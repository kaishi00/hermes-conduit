import Combine
import XCTest
import UIKit
@testable import Conduit

@MainActor
final class MarkdownSelectionCoordinatorTests: XCTestCase {
    func testMixedMarkdownPlanIncludesTableCellsRowMajorAndOneCodeSegment() {
        let blocks = MarkdownParser.parse(
            "Before\n\n| A | B |\n| --- | --- |\n| [link](https://example.com) | 2 |\n\n```swift\nlet x = 1\n```\n\nAfter",
            recognizesGatewayMedia: false
        )

        XCTAssertEqual(
            MarkdownSelectionSegmentPlan.descriptors(for: blocks).map(\.id),
            ["block-0", "block-1-table-r0-c0", "block-1-table-r0-c1", "block-1-table-r1-c0", "block-1-table-r1-c1", "block-2-code", "block-3"]
        )
    }

    func testCopiedAttributedTextAcrossParagraphTableAndCodePreservesSeparatorsAndLinkAttributes() throws {
        let blocks = MarkdownParser.parse(
            "Before\n\n| A | B |\n| --- | --- |\n| [link](https://example.com) | 2 |\n\n```swift\nlet x = 1\n```\n\nAfter",
            recognizesGatewayMedia: false
        )
        let descriptors = MarkdownSelectionSegmentPlan.descriptors(for: blocks)
        let coordinator = MarkdownSelectionCoordinator()
        coordinator.replaceSegments(descriptors, revision: "copy-rich-v1")

        func register(_ id: String, attributedText: NSAttributedString) throws {
            let descriptor = try XCTUnwrap(descriptors.first { $0.id == id })
            let textView = SelectableTextView.makeTextView()
            textView.attributedText = attributedText
            coordinator.register(descriptor: descriptor, textView: textView)
        }

        try register("block-0", attributedText: NSAttributedString(string: "Before"))
        try register("block-1-table-r0-c0", attributedText: NSAttributedString(string: "A"))
        try register("block-1-table-r0-c1", attributedText: NSAttributedString(string: "B"))
        try register(
            "block-1-table-r1-c0",
            attributedText: NSAttributedString(
                string: "link",
                attributes: [.link: URL(string: "https://example.com")!]
            )
        )
        try register("block-1-table-r1-c1", attributedText: NSAttributedString(string: "2"))
        try register("block-2-code", attributedText: NSAttributedString(string: "let x = 1"))

        let copied = coordinator.copiedAttributedText(
            from: MarkdownSelectionEndpoint(segmentID: "block-0", offset: 2),
            to: MarkdownSelectionEndpoint(segmentID: "block-2-code", offset: 9)
        )

        XCTAssertEqual(copied.string, "fore\n\nA | B\nlink | 2\n\nlet x = 1")

        let linkRange = (copied.string as NSString).range(of: "link")
        let link = try XCTUnwrap(copied.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL)
        XCTAssertEqual(link.absoluteString, "https://example.com")
    }

    func testCopiedAttributedTextPreservesIntermediateEmptyTableCellSeparators() {
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "table-r0-c0", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "table-r0-c1", order: 1, separatorBefore: " | "),
            MarkdownSelectionSegmentDescriptor(id: "table-r0-c2", order: 2, separatorBefore: " | ")
        ]
        let coordinator = MarkdownSelectionCoordinator()
        coordinator.replaceSegments(descriptors, revision: "empty-cell-middle-v1")

        let firstTextView = SelectableTextView.makeTextView()
        firstTextView.attributedText = NSAttributedString(string: "A")
        coordinator.register(descriptor: descriptors[0], textView: firstTextView)

        let emptyTextView = SelectableTextView.makeTextView()
        emptyTextView.attributedText = NSAttributedString(string: "")
        coordinator.register(descriptor: descriptors[1], textView: emptyTextView)

        let thirdTextView = SelectableTextView.makeTextView()
        thirdTextView.attributedText = NSAttributedString(string: "C")
        coordinator.register(descriptor: descriptors[2], textView: thirdTextView)

        XCTAssertEqual(
            coordinator.copiedAttributedText(
                from: MarkdownSelectionEndpoint(segmentID: "table-r0-c0", offset: 0),
                to: MarkdownSelectionEndpoint(segmentID: "table-r0-c2", offset: 1)
            ).string,
            "A |  | C"
        )
    }

    func testCopiedAttributedTextSuppressesBoundaryEmptyTableCells() {
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "table-r0-c0", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "table-r0-c1", order: 1, separatorBefore: " | "),
            MarkdownSelectionSegmentDescriptor(id: "table-r0-c2", order: 2, separatorBefore: " | ")
        ]
        let coordinator = MarkdownSelectionCoordinator()
        coordinator.replaceSegments(descriptors, revision: "empty-cell-boundary-v1")

        let firstTextView = SelectableTextView.makeTextView()
        firstTextView.attributedText = NSAttributedString(string: "")
        coordinator.register(descriptor: descriptors[0], textView: firstTextView)

        let secondTextView = SelectableTextView.makeTextView()
        secondTextView.attributedText = NSAttributedString(string: "B")
        coordinator.register(descriptor: descriptors[1], textView: secondTextView)

        let trailingEmptyTextView = SelectableTextView.makeTextView()
        trailingEmptyTextView.attributedText = NSAttributedString(string: "")
        coordinator.register(descriptor: descriptors[2], textView: trailingEmptyTextView)

        XCTAssertEqual(
            coordinator.copiedAttributedText(
                from: MarkdownSelectionEndpoint(segmentID: "table-r0-c0", offset: 0),
                to: MarkdownSelectionEndpoint(segmentID: "table-r0-c1", offset: 1)
            ).string,
            "B"
        )
        XCTAssertEqual(
            coordinator.copiedAttributedText(
                from: MarkdownSelectionEndpoint(segmentID: "table-r0-c1", offset: 0),
                to: MarkdownSelectionEndpoint(segmentID: "table-r0-c2", offset: 0)
            ).string,
            "B"
        )
    }

    func testRepeatedRegistrationOfSameTextViewDoesNotPublishVisibleState() {
        let descriptor = MarkdownSelectionSegmentDescriptor(id: "paragraph", order: 0, separatorBefore: "")
        let coordinator = MarkdownSelectionCoordinator()
        let cancellable = coordinator.objectWillChange.sink { XCTFail("Unchanged registration should not publish visible state") }
        defer { cancellable.cancel() }

        coordinator.replaceSegments([descriptor], revision: "idempotent-register-v1")

        let textView = SelectableTextView.makeTextView()
        textView.attributedText = NSAttributedString(string: "Stable")
        coordinator.register(descriptor: descriptor, textView: textView)
        coordinator.register(descriptor: descriptor, textView: textView)
    }

    func testRepeatedReplaceWithSameSegmentsDoesNotPublishVisibleState() {
        let descriptor = MarkdownSelectionSegmentDescriptor(id: "paragraph", order: 0, separatorBefore: "")
        let coordinator = MarkdownSelectionCoordinator()
        coordinator.replaceSegments([descriptor], revision: "same-revision-v1")

        let cancellable = coordinator.objectWillChange.sink { XCTFail("Unchanged replacement should not publish visible state") }
        defer { cancellable.cancel() }

        coordinator.replaceSegments([descriptor], revision: "same-revision-v1")
    }

    func testSegmentPlanLeavesBarrierBetweenSelectableSegmentsAroundMathBlock() {
        let descriptors = MarkdownSelectionSegmentPlan.descriptors(for: [
            .paragraph("First"),
            .math("x^2"),
            .paragraph("After")
        ])

        XCTAssertEqual(descriptors.map(\.id), ["block-0", "block-2"])
        XCTAssertEqual(descriptors.map(\.order), [0, 2])
    }

    func testMixedResponseUsesRenderedOrderAndSelectsEveryIntermediateSegment() {
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "paragraph", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "table-r0-c0", order: 1, separatorBefore: "\n"),
            MarkdownSelectionSegmentDescriptor(id: "table-r0-c1", order: 2, separatorBefore: " | "),
            MarkdownSelectionSegmentDescriptor(id: "code", order: 3, separatorBefore: "\n\n"),
            MarkdownSelectionSegmentDescriptor(id: "paragraph-2", order: 4, separatorBefore: "\n\n")
        ]
        let coordinator = MarkdownSelectionCoordinator()
        coordinator.replaceSegments(descriptors, revision: "mixed-v1")

        for descriptor in descriptors {
            let text: String
            switch descriptor.id {
            case "paragraph": text = "First paragraph."
            case "table-r0-c0": text = "A"
            case "table-r0-c1": text = "B"
            case "code": text = "let x = 1"
            case "paragraph-2": text = "After"
            default:
                XCTFail("Unexpected descriptor \(descriptor.id)")
                continue
            }

            let textView = SelectableTextView.makeTextView()
            textView.attributedText = NSAttributedString(string: text)
            coordinator.register(descriptor: descriptor, textView: textView)
        }

        XCTAssertEqual(
            coordinator.spans(
                from: MarkdownSelectionEndpoint(segmentID: "paragraph", offset: 6),
                to: MarkdownSelectionEndpoint(segmentID: "paragraph-2", offset: 3)
            ),
            [
                MarkdownSelectionSpan(segmentID: "paragraph", range: NSRange(location: 6, length: 10)),
                MarkdownSelectionSpan(segmentID: "table-r0-c0", range: NSRange(location: 0, length: 1)),
                MarkdownSelectionSpan(segmentID: "table-r0-c1", range: NSRange(location: 0, length: 1)),
                MarkdownSelectionSpan(segmentID: "code", range: NSRange(location: 0, length: 9)),
                MarkdownSelectionSpan(segmentID: "paragraph-2", range: NSRange(location: 0, length: 3))
            ]
        )
    }

    func testReverseSelectionNormalizesOnlyForRangeResolution() {
        let coordinator = MarkdownSelectionCoordinator()
        coordinator.replaceSegments([
            MarkdownSelectionSegmentDescriptor(id: "a", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "b", order: 1, separatorBefore: "\n\n")
        ], revision: "v1")

        let ordered = coordinator.orderedEndpoints(
            from: MarkdownSelectionEndpoint(segmentID: "b", offset: 5),
            to: MarkdownSelectionEndpoint(segmentID: "a", offset: 2)
        )
        XCTAssertEqual(ordered.start, MarkdownSelectionEndpoint(segmentID: "a", offset: 2))
        XCTAssertEqual(ordered.end, MarkdownSelectionEndpoint(segmentID: "b", offset: 5))
    }

    func testSelectionStopsAtBarrierCreatedByNonTextBlock() {
        let coordinator = MarkdownSelectionCoordinator()
        let descriptors = MarkdownSelectionSegmentPlan.descriptors(for: [
            .paragraph("First"),
            .math("x^2"),
            .paragraph("After")
        ])
        coordinator.replaceSegments(descriptors, revision: "math-barrier-v1")

        for descriptor in descriptors {
            let textView = SelectableTextView.makeTextView()
            switch descriptor.id {
            case "block-0":
                textView.attributedText = NSAttributedString(string: "First")
            case "block-2":
                textView.attributedText = NSAttributedString(string: "After")
            default:
                XCTFail("Unexpected descriptor \(descriptor.id)")
            }
            coordinator.register(descriptor: descriptor, textView: textView)
        }

        XCTAssertEqual(
            coordinator.spans(
                from: MarkdownSelectionEndpoint(segmentID: "block-0", offset: 1),
                to: MarkdownSelectionEndpoint(segmentID: "block-2", offset: 2)
            ),
            [
                MarkdownSelectionSpan(segmentID: "block-0", range: NSRange(location: 1, length: 4))
            ]
        )
    }

    func testReverseSelectionAcrossMathMermaidAndImageBarriersRetainsAnchorSideRun() {
        let coordinator = MarkdownSelectionCoordinator()
        let descriptors = MarkdownSelectionSegmentPlan.descriptors(for: [
            .paragraph("Before"),
            .math("x^2"),
            .paragraph("After math"),
            .code(language: "mermaid", source: "graph TD; A-->B;"),
            .paragraph("After mermaid"),
            .image(url: "https://example.com/image.png", alt: "diagram"),
            .paragraph("After image")
        ])
        coordinator.replaceSegments(descriptors, revision: "reverse-barriers-v1")

        let textByID = [
            "block-0": "Before",
            "block-2": "After math",
            "block-4": "After mermaid",
            "block-6": "After image"
        ]
        for descriptor in descriptors {
            let textView = SelectableTextView.makeTextView()
            textView.attributedText = NSAttributedString(string: textByID[descriptor.id] ?? "")
            coordinator.register(descriptor: descriptor, textView: textView)
        }

        XCTAssertEqual(
            coordinator.spans(
                from: MarkdownSelectionEndpoint(segmentID: "block-6", offset: 5),
                to: MarkdownSelectionEndpoint(segmentID: "block-0", offset: 1)
            ),
            [
                MarkdownSelectionSpan(segmentID: "block-6", range: NSRange(location: 0, length: 5))
            ]
        )
    }

    func testRevisionChangeRetainsStableRegistrationsUpdatesDescriptorsAndDropsRemovedIDs() {
        let originalDescriptors = [
            MarkdownSelectionSegmentDescriptor(id: "stable", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "retained", order: 1, separatorBefore: "\n\n"),
            MarkdownSelectionSegmentDescriptor(id: "removed", order: 2, separatorBefore: "\n\n")
        ]
        let coordinator = MarkdownSelectionCoordinator()

        coordinator.replaceSegments(originalDescriptors, revision: "revision-v1")

        let stableTextView = SelectableTextView.makeTextView()
        stableTextView.attributedText = NSAttributedString(string: "Old stable text")
        coordinator.register(descriptor: originalDescriptors[0], textView: stableTextView)

        let retainedTextView = SelectableTextView.makeTextView()
        retainedTextView.attributedText = NSAttributedString(string: "Old retained text")
        coordinator.register(descriptor: originalDescriptors[1], textView: retainedTextView)

        let removedTextView = SelectableTextView.makeTextView()
        removedTextView.attributedText = NSAttributedString(string: "Removed text")
        coordinator.register(descriptor: originalDescriptors[2], textView: removedTextView)

        coordinator.beginSelection(segmentID: "stable", offset: 4, windowPoint: .zero)
        coordinator.updateSelection(segmentID: "removed", offset: 3, windowPoint: CGPoint(x: 0, y: 20))
        XCTAssertTrue(coordinator.hasActiveSelection)

        stableTextView.attributedText = NSAttributedString(string: "New stable text")
        stableTextView.selectedRange = NSRange(location: 4, length: 3)
        retainedTextView.attributedText = NSAttributedString(string: "New retained text")

        let replacementDescriptors = [
            MarkdownSelectionSegmentDescriptor(id: "retained", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "stable", order: 1, separatorBefore: "\n\n")
        ]
        coordinator.replaceSegments(replacementDescriptors, revision: "revision-v2")

        XCTAssertFalse(coordinator.hasActiveSelection)
        XCTAssertEqual(coordinator.activeSpans, [])
        XCTAssertEqual(stableTextView.selectedRange.length, 0)
        XCTAssertEqual(removedTextView.selectedRange.length, 0)
        XCTAssertEqual(coordinator.text(for: "stable"), "New stable text")
        XCTAssertEqual(coordinator.text(for: "retained"), "New retained text")
        XCTAssertNil(coordinator.text(for: "removed"))
        XCTAssertEqual(
            coordinator.spans(
                from: MarkdownSelectionEndpoint(segmentID: "retained", offset: 0),
                to: MarkdownSelectionEndpoint(segmentID: "stable", offset: 3)
            ).map(\.segmentID),
            ["retained", "stable"]
        )
        XCTAssertEqual(
            coordinator.copiedAttributedText(
                from: MarkdownSelectionEndpoint(segmentID: "retained", offset: 0),
                to: MarkdownSelectionEndpoint(segmentID: "stable", offset: 3)
            ).string,
            "New retained text\n\nNew"
        )
    }

    func testInitialReplaceKeepsTextViewRegisteredBeforeHostAppear() {
        let descriptor = MarkdownSelectionSegmentDescriptor(id: "block-0", order: 0, separatorBefore: "")
        let coordinator = MarkdownSelectionCoordinator()
        let textView = SelectableTextView.makeTextView()
        textView.attributedText = NSAttributedString(string: "Mounted before host")

        coordinator.register(descriptor: descriptor, textView: textView)
        coordinator.replaceSegments([descriptor], revision: "source-v1")

        XCTAssertEqual(coordinator.text(for: descriptor.id), "Mounted before host")
    }

    func testCopiedAttributedTextSkipsEmptyLeadingSpanWithoutLeadingSeparator() {
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "paragraph", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "paragraph-2", order: 1, separatorBefore: "\n\n")
        ]
        let coordinator = MarkdownSelectionCoordinator()
        coordinator.replaceSegments(descriptors, revision: "copy-v1")

        let firstTextView = SelectableTextView.makeTextView()
        firstTextView.attributedText = NSAttributedString(string: "A")
        coordinator.register(descriptor: descriptors[0], textView: firstTextView)

        let secondTextView = SelectableTextView.makeTextView()
        secondTextView.attributedText = NSAttributedString(string: "B")
        coordinator.register(descriptor: descriptors[1], textView: secondTextView)

        XCTAssertEqual(
            coordinator.copiedAttributedText(
                from: MarkdownSelectionEndpoint(segmentID: "paragraph", offset: 1),
                to: MarkdownSelectionEndpoint(segmentID: "paragraph-2", offset: 1)
            ).string,
            "B"
        )
    }

    func testSameSegmentSelectionNormalizesAndClampsOffsets() {
        let descriptor = MarkdownSelectionSegmentDescriptor(id: "paragraph", order: 0, separatorBefore: "")
        let coordinator = MarkdownSelectionCoordinator()
        coordinator.replaceSegments([descriptor], revision: "same-segment-v1")

        let textView = SelectableTextView.makeTextView()
        textView.attributedText = NSAttributedString(string: "abc")
        coordinator.register(descriptor: descriptor, textView: textView)

        let ordered = coordinator.orderedEndpoints(
            from: MarkdownSelectionEndpoint(segmentID: "paragraph", offset: 9),
            to: MarkdownSelectionEndpoint(segmentID: "paragraph", offset: 1)
        )
        XCTAssertEqual(ordered.start, MarkdownSelectionEndpoint(segmentID: "paragraph", offset: 1))
        XCTAssertEqual(ordered.end, MarkdownSelectionEndpoint(segmentID: "paragraph", offset: 9))

        XCTAssertEqual(
            coordinator.spans(
                from: MarkdownSelectionEndpoint(segmentID: "paragraph", offset: 9),
                to: MarkdownSelectionEndpoint(segmentID: "paragraph", offset: 1)
            ),
            [
                MarkdownSelectionSpan(segmentID: "paragraph", range: NSRange(location: 1, length: 2))
            ]
        )
    }

    func testActiveCrossSegmentSelectionProducesActiveSpansAndCopiedText() {
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "first", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "second", order: 1, separatorBefore: "\n\n")
        ]
        let coordinator = MarkdownSelectionCoordinator()
        coordinator.replaceSegments(descriptors, revision: "active-selection-v1")

        let firstTextView = SelectableTextView.makeTextView()
        firstTextView.attributedText = NSAttributedString(string: "First")
        coordinator.register(descriptor: descriptors[0], textView: firstTextView)

        let secondTextView = SelectableTextView.makeTextView()
        secondTextView.attributedText = NSAttributedString(string: "Second")
        coordinator.register(descriptor: descriptors[1], textView: secondTextView)

        coordinator.beginSelection(
            segmentID: "first",
            offset: 2,
            windowPoint: CGPoint(x: 10, y: 10)
        )
        coordinator.updateSelection(
            segmentID: "second",
            offset: 3,
            windowPoint: CGPoint(x: 10, y: 40)
        )

        XCTAssertTrue(coordinator.hasActiveSelection)
        XCTAssertTrue(coordinator.hasCrossSegmentSelection)
        XCTAssertEqual(
            coordinator.activeSpans,
            [
                MarkdownSelectionSpan(segmentID: "first", range: NSRange(location: 2, length: 3)),
                MarkdownSelectionSpan(segmentID: "second", range: NSRange(location: 0, length: 3))
            ]
        )
        XCTAssertEqual(coordinator.copiedAttributedTextForActiveSelection().string, "rst\n\nSec")

        coordinator.clearSelection()

        XCTAssertFalse(coordinator.hasActiveSelection)
        XCTAssertFalse(coordinator.hasCrossSegmentSelection)
        XCTAssertEqual(coordinator.activeSpans, [])
    }

    func testEndingGesturePreservesSelectionRangesAndCoordinatedCopy() {
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "first", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "second", order: 1, separatorBefore: "\n\n")
        ]
        let coordinator = MarkdownSelectionCoordinator()
        coordinator.replaceSegments(descriptors, revision: "gesture-end-v1")

        let firstTextView = SelectableTextView.makeTextView()
        firstTextView.attributedText = NSAttributedString(string: "First")
        coordinator.register(descriptor: descriptors[0], textView: firstTextView)

        let secondTextView = SelectableTextView.makeTextView()
        secondTextView.attributedText = NSAttributedString(string: "Second")
        coordinator.register(descriptor: descriptors[1], textView: secondTextView)

        coordinator.beginSelection(segmentID: "first", offset: 2, windowPoint: CGPoint(x: 0, y: 0))
        coordinator.updateSelection(segmentID: "second", offset: 3, windowPoint: CGPoint(x: 0, y: 10))

        coordinator.endSelection()

        XCTAssertTrue(coordinator.hasActiveSelection)
        XCTAssertTrue(coordinator.hasCrossSegmentSelection)
        XCTAssertEqual(firstTextView.selectedRange, NSRange(location: 2, length: 3))
        XCTAssertEqual(secondTextView.selectedRange, NSRange(location: 0, length: 3))
        XCTAssertEqual(coordinator.copiedAttributedTextForActiveSelection().string, "rst\n\nSec")

        coordinator.clearSelection()

        XCTAssertFalse(coordinator.hasActiveSelection)
        XCTAssertEqual(firstTextView.selectedRange, NSRange(location: 2, length: 0))
        XCTAssertEqual(secondTextView.selectedRange, NSRange(location: 0, length: 0))
        XCTAssertEqual(coordinator.copiedAttributedTextForActiveSelection().string, "")
    }

    func testOwnerNativeReportWhileFocusIsInAnotherSegmentDoesNotCollapseSelection() {
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "first", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "second", order: 1, separatorBefore: "\n\n")
        ]
        let coordinator = MarkdownSelectionCoordinator()
        coordinator.replaceSegments(descriptors, revision: "owner-clobber-v1")

        let firstTextView = SelectableTextView.makeTextView()
        firstTextView.attributedText = NSAttributedString(string: "First")
        coordinator.register(descriptor: descriptors[0], textView: firstTextView)

        let secondTextView = SelectableTextView.makeTextView()
        secondTextView.attributedText = NSAttributedString(string: "Second")
        coordinator.register(descriptor: descriptors[1], textView: secondTextView)

        coordinator.beginSelection(segmentID: "first", offset: 2, windowPoint: .zero)
        coordinator.updateSelection(segmentID: "second", offset: 3, windowPoint: CGPoint(x: 0, y: 10))
        XCTAssertTrue(coordinator.hasCrossSegmentSelection)

        // While the drag focus sits in the second segment, the owner's
        // private gesture keeps reporting its own capped range; those stale
        // reports must not collapse the cross-block selection.
        coordinator.updateNativeSelection(
            segmentID: "first",
            selectedRange: NSRange(location: 2, length: 3),
            lowerWindowPoint: .zero,
            upperWindowPoint: .zero
        )

        XCTAssertTrue(coordinator.hasCrossSegmentSelection)
        XCTAssertEqual(
            coordinator.activeSpans.map(\.segmentID),
            ["first", "second"]
        )

        // Dragging back into the owner re-enables native reports there.
        coordinator.updateSelection(segmentID: "first", offset: 4, windowPoint: CGPoint(x: 0, y: 0))
        coordinator.updateNativeSelection(
            segmentID: "first",
            selectedRange: NSRange(location: 2, length: 3),
            lowerWindowPoint: .zero,
            upperWindowPoint: .zero
        )
        XCTAssertEqual(
            coordinator.activeSpans,
            [MarkdownSelectionSpan(segmentID: "first", range: NSRange(location: 2, length: 3))]
        )
    }

    func testPostLiftOwnerReportsDoNotCollapseCrossBlockSelection() {
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "first", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "second", order: 1, separatorBefore: "\n\n")
        ]
        let coordinator = MarkdownSelectionCoordinator()
        coordinator.replaceSegments(descriptors, revision: "post-lift-collapse-v1")

        let firstTextView = SelectableTextView.makeTextView()
        firstTextView.attributedText = NSAttributedString(string: "First")
        coordinator.register(descriptor: descriptors[0], textView: firstTextView)

        let secondTextView = SelectableTextView.makeTextView()
        secondTextView.attributedText = NSAttributedString(string: "Second")
        coordinator.register(descriptor: descriptors[1], textView: secondTextView)

        coordinator.beginSelection(segmentID: "first", offset: 2, windowPoint: .zero)
        coordinator.updateSelection(segmentID: "second", offset: 3, windowPoint: CGPoint(x: 0, y: 10))
        coordinator.endSelection()

        // After the finger lifts, the edit menu appearing (or a handle drag
        // ending out of bounds) makes the owner re-report its own range —
        // sometimes an empty caret. Those reports must not collapse the
        // cross-block selection the user is about to copy.
        coordinator.updateNativeSelection(
            segmentID: "first",
            selectedRange: NSRange(location: 2, length: 3),
            lowerWindowPoint: .zero,
            upperWindowPoint: .zero
        )
        coordinator.updateNativeSelection(
            segmentID: "first",
            selectedRange: NSRange(location: 2, length: 0),
            lowerWindowPoint: .zero,
            upperWindowPoint: .zero
        )

        XCTAssertTrue(coordinator.hasCrossSegmentSelection)
        XCTAssertEqual(coordinator.copiedAttributedTextForActiveSelection().string, "rst\n\nSec")

        // A fresh long-press on the owner's text still clears the old
        // selection and starts a new one.
        coordinator.beginPendingSelection(segmentID: "first", offset: 1, windowPoint: .zero)
        XCTAssertFalse(coordinator.hasActiveSelection)
    }

    func testEndingOutsideTheFirstSegmentProducesAForwardCrossBlockSelection() {
        let coordinator = MarkdownSelectionCoordinator()
        coordinator.replaceSegments([
            MarkdownSelectionSegmentDescriptor(id: "first", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "second", order: 1, separatorBefore: "\n\n")
        ], revision: "v1")
        coordinator.beginSelection(segmentID: "first", offset: 6, windowPoint: CGPoint(x: 20, y: 20))
        coordinator.updateSelection(segmentID: "second", offset: 4, windowPoint: CGPoint(x: 20, y: 120))

        XCTAssertTrue(coordinator.hasCrossSegmentSelection)
        XCTAssertEqual(coordinator.activeSpans.map(\.segmentID), ["first", "second"])
    }

    func testHostGestureWindowPointResolvesCurrentRegisteredTextView() {
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "first", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "second", order: 1, separatorBefore: "\n\n")
        ]
        let coordinator = MarkdownSelectionCoordinator()
        let window = makeSelectionWindow()
        let firstTextView = mountedTextView(text: "Anchor", frame: CGRect(x: 10, y: 10, width: 180, height: 40), in: window)
        let secondTextView = mountedTextView(text: "Focus", frame: CGRect(x: 10, y: 80, width: 180, height: 40), in: window)

        coordinator.replaceSegments(descriptors, revision: "geometry-v1")
        coordinator.register(descriptor: descriptors[0], textView: firstTextView)
        coordinator.register(descriptor: descriptors[1], textView: secondTextView)

        coordinator.beginSelection(segmentID: "first", offset: 3, windowPoint: CGPoint(x: 18, y: 20))
        coordinator.updateSelection(windowPoint: CGPoint(x: 18, y: 90))

        XCTAssertEqual(coordinator.activeSpans.map(\.segmentID), ["first", "second"])
    }

    func testHighlightRectsUseCurrentWindowGeometryForNonNativeOwnerSegments() {
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "first", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "second", order: 1, separatorBefore: "\n\n")
        ]
        let coordinator = MarkdownSelectionCoordinator()
        let window = makeSelectionWindow()
        let firstTextView = mountedTextView(text: "Anchor", frame: CGRect(x: 10, y: 10, width: 180, height: 40), in: window)
        let secondTextView = mountedTextView(text: "Focus", frame: CGRect(x: 10, y: 80, width: 180, height: 40), in: window)

        coordinator.replaceSegments(descriptors, revision: "highlights-v1")
        coordinator.register(descriptor: descriptors[0], textView: firstTextView)
        coordinator.register(descriptor: descriptors[1], textView: secondTextView)
        coordinator.beginSelection(segmentID: "first", offset: 1, windowPoint: CGPoint(x: 18, y: 20))
        coordinator.updateSelection(segmentID: "second", offset: 2, windowPoint: CGPoint(x: 28, y: 90))

        // The owner claims first responder, then a cross-segment selection
        // dismisses it: a non-first-responder view renders no native
        // selection, and the overlay covers every span so the coordinator's
        // visual is the only one.
        _ = firstTextView.becomeFirstResponder()
        XCTAssertTrue(firstTextView.isFirstResponder)

        coordinator.applySelectionRanges()

        XCTAssertFalse(firstTextView.isFirstResponder, "Owner native chrome must be dismissed for cross-block selections")
        let rects = coordinator.highlightRects(in: window)
        XCTAssertFalse(rects.isEmpty)
        XCTAssertTrue(rects.contains { $0.maxY <= firstTextView.frame.maxY + 1 }, "Owner span must be covered by the overlay")
        XCTAssertTrue(rects.contains { $0.minY >= secondTextView.frame.minY - 1 }, "Other spans must be covered too")
    }

    func testHighlightRectsCoverOwnerSpanOnceNativeChromeIsDismissed() {
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "first", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "second", order: 1, separatorBefore: "\n\n")
        ]
        let coordinator = MarkdownSelectionCoordinator()
        let window = makeSelectionWindow()
        let firstTextView = mountedTextView(text: "Anchor", frame: CGRect(x: 10, y: 10, width: 180, height: 40), in: window)
        let secondTextView = mountedTextView(text: "Focus", frame: CGRect(x: 10, y: 80, width: 180, height: 40), in: window)

        coordinator.replaceSegments(descriptors, revision: "highlights-rest-v1")
        coordinator.register(descriptor: descriptors[0], textView: firstTextView)
        coordinator.register(descriptor: descriptors[1], textView: secondTextView)
        coordinator.beginSelection(segmentID: "first", offset: 1, windowPoint: CGPoint(x: 18, y: 20))
        coordinator.updateSelection(segmentID: "second", offset: 2, windowPoint: CGPoint(x: 28, y: 90))
        _ = firstTextView.becomeFirstResponder()
        coordinator.endSelection()
        XCTAssertFalse(firstTextView.isFirstResponder)

        let rects = coordinator.highlightRects(in: window)

        // At rest the owner span must be covered by the overlay too.
        XCTAssertTrue(rects.contains { $0.minY >= firstTextView.frame.minY && $0.maxY <= firstTextView.frame.maxY })
        XCTAssertTrue(rects.contains { $0.minY >= secondTextView.frame.minY && $0.maxY <= secondTextView.frame.maxY })
    }

    func testWindowPointInGapBetweenBlocksResolvesToNearestSegment() {
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "first", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "second", order: 1, separatorBefore: "\n\n")
        ]
        let coordinator = MarkdownSelectionCoordinator()
        let window = makeSelectionWindow()
        let firstTextView = mountedTextView(text: "Anchor", frame: CGRect(x: 10, y: 10, width: 180, height: 40), in: window)
        let secondTextView = mountedTextView(text: "Focus", frame: CGRect(x: 10, y: 80, width: 180, height: 40), in: window)

        coordinator.replaceSegments(descriptors, revision: "gap-fallback-v1")
        coordinator.register(descriptor: descriptors[0], textView: firstTextView)
        coordinator.register(descriptor: descriptors[1], textView: secondTextView)

        coordinator.beginSelection(segmentID: "first", offset: 3, windowPoint: CGPoint(x: 18, y: 20))
        // (18, 70) sits in the dead zone between the two text views, nearer
        // the second; the focus must advance instead of freezing.
        coordinator.updateSelection(windowPoint: CGPoint(x: 18, y: 70))

        XCTAssertTrue(coordinator.hasCrossSegmentSelection)
        XCTAssertEqual(coordinator.activeSpans.map(\.segmentID), ["first", "second"])
    }

    func testAnchorHandleDragMovesAnchorWhileFocusStaysPut() {
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "first", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "second", order: 1, separatorBefore: "\n\n")
        ]
        let coordinator = MarkdownSelectionCoordinator()
        let window = makeSelectionWindow()
        let firstTextView = mountedTextView(text: "Anchor", frame: CGRect(x: 10, y: 10, width: 180, height: 40), in: window)
        let secondTextView = mountedTextView(text: "Focus", frame: CGRect(x: 10, y: 80, width: 180, height: 40), in: window)

        coordinator.replaceSegments(descriptors, revision: "anchor-drag-v1")
        coordinator.register(descriptor: descriptors[0], textView: firstTextView)
        coordinator.register(descriptor: descriptors[1], textView: secondTextView)

        coordinator.beginSelection(segmentID: "first", offset: 2, windowPoint: CGPoint(x: 18, y: 20))
        coordinator.updateSelection(segmentID: "second", offset: 3, windowPoint: CGPoint(x: 18, y: 90))
        XCTAssertEqual(coordinator.activeSpans.map(\.segmentID), ["first", "second"])

        // Dragging the anchor handle into the second segment moves the
        // anchor; the focus endpoint is untouched.
        coordinator.updateAnchorSelection(segmentID: "second", offset: 5, windowPoint: CGPoint(x: 150, y: 90))
        XCTAssertEqual(coordinator.activeAnchorEndpoint?.segmentID, "second")
        XCTAssertEqual(coordinator.activeAnchorEndpoint?.offset, 5)
        XCTAssertEqual(coordinator.activeFocusEndpoint, MarkdownSelectionEndpoint(segmentID: "second", offset: 3))
        XCTAssertEqual(coordinator.activeSpans.map(\.segmentID), ["second"])
    }

    func testCaretRectTracksEndpointOffsetsWithinTheTextView() {
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "first", order: 0, separatorBefore: "")
        ]
        let coordinator = MarkdownSelectionCoordinator()
        let window = makeSelectionWindow()
        let textView = mountedTextView(text: "Anchor", frame: CGRect(x: 10, y: 10, width: 180, height: 40), in: window)

        coordinator.replaceSegments(descriptors, revision: "caret-rect-v1")
        coordinator.register(descriptor: descriptors[0], textView: textView)

        let start = coordinator.caretRect(for: MarkdownSelectionEndpoint(segmentID: "first", offset: 0), in: window)
        let end = coordinator.caretRect(for: MarkdownSelectionEndpoint(segmentID: "first", offset: 5), in: window)

        XCTAssertNotNil(start)
        XCTAssertNotNil(end)
        if let start, let end {
            XCTAssertLessThan(start.midX, end.midX, "Caret rect should advance with the offset")
            XCTAssertGreaterThanOrEqual(start.minY, textView.frame.minY - 1)
            XCTAssertLessThanOrEqual(end.maxY, textView.frame.maxY + 1)
        }
    }

    func testEndSelectionResignsOwnerFirstResponderForCrossSegmentSelections() {
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "first", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "second", order: 1, separatorBefore: "\n\n")
        ]
        let coordinator = MarkdownSelectionCoordinator()
        let window = makeSelectionWindow()
        let firstTextView = mountedTextView(text: "Anchor", frame: CGRect(x: 10, y: 10, width: 180, height: 40), in: window)
        let secondTextView = mountedTextView(text: "Focus", frame: CGRect(x: 10, y: 80, width: 180, height: 40), in: window)

        coordinator.replaceSegments(descriptors, revision: "resign-owner-v1")
        coordinator.register(descriptor: descriptors[0], textView: firstTextView)
        coordinator.register(descriptor: descriptors[1], textView: secondTextView)

        coordinator.beginSelection(segmentID: "first", offset: 2, windowPoint: .zero)
        coordinator.updateSelection(segmentID: "second", offset: 3, windowPoint: CGPoint(x: 0, y: 10))
        XCTAssertTrue(coordinator.hasCrossSegmentSelection)

        _ = firstTextView.becomeFirstResponder()
        XCTAssertTrue(firstTextView.isFirstResponder)

        coordinator.endSelection()

        XCTAssertFalse(firstTextView.isFirstResponder, "Cross-block selections drop native first-responder chrome at rest")
        XCTAssertTrue(coordinator.hasCrossSegmentSelection)
        XCTAssertEqual(secondTextView.selectedRange, NSRange(location: 0, length: 3), "Programmatic spans must survive the resign")
    }

    func testRevisionChangeClearsActiveSelectionState() {
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "first", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "second", order: 1, separatorBefore: "\n\n")
        ]
        let coordinator = MarkdownSelectionCoordinator()
        coordinator.replaceSegments(descriptors, revision: "active-selection-v1")

        let firstTextView = SelectableTextView.makeTextView()
        firstTextView.attributedText = NSAttributedString(string: "First")
        coordinator.register(descriptor: descriptors[0], textView: firstTextView)

        let secondTextView = SelectableTextView.makeTextView()
        secondTextView.attributedText = NSAttributedString(string: "Second")
        coordinator.register(descriptor: descriptors[1], textView: secondTextView)

        coordinator.beginSelection(segmentID: "first", offset: 1, windowPoint: CGPoint(x: 0, y: 0))
        coordinator.updateSelection(segmentID: "second", offset: 2, windowPoint: CGPoint(x: 0, y: 10))

        XCTAssertTrue(coordinator.hasActiveSelection)

        coordinator.replaceSegments([
            MarkdownSelectionSegmentDescriptor(id: "replacement", order: 0, separatorBefore: "")
        ], revision: "active-selection-v2")

        XCTAssertFalse(coordinator.hasActiveSelection)
        XCTAssertFalse(coordinator.hasCrossSegmentSelection)
        XCTAssertEqual(coordinator.activeSpans, [])
        XCTAssertEqual(coordinator.copiedAttributedTextForActiveSelection().string, "")
    }

    func testRevisionChangeClearsStaleSelectionAndRegistrations() {
        let coordinator = MarkdownSelectionCoordinator()
        coordinator.replaceSegments([
            MarkdownSelectionSegmentDescriptor(id: "old", order: 0, separatorBefore: "")
        ], revision: "old")
        coordinator.beginSelection(segmentID: "old", offset: 0, windowPoint: .zero)
        coordinator.replaceSegments([
            MarkdownSelectionSegmentDescriptor(id: "new", order: 0, separatorBefore: "")
        ], revision: "new")

        XCTAssertFalse(coordinator.hasActiveSelection)
        XCTAssertNil(coordinator.text(for: "old"))
    }

    func testUnregisteringASelectedSegmentClearsActiveSelection() {
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "first", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "second", order: 1, separatorBefore: "\n\n")
        ]
        let coordinator = MarkdownSelectionCoordinator()
        coordinator.replaceSegments(descriptors, revision: "unregister-active-v1")

        let firstTextView = SelectableTextView.makeTextView()
        firstTextView.attributedText = NSAttributedString(string: "First")
        coordinator.register(descriptor: descriptors[0], textView: firstTextView)

        let secondTextView = SelectableTextView.makeTextView()
        secondTextView.attributedText = NSAttributedString(string: "Second")
        coordinator.register(descriptor: descriptors[1], textView: secondTextView)

        coordinator.beginSelection(segmentID: "first", offset: 2, windowPoint: .zero)
        coordinator.updateSelection(segmentID: "second", offset: 3, windowPoint: CGPoint(x: 0, y: 10))

        coordinator.unregister(segmentID: "first", textView: firstTextView)

        XCTAssertFalse(coordinator.hasActiveSelection)
        XCTAssertFalse(coordinator.hasCrossSegmentSelection)
        XCTAssertEqual(firstTextView.selectedRange, NSRange(location: 2, length: 0))
        XCTAssertEqual(secondTextView.selectedRange, NSRange(location: 0, length: 0))
    }

    func testActivatingNewResponseSelectionClearsPreviousResponseSelection() {
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "first", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "second", order: 1, separatorBefore: "\n\n")
        ]
        let firstCoordinator = MarkdownSelectionCoordinator()
        let secondCoordinator = MarkdownSelectionCoordinator()
        firstCoordinator.replaceSegments(descriptors, revision: "first-response-v1")
        secondCoordinator.replaceSegments(descriptors, revision: "second-response-v1")

        for descriptor in descriptors {
            let firstTextView = SelectableTextView.makeTextView()
            firstTextView.attributedText = NSAttributedString(string: descriptor.id == "first" ? "First" : "Second")
            firstCoordinator.register(descriptor: descriptor, textView: firstTextView)

            let secondTextView = SelectableTextView.makeTextView()
            secondTextView.attributedText = NSAttributedString(string: descriptor.id == "first" ? "Alpha" : "Beta")
            secondCoordinator.register(descriptor: descriptor, textView: secondTextView)
        }

        firstCoordinator.beginSelection(segmentID: "first", offset: 2, windowPoint: .zero)
        firstCoordinator.updateSelection(segmentID: "second", offset: 3, windowPoint: CGPoint(x: 0, y: 10))
        XCTAssertTrue(firstCoordinator.hasCrossSegmentSelection)

        secondCoordinator.beginSelection(segmentID: "first", offset: 1, windowPoint: .zero)
        secondCoordinator.updateSelection(segmentID: "second", offset: 2, windowPoint: CGPoint(x: 0, y: 10))

        XCTAssertFalse(firstCoordinator.hasActiveSelection)
        XCTAssertTrue(secondCoordinator.hasCrossSegmentSelection)
    }

    private func makeSelectionWindow() -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 240, height: 180))
        let rootView = UIView(frame: window.bounds)
        window.addSubview(rootView)
        window.isHidden = false
        rootView.layoutIfNeeded()
        return window
    }

    private func mountedTextView(text: String, frame: CGRect, in window: UIWindow) -> UITextView {
        let textView = SelectableTextView.makeTextView()
        textView.attributedText = NSAttributedString(
            string: text,
            attributes: [.font: UIFont.preferredFont(forTextStyle: .body)]
        )
        textView.frame = frame
        window.subviews.first?.addSubview(textView)
        textView.layoutIfNeeded()
        _ = textView.layoutManager.glyphRange(for: textView.textContainer)
        return textView
    }
}
