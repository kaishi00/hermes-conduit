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
        XCTAssertFalse(presentation.isManuallySelectable)
        XCTAssertFalse(presentation.isTaskCreatable)
    }

    func testRunningIsVisibleButNotManuallySelectableOrCreatable() {
        let running = KanbanStatusPresentation.forStatus("running")
        XCTAssertTrue(running.isVisibleOnBoard)
        XCTAssertTrue(running.isBackendControlled)
        XCTAssertFalse(running.isManuallySelectable)
        XCTAssertFalse(running.isTaskCreatable)
        XCTAssertFalse(KanbanStatusPresentation.canSelectManually("running"))
        XCTAssertFalse(KanbanStatusPresentation.canCreateTask(in: "running"))
        XCTAssertFalse(KanbanStatusPresentation.manuallySelectableStatuses.contains { $0.rawValue == "running" })
        XCTAssertFalse(KanbanStatusPresentation.taskCreatableStatuses.contains { $0.rawValue == "running" })
    }

    func testStoreRejectsRunningCreationWithoutPosting() async throws {
        let requester = MockKanbanRequester(responsesByPath: standardKanbanResponses())
        let store = KanbanStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.configure(requester: requester, profile: "default", serverIdentity: "https://example.test")

        do {
            _ = try await store.createTask(KanbanCreateTaskRequest(title: "Never run directly"), initialStatus: "running")
            XCTFail("Running must be rejected before create")
        } catch let error as KanbanServiceError {
            XCTAssertEqual(error, .invalidManualStatus("running"))
        }

        XCTAssertFalse(requester.calls.contains { $0.method == "POST" && $0.path.contains("/tasks") })
        XCTAssertTrue(store.mutationErrorMessage?.contains("dispatcher/claim") == true)
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

    func testProfileAndBoardQueriesAreOwnedByKanbanService() async throws {
        let requester = MockKanbanRequester(responses: [
            ["columns": [], "tenants": [], "assignees": []]
        ])
        let service = KanbanService(requester: requester, profile: "work")
        _ = try await service.fetchBoard(slug: "mobile", includeArchived: false)
        XCTAssertEqual(requester.calls[0].path, "/api/plugins/kanban/board?board=mobile&profile=work")
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

    func testTwoStepCreationReportsPartialSuccessWithoutASecondCreate() async throws {
        var responses = standardKanbanResponses()
        responses["/api/plugins/kanban/tasks"] = ["task": ["id": "task-1", "title": "Scheduled", "status": "todo"]]
        responses["/api/plugins/kanban/dispatch"] = [:]
        let requester = MockKanbanRequester(
            responsesByPath: responses,
            errorsByPath: ["/api/plugins/kanban/tasks/task-1": MockRequestError.failed("parent dependency blocks Scheduled")]
        )
        let store = KanbanStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.configure(requester: requester, profile: "default", serverIdentity: "https://example.test")

        do {
            _ = try await store.createTask(KanbanCreateTaskRequest(title: "Scheduled"), initialStatus: "scheduled")
            XCTFail("The follow-up transition should fail")
        } catch let error as KanbanServiceError {
            guard case .taskCreatedButMoveFailed(let taskID, let targetStatus, let reason) = error else {
                return XCTFail("Expected an explicit partial-success error")
            }
            XCTAssertEqual(taskID, "task-1")
            XCTAssertEqual(targetStatus, "scheduled")
            XCTAssertTrue(reason.contains("parent dependency"))
        }

        XCTAssertEqual(requester.calls.filter { $0.method == "POST" && $0.path.contains("/tasks") }.count, 1)
        XCTAssertTrue(store.mutationErrorMessage?.contains("not duplicated") == true)
    }

    func testSuccessfulUpdateNudgesDispatcherAndNudgeFailureIsNonFatal() async throws {
        var responses = standardKanbanResponses()
        responses["/api/plugins/kanban/tasks/task-1"] = ["task": ["id": "task-1", "title": "Done", "status": "done"]]
        responses["/api/plugins/kanban/dispatch"] = [:]
        let requester = MockKanbanRequester(
            responsesByPath: responses,
            errorsByPath: ["/api/plugins/kanban/dispatch": MockRequestError.failed("dispatcher unavailable")]
        )
        let store = KanbanStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.configure(requester: requester, profile: "default", serverIdentity: "https://example.test")

        _ = try await store.updateTask(id: "task-1", patch: KanbanTaskPatch(status: "done"))

        XCTAssertTrue(requester.calls.contains { $0.path == "/api/plugins/kanban/dispatch" && $0.method == "POST" })
        XCTAssertNil(store.mutationErrorMessage)
    }

    func testMutationFailureIsSeparateFromBackgroundRefreshFailure() async throws {
        var responses = standardKanbanResponses()
        responses["/api/plugins/kanban/tasks/task-1"] = ["task": ["id": "task-1", "title": "Done", "status": "done"]]
        let requester = MockKanbanRequester(responsesByPath: responses)
        let store = KanbanStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.configure(requester: requester, profile: "default", serverIdentity: "https://example.test")
        await store.reload()
        XCTAssertNotNil(store.board)

        requester.errorsByPath["/api/plugins/kanban/boards"] = MockRequestError.failed("temporary refresh failure")
        await store.refresh()
        XCTAssertNotNil(store.board)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(store.mutationErrorMessage)

        requester.errorsByPath["/api/plugins/kanban/tasks/task-1"] = MockRequestError.failed("task was deleted")
        do {
            _ = try await store.updateTask(id: "task-1", patch: KanbanTaskPatch(title: "Nope"))
            XCTFail("The explicit mutation should fail")
        } catch {
            XCTAssertTrue(store.mutationErrorMessage?.contains("task was deleted") == true)
        }
    }

    func testProfileChangeReloadsWithSameBridgeAndScopesBoardSelection() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let requester = MockKanbanRequester(responsesByPath: standardKanbanResponses(boardSlug: "alpha-board"))
        let store = KanbanStore(defaults: defaults)

        store.configure(requester: requester, profile: "alpha", serverIdentity: "https://example.test")
        await store.selectBoard(slug: "alpha-board")
        XCTAssertEqual(store.selectedBoardSlug, "alpha-board")

        store.configure(requester: requester, profile: "beta", serverIdentity: "https://example.test")
        XCTAssertEqual(store.selectedBoardSlug, "")
        await store.reload()
        XCTAssertTrue(requester.calls.contains { $0.path == "/api/plugins/kanban/boards?profile=beta" })

        store.configure(requester: requester, profile: "alpha", serverIdentity: "https://example.test")
        XCTAssertEqual(store.selectedBoardSlug, "alpha-board")
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

private enum MockRequestError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
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
    var responsesByPath: [String: [String: Any]]
    var errorsByPath: [String: Error]
    var calls: [Call] = []

    init(
        responses: [[String: Any]] = [],
        responsesByPath: [String: [String: Any]] = [:],
        errorsByPath: [String: Error] = [:]
    ) {
        self.responses = responses
        self.responsesByPath = responsesByPath
        self.errorsByPath = errorsByPath
    }

    func requestJSON(path: String, method: String, body: [String: Any]?, timeoutMilliseconds: Int, maxResponseBytes: Int) async throws -> [String: Any] {
        calls.append(Call(path: path, method: method, body: body))
        let basePath = path.components(separatedBy: "?").first ?? path
        if let error = errorsByPath[path] ?? errorsByPath[basePath] { throw error }
        if let response = responsesByPath[path] ?? responsesByPath[basePath] { return response }
        guard !responses.isEmpty else { return [:] }
        return responses.removeFirst()
    }
}

private func standardKanbanResponses(boardSlug: String = "default") -> [String: [String: Any]] {
    [
        "/api/plugins/kanban/boards": [
            "boards": [["slug": boardSlug, "name": boardSlug, "is_current": true]],
            "current": boardSlug
        ],
        "/api/plugins/kanban/board": [
            "columns": [], "tenants": [], "assignees": [], "latest_event_id": 1, "now": 2
        ],
        "/api/plugins/kanban/profiles": ["profiles": []],
        "/api/plugins/kanban/projects": ["projects": []],
        "/api/plugins/kanban/orchestration": [
            "orchestrator_profile": "",
            "default_assignee": "",
            "auto_decompose": true,
            "auto_promote_children": true,
            "resolved_orchestrator_profile": "default",
            "resolved_default_assignee": "default"
        ],
        "/api/plugins/kanban/dispatch": [:]
    ]
}
