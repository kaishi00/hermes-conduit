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

    /// The dashboard the chat on screen belongs to.
    var chatOnScreenDashboardID: UUID? { farChatDashboardID ?? dashboardIDOnScreen }

    /// The chat on screen's runtime: the one on screen's, or another
    /// combined dashboard's (nil when that one's connection dropped).
    var chatOnScreenRuntime: DashboardRuntime? {
        guard let farChatDashboardID else { return runtimeOnScreen }
        return runtime(for: farChatDashboardID)
    }

    /// Whether the chat on screen can reach Hermes: its own dashboard's
    /// connection, which for a far chat isn't the one on screen's.
    var chatIsConnected: Bool {
        guard farChatDashboardID != nil else { return isConnected }
        return chatOnScreenRuntime?.isConnected ?? false
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

    // MARK: - Opening

    /// Opens another combined dashboard's Chats row in place, on that
    /// dashboard's runtime through its kept connection, with no switch.
    /// False when it can't (not kept connected, or its socket can't be
    /// handed to a client on the row's profile): the caller switches as
    /// before.
    func openFarChatInPlace(_ session: SessionSummary, in dashboardID: UUID) -> Bool {
        guard dashboardID != dashboardIDOnScreen, isInCombinedGroup(dashboardID),
              let runtime = keptRuntime(dashboardID, on: session.profile ?? "default") else { return false }
        // Its list as the Chats list read it, for the open to find the row
        // (its title, its saved copy, its profile) as a row here is found.
        seedFarChatList(runtime, from: dashboardID, with: session)
        widgetLaunchCoordinator.supersede()
        act(onRuntime: runtime) {
            _ = requestOpenSession(session.id)
        }
        return true
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
        guard kept.client.handOffSocket(to: next) else {
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
