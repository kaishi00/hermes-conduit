//
//  MarkdownLargeDocument.swift
//  Conduit
//
//  Bounded rendering for pathological-but-legitimate chat messages.
//
//  Measurements (iPhone 17 simulator, see PR description) showed that at
//  ~250 KB a single message already costs 220–800 ms of synchronous
//  MainActor work per pipeline stage, and at 1 MB the whole-document
//  pipeline costs 0.8–3.3 s — repeated at 30 fps while streaming, which
//  wedges the main thread and invites a watchdog kill. This file owns the
//  policy and the pure planning logic that keeps every stage's work
//  proportional to a bounded chunk, never to the whole document.
//

import Foundation

/// Central policy for the large-document rendering mode. All thresholds are
/// `utf8.count`-based (cheap, deterministic — no parsing just to decide the
/// path) and justified by measurement:
///
/// - `documentThresholdBytes` (100 KB): a typical rich assistant response is
///   1–10 KB; the largest ordinary ones (~50 KB) measured 45–160 ms for a
///   full synchronous pipeline pass — a hitch, not a freeze, and that is the
///   pre-existing behavior this change must preserve. By 250 KB every stage
///   measured 220 ms+ and whole-document layout reached 565 ms–2.4 s, so the
///   boundary between "keep the fast path" and "must bound the work" sits
///   between those: 100 KB.
/// - `previewBytes` (16 KB): the collapsed preview renders synchronously on
///   first presentation (session load, history scroll). Two chunks' worth of
///   content measured ≤ ~35 ms to parse + format + lay out.
/// - `chunkTargetBytes` (8 KB): one flow chunk measured ~1.5 ms parse +
///   ~3 ms attributed construction + ~3 ms TextKit layout — single-digit
///   milliseconds per chunk keeps progressive rendering hitch-free.
/// - `codeBlockThresholdBytes` (32 KB): syntax highlighting measured 67 ms at
///   50 KB and 1.5 s at 1 MB; 32 KB is where highlighting leaves the
///   "synchronous is fine" range.
enum MarkdownLargeDocumentPolicy {
    static let documentThresholdBytes = 100_000
    static let previewBytes = 16_000
    static let chunkTargetBytes = 8_000
    static let codeBlockThresholdBytes = 32_000
    /// Lines per rendered slice of a large code block; bounds each slice's
    /// TextKit layout height (~800 lines ≈ 13K pt) and highlighting pass.
    static let codeSliceLineCount = 800

    static func isLargeDocument(_ source: String) -> Bool {
        source.utf8.count >= documentThresholdBytes
    }

    static func isLargeCodeBlock(_ source: String) -> Bool {
        source.utf8.count >= codeBlockThresholdBytes
    }
}

/// One bounded rendering unit of a large document. Consecutive selectable
/// flow blocks (paragraphs, headings, lists, quotes) are grouped into
/// `flow` chunks of roughly `chunkTargetBytes`; each rich block (table,
/// code, math, image, callout, columns, divider) stays independent — with
/// its original block index retained so its selection descriptors match the
/// ordinary plan's `block-N` ids — so its own renderer handles it exactly
/// as in the normal block path.
///
/// A single flow block larger than the chunk target (e.g. a 1 MB paragraph,
/// which measured 2.4 s of whole-document TextKit layout) is split at word
/// boundaries into multiple `flow` chunks so no chunk scales with the
/// document.
enum MarkdownLargeChunk: Equatable {
    case flow(blocks: [MarkdownBlock])
    case block(MarkdownBlock, originalIndex: Int)
}

/// Groups a parsed document's blocks into bounded chunks. Pure and cheap:
/// byte estimates come from the blocks' own text (no re-serialization), and
/// the grouping is deterministic for a deterministic block list, so the plan
/// is directly unit-testable.
enum MarkdownLargeChunkPlanner {
    static func chunks(for blocks: [MarkdownBlock]) -> [MarkdownLargeChunk] {
        var chunks: [MarkdownLargeChunk] = []
        var pending: [MarkdownBlock] = []
        var pendingBytes = 0

        func flush() {
            guard !pending.isEmpty else { return }
            chunks.append(.flow(blocks: pending))
            pending = []
            pendingBytes = 0
        }

        for (originalIndex, block) in blocks.enumerated() {
            if block.isSelectableFlowBlock {
                let bytes = block.estimatedSourceBytes
                if pendingBytes + bytes > MarkdownLargeDocumentPolicy.chunkTargetBytes {
                    flush()
                }
                if bytes > MarkdownLargeDocumentPolicy.chunkTargetBytes {
                    // A single oversized flow block would produce one chunk
                    // scaling with the document; split it first.
                    flush()
                    chunks.append(contentsOf: splitOversized(block: block))
                    continue
                }
                pending.append(block)
                pendingBytes += bytes
            } else {
                flush()
                chunks.append(.block(block, originalIndex: originalIndex))
            }
        }
        flush()
        return chunks
    }

    /// Splits one oversized flow block at sub-block boundaries (list items,
    /// quote lines, or word boundaries inside a paragraph/heading) so every
    /// piece stays within the chunk target. Heading text is small by nature
    /// but shares the paragraph fallback for completeness.
    private static func splitOversized(block: MarkdownBlock) -> [MarkdownLargeChunk] {
        switch block {
        case .unorderedList(let items):
            return groupItems(items) { .unorderedList($0) }
        case .orderedList(let items):
            return groupItems(items) { .orderedList($0) }
        case .quote(let lines):
            return groupItems(lines) { .quote($0) }
        case .heading(let level, let text):
            return splitText(text) { .heading(level: level, text: $0) }
        case .paragraph(let text):
            return splitText(text) { .paragraph($0) }
        default:
            return [.flow(blocks: [block])]
        }
    }

    private static func groupItems<T>(_ items: [T], make: ([T]) -> MarkdownBlock) -> [MarkdownLargeChunk] {
        func itemBytes(_ item: T) -> Int {
            if let string = item as? String { return string.utf8.count }
            if let line = item as? MarkdownQuoteLine { return line.text.utf8.count }
            return 0
        }
        var chunks: [MarkdownLargeChunk] = []
        var group: [T] = []
        var groupBytes = 0
        for item in items {
            let bytes = itemBytes(item) + 32 // marker/separator allowance
            if groupBytes + bytes > MarkdownLargeDocumentPolicy.chunkTargetBytes, !group.isEmpty {
                chunks.append(.flow(blocks: [make(group)]))
                group = []
                groupBytes = 0
            }
            group.append(item)
            groupBytes += bytes
        }
        if !group.isEmpty { chunks.append(.flow(blocks: [make(group)])) }
        return chunks
    }

    /// Word-boundary text split into ~chunkTargetBytes pieces. Each piece
    /// renders as its own paragraph; soft wrapping makes consecutive pieces
    /// read as one flowing body with a little extra paragraph spacing.
    static func splitText(_ text: String, make: (String) -> MarkdownBlock) -> [MarkdownLargeChunk] {
        guard text.utf8.count > MarkdownLargeDocumentPolicy.chunkTargetBytes else {
            return [.flow(blocks: [make(text)])]
        }
        var chunks: [MarkdownLargeChunk] = []
        var pieceStart = text.startIndex
        var pieceBytes = 0
        var lastBoundary = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == " " || character == "\n" { lastBoundary = index }
            pieceBytes += String(character).utf8.count
            if pieceBytes >= MarkdownLargeDocumentPolicy.chunkTargetBytes {
                let cut = lastBoundary > pieceStart ? text.index(after: lastBoundary) : index
                chunks.append(.flow(blocks: [make(String(text[pieceStart..<cut]))]))
                pieceStart = cut
                pieceBytes = 0
                lastBoundary = cut
            }
            index = text.index(after: index)
        }
        if pieceStart < text.endIndex {
            chunks.append(.flow(blocks: [make(String(text[pieceStart...]))]))
        }
        return chunks
    }
}

extension MarkdownBlock {
    /// Byte estimate used only for chunk grouping decisions.
    var estimatedSourceBytes: Int {
        switch self {
        case .heading(_, let text): return text.utf8.count + 8
        case .paragraph(let text): return text.utf8.count + 2
        case .quote(let lines): return lines.reduce(0) { $0 + $1.text.utf8.count + 4 } + 4
        case .unorderedList(let items), .orderedList(let items):
            return items.reduce(0) { $0 + $1.utf8.count + 4 } + 4
        case .table(let headers, _, let rows):
            return headers.reduce(0) { $0 + $1.utf8.count + 4 }
                + rows.reduce(0) { $0 + $1.reduce(0) { $0 + $1.utf8.count + 4 } }
        case .code(_, let source): return source.utf8.count + 16
        case .callout(_, let text): return text.utf8.count + 16
        case .columns(let columns): return columns.reduce(0) { $0 + $1.utf8.count + 4 }
        case .image, .math, .divider: return 64
        }
    }
}

/// Pure decision step of the large-stream projection: given how much has
/// been promoted, revealed, and the latest safe boundary, returns the next
/// byte offset to promote up to (or nil when nothing should move). Kept
/// side-effect-free so the promotion policy is directly unit-testable.
enum LargeStreamPromotion {
    static func nextPromotionBoundary(
        promotedBytes: Int,
        revealedBytes: Int,
        tailWindowBytes: Int = MarkdownLargeDocumentPolicy.chunkTargetBytes,
        chunkTargetBytes: Int = MarkdownLargeDocumentPolicy.chunkTargetBytes,
        lastSafeBoundary: Int?
    ) -> Int? {
        // Only revealed content well past the live tail window is stable.
        let stableTarget = revealedBytes - tailWindowBytes
        guard stableTarget - promotedBytes > chunkTargetBytes else { return nil }

        // Prefer a safe boundary (never inside a fence/math/directive).
        let minimumNext = promotedBytes + chunkTargetBytes
        if let boundary = lastSafeBoundary, boundary >= minimumNext, boundary <= stableTarget {
            return boundary
        }
        // No safe boundary in reach — a giant unbroken paragraph — so
        // hard-cut one bounded piece, mirroring the planner's oversized-
        // block split, but only once the unpromoted region is clearly past
        // the tail window.
        if stableTarget - promotedBytes >= 2 * chunkTargetBytes {
            return min(stableTarget, promotedBytes + 2 * chunkTargetBytes)
        }
        return nil
    }
}

/// Incremental scanner that finds *safe* split points in a growing streamed
/// document — positions where slicing the source leaves both sides as
/// well-formed Markdown (never inside a fenced code block, math block, or
/// `:::` directive). Used by the large streaming path to promote a stable
/// prefix into immutable chunks while only re-parsing the live tail.
///
/// The scanner is resumable: it consumes only complete new lines each call,
/// so per-frame cost is O(delta), not O(document). Offsets are absolute
/// UTF-8 byte offsets into the whole accumulated text.
struct MarkdownStableBoundaryScanner {
    /// Absolute UTF-8 offset of the most recent safe block boundary — the
    /// position where the next block starts after a blank-line gap, outside
    /// every fenced/math/directive construct. Nil before any boundary exists.
    private(set) var lastSafeBoundary: Int?
    /// Absolute UTF-8 offset of everything fully scanned (complete lines).
    private(set) var consumedOffset: Int = 0
    /// Trailing partial line awaiting its newline.
    private var pendingLine = ""
    private var fenceMarker: String?
    private var inMath = false
    private var inDirective = false

    /// True when the scanner sits inside a fenced/math/directive region at
    /// the end of everything consumed — callers avoid promoting a prefix
    /// that ends mid-construct.
    var isInOpenConstruct: Bool { fenceMarker != nil || inMath || inDirective }

    /// Feeds an append-only delta and returns any newly discovered safe
    /// boundary offsets (absolute, UTF-8).
    mutating func append(_ delta: String) -> [Int] {
        var newBoundaries: [Int] = []
        pendingLine += delta

        while let newline = pendingLine.firstIndex(of: "\n") {
            let line = String(pendingLine[..<newline])
            let lineBytes = line.utf8.count + 1 // including the newline

            updateState(for: line.trimmingCharacters(in: .whitespaces))

            // A blank line outside every construct ends a block: everything
            // after this line is a fresh block, so the split point moves to
            // the next line's start. Consecutive blank lines keep moving it.
            if line.trimmingCharacters(in: .whitespaces).isEmpty,
               fenceMarker == nil, !inMath, !inDirective {
                let boundary = consumedOffset + lineBytes
                lastSafeBoundary = boundary
                newBoundaries.append(boundary)
            }

            consumedOffset += lineBytes
            pendingLine.removeSubrange(..<pendingLine.index(after: newline))
        }
        return newBoundaries
    }

    /// Processes the trailing partial line as if the stream had ended with
    /// a newline. Call once the stream is finished: without it, a document
    /// whose last line is a closing fence (no trailing newline) leaves the
    /// scanner reporting an open construct forever, and final promotion
    /// falls back to hard cuts that can land inside the block.
    mutating func finish() {
        guard !pendingLine.isEmpty else { return }
        let line = pendingLine
        pendingLine = ""
        updateState(for: line.trimmingCharacters(in: .whitespaces))
        if line.trimmingCharacters(in: .whitespaces).isEmpty,
           fenceMarker == nil, !inMath, !inDirective {
            // Match append()'s arithmetic: the boundary sits after the
            // (virtual) newline of the blank line.
            lastSafeBoundary = consumedOffset + line.utf8.count
        }
        consumedOffset += line.utf8.count
    }

    private mutating func updateState(for trimmedLine: String) {
        if let marker = fenceMarker {
            if trimmedLine.hasPrefix(marker) {
                fenceMarker = nil
            }
            return
        }
        if inMath {
            if trimmedLine == "$$" || trimmedLine == "\\]" { inMath = false }
            return
        }
        if inDirective {
            if trimmedLine == ":::" { inDirective = false }
            return
        }
        if trimmedLine.hasPrefix("```") { fenceMarker = "```" }
        else if trimmedLine.hasPrefix("~~~") { fenceMarker = "~~~" }
        else if trimmedLine == "$$" || trimmedLine == "\\[" { inMath = true }
        else if trimmedLine.hasPrefix(":::") {
            let name = trimmedLine.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
            if ["note", "info", "tip", "hint", "warning", "caution", "danger", "error", "important", "columns"].contains(name) {
                inDirective = true
            }
        }
    }
}
