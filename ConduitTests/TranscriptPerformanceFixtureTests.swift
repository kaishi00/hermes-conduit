import XCTest
import SwiftUI
@testable import Conduit

/// Performance fixture (spec: 250 settled Markdown-heavy messages + one
/// active streaming response, every message below the 100 KB large-document
/// threshold, plus a plain-text counterpart). Asserts the architectural
/// acceptance criterion with deterministic counters, never wall-clock:
///
///   one streaming publish
///       → only the live StreamingBubble changes
///       settled Markdown presentation rebuilds ≈ 0
///       settled TextKit measurements ≈ 0
///
/// The fixture hosts the real ChatView (real ForEach, real gating, real
/// StreamingBubble) so the measured cascade is the production one. The
/// LazyVStack mounts the visible subset of rows, exactly as on a device.
@MainActor
final class TranscriptPerformanceFixtureTests: XCTestCase {

    private func makeAppState() -> AppState {
        let defaults = UserDefaults(suiteName: "transcript-perf-fixture")!
        defaults.removePersistentDomain(forName: "transcript-perf-fixture")
        return AppState(defaults: defaults, loadSavedConnection: false)
    }

    // MARK: - Fixture transcripts

    /// Markdown-heavy settled messages covering paragraphs, headings,
    /// lists, quotes, links, and moderate code blocks. Diverse from the
    /// first message onward — the LazyVStack mounts roughly the first
    /// screenful, so the mounted subset must exercise every block shape.
    static func markdownTranscript(count: Int = 250) -> [ChatMessage] {
        (0..<count).map { index in
            ChatMessage(
                id: "fixture-\(index)",
                role: index % 2 == 0 ? .assistant : .user,
                content: markdownBody(index: index),
                timestamp: "2026-01-01T00:00:00Z"
            )
        }
    }

    private static func markdownBody(index: Int) -> String {
        switch index % 6 {
        case 0:
            return """
            ### Section heading \(index)

            A settled paragraph with **bold**, *italic*, and `inline code` —
            message \(index) of the cumulative-transcript fixture. It repeats
            enough prose to resemble a real assistant answer, and carries a
            [reference link](https://example.com/item/\(index)) for coverage.

            - first list item with some detail
            - second list item
            - third list item with a trailing note
            """
        case 1:
            return """
            Message \(index) asks a settled question with _emphasis_ and a
            [link](https://example.com/q/\(index)); the answer follows in the
            next turn. Ordinary paragraphs keep the reading column busy.
            """
        case 2:
            return """
            > A quoted passage for message \(index).
            > Quotes render through the selectable flow path with italic runs.

            Follow-up paragraph after the quote, long enough to wrap across
            two or three display lines in the fixture viewport.
            """
        case 3:
            return """
            #### Code-bearing answer \(index)

            ```swift
            func settled\(index)() -> String {
                let value = "message \\(index)"
                return value
            }
            ```

            A short paragraph after the code block for coverage.
            """
        case 4:
            return """
            1. Ordered first step for message \(index)
            2. Ordered second step
            3. Ordered third step with a [docs link](https://example.com/docs/\(index))

            Closing paragraph.
            """
        default:
            return """
            ## Heading \(index)

            Mixed content: a paragraph, then a list, then a quote.

            - bullet one
            - bullet two

            > quoted line
            """
        }
    }

    /// Plain-text counterpart: no Markdown structure, same volume.
    static func plainTextTranscript(count: Int = 250) -> [ChatMessage] {
        (0..<count).map { index in
            ChatMessage(
                id: "plain-\(index)",
                role: index % 2 == 0 ? .assistant : .user,
                content: String(
                    repeating: "Plain settled message \(index) body text. ",
                    count: 24
                ),
                timestamp: "2026-01-01T00:00:00Z"
            )
        }
    }

    // MARK: - Harness

    /// Drains pending SwiftUI updates (including any left over from the
    /// previous test's host window teardown) so counter windows measure
    /// only this test's work.
    private func drainRunLoop() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }

    private func mountChat(
        appState: AppState,
        streaming: String
    ) -> (UIHostingController<AnyView>, UIWindow) {
        appState.streamingText = streaming
        let host = UIHostingController(
            rootView: AnyView(ChatView().environmentObject(appState))
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        drainRunLoop()
        return (host, window)
    }

    /// Drives `ticks` streaming publishes at the production ~30 Hz cadence,
    /// pumping layout each tick (see the SwiftUI async-commit pitfall:
    /// state set from async contexts needs a forced layout pass per pump).
    private func streamTicks(
        _ ticks: Int,
        appState: AppState,
        host: UIHostingController<AnyView>
    ) {
        for tick in 0..<ticks {
            appState.streamingText =
                "Live streaming delta \(tick) — the only view that should change. "
                + String(repeating: "Growing body \(tick). ", count: tick + 1)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.current.run(until: Date())
        }
    }

    // MARK: - Fixtures

    func testStreamingTicksLeaveSettledMarkdownDormant_MarkdownTranscript() throws {
        let appState = makeAppState()
        appState.messages = Self.markdownTranscript()

        let (host, _) = mountChat(appState: appState, streaming: "Initial streaming frame")

        // Sanity: the settled transcript actually mounted and rendered.
        let settledMarkdownAtRest = TranscriptPerf.settledMarkdownTextBodyEvaluations
        XCTAssertGreaterThan(
            settledMarkdownAtRest, 0,
            "fixture must mount settled Markdown rows before streaming starts"
        )

        // Settle tick: the first streaming delta can legitimately mount one
        // additional lazy row as layout adjusts. Steady-state work is what
        // the acceptance criterion bounds, so measure from the second tick.
        streamTicks(1, appState: appState, host: host)
        drainRunLoop()

        TranscriptPerf.reset()
        streamTicks(10, appState: appState, host: host)

        XCTAssertEqual(
            TranscriptPerf.settledMarkdownTextBodyEvaluations, 0,
            "10 streaming publishes must not re-evaluate any settled Markdown body"
        )
        // The live streaming row legitimately updates, rebuilds, and measures
        // its own few block text views each tick (~2-3 SelectableTextViews).
        // The bounds below allow only that live-row work: under the pre-fix
        // cascade every mounted settled row joined these counts per tick.
        XCTAssertLessThanOrEqual(
            TranscriptPerf.selectableTextViewUpdateCalls, 30,
            "SelectableTextView work must be bounded to the live row (~3/tick)"
        )
        XCTAssertLessThanOrEqual(
            TranscriptPerf.textKitMeasurementCalls, 30,
            "TextKit measurement must be bounded to the live row, not the settled transcript"
        )
        XCTAssertLessThanOrEqual(
            TranscriptPerf.selectableTextViewTextRebuilds, 20,
            "attributed-text rebuilds must be bounded to the live row's changed content (~2/tick)"
        )
    }

    func testStreamingTicksLeaveSettledMarkdownDormant_PlainTextTranscript() throws {
        let appState = makeAppState()
        appState.messages = Self.plainTextTranscript()

        let (host, _) = mountChat(appState: appState, streaming: "Initial streaming frame")
        streamTicks(1, appState: appState, host: host)
        drainRunLoop()

        TranscriptPerf.reset()
        streamTicks(10, appState: appState, host: host)

        XCTAssertEqual(
            TranscriptPerf.settledMarkdownTextBodyEvaluations, 0,
            "plain-text transcript: streaming must not re-evaluate settled Markdown"
        )
        XCTAssertLessThanOrEqual(TranscriptPerf.textKitMeasurementCalls, 30)
    }

    /// The settled transcript itself still renders through the normal path
    /// when it genuinely changes: appending a message re-renders exactly the
    /// new content, and the fingerprint bound stays O(append).
    func testGenuineAppendRendersNewMessageAndFingerprintsBounded() throws {
        let appState = makeAppState()
        var messages = Self.markdownTranscript(count: 100)
        appState.messages = messages

        let (host, _) = mountChat(appState: appState, streaming: "")
        appState.streamingText = ""  // StreamingBubble unmounts

        TranscriptPerf.reset()
        messages.append(
            ChatMessage(
                id: "fixture-new",
                role: .assistant,
                content: "## A genuinely new message\n\nWith a paragraph and a [link](https://example.com/new).",
                timestamp: "2026-01-02T00:00:00Z"
            )
        )
        appState.messages = messages
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date())

        XCTAssertEqual(
            TranscriptPerf.lastFingerprintedMessageCount, 1,
            "appending to a 100-message transcript must fingerprint exactly the appended message"
        )
        XCTAssertGreaterThan(
            TranscriptPerf.settledMarkdownTextBodyEvaluations, 0,
            "the genuinely new message must render"
        )
        XCTAssertEqual(
            TranscriptPerf.transcriptChangedCalls, 1,
            "one messages mutation must cause exactly one transcriptChanged call"
        )
    }
}
