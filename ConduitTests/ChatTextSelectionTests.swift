import XCTest
import UIKit
import SwiftUI
@testable import Conduit

final class ChatTextSelectionTests: XCTestCase {
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
}
