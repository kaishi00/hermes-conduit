//
//  MarkdownLargeDocumentView.swift
//  Conduit
//
//  Bounded presentation for messages at or above the large-document
//  threshold. See MarkdownLargeDocument.swift for the measured policy.
//
//  Shape (every stage bounded — nothing here scales with the whole source):
//
//      collapsed:  synchronous render of a ≤16 KB prefix through the
//                  ordinary MarkdownText fast path, plus a banner
//      expanded:   structural parse + chunk plan off the MainActor, then
//                  progressive rendering of ~8 KB chunks — each flow chunk
//                  is a memoized attributed string inside one
//                  SelectableTextView, rich blocks reuse the ordinary block
//                  renderer, and oversized code blocks render as line
//                  slices with off-main highlighting
//

import SwiftUI
import UIKit

/// Entry point used by `MarkdownText` when the source meets the large-
/// document policy. Settled messages open collapsed with a bounded preview;
/// expanding parses the full document off-main and renders it progressively.
///
/// Deliberate UX tradeoff: a streamed response renders uncollapsed while it
/// grows (the user is reading the tail), then adopts this collapsed form
/// once it settles into the transcript — every large message behaves the
/// same way on reopen, and the transcript never carries an eagerly expanded
/// megabyte message.
struct LargeMarkdownDocumentView: View {
    let source: String
    let foregroundStyle: Color
    let usesAccentSurface: Bool
    let gatewayMediaDataURL: ((String) async -> String?)?

    @State private var expanded = false

    var body: some View {
        if expanded {
            LargeMarkdownExpandedView(
                source: source,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                gatewayMediaDataURL: gatewayMediaDataURL
            )
        } else {
            collapsedView
        }
    }

    private var collapsedView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The preview renders synchronously through the ordinary fast
            // path — bounded by policy.previewBytes, so first presentation
            // (session load, history scroll) never parses the full source.
            // Reference-style links defined later in the document stay
            // literal here; the expanded render resolves them message-wide.
            MarkdownText(
                source: Self.previewSource(of: source),
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                gatewayMediaDataURL: gatewayMediaDataURL
            )

            LargeDocumentBanner(
                byteCount: source.utf8.count,
                usesAccentSurface: usesAccentSurface,
                expand: { expanded = true }
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A ≤previewBytes slice cut at the last blank line inside the window so
    /// the preview ends on a block boundary when possible. The window is
    /// byte-precise (`String.prefix(_:)` counts characters, which would
    /// triple the synchronous preview budget for CJK/emoji text), stepping
    /// back to a whole-character boundary when the byte cut lands mid-
    /// grapheme.
    static func previewSource(of source: String) -> String {
        guard source.utf8.count > MarkdownLargeDocumentPolicy.previewBytes else { return source }
        let utf8 = source.utf8
        var windowEnd: String.Index?
        var offset = MarkdownLargeDocumentPolicy.previewBytes
        while offset > 0 {
            if let byteIndex = utf8.index(utf8.startIndex, offsetBy: offset, limitedBy: utf8.endIndex),
               let characterIndex = String.Index(byteIndex, within: source) {
                windowEnd = characterIndex
                break
            }
            offset -= 1
        }
        guard let end = windowEnd else {
            // Unreachable for real UTF-8 (byte 0 always aligns), kept total.
            return source
        }
        let window = source[..<end]
        if let lastBreak = window.range(of: "\n\n", options: .backwards) {
            return String(source[..<lastBreak.lowerBound])
        }
        return String(window)
    }
}

private struct LargeDocumentBanner: View {
    let byteCount: Int
    let usesAccentSurface: Bool
    let expand: () -> Void

    private var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "This message is very large (\(sizeLabel))",
                systemImage: "doc.text.magnifyingglass"
            )
            .font(.footnote.weight(.semibold))
            .foregroundStyle(usesAccentSurface ? Color.white.opacity(0.86) : .secondary)

            Button(action: expand) {
                Label("Show full message", systemImage: "chevron.down")
                    .font(.footnote.weight(.semibold))
            }
            .tint(usesAccentSurface ? .white : .conduitAccent)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            usesAccentSurface ? Color.black.opacity(0.13) : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    usesAccentSurface ? Color.white.opacity(0.24) : Color.secondary.opacity(0.20),
                    lineWidth: 1
                )
        }
    }
}

// MARK: - Preparation

/// The result of the off-main preparation pass. Value types throughout, so
/// the pass is cancellation-safe to hand back; `sourceIdentity` guards
/// against a stale pass populating a changed message.
struct LargeMarkdownPreparedDocument {
    let chunks: [MarkdownLargeChunk]
    let references: MarkdownReferenceContext
    /// Selection descriptors in document order — one synthetic descriptor
    /// per flow chunk, the ordinary per-block descriptors (original `block-N`
    /// ids included) for rich blocks — so cross-chunk selection works
    /// through the shared coordinator exactly like cross-block selection.
    let segmentDescriptors: [MarkdownSelectionSegmentDescriptor]
    /// Selection descriptors for each chunk (flow chunks carry their single
    /// synthetic descriptor; rich chunks carry their block's descriptors).
    let descriptorsByChunk: [[MarkdownSelectionSegmentDescriptor]]
    let sourceIdentity: String

    /// Pure string work — no UIKit — so it runs off the MainActor.
    /// (`MarkdownParser.parseDocument` is a plain static over value types;
    /// its Foundation `AttributedString(markdown:)` probes are thread-safe.)
    static func prepare(_ source: String) -> LargeMarkdownPreparedDocument {
        let document = MarkdownParser.parseDocument(source)
        let chunks = MarkdownLargeChunkPlanner.chunks(for: document.blocks)

        // Slice the ordinary per-block plan by original block index so rich
        // chunks get exactly the descriptors (and `block-N` ids) their
        // MarkdownBlockView lookups expect.
        let blockPlan = MarkdownSelectionSegmentPlan.descriptors(for: document.blocks)
        var blockRanges: [Range<Int>] = []
        var cursor = 0
        for block in document.blocks {
            let count = MarkdownSelectionSegmentPlan.segmentCount(of: block)
            blockRanges.append(cursor..<(cursor + count))
            cursor += count
        }

        var descriptorsByChunk: [[MarkdownSelectionSegmentDescriptor]] = []
        var all: [MarkdownSelectionSegmentDescriptor] = []
        for (chunkIndex, chunk) in chunks.enumerated() {
            switch chunk {
            case .flow:
                let descriptor = MarkdownSelectionSegmentDescriptor(
                    id: "lmd-flow-\(chunkIndex)",
                    order: all.count,
                    separatorBefore: all.isEmpty ? "" : "\n\n"
                )
                descriptorsByChunk.append([descriptor])
                all.append(descriptor)
            case .block(_, let originalIndex):
                let range = blockRanges[originalIndex]
                // Rebase the slice's order values onto the running global
                // counter so chunk order and document order agree.
                let base = blockPlan[range].first?.order ?? 0
                let slice = blockPlan[range].map { descriptor in
                    MarkdownSelectionSegmentDescriptor(
                        id: descriptor.id,
                        order: all.count + (descriptor.order - base),
                        separatorBefore: descriptor.separatorBefore
                    )
                }
                descriptorsByChunk.append(slice)
                all.append(contentsOf: slice)
            }
        }

        return LargeMarkdownPreparedDocument(
            chunks: chunks,
            references: document.references,
            segmentDescriptors: all,
            descriptorsByChunk: descriptorsByChunk,
            sourceIdentity: Self.identity(of: source)
        )
    }

    static func identity(of source: String) -> String {
        "\(source.utf8.count)-\(source.hashValue)"
    }
}

// MARK: - Expanded document

/// Expanded body: parse off-main, render chunks progressively. Chunks
/// materialize in batches as the user scrolls — a monotonic window that
/// only grows downward, so scroll position never jumps.
struct LargeMarkdownExpandedView: View {
    let source: String
    let foregroundStyle: Color
    let usesAccentSurface: Bool
    let gatewayMediaDataURL: ((String) async -> String?)?

    @StateObject private var selectionCoordinator = MarkdownSelectionCoordinator()
    @State private var prepared: LargeMarkdownPreparedDocument?
    /// How many chunks are materialized in the view hierarchy.
    @State private var renderedChunkCount = LargeMarkdownExpandedView.initialChunkBatch
    /// Re-entrancy guard: at most one window extension per runloop turn.
    /// Without it, a batch of simultaneous onAppear calls (a plain VStack
    /// fires onAppear on insertion, not visibility) cascades into mounting
    /// every chunk of a many-thousand-chunk document in one layout pass.
    @State private var isExtendingWindow = false

    /// First synchronous batch: enough to fill a screen at typical chunk
    /// heights while keeping per-chunk work in single-digit milliseconds.
    static let initialChunkBatch = 12
    private static let chunkBatch = 12
    /// Hard ceiling on simultaneously mounted chunks. Documents made of
    /// pathological tiny blocks (a mini-table after every sentence) can
    /// produce thousands of chunks; past the ceiling the footer becomes a
    /// Continue control, so the mounted-view count is bounded by
    /// construction rather than by how fast a layout pass fires onAppear.
    private static let maximumMountedChunks = 480

    private var sourceIdentity: String { LargeMarkdownPreparedDocument.identity(of: source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let prepared {
                ForEach(0..<renderedChunkCount, id: \.self) { index in
                    chunkView(prepared, chunk: prepared.chunks[index], index: index)
                        .onAppear {
                            extendWindowIfNecessary(lastAppearedIndex: index, total: prepared.chunks.count)
                        }
                }
                if renderedChunkCount < prepared.chunks.count {
                    progressFooter(remaining: prepared.chunks.count - renderedChunkCount)
                }
            } else {
                LargeDocumentPreparingView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.markdownReferences, prepared?.references ?? .empty)
        .modifier(MarkdownSelectionHost(coordinator: selectionCoordinator))
        .task(id: sourceIdentity) {
            // Structural parsing is pure string work — measured 192 ms at
            // 1 MB — so it runs off the MainActor; nothing UIKit happens
            // until the per-chunk attributed builds below.
            let currentSource = source
            let plan = await Task.detached(priority: .userInitiated) {
                LargeMarkdownPreparedDocument.prepare(currentSource)
            }.value
            guard !Task.isCancelled, plan.sourceIdentity == sourceIdentity else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                prepared = plan
                // Clamped: a large document can legitimately produce fewer
                // chunks than one batch (a handful of giant rich blocks),
                // and chunkView indexes prepared.chunks directly.
                renderedChunkCount = min(Self.initialChunkBatch, plan.chunks.count)
            }
        }
        .onAppear {
            registerSegments()
        }
        .onChange(of: prepared?.sourceIdentity) { _, _ in
            registerSegments()
        }
        .onDisappear {
            selectionCoordinator.clearSelection()
        }
    }

    private func registerSegments() {
        guard let prepared else { return }
        selectionCoordinator.replaceSegments(prepared.segmentDescriptors, revision: prepared.sourceIdentity)
    }

    @ViewBuilder
    private func chunkView(_ prepared: LargeMarkdownPreparedDocument, chunk: MarkdownLargeChunk, index: Int) -> some View {
        switch chunk {
        case .flow(let blocks):
            LargeFlowChunkView(
                blocks: blocks,
                references: prepared.references,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                selectionCoordinator: selectionCoordinator,
                selectionSegment: prepared.descriptorsByChunk[index].first
            )
            .id("\(prepared.sourceIdentity)-\(index)")
        case .block(let block, let originalIndex):
            // Rich blocks reuse the ordinary block renderer — same views,
            // same selection ids — except oversized code, which gets the
            // sliced / async-highlighted presentation.
            if case .code(let language, let code) = block,
               MarkdownLanguage.normalized(language) != "mermaid",
               MarkdownLargeDocumentPolicy.isLargeCodeBlock(code) {
                LargeCodeBlockView(
                    source: code,
                    language: language,
                    usesAccentSurface: usesAccentSurface
                )
                .id("\(prepared.sourceIdentity)-\(index)")
            } else {
                MarkdownBlockView(
                    block: block,
                    blockIndex: originalIndex,
                    foregroundStyle: foregroundStyle,
                    usesAccentSurface: usesAccentSurface,
                    gatewayMediaDataURL: gatewayMediaDataURL,
                    selectionCoordinator: selectionCoordinator,
                    selectionSegments: prepared.descriptorsByChunk[index],
                    newestCharacterOpacities: []
                )
                .id("\(prepared.sourceIdentity)-\(index)")
            }
        }
    }

    /// Window growth: only the last mounted chunk triggers an extension,
    /// only one batch per runloop turn, and never past the mounted cap —
    /// see `maximumMountedChunks`.
    private func extendWindowIfNecessary(lastAppearedIndex: Int, total: Int) {
        guard
            lastAppearedIndex == renderedChunkCount - 1,
            renderedChunkCount < total,
            renderedChunkCount < Self.maximumMountedChunks,
            !isExtendingWindow
        else { return }
        isExtendingWindow = true
        Task { @MainActor in
            renderedChunkCount = Self.nextWindowCount(current: renderedChunkCount, total: total)
            isExtendingWindow = false
        }
    }

    /// Next mounted-chunk count: one batch more, clamped to the document's
    /// chunk count (the remaining chunks past the cap can be fewer than one
    /// batch, and chunkView indexes prepared.chunks directly).
    static func nextWindowCount(current: Int, total: Int) -> Int {
        min(current + chunkBatch, total)
    }

    /// Total chunk count read through @State: dynamic, so a button action
    /// firing twice before SwiftUI rebuilds still sees the live value
    /// (a body-time capture could be stale and overflow the array).
    private var preparedChunkTotal: Int {
        prepared?.chunks.count ?? 0
    }

    @ViewBuilder
    private func progressFooter(remaining: Int) -> some View {
        if renderedChunkCount >= Self.maximumMountedChunks {
            Button {
                // Clamped: the remaining chunks past the cap can be fewer
                // than one batch, and chunkView indexes prepared.chunks
                // directly.
                renderedChunkCount = Self.nextWindowCount(
                    current: renderedChunkCount,
                    total: preparedChunkTotal
                )
            } label: {
                Label("Continue reading (\(remaining) sections left)", systemImage: "chevron.down")
                    .font(.footnote.weight(.semibold))
            }
            .tint(usesAccentSurface ? .white : .conduitAccent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Rendering…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

private struct LargeDocumentPreparingView: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Preparing large message…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

// MARK: - Flow chunks

/// Memoizes a flow chunk's attributed string so window growth and unrelated
/// body re-evaluations never re-run the Foundation parses. Rebuilds when the
/// Dynamic Type category changes (fonts bake into the string); the category
/// is an explicit parameter so the invalidation policy is unit-testable.
final class LargeFlowChunkBox {
    private var cachedText: NSAttributedString?
    private var cachedCategory: UIContentSizeCategory?

    @MainActor
    func attributedText(
        blocks: [MarkdownBlock],
        references: MarkdownReferenceContext,
        foregroundStyle: Color,
        usesAccentSurface: Bool,
        contentCategory: UIContentSizeCategory = UIApplication.shared.preferredContentSizeCategory
    ) -> NSAttributedString? {
        if let cachedText, cachedCategory == contentCategory { return cachedText }
        let text = MarkdownSelectionFormatter.attributedText(
            for: blocks,
            references: references,
            foregroundStyle: foregroundStyle,
            usesAccentSurface: usesAccentSurface,
            newestCharacterOpacities: []
        )
        cachedText = text
        cachedCategory = contentCategory
        return text
    }
}

/// One bounded flow chunk: a single selectable attributed string (the same
/// formatter the ordinary fast path uses) registered with the shared
/// coordinator under its chunk descriptor. Selection is native within the
/// chunk and coordinator-driven across chunks.
private struct LargeFlowChunkView: View {
    let blocks: [MarkdownBlock]
    let references: MarkdownReferenceContext
    let foregroundStyle: Color
    let usesAccentSurface: Bool
    let selectionCoordinator: MarkdownSelectionCoordinator?
    let selectionSegment: MarkdownSelectionSegmentDescriptor?

    /// Per-view memo box: identity comes from the enclosing ForEach index
    /// (keyed by source identity), so it survives window growth and dies
    /// with the chunk when the source changes.
    @State private var box = LargeFlowChunkBox()

    var body: some View {
        if let attributed = box.attributedText(
            blocks: blocks,
            references: references,
            foregroundStyle: foregroundStyle,
            usesAccentSurface: usesAccentSurface
        ) {
            SelectableTextView(
                attributedText: attributed,
                font: .preferredFont(forTextStyle: .body),
                textColor: usesAccentSurface ? .white : UIColor(foregroundStyle),
                lineSpacing: 4,
                linkColor: usesAccentSurface ? .white : .link,
                selectionCoordinator: selectionCoordinator,
                selectionSegment: selectionSegment
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Unreachable for planner-produced flow chunks (they contain
            // only selectable flow blocks); kept total for safety.
            EmptyView()
        }
    }
}

// MARK: - Large code blocks

/// Code at or above `codeBlockThresholdBytes` (highlighting measured 67 ms
/// at 50 KB and 1.5 s at 1 MB): a bounded line preview first; expanded, the
/// source renders in line slices whose highlighting happens off the
/// MainActor (tokenization is pure Foundation) and swaps in per slice. Copy
/// always uses the complete source.
struct LargeCodeBlockView: View {
    let source: String
    let language: String
    let usesAccentSurface: Bool

    @State private var expanded = false
    @State private var copied = false
    @State private var slices: [String]?
    /// (hasMoreLines, lineCount) computed once off-main; whole-block scans
    /// must not run per body evaluation (the Copy state toggle re-evaluates).
    @State private var lineStats: (hasMore: Bool, count: Int)?

    private var normalizedLanguage: String { MarkdownLanguage.normalized(language) }

    private static let previewLineCount = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if let slices {
                        ForEach(0..<slices.count, id: \.self) { index in
                            LargeCodeSliceView(
                                source: slices[index],
                                language: normalizedLanguage,
                                usesAccentSurface: usesAccentSurface
                            )
                        }
                    } else {
                        LargeCodeSliceView(
                            source: Self.previewSource(of: source),
                            language: normalizedLanguage,
                            usesAccentSurface: usesAccentSurface,
                            maximumNumberOfLines: Self.previewLineCount
                        )
                        if lineStats?.hasMore == true {
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) { expanded = true }
                            } label: {
                                Label("Show all \(lineStats?.count ?? 0) lines", systemImage: "chevron.down")
                                    .font(.caption.weight(.semibold))
                            }
                            .tint(usesAccentSurface ? .white : .conduitAccent)
                            .padding(.top, 8)
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(
            usesAccentSurface ? Color.black.opacity(0.24) : Color.primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    usesAccentSurface ? Color.white.opacity(0.28) : Color.secondary.opacity(0.20),
                    lineWidth: 1
                )
        }
        .task(id: "stats-\(source.utf8.count)") {
            // One-time whole-block scans (line counting), off the MainActor.
            guard lineStats == nil else { return }
            let currentSource = source
            let previewBudget = Self.previewLineCount
            let stats = await Task.detached(priority: .userInitiated) { () -> (Bool, Int) in
                var newlines = 0
                var index = currentSource.startIndex
                while index < currentSource.endIndex {
                    if currentSource[index] == "\n" { newlines += 1 }
                    index = currentSource.index(after: index)
                }
                // The preview shows at most `previewLineCount` lines.
                return (newlines >= previewBudget, newlines + 1)
            }.value
            guard !Task.isCancelled else { return }
            lineStats = stats
        }
        .task(id: expanded ? "full-\(source.utf8.count)" : "preview") {
            guard expanded, slices == nil else { return }
            // Line splitting is pure; a 1 MB block measured tens of ms, so
            // keep it off the MainActor too.
            let currentSource = source
            let lineCount = MarkdownLargeDocumentPolicy.codeSliceLineCount
            let result = await Task.detached(priority: .userInitiated) {
                currentSource.split(separator: "\n", omittingEmptySubsequences: false)
                    .chunks(lineCount)
                    .map { $0.joined(separator: "\n") }
            }.value
            guard !Task.isCancelled, expanded else { return }
            slices = result
        }
    }

    private var header: some View {
        HStack {
            Text(normalizedLanguage == "plain" ? "Code" : normalizedLanguage)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(usesAccentSurface ? Color.white.opacity(0.86) : .secondary)
            Spacer()
            Button {
                UIPasteboard.general.string = source
                Haptics.light()
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    guard !Task.isCancelled else { return }
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption2.weight(.semibold))
            }
            .tint(usesAccentSurface ? .white : .conduitAccent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(usesAccentSurface ? Color.black.opacity(0.28) : Color.primary.opacity(0.055))
    }

    /// First N lines of the source: a bounded scan, never a full split.
    static func previewSource(of source: String) -> String {
        var lineCount = 0
        var index = source.startIndex
        while index < source.endIndex {
            if source[index] == "\n" {
                lineCount += 1
                if lineCount >= previewLineCount {
                    return String(source[..<index])
                }
            }
            index = source.index(after: index)
        }
        return source
    }

}

private extension Array where Element == Substring {
    func chunks(_ size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return [] }
        var result: [[Element]] = []
        var start = startIndex
        while start < endIndex {
            let end = index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(Array(self[start..<end]))
            start = end
        }
        return result
    }
}

/// One bounded slice of a large code block: plain monospaced text
/// immediately, tokenized highlighting swapped in when the off-main pass
/// completes. Each slice is independently selectable.
private struct LargeCodeSliceView: View {
    let source: String
    let language: String
    let usesAccentSurface: Bool
    var maximumNumberOfLines: Int = 0

    @State private var highlighted: NSAttributedString?

    private var font: UIFont {
        .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
    }

    private var sliceIdentity: String {
        "\(source.hashValue)-\(UIApplication.shared.preferredContentSizeCategory.rawValue)"
    }

    var body: some View {
        Group {
            if let highlighted {
                SelectableTextView(
                    attributedText: highlighted,
                    font: font,
                    textColor: .label,
                    lineSpacing: 3,
                    wrapsLines: false
                )
            } else {
                SelectableTextView(
                    text: source,
                    font: font,
                    textColor: usesAccentSurface ? UIColor.white.withAlphaComponent(0.96) : .label,
                    lineSpacing: 3,
                    maximumNumberOfLines: maximumNumberOfLines,
                    wrapsLines: false
                )
            }
        }
        .task(id: sliceIdentity) {
            // Accent-surface (user-bubble) code never highlights, matching
            // the ordinary ChatCodeBlock behavior.
            guard !usesAccentSurface, !source.isEmpty else { return }
            let currentSource = source
            let currentLanguage = language
            let currentFont = font
            // Snapshot the identity the pass started under; comparing
            // against the live property is what actually drops stale
            // results when the view was re-created mid-pass.
            let passIdentity = sliceIdentity
            let highlightedResult = await Task.detached(priority: .userInitiated) {
                SyntaxHighlighter.highlight(currentSource, language: currentLanguage)
            }.value
            guard !Task.isCancelled, sliceIdentity == passIdentity else { return }
            self.highlighted = SelectableTextView.bridge(
                highlightedResult,
                defaultFont: currentFont,
                defaultColor: .label,
                linkColor: .link
            )
        }
    }
}
