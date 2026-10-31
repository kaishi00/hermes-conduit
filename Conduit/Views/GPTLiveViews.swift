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
    /// Asks the Hermes host whether it can start GPT-Live on a billing.
    var checkAvailability: (GPTLiveBilling) async -> Result<GPTLiveAvailability, Error>
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
    /// Who pays for calls (#559). Settings asks before choosing the API key.
    var billing: GPTLiveBilling = .subscription
    var setBilling: (GPTLiveBilling) -> Void = { _ in }
    /// The API key's voice; nil is the voice set on the Hermes server.
    var apiVoice: String? = nil
    var setAPIVoice: (String?) -> Void = { _ in }
    /// Minutes an API-key call may run; 0 is no limit.
    var apiMaxMinutes: Int = GPTLiveAPICallLimit.defaultMinutes
    var setAPIMaxMinutes: (Int) -> Void = { _ in }
    /// Whether calls Hermes places may run on the API key.
    var apiHermesCalls: Bool = false
    var setAPIHermesCalls: (Bool) -> Void = { _ in }
    /// The status line as its last check of this billing said, kept on the
    /// phone (#1533).
    var keptStatus: LiveVoiceStatusLine? = nil
    /// Keeps a check's line under the billing it checked.
    var keepStatus: (LiveVoiceStatusLine, GPTLiveBilling) -> Void = { _, _ in }
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
    @State private var billing: GPTLiveBilling
    @State private var apiVoice: String
    @State private var apiMaxMinutes: Int
    @State private var apiHermesCalls: Bool
    /// The API key was picked and waits for the user to confirm the cost.
    @State private var confirmingAPIBilling = false
    @State private var status: String?
    @State private var isAvailable: Bool?
    @State private var isChecking = false

    init(model: GPTLiveSettingsModel, showsModeToggle: Bool = false) {
        self.model = model
        self.showsModeToggle = showsModeToggle
        // Shown by the mode picker only once this mode is picked, maybe
        // a render before the model catches up.
        _enabled = State(initialValue: model.enabled || !showsModeToggle)
        _voice = State(initialValue: model.voice ?? "")
        _memory = State(initialValue: model.memory)
        _personality = State(initialValue: model.personality)
        _saveCalls = State(initialValue: model.saveCalls)
        _billing = State(initialValue: model.billing)
        _apiVoice = State(initialValue: model.apiVoice ?? "")
        _apiMaxMinutes = State(initialValue: model.apiMaxMinutes)
        _apiHermesCalls = State(initialValue: model.apiHermesCalls)
        _status = State(initialValue: model.keptStatus?.text)
        _isAvailable = State(initialValue: model.keptStatus?.isAvailable)
    }

    private var billingChoices: [(id: GPTLiveBilling, title: String)] {
        GPTLiveBilling.allCases.map { (id: $0, title: $0.badge) }
    }

    private var apiVoiceChoices: [(id: String, title: String)] {
        var choices = [(id: "", title: AppLocalization.string("Server default"))]
        choices += GPTLiveVoice.apiNames.map { (id: $0, title: "\($0.prefix(1).uppercased())\($0.dropFirst())") }
        if !apiVoice.isEmpty, !GPTLiveVoice.apiNames.contains(apiVoice) {
            choices.append((id: apiVoice, title: apiVoice))
        }
        return choices
    }

    private var limitChoices: [(id: Int, title: String)] {
        var minutes = GPTLiveAPICallLimit.choices
        if !minutes.contains(apiMaxMinutes) { minutes.insert(apiMaxMinutes, at: 0) }
        return minutes.map { value -> (id: Int, title: String) in
            guard value > 0 else { return (id: value, title: AppLocalization.string("No limit")) }
            let title = Duration.seconds(value * 60)
                .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated).locale(AppLocalization.formattingLocale))
            return (id: value, title: title)
        }
    }

    private func selectBilling(_ requested: GPTLiveBilling) {
        guard requested != billing else { return }
        if requested == .api {
            // Never without saying what it costs.
            confirmingAPIBilling = true
            return
        }
        applyBilling(.subscription)
    }

    private func applyBilling(_ chosen: GPTLiveBilling) {
        billing = chosen
        model.setBilling(chosen)
        // The status line checks the path now chosen.
        Task { await check() }
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
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            LiveVoiceSetupLink(mode: .gpt)
            LiveVoiceConsentRow(mode: .gptLive)
            if enabled {
                HStack(spacing: 10) {
                    Circle()
                        .fill(isAvailable == true ? Color.green : (isAvailable == false ? Color.orange : Color.secondary))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(status ?? AppLocalization.string("Not checked yet"))
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Button {
                    Task { await check() }
                } label: {
                    Label(isChecking ? AppLocalization.string("Checking…") : AppLocalization.string("Check GPT-Live"), systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6).frame(minHeight: 44)
                }
                .disabled(isChecking)
                .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.14))
                billingSettings
                if billing == .subscription {
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
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    apiSettings
                }
                Toggle("Use Hermes memory", isOn: Binding(
                    get: { memory },
                    set: { requested in
                        memory = requested
                        model.setMemory(requested)
                    }
                ))
                Text("GPT-Live gets what your Hermes agent remembers about you. That memory is sent to OpenAI with the conversation. Applies to the next conversation.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Use Hermes personality", isOn: Binding(
                    get: { personality },
                    set: { requested in
                        personality = requested
                        model.setPersonality(requested)
                    }
                ))
                Text("GPT-Live talks with the personality in this profile's SOUL.md. SOUL.md is sent to OpenAI with the conversation. Applies to the next conversation.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Save calls to Sessions", isOn: Binding(
                    get: { saveCalls },
                    set: { requested in
                        saveCalls = requested
                        model.setSaveCalls(requested)
                    }
                ))
                Text("Each call's transcript is saved to your Hermes server's history and shows under Voice in Sessions, where you can read it or resume the call. Needs an up-to-date Hermes notifier plugin. Shared by every live voice mode. Applies to the next conversation.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .alert("Bill GPT-Live to the API key?", isPresented: $confirmingAPIBilling) {
            Button("Use the API key") { applyBilling(.api) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("GPT-Live calls will use your Hermes server's OpenAI API key, which OpenAI bills per minute of call time, separately from any ChatGPT plan. Your Hermes server has to allow it too (voice.gpt_live.conduit_api_billing in the profile's config).")
        }
        .task { if enabled { await check() } }
        .onChange(of: model.enabled) { _, newValue in enabled = newValue }
        .onChange(of: model.voice) { _, newValue in voice = newValue ?? "" }
        .onChange(of: model.memory) { _, newValue in memory = newValue }
        .onChange(of: model.personality) { _, newValue in personality = newValue }
        .onChange(of: model.saveCalls) { _, newValue in saveCalls = newValue }
        .onChange(of: model.billing) { _, newValue in
            guard newValue != billing else { return }
            // Changed in another window: the line is the new billing's as
            // last checked, while it's checked again.
            billing = newValue
            status = model.keptStatus?.text
            isAvailable = model.keptStatus?.isAvailable
            Task { await check() }
        }
        .onChange(of: model.apiVoice) { _, newValue in apiVoice = newValue ?? "" }
        .onChange(of: model.apiMaxMinutes) { _, newValue in apiMaxMinutes = newValue }
        .onChange(of: model.apiHermesCalls) { _, newValue in apiHermesCalls = newValue }
    }

    /// Who pays: the ChatGPT plan, or the API key after a confirmation.
    @ViewBuilder private var billingSettings: some View {
        ConduitMenuPicker(value: billing, choices: billingChoices, onSelect: selectBilling) {
            Text("Billing").foregroundStyle(.secondary)
        }
        if billing == .api {
            Text("Bills your Hermes server's OpenAI API key per minute of call time, separately from any ChatGPT plan. The call screen shows which one a call is on.")
                .scaledFont(.caption)
                .foregroundStyle(.orange)
        } else {
            Text("Bills the ChatGPT subscription your Hermes server is signed in to. A call never moves to the API key on its own.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The API key's own voice, time limit and Hermes calls.
    @ViewBuilder private var apiSettings: some View {
        ConduitMenuPicker(
            value: apiVoice,
            choices: apiVoiceChoices,
            onSelect: { chosen in
                apiVoice = chosen
                model.setAPIVoice(chosen.isEmpty ? nil : chosen)
                if status != nil { Task { await check() } }
            }
        ) {
            Text("Voice").foregroundStyle(.secondary)
        }
        Text("The voice GPT-Live speaks with on the API key. Server default uses voice.gpt_live.voice in the profile's config. Applies to the next conversation.")
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
        ConduitMenuPicker(
            value: apiMaxMinutes,
            choices: limitChoices,
            onSelect: { chosen in
                apiMaxMinutes = chosen
                model.setAPIMaxMinutes(chosen)
            }
        ) {
            Text("Time limit per call").foregroundStyle(.secondary)
        }
        Text("An API-key call says goodbye and ends when it reaches this limit.")
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
        Toggle("Calls from Hermes on the API key", isOn: Binding(
            get: { apiHermesCalls },
            set: { requested in
                apiHermesCalls = requested
                model.setAPIHermesCalls(requested)
            }
        ))
        Text("When Hermes calls you, the call uses the ChatGPT subscription unless this is on.")
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
    }

    private func check() async {
        guard !isChecking else { return }
        isChecking = true
        // The billing the picker shows, even while a call Hermes placed
        // would start on the subscription: the line is its, kept under it.
        let asked = billing
        let result = await model.checkAvailability(asked)
        isChecking = false
        switch result {
        case .success(let availability):
            let line: String?
            switch availability {
            // The host reports its own voice; a voice chosen here overrides it.
            case .available(let modelName, let hostVoice?) where (asked == .api ? apiVoice : voice).isEmpty:
                line = AppLocalization.string("Available (\(modelName), voice \(hostVoice))")
            case .available(let modelName, _):
                line = AppLocalization.string("Available (\(modelName))")
            default:
                line = availability.userFacingReason
            }
            if let line { model.keepStatus(LiveVoiceStatusLine(text: line, isAvailable: availability.isAvailable), asked) }
            // A switch while it was out asked for a check this one held off.
            guard billing == asked else { return await check() }
            status = line
            isAvailable = availability.isAvailable
        case .failure(let error):
            guard billing == asked else { return await check() }
            isAvailable = false
            status = UserFacingError.message(for: error)
        }
    }
}

struct GPTLiveVoiceSheet: View {
    @ObservedObject var controller: GPTLiveConversationController
    let jobs: VoiceBackgroundJobSupervisor
    /// Passed to the call screen for its own sheets; not observed.
    let appState: AppState
    /// Up before its call opens, for a widget's Talk or Siri waiting on
    /// Hermes (`AppState.waitingCall`).
    var waitsToStart = false
    let onClose: () -> Void
    let onRetry: () -> Void

    /// The screen shows its call connecting, without the last call's lines,
    /// until the call's own connecting state takes over.
    private var isWaiting: Bool { waitsToStart && !controller.isActive }

    var body: some View {
        LiveVoiceCallSheet(
            title: "GPT-Live",
            billingBadge: isWaiting ? nil : controller.billing,
            phase: isWaiting ? .connecting : Self.callPhase(controller.phase, microphoneMuted: controller.isMicrophoneMuted),
            waitsToStart: isWaiting,
            statusText: isWaiting ? AppLocalization.string("Connecting…") : statusText,
            note: isWaiting ? nil : controller.limitNote ?? controller.voiceNote,
            transcript: isWaiting ? [] : controller.transcript,
            assistantLabel: { AppLocalization.string("GPT-Live: \($0)") },
            jobs: jobs,
            appState: appState,
            isMicrophoneMuted: controller.isMicrophoneMuted,
            isSpeakerMuted: controller.isSpeakerMuted,
            canMute: controller.isActive && !controller.isEnding,
            // GPT-Live cuts in on its own when you speak over it: no
            // Interrupt button.
            canInterrupt: false,
            onToggleMute: { controller.setMicrophoneMuted(!controller.isMicrophoneMuted) },
            onToggleSpeaker: { controller.setSpeakerMuted(!controller.isSpeakerMuted) },
            onEnd: onClose,
            onRetry: onRetry,
            // A call still waiting on Hermes has no mode to move yet.
            modeSwitch: isWaiting ? nil : appState.voiceModeSwitch(for: .gptLive),
            consent: isWaiting ? nil : controller.awaitingConsent,
            onAllowConsent: {
                guard let mode = controller.awaitingConsent else { return }
                appState.setLiveVoiceConsent(true, for: mode)
                onRetry()
            }
        )
        // The status and new turns change without focus moving.
        .onChange(of: controller.phase) { _, _ in
            // A consent stop shows the question, not the Watch's wording.
            let consentQuestion = controller.awaitingConsent.map { AppLocalization.string("Send your voice to \($0.company)?") }
            AccessibilityNotification.Announcement(consentQuestion ?? statusText).post()
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
        .onChange(of: controller.limitNote) { _, note in
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
