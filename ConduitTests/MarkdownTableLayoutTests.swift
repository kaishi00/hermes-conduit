import XCTest
import UIKit
import SwiftUI
@testable import Conduit

final class MarkdownTableLayoutTests: XCTestCase {
    // MARK: - Table-wide column widths (unit)

    /// One width per column, driven by the longest cell anywhere in that
    /// column — header included — so rows with the longest value in
    /// different columns still share widths.
    @MainActor
    func testColumnWidthsAreSharedAcrossRowsAndHeaderParticipates() {
        let headers = ["A", "B", "C"]
        // Drivers sized to land mid-range (no clamp): each column's longest
        // value lives in a different row.
        let rows = [
            ["short", "column-two-driver-here", "ok"],
            ["column-one-driver-longer", "mid", "fine"],
            ["tiny", "", "x"],
        ]

        let widths = MarkdownTableLayout.columnWidths(headers: headers, rows: rows)

        XCTAssertEqual(widths.count, 3)
        for width in widths {
            XCTAssertTrue(MarkdownTableLayout.columnWidthRange.contains(width),
                          "Column width \(width) must stay inside the table column policy")
        }
        // Content-informed, not equal-width: A's longest value is longer than
        // B's, which is longer than C's clamp floor.
        XCTAssertGreaterThan(widths[0], widths[1])
        XCTAssertGreaterThan(widths[1], widths[2])
    }

    @MainActor
    func testColumnWidthsClampToPolicyBounds() {
        let narrow = MarkdownTableLayout.columnWidths(
            headers: ["a", "b"],
            rows: [["x", ""]]
        )
        XCTAssertTrue(narrow.allSatisfy { $0 == MarkdownTableLayout.columnWidthRange.lowerBound },
                      "Short/empty columns clamp to the minimum column width")

        let wide = MarkdownTableLayout.columnWidths(
            headers: ["a"],
            rows: [[String(repeating: "very-long-value ", count: 30)]]
        )
        XCTAssertEqual(wide[0], MarkdownTableLayout.columnWidthRange.upperBound,
                       "Over-long content clamps to the max width and wraps there")
    }

    // MARK: - Shared widths + wrap + scroll through the real view chain

    /// Renders a real table and asserts every cell in a column — header,
    /// long driver cells, short cells, and an empty cell — has the same
    /// rendered width, which is what keeps dividers aligned down the table.
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

        let cells = allTextViews(in: host.view)
        XCTAssertEqual(cells.count, 12, "3 headers + 3 rows × 3 columns")

        // Map marker → view. Markers identify every non-empty cell; the empty
        // cell is found by elimination.
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
        let shortA = try cell(containing: "aaa")
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

        window.isHidden = true
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

        window.isHidden = true
    }

    /// Wide tables stay horizontally scrollable: the table's backing scroll
    /// view content must exceed the viewport when columns run wide.
    @MainActor
    func testWideTableRemainsHorizontallyScrollable() throws {
        let source = """
        | One | Two | Three | Four | Five |
        |---|---|---|---|---|
        | \(String(repeating: "first-column ", count: 6)) | \(String(repeating: "second-column ", count: 6)) | \(String(repeating: "third-column ", count: 6)) | \(String(repeating: "fourth-column ", count: 6)) | \(String(repeating: "fifth-column ", count: 6)) |
        """
        let (host, window) = renderedTableHost(source: source)

        let scrollViews = allTextViewsDeep(in: host.view).compactMap { $0 as? UIScrollView }
        XCTAssertTrue(
            scrollViews.contains { $0.contentSize.width > $0.bounds.width + 10 },
            "A table wider than the viewport must be backed by a horizontally scrollable UIScrollView"
        )

        window.isHidden = true
    }

    // MARK: - Alignment reaches the text layout

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

        // Geometry: every laid-out line's glyph rect must sit at the aligned
        // position within the cell. Uses the layout manager's per-line glyph
        // bounding rects (container line fragments are always full width).
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

    @MainActor
    private func renderedTableHost(source: String) -> (UIHostingController<MarkdownText>, UIWindow) {
        let host = UIHostingController(rootView: MarkdownText(source: source))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
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
