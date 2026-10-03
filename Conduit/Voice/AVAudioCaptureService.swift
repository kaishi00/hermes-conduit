//
//  AVAudioCaptureService.swift
//  Conduit
//

import AVFAudio
import Foundation
import OSLog
import os

private let voiceAudioLogger = Logger(subsystem: "com.milim.relay", category: "VoiceAudio")

@MainActor
final class AVAudioCaptureService: NSObject, AudioCaptureService {
    private static let outputSampleRate = VoiceAudioSessionConfiguration.capture.outputSampleRate
    private static let outputChannelCount = VoiceAudioSessionConfiguration.capture.outputChannelCount
    private static let outputBytesPerSample = MemoryLayout<Int16>.size
    private static let outputBytesPerFrame = outputBytesPerSample * Int(outputChannelCount)
    private static let preRollDuration: TimeInterval = 5

    /// Rebuilt at the start of every rendering lifetime (see
    /// `VoiceAudioEngineRecovery`): an engine kept across session
    /// reconfigurations starts against stale input formats (-10868).
    private var engine: VoiceCaptureEngine
    private let makeEngine: () -> VoiceCaptureEngine
    private let session = AVAudioSession.sharedInstance()
    private let coordinator: VoiceAudioSessionCoordinator
    /// AVAudioEngine and AVAudioConverter use deinterleaved Float32 as their
    /// canonical PCM representation. Quantize to PCM16 only after resampling.
    private let outputFormat = AVAudioFormat(
        standardFormatWithSampleRate: AVAudioCaptureService.outputSampleRate,
        channels: AVAudioCaptureService.outputChannelCount
    )!
    private var converter: AVAudioConverter?
    // Capture state below is internal rather than private so ConduitTests
    // can drive the frame-admission seam directly with synthetic PCM
    // buffers instead of audio hardware. Production code must mutate these
    // only through the lifecycle methods; direct writes outside ConduitTests
    // can create flag combinations the lifecycle never produces and are not
    // supported.
    var capturedPCM = Data()
    /// Streaming consumers (Gemini Live) receive every converted 16 kHz
    /// PCM16 chunk as it is produced. Nil for the classic Voice path, which
    /// only reads whole utterances.
    var onPCM16Chunk: (@MainActor (Data) -> Void)?
    var preRollPCM = Data()
    private let maximumPreRollBytes = Int(AVAudioCaptureService.outputSampleRate * AVAudioCaptureService.preRollDuration) * AVAudioCaptureService.outputBytesPerFrame
    var activelyRecording = false
    var paused = false
    /// Set by `holdForPlayback()`: the engine, tap, and session lease stay
    /// up but no frame is admitted. Cleared when capture starts, resumes,
    /// pauses, or stops.
    var heldForPlayback = false
    var isHeldForPlayback: Bool { heldForPlayback }
    /// The hold keeps the tap, so its frames share a capture generation
    /// with frames from after it. Lifting a hold advances this epoch, which
    /// the tap stamps on every frame on the audio thread, so playback audio
    /// still queued for the MainActor can't land in the next window.
    private var holdEpoch: UInt64 = 0
    private let observedHoldEpoch = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    nonisolated private var holdEpochForTap: UInt64 {
        observedHoldEpoch.withLock { $0 }
    }

    private func liftPlaybackHold() {
        guard heldForPlayback else { return }
        heldForPlayback = false
        holdEpoch &+= 1
        let current = holdEpoch
        observedHoldEpoch.withLock { $0 = current }
    }
    /// Monotonic identity of the installed input-tap/rendering lifetime.
    /// Bumped at every teardown (pause/stop) and every tap reinstall, so
    /// frames queued from a previous generation can be recognized and
    /// dropped after the boundary.
    private(set) var captureGeneration: UInt64 = 0
    /// Thread-safe mirror of `captureGeneration` for observers that run
    /// outside the MainActor. Session interruption notifications arrive on
    /// an arbitrary thread and must record which capture generation they
    /// belong to SYNCHRONOUSLY, before the MainActor hop — reading the value
    /// later would observe whatever generation is installed by then, which
    /// is exactly the stale-teardown race this exists to prevent.
    private let observedCaptureGeneration = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    nonisolated private var generationForInterruptionObservers: UInt64 {
        observedCaptureGeneration.withLock { $0 }
    }

    private func publishGenerationForInterruptionObservers() {
        let current = captureGeneration
        observedCaptureGeneration.withLock { $0 = current }
    }
    var shouldKeepEngineRunning = false
    private var lastCaptureFailure: String?
    private var continuation: AsyncStream<VoiceCaptureEvent>.Continuation?
    /// Capture holds one lease for the whole capture window (listening,
    /// barge-in monitoring) and releases it on stop — or on pause, which is a
    /// real resource pause: engine, tap, and session ownership all go away
    /// while the Voice Conversation stays logically open.
    private var captureLease: VoiceAudioLease?
    let events: AsyncStream<VoiceCaptureEvent>

    /// Optional injection instead of a default `.shared` argument: default
    /// parameter values are evaluated in a nonisolated context, which cannot
    /// read the MainActor-isolated singleton.
    /// `makeEngine` is the test seam for the capture graph: production uses
    /// a real `AVAudioEngine`; ConduitTests inject fakes to drive the
    /// rebuild, tap-format, and retry paths without audio hardware.
    init(
        coordinator: VoiceAudioSessionCoordinator? = nil,
        makeEngine: @escaping () -> VoiceCaptureEngine = { SystemVoiceCaptureEngine() }
    ) {
        self.coordinator = coordinator ?? .shared
        self.makeEngine = makeEngine
        self.engine = makeEngine()
        var capturedContinuation: AsyncStream<VoiceCaptureEvent>.Continuation?
        events = AsyncStream { capturedContinuation = $0 }
        continuation = capturedContinuation
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: session
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            switch session.recordPermission {
            case .granted:
                continuation.resume(returning: true)
            case .denied:
                continuation.resume(returning: false)
            case .undetermined:
                session.requestRecordPermission { continuation.resume(returning: $0) }
            @unknown default:
                continuation.resume(returning: false)
            }
        }
    }

    func startListening(includePreRoll: Bool = false) throws {
        do {
            try startCaptureIfNeeded()
        } catch {
            handleStartupFailure(error, stage: "startListening")
            throw error
        }
        capturedPCM = includePreRoll ? preRollPCM : Data()
        lastCaptureFailure = nil
        activelyRecording = true
        paused = false
        liftPlaybackHold()
        shouldKeepEngineRunning = true
    }

    func beginBargeInMonitoring() throws {
        guard !paused else { return }
        do {
            try startCaptureIfNeeded()
        } catch {
            handleStartupFailure(error, stage: "beginBargeInMonitoring")
            throw error
        }
        activelyRecording = false
        paused = false
        liftPlaybackHold()
        shouldKeepEngineRunning = true
    }

    /// Playback suspension that keeps the microphone hardware. Frames are
    /// dropped at the admission gate (no meter, VAD, pre-roll, or captured
    /// audio), but the engine and the capture lease stay up, so the next
    /// `startListening()` reuses the running engine instead of starting a
    /// new one. That matters on a locked phone: iOS refuses to start
    /// recording while Conduit is in the background (the engine start
    /// fails with 'what', 2003329396), so a capture torn down by `pause()`
    /// for a reply could never reopen afterwards. A capture that is not
    /// running has nothing to keep, so it falls back to a real pause.
    func holdForPlayback() {
        guard !paused else { return }
        guard captureLease != nil, engine.isRunning else {
            pause()
            return
        }
        activelyRecording = false
        heldForPlayback = true
    }

    /// A real resource pause: the engine, tap, converter, and capture's
    /// audio-session lease are released so microphone hardware and the
    /// system session are not held while the user believes the mic is
    /// paused. `resume()` reacquires everything. The Voice Conversation
    /// stays logically open across the pause.
    func pause() {
        guard !paused else { return }
        paused = true
        heldForPlayback = false
        shouldKeepEngineRunning = false
        captureGeneration &+= 1
        publishGenerationForInterruptionObservers()
        teardownRendering()
        releaseLease()
    }

    func resume() throws {
        do {
            try startCaptureIfNeeded()
        } catch {
            handleStartupFailure(error, stage: "resume")
            throw error
        }
        paused = false
        liftPlaybackHold()
        shouldKeepEngineRunning = true
    }

    func finishUtterance() throws -> VoiceCapturedAudio {
        activelyRecording = false
        paused = false
        let pcm = capturedPCM
        capturedPCM.removeAll(keepingCapacity: true)
        guard !pcm.isEmpty else {
            if let lastCaptureFailure { throw VoiceAudioError.unavailable(lastCaptureFailure) }
            throw VoiceAudioError.noAudioCaptured
        }
        let duration = Double(pcm.count) / (Self.outputSampleRate * Double(Self.outputBytesPerFrame))
        return VoiceCapturedAudio(
            wavData: Self.wavWrapping(pcm16: pcm, sampleRate: Int(Self.outputSampleRate)),
            pcm16Data: pcm,
            sampleRate: Self.outputSampleRate,
            duration: duration
        )
    }

    func stop() {
        activelyRecording = false
        paused = false
        heldForPlayback = false
        shouldKeepEngineRunning = false
        // Deliberately unguarded (unlike pause): a redundant stop bumps the
        // generation again, which is always fail-closed.
        captureGeneration &+= 1
        publishGenerationForInterruptionObservers()
        teardownRendering()
        releaseLease()
    }

    private func startCaptureIfNeeded() throws {
        if captureLease == nil {
            // Acquiring configures the conversation policy (category/mode/
            // options) and activates the session through the coordinator, so
            // concurrent owners can never fight over the singleton.
            captureLease = try coordinator.acquire(.conversationCapture)
        }
        if !engine.isRunning { try startFreshEngine() }
    }

    /// Every rendering lifetime starts on a new engine so the input node
    /// reports the live hardware format; a recoverable graph failure
    /// re-applies the session policy and retries once.
    private func startFreshEngine() throws {
        try VoiceAudioEngineRecovery.startFresh(
            rebuild: { rebuildEngine() },
            reassert: { try coordinator.reassert() },
            start: { try startEngine() }
        )
    }

    private func rebuildEngine() {
        teardownRendering()
        engine = makeEngine()
    }

    private func handleStartupFailure(_ error: Error, stage: String) {
        logStartupFailure(error, stage: stage)
        stop()
    }

    private func logStartupFailure(_ error: Error, stage: String) {
        let nsError = error as NSError
        let inputFormat = engine.hardwareInputFormat
        let inputPorts = session.currentRoute.inputs
            .map { $0.portType.rawValue }
            .joined(separator: ",")
        voiceAudioLogger.error(
            "Capture startup failed stage=\(stage, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) ports=\(inputPorts, privacy: .public) sessionRate=\(self.session.sampleRate, privacy: .public) sessionChannels=\(self.session.inputNumberOfChannels, privacy: .public) inputRate=\(inputFormat.sampleRate, privacy: .public) inputChannels=\(inputFormat.channelCount, privacy: .public)"
        )
    }

    private func startEngine() throws {
        let hardwareFormat = engine.hardwareInputFormat
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            // Recoverable: a fresh input node can report an empty format
            // until the session settles after a route change.
            throw VoiceAudioInputFormatUnavailable()
        }
        // A nil-format tap uses the node's output format. If that disagrees
        // with the live hardware rate, installTap raises an Objective-C
        // exception (an app crash), so tap at the validated hardware format
        // instead. The normal path keeps the nil-format tap unchanged.
        let tapFormat = VoiceAudioEngineRecovery.tapFormat(
            nodeOutput: engine.inputNodeOutputFormat,
            hardware: hardwareFormat
        )
        if tapFormat != nil {
            voiceAudioLogger.notice(
                "Input node output format disagrees with hardware rate \(hardwareFormat.sampleRate, privacy: .public); tapping at the hardware format"
            )
        }
        converter = nil
        // Defensive: a recovery restart (e.g. after a route change stops the
        // engine) can reach startEngine while a stale tap still hangs on bus
        // 0 even though the engine is not running. Removing first keeps the
        // reinstall from stacking a second tap; removeTap is a no-op when
        // none exists.
        engine.removeInputTap()
        // A freshly installed tap begins a new rendering generation: frames
        // it produces are stamped with this identity, and any teardown
        // invalidates it so queued frames from the old tap are recognized
        // as stale.
        captureGeneration &+= 1
        publishGenerationForInterruptionObservers()
        let frameGeneration = captureGeneration
        engine.installInputTap(bufferSize: 1_024, format: tapFormat) { [weak self] buffer, _ in
            let frameHoldEpoch = self?.holdEpochForTap ?? 0
            // AVAudioEngine owns and reuses tap buffers as soon as this block
            // returns. Copy the frame bytes before crossing onto MainActor so
            // conversion never reads a recycled hardware buffer.
            guard let copy = AVAudioPCMBuffer(
                pcmFormat: buffer.format,
                frameCapacity: buffer.frameLength
            ) else { return }
            copy.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in 0..<min(source.count, destination.count) {
                guard let sourceData = source[index].mData,
                      let destinationData = destination[index].mData else { continue }
                let byteCount = Int(source[index].mDataByteSize)
                destinationData.copyMemory(from: sourceData, byteCount: byteCount)
                destination[index].mDataByteSize = source[index].mDataByteSize
            }
            Task { @MainActor [weak self] in
                // Capture-generation fence: pause()/stop() tear the tap
                // down, but a frame already in flight across this hop
                // belongs to the previous generation and must not surface
                // into the new one — even when a stop was immediately
                // followed by a restart that re-armed the live flags. The
                // admission seam checks the frame's own generation against
                // the currently installed tap before anything downstream
                // (including consume's own defense-in-depth guard) runs.
                guard let self, self.acceptsFrame(generation: frameGeneration),
                      frameHoldEpoch == self.holdEpoch else { return }
                self.consume(copy, generation: frameGeneration)
            }
        }
        engine.prepare()
        try engine.start()
    }

    private func teardownRendering() {
        engine.removeInputTap()
        engine.stop()
        converter = nil
    }

    private func releaseLease() {
        guard let lease = captureLease else { return }
        captureLease = nil
        coordinator.release(lease)
    }

    /// Single admission gate for tap frames on their way into PCM state.
    /// A frame is admitted only when it was produced by the currently
    /// installed tap generation while capture is unpaused (and not held for
    /// playback) and the engine is
    /// expected to stay live. Both the MainActor hop and consume() gate on
    /// this seam, so an invalidated generation's bytes can never reach
    /// conversion state, pre-roll, captured audio, the meter, or VAD — even
    /// when a stop was immediately followed by a restart that re-armed the
    /// live flags.
    func acceptsFrame(generation: UInt64) -> Bool {
        generation == captureGeneration && !paused && !heldForPlayback && shouldKeepEngineRunning
    }

    func consume(_ buffer: AVAudioPCMBuffer, generation: UInt64) {
        // Defense-in-depth: the hop already admitted this frame, but any
        // future caller path must equally fail closed before PCM admission.
        guard acceptsFrame(generation: generation) else { return }
        if converter == nil || !Self.converter(converter, accepts: buffer.format) {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else {
            lastCaptureFailure = "The microphone audio format could not be converted."
            return
        }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio) + 32)
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            lastCaptureFailure = "Conduit could not allocate a microphone conversion buffer."
            return
        }
        var conversionError: NSError?
        var suppliedInput = false
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            guard !suppliedInput else {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let conversionError {
            lastCaptureFailure = "Microphone conversion failed: \(conversionError.localizedDescription)"
            return
        }
        guard status != .error else {
            lastCaptureFailure = "Microphone conversion failed."
            return
        }
        guard converted.frameLength > 0 else {
            lastCaptureFailure = "The microphone converter produced no audio frames."
            return
        }
        guard let channel = converted.floatChannelData?[0] else {
            lastCaptureFailure = "The microphone converter returned an unsupported sample layout."
            return
        }
        let encoded = VoicePCMEncoding.encode(channel, count: Int(converted.frameLength))
        let pcm = encoded.data
        lastCaptureFailure = nil
        appendPreRoll(pcm)
        if activelyRecording { capturedPCM.append(pcm) }
        onPCM16Chunk?(pcm)
        continuation?.yield(.level(encoded.peak, date: Date(), generation: generation))
    }

    private func appendPreRoll(_ pcm: Data) {
        preRollPCM.append(pcm)
        if preRollPCM.count > maximumPreRollBytes {
            preRollPCM.removeFirst(preRollPCM.count - maximumPreRollBytes)
        }
    }

    /// Internal for tests: the deterministic stale-interruption regression
    /// drives this entry point directly.
    ///
    /// Hopped through `Task { @MainActor }`: session notifications are not
    /// guaranteed to arrive on the main thread, and stop() now releases the
    /// capture lease through the MainActor coordinator. The interruption's
    /// capture generation is captured SYNCHRONOUSLY on the notifying thread
    /// — reading it later on the MainActor would observe whatever generation
    /// is installed by then. The fence runs BEFORE any mutation: an
    /// interruption that observed a torn-down generation must never stop the
    /// live one, release its lease, or emit a failure that applies to it.
    @objc func handleInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue), type == .began else { return }
        // PRE-STOP generation: identifies the capture runtime the
        // notification belonged to, captured synchronously on the notifying
        // thread before any MainActor work.
        let observedGeneration = generationForInterruptionObservers
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Stale-callback fence BEFORE mutation: a queued interruption
            // that observed a torn-down generation must never stop the
            // live one, release its lease, or emit a failure that applies
            // to it.
            guard observedGeneration == captureGeneration else {
                voiceAudioLogger.notice(
                    "Discarding interruption for torn-down capture generation \(observedGeneration, privacy: .public); current \(self.captureGeneration, privacy: .public)"
                )
                return
            }
            stop()
            // POST-STOP generation: the authoritative service state after
            // the accepted runtime was torn down. Emitting this (not the
            // pre-stop value) lets the controller recognize the event as
            // belonging to the state it actually left behind.
            let postStopGeneration = captureGeneration
            continuation?.yield(.interrupted(generation: postStopGeneration))
        }
    }

    /// Hopped through `Task { @MainActor }` for the same reason as
    /// `handleInterruption`; `coordinator.reassert()` is MainActor-isolated.
    @objc private func handleRouteChange(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.handleRouteChangeOnMain() }
    }

    private func handleRouteChangeOnMain() {
        // A nil-format tap follows the input node's actual route format. Rebuild
        // the converter lazily without churning an already-running engine.
        converter = nil
        if shouldKeepEngineRunning, !engine.isRunning {
            do {
                // The lease is still held, but the system may have torn the
                // session down with the old route: reapply the conversation
                // policy before restarting the engine.
                try coordinator.reassert()
                try startFreshEngine()
            } catch {
                handleStartupFailure(error, stage: "routeChange")
                continuation?.yield(.interrupted(generation: captureGeneration))
                return
            }
        }
        continuation?.yield(.routeChanged)
    }

    private static func converter(_ converter: AVAudioConverter?, accepts format: AVAudioFormat) -> Bool {
        guard let input = converter?.inputFormat else { return false }
        return input.commonFormat == format.commonFormat
            && abs(input.sampleRate - format.sampleRate) < 0.5
            && input.channelCount == format.channelCount
            && input.isInterleaved == format.isInterleaved
    }

    private static func wavWrapping(pcm16: Data, sampleRate: Int) -> Data {
        let byteRate = sampleRate * outputBytesPerFrame
        let fileSize = 36 + pcm16.count
        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.append(UInt32(fileSize).littleEndianData)
        header.append("WAVEfmt ".data(using: .ascii)!)
        header.append(UInt32(16).littleEndianData)
        header.append(UInt16(1).littleEndianData)
        header.append(UInt16(outputChannelCount).littleEndianData)
        header.append(UInt32(sampleRate).littleEndianData)
        header.append(UInt32(byteRate).littleEndianData)
        header.append(UInt16(outputBytesPerFrame).littleEndianData)
        header.append(UInt16(16).littleEndianData)
        header.append("data".data(using: .ascii)!)
        header.append(UInt32(pcm16.count).littleEndianData)
        header.append(pcm16)
        return header
    }
}

enum VoicePCMEncoding {
    static func encode(_ samples: UnsafePointer<Float>, count: Int) -> (data: Data, peak: Float) {
        guard count > 0 else { return (Data(), 0) }
        var pcm = [Int16](repeating: 0, count: count)
        var peak: Float = 0
        for index in 0..<count {
            let raw = samples[index]
            let clamped = raw.isFinite ? min(1, max(-1, raw)) : 0
            peak = max(peak, abs(clamped))
            let scaled = clamped >= 0 ? clamped * Float(Int16.max) : clamped * 32_768
            pcm[index] = Int16(scaled.rounded()).littleEndian
        }
        let data = pcm.withUnsafeBytes { Data($0) }
        return (data, peak)
    }
}

private extension FixedWidthInteger {
    var littleEndianData: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: MemoryLayout<Self>.size)
    }
}

/// The slice of `AVAudioEngine` capture drives: the input node's formats and
/// tap, plus the engine lifecycle. A seam so ConduitTests can exercise the
/// rebuild/retry/tap-format paths without an `AVAudioInputNode`, which
/// cannot be constructed or faked.
protocol VoiceCaptureEngine: AnyObject {
    var isRunning: Bool { get }
    /// The live hardware input format (`inputNode.inputFormat(forBus: 0)`).
    var hardwareInputFormat: AVAudioFormat { get }
    /// What a nil-format tap would use (`inputNode.outputFormat(forBus: 0)`).
    var inputNodeOutputFormat: AVAudioFormat { get }
    func installInputTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock)
    func removeInputTap()
    func prepare()
    func start() throws
    func stop()
}

final class SystemVoiceCaptureEngine: VoiceCaptureEngine {
    private let engine: AVAudioEngine
    /// Whether this engine's input node holds a tap Conduit installed.
    private var hasInputTap = false
    /// Whether the graph was prepared or started since the last stop.
    private var hasRenderResources = false

    /// `engine` is a ConduitTests seam; production always uses a new engine.
    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
    }

    var isRunning: Bool { engine.isRunning }
    var hardwareInputFormat: AVAudioFormat { engine.inputNode.inputFormat(forBus: 0) }
    var inputNodeOutputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    func installInputTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock) {
        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: block)
        hasInputTap = true
    }

    // Teardown of a graph that never rendered must not reach CoreAudio:
    // `inputNode` builds the input AURemoteIO on first access, and stopping
    // talks to the audio server. Every Voice teardown (server switch,
    // disconnect, Close) runs these on the placeholder engine, and when the
    // audio server stalls CoreAudio aborts the whole process ("AURemoteIO:
    // RPC timeout. Apparently deadlocked.").
    func removeInputTap() {
        guard hasInputTap else { return }
        engine.inputNode.removeTap(onBus: 0)
        hasInputTap = false
    }

    func prepare() {
        hasRenderResources = true
        engine.prepare()
    }

    func start() throws {
        hasRenderResources = true
        try engine.start()
    }

    func stop() {
        guard hasRenderResources else { return }
        engine.stop()
        hasRenderResources = false
    }
}
