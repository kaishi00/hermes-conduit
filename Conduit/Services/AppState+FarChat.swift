//
//  AppState+FarChat.swift
//  Conduit
//
//  Another combined dashboard's chat on screen with no switch (no-switch
//  stage 2, the chat screen's thread): a far Chats row opens its chat on
//  that dashboard's own runtime, through its kept connection, while the
//  dashboard on screen stays as it is. The chat reads, streams and sends
//  there: its open runs in that runtime's scope, its client's events for
//  it apply there, and what acts on the open chat (send, stop, an answer,
//  Load earlier, a refresh or resume) goes to it.
//  The plan: /mnt/project-files/all-live/no-switch-plan.md.
//

import Foundation

/// Another combined dashboard's chat on screen: its dashboard, and the
/// profile it opened on there.
struct FarChatOwner: Equatable {
    let dashboardID: UUID
    let profile: String
}

/// Where an action on the chat on screen runs.
enum ChatRuntimeRoute {
    /// On the runtime acting now: the chat is its dashboard's.
    case inScope
    /// On another dashboard's runtime, the chat's own.
    case far(DashboardRuntime)
    /// The chat's dashboard isn't connected here any more (its kept
    /// connection dropped): nothing can act on the chat until it's back.
    case unreachable
}

extension AppState {
    /// The key `republishRuntime(_:for:)` keeps the far chat's runtime under.
    static let farChatSurface = "farChat"

    /// The combined dashboard whose chat is on screen, when it isn't the
    /// one on screen's.
    var farChatDashboardID: UUID? { farChat?.dashboardID }

    /// Whether a Bot's Screen for `dashboardID`'s bot is another combined
    /// dashboard's than the one on screen's.
    func botScreenIsFar(_ dashboardID: UUID?) -> Bool {
        dashboardID != nil && dashboardID != dashboardIDOnScreen
    }

    /// The connection a Bot's Screen reads and drives: the one on screen's,
    /// or a far bot's own dashboard's kept one (nil once that dropped).
    func botScreenClient(for dashboardID: UUID?) -> HermesClient? {
        guard let dashboardID, botScreenIsFar(dashboardID) else { return client }
        return runtime(for: dashboardID)?.client
    }

    /// A far bot's name as its own dashboard's roster gives it (its Bots
    /// Home roster, else its kept connection's), named as its portrait is
    /// there; else its profile, never the screen's bot under the same
    /// profile name. Its main bot goes by that dashboard's saved name.
    func farBotName(_ profile: String, on dashboardID: UUID) -> String {
        if profile.isEmpty || BotManagement.isDefaultProfile(profile) {
            return profileAppearanceStore.loadDefaultName(dashboardID: dashboardID)
        }
        let roster = (combinedDashboardBots[dashboardID]?.bots ?? [])
            + (keptDashboardRuntimes[dashboardID]?.runtime.botRoster ?? [])
        if let bot = roster.first(where: { $0.name == profile }) { return bot.displayLabel }
        return String(profile.prefix(1)).uppercased() + String(profile.dropFirst())
    }

    /// Whether `dashboardID`'s bots' hosts can have a Bot's Screen, as read
    /// through its own connection.
    func botScreenSupport(for dashboardID: UUID?) -> BotScreenSupport {
        guard let dashboardID, botScreenIsFar(dashboardID) else { return botScreens }
        if let support = farBotScreens[dashboardID] { return support }
        let support = BotScreenSupport()
        farBotScreens[dashboardID] = support
        return support
    }

    /// The dashboard the chat on screen belongs to.
    var chatOnScreenDashboardID: UUID? { farChatDashboardID ?? dashboardIDOnScreen }

    /// The chat on screen's runtime: the one on screen's, or another
    /// combined dashboard's (nil when that one's connection dropped).
    var chatOnScreenRuntime: DashboardRuntime? {
        guard let farChatDashboardID else { return runtimeOnScreen }
        return runtime(for: farChatDashboardID)
    }

    /// The dashboard and profile the chat on screen's composer works for:
    /// a far chat's own, so a message waiting for it ("Sends when
    /// connected") is filed, sent and handed back there.
    var composerOwnerDashboardID: UUID? { farChat?.dashboardID ?? activeDashboardID }
    var composerOwnerProfile: String { farChat?.profile ?? activeProfile }

    /// Whether the chat on screen can reach Hermes: its own dashboard's
    /// connection, which for a far chat isn't the one on screen's.
    var chatIsConnected: Bool {
        guard farChatDashboardID != nil else { return isConnected }
        return chatOnScreenRuntime?.isConnected ?? false
    }

    /// Whether the chat on screen's gateway connection is recovering
    /// (`Reconnecting…` rather than `Disconnected`).
    var chatIsRecoveringConnection: Bool {
        guard let farDashboardID = farChatDashboardID else { return isRecoveringConnection }
        return networkPathUsable && combinedDashboardStatus(farDashboardID) == .connecting
    }

    /// Whether the chat on screen hides a brief reconnect indicator while
    /// returning to the foreground.
    var chatHidesBriefReconnect: Bool {
        guard farChatDashboardID != nil else { return hidesBriefReconnect }
        return isReturningQuietly && networkPathUsable && chatIsRecoveringConnection
    }

    /// The bots' work for the chat on screen: this dashboard's store when
    /// local, or the far chat's own dashboard's store (an empty inert store
    /// while that kept connection is gone, never the screen's).
    var chatBotWork: BotWorkStore {
        guard farChatDashboardID != nil else { return screenBotWork }
        return chatOnScreenRuntime?.botWork ?? emptyBotWork
    }

    /// Whether the chat on screen's dashboard serves bot workstreams.
    var chatServesBotWorkstreams: Bool {
        onChatRuntimeValue(unreachable: false) { servesBotWorkstreams }
    }

    /// The bot profile the chat on screen belongs to, when it's a Bot Chat:
    /// on screen or on its own kept dashboard.
    var chatBotChatProfile: String? {
        guard let farDashboardID = farChatDashboardID else { return activeBotChatProfile }
        return farBotChatProfile(in: farDashboardID)
    }

    /// A far bot's saved avatar URL as its own dashboard knows it.
    func farAvatarURL(for profile: String, on dashboardID: UUID) -> URL? {
        if let url = combinedDashboardBots[dashboardID]?.avatars[profile] { return url }
        return profileAppearanceStore.loadAvatarURLs(dashboardID: dashboardID)[profile]
    }

    /// Runs an async action on the chat on screen's own runtime (the screen
    /// runtime when local, or the far runtime when kept); does nothing when a
    /// far chat's kept connection dropped.
    func actOnChatRuntime(_ body: @escaping @MainActor () async -> Void) async {
        if await onChatRuntime(unreachable: (), { await body() }) == nil {
            await body()
        }
    }

    /// Records whose chat is on screen as the open chat changes: the
    /// dashboard in scope (another combined dashboard's when its open ran
    /// on that runtime).
    func noteChatOnScreenDashboard() {
        let chatDashboard = activeSessionId == nil ? nil : activeDashboardID
        let far = chatDashboard.flatMap { $0 == dashboardIDOnScreen ? nil : FarChatOwner(dashboardID: $0, profile: activeProfile) }
        if farChat != far { farChat = far }
    }

    /// Whether the chat on screen is the dashboard in scope's: only its
    /// own runtime's events and actions reach it.
    var chatOnScreenIsInScope: Bool { chatOnScreenDashboardID == activeDashboardID }

    /// Where an action on the chat on screen runs (`ChatRuntimeRoute`).
    var chatRuntimeRoute: ChatRuntimeRoute {
        guard !chatOnScreenIsInScope else { return .inScope }
        guard let runtime = runtime(for: chatOnScreenDashboardID) else { return .unreachable }
        return .far(runtime)
    }

    /// Runs an action on the chat on screen on the chat's own runtime when
    /// that isn't the one acting now: `body` again in its scope, across its
    /// awaits. Nil when it's in scope already, so the caller goes on;
    /// `unreachable` when its dashboard isn't connected.
    func onChatRuntime<T>(unreachable: T, _ body: () async -> T) async -> T? {
        switch chatRuntimeRoute {
        case .inScope: return nil
        case .far(let runtime): return await actAcrossAwaits(onRuntime: runtime) { await body() }
        case .unreachable: return unreachable
        }
    }

    /// `onChatRuntime` for a step that can't wait: synchronous, in the
    /// chat's scope; nothing runs when its dashboard isn't connected.
    func onChatRuntimeNow(_ body: () -> Void) {
        switch chatRuntimeRoute {
        case .inScope: body()
        case .far(let runtime): act(onRuntime: runtime, body)
        case .unreachable: break
        }
    }

    /// A value read for the chat on screen, in its own runtime's scope:
    /// what it goes by and whose host serves it (its Artifacts, its
    /// checklists, its cards). `unreachable` when its dashboard isn't
    /// connected.
    func onChatRuntimeValue<T>(unreachable: T, _ body: () -> T) -> T {
        switch chatRuntimeRoute {
        case .inScope: return body()
        case .far(let runtime): return act(onRuntime: runtime, body)
        case .unreachable: return unreachable
        }
    }

    // MARK: - Its folder

    /// Whether the chat on screen's folder can be moved (the Folder tab's
    /// Work Here in This Chat): on its own dashboard for a far chat.
    var canMoveChatOnScreenFolder: Bool {
        onChatRuntimeValue(unreachable: false) { canMoveOpenChatFolder }
    }

    /// Moves the chat on screen's folder there, on its own dashboard's
    /// runtime for a far chat.
    func moveChatOnScreenFolder(to folder: String) async -> ChatFolderMoveResult {
        let unreachable = ChatFolderMoveResult.failed(AppLocalization.string("Reconnect to Hermes to move this conversation."))
        if let routed = await onChatRuntime(unreachable: unreachable, { await moveOpenChatFolder(to: folder, reloadsProjects: false) }) {
            return routed
        }
        return await moveOpenChatFolder(to: folder)
    }

    // MARK: - Its title menu

    /// The chat on screen's row, which its title menu acts on. A far
    /// chat's comes from its own runtime's list, read in that scope (this
    /// dashboard's rows can share its id), and names its dashboard, so
    /// Rename and Delete run there even if the screen moves on before the
    /// user confirms. Nil while that dashboard isn't connected. Uncached:
    /// the screen's cache follows only the screen's list, and a far chat's
    /// list is short (the rows its open and the Chats list's read seeded).
    var chatOnScreenSessionSummary: SessionSummary? {
        guard farChat != nil else { return activeChatSessionSummary }
        switch chatRuntimeRoute {
        case .inScope: return uncachedActiveChatSessionSummary()
        case .far(let runtime):
            guard var row = act(onRuntime: runtime, { uncachedActiveChatSessionSummary(includingCronRuns: false) }) else { return nil }
            row.combinedDashboardID = farChatDashboardID
            return row
        case .unreachable: return nil
        }
    }

    /// Runs a chat action (Rename, Delete) for another combined
    /// dashboard's row on that dashboard's runtime, with the row as its
    /// own list has it. Nil for this dashboard's row, so the caller goes on;
    /// false, with a notice, when that dashboard isn't connected.
    func onCombinedDashboard(of session: SessionSummary, _ body: (SessionSummary) async -> Bool) async -> Bool? {
        guard let dashboardID = session.combinedDashboardID, dashboardID != activeDashboardID else { return nil }
        var local = session
        local.combinedDashboardID = nil
        guard let runtime = runtime(for: dashboardID) else {
            showSessionMutationNotice(AppLocalization.string("Reconnect to Hermes to change this conversation."))
            return false
        }
        return await actAcrossAwaits(onRuntime: runtime) { await body(local) }
    }

    // MARK: - The composer's session state

    /// The chat on screen's session state (its model, reasoning, YOLO and
    /// context use): another combined dashboard's for a chat opened in
    /// place there, empty while that connection is down.
    var chatRuntimeState: RuntimeState {
        guard farChat != nil else { return runtime }
        return chatOnScreenRuntime?.runtime ?? RuntimeState()
    }

    /// Changes the chat on screen's session state, on its own runtime.
    func updateChatRuntimeState(_ change: (inout RuntimeState) -> Void) {
        guard farChat != nil else { return change(&runtime) }
        guard let chatRuntime = chatOnScreenRuntime else { return }
        change(&chatRuntime.runtime)
    }

    /// The chat on screen's client: another combined dashboard's kept one
    /// for a far chat, nil while its connection is down.
    var chatClient: HermesClient? {
        guard farChat != nil else { return client }
        return chatOnScreenRuntime?.client
    }

    /// The models the chat on screen's Hermes offers it, read on its own
    /// runtime: another combined dashboard's for a far chat. Nil when it
    /// didn't answer or its connection is down.
    func loadChatModelProviders(sessionId: String?, refresh: Bool) async -> [ProviderInfo]? {
        switch chatRuntimeRoute {
        case .inScope: return await loadModelProviders(sessionId: sessionId, refresh: refresh)
        case .far(let runtime):
            return await actAcrossAwaits(onRuntime: runtime) { await loadModelProviders(sessionId: sessionId, refresh: refresh) }
        case .unreachable: return nil
        }
    }

    /// Those models as last read for the chat on screen's dashboard and
    /// profile, kept on the phone.
    func keptChatModelProviders() -> [ProviderInfo] {
        switch chatRuntimeRoute {
        case .inScope: return keptModelProviders()
        case .far(let runtime): return act(onRuntime: runtime) { keptModelProviders() }
        case .unreachable: return []
        }
    }

    /// The Model sheet's Edit filters for the chat on screen: its own
    /// dashboard's, as kept for it (per dashboard).
    var chatModelVisibility: ModelVisibility {
        guard let farChat else { return modelVisibility }
        return storedModelVisibilities()[Self.dashboardPreferenceBucket(farChat.dashboardID)] ?? ModelVisibility()
    }

    /// Saves the Model sheet's Edit filters under the chat on screen's own
    /// dashboard, its connection up or not.
    func saveChatModelVisibility(_ visibility: ModelVisibility) {
        guard let farChat else { return saveModelVisibility(visibility) }
        guard let chatRuntime = runtime(for: farChat.dashboardID) else {
            // Its runtime has gone: kept for its dashboard all the same.
            return saveModelVisibility(visibility, dashboardID: farChat.dashboardID)
        }
        act(onRuntime: chatRuntime) { saveModelVisibility(visibility) }
    }

    /// The pinned and recent models for the chat on screen: its own
    /// dashboard's, as kept for it (per dashboard).
    var chatModelQuickPicks: ModelQuickPicks {
        guard let farChat else { return modelQuickPicks }
        return storedModelQuickPicks()[Self.dashboardPreferenceBucket(farChat.dashboardID)] ?? ModelQuickPicks()
    }

    /// Changes the chat on screen's dashboard's pinned and recent models.
    func updateChatModelQuickPicks(_ change: (inout ModelQuickPicks) -> Void) {
        guard let farChat else { return updateModelQuickPicks(change) }
        guard let chatRuntime = runtime(for: farChat.dashboardID) else {
            // Its runtime has gone: kept for its dashboard all the same.
            return updateModelQuickPicks(change, dashboardID: farChat.dashboardID)
        }
        act(onRuntime: chatRuntime) {
            // Its runtime's copy may not have been read from what's kept.
            chatRuntime.modelQuickPicks = chatModelQuickPicks
            updateModelQuickPicks(change)
        }
    }

    // MARK: - Opening

    /// Opens another combined dashboard's Chats row in place, on that
    /// dashboard's runtime through its kept connection, with no switch: a
    /// bot's Bot Chat too, once that dashboard's bots name it
    /// (openFarBotChatInPlace). False when it can't (not kept connected, its
    /// socket can't be handed to a client on the row's profile, or a Bot
    /// Chat only its title tells, whose bot isn't read yet): the caller
    /// switches as before.
    func openFarChatInPlace(_ session: SessionSummary, in dashboardID: UUID) -> Bool {
        if isFarBotChat(session, in: dashboardID) { return openFarBotChatInPlace(session, in: dashboardID) != nil }
        return startFarChatOpen(session, in: dashboardID) != nil
    }

    /// The bot whose Bot Chat another combined dashboard's row is, by its
    /// bots as its kept runtime or Bots Home read them: by the row's ids or
    /// the lineage root a compacted Bot Chat keeps. The kept runtime's own
    /// copy first, as its open looks the bot up there.
    func farBot(for session: SessionSummary, in dashboardID: UUID) -> BotProfile? {
        var ids = Set(SessionContentSearch.identities(of: session))
        if let root = session.lineageRootId.flatMap(ChatScrollIdentityNormalization.sessionID) { ids.insert(root) }
        return farBot(named: ids, in: dashboardID)
    }

    /// The bot of another combined dashboard whose canonical Bot Chat one
    /// of `ids` is, by its kept runtime's bots, then Bots Home's read of
    /// them (kept when its connection drops).
    func farBot(named ids: Set<String>, in dashboardID: UUID) -> BotProfile? {
        farBotRoster(in: dashboardID).first { bot in
            // Its canonical id or the id Hermes resolved it to, as
            // isFarBotChat tells the row.
            [bot.canonicalSession?.id, bot.canonicalSession?.resolvedID]
                .compactMap { $0.flatMap(ChatScrollIdentityNormalization.sessionID) }
                .contains(where: ids.contains)
        }
    }

    /// The bot profile the chat on screen belongs to on another combined
    /// dashboard: by that dashboard's own Bot Chat registry (its runtime's,
    /// whatever runs in scope), else by that dashboard's bots (its kept
    /// roster, else Bots Home's read) naming the chat's open id alone. Nil
    /// for an ordinary chat.
    func farBotChatProfile(in dashboardID: UUID) -> String? {
        guard let open = activeSessionId.flatMap(ChatScrollIdentityNormalization.sessionID) else { return nil }
        if let profile = keptDashboardRuntimes[dashboardID]?.runtime.botChatSessionProfiles[open] { return profile }
        // Its runtime let go, or a replacement one (a reconnect) whose
        // registry hasn't heard of it yet: that dashboard's own bots naming
        // the far chat's own open id (farChat owns it while set), never ids
        // the dashboard on screen holds.
        return farBot(named: [open], in: dashboardID)?.name
    }

    /// Opens another combined dashboard's Bot Chat in place, as a Bot Chat
    /// opens on screen (its bot's lookup, then its chat in the bot's
    /// profile), on that dashboard's runtime through its kept connection
    /// and across its awaits, with no switch. Its client stays the kept
    /// one's: a Bot Chat rides its bot's profile on any client, as on
    /// screen. Nil when it can't: not kept connected, or no bot of its
    /// names the row.
    @discardableResult
    func openFarBotChatInPlace(_ session: SessionSummary, in dashboardID: UUID) -> Task<Bool, Never>? {
        guard let bot = farBot(for: session, in: dashboardID) else { return nil }
        return openFarBotChatInPlace(of: bot, in: dashboardID)
    }

    /// Opens `bot`'s Bot Chat on another combined dashboard in place, as
    /// above: a widget's or Siri's tap on it names the chat by its id alone.
    @discardableResult
    func openFarBotChatInPlace(of bot: BotProfile, in dashboardID: UUID) -> Task<Bool, Never>? {
        guard let runtime = farBotChatRuntime(in: dashboardID) else { return nil }
        ensureKeptPluginReport(for: dashboardID)
        widgetLaunchCoordinator.supersede()
        return Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.actAcrossAwaits(onRuntime: runtime) { await self.openBotChat(for: bot) }
        }
    }

    /// Another combined dashboard's kept runtime a Bot Chat of its opens on
    /// in place: kept connected, not the dashboard on screen.
    func farBotChatRuntime(in dashboardID: UUID) -> DashboardRuntime? {
        guard dashboardID != dashboardIDOnScreen, isInCombinedGroup(dashboardID),
              let kept = keptDashboardRuntimes[dashboardID], kept.client.isConnected else { return nil }
        return kept.runtime
    }

    /// The open `openFarChatInPlace` starts, for a caller that waits on it
    /// (a push, whose card lands once its chat is up). `prepare` runs on
    /// that dashboard's runtime just before the open (a push records its
    /// card there). Nil when it can't open in place.
    func startFarChatOpen(
        _ session: SessionSummary,
        in dashboardID: UUID,
        prepare: () -> Void = {},
        onFailure: (@MainActor (_ sessionWasNotFound: Bool) -> Void)? = nil,
        onFailed: (@MainActor (_ refused: Bool) -> Void)? = nil
    ) -> Task<Bool, Never>? {
        guard dashboardID != dashboardIDOnScreen, isInCombinedGroup(dashboardID),
              !isFarBotChat(session, in: dashboardID),
              let runtime = keptRuntime(dashboardID, on: session.profile ?? "default") else { return nil }
        // Its list as the Chats list read it, for the open to find the row
        // (its title, its saved copy, its profile) as a row here is found.
        seedFarChatList(runtime, from: dashboardID, with: session)
        widgetLaunchCoordinator.supersede()
        return act(onRuntime: runtime) {
            prepare()
            return requestOpenSession(session.id, onFailure: onFailure, onFailed: onFailed)
        }
    }

    /// Whether another dashboard's row is a bot's Bot Chat, by its bots as
    /// Bots Home or its kept runtime read them, or by the title only a Bot
    /// Chat carries.
    func isFarBotChat(_ session: SessionSummary, in dashboardID: UUID) -> Bool {
        let roster = (combinedDashboardBots[dashboardID]?.bots ?? [])
            + (keptDashboardRuntimes[dashboardID]?.runtime.botRoster ?? [])
        // A Bot Chat compacted into a new row keeps its first id as its
        // lineage root, which is the id the roster names.
        let lineageRoot = session.lineageRootId.flatMap(ChatScrollIdentityNormalization.sessionID)
        return BotChatHygiene.isCanonicalBotChatRow(session, roster: roster)
            || BotChatHygiene.isReservedCanonicalTitleRow(session)
            || (lineageRoot.map { root in roster.contains { $0.canonicalSessionID == root } } ?? false)
    }

    /// A kept dashboard's runtime on `profile`: as kept, or with its socket
    /// handed to a client on that profile, as a profile switch keeps the
    /// socket. Nil when it isn't kept connected or the socket can't be
    /// handed on (a large frame still going out, for one).
    func keptRuntime(_ dashboardID: UUID, on profile: String) -> DashboardRuntime? {
        guard let kept = keptDashboardRuntimes[dashboardID], kept.client.isConnected else { return nil }
        let runtime = kept.runtime
        guard (kept.client.profile ?? "default") != profile else { return runtime }
        // The socket stays the same, so the chats it opened there go on
        // streaming, to the new client.
        guard kept.client.canHandOffSocket else { return nil }
        let transportFactory: @MainActor () -> any HermesWebSocketTransport = chatResumeLifecycleOperations.makeTransport ?? { URLSessionWebSocketTransport() }
        let access = dashboardScopedCloudflareAccess(for: kept.connection.baseUrl)
        // Not `makeClient`: that points the client's events at the screen.
        // `keep` below points them at this dashboard's own.
        let next = HermesClient(
            connection: kept.connection,
            profile: profile,
            cloudflareAccess: access,
            requestAuthorizer: kept.bridge.requestAuthorizer,
            transportFactory: transportFactory
        )
        next.setKeepaliveBackgrounded(!isSceneActive && hasEnteredBackgroundScenePhase)
        next.inheritSessionProfiles(from: kept.client)
        // Its chat on screen, on the old profile, saves under that profile
        // now: the open that follows flushes it again on the new one, and
        // skips it there (`flushPendingPresentationCache`).
        if farChat?.dashboardID == dashboardID { flushPendingPresentationCache() }
        noteFollowedChatProfiles(of: dashboardID, on: next)
        // A live call held on this dashboard keeps its requests in flight
        // and its sessions on its own profile, as `keptClient(_:of:on:)` and a
        // profile switch carry it (`keep` below names the call's profile
        // for its sessions). Asked directly, not through `liveCallHolds`,
        // so it holds whichever dashboard is in scope.
        let carriesCall = isLiveCallUp && liveCallDashboardID == dashboardID
        guard kept.client.handOffSocket(
            to: next, carryingSessions: carriesCall ? callSessionIDs : [], carryingCallRequests: carriesCall
        ) else {
            next.disconnect()
            return nil
        }
        // The lists it kept were its last profile's: the next read fills
        // this one's.
        runtime.sessions = []
        if runtime.keptListsProfile != nil { runtime.keptListsProfile = profile }
        keep(KeptDashboardRuntime(
            client: next,
            bridge: kept.bridge,
            connection: kept.connection,
            keptAt: kept.keptAt,
            runtime: runtime
        ), for: dashboardID)
        noteConnectionStep("Kept socket handed to another profile for a chat there")
        return runtime
    }

    /// The chats followed on `dashboardID` (the one open in place, ones
    /// left mid-reply) were never noted on its kept client when they were
    /// on its own profile: a client on another profile taking its socket
    /// names their profile for them.
    func noteFollowedChatProfiles(of dashboardID: UUID, on next: HermesClient) {
        if let farChat, farChat.dashboardID == dashboardID {
            // A far Bot Chat's requests name its bot's profile, as its open
            // scoped them, not the workspace profile it opened on.
            let profile = farBotChatProfile(in: dashboardID) ?? farChat.profile
            next.noteSessionProfile(profile, for: (offlineChatIdentities() ?? []).map(Optional.some) + [activeSessionId])
        }
        for chat in backgroundChats where chat.dashboardID == dashboardID {
            next.noteSessionProfile(chat.profile, for: chat.sessionIDs.map(Optional.some))
        }
    }

    /// The open finds the row (its title, saved copy and profile) in its
    /// runtime's list as it does here: a kept runtime with no list of its
    /// own takes its profile's rows from the Chats list's read of that
    /// dashboard, and one whose kept list lacks the row (kept before the
    /// chat was made) takes the row itself.
    private func seedFarChatList(_ runtime: DashboardRuntime, from dashboardID: UUID, with session: SessionSummary) {
        func local(_ row: SessionSummary) -> SessionSummary {
            var row = row
            row.combinedDashboardID = nil
            return row
        }
        if runtime.sessions.isEmpty, let read = combinedDashboardChats[dashboardID] {
            let profile = runtime.activeProfile
            runtime.sessions = read.sessions.filter { ($0.profile ?? "default") == profile }.map(local)
        }
        guard !runtime.sessions.contains(where: { $0.id == session.id }) else { return }
        runtime.sessions.insert(local(session), at: 0)
    }

    // MARK: - Its events and its connection

    /// Whether a kept dashboard's turn event is for a chat followed there:
    /// the chat on screen, when it's that dashboard's, or one left
    /// mid-reply there.
    func keptDashboardFollowsChats(_ id: UUID) -> Bool {
        farChatDashboardID == id || backgroundChats.contains { $0.dashboardID == id }
    }

    /// A kept dashboard's connection came back (signed in again quietly):
    /// its chat on screen resumes through it, as a reconnect resumes
    /// the one on screen's.
    func resumeFarChatAfterReconnect(_ id: UUID) {
        guard let farChat, farChat.dashboardID == id,
              let runtime = keptRuntime(id, on: farChat.profile) else { return }
        // A new runtime came with the new connection: its changes redraw
        // the chat.
        republishRuntime(runtime, for: Self.farChatSurface)
        act(onRuntime: runtime) {
            Task { @MainActor [weak self] in await self?.refreshActiveSession() }
        }
    }

    /// A chat sync where the chat on screen and the dashboard acted on
    /// aren't the dashboard on screen's chat and runtime: the chat resumes
    /// on its own runtime (`refreshActiveSession`, a plain re-resume, which
    /// reads no list there), and only the dashboard on screen reads its
    /// list, as its sync would. Another dashboard's list is the Chats
    /// list's own read of it (`readOtherCombinedDashboardsChats`), never
    /// written through this one's list state.
    func syncBesideFarChat(
        using reconciliationToken: UUID?,
        onCatalogPublished: () -> Void
    ) async -> ChatResumeSyncExecutionOutcome {
        // A reconcile begun for the sync of the chat on screen is its
        // resume's to begin anew.
        if let reconciliationToken, chatOnScreenIsInScope || actingOnRuntimeOnScreen {
            _ = settleReconciliation(reconciliationToken)
        }
        if !actingOnRuntimeOnScreen {
            // On another dashboard's runtime: its own chat on screen resumes
            // here; the chat of any other dashboard isn't its to touch.
            if chatOnScreenIsInScope { await refreshActiveSession() }
            return .completed
        }
        // The dashboard on screen's sync, with another dashboard's chat on
        // screen: that chat resumes on its own runtime, or once its
        // dashboard is back (`resumeFarChatAfterReconnect`).
        if case .far(let runtime) = chatRuntimeRoute {
            act(onRuntime: runtime) {
                Task { @MainActor [weak self] in await self?.refreshActiveSession() }
            }
        }
        guard client != nil else { return .completed }
        if await loadSessions(forceRefresh: true, requiredViewportTransitionGeneration: nil, reportsFailure: false) {
            onCatalogPublished()
        }
        return .completed
    }
}
