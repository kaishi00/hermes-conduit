//
//  AVSpeechPlaybackService.swift
//  Conduit
//

import AVFAudio
import Foundation

@MainActor
final class AVSpeechPlaybackService: NSObject, SpeechPlaybackService {
    /// Engine and player are rebuilt for every PCM stream (see
    /// `VoiceAudioEngineRecovery`): an engine kept across session
    /// reconfigurations — capture pausing for speaker-safe playback, Read
    /// Aloud's `.playback` policy, route changes — starts against a stale
    /// output format and fails with -10868 as the assistant begins to speak.
    private var engine: AVAudioEngine
    private var player: AVAudioPlayerNode
    private let makeEngine: () -> AVAudioEngine
    private var format: AVAudioFormat?
    private var remainder = Data()
    /// Internal so ConduitTests can drive the drain fence without audio
    /// hardware; production code mutates it only through scheduling,
    /// draining, and stop().
    var pendingBuffers = 0
    /// Identity of the current playback lifetime. Bumped by every stop(), so
    /// completion callbacks from buffers of a stopped (or replaced) player —
    /// AVAudioPlayerNode fires them for unplayed buffers when stopped — can
    /// never drain the next stream's counters.
    private(set) var playbackGeneration: UInt64 = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var encodedPlayer: AVAudioPlayer?
    /// Set once `finish()` is requested: when the last scheduled buffer (or
    /// the encoded player) then drains, playback is terminal and ownership
    /// must be released. Mid-stream buffer gaps keep ownership so the session
    /// does not flap while the gateway prepares the next chunk.
    private var isFinishing = false
    private let coordinator: VoiceAudioSessionCoordinator
    private var lease: VoiceAudioLease?
    /// Which audio-session ownership this service claims while playing.
    /// Conversation playback joins the capture-owned session; standalone
    /// flows (Read Aloud, TTS provider test) claim output-only ownership.
    var ownershipIntent: VoiceAudioIntent = .standalonePlayback
    private(set) var isPlaying = false

    /// Optional injection instead of a default `.shared` argument: default
    /// parameter values are evaluated in a nonisolated context, which cannot
    /// read the MainActor-isolated singleton.
    init(
        coordinator: VoiceAudioSessionCoordinator? = nil,
        makeEngine: @escaping () -> AVAudioEngine = { AVAudioEngine() }
    ) {
        self.coordinator = coordinator ?? .shared
        self.makeEngine = makeEngine
        self.engine = makeEngine()
        self.player = AVAudioPlayerNode()
        super.init()
        engine.attach(player)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            // Engines are replaced per stream, so observe every engine and
            // filter to the live one in the handler.
            object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func start(sampleRate: Double) throws {
        stop()
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true) else {
            throw VoiceAudioError.unavailable(AppLocalization.string("The gateway reported an unsupported PCM format."))
        }
        lease = try coordinator.acquire(ownershipIntent)
        do {
            self.format = format
            try VoiceAudioEngineRecovery.startFresh(
                rebuild: { rebuildEngine() },
                reassert: { try coordinator.reassert() },
                start: {
                    engine.connect(player, to: engine.mainMixerNode, format: format)
                    engine.prepare()
                    try engine.start()
                }
            )
        } catch {
            // Full settle, not just ownership: a failed start must not leave
            // `format` set on a graph that never started, or later chunks
            // would schedule onto a dead player and drain would never fire.
            stop()
            throw error
        }
        player.play()
        isPlaying = true
    }

    func enqueuePCM16(_ data: Data, sampleRate: Double) throws -> Int {
        if format == nil { try start(sampleRate: sampleRate) }
        guard let format, abs(format.sampleRate - sampleRate) < 1 else {
            // A stream that changes sample rates can never render; settle
            // immediately so the lease does not wait on the caller's error
            // path.
            stop()
            throw VoiceAudioError.unavailable(AppLocalization.string("The gateway changed PCM sample rates during a stream."))
        }
        remainder.append(data)
        let alignedBytes = remainder.count - (remainder.count % 2)
        guard alignedBytes > 0 else { return 0 }
        let pcm = remainder.prefix(alignedBytes)
        remainder.removeFirst(alignedBytes)
        let frames = AVAudioFrameCount(alignedBytes / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return 0 }
        buffer.frameLength = frames
        guard let destination = buffer.int16ChannelData else { return 0 }
        pcm.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            destination[0].assign(from: base.assumingMemoryBound(to: Int16.self), count: Int(frames))
        }
        pendingBuffers += 1
        let generation = playbackGeneration
        player.scheduleBuffer(
            buffer,
            at: nil,
            options: [],
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in self?.bufferDidDrain(generation: generation) }
        }
        return alignedBytes
    }

    func playEncodedAudioData(_ data: Data) throws {
        stop()
        lease = try coordinator.acquire(ownershipIntent)
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.prepareToPlay()
            guard player.play() else { throw VoiceAudioError.unavailable(AppLocalization.string("Could not play Hermes fallback speech.")) }
            encodedPlayer = player
            isPlaying = true
        } catch {
            releaseOwnership()
            throw error
        }
    }

    func finish() throws {
        // An odd tail is invalid PCM16 and is intentionally discarded rather
        // than shifted into the next response.
        remainder.removeAll(keepingCapacity: true)
        isFinishing = true
    }

    func drain() async {
        guard pendingBuffers > 0 || encodedPlayer != nil else {
            isPlaying = false
            // Nothing was ever scheduled (or the queue drained between
            // checks): a finishing stream must still release ownership.
            if isFinishing { stop() }
            return
        }
        await withCheckedContinuation { continuation in
            drainWaiters.append(continuation)
        }
    }

    func stop() {
        playbackGeneration &+= 1
        isFinishing = false
        player.stop()
        encodedPlayer?.stop()
        encodedPlayer = nil
        engine.stop()
        format = nil
        remainder.removeAll(keepingCapacity: true)
        pendingBuffers = 0
        isPlaying = false
        let waiters = drainWaiters
        drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
        releaseOwnership()
    }

    /// Replaces the engine and player with fresh instances so the new graph
    /// is built against the session's current hardware format.
    private func rebuildEngine() {
        player.stop()
        engine.stop()
        engine = makeEngine()
        player = AVAudioPlayerNode()
        engine.attach(player)
    }

    /// Ownership is released only after the engine stopped rendering, so the
    /// coordinator never deactivates the session underneath live audio. The
    /// coordinator keeps the session active when another owner (conversation
    /// capture) still needs it.
    private func releaseOwnership() {
        guard let lease else { return }
        self.lease = nil
        coordinator.release(lease)
    }

    /// Both notification handlers hop through `Task { @MainActor }`: session
    /// notifications are not guaranteed to arrive on the main thread, and
    /// every reachable entry point below (stop, coordinator release, waiter
    /// resumption) is MainActor-isolated state.
    @objc private func handleInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue), type == .began else { return }
        Task { @MainActor [weak self] in
            // Playback can no longer continue: settle buffers and drain
            // waiters so awaiting controllers never hang, and release session
            // ownership so other media recovers. Resuming after the
            // interruption ends is deliberate follow-up work, not silent
            // breakage.
            self?.stop()
        }
    }

    @objc private func handleEngineConfigurationChange(_ notification: Notification) {
        guard let changedEngine = notification.object as? AVAudioEngine else { return }
        // Weak, not an address: a replaced engine that has since been freed
        // reads back nil and can never alias the live engine.
        let changed = WeakAudioEngineReference(changedEngine)
        Task { @MainActor [weak self] in
            // A route change can stop the rendering engine under a live lease
            // (AirPods disconnect, dock/undock). Settle instead of leaving
            // buffers undrained and ownership claimed by audio that can never
            // play. A conversation drain self-heals: the next PCM buffer
            // reacquires ownership and restarts the engine on a fresh graph.
            // Changes from replaced engines (or the capture service's engine)
            // are not this stream's.
            guard let self,
                  let changedEngine = changed.engine,
                  changedEngine === self.engine,
                  self.lease != nil,
                  !self.engine.isRunning else { return }
            self.stop()
        }
    }

    /// Internal for tests: the drain-fence regression drives this directly.
    func bufferDidDrain(generation: UInt64) {
        guard generation == playbackGeneration, pendingBuffers > 0 else { return }
        pendingBuffers -= 1
        guard pendingBuffers == 0 else { return }
        if isFinishing {
            // Terminal: everything queued has rendered. stop() tears the
            // engine down, resumes drain waiters exactly once, and releases
            // session ownership so standalone speech un-ducks other media the
            // moment it ends.
            stop()
        } else {
            isPlaying = false
            settleDrainWaiters()
        }
    }

    private func settleDrainWaiters() {
        let waiters = drainWaiters
        drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

extension AVSpeechPlaybackService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.encodedPlayer === player else { return }
            // Natural completion is terminal for the encoded path: stop()
            // clears the player, resumes drain waiters, and releases the
            // session lease.
            self.stop()
        }
    }
}

/// Carries a configuration-change notification's engine across the MainActor
/// hop without retaining it or comparing raw addresses.
private final class WeakAudioEngineReference: @unchecked Sendable {
    weak var engine: AVAudioEngine?
    init(_ engine: AVAudioEngine) { self.engine = engine }
}
