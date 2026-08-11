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

    var body: some View {
        let rendering = MarkdownRenderCache.rendering(
            source: source,
            recognizesGatewayMedia: gatewayMediaDataURL != nil,
            foregroundStyle: foregroundStyle,
            usesAccentSurface: usesAccentSurface
        )

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
                            foregroundStyle: foregroundStyle,
                            usesAccentSurface: usesAccentSurface,
                            gatewayMediaDataURL: gatewayMediaDataURL,
                            newestCharacterOpacities: index == rendering.blocks.count - 1
                                ? newestCharacterOpacities
                                : []
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One render's parsed blocks plus the prebuilt selectable string (nil when
/// the blocks need the full block-view path). A class so NSCache can hold it.
private final class MarkdownRendering {
    let blocks: [MarkdownBlock]
    let selectableText: NSAttributedString?

    init(blocks: [MarkdownBlock], selectableText: NSAttributedString?) {
        self.blocks = blocks
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
        return cache
    }()

    static func rendering(
        source: String,
        recognizesGatewayMedia: Bool,
        foregroundStyle: Color,
        usesAccentSurface: Bool
    ) -> MarkdownRendering {
        // Fonts resolve against the current Dynamic Type size, so a size
        // change must miss the cache rather than serve stale metrics.
        let key = [
            recognizesGatewayMedia ? "1" : "0",
            usesAccentSurface ? "1" : "0",
            String(describing: foregroundStyle),
            UIApplication.shared.preferredContentSizeCategory.rawValue,
            source
        ].joined(separator: "|") as NSString

        if let cached = cache.object(forKey: key) { return cached }
        let blocks = MarkdownParser.parse(source, recognizesGatewayMedia: recognizesGatewayMedia)
        let rendering = MarkdownRendering(
            blocks: blocks,
            selectableText: MarkdownSelectionFormatter.attributedText(
                for: blocks,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                newestCharacterOpacities: []
            )
        )
        cache.setObject(rendering, forKey: key)
        return rendering
    }
}

enum MarkdownBlock {
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

struct MarkdownQuoteLine {
    let depth: Int
    let text: String
}

enum MarkdownSelectionFormatter {
    static func attributedText(
        for blocks: [MarkdownBlock],
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
                font: headingFont(level),
                textColor: textColor,
                linkColor: linkColor
            )

        case .paragraph(let text):
            return inline(text, font: bodyFont, textColor: textColor, linkColor: linkColor)

        case .unorderedList(let items):
            return list(
                items,
                ordered: false,
                bodyFont: bodyFont,
                textColor: textColor,
                linkColor: linkColor,
                markerColor: usesAccentSurface ? .white : UIColor(Color.conduitAccent)
            )

        case .orderedList(let items):
            return list(
                items,
                ordered: true,
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
                result.append(inline(line.text, font: quoteFont, textColor: quoteColor, linkColor: linkColor))
            }
            return result

        default:
            return nil
        }
    }

    private static func list(
        _ items: [String],
        ordered: Bool,
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
                font: bodyFont,
                textColor: textColor,
                linkColor: linkColor
            ))
        }
        return result
    }

    private static func inline(
        _ source: String,
        font: UIFont,
        textColor: UIColor,
        linkColor: UIColor
    ) -> NSAttributedString {
        let attributed = (try? AttributedString(
            markdown: source,
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

private extension MarkdownBlock {
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

    var swiftUI: Alignment {
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
    static func font(for level: Int) -> UIFont {
        switch level {
        case 1: UIFont.preferredFont(forTextStyle: .title2).withTraits(.traitBold)
        case 2: UIFont.preferredFont(forTextStyle: .title3).withTraits(.traitBold)
        case 3: UIFont.preferredFont(forTextStyle: .headline).withTraits(.traitBold)
        default: UIFont.preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let foregroundStyle: Color
    let usesAccentSurface: Bool
    let gatewayMediaDataURL: ((String) async -> String?)?
    let newestCharacterOpacities: [Double]

    var body: some View {
        switch block {
        case .heading(let level, let text):
            InlineMarkdown(
                source: text,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                font: headingFont(level),
                trailingCharacterOpacities: newestCharacterOpacities
            )
                .padding(.top, level <= 2 ? 6 : 2)

        case .paragraph(let text):
            InlineMarkdown(
                source: text,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                lineSpacing: 4,
                trailingCharacterOpacities: newestCharacterOpacities
            )

        case .quote(let lines):
            MarkdownQuote(
                lines: lines,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                trailingCharacterOpacities: newestCharacterOpacities
            )

        case .unorderedList(let items):
            MarkdownList(
                items: items,
                ordered: false,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                trailingCharacterOpacities: newestCharacterOpacities
            )

        case .orderedList(let items):
            MarkdownList(
                items: items,
                ordered: true,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                trailingCharacterOpacities: newestCharacterOpacities
            )

        case .table(let headers, let alignments, let rows):
            MarkdownTable(
                headers: headers,
                alignments: alignments,
                rows: rows,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface
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
                trailingCharacterOpacities: newestCharacterOpacities
            )

        case .columns(let columns):
            MarkdownColumns(
                columns: columns,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                trailingCharacterOpacities: newestCharacterOpacities
            )

        case .code(let language, let source):
            if MarkdownLanguage.normalized(language) == "mermaid" {
                MermaidBlock(source: source)
            } else {
                ChatCodeBlock(source: source, language: language, usesAccentSurface: usesAccentSurface)
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
}

private struct InlineMarkdown: View {
    let source: String
    let foregroundStyle: Color
    let usesAccentSurface: Bool
    var font: UIFont = .preferredFont(forTextStyle: .body)
    var lineSpacing: CGFloat = 0
    var maximumNumberOfLines: Int = 0
    var trailingCharacterOpacities: [Double] = []

    private var attributed: AttributedString {
        var attributed = (try? AttributedString(
            markdown: source,
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

    var body: some View {
        SelectableTextView(
            attributedText: attributed,
            font: font,
            textColor: usesAccentSurface ? .white : UIColor(foregroundStyle),
            lineSpacing: lineSpacing,
            maximumNumberOfLines: maximumNumberOfLines,
            linkColor: usesAccentSurface ? .white : .link
        )
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownList: View {
    let items: [String]
    let ordered: Bool
    let foregroundStyle: Color
    let usesAccentSurface: Bool
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
    var trailingCharacterOpacities: [Double] = []

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                InlineMarkdown(
                    source: column,
                    foregroundStyle: foregroundStyle,
                    usesAccentSurface: usesAccentSurface,
                    lineSpacing: 3,
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

private struct MarkdownTable: View {
    let headers: [String]
    let alignments: [MarkdownTableAlignment]
    let rows: [[String]]
    let foregroundStyle: Color
    let usesAccentSurface: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(headers, isHeader: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider().overlay(usesAccentSurface ? Color.white.opacity(0.22) : Color.secondary.opacity(0.18))
                    tableRow(row, isHeader: false)
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

    private func tableRow(_ cells: [String], isHeader: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                InlineMarkdown(
                    source: cell,
                    foregroundStyle: foregroundStyle,
                    usesAccentSurface: usesAccentSurface,
                    font: isHeader
                        ? UIFont.preferredFont(forTextStyle: .caption1).withTraits(.traitBold)
                        : UIFont.preferredFont(forTextStyle: .footnote),
                    maximumNumberOfLines: 4
                )
                    .frame(minWidth: 112, maxWidth: 220, alignment: alignment(at: index).swiftUI)
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

/// AsyncImage is fast for ordinary HTTPS hosts. Some image CDNs reject its
/// URLSession user agent or redirect to HTTP; WebKit follows the same browser
/// path as the source link, but is isolated to this image-only fallback.
private struct WebFallbackImage: View {
    let url: String
    let alt: String
    @State private var height: CGFloat = 220
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                Link(destination: URL(string: url)!) {
                    Label(alt.isEmpty ? "Open image" : "Image unavailable — open source", systemImage: "photo.badge.exclamationmark")
                        .font(.footnote.weight(.semibold))
                }
                .tint(.conduitAccent)
                .padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            } else {
                RemoteImageWebView(url: url, height: $height, failed: $failed)
                    .frame(height: min(max(height, 80), 420))
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
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
                            wrapsLines: false
                        )
                    } else {
                        SelectableTextView(
                            attributedText: SyntaxHighlighter.highlight(source, language: normalizedLanguage),
                            font: .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular),
                            textColor: .label,
                            lineSpacing: 3,
                            wrapsLines: false
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
    static func parse(_ source: String, recognizesGatewayMedia: Bool = false) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
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
        return blocks.isEmpty && !source.isEmpty ? [.paragraph(source)] : blocks
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

private enum MarkdownLanguage {
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

private enum SyntaxHighlighter {
    /// Settled code blocks across the transcript re-render at streaming frame
    /// rate; tokenizing is linear but allocation-heavy, so memoize by content.
    /// Only the still-growing streaming block misses per frame.
    private static let cache: NSCache<NSString, HighlightedCode> = {
        let cache = NSCache<NSString, HighlightedCode>()
        cache.countLimit = 128
        return cache
    }()

    static func highlight(_ source: String, language: String) -> AttributedString {
        let key = "\(language)|\(source)" as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        let highlighted = tokenize(source, language: language)
        cache.setObject(HighlightedCode(highlighted), forKey: key)
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
