import SwiftUI
import UIKit

/// Text from a Kanban task shown whole: a run's summary or error, an
/// activity event's payload, a comment. The task screen keeps these rows
/// short (a few lines each) so it stays scannable; tapping one opens this
/// sheet, where nothing is cut and the text can be selected, copied and
/// shared, so a long worker handoff can be reviewed on a phone.
struct KanbanFullText: Identifiable {
    let id = UUID()
    let title: String
    var subtitle: String?
    let body: String
    /// Worker summaries and comments are Markdown; event payloads are
    /// `key: value` lines that Markdown would mangle (`root_assignee`).
    var rendersMarkdown = true
}

struct KanbanFullTextSheet: View {
    let content: KanbanFullText
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let subtitle = content.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if content.rendersMarkdown {
                        MarkdownText(source: content.body)
                    } else {
                        Text(content.body)
                            .scaledFont(.footnote)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .background(ConduitBackdrop())
            .navigationTitle(content.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = content.body
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel(copied ? AppLocalization.string("Copied") : AppLocalization.string("Copy"))
                    ShareLink(item: content.body) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share")
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}

/// Builds the whole text behind a task screen row, so the row can stay
/// short. Pure, so the tests read exactly what the sheet shows.
enum KanbanFullTextFormatter {
    /// A run's error and summary, whole, then its metadata when Hermes sent
    /// any. Nil when the run has nothing to read. An error alone is the
    /// body as written (the sheet shows it plain); beside a summary or
    /// metadata the sheet renders Markdown, so the error goes in a code
    /// block under its heading, where `*` or `<...>` in it stay put.
    static func runText(_ run: KanbanRun) -> String? {
        let error = run.error.flatMap { $0.isEmpty ? nil : $0 }
        let summary = run.summary.flatMap { $0.isEmpty ? nil : $0 }
        guard error != nil || summary != nil else { return nil }
        let details = run.metadata.flatMap { metadata in
            isEmptyContainer(metadata) ? nil : prettyJSON(metadata)
        }
        if let error, summary == nil, details == nil { return error }
        var parts: [String] = []
        if let error {
            parts.append("### " + AppLocalization.string("Error") + "\n\n" + fenced(error))
        }
        if let summary {
            parts.append(error == nil ? summary : "### " + AppLocalization.string("Summary", table: .tasks) + "\n\n" + summary)
        }
        if let details {
            parts.append("### " + AppLocalization.string("Details") + "\n\n" + fenced(details, language: "json"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// `text` as a fenced code block, its fence longer than any run of
    /// backticks inside, so the text can't close it early.
    static func fenced(_ text: String, language: String = "") -> String {
        var longest = 0, current = 0
        for character in text {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + language + "\n" + text + "\n" + fence
    }

    /// Whether a run row hides something worth a tap: text past what its
    /// four lines hold, both an error and a summary (the row shows only the
    /// error), or metadata. A short crash message already shown whole
    /// doesn't open.
    static func runHasMoreToRead(_ run: KanbanRun, lineWidth: Int = rowLineWidth) -> Bool {
        let error = run.error.flatMap { $0.isEmpty ? nil : $0 }
        let summary = run.summary.flatMap { $0.isEmpty ? nil : $0 }
        guard let shown = error ?? summary else { return false }
        if error != nil, summary != nil { return true }
        if let metadata = run.metadata, !isEmptyContainer(metadata) { return true }
        return textHasMoreToRead(error != nil ? shown : plainPreview(shown), lineWidth: lineWidth)
    }

    /// Whether `text` likely wraps past the four lines a row shows on an
    /// iPhone. An estimate, not a measurement: each line counts the lines it
    /// wraps to at `lineWidth` columns (`lineWidth(for:at:)` for the row's
    /// text style and text size), with wide characters (CJK, Hangul, emoji)
    /// taking two columns, so a short line of Chinese still opens. It
    /// leans toward opening: a chevron on text that fit costs a tap, a
    /// missing one hides text.
    static func textHasMoreToRead(_ text: String, lineWidth: Int = rowLineWidth) -> Bool {
        let width = max(1, lineWidth)
        var lines = 0
        for line in text.components(separatedBy: .newlines) {
            let columns = line.unicodeScalars.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
            lines += max(1, (columns + width - 1) / width)
            if lines > previewLines { return true }
        }
        return false
    }

    /// Lines a run summary, error or comment shows on the task screen.
    static let previewLines = 4
    /// Columns of caption text a row line holds on the narrowest iPhone at
    /// the default text size, rounded down.
    static let rowLineWidth = 40

    /// Columns a row line holds in `style` at `size`: `rowLineWidth` scaled
    /// by the style's point size against default-size caption (12 pt), so
    /// footnote comments and the larger text sizes, accessibility sizes
    /// included, count the fewer columns they hold.
    static func lineWidth(for style: UIFont.TextStyle, at size: DynamicTypeSize) -> Int {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        let points = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).pointSize
        return lineWidth(points: points)
    }

    /// `rowLineWidth` for text of `points` (the pure half of the above).
    static func lineWidth(points: CGFloat) -> Int {
        guard points > 0 else { return rowLineWidth }
        return max(8, Int((CGFloat(rowLineWidth) * 12 / points).rounded(.down)))
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0x2600...0x27BF, 0x2B00...0x2BFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F000...0x1FAFF, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    /// A run's sheet renders Markdown when it holds a worker's summary or
    /// metadata (its Details heading and JSON block); an error alone is
    /// shown as written, so `*` or `<...>` in it stay put.
    static func runTextIsMarkdown(_ run: KanbanRun) -> Bool {
        if !(run.summary ?? "").isEmpty { return true }
        guard let metadata = run.metadata else { return false }
        return !isEmptyContainer(metadata)
    }

    /// Every payload entry of an activity event, whole: short values first
    /// as `key: value` (who, what, how big), then long text such as a
    /// worker's `summary`, then nested values as indented JSON. Nil when
    /// the event carries no payload.
    static func eventText(_ event: KanbanEvent) -> String? {
        guard let payload = event.payload?.objectValue, !payload.isEmpty else { return nil }
        func rank(_ value: AnyCodable) -> Int {
            switch value {
            case .array, .object: return 2
            case .string(let s): return isLong(s) ? 1 : 0
            default: return 0
            }
        }
        return payload.keys
            .sorted { lhs, rhs in
                let l = rank(payload[lhs] ?? .null), r = rank(payload[rhs] ?? .null)
                return l == r ? lhs < rhs : l < r
            }
            .map { key in
                let value = payload[key] ?? .null
                switch value {
                case .array, .object: return key + ":\n" + display(value)
                default: return key + ": " + display(value)
                }
            }
            .joined(separator: "\n\n")
    }

    /// Whether an activity row hides something worth a tap: long text or a
    /// nested value its one detail line can't hold. A row like "Claimed by
    /// worker" whose payload is `source_status: todo` doesn't open.
    static func eventHasMoreToRead(_ event: KanbanEvent, detail: String?) -> Bool {
        guard let payload = event.payload?.objectValue, !payload.isEmpty else { return false }
        if let detail, detail.count > rowDetailCharacters { return true }
        return payload.values.contains { value in
            switch value {
            case .array(let a): return !a.isEmpty
            case .object(let o): return !o.isEmpty
            case .string(let s): return isLong(s)
            default: return false
            }
        }
    }

    /// Roughly what two caption lines hold on an iPhone.
    static let rowDetailCharacters = 80

    private static func isLong(_ text: String) -> Bool {
        text.count > 60 || text.contains("\n")
    }

    /// A row's preview of Markdown text: heading and quote markers, code
    /// fences, emphasis and backticks taken out and blank lines dropped, so
    /// the few lines a row shows are words, not `## Handoff` and an empty
    /// line. A code span keeps what's inside it whole (`__init__`), only its
    /// backticks go. The sheet renders the Markdown itself.
    static func plainPreview(_ markdown: String) -> String {
        // Each kept line split on backticks: even pieces are prose, odd ones
        // the inside of a code span, left as written. A fenced block's lines
        // (blank ones too) are kept as written, and emphasis pairs only
        // within a paragraph (lines between blank lines or fences), as the
        // sheet pairs it.
        var lines: [(pieces: [String], paragraph: Int, literal: Bool)] = []
        var paragraph = 0
        // The open fence's character and length: only a run of the same
        // character, at least as long, with nothing after it closes it. One
        // opened in a list item or a quote keeps its lines' indentation past
        // the item's, or their quote markers, out of the block.
        // `quotes` is how deep in quotes it opened: only that many markers
        // come off its lines, and a line out of the quote ends it, as the
        // quote it's in ends (#3143).
        var fence: (mark: Character, length: Int, indent: Int, quotes: Int)?
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines) {
            if let open = fence {
                let stripped = quoteStripped(Substring(raw), upTo: open.quotes)
                if stripped.depth < open.quotes {
                    // Out of its quote: the block ends, and this line is read as any other.
                    fence = nil
                    paragraph += 1
                } else {
                    let content = stripped.content
                    let (columns, rest) = leadingColumns(content)
                    let run = rest.prefix { $0 == open.mark }.count
                    if max(0, columns - open.indent) <= 3, run >= open.length, rest.dropFirst(run).allSatisfy(\.isWhitespace) {
                        fence = nil
                        paragraph += 1
                    } else {
                        let indented = content.prefix(open.indent).prefix { $0 == " " }.count
                        lines.append(([String(content.dropFirst(indented))], paragraph, true))
                    }
                    continue
                }
            }
            // A fence opens indented at most 3 columns, in a list item or a
            // quote as at the top.
            let container = fenceContainer(raw)
            let (columns, rest) = leadingColumns(container.content)
            if columns <= 3, let mark = rest.first, mark == "`" || mark == "~" {
                let run = rest.prefix { $0 == mark }.count
                if run >= 3, mark == "~" || !rest.dropFirst(run).contains("`") {
                    fence = (mark, run, container.indent, container.quotes)
                    paragraph += 1
                    continue
                }
            }
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                paragraph += 1
                continue
            }
            // A heading or quote marker counts only with its space, so
            // "#hashtag" stays as written.
            while let marker = line.firstIndex(where: { $0 != "#" && $0 != ">" }),
                  marker > line.startIndex, line[marker] == " " {
                line = String(line[marker...]).trimmingCharacters(in: .whitespaces)
            }
            let pieces = line.split(separator: "`", omittingEmptySubsequences: false).map(String.init)
            lines.append((pieces, paragraph, false))
        }
        let removals = pairedEmphasis(in: lines)
        return lines.enumerated()
            .compactMap { index, line -> String? in
                guard !line.literal else { return line.pieces.joined() }
                let text = line.pieces.enumerated().map { piece, written -> String in
                    var text = written
                    for range in (removals[PiecePosition(line: index, piece: piece)] ?? []).sorted(by: { $0.location > $1.location }) {
                        text = (text as NSString).replacingCharacters(in: range, with: "")
                    }
                    return text
                }
                .joined()
                return text.isEmpty ? nil : text
            }
            .joined(separator: "\n")
    }

    /// A piece of a preview line: the line's index, and the piece's among
    /// the line's backtick-split pieces.
    struct PiecePosition: Hashable {
        let line: Int
        let piece: Int
    }

    /// The emphasis markers (`**`, `__`) that pair up within a paragraph's
    /// prose, as CommonMark pairs them: a run opens only where it's
    /// left-flanking and closes only where it's right-flanking (`a ** b`
    /// does neither; `__` between two letters or digits, `my__var`, never
    /// does), and a closer pairs with the nearest opener before it. Bold
    /// that spans a code span or a line break still pairs; an odd one out
    /// stays as written, as the sheet shows it. By piece, the ranges to
    /// take out.
    static func pairedEmphasis(in lines: [(pieces: [String], paragraph: Int, literal: Bool)]) -> [PiecePosition: [NSRange]] {
        var order: [Int: [PiecePosition]] = [:]
        for (index, line) in lines.enumerated() where !line.literal {
            for piece in stride(from: 0, to: line.pieces.count, by: 2) {
                order[line.paragraph, default: []].append(PiecePosition(line: index, piece: piece))
            }
        }
        var removals: [PiecePosition: [NSRange]] = [:]
        for positions in order.values {
            // A run of `*` or `_` is one delimiter, its flanking read at the
            // run's edges (`***a***`, `****`), and a closer takes two from
            // the nearest opener's inner end at a time (#3143).
            for mark in ["*", "_"] {
                let unit = (mark as NSString).character(at: 0)
                var openers: [(position: PiecePosition, location: Int, length: Int)] = []
                for position in positions {
                    let pieces = lines[position.line].pieces
                    let text = pieces[position.piece] as NSString
                    var index = 0
                    while index < text.length {
                        guard text.character(at: index) == unit else {
                            index += 1
                            continue
                        }
                        var end = index
                        while end < text.length, text.character(at: end) == unit { end += 1 }
                        let length = end - index
                        defer { index = end }
                        guard length >= 2 else { continue }
                        // A line's edge reads as a space; a code span's backtick as punctuation.
                        let before: Character = index > 0
                            ? text.substring(with: text.rangeOfComposedCharacterSequence(at: index - 1)).first ?? " "
                            : position.piece > 0 ? "`" : " "
                        let after: Character = end < text.length
                            ? text.substring(with: text.rangeOfComposedCharacterSequence(at: end)).first ?? " "
                            : position.piece < pieces.count - 1 ? "`" : " "
                        let (opens, closes) = emphasisFlanking(mark + mark, before: before, after: after)
                        var start = index
                        if closes {
                            while end - start >= 2, var opener = openers.popLast() {
                                removals[opener.position, default: []].append(
                                    NSRange(location: opener.location + opener.length - 2, length: 2))
                                removals[position, default: []].append(NSRange(location: start, length: 2))
                                start += 2
                                opener.length -= 2
                                if opener.length >= 2 { openers.append(opener) }
                            }
                        }
                        if opens, end - start >= 2 {
                            openers.append((position, start, end - start))
                        }
                    }
                }
            }
        }
        return removals
    }

    /// Whether a `**` or `__` run between these characters can open and
    /// close emphasis (CommonMark's flanking rules).
    static func emphasisFlanking(_ marker: String, before: Character, after: Character) -> (opens: Bool, closes: Bool) {
        func isPunctuation(_ character: Character) -> Bool { character.isPunctuation || character.isSymbol }
        let left = !after.isWhitespace
            && !(isPunctuation(after) && !(before.isWhitespace || isPunctuation(before)))
        let right = !before.isWhitespace
            && !(isPunctuation(before) && !(after.isWhitespace || isPunctuation(after)))
        guard marker == "__" else { return (left, right) }
        return (left && (!right || isPunctuation(before)), right && (!left || isPunctuation(after)))
    }

    /// Spaces and tabs (a tab to the next multiple of 4) before the text,
    /// and what follows them.
    private static func leadingColumns(_ text: Substring) -> (columns: Int, rest: Substring) {
        var columns = 0
        var rest = text
        while let first = rest.first, first == " " || first == "\t" {
            columns = first == " " ? columns + 1 : columns + 4 - columns % 4
            rest = rest.dropFirst()
        }
        return (columns, rest)
    }

    /// The line past its quote markers (`> `, each indented at most 3), at
    /// most `limit` of them, and how many came off.
    private static func quoteStripped(_ line: Substring, upTo limit: Int = .max) -> (content: Substring, depth: Int) {
        var content = line
        var depth = 0
        while depth < limit {
            let (columns, rest) = leadingColumns(content)
            guard columns <= 3, rest.first == ">" else { break }
            content = rest.dropFirst()
            if content.first == " " { content = content.dropFirst() }
            depth += 1
        }
        return (content, depth)
    }

    /// The line past a quote's markers and a list item's marker, where a
    /// fence in them starts, and the item's content indentation.
    private static func fenceContainer(_ raw: String) -> (content: Substring, quotes: Int, indent: Int) {
        let (content, quoted) = quoteStripped(Substring(raw))
        let (columns, rest) = leadingColumns(content)
        guard columns <= 3 else { return (content, quoted, 0) }
        var marker = rest.prefix { $0.isASCII && $0.isNumber }
        if marker.isEmpty {
            marker = rest.prefix(1)
            guard let bullet = marker.first, bullet == "-" || bullet == "+" || bullet == "*" else { return (content, quoted, 0) }
        } else {
            guard marker.count <= 9, let end = rest.dropFirst(marker.count).first, end == "." || end == ")" else {
                return (content, quoted, 0)
            }
            marker = rest.prefix(marker.count + 1)
        }
        let afterMarker = rest.dropFirst(marker.count)
        guard afterMarker.first == " " else { return (content, quoted, 0) }
        return (afterMarker.dropFirst(), quoted, columns + marker.count + 1)
    }

    /// Whether the Result row opens the whole text: its preview runs past
    /// the row's lines, or the preview had Markdown taken out.
    static func resultOpensFullText(_ result: String, preview: String, lineWidth: Int) -> Bool {
        textHasMoreToRead(preview, lineWidth: lineWidth) || preview != result
    }

    /// Activity rows shown and hidden behind "Show N earlier events": the
    /// newest `newest` until the person asks for all of them.
    static func activityShown(total: Int, newest: Int, showsAll: Bool) -> (shownCount: Int, hiddenCount: Int) {
        let shown = showsAll ? total : min(total, newest)
        return (shown, total - shown)
    }

    /// A child's result as its parent received it (`child_results`): its
    /// task result, else its latest run summary, as a row preview. Nil when
    /// it handed back neither.
    static func childResultPreview(_ child: KanbanChildResult) -> String? {
        let text = [child.result, child.latestSummary]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return text.map(plainPreview).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func display(_ value: AnyCodable) -> String {
        switch value {
        case .string(let s): return s
        case .number(let n):
            if let exact = Int(exactly: n) { return String(exact) }
            return String(n)
        case .bool(let b): return String(b)
        case .null: return "null"
        case .array, .object: return prettyJSON(value) ?? ""
        }
    }

    private static func prettyJSON(_ value: AnyCodable) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func isEmptyContainer(_ value: AnyCodable) -> Bool {
        switch value {
        case .null: return true
        case .object(let o): return o.isEmpty
        case .array(let a): return a.isEmpty
        default: return false
        }
    }
}
