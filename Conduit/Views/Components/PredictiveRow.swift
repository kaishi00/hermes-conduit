//
//  PredictiveRow.swift
//  Conduit
//
//  The one row above the composer where Predictive guesses show
//  (Predictive.swift): continuations of a paused draft (dashed, insert)
//  and whole messages (filled, send), best first. Typing folds it to a ✦
//  button instead of making it vanish.
//

import SwiftUI

struct PredictiveRow: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @ObservedObject var store: PredictiveStore
    let appState: AppState
    // A switch turned off takes its chips with it.
    @AppStorage(Predictive.repliesKey) private var repliesOn = false
    @AppStorage(Predictive.pauseKey) private var pauseOn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if store.isShowing, !visibleNext.isEmpty || !visibleReplies.isEmpty {
                if store.isFolded {
                    foldedButton
                } else {
                    row
                }
            }
        }
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: store.isShowing)
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: store.isFolded)
    }

    private var visibleNext: [Predictive.Guess] { pauseOn ? store.currentNext : [] }

    /// Whole messages: a reply's suggestions, or a paused draft's.
    private var visibleReplies: [Predictive.Guess] {
        let forDraft = !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (forDraft ? pauseOn : repliesOn) ? store.currentReplies : []
    }

    private var row: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                let next = visibleNext
                let replies = visibleReplies
                ForEach(Array(next.enumerated()), id: \.offset) { _, guess in
                    continuationChip(guess)
                }
                if !next.isEmpty, !replies.isEmpty {
                    Divider().frame(height: 22)
                }
                ForEach(Array(replies.enumerated()), id: \.offset) { index, guess in
                    replyChip(guess, isFirst: index == 0)
                }
                moreMenu
            }
            .padding(.horizontal, 14)
        }
        .frame(minHeight: 44)
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Suggestions"))
    }

    /// A whole message: tap sends it, long-press puts it in the composer.
    private func replyChip(_ guess: Predictive.Guess, isFirst: Bool) -> some View {
        HStack(spacing: 6) {
            // A tap sends it, so it shows all of it: never cut short with
            // an ellipsis, it wraps instead.
            WrapsPastWidth(maxWidth: 250) {
                Text(guess.text)
                    .multilineTextAlignment(.leading)
            }
            Image(systemName: "arrow.up")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.conduitAura)
                .accessibilityHidden(true)
        }
        .font(.subheadline)
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.conduitAura.opacity(isFirst ? 0.2 : 0.1)))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.conduitAura.opacity(isFirst ? 0.6 : 0.35), lineWidth: 1)
        )
        // A 44 pt target around the smaller capsule.
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture { send(guess.text) }
        .onLongPressGesture(minimumDuration: 0.4) { edit(guess.text) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Sends this message. Use the Edit action to change it first."))
        .accessibilityAction { send(guess.text) }
        .accessibilityAction(named: Text("Edit")) { edit(guess.text) }
    }

    /// The next words of the draft: tap puts them after it.
    private func continuationChip(_ guess: Predictive.Guess) -> some View {
        Text(verbatim: "…" + guess.text.trimmingCharacters(in: .whitespaces))
            .lineLimit(1)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.conduitAura.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .onTapGesture { insert(guess.text) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text("Adds these words to your message."))
            .accessibilityAction { insert(guess.text) }
    }

    private var moreMenu: some View {
        Menu {
            Button {
                appState.refreshPredictions()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Button {
                appState.hidePredictionsInOpenChat()
            } label: {
                Label("Hide for this chat", systemImage: "eye.slash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("More suggestion options"))
    }

    /// While typing: the guesses wait behind this button.
    private var foldedButton: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                Haptics.selection()
                store.unfold()
            } label: {
                Image(systemName: "sparkles")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.conduitAura)
                    .frame(width: 44, height: 32)
                    .background(Capsule().fill(Color.conduitAura.opacity(0.12)))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Show suggestions"))
        }
        .padding(.horizontal, 14)
        .transition(.opacity)
    }

    private func send(_ text: String) {
        guard !store.tapIsGuarded() else { return }
        appState.requestPredictiveComposer(.send, text: text)
    }

    private func edit(_ text: String) {
        guard !store.tapIsGuarded() else { return }
        Haptics.light()
        appState.requestPredictiveComposer(.edit, text: text)
    }

    private func insert(_ text: String) {
        guard !store.tapIsGuarded() else { return }
        Haptics.selection()
        appState.requestPredictiveComposer(.insert, text: text)
    }
}

/// Over a reply Hermes wrote on its own: "Hermes followed up", and a tap
/// shows why it chose to.
struct PredictiveFollowUpTag: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let why: String
    @State private var showsWhy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                showsWhy.toggle()
            } label: {
                Label("Hermes followed up", systemImage: "sparkle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.conduitAura)
            }
            .buttonStyle(.plain)
            .disabled(why.isEmpty)
            .accessibilityHint(Text("Hermes wrote this without a new message from you. Shows why."))
            if showsWhy, !why.isEmpty {
                Text(why)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Its content at its natural width up to `maxWidth`, and past that wrapped
/// to `maxWidth` at whatever height that takes. A horizontal scroll view
/// offers no width at all, so a plain `frame(maxWidth:)` there sizes text
/// for one line and then cuts it short.
private struct WrapsPastWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        return content.sizeThatFits(contentProposal(content))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        content.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }

    private func contentProposal(_ content: LayoutSubview) -> ProposedViewSize {
        let ideal = content.sizeThatFits(.unspecified).width
        return ProposedViewSize(width: min(ideal, maxWidth), height: nil)
    }
}
