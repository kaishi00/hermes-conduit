//
//  ScreenQuestionViews.swift
//  Conduit
//
//  Ask Hermes About Screen: the screenshot a voice conversation will ask
//  about, shown over the call, and the setup section in Voice settings.
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
            // One region for VoiceOver: the caption with the chip and its remove button.
            .accessibilityElement(children: .contain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
        }
    }
}

/// Voice settings: getting the shortcut onto the Action Button (or
/// another trigger), whether it has run, and how a screenshot chat takes
/// the question when the shortcut doesn't say.
struct ScreenQuestionSettingsSection: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @AppStorage(ScreenQuestionPreferences.startWithKey) private var startWith = ScreenQuestionStart.voice.rawValue
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var isOpeningShortcut = false
    @State private var lastUsed = ScreenQuestionUsage.lastUsed()

    var body: some View {
        ConduitSettingsSection(
            title: AppLocalization.string("Ask Hermes About Screen"),
            symbol: "camera.viewfinder",
            tint: .conduitAccent
        ) {
            Text("Press the Action Button in any app and Conduit opens with a screenshot of it, ready for your question.")
                .font(.caption)
                .foregroundStyle(.secondary)
            addShortcutStep
            actionButtonStep
            otherWaysStep
            lastUsedRow
            Divider()
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
        .onAppear { lastUsed = ScreenQuestionUsage.lastUsed() }
        // Back from running the shortcut: the row shows the run.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            lastUsed = ScreenQuestionUsage.lastUsed()
        }
    }

    private var addShortcutStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: openShortcut) {
                Label(
                    isOpeningShortcut ? AppLocalization.string("Opening…") : AppLocalization.string("Add the shortcut"),
                    systemImage: "plus.square.on.square"
                )
                .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .disabled(isOpeningShortcut)
            .accessibilityIdentifier("voice.screenQuestionAddShortcut")
            Text("Opens Shortcuts. Tap Add Shortcut there.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var actionButtonStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Put it on the Action Button")
                .font(.subheadline.weight(.semibold))
            Text("Open Settings, then Action Button. Swipe to Shortcut and choose Ask Hermes About Screen. The Action Button is on iPhone 15 Pro and later.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var otherWaysStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Other ways to run it")
                .font(.subheadline.weight(.semibold))
            Label("Siri: say “Ask Hermes About Screen”.", systemImage: "mic")
            Label("Back Tap: Settings, Accessibility, Touch, Back Tap.", systemImage: "hand.tap")
            Label("Control Center: add a Shortcut control and pick it.", systemImage: "switch.2")
            Label("Home Screen: in Shortcuts, touch and hold it, then Share, Add to Home Screen.", systemImage: "apps.iphone")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Conduit can't see the user's shortcuts; a run proves the shortcut ran.
    @ViewBuilder
    private var lastUsedRow: some View {
        if let lastUsed {
            HStack(spacing: 4) {
                Text("Last used")
                Text(lastUsed, format: .relative(presentation: .named))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        } else {
            Text("Not run yet. Once it runs, it shows here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func openShortcut() {
        isOpeningShortcut = true
        Task { @MainActor in
            let url = await ScreenQuestionShortcutLink.resolve()
            isOpeningShortcut = false
            openURL(url)
        }
    }
}
