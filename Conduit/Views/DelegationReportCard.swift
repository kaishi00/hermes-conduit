import SwiftUI

/// The notice Hermes writes into a chat when its background delegate agents
/// finish ("6 background agents finished"), with what each one did: a line
/// per agent (its task, how it ended, how long it ran), and each agent's
/// result a tap away (issue 1553). It comes back with the chat, since the
/// report is part of the transcript, so a finished agent's work is still
/// there after the Delegate agents sheet has forgotten it.
struct DelegationReportCard: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let message: ChatMessage
    let report: DelegationReport
    @Environment(\.chatRowDisclosure) private var disclosure
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Nil until tapped here: a rebuilt row takes what the reader chose
    /// from `disclosure`.
    @State private var tapped: Bool?

    /// Folded, a long batch shows its first agents and how many more.
    static let foldedLimit = 6

    private var expanded: Bool {
        tapped ?? disclosure?.isExpanded(message.id, default: false) ?? false
    }

    var body: some View {
        Button {
            Haptics.selection()
            let opens = !expanded
            // Tells the scroller first, as every row that opens does.
            disclosure?.willToggle(message.id, to: opens)
            withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { tapped = opens }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "person.2")
                    .scaledFont(.footnote.weight(.medium))
                    .foregroundStyle(.conduitAccent)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(AppLocalization.string("System"))
                            .scaledFont(.caption2.weight(.semibold))
                            .foregroundStyle(.conduitAccent)
                            .textCase(.uppercase)
                            .tracking(0.5)
                        Spacer(minLength: 8)
                        MessageTimestampLabel(timestamp: message.timestamp, tone: .supporting)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(message.content)
                            .scaledFont(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(expanded ? AppLocalization.string("Show less") : AppLocalization.string("Show all"))
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .scaledFont(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    let shown = expanded ? report.entries : Array(report.entries.prefix(Self.foldedLimit))
                    ForEach(shown, id: \.number) { entry in
                        entryView(entry)
                    }
                    if !expanded, report.entries.count > Self.foldedLimit {
                        Text(AppLocalization.string("\(report.entries.count - Self.foldedLimit) more"))
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Color.conduitAccent.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.conduitAccent.opacity(0.15), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .accessibilityValue(expanded ? AppLocalization.string("Expanded") : AppLocalization.string("Collapsed"))
        .accessibilityHint(expanded ? AppLocalization.string("Shows less") : AppLocalization.string("Shows each agent's result"))
        .accessibilityIdentifier("delegation.report")
    }

    @ViewBuilder
    private func entryView(_ entry: DelegationReport.Entry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: Self.symbol(entry.outcome))
                    .scaledFont(.caption.weight(.semibold))
                    .foregroundStyle(Self.tint(entry.outcome))
                    .accessibilityHidden(true)
                Text(entry.goal.isEmpty ? AppLocalization.string("Delegate agent") : entry.goal)
                    .scaledFont(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(expanded ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Self.caption(entry))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.spokenLine(entry))
            if expanded, !entry.result.isEmpty {
                MarkdownText(source: entry.result)
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 22)
            }
        }
    }

    static func symbol(_ outcome: DelegationReport.Entry.Outcome) -> String {
        switch outcome {
        case .completed: return "checkmark.circle.fill"
        case .incomplete: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    static func tint(_ outcome: DelegationReport.Entry.Outcome) -> Color {
        switch outcome {
        case .completed: return .conduitSuccess
        case .incomplete: return .orange
        case .stopped: return .secondary
        case .failed: return .red
        }
    }

    static func label(_ outcome: DelegationReport.Entry.Outcome) -> String {
        switch outcome {
        case .completed: return AppLocalization.string("Completed")
        case .incomplete: return AppLocalization.string("Incomplete")
        case .stopped: return AppLocalization.string("Interrupted")
        case .failed: return AppLocalization.string("Failed")
        }
    }

    /// "12s" for a finished agent, its outcome too when it didn't finish.
    static func caption(_ entry: DelegationReport.Entry) -> String {
        let time = ChatStepTiming.text(entry.duration)
        guard entry.outcome != .completed else { return time ?? label(entry.outcome) }
        return [label(entry.outcome), time].compactMap { $0 }.joined(separator: " · ")
    }

    static func spokenLine(_ entry: DelegationReport.Entry) -> String {
        let goal = entry.goal.isEmpty ? AppLocalization.string("Delegate agent") : entry.goal
        return [goal, label(entry.outcome), ChatStepTiming.spokenText(entry.duration)].compactMap { $0 }.joined(separator: ", ")
    }
}
