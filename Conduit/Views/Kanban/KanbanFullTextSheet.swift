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
        // are kept as written, and emphasis pairs only within a paragraph
        // (lines between blank lines or fences), as the sheet pairs it.
        var lines: [(pieces: [String], paragraph: Int, literal: Bool)] = []
        var paragraph = 0
        var inFence = false
        for raw in markdown.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inFence.toggle()
                paragraph += 1
                continue
            }
            if line.isEmpty {
                paragraph += 1
                continue
            }
            if inFence {
                lines.append(([line], paragraph, true))
                continue
            }
            // A heading or quote marker counts only with its space, so
            // "#hashtag" stays as written.
            while let marker = line.firstIndex(where: { $0 != "#" && $0 != ">" }),
                  marker > line.startIndex, line[marker] == " " {
                line = String(line[marker...]).trimmingCharacters(in: .whitespaces)
            }
            lines.append((line.split(separator: "`", omittingEmptySubsequences: false).map(String.init), paragraph, false))
        }
        var stripped: [Int: [String]] = [:]
        for block in Set(lines.filter { !$0.literal }.map { $0.paragraph }) {
            let prose = lines
                .filter { !$0.literal && $0.paragraph == block }
                .flatMap { line in line.pieces.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element) }
            stripped[block] = pairedEmphasisMarkers(in: prose)
        }
        return lines
            .map { line -> String in
                guard !line.literal else { return line.pieces.joined() }
                let markers = stripped[line.paragraph] ?? []
                return line.pieces.enumerated().map { index, piece -> String in
                    guard index.isMultiple(of: 2) else { return piece }
                    return markers.reduce(piece) { removingEmphasis($1, from: $0) }
                }
                .joined()
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The emphasis markers (`**`, `__`) that pair up across a paragraph's
    /// prose, so bold that spans a code span or a line break still goes. An
    /// odd one out (`my__var`) leaves that marker's runs as written, as the
    /// sheet shows it.
    static func pairedEmphasisMarkers(in prose: [String]) -> [String] {
        ["**", "__"].filter { marker in
            let count = prose.reduce(0) { total, text in
                total + emphasisPattern(marker).numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            }
            return count > 0 && count.isMultiple(of: 2)
        }
    }

    /// Where a marker can open or close emphasis. `__` between two letters
    /// or digits (`my__var`, `snake__case__var`) never does, as in the sheet.
    private static func emphasisPattern(_ marker: String) -> NSRegularExpression {
        marker == "__" ? underscoreEmphasis : starEmphasis
    }

    private static let starEmphasis = try! NSRegularExpression(pattern: #"\*\*"#)
    private static let underscoreEmphasis = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])__|__(?![\p{L}\p{N}])"#)

    private static func removingEmphasis(_ marker: String, from text: String) -> String {
        emphasisPattern(marker).stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
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
