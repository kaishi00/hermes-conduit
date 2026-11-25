import XCTest
@testable import Conduit

/// The Kanban tasks a chat handed to the board (desktop issue 553).
final class ChatKanbanTasksTests: XCTestCase {
    func testTheAnswerKeepsRowsWithAnIdAndABoard() {
        let answer = ChatKanbanTasks(response: [
            "supported": true,
            "tasks": [
                ["id": "t1", "title": "Build it", "status": "Running", "assignee": "coder", "board": "research", "board_name": "Research"],
                ["id": "t2", "status": "blocked", "board": "default", "error": "worker crashed"],
                ["title": "no id", "board": "default"],
                ["id": "t3", "title": "no board"],
            ],
        ])
        XCTAssertTrue(answer.supported)
        XCTAssertEqual(answer.tasks, [
            ChatKanbanTask(taskID: "t1", title: "Build it", status: "running", assignee: "coder", board: "research", boardName: "Research"),
            ChatKanbanTask(taskID: "t2", title: "t2", status: "blocked", board: "default", boardName: "default", error: "worker crashed"),
        ])
        XCTAssertFalse(ChatKanbanTasks(response: ["tasks": []]).supported)
    }

    func testTheRouteNamesTheChat() {
        XCTAssertEqual(ChatKanbanTasks.route(sessionID: "s 1"), "/api/plugins/conduit_push/sessions/kanban-tasks?session_id=s%201")
    }

    func testFinishedTasksShowOnlyOnceTheChatSawItsTasksOpen() {
        let done = ChatKanbanTask(taskID: "a", title: "a", status: "done")
        let running = ChatKanbanTask(taskID: "b", title: "b", status: "running")
        // Reopened after everything finished: nothing.
        XCTAssertEqual(ChatKanbanTasks.shown([done], seenOpen: []), [])
        // An open one shows; a finished one never seen open stays on the board.
        XCTAssertEqual(ChatKanbanTasks.shown([done, running], seenOpen: [running.id]), [running])
        // Seen open, now finished: the line stays to say so.
        let finished = ChatKanbanTask(taskID: "b", title: "b", status: "done")
        XCTAssertEqual(ChatKanbanTasks.shown([done, finished], seenOpen: [running.id]), [finished])
    }

    func testTheLineCountsWhatsInProgressAndWhatsBlocked() {
        let running = ChatKanbanTask(taskID: "a", title: "a", status: "running")
        let queued = ChatKanbanTask(taskID: "b", title: "b", status: "todo")
        let blocked = ChatKanbanTask(taskID: "c", title: "c", status: "blocked")
        let done = ChatKanbanTask(taskID: "d", title: "d", status: "done")
        XCTAssertEqual(ChatKanbanTasks.label([running, queued]), "2 Kanban tasks in progress")
        XCTAssertEqual(ChatKanbanTasks.label([running, blocked]), "1 Kanban task in progress · 1 blocked")
        XCTAssertEqual(ChatKanbanTasks.label([blocked, done]), "1 Kanban task blocked")
        XCTAssertEqual(ChatKanbanTasks.label([done]), "Kanban tasks finished")
    }
}
