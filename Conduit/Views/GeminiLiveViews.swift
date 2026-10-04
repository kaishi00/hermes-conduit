//
//  GeminiLiveViews.swift
//  Conduit
//
//  Gemini Live voice mode: its Voice settings section and its sheet.
//

import SwiftUI

/// What Voice settings needs to show the Gemini Live option.
struct GeminiLiveSettingsModel {
    var enabled: Bool
    var setEnabled: (Bool) -> Void
    /// Asks the Hermes host whether it can serve Gemini Live.
    var checkAvailability: () async -> Result<GeminiLiveAvailability, Error>
    var search: GeminiLiveSearchMode = .automatic
    var setSearch: (GeminiLiveSearchMode) -> Void = { _ in }
    /// Prebuilt voice name; nil is Gemini's default voice.
    var voice: String? = nil
    var setVoice: (String?) -> Void = { _ in }
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

struct GeminiLiveSettingsSection: View {
    let model: GeminiLiveSettingsModel
    /// Off when Voice settings picks the mode with its own picker: the
    /// section then only shows this mode's settings.
    let showsModeToggle: Bool
    @State private var enabled: Bool
    @State private var search: GeminiLiveSearchMode
    /// Empty is Gemini's default voice (a Picker tag can't be nil).
    @State private var voice: String
    @State private var memory: Bool
    @State private var personality: Bool
    @State private var saveCalls: Bool
    @State private var speakerBargeIn: Bool
    @State private var status: String?
    @State private var isAvailable: Bool?
    @State private var isChecking = false

    init(model: GeminiLiveSettingsModel, showsModeToggle: Bool = true) {
        self.model = model
        self.showsModeToggle = showsModeToggle
        // Shown by the mode picker only once this mode is picked, maybe
        // a render before the model catches up.
        _enabled = State(initialValue: model.enabled || !showsModeToggle)
        _search = State(initialValue: model.search)
        _voice = State(initialValue: model.voice ?? "")
        _memory = State(initialValue: model.memory)
        _personality = State(initialValue: model.personality)
        _saveCalls = State(initialValue: model.saveCalls)
        _speakerBargeIn = State(initialValue: model.speakerBargeIn)
    }

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Gemini Live"), symbol: "waveform.badge.mic", tint: .conduitAura) {
            if showsModeToggle {
                Toggle("Use Gemini Live for voice", isOn: Binding(
                    get: { enabled },
                    set: { requested in
                        enabled = requested
                        model.setEnabled(requested)
                        if requested { Task { await check() } }
                    }
                ))
            }
            Text("Talk with Gemini Live instead of the Hermes speech pipeline. Hermes still does the work: Gemini starts background jobs on this profile and tells you their results. The API key stays on your Hermes server. Approvals are never given by voice.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LiveVoiceSetupLink(mode: .gemini)
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
                    Label(isChecking ? AppLocalization.string("Checking…") : AppLocalization.string("Check Gemini Live"), systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .disabled(isChecking)
                .conduitGlassControl(cornerRadius: 16, tint: .conduitAura.opacity(0.14))
                Picker("Web lookups", selection: Binding(
                    get: { search },
                    set: { chosen in
                        search = chosen
                        model.setSearch(chosen)
                    }
                )) {
                    Text("Automatic").tag(GeminiLiveSearchMode.automatic)
                    Text("Hermes web search").tag(GeminiLiveSearchMode.hermes)
                    Text("Google Search").tag(GeminiLiveSearchMode.google)
                    Text("Off").tag(GeminiLiveSearchMode.off)
                }
                .pickerStyle(.menu)
                Text("How Gemini answers quick questions like weather or news. Hermes web search uses the search your Hermes server is set up with (SearXNG, Firecrawl…). Google Search has its own quota on your Gemini key. Automatic uses Hermes when it has a search set up, otherwise Google. Applies to the next conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Voice", selection: Binding(
                    get: { voice },
                    set: { chosen in
                        voice = chosen
                        model.setVoice(chosen.isEmpty ? nil : chosen)
                    }
                )) {
                    Text("Gemini default").tag("")
                    ForEach(GeminiLiveVoice.all) { option in
                        Text(verbatim: "\(option.name) · \(option.style)").tag(option.name)
                    }
                    // A voice saved by a newer build that this one doesn't list.
                    if !voice.isEmpty, !GeminiLiveVoice.all.contains(where: { $0.name == voice }) {
                        Text(verbatim: voice).tag(voice)
                    }
                }
                .pickerStyle(.menu)
                Text("The voice Gemini speaks with. Applies to the next conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Use Hermes memory", isOn: Binding(
                    get: { memory },
                    set: { requested in
                        memory = requested
                        model.setMemory(requested)
                    }
                ))
                Text("Gemini gets what your Hermes agent remembers about you, from whichever memory Hermes is set up with, and can search it for more. That memory is sent to Google with the conversation. Applies to the next conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Use Hermes personality", isOn: Binding(
                    get: { personality },
                    set: { requested in
                        personality = requested
                        model.setPersonality(requested)
                    }
                ))
                Text("Gemini talks with the personality in this profile's SOUL.md, without reading out actions or emoji. SOUL.md is sent to Google with the conversation. Applies to the next conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Talk over it on the speaker", isOn: Binding(
                    get: { speakerBargeIn },
                    set: { requested in
                        speakerBargeIn = requested
                        model.setSpeakerBargeIn(requested)
                    }
                ))
                Text("Experimental. Keeps the microphone open while Gemini talks on the phone's speaker or in the car, with iOS echo cancellation, so you can cut in by speaking. Headphones and AirPods always allow this. Turn it off if Gemini keeps cutting itself off. Shared by Gemini Live and Grok Live. Applies to the next conversation.")
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
        // A profile switch can change the preference under a retained view.
        .onChange(of: model.enabled) { _, newValue in enabled = newValue }
        .onChange(of: model.search) { _, newValue in search = newValue }
        .onChange(of: model.voice) { _, newValue in voice = newValue ?? "" }
        .onChange(of: model.memory) { _, newValue in memory = newValue }
        .onChange(of: model.personality) { _, newValue in personality = newValue }
        .onChange(of: model.saveCalls) { _, newValue in saveCalls = newValue }
        .onChange(of: model.speakerBargeIn) { _, newValue in speakerBargeIn = newValue }
    }

    private func check() async {
        isChecking = true
        defer { isChecking = false }
        switch await model.checkAvailability() {
        case .success(let availability):
            isAvailable = availability.isAvailable
            if case .available(let modelName) = availability {
                status = AppLocalization.string("Available (\(modelName))")
            } else {
                status = availability.userFacingReason
            }
        case .failure(let error):
            isAvailable = false
            status = UserFacingError.message(for: error)
        }
    }
}

/// Gemini Live's sheet, which Grok Live shares: they run on the same
/// conversation controller.
struct GeminiLiveVoiceSheet: View {
    enum Engine {
        case gemini
        case grok
    }

    @ObservedObject var controller: GeminiLiveConversationController
    let jobs: VoiceBackgroundJobSupervisor
    var engine: Engine = .gemini
    let onClose: () -> Void
    let onRetry: () -> Void

    var body: some View {
        LiveVoiceCallSheet(
            title: engine == .grok ? "Grok Live" : "Gemini Live",
            phase: Self.callPhase(controller.phase, microphoneMuted: controller.isMicrophoneMuted),
            statusText: statusText,
            transcript: controller.transcript,
            assistantLabel: speakerLabel,
            jobs: jobs,
            isMicrophoneMuted: controller.isMicrophoneMuted,
            canMute: controller.isActive && !controller.isEnding,
            canInterrupt: controller.phase == .speaking,
            onToggleMute: { controller.setMicrophoneMuted(!controller.isMicrophoneMuted) },
            onInterrupt: { controller.interruptSpeaking() },
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
        // Each line once, with its final text (not the first fragment).
        .onChange(of: controller.finishedTurn) { _, turn in
            guard let turn else { return }
            AccessibilityNotification.Announcement(turn.speaker == .user
                ? AppLocalization.string("You: \(turn.text)")
                : speakerLabel(turn.text)).post()
        }
    }

    static func callPhase(_ phase: GeminiLiveConversationController.Phase, microphoneMuted: Bool) -> LiveVoiceCallPhase {
        switch phase {
        case .idle: return .idle
        case .connecting, .reconnecting: return .connecting
        case .listening: return microphoneMuted ? .muted : .listening
        case .speaking: return .speaking
        case .paused: return .muted
        case .ending: return .ending
        case .failed: return .failed
        }
    }

    private func speakerLabel(_ text: String) -> String {
        engine == .grok ? AppLocalization.string("Grok: \(text)") : AppLocalization.string("Gemini: \(text)")
    }

    private var statusText: String {
        switch controller.phase {
        case .idle: return AppLocalization.string("Not connected")
        case .connecting:
            return engine == .grok
                ? AppLocalization.string("Connecting to Grok Live…")
                : AppLocalization.string("Connecting to Gemini Live…")
        case .reconnecting: return AppLocalization.string("Reconnecting…")
        case .listening: return controller.isMicrophoneMuted ? AppLocalization.string("Microphone muted") : AppLocalization.string("Listening")
        case .speaking: return AppLocalization.string("Speaking")
        case .paused: return AppLocalization.string("Paused while another sound plays")
        case .ending: return AppLocalization.string("Ending conversation…")
        case .failed(let message): return message
        }
    }
}

/// Under an attached call's status, the first few times: the call works in
/// its chat, and "quick…" runs a fast job instead.
struct LiveVoiceQuickHint: View {
    static let shownCountKey = "conduit.liveVoiceQuickHintShown"
    static let timesShown = 3

    /// Observed here, not by the sheet: job progress shouldn't redraw the
    /// whole call.
    @ObservedObject var jobs: VoiceBackgroundJobSupervisor
    @AppStorage(LiveVoiceQuickHint.shownCountKey) private var shownCount = 0
    @State private var isShown = false
    /// Chats already counted while the app runs: bringing a minimised call
    /// back, or calling the same chat again, doesn't count twice.
    @MainActor private static var countedThisRun: Set<String> = []

    private var thread: String? { jobs.liveThread?.title }
    /// The chat's durable id: a resumed chat runs under a new runtime id.
    private var threadID: String? { jobs.liveThread.map { $0.storedSessionID ?? $0.runtimeSessionID } }

    var body: some View {
        Group {
            if isShown, let thread {
                Text(AppLocalization.string("Working in \(thread). Say “quick…” for a fast side job."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear { showIfDue() }
        .onChange(of: threadID) { _, _ in showIfDue() }
    }

    private func showIfDue() {
        guard let threadID, thread != nil else {
            isShown = false
            return
        }
        isShown = Self.shows(threadID: threadID, shownCount: &shownCount, counted: &Self.countedThisRun)
    }

    /// Counted once per chat; one already counted shows it again.
    static func shows(threadID: String, shownCount: inout Int, counted: inout Set<String>) -> Bool {
        if counted.contains(threadID) { return true }
        guard shownCount < timesShown else { return false }
        shownCount += 1
        counted.insert(threadID)
        return true
    }
}

/// What Voice settings needs for the voice-job model choice.
struct VoiceJobModelSettingsModel {
    var provider: String?
    var model: String?
    var reasoningEffort: String?
    var loadProviders: () async -> [ProviderInfo]
    var save: (_ provider: String?, _ model: String?, _ reasoningEffort: String?) -> Void
}

/// The model and reasoning level for Hermes sessions that voice background
/// jobs create (both Voice modes). A faster model here keeps spoken
/// requests quick without changing the profile's main chat model.
struct VoiceJobModelSettingsSection: View {
    let settings: VoiceJobModelSettingsModel
    @State private var selection: String
    @State private var reasoning: String
    @State private var providers: [ProviderInfo] = []

    private static let profileDefault = ""

    init(settings: VoiceJobModelSettingsModel) {
        self.settings = settings
        _selection = State(initialValue: settings.model.map { Self.tag(provider: settings.provider, model: $0) } ?? Self.profileDefault)
        _reasoning = State(initialValue: settings.reasoningEffort ?? Self.profileDefault)
    }

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Voice jobs"), symbol: "bolt.horizontal.circle", tint: .conduitAccent) {
            Picker("Model", selection: $selection) {
                Text("Profile default").tag(Self.profileDefault)
                // Keep a saved choice visible even before the list loads.
                if selection != Self.profileDefault, !providers.contains(where: { provider in
                    provider.models.contains { Self.tag(provider: provider.name, model: $0.id) == selection }
                }) {
                    Text(Self.parse(selection).model).tag(selection)
                }
                ForEach(providers, id: \.name) { provider in
                    ForEach(provider.models, id: \.id) { model in
                        Text("\(model.label ?? model.id) · \(provider.name)")
                            .tag(Self.tag(provider: provider.name, model: model.id))
                    }
                }
            }
            .pickerStyle(.menu)
            Picker("Reasoning", selection: $reasoning) {
                Text("Profile default").tag(Self.profileDefault)
                // Same levels as the model picker's reasoning control.
                Text("None").tag("none")
                Text("Minimal").tag("minimal")
                Text("Low").tag("low")
                Text("Medium").tag("medium")
                Text("High").tag("high")
                Text("Extra High").tag("xhigh")
                Text("Max").tag("max")
            }
            .pickerStyle(.menu)
            Text("The model Hermes uses for background jobs started by voice. A fast model with low reasoning keeps spoken requests quick; your chats keep the profile's model.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { providers = await settings.loadProviders() }
        .onChange(of: selection) { _, _ in save() }
        .onChange(of: reasoning) { _, _ in save() }
    }

    private func save() {
        let chosen = selection == Self.profileDefault ? nil : Self.parse(selection)
        settings.save(chosen?.provider, chosen?.model, reasoning == Self.profileDefault ? nil : reasoning)
    }

    /// Picker tag for a provider/model pair (provider may be empty).
    static func tag(provider: String?, model: String) -> String {
        "\(provider ?? "")\u{1F}\(model)"
    }

    static func parse(_ tag: String) -> (provider: String?, model: String) {
        let parts = tag.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return (nil, tag) }
        return (parts[0].isEmpty ? nil : String(parts[0]), String(parts[1]))
    }
}
