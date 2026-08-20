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
    // --- Hardening additions (adversarial shapes) ---
    /// Byte ceilings for code presentation: a block with a few very long
    /// lines (minified JS, base64 blobs) must bound work by bytes as well
    /// as by line count.
    static let codePreviewLineCount = 200
    static let codePreviewBytes = 16_000
    static let codeSliceBytes = 64_000
    /// Hard maximum for one promoted streaming stable chunk. Kept far below
    /// the document threshold so a stable chunk can never route back into
    /// the large-document renderer, and so the MarkdownText render of a
    /// chunk is bounded regardless of how far ahead safe boundaries sit.
    static let maxStreamChunkBytes = 2 * chunkTargetBytes
    /// Tables at/above this estimated size use the paged presentation
    /// (bounded column measurement on a sampled prefix + row batches).
    static let largeTableBytes = 32_000
    /// Textual rich blocks (callouts, columns) above this size reproject
    /// their bodies into bounded inner text pieces.
    static let largeTextBlockBytes = chunkTargetBytes
    /// Math and Mermaid sources above this size drop the render action (the
    /// renderers are not chunkable); the source stays previewable/copyable.
    static let mathGuardBytes = 100_000
    static let mermaidGuardBytes = 100_000
    /// Byte budget for the per-chunk subset of message-wide reference
    /// definitions appended at parse time (see MarkdownReferenceResolver).
    static let referenceSubsetBudgetBytes = 8_000
    /// Per-cell byte ceiling in the paged large-table presentation: one
    /// 500 KB cell must not become an unbounded InlineMarkdown/TextKit
    /// operation or an unbounded width-measurement input. The cell renders
    /// a grapheme-safe bounded prefix; the full content remains in the
    /// message (Copy Response) — a documented pathological-only tradeoff.
    static let tableCellBytes = 8_000

    /// Grapheme-safe bounded cell text (or any bounded display text) with
    /// an explicit truncation marker.
    static func boundedDisplayText(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var bytes = 0
        var index = text.startIndex
        while index < text.endIndex {
            let characterBytes = String(text[index]).utf8.count
            if bytes + characterBytes > maxBytes { break }
            bytes += characterBytes
            index = text.index(after: index)
        }
        return String(text[..<index]) + " …"
    }

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

/// Pure slicer for large code blocks: contiguous source slices bounded by
/// BOTH a line ceiling and a UTF-8 byte ceiling. Concatenating the slices
/// reproduces the original source exactly (giant lines are cut at
/// whole-character boundaries with nothing inserted), which keeps Copy and
/// round-trip tests trivially sound.
enum MarkdownCodeSlicer {
    /// The single bounded preview piece: stops scanning as soon as the
    /// preview line or byte ceiling is reached, never walking or
    /// materializing the rest of the block. Safe to call from SwiftUI
    /// `body` for arbitrarily large sources.
    #if DEBUG
    /// Test instrumentation: UTF-8 bytes inspected by `firstSlice`, proving
    /// preview work is proportional to the configured budget rather than
    /// to the source length.
    private static let firstSliceInspectLock = NSLock()
    private nonisolated(unsafe) static var firstSliceInspectedBytesStorage = 0

    nonisolated(unsafe) static var firstSliceInspectedBytes: Int {
        get {
            firstSliceInspectLock.lock()
            defer { firstSliceInspectLock.unlock() }
            return firstSliceInspectedBytesStorage
        }
        set {
            firstSliceInspectLock.lock()
            defer { firstSliceInspectLock.unlock() }
            firstSliceInspectedBytesStorage = newValue
        }
    }
    #endif

    /// The single bounded preview piece. Contracts, all deterministic:
    /// - the result is always a prefix of the source;
    /// - the result's UTF-8 size never exceeds `maxBytes`;
    /// - at most `maxLines` complete lines are included;
    /// - the scan inspects O(maxBytes) source bytes — a pathological
    ///   newline-free block is abandoned as soon as its first line alone
    ///   exceeds the whole budget, never walked to the end.
    static func firstSlice(_ source: String, maxLines: Int, maxBytes: Int) -> String {
        #if DEBUG
        firstSliceInspectedBytes = 0
        #endif
        var lines = 0
        var bytes = 0      // UTF-8 bytes of complete lines included so far
        var lineBytes = 0  // running UTF-8 bytes of the current line
        var lineStart = source.startIndex
        var index = source.startIndex

        func inspect(_ count: Int) {
            #if DEBUG
            firstSliceInspectedBytes += count
            #endif
        }

        while index < source.endIndex {
            let character = source[index]
            inspect(String(character).utf8.count)
            if character == "\n" {
                let lineEnd = source.index(after: index)
                let totalLineBytes = lineBytes + 1 // including the newline
                let remaining = maxBytes - bytes
                if totalLineBytes > remaining {
                    // Including this line whole would exceed the budget:
                    // keep everything before it plus a grapheme-safe piece
                    // of it under the REMAINING budget.
                    return String(source[..<lineStart])
                        + boundedPrefix(of: source[lineStart..<lineEnd], maxBytes: remaining)
                }
                lines += 1
                bytes += totalLineBytes
                if lines >= maxLines || bytes >= maxBytes {
                    return String(source[..<lineEnd])
                }
                lineStart = lineEnd
                index = lineEnd
                lineBytes = 0
                continue
            }
            lineBytes += String(character).utf8.count
            if lineBytes > maxBytes {
                // The current line alone exceeds the entire budget — stop
                // scanning it (work stays proportional to maxBytes) and
                // take a bounded piece under the remaining budget.
                let remaining = maxBytes - bytes
                return String(source[..<lineStart])
                    + boundedPrefix(of: source[lineStart...], maxBytes: remaining)
            }
            index = source.index(after: index)
        }

        // Trailing partial line (no final newline).
        if lineStart < source.endIndex {
            let remaining = maxBytes - bytes
            if lineBytes > remaining {
                return String(source[..<lineStart])
                    + boundedPrefix(of: source[lineStart...], maxBytes: remaining)
            }
        }
        return source
    }

    /// Grapheme-safe prefix of `range` whose UTF-8 size never exceeds
    /// `maxBytes` — a grapheme is only included when it fits (checked
    /// before inclusion), so the only overshoot is impossible; a budget
    /// smaller than the first grapheme returns an empty prefix.
    private static func boundedPrefix(of range: Substring, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var bytes = 0
        var index = range.startIndex
        while index < range.endIndex {
            let characterBytes = String(range[index]).utf8.count
            if bytes + characterBytes > maxBytes { break }
            bytes += characterBytes
            index = range.index(after: index)
        }
        return String(range[..<index])
    }

    static func slice(_ source: String, maxLines: Int, maxBytes: Int) -> [String] {
        guard !source.isEmpty else { return [] }
        var slices: [String] = []
        var sliceStart = source.startIndex
        var lineStart = source.startIndex
        var lines = 0
        var bytes = 0
        var index = source.startIndex

        func flush(through end: String.Index) {
            guard sliceStart < end else { return }
            slices.append(String(source[sliceStart..<end]))
            sliceStart = end
            lines = 0
            bytes = 0
        }

        func emitGiantLinePieces(_ range: Range<String.Index>) {
            var pieceStart = range.lowerBound
            var pieceBytes = 0
            var walk = range.lowerBound
            while walk < range.upperBound {
                pieceBytes += String(source[walk]).utf8.count
                if pieceBytes >= maxBytes {
                    let cut = source.index(after: walk)
                    slices.append(String(source[pieceStart..<cut]))
                    pieceStart = cut
                    pieceBytes = 0
                }
                walk = source.index(after: walk)
            }
            if pieceStart < range.upperBound {
                slices.append(String(source[pieceStart..<range.upperBound]))
            }
        }

        while index < source.endIndex {
            if source[index] == "\n" {
                let lineEnd = source.index(after: index) // includes the newline
                let lineBytes = source[lineStart..<lineEnd].utf8.count
                if lineBytes > maxBytes {
                    // A single line larger than the whole slice budget: emit
                    // it as its own grapheme-aligned pieces.
                    flush(through: lineStart)
                    emitGiantLinePieces(lineStart..<lineEnd)
                    sliceStart = lineEnd
                    lines = 0
                    bytes = 0
                } else {
                    if lines + 1 > maxLines || bytes + lineBytes > maxBytes {
                        flush(through: lineStart)
                    }
                    lines += 1
                    bytes += lineBytes
                }
                lineStart = lineEnd
                index = lineEnd
                continue
            }
            index = source.index(after: index)
        }

        if lineStart < source.endIndex {
            let lineBytes = source[lineStart...].utf8.count
            if lineBytes > maxBytes {
                flush(through: lineStart)
                emitGiantLinePieces(lineStart..<source.endIndex)
                return slices
            }
            if lines + 1 > maxLines || bytes + lineBytes > maxBytes {
                flush(through: lineStart)
            }
        }
        flush(through: source.endIndex)
        return slices
    }
}

/// Incremental inline-marker balance for flow-text splitting. A cut is
/// "safe" when no inline construct visibly spans it: even backtick count
/// (inline code), zero open bracket depth (links/images/labels), and even
/// asterisk/underscore/tilde parity (emphasis/strikethrough). Escaped
/// characters (\*) do not count. This is deliberately a heuristic — it can
/// only choose between cut points, never alter text — and a pathological
/// unbalanceable window falls back to the plain target cut (rendered inline
/// markers may then appear literal in that one piece).
struct MarkdownInlineBalance {
    private var backticks = 0
    private var bracketDepth = 0
    private var asterisks = 0
    private var underscores = 0
    private var tildes = 0
    private var escaped = false

    mutating func consume(_ character: Character) {
        if escaped {
            escaped = false
            return
        }
        switch character {
        case "\\": escaped = true
        case "`": backticks += 1
        case "[": bracketDepth += 1
        case "]": bracketDepth = max(0, bracketDepth - 1)
        case "*": asterisks += 1
        case "_": underscores += 1
        case "~": tildes += 1
        default: break
        }
    }

    var isBalanced: Bool {
        bracketDepth == 0
            && backticks % 2 == 0
            && asterisks % 2 == 0
            && underscores % 2 == 0
            && tildes % 2 == 0
    }
}

/// Groups a parsed document's blocks into bounded chunks. Pure and cheap:
/// byte estimates come from the blocks' own text (no re-serialization), and
/// the grouping is deterministic for a deterministic block list, so the plan
/// is directly unit-testable.
enum MarkdownLargeChunkPlanner {
    #if DEBUG
    /// Test instrumentation: number of `splitText` invocations. Proves that
    /// SwiftUI body re-evaluations never re-split pathological text (the
    /// specialized rich-block pieces are computed once in preparation).
    /// Lock-guarded end to end: preparation runs off the MainActor while
    /// tests read/reset from the main thread.
    private static let splitCountLock = NSLock()
    private nonisolated(unsafe) static var splitTextCallCountStorage = 0

    nonisolated(unsafe) static var splitTextCallCount: Int {
        get {
            splitCountLock.lock()
            defer { splitCountLock.unlock() }
            return splitTextCallCountStorage
        }
        set {
            splitCountLock.lock()
            defer { splitCountLock.unlock() }
            splitTextCallCountStorage = newValue
        }
    }
    #endif

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
    ///
    /// Ordered lists: only the FIRST chunk of a split list keeps the real
    /// `.orderedList` rendering; continuation groups render as paragraphs
    /// with the ordinal baked into the text ("7. …") so numbering never
    /// restarts at 1. The baked-number styling differs from the styled list
    /// marker — a pathological-only formatting tradeoff.
    private static func splitOversized(block: MarkdownBlock) -> [MarkdownLargeChunk] {
        switch block {
        case .unorderedList(let items):
            return splitListItems(items, ordered: false)
        case .orderedList(let items):
            return splitListItems(items, ordered: true)
        case .quote(let lines):
            return splitQuoteLines(lines)
        case .heading(let level, let text):
            return splitText(text) { .heading(level: level, text: $0) }
        case .paragraph(let text):
            return splitText(text) { .paragraph($0) }
        default:
            return [.flow(blocks: [block])]
        }
    }

    private static func splitListItems(_ items: [String], ordered: Bool) -> [MarkdownLargeChunk] {
        let target = MarkdownLargeDocumentPolicy.chunkTargetBytes
        var chunks: [MarkdownLargeChunk] = []
        var group: [String] = []
        var groupStartIndex = 0
        var groupBytes = 0
        var emittedFirstGroup = false

        func flush() {
            guard !group.isEmpty else { return }
            if ordered && emittedFirstGroup {
                // Continuation of an ordered list: bake the real ordinals.
                let paragraphs = group.enumerated().map { offset, item in
                    MarkdownBlock.paragraph("\(groupStartIndex + offset + 1). \(taskStripped(item))")
                }
                chunks.append(.flow(blocks: paragraphs))
            } else {
                chunks.append(.flow(blocks: [ordered ? .orderedList(group) : .unorderedList(group)]))
                emittedFirstGroup = true
            }
            group = []
            groupBytes = 0
        }

        for (index, item) in items.enumerated() {
            let bytes = item.utf8.count + 32 // marker/separator allowance
            if bytes > target {
                // One pathologically huge item: its first piece keeps the
                // list semantics (or the baked ordinal); continuations are
                // plain paragraphs. For ordered lists the oversized item
                // consumes the "first group" slot so a later normal group
                // bakes its ordinals instead of restarting at 1.
                flush()
                if ordered { emittedFirstGroup = true }
                groupStartIndex = index + 1
                let task = MarkdownParser.taskItem(item)
                let baseText = task?.text ?? item
                let prefix = ordered ? "\(index + 1). " : ""
                let taskMarker = task.map { $0.complete ? "[x] " : "[ ] " } ?? ""
                let marked = taskMarker + baseText
                // Uniform paragraph presentation for oversized items and
                // their continuations keeps the pieces visually coherent
                // (the ordinal or task marker is baked into the text).
                chunks.append(contentsOf: splitText(marked) { piece in
                    .paragraph(prefix + piece)
                })
                continue
            }
            if groupBytes + bytes > target, !group.isEmpty {
                flush()
                groupStartIndex = index
            }
            group.append(item)
            groupBytes += bytes
        }
        flush()
        return chunks
    }

    private static func taskStripped(_ item: String) -> String {
        MarkdownParser.taskItem(item)?.text ?? item
    }

    private static func splitQuoteLines(_ lines: [MarkdownQuoteLine]) -> [MarkdownLargeChunk] {
        let target = MarkdownLargeDocumentPolicy.chunkTargetBytes
        var chunks: [MarkdownLargeChunk] = []
        var group: [MarkdownQuoteLine] = []
        var groupBytes = 0

        func flush() {
            guard !group.isEmpty else { return }
            chunks.append(.flow(blocks: [.quote(group)]))
            group = []
            groupBytes = 0
        }

        for line in lines {
            let bytes = line.text.utf8.count + 8
            if bytes > target {
                // A pathologically huge quote line splits into several
                // same-depth quote lines — quote chrome and depth semantics
                // are preserved for every piece.
                flush()
                chunks.append(contentsOf: splitText(line.text) { piece in
                    .quote([MarkdownQuoteLine(depth: line.depth, text: piece)])
                })
                continue
            }
            if groupBytes + bytes > target, !group.isEmpty {
                flush()
            }
            group.append(line)
            groupBytes += bytes
        }
        flush()
        return chunks
    }

    /// Word-boundary text split into ~chunkTargetBytes pieces. Each piece
    /// renders as its own paragraph; soft wrapping makes consecutive pieces
    /// read as one flowing body with a little extra paragraph spacing.
    ///
    /// Cut selection prefers the latest whitespace boundary whose prefix
    /// has balanced inline markers (code spans, links, emphasis), so a
    /// `**bold**`/`` `code` ``/`[link](…)` construct is not visibly broken
    /// across pieces. A window with no balanced candidate falls back to the
    /// plain whitespace cut — pathological inline soup may then show literal
    /// markers at one seam, never altered text.
    static func splitText(_ text: String, make: (String) -> MarkdownBlock) -> [MarkdownLargeChunk] {
        #if DEBUG
        splitTextCallCount += 1
        #endif
        guard text.utf8.count > MarkdownLargeDocumentPolicy.chunkTargetBytes else {
            return [.flow(blocks: [make(text)])]
        }
        var chunks: [MarkdownLargeChunk] = []
        var pieceStart = text.startIndex
        var pieceBytes = 0
        var lastWhitespace: String.Index?
        var lastBalanced: String.Index?
        var balance = MarkdownInlineBalance()
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            balance.consume(character)
            if character == " " || character == "\n" {
                lastWhitespace = index
                if balance.isBalanced {
                    lastBalanced = text.index(after: index)
                }
            }
            pieceBytes += String(character).utf8.count
            if pieceBytes >= MarkdownLargeDocumentPolicy.chunkTargetBytes {
                let cut: String.Index
                if let balanced = lastBalanced, balanced > pieceStart, balanced <= text.index(after: index) {
                    cut = balanced
                } else if let boundary = lastWhitespace, boundary > pieceStart {
                    cut = text.index(after: boundary)
                } else {
                    cut = text.index(after: index)
                }
                chunks.append(.flow(blocks: [make(String(text[pieceStart..<cut]))]))
                pieceStart = cut
                pieceBytes = 0
                lastWhitespace = nil
                lastBalanced = nil
                // A balanced cut leaves the remainder marker-free, so the
                // balance state legitimately restarts with the new piece;
                // rewind so characters between the cut and the triggering
                // index are consumed by the new piece's own accounting.
                balance = MarkdownInlineBalance()
                index = cut
                continue
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

/// Pure decision step of the large-stream projection. Returns the next byte
/// offset to promote up to (or nil when nothing should move). Side-effect
/// free so the policy is directly unit-testable.
///
/// Selection seeks the LATEST safe boundary inside a bounded window
/// `[promoted + minChunk, min(promoted + maxChunk, stableTarget)]` — never
/// the globally latest boundary, which could sit hundreds of KB ahead and
/// produce a huge stable chunk that re-enters whole-document rendering.
///
/// With no boundary in the window:
/// - if the stable target sits inside a known construct span (fence/math/
///   directive), promotion WAITS — a hard cut must never split a construct;
/// - otherwise the text is genuinely unstructured prose and a bounded,
///   grapheme-aligned hard cut advances one piece.
enum LargeStreamPromotion {
    static func nextPromotionBoundary(
        promotedBytes: Int,
        revealedBytes: Int,
        tailWindowBytes: Int = MarkdownLargeDocumentPolicy.chunkTargetBytes,
        minChunkBytes: Int = MarkdownLargeDocumentPolicy.chunkTargetBytes,
        maxChunkBytes: Int = MarkdownLargeDocumentPolicy.maxStreamChunkBytes,
        boundaries: [Int],
        constructIntervals: [(start: Int, end: Int?)] = []
    ) -> Int? {
        // Only revealed content well past the live tail window is stable.
        let stableTarget = revealedBytes - tailWindowBytes
        guard stableTarget - promotedBytes > minChunkBytes else { return nil }

        let minimumNext = promotedBytes + minChunkBytes
        let windowEnd = min(promotedBytes + maxChunkBytes, stableTarget)

        // Latest safe boundary inside the bounded window.
        if let boundary = boundaries.last(where: { $0 >= minimumNext && $0 <= windowEnd }) {
            return boundary
        }

        // Structural guard: never hard-cut through a construct. BOTH the
        // stable target and the actual candidate cut offset must sit
        // outside every recorded construct — a target beyond a fence can
        // still receive a fallback cut that lands inside it.
        func isInsideConstruct(_ offset: Int) -> Bool {
            constructIntervals.contains { interval in
                let end = interval.end ?? Int.max
                return offset > interval.start && offset < end
            }
        }
        if isInsideConstruct(stableTarget) { return nil }

        // Unstructured prose: bounded hard-cut fallback, still guarded by
        // the construct check on the candidate itself. Promotion waits for
        // a real boundary instead; if the construct never closes, the tail
        // itself eventually crosses the large-document threshold and
        // renders through the bounded collapsed presentation.
        if stableTarget - promotedBytes >= 2 * minChunkBytes {
            let cut = min(stableTarget, promotedBytes + 2 * minChunkBytes)
            return isInsideConstruct(cut) ? nil : cut
        }
        return nil
    }
}

/// Per-chunk subsetting of message-wide reference definitions. Large-mode
/// chunks must not append an arbitrarily large global definition block to
/// every Foundation parse; the one-time off-main preparation computes, for
/// each chunk, the definitions whose labels that chunk's text actually
/// references (Foundation stays the semantic resolver — unused definitions
/// render invisibly under `.full`, exactly the property PR #75 relies on).
enum MarkdownReferenceResolver {
    struct Definition: Equatable {
        let label: String
        let markdown: String
    }

    /// Splits a definitions context into individual definition lines with
    /// their labels (the same single-line subset `parseDocument` collects).
    static func definitions(from context: MarkdownReferenceContext) -> [Definition] {
        guard context.containsDefinitions else { return [] }
        return context.definitionsMarkdown
            .components(separatedBy: "\n")
            .compactMap { line in
                guard let range = line.range(of: #"^\[([^\[\]\^][^\[\]]*)\]:"#, options: .regularExpression) else {
                    return nil
                }
                // The whole-match range covers "[label]:" — strip the
                // brackets and colon, keeping only the label.
                let label = String(line[range].dropFirst().dropLast(2))
                guard !label.isEmpty else { return nil }
                return Definition(label: label.lowercased(), markdown: line)
            }
    }

    /// Labels referenced by a chunk's text, in any of the Foundation forms
    /// (`[text][label]`, `[label][]`, shortcut `[label]`). Over-inclusion is
    /// harmless (unused definitions are invisible); under-inclusion would
    /// break links, so the scan is deliberately generous.
    static func referencedLabels(in text: String) -> Set<String> {
        var labels = Set<String>()
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "[" else {
                index = text.index(after: index)
                continue
            }
            // Collect one single-level bracket group. Nested brackets or a
            // newline inside disqualify it from every reference form.
            var walk = text.index(after: index)
            var inner: [Character] = []
            var closed = false
            while walk < text.endIndex {
                let character = text[walk]
                if character == "]" { closed = true; break }
                if character == "[" || character == "\n" { break }
                inner.append(character)
                walk = text.index(after: walk)
            }
            if closed, !inner.isEmpty, inner.first != "^" {
                labels.insert(String(inner).lowercased())
                index = text.index(after: walk)
            } else {
                index = text.index(after: index)
            }
        }
        return labels
    }

    /// The bounded per-chunk definition context: only definitions whose
    /// labels appear in `text`, capped at `budgetBytes` (a pathological
    /// chunk referencing everything still parses against a bounded block;
    /// links beyond the budget degrade to literal text in that one chunk).
    static func subset(
        for text: String,
        definitions: [Definition],
        budgetBytes: Int = MarkdownLargeDocumentPolicy.referenceSubsetBudgetBytes
    ) -> MarkdownReferenceContext {
        guard !definitions.isEmpty else { return .empty }
        let used = referencedLabels(in: text)
        guard !used.isEmpty else { return .empty }
        var selected: [String] = []
        var bytes = 0
        for definition in definitions where used.contains(definition.label) {
            if bytes + definition.markdown.utf8.count + 1 > budgetBytes { break }
            selected.append(definition.markdown)
            bytes += definition.markdown.utf8.count + 1
        }
        guard !selected.isEmpty else { return .empty }
        return MarkdownReferenceContext(definitionsMarkdown: selected.joined(separator: "\n"))
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
    /// The close marker the open math region expects (`$$` or `\]`), so a
    /// block opened with one cannot close on the other.
    private var mathClose: String?
    private var inDirective = false

    /// True when the scanner sits inside a fenced/math/directive region at
    /// the end of everything consumed — callers avoid promoting a prefix
    /// that ends mid-construct.
    var isInOpenConstruct: Bool { fenceMarker != nil || mathClose != nil || inDirective }

    /// Absolute byte spans of every fenced/math/directive construct seen so
    /// far (an open construct has a nil end). The streaming promotion policy
    /// refuses to hard-cut through a span that contains the current stable
    /// target. One interval per construct — bounded by construct count.
    private(set) var constructIntervals: [(start: Int, end: Int?)] = []

    /// Feeds an append-only delta and returns any newly discovered safe
    /// boundary offsets (absolute, UTF-8). The delta's complete lines are
    /// processed in place — only the trailing partial is buffered — so cost
    /// is O(delta) with no repeated prefix shifts even for one-shot bulk
    /// feeds (threshold crossing, branch-swap reseed).
    mutating func append(_ delta: String) -> [Int] {
        var newBoundaries: [Int] = []
        var remainder = delta[...]

        // A buffered partial continues with the delta's first line.
        if !pendingLine.isEmpty {
            if let separator = Self.firstLineSeparator(in: remainder) {
                pendingLine += remainder[..<separator.index]
                consumeCompleteLine(pendingLine, separatorBytes: separator.byteLength, boundaries: &newBoundaries)
                pendingLine = ""
                remainder = remainder[remainder.index(after: separator.index)...]
            } else {
                pendingLine += remainder
                return newBoundaries
            }
        }

        while let separator = Self.firstLineSeparator(in: remainder) {
            consumeCompleteLine(
                String(remainder[..<separator.index]),
                separatorBytes: separator.byteLength,
                boundaries: &newBoundaries
            )
            remainder = remainder[remainder.index(after: separator.index)...]
        }
        pendingLine += remainder
        return newBoundaries
    }

    /// Swift treats "\r\n" as a single grapheme, so a plain
    /// `firstIndex(of: "\n")` finds nothing in CRLF text and the whole
    /// document reads as one line. A line separator here is the "\n"
    /// grapheme (1 UTF-8 byte) or the "\r\n" grapheme (2 bytes); a lone
    /// "\r" is not a separator, matching `parseDocument`'s CRLF-only
    /// normalization.
    private static func firstLineSeparator(in text: Substring) -> (index: Substring.Index, byteLength: Int)? {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\n" { return (index, 1) }
            if character == "\r\n" { return (index, 2) }
            index = text.index(after: index)
        }
        return nil
    }

    private mutating func consumeCompleteLine(_ line: String, separatorBytes: Int, boundaries: inout [Int]) {
        let lineBytes = line.utf8.count + separatorBytes // including the separator
        // CRLF input (parseDocument normalizes it, so upstream can deliver
        // it): the \r rides the line content, and .whitespaces trimming
        // does not remove it — strip it for state/blank checks while the
        // byte accounting above keeps counting it.
        let normalized = line.hasSuffix("\r") ? String(line.dropLast()) : line
        let wasInConstruct = fenceMarker != nil || mathClose != nil || inDirective
        let lineStartOffset = consumedOffset
        updateStateForLine(normalized.trimmingCharacters(in: .whitespaces), lineStartOffset: lineStartOffset, lineBytes: lineBytes)
        let isInConstruct = fenceMarker != nil || mathClose != nil || inDirective
        if wasInConstruct && !isInConstruct, !constructIntervals.isEmpty {
            constructIntervals[constructIntervals.count - 1].end = consumedOffset + lineBytes
        }
        _ = boundaries

        // A blank line outside every construct ends a block: everything
        // after this line is a fresh block, so the split point moves to the
        // next line's start. Consecutive blank lines keep moving it.
        if normalized.trimmingCharacters(in: .whitespaces).isEmpty,
           fenceMarker == nil, mathClose == nil, !inDirective {
            let boundary = consumedOffset + lineBytes
            lastSafeBoundary = boundary
            boundaries.append(boundary)
        }
        consumedOffset += lineBytes
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
        let normalized = line.hasSuffix("\r") ? String(line.dropLast()) : line
        let wasInConstruct = fenceMarker != nil || mathClose != nil || inDirective
        updateStateForLine(
            normalized.trimmingCharacters(in: .whitespaces),
            lineStartOffset: consumedOffset,
            lineBytes: line.utf8.count
        )
        if wasInConstruct && !(fenceMarker != nil || mathClose != nil || inDirective), !constructIntervals.isEmpty {
            constructIntervals[constructIntervals.count - 1].end = consumedOffset + line.utf8.count
        }
        if normalized.trimmingCharacters(in: .whitespaces).isEmpty,
           fenceMarker == nil, mathClose == nil, !inDirective {
            // Match append()'s arithmetic: the boundary sits after the
            // (virtual) newline of the blank line.
            lastSafeBoundary = consumedOffset + line.utf8.count
        }
        consumedOffset += line.utf8.count
    }

    private mutating func updateStateForLine(_ trimmedLine: String, lineStartOffset: Int, lineBytes: Int) {
        if let marker = fenceMarker {
            if trimmedLine.hasPrefix(marker) {
                fenceMarker = nil
            }
            return
        }
        if let close = mathClose {
            if trimmedLine == close { mathClose = nil }
            return
        }
        if inDirective {
            if trimmedLine == ":::" { inDirective = false }
            return
        }
        if trimmedLine.hasPrefix("```") {
            fenceMarker = "```"
            constructIntervals.append((start: lineStartOffset, end: nil))
        } else if trimmedLine.hasPrefix("~~~") {
            fenceMarker = "~~~"
            constructIntervals.append((start: lineStartOffset, end: nil))
        } else if trimmedLine == "$$" {
            mathClose = "$$"
            constructIntervals.append((start: lineStartOffset, end: nil))
        } else if trimmedLine == "\\[" {
            mathClose = "\\]"
            constructIntervals.append((start: lineStartOffset, end: nil))
        } else if trimmedLine.hasPrefix(":::") {
            let name = trimmedLine.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
            if ["note", "info", "tip", "hint", "warning", "caution", "danger", "error", "important", "columns"].contains(name) {
                inDirective = true
                constructIntervals.append((start: lineStartOffset, end: nil))
            }
        }
    }
}
