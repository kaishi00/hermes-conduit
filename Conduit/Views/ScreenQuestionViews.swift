//
//  ScreenQuestionViews.swift
//  Conduit
//
//  Ask Hermes About Screen in voice: the screenshot a voice conversation
//  will ask about, shown over the call, and the "Opens with" setting.
//

import SwiftUI

/// Over a voice sheet: the screenshot waiting on the call's chat. Its
/// remove button throws it away, so it never leaves the phone.
struct ScreenQuestionVoiceBanner: View {
    let screenshot: Attachment?
    let onDiscard: () -> Void

    var body: some View {
        if let screenshot {
            VStack(alignment: .leading, spacing: 6) {
                Text("Asking about this screenshot")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ComposerAttachmentChip(attachment: screenshot, canRemove: true, onRemove: onDiscard)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
        }
    }
}

/// Voice settings: how a screenshot chat takes the question when the
/// shortcut doesn't say.
struct ScreenQuestionSettingsSection: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @AppStorage(ScreenQuestionPreferences.startWithKey) private var startWith = ScreenQuestionStart.voice.rawValue

    var body: some View {
        ConduitSettingsSection(
            title: AppLocalization.string("Ask Hermes About Screen"),
            symbol: "camera.viewfinder",
            tint: .conduitAccent
        ) {
            Picker("Opens with", selection: $startWith) {
                Text("Voice").tag(ScreenQuestionStart.voice.rawValue)
                Text("Keyboard").tag(ScreenQuestionStart.keyboard.rawValue)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("voice.screenQuestionStartWith")
            Text("When the Ask Hermes About Screen shortcut runs without a question, Conduit opens the chat with the screenshot attached and starts your voice mode, or the keyboard.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
