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

    static let unavailable = VoiceCapabilitySnapshot(
        isGatewayConnected: false,
        supportsTranscription: false,
        supportsSpeech: false,
        unavailableReason: "This Hermes gateway does not expose voice endpoints."
    )
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
    var spokenStopPhrases: [String] = ["stop", "stop talking", "be quiet"]
    /// Nil decodes older preferences as the Hermes-hosted route.
    var transcriptionMode: VoiceTranscriptionMode? = nil

    var resolvedTranscriptionMode: VoiceTranscriptionMode {
        transcriptionMode ?? .hermes
    }

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
            ?? ["stop", "stop talking", "be quiet"]
        transcriptionMode = try container.decodeIfPresent(VoiceTranscriptionMode.self, forKey: .transcriptionMode)
    }
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
        case .ready: return "Ready"
        case .permissionRequired: return "Permission required"
        case .permissionDenied: return "Permission denied"
        case .unsupported: return "Unavailable"
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
    case interrupted
    case routeChanged
}

enum VoiceAudioError: LocalizedError, Equatable {
    case microphonePermissionDenied
    case noAudioCaptured
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: return "Microphone access is required for voice conversations."
        case .noAudioCaptured: return "No speech was captured."
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
