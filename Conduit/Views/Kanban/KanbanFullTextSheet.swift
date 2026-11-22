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
            parts.append("### " + AppLocalization.string("Summary") + "\n\n" + summary)
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

    /// Every payload entry of an activity event, whole: scalars as
    /// `key: value`, nested values as indented JSON. Nil when the event
    /// carries no payload.
    static func eventText(_ event: KanbanEvent) -> String? {
        guard let payload = event.payload?.objectValue, !payload.isEmpty else { return nil }
        return payload.keys.sorted().map { key in
            let value = payload[key] ?? .null
            switch value {
            case .array, .object: return key + ":\n" + display(value)
            default: return key + ": " + display(value)
            }
        }
        .joined(separator: "\n\n")
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
