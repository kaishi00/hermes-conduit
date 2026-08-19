import Combine
import XCTest
@testable import Conduit

/// Live reasoning must publish through the same display-cadence discipline as
/// assistant streaming: raw gateway deltas merge into an authoritative buffer
/// immediately, but the published transcript only republishes at a coalesced
/// cadence so an expanded ThinkingCard cannot saturate main-actor layout work
/// (0x8BADF00D scene-update watchdog during active reasoning streams).
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

        // One publication creates the thinking card; every raw delta after
        // that must merge into the authoritative buffer without republishing.
        XCTAssertEqual(burstPublications, 1)
        XCTAssertEqual(reasoningCards(in: state).count, 1)
        XCTAssertEqual(reasoningCards(in: state).first?.content, chunks.first)

        forceFlushPendingReasoning(on: state)
        XCTAssertEqual(reasoningCards(in: state).first?.content, expectedTotal)
    }

    func testScheduledReasoningPublishFiresWithoutForcedFlush() async throws {
        let state = makeAppState()
        installActiveSession(state, id: "stored-a")

        feedReasoning(
            ["coalesced chunk one ", "coalesced chunk two"],
            sessionId: "stored-a",
            state: state
        )
        XCTAssertEqual(reasoningCards(in: state).first?.content, "coalesced chunk one ")

        // The scheduled 50 ms publish must land on its own — no sidebar
        // force-flush, no boundary event. The wait only needs to clear the
        // cadence interval, so generous slack keeps it stable on CI runners.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(
            reasoningCards(in: state).first?.content,
            "coalesced chunk one coalesced chunk two"
        )
    }

    func testReasoningCardIdentityIsStableAcrossCoalescedPublications() {
        let state = makeAppState()
        installActiveSession(state, id: "stored-a")

        feedReasoning(["first segment "], sessionId: "stored-a", state: state)
        forceFlushPendingReasoning(on: state)
        let firstCardID = reasoningCards(in: state).first?.id

        feedReasoning(["continues to stream "], sessionId: "stored-a", state: state)
        forceFlushPendingReasoning(on: state)

        XCTAssertEqual(reasoningCards(in: state).count, 1)
        XCTAssertEqual(reasoningCards(in: state).first?.id, firstCardID)
        XCTAssertEqual(
            reasoningCards(in: state).first?.content,
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

        XCTAssertEqual(reasoningCards(in: state).first?.content, "abcdefgh")
    }

    func testIncrementalReasoningDeltasConcatenateExactly() {
        let state = makeAppState()
        installActiveSession(state, id: "stored-a")

        feedReasoning(["abc", "def", "ghi"], sessionId: "stored-a", state: state)
        forceFlushPendingReasoning(on: state)

        XCTAssertEqual(reasoningCards(in: state).first?.content, "abcdefghi")
    }

    // MARK: - Boundary flushes

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

        XCTAssertEqual(
            reasoningCards(in: state).first?.content,
            "partial thought still buffering"
        )

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

        // Reasoning that resumes after a tool belongs to a fresh card, never
        // the finalized one.
        feedReasoning(["post-tool thinking "], sessionId: "stored-a", state: state)
        forceFlushPendingReasoning(on: state)
        XCTAssertEqual(reasoningCards(in: state).count, 2)
        XCTAssertEqual(reasoningCards(in: state).last?.content, "post-tool thinking ")
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
        XCTAssertEqual(reasoningCards(in: state).first?.content, "visible ")

        // The drawer suppresses coalesced reasoning publications while it is
        // animating; the buffer stays authoritative.
        state.showSidebar = true
        feedReasoning(["hidden ", "while draining"], sessionId: "stored-a", state: state)
        XCTAssertEqual(reasoningCards(in: state).first?.content, "visible ")

        state.showSidebar = false
        XCTAssertEqual(
            reasoningCards(in: state).first?.content,
            "visible hidden while draining"
        )
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
        // first, then mounts a fresh card — the pre-fix behavior, with no
        // buffered text lost.
        state.handleStreamEvent(
            .reasoningDelta(sessionId: "stored-a", text: "late thought")
        )

        let cards = reasoningCards(in: state)
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards.first?.content, "pre-complete ")
        XCTAssertEqual(cards.last?.content, "late thought")
        XCTAssertEqual(state.messages.map(\.role), [.reasoning, .assistant, .reasoning])
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

    func testSessionSwitchDiscardsPendingReasoningPublishForNewSession() async {
        let replacementMessages = [
            ChatMessage(id: "new-1", role: .assistant, content: "Other session", timestamp: "1")
        ]
        let state = makeAppState(lifecycleOperations: ChatResumeLifecycleOperations(
            openSession: { _, sessionID in
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
        XCTAssertEqual(state.messages, replacementMessages)

        // Even a forced flush of any surviving pending state must not
        // reproduce the old session's reasoning inside the new transcript.
        forceFlushPendingReasoning(on: state)
        XCTAssertTrue(reasoningCards(in: state).isEmpty)
        XCTAssertEqual(state.messages, replacementMessages)
    }
}
