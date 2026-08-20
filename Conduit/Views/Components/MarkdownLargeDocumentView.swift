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
    /// The message-wide context (used by rich-block subviews that read the
    /// environment default); per-chunk subsets live in `referencesByChunk`.
    let references: MarkdownReferenceContext
    /// Bounded per-chunk reference-definition subsets, so an 8 KB chunk
    /// never drags an arbitrarily large global definition block into its
    /// Foundation parse (see MarkdownReferenceResolver).
    let referencesByChunk: [MarkdownReferenceContext]
    /// Selection descriptors in document order — one synthetic descriptor
    /// per flow chunk, the ordinary per-block descriptors (original `block-N`
    /// ids included) for rich blocks — so cross-chunk selection works
    /// through the shared coordinator exactly like cross-block selection.
    let segmentDescriptors: [MarkdownSelectionSegmentDescriptor]
    /// Selection descriptors for each chunk (flow chunks carry their single
    /// synthetic descriptor; rich chunks carry their block's descriptors).
    let descriptorsByChunk: [[MarkdownSelectionSegmentDescriptor]]
    let sourceIdentity: String

    /// String work only — no UIKit — so it runs off the MainActor as a
    /// cooperative child of the caller's task (cancellation stops the pass
    /// between stages instead of wasting a megabyte parse after a switch).
    static func prepare(_ source: String) async -> LargeMarkdownPreparedDocument? {
        let document = MarkdownParser.parseDocument(source)
        guard !Task.isCancelled else { return nil }
        let chunks = MarkdownLargeChunkPlanner.chunks(for: document.blocks)
        guard !Task.isCancelled else { return nil }

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
        guard !Task.isCancelled else { return nil }

        // Per-chunk reference subsets from the chunk's own text.
        let definitions = MarkdownReferenceResolver.definitions(from: document.references)
        var referencesByChunk: [MarkdownReferenceContext] = []
        referencesByChunk.reserveCapacity(chunks.count)
        for chunk in chunks {
            referencesByChunk.append(
                MarkdownReferenceResolver.subset(for: chunk.flattenedText, definitions: definitions)
            )
        }

        return LargeMarkdownPreparedDocument(
            chunks: chunks,
            references: document.references,
            referencesByChunk: referencesByChunk,
            segmentDescriptors: all,
            descriptorsByChunk: descriptorsByChunk,
            sourceIdentity: Self.identity(of: source)
        )
    }

    static func identity(of source: String) -> String {
        "\(source.utf8.count)-\(source.hashValue)"
    }
}

/// Text projection of a chunk used for reference-label scanning — every
/// fragment of the chunk that Foundation will parse with the definitions
/// appended.
extension MarkdownLargeChunk {
    var flattenedText: String {
        switch self {
        case .flow(let blocks):
            return blocks.map(\.flattenedText).joined(separator: "\n")
        case .block(let block, _):
            return block.flattenedText
        }
    }
}

extension MarkdownBlock {
    /// All text fragments of the block that inline parsing will see.
    var flattenedText: String {
        switch self {
        case .heading(_, let text), .paragraph(let text): return text
        case .quote(let lines): return lines.map(\.text).joined(separator: "\n")
        case .unorderedList(let items), .orderedList(let items): return items.joined(separator: "\n")
        case .table(let headers, _, let rows):
            return ([headers] + rows).map { $0.joined(separator: " ") }.joined(separator: "\n")
        case .code(_, let source): return source
        case .callout(_, let text): return text
        case .columns(let columns): return columns.joined(separator: "\n")
        case .math(let source): return source
        case .image(let url, let alt): return "\(alt) \(url)"
        case .divider: return ""
        }
    }
}

// MARK: - Expanded document

/// Expanded body: prepare off-main, then render chunks progressively. The
/// initial batch mounts immediately; every further batch requires an
/// explicit Continue action — a plain VStack fires onAppear on insertion
/// rather than on visibility, so any automatic growth would cascade through
/// hundreds of chunks without the user ever scrolling.
struct LargeMarkdownExpandedView: View {
    let source: String
    let foregroundStyle: Color
    let usesAccentSurface: Bool
    let gatewayMediaDataURL: ((String) async -> String?)?

    @StateObject private var selectionCoordinator = MarkdownSelectionCoordinator()
    @State private var prepared: LargeMarkdownPreparedDocument?
    /// How many chunks are materialized in the view hierarchy.
    @State private var renderedChunkCount = LargeMarkdownExpandedView.initialChunkBatch

    /// First synchronous batch: enough to fill a screen at typical chunk
    /// heights while keeping per-chunk work in single-digit milliseconds.
    static let initialChunkBatch = 12
    /// Chunks added per explicit Continue action.
    static let continueChunkBatch = 25

    private var sourceIdentity: String { LargeMarkdownPreparedDocument.identity(of: source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let prepared {
                ForEach(0..<renderedChunkCount, id: \.self) { index in
                    chunkView(prepared, chunk: prepared.chunks[index], index: index)
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
            // Nonisolated async → runs on the global executor (a structured
            // child of this task, so cancellation stops the parse instead of
            // merely discarding its result).
            guard let plan = await LargeMarkdownPreparedDocument.prepare(source) else { return }
            guard !Task.isCancelled, plan.sourceIdentity == sourceIdentity else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                prepared = plan
                // Clamped: a large document can legitimately produce fewer
                // chunks than one batch, and chunkView indexes
                // prepared.chunks directly.
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
        Group {
            switch chunk {
            case .flow(let blocks):
                LargeFlowChunkView(
                    blocks: blocks,
                    references: prepared.referencesByChunk[index],
                    foregroundStyle: foregroundStyle,
                    usesAccentSurface: usesAccentSurface,
                    selectionCoordinator: selectionCoordinator,
                    selectionSegment: prepared.descriptorsByChunk[index].first
                )
            case .block(let block, let originalIndex):
                largeBlockView(
                    block,
                    originalIndex: originalIndex,
                    index: index,
                    prepared: prepared
                )
            }
        }
        .id("\(prepared.sourceIdentity)-\(index)")
    }

    /// Rich-block routing: ordinary blocks reuse the ordinary renderer;
    /// oversized ones get bounded specialized presentations.
    @ViewBuilder
    private func largeBlockView(
        _ block: MarkdownBlock,
        originalIndex: Int,
        index: Int,
        prepared: LargeMarkdownPreparedDocument
    ) -> some View {
        switch block {
        case .table(let headers, let alignments, let rows)
            where block.estimatedSourceBytes >= MarkdownLargeDocumentPolicy.largeTableBytes:
            LargeMarkdownTable(
                headers: headers,
                alignments: alignments,
                rows: rows,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                selectionCoordinator: selectionCoordinator,
                blockIndex: originalIndex,
                selectionSegments: prepared.descriptorsByChunk[index]
            )
        case .callout(let kind, let text)
            where text.utf8.count > MarkdownLargeDocumentPolicy.largeTextBlockBytes:
            LargeMarkdownCallout(
                kind: kind,
                text: text,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                selectionCoordinator: selectionCoordinator,
                selectionSegment: prepared.descriptorsByChunk[index].first
            )
        case .columns(let columns)
            where block.estimatedSourceBytes > MarkdownLargeDocumentPolicy.largeTextBlockBytes:
            LargeMarkdownColumns(
                columns: columns,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                selectionCoordinator: selectionCoordinator,
                selectionSegments: prepared.descriptorsByChunk[index]
            )
        case .math(let source) where source.utf8.count > MarkdownLargeDocumentPolicy.mathGuardBytes:
            GuardedSourceCard(
                title: "LaTeX",
                icon: "function",
                source: source,
                guardBytes: MarkdownLargeDocumentPolicy.mathGuardBytes
            )
        case .code(let language, let code)
            where MarkdownLanguage.normalized(language) == "mermaid"
                && code.utf8.count > MarkdownLargeDocumentPolicy.mermaidGuardBytes:
            GuardedSourceCard(
                title: "Mermaid",
                icon: "point.3.connected.trianglepath.dotted",
                source: code,
                guardBytes: MarkdownLargeDocumentPolicy.mermaidGuardBytes
            )
        case .code(let language, let code)
            where MarkdownLanguage.normalized(language) != "mermaid"
                && MarkdownLargeDocumentPolicy.isLargeCodeBlock(code):
            LargeCodeBlockView(
                source: code,
                language: language,
                usesAccentSurface: usesAccentSurface
            )
        default:
            // Ordinary rich blocks reuse the ordinary renderer with their
            // chunk-local reference subset injected.
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
            .environment(\.markdownReferences, prepared.referencesByChunk[index])
        }
    }

    /// Total chunk count read through @State: dynamic, so a button action
    /// firing twice before SwiftUI rebuilds still sees the live value.
    private var preparedChunkTotal: Int {
        prepared?.chunks.count ?? 0
    }

    @ViewBuilder
    private func progressFooter(remaining: Int) -> some View {
        Button {
            // Clamped to the real total: chunkView indexes prepared.chunks
            // directly, and the remaining chunks can be fewer than a batch.
            renderedChunkCount = Self.nextWindowCount(
                current: renderedChunkCount,
                total: preparedChunkTotal
            )
        } label: {
            Label(
                "Continue reading (\(remaining) sections left)",
                systemImage: "chevron.down"
            )
            .font(.footnote.weight(.semibold))
        }
        .tint(usesAccentSurface ? .white : .conduitAccent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    /// Next mounted-chunk count: one batch more, clamped to the document's
    /// chunk count.
    static func nextWindowCount(current: Int, total: Int) -> Int {
        min(current + continueChunkBatch, total)
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

/// Memoizes a flow chunk's attributed string so unrelated body
/// re-evaluations never re-run the Foundation parses. The memo identity is
/// explicit: Dynamic Type category (fonts bake into the string) and the
/// accent-surface flag (colors bake in). The chunk's blocks/references are
/// fixed per prepared plan — a changed source means a new identity and new
/// chunk views, so those inputs cannot change for a surviving box.
final class LargeFlowChunkBox {
    private var cachedText: NSAttributedString?
    private var cachedCategory: UIContentSizeCategory?
    private var cachedUsesAccentSurface: Bool?

    @MainActor
    func attributedText(
        blocks: [MarkdownBlock],
        references: MarkdownReferenceContext,
        foregroundStyle: Color,
        usesAccentSurface: Bool,
        contentCategory: UIContentSizeCategory = UIApplication.shared.preferredContentSizeCategory
    ) -> NSAttributedString? {
        if let cachedText,
           cachedCategory == contentCategory,
           cachedUsesAccentSurface == usesAccentSurface {
            return cachedText
        }
        let text = MarkdownSelectionFormatter.attributedText(
            for: blocks,
            references: references,
            foregroundStyle: foregroundStyle,
            usesAccentSurface: usesAccentSurface,
            newestCharacterOpacities: []
        )
        cachedText = text
        cachedCategory = contentCategory
        cachedUsesAccentSurface = usesAccentSurface
        return text
    }
}

/// One bounded flow chunk: a single selectable attributed string (the same
/// formatter the ordinary fast path uses) registered with the shared
/// coordinator under its chunk descriptor. Selection is native within the
/// chunk and coordinator-driven across chunks. The Dynamic Type category
/// arrives from the SwiftUI environment so text-size changes rebuild the
/// memoized string.
struct LargeFlowChunkView: View {
    let blocks: [MarkdownBlock]
    let references: MarkdownReferenceContext
    let foregroundStyle: Color
    let usesAccentSurface: Bool
    let selectionCoordinator: MarkdownSelectionCoordinator?
    let selectionSegment: MarkdownSelectionSegmentDescriptor?

    @Environment(\.sizeCategory) private var sizeCategory

    /// Per-view memo box: identity comes from the enclosing ForEach index
    /// (keyed by source identity), so it survives re-evaluations and dies
    /// with the chunk when the source changes.
    @State private var box = LargeFlowChunkBox()

    var body: some View {
        if let attributed = box.attributedText(
            blocks: blocks,
            references: references,
            foregroundStyle: foregroundStyle,
            usesAccentSurface: usesAccentSurface,
            contentCategory: UIContentSizeCategory(sizeCategory)
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

// MARK: - Large textual rich blocks

/// A callout whose body exceeds the text-block budget, reprojected into
/// bounded inner pieces (each ≤ the chunk target) rendered inside the same
/// callout chrome. Every piece is selectable and Copy Response still uses
/// the complete message.
private struct LargeMarkdownCallout: View {
    let kind: String
    let text: String
    let foregroundStyle: Color
    let usesAccentSurface: Bool
    let selectionCoordinator: MarkdownSelectionCoordinator?
    let selectionSegment: MarkdownSelectionSegmentDescriptor?

    private var detail: (title: String, icon: String, color: Color) {
        switch kind.lowercased() {
        case "tip", "hint": ("Tip", "lightbulb.fill", .green)
        case "warning", "caution": ("Warning", "exclamationmark.triangle.fill", .orange)
        case "danger", "error": ("Important", "exclamationmark.octagon.fill", .red)
        case "important": ("Important", "exclamationmark.circle.fill", .purple)
        default: ("Note", "info.circle.fill", .blue)
        }
    }

    var body: some View {
        // The pieces are flow text below the document threshold; rendering
        // each through the ordinary MarkdownText path reuses its cache and
        // selection machinery instead of a second inline implementation.
        let pieces = MarkdownLargeChunkPlanner.splitText(text) { .paragraph($0) }
        VStack(alignment: .leading, spacing: 6) {
            Label(detail.title, systemImage: detail.icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(detail.color)
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                if case .flow(let blocks) = piece {
                    LargeFlowChunkView(
                        blocks: blocks,
                        references: .empty,
                        foregroundStyle: foregroundStyle,
                        usesAccentSurface: usesAccentSurface,
                        selectionCoordinator: nil,
                        selectionSegment: nil
                    )
                }
            }
        }
        .padding(12)
        .background(detail.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(detail.color.opacity(0.28), lineWidth: 1)
        }
    }
}

/// Columns whose combined size exceeds the text-block budget, reprojected
/// per column into bounded pieces. The HStack chrome is preserved; each
/// piece renders through the ordinary small path.
private struct LargeMarkdownColumns: View {
    let columns: [String]
    let foregroundStyle: Color
    let usesAccentSurface: Bool
    let selectionCoordinator: MarkdownSelectionCoordinator?
    let selectionSegments: [MarkdownSelectionSegmentDescriptor]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                let pieces = MarkdownLargeChunkPlanner.splitText(column) { .paragraph($0) }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                        if case .flow(let blocks) = piece {
                            LargeFlowChunkView(
                                blocks: blocks,
                                references: .empty,
                                foregroundStyle: foregroundStyle,
                                usesAccentSurface: usesAccentSurface,
                                selectionCoordinator: selectionCoordinator,
                                selectionSegment: nil
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                if index < columns.count - 1 {
                    Divider().overlay(usesAccentSurface ? Color.white.opacity(0.24) : Color.secondary.opacity(0.20))
                }
            }
        }
        .background(
            usesAccentSurface ? Color.black.opacity(0.13) : Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(usesAccentSurface ? Color.white.opacity(0.26) : Color.secondary.opacity(0.20), lineWidth: 1)
        }
    }
}

// MARK: - Large code blocks

/// Code at or above `codeBlockThresholdBytes` (highlighting measured 67 ms
/// at 50 KB and 1.5 s at 1 MB): a bounded preview first; expanded, the
/// source renders as slices bounded by BOTH a line ceiling and a UTF-8 byte
/// ceiling (a 1 MB single-line blob is as pathological as 25 K normal
/// lines), with highlighting computed off the MainActor and swapped in per
/// slice. Copy always uses the complete source.
struct LargeCodeBlockView: View {
    let source: String
    let language: String
    let usesAccentSurface: Bool

    @State private var expanded = false
    @State private var copied = false
    @State private var slices: [String]?
    /// (hasMoreLines, lineCount) computed once off-main; whole-block scans
    /// must not run per body evaluation.
    @State private var lineStats: (hasMore: Bool, count: Int)?

    private var normalizedLanguage: String { MarkdownLanguage.normalized(language) }

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
                        // The preview renders ONE bounded slice — up to
                        // `codePreviewLineCount` lines AND `codePreviewBytes`
                        // bytes; a 1 MB single-line blob previews as its
                        // first 16 KB piece.
                        ForEach(Array(MarkdownCodeSlicer.slice(
                            source,
                            maxLines: MarkdownLargeDocumentPolicy.codePreviewLineCount,
                            maxBytes: MarkdownLargeDocumentPolicy.codePreviewBytes
                        ).prefix(1).enumerated()), id: \.offset) { _, piece in
                            LargeCodeSliceView(
                                source: piece,
                                language: normalizedLanguage,
                                usesAccentSurface: usesAccentSurface
                            )
                        }
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
            // One-time whole-block scans, off the MainActor and cancellation
            // cooperative with this view's lifecycle.
            guard lineStats == nil else { return }
            let currentSource = source
            let stats = await MarkdownCodeSlicer.lineStats(
                source: currentSource,
                previewLineBudget: MarkdownLargeDocumentPolicy.codePreviewLineCount,
                previewByteBudget: MarkdownLargeDocumentPolicy.codePreviewBytes
            )
            guard !Task.isCancelled else { return }
            lineStats = stats
        }
        .task(id: expanded ? "full-\(source.utf8.count)" : "preview") {
            guard expanded, slices == nil else { return }
            let currentSource = source
            let maxLines = MarkdownLargeDocumentPolicy.codeSliceLineCount
            let maxBytes = MarkdownLargeDocumentPolicy.codeSliceBytes
            let result = await MarkdownCodeSlicer.sliceAsync(
                currentSource,
                maxLines: maxLines,
                maxBytes: maxBytes
            )
            guard !Task.isCancelled, expanded, let result else { return }
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
    @Environment(\.sizeCategory) private var sizeCategory

    private var font: UIFont {
        .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
    }

    private var sliceIdentity: String {
        "\(source.hashValue)-\(sizeCategory)"
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
            let highlightedResult = await SyntaxHighlighter.highlightAsync(
                currentSource,
                language: currentLanguage
            )
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

// MARK: - Off-main helpers

extension MarkdownCodeSlicer {
    /// Cancellation-cooperative slicing for the expanded presentation: runs
    /// off the MainActor as a structured child of the caller and returns
    /// nil when cancelled mid-walk.
    static func sliceAsync(_ source: String, maxLines: Int, maxBytes: Int) async -> [String]? {
        await Task.yield()
        guard !Task.isCancelled else { return nil }
        // The synchronous walk over a megabyte is tens of milliseconds —
        // bounded — so a start-check plus the yield is proportionate; the
        // result is discarded anyway if the caller was cancelled.
        return slice(source, maxLines: maxLines, maxBytes: maxBytes)
    }

    /// One-time line statistics for the preview affordance. `hasMore` is
    /// true when either ceiling (lines or bytes) leaves content unpreviewed.
    static func lineStats(source: String, previewLineBudget: Int, previewByteBudget: Int) async -> (hasMore: Bool, count: Int) {
        await Task.yield()
        var newlines = 0
        var index = source.startIndex
        while index < source.endIndex {
            if source[index] == "\n" { newlines += 1 }
            index = source.index(after: index)
        }
        let hasMore = newlines >= previewLineBudget || source.utf8.count > previewByteBudget
        return (hasMore, newlines + 1)
    }
}

extension SyntaxHighlighter {
    /// Off-main, cancellation-checked entry for large-slice highlighting.
    static func highlightAsync(_ source: String, language: String) async -> AttributedString {
        await Task.yield()
        guard !Task.isCancelled else { return AttributedString(source) }
        return highlight(source, language: language)
    }
}
