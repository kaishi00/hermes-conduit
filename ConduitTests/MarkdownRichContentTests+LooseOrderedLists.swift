//
//  MarkdownRichContentTests+LooseOrderedLists.swift
//  Conduit
//
//  An ordered list with blank lines between its items is one list, as in
//  CommonMark and Hermes Desktop, so it numbers 1, 2, 3 and not 1, 1, 1
//  (#1163). Every place that shows Markdown numbers each list block from
//  one, so the parser keeping the list whole is the fix for all of them.
//

import SwiftUI
import XCTest
@testable import Conduit

extension MarkdownRichContentPolicyTests {
    func testBlankLinesBetweenOrderedItemsKeepOneList() {
        let blocks = MarkdownParser.parse("1. first\n\n2. second\n\n3. third")
        XCTAssertEqual(blocks, [.orderedList(["first", "second", "third"])])
    }

    func testLooseOrderedListToleratesSeveralBlankLines() {
        let blocks = MarkdownParser.parse("1. first\n\n\n2. second\n   \n3. third")
        XCTAssertEqual(blocks, [.orderedList(["first", "second", "third"])])
    }

    func testLooseOrderedListEndsAtOtherContent() {
        let blocks = MarkdownParser.parse("1. first\n\n2. second\n\nAfter the list.\n\n1. again")
        XCTAssertEqual(blocks, [
            .orderedList(["first", "second"]),
            .paragraph("After the list."),
            .orderedList(["again"])
        ])
    }

    func testLooseOrderedListEndsAtADifferentDelimiter() {
        // CommonMark: "1." and "1)" are different lists.
        let blocks = MarkdownParser.parse("1. first\n\n2) second")
        XCTAssertEqual(blocks, [.orderedList(["first"]), .orderedList(["second"])])
    }

    func testLooseOrderedListEndsAtADifferentIndent() {
        let blocks = MarkdownParser.parse("1. first\n\n   1. nested")
        XCTAssertEqual(blocks, [.orderedList(["first"]), .orderedList(["nested"])])
    }

    func testBlankLinesStillSplitAnOrderedListFromABulletList() {
        let blocks = MarkdownParser.parse("1. first\n\n- bullet")
        XCTAssertEqual(blocks, [.orderedList(["first"]), .unorderedList(["bullet"])])
    }

    func testTrailingBlankLinesAfterAnOrderedListAreHarmless() {
        let blocks = MarkdownParser.parse("1. first\n2. second\n\n")
        XCTAssertEqual(blocks, [.orderedList(["first", "second"])])
    }

    func testLooseOrderedListDrawsSequentialNumbers() {
        let blocks = MarkdownParser.parse((1...15).map { "\($0). Reference \($0)" }.joined(separator: "\n\n"))
        guard blocks.count == 1, case .orderedList(let items) = blocks[0] else {
            return XCTFail("Expected one ordered list, got \(blocks)")
        }
        XCTAssertEqual(items.count, 15)
        let drawn = MarkdownSelectionFormatter.attributedText(
            for: blocks,
            foregroundStyle: .primary,
            usesAccentSurface: false,
            newestCharacterOpacities: []
        )?.string ?? ""
        XCTAssertTrue(drawn.hasPrefix("1. Reference 1\n2. Reference 2"), drawn)
        XCTAssertTrue(drawn.hasSuffix("15. Reference 15"), drawn)
    }
}
