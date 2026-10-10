//
//  GPTLiveViews.swift
//  Conduit
//
//  GPT-Live voice mode: its Voice settings section and its sheet.
//

import SwiftUI

/// What Voice settings needs to show the GPT-Live option.
struct GPTLiveSettingsModel {
    var enabled: Bool
    var setEnabled: (Bool) -> Void
    /// Asks the Hermes host whether it can start GPT-Live.
    var checkAvailability: () async -> Result<GPTLiveAvailability, Error>
    /// Voice name; nil is the voice set on the Hermes server.
    var voice: String? = nil
    var setVoice: (String?) -> Void = { _ in }
    var memory: Bool = false
    var setMemory: (Bool) -> Void = { _ in }
    var personality: Bool = false
    var setPersonality: (Bool) -> Void = { _ in }
    /// Save calls to the Hermes host's session history (Sessions > Voice).
    var saveCalls: Bool = true
    var setSaveCalls: (Bool) -> Void = { _ in }
}

struct GPTLiveSettingsSection: View {
    let model: GPTLiveSettingsModel
    /// Off when Voice settings picks the mode with its own picker: the
    /// section then only shows this mode's settings.
    let showsModeToggle: Bool
    @State private var enabled: Bool
    /// Empty is the host's voice (a Picker tag can't be nil).
    @State private var voice: String
    @State private var memory: Bool
    @State private var personality: Bool
    @State private var saveCalls: Bool
    @State private var status: String?
    @State private var isAvailable: Bool?
    @State private var isChecking = false

    init(model: GPTLiveSettingsModel, showsModeToggle: Bool = true) {
        self.model = model
        self.showsModeToggle = showsModeToggle
        // Shown by the mode picker only once this mode is picked, maybe
        // a render before the model catches up.
        _enabled = State(initialValue: model.enabled || !showsModeToggle)
        _voice = State(initialValue: model.voice ?? "")
        _memory = State(initialValue: model.memory)
        _personality = State(initialValue: model.personality)
        _saveCalls = State(initialValue: model.saveCalls)
    }

    private var voiceChoices: [(id: String, title: String)] {
        let options = GPTLiveVoice.all
        var choices = [(id: "", title: AppLocalization.string("Server default"))]
        choices += options.map { (id: $0.name, title: $0.label) }
        // A voice saved by a newer build that this one doesn't list.
        if !voice.isEmpty, !options.contains(where: { $0.name == voice }) {
            choices.append((id: voice, title: voice))
        }
        return choices
    }

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("GPT-Live"), symbol: "waveform.circle", tint: .conduitAccent) {
            if showsModeToggle {
                Toggle("Use GPT-Live for voice", isOn: Binding(
                    get: { enabled },
                    set: { requested in
                        enabled = requested
                        model.setEnabled(requested)
                        if requested { Task { await check() } }
                    }
                ))
            }
            Text("Talk with GPT-Live on the ChatGPT subscription your Hermes server is signed in to, instead of the Hermes speech pipeline. Hermes still does the work: GPT-Live hands requests to background jobs on this profile. The sign-in stays on your Hermes server, and it never falls back to API billing. Turning this on turns Gemini Live and Grok Live off.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LiveVoiceSetupLink(mode: .gpt)
            if enabled {
                HStack(spacing: 10) {
                    Circle()
                        .fill(isAvailable == true ? Color.green : (isAvailable == false ? Color.orange : Color.secondary))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(status ?? AppLocalization.string("Not checked yet"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Button {
                    Task { await check() }
                } label: {
                    Label(isChecking ? AppLocalization.string("Checking…") : AppLocalization.string("Check GPT-Live"), systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .disabled(isChecking)
                .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.14))
                ConduitMenuPicker(
                    value: voice,
                    choices: voiceChoices,
                    onSelect: { chosen in
                        voice = chosen
                        model.setVoice(chosen.isEmpty ? nil : chosen)
                        // The status line names the voice in use.
                        if status != nil { Task { await check() } }
                    }
                ) {
                    Text("Voice").foregroundStyle(.secondary)
                }
                Text("The voice GPT-Live speaks with. Server default uses the voice set on your Hermes server (voice.gpt_live in the profile's config). The model is set there too. Applies to the next conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Use Hermes memory", isOn: Binding(
                    get: { memory },
                    set: { requested in
                        memory = requested
                        model.setMemory(requested)
                    }
                ))
                Text("GPT-Live gets what your Hermes agent remembers about you. That memory is sent to OpenAI with the conversation. Applies to the next conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Use Hermes personality", isOn: Binding(
                    get: { personality },
                    set: { requested in
                        personality = requested
                        model.setPersonality(requested)
                    }
                ))
                Text("GPT-Live talks with the personality in this profile's SOUL.md. SOUL.md is sent to OpenAI with the conversation. Applies to the next conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Save calls to Sessions", isOn: Binding(
                    get: { saveCalls },
                    set: { requested in
                        saveCalls = requested
                        model.setSaveCalls(requested)
                    }
                ))
                Text("Each call's transcript is saved to your Hermes server's history and shows under Voice in Sessions, where you can read it or resume the call. Needs an up-to-date Hermes notifier plugin. Shared by every live voice mode. Applies to the next conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task { if enabled { await check() } }
        .onChange(of: model.enabled) { _, newValue in enabled = newValue }
        .onChange(of: model.voice) { _, newValue in voice = newValue ?? "" }
        .onChange(of: model.memory) { _, newValue in memory = newValue }
        .onChange(of: model.personality) { _, newValue in personality = newValue }
        .onChange(of: model.saveCalls) { _, newValue in saveCalls = newValue }
    }

    private func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        switch await model.checkAvailability() {
        case .success(let availability):
            isAvailable = availability.isAvailable
            switch availability {
            // The host reports its own voice; a voice chosen here overrides it.
            case .available(let modelName, let hostVoice?) where voice.isEmpty:
                status = AppLocalization.string("Available (\(modelName), voice \(hostVoice))")
            case .available(let modelName, _):
                status = AppLocalization.string("Available (\(modelName))")
            default:
                status = availability.userFacingReason
            }
        case .failure(let error):
            isAvailable = false
            status = UserFacingError.message(for: error)
        }
    }
}

struct GPTLiveVoiceSheet: View {
    @ObservedObject var controller: GPTLiveConversationController
    let jobs: VoiceBackgroundJobSupervisor
    let onClose: () -> Void
    let onRetry: () -> Void

    var body: some View {
        LiveVoiceCallSheet(
            title: "GPT-Live",
            phase: Self.callPhase(controller.phase, microphoneMuted: controller.isMicrophoneMuted),
            statusText: statusText,
            note: controller.voiceNote,
            transcript: controller.transcript,
            assistantLabel: { AppLocalization.string("GPT-Live: \($0)") },
            jobs: jobs,
            isMicrophoneMuted: controller.isMicrophoneMuted,
            isSpeakerMuted: controller.isSpeakerMuted,
            canMute: controller.isActive && !controller.isEnding,
            // GPT-Live cuts in on its own when you speak over it: no
            // Interrupt button.
            canInterrupt: false,
            onToggleMute: { controller.setMicrophoneMuted(!controller.isMicrophoneMuted) },
            onToggleSpeaker: { controller.setSpeakerMuted(!controller.isSpeakerMuted) },
            onEnd: onClose,
            onRetry: onRetry
        )
        // The status and new turns change without focus moving.
        .onChange(of: controller.phase) { _, _ in
            AccessibilityNotification.Announcement(statusText).post()
        }
        // Said outright: the status only mentions the mute while listening.
        .onChange(of: controller.isMicrophoneMuted) { _, muted in
            // A new call clearing the last one's mute isn't the user's doing.
            guard controller.isActive, controller.phase != .connecting else { return }
            AccessibilityNotification.Announcement(muted
                ? AppLocalization.string("Microphone muted")
                : AppLocalization.string("Microphone unmuted")).post()
        }
        .onChange(of: controller.isSpeakerMuted) { _, muted in
            guard controller.isActive, controller.phase != .connecting else { return }
            AccessibilityNotification.Announcement(muted
                ? AppLocalization.string("Assistant silenced")
                : AppLocalization.string("Assistant's sound back on")).post()
        }
        .onChange(of: controller.voiceNote) { _, note in
            if let note { AccessibilityNotification.Announcement(note).post() }
        }
        // Each turn once, with its final text (not the first fragment).
        .onChange(of: controller.finishedTurn) { _, turn in
            guard let turn else { return }
            AccessibilityNotification.Announcement(turn.speaker == .user
                ? AppLocalization.string("You: \(turn.text)")
                : AppLocalization.string("GPT-Live: \(turn.text)")).post()
        }
    }

    static func callPhase(_ phase: GPTLiveConversationController.Phase, microphoneMuted: Bool) -> LiveVoiceCallPhase {
        switch phase {
        case .idle: return .idle
        case .connecting: return .connecting
        case .listening: return microphoneMuted ? .muted : .listening
        case .speaking: return .speaking
        case .paused: return .muted
        case .ending: return .ending
        case .failed: return .failed
        }
    }

    private var statusText: String {
        switch controller.phase {
        case .idle: return AppLocalization.string("Not connected")
        case .connecting: return AppLocalization.string("Connecting to GPT-Live…")
        case .listening: return controller.isMicrophoneMuted ? AppLocalization.string("Microphone muted") : AppLocalization.string("Listening")
        case .speaking: return controller.isSpeakerMuted ? AppLocalization.string("Speaking, silenced") : AppLocalization.string("Speaking")
        case .paused: return AppLocalization.string("Paused while another sound plays")
        case .ending: return AppLocalization.string("Ending conversation…")
        case .failed(let message): return message
        }
    }
}
