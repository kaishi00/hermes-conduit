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
            markdown: "**bold** *italic* `code` [link](https://example.com)"
        )
        let surface = SelectableTextView(attributedText: markdown)
        let text = surface.attributedText

        let boldLocation = (text.string as NSString).range(of: "bold").location
        let italicLocation = (text.string as NSString).range(of: "italic").location
        let codeLocation = (text.string as NSString).range(of: "code").location
        let linkLocation = (text.string as NSString).range(of: "link").location

        let boldFont = try XCTUnwrap(text.attribute(.font, at: boldLocation, effectiveRange: nil) as? UIFont)
        let italicFont = try XCTUnwrap(text.attribute(.font, at: italicLocation, effectiveRange: nil) as? UIFont)
        let codeFont = try XCTUnwrap(text.attribute(.font, at: codeLocation, effectiveRange: nil) as? UIFont)
        let link = try XCTUnwrap(text.attribute(.link, at: linkLocation, effectiveRange: nil) as? URL)

        XCTAssertTrue(boldFont.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertTrue(italicFont.fontDescriptor.symbolicTraits.contains(.traitItalic))
        XCTAssertEqual(codeFont.fontDescriptor.postscriptName, UIFont.monospacedSystemFont(ofSize: codeFont.pointSize, weight: .regular).fontDescriptor.postscriptName)
        XCTAssertEqual(link.absoluteString, "https://example.com")
    }
}
