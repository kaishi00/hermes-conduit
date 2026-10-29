//
//  ToolResultViews.swift
//  Conduit
//
//  The readable part of an opened tool row (see ToolResultPresentation):
//  a plan as a checklist, a diff in color, a command's output, the pages a
//  search found, and the pictures or audio a tool made.
//

import SwiftUI
import UIKit

/// The readable part of an opened tool row, above its raw Input and Output.
struct ToolResultBodyView: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let presentation: ToolResultPresentation
    let gatewayResolver: GatewayMediaDataURLResolver?
    @Environment(\.openURL) private var openURL
    /// The column's text size, which a wide window steps up
    /// (`readableChatColumn`), as the raw Input and Output below follow.
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.chatColumnBaseTextSize) private var columnBaseTextSize

    private var monospaced: UIFont {
        .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1, in: sizeCategory, from: columnBaseTextSize).pointSize, weight: .regular)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = presentation.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(.caption)
                    .foregroundStyle(.red)
                    .labelStyle(.titleAndIcon)
            }
            if let notice = presentation.notice {
                Label(notice, systemImage: "info.circle")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            content
            if let exitCode = presentation.exitCode {
                Text(AppLocalization.string("Exit code \(String(exitCode))"))
                    .scaledFont(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch presentation.body {
        case nil:
            EmptyView()
        case .todos(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: Self.symbol(for: item.status))
                            .foregroundStyle(item.status == .inProgress ? Color.conduitAccent : .secondary)
                            .accessibilityLabel(Self.statusLabel(for: item.status))
                        Text(item.content)
                            .strikethrough(item.status == .cancelled)
                            .foregroundStyle(item.status == .completed || item.status == .cancelled ? .secondary : .primary)
                    }
                    .scaledFont(.subheadline)
                    .padding(.leading, CGFloat(min(item.depth, 6)) * 16)
                    .accessibilityElement(children: .combine)
                    .modifier(SubtaskAccessibilityValue(isSubtask: item.depth > 0))
                }
            }
        case .diff(let diff):
            SelectableTextView(
                attributedText: Self.coloredDiff(ToolCard.truncateForDisplay(diff, maxLines: ToolResultPresentation.displayLineLimit), font: monospaced),
                font: monospaced,
                textColor: .secondaryLabel,
                maximumNumberOfLines: 0,
                keepsParagraphStyles: true
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        case .text(let text):
            SelectableTextView(
                attributedText: NSAttributedString(string: ToolCard.truncateForDisplay(text, maxLines: ToolResultPresentation.displayLineLimit)),
                font: monospaced,
                textColor: .label,
                maximumNumberOfLines: 0
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        case .links(let links):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(links) { link in
                    if link.opensPage {
                        Button {
                            if let url = URL(string: link.url) { openURL(url) }
                        } label: {
                            linkLabel(link)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(AppLocalization.string("Opens the page"))
                    } else {
                        // One VoiceOver stop per link, as a button row is.
                        linkLabel(link)
                            .accessibilityElement(children: .combine)
                    }
                }
            }
        case .media(let references):
            MarkdownText(
                source: references.map(ToolResultPresentation.mediaTag(for:)).joined(separator: "\n\n"),
                gatewayMediaDataURL: gatewayResolver.map { resolver in
                    { path in await resolver.dataURL(for: path) }
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func linkLabel(_ link: ToolResultPresentation.Link) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if !link.title.isEmpty {
                Text(link.title)
                    .scaledFont(.subheadline)
                    .foregroundStyle(link.opensPage ? Color.conduitAccent : Color.primary)
                    .lineLimit(2)
            }
            if link.opensPage {
                Text(URL(string: link.url)?.host ?? link.url)
                    .scaledFont(.caption2)
                    .foregroundStyle(.conduitTertiary)
                    .lineLimit(1)
            }
            if let error = link.error {
                Text(error)
                    .scaledFont(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            } else if let snippet = link.snippet {
                Text(snippet)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private static func symbol(for status: ToolResultPresentation.TodoItem.Status) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private static func statusLabel(for status: ToolResultPresentation.TodoItem.Status) -> String {
        switch status {
        case .pending: return AppLocalization.string("Not started")
        case .inProgress: return AppLocalization.string("In progress")
        case .completed: return AppLocalization.string("Done")
        case .cancelled: return AppLocalization.string("Cancelled")
        }
    }

    /// A unified diff with added lines green, removed lines red and hunk
    /// and file headers dimmed.
    static func coloredDiff(_ diff: String, font: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = diff.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let color: UIColor
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") {
                color = .tertiaryLabel
            } else if line.hasPrefix("+") {
                color = .systemGreen
            } else if line.hasPrefix("-") {
                color = .systemRed
            } else {
                color = .secondaryLabel
            }
            let text = index < lines.count - 1 ? line + "\n" : line
            result.append(NSAttributedString(string: text, attributes: [.foregroundColor: color, .font: font]))
        }
        return result
    }
}

/// VoiceOver hears "Subtask" on a nested task, and nothing extra on a
/// top-level one.
private struct SubtaskAccessibilityValue: ViewModifier {
    let isSubtask: Bool

    func body(content: Content) -> some View {
        if isSubtask {
            content.accessibilityValue(AppLocalization.string("Subtask"))
        } else {
            content
        }
    }
}
