//
//  LiveVoiceEchoCancellingAudio.swift
//  Conduit
//
//  Speaker barge-in for Gemini Live and Grok Live (opt in, per profile).
//
//  iOS only cancels echo for audio played through the same voice-processing
//  I/O unit that records. The default live audio runs the microphone
//  (AVAudioCaptureService) and the speaker (AVSpeechPlaybackService) on two
//  engines, so on the loudspeaker the microphone hears the model, the
//  server takes it for the user, and the model interrupts itself. That is
//  why the controller closes the microphone while the model talks on an
//  open speaker.
//
//  `EchoCancellingLiveVoiceAudio` runs both directions on one
//  voice-processing AVAudioEngine, so the model's own voice is cancelled
//  out of the microphone and the controller can leave it open: the user
//  can talk over the model on the speaker and in the car too.
//  `LiveVoiceAudioSelector` picks between the two for each call.
//

import AVFAudio
import Foundation
import OSLog

private let echoCancellingAudioLogger = Logger(subsystem: "com.milim.relay", category: "LiveVoiceAudio")

/// Microphone and speaker of a live call on one voice-processing engine.
/// The session policy is the conversation one (`.playAndRecord` +
/// `.voiceChat`, through VoiceAudioSessionCoordinator), held for as long
/// as either direction is in use.
@MainActor
final class EchoCancellingLiveVoiceAudio: NSObject {
    private let coordinator: VoiceAudioSessionCoordinator
    private let session = AVAudioSession.sharedInstance()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var playerFormat: AVAudioFormat?
    private var lease: VoiceAudioLease?
    private var converter: AVAudioConverter?
    private let microphoneFormat = AVAudioFormat(
        standardFormatWithSampleRate: VoiceAudioSessionConfiguration.capture.outputSampleRate,
        channels: VoiceAudioSessionConfiguration.capture.outputChannelCount
    )!

    /// Microphone chunks are wanted (input started, not muted).
    private var inputWanted = false
    /// The speaker side is in use (something played since the last stop).
    /// Together with `inputWanted` it decides whether the engine and the
    /// session lease stay up.
    private var outputWanted = false
    /// Bumped whenever the tap goes away, so microphone frames from an old
    /// engine are dropped.
    private var tapGeneration: UInt64 = 0
    /// Bumped whenever the playback queue is dropped, so completions of
    /// dropped buffers don't count.
    private var playbackGeneration: UInt64 = 0
    private var pendingBuffers = 0
    /// An odd trailing byte, carried into the next chunk as
    /// AVSpeechPlaybackService does.
    private var remainder = Data()
    /// When everything scheduled should have played. Completions normally
    /// drain the queue; if rendering died without a notification, the
    /// watchdog clears it once this (plus a grace) has passed, so
    /// `isPlaying` can't stay stuck.
    private var drainDeadline: Date?
    private var drainWatchdog: Task<Void, Never>?
    static let drainWatchdogGrace: TimeInterval = 2

    var onChunk: (@MainActor (Data) -> Void)?
    var onInterrupted: (@MainActor () -> Void)?
    var isPlaying: Bool { pendingBuffers > 0 }

    /// The controller's two seams over this one engine.
    var input: GeminiLiveAudioInput { Input(audio: self) }
    var output: GeminiLiveAudioOutput { Output(audio: self) }

    /// Optional injection instead of a default `.shared` argument: default
    /// parameter values are evaluated in a nonisolated context, which
    /// cannot read the MainActor-isolated singleton.
    init(coordinator: VoiceAudioSessionCoordinator? = nil) {
        self.coordinator = coordinator ?? .shared
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: session
        )
        // Belt and braces next to the engine's configuration change: a
        // route change that stopped the engine restarts it too.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: session
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Input

    /// Asks only while undetermined; answers at once otherwise.
    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func startInput() throws {
        inputWanted = true
        do {
            try ensureRunning()
        } catch {
            inputWanted = false
            teardownIfUnused()
            throw error
        }
    }

    /// Stops sending microphone audio. Echo cancellation needs both
    /// directions on one unit, so the engine keeps running while the
    /// speaker side still needs it; its frames are just dropped.
    func stopInput() {
        inputWanted = false
        teardownIfUnused()
    }

    // MARK: Output

    func play(_ pcm: Data, sampleRate: Double) throws {
        outputWanted = true
        do {
            try ensureRunning()
        } catch {
            outputWanted = false
            teardownIfUnused()
            throw error
        }
        guard let engine, let player else { return }
        if playerFormat.map({ abs($0.sampleRate - sampleRate) >= 1 }) ?? true {
            // The model changed rates: reconnect the player at the new one.
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
                throw VoiceAudioError.unavailable(AppLocalization.string("The gateway reported an unsupported PCM format."))
            }
            interrupt()
            engine.connect(player, to: engine.mainMixerNode, format: format)
            playerFormat = format
        }
        guard let format = playerFormat else { return }
        remainder.append(pcm)
        let alignedBytes = remainder.count - (remainder.count % 2)
        let frames = AVAudioFrameCount(alignedBytes / 2)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = frames
        remainder.prefix(alignedBytes).withUnsafeBytes { raw in
            AVSpeechPlaybackService.convertPCM16(raw, into: channel, frames: Int(frames))
        }
        remainder.removeFirst(alignedBytes)
        pendingBuffers += 1
        extendDrainDeadline(by: Double(frames) / format.sampleRate)
        let generation = playbackGeneration
        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == generation else { return }
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
            }
        }
        if !player.isPlaying { player.play() }
    }

    /// Drops everything queued (the user started speaking) but keeps the
    /// engine running so the microphone keeps streaming.
    func interrupt() {
        playbackGeneration &+= 1
        pendingBuffers = 0
        remainder.removeAll(keepingCapacity: true)
        clearDrainWatchdog()
        player?.stop()
    }

    private func extendDrainDeadline(by seconds: TimeInterval) {
        let start = max(drainDeadline ?? Date(), Date())
        drainDeadline = start.addingTimeInterval(seconds)
        guard drainWatchdog == nil else { return }
        drainWatchdog = Task { @MainActor [weak self] in
            while let deadline = self?.drainDeadline {
                let wait = deadline.timeIntervalSinceNow + Self.drainWatchdogGrace
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(wait))
                    guard !Task.isCancelled else { return }
                    continue
                }
                guard let self else { return }
                if self.pendingBuffers > 0 {
                    echoCancellingAudioLogger.notice("Live speech never finished playing; clearing the queue")
                    self.playbackGeneration &+= 1
                    self.pendingBuffers = 0
                }
                self.drainDeadline = nil
                self.drainWatchdog = nil
                return
            }
        }
    }

    private func clearDrainWatchdog() {
        drainWatchdog?.cancel()
        drainWatchdog = nil
        drainDeadline = nil
    }

    /// The speaker side is done: drop the queue, and stop everything once
    /// the microphone is off too.
    func stopOutput() {
        interrupt()
        outputWanted = false
        teardownIfUnused()
    }

    // MARK: Engine

    private func ensureRunning() throws {
        if let engine, engine.isRunning { return }
        if lease == nil {
            lease = try coordinator.acquire(.conversationCapture)
        }
        // Every rendering lifetime starts on a new engine (see
        // VoiceAudioEngineRecovery); a stale-graph failure re-applies the
        // session policy and retries once.
        try VoiceAudioEngineRecovery.startFresh(
            rebuild: { tearDownEngine() },
            reassert: { try coordinator.reassert() },
            start: { try startEngine() }
        )
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Before the graph starts: this switches both the input and the
        // output node to the voice-processing I/O unit, which is what
        // cancels the speaker's echo.
        try input.setVoiceProcessingEnabled(true)
        let player = AVAudioPlayerNode()
        engine.attach(player)
        // Connected up front so the speaker side is part of the graph (and
        // of the echo reference) from the start.
        let format = playerFormat ?? AVAudioFormat(standardFormatWithSampleRate: GeminiLiveProtocol.outputSampleRate, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)

        let hardwareFormat = input.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            // Recoverable: the input can report an empty format until the
            // session settles after a route change.
            throw VoiceAudioInputFormatUnavailable()
        }
        // As in AVAudioCaptureService: a nil-format tap whose rate disagrees
        // with the hardware raises an exception, so tap at the hardware
        // format in that case.
        let tapFormat = VoiceAudioEngineRecovery.tapFormat(
            nodeOutput: input.outputFormat(forBus: 0),
            hardware: hardwareFormat
        )
        tapGeneration &+= 1
        let frameGeneration = tapGeneration
        input.installTap(onBus: 0, bufferSize: 1_024, format: tapFormat) { [weak self] buffer, _ in
            // The engine reuses tap buffers once this block returns: copy
            // before hopping to the main actor.
            guard let copy = Self.copy(buffer) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.tapGeneration == frameGeneration, self.inputWanted else { return }
                self.forward(copy)
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
        engine.prepare()
        do {
            try engine.start()
        } catch {
            echoCancellingAudioLogger.error("Echo-cancelling live audio failed to start: \(String(describing: error), privacy: .public)")
            NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: engine)
            input.removeTap(onBus: 0)
            engine.stop()
            throw error
        }
        self.engine = engine
        self.player = player
        playerFormat = format
    }

    private func forward(_ buffer: AVAudioPCMBuffer) {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: microphoneFormat)
        }
        guard let converter else { return }
        let ratio = microphoneFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio) + 32)
        guard let converted = AVAudioPCMBuffer(pcmFormat: microphoneFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            guard !supplied else {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, status != .error, converted.frameLength > 0,
              let channel = converted.floatChannelData?[0] else { return }
        onChunk?(VoicePCMEncoding.encode(channel, count: Int(converted.frameLength)).data)
    }

    private func teardownIfUnused() {
        if !inputWanted && !outputWanted { tearDown() }
    }

    /// Full stop: engine, queue, and the session lease.
    private func tearDown() {
        inputWanted = false
        outputWanted = false
        tearDownEngine()
        playerFormat = nil
        if let lease {
            self.lease = nil
            coordinator.release(lease)
        }
    }

    private func tearDownEngine() {
        tapGeneration &+= 1
        playbackGeneration &+= 1
        pendingBuffers = 0
        remainder.removeAll(keepingCapacity: true)
        clearDrainWatchdog()
        converter = nil
        guard let engine else { return }
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: engine)
        player?.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        player = nil
    }

    /// A route change (speaker to AirPods and back) stops the engine:
    /// rebuild the graph against the new hardware. Queued speech is
    /// dropped. If it can't come back, the call hears about it like an
    /// interruption.
    private func restartAfterConfigurationChange() {
        guard inputWanted || outputWanted, engine?.isRunning != true else { return }
        tearDownEngine()
        do {
            try coordinator.reassert()
            try ensureRunning()
        } catch {
            echoCancellingAudioLogger.error("Echo-cancelling live audio restart failed: \(String(describing: error), privacy: .public)")
            stopAfterInterruption()
        }
    }

    /// The system took the audio (a call, Siri) or reset it. Everything
    /// stops and the session lease goes back; the controller restarts the
    /// microphone once the system lets go, as it does for the default
    /// capture.
    private func stopAfterInterruption() {
        guard inputWanted || outputWanted else { return }
        let wasListening = inputWanted
        tearDown()
        if wasListening { onInterrupted?() }
    }

    @objc private func handleConfigurationChange(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.restartAfterConfigurationChange() }
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        Task { @MainActor [weak self] in self?.stopAfterInterruption() }
    }

    @objc private func handleMediaServicesReset(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.stopAfterInterruption() }
    }

    nonisolated private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard let from = source[index].mData, let to = destination[index].mData else { continue }
            to.copyMemory(from: from, byteCount: Int(source[index].mDataByteSize))
            destination[index].mDataByteSize = source[index].mDataByteSize
        }
        return copy
    }

    // MARK: Seams

    @MainActor
    private final class Input: GeminiLiveAudioInput {
        let audio: EchoCancellingLiveVoiceAudio
        init(audio: EchoCancellingLiveVoiceAudio) { self.audio = audio }
        var onChunk: (@MainActor (Data) -> Void)? {
            get { audio.onChunk }
            set { audio.onChunk = newValue }
        }
        var onInterrupted: (@MainActor () -> Void)? {
            get { audio.onInterrupted }
            set { audio.onInterrupted = newValue }
        }
        var cancelsEcho: Bool { true }
        func requestPermission() async -> Bool { await EchoCancellingLiveVoiceAudio.requestPermission() }
        func start() throws { try audio.startInput() }
        func stop() { audio.stopInput() }
    }

    @MainActor
    private final class Output: GeminiLiveAudioOutput {
        let audio: EchoCancellingLiveVoiceAudio
        init(audio: EchoCancellingLiveVoiceAudio) { self.audio = audio }
        var isPlaying: Bool { audio.isPlaying }
        func play(_ pcm: Data, sampleRate: Double) throws { try audio.play(pcm, sampleRate: sampleRate) }
        func interrupt() { audio.interrupt() }
        func stop() { audio.stopOutput() }
    }
}

// MARK: - Per-call choice

/// The live controller's audio seams, choosing for each call between the
/// default audio (separate microphone and speaker, half duplex on an open
/// speaker) and the echo-cancelling one (speaker barge-in). The choice is
/// made when the call first uses audio and kept until the speaker side
/// stops with the microphone off (the controller does that only when a
/// call ends or fails), so a setting changed mid-call, mutes included,
/// applies from the next call. Each kind is built on first use only.
@MainActor
final class LiveVoiceAudioSelector {
    typealias Pair = (input: GeminiLiveAudioInput, output: GeminiLiveAudioOutput)

    private let wantsEchoCancellation: @MainActor () -> Bool
    private let makeStandard: @MainActor () -> Pair
    private let makeEchoCancelling: @MainActor () -> Pair
    private var standard: Pair?
    private var echoCancelling: Pair?
    private var current: Pair?
    private var inputRunning = false

    var onChunk: (@MainActor (Data) -> Void)? {
        didSet { current?.input.onChunk = onChunk }
    }
    var onInterrupted: (@MainActor () -> Void)?

    init(
        wantsEchoCancellation: @escaping @MainActor () -> Bool,
        makeStandard: @escaping @MainActor () -> Pair,
        makeEchoCancelling: @escaping @MainActor () -> Pair
    ) {
        self.wantsEchoCancellation = wantsEchoCancellation
        self.makeStandard = makeStandard
        self.makeEchoCancelling = makeEchoCancelling
    }

    var input: GeminiLiveAudioInput { Input(selector: self) }
    var output: GeminiLiveAudioOutput { Output(selector: self) }

    /// Whether the running call cancels echo (false between calls).
    var cancelsEcho: Bool { current?.input.cancelsEcho ?? false }

    private func pair(echoCancelling wanted: Bool) -> Pair {
        if wanted {
            if let echoCancelling { return echoCancelling }
            let made = makeEchoCancelling()
            echoCancelling = made
            return made
        }
        if let standard { return standard }
        let made = makeStandard()
        standard = made
        return made
    }

    private func selected() -> Pair {
        if let current { return current }
        let chosen = pair(echoCancelling: wantsEchoCancellation())
        chosen.input.onChunk = onChunk
        chosen.input.onInterrupted = { [weak self] in self?.inputInterrupted() }
        current = chosen
        return chosen
    }

    /// The call's audio is over: the next use chooses again.
    private func release() {
        guard !inputRunning, let released = current else { return }
        released.input.onChunk = nil
        released.input.onInterrupted = nil
        current = nil
    }

    /// Asked before a call has any audio, so it builds nothing.
    fileprivate func requestPermission() async -> Bool {
        await EchoCancellingLiveVoiceAudio.requestPermission()
    }

    fileprivate func startInput() throws {
        let choosing = current == nil
        do {
            try selected().input.start()
            inputRunning = true
        } catch {
            // A call whose audio never started holds no choice.
            if choosing { release() }
            throw error
        }
    }

    /// A mute or the end of the call: the call keeps its audio until the
    /// speaker side stops too.
    fileprivate func stopInput() {
        current?.input.stop()
        inputRunning = false
    }

    /// An interruption stopped the microphone underneath the call.
    private func inputInterrupted() {
        inputRunning = false
        onInterrupted?()
    }

    fileprivate var isPlaying: Bool { current?.output.isPlaying ?? false }

    fileprivate func play(_ pcm: Data, sampleRate: Double) throws {
        let choosing = current == nil
        do {
            try selected().output.play(pcm, sampleRate: sampleRate)
        } catch {
            if choosing { release() }
            throw error
        }
    }

    fileprivate func interrupt() { current?.output.interrupt() }

    fileprivate func stopOutput() {
        current?.output.stop()
        release()
    }

    @MainActor
    private final class Input: GeminiLiveAudioInput {
        let selector: LiveVoiceAudioSelector
        init(selector: LiveVoiceAudioSelector) { self.selector = selector }
        var onChunk: (@MainActor (Data) -> Void)? {
            get { selector.onChunk }
            set { selector.onChunk = newValue }
        }
        var onInterrupted: (@MainActor () -> Void)? {
            get { selector.onInterrupted }
            set { selector.onInterrupted = newValue }
        }
        var cancelsEcho: Bool { selector.cancelsEcho }
        func requestPermission() async -> Bool { await selector.requestPermission() }
        func start() throws { try selector.startInput() }
        func stop() { selector.stopInput() }
    }

    @MainActor
    private final class Output: GeminiLiveAudioOutput {
        let selector: LiveVoiceAudioSelector
        init(selector: LiveVoiceAudioSelector) { self.selector = selector }
        var isPlaying: Bool { selector.isPlaying }
        func play(_ pcm: Data, sampleRate: Double) throws { try selector.play(pcm, sampleRate: sampleRate) }
        func interrupt() { selector.interrupt() }
        func stop() { selector.stopOutput() }
    }
}
