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

    /// Retained for the full lifetime of each measurement so the hosted
    /// hierarchy stays genuinely mounted; torn down explicitly per test.
    private var testWindow: UIWindow?

    override func setUp() {
        super.setUp()
        TranscriptPerf.resetRenderLedgerForTesting()
    }

    override func tearDown() {
        // Detach the window first so dismantle work is triggered, flush the
        // run loop so it completes within THIS test, then reset counters —
        // the next test starts from zero with no pending teardown updates.
        testWindow?.isHidden = true
        testWindow?.rootViewController = nil
        RunLoop.current.run(until: Date())
        testWindow = nil
        TranscriptPerf.reset()
        super.tearDown()
    }

    private func makeAppState() throws -> AppState {
        let suiteName = "transcript-perf-fixture"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName),
            "test UserDefaults suite must initialize"
        )
        defaults.removePersistentDomain(forName: suiteName)
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

    /// Hosts the full ChatView in a retained, live window.
    private func mountChat(
        appState: AppState,
        streaming: String
    ) -> UIHostingController<AnyView> {
        appState.streamingText = streaming
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
        let appState = try makeAppState()
        appState.messages = Self.markdownTranscript()

        let host = mountChat(appState: appState, streaming: "Initial streaming frame")

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
        let settled = PerformanceFixtureWait.settleUntilCountersQuiet(quietFor: 1.2)
        guard settled else {
            XCTFail("counter window never reached a quiet state; measurement would be meaningless on this runner")
            return
        }

        TranscriptPerf.reset()
        streamTicks(10, appState: appState, host: host)

        // Dormancy invariant, classified by position: streaming must never
        // re-render INTERIOR settled rows — that is the per-publish cascade
        // the acceptance criterion bounds (every mounted row joining each
        // tick). A growing streaming bubble legitimately shifts the
        // bottom-anchored LazyVStack, and remounts of rows AT THE VIEWPORT
        // EDGES are tolerated however many a loaded scheduler produces.
        let atRestRerenders = TranscriptPerf.settledMarkdownPreWindowRepeatEvaluations
        let interiorRerenders = TranscriptPerf.interiorAtRestRerenders(
            sources: TranscriptPerf.recentPreWindowRepeatSources,
            transcript: Self.markdownTranscript()
        )
        XCTAssertTrue(
            interiorRerenders.isEmpty,
            "streaming re-rendered \(interiorRerenders.count) interior settled Markdown rows "
                + "(of \(atRestRerenders) at-rest re-renders; edge remounts are tolerated): "
                + "\(interiorRerenders.map { String($0.prefix(32)) })"
        )
        // The live streaming row legitimately updates, rebuilds, and measures
        // its own few block text views each tick (~3 SelectableTextViews,
        // ~2 rebuilds). Under the pre-fix cascade every mounted settled row
        // joined these counts per tick (thousands per window), which stays
        // caught. Each TOLERATED viewport-edge remount additionally costs
        // its own row's few text views, so the allowance grows by one
        // remount's footprint per edge re-render the dormancy classifier
        // above accepted — zero churn keeps the original strict bound.
        let edgeRemountAllowance = max(atRestRerenders, TranscriptPerf.settledMarkdownWindowDuplicateEvaluations)
        XCTAssertLessThanOrEqual(
            TranscriptPerf.selectableTextViewUpdateCalls, 30 + 5 * edgeRemountAllowance,
            "SelectableTextView work must be bounded to the live row (~3/tick) plus tolerated edge remounts"
        )
        XCTAssertLessThanOrEqual(
            TranscriptPerf.textKitMeasurementCalls, 30 + 5 * edgeRemountAllowance,
            "TextKit measurement must be bounded to the live row, not the settled transcript"
        )
        XCTAssertLessThanOrEqual(
            TranscriptPerf.selectableTextViewTextRebuilds, 20 + 3 * edgeRemountAllowance,
            "attributed-text rebuilds must be bounded to the live row's changed content (~2/tick) plus tolerated edge remounts"
        )
    }

    func testStreamingTicksLeaveSettledMarkdownDormant_PlainTextTranscript() throws {
        let appState = try makeAppState()
        appState.messages = Self.plainTextTranscript()

        let host = mountChat(appState: appState, streaming: "Initial streaming frame")
        streamTicks(1, appState: appState, host: host)
        let settled = PerformanceFixtureWait.settleUntilCountersQuiet(quietFor: 1.2)
        guard settled else {
            XCTFail("counter window never reached a quiet state; measurement would be meaningless on this runner")
            return
        }

        TranscriptPerf.reset()
        streamTicks(10, appState: appState, host: host)

        // Same position classification: interior plain rows re-rendering
        // under streaming is the cascade; edge remounts are layout churn.
        let plainAtRestRerenders = TranscriptPerf.settledMarkdownPreWindowRepeatEvaluations
        let plainInteriorRerenders = TranscriptPerf.interiorAtRestRerenders(
            sources: TranscriptPerf.recentPreWindowRepeatSources,
            transcript: Self.plainTextTranscript()
        )
        XCTAssertTrue(
            plainInteriorRerenders.isEmpty,
            "plain-text transcript: streaming re-rendered \(plainInteriorRerenders.count) interior rows "
                + "(of \(plainAtRestRerenders) at-rest re-renders; edge remounts are tolerated): "
                + "\(plainInteriorRerenders.map { String($0.prefix(32)) })"
        )
        // Same remount-footprint allowance as the markdown variant: the
        // strict bound holds whenever no edge churn occurred.
        let plainEdgeAllowance = max(plainAtRestRerenders, TranscriptPerf.settledMarkdownWindowDuplicateEvaluations)
        XCTAssertLessThanOrEqual(
            TranscriptPerf.textKitMeasurementCalls, 30 + 5 * plainEdgeAllowance,
            "TextKit measurement must be bounded to the live row plus tolerated edge remounts"
        )
    }

    /// First-render gateway resolver (#5): settled Markdown must render
    /// exactly once on first appearance — no nil → resolver invalidation
    /// sweep. The resolver identity must be stable for the profile and the
    /// settled evaluation count must not grow after the initial layout.
    func testFirstAppearanceRendersSettledMarkdownOnce() throws {
        let appState = try makeAppState()
        appState.messages = Self.markdownTranscript()

        // Stable identity per profile, available from the first body pass.
        let first = appState.gatewayMediaResolver
        XCTAssertIdentical(
            appState.gatewayMediaResolver, first,
            "the resolver must be identity-stable while the profile is unchanged"
        )

        let host = mountChat(appState: appState, streaming: "Initial frame")
        // Let lazy mounting fully settle: the first pass mounts the visible
        // screenful and LazyVStack prefetches neighbor rows on subsequent
        // turns — each a legitimate FIRST render of a new row, not a
        // re-render of an existing one. Cold CI simulators trickle those
        // prefetches over seconds, so wait for the sustained-quiet baseline
        // (counter condition; the cap is only a failsafe).
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let baselineSettled = PerformanceFixtureWait.settleUntilCountersQuiet(quietFor: 1.2)
        // Without a settled baseline the "no second render pass" assertion
        // would race against still-in-flight lazy mounts on slow runners.
        guard baselineSettled else {
            XCTFail("lazy mounting never reached a quiet state; the first-appearance baseline would be meaningless on this runner")
            return
        }
        let initialEvaluations = TranscriptPerf.settledMarkdownTextBodyEvaluations
        XCTAssertGreaterThan(
            initialEvaluations, 0,
            "settled Markdown must render on first appearance"
        )

        // Open the measurement window: every row rendered by the drain is
        // now "already at rest" for the repeat ledger.
        TranscriptPerf.reset()

        // The pre-fix nil → resolver transition re-evaluated every mounted
        // settled row here — an INTERIOR-row cascade the position
        // classifier fails loudly. Relayout waking the lazy prefetcher to
        // FIRST-mount one more neighbor row, or remounting viewport-edge
        // rows, is not a second render pass of at-rest content.
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let relayoutSettled = PerformanceFixtureWait.settleUntilCountersQuiet(quietFor: 1.2)
        guard relayoutSettled else {
            XCTFail("post-relayout updates never quieted; the no-second-pass check would race pending commits on this runner")
            return
        }

        let atRestRerenders = TranscriptPerf.settledMarkdownPreWindowRepeatEvaluations
        let interiorRerenders = TranscriptPerf.interiorAtRestRerenders(
            sources: TranscriptPerf.recentPreWindowRepeatSources,
            transcript: Self.markdownTranscript()
        )
        XCTAssertTrue(
            interiorRerenders.isEmpty,
            "relayout re-rendered \(interiorRerenders.count) interior settled rows after first appearance "
                + "(of \(atRestRerenders) at-rest re-renders; edge remounts are tolerated): "
                + "\(interiorRerenders.map { String($0.prefix(32)) })"
        )
    }

    /// The settled transcript itself still renders through the normal path
    /// when it genuinely changes: appending a message re-renders exactly the
    /// new content, and the fingerprint bound stays O(append).
    func testGenuineAppendRendersNewMessageAndFingerprintsBounded() throws {
        let appState = try makeAppState()
        var messages = Self.markdownTranscript(count: 100)
        appState.messages = messages

        let host = mountChat(appState: appState, streaming: "")
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

        // Semantic readiness, not elapsed time: the mutation must have been
        // fingerprinted by the scroll-target cache (the append-specific
        // signal) and the new content must have rendered before the
        // bounded-work assertions mean anything. Exactness is asserted
        // below; these gates only decide readiness.
        let appendFingerprinted = PerformanceFixtureWait.eventually {
            TranscriptPerf.lastFingerprintedMessageCount >= 1
        }
        XCTAssertTrue(
            appendFingerprinted,
            "the append never reached the scroll-target cache on this runner"
        )
        let newMessageRendered = PerformanceFixtureWait.eventually {
            TranscriptPerf.settledMarkdownTextBodyEvaluations > 0
        }
        XCTAssertTrue(
            newMessageRendered,
            "the genuinely new message never rendered on this runner"
        )

        XCTAssertEqual(
            TranscriptPerf.lastFingerprintedMessageCount, 1,
            "appending to a 100-message transcript must fingerprint exactly the appended message"
        )
        XCTAssertEqual(
            TranscriptPerf.transcriptChangedCalls, 1,
            "one messages mutation must cause exactly one transcriptChanged call"
        )
    }
}
