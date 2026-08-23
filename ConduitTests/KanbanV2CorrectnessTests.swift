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

        // Both card entry points (ellipsis menu and context menu) route
        // through the staging request: never the destructive mutation.
        let staged = KanbanCardDeletePolicy.cardRequestedDelete(for: task)
        XCTAssertEqual(staged, .confirm(task))
        if case .perform = staged {
            XCTFail("a card action must never issue the destructive DELETE directly")
        }

        // Only an explicit confirmation resolves to the destructive request.
        XCTAssertEqual(KanbanCardDeletePolicy.confirmed(staged: task), .perform(task))
        XCTAssertEqual(KanbanCardDeletePolicy.cancelled(), .none)
        XCTAssertEqual(KanbanCardDeletePolicy.confirmed(staged: nil), .none)
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
