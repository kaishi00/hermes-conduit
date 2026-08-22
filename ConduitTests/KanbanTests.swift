import XCTest
@testable import Conduit

@MainActor
final class KanbanTests: XCTestCase {
    // MARK: - Workflow capability model (upstream LOCKED_COLUMNS parity)

    func testSidebarMigrationMapsRemovedCapabilitiesToSessions() {
        XCTAssertEqual(SidebarTab.migrated(rawValue: "Capabilities"), .sessions)
        XCTAssertEqual(SidebarTab.migrated(rawValue: "not-a-tab"), .sessions)
        XCTAssertEqual(SidebarTab.migrated(rawValue: "Kanban"), .kanban)
    }

    func testLockedLanesMatchUpstreamAndAreNotManualDestinations() {
        // apps/desktop/src/plugins/kanban/ui.tsx: LOCKED_COLUMNS
        XCTAssertEqual(KanbanStatusPresentation.lockedDestinations, ["review", "running", "scheduled"])

        for lane in ["review", "running", "scheduled"] {
            XCTAssertFalse(KanbanStatusPresentation.canCreateTask(in: lane), lane)
            XCTAssertFalse(KanbanStatusPresentation.canSelectManually(lane), lane)
            let presentation = KanbanStatusPresentation.forStatus(lane)
            XCTAssertTrue(presentation.isVisibleOnBoard, lane)
            XCTAssertTrue(presentation.isBackendControlled, lane)
        }
        XCTAssertFalse(KanbanStatusPresentation.manuallySelectableStatuses.contains { $0.rawValue == "review" })
        XCTAssertFalse(KanbanStatusPresentation.manuallySelectableStatuses.contains { $0.rawValue == "scheduled" })
        XCTAssertFalse(KanbanStatusPresentation.taskCreatableStatuses.contains { $0.rawValue == "review" })
        XCTAssertFalse(KanbanStatusPresentation.taskCreatableStatuses.contains { $0.rawValue == "scheduled" })
        XCTAssertFalse(KanbanStatusPresentation.taskCreatableStatuses.contains { $0.rawValue == "running" })
    }

    func testUnlockedCreationTargetsMatchUpstreamAddableColumns() {
        let creatable = Set(KanbanStatusPresentation.taskCreatableStatuses.map { $0.rawValue })
        XCTAssertEqual(creatable, ["triage", "todo", "ready", "blocked", "done"])
        XCTAssertTrue(KanbanStatusPresentation.canSelectManually("archived"))
        XCTAssertFalse(KanbanStatusPresentation.canCreateTask(in: "archived"))
    }

    func testUnknownStatusHasSafeLockedFallback() {
        let presentation = KanbanStatusPresentation.forStatus("awaiting_customer")
        XCTAssertEqual(presentation.displayName, "Awaiting Customer")
        XCTAssertTrue(presentation.isBackendControlled)
        XCTAssertFalse(KanbanStatusPresentation.canCreateTask(in: "awaiting_customer"))
        XCTAssertFalse(KanbanStatusPresentation.canSelectManually("awaiting_customer"))
    }

    // MARK: - Transport contract

    func testBoardSelectionIsQueryScopedAndNeverSwitchesServerBoard() async throws {
        let requester = MockKanbanRequester(responsesByPath: [
            "/api/plugins/kanban/board": ["columns": [], "tenants": [], "assignees": []]
        ])
        let service = KanbanService(requester: requester)
        _ = try await service.fetchBoard(slug: "mobile board", includeArchived: true)
        XCTAssertEqual(requester.calls[0].path, "/api/plugins/kanban/board?board=mobile%20board&include_archived=true")
        XCTAssertEqual(requester.calls[0].method, "GET")
    }

    func testUnicodeBoardSlugSurvivesEncoding() async throws {
        let slug = "b\u{00F6}ard \u{65E5}\u{672C}"
        let requester = MockKanbanRequester(responsesByPath: [
            "/api/plugins/kanban/board": ["columns": [], "tenants": [], "assignees": []]
        ])
        let service = KanbanService(requester: requester)
        _ = try await service.fetchBoard(slug: slug, includeArchived: false)
        let path = try XCTUnwrap(requester.calls.first?.path)
        XCTAssertTrue(path.hasPrefix("/api/plugins/kanban/board?board="))
        XCTAssertFalse(path.contains(" "), "spaces must be percent-encoded")
        XCTAssertTrue(path.lowercased().contains("%c3%b6"), "non-ASCII must be UTF-8 percent-encoded")
    }

    func testPluginRequestsNeverCarryFabricatedProfileScope() async throws {
        var responses = standardKanbanResponses()
        responses["/api/plugins/kanban/tasks"] = ["task": ["id": "t1", "title": "x", "status": "todo"]]
        let requester = MockKanbanRequester(responsesByPath: responses)
        let store = makeStore(requester: requester)
        await store.reload()

        _ = try? await store.createTask(KanbanCreateTaskRequest(title: "No profile param"))

        for call in requester.calls {
            XCTAssertFalse(call.path.contains("profile="), call.path)
        }
    }

    // MARK: - Creation transaction

    func testLockedLaneCreationIsRejectedBeforeAnyPost() async throws {
        var responses = standardKanbanResponses()
        responses["/api/plugins/kanban/tasks"] = ["task": ["id": "SHOULD-NOT-EXIST", "title": "x", "status": "todo"]]
        let requester = MockKanbanRequester(responsesByPath: responses)
        let store = makeStore(requester: requester)

        do {
            _ = try await store.createTask(KanbanCreateTaskRequest(title: "Never"), initialStatus: "scheduled")
            XCTFail("scheduled creation must be rejected client-side")
        } catch let error as KanbanServiceError {
            XCTAssertEqual(error, .invalidManualStatus("scheduled"))
        }
        do {
            _ = try await store.createTask(KanbanCreateTaskRequest(title: "Never 2"), initialStatus: "review")
            XCTFail("review creation must be rejected client-side")
        } catch {}

        XCTAssertEqual(requester.calls.filter { $0.method == "POST" && ($0.path.hasSuffix("/tasks") || $0.path.contains("/tasks?")) }.count, 0)
        XCTAssertNotNil(store.mutationErrorMessage)
    }

    func testTwoStepCreationFailureSurfacesPartialSuccessWithoutDuplicatePost() async throws {
        var responses = standardKanbanResponses()
        responses["/api/plugins/kanban/tasks"] = ["task": ["id": "task-1", "title": "Blocked pick", "status": "todo"]]
        let requester = MockKanbanRequester(
            responsesByPath: responses,
            errorsByPath: ["/api/plugins/kanban/tasks/task-1": MockRequestError.failed("parent dependency blocks Blocked")]
        )
        let store = makeStore(requester: requester)

        do {
            _ = try await store.createTask(KanbanCreateTaskRequest(title: "Blocked pick"), initialStatus: "blocked")
            XCTFail("follow-up transition should fail")
        } catch let error as KanbanServiceError {
            guard case .taskCreatedButMoveFailed(let taskID, let target, let reason) = error else {
                return XCTFail("expected partial-success error, got \(error)")
            }
            XCTAssertEqual(taskID, "task-1")
            XCTAssertEqual(target, "blocked")
            XCTAssertTrue(reason.contains("parent dependency"))
        }

        XCTAssertEqual(requester.calls.filter { $0.method == "POST" && ($0.path.hasSuffix("/tasks") || $0.path.contains("/tasks?")) }.count, 1)
        XCTAssertTrue(store.mutationErrorMessage?.contains("not duplicated") == true)
    }

    // MARK: - Dispatcher nudge

    func testMutationReturnsBeforeNudgeFiresAndNudgeUsesCapturedBoardContext() async throws {
        var responses = standardKanbanResponses()
        responses["/api/plugins/kanban/tasks/t1"] = ["task": ["id": "t1", "title": "Done", "status": "done"]]
        let requester = MockKanbanRequester(responsesByPath: responses)
        let store = makeStore(requester: requester, nudgeDebounceNanoseconds: 40_000_000)
        await store.selectBoard(slug: "alpha")

        _ = try await store.updateTask(id: "t1", patch: KanbanTaskPatch(status: "done"))
        // Fire-and-forget: the write resolved before the debounced dispatch.
        XCTAssertFalse(requester.calls.contains { $0.path.contains("/dispatch") })

        await flushNudge()
        let dispatchCalls = requester.calls.filter { $0.path.contains("/dispatch") }
        XCTAssertEqual(dispatchCalls.count, 1)
        XCTAssertEqual(dispatchCalls.first?.method, "POST")
        XCTAssertTrue(dispatchCalls.first?.path.contains("board=alpha") == true)
    }

    func testDispatchFailureIsNonFatalAndRapidWritesCoalesce() async throws {
        var responses = standardKanbanResponses()
        responses["/api/plugins/kanban/tasks/t1"] = ["task": ["id": "t1", "title": "A", "status": "done"]]
        let requester = MockKanbanRequester(
            responsesByPath: responses,
            errorsByPath: ["/api/plugins/kanban/dispatch": MockRequestError.failed("dispatcher unavailable")]
        )
        let store = makeStore(requester: requester, nudgeDebounceNanoseconds: 30_000_000)
        await store.selectBoard(slug: "alpha")

        _ = try await store.updateTask(id: "t1", patch: KanbanTaskPatch(title: "A"))
        _ = try await store.updateTask(id: "t1", patch: KanbanTaskPatch(title: "AA"))
        await flushNudge()

        XCTAssertEqual(requester.calls.filter { $0.path.contains("/dispatch") }.count, 1)
        XCTAssertNil(store.mutationErrorMessage)
    }

    // MARK: - Immutable mutation context across board switches

    func testInFlightMutationKeepsCapturedBoardAcrossSwitch() async throws {
        var responses = standardKanbanResponses(boardSlug: "alpha")
        responses["/api/plugins/kanban/tasks/t1"] = ["task": ["id": "t1", "title": "Moved title", "status": "todo"]]
        let requester = MockKanbanRequester(responsesByPath: responses)
        let store = makeStore(requester: requester, nudgeDebounceNanoseconds: 30_000_000)
        await store.selectBoard(slug: "alpha")

        requester.hold(pathPrefix: "/api/plugins/kanban/tasks/t1")
        let mutation = Task { try? await store.updateTask(id: "t1", patch: KanbanTaskPatch(title: "Moved title")) }
        // Let the mutation reach (and park at) the held PATCH.
        await Task.yield(); await Task.yield(); await Task.yield()

        await store.selectBoard(slug: "beta")
        requester.releaseAll()
        _ = await mutation.value
        await flushNudge()

        let patchCall = requester.calls.last(where: { $0.method == "PATCH" })
        XCTAssertTrue(patchCall?.path.contains("board=alpha") == true)
        let nudgeCall = requester.calls.last(where: { $0.path.contains("/dispatch") })
        XCTAssertTrue(nudgeCall?.path.contains("board=alpha") == true)
        XCTAssertNil(store.mutationErrorMessage)
        XCTAssertEqual(store.selectedBoardSlug, "beta")
    }

    func testStaleStateAfterServerReconfigureIsDiscarded() async throws {
        var responsesA = standardKanbanResponses(boardSlug: "a-board")
        responsesA["/api/plugins/kanban/board"] = [
            "columns": [["name": "todo", "tasks": [["id": "1", "title": "from A", "status": "todo"]]]],
            "tenants": [], "assignees": []
        ]
        let requesterA = MockKanbanRequester(responsesByPath: responsesA)
        let store = makeStore(requester: requesterA)
        store.configure(requester: requesterA, serverIdentity: "https://a.test")
        await store.reload()
        XCTAssertEqual(store.board?.columns.first?.tasks.first?.title, "from A")

        var responsesB = standardKanbanResponses(boardSlug: "b-board")
        responsesB["/api/plugins/kanban/board"] = [
            "columns": [["name": "todo", "tasks": [["id": "2", "title": "from B", "status": "todo"]]]],
            "tenants": [], "assignees": []
        ]
        store.configure(
            requester: MockKanbanRequester(responsesByPath: responsesB),
            serverIdentity: "https://b.test"
        )
        XCTAssertEqual(store.selectedBoardSlug, "", "selection from server A must not bleed into server B")
        await store.reload()
        XCTAssertEqual(store.board?.columns.first?.tasks.first?.title, "from B")
    }

    // MARK: - Persistence scoping

    func testBoardSelectionPersistenceIsScopedToServerIdentity() {
        let keyA = KanbanStore.scopedBoardKey(serverIdentity: "https://one.test")
        let keyB = KanbanStore.scopedBoardKey(serverIdentity: "https://two.test")
        XCTAssertNotEqual(keyA, keyB)
        XCTAssertEqual(keyA, KanbanStore.scopedBoardKey(serverIdentity: "https://one.test/"))
        XCTAssertTrue(keyA.hasPrefix(KanbanStore.selectedBoardKey + "."))
    }

    // MARK: - Mutation vs refresh error separation

    func testMutationFailureStaysVisibleAndRefreshFailureKeepsBoard() async throws {
        var responses = standardKanbanResponses()
        responses["/api/plugins/kanban/tasks/t1"] = ["task": ["id": "t1", "title": "T", "status": "todo"]]
        let requester = MockKanbanRequester(responsesByPath: responses)
        let store = makeStore(requester: requester)
        await store.refresh()
        XCTAssertNotNil(store.board)

        requester.errorsByPath["/api/plugins/kanban/boards"] = MockRequestError.failed("temporary refresh failure")
        await store.refresh()
        XCTAssertNotNil(store.board)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(store.mutationErrorMessage)

        requester.errorsByPath.removeValue(forKey: "/api/plugins/kanban/boards")
        requester.errorsByPath["/api/plugins/kanban/tasks/t1"] = MockRequestError.failed("task was deleted")
        do {
            _ = try await store.updateTask(id: "t1", patch: KanbanTaskPatch(title: "Nope"))
            XCTFail("mutation should fail")
        } catch {
            XCTAssertTrue(store.mutationErrorMessage?.contains("task was deleted") == true)
        }
    }

    // MARK: - Draft preservation policy

    func testDetailPollingPreservesDirtyDraftAndFlagsRemoteChange() {
        // load "Original" -> user edits -> server says "Server change"
        let dirty = KanbanDetailDraftPolicy.isDirty(
            draftTitle: "My draft", draftBody: "", draftStatus: "todo",
            baselineTitle: "Original", baselineBodyText: "", baselineStatus: "todo"
        )
        XCTAssertTrue(dirty)
        let moved = KanbanDetailDraftPolicy.serverMovedIndependently(
            serverTitle: "Server change", serverBodyText: "", serverStatus: "todo",
            baselineTitle: "Original", baselineBodyText: "", baselineStatus: "todo"
        )
        XCTAssertTrue(moved)

        // Clean draft adopts the server snapshot without any notice.
        XCTAssertFalse(KanbanDetailDraftPolicy.isDirty(
            draftTitle: "Original", draftBody: "", draftStatus: "todo",
            baselineTitle: "Original", baselineBodyText: "", baselineStatus: "todo"
        ))
    }

    // MARK: - Tolerant decoding must not crash on hostile numbers

    func testLossyIntDecodingHandlesExtremeAndMalformedValues() throws {
        let json = "{\"id\":\"t\",\"title\":\"x\",\"status\":\"todo\",\"priority\":1e999,\"created_at\":2.5,\"comment_count\":-3,\"started_at\":\"7\",\"worker_pid\":\"not-a-number\"}"
        let task = try JSONDecoder().decode(KanbanTask.self, from: Data(json.utf8))
        XCTAssertNil(task.priority, "unrepresentable huge double must decode as nil, not crash")
        XCTAssertEqual(task.createdAt, 2)
        XCTAssertEqual(task.commentCount, -3)
        XCTAssertEqual(task.startedAt, 7)
        XCTAssertNil(task.workerPid)
    }

    // MARK: - Helpers

    private func makeStore(
        requester: MockKanbanRequester,
        nudgeDebounceNanoseconds: UInt64? = nil
    ) -> KanbanStore {
        let store = KanbanStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            serviceFactory: nudgeDebounceNanoseconds.map { ns in
                { request in KanbanService(requester: request, nudgeDebounceNanoseconds: ns) }
            }
        )
        store.configure(requester: requester, serverIdentity: "https://example.test")
        return store
    }

    private func flushNudge() async {
        // The instrumented debounce is tens of milliseconds; wait past it and
        // give the scheduled task a few ticks to finish its POST.
        try? await Task.sleep(nanoseconds: 250_000_000)
        await Task.yield()
    }
}

private enum MockRequestError: LocalizedError {
    case failed(String)
    var errorDescription: String? { switch self { case .failed(let m): return m } }
}

@MainActor
private final class MockKanbanRequester: DashboardJSONRequester {
    struct Call {
        let path: String
        let method: String
        let body: [String: Any]?
    }

    var responsesByPath: [String: [String: Any]]
    var errorsByPath: [String: Error]
    private var holdsActive: Set<String> = []
    private var heldContinuations: [CheckedContinuation<Void, Never>] = []
    var calls: [Call] = []

    init(responsesByPath: [String: [String: Any]] = [:], errorsByPath: [String: Error] = [:]) {
        self.responsesByPath = responsesByPath
        self.errorsByPath = errorsByPath
    }

    /// Park every request whose path starts with the prefix until releaseAll().
    func hold(pathPrefix: String) { holdsActive.insert(pathPrefix) }

    func releaseAll() {
        holdsActive.removeAll()
        for continuation in heldContinuations { continuation.resume() }
        heldContinuations.removeAll()
    }

    func requestJSON(path: String, method: String, body: [String: Any]?, timeoutMilliseconds: Int, maxResponseBytes: Int) async throws -> [String: Any] {
        calls.append(Call(path: path, method: method, body: body))
        let basePath = path.components(separatedBy: "?").first ?? path
        if !holdsActive.isEmpty, holdsActive.contains(where: { path.hasPrefix($0) || basePath.hasPrefix($0) }) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                heldContinuations.append(continuation)
            }
        }
        if let error = errorsByPath[path] ?? errorsByPath[basePath] { throw error }
        if let response = responsesByPath[path] ?? responsesByPath[basePath] { return response }
        return [:]
    }
}

private func standardKanbanResponses(boardSlug: String = "default") -> [String: [String: Any]] {
    [
        "/api/plugins/kanban/boards": [
            "boards": [
                ["slug": boardSlug, "name": boardSlug, "is_current": true],
                ["slug": "beta", "name": "Beta", "is_current": false],
                ["slug": "alpha", "name": "Alpha", "is_current": false]
            ],
            "current": boardSlug
        ],
        "/api/plugins/kanban/board": ["columns": [], "tenants": [], "assignees": [], "latest_event_id": 1, "now": 2],
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
