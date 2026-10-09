//
//  VoiceTypes.swift
//  Conduit
//
//  The audio layer is deliberately independent of SwiftUI so it can be
//  exercised with deterministic capture, playback, and gateway test doubles.
//

import Foundation

enum VoiceConversationState: Equatable {
    case idle
    case listening
    case transcribing
    case thinking
    case speaking
    case muted
    case failed(String)
}

struct VoiceCapabilitySnapshot: Equatable {
    var isGatewayConnected: Bool
    var supportsTranscription: Bool
    var supportsSpeech: Bool
    var unavailableReason: String?

    /// Computed so the reason re-resolves under the in-app App Language.
    static var unavailable: VoiceCapabilitySnapshot {
        VoiceCapabilitySnapshot(
            isGatewayConnected: false,
            supportsTranscription: false,
            supportsSpeech: false,
            unavailableReason: AppLocalization.string("Your Hermes server doesn't offer voice. Update Hermes to use Voice.")
        )
    }
}

struct VoiceProviderDescriptor: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case stt, tts }

    var id: String
    var displayName: String
    var kind: Kind
    var models: [String]
    var voices: [String]
    var supportsStreaming: Bool

    init(id: String, displayName: String, kind: Kind, models: [String] = [], voices: [String] = [], supportsStreaming: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.models = models
        self.voices = voices
        self.supportsStreaming = supportsStreaming
    }
}

struct VoiceProfilePreferences: Codable, Equatable {
    var outputMuted: Bool = false
    /// Whether a completed assistant response automatically opens the next
    /// listening turn. Does not control session lifetime, user pause,
    /// barge-in, or route policy.
    var continuousConversation: Bool = true
    var continueWakeConversation: Bool = false
    /// Whether an open classic Voice conversation keeps listening with the
    /// phone locked or Conduit in the background, like a live call. Nil is
    /// off.
    var keepListeningWhenLocked: Bool? = nil
    var spokenStopPhrases: [String] = VoiceSpokenCommands.defaultStopPhrases
    /// Spoken phrases that close the whole Voice session through the
    /// existing Close teardown path. An empty list disables the category.
    var spokenEndConversationPhrases: [String] = VoiceSpokenCommands.defaultEndConversationPhrases
    /// Nil decodes older preferences as the Hermes-hosted route.
    var transcriptionMode: VoiceTranscriptionMode? = nil
    /// Opt-in Gemini Live voice mode (off by default; older blobs decode off).
    var geminiLiveEnabled: Bool = false
    /// Where Gemini Live's quick lookups search. Nil is automatic.
    var geminiLiveSearch: GeminiLiveSearchMode? = nil
    /// Gemini Live's prebuilt voice ("Kore", "Puck"…). Nil is Gemini's
    /// default voice.
    var geminiLiveVoice: String? = nil
    /// Whether Gemini Live gets the Hermes host's memory. Nil is off.
    var geminiLiveMemory: Bool? = nil
    /// Whether Gemini Live speaks as the profile's SOUL.md persona. Nil is off.
    var geminiLivePersonality: Bool? = nil
    /// Opt-in GPT-Live voice mode on the host's ChatGPT subscription (off by
    /// default; older blobs decode off). Never on together with Gemini Live.
    var gptLiveEnabled: Bool = false
    /// GPT-Live's voice ("cove", "ember"…). Nil is the host's configured voice
    /// (voice.gpt_live in the profile's config, "cove" by default).
    var gptLiveVoice: String? = nil
    /// Whether GPT-Live gets the Hermes host's memory. Nil is off.
    var gptLiveMemory: Bool? = nil
    /// Whether GPT-Live speaks as the profile's SOUL.md persona. Nil is off.
    var gptLivePersonality: Bool? = nil
    /// Opt-in Grok Live voice mode through the host's SuperGrok sign-in (off
    /// by default; older blobs decode off). Never on with another live mode.
    var grokLiveEnabled: Bool = false
    /// Whether Grok Live gets the Hermes host's memory. Nil is off.
    var grokLiveMemory: Bool? = nil
    /// Whether Grok Live speaks as the profile's SOUL.md persona. Nil is off.
    var grokLivePersonality: Bool? = nil
    /// Model for the Hermes sessions voice background jobs create. Nil keeps
    /// the profile's current model (the pre-existing behavior).
    var voiceJobModel: String? = nil
    var voiceJobProvider: String? = nil
    /// Reasoning effort for voice jobs ("none", "low", …). Nil keeps the
    /// profile default.
    var voiceJobReasoningEffort: String? = nil
    /// Whether live voice calls (Gemini Live, GPT-Live, Grok Live) are saved to the Hermes
    /// host's session history. Nil is on.
    var saveVoiceCalls: Bool? = nil
    /// Whether Gemini Live and Grok Live keep the microphone open while
    /// the model speaks on the loudspeaker or in the car, with echo
    /// cancellation. Nil is off (experimental).
    var liveVoiceSpeakerBargeIn: Bool? = nil
    /// How every live mode sounds (#290). Nil tone keeps the model's own.
    var liveVoiceTone: LiveVoiceTone? = nil
    /// Whether live models say "mm-hmm" while the user talks. Nil is on.
    var liveVoiceBackchannels: Bool? = nil
    /// Greeting when a live call connects. Nil is off; empty is a short
    /// greeting in the model's own words.
    var liveVoiceGreeting: String? = nil
    /// How much live models say. Nil is Default.
    var liveVoiceAnswerLength: LiveVoiceAnswerLength? = nil
    /// Whether live calls start asking before sending a request to Hermes
    /// (#451). Nil is off.
    var liveVoiceAskBeforeSending: Bool? = nil

    var liveVoiceStyle: LiveVoiceStyle {
        LiveVoiceStyle(
            tone: liveVoiceTone,
            backchannels: liveVoiceBackchannels ?? true,
            greeting: liveVoiceGreeting,
            answerLength: liveVoiceAnswerLength ?? .standard,
            asksBeforeSending: liveVoiceAskBeforeSending ?? false
        )
    }

    var resolvedTranscriptionMode: VoiceTranscriptionMode {
        transcriptionMode ?? .hermes
    }

    /// Explicit zero-arg initializer: a custom `init(from:)` removes the
    /// synthesized memberwise/default initializer, and callers use
    /// `VoiceProfilePreferences()` then mutate fields.
    init() {}

    /// Missing keys decode to the field defaults so a stored blob that never
    /// wrote `continuousConversation` still yields ON (backward compatible).
    /// Synthesized Codable would throw `keyNotFound` for absent non-optional
    /// keys even when the property has a default value.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outputMuted = try container.decodeIfPresent(Bool.self, forKey: .outputMuted) ?? false
        continuousConversation = try container.decodeIfPresent(Bool.self, forKey: .continuousConversation) ?? true
        continueWakeConversation = try container.decodeIfPresent(Bool.self, forKey: .continueWakeConversation) ?? false
        keepListeningWhenLocked = try? container.decodeIfPresent(Bool.self, forKey: .keepListeningWhenLocked)
        spokenStopPhrases = try container.decodeIfPresent([String].self, forKey: .spokenStopPhrases)
            .map {
                VoiceSpokenCommands.migratedDefaultPhrases(
                    $0,
                    previous: VoiceSpokenCommands.previousDefaultStopPhrases,
                    current: VoiceSpokenCommands.defaultStopPhrases
                )
            } ?? VoiceSpokenCommands.defaultStopPhrases
        spokenEndConversationPhrases = try container.decodeIfPresent(
            [String].self, forKey: .spokenEndConversationPhrases
        ).map {
            VoiceSpokenCommands.migratedDefaultPhrases(
                $0,
                previous: VoiceSpokenCommands.previousDefaultEndConversationPhrases,
                current: VoiceSpokenCommands.defaultEndConversationPhrases
            )
        } ?? VoiceSpokenCommands.defaultEndConversationPhrases
        transcriptionMode = try container.decodeIfPresent(VoiceTranscriptionMode.self, forKey: .transcriptionMode)
        geminiLiveEnabled = try container.decodeIfPresent(Bool.self, forKey: .geminiLiveEnabled) ?? false
        // An unknown mode (a newer build's) falls back to automatic rather
        // than failing the whole blob.
        geminiLiveSearch = (try? container.decodeIfPresent(GeminiLiveSearchMode.self, forKey: .geminiLiveSearch)) ?? nil
        geminiLiveVoice = (try? container.decodeIfPresent(String.self, forKey: .geminiLiveVoice)) ?? nil
        geminiLiveMemory = (try? container.decodeIfPresent(Bool.self, forKey: .geminiLiveMemory)) ?? nil
        geminiLivePersonality = (try? container.decodeIfPresent(Bool.self, forKey: .geminiLivePersonality)) ?? nil
        gptLiveEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .gptLiveEnabled)) ?? false
        gptLiveVoice = (try? container.decodeIfPresent(String.self, forKey: .gptLiveVoice)) ?? nil
        gptLiveMemory = (try? container.decodeIfPresent(Bool.self, forKey: .gptLiveMemory)) ?? nil
        gptLivePersonality = (try? container.decodeIfPresent(Bool.self, forKey: .gptLivePersonality)) ?? nil
        grokLiveEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .grokLiveEnabled)) ?? false
        grokLiveMemory = (try? container.decodeIfPresent(Bool.self, forKey: .grokLiveMemory)) ?? nil
        grokLivePersonality = (try? container.decodeIfPresent(Bool.self, forKey: .grokLivePersonality)) ?? nil
        voiceJobModel = try container.decodeIfPresent(String.self, forKey: .voiceJobModel)
        voiceJobProvider = try container.decodeIfPresent(String.self, forKey: .voiceJobProvider)
        voiceJobReasoningEffort = try container.decodeIfPresent(String.self, forKey: .voiceJobReasoningEffort)
        saveVoiceCalls = try? container.decodeIfPresent(Bool.self, forKey: .saveVoiceCalls)
        liveVoiceSpeakerBargeIn = try? container.decodeIfPresent(Bool.self, forKey: .liveVoiceSpeakerBargeIn)
        // An unknown tone (a newer build's) keeps the model's own.
        liveVoiceTone = try? container.decodeIfPresent(LiveVoiceTone.self, forKey: .liveVoiceTone)
        liveVoiceBackchannels = try? container.decodeIfPresent(Bool.self, forKey: .liveVoiceBackchannels)
        liveVoiceGreeting = try? container.decodeIfPresent(String.self, forKey: .liveVoiceGreeting)
        // An unknown length (a newer build's) is Default.
        liveVoiceAnswerLength = try? container.decodeIfPresent(LiveVoiceAnswerLength.self, forKey: .liveVoiceAnswerLength)
        liveVoiceAskBeforeSending = try? container.decodeIfPresent(Bool.self, forKey: .liveVoiceAskBeforeSending)
    }

    /// What a voice job's `session.create` asks for: the chosen voice-job
    /// model, else the profile's current model; the chosen reasoning effort
    /// either way.
    func voiceJobSessionOptions(runtimeModel: String, runtimeProvider: String) -> (model: String?, provider: String?, reasoningEffort: String?) {
        let reasoning = voiceJobReasoningEffort.flatMap { $0.isEmpty ? nil : $0 }
        if let model = voiceJobModel, !model.isEmpty {
            return (model, voiceJobProvider.flatMap { $0.isEmpty ? nil : $0 }, reasoning)
        }
        return (
            runtimeModel.isEmpty ? nil : runtimeModel,
            runtimeProvider.isEmpty ? nil : runtimeProvider,
            reasoning
        )
    }
}

/// The user's choice for Gemini Live's quick lookups (weather, news, facts).
enum GeminiLiveSearchMode: String, Codable, Equatable, CaseIterable {
    /// The Hermes host's own web search when it has one, else Google Search.
    case automatic
    /// The Hermes host's web search backend (SearXNG, Firecrawl…).
    case hermes
    /// Gemini's built-in Google Search, metered by Google on its own quota.
    case google
    /// No web lookups; web questions become Hermes jobs.
    case off

    func resolved(hermesAvailable: Bool) -> GeminiLiveSearchSource {
        switch self {
        case .automatic: return hermesAvailable ? .hermes : .google
        case .hermes: return .hermes
        case .google: return .google
        case .off: return .none
        }
    }
}

/// "Keep phone awake during voice conversations": a device-wide choice
/// (not per profile) to stop auto-lock while a voice conversation is open.
enum VoiceScreenAwake {
    static let preferenceKey = "conduit.voice.keepScreenAwake"

    /// Auto-lock is held off only while the setting is on and a voice
    /// conversation (classic, or a live mode: Gemini Live or GPT-Live) is
    /// on screen.
    static func holdsScreenAwake(enabled: Bool, voiceSheetShown: Bool, liveSheetShown: Bool) -> Bool {
        enabled && (voiceSheetShown || liveSheetShown)
    }
}

/// How hard the live call orb works the GPU (#432). It is a heavy
/// Metal shader, so frames are spent only where they show: 60 fps while the
/// assistant speaks, 30 the rest of the call, 30 throughout in Low Power
/// Mode, and a still frame when the user turns the motion off, Reduce Motion
/// is on, or the phone runs hot.
enum LiveVoiceOrbPower {
    /// "Animate the call orb": a device-wide choice (not per profile).
    static let preferenceKey = "conduit.voice.animateCallOrb"

    static func animates(
        requested: Bool,
        enabled: Bool,
        reduceMotion: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> Bool {
        guard requested, enabled, !reduceMotion else { return false }
        switch thermalState {
        case .serious, .critical: return false
        case .nominal, .fair: return true
        // A state iOS adds later is most likely hotter still.
        @unknown default: return false
        }
    }

    static func framesPerSecond(speaking: Bool, lowPowerMode: Bool) -> Int {
        speaking && !lowPowerMode ? 60 : 30
    }
}

/// Read Aloud playback speed: a device-wide choice (not per profile) for the
/// speaker button under replies. Voice conversations always play at 1x.
enum ReadAloudSpeed: Double, CaseIterable, Identifiable {
    case normal = 1.0
    case fast = 1.25
    case faster = 1.5
    case fastest = 1.75
    case double = 2.0

    static let preferenceKey = "conduit.voice.readAloudSpeed"

    var id: Double { rawValue }
    var rate: Float { Float(rawValue) }

    /// "1x", "1.25x", …, the same in every locale like the speed labels of
    /// system media players.
    var label: String {
        String(format: "%gx", locale: Locale(identifier: "en_US_POSIX"), rawValue)
    }

    /// The stored choice; anything missing or unrecognised reads as 1x.
    static func current(defaults: UserDefaults = .standard) -> ReadAloudSpeed {
        ReadAloudSpeed(rawValue: defaults.double(forKey: preferenceKey)) ?? .normal
    }
}

/// A prebuilt Gemini Live voice: its API name and Google's one-word
/// description of how it sounds.
struct GeminiLiveVoice: Equatable, Identifiable {
    let name: String
    let style: String

    var id: String { name }

    /// Google's prebuilt voices for native-audio models, in Google's order.
    /// Computed so the descriptions follow the current app language.
    static var all: [GeminiLiveVoice] {
        [
            GeminiLiveVoice(name: "Zephyr", style: AppLocalization.string("Bright")),
            GeminiLiveVoice(name: "Puck", style: AppLocalization.string("Upbeat")),
            GeminiLiveVoice(name: "Charon", style: AppLocalization.string("Informative")),
            GeminiLiveVoice(name: "Kore", style: AppLocalization.string("Firm")),
            GeminiLiveVoice(name: "Fenrir", style: AppLocalization.string("Excitable")),
            GeminiLiveVoice(name: "Leda", style: AppLocalization.string("Youthful")),
            GeminiLiveVoice(name: "Orus", style: AppLocalization.string("Firm")),
            GeminiLiveVoice(name: "Aoede", style: AppLocalization.string("Breezy")),
            GeminiLiveVoice(name: "Callirrhoe", style: AppLocalization.string("Easy-going")),
            GeminiLiveVoice(name: "Autonoe", style: AppLocalization.string("Bright")),
            GeminiLiveVoice(name: "Enceladus", style: AppLocalization.string("Breathy")),
            GeminiLiveVoice(name: "Iapetus", style: AppLocalization.string("Clear")),
            GeminiLiveVoice(name: "Umbriel", style: AppLocalization.string("Easy-going")),
            GeminiLiveVoice(name: "Algieba", style: AppLocalization.string("Smooth")),
            GeminiLiveVoice(name: "Despina", style: AppLocalization.string("Smooth")),
            GeminiLiveVoice(name: "Erinome", style: AppLocalization.string("Clear")),
            GeminiLiveVoice(name: "Algenib", style: AppLocalization.string("Gravelly")),
            GeminiLiveVoice(name: "Rasalgethi", style: AppLocalization.string("Informative")),
            GeminiLiveVoice(name: "Laomedeia", style: AppLocalization.string("Upbeat")),
            GeminiLiveVoice(name: "Achernar", style: AppLocalization.string("Soft")),
            GeminiLiveVoice(name: "Alnilam", style: AppLocalization.string("Firm")),
            GeminiLiveVoice(name: "Schedar", style: AppLocalization.string("Even")),
            GeminiLiveVoice(name: "Gacrux", style: AppLocalization.string("Mature")),
            GeminiLiveVoice(name: "Pulcherrima", style: AppLocalization.string("Forward")),
            GeminiLiveVoice(name: "Achird", style: AppLocalization.string("Friendly")),
            GeminiLiveVoice(name: "Zubenelgenubi", style: AppLocalization.string("Casual")),
            GeminiLiveVoice(name: "Vindemiatrix", style: AppLocalization.string("Gentle")),
            GeminiLiveVoice(name: "Sadachbia", style: AppLocalization.string("Lively")),
            GeminiLiveVoice(name: "Sadaltager", style: AppLocalization.string("Knowledgeable")),
            GeminiLiveVoice(name: "Sulafat", style: AppLocalization.string("Warm")),
        ]
    }
}

/// A GPT-Live voice: the name the host sends to GPT-Live, and how it sounds.
/// The names are ChatGPT's voices; a voice the account doesn't have is
/// refused by GPT-Live when the call starts.
struct GPTLiveVoice: Equatable, Identifiable {
    let name: String
    let style: String

    var id: String { name }

    /// Computed so the descriptions follow the current app language.
    static var all: [GPTLiveVoice] {
        [
            GPTLiveVoice(name: "arbor", style: AppLocalization.string("Easy-going")),
            GPTLiveVoice(name: "breeze", style: AppLocalization.string("Animated")),
            GPTLiveVoice(name: "cove", style: AppLocalization.string("Composed")),
            GPTLiveVoice(name: "ember", style: AppLocalization.string("Confident")),
            GPTLiveVoice(name: "juniper", style: AppLocalization.string("Upbeat")),
            GPTLiveVoice(name: "maple", style: AppLocalization.string("Cheerful")),
            GPTLiveVoice(name: "sol", style: AppLocalization.string("Savvy")),
            GPTLiveVoice(name: "spruce", style: AppLocalization.string("Calm")),
            GPTLiveVoice(name: "vale", style: AppLocalization.string("Bright")),
        ]
    }

    /// The name as shown in the picker ("Cove · Composed").
    var label: String { "\(name.prefix(1).uppercased())\(name.dropFirst()) · \(style)" }
}

/// What a Gemini Live session actually searches with.
enum GeminiLiveSearchSource: Equatable {
    case hermes
    case google
    case none
}

enum VoiceTranscriptionMode: String, Codable, Equatable {
    case hermes
    case appleOnDevice
}

enum AppleSpeechRecognitionAvailability: Equatable {
    case ready(localeIdentifier: String)
    case permissionRequired(localeIdentifier: String)
    case permissionDenied
    case unsupported(localeIdentifier: String)

    var canAttemptRecognition: Bool {
        switch self {
        case .ready, .permissionRequired: return true
        case .permissionDenied, .unsupported: return false
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .ready: return AppLocalization.string("Ready")
        case .permissionRequired: return AppLocalization.string("Permission required")
        case .permissionDenied: return AppLocalization.string("Permission denied")
        case .unsupported: return AppLocalization.string("Unavailable")
        }
    }

    var localeIdentifier: String? {
        switch self {
        case .ready(let identifier), .permissionRequired(let identifier), .unsupported(let identifier): return identifier
        case .permissionDenied: return nil
        }
    }
}

struct PendingVoiceIntent: Equatable {
    var profile: String?
    var startsFreshConversation: Bool
    var source: Source
    /// Wall-clock deadline metadata (tests / identity). The actual timeout
    /// wait uses `externalLaunchElapsedDeadline` so a backward clock step
    /// cannot extend the Siri budget.
    var externalLaunchDeadline: Date? = nil
    /// Monotonic elapsed deadline armed at enqueue. Authoritative for the
    /// deadline waiter; nil for requests with no external budget.
    var externalLaunchElapsedDeadline: ContinuousClock.Instant? = nil

    /// The screenshot (and optional question) of an Ask Hermes About
    /// Screen launch; nil for every other source.
    var screenQuestion: ScreenQuestionRequest? = nil

    /// `newCall`: the sidebar's New voice call, never attached to a chat.
    /// `screenQuestion`: the Ask Hermes About Screen action.
    /// `hermesCall`: Talk on a "Hermes wants to talk" notification (#449),
    /// in the job's chat it opened.
    enum Source: String, Equatable { case composer, wakePhrase, siri, newCall, screenQuestion, hermesCall }
}

/// How the chat opened by Ask Hermes About Screen takes the question.
enum ScreenQuestionStart: String, Codable, Equatable, CaseIterable {
    case voice
    case keyboard
}

/// One image handed to Conduit by the Ask Hermes About Screen action. It
/// waits on a chat until the next question is sent there.
struct ScreenQuestionRequest: Equatable {
    var attachment: Attachment
    /// A question that came with the image; it is sent at once.
    var question: String?
    /// nil starts voice, falling back to the keyboard when voice can't start.
    var startWith: ScreenQuestionStart?
    /// When the action ran, before Conduit came to the foreground: the
    /// recent-chat rule measures from here.
    var enqueuedAt: Date
    /// The shortcut's Chat option asked for a new chat instead of the
    /// recent one.
    var startsNewChat = false
}

/// What became of words spoken to steer a running Hermes turn.
enum VoiceSteerOutcome: Equatable {
    /// Hermes took them into the running turn.
    case steered
    /// No turn was running: the words should go out as a new turn.
    case noRunningTurn
    /// The steer was refused or failed; the running turn carries on
    /// without it.
    case failed
}

/// AppState emits these from its authoritative Hermes socket event path. Voice
/// consumers never need to scrape visible message rows or streaming text.
enum VoiceAssistantEvent: Equatable {
    case started(sessionID: String)
    case delta(sessionID: String, text: String)
    case completed(sessionID: String, content: String?)
    case failed(sessionID: String, message: String)
    case interrupted(sessionID: String)
}

struct VoiceConversationTranscriptEntry: Identifiable, Equatable {
    enum Speaker: Equatable {
        case user
        case assistant
    }

    let id: UUID
    let speaker: Speaker
    var text: String

    init(id: UUID = UUID(), speaker: Speaker, text: String) {
        self.id = id
        self.speaker = speaker
        self.text = text
    }
}

struct VoiceCapturedAudio: Equatable {
    var wavData: Data
    var pcm16Data: Data
    var sampleRate: Double
    var duration: TimeInterval

    var dataURL: String {
        "data:audio/wav;base64," + wavData.base64EncodedString()
    }
}

enum VoiceCaptureEvent: Equatable {
    /// Raw converted microphone peak. `generation` identifies the
    /// input-tap/rendering lifetime that produced the frame, so the
    /// controller can drop events queued before a pause/stop/restart: a
    /// frame is valid only for the generation that produced it.
    case level(Float, date: Date, generation: UInt64)
    /// `generation` identifies the capture runtime the interruption belongs
    /// to, so a queued interruption observed for a torn-down generation can
    /// never fail a later capture (the controller rejects foreign
    /// generations before applying the interrupted-failure semantics).
    case interrupted(generation: UInt64)
    case routeChanged
}

enum VoiceAudioError: LocalizedError, Equatable {
    case microphonePermissionDenied
    case noAudioCaptured
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: return AppLocalization.string("Conduit needs the microphone for voice. Allow it in iPhone Settings > Conduit.")
        case .noAudioCaptured: return AppLocalization.string("No speech was captured.")
        case .unavailable(let detail): return detail
        }
    }
}

struct VoiceProviderTestResult: Equatable {
    var passed: Bool
    var message: String

    static func success(_ message: String) -> Self {
        Self(passed: true, message: message)
    }

    static func failure(_ message: String) -> Self {
        Self(passed: false, message: message)
    }
}

@MainActor
protocol AudioCaptureService: AnyObject {
    var events: AsyncStream<VoiceCaptureEvent> { get }
    /// Monotonic identity of the currently installed input-tap/rendering
    /// lifetime. Bumped whenever the tap is torn down or reinstalled; level
    /// events carry the generation that produced them so stale frames from
    /// a previous generation can be rejected.
    var captureGeneration: UInt64 { get }
    func requestPermission() async -> Bool
    func startListening(includePreRoll: Bool) throws
    func beginBargeInMonitoring() throws
    func pause()
    /// Silences capture for assistant playback without releasing the
    /// microphone, so listening can reopen while Conduit is in the
    /// background. Starting, resuming, pausing, or stopping capture ends it.
    func holdForPlayback()
    var isHeldForPlayback: Bool { get }
    func resume() throws
    func finishUtterance() throws -> VoiceCapturedAudio
    func stop()
    /// PCM16 recorded so far in the open utterance (pre-roll included), at
    /// `VoiceAudioSessionConfiguration.capture.outputSampleRate`. Live
    /// transcription reads it as it grows; empty when none is open.
    var recordedPCM16: Data { get }
}

extension AudioCaptureService {
    /// Captures that can't expose the open utterance just never stream it.
    var recordedPCM16: Data { Data() }
}

/// Words recognized while the user is still speaking: microphone PCM goes
/// in as it is recorded, partial text comes out, and `finish()` returns the
/// final transcript, or nil when the recording's upload must be used.
@MainActor
protocol VoiceLiveTranscription: AnyObject {
    func push(_ pcm16: Data)
    func finish() async -> String?
    func cancel()
}

/// A gateway that can transcribe while the user speaks. Nil when this
/// Hermes has no live speech-to-text for the profile.
@MainActor
protocol VoiceLiveTranscriptionGateway: AnyObject {
    func openLiveTranscription(
        sampleRate: Double,
        onPartial: @escaping @MainActor (String) -> Void,
        onUnavailable: @escaping @MainActor () -> Void
    ) async -> VoiceLiveTranscription?
}

@MainActor
protocol DeviceSpeechTranscriptionService: AnyObject {
    func requestPermission() async -> Bool
    func transcribe(_ audio: VoiceCapturedAudio) async throws -> String
    func cancel()
}

@MainActor
protocol SpeechPlaybackService: AnyObject {
    var isPlaying: Bool { get }
    /// Which audio-session ownership playback claims while it plays.
    /// Conversation playback joins the capture-owned session; standalone
    /// flows (Read Aloud, provider tests) own the session alone.
    var ownershipIntent: VoiceAudioIntent { get set }
    /// Speed applied to the next stream or clip; 1.0 is normal speed.
    var playbackRate: Float { get set }
    func start(sampleRate: Double) throws
    func enqueuePCM16(_ data: Data, sampleRate: Double) throws -> Int
    func playEncodedAudioData(_ data: Data) throws
    func finish() throws
    func drain() async
    func stop()
    /// Holds the current audio in place (Now Playing pause, #373). Returns
    /// false when nothing is playing that can be paused. Scheduled and
    /// newly enqueued audio waits until `resume()`.
    func pause() -> Bool
    func resume()
    /// Whether audio is currently held by `pause()`. A stream restart (route
    /// change) clears it even though nobody resumed.
    var isPaused: Bool { get }
}

extension SpeechPlaybackService {
    /// Services without a speed control play at normal speed.
    var playbackRate: Float {
        get { 1 }
        set {}
    }

    /// Services without pause support refuse it; the caller keeps playing.
    func pause() -> Bool { false }
    func resume() {}
    var isPaused: Bool { false }
}

@MainActor
protocol WakeWordService: AnyObject {
    var isArmed: Bool { get }
    func arm() throws
    func disarm()
}

@MainActor
protocol VoiceSpeechStream: AnyObject {
    func append(_ text: String) async throws
    func finish() async throws -> Bool
    func cancel()
}

@MainActor
protocol VoiceGatewayService: AnyObject {
    var profile: String { get }
    func transcribe(_ audio: VoiceCapturedAudio) async throws -> String
    func openSpeechStream(
        onStart: @escaping @MainActor (Double) throws -> Void,
        onPCM16: @escaping @MainActor (Data, Double) throws -> Void,
        onEncodedAudio: @escaping @MainActor (Data) throws -> Void
    ) async throws -> VoiceSpeechStream
}
