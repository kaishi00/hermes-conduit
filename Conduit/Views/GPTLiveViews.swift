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
}

struct GPTLiveSettingsSection: View {
    let model: GPTLiveSettingsModel
    @State private var enabled: Bool
    /// Empty is the host's voice (a Picker tag can't be nil).
    @State private var voice: String
    @State private var memory: Bool
    @State private var personality: Bool
    @State private var status: String?
    @State private var isAvailable: Bool?
    @State private var isChecking = false

    init(model: GPTLiveSettingsModel) {
        self.model = model
        _enabled = State(initialValue: model.enabled)
        _voice = State(initialValue: model.voice ?? "")
        _memory = State(initialValue: model.memory)
        _personality = State(initialValue: model.personality)
    }

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("GPT-Live"), symbol: "waveform.circle", tint: .conduitAccent) {
            Toggle("Use GPT-Live for voice", isOn: Binding(
                get: { enabled },
                set: { requested in
                    enabled = requested
                    model.setEnabled(requested)
                    if requested { Task { await check() } }
                }
            ))
            Text("Talk with GPT-Live on the ChatGPT subscription your Hermes server is signed in to, instead of the Hermes speech pipeline. Hermes still does the work: GPT-Live hands requests to background jobs on this profile. The sign-in stays on your Hermes server, and it never falls back to API billing. Turning this on turns Gemini Live off.")
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
                Picker("Voice", selection: Binding(
                    get: { voice },
                    set: { chosen in
                        voice = chosen
                        model.setVoice(chosen.isEmpty ? nil : chosen)
                        // The status line names the voice in use.
                        if status != nil { Task { await check() } }
                    }
                )) {
                    Text("Server default").tag("")
                    let options = GPTLiveVoice.all
                    ForEach(options) { option in
                        Text(verbatim: option.label).tag(option.name)
                    }
                    // A voice saved by a newer build that this one doesn't list.
                    if !voice.isEmpty, !options.contains(where: { $0.name == voice }) {
                        Text(verbatim: voice).tag(voice)
                    }
                }
                .pickerStyle(.menu)
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
            }
        }
        .task { if enabled { await check() } }
        .onChange(of: model.enabled) { _, newValue in enabled = newValue }
        .onChange(of: model.voice) { _, newValue in voice = newValue ?? "" }
        .onChange(of: model.memory) { _, newValue in memory = newValue }
        .onChange(of: model.personality) { _, newValue in personality = newValue }
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
            status = error.localizedDescription
        }
    }
}

struct GPTLiveVoiceSheet: View {
    @ObservedObject var controller: GPTLiveConversationController
    let onClose: () -> Void
    let onRetry: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                VStack(spacing: 16) {
                    statusHeader
                    transcriptList
                    controls
                }
                .padding(16)
            }
            .navigationTitle("GPT-Live")
            .navigationBarTitleDisplayMode(.inline)
            // The status and new turns change without focus moving.
            .onChange(of: controller.phase) { _, _ in
                AccessibilityNotification.Announcement(statusText).post()
            }
            // Each turn once, with its final text (not the first fragment).
            .onChange(of: controller.finishedTurn) { _, turn in
                guard let turn else { return }
                AccessibilityNotification.Announcement(turn.speaker == .user
                    ? AppLocalization.string("You: \(turn.text)")
                    : AppLocalization.string("GPT-Live: \(turn.text)")).post()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
        }
    }

    private var statusHeader: some View {
        VStack(spacing: 6) {
            Image(systemName: statusSymbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.conduitAccent)
                .accessibilityHidden(true)
            Text(statusText)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let note = controller.voiceNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var transcriptList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(controller.transcript) { entry in
                    Text(entry.text)
                        .font(.body)
                        .foregroundStyle(entry.speaker == .user ? Color.primary : Color.conduitAccent)
                        .frame(maxWidth: .infinity, alignment: entry.speaker == .user ? .trailing : .leading)
                        .accessibilityLabel(entry.speaker == .user
                            ? AppLocalization.string("You: \(entry.text)")
                            : AppLocalization.string("GPT-Live: \(entry.text)"))
                }
            }
        }
        .defaultScrollAnchor(.bottom)
    }

    @ViewBuilder
    private var controls: some View {
        if case .failed = controller.phase {
            Button(action: onRetry) {
                Label("Try again", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .conduitGlassControl(cornerRadius: 18, tint: .conduitAccent.opacity(0.14))
        } else {
            Button {
                controller.setMicrophoneMuted(!controller.isMicrophoneMuted)
            } label: {
                Label(
                    controller.isMicrophoneMuted ? AppLocalization.string("Unmute microphone") : AppLocalization.string("Mute microphone"),
                    systemImage: controller.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill"
                )
                .frame(maxWidth: .infinity)
                .frame(height: 50)
            }
            .disabled(!controller.isActive || controller.isEnding)
            .conduitGlassControl(cornerRadius: 18, tint: .conduitAccent.opacity(0.14))
        }
    }

    private var statusSymbol: String {
        switch controller.phase {
        case .idle, .connecting: return "antenna.radiowaves.left.and.right"
        case .listening: return controller.isMicrophoneMuted ? "mic.slash" : "waveform"
        case .speaking: return "speaker.wave.3.fill"
        case .ending: return "hand.wave.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var statusText: String {
        switch controller.phase {
        case .idle: return AppLocalization.string("Not connected")
        case .connecting: return AppLocalization.string("Connecting to GPT-Live…")
        case .listening: return controller.isMicrophoneMuted ? AppLocalization.string("Microphone muted") : AppLocalization.string("Listening")
        case .speaking: return AppLocalization.string("Speaking")
        case .ending: return AppLocalization.string("Ending conversation…")
        case .failed(let message): return message
        }
    }
}
