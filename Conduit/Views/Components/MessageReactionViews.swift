import SwiftUI

/// Reactions on a message, one chip per emoji (both authors picking the
/// same emoji share a chip with a count). The user's own reaction is
/// outlined in the accent colour, like Messages' Tapback.
struct MessageReactionChips: View {
    /// Re-renders the labels when the app language changes.
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let reactions: [MessageReaction]
    /// The agent's display name, for VoiceOver.
    let agentName: String
    /// Tapping a chip opens the picker on replies the user can react to.
    var onTap: (() -> Void)?

    struct ChipGroup: Equatable {
        let emoji: String
        let count: Int
        let includesUser: Bool
        let includesOthers: Bool
    }

    /// Chips in first-reaction order.
    static func groups(for reactions: [MessageReaction]) -> [ChipGroup] {
        var order: [String] = []
        var byEmoji: [String: [MessageReaction]] = [:]
        for reaction in reactions {
            if byEmoji[reaction.emoji] == nil { order.append(reaction.emoji) }
            byEmoji[reaction.emoji, default: []].append(reaction)
        }
        return order.map { emoji in
            let entries = byEmoji[emoji] ?? []
            return ChipGroup(
                emoji: emoji,
                count: entries.count,
                includesUser: entries.contains(where: \.isFromUser),
                includesOthers: entries.contains(where: { !$0.isFromUser })
            )
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.groups(for: reactions), id: \.emoji) { group in
                chip(group)
            }
        }
    }

    @ViewBuilder
    private func chip(_ group: ChipGroup) -> some View {
        let label = HStack(spacing: 2) {
            Text(group.emoji)
                .font(.subheadline)
            if group.count > 1 {
                Text(verbatim: "\(group.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.conduitSurface))
        .overlay(
            Capsule().strokeBorder(
                group.includesUser ? Color.conduitAccent.opacity(0.7) : Color.secondary.opacity(0.2),
                lineWidth: 1
            )
        )

        if let onTap {
            // The capsule stays small; the touch area grows to 44 pt tall
            // without adding space under the bubble.
            Button(action: onTap) {
                label
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .padding(.vertical, -8)
            }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(for: group))
                .accessibilityHint(AppLocalization.string("Change your reaction"))
        } else {
            label
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel(for: group))
        }
    }

    private func accessibilityLabel(for group: ChipGroup) -> String {
        let emoji = group.emoji
        if group.includesUser && group.includesOthers {
            return AppLocalization.string("You and \(agentName) reacted \(emoji)")
        }
        if group.includesUser {
            return AppLocalization.string("You reacted \(emoji)")
        }
        return AppLocalization.string("\(agentName) reacted \(emoji)")
    }
}

/// The Tapback bar: six reactions in a row. Picking the one already chosen
/// takes it back.
struct TapbackPicker: View {
    /// Re-renders the labels when the app language changes.
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let selected: String?
    let onPick: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MessageReaction.tapbacks, id: \.self) { emoji in
                Button {
                    onPick(emoji)
                } label: {
                    Text(emoji)
                        .font(.title2)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(
                            Circle().fill(emoji == selected ? Color.conduitAccent.opacity(0.22) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    emoji == selected
                        ? AppLocalization.string("Remove reaction \(emoji)")
                        : AppLocalization.string("React with \(emoji)")
                )
                .accessibilityAddTraits(emoji == selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

/// The React control in a reply's action row; it hosts the Tapback bar.
/// `isPresented` is owned by the bubble so tapping a reaction chip opens
/// the same bar.
struct MessageReactButton: View {
    /// Re-renders the label when the app language changes.
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let message: ChatMessage
    @Binding var isPresented: Bool
    @EnvironmentObject private var appState: AppState

    private var mine: String? {
        message.reactions.first(where: \.isFromUser)?.emoji
    }

    var body: some View {
        let enabled = appState.canReact(to: message)
        Button {
            Haptics.light()
            isPresented = true
        } label: {
            Image(systemName: mine == nil ? "face.smiling" : "face.smiling.inverse")
                .font(.subheadline.weight(.semibold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .foregroundStyle(mine == nil ? Color.secondary : Color.conduitAccent)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(
            mine == nil
                ? AppLocalization.string("React to this response")
                : AppLocalization.string("Change your reaction")
        )
        .accessibilityAddTraits(mine == nil ? [] : .isSelected)
        // A turn starting while the bar is open makes a live reply
        // unaddressable; close the bar rather than let a pick do nothing.
        .onChange(of: enabled) { _, isEnabled in
            if !isEnabled { isPresented = false }
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            TapbackPicker(selected: mine) { emoji in
                isPresented = false
                Task { await appState.react(to: message.id, with: emoji) }
            }
            .presentationCompactAdaptation(.popover)
        }
    }
}
