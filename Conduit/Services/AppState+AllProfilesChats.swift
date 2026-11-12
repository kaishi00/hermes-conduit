//
//  AppState+AllProfilesChats.swift
//  Conduit
//
//  Moved out of AppState.swift (issue 828): All profiles in one Chats list.
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

// MARK: - All profiles in one Chats list

extension AppState {
    /// The profile a listed row belongs to: the one in use, or, for another
    /// profile's row in the Chats list's All view, the listed profile its
    /// tag names. A row tagged with a profile this dashboard doesn't list
    /// stays with the one in use, as before All.
    func rowProfile(_ session: SessionSummary) -> String {
        guard let owner = session.profile,
              !sessionBelongsToProfile(session, profile: activeProfile),
              let listed = AllProfilesChats.profile(named: owner, in: profiles) else { return activeProfile }
        return listed
    }

    /// Another profile's row in All: it opens with a switch to its profile.
    func isOtherProfileRow(_ session: SessionSummary) -> Bool {
        rowProfile(session) != activeProfile
    }

    /// All's settings on the dashboard in use.
    var allProfilesChats: AllProfilesChatsSettings.Dashboard {
        allProfilesChatsSettings[dashboard: activeDashboardID]
    }

    /// The Chats list shows All: it is on here, and the dashboard lists two
    /// or more profiles.
    var isAllProfilesChatsOn: Bool {
        allProfilesChats.isOn && AllProfilesChats.isAvailable(profiles: profiles)
    }

    /// The profiles All lists, in the strip's order.
    var allProfilesIncluded: [String] {
        AllProfilesChats.included(profiles, excluded: allProfilesChats.excluded)
    }

    /// All is on and splits into a section per profile.
    var allProfilesGroupsByProfile: Bool {
        isAllProfilesChatsOn && allProfilesChats.groupsByProfile
    }

    func setAllProfilesChatsOn(_ on: Bool) {
        updateAllProfilesChats { $0.isOn = on }
        if on { refreshAllProfilesCatalog() }
    }

    func setAllProfilesGroupsByProfile(_ grouped: Bool) {
        updateAllProfilesChats { $0.groupsByProfile = grouped }
    }

    /// Puts a profile in All or leaves it out. The last one in stays: All
    /// never lists nothing.
    func setProfile(_ profile: String, includedInAll included: Bool) {
        guard included || allProfilesIncluded.count > 1 else { return }
        updateAllProfilesChats { settings in
            settings.excluded.removeAll { Self.profilesMatch($0, profile) }
            if !included { settings.excluded.append(profile) }
        }
    }

    private func updateAllProfilesChats(_ change: (inout AllProfilesChatsSettings.Dashboard) -> Void) {
        var settings = allProfilesChatsSettings
        var dashboard = settings[dashboard: activeDashboardID]
        change(&dashboard)
        settings[dashboard: activeDashboardID] = dashboard
        guard settings != allProfilesChatsSettings else { return }
        allProfilesChatsSettings = settings
        settings.save(to: defaults)
    }

    /// The Chats list's chats: in All, every included profile's, newest
    /// first; otherwise the profile in use's (`listedSessions`).
    var chatListSessions: [SessionSummary] {
        guard isAllProfilesChatsOn else { return listedSessions }
        return AllProfilesChats.rows(
            active: activeProfile,
            activeRows: listedSessions,
            combined: allProfilesCatalog.dashboardID == activeDashboardID ? allProfilesCatalog.sessions : [],
            included: allProfilesIncluded
        )
    }

    /// Cron runs stay with their own profile's list: All shows the profile
    /// in use's, while it is included.
    var chatListCronSessions: [SessionSummary] {
        guard isAllProfilesChatsOn else { return listedCronSessions }
        return allProfilesIncluded.contains { Self.profilesMatch($0, activeProfile) } ? listedCronSessions : []
    }

    /// Reads every profile's chats for All, one read at a time. The profile
    /// in use keeps its own list and poll; this brings the others'.
    func refreshAllProfilesCatalog() {
        guard isAllProfilesChatsOn, allProfilesCatalogTask == nil, let bridge = dashboardTicketBridge else { return }
        let dashboardID = activeDashboardID
        let read = UUID()
        allProfilesCatalogRead = read
        allProfilesCatalogTask = Task { @MainActor [weak self] () -> Void in
            guard let self else { return }
            await self.readAllProfilesCatalog(using: bridge, dashboardID: dashboardID)
            // A reset since may have started a newer read.
            if self.allProfilesCatalogRead == read { self.allProfilesCatalogTask = nil }
        }
    }

    /// All's poll while the list shows. Slower than the profile in use's
    /// own: Hermes opens every profile's database for it. Off screen (voice,
    /// Read Aloud or CarPlay keeping the app running) nothing reads, as with
    /// the chat list's own poll (issue 1728).
    func runAllProfilesCatalogPolling() async {
        while !Task.isCancelled {
            if isSceneActive { refreshAllProfilesCatalog() }
            try? await Task.sleep(for: .seconds(20))
        }
    }

    private func readAllProfilesCatalog(using bridge: DashboardTicketBridge, dashboardID: UUID?) async {
        do {
            let response = try await bridge.requestJSON(path: AllProfilesChats.sessionsPath)
            let batch = response["sessions"] as? [Any] ?? []
            let rows = await Self.convertAllProfilesPage(batch)
            // A dashboard switched meanwhile has its own profiles.
            guard activeDashboardID == dashboardID, dashboardTicketBridge === bridge else { return }
            listAllProfilesCatalog(rows, dashboardID: dashboardID)
        } catch {
            // A failed read keeps what All showed; the next poll asks again.
            sessionCatalogLog.notice("All profiles' chats unavailable: \(LogRedaction.describing(error), privacy: .public)")
        }
    }

    /// Nonisolated and async: runs on the generic executor, off main.
    nonisolated private static func convertAllProfilesPage(_ batch: [Any]) async -> [SessionSummary] {
        MessageNormalizer.normalizeSessions(
            AnyCodable.from(["sessions": batch]),
            profile: nil
        ).filter { $0.profile != nil && $0.messageCount != 0 && !$0.isArchived }
    }

    /// Other profiles' rows as a mixed list shows them (All, a project page
    /// gathering profiles): a bot's chats belong to its Bot Chat, as in each
    /// profile's own list, and a workstream's to its bot.
    func otherProfileRowsShown(_ rows: [SessionSummary]) -> [SessionSummary] {
        let botOwned = botOwnedSessionIDs
        return rows.filter { session in
            !BotChatHygiene.isCanonicalBotChatRow(session, roster: botRoster)
                && !BotChatHygiene.isBotOwnedRow(session, botOwnedSessionIDs: botOwned)
                && !isWorkstreamRow(session)
        }
    }

    private func listAllProfilesCatalog(_ rows: [SessionSummary], dashboardID: UUID?) {
        let kept = otherProfileRowsShown(rows)
        // Each other profile's rows are noted the way its own list notes
        // them, so a reply that lands there later lights its dot here.
        // A row whose profile isn't listed goes in no group.
        let others = AllProfilesChats.groups(kept, profiles: profiles, fallback: "", owner: { $0.profile })
            .filter { !$0.profile.isEmpty && !Self.profilesMatch($0.profile, activeProfile) }
        if !others.isEmpty {
            updateChatReadState { state in
                for group in others { _ = state.observe(group.items, profile: group.profile) }
            }
        }
        let next = AllProfilesCatalog(dashboardID: dashboardID, sessions: kept, isLoaded: true)
        if next != allProfilesCatalog { allProfilesCatalog = next }
    }

    func updateAllProfilesCatalogRow(_ session: SessionSummary, _ change: (inout SessionSummary) -> Void) {
        guard let index = allProfilesCatalog.sessions.firstIndex(where: {
            $0.id == session.id && Self.profilesMatch($0.profile ?? "", session.profile ?? "")
        }) else { return }
        change(&allProfilesCatalog.sessions[index])
    }

    private func removeFromAllProfilesCatalog(_ session: SessionSummary) {
        let ids = Set(session.nestingIDs)
        allProfilesCatalog.sessions.removeAll {
            Self.profilesMatch($0.profile ?? "", session.profile ?? "") && !ids.isDisjoint(with: $0.nestingIDs)
        }
    }

    /// A message hit in another profile's chat that All hasn't listed: its
    /// link's way, refused with a notice during a call.
    func openOtherProfileChat(_ id: String, inProfile profile: String) {
        guard !isVoiceCallInProgress else {
            showSessionMutationNotice(AppLocalization.string("End the call to open a chat in another profile."))
            return
        }
        Task { await routeLinkedSession(id, toProfile: profile) }
    }

    /// A project page's New conversation in a folder, here or in `profile`
    /// after a switch to it: a page gathering profiles asks which (issue
    /// 1761). A switch ends a call, so none while one is up.
    func createNewSession(cwd: String, inProfile profile: String) {
        guard !Self.profilesMatch(profile, activeProfile) else {
            Task { await self.createNewSession(cwd: cwd) }
            return
        }
        guard !isVoiceCallInProgress else {
            showSessionMutationNotice(AppLocalization.string("End the call to open a chat in another profile."))
            return
        }
        let refusal = AppLocalization.string("End the call to open a chat in another profile.")
        let seen = chatViewportTransitionGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Only a switch that went through: one a newer navigation or a
            // call superseded starts nothing.
            guard await self.switchProfile(to: profile, reusing: nil, refusingCallsWith: refusal, navigationSeenAt: seen) else { return }
            await self.createNewSession(cwd: cwd)
        }
    }

    /// New Chat from All's menu: here, or in `profile` after a switch to
    /// it. A switch ends a call, so none while one is up.
    func startNewChat(inProfile profile: String) {
        guard profile != activeProfile else {
            startNewChat()
            return
        }
        guard !isVoiceCallInProgress else {
            showSessionMutationNotice(AppLocalization.string("End the call to open a chat in another profile."))
            return
        }
        let refusal = AppLocalization.string("End the call to open a chat in another profile.")
        let seen = chatViewportTransitionGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            // As createNewSession(cwd:inProfile:): a superseded switch
            // starts nothing.
            guard await self.switchProfile(to: profile, reusing: nil, refusingCallsWith: refusal, navigationSeenAt: seen) else { return }
            self.startNewChat()
        }
    }

    // Another profile's row in All goes to Hermes under its own profile,
    // and its result lands in All's list. Nothing here touches the profile
    // in use's catalog or open chat.

    func archiveOtherProfileSession(_ session: SessionSummary) async -> Bool {
        let profile = rowProfile(session)
        guard sessionMutationCanStart(hasTransport: dashboardTicketBridge != nil),
              let owner = currentDashboardRuntimeOwner() else { return false }
        sessionMutationID = session.id
        defer { sessionMutationID = nil }
        do {
            try await sendSessionMutation(session.id, body: ["archived": true], profile: profile, bridge: owner.bridge)
            guard ownsDashboardRuntime(owner) else { return false }
            sessionYoloStore.clearOverride(for: profile, sessionIDs: [session.id] + session.alternateIds)
            setLocalPin(session, pinned: false, profile: profile)
            removeFromAllProfilesCatalog(session)
            return true
        } catch {
            guard ownsDashboardRuntime(owner) else { return false }
            showSessionMutationNotice(AppLocalization.string("Could not archive this conversation: \(UserFacingError.message(for: error))"))
            return false
        }
    }

    func deleteOtherProfileSession(_ session: SessionSummary) async -> Bool {
        let profile = rowProfile(session)
        let dashboardID = activeDashboardID
        guard sessionMutationCanStart(hasTransport: dashboardTicketBridge != nil),
              let owner = currentDashboardRuntimeOwner() else { return false }
        sessionMutationID = session.id
        defer { sessionMutationID = nil }
        let deletedSessionIDs = Set(session.nestingIDs)
        do {
            try await sendSessionMutation(session.id, body: nil, profile: profile, bridge: owner.bridge)
            // Hermes deleted it: its saved copy and pinned replies go too,
            // whatever the screen shows now (#1040).
            if let dashboardID {
                removeSavedCopies(ofDeleted: deletedSessionIDs, dashboardID: dashboardID, profile: profile)
            }
            dropPinnedReplies(forDeleted: session, profile: profile)
            // A call in it (a Bot Chat call's, say) goes on in a new chat (issue 1797).
            voiceBackgroundJobSupervisor.noteChatDeleted(deletedSessionIDs)
            guard ownsDashboardRuntime(owner) else { return false }
            sessionYoloStore.clearOverride(for: profile, sessionIDs: Array(deletedSessionIDs))
            revokeDeletedConversationIdentity(sessionIDs: deletedSessionIDs, profile: profile)
            removeFromAllProfilesCatalog(session)
            setLocalPin(session, pinned: false, profile: profile)
            setSessionStarred(session, starred: false, profile: profile)
            updateChatReadState { $0.forget(session, profile: profile) }
            return true
        } catch DashboardTicketBridgeError.answeredAfterSwitch {
            if let dashboardID {
                removeSavedCopies(ofDeleted: deletedSessionIDs, dashboardID: dashboardID, profile: profile)
            }
            return false
        } catch {
            guard ownsDashboardRuntime(owner) else { return false }
            showSessionMutationNotice(AppLocalization.string("Could not delete this conversation: \(UserFacingError.message(for: error))"))
            return false
        }
    }

    /// Hermes deleted the chats `sessionIDs` name: their saved copies leave
    /// the phone (#1040), and their rows the profile's kept Artifacts page,
    /// as their own kept lists do (#1533).
    func removeSavedCopies(ofDeleted sessionIDs: Set<String>, dashboardID: UUID, profile: String) {
        offlineChatCache.removeTranscripts(sessionIDs: sessionIDs, dashboardID: dashboardID, profile: profile)
        forgetLeftBackfilledTranscripts(dashboardID: dashboardID, sessionIDs: sessionIDs)
        for showMissing in [true, false] {
            guard let route = ArtifactsClient.keptRoute(ArtifactSource(profile: profile, sessionIDs: []), filter: .all,
                                                        query: "", showMissing: showMissing),
                  let kept = offlineChatCache.keptAnswer(route, dashboardID: dashboardID, profile: profile),
                  let left = ArtifactsClient.answer(kept, withoutRowsOf: sessionIDs) else { continue }
            offlineChatCache.recordAnswer(left, route: route, dashboardID: dashboardID, profile: profile)
        }
    }

    func renameOtherProfileSession(_ session: SessionSummary, to title: String) async -> Bool {
        let profile = rowProfile(session)
        guard SessionRenameOperation.normalizedTitle(title, currentTitle: session.title) != nil,
              sessionMutationCanStart(hasTransport: dashboardTicketBridge != nil),
              let owner = currentDashboardRuntimeOwner() else { return false }
        sessionMutationID = session.id
        defer { sessionMutationID = nil }
        // Not the open chat's: only the stored title changes.
        let operations = SessionRenameOperation.Operations(
            renameRuntime: nil,
            renameStored: { [weak self] sessionID, newTitle in
                guard let self, self.ownsDashboardRuntime(owner) else {
                    throw SessionRenameOperation.ContextChanged()
                }
                try await self.sendSessionMutation(
                    sessionID,
                    body: ["title": newTitle],
                    profile: profile,
                    bridge: owner.bridge
                )
            }
        )
        do {
            guard let result = try await SessionRenameOperation.perform(
                session: session,
                activeSessionID: nil,
                title: title,
                operations: operations
            ), ownsDashboardRuntime(owner) else { return false }
            updateAllProfilesCatalogRow(session) { $0.title = result.title }
            return true
        } catch is SessionRenameOperation.ContextChanged {
            return false
        } catch {
            guard ownsDashboardRuntime(owner) else { return false }
            showSessionMutationNotice(SessionRenameOperation.failureMessage(error))
            return false
        }
    }
}
