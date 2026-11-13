//
//  AppState+OneChatTwoDevices.swift
//  Conduit
//
//  Moved out of AppState.swift (issue 828): One chat on two devices.
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - One chat on two devices

    /// The Chats list's poll loop, while the list shows. Each tick says how
    /// long to wait before the next; a return to the app, a send or a
    /// search cuts the wait short (`noteChatListInteraction`).
    func runChatListPolling() async {
        chatListPollPacer.reset()
        chatListPollSleep.clearPendingWake()
        while !Task.isCancelled {
            let delay = await chatListPollTick()
            guard !Task.isCancelled else { return }
            await chatListPollSleep.sleep(seconds: delay)
        }
    }

    /// Something happened that the list should catch up with soon: the
    /// next poll comes at once, then at the shortest interval.
    func noteChatListInteraction() {
        chatListPollPacer.reset()
        chatListPollSleep.wake()
    }

    /// The Chats list's poll: the live registry, then what it says about
    /// the list and the open chat behind it. A chat the registry has and
    /// the list doesn't, one started on another device, reads the catalog
    /// again; so does a list left on screen for 30 s, for renames and
    /// deletions made elsewhere (5 minutes on a gateway that pushes
    /// `sessions.changed`, which reads them as they come, and 30 s again
    /// while a change waits on a turn running here). Reads go through
    /// the coalesced read Back uses. Returns the wait before the next tick:
    /// 4 s while a turn runs or something on the list changed, then 8, 15,
    /// 30 and 60 s while nothing moves, and 120 s with change events
    /// (PollCadence), stretched in Low Power and Low Data Mode.
    @discardableResult
    func chatListPollTick() async -> TimeInterval {
        let followsChanges = client?.sendsChangeEvents == true
        // Off screen (voice or CarPlay keep the app running) nothing reads.
        guard sceneIsInView, isConnected else {
            return PollCadence.stretched(chatListPollPacer.interval(followingChanges: followsChanges), by: deviceConditions())
        }
        let registryRead = await refreshLiveSessionStatuses()
        // Left the screen, or the poll stopped, while the registry read was
        // on its way: nothing more reads.
        guard sceneIsInView, !Task.isCancelled else {
            return PollCadence.stretched(chatListPollPacer.interval(followingChanges: followsChanges), by: deviceConditions())
        }
        var registry: Set<String>?
        let listed = chatListListedIDs()
        // Only the chats the list shows pace it: not a Bot Chat, a
        // workstream or another profile's chat the catalog has but the list
        // hides.
        let displayed = chatListDisplayedIDs()
        // The open chat's turn paces the list only when it is one of the
        // list's chats: a Bot Chat's turn behind it isn't (see below).
        var turnRunning = turnState.isRunning && activeSessionId.map(displayed.contains) == true
        if let snapshot = freshActiveListSnapshot(maxAge: 2) {
            // A chat started elsewhere is about to be listed: the poll
            // stays quick to follow it.
            if noteActiveListForChatList(snapshot.rows, listed: listed) { chatListPollPacer.reset() }
            // The open chat shows beside the list in the persistent iPad
            // sidebar, and is covered by it otherwise.
            observeOpenChat(in: snapshot, chatVisible: !showSidebar)
            // Only the list's own chats pace it: a bot's or a cron job's
            // runtime working all day mustn't keep it at 4 s. A chat the
            // list doesn't have yet is read above, and the read that lists
            // it changes the list.
            let listedRows = snapshot.rows.filter { displayed.contains($0.storedSessionId) }
            registry = ChatListPollPacer.registryKeys(listedRows)
            turnRunning = turnRunning || listedRows.contains(where: ChatListPollPacer.isTurnRunning)
        } else if registryRead {
            // A gateway without the registry answers nothing to compare:
            // an empty one, so the list backs off.
            registry = []
        }
        // All's rows from other profiles pace it too, by their own
        // profiles' registries, so one's Running ends as soon as its own does.
        if let registry0 = registry, isAllProfilesChatsOn {
            let others = otherProfilesListedLiveRows(Self.chatListIDs(of: allProfilesCatalog.sessions))
            registry = registry0.union(others.keys)
            turnRunning = turnRunning || others.running
        }
        // A gateway that pushes `sessions.changed` has each change read as
        // it comes: the timed read is only its backstop (issue 851). One
        // held back by a turn here keeps the 30 s read, so a chat deleted
        // elsewhere during a long reply leaves as it did before.
        let fallback = followsChanges && !catalogChangeSignal.isPending
            ? ChatListCatalogFreshness.fallbackIntervalFollowingChanges
            : ChatListCatalogFreshness.fallbackInterval
        if chatListCatalogFreshness.shouldRead(olderThan: fallback, now: chatSyncNow()) {
            refreshCatalogAfterLeavingChat(reportingFailure: false)
        }
        readPendingCatalogChange()
        return chatListPollPacer.next(
            after: .init(
                registry: registry,
                turnRunning: turnRunning,
                catalogGeneration: chatListCatalogGeneration,
                followsChanges: followsChanges,
                inactiveFor: isSceneActive ? nil : lastLeftForegroundAt.map { max(0, Date().timeIntervalSince($0)) }
            ),
            conditions: deviceConditions(),
            random: pollJitter()
        )
    }

    /// Back in the app with the list on screen: a read older than 10 s is
    /// read again. (A return from the background also syncs the chat, which
    /// reads the catalog too; an overlay dip doesn't.)
    func chatListBecameActive() {
        if chatListCatalogFreshness.shouldRead(olderThan: ChatListCatalogFreshness.sceneActiveInterval, now: chatSyncNow()) {
            refreshCatalogAfterLeavingChat(reportingFailure: false)
        }
    }

    /// Every id the catalog's chats go by, shown or hidden: a live chat
    /// with none of these reads the catalog again.
    private func chatListListedIDs() -> Set<String> {
        // A new chat made here is listed only until Hermes lists it: the
        // registry still reads the catalog in for it, its title included.
        Self.chatListIDs(of: sessions + cronSessions + archivedSessions)
            .subtracting(openNewChatAwaitingListing?.ids ?? [])
    }

    /// Every id the chats the list shows go by: the profile's own, without
    /// the Bot Chats and workstreams it hides.
    private func chatListDisplayedIDs() -> Set<String> {
        Self.chatListIDs(of: activeProfileSessions + activeProfileCronSessions + archivedSessions)
    }

    static func chatListIDs(of rows: [SessionSummary]) -> Set<String> {
        var listed = Set<String>()
        for session in rows {
            listed.insert(session.id)
            if let stored = session.storedSessionId { listed.insert(stored) }
            if let root = session.lineageRootId { listed.insert(root) }
            listed.formUnion(session.alternateIds)
        }
        return listed
    }

    /// Returns whether it asked for a catalog read.
    @discardableResult
    private func noteActiveListForChatList(_ rows: [LiveSessionStatus], listed: Set<String>) -> Bool {
        let unlisted = rows.filter { !$0.storedSessionId.isEmpty && !listed.contains($0.storedSessionId) }
        // Keyed by the row's state too: a chat created on another device is
        // live before its first message makes it listable, and that message
        // (working, then a new count) asks again.
        let keys = Set(unlisted.map { "\($0.storedSessionId)|\($0.status)|\($0.messageCount ?? -1)" })
        guard chatListCatalogFreshness.shouldRead(forUnlisted: keys, now: chatSyncNow()) else { return false }
        sessionCatalogLog.notice(
            "Chat list: \(unlisted.count, privacy: .public) live chat(s) not listed yet; reading the catalog again"
        )
        refreshCatalogAfterLeavingChat(reportingFailure: false)
        return true
    }

    /// The open chat shows (again), or the app came back: its idle check
    /// starts over at the shortest interval.
    func openChatSyncBecameVisible() {
        openChatSync.resetIdlePace()
    }

    /// The open chat's check while it is on screen (ChatView, every few
    /// seconds and on each turn edge). A turn running here that streamed
    /// nothing for 20 s, or an idle chat, is checked against the registry;
    /// a snapshot the list read in the last 5 s is reused.
    func openChatSyncTick() async {
        guard isSceneActive, isConnected, let client,
              client !== activeListUnsupportedClient,
              let local = openChatLocalTurn() else {
            setActiveChatRepliesElsewhere(false)
            return
        }
        // A `sessions.changed` held back by a turn here is read once it ends.
        readPendingCatalogChange()
        let due = openChatSync.checkDue(local, now: chatSyncNow(), conditions: deviceConditions())
        // Another chat starts over without the label.
        setActiveChatRepliesElsewhere(openChatSync.repliesElsewhere)
        guard due else { return }
        if freshActiveListSnapshot(maxAge: 5) == nil {
            await refreshLiveSessionStatuses()
        }
        guard let snapshot = freshActiveListSnapshot(maxAge: 5) else { return }
        observeOpenChat(in: snapshot, chatVisible: true)
    }

    private func freshActiveListSnapshot(maxAge: TimeInterval) -> (rows: [LiveSessionStatus], at: Date)? {
        guard let latestActiveList, latestActiveList.profile == activeProfile,
              let client, latestActiveList.client == ObjectIdentifier(client),
              chatSyncNow().timeIntervalSince(latestActiveList.at) < maxAge else { return nil }
        return (latestActiveList.rows, latestActiveList.at)
    }

    /// The open chat as this device holds it, or nil when there is none the
    /// registry can speak for: a Bot Chat lives in another profile's
    /// registry, a room isn't one session, and a chat still syncing or
    /// reconnecting has no settled local state to compare.
    private func openChatLocalTurn() -> OpenChatLocalTurn? {
        guard let sessionId = activeSessionId, !sessionId.isEmpty,
              activeRoomSurface == nil,
              botConversationProfile(for: sessionId) == nil,
              turnState == .idle || turnState == .running else { return nil }
        var ownTexts: [String] = []
        var hasRunningTool = false
        // The running turn's own rows: back to its user message.
        for message in messages.reversed() {
            if message.role == .tool, message.tool?.status == .running { hasRunningTool = true }
            if message.role == .assistant { ownTexts.append(message.content) }
            if message.role == .user {
                ownTexts.append(message.content)
                if !message.isSteer { break }
            }
        }
        ownTexts.append(streamingBuffer)
        return OpenChatLocalTurn(
            sessionID: sessionId,
            isRunning: turnState.isRunning,
            hasRunningTool: turnState.isRunning && hasRunningTool,
            ownTexts: ownTexts
        )
    }

    private func observeOpenChat(in snapshot: (rows: [LiveSessionStatus], at: Date), chatVisible: Bool) {
        // A read or a reconciliation already under way owns the transcript.
        guard let local = openChatLocalTurn() else {
            setActiveChatRepliesElsewhere(false)
            return
        }
        guard openChatSyncRead == nil, reconciliation == nil, !isChatRefreshing else { return }
        let rows = openChatRegistryRows(snapshot.rows, sessionID: local.sessionID)
        let action = openChatSync.observe(
            Self.openChatRegistryRow(rows),
            snapshotAt: snapshot.at,
            local: local,
            now: chatSyncNow(),
            chatVisible: chatVisible
        )
        setActiveChatRepliesElsewhere(openChatSync.repliesElsewhere)
        switch action {
        case .none:
            break
        case .settleTurn:
            lifecycleLog.notice(
                "Open chat: turn silent here and not running on the server → re-read session=\(local.sessionID, privacy: .private(mask: .hash))"
            )
            startOpenChatSyncRead(sessionID: local.sessionID, expectsRunning: true) { appState in
                // Nothing runs, so this resume takes no stream from another
                // device; it brings the reply and settles the turn. Asked
                // once more right before, since a new turn may have begun.
                guard await appState.openChatIsIdleOnServer(local.sessionID) else { return }
                await appState.syncSession(purpose: .preserveCurrent, using: nil, automaticWorkToken: nil)
            }
        case .readNewRows:
            guard !rows.isEmpty else { return }
            readOpenChatRowsFromElsewhere(sessionID: local.sessionID, rows: rows)
        }
    }

    /// Reads the rows of a turn another device (or the TUI) ran in the open
    /// chat, which sits idle here. `rows` are the chat's registry rows.
    private func readOpenChatRowsFromElsewhere(sessionID: String, rows: [LiveSessionStatus]) {
        guard let row = rows.first(where: { !$0.isRunning }) ?? rows.first else {
            // No live runtime of the chat on this gateway: the turn ran in
            // another process (the TUI), and may still be running there,
            // where this registry can't see it. Only the read-only tail read:
            // a resume could take the chat from that process mid-turn.
            lifecycleLog.notice(
                "Open chat: stored rows moved elsewhere, no live runtime here → read its rows session=\(sessionID, privacy: .private(mask: .hash))"
            )
            let probe = LiveSessionStatus(runtimeSessionId: sessionID, storedSessionId: sessionID, status: "idle")
            startOpenChatSyncRead(sessionID: sessionID, expectsRunning: false) { appState in
                let token = appState.beginReconciliation()
                let read = await appState.reconcileForegroundCrossSurfaceActivity(
                    livenessIsRunning: false,
                    requestedSessionID: sessionID,
                    probeRow: probe,
                    reconciliationToken: token,
                    automaticWorkToken: nil,
                    resumeFallbackAllowed: { false }
                )
                if !read { appState.openChatSync.readCalledOff() }
            }
            return
        }
        lifecycleLog.notice(
            "Open chat: a turn ran elsewhere → read its rows session=\(sessionID, privacy: .private(mask: .hash))"
        )
        startOpenChatSyncRead(sessionID: sessionID, expectsRunning: false) { appState in
            // The bounded, read-only tail read a return from the
            // background uses: new rows merge in, and only an
            // inconclusive read falls back to resuming the idle chat.
            let token = appState.beginReconciliation()
            let resumed = await appState.reconcileForegroundCrossSurfaceActivity(
                livenessIsRunning: false,
                requestedSessionID: sessionID,
                probeRow: row,
                reconciliationToken: token,
                automaticWorkToken: nil,
                // A read that would end in a resume asks the registry
                // first: a turn begun since would lose its stream.
                resumeFallbackAllowed: { await appState.openChatIsIdleOnServer(sessionID) }
            )
            if !resumed { appState.openChatSync.readCalledOff() }
        }
    }

    /// Hermes said a stored session row moved (`sessions.changed`): the
    /// catalog is read again, which also tells the open chat whether its
    /// own count moved (#1026).
    func noteCatalogChanged() {
        catalogChangeSignal.noteChanged()
        readPendingCatalogChange()
    }

    /// Reads the catalog for a pending `sessions.changed` when it may: not
    /// while a turn runs here, at most every 5 s. One held back by the
    /// spacing is read when the wait is over; one held back by a turn, at
    /// the open chat's or the list's next check.
    func readPendingCatalogChange() {
        guard isSceneActive, isConnected else { return }
        let now = chatSyncNow()
        if catalogChangeSignal.takeRead(now: now, turnRunningHere: turnState.isRunning) {
            refreshCatalogAfterLeavingChat(reportingFailure: false, readingChange: true)
            return
        }
        guard !turnState.isRunning, catalogChangeReadTask == nil,
              let delay = catalogChangeSignal.delayUntilDue(now: now), delay > 0 else { return }
        catalogChangeReadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            self.catalogChangeReadTask = nil
            guard !Task.isCancelled else { return }
            self.readPendingCatalogChange()
        }
    }

    /// Hermes announced a user message in a chat (`user.message`). Every
    /// client of the chat hears it, this one's own sends included: one
    /// already shown here by its row id, or matching the latest user
    /// message here while that one has no row id yet, is this device's
    /// (so is the same text resent elsewhere then; its stored count still
    /// reads it).
    func noteUserMessageElsewhere(sessionId: String, rowId: Int?, text: String) {
        let latestHere = messages.last(where: { $0.role == .user })
        let elsewhere = eventBelongsToActiveSession(sessionId)
            && (rowId.map({ id in !messages.contains(where: { $0.rowId == id }) }) ?? true)
            && (rowId != nil && latestHere?.rowId != nil
                || OpenChatSync.squashed(latestHere?.content ?? "") != OpenChatSync.squashed(text))
        // A follow-up waiting in this chat: whatever turn is running here.
        if elsewhere, let activeSessionId {
            notePredictiveFollowUpMessageElsewhere(sessionId: activeSessionId, rowId: rowId)
        }
        if elsewhere, !turnState.isRunning, openChatSync.sessionID == activeSessionId {
            openChatSync.noteUserMessageElsewhere()
        }
        noteCatalogChanged()
    }

    /// A catalog read landed: the open chat's stored count, against the
    /// last one, says whether a turn the registry never saw ran in it.
    func observeOpenChatCatalog() {
        guard let local = openChatLocalTurn(),
              openChatSyncRead == nil, reconciliation == nil, !isChatRefreshing else { return }
        let accepted = acceptedIdentitySessionIDs(forRequested: local.sessionID)
        let listed = (sessions + cronSessions).first { session in
            accepted.contains(session.id)
                || session.storedSessionId.map { accepted.contains($0) } == true
                || !accepted.isDisjoint(with: session.alternateIds)
        }
        let action = openChatSync.observeCatalog(
            messageCount: listed?.messageCount,
            local: local,
            now: chatSyncNow(),
            chatVisible: isSceneActive && !showSidebar
        )
        guard action == .readNewRows else { return }
        let sessionID = local.sessionID
        // A newer check replaces this one: it would only read the rows again.
        openChatCatalogCheck?.cancel()
        openChatCatalogCheck = Task { @MainActor [weak self] in
            guard let self else { return }
            if self.freshActiveListSnapshot(maxAge: 5) == nil {
                await self.refreshLiveSessionStatuses()
            }
            guard !Task.isCancelled else { return }
            let rows = self.freshActiveListSnapshot(maxAge: 5)
                .map { self.openChatRegistryRows($0.rows, sessionID: sessionID) } ?? []
            guard self.activeSessionId == sessionID, self.openChatSyncRead == nil,
                  self.reconciliation == nil, !self.isChatRefreshing else {
                self.openChatSync.readCalledOff()
                return
            }
            self.readOpenChatRowsFromElsewhere(sessionID: sessionID, rows: rows)
        }
    }

    private func startOpenChatSyncRead(
        sessionID: String,
        expectsRunning: Bool,
        _ read: @escaping @MainActor (AppState) async -> Void
    ) {
        let readID = UUID()
        openChatSyncReadID = readID
        openChatSyncRead = Task { @MainActor [weak self] in
            guard let self else { return }
            // Clears its own fence only.
            defer {
                if self.openChatSyncReadID == readID {
                    self.openChatSyncRead = nil
                    self.openChatSyncReadID = nil
                }
            }
            // The chat or its turn changed since the snapshot: nothing to do.
            guard self.activeSessionId == sessionID, self.reconciliation == nil,
                  self.turnState == (expectsRunning ? .running : .idle) else {
                // New rows still unread: the next check asks again.
                if !expectsRunning, self.activeSessionId == sessionID { self.openChatSync.readCalledOff() }
                return
            }
            await read(self)
        }
    }

    /// Every registry row of the open chat: a voice runtime and the chat's
    /// own can share its ids.
    private func openChatRegistryRows(_ rows: [LiveSessionStatus], sessionID: String) -> [LiveSessionStatus] {
        let acceptedIDs = acceptedIdentitySessionIDs(forRequested: sessionID)
        return rows.filter {
            acceptedIDs.contains($0.runtimeSessionId) || acceptedIDs.contains($0.storedSessionId)
        }
    }

    /// One view of the chat's rows: running if any runs, starting if any
    /// starts, the running row's preview, and the highest count.
    nonisolated static func openChatRegistryRow(_ rows: [LiveSessionStatus]) -> OpenChatRegistryRow? {
        guard !rows.isEmpty else { return nil }
        let running = rows.first(where: \.isRunning)
        return OpenChatRegistryRow(
            isRunning: running != nil,
            isStarting: running == nil && rows.contains { $0.status == "starting" },
            messageCount: rows.compactMap(\.messageCount).max(),
            preview: (running ?? rows[0]).preview
        )
    }

    /// A fresh registry read: nothing of the open chat runs or starts.
    private func openChatIsIdleOnServer(_ sessionID: String) async -> Bool {
        guard let client else { return false }
        // A send here during the read changes the local turn; the idle
        // answer is then stale, and a resume would take the new turn's stream.
        let turnStateBefore = turnState
        let streamEventBefore = openChatSync.lastStreamEventAt
        let rows: [LiveSessionStatus]
        do {
            if let probeActiveSessions = chatResumeLifecycleOperations.probeActiveSessions {
                rows = try await probeActiveSessions(client)
            } else {
                rows = try await client.activeSessions()
            }
        } catch {
            return false
        }
        guard self.client === client, activeSessionId == sessionID,
              turnState == turnStateBefore,
              openChatSync.lastStreamEventAt == streamEventBefore else { return false }
        return !openChatRegistryRows(rows, sessionID: sessionID).contains {
            $0.isRunning || $0.status == "starting"
        }
    }

    /// This device sent something in the open chat (a turn, a steer, a
    /// command): the registry's count moving next is its own doing.
    func noteOpenChatSentHere() {
        openChatSync.noteSentHere()
        // The persistent iPad sidebar shows the list beside the chat.
        noteChatListInteraction()
    }

    func noteOpenChatStreamEvent() {
        openChatSync.noteStreamEvent(at: chatSyncNow())
        setActiveChatRepliesElsewhere(false)
    }

    private func setActiveChatRepliesElsewhere(_ value: Bool) {
        // Assigned only on a change: every publish redraws the chat.
        if activeChatRepliesElsewhere != value { activeChatRepliesElsewhere = value }
    }

    /// Desktop treats archived conversations as a separate, server-backed
    /// history surface. Keep it separate from the live drawer catalog so an
    /// archive operation cannot briefly reinsert a row into recents.
    func loadArchivedSessions() async {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { return }
        do {
            let loaded = try await dashboardArchivedSessions(profile: profile, using: owner.bridge)
            guard profile == activeProfile, ownsDashboardRuntime(owner) else { return }
            archivedSessions = uniqueSessions(loaded.filter { sessionBelongsToProfile($0, profile: profile) })
        } catch {
            guard profile == activeProfile, ownsDashboardRuntime(owner) else { return }
            errorMessage = AppLocalization.string("Could not load archived conversations: \(UserFacingError.message(for: error))")
        }
    }

    func archiveSession(_ session: SessionSummary) async -> Bool {
        await setSessionArchived(session, archived: true)
    }

    func restoreArchivedSession(_ session: SessionSummary) async -> Bool {
        await setSessionArchived(session, archived: false)
    }

    private func setSessionArchived(_ session: SessionSummary, archived: Bool) async -> Bool {
        if archived, isOtherProfileRow(session) {
            return await archiveOtherProfileSession(session)
        }
        guard sessionBelongsToProfile(session, profile: activeProfile),
              sessionMutationCanStart(hasTransport: dashboardTicketBridge != nil || widgetSessionMutationRequestOverride != nil)
        else { return false }
        if archived, isBusy, sessionMatchesActiveSession(session) {
            showSessionMutationNotice(AppLocalization.string("Stop the active response before archiving this conversation."))
            return false
        }

        let profile = activeProfile
        let owner = currentDashboardRuntimeOwner()
        sessionMutationID = session.id
        defer { sessionMutationID = nil }
        do {
            let body: [String: Any] = ["archived": archived]
            if let widgetSessionMutationRequestOverride {
                try await sendSessionMutation(session.id, body: body, profile: profile, using: widgetSessionMutationRequestOverride)
            } else if let owner {
                try await sendSessionMutation(session.id, body: body, profile: profile, bridge: owner.bridge)
            } else {
                showSessionMutationNotice(AppLocalization.string("Reconnect to Hermes to change this conversation."))
                return false
            }
            guard sessionMutationResultIsCurrent(profile: profile, owner: owner) else { return false }

            do {
                widgetSnapshotPublicationSuppressionDepth += 1
                defer { widgetSnapshotPublicationSuppressionDepth -= 1 }
                var updated = session
                updated.isArchived = archived
                if archived {
                    sessionYoloStore.clearOverride(
                        for: profile,
                        sessionIDs: [updated.id] + updated.alternateIds
                    )
                    removeSessionFromLiveCatalog(updated)
                    archivedSessions = [updated] + archivedSessions.filter { !sessionMatches($0, updated) }
                    removePinnedState(for: updated, unpinOnHost: true)
                    clearActiveSessionIfNeeded(updated, replacement: .archive)
                } else {
                    archivedSessions.removeAll { sessionMatches($0, updated) }
                    // A restored cron run goes back to the Cron list, not the chats.
                    if updated.source == .cron {
                        cronSessions = [updated] + cronSessions.filter { !sessionMatches($0, updated) }
                    } else {
                        sessions = [updated] + sessions.filter { !sessionMatches($0, updated) }
                    }
                }
            }
            publishWidgetSnapshot()
            return true
        } catch {
            guard sessionMutationResultIsCurrent(profile: profile, owner: owner) else { return false }
            let reason = UserFacingError.message(for: error)
            showSessionMutationNotice(archived
                ? AppLocalization.string("Could not archive this conversation: \(reason)")
                : AppLocalization.string("Could not restore this conversation: \(reason)"))
            return false
        }
    }

    @discardableResult
    func renameSession(_ session: SessionSummary, to title: String) async -> Bool {
        if isOtherProfileRow(session) {
            return await renameOtherProfileSession(session, to: title)
        }
        guard let trimmedTitle = SessionRenameOperation.normalizedTitle(
            title,
            currentTitle: session.title
        ),
              sessionBelongsToProfile(session, profile: activeProfile),
              sessionMutationCanStart(hasTransport: sessionRenameOperationsOverride != nil || dashboardTicketBridge != nil)
        else { return false }

        let profile = activeProfile
        let knownIDs = [session.id] + session.alternateIds
        let titleRecoveryTaskKeys = Set(
            knownIDs.filter { !$0.isEmpty }.map {
                Self.secondaryTitleRecoveryTaskKey(profile: profile, sessionID: $0)
            }
        )
        sessionTitleRecoveryTracker.suppress(titleRecoveryTaskKeys)
        sessionMutationID = session.id
        defer {
            sessionMutationID = nil
            sessionTitleRecoveryTracker.unsuppress(titleRecoveryTaskKeys)
        }

        await sessionTitleRecoveryTracker.cancel(titleRecoveryTaskKeys)
        guard profile == activeProfile else { return false }

        let operations: SessionRenameOperation.Operations
        if let sessionRenameOperationsOverride {
            operations = sessionRenameOperationsOverride
        } else {
            guard let dashboardTicketBridge else {
                // The connection dropped while title recovery was cancelled.
                showSessionMutationNotice(AppLocalization.string("Reconnect to Hermes to change this conversation."))
                return false
            }
            let activeClient = client
            let runtimeRenameExpected = activeClient != nil
                && activeSessionId.map { knownIDs.contains($0) } == true
            operations = SessionRenameOperation.Operations(
                renameRuntime: activeClient.map { client in
                    { [weak self, weak client] sessionID, title in
                        guard let self, let client else {
                            throw SessionRenameOperation.ContextChanged()
                        }
                        try await client.setSessionTitle(sessionID, title: title)
                        guard profile == self.activeProfile, self.client === client else {
                            throw SessionRenameOperation.ContextChanged()
                        }
                    }
                },
                renameStored: { [weak self, weak dashboardTicketBridge] sessionID, title in
                    guard let self, let dashboardTicketBridge,
                          profile == self.activeProfile,
                          !runtimeRenameExpected || self.client === activeClient else {
                        throw SessionRenameOperation.ContextChanged()
                    }
                    try await self.sendSessionMutation(
                        sessionID,
                        body: ["title": title],
                        profile: profile,
                        bridge: dashboardTicketBridge
                    )
                }
            )
        }

        do {
            guard let result = try await SessionRenameOperation.perform(
                session: session,
                activeSessionID: activeSessionId,
                title: trimmedTitle,
                operations: operations
            ), profile == activeProfile else { return false }
            applyRecoveredSessionTitle(result.title, sessionIDs: result.sessionIDs)
            return true
        } catch is SessionRenameOperation.ContextChanged {
            return false
        } catch {
            guard profile == activeProfile else { return false }
            showSessionMutationNotice(SessionRenameOperation.failureMessage(error))
            return false
        }
    }

    func deleteSession(_ session: SessionSummary) async -> Bool {
        if isOtherProfileRow(session) {
            return await deleteOtherProfileSession(session)
        }
        guard sessionBelongsToProfile(session, profile: activeProfile),
              sessionMutationCanStart(hasTransport: dashboardTicketBridge != nil || widgetSessionMutationRequestOverride != nil)
        else { return false }
        if isBusy, sessionMatchesActiveSession(session) {
            showSessionMutationNotice(AppLocalization.string("Stop the active response before deleting this conversation."))
            return false
        }

        let profile = activeProfile
        let dashboardID = activeDashboardID
        let owner = currentDashboardRuntimeOwner()
        sessionMutationID = session.id
        defer { sessionMutationID = nil }
        do {
            if let widgetSessionMutationRequestOverride {
                try await sendSessionMutation(session.id, body: nil, profile: profile, using: widgetSessionMutationRequestOverride)
            } else if let owner {
                try await sendSessionMutation(session.id, body: nil, profile: profile, bridge: owner.bridge)
            } else {
                showSessionMutationNotice(AppLocalization.string("Reconnect to Hermes to change this conversation."))
                return false
            }
            let deletedSessionIDs = Set(session.nestingIDs)
            // Hermes deleted it: its saved copy leaves the phone even if the
            // screen has since moved to another dashboard or profile, or a
            // later visit there would open to it (#1040).
            if let dashboardID {
                removeSavedCopies(ofDeleted: deletedSessionIDs, dashboardID: dashboardID, profile: profile)
            }
            // Its pinned replies go too, under the profile it was deleted in.
            dropPinnedReplies(forDeleted: session, profile: profile)
            // A call in it goes on in a new chat (issue 1797).
            voiceBackgroundJobSupervisor.noteChatDeleted(deletedSessionIDs)
            guard sessionMutationResultIsCurrent(profile: profile, owner: owner) else { return false }
            sessionYoloStore.clearOverride(
                for: profile,
                sessionIDs: Array(deletedSessionIDs)
            )
            revokeDeletedConversationIdentity(
                sessionIDs: deletedSessionIDs,
                profile: profile
            )
            removeSessionFromLiveCatalog(session)
            archivedSessions.removeAll { sessionMatches($0, session) }
            removePinnedState(for: session)
            setSessionStarred(session, starred: false, profile: profile)
            updateChatReadState { $0.forget(session, profile: profile) }
            clearActiveSessionIfNeeded(session, replacement: .delete)
            publishWidgetSnapshot()
            return true
        } catch DashboardTicketBridgeError.answeredAfterSwitch {
            // Hermes deleted it after the screen moved to another dashboard:
            // only the old dashboard's saved copy follows (#1040).
            if let dashboardID {
                removeSavedCopies(ofDeleted: Set(session.nestingIDs), dashboardID: dashboardID, profile: profile)
            }
            return false
        } catch {
            guard sessionMutationResultIsCurrent(profile: profile, owner: owner) else { return false }
            showSessionMutationNotice(AppLocalization.string("Could not delete this conversation: \(UserFacingError.message(for: error))"))
            return false
        }
    }

    func isSessionMutationInFlight(_ session: SessionSummary) -> Bool {
        sessionMutationID == session.id
    }

    /// Whether an archive or delete's result (or failure) is still this
    /// screen's: same profile, and the dashboard it went to is still the
    /// one showing. Sent without a bridge (a widget's), the profile decides.
    private func sessionMutationResultIsCurrent(profile: String, owner: DashboardRuntimeOwner?) -> Bool {
        guard profile == activeProfile else { return false }
        return owner.map(ownsDashboardRuntime) ?? true
    }

    /// Whether an archive, delete or rename may start now; says why not
    /// when it can't, instead of the tap doing nothing.
    func sessionMutationCanStart(hasTransport: Bool) -> Bool {
        guard sessionMutationID == nil else {
            showSessionMutationNotice(AppLocalization.string("Wait for the current conversation change to finish, then try again."))
            return false
        }
        guard hasTransport else {
            showSessionMutationNotice(AppLocalization.string("Reconnect to Hermes to change this conversation."))
            return false
        }
        return true
    }

    /// A chat change that didn't happen says so over the Chats list and the
    /// open chat. `errorMessage` shows only while the composer is locked or
    /// the connection needs repair, so a refused archive or delete used to
    /// look like the tap did nothing.
    func showSessionMutationNotice(_ message: String) {
        showNotice(message, systemImage: "exclamationmark.triangle.fill")
    }

    /// Explicit deletion revokes the conversation's identity: index
    /// mappings, scroll/resume state, and cached presentation (with any
    /// pending cards) must not survive under any of its aliases.
    func revokeDeletedConversationIdentity(sessionIDs: Set<String>, profile: String) {
        conversationIdentityIndex.removeSessionIDs(sessionIDs, profile: profile)
        chatResumeCoordinator.removeSessions(
            profile: profile,
            sessionIDs: Array(sessionIDs)
        )
        sessionPresentationCache.removeSessions(
            profile: profile,
            sessionIDs: Array(sessionIDs)
        )
        // A saved copy of it on screen goes too; deleteSession removes the
        // copy's files.
        if let copy = offlineChatPresentation, copy.profile == profile,
           !copy.chatSessionIDs.isDisjoint(with: sessionIDs) {
            dismissOfflineChatPresentation()
        }
    }

    private func encodedSessionID(_ sessionID: String) -> String {
        sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionID
    }

    /// A session PATCH (with `body`) or DELETE (`body` nil) carrying Hermes'
    /// mutation identity when the host has one (SessionMutationIdentity).
    /// A write that lost a race with another change gets one retry.
    @discardableResult
    func sendSessionMutation(
        _ sessionID: String,
        body: [String: Any]?,
        profile: String,
        host: String? = nil,
        using request: @escaping (String, String, [String: Any]?) async throws -> [String: Any]
    ) async throws -> [String: Any] {
        let path = dashboardPath("/api/sessions/\(encodedSessionID(sessionID))", profile: profile)
        let snapshotPath = dashboardPath("/api/sessions/\(encodedSessionID(sessionID))/mutation-snapshot", profile: profile)
        let routeKey = "\(host ?? dashboardTicketBridge?.baseURL ?? "")|\(profile)"
        let attempt: () async throws -> [String: Any] = {
            var snapshot: [String: Any] = [:]
            if !self.hostsWithoutMutationSnapshot.contains(routeKey) {
                do {
                    snapshot = try await request(snapshotPath, "GET", nil)
                } catch DashboardTicketBridgeError.http(status: 404, detail: let detail)
                            where SessionMutationIdentity.isMissingRoute(detail) {
                    self.hostsWithoutMutationSnapshot.insert(routeKey)
                } catch {
                    // A failed read sends the bare write; a refusal retries.
                }
            }
            let identity = SessionMutationIdentity.fields(snapshot: snapshot)
            if var body {
                if let identity { body.merge(identity) { _, new in new } }
                return try await request(path, "PATCH", DashboardPath.bodyWithProfile(body, profile: profile))
            }
            let deletePath = identity.map { SessionMutationIdentity.path(path, adding: $0) } ?? path
            return try await request(deletePath, "DELETE", nil)
        }
        do {
            return try await attempt()
        } catch let error where SessionMutationIdentity.warrantsRetry(error) {
            hostsWithoutMutationSnapshot.remove(routeKey)
            return try await attempt()
        }
    }

    /// `sendSessionMutation` over the dashboard bridge.
    @discardableResult
    func sendSessionMutation(
        _ sessionID: String,
        body: [String: Any]?,
        profile: String,
        bridge: DashboardTicketBridge
    ) async throws -> [String: Any] {
        try await sendSessionMutation(sessionID, body: body, profile: profile, host: bridge.baseURL) { path, method, body in
            try await bridge.requestJSON(path: path, method: method, body: body)
        }
    }

    private func sessionMatches(_ lhs: SessionSummary, _ rhs: SessionSummary) -> Bool {
        let left = Set([lhs.id] + lhs.alternateIds)
        let right = Set([rhs.id] + rhs.alternateIds)
        return !left.isDisjoint(with: right)
    }

    func knownSessionIDs(for sessionID: String) -> Set<String> {
        guard let session = [sessions, cronSessions].joined().first(where: {
            $0.id == sessionID || $0.alternateIds.contains(sessionID)
        }) else {
            return [sessionID]
        }
        return Set([session.id] + session.alternateIds)
    }

    /// Captures the complete selected conversation identity from the CURRENT
    /// catalog and scroll identity. Recovery callers MUST invoke this before
    /// replacing the catalog: the accepted alias set is positively
    /// established evidence, and the refreshed catalog that recovery is about
    /// to publish is allowed to have temporarily forgotten the runtime alias.
    /// Reconstructing the set from the already-replaced catalog would drop
    /// the alias for exactly the reconcile window that needs it.
    func captureConversationIdentity(
        for selectedID: String?,
        scopeProfile: String? = nil
    ) -> ConversationIdentity? {
        guard let selectedID, !selectedID.isEmpty else { return nil }
        var accepted = Set([selectedID])
        var durableSessionID: String?
        if let row = (sessions + cronSessions).first(where: { row in
            guard row.id == selectedID || row.alternateIds.contains(selectedID) else { return false }
            // A typed Bot open addresses the bot's own profile. The raw
            // dashboard catalog can contain the same runtime id, but its
            // durable identity is not evidence about this Bot Chat.
            guard let scopeProfile else { return true }
            guard let owner = row.profile else { return false }
            return profilesMatch(owner, scopeProfile)
        }) {
            accepted.formUnion([row.id] + row.alternateIds)
            // The row's stored id is the positively labeled durable identity;
            // a row without one is represented by its primary id.
            durableSessionID = row.storedSessionId ?? row.id
        } else if activeChatScrollSessionIdentity.contains(selectedID),
                  (scopeProfile == nil || activeChatScrollSessionIdentity.profile.map {
                      profilesMatch($0, scopeProfile ?? activeProfile)
                  } == true) {
            // Not in the catalog anymore, but the scroll identity still holds
            // positively confirmed aliases for it (mid-refresh windows).
            accepted.formUnion(activeChatScrollSessionIdentity.equivalentSessionIDs)
            // A canonical that DIFFERS from the selected id is positive
            // durable evidence (the row resolved the alias). A canonical that
            // EQUALS the selected id is self-referential (runtime-only
            // conversation) — treating it as durable would turn the first
            // labeled resume into a false contradiction, so leave durable
            // unset and let the response establish it.
            if let canonical = activeChatScrollSessionIdentity.canonicalSessionID,
               canonical != selectedID {
                durableSessionID = canonical
            }
        }
        // A reopened chat's runtime id is often in neither place, but the
        // resume that produced it recorded the stored id it belongs to.
        // Without it, recovery would resume the runtime id, which Hermes
        // stops recognizing once that runtime is reaped.
        // Index mappings are profile-owned. A Bot Chat must not inherit a
        // same-id dashboard mapping when its own profile has none yet.
        if durableSessionID == nil,
           let durable = conversationIdentityIndex.durableID(
               forRuntime: selectedID,
               profile: scopeProfile ?? activeProfile
           ),
           durable != selectedID {
            durableSessionID = durable
            accepted.insert(durable)
        }
        return ConversationIdentity(
            // Capture metadata for the conversation's owning workspace: a
            // canonical Bot Chat belongs to the bot's profile, not the
            // dashboard's. The admission gate never compares this field.
            profile: scopeProfile ?? activeProfile,
            durableSessionID: durableSessionID,
            runtimeSessionID: durableSessionID == selectedID ? nil : selectedID,
            acceptedSessionIDs: accepted
        )
    }

    func sessionMatchesActiveSession(_ session: SessionSummary) -> Bool {
        guard let activeSessionId else { return false }
        return Set([session.id] + session.alternateIds).contains(activeSessionId)
    }

    func removeSessionFromLiveCatalog(_ session: SessionSummary) {
        sessions.removeAll { sessionMatches($0, session) }
        cronSessions.removeAll { sessionMatches($0, session) }
        // A row deleted or archived while the saved list still shows goes
        // from it too, not only once the live list lands without it.
        if var saved = savedChatList {
            saved.list.sessions.removeAll { sessionMatches($0, session) }
            saved.list.cronSessions.removeAll { sessionMatches($0, session) }
            saved.keptPinnedRows?.removeAll { sessionMatches($0, session) }
            if saved != savedChatList { savedChatList = saved }
        }
        // Every non-forced catalog load merges the profile cache back into
        // the published arrays and re-saves the union. A row left in the
        // cache therefore resurrects a deleted or archived conversation on
        // the next foreground or send, until a pull-to-refresh purges it.
        sessionCatalogCache.removeSession(
            withIDs: Set([session.id] + session.alternateIds)
        )
        // A call archive kept for the catalog that lists it is dropped: a
        // call archived on Hermes already, deleted or archived here, leaves
        // no trace in the live total that would make it read again. Kept
        // archives that don't list it (other profiles') stay.
        archivedCallsReads = archivedCallsReads.filter { _, read in
            !read.calls.contains { sessionMatches($0, session) }
        }
        publishWidgetSnapshot()
    }

    func clearActiveSessionIfNeeded(
        _ session: SessionSummary,
        replacement: ChatResumeConversationReplacement
    ) {
        guard sessionMatchesActiveSession(session) else { return }
        clearActiveConversation(replacement: replacement)
    }

    func clearActiveConversation(replacement: ChatResumeConversationReplacement) {
        let transitionGeneration = acceptChatResumeConversationReplacement(replacement)
        markChatViewportReplacement()
        setActiveSessionState(id: nil, title: AppLocalization.string("New conversation"))
        keepDelegateAgents(of: [])
        messages = []
        persistedTranscriptWindow = nil
        resetTranscriptLifecycleEvidence()
        clearStreamingText()
        activeAssistantMessageId = nil
        resetReasoningTurn()
        turnState = .idle
        finishChatViewportTransition(generation: transitionGeneration)
    }

    /// The V2 Scheduled tab's read: the jobs it draws and their
    /// notifications. The cron-session history `refreshCronContent` also
    /// fills is the legacy drawer's Cron tab, which shows those rows; the
    /// V2 tab shows none, so it does not pay for a catalogue read on every
    /// switch to it.
    func refreshScheduledContent() async {
        async let jobsRefresh: Void = loadCronJobs()
        async let notificationsRefresh: Void = refreshCronNotifications()
        _ = await (jobsRefresh, notificationsRefresh)
    }

    /// The Cron tab presents two independent server-backed surfaces: the job
    /// definitions and the cron-session history. Refresh them together so a
    /// newly completed run is visible without visiting the Sessions tab first.
    ///
    /// Showing the tab reads only the newest page and the cron rows over the
    /// cached catalog; the older pages wait for the full history's own
    /// interval. Pull to refresh (`repairingCatalog`) still replaces the
    /// whole catalog, as Chats' pull does (issue 1962).
    func refreshCronContent(repairingCatalog: Bool = false) async {
        async let sessionRefresh: Void = repairingCatalog
            ? refreshSessionCatalog()
            : refreshNewestSessionCatalogPage()
        async let jobsRefresh: Void = loadCronJobs()
        async let notificationsRefresh: Void = refreshCronNotifications()
        _ = await (sessionRefresh, jobsRefresh, notificationsRefresh)
    }
}
