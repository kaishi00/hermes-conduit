import SwiftUI
import UIKit

/// A chat answer's consecutive headings, paragraphs and lists, drawn in one
/// text view instead of one per block and list item. A row builds every
/// text view it holds as it scrolls in, so a long answer that mounted a
/// dozen of them now mounts a few. Each paragraph keeps the font, spacing
/// and indent its own block view gave it, so the answer looks the same.
enum MarkdownProseRun {
    /// One step of the answer's block stack: a single block in its own
    /// view, or a run of prose blocks sharing one.
    struct Piece: Identifiable, Equatable {
        let blocks: Range<Int>
        let isRun: Bool
        var id: Int { blocks.lowerBound }
    }

    /// Spacing the block views put between and around prose blocks.
    enum Spacing {
        static let betweenBlocks: CGFloat = 10
        static let betweenListItems: CGFloat = 7
        static let paragraphLineSpacing: CGFloat = 4
        static let listItemLineSpacing: CGFloat = 3
        static let listMarkerToText: CGFloat = 9

        static func aboveHeading(level: Int) -> CGFloat {
            level <= 2 ? 6 : 2
        }
    }

    /// Whether a block can join a run. Quotes and callouts draw a card and
    /// task lists draw checkbox symbols, so they keep their own views.
    static func joins(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .heading, .paragraph:
            true
        case .unorderedList(let items), .orderedList(let items):
            !items.contains { MarkdownParser.taskItem($0) != nil }
        default:
            false
        }
    }

    /// The runs worth joining: consecutive joinable blocks that would
    /// otherwise mount more than one text view.
    static func ranges(in blocks: [MarkdownBlock]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start: Int?

        func close(at end: Int) {
            guard let runStart = start else { return }
            start = nil
            if textViewCount(blocks[runStart..<end]) > 1 {
                ranges.append(runStart..<end)
            }
        }

        for (index, block) in blocks.enumerated() {
            if joins(block) {
                if start == nil { start = index }
            } else {
                close(at: index)
            }
        }
        close(at: blocks.count)
        return ranges
    }

    static func pieces(blockCount: Int, runs: [Range<Int>]) -> [Piece] {
        var pieces: [Piece] = []
        var remainingRuns = runs[...]
        var index = 0
        while index < blockCount {
            if let run = remainingRuns.first, run.lowerBound == index {
                pieces.append(Piece(blocks: run, isRun: true))
                index = run.upperBound
                remainingRuns = remainingRuns.dropFirst()
            } else {
                pieces.append(Piece(blocks: index..<(index + 1), isRun: false))
                index += 1
            }
        }
        return pieces
    }

    /// Space above the run, as a heading's own view had above it.
    static func topPadding(for firstBlock: MarkdownBlock) -> CGFloat {
        if case .heading(let level, _) = firstBlock {
            return Spacing.aboveHeading(level: level)
        }
        return 0
    }

    private static func textViewCount(_ blocks: ArraySlice<MarkdownBlock>) -> Int {
        blocks.reduce(0) { count, block in
            switch block {
            case .unorderedList(let items), .orderedList(let items):
                count + items.count
            default:
                count + 1
            }
        }
    }

    /// TextKit puts a paragraph's line spacing under its last line when
    /// another paragraph follows in the same text view, where a block's
    /// own view ended without it. The gaps take it back out.
    static func gap(_ spacing: CGFloat, below lineSpacing: CGFloat) -> CGFloat {
        max(1, spacing - lineSpacing)
    }

    private struct Paragraph {
        let content: NSAttributedString
        let style: NSParagraphStyle
        /// Space under the paragraph's last line, before the next one.
        var spacingAfter: CGFloat = 0
    }

    /// The run's text. Blocks are separated by an empty line sized to the
    /// gap their views had, and list items by a plain line break, so
    /// copying a run gives the same text copying its blocks did, with
    /// each list item's marker in front.
    @MainActor
    static func attributedText(
        for blocks: ArraySlice<MarkdownBlock>,
        references: MarkdownReferenceContext,
        foregroundStyle: Color,
        usesAccentSurface: Bool,
        chatTextSize: ChatTextSize
    ) -> NSAttributedString {
        let bodyFont = ChatTypography.font(for: .body, chatSize: chatTextSize)
        let textColor = usesAccentSurface ? UIColor.white : UIColor(foregroundStyle)
        let markerColor = usesAccentSurface
            ? UIColor.white.withAlphaComponent(0.92)
            : UIColor(Color.conduitAccent)
        let markerFont = UIFont.systemFont(ofSize: bodyFont.pointSize, weight: .semibold)

        func inline(_ source: String, font: UIFont) -> NSAttributedString {
            InlineMarkdownContent.bridged(
                source: source,
                references: references,
                foregroundStyle: foregroundStyle,
                usesAccentSurface: usesAccentSurface,
                font: font,
                trailingCharacterOpacities: []
            )
        }

        func lineStyle(_ lineSpacing: CGFloat) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            return style
        }

        func spacer(height: CGFloat) -> Paragraph {
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = height
            style.maximumLineHeight = height
            return Paragraph(content: NSAttributedString(), style: style)
        }

        func listItems(_ items: [String], ordered: Bool) -> [Paragraph] {
            let markerColumn = ChatTypography.dimension(ordered ? 24 : 12, chatSize: chatTextSize)
            let textStart = markerColumn + Spacing.listMarkerToText
            return items.enumerated().map { (index, item) -> Paragraph in
                let marker = ordered ? "\(index + 1)." : "•"
                let markerAttributes: [NSAttributedString.Key: Any] = [
                    .font: markerFont,
                    .foregroundColor: markerColor
                ]
                let markerWidth = (marker as NSString).size(withAttributes: markerAttributes).width
                let style = lineStyle(Spacing.listItemLineSpacing)
                // The marker sits right-aligned in its column, as the list
                // view's trailing-aligned marker frame put it; the tab takes
                // the text to where that view's text column began.
                style.firstLineHeadIndent = max(0, markerColumn - markerWidth)
                style.headIndent = textStart
                style.tabStops = [NSTextTab(textAlignment: .natural, location: textStart, options: [:])]
                style.defaultTabInterval = textStart

                let content = NSMutableAttributedString(string: marker + "\t", attributes: markerAttributes)
                content.append(inline(item, font: bodyFont))
                let isLast = index == items.count - 1
                return Paragraph(
                    content: content,
                    style: style,
                    spacingAfter: isLast
                        ? 0
                        : gap(Spacing.betweenListItems, below: Spacing.listItemLineSpacing)
                )
            }
        }

        var paragraphs: [Paragraph] = []
        var lastLineSpacing: CGFloat = 0
        for block in blocks {
            let blockParagraphs: [Paragraph]
            var blockGap = Spacing.betweenBlocks
            switch block {
            case .heading(let level, let text):
                blockParagraphs = [Paragraph(
                    content: inline(text, font: MarkdownHeading.font(for: level, chatTextSize: chatTextSize)),
                    style: lineStyle(0)
                )]
                blockGap += Spacing.aboveHeading(level: level)
            case .paragraph(let text):
                blockParagraphs = [Paragraph(
                    content: inline(text, font: bodyFont),
                    style: lineStyle(Spacing.paragraphLineSpacing)
                )]
            case .unorderedList(let items):
                blockParagraphs = listItems(items, ordered: false)
            case .orderedList(let items):
                blockParagraphs = listItems(items, ordered: true)
            default:
                assertionFailure("only blocks that join a prose run reach its text")
                blockParagraphs = []
            }
            guard !blockParagraphs.isEmpty else { continue }
            if !paragraphs.isEmpty {
                paragraphs.append(spacer(height: gap(blockGap, below: lastLineSpacing)))
            }
            paragraphs.append(contentsOf: blockParagraphs)
            lastLineSpacing = blockParagraphs.last?.style.lineSpacing ?? 0
        }

        let result = NSMutableAttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            let start = result.length
            result.append(paragraph.content)
            let isLast = index == paragraphs.count - 1
            if !isLast {
                let lastFont = paragraph.content.length > 0
                    ? paragraph.content.attribute(.font, at: paragraph.content.length - 1, effectiveRange: nil) as? UIFont
                    : nil
                let font = lastFont ?? bodyFont
                result.append(NSAttributedString(
                    string: "\n",
                    attributes: [.font: font, .foregroundColor: textColor]
                ))
            }
            let range = NSRange(location: start, length: result.length - start)
            guard range.length > 0 else { continue }
            result.addAttribute(.paragraphStyle, value: paragraph.style, range: range)
            if paragraph.spacingAfter > 0 {
                // Only the item's last line gets the space under it: a line
                // break inside the item stays as tight as in its own view.
                let lastLine = (result.string as NSString).paragraphRange(
                    for: NSRange(location: NSMaxRange(range) - 1, length: 0)
                )
                let spaced = (paragraph.style.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                spaced.paragraphSpacing = paragraph.spacingAfter
                result.addAttribute(.paragraphStyle, value: spaced, range: NSIntersectionRange(lastLine, range))
            }
        }
        return NSAttributedString(attributedString: result)
    }
}

/// A run of prose blocks in one text view, as one selection segment.
struct MarkdownProseRunView: View {
    let text: NSAttributedString
    let topPadding: CGFloat
    let foregroundStyle: Color
    let usesAccentSurface: Bool
    let selectionCoordinator: MarkdownSelectionCoordinator?
    let selectionSegment: MarkdownSelectionSegmentDescriptor?
    @Environment(\.chatTextSize) private var chatTextSize

    var body: some View {
        SelectableTextView(
            attributedText: text,
            font: ChatTypography.font(for: .body, chatSize: chatTextSize),
            textColor: usesAccentSurface ? .white : UIColor(foregroundStyle),
            linkColor: usesAccentSurface ? .white : .link,
            selectionCoordinator: selectionCoordinator,
            selectionSegment: selectionSegment,
            keepsParagraphStyles: true
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, topPadding)
    }
}

/// Prose runs share one text view. Set by the chat, where answers mount and
/// unmount as the transcript scrolls; elsewhere every block keeps its own.
struct MarkdownJoinsProseRunsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var markdownJoinsProseRuns: Bool {
        get { self[MarkdownJoinsProseRunsKey.self] }
        set { self[MarkdownJoinsProseRunsKey.self] = newValue }
    }
}
