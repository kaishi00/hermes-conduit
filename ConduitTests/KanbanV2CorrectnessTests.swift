import XCTest
@testable import Conduit

/// Final correctness pass for Kanban V2 (PR #93): task-identity invariants
/// on the detail screen, card-delete confirmation, model-override display,
/// Note & requeue partial success, and worker-log cached-content rules.
///
/// These tests exercise the extracted policies the views execute — the same
/// no-UI-timing idiom as KanbanTests/KanbanV2Tests.
@MainActor
final class KanbanV2CorrectnessTests: XCTestCase {

    // MARK: - Helpers

    private enum CorrectnessTestError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let message): return message
            }
        }
    }

    private func makeContextRaceStore(requester: ContextRaceMockRequester) -> KanbanStore {
        let store = KanbanStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        store.configure(requester: requester, serverIdentity: "https://a.test")
        return store
    }

    private func makeTask(id: String, extra: [String: Any] = [:]) -> KanbanTask {
        var object: [String: Any] = ["id": id, "title": "T", "status": "todo"]
        for (key, value) in extra { object[key] = value }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSONDecoder().decode(KanbanTask.self, from: data)
    }

    // MARK: - 1/2. Dependency navigation & failed replacement fetch

    func testDependencyNavigationNeverExposesPreviousTaskAsActionable() {
        let taskA = makeTask(id: "task-a", extra: ["title": "A"])
        let taskB = makeTask(id: "task-b", extra: ["title": "B"])

        // Opened A, then tapped dependency B: the screen's identity is B and
        // B's detail request is still in flight. A — the OPENING task — must
        // not be actionable: no A metadata, no Copy ID/Title of A, no
        // Archive/Delete/model mutations against A.
        XCTAssertNil(
            KanbanDetailIdentityPolicy.actionableTask(displayedID: "task-b", detailTask: nil, initialTask: taskA),
            "a loading replacement must never fall back to the opening task"
        )

        // Once B's detail lands, B is the actionable task.
        XCTAssertEqual(
            KanbanDetailIdentityPolicy.actionableTask(displayedID: "task-b", detailTask: taskB, initialTask: taskA)?.id,
            "task-b"
        )

        // A detail belonging to a DIFFERENT identity than the one displayed
        // can never become actionable (stale poll completion).
        XCTAssertNil(
            KanbanDetailIdentityPolicy.actionableTask(displayedID: "task-b", detailTask: taskA, initialTask: taskA)
        )

        // The opening identity keeps its V1 behavior: A is actionable on A's
        // own screen even before the first detail load completes.
        XCTAssertEqual(
            KanbanDetailIdentityPolicy.actionableTask(displayedID: "task-a", detailTask: nil, initialTask: taskA)?.id,
            "task-a"
        )
    }

    func testFailedReplacementFetchNeverResurrectsPreviousTask() {
        let taskA = makeTask(id: "task-a")
        // B's fetch failed: the failure belongs to B and the screen stays on
        // B's identity — A must not come back as the actionable task.
        let actionable = KanbanDetailIdentityPolicy.actionableTask(
            displayedID: "task-b",
            detailTask: nil,
            initialTask: taskA
        )
        XCTAssertNil(actionable, "a failed replacement fetch must never resurrect the previous task")
    }

    // MARK: - 3/4/5. Stale mutation completions

    func testStaleSaveCompletionCannotOverwriteDisplayedTask() {
        let taskA = makeTask(id: "task-a", extra: ["title": "A title"])
        let serverA = makeTask(id: "task-a", extra: ["title": "A title (server)"])

        // Save started on A, response arrives after navigation to B: the
        // completion is inert — no draft/baseline write, no error, no
        // refresh for B.
        let staleWithResponse = KanbanDetailMutationPolicy.saveCompletion(
            startedTask: taskA,
            response: serverA,
            displayedTaskID: "task-b"
        )
        XCTAssertFalse(staleWithResponse.isActive)
        XCTAssertNil(staleWithResponse.serverTask)

        // Same shape with no response body: still inert.
        let staleNoResponse = KanbanDetailMutationPolicy.saveCompletion(
            startedTask: taskA,
            response: nil,
            displayedTaskID: "task-b"
        )
        XCTAssertFalse(staleNoResponse.isActive)
        XCTAssertNil(staleNoResponse.serverTask)
    }

    func testStaleSaveFailureCannotShowErrorOnDisplayedTask() {
        // The same ownership gate governs the catch path: a failure that
        // started for A may not surface anywhere while B is displayed.
        XCTAssertFalse(
            KanbanDetailMutationPolicy.completionIsActive(startedTaskID: "task-a", displayedTaskID: "task-b")
        )
        XCTAssertTrue(
            KanbanDetailMutationPolicy.completionIsActive(startedTaskID: "task-b", displayedTaskID: "task-b")
        )
    }

    func testStaleDestructiveCompletionCannotDismissDisplayedTask() {
        // Delete started on A, A's delete succeeds after navigation to B:
        // the completion gate keeps it from dismissing B's screen (and from
        // surfacing A's errors or refreshes on B).
        XCTAssertFalse(
            KanbanDetailMutationPolicy.completionIsActive(startedTaskID: "task-a", displayedTaskID: "task-b"),
            "a stale delete completion must never dismiss or mutate the displayed task's screen"
        )
    }

    func testActiveSaveCompletionSeedsBaselineFromStartedTaskOrItsResponse() {
        let taskA = makeTask(id: "task-a", extra: ["title": "A title"])
        // Active completion with no task in the response must seed from the
        // task that STARTED the save — never from whatever task is displayed
        // when the response lands (the old saved ?? currentTask re-read).
        let noResponse = KanbanDetailMutationPolicy.saveCompletion(
            startedTask: taskA,
            response: nil,
            displayedTaskID: "task-a"
        )
        XCTAssertTrue(noResponse.isActive)
        XCTAssertEqual(noResponse.serverTask?.id, "task-a")
        XCTAssertEqual(noResponse.serverTask?.title, "A title")

        // Active completion WITH a server response seeds from the response
        // for the started identity.
        let serverResponse = makeTask(id: "task-a", extra: ["title": "A title (server)"])
        let withResponse = KanbanDetailMutationPolicy.saveCompletion(
            startedTask: taskA,
            response: serverResponse,
            displayedTaskID: "task-a"
        )
        XCTAssertTrue(withResponse.isActive)
        XCTAssertEqual(withResponse.serverTask?.title, "A title (server)")

        // A response echoing a DIFFERENT id never seeds the started task's
        // baseline — the started task stands in until the forced reload
        // re-syncs from the authoritative task.
        let foreignResponse = makeTask(id: "task-z", extra: ["title": "Foreign title"])
        let withForeign = KanbanDetailMutationPolicy.saveCompletion(
            startedTask: taskA,
            response: foreignResponse,
            displayedTaskID: "task-a"
        )
        XCTAssertTrue(withForeign.isActive)
        XCTAssertEqual(withForeign.serverTask?.id, "task-a")
        XCTAssertEqual(withForeign.serverTask?.title, "A title")

        // An EMPTY-id response under a NON-empty started task is the same
        // contract violation: the started task seeds the baseline until the
        // forced reload re-syncs.
        let emptyIDResponse = makeTask(id: "", extra: ["title": "Poisoned"])
        let withEmptyID = KanbanDetailMutationPolicy.saveCompletion(
            startedTask: taskA,
            response: emptyIDResponse,
            displayedTaskID: "task-a"
        )
        XCTAssertTrue(withEmptyID.isActive)
        XCTAssertEqual(withEmptyID.serverTask?.id, "task-a")
        XCTAssertEqual(withEmptyID.serverTask?.title, "A title")
    }

    func testMismatchedEmptyIDDetailIsNeverActionable() {
        let taskA = makeTask(id: "task-a")
        let emptyID = makeTask(id: "")
        let taskB = makeTask(id: "task-b")
        // Same-identity empty/empty still matches through the equality
        // branch (an identity fetched BY its own empty id).
        XCTAssertEqual(
            KanbanDetailIdentityPolicy.actionableTask(displayedID: "", detailTask: emptyID, initialTask: taskA)?.id,
            ""
        )
        // A detail with an EMPTY id under a NON-EMPTY displayed identity is a
        // server contract violation: honoring it would aim mutations at an
        // empty task id and break startedTask.id == displayedTaskID gating
        // (silently inert saves, PATCH/DELETE against /tasks/""). It must be
        // non-actionable — the loading/failed state renders and the poll
        // keeps retrying the displayed identity.
        XCTAssertNil(
            KanbanDetailIdentityPolicy.actionableTask(displayedID: "task-b", detailTask: emptyID, initialTask: taskA),
            "an empty-id detail must never stand in for a non-empty displayed identity"
        )
        // The general boundary: a detail belonging to a different identity
        // can never become actionable, and a true match always does.
        XCTAssertNil(
            KanbanDetailIdentityPolicy.actionableTask(displayedID: "task-b", detailTask: taskA, initialTask: taskA)
        )
        XCTAssertNotNil(
            KanbanDetailIdentityPolicy.actionableTask(displayedID: "task-b", detailTask: taskB, initialTask: taskA)
        )
    }

    // MARK: - 6. Card delete confirmation

    func testCardDeleteActionNeverIssuesDestructiveMutationDirectly() {
        let task = makeTask(id: "task-a")
        let stamp = KanbanBoardContextStamp(boardSlug: "alpha", configurationGeneration: 3)

        // Both card entry points (ellipsis menu and context menu) route
        // through the staging request: never the destructive mutation, and
        // always stamped with the staging board/server context.
        let staged = KanbanCardDeletePolicy.cardRequestedDelete(for: task, stamp: stamp)
        XCTAssertEqual(
            staged,
            .confirm(PendingCardDelete(task: task, stamp: stamp))
        )
        if case .perform = staged {
            XCTFail("a card action must never issue the destructive DELETE directly")
        }

        // Only an explicit confirmation that still owns the staging context
        // resolves to the destructive request.
        XCTAssertEqual(
            KanbanCardDeletePolicy.confirmed(staged: stagedIfConfirm(staged), currentStamp: stamp, isSnapshotActionable: true),
            .perform(task)
        )
        XCTAssertEqual(KanbanCardDeletePolicy.cancelled(), .none)
        XCTAssertEqual(
            KanbanCardDeletePolicy.confirmed(staged: nil, currentStamp: stamp, isSnapshotActionable: true),
            .none
        )
    }

    /// Staging helper mirroring the view: only a .confirm carries a pending
    /// delete; anything else stages nothing.
    private func stagedIfConfirm(_ request: KanbanCardDeletePolicy.Request) -> PendingCardDelete? {
        if case .confirm(let pending) = request { return pending }
        return nil
    }

    // MARK: - 6b. Card delete context ownership (staged confirmation races)

    func testStagedCardDeleteIsInertAfterServerReconfigure() async throws {
        let requesterA = ContextRaceMockRequester(responsesByPath: contextRaceResponses(boardSlug: "alpha"))
        let store = makeContextRaceStore(requester: requesterA)
        await store.refresh()

        // Stage exactly as the view does: task by value + current stamp.
        let stampA = try XCTUnwrap(store.loadedContextStamp)
        let staged = stagedIfConfirm(
            KanbanCardDeletePolicy.cardRequestedDelete(for: makeTask(id: "t1"), stamp: stampA)
        )

        // The dashboard/server reconfigures to B before the user confirms.
        let requesterB = ContextRaceMockRequester(responsesByPath: contextRaceResponses(boardSlug: "beta"))
        store.configure(requester: requesterB, serverIdentity: "https://b.test")
        await store.reload()

        let outcome = KanbanCardDeletePolicy.confirmed(
            staged: staged,
            currentStamp: store.loadedContextStamp,
            isSnapshotActionable: store.isSelectedSnapshotLoaded
        )
        XCTAssertEqual(outcome, KanbanCardDeletePolicy.Request.none, "a confirmation staged on server A must never delete on server B")
        XCTAssertFalse(requesterB.calls.contains { $0.method == "DELETE" }, "zero DELETE requests may reach server B")
        XCTAssertFalse(requesterA.calls.contains { $0.method == "DELETE" }, "nothing was sent to A either — the request was discarded before any transport")
    }

    func testStagedCardDeleteIsInertAfterBoardSwitchOnSameServer() async throws {
        // The SAME task id exists on both boards: the id alone must never be
        // the ownership token.
        var responses = contextRaceResponses(boardSlug: "alpha")
        responses["/api/plugins/kanban/board?board=alpha"] = [
            "columns": [["name": "todo", "tasks": [["id": "t1", "title": "on alpha", "status": "todo"]]]],
            "tenants": [], "assignees": []
        ]
        responses["/api/plugins/kanban/board?board=beta"] = [
            "columns": [["name": "todo", "tasks": [["id": "t1", "title": "on beta", "status": "todo"]]]],
            "tenants": [], "assignees": []
        ]
        let requester = ContextRaceMockRequester(responsesByPath: responses)
        let store = makeContextRaceStore(requester: requester)
        await store.selectBoard(slug: "alpha")

        let stampA = try XCTUnwrap(store.loadedContextStamp)
        XCTAssertEqual(stampA.boardSlug, "alpha")
        let staged = stagedIfConfirm(
            KanbanCardDeletePolicy.cardRequestedDelete(for: makeTask(id: "t1"), stamp: stampA)
        )

        // Confirm while the new board is still loading (loaded snapshot is
        // still alpha, but it is no longer actionable): discarded.
        let inFlightOutcome = KanbanCardDeletePolicy.confirmed(
            staged: staged,
            currentStamp: KanbanBoardContextStamp(boardSlug: "alpha", configurationGeneration: stampA.configurationGeneration),
            isSnapshotActionable: false
        )
        XCTAssertEqual(inFlightOutcome, KanbanCardDeletePolicy.Request.none, "an in-flight board navigation must invalidate a staged confirmation")

        // Select board B on the SAME server and let it load.
        await store.selectBoard(slug: "beta")
        let outcome = KanbanCardDeletePolicy.confirmed(
            staged: staged,
            currentStamp: store.loadedContextStamp,
            isSnapshotActionable: store.isSelectedSnapshotLoaded
        )
        XCTAssertEqual(outcome, KanbanCardDeletePolicy.Request.none, "a confirmation staged on board A must never delete on board B, even for a colliding task id")
        XCTAssertFalse(requester.calls.contains { $0.method == "DELETE" }, "zero DELETE requests may leave for any board")
    }

    func testConfirmedCardDeleteOnUnchangedContextSendsExactlyOneDelete() async throws {
        var responses = contextRaceResponses(boardSlug: "alpha")
        responses["/api/plugins/kanban/tasks/t1"] = ["ok": true]
        let requester = ContextRaceMockRequester(responsesByPath: responses)
        let store = makeContextRaceStore(requester: requester)
        await store.refresh()

        let stamp = try XCTUnwrap(store.loadedContextStamp)
        let staged = stagedIfConfirm(
            KanbanCardDeletePolicy.cardRequestedDelete(for: makeTask(id: "t1"), stamp: stamp)
        )

        // Context unchanged: the confirmation resolves and the view's delete
        // issues exactly one DELETE to the staging board.
        guard case .perform(let task) = KanbanCardDeletePolicy.confirmed(
            staged: staged,
            currentStamp: store.loadedContextStamp,
            isSnapshotActionable: store.isSelectedSnapshotLoaded
        ) else {
            return XCTFail("an unchanged context must honor the confirmed delete")
        }
        try await store.deleteTask(id: task.id)
        await store.awaitPendingDispatcherNudgeForTesting()

        let deletes = requester.calls.filter { $0.method == "DELETE" }
        XCTAssertEqual(deletes.count, 1, "exactly one DELETE for the staged task")
        XCTAssertTrue(deletes[0].path.contains("/tasks/t1"), deletes[0].path)
        XCTAssertTrue(deletes[0].path.contains("board=alpha"), deletes[0].path)
    }

    // MARK: - 7. Existing model override display

    func testExistingModelOverrideDisplaysWithoutOpeningEditor() {
        let overridden = makeTask(id: "task-a", extra: [
            "model_override": "glm-4.7",
            "provider_override": "zhipu",
            "reasoning_effort": "high"
        ])
        // The visible row label derives from the loaded SERVER task, so an
        // existing override shows immediately — without opening the sheet.
        let label = KanbanModelOverrideDisplayPolicy.label(for: overridden, inheritCopy: "Inherit from profile")
        XCTAssertTrue(label.contains("zhipu"), label)
        XCTAssertTrue(label.contains("glm-4.7"), label)
        XCTAssertTrue(label.contains("High"), label)
        XCTAssertFalse(label.contains("Inherit"), label)

        // An inherited task still inherits.
        let inherited = makeTask(id: "task-b")
        XCTAssertEqual(
            KanbanModelOverrideDisplayPolicy.label(for: inherited, inheritCopy: "Inherit from profile"),
            "Inherit from profile"
        )
        // Not-yet-loaded replacement identity: inherit copy, never stale
        // data from the previous task.
        XCTAssertEqual(
            KanbanModelOverrideDisplayPolicy.label(for: nil, inheritCopy: "Inherit from profile"),
            "Inherit from profile"
        )
    }

    func testModelOverrideEditorDraftIsIndependentOfLaterServerChanges() {
        let serverAtOpen = makeTask(id: "task-a", extra: [
            "model_override": "glm-4.7",
            "provider_override": "zhipu"
        ])
        // The editor draft is seeded from the server task at OPEN time only.
        let seededDraft = KanbanModelOverrideDisplayPolicy.override(for: serverAtOpen)
        XCTAssertEqual(seededDraft.model, "glm-4.7")
        // A later poll that changes the server override updates the DISPLAY
        // row (server-derived) but never the seeded editor draft: polling
        // cannot clobber an open editor, and loadDetail has no draft writes.
        let serverAfterPoll = makeTask(id: "task-a", extra: [
            "model_override": "glm-5.3",
            "provider_override": "zhipu"
        ])
        XCTAssertEqual(
            KanbanModelOverrideDisplayPolicy.label(for: serverAfterPoll, inheritCopy: "Inherit from profile"),
            "zhipu: glm-5.3"
        )
        XCTAssertEqual(seededDraft.model, "glm-4.7", "the editor draft is never rewritten by later server loads")
    }

    // MARK: - 7b. Model sheet session (no-edit vs server-changed race)

    func testModelSheetBaselineSeedingPinsToTheDisplayPolicy() {
        // The view seeds both the draft and the session baseline through
        // KanbanModelOverrideDisplayPolicy.override(for:); the tests below
        // seed raw TaskModelOverride(task:). Pin their equality so the two
        // can never drift apart silently.
        let serverTask = makeTask(id: "t1", extra: [
            "model_override": "model-a",
            "provider_override": "prov-a",
            "reasoning_effort": "high"
        ])
        XCTAssertEqual(
            KanbanModelOverrideDisplayPolicy.override(for: serverTask),
            TaskModelOverride(task: serverTask)
        )
    }

    func testModelSheetNoEditDismissNeverOverwritesConcurrentServerChange() {
        let serverAtOpen = makeTask(id: "t1", extra: ["model_override": "model-a"])
        let session = KanbanModelOverrideSession(
            taskID: "t1",
            baseline: TaskModelOverride(task: serverAtOpen)
        )
        // The user opened the editor and made NO changes.
        let untouchedDraft = TaskModelOverride(task: serverAtOpen)

        // While the sheet stayed open, the server moved to B.
        let serverNow = makeTask(id: "t1", extra: ["model_override": "model-b"])
        // Precondition of the OLD bug: draft != current server would have
        // been misread as "the user edited" and PATCHed A back over B.
        XCTAssertNotEqual(untouchedDraft, TaskModelOverride(task: serverNow))

        // The session baseline says the user never edited: no write at all,
        // so B remains authoritative and zero PATCH requests are made.
        XCTAssertEqual(
            KanbanModelOverrideSessionPolicy.dismissalOutcome(
                session: session,
                draft: untouchedDraft,
                displayedTaskID: "t1"
            ),
            .noWrite
        )
    }

    func testModelSheetUserEditCommitsDiffedAgainstCurrentServer() {
        let serverAtOpen = makeTask(id: "t1", extra: ["model_override": "model-a"])
        let session = KanbanModelOverrideSession(
            taskID: "t1",
            baseline: TaskModelOverride(task: serverAtOpen)
        )
        // The user deliberately edited the draft to C.
        let edited = TaskModelOverride(model: "model-c")

        // And the server moved to B while the sheet was open.
        let serverNow = makeTask(id: "t1", extra: [
            "model_override": "model-b",
            "provider_override": "prov-b"
        ])

        // The user's edit IS committed...
        XCTAssertEqual(
            KanbanModelOverrideSessionPolicy.dismissalOutcome(
                session: session,
                draft: edited,
                displayedTaskID: "t1"
            ),
            .commit(edited)
        )

        // ...and the wire mutation is diffed against the CURRENT server B
        // (not the open-time baseline): model set to C, no spurious clears.
        let patch = TaskModelOverride.patch(from: serverNow, to: edited)
        XCTAssertEqual(patch.modelOverride, "model-c")
        XCTAssertFalse(patch.clearModelOverride)
        XCTAssertNil(patch.providerOverride, "provider is sent only when explicitly chosen (desktop parity)")

        // Explicit-clear semantics survive: editing to INHERIT clears the
        // server's B override through the dedicated clear flag.
        let inheritPatch = TaskModelOverride.patch(from: serverNow, to: TaskModelOverride())
        XCTAssertTrue(inheritPatch.clearModelOverride)
        XCTAssertFalse(inheritPatch.clearReasoningEffort)
    }

    func testModelSheetSessionNeverCommitsForAnotherTaskIdentity() {
        let serverA = makeTask(id: "task-a", extra: ["model_override": "model-a"])
        let session = KanbanModelOverrideSession(
            taskID: "task-a",
            baseline: TaskModelOverride(task: serverA)
        )
        let edited = TaskModelOverride(model: "model-c")

        // Dependency navigation replaced the displayed identity: the old
        // session must not PATCH either A or B.
        XCTAssertEqual(
            KanbanModelOverrideSessionPolicy.dismissalOutcome(
                session: session,
                draft: edited,
                displayedTaskID: "task-b"
            ),
            .noWrite
        )

        // A missing session (never opened, or reset by navigation) writes
        // nothing either.
        XCTAssertEqual(
            KanbanModelOverrideSessionPolicy.dismissalOutcome(
                session: nil,
                draft: edited,
                displayedTaskID: "task-a"
            ),
            .noWrite
        )
    }

    // MARK: - 8. Note & requeue partial success

    func testNotePostedThenRequeueFailedIsExplicitPartialSuccess() async throws {
        var events: [String] = []
        var commentPostCount = 0

        let outcome = await KanbanNoteAndRequeueFlow.perform(
            text: "check the logs",
            postComment: { _ in
                commentPostCount += 1
                events.append("comment-post")
            },
            reclaim: {
                events.append("reclaim-attempt")
                throw CorrectnessTestError.failed("reclaim exploded")
            },
            onCommentPosted: { events.append("draft-cleared") }
        )

        XCTAssertTrue(outcome.commentPosted)
        XCTAssertFalse(outcome.requeued)
        XCTAssertEqual(commentPostCount, 1, "a failed reclaim must never cause a second comment POST")
        XCTAssertEqual(
            events,
            ["comment-post", "draft-cleared", "reclaim-attempt"],
            "strict order IS the contract: the draft is consumed the moment the note reaches the server and BEFORE the reclaim attempt, so a reclaim failure can never hide whether the note posted"
        )
        let message = try XCTUnwrap(KanbanNoteAndRequeueFlow.message(for: outcome))
        XCTAssertTrue(message.contains("note was posted"), message)
        XCTAssertTrue(message.contains("could not be requeued"), message)
        XCTAssertTrue(message.contains("reclaim exploded"), message)
    }

    func testNoteFailureKeepsDraftAndSurfacesPlainError() async {
        var draftCleared = false
        let outcome = await KanbanNoteAndRequeueFlow.perform(
            text: "note",
            postComment: { _ in throw CorrectnessTestError.failed("comment 500") },
            reclaim: { XCTFail("reclaim must not be attempted when the comment failed") },
            onCommentPosted: { draftCleared = true }
        )
        XCTAssertFalse(outcome.commentPosted)
        XCTAssertFalse(outcome.requeued)
        XCTAssertFalse(draftCleared, "a failed POST keeps the draft so the user can retry")
        XCTAssertEqual(KanbanNoteAndRequeueFlow.message(for: outcome), "comment 500")
    }

    func testNoteAndRequeueFullSuccessClearsDraftAndReportsNothing() async {
        var postedBody: String?
        var draftCleared = false
        let outcome = await KanbanNoteAndRequeueFlow.perform(
            text: "note",
            postComment: { body in postedBody = body },
            reclaim: { },
            onCommentPosted: { draftCleared = true }
        )
        XCTAssertEqual(postedBody, "note")
        XCTAssertTrue(outcome.commentPosted)
        XCTAssertTrue(outcome.requeued)
        XCTAssertTrue(draftCleared)
        XCTAssertNil(KanbanNoteAndRequeueFlow.message(for: outcome))
    }

    // MARK: - 9. Worker-log cached content on refresh failure

    func testWorkerLogInitialFailureShowsFullUnavailableState() {
        // Nothing cached + load failed → full unavailable state.
        XCTAssertEqual(
            KanbanWorkerLogPresentation.resolve(log: nil, loadError: "boom", refreshError: nil),
            .unavailable("boom")
        )
        // Nothing cached, still loading (no error yet) → loading state.
        XCTAssertEqual(
            KanbanWorkerLogPresentation.resolve(log: nil, loadError: nil, refreshError: nil),
            .loading
        )
    }

    func testWorkerLogRefreshFailurePreservesCachedContent() {
        let cached = KanbanWorkerLog(exists: true, sizeBytes: 12, content: "hello world", truncated: false)
        // Refresh failed WITH a cached log: the cache stays visible with a
        // non-destructive banner — the load error must NOT evict it.
        XCTAssertEqual(
            KanbanWorkerLogPresentation.resolve(log: cached, loadError: "refresh boom", refreshError: "refresh boom"),
            .content(log: cached, refreshError: "refresh boom")
        )
        // Documented precedence: cached CONTENT always outranks a (possibly
        // stale) loadError — only the dedicated refresh banner channel may
        // carry a failure while a log is cached.
        XCTAssertEqual(
            KanbanWorkerLogPresentation.resolve(log: cached, loadError: "stale load error", refreshError: nil),
            .content(log: cached, refreshError: nil)
        )
    }

    func testWorkerLogSuccessfulRefreshClearsTheBanner() {
        let fresh = KanbanWorkerLog(exists: true, sizeBytes: 9, content: "fresh log", truncated: false)
        XCTAssertEqual(
            KanbanWorkerLogPresentation.resolve(log: fresh, loadError: nil, refreshError: nil),
            .content(log: fresh, refreshError: nil)
        )
    }
}

// MARK: - Card-delete context-race doubles

@MainActor
private final class ContextRaceMockRequester: DashboardJSONRequester {
    struct Call {
        let path: String
        let method: String
        let body: [String: Any]?
    }

    var responsesByPath: [String: [String: Any]]
    var errorsByPath: [String: Error] = [:]
    var calls: [Call] = []

    init(responsesByPath: [String: [String: Any]] = [:]) {
        self.responsesByPath = responsesByPath
    }

    func requestJSON(path: String, method: String, body: [String: Any]?, timeoutMilliseconds: Int, maxResponseBytes: Int) async throws -> [String: Any] {
        calls.append(Call(path: path, method: method, body: body))
        let basePath = path.components(separatedBy: "?").first ?? path
        if let error = errorsByPath[path] ?? errorsByPath[basePath] { throw error }
        if let response = responsesByPath[path] ?? responsesByPath[basePath] { return response }
        return [:]
    }
}

private func contextRaceResponses(boardSlug: String) -> [String: [String: Any]] {
    [
        "/api/plugins/kanban/boards": [
            "boards": [
                ["slug": boardSlug, "name": boardSlug, "is_current": true],
                ["slug": "beta", "name": "Beta", "is_current": false]
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
