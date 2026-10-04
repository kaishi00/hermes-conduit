//
//  GrokLiveViews.swift
//  Conduit
//
//  Grok Live voice mode: its Voice settings section. The conversation
//  itself shows in Gemini Live's sheet, since both run on one controller.
//

import SwiftUI

/// What Voice settings needs to show the Grok Live option.
struct GrokLiveSettingsModel {
    var enabled: Bool
    var setEnabled: (Bool) -> Void
    /// Asks the Hermes host whether it can relay Grok Live.
    var checkAvailability: () async -> Result<GrokLiveAvailability, Error>
    var memory: Bool = false
    var setMemory: (Bool) -> Void = { _ in }
    var personality: Bool = false
    var setPersonality: (Bool) -> Void = { _ in }
    /// Save calls to the Hermes host's session history (Sessions > Voice).
    var saveCalls: Bool = true
    var setSaveCalls: (Bool) -> Void = { _ in }
    /// Talk over the model on the loudspeaker (echo-cancelling audio).
    var speakerBargeIn: Bool = false
    var setSpeakerBargeIn: (Bool) -> Void = { _ in }
}

struct GrokLiveSettingsSection: View {
    let model: GrokLiveSettingsModel
    /// Off when Voice settings picks the mode with its own picker: the
    /// section then only shows this mode's settings.
    let showsModeToggle: Bool
    @State private var enabled: Bool
    @State private var memory: Bool
    @State private var personality: Bool
    @State private var saveCalls: Bool
    @State private var speakerBargeIn: Bool
    @State private var status: String?
    @State private var isAvailable: Bool?
    @State private var isChecking = false

    init(model: GrokLiveSettingsModel, showsModeToggle: Bool = true) {
        self.model = model
        self.showsModeToggle = showsModeToggle
        // Shown by the mode picker only once this mode is picked, maybe
        // a render before the model catches up.
        _enabled = State(initialValue: model.enabled || !showsModeToggle)
        _memory = State(initialValue: model.memory)
        _personality = State(initialValue: model.personality)
        _saveCalls = State(initialValue: model.saveCalls)
        _speakerBargeIn = State(initialValue: model.speakerBargeIn)
    }

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Grok Live"), symbol: "waveform.circle", tint: .conduitAccent) {
            if showsModeToggle {
                Toggle("Use Grok Live for voice", isOn: Binding(
                    get: { enabled },
                    set: { requested in
                        enabled = requested
                        model.setEnabled(requested)
                        if requested { Task { await check() } }
                    }
                ))
            }
            Text("Talk with Grok Live, xAI's realtime voice model, instead of the Hermes speech pipeline. Hermes still does the work: Grok hands requests to background jobs on this profile. Your Hermes server connects to xAI with its SuperGrok sign-in (or its XAI_API_KEY), which stays on the server. Turning this on turns Gemini Live and GPT-Live off.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LiveVoiceSetupLink(mode: .grok)
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
                    Label(isChecking ? AppLocalization.string("Checking…") : AppLocalization.string("Check Grok Live"), systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .disabled(isChecking)
                .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.14))
                Text("The voice and model are set on your Hermes server (voice.grok_live in the profile's config).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Use Hermes memory", isOn: Binding(
                    get: { memory },
                    set: { requested in
                        memory = requested
                        model.setMemory(requested)
                    }
                ))
                Text("Grok Live gets what your Hermes agent remembers about you. That memory is sent to xAI with the conversation. Applies to the next conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Use Hermes personality", isOn: Binding(
                    get: { personality },
                    set: { requested in
                        personality = requested
                        model.setPersonality(requested)
                    }
                ))
                Text("Grok Live talks with the personality in this profile's SOUL.md. SOUL.md is sent to xAI with the conversation. Applies to the next conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Talk over it on the speaker", isOn: Binding(
                    get: { speakerBargeIn },
                    set: { requested in
                        speakerBargeIn = requested
                        model.setSpeakerBargeIn(requested)
                    }
                ))
                Text("Experimental. Keeps the microphone open while Grok talks on the phone's speaker or in the car, with iOS echo cancellation, so you can cut in by speaking. Headphones and AirPods always allow this. Turn it off if Grok keeps cutting itself off. Shared by Gemini Live and Grok Live. Applies to the next conversation.")
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
        .onChange(of: model.memory) { _, newValue in memory = newValue }
        .onChange(of: model.personality) { _, newValue in personality = newValue }
        .onChange(of: model.saveCalls) { _, newValue in saveCalls = newValue }
        .onChange(of: model.speakerBargeIn) { _, newValue in speakerBargeIn = newValue }
    }

    private func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        switch await model.checkAvailability() {
        case .success(let availability):
            isAvailable = availability.isAvailable
            switch availability {
            case .available(let modelName, let voice, let auth):
                // Credential names, not prose: never translated.
                let via = auth == "api_key" ? "XAI_API_KEY" : "SuperGrok"
                if let voice {
                    status = AppLocalization.string("Available (\(modelName), voice \(voice), via \(via))")
                } else {
                    status = AppLocalization.string("Available (\(modelName), via \(via))")
                }
            default:
                status = availability.userFacingReason
            }
        case .failure(let error):
            isAvailable = false
            status = error.localizedDescription
        }
    }
}
