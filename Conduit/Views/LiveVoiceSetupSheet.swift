import SwiftUI

struct LiveVoiceSetupSheet: View {
    enum Mode {
        case gemini
        case qwen
        case gpt
        case grok

        var checkTitle: String {
            switch self {
            case .gemini: AppLocalization.string("Check Gemini Live")
            case .qwen: AppLocalization.string("Check Qwen Live")
            case .gpt: AppLocalization.string("Check GPT-Live")
            case .grok: AppLocalization.string("Check Grok Live")
            }
        }
    }

    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appLanguage = AppLanguageStore.shared

    var body: some View {
        NavigationStack {
            SettingsDetailContainer {
                Text(AppLocalization.string("Install the notifier if it is missing, or update your existing installation. Both commands target the Hermes gateway used by this profile."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                NotificationSetupCommand(
                    step: 1,
                    title: AppLocalization.string("Install the notifier"),
                    command: "hermes plugins install kaishi00/hermes-conduit-notifier --enable"
                )
                NotificationSetupCommand(
                    step: 1,
                    title: AppLocalization.string("Update the notifier"),
                    command: "hermes plugins update conduit_push"
                )

                modeInstructions

                NotificationSetupCommand(
                    step: 3,
                    title: AppLocalization.string("Restart the gateway"),
                    command: "hermes gateway restart"
                )

                Link(destination: URL(string: "https://github.com/kaishi00/hermes-conduit-notifier")!) {
                    Label(AppLocalization.string("Hermes notifier repository"), systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.medium))
                }
                .accessibilityHint(AppLocalization.string("Opens the notifier project on GitHub"))

                Label(
                    AppLocalization.string("Return to Voice settings, enable this mode if it is off, and tap \(mode.checkTitle) to check availability."),
                    systemImage: "arrow.uturn.backward"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .navigationTitle(AppLocalization.string("Live voice setup"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private var modeInstructions: some View {
        switch mode {
        case .gemini:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(verbatim: "2")
                        .font(.caption.weight(.bold))
                        .conduitFixedGlyph()
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.conduitAccent, in: Circle())
                    Text(AppLocalization.string("Add a Gemini API key"))
                        .font(.subheadline.weight(.semibold))
                }
                Text(AppLocalization.string("Add it in Voice settings under API key, or set GEMINI_API_KEY in the active Hermes profile’s .env file. The key stays on your Hermes server."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .qwen:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(verbatim: "2")
                        .font(.caption.weight(.bold))
                        .conduitFixedGlyph()
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.conduitAccent, in: Circle())
                    Text(AppLocalization.string("Add a Qwen API key"))
                        .font(.subheadline.weight(.semibold))
                }
                Text(AppLocalization.string("Set DASHSCOPE_API_KEY and CONDUIT_QWEN_LIVE_WORKSPACE on your Hermes profile. The permanent key stays on your server."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .gpt:
            VStack(alignment: .leading, spacing: 6) {
                NotificationSetupCommand(
                    step: 2,
                    title: AppLocalization.string("Sign in to OpenAI Codex"),
                    command: "hermes auth"
                )
                Text(AppLocalization.string("Choose OpenAI Codex when prompted. The sign-in stays on your Hermes server."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .grok:
            VStack(alignment: .leading, spacing: 6) {
                NotificationSetupCommand(
                    step: 2,
                    title: AppLocalization.string("Sign in to SuperGrok"),
                    command: "hermes auth add xai-oauth"
                )
                Text(AppLocalization.string("Sign in with your SuperGrok or X Premium+ account, or add an xAI key in Voice settings under API key instead. The sign-in and the key stay on your Hermes server."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct LiveVoiceSetupLink: View {
    let mode: LiveVoiceSetupSheet.Mode
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    @State private var showingSetup = false

    private var accessibilityTitle: String {
        switch mode {
        case .gemini: AppLocalization.string("Set up Gemini Live")
        case .qwen: AppLocalization.string("Set up Qwen Live")
        case .gpt: AppLocalization.string("Set up GPT-Live")
        case .grok: AppLocalization.string("Set up Grok Live")
        }
    }

    var body: some View {
        Button { showingSetup = true } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(AppLocalization.string("Requires Hermes notifier ·"))
                    .foregroundStyle(.secondary)
                Text(AppLocalization.string("Setup"))
                    .fontWeight(.semibold)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityHint(AppLocalization.string("Opens live voice setup instructions"))
        .sheet(isPresented: $showingSetup) {
            LiveVoiceSetupSheet(mode: mode)
        }
    }
}
