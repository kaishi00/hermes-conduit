//
//  VoiceSettingsView.swift
//  Conduit
//

import SwiftUI

struct VoiceSettingsRoute: View {
    @StateObject private var service: HermesVoiceConfigurationService
    /// The active VoiceConversationController, observed so the Record ASR
    /// input meter tracks live capture without polling or a second capture
    /// service.
    @ObservedObject var conversationController: VoiceConversationController
    let actions: VoiceSettingsActions
    let voiceEnabled: Bool
    let transcriptionMode: VoiceTranscriptionMode
    let appleSpeechAvailability: AppleSpeechRecognitionAvailability
    let continuousConversation: Bool
    let spokenStopPhrases: [String]
    let spokenEndConversationPhrases: [String]
    let setVoiceEnabled: (Bool) async -> Bool
    let setTranscriptionMode: (VoiceTranscriptionMode) async -> Bool
    let setContinuousConversation: (Bool) async -> Bool
    let setStopPhrases: ([String]) -> Void
    let setEndConversationPhrases: ([String]) -> Void
    let geminiLive: GeminiLiveSettingsModel?
    let gptLive: GPTLiveSettingsModel?
    let grokLive: GrokLiveSettingsModel?
    let liveStyle: LiveVoiceStyleSettingsModel?
    let voiceJobs: VoiceJobModelSettingsModel?
    let wake: WakePhraseSettingsModel?
    let lockedListening: VoiceLockedListeningSettingsModel?
    let callSaves: VoiceCallSaveStatusModel?

    init(
        bridge: DashboardTicketBridge,
        profile: String,
        conversationController: VoiceConversationController,
        actions: VoiceSettingsActions,
        voiceEnabled: Bool,
        transcriptionMode: VoiceTranscriptionMode,
        appleSpeechAvailability: AppleSpeechRecognitionAvailability,
        continuousConversation: Bool = true,
        spokenStopPhrases: [String] = VoiceSpokenCommands.defaultStopPhrases,
        spokenEndConversationPhrases: [String] = VoiceSpokenCommands.defaultEndConversationPhrases,
        setVoiceEnabled: @escaping (Bool) async -> Bool,
        setTranscriptionMode: @escaping (VoiceTranscriptionMode) async -> Bool,
        setContinuousConversation: @escaping (Bool) async -> Bool = { _ in true },
        setStopPhrases: @escaping ([String]) -> Void = { _ in },
        setEndConversationPhrases: @escaping ([String]) -> Void = { _ in },
        geminiLive: GeminiLiveSettingsModel? = nil,
        gptLive: GPTLiveSettingsModel? = nil,
        grokLive: GrokLiveSettingsModel? = nil,
        liveStyle: LiveVoiceStyleSettingsModel? = nil,
        voiceJobs: VoiceJobModelSettingsModel? = nil,
        wake: WakePhraseSettingsModel? = nil,
        lockedListening: VoiceLockedListeningSettingsModel? = nil,
        callSaves: VoiceCallSaveStatusModel? = nil
    ) {
        self.geminiLive = geminiLive
        self.gptLive = gptLive
        self.grokLive = grokLive
        self.liveStyle = liveStyle
        self.voiceJobs = voiceJobs
        self.wake = wake
        self.lockedListening = lockedListening
        self.callSaves = callSaves
        _service = StateObject(wrappedValue: HermesVoiceConfigurationService(bridge: bridge, profile: profile))
        _conversationController = ObservedObject(wrappedValue: conversationController)
        self.actions = actions
        self.voiceEnabled = voiceEnabled
        self.transcriptionMode = transcriptionMode
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
            wake: wake,
            lockedListening: lockedListening,
            callSaves: callSaves
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
    @AppStorage(VoiceScreenAwake.preferenceKey) private var keepScreenAwake = false
    @AppStorage(ReadAloudSpeed.preferenceKey) private var readAloudSpeedRaw = ReadAloudSpeed.normal.rawValue
    let spokenStopPhrases: [String]
    let spokenEndConversationPhrases: [String]
    let setStopPhrases: ([String]) -> Void
    let setEndConversationPhrases: ([String]) -> Void
    var geminiLive: GeminiLiveSettingsModel?
    var gptLive: GPTLiveSettingsModel?
    var grokLive: GrokLiveSettingsModel?
    var liveStyle: LiveVoiceStyleSettingsModel?
    var voiceJobs: VoiceJobModelSettingsModel?
    var wake: WakePhraseSettingsModel?
    var lockedListening: VoiceLockedListeningSettingsModel?
    var callSaves: VoiceCallSaveStatusModel?
    @State private var keepListeningWhenLocked: Bool

    init(
        service: HermesVoiceConfigurationService,
        conversationController: VoiceConversationController,
        actions: VoiceSettingsActions = VoiceSettingsActions(),
        voiceEnabled: Bool = false,
        transcriptionMode: VoiceTranscriptionMode = .hermes,
        appleSpeechAvailability: AppleSpeechRecognitionAvailability = .permissionRequired(localeIdentifier: Locale.current.identifier),
        continuousConversation: Bool = true,
        spokenStopPhrases: [String] = VoiceSpokenCommands.defaultStopPhrases,
        spokenEndConversationPhrases: [String] = VoiceSpokenCommands.defaultEndConversationPhrases,
        setVoiceEnabled: @escaping (Bool) async -> Bool = { _ in false },
        setTranscriptionMode: @escaping (VoiceTranscriptionMode) async -> Bool = { _ in false },
        setContinuousConversation: @escaping (Bool) async -> Bool = { _ in true },
        setStopPhrases: @escaping ([String]) -> Void = { _ in },
        setEndConversationPhrases: @escaping ([String]) -> Void = { _ in },
        geminiLive: GeminiLiveSettingsModel? = nil,
        gptLive: GPTLiveSettingsModel? = nil,
        grokLive: GrokLiveSettingsModel? = nil,
        liveStyle: LiveVoiceStyleSettingsModel? = nil,
        voiceJobs: VoiceJobModelSettingsModel? = nil,
        wake: WakePhraseSettingsModel? = nil,
        lockedListening: VoiceLockedListeningSettingsModel? = nil,
        callSaves: VoiceCallSaveStatusModel? = nil
    ) {
        self.geminiLive = geminiLive
        self.gptLive = gptLive
        self.grokLive = grokLive
        self.liveStyle = liveStyle
        self.voiceJobs = voiceJobs
        self.wake = wake
        self.lockedListening = lockedListening
        self.callSaves = callSaves
        _keepListeningWhenLocked = State(initialValue: lockedListening?.enabled ?? false)
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
        _voiceEnabled = State(initialValue: voiceEnabled)
        _transcriptionMode = State(initialValue: transcriptionMode)
        _appleSpeechAvailability = State(initialValue: appleSpeechAvailability)
        _continuousConversation = State(initialValue: continuousConversation)
    }

    var body: some View {
        ZStack {
            ConduitBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    capabilitySection
                    readAloudSection
                    if let callSaves, callSaves.pendingCount > 0 {
                        VoiceCallSaveStatusSection(model: callSaves)
                    }
                    if let geminiLive {
                        GeminiLiveSettingsSection(model: geminiLive)
                    }
                    if let gptLive {
                        GPTLiveSettingsSection(model: gptLive)
                    }
                    if let grokLive {
                        GrokLiveSettingsSection(model: grokLive)
                    }
                    if let liveStyle {
                        LiveVoiceStyleSettingsSection(model: liveStyle)
                    }
                    if let voiceJobs {
                        VoiceJobModelSettingsSection(settings: voiceJobs)
                    }
                    CarPlaySettingsSection()
                    if service.isLoading {
                        ProgressView("Loading profile voice settings…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    } else if service.snapshot.capability.isGatewayConnected {
                        providerSection(title: AppLocalization.string("Speech to text"), symbol: "waveform", kind: .stt, providers: service.snapshot.sttProviders)
                        providerSection(title: AppLocalization.string("Assistant speech"), symbol: "speaker.wave.3", kind: .tts, providers: service.snapshot.ttsProviders)
                        credentialsSection
                        testingSection
                        spokenControlsSection
                        wakeSection
                    }
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
        .accessibilityElement(children: .contain)
    }

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

    private var capabilitySection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Voice on \(profileDisplayName)"), symbol: "mic.badge.plus", tint: .conduitAccent) {
            Toggle("Enable voice on this device", isOn: Binding(
                get: { voiceEnabled },
                set: { requested in
                    let previous = voiceEnabled
                    voiceEnabled = requested
                    Task {
                        if !(await setVoiceEnabled(requested)) { voiceEnabled = previous }
                    }
                }
            ))
            Text("This preference is stored locally for this gateway and profile. Voice starts disabled until you opt in.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            .accessibilityHint("Automatically listens again after each response. Turn off to start each listening turn manually.")
            Text("When enabled, Conduit automatically listens again after each response. When disabled, the session stays open and you start the next listening turn manually. This does not change Pause Mic, Interrupt, Close, or wake-word settings.")
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
            HStack(spacing: 10) {
                Circle()
                    .fill(availabilityColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(availabilityTitle).font(.subheadline.weight(.semibold))
                Spacer()
            }
            Text(availabilityDetail)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let error = service.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Button {
                Task { await load() }
            } label: {
                Label(service.isLoading ? AppLocalization.string("Checking…") : AppLocalization.string("Check voice support"), systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .disabled(service.isLoading)
            .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.14))
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
            }
        }
    }

    private var appleOnDeviceDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            let isReady = appleSpeechAvailability.title == "Ready"
            SettingsMetricRow(
                label: "Readiness",
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
                label: "Readiness",
                value: readiness.status.capitalized,
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

    private var testingSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Test this profile"), symbol: "checkmark.seal", tint: .conduitAccent) {
            Text("These checks use the selected speech route and active profile. Provider credentials remain on Hermes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { runTest(kind: .stt) } label: {
                    Label("Record ASR", systemImage: "mic.badge.plus")
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                }
                .disabled(!voiceEnabled || actions.runASRTest == nil || isRunningTest || !supportsSelectedTranscription)
                .conduitGlassControl(cornerRadius: 16, tint: .conduitAura.opacity(0.14))
                .accessibilityHint("Records a short sample using this profile's speech-to-text provider")

                Button { runTest(kind: .tts) } label: {
                    Label("Play TTS", systemImage: "speaker.wave.2")
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                }
                .disabled(!voiceEnabled || actions.runTTSTest == nil || isRunningTest || !service.snapshot.capability.supportsSpeech)
                .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.14))
                .accessibilityHint("Plays a short sample using this profile's speech provider")
            }
            if let testStatus {
                Text(testStatus).font(.footnote).foregroundStyle(.secondary)
            } else if actions.runASRTest == nil || actions.runTTSTest == nil {
                Text("Live tests become available when the active voice session is connected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // The meter is visible only while the ASR test is actually
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

    private var spokenControlsSection: some View {
        ConduitSettingsSection(title: "Spoken Controls", symbol: "text.bubble", tint: .conduitAura) {
            Text("Phrases you can say during a Voice conversation. A phrase matches only when it is the entire spoken utterance — the same words inside a longer sentence do nothing.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            SpokenPhraseListEditor(
                title: AppLocalization.string("Stop Phrases"),
                purposeText: AppLocalization.string("Cancel the current response and keep Voice open."),
                initialPhrases: spokenStopPhrases,
                onChange: setStopPhrases
            )
            .id(spokenStopPhrases)
            SpokenPhraseListEditor(
                title: AppLocalization.string("End Conversation Phrases"),
                purposeText: AppLocalization.string("Close the Voice conversation completely."),
                initialPhrases: spokenEndConversationPhrases,
                onChange: setEndConversationPhrases
            )
            .id(spokenEndConversationPhrases)
        }
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

    private var availabilityTitle: String {
        if supportsSelectedTranscription || service.snapshot.capability.supportsSpeech { return AppLocalization.string("Voice settings are available") }
        return AppLocalization.string("Voice is unavailable")
    }

    private var availabilityDetail: String {
        if transcriptionMode == .appleOnDevice, appleSpeechAvailability.canAttemptRecognition {
            return "Speech-to-text runs on this iPhone. Hermes retains assistant speech configuration and chat processing."
        }
        return service.snapshot.capability.unavailableReason ?? AppLocalization.string("Hermes will retain all provider credentials and audio processing.")
    }

    private var availabilityColor: Color {
        (supportsSelectedTranscription || service.snapshot.capability.supportsSpeech) ? .green : .orange
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

    private func selectProvider(_ provider: String, kind: VoiceProviderDescriptor.Kind) {
        guard provider != selectedProviderChoice(kind) else { return }
        Task {
            savingField = "\(kind.rawValue).provider"
            if kind == .stt, provider == Self.appleProviderID {
                let selected = await setTranscriptionMode(.appleOnDevice)
                appleSpeechAvailability = AppleOnDeviceSpeechTranscriber.currentAvailability()
                if selected {
                    transcriptionMode = .appleOnDevice
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
                    if (await setTranscriptionMode(.hermes)) { transcriptionMode = .hermes }
                }
            }
            savingField = nil
        }
    }

    private func load() async {
        appleSpeechAvailability = AppleOnDeviceSpeechTranscriber.currentAvailability()
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
    var failure: String?
    var save: (_ phrases: [String], _ startsFreshConversation: Bool) -> Void
    var setListensOnCarPlay: (Bool) -> Void
}

/// Foreground wake phrase for this profile (#174). Device-local: phrases
/// are stored per dashboard and profile on this iPhone only.
private struct WakePhraseSettingsSection: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let model: WakePhraseSettingsModel
    @State private var phrases: [String]
    @State private var startsFresh: Bool
    @State private var listensOnCarPlay: Bool
    /// Optimistic: stays on while the permission prompt is up.
    @State private var isEnabled: Bool
    @State private var isRequestingPermission = false
    @State private var permissionDenied = false

    init(model: WakePhraseSettingsModel) {
        self.model = model
        _phrases = State(initialValue: model.phrases)
        _startsFresh = State(initialValue: model.startsFreshConversation)
        _listensOnCarPlay = State(initialValue: model.listensOnCarPlay)
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
                Button(editingIndex == nil ? "Add" : "Save", action: commitDraft)
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
                Picker(field.label, selection: $value) {
                    ForEach(options, id: \.self) { option in
                        Text(option.replacingOccurrences(of: "_", with: " ").capitalized).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: value) { _, updated in Task { await save(updated) } }
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
                    .frame(height: 44)
            }
            .disabled(model.isSaving || model.isWaitingOnCall)
            .conduitGlassControl(cornerRadius: 16, tint: .orange.opacity(0.14))
        }
    }
}
