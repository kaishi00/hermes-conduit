//
//  PresentedConfirmPanel.swift
//  Conduit
//
//  The confirmation Hermes asks this iPhone to present (PresentedScreens.swift):
//  a strong-glass panel from the bottom with the title, a preview of what
//  will happen, Edit, Not now and a gold primary action. Over a voice call
//  it also says the user can just answer out loud.
//

import SwiftUI

struct PresentedConfirmOverlay: View {
    @ObservedObject var sync: PresentedScreensSync
    /// Over a voice call: the hint to answer out loud, and no Edit (that
    /// leaves the call for the chat).
    var inCall = false
    let onAnswer: (PresentedConfirm, PresentedConfirmOutcome) -> Void
    var onEdit: ((PresentedConfirm) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            if let prompt = sync.current {
                PresentedConfirmPanel(
                    prompt: prompt,
                    inCall: inCall,
                    onAnswer: { onAnswer(prompt, $0) },
                    // Directions have nothing to edit.
                    onEdit: prompt.maps == nil ? onEdit.map { edit in { () -> Void in edit(prompt) } } : nil
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
                Text("Hermes asks")
            } icon: {
                Image(systemName: "checkmark.shield")
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
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 220)
                .padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            if inCall {
                Label(spokenHint, systemImage: "waveform")
                    .scaledFont(.footnote)
                    .foregroundStyle(Color.conduitAura)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buttons }
                VStack(alignment: .leading, spacing: 10) { buttons }
            }
        }
        .padding(20)
        .frame(maxWidth: 560, alignment: .leading)
        .conduitGlassControl(cornerRadius: 38, interactive: false)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onAppear {
            AccessibilityNotification.Announcement(AppLocalization.string("Hermes asks: \(prompt.title)")).post()
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if let onEdit {
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
            Text("Not now")
                .scaledFont(.body.weight(.semibold))
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
