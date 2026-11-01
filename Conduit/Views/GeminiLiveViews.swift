//
//  GeminiLiveViews.swift
//  Conduit
//
//  Gemini Live voice mode: its Voice settings section and its sheet.
//

import SwiftUI

/// A live voice mode's status line on Voice settings: whether a call can
/// start, as its check last said, kept on the phone so the line opens on it
/// (#1533). A check that fails says why, as before, and isn't kept.
struct LiveVoiceStatusLine: Equatable {
    var text: String
    var isAvailable: Bool

    init(text: String, isAvailable: Bool) {
        self.text = text
        self.isAvailable = isAvailable
    }

    init?(answer: [String: Any]) {
        guard let text = answer["line"] as? String, let isAvailable = answer["available"] as? Bool else { return nil }
        self.init(text: text, isAvailable: isAvailable)
    }

    var answer: [String: Any] { ["line": text, "available": isAvailable] }
}

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
    var provider: LiveVoiceModeName = .geminiLive
    /// The status line as its last check said, kept on the phone (#1533).
    var keptStatus: LiveVoiceStatusLine? = nil
    var keepStatus: (LiveVoiceStatusLine) -> Void = { _ in }
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

    init(model: GeminiLiveSettingsModel, showsModeToggle: Bool = false) {
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
        _status = State(initialValue: model.keptStatus?.text)
        _isAvailable = State(initialValue: model.keptStatus?.isAvailable)
    }

    private var voiceChoices: [(id: String, title: String)] {
        var choices = [(id: "", title: AppLocalization.string("Gemini default"))]
        choices += GeminiLiveVoice.all.map { (id: $0.name, title: "\($0.name) · \($0.style)") }
        // A voice saved by a newer build that this one doesn't list.
        if !voice.isEmpty, !GeminiLiveVoice.all.contains(where: { $0.name == voice }) {
            choices.append((id: voice, title: voice))
        }
        return choices
    }

    var body: some View {
        ConduitSettingsSection(title: model.provider.displayName, symbol: "waveform.badge.mic", tint: .conduitAura) {
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
            Text(model.provider == .qwenLive ? AppLocalization.string("Qwen Live talks with you while Hermes runs jobs. The permanent API key stays on your server. Your iPhone or Watch connects directly to the provider using a short-lived credential.") : AppLocalization.string("Talk with Gemini Live instead of the Hermes speech pipeline. Hermes still does the work: Gemini starts background jobs on this profile and tells you their results. The API key stays on your Hermes server. Gemini answers what Hermes asks you only with what you say, and approves a command only on your yes."))
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            LiveVoiceSetupLink(mode: model.provider == .qwenLive ? .qwen : .gemini)
            LiveVoiceConsentRow(mode: model.provider)
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
                    Label(isChecking ? AppLocalization.string("Checking…") : (model.provider == .qwenLive ? AppLocalization.string("Check Qwen Live") : AppLocalization.string("Check Gemini Live")), systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6).frame(minHeight: 44)
                }
                .disabled(isChecking)
                .conduitGlassControl(cornerRadius: 16, tint: .conduitAura.opacity(0.14))
                ConduitMenuPicker(
                    value: search,
                    choices: [
                        (id: GeminiLiveSearchMode.automatic, title: AppLocalization.string("Automatic")),
                        (id: GeminiLiveSearchMode.hermes, title: AppLocalization.string("Hermes web search")),
                    ] + (model.provider == .geminiLive ? [(id: GeminiLiveSearchMode.google, title: AppLocalization.string("Google Search"))] : []) + [
                        (id: GeminiLiveSearchMode.off, title: AppLocalization.string("Off")),
                    ],
                    onSelect: { chosen in
                        search = chosen
                        model.setSearch(chosen)
                    }
                ) {
                    Text("Web lookups").foregroundStyle(.secondary)
                }
                Text(model.provider == .qwenLive ? AppLocalization.string("Qwen uses Hermes web search. Native search is disabled while function tools are enabled.") : AppLocalization.string("How Gemini answers quick questions like weather or news. Hermes web search uses the search your Hermes server is set up with (SearXNG, Firecrawl…). Google Search has its own quota on your Gemini key. Automatic uses Hermes when it has a search set up, otherwise Google. Applies to the next conversation."))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                if model.provider == .qwenLive {
                    TextField("Voice", text: $voice)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: voice) { _, value in model.setVoice(value.isEmpty ? nil : value) }
                } else {
                    ConduitMenuPicker(
                        value: voice,
                        choices: voiceChoices,
                        onSelect: { chosen in
                            voice = chosen
                            model.setVoice(chosen.isEmpty ? nil : chosen)
                        }
                    ) {
                        Text("Voice").foregroundStyle(.secondary)
                    }
                }
                Text(model.provider == .qwenLive ? AppLocalization.string("The voice Qwen speaks with. Applies to the next conversation.") : AppLocalization.string("The voice Gemini speaks with. Applies to the next conversation."))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Use Hermes memory", isOn: Binding(
                    get: { memory },
                    set: { requested in
                        memory = requested
                        model.setMemory(requested)
                    }
                ))
                Text(model.provider == .qwenLive ? AppLocalization.string("Qwen gets what your Hermes agent remembers about you, from whichever memory Hermes is set up with, and can search it for more. That memory is sent to Alibaba Cloud with the conversation. Applies to the next conversation.") : AppLocalization.string("Gemini gets what your Hermes agent remembers about you, from whichever memory Hermes is set up with, and can search it for more. That memory is sent to Google with the conversation. Applies to the next conversation."))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Use Hermes personality", isOn: Binding(
                    get: { personality },
                    set: { requested in
                        personality = requested
                        model.setPersonality(requested)
                    }
                ))
                Text(model.provider == .qwenLive ? AppLocalization.string("Qwen talks with the personality in this profile's SOUL.md, without reading out actions or emoji. SOUL.md is sent to Alibaba Cloud with the conversation. Applies to the next conversation.") : AppLocalization.string("Gemini talks with the personality in this profile's SOUL.md, without reading out actions or emoji. SOUL.md is sent to Google with the conversation. Applies to the next conversation."))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Talk over it on the speaker", isOn: Binding(
                    get: { speakerBargeIn },
                    set: { requested in
                        speakerBargeIn = requested
                        model.setSpeakerBargeIn(requested)
                    }
                ))
                Text(model.provider == .qwenLive ? AppLocalization.string("Experimental. Keeps the microphone open while Qwen talks on the phone's speaker or in the car, with iOS echo cancellation, so you can cut in by speaking. Headphones and AirPods always allow this. Turn it off if Qwen keeps cutting itself off. Shared by Qwen Live, Gemini Live, Grok Live and Classic voice. Applies to the next conversation.") : AppLocalization.string("Experimental. Keeps the microphone open while Gemini talks on the phone's speaker or in the car, with iOS echo cancellation, so you can cut in by speaking. Headphones and AirPods always allow this. Turn it off if Gemini keeps cutting itself off. Shared by Qwen Live, Gemini Live, Grok Live and Classic voice. Applies to the next conversation."))
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
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        switch await model.checkAvailability() {
        case .success(let availability):
            let line: String?
            if case .available(let modelName) = availability {
                line = AppLocalization.string("Available (\(modelName))")
            } else {
                line = availability.userFacingReason(for: model.provider == .qwenLive ? .qwen : .gemini)
            }
            status = line
            isAvailable = availability.isAvailable
            if let line { model.keepStatus(LiveVoiceStatusLine(text: line, isAvailable: availability.isAvailable)) }
        case .failure(let error):
            isAvailable = false
            status = UserFacingError.message(for: error)
        }
    }
}

/// Gemini Live's sheet, which Grok Live and Local Live share: they run on
/// the same conversation controller.
struct GeminiLiveVoiceSheet: View {
    enum Engine {
        case gemini
        case qwen
        case grok
        case local

        var title: String {
            switch self {
            case .gemini: return "Gemini Live"
            case .qwen: return AppLocalization.string("Qwen Live")
            case .grok: return "Grok Live"
            case .local: return AppLocalization.string("Local Live")
            }
        }

        var callEngine: VoiceCallEngine {
            switch self {
            case .gemini: return .geminiLive
            case .qwen: return .qwenLive
            case .grok: return .grokLive
            case .local: return .localLive
            }
        }
    }

    @ObservedObject var controller: GeminiLiveConversationController
    let jobs: VoiceBackgroundJobSupervisor
    /// Passed to the call screen for its own sheets; not observed.
    let appState: AppState
    var engine: Engine = .gemini
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
            title: engine.title,
            phase: isWaiting ? .connecting : Self.callPhase(controller.phase, microphoneMuted: controller.isMicrophoneMuted),
            waitsToStart: isWaiting,
            statusText: isWaiting ? AppLocalization.string("Connecting…") : statusText,
            transcript: isWaiting ? [] : controller.transcript,
            assistantLabel: speakerLabel,
            jobs: jobs,
            appState: appState,
            isMicrophoneMuted: controller.isMicrophoneMuted,
            isSpeakerMuted: controller.isSpeakerMuted,
            canMute: controller.isActive && !controller.isEnding,
            canInterrupt: controller.phase == .speaking,
            onToggleMute: { controller.setMicrophoneMuted(!controller.isMicrophoneMuted) },
            onToggleSpeaker: { controller.setSpeakerMuted(!controller.isSpeakerMuted) },
            onInterrupt: { controller.interruptSpeaking() },
            onEnd: onClose,
            onRetry: onRetry,
            // A call still waiting on Hermes has no mode to move yet.
            modeSwitch: isWaiting ? nil : appState.voiceModeSwitch(for: engine.callEngine),
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
        switch engine {
        case .gemini: return AppLocalization.string("Gemini: \(text)")
        case .qwen: return AppLocalization.string("Qwen: \(text)")
        case .grok: return AppLocalization.string("Grok: \(text)")
        // Hermes writes a Local Live call's replies; the server only speaks them.
        case .local: return AppLocalization.string("Hermes: \(text)")
        }
    }

    private var statusText: String {
        switch controller.phase {
        case .idle: return AppLocalization.string("Not connected")
        case .connecting:
            switch engine {
            case .gemini: return AppLocalization.string("Connecting to Gemini Live…")
            case .qwen: return AppLocalization.string("Connecting to Qwen Live…")
            case .grok: return AppLocalization.string("Connecting to Grok Live…")
            case .local: return AppLocalization.string("Connecting to your speech server…")
            }
        case .reconnecting: return AppLocalization.string("Reconnecting…")
        case .listening: return controller.isMicrophoneMuted ? AppLocalization.string("Microphone muted") : AppLocalization.string("Listening")
        case .speaking: return controller.isSpeakerMuted ? AppLocalization.string("Speaking, silenced") : AppLocalization.string("Speaking")
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
                    .scaledFont(.footnote)
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
    /// The models as last read, kept on the phone, for the menu to open on
    /// (#1533).
    var keptProviders: () -> [ProviderInfo] = { [] }
    /// Nil when Hermes didn't answer: the menu keeps the models it lists.
    var loadProviders: () async -> [ProviderInfo]?
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
    @State private var providersFailed = false
    /// Hermes answered the models read: only then is a model picked, as a
    /// list that didn't load is never picked from.
    @State private var modelsAnswered = false

    private static let profileDefault = ""

    init(settings: VoiceJobModelSettingsModel) {
        self.settings = settings
        _selection = State(initialValue: settings.model.map { Self.tag(provider: settings.provider, model: $0) } ?? Self.profileDefault)
        _reasoning = State(initialValue: settings.reasoningEffort ?? Self.profileDefault)
    }

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Voice jobs"), symbol: "bolt.horizontal.circle", tint: .conduitAccent) {
            ConduitMenuPicker(
                value: selection,
                choices: VoiceJobModelSettingsSection.modelChoices(
                    defaultTitle: AppLocalization.string("Profile default"),
                    defaultTag: Self.profileDefault,
                    selection: selection,
                    providers: providers
                ),
                onSelect: { selection = $0 }
            ) {
                Text("Model").foregroundStyle(.secondary)
            }
            .disabled(!modelsAnswered)
            if providersFailed {
                // The models listed stay up; Hermes didn't answer.
                ModelCatalogPlaceholder(state: .failed) { Task { await loadProviders() } }
            }
            ConduitMenuPicker(
                value: reasoning,
                choices: reasoningChoices,
                onSelect: { reasoning = $0 }
            ) {
                Text("Reasoning").foregroundStyle(.secondary)
            }
            Text("The model Hermes uses for background jobs started by voice. A fast model with low reasoning keeps spoken requests quick; your chats keep the profile's model.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { if providers.isEmpty { providers = settings.keptProviders() } }
        .task { await loadProviders() }
        .onChange(of: selection) { _, _ in save() }
        .onChange(of: reasoning) { _, _ in save() }
    }

    private func loadProviders() async {
        let loaded = await settings.loadProviders()
        if let loaded {
            providers = loaded
            modelsAnswered = true
        }
        providersFailed = loaded == nil
    }

    private func save() {
        let chosen = selection == Self.profileDefault ? nil : Self.parse(selection)
        settings.save(chosen?.provider, chosen?.model, reasoning == Self.profileDefault ? nil : reasoning)
    }

    private var reasoningChoices: [(id: String, title: String)] {
        let levels = Self.reasoningLevels(offTitle: AppLocalization.string("None"))
        return [(id: Self.profileDefault, title: AppLocalization.string("Profile default"))] + levels
    }

    /// Model menu: the default choice, a saved model the list doesn't carry
    /// (kept visible even before the list loads), then every provider's
    /// models.
    static func modelChoices(
        defaultTitle: String,
        defaultTag: String,
        selection: String,
        providers: [ProviderInfo]
    ) -> [(id: String, title: String)] {
        var choices = [(id: defaultTag, title: defaultTitle)]
        if selection != defaultTag, !providers.contains(where: { provider in
            provider.models.contains { tag(provider: provider.name, model: $0.id) == selection }
        }) {
            let held = parse(selection)
            // A provider pinned without a model runs on its default one.
            choices.append((id: selection, title: held.model.isEmpty
                ? providerDefaultTitle(held.provider ?? "")
                : held.model))
        }
        for provider in providers {
            for model in provider.models {
                choices.append((id: tag(provider: provider.name, model: model.id), title: "\(model.label ?? model.id) · \(provider.name)"))
            }
        }
        return choices
    }

    /// Reasoning levels, the same as the model picker's reasoning control.
    static func reasoningLevels(offTitle: String) -> [(id: String, title: String)] {
        [
            (id: "none", title: offTitle),
            (id: "minimal", title: AppLocalization.string("Minimal")),
            (id: "low", title: AppLocalization.string("Low")),
            (id: "medium", title: AppLocalization.string("Medium")),
            (id: "high", title: AppLocalization.string("High")),
            (id: "xhigh", title: AppLocalization.string("Extra High")),
            (id: "max", title: AppLocalization.string("Max")),
        ]
    }

    /// A provider pinned without a model: Hermes runs its default model.
    static func providerDefaultTitle(_ provider: String) -> String {
        AppLocalization.string("Default") + " · " + provider
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

/// One of Hermes' helper model slots (`auxiliary.<task>`), read from
/// `/api/model/auxiliary`: spoken classic-voice turns (`voice_chat`) and
/// the helper models on Models & providers.
struct VoiceReplyModelSetting: Equatable {
    static let task = "voice_chat"

    /// The slot: `voice_chat` for voice replies.
    var task: String = Self.task
    /// `auto` with an empty model follows the chat's model.
    var provider: String
    var model: String
    /// Nil follows the chat's reasoning; `none` (Hermes' default) is off.
    var reasoningEffort: String?
    /// An endpoint of the slot's own (`auxiliary.<task>.base_url`), such as
    /// a local server. Hermes keeps it while the provider stays, so a save
    /// never sends it.
    var baseURL: String?

    /// Nil when this Hermes has no such slot.
    init?(auxiliaryResponse response: [String: Any], task: String = Self.task) {
        let tasks = response["tasks"] as? [[String: Any]] ?? []
        guard let row = tasks.first(where: { $0["task"] as? String == task }) else { return nil }
        self.init(row: row)
    }

    /// A row of `/api/model/auxiliary`'s tasks; nil without a task name.
    init?(row: [String: Any]) {
        let task = (row["task"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !task.isEmpty else { return nil }
        self.task = task
        let provider = (row["provider"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        self.provider = provider.isEmpty ? "auto" : provider
        model = (row["model"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let effort = (row["reasoning_effort"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        reasoningEffort = effort.isEmpty ? nil : effort
        let url = (row["base_url"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        baseURL = url.isEmpty ? nil : url
    }

    init(task: String = Self.task, provider: String, model: String, reasoningEffort: String?, baseURL: String? = nil) {
        self.task = task
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.baseURL = baseURL
    }

    /// Follows the chat's model.
    var followsChats: Bool { model.isEmpty && !providerOnly }

    /// A provider pinned without a model: Hermes runs that provider's
    /// default model, not the chat's.
    var providerOnly: Bool {
        model.isEmpty && !provider.isEmpty && provider != "auto"
    }

    /// The slot's own endpoint by host (and port), never its path or any
    /// credentials in it.
    var endpointHost: String? {
        guard let baseURL else { return nil }
        guard let components = URLComponents(string: baseURL), let host = components.host, !host.isEmpty else {
            return nil
        }
        return components.port.map { "\(host):\($0)" } ?? host
    }

    /// `POST /api/model/set` body. An explicit null reasoning means "same as
    /// chats"; Hermes keeps it from falling back to its off default.
    /// `confirmed` answers Hermes' price check for a model the user chose
    /// anyway.
    func assignmentBody(profile: String, confirmed: Bool = false) -> [String: Any] {
        var body: [String: Any] = [
            "scope": "auxiliary",
            "task": task,
            "provider": provider.isEmpty ? "auto" : provider,
            "model": model,
            "reasoning_effort": reasoningEffort ?? NSNull(),
            "profile": profile
        ]
        if confirmed { body["confirm_expensive_model"] = true }
        return body
    }
}

/// How a helper model save ended.
enum HelperModelSaveResult: Equatable {
    case saved
    /// Hermes didn't take it, saying why.
    case refused(String)
    /// Hermes' price check asks before it takes the model: its warning,
    /// for the user to choose it anyway.
    case needsConfirmation(String)
}

/// What Voice settings needs for the voice reply model choice.
struct VoiceReplyModelSettingsModel {
    /// The setting and models as Hermes gave them last, kept on the phone:
    /// the section opens on them (#1533).
    var kept: () -> VoiceReplyModelSetting? = { nil }
    var keptProviders: () -> [ProviderInfo] = { [] }
    /// Nil when this Hermes has no voice reply slot; throws when Hermes
    /// didn't answer.
    var load: () async throws -> VoiceReplyModelSetting?
    var loadProviders: () async -> [ProviderInfo]?
    /// Writes the setting; `confirmed` answers Hermes' price check.
    var save: (VoiceReplyModelSetting, _ confirmed: Bool) async -> HelperModelSaveResult
}

/// The Voice replies section's setting and picks, apart from its view so
/// the order of Hermes' answers and the writes can be tested (#1533).
struct VoiceReplyModelPicks {
    static let sameAsChats = ""
    static let inheritReasoning = "inherit"

    /// What Hermes holds, as it last answered or took a write. Nil hides
    /// the section, for a Hermes without the slot.
    private(set) var saved: VoiceReplyModelSetting?
    var selection = Self.sameAsChats
    var reasoning = "none"
    /// Hermes answered. Until then the section shows the setting kept on
    /// the phone, and its pickers wait: a save writes the whole setting,
    /// which may be stale.
    private(set) var answered = false
    private(set) var readFailed = false
    /// A pick is being written: the pickers wait for it.
    private(set) var writing = false
    /// Why Hermes didn't take the last pick, shown under the pickers.
    private(set) var refusal: String?
    /// The pick Hermes' price check asked about, for Use It Anyway.
    private(set) var confirmable: VoiceReplyModelSetting?
    /// Counts the writes: an answer to a read asked before one, or while
    /// one was out, may predate it.
    private var writes = 0
    /// Counts the reads, and names the newest one Hermes answered: an
    /// answer to a read asked before it is older than what's shown.
    private var reads = 0
    private var newestAnsweredRead = 0

    /// A read, as it was asked.
    struct Read {
        fileprivate let number: Int
        fileprivate let writes: Int
        fileprivate let duringWrite: Bool
    }

    mutating func readAsked() -> Read {
        reads += 1
        return Read(number: reads, writes: writes, duringWrite: writing)
    }

    /// Nothing from Hermes is shown yet: the kept setting can be.
    var opensOnKept: Bool { saved == nil && !answered }

    /// The setting Hermes gave last, kept on the phone, drawn before the
    /// first frame while Hermes is asked again.
    mutating func showKept(_ setting: VoiceReplyModelSetting?) {
        guard opensOnKept else { return }
        show(setting)
    }

    /// Hermes' answer to `read`, shown unless a pick's write was out when
    /// it was asked or went out since, as the pick stays then, or a read
    /// asked after it answered first. False for the last: the models read
    /// with it are older than the ones shown too.
    @discardableResult
    mutating func hermesAnswered(_ setting: VoiceReplyModelSetting?, to read: Read) -> Bool {
        guard read.number > newestAnsweredRead else { return false }
        newestAnsweredRead = read.number
        readFailed = false
        if !read.duringWrite, read.writes == writes { show(setting) }
        answered = true
        return true
    }

    /// A read that fails keeps what's shown. One asked before the newest
    /// answer is older than what's shown, and says nothing.
    mutating func readDidFail(_ read: Read) {
        guard read.number > newestAnsweredRead else { return }
        readFailed = true
    }

    /// The setting the picks ask Hermes for, nil when they change nothing:
    /// showing Hermes' setting changes the pickers too. One write is out at
    /// a time, and only once Hermes answered.
    mutating func writeAsked() -> VoiceReplyModelSetting? {
        guard answered, !writing, let saved, chosen != saved else { return nil }
        writing = true
        writes += 1
        refusal = nil
        confirmable = nil
        return chosen
    }

    /// The pick Hermes' price check asked about, written again with the
    /// user's yes; nil when there's none or a write is out.
    mutating func confirmAsked() -> VoiceReplyModelSetting? {
        guard !writing, let confirmable else { return nil }
        writing = true
        writes += 1
        refusal = nil
        self.confirmable = nil
        // Shown while it's written; a refusal puts back what Hermes holds.
        selection = Self.selection(for: confirmable)
        reasoning = confirmable.reasoningEffort ?? Self.inheritReasoning
        return confirmable
    }

    private static func selection(for setting: VoiceReplyModelSetting) -> String {
        setting.followsChats ? sameAsChats : VoiceJobModelSettingsSection.tag(provider: setting.provider, model: setting.model)
    }

    /// The model Hermes runs the slot on, its endpoint's host beside it.
    var endpointCaption: String? {
        saved?.endpointHost.map { AppLocalization.string("Runs on your endpoint at \($0). A model from another provider moves it off.") }
    }

    /// How a write ended: Hermes took it, refused it, or asks first.
    mutating func writeEnded(_ setting: VoiceReplyModelSetting, result: HelperModelSaveResult) {
        switch result {
        case .saved:
            writeEnded(setting, refusal: nil)
        case .refused(let reason):
            writeEnded(setting, refusal: reason)
        case .needsConfirmation(let warning):
            writeEnded(setting, refusal: warning)
            confirmable = setting
        }
    }

    /// Hermes took `setting`, or refused it, saying why: the pickers then
    /// show what Hermes holds again.
    mutating func writeEnded(_ setting: VoiceReplyModelSetting, refusal: String?) {
        writing = false
        guard let refusal else {
            saved = setting
            return
        }
        self.refusal = refusal
        show(saved)
    }

    private var chosen: VoiceReplyModelSetting {
        let pick = selection == Self.sameAsChats ? nil : VoiceJobModelSettingsSection.parse(selection)
        // "Same as chats" unpins the provider too; a provider pinned
        // without a model is a choice of its own.
        let provider = pick.map { $0.provider ?? "auto" } ?? "auto"
        return VoiceReplyModelSetting(
            task: saved?.task ?? VoiceReplyModelSetting.task,
            provider: provider,
            model: pick?.model ?? "",
            reasoningEffort: reasoning == Self.inheritReasoning ? nil : reasoning,
            // The slot's endpoint stays while its provider does, as Hermes
            // keeps it then.
            baseURL: provider == saved?.provider ? saved?.baseURL : nil
        )
    }

    /// Shows `setting`, or hides the section. The saved value goes with the
    /// pickers', so these changes write nothing.
    private mutating func show(_ setting: VoiceReplyModelSetting?) {
        saved = setting
        guard let setting else { return }
        selection = Self.selection(for: setting)
        reasoning = setting.reasoningEffort ?? Self.inheritReasoning
    }
}

/// The model and reasoning Hermes answers classic-voice turns with, or
/// (on a helper model's page) runs one of its helper jobs with. Hidden on
/// a Hermes without the slot.
struct VoiceReplyModelSettingsSection: View {
    let settings: VoiceReplyModelSettingsModel
    /// The page is asking Hermes again (Check again too).
    var pageIsChecking = false
    /// A helper model's own heading and words; nil for Voice replies.
    var helper: HelperModelSlot?
    @State private var picks = VoiceReplyModelPicks()
    @State private var providers: [ProviderInfo] = []
    @State private var providersFailed = false
    /// Hermes answered the models read: only then is a model picked.
    @State private var modelsAnswered = false

    var body: some View {
        Group {
            if picks.saved != nil {
                ConduitSettingsSection(
                    title: helper?.title ?? AppLocalization.string("Voice replies"),
                    symbol: helper?.symbol ?? "waveform.circle",
                    tint: .conduitAura
                ) {
                    ConduitMenuPicker(
                        value: picks.selection,
                        choices: VoiceJobModelSettingsSection.modelChoices(
                            defaultTitle: helper?.followTitle ?? AppLocalization.string("Same as chats"),
                            defaultTag: VoiceReplyModelPicks.sameAsChats,
                            selection: picks.selection,
                            providers: providers
                        ),
                        onSelect: { picks.selection = $0 }
                    ) {
                        Text("Model").foregroundStyle(.secondary)
                    }
                    .disabled(pickersWait || !modelsAnswered)
                    if providersFailed || picks.readFailed {
                        // What's listed stays up; Hermes didn't answer.
                        ModelCatalogPlaceholder(state: .failed) { Task { await tryAgain() } }
                    }
                    ConduitMenuPicker(
                        value: picks.reasoning,
                        choices: reasoningChoices,
                        onSelect: { picks.reasoning = $0 }
                    ) {
                        Text("Reasoning").foregroundStyle(.secondary)
                    }
                    .disabled(pickersWait)
                    if let refusal = picks.refusal {
                        Text(verbatim: refusal)
                            .scaledFont(.caption)
                            .foregroundStyle(picks.confirmable == nil ? .red : .orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if picks.confirmable != nil {
                        // Hermes' price check asked first: the user can
                        // choose the model anyway.
                        Button(AppLocalization.string("Use It Anyway")) { confirm() }
                            .scaledFont(.subheadline.weight(.semibold))
                            .tint(.conduitAccent)
                            .disabled(picks.writing)
                    }
                    if let endpoint = picks.endpointCaption {
                        Text(verbatim: endpoint)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let helper {
                        Text(verbatim: helper.caption)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("The model Hermes answers you with in a voice conversation. Reasoning is off by default so replies start sooner; typed messages keep the chat's model. Hermes Desktop uses this setting too.")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear(perform: showKept)
        .task { await read() }
        // After a read that failed, the page's next check (its Check again
        // too) asks Hermes again.
        .onChange(of: pageIsChecking) { _, checking in
            guard !checking, picks.readFailed else { return }
            Task { await read() }
        }
        .onChange(of: picks.selection) { _, _ in save() }
        .onChange(of: picks.reasoning) { _, _ in save() }
    }

    /// The pickers wait for Hermes' answer and for a save; Try Again
    /// doesn't, as it's how a failed read asks again.
    private var pickersWait: Bool { !picks.answered || picks.writing }

    /// A read that fails keeps what's shown, and the pickers wait.
    private func read() async {
        let asked = picks.readAsked()
        let setting: VoiceReplyModelSetting?
        do {
            setting = try await settings.load()
        } catch {
            picks.readDidFail(asked)
            return
        }
        var loaded: [ProviderInfo]?
        if setting != nil { loaded = await settings.loadProviders() }
        guard picks.hermesAnswered(setting, to: asked) else { return }
        if let loaded {
            providers = loaded
            modelsAnswered = true
        }
        providersFailed = setting != nil && loaded == nil
    }

    /// Asks again for what didn't come: the setting with its models, or
    /// the models alone.
    private func tryAgain() async {
        if picks.readFailed {
            await read()
        } else {
            await reloadProviders()
        }
    }

    private func reloadProviders() async {
        guard let loaded = await settings.loadProviders() else { return }
        providers = loaded
        modelsAnswered = true
        providersFailed = false
    }

    private func showKept() {
        guard picks.opensOnKept else { return }
        providers = settings.keptProviders()
        picks.showKept(settings.kept())
    }

    private var reasoningChoices: [(id: String, title: String)] {
        let levels = VoiceJobModelSettingsSection.reasoningLevels(offTitle: AppLocalization.string("Off"))
        return levels + [(id: VoiceReplyModelPicks.inheritReasoning, title: AppLocalization.string("Same as chats"))]
    }

    private func save() {
        guard let next = picks.writeAsked() else { return }
        Task {
            let result = await settings.save(next, false)
            picks.writeEnded(next, result: result)
        }
    }

    private func confirm() {
        guard let next = picks.confirmAsked() else { return }
        Task {
            let result = await settings.save(next, true)
            picks.writeEnded(next, result: result)
        }
    }
}
