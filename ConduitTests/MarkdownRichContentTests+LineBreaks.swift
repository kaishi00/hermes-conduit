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
        XCTAssertEqual(InlineMarkdownContent.keepingLineBreaks("a\nb"), "a  \nb")
        XCTAssertEqual(InlineMarkdownContent.keepingLineBreaks("a\n\nb"), "a\n\nb")
        XCTAssertEqual(InlineMarkdownContent.keepingLineBreaks("Title\n==="), "Title\n===")
        XCTAssertEqual(InlineMarkdownContent.keepingLineBreaks("Title\n===\nBody"), "Title\n===\nBody")
        XCTAssertEqual(InlineMarkdownContent.keepingLineBreaks("a\nb\n"), "a  \nb\n")
        // A "===" with no text above it is text, and its break stays.
        XCTAssertEqual(InlineMarkdownContent.keepingLineBreaks("===\nnext"), "===  \nnext")
    }

    func testAMarkdownDocumentKeepsSoftBreaks() {
        // A hard-wrapped README shown as a file flows as one paragraph.
        let document = MarkdownReferenceContext.empty.withLineBreaks(kept: false)
        let attributed = InlineMarkdownContent.attributed(source: "wrapped at\nseventy-eight", references: document)
        XCTAssertEqual(String(attributed.characters), "wrapped at seventy-eight")
    }

    @MainActor
    func testTheRenderCacheKeepsRepliesAndDocumentsApart() throws {
        func text(_ keeps: Bool) throws -> String {
            let rendering = MarkdownRenderCache.rendering(
                source: "first line\nsecond line",
                recognizesGatewayMedia: false,
                foregroundStyle: .primary,
                usesAccentSurface: false,
                isStreaming: false,
                chatTextSize: .default,
                keepsLineBreaks: keeps
            )
            XCTAssertEqual(rendering.references.keepsLineBreaks, keeps)
            return try XCTUnwrap(rendering.selectableText).string
        }
        XCTAssertEqual(try text(true), "first line\nsecond line")
        XCTAssertEqual(try text(false), "first line second line")
        XCTAssertEqual(try text(true), "first line\nsecond line")
    }

    func testALargeDocumentCarriesItsLineBreakChoiceToEveryChunk() async throws {
        let paragraph = String(repeating: "word ", count: 40) + "\nnext line"
        let source = Array(repeating: paragraph, count: 600).joined(separator: "\n\n")
        let keptPlan = await LargeMarkdownPreparedDocument.prepare(source)
        let flowingPlan = await LargeMarkdownPreparedDocument.prepare(source, keepsLineBreaks: false)
        let kept = try XCTUnwrap(keptPlan)
        let flowing = try XCTUnwrap(flowingPlan)
        XCTAssertTrue(kept.references.keepsLineBreaks)
        XCTAssertTrue(kept.referencesByChunk.allSatisfy(\.keepsLineBreaks))
        XCTAssertFalse(flowing.references.keepsLineBreaks)
        XCTAssertFalse(flowing.referencesByChunk.contains(where: \.keepsLineBreaks))
    }

    func testABackslashWithASpaceAfterItIsTextAndTheBreakStays() {
        let attributed = InlineMarkdownContent.attributed(source: "a\\ \nb", references: .empty)
        XCTAssertEqual(String(attributed.characters), "a\\\nb")
    }

    func testLinksAndCodeSpansRunAcrossABreakWithNothingShowing() throws {
        let link = InlineMarkdownContent.attributed(source: "[docs](\nhttps://example.com) here", references: .empty)
        XCTAssertEqual(String(link.characters), "docs here")
        let docs = try XCTUnwrap(link.characters.firstRange(of: "docs"))
        XCTAssertEqual(link[docs].link?.absoluteString, "https://example.com")

        let code = InlineMarkdownContent.attributed(source: "`one\ntwo`", references: .empty)
        XCTAssertFalse(String(code.characters).contains("\\"), String(code.characters))
    }

    func testManyShortLinesKeepEveryBreak() {
        let lines = (1...2000).map(String.init).joined(separator: "\n")
        let attributed = InlineMarkdownContent.attributed(source: lines, references: .empty)
        XCTAssertEqual(String(attributed.characters), lines)
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
