//
//  MarkdownText.swift
//  Conduit
//
//  A compact, block-aware renderer for agent output.  System Markdown handles
//  inline emphasis well, while this layer owns the parts chat responses need:
//  code, diagrams, equations, tables, task lists, remote images, and callouts.
//

import SwiftUI
import UIKit
import WebKit

struct MarkdownText: View {
    let source: String
    var foregroundStyle: Color = .primary
    /// User messages sit on the app accent, where standard link, list, and
    /// code colors can blend into the bubble. Keep those rich blocks legible
    /// without changing the assistant-message presentation.
    var usesAccentSurface = false
    /// Resolves a gateway-local `MEDIA:` path through Hermes. This is supplied
    /// only for agent output, so user-authored paths stay ordinary text.
    var gatewayMediaDataURL: ((String) async -> String?)? = nil
    /// Per-character opacity values for the newest rendered block. Values map
    /// to its trailing glyphs, allowing a streaming tail to fade independently
    /// while already-read text remains fully stable.
    var newestCharacterOpacities: [Double] = []
    @StateObject private var selectionCoordinator = MarkdownSelectionCoordinator()

    /// True only for the actively streaming reply, whose `source` changes
    /// every frame. Settled messages (the default) populate the render cache;
    /// the streaming instance still parses each frame but skips inserting a
    /// snapshot that would be dead the moment the next delta arrives.
    var isStreaming: Bool = false

    var body: some View {
        // Path fork is centralized here: ordinary messages keep the exact
        // fast cached path below; pathological ones (see
        // MarkdownLargeDocumentPolicy) get the bounded presentation so no
        // stage of parse/format/layout scales with the whole source.
        if MarkdownLargeDocumentPolicy.isLargeDocument(source) {
            LargeMarkdownDocumentView(
                source: source,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                gatewayMediaDataURL: gatewayMediaDataURL
            )
        } else {
            normalBody
        }
    }

    @ViewBuilder
    private var normalBody: some View {
        let rendering = MarkdownRenderCache.rendering(
            source: source,
            recognizesGatewayMedia: gatewayMediaDataURL != nil,
            foregroundStyle: foregroundStyle,
            usesAccentSurface: usesAccentSurface,
            isStreaming: isStreaming
        )
        let selectionSegments = rendering.selectableText == nil
            ? MarkdownSelectionSegmentPlan.descriptors(for: rendering.blocks)
            : []

        Group {
            if let baseText = rendering.selectableText {
                SelectableTextView(
                    attributedText: MarkdownSelectionFormatter.applyingTrailingCharacterOpacities(
                        newestCharacterOpacities,
                        to: baseText,
                        baseColor: usesAccentSurface ? .white : UIColor(foregroundStyle)
                    ),
                    font: .preferredFont(forTextStyle: .body),
                    textColor: usesAccentSurface ? .white : UIColor(foregroundStyle),
                    lineSpacing: 4,
                    linkColor: usesAccentSurface ? .white : .link
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(rendering.blocks.enumerated()), id: \.offset) { index, block in
                        MarkdownBlockView(
                            block: block,
                            blockIndex: index,
                            foregroundStyle: foregroundStyle,
                            usesAccentSurface: usesAccentSurface,
                            gatewayMediaDataURL: gatewayMediaDataURL,
                            selectionCoordinator: selectionCoordinator,
                            selectionSegments: selectionSegments,
                            newestCharacterOpacities: index == rendering.blocks.count - 1
                                ? newestCharacterOpacities
                                : []
                        )
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
        }
        // Reference definitions ride the environment so every InlineMarkdown
        // below — however deeply nested in tables, quotes, or callouts — sees
        // the same message-level context without threading it through each
        // container view. Scoped to this MarkdownText subtree only.
        .environment(\.markdownReferences, rendering.references)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownSelectionHost: ViewModifier {
    @ObservedObject var coordinator: MarkdownSelectionCoordinator

    func body(content: Content) -> some View {
        content
            // No SwiftUI gesture ever sits over this content: the last one
            // (PR #57) fought the chat ScrollView's vertical pan and deadened
            // touches on table/code responses. Cross-block selection is
            // driven from below instead — MarkdownSelectionObserverGestureRecognizer
            // (SelectableTextView.swift) rides each block's text view as a
            // never-recognizing observer and forwards touch points to the
            // coordinator during a native selection drag, while this
            // non-interactive overlay draws the cross-block highlights and
            // the interactive handle overlay supplies coordinator-owned
            // endpoint handles plus a copy pill (the native handles cannot
            // leave the owner's own text view) — the chrome lives at the
            // chat root via MarkdownSelectionChromeRoot, not here.
            .overlay {
                MarkdownSelectionHighlightOverlay(coordinator: coordinator)
                    .allowsHitTesting(false)
            }
            .onDisappear {
                coordinator.clearSelection()
            }
    }
}

private struct MarkdownSelectionHighlightOverlay: UIViewRepresentable {
    @ObservedObject var coordinator: MarkdownSelectionCoordinator

    func makeUIView(context: Context) -> MarkdownSelectionHighlightView {
        let view = MarkdownSelectionHighlightView(frame: .zero)
        view.coordinator = coordinator
        return view
    }

    func updateUIView(_ uiView: MarkdownSelectionHighlightView, context: Context) {
        uiView.coordinator = coordinator
        uiView.setNeedsDisplay()
    }

    /// Match the content exactly — see MarkdownSelectionHandleOverlay.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MarkdownSelectionHighlightView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.bounds.width, height: proposal.height ?? uiView.bounds.height)
    }
}

private final class MarkdownSelectionHighlightView: UIView {
    weak var coordinator: MarkdownSelectionCoordinator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let coordinator, let window else { return }

        UIColor.systemBlue.withAlphaComponent(0.24).setFill()
        for windowRect in coordinator.highlightRects(in: window) {
            let localRect = convert(windowRect, from: window)
            guard localRect.intersects(bounds) else { continue }
            UIBezierPath(
                roundedRect: localRect.intersection(bounds).insetBy(dx: -0.5, dy: -0.5),
                cornerRadius: 2
            ).fill()
        }
    }
}

/// One render's parsed blocks plus the prebuilt selectable string (nil when
/// the blocks need the full block-view path). A class so NSCache can hold it.
private final class MarkdownRendering {
    let blocks: [MarkdownBlock]
    /// The message's link reference definitions; block views need them to
    /// resolve reference-style links when re-parsing each fragment.
    let references: MarkdownReferenceContext
    let selectableText: NSAttributedString?

    init(blocks: [MarkdownBlock], references: MarkdownReferenceContext, selectableText: NSAttributedString?) {
        self.blocks = blocks
        self.references = references
        self.selectableText = selectableText
    }
}

/// Every visible MarkdownText body re-evaluates ~30x/s while a reply streams
/// (each delta publishes an AppState change), and each evaluation used to
/// re-parse the source and rebuild the attributed string from scratch —
/// O(visible transcript) main-thread work per frame. Memoize per source and
/// style so settled messages render from cache and only genuinely new content
/// pays for parsing. Streaming-tail fades stay per-frame but are applied to a
/// copy of the cached base rather than triggering a rebuild.
private enum MarkdownRenderCache {
    private static let cache: NSCache<NSString, MarkdownRendering> = {
        let cache = NSCache<NSString, MarkdownRendering>()
        cache.countLimit = 256
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    @MainActor
    static func rendering(
        source: String,
        recognizesGatewayMedia: Bool,
        foregroundStyle: Color,
        usesAccentSurface: Bool,
        isStreaming: Bool
    ) -> MarkdownRendering {
        // `foregroundStyle` is deliberately absent from the key: only two
        // values are ever passed (.primary / .white), each uniquely tied to
        // `usesAccentSurface` (false / true), so keying on that is stable —
        // whereas `String(describing:)` of a SwiftUI Color is not (its
        // description is undocumented and can drift for adaptive colors). The
        // assert fails loudly in debug if a third style is ever introduced;
        // promote it to an explicit key token then.
        assert(
            usesAccentSurface ? foregroundStyle == .white : foregroundStyle == .primary,
            "MarkdownRenderCache keys on usesAccentSurface, not foregroundStyle; a new style needs an explicit key token."
        )

        // Fonts resolve against the current Dynamic Type size, so a size change
        // must miss the cache rather than serve stale metrics. Reading
        // preferredContentSizeCategory touches UIApplication.shared, hence the
        // @MainActor isolation on this function.
        let key = [
            recognizesGatewayMedia ? "1" : "0",
            usesAccentSurface ? "1" : "0",
            UIApplication.shared.preferredContentSizeCategory.rawValue,
            source
        ].joined(separator: "|") as NSString

        if let cached = cache.object(forKey: key) { return cached }
        let document = MarkdownParser.parseDocument(source, recognizesGatewayMedia: recognizesGatewayMedia)
        let rendering = MarkdownRendering(
            blocks: document.blocks,
            references: document.references,
            selectableText: MarkdownSelectionFormatter.attributedText(
                for: document.blocks,
                references: document.references,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                newestCharacterOpacities: []
            )
        )
        // While streaming, `source` changes every frame, so a cached entry is
        // dead on insertion and would only evict reusable settled entries.
        // Parse anyway (unavoidable — the content is new), but skip the write.
        // The message is cached on its first settled render via the
        // non-streaming call sites (isStreaming == false).
        if !isStreaming {
            // Approximate byte cost: source bytes + attributed-string storage
            // (each char carries attribute runs), so a few large messages can't
            // crowd out many small ones within totalCostLimit.
            let cost = source.utf8.count + (rendering.selectableText?.length ?? 0) * 4
            cache.setObject(rendering, forKey: key, cost: cost)
        }
        return rendering
    }
}

/// The message-wide link reference definitions (`[id]: url`) collected while
/// parsing a chat message. Each block fragment is re-parsed together with
/// these definitions so Foundation's Markdown parser — not this app — resolves
/// reference-style links, labels, and titles.
struct MarkdownReferenceContext: Equatable {
    /// The original definition lines, newline-joined. Retained verbatim so
    /// Foundation interprets destination/title semantics (case-insensitive
    /// labels, collapsed/shortcut forms, escapes) instead of this app doing it.
    let definitionsMarkdown: String

    static let empty = MarkdownReferenceContext(definitionsMarkdown: "")

    var containsDefinitions: Bool { !definitionsMarkdown.isEmpty }

    /// Fragment + definitions parse as one document: the definition block is
    /// block-level syntax that produces nothing visible, so fragments without
    /// references render exactly as they would alone.
    func markdownForParsing(_ fragment: String) -> String {
        guard containsDefinitions else { return fragment }
        return fragment + "\n\n" + definitionsMarkdown
    }
}

/// A parsed chat message: its visible blocks plus the reference definitions
/// that were removed from the visible body before block parsing.
struct MarkdownParsedDocument {
    let blocks: [MarkdownBlock]
    let references: MarkdownReferenceContext
}

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case quote([MarkdownQuoteLine])
    case unorderedList([String])
    case orderedList([String])
    case table(headers: [String], alignments: [MarkdownTableAlignment], rows: [[String]])
    case image(url: String, alt: String)
    case math(String)
    case callout(kind: String, text: String)
    case columns([String])
    case code(language: String, source: String)
    case divider
}

struct MarkdownQuoteLine: Equatable {
    let depth: Int
    let text: String
}

enum MarkdownSelectionFormatter {
    static func attributedText(
        for blocks: [MarkdownBlock],
        references: MarkdownReferenceContext = .empty,
        foregroundStyle: Color,
        usesAccentSurface: Bool,
        newestCharacterOpacities: [Double]
    ) -> NSAttributedString? {
        guard !blocks.isEmpty, blocks.allSatisfy(\.isSelectableFlowBlock) else { return nil }

        let bodyFont = UIFont.preferredFont(forTextStyle: .body)
        let textColor = usesAccentSurface ? UIColor.white : UIColor(foregroundStyle)
        let linkColor = usesAccentSurface ? UIColor.white : UIColor.link
        let result = NSMutableAttributedString()

        for (index, block) in blocks.enumerated() {
            guard let segment = segment(
                for: block,
                references: references,
                bodyFont: bodyFont,
                textColor: textColor,
                linkColor: linkColor,
                usesAccentSurface: usesAccentSurface,
                foregroundStyle: foregroundStyle
            ) else {
                return nil
            }

            if index > 0 {
                result.append(NSAttributedString(
                    string: "\n\n",
                    attributes: [
                        .font: bodyFont,
                        .foregroundColor: textColor
                    ]
                ))
            }
            result.append(segment)
        }

        applyTrailingCharacterOpacities(newestCharacterOpacities, to: result, baseColor: textColor)
        return result
    }

    private static func segment(
        for block: MarkdownBlock,
        references: MarkdownReferenceContext,
        bodyFont: UIFont,
        textColor: UIColor,
        linkColor: UIColor,
        usesAccentSurface: Bool,
        foregroundStyle: Color
    ) -> NSAttributedString? {
        switch block {
        case .heading(let level, let text):
            return inline(
                text,
                references: references,
                font: headingFont(level),
                textColor: textColor,
                linkColor: linkColor
            )

        case .paragraph(let text):
            return inline(text, references: references, font: bodyFont, textColor: textColor, linkColor: linkColor)

        case .unorderedList(let items):
            return list(
                items,
                ordered: false,
                references: references,
                bodyFont: bodyFont,
                textColor: textColor,
                linkColor: linkColor,
                markerColor: usesAccentSurface ? .white : UIColor(Color.conduitAccent)
            )

        case .orderedList(let items):
            return list(
                items,
                ordered: true,
                references: references,
                bodyFont: bodyFont,
                textColor: textColor,
                linkColor: linkColor,
                markerColor: usesAccentSurface ? .white : UIColor(Color.conduitAccent)
            )

        case .quote(let lines):
            let result = NSMutableAttributedString()
            let quoteColor = usesAccentSurface
                ? UIColor.white.withAlphaComponent(0.90)
                : UIColor(foregroundStyle).withAlphaComponent(0.90)
            let quoteFont = bodyFont.withTraits(.traitItalic)

            for (index, line) in lines.enumerated() {
                if index > 0 {
                    result.append(NSAttributedString(string: "\n"))
                }
                let marker = String(repeating: "│ ", count: max(line.depth, 1))
                result.append(NSAttributedString(
                    string: marker,
                    attributes: [
                        .font: bodyFont,
                        .foregroundColor: quoteColor
                    ]
                ))
                result.append(inline(line.text, references: references, font: quoteFont, textColor: quoteColor, linkColor: linkColor))
            }
            return result

        default:
            return nil
        }
    }

    private static func list(
        _ items: [String],
        ordered: Bool,
        references: MarkdownReferenceContext,
        bodyFont: UIFont,
        textColor: UIColor,
        linkColor: UIColor,
        markerColor: UIColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let markerFont = bodyFont.withTraits(.traitBold)

        for (index, item) in items.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }

            let task = MarkdownParser.taskItem(item)
            let marker: String
            if let task {
                marker = task.complete ? "☑ " : "☐ "
            } else {
                marker = ordered ? "\(index + 1). " : "• "
            }
            result.append(NSAttributedString(
                string: marker,
                attributes: [
                    .font: markerFont,
                    .foregroundColor: markerColor
                ]
            ))
            result.append(inline(
                task?.text ?? item,
                references: references,
                font: bodyFont,
                textColor: textColor,
                linkColor: linkColor
            ))
        }
        return result
    }

    private static func inline(
        _ source: String,
        references: MarkdownReferenceContext,
        font: UIFont,
        textColor: UIColor,
        linkColor: UIColor
    ) -> NSAttributedString {
        let attributed = (try? AttributedString(
            markdown: references.markdownForParsing(source),
            options: .init(interpretedSyntax: .full)
        )) ?? AttributedString(source)
        return SelectableTextView.bridge(attributed, defaultFont: font, defaultColor: textColor, linkColor: linkColor)
    }

    private static func headingFont(_ level: Int) -> UIFont {
        MarkdownHeading.font(for: level)
    }

    /// Applies the streaming-tail fade to a copy, leaving the shared cached
    /// base untouched for reuse on the next frame.
    static func applyingTrailingCharacterOpacities(
        _ opacities: [Double],
        to base: NSAttributedString,
        baseColor: UIColor
    ) -> NSAttributedString {
        guard !opacities.isEmpty, base.length > 0 else { return base }
        let copy = NSMutableAttributedString(attributedString: base)
        applyTrailingCharacterOpacities(opacities, to: copy, baseColor: baseColor)
        return copy
    }

    private static func applyTrailingCharacterOpacities(
        _ opacities: [Double],
        to text: NSMutableAttributedString,
        baseColor: UIColor
    ) {
        guard !opacities.isEmpty, text.length > 0 else { return }
        var location = text.length
        for opacity in opacities.reversed() {
            guard location > 0 else { break }
            location -= 1
            text.addAttribute(
                .foregroundColor,
                value: baseColor.withAlphaComponent(CGFloat(opacity)),
                range: NSRange(location: location, length: 1)
            )
        }
    }
}

extension MarkdownBlock {
    var isSelectableFlowBlock: Bool {
        switch self {
        case .heading, .paragraph, .quote, .unorderedList, .orderedList:
            true
        default:
            false
        }
    }
}

enum MarkdownTableAlignment {
    case leading, center, trailing

    /// Carried into the cell text's paragraph style so alignment governs
    /// every wrapped line, not just the position of a full-width wrapper.
    var nsText: NSTextAlignment {
        switch self {
        case .leading: .natural
        case .center: .center
        case .trailing: .right
        }
    }
}

/// Shared heading font logic used by both MarkdownSelectionFormatter
/// and MarkdownBlockView to prevent divergence.
enum MarkdownHeading {
    static func font(for level: Int) -> UIFont {
        switch level {
        case 1: UIFont.preferredFont(forTextStyle: .title2).withTraits(.traitBold)
        case 2: UIFont.preferredFont(forTextStyle: .title3).withTraits(.traitBold)
        case 3: UIFont.preferredFont(forTextStyle: .headline).withTraits(.traitBold)
        default: UIFont.preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
        }
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let blockIndex: Int
    let foregroundStyle: Color
    let usesAccentSurface: Bool
    let gatewayMediaDataURL: ((String) async -> String?)?
    let selectionCoordinator: MarkdownSelectionCoordinator?
    let selectionSegments: [MarkdownSelectionSegmentDescriptor]
    let newestCharacterOpacities: [Double]

    var body: some View {
        switch block {
        case .heading(let level, let text):
            InlineMarkdown(
                source: text,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                font: headingFont(level),
                selectionCoordinator: selectionCoordinator,
                selectionSegment: blockDescriptor,
                trailingCharacterOpacities: newestCharacterOpacities
            )
                .padding(.top, level <= 2 ? 6 : 2)

        case .paragraph(let text):
            InlineMarkdown(
                source: text,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                lineSpacing: 4,
                selectionCoordinator: selectionCoordinator,
                selectionSegment: blockDescriptor,
                trailingCharacterOpacities: newestCharacterOpacities
            )

        case .quote(let lines):
            MarkdownQuote(
                lines: lines,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                selectionCoordinator: selectionCoordinator,
                selectionSegments: blockSelectionSegments,
                trailingCharacterOpacities: newestCharacterOpacities
            )

        case .unorderedList(let items):
            MarkdownList(
                items: items,
                ordered: false,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                selectionCoordinator: selectionCoordinator,
                selectionSegments: blockSelectionSegments,
                trailingCharacterOpacities: newestCharacterOpacities
            )

        case .orderedList(let items):
            MarkdownList(
                items: items,
                ordered: true,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                selectionCoordinator: selectionCoordinator,
                selectionSegments: blockSelectionSegments,
                trailingCharacterOpacities: newestCharacterOpacities
            )

        case .table(let headers, let alignments, let rows):
            MarkdownTable(
                headers: headers,
                alignments: alignments,
                rows: rows,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                selectionCoordinator: selectionCoordinator,
                blockIndex: blockIndex,
                selectionSegments: selectionSegments
            )

        case .image(let url, let alt):
            RemoteMarkdownImage(url: url, alt: alt, gatewayMediaDataURL: gatewayMediaDataURL)

        case .math(let source):
            MathBlock(source: source)

        case .callout(let kind, let text):
            MarkdownCallout(
                kind: kind,
                text: text,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                selectionCoordinator: selectionCoordinator,
                selectionSegment: blockDescriptor,
                trailingCharacterOpacities: newestCharacterOpacities
            )

        case .columns(let columns):
            MarkdownColumns(
                columns: columns,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                selectionCoordinator: selectionCoordinator,
                selectionSegments: blockSelectionSegments,
                trailingCharacterOpacities: newestCharacterOpacities
            )

        case .code(let language, let source):
            if MarkdownLanguage.normalized(language) == "mermaid" {
                MermaidBlock(source: source)
            } else {
                ChatCodeBlock(
                    source: source,
                    language: language,
                    usesAccentSurface: usesAccentSurface,
                    selectionCoordinator: selectionCoordinator,
                    selectionSegment: selectionSegment(id: "block-\(blockIndex)-code")
                )
            }

        case .divider:
            Rectangle()
                .fill(Color.secondary.opacity(0.22))
                .frame(height: 1)
                .padding(.vertical, 5)
        }
    }

    private func headingFont(_ level: Int) -> UIFont {
        MarkdownHeading.font(for: level)
    }

    private var blockDescriptor: MarkdownSelectionSegmentDescriptor? {
        selectionSegment(id: "block-\(blockIndex)")
    }

    private var blockSelectionSegments: [MarkdownSelectionSegmentDescriptor] {
        let blockID = "block-\(blockIndex)"
        let blockPrefix = "\(blockID)-"
        return selectionSegments.filter { descriptor in
            descriptor.id == blockID || descriptor.id.hasPrefix(blockPrefix)
        }
    }

    private func selectionSegment(id: String) -> MarkdownSelectionSegmentDescriptor? {
        selectionSegments.first { $0.id == id }
    }
}

/// Message-scoped link reference definitions for the block-view hierarchy.
/// `MarkdownText` injects its parsed context; every `InlineMarkdown` in the
/// subtree reads it. The default keeps `InlineMarkdown` renderable in
/// isolation (no references), which matches pre-reference behavior.
struct MarkdownReferencesKey: EnvironmentKey {
    static let defaultValue = MarkdownReferenceContext.empty
}

extension EnvironmentValues {
    var markdownReferences: MarkdownReferenceContext {
        get { self[MarkdownReferencesKey.self] }
        set { self[MarkdownReferencesKey.self] = newValue }
    }
}

/// The single inline-attributed-string construction shared by
/// `InlineMarkdown` rendering and `MarkdownTableLayout` width measurement,
/// so a table column is always measured at exactly the content its cells
/// render — reference-style links resolve to their labels in both paths,
/// and any future inline-syntax change updates measurement with it.
enum InlineMarkdownContent {
    static func attributed(
        source: String,
        references: MarkdownReferenceContext,
        foregroundStyle: Color = .primary,
        trailingCharacterOpacities: [Double] = []
    ) -> AttributedString {
        // Re-append the message's definitions so Foundation resolves
        // reference-style links for this fragment too. The definition block
        // is invisible under `.full`; if parsing fails, fall back to the bare
        // fragment so definitions never surface as text.
        var attributed = (try? AttributedString(
            markdown: references.markdownForParsing(source),
            options: .init(interpretedSyntax: .full)
        )) ?? AttributedString(source)

        var endIndex = attributed.characters.endIndex
        for opacity in trailingCharacterOpacities.reversed() {
            guard endIndex != attributed.characters.startIndex else { break }
            let startIndex = attributed.characters.index(before: endIndex)
            attributed[startIndex..<endIndex].foregroundColor = foregroundStyle.opacity(opacity)
            endIndex = startIndex
        }
        return attributed
    }
}

private struct InlineMarkdown: View {
    let source: String
    let foregroundStyle: Color
    let usesAccentSurface: Bool
    var font: UIFont = .preferredFont(forTextStyle: .body)
    var lineSpacing: CGFloat = 0
    var maximumNumberOfLines: Int = 0
    var textAlignment: NSTextAlignment = .natural
    var selfSizingWidthRange: ClosedRange<CGFloat>? = nil
    var selectionCoordinator: MarkdownSelectionCoordinator?
    var selectionSegment: MarkdownSelectionSegmentDescriptor?
    var trailingCharacterOpacities: [Double] = []
    @Environment(\.markdownReferences) private var references

    private var attributed: AttributedString {
        InlineMarkdownContent.attributed(
            source: source,
            references: references,
            foregroundStyle: foregroundStyle,
            trailingCharacterOpacities: trailingCharacterOpacities
        )
    }

    var body: some View {
        SelectableTextView(
            attributedText: attributed,
            font: font,
            textColor: usesAccentSurface ? .white : UIColor(foregroundStyle),
            lineSpacing: lineSpacing,
            maximumNumberOfLines: maximumNumberOfLines,
            linkColor: usesAccentSurface ? .white : .link,
            textAlignment: textAlignment,
            selfSizingWidthRange: selfSizingWidthRange,
            selectionCoordinator: selectionCoordinator,
            selectionSegment: selectionSegment
        )
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownList: View {
    let items: [String]
    let ordered: Bool
    let foregroundStyle: Color
    let usesAccentSurface: Bool
    let selectionCoordinator: MarkdownSelectionCoordinator?
    let selectionSegments: [MarkdownSelectionSegmentDescriptor]
    var trailingCharacterOpacities: [Double] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let task = MarkdownParser.taskItem(item)
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    if let task {
                        Image(systemName: task.complete ? "checkmark.square.fill" : "square")
                            .foregroundStyle(task.complete
                                             ? (usesAccentSurface ? Color.white : Color.conduitAccent)
                                             : (usesAccentSurface ? Color.white.opacity(0.82) : Color.secondary))
                            .frame(width: 16, alignment: .trailing)
                    } else {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(usesAccentSurface ? Color.white.opacity(0.92) : Color.conduitAccent)
                            .frame(width: ordered ? 24 : 12, alignment: .trailing)
                    }
                    InlineMarkdown(
                        source: task?.text ?? item,
                        foregroundStyle: foregroundStyle,
                        usesAccentSurface: usesAccentSurface,
                        lineSpacing: 3,
                        selectionCoordinator: selectionCoordinator,
                        selectionSegment: selectionSegments.indices.contains(index) ? selectionSegments[index] : nil,
                        trailingCharacterOpacities: index == items.count - 1
                            ? trailingCharacterOpacities
                            : []
                    )
                }
            }
        }
    }
}

private struct MarkdownQuote: View {
    let lines: [MarkdownQuoteLine]
    let foregroundStyle: Color
    let usesAccentSurface: Bool
    let selectionCoordinator: MarkdownSelectionCoordinator?
    let selectionSegments: [MarkdownSelectionSegmentDescriptor]
    var trailingCharacterOpacities: [Double] = []

    private var callout: (kind: String, text: String)? {
        guard let first = lines.first, let marker = MarkdownParser.calloutMarker(first.text) else { return nil }
        let body = ([marker.remainder] + lines.dropFirst().map(\.text))
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return (marker.kind, body)
    }

    var body: some View {
        if let callout {
            MarkdownCallout(
                kind: callout.kind,
                text: callout.text,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                selectionCoordinator: selectionCoordinator,
                selectionSegment: selectionSegments.first,
                trailingCharacterOpacities: trailingCharacterOpacities
            )
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: 8) {
                        HStack(spacing: 3) {
                            ForEach(0..<max(line.depth, 1), id: \.self) { _ in
                                Capsule().fill(usesAccentSurface ? Color.white.opacity(0.78) : Color.conduitAccent.opacity(0.78)).frame(width: 3)
                            }
                        }
                        InlineMarkdown(
                            source: line.text,
                            foregroundStyle: foregroundStyle.opacity(0.90),
                            usesAccentSurface: usesAccentSurface,
                            font: UIFont.preferredFont(forTextStyle: .body).withTraits(.traitItalic),
                            lineSpacing: 3,
                            selectionCoordinator: selectionCoordinator,
                            selectionSegment: selectionSegments.indices.contains(index) ? selectionSegments[index] : nil,
                            trailingCharacterOpacities: index == lines.count - 1
                                ? trailingCharacterOpacities
                                : []
                        )
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                usesAccentSurface ? Color.black.opacity(0.13) : Color.conduitAccent.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
        }
    }
}

private struct MarkdownCallout: View {
    let kind: String
    let text: String
    let foregroundStyle: Color
    let usesAccentSurface: Bool
    let selectionCoordinator: MarkdownSelectionCoordinator?
    let selectionSegment: MarkdownSelectionSegmentDescriptor?
    var trailingCharacterOpacities: [Double] = []

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
        VStack(alignment: .leading, spacing: 6) {
            Label(detail.title, systemImage: detail.icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(detail.color)
            InlineMarkdown(
                source: text,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                lineSpacing: 3,
                selectionCoordinator: selectionCoordinator,
                selectionSegment: selectionSegment,
                trailingCharacterOpacities: trailingCharacterOpacities
            )
        }
        .padding(12)
        .background(detail.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(detail.color.opacity(0.28), lineWidth: 1)
        }
    }
}

private struct MarkdownColumns: View {
    let columns: [String]
    let foregroundStyle: Color
    let usesAccentSurface: Bool
    let selectionCoordinator: MarkdownSelectionCoordinator?
    let selectionSegments: [MarkdownSelectionSegmentDescriptor]
    var trailingCharacterOpacities: [Double] = []

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                InlineMarkdown(
                    source: column,
                    foregroundStyle: foregroundStyle,
                    usesAccentSurface: usesAccentSurface,
                    lineSpacing: 3,
                    selectionCoordinator: selectionCoordinator,
                    selectionSegment: selectionSegments.indices.contains(index) ? selectionSegments[index] : nil,
                    trailingCharacterOpacities: index == columns.count - 1
                        ? trailingCharacterOpacities
                        : []
                )
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

/// Table-wide column layout: one width per column shared by the header and
/// every row, so vertical dividers align across rows. Each column's width
/// is the largest ideal (unwrapped) text width among its cells — header
/// included — capped at `maxColumnContentWidth`. When the capped columns
/// fit the chat width the table fits too (narrow columns stay narrow, wide
/// ones keep their earned space); when they overflow, columns above the
/// shrink floor give up width proportionally to their excess and wrap, and
/// a table that still overflows at the floor keeps horizontal scrolling.
enum MarkdownTableLayout {
    /// Widest a column's text may be before it wraps.
    static let maxColumnContentWidth: CGFloat = 220
    /// Narrowest a column shrinks to when the table must compress; columns
    /// whose ideal is already below this keep their ideal width.
    static let shrinkFloorContentWidth: CGFloat = 64
    static let cellHorizontalPadding: CGFloat = 10
    static let dividerWidth: CGFloat = 1
    static let borderAllowance: CGFloat = 2

    private static let cache: NSCache<NSString, NSArray> = {
        let cache = NSCache<NSString, NSArray>()
        cache.countLimit = 64
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()

    @MainActor
    static func columnWidths(
        headers: [String],
        rows: [[String]],
        availableWidth: CGFloat,
        references: MarkdownReferenceContext = .empty
    ) -> [CGFloat] {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return [] }

        // Fonts resolve against the current Dynamic Type size, so the widths
        // key on the content category just like MarkdownRenderCache, on the
        // viewport width that feeds the fit-or-shrink decision, and on the
        // reference definitions (they change how cell source measures).
        let key = (
            [
                UIApplication.shared.preferredContentSizeCategory.rawValue,
                String(format: "%.1f", availableWidth),
                references.definitionsMarkdown
            ]
                + headers
                + rows.flatMap { $0.isEmpty ? ["<empty-row>"] : $0 }
        ).joined(separator: "\u{1F}") as NSString

        if let cached = cache.object(forKey: key) as? [CGFloat] { return cached }

        let headerFont = UIFont.preferredFont(forTextStyle: .caption1).withTraits(.traitBold)
        let bodyFont = UIFont.preferredFont(forTextStyle: .footnote)

        var ideals = [CGFloat](repeating: 0, count: columnCount)
        for (index, header) in headers.enumerated() {
            ideals[index] = max(ideals[index], idealWidth(of: header, font: headerFont, references: references))
        }
        for row in rows {
            for (index, cell) in row.enumerated() where index < columnCount {
                ideals[index] = max(ideals[index], idealWidth(of: cell, font: bodyFont, references: references))
            }
        }

        let widths = resolveColumnContentWidths(ideals: ideals, availableWidth: availableWidth)
        cache.setObject(widths as NSArray, forKey: key, cost: key.length)
        return widths
    }

    /// Pure distribution step so the policy is directly unit-testable.
    /// A non-positive available width means the viewport is not yet known
    /// (first layout pass): fall back to the cap-and-scroll layout, which is
    /// deterministic and re-resolves once the real width arrives.
    static func resolveColumnContentWidths(ideals: [CGFloat], availableWidth: CGFloat) -> [CGFloat] {
        guard !ideals.isEmpty else { return [] }
        let capped = ideals.map { min($0, maxColumnContentWidth) }
        guard availableWidth > 0 else { return halfPointRounded(capped) }

        // Cell padding, dividers, and the table border consume viewport width
        // exactly once, before any column sees it.
        let overhead = CGFloat(capped.count) * cellHorizontalPadding * 2
            + CGFloat(capped.count - 1) * dividerWidth
            + borderAllowance
        let available = max(0, availableWidth - overhead)

        let total = capped.reduce(0, +)
        if total <= available { return halfPointRounded(capped) }

        let shrinkable = capped.reduce(0) { $0 + max($1 - shrinkFloorContentWidth, 0) }
        let deficit = total - available
        if deficit >= shrinkable {
            // Everything compressible is at the floor; columns that were
            // already narrower keep their ideal. The table scrolls.
            return halfPointRounded(capped.map { $0 > shrinkFloorContentWidth ? shrinkFloorContentWidth : $0 })
        }
        // Shrink proportionally to the excess above the floor: wide columns
        // contribute more, narrow ones may not shrink at all.
        let factor = deficit / shrinkable
        return halfPointRounded(capped.map { $0 - max($0 - shrinkFloorContentWidth, 0) * factor })
    }

    private static func halfPointRounded(_ widths: [CGFloat]) -> [CGFloat] {
        widths.map { ($0 * 2).rounded() / 2 }
    }

    /// Measures the ideal (single-fragment) width of a cell from the exact
    /// attributed content InlineMarkdown renders (`InlineMarkdownContent`
    /// bridged with the cell font), so the shared column widths and the
    /// rendered wrapping agree — including message-level reference links,
    /// which measure as their resolved labels.
    private static func idealWidth(of source: String, font: UIFont, references: MarkdownReferenceContext) -> CGFloat {
        let bridged = NSMutableAttributedString(
            attributedString: SelectableTextView.bridge(
                InlineMarkdownContent.attributed(source: source, references: references),
                defaultFont: font,
                defaultColor: .label,
                linkColor: .link
            )
        )
        let fullRange = NSRange(location: 0, length: bridged.length)
        if fullRange.length > 0 {
            bridged.addAttribute(
                .paragraphStyle,
                value: NSMutableParagraphStyle(),
                range: fullRange
            )
        }
        let measured = bridged.boundingRect(
            with: CGSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return ceil(measured.width)
    }
}

private struct MarkdownTable: View {
    let headers: [String]
    let alignments: [MarkdownTableAlignment]
    let rows: [[String]]
    let foregroundStyle: Color
    let usesAccentSurface: Bool
    let selectionCoordinator: MarkdownSelectionCoordinator?
    let blockIndex: Int
    let selectionSegments: [MarkdownSelectionSegmentDescriptor]

    /// The chat's proposed width for this block, read by a zero-height
    /// probe above the scroll view. Zero means "unknown yet" (first pass);
    /// the layout then falls back to cap-and-scroll and re-resolves a frame
    /// later, once the width is known.
    @State private var availableWidth: CGFloat = 0
    @Environment(\.markdownReferences) private var references

    private var columnWidths: [CGFloat] {
        MarkdownTableLayout.columnWidths(
            headers: headers,
            rows: rows,
            availableWidth: availableWidth,
            references: references
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { availableWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in availableWidth = width }
            }
            .frame(height: 0)

            let widths = columnWidths
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    tableRow(headers, rowIndex: 0, isHeader: true, widths: widths)
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowOffset, row in
                        Divider().overlay(usesAccentSurface ? Color.white.opacity(0.22) : Color.secondary.opacity(0.18))
                        tableRow(row, rowIndex: rowOffset + 1, isHeader: false, widths: widths)
                    }
                }
                .background(
                    usesAccentSurface ? Color.black.opacity(0.13) : Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(usesAccentSurface ? Color.white.opacity(0.26) : Color.secondary.opacity(0.20), lineWidth: 1)
                }
            }
        }
    }

    private func tableRow(_ cells: [String], rowIndex: Int, isHeader: Bool, widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                let width = widths.indices.contains(index)
                    ? widths[index]
                    : MarkdownTableLayout.shrinkFloorContentWidth
                InlineMarkdown(
                    source: cell,
                    foregroundStyle: foregroundStyle,
                    usesAccentSurface: usesAccentSurface,
                    font: isHeader
                        ? UIFont.preferredFont(forTextStyle: .caption1).withTraits(.traitBold)
                        : UIFont.preferredFont(forTextStyle: .footnote),
                    textAlignment: alignment(at: index).nsText,
                    // The exact shared column width — a single-value range keeps
                    // the cell's measured/committed height deterministic from the
                    // first layout pass, and .frame(width:) below pins the
                    // displayed width so every row's dividers align.
                    selfSizingWidthRange: width...width,
                    selectionCoordinator: selectionCoordinator,
                    selectionSegment: selectionSegment(row: rowIndex, column: index)
                )
                    .frame(width: width)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                if index < cells.count - 1 {
                    Divider().overlay(usesAccentSurface ? Color.white.opacity(0.22) : Color.secondary.opacity(0.18))
                }
            }
        }
    }

    private func alignment(at index: Int) -> MarkdownTableAlignment {
        alignments.indices.contains(index) ? alignments[index] : .leading
    }

    private func selectionSegment(row: Int, column: Int) -> MarkdownSelectionSegmentDescriptor? {
        let id = "block-\(blockIndex)-table-r\(row)-c\(column)"
        return selectionSegments.first { $0.id == id }
    }
}

private struct RemoteMarkdownImage: View {
    let url: String
    let alt: String
    let gatewayMediaDataURL: ((String) async -> String?)?
    @State private var gatewayImage: UIImage?
    @State private var gatewayLoadFailed = false

    private var isGatewayMedia: Bool { url.hasPrefix("MEDIA:") }
    private var gatewayPath: String {
        String(url.dropFirst("MEDIA:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if isGatewayMedia {
                gatewayMediaContent
            } else {
                AsyncImage(url: URL(string: url), transaction: .init(animation: .easeInOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit().frame(maxHeight: 360).clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            case .failure:
                WebFallbackImage(url: url, alt: alt)
            default:
                HStack(spacing: 8) { ProgressView(); Text(alt.isEmpty ? "Loading image…" : alt).font(.footnote).foregroundStyle(.secondary) }
                    .padding(12)
            }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: url) {
            guard isGatewayMedia else { return }
            gatewayImage = nil
            gatewayLoadFailed = false
            guard let gatewayMediaDataURL, !gatewayPath.isEmpty,
                  let dataURL = await gatewayMediaDataURL(gatewayPath),
                  !Task.isCancelled,
                  let image = image(fromDataURL: dataURL) else {
                guard !Task.isCancelled else { return }
                gatewayLoadFailed = true
                return
            }
            gatewayImage = image
        }
    }

    @ViewBuilder
    private var gatewayMediaContent: some View {
        if let gatewayImage {
            Image(uiImage: gatewayImage)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        } else if gatewayLoadFailed {
            Label(alt.isEmpty ? "Image unavailable" : "\(alt) unavailable", systemImage: "photo.badge.exclamationmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        } else {
            loadingLabel
        }
    }

    private var loadingLabel: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(alt.isEmpty ? "Loading image..." : alt)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private func image(fromDataURL value: String) -> UIImage? {
        guard let data = DataURLLimits.decodeBase64DataURL(value, prefix: "data:image/") else { return nil }
        return UIImage(data: data)
    }
}

/// Resolves a model-authored image destination without treating a non-nil URL
/// as proof that it is a usable web destination. Strict parsing preserves
/// existing percent escapes; component-aware repair handles spaces and other
/// invalid characters without encoding URL delimiters or double-encoding `%XX`.
enum WebFallbackImageDestination {
    static func resolve(_ value: String) -> URL? {
        if let strictURL = URL(string: value, encodingInvalidCharacters: false),
           isValidWebDestination(strictURL) {
            return strictURL
        }

        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              let rawComponents = rawComponents(from: value),
              let encodedPath = encodedComponent(
                  rawComponents.path,
                  allowedCharacters: .urlPathAllowed
              ) else {
            return nil
        }

        components.scheme = scheme
        components.percentEncodedPath = encodedPath
        if let query = rawComponents.query {
            guard let encodedQuery = encodedComponent(
                query,
                allowedCharacters: .urlQueryAllowed
            ) else { return nil }
            components.percentEncodedQuery = encodedQuery
        } else {
            components.percentEncodedQuery = nil
        }
        if let fragment = rawComponents.fragment {
            guard let encodedFragment = encodedComponent(
                fragment,
                allowedCharacters: .urlFragmentAllowed
            ) else { return nil }
            components.percentEncodedFragment = encodedFragment
        } else {
            components.percentEncodedFragment = nil
        }

        return isValidWebDestination(components.url) ? components.url : nil
    }

    private struct RawComponents {
        let path: String
        let query: String?
        let fragment: String?
    }

    /// URLComponents exposes a decoded `path` when a URL has another invalid
    /// component. Reading that value would turn an existing `%2F` into `/`
    /// while repairing, so split the original string before encoding each
    /// component instead.
    private static func rawComponents(from value: String) -> RawComponents? {
        guard let schemeEnd = value.firstIndex(of: ":") else { return nil }
        let authorityStart = value.index(after: schemeEnd)
        guard value[authorityStart...].hasPrefix("//") else { return nil }

        let suffixStart = value.index(authorityStart, offsetBy: 2)
        guard let firstDelimiter = value[suffixStart...].firstIndex(where: { character in
            character == "/" || character == "?" || character == "#"
        }) else {
            return RawComponents(path: "", query: nil, fragment: nil)
        }

        let suffix = value[firstDelimiter...]
        let queryDelimiter = suffix.firstIndex(of: "?")
        let fragmentDelimiter = suffix.firstIndex(of: "#")
        let pathEnd = [queryDelimiter, fragmentDelimiter]
            .compactMap { $0 }
            .min() ?? suffix.endIndex
        let path = String(suffix[..<pathEnd])

        let query: String?
        if let queryDelimiter,
           fragmentDelimiter.map({ queryDelimiter < $0 }) ?? true {
            let queryEnd = fragmentDelimiter ?? suffix.endIndex
            query = String(suffix[suffix.index(after: queryDelimiter)..<queryEnd])
        } else {
            query = nil
        }

        let fragment = fragmentDelimiter.map { delimiter in
            String(suffix[suffix.index(after: delimiter)...])
        }

        return RawComponents(path: path, query: query, fragment: fragment)
    }

    private static func isValidWebDestination(_ url: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else { return false }
        return true
    }

    private static func encodedComponent(
        _ value: String,
        allowedCharacters: CharacterSet
    ) -> String? {
        var allowed = allowedCharacters
        allowed.insert(charactersIn: "%")
        return escapedStrayPercents(in: value)
            .addingPercentEncoding(withAllowedCharacters: allowed)
    }

    private static func escapedStrayPercents(in value: String) -> String {
        let bytes = Array(value.utf8)
        var escaped: [UInt8] = []
        escaped.reserveCapacity(bytes.count)
        var index = 0

        while index < bytes.count {
            guard bytes[index] == 37 else {
                escaped.append(bytes[index])
                index += 1
                continue
            }

            if index + 2 < bytes.count,
               isHexDigit(bytes[index + 1]),
               isHexDigit(bytes[index + 2]) {
                escaped.append(contentsOf: bytes[index...(index + 2)])
                index += 3
            } else {
                escaped.append(contentsOf: [37, 50, 53])
                index += 1
            }
        }

        return String(decoding: escaped, as: UTF8.self)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 70)
            || (byte >= 97 && byte <= 102)
    }
}

/// AsyncImage is fast for ordinary HTTPS hosts. Some image CDNs reject its
/// URLSession user agent or redirect to HTTP; WebKit follows the same browser
/// path as the source link, but is isolated to this image-only fallback.
enum WebFallbackImageLabel {
    static func title(alt: String, destinationAvailable: Bool) -> String {
        if destinationAvailable {
            return alt.isEmpty ? "Open image" : "\(alt) — image unavailable; open source"
        }
        return alt.isEmpty ? "Image unavailable" : "\(alt) unavailable"
    }
}

private struct WebFallbackImage: View {
    let url: String
    let alt: String
    @State private var height: CGFloat = 220
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                // A model-authored URL is not guaranteed to be RFC-valid
                // (unencoded non-ASCII paths are common); force-unwrapping
                // here crashed the app on exactly the images most likely to
                // reach this fallback.
                fallbackLabel
                    .padding(12)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            } else {
                RemoteImageWebView(url: url, height: $height, failed: $failed)
                    .frame(height: min(max(height, 80), 420))
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var fallbackLabel: some View {
        if let destination = WebFallbackImageDestination.resolve(url) {
            Link(destination: destination) {
                Label(
                    WebFallbackImageLabel.title(alt: alt, destinationAvailable: true),
                    systemImage: "photo.badge.exclamationmark"
                )
                .font(.footnote.weight(.semibold))
            }
                .tint(.conduitAccent)
        } else {
            Label(
                WebFallbackImageLabel.title(alt: alt, destinationAvailable: false),
                systemImage: "photo.badge.exclamationmark"
            )
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

private struct RemoteImageWebView: UIViewRepresentable {
    let url: String
    @Binding var height: CGFloat
    @Binding var failed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(height: $height, failed: $failed) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(RemoteImageHTML.render(url: url), baseURL: URL(string: "https://conduit.local/"))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var height: CGFloat
        @Binding var failed: Bool

        init(height: Binding<CGFloat>, failed: Binding<Bool>) {
            _height = height
            _failed = failed
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Image failures do not create a navigation error, so inspect the
            // browser image element after it has had a chance to load.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                webView.evaluateJavaScript("(() => { const i = document.getElementById('image'); return { loaded: !!i && i.complete && i.naturalWidth > 0, height: Math.max(document.body.scrollHeight, document.documentElement.scrollHeight) }; })()") { value, _ in
                    guard let result = value as? [String: Any], result["loaded"] as? Bool == true else {
                        self.failed = true
                        return
                    }
                    if let value = result["height"] as? Double { self.height = CGFloat(value) }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed = true }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed = true }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let host = navigationAction.request.url?.host
            decisionHandler(host == nil || host == "conduit.local" ? .allow : .cancel)
        }
    }
}

private enum RemoteImageHTML {
    static func render(url: String) -> String {
        let source = MarkupHTML.jsonString(url)
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;padding:0;background:transparent}img{display:block;max-width:100%;height:auto;margin:auto;border-radius:13px}</style>
        </head><body><img id="image" alt="" />
        <script>document.getElementById('image').src=\(source);</script></body></html>
        """
    }
}

struct ChatCodeBlock: View {
    let source: String
    var language: String = ""
    var usesAccentSurface = false
    var selectionCoordinator: MarkdownSelectionCoordinator?
    var selectionSegment: MarkdownSelectionSegmentDescriptor?
    @State private var copied = false

    private var normalizedLanguage: String { MarkdownLanguage.normalized(language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(normalizedLanguage == "plain" ? "Code" : normalizedLanguage)
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(usesAccentSurface ? Color.white.opacity(0.86) : .secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = source
                    Haptics.light()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption2.weight(.semibold))
                }
                .tint(usesAccentSurface ? .white : .conduitAccent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(usesAccentSurface ? Color.black.opacity(0.28) : Color.primary.opacity(0.055))
            ScrollView(.horizontal, showsIndicators: false) {
                Group {
                    if usesAccentSurface {
                        SelectableTextView(
                            text: source,
                            font: .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular),
                            textColor: UIColor.white.withAlphaComponent(0.96),
                            lineSpacing: 3,
                            wrapsLines: false,
                            selectionCoordinator: selectionCoordinator,
                            selectionSegment: selectionSegment
                        )
                    } else {
                        SelectableTextView(
                            attributedText: SyntaxHighlighter.highlight(source, language: normalizedLanguage),
                            font: .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular),
                            textColor: .label,
                            lineSpacing: 3,
                            wrapsLines: false,
                            selectionCoordinator: selectionCoordinator,
                            selectionSegment: selectionSegment
                        )
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
                .strokeBorder(usesAccentSurface ? Color.white.opacity(0.28) : Color.secondary.opacity(0.20), lineWidth: 1)
        }
    }
}

private struct MermaidBlock: View {
    let source: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var preview: MarkupPreview?

    var body: some View {
        RenderCard(title: "Mermaid", icon: "point.3.connected.trianglepath.dotted", source: source, actionTitle: "Render diagram", actionIcon: "play.fill") {
            preview = MarkupPreview(kind: .mermaid, source: source, light: colorScheme == .light)
        }
        .sheet(item: $preview) { MarkupPreviewSheet(preview: $0) }
    }
}

private struct MathBlock: View {
    let source: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var preview: MarkupPreview?

    var body: some View {
        RenderCard(title: "LaTeX", icon: "function", source: source, actionTitle: "Render formula", actionIcon: "function") {
            preview = MarkupPreview(kind: .math, source: source, light: colorScheme == .light)
        }
        .sheet(item: $preview) { MarkupPreviewSheet(preview: $0) }
    }
}

private struct RenderCard: View {
    let title: String
    let icon: String
    let source: String
    let actionTitle: String
    let actionIcon: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: icon).font(.caption2.monospaced().weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = source
                    Haptics.light()
                } label: { Label("Copy source", systemImage: "doc.on.doc").font(.caption2.weight(.semibold)) }
                    .tint(.conduitAccent)
            }
            Button(action: action) { Label(actionTitle, systemImage: actionIcon).font(.caption.weight(.semibold)) }
                .tint(.conduitAccent)
            SelectableTextView(
                text: source,
                font: .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular),
                textColor: .label,
                maximumNumberOfLines: 5
            )
        }
        .padding(12)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.secondary.opacity(0.20), lineWidth: 1) }
    }
}

private struct MarkupPreview: Identifiable {
    enum Kind { case mermaid, math }
    let id = UUID()
    let kind: Kind
    let source: String
    let light: Bool
}

private struct MarkupPreviewSheet: View {
    let preview: MarkupPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SafeMarkupWebView(html: preview.kind == .mermaid ? MermaidHTML.render(source: preview.source, light: preview.light) : KaTeXHTML.render(source: preview.source, light: preview.light))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    SelectableTextView(
                        text: preview.source,
                        font: .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular),
                        textColor: .label,
                        wrapsLines: false
                    )
                    .padding(12)
                }
                    .frame(maxHeight: 96)
            }
            .navigationTitle(preview.kind == .mermaid ? "Diagram" : "Formula")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct SafeMarkupWebView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(html, baseURL: URL(string: "https://conduit.local/"))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let host = navigationAction.request.url?.host
            decisionHandler(host == nil || host == "conduit.local" || host == "cdn.jsdelivr.net" ? .allow : .cancel)
        }
    }
}

private enum MermaidHTML {
    static func render(source: String, light: Bool) -> String {
        let palette = MarkupPalette(light: light)
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;padding:0;background:\(palette.background);color:\(palette.foreground)}#diagram{padding:16px;box-sizing:border-box}svg{display:block;max-width:100%;height:auto;margin:auto}.error{font:14px -apple-system,sans-serif;color:#d14b4b;white-space:pre-wrap}</style>
        </head><body><div id="diagram">Rendering diagram…</div>
        <script src="https://cdn.jsdelivr.net/npm/mermaid@11.16.0/dist/mermaid.min.js"></script>
        <script>(async function(){try{mermaid.initialize({startOnLoad:false,securityLevel:'strict',theme:'base',themeVariables:{background:'\(palette.background)',primaryColor:'\(palette.primary)',primaryTextColor:'\(palette.foreground)',primaryBorderColor:'\(palette.border)',lineColor:'\(palette.muted)',fontFamily:'-apple-system,BlinkMacSystemFont,sans-serif'}});const result=await mermaid.render('conduit-diagram',\(MarkupHTML.jsonString(source)));document.getElementById('diagram').innerHTML=result.svg;}catch(error){document.getElementById('diagram').innerHTML='<div class="error">'+String(error&&error.message?error.message:error)+'</div>';}})();</script></body></html>
        """
    }
}

private enum KaTeXHTML {
    static func render(source: String, light: Bool) -> String {
        let palette = MarkupPalette(light: light)
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.22/dist/katex.min.css">
        <style>html,body{margin:0;padding:0;background:\(palette.background);color:\(palette.foreground)}#math{padding:24px;box-sizing:border-box;font-size:1.2em;overflow:auto}.error{font:14px -apple-system,sans-serif;color:#d14b4b;white-space:pre-wrap}</style>
        </head><body><div id="math">Rendering formula…</div>
        <script src="https://cdn.jsdelivr.net/npm/katex@0.16.22/dist/katex.min.js"></script>
        <script>try{katex.render(\(MarkupHTML.jsonString(source)),document.getElementById('math'),{displayMode:true,throwOnError:false,trust:false});}catch(error){document.getElementById('math').innerHTML='<div class="error">'+String(error&&error.message?error.message:error)+'</div>';}</script></body></html>
        """
    }
}

private struct MarkupPalette {
    let background: String
    let foreground: String
    let muted: String
    let primary: String
    let border: String

    init(light: Bool) {
        (background, foreground, muted, primary, border) = light ? ("#ffffff", "#1b1d22", "#727780", "#f6f3eb", "#d4cdbf") : ("#16181e", "#f4f5f8", "#9ca1ac", "#20232b", "#454a57")
    }
}

enum MarkupHTML {
    static func jsonString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data("\"\"".utf8)
        let json = String(data: data, encoding: .utf8) ?? "\"\""
        return json
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}

enum MarkdownParser {
    #if DEBUG
    /// Test instrumentation: sizes (utf8 bytes) of every source handed to
    /// `parseDocument`. Lets regression tests assert that pathological
    /// streaming/rendering paths never re-parse the whole document per frame
    /// — a bound on work, not a fragile wall-clock threshold.
    nonisolated(unsafe) static var parseSourceSizes: [Int] = []
    #endif

    /// Compatibility wrapper for callers that only need the visible blocks.
    /// Reference definitions are already stripped from them; call
    /// `parseDocument` when the render context needs those definitions.
    static func parse(_ source: String, recognizesGatewayMedia: Bool = false) -> [MarkdownBlock] {
        parseDocument(source, recognizesGatewayMedia: recognizesGatewayMedia).blocks
    }

    /// Splits a message into its visible blocks and its link reference
    /// definitions. Definitions (`[id]: url`) are block-level Markdown that a
    /// fragment-by-fragment renderer never sees — without this pass they end
    /// up as visible paragraph text and every `[text][id]` use stays literal.
    /// Definition lines are removed here (leaving a blank line behind so
    /// neighboring paragraphs don't merge) and re-fed to Foundation with each
    /// fragment at render time; see `MarkdownReferenceContext`.
    static func parseDocument(_ source: String, recognizesGatewayMedia: Bool = false) -> MarkdownParsedDocument {
        #if DEBUG
        parseSourceSizes.append(source.utf8.count)
        #endif
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var visibleLines: [String] = []
        var definitions: [String] = []
        var openFence: String?
        var mathClose: String?

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code and math blocks are raw content — the same regions
            // the block walker below consumes wholesale — so a
            // definition-looking line inside them must stay put. One known
            // divergence: a fence opener inside a blockquote ("> ```") reads
            // as a quote line to the walker but opens a fence here, so a
            // definition-looking line in that region is collected while the
            // walker renders the region as prose. Quote-nested fences are not
            // a construct this renderer supports; accepted as an edge case.
            if let close = mathClose {
                visibleLines.append(line)
                if trimmed == close { mathClose = nil }
                index += 1
                continue
            }
            if let fence = openFence {
                visibleLines.append(line)
                if trimmed.hasPrefix(fence) { openFence = nil }
                index += 1
                continue
            }
            if let fence = fenceStart(trimmed) {
                openFence = fence
                visibleLines.append(line)
                index += 1
                continue
            }
            if let close = mathBlockOpening(trimmed) {
                mathClose = close
                visibleLines.append(line)
                index += 1
                continue
            }
            if isDefinitionIndent(line), let definition = referenceDefinition(trimmed),
               let span = consumedDefinitionSpan(definition, following: lines, at: index) {
                definitions.append(span.markdown)
                for _ in 0..<span.lineCount { visibleLines.append("") }
                index += span.lineCount
                continue
            }
            visibleLines.append(line)
            index += 1
        }

        let visibleSource = visibleLines.joined(separator: "\n")
        let blocks = parseBlocks(visibleLines, recognizesGatewayMedia: recognizesGatewayMedia)
        // Defensive safety net carried over from the original parse(): if the
        // walker ever produces nothing for non-whitespace input, surface the
        // stripped body rather than rendering an empty message. Definitions
        // were already removed from visibleSource, so they cannot resurface
        // here even in that fallback.
        let finalBlocks = blocks.isEmpty && !visibleSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? [.paragraph(visibleSource)]
            : blocks
        return MarkdownParsedDocument(
            blocks: finalBlocks,
            references: MarkdownReferenceContext(definitionsMarkdown: definitions.joined(separator: "\n"))
        )
    }

    private static func parseBlocks(_ lines: [String], recognizesGatewayMedia: Bool) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }

            if let fence = fenceStart(trimmed) {
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                index += 1
                var code: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(lines[index]); index += 1 }
                if index < lines.count { index += 1 }
                blocks.append(.code(language: language, source: code.joined(separator: "\n")))
                continue
            }

            if let inlineMath = singleLineMath(trimmed) { blocks.append(.math(inlineMath)); index += 1; continue }
            if let closing = mathBlockOpening(trimmed) {
                index += 1
                var math: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != closing { math.append(lines[index]); index += 1 }
                if index < lines.count { index += 1 }
                blocks.append(.math(math.joined(separator: "\n")))
                continue
            }

            if let directive = directiveStart(trimmed) {
                index += 1
                var sections: [[String]] = [[]]
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != ":::" {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if directive == "columns", candidate.lowercased() == "::: column" { sections.append([]) }
                    else { sections[sections.count - 1].append(lines[index]) }
                    index += 1
                }
                if index < lines.count { index += 1 }
                if directive == "columns" { blocks.append(.columns(sections.map { $0.joined(separator: "\n") }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })) }
                else { blocks.append(.callout(kind: directive, text: sections.flatMap { $0 }.joined(separator: "\n"))) }
                continue
            }

            if recognizesGatewayMedia, let mediaPath = gatewayMediaPath(trimmed) { blocks.append(.image(url: "MEDIA: \(mediaPath)", alt: mediaName(mediaPath))); index += 1; continue }
            if let image = imageMarkdown(trimmed) { blocks.append(.image(url: image.url, alt: image.alt)); index += 1; continue }
            if let imageURL = directImageURL(trimmed) { blocks.append(.image(url: imageURL, alt: "")); index += 1; continue }
            if isDivider(trimmed) { blocks.append(.divider); index += 1; continue }
            if let heading = heading(trimmed) { blocks.append(.heading(level: heading.level, text: heading.text)); index += 1; continue }

            if isTableHeader(lines, at: index) {
                let headers = tableCells(lines[index])
                let alignments = tableCells(lines[index + 1]).map(tableAlignment)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty { rows.append(tableCells(lines[index])); index += 1 }
                blocks.append(.table(headers: headers, alignments: alignments, rows: rows))
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoted: [MarkdownQuoteLine] = []
                while index < lines.count, let quote = quoteLine(lines[index]) { quoted.append(quote); index += 1 }
                blocks.append(.quote(quoted))
                continue
            }

            if unorderedItem(trimmed) != nil {
                var items: [String] = []
                while index < lines.count, let item = unorderedItem(lines[index].trimmingCharacters(in: .whitespaces)) { items.append(item); index += 1 }
                blocks.append(.unorderedList(items))
                continue
            }

            if orderedItem(trimmed) != nil {
                var items: [String] = []
                while index < lines.count, let item = orderedItem(lines[index].trimmingCharacters(in: .whitespaces)) { items.append(item); index += 1 }
                blocks.append(.orderedList(items))
                continue
            }

            var paragraph = [line]
            index += 1
            while index < lines.count {
                let candidate = lines[index]
                let next = candidate.trimmingCharacters(in: .whitespaces)
                if next.isEmpty || fenceStart(next) != nil || mathBlockOpening(next) != nil || singleLineMath(next) != nil || directiveStart(next) != nil || (recognizesGatewayMedia && gatewayMediaPath(next) != nil) || imageMarkdown(next) != nil || directImageURL(next) != nil || isDivider(next) || heading(next) != nil || next.hasPrefix(">") || unorderedItem(next) != nil || orderedItem(next) != nil || isTableHeader(lines, at: index) { break }
                paragraph.append(candidate); index += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        }
        return blocks
    }

    static func taskItem(_ value: String) -> (complete: Bool, text: String)? {
        guard let range = value.range(of: #"^\[([ xX])\]\s+"#, options: .regularExpression) else { return nil }
        let marker = String(value[value.index(after: value.startIndex)])
        return (marker.lowercased() == "x", String(value[range.upperBound...]))
    }

    static func calloutMarker(_ value: String) -> (kind: String, remainder: String)? {
        guard let range = value.range(of: #"^\[!([A-Za-z]+)\]\s*"#, options: .regularExpression) else { return nil }
        let marker = String(value[range]).dropFirst(2).prefix { $0.isLetter }
        return (String(marker), String(value[range.upperBound...]))
    }

    private static func fenceStart(_ value: String) -> String? { value.hasPrefix("```") ? "```" : (value.hasPrefix("~~~") ? "~~~" : nil) }

    /// CommonMark allows a definition at most three spaces of indentation;
    /// anything deeper is indented-code content that Foundation keeps as
    /// visible paragraph text, so it must not be collected here.
    private static func isDefinitionIndent(_ line: String) -> Bool {
        var spaces = 0
        for character in line {
            if character == " " { spaces += 1 }
            else if character == "\t" { return false }
            else { break }
        }
        return spaces <= 3
    }

    /// Recognizes the supported single-line subset of CommonMark link
    /// reference definitions: `[label]: destination` with an optional
    /// `"…"`, `'…'`, or `(…)` title and an optional `<…>` destination.
    /// Labels containing brackets and footnote-style `[^…]` markers are out
    /// of scope and return nil (they stay visible text). Definitions with
    /// title continuation lines are deliberately unsupported; this renderer
    /// documents and tests the single-line forms only.
    private static func referenceDefinition(_ value: String) -> String? {
        guard let range = value.range(
            of: #"^\[([^\[\]\^][^\[\]]*)\]:[ \t]+(<[^>]+>|[^\s<][^\s]*)(?:[ \t]+("[^"]*"|'[^']*'|\([^)]*\)))?[ \t]*$"#,
            options: .regularExpression
        ) else { return nil }
        return String(value[range])
    }

    /// Foundation is the authority on valid definitions; the regex above is
    /// only a pre-filter. A regex match Foundation renders as text — e.g. a
    /// destination with an unbalanced `)` — must stay visible in place:
    /// stripping it here would delete it from its position and then
    /// duplicate it after every block when the collected definitions are
    /// re-appended to each fragment. A definition's title may also continue
    /// on the following line; fold a title-shaped next line in only when
    /// Foundation consumes the pair invisibly, so it cannot surface as a
    /// stray paragraph. The shape check keeps block openers (fences, math,
    /// directives) out of the fold even when a bare opener would parse empty.
    private static func consumedDefinitionSpan(
        _ definition: String,
        following lines: [String],
        at index: Int
    ) -> (markdown: String, lineCount: Int)? {
        func isConsumedInvisibly(_ markdown: String) -> Bool {
            (try? AttributedString(
                markdown: markdown,
                options: .init(interpretedSyntax: .full)
            ))?.characters.isEmpty == true
        }

        let next = index + 1 < lines.count
            ? lines[index + 1].trimmingCharacters(in: .whitespaces)
            : ""
        if isTitleContinuation(next), isConsumedInvisibly(definition + "\n" + next) {
            return (definition + "\n" + next, 2)
        }
        return isConsumedInvisibly(definition) ? (definition, 1) : nil
    }

    private static func isTitleContinuation(_ value: String) -> Bool {
        guard value.count >= 2, let first = value.first, let last = value.last else { return false }
        switch (first, last) {
        case ("\"", "\""), ("'", "'"), ("(", ")"): return true
        default: return false
        }
    }
    private static func mathBlockOpening(_ value: String) -> String? { value == "$$" ? "$$" : (value == "\\[" ? "\\]" : nil) }
    private static func singleLineMath(_ value: String) -> String? {
        guard value.hasPrefix("$$"), value.hasSuffix("$$"), value.count > 4 else { return nil }
        return String(value.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
    }
    private static func directiveStart(_ value: String) -> String? {
        guard value.hasPrefix(":::") else { return nil }
        let name = String(value.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
        return ["note", "info", "tip", "hint", "warning", "caution", "danger", "error", "important", "columns"].contains(name) ? name : nil
    }
    private static func imageMarkdown(_ value: String) -> (url: String, alt: String)? {
        guard let match = try? NSRegularExpression(pattern: #"^!\[([^\]]*)\]\((https?://[^\s)]+)(?:\s+\"[^\"]*\")?\)$"#).firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), let altRange = Range(match.range(at: 1), in: value), let urlRange = Range(match.range(at: 2), in: value) else { return nil }
        return (String(value[urlRange]), String(value[altRange]))
    }
    private static func directImageURL(_ value: String) -> String? {
        value.range(of: #"^https?://\S+\.(png|jpe?g|gif|webp)(\?\S*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil ? value : nil
    }
    private static func gatewayMediaPath(_ value: String) -> String? {
        guard value.range(of: #"^MEDIA:\s*\S+\.(png|jpe?g|gif|webp|bmp|heic)(\?\S*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        let path = String(value.dropFirst("MEDIA:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
    private static func mediaName(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? "Image"
    }
    private static func quoteLine(_ value: String) -> MarkdownQuoteLine? {
        var remainder = value.trimmingCharacters(in: .whitespaces)
        var depth = 0
        while remainder.hasPrefix(">") { depth += 1; remainder = String(remainder.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return depth == 0 ? nil : MarkdownQuoteLine(depth: depth, text: remainder)
    }
    private static func heading(_ value: String) -> (level: Int, text: String)? {
        let count = value.prefix { $0 == "#" }.count
        guard (1...6).contains(count), value.dropFirst(count).first == " " else { return nil }
        return (count, String(value.dropFirst(count)).trimmingCharacters(in: .whitespaces))
    }
    private static func isDivider(_ value: String) -> Bool {
        let characters = value.filter { !$0.isWhitespace }
        return characters.count >= 3 && Set(characters).count == 1 && ["-", "*", "_"].contains(characters.first ?? " ")
    }
    private static func unorderedItem(_ value: String) -> String? {
        guard value.count > 2, ["-", "*", "+"].contains(value.first ?? " "), value.dropFirst().first == " " else { return nil }
        return String(value.dropFirst(2))
    }
    private static func orderedItem(_ value: String) -> String? {
        guard let range = value.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) else { return nil }
        return String(value[range.upperBound...])
    }
    private static func isTableHeader(_ lines: [String], at index: Int) -> Bool {
        guard index + 1 < lines.count, lines[index].contains("|") else { return false }
        return lines[index + 1].trimmingCharacters(in: .whitespaces).range(of: #"^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?$"#, options: .regularExpression) != nil
    }
    private static func tableCells(_ line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }
    private static func tableAlignment(_ value: String) -> MarkdownTableAlignment {
        let value = value.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix(":") && value.hasSuffix(":") { return .center }
        if value.hasSuffix(":") { return .trailing }
        return .leading
    }
}

enum MarkdownLanguage {
    static func normalized(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "text", "plaintext": return "plain"
        case "js", "mjs", "cjs": return "javascript"
        case "ts": return "typescript"
        case "py": return "python"
        case "sh", "shell": return "bash"
        case "yml": return "yaml"
        case "html", "xml": return "markup"
        case "md": return "markdown"
        default: return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }
}

/// Box for NSCache, which stores class instances only.
private final class HighlightedCode {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

enum SyntaxHighlighter {
    /// Settled code blocks across the transcript re-render at streaming frame
    /// rate; tokenizing is linear but allocation-heavy, so memoize by content.
    ///
    /// Unlike `MarkdownRenderCache` (keyed on whole-message source, which is
    /// transient every frame while streaming and therefore skips writes), this
    /// cache is keyed per code block by (language, source). Only the single
    /// still-growing block produces a throwaway entry each frame; stable blocks
    /// — both earlier in the streaming message and across the settled
    /// transcript — have a constant key and hit on every subsequent frame, so
    /// writes here are worth keeping. The one transient entry per frame is
    /// bounded and self-evicting under NSCache's LRU/memory policy.
    private static let cache: NSCache<NSString, HighlightedCode> = {
        let cache = NSCache<NSString, HighlightedCode>()
        cache.countLimit = 128
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    static func highlight(_ source: String, language: String) -> AttributedString {
        let key = "\(language)|\(source)" as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        let highlighted = tokenize(source, language: language)
        cache.setObject(HighlightedCode(highlighted), forKey: key, cost: source.utf8.count)
        return highlighted
    }

    private static func tokenize(_ source: String, language: String) -> AttributedString {
        let keywords: Set<String> = ["as", "async", "await", "break", "case", "catch", "class", "const", "continue", "def", "else", "enum", "false", "final", "for", "func", "guard", "if", "import", "in", "init", "let", "nil", "null", "private", "public", "return", "self", "static", "struct", "switch", "throw", "true", "try", "var", "while"]
        // String-literal alternatives must be disjoint (`\\.` vs `[^"\\]`):
        // if both branches can match a backslash, an unterminated literal with
        // many escapes — the normal transient state while a code block streams —
        // backtracks exponentially and wedges the main thread (~2^k paths).
        let pattern = #"(//[^\n]*|#[^\n]*|/\*[\s\S]*?\*/|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|\b\d+(?:\.\d+)?\b|\b[A-Za-z_][A-Za-z0-9_]*\b)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return AttributedString(source) }
        let range = NSRange(source.startIndex..., in: source)
        var cursor = source.startIndex
        var output = AttributedString()
        for match in expression.matches(in: source, range: range) {
            guard let matchRange = Range(match.range, in: source) else { continue }
            append(String(source[cursor..<matchRange.lowerBound]), color: .primary, to: &output)
            let token = String(source[matchRange])
            let color: Color
            if token.hasPrefix("//") || token.hasPrefix("#") || token.hasPrefix("/*") { color = .secondary }
            else if token.hasPrefix("\"") || token.hasPrefix("'") { color = .conduitAura }
            else if Double(token) != nil { color = .orange }
            else if keywords.contains(token) { color = .conduitAccent }
            else { color = .primary }
            append(token, color: color, to: &output)
            cursor = matchRange.upperBound
        }
        append(String(source[cursor...]), color: .primary, to: &output)
        return output
    }

    private static func append(_ text: String, color: Color, to output: inout AttributedString) {
        guard !text.isEmpty else { return }
        var value = AttributedString(text)
        value.foregroundColor = color
        output.append(value)
    }
}
