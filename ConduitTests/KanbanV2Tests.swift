import XCTest
@testable import Conduit

/// Kanban V2 semantics: composer serialization, assignment/workspace/model
/// inheritance rules, lane policy, actions, diagnostics/dependencies decoding,
/// and worker-log context. V1's KanbanTests.swift remains untouched.
@MainActor
final class KanbanV2Tests: XCTestCase {

    // MARK: - Effective visible lane (V2 §9 regression)

    private func columns(_ names: [String]) -> [KanbanColumn] {
        names.map { KanbanColumn(name: $0) }
    }

    func testGlobalPlusUsesEffectiveVisibleLaneNotRawSelection() {
        // The user never tapped a chip (selected == nil), yet the UI resolved
        // Triage as the visible lane. The New Task initial status MUST follow
        // the effective lane, not fall back to Todo.
        let board = columns(["triage", "todo", "ready"])
        let lane = KanbanLanePolicy.effectiveSelectedLane(selected: nil, columns: board)
        XCTAssertEqual(lane, "triage")
        XCTAssertEqual(KanbanLanePolicy.newTaskInitialStatus(effectiveLane: lane), "triage")
    }

    func testExplicitSelectionWinsAndLockedSelectionCollapsesToTodo() {
        let board = columns(["triage", "todo", "running"])
        XCTAssertEqual(
            KanbanLanePolicy.effectiveSelectedLane(selected: "todo", columns: board),
            "todo"
        )
        // A locked lane is never a valid creation target.
        let locked = KanbanLanePolicy.effectiveSelectedLane(selected: "running", columns: board)
        XCTAssertEqual(locked, "running", "locked lanes stay VIEWABLE")
        XCTAssertEqual(
            KanbanLanePolicy.newTaskInitialStatus(effectiveLane: locked),
            "todo",
            "creation on a locked lane collapses to the default unlocked status"
        )
    }

    func testAllLockedBoardStillResolvesFirstLane() {
        let board = columns(["review", "scheduled"])
        XCTAssertEqual(KanbanLanePolicy.effectiveSelectedLane(selected: nil, columns: board), "review")
        XCTAssertNil(KanbanLanePolicy.effectiveSelectedLane(selected: nil, columns: []))
        XCTAssertEqual(KanbanLanePolicy.newTaskInitialStatus(effectiveLane: nil), "todo")
    }

    func testMissingSelectedLaneFallsBackToUnlockedDefault() {
        // selected references a column that left the snapshot (e.g. archived).
        let board = columns(["ready", "done"])
        XCTAssertEqual(
            KanbanLanePolicy.effectiveSelectedLane(selected: "vanished", columns: board),
            "ready"
        )
    }

    // MARK: - Assignment Default / Profile / Parked (V2 §2)

    func testAssigneeSelectionMatchesUpstreamWireSemantics() {
        // Default sends the RESOLVED orchestration default — never silently nil.
        XCTAssertEqual(
            KanbanAssigneeSelection.inheritDefault.requestValue(resolvedDefaultAssignee: "archimedes"),
            "archimedes"
        )
        XCTAssertEqual(
            KanbanAssigneeSelection.inheritDefault.requestValue(resolvedDefaultAssignee: "   "),
            "default",
            "empty resolution falls back to 'default' like the desktop dialog"
        )
        // Parked OMITS assignee entirely (backend nil = unassigned).
        XCTAssertNil(KanbanAssigneeSelection.parked.requestValue(resolvedDefaultAssignee: "archimedes"))
        // Explicit profile pins that profile.
        XCTAssertEqual(
            KanbanAssigneeSelection.profile("lancelot").requestValue(resolvedDefaultAssignee: "archimedes"),
            "lancelot"
        )
    }

    // MARK: - Workspace default + override serialization (V2 §3)

    func testBoardDefaultWorkspaceKindInitializesComposer() {
        XCTAssertEqual(KanbanWorkspaceKind.initialKind(boardDefault: nil), .scratch)
        XCTAssertEqual(KanbanWorkspaceKind.initialKind(boardDefault: ""), .scratch)
        XCTAssertEqual(KanbanWorkspaceKind.initialKind(boardDefault: "worktree"), .worktree)
        XCTAssertEqual(KanbanWorkspaceKind.initialKind(boardDefault: "dir"), .dir)
        XCTAssertEqual(KanbanWorkspaceKind.initialKind(boardDefault: "scratch"), .scratch)
        XCTAssertEqual(KanbanWorkspaceKind.initialKind(boardDefault: "  Worktree "), .worktree, "case/space tolerant")
        XCTAssertEqual(KanbanWorkspaceKind.initialKind(boardDefault: "banana"), .scratch, "unknown falls back to backend scratch default")
    }

    func testExplicitWorkspaceOverrideSerializesCorrectly() throws {
        var draft = KanbanComposerDraft()
        draft.title = "Worktree task"
        draft.workspaceKind = .worktree
        draft.workspacePath = " /repos/hermes-agent "
        let request = try KanbanComposerValidator.makeRequest(from: draft, resolvedDefaultAssignee: "default")
        XCTAssertEqual(request.workspaceKind, "worktree")
        XCTAssertEqual(request.workspacePath, "/repos/hermes-agent", "path trimmed and sent for worktree")

        draft.workspaceKind = .scratch
        draft.workspacePath = ""
        let scratchRequest = try KanbanComposerValidator.makeRequest(from: draft, resolvedDefaultAssignee: "default")
        XCTAssertEqual(scratchRequest.workspaceKind, "scratch")
        XCTAssertNil(scratchRequest.workspacePath, "scratch never carries a path")
    }

    func testScratchWithPathIsAnInvalidCombination() {
        var draft = KanbanComposerDraft()
        draft.title = "Bad combo"
        draft.workspaceKind = .scratch
        draft.workspacePath = "/somewhere"
        XCTAssertThrowsError(try KanbanComposerValidator.makeRequest(from: draft, resolvedDefaultAssignee: "default")) { error in
            XCTAssertEqual(error as? KanbanDraftValidationError, .invalidWorkspacePath(.scratch))
        }
    }

    // MARK: - Model / provider / reasoning (V2 §4)

    func testModelOverrideInheritsByOmittingCreateFields() throws {
        var draft = KanbanComposerDraft()
        draft.title = "Inherit"
        let request = try KanbanComposerValidator.makeRequest(from: draft, resolvedDefaultAssignee: "default")
        XCTAssertNil(request.modelOverride)
        XCTAssertNil(request.providerOverride)
        XCTAssertNil(request.reasoningEffort)
    }

    func testModelOverrideSerializesModelProviderEffortOnCreate() throws {
        var draft = KanbanComposerDraft()
        draft.title = "Pinned"
        draft.modelOverride = TaskModelOverride(provider: "openai", model: "gpt-test", reasoningEffort: "high")
        let request = try KanbanComposerValidator.makeRequest(from: draft, resolvedDefaultAssignee: "default")
        XCTAssertEqual(request.modelOverride, "gpt-test")
        XCTAssertEqual(request.providerOverride, "openai")
        XCTAssertEqual(request.reasoningEffort, "high")

        // Provider without a model is meaningless upstream and must be omitted.
        draft.modelOverride = TaskModelOverride(provider: "openai", model: nil, reasoningEffort: nil)
        let providerOnly = try KanbanComposerValidator.makeRequest(from: draft, resolvedDefaultAssignee: "default")
        XCTAssertNil(providerOnly.modelOverride)
        XCTAssertNil(providerOnly.providerOverride)
    }

    func testReasoningEffortNoneIsARealValueAndUnknownIsRejected() throws {
        var draft = KanbanComposerDraft()
        draft.title = "Thinking off"
        draft.modelOverride = TaskModelOverride(reasoningEffort: "none")
        let request = try KanbanComposerValidator.makeRequest(from: draft, resolvedDefaultAssignee: "default")
        XCTAssertEqual(request.reasoningEffort, "none", "none = thinking OFF, not a clear")

        draft.modelOverride = TaskModelOverride(reasoningEffort: "maximum")
        XCTAssertThrowsError(try KanbanComposerValidator.validate(draft)) { error in
            XCTAssertEqual(error as? KanbanDraftValidationError, .invalidReasoningEffort("maximum"))
        }
    }

    func testModelOverridePatchCarriesValuesAndClearFlags() {
        let serverTask = makeTask(
            id: "t1",
            extra: [
                "model_override": "old-model",
                "provider_override": "old-provider",
                "reasoning_effort": "low"
            ]
        )

        // Back to inherit => explicit clear flags.
        let cleared = TaskModelOverride.patch(from: serverTask, to: TaskModelOverride())
        XCTAssertTrue(cleared.clearModelOverride)
        XCTAssertTrue(cleared.clearReasoningEffort)
        XCTAssertNil(cleared.modelOverride)

        // New model replaces; effort kept separate.
        let switched = TaskModelOverride.patch(
            from: serverTask,
            to: TaskModelOverride(provider: "anthropic", model: "claude-test", reasoningEffort: "high")
        )
        XCTAssertFalse(switched.clearModelOverride)
        XCTAssertEqual(switched.modelOverride, "claude-test")
        XCTAssertEqual(switched.providerOverride, "anthropic")
        XCTAssertEqual(switched.reasoningEffort, "high")

        // Dropping ONLY the model does not silently reset an explicit effort.
        let modelDropped = TaskModelOverride.patch(
            from: serverTask,
            to: TaskModelOverride(reasoningEffort: "ultra")
        )
        XCTAssertTrue(modelDropped.clearModelOverride)
        XCTAssertFalse(modelDropped.clearReasoningEffort)
        XCTAssertEqual(modelDropped.reasoningEffort, "ultra")
    }

    // MARK: - Skills (V2 §5)

    func testSelectedSkillsSerializeTrimmedAndDeduplicated() throws {
        var draft = KanbanComposerDraft()
        draft.title = "Skilled"
        draft.skills = [" github ", "translation", "github", "", "   ", "code-review"]
        let request = try KanbanComposerValidator.makeRequest(from: draft, resolvedDefaultAssignee: "default")
        XCTAssertEqual(request.skills, ["github", "translation", "code-review"])

        draft.skills = ["   "]
        let empty = try KanbanComposerValidator.makeRequest(from: draft, resolvedDefaultAssignee: "default")
        XCTAssertNil(empty.skills, "an all-blank selection serializes as absent")
    }

    // MARK: - Goal Mode (V2 §6)

    func testGoalModeSerializesWithOptionalMaxTurns() throws {
        var draft = KanbanComposerDraft()
        draft.title = "Goal"
        draft.goalMode = true
        draft.goalMaxTurns = 25
        let request = try KanbanComposerValidator.makeRequest(from: draft, resolvedDefaultAssignee: "default")
        XCTAssertTrue(request.goalMode)
        XCTAssertEqual(request.goalMaxTurns, 25)

        draft.goalMode = false
        let off = try KanbanComposerValidator.makeRequest(from: draft, resolvedDefaultAssignee: "default")
        XCTAssertFalse(off.goalMode)
        XCTAssertNil(off.goalMaxTurns, "turns only travel when Goal Mode is enabled")
    }

    func testGoalModeZeroTurnsRejectedWhenEnabled() {
        var draft = KanbanComposerDraft()
        draft.title = "Goal"
        draft.goalMode = true
        draft.goalMaxTurns = 0
        XCTAssertThrowsError(try KanbanComposerValidator.validate(draft)) { error in
            XCTAssertEqual(error as? KanbanDraftValidationError, .invalidGoalMaxTurns(0))
        }
        // Disabled Goal Mode with a stale turn value is fine.
        draft.goalMode = false
        XCTAssertNoThrow(try KanbanComposerValidator.validate(draft))
    }

    // MARK: - Parents (V2 §7)

    func testParentDependenciesSerializeAsList() throws {
        var draft = KanbanComposerDraft()
        draft.title = "Child"
        draft.parents = [" t_parent_1 "]
        let request = try KanbanComposerValidator.makeRequest(from: draft, resolvedDefaultAssignee: "default")
        XCTAssertEqual(request.parents, ["t_parent_1"])
    }

    func testDuplicateParentsAreSanitized() {
        let sanitized = KanbanComposerValidator.sanitizedParents(["a", "a", " b ", ""])
        XCTAssertEqual(sanitized, ["a", "b"])
    }

    // MARK: - Creation validation (V2 §8)

    func testEmptyTitleIsRejectedByTheValidationLayer() {
        let draft = KanbanComposerDraft()
        XCTAssertThrowsError(try KanbanComposerValidator.makeRequest(from: draft, resolvedDefaultAssignee: "x")) { error in
            XCTAssertEqual(error as? KanbanDraftValidationError, .emptyTitle)
        }
    }

    func testPriorityIsClampedNonNegative() throws {
        var draft = KanbanComposerDraft()
        draft.title = "P"
        draft.priority = -5
        let request = try KanbanComposerValidator.makeRequest(from: draft, resolvedDefaultAssignee: "d")
        XCTAssertEqual(request.priority, 0)
    }

    // MARK: - Actions (V2 §10)

    func testArchiveSendsArchivedStatusPatch() async throws {
        let requester = V2MockKanbanRequester()
        requester.responsesByPath["/api/plugins/kanban/tasks/t9"] = ["task": ["id": "t9", "title": "x", "status": "archived"]]
        let service = KanbanService(requester: requester)
        _ = try await service.updateTask(id: "t9", board: "alpha", patch: KanbanTaskPatch(status: "archived"))
        let call = try XCTUnwrap(requester.calls.last)
        XCTAssertEqual(call.method, "PATCH")
        XCTAssertTrue(call.path.hasPrefix("/api/plugins/kanban/tasks/t9?board=alpha"), call.path)
        XCTAssertEqual(call.body?["status"] as? String, "archived")
    }

    func testArchivePassesTheManualCapabilityGate() {
        // Upstream archive_task is reached via PATCH status='archived'; the
        // client capability matrix must not block it.
        XCTAssertTrue(KanbanStatusPresentation.canSelectManually("archived"))
    }

    func testDeleteRemainsDeleteMethod() async throws {
        let requester = V2MockKanbanRequester()
        let service = KanbanService(requester: requester)
        try await service.deleteTask(id: "t1", board: "beta")
        let call = try XCTUnwrap(requester.calls.last)
        XCTAssertEqual(call.method, "DELETE")
        XCTAssertTrue(call.path.contains("/tasks/t1"))
        XCTAssertTrue(call.path.contains("board=beta"))
    }

    func testMoveToRunningIsRefusedBeforeAnyTransport() async throws {
        var responses = standardKanbanResponses(boardSlug: "alpha")
        responses["/api/plugins/kanban/tasks/t1"] = ["task": ["id": "t1", "title": "x", "status": "todo"]]
        let requester = V2MockKanbanRequester(responsesByPath: responses)
        let store = makeStore(requester: requester)
        await store.refresh()

        do {
            _ = try await store.updateTask(id: "t1", patch: KanbanTaskPatch(status: "running"))
            XCTFail("manual move into Running must be refused")
        } catch {}
        XCTAssertFalse(requester.calls.contains { $0.method == "PATCH" })
    }

    func testShortIDHelperMatchesUpstreamSemantics() {
        XCTAssertEqual(KanbanShortID.of("t_abcdef123456"), "abcdef")
        XCTAssertEqual(KanbanShortID.of("abcdef123456"), "abcdef", "ids without prefix still shorten")
        XCTAssertEqual(KanbanShortID.of("t_ab"), "ab")
        XCTAssertEqual(KanbanShortID.of(nil), "")
    }

    // MARK: - Reassignment / reclaim (V2 §12, §19)

    func testReassignUsesDedicatedEndpointWithReclaimFirstBody() async throws {
        let requester = V2MockKanbanRequester()
        let service = KanbanService(requester: requester)
        try await service.reassignTask(taskID: "t7", board: "alpha", profile: "archimedes", reclaimFirst: true)
        let call = try XCTUnwrap(requester.calls.last)
        XCTAssertEqual(call.method, "POST")
        XCTAssertTrue(call.path.contains("/tasks/t7/reassign"))
        XCTAssertTrue(call.path.contains("board=alpha"))
        XCTAssertEqual(call.body?["profile"] as? String, "archimedes")
        XCTAssertEqual(call.body?["reclaim_first"] as? Bool, true)
    }

    func testReclaimUsesDedicatedEndpoint() async throws {
        let requester = V2MockKanbanRequester()
        let service = KanbanService(requester: requester)
        try await service.reclaimTask(taskID: "t7", board: "alpha", reason: "stuck")
        let call = try XCTUnwrap(requester.calls.last)
        XCTAssertTrue(call.path.contains("/tasks/t7/reclaim"))
        XCTAssertEqual(call.body?["reason"] as? String, "stuck")
    }

    func testStaleReassignCompletionCannotTouchNewServer() async throws {
        var responsesA = standardKanbanResponses(boardSlug: "a-board")
        responsesA["/api/plugins/kanban/profiles"] = ["profiles": [["name": "alpha-profile", "is_default": true, "description": "", "description_auto": false]]]
        let requesterA = V2MockKanbanRequester(responsesByPath: responsesA)
        let store = makeStore(requester: requesterA)
        await store.refresh()

        requesterA.hold(pathPrefix: "/api/plugins/kanban/tasks/t1/reassign")
        let mutation = Task { try? await store.reassignTask(taskID: "t1", profile: "beta-profile", reclaimFirst: true) }
        await Task.yield(); await Task.yield(); await Task.yield()

        let requesterB = V2MockKanbanRequester(responsesByPath: standardKanbanResponses(boardSlug: "b-board"))
        store.configure(requester: requesterB, serverIdentity: "https://b.test")
        await store.reload()
        let bCallsBeforeRelease = requesterB.calls.count

        requesterA.errorsByPath["/api/plugins/kanban/tasks/t1/reassign"] = MockRequestError.failed("A reassign exploded")
        requesterA.releaseAll()
        _ = await mutation.value

        XCTAssertNil(store.mutationErrorMessage, "stale completion must be inert on server B")
        XCTAssertFalse(store.isMutating)
        XCTAssertEqual(requesterB.calls.count, bCallsBeforeRelease)
    }

    // MARK: - Diagnostics & dependencies decoding (V2 §14, §15)

    func testMalformedDiagnosticsDoNotCrashDecoding() throws {
        let json = "{" +
            "\"id\":\"t1\",\"title\":\"x\",\"status\":\"blocked\"," +
            "\"diagnostics\":[" +
            "{\"kind\":\"stale_claim\",\"severity\":\"warning\",\"title\":\"Stale claim\",\"detail\":\"no heartbeat\",\"count\":\"3\",\"last_seen_at\":\"1700\",\"actions\":[{\"kind\":\"reclaim\",\"label\":\"Reclaim\"}]}," +
            "{\"severity\":123,\"actions\":\"not-an-array\",\"data\":{\"weird\":[1,2]}}" +
            "]}"
        let task = try JSONDecoder().decode(KanbanTask.self, from: Data(json.utf8))
        let diagnostics = try XCTUnwrap(task.diagnostics)
        XCTAssertEqual(diagnostics.count, 2, "hostile rows normalize instead of crashing or vanishing wholesale")
        XCTAssertEqual(diagnostics[0].count, 3, "stringly count decodes lossily")
        XCTAssertEqual(diagnostics[0].lastSeenAt, 1700)
        XCTAssertEqual(diagnostics[0].actions.first?.kind, "reclaim")
        XCTAssertEqual(diagnostics[1].kind, "", "missing identity text degrades to empty")
        XCTAssertEqual(diagnostics[1].severity, "123", "wrong-typed scalars degrade through the lossy string path")
        XCTAssertTrue(diagnostics[1].actions.isEmpty, "a non-array actions payload becomes an empty list")
    }

    func testDiagnosticCLIHintActionCarriesCommandPayload() throws {
        let json = "{" +
            "\"id\":\"t1\",\"title\":\"x\",\"status\":\"blocked\"," +
            "\"diagnostics\":[{\"kind\":\"k\",\"severity\":\"error\",\"title\":\"T\",\"detail\":\"D\",\"count\":1," +
            "\"actions\":[{\"kind\":\"cli_hint\",\"label\":\"Copy fix\",\"payload\":{\"command\":\"hermes kanban reclaim t1\"}}]}]}"
        let task = try JSONDecoder().decode(KanbanTask.self, from: Data(json.utf8))
        let action = try XCTUnwrap(task.diagnostics?.first?.actions.first)
        XCTAssertEqual(action.payload?["command"]?.stringValue, "hermes kanban reclaim t1")
    }

    func testDependencyLinksDecodeIntoParentsAndChildren() throws {
        let json = "{" +
            "\"task\":{\"id\":\"kid\",\"title\":\"child\",\"status\":\"blocked\"}," +
            "\"comments\":[],\"events\":[],\"attachments\":[]," +
            "\"links\":{\"parents\":[\"t_parent\"],\"children\":[\"t_grand\"]}," +
            "\"child_results\":[],\"runs\":[]}"
        let detail = try JSONDecoder().decode(KanbanTaskDetail.self, from: Data(json.utf8))
        XCTAssertEqual(detail.links.parents, ["t_parent"])
        XCTAssertEqual(detail.links.children, ["t_grand"])
    }

    // MARK: - Activity presentation (V2 §16)

    private func makeEvent(kind: String, payload: [String: AnyCodable] = [:]) -> KanbanEvent {
        KanbanEvent(id: "1", taskID: "t", kind: kind, payload: payload.isEmpty ? nil : .object(payload), createdAt: 100)
    }

    func testKnownActivityEventsMapToHumanRows() {
        let moved = KanbanActivityFormatter.row(for: makeEvent(kind: "status", payload: ["status": .string("ready")]))
        XCTAssertEqual(moved.label, "Moved to Ready")

        let assigned = KanbanActivityFormatter.row(for: makeEvent(kind: "assigned", payload: ["assignee": .string("arch")]))
        XCTAssertEqual(assigned.label, "Assigned to arch")

        let unassigned = KanbanActivityFormatter.row(for: makeEvent(kind: "assigned", payload: [:]))
        XCTAssertEqual(unassigned.label, "Unassigned")

        let spawned = KanbanActivityFormatter.row(for: makeEvent(kind: "spawned", payload: ["pid": .number(4242)]))
        XCTAssertEqual(spawned.label, "Worker started")
        XCTAssertEqual(spawned.detail, "pid 4242")

        let claimedFromReview = KanbanActivityFormatter.row(for: makeEvent(kind: "claimed", payload: ["source_status": .string("review")]))
        XCTAssertEqual(claimedFromReview.label, "Claimed from review")
    }

    func testUnknownActivityEventGetsGracefulFallback() {
        let row = KanbanActivityFormatter.row(
            for: makeEvent(kind: "quantum_sync", payload: ["shard": .string("a"), "level": .number(2)])
        )
        XCTAssertEqual(row.label, "Quantum Sync", "unknown kinds become readable words")
        XCTAssertEqual(row.detail, "level=2 shard=a", "scalar payload folds into detail; no raw JSON dump, no crash")

        let emptyRow = KanbanActivityFormatter.row(for: makeEvent(kind: "mystery"))
        XCTAssertEqual(emptyRow.label, "Mystery")
        XCTAssertNil(emptyRow.detail)
    }

    func testParentReopenedReasonIsExplained() {
        let row = KanbanActivityFormatter.row(
            for: makeEvent(kind: "status", payload: ["status": .string("blocked"), "reason": .string("parent_reopened"), "parent": .string("t_p")])
        )
        XCTAssertEqual(row.detail, "parent t_p reopened")
    }

    // MARK: - Runs presentation (V2 §17)

    func testRunFailureClassificationMatchesUpstreamSet() {
        for outcome in ["crashed", "failed", "timed_out", "gave_up"] {
            let run = makeRun(outcome: outcome)
            XCTAssertTrue(KanbanRunPresentation.isFailed(run), outcome)
        }
        XCTAssertFalse(KanbanRunPresentation.isFailed(makeRun(outcome: "completed")))
        XCTAssertFalse(KanbanRunPresentation.isFailed(makeRun(outcome: nil, status: "completed")))
        XCTAssertTrue(KanbanRunPresentation.isFailed(makeRun(outcome: nil, status: "failed")), "falls back through status")
    }

    func testRunDurationFormatting() {
        XCTAssertEqual(KanbanRunPresentation.durationText(start: 100, end: 130), "30s")
        XCTAssertEqual(KanbanRunPresentation.durationText(start: 100, end: 220), "2m")
        XCTAssertEqual(KanbanRunPresentation.durationText(start: 100, end: 5000), "1h")
        XCTAssertNil(KanbanRunPresentation.durationText(start: nil, end: 200))
        XCTAssertNil(KanbanRunPresentation.durationText(start: 300, end: 100), "end before start is not a duration")
    }

    // MARK: - Worker log context (V2 §18)

    func testWorkerLogFetchPinsBoardAndTail() async throws {
        let requester = V2MockKanbanRequester()
        requester.responsesByPath["/api/plugins/kanban/tasks/t1/log"] = [
            "exists": true, "size_bytes": 12, "content": "hello\nworld", "truncated": false
        ]
        let service = KanbanService(requester: requester)
        let log = try await service.fetchTaskLog(id: "t1", board: "alpha", tailBytes: 65_536)
        XCTAssertTrue(log.exists)
        XCTAssertEqual(log.content, "hello\nworld")
        let call = try XCTUnwrap(requester.calls.last)
        XCTAssertTrue(call.path.contains("/tasks/t1/log?"), call.path)
        XCTAssertTrue(call.path.contains("tail=65536"), call.path)
        XCTAssertTrue(call.path.contains("board=alpha"), call.path)
    }

    func testStoreWorkerLogUsesLoadedSnapshotBoard() async throws {
        var responses = standardKanbanResponses(boardSlug: "alpha")
        responses["/api/plugins/kanban/tasks/t-log/log?board=alpha&tail=1024"] = [
            "exists": true, "size_bytes": 1, "content": "x", "truncated": false
        ]
        let requester = V2MockKanbanRequester(responsesByPath: responses)
        let store = makeStore(requester: requester)
        await store.selectBoard(slug: "alpha")
        let log = try await store.fetchTaskLog(id: "t-log", tailBytes: 1024)
        XCTAssertTrue(log.exists)
        XCTAssertTrue(
            requester.calls.contains { $0.path.contains("/tasks/t-log/log?board=alpha&tail=1024") },
            requester.calls.map(\.path).joined(separator: " | ")
        )
    }

    func testWorkerLogRenderTailCapsAndKeepsNewest() {
        let huge = String(repeating: "x", count: 70_000)
        let rendered = KanbanWorkerLogScreen.renderTail(huge)
        XCTAssertLessThanOrEqual(rendered.count, KanbanWorkerLogScreen.maxRenderedCharacters + 40)
        XCTAssertTrue(rendered.hasPrefix("[older output omitted]"))
        XCTAssertEqual(KanbanWorkerLogScreen.renderTail("small"), "small")
    }

    // MARK: - Model options decoding (V2 §4)

    func testModelOptionsDecodeTolerantly() async throws {
        let empty = try JSONDecoder().decode(KanbanModelOptionsResponse.self, from: Data("{}".utf8))
        XCTAssertTrue(empty.providers.isEmpty)

        let json = "{" +
            "\"providers\":[" +
            "{\"slug\":\"openai\",\"label\":\"OpenAI\",\"models\":[\"gpt-a\",\"\",\"gpt-b\"]}," +
            "{\"models\":\"junk\"}" +
            "]}"
        let decoded = try JSONDecoder().decode(KanbanModelOptionsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.providers.count, 2, "hostile rows normalize instead of crashing")
        XCTAssertEqual(decoded.providers[0].models, ["gpt-a", "gpt-b"])

        // The service boundary drops unusable rows so the picker only ever
        // sees an offerable catalog.
        let mock = V2MockKanbanRequester()
        mock.responsesByPath["/api/plugins/kanban/model-options"] =
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
        let service = KanbanService(requester: mock)
        let options = try await service.fetchModelOptions()
        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options[0].slug, "openai")
        XCTAssertEqual(options[0].models, ["gpt-a", "gpt-b"])
    }


    // MARK: - Review-pass hardening (render cap, walker termination, wire contracts)

    func testRenderTailStaysWithinBudgetEvenWithoutNewlines() {
        let budget = KanbanWorkerLogScreen.maxRenderedCharacters
        // Exactly at budget: returned verbatim, no marker.
        XCTAssertEqual(KanbanWorkerLogScreen.renderTail(String(repeating: "a", count: budget)).count, budget)
        // One over budget with NO newline anywhere: must still be capped.
        let rendered = KanbanWorkerLogScreen.renderTail(String(repeating: "x", count: budget + 1))
        XCTAssertLessThanOrEqual(rendered.count, budget)
        XCTAssertTrue(rendered.hasPrefix("[older output omitted]"))
    }

    func testRenderTailResumesAtLineBoundaryWhenAvailable() {
        let budget = KanbanWorkerLogScreen.maxRenderedCharacters
        var content = String(repeating: "=", count: budget - 10)
        content += "\nNEWEST LINE"
        let rendered = KanbanWorkerLogScreen.renderTail(content)
        XCTAssertTrue(rendered.hasSuffix("NEWEST LINE"))
        XCTAssertFalse(rendered.contains("======="), "mid-line prefix is trimmed to the line boundary")
    }

    func testHostileActionsArrayTerminatesDecoding() throws {
        // Every element is scalar junk: neither typed decode nor the AnyCodable
        // consumer has an easy row; the bounded walker must still terminate.
        let json = "{" +
            "\"id\":\"t1\",\"title\":\"x\",\"status\":\"blocked\"," +
            "\"diagnostics\":[{\"kind\":\"k\",\"severity\":\"error\",\"title\":\"T\",\"detail\":\"D\",\"count\":1," +
            "\"actions\":[1, true, \"text\", null]}]}"
        let task = try JSONDecoder().decode(KanbanTask.self, from: Data(json.utf8))
        XCTAssertEqual(task.diagnostics?.first?.actions.count, 0, "scalar junk normalizes to no actions")
    }

    func testModelOnlyPatchOmitsProviderSoBackendNullsIt() {
        // Backend contract (kanban_db.set_model_override): a PATCH carrying
        // model_override without provider_override writes provider=NULL — the
        // stale provider cannot survive a model-only edit. Conduit matches by
        // OMITTING the field (never sending "").
        let serverTask = makeTask(id: "t1", extra: [
            "model_override": "old-model",
            "provider_override": "old-provider"
        ])
        let patch = TaskModelOverride.patch(
            from: serverTask,
            to: TaskModelOverride(model: "new-model")
        )
        XCTAssertEqual(patch.modelOverride, "new-model")
        XCTAssertNil(patch.providerOverride, "omitted on the wire so the backend nulls the stored provider")
        XCTAssertFalse(patch.clearModelOverride)
    }

    // MARK: - Helpers

    private func makeTask(id: String, extra: [String: Any]) -> KanbanTask {
        var object: [String: Any] = ["id": id, "title": "T", "status": "todo"]
        for (key, value) in extra { object[key] = value }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSONDecoder().decode(KanbanTask.self, from: data)
    }

    private func makeRun(outcome: String?, status: String = "completed") -> KanbanRun {
        var object: [String: Any] = ["id": "r1", "status": status]
        if let outcome { object["outcome"] = outcome }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSONDecoder().decode(KanbanRun.self, from: data)
    }

    private func makeStore(
        requester: V2MockKanbanRequester,
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

// MARK: - Test doubles

private enum MockRequestError: LocalizedError {
    case failed(String)
    var errorDescription: String? { switch self { case .failed(let m): return m } }
}

@MainActor
private final class V2MockKanbanRequester: DashboardJSONRequester {
    struct Call {
        let path: String
        let method: String
        let body: [String: Any]?
    }

    var responsesByPath: [String: [String: Any]]
    var errorsByPath: [String: Error] = [:]
    private var holdsActive: Set<String> = []
    private struct HeldRequest {
        let continuation: CheckedContinuation<Void, Never>
    }
    private var heldRequests: [HeldRequest] = []
    var calls: [Call] = []

    init(responsesByPath: [String: [String: Any]] = [:]) {
        self.responsesByPath = responsesByPath
    }

    func hold(pathPrefix: String) { holdsActive.insert(pathPrefix) }

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
                heldRequests.append(HeldRequest(continuation: continuation))
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
            "boards": [["slug": boardSlug, "name": boardSlug, "is_current": true]],
            "current": boardSlug
        ],
        "/api/plugins/kanban/board": ["columns": [], "tenants": [], "assignees": [], "latest_event_id": 1, "now": 2],
        "/api/plugins/kanban/profiles": ["profiles": []],
        "/api/plugins/kanban/projects": ["projects": []],
        "/api/plugins/kanban/orchestration": [
            "orchestrator_profile": "",
            "default_assignee": "",
            "auto_decompose": true,
            "resolved_orchestrator_profile": "default",
            "resolved_default_assignee": "default"
        ],
        "/api/plugins/kanban/dispatch": [:],
        "/api/plugins/kanban/model-options": ["providers": []]
    ]
}
