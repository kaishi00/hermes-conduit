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

    /// The source is a cut of a longer message (a large document's
    /// preview), so its last block may be partial: a diagram or formula
    /// there shows its source instead of drawing a truncated one.
    var mayEndMidBlock = false

    /// The selected chat text size (issue #85): a first-class rendering
    /// input, injected at the chat root. Streaming and settled content read
    /// the same value, so the whole stream stays at one size. The
    /// `.default` environment default keeps non-chat subtrees untouched.
    @Environment(\.chatTextSize) private var chatTextSize
    @Environment(\.markdownJoinsProseRuns) private var joinsProseRuns
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControlEnabled

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
            .environment(\.textSelectionTint, selectionTint)
        } else {
            normalBody
        }
    }

    /// A selection on a sent bubble would take the bubble's own colour (#697).
    private var selectionTint: UIColor? {
        usesAccentSurface ? UIColor.conduitSelectionOnAccent : nil
    }

    /// A streaming reply or a cut preview can end inside a block.
    private var lastBlockMayBePartial: Bool { isStreaming || mayEndMidBlock }

    @ViewBuilder
    private var normalBody: some View {
        let _ = isStreaming ? () : TranscriptPerf.note(.settledMarkdownBody, context: source)
        let rendering = MarkdownRenderCache.rendering(
            source: source,
            recognizesGatewayMedia: gatewayMediaDataURL != nil,
            foregroundStyle: foregroundStyle,
            usesAccentSurface: usesAccentSurface,
            isStreaming: isStreaming,
            chatTextSize: chatTextSize
        )
        // A settled answer in the chat draws its prose runs in one text
        // view each. A streaming reply keeps a view per block, so a new
        // delta never re-lays out the paragraphs above it, and so does
        // every answer under VoiceOver or Switch Control, which step
        // through each block's view. Voice Control can't be detected; it
        // targets controls, and the links inside a run stay targets.
        let proseRuns = joinsProseRuns
            && !voiceOverEnabled
            && !switchControlEnabled
            && !isStreaming
            && newestCharacterOpacities.isEmpty
            && rendering.selectableText == nil
            && !rendering.needsRichBounding
            ? rendering.proseRuns
            : []
        let selectionSegments = rendering.selectableText == nil
            ? MarkdownSelectionSegmentPlan.descriptors(for: rendering.blocks, joiningRuns: proseRuns)
            : []

        Group {
            if let baseText = rendering.selectableText {
                SelectableTextView(
                    attributedText: MarkdownSelectionFormatter.applyingTrailingCharacterOpacities(
                        newestCharacterOpacities,
                        to: baseText,
                        baseColor: usesAccentSurface ? .white : UIColor(foregroundStyle)
                    ),
                    font: ChatTypography.font(for: .body, appearance: chatTextSize),
                    textColor: usesAccentSurface ? .white : UIColor(foregroundStyle),
                    lineSpacing: 4,
                    linkColor: usesAccentSurface ? .white : .link
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if rendering.needsRichBounding {
                // Byte-ordinary but structurally pathological rich content:
                // identical block rendering behind a bounded mount budget
                // (see MarkdownRichContent.swift). Plain flow messages can
                // never reach here — they take the selectableText branch —
                // and ordinary rich messages stay under the budget. The
                // decision and the per-block unit vector come from the
                // cached rendering, so re-evaluations never re-walk the
                // blocks.
                RichBudgetedMarkdownBody(
                    blocks: rendering.blocks,
                    source: source,
                    richUnitsByBlock: rendering.richUnitsByBlock,
                    foregroundStyle: foregroundStyle,
                    usesAccentSurface: usesAccentSurface,
                    gatewayMediaDataURL: gatewayMediaDataURL,
                    selectionCoordinator: selectionCoordinator,
                    selectionSegments: selectionSegments,
                    newestCharacterOpacities: newestCharacterOpacities,
                    lastBlockMayBePartial: lastBlockMayBePartial
                )
            } else {
                VStack(alignment: .leading, spacing: MarkdownProseRun.Spacing.betweenBlocks) {
                    ForEach(MarkdownProseRun.pieces(blockCount: rendering.blocks.count, runs: proseRuns)) { piece in
                        let index = piece.blocks.lowerBound
                        if piece.isRun {
                            MarkdownProseRunView(
                                text: rendering.proseRunText(
                                    for: piece.blocks,
                                    foregroundStyle: foregroundStyle,
                                    usesAccentSurface: usesAccentSurface,
                                    chatTextSize: chatTextSize
                                ),
                                topPadding: MarkdownProseRun.topPadding(for: rendering.blocks[index]),
                                foregroundStyle: foregroundStyle,
                                usesAccentSurface: usesAccentSurface,
                                selectionCoordinator: selectionCoordinator,
                                selectionSegment: selectionSegments.first { $0.id == "block-\(index)" }
                            )
                        } else {
                            MarkdownBlockView(
                                block: rendering.blocks[index],
                                blockIndex: index,
                                foregroundStyle: foregroundStyle,
                                usesAccentSurface: usesAccentSurface,
                                gatewayMediaDataURL: gatewayMediaDataURL,
                                selectionCoordinator: selectionCoordinator,
                                selectionSegments: selectionSegments,
                                newestCharacterOpacities: index == rendering.blocks.count - 1
                                    ? newestCharacterOpacities
                                    : [],
                                isStreamingTail: lastBlockMayBePartial && index == rendering.blocks.count - 1
                            )
                        }
                    }
                }
                .onAppear {
                    selectionCoordinator.replaceSegments(selectionSegments, revision: source)
                }
                .onChange(of: source) { _, _ in
                    selectionCoordinator.replaceSegments(selectionSegments, revision: source)
                }
                // A reply that settles joins its prose runs with the same
                // source: the plan changes shape, the text doesn't.
                .onChange(of: proseRuns) { _, _ in
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
        .environment(\.textSelectionTint, selectionTint)
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
        uiView.selectionTint = context.environment.textSelectionTint
        uiView.refresh()
    }

    /// Match the content exactly — see MarkdownSelectionHandleOverlay.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MarkdownSelectionHighlightView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.bounds.width, height: proposal.height ?? uiView.bounds.height)
    }
}

/// Covers the whole message, so the highlight is a shape layer's path: a
/// view that drew its own content kept a transparent bitmap the size of
/// the message, made again each time its row scrolled into view.
private final class MarkdownSelectionHighlightView: UIView {
    weak var coordinator: MarkdownSelectionCoordinator?
    /// Nil draws the standard blue.
    var selectionTint: UIColor?

    override class var layerClass: AnyClass { CAShapeLayer.self }

    private var shapeLayer: CAShapeLayer { layer as! CAShapeLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ConduitAccentTrait.self]) { (view: MarkdownSelectionHighlightView, _: UITraitCollection) in
            view.refresh()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refresh()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refresh()
    }

    func refresh() {
        guard let coordinator, let window else {
            shapeLayer.path = nil
            return
        }
        let path = UIBezierPath()
        for windowRect in coordinator.highlightRects(in: window) {
            let localRect = convert(windowRect, from: window)
            guard localRect.intersects(bounds) else { continue }
            path.append(UIBezierPath(
                roundedRect: localRect.intersection(bounds).insetBy(dx: -0.5, dy: -0.5),
                cornerRadius: 2
            ))
        }
        shapeLayer.fillColor = (selectionTint ?? .systemBlue).withAlphaComponent(0.24).resolvedColor(with: traitCollection).cgColor
        shapeLayer.path = path.isEmpty ? nil : path.cgPath
    }
}

/// One render's parsed blocks plus the prebuilt selectable string (nil when
/// the blocks need the full block-view path). A class so NSCache can hold it.
///
/// Structural rich-content metadata (the per-block rich-unit vector) is
/// computed ONCE here, with the parse, and cached with the rendering — the
/// exact pathological Markdown this bounding exists for used to re-walk
/// every table's cells on each SwiftUI body re-evaluation just to
/// rediscover the same budget (see MarkdownRichContentPolicy).
final class MarkdownRendering {
    let blocks: [MarkdownBlock]
    /// The message's link reference definitions; block views need them to
    /// resolve reference-style links when re-parsing each fragment.
    let references: MarkdownReferenceContext
    let selectableText: NSAttributedString?
    /// Per-block rich-layout units (MarkdownRichContentPolicy.richUnits),
    /// aligned with blocks by index.
    let richUnitsByBlock: [Int]

    /// Whether this message's aggregate rich complexity exceeds the
    /// progressive-mount budget.
    var needsRichBounding: Bool {
        MarkdownRichContentPolicy.needsBounding(unitsByBlock: richUnitsByBlock)
    }

    /// Found and built on first use, by the main actor's view bodies only.
    @MainActor private var foundProseRuns: [Range<Int>]?
    /// Each run's text, built once per settled rendering so a row that
    /// scrolls back in hands its text view the same string. The render
    /// cache keys a rendering on its surface and text size, so the style a
    /// run's text was built with never changes under it.
    @MainActor private var proseRunTexts: [Range<Int>: NSAttributedString] = [:]

    init(blocks: [MarkdownBlock], references: MarkdownReferenceContext, selectableText: NSAttributedString?) {
        self.blocks = blocks
        self.references = references
        self.selectableText = selectableText
        self.richUnitsByBlock = MarkdownRichContentPolicy.richUnitsByBlock(blocks)
    }

    /// The prose runs a chat draws in one text view each.
    @MainActor
    var proseRuns: [Range<Int>] {
        if let foundProseRuns { return foundProseRuns }
        let runs = MarkdownProseRun.ranges(in: blocks)
        foundProseRuns = runs
        return runs
    }

    /// A run's text, built with these styles the first time it's asked for.
    @MainActor
    func proseRunText(
        for run: Range<Int>,
        foregroundStyle: Color,
        usesAccentSurface: Bool,
        chatTextSize: ChatTextAppearance
    ) -> NSAttributedString {
        if let text = proseRunTexts[run] { return text }
        let text = MarkdownProseRun.attributedText(
            for: blocks[run],
            references: references,
            foregroundStyle: foregroundStyle,
            usesAccentSurface: usesAccentSurface,
            chatTextSize: chatTextSize
        )
        proseRunTexts[run] = text
        return text
    }
}

/// Every visible MarkdownText body re-evaluates ~30x/s while a reply streams
/// (each delta publishes an AppState change), and each evaluation used to
/// re-parse the source and rebuild the attributed string from scratch —
/// O(visible transcript) main-thread work per frame. Memoize per source and
/// style so settled messages render from cache and only genuinely new content
/// pays for parsing. Streaming-tail fades stay per-frame but are applied to a
/// copy of the cached base rather than triggering a rebuild.
enum MarkdownRenderCache {
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
        isStreaming: Bool,
        chatTextSize: ChatTextAppearance
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

        // Fonts resolve against the current Dynamic Type size AND the
        // selected chat text size (issue #85), so either change must miss the
        // cache rather than serve stale metrics. The chat-size identity is
        // the persisted enum position, so re-tuning the scale factors later
        // needs no cache migration. Reading preferredContentSizeCategory
        // touches UIApplication.shared, hence the @MainActor isolation on
        // this function.
        let key = [
            recognizesGatewayMedia ? "1" : "0",
            usesAccentSurface ? "1" : "0",
            UIApplication.shared.preferredContentSizeCategory.rawValue,
            chatTextSize.cacheIdentity,
            // Hermes' @session links are titled with the chat's name once
            // Conduit lists it.
            HermesSessionReference.titleKey(for: source),
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
                newestCharacterOpacities: [],
                chatTextSize: chatTextSize
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
            // A rich answer's prose runs build their text later, about the
            // size a flow message's text is.
            let cost = source.utf8.count + (rendering.selectableText?.length ?? source.utf16.count) * 4
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

/// A fenced code block's delimiter: three or more backticks or tildes. Only
/// a line of the same character, at least as long and with nothing after
/// it, closes the block, so a ````markdown block can show ``` fences inside.
struct MarkdownFence: Equatable {
    let character: Character
    let length: Int

    /// The fence a whitespace-trimmed line opens, if any.
    static func opening(_ trimmed: String) -> MarkdownFence? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let length = trimmed.prefix { $0 == first }.count
        return length >= 3 ? MarkdownFence(character: first, length: length) : nil
    }

    /// Whether this whitespace-trimmed line closes the block.
    func closes(_ trimmed: String) -> Bool {
        trimmed.count >= length && trimmed.allSatisfy { $0 == character }
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
    /// `start` is the number written on the first item, as CommonMark
    /// numbers a list, so one split by a code block carries on.
    case orderedList([String], start: Int = 1)
    case table(headers: [String], alignments: [MarkdownTableAlignment], rows: [[String]])
    case image(url: String, alt: String)
    case math(String)
    case callout(kind: String, text: String)
    case columns([String])
    case code(language: String, source: String)
    case divider
    /// An HTML file on the Hermes host the reply asked to show in place
    /// (`::preview{file="…"}`).
    case htmlPreview(path: String)
    /// A Hermes Desktop plugin's card (`::richui{id="…"}`, #1522).
    case desktopCard(DesktopCardDirective)
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
        newestCharacterOpacities: [Double],
        chatTextSize: ChatTextAppearance = .default
    ) -> NSAttributedString? {
        guard !blocks.isEmpty, blocks.allSatisfy(\.isSelectableFlowBlock) else { return nil }

        // All fonts resolve through ChatTypography (issue #85): the selected
        // chat size scales ON TOP of the current Dynamic Type size, and
        // `.default` reproduces the historical fonts exactly.
        let bodyFont = ChatTypography.font(for: .body, appearance: chatTextSize)
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
                foregroundStyle: foregroundStyle,
                chatTextSize: chatTextSize
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
        foregroundStyle: Color,
        chatTextSize: ChatTextAppearance
    ) -> NSAttributedString? {
        switch block {
        case .heading(let level, let text):
            return inline(
                text,
                references: references,
                font: headingFont(level, chatTextSize: chatTextSize),
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
                markerColor: usesAccentSurface ? .white : UIColor(Color.conduitAccent),
                chatTextSize: chatTextSize
            )

        case .orderedList(let items, let start):
            return list(
                items,
                ordered: true,
                start: start,
                references: references,
                bodyFont: bodyFont,
                textColor: textColor,
                linkColor: linkColor,
                markerColor: usesAccentSurface ? .white : UIColor(Color.conduitAccent),
                chatTextSize: chatTextSize
            )

        case .quote(let lines):
            let result = NSMutableAttributedString()
            let quoteColor = usesAccentSurface
                ? UIColor.white.withAlphaComponent(0.90)
                : UIColor(foregroundStyle).withAlphaComponent(0.90)
            let quoteFont = ChatTypography.font(for: .quote, appearance: chatTextSize)

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
        start: Int = 1,
        references: MarkdownReferenceContext,
        bodyFont: UIFont,
        textColor: UIColor,
        linkColor: UIColor,
        markerColor: UIColor,
        chatTextSize: ChatTextAppearance
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
                marker = ordered ? "\(start + index). " : "• "
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

    private static func headingFont(_ level: Int, chatTextSize: ChatTextAppearance) -> UIFont {
        MarkdownHeading.font(for: level, chatTextSize: chatTextSize)
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

    /// The same alignment for a cell drawn as plain text: its wrapped
    /// lines, and its place in the column.
    var text: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var frame: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// Shared heading font logic used by both MarkdownSelectionFormatter
/// and MarkdownBlockView to prevent divergence.
enum MarkdownHeading {
    /// Heading font at the selected chat text size. The style mapping and
    /// bold trait live in ChatTypography so the SwiftUI block renderer and
    /// the attributed-string formatter can never diverge.
    static func font(for level: Int, chatTextSize: ChatTextAppearance) -> UIFont {
        ChatTypography.font(for: .heading(level: level), appearance: chatTextSize)
    }

    /// Historical entry point: today's typography at the default chat size.
    static func font(for level: Int) -> UIFont {
        font(for: level, chatTextSize: .default)
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
    /// The last block of a reply that is still streaming (or of a cut
    /// preview), which may be half written: a diagram or formula there
    /// shows its source until it's done.
    var isStreamingTail = false
    @Environment(\.chatTextSize) private var chatTextSize

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

        case .orderedList(let items, let start):
            MarkdownList(
                items: items,
                ordered: true,
                start: start,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                selectionCoordinator: selectionCoordinator,
                selectionSegments: blockSelectionSegments,
                trailingCharacterOpacities: newestCharacterOpacities
            )

        case .table(let headers, let alignments, let rows):
            // Structural complexity — not whole-message bytes — decides the
            // presentation: a 45-row table in a 40 KB message mounts the
            // same thousand TextKit cell views as one in a 400 KB message.
            // Both paths share MarkdownTableRowView, so appearance and
            // selection behavior match either way.
            if MarkdownRichContentPolicy.isComplexTable(headers: headers, rows: rows) {
                LargeMarkdownTable(
                    headers: headers,
                    alignments: alignments,
                    rows: rows,
                    foregroundStyle: foregroundStyle,
                    usesAccentSurface: usesAccentSurface,
                    selectionCoordinator: selectionCoordinator,
                    blockIndex: blockIndex,
                    selectionSegments: selectionSegments
                )
            } else {
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
            }

        case .image(let url, let alt):
            RemoteMarkdownImage(url: url, alt: alt, gatewayMediaDataURL: gatewayMediaDataURL)

        case .htmlPreview(let path):
            HTMLPreviewBlock(path: path, gatewayMediaDataURL: gatewayMediaDataURL, isComplete: !isStreamingTail) {
                RemoteMarkdownImage(url: "MEDIA: \(path)", alt: MarkdownParser.mediaName(path), gatewayMediaDataURL: gatewayMediaDataURL)
            }

        case .desktopCard(let card):
            DesktopCardBlock(card: card)

        case .math(let source):
            // The #88 oversized-math guard applies to the block itself,
            // wherever it renders — never only inside large-document mode.
            if MarkdownBlockView.mathNeedsGuard(source) {
                GuardedSourceCard(
                    title: "LaTeX",
                    icon: "function",
                    source: source,
                    guardBytes: MarkdownLargeDocumentPolicy.mathGuardBytes
                )
            } else {
                MarkupBlock(kind: .math, source: source, isComplete: !isStreamingTail)
            }

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
            switch MarkdownBlockView.codePresentation(language: language, source: source) {
            case .guardedMermaid:
                // The #88 Mermaid guard, applied per block: a diagram past
                // the guard size renders as a copyable bounded card no
                // matter how small the enclosing message is.
                GuardedSourceCard(
                    title: "Mermaid",
                    icon: "point.3.connected.trianglepath.dotted",
                    source: source,
                    guardBytes: MarkdownLargeDocumentPolicy.mermaidGuardBytes
                )
            case .mermaid:
                MarkupBlock(kind: .mermaid, source: source, isComplete: !isStreamingTail)
            case .slicedCode:
                LargeCodeBlockView(
                    source: source,
                    language: language,
                    usesAccentSurface: usesAccentSurface
                )
            case .code:
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
        MarkdownHeading.font(for: level, chatTextSize: chatTextSize)
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

    // MARK: Block-local routing (pure, unit-testable)

    /// The bounded presentations a code fence can take. The guards are
    /// properties of the BLOCK — they apply identically in the ordinary
    /// path and in large-document mode, which is what makes Mermaid and
    /// oversized-code safety independent of the whole-message threshold.
    enum CodePresentation: Equatable {
        /// Mermaid source beyond the #88 guard: bounded copyable card,
        /// never drawn.
        case guardedMermaid
        /// Ordinary Mermaid diagram, drawn in the message.
        case mermaid
        /// Code at/above the #88 large-code threshold: bounded preview,
        /// then line/byte slices with off-main highlighting.
        case slicedCode
        /// Ordinary code block.
        case code
    }

    static func codePresentation(language: String, source: String) -> CodePresentation {
        let normalized = MarkdownLanguage.normalized(language)
        if normalized == "mermaid" {
            return source.utf8.count > MarkdownLargeDocumentPolicy.mermaidGuardBytes
                ? .guardedMermaid
                : .mermaid
        }
        return MarkdownLargeDocumentPolicy.isLargeCodeBlock(source) ? .slicedCode : .code
    }

    /// Oversized math sources aren't drawn (#88 guard), applied per block
    /// rather than per document.
    static func mathNeedsGuard(_ source: String) -> Bool {
        source.utf8.count > MarkdownLargeDocumentPolicy.mathGuardBytes
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

    /// Everything a bridged fragment depends on, boxed for NSCache. It keys
    /// on the text color itself, not only the accent surface the render
    /// cache keys on: quotes pass a dimmed color. Two equal colors stored
    /// differently can only cost a miss.
    private final class BridgedKey: NSObject {
        let source: String
        let definitions: String
        let foregroundStyle: Color
        let font: UIFont
        let usesAccentSurface: Bool

        init(source: String, definitions: String, foregroundStyle: Color, font: UIFont, usesAccentSurface: Bool) {
            self.source = source
            self.definitions = definitions
            self.foregroundStyle = foregroundStyle
            self.font = font
            self.usesAccentSurface = usesAccentSurface
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(source)
            hasher.combine(definitions)
            hasher.combine(foregroundStyle)
            hasher.combine(font)
            hasher.combine(usesAccentSurface)
            return hasher.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? BridgedKey else { return false }
            return source == other.source
                && definitions == other.definitions
                && foregroundStyle == other.foregroundStyle
                && font == other.font
                && usesAccentSurface == other.usesAccentSurface
        }
    }

    /// Settled fragments parsed and bridged once. LazyVStack takes a row
    /// down when it scrolls out of view and builds it again when it comes
    /// back, and each block used to run Foundation's Markdown parser and
    /// the UIKit bridge again on the way in. Returning the same string also
    /// lets the text view's presentation check match on identity.
    private static let bridgedCache: NSCache<BridgedKey, NSAttributedString> = {
        let cache = NSCache<BridgedKey, NSAttributedString>()
        cache.countLimit = 2048
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    @MainActor
    static func bridged(
        source: String,
        references: MarkdownReferenceContext,
        foregroundStyle: Color,
        usesAccentSurface: Bool,
        font: UIFont,
        trailingCharacterOpacities: [Double]
    ) -> NSAttributedString {
        func build() -> NSAttributedString {
            SelectableTextView.bridge(
                attributed(
                    source: source,
                    references: references,
                    foregroundStyle: foregroundStyle,
                    trailingCharacterOpacities: trailingCharacterOpacities
                ),
                defaultFont: font,
                defaultColor: usesAccentSurface ? .white : UIColor(foregroundStyle),
                linkColor: usesAccentSurface ? .white : .link
            )
        }
        // A streaming tail fades its newest characters each frame.
        guard trailingCharacterOpacities.isEmpty else { return build() }

        let key = BridgedKey(
            source: source,
            definitions: references.definitionsMarkdown,
            foregroundStyle: foregroundStyle,
            font: font,
            usesAccentSurface: usesAccentSurface
        )
        if let cached = bridgedCache.object(forKey: key) { return cached }
        // The bridge builds a mutable string; every row shares the cached
        // one, so it's kept as an immutable copy.
        let value = NSAttributedString(attributedString: build())
        bridgedCache.setObject(value, forKey: key, cost: value.length * 2)
        return value
    }

    private final class PlainTextBox {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private static let plainTextCache: NSCache<NSAttributedString, PlainTextBox> = {
        let cache = NSCache<NSAttributedString, PlainTextBox>()
        cache.countLimit = 2048
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    /// A bridged fragment as SwiftUI text, for a table cell drawn as plain
    /// text. SwiftUI's Text reads its own attributes, not UIKit's, so the
    /// fonts, colors, links and strikethrough the bridge set carry over run
    /// by run. Keyed on the bridged string, which `bridged` returns from
    /// its cache.
    @MainActor
    static func plainText(_ bridged: NSAttributedString) -> AttributedString {
        if let cached = plainTextCache.object(forKey: bridged) { return cached.value }
        var result = AttributedString()
        bridged.enumerateAttributes(in: NSRange(location: 0, length: bridged.length)) { attributes, range, _ in
            typealias SwiftUIKeys = AttributeScopes.SwiftUIAttributes
            var run = AttributedString(bridged.attributedSubstring(from: range).string)
            if let font = attributes[.font] as? UIFont {
                run[SwiftUIKeys.FontAttribute.self] = Font(font as CTFont)
            }
            if let color = attributes[.foregroundColor] as? UIColor {
                run[SwiftUIKeys.ForegroundColorAttribute.self] = Color(uiColor: color)
            }
            if let url = attributes[.link] as? URL {
                run.link = url
            } else if let string = attributes[.link] as? String, let url = URL(string: string) {
                run.link = url
            }
            // Underlined, as a text view's link attributes draw a link.
            if run.link != nil || attributes[.underlineStyle] != nil {
                run[SwiftUIKeys.UnderlineStyleAttribute.self] = .single
            }
            if attributes[.strikethroughStyle] != nil {
                run[SwiftUIKeys.StrikethroughStyleAttribute.self] = .single
            }
            result.append(run)
        }
        plainTextCache.setObject(PlainTextBox(result), forKey: bridged, cost: bridged.length * 2)
        return result
    }
}

private struct InlineMarkdown: View {
    let source: String
    let foregroundStyle: Color
    let usesAccentSurface: Bool
    /// Explicit role font (headings, table cells); nil resolves the body
    /// role through ChatTypography at the selected chat text size.
    var font: UIFont?
    var lineSpacing: CGFloat = 0
    var maximumNumberOfLines: Int = 0
    var textAlignment: NSTextAlignment = .natural
    var selfSizingWidthRange: ClosedRange<CGFloat>? = nil
    var selectionCoordinator: MarkdownSelectionCoordinator?
    var selectionSegment: MarkdownSelectionSegmentDescriptor?
    var trailingCharacterOpacities: [Double] = []
    @Environment(\.markdownReferences) private var references
    @Environment(\.chatTextSize) private var chatTextSize

    private var effectiveFont: UIFont {
        font ?? ChatTypography.font(for: .body, appearance: chatTextSize)
    }

    private var attributed: NSAttributedString {
        InlineMarkdownContent.bridged(
            source: source,
            references: references,
            foregroundStyle: foregroundStyle,
            usesAccentSurface: usesAccentSurface,
            font: effectiveFont,
            trailingCharacterOpacities: trailingCharacterOpacities
        )
    }

    var body: some View {
        SelectableTextView(
            attributedText: attributed,
            font: effectiveFont,
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
    var start = 1
    let foregroundStyle: Color
    let usesAccentSurface: Bool
    let selectionCoordinator: MarkdownSelectionCoordinator?
    let selectionSegments: [MarkdownSelectionSegmentDescriptor]
    var trailingCharacterOpacities: [Double] = []
    @Environment(\.chatTextSize) private var chatTextSize
    @Environment(\.sizeCategory) private var sizeCategory

    /// Marker glyphs resolve Dynamic Type through the environment category
    /// (rather than a size frozen at body-evaluation time), so a system
    /// text-size change re-resolves them wherever the list re-evaluates.
    private var markerFont: UIFont {
        ChatTypography.font(for: .body, appearance: chatTextSize, environmentCategory: sizeCategory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let task = MarkdownParser.taskItem(item)
                // Top-aligned with the marker in a box at least one text
                // line tall: the item is a UIKit text view, which reports no
                // text baseline to SwiftUI, so a first-baseline row put the
                // marker a line above its text.
                HStack(alignment: .top, spacing: 9) {
                    if let task {
                        Image(systemName: task.complete ? "checkmark.square.fill" : "square")
                            .font(.system(size: markerFont.pointSize))
                            .foregroundStyle(task.complete
                                             ? (usesAccentSurface ? Color.white : Color.conduitAccent)
                                             : (usesAccentSurface ? Color.white.opacity(0.82) : Color.secondary))
                            .frame(width: ChatTypography.dimension(16, appearance: chatTextSize), alignment: .trailing)
                            .frame(minHeight: markerFont.lineHeight)
                    } else {
                        Text(ordered ? "\(start + index)." : "•")
                            .font(.system(size: markerFont.pointSize, weight: .semibold, design: chatTextSize.style.fontDesign))
                            .foregroundStyle(usesAccentSurface ? Color.white.opacity(0.92) : Color.conduitAccent)
                            .frame(width: ChatTypography.dimension(ordered ? 24 : 12, appearance: chatTextSize), alignment: .trailing)
                            .frame(minHeight: markerFont.lineHeight)
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
    @Environment(\.chatTextSize) private var chatTextSize

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
                            font: ChatTypography.font(for: .quote, appearance: chatTextSize),
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
        case "tip", "hint": (AppLocalization.string("Tip"), "lightbulb.fill", .green)
        case "warning", "caution": (AppLocalization.string("Warning"), "exclamationmark.triangle.fill", .orange)
        case "danger", "error": (AppLocalization.string("Important"), "exclamationmark.octagon.fill", .red)
        case "important": (AppLocalization.string("Important"), "exclamationmark.circle.fill", .purple)
        default: (AppLocalization.string("Note"), "info.circle.fill", .blue)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(detail.title, systemImage: detail.icon)
                .scaledFont(.caption.weight(.bold))
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
        references: MarkdownReferenceContext = .empty,
        chatTextSize: ChatTextAppearance = .default
    ) -> [CGFloat] {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return [] }

        // Fonts resolve against the current Dynamic Type size AND the
        // selected chat text size (issue #85), so the widths key on the
        // content category just like MarkdownRenderCache, on the chat-size
        // identity, on the viewport width that feeds the fit-or-shrink
        // decision, and on the reference definitions (they change how cell
        // source measures). A chat-size change must never serve stale
        // measurements from the previous size.
        let key = (
            [
                UIApplication.shared.preferredContentSizeCategory.rawValue,
                chatTextSize.cacheIdentity,
                String(format: "%.1f", availableWidth),
                references.definitionsMarkdown
            ]
                + headers
                + rows.flatMap { $0.isEmpty ? ["<empty-row>"] : $0 }
        ).joined(separator: "\u{1F}") as NSString

        if let cached = cache.object(forKey: key) as? [CGFloat] { return cached }

        let headerFont = ChatTypography.font(for: .tableHeader, appearance: chatTextSize)
        let bodyFont = ChatTypography.font(for: .tableBody, appearance: chatTextSize)

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

    /// The table as tab-separated lines, each cell's Markdown resolved to
    /// its text, so it pastes into a spreadsheet as a grid. A tab or line
    /// break inside a cell becomes a space, so it can't split the grid.
    /// Safe off the main thread, where Copy Table runs it.
    static func plainText(headers: [String], rows: [[String]], references: MarkdownReferenceContext) -> String {
        ([headers] + rows)
            .map { row in
                row.map { cell in
                    String(InlineMarkdownContent.attributed(source: cell, references: references).characters)
                        .split(omittingEmptySubsequences: false) { $0 == "\t" || $0.isNewline }
                        .joined(separator: " ")
                }
                .joined(separator: "\t")
            }
            .joined(separator: "\n")
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

/// The zero-height width probe shared by BOTH table presentations: the
/// chat's proposed width for the block, read once per layout width change.
/// Extracted so the ordinary MarkdownTable and the paged
/// LargeMarkdownTable resolve columns from the SAME container-width
/// knowledge — crossing the structural complexity threshold must not
/// change whether a previously fitting table fits.
private struct MarkdownTableWidthProbe: View {
    /// The width the last table read. A table mounting again as its row
    /// scrolls back into view starts from it, so its columns are laid out
    /// once instead of at the fallback width and again a frame later. After
    /// the chat's width changes, the first table to mount re-resolves once,
    /// as every table used to. Only read and written on the main thread.
    nonisolated(unsafe) static var lastWidth: CGFloat = 0

    @Binding var width: CGFloat

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { record(proxy.size.width) }
                .onChange(of: proxy.size.width) { _, newWidth in record(newWidth) }
        }
        .frame(height: 0)
    }

    private func record(_ newWidth: CGFloat) {
        if newWidth > 0 { Self.lastWidth = newWidth }
        width = newWidth
    }
}

/// The ordinary (non-paged) table presentation. Internal (not private) so
/// the chat-size wiring into column measurement is directly testable.
struct MarkdownTable: View {
    let headers: [String]
    let alignments: [MarkdownTableAlignment]
    let rows: [[String]]
    let foregroundStyle: Color
    let usesAccentSurface: Bool
    let selectionCoordinator: MarkdownSelectionCoordinator?
    let blockIndex: Int
    let selectionSegments: [MarkdownSelectionSegmentDescriptor]

    /// The chat's proposed width for this block, read by a zero-height
    /// probe above the scroll view. It starts from the last width a table
    /// read; zero means "unknown yet" (first pass), and the layout then
    /// falls back to cap-and-scroll and re-resolves a frame later, once the
    /// width is known.
    @State private var availableWidth: CGFloat = MarkdownTableWidthProbe.lastWidth
    /// Turned on from the long-press menu; kept until the row is taken down.
    @State private var selectionTurnedOn = false
    @Environment(\.markdownTablePlainCells) private var drawsPlainCells
    @Environment(\.markdownReferences) private var references
    @Environment(\.chatTextSize) private var chatTextSize

    private var selectsText: Bool { !drawsPlainCells || selectionTurnedOn }

    private var columnWidths: [CGFloat] {
        MarkdownTableLayout.columnWidths(
            headers: headers,
            rows: rows,
            availableWidth: availableWidth,
            references: references,
            chatTextSize: chatTextSize
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            MarkdownTableWidthProbe(width: $availableWidth)

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
            .modifier(MarkdownTableMenu(
                isOn: !selectsText,
                copyText: { [headers, rows, references] in
                    MarkdownTableLayout.plainText(headers: headers, rows: rows, references: references)
                },
                selectText: { selectionTurnedOn = true }
            ))
        }
    }

    private func tableRow(_ cells: [String], rowIndex: Int, isHeader: Bool, widths: [CGFloat]) -> some View {
        MarkdownTableRowView(
            cells: cells,
            isHeader: isHeader,
            widths: widths,
            alignments: alignments,
            foregroundStyle: foregroundStyle,
            usesAccentSurface: usesAccentSurface,
            selectsText: selectsText,
            selectionCoordinator: selectionCoordinator,
            segmentFor: { selectionSegment(row: rowIndex, column: $0) }
        )
    }

    private func selectionSegment(row: Int, column: Int) -> MarkdownSelectionSegmentDescriptor? {
        let id = "block-\(blockIndex)-table-r\(row)-c\(column)"
        return selectionSegments.first { $0.id == id }
    }
}

/// The table row rendering shared by `MarkdownTable` and the paged
/// `LargeMarkdownTable` so dividers, fonts, alignment, selection, and the
/// deterministic single-width sizing behave identically in both paths.
struct MarkdownTableRowView: View {
    let cells: [String]
    let isHeader: Bool
    let widths: [CGFloat]
    let alignments: [MarkdownTableAlignment]
    let foregroundStyle: Color
    let usesAccentSurface: Bool
    /// Each cell a selectable text view, or plain text: the chat's tables,
    /// until the reader turns on selection from the long-press menu.
    let selectsText: Bool
    let selectionCoordinator: MarkdownSelectionCoordinator?
    let segmentFor: (Int) -> MarkdownSelectionSegmentDescriptor?
    @Environment(\.chatTextSize) private var chatTextSize

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                let width = widths.indices.contains(index)
                    ? widths[index]
                    : MarkdownTableLayout.shrinkFloorContentWidth
                let alignment = alignments.indices.contains(index) ? alignments[index] : .leading
                let font = ChatTypography.font(
                    for: isHeader ? .tableHeader : .tableBody,
                    appearance: chatTextSize
                )
                Group {
                    if selectsText {
                        InlineMarkdown(
                            source: cell,
                            foregroundStyle: foregroundStyle,
                            usesAccentSurface: usesAccentSurface,
                            font: font,
                            textAlignment: alignment.nsText,
                            // The exact shared column width — a single-value range keeps
                            // the cell's measured/committed height deterministic from the
                            // first layout pass, and .frame(width:) below pins the
                            // displayed width so every row's dividers align.
                            selfSizingWidthRange: width...width,
                            selectionCoordinator: selectionCoordinator,
                            selectionSegment: segmentFor(index)
                        )
                    } else {
                        MarkdownPlainCell(
                            source: cell,
                            foregroundStyle: foregroundStyle,
                            usesAccentSurface: usesAccentSurface,
                            font: font,
                            alignment: alignment
                        )
                    }
                }
                    .frame(width: width, alignment: alignment.frame)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                if index < cells.count - 1 {
                    Divider().overlay(usesAccentSurface ? Color.white.opacity(0.22) : Color.secondary.opacity(0.18))
                }
            }
        }
    }
}

/// A table cell drawn as plain text, from the attributed content the
/// selectable cell shows. A selectable text view per cell made a table
/// most of what a long answer cost to build as it scrolled in; plain text
/// costs a fraction of that. Links stay tappable: SwiftUI opens them
/// through the environment's openURL, as the text views do.
private struct MarkdownPlainCell: View {
    let source: String
    let foregroundStyle: Color
    let usesAccentSurface: Bool
    let font: UIFont
    let alignment: MarkdownTableAlignment
    @Environment(\.markdownReferences) private var references

    var body: some View {
        let _ = TranscriptPerf.note(.plainTableCellBody)
        Text(InlineMarkdownContent.plainText(InlineMarkdownContent.bridged(
            source: source,
            references: references,
            foregroundStyle: foregroundStyle,
            usesAccentSurface: usesAccentSurface,
            font: font,
            trailingCharacterOpacities: []
        )))
            .multilineTextAlignment(alignment.text)
            .tint(usesAccentSurface ? .white : Color(uiColor: .link))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A long press on a table whose cells are plain text copies the table or
/// turns on text selection, which draws its cells as selectable text views
/// until its row is taken down. VoiceOver offers both as actions.
private struct MarkdownTableMenu: ViewModifier {
    let isOn: Bool
    let copyText: @Sendable () -> String
    let selectText: () -> Void

    func body(content: Content) -> some View {
        if isOn {
            content
                .contextMenu {
                    Button(action: copyTable) {
                        Label("Copy Table", systemImage: "doc.on.doc")
                    }
                    Button(action: selectText) {
                        Label("Select Text", systemImage: "character.cursor.ibeam")
                    }
                }
                .accessibilityAction(named: Text("Copy Table"), copyTable)
                .accessibilityAction(named: Text("Select Text"), selectText)
        } else {
            content
        }
    }

    /// Resolving every cell's Markdown is the user's wait on a big table,
    /// so it runs off the main thread.
    private func copyTable() {
        let copyText = copyText
        Task.detached(priority: .userInitiated) {
            let text = copyText()
            await MainActor.run { UIPasteboard.general.string = text }
        }
    }
}

/// Tables draw their cells as plain text, with selection a long press
/// away. Set by the chat, where tables mount and unmount as the transcript
/// scrolls; elsewhere cells stay selectable text views.
private struct MarkdownTablePlainCellsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var markdownTablePlainCells: Bool {
        get { self[MarkdownTablePlainCellsKey.self] }
        set { self[MarkdownTablePlainCellsKey.self] = newValue }
    }
}

/// Paged presentation for very large tables: column widths are computed
/// once from a bounded sample of leading rows (measuring every cell of a
/// 1 MB table would itself be unbounded work), and rows mount in explicit
/// batches — never all at once. Cell selection ids keep the ordinary
/// `block-N-table-rX-cY` shape, so coordinator selection behaves like any
/// other table.
struct LargeMarkdownTable: View {
    let headers: [String]
    let alignments: [MarkdownTableAlignment]
    let rows: [[String]]
    let foregroundStyle: Color
    let usesAccentSurface: Bool
    let selectionCoordinator: MarkdownSelectionCoordinator?
    let blockIndex: Int
    let selectionSegments: [MarkdownSelectionSegmentDescriptor]

    @State private var renderedRowCount: Int
    /// The chat's proposed width for this block, read by the SAME zero-height
    /// probe the ordinary MarkdownTable uses. Crossing the structural
    /// complexity threshold (rows/cells/bytes) must not change whether a
    /// previously fitting table fits: with the real container width the
    /// shared layout engine's fit-or-shrink behavior applies identically in
    /// both presentations. It starts from the last width a table read;
    /// zero means "unknown yet" (first pass), and the cap-and-scroll
    /// fallback re-resolves a frame later.
    @State private var availableWidth: CGFloat = MarkdownTableWidthProbe.lastWidth
    /// Turned on from the long-press menu; kept until the row is taken down.
    @State private var selectionTurnedOn = false
    @Environment(\.markdownTablePlainCells) private var drawsPlainCells
    @Environment(\.markdownReferences) private var references
    @Environment(\.chatTextSize) private var chatTextSize

    private var selectsText: Bool { !drawsPlainCells || selectionTurnedOn }

    init(
        headers: [String],
        alignments: [MarkdownTableAlignment],
        rows: [[String]],
        foregroundStyle: Color,
        usesAccentSurface: Bool,
        selectionCoordinator: MarkdownSelectionCoordinator?,
        blockIndex: Int,
        selectionSegments: [MarkdownSelectionSegmentDescriptor]
    ) {
        self.headers = headers
        self.alignments = alignments
        self.rows = rows
        self.foregroundStyle = foregroundStyle
        self.usesAccentSurface = usesAccentSurface
        self.selectionCoordinator = selectionCoordinator
        self.blockIndex = blockIndex
        self.selectionSegments = selectionSegments
        // A table qualifies as large because of total estimated bytes — a
        // few rows with enormous cells also qualify, so the mounted count
        // must clamp to the actual row count from the start.
        _renderedRowCount = State(initialValue: min(LargeMarkdownTable.initialRowBatch, rows.count))
    }

    /// Rows whose cells feed the shared width measurement. Widths computed
    /// from a bounded prefix can differ from whole-table widths for wildly
    /// varying columns — a documented pathological-only tradeoff that keeps
    /// the expensive measurement bounded.
    static let widthSampleRows = 100
    static let initialRowBatch = 25
    static let rowBatch = 100

    private var columnWidths: [CGFloat] {
        let ceiling = MarkdownLargeDocumentPolicy.tableCellBytes
        return MarkdownTableLayout.columnWidths(
            headers: headers.map { MarkdownLargeDocumentPolicy.boundedDisplayText($0, maxBytes: ceiling) },
            rows: Array(rows.prefix(Self.widthSampleRows)).map {
                $0.map { MarkdownLargeDocumentPolicy.boundedDisplayText($0, maxBytes: ceiling) }
            },
            availableWidth: availableWidth,
            references: references,
            chatTextSize: chatTextSize
        )
    }

    /// Cell display text under the pathological-cell ceiling; keeps both
    /// width measurement and text layout bounded per cell.
    private func boundedCell(_ text: String) -> String {
        MarkdownLargeDocumentPolicy.boundedDisplayText(text, maxBytes: MarkdownLargeDocumentPolicy.tableCellBytes)
    }

    private func segmentDescriptor(row: Int, column: Int) -> MarkdownSelectionSegmentDescriptor? {
        let id = "block-\(blockIndex)-table-r\(row)-c\(column)"
        return selectionSegments.first { $0.id == id }
    }

    var body: some View {
        // One width computation per body evaluation — every mounted row and
        // the header share the same resolved (bounded) widths.
        let widths = columnWidths
        return VStack(spacing: 0) {
            MarkdownTableWidthProbe(width: $availableWidth)

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    MarkdownTableRowView(
                        cells: headers.map(boundedCell),
                        isHeader: true,
                        widths: widths,
                        alignments: alignments,
                        foregroundStyle: foregroundStyle,
                        usesAccentSurface: usesAccentSurface,
                        selectsText: selectsText,
                        selectionCoordinator: selectionCoordinator,
                        segmentFor: { segmentDescriptor(row: 0, column: $0) }
                    )
                    ForEach(0..<renderedRowCount, id: \.self) { rowOffset in
                        Divider().overlay(usesAccentSurface ? Color.white.opacity(0.22) : Color.secondary.opacity(0.18))
                        MarkdownTableRowView(
                            cells: rows[rowOffset].map(boundedCell),
                            isHeader: false,
                            widths: widths,
                            alignments: alignments,
                            foregroundStyle: foregroundStyle,
                            usesAccentSurface: usesAccentSurface,
                            selectsText: selectsText,
                            selectionCoordinator: selectionCoordinator,
                            segmentFor: { segmentDescriptor(row: rowOffset + 1, column: $0) }
                        )
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
            .modifier(MarkdownTableMenu(
                isOn: !selectsText,
                copyText: { [headers, rows, references] in
                    MarkdownTableLayout.plainText(headers: headers, rows: rows, references: references)
                },
                selectText: { selectionTurnedOn = true }
            ))
            if renderedRowCount < rows.count {
                Button {
                    renderedRowCount = min(renderedRowCount + Self.rowBatch, rows.count)
                } label: {
                    // The count drives its own plural; the progress is a separate string.
                    Label(AppLocalization.string("Show \(min(Self.rowBatch, rows.count - renderedRowCount)) more rows")
                        + " " + AppLocalization.string("(\(String(rows.count - renderedRowCount)) of \(String(rows.count)) left)"),
                        systemImage: "chevron.down")
                        .scaledFont(.caption.weight(.semibold))
                }
                .tint(usesAccentSurface ? .white : .conduitAccent)
                .padding(.vertical, 8)
            }
        }
    }
}

/// Fallback card for oversized math/Mermaid sources: the dedicated
/// renderers are not chunkable, so past the guard size the presentation is
/// a bounded source preview plus Copy (it is never drawn).
struct GuardedSourceCard: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let title: String
    let icon: String
    let source: String
    let guardBytes: Int

    @State private var copied = false
    @Environment(\.chatTextSize) private var chatTextSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: icon)
                    .scaledFont(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Too large to render")
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
            }
            SelectableTextView(
                text: String(source.prefix(2_000)),
                font: ChatTypography.font(for: .sourceCode, appearance: chatTextSize),
                textColor: .label,
                maximumNumberOfLines: 5
            )
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
                Label(copied ? AppLocalization.string("Copied") : AppLocalization.string("Copy full source"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    .scaledFont(.caption.weight(.semibold))
            }
            .tint(.conduitAccent)
        }
        .padding(12)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.secondary.opacity(0.20), lineWidth: 1)
        }
    }
}

private struct RemoteMarkdownImage: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let url: String
    let alt: String
    let gatewayMediaDataURL: ((String) async -> String?)?
    /// Scopes where a `MEDIA:` picture is kept on the phone; without one
    /// (a surface that sets no resolver) it is fetched each time.
    @Environment(\.gatewayMediaFiles) private var gatewayMediaFiles
    /// The chat's scroll engine, which says when a picture that will grow
    /// its row shows (#1238).
    @Environment(\.chatRowDisclosure) private var disclosure
    /// The row's frame, and the picture waiting to show in it.
    @StateObject private var arrival = ChatRowArrival()
    @State private var gatewayImage: UIImage?
    /// The cache key `gatewayImage` was loaded for, so a row kept across a
    /// dashboard or profile switch never shows the picture it held before.
    @State private var gatewayImageKey: String?
    /// The picture whose load failed (`loadIdentity`), so a row handed
    /// another picture never shows it as unavailable, and one loading the
    /// same picture again keeps its label meanwhile.
    @State private var gatewayFailedLoad: String?
    private var gatewayLoadFailed: Bool { gatewayFailedLoad == loadIdentity }
    /// A web picture, fetched and decoded within bounds; nil while loading.
    @State private var remoteOutcome: BoundedRemoteImage.Outcome?
    /// The address `remoteOutcome` is for: a row handed another picture
    /// never shows the one it held before.
    @State private var remoteOutcomeURL: String?
    /// The pictures around this one, which the viewer pages through.
    @Environment(\.imageGallery) private var imageGallery

    /// Shown at most 360 pt tall and a phone's width: twice that, at 3x,
    /// stays sharp.
    private static let remoteMaxPixelSize: CGFloat = 2048
    private static let maxHeight: CGFloat = 360

    private var isGatewayMedia: Bool { url.hasPrefix("MEDIA:") }
    private var gatewayCacheKey: String? {
        isGatewayMedia ? gatewayMediaFiles?.imageCacheKey(forMediaPath: gatewayPath) : nil
    }
    /// Which picture the row loads: its address, and for one from Hermes
    /// where it is kept, since another dashboard's same path is another
    /// picture.
    private var loadIdentity: String { "\(url)|\(gatewayCacheKey ?? "")" }
    /// A web picture's size is remembered under its address.
    private var remoteSizeKey: String { "web|\(url)" }

    /// A picture still in memory shows on the row's first frame, so a row
    /// scrolled back into view doesn't grow from its loading line (#1238).
    /// A row laid out with its loading line (another row of the same
    /// picture showed it since) takes it through the task, which asks the
    /// scroll engine.
    private var shownGatewayImage: UIImage? {
        let key = gatewayCacheKey
        if let gatewayImage, gatewayImageKey == key { return gatewayImage }
        guard let kept = key.flatMap(TranscriptPictureMemory.image(for:)),
              arrival.holds(rowHeight(showing: kept.size)) else { return nil }
        return kept
    }

    private var shownRemoteOutcome: BoundedRemoteImage.Outcome? {
        if let remoteOutcome, remoteOutcomeURL == url { return remoteOutcome }
        // A picture decoded already shows on the row's first frame, or where
        // the row has its height already (its size was remembered). One that
        // would grow the row waits for the task, which asks the scroll
        // engine (#1238).
        guard !isGatewayMedia, let remoteURL = URL(string: url),
              let cached = BoundedRemoteImage.cachedImage(remoteURL, maxPixelSize: Self.remoteMaxPixelSize),
              arrival.holds(rowHeight(showing: cached.size)) else { return nil }
        return .image(cached)
    }

    /// The size the picture will take, when it's known before it loads.
    private var reservedSize: CGSize? {
        if let gatewayCacheKey { return TranscriptPictureMemory.size(for: gatewayCacheKey) }
        return isGatewayMedia ? nil : TranscriptPictureMemory.size(for: remoteSizeKey)
    }
    private var gatewayPath: String {
        String(url.dropFirst("MEDIA:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Non-image gateway media (video, audio, documents) renders as a card
    /// and is only fetched when opened, so scrolling past a video never
    /// downloads it.
    private var gatewayFileKind: GatewayMediaKind? {
        guard isGatewayMedia else { return nil }
        let kind = GatewayMediaKind(path: gatewayPath)
        return kind == .image ? nil : kind
    }

    var body: some View {
        Group {
            if let gatewayFileKind {
                GatewayMediaFileCard(
                    path: gatewayPath,
                    name: alt,
                    kind: gatewayFileKind,
                    gatewayMediaDataURL: gatewayMediaDataURL
                )
            } else if isGatewayMedia {
                gatewayMediaContent
            } else {
            switch shownRemoteOutcome {
            case .image(let image):
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: Self.maxHeight).clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .opensMediaPreview { openImage(showing: image) }
                    .accessibilityLabel(alt.isEmpty ? Text("Image") : Text(verbatim: alt))
            case .unavailable:
                WebFallbackImage(url: url, alt: alt, arrival: arrival, engine: disclosure?.engine)
            case .tooLarge:
                WebFallbackImage(url: url, alt: alt, loadsInPage: false, arrival: arrival, engine: disclosure?.engine)
            case nil:
                loadingLabel
            }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatRowFrame(arrival)
        .onDisappear {
            // A picture still waiting to show is dropped with the row; the
            // task loads it again when the row is back.
            arrival.rowDisappeared()
        }
        // Handed another picture: whatever still waits was the last one's.
        .onChange(of: loadIdentity) { arrival.rowDisappeared() }
        .task(id: loadIdentity) {
            guard isGatewayMedia else {
                // An outcome for another address goes; this one's stays
                // while it loads again (the task restarting as the row
                // comes back), so the row doesn't flash its loading line.
                if remoteOutcomeURL != url {
                    remoteOutcomeURL = url
                    remoteOutcome = nil
                }
                // A URL that isn't RFC-valid goes to the web view, which
                // escapes it.
                guard let remoteURL = URL(string: url) else {
                    placeRemoteFailure(.unavailable)
                    return
                }
                if let cached = BoundedRemoteImage.cachedImage(remoteURL, maxPixelSize: Self.remoteMaxPixelSize) {
                    placeRemoteImage(cached, generation: TranscriptImageCache.generation, fades: false)
                    return
                }
                let started = TranscriptImageCache.generation
                let outcome = await BoundedRemoteImage.load(remoteURL, maxPixelSize: Self.remoteMaxPixelSize)
                guard !Task.isCancelled else { return }
                guard case .image(let image) = outcome else {
                    placeRemoteFailure(outcome)
                    return
                }
                placeRemoteImage(image, generation: started, fades: true)
                return
            }
            guard gatewayFileKind == nil else { return }
            let cacheKey = gatewayCacheKey
            // Still in memory: in the row since its first frame, or, shown
            // since by another row of it, arriving like a load.
            if let cacheKey, let kept = TranscriptPictureMemory.image(for: cacheKey) {
                placeGatewayImage(kept, for: cacheKey, generation: TranscriptImageCache.generation)
                return
            }
            // One that failed keeps its label while it loads again.
            gatewayImage = nil
            gatewayImageKey = nil
            let maxPixelSize = Self.remoteMaxPixelSize
            // Kept on the phone from an earlier load: no request, and the
            // read and decode stay off the main thread. After a sign-out
            // it shows, but isn't remembered.
            let keptGeneration = TranscriptImageCache.generation
            if let cacheKey, let kept = await Self.keptGatewayImage(cacheKey, maxPixelSize: maxPixelSize) {
                guard !Task.isCancelled else { return }
                placeGatewayImage(kept, for: cacheKey, generation: keptGeneration)
                return
            }
            guard !Task.isCancelled else { return }
            // Read first: a sign-out during the fetch keeps it off the phone.
            let generation = TranscriptImageCache.generation
            guard let gatewayMediaDataURL, !gatewayPath.isEmpty,
                  let dataURL = await gatewayMediaDataURL(gatewayPath),
                  !Task.isCancelled else {
                guard !Task.isCancelled else { return }
                placeGatewayFailure()
                return
            }
            // The data URL (up to 16 MB of base64) is decoded, kept and
            // downsampled off the main thread, within the same pixel bound.
            let decoded = await Task.detached(priority: .userInitiated) { () -> BoundedRemoteImage.Outcome in
                guard let data = DataURLLimits.decodeBase64DataURL(dataURL, prefix: "data:image/") else { return .unavailable }
                let outcome = BoundedRemoteImage.decode(data, maxPixelSize: maxPixelSize)
                if let cacheKey, case .image = outcome {
                    TranscriptImageCache.store(
                        data,
                        fileExtension: TranscriptImageCache.fileExtension(forDataURL: dataURL),
                        for: cacheKey,
                        generation: generation
                    )
                }
                return outcome
            }.value
            guard !Task.isCancelled else { return }
            guard case .image(let image) = decoded else {
                placeGatewayFailure()
                return
            }
            placeGatewayImage(image, for: cacheKey, generation: generation)
        }
    }

    /// Puts a picture from Hermes in the row once the reader's scrolling
    /// allows (ChatRowArrival), remembering it then: remembered first,
    /// its size would resize the loading line on its own. After a sign-out
    /// it shows, but isn't remembered.
    private func placeGatewayImage(_ image: UIImage, for cacheKey: String?, generation: Int) {
        arrival.arrive(rowHeight: rowHeight(showing: image.size), engine: disclosure?.engine) {
            if let cacheKey, generation == TranscriptImageCache.generation {
                TranscriptPictureMemory.remember(image, for: cacheKey)
            }
            gatewayImage = image
            gatewayImageKey = cacheKey
        }
    }

    /// Puts a web picture in the row the same way, its size remembered as
    /// it shows. Outside a chat a fresh load fades in; in a chat it lands
    /// in one pass, which the engine makes good above the reader.
    private func placeRemoteImage(_ image: UIImage, generation: Int, fades: Bool) {
        let engine = disclosure?.engine
        let sizeKey = remoteSizeKey
        let placedURL = url
        arrival.arrive(rowHeight: rowHeight(showing: image.size), engine: engine) {
            // The row moved on to another address while this one waited.
            guard remoteOutcomeURL == placedURL else { return }
            if generation == TranscriptImageCache.generation {
                TranscriptPictureMemory.rememberSize(image.size, for: sizeKey)
            }
            if fades, engine == nil {
                withAnimation(.easeInOut(duration: 0.2)) { remoteOutcome = .image(image) }
            } else {
                remoteOutcome = .image(image)
            }
        }
    }

    /// A picture from Hermes that won't load gives its place to its label
    /// the same way, a height only the label's layout tells.
    private func placeGatewayFailure() {
        let failedLoad = loadIdentity
        // Its label shows already (the task restarting as the row comes back).
        guard gatewayFailedLoad != failedLoad else { return }
        arrival.arrive(rowHeight: nil, engine: disclosure?.engine) {
            gatewayFailedLoad = failedLoad
        }
    }

    /// A web picture that won't show here gives its place to its fallback
    /// the same way: the page that tries it, at its starting height, or the
    /// link, which only its layout measures. Outside a chat it fades in.
    private func placeRemoteFailure(_ outcome: BoundedRemoteImage.Outcome) {
        guard !showsFallback(for: outcome) else { return }
        let engine = disclosure?.engine
        let placedURL = url
        var rowHeight: CGFloat?
        if case .unavailable = outcome { rowHeight = WebFallbackImage.startingHeight }
        arrival.arrive(rowHeight: rowHeight, engine: engine) {
            // The row moved on to another address while this one waited.
            guard remoteOutcomeURL == placedURL else { return }
            if engine == nil {
                withAnimation(.easeInOut(duration: 0.2)) { remoteOutcome = outcome }
            } else {
                remoteOutcome = outcome
            }
        }
    }

    /// Whether the row shows `outcome`'s fallback for its address already
    /// (the task restarting as the row comes back).
    private func showsFallback(for outcome: BoundedRemoteImage.Outcome) -> Bool {
        guard remoteOutcomeURL == url else { return false }
        switch (remoteOutcome, outcome) {
        case (.unavailable?, .unavailable), (.tooLarge?, .tooLarge): return true
        default: return false
        }
    }

    /// The height the row takes with a picture of `size` in it: scaled to
    /// the row's width, up to the ceiling, which a placeholder at the
    /// remembered size already has. The arrival compares it with the row's
    /// frame, since a row laid out before a cold launch's kept sizes loaded
    /// still draws its loading line.
    private func rowHeight(showing size: CGSize) -> CGFloat {
        ChatRowArrival.fittedHeight(of: size, inWidth: arrival.stackFrame?.width ?? 0, maxHeight: Self.maxHeight)
    }

    @ViewBuilder
    private var gatewayMediaContent: some View {
        if let gatewayImage = shownGatewayImage {
            Image(uiImage: gatewayImage)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: Self.maxHeight)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .opensMediaPreview { openImage(showing: gatewayImage) }
                .accessibilityLabel(alt.isEmpty ? Text("Image") : Text(verbatim: alt))
        } else if gatewayLoadFailed {
            Label(alt.isEmpty ? AppLocalization.string("Image unavailable") : AppLocalization.string("\(alt) unavailable"), systemImage: "photo.badge.exclamationmark")
                .scaledFont(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        } else {
            loadingLabel
        }
    }

    /// At the picture's own size when that's known, so the row doesn't
    /// change height when it arrives: known as the row was first laid out,
    /// since a size remembered after (another row of the same picture, or
    /// a cold launch's kept sizes loading) would resize the line on its own.
    @ViewBuilder
    private var loadingLabel: some View {
        let label = HStack(spacing: 8) {
            ProgressView()
            Text(alt.isEmpty ? AppLocalization.string("Loading image…") : alt)
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
        }
        if let size = reservedSize, arrival.holds(rowHeight(showing: size)) {
            Color.primary.opacity(0.05)
                .aspectRatio(size, contentMode: .fit)
                .frame(maxHeight: Self.maxHeight)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay { label.padding(12) }
        } else {
            label.padding(12)
        }
    }

    /// The picture kept on the phone under `key`, read and downsampled off
    /// the main thread.
    private static func keptGatewayImage(_ key: String, maxPixelSize: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let file = TranscriptImageCache.cachedFile(for: key, touch: true),
                  let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                  case .image(let image) = BoundedRemoteImage.decode(data, maxPixelSize: maxPixelSize) else { return nil }
            return image
        }.value
    }

    /// Opens the original among the pictures around it, with the row's
    /// copy shown until it's in. The row keeps only the decoded image, not
    /// the original bytes (up to 16 MB each across a whole transcript), so
    /// opening re-fetches them: from the copy kept on the phone, which stays
    /// after Hermes sweeps its own, else from Hermes; a web picture again
    /// (usually from URLCache) to share it at full quality.
    private func openImage(showing image: UIImage) {
        guard let item = ImageGalleryItem.markdownImage(url: url, alt: alt, resolver: gatewayMediaFiles,
                                                        dataURL: gatewayMediaDataURL) else { return }
        ImageGallery.open(item, in: imageGallery, placeholder: image)
    }
}

/// Inline card for a gateway video, audio clip or document. Tapping fetches
/// the file through the authenticated dashboard and opens it full screen.
private struct GatewayMediaFileCard: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let path: String
    let name: String
    let kind: GatewayMediaKind
    let gatewayMediaDataURL: ((String) async -> String?)?
    @Environment(\.gatewayMediaFiles) private var gatewayMediaFiles
    @State private var loading = false
    @State private var failed = false
    @State private var tooLarge = false
    @State private var openTask: Task<Void, Never>?

    var body: some View {
        Group {
            if kind == .audio {
                // Audio plays in place (#439); expand still opens Quick Look.
                InlineAudioClipView(
                    id: "MEDIA:\(path)",
                    name: displayName,
                    filename: path,
                    style: .card,
                    opening: loading,
                    openFailed: failed,
                    load: loadAudio,
                    openFull: open
                )
            } else {
                fileCard
            }
        }
        .onDisappear {
            openTask?.cancel()
            openTask = nil
            loading = false
        }
    }

    private var fileCard: some View {
        HStack(spacing: 12) {
            Image(systemName: failed ? "exclamationmark.triangle.fill" : kind.systemImage)
                .scaledFont(.title2)
                .foregroundStyle(failed ? Color.secondary : Color.conduitAccent)
                .frame(width: 44, height: 44)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: displayName)
                    .scaledFont(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: failed ? failureLabel : kind.label)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if loading {
                ProgressView()
            } else {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .scaledFont(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: 360, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .opensMediaPreview(open)
    }

    private var displayName: String {
        name.isEmpty ? MediaPreviewPresenter.sanitizedFilename(path) : name
    }

    private var failureLabel: String {
        tooLarge
            ? AppLocalization.string("Too large to open on this phone")
            : AppLocalization.string("Couldn't open this file")
    }

    /// The clip's bytes for inline playback, read or decoded off the main
    /// actor. The player holds them in memory, so a clip over
    /// `maxInlineAudioBytes` only opens full screen.
    private func loadAudio() async -> Data? {
        if let gatewayMediaFiles {
            switch await gatewayMediaFiles.file(for: path, maxBytes: DashboardFileDownloadLimits.maxInlineAudioBytes) {
            case .downloaded(let download):
                return await Task.detached(priority: .userInitiated) {
                    defer { MediaPreviewPresenter.removeDirectory(download.directory) }
                    return try? Data(contentsOf: download.file)
                }.value
            case .tooLarge:
                return nil
            case .unavailable:
                break
            }
        }
        // A cancelled download reads as unavailable; don't start the
        // fallback for a card that has gone.
        guard !Task.isCancelled, let gatewayMediaDataURL,
              let dataURL = await gatewayMediaDataURL(path), !Task.isCancelled else { return nil }
        return await Task.detached(priority: .userInitiated) {
            DataURLLimits.decodeBase64DataURL(dataURL)
        }.value
    }

    private enum OpenOutcome {
        case presented
        case tooLarge
        case failed
    }

    private func open() {
        guard !loading, gatewayMediaFiles != nil || gatewayMediaDataURL != nil else { return }
        loading = true
        failed = false
        tooLarge = false
        // Cancelled on disappear, so a slow fetch can't pop a preview over
        // whatever screen the user moved on to.
        openTask = Task {
            let outcome = await fetchAndPresent()
            guard !Task.isCancelled else { return }
            loading = false
            failed = outcome != .presented
            tooLarge = outcome == .tooLarge
            openTask = nil
        }
    }

    /// The file itself, downloaded to disk, so a video over the 16 MB data
    /// URL ceiling still opens (#569); the data URL when the download is
    /// unavailable (an older Hermes, or no sign-in yet).
    private func fetchAndPresent() async -> OpenOutcome {
        if let gatewayMediaFiles {
            switch await gatewayMediaFiles.file(for: path) {
            case .downloaded(let download):
                return MediaPreviewPresenter.shared.present(downloaded: download) ? .presented : .failed
            case .tooLarge:
                return .tooLarge
            case .unavailable:
                break
            }
        }
        guard !Task.isCancelled, let gatewayMediaDataURL,
              let dataURL = await gatewayMediaDataURL(path), !Task.isCancelled else { return .failed }
        return await MediaPreviewPresenter.shared.present(dataURL: dataURL, filename: path) ? .presented : .failed
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
            return alt.isEmpty ? AppLocalization.string("Open image") : AppLocalization.string("\(alt) — image unavailable; open source")
        }
        return alt.isEmpty ? AppLocalization.string("Image unavailable") : AppLocalization.string("\(alt) unavailable")
    }
}

private struct WebFallbackImage: View {
    let url: String
    let alt: String
    /// False for a picture too large to load here: just the link.
    var loadsInPage = true
    /// The row's arrival, which what the page reports goes through, as the
    /// picture would have (#1238).
    let arrival: ChatRowArrival
    /// The chat's scroll engine, nil outside a chat.
    let engine: ChatScrollEngine?
    /// The page's height before it has measured the picture.
    static let startingHeight: CGFloat = 220
    @State private var height: CGFloat = WebFallbackImage.startingHeight
    @State private var failed = false
    /// What the page last reported, kept until the row takes it: a row
    /// that left the screen first takes it when it's back, since the page
    /// doesn't report again.
    @State private var reported: PageReport? = nil

    enum PageReport {
        case height(CGFloat)
        case failed
    }

    var body: some View {
        Group {
            if failed || !loadsInPage {
                // A model-authored URL is not guaranteed to be RFC-valid
                // (unencoded non-ASCII paths are common); force-unwrapping
                // here crashed the app on exactly the images most likely to
                // reach this fallback.
                fallbackLabel
                    .padding(12)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            } else {
                RemoteImageWebView(url: url, height: measuredHeight, failed: pageFailed)
                    .frame(height: Self.shownHeight(height))
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
        }
        .onAppear {
            if let reported { take(reported) }
        }
    }

    private static func shownHeight(_ height: CGFloat) -> CGFloat {
        min(max(height, 80), 420)
    }

    /// The page measured the picture.
    private var measuredHeight: Binding<CGFloat> {
        Binding(get: { height }, set: { measured in
            // Web view callbacks arrive on the main thread; said so,
            // whatever isolation the SDK gives this closure.
            MainActor.assumeIsolated { take(.height(measured)) }
        })
    }

    /// The page couldn't show it either.
    private var pageFailed: Binding<Bool> {
        Binding(get: { failed }, set: { didFail in
            MainActor.assumeIsolated {
                if didFail { take(.failed) }
            }
        })
    }

    /// The row takes what the page reported once the reader's scrolling
    /// allows: the picture's height, or the link, a height only its layout
    /// tells.
    private func take(_ report: PageReport) {
        reported = report
        guard !failed else { return }
        switch report {
        case .height(let measured):
            guard measured != height else { return }
            arrival.arrive(rowHeight: Self.shownHeight(measured), engine: engine) { height = measured }
        case .failed:
            arrival.arrive(rowHeight: nil, engine: engine) { failed = true }
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
                .scaledFont(.footnote.weight(.semibold))
            }
                .tint(.conduitAccent)
        } else {
            Label(
                WebFallbackImageLabel.title(alt: alt, destinationAvailable: false),
                systemImage: "photo.badge.exclamationmark"
            )
                .scaledFont(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

struct RemoteImageWebView: UIViewRepresentable {
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

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
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
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let source: String
    var language: String = ""
    var usesAccentSurface = false
    var selectionCoordinator: MarkdownSelectionCoordinator?
    var selectionSegment: MarkdownSelectionSegmentDescriptor?
    @State private var copied = false
    @Environment(\.chatTextSize) private var chatTextSize

    /// Code content scales with the chat text size (issue #85); the
    /// language label and Copy button above stay interface chrome.
    private var codeFont: UIFont {
        ChatTypography.font(for: .blockCode, appearance: chatTextSize)
    }

    private var normalizedLanguage: String { MarkdownLanguage.normalized(language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(normalizedLanguage == "plain" ? AppLocalization.string("Code") : normalizedLanguage)
                    .scaledFont(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(usesAccentSurface ? Color.white.opacity(0.86) : .secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = source
                    Haptics.light()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    Label(copied ? AppLocalization.string("Copied") : AppLocalization.string("Copy"), systemImage: copied ? "checkmark" : "doc.on.doc").scaledFont(.caption2.weight(.semibold))
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
                            font: codeFont,
                            textColor: UIColor.white.withAlphaComponent(0.96),
                            lineSpacing: 3,
                            wrapsLines: false,
                            selectionCoordinator: selectionCoordinator,
                            selectionSegment: selectionSegment
                        )
                    } else {
                        SelectableTextView(
                            attributedText: SyntaxHighlighter.highlight(source, language: normalizedLanguage),
                            font: codeFont,
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

enum MarkdownParser {
    #if DEBUG
    /// Test instrumentation: sizes (utf8 bytes) of every source handed to
    /// `parseDocument`. Lets regression tests assert that pathological
    /// streaming/rendering paths never re-parse the whole document per frame
    /// — a bound on work, not a fragile wall-clock threshold. Lock-guarded
    /// because `parseDocument` runs on the MainActor (rendering) and inside
    /// off-main preparation passes concurrently.
    private static let parseSizeLock = NSLock()
    private nonisolated(unsafe) static var parseSizes: [Int] = []

    nonisolated(unsafe) static var parseSourceSizes: [Int] {
        get {
            parseSizeLock.lock()
            defer { parseSizeLock.unlock() }
            return parseSizes
        }
        set {
            parseSizeLock.lock()
            defer { parseSizeLock.unlock() }
            parseSizes = newValue
        }
    }

    nonisolated private static func recordParseSize(_ bytes: Int) {
        parseSizeLock.lock()
        defer { parseSizeLock.unlock() }
        parseSizes.append(bytes)
    }
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
        recordParseSize(source.utf8.count)
        #endif
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var visibleLines: [String] = []
        var definitions: [String] = []
        var openFence: MarkdownFence?
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
                if fence.closes(trimmed) { openFence = nil }
                index += 1
                continue
            }
            if let fence = MarkdownFence.opening(trimmed) {
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
            // Hermes' `@session:<id>` chat references open the chat.
            visibleLines.append(HermesSessionReference.linkingMarkdown(line))
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

            if let fence = MarkdownFence.opening(trimmed) {
                let language = String(trimmed.dropFirst(fence.length)).trimmingCharacters(in: .whitespaces)
                index += 1
                var code: [String] = []
                while index < lines.count, !fence.closes(lines[index].trimmingCharacters(in: .whitespaces)) { code.append(lines[index]); index += 1 }
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

            // `::preview{file="…"}` asks for a host HTML file drawn in
            // place; any other file gets its card, as a MEDIA: tag would. A
            // Desktop plugin's directive gets its card on every surface
            // (#1522). A quoted one is an example, as with MEDIA: tags.
            if !isTableHeader(lines, at: index), let segments = directiveSegments(in: trimmed, recognizesGatewayMedia: recognizesGatewayMedia) {
                for segment in segments {
                    switch segment {
                    case .preview(let file) where recognizesGatewayMedia:
                        blocks.append(TranscriptDirectives.isHTML(file)
                            ? .htmlPreview(path: file)
                            : .image(url: "MEDIA: \(file)", alt: mediaName(file)))
                    case .preview(let file):
                        // No host to read it from: the directive stays text.
                        blocks.append(.paragraph("::preview{file=\"\(file)\"}"))
                    case .desktopCard(let card):
                        blocks.append(.desktopCard(card))
                    case .text(let text):
                        // The text holds no directives any more, so this
                        // cannot come back to this branch.
                        blocks.append(contentsOf: parseBlocks([text], recognizesGatewayMedia: recognizesGatewayMedia))
                    }
                }
                index += 1
                continue
            }

            // A line holding `MEDIA:` tags splits into media and the text
            // around them (#439); a line of only Hermes directives drops.
            if recognizesGatewayMedia, !isTableHeader(lines, at: index), let segments = GatewayMediaTags.segments(in: trimmed) {
                for segment in segments {
                    switch segment {
                    case .media(let mediaPath, let alt):
                        blocks.append(.image(url: "MEDIA: \(mediaPath)", alt: alt ?? mediaName(mediaPath)))
                    case .text(let text):
                        // The text carries no tags any more, so this cannot
                        // recurse back into this branch.
                        blocks.append(contentsOf: parseBlocks([text], recognizesGatewayMedia: false))
                    }
                }
                index += 1
                continue
            }
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
                let start = orderedNumber(trimmed)
                var items: [String] = []
                while index < lines.count, let item = orderedItem(lines[index].trimmingCharacters(in: .whitespaces)) {
                    let itemLine = lines[index]
                    items.append(item); index += 1
                    // Blank lines between items make a loose list, not a
                    // new one (#1163): the list goes on when the next line
                    // after them is an item with the same indent and
                    // delimiter as the last one, so it numbers 1, 2, 3 and
                    // not 1, 1, 1. A table, MEDIA: tag or preview still
                    // wins, as it does above.
                    var next = index
                    while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
                    if next > index, next < lines.count, continuesOrderedList(lines[next], from: itemLine), !isTableHeader(lines, at: next), !(recognizesGatewayMedia && claimsGatewayMedia(lines[next])), directiveSegments(in: lines[next].trimmingCharacters(in: .whitespaces), recognizesGatewayMedia: false) == nil { index = next }
                }
                blocks.append(.orderedList(items, start: start))
                continue
            }

            var paragraph = [line]
            index += 1
            while index < lines.count {
                let candidate = lines[index]
                let next = candidate.trimmingCharacters(in: .whitespaces)
                if next.isEmpty || MarkdownFence.opening(next) != nil || mathBlockOpening(next) != nil || singleLineMath(next) != nil || directiveStart(next) != nil || (recognizesGatewayMedia && GatewayMediaTags.segments(in: next) != nil) || directiveSegments(in: next, recognizesGatewayMedia: recognizesGatewayMedia) != nil || imageMarkdown(next) != nil || directImageURL(next) != nil || isDivider(next) || heading(next) != nil || next.hasPrefix(">") || unorderedItem(next) != nil || orderedItem(next) != nil || isTableHeader(lines, at: index) { break }
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
    /// The path when `value` is a line holding exactly one `MEDIA:` tag.
    static func gatewayMediaPath(_ value: String) -> String? {
        GatewayMediaTags.soleMediaPath(value)
    }
    static func mediaName(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? AppLocalization.string("Image")
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
        // CommonMark: one to nine ASCII digits, so anything else is text.
        guard let range = value.range(of: #"^[0-9]{1,9}[.)]\s+"#, options: .regularExpression) else { return nil }
        return String(value[range.upperBound...])
    }
    /// The number an ordered item is written with.
    private static func orderedNumber(_ value: String) -> Int {
        Int(value.prefix { $0.isASCII && $0.isNumber }) ?? 1
    }
    /// Whether `line` carries on the ordered list after its item `previous`:
    /// the same leading whitespace and the same "." or ")" after the number.
    private static func continuesOrderedList(_ line: String, from previous: String) -> Bool {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        guard indent == previous.prefix(while: { $0 == " " || $0 == "\t" }) else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard orderedItem(trimmed) != nil else { return false }
        return orderedDelimiter(trimmed) == orderedDelimiter(previous.trimmingCharacters(in: .whitespaces))
    }
    /// A line's transcript directives as `parseBlocks` takes them: previews
    /// only with a host to read them from, Desktop cards everywhere, and
    /// never in a quote (an example).
    private static func directiveSegments(in trimmed: String, recognizesGatewayMedia: Bool) -> [TranscriptDirectives.Segment]? {
        guard !trimmed.hasPrefix(">"), let segments = TranscriptDirectives.segments(in: trimmed) else { return nil }
        if recognizesGatewayMedia { return segments }
        return segments.contains { if case .desktopCard = $0 { return true } else { return false } } ? segments : nil
    }
    /// Whether the gateway-media branches of `parseBlocks` take `line`.
    private static func claimsGatewayMedia(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return GatewayMediaTags.segments(in: trimmed) != nil
            || (!trimmed.hasPrefix(">") && TranscriptDirectives.segments(in: trimmed) != nil)
    }
    private static func orderedDelimiter(_ value: String) -> Character? {
        value.first { !$0.isNumber }
    }
    static func isTableHeader(_ lines: [String], at index: Int) -> Bool {
        TranscriptDirectives.isTableHeader(lines, at: index)
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

    /// NOTE: deliberately NOT keyed on the chat text size (issue #85): the
    /// tokenizer bakes colors only — fonts are applied when the result is
    /// bridged into an NSAttributedString with a caller-supplied default
    /// font — so one highlighted value serves every typography.
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
