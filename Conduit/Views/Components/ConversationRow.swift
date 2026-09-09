import SwiftUI

struct ConversationRow: View {
    let session: SessionSummary
    let secondaryLine: String
    let isPinned: Bool
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.conduitPrimaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(session.updatedLabel)
                    .font(.caption)
                    .foregroundStyle(Color.conduitSecondaryText)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.conduitSecondaryText)
                        .accessibilityHidden(true)
                }
                Text(secondaryLine)
                    .font(.subheadline)
                    .foregroundStyle(Color.conduitSecondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .frame(minHeight: ConduitInboxMetrics.rowMinimumHeight, alignment: .center)
        .contentShape(Rectangle())
        .background(
            isSelected
                ? Color.conduitRaisedSurface.opacity(0.9)
                : Color.clear
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [session.title]
        if isPinned { parts.append("Pinned") }
        if !secondaryLine.isEmpty { parts.append(secondaryLine) }
        if !session.updatedLabel.isEmpty { parts.append(session.updatedLabel) }
        return parts.joined(separator: ", ")
    }
}

/// Home-row secondary copy: cached activity snippet, else source label — never model.
enum ConversationActivityCopy {
    static func secondaryLine(
        session: SessionSummary,
        cachedSnippet: String?,
        liveMessages: [ChatMessage]? = nil
    ) -> String {
        if let live = SessionPresentationCache.activityPreview(from: liveMessages ?? []), !live.isEmpty {
            return live
        }
        if let cached = cachedSnippet?.trimmingCharacters(in: .whitespacesAndNewlines), !cached.isEmpty {
            return cached
        }
        return session.source.label.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
