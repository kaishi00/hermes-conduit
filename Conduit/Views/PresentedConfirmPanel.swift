//
//  PresentedConfirmPanel.swift
//  Conduit
//
//  The confirmation Hermes asks this iPhone to present (PresentedScreens.swift):
//  a strong-glass panel from the bottom with the title, a preview of what
//  will happen, Edit, Not now and a gold primary action. Over a voice call
//  it also says the user can just answer out loud. A room's ask (Linked
//  Rooms, Ask me first) names its room and offers Say instead, Don't share
//  and Share, Say instead typed right here.
//

import SwiftUI

struct PresentedConfirmOverlay: View {
    @ObservedObject var sync: PresentedScreensSync
    /// Over a voice call: the hint to answer out loud, and no Edit (that
    /// leaves the call for the chat).
    var inCall = false
    let onAnswer: (PresentedConfirm, PresentedConfirmOutcome) -> Void
    var onEdit: ((PresentedConfirm) -> Void)?
    /// A room's ask answered with what to say instead.
    var onSayInstead: ((PresentedConfirm, String) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            if let prompt = sync.current {
                PresentedConfirmPanel(
                    prompt: prompt,
                    inCall: inCall,
                    onAnswer: { onAnswer(prompt, $0) },
                    // Directions have nothing to edit; a room's ask says what to say instead here, never in
                    // the room's hidden chat.
                    onEdit: prompt.maps == nil && prompt.room == nil
                        ? onEdit.map { edit in { () -> Void in edit(prompt) } } : nil,
                    onSayInstead: prompt.room == nil ? nil : onSayInstead.map { say in { text in say(prompt, text) } }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                if let name = prompt.room?.name, !name.isEmpty {
                    Text(AppLocalization.string("Asked in \(name)"))
                } else {
                    Text("Hermes asks")
                }
            } icon: {
                Image(systemName: prompt.room == nil ? "checkmark.shield" : "person.2")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            Text(verbatim: prompt.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            if !prompt.preview.isEmpty {
                ScrollView {
                    Text(preview)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 220)
                .padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            if inCall {
                Label(spokenHint, systemImage: "waveform")
                    .font(.footnote)
                    .foregroundStyle(Color.conduitAura)
            }

            if sayingInstead {
                sayInsteadField
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { buttons }
                    VStack(alignment: .leading, spacing: 10) { buttons }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 560, alignment: .leading)
        .conduitGlassControl(cornerRadius: 38, interactive: false)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onAppear {
            if let name = prompt.room?.name, !name.isEmpty {
                AccessibilityNotification.Announcement("\(AppLocalization.string("Asked in \(name)")). \(prompt.title)").post()
            } else {
                AccessibilityNotification.Announcement(AppLocalization.string("Hermes asks: \(prompt.title)")).post()
            }
        }
    }

    /// What your agent says in the room instead, typed here.
    private var sayInsteadField: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(AppLocalization.string("What to say instead"), text: $instead, axis: .vertical)
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
                        .font(.body.weight(.semibold))
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
                        .font(.body.weight(.semibold))
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

    @ViewBuilder
    private var buttons: some View {
        if onSayInstead != nil {
            Button {
                Haptics.selection()
                sayingInstead = true
            } label: {
                Text(AppLocalization.string("Say instead"))
                    .font(.body.weight(.semibold))
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
                    .font(.body.weight(.semibold))
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
            Text(prompt.room == nil ? AppLocalization.string("Not now") : AppLocalization.string("Don't share"))
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minHeight: 44)
                .padding(.horizontal, 8)
        }
        .buttonStyle(PressableButtonStyle())
        Spacer(minLength: 0)
        Button {
            Haptics.medium()
            onAnswer(.confirmed)
        } label: {
            Text(verbatim: prompt.actionLabel)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.conduitBackgroundColor)
                .frame(minWidth: 96, minHeight: 44)
                .padding(.horizontal, 12)
                .background(Color.conduitAccent, in: Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityHint(Text(verbatim: prompt.title))
    }
}
