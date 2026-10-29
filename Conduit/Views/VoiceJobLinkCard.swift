//
//  VoiceJobLinkCard.swift
//  Conduit
//
//  A saved voice call's "Started a background job" or "Asked the chat"
//  line, drawn as a card that opens the job's chat (or the chat) instead
//  of a sentence ending in an "Open job" link. Used in the saved call's
//  chat and in the transcript of a call kept with its chat.
//

import SwiftUI

struct VoiceJobLinkCard: View {
    let note: VoiceJobLinkNote
    /// The line's raw timestamp; nil where the transcript shows none.
    var timestamp: String? = nil
    let open: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var kicker: String {
        switch note.kind {
        case .job: return AppLocalization.string("Background job")
        case .chat: return AppLocalization.string("Sent to the chat")
        }
    }

    private var action: String {
        switch note.kind {
        case .job: return AppLocalization.string("Open job")
        case .chat: return AppLocalization.string("Open chat")
        }
    }

    private var symbol: String {
        switch note.kind {
        case .job: return "arrow.triangle.branch"
        case .chat: return "bubble.left.and.bubble.right.fill"
        }
    }

    private var time: String? {
        timestamp.flatMap(MessageTimestampFormatter.displayString(for:))
    }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.conduitAccent)
                    .frame(width: 32, height: 32)
                    .background(Color.conduitAccent.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    // Time under the kicker at the largest sizes, as the
                    // button moves under the title.
                    let header = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                        : AnyLayout(HStackLayout(spacing: 6))
                    header {
                        Text(verbatim: kicker)
                            .scaledFont(.caption2.weight(.bold))
                            .tracking(0.6)
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                        if let time {
                            Text(verbatim: time)
                                .scaledFont(.caption2.weight(.medium))
                                .foregroundStyle(.conduitTertiary)
                                .monospacedDigit()
                        }
                    }
                    Text(verbatim: note.title)
                        .scaledFont(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    // At the largest text sizes the button goes under the
                    // title, which would otherwise get a word per line.
                    if dynamicTypeSize.isAccessibilitySize {
                        actionCapsule
                            .padding(.top, 4)
                    }
                }
                Spacer(minLength: 8)
                if !dynamicTypeSize.isAccessibilitySize {
                    actionCapsule
                }
            }
            .padding(14)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chatCard(cornerRadius: 18, tint: .conduitAccent.opacity(0.07))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.conduitAccent.opacity(0.16), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [kicker, note.title, time].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityHint(Text(verbatim: action))
        .accessibilityAddTraits(.isButton)
    }

    private var actionCapsule: some View {
        HStack(spacing: 3) {
            Text(verbatim: action)
                .scaledFont(.caption.weight(.semibold))
            Image(systemName: "chevron.right")
                .scaledFont(.caption2.weight(.bold))
                .accessibilityHidden(true)
        }
        .foregroundStyle(.conduitAccent)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.conduitAccent.opacity(0.12), in: Capsule())
        .fixedSize()
    }
}
