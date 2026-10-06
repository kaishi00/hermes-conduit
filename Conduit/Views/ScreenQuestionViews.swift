//
//  ScreenQuestionViews.swift
//  Conduit
//
//  Ask Hermes About Screen: the screenshot a voice conversation will ask
//  about, shown over the call, and its setup page in Settings.
//

import SwiftUI

/// Over a voice sheet: the screenshot waiting on the call's chat. Its
/// remove button throws it away, so it never leaves the phone.
struct ScreenQuestionVoiceBanner: View {
    let screenshot: Attachment?
    let onDiscard: () -> Void
    /// Set when the screenshot joined a chat already in use.
    var onNewChat: (() -> Void)? = nil

    var body: some View {
        if let screenshot {
            VStack(alignment: .leading, spacing: 6) {
                Text("Asking about this screenshot")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ComposerAttachmentChip(attachment: screenshot, canRemove: true, onRemove: onDiscard)
                    if let onNewChat {
                        ScreenshotNewChatButton(action: onNewChat)
                    }
                }
            }
            // One region for VoiceOver: the caption with the chip, its
            // remove button and New Chat.
            .accessibilityElement(children: .contain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
        }
    }
}

/// "New Chat" beside a screenshot that joined a chat already in use: it
/// moves the screenshot, and voice when it's open, to a fresh chat.
struct ScreenshotNewChatButton: View {
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Label("New Chat", systemImage: "square.and.pencil")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.conduitAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.conduitAccent.opacity(0.09), in: Capsule())
                // A full-size tap target without growing the pill.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(AppLocalization.string("Moves the screenshot to a new chat."))
        .accessibilityIdentifier("screenQuestion.newChat")
    }
}

/// Settings › Ask Hermes About Screen: what a press does, and how to get
/// a new chat instead of the recent one.
struct ScreenQuestionHowItWorksSection: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared

    var body: some View {
        ConduitSettingsSection(
            title: AppLocalization.string("How it works"),
            symbol: "text.bubble",
            tint: .conduitAccent
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Label("The screenshot opens in your voice mode. Close voice to type instead; the screenshot stays attached.", systemImage: "waveform")
                Label("It joins the chat you used in the last 5 minutes, or a new chat. Tap New Chat beside the screenshot to move it to a fresh one.", systemImage: "square.and.pencil")
                Label("To always use a new chat, open the shortcut in Shortcuts, tap Show More, and set Chat to New Chat.", systemImage: "slider.horizontal.3")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// Settings › Ask Hermes About Screen: getting the shortcut onto the
/// Action Button (or another trigger), and whether it has run. A
/// screenshot opens in voice; closing voice leaves the keyboard.
struct ScreenQuestionSettingsSection: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var isOpeningShortcut = false
    @State private var shortcutTask: Task<Void, Never>?
    @State private var lastUsed = ScreenQuestionUsage.lastUsed()

    var body: some View {
        ConduitSettingsSection(
            title: AppLocalization.string("Setup"),
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
        }
        .onAppear { lastUsed = ScreenQuestionUsage.lastUsed() }
        // Left before the link resolved: nothing opens later.
        .onDisappear {
            shortcutTask?.cancel()
            shortcutTask = nil
            isOpeningShortcut = false
        }
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
                .accessibilityAddTraits(.isHeader)
            Text("Open Settings, then Action Button. Swipe to Shortcut and choose Ask Hermes About Screen. The Action Button is on iPhone 15 Pro and later.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var otherWaysStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Other ways to run it")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
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
        shortcutTask?.cancel()
        shortcutTask = Task { @MainActor in
            let url = await ScreenQuestionShortcutLink.resolve()
            guard !Task.isCancelled else { return }
            isOpeningShortcut = false
            shortcutTask = nil
            openURL(url)
        }
    }
}
