//
//  AppState+ConnectionTimeline.swift
//  Conduit
//
//  Moved out of AppState.swift (issue 828): Connection timeline (#417).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Connection timeline (#417)

    /// Starts a fresh timeline. Used where a launch, a return to the app or
    /// a reconnect begins; every step after it lands in this one.
    func beginConnectionTimeline(_ trigger: String) {
        connectionTimeline = ConnectionTimeline(trigger: trigger)
        // A call from Hermes races these (#449).
        HermesCallTrace.shared.note("Connection: \(trigger)")
    }

    /// Starts a timeline only when none is still recording, so a reconnect
    /// inside a launch extends the launch's timeline.
    func continueConnectionTimeline(_ trigger: String) {
        if connectionTimeline?.isRecording() != true {
            beginConnectionTimeline(trigger)
        }
    }

    /// Records one step. Purely observational: nothing reads the timeline
    /// back except Gateway Diagnostics.
    func noteConnectionStep(_ label: String, since startedAt: Date? = nil, error: Error? = nil) {
        connectionTimeline?.record(label, since: startedAt, error: error)
        HermesCallTrace.shared.note("Connection: \(label)", since: startedAt, error: error)
    }

    /// `readsFor` names the profile the connection will open on, when it
    /// isn't the active one yet (a profile switch), so the early reads are
    /// its own.
    func mintChatResumeTicket(for connection: HermesConnection, readsFor profile: String? = nil) async throws -> String {
        if let mintTicket = chatResumeLifecycleOperations.mintTicket {
            return try await mintTicket(connection.baseUrl)
        }
        prepareDashboardBridge(for: connection.baseUrl)
        guard let dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        // A switch never reads the profile list, so it doesn't send it.
        sendStartupReads(profile: profile ?? activeProfile, includingProfiles: profile == nil)
        let startedAt = Date()
        let signposter = ResponsivenessSignposts.signposter
        let minting = signposter.beginInterval("Ticket mint", id: signposter.makeSignpostID())
        defer { signposter.endInterval("Ticket mint", minting) }
        do {
            let ticket = try await dashboardTicketBridge.mintTicket()
            noteConnectionStep("Ticket", since: startedAt)
            return ticket
        } catch {
            noteConnectionStep("Ticket", since: startedAt, error: error)
            throw error
        }
    }

    /// The connected client whose socket a profile switch on
    /// `savedConnection` hands to the new profile's client, or nil when the
    /// switch opens its own (no socket open, another dashboard's, or one
    /// that can't be handed on yet).
    func socketToKeepForProfileSwitch(within savedConnection: HermesConnection) -> HermesClient? {
        guard let client, client.canHandOffSocket,
              client.connection.baseUrl == savedConnection.baseUrl else { return nil }
        return client
    }

    func connectChatResumeClient(_ client: HermesClient) async throws {
        if let connectClient = chatResumeLifecycleOperations.connectClient {
            try await connectClient(client)
        } else {
            let startedAt = Date()
            let signposter = ResponsivenessSignposts.signposter
            let connecting = signposter.beginInterval("WebSocket connect", id: signposter.makeSignpostID())
            defer { signposter.endInterval("WebSocket connect", connecting) }
            do {
                try await client.connect()
                noteConnectionStep("Socket open", since: startedAt)
            } catch {
                noteConnectionStep("Socket open", since: startedAt, error: error)
                throw error
            }
        }
    }

    func loadChatResumeProfiles() async {
        if let loadProfiles = chatResumeLifecycleOperations.loadProfiles {
            await loadProfiles()
        } else {
            let startedAt = Date()
            await loadProfiles()
            noteConnectionStep("Profile list", since: startedAt)
        }
    }

    /// Bot Mode's capability probe and canonical registry, loaded once per
    /// connection — BEFORE the resume decision reads it.
    ///
    /// Bot conversations share the session id space with the Sessions surface,
    /// so "is this id a bot's forever chat?" can only be answered from
    /// evidence: the roster's canonical registries plus this process's chat
    /// registry. Loading it here (rather than only when the Bots surface opens)
    /// is what makes that evidence available while a workspace is still
    /// deciding which conversation it was in — otherwise the strongest signal
    /// the restore path can have is a row's title, and a canonical chat whose
    /// title no longer reads "Bot Chat" passes as an ordinary conversation.
    ///
    /// Failures are never fatal: a gateway without Bot Mode answers a missing
    /// method, and the phase marks the capability gap for the Bots surface
    /// while ordinary sessions are untouched.
    func loadChatResumeBotRoster() async {
        if let loadBotRoster = chatResumeLifecycleOperations.loadBotRoster {
            await loadBotRoster()
            return
        }
        guard botModePhase != .gatewayUnsupported else { return }
        // One verified roster per CONNECTION. The skip avoids re-fetching on
        // the resume path within a connection, but it must not cross a
        // reconnection: a same-server reconnect re-reads this evidence,
        // because a bot registered since the last successful refresh would be
        // missing from a roster that still reports `.available` — and absence
        // is what the authority gates read.
        guard botRosterVerifiedForCurrentConnection else {
            let startedAt = Date()
            await refreshBotRoster()
            noteConnectionStep("Bot roster", since: startedAt)
            return
        }
        // Already verified for this connection: nothing left to do (the
        // trailing `botRoster.isEmpty` guard that used to sit here returned to
        // the end of the function either way).
    }

    func loadChatResumeBusyInputMode(using client: HermesClient) async {
        if let loadBusyInputMode = chatResumeLifecycleOperations.loadBusyInputMode {
            await loadBusyInputMode(client)
        } else {
            let startedAt = Date()
            await loadBusyInputMode(using: client)
            noteConnectionStep("Busy-input setting", since: startedAt)
        }
    }

    func loadChatResumeProfileDisplayPreferences() async {
        if let loadProfileDisplayPreferences = chatResumeLifecycleOperations.loadProfileDisplayPreferences {
            await loadProfileDisplayPreferences()
        } else {
            let startedAt = Date()
            await loadProfileDisplayPreferences()
            noteConnectionStep("Display settings", since: startedAt)
        }
    }

    func loadChatResumeSlashCommands() async {
        if let loadSlashCommands = chatResumeLifecycleOperations.loadSlashCommands {
            await loadSlashCommands()
        } else {
            await loadSlashCommands()
        }
    }

    @discardableResult
    func handleScenePhase(_ phase: ScenePhase) -> Task<Void, Never>? {
        HermesCallTrace.shared.note("App \(phase)")
        if phase != .active {
            responseHapticConclusionTask?.cancel()
            responseHapticConclusionTask = nil
        }
        if let effect = responseHaptics.setForegroundActive(
            ResponseHapticPolicy.treatsAsForegroundActive(phase)
        ) {
            performResponseHapticEffects([effect])
        }
        switch phase {
        case .active:
            if !(isSceneActive && sceneHasBeenActive) { sceneActiveSince = Date() }
            isSceneActive = true
            sceneHasBeenActive = true
            backgroundConnectionGrace.end()
            // Polls left long while nothing moved catch up at once.
            noteChatListInteraction()
            openChatSync.resetIdlePace()
            client?.setKeepaliveBackgrounded(false)
            // A message left waiting through a long time away isn't sent on
            // its own now, as after Conduit was stopped.
            returnPendingComposerSendAfterLongAbsence()
            widgetLaunchCoordinator.readinessChanged()
            // A Pulse widget added since gets what it reads Pulse with.
            Task { await savePulseWidgetAccess() }
            // A sign-out that couldn't reach Hermes tries again.
            serverSignOutQueue.retryPending()
            // A draft shared from another app opens its chat (#812).
            publishShareDraftSettings()
            postponedSharedDraftIDs = []
            pickUpSharedDrafts()
            pruneSharedDraftNotifications()
            // A Talk that arrived before there was a window shows its call
            // screen now.
            presentWaitingCallIfNeeded()
            // So does why a call failed in the car.
            presentCarPlayFailureIfWaiting()
            noteActiveChatSeen(respectingMarks: true)
            // Health data the phone gathered while Conduit was away.
            Task { await runHealthSync(reason: .foreground) }
            // Location permissions may have changed; unsent location goes.
            activateLocationSharing()
            LocationSharingController.shared.appBecameActive()
            Task { await runPhoneSync(reason: .foreground) }
            Task { await syncPresentedScreens() }
            // An invite that came while Conduit was away, its push missed,
            // and a room that started meanwhile.
            Task { await refreshLinkedRoomsOnForeground() }
            scheduleWakeRefresh()
            // Voice gates. The capture gate additionally requires a Voice
            // surface (the phone sheet, or CarPlay), so it can be false here
            // while the app-foreground gate is true — that pair is exactly
            // the Voice settings state, and it must still admit permission
            // requests and provider tests.
            publishVoiceRuntimeGates()
            startDeferredVoiceSheetAutoListen()
            messageReadAloudController.setForegroundActive(true)
            // Voice restoration deliberately does NOT run here: the socket,
            // bridge, and runtime session identity may all be stale after a
            // background suspension. The suspended descriptor is consumed
            // inside the reconciliation task below, after the authoritative
            // transport/session state is established (or definitively fails).
            // Consume the background arming even while signed out, so a
            // background → active cycle on the login screen doesn't surface
            // a stale request after the user signs back in.
            let didReturnFromBackground = hasEnteredBackgroundScenePhase
            hasEnteredBackgroundScenePhase = false
            // What streamed while hidden shows, in one publish.
            if sceneHidesLiveRows {
                sceneHidesLiveRows = false
                resumeLivePublishesIfShown()
            }
            if holdLaunchDashboardChoiceOnScreen() {
                foregroundFreshnessCheckArmed = false
                return nil
            }
            if showLogin, signInWaitsForForeground {
                // The freshness arming belongs to the session that was torn
                // down; the retry's connect syncs from scratch.
                foregroundFreshnessCheckArmed = false
                retrySignInFromBackground()
                return nil
            }
            guard connection != nil else {
                // A cold-launch restore that failed offline left the saved
                // copy up without a connection: try the restore again.
                if offlineChatPresentation != nil, !showLogin {
                    retryFromOfflineChat()
                }
                return nil
            }
            // The preferred return surface belongs to the authenticated
            // app: MainView presents the drawer while the automatic resume
            // sync restores the chat underneath, and explicit navigation
            // still wins via the suppression guards on both sides.
            if didReturnFromBackground {
                beginQuietReturn()
                requestPreferredReturnSurface()
                let away = lastLeftForegroundAt.map {
                    " after \(ConnectionTimeline.seconds(Date().timeIntervalSince($0))) away"
                } ?? ""
                beginConnectionTimeline("back in the app\(away)")
            } else {
                noteConnectionStep("App active")
            }
            cancelScenePhaseAttempt()
            // Publish the foreground reconciliation boundary synchronously.
            // ChatView may receive the same scene transition before the health
            // check task runs, so geometry alone must not restore stale rows.
            // Consume the freshness arming here, synchronously with the
            // transition: exactly one foreground return pays the bounded
            // freshness check, overlay dips stay observational, and a refresh
            // superseded mid-read is token-dead before it can act on stale
            // evidence (every deactivation rotates the token).
            let freshnessCheckArmed = foregroundFreshnessCheckArmed
            foregroundFreshnessCheckArmed = false
            let token = beginReconciliation()
            let automaticWorkToken = beginAutomaticChatResumeWork()
            let sceneAttemptID = UUID()
            self.scenePhaseAttemptID = sceneAttemptID
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.finishScenePhaseAttempt(id: sceneAttemptID) }
                guard self.scenePhaseAttemptIsCurrent(sceneAttemptID) else { return }
                if let client = self.client, client.isConnected {
                    // A connect that aborted mid-flight (scene went inactive
                    // before its checkpoint) can leave the UI's transport
                    // flags unpublished — "connecting…" with sends disabled —
                    // even though the socket is alive. Publish the healthy
                    // transport before syncing; the reconnect path manages
                    // these flags for unhealthy sockets.
                    self.isConnected = true
                    self.isConnecting = false
                    lifecycleLog.notice(
                        "Foreground refresh start: transport=retained localTurn=\(self.turnStateLogValue, privacy: .public)"
                    )
                    // The registry probe goes out alongside the health ping
                    // (issue 1727): both are reads on the same socket, and
                    // its rows count only once the ping passed. Not when a
                    // bootstrap is owed, which never reads them.
                    let probeRead: Task<ForegroundRuntimeRowsRead, Never>?
                    if self.activeSessionId != nil,
                       !(self.owedPostConnectBootstrap.map { $0.client === client } ?? false) {
                        probeRead = self.startForegroundRuntimeRowsRead(using: client)
                    } else {
                        probeRead = nil
                    }
                    defer { probeRead?.cancel() }
                    do {
                        try await self.verifyChatResumeTransportHealth(client)
                        guard self.scenePhaseAttemptIsCurrent(sceneAttemptID),
                              self.automaticChatResumeWorkIsCurrent(automaticWorkToken) else {
                            self.settleReconciliation(token)
                            return
                        }
                        if let owed = self.owedPostConnectBootstrap, owed.client === client {
                            lifecycleLog.notice(
                                "Foreground refresh: post-connect bootstrap owed (connect interrupted by scene deactivation) → full sync"
                            )
                            await self.runOwedPostConnectBootstrap(
                                owed,
                                reconciliationToken: token,
                                automaticWorkToken: automaticWorkToken,
                                isCurrent: { self.scenePhaseAttemptIsCurrent(sceneAttemptID) }
                            )
                        } else {
                            await self.refreshForegroundOnHealthyTransport(
                                using: client,
                                probeRead: probeRead,
                                freshnessCheckArmed: freshnessCheckArmed,
                                reconciliationToken: token,
                                automaticWorkToken: automaticWorkToken
                            )
                        }
                    } catch {
                        guard self.scenePhaseAttemptIsCurrent(sceneAttemptID) else {
                            self.settleReconciliation(token)
                            return
                        }
                        if !self.automaticChatResumeWorkIsCurrent(automaticWorkToken) {
                            // The automatic intent was invalidated mid-check
                            // (composer edit, explicit viewport action): the
                            // user owns the visible conversation, so repair
                            // the transport without letting recovery select a
                            // session.
                            self.settleReconciliation(token)
                            await self.reconnectForRetry(purpose: .preserveCurrent)
                        } else {
                            lifecycleLog.notice(
                                "Foreground refresh: health check failed (\(error.localizedDescription, privacy: .private)); reconnecting"
                            )
                            await self.reconnectForRetry(
                                purpose: self.foregroundRecoveryPurpose
                            )
                            self.settleReconciliation(token)
                        }
                    }
                } else {
                    guard self.scenePhaseAttemptIsCurrent(sceneAttemptID) else {
                        self.settleReconciliation(token)
                        return
                    }
                    if !self.automaticChatResumeWorkIsCurrent(automaticWorkToken) {
                        self.settleReconciliation(token)
                        await self.reconnectForRetry(purpose: .preserveCurrent)
                    } else {
                        lifecycleLog.notice(
                            "Foreground refresh start: transport=missing-or-unhealthy; reconnecting"
                        )
                        await self.reconnectForRetry(
                            purpose: self.foregroundRecoveryPurpose
                        )
                        self.settleReconciliation(token)
                    }
                }
                // Voice restoration runs here — after the authoritative
                // reconciliation above established transport and session
                // state — and only while this attempt is still current. A
                // pending suspended conversation forces a capability refresh
                // first: the pre-background snapshot cannot be trusted across
                // suspension, and restoration must fail closed when the
                // refreshed state says a fresh open would be rejected.
                if self.scenePhaseAttemptIsCurrent(sceneAttemptID) {
                    await self.refreshCapabilitiesAndRestoreSuspendedVoice(
                        isCurrent: { self.scenePhaseAttemptIsCurrent(sceneAttemptID) }
                    )
                }
            }
            scenePhaseTask = task
            return task

        case .background:
            // A shared draft whose chat was still opening waits on disk for
            // the next time Conduit is on screen.
            sharedDraftLaunch = nil
            publishShareDraftSettings()
            widgetLaunchCoordinator.supersede()
            // Only a departure from active counts: coming back passes
            // through .inactive too, and that is not "last used".
            if isSceneActive, sceneHasBeenActive {
                lastLeftForegroundAt = Date()
                noteChatLeft(activeSessionId)
            }
            isSceneActive = false
            disarmWakeListeningForBackground()
            hasEnteredBackgroundScenePhase = true
            sceneHidesLiveRows = true
            pauseLivePublishes()
            // Audio may keep the socket open off screen; it pings less.
            client?.setKeepaliveBackgrounded(true)
            endQuietReturn()
            // Without audio, iOS suspends Conduit at once and the socket
            // stops answering Hermes' pings: hold the process a little so a
            // quick trip to another app doesn't cost a reconnect.
            if client?.isConnected == true {
                backgroundConnectionGrace.begin()
            }
            // The socket can die while suspended and turn edges can be missed,
            // so the local turn state must be re-confirmed against the
            // authoritative runtime registry before the next composer submit
            // decides between a new turn and a busy submission.
            turnStateIsStale = true
            // Snapshot the pre-suspension liveness evidence and arm the
            // cross-surface freshness check: while suspended, another Hermes
            // surface can start or finish turns whose stream events Conduit
            // will never see (the socket may not survive the suspension).
            preSuspensionTurnRunningSessionIDs = turnState.isRunning
                ? acceptedIdentitySessionIDs(forRequested: activeSessionId ?? "")
                : []
            // A locally-owned in-flight turn is only continuity evidence
            // while this conversation's turn is unsettled. A SETTLED turn
            // (idle, or the unsupported-gateway dead end) expires the marker;
            // .synchronizing/.reconnecting are mid-recovery, not settle —
            // the turn may still be live, so the marker survives them. A
            // marker left over from another session never survives.
            if turnState == .idle || turnState == .unsupportedGateway {
                locallyOwnedInFlightTurn = nil
            } else if let marker = locallyOwnedInFlightTurn,
                      let active = activeSessionId,
                      !marker.sessionIDs.contains(active) {
                locallyOwnedInFlightTurn = nil
            }
            foregroundFreshnessCheckArmed = true
            // A reply already reading aloud keeps playing in the background
            // (#373); this only refuses new taps until the app is back.
            messageReadAloudController.setForegroundActive(false)
            // The app-foreground fact changed here regardless of which branch
            // below runs: the phone scene is gone, so only CarPlay or a
            // conversation kept running while locked can still count as a
            // foreground surface.
            voiceConversationController.setApplicationForegroundActive(hasForegroundApplicationSurface)
            voiceConversationController.setBackgroundListening(isLockedVoiceSurfaceActive || isNativeCallVoiceSurfaceActive)
            // Suspension is not Close: an open Voice conversation releases its
            // runtime ownership and is recorded for foreground restoration,
            // and the sheet presentation intentionally survives the
            // background transition. The exception is another active Voice
            // presentation surface: with CarPlay presenting the shared
            // conversation, the phone backgrounding is NOT a Voice lifecycle
            // boundary — Voice must stay live for the driver — so the
            // suspension (and its restoration descriptor) is skipped
            // entirely. "Keep listening when locked" makes an open, running
            // conversation such a surface too.
            if hasActiveVoiceSurface {
                voiceConversationController.setForegroundActive(true)
            } else {
                suspendVoiceConversationForBackground()
            }
            // Drop any armed reconnect timer as well: in-flight cycles abort
            // at their next transportContinuation checkpoint, and foreground
            // activation re-establishes the transport.
            cancelScheduledReconnect()
            // Unless CarPlay still presents Voice: then the driver is relying
            // on the transport right now, so a dropped cycle is re-armed.
            recoverTransportForCarPlayIfNeeded()
            // Flush any pending coalesced cache writes before the app
            // suspends — iOS may kill the process before the debounce fires.
            // The caches write on background queues: hold a background task
            // until those writes land. Never block the main thread on those
            // queues here (see SessionPresentationCache.waitForPendingWrites).
            flushPendingPresentationCache()
            // The Chats list as it shows now, for the next cold launch.
            recordSavedChatList()
            holdBackgroundTaskUntilCacheWritesLand()
            // A suspended socket may still look open. Invalidate incomplete
            // snapshots so foreground always obtains a fresh authoritative one.
            invalidateReconciliation()
            cancelScenePhaseAttempt()
            return nil

        case .inactive:
            // Only a departure from active counts: coming back passes
            // through .inactive too, and that is not "last used".
            if isSceneActive, sceneHasBeenActive {
                lastLeftForegroundAt = Date()
                noteChatLeft(activeSessionId)
            }
            isSceneActive = false
            if !inactiveSceneStaysInView {
                sceneHidesLiveRows = true
                pauseLivePublishes()
            }
            disarmWakeListeningForBackground()
            // Same reasoning as .background: a dip through Control Center or a
            // system overlay can miss turn edges. This never causes a resume —
            // the foreground path treats staleness as a read-only probe.
            turnStateIsStale = true
            // Capture the continuity evidence (an in-flight Conduit turn stays
            // the same turn across a dip) but do NOT arm the freshness check:
            // the socket survives overlay dips, so live events kept flowing.
            preSuspensionTurnRunningSessionIDs = turnState.isRunning
                ? acceptedIdentitySessionIDs(forRequested: activeSessionId ?? "")
                : []
            // Reconnects are suppressed during .inactive too, so an armed
            // timer would only fire to be discarded. Drop it here; a socket
            // that dies under a system overlay (incoming call, control
            // center) is recovered by the .active scene task — the same
            // moment the user can see the transcript again. The exception is
            // a connected CarPlay Voice surface, which admits recovery on its
            // own: re-arm for it, exactly as the .background branch does.
            cancelScheduledReconnect()
            recoverTransportForCarPlayIfNeeded()
            // The scene treats .inactive like .background for reconnect
            // purposes; formally abort the in-flight scene attempt at the
            // transition too, rather than at its next checkpoint.
            cancelScenePhaseAttempt()
            chatResumeCoordinator.freezeViewport()
            messageReadAloudController.setForegroundActive(false)
            // A transient .inactive dip (Control Center, an incoming-call
            // banner, the microphone permission prompt) is NOT a lifecycle
            // suspension: the socket and audio session survive, in-flight
            // turns keep flowing, and a pending first-listen must survive the
            // dip. Voice suspension happens only on the actual .background
            // transition — a descriptor-less suspension here would tear the
            // runtime down with no restoration path.
            //
            // The Voice gates are deliberately NOT republished here, leaving
            // the app-foreground gate at its last value. This branch runs
            // while iOS presents a permission alert the voice flow awaited —
            // the first-run microphone alert over a fresh sheet's auto-listen
            // — and republishing would fence `startListening`'s
            // `isCurrent`-checked continuation during the alert, so every
            // grant would kill the listen it was granted for. Only `.active`
            // and `.background` state the fact.
            return nil

        @unknown default:
            return nil
        }
    }

    private func scenePhaseAttemptIsCurrent(_ id: UUID) -> Bool {
        !Task.isCancelled && scenePhaseAttemptID == id
    }

    private func beginQuietReturn() {
        quietReturnTask?.cancel()
        isReturningQuietly = true
        quietReturnTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.quietReturnWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.isReturningQuietly = false
            self?.quietReturnTask = nil
        }
    }

    func beginQuietReturnForTesting() {
        beginQuietReturn()
    }

    func endQuietReturn() {
        quietReturnTask?.cancel()
        quietReturnTask = nil
        if isReturningQuietly { isReturningQuietly = false }
    }

    /// Background transition for the Voice conversation. An open Voice sheet
    /// routes through the controller's lifecycle suspension — runtime
    /// ownership released, logical conversation preserved — and records the
    /// suspended descriptor for foreground restoration. A closed Voice sheet
    /// keeps the existing full-stop semantics. Transient .inactive dips never
    /// reach this: they leave Voice untouched.
    ///
    /// Callers guarantee no other legitimate Voice presentation surface is
    /// active (`hasActiveVoiceSurface == false`): a CarPlay-presented
    /// conversation skips this path on phone backgrounding, and the CarPlay
    /// disconnect handler routes through it when the phone scene is inactive
    /// so both boundaries share exactly one release/restore contract.
    func suspendVoiceConversationForBackground() {
        // Suspension disarms the fresh-open auto-listen intent: the restored
        // sheet must never hot-start the microphone, even if SwiftUI
        // recreates the sheet's view identity while the binding stays true.
        voiceSheetShouldAutoListen = false
        voiceConversationController.setForegroundActive(false)
        guard showVoiceSheet else {
            voiceConversationController.stop()
            return
        }
        voiceConversationController.suspendRuntimeForLifecycle()
        suspendedVoiceConversation = SuspendedVoiceConversation(
            profile: activeProfile,
            sessionID: activeSessionId ?? "",
            serverIdentity: Self.voiceSuspensionServerIdentity(connection)
        )
    }

    /// Consumes the suspended Voice descriptor on foreground return. Called
    /// ONLY after the foreground reconciliation task has established the
    /// authoritative transport/session state (or definitively failed) — never
    /// synchronously at the scene transition, when the socket, bridge, and
    /// runtime session identity may all still be stale.
    ///
    /// Validation is synchronous against that post-reconciliation state: the
    /// same authoritative predicate as a fresh `openVoiceConversation`
    /// (`canStartVoiceConversation`: live connection, voice enabled, usable
    /// transcription AND speech) plus the suspended conversation's identity —
    /// same active profile, and the active runtime session is still the
    /// suspended conversation (unchanged, or a legitimate rebind per the
    /// session catalog/alias machinery). Anything stale fails CLOSED. A valid
    /// descriptor reinstalls the gateway and settles open-but-NON-listening;
    /// capture is NEVER started by restoration (Continuous Conversation
    /// governs turn-to-turn continuation only, not lifecycle transitions).
    func restoreSuspendedVoiceConversationIfNeeded() {
        guard let suspended = suspendedVoiceConversation else { return }
        suspendedVoiceConversation = nil
        let conversationStillMatches = suspended.sessionID == activeSessionId
            || knownSessionIDs(for: suspended.sessionID).contains(activeSessionId ?? "")
        let identityStillValid = suspended.profile == activeProfile
            && !suspended.sessionID.isEmpty
            && conversationStillMatches
            && connection != nil
            && suspended.serverIdentity == Self.voiceSuspensionServerIdentity(connection)
            && canStartVoiceConversation
            && showVoiceSheet
            && voiceConversationController.hasLiveVoiceSession
        guard identityStillValid else {
            if showVoiceSheet {
                if suspended.profile == activeProfile {
                    closeVoiceConversation()
                } else {
                    // Cross-profile staleness: the suspended controller's
                    // live mute belongs to the descriptor's profile. Tear
                    // down directly — closeVoiceConversation would persist
                    // that mute into the now-active profile's preferences.
                    voiceConversationController.stop()
                    voiceSheetShouldAutoListen = false
                    voiceControllerSessionProfile = nil
                    showVoiceSheet = false
                }
            }
            return
        }
        // Rebuild the gateway from the current bridge/connection; the
        // controller keeps its preserved conversation identity and
        // preferences, settled in .idle.
        refreshVoiceControllerGateway()
        // The capability checks above passed, so a gateway that still could
        // not be built (e.g. the bridge rotated under us) is staleness too:
        // fail closed instead of restoring an open-but-dead sheet.
        if !voiceConversationController.isGatewayAttached {
            closeVoiceConversation()
        }
    }

    /// Refreshes Voice capability state when a suspended Voice conversation
    /// is pending, then validates/restores. The pre-background capability
    /// snapshot cannot be trusted across suspension, so restoration must run
    /// against a freshly negotiated answer; `isCurrent` is re-checked after
    /// that await so a superseded attempt never consumes the descriptor.
    /// Without a pending descriptor this is a no-op — a plain foreground
    /// return never pays a redundant capability network refresh here.
    func refreshCapabilitiesAndRestoreSuspendedVoice(isCurrent: @MainActor () -> Bool) async {
        guard suspendedVoiceConversation != nil else { return }
        // The central refreshVoiceCapabilities authority preserves the live
        // in-session mute for the owning profile during this refresh, so the
        // restored session keeps the user's Mute state.
        await refreshVoiceCapabilities()
        guard isCurrent() else { return }
        restoreSuspendedVoiceConversationIfNeeded()
    }

    private static func voiceSuspensionServerIdentity(_ connection: HermesConnection?) -> String? {
        guard let baseURL = connection?.baseUrl else { return nil }
        return normalizedChatResumeServerIdentity(baseURL)
    }

    func cancelScenePhaseAttempt() {
        let hadAttempt = scenePhaseAttemptID != nil
        scenePhaseAttemptID = nil
        scenePhaseTask?.cancel()
        scenePhaseTask = nil
        cancelOwnedAutomaticOperations()
        // The cancelled attempt's finish no longer matches and says
        // nothing, so a waiting widget hears it here.
        if hadAttempt, widgetForegroundReady { widgetLaunchCoordinator.readinessChanged() }
    }

    private func finishScenePhaseAttempt(id: UUID) {
        guard scenePhaseAttemptID == id else { return }
        scenePhaseAttemptID = nil
        scenePhaseTask = nil
        if widgetForegroundReady { widgetLaunchCoordinator.readinessChanged() }
    }

    var turnStateLogValue: String {
        switch turnState {
        case .synchronizing: return "synchronizing"
        case .idle: return "idle"
        case .running: return "running"
        case .reconnecting: return "reconnecting"
        case .unsupportedGateway: return "unsupportedGateway"
        }
    }
}
