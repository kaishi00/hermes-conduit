//
//  EchoCancellingVoiceConversationAudio.swift
//  Conduit
//
//  Speaker talk-over for Classic voice (opt in, per profile, the same
//  setting as Gemini Live and Grok Live).
//
//  Classic voice records with AVAudioCaptureService and speaks with
//  AVSpeechPlaybackService, on two engines. iOS only cancels echo for
//  audio played through the voice-processing unit that records, so on
//  the loudspeaker the microphone would hear Hermes and take it for the
//  user; the controller closes the microphone while Hermes talks there.
//
//  `VoiceConversationAudioSelector` gives the controller one capture and
//  one playback seam and picks, for each conversation, between those two
//  services and `EchoCancellingLiveVoiceAudio`, which runs both directions
//  on one voice-processing engine. With echo cancelled, the controller
//  treats every route like a headset: the microphone stays open while
//  Hermes speaks, so the user can talk over the reply.
//

import AVFAudio
import Foundation
import OSLog

private let conversationAudioLogger = Logger(subsystem: "com.milim.relay", category: "VoiceAudio")

/// The slice of the echo-cancelling engine Classic voice drives, so
/// ConduitTests can stand in for the audio hardware.
@MainActor
protocol EchoCancellingVoiceEngine: AnyObject {
    var onChunk: (@MainActor (Data) -> Void)? { get set }
    var onInterrupted: (@MainActor () -> Void)? { get set }
    var isPlaying: Bool { get }
    func startInput() throws
    func stopInput()
    func play(_ pcm: Data, sampleRate: Double) throws
    func play(_ buffer: AVAudioPCMBuffer) throws
    func discardRemainder()
    func interrupt()
    func stopOutput()
}

extension EchoCancellingLiveVoiceAudio: EchoCancellingVoiceEngine {}

/// Classic voice capture over the echo-cancelling engine: the same
/// listening, pre-roll and utterance behaviour as AVAudioCaptureService,
/// fed by the engine's 16 kHz PCM16 chunks.
@MainActor
final class EchoCancellingVoiceCapture: AudioCaptureService {
    private static let sampleRate = VoiceAudioSessionConfiguration.capture.outputSampleRate
    private static let bytesPerFrame = MemoryLayout<Int16>.size * Int(VoiceAudioSessionConfiguration.capture.outputChannelCount)
    private static let preRollDuration: TimeInterval = 5

    private let audio: EchoCancellingVoiceEngine
    private var continuation: AsyncStream<VoiceCaptureEvent>.Continuation?
    let events: AsyncStream<VoiceCaptureEvent>
    /// Bumped whenever the microphone stops or starts, so level events
    /// from before the boundary are dropped by the controller.
    private(set) var captureGeneration: UInt64 = 0
    private var inputRunning = false
    private var activelyRecording = false
    private var paused = false
    private(set) var isHeldForPlayback = false
    private var capturedPCM = Data()
    private var preRollPCM = Data()
    private let maximumPreRollBytes = Int(EchoCancellingVoiceCapture.sampleRate * EchoCancellingVoiceCapture.preRollDuration) * EchoCancellingVoiceCapture.bytesPerFrame

    init(audio: EchoCancellingVoiceEngine) {
        self.audio = audio
        var capturedContinuation: AsyncStream<VoiceCaptureEvent>.Continuation?
        events = AsyncStream { capturedContinuation = $0 }
        continuation = capturedContinuation
    }

    /// The selector forwards the engine's microphone chunks here while this
    /// capture is the conversation's.
    func receive(_ pcm: Data) {
        guard inputRunning, !paused, !isHeldForPlayback, !pcm.isEmpty else { return }
        preRollPCM.append(pcm)
        if preRollPCM.count > maximumPreRollBytes {
            preRollPCM.removeFirst(preRollPCM.count - maximumPreRollBytes)
        }
        if activelyRecording { capturedPCM.append(pcm) }
        continuation?.yield(.level(Self.peak(of: pcm), date: Date(), generation: captureGeneration))
    }

    /// The system took the audio (a call, Siri): the engine already
    /// stopped. Reported like the default capture's interruption.
    func receiveInterruption() {
        guard inputRunning else { return }
        resetInput()
        continuation?.yield(.interrupted(generation: captureGeneration))
    }

    func requestPermission() async -> Bool {
        await EchoCancellingLiveVoiceAudio.requestPermission()
    }

    func startListening(includePreRoll: Bool) throws {
        try startInputIfNeeded()
        capturedPCM = includePreRoll ? preRollPCM : Data()
        activelyRecording = true
        paused = false
        isHeldForPlayback = false
    }

    func beginBargeInMonitoring() throws {
        guard !paused else { return }
        try startInputIfNeeded()
        activelyRecording = false
        isHeldForPlayback = false
    }

    /// Echo is cancelled, so the controller never asks for this; dropping
    /// frames keeps the protocol's meaning if it ever does.
    func holdForPlayback() {
        guard !paused else { return }
        guard inputRunning else {
            pause()
            return
        }
        activelyRecording = false
        isHeldForPlayback = true
    }

    /// Stops sending microphone audio. The engine keeps running only while
    /// Hermes still has speech queued through it; otherwise it (and its
    /// audio session lease) stops until the microphone or speech resumes.
    func pause() {
        guard !paused else { return }
        resetInput()
        paused = true
    }

    func resume() throws {
        try startInputIfNeeded()
        paused = false
        isHeldForPlayback = false
    }

    func finishUtterance() throws -> VoiceCapturedAudio {
        activelyRecording = false
        paused = false
        let pcm = capturedPCM
        capturedPCM.removeAll(keepingCapacity: true)
        guard !pcm.isEmpty else { throw VoiceAudioError.noAudioCaptured }
        return VoiceCapturedAudio(
            wavData: AVAudioCaptureService.wavWrapping(pcm16: pcm, sampleRate: Int(Self.sampleRate)),
            pcm16Data: pcm,
            sampleRate: Self.sampleRate,
            duration: Double(pcm.count) / (Self.sampleRate * Double(Self.bytesPerFrame))
        )
    }

    func stop() {
        resetInput()
        paused = false
    }

    private func startInputIfNeeded() throws {
        guard !inputRunning else { return }
        try audio.startInput()
        inputRunning = true
        captureGeneration &+= 1
    }

    private func resetInput() {
        if inputRunning { audio.stopInput() }
        inputRunning = false
        activelyRecording = false
        isHeldForPlayback = false
        captureGeneration &+= 1
    }

    private static func peak(of pcm: Data) -> Float {
        pcm.withUnsafeBytes { raw in
            var peak: Int32 = 0
            for offset in stride(from: 0, to: raw.count - 1, by: 2) {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))
                peak = max(peak, abs(Int32(sample)))
            }
            return Float(peak) / 32_768
        }
    }
}

/// Classic voice playback over the echo-cancelling engine. Streamed PCM
/// goes straight to the engine; a whole-file fallback clip is decoded and
/// played through it too, so it is cancelled from the microphone as well.
@MainActor
final class EchoCancellingVoicePlayback: SpeechPlaybackService {
    private let audio: EchoCancellingVoiceEngine
    /// Bumped by `stop()`, so a drain waiting on dropped audio returns.
    private var stopGeneration: UInt64 = 0
    /// How often `drain()` checks the engine's queue. Internal so tests
    /// can shorten it.
    var drainPollInterval: Duration = .milliseconds(50)

    init(audio: EchoCancellingVoiceEngine) {
        self.audio = audio
    }

    var isPlaying: Bool { audio.isPlaying }
    /// The engine holds the conversation's own session lease.
    var ownershipIntent: VoiceAudioIntent = .conversationPlayback
    var isPaused: Bool { false }

    func start(sampleRate: Double) throws {}

    func enqueuePCM16(_ data: Data, sampleRate: Double) throws -> Int {
        try audio.play(data, sampleRate: sampleRate)
        return data.count - (data.count % 2)
    }

    /// The gateway sends a fallback clip only for a reply that streamed no
    /// PCM, and the clip is the whole reply: like the default playback, it
    /// replaces anything still queued.
    func playEncodedAudioData(_ data: Data) throws {
        audio.interrupt()
        try audio.play(try Self.decode(data))
    }

    func finish() throws {
        // An odd tail is invalid PCM16 and is dropped rather than shifted
        // into the next reply, as the default playback does.
        audio.discardRemainder()
    }

    func drain() async {
        let generation = stopGeneration
        while audio.isPlaying, generation == stopGeneration, !Task.isCancelled {
            try? await Task.sleep(for: drainPollInterval)
        }
        // The reply has played out: give the speaker side back, so a
        // paused microphone doesn't keep the engine (and the microphone
        // hardware) running between turns.
        guard generation == stopGeneration, !Task.isCancelled else { return }
        audio.stopOutput()
    }

    func stop() {
        stopGeneration &+= 1
        audio.stopOutput()
    }

    /// Conversation speech can't be held in place.
    func pause() -> Bool { false }
    func resume() {}

    /// AVAudioFile reads from a file only, and the file's extension is its
    /// format hint. Decoding runs on the main actor: it is the fallback-only
    /// path (one clip for a reply whose speech didn't stream), and the
    /// playback seam is synchronous.
    private static func decode(_ data: Data) throws -> AVAudioPCMBuffer {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-speech-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension(for: data))
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                throw VoiceAudioError.unavailable(AppLocalization.string("Could not play Hermes fallback speech."))
            }
            try file.read(into: buffer)
            return buffer
        } catch {
            conversationAudioLogger.error("Fallback speech could not be decoded: \(String(describing: error), privacy: .public)")
            throw VoiceAudioError.unavailable(AppLocalization.string("Could not play Hermes fallback speech."))
        }
    }

    /// Sniffs the clip's container from its first bytes.
    static func fileExtension(for data: Data) -> String {
        let head = [UInt8](data.prefix(12))
        func starts(_ ascii: String, at offset: Int = 0) -> Bool {
            let bytes = Array(ascii.utf8)
            return head.count >= offset + bytes.count && Array(head[offset..<offset + bytes.count]) == bytes
        }
        if starts("RIFF") { return "wav" }
        if starts("OggS") { return "ogg" }
        if starts("fLaC") { return "flac" }
        if starts("caff") { return "caf" }
        if starts("ftyp", at: 4) { return "m4a" }
        if starts("FORM") { return "aiff" }
        return "mp3"
    }
}

/// The Classic voice controller's audio seams, choosing for each
/// conversation between the default capture and playback (half duplex on
/// an open speaker) and the echo-cancelling engine (talk over Hermes on
/// any route). The choice is made when the microphone first starts and
/// kept until the microphone stops for good (`stop()`, the end of the
/// conversation), so a setting changed mid-conversation applies to the
/// next one. Speech outside a conversation (the provider test) uses the
/// default playback.
@MainActor
final class VoiceConversationAudioSelector {
    private let wantsEchoCancellation: @MainActor () -> Bool
    private let standardCapture: AudioCaptureService
    private let standardPlayback: SpeechPlaybackService
    private let makeEchoCancelling: @MainActor () -> EchoCancellingVoiceEngine
    private var echo: (audio: EchoCancellingVoiceEngine, capture: EchoCancellingVoiceCapture, playback: EchoCancellingVoicePlayback)?
    private var usesEchoCancellation: Bool?
    private var continuation: AsyncStream<VoiceCaptureEvent>.Continuation?
    let events: AsyncStream<VoiceCaptureEvent>
    private var forwarding: [Task<Void, Never>] = []

    init(
        wantsEchoCancellation: @escaping @MainActor () -> Bool,
        standardCapture: AudioCaptureService,
        standardPlayback: SpeechPlaybackService,
        makeEchoCancelling: @escaping @MainActor () -> EchoCancellingVoiceEngine
    ) {
        self.wantsEchoCancellation = wantsEchoCancellation
        self.standardCapture = standardCapture
        self.standardPlayback = standardPlayback
        self.makeEchoCancelling = makeEchoCancelling
        var capturedContinuation: AsyncStream<VoiceCaptureEvent>.Continuation?
        events = AsyncStream { capturedContinuation = $0 }
        continuation = capturedContinuation
        forward(standardCapture.events, isEchoCancelling: false)
    }

    deinit { forwarding.forEach { $0.cancel() } }

    var capture: AudioCaptureService { Capture(selector: self) }
    var playback: SpeechPlaybackService { Playback(selector: self) }

    /// Whether the running conversation cancels echo (false between
    /// conversations). The controller's route policy reads this.
    var cancelsEcho: Bool { usesEchoCancellation == true }

    /// Only the chosen capture's events reach the controller, so a late
    /// event from the other one can't touch the conversation.
    private func forward(_ stream: AsyncStream<VoiceCaptureEvent>, isEchoCancelling: Bool) {
        forwarding.append(Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                guard (self.usesEchoCancellation ?? false) == isEchoCancelling else { continue }
                self.continuation?.yield(event)
            }
        })
    }

    private func echoCancelling() -> (audio: EchoCancellingVoiceEngine, capture: EchoCancellingVoiceCapture, playback: EchoCancellingVoicePlayback) {
        if let echo { return echo }
        let audio = makeEchoCancelling()
        let made = (audio: audio, capture: EchoCancellingVoiceCapture(audio: audio), playback: EchoCancellingVoicePlayback(audio: audio))
        audio.onChunk = { [weak capture = made.capture] in capture?.receive($0) }
        audio.onInterrupted = { [weak capture = made.capture] in capture?.receiveInterruption() }
        forward(made.capture.events, isEchoCancelling: true)
        echo = made
        return made
    }

    /// The capture for this conversation, choosing one if none is chosen.
    fileprivate func chosenCapture() -> AudioCaptureService {
        if usesEchoCancellation == nil {
            usesEchoCancellation = wantsEchoCancellation()
            if usesEchoCancellation == true {
                conversationAudioLogger.notice("Classic voice uses echo-cancelling audio for this conversation")
            }
        }
        return usesEchoCancellation == true ? echoCancelling().capture : standardCapture
    }

    /// The capture currently in use, without choosing one.
    fileprivate var currentCapture: AudioCaptureService {
        usesEchoCancellation == true ? echoCancelling().capture : standardCapture
    }

    fileprivate var currentPlayback: SpeechPlaybackService {
        usesEchoCancellation == true ? echoCancelling().playback : standardPlayback
    }

    /// A capture start that failed before anything was chosen leaves no
    /// choice behind.
    fileprivate func start(_ body: (AudioCaptureService) throws -> Void) throws {
        let wasUnchosen = usesEchoCancellation == nil
        do {
            try body(chosenCapture())
        } catch {
            if wasUnchosen { release() }
            throw error
        }
    }

    /// The conversation's audio is over: stop the echo-cancelling speaker
    /// side too, and choose again next time.
    fileprivate func release() {
        if usesEchoCancellation == true { echo?.playback.stop() }
        usesEchoCancellation = nil
    }

    /// Stops the playback in use. Echo audio still queued is stopped too
    /// even once the choice was released, so the controller's teardown
    /// doesn't depend on which side it stops first.
    fileprivate func stopPlayback() {
        currentPlayback.stop()
        if usesEchoCancellation != true, let echo, echo.audio.isPlaying {
            echo.playback.stop()
        }
    }

    @MainActor
    private final class Capture: AudioCaptureService {
        let selector: VoiceConversationAudioSelector
        init(selector: VoiceConversationAudioSelector) { self.selector = selector }

        var events: AsyncStream<VoiceCaptureEvent> { selector.events }
        var captureGeneration: UInt64 { selector.currentCapture.captureGeneration }
        var isHeldForPlayback: Bool { selector.currentCapture.isHeldForPlayback }

        /// One app-wide microphone permission, whichever capture records:
        /// always asked through the default capture.
        func requestPermission() async -> Bool { await selector.standardCapture.requestPermission() }
        func startListening(includePreRoll: Bool) throws {
            try selector.start { try $0.startListening(includePreRoll: includePreRoll) }
        }
        func beginBargeInMonitoring() throws {
            try selector.start { try $0.beginBargeInMonitoring() }
        }
        func resume() throws {
            try selector.start { try $0.resume() }
        }
        func pause() { selector.currentCapture.pause() }
        func holdForPlayback() { selector.currentCapture.holdForPlayback() }
        func finishUtterance() throws -> VoiceCapturedAudio { try selector.currentCapture.finishUtterance() }
        func stop() {
            selector.currentCapture.stop()
            selector.release()
        }
    }

    @MainActor
    private final class Playback: SpeechPlaybackService {
        let selector: VoiceConversationAudioSelector
        init(selector: VoiceConversationAudioSelector) { self.selector = selector }

        var isPlaying: Bool { selector.currentPlayback.isPlaying }
        var ownershipIntent: VoiceAudioIntent {
            get { selector.currentPlayback.ownershipIntent }
            set { selector.currentPlayback.ownershipIntent = newValue }
        }
        var playbackRate: Float {
            get { selector.currentPlayback.playbackRate }
            set { selector.currentPlayback.playbackRate = newValue }
        }
        var isPaused: Bool { selector.currentPlayback.isPaused }

        func start(sampleRate: Double) throws { try selector.currentPlayback.start(sampleRate: sampleRate) }
        func enqueuePCM16(_ data: Data, sampleRate: Double) throws -> Int {
            try selector.currentPlayback.enqueuePCM16(data, sampleRate: sampleRate)
        }
        func playEncodedAudioData(_ data: Data) throws { try selector.currentPlayback.playEncodedAudioData(data) }
        func finish() throws { try selector.currentPlayback.finish() }
        func drain() async { await selector.currentPlayback.drain() }
        func stop() { selector.stopPlayback() }
        func pause() -> Bool { selector.currentPlayback.pause() }
        func resume() { selector.currentPlayback.resume() }
    }
}
