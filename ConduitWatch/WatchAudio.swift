//
//  WatchAudio.swift
//  Conduit Watch
//
//  The Watch's microphone and speaker for a call: one AVAudioEngine with
//  the microphone converted to 16 kHz PCM16 (what Gemini and Grok take on
//  the iPhone) and a player node for the model's speech. The session is
//  play-and-record with the default route policy, which is what lets the
//  built-in speaker play (long-form audio would want Bluetooth).
//

import AVFAudio
import Foundation

@MainActor
final class WatchAudio {
    struct Options: Hashable {
        /// The engine's echo cancellation and noise suppression.
        var voiceProcessing = false
        /// The voice chat session mode instead of the default one.
        var voiceChatMode = false
    }

    static let captureRate: Double = 16_000
    /// Speech waits this long (or for this much audio) before it starts,
    /// so a late packet doesn't leave a gap mid-sentence.
    static let playbackPreRoll: TimeInterval = 0.15
    static let playbackPreRollAudio: TimeInterval = 0.2

    /// Microphone audio at 16 kHz, with when its last sample was captured
    /// (system uptime).
    var onCapture: (([Int16], TimeInterval) -> Void)?
    /// Speech started playing; the time is when it should reach the ear.
    var onPlaybackStarted: ((TimeInterval) -> Void)?
    /// Everything scheduled has played out.
    var onDrained: (() -> Void)?
    /// The system took the audio (true) or gave it back (false).
    var onInterruption: ((Bool) -> Void)?

    private(set) var isRunning = false
    private(set) var options = Options()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var playerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let captureFormat = AVAudioFormat(standardFormatWithSampleRate: WatchAudio.captureRate, channels: 1)!
    private var captureGeneration = 0
    private var outstandingBuffers = 0
    /// The last refused playback rate, logged once rather than per packet.
    private var refusedRate: Double?
    private var playbackGeneration = 0
    /// What a failed start got as far as. Tearing down a graph that never
    /// rendered must not reach CoreAudio, which can abort the process
    /// ("RPC timeout. Apparently deadlocked."), the way the phone's
    /// capture service guards it.
    private var hasInputTap = false
    private var hasRenderResources = false
    /// The start step running, for the log when one fails.
    private var startStep = "session"
    private var startPending = false
    private var queuedDuration: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []

    var isPlaying: Bool { outstandingBuffers > 0 || startPending }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Starts the microphone and the player. Must run from a tap while the
    /// app is in front: watchOS only starts recording then.
    func start(options: Options, playbackRate: Double) throws {
        stop()
        self.options = options
        let session = AVAudioSession.sharedInstance()
        startStep = "session"
        do {
            try session.setCategory(.playAndRecord, mode: options.voiceChatMode ? .voiceChat : .default, policy: .default, options: [])
            try session.setActive(true)
        } catch {
            logStartFailure(error)
            throw error
        }
        do {
            try startEngine(session: session, options: options, playbackRate: playbackRate)
        } catch {
            logStartFailure(error)
            // Nothing half started stays behind: the tap, the engine, the
            // active session.
            captureGeneration += 1
            if hasInputTap { engine?.inputNode.removeTap(onBus: 0) }
            if hasRenderResources { engine?.stop() }
            hasInputTap = false
            hasRenderResources = false
            engine = nil
            player = nil
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            throw error
        }
    }

    private func startEngine(session: AVAudioSession, options: Options, playbackRate: Double) throws {
        let engine = AVAudioEngine()
        // Kept from the start, so a failure below can undo it.
        self.engine = engine
        hasInputTap = false
        hasRenderResources = false
        if options.voiceProcessing {
            startStep = "voiceProcessing"
            try engine.inputNode.setVoiceProcessingEnabled(true)
        }
        startStep = "microphone"
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw WatchAudioError.noMicrophoneFormat
        }
        captureGeneration += 1
        let generation = captureGeneration
        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            let capturedAt = ProcessInfo.processInfo.systemUptime
            // The engine reuses its buffer once this returns: copy first.
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in 0..<min(source.count, destination.count) {
                guard let from = source[index].mData, let to = destination[index].mData else { continue }
                to.copyMemory(from: from, byteCount: Int(source[index].mDataByteSize))
                destination[index].mDataByteSize = source[index].mDataByteSize
            }
            WatchVoiceMain.async { [weak self] in
                guard let self, self.captureGeneration == generation else { return }
                self.consume(copy, capturedAt: capturedAt)
            }
        }
        hasInputTap = true

        let player = AVAudioPlayerNode()
        engine.attach(player)
        let playerFormat = AVAudioFormat(standardFormatWithSampleRate: playbackRate, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: playerFormat)
        engine.prepare()
        hasRenderResources = true
        startStep = "engine"
        try engine.start()

        self.engine = engine
        self.player = player
        self.playerFormat = playerFormat
        isRunning = true
        observe(engine)
        WatchProbeLog.shared.note("audioStarted", [
            "voiceProcessing": options.voiceProcessing,
            "voiceChatMode": options.voiceChatMode,
            "inputRate": inputFormat.sampleRate,
            "inputChannels": Int(inputFormat.channelCount),
            "outputs": session.currentRoute.outputs.map { $0.portType.rawValue },
            "inputs": session.currentRoute.inputs.map { $0.portType.rawValue },
            "outputLatencyMs": Int(session.outputLatency * 1000),
            "inputLatencyMs": Int(session.inputLatency * 1000),
        ])
    }

    /// Which step failed, with the raw error: a device log had only
    /// "avfaudio error -308" with voice processing on.
    private func logStartFailure(_ error: Error) {
        let error = error as NSError
        WatchProbeLog.shared.note("audioStartFailed", [
            "step": startStep,
            "domain": error.domain,
            "code": error.code,
            "voiceProcessing": options.voiceProcessing,
            "voiceChatMode": options.voiceChatMode,
        ])
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        captureGeneration += 1
        stopPlayback()
        if hasInputTap { engine?.inputNode.removeTap(onBus: 0) }
        if hasRenderResources { engine?.stop() }
        hasInputTap = false
        hasRenderResources = false
        engine = nil
        player = nil
        converter = nil
        guard isRunning else { return }
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Queues speech. It starts after a short pre-roll when nothing is
    /// playing, and right after what's queued otherwise.
    func enqueue(_ samples: [Int16], sampleRate: Double) {
        guard isRunning, let player, let playerFormat, !samples.isEmpty else { return }
        guard abs(playerFormat.sampleRate - sampleRate) < 0.5 else {
            if refusedRate != sampleRate {
                refusedRate = sampleRate
                WatchProbeLog.shared.note("playbackRateMismatch", ["expected": playerFormat.sampleRate, "got": sampleRate])
            }
            return
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            channel[index] = Float(sample) / 32_768
        }
        outstandingBuffers += 1
        queuedDuration += Double(samples.count) / sampleRate
        let generation = playbackGeneration
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            WatchVoiceMain.async { [weak self] in self?.bufferPlayed(generation: generation) }
        }
        guard !player.isPlaying else { return }
        if queuedDuration >= Self.playbackPreRollAudio {
            startPlayer()
        } else if !startPending {
            startPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.playbackPreRoll) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.playbackGeneration == generation, self.startPending else { return }
                    self.startPlayer()
                }
            }
        }
    }

    /// Drops everything queued, at once.
    func stopPlayback() {
        playbackGeneration += 1
        outstandingBuffers = 0
        queuedDuration = 0
        startPending = false
        player?.stop()
    }

    private func startPlayer() {
        guard let player, isRunning else { return }
        startPending = false
        player.play()
        let latency = AVAudioSession.sharedInstance().outputLatency
        onPlaybackStarted?(ProcessInfo.processInfo.systemUptime + latency)
    }

    private func bufferPlayed(generation: Int) {
        guard generation == playbackGeneration, outstandingBuffers > 0 else { return }
        outstandingBuffers -= 1
        guard outstandingBuffers == 0 else { return }
        queuedDuration = 0
        // Stopped, so the next speech gets its pre-roll again.
        player?.stop()
        startPending = false
        onDrained?()
    }

    private func consume(_ buffer: AVAudioPCMBuffer, capturedAt: TimeInterval) {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: captureFormat)
            converter?.downmix = true
        }
        guard let converter else { return }
        let ratio = captureFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio) + 32)
        guard let converted = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            guard !supplied else {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, status != .error, converted.frameLength > 0,
              let channel = converted.floatChannelData?[0] else { return }
        var samples = [Int16](repeating: 0, count: Int(converted.frameLength))
        for index in 0..<samples.count {
            let value = max(-1, min(1, channel[index].isFinite ? channel[index] : 0))
            samples[index] = Int16((value * 32_767).rounded())
        }
        onCapture?(samples, capturedAt)
    }

    private func observe(_ engine: AVAudioEngine) {
        observers = [
            NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch type {
                    case .began?:
                        WatchProbeLog.shared.note("audioInterruptionBegan")
                        self.onInterruption?(true)
                    case .ended?:
                        WatchProbeLog.shared.note("audioInterruptionEnded")
                        self.onInterruption?(false)
                    default:
                        break
                    }
                }
            },
            NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    WatchProbeLog.shared.note("audioEngineConfigurationChange", ["running": self?.engine?.isRunning ?? false])
                    // The engine stopped underneath: treat it as taken.
                    if self?.engine?.isRunning == false { self?.onInterruption?(true) }
                }
            },
            NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { _ in
                let route = AVAudioSession.sharedInstance().currentRoute
                MainActor.assumeIsolated {
                    WatchProbeLog.shared.note("audioRouteChange", [
                        "outputs": route.outputs.map { $0.portType.rawValue },
                        "inputs": route.inputs.map { $0.portType.rawValue },
                    ])
                }
            },
        ]
    }
}

enum WatchAudioError: LocalizedError {
    case noMicrophoneFormat
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noMicrophoneFormat: return "The microphone isn't ready."
        case .permissionDenied: return "Conduit needs the microphone. Allow it in Settings on your Watch."
        }
    }
}
