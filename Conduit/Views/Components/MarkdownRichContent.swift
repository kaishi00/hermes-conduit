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
//     a bounded budget mounts its rich blocks progressively (initial
//     batch + explicit reveal), reusing the progressive-rendering UX
//     shape of the #88 expanded view. Ordinary messages — a table, a
//     diagram, a few code blocks — never enter this path.
//

import SwiftUI

// MARK: - Policy

/// Structural (non-byte) bounding policy for rich Markdown content.
/// Every decision here is derived from the blocks themselves — never
/// from the enclosing message's byte count — so the ordinary rendering
/// path inherits the #88 protections exactly when its own content is
/// expensive.
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

    /// Rich-layout units mounted before the progressive reveal gate
    /// engages. Generous for ordinary messages (several tables, a
    /// diagram, a handful of code blocks and images all fit), bounded
    /// for pathological showcases.
    static let eagerRichUnitBudget = 16
    /// Units added per explicit reveal action.
    static let revealUnitBatch = 16
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

    private static func units(forCells cells: Int) -> Int {
        let numerator = cells + tableCellsPerUnit - 1
        return numerator / tableCellsPerUnit
    }

    /// Aggregate rich-layout units of a whole parsed message.
    static func totalRichUnits(_ blocks: [MarkdownBlock]) -> Int {
        blocks.reduce(0) { $0 + richUnits($1) }
    }

    /// True when a message's rich content needs the progressive gate.
    /// Deliberately cheap: the walk touches each block once with O(1)
    /// (tables: O(cells)) work — the same order as the parse itself.
    static func needsBounding(_ blocks: [MarkdownBlock]) -> Bool {
        totalRichUnits(blocks) > eagerRichUnitBudget
    }

    /// Index of the first block held behind the reveal gate for a given
    /// unit budget (nil when everything fits). The block that crosses
    /// the budget is itself held back only when at least one earlier
    /// block is mounted, so a single legitimate rich block never leaves
    /// an empty message body.
    static func gateCut(blocks: [MarkdownBlock], unitBudget: Int) -> Int? {
        var units = 0
        for (index, block) in blocks.enumerated() {
            units += richUnits(block)
            if units > unitBudget, index > 0 {
                return index
            }
        }
        return nil
    }
}

// MARK: - Bounded message body

/// The normal-path message body for responses whose aggregate rich
/// complexity exceeds the budget: identical block rendering, but rich
/// blocks mount progressively — an initial bounded batch, then explicit
/// reveal — so opening a structurally pathological (but byte-ordinary)
/// response can never synchronously mount an unbounded pile of
/// SwiftUI/UIKit/WebKit layout nodes.
///
/// While the message is STREAMING, the gate is bypassed: content grows
/// incrementally frame by frame, so the per-frame mount cost is the
/// small delta (the pre-existing behavior), and the live tail the user
/// is reading can never sit behind a reveal button. The gate engages on
/// the settled render — the exact scenario the watchdog crashes
/// reported (opening a session with one Markdown-heavy response).
struct RichBudgetedMarkdownBody: View {
    let blocks: [MarkdownBlock]
    /// The message source, carried only as the selection-plan revision so
    /// segment registration mirrors the ordinary path's onChange contract.
    let source: String
    let foregroundStyle: Color
    let usesAccentSurface: Bool
    let gatewayMediaDataURL: ((String) async -> String?)?
    let selectionCoordinator: MarkdownSelectionCoordinator
    let selectionSegments: [MarkdownSelectionSegmentDescriptor]
    var newestCharacterOpacities: [Double] = []
    var isStreaming: Bool = false

    @State private var mountedUnitBudget = MarkdownRichContentPolicy.eagerRichUnitBudget

    #if DEBUG
    /// Test instrumentation: block count mounted by the most recent body
    /// evaluation. Proves the gate (not luck) bounded the mounted set.
    /// Lock-guarded end to end, matching the other DEBUG counters.
    private static let debugLock = NSLock()
    private nonisolated(unsafe) static var debugMountedBlockCountStorage = 0

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

    static func resetDebugInstrumentation() {
        debugMountedBlockCount = 0
    }
    #endif

    private var gateCut: Int? {
        let cut = MarkdownRichContentPolicy.gateCut(
            blocks: blocks,
            unitBudget: mountedUnitBudget
        )
        #if DEBUG
        RichBudgetedMarkdownBody.debugMountedBlockCount = cut ?? blocks.count
        #endif
        return cut
    }

    var body: some View {
        // Streaming bypass: the gate exists to bound the ONE synchronous
        // mount of a pathological settled response; streaming mounts
        // grow by small deltas per frame and must keep the tail visible.
        // The gate is still resolved first so instrumentation records the
        // ungated count (blocks.count) for streaming bodies too.
        let gate = gateCut
        let cut = isStreaming ? nil : gate
        #if DEBUG
        if isStreaming {
            RichBudgetedMarkdownBody.debugMountedBlockCount = blocks.count
        }
        #endif
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.prefix(cut ?? blocks.count).enumerated()), id: \.offset) { index, block in
                MarkdownBlockView(
                    block: block,
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
            if let cut {
                revealFooter(remainingBlocks: blocks.count - cut)
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

    /// The reveal affordance, in the same shape as the #88 expanded-view
    /// footer so both bounded presentations read as one system.
    private func revealFooter(remainingBlocks: Int) -> some View {
        Button {
            mountedUnitBudget += MarkdownRichContentPolicy.revealUnitBatch
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
