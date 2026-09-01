import Combine
import XCTest
@testable import Conduit

/// Live reasoning must publish through the same display-cadence discipline as
/// assistant streaming: raw gateway deltas merge into an authoritative buffer
/// immediately, but the UI only republishes at a coalesced cadence so an
/// expanded ThinkingCard cannot saturate main-actor layout work (0x8BADF00D
/// scene-update watchdog during active reasoning streams).
///
/// The live card renders from the published PROJECTION
/// (`liveReasoningSegment`) and never mutates the settled `messages` array
/// while streaming — per-publish transcript mutation is O(message count) in a
/// deep agent session. Settled `.reasoning` rows appear exactly once per
/// segment, committed at semantic boundaries (tool cards, completion, error,
/// interruption, new turn).
@MainActor
final class AppStateReasoningStreamTests: XCTestCase {

    // MARK: - Harness

    private func makeAppState(
        lifecycleOperations: ChatResumeLifecycleOperations = .live
    ) -> AppState {
        let suite = "AppStateReasoningStreamTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppState(
            defaults: defaults,
            loadSavedConnection: false,
            chatResumeLifecycleOperations: lifecycleOperations
        )
    }

    private func installActiveSession(_ state: AppState, id: String) {
        let summary = SessionSummary(
            id: id,
            alternateIds: [],
            title: id,
            model: "Hermes",
            updatedLabel: "now",
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
        state.sessions = [summary]
        state.activeSessionId = id
    }

    /// The sidebar drawer suppresses streaming publications while open and
    /// force-publishes the authoritative buffers when it closes. Toggling it
    /// gives tests a synchronous flush without sleeping on the publish cadence.
    /// The flush targets the live projection only — the segment keeps
    /// streaming; only boundaries commit it into the transcript.
    private func forceFlushPendingReasoning(on state: AppState) {
        state.showSidebar = true
        state.showSidebar = false
    }

    private func feedReasoning(
        _ chunks: [String],
        sessionId: String,
        state: AppState
    ) {
        chunks.forEach {
            state.handleStreamEvent(.reasoningDelta(sessionId: sessionId, text: $0))
        }
    }

    private func reasoningCards(in state: AppState) -> [ChatMessage] {
        state.messages.filter { $0.role == .reasoning }
    }

    /// Live reasoning content as the UI sees it (the projection), independent
    /// of the settled transcript.
    private func liveReasoningContent(on state: AppState) -> String? {
        state.liveReasoningSegment?.content
    }

    // MARK: - Coalescing

    func testRapidReasoningDeltasCoalesceTranscriptPublications() {
        let state = makeAppState()
        installActiveSession(state, id: "stored-a")
        let chunks = (0..<75).map { "reasoning-line-\($0) " }
        let expectedTotal = chunks.joined()

        var burstPublications = 0
        let cancellable = state.$messages.dropFirst().sink { _ in burstPublications += 1 }
        feedReasoning(chunks, sessionId: "stored-a", state: state)
        cancellable.cancel()

        // Zero transcript publications: the live card mounts in the
        // projection, and every raw delta after that merges into the
        // authoritative buffer without touching `messages` at all.
        XCTAssertEqual(burstPublications, 0)
        XCTAssertEqual(reasoningCards(in: state).count, 0)
        XCTAssertEqual(liveReasoningContent(on: state), chunks.first)

        forceFlushPendingReasoning(on: state)
        XCTAssertEqual(liveReasoningContent(on: state), expectedTotal)
        XCTAssertEqual(reasoningCards(in: state).count, 0)
    }

    func testScheduledReasoningPublishFiresWithoutForcedFlush() async throws {
        let state = makeAppState()
        installActiveSession(state, id: "stored-a")

        feedReasoning(
            ["coalesced chunk one ", "coalesced chunk two"],
            sessionId: "stored-a",
            state: state
        )
        XCTAssertEqual(liveReasoningContent(on: state), "coalesced chunk one ")

        // The scheduled 50 ms publish must land on its own — no sidebar
        // force-flush, no boundary event. The wait only needs to clear the
        // cadence interval, so generous slack keeps it stable on CI runners.
        var scheduledTranscriptPublications = 0
        let cancellable = state.$messages.dropFirst().sink { _ in
            scheduledTranscriptPublications += 1
        }
        try await Task.sleep(for: .milliseconds(500))
        cancellable.cancel()
        XCTAssertEqual(
            liveReasoningContent(on: state),
            "coalesced chunk one coalesced chunk two"
        )
        XCTAssertEqual(
            scheduledTranscriptPublications, 0,
            "the scheduled reasoning publish must not touch the settled transcript"
        )
    }

    func testReasoningCardIdentityIsStableAcrossCoalescedPublications() {
        let state = makeAppState()
        installActiveSession(state, id: "stored-a")

        feedReasoning(["first segment "], sessionId: "stored-a", state: state)
        forceFlushPendingReasoning(on: state)
        let firstCardID = state.liveReasoningSegment?.id

        feedReasoning(["continues to stream "], sessionId: "stored-a", state: state)
        forceFlushPendingReasoning(on: state)

        // One live card for the whole segment, stable identity, still outside
        // the settled transcript.
        XCTAssertEqual(reasoningCards(in: state).count, 0)
        XCTAssertEqual(state.liveReasoningSegment?.id, firstCardID)
        XCTAssertEqual(
            liveReasoningContent(on: state),
            "first segment continues to stream "
        )
    }

    // MARK: - Gateway delta shapes

    func testCumulativeReasoningSnapshotsDoNotDuplicate() {
        let state = makeAppState()
        installActiveSession(state, id: "stored-a")

        feedReasoning(
            ["abc", "abcdef", "abcdefgh"],
            sessionId: "stored-a",
            state: state
        )
        forceFlushPendingReasoning(on: state)

        XCTAssertEqual(liveReasoningContent(on: state), "abcdefgh")
    }

    func testIncrementalReasoningDeltasConcatenateExactly() {
        let state = makeAppState()
        installActiveSession(state, id: "stored-a")

        feedReasoning(["abc", "def", "ghi"], sessionId: "stored-a", state: state)
        forceFlushPendingReasoning(on: state)

        XCTAssertEqual(liveReasoningContent(on: state), "abcdefghi")
    }

    // MARK: - Boundary commits

    func testMessageCompleteFlushesPendingReasoningSynchronously() {
        let state = makeAppState()
        installActiveSession(state, id: "stored-a")

        feedReasoning(
            ["partial thought ", "still buffering"],
            sessionId: "stored-a",
            state: state
        )
        state.handleStreamEvent(
            .messageComplete(
                sessionId: "stored-a",
                messageId: "assistant-1",
                content: "Final answer",
                reasoning: nil
            )
        )

        // The boundary commits the live segment into the settled transcript.
        XCTAssertEqual(
            reasoningCards(in: state).first?.content,
            "partial thought still buffering"
        )
        XCTAssertNil(state.liveReasoningSegment)

        // Force the drained completion so the final assistant message lands
        // synchronously; the reasoning card must stay complete and ordered
        // before it.
        state.handleStreamEvent(.messageStart(sessionId: "stored-a"))
        guard let reasoningIndex = state.messages.firstIndex(where: { $0.role == .reasoning }),
              let assistantIndex = state.messages.firstIndex(where: { $0.id == "assistant-1" })
        else {
            return XCTFail("Expected finalized reasoning card and assistant message")
        }
        XCTAssertEqual(state.messages[reasoningIndex].content, "partial thought still buffering")
        XCTAssertLessThan(reasoningIndex, assistantIndex)
    }

    func testToolStartFlushesPendingReasoningAndPreservesOrdering() {
        let state = makeAppState()
        installActiveSession(state, id: "stored-a")

        feedReasoning(
            ["deciding which file to inspect ", "before the tool runs"],
            sessionId: "stored-a",
            state: state
        )
        state.handleStreamEvent(
            .toolStart(sessionId: "stored-a", toolName: "read_file", toolInput: nil)
        )

        XCTAssertEqual(
            reasoningCards(in: state).first?.content,
            "deciding which file to inspect before the tool runs"
        )
        XCTAssertEqual(state.messages.last?.role, .tool)
        guard let reasoningIndex = state.messages.firstIndex(where: { $0.role == .reasoning }),
              let toolIndex = state.messages.firstIndex(where: { $0.role == .tool })
        else {
            return XCTFail("Expected reasoning card followed by tool card")
        }
        XCTAssertLessThan(reasoningIndex, toolIndex)

        // Reasoning that resumes after a tool belongs to a fresh live card,
        // never the finalized one.
        feedReasoning(["post-tool thinking "], sessionId: "stored-a", state: state)
        forceFlushPendingReasoning(on: state)
        XCTAssertEqual(reasoningCards(in: state).count, 1)
        XCTAssertEqual(liveReasoningContent(on: state), "post-tool thinking ")
    }

    func testMessageErrorFlushesPendingReasoningWithoutStaleDelayedPublish() async throws {
        let state = makeAppState()
        installActiveSession(state, id: "stored-a")

        // Two chunks guarantee a coalesced publish is actually pending when
        // the boundary arrives; one chunk would mount the card fully and
        // make the flush assertion trivially pass.
        feedReasoning(
            ["mid-flight reasoning ", "still open"],
            sessionId: "stored-a",
            state: state
        )
        state.handleStreamEvent(
            .messageError(sessionId: "stored-a", message: "gateway exploded")
        )

        XCTAssertEqual(
            reasoningCards(in: state).first?.content,
            "mid-flight reasoning still open"
        )
        XCTAssertEqual(state.errorMessage, "gateway exploded")

        // No coalesced publish may fire after the boundary: not the
        // transcript equality, and not even a single republication.
        var postBoundaryPublications = 0
        let cancellable = state.$messages.dropFirst().sink { _ in
            postBoundaryPublications += 1
        }
        try await Task.sleep(for: .milliseconds(250))
        cancellable.cancel()
        XCTAssertEqual(postBoundaryPublications, 0)
        XCTAssertEqual(
            reasoningCards(in: state).first?.content,
            "mid-flight reasoning still open"
        )
    }

    func testMessageInterruptedFlushesPendingReasoningWithoutStaleDelayedPublish() async throws {
        let state = makeAppState()
        installActiveSession(state, id: "stored-a")

        feedReasoning(
            ["about to be ", "interrupted"],
            sessionId: "stored-a",
            state: state
        )
        state.handleStreamEvent(.messageInterrupted(sessionId: "stored-a"))

        XCTAssertEqual(
            reasoningCards(in: state).first?.content,
            "about to be interrupted"
        )

        var postBoundaryPublications = 0
        let cancellable = state.$messages.dropFirst().sink { _ in
            postBoundaryPublications += 1
        }
        try await Task.sleep(for: .milliseconds(250))
        cancellable.cancel()
        XCTAssertEqual(postBoundaryPublications, 0)
        XCTAssertEqual(
            reasoningCards(in: state).first?.content,
            "about to be interrupted"
        )
    }

    func testShowSidebarSuppressesReasoningPublishUntilClosed() {
        let state = makeAppState()
        installActiveSession(state, id: "stored-a")

        feedReasoning(["visible "], sessionId: "stored-a", state: state)
        XCTAssertEqual(liveReasoningContent(on: state), "visible ")

        // The drawer suppresses coalesced reasoning publications while it is
        // animating; the buffer stays authoritative.
        state.showSidebar = true
        feedReasoning(["hidden ", "while draining"], sessionId: "stored-a", state: state)
        XCTAssertEqual(liveReasoningContent(on: state), "visible ")

        state.showSidebar = false
        XCTAssertEqual(
            liveReasoningContent(on: state),
            "visible hidden while draining"
        )
        // The suppression flush publishes the projection; it must not commit
        // the still-streaming segment into the transcript.
        XCTAssertEqual(reasoningCards(in: state).count, 0)
    }

    func testReasoningDeltaDuringCompletionDrainMountsFreshCardAfterAssistant() {
        let state = makeAppState()
        installActiveSession(state, id: "stored-a")

        feedReasoning(["pre-complete "], sessionId: "stored-a", state: state)
        state.handleStreamEvent(
            .messageComplete(
                sessionId: "stored-a",
                messageId: "assistant-1",
                content: "Final answer",
                reasoning: nil
            )
        )
        // A delta racing the drain window finalizes the pending completion
        // first, then mounts a fresh live card — the pre-projection behavior,
        // with no buffered text lost. The fresh segment stays in the
        // projection until its own boundary.
        state.handleStreamEvent(
            .reasoningDelta(sessionId: "stored-a", text: "late thought")
        )

        XCTAssertEqual(state.messages.map(\.role), [.reasoning, .assistant])
        XCTAssertEqual(liveReasoningContent(on: state), "late thought")

        // The next turn boundary commits the late segment in order.
        state.handleStreamEvent(.messageStart(sessionId: "stored-a"))
        XCTAssertEqual(state.messages.map(\.role), [.reasoning, .assistant, .reasoning])
        XCTAssertEqual(state.messages.last?.content, "late thought")
    }

    func testCompletionReasoningTraceDoesNotDuplicateStreamedCard() {
        let state = makeAppState()
        installActiveSession(state, id: "stored-a")

        feedReasoning(
            ["streamed so far ", "still streaming"],
            sessionId: "stored-a",
            state: state
        )
        state.handleStreamEvent(
            .messageComplete(
                sessionId: "stored-a",
                messageId: "assistant-1",
                content: "Final answer",
                reasoning: "full trace"
            )
        )
        state.handleStreamEvent(.messageStart(sessionId: "stored-a"))

        // Completion repeating the trace after streamed reasoning keeps the
        // streamed card; it must not append a duplicate thinking box.
        XCTAssertEqual(reasoningCards(in: state).count, 1)
        XCTAssertEqual(
            reasoningCards(in: state).first?.content,
            "streamed so far still streaming"
        )
    }

    func testCompletionOnlyReasoningSurvivesFullReasoningStateReset() {
        let state = makeAppState()
        installActiveSession(state, id: "stored-a")

        // Turn one streamed reasoning: receivedReasoningForCurrentTurn == true.
        feedReasoning(["prior turn reasoning "], sessionId: "stored-a", state: state)
        state.handleStreamEvent(.messageStart(sessionId: "stored-a"))
        XCTAssertEqual(reasoningCards(in: state).count, 1)

        // A full state reset (disconnect) must restore the ENTIRE per-turn
        // reasoning state machine — a stale turn flag would make the next
        // session's completion-carried reasoning look already-streamed and
        // silently discard it.
        state.disconnect()
        installActiveSession(state, id: "stored-b")

        state.handleStreamEvent(
            .messageComplete(
                sessionId: "stored-b",
                messageId: "assistant-b",
                content: "Answer",
                reasoning: "completion-only reasoning"
            )
        )
        // Force the drained completion synchronously.
        state.handleStreamEvent(.messageStart(sessionId: "stored-b"))

        let cards = reasoningCards(in: state)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.content, "completion-only reasoning")
        XCTAssertFalse(
            state.messages.contains { $0.content.contains("prior turn") },
            "Session A reasoning must not leak into session B's transcript"
        )
    }

    func testToolBoundaryDoesNotEraseTurnReasoningFlagAtCompletion() {
        let state = makeAppState()
        installActiveSession(state, id: "stored-a")

        feedReasoning(["pre-tool reasoning"], sessionId: "stored-a", state: state)
        state.handleStreamEvent(
            .toolStart(sessionId: "stored-a", toolName: "read_file", toolInput: nil)
        )
        state.handleStreamEvent(
            .toolComplete(sessionId: "stored-a", toolName: "read_file", toolOutput: "result")
        )
        state.handleStreamEvent(
            .messageComplete(
                sessionId: "stored-a",
                messageId: "assistant-1",
                content: "Final answer",
                reasoning: "full completion trace"
            )
        )
        // Force the drained completion synchronously.
        state.handleStreamEvent(.messageStart(sessionId: "stored-a"))

        // A tool boundary ends the reasoning SEGMENT, not the turn: reasoning
        // streamed before the tool still counts as this turn's reasoning, so
        // the completion-carried trace must not mount a duplicate card.
        let cards = reasoningCards(in: state)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.content, "pre-tool reasoning")

        guard let reasoningIndex = state.messages.firstIndex(where: { $0.role == .reasoning }),
              let toolIndex = state.messages.firstIndex(where: { $0.role == .tool }),
              let assistantIndex = state.messages.firstIndex(where: { $0.id == "assistant-1" })
        else {
            return XCTFail("Expected reasoning, tool, and assistant messages")
        }
        XCTAssertLessThan(reasoningIndex, toolIndex)
        XCTAssertLessThan(toolIndex, assistantIndex)
        XCTAssertEqual(state.messages[assistantIndex].content, "Final answer")
        XCTAssertEqual(state.messages[toolIndex].tool?.status, .complete)
    }

    func testMultiSegmentTurnKeepsBothSegmentsAndSkipsCompletionTrace() {
        let state = makeAppState()
        installActiveSession(state, id: "stored-a")

        // Two reasoning segments separated by tools inside ONE turn. Both
        // segment cards must survive to completion, and the completion-carried
        // trace must not append a third.
        feedReasoning(["first segment "], sessionId: "stored-a", state: state)
        state.handleStreamEvent(
            .toolStart(sessionId: "stored-a", toolName: "read_file", toolInput: nil)
        )
        feedReasoning(["second segment"], sessionId: "stored-a", state: state)
        state.handleStreamEvent(
            .toolComplete(sessionId: "stored-a", toolName: "read_file", toolOutput: "result")
        )
        state.handleStreamEvent(
            .messageComplete(
                sessionId: "stored-a",
                messageId: "assistant-1",
                content: "Final answer",
                reasoning: "full completion trace"
            )
        )
        state.handleStreamEvent(.messageStart(sessionId: "stored-a"))

        let cards = reasoningCards(in: state)
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards.first?.content, "first segment ")
        XCTAssertEqual(cards.last?.content, "second segment")
        XCTAssertEqual(state.messages.last?.id, "assistant-1")
    }

    /// Mid-turn transcript rows (review summaries, clarify/approval cards,
    /// slash output, steer corrections) must not land below the live
    /// reasoning card's eventual commit: each append settles the segment
    /// first, preserving the pre-projection chronology, and reasoning that
    /// resumes afterwards mounts a fresh segment (tool-boundary precedent).
    func testMidTurnTranscriptAppendsCommitReasoningSegmentFirst() {
        let state = makeAppState()
        installActiveSession(state, id: "stored-a")

        feedReasoning(["thinking about the change "], sessionId: "stored-a", state: state)
        state.handleStreamEvent(.reviewSummary(
            sessionId: "stored-a",
            activity: ReviewActivity(summary: "mid-turn review", details: nil, fullSessionId: nil)
        ))

        // The live card committed above the review row; nothing stays live.
        XCTAssertEqual(state.messages.map(\.role), [.reasoning, .system])
        XCTAssertEqual(state.messages.first?.content, "thinking about the change ")
        XCTAssertNil(state.liveReasoningSegment)

        // Reasoning that resumes after the interjection mounts a FRESH
        // segment, which the next mid-turn append commits the same way.
        feedReasoning(["second segment "], sessionId: "stored-a", state: state)
        state.handleStreamEvent(.approval(
            sessionId: "stored-a",
            activity: ApprovalActivity(
                sessionId: "stored-a",
                command: "run tests",
                description: "wants to run tests",
                choices: nil,
                allowPermanent: false,
                smartDenied: false,
                status: .pending,
                choice: nil,
                error: nil
            )
        ))
        XCTAssertEqual(state.messages.map(\.role), [.reasoning, .system, .reasoning, .approval])
        XCTAssertEqual(state.messages[2].content, "second segment ")

        feedReasoning(["third segment"], sessionId: "stored-a", state: state)
        state.handleStreamEvent(.clarify(
            sessionId: "stored-a",
            requestId: "req-1",
            question: "which scope?",
            choices: [("a", "A"), ("b", "B")]
        ))
        XCTAssertEqual(
            state.messages.map(\.role),
            [.reasoning, .system, .reasoning, .approval, .reasoning, .clarify]
        )
        XCTAssertEqual(state.messages[4].content, "third segment")
        XCTAssertNil(state.liveReasoningSegment)
    }

    func testSessionSwitchDiscardsPendingReasoningPublishForNewSession() async {
        let replacementMessages = [
            ChatMessage(id: "new-1", role: .assistant, content: "Other session", timestamp: "1")
        ]
        let state = makeAppState(lifecycleOperations: ChatResumeLifecycleOperations(
            openSession: { _, sessionID, _ in
                SessionResumeResult(
                    sessionId: sessionID,
                    messages: replacementMessages,
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in }
        ))
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        state.connection = connection
        state.client = HermesClient(connection: connection, profile: "default")
        let origin = SessionSummary(
            id: "stored-a",
            alternateIds: [],
            title: "stored-a",
            model: "Hermes",
            updatedLabel: "now",
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
        let destination = SessionSummary(
            id: "stored-b",
            alternateIds: [],
            title: "stored-b",
            model: "Hermes",
            updatedLabel: "now",
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
        state.sessions = [origin, destination]
        state.activeSessionId = origin.id

        feedReasoning(
            ["stale reasoning ", "that must not leak"],
            sessionId: origin.id,
            state: state
        )
        let opened = await state.openSession(destination.id)
        XCTAssertTrue(opened)

        XCTAssertEqual(state.activeSessionId, destination.id)
        XCTAssertTrue(reasoningCards(in: state).isEmpty)
        XCTAssertNil(state.liveReasoningSegment)
        XCTAssertEqual(state.messages, replacementMessages)

        // Even a forced flush of any surviving pending state must not
        // reproduce the old session's reasoning inside the new transcript.
        forceFlushPendingReasoning(on: state)
        XCTAssertTrue(reasoningCards(in: state).isEmpty)
        XCTAssertNil(state.liveReasoningSegment)
        XCTAssertEqual(state.messages, replacementMessages)

        // Five 50 ms cadence periods: proves that after the session switch no
        // stale publish (guarded or not) can mutate the replacement transcript.
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(reasoningCards(in: state).isEmpty)
        XCTAssertNil(state.liveReasoningSegment)
        XCTAssertEqual(state.messages, replacementMessages)
    }
}
