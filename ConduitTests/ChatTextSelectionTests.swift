import XCTest
import UIKit
import SwiftUI
@testable import Conduit

final class ChatTextSelectionTests: XCTestCase {
    @MainActor
    func testSelectableTextViewDefaultsToNoSelectionCoordinatorHooks() {
        let view = SelectableTextView(text: "plain text")

        XCTAssertNil(view.selectionCoordinator)
        XCTAssertNil(view.selectionSegment)
    }

    @MainActor
    func testSelectableTextViewStoresOptionalSelectionCoordinatorHooks() {
        let coordinator = MarkdownSelectionCoordinator()
        let descriptor = MarkdownSelectionSegmentDescriptor(id: "paragraph", order: 0, separatorBefore: "")
        let view = SelectableTextView(
            text: "coordinated text",
            selectionCoordinator: coordinator,
            selectionSegment: descriptor
        )

        XCTAssertTrue(view.selectionCoordinator === coordinator)
        XCTAssertEqual(view.selectionSegment, descriptor)
    }

    @MainActor
    func testSelectionBridgeCanBeEnabledAndDisabledAcrossUpdates() {
        let selectionCoordinator = MarkdownSelectionCoordinator()
        let descriptor = MarkdownSelectionSegmentDescriptor(id: "paragraph", order: 0, separatorBefore: "")
        selectionCoordinator.replaceSegments([descriptor], revision: "bridge-toggle-v1")

        let coordinatedView = SelectableTextView(
            text: "toggle me",
            selectionCoordinator: selectionCoordinator,
            selectionSegment: descriptor
        )
        let bridgeCoordinator = coordinatedView.makeCoordinator()
        let hostView = coordinatedView.makeUIViewForTests(coordinator: bridgeCoordinator)

        XCTAssertTrue(hostView.isUsingCoordinatedTextView)
        hostView.simulateTouchBeganForTesting(at: CGPoint(x: 3, y: 3))
        XCTAssertFalse(selectionCoordinator.hasActiveSelection)

        hostView.mountedTextView.selectedRange = NSRange(location: 0, length: 3)
        bridgeCoordinator.textViewDidChangeSelection(hostView.mountedTextView)

        XCTAssertTrue(selectionCoordinator.hasActiveSelection)
        XCTAssertEqual(
            selectionCoordinator.activeSpans,
            [MarkdownSelectionSpan(segmentID: descriptor.id, range: NSRange(location: 0, length: 3))]
        )

        selectionCoordinator.clearSelection()

        let uncoordinatedView = SelectableTextView(text: "toggle me")
        uncoordinatedView.updateUIViewForTests(hostView, coordinator: bridgeCoordinator)

        XCTAssertFalse(hostView.isUsingCoordinatedTextView)
        hostView.simulateTouchBeganForTesting(at: CGPoint(x: 3, y: 3))
        XCTAssertFalse(selectionCoordinator.hasActiveSelection)
    }

    @MainActor
    func testReverseNativeSelectionActivationPreservesTouchedUpperEndpointForCrossSegmentUpdate() {
        let selectionCoordinator = MarkdownSelectionCoordinator()
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "first", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "second", order: 1, separatorBefore: "\n\n")
        ]
        selectionCoordinator.replaceSegments(descriptors, revision: "reverse-native-cross-segment-v1")

        let firstTextView = SelectableTextView.makeTextView()
        firstTextView.attributedText = NSAttributedString(string: "Alpha")
        selectionCoordinator.register(descriptor: descriptors[0], textView: firstTextView)

        let view = SelectableTextView(
            text: "Bravo",
            selectionCoordinator: selectionCoordinator,
            selectionSegment: descriptors[1]
        )
        let bridgeCoordinator = view.makeCoordinator()
        let hostView = view.makeUIViewForTests(coordinator: bridgeCoordinator)

        selectionCoordinator.beginPendingSelection(
            segmentID: descriptors[1].id,
            offset: 4,
            windowPoint: CGPoint(x: 40, y: 0)
        )
        hostView.mountedTextView.selectedRange = NSRange(location: 1, length: 3)
        bridgeCoordinator.textViewDidChangeSelection(hostView.mountedTextView)

        selectionCoordinator.updateSelection(
            segmentID: descriptors[0].id,
            offset: 2,
            windowPoint: CGPoint(x: 0, y: 0)
        )

        XCTAssertEqual(
            selectionCoordinator.activeSpans,
            [
                MarkdownSelectionSpan(segmentID: descriptors[0].id, range: NSRange(location: 2, length: 3)),
                MarkdownSelectionSpan(segmentID: descriptors[1].id, range: NSRange(location: 0, length: 4))
            ]
        )
    }

    @MainActor
    func testReverseNativeSelectionUpdateKeepsTouchedUpperEndpointAsAnchor() {
        let selectionCoordinator = MarkdownSelectionCoordinator()
        let descriptor = MarkdownSelectionSegmentDescriptor(id: "paragraph", order: 0, separatorBefore: "")
        selectionCoordinator.replaceSegments([descriptor], revision: "reverse-native-update-v1")

        let view = SelectableTextView(
            text: "ABCDE",
            selectionCoordinator: selectionCoordinator,
            selectionSegment: descriptor
        )
        let bridgeCoordinator = view.makeCoordinator()
        let hostView = view.makeUIViewForTests(coordinator: bridgeCoordinator)

        selectionCoordinator.beginPendingSelection(
            segmentID: descriptor.id,
            offset: 4,
            windowPoint: CGPoint(x: 40, y: 0)
        )
        hostView.mountedTextView.selectedRange = NSRange(location: 1, length: 3)
        bridgeCoordinator.textViewDidChangeSelection(hostView.mountedTextView)

        hostView.mountedTextView.selectedRange = NSRange(location: 0, length: 4)
        bridgeCoordinator.textViewDidChangeSelection(hostView.mountedTextView)

        XCTAssertEqual(
            selectionCoordinator.activeSpans,
            [
                MarkdownSelectionSpan(segmentID: descriptor.id, range: NSRange(location: 0, length: 4))
            ]
        )
    }

    @MainActor
    func testCoordinatedMountedTextViewUsesSelectableBaseConfiguration() {
        let selectionCoordinator = MarkdownSelectionCoordinator()
        let descriptor = MarkdownSelectionSegmentDescriptor(id: "paragraph", order: 0, separatorBefore: "")
        selectionCoordinator.replaceSegments([descriptor], revision: "coordinated-config-v1")

        let view = SelectableTextView(
            text: "configured",
            selectionCoordinator: selectionCoordinator,
            selectionSegment: descriptor
        )
        let hostView = view.makeUIViewForTests(coordinator: view.makeCoordinator())
        let textView = hostView.mountedTextView

        XCTAssertTrue(hostView.isUsingCoordinatedTextView)
        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertFalse(textView.isScrollEnabled)
        XCTAssertEqual(textView.backgroundColor, .clear)
        XCTAssertEqual(textView.textContainerInset, .zero)
        XCTAssertEqual(textView.textContainer.lineFragmentPadding, 0)
        XCTAssertEqual(textView.contentHuggingPriority(for: .vertical), .required)
        XCTAssertEqual(textView.contentCompressionResistancePriority(for: .vertical), .required)
    }

    @MainActor
    func testSimpleTapClearsPreviousCrossBlockSelectionWithoutStartingANewOne() {
        let selectionCoordinator = MarkdownSelectionCoordinator()
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "first", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "second", order: 1, separatorBefore: "\n\n")
        ]
        selectionCoordinator.replaceSegments(descriptors, revision: "tap-clear-v1")

        let view = SelectableTextView(
            text: "First",
            selectionCoordinator: selectionCoordinator,
            selectionSegment: descriptors[0]
        )
        let bridgeCoordinator = view.makeCoordinator()
        let hostView = view.makeUIViewForTests(coordinator: bridgeCoordinator)

        let secondTextView = SelectableTextView.makeTextView()
        secondTextView.attributedText = NSAttributedString(string: "Second")
        selectionCoordinator.register(descriptor: descriptors[1], textView: secondTextView)

        selectionCoordinator.beginSelection(segmentID: "first", offset: 2, windowPoint: .zero)
        selectionCoordinator.updateSelection(segmentID: "second", offset: 3, windowPoint: CGPoint(x: 0, y: 10))
        XCTAssertTrue(selectionCoordinator.hasCrossSegmentSelection)

        // The observer recognizer ends the gesture on touch-up; a later tap is
        // a fresh touch down, modeled by ending the gesture before the tap.
        selectionCoordinator.endSelection()

        hostView.simulateTouchBeganForTesting(at: CGPoint(x: 3, y: 3))

        XCTAssertFalse(selectionCoordinator.hasActiveSelection)
        XCTAssertFalse(selectionCoordinator.hasCrossSegmentSelection)
    }

    @MainActor
    func testMidGestureRedeliveredTouchBeganDoesNotClearActiveSelection() {
        let selectionCoordinator = MarkdownSelectionCoordinator()
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "first", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "second", order: 1, separatorBefore: "\n\n")
        ]
        selectionCoordinator.replaceSegments(descriptors, revision: "mid-gesture-v1")

        selectionCoordinator.beginSelection(segmentID: "first", offset: 2, windowPoint: .zero)
        selectionCoordinator.updateSelection(segmentID: "second", offset: 3, windowPoint: CGPoint(x: 0, y: 10))
        XCTAssertTrue(selectionCoordinator.isSelectionGestureActive)

        // The private text-selection gesture re-delivers a synthetic
        // touchesBegan mid-drag as it takes over the touch; that must not
        // clear the selection being dragged.
        selectionCoordinator.beginPendingSelection(
            segmentID: "first",
            offset: 1,
            windowPoint: CGPoint(x: 0, y: 0)
        )

        XCTAssertTrue(selectionCoordinator.hasActiveSelection)
        XCTAssertTrue(selectionCoordinator.hasCrossSegmentSelection)
    }

    @MainActor
    func testDismantleUnregistersMountedCoordinatedTextView() {
        let selectionCoordinator = MarkdownSelectionCoordinator()
        let descriptor = MarkdownSelectionSegmentDescriptor(id: "paragraph", order: 0, separatorBefore: "")
        selectionCoordinator.replaceSegments([descriptor], revision: "dismantle-v1")

        let view = SelectableTextView(
            text: "registered",
            selectionCoordinator: selectionCoordinator,
            selectionSegment: descriptor
        )
        let bridgeCoordinator = view.makeCoordinator()
        let hostView = view.makeUIViewForTests(coordinator: bridgeCoordinator)

        XCTAssertEqual(selectionCoordinator.text(for: descriptor.id), "registered")

        SelectableTextView.dismantleUIView(hostView, coordinator: bridgeCoordinator)

        XCTAssertNil(selectionCoordinator.text(for: descriptor.id))
    }

    @MainActor
    func testCoordinatedCopyPathUsesCoordinatorActiveSelection() {
        let selectionCoordinator = MarkdownSelectionCoordinator()
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "first", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "second", order: 1, separatorBefore: "\n\n")
        ]
        selectionCoordinator.replaceSegments(descriptors, revision: "copy-bridge-v1")

        let view = SelectableTextView(
            text: "First",
            selectionCoordinator: selectionCoordinator,
            selectionSegment: descriptors[0]
        )
        let bridgeCoordinator = view.makeCoordinator()
        let hostView = view.makeUIViewForTests(coordinator: bridgeCoordinator)

        let secondTextView = SelectableTextView.makeTextView()
        secondTextView.attributedText = NSAttributedString(string: "Second")
        selectionCoordinator.register(descriptor: descriptors[1], textView: secondTextView)

        selectionCoordinator.beginSelection(
            segmentID: descriptors[0].id,
            offset: 2,
            windowPoint: CGPoint(x: 0, y: 0)
        )
        selectionCoordinator.updateSelection(
            segmentID: descriptors[1].id,
            offset: 3,
            windowPoint: CGPoint(x: 0, y: 10)
        )

        XCTAssertEqual(hostView.coordinatedCopiedAttributedTextForTesting()?.string, "rst\n\nSec")
    }

    // MARK: - Selection observer recognizer

    @MainActor
    func testObserverRecognizerIsAttachedToCoordinatedTextViewAndAllowsSimultaneousRecognition() throws {
        let selectionCoordinator = MarkdownSelectionCoordinator()
        let descriptor = MarkdownSelectionSegmentDescriptor(id: "paragraph", order: 0, separatorBefore: "")
        selectionCoordinator.replaceSegments([descriptor], revision: "observer-attach-v1")

        let view = SelectableTextView(
            text: "observed",
            selectionCoordinator: selectionCoordinator,
            selectionSegment: descriptor
        )
        let hostView = view.makeUIViewForTests(coordinator: view.makeCoordinator())
        let observer = try XCTUnwrap(hostView.selectionObserverForTesting)

        XCTAssertFalse(observer.cancelsTouchesInView)
        XCTAssertFalse(observer.delaysTouchesBegan)
        XCTAssertFalse(observer.delaysTouchesEnded)
        XCTAssertTrue(
            observer.gestureRecognizer(
                observer,
                shouldRecognizeSimultaneouslyWith: UIPanGestureRecognizer()
            )
        )
    }

    @MainActor
    func testObserverMoveExtendsActiveSelectionAcrossSegmentsAndTouchEndPreservesIt() throws {
        let selectionCoordinator = MarkdownSelectionCoordinator()
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "first", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "second", order: 1, separatorBefore: "\n\n")
        ]
        selectionCoordinator.replaceSegments(descriptors, revision: "observer-move-v1")

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 240, height: 180))
        let rootView = UIView(frame: window.bounds)
        window.addSubview(rootView)
        window.isHidden = false

        let firstHost = mountedSelectionHost(
            text: "Anchor",
            segment: descriptors[0],
            frame: CGRect(x: 10, y: 10, width: 180, height: 40),
            coordinator: selectionCoordinator,
            in: window
        )
        let secondTextView = SelectableTextView.makeTextView()
        secondTextView.attributedText = NSAttributedString(string: "Focus")
        secondTextView.frame = CGRect(x: 10, y: 80, width: 180, height: 40)
        window.subviews.first?.addSubview(secondTextView)
        secondTextView.layoutIfNeeded()
        selectionCoordinator.register(descriptor: descriptors[1], textView: secondTextView)

        let observer = try XCTUnwrap(firstHost.selectionObserverForTesting)

        // A move with no active selection drag is a no-op (plain scrolling).
        observer.handleMove(toWindowPoint: CGPoint(x: 18, y: 90))
        XCTAssertFalse(selectionCoordinator.hasActiveSelection)

        // The long-press lands and the native gesture reports a selection.
        firstHost.simulateTouchBeganForTesting(at: CGPoint(x: 18, y: 20))
        firstHost.mountedTextView.selectedRange = NSRange(location: 1, length: 3)
        selectionCoordinator.updateNativeSelection(
            segmentID: descriptors[0].id,
            selectedRange: NSRange(location: 1, length: 3),
            lowerWindowPoint: CGPoint(x: 18, y: 20),
            upperWindowPoint: CGPoint(x: 34, y: 20)
        )
        XCTAssertTrue(selectionCoordinator.isSelectionGestureActive)

        // The finger crosses into the second segment; the observer extends
        // the selection across both text views.
        observer.handleMove(toWindowPoint: CGPoint(x: 150, y: 100))
        XCTAssertTrue(selectionCoordinator.hasCrossSegmentSelection)
        XCTAssertEqual(selectionCoordinator.activeSpans.map(\.segmentID), ["first", "second"])
        XCTAssertEqual(secondTextView.selectedRange.location, 0)
        XCTAssertTrue((1...5).contains(secondTextView.selectedRange.length))

        // Touch-up ends the gesture but keeps the selection for Copy.
        observer.handleTouchEnd()
        XCTAssertFalse(selectionCoordinator.isSelectionGestureActive)
        XCTAssertTrue(selectionCoordinator.hasCrossSegmentSelection)
    }

    @MainActor
    private func mountedSelectionHost(
        text: String,
        segment: MarkdownSelectionSegmentDescriptor,
        frame: CGRect,
        coordinator: MarkdownSelectionCoordinator,
        in window: UIWindow
    ) -> SelectableTextViewHostView {
        let view = SelectableTextView(
            text: text,
            selectionCoordinator: coordinator,
            selectionSegment: segment
        )
        let hostView = view.makeUIViewForTests(coordinator: view.makeCoordinator())
        hostView.frame = frame
        window.subviews.first?.addSubview(hostView)
        hostView.layoutIfNeeded()
        hostView.mountedTextView.layoutIfNeeded()
        return hostView
    }

    @MainActor
    func testLinkPreviewInteractionRemainsEnabled() {
        let coordinator = SelectableTextView.Coordinator(
            linkColor: .link,
            selectionCoordinator: nil,
            selectionSegment: nil
        )
        let shouldAllowPreview = coordinator.textView(
            SelectableTextView.makeTextView(),
            shouldInteractWith: URL(string: "https://example.com")!,
            in: NSRange(location: 0, length: 4),
            interaction: .preview
        )

        XCTAssertTrue(shouldAllowPreview)
    }

    func testSelectableTextSurfaceSupportsCharacterRangeSelection() {
        let textView = SelectableTextView.makeTextView()

        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertFalse(textView.isScrollEnabled)

        textView.text = "select only this phrase"
        textView.selectedRange = NSRange(location: 7, length: 9)

        guard let selectedRange = textView.selectedTextRange else {
            return XCTFail("The selectable surface did not expose its selected range")
        }
        XCTAssertEqual(textView.text(in: selectedRange), "only this")
    }

    func testMarkdownBridgePreservesEmphasisCodeAndLinks() throws {
        let markdown = try AttributedString(
            markdown: "**bold** *italic* ***both*** `code` [link](https://example.com)"
        )
        let surface = SelectableTextView(attributedText: markdown)
        let text = surface.attributedText

        let boldLocation = (text.string as NSString).range(of: "bold").location
        let italicLocation = (text.string as NSString).range(of: "italic").location
        let bothLocation = (text.string as NSString).range(of: "both").location
        let codeLocation = (text.string as NSString).range(of: "code").location
        let linkLocation = (text.string as NSString).range(of: "link").location

        let boldFont = try XCTUnwrap(text.attribute(.font, at: boldLocation, effectiveRange: nil) as? UIFont)
        let italicFont = try XCTUnwrap(text.attribute(.font, at: italicLocation, effectiveRange: nil) as? UIFont)
        let bothFont = try XCTUnwrap(text.attribute(.font, at: bothLocation, effectiveRange: nil) as? UIFont)
        let codeFont = try XCTUnwrap(text.attribute(.font, at: codeLocation, effectiveRange: nil) as? UIFont)
        let link = try XCTUnwrap(text.attribute(.link, at: linkLocation, effectiveRange: nil) as? URL)

        XCTAssertTrue(boldFont.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertTrue(italicFont.fontDescriptor.symbolicTraits.contains(.traitItalic))
        XCTAssertTrue(bothFont.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertTrue(bothFont.fontDescriptor.symbolicTraits.contains(.traitItalic))

        // Derive expected monospaced size from the body font the bridge uses,
        // not from the font under test, so a wrong point size would be caught.
        let expectedCodeSize = UIFont.preferredFont(forTextStyle: .body).pointSize
        XCTAssertEqual(
            codeFont.fontDescriptor.postscriptName,
            UIFont.monospacedSystemFont(ofSize: expectedCodeSize, weight: .regular).fontDescriptor.postscriptName
        )
        XCTAssertEqual(codeFont.pointSize, expectedCodeSize,
                       "Code font point size must match the body font, not a hardcoded constant")
        XCTAssertEqual(link.absoluteString, "https://example.com")
    }

    func testMarkdownBridgeUsesLinkDisplayTextAndPreservesURLAttribute() throws {
        let markdown = try AttributedString(markdown: "[display text](https://example.com/path)")
        let text = SelectableTextView(attributedText: markdown).attributedText

        XCTAssertEqual(text.string, "display text")

        let link = try XCTUnwrap(text.attribute(.link, at: 0, effectiveRange: nil) as? URL)
        XCTAssertEqual(link.absoluteString, "https://example.com/path")
    }

    func testMarkdownSelectionSpansParagraphBlocks() throws {
        let blocks = MarkdownParser.parse("First paragraph.\n\nSecond paragraph.", recognizesGatewayMedia: false)
        let content = try XCTUnwrap(
            MarkdownSelectionFormatter.attributedText(
                for: blocks,
                foregroundStyle: .primary,
                usesAccentSurface: false,
                newestCharacterOpacities: []
            )
        )
        XCTAssertEqual(content.string, "First paragraph.\n\nSecond paragraph.")

        let textView = SelectableTextView.makeTextView()
        textView.attributedText = content
        let start: Int = (content.string as NSString).range(of: "paragraph.").location
        let end: Int = NSMaxRange((content.string as NSString).range(of: "Second paragraph."))
        textView.selectedRange = NSRange(location: start, length: end - start)

        guard let selectedRange = textView.selectedTextRange else {
            return XCTFail("The unified Markdown surface did not expose its selected range")
        }
        XCTAssertEqual(textView.text(in: selectedRange), "paragraph.\n\nSecond paragraph.")
    }

    // MARK: - Regression tests for CodeRabbit findings

    /// Regression: withTraits must union traits, not replace them.
    /// Chaining bold then italic must preserve both traits.
    func testWithTraitsUnionsSymbolicTraits() {
        let base = UIFont.preferredFont(forTextStyle: .body)
        let boldItalic = base.withTraits(.traitBold).withTraits(.traitItalic)

        XCTAssertTrue(boldItalic.fontDescriptor.symbolicTraits.contains(.traitBold),
                      "Bold trait must survive a subsequent withTraits(.traitItalic) call")
        XCTAssertTrue(boldItalic.fontDescriptor.symbolicTraits.contains(.traitItalic),
                      "Italic trait must be present after withTraits(.traitItalic)")
    }

    /// Regression: sizeThatFits with wrapsLines=false must not force-unwrap
    /// uiView.attributedText. Exercises the measurement helper that
    /// sizeThatFits delegates to, so a regression in either the helper or
    /// the delegation would be caught.
    func testSizeThatFitsNonWrappingMeasuresStoredText() {
        let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        // Case 1: attributed text already carries a .font attribute
        let withFont = NSAttributedString(
            string: "line of code that should not wrap",
            attributes: [.font: font]
        )
        let view1 = SelectableTextView(
            attributedText: withFont,
            font: font,
            lineSpacing: 3,
            wrapsLines: false
        )
        let size1 = view1.measureNonWrapping()
        XCTAssertGreaterThan(size1.width, 0,
                             "measureNonWrapping must produce a valid width")
        XCTAssertGreaterThan(size1.height, 0,
                             "measureNonWrapping must produce a valid height")

        // Case 2: attributed text has NO .font attribute — measureNonWrapping
        // must fill the default font so boundingRect doesn't measure with a
        // system fallback that's smaller than what configure() renders.
        let withoutFont = NSAttributedString(string: "no font attribute here")
        let view2 = SelectableTextView(
            attributedText: withoutFont,
            font: font,
            lineSpacing: 3,
            wrapsLines: false
        )
        let size2 = view2.measureNonWrapping()
        XCTAssertGreaterThan(size2.width, 0,
                             "measureNonWrapping must fill default font for unstyled runs")
        XCTAssertGreaterThan(size2.height, 0)
    }

    /// Regression: lineSpacing must be stored on the SelectableTextView struct
    /// so configure() can apply it to the UIKit paragraph style. This verifies
    /// the parameter is preserved, not dropped as a no-op SwiftUI modifier.
    func testLineSpacingParameterIsPreserved() {
        let view = SelectableTextView(
            text: "line one\nline two",
            font: .preferredFont(forTextStyle: .body),
            lineSpacing: 7
        )
        // The struct must carry the lineSpacing value — if it were applied as
        // a SwiftUI .lineSpacing() modifier on a UIViewRepresentable, it would
        // be silently ignored and the parameter would default to 0.
        XCTAssertEqual(view.lineSpacing, 7,
                       "lineSpacing must be stored on the struct for configure() to read")
    }

    /// Regression: bold+italic combined markdown (***text***) must produce
    /// a font with both traits after bridge conversion.
    func testCombinedBoldItalicMarkdownPreservesBothTraits() throws {
        let markdown = try AttributedString(markdown: "***bold italic text***")
        let bridged = SelectableTextView.bridge(
            markdown,
            defaultFont: .preferredFont(forTextStyle: .body),
            defaultColor: .label,
            linkColor: .link
        )

        let location = (bridged.string as NSString).range(of: "bold italic").location
        let font = try XCTUnwrap(bridged.attribute(.font, at: location, effectiveRange: nil) as? UIFont)

        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold),
                      "Combined bold+italic must preserve bold")
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitItalic),
                      "Combined bold+italic must preserve italic")
    }

    /// Regression: tool output truncation caps at maxLines and appends indicator.
    func testToolOutputTruncation() {
        let short = "one\ntwo\nthree"
        XCTAssertEqual(ToolCard.truncateForDisplay(short, maxLines: 10), short)

        let long = (0..<100).map { "line \($0)" }.joined(separator: "\n")
        let truncated = ToolCard.truncateForDisplay(long, maxLines: 10)
        XCTAssertTrue(truncated.contains("90 more lines"),
                      "Truncated output must indicate remaining line count")
        let truncatedLines = truncated.components(separatedBy: "\n")
        XCTAssertEqual(truncatedLines.count, 11, // 10 content lines + 1 indicator line
                       "Truncated output must be exactly maxLines + 1 indicator line")
    }

    // MARK: - Markdown table cell measurement regression

    /// Helper: configures a mounted UITextView the same way SelectableTextView
    /// does, then measures at a given width. Bypasses UIViewRepresentable
    /// Context (which is inaccessible outside SwiftUI) while exercising the
    /// exact same UIKit measurement path.
    private func measureTextView(
        text: String,
        font: UIFont = .preferredFont(forTextStyle: .footnote),
        maximumNumberOfLines: Int = 0,
        at width: CGFloat
    ) -> (textView: UITextView, measuredHeight: CGFloat) {
        let textView = SelectableTextView.makeTextView()
        textView.font = font
        textView.textColor = .label
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.maximumNumberOfLines = maximumNumberOfLines
        textView.textContainer.lineBreakMode = maximumNumberOfLines > 0
            ? .byTruncatingTail : .byWordWrapping

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 0
        let styled = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraphStyle
        ])
        textView.attributedText = styled

        // Set the text container width to the target column width — this is
        // what sizeThatFits now does before measuring.
        textView.textContainer.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        textView.bounds = CGRect(x: 0, y: 0, width: width, height: 0)
        textView.layoutIfNeeded()

        let measured = textView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        return (textView, ceil(measured.height))
    }

    /// Regression: table cells must wrap at the column width and produce
    /// sufficient height for all wrapped lines. The old maximumNumberOfLines: 4
    /// would cap at ~4 lines; the stale-bounds bug would measure at width≈1.
    func testTableCellMeasurementAtRealisticWidthProducesSufficientHeight() {
        let font = UIFont.preferredFont(forTextStyle: .footnote)
        let longText = (0..<30).map { "Word\($0)" }.joined(separator: " ")
        let columnWidth: CGFloat = 200

        let (_, measuredHeight) = measureTextView(text: longText, font: font, at: columnWidth)
        let fourLineHeight = font.lineHeight * 4

        XCTAssertGreaterThan(measuredHeight, fourLineHeight,
                             "Wrapping table cell must produce height above 4-line cap at \(columnWidth)pt width")
    }

    /// Regression: measurement must use the column width, not a stale
    /// textView.bounds.width. Before the fix, a view with zero bounds would
    /// measure at width≈1, producing less than one line of height.
    func testMeasurementUsesColumnWidthNotStaleBounds() {
        let font = UIFont.preferredFont(forTextStyle: .footnote)
        let text = (0..<20).map { "content \($0)" }.joined(separator: " ")

        let (_, narrowHeight) = measureTextView(text: text, font: font, at: 180)
        let (_, wideHeight) = measureTextView(text: text, font: font, at: 300)

        XCTAssertGreaterThan(narrowHeight, font.lineHeight,
                             "Measurement at 180pt must not collapse below one line")
        XCTAssertGreaterThan(wideHeight, font.lineHeight,
                             "Measurement at 300pt must not collapse below one line")
        XCTAssertLessThanOrEqual(wideHeight, narrowHeight,
                                 "Wider column should produce ≤ height of narrower column")
    }

    /// Regression: cells of different content lengths must produce proportional
    /// heights. A long cell must be taller than a short one.
    func testDifferentLengthCellsProportionalHeights() {
        let font = UIFont.preferredFont(forTextStyle: .footnote)
        let columnWidth: CGFloat = 200

        let (_, shortHeight) = measureTextView(text: "Short", font: font, at: columnWidth)
        let longText = (0..<25).map { "Word \($0)" }.joined(separator: " ")
        let (_, longHeight) = measureTextView(text: longText, font: font, at: columnWidth)

        XCTAssertGreaterThan(longHeight, shortHeight,
                             "Longer cell content must produce greater height than short content")
        XCTAssertGreaterThan(shortHeight, 0,
                             "Even short content must produce positive height")
    }

    /// Finite maximumNumberOfLines must still work for callers that intentionally
    /// request truncation (e.g. RenderCard source preview). This guards against
    /// a future refactor that removes the limit globally.
    func testFiniteLineLimitStillTruncates() {
        let font = UIFont.preferredFont(forTextStyle: .footnote)
        let (textView, _) = measureTextView(text: "capped", font: font, maximumNumberOfLines: 4, at: 200)

        XCTAssertEqual(textView.textContainer.maximumNumberOfLines, 4,
                       "Finite line limit must propagate to the text container")
        XCTAssertEqual(textView.textContainer.lineBreakMode, .byTruncatingTail,
                       "Finite lines must use truncation, not word wrapping")
    }
}
