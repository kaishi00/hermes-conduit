//
//  MarkdownRichContent.swift
//  Conduit
//
//  Bounding of expensive rich Markdown content by STRUCTURE, not by
//  whole-message bytes.
//
//  The large-document mode (PR #88) gates every protection behind the
//  whole-message byte threshold (100 KB). Two TestFlight crashes
//  (0x8BADF00D scene-update watchdog, main thread inside
//  ScrollViewCommitMutation under GraphHost.flushTransactions) came from
//  a response that was comfortably BELOW that threshold but carried a
//  pathological quantity of rich blocks — dozens of tables, Mermaid
//  diagrams, images, math, code fences. Source bytes are a poor proxy
//  for layout complexity: a 60 KB showcase with 30 tables mounts
//  thousands of TextKit cell views (plus width measurement for every
//  cell) in one layout pass, while 150 KB of prose stays cheap.
//
//  This file owns two bounds, both independent of the message size:
//
//  1. Block-local: a structurally complex table uses the paged
//     LargeMarkdownTable presentation (bounded column measurement on a
//     sampled prefix + explicit row batches), and the per-block
//     Mermaid/math/code guards from the large-document path apply to the
//     block itself wherever it renders.
//  2. Message-level: a response whose aggregate rich complexity exceeds
//     a bounded budget mounts a bounded PREFIX of rich blocks plus an
//     always-visible LIVE TAIL, with the middle behind an explicit
//     reveal. Ordinary messages — a table, a diagram, a few code blocks
//     — never enter this path.
//
//  The live tail is what keeps streaming correct in both directions:
//
//  - While a response STREAMS, the newest content (where the user is
//    reading) is always mounted, while the historical rich blocks behind
//    it stay bounded. Streaming therefore cannot eagerly mount an
//    unbounded pile of rich renderers — including the reconnect case
//    where a huge accumulated body arrives while still technically
//    streaming.
//  - When the message SETTLES, the mounted set does not change: the
//    prefix and the tail are computed from the block structure and the
//    reveal budget alone, never from the streaming flag. Content the
//    user was just reading cannot disappear at the transition.
//

import SwiftUI

// MARK: - Policy

/// Structural (non-byte) bounding policy for rich Markdown content.
/// Every decision here is derived from the blocks themselves — never
/// from the enclosing message's byte count — so the ordinary rendering
/// path inherits the #88 protections exactly when its own content is
/// expensive.
///
/// All planning functions take the per-block rich-unit vector
/// (unitsByBlock) rather than the blocks themselves: the vector is
/// computed once per parsed source and cached alongside it (see
/// MarkdownRenderCache), so repeated SwiftUI body evaluations never
/// re-walk table cells to rediscover the same budget. Blocks-based
/// conveniences remain for tests and one-shot callers.
enum MarkdownRichContentPolicy {
    // --- Block-local table complexity ---

    /// Tables with at least this many rows use the paged presentation:
    /// row mounting is the dominant cost (one TextKit view per cell),
    /// and past this count a single table owns a screenful of layout.
    static let complexTableRowCount = 40
    /// Header+row cell count at/above which a table uses the paged
    /// presentation — catches wide tables (many columns) whose row count
    /// alone looks moderate.
    static let complexTableCellCount = 200

    /// A table whose estimated source size reaches the existing
    /// large-table byte ceiling keeps that qualification, so behavior
    /// for byte-heavy tables (huge cells) is unchanged from #88.
    static func isComplexTable(headers: [String], rows: [[String]]) -> Bool {
        if rows.count >= complexTableRowCount { return true }
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        if rows.count * columnCount >= complexTableCellCount { return true }
        return tableEstimatedBytes(headers: headers, rows: rows)
            >= MarkdownLargeDocumentPolicy.largeTableBytes
    }

    /// Byte estimate of a table's own content (mirrors the
    /// estimatedSourceBytes measure the #88 planner already uses for
    /// tables, kept in one place so the two paths cannot drift).
    static func tableEstimatedBytes(headers: [String], rows: [[String]]) -> Int {
        var bytes: Int = 0
        for header in headers {
            bytes += header.utf8.count + 4
        }
        for row in rows {
            for cell in row {
                bytes += cell.utf8.count + 4
            }
        }
        return bytes
    }

    // --- Aggregate rich-layout budget ---

    /// Rich-layout units mounted from the front before the progressive
    /// reveal gate engages. Generous for ordinary messages (several
    /// tables, a diagram, a handful of code blocks and images all fit),
    /// bounded for pathological showcases.
    static let eagerRichUnitBudget = 16
    /// Units added per explicit reveal action (see revealBudget(after:)
    /// for the forward-progress guarantee).
    static let revealUnitBatch = 16
    /// Units of the ALWAYS-MOUNTED live tail: the newest blocks stay
    /// visible regardless of the reveal budget — while streaming (the
    /// region the user is reading) and after settling (nothing already
    /// shown may collapse away). Same order as the eager budget so the
    /// gap boundary sits roughly a screenful of rich content above the
    /// reading position.
    static let liveTailUnitBudget = 16
    /// Table cells represented by one unit — the cost of actually
    /// mounting and measuring that many TextKit cell views.
    static let tableCellsPerUnit = 64
    /// A remote image is web-backed (AsyncImage with a WKWebView
    /// fallback path), so it counts heavier than a local text block.
    static let imageUnits = 2
    /// Code bytes per unit; blocks above the #88 code threshold render
    /// a bounded preview first, so their initial cost stays near one
    /// screenful.
    static let codeBytesPerUnit = MarkdownLargeDocumentPolicy.chunkTargetBytes

    /// Eagerly mounted layout cost of one block, in rich-layout units.
    /// Flow blocks (paragraphs, headings, lists, quotes) are plain
    /// attributed text and cost nothing here. Paged (structurally
    /// complex) tables are charged for what they actually mount — the
    /// initial row batch, not the whole table.
    static func richUnits(_ block: MarkdownBlock) -> Int {
        switch block {
        case .table(let headers, _, let rows):
            let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
            if isComplexTable(headers: headers, rows: rows) {
                let mountedRowCount = min(rows.count, LargeMarkdownTable.initialRowBatch)
                let mountedCellCount = max((mountedRowCount + 1) * columnCount, 1)
                return max(1, units(forCells: mountedCellCount))
            }
            let cellCount = max((rows.count + 1) * columnCount, 1)
            return max(1, units(forCells: cellCount))
        case .code(_, let source):
            let byteCount = source.utf8.count
            return max(1, (byteCount + codeBytesPerUnit - 1) / codeBytesPerUnit)
        case .math:
            return 1
        case .image:
            return imageUnits
        case .heading, .paragraph, .quote, .unorderedList, .orderedList,
             .callout, .columns, .divider:
            return 0
        }
    }

    /// Per-block rich-unit vector for a whole parsed message. Computed
    /// once per source and cached with the rendering, so body
    /// re-evaluations reuse it instead of re-walking every table's
    /// cells.
    static func richUnitsByBlock(_ blocks: [MarkdownBlock]) -> [Int] {
        blocks.map(richUnits)
    }

    private static func units(forCells cells: Int) -> Int {
        let numerator = cells + tableCellsPerUnit - 1
        return numerator / tableCellsPerUnit
    }

    /// Aggregate rich-layout units of a whole parsed message.
    static func totalRichUnits(_ blocks: [MarkdownBlock]) -> Int {
        let units = richUnitsByBlock(blocks)
        return totalRichUnits(units)
    }

    static func totalRichUnits(_ unitsByBlock: [Int]) -> Int {
        unitsByBlock.reduce(0, +)
    }

    /// True when a message's rich content needs the progressive gate.
    static func needsBounding(_ blocks: [MarkdownBlock]) -> Bool {
        needsBounding(unitsByBlock: richUnitsByBlock(blocks))
    }

    static func needsBounding(unitsByBlock: [Int]) -> Bool {
        totalRichUnits(unitsByBlock) > eagerRichUnitBudget
    }

    /// Index of the first block held behind the reveal gate for a given
    /// unit budget (nil when everything fits). The block that crosses
    /// the budget is itself held back only when at least one earlier
    /// block is mounted, so a single legitimate rich block never leaves
    /// an empty message body.
    static func gateCut(blocks: [MarkdownBlock], unitBudget: Int) -> Int? {
        gateCut(unitsByBlock: richUnitsByBlock(blocks), unitBudget: unitBudget)
    }

    static func gateCut(unitsByBlock: [Int], unitBudget: Int) -> Int? {
        var units = 0
        for (index, blockUnits) in unitsByBlock.enumerated() {
            units += blockUnits
            if units > unitBudget, index > 0 {
                return index
            }
        }
        return nil
    }

    /// Start index of the always-visible live tail: the latest blocks
    /// whose combined units fit the tail budget. The FINAL block is
    /// always included, even when it alone exceeds the budget — the
    /// streaming reveal region must be visible no matter how expensive
    /// the newest block is. Zero when the whole message fits the tail
    /// budget.
    static func liveTailStart(
        unitsByBlock: [Int],
        unitBudget: Int = liveTailUnitBudget
    ) -> Int {
        guard !unitsByBlock.isEmpty else { return 0 }
        var total = 0
        var start = unitsByBlock.count
        while start > 0 {
            let next = unitsByBlock[start - 1]
            if total + next > unitBudget {
                break
            }
            total += next
            start -= 1
        }
        // At least the final block is always tail-mounted.
        return min(start, unitsByBlock.count - 1)
    }

    /// Number of blocks hidden behind the gate for a given budget: the
    /// gap between the mounted prefix and the always-mounted tail. Zero
    /// when the prefix and tail overlap (or no gate engages at all).
    static func hiddenBlockCount(unitsByBlock: [Int], unitBudget: Int) -> Int {
        guard let cut = gateCut(unitsByBlock: unitsByBlock, unitBudget: unitBudget) else {
            return 0
        }
        let tail = liveTailStart(unitsByBlock: unitsByBlock)
        return max(0, tail - cut)
    }

    /// Budget required for the mounted prefix to INCLUDE the block at
    /// index — the cumulative units through that block. Used by the
    /// reveal action so one tap always mounts at least one additional
    /// held-back block, even when that single block costs more than a
    /// normal reveal batch.
    static func budgetToInclude(unitsByBlock: [Int], index: Int) -> Int {
        guard index > 0, index <= unitsByBlock.count else { return eagerRichUnitBudget }
        var units = 0
        for position in 0...index {
            units += unitsByBlock[position]
        }
        return units
    }

    /// The next reveal budget: one batch more than the current budget,
    /// or enough to include the first gated block when that block alone
    /// costs more than the batch — whichever is larger. Forward progress
    /// is guaranteed (the gate cut strictly advances past at least one
    /// block) while staying bounded to a single block's cost.
    static func revealBudget(
        unitsByBlock: [Int],
        currentBudget: Int,
        batch: Int = revealUnitBatch
    ) -> Int {
        var next = currentBudget + batch
        if let cut = gateCut(unitsByBlock: unitsByBlock, unitBudget: currentBudget) {
            let including = budgetToInclude(unitsByBlock: unitsByBlock, index: cut)
            if including > next {
                next = including
            }
        }
        return next
    }
}

// MARK: - Bounded message body

/// The normal-path message body for responses whose aggregate rich
/// complexity exceeds the budget: identical block rendering, but only a
/// bounded PREFIX of rich blocks plus the ALWAYS-VISIBLE live TAIL mount
/// eagerly; the middle sits behind an explicit reveal.
///
/// The mounted set is computed from the block structure and the reveal
/// budget ALONE — never from a streaming flag — so opening a
/// structurally pathological (but byte-ordinary) response can never
/// synchronously mount an unbounded pile of SwiftUI/UIKit/WebKit layout
/// nodes, a streaming response keeps its newest content visible while
/// its history stays bounded, and the streaming → settled transition
/// cannot collapse content the user was just reading.
struct RichBudgetedMarkdownBody: View {
    let blocks: [MarkdownBlock]
    /// The message source, carried only as the selection-plan revision so
    /// segment registration mirrors the ordinary path's onChange contract.
    let source: String
    /// Per-block rich-unit vector, precomputed with the cached rendering
    /// (never re-walked from body).
    let richUnitsByBlock: [Int]
    let foregroundStyle: Color
    let usesAccentSurface: Bool
    let gatewayMediaDataURL: ((String) async -> String?)?
    let selectionCoordinator: MarkdownSelectionCoordinator
    let selectionSegments: [MarkdownSelectionSegmentDescriptor]
    var newestCharacterOpacities: [Double] = []

    @State private var mountedUnitBudget = MarkdownRichContentPolicy.eagerRichUnitBudget

    #if DEBUG
    /// Test instrumentation: block count mounted by the most recent body
    /// evaluation. Proves the gate (not luck) bounded the mounted set.
    /// Lock-guarded end to end, matching the other DEBUG counters.
    private static let debugLock = NSLock()
    private nonisolated(unsafe) static var debugMountedBlockCountStorage = 0
    private nonisolated(unsafe) static var debugMountedBlockIndicesStorage: [Int] = []

    nonisolated(unsafe) static var debugMountedBlockCount: Int {
        get {
            debugLock.lock()
            defer { debugLock.unlock() }
            return debugMountedBlockCountStorage
        }
        set {
            debugLock.lock()
            defer { debugLock.unlock() }
            debugMountedBlockCountStorage = newValue
        }
    }

    /// Indices of the blocks mounted by the most recent body evaluation —
    /// the exact mounted set, so tests can prove the streaming → settled
    /// transition never unmounts visible content.
    nonisolated(unsafe) static var debugMountedBlockIndices: [Int] {
        get {
            debugLock.lock()
            defer { debugLock.unlock() }
            return debugMountedBlockIndicesStorage
        }
        set {
            debugLock.lock()
            defer { debugLock.unlock() }
            debugMountedBlockIndicesStorage = newValue
        }
    }

    static func resetDebugInstrumentation() {
        debugMountedBlockCount = 0
        debugMountedBlockIndices = []
    }
    #endif

    /// The gate cut for the current budget: first hidden block index, or
    /// nil when the prefix covers everything.
    private var gateIndex: Int? {
        MarkdownRichContentPolicy.gateCut(
            unitsByBlock: richUnitsByBlock,
            unitBudget: mountedUnitBudget
        )
    }

    /// Start index of the always-mounted live tail.
    private var tailIndex: Int {
        MarkdownRichContentPolicy.liveTailStart(unitsByBlock: richUnitsByBlock)
    }

    var body: some View {
        // Mounted set = prefix(0..<cut) ∪ tail(tailIndex...). Both parts
        // are streaming-independent: the tail is where a streaming
        // response is being read (and where reveal characters fade), the
        // prefix is the bounded history the reveal budget has bought.
        // The gap between them is the only hidden region.
        let cut = gateIndex
        let tail = tailIndex
        let tailIsBeyondGate: Bool
        if let cut {
            tailIsBeyondGate = tail > cut
        } else {
            tailIsBeyondGate = false
        }
        let mountedPrefixEnd = cut ?? blocks.count
        let mountedTailStart = tailIsBeyondGate ? tail : blocks.count
        #if DEBUG
        Self.debugMountedBlockCount = mountedPrefixEnd
            + (blocks.count - mountedTailStart)
        var mountedIndices: [Int] = Array(0..<mountedPrefixEnd)
        if tailIsBeyondGate {
            mountedIndices.append(contentsOf: Array(mountedTailStart..<blocks.count))
        }
        Self.debugMountedBlockIndices = mountedIndices
        #endif
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<mountedPrefixEnd, id: \.self) { index in
                blockView(index)
            }
            if tailIsBeyondGate {
                revealFooter(remainingBlocks: mountedTailStart - mountedPrefixEnd)
                ForEach(mountedTailStart..<blocks.count, id: \.self) { index in
                    blockView(index)
                }
            }
        }
        .onAppear {
            selectionCoordinator.replaceSegments(selectionSegments, revision: source)
        }
        .onChange(of: source) { _, _ in
            selectionCoordinator.replaceSegments(selectionSegments, revision: source)
        }
        .modifier(MarkdownSelectionHost(coordinator: selectionCoordinator))
    }

    private func blockView(_ index: Int) -> some View {
        MarkdownBlockView(
            block: blocks[index],
            blockIndex: index,
            foregroundStyle: foregroundStyle,
            usesAccentSurface: usesAccentSurface,
            gatewayMediaDataURL: gatewayMediaDataURL,
            selectionCoordinator: selectionCoordinator,
            selectionSegments: selectionSegments,
            newestCharacterOpacities: index == blocks.count - 1
                ? newestCharacterOpacities
                : []
        )
    }

    /// The reveal affordance, in the same shape as the #88 expanded-view
    /// footer so both bounded presentations read as one system. The
    /// budget advance guarantees forward progress: one tap always mounts
    /// at least one additional held-back block, even when that block
    /// alone costs more than a normal batch.
    private func revealFooter(remainingBlocks: Int) -> some View {
        Button {
            mountedUnitBudget = MarkdownRichContentPolicy.revealBudget(
                unitsByBlock: richUnitsByBlock,
                currentBudget: mountedUnitBudget
            )
        } label: {
            Label(
                "Continue reading (\(remainingBlocks) sections left)",
                systemImage: "chevron.down"
            )
            .font(.footnote.weight(.semibold))
        }
        .tint(usesAccentSurface ? .white : .conduitAccent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityIdentifier("markdown.richReveal")
    }
}
