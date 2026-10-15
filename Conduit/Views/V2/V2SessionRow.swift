//
//  V2SessionRow.swift
//  Conduit
//
//  The dense V2 session row: no card, two lines, about 58 pt tall so ten or
//  more conversations fit on an iPhone screen. Line one is the title and
//  time; line two a status glyph, a one-line preview, and an action word
//  only when the row needs one (Running, Approve). Unread is a gold dot in
//  the leading column.
//

import SwiftUI

/// A row's status, in V2's colors. Every status is a symbol and a word,
/// never color alone.
enum V2SessionStatus: Equatable {
    case running
    case approval
    case voice
    case scheduled
    case job
    case source(SessionSource)
    case none

    init(liveStatus: SessionLiveStatus?, category: SessionSource) {
        switch liveStatus {
        case .needsInput?: self = .approval
        case .working?: self = .running
        case nil:
            switch category {
            case .voice: self = .voice
            case .cron: self = .scheduled
            case .voiceJob: self = .job
            case .chat: self = .none
            default: self = .source(category)
            }
        }
    }

    var symbol: String? {
        switch self {
        case .running: return nil
        case .approval: return "checkmark.shield.fill"
        case .voice: return "waveform"
        case .scheduled: return "clock.fill"
        case .job: return "bolt.horizontal.circle.fill"
        case .source(let source): return source.iconName
        case .none: return nil
        }
    }

    var color: Color {
        switch self {
        case .running: return .conduitAccent
        case .approval: return .conduitAttention
        case .voice: return .conduitAura
        case .scheduled: return .conduitScheduled
        case .job: return .conduitAura
        case .source(let source): return source.color
        case .none: return .secondary
        }
    }

    /// The trailing action word, for the two states that ask for attention.
    var actionWord: String? {
        switch self {
        case .running: return AppLocalization.string("Running")
        case .approval: return AppLocalization.string("Approve")
        default: return nil
        }
    }

    /// What VoiceOver says for the glyph.
    var accessibilityWord: String? {
        switch self {
        case .running: return AppLocalization.string("Running")
        case .approval: return AppLocalization.string("Needs approval")
        case .voice: return AppLocalization.string("Voice")
        case .scheduled: return AppLocalization.string("Scheduled")
        case .job: return AppLocalization.string("Voice Jobs")
        case .source(let source): return source.label
        case .none: return nil
        }
    }
}

/// The status glyph: a gold spinner while running, else the status symbol.
struct V2StatusGlyph: View {
    let status: V2SessionStatus

    var body: some View {
        Group {
            if status == .running {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Color.conduitAccent)
            } else if let symbol = status.symbol {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .conduitFixedGlyph()
                    .foregroundStyle(status.color)
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

struct V2SessionRow: View {
    let title: String
    let time: String
    let preview: String
    let status: V2SessionStatus
    var isUnread = false
    var isPinned = false
    var isSelected = false
    /// Project pages draw the status glyph ahead of the title, in the unread
    /// column, instead of ahead of the preview.
    var leadingGlyph = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // The unread column: always reserved, so titles align.
            ZStack {
                if leadingGlyph && status != .none {
                    V2StatusGlyph(status: status)
                } else if isUnread {
                    Circle()
                        .fill(Color.conduitAccent)
                        .frame(width: 7, height: 7)
                }
            }
            .frame(width: leadingGlyph ? 20 : 12)
            .frame(minHeight: 21)
            .padding(.trailing, leadingGlyph ? 8 : 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    Spacer(minLength: 4)
                    Text(time)
                        .font(.footnote)
                        .foregroundStyle(Color.primary.opacity(0.45))
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                HStack(alignment: .center, spacing: 5) {
                    if status != .none && !leadingGlyph {
                        V2StatusGlyph(status: status)
                    }
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary.opacity(0.58))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !leadingGlyph, let word = status.actionWord {
                        Text(word)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(status.color)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
            }
        }
        .padding(.vertical, 9)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                Color.primary.opacity(0.05)
            }
        }
        .contentShape(Rectangle())
        .dynamicTypeSize(...DynamicTypeSize.listRowCap)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(accessibilityValue))
    }

    private var accessibilityValue: String {
        [
            isUnread ? AppLocalization.string("Unread") : nil,
            isPinned ? AppLocalization.string("Pinned") : nil,
            status.accessibilityWord,
            preview.isEmpty ? nil : preview,
            time.isEmpty ? nil : time
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

/// The 0.5 pt hairline under a row, inset to the text column.
struct V2RowDivider: View {
    var leadingInset: CGFloat = 32

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.09))
            .frame(height: 0.5)
            .padding(.leading, leadingInset)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Plain V2 list chrome: no background, no system separator, the row's
    /// own hairline, full-width insets.
    func v2ListRow(divider: Bool = true, dividerInset: CGFloat = 32) -> some View {
        self
            .overlay(alignment: .bottom) {
                if divider { V2RowDivider(leadingInset: dividerInset) }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }
}

extension AppState {
    /// The second line of a session row: the listing's preview, else what
    /// the old row showed there (a saved call's engine, the call a job came
    /// from), else the model.
    func v2RowPreview(for session: SessionSummary) -> String {
        if let preview = session.preview, !preview.isEmpty { return preview }
        return voiceSessionDetail(for: session) ?? session.model
    }

    func v2RowStatus(for session: SessionSummary) -> V2SessionStatus {
        V2SessionStatus(liveStatus: sessionLiveStatus(session), category: sessionCategory(for: session))
    }
}
