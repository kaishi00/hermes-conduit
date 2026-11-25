//
//  ChatKanbanTasks.swift
//  Conduit
//
//  The Kanban tasks a chat handed to the board (desktop issue 553), for the
//  line above its composer. Hermes stamps each card `kanban_create` makes
//  with the chat's session, and a worker's own cards inherit it, so a
//  squad's fan-out counts too. The notifier plugin finds them on every board,
//  through the chat's compressions (`GET /sessions/kanban-tasks`, plugin
//  0.197.0+). Hermes keeps the tasks; Conduit only reads them.
//

import Foundation

struct ChatKanbanTask: Equatable, Identifiable {
    let taskID: String
    let title: String
    /// Hermes' lane: triage, todo, scheduled, ready, running, blocked, review, done.
    let status: String
    let assignee: String?
    let board: String
    let boardName: String
    /// Why it's blocked, only while it is.
    let error: String?

    /// One task id can be on two boards.
    var id: String { "\(board)\n\(taskID)" }
    var isOpen: Bool { status != "done" && status != "archived" }
    var isBlocked: Bool { status == "blocked" }

    init(taskID: String, title: String, status: String, assignee: String? = nil,
         board: String = "default", boardName: String = "default", error: String? = nil) {
        self.taskID = taskID
        self.title = title
        self.status = status
        self.assignee = assignee
        self.board = board
        self.boardName = boardName
        self.error = error
    }
}

struct ChatKanbanTasks: Equatable {
    static let capability = "chat-kanban-tasks"
    static let path = "/api/plugins/conduit_push/sessions/kanban-tasks"
    /// Between two reads while a task is still open.
    static let refreshInterval: Duration = .seconds(15)

    /// False when this Hermes doesn't stamp cards with their chat: nothing to show.
    var supported = false
    var tasks: [ChatKanbanTask] = []

    /// The route for one chat, without its profile, which the request adds
    /// (`DashboardPath.withProfile`).
    static func route(sessionID: String) -> String? {
        guard let id = DashboardPath.encodedQueryComponent(sessionID) else { return nil }
        return "\(path)?session_id=\(id)"
    }

    init(response: [String: Any]) {
        supported = (response["supported"] as? Bool) == true
        let rows = response["tasks"] as? [[String: Any]] ?? []
        tasks = rows.compactMap { row in
            let text = { (key: String) -> String? in
                let value = (row[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return value?.isEmpty == false ? value : nil
            }
            guard let id = text("id"), let board = text("board") else { return nil }
            return ChatKanbanTask(
                taskID: id,
                title: text("title") ?? id,
                status: text("status")?.lowercased() ?? "",
                assignee: text("assignee"),
                board: board,
                boardName: text("board_name") ?? board,
                error: text("error")
            )
        }
    }

    init(supported: Bool = false, tasks: [ChatKanbanTask] = []) {
        self.supported = supported
        self.tasks = tasks
    }

    /// The tasks the line shows: every open one, and the finished ones once
    /// the chat has seen any of its tasks open while it showed. A chat
    /// reopened after all its tasks finished shows nothing; its finished
    /// cards live on the board.
    static func shown(_ tasks: [ChatKanbanTask], seenOpen: Set<String>) -> [ChatKanbanTask] {
        guard tasks.contains(where: \.isOpen) || tasks.contains(where: { seenOpen.contains($0.id) }) else { return [] }
        return tasks.filter { $0.isOpen || seenOpen.contains($0.id) }
    }

    /// "2 Kanban tasks in progress", then how many are blocked; "Kanban
    /// tasks finished" once none is open.
    static func label(_ tasks: [ChatKanbanTask]) -> String {
        let blockedCount = tasks.filter(\.isBlocked).count
        let inProgressCount = tasks.filter(\.isOpen).count - blockedCount
        if inProgressCount > 0, blockedCount > 0 {
            return AppLocalization.string("\(inProgressCount) Kanban tasks in progress", table: .chat)
                + " · " + AppLocalization.string("\(blockedCount) blocked", table: .chat)
        }
        if blockedCount > 0 { return AppLocalization.string("\(blockedCount) Kanban tasks blocked", table: .chat) }
        if inProgressCount > 0 { return AppLocalization.string("\(inProgressCount) Kanban tasks in progress", table: .chat) }
        return AppLocalization.string("Kanban tasks finished", table: .chat)
    }
}
