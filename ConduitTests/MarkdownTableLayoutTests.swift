import XCTest
import UIKit
import SwiftUI
@testable import Conduit

final class MarkdownTableLayoutTests: XCTestCase {
    // MARK: - Responsive width policy (pure distribution step)

    /// When the capped columns fit the available width, each column keeps its
    /// ideal width — genuinely narrow columns stay narrow.
    func testResolveKeepsIdealWidthsWhenTableFits() {
        let widths = MarkdownTableLayout.resolveColumnContentWidths(
            ideals: [140, 125, 30],
            availableWidth: 390
        )
        XCTAssertEqual(widths, [140, 125, 30])
    }

    /// Over-long content caps at the max column width and wraps there.
    func testResolveCapsWideColumns() {
        let widths = MarkdownTableLayout.resolveColumnContentWidths(
            ideals: [900],
            availableWidth: 390
        )
        XCTAssertEqual(widths, [MarkdownTableLayout.maxColumnContentWidth])
    }

    /// Overflowing tables shrink columns proportionally to their excess above
    /// the floor; wide columns give up more, narrow ones may not shrink.
    func testResolveShrinksProportionallyToExcess() {
        // overhead for 3 columns = 3×20 + 2×1 + 2 = 64 → available 236
        // total 295, deficit 59; shrinkable = 76 + 61 + 0 = 137 → factor ≈ 0.43
        let widths = MarkdownTableLayout.resolveColumnContentWidths(
            ideals: [140, 125, 30],
            availableWidth: 300
        )
        // Wide columns shrank; the already-narrow column is untouched.
        XCTAssertLessThan(widths[0], 140)
        XCTAssertLessThan(widths[1], 125)
        XCTAssertEqual(widths[2], 30, "Columns below the floor must not shrink")
        XCTAssertGreaterThan(widths[0], widths[1], "Wider columns keep proportionally more space")
        // Sum fits the available content width (allow half-point rounding).
        let overhead: CGFloat = 3 * 20 + 2 * 1 + 2
        XCTAssertLessThanOrEqual(widths.reduce(0, +), 300 - overhead + 1.5)
    }

    /// A genuinely wide table: everything compressible hits the floor and the
    /// table keeps horizontal scrolling rather than crushing to nothing.
    func testResolveFallsToFloorAndScrollsWhenDeficitExceedsShrinkable() {
        let widths = MarkdownTableLayout.resolveColumnContentWidths(
            ideals: [500, 500, 500, 500, 500],
            availableWidth: 390
        )
        XCTAssertEqual(widths, [64, 64, 64, 64, 64])
        XCTAssertEqual(widths[0], MarkdownTableLayout.shrinkFloorContentWidth)
        let overhead: CGFloat = 5 * 20 + 4 * 1 + 2
        XCTAssertGreaterThan(widths.reduce(0, +) + overhead, 390,
                             "At the floor the table still overflows and must scroll")
    }

    /// Unknown viewport (first layout pass): deterministic cap-and-scroll
    /// layout until the real width arrives.
    func testResolveWithUnknownWidthUsesCappedWidths() {
        let widths = MarkdownTableLayout.resolveColumnContentWidths(
            ideals: [900, 30],
            availableWidth: 0
        )
        XCTAssertEqual(widths, [MarkdownTableLayout.maxColumnContentWidth, 30])
    }

    /// Dynamic Type proxy: larger text metrics grow the ideal widths, and the
    /// resolved layout recomputes (fit → shrink as the same content gets
    /// wider relative to the viewport).
    func testResolveRecomputesWhenContentMetricsGrow() {
        let ideals: [CGFloat] = [100, 80]
        let scaled = ideals.map { $0 * 1.4 } // larger Dynamic Type → wider text

        XCTAssertEqual(MarkdownTableLayout.resolveColumnContentWidths(ideals: ideals, availableWidth: 320), [100, 80])
        let resolvedScaled = MarkdownTableLayout.resolveColumnContentWidths(ideals: scaled, availableWidth: 250)
        // Same viewport, wider content: the columns now compress instead of fitting.
        XCTAssertLessThan(resolvedScaled[0], scaled[0])
        XCTAssertLessThan(resolvedScaled[1], scaled[1])
    }

    // MARK: - Table-wide shared widths from real content

    /// One width per column, driven by the longest cell anywhere in that
    /// column — header included — so rows with the longest value in
    /// different columns still share widths.
    @MainActor
    func testColumnWidthsAreSharedAcrossRowsAndHeaderParticipates() {
        let headers = ["A", "B", "C"]
        // Drivers sized to land mid-range (no cap): each column's longest
        // value lives in a different row.
        let rows = [
            ["short", "column-two-driver-here", "ok"],
            ["column-one-driver-longer", "mid", "fine"],
            ["tiny", "", "x"],
        ]

        let widths = MarkdownTableLayout.columnWidths(headers: headers, rows: rows, availableWidth: 390)

        XCTAssertEqual(widths.count, 3)
        // Content-informed, not equal-width: A's longest value is longer than
        // B's, which is longer than C's tiny value — and the tiny column is
        // allowed to stay genuinely narrow.
        XCTAssertGreaterThan(widths[0], widths[1])
        XCTAssertGreaterThan(widths[1], widths[2])
        XCTAssertLessThan(widths[2], MarkdownTableLayout.shrinkFloorContentWidth,
                          "A tiny column must not be forced to the old 112pt floor")
        for width in widths {
            XCTAssertLessThanOrEqual(width, MarkdownTableLayout.maxColumnContentWidth)
        }
    }

    /// Regression: a reference-style link cell must be measured at its
    /// resolved label, not the raw `[label][id]` syntax. The message's
    /// reference definitions thread into column-width measurement through
    /// the same attributed-string construction InlineMarkdown renders.
    @MainActor
    func testReferenceStyleLinkCellMeasuresAtResolvedLabelWidth() {
        // Two columns: the parser's table delimiter requires at least two.
        let source = """
        | Docs | Note |
        |---|---|
        | [Handbook][1] | x |

        [1]: https://example.com/handbook
        """
        let document = MarkdownParser.parseDocument(source)
        guard case .table(let headers, _, let rows)? = document.blocks.first else {
            return XCTFail("Expected a table block")
        }
        XCTAssertTrue(document.references.containsDefinitions,
                      "The definition must be extracted into the reference context")

        let resolved = MarkdownTableLayout.columnWidths(
            headers: headers, rows: rows, availableWidth: 390, references: document.references
        )
        let literal = MarkdownTableLayout.columnWidths(
            headers: ["Docs"], rows: [["Handbook"]], availableWidth: 390
        )
        XCTAssertEqual(resolved[0], literal[0], accuracy: 2,
                       "Column width must match the resolved label's width")

        // Without the context (the pre-fix measurement), the raw syntax is
        // visibly wider than the label.
        let raw = MarkdownTableLayout.columnWidths(
            headers: headers, rows: rows, availableWidth: 390, references: .empty
        )
        XCTAssertLessThan(resolved[0], raw[0] - 5,
                          "Raw [label][id] measurement must be wider than the resolved label")
    }

    // MARK: - Rendered fixtures (full MarkdownText view chain)

    /// QA fixture: three tiny columns fit an iPhone viewport with no
    /// horizontal overflow.
    @MainActor
    func testTinyThreeColumnTableFitsViewportWithoutHorizontalScrolling() throws {
        let source = """
        | A | B | C |
        |---|---|---|
        | 1 | 2 | 3 |
        """
        let (host, window) = renderedTableHost(source: source)
        defer { window.isHidden = true }

        let cells = allTextViews(in: host.view)
        XCTAssertEqual(cells.count, 6, "3 headers + 1 row × 3 columns")

        // No cell is anywhere near the old 112pt floor.
        XCTAssertTrue(cells.allSatisfy { $0.bounds.width < MarkdownTableLayout.shrinkFloorContentWidth + 20 },
                      "Tiny columns must stay narrow")

        // The table fits: the horizontal scroll view has no overflow.
        let scrollViews = allTextViewsDeep(in: host.view).compactMap { $0 as? UIScrollView }
        let tableScroll = try XCTUnwrap(scrollViews.first)
        XCTAssertLessThanOrEqual(tableScroll.contentSize.width, tableScroll.bounds.width + 0.5,
                                 "A tiny table must not need horizontal scrolling")
    }

    /// QA fixture: a genuinely narrow status column beside a long description
    /// column — status stays narrow, description gets the wide share, and the
    /// table fits without scrolling.
    @MainActor
    func testNarrowStatusColumnBesideLongDescriptionColumnFits() throws {
        let source = """
        | Status | Description |
        |---|---|
        | OK | \(String(repeating: "a long description of the thing ", count: 3)) |
        | Retry | short |
        """
        let (host, window) = renderedTableHost(source: source)
        defer { window.isHidden = true }

        let cells = allTextViews(in: host.view)
        let statusCell = try XCTUnwrap(cells.first { $0.attributedText.string == "Retry" })
        let descriptionCell = try XCTUnwrap(cells.first { $0.attributedText.string.contains("a long description") })
        let descriptionHeader = try XCTUnwrap(cells.first { $0.attributedText.string == "Description" })

        XCTAssertLessThan(statusCell.bounds.width, MarkdownTableLayout.shrinkFloorContentWidth + 10,
                          "The narrow status column must stay narrow")
        XCTAssertGreaterThan(descriptionCell.bounds.width, statusCell.bounds.width * 2,
                             "The long description column gets proportionally more space")
        XCTAssertEqual(descriptionCell.bounds.width, descriptionHeader.bounds.width, accuracy: 0.5)
        XCTAssertLessThanOrEqual(descriptionCell.bounds.width, MarkdownTableLayout.maxColumnContentWidth)

        let scrollViews = allTextViewsDeep(in: host.view).compactMap { $0 as? UIScrollView }
        let tableScroll = try XCTUnwrap(scrollViews.first)
        XCTAssertLessThanOrEqual(tableScroll.contentSize.width, tableScroll.bounds.width + 0.5,
                                 "This table fits the viewport and must not scroll horizontally")
    }

    /// Regression, rendered: through the full MarkdownText chain, a
    /// reference-style link cell renders its resolved label as a link, and
    /// the column is sized to the label — identical to a table whose cell
    /// contains the label literally.
    @MainActor
    func testRenderedReferenceLinkTableSizesColumnAtLabelWidth() throws {
        let withLink = """
        | Name | Docs |
        |---|---|
        | Alpha | [Handbook][1] |

        [1]: https://example.com/handbook
        """
        let literal = """
        | Name | Docs |
        |---|---|
        | Alpha | Handbook |
        """
        let (linkHost, linkWindow) = renderedTableHost(source: withLink)
        let (literalHost, literalWindow) = renderedTableHost(source: literal)
        defer { linkWindow.isHidden = true; literalWindow.isHidden = true }

        let linkCell = try XCTUnwrap(
            allTextViews(in: linkHost.view).first { $0.attributedText.string == "Handbook" },
            "The reference link must render as its resolved label"
        )
        let link = try XCTUnwrap(
            linkCell.attributedText.attribute(.link, at: 0, effectiveRange: nil) as? URL,
            "The resolved label must carry the definition's URL"
        )
        XCTAssertEqual(link.absoluteString, "https://example.com/handbook")

        let literalCell = try XCTUnwrap(
            allTextViews(in: literalHost.view).first { $0.attributedText.string == "Handbook" }
        )
        XCTAssertEqual(linkCell.bounds.width, literalCell.bounds.width, accuracy: 1,
                       "The link column must be sized to the resolved label, not the raw [label][id] syntax")
    }

    /// QA fixture: a genuinely wide table still scrolls horizontally.
    @MainActor
    func testWideTableRemainsHorizontallyScrollable() throws {
        let source = """
        | One | Two | Three | Four | Five |
        |---|---|---|---|---|
        | \(String(repeating: "first-column ", count: 6)) | \(String(repeating: "second-column ", count: 6)) | \(String(repeating: "third-column ", count: 6)) | \(String(repeating: "fourth-column ", count: 6)) | \(String(repeating: "fifth-column ", count: 6)) |
        """
        let (host, window) = renderedTableHost(source: source)
        defer { window.isHidden = true }

        let scrollViews = allTextViewsDeep(in: host.view).compactMap { $0 as? UIScrollView }
        XCTAssertTrue(
            scrollViews.contains { $0.contentSize.width > $0.bounds.width + 10 },
            "A table wider than the viewport must be backed by a horizontally scrollable UIScrollView"
        )
    }

    /// Shared column widths through the real chain: every cell in a column —
    /// header, long driver cells, short cells, and an empty cell — renders at
    /// the same width, keeping dividers aligned down the table.
    @MainActor
    func testRenderedTableSharesColumnWidthsAcrossRowsIncludingEmptyCells() throws {
        let source = """
        | ColA | ColB | ColC |
        |:---|:---:|---:|
        | aaa | bbbb-col-two-driver | c |
        | aaaa-column-one-driver | b | cc |
        | a |  | c |
        """
        let (host, window) = renderedTableHost(source: source)
        defer { window.isHidden = true }

        let cells = allTextViews(in: host.view)
        XCTAssertEqual(cells.count, 12, "3 headers + 3 rows × 3 columns")

        func cell(containing marker: String) throws -> UITextView {
            for candidate in cells where candidate.attributedText.string.contains(marker) {
                return candidate
            }
            return try XCTUnwrap(nil, "No cell contains marker \(marker)")
        }

        let columnDriverA = try cell(containing: "column-one-driver")
        let columnDriverB = try cell(containing: "col-two-driver")
        let headerA = try cell(containing: "ColA")
        let headerB = try cell(containing: "ColB")
        // Exact match: the substring "aaa" also occurs in "aaaa-column-one-driver".
        let shortA = try XCTUnwrap(cells.first { $0.attributedText.string == "aaa" },
                                   "The lone short column-A cell must be findable by exact text")
        let shortB2 = try XCTUnwrap(cells.first { $0.attributedText.string == "b" },
                                    "The lone short column-B cell must be findable by exact text")

        // All column-A cells share one width.
        XCTAssertEqual(headerA.bounds.width, columnDriverA.bounds.width, accuracy: 0.5)
        XCTAssertEqual(shortA.bounds.width, columnDriverA.bounds.width, accuracy: 0.5)

        // All column-B cells share one (different) width.
        XCTAssertEqual(headerB.bounds.width, columnDriverB.bounds.width, accuracy: 0.5)
        XCTAssertGreaterThan(columnDriverA.bounds.width, columnDriverB.bounds.width,
                             "Columns are content-informed, not fixed equal widths")

        // The empty cell keeps column B's shared width. Identify it as the one
        // cell with empty text, then verify its x-position matches column B's
        // driver (same column band).
        let emptyCell = try XCTUnwrap(cells.first { $0.attributedText.string.isEmpty })
        XCTAssertEqual(emptyCell.bounds.width, columnDriverB.bounds.width, accuracy: 0.5,
                       "Empty cells must occupy the full shared column width")
        let columnBBand = columnDriverB.frame.minX...columnDriverB.frame.maxX
        XCTAssertTrue(columnBBand.contains(emptyCell.frame.minX),
                      "The empty cell must sit in the same column band as its column driver")

        // Dividers align because every cell in a column has equal width: the
        // right edges of column A's cells across different rows must agree.
        let rightEdges = [headerA, shortA, columnDriverA].map { $0.frame.maxX }
        XCTAssertEqual((rightEdges.max() ?? 0) - (rightEdges.min() ?? 0), 0, accuracy: 1,
                       "Column boundaries must not shift between rows")

        // Selection machinery stays attached to shared-width cells.
        XCTAssertTrue(cells.allSatisfy { cell in
            cell.gestureRecognizers?.contains { $0 is MarkdownSelectionObserverGestureRecognizer } == true
        }, "Table cells must keep the cross-block selection observer attached")
    }

    /// A long cell wraps at its shared column width and stays fully visible
    /// vertically; short cells in the same column keep the column width.
    @MainActor
    func testLongCellWrapsAtSharedColumnWidthAndStaysFullyVisible() throws {
        let longText = (0..<30).map { "Word\($0)" }.joined(separator: " ")
        let source = """
        | Item | Details |
        |---|---|
        | Short | \(longText) |
        | Also short | tiny |
        """
        let (host, window) = renderedTableHost(source: source)
        defer { window.isHidden = true }

        let cells = allTextViews(in: host.view)
        let longCell = try XCTUnwrap(cells.first { $0.attributedText.string.contains("Word29") })
        let headerDetails = try XCTUnwrap(cells.first { $0.attributedText.string == "Details" })
        let tinyCell = try XCTUnwrap(cells.first { $0.attributedText.string == "tiny" })

        // Shared width: header, long cell, and the short cell below all equal.
        XCTAssertEqual(longCell.bounds.width, headerDetails.bounds.width, accuracy: 0.5)
        XCTAssertEqual(tinyCell.bounds.width, headerDetails.bounds.width, accuracy: 0.5)

        // Unlimited lines and full vertical visibility at the shared width.
        XCTAssertEqual(longCell.textContainer.maximumNumberOfLines, 0)
        let reference = SelectableTextView.makeTextView()
        reference.attributedText = longCell.attributedText
        let fullWrapHeight = SelectableTextView.measuredWrappingHeight(of: reference, at: longCell.bounds.width)
        XCTAssertGreaterThanOrEqual(longCell.bounds.height + 1, fullWrapHeight,
                                    "Long cell must show every wrapped line at the shared column width")
    }

    /// `:---`, `:---:`, and `---:` must produce leading, centered, and
    /// trailing paragraph alignment on the real cell text views, and the
    /// geometry must hold for wrapped multiline content.
    @MainActor
    func testMarkdownAlignmentReachesTextLayoutForSingleLineAndWrappedCells() throws {
        let source = """
        | Left | Center | Right |
        |:---|:---:|---:|
        | left text | center text | right text |
        | wrap-left-alignment-value long enough to wrap across several lines inside its column | wrap-center-alignment-value long enough to wrap across several lines inside its column | wrap-right-alignment-value long enough to wrap across several lines inside its column |
        """
        let (host, window) = renderedTableHost(source: source)
        defer { window.isHidden = true }

        let cells = allTextViews(in: host.view)
        func cell(containing marker: String) throws -> UITextView {
            try XCTUnwrap(cells.first { $0.attributedText.string.contains(marker) })
        }

        // Paragraph style carries the alignment into the text engine.
        for (marker, expected) in [
            ("left text", NSTextAlignment.natural),
            ("center text", NSTextAlignment.center),
            ("right text", NSTextAlignment.right),
            ("wrap-left-alignment", NSTextAlignment.natural),
            ("wrap-center-alignment", NSTextAlignment.center),
            ("wrap-right-alignment", NSTextAlignment.right),
        ] {
            let view = try cell(containing: marker)
            let style = try XCTUnwrap(
                view.attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            )
            XCTAssertEqual(style.alignment, expected, "Cell '\(marker)' must carry \(expected) paragraph alignment")
        }

        // Geometry smoke check: every laid-out line's glyph rect sits at the
        // aligned position. Accessing `layoutManager` switches this test view
        // into TextKit-1 compatibility mode, so this measures compat layout —
        // an end-to-end sanity signal, not a TextKit-2-faithful measurement.
        // The paragraph-style assertions above are the production contract;
        // don't grow this block.
        func assertLines(_ view: UITextView, aligned: NSTextAlignment, marker: String) throws {
            let layoutManager = view.layoutManager
            let glyphRange = layoutManager.glyphRange(for: view.textContainer)
            var rects: [CGRect] = []
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, lineGlyphRange, _ in
                rects.append(layoutManager.boundingRect(forGlyphRange: lineGlyphRange, in: view.textContainer))
            }

            XCTAssertFalse(rects.isEmpty, "Cell '\(marker)' must lay out at least one line")
            for rect in rects {
                switch aligned {
                case .center:
                    XCTAssertEqual(rect.midX, view.bounds.width / 2, accuracy: 3,
                                   "Centered line must be centered in cell '\(marker)'")
                case .right:
                    XCTAssertEqual(rect.maxX, view.bounds.width, accuracy: 3,
                                   "Trailing line must end at the cell edge in '\(marker)'")
                default:
                    XCTAssertLessThanOrEqual(rect.minX, 3,
                                             "Leading line must start at the cell edge in '\(marker)'")
                }
            }
        }

        try assertLines(try cell(containing: "left text"), aligned: .natural, marker: "left")
        try assertLines(try cell(containing: "center text"), aligned: .center, marker: "center")
        try assertLines(try cell(containing: "right text"), aligned: .right, marker: "right")
        // Wrapped multiline cells: every wrapped line keeps the alignment.
        try assertLines(try cell(containing: "wrap-center-alignment"), aligned: .center, marker: "wrap-center")
        try assertLines(try cell(containing: "wrap-right-alignment"), aligned: .right, marker: "wrap-right")
    }

    // MARK: - Helpers

    /// Hosts the markdown and lets the width probe settle: the probe's state
    /// update lands a frame after the first layout pass, so pump the runloop
    /// and lay out again before asserting geometry.
    @MainActor
    private func renderedTableHost(source: String) -> (UIHostingController<MarkdownText>, UIWindow) {
        let host = UIHostingController(rootView: MarkdownText(source: source))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        let settled = XCTestExpectation(description: "width probe settles")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return (host, window)
    }

    private func allTextViews(in view: UIView) -> [UITextView] {
        allTextViewsDeep(in: view).compactMap { $0 as? UITextView }
    }

    private func allTextViewsDeep(in view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + allTextViewsDeep(in: $0) }
    }
}
