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
    /// any. Nil when the run has nothing to read.
    static func runText(_ run: KanbanRun) -> String? {
        let error = run.error.flatMap { $0.isEmpty ? nil : $0 }
        let summary = run.summary.flatMap { $0.isEmpty ? nil : $0 }
        var parts: [String] = []
        switch (error, summary) {
        case let (error?, summary?):
            parts.append("### " + AppLocalization.string("Error") + "\n\n" + error)
            parts.append("### " + AppLocalization.string("Summary", table: .tasks) + "\n\n" + summary)
        case let (error?, nil):
            parts.append(error)
        case let (nil, summary?):
            parts.append(summary)
        case (nil, nil):
            break
        }
        if parts.isEmpty { return nil }
        if let metadata = run.metadata, let json = prettyJSON(metadata), !isEmptyContainer(metadata) {
            parts.append("### " + AppLocalization.string("Details") + "\n\n```json\n" + json + "\n```")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Whether a run row hides something worth a tap: text past what its
    /// four lines hold, both an error and a summary (the row shows only the
    /// error), or metadata. A short crash message already shown whole
    /// doesn't open.
    static func runHasMoreToRead(_ run: KanbanRun) -> Bool {
        let error = run.error.flatMap { $0.isEmpty ? nil : $0 }
        let summary = run.summary.flatMap { $0.isEmpty ? nil : $0 }
        guard let shown = error ?? summary else { return false }
        if error != nil, summary != nil { return true }
        if let metadata = run.metadata, !isEmptyContainer(metadata) { return true }
        return shown.count > rowPreviewCharacters || shown.components(separatedBy: .newlines).count > 4
    }

    /// Roughly what four caption lines hold on an iPhone.
    static let rowPreviewCharacters = 160

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
    /// line. The sheet renders the Markdown itself.
    static func plainPreview(_ markdown: String) -> String {
        markdown
            .components(separatedBy: .newlines)
            .compactMap { raw -> String? in
                var line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("```") || line.isEmpty { return nil }
                while line.hasPrefix("#") || line.hasPrefix(">") {
                    line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                for marker in ["**", "__", "`"] {
                    line = line.replacingOccurrences(of: marker, with: "")
                }
                return line.isEmpty ? nil : line
            }
            .joined(separator: "\n")
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
