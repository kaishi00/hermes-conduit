import XCTest
@testable import Conduit

/// Kanban V3C: multi-select + bulk operations (wire contracts, ownership
/// races, immutable capture, per-ID reconciliation, delete fanout with ONE
/// authoritative reconciliation, selection ownership/pruning).
///
/// Deterministic: no sleeps; continuation-handshake + provider-keyed mock.
@MainActor
final class KanbanV3CTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore(requester: V3CMockRequester) -> KanbanStore {
        let store = KanbanStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.configure(requester: requester, serverIdentity: "https://a.test")
        return store
    }

    private func stamp(_ slug: String = "alpha", generation: Int) -> KanbanBoardContextStamp {
        KanbanBoardContextStamp(boardSlug: slug, configurationGeneration: generation)
    }

    // MARK: - Wire contracts

    func testBulkMoveWireContract() async throws {
        let requester = V3CMockRequester()
        requester.bulkUpdateResponse = [
            "results": [
                ["id": "t-1", "ok": true],
                ["id": "t-2", "ok": true],
            ],
        ]
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        let outcome = try await store.bulkUpdateTasks(
            ids: ["t-1", "t-2"],
            patch: KanbanBulkTaskRequest(ids: ["t-1", "t-2"], status: "ready"),
            expectedContext: stampA
        )

        let calls = requester.calls.filter { $0.method == "POST" && $0.path.contains("/tasks/bulk") }
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].path.hasPrefix("/api/plugins/kanban/tasks/bulk?board=alpha"), "board param: \(calls[0].path)")
        XCTAssertEqual(calls[0].body?["ids"] as? [String], ["t-1", "t-2"])
        XCTAssertEqual(calls[0].body?["status"] as? String, "ready")
        XCTAssertNil(calls[0].body?["assignee"])
        XCTAssertNil(calls[0].body?["priority"])
        XCTAssertNil(calls[0].body?["archive"])
        XCTAssertNil(calls[0].body?["reclaim_first"])
        XCTAssertEqual(outcome.succeededIDs, ["t-1", "t-2"])
        XCTAssertTrue(outcome.failures.isEmpty)
    }

    func testNormalizedBulkIDsDedupeTrimAndOrder() {
        XCTAssertEqual(
            KanbanStore.normalizedBulkIDs(["  t-1 ", "t-2", "t-2", " t-1", "", "   ", "t-3"]),
            ["t-1", "t-2", "t-3"],
            "whitespace trimmed, empties dropped, duplicates first-wins, order preserved"
        )
        XCTAssertEqual(KanbanStore.normalizedBulkIDs([]), [])
    }

    func testBulkAssignWireContract() async throws {
        let requester = V3CMockRequester()
        requester.bulkUpdateResponse = ["results": [["id": "t-1", "ok": true]]]
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        _ = try await store.bulkUpdateTasks(
            ids: ["t-1"],
            patch: KanbanBulkTaskRequest(ids: ["t-1"], assignee: "coder", reclaimFirst: true),
            expectedContext: stampA
        )
        let call = requester.calls.first { $0.method == "POST" && $0.path.contains("/tasks/bulk") }
        XCTAssertEqual(call?.body?["assignee"] as? String, "coder")
        XCTAssertEqual(call?.body?["reclaim_first"] as? Bool, true, "Desktop parity: explicit assignment reclaims first")
        XCTAssertNil(call?.body?["status"])
        XCTAssertNil(call?.body?["priority"])
        XCTAssertNil(call?.body?["archive"])
    }

    func testBulkUnassignWireContract() async throws {
        let requester = V3CMockRequester()
        requester.bulkUpdateResponse = ["results": [["id": "t-1", "ok": true]]]
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        _ = try await store.bulkUpdateTasks(
            ids: ["t-1"],
            patch: KanbanBulkTaskRequest(ids: ["t-1"], assignee: "", reclaimFirst: true),
            expectedContext: stampA
        )
        let call = requester.calls.first { $0.method == "POST" && $0.path.contains("/tasks/bulk") }
        XCTAssertEqual(call?.body?["assignee"] as? String, "", "explicit empty string = unassign (never resolved_default_assignee)")
        XCTAssertEqual(call?.body?["reclaim_first"] as? Bool, true)
    }

    func testBulkPriorityWireContract() async throws {
        let requester = V3CMockRequester()
        requester.bulkUpdateResponse = ["results": [["id": "t-1", "ok": true]]]
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        _ = try await store.bulkUpdateTasks(
            ids: ["t-1"],
            patch: KanbanBulkTaskRequest(ids: ["t-1"], priority: -2),
            expectedContext: stampA
        )
        let call = requester.calls.first { $0.method == "POST" && $0.path.contains("/tasks/bulk") }
        XCTAssertEqual(call?.body?["priority"] as? Int, -2, "verbatim integer; no invented 1-5 scale")
        XCTAssertNil(call?.body?["status"])
        XCTAssertNil(call?.body?["assignee"])
    }

    func testBulkArchiveWireContract() async throws {
        let requester = V3CMockRequester()
        requester.bulkUpdateResponse = ["results": [["id": "t-1", "ok": true]]]
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        _ = try await store.bulkUpdateTasks(
            ids: ["t-1"],
            patch: KanbanBulkTaskRequest(ids: ["t-1"], archive: true),
            expectedContext: stampA
        )
        let call = requester.calls.first { $0.method == "POST" && $0.path.contains("/tasks/bulk") }
        XCTAssertEqual(call?.body?["archive"] as? Bool, true)
        XCTAssertNil(call?.body?["status"], "archived tasks are not also moved to a lane")
        XCTAssertNil(call?.body?["assignee"])
        XCTAssertNil(call?.body?["priority"])
    }

    func testBulkDeleteFansOutPerTaskWithOneReconciliation() async throws {
        let requester = V3CMockRequester()
        requester.deleteTaskResults = [
            "t-1": KanbanBulkTaskResult(id: "t-1", ok: true),
            "t-2": KanbanBulkTaskResult(id: "t-2", ok: false, error: "not found"),
            "t-3": KanbanBulkTaskResult(id: "t-3", ok: true),
        ]
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }
        let boardFetchesBefore = requester.boardFetches
        let boardsFetchesBefore = requester.boardsFetches

        let outcome = try await store.bulkDeleteTasks(ids: ["t-1", "t-2", "t-3"], expectedContext: stampA)

        // ONE DELETE per ID; NO invented bulk-delete route.
        XCTAssertFalse(requester.calls.contains { $0.path.contains("/tasks/bulk/delete") || $0.path.contains("bulk/delete") }, "no invented bulk-delete route")
        let deletes = requester.calls.filter { $0.method == "DELETE" && $0.path.contains("/tasks/") }
        XCTAssertEqual(Set(deletes.map { $0.path.components(separatedBy: "?").first! }),
                       Set(["/api/plugins/kanban/tasks/t-1", "/api/plugins/kanban/tasks/t-2", "/api/plugins/kanban/tasks/t-3"]))
        for d in deletes {
            XCTAssertTrue(d.path.contains("board=alpha"), "every DELETE carries the captured concrete board slug: \(d.path)")
        }
        // Exactly ONE post-operation authoritative reconciliation.
        XCTAssertEqual(requester.boardFetches - boardFetchesBefore, 1, "one board reload, not N")
        XCTAssertEqual(requester.boardsFetches - boardsFetchesBefore, 1, "one boards refresh, not N")

        XCTAssertEqual(outcome.succeededIDs, ["t-1", "t-3"])
        XCTAssertEqual(outcome.failures, [KanbanBulkFailure(id: "t-2", reason: "not found")])
    }

    func testBulkDeletePerIDTransportFailuresSettleAsPerIDOutcomes() async throws {
        let requester = V3CMockRequester()
        requester.errorsByPath["/api/plugins/kanban/tasks/t-1"] = URLError(.cannotConnectToHost)
        requester.errorsByPath["/api/plugins/kanban/tasks/t-2"] = URLError(.cannotConnectToHost)
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        // Per-ID transport failures are per-ID failures (nothing cancels
        // siblings); every request settles and each ID has its own outcome.
        let outcome = try await store.bulkDeleteTasks(ids: ["t-1", "t-2"], expectedContext: stampA)
        XCTAssertEqual(outcome.succeededIDs, [])
        XCTAssertEqual(outcome.failures.map(\.id), ["t-1", "t-2"])
        XCTAssertNil(store.mutationErrorMessage, "per-ID outcomes are not a top-level operation failure")
    }

    // MARK: - Ownership

    func testBulkUpdateContextMismatchFailsClosed() async throws {
        let requester = V3CMockRequester()
        requester.bulkUpdateResponse = ["results": [["id": "t-1", "ok": true]]]
        let store = makeStore(requester: requester)
        await store.reload()
        // Capture the ALPHA stamp while alpha is still loaded/actionable.
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }
        XCTAssertEqual(stampA.boardSlug, "alpha")
        // Move to beta; the alpha stamp is now stale.
        await store.selectBoard(slug: "beta")
        XCTAssertEqual(store.loadedBoardSlug, "beta")

        do {
            _ = try await store.bulkUpdateTasks(
                ids: ["t-1"],
                patch: KanbanBulkTaskRequest(ids: ["t-1"], status: "ready"),
                expectedContext: stampA
            )
            XCTFail("a stale alpha stamp must fail closed while beta is loaded")
        } catch KanbanServiceError.boardNavigationInProgress {
            // expected
        } catch {
            XCTFail("unexpected: \(error)")
        }
        XCTAssertTrue(requester.calls.filter { $0.method == "POST" && $0.path.contains("/tasks/bulk") }.isEmpty, "zero POST")
    }

    func testBulkUpdateCapturedContextSurvivesBoardSwitchDuringFlight() async throws {
        // The operation context is captured BEFORE the first suspension; a
        // board switch while the request is parked cannot retarget it.
        let requester = V3CMockRequester()
        requester.bulkUpdateResponse = ["results": [["id": "t-1", "ok": true]]]
        requester.suspend(method: "POST", basePath: "/api/plugins/kanban/tasks/bulk")
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        let task = Task { try await store.bulkUpdateTasks(ids: ["t-1"], patch: KanbanBulkTaskRequest(ids: ["t-1"], status: "ready"), expectedContext: stampA) }
        await requester.waitForSuspension()
        await store.selectBoard(slug: "beta")
        requester.resumeSuspended()

        _ = try await task.value
        let call = requester.calls.first { $0.method == "POST" && $0.path.contains("/tasks/bulk") }
        XCTAssertTrue(call?.path.contains("board=alpha") == true, "request still targets the CAPTURED board alpha: \(call?.path ?? "nil")")
        XCTAssertEqual(call?.body?["ids"] as? [String], ["t-1"])
    }

    func testEmptyBulkIDsRejectedBeforeAnyRequest() async throws {
        let requester = V3CMockRequester()
        requester.bulkUpdateResponse = ["results": []]
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        do {
            _ = try await store.bulkUpdateTasks(ids: [], patch: KanbanBulkTaskRequest(ids: [], status: "ready"), expectedContext: stampA)
            XCTFail("empty ids must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No tasks selected"), "reason: \(error.localizedDescription)")
        }
        do {
            _ = try await store.bulkDeleteTasks(ids: [], expectedContext: stampA)
            XCTFail("empty ids must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No tasks selected"))
        }
        XCTAssertTrue(requester.calls.filter { $0.method == "POST" || $0.method == "DELETE" }.isEmpty)
    }

    // MARK: - Reconciliation (pure policy)

    func testPartialFailureReconciliationRetainsFailedIDs() {
        let outcome = KanbanBulkResultPolicy.reconcile(
            requestedIDs: ["A", "B", "C"],
            results: [
                KanbanBulkTaskResult(id: "A", ok: true),
                KanbanBulkTaskResult(id: "B", ok: false, error: "running task is claimed"),
                KanbanBulkTaskResult(id: "C", ok: true),
            ]
        )
        XCTAssertEqual(outcome.succeededIDs, ["A", "C"])
        XCTAssertEqual(outcome.failures, [KanbanBulkFailure(id: "B", reason: "running task is claimed")])
        // Desktop parity: after completion, selection = failed IDs only.
        let next = KanbanBulkResultPolicy.selectionAfterApplying(outcome: outcome, originalSelection: ["A", "B", "C"])
        XCTAssertEqual(next, ["B"])
        // Multiple distinct failures all surface in the detail list.
        XCTAssertEqual(KanbanBulkResultPolicy.failures(from: outcome).count, 1)
    }

    func testMissingOutcomeNeverCountsAsSuccess() {
        let outcome = KanbanBulkResultPolicy.reconcile(
            requestedIDs: ["A", "B"],
            results: [KanbanBulkTaskResult(id: "A", ok: true)]
        )
        XCTAssertEqual(outcome.succeededIDs, ["A"])
        XCTAssertEqual(outcome.failures, [KanbanBulkFailure(id: "B", reason: "Hermes returned no result for this task.")],
                       "a requested ID with no outcome is a failure, never declared success")
    }

    func testDuplicateOutcomeFirstWinsAndUnexpectedIDsIgnored() {
        let outcome = KanbanBulkResultPolicy.reconcile(
            requestedIDs: ["A", "B"],
            results: [
                KanbanBulkTaskResult(id: "A", ok: true),
                KanbanBulkTaskResult(id: "A", ok: false, error: "second"),
                KanbanBulkTaskResult(id: "X", ok: true),
            ]
        )
        XCTAssertEqual(outcome.succeededIDs, ["A"], "first outcome wins")
        XCTAssertEqual(outcome.failures, [KanbanBulkFailure(id: "B", reason: "Hermes returned no result for this task.")])
        XCTAssertFalse(outcome.succeededIDs.contains("X"), "unexpected extra response ID never enters the outcome")
    }

    func testSelectionPrunesIdsRemovedByAuthoritativeRefresh() {
        XCTAssertEqual(
            KanbanBulkSelectionPolicy.prune(selected: ["A", "B", "C"], aliveTaskIDs: ["A", "C"]),
            ["A", "C"]
        )
        XCTAssertEqual(
            KanbanBulkSelectionPolicy.prune(selected: ["A", "B"], aliveTaskIDs: ["A", "B", "C"]),
            ["A", "B"],
            "tasks that moved lanes still exist on the board - never pruned"
        )
    }

    func testSelectionOwnershipRequiresExactStamp() {
        let alphaStamp = stamp("alpha", generation: 4)
        let betaStamp = stamp("beta", generation: 4)
        XCTAssertTrue(KanbanBulkSelectionPolicy.isOwned(selectionContext: alphaStamp, currentStamp: alphaStamp, isSnapshotActionable: true))
        XCTAssertFalse(KanbanBulkSelectionPolicy.isOwned(selectionContext: alphaStamp, currentStamp: betaStamp, isSnapshotActionable: true), "board change: selection invalid")
        XCTAssertFalse(KanbanBulkSelectionPolicy.isOwned(selectionContext: alphaStamp, currentStamp: nil, isSnapshotActionable: true))
        XCTAssertFalse(KanbanBulkSelectionPolicy.isOwned(selectionContext: nil, currentStamp: alphaStamp, isSnapshotActionable: true))
        XCTAssertFalse(KanbanBulkSelectionPolicy.isOwned(selectionContext: alphaStamp, currentStamp: alphaStamp, isSnapshotActionable: false), "non-actionable board: selection invalid")
    }

    func testMoveDestinationsExcludeLockedAndArchived() {
        let destinations = KanbanBulkDestinationPolicy.moveDestinations().map(\.rawValue)
        XCTAssertFalse(destinations.contains("scheduled"))
        XCTAssertFalse(destinations.contains("running"))
        XCTAssertFalse(destinations.contains("review"))
        XCTAssertFalse(destinations.contains("archived"), "Archive is a dedicated action, never a Move lane")
        XCTAssertTrue(destinations.contains("triage"))
        XCTAssertTrue(destinations.contains("todo"))
        XCTAssertTrue(destinations.contains("ready"))
        XCTAssertTrue(destinations.contains("blocked"))
        XCTAssertTrue(destinations.contains("done"))
    }

    // MARK: - Top-level request failure semantics

    func testBulkUpdateTopLevelTransportFailureThrows() async throws {
        let requester = V3CMockRequester()
        requester.errorsByPath["/api/plugins/kanban/tasks/bulk"] = URLError(.notConnectedToInternet)
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        do {
            _ = try await store.bulkUpdateTasks(ids: ["t-1"], patch: KanbanBulkTaskRequest(ids: ["t-1"], status: "ready"), expectedContext: stampA)
            XCTFail("top-level transport failure must throw")
        } catch {
            XCTAssertNotNil(store.mutationErrorMessage, "the store surfaces the mutation error")
        }
    }
}

/// Deterministic V3C mock: continuation-handshake suspension + per-task DELETE
/// results + bulk POST response; counts every board fetch for reconciliation
/// assertions.
@MainActor
private final class V3CMockRequester: DashboardJSONRequester {
    struct Call {
        let path: String
        let method: String
        let body: [String: Any]?
    }

    static let baseBoards: [[String: Any]] = [
        ["slug": "alpha", "name": "Alpha", "archived": false],
        ["slug": "beta", "name": "Beta", "archived": false],
        ["slug": "default", "name": "Default", "archived": false],
    ]

    static func board(columns: [[String: Any]]) -> [String: Any] {
        ["columns": columns, "tenants": ["project-a"], "assignees": ["coder", "reviewer"], "latest_event_id": 1, "now": 2]
    }

    static let defaultBoard: [String: Any] = board(columns: [
        ["name": "triage", "tasks": []],
        ["name": "todo", "tasks": []],
        ["name": "running", "tasks": []],
    ])

    var bulkUpdateResponse: [String: Any] = ["results": []]
    var deleteTaskResults: [String: KanbanBulkTaskResult] = [:]
    var errorsByPath: [String: Error] = [:]
    var boardFetches = 0
    var boardsFetches = 0
    var calls: [Call] = []

    private var suspendEntries: [(method: String, basePath: String)] = []
    private var suspended: [CheckedContinuation<Void, Never>] = []
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend(method: String, basePath: String) {
        suspendEntries.append((method, basePath))
    }

    func waitForSuspension() async {
        if !suspended.isEmpty { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            suspensionWaiters.append(continuation)
        }
    }

    func resumeSuspended() {
        let pending = suspended
        suspended.removeAll()
        pending.forEach { $0.resume() }
    }

    func requestJSON(path: String, method: String, body: [String: Any]?, timeoutMilliseconds: Int, maxResponseBytes: Int) async throws -> [String: Any] {
        let call = Call(path: path, method: method, body: body)
        calls.append(call)
        let basePath = path.components(separatedBy: "?").first ?? path

        if suspendEntries.contains(where: { $0.method == method && $0.basePath == basePath }) {
            suspendEntries.removeAll { $0.method == method && $0.basePath == basePath }
            suspensionWaiters.forEach { $0.resume() }
            suspensionWaiters.removeAll()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                suspended.append(continuation)
            }
        }

        if let error = errorsByPath[path] ?? errorsByPath[basePath] { throw error }

        if method == "GET", basePath == "/api/plugins/kanban/boards" {
            boardsFetches += 1
            return ["boards": Self.baseBoards, "current": "alpha"]
        }
        if method == "GET", basePath == "/api/plugins/kanban/board" {
            boardFetches += 1
            return Self.defaultBoard
        }
        if method == "POST", basePath == "/api/plugins/kanban/tasks/bulk" {
            return bulkUpdateResponse
        }
        if method == "DELETE", basePath.hasPrefix("/api/plugins/kanban/tasks/") {
            let id = String(basePath.dropFirst("/api/plugins/kanban/tasks/".count))
            if let result = deleteTaskResults[id] {
                if result.ok { return [:] }
                throw V3CBulkTestError.refused(result.error ?? "refused")
            }
            return [:] // per-task ok by default
        }
        if method == "GET", basePath == "/api/plugins/kanban/orchestration" {
            return ["orchestrator_profile": "", "default_assignee": "", "auto_decompose": true, "auto_promote_children": true,
                    "resolved_orchestrator_profile": "default", "resolved_default_assignee": "coder", "active_profile": "default"]
        }
        if method == "GET", basePath == "/api/plugins/kanban/profiles" {
            return ["profiles": [["name": "coder"], ["name": "reviewer"]]]
        }
        if method == "GET", basePath == "/api/plugins/kanban/projects" {
            return ["projects": []]
        }
        return [:]
    }
}

/// Errors for the V3C mock (localized so error.localizedDescription is stable).
struct V3CBulkTestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    static func refused(_ reason: String) -> V3CBulkTestError {
        V3CBulkTestError(message: reason)
    }
}
