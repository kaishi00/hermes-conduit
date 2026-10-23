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
            // Runs come sorted and apart from `ranges(in:)`; anything else
            // is skipped rather than allowed to stall the loop.
            while let run = remainingRuns.first, run.lowerBound < index || run.isEmpty {
                remainingRuns = remainingRuns.dropFirst()
            }
            if let run = remainingRuns.first, run.lowerBound == index {
                let blocks = index..<min(run.upperBound, blockCount)
                pieces.append(Piece(blocks: blocks, isRun: true))
                index = blocks.upperBound
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

    /// TextKit puts a paragraph's line spacing above its first line when
    /// another paragraph comes before it in the same text view, where the
    /// paragraph's own view began without it. The gaps take it back out.
    static func gap(_ spacing: CGFloat, above lineSpacing: CGFloat) -> CGFloat {
        max(1, spacing - lineSpacing)
    }

    /// Marks a character of the run's text that copies as something else:
    /// the line break between two blocks copies as a blank line, and the
    /// tab after a list marker as a space, as copying the blocks did.
    static let copiesAs = NSAttributedString.Key("ConduitProseRunCopiesAs")

    /// The text copying `text` gives: each marked character becomes what it
    /// copies as. A mark at either end is the separator beyond what was
    /// selected, which a block's own view ended at, so it copies as
    /// nothing. Text without marks comes back as it is.
    static func copyableText(_ text: NSAttributedString) -> NSAttributedString {
        var marks: [(range: NSRange, copy: String)] = []
        text.enumerateAttribute(copiesAs, in: NSRange(location: 0, length: text.length), options: []) { value, range, _ in
            guard let copy = value as? String else { return }
            // Neighbouring marks with the same copy come as one range.
            var count = range.length
            if range.location == 0 { count -= 1 }
            if NSMaxRange(range) == text.length, count > 0 { count -= 1 }
            marks.append((range, String(repeating: copy, count: count)))
        }
        guard !marks.isEmpty else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        for mark in marks.reversed() {
            result.replaceCharacters(in: mark.range, with: mark.copy)
        }
        result.removeAttribute(copiesAs, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// What copying a text view's own selection gives, when it holds a run.
    @MainActor
    static func copiedSelection(in textView: UITextView) -> NSAttributedString? {
        guard let text = textView.attributedText else { return nil }
        let range = NSIntersectionRange(textView.selectedRange, NSRange(location: 0, length: text.length))
        guard range.length > 0 else { return nil }
        let selected = text.attributedSubstring(from: range)
        let copied = copyableText(selected)
        return copied === selected ? nil : copied
    }

    private struct Paragraph {
        let content: NSAttributedString
        let style: NSParagraphStyle
        /// Space under the paragraph's last line, before the next one.
        var spacingAfter: CGFloat = 0
        /// The last paragraph of a block: its line break copies as the
        /// blank line between blocks.
        var endsBlock = false
    }

    /// The run's text. Each paragraph keeps its block view's line spacing,
    /// and the space under a block's or list item's last line makes up the
    /// gap the stack put between their views. Copying it through
    /// `copyableText` gives the text copying its blocks did: blocks a blank
    /// line apart, each list item with its marker and a space in front.
    @MainActor
    static func attributedText(
        for blocks: ArraySlice<MarkdownBlock>,
        references: MarkdownReferenceContext,
        foregroundStyle: Color,
        usesAccentSurface: Bool,
        chatTextSize: ChatTextAppearance
    ) -> NSAttributedString {
        let bodyFont = ChatTypography.font(for: .body, appearance: chatTextSize)
        let textColor = usesAccentSurface ? UIColor.white : UIColor(foregroundStyle)
        let markerColor = usesAccentSurface
            ? UIColor.white.withAlphaComponent(0.92)
            : UIColor(Color.conduitAccent)
        let markerFont = ChatTypography.styled(
            UIFont.systemFont(ofSize: bodyFont.pointSize, weight: .semibold),
            role: .body,
            style: chatTextSize.style
        )

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

        func listItems(_ items: [String], ordered: Bool) -> [Paragraph] {
            let markerColumn = ChatTypography.dimension(ordered ? 24 : 12, appearance: chatTextSize)
            return items.enumerated().map { (index, item) -> Paragraph in
                let marker = ordered ? "\(index + 1)." : "•"
                let markerAttributes: [NSAttributedString.Key: Any] = [
                    .font: markerFont,
                    .foregroundColor: markerColor
                ]
                let markerWidth = (marker as NSString).size(withAttributes: markerAttributes).width
                let style = lineStyle(Spacing.listItemLineSpacing)
                // The marker sits right-aligned in its column, as the list
                // view's trailing-aligned marker frame put it, and a tab
                // takes the text to where that view's text column began.
                // Wrapped lines start there too. A marker wider than its
                // column ("10." at a large text size) moves its item's
                // text along rather than past the next tab interval.
                let textStart = max(markerColumn, markerWidth) + Spacing.listMarkerToText
                style.firstLineHeadIndent = max(0, markerColumn - markerWidth)
                style.headIndent = textStart
                style.tabStops = [NSTextTab(textAlignment: .natural, location: textStart, options: [:])]
                style.defaultTabInterval = textStart

                let content = NSMutableAttributedString(string: marker, attributes: markerAttributes)
                var tabAttributes = markerAttributes
                tabAttributes[copiesAs] = " "
                content.append(NSAttributedString(string: "\t", attributes: tabAttributes))
                content.append(inline(item, font: bodyFont))
                let isLast = index == items.count - 1
                return Paragraph(
                    content: content,
                    style: style,
                    spacingAfter: isLast
                        ? 0
                        : gap(Spacing.betweenListItems, above: Spacing.listItemLineSpacing)
                )
            }
        }

        var paragraphs: [Paragraph] = []
        for block in blocks {
            let blockParagraphs: [Paragraph]
            var gapAbove = Spacing.betweenBlocks
            switch block {
            case .heading(let level, let text):
                blockParagraphs = [Paragraph(
                    content: inline(text, font: MarkdownHeading.font(for: level, chatTextSize: chatTextSize)),
                    style: lineStyle(0)
                )]
                gapAbove += Spacing.aboveHeading(level: level)
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
            guard let first = blockParagraphs.first else { continue }
            if let above = paragraphs.indices.last {
                paragraphs[above].spacingAfter = gap(gapAbove, above: first.style.lineSpacing)
                paragraphs[above].endsBlock = true
            }
            paragraphs.append(contentsOf: blockParagraphs)
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
                var breakAttributes: [NSAttributedString.Key: Any] = [
                    .font: lastFont ?? bodyFont,
                    .foregroundColor: textColor
                ]
                if paragraph.endsBlock {
                    breakAttributes[copiesAs] = "\n\n"
                }
                result.append(NSAttributedString(string: "\n", attributes: breakAttributes))
            }
            let range = NSRange(location: start, length: result.length - start)
            guard range.length > 0 else { continue }
            result.addAttribute(.paragraphStyle, value: paragraph.style, range: range)
            if paragraph.spacingAfter > 0 {
                // Only the paragraph's last line gets the space under it: a
                // line break inside it stays as tight as in its own view.
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
            font: ChatTypography.font(for: .body, appearance: chatTextSize),
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
private struct MarkdownJoinsProseRunsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var markdownJoinsProseRuns: Bool {
        get { self[MarkdownJoinsProseRunsKey.self] }
        set { self[MarkdownJoinsProseRunsKey.self] = newValue }
    }
}
