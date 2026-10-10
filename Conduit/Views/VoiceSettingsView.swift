//
//  VoiceSettingsView.swift
//  Conduit
//

import AVFoundation
import SwiftUI
import UIKit

struct VoiceSettingsRoute: View {
    @StateObject private var service: HermesVoiceConfigurationService
    /// The active VoiceConversationController, observed so the Record ASR
    /// input meter tracks live capture without polling or a second capture
    /// service.
    @ObservedObject var conversationController: VoiceConversationController
    let actions: VoiceSettingsActions
    let voiceEnabled: Bool
    let transcriptionMode: VoiceTranscriptionMode
    let transcriptionModeChosen: Bool
    let appleSpeechAvailability: AppleSpeechRecognitionAvailability
    let continuousConversation: Bool
    let spokenStopPhrases: [String]
    let spokenEndConversationPhrases: [String]
    let setVoiceEnabled: (Bool) async -> Bool
    let setTranscriptionMode: (VoiceTranscriptionMode) async -> Bool
    let setContinuousConversation: (Bool) async -> Bool
    let setStopPhrases: ([String]) -> Bool
    let setEndConversationPhrases: ([String]) -> Bool
    let geminiLive: GeminiLiveSettingsModel?
    let gptLive: GPTLiveSettingsModel?
    let grokLive: GrokLiveSettingsModel?
    let liveStyle: LiveVoiceStyleSettingsModel?
    let voiceJobs: VoiceJobModelSettingsModel?
    let voiceReplies: VoiceReplyModelSettingsModel?
    let wake: WakePhraseSettingsModel?
    let lockedListening: VoiceLockedListeningSettingsModel?
    let speakerTalkOver: VoiceSpeakerTalkOverSettingsModel?
    let callSaves: VoiceCallSaveStatusModel?
    let hermesCalls: HermesCallSettingsModel?

    init(
        bridge: DashboardTicketBridge,
        profile: String,
        conversationController: VoiceConversationController,
        actions: VoiceSettingsActions,
        voiceEnabled: Bool,
        transcriptionMode: VoiceTranscriptionMode,
        transcriptionModeChosen: Bool = false,
        appleSpeechAvailability: AppleSpeechRecognitionAvailability,
        continuousConversation: Bool = true,
        spokenStopPhrases: [String] = VoiceSpokenCommandDefaults.stopPhrases,
        spokenEndConversationPhrases: [String] = VoiceSpokenCommandDefaults.endConversationPhrases,
        setVoiceEnabled: @escaping (Bool) async -> Bool,
        setTranscriptionMode: @escaping (VoiceTranscriptionMode) async -> Bool,
        setContinuousConversation: @escaping (Bool) async -> Bool = { _ in true },
        setStopPhrases: @escaping ([String]) -> Bool = { _ in true },
        setEndConversationPhrases: @escaping ([String]) -> Bool = { _ in true },
        geminiLive: GeminiLiveSettingsModel? = nil,
        gptLive: GPTLiveSettingsModel? = nil,
        grokLive: GrokLiveSettingsModel? = nil,
        liveStyle: LiveVoiceStyleSettingsModel? = nil,
        voiceJobs: VoiceJobModelSettingsModel? = nil,
        voiceReplies: VoiceReplyModelSettingsModel? = nil,
        wake: WakePhraseSettingsModel? = nil,
        lockedListening: VoiceLockedListeningSettingsModel? = nil,
        speakerTalkOver: VoiceSpeakerTalkOverSettingsModel? = nil,
        callSaves: VoiceCallSaveStatusModel? = nil,
        hermesCalls: HermesCallSettingsModel? = nil
    ) {
        self.geminiLive = geminiLive
        self.gptLive = gptLive
        self.grokLive = grokLive
        self.liveStyle = liveStyle
        self.voiceJobs = voiceJobs
        self.voiceReplies = voiceReplies
        self.wake = wake
        self.lockedListening = lockedListening
        self.speakerTalkOver = speakerTalkOver
        self.callSaves = callSaves
        self.hermesCalls = hermesCalls
        _service = StateObject(wrappedValue: HermesVoiceConfigurationService(bridge: bridge, profile: profile))
        _conversationController = ObservedObject(wrappedValue: conversationController)
        self.actions = actions
        self.voiceEnabled = voiceEnabled
        self.transcriptionMode = transcriptionMode
        self.transcriptionModeChosen = transcriptionModeChosen
        self.appleSpeechAvailability = appleSpeechAvailability
        self.continuousConversation = continuousConversation
        self.spokenStopPhrases = spokenStopPhrases
        self.spokenEndConversationPhrases = spokenEndConversationPhrases
        self.setVoiceEnabled = setVoiceEnabled
        self.setTranscriptionMode = setTranscriptionMode
        self.setContinuousConversation = setContinuousConversation
        self.setStopPhrases = setStopPhrases
        self.setEndConversationPhrases = setEndConversationPhrases
    }

    var body: some View {
        VoiceSettingsView(
            service: service,
            conversationController: conversationController,
            actions: actions,
            voiceEnabled: voiceEnabled,
            transcriptionMode: transcriptionMode,
            transcriptionModeChosen: transcriptionModeChosen,
            appleSpeechAvailability: appleSpeechAvailability,
            continuousConversation: continuousConversation,
            spokenStopPhrases: spokenStopPhrases,
            spokenEndConversationPhrases: spokenEndConversationPhrases,
            setVoiceEnabled: setVoiceEnabled,
            setTranscriptionMode: setTranscriptionMode,
            setContinuousConversation: setContinuousConversation,
            setStopPhrases: setStopPhrases,
            setEndConversationPhrases: setEndConversationPhrases,
            geminiLive: geminiLive,
            gptLive: gptLive,
            grokLive: grokLive,
            liveStyle: liveStyle,
            voiceJobs: voiceJobs,
            voiceReplies: voiceReplies,
            wake: wake,
            lockedListening: lockedListening,
            speakerTalkOver: speakerTalkOver,
            callSaves: callSaves,
            hermesCalls: hermesCalls
        )
    }
}

struct VoiceSettingsActions {
    var runASRTest: (() async -> VoiceProviderTestResult)?
    var runTTSTest: (() async -> VoiceProviderTestResult)?

    init(
        runASRTest: (() async -> VoiceProviderTestResult)? = nil,
        runTTSTest: (() async -> VoiceProviderTestResult)? = nil
    ) {
        self.runASRTest = runASRTest
        self.runTTSTest = runTTSTest
    }
}

/// A profile-scoped route. It is usable as a NavigationStack destination or
/// standalone in a sheet; the host app supplies live-audio test closures after
/// it has built the active VoiceConversationController.
struct VoiceSettingsView: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @ObservedObject var service: HermesVoiceConfigurationService
    /// Observed so the Record ASR meter tracks the active controller's raw
    /// microphone level (issue #130): a moving meter proves capture works
    /// and localizes detection failures to the VAD/provider boundary.
    @ObservedObject var conversationController: VoiceConversationController
    var actions = VoiceSettingsActions()
    let setVoiceEnabled: (Bool) async -> Bool
    let setTranscriptionMode: (VoiceTranscriptionMode) async -> Bool
    let setContinuousConversation: (Bool) async -> Bool

    @State private var values: [String: String] = [:]
    @State private var credentialDrafts: [String: String] = [:]
    @State private var savingField: String?
    @State private var testStatus: String?
    @State private var isRunningTest = false
    @State private var isRecordingASRTest = false
    @State private var voiceEnabled: Bool
    @State private var transcriptionMode: VoiceTranscriptionMode
    @State private var appleSpeechAvailability: AppleSpeechRecognitionAvailability
    @State private var continuousConversation: Bool
    /// Whether the profile has a saved speech-to-text choice. Turning voice
    /// on picks "On this iPhone" only when it doesn't.
    @State private var transcriptionModeChosen: Bool
    /// The saved preference as the host last rendered it, so a choice made
    /// elsewhere while this page is open is kept too.
    let savedTranscriptionModeChosen: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var voiceMode: VoiceMode
    @State private var isApplyingDefaults = false
    @State private var microphonePermission: AVAudioApplication.recordPermission
    @AppStorage(VoiceScreenAwake.preferenceKey) private var keepScreenAwake = false
    @AppStorage(LiveVoiceOrbPower.preferenceKey) private var animateCallOrb = true
    @AppStorage(ReadAloudSpeed.preferenceKey) private var readAloudSpeedRaw = ReadAloudSpeed.normal.rawValue
    @AppStorage("conduit.voice.settingsAdvancedExpanded") private var advancedExpanded = false
    let spokenStopPhrases: [String]
    let spokenEndConversationPhrases: [String]
    let setStopPhrases: ([String]) -> Bool
    let setEndConversationPhrases: ([String]) -> Bool
    var geminiLive: GeminiLiveSettingsModel?
    var gptLive: GPTLiveSettingsModel?
    var grokLive: GrokLiveSettingsModel?
    var liveStyle: LiveVoiceStyleSettingsModel?
    var voiceJobs: VoiceJobModelSettingsModel?
    var voiceReplies: VoiceReplyModelSettingsModel?
    var wake: WakePhraseSettingsModel?
    var lockedListening: VoiceLockedListeningSettingsModel?
    var speakerTalkOver: VoiceSpeakerTalkOverSettingsModel?
    var callSaves: VoiceCallSaveStatusModel?
    var hermesCalls: HermesCallSettingsModel?
    @State private var keepListeningWhenLocked: Bool
    @State private var speakerTalkOverEnabled: Bool
    /// The phrase lists as last saved from this page. AppState doesn't
    /// publish a phrase save, so the page keeps its own copy for the
    /// editors and the reset button instead of waiting for a re-render.
    @State private var stopPhrasesShown: [String]
    @State private var endPhrasesShown: [String]
    @State private var stopPhrasesCustomized: Bool
    @State private var endPhrasesCustomized: Bool
    /// Bumped to reseed the phrase editors (a reset, a profile or language
    /// switch), never by the editors' own saves, so adding phrases keeps
    /// the keyboard up.
    @State private var phraseEditorsGeneration = 0

    init(
        service: HermesVoiceConfigurationService,
        conversationController: VoiceConversationController,
        actions: VoiceSettingsActions = VoiceSettingsActions(),
        voiceEnabled: Bool = false,
        transcriptionMode: VoiceTranscriptionMode = .hermes,
        transcriptionModeChosen: Bool = false,
        appleSpeechAvailability: AppleSpeechRecognitionAvailability = .permissionRequired(localeIdentifier: Locale.current.identifier),
        continuousConversation: Bool = true,
        spokenStopPhrases: [String] = VoiceSpokenCommandDefaults.stopPhrases,
        spokenEndConversationPhrases: [String] = VoiceSpokenCommandDefaults.endConversationPhrases,
        setVoiceEnabled: @escaping (Bool) async -> Bool = { _ in false },
        setTranscriptionMode: @escaping (VoiceTranscriptionMode) async -> Bool = { _ in false },
        setContinuousConversation: @escaping (Bool) async -> Bool = { _ in true },
        setStopPhrases: @escaping ([String]) -> Bool = { _ in true },
        setEndConversationPhrases: @escaping ([String]) -> Bool = { _ in true },
        geminiLive: GeminiLiveSettingsModel? = nil,
        gptLive: GPTLiveSettingsModel? = nil,
        grokLive: GrokLiveSettingsModel? = nil,
        liveStyle: LiveVoiceStyleSettingsModel? = nil,
        voiceJobs: VoiceJobModelSettingsModel? = nil,
        voiceReplies: VoiceReplyModelSettingsModel? = nil,
        wake: WakePhraseSettingsModel? = nil,
        lockedListening: VoiceLockedListeningSettingsModel? = nil,
        speakerTalkOver: VoiceSpeakerTalkOverSettingsModel? = nil,
        callSaves: VoiceCallSaveStatusModel? = nil,
        hermesCalls: HermesCallSettingsModel? = nil
    ) {
        self.geminiLive = geminiLive
        self.gptLive = gptLive
        self.grokLive = grokLive
        self.liveStyle = liveStyle
        self.voiceJobs = voiceJobs
        self.voiceReplies = voiceReplies
        self.wake = wake
        self.lockedListening = lockedListening
        self.speakerTalkOver = speakerTalkOver
        self.callSaves = callSaves
        self.hermesCalls = hermesCalls
        _keepListeningWhenLocked = State(initialValue: lockedListening?.enabled ?? false)
        _speakerTalkOverEnabled = State(initialValue: speakerTalkOver?.enabled ?? false)
        self.service = service
        _conversationController = ObservedObject(wrappedValue: conversationController)
        self.actions = actions
        self.setVoiceEnabled = setVoiceEnabled
        self.setTranscriptionMode = setTranscriptionMode
        self.setContinuousConversation = setContinuousConversation
        self.spokenStopPhrases = spokenStopPhrases
        self.spokenEndConversationPhrases = spokenEndConversationPhrases
        self.setStopPhrases = setStopPhrases
        self.setEndConversationPhrases = setEndConversationPhrases
        _stopPhrasesShown = State(initialValue: spokenStopPhrases)
        _endPhrasesShown = State(initialValue: spokenEndConversationPhrases)
        _stopPhrasesCustomized = State(initialValue: Self.isCustomStopList(spokenStopPhrases))
        _endPhrasesCustomized = State(initialValue: Self.isCustomEndList(spokenEndConversationPhrases))
        _voiceEnabled = State(initialValue: voiceEnabled)
        _transcriptionMode = State(initialValue: transcriptionMode)
        _transcriptionModeChosen = State(initialValue: transcriptionModeChosen)
        self.savedTranscriptionModeChosen = transcriptionModeChosen
        _microphonePermission = State(initialValue: AVAudioApplication.shared.recordPermission)
        _voiceMode = State(initialValue: Self.mode(
            gemini: geminiLive?.enabled == true,
            gpt: gptLive?.enabled == true,
            grok: grokLive?.enabled == true
        ))
        _appleSpeechAvailability = State(initialValue: appleSpeechAvailability)
        _continuousConversation = State(initialValue: continuousConversation)
    }

    var body: some View {
        ZStack {
            ConduitBackdrop()
            ScrollView {
                // Setup first, then what most people change. Provider
                // detail, models and tuning wait under Advanced.
                VStack(alignment: .leading, spacing: 14) {
                    if let callSaves, callSaves.pendingCount > 0 {
                        VoiceCallSaveStatusSection(model: callSaves)
                    }
                    setupSection
                    voiceModeSection
                    liveModeSettings
                    conversationSection
                    // "Call me when it's done" is asked in a live call (#449).
                    if voiceMode != .classic, let hermesCalls {
                        HermesCallSettingsSection(model: hermesCalls)
                    }
                    wakeSection
                    CarPlaySettingsSection()
                    WatchSettingsSection()
                    readAloudSection
                    advancedSection
                }
                .padding(16)
            }
        }
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: service.snapshot.values) { _, newValues in
            // Preserve unsaved text while a provider field is being edited.
            for (key, value) in newValues where values[key] == nil { values[key] = value }
        }
        // A mode changed elsewhere (CarPlay, another profile's settings)
        // while this page stays open.
        .onChange(of: modelVoiceMode) { _, newValue in voiceMode = newValue }
        // The setup step's fix ("choose one under Speech to text below")
        // lives under Advanced.
        .onChange(of: classicSpeechNeedsAttention, initial: true) { _, needsAttention in
            if needsAttention { advancedExpanded = true }
        }
        // A profile switch or an app language change re-renders the host
        // with other lists.
        .onChange(of: spokenStopPhrases) { _, phrases in
            guard phrases != stopPhrasesShown else { return }
            stopPhrasesShown = phrases
            stopPhrasesCustomized = Self.isCustomStopList(phrases)
            phraseEditorsGeneration += 1
        }
        .onChange(of: spokenEndConversationPhrases) { _, phrases in
            guard phrases != endPhrasesShown else { return }
            endPhrasesShown = phrases
            endPhrasesCustomized = Self.isCustomEndList(phrases)
            phraseEditorsGeneration += 1
        }
        .onChange(of: savedTranscriptionModeChosen) { _, chosen in
            if chosen { transcriptionModeChosen = true }
        }
        // Back from iPhone Settings: the permission steps show what was allowed.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            microphonePermission = AVAudioApplication.shared.recordPermission
            appleSpeechAvailability = AppleOnDeviceSpeechTranscriber.currentAvailability()
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Set up voice

    private var setupSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Set up voice"), symbol: "mic.badge.plus", tint: .conduitAccent) {
            Toggle("Enable voice on this device", isOn: Binding(
                get: { voiceEnabled },
                set: { setVoice($0) }
            ))
            .disabled(isApplyingDefaults)
            .accessibilityIdentifier("voice.enableToggle")
            Text(voiceEnabled
                 ? AppLocalization.string("Voice is on for \(profileDisplayName) on this iPhone. Each step below turns green when it's ready; an orange step has a fix.")
                 : AppLocalization.string("Turn this on to talk to \(profileDisplayName). Conduit asks for the microphone and Speech Recognition, uses this iPhone for speech to text, and switches the assistant's voice to Edge TTS on Hermes if the current one isn't ready."))
                .font(.caption)
                .foregroundStyle(.secondary)
            if isApplyingDefaults {
                ProgressView(AppLocalization.string("Setting up voice…"))
                    .font(.footnote)
            }
            if voiceEnabled {
                setupChecklist
                // The tests run classic Voice's speech route; testButtons
                // assumes Classic. A test already running keeps its status.
                if voiceMode == .classic || isRunningTest { testButtons }
            }
            if let error = service.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var setupChecklist: some View {
        VStack(alignment: .leading, spacing: 12) {
            hermesStep
            microphoneStep
            if voiceMode == .classic {
                speechToTextStep
                assistantVoiceStep
            } else {
                Text(verbatim: AppLocalization.string("\(voiceMode.title) brings its own listening and speaking, so the speech-to-text and assistant voice steps don't apply. Pick Classic under Voice mode to use them."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await load() }
            } label: {
                Label(service.isLoading ? AppLocalization.string("Checking…") : AppLocalization.string("Check again"), systemImage: "arrow.clockwise")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .disabled(service.isLoading || isApplyingDefaults)
        }
    }

    private var hermesStep: some View {
        let capability = service.snapshot.capability
        if service.isLoading {
            return setupStep(AppLocalization.string("Hermes"), detail: AppLocalization.string("Checking…"), state: .pending)
        }
        if capability.isGatewayConnected {
            return setupStep(AppLocalization.string("Hermes"), detail: AppLocalization.string("Connected to \(profileDisplayName)"), state: .done)
        }
        return setupStep(
            AppLocalization.string("Hermes"),
            detail: capability.unavailableReason ?? AppLocalization.string("Connect to Hermes before starting voice."),
            state: .attention
        )
    }

    private var microphoneStep: some View {
        switch microphonePermission {
        case .granted:
            return setupStep(AppLocalization.string("Microphone"), detail: AppLocalization.string("Allowed"), state: .done)
        case .denied:
            return setupStep(
                AppLocalization.string("Microphone"),
                detail: AppLocalization.string("Not allowed. Allow the microphone for Conduit in iPhone Settings."),
                state: .attention,
                fix: (label: AppLocalization.string("Open Settings"), action: openSystemSettings)
            )
        default:
            return setupStep(AppLocalization.string("Microphone"), detail: AppLocalization.string("iOS asks the first time you talk."), state: .pending)
        }
    }

    private var speechToTextStep: some View {
        let title = AppLocalization.string("Speech to text")
        if transcriptionMode == .appleOnDevice {
            switch appleSpeechAvailability {
            case .ready:
                return setupStep(title, detail: AppLocalization.string("On this iPhone"), state: .done)
            case .permissionRequired:
                return setupStep(
                    title,
                    detail: AppLocalization.string("On this iPhone. Speech Recognition isn't allowed yet."),
                    state: .pending,
                    fix: (label: AppLocalization.string("Allow"), action: { selectProvider(Self.appleProviderID, kind: .stt, force: true) })
                )
            case .permissionDenied:
                return setupStep(
                    title,
                    detail: AppLocalization.string("Speech Recognition isn't allowed. Allow it for Conduit in iPhone Settings, or choose a Hermes provider under Speech to text below."),
                    state: .attention,
                    fix: (label: AppLocalization.string("Open Settings"), action: openSystemSettings)
                )
            case .unsupported:
                return setupStep(
                    title,
                    detail: AppLocalization.string("This iPhone can't transcribe your language on the device. Choose a Hermes provider under Speech to text below."),
                    state: .attention
                )
            }
        }
        if service.isLoading || !service.snapshot.capability.isGatewayConnected {
            return setupStep(title, detail: AppLocalization.string("Not checked yet"), state: .pending)
        }
        let name = providerName(service.snapshot.selectedSTTProvider, kind: .stt)
        var useIPhone: (label: String, action: () -> Void)?
        if appleSpeechAvailability.canAttemptRecognition {
            useIPhone = (label: AppLocalization.string("Use this iPhone"), action: { selectProvider(Self.appleProviderID, kind: .stt) })
        }
        if !service.snapshot.capability.supportsTranscription {
            return setupStep(
                title,
                detail: service.snapshot.capability.unavailableReason ?? AppLocalization.string("This Hermes profile has no ready speech-to-text provider."),
                state: .attention,
                fix: useIPhone
            )
        }
        switch VoiceSetupDefaults.providerReadiness(service.snapshot.selectedSTTProvider, in: service.snapshot.sttProviders) {
        case .ready:
            return setupStep(title, detail: AppLocalization.string("\(name) on Hermes"), state: .done)
        case .notReady(let status):
            return setupStep(
                title,
                detail: AppLocalization.string("\(name) on Hermes isn't ready (\(VoiceProviderReadiness.label(forStatus: status))). This iPhone can do it instead, with nothing to install."),
                state: .attention,
                fix: useIPhone
            )
        case .unknown:
            return setupStep(title, detail: AppLocalization.string("\(name) on Hermes. Hermes doesn't report whether it's ready."), state: .pending, fix: useIPhone)
        }
    }

    private var assistantVoiceStep: some View {
        let title = AppLocalization.string("Assistant voice")
        let name = providerName(service.snapshot.selectedTTSProvider, kind: .tts)
        if service.snapshot.capability.supportsSpeech {
            return setupStep(title, detail: AppLocalization.string("\(name) on Hermes"), state: .done)
        }
        if VoiceSetupDefaults.canSwitchSpeechToEdge(service.snapshot) {
            return setupStep(
                title,
                detail: service.snapshot.selectedTTSProvider.isEmpty
                    ? AppLocalization.string("No assistant voice is set up yet. Edge TTS is free and ready.")
                    : AppLocalization.string("\(name) isn't ready on Hermes. Edge TTS is free and ready."),
                state: .attention,
                fix: (label: AppLocalization.string("Use Edge TTS"), action: { selectProvider(VoiceSetupDefaults.edgeTTSProviderID, kind: .tts) })
            )
        }
        if service.isLoading || !service.snapshot.capability.isGatewayConnected {
            return setupStep(title, detail: AppLocalization.string("Not checked yet"), state: .pending)
        }
        return setupStep(
            title,
            detail: service.snapshot.selectedTTSProvider.isEmpty
                ? AppLocalization.string("No assistant voice is set up yet. Choose one under Assistant speech below.")
                : AppLocalization.string("\(name) isn't ready on Hermes. Choose another under Assistant speech below."),
            state: .attention
        )
    }

    private enum SetupStepState {
        case done, attention, pending

        var color: Color {
            switch self {
            case .done: return .green
            case .attention: return .orange
            case .pending: return .secondary
            }
        }

        var accessibilityValue: String {
            switch self {
            case .done: return AppLocalization.string("Ready")
            case .attention: return AppLocalization.string("Needs attention")
            case .pending: return AppLocalization.string("Not checked yet")
            }
        }
    }

    private func setupStep(
        _ title: String,
        detail: String,
        state: SetupStepState,
        fix: (label: String, action: () -> Void)? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: state == .done ? "checkmark.circle.fill" : (state == .attention ? "exclamationmark.circle.fill" : "circle.dashed"))
                .foregroundStyle(state.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.subheadline.weight(.semibold))
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(Text(verbatim: state.accessibilityValue))
            Spacer(minLength: 8)
            if let fix {
                Button(fix.label, action: fix.action)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
                    .disabled(savingField != nil || isApplyingDefaults)
            }
        }
    }

    private var testButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            AdaptiveStack(spacing: 10) {
                Button { runTest(kind: .stt) } label: {
                    Label(AppLocalization.string("Test listening"), systemImage: "mic")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6).frame(minHeight: 46)
                }
                .disabled(actions.runASRTest == nil || isRunningTest || !supportsSelectedTranscription)
                .conduitGlassControl(cornerRadius: 16, tint: .conduitAura.opacity(0.14))
                .accessibilityHint(AppLocalization.string("Records a short sample and shows what speech to text heard"))

                Button { runTest(kind: .tts) } label: {
                    Label(AppLocalization.string("Test speaking"), systemImage: "speaker.wave.2")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6).frame(minHeight: 46)
                }
                .disabled(actions.runTTSTest == nil || isRunningTest || !service.snapshot.capability.supportsSpeech)
                .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.14))
                .accessibilityHint(AppLocalization.string("Plays a short sample in the assistant's voice"))
            }
            if let testStatus {
                Text(testStatus).font(.footnote).foregroundStyle(.secondary)
            } else if actions.runASRTest == nil || actions.runTTSTest == nil {
                Text("Live tests become available when the active voice session is connected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // The meter is visible only while the listening test is actually
            // recording (state .listening): once the sample is complete and
            // the state becomes .transcribing, capture input is no longer
            // the interesting signal, so the meter hides instead of
            // freezing at its last value. Never shown during TTS playback.
            if isRecordingASRTest, conversationController.state == .listening {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Microphone input")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VoiceInputLevelMeter(level: conversationController.microphoneLevel, isActive: true)
                        .frame(height: 20)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Microphone input level"))
            }
        }
    }

    private func setVoice(_ requested: Bool) {
        let previous = voiceEnabled
        voiceEnabled = requested
        // Holds the switch from the tap on, so a second tap can't turn voice
        // off while the defaults are still being written.
        if requested { isApplyingDefaults = true }
        Task {
            guard await setVoiceEnabled(requested) else {
                voiceEnabled = previous
                if requested { isApplyingDefaults = false }
                return
            }
            if requested { await applySetupDefaults() }
        }
    }

    /// The one-switch happy path: fills in a speech-to-text choice and an
    /// assistant voice that work without anything installed on Hermes.
    /// A live mode brings its own speech, so the profile's Hermes speech
    /// config is left alone then; picking Classic shows the fixes instead.
    private func applySetupDefaults() async {
        isApplyingDefaults = true
        defer { isApplyingDefaults = false }
        guard voiceMode == .classic else { return }
        if !service.snapshot.capability.isGatewayConnected { await load() }
        let plan = VoiceSetupDefaults.plan(
            transcriptionModeChosen: transcriptionModeChosen,
            appleSpeechAvailability: AppleOnDeviceSpeechTranscriber.currentAvailability(),
            snapshot: service.snapshot
        )
        if plan.usesOnDeviceTranscription {
            await applyProvider(Self.appleProviderID, kind: .stt)
        }
        if plan.switchesSpeechToEdge {
            await applyProvider(VoiceSetupDefaults.edgeTTSProviderID, kind: .tts)
        }
        await load()
    }

    // MARK: Voice mode

    private enum VoiceMode: String, CaseIterable {
        case classic, gemini, gpt, grok

        var title: String {
            switch self {
            case .classic: return AppLocalization.string("Classic")
            case .gemini: return AppLocalization.string("Gemini Live")
            case .gpt: return AppLocalization.string("GPT-Live")
            case .grok: return AppLocalization.string("Grok Live")
            }
        }

        var summary: String {
            switch self {
            case .classic:
                return AppLocalization.string("Hermes listens and replies with the speech to text and assistant voice set up above. Works with any Hermes server.")
            case .gemini:
                return AppLocalization.string("A real-time conversation with Gemini that hands the work to Hermes. Needs the Hermes notifier plugin and a Gemini key on your Hermes server.")
            case .gpt:
                return AppLocalization.string("A real-time conversation on your Hermes server's ChatGPT sign-in that hands the work to Hermes. Needs the Hermes notifier plugin.")
            case .grok:
                return AppLocalization.string("A real-time conversation with Grok through your Hermes server's SuperGrok sign-in that hands the work to Hermes. Needs the Hermes notifier plugin.")
            }
        }
    }

    /// The mode the profile's saved preferences say is on.
    private var modelVoiceMode: VoiceMode {
        Self.mode(gemini: geminiLive?.enabled == true, gpt: gptLive?.enabled == true, grok: grokLive?.enabled == true)
    }

    private static func mode(gemini: Bool, gpt: Bool, grok: Bool) -> VoiceMode {
        if gemini { return .gemini }
        if gpt { return .gpt }
        if grok { return .grok }
        return .classic
    }

    private var availableVoiceModes: [VoiceMode] {
        VoiceMode.allCases.filter { mode in
            switch mode {
            case .classic: return true
            case .gemini: return geminiLive != nil
            case .gpt: return gptLive != nil
            case .grok: return grokLive != nil
            }
        }
    }

    @ViewBuilder
    private var voiceModeSection: some View {
        if availableVoiceModes.count > 1 {
            ConduitSettingsSection(title: AppLocalization.string("Voice mode"), symbol: "waveform", tint: .conduitAura) {
                ConduitMenuPicker(
                    value: voiceMode.rawValue,
                    choices: availableVoiceModes.map { (id: $0.rawValue, title: $0.title) },
                    onSelect: { selectVoiceMode($0) }
                ) {
                    Text("Mode").foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("voice.modePicker")
                Text(verbatim: voiceMode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The picked live mode's own settings, shown right under the picker.
    @ViewBuilder
    private var liveModeSettings: some View {
        switch voiceMode {
        case .classic:
            EmptyView()
        case .gemini:
            if let geminiLive { GeminiLiveSettingsSection(model: geminiLive, showsModeToggle: false) }
        case .gpt:
            if let gptLive { GPTLiveSettingsSection(model: gptLive, showsModeToggle: false) }
        case .grok:
            if let grokLive { GrokLiveSettingsSection(model: grokLive, showsModeToggle: false) }
        }
    }

    // MARK: Advanced

    /// Collapsed by default and remembered on this device. Opens by itself
    /// when a Classic setup step needs a fix that lives in here.
    @ViewBuilder
    private var advancedSection: some View {
        Button {
            withAnimation(.snappy) { advancedExpanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Label(AppLocalization.string("Advanced"), systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.conduitAura)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(advancedExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                if !advancedExpanded {
                    Text("Speech providers, voice models, spoken phrases and experimental options.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .conduitGlassSurface(cornerRadius: 24, tint: Color.conduitAura.opacity(0.07))
        .accessibilityValue(Text(advancedExpanded ? AppLocalization.string("Expanded") : AppLocalization.string("Collapsed")))
        .accessibilityIdentifier("voice.advancedToggle")
        if advancedExpanded {
            if voiceMode != .classic, let liveStyle {
                LiveVoiceStyleSettingsSection(model: liveStyle)
            }
            spokenControlsSection
            if voiceMode == .classic {
                if service.isLoading {
                    ProgressView("Loading profile voice settings…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                } else if service.snapshot.capability.isGatewayConnected {
                    providerSection(title: AppLocalization.string("Speech to text"), symbol: "waveform", kind: .stt, providers: service.snapshot.sttProviders)
                    providerSection(title: AppLocalization.string("Assistant speech"), symbol: "speaker.wave.3", kind: .tts, providers: service.snapshot.ttsProviders)
                    credentialsSection
                }
                if let voiceReplies {
                    VoiceReplyModelSettingsSection(settings: voiceReplies)
                }
            }
            if let voiceJobs {
                VoiceJobModelSettingsSection(settings: voiceJobs)
            }
            speakerAndCallScreenSection
        }
    }

    /// A Classic step the provider sections below fix.
    private var classicSpeechNeedsAttention: Bool {
        guard voiceEnabled, voiceMode == .classic, !service.isLoading,
              service.snapshot.capability.isGatewayConnected else { return false }
        return !supportsSelectedTranscription || !service.snapshot.capability.supportsSpeech
    }

    private func selectVoiceMode(_ id: String) {
        guard let mode = VoiceMode(rawValue: id), mode != voiceMode else { return }
        voiceMode = mode
        // Turning one live mode on turns the others off (AppState keeps one
        // live engine per profile); Classic is every live mode off.
        switch mode {
        case .classic:
            geminiLive?.setEnabled(false)
            gptLive?.setEnabled(false)
            grokLive?.setEnabled(false)
        case .gemini: geminiLive?.setEnabled(true)
        case .gpt: gptLive?.setEnabled(true)
        case .grok: grokLive?.setEnabled(true)
        }
    }

    // MARK: Conversation

    private var conversationSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Conversation"), symbol: "bubble.left.and.bubble.right", tint: .conduitAccent) {
            Toggle("Continuous Conversation", isOn: Binding(
                get: { continuousConversation },
                set: { requested in
                    let previous = continuousConversation
                    continuousConversation = requested
                    Task {
                        if !(await setContinuousConversation(requested)) {
                            continuousConversation = previous
                        }
                    }
                }
            ))
            .accessibilityHint("Automatically listens again after each response and keeps listening through silence. Turn off to start each listening turn manually.")
            Text("When enabled, Conduit automatically listens again after each response and keeps listening through long silences until you pause the mic. When disabled, the session stays open and you start the next listening turn manually. This does not change Pause Mic, Interrupt, Close, or wake-word settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let lockedListening {
                Toggle("Keep listening when locked", isOn: Binding(
                    get: { keepListeningWhenLocked },
                    set: { requested in
                        let previous = keepListeningWhenLocked
                        keepListeningWhenLocked = requested
                        if !lockedListening.setEnabled(requested) {
                            keepListeningWhenLocked = previous
                        }
                    }
                ))
                .onChange(of: lockedListening.enabled) { _, newValue in keepListeningWhenLocked = newValue }
                Text("A voice conversation that is already listening keeps going when you lock the phone or switch apps, so you can talk hands-free. While locked, Conduit always listens again after each response and keeps listening through silence. End it by saying a goodbye phrase or from the app. Uses more battery.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Keep phone awake during voice conversations", isOn: $keepScreenAwake)
            Text("The screen stays on while a voice conversation is open, including the live voice modes. When off, the phone locks on its usual timer: live voice calls keep going in the background, and a classic voice conversation does too with Keep Listening When Locked on. Applies to this device.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The experimental talk-over switch and the call orb, under Advanced.
    private var speakerAndCallScreenSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Speaker and call screen"), symbol: "speaker.wave.2.circle", tint: .conduitAccent) {
            if let speakerTalkOver {
                Toggle("Talk over Hermes on the speaker", isOn: Binding(
                    get: { speakerTalkOverEnabled },
                    set: { requested in
                        speakerTalkOverEnabled = requested
                        speakerTalkOver.setEnabled(requested)
                    }
                ))
                .onChange(of: speakerTalkOver.enabled) { _, newValue in speakerTalkOverEnabled = newValue }
                Text("Experimental. Keeps the microphone open while Hermes reads its reply on the phone's speaker or in the car, with iOS echo cancellation, so you can speak over it to start a new turn. Headphones and AirPods always allow this. Turn it off if Hermes keeps cutting itself off. Shared with Gemini Live and Grok Live. Applies to the next conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Animate the call orb", isOn: $animateCallOrb)
                .accessibilityIdentifier("voice.animateCallOrb")
                .accessibilityHint("The orb on the live call screen moves with the call. Turn this off for a still orb that uses less battery. It also holds still while the phone is hot or Reduce Motion is on. Applies to this device.")
            Text("The orb on the live call screen moves with the call. Turn this off for a still orb that uses less battery. It also holds still while the phone is hot or Reduce Motion is on. Applies to this device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                // The switch's hint already reads this.
                .accessibilityHidden(true)
        }
    }

    // MARK: Read aloud

    private var readAloudSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Read Aloud"), symbol: "speaker.wave.2", tint: .conduitAccent) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Speed")
                    .font(.subheadline.weight(.semibold))
                Picker("Speed", selection: Binding(
                    get: { ReadAloudSpeed(rawValue: readAloudSpeedRaw) ?? .normal },
                    set: { readAloudSpeedRaw = $0.rawValue }
                )) {
                    ForEach(ReadAloudSpeed.allCases) { speed in
                        Text(verbatim: speed.label).tag(speed)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("voice.readAloudSpeed")
            }
            Text("How fast the speaker button under a reply reads it aloud, without changing the voice's pitch. Applies from the next reply you play, on this device. Voice conversations always play at normal speed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func providerSection(
        title: String,
        symbol: String,
        kind: VoiceProviderDescriptor.Kind,
        providers: [VoiceProviderConfiguration]
    ) -> some View {
        let choices = providerChoices(kind: kind, providers: providers)
        ConduitSettingsSection(title: title, symbol: symbol, tint: kind == .stt ? .conduitAura : .conduitAccent) {
            if choices.isEmpty {
                Text(kind == .stt
                     ? AppLocalization.string("No transcription providers were discovered for this Hermes profile.")
                     : AppLocalization.string("No speech providers were discovered for this Hermes profile."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ConduitMenuPicker(
                    value: selectedProviderChoice(kind),
                    choices: choices,
                    onSelect: { selectProvider($0, kind: kind) }
                ) {
                    Text("Provider").foregroundStyle(.secondary)
                }
                .disabled(service.isLoading || savingField == "\(kind.rawValue).provider")
                .accessibilityHint(kind == .stt ? AppLocalization.string("Choose on-device Apple speech or a provider reported by Hermes") : AppLocalization.string("Provider options are reported by Hermes for this profile"))

                if kind == .stt, transcriptionMode == .appleOnDevice {
                    appleOnDeviceDetail
                } else if let selected = providers.first(where: { $0.descriptor.id == selectedProvider(kind) }) {
                    providerDetail(selected)
                } else if let fallback = providers.first {
                    providerDetail(fallback)
                }
                if kind == .stt, transcriptionMode != .appleOnDevice {
                    liveTranscriptionToggle
                }
            }
        }
    }

    /// Hermes' `stt.streaming`: words appear while the user speaks.
    private var liveTranscriptionToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Show words while you speak", isOn: Binding(
                get: { service.snapshot.liveTranscription },
                set: { enabled in Task { _ = await service.saveLiveTranscription(enabled) } }
            ))
            .disabled(service.isLoading)
            Text("Hermes transcribes while you talk, so your words show up as you say them and are ready as soon as you stop. Works with OpenAI, xAI and ElevenLabs speech to text. This is a Hermes setting, so Hermes Desktop and the terminal use it too.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var appleOnDeviceDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            let isReady = appleSpeechAvailability.isReady
            SettingsMetricRow(
                label: AppLocalization.string("Readiness"),
                value: appleSpeechAvailability.title,
                valueColor: isReady ? .green : (appleSpeechAvailability.canAttemptRecognition ? .orange : .secondary),
                statusDot: isReady ? .green : nil
            )
            Label("Uses Apple's system-managed speech model. Captured audio stays on this iPhone.", systemImage: "iphone")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let localeIdentifier = appleSpeechAvailability.localeIdentifier {
                Text("Language: \(Locale.current.localizedString(forIdentifier: localeIdentifier) ?? localeIdentifier)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            switch appleSpeechAvailability {
            case .ready:
                EmptyView()
            case .permissionRequired:
                Text("Enable Speech Recognition in Settings > Conduit > Speech Recognition, then retry selecting \"On this iPhone\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .permissionDenied:
                Text("Speech Recognition permission was denied. Please enable it in Settings > Conduit > Speech Recognition.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .unsupported:
                Text("On-device speech recognition is not available for your current language locale.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func providerDetail(_ provider: VoiceProviderConfiguration) -> some View {
        let descriptor = provider.descriptor
        if let readiness = provider.readiness {
            let isReady = readiness.status.caseInsensitiveCompare("ready") == .orderedSame
            SettingsMetricRow(
                label: AppLocalization.string("Readiness"),
                value: readiness.statusLabel,
                valueColor: isReady ? .green : .secondary,
                statusDot: isReady ? .green : nil
            )
        }
        if descriptor.id == "local", descriptor.kind == .stt {
            Label("Runs on the Hermes host using its local Whisper installation—not on this iPhone.", systemImage: "server.rack")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if descriptor.supportsStreaming {
            Label("Streams speech as it is generated", systemImage: "waveform.path.ecg")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if !descriptor.models.isEmpty {
            Text(AppLocalization.string("Suggested models: ") + descriptor.models.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if !descriptor.voices.isEmpty {
            Text(AppLocalization.string("Suggested voices: ") + descriptor.voices.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        ForEach(provider.fields) { field in
            VoiceProviderFieldEditor(
                field: field,
                value: Binding(
                    get: { values[field.key] ?? service.snapshot.values[field.key] ?? field.defaultValue },
                    set: { values[field.key] = $0 }
                ),
                isSaving: savingField == field.key,
                save: { value in await save(value: value, field: field) }
            )
        }
    }

    private var credentialsSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Credentials on Hermes"), symbol: "key.fill", tint: .conduitAura) {
            Text("Keys stay on your Hermes host. Conduit only receives whether each key is set; it never reads a key back.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if service.snapshot.credentials.isEmpty {
                Text("No StepFun or Xiaomi credential metadata was reported by this gateway.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(service.snapshot.credentials) { credential in
                credentialEditor(credential)
            }
        }
    }

    @ViewBuilder
    private func credentialEditor(_ credential: VoiceCredentialStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(credential.key).font(.subheadline.weight(.semibold))
                    Text(credential.isSet ? AppLocalization.string("Configured on Hermes") : AppLocalization.string("Not configured"))
                        .font(.caption)
                        .foregroundStyle(credential.isSet ? .green : .secondary)
                }
                Spacer()
                Image(systemName: credential.isSet ? "checkmark.shield.fill" : "key")
                    .foregroundStyle(credential.isSet ? .green : .secondary)
                    .accessibilityHidden(true)
            }
            SecureField("Replace credential", text: Binding(
                get: { credentialDrafts[credential.key, default: ""] },
                set: { credentialDrafts[credential.key] = $0 }
            ))
            .textContentType(.password)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            HStack {
                Text("Enter a replacement only if needed.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save") {
                    let candidate = credentialDrafts[credential.key, default: ""]
                    Task {
                        savingField = credential.key
                        let saved = await service.saveCredential(candidate, key: credential.key)
                        if saved { credentialDrafts[credential.key] = "" }
                        savingField = nil
                    }
                }
                .disabled(credentialDrafts[credential.key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || savingField == credential.key)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var spokenControlsSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Spoken Controls"), symbol: "text.bubble", tint: .conduitAura) {
            Text("Phrases you can say during a Voice conversation. A phrase matches only when it is the entire spoken utterance — the same words inside a longer sentence do nothing.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            SpokenPhraseListEditor(
                title: AppLocalization.string("Stop Phrases"),
                purposeText: AppLocalization.string("Cancel the current response and keep Voice open."),
                initialPhrases: stopPhrasesShown,
                onChange: { phrases in
                    _ = setStopPhrases(phrases)
                    // Kept current, so the host's list matches it after
                    // the save and doesn't reseed the editor.
                    stopPhrasesShown = phrases
                    stopPhrasesCustomized = Self.isCustomStopList(phrases)
                }
            )
            .id(phraseEditorsGeneration)
            SpokenPhraseListEditor(
                title: AppLocalization.string("End Conversation Phrases"),
                purposeText: AppLocalization.string("Close the Voice conversation completely."),
                initialPhrases: endPhrasesShown,
                onChange: { phrases in
                    _ = setEndConversationPhrases(phrases)
                    endPhrasesShown = phrases
                    endPhrasesCustomized = Self.isCustomEndList(phrases)
                }
            )
            .id(phraseEditorsGeneration)
            Text("The built-in phrases are in the app language. Once you edit a list, it stays as you left it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if stopPhrasesCustomized || endPhrasesCustomized {
                Button {
                    let stop = VoiceSpokenCommandDefaults.stopPhrases
                    let end = VoiceSpokenCommandDefaults.endConversationPhrases
                    // Disconnected, nothing is saved: keep showing the
                    // user's lists rather than claim a reset.
                    guard setStopPhrases(stop), setEndConversationPhrases(end) else { return }
                    stopPhrasesShown = stop
                    endPhrasesShown = end
                    phraseEditorsGeneration += 1
                    stopPhrasesCustomized = false
                    endPhrasesCustomized = false
                } label: {
                    Label(AppLocalization.string("Use the built-in phrases"), systemImage: "arrow.counterclockwise")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("voice.spokenPhrasesReset")
            }
        }
    }

    /// A list is the user's own when saving it wouldn't go back to
    /// following the app language (an emptied list counts).
    private static func isCustomStopList(_ phrases: [String]) -> Bool {
        VoiceSpokenCommands.storedPhrases(phrases, builtIns: VoiceSpokenCommandDefaults.stopPhrases) != nil
    }

    private static func isCustomEndList(_ phrases: [String]) -> Bool {
        VoiceSpokenCommands.storedPhrases(phrases, builtIns: VoiceSpokenCommandDefaults.endConversationPhrases) != nil
    }

    @ViewBuilder
    private var wakeSection: some View {
        if let wake {
            // Keyed by profile: the section's state is seeded from the
            // model once, so another profile must get a fresh section.
            WakePhraseSettingsSection(model: wake)
                .id(service.profile)
        }
    }

    private var profileDisplayName: String {
        service.profile == "default" ? AppLocalization.string("Default profile") : service.profile.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func selectedProvider(_ kind: VoiceProviderDescriptor.Kind) -> String {
        kind == .stt ? service.snapshot.selectedSTTProvider : service.snapshot.selectedTTSProvider
    }

    private func selectedProviderChoice(_ kind: VoiceProviderDescriptor.Kind) -> String {
        kind == .stt && transcriptionMode == .appleOnDevice ? Self.appleProviderID : selectedProvider(kind)
    }

    private func providerChoices(
        kind: VoiceProviderDescriptor.Kind,
        providers: [VoiceProviderConfiguration]
    ) -> [(id: String, title: String)] {
        let hermes = providers.map { (id: $0.descriptor.id, title: $0.descriptor.displayName) }
        guard kind == .stt else { return hermes }
        return [(id: Self.appleProviderID, title: AppLocalization.string("On this iPhone"))] + hermes
    }

    private var supportsSelectedTranscription: Bool {
        transcriptionMode == .appleOnDevice
            ? appleSpeechAvailability.canAttemptRecognition
            : service.snapshot.capability.supportsTranscription
    }

    private func selectProvider(_ provider: String, kind: VoiceProviderDescriptor.Kind, force: Bool = false) {
        // `force` re-runs a selection already shown, to ask iOS again.
        guard force || provider != selectedProviderChoice(kind) else { return }
        Task { await applyProvider(provider, kind: kind) }
    }

    private func applyProvider(_ provider: String, kind: VoiceProviderDescriptor.Kind) async {
        savingField = "\(kind.rawValue).provider"
        defer { savingField = nil }
        if kind == .stt, provider == Self.appleProviderID {
            let selected = await setTranscriptionMode(.appleOnDevice)
            appleSpeechAvailability = AppleOnDeviceSpeechTranscriber.currentAvailability()
            microphonePermission = AVAudioApplication.shared.recordPermission
            if selected {
                transcriptionMode = .appleOnDevice
                transcriptionModeChosen = true
                testStatus = nil
            } else if case .permissionRequired = appleSpeechAvailability {
                testStatus = AppLocalization.string("Enable Speech Recognition in Settings > Conduit > Speech Recognition, then retry selecting \"On this iPhone\".")
            } else if case .permissionDenied = appleSpeechAvailability {
                testStatus = AppLocalization.string("Speech Recognition permission was denied. Please enable it in Settings > Conduit > Speech Recognition.")
            } else if case .unsupported = appleSpeechAvailability {
                testStatus = AppLocalization.string("On-device speech recognition is not available for your current language locale.")
            }
        } else {
            let providerSaved: Bool
            if provider == selectedProvider(kind) {
                providerSaved = true
            } else {
                providerSaved = await service.saveProvider(provider, kind: kind)
            }
            if providerSaved, kind == .stt {
                if (await setTranscriptionMode(.hermes)) {
                    transcriptionMode = .hermes
                    transcriptionModeChosen = true
                }
            }
        }
    }

    private func providerName(_ id: String, kind: VoiceProviderDescriptor.Kind) -> String {
        let providers = kind == .stt ? service.snapshot.sttProviders : service.snapshot.ttsProviders
        if let descriptor = providers.first(where: { $0.descriptor.id == id })?.descriptor { return descriptor.displayName }
        if let descriptor = VoiceConfigurationParser.catalogDescriptor(id: id, kind: kind) { return descriptor.displayName }
        return id.isEmpty ? AppLocalization.string("Not chosen") : id.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func load() async {
        appleSpeechAvailability = AppleOnDeviceSpeechTranscriber.currentAvailability()
        microphonePermission = AVAudioApplication.shared.recordPermission
        await service.reload()
        values = service.snapshot.values
    }

    private func save(value: String, field: VoiceTypedField) async {
        savingField = field.key
        _ = await service.save(value: value, for: field.key)
        // Re-sync the draft with the confirmed server state either way: a
        // canonicalized value ("1,5" → "1.5") or a removed override
        // (blank → the field default) is what the editor should show, and
        // a failed save restores the server value so the field never
        // claims an unpersisted edit.
        values[field.key] = service.snapshot.values[field.key] ?? field.defaultValue
        savingField = nil
    }

    private func runTest(kind: VoiceProviderDescriptor.Kind) {
        let action = kind == .stt ? actions.runASRTest : actions.runTTSTest
        guard let action else { return }
        Task {
            isRunningTest = true
            isRecordingASRTest = kind == .stt
            testStatus = kind == .stt ? AppLocalization.string("Listening for a short test…") : AppLocalization.string("Starting speech playback…")
            let result = await action()
            if kind == .stt, transcriptionMode == .appleOnDevice {
                appleSpeechAvailability = AppleOnDeviceSpeechTranscriber.currentAvailability()
            }
            testStatus = result.message
            isRecordingASRTest = false
            isRunningTest = false
        }
    }

    private static let appleProviderID = "apple_on_device"
}

/// Compact phrase-list editor for one spoken-command category: view, add,
/// edit, and delete entries, including down to an empty list (which disables
/// that command category — defaults are not forced back). Every save
/// canonicalizes through `VoiceSpokenCommands` so duplicates and blanks never
/// reach persistence.
struct WakePhraseSettingsModel {
    var phrases: [String]
    var suggestedPhrase: String
    var startsFreshConversation: Bool
    /// Device-wide, shared by every profile's wake phrases.
    var listensOnCarPlay: Bool
    /// Device-wide: keep listening while another app plays audio.
    var listensOverOtherAudio: Bool
    /// Wake is waiting for another app's audio to stop.
    var isPausedForOtherAudio: Bool
    var failure: String?
    var save: (_ phrases: [String], _ startsFreshConversation: Bool) -> Void
    var setListensOnCarPlay: (Bool) -> Void
    var setListensOverOtherAudio: (Bool) -> Void
}

/// Foreground wake phrase for this profile (#174). Device-local: phrases
/// are stored per dashboard and profile on this iPhone only.
private struct WakePhraseSettingsSection: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let model: WakePhraseSettingsModel
    @State private var phrases: [String]
    @State private var startsFresh: Bool
    @State private var listensOnCarPlay: Bool
    @State private var listensOverOtherAudio: Bool
    /// Optimistic: stays on while the permission prompt is up.
    @State private var isEnabled: Bool
    @State private var isRequestingPermission = false
    @State private var permissionDenied = false

    init(model: WakePhraseSettingsModel) {
        self.model = model
        _phrases = State(initialValue: model.phrases)
        _startsFresh = State(initialValue: model.startsFreshConversation)
        _listensOnCarPlay = State(initialValue: model.listensOnCarPlay)
        _listensOverOtherAudio = State(initialValue: model.listensOverOtherAudio)
        _isEnabled = State(initialValue: !model.phrases.isEmpty)
    }

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Wake phrase"), symbol: "ear.and.waveform", tint: .conduitAura) {
            Toggle("Listen for a wake phrase", isOn: Binding(
                get: { isEnabled },
                set: { enabled in
                    isEnabled = enabled
                    if enabled { enable() } else { save([]) }
                }
            ))
            .disabled(isRequestingPermission)
            Text("Say the phrase while Conduit is open to start voice on this profile, in whichever voice mode it uses. Listening runs on this iPhone, stops during calls and in the background, and the microphone indicator stays on while it listens.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if permissionDenied {
                Label("Allow Microphone and Speech Recognition for Conduit in Settings to use a wake phrase.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !phrases.isEmpty {
                SpokenPhraseListEditor(
                    title: AppLocalization.string("Wake phrases"),
                    purposeText: AppLocalization.string("Use at least two words, such as \"\(model.suggestedPhrase)\". Add a second spelling if Conduit mishears a name."),
                    initialPhrases: phrases,
                    onChange: { save($0) }
                )
                .id(phrases)
                if phrases.contains(where: { !WakePhraseMatcher.isUsable($0) }) {
                    Label("Phrases with a single word are ignored.", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Toggle("Start a new conversation", isOn: Binding(
                    get: { startsFresh },
                    set: { value in
                        startsFresh = value
                        model.save(phrases, value)
                    }
                ))
                Toggle("Listen on CarPlay", isOn: Binding(
                    get: { listensOnCarPlay },
                    set: { value in
                        listensOnCarPlay = value
                        model.setListensOnCarPlay(value)
                    }
                ))
                .accessibilityHint(Text("On CarPlay, wake listens through the iPhone's microphone so music keeps playing normally in the car. Turn this off if the phrase is missed or music sounds wrong."))
                Text("On CarPlay, wake listens through the iPhone's microphone so music keeps playing normally in the car. Turn this off if the phrase is missed or music sounds wrong.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Toggle("Listen while other audio plays", isOn: Binding(
                    get: { listensOverOtherAudio },
                    set: { value in
                        listensOverOtherAudio = value
                        model.setListensOverOtherAudio(value)
                    }
                ))
                .accessibilityHint(Text("Off: wake pauses while another app plays music or a podcast, and listens again once it stops. On: wake keeps listening, but iOS may play that audio in mono or cut it out briefly."))
                Text("Off: wake pauses while another app plays music or a podcast, and listens again once it stops. On: wake keeps listening, but iOS may play that audio in mono or cut it out briefly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                if model.isPausedForOtherAudio {
                    Label("Paused while another app plays audio. Wake listens again when it stops.", systemImage: "pause.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let failure = model.failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Text("Siri remains the supported way to begin a voice conversation from the Lock Screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // Follow changes made elsewhere while this page stays open.
        .onChange(of: model.phrases) { _, newPhrases in
            guard !isRequestingPermission, newPhrases != phrases else { return }
            phrases = newPhrases
            isEnabled = !newPhrases.isEmpty
        }
        .onChange(of: model.startsFreshConversation) { _, value in
            startsFresh = value
        }
        .onChange(of: model.listensOnCarPlay) { _, value in
            listensOnCarPlay = value
        }
        .onChange(of: model.listensOverOtherAudio) { _, value in
            listensOverOtherAudio = value
        }
    }

    private func enable() {
        isRequestingPermission = true
        Task { @MainActor in
            let granted = await AppleSpeechWakeWordService.requestPermissions()
            isRequestingPermission = false
            permissionDenied = !granted
            guard granted else {
                isEnabled = false
                return
            }
            save([model.suggestedPhrase])
        }
    }

    private func save(_ updated: [String]) {
        let canonical = VoiceSpokenCommands.canonicalizedPhraseList(updated)
        phrases = canonical
        isEnabled = !canonical.isEmpty
        model.save(canonical, startsFresh)
    }
}

private struct SpokenPhraseListEditor: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let title: String
    let purposeText: String
    let initialPhrases: [String]
    let onChange: ([String]) -> Void

    @State private var phrases: [String]
    @State private var draft = ""
    @State private var editingIndex: Int?

    init(title: String, purposeText: String, initialPhrases: [String], onChange: @escaping ([String]) -> Void) {
        self.title = title
        self.purposeText = purposeText
        self.initialPhrases = initialPhrases
        self.onChange = onChange
        // Seed through the same canonicalization the write path uses: a
        // legacy or externally written blob can carry duplicate/non-canonical
        // entries, and the value-identity ForEach requires distinct values.
        _phrases = State(initialValue: VoiceSpokenCommands.canonicalizedPhraseList(initialPhrases))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(purposeText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if phrases.isEmpty {
                Label("No phrases. This spoken command is disabled.", systemImage: "minus.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Entries are pairwise distinct after canonicalization, so the
            // value itself is a stable identity across deletes and dedupes.
            ForEach(phrases, id: \.self) { phrase in
                phraseRow(phrase)
            }
            HStack(spacing: 8) {
                TextField(editingIndex == nil ? AppLocalization.string("Add a phrase") : AppLocalization.string("Edit phrase"), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitDraft)
                    .accessibilityLabel(Text(editingIndex == nil ? AppLocalization.string("Add \(title)") : AppLocalization.string("Edit \(title)")))
                Button(editingIndex == nil ? AppLocalization.string("Add") : AppLocalization.string("Save"), action: commitDraft)
                    .disabled(draftCanonicalized.isEmpty)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var draftCanonicalized: String {
        VoiceSpokenCommands.canonicalized(draft)
    }

    private func phraseRow(_ phrase: String) -> some View {
        HStack(spacing: 10) {
            Text(phrase)
                .font(.subheadline)
            Spacer()
            Button {
                draft = phrase
                editingIndex = phrases.firstIndex(of: phrase)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(AppLocalization.string("Edit phrase \(phrase)")))
            Button {
                deletePhrase(phrase)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Delete phrase \(phrase)"))
        }
        .padding(.vertical, 2)
    }

    private func commitDraft() {
        // A draft that canonicalizes to empty ("   ", "!!!") would be
        // dropped by the save-time canonicalization anyway — refuse it here
        // so committing never silently no-ops.
        guard !draftCanonicalized.isEmpty else { return }
        var updated = phrases
        if let editingIndex, phrases.indices.contains(editingIndex) {
            updated[editingIndex] = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            updated.append(draft.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        save(updated)
    }

    private func deletePhrase(_ phrase: String) {
        guard let index = phrases.firstIndex(of: phrase) else { return }
        // Deleting any row discards the current in-progress edit: save()
        // clears the draft and the edit target unconditionally.
        var updated = phrases
        updated.remove(at: index)
        save(updated)
    }

    private func save(_ updated: [String]) {
        let canonical = VoiceSpokenCommands.canonicalizedPhraseList(updated)
        phrases = canonical
        onChange(canonical)
        draft = ""
        editingIndex = nil
    }
}

private struct VoiceProviderFieldEditor: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let field: VoiceTypedField
    @Binding var value: String
    let isSaving: Bool
    let save: (String) async -> Void

    /// Mirrors the service-side save guard so out-of-range numbers are
    /// rejected locally before a config round trip.
    private var validationMessage: String? {
        VoiceConfigurationParser.validationMessage(for: value, key: field.key)
    }

    private func saveChoice(_ option: String) {
        Task { await save(option) }
    }

    private var saveHint: Text {
        if let validationMessage {
            return Text("Cannot save. \(validationMessage)")
        }
        return Text("Saves \(field.label) to this Hermes profile.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            switch field.kind {
            case .choice(let options):
                ConduitMenuPicker(
                    value: value,
                    choices: options.map { (id: $0, title: $0.replacingOccurrences(of: "_", with: " ").capitalized) },
                    onSelect: { value = $0 }
                ) {
                    Text(field.label).foregroundStyle(.secondary)
                }
                .onChange(of: value) { _, updated in saveChoice(updated) }
            case .decimal:
                TextField(field.label, text: $value)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitIfValid)
                    .accessibilityHint(Text(validationMessage ?? field.help))
            case .text:
                TextField(field.label, text: $value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitIfValid)
                    .accessibilityHint(Text(validationMessage ?? field.help))
            }
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(Text("Cannot save \(field.label): \(validationMessage)"))
            }
            HStack {
                Text(field.help).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if case .choice = field.kind {
                    EmptyView()
                } else {
                    Button(isSaving ? AppLocalization.string("Saving…") : AppLocalization.string("Save")) { Task { await save(value) } }
                        .font(.caption.weight(.semibold))
                        .disabled(isSaving || validationMessage != nil)
                        .accessibilityHint(saveHint)
                }
            }
        }
        .padding(.vertical, 3)
    }

    /// Keyboard submit must respect the same guard as the Save button.
    private func submitIfValid() {
        guard !isSaving, validationMessage == nil else { return }
        Task { await save(value) }
    }
}

/// "Keep listening when locked" for classic Voice on this profile.
struct VoiceLockedListeningSettingsModel {
    var enabled: Bool
    /// Returns false when the change couldn't be saved (disconnected).
    var setEnabled: (Bool) -> Bool
}

/// Talking over Classic voice replies on the loudspeaker (echo-cancelling
/// audio). The same per-profile setting as the live modes' speaker barge-in.
struct VoiceSpeakerTalkOverSettingsModel {
    var enabled: Bool
    var setEnabled: (Bool) -> Void
}

/// Live calls that ended but haven't reached the Hermes host yet.
struct VoiceCallSaveStatusModel {
    var pendingCount: Int
    /// The host answered that it can't store voice calls.
    var blocked: Bool
    var isSaving: Bool
    /// Saves wait while a live call runs: a save would stall it.
    var isWaitingOnCall: Bool = false
    var saveNow: () async -> Void
}

struct VoiceCallSaveStatusSection: View {
    let model: VoiceCallSaveStatusModel

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Unsaved voice calls"), symbol: "exclamationmark.icloud", tint: .orange) {
            Text(AppLocalization.string("Voice calls waiting to save: \(model.pendingCount)"))
                .font(.subheadline.weight(.semibold))
            Text(model.blocked
                 ? AppLocalization.string("Your Hermes server can't save voice calls yet. Install or update the Hermes notifier plugin on your Hermes server, then tap Save Now.")
                 : AppLocalization.string("These calls are kept on this device and Conduit retries them automatically. It keeps up to 20 calls, and a call that still hasn't saved after 7 days is dropped."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await model.saveNow() }
            } label: {
                Label(model.isSaving ? AppLocalization.string("Saving…") : AppLocalization.string("Save Now"), systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6).frame(minHeight: 44)
            }
            .disabled(model.isSaving || model.isWaitingOnCall)
            .conduitGlassControl(cornerRadius: 16, tint: .orange.opacity(0.14))
        }
    }
}
