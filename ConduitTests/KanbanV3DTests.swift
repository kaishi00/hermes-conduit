import XCTest
@testable import Conduit

/// Kanban V3D: live /events WebSocket as INVALIDATION ONLY.
///
/// Deterministic: scripted sockets, continuation-gated sleepers (no sleeps),
/// continuation-handshake parking on the HTTP mock.
@MainActor
final class KanbanV3DTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore(requester: V3DMockRequester) throws -> KanbanStore {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let store = KanbanStore(defaults: defaults)
        store.configure(requester: requester, serverIdentity: "https://a.test")
        return store
    }

    private func stamp(_ slug: String = "alpha", generation: Int = 0) -> KanbanBoardContextStamp {
        KanbanBoardContextStamp(boardSlug: slug, configurationGeneration: generation)
    }

    /// MainActor drain: lets scheduled tasks/continuations run to their next
    /// suspension without wall-clock waits.
    private func drain() async {
        for _ in 0..<200 { await Task.yield() }
    }

    private func frameJSON(events: [[String: Any]], cursor: Int?) -> String {
        var object: [String: Any] = ["events": events]
        if let cursor { object["cursor"] = cursor }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    private func eventJSON(id: Int?, taskID: String?) -> [String: Any] {
        var object: [String: Any] = [:]
        if let id { object["id"] = id }
        if let taskID { object["task_id"] = taskID }
        object["kind"] = "whatever"
        return object
    }

    // MARK: - URL / auth contract

    func testConnectUsesEventsPathConcreteBoardWatermarkAndFreshTicket() async throws {
        let requester = V3DMockRequester()
        requester.boardPayload["latest_event_id"] = 42
        let store = try makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        let recorder = StreamRecorder(minterTickets: ["ticket-1"])
        let coordinator = recorder.makeCoordinator(
            stamp: stampA, boardSlug: "alpha", initialCursor: 42, baseURL: "https://a.test"
        )
        coordinator.start()
        await recorder.waitUntilURLCount(1)
        coordinator.stop()

        XCTAssertEqual(recorder.mintedTickets, ["ticket-1"], "a fresh single-use ticket per connect")
        let url = try XCTUnwrap(recorder.issuedURLs.first)
        XCTAssertEqual(url.path, "/api/plugins/kanban/events")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(query.contains(URLQueryItem(name: "board", value: "alpha")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "since", value: "42")), "starts from authoritative latest_event_id")
        XCTAssertTrue(query.contains(URLQueryItem(name: "ticket", value: "ticket-1")))
    }

    func testReconnectMintsAFreshTicketAndNeverReuses() async throws {
        let requester = V3DMockRequester()
        requester.boardPayload["latest_event_id"] = 42
        let store = try makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        // First socket fails immediately; the reconnect parks forever.
        let failingSocket = MockSocket(scripts: [.fail(URLError(.networkConnectionLost))])
        let recorder = StreamRecorder(minterTickets: ["ticket-1", "ticket-2"])
        let coordinator = recorder.makeCoordinator(
            stamp: stampA, boardSlug: "alpha", initialCursor: 42, baseURL: "https://a.test",
            sockets: [failingSocket]
        )
        coordinator.start()
        await recorder.waitUntilURLCount(2)
        coordinator.stop()

        XCTAssertEqual(recorder.mintedTickets, ["ticket-1", "ticket-2"], "every reconnect mints a FRESH ticket")
        XCTAssertTrue(failingSocket.cancelled, "the failed socket is retired (.goingAway)")
        let second = try XCTUnwrap(recorder.issuedURLs.last)
        let secondComponents = try XCTUnwrap(URLComponents(url: second, resolvingAgainstBaseURL: false))
        XCTAssertTrue(secondComponents.queryItems!.contains(where: { $0.name == "ticket" && $0.value == "ticket-2" }), "ticket-1 is NEVER reused")
    }

    func testMalformedOrMissingWatermarkMeansNoSocket() {
        XCTAssertFalse(KanbanLiveUpdatePolicy.isValidInitialWatermark(nil))
        XCTAssertFalse(KanbanLiveUpdatePolicy.isValidInitialWatermark(-1), "negative watermarks never open a stream")
        XCTAssertTrue(KanbanLiveUpdatePolicy.isValidInitialWatermark(0))
        XCTAssertNil(KanbanLiveUpdateSupport.initialWatermark(from: nil), "no board snapshot -> no watermark")
    }

    // MARK: - Cursor

    func testCursorAdvancesAndResumesAcrossReconnectWithinSameContext() async throws {
        let requester = V3DMockRequester()
        requester.boardPayload["latest_event_id"] = 40
        let store = try makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        let frame = frameJSON(events: [eventJSON(id: 41, taskID: "A"), eventJSON(id: 43, taskID: "B")], cursor: 43)
        let failing = MockSocket(scripts: [.text(frame), .fail(URLError(.networkConnectionLost))])
        let recorder = StreamRecorder(minterTickets: ["ticket-1", "ticket-2"])
        let coordinator = recorder.makeCoordinator(
            stamp: stampA, boardSlug: "alpha", initialCursor: 40, baseURL: "https://a.test",
            sockets: [failing]
        )
        coordinator.start()
        await recorder.waitUntilURLCount(2)
        coordinator.stop()

        XCTAssertEqual(coordinator.cursor, 43, "cursor advances from valid frames")
        let second = try XCTUnwrap(recorder.issuedURLs.last)
        let secondComponents = try XCTUnwrap(URLComponents(url: second, resolvingAgainstBaseURL: false))
        XCTAssertTrue(secondComponents.queryItems!.contains(where: { $0.name == "since" && $0.value == "43" }), "reconnect resumes from the decoded stream cursor")
    }

    func testCursorNeverMovesBackwards() async throws {
        let requester = V3DMockRequester()
        requester.boardPayload["latest_event_id"] = 40
        let store = try makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        let backwards = frameJSON(events: [eventJSON(id: 39, taskID: "OLD")], cursor: 38)
        let failing = MockSocket(scripts: [.text(backwards), .fail(URLError(.networkConnectionLost))])
        let recorder = StreamRecorder(minterTickets: ["ticket-1", "ticket-2"])
        let coordinator = recorder.makeCoordinator(
            stamp: stampA, boardSlug: "alpha", initialCursor: 40, baseURL: "https://a.test",
            sockets: [failing]
        )
        coordinator.start()
        await recorder.waitUntilURLCount(2)
        coordinator.stop()

        XCTAssertEqual(coordinator.cursor, 40, "the cursor never moves backwards")
        let second = try XCTUnwrap(recorder.issuedURLs.last)
        let secondComponents = try XCTUnwrap(URLComponents(url: second, resolvingAgainstBaseURL: false))
        XCTAssertTrue(secondComponents.queryItems!.contains(where: { $0.name == "since" && $0.value == "40" }))
    }

    func testBoardSwitchSubscribesFromItsOwnWatermark() {
        // Cursor/context ownership: a cursor belongs to exactly one
        // board/server context. Beta's stream starts from BETA's watermark,
        // never alpha's cursor.
        let alphaKey = KanbanLiveUpdateSupport.streamKey(
            bridgeIdentity: ObjectIdentifier(NSObject()), baseURL: "https://a.test",
            configurationGeneration: 4, loadedBoardSlug: "alpha"
        )
        let betaKey = KanbanLiveUpdateSupport.streamKey(
            bridgeIdentity: ObjectIdentifier(NSObject()), baseURL: "https://a.test",
            configurationGeneration: 4, loadedBoardSlug: "beta"
        )
        XCTAssertNotEqual(alphaKey, betaKey, "a board change retires the stream identity")

        let coordinator = StreamRecorder(minterTickets: ["t"]).makeCoordinator(
            stamp: stamp("beta", generation: 4), boardSlug: "beta", initialCursor: 7, baseURL: "https://a.test"
        )
        coordinator.start()
        XCTAssertEqual(coordinator.cursor, 7, "beta subscribes since=7, never alpha's 100")
        coordinator.stop()
    }

    // MARK: - Ownership (stale context/generation)

    func testFramesFromRetiredContextProduceZeroRequests() async throws {
        let requester = V3DMockRequester()
        let store = try makeStore(requester: requester)
        await store.reload()
        guard let stampAlpha = store.loadedContextStamp else { return XCTFail("expected context") }

        // Loaded context moves to beta: alpha-context invalidation is STALE.
        await store.selectBoard(slug: "beta")
        let boardsBefore = requester.boardsFetches

        let disposition = await store.refreshFromEvent(expectedContext: stampAlpha, includeArchived: false)
        XCTAssertEqual(disposition, .stale, "old-board frames are dropped permanently")
        XCTAssertEqual(requester.boardsFetches, boardsBefore, "zero request for a stale context")

        // Same board slug does NOT rescue a stale server generation.
        let secondRequester = V3DMockRequester()
        store.configure(requester: secondRequester, serverIdentity: "https://b.test")
        let afterServerChange = await store.refreshFromEvent(expectedContext: stampAlpha, includeArchived: false)
        XCTAssertEqual(afterServerChange, .stale, "same slug, new server generation -> still stale")
        XCTAssertTrue(secondRequester.calls.isEmpty, "generation-4 frames cause ZERO requests on the new server")
    }

    // MARK: - Coalescing

    func testCoalescingWindowUnionsTouchedIDsIntoOneRefresh() async throws {
        let requester = V3DMockRequester()
        let store = try makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        let gates = SleeperGate()
        var batches: [KanbanEventInvalidation] = []
        let coordinator = KanbanEventStreamCoordinator(
            configuration: .init(stamp: stampA, boardSlug: "alpha", initialCursor: 10, baseURL: "https://a.test"),
            socketFactory: { _ in MockSocket() },
            ticketMinter: { "t" },
            sleeper: gates.sleeper,
            onBatch: { invalidation in
                batches.append(invalidation)
                _ = await store.refreshFromEvent(expectedContext: invalidation.context, includeArchived: false)
                return .completed
            }
        )
        coordinator.start()
        // Frame 1 opens THE window (held by the gate); frames 2-3 merge.
        coordinator.injectForTesting(text: frameJSON(events: [eventJSON(id: 11, taskID: "A")], cursor: 11))
        await gates.waitUntilHeld(1)
        coordinator.injectForTesting(text: frameJSON(events: [eventJSON(id: 12, taskID: "B")], cursor: 12))
        coordinator.injectForTesting(text: frameJSON(events: [eventJSON(id: 13, taskID: "A"), eventJSON(id: 14, taskID: "C")], cursor: 14))
        XCTAssertEqual(batches.count, 0, "nothing flushes while the window is open")
        await gates.releaseAll()
        await drain()
        coordinator.stop()

        XCTAssertEqual(batches.count, 1, "three frames inside one window = ONE refresh")
        XCTAssertEqual(batches.first?.taskIDs, Set(["A", "B", "C"]))
        XCTAssertTrue(batches.first?.boardInvalidated ?? false)
    }

    func testEventDuringInFlightRefreshRunsExactlyOneFollowUp() async throws {
        let requester = V3DMockRequester()
        let store = try makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        let gates = SleeperGate()
        let refreshGate = ContinuationGate()
        var batches: [KanbanEventInvalidation] = []
        let coordinator = KanbanEventStreamCoordinator(
            configuration: .init(stamp: stampA, boardSlug: "alpha", initialCursor: 10, baseURL: "https://a.test"),
            socketFactory: { _ in MockSocket() },
            ticketMinter: { "t" },
            sleeper: gates.sleeper,
            onBatch: { invalidation in
                batches.append(invalidation)
                do {
                    // REST refresh "in flight"
                    try await refreshGate.awaitRelease()
                } catch {
                    return .discard
                }
                _ = await store.refreshFromEvent(expectedContext: invalidation.context, includeArchived: false)
                return .completed
            }
        )
        coordinator.start()
        coordinator.injectForTesting(text: frameJSON(events: [eventJSON(id: 11, taskID: "A")], cursor: 11))
        await gates.waitUntilHeld(1)
        await gates.releaseAll()
        // Batch 1 handling parks on the refresh gate; an event arrives DURING it.
        await refreshGate.waitUntilAwaited(1)
        coordinator.injectForTesting(text: frameJSON(events: [eventJSON(id: 12, taskID: "B")], cursor: 12))
        await gates.waitUntilHeld(2)          // the follow-up flush window opened
        await refreshGate.releaseAll()         // batch 1 finishes
        await gates.releaseAll()               // follow-up window elapses
        await refreshGate.waitUntilAwaited(2)  // follow-up batch handling reached its gate
        await refreshGate.releaseAll()
        await drain()
        coordinator.stop()

        XCTAssertEqual(batches.count, 2, "first batch + exactly ONE follow-up; no invalidation lost")
        XCTAssertEqual(batches.first?.taskIDs, Set(["A"]))
        XCTAssertEqual(batches.last?.taskIDs, Set(["B"]))
    }

    // MARK: - Busy store boundary

    func testDeferredWhileMutatingThenConvergesWithOneRetry() async throws {
        let requester = V3DMockRequester()
        requester.suspend(method: "POST", basePath: "/api/plugins/kanban/tasks/bulk")
        requester.bulkUpdateResponse = ["results": [["id": "t-1", "ok": true]]]
        let store = try makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        // Park a mutation mid-flight: isMutating stays true.
        let mutation = Task {
            try await store.bulkUpdateTasks(
                ids: ["t-1"],
                patch: KanbanBulkTaskRequest(ids: ["t-1"], status: "ready"),
                expectedContext: stampA
            )
        }
        await requester.waitForSuspension()

        let disposition = await store.refreshFromEvent(expectedContext: stampA, includeArchived: false)
        XCTAssertEqual(disposition, .deferred, "event refresh defers while a mutation owns the store")

        requester.resumeSuspended()
        _ = try await mutation.value

        let converged = await store.refreshFromEvent(expectedContext: stampA, includeArchived: false)
        XCTAssertEqual(converged, .refreshed, "the pending invalidation converges through one refresh")
    }

    func testDeferredWhileLoadingIsNotLost() async throws {
        let requester = V3DMockRequester()
        let store = try makeStore(requester: requester)
        await store.reload()   // established board
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        // Park the NEXT board GET: isLoading true while the context stays valid.
        requester.suspend(method: "GET", basePath: "/api/plugins/kanban/board")
        let reload = Task { await store.reload() }
        await requester.waitForSuspension()

        let disposition = await store.refreshFromEvent(expectedContext: stampA, includeArchived: false)
        XCTAssertEqual(disposition, .deferred, "passive event refresh defers while a load is in flight")

        requester.resumeSuspended()
        await reload.value
    }

    // MARK: - Frame robustness

    func testEmptyEventsFrameCausesNoInvalidationButAdvancesCursor() async throws {
        var batches: [KanbanEventInvalidation] = []
        let gates = SleeperGate()
        let coordinator = KanbanEventStreamCoordinator(
            configuration: .init(stamp: stamp(), boardSlug: "alpha", initialCursor: 100, baseURL: "https://a.test"),
            socketFactory: { _ in MockSocket() },
            ticketMinter: { "t" },
            sleeper: gates.sleeper,
            onBatch: { invalidation in
                batches.append(invalidation)
                return .completed
            }
        )
        coordinator.start()
        coordinator.injectForTesting(text: frameJSON(events: [], cursor: 104))
        await gates.waitUntilHeld(0)
        await drain()
        coordinator.stop()
        XCTAssertEqual(coordinator.cursor, 104, "cursor still advances")
        XCTAssertTrue(batches.isEmpty, "empty frames never invalidate")
    }

    func testMalformedFrameIsIgnoredAndLoopContinues() async throws {
        var batches: [KanbanEventInvalidation] = []
        let gates = SleeperGate()
        let coordinator = KanbanEventStreamCoordinator(
            configuration: .init(stamp: stamp(), boardSlug: "alpha", initialCursor: 10, baseURL: "https://a.test"),
            socketFactory: { _ in MockSocket() },
            ticketMinter: { "t" },
            sleeper: gates.sleeper,
            onBatch: { invalidation in
                batches.append(invalidation)
                return .completed
            }
        )
        coordinator.start()
        coordinator.injectForTesting(text: "{not json at all")
        coordinator.injectForTesting(text: frameJSON(events: [eventJSON(id: 11, taskID: "A")], cursor: 11))
        await gates.waitUntilHeld(1)
        await gates.releaseAll()
        await drain()
        coordinator.stop()
        XCTAssertEqual(batches.count, 1, "the malformed frame was skipped; the loop continued")
        XCTAssertEqual(batches.first?.taskIDs, Set(["A"]))
    }

    func testUnknownKindMissingTaskIDAndUnknownFieldsAreTolerated() async throws {
        // Phase 1: unknown kind + missing task_id + unknown fields -> the
        // BOARD still invalidates; no detail surface is touched.
        var boardOnlyBatches: [KanbanEventInvalidation] = []
        let gates1 = SleeperGate()
        let coordinator1 = KanbanEventStreamCoordinator(
            configuration: .init(stamp: stamp(), boardSlug: "alpha", initialCursor: 10, baseURL: "https://a.test"),
            socketFactory: { _ in MockSocket() },
            ticketMinter: { "t" },
            sleeper: gates1.sleeper,
            onBatch: { invalidation in
                boardOnlyBatches.append(invalidation)
                return .completed
            }
        )
        coordinator1.start()
        coordinator1.injectForTesting(text: #"{"events":[{"id":11,"kind":"brand_new_kind","future_field":{"x":1}}],"cursor":11}"#)
        await gates1.waitUntilHeld(1)
        await gates1.releaseAll()
        await drain()
        coordinator1.stop()
        XCTAssertEqual(boardOnlyBatches.count, 1, "unknown kinds still invalidate the BOARD")
        XCTAssertTrue(boardOnlyBatches.first?.boardInvalidated ?? false)
        XCTAssertTrue(boardOnlyBatches.first!.taskIDs.isEmpty, "missing task_id never touches a detail surface")

        // Phase 2: a well-formed event with a task ID touches that detail.
        var touchedBatches: [KanbanEventInvalidation] = []
        let gates2 = SleeperGate()
        let coordinator2 = KanbanEventStreamCoordinator(
            configuration: .init(stamp: stamp(), boardSlug: "alpha", initialCursor: 12, baseURL: "https://a.test"),
            socketFactory: { _ in MockSocket() },
            ticketMinter: { "t" },
            sleeper: gates2.sleeper,
            onBatch: { invalidation in
                touchedBatches.append(invalidation)
                return .completed
            }
        )
        coordinator2.start()
        coordinator2.injectForTesting(text: #"{"events":[{"id":13,"task_id":"A","kind":"completed"}],"cursor":13}"#)
        await gates2.waitUntilHeld(1)
        await gates2.releaseAll()
        await drain()
        coordinator2.stop()
        XCTAssertEqual(touchedBatches.count, 1)
        XCTAssertEqual(touchedBatches.first?.taskIDs, Set(["A"]))
    }

    // MARK: - Detail invalidation + dirty drafts

    func testDetailInvalidationPolicyTruthTable() {
        let current = stamp("alpha", generation: 9)
        let owned = KanbanEventInvalidation(revision: 1, context: current, taskIDs: ["A"], boardInvalidated: true)
        XCTAssertTrue(KanbanLiveUpdateSupport.shouldRefreshDetail(invalidation: owned, currentStamp: current, isSnapshotActionable: true, displayedTaskID: "A"))
        XCTAssertFalse(KanbanLiveUpdateSupport.shouldRefreshDetail(invalidation: owned, currentStamp: current, isSnapshotActionable: true, displayedTaskID: "B"), "unrelated IDs never wake the drawer")
        XCTAssertFalse(KanbanLiveUpdateSupport.shouldRefreshDetail(invalidation: owned, currentStamp: stamp("beta", generation: 9), isSnapshotActionable: true, displayedTaskID: "A"))
        XCTAssertFalse(KanbanLiveUpdateSupport.shouldRefreshDetail(invalidation: owned, currentStamp: current, isSnapshotActionable: false, displayedTaskID: "A"))
        XCTAssertFalse(KanbanLiveUpdateSupport.shouldRefreshDetail(invalidation: nil, currentStamp: nil, isSnapshotActionable: true, displayedTaskID: "A"))
    }

    func testDirtyDraftSurvivesAnEventTriggeredRemoteChange() {
        // Touched-task events route through the SAME loadDetail reconciliation
        // as ordinary polling; dirty-draft protection lives in
        // KanbanDetailDraftPolicy and is pinned here.
        let dirty = KanbanDetailDraftPolicy.isDirty(
            draftTitle: "my unsaved edit",
            draftBody: "",
            draftStatus: "todo",
            baselineTitle: "old",
            baselineBodyText: "",
            baselineStatus: "todo"
        )
        XCTAssertTrue(dirty, "local draft differs from baseline -> protected from remote overwrite")
        XCTAssertTrue(
            KanbanDetailDraftPolicy.serverMovedIndependently(
                serverTitle: "remote change",
                serverBodyText: "",
                serverStatus: "todo",
                baselineTitle: "old",
                baselineBodyText: "",
                baselineStatus: "todo"
            ),
            "the remote change is detected so collections/status metadata can refresh"
        )
        let clean = KanbanDetailDraftPolicy.isDirty(
            draftTitle: "remote change",
            draftBody: "",
            draftStatus: "todo",
            baselineTitle: "remote change",
            baselineBodyText: "",
            baselineStatus: "todo"
        )
        XCTAssertFalse(clean, "clean drafts adopt remote state freely")
    }

    // MARK: - Polling fallback

    func testPollingConstantsRemainUnchanged() {
        XCTAssertEqual(KanbanPollingPolicy.boardIntervalNanoseconds, 8_000_000_000)
        XCTAssertEqual(KanbanPollingPolicy.detailIntervalNanoseconds, 4_000_000_000)
    }

    func testTicketMintFailureKeepsRESTUsableAndRetriesQuietly() async throws {
        let requester = V3DMockRequester()
        let store = try makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }
        let boardsBefore = requester.boardsFetches

        // The minter fails a BOUNDED number of times, then parks on a long
        // cancellation-safe sleep - the reconnect loop must never become a
        // non-suspending spin (CI regression: an always-failing minter with
        // instant sleepers starved the MainActor).
        var failures = 0
        let coordinator = KanbanEventStreamCoordinator(
            configuration: .init(stamp: stampA, boardSlug: "alpha", initialCursor: 42, baseURL: "https://a.test"),
            socketFactory: { _ in MockSocket() },
            ticketMinter: {
                if failures >= 30 {
                    // Park until stop()-cancellation ends the loop.
                    try await Task.sleep(nanoseconds: 600_000_000_000)
                    throw CancellationError()
                }
                failures += 1
                throw URLError(.notConnectedToInternet)
            },
            sleeper: { _ in },   // bounded backoff drains instantly
            onBatch: { _ in .completed }
        )
        coordinator.start()
        await drain()   // 30 failures + backoff steps happen across these yields
        coordinator.stop()
        await drain()

        XCTAssertGreaterThanOrEqual(failures, 30, "the minter kept being retried quietly up to the bound")
        XCTAssertNil(store.errorMessage, "socket failures never become Kanban errors")
        XCTAssertNil(store.mutationErrorMessage)
        XCTAssertEqual(requester.boardsFetches - boardsBefore, 0, "the socket layer performs no board fetches itself")
        XCTAssertEqual(store.loadedBoardSlug, "alpha", "the REST board remains usable")
    }

    // MARK: - Cancellation finality

    func testStopCancelsSocketAndSilencesLateCompletions() async throws {
        let requester = V3DMockRequester()
        let store = try makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        let socket = MockSocket()
        let recorder = StreamRecorder(minterTickets: ["ticket-1"])
        let coordinator = recorder.makeCoordinator(
            stamp: stampA, boardSlug: "alpha", initialCursor: 42, baseURL: "https://a.test",
            sockets: [socket]
        )
        coordinator.start()
        await recorder.waitUntilURLCount(1)
        let urlsBefore = recorder.issuedURLs.count
        let mintsBefore = recorder.mintedTickets.count

        coordinator.stop()
        XCTAssertTrue(socket.cancelled, "the URLSessionWebSocketTask is cancelled (.goingAway behind the protocol)")

        // A late receive completion after cancellation is ignored: no new
        // tickets, no new URLs, no batches.
        socket.emitLate(text: frameJSON(events: [eventJSON(id: 50, taskID: "A")], cursor: 50))
        await drain()

        XCTAssertEqual(recorder.issuedURLs.count, urlsBefore, "no reconnect after stop()")
        XCTAssertEqual(recorder.mintedTickets.count, mintsBefore, "no new ticket minted after stop()")
    }
}

// MARK: - Test doubles

@MainActor
private final class MockSocket: KanbanEventSocket {
    enum Script {
        case text(String)
        case fail(Error)
    }

    private(set) var cancelled = false
    private var scripts: [Script]
    private var scriptIndex = 0
    private var parked: [CheckedContinuation<KanbanEventSocketMessage, Error>] = []

    init(scripts: [Script] = []) {
        self.scripts = scripts
    }

    /// Deliver a message AFTER cancellation (late receive completion).
    func emitLate(text: String) {
        let parkedNow = parked
        parked.removeAll()
        parkedNow.forEach { $0.resume(returning: .text(text)) }
    }

    func receive() async throws -> KanbanEventSocketMessage {
        if cancelled { throw CancellationError() }
        if scriptIndex < scripts.count {
            let entry = scripts[scriptIndex]
            scriptIndex += 1
            switch entry {
            case .text(let string): return .text(string)
            case .fail(let error): throw error
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            parked.append(continuation)
        }
    }

    func ping() async {}

    func cancel() {
        cancelled = true
        let parkedNow = parked
        parked.removeAll()
        parkedNow.forEach { $0.resume(throwing: CancellationError()) }
    }
}

/// Gated sleeper: records delay requests and PARKS each until released -
/// deterministic coalescing/backoff ordering without wall-clock waits.
@MainActor
private final class SleeperGate {
    private(set) var heldCount = 0
    private var parked: [CheckedContinuation<Void, Error>] = []

    var sleeper: KanbanEventStreamCoordinator.Sleeper {
        { [weak self] _ in
            guard let self else { return }
            self.heldCount += 1
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.parked.append(continuation)
            }
        }
    }

    func waitUntilHeld(_ count: Int) async {
        while heldCount < count {
            await Task.yield()
        }
    }

    func releaseAll() async {
        let now = parked
        parked.removeAll()
        now.forEach { $0.resume() }
        await drainActor()
    }

    private func drainActor() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

/// Generic continuation gate for simulating in-flight work.
@MainActor
private final class ContinuationGate {
    private(set) var awaitedCount = 0
    private var parked: [CheckedContinuation<Void, Error>] = []

    func awaitRelease() async throws {
        awaitedCount += 1
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            parked.append(continuation)
        }
    }

    func waitUntilAwaited(_ count: Int) async {
        while awaitedCount < count {
            await Task.yield()
        }
    }

    func releaseAll() async {
        let now = parked
        parked.removeAll()
        now.forEach { $0.resume() }
        await drainActor()
    }

    private func drainActor() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

/// Minimal HTTP mock for store-level V3D tests: boards/board GETs with
/// counting, bulk POST response, and continuation-handshake suspension.
@MainActor
private final class V3DMockRequester: DashboardJSONRequester {
    struct Call {
        let path: String
        let method: String
    }

    static let baseBoards: [[String: Any]] = [
        ["slug": "alpha", "name": "Alpha", "archived": false],
        ["slug": "beta", "name": "Beta", "archived": false],
        ["slug": "default", "name": "Default", "archived": false],
    ]

    var boardPayload: [String: Any] = [:]
    var bulkUpdateResponse: [String: Any] = ["results": []]
    private(set) var calls: [Call] = []
    private(set) var boardsFetches = 0
    private(set) var boardFetches = 0

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
        calls.append(Call(path: path, method: method))
        let basePath = path.components(separatedBy: "?").first ?? path

        if suspendEntries.contains(where: { $0.method == method && $0.basePath == basePath }) {
            suspendEntries.removeAll { $0.method == method && $0.basePath == basePath }
            suspensionWaiters.forEach { $0.resume() }
            suspensionWaiters.removeAll()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                suspended.append(continuation)
            }
        }

        if method == "GET", basePath == "/api/plugins/kanban/boards" {
            boardsFetches += 1
            return ["boards": Self.baseBoards, "current": "alpha"]
        }
        if method == "GET", basePath == "/api/plugins/kanban/board" {
            boardFetches += 1
            var board: [String: Any] = [
                "columns": [
                    ["name": "triage", "tasks": []],
                    ["name": "todo", "tasks": []],
                    ["name": "running", "tasks": []],
                ],
                "tenants": [],
                "assignees": ["coder"],
                "latest_event_id": 42,
                "now": 2,
            ]
            for (key, value) in boardPayload { board[key] = value }
            return board
        }
        if method == "POST", basePath == "/api/plugins/kanban/tasks/bulk" {
            return bulkUpdateResponse
        }
        if method == "GET", basePath == "/api/plugins/kanban/orchestration" {
            return ["orchestrator_profile": "", "default_assignee": "", "auto_decompose": true, "auto_promote_children": true,
                    "resolved_orchestrator_profile": "default", "resolved_default_assignee": "coder", "active_profile": "default"]
        }
        if method == "GET", basePath == "/api/plugins/kanban/profiles" {
            return ["profiles": [["name": "coder"]]]
        }
        if method == "GET", basePath == "/api/plugins/kanban/projects" {
            return ["projects": []]
        }
        return [:]
    }
}

/// Records issued URLs/tickets; optional scripted sockets per connection
/// (first, second, ...); extra connections park forever.
@MainActor
private final class StreamRecorder {
    let minterTickets: [String]
    private let scriptedSockets: [[MockSocket.Script]]
    private(set) var issuedURLs: [URL] = []
    private(set) var mintedTickets: [String] = []

    init(minterTickets: [String], scriptedSockets: [[MockSocket.Script]] = []) {
        self.minterTickets = minterTickets
        self.scriptedSockets = scriptedSockets
    }

    func makeCoordinator(
        stamp: KanbanBoardContextStamp,
        boardSlug: String,
        initialCursor: Int,
        baseURL: String,
        sockets: [MockSocket] = []
    ) -> KanbanEventStreamCoordinator {
        let rec = self
        var connectionIndex = 0
        return KanbanEventStreamCoordinator(
            configuration: .init(stamp: stamp, boardSlug: boardSlug, initialCursor: initialCursor, baseURL: baseURL),
            socketFactory: { url in
                rec.issuedURLs.append(url)
                defer { connectionIndex += 1 }
                if connectionIndex < sockets.count {
                    return sockets[connectionIndex]
                }
                if connectionIndex < rec.scriptedSockets.count {
                    return MockSocket(scripts: rec.scriptedSockets[connectionIndex])
                }
                return MockSocket()   // parks forever
            },
            ticketMinter: {
                defer { rec.mintIndex += 1 }
                let index = min(rec.mintIndex, rec.minterTickets.count - 1)
                let ticket = rec.minterTickets[index]
                rec.mintedTickets.append(ticket)
                return ticket
            },
            sleeper: { _ in },   // backoff/retry delays drain instantly unless overridden
            onBatch: { _ in .discard }
        )
    }

    private var mintIndex = 0

    func waitUntilURLCount(_ count: Int) async {
        while issuedURLs.count < count {
            await Task.yield()
        }
    }
}