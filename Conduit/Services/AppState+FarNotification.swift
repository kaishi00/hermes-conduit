//
//  AppState+FarNotification.swift
//  Conduit
//
//  A push or chat link from another combined dashboard opens in place (no-
//  switch stage 2, the notifications thread): its route runs on that
//  dashboard's own runtime, through its kept connection, as the far Chats
//  row's open does (AppState+FarChat.swift), while the dashboard on screen
//  stays as it is. That covers listed and unlisted chats, Bot Chats
//  (through their bot's open), hosted group rooms (on their kept room
//  runtime) and Pulse chats (opening that dashboard's own Pulse feed in
//  place, per the Pulse per-instance ruling). A call's push, a peer-hosted
//  room approval, a dashboard whose kept connection was let go, and a
//  widget's New Chat or Talk still switch.
//  The plan: /mnt/project-files/all-live/no-switch-plan.md.
//

import Foundation

extension AppState {
    /// Opens what a push or chat link for another combined dashboard names
    /// in place on that dashboard's own runtime through its kept
    /// connection: hosted group rooms, Pulse chats (opening that
    /// dashboard's Pulse feed), Bot Chats (through openFarBotChatNotification),
    /// and listed or unlisted chats (landing a wait's push on its card).
    /// Returns `.opened`, `.retry`, or `.failed`, or `nil` when it opens
    /// through a switch as before: a call's push (by ruling), a peer-hosted
    /// room approval, the dashboard isn't kept connected (or its socket can't
    /// be handed to the chat's profile), its bots aren't read yet, or nothing
    /// knows where its Pulse lives.
    func openFarNotificationInPlace(_ target: ConduitNotificationTarget, in dashboardID: UUID) async -> NotificationOpenOutcome? {
        guard dashboardID != dashboardIDOnScreen, isInCombinedGroup(dashboardID) else { return nil }
        if target.call == nil, let roomID = target.roomID {
            return await openFarRoomNotification(target, roomID: roomID, in: dashboardID)
        }
        guard let kept = keptDashboardRuntimes[dashboardID], kept.client.isConnected else { return nil }
        if let pulseOutcome = openFarPulseNotification(target, in: dashboardID, runtime: kept.runtime) {
            return pulseOutcome
        }
        guard combinedDashboardBots[dashboardID] != nil || !kept.runtime.botRoster.isEmpty else { return nil }
        // A Bot Chat's push or link opens it in place too, as its Chats row
        // does: its bot's open on that dashboard's runtime.
        if let bot = farBotChatPushed(target, in: dashboardID) {
            return await openFarBotChatNotification(target, of: bot, in: dashboardID)
        }
        // Its Pulse's feed read, or its Pulse chat known some other way.
        guard combinedDashboardPulse[dashboardID] != nil || !farPulseHomes(in: dashboardID).isEmpty else { return nil }
        let requested = target.sessionId
        let attempt = FarNotificationOpenAttempt()
        guard let session = Self.farNotificationChat(
            target,
            listed: combinedDashboardChats[dashboardID]?.sessions ?? [],
            botChats: farBotChatIDs(in: dashboardID),
            pulseHomes: farPulseHomes(in: dashboardID)
        ) else {
            return await openFarUnlistedChatNotification(target, in: dashboardID, attempt: attempt)
        }
        guard let open = startFarChatOpen(session, in: dashboardID, prepare: {
            // A wait raised while Conduit was away comes on the push:
            // its card is recorded on that dashboard's runtime before
            // the open, whose resume merges it in, as on screen.
            guard let decision = target.decision else { return }
            let ids = [session.id, requested, target.durableSessionID].compactMap { $0 }.filter { !$0.isEmpty }
            attempt.cardIDs = requested == session.id ? [requested] : [requested, session.id]
            recordNotificationDecision(decision, sessionIDs: ids, cacheSessionIDs: attempt.cardIDs)
        }, onFailed: { [weak self] wasRefused in
            attempt.refused = wasRefused
            // Runs on that dashboard's runtime, as the card was recorded.
            guard let self, let decision = target.decision,
                  let key = Self.pendingDecisionEvictionKey(for: decision),
                  let first = attempt.cardIDs.first else { return }
            self.sessionPresentationCache.removePendingDecision(
                key: key, profile: self.presentationProfile(for: first), sessionIDs: attempt.cardIDs
            )
        }) else { return nil }
        ensureKeptPluginReport(for: dashboardID)
        return await finishFarNotificationChatOpen(open: open, attempt: attempt, target: target) {
            self.farChatIsShown(session, in: dashboardID)
        }
    }

    private func openFarRoomNotification(
        _ target: ConduitNotificationTarget,
        roomID: String,
        in dashboardID: UUID
    ) async -> NotificationOpenOutcome? {
        guard let runtime = keptRuntimeOpeningRoomsInPlace(dashboardID) else { return nil }
        let viewport = chatViewportTransitionGeneration
        let roomEpoch = groupRoomEpoch
        guard await readyKeptRuntimeForRooms(runtime, dashboardID) else { return .retry }
        guard keptRuntimeOpeningRoomsInPlace(dashboardID) === runtime else { return nil }
        guard chatViewportTransitionGeneration == viewport, groupRoomEpoch == roomEpoch else { return .failed }
        let outcome = await actAcrossAwaits(onRuntime: runtime) { await openNotificationRoom(roomID) }
        closeFarRoomIfLetGo(runtime, dashboardID)
        if outcome == .opened {
            if activeRoomSurface?.room.roomID == roomID {
                discardNotificationRouteFailure(for: target)
                return .opened
            }
            return .failed
        }
        if outcome == .failed {
            discardNotificationRouteFailure(for: target)
        }
        return outcome
    }

    private func openFarPulseNotification(
        _ target: ConduitNotificationTarget,
        in dashboardID: UUID,
        runtime: DashboardRuntime
    ) -> NotificationOpenOutcome? {
        guard target.type == "response.ready", target.decision == nil, target.call == nil,
              !target.isChatLink, !isModalSheetPresented else { return nil }
        let homes = farPulseHomes(in: dashboardID)
        let targetIDs = [
            target.sessionId,
            target.durableSessionID,
            ChatScrollIdentityNormalization.sessionID(target.sessionId),
            target.durableSessionID.flatMap(ChatScrollIdentityNormalization.sessionID)
        ].compactMap { $0 }.filter { !$0.isEmpty }
        guard targetIDs.contains(where: { homes.contains($0) }) else { return nil }
        let pulseProfile = combinedDashboardPulse[dashboardID]?.profile
            ?? act(onRuntime: runtime) { pulseHomeProfile }
        guard target.profile.map({ profilesMatch($0, pulseProfile) }) ?? true else { return nil }
        guard combinedDashboardPulse[dashboardID] != nil
            || act(onRuntime: runtime, { showsPulseScreen }) else { return nil }
        openCombinedPulse(dashboardID)
        openPulse(card: nil)
        discardNotificationRouteFailure(for: target)
        return .opened
    }

    private func openFarUnlistedChatNotification(
        _ target: ConduitNotificationTarget,
        in dashboardID: UUID,
        attempt: FarNotificationOpenAttempt
    ) async -> NotificationOpenOutcome? {
        guard target.call == nil, target.roomID == nil else { return nil }
        let viewport = chatViewportTransitionGeneration
        let roomEpoch = groupRoomEpoch
        func cancelledOrSupersededOutcome() -> NotificationOpenOutcome? {
            if Task.isCancelled { return .retry }
            if chatViewportTransitionGeneration != viewport || groupRoomEpoch != roomEpoch {
                return .failed
            }
            return nil
        }
        let rawIDs = Set([target.sessionId, target.durableSessionID].compactMap { $0 }.filter { !$0.isEmpty })
        let normalizedIDs = Set([target.sessionId, target.durableSessionID].compactMap(ChatScrollIdentityNormalization.sessionID))
        let pulseHomes = farPulseHomes(in: dashboardID)
        let botChats = farBotChatIDs(in: dashboardID)
        guard !rawIDs.isEmpty,
              rawIDs.isDisjoint(with: pulseHomes), normalizedIDs.isDisjoint(with: pulseHomes),
              rawIDs.isDisjoint(with: botChats), normalizedIDs.isDisjoint(with: botChats) else { return nil }
        if case .approval(let sessionKey, _, _) = target.decision {
            await readKeptPluginStatusIfUnknown(dashboardID)
            if let abort = cancelledOrSupersededOutcome() { return abort }
            guard let currentKept = keptDashboardRuntimes[dashboardID], currentKept.client.isConnected else { return nil }
            if act(onRuntime: currentKept.runtime, { canAnswerRoomApprovals }) {
                let keys = [sessionKey, target.durableSessionID, target.sessionId].compactMap { $0 }
                let approval = await actAcrossAwaits(onRuntime: currentKept.runtime, { await roomApproval(matching: keys) })
                if let abort = cancelledOrSupersededOutcome() { return abort }
                if approval != nil { return nil }
            }
        }
        guard let initialKept = keptDashboardRuntimes[dashboardID], initialKept.client.isConnected else { return nil }
        // Its default profile is the one that dashboard named, never the
        // one on screen's.
        let farDefault = profileAppearanceStore.loadDefaultName(dashboardID: dashboardID)
        let scopedProfile = act(onRuntime: initialKept.runtime) {
            notificationProfileID(target.profile, defaultName: farDefault)
        }
        let listedProfile = scopedProfile.flatMap { name in
            combinedDashboardChats[dashboardID]?.profiles.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
        }
        let targetProfile = listedProfile ?? initialKept.client.profile ?? "default"
        if act(onRuntime: initialKept.runtime, { botModePhase != .gatewayUnsupported }) {
            let pushesCanonicalChat: Bool
            do {
                pushesCanonicalChat = try await actAcrossAwaits(onRuntime: initialKept.runtime) {
                    try await notificationTargetIsCanonicalChat(target, of: targetProfile)
                }
            } catch {
                if let abort = cancelledOrSupersededOutcome() { return abort }
                return nil
            }
            if let abort = cancelledOrSupersededOutcome() { return abort }
            if pushesCanonicalChat {
                var owner = Self.linkedBot(named: targetProfile, in: farBotRoster(in: dashboardID))
                if owner == nil, let refreshedKept = keptDashboardRuntimes[dashboardID], refreshedKept.client.isConnected {
                    await actAcrossAwaits(onRuntime: refreshedKept.runtime) { await refreshBotRoster() }
                    if let abort = cancelledOrSupersededOutcome() { return abort }
                    owner = Self.linkedBot(named: targetProfile, in: farBotRoster(in: dashboardID))
                }
                guard let owner else { return nil }
                return await openFarBotChatNotification(target, of: owner, in: dashboardID)
            }
        }
        if let abort = cancelledOrSupersededOutcome() { return abort }
        guard let currentKept = keptDashboardRuntimes[dashboardID], currentKept.client.isConnected,
              let runtime = keptRuntime(dashboardID, on: targetProfile) else { return nil }
        let requested = target.sessionId
        let primaryID = target.durableSessionID.flatMap { $0.isEmpty ? nil : $0 } ?? requested
        var decisionSessionIDs: [String] = []
        for id in [primaryID, requested, target.durableSessionID].compactMap({ $0 })
            where !id.isEmpty && !decisionSessionIDs.contains(id) {
            decisionSessionIDs.append(id)
        }
        ensureKeptPluginReport(for: dashboardID)
        widgetLaunchCoordinator.supersede()
        let open: Task<Bool, Never> = act(onRuntime: runtime) {
            if let decision = target.decision {
                attempt.cardIDs = requested == primaryID ? [requested] : [requested, primaryID].filter { !$0.isEmpty }
                recordNotificationDecision(decision, sessionIDs: decisionSessionIDs, cacheSessionIDs: attempt.cardIDs)
            }
            return requestOpenSession(primaryID, onFailed: { [weak self] wasRefused in
                attempt.refused = wasRefused
                guard let self, let decision = target.decision,
                      let key = Self.pendingDecisionEvictionKey(for: decision),
                      let first = attempt.cardIDs.first else { return }
                self.sessionPresentationCache.removePendingDecision(
                    key: key, profile: self.presentationProfile(for: first), sessionIDs: attempt.cardIDs
                )
            })
        }
        return await finishFarNotificationChatOpen(open: open, attempt: attempt, target: target) {
            guard self.farChatDashboardID == dashboardID, let active = self.activeSessionId else { return false }
            if rawIDs.contains(active) { return true }
            if let normActive = ChatScrollIdentityNormalization.sessionID(active) {
                return normalizedIDs.contains(normActive)
            }
            return false
        }
    }

    private func finishFarNotificationChatOpen(
        open: Task<Bool, Never>,
        attempt: FarNotificationOpenAttempt,
        target: ConduitNotificationTarget,
        isShown: @MainActor () -> Bool
    ) async -> NotificationOpenOutcome {
        // An approval's or a question's push lands on its card, as on screen.
        var reveal: NeedsYouReveal?
        if let type = target.type, NeedsYouStore.notificationTypes.contains(type) {
            reveal = NeedsYouReveal(opening: target.durableSessionID ?? target.sessionId)
            pendingNeedsYouReveal = reveal
        }
        // The open's own answer can be false for an open that a later read
        // of the same chat took over (the chat still came up), so the chat
        // on screen decides too, unless this open itself failed: a failed
        // resume leaves the chat selected without its rows.
        let answered = await open.value
        let opened = answered || (attempt.refused == nil && isShown())
        if opened {
            discardNotificationRouteFailure(for: target)
            return .opened
        }
        // One that didn't open is tried again: its card's reveal waits for
        // that try rather than land on another chat. A newer tap's reveal
        // stays.
        if let reveal, pendingNeedsYouReveal == reveal { pendingNeedsYouReveal = nil }
        // Superseded by another open: the newer one says what happened.
        guard let refused = attempt.refused else { return .retry }
        let message = Self.linkedSessionFailureMessage(
            current: nil, sessionWasNotFound: refused,
            unavailable: AppLocalization.string("WidgetLaunch.ConversationUnavailable")
        )
        if refused {
            // The same open would hear the same answer.
            discardNotificationRouteFailure(for: target)
            errorMessage = message
            return .failed
        }
        // Said when the retries run out with no chat opened, as the
        // switch's open does (publishNotificationRouteFailure), on the
        // transition the open itself began.
        notificationRouteFailure = NotificationRouteFailure(
            target: target, message: message, transition: chatViewportTransitionGeneration, roomEpoch: groupRoomEpoch
        )
        return .retry
    }

    /// The chat of another combined dashboard's list a push opens in place:
    /// a chat's reply, failure or background task, a wait's question or
    /// approval, or a chat link, for a chat its list holds. Nil for a room's
    /// push, a call's, its Pulse chat's, a Bot Chat's, or a chat it doesn't
    /// list (a room's hidden chat, a chat newer than its last read). Pure,
    /// for tests.
    static func farNotificationChat(
        _ target: ConduitNotificationTarget,
        listed: [SessionSummary],
        botChats: Set<String>,
        pulseHomes: Set<String>
    ) -> SessionSummary? {
        guard target.call == nil, target.roomID == nil else { return nil }
        let ids = Set([target.sessionId, target.durableSessionID].compactMap { $0 }.filter { !$0.isEmpty })
        guard !ids.isEmpty, ids.isDisjoint(with: botChats) else { return nil }
        guard ids.isDisjoint(with: pulseHomes) else { return nil }
        let profile = target.profile.flatMap { $0.isEmpty ? nil : $0 }
        // The durable id first, as the switch's route resolves it.
        func match(_ candidates: Set<String>) -> SessionSummary? {
            listed.first { row in
                !candidates.isDisjoint(with: SessionContentSearch.identities(of: row))
                    && profile.map { profilesMatch(row.profile ?? "default", $0) } ?? true
            }
        }
        let durable = Set([target.durableSessionID].compactMap { $0 }.filter { !$0.isEmpty })
        guard let row = match(durable) ?? match(ids),
              Set(SessionContentSearch.identities(of: row)).isDisjoint(with: pulseHomes) else { return nil }
        return row
    }

    /// The bot of another combined dashboard whose Bot Chat a push or chat
    /// link names: by its bots (its kept runtime's, else Bots Home's read),
    /// else by that dashboard's own Bot Chat registry (a compacted Bot
    /// Chat's newer id). Nil for a call's push (it switches, as a call
    /// does), a room's, or its Pulse chat's.
    func farBotChatPushed(_ target: ConduitNotificationTarget, in dashboardID: UUID) -> BotProfile? {
        guard target.call == nil, target.roomID == nil else { return nil }
        let ids = Set([target.sessionId, target.durableSessionID].compactMap {
            ChatScrollIdentityNormalization.sessionID($0)
        })
        guard !ids.isEmpty, ids.isDisjoint(with: farPulseHomes(in: dashboardID)) else { return nil }
        if let bot = farBot(named: ids, in: dashboardID) { return bot }
        let registry = keptDashboardRuntimes[dashboardID]?.runtime.botChatSessionProfiles ?? [:]
        guard let name = ids.sorted().lazy.compactMap({ registry[$0] }).first else { return nil }
        return Self.linkedBot(named: name, in: farBotRoster(in: dashboardID))
    }

    /// Another combined dashboard's bots: its kept runtime's, then Bots
    /// Home's read of them (kept when its connection drops).
    func farBotRoster(in dashboardID: UUID) -> [BotProfile] {
        (keptDashboardRuntimes[dashboardID]?.runtime.botRoster ?? [])
            + (combinedDashboardBots[dashboardID]?.bots ?? [])
    }

    /// Opens the Bot Chat a push or chat link of another combined dashboard
    /// names in place, as a Bot Chat's push opens on screen
    /// (routeBotOwnedNotification: its card recorded for the bot, its open,
    /// its card landed), on that dashboard's runtime across its awaits,
    /// with no switch. Nil when it isn't kept connected: it switches.
    func openFarBotChatNotification(
        _ target: ConduitNotificationTarget,
        of bot: BotProfile,
        in dashboardID: UUID
    ) async -> NotificationOpenOutcome? {
        guard let runtime = farBotChatRuntime(in: dashboardID) else { return nil }
        ensureKeptPluginReport(for: dashboardID)
        // An approval's or a question's push lands on its card, as on screen.
        if let type = target.type, NeedsYouStore.notificationTypes.contains(type) {
            pendingNeedsYouReveal = NeedsYouReveal(opening: target.durableSessionID ?? target.sessionId)
        }
        let (attemptID, transition) = beginNotificationOpenAttempt(for: target)
        defer { endNotificationOpenAttempt(id: attemptID, transitionGeneration: transition) }
        return await actAcrossAwaits(onRuntime: runtime) {
            await routeBotOwnedNotification(
                target,
                notifiedProfile: target.profile ?? "",
                owner: bot,
                attemptID: attemptID,
                transitionGeneration: transition
            )
        }
    }

    /// Another combined dashboard's Bot Chats, by its bots as Bots Home or
    /// its kept runtime read them.
    func farBotChatIDs(in dashboardID: UUID) -> Set<String> {
        Set(farBotRoster(in: dashboardID).compactMap(\.canonicalSessionID))
    }

    /// Another combined dashboard's Pulse chat, as any of its feed read
    /// through its kept connection, its runtime or its last visit here names
    /// it: one of them can be behind the others.
    func farPulseHomes(in dashboardID: UUID) -> Set<String> {
        Set([
            combinedDashboardPulse[dashboardID]?.homeChatID,
            keptDashboardRuntimes[dashboardID]?.runtime.pulseHomeChatID,
            pulseRememberedHomes[dashboardID.uuidString],
        ].compactMap { $0 }.filter { !$0.isEmpty })
    }

    /// Whether another dashboard's chat is the one on screen, opened in place.
    func farChatIsShown(_ session: SessionSummary, in dashboardID: UUID) -> Bool {
        guard farChatDashboardID == dashboardID, let active = activeSessionId, !active.isEmpty else { return false }
        return SessionContentSearch.identities(of: session).contains(active)
    }

    /// Opens a widget's or Siri's chat of another combined dashboard in
    /// place, on that dashboard's runtime, as its Chats row does: the chat
    /// its kept read lists for that profile. False when the launch goes on
    /// as before (through a switch, or its refusal during a call): a call
    /// going on, not a chat's resume, the dashboard on
    /// screen's, not kept connected, its bots not read yet, not listed, or
    /// its Pulse chat (a chat's link; a bot's opens its Bot Chat). A bot's
    /// Bot Chat opens through its bot's open (openFarBotChatInPlace). An open that fails later shows the launch's
    /// error.
    func openWidgetChatInPlace(_ link: WidgetLaunchLink) -> Bool {
        // During a call a widget's chat refuses, as the switch's launch
        // does (A switch during a call): end the call first.
        guard !isVoiceCallInProgress,
              link.action == .resume, let workspace = link.workspace,
              let reference = link.reference,
              workspace.dashboardID != dashboardIDOnScreen,
              let kept = keptDashboardRuntimes[workspace.dashboardID],
              // Its bots read, so a Bot Chat is told from a chat, as a push's.
              combinedDashboardBots[workspace.dashboardID] != nil || !kept.runtime.botRoster.isEmpty else { return false }
        // A bot's Bot Chat (a `.bot` link, as the widget snapshot makes
        // one) opens in place too, as its Chats row does: by the bot its
        // bots name for the chat's id, else by the link's bot. One that
        // fails says so in its open, as on screen.
        let id = ChatScrollIdentityNormalization.sessionID(reference.sessionID)
        let byID = id.flatMap { farBot(named: [$0], in: workspace.dashboardID) }
        let byName = reference.kind == .bot
            ? reference.botName.flatMap { Self.linkedBot(named: $0, in: farBotRoster(in: workspace.dashboardID)) }
            : nil
        // A chat's link to its Pulse chat isn't opened here as a Bot Chat:
        // it goes on to the switch's launch as before. A bot's link opens
        // its Bot Chat, as that launch would (openWidgetConversation).
        let isPulse = id.map { farPulseHomes(in: workspace.dashboardID).contains($0) } ?? false
        if !(isPulse && reference.kind == .dashboard), let bot = byID ?? byName {
            let open = openFarBotChatInPlace(of: bot, in: workspace.dashboardID)
            if open != nil { errorMessage = nil }
            return open != nil
        }
        // A bot's link no bot of its names: it switches, as before.
        guard reference.kind == .dashboard,
              let session = combinedDashboardChats[workspace.dashboardID]?.sessions.first(where: {
                  profilesMatch($0.profile ?? "default", workspace.profile)
                      && SessionContentSearch.identities(of: $0).contains(reference.sessionID)
              }),
              // Its Pulse chat opens through a switch, on the Pulse screen.
              Set(SessionContentSearch.identities(of: session))
                  .isDisjoint(with: farPulseHomes(in: workspace.dashboardID)) else { return false }
        // An open that fails says so, as the switch's launch does: the chat
        // gone there since its list was read, or its connection lost.
        let unavailable = AppLocalization.string("WidgetLaunch.ConversationUnavailable")
        let open = startFarChatOpen(session, in: workspace.dashboardID, onFailure: { [weak self] sessionWasNotFound in
            guard let self else { return }
            self.errorMessage = Self.linkedSessionFailureMessage(
                current: self.errorMessage, sessionWasNotFound: sessionWasNotFound, unavailable: unavailable
            )
        })
        if open != nil { errorMessage = nil }
        return open != nil
    }
}

/// What a far push's open learned as it went: the ids its card was recorded
/// under, and, once it failed, whether Hermes refused the chat.
@MainActor
private final class FarNotificationOpenAttempt {
    var cardIDs: [String] = []
    var refused: Bool?
}
