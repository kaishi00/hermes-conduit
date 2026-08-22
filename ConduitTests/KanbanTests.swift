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
        // Establish a loaded board snapshot before any mutation.
        await store.refresh()
        XCTAssertEqual(store.loadedBoardSlug, "default")

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
        await store.refresh()

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

        await store.awaitPendingDispatcherNudgeForTesting()
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
        await store.awaitPendingDispatcherNudgeForTesting()

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
        await store.awaitPendingDispatcherNudgeForTesting()

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
        let json = "{\"id\":\"t\",\"title\":\"x\",\"status\":\"todo\",\"priority\":1e300,\"created_at\":2.5,\"completed_at\":3.0,\"comment_count\":-3,\"started_at\":\"7\",\"worker_pid\":\"not-a-number\"}"
        let task = try JSONDecoder().decode(KanbanTask.self, from: Data(json.utf8))
        XCTAssertNil(task.priority, "unrepresentable huge double must decode as nil, not crash")
        XCTAssertNil(task.createdAt, "fractional doubles must not truncate to an integer")
        XCTAssertEqual(task.completedAt, 3, "integral doubles decode exactly")
        XCTAssertEqual(task.commentCount, -3)
        XCTAssertEqual(task.startedAt, 7)
        XCTAssertNil(task.workerPid)
    }

    // MARK: - Board selection supersedes background polls

    func testBoardSelectionSupersedesInFlightPollAndBindsMutationToLoadedSnapshot() async throws {
        var responses = standardKanbanResponses(boardSlug: "alpha")
        responses["/api/plugins/kanban/board?board=alpha"] = [
            "columns": [["name": "todo", "tasks": [["id": "t-a", "title": "from alpha", "status": "todo"]]]],
            "tenants": [], "assignees": []
        ]
        responses["/api/plugins/kanban/board?board=beta"] = [
            "columns": [["name": "todo", "tasks": [["id": "t-b", "title": "from beta", "status": "todo"]]]],
            "tenants": [], "assignees": []
        ]
        responses["/api/plugins/kanban/tasks/t-a"] = ["task": ["id": "t-a", "title": "edited on alpha", "status": "todo"]]
        let requester = MockKanbanRequester(responsesByPath: responses)
        let store = makeStore(requester: requester)
        await store.selectBoard(slug: "alpha")
        XCTAssertEqual(store.loadedBoardSlug, "alpha")
        XCTAssertEqual(store.board?.columns.first?.tasks.first?.title, "from alpha")

        // Park an ordinary background refresh of board A.
        requester.hold(pathPrefix: "/api/plugins/kanban/boards")
        let poll = Task { await store.poll() }
        await Task.yield(); await Task.yield(); await Task.yield()

        // The user selects B while the A poll is still parked.
        let selection = Task { await store.selectBoard(slug: "beta") }
        await Task.yield(); await Task.yield(); await Task.yield()
        XCTAssertEqual(store.selectedBoardSlug, "beta")
        XCTAssertEqual(store.loadedBoardSlug, "alpha", "displayed snapshot must stay bound to A until B loads")
        XCTAssertEqual(store.board?.columns.first?.tasks.first?.id, "t-a")

        // While B is pending, the stale A snapshot must NOT be actionable:
        // the store rejects the mutation outright (no PATCH can target A or
        // B), matching the view's disabled cards and New Task button.
        let blocked = try? await store.updateTask(id: "t-a", patch: KanbanTaskPatch(title: "edited on alpha"))
        XCTAssertNil(blocked)
        XCTAssertEqual(store.mutationErrorMessage, KanbanServiceError.boardNavigationInProgress.localizedDescription)
        XCTAssertFalse(requester.calls.contains { $0.method == "PATCH" }, "no write may leave during navigation")

        do {
            _ = try await store.createTask(KanbanCreateTaskRequest(title: "No A create"), initialStatus: "todo")
            XCTFail("creation must be rejected while navigating")
        } catch let error as KanbanServiceError {
            XCTAssertEqual(error, .boardNavigationInProgress)
        }
        XCTAssertFalse(requester.calls.contains { $0.method == "POST" && $0.path.contains("/tasks") })

        // The transient navigation hint is dismissed (user-tappable banner);
        // later phases assert fresh error state only.
        store.clearMutationError()

        requester.releaseAll()
        await poll.value
        await selection.value
        await store.awaitPendingDispatcherNudgeForTesting()

        XCTAssertEqual(store.selectedBoardSlug, "beta")
        XCTAssertEqual(store.loadedBoardSlug, "beta")
        XCTAssertEqual(store.board?.columns.first?.tasks.first?.title, "from beta", "stale A completion must be discarded")
        XCTAssertNil(store.mutationErrorMessage)

        // Actions become available again once B is the loaded snapshot.
        XCTAssertTrue(store.isSelectedSnapshotLoaded)
        requester.errorsByPath["/api/plugins/kanban/tasks/t-b"] = MockRequestError.failed("beta write failed")
        do {
            _ = try await store.updateTask(id: "t-b", patch: KanbanTaskPatch(title: "x"))
            XCTFail("expected current-generation failure to surface")
        } catch {
            XCTAssertTrue(store.mutationErrorMessage?.contains("beta write failed") == true)
        }
    }

    // MARK: - Mutation reconciliation vs passive poll ordering

    func testMutationReconciliationSupersedesInFlightPassivePoll() async throws {
        var responses = standardKanbanResponses(boardSlug: "alpha")
        responses["/api/plugins/kanban/board?board=alpha"] = [
            "columns": [["name": "todo", "tasks": [["id": "t-old", "title": "stale card", "status": "todo"]]]],
            "tenants": [], "assignees": []
        ]
        let requester = MockKanbanRequester(responsesByPath: responses)
        let store = makeStore(requester: requester, nudgeDebounceNanoseconds: 30_000_000)
        await store.refresh()
        XCTAssertEqual(store.board?.columns.first?.tasks.first?.id, "t-old")
        let boardFetchesBefore = requester.calls.filter { $0.path.contains("/board?") }.count

        // Park an ordinary 8-second-style passive poll at its first request.
        requester.hold(pathPrefix: "/api/plugins/kanban/boards")
        let poll = Task { await store.poll() }
        // Deterministic wait: the poll must actually be parked before proceeding.
        for _ in 0..<5000 where requester.heldCount == 0 { await Task.yield() }
        XCTAssertGreaterThan(requester.heldCount, 0, "passive poll should be parked")

        // Delete succeeds while the poll is still parked. The mutation's own
        // reconciliation must supersede the parked poll instead of being
        // dropped behind isLoading.
        let mutation = Task { try? await store.deleteTask(id: "t-old") }
        // Wait until the mutation's superseding reconciliation is parked
        // behind the poll (two held requests), so releaseNext is never early.
        for _ in 0..<5000 where requester.heldCount < 2 { await Task.yield() }
        XCTAssertGreaterThanOrEqual(requester.heldCount, 2, "reconciliation should be queued behind the poll")

        // Fresh authoritative state after the delete: the board no longer has
        // the deleted task. (Mutate the MOCK - the local dict was copied at init.)
        requester.responsesByPath["/api/plugins/kanban/board?board=alpha"] = [
            "columns": [], "tenants": [], "assignees": [], "latest_event_id": 2, "now": 3
        ]
        // Wake the parked POLL and lift the hold (same-prefix drains too, so
        // the superseding reconciliation passes through freely afterwards).
        requester.releaseNext()
        // The unheld prefix lets the reconciliation's /boards pass freely;
        // wait until its board fetch lands before asserting.
        for _ in 0..<5000
        where requester.calls.filter({ $0.path.contains("/board?") }).count <= boardFetchesBefore {
            await Task.yield()
        }
        _ = await mutation.value
        await store.awaitPendingDispatcherNudgeForTesting()

        // The reconciliation actually issued a NEW board fetch (it was not
        // dropped because isLoading was true).
        let boardFetchesAfter = requester.calls.filter { $0.path.contains("/board?") }.count
        XCTAssertGreaterThan(boardFetchesAfter, boardFetchesBefore, "post-mutation reconciliation must not be skipped")
        XCTAssertNil(store.mutationErrorMessage)
        XCTAssertNil(store.board?.columns.first?.tasks.first, "deleted card must be gone from the reconciled snapshot")

        // The released old poll finishes as a stale generation and cannot
        // resurrect the pre-mutation snapshot.
        await poll.value
        XCTAssertNil(store.board?.columns.first?.tasks.first, "old poll must not overwrite post-mutation state")
        XCTAssertEqual(store.loadedBoardSlug, "alpha")
    }

    // MARK: - Cross-server stale mutation isolation

    func testReconfiguredServerIsolatesStaleMutationFailure() async throws {
        var responsesA = standardKanbanResponses(boardSlug: "a-board")
        let requesterA = MockKanbanRequester(responsesByPath: responsesA)
        let store = makeStore(requester: requesterA)
        await store.refresh()

        requesterA.hold(pathPrefix: "/api/plugins/kanban/tasks/t1")
        let mutation = Task { try? await store.updateTask(id: "t1", patch: KanbanTaskPatch(title: "held")) }
        await Task.yield(); await Task.yield(); await Task.yield()

        var responsesB = standardKanbanResponses(boardSlug: "b-board")
        responsesB["/api/plugins/kanban/board"] = [
            "columns": [["name": "todo", "tasks": [["id": "2", "title": "from B", "status": "todo"]]]],
            "tenants": [], "assignees": []
        ]
        let requesterB = MockKanbanRequester(responsesByPath: responsesB)
        store.configure(requester: requesterB, serverIdentity: "https://b.test")
        await store.reload()
        XCTAssertEqual(store.board?.columns.first?.tasks.first?.title, "from B")

        // configure() revokes the old operation's UI ownership immediately.
        XCTAssertFalse(store.isMutating)
        XCTAssertNil(store.mutationErrorMessage)
        let bCallsBeforeRelease = requesterB.calls.count

        requesterA.errorsByPath["/api/plugins/kanban/tasks/t1"] = MockRequestError.failed("server A exploded")
        requesterA.releaseAll()
        _ = await mutation.value

        XCTAssertFalse(store.isMutating)
        XCTAssertNil(store.mutationErrorMessage, "server A's failure must not surface on server B")
        XCTAssertEqual(requesterB.calls.count, bCallsBeforeRelease, "stale completion must not trigger a B refresh")
        XCTAssertEqual(store.board?.columns.first?.tasks.first?.title, "from B")
    }

    func testReconfiguredServerIsolatesStaleMutationSuccess() async throws {
        var responsesA = standardKanbanResponses(boardSlug: "a-board")
        responsesA["/api/plugins/kanban/tasks/t1"] = ["task": ["id": "t1", "title": "saved on A", "status": "todo"]]
        let requesterA = MockKanbanRequester(responsesByPath: responsesA)
        let store = makeStore(requester: requesterA)
        await store.refresh()

        requesterA.hold(pathPrefix: "/api/plugins/kanban/tasks/t1")
        let mutation = Task { try? await store.updateTask(id: "t1", patch: KanbanTaskPatch(title: "saved on A")) }
        await Task.yield(); await Task.yield(); await Task.yield()

        var responsesB = standardKanbanResponses(boardSlug: "b-board")
        responsesB["/api/plugins/kanban/board"] = [
            "columns": [["name": "todo", "tasks": [["id": "2", "title": "from B", "status": "todo"]]]],
            "tenants": [], "assignees": []
        ]
        let requesterB = MockKanbanRequester(responsesByPath: responsesB)
        store.configure(requester: requesterB, serverIdentity: "https://b.test")
        await store.reload()
        XCTAssertEqual(store.board?.columns.first?.tasks.first?.title, "from B")
        let bCallsBeforeRelease = requesterB.calls.count

        requesterA.releaseAll()
        _ = await mutation.value
        await store.awaitPendingDispatcherNudgeForTesting()

        XCTAssertNil(store.mutationErrorMessage)
        XCTAssertFalse(store.isMutating)
        XCTAssertEqual(requesterB.calls.count, bCallsBeforeRelease, "old success must not refresh the new server")
        XCTAssertEqual(store.board?.columns.first?.tasks.first?.title, "from B")
    }

    // MARK: - Malformed rows

    func testIdLessTaskRowsAreDroppedFromBoardColumns() throws {
        let json = "{\"name\":\"todo\",\"tasks\":[" +
            "{\"id\":\"valid-1\",\"title\":\"one\",\"status\":\"todo\"}," +
            "{\"title\":\"missing a\",\"status\":\"todo\"}," +
            "{\"status\":\"todo\"}," +
            "{\"id\":\"valid-2\",\"title\":\"two\",\"status\":\"todo\"}]}"
        let column = try JSONDecoder().decode(KanbanColumn.self, from: Data(json.utf8))
        XCTAssertEqual(column.tasks.map(\.id), ["valid-1", "valid-2"])
        XCTAssertEqual(Set(column.tasks.map(\.id)).count, column.tasks.count, "no duplicate SwiftUI identities possible")
    }

    // MARK: - Capabilities request-scoped outcome contract

    func testCapabilityOutcomeMappingIsRequestScoped() {
        typealias Outcome = AppState.CapabilityLoadOutcome

        // Successful load with data clears any local failure.
        XCTAssertNil(CapabilitiesView.localError(for: .success(profile: "p"), hasData: true))
        // Successful EMPTY result is distinct from failure and independent of
        // any stale global error message.
        XCTAssertEqual(
            CapabilitiesView.localError(for: .success(profile: "p"), hasData: false),
            "No capabilities found."
        )
        // Failure surfaces verbatim whether or not cached data exists; the
        // same failure repeated is surfaced again identically.
        for _ in 0..<2 {
            XCTAssertEqual(CapabilitiesView.localError(for: .failed(profile: "p", message: "boom"), hasData: true), "boom")
            XCTAssertEqual(CapabilitiesView.localError(for: .failed(profile: "p", message: "boom"), hasData: false), "boom")
        }
        XCTAssertEqual(
            CapabilitiesView.localError(for: .unavailable(profile: "p"), hasData: false),
            "Connect to a Hermes dashboard to load capabilities."
        )
        XCTAssertNil(CapabilitiesView.localError(for: .superseded(requestedProfile: "a", activeProfile: "b"), hasData: true))
    }

    // MARK: - Concrete slug resolution

    func testInvalidPersistedSelectionResolvesToConcreteCurrentBoard() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var responses = standardKanbanResponses(boardSlug: "beta")
        // The persisted selection points at a board that no longer exists.
        responses["/api/plugins/kanban/boards"] = [
            "boards": [["slug": "beta", "name": "Beta", "is_current": true]],
            "current": "beta"
        ]
        responses["/api/plugins/kanban/board?board=removed-board"] = [:]
        responses["/api/plugins/kanban/board?board=beta"] = [
            "columns": [["name": "todo", "tasks": [["id": "b1", "title": "from beta", "status": "todo"]]]],
            "tenants": [], "assignees": []
        ]
        let requester = MockKanbanRequester(responsesByPath: responses)
        defaults.set("removed-board", forKey: KanbanStore.scopedBoardKey(serverIdentity: "https://example.test"))
        let store = KanbanStore(defaults: defaults)
        store.configure(requester: requester, serverIdentity: "https://example.test")
        await store.reload()

        let boardCall = try XCTUnwrap(requester.calls.last(where: { $0.path.contains("/board?") }))
        XCTAssertTrue(boardCall.path.contains("board=beta"), boardCall.path)
        XCTAssertFalse(boardCall.path.contains("removed-board"))
        XCTAssertEqual(store.selectedBoardSlug, "")
        XCTAssertEqual(store.loadedBoardSlug, "beta", "loaded identity must equal the fetched slug")
        XCTAssertEqual(store.board?.columns.first?.tasks.first?.title, "from beta")
    }

    func testServerCurrentLoadPinsConcreteResolvedSlug() async throws {
        var responses = standardKanbanResponses(boardSlug: "alpha")
        responses.removeValue(forKey: "/api/plugins/kanban/board")
        responses["/api/plugins/kanban/board?board=alpha"] = [
            "columns": [["name": "todo", "tasks": [["id": "a1", "title": "pinned alpha", "status": "todo"]]]],
            "tenants": [], "assignees": []
        ]
        let requester = MockKanbanRequester(responsesByPath: responses)
        let store = makeStore(requester: requester)
        await store.refresh()

        let boardCall = try XCTUnwrap(requester.calls.last(where: { $0.path.contains("/api/plugins/kanban/board") && !$0.path.contains("/boards") }))
        XCTAssertTrue(boardCall.path.hasSuffix("/board?board=alpha"), "server-current must be pinned before GET /board: \(boardCall.path)")
        XCTAssertEqual(store.loadedBoardSlug, "alpha")
    }

    func testDotSegmentIdentifiersFailBeforeTransport() async throws {
        let requester = MockKanbanRequester(responsesByPath: standardKanbanResponses())
        let service = KanbanService(requester: requester)

        for bad in [".", ".."] {
            do {
                _ = try await service.updateTask(id: bad, board: nil, patch: KanbanTaskPatch(title: "x"))
                XCTFail("dot segment must be rejected: \(bad)")
            } catch let error as KanbanServiceError {
                XCTAssertEqual(error, .invalidQueryParameter(bad))
            }
        }
        XCTAssertTrue(requester.calls.isEmpty, "rejection happens before transport")

        _ = try await service.updateTask(id: "t_99", board: nil, patch: KanbanTaskPatch(title: "ok"))
        XCTAssertEqual(requester.calls.last?.path, "/api/plugins/kanban/tasks/t_99")
    }

    func testStaleDeleteFailureIsInvisibleAfterReconfigure() async throws {
        let requesterA = MockKanbanRequester(responsesByPath: standardKanbanResponses(boardSlug: "a-board"))
        let store = makeStore(requester: requesterA)
        await store.refresh()

        requesterA.hold(pathPrefix: "/api/plugins/kanban/tasks/t1")
        let mutation = Task { try? await store.deleteTask(id: "t1") }
        await Task.yield(); await Task.yield(); await Task.yield()

        let requesterB = MockKanbanRequester(responsesByPath: standardKanbanResponses(boardSlug: "b-board"))
        store.configure(requester: requesterB, serverIdentity: "https://b.test")
        await store.reload()
        XCTAssertFalse(store.isMutating)
        let bCallsBefore = requesterB.calls.count

        requesterA.errorsByPath["/api/plugins/kanban/tasks/t1"] = MockRequestError.failed("A delete failed")
        requesterA.releaseAll()
        _ = await mutation.value

        XCTAssertNil(store.mutationErrorMessage, "stale View/store channel must stay silent on B")
        XCTAssertFalse(store.isMutating)
        XCTAssertEqual(requesterB.calls.count, bCallsBefore)

        // Current-generation delete failures remain visible.
        requesterB.errorsByPath["/api/plugins/kanban/tasks/t9"] = MockRequestError.failed("B delete failed")
        do {
            try await store.deleteTask(id: "t9")
            XCTFail("expected current-generation failure")
        } catch {
            XCTAssertTrue(store.mutationErrorMessage?.contains("B delete failed") == true)
        }
    }

    // MARK: - Capability ownership policy (rapid profile switching)

    func testCapabilityCommitPolicyRejectsABAAndForeignProfiles() {
        // A -> B -> A: old A1 finishes after A2 started; latestGeneration moved on.
        XCTAssertFalse(CapabilityLoadPolicy.canCommit(
            generation: 1, latestGeneration: 3, requestedProfile: "A", activeProfile: "A"
        ))
        // Newer request for the same still-active profile commits.
        XCTAssertTrue(CapabilityLoadPolicy.canCommit(
            generation: 3, latestGeneration: 3, requestedProfile: "A", activeProfile: "A"
        ))
        // Profile changed mid-flight.
        XCTAssertFalse(CapabilityLoadPolicy.canCommit(
            generation: 2, latestGeneration: 2, requestedProfile: "A", activeProfile: "B"
        ))
    }

    func testCapabilityRowsNeverRenderForForeignSnapshotProfile() {
        XCTAssertFalse(CapabilityLoadPolicy.shouldPresentRows(snapshotProfile: "A", activeProfile: "B"))
        XCTAssertFalse(CapabilityLoadPolicy.shouldPresentRows(snapshotProfile: nil, activeProfile: "B"))
        XCTAssertTrue(CapabilityLoadPolicy.shouldPresentRows(snapshotProfile: "B", activeProfile: "B"))
    }

    // MARK: - Capabilities rendering boundary policy

    func testForeignSnapshotCanNeverResolveToARowState() {
        // A rows under active B while B's request is still in flight (SwiftUI
        // render race): the transition state must stay loading, never rows.
        XCTAssertEqual(
            CapabilityLoadPolicy.resolvePresentation(snapshotProfile: "A", activeProfile: "B", isLoading: true, loadError: nil, hasRows: true),
            .loading
        )
        // Foreign snapshot with nothing settled for B yet: still loading.
        XCTAssertEqual(
            CapabilityLoadPolicy.resolvePresentation(snapshotProfile: "A", activeProfile: "B", isLoading: false, loadError: nil, hasRows: true),
            .loading
        )
    }

    func testFailedFirstLoadWithoutSnapshotShowsFailure() {
        // First load fails before any snapshot exists (e.g. offline).
        XCTAssertEqual(
            CapabilityLoadPolicy.resolvePresentation(snapshotProfile: nil, activeProfile: "B", isLoading: false, loadError: "offline", hasRows: false),
            .failure("offline")
        )
    }

    func testNoDashboardUnavailableFirstLoadShowsConnectionFailure() {
        XCTAssertEqual(
            CapabilityLoadPolicy.resolvePresentation(
                snapshotProfile: nil,
                activeProfile: "B",
                isLoading: false,
                loadError: "Connect to a Hermes dashboard to load capabilities.",
                hasRows: false
            ),
            .failure("Connect to a Hermes dashboard to load capabilities.")
        )
    }

    func testCurrentSnapshotEmptySuccessShowsExplicitEmptyState() {
        XCTAssertEqual(
            CapabilityLoadPolicy.resolvePresentation(snapshotProfile: "B", activeProfile: "B", isLoading: false, loadError: nil, hasRows: false),
            .emptySuccess
        )
    }

    func testCurrentSnapshotEmptyFailureShowsFullFailureState() {
        XCTAssertEqual(
            CapabilityLoadPolicy.resolvePresentation(snapshotProfile: "B", activeProfile: "B", isLoading: false, loadError: "boom", hasRows: false),
            .failure("boom")
        )
    }

    func testPopulatedSameProfileRefreshFailureKeepsRowsWithBanner() {
        XCTAssertEqual(
            CapabilityLoadPolicy.resolvePresentation(snapshotProfile: "B", activeProfile: "B", isLoading: false, loadError: "refresh boom", hasRows: true),
            .list(banner: "refresh boom")
        )
        // Clean populated load renders the plain list.
        XCTAssertEqual(
            CapabilityLoadPolicy.resolvePresentation(snapshotProfile: "B", activeProfile: "B", isLoading: false, loadError: nil, hasRows: true),
            .list(banner: nil)
        )
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
    private struct HeldRequest {
        let prefix: String
        let continuation: CheckedContinuation<Void, Never>
    }
    private var heldRequests: [HeldRequest] = []
    /// Number of requests currently parked by an active hold.
    var heldCount: Int { heldRequests.count }
    var calls: [Call] = []

    init(responsesByPath: [String: [String: Any]] = [:], errorsByPath: [String: Error] = [:]) {
        self.responsesByPath = responsesByPath
        self.errorsByPath = errorsByPath
    }

    /// Park every request whose path starts with the prefix until releaseAll().
    func hold(pathPrefix: String) { holdsActive.insert(pathPrefix) }

    /// Wake exactly the oldest parked request and stop holding its prefix, so
    /// later matching requests (e.g. a superseding reconciliation) pass freely
    /// while the released one finishes as a stale generation.
    /// Wake exactly the oldest parked request and stop holding its prefix.
    /// Any OTHER requests already parked under the same prefix are woken too:
    /// they proceed as stale generations (their completions discard), while
    /// later matching requests pass through freely.
    func releaseNext() {
        guard let first = heldRequests.first else { return }
        heldRequests.removeFirst()
        holdsActive.remove(first.prefix)
        first.continuation.resume()
        let samePrefix = heldRequests.filter { $0.prefix == first.prefix }
        heldRequests.removeAll { $0.prefix == first.prefix }
        for held in samePrefix { held.continuation.resume() }
    }

    func releaseAll() {
        holdsActive.removeAll()
        for held in heldRequests { held.continuation.resume() }
        heldRequests.removeAll()
    }

    func requestJSON(path: String, method: String, body: [String: Any]?, timeoutMilliseconds: Int, maxResponseBytes: Int) async throws -> [String: Any] {
        calls.append(Call(path: path, method: method, body: body))
        let basePath = path.components(separatedBy: "?").first ?? path
        if !holdsActive.isEmpty, holdsActive.contains(where: { path.hasPrefix($0) || basePath.hasPrefix($0) }) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                heldRequests.append(HeldRequest(prefix: Self.matchingHoldPrefix(path: path, basePath: basePath, prefixes: holdsActive), continuation: continuation))
            }
        }
        if let error = errorsByPath[path] ?? errorsByPath[basePath] { throw error }
        if let response = responsesByPath[path] ?? responsesByPath[basePath] { return response }
        return [:]
    }

    private static func matchingHoldPrefix(path: String, basePath: String, prefixes: Set<String>) -> String {
        prefixes.first { path.hasPrefix($0) || basePath.hasPrefix($0) } ?? ""
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
