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

    func testLargeCodePreviewIsBoundedInLines() {
        let lines = (0..<2_000).map { "line \($0) of a very long code block" }
        let source = lines.joined(separator: "\n")
        let preview = LargeCodeBlockView.previewSource(of: source)

        XCTAssertLessThanOrEqual(preview.components(separatedBy: "\n").count, 200)
        XCTAssertTrue(source.hasPrefix(preview))
    }

    // MARK: 4/5. Expansion is chunked and preserves all content

    func testChunkPlanBoundsEveryFlowChunk() {
        let source = paragraphSoup(targetBytes: 300_000)
        let prepared = LargeMarkdownPreparedDocument.prepare(source)

        XCTAssertGreaterThan(prepared.chunks.count, 10)
        for chunk in prepared.chunks {
            guard case .flow(let blocks) = chunk else { continue }
            let bytes = blocks.reduce(0) { $0 + $1.estimatedSourceBytes }
            // Word-boundary splitting lets a piece overshoot by at most one
            // word; grouping alone never exceeds the target.
            XCTAssertLessThanOrEqual(bytes, chunkTarget + 128, "flow chunk exceeded the bound: \(bytes)")
        }
    }

    func testOversizedSingleParagraphIsSplit() {
        // One 1 MB paragraph measured 2.4 s of TextKit layout as a single
        // selectable document; the plan must not produce it whole.
        let giant = String(repeating: "word ", count: 200_000)
        let prepared = LargeMarkdownPreparedDocument.prepare(giant)

        XCTAssertGreaterThan(prepared.chunks.count, 10)
        for chunk in prepared.chunks {
            guard case .flow(let blocks) = chunk else { continue }
            let bytes = blocks.reduce(0) { $0 + $1.estimatedSourceBytes }
            XCTAssertLessThanOrEqual(bytes, chunkTarget + 128)
        }
    }

    func testChunkPlanIsDeterministic() {
        let source = mixedSoup(targetBytes: 200_000)
        let first = LargeMarkdownPreparedDocument.prepare(source)
        let second = LargeMarkdownPreparedDocument.prepare(source)
        XCTAssertEqual(first.chunks, second.chunks)
    }

    func testPreparedDocumentPreservesAllContent() {
        let source = mixedSoup(targetBytes: 200_000)
        let document = MarkdownParser.parseDocument(source)
        let prepared = LargeMarkdownPreparedDocument.prepare(source)

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

    func testPreparedDocumentCarriesReferenceDefinitions() throws {
        let source = mixedSoup(targetBytes: 150_000)
        let prepared = LargeMarkdownPreparedDocument.prepare(source)

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

    func testRichBlocksRemainUnsplitWithOriginalIndexes() {
        let source = mixedSoup(targetBytes: 200_000)
        let document = MarkdownParser.parseDocument(source)
        let prepared = LargeMarkdownPreparedDocument.prepare(source)

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

    func testSegmentSlicingMatchesOrdinaryPlan() throws {
        let source = mixedSoup(targetBytes: 150_000)
        let document = MarkdownParser.parseDocument(source)
        let plan = MarkdownSelectionSegmentPlan.descriptors(for: document.blocks)
        let prepared = LargeMarkdownPreparedDocument.prepare(source)

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
            promotedBytes: 0, revealedBytes: tail + chunk - 1, tailWindowBytes: tail, lastSafeBoundary: nil
        ))

        // Safe boundary in range wins.
        XCTAssertEqual(
            LargeStreamPromotion.nextPromotionBoundary(
                promotedBytes: 0, revealedBytes: tail + 3 * chunk, tailWindowBytes: tail, lastSafeBoundary: tail + 2 * chunk
            ),
            tail + 2 * chunk
        )

        // A safe boundary behind the minimum chunk step is not used.
        XCTAssertNil(LargeStreamPromotion.nextPromotionBoundary(
            promotedBytes: 0, revealedBytes: tail + chunk + 100, tailWindowBytes: tail, lastSafeBoundary: tail - 5
        ))

        // No boundary at all: the hard cut engages only with two chunks of
        // stable content, and never promotes into the tail window.
        let hardCut = LargeStreamPromotion.nextPromotionBoundary(
            promotedBytes: 0, revealedBytes: tail + 4 * chunk, tailWindowBytes: tail, lastSafeBoundary: nil
        )
        XCTAssertEqual(hardCut, 2 * chunk)
        let noHardCut = LargeStreamPromotion.nextPromotionBoundary(
            promotedBytes: 0, revealedBytes: tail + chunk + 100, tailWindowBytes: tail, lastSafeBoundary: nil
        )
        XCTAssertNil(noHardCut)
    }

    @MainActor
    func testFewerChunksThanOneBatchRendersWithoutOverflow() throws {
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
        let prepared = LargeMarkdownPreparedDocument.prepare(source)
        XCTAssertLessThan(prepared.chunks.count, LargeMarkdownExpandedView.initialChunkBatch,
                          "corpus should produce fewer chunks than one batch")

        // The precondition that exercises the view's initial-window clamp:
        // fewer chunks than one batch.
        XCTAssertLessThan(prepared.chunks.count, LargeMarkdownExpandedView.initialChunkBatch)

        // Render end-to-end to prove no out-of-bounds during layout.
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
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline,
              !host.view.recursiveSubviewsForTests.contains(where: { ($0 as? UITextView)?.attributedText?.length ?? 0 > 0 }) {
            pumpForSwiftUICommit(host: host)
        }
        XCTAssertTrue(
            host.view.recursiveSubviewsForTests.contains { ($0 as? UITextView)?.attributedText?.length ?? 0 > 0 },
            "content must render without an out-of-bounds crash"
        )
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
            lastSafeBoundary: scanner.lastSafeBoundary
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
        XCTAssertEqual(LargeMarkdownExpandedView.nextWindowCount(current: 480, total: 485), 485)
        XCTAssertEqual(LargeMarkdownExpandedView.nextWindowCount(current: 480, total: 600), 492)
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
        while consumedBytes < totalBytes {
            let next = min(consumedBytes + 1_024, totalBytes)
            let start = source.utf8.index(source.utf8.startIndex, offsetBy: consumedBytes)
            let end = source.utf8.index(source.utf8.startIndex, offsetBy: next)
            _ = scanner.append(String(source[start..<end]))
            consumedBytes = next

            // Reveal lags arrival a little; promotion only uses revealed bytes.
            revealedBytes = min(revealedBytes + 2_048, consumedBytes)

            while let boundary = LargeStreamPromotion.nextPromotionBoundary(
                promotedBytes: promotedBytes,
                revealedBytes: revealedBytes,
                tailWindowBytes: tail,
                lastSafeBoundary: scanner.lastSafeBoundary
            ) {
                let sliceStart = source.utf8.index(source.utf8.startIndex, offsetBy: promotedBytes)
                let sliceEnd = source.utf8.index(source.utf8.startIndex, offsetBy: boundary)
                promotedSlices.append(String(source[sliceStart..<sliceEnd]))
                promotedBytes = boundary
            }

            XCTAssertLessThanOrEqual(revealedBytes - promotedBytes, maximumTail)
        }

        // Drain the reveal and promote the remainder.
        revealedBytes = totalBytes
        while let boundary = LargeStreamPromotion.nextPromotionBoundary(
            promotedBytes: promotedBytes,
            revealedBytes: revealedBytes,
            tailWindowBytes: tail,
            lastSafeBoundary: scanner.lastSafeBoundary
        ) {
            let sliceStart = source.utf8.index(source.utf8.startIndex, offsetBy: promotedBytes)
            let sliceEnd = source.utf8.index(source.utf8.startIndex, offsetBy: boundary)
            promotedSlices.append(String(source[sliceStart..<sliceEnd]))
            promotedBytes = boundary
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
