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
}
