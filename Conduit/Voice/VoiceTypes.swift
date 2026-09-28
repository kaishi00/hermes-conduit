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
            unavailableReason: AppLocalization.string("This Hermes gateway does not expose voice endpoints.")
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

/// Shared canonicalization and whole-utterance matching for the spoken Voice
/// command phrase lists (Stop, End Conversation). Matching is deliberately
/// conservative: a command fires only when the ENTIRE transcribed utterance
/// equals an ENTIRE configured phrase after normalization — no substring,
/// fuzzy, or semantic matching. Both the transcript and the configured
/// phrases are normalized the same way, so stored phrases need not be
/// pre-trimmed or lowercased.
enum VoiceSpokenCommands {
    /// Built-in spoken commands. Additive across languages BY DESIGN: both
    /// the English and the Simplified Chinese commands are recognized no
    /// matter which App Language the interface uses — commands match the
    /// transcribed utterance, never the UI locale.
    static let defaultStopPhrases = [
        "stop", "stop talking", "be quiet",
        "停止", "别说了", "不要说了",
    ]
    static let defaultEndConversationPhrases = [
        "goodbye", "bye", "end conversation", "that's all",
        "再见", "拜拜", "结束对话", "就这样吧",
    ]

    /// Defaults as originally shipped. The spoken-phrase preferences have
    /// not shipped in a stable release, but development builds may have
    /// persisted the original lists verbatim.
    static let previousDefaultStopPhrases = ["stop", "stop talking", "be quiet"]
    static let previousDefaultEndConversationPhrases = ["goodbye", "bye", "end conversation", "that's all"]

    /// Persistence migration for extended built-ins: a stored list that is
    /// exactly a previous default (the user never customized it) upgrades
    /// to the current defaults, so multilingual commands appear for
    /// existing persisted blobs. A customized list — including one where
    /// the user deliberately removed a built-in — is preserved untouched.
    static func migratedDefaultPhrases(_ stored: [String], previous: [String], current: [String]) -> [String] {
        let canonicalStored = Set(stored.map(canonicalized))
        let canonicalPrevious = Set(previous.map(canonicalized))
        return canonicalStored == canonicalPrevious ? current : stored
    }

    /// The single normalization used on both utterances and configured
    /// phrases: case folding, typographic apostrophe folding (ASR emits
    /// U+2019 for the U+0027 in defaults like "that's all"), and
    /// leading/trailing whitespace and punctuation stripping (internal
    /// punctuation such as the folded apostrophe survives).
    static func canonicalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// True only when the whole utterance matches a whole configured phrase.
    /// An utterance that canonicalizes to empty never matches.
    static func matches(_ utterance: String, phrases: [String]) -> Bool {
        let normalized = canonicalized(utterance)
        guard !normalized.isEmpty else { return false }
        return phrases.contains { canonicalized($0) == normalized }
    }

    /// Save-time canonicalization for a phrase list: trim each entry, drop
    /// entries that canonicalize to empty, and de-duplicate by the same
    /// canonical form used at runtime — keeping the first occurrence's
    /// trimmed display form so user capitalization survives.
    static func canonicalizedPhraseList(_ phrases: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for phrase in phrases {
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonical = canonicalized(trimmed)
            guard !canonical.isEmpty, seen.insert(canonical).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}

struct VoiceProfilePreferences: Codable, Equatable {
    var outputMuted: Bool = false
    /// Whether a completed assistant response automatically opens the next
    /// listening turn. Does not control session lifetime, user pause,
    /// barge-in, or route policy.
    var continuousConversation: Bool = true
    var continueWakeConversation: Bool = false
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
    /// Whether GPT-Live gets the Hermes host's memory. Nil is off.
    var gptLiveMemory: Bool? = nil
    /// Whether GPT-Live speaks as the profile's SOUL.md persona. Nil is off.
    var gptLivePersonality: Bool? = nil
    /// Model for the Hermes sessions voice background jobs create. Nil keeps
    /// the profile's current model (the pre-existing behavior).
    var voiceJobModel: String? = nil
    var voiceJobProvider: String? = nil
    /// Reasoning effort for voice jobs ("none", "low", …). Nil keeps the
    /// profile default.
    var voiceJobReasoningEffort: String? = nil

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
        gptLiveMemory = (try? container.decodeIfPresent(Bool.self, forKey: .gptLiveMemory)) ?? nil
        gptLivePersonality = (try? container.decodeIfPresent(Bool.self, forKey: .gptLivePersonality)) ?? nil
        voiceJobModel = try container.decodeIfPresent(String.self, forKey: .voiceJobModel)
        voiceJobProvider = try container.decodeIfPresent(String.self, forKey: .voiceJobProvider)
        voiceJobReasoningEffort = try container.decodeIfPresent(String.self, forKey: .voiceJobReasoningEffort)
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
    /// conversation (classic or Gemini Live) is on screen.
    static func holdsScreenAwake(enabled: Bool, voiceSheetShown: Bool, geminiLiveSheetShown: Bool) -> Bool {
        enabled && (voiceSheetShown || geminiLiveSheetShown)
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

    enum Source: String, Equatable { case composer, wakePhrase, siri }
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
        case .microphonePermissionDenied: return AppLocalization.string("Microphone access is required for voice conversations.")
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
    func resume() throws
    func finishUtterance() throws -> VoiceCapturedAudio
    func stop()
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
    func start(sampleRate: Double) throws
    func enqueuePCM16(_ data: Data, sampleRate: Double) throws -> Int
    func playEncodedAudioData(_ data: Data) throws
    func finish() throws
    func drain() async
    func stop()
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
