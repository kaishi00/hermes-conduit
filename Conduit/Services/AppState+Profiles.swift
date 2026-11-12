//
//  AppState+Profiles.swift
//  Conduit
//
//  Switching profiles, reading the profile list, the Siri profile names
//  and the fallback profile, and the profiles' order. Moved out of
//  AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Switching and reading profiles

    func switchProfile(to profile: String) async {
        _ = await switchProfile(to: profile, reusing: nil)
    }

    func switchProfileForWidget(to profile: String, lease: WidgetLaunchLease) async -> Bool {
        await switchProfile(to: profile, reusing: nil, widgetLease: lease)
    }

    @discardableResult
    func switchProfile(
        to profile: String,
        reusing viewportTransitionGeneration: UInt64?,
        refusingCallsWith callRefusal: String? = nil,
        widgetLease: WidgetLaunchLease? = nil,
        navigationSeenAt seenGeneration: UInt64? = nil
    ) async -> Bool {
        let signposter = ResponsivenessSignposts.signposter
        let switching = signposter.beginInterval("Profile switch", id: signposter.makeSignpostID())
        defer { signposter.endInterval("Profile switch", switching) }
        // The early reads the switch's ticket sent are its own steps'; what
        // they didn't take is dropped when it ends, as connect's are.
        defer { startupReads.clear() }
        let target = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, target != activeProfile, let savedConnection = connection else {
            return false
        }
        guard !isProfileSwitching else { return false }
        // What the switch shows first (the profile's saved list and the chat
        // it opens on) is read ahead off the main thread while it waits on
        // its ticket and teardown, if the read-ahead after the live list
        // hasn't already (issue 1963).
        if let dashboardID = savedDashboardRegistry.activeDashboardID {
            offlineChatCache.prefetch(dashboardID: dashboardID, profile: target, transcripts: 1)
        }
        // A switch that spares calls (a notification's or a chat link's)
        // mints its ticket before anything changes, so nothing waits between
        // its call check and the voice teardown below; it refuses while a
        // call runs, saying `callRefusal`. One that will keep the open
        // socket needs no ticket, so it neither waits nor fails on one.
        var sparedCallTicket: String?
        if let callRefusal {
            var mintError: Error?
            if socketToKeepForProfileSwitch(within: savedConnection) == nil {
                do {
                    sparedCallTicket = try await mintChatResumeTicket(for: savedConnection, readsFor: profile)
                } catch {
                    mintError = error
                }
            }
            // A newer navigation or switch that started meanwhile owns the
            // screen now.
            if let viewportTransitionGeneration,
               !chatViewportTransitionIsCurrent(generation: viewportTransitionGeneration) {
                return false
            }
            // A tap that began no transition of its own (New conversation
            // in another profile) gives way to one that began meanwhile.
            if let seenGeneration, !chatViewportTransitionIsCurrent(generation: seenGeneration) {
                return false
            }
            guard widgetLease?.isCurrent != false else {
                if let viewportTransitionGeneration {
                    cancelChatViewportTransitionIfNoReplacement(generation: viewportTransitionGeneration)
                }
                return false
            }
            guard !isProfileSwitching, target != activeProfile, connection == savedConnection else { return false }
            // A call that rang in meanwhile says so, whether or not the
            // ticket came: the call alone stops the switch.
            guard !isVoiceCallInProgress else {
                showCallRefusal(callRefusal)
                return false
            }
            if let mintError {
                let message = AppLocalization.string("Could not switch workspace: \(UserFacingError.message(for: mintError))")
                errorMessage = message
                // The composer shows errorMessage only while it's locked, so
                // a notice says it too, or the tap looks ignored: once while
                // it's up, since the route retries the open for its window.
                // Only V2 draws the notice.
                if V2ShellPreference.isOn, pinSyncNotice?.message != message {
                    showNotice(message, systemImage: "exclamationmark.circle")
                }
                return false
            }
        }
        // A profile change replaces the voice gateway; any in-flight read
        // aloud belongs to the outgoing profile.
        messageReadAloudController.stop()
        let transitionGeneration: UInt64
        if let viewportTransitionGeneration {
            guard chatViewportTransitionIsCurrent(
                generation: viewportTransitionGeneration
            ) else { return false }
            transitionGeneration = viewportTransitionGeneration
        } else {
            transitionGeneration = beginExplicitChatViewportTransition(ownedBy: widgetLease)
        }
        cancelChatResumeTransportRecovery()
        // Hard profile boundary for this forward transition: cancel the
        // debounced stream flush and write synchronously while the outgoing
        // profile still owns the in-memory transcript. No parked task
        // survives the identity changes below (success or rollback).
        flushPendingPresentationCache()
        cancelSecondaryProfileTitleRecovery()

        // Dismiss keyboard before switching profiles
        DispatchQueue.main.async {
            ReturnKeyTextView.putAwayFocus()
        }

        let previousProfile = activeProfile
        let previousApprovalsMode = runtime.approvalsMode
        let previousYolo = runtime.yolo
        let previousLastReportedSessionYolo = lastReportedSessionYolo
        let previousSessions = sessions
        let previousCronSessions = cronSessions
        let previousArchivedSessions = archivedSessions
        let previousProjects = projects
        let previousSupportsProjects = supportsProjects
        let previousTurnState = turnState
        isProfileSwitching = true
        defer { isProfileSwitching = false }
        invalidateReconciliation()
        turnState = .synchronizing
        // The next profile's approval mode is unknown until its first session
        // snapshot arrives; don't let the previous profile's floor leak across
        // the switch, and neutralize the indicator to the safe display
        // (approvals required) until the new profile resolves it.
        runtime.approvalsMode = nil
        runtime.yolo = false
        lastReportedSessionYolo = nil
        func restorePreviousApprovalState() {
            runtime.approvalsMode = previousApprovalsMode
            runtime.yolo = previousYolo
            lastReportedSessionYolo = previousLastReportedSessionYolo
        }
        // Set once the target's client and identity are installed: from
        // then on a superseded switch still finishes or rolls back.
        var adoptedTarget = false
        var previousClient: HermesClient?
        // The outgoing transcript as the profile changes over, for a switch
        // that fails after it.
        var previousMessages: [ChatMessage] = []
        var previousOfflineChatPresentation: OfflineChatPresentation?
        var previousTranscriptDashboardID: UUID?

        do {
            // The open socket isn't tied to a profile, so the new profile's
            // client takes it over instead of a new ticket and socket, about
            // two seconds on a slow path (#1442). Nothing awaits between
            // here and the hand-off, so the socket checked here is the one
            // handed on.
            let keptSocketClient = socketToKeepForProfileSwitch(within: savedConnection)
            let ticket: String
            if keptSocketClient != nil {
                ticket = savedConnection.ticket
            } else if let sparedCallTicket {
                ticket = sparedCallTicket
            } else {
                ticket = try await mintChatResumeTicket(for: savedConnection, readsFor: profile)
            }
            guard widgetLease?.isCurrent != false else {
                // Nothing has changed over yet: the previous profile keeps
                // its approval state and, unless a newer navigation owns the
                // chat, its turn state.
                restorePreviousApprovalState()
                if chatViewportTransitionIsCurrent(generation: transitionGeneration),
                   turnState == .synchronizing {
                    turnState = previousTurnState == .synchronizing ? .idle : previousTurnState
                }
                cancelChatViewportTransitionIfNoReplacement(generation: transitionGeneration)
                return false
            }
            guard chatViewportTransitionIsCurrent(generation: transitionGeneration) else {
                // A newer navigation owns the chat, and nothing has changed
                // over yet: the previous profile keeps its approval state.
                restorePreviousApprovalState()
                return false
            }
            let freshConnection = HermesConnection(baseUrl: savedConnection.baseUrl, ticket: ticket)
            previousClient = client
            let nextClient = makeClient(connection: freshConnection, profile: target)
            if let previousClient { nextClient.inheritSessionProfiles(from: previousClient) }
            previousMessages = messages
            previousOfflineChatPresentation = offlineChatPresentation
            previousTranscriptDashboardID = activeDashboardID

            markChatViewportReplacement()
            adoptedTarget = true
            connection = freshConnection
            client = nextClient
            clearPendingDecisionRestorationGuard()
            // A profile switch ends any live or suspended Voice conversation
            // from the outgoing profile. Persist the outgoing mute and tear
            // down BEFORE the identity flip: the sheet's deferred onDismiss
            // re-enters closeVoiceConversation after the switch, and its
            // hasLiveVoiceSession guard makes that a no-op so the outgoing
            // mute can never be persisted under the target profile.
            if showVoiceSheet {
                var preferences = loadVoiceProfilePreferences(profile: activeProfile)
                preferences.outputMuted = voiceConversationController.isOutputMuted
                saveVoiceProfilePreferences(preferences, profile: activeProfile)
            }
            voiceConversationController.stop()
            stopQwenLiveConversation()
        stopGeminiLiveConversation()
            stopGPTLiveConversation()
            stopGrokLiveConversation()
            stopLocalLiveConversation()
            retireVoiceBackgroundJobs()
            showVoiceSheet = false
            clearClassicVoiceCards()
            suspendedVoiceConversation = nil
            voiceSheetShouldAutoListen = false
            voiceControllerSessionProfile = nil
            // The outgoing profile's list as it shows now, for switching back.
            recordSavedChatList()
            // And its chat, when Load earlier brought in older rows.
            keepLeftBackfilledTranscript()
            // Fence any residual deferred cache write scheduled under the
            // outgoing profile before identities and namespaces change over.
            setActiveProfile(target)
            sessions = []
            cronSessions = []
            archivedSessions = []
            projects = []
            supportsProjects = false
            projectsLoading = false
            projectsLoadFailed = false
            slashCommands = Self.builtInSlashCommands
            slashSubcommands = Self.conduitSlashSubcommands
            restoreActiveSessionState(for: target)
            restorePinnedSessions(for: target)
            // The target's list as it showed last time, until its own lands.
            if let dashboardID = activeDashboardID {
                presentSavedChatListIfAvailable(dashboardID: dashboardID)
            }
            presentRestoredChatAfterProfileChange()
            // handOffSocket checks what socketToKeepForProfileSwitch did,
            // plus that nextClient is new, so with nothing awaited between
            // them it can't refuse here; the fallback below is for a switch
            // that kept no socket and so holds a fresh ticket.
            if let keptSocketClient, keptSocketClient.handOffSocket(to: nextClient) {
                noteConnectionStep("Socket kept for the switch")
            } else {
                try await connectChatResumeClient(nextClient)
            }
            // The new profile is connected and already active: an expired
            // widget launch or a newer navigation still finishes the switch
            // (only the chat is theirs), or the old socket and a
            // half-switched profile would be left behind.
            guard self.client === nextClient else {
                previousClient?.disconnect()
                return false
            }
            // Keep the previous socket alive until the new profile has
            // actually connected, so a failed switch has a recovery path.
            previousClient?.disconnect()
            // An owed bootstrap belongs to the outgoing client; it can never
            // match the new one, so retire it rather than pin a dead socket.
            if let previousClient, owedPostConnectBootstrap?.client === previousClient {
                owedPostConnectBootstrap = nil
            }
            isConnected = true
            connectedAt = Date()
            if let dashboardID = activeDashboardID {
                KeychainHelper.saveConnection(freshConnection, dashboardID: dashboardID)
            }
            persistActiveProfile(target)
            // The profile's busy mode and display settings are read in the
            // background: both already show what this profile last said
            // (restoreDisplayPreferences, the busy mode's cache), and the
            // display read alone took over two seconds on a real dashboard,
            // which the switch and a chat opened in the other profile waited
            // on (#1442).
            Task {
                await loadChatResumeBusyInputMode(using: nextClient)
                guard self.client === nextClient else { return }
                await loadChatResumeProfileDisplayPreferences()
            }
            // A newer navigation opens and syncs its own chat.
            guard chatViewportTransitionIsCurrent(generation: transitionGeneration) else {
                return false
            }

            await syncSession(
                purpose: .preserveCurrent,
                using: nil,
                automaticWorkToken: nil,
                requiredViewportTransitionGeneration: transitionGeneration
            )
            guard chatViewportTransitionIsCurrent(generation: transitionGeneration) else {
                return false
            }
            // A transition borrowed from an open that goes on (a
            // notification) stays with it: the chat it opens next lays out
            // under it.
            if viewportTransitionGeneration == nil {
                finishChatViewportTransitionIfNoTranscriptReplacement(
                    generation: transitionGeneration
                )
            }
            Task { await loadChatResumeSlashCommands() }
            return true
        } catch {
            let ownsChat = chatViewportTransitionIsCurrent(generation: transitionGeneration)
            // Superseded before anything changed over: only the approval
            // state was neutralized. Once the target was installed, its
            // failed client is rolled back even when a newer navigation owns
            // the chat; only the error is left to that one, and the outgoing
            // chat and its transcript come back over it until the reconnect
            // resolves it.
            guard ownsChat || adoptedTarget else {
                restorePreviousApprovalState()
                return false
            }
            if ownsChat {
                errorMessage = AppLocalization.string("Could not switch workspace: \(UserFacingError.message(for: error))")
            }
            clearPendingDecisionRestorationGuard()
            // The pre-switch reset neutralized the approval state; restore it
            // with the rest of the previous profile or a failed switch loses
            // the floor while the previous profile is still the active one.
            restorePreviousApprovalState()
            sessions = previousSessions
            cronSessions = previousCronSessions
            archivedSessions = previousArchivedSessions
            projects = previousProjects
            supportsProjects = previousSupportsProjects
            projectsLoading = false
            restoreActiveSessionState(for: previousProfile)
            restorePinnedSessions(for: previousProfile)
            // restoreActiveSessionState/restorePinnedSessions are
            // synchronous and cache-write-free; the pre-flight boundary
            // flush (above) already persisted the outgoing transcript under
            // the previous profile's namespace. setActiveProfile(_:)
            // deliberately does NOT flush: flipping the identity back only
            // re-arms the namespace and bumps the fence epoch, making any
            // flush scheduled under the failed target during the aborted
            // attempt stale.
            setActiveProfile(previousProfile)
            // The previous profile's transcript left with it: it comes back
            // as it was, with its chat (restored above), over any newer
            // navigation's, which the reconnect then resolves. Never onto
            // another dashboard a switch moved to meanwhile.
            if adoptedTarget, activeDashboardID == previousTranscriptDashboardID {
                messages = previousMessages
                offlineChatPresentation = previousOfflineChatPresentation
            }
            connection = savedConnection
            previousClient?.disconnect()
            client?.disconnect()
            client = nil
            isConnected = false
            turnState = .reconnecting
            if ownsChat { finishChatViewportTransition(generation: transitionGeneration) }
            await reconnect()
            return false
        }
    }

    func loadProfiles() async {
        await readProfiles()
    }

    /// Reads the host's profile list. False when it wasn't read for this
    /// connection (no bridge, a failed or empty reply, or a reply from a
    /// replaced connection): the list then says nothing about a profile.
    /// True when a list sent after this one was taken first, which stands.
    @discardableResult
    func readProfiles() async -> Bool {
        guard let bridge = dashboardTicketBridge else { return false }
        let dashboardID = activeDashboardID
        profileListReadsSent &+= 1
        let read = profileListReadsSent
        do {
            let response: [String: Any]
            if let profileDiscoveryLoaderOverride {
                response = try await profileDiscoveryLoaderOverride()
            } else {
                response = try await startupReads.read("/api/profiles", through: bridge, fence: startupReadFence(for: bridge))
            }
            // Commit gate, same identity pattern as the dashboard catalog
            // loader: a bridge swapped mid-request (server change, re-login,
            // disconnect) makes this response foreign. A late reply from an
            // old connection must not overwrite the live list, and must not
            // repopulate a persisted cache that
            // prepareChatResumeForConnection(to:) already cleared with the
            // previous server's profile names. Discarded silently — profile
            // discovery has no retry loop to feed an error into.
            guard dashboardTicketBridge === bridge, activeDashboardID == dashboardID else { return false }
            let values = response["profiles"] as? [Any] ?? []
            let names = values.compactMap { value -> String? in
                if let name = value as? String { return name }
                return (value as? [String: Any])?["name"] as? String
            }
            // Two reads through the same bridge can land out of order (one
            // native, one through the page or read again): one sent after
            // this that already landed is newer, so this older list must not
            // undo a bot just made or deleted, nor re-home the profile in use.
            // Only a list with names takes the place: a degraded empty one
            // leaves it to an older complete one. A list that lost it was
            // read all the same, and a newer one stands.
            guard read > profileListReadCommitted else { return true }
            if !names.isEmpty { profileListReadCommitted = read }
            // Rows as objects carry `display_name`; a plain-name listing
            // says nothing about it, and the bot roster fills it in.
            let rows = values.compactMap { $0 as? [String: Any] }
            if !rows.isEmpty, rows.count == values.count {
                adoptProfileHermesNames(rows.compactMap { row in
                    (row["name"] as? String).map { (profile: $0, displayName: row["display_name"] as? String ?? "") }
                })
            }
            // A 200 with no profile names is a degraded payload (dashboard
            // mid-restart, partial deploy, proxy), not authoritative evidence
            // that every profile vanished — Hermes always has `default`. The
            // next line would otherwise collapse the picker and persist that
            // degraded list over the complete cache, the exact bug this
            // function exists to prevent, just via a 200 instead of an error.
            let nextProfiles = names.isEmpty
                ? orderedProfiles(profiles + [activeProfile, "default"])
                : orderedProfiles(names + ["default"])
            profiles = nextProfiles
            persistKnownProfiles(nextProfiles)
            if !names.isEmpty, let dashboardID {
                retainWidgetProfiles(Set(nextProfiles), dashboardID: dashboardID)
            }
            // A deleted profile's glow pick goes with it, so a new profile
            // given the same name later starts from its photo's color.
            if !names.isEmpty {
                let stale = profileGlowPicks.keys.filter { !nextProfiles.contains($0) }
                for profile in stale {
                    setProfileGlowColor(nil, for: profile)
                }
                // So do its pinned replies, which keep reply text.
                for profile in pinnedRepliesByProfile.keys where !nextProfiles.contains(profile) {
                    forgetPinnedReplies(profile: profile)
                }
            }
            // A non-empty response is authoritative: if the server no longer
            // knows the active profile (deleted externally), re-home onto a
            // valid fallback instead of leaving `activeProfile ∉ profiles` —
            // a state the profile picker cannot represent. The degraded and
            // empty-payload paths already union `activeProfile` in, so only
            // this branch can need the correction.
            if !names.isEmpty, !nextProfiles.contains(activeProfile) {
                // orderedProfiles always unions "default" into a non-empty
                // names list, so the fallback is unconditionally "default";
                // the contains-check stays as cheap defense-in-depth against
                // a future change to that union invariant.
                adoptAuthoritativeFallbackProfile(
                    nextProfiles.contains("default") ? "default" : nextProfiles[0]
                )
                // The abandoned profile-scoped connect/reconnect work can no
                // longer commit (its identity fences now fail), so converge
                // the transport onto the corrected profile. Fire-and-forget:
                // never awaited inside discovery, and idempotent — the next
                // discovery contains the fallback and will not re-adopt.
                if isConnected {
                    Task { await reconnect() }
                }
            }
            return !names.isEmpty
        } catch {
            guard dashboardTicketBridge === bridge, activeDashboardID == dashboardID else { return false }
            // Profile discovery is additive and monotonic. A failed refresh
            // (bridge still loading, dashboard restart, transient 5xx) must
            // never shrink the visible list or overwrite a complete persisted
            // cache with a degraded fallback — that degradation is exactly
            // how a known profile "disappeared" from the picker until the
            // next successful discovery or a logout/login cycle. Union with
            // the current list so the active profile and the `default`
            // invariant are always represented, then persist the union (a
            // no-op write when the cache is already complete).
            let merged = orderedProfiles(profiles + [activeProfile, "default"])
            profiles = merged
            persistKnownProfiles(merged)
            // A list sent after this one was read and taken meanwhile.
            return read <= profileListReadCommitted
        }
    }

    /// Caches the profile list and, when it changed, tells Siri so the
    /// "Start <profile> voice in Conduit" phrases can match the new names.
    private func persistKnownProfiles(_ names: [String]) {
        guard defaults.stringArray(forKey: knownProfilesKey) != names else { return }
        defaults.set(names, forKey: knownProfilesKey)
        persistSiriProfileNames()
        refreshSiriProfileShortcuts()
    }

    /// Siri and Shortcuts name each profile as the rest of Conduit does,
    /// and follow a rename.
    func persistSiriProfileNames() {
        let ids = defaults.stringArray(forKey: knownProfilesKey) ?? ["default"]
        var names: [String: String] = [:]
        for id in ids { names[id] = profileDisplayName(id) }
        guard defaults.dictionary(forKey: knownProfileNamesKey) as? [String: String] != names else { return }
        defaults.set(names, forKey: knownProfileNamesKey)
        refreshSiriProfileShortcuts()
    }

    /// Siri re-reads the cached profile list in a later task; discovery and
    /// the server-switch wipe never wait on it.
    func refreshSiriProfileShortcuts() {
        Task {
            SiriProfileShortcuts.refresh()
        }
    }

    /// Authoritative discovery reported a server that no longer contains the
    /// active profile (e.g. it was deleted externally). Re-home onto a valid
    /// fallback using the same local hard-boundary sequence as the forward
    /// profile transition in `connect(with:profile:)`: flush the outgoing
    /// transcript under its presentation-cache namespace, clear the
    /// profile-scoped catalogs and transcript, fence-flip the identity,
    /// prune the deleted profile's persisted bookkeeping, restore the
    /// fallback's remembered session/pinned state, and persist the
    /// correction under `activeProfileKey`.
    ///
    /// Deliberately NOT the interactive `switchProfile(to:reusing:)` flow:
    /// that re-resolves the whole connection and would nest reconnects and
    /// capability loads inside this discovery call site. Callers schedule a
    /// fire-and-forget `reconnect()` when the transport is live so the
    /// client converges onto the corrected profile; every catalog read is
    /// filtered and path-prefixed by the explicit profile, so no
    /// cross-profile transcript or cache state leaks in the window before
    /// that reconnect lands.
    ///
    /// Internal for tests: the fallback adoption is a real destructive Voice
    /// boundary and the cross-profile fail-closed restore contract is pinned
    /// through it.
    func adoptAuthoritativeFallbackProfile(_ fallback: String) {
        guard fallback != activeProfile else { return }
        // A profile change replaces the voice gateway; any in-flight read
        // aloud belongs to the outgoing profile (same as switchProfile).
        messageReadAloudController.stop()
        // A profile re-home ends any live or suspended Voice conversation
        // from the outgoing profile. Persist the outgoing mute and tear down
        // BEFORE the identity flip so it lands in the outgoing profile's
        // blob, never the fallback's (same contract as switchProfile).
        if showVoiceSheet {
            var preferences = loadVoiceProfilePreferences(profile: activeProfile)
            preferences.outputMuted = voiceConversationController.isOutputMuted
            saveVoiceProfilePreferences(preferences, profile: activeProfile)
        }
        voiceConversationController.stop()
        stopQwenLiveConversation()
        stopGeminiLiveConversation()
        stopGPTLiveConversation()
        stopGrokLiveConversation()
        stopLocalLiveConversation()
        retireVoiceBackgroundJobs()
        showVoiceSheet = false
        clearClassicVoiceCards()
        suspendedVoiceConversation = nil
        voiceSheetShouldAutoListen = false
        voiceControllerSessionProfile = nil
        flushPendingPresentationCache()
        sessions = []
        cronSessions = []
        archivedSessions = []
        projects = []
        supportsProjects = false
        projectsLoading = false
        projectsLoadFailed = false
        slashCommands = Self.builtInSlashCommands
        slashSubcommands = Self.conduitSlashSubcommands
        messages = []
        persistedTranscriptWindow = nil
        resetTranscriptLifecycleEvidence()
        clearStreamingText()
        resetReasoningTurn()
        // The next profile's approval mode is unknown until its first session
        // snapshot arrives; don't let the deleted profile's approval floor or
        // YOLO state leak across the re-home — neutralize to the safe display
        // until the fallback profile resolves them (same neutralization as
        // switchProfile).
        runtime.approvalsMode = nil
        runtime.yolo = false
        lastReportedSessionYolo = nil
        // Drop the deleted profile's persisted local bookkeeping so a later
        // re-creation with the same name starts fresh instead of
        // resurrecting obsolete titles and pins.
        activeSessionTitlesByProfile.removeValue(forKey: activeProfile)
        pinnedSessionIDsByProfile.removeValue(forKey: activeProfile)
        sessionPinSync.forget(profile: activeProfile)
        persistHostPinSyncState()
        sessionStars.forget(profile: activeProfile)
        sessionStars.save(to: defaults)
        pinnedChatOrder.forget(profile: activeProfile)
        pinnedChatOrder.save(to: defaults)
        voiceJobSessionIDsByProfile.removeValue(forKey: activeProfile)
        forgetPinnedReplies(profile: activeProfile)
        persistActiveSessionTitles()
        persistPinnedSessions()
        persistVoiceJobSessions()
        setActiveProfile(fallback)
        restoreActiveSessionState(for: fallback)
        restorePinnedSessions(for: fallback)
        persistActiveProfile(fallback)
    }

    func orderedProfiles(_ values: [String]) -> [String] {
        let discovered = Array(Set(values.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }))
        let orders = defaults.dictionary(forKey: profileOrderByDashboardKey) as? [String: [String]] ?? [:]
        let savedOrder = orders[Self.dashboardPreferenceBucket(activeDashboardID)] ?? []
        let knownOrder = savedOrder.filter { discovered.contains($0) }
        let unordered = discovered
            .filter { !knownOrder.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        if savedOrder.isEmpty, let defaultProfile = unordered.first(where: { $0 == "default" }) {
            return [defaultProfile] + unordered.filter { $0 != "default" }
        }
        return knownOrder + unordered
    }

    static func normalizedSessionFilterOrder(_ values: [String]) -> [SessionSource] {
        let defaults = Self.defaultSessionFilterOrder
        let requested = values.compactMap(SessionSource.init(rawValue:))
        var unique = requested.reduce(into: [SessionSource]()) { result, source in
            if !result.contains(source), defaults.contains(source) {
                result.append(source)
            }
        }
        // Filters a saved order predates (Voice, Voice Jobs, Cron) take their
        // default place after the one before them, not the end of the row.
        for (position, source) in defaults.enumerated() where !unique.contains(source) {
            let after = defaults[..<position].last { unique.contains($0) }
            let index = after.flatMap { unique.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            unique.insert(source, at: index)
        }
        return unique
    }
}
