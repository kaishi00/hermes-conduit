//
//  V2SessionRow.swift
//  Conduit
//
//  The V2 session row: no card, two lines, about 66 pt tall, with more room
//  between rows than between a row's own lines so each conversation reads
//  as one block. A Chats row leads with a round icon for where the
//  conversation came from, the gold unread dot on its corner. Line one is
//  the title and time, with a star before the time on a starred chat; line
//  two a dimmer one-line preview, and a status glyph and action word only
//  when the row needs one (Running, Approve).
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

/// A Chats row's icon: where the conversation came from, in that source's
/// color on a faint disc of it, with the gold unread dot on its corner.
struct V2SessionIcon: View {
    let source: SessionSource
    var isUnread = false

    var body: some View {
        Image(systemName: symbol)
            .font(.callout.weight(.semibold))
            .conduitFixedGlyph()
            .foregroundStyle(tint)
            .frame(width: 38, height: 38)
            .background(tint.opacity(0.16), in: Circle())
            .overlay(alignment: .topTrailing) {
                if isUnread {
                    Circle()
                        .fill(Color.conduitAccent)
                        .frame(width: 12, height: 12)
                        .offset(x: 1, y: -1)
                }
            }
            .accessibilityHidden(true)
    }

    /// The disc is already a circle, so a job gets the plain bolt rather
    /// than the circled one used elsewhere.
    private var symbol: String {
        switch source {
        case .voiceJob: return "bolt.horizontal.fill"
        default: return source.iconName
        }
    }

    private var tint: Color {
        V2SessionStatus(liveStatus: nil, category: source).color
    }
}

struct V2SessionRow: View {
    /// Where a Chats row's text starts (16 pt in, the 38 pt icon, 12 pt):
    /// its hairline and nest summary line up here.
    static let iconTextInset: CGFloat = 66

    let title: String
    let time: String
    let preview: String
    let status: V2SessionStatus
    var isUnread = false
    var isPinned = false
    var isStarred = false
    var isSelected = false
    /// Project pages draw the status glyph ahead of the title, in the unread
    /// column, instead of ahead of the preview.
    var leadingGlyph = false
    /// Chats rows: the round icon for where the conversation came from (a
    /// waveform for a call, a bubble for a typed chat), carrying the unread
    /// dot. Nil keeps the narrow unread column (project pages).
    var icon: SessionSource? = nil
    /// A Chats row with its "3 jobs" summary under it: the summary sits
    /// close, as part of this row, rather than a row's gap away.
    var hasNestBelow = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: icon == nil ? .top : .center, spacing: 0) {
            if let icon {
                V2SessionIcon(source: icon, isUnread: isUnread)
                    .padding(.leading, 16)
                    .padding(.trailing, 12)
            } else {
                unreadColumn
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    Spacer(minLength: 4)
                    if isStarred {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.conduitAccent)
                            .accessibilityHidden(true)
                    }
                    Text(time)
                        .font(.footnote)
                        .foregroundStyle(Color.primary.opacity(0.45))
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                HStack(alignment: .center, spacing: 5) {
                    if showsLineGlyph {
                        V2StatusGlyph(status: status)
                    }
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary.opacity(0.5))
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
        .padding(.top, 13)
        .padding(.bottom, hasNestBelow ? 4 : 13)
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

    /// The glyph before the preview. Beside an icon that already names the
    /// source, only the live states (running, waiting on approval) keep one.
    private var showsLineGlyph: Bool {
        guard status != .none, !leadingGlyph else { return false }
        return icon == nil || status == .running || status == .approval
    }

    /// Without an icon: the narrow unread column, always reserved so titles
    /// align.
    private var unreadColumn: some View {
        ZStack {
            if leadingGlyph && status != .none {
                V2StatusGlyph(status: status)
                    .overlay(alignment: .topTrailing) {
                        // Unread still shows beside a status glyph.
                        if isUnread {
                            Circle()
                                .fill(Color.conduitAccent)
                                .frame(width: 8, height: 8)
                                .offset(x: 4, y: -3)
                        }
                    }
            } else if isUnread {
                Circle()
                    .fill(Color.conduitAccent)
                    .frame(width: 10, height: 10)
            }
        }
        .frame(width: leadingGlyph ? 20 : 12)
        .frame(minHeight: 21)
        // A row without an icon starting at the screen edge keeps the dot
        // in from it. A project page draws its own thread line there.
        .padding(.leading, leadingGlyph ? 0 : 16)
        .padding(.trailing, leadingGlyph ? 8 : 4)
    }

    private var accessibilityValue: String {
        [
            isUnread ? AppLocalization.string("Unread") : nil,
            isPinned ? AppLocalization.string("Pinned") : nil,
            isStarred ? AppLocalization.string("Starred") : nil,
            status.accessibilityWord,
            preview.isEmpty ? nil : preview,
            time.isEmpty ? nil : time
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

/// A chat the search found by its messages: the title, then up to two lines
/// of the matching text with the matched words picked out.
struct V2ContentMatchRow: View {
    let title: String
    let time: String
    let snippet: SessionSearchSnippet
    var isUnread = false
    var isStarred = false
    var isSelected = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ZStack {
                if isUnread {
                    Circle()
                        .fill(Color.conduitAccent)
                        .frame(width: 7, height: 7)
                }
            }
            .frame(width: 12)
            .frame(minHeight: 21)
            .padding(.trailing, 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    Spacer(minLength: 4)
                    if isStarred {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.conduitAccent)
                            .accessibilityHidden(true)
                    }
                    Text(time)
                        .font(.footnote)
                        .foregroundStyle(Color.primary.opacity(0.45))
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                if !snippet.runs.isEmpty {
                    Text(snippet.attributed())
                        .font(.subheadline)
                        .foregroundStyle(Color.primary.opacity(0.58))
                        .lineLimit(2)
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
            isStarred ? AppLocalization.string("Starred") : nil,
            snippet.plainText.isEmpty ? nil : snippet.plainText,
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
            .fill(Color.primary.opacity(0.14))
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
        if let preview = session.preview {
            let plain = PreviewText.plain(preview)
            if !plain.isEmpty { return plain }
        }
        return voiceSessionDetail(for: session) ?? session.model
    }

    func v2RowStatus(for session: SessionSummary) -> V2SessionStatus {
        V2SessionStatus(liveStatus: sessionLiveStatus(session), category: sessionCategory(for: session))
    }
}
