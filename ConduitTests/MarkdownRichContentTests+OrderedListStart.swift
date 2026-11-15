//
//  MarkdownRichContentTests+OrderedListStart.swift
//  Conduit
//
//  An ordered list starts at the number written on its first item, as in
//  CommonMark and Hermes Desktop. Steps split by a code block ("1. Install",
//  the code, "2. Run") carry on 1, 2 rather than restarting at 1, and a
//  list written from "4." draws 4, 5, 6.
//

import SwiftUI
import XCTest
@testable import Conduit

extension MarkdownRichContentPolicyTests {
    func testOrderedListKeepsItsFirstNumber() {
        XCTAssertEqual(MarkdownParser.parse("4. four\n5. five"), [.orderedList(["four", "five"], start: 4)])
        XCTAssertEqual(MarkdownParser.parse("1. one\n2. two"), [.orderedList(["one", "two"])])
        XCTAssertEqual(MarkdownParser.parse("0) zero"), [.orderedList(["zero"], start: 0)])
    }

    func testOrderedListNumbersFollowTheFirstItemOnly() {
        // Later numbers don't matter, as in CommonMark: "1. 1. 1." counts up.
        XCTAssertEqual(MarkdownParser.parse("1. a\n1. b\n1. c"), [.orderedList(["a", "b", "c"])])
    }

    func testOverlongOrderedNumberIsText() {
        // CommonMark: a list marker has at most nine digits.
        XCTAssertEqual(MarkdownParser.parse("1234567890. far"), [.paragraph("1234567890. far")])
        XCTAssertEqual(MarkdownParser.parse("123456789. near"), [.orderedList(["near"], start: 123456789)])
        XCTAssertEqual(MarkdownParser.parse("٤. four"), [.paragraph("٤. four")])
    }

    func testStepsSplitByACodeBlockCarryOn() {
        let blocks = MarkdownParser.parse("1. Install:\n\n```sh\nmake install\n```\n\n2. Run:\n\n```sh\nmake run\n```")
        XCTAssertEqual(blocks, [
            .orderedList(["Install:"]),
            .code(language: "sh", source: "make install"),
            .orderedList(["Run:"], start: 2),
            .code(language: "sh", source: "make run")
        ])
    }

    func testOrderedListDrawsFromItsStart() throws {
        let drawn = try XCTUnwrap(MarkdownSelectionFormatter.attributedText(
            for: MarkdownParser.parse("7. seven\n8. eight"),
            foregroundStyle: .primary,
            usesAccentSurface: false,
            newestCharacterOpacities: []
        ))
        // The marker hangs in its gutter, a tab from the text, and copies
        // with a space.
        XCTAssertEqual(drawn.string, "7.\tseven\n8.\teight")
        XCTAssertEqual(MarkdownProseRun.copyableText(drawn).string, "7. seven\n8. eight")
    }

    func testNestedListsKeepTheirDepth() {
        let blocks = MarkdownParser.parse("""
        1. Install
           - brew install foo
           - or build it
             1. clone
             2. make
        2. Run
        - after
        """)
        XCTAssertEqual(blocks, [
            .orderedList(["Install"]),
            .unorderedList(["brew install foo", "or build it"], depth: 1),
            .orderedList(["clone", "make"], depth: 2),
            .orderedList(["Run"], start: 2),
            .unorderedList(["after"])
        ])
        // Two-space bullets and tabs nest too; one space is the same list.
        XCTAssertEqual(MarkdownParser.parse("- a\n  - b\n\t- c\n- d"), [
            .unorderedList(["a"]),
            .unorderedList(["b"], depth: 1),
            .unorderedList(["c"], depth: 2),
            .unorderedList(["d"])
        ])
        XCTAssertEqual(MarkdownParser.parse("- a\n - b"), [.unorderedList(["a", "b"])])
        // Back out of a sub-list, the parent keeps counting even when every
        // item is written "1.".
        XCTAssertEqual(MarkdownParser.parse("1. A\n   - child\n1. B\n   1. x\n   1. y\n1. C"), [
            .orderedList(["A"]),
            .unorderedList(["child"], depth: 1),
            .orderedList(["B"], start: 2),
            .orderedList(["x", "y"], depth: 1),
            .orderedList(["C"], start: 3)
        ])
        // A ")" list is another list, and a hidden board line ends the
        // outline: both start from their written number.
        XCTAssertEqual(MarkdownParser.parse("1. A\n   - child\n\n1) B"), [
            .orderedList(["A"]),
            .unorderedList(["child"], depth: 1),
            .orderedList(["B"])
        ])
        XCTAssertEqual(MarkdownParser.parse("1. A\n   - child\n::conduit-board{id=\"cb-0123456789ab\"}\n1. B\n   - next"), [
            .orderedList(["A"]),
            .unorderedList(["child"], depth: 1),
            .orderedList(["B"]),
            .unorderedList(["next"], depth: 1)
        ])
        // So does a line of only Hermes directives, which adds no block.
        XCTAssertEqual(MarkdownParser.parse("1. A\n   - child\n[[audio_as_voice]]\n1. B", recognizesGatewayMedia: true), [
            .orderedList(["A"]),
            .unorderedList(["child"], depth: 1),
            .orderedList(["B"])
        ])
        // A tagged item that starts a list after a sub-list still draws,
        // so it keeps the outline and the sub-list under it stays nested.
        XCTAssertEqual(MarkdownParser.parse("1. A\n   - child\n- B [[as_document]]\n  - next", recognizesGatewayMedia: true), [
            .orderedList(["A"]),
            .unorderedList(["child"], depth: 1),
            .unorderedList(["B"]),
            .unorderedList(["next"], depth: 1)
        ])
        // A paragraph between starts over at the left edge.
        XCTAssertEqual(MarkdownParser.parse("- a\n\nText\n\n  - b"), [
            .unorderedList(["a"]),
            .paragraph("Text"),
            .unorderedList(["b"])
        ])
    }

    func testNestedListDrawsAsAnOutline() throws {
        let blocks = MarkdownParser.parse("1. Install\n   - brew\n2. Run\n\nAfter.")
        let drawn = try XCTUnwrap(MarkdownSelectionFormatter.attributedText(
            for: blocks,
            foregroundStyle: .primary,
            usesAccentSurface: false,
            newestCharacterOpacities: []
        ))
        // One line apart inside the outline, a blank line after it.
        XCTAssertEqual(MarkdownProseRun.copyableText(drawn).string, "1. Install\n• brew\n2. Run\n\nAfter.")
        func style(at text: String) -> NSParagraphStyle? {
            drawn.attribute(.paragraphStyle, at: (drawn.string as NSString).range(of: text).location, effectiveRange: nil) as? NSParagraphStyle
        }
        let outer = try XCTUnwrap(style(at: "Install"))
        let inner = try XCTUnwrap(style(at: "brew"))
        let step = MarkdownProseRun.nestedListIndent(chatTextSize: .default)
        // A bullet's text is a step in at the left edge, so two steps a level in.
        XCTAssertEqual(inner.headIndent, 2 * step, accuracy: 0.5, "the sub-list's text sits a level in")
        XCTAssertGreaterThan(inner.firstLineHeadIndent, outer.firstLineHeadIndent, "and its marker past the outer one's")
        XCTAssertEqual(try XCTUnwrap(style(at: "Run")).headIndent, outer.headIndent, "back out to the outer list's column")
    }

    @MainActor
    func testProseRunNestsAnOutline() {
        let run = MarkdownProseRun.attributedText(
            for: MarkdownParser.parse("- a\n  - b\n- c")[...],
            references: .empty,
            foregroundStyle: .primary,
            usesAccentSurface: false,
            chatTextSize: .default
        )
        XCTAssertEqual(MarkdownProseRun.copyableText(run).string, "• a\n• b\n• c")
        let a = run.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let b = run.attribute(.paragraphStyle, at: (run.string as NSString).range(of: "b").location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual((b?.headIndent ?? 0) - (a?.headIndent ?? 0), MarkdownProseRun.nestedListIndent(chatTextSize: .default), accuracy: 0.5)
    }

    @MainActor
    func testProseRunDrawsAnOrderedListFromItsStart() {
        let run = MarkdownProseRun.attributedText(
            for: [MarkdownBlock.orderedList(["seven", "eight"], start: 7)][...],
            references: .empty,
            foregroundStyle: .primary,
            usesAccentSurface: false,
            chatTextSize: .default
        )
        XCTAssertTrue(run.string.hasPrefix("7.\tseven"), run.string)
        XCTAssertTrue(run.string.contains("8.\teight"), run.string)
    }

    func testLongListChunksCountFromItsStart() {
        let items = (0..<900).map { "item \($0) \(String(repeating: "text ", count: 12))" }
        let chunks = MarkdownLargeChunkPlanner.chunks(for: [.orderedList(items, start: 7)])
        XCTAssertGreaterThan(chunks.count, 1, "the list must split across chunks")
        var groups: [(start: Int, count: Int)] = []
        for case .flow(let blocks) in chunks {
            for block in blocks {
                switch block {
                case .orderedList(let group, let start, _):
                    groups.append((start, group.count))
                case .paragraph(let text):
                    XCTFail("a continuation is a list, not a paragraph: \(text.prefix(20))")
                default: break
                }
            }
        }
        XCTAssertGreaterThan(groups.count, 1)
        XCTAssertEqual(groups.first?.start, 7)
        // Each continuation starts where the chunk before it stopped, so the
        // list keeps its marker column and counts on one by one.
        var next = 7
        for group in groups {
            XCTAssertEqual(group.start, next)
            next += group.count
        }
        XCTAssertEqual(next, 7 + items.count)
    }

    func testOversizedFirstItemBakesItsStart() {
        let huge = String(repeating: "item prose ", count: 900)
        let chunks = MarkdownLargeChunkPlanner.chunks(for: [.orderedList([huge, "normal"], start: 7)])
        let texts = chunks.flatMap { chunk -> [String] in
            guard case .flow(let blocks) = chunk else { return [] }
            return blocks.compactMap { if case .paragraph(let text) = $0 { return text }; return nil }
        }
        XCTAssertTrue(texts.first?.hasPrefix("7. ") == true, "\(texts.first ?? "")")
        // The items after it carry on as a list from the next number.
        let lists = chunks.flatMap { chunk -> [MarkdownBlock] in
            guard case .flow(let blocks) = chunk else { return [] }
            return blocks.filter { if case .orderedList = $0 { return true }; return false }
        }
        XCTAssertEqual(lists, [.orderedList(["normal"], start: 8)])
    }
}
