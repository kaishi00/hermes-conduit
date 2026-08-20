import XCTest
import UIKit
@testable import Conduit

/// Regression tests for SelectableTextView presentation memoization (Fix 3):
/// an identical settled presentation must return from updateUIView without
/// rebuilding/styling/replacing text, and repeated measurement at the same
/// width must not ask TextKit to lay the text out again. Deterministic via
/// TranscriptPerf counters — no wall-clock assertions.
@MainActor
final class SelectableTextViewPresentationCacheTests: XCTestCase {

    private func makeView(
        text: String = "A settled paragraph of selectable text.",
        font: UIFont = .preferredFont(forTextStyle: .body),
        maximumNumberOfLines: Int = 0,
        wrapsLines: Bool = true,
        selfSizingWidthRange: ClosedRange<CGFloat>? = nil,
        selectionCoordinator: MarkdownSelectionCoordinator? = nil,
        selectionSegment: MarkdownSelectionSegmentDescriptor? = nil
    ) -> SelectableTextView {
        SelectableTextView(
            text: text,
            font: font,
            textColor: .label,
            lineSpacing: 4,
            maximumNumberOfLines: maximumNumberOfLines,
            wrapsLines: wrapsLines,
            selfSizingWidthRange: selfSizingWidthRange,
            selectionCoordinator: selectionCoordinator,
            selectionSegment: selectionSegment
        )
    }

    /// 1. Identical presentation + repeated update: no attributed-text rebuild.
    func testIdenticalPresentationUpdatePerformsNoTextRebuild() {
        let view = makeView()
        let coordinator = view.makeCoordinator()
        let host = view.makeUIViewForTests(coordinator: coordinator)

        let rebuildsAfterFirst = TranscriptPerf.selectableTextViewTextRebuilds

        // Identical inputs: the presentation token must short-circuit configure.
        let identical = makeView()
        let rebuildsBefore = TranscriptPerf.selectableTextViewTextRebuilds
        identical.updateUIViewForTests(host, coordinator: coordinator)

        XCTAssertEqual(
            TranscriptPerf.selectableTextViewTextRebuilds, rebuildsBefore,
            "identical presentation must not rebuild attributed text"
        )
        XCTAssertGreaterThan(rebuildsAfterFirst, 0, "sanity: first apply did rebuild")
    }

    /// 1b. Repeated measurement at the same width avoids TextKit.
    func testRepeatedMeasurementAtSameWidthAvoidsTextKit() {
        let view = makeView()
        let coordinator = view.makeCoordinator()
        let host = view.makeUIViewForTests(coordinator: coordinator)
        let textView = host.mountedTextView

        let first = view.measuredSizeCached(
            proposalWidth: 320, textView: textView, coordinator: coordinator
        )
        XCTAssertNotNil(first)

        TranscriptPerf.reset()
        let second = view.measuredSizeCached(
            proposalWidth: 320, textView: textView, coordinator: coordinator
        )
        XCTAssertEqual(second, first, "cached measurement must return the same size")
        XCTAssertEqual(
            TranscriptPerf.textKitMeasurementCalls, 0,
            "identical presentation at the same width must not invoke TextKit measurement"
        )
    }

    /// 2. Content change invalidates the presentation gate and the cache.
    func testContentChangeInvalidates() {
        let view = makeView()
        let coordinator = view.makeCoordinator()
        let host = view.makeUIViewForTests(coordinator: coordinator)

        _ = view.measuredSizeCached(
            proposalWidth: 320, textView: host.mountedTextView, coordinator: coordinator
        )

        let changed = makeView(text: "A settled paragraph of selectable text. Now changed.")
        let rebuildsBefore = TranscriptPerf.selectableTextViewTextRebuilds
        changed.updateUIViewForTests(host, coordinator: coordinator)
        XCTAssertGreaterThan(
            TranscriptPerf.selectableTextViewTextRebuilds, rebuildsBefore,
            "changed content must rebuild attributed text"
        )

        TranscriptPerf.reset()
        let size = changed.measuredSizeCached(
            proposalWidth: 320, textView: host.mountedTextView, coordinator: coordinator
        )
        XCTAssertNotNil(size)
        XCTAssertGreaterThan(
            TranscriptPerf.textKitMeasurementCalls, 0,
            "changed content must re-measure through TextKit"
        )
    }

    /// 3. Width change invalidates the measurement cache.
    func testWidthChangeInvalidatesMeasurement() {
        let view = makeView()
        let coordinator = view.makeCoordinator()
        let host = view.makeUIViewForTests(coordinator: coordinator)

        _ = view.measuredSizeCached(
            proposalWidth: 320, textView: host.mountedTextView, coordinator: coordinator
        )

        TranscriptPerf.reset()
        _ = view.measuredSizeCached(
            proposalWidth: 200, textView: host.mountedTextView, coordinator: coordinator
        )
        XCTAssertGreaterThan(
            TranscriptPerf.textKitMeasurementCalls, 0,
            "a different proposed width must re-measure through TextKit"
        )
    }

    /// 4. Font change (Dynamic Type) invalidates the presentation gate.
    ///    A font-only change may apply through the text view's font property
    ///    (which UIKit applies to the mounted text) rather than the
    ///    attributed-string replacement branch, so the deterministic signal
    ///    is the presentation generation bump plus the mounted font.
    func testFontChangeInvalidates() {
        let view = makeView()
        let coordinator = view.makeCoordinator()
        let host = view.makeUIViewForTests(coordinator: coordinator)
        let generationBefore = coordinator.presentationGeneration

        let bigger = makeView(font: .preferredFont(forTextStyle: .title1))
        bigger.updateUIViewForTests(host, coordinator: coordinator)

        XCTAssertGreaterThan(
            coordinator.presentationGeneration, generationBefore,
            "a font change must open the presentation gate (run configure)"
        )
        let mountedFont = host.mountedTextView.attributedText.attribute(
            .font, at: 0, effectiveRange: nil
        ) as? UIFont
        XCTAssertEqual(
            mountedFont, bigger.font,
            "the new font must actually apply to the mounted text"
        )
    }

    /// 5. Selection-coordinator changes still register/unregister correctly
    ///    without forcing text restyling.
    func testSelectionChangeRegistersWithoutTextRestyle() {
        let view = makeView()
        let coordinator = view.makeCoordinator()
        let host = view.makeUIViewForTests(coordinator: coordinator)
        XCTAssertFalse(host.isUsingCoordinatedTextView, "plain mount starts uncoordinated")

        let markdownCoordinator = MarkdownSelectionCoordinator()
        let segment = MarkdownSelectionSegmentDescriptor(
            id: "block-0", order: 0, separatorBefore: ""
        )
        let coordinated = makeView(
            selectionCoordinator: markdownCoordinator,
            selectionSegment: segment
        )

        let rebuildsBefore = TranscriptPerf.selectableTextViewTextRebuilds
        coordinated.updateUIViewForTests(host, coordinator: coordinator)

        XCTAssertTrue(
            host.isUsingCoordinatedTextView,
            "selection coordinator + segment must mount the coordinated text view"
        )
        XCTAssertTrue(
            markdownCoordinator.isSegmentRegistered(segment.id),
            "the selection segment must be registered"
        )
        XCTAssertEqual(
            TranscriptPerf.selectableTextViewTextRebuilds, rebuildsBefore,
            "a selection-only change must not rebuild attributed text"
        )

        // Removing the coordinator unregisters and returns to the plain view.
        let plain = makeView()
        plain.updateUIViewForTests(host, coordinator: coordinator)
        XCTAssertFalse(host.isUsingCoordinatedTextView)
        XCTAssertFalse(
            markdownCoordinator.isSegmentRegistered(segment.id),
            "the selection segment must be unregistered when coordination ends"
        )
    }

    /// 6. Table self-sizing and non-wrapping behavior remain correct.
    func testSelfSizingAndNonWrappingMeasurementsRemainCorrect() {
        // Self-sizing (table cell): deterministic width within the range,
        // cached by presentation generation without a width key.
        let cell = makeView(selfSizingWidthRange: 80...220)
        let cellCoordinator = cell.makeCoordinator()
        let cellHost = cell.makeUIViewForTests(coordinator: cellCoordinator)

        let first = cell.measuredSizeCached(
            proposalWidth: nil, textView: cellHost.mountedTextView, coordinator: cellCoordinator
        )
        XCTAssertNotNil(first)

        TranscriptPerf.reset()
        let second = cell.measuredSizeCached(
            proposalWidth: nil, textView: cellHost.mountedTextView, coordinator: cellCoordinator
        )
        XCTAssertEqual(second, first, "self-sizing measurement must be stable")
        XCTAssertEqual(
            TranscriptPerf.textKitMeasurementCalls, 0,
            "self-sizing re-measurement must be cached"
        )
        if let size = first {
            XCTAssertTrue((80...220).contains(size.width), "self-sizing width must be clamped to the range")
        }

        // Non-wrapping: single-fragment width, height at least one line.
        let nonWrapping = makeView(text: "no wrapping here", wrapsLines: false)
        let nwCoordinator = nonWrapping.makeCoordinator()
        let nwHost = nonWrapping.makeUIViewForTests(coordinator: nwCoordinator)

        let nwFirst = nonWrapping.measuredSizeCached(
            proposalWidth: nil, textView: nwHost.mountedTextView, coordinator: nwCoordinator
        )
        XCTAssertNotNil(nwFirst)

        TranscriptPerf.reset()
        let nwSecond = nonWrapping.measuredSizeCached(
            proposalWidth: nil, textView: nwHost.mountedTextView, coordinator: nwCoordinator
        )
        XCTAssertEqual(nwSecond, nwFirst, "non-wrapping measurement must be cached")
        XCTAssertEqual(TranscriptPerf.textKitMeasurementCalls, 0)
    }
}
