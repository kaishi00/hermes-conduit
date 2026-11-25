//
//  AppState+ChatKanbanTasks.swift
//  Conduit
//
//  The open chat's Kanban tasks (desktop issue 553), for the line above
//  its composer: the cards it handed to the board, on every board, from the
//  plugin's `GET /sessions/kanban-tasks`.
//

import Foundation

extension AppState {
    /// The open chat's Kanban tasks, by the id Hermes stores it under, in
    /// the profile it runs under, as the Context sheet reads its usage
    /// (`openChatUsageSessionID`). Nil when there's nothing to say: no open
    /// chat, no connection, a plugin without the route, a Hermes that
    /// doesn't stamp cards with their chat, a chat Hermes has no row for
    /// yet, a failed read, or a dashboard that changed while it was out.
    func loadOpenChatKanbanTasks() async -> ChatKanbanTasks? {
        guard activeSessionId != nil else { return nil }
        // Another combined dashboard's chat on screen: read on its own
        // runtime, from its own dashboard and profile (AppState+FarChat.swift).
        if let routed = await onChatRuntime(unreachable: ChatKanbanTasks?.none, { await loadOpenChatKanbanTasks() }) {
            return routed
        }
        guard let sessionID = openChatUsageSessionID(),
              let route = ChatKanbanTasks.route(sessionID: sessionID),
              isConnected, let owner = currentDashboardRuntimeOwner() else { return nil }
        if case .reported(_, let capabilities) = notifierPlugin.state,
           !capabilities.contains(ChatKanbanTasks.capability) { return nil }
        if case .predatesCapabilities = notifierPlugin.state { return nil }
        let path = DashboardPath.withProfile(route, profile: conversationIdentityProfile)
        guard let response = try? await owner.bridge.requestJSON(path: path), ownsDashboardRuntime(owner) else { return nil }
        let answer = ChatKanbanTasks(response: response)
        return answer.supported ? answer : nil
    }

    /// Opens one of the open chat's Kanban tasks in Tasks, on whichever
    /// board holds it. Only for a chat on this dashboard: Tasks shows this
    /// dashboard's boards.
    var canOpenChatKanbanTask: Bool { chatOnScreenIsInScope }

    func openChatKanbanTask(_ task: ChatKanbanTask) {
        guard canOpenChatKanbanTask else { return }
        kanbanTaskOpenRequest = KanbanTaskOpenRequest(taskID: task.taskID, dashboardID: activeDashboardID)
    }
}
