//
//  MarkdownRichContentTests+LineBreaks.swift
//  Conduit
//
//  A single line break in a reply stays a line break, as chat apps draw it:
//  "Count to 30, one number per line" came back as one wrapped line of
//  numbers, because CommonMark makes a lone newline a soft break and
//  Foundation draws that as a space. Every view that draws a reply's text
//  parses it through InlineMarkdownContent, so these check it there and in
//  the two ways a chat lays it out.
//

import SwiftUI
import XCTest
@testable import Conduit

extension MarkdownRichContentPolicyTests {
    func testSingleLineBreaksStayLineBreaks() {
        let numbers = (1...30).map(String.init).joined(separator: "\n")
        let attributed = InlineMarkdownContent.attributed(source: numbers, references: .empty)
        XCTAssertEqual(String(attributed.characters), numbers)
    }

    func testEmphasisRunsAcrossALineBreak() throws {
        let attributed = InlineMarkdownContent.attributed(source: "**one\ntwo** after", references: .empty)
        XCTAssertEqual(String(attributed.characters), "one\ntwo after")
        let bold = try XCTUnwrap(attributed.characters.firstRange(of: "two"))
        XCTAssertEqual(attributed[bold].inlinePresentationIntent, .stronglyEmphasized)
    }

    func testWrittenHardBreaksDrawOneBreakAndNoBackslash() {
        for (source, drawn) in [
            ("a\\\nb", "a\nb"),
            ("a  \nb", "a\nb"),
            ("a   \nb", "a\nb"),
            ("a \nb", "a\nb"),
            ("ends in an escaped backslash \\\\\nb", "ends in an escaped backslash \\\nb"),
        ] {
            let attributed = InlineMarkdownContent.attributed(source: source, references: .empty)
            XCTAssertEqual(String(attributed.characters), drawn, source)
        }
    }

    func testReferenceLinkResolvesInAParagraphWithLineBreaks() throws {
        let attributed = InlineMarkdownContent.attributed(
            source: "first line\nsecond [link][id] line",
            references: MarkdownReferenceContext(definitionsMarkdown: "[id]: https://example.com")
        )
        XCTAssertEqual(String(attributed.characters), "first line\nsecond link line")
        let range = try XCTUnwrap(attributed.characters.firstRange(of: "link"))
        XCTAssertEqual(attributed[range].link?.absoluteString, "https://example.com")
    }

    func testLineBreaksLeaveBlankLinesAndSetextUnderlinesAlone() {
        XCTAssertEqual(InlineMarkdownContent.keepingLineBreaks("one line"), "one line")
        XCTAssertEqual(InlineMarkdownContent.keepingLineBreaks("a\nb"), "a\\\nb")
        XCTAssertEqual(InlineMarkdownContent.keepingLineBreaks("a\n\nb"), "a\n\nb")
        XCTAssertEqual(InlineMarkdownContent.keepingLineBreaks("Title\n==="), "Title\n===")
        XCTAssertEqual(InlineMarkdownContent.keepingLineBreaks("a\nb\n"), "a\\\nb\n")
    }

    func testSelectableParagraphKeepsLineBreaks() throws {
        let text = try XCTUnwrap(MarkdownSelectionFormatter.attributedText(
            for: [.paragraph("1\n2\n3"), .orderedList(["first\nstill first"])],
            foregroundStyle: .primary,
            usesAccentSurface: false,
            newestCharacterOpacities: []
        ))
        XCTAssertTrue(text.string.hasPrefix("1\n2\n3\n\n"), text.string)
        XCTAssertTrue(text.string.contains("first\nstill first"), text.string)
        XCTAssertFalse(text.string.contains("\u{2028}"))
    }

    @MainActor
    func testProseRunKeepsLineBreaks() {
        let text = MarkdownProseRun.attributedText(
            for: [.paragraph("1\n2\n3")][...],
            references: .empty,
            foregroundStyle: .primary,
            usesAccentSurface: false,
            chatTextSize: .default
        )
        XCTAssertTrue(text.string.contains("1\n2\n3"), text.string)
    }
}
