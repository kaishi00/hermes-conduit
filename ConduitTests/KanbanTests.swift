import XCTest
@testable import Conduit

@MainActor
final class KanbanTests: XCTestCase {
    func testSidebarMigrationMapsRemovedCapabilitiesToSessions() {
        XCTAssertEqual(SidebarTab.migrated(rawValue: "Capabilities"), .sessions)
        XCTAssertEqual(SidebarTab.migrated(rawValue: "not-a-tab"), .sessions)
        XCTAssertEqual(SidebarTab.migrated(rawValue: "Kanban"), .kanban)
    }

    func testUnknownStatusHasSafeFallbackPresentation() {
        let presentation = KanbanStatusPresentation.forStatus("awaiting_customer")
        XCTAssertEqual(presentation.rawValue, "awaiting_customer")
        XCTAssertEqual(presentation.displayName, "Awaiting Customer")
        XCTAssertEqual(presentation.systemImage, "circle.dashed")
        XCTAssertEqual(presentation.sortOrder, 100)
    }

    func testTaskDecodingToleratesNumericIdentifiersAndMissingOptionalFields() throws {
        let data = Data(#"{"id":42,"title":"Needs review","status":"review","priority":"2"}"#.utf8)
        let task = try JSONDecoder().decode(KanbanTask.self, from: data)
        XCTAssertEqual(task.id, "42")
        XCTAssertEqual(task.title, "Needs review")
        XCTAssertEqual(task.status, "review")
        XCTAssertEqual(task.priority, 2)
        XCTAssertNil(task.assignee)
    }

    func testBoardSelectionIsSentAsQueryAndNeverSwitchesServerBoard() async throws {
        let requester = MockKanbanRequester(responses: [
            ["columns": [], "tenants": [], "assignees": [], "latest_event_id": 1, "now": 2]
        ])
        let service = KanbanService(requester: requester)
        _ = try await service.fetchBoard(slug: "mobile board", includeArchived: true)
        XCTAssertEqual(requester.calls.count, 1)
        XCTAssertEqual(requester.calls[0].path, "/api/plugins/kanban/board?board=mobile%20board&include_archived=true")
        XCTAssertEqual(requester.calls[0].method, "GET")
    }

    func testCreateTaskUsesDashboardTaskContract() async throws {
        let requester = MockKanbanRequester(responses: [
            ["task": ["id": "task-1", "title": "Ship it", "status": "todo"]]
        ])
        let service = KanbanService(requester: requester)
        let response = try await service.createTask(
            KanbanCreateTaskRequest(title: "Ship it", body: "Details", assignee: "worker", priority: 2),
            board: "mobile"
        )
        XCTAssertEqual(response.task?.id, "task-1")
        XCTAssertEqual(requester.calls[0].path, "/api/plugins/kanban/tasks?board=mobile")
        XCTAssertEqual(requester.calls[0].method, "POST")
        XCTAssertEqual(requester.calls[0].body?["title"] as? String, "Ship it")
        XCTAssertEqual(requester.calls[0].body?["workspace_kind"] as? String, "scratch")
        XCTAssertEqual(requester.calls[0].body?["priority"] as? Int, 2)
    }

    func testPatchOnlyContainsExplicitMutationFields() async throws {
        let requester = MockKanbanRequester(responses: [
            ["task": ["id": "task-1", "title": "Ship it", "status": "done"]]
        ])
        let service = KanbanService(requester: requester)
        _ = try await service.updateTask(id: "task-1", board: nil, patch: KanbanTaskPatch(status: "done"))
        XCTAssertEqual(requester.calls[0].body?.keys.sorted(), ["status"])
        XCTAssertEqual(requester.calls[0].body?["status"] as? String, "done")
    }
}

@MainActor
private final class MockKanbanRequester: DashboardJSONRequester {
    struct Call {
        let path: String
        let method: String
        let body: [String: Any]?
    }

    var responses: [[String: Any]]
    var calls: [Call] = []

    init(responses: [[String: Any]]) {
        self.responses = responses
    }

    func requestJSON(path: String, method: String, body: [String: Any]?, timeoutMilliseconds: Int, maxResponseBytes: Int) async throws -> [String: Any] {
        calls.append(Call(path: path, method: method, body: body))
        guard !responses.isEmpty else { return [:] }
        return responses.removeFirst()
    }
}
