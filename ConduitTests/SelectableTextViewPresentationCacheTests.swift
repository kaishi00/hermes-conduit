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

    override func setUp() {
        super.setUp()
        TranscriptPerf.reset()
    }

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
    ///    The per-test reset makes the sanity assertion prove THIS view
    ///    instance performed the first-apply rebuild.
    func testIdenticalPresentationUpdatePerformsNoTextRebuild() {
        let view = makeView()
        let coordinator = view.makeCoordinator()

        TranscriptPerf.reset()
        let host = view.makeUIViewForTests(coordinator: coordinator)
        XCTAssertEqual(
            TranscriptPerf.selectableTextViewTextRebuilds, 1,
            "sanity: the initial mount of this instance performed exactly one rebuild"
        )

        // Identical inputs: the presentation token must short-circuit configure.
        let identical = makeView()
        identical.updateUIViewForTests(host, coordinator: coordinator)
        XCTAssertEqual(
            TranscriptPerf.selectableTextViewTextRebuilds, 1,
            "identical presentation must not rebuild attributed text"
        )
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

    /// 5. Selection transitions in both directions still register/unregister
    ///    correctly, do not regenerate attributed content, and fully
    ///    configure the swapped-in text view (font, colors, line limits,
    ///    wrapping, container, link attributes — everything `configure`
    ///    owns, which the copied attributedText alone does not carry).
    func testSelectionSwapRegistersAndFullyConfiguresReplacementTextView() {
        // A finite line limit makes configuration loss observable.
        let view = makeView(text: "A limited settled paragraph.", maximumNumberOfLines: 2)
        let coordinator = view.makeCoordinator()
        let host = view.makeUIViewForTests(coordinator: coordinator)
        XCTAssertFalse(host.isUsingCoordinatedTextView, "plain mount starts uncoordinated")

        let markdownCoordinator = MarkdownSelectionCoordinator()
        let segment = MarkdownSelectionSegmentDescriptor(
            id: "block-0", order: 0, separatorBefore: ""
        )
        let coordinated = makeView(
            text: "A limited settled paragraph.",
            maximumNumberOfLines: 2,
            selectionCoordinator: markdownCoordinator,
            selectionSegment: segment
        )

        // Plain → coordinated. The copied attributedText already carries the
        // full styling from the previous view's configure pass, so the
        // isEqual guard needs no re-apply — the fresh view still receives
        // every view-level setting (font, colors, limits, container, link
        // attributes) because configure runs unconditionally on it.
        TranscriptPerf.reset()
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
            TranscriptPerf.selectableTextViewTextRebuilds, 0,
            "a swap must not regenerate attributed content (copied text is already styled)"
        )
        XCTAssertEqual(
            host.mountedTextView.attributedText.string,
            coordinated.attributedText.string,
            "a selection-only swap must not regenerate content"
        )
        assertFullyConfigured(host.mountedTextView, like: coordinated)

        // Coordinated → plain (same presentation otherwise).
        TranscriptPerf.reset()
        let plain = makeView(text: "A limited settled paragraph.", maximumNumberOfLines: 2)
        plain.updateUIViewForTests(host, coordinator: coordinator)

        XCTAssertFalse(
            host.isUsingCoordinatedTextView,
            "removing coordination must return to the plain text view"
        )
        XCTAssertFalse(
            markdownCoordinator.isSegmentRegistered(segment.id),
            "the selection segment must be unregistered when coordination ends"
        )
        XCTAssertEqual(
            TranscriptPerf.selectableTextViewTextRebuilds, 0,
            "the reverse swap must not regenerate attributed content either"
        )
        XCTAssertEqual(
            host.mountedTextView.attributedText.string,
            plain.attributedText.string,
            "the reverse swap must not regenerate content"
        )
        assertFullyConfigured(host.mountedTextView, like: plain)
    }

    /// The full set of view-level configuration `configure` applies — every
    /// item a freshly swapped-in UITextView would otherwise miss.
    private func assertFullyConfigured(
        _ textView: UITextView,
        like view: SelectableTextView,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertEqual(textView.font, view.font, file: file, line: line)
        XCTAssertEqual(textView.textColor, view.textColor, file: file, line: line)
        XCTAssertEqual(
            textView.textContainer.maximumNumberOfLines,
            view.maximumNumberOfLines,
            "line limits must survive the text-view swap", file: file, line: line
        )
        XCTAssertTrue(
            textView.textContainer.widthTracksTextView == view.wrapsLines,
            "wrapping configuration must survive the swap", file: file, line: line
        )
        let expectedBreak: NSLineBreakMode = view.maximumNumberOfLines > 0
            ? .byTruncatingTail
            : (view.wrapsLines ? .byWordWrapping : .byClipping)
        XCTAssertEqual(
            textView.textContainer.lineBreakMode,
            expectedBreak,
            "line-break mode must survive the swap", file: file, line: line
        )
        XCTAssertEqual(
            (textView.linkTextAttributes[.foregroundColor] as? UIColor),
            view.linkColor,
            "link attributes must survive the swap", file: file, line: line
        )
        let paragraph = textView.attributedText.attribute(
            .paragraphStyle, at: 0, effectiveRange: nil
        ) as? NSParagraphStyle
        XCTAssertEqual(
            paragraph?.lineSpacing,
            view.lineSpacing,
            "paragraph line spacing must survive the swap", file: file, line: line
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
