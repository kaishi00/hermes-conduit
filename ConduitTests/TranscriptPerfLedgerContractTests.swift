import XCTest
@testable import Conduit

/// Pins the repeat-detection ledger contract the performance fixtures
/// depend on. Without this negative control, a refactor that stops feeding
/// the ledger (e.g. the `MarkdownText` call site dropping
/// `context: source`) would silently vacuate every
/// `settledMarkdownRepeatEvaluations == 0` assertion while staying green.
@MainActor
final class TranscriptPerfLedgerContractTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TranscriptPerf.resetRenderLedgerForTesting()
    }

    override func tearDown() {
        TranscriptPerf.resetRenderLedgerForTesting()
        super.tearDown()
    }

    func testRepeatLedgersDetectReRendersAndResetSemantics() {
        TranscriptPerf.note(.settledMarkdownBody, context: "row-source-1")
        XCTAssertEqual(
            TranscriptPerf.settledMarkdownPreWindowRepeatEvaluations, 0,
            "a source's first evaluation is a first render, not a repeat"
        )
        XCTAssertEqual(
            TranscriptPerf.settledMarkdownWindowDuplicateEvaluations, 0,
            "the same source's FIRST evaluation must not count as an in-window duplicate"
        )

        TranscriptPerf.note(.settledMarkdownBody, context: "row-source-1")
        XCTAssertEqual(
            TranscriptPerf.settledMarkdownWindowDuplicateEvaluations, 1,
            "a second body pass on a source first rendered in this window is an in-window duplicate"
        )
        XCTAssertEqual(
            TranscriptPerf.settledMarkdownPreWindowRepeatEvaluations, 0,
            "an in-window source is not yet an at-rest (pre-window) row"
        )

        // reset() opens a fresh measurement window: raw counters zero out,
        // and sources first seen in the closing window merge into the
        // at-rest ledger — so re-evaluating one of them in the new window
        // is a PRE-WINDOW repeat (the cascade signature).
        TranscriptPerf.reset()
        XCTAssertEqual(
            TranscriptPerf.settledMarkdownTextBodyEvaluations, 0,
            "reset() clears raw counters"
        )
        TranscriptPerf.note(.settledMarkdownBody, context: "row-source-1")
        XCTAssertEqual(
            TranscriptPerf.settledMarkdownPreWindowRepeatEvaluations, 1,
            "reset() must carry the window ledger into the at-rest ledger"
        )

        // A distinct source renders free: first render, never a repeat.
        TranscriptPerf.note(.settledMarkdownBody, context: "row-source-2")
        XCTAssertEqual(
            TranscriptPerf.settledMarkdownPreWindowRepeatEvaluations, 1,
            "a never-rendered source's first evaluation is not a repeat"
        )

        // Test-lifetime clearing is the explicit resetRenderLedger path.
        TranscriptPerf.resetRenderLedgerForTesting()
        TranscriptPerf.note(.settledMarkdownBody, context: "row-source-1")
        XCTAssertEqual(
            TranscriptPerf.settledMarkdownPreWindowRepeatEvaluations, 0,
            "resetRenderLedgerForTesting() must clear both ledgers"
        )
    }

    #if DEBUG
    /// The failure diagnostics LongContextScalingFixtureTests prints: spans
    /// only for pre-window repeats, the window's first gate reopen kept past
    /// the ring's eviction, and both scoped to one window.
    func testRepeatSpansAndFirstGateReopenAreWindowScoped() {
        TranscriptPerf.note(.settledMarkdownBody, context: "row-source-1")
        XCTAssertTrue(TranscriptPerf.preWindowRepeatSpans.isEmpty, "a first render records no repeat span")
        TranscriptPerf.reset()
        TranscriptPerf.note(.settledMarkdownBody, context: "row-source-1")
        TranscriptPerf.note(.settledMarkdownBody, context: "row-source-2")
        XCTAssertEqual(TranscriptPerf.preWindowRepeatSpans.count, 1, "only the pre-window repeat records a span")
        XCTAssertTrue(TranscriptPerf.preWindowRepeatSpans[0].contains(" src=row-source-1"))

        for index in 0..<33 {
            TranscriptPerf.noteGateReopen(component: "row", fields: ["field\(index)"])
        }
        XCTAssertEqual(TranscriptPerf.recentGateReopenReports.count, 32)
        XCTAssertFalse(TranscriptPerf.recentGateReopenReports.contains { $0.hasSuffix("field0") })
        XCTAssertEqual(TranscriptPerf.firstGateReopenReport?.hasSuffix("opened by: field0"), true)

        TranscriptPerf.reset()
        XCTAssertTrue(TranscriptPerf.preWindowRepeatSpans.isEmpty, "reset() opens a window without spans")
        XCTAssertNil(TranscriptPerf.firstGateReopenReport, "reset() clears the first gate reopen")
    }
    #endif

    /// The ever-seen mount ledger behind the fresh-mount diagnostic is
    /// bounded (4096 entries). Once SATURATED, classification must stop:
    /// an unseen source evaluated after saturation is neither counted nor
    /// inserted, so the bounded ledger degrades to "no new classification"
    /// instead of re-counting every evaluation of every unseen source as a
    /// fresh mount (the pre-fix behavior inflated the diagnostic by one on
    /// each pass and grew without bound).
    func testFreshMountLedgerStopsCountingOnceSaturated() {
        // setUp cleared the ledger; saturate it with distinct sources, each
        // counted fresh exactly once.
        for index in 0..<4096 {
            TranscriptPerf.note(.settledMarkdownBody, context: "saturation-source-\(index)")
        }
        let freshAtSaturation = TranscriptPerf.settledMarkdownFreshMountEvaluations
        XCTAssertEqual(
            freshAtSaturation, 4096,
            "each distinct source's first evaluation is one fresh mount"
        )

        // An UNSEEN source after saturation, evaluated repeatedly: none of
        // its passes may count as fresh.
        for _ in 0..<5 {
            TranscriptPerf.note(.settledMarkdownBody, context: "post-saturation-unseen-source")
        }
        XCTAssertEqual(
            TranscriptPerf.settledMarkdownFreshMountEvaluations, freshAtSaturation,
            "once the bounded ledger is saturated, repeated evaluations of an unseen "
                + "source must not be re-counted as fresh mounts"
        )
    }
}
