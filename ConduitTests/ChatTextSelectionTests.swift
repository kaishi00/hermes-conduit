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
        XCTAssertEqual(link.absoluteString, "https://example.com")
    }

    func testMarkdownSelectionSpansParagraphBlocks() throws {
        let content = try XCTUnwrap(
            MarkdownText.selectableAttributedText(for: "First paragraph.\n\nSecond paragraph.")
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
    /// uiView.attributedText. It should measure the stored attributedText.
    func testSizeThatFitsNonWrappingDoesNotCrashWithoutUIView() {
        let text = "line of code that should not wrap"
        let view = SelectableTextView(
            text: text,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            wrapsLines: false
        )

        // This should not crash even though no UITextView has been created yet.
        let size = view.sizeThatFits(.unspecified, uiView: SelectableTextView.makeTextView(), context: SelectableTextView.Coordinator(linkColor: .link))
        XCTAssertGreaterThan(size?.width ?? 0, 0)
    }

    /// Regression: lineSpacing passed to SelectableTextView must reach the
    /// UIKit text container, not be lost as a no-op SwiftUI modifier.
    func testLineSpacingReachesUITextContainer() {
        let textView = SelectableTextView.makeTextView()
        let styled = NSAttributedString(
            string: "line one\nline two",
            attributes: [.font: UIFont.preferredFont(forTextStyle: .body)]
        )

        let view = SelectableTextView(
            attributedText: styled,
            font: .preferredFont(forTextStyle: .body),
            lineSpacing: 7
        )

        // Simulate what UIViewRepresentable does
        view.updateUIView(textView, context: SelectableTextView.Coordinator(linkColor: .link))

        let paragraph = textView.attributedText?.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle
        XCTAssertEqual(paragraph?.lineSpacing, 7,
                       "lineSpacing must be applied to the UIKit paragraph style, not a SwiftUI modifier")
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
        XCTAssertEqual(truncatedLines.count, 12, // 10 lines + separator + indicator
                       "Truncated output must be exactly maxLines + 1 indicator line")
    }
}
