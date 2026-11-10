//
//  PresentedConfirmPanel.swift
//  Conduit
//
//  The confirmation Hermes asks this iPhone to present (PresentedScreens.swift):
//  a strong-glass panel from the bottom, only as tall as its content, with
//  the title, a preview of what will happen, then Edit, Not now and a gold
//  primary action right under it. Over a voice call
//  it also says the user can just answer out loud. A room's ask (Linked
//  Rooms, Ask me first) names its room and offers Say instead, Don't share
//  and Share, Say instead typed right here. A Link's ask (a linked person's
//  Hermes asks yours) names them the same way, with Share only when there's
//  an answer to share. Run work's ask (your agent starts work for a room)
//  offers Change it, Don't start and Start.
//

import SwiftUI

struct PresentedConfirmOverlay: View {
    @ObservedObject var sync: PresentedScreensSync
    /// Over a voice call: the hint to answer out loud, and no Edit (that
    /// leaves the call for the chat).
    var inCall = false
    let onAnswer: (PresentedConfirm, PresentedConfirmOutcome) -> Void
    var onEdit: ((PresentedConfirm) -> Void)?
    /// A room's or a Link's ask answered with what to say instead.
    var onSayInstead: ((PresentedConfirm, String) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            if let prompt = sync.current {
                PresentedConfirmPanel(
                    prompt: prompt,
                    inCall: inCall,
                    onAnswer: { onAnswer(prompt, $0) },
                    // Directions have nothing to edit; a room's or a Link's ask says what to say instead here,
                    // never in a hidden chat.
                    onEdit: prompt.maps == nil && !prompt.isAsk
                        ? onEdit.map { edit in { () -> Void in edit(prompt) } } : nil,
                    onSayInstead: prompt.isAsk ? onSayInstead.map { say in { text in say(prompt, text) } } : nil
                )
                .id(prompt.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: sync.current?.id)
        // Leaves when its time runs out, not at the next exchange.
        .task(id: sync.current?.id) {
            guard let expires = sync.current?.expiresAt else { return }
            let wait = expires.timeIntervalSinceNow
            if wait > 0 {
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            }
            sync.dropExpired()
        }
    }
}

struct PresentedConfirmPanel: View {
    let prompt: PresentedConfirm
    let inCall: Bool
    let onAnswer: (PresentedConfirmOutcome) -> Void
    let onEdit: (() -> Void)?
    var onSayInstead: ((String) -> Void)?

    @State private var sayingInstead = false
    /// The preview's own height, so its box is only as tall as its text
    /// (up to `maxPreviewHeight`, then it scrolls) (issue 2086).
    @State private var previewHeight: CGFloat = 0
    private static let maxPreviewHeight: CGFloat = 220
    @State private var instead = ""
    @FocusState private var insteadFocused: Bool

    private var preview: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: prompt.preview, options: options)) ?? AttributedString(prompt.preview)
    }

    private var spokenHint: String {
        if let phrase = prompt.spokenYes.first {
            return AppLocalization.string("Or just say “\(phrase)”")
        }
        return AppLocalization.string("Or just say yes")
    }

    /// Who asks: a room's agent, a linked person's Hermes, or Hermes.
    private var asker: String {
        if let name = prompt.room?.name, !name.isEmpty {
            return AppLocalization.string("Asked in \(name)")
        }
        if let link = prompt.link {
            return link.name.isEmpty ? AppLocalization.string("A linked person's Hermes asks")
                : AppLocalization.string("\(link.name)'s Hermes asks")
        }
        return AppLocalization.string("Hermes asks")
    }

    /// A Link's question has nothing to share: it's not answered.
    private var declineLabel: String {
        if !prompt.canConfirm { return AppLocalization.string("Don't answer") }
        // A send to running work isn't a start.
        if prompt.room?.work == true {
            return prompt.actionLabel == "Send" ? AppLocalization.string("Not now") : AppLocalization.string("Don't start")
        }
        return prompt.isAsk ? AppLocalization.string("Don't share") : AppLocalization.string("Not now")
    }

    private var askerSymbol: String {
        if prompt.link != nil { return "link" }
        return prompt.room == nil ? "checkmark.shield" : "person.2"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(verbatim: asker)
            } icon: {
                Image(systemName: askerSymbol)
            }
            .scaledFont(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            Text(verbatim: prompt.title)
                .scaledFont(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            if !prompt.preview.isEmpty {
                ScrollView {
                    Text(preview)
                        .scaledFont(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { previewHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                // A ScrollView (and a frame with only a maximum) takes all the
                // height it's offered, which left a short preview's box mostly
                // empty; it fits the text instead.
                .frame(height: min(max(previewHeight, 1), Self.maxPreviewHeight))
                .padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            // A question has nothing to say yes to, and room work with no
            // phrase takes no spoken yes at all (only a tap).
            if inCall, prompt.canConfirm, prompt.room?.work != true || !prompt.spokenYes.isEmpty {
                Label(spokenHint, systemImage: "waveform")
                    .scaledFont(.footnote)
                    .foregroundStyle(Color.conduitAura)
            }

            if sayingInstead {
                sayInsteadField
            } else {
                // The buttons sit right under the preview. Too narrow for one
                // row (a folded screen, larger text): the secondary buttons
                // keep a row and the primary goes under them, never a spacer
                // that would stretch the panel to the top (issue 2086).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        secondaryButtons
                        Spacer(minLength: 0)
                        primaryButton
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) { secondaryButtons }
                        primaryButton
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        secondaryButtons
                        primaryButton
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 560, alignment: .leading)
        .conduitGlassControl(cornerRadius: 38, interactive: false)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onAppear {
            if prompt.isAsk {
                AccessibilityNotification.Announcement("\(asker). \(prompt.title)").post()
            } else {
                AccessibilityNotification.Announcement(AppLocalization.string("Hermes asks: \(prompt.title)")).post()
            }
        }
    }

    /// What your agent says in the room, or to the linked person's Hermes,
    /// instead, typed here.
    private var sayInsteadField: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(prompt.room?.work == true ? AppLocalization.string("What it should do instead")
                      : AppLocalization.string("What to say instead"), text: $instead, axis: .vertical)
                .lineLimit(1...5)
                .focused($insteadFocused)
                .padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onChange(of: instead) { _, text in
                    if text.count > PresentedScreensSync.maxEditText {
                        instead = String(text.prefix(PresentedScreensSync.maxEditText))
                    }
                }
            HStack(spacing: 10) {
                Button {
                    Haptics.selection()
                    sayingInstead = false
                } label: {
                    Text("Cancel")
                        .scaledFont(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 44)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(PressableButtonStyle())
                Spacer(minLength: 0)
                Button {
                    Haptics.medium()
                    onSayInstead?(instead)
                } label: {
                    Text("Send")
                        .scaledFont(.body.weight(.semibold))
                        .foregroundStyle(Color.conduitBackgroundColor)
                        .frame(minWidth: 96, minHeight: 44)
                        .padding(.horizontal, 12)
                        .background(Color.conduitAccent, in: Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(instead.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { insteadFocused = true }
    }

    /// Say instead or Edit, and the decline.
    @ViewBuilder
    private var secondaryButtons: some View {
        if onSayInstead != nil {
            Button {
                Haptics.selection()
                sayingInstead = true
            } label: {
                Text(prompt.room?.work == true ? AppLocalization.string("Change it") : AppLocalization.string("Say instead"))
                    .scaledFont(.body.weight(.semibold))
                    .frame(minWidth: 64, minHeight: 44)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(PressableButtonStyle())
            .conduitGlassControl(cornerRadius: 22)
        } else if let onEdit {
            Button {
                Haptics.selection()
                onEdit()
            } label: {
                Text("Edit")
                    .scaledFont(.body.weight(.semibold))
                    .frame(minWidth: 64, minHeight: 44)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(PressableButtonStyle())
            .conduitGlassControl(cornerRadius: 22)
        }
        Button {
            Haptics.selection()
            onAnswer(.declined)
        } label: {
            Text(declineLabel)
                .scaledFont(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minHeight: 44)
                .padding(.horizontal, 8)
        }
        .buttonStyle(PressableButtonStyle())
    }

    @ViewBuilder
    private var primaryButton: some View {
        // A Link's question has no answer to Share: Say instead answers it.
        if prompt.canConfirm {
            Button {
                Haptics.medium()
                onAnswer(.confirmed)
            } label: {
                Text(verbatim: prompt.actionLabel)
                    .scaledFont(.body.weight(.semibold))
                    .foregroundStyle(Color.conduitBackgroundColor)
                    .frame(minWidth: 96, minHeight: 44)
                    .padding(.horizontal, 12)
                    .background(Color.conduitAccent, in: Capsule())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityHint(Text(verbatim: prompt.title))
        }
    }
}
