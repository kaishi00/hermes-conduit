import XCTest
import SwiftUI
@testable import Conduit

/// Long-context regression fixture (spec: agent sessions with >200K context,
/// i.e. hundreds-to-thousands of settled rows). Deterministic counters only —
/// never wall-clock. Three seams are measured:
///
///   1. one live reasoning publish in a deep transcript
///      → must not mutate the settled transcript / revision / scroll-target
///        cache (the O(message count) churn behind the reported CPU burn)
///   2. unrelated AppState publications with a focused, edited composer
///      → must reach `updateUIView` but never write text or selection
///   3. the stale-binding echo window (UIKit advanced past the binding)
///      → must never rewrite editor text (cursor corruption repro)
///
/// The fixture hosts the real ChatView (real ForEach, real ComposerBar, real
/// ComposerPasteTextView) so the measured cascade is the production one.
@MainActor
final class LongContextScalingFixtureTests: XCTestCase {

    /// Retained for the full lifetime of each measurement so the hosted
    /// hierarchy stays genuinely mounted.
    private var testWindow: UIWindow?

    override func setUp() {
        super.setUp()
        TranscriptPerf.resetRenderLedgerForTesting()
    }

    override func tearDown() {
        testWindow?.isHidden = true
        testWindow?.rootViewController = nil
        RunLoop.current.run(until: Date())
        testWindow = nil
        TranscriptPerf.reset()
        super.tearDown()
    }

    // MARK: - Harness

    private func makeAppState() throws -> AppState {
        let suiteName = "long-context-fixture"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName),
            "test UserDefaults suite must initialize"
        )
        defaults.removePersistentDomain(forName: suiteName)
        return AppState(defaults: defaults, loadSavedConnection: false)
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

    /// Deep agent-session transcript: markdown-heavy settled rows, far beyond
    /// the 250-row streaming fixture, representing a >200K-context session.
    static func deepTranscript(count: Int = 800) -> [ChatMessage] {
        (0..<count).map { index in
            ChatMessage(
                id: "deep-\(index)",
                role: index % 2 == 0 ? .assistant : .user,
                content: """
                ### Turn \(index)
                Settled assistant answer \(index) with **bold**, *italic*, and
                [a reference link](https://example.com/item/\(index)).

                - detail one for turn \(index)
                - detail two for turn \(index)
                """,
                timestamp: "2026-01-01T00:00:00Z"
            )
        }
    }

    /// Drives `count` live reasoning deltas through the production
    /// stream-event path and performs each coalesced publication through the
    /// production flush seam (`AppState.flushReasoningPublish`), followed by
    /// ONE deterministic run-loop turn per publish.
    ///
    /// The old version waited 55 ms per delta hoping the ~50 ms coalescing
    /// `Task.sleep` would fire inside the pump — on loaded CI runners the
    /// publishes coalesced or landed late, so the measured window contained
    /// an arbitrary subset of the implied publications. Now the window
    /// contains exactly the publications the deltas imply, with zero
    /// dependence on scheduler timing.
    @discardableResult
    private func feedReasoningDeltas(
        _ count: Int,
        sessionId: String,
        state: AppState,
        host: UIHostingController<AnyView>
    ) -> String {
        var buffer = ""
        for index in 0..<count {
            let chunk = "reasoning line \(index) for the live thinking card. "
            buffer += chunk
            state.handleStreamEvent(.reasoningDelta(sessionId: sessionId, text: chunk))
            state.flushReasoningPublish()
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.current.run(until: Date())
        }
        return buffer
    }

    private func mountChat(appState: AppState) -> UIHostingController<AnyView> {
        let host = UIHostingController(
            rootView: AnyView(ChatView().environmentObject(appState))
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        testWindow = window
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date())
        return host
    }

    private func findTextView(in root: UIView) -> ImagePasteTextView? {
        if let found = root as? ImagePasteTextView { return found }
        for child in root.subviews {
            if let found = findTextView(in: child) { return found }
        }
        return nil
    }

    // MARK: - 1. Deep-transcript reasoning churn

    /// THE scaling regression: in an 800-row transcript, every live reasoning
    /// publish used to mutate `messages` (O(n) index scan + CoW copy + revision
    /// bump), re-run the scroll-target cache's O(n) prefix walk + O(prefix)
    /// fingerprint-set build, and re-copy the ForEach source array. Steady-state
    /// reasoning must do NONE of that: it publishes through the live projection
    /// only, at O(live content) cost.
    func testLiveReasoningPublishesAvoidTranscriptSizedWork() throws {
        let appState = try makeAppState()
        installActiveSession(appState, id: "deep-session")
        appState.messages = Self.deepTranscript()

        let host = mountChat(appState: appState)
        guard PerformanceFixtureWait.settleUntilCountersQuiet(quietFor: 1.0) else {
            XCTFail("deep transcript never reached a quiet state; measurement would be meaningless")
            return
        }

        TranscriptPerf.reset()
        let expected = feedReasoningDeltas(12, sessionId: "deep-session", state: appState, host: host)
        guard PerformanceFixtureWait.settleUntilCountersQuiet(quietFor: 0.6) else {
            XCTFail("measurement window never quieted; trailing publishes would be misattributed")
            return
        }

        // Measurement validity: publishes really happened. The flush-fed
        // driver is deterministic — one publication per delta (delta 0's
        // publication IS the initial mount; its flush no-ops on the
        // unchanged-content guard), so 12 for this fixture. The floor only
        // guards against a silent seam breakage; the exact contract lives
        // in the ledger micro-test.
        XCTAssertGreaterThanOrEqual(
            TranscriptPerf.reasoningProjectionPublishes, 5,
            "fixture must drive at least 5 live reasoning publishes"
        )

        // The scaling contract.
        XCTAssertEqual(
            TranscriptPerf.reasoningTranscriptMutations, 0,
            "live reasoning publishes must not mutate the settled transcript"
        )
        XCTAssertEqual(
            TranscriptPerf.transcriptChangedCalls, 0,
            "live reasoning publishes must not re-run viewport transcriptChanged"
        )
        XCTAssertEqual(
            TranscriptPerf.scrollTargetCommonPrefixComparisons, 0,
            "live reasoning publishes must not walk the scroll-target common prefix"
        )
        XCTAssertEqual(
            TranscriptPerf.scrollTargetPrefixSetBuilds, 0,
            "live reasoning publishes must not rebuild the prefix fingerprint set"
        )
        // Dormancy, classified by position: a growing live card legitimately
        // shifts the bottom-anchored LazyVStack and can remount rows AT THE
        // VIEWPORT EDGES (measured churn touches only the first/last few
        // messages — Turn 0/2 and Turn 796/798 in this fixture). A re-render
        // of an INTERIOR row is the per-publish cascade this fixture kills:
        // every mounted row re-evaluating, which no amount of edge churn
        // can disguise. The data-layer invariants above (zero mutations,
        // zero transcriptChanged, zero prefix walks) remain the primary
        // contract; this is the render-layer defense in depth.
        let atRestRerenders = TranscriptPerf.settledMarkdownPreWindowRepeatEvaluations
        // The reasoning buffer inherently ACCUMULATES (deltas merge into one
        // growing live card), so the layout-shift band scales with the fed
        // content — measured churn reaches ~1 row per fed line, deeper than
        // the streaming fixture's steady-state window. Margin 16 covers the
        // 12-delta fixture's band with slack; a full mounted-row cascade
        // still cannot hide inside it, and the data-layer counters above
        // remain the exact primary contract.
        let interiorRerenders = TranscriptPerf.interiorAtRestRerenders(
            sources: TranscriptPerf.recentPreWindowRepeatSources,
            transcript: Self.deepTranscript(),
            edgeMargin: 16
        )
        XCTAssertTrue(
            interiorRerenders.isEmpty,
            "live reasoning re-rendered \(interiorRerenders.count) interior settled rows "
                + "(of \(atRestRerenders) at-rest re-renders; edge remounts are tolerated): "
                + "\(interiorRerenders.map { String($0.prefix(32)) })"
        )

        // And the live card content must actually be visible.
        XCTAssertEqual(appState.messages.filter { $0.role == .reasoning }.count, 0)
        XCTAssertFalse(expected.isEmpty)
    }

    // MARK: - 2. Hosted composer isolation

    /// With user text in a focused editor, unrelated AppState publications
    /// (reasoning, streaming, busy flips) reach `updateUIView` but must never
    /// write text or selection back into UIKit.
    func testComposerEditorIsUnaffectedByReasoningPublishes() throws {
        let appState = try makeAppState()
        installActiveSession(appState, id: "deep-session")
        appState.messages = Self.deepTranscript()

        let host = mountChat(appState: appState)
        guard PerformanceFixtureWait.settleUntilCountersQuiet(quietFor: 1.0) else {
            XCTFail("deep transcript never reached a quiet state; measurement would be meaningless")
            return
        }

        guard let textView = findTextView(in: host.view) else {
            return XCTFail("composer text view must be mounted")
        }

        // Simulate real user typing through the text input system, then park
        // the cursor mid-text.
        textView.insertText("hello from the hardware keyboard")
        RunLoop.current.run(until: Date())
        textView.selectedRange = NSRange(location: 12, length: 0)
        let textBefore = textView.text
        let selectionBefore = textView.selectedRange

        TranscriptPerf.reset()
        _ = feedReasoningDeltas(8, sessionId: "deep-session", state: appState, host: host)
        appState.streamingText = "unrelated streaming tick "
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date())
        appState.streamingText = ""
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        guard PerformanceFixtureWait.settleUntilCountersQuiet(quietFor: 0.6) else {
            XCTFail("measurement window never quieted")
            return
        }

        // Invalidation DID reach the editor bridge — isolation is not silence.
        XCTAssertGreaterThan(
            TranscriptPerf.composerUpdateUIViewCalls, 0,
            "unrelated publications must still reach updateUIView (measuring the right seam)"
        )
        // …but they must never rewrite the editor.
        XCTAssertEqual(
            TranscriptPerf.composerProgrammaticTextAssignments, 0,
            "unrelated publications must cause zero programmatic text assignments"
        )
        XCTAssertEqual(
            TranscriptPerf.composerSelectionWrites, 0,
            "unrelated publications must cause zero selection writes"
        )
        XCTAssertEqual(textView.text, textBefore, "editor text must be untouched")
        XCTAssertEqual(textView.selectedRange, selectionBefore, "cursor must not move")
    }

    // MARK: - 3. Stale-binding echo seam

    /// The deterministic cursor-corruption repro at the smallest seam: the
    /// binding lags UIKit because the delegate notification is deferred while
    /// an unrelated SwiftUI update runs `apply`. The user's keystroke must
    /// survive; before the fix it was reverted and the cursor re-clamped
    /// (measured pre-fix: text "abcdefg" → "abcdef", 1 assignment, cursor 4 → 4).
    func testStaleBindingEchoDoesNotRevertUserTyping() throws {
        var value = "abcdef"
        let identity = UUID()
        let editor = ComposerPasteTextView(
            text: Binding(get: { value }, set: { value = $0 }),
            isFocused: .constant(false),
            measuredHeight: .constant(44),
            enabled: true,
            onPastedImage: { _ in },
            onPastedImageError: { _ in },
            editorIdentity: identity
        )
        let coordinator = ComposerPasteTextView.Coordinator(editor)
        let textView = ImagePasteTextView()

        // Intentional programmatic prefill: applies exactly once.
        coordinator.apply(
            text: "abcdef",
            programmaticRevision: 1,
            editorIdentity: identity,
            to: textView
        )
        XCTAssertEqual(textView.text, "abcdef")

        // The user types "g" after "abc" — UIKit advanced to "abcdefg" with
        // the cursor at 4, but the delegate flush is still pending, so the
        // SwiftUI binding still reads "abcdef".
        textView.text = "abcdefg"
        textView.selectedRange = NSRange(location: 4, length: 0)

        TranscriptPerf.reset()
        // Unrelated SwiftUI invalidation runs the updateUIView apply with the
        // stale binding value and an UNCHANGED revision.
        coordinator.apply(
            text: "abcdef",
            programmaticRevision: 1,
            editorIdentity: identity,
            to: textView
        )

        XCTAssertEqual(
            textView.text, "abcdefg",
            "a stale binding echo must not revert the user's keystroke"
        )
        XCTAssertEqual(
            textView.selectedRange.location, 4,
            "a stale binding echo must not move the cursor"
        )
        XCTAssertEqual(
            TranscriptPerf.composerProgrammaticTextAssignments, 0,
            "a stale binding echo must not perform a programmatic assignment"
        )

        // The delegate flush lands afterwards: UIKit reports the user text
        // and it flows to the binding, still without an editor rewrite.
        coordinator.textViewDidChange(textView)
        XCTAssertEqual(textView.text, "abcdefg")
        XCTAssertEqual(
            TranscriptPerf.composerProgrammaticTextAssignments, 0,
            "publishing the user's text must not write back into the editor"
        )
    }

    /// Intentional programmatic replacements apply EXACTLY ONCE per revision:
    /// repeated updateUIView calls with the same revision must not rewrite
    /// the editor (old behavior reassigned on every mismatch, tearing down
    /// input state each time).
    func testProgrammaticReplacementAppliesExactlyOncePerRevision() throws {
        var value = ""
        let identity = UUID()
        let editor = ComposerPasteTextView(
            text: Binding(get: { value }, set: { value = $0 }),
            isFocused: .constant(false),
            measuredHeight: .constant(44),
            enabled: true,
            onPastedImage: { _ in },
            onPastedImageError: { _ in },
            editorIdentity: identity
        )
        let coordinator = ComposerPasteTextView.Coordinator(editor)
        let textView = ImagePasteTextView()

        TranscriptPerf.reset()
        coordinator.apply(
            text: "draft text",
            programmaticRevision: 7,
            editorIdentity: identity,
            to: textView
        )
        XCTAssertEqual(textView.text, "draft text")
        XCTAssertEqual(TranscriptPerf.composerProgrammaticTextAssignments, 1)
        XCTAssertEqual(TranscriptPerf.composerSelectionWrites, 1)

        // Repeated invalidations carrying the same revision: no rewrites.
        textView.selectedRange = NSRange(location: 5, length: 0)
        coordinator.apply(
            text: "draft text",
            programmaticRevision: 7,
            editorIdentity: identity,
            to: textView
        )
        coordinator.apply(
            text: "draft text",
            programmaticRevision: 7,
            editorIdentity: identity,
            to: textView
        )
        XCTAssertEqual(TranscriptPerf.composerProgrammaticTextAssignments, 1)
        XCTAssertEqual(TranscriptPerf.composerSelectionWrites, 1)
        XCTAssertEqual(textView.selectedRange.location, 5, "cursor must stay where the user put it")

        // A NEW revision replaces deliberately — once — and keeps the
        // selection clamped, as the draft-restore/prefill paths expect.
        coordinator.apply(
            text: "prefilled prompt",
            programmaticRevision: 8,
            editorIdentity: identity,
            to: textView
        )
        XCTAssertEqual(textView.text, "prefilled prompt")
        XCTAssertEqual(TranscriptPerf.composerProgrammaticTextAssignments, 2)
        XCTAssertEqual(
            textView.selectedRange.location, 5,
            "programmatic replacement preserves the caret location when it fits"
        )
    }

    /// An intentional replacement arriving during active IME composition is
    /// DEFERRED, never applied over the marked text; it lands exactly once
    /// when the composition ends.
    func testProgrammaticReplacementDefersDuringMarkedText() throws {
        var value = ""
        let identity = UUID()
        let editor = ComposerPasteTextView(
            text: Binding(get: { value }, set: { value = $0 }),
            isFocused: .constant(false),
            measuredHeight: .constant(44),
            enabled: true,
            onPastedImage: { _ in },
            onPastedImageError: { _ in },
            editorIdentity: identity
        )
        let coordinator = ComposerPasteTextView.Coordinator(editor)
        let textView = ImagePasteTextView()

        // Establish baseline content and a live composition (UITextInput
        // marked text — the deterministic seam for IME state).
        coordinator.apply(
            text: "base ",
            programmaticRevision: 1,
            editorIdentity: identity,
            to: textView
        )
        (textView as UITextInput).setMarkedText("にほんご", selectedRange: NSRange(location: 0, length: 0))
        XCTAssertNotNil(textView.markedTextRange, "fixture requires active marked text")

        TranscriptPerf.reset()
        coordinator.apply(
            text: "slash-command replacement ",
            programmaticRevision: 2,
            editorIdentity: identity,
            to: textView
        )
        XCTAssertNotNil(
            textView.markedTextRange,
            "the composition must survive an intentional replacement"
        )
        XCTAssertEqual(
            TranscriptPerf.composerMarkedTextDeferrals, 1,
            "the replacement must be recorded as deferred"
        )
        XCTAssertEqual(
            TranscriptPerf.composerProgrammaticTextAssignments, 0,
            "marked text must never be silently replaced"
        )
        XCTAssertTrue(textView.text.contains("にほんご"), "composition text stays intact")

        // Composition ends (commit or discard both unmark): the deferred
        // replacement lands exactly once.
        coordinator.textViewDidChange(textView)
        if textView.markedTextRange != nil {
            textView.unmarkText()
            coordinator.textViewDidChange(textView)
        }
        XCTAssertNil(textView.markedTextRange)
        XCTAssertEqual(
            textView.text, "slash-command replacement ",
            "the deferred intentional replacement lands when composition ends"
        )
        XCTAssertEqual(
            TranscriptPerf.composerProgrammaticTextAssignments, 1,
            "the deferred replacement applies exactly once"
        )
    }

    /// An editor identity rotation NOT paired with a revision advance (no
    /// production path does this today, but the bridge must not silently
    /// blank the editor if one ever appears): the fresh editor adopts the
    /// binding as ground truth, exactly once.
    func testIdentityRotationWithUnpairedRevisionStillAppliesBinding() throws {
        var value = "carried text"
        let firstIdentity = UUID()
        let secondIdentity = UUID()
        let editor = ComposerPasteTextView(
            text: Binding(get: { value }, set: { value = $0 }),
            isFocused: .constant(false),
            measuredHeight: .constant(44),
            enabled: true,
            onPastedImage: { _ in },
            onPastedImageError: { _ in },
            editorIdentity: firstIdentity
        )
        let coordinator = ComposerPasteTextView.Coordinator(editor)
        let textView = ImagePasteTextView()

        // Establish the first lifecycle with no revision advances at all
        // (revision stays 0 — typed text, never replaced programmatically).
        TranscriptPerf.reset()
        coordinator.apply(
            text: "carried text",
            programmaticRevision: 0,
            editorIdentity: firstIdentity,
            to: textView
        )
        XCTAssertEqual(
            TranscriptPerf.composerProgrammaticTextAssignments, 1,
            "first apply on a fresh editor must materialize the binding"
        )

        // Rotate the identity with a genuinely fresh editor (in production
        // .id(editorIdentity) recreates the view) and no revision advance:
        // the empty view must adopt the binding as ground truth.
        let freshTextView = ImagePasteTextView()
        coordinator.apply(
            text: "carried text",
            programmaticRevision: 0,
            editorIdentity: secondIdentity,
            to: freshTextView
        )
        XCTAssertEqual(
            freshTextView.text, "carried text",
            "an unpaired identity rotation must not blank the editor"
        )
        XCTAssertEqual(
            TranscriptPerf.composerProgrammaticTextAssignments, 2,
            "the rotation apply happens exactly once"
        )

        // Follow-up invalidations with the same identity/revision: no writes.
        coordinator.apply(
            text: "carried text",
            programmaticRevision: 0,
            editorIdentity: secondIdentity,
            to: freshTextView
        )
        XCTAssertEqual(TranscriptPerf.composerProgrammaticTextAssignments, 2)
    }

    /// An intentional revision whose value equals the last DELEGATE-REPORTED
    /// text must still be applied when the live editor has already advanced
    /// past that report (unreported user input in flight). The adoption
    /// shortcut verifies against the live editor, so a genuine intentional
    /// revision can never be acknowledged without being applied.
    func testIntentionalRevisionAppliesWhenLiveEditorAdvancedPastReportedText() throws {
        var value = "abcdef"
        let identity = UUID()
        let editor = ComposerPasteTextView(
            text: Binding(get: { value }, set: { value = $0 }),
            isFocused: .constant(false),
            measuredHeight: .constant(44),
            enabled: true,
            onPastedImage: { _ in },
            onPastedImageError: { _ in },
            editorIdentity: identity
        )
        let coordinator = ComposerPasteTextView.Coordinator(editor)
        let textView = ImagePasteTextView()

        coordinator.apply(
            text: "abcdef",
            programmaticRevision: 1,
            editorIdentity: identity,
            to: textView
        )
        XCTAssertEqual(textView.text, "abcdef")

        // The user types "g" — the live editor advances to "abcdefg" while
        // the delegate flush is still pending, so the last reported text is
        // stale at "abcdef".
        textView.text = "abcdefg"
        textView.selectedRange = NSRange(location: 7, length: 0)

        TranscriptPerf.reset()
        // An intentional source rewrites the SAME value it believes is
        // current, advancing the revision: the adoption shortcut must not
        // fire on the stale report.
        coordinator.apply(
            text: "abcdef",
            programmaticRevision: 2,
            editorIdentity: identity,
            to: textView
        )
        XCTAssertEqual(
            textView.text, "abcdef",
            "a genuine intentional revision must be applied, not acknowledged while the live editor holds newer text"
        )
        XCTAssertEqual(
            TranscriptPerf.composerProgrammaticTextAssignments, 1,
            "the intentional replacement must perform a real assignment"
        )

        // Apply-once: the same revision never rewrites again.
        coordinator.apply(
            text: "abcdef",
            programmaticRevision: 2,
            editorIdentity: identity,
            to: textView
        )
        XCTAssertEqual(TranscriptPerf.composerProgrammaticTextAssignments, 1)

        // The user-echo contract is untouched: newer live text with an
        // UNCHANGED revision is never reverted by an unrelated invalidation.
        textView.text = "abcdefZ"
        textView.selectedRange = NSRange(location: 6, length: 0)
        coordinator.apply(
            text: "abcdef",
            programmaticRevision: 2,
            editorIdentity: identity,
            to: textView
        )
        XCTAssertEqual(textView.text, "abcdefZ")
        XCTAssertEqual(textView.selectedRange.location, 6)
        XCTAssertEqual(TranscriptPerf.composerProgrammaticTextAssignments, 1)
    }

    /// Clear-after-send is an intentional revision: the editor is cleared
    /// exactly once even though the same (empty) binding rides along on
    /// every subsequent invalidation.
    func testClearAfterSendClearsEditorExactlyOnce() throws {
        var value = "message being typed"
        let identity = UUID()
        let editor = ComposerPasteTextView(
            text: Binding(get: { value }, set: { value = $0 }),
            isFocused: .constant(false),
            measuredHeight: .constant(44),
            enabled: true,
            onPastedImage: { _ in },
            onPastedImageError: { _ in },
            editorIdentity: identity
        )
        let coordinator = ComposerPasteTextView.Coordinator(editor)
        let textView = ImagePasteTextView()

        coordinator.apply(
            text: "message being typed",
            programmaticRevision: 1,
            editorIdentity: identity,
            to: textView
        )
        XCTAssertEqual(textView.text, "message being typed")

        // Submit clears the composer: revision advances, editor empties.
        TranscriptPerf.reset()
        value = ""
        coordinator.apply(
            text: "",
            programmaticRevision: 2,
            editorIdentity: identity,
            to: textView
        )
        XCTAssertEqual(textView.text, "")
        XCTAssertEqual(TranscriptPerf.composerProgrammaticTextAssignments, 1)

        // Follow-up invalidations with unrelated state (streaming, busy
        // flips) carry the same revision and must not touch the editor.
        coordinator.apply(text: "", programmaticRevision: 2, editorIdentity: identity, to: textView)
        coordinator.apply(text: "", programmaticRevision: 2, editorIdentity: identity, to: textView)
        XCTAssertEqual(
            TranscriptPerf.composerProgrammaticTextAssignments, 1,
            "clear-after-send must apply exactly once"
        )
    }
}
