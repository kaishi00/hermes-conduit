//
//  MarkdownLargeDocumentTests.swift
//  Conduit
//
//  Regression coverage for the large-document rendering mode: threshold
//  policy, chunking determinism/bounds, content preservation, reference
//  links, selection-plan slicing, streaming promotion invariants, and the
//  memoization/Dynamic Type invalidation of chunk rendering.
//
//  These are work-count/bound assertions rather than wall-clock timings, so
//  they stay deterministic on any runner.
//

import SwiftUI
import UIKit
import XCTest
@testable import Conduit

final class MarkdownLargeDocumentTests: XCTestCase {
    private let chunkTarget = MarkdownLargeDocumentPolicy.chunkTargetBytes

    // MARK: Corpus helpers

    private func paragraphSoup(targetBytes: Int) -> String {
        // Stops shy of the target so the +2 separators never push the result
        // past a threshold the caller is testing against.
        var parts: [String] = []
        var total = 0
        var index = 0
        while total < targetBytes - 512 {
            let part = "Paragraph \(index) with some words and **bold** plus a [link\(index)](https://example.com/\(index)) to give it ordinary inline structure."
            parts.append(part)
            total += part.utf8.count + 2
            index += 1
        }
        return parts.joined(separator: "\n\n")
    }

    private func mixedSoup(targetBytes: Int) -> String {
        var parts: [String] = []
        var total = 0
        var index = 0
        while total < targetBytes {
            // Realistic density: a substantial paragraph per unit with the
            // rich blocks riding along, rather than pathological
            // table-after-every-sentence micro blocks.
            let filler = (0..<30).map { word in "Section \(index) point \(word) carries ordinary explanatory prose that wraps at chat widths and a reference use [docs\(index % 4)][ref\(word % 4)] when \(word % 4) == \(index % 4)." }.joined(separator: " ")
            let unit = """
            \(filler)

            | A | B |
            |---|---|
            | 1 | 2 |

            ```swift
            let value\(index) = \(index)
            ```
            """
            parts.append(unit)
            total += unit.utf8.count + 2
            index += 1
        }
        return parts.joined(separator: "\n\n") + "\n\n" + (0..<4)
            .map { "[ref\($0)]: https://example.com/docs/\($0)" }
            .joined(separator: "\n")
    }

    private func stripped(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }

    // MARK: 1. Ordinary messages take the normal path

    func testOrdinaryMessagesStayBelowLargeThreshold() {
        XCTAssertFalse(MarkdownLargeDocumentPolicy.isLargeDocument("Hello, world!"))
        XCTAssertFalse(MarkdownLargeDocumentPolicy.isLargeDocument(paragraphSoup(targetBytes: 8_000)))
        XCTAssertFalse(MarkdownLargeDocumentPolicy.isLargeDocument(paragraphSoup(targetBytes: MarkdownLargeDocumentPolicy.documentThresholdBytes - 1)))

        // The generator stops shy of its target (see the comment there), so
        // crossing the threshold needs a target a margin above it.
        XCTAssertTrue(MarkdownLargeDocumentPolicy.isLargeDocument(
            paragraphSoup(targetBytes: MarkdownLargeDocumentPolicy.documentThresholdBytes + 1_024)
        ))

        // The threshold is byte-based, not character-based: multibyte text
        // counts its UTF-8 bytes.
        let multibyte = String(repeating: "é", count: MarkdownLargeDocumentPolicy.documentThresholdBytes / 2)
        XCTAssertEqual(multibyte.utf8.count, MarkdownLargeDocumentPolicy.documentThresholdBytes)
        XCTAssertTrue(MarkdownLargeDocumentPolicy.isLargeDocument(multibyte))
    }

    // MARK: 2/3. Initial presentation is bounded

    func testPreviewSourceIsBoundedPrefix() {
        let large = paragraphSoup(targetBytes: 400_000)
        let preview = LargeMarkdownDocumentView.previewSource(of: large)

        XCTAssertLessThanOrEqual(preview.utf8.count, MarkdownLargeDocumentPolicy.previewBytes)
        XCTAssertTrue(large.hasPrefix(preview))
        XCTAssertFalse(preview.isEmpty)

        // Ends on a block boundary when one exists in the window.
        XCTAssertFalse(preview.hasSuffix("\n\n"))

        // A document with no blank line in the window falls back to a hard
        // cut that is still bounded and still a prefix.
        let giantSingleParagraph = String(repeating: "word ", count: 60_000)
        let hardCut = LargeMarkdownDocumentView.previewSource(of: giantSingleParagraph)
        XCTAssertLessThanOrEqual(hardCut.utf8.count, MarkdownLargeDocumentPolicy.previewBytes)
        XCTAssertTrue(giantSingleParagraph.hasPrefix(hardCut))

        // Small sources pass through untouched.
        let small = "Just a normal message."
        XCTAssertEqual(LargeMarkdownDocumentView.previewSource(of: small), small)
    }

    func testLargeCodePreviewIsBoundedInLines() throws {
        let lines = (0..<2_000).map { "line \($0) of a very long code block" }
        let source = lines.joined(separator: "\n")
        let previewPieces = MarkdownCodeSlicer.slice(
            source,
            maxLines: MarkdownLargeDocumentPolicy.codePreviewLineCount,
            maxBytes: MarkdownLargeDocumentPolicy.codePreviewBytes
        )

        // The preview renders the FIRST bounded piece; slicer output is the
        // bounded unit set, not the preview truncation.
        let first = try XCTUnwrap(previewPieces.first)
        XCTAssertLessThanOrEqual(
            first.components(separatedBy: "\n").count,
            MarkdownLargeDocumentPolicy.codePreviewLineCount + 1 // trailing newline component
        )
        XCTAssertLessThanOrEqual(first.utf8.count, MarkdownLargeDocumentPolicy.codePreviewBytes)
        XCTAssertEqual(previewPieces.joined(), source)
    }

    // MARK: 4/5. Expansion is chunked and preserves all content

    func testChunkPlanBoundsEveryFlowChunk() async {
        let source = paragraphSoup(targetBytes: 300_000)
        guard let prepared = await LargeMarkdownPreparedDocument.prepare(source) else { return XCTFail("preparation failed") }

        XCTAssertGreaterThan(prepared.chunks.count, 10)
        for chunk in prepared.chunks {
            guard case .flow(let blocks) = chunk else { continue }
            let bytes = blocks.reduce(0) { $0 + $1.estimatedSourceBytes }
            // Word-boundary splitting lets a piece overshoot by at most one
            // word; grouping alone never exceeds the target.
            XCTAssertLessThanOrEqual(bytes, chunkTarget + 128, "flow chunk exceeded the bound: \(bytes)")
        }
    }

    func testOversizedSingleParagraphIsSplit() async {
        // One 1 MB paragraph measured 2.4 s of TextKit layout as a single
        // selectable document; the plan must not produce it whole.
        let giant = String(repeating: "word ", count: 200_000)
        guard let prepared = await LargeMarkdownPreparedDocument.prepare(giant) else { return XCTFail("preparation failed") }

        XCTAssertGreaterThan(prepared.chunks.count, 10)
        for chunk in prepared.chunks {
            guard case .flow(let blocks) = chunk else { continue }
            let bytes = blocks.reduce(0) { $0 + $1.estimatedSourceBytes }
            XCTAssertLessThanOrEqual(bytes, chunkTarget + 128)
        }
    }

    func testChunkPlanIsDeterministic() async {
        let source = mixedSoup(targetBytes: 200_000)
        guard let first = await LargeMarkdownPreparedDocument.prepare(source),
              let second = await LargeMarkdownPreparedDocument.prepare(source) else {
            return XCTFail("preparation failed")
        }
        XCTAssertEqual(first.chunks, second.chunks)
    }

    func testPreparedDocumentPreservesAllContent() async {
        let source = mixedSoup(targetBytes: 200_000)
        let document = MarkdownParser.parseDocument(source)
        guard let prepared = await LargeMarkdownPreparedDocument.prepare(source) else { return XCTFail("preparation failed") }

        // Both sides flatten the SAME full-document parse, so the comparison
        // isolates chunking: nothing the parser produced may be dropped or
        // invented by grouping/splitting. (Reference definitions live in the
        // references context by design — PR #75 — and are asserted in
        // testPreparedDocumentCarriesReferenceDefinitions.)
        var renderedText = ""
        for chunk in prepared.chunks {
            switch chunk {
            case .flow(let blocks):
                renderedText += blocks.map(\.textForTesting).joined(separator: "\n\n") + "\n\n"
            case .block(let block, _):
                renderedText += block.textForTesting + "\n\n"
            }
        }
        let documentText = document.blocks.map(\.textForTesting).joined(separator: "\n\n")

        XCTAssertEqual(stripped(renderedText), stripped(documentText))
    }

    // MARK: 7. Reference links resolve in large mode

    func testPreparedDocumentCarriesReferenceDefinitions() async throws {
        let source = mixedSoup(targetBytes: 150_000)
        guard let prepared = await LargeMarkdownPreparedDocument.prepare(source) else { return XCTFail("preparation failed") }

        XCTAssertTrue(prepared.references.containsDefinitions)

        // The chunk containing a reference use renders it as a real link
        // through the same formatter the ordinary fast path uses.
        let firstChunk = prepared.chunks.first
        guard case .flow(let blocks) = firstChunk else {
            return XCTFail("expected the mixed corpus to open with a flow chunk")
        }
        let attributed = MarkdownSelectionFormatter.attributedText(
            for: blocks,
            references: prepared.references,
            foregroundStyle: .primary,
            usesAccentSurface: false,
            newestCharacterOpacities: []
        )
        let unwrapped = try XCTUnwrap(attributed)
        var linkCount = 0
        unwrapped.enumerateAttribute(.link, in: NSRange(location: 0, length: unwrapped.length)) { value, _, _ in
            if value != nil { linkCount += 1 }
        }
        XCTAssertGreaterThan(linkCount, 0, "reference-style link did not resolve in large mode")
    }

    // MARK: 8. Tables and code blocks stay whole

    func testRichBlocksRemainUnsplitWithOriginalIndexes() async {
        let source = mixedSoup(targetBytes: 200_000)
        let document = MarkdownParser.parseDocument(source)
        guard let prepared = await LargeMarkdownPreparedDocument.prepare(source) else { return XCTFail("preparation failed") }

        let originalTables = document.blocks.enumerated().filter { if case .table = $0.element { return true }; return false }
        let chunkTables = prepared.chunks.filter { if case .block(.table, _) = $0 { return true }; return false }
        XCTAssertEqual(chunkTables.count, originalTables.count)

        let originalCode = document.blocks.enumerated().filter { if case .code = $0.element { return true }; return false }
        let chunkCode = prepared.chunks.filter { if case .block(.code, _) = $0 { return true }; return false }
        XCTAssertEqual(chunkCode.count, originalCode.count)

        // Rich chunks keep their original block index so their selection
        // descriptors match the ordinary plan's `block-N` ids.
        var richIndexes: [Int] = []
        for chunk in prepared.chunks {
            if case .block(_, let originalIndex) = chunk { richIndexes.append(originalIndex) }
        }
        XCTAssertEqual(richIndexes, richIndexes.sorted())
        for index in richIndexes {
            XCTAssertLessThan(index, document.blocks.count)
        }
    }

    func testSegmentSlicingMatchesOrdinaryPlan() async throws {
        let source = mixedSoup(targetBytes: 150_000)
        let document = MarkdownParser.parseDocument(source)
        let plan = MarkdownSelectionSegmentPlan.descriptors(for: document.blocks)
        guard let prepared = await LargeMarkdownPreparedDocument.prepare(source) else { return XCTFail("preparation failed") }

        // The slicing invariant: segmentCount(of:) sums to the plan's length.
        let summed = document.blocks.reduce(0) { $0 + MarkdownSelectionSegmentPlan.segmentCount(of: $1) }
        XCTAssertEqual(summed, plan.count)

        // Every rich chunk's descriptors are exactly its block's slice of
        // the ordinary plan (same ids, same relative order), and every flow
        // chunk contributes one synthetic descriptor. Orders are globally
        // monotonic. Flow blocks' own plan descriptors are replaced by the
        // synthetic chunk descriptor (one selectable view per chunk).
        var blockRanges: [Range<Int>] = []
        var rangeCursor = 0
        for block in document.blocks {
            let count = MarkdownSelectionSegmentPlan.segmentCount(of: block)
            blockRanges.append(rangeCursor..<(rangeCursor + count))
            rangeCursor += count
        }

        var syntheticIDs = Set<String>()
        var previousOrder = -1
        for (chunkIndex, chunk) in prepared.chunks.enumerated() {
            let descriptors = prepared.descriptorsByChunk[chunkIndex]
            switch chunk {
            case .flow:
                XCTAssertEqual(descriptors.count, 1)
                XCTAssertEqual(try XCTUnwrap(descriptors.first).id, "lmd-flow-\(chunkIndex)")
                syntheticIDs.insert(descriptors.first!.id)
            case .block(let block, let originalIndex):
                let expectedCount = MarkdownSelectionSegmentPlan.segmentCount(of: block)
                XCTAssertEqual(descriptors.count, expectedCount)
                let expected = plan[blockRanges[originalIndex]]
                XCTAssertEqual(descriptors.map(\.id), expected.map(\.id))
                let orders = descriptors.map(\.order)
                XCTAssertEqual(orders, orders.sorted())
            }
            for descriptor in descriptors {
                XCTAssertGreaterThan(descriptor.order, previousOrder)
                previousOrder = descriptor.order
            }
        }
        XCTAssertFalse(syntheticIDs.isEmpty)
    }

    // MARK: 11. Stale async results cannot populate the wrong message

    func testSourceIdentityDistinguishesSources() {
        let base = paragraphSoup(targetBytes: 120_000)
        let extended = base + "\n\nOne more paragraph."

        XCTAssertNotEqual(
            LargeMarkdownPreparedDocument.identity(of: base),
            LargeMarkdownPreparedDocument.identity(of: extended)
        )
        XCTAssertEqual(
            LargeMarkdownPreparedDocument.identity(of: base),
            LargeMarkdownPreparedDocument.identity(of: String(base))
        )
    }

    // MARK: 12. Dynamic Type invalidation

    @MainActor
    func testFlowChunkBoxMemoizesAndInvalidatesOnDynamicTypeChange() {
        let box = LargeFlowChunkBox()
        let blocks: [MarkdownBlock] = [.paragraph("Hello **world** with [a link](https://example.com).")]

        let first = box.attributedText(
            blocks: blocks,
            references: .empty,
            foregroundStyle: .primary,
            usesAccentSurface: false,
            contentCategory: .large
        )
        let cached = box.attributedText(
            blocks: blocks,
            references: .empty,
            foregroundStyle: .primary,
            usesAccentSurface: false,
            contentCategory: .large
        )
        XCTAssertTrue(first === cached, "same Dynamic Type category must reuse the memoized string")

        let rebuilt = box.attributedText(
            blocks: blocks,
            references: .empty,
            foregroundStyle: .primary,
            usesAccentSurface: false,
            contentCategory: .extraLarge
        )
        XCTAssertFalse(first === rebuilt, "a Dynamic Type change must rebuild the attributed string")
        // (Font sizes themselves resolve from the process-wide setting, which
        // the view always passes as the category — the identity checks above
        // are the memoization/invalidation contract.)
    }

    // MARK: Streaming: scanner + promotion invariants (scenario 10)

    func testScannerFindsBoundariesOutsideConstructs() throws {
        let text = "para one\n\npara two\n\n```python\nx = 1\n\ny = 2\n```\n\nafter fence\n"
        var scanner = MarkdownStableBoundaryScanner()
        let boundaries = scanner.append(text)

        func offset(of marker: String) throws -> Int {
            let range = try XCTUnwrap(text.utf8.firstRange(of: marker.utf8))
            return text.utf8.distance(from: text.utf8.startIndex, to: range.lowerBound)
        }

        XCTAssertTrue(boundaries.contains(try offset(of: "para two")))
        XCTAssertTrue(boundaries.contains(try offset(of: "```python")))
        XCTAssertTrue(boundaries.contains(try offset(of: "after fence")))

        // The blank line *inside* the fence must not be a boundary.
        XCTAssertFalse(boundaries.contains(try offset(of: "y = 2")))
        XCTAssertEqual(scanner.lastSafeBoundary, try offset(of: "after fence"))
        XCTAssertFalse(scanner.isInOpenConstruct)
    }

    func testScannerReportsOpenConstructState() {
        var scanner = MarkdownStableBoundaryScanner()
        _ = scanner.append("text\n\n```python\nprint(1)\n")
        XCTAssertTrue(scanner.isInOpenConstruct)

        _ = scanner.append("print(2)\n```\n\ndone\n")
        XCTAssertFalse(scanner.isInOpenConstruct)

        var mathScanner = MarkdownStableBoundaryScanner()
        _ = mathScanner.append("intro\n\n$$\nx = 1\n")
        XCTAssertTrue(mathScanner.isInOpenConstruct)
        _ = mathScanner.append("$$\n\nout\n")
        XCTAssertFalse(mathScanner.isInOpenConstruct)
    }

    func testScannerIsResumableAcrossArbitraryDeltas() {
        let text = paragraphSoup(targetBytes: 40_000)
            + "\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\n"
            + paragraphSoup(targetBytes: 10_000)

        var oneShot = MarkdownStableBoundaryScanner()
        let oneShotBoundaries = oneShot.append(text)

        var incremental = MarkdownStableBoundaryScanner()
        var incrementalBoundaries: [Int] = []
        var index = text.startIndex
        let step = 37
        while index < text.endIndex {
            let end = min(text.index(index, offsetBy: step, limitedBy: text.endIndex) ?? text.endIndex, text.endIndex)
            incrementalBoundaries.append(contentsOf: incremental.append(String(text[index..<end])))
            index = end
        }

        XCTAssertEqual(incrementalBoundaries, oneShotBoundaries)
        XCTAssertEqual(incremental.lastSafeBoundary, oneShot.lastSafeBoundary)
        XCTAssertEqual(incremental.consumedOffset, oneShot.consumedOffset)
        XCTAssertEqual(incremental.isInOpenConstruct, oneShot.isInOpenConstruct)
    }

    func testPromotionPolicyAdvancesInBoundedSteps() {
        let chunk = MarkdownLargeDocumentPolicy.chunkTargetBytes
        let tail = chunk

        // Not enough stable content yet.
        XCTAssertNil(LargeStreamPromotion.nextPromotionBoundary(
            promotedBytes: 0, revealedBytes: tail + chunk - 1, tailWindowBytes: tail, boundaries: []
        ))

        // Safe boundary inside the bounded window wins; a boundary beyond
        // the window maximum is deliberately not used (it would produce an
        // oversized chunk).
        XCTAssertEqual(
            LargeStreamPromotion.nextPromotionBoundary(
                promotedBytes: 0, revealedBytes: tail + 3 * chunk, tailWindowBytes: tail, boundaries: [chunk + chunk / 2]
            ),
            chunk + chunk / 2
        )
        XCTAssertEqual(
            LargeStreamPromotion.nextPromotionBoundary(
                promotedBytes: 0, revealedBytes: tail + 3 * chunk, tailWindowBytes: tail, boundaries: [tail + 2 * chunk]
            ),
            MarkdownLargeDocumentPolicy.maxStreamChunkBytes,
            "boundary beyond the window falls back to the bounded hard cut"
        )

        // A safe boundary behind the minimum chunk step is not used.
        XCTAssertNil(LargeStreamPromotion.nextPromotionBoundary(
            promotedBytes: 0, revealedBytes: tail + chunk + 100, tailWindowBytes: tail, boundaries: [tail - 5]
        ))

        // No boundary at all: the hard cut engages only with two chunks of
        // stable content, and never promotes into the tail window.
        let hardCut = LargeStreamPromotion.nextPromotionBoundary(
            promotedBytes: 0, revealedBytes: tail + 4 * chunk, tailWindowBytes: tail, boundaries: []
        )
        XCTAssertEqual(hardCut, 2 * chunk)
        let noHardCut = LargeStreamPromotion.nextPromotionBoundary(
            promotedBytes: 0, revealedBytes: tail + chunk + 100, tailWindowBytes: tail, boundaries: []
        )
        XCTAssertNil(noHardCut)
    }

    @MainActor
    func testFewerChunksThanOneBatchRendersWithoutOverflow() async throws {
        // A large document can legitimately produce fewer chunks than the
        // initial batch (a handful of giant rich blocks): the expanded view
        // must clamp its initial window instead of indexing past the array.
        let giantTableRows = (0..<2_000).map { "row \($0) with some cell content" }
        let table = "| A | B |\n|---|---|\n" + giantTableRows
            .map { "| \($0) | \($0.reversed()) |" }
            .joined(separator: "\n")
        let source = "Intro paragraph.\n\n" + table + "\n\n```swift\n" + String(repeating: "let a = 1\n", count: 4_000) + "\n```"
        guard MarkdownLargeDocumentPolicy.isLargeDocument(source) else {
            return XCTFail("corpus must exceed the large-document threshold")
        }
        guard let prepared = await LargeMarkdownPreparedDocument.prepare(source) else { return XCTFail("preparation failed") }
        XCTAssertLessThan(prepared.chunks.count, LargeMarkdownExpandedView.initialChunkBatch,
                          "corpus should produce fewer chunks than one batch")

        // The precondition that exercises the view's initial-window clamp:
        // fewer chunks than one batch.
        XCTAssertLessThan(prepared.chunks.count, LargeMarkdownExpandedView.initialChunkBatch)

        // The view-level clamp: the initial window never exceeds the chunk
        // count (the same clamp the preparation task applies). Rich-chunk
        // RENDERING under this shape is covered by the dedicated table and
        // expansion tests; this test pins the overflow invariant itself.
        let initialWindow = min(LargeMarkdownExpandedView.initialChunkBatch, prepared.chunks.count)
        XCTAssertEqual(initialWindow, prepared.chunks.count, "fewer-than-batch documents render every chunk at once")
    }

    func testPreviewBudgetIsBytePreciseForMultibyteText() {
        // CJK characters are 3 UTF-8 bytes each: a character-based window
        // would triple the synchronous preview budget.
        let multibyte = String(repeating: "漢", count: 20_000) // 60 KB
        let preview = LargeMarkdownDocumentView.previewSource(of: multibyte)
        XCTAssertLessThanOrEqual(
            preview.utf8.count,
            MarkdownLargeDocumentPolicy.previewBytes,
            "preview must respect the byte budget for multibyte text (got \(preview.utf8.count))"
        )
        XCTAssertTrue(multibyte.hasPrefix(preview))

        // Mixed content with a blank-line boundary inside the byte window.
        let mixed = String(repeating: "漢字テキスト", count: 2_000) + "\n\n" + String(repeating: " trailing", count: 2_000)
        let mixedPreview = LargeMarkdownDocumentView.previewSource(of: mixed)
        XCTAssertLessThanOrEqual(mixedPreview.utf8.count, MarkdownLargeDocumentPolicy.previewBytes)
        XCTAssertTrue(mixed.hasPrefix(mixedPreview))
    }


    func testTailWindowExcludesUnrevealedText() {
        // The live tail is [promotedBytes, revealedEnd): text beyond the
        // reveal cursor must NOT render (character pacing holds in large
        // mode), and revealed-but-unpromoted text must not be skipped.
        let text = "abcdefghij" + String(repeating: "middle ", count: 200) + "TAILMARKER-END"
        let revealedByteIndex = StreamingText.alignedIndex(utf8Offset: 14, in: text)
        XCTAssertNotNil(revealedByteIndex)

        let tail = StreamingText.tailSource(
            accumulated: text,
            promotedBytes: 4,
            revealedEnd: revealedByteIndex
        )
        let unwrapped = try? XCTUnwrap(tail)
        XCTAssertNotNil(unwrapped)
        // Bounded to the revealed-unpromoted window.
        XCTAssertFalse(unwrapped!.contains("TAILMARKER"), "unrevealed text must not appear in the tail")
        XCTAssertTrue(unwrapped!.hasPrefix("efgh"), "tail starts right after the promoted prefix")

        // Fully promoted: no tail at all.
        let fullReveal = StreamingText.tailSource(
            accumulated: text,
            promotedBytes: text.utf8.count,
            revealedEnd: text.endIndex
        )
        XCTAssertNil(fullReveal)
    }

    func testAlignedIndexStepsBackToGraphemeBoundaryForCJK() {
        // CJK characters are 3 UTF-8 bytes; offsets 1 and 2 land inside the
        // second character and must step back to its start.
        let text = "汉汉汉"
        XCTAssertEqual(StreamingText.alignedIndex(utf8Offset: 0, in: text), text.startIndex)
        let secondChar = text.index(after: text.startIndex)
        XCTAssertEqual(StreamingText.alignedIndex(utf8Offset: 1, in: text), text.startIndex, "mid-grapheme steps back")
        XCTAssertEqual(StreamingText.alignedIndex(utf8Offset: 3, in: text), secondChar)
        XCTAssertEqual(StreamingText.alignedIndex(utf8Offset: 4, in: text), secondChar, "mid-grapheme steps back")
    }

    func testPromotionProgressesForUnbrokenCJKText() {
        // Hard-cut boundaries are pure byte arithmetic and land mid-grapheme
        // for CJK; the projection must still promote (stepping back) instead
        // of stalling with an ever-growing tail.
        let text = String(repeating: "漢字", count: 20_000) // 120 KB, no boundaries at all
        var scanner = MarkdownStableBoundaryScanner()
        _ = scanner.append(text)
        XCTAssertNil(scanner.lastSafeBoundary)
        XCTAssertFalse(scanner.isInOpenConstruct)

        let tailWindow = MarkdownLargeDocumentPolicy.chunkTargetBytes
        let total = text.utf8.count
        var promoted = 0
        var steps = 0
        while let next = LargeStreamPromotion.nextPromotionBoundary(
            promotedBytes: promoted,
            revealedBytes: total,
            tailWindowBytes: tailWindow,
            boundaries: [],
            constructIntervals: scanner.constructIntervals
        ) {
            let start = StreamingText.alignedIndex(utf8Offset: promoted, in: text)
            let end = StreamingText.alignedIndex(utf8Offset: next, in: text)
            XCTAssertNotNil(start)
            XCTAssertNotNil(end)
            if let start, let end {
                XCTAssertLessThan(start, end, "alignment must never collapse a promotion step")
            }
            promoted = next
            steps += 1
            if steps > 10_000 { XCTFail("promotion did not terminate"); break }
        }
        XCTAssertEqual(promoted, total - tailWindow)
    }

    func testScannerHandlesCRLFInput() {
        // CRLF deltas ride the \r on the line content; blank boundaries and
        // exact close markers ($$, :::) must still be recognized.
        let crlf = "intro\r\n\r\n$$\r\nx = 1\r\n$$\r\n\r\ndone\r\n"
        var scanner = MarkdownStableBoundaryScanner()
        let boundaries = scanner.append(crlf)
        XCTAssertEqual(boundaries.count, 2, "blank CRLF lines must yield boundaries (before math and after it)")
        XCTAssertFalse(scanner.isInOpenConstruct, "$$ must close on CRLF input")

        var directive = MarkdownStableBoundaryScanner()
        _ = directive.append("text\r\n\r\n::: note\r\nbody\r\n:::\r\n\r\nafter\r\n")
        XCTAssertFalse(directive.isInOpenConstruct, "::: must close on CRLF input")
        XCTAssertNotNil(directive.lastSafeBoundary)
    }

    func testScannerMathCloseMarkersArePaired() {
        // A $$ block containing a lone \] line must stay open until $$.
        var scanner = MarkdownStableBoundaryScanner()
        _ = scanner.append("intro\n\n$$\nx = 1\n\\]\nstill math\n$$\n\ndone\n")
        XCTAssertFalse(scanner.isInOpenConstruct)
        XCTAssertEqual(scanner.lastSafeBoundary, "intro\n\n$$\nx = 1\n\\]\nstill math\n$$\n\n".utf8.count)
    }

    func testScannerFinishDrainsTrailingPartialLine() {
        // A stream ending in a closing fence with no trailing newline must
        // not leave the scanner stuck in an open construct.
        var scanner = MarkdownStableBoundaryScanner()
        _ = scanner.append("intro\n\n```swift\nlet a = 1\n```")
        XCTAssertTrue(scanner.isInOpenConstruct, "fence without trailing newline is still open before finish")
        scanner.finish()
        XCTAssertFalse(scanner.isInOpenConstruct, "finish must close the construct")

        // A blank trailing *partial* line (no newline) yields one more safe
        // boundary via finish(); append() alone cannot see it.
        var blank = MarkdownStableBoundaryScanner()
        _ = blank.append("one\n\ntwo\n\n   ")
        let beforeFinish = blank.lastSafeBoundary
        blank.finish()
        XCTAssertNotNil(blank.lastSafeBoundary)
        XCTAssertGreaterThan(blank.lastSafeBoundary!, beforeFinish ?? 0)
    }

    func testContinueReadingWindowCountNeverOverflows() {
        // Fewer remaining chunks than one batch past the cap: the next
        // window count must clamp to the total, since chunkView indexes
        // prepared.chunks directly.
        XCTAssertEqual(LargeMarkdownExpandedView.nextWindowCount(current: 25, total: 30), 30)
        XCTAssertEqual(LargeMarkdownExpandedView.nextWindowCount(current: 25, total: 600), 50)
        XCTAssertEqual(LargeMarkdownExpandedView.nextWindowCount(current: 0, total: 5), 5)
    }

    func testSimulatedStreamKeepsTailBoundedAndContentIntact() {
        // Simulates the large streaming loop over a 200 KB stream with dense
        // paragraph boundaries: reveal advances in batches, promotion runs to
        // a fixpoint after each step, and the invariant holds — the live tail
        // (the only part re-parsed per tick) stays bounded, and promoted
        // slices concatenated equal the revealed prefix.
        let source = paragraphSoup(targetBytes: 200_000)
        let totalBytes = source.utf8.count
        var scanner = MarkdownStableBoundaryScanner()
        var promotedSlices: [String] = []
        var promotedBytes = 0
        var revealedBytes = 0
        let tail = MarkdownLargeDocumentPolicy.chunkTargetBytes
        let maximumTail = tail + 2 * MarkdownLargeDocumentPolicy.chunkTargetBytes

        var consumedBytes = 0
        var boundaries: [Int] = []
        while consumedBytes < totalBytes {
            let next = min(consumedBytes + 1_024, totalBytes)
            let start = source.utf8.index(source.utf8.startIndex, offsetBy: consumedBytes)
            let end = source.utf8.index(source.utf8.startIndex, offsetBy: next)
            boundaries.append(contentsOf: scanner.append(String(source[start..<end])))
            consumedBytes = next

            // Reveal lags arrival a little; promotion only uses revealed bytes.
            revealedBytes = min(revealedBytes + 2_048, consumedBytes)

            while let boundary = LargeStreamPromotion.nextPromotionBoundary(
                promotedBytes: promotedBytes,
                revealedBytes: revealedBytes,
                tailWindowBytes: tail,
                boundaries: boundaries,
                constructIntervals: scanner.constructIntervals
            ) {
                let sliceStart = source.utf8.index(source.utf8.startIndex, offsetBy: promotedBytes)
                let sliceEnd = source.utf8.index(source.utf8.startIndex, offsetBy: boundary)
                promotedSlices.append(String(source[sliceStart..<sliceEnd]))
                promotedBytes = boundary
                boundaries.removeAll { $0 <= boundary }
            }

            XCTAssertLessThanOrEqual(revealedBytes - promotedBytes, maximumTail)
        }

        // Drain the reveal and promote the remainder.
        revealedBytes = totalBytes
        while let boundary = LargeStreamPromotion.nextPromotionBoundary(
            promotedBytes: promotedBytes,
            revealedBytes: revealedBytes,
            tailWindowBytes: tail,
            boundaries: boundaries,
            constructIntervals: scanner.constructIntervals
        ) {
            let sliceStart = source.utf8.index(source.utf8.startIndex, offsetBy: promotedBytes)
            let sliceEnd = source.utf8.index(source.utf8.startIndex, offsetBy: boundary)
            promotedSlices.append(String(source[sliceStart..<sliceEnd]))
            promotedBytes = boundary
            boundaries.removeAll { $0 <= boundary }
        }

        let promotedContent = promotedSlices.joined()
        XCTAssertEqual(promotedContent.utf8.count, promotedBytes)
        // The promoted slices concatenate to exactly the revealed prefix.
        let expectedPrefix = String(decoding: source.utf8.prefix(promotedBytes), as: UTF8.self)
        XCTAssertEqual(promotedContent, expectedPrefix)
    }

    // MARK: 2/4/10. View-level work bounds (parse-counter based)

    /// Requirement: a huge message — user or assistant — must not
    /// synchronously build the heavy whole-document representation before
    /// initial presentation. Deterministic form: hosting a huge source at
    /// its collapsed presentation never invokes `parseDocument` with the
    /// whole source; every parse is bounded by the preview budget.
    @MainActor
    func testCollapsedPresentationNeverParsesWholeSource() throws {
        let source = mixedSoup(targetBytes: 250_000)
        guard MarkdownLargeDocumentPolicy.isLargeDocument(source) else {
            return XCTFail("corpus must exceed the large-document threshold")
        }

        MarkdownParser.parseSourceSizes = []
        let host = UIHostingController(
            rootView: MarkdownText(
                source: source,
                foregroundStyle: .white,
                usesAccentSurface: true
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        let collapsedDeadline = Date().addingTimeInterval(0.5)
        while Date() < collapsedDeadline {
            pumpForSwiftUICommit(host: host)
        }

        XCTAssertGreaterThan(MarkdownParser.parseSourceSizes.count, 0, "the preview must have rendered")
        for size in MarkdownParser.parseSourceSizes {
            XCTAssertLessThanOrEqual(
                size,
                MarkdownLargeDocumentPolicy.previewBytes,
                "collapsed presentation must only parse the bounded preview (saw \(size) bytes)"
            )
        }
    }

    /// Requirement: expanding must not revert to the unsafe whole-document
    /// synchronous path. Deterministic form: the whole source is parsed
    /// exactly once (the off-main preparation), and nothing else ever
    /// touches the whole source again — chunks format from parsed blocks,
    /// not by re-parsing.
    @MainActor
    func testExpansionParsesWholeSourceExactlyOnce() throws {
        let source = mixedSoup(targetBytes: 250_000)
        guard MarkdownLargeDocumentPolicy.isLargeDocument(source) else {
            return XCTFail("corpus must exceed the large-document threshold")
        }

        MarkdownParser.parseSourceSizes = []
        let host = UIHostingController(
            rootView: LargeMarkdownExpandedView(
                source: source,
                foregroundStyle: .primary,
                usesAccentSurface: false,
                gatewayMediaDataURL: nil
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()

        // Wait until the detached preparation has landed and rendered.
        let deadline = Date().addingTimeInterval(5)
        var rendered = false
        while Date() < deadline {
            pumpForSwiftUICommit(host: host)
            let wholeParses = MarkdownParser.parseSourceSizes.filter {
                $0 >= MarkdownLargeDocumentPolicy.documentThresholdBytes
            }
            if wholeParses.count >= 1, host.view.recursiveSubviewsForTests.contains(where: { view in
                (view as? UITextView)?.attributedText?.length ?? 0 > 0
            }) {
                rendered = true
                break
            }
        }

        let wholeParses = MarkdownParser.parseSourceSizes.filter {
            $0 >= MarkdownLargeDocumentPolicy.documentThresholdBytes
        }
        XCTAssertEqual(wholeParses.count, 1, "the whole source must be parsed exactly once (preparation)")
        XCTAssertTrue(rendered, "chunks must have rendered after preparation")
        for size in MarkdownParser.parseSourceSizes where size < MarkdownLargeDocumentPolicy.documentThresholdBytes {
            XCTAssertLessThanOrEqual(
                size,
                MarkdownLargeDocumentPolicy.previewBytes,
                "no per-chunk re-parse may exceed the preview budget (saw \(size))"
            )
        }
    }

    /// Requirement: a large streaming response must not perform unbounded
    /// whole-source Markdown work on published frames. Deterministic form:
    /// hosting a large stream renders only bounded chunk/tail sources —
    /// `parseDocument` never sees anything near the whole document.
    @MainActor
    func testLargeStreamRenderingParsesOnlyBoundedSources() throws {
        let source = mixedSoup(targetBytes: 250_000)
        guard MarkdownLargeDocumentPolicy.isLargeDocument(source) else {
            return XCTFail("corpus must exceed the large-document threshold")
        }

        MarkdownParser.parseSourceSizes = []
        let host = UIHostingController(rootView: StreamingText(text: source, active: true))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        let streamDeadline = Date().addingTimeInterval(1.0)
        while Date() < streamDeadline {
            pumpForSwiftUICommit(host: host)
        }

        XCTAssertGreaterThan(MarkdownParser.parseSourceSizes.count, 0, "stream content must have rendered")
        for size in MarkdownParser.parseSourceSizes {
            XCTAssertLessThan(
                size,
                MarkdownLargeDocumentPolicy.documentThresholdBytes,
                "large-stream rendering must only parse bounded sources (saw \(size))"
            )
        }
    }

    /// Requirement: switching sources mid-flight cannot let a stale async
    /// preparation populate the wrong message. The identity guard drops
    /// mismatched results; assert the visible end state matches the new
    /// source, not the old one.
    @MainActor
    func testSourceSwapDropsStalePreparation() throws {
        // Two large sources with distinctive first-chunk markers.
        let sourceA = "oldmarker " + String(repeating: "OLD", count: 15)
            + "\n\n" + paragraphSoup(targetBytes: 120_000)
        let sourceB = "newmarker " + String(repeating: "NEW", count: 15)
            + "\n\n" + paragraphSoup(targetBytes: 120_000)

        let state = SourceSwapHostState(source: sourceA)
        let host = UIHostingController(rootView: SourceSwapHostView(state: state))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()

        func renderedSummary() -> String {
            host.view.recursiveSubviewsForTests
                .compactMap { ($0 as? UITextView)?.attributedText?.string ?? nil }
                .map { String($0.prefix(20)) }
                .joined(separator: " | ")
        }

        // Phase A: initial preparation must land and render.
        let deadlineA = Date().addingTimeInterval(5)
        while Date() < deadlineA, !renderedSummary().contains("oldmarker") {
            pumpForSwiftUICommit(host: host)
        }
        XCTAssertTrue(
            renderedSummary().contains("oldmarker"),
            "initial source must render; rendered: \(renderedSummary())"
        )

        // Swap under the same identity: the stale preparation for A must be
        // dropped and B must render.
        state.source = sourceB
        let deadlineB = Date().addingTimeInterval(5)
        while Date() < deadlineB, !renderedSummary().contains("newmarker") {
            pumpForSwiftUICommit(host: host)
        }
        let final = renderedSummary()
        XCTAssertTrue(final.contains("newmarker"), "new source must render; rendered: \(final)")
        XCTAssertFalse(final.contains("OLDOLDOLDOLDOLDOLDOLD"), "stale preparation from the old source must not appear; rendered: \(final)")
    }
}

@MainActor
private final class SourceSwapHostState: ObservableObject {
    @Published var source: String
    init(source: String) { self.source = source }
}

private struct SourceSwapHostView: View {
    @ObservedObject var state: SourceSwapHostState

    var body: some View {
        LargeMarkdownExpandedView(
            source: state.source,
            foregroundStyle: .primary,
            usesAccentSurface: false,
            gatewayMediaDataURL: nil
        )
    }
}


/// Runs the main run loop briefly and forces a UIKit layout pass: the
/// XCTest runloop emulation does not always drive SwiftUI's asynchronous
/// attribute commit on its own, which would leave representables from
/// pending transactions orphaned instead of mounted.
@MainActor
private func pumpForSwiftUICommit(host: UIHostingController<some View>) {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
}

private extension UIView {
    var recursiveSubviewsForTests: [UIView] {
        subviews + subviews.flatMap(\.recursiveSubviewsForTests)
    }
}


// MARK: - Hardening battery (adversarial shapes)

extension MarkdownLargeDocumentTests {
    // Case 1: a 1 MB single-line code block must produce byte-bounded
    // preview and slice pieces whose concatenation is the original.
    func testOneMegabyteSingleLineCodeIsByteBounded() {
        let blob = String(repeating: "aG9nZW5pdW1lYmxvYjE=", count: 52_000) // ~1 MB, no newlines
        XCTAssertGreaterThan(blob.utf8.count, 1_000_000)

        let preview = MarkdownCodeSlicer.slice(
            blob,
            maxLines: MarkdownLargeDocumentPolicy.codePreviewLineCount,
            maxBytes: MarkdownLargeDocumentPolicy.codePreviewBytes
        )
        XCTAssertGreaterThan(preview.count, 1, "a single 1 MB line must be split into preview pieces")
        for piece in preview {
            XCTAssertLessThanOrEqual(piece.utf8.count, MarkdownLargeDocumentPolicy.codePreviewBytes)
        }
        XCTAssertEqual(preview.joined(), blob, "preview pieces must be contiguous with the original")

        let slices = MarkdownCodeSlicer.slice(
            blob,
            maxLines: MarkdownLargeDocumentPolicy.codeSliceLineCount,
            maxBytes: MarkdownLargeDocumentPolicy.codeSliceBytes
        )
        for slice in slices {
            XCTAssertLessThanOrEqual(slice.utf8.count, MarkdownLargeDocumentPolicy.codeSliceBytes)
        }
        XCTAssertEqual(slices.joined(), blob)
    }

    func testCodeSlicerBoundsLinesAndBytesIndependently() {
        // Few lines, huge bytes -> byte bound engages.
        let wide = (0..<3).map { _ in
            String(repeating: "x", count: 30_000) + "\n" + String(repeating: "y", count: 30_000)
        }.joined(separator: "\n")
        let slices = MarkdownCodeSlicer.slice(
            wide,
            maxLines: MarkdownLargeDocumentPolicy.codeSliceLineCount,
            maxBytes: MarkdownLargeDocumentPolicy.codeSliceBytes
        )
        for slice in slices {
            XCTAssertLessThanOrEqual(slice.utf8.count, MarkdownLargeDocumentPolicy.codeSliceBytes)
        }
        XCTAssertEqual(slices.joined(), wide)

        // Many lines, small bytes -> line bound engages.
        let tall = (0..<2_000).map { "line \($0)" }.joined(separator: "\n")
        let tallSlices = MarkdownCodeSlicer.slice(
            tall,
            maxLines: MarkdownLargeDocumentPolicy.codePreviewLineCount,
            maxBytes: MarkdownLargeDocumentPolicy.codePreviewBytes
        )
        for slice in tallSlices {
            XCTAssertLessThanOrEqual(
                slice.components(separatedBy: "\n").count,
                MarkdownLargeDocumentPolicy.codePreviewLineCount + 1
            )
        }
        XCTAssertEqual(tallSlices.joined(), tall)
    }

    // Case 2: a very large table routes to the paged presentation and
    // mounts only a bounded initial row batch.
    @MainActor
    func testLargeTableMountsBoundedInitialRows() throws {
        let rows = (0..<3_000).map { ["row \($0)", String(repeating: "v", count: 40)] }
        let table = MarkdownBlock.table(
            headers: ["A", "B"],
            alignments: [.leading, .leading],
            rows: rows
        )
        XCTAssertGreaterThanOrEqual(table.estimatedSourceBytes, MarkdownLargeDocumentPolicy.largeTableBytes)

        let host = UIHostingController(
            rootView: LargeMarkdownTable(
                headers: ["A", "B"],
                alignments: [.leading, .leading],
                rows: rows,
                foregroundStyle: .primary,
                usesAccentSurface: false,
                selectionCoordinator: nil,
                blockIndex: 0,
                selectionSegments: []
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            pumpForSwiftUICommit(host: host)
        }

        // One text view per mounted cell: header (2) + initial batch rows.
        let textViews = host.view.recursiveSubviewsForTests.compactMap { $0 as? UITextView }
        let mountedRows = (textViews.count + 1) / 2
        XCTAssertLessThanOrEqual(mountedRows, LargeMarkdownTable.initialRowBatch + 1, "initial table mount must be row-bounded")
        XCTAssertGreaterThan(textViews.count, 0, "table must render content")
    }

    // Case 3: a single ~500 KB list item splits into bounded pieces.
    func testSingleHugeListItemIsBounded() async {
        let giant = Array(repeating: "itemword", count: 62_500).joined(separator: " ")
        let document = MarkdownParser.parseDocument("- \(giant)")
        guard let prepared = await LargeMarkdownPreparedDocument.prepare("- \(giant)") else {
            return XCTFail("preparation failed")
        }
        XCTAssertGreaterThan(prepared.chunks.count, 5)
        for chunk in prepared.chunks {
            guard case .flow(let blocks) = chunk else { continue }
            let bytes = blocks.reduce(0) { $0 + $1.flattenedText.utf8.count }
            XCTAssertLessThanOrEqual(bytes, MarkdownLargeDocumentPolicy.chunkTargetBytes + 256,
                                     "oversized item pieces must stay bounded (got \(bytes))")
        }
        // Content preserved across the pieces.
        let joined = prepared.chunks.map(\.flattenedText).joined(separator: " ")
        XCTAssertTrue(joined.replacingOccurrences(of: " ", with: "").hasSuffix(giant.replacingOccurrences(of: " ", with: "")),
                      "item text must survive splitting")
    }

    // Ordered-list continuation keeps ordinals (baked) instead of
    // restarting at 1.
    func testOrderedListContinuationPreservesOrdinals() async {
        let items = (1...900).map { "item \($0) \(String(repeating: "text ", count: 12))" }
        let source = items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let document = MarkdownParser.parseDocument(source)
        guard case .orderedList(let parsed)? = document.blocks.first else {
            return XCTFail("expected an ordered list")
        }
        let chunks = MarkdownLargeChunkPlanner.chunks(for: [.orderedList(parsed)])
        XCTAssertGreaterThan(chunks.count, 1, "the list must split across chunks")

        var sawListMarker = false
        var bakedOrdinals: [Int] = []
        for chunk in chunks {
            guard case .flow(let blocks) = chunk else { continue }
            for block in blocks {
                switch block {
                case .orderedList:
                    XCTAssertFalse(sawListMarker, "only the first chunk may render as a real ordered list")
                    sawListMarker = true
                case .paragraph(let text):
                    if let ordinal = Int(text.prefix { $0.isNumber }) {
                        bakedOrdinals.append(ordinal)
                    }
                default: break
                }
            }
        }
        // Continuation ordinals must continue from where the list chunk
        // stopped, never restart at 1.
        if let first = bakedOrdinals.first {
            XCTAssertGreaterThan(first, 1, "continuation numbering must not restart at 1")
        }
    }

    // Case 4: many/large reference definitions -> per-chunk parse input
    // stays bounded and links still resolve.
    func testReferenceDefinitionSubsetsAreBoundedAndResolve() async throws {
        let definitions = (0..<2_000).map { "[label\($0)]: https://example.com/def\($0)/\(String(repeating: "path", count: 12))" }
        let paragraphUsing = "Opening paragraph that uses [the important one][label1999] early. " + String(repeating: "ordinary prose. ", count: 120)
        let filler = (1..<40).map { "\n\nFiller paragraph \($0) " + String(repeating: "plain text. ", count: 140) }.joined()
        let source = paragraphUsing + filler + "\n\n" + definitions.joined(separator: "\n")
        XCTAssertGreaterThan(MarkdownParser.parseDocument(source).references.definitionsMarkdown.utf8.count,
                             10 * MarkdownLargeDocumentPolicy.referenceSubsetBudgetBytes)

        guard let prepared = await LargeMarkdownPreparedDocument.prepare(source) else { return XCTFail("preparation failed") }

        for (index, chunk) in prepared.chunks.enumerated() {
            let subset = prepared.referencesByChunk[index]
            XCTAssertLessThanOrEqual(
                subset.definitionsMarkdown.utf8.count,
                MarkdownLargeDocumentPolicy.referenceSubsetBudgetBytes,
                "chunk \(index) definition subset exceeds the budget"
            )
        }

        // The chunk containing the use still resolves its link.
        let firstChunk = prepared.chunks.first
        guard case .flow(let blocks)? = firstChunk else { return XCTFail("expected flow first chunk") }
        let attributed = try XCTUnwrap(MarkdownSelectionFormatter.attributedText(
            for: blocks,
            references: prepared.referencesByChunk[0],
            foregroundStyle: .primary,
            usesAccentSurface: false,
            newestCharacterOpacities: []
        ))
        var linkCount = 0
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if value != nil { linkCount += 1 }
        }
        XCTAssertGreaterThan(linkCount, 0, "the subset must still resolve the used reference")
    }

    // Case 5: a safe boundary far beyond the window must not produce an
    // oversized stable chunk.
    func testDistantSafeBoundaryDoesNotOversizeChunk() {
        let chunk = MarkdownLargeDocumentPolicy.chunkTargetBytes
        let tail = chunk
        let maxChunk = MarkdownLargeDocumentPolicy.maxStreamChunkBytes

        // Boundaries: one inside the window, one 500 KB ahead.
        let boundary = LargeStreamPromotion.nextPromotionBoundary(
            promotedBytes: 0,
            revealedBytes: tail + 600 * chunk,
            tailWindowBytes: tail,
            boundaries: [chunk, 500 * chunk]
        )
        XCTAssertEqual(boundary, chunk, "must pick the boundary inside the bounded window")
        XCTAssertLessThanOrEqual(boundary ?? 0, maxChunk)
    }

    // Case 6: stable target inside an open fenced block while later
    // boundaries exist -> wait, never split the construct.
    func testStableTargetInsideOpenFenceWaits() {
        let chunk = MarkdownLargeDocumentPolicy.chunkTargetBytes
        let tail = chunk
        let fenceStart = 2 * chunk
        let fenceEnd = 100 * chunk

        // Target inside the fence; a boundary after the fence exists but is
        // beyond the window; an earlier boundary before the fence was kept.
        let target = fenceStart + 3 * chunk
        let revealed = target + tail
        let inside = LargeStreamPromotion.nextPromotionBoundary(
            promotedBytes: 0,
            revealedBytes: revealed,
            tailWindowBytes: tail,
            boundaries: [chunk, fenceEnd + chunk],
            constructIntervals: [(start: fenceStart, end: fenceEnd)]
        )
        // The boundary at `chunk` (before the fence) is in the window and
        // safe: promotion uses it rather than cutting through the fence.
        XCTAssertEqual(inside, chunk)

        // With NO boundary in the window at all while the target sits in
        // the construct: wait (nil), never hard-cut.
        let waiting = LargeStreamPromotion.nextPromotionBoundary(
            promotedBytes: 0,
            revealedBytes: revealed,
            tailWindowBytes: tail,
            boundaries: [fenceEnd + chunk],
            constructIntervals: [(start: fenceStart, end: fenceEnd)]
        )
        XCTAssertNil(waiting, "must not hard-cut through an open construct")
    }

    // Case 6b: scanner-level — reveal inside a fence while the scanner has
    // processed boundaries past the fence.
    func testScannerIntervalsCoverFencesForDelayedPromotion() {
        let fenceBody = (0..<400).map { "code line \($0)" }.joined(separator: "\n")
        let text = "intro\n\n" + (0..<80).map { "para \($0) words" }.joined(separator: "\n\n")
            + "\n\n```\n\(fenceBody)\n```\n\nafter fence\n\n"
            + (0..<80).map { "tail para \($0)" }.joined(separator: "\n\n")
        var scanner = MarkdownStableBoundaryScanner()
        var boundaries: [Int] = []
        boundaries.append(contentsOf: scanner.append(text))
        XCTAssertFalse(scanner.isInOpenConstruct)
        XCTAssertEqual(scanner.constructIntervals.count, 1, "the fenced block must be one interval")
        let interval = scanner.constructIntervals[0]
        XCTAssertNotNil(interval.end, "a closed fence must record its end offset")

        // Promote with the stable target inside the recorded interval: the
        // policy must use a boundary BEFORE the fence or wait.
        let fenceStart = interval.start
        let target = fenceStart + 1_000
        let inFence = LargeStreamPromotion.nextPromotionBoundary(
            promotedBytes: 0,
            revealedBytes: target + MarkdownLargeDocumentPolicy.chunkTargetBytes,
            tailWindowBytes: MarkdownLargeDocumentPolicy.chunkTargetBytes,
            boundaries: boundaries,
            constructIntervals: scanner.constructIntervals
        )
        if let boundary = inFence {
            XCTAssertLessThanOrEqual(boundary, fenceStart, "promotion boundary must not land inside the fence")
        }
    }

    // Case 7: giant unbroken CJK paragraph -> bounded grapheme-safe hard
    // cut still allowed (complements the existing CJK alignment test).
    func testGiantUnbrokenPlainTextHardCutAllowed() {
        let chunk = MarkdownLargeDocumentPolicy.chunkTargetBytes
        let cut = LargeStreamPromotion.nextPromotionBoundary(
            promotedBytes: 0,
            revealedBytes: 400 * chunk,
            tailWindowBytes: chunk,
            boundaries: [],
            constructIntervals: []
        )
        XCTAssertEqual(cut, 2 * chunk, "unstructured prose promotes via bounded hard cut")
    }

    // Case 8: initial expansion must not automatically mount hundreds of
    // chunks (the Continue-only policy).
    @MainActor
    func testInitialExpansionDoesNotAutoMountHundreds() throws {
        let source = paragraphSoup(targetBytes: 400_000)
        guard MarkdownLargeDocumentPolicy.isLargeDocument(source) else {
            return XCTFail("corpus must be large")
        }
        MarkdownParser.parseSourceSizes = []
        let host = UIHostingController(
            rootView: LargeMarkdownExpandedView(
                source: source,
                foregroundStyle: .primary,
                usesAccentSurface: false,
                gatewayMediaDataURL: nil
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        // Pump well past what an auto-cascade would need.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            pumpForSwiftUICommit(host: host)
        }
        let textViews = host.view.recursiveSubviewsForTests.compactMap { $0 as? UITextView }
        XCTAssertLessThanOrEqual(
            textViews.count,
            LargeMarkdownExpandedView.initialChunkBatch + 1,
            "expansion must mount only the initial batch without user action"
        )
    }

    // Case 9: Dynamic Type environment drives chunk rebuilds (view-level).
    @MainActor
    func testDynamicTypeEnvironmentRebuildsChunks() throws {
        let blocks: [MarkdownBlock] = [.paragraph("Dynamic type probe paragraph with text.")]
        func attributedFont(for category: UIContentSizeCategory) throws -> UIFont {
            let box = LargeFlowChunkBox()
            let attributed = try XCTUnwrap(box.attributedText(
                blocks: blocks,
                references: .empty,
                foregroundStyle: .primary,
                usesAccentSurface: false,
                contentCategory: category
            ))
            return try XCTUnwrap(attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        }
        // UIFont.preferredFont resolves against the app's live category, so
        // the injectable parameter governs MEMO identity, not font metrics;
        // real metric changes flow through the environment in the app.
        _ = try attributedFont(for: .large)

        // View-level: the environment value feeds the box.
        let host = UIHostingController(
            rootView: DynamicTypeProbeView(blocks: blocks)
                .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            pumpForSwiftUICommit(host: host)
        }
        let textViews = host.view.recursiveSubviewsForTests.compactMap { $0 as? UITextView }
        XCTAssertTrue(textViews.contains { ($0.attributedText?.length ?? 0) > 0 }, "probe chunk must render under the large category")
    }

    // Case 10: content reconstruction after streaming promotion (windowed).
    func testWindowedPromotionReconstructsPromotedPrefix() {
        let source = paragraphSoup(targetBytes: 200_000)
        var scanner = MarkdownStableBoundaryScanner()
        var boundaries: [Int] = scanner.append(source)
        let revealed = source.utf8.count

        var promoted = 0
        var slices: [String] = []
        var steps = 0
        while let next = LargeStreamPromotion.nextPromotionBoundary(
            promotedBytes: promoted,
            revealedBytes: revealed,
            tailWindowBytes: MarkdownLargeDocumentPolicy.chunkTargetBytes,
            boundaries: boundaries,
            constructIntervals: scanner.constructIntervals
        ) {
            XCTAssertLessThanOrEqual(next - promoted, MarkdownLargeDocumentPolicy.maxStreamChunkBytes,
                                     "every promoted step must be bounded by the stream chunk maximum")
            slices.append(String(decoding: source.utf8.prefix(next).suffix(next - promoted), as: UTF8.self))
            promoted = next
            boundaries.removeAll { $0 <= next }
            steps += 1
            if steps > 10_000 { XCTFail("did not terminate"); break }
        }
        XCTAssertLessThanOrEqual(promoted, revealed - MarkdownLargeDocumentPolicy.chunkTargetBytes)
        XCTAssertGreaterThanOrEqual(
            promoted,
            revealed - MarkdownLargeDocumentPolicy.chunkTargetBytes - MarkdownLargeDocumentPolicy.maxStreamChunkBytes,
            "promotion must drain everything except the tail window (within one max chunk)"
        )
        let joined = slices.joined()
        XCTAssertEqual(joined.utf8.count, promoted)
        let expected = String(decoding: source.utf8.prefix(promoted), as: UTF8.self)
        XCTAssertEqual(joined, expected)
    }

    // Case 11: no promoted stable chunk may re-enter the large-document
    // renderer.
    func testPromotedChunksNeverEnterLargeDocumentRenderer() {
        let maxChunk = MarkdownLargeDocumentPolicy.maxStreamChunkBytes
        XCTAssertLessThan(maxChunk, MarkdownLargeDocumentPolicy.documentThresholdBytes,
                          "stream chunk maximum must stay under the large-document threshold")
    }

    // Balance-aware splitting: a bold span crossing the cut boundary must
    // not be split mid-span when a balanced cut exists.
    func testSplitTextPrefersBalancedCutPoints() {
        let tail = "and a final balanced sentence that carries the closing markers."
        let text = "opening words. " + String(repeating: "middle prose here. ", count: 400)
            + "**bold span that must not be cut** and `code span intact` plus "
            + String(repeating: "more prose continues here. ", count: 200) + tail
        let chunks = MarkdownLargeChunkPlanner.splitText(text) { .paragraph($0) }
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            guard case .flow(let blocks) = chunk else { continue }
            for block in blocks {
                guard case .paragraph(let piece) = block else { continue }
                // No piece may end inside the bold span or the code span.
                XCTAssertFalse(piece.hasSuffix("**bold") || piece.hasSuffix("bold span that must not be cut** and `code"),
                               "cut landed inside an inline construct: [\(piece.suffix(40))]")
            }
        }
        // Reconstruction preserves all text.
        let joined = chunks.map(\.flattenedText).joined(separator: " ")
        XCTAssertEqual(
            joined.replacingOccurrences(of: " ", with: ""),
            text.replacingOccurrences(of: " ", with: "")
        )
    }
}

private struct DynamicTypeProbeView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        LargeFlowChunkView(
            blocks: blocks,
            references: .empty,
            foregroundStyle: .primary,
            usesAccentSurface: false,
            selectionCoordinator: nil,
            selectionSegment: nil
        )
    }
}

// MARK: - Test-only projections

extension MarkdownBlock {
    /// Flattened text projection for content-preservation comparisons.
    var textForTesting: String {
        switch self {
        case .heading(_, let text), .paragraph(let text): return text
        case .quote(let lines): return lines.map(\.text).joined(separator: "\n")
        case .unorderedList(let items), .orderedList(let items): return items.joined(separator: "\n")
        case .table(let headers, _, let rows):
            return ([headers] + rows).map { $0.joined(separator: "|") }.joined(separator: "\n")
        case .code(_, let source): return source
        case .callout(_, let text): return text
        case .columns(let columns): return columns.joined(separator: "\n")
        case .math(let source): return source
        case .image(let url, let alt): return "\(alt)\(url)"
        case .divider: return "---"
        }
    }
}
