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
    /// Whether the current engine's graph was connected or started. An
    /// untouched engine is never stopped: stopping reaches CoreAudio, and
    /// every Voice teardown stops this service whether or not it ever
    /// played. When the audio server stalls, CoreAudio aborts the whole
    /// process ("AURemoteIO: RPC timeout. Apparently deadlocked.").
    private var engineHasGraph = false
    private let makeEngine: () -> AVAudioEngine
    /// Identity of the current engine, bumped by every rebuild. The
    /// configuration-change observer captures it so a change from a replaced
    /// engine can never stop the live one.
    private var engineGeneration: UInt64 = 0
    private var engineObserver: NSObjectProtocol?
    private var format: AVAudioFormat?
    private var remainder = Data()
    /// Internal so ConduitTests can drive the drain fence without audio
    /// hardware; production code mutates it only through scheduling,
    /// draining, and stop().
    var pendingBuffers = 0
    /// Total audio scheduled on the current stream: an upper bound on what is
    /// still left to render when a drain begins.
    private var scheduledSeconds: TimeInterval = 0
    /// Slack past the scheduled audio before a drain concludes the engine is
    /// dead. Internal so ConduitTests can shorten it.
    var drainWatchdogGrace: TimeInterval = 10
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
    /// Pause bookkeeping (#373). Time spent paused does not count against
    /// the drain watchdog, whose budget is the audio left to render.
    private(set) var isPaused = false
    /// Set when an interruption (a phone call) ended standalone speech. The
    /// stream that was playing must not restart itself under the call: its
    /// next chunk is refused as a cancellation, so Read Aloud settles quietly.
    /// A new stream (`start` / an encoded clip) clears it. Conversation
    /// playback keeps its self-healing restart.
    private var interruptedStandaloneStream = false
    private var pausedAt: ContinuousClock.Instant?
    private var totalPausedDuration: Duration = .zero
    private let coordinator: VoiceAudioSessionCoordinator
    private var lease: VoiceAudioLease?
    /// Which audio-session ownership this service claims while playing.
    /// Conversation playback joins the capture-owned session; standalone
    /// flows (Read Aloud, TTS provider test) claim output-only ownership.
    var ownershipIntent: VoiceAudioIntent = .standalonePlayback
    /// Speed for the next stream (Read Aloud's speed setting), applied when a
    /// stream or encoded clip starts. At 1.0 the graph is the plain
    /// player→mixer path voice conversations use; any other rate inserts a
    /// pitch-preserving time stretch.
    var playbackRate: Float = 1.0
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
        // A media-services reset kills every engine without a configuration
        // change; settle like an interruption so drain waiters never hang.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance()
        )
        observeEngineConfiguration()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
    }

    func start(sampleRate: Double) throws {
        stop()
        interruptedStandaloneStream = false
        let rate = Self.clampedRate(playbackRate)
        // Effect units render Float32 only, so a stretched stream schedules
        // float buffers (converted in enqueuePCM16) instead of the Int16 ones
        // the direct path plays.
        let stretched = rate != 1
        let format = stretched
            ? AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
            : AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)
        guard let format else {
            throw VoiceAudioError.unavailable(AppLocalization.string("The gateway reported an unsupported PCM format."))
        }
        lease = try coordinator.acquire(ownershipIntent)
        do {
            self.format = format
            try VoiceAudioEngineRecovery.startFresh(
                rebuild: { rebuildEngine() },
                reassert: { try coordinator.reassert() },
                start: {
                    engineHasGraph = true
                    if stretched {
                        let timePitch = AVAudioUnitTimePitch()
                        timePitch.rate = rate
                        engine.attach(timePitch)
                        engine.connect(player, to: timePitch, format: format)
                        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
                    } else {
                        engine.connect(player, to: engine.mainMixerNode, format: format)
                    }
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
        // A configuration change stops the engine before its deferred
        // settle runs; buffers scheduled onto a stopped player never
        // complete. Treat that as a stream boundary and restart now.
        // A paused stream stays paused across that restart (AirPods back in
        // the case): the fresh player holds its place until resume().
        let holdPause = isPaused
        if interruptedStandaloneStream { throw CancellationError() }
        if format != nil, !engine.isRunning { stop() }
        if format == nil {
            try start(sampleRate: sampleRate)
            if holdPause { _ = pause() }
        }
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
        if let destination = buffer.int16ChannelData {
            pcm.withUnsafeBytes { source in
                guard let base = source.baseAddress else { return }
                destination[0].assign(from: base.assumingMemoryBound(to: Int16.self), count: Int(frames))
            }
        } else if let destination = buffer.floatChannelData {
            pcm.withUnsafeBytes { source in
                Self.convertPCM16(source, into: destination[0], frames: Int(frames))
            }
        } else {
            return 0
        }
        pendingBuffers += 1
        // A stream stays started across drains (Gemini Live keeps it open
        // for the whole conversation), so every scheduled chunk marks it
        // playing again, not just the one that started it.
        isPlaying = true
        scheduledSeconds += Double(frames) / format.sampleRate
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
        interruptedStandaloneStream = false
        lease = try coordinator.acquire(ownershipIntent)
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            // AVAudioPlayer supports up to 2x.
            let rate = min(Self.clampedRate(playbackRate), 2)
            if rate != 1 {
                player.enableRate = true
                player.rate = rate
            }
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
        // Watchdog: every waiter is normally resumed by a buffer completion
        // or stop(). If rendering died without any observed notification,
        // nothing would ever resume it, so settle once all scheduled audio
        // could have played plus a grace period. Only a dead engine gets here.
        let generation = playbackGeneration
        let budget = scheduledSeconds + (encodedPlayer?.duration ?? 0) + drainWatchdogGrace
        let budgetDuration = Duration.seconds(max(0, budget))
        let startedAt = ContinuousClock.now
        let pausedAtStart = pausedDuration()
        let watchdog = Task { @MainActor [weak self] in
            var wait = budgetDuration
            while true {
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled, let self,
                      self.playbackGeneration == generation,
                      !self.drainWaiters.isEmpty else { return }
                // Only unpaused time counts against the budget; a pause in
                // progress is re-checked until it ends.
                if self.isPaused {
                    wait = .seconds(1)
                    continue
                }
                let played = (ContinuousClock.now - startedAt) - (self.pausedDuration() - pausedAtStart)
                guard played < budgetDuration else { break }
                wait = budgetDuration - played
            }
            self?.stop()
        }
        await withCheckedContinuation { continuation in
            drainWaiters.append(continuation)
        }
        watchdog.cancel()
    }

    func pause() -> Bool {
        guard !isPaused else { return true }
        if let encodedPlayer, encodedPlayer.isPlaying {
            encodedPlayer.pause()
        } else if format != nil, engineHasGraph, engine.isRunning {
            // The engine keeps running; only the player holds its place, so
            // buffers still arriving from the stream queue up behind it.
            player.pause()
        } else {
            return false
        }
        isPaused = true
        pausedAt = .now
        return true
    }

    func resume() {
        guard isPaused else { return }
        if let encodedPlayer {
            encodedPlayer.play()
        } else {
            player.play()
        }
        endPause()
    }

    private func endPause() {
        if let pausedAt { totalPausedDuration += ContinuousClock.now - pausedAt }
        pausedAt = nil
        isPaused = false
    }

    private func pausedDuration() -> Duration {
        totalPausedDuration + (pausedAt.map { ContinuousClock.now - $0 } ?? .zero)
    }

    func stop() {
        playbackGeneration &+= 1
        isFinishing = false
        if isPaused { endPause() }
        // Pause time only matters to this stream's drain watchdog, which
        // the generation bump above already retired.
        totalPausedDuration = .zero
        teardownGraph()
        encodedPlayer?.stop()
        encodedPlayer = nil
        format = nil
        remainder.removeAll(keepingCapacity: true)
        pendingBuffers = 0
        scheduledSeconds = 0
        isPlaying = false
        let waiters = drainWaiters
        drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
        releaseOwnership()
    }

    /// Stops the player and engine if this engine's graph was built. The
    /// player can only hold scheduled audio once `engineHasGraph` is set, so
    /// skipping an untouched engine never strands a buffer.
    private func teardownGraph() {
        guard engineHasGraph else { return }
        player.stop()
        engine.stop()
        engineHasGraph = false
    }

    /// Replaces the engine and player with fresh instances so the new graph
    /// is built against the session's current hardware format.
    private func rebuildEngine() {
        teardownGraph()
        stopObservingEngineConfiguration()
        engine = makeEngine()
        player = AVAudioPlayerNode()
        engine.attach(player)
        observeEngineConfiguration()
    }

    /// Observes only the current engine. Observing every engine (object: nil)
    /// delivered other engines' changes too, including the echo-cancelling
    /// live-voice engine's while it was being torn down and freed; touching
    /// that notification's engine from the posting thread aborted the app
    /// ("Cannot form weak reference"). The handler never reads the
    /// notification's object: the captured generation says whose change it
    /// was.
    private func observeEngineConfiguration() {
        stopObservingEngineConfiguration()
        engineGeneration &+= 1
        let generation = engineGeneration
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            // The outer weak capture matters: without it the inner one
            // captures self strongly here, and the center keeps the service
            // alive through this block.
            Task { @MainActor [weak self] in self?.engineConfigurationChanged(generation: generation) }
        }
    }

    /// Runs before the engine it observes is released.
    private func stopObservingEngineConfiguration() {
        guard let engineObserver else { return }
        NotificationCenter.default.removeObserver(engineObserver)
        self.engineObserver = nil
    }

    /// Read Aloud offers 1x–2x. Slower than 1x is never played: the drain
    /// watchdog budgets source-length audio, which a slowed stream outlasts.
    /// Not-a-number plays at normal speed.
    nonisolated static func clampedRate(_ rate: Float) -> Float {
        guard rate.isFinite else { return 1 }
        return min(max(rate, 1), 4)
    }

    /// Little-endian PCM16 to Float32 samples in [-1, 1), for the stretched
    /// graph. Reads unaligned: the bytes come from a Data slice.
    nonisolated static func convertPCM16(_ source: UnsafeRawBufferPointer, into destination: UnsafeMutablePointer<Float>, frames: Int) {
        for index in 0..<min(frames, source.count / 2) {
            let sample = source.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)
            destination[index] = Float(Int16(littleEndian: sample)) / 32_768
        }
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

    /// The notification handlers (these selectors and the engine observer's
    /// block) hop through `Task { @MainActor }`: session and engine
    /// notifications are not guaranteed to arrive on the main thread, and
    /// every reachable entry point below (stop, coordinator release, waiter
    /// resumption) is MainActor-isolated state.
    @objc private func handleInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue), type == .began else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.ownershipIntent == .standalonePlayback, self.lease != nil {
                self.interruptedStandaloneStream = true
            }
            // Playback can no longer continue: settle buffers and drain
            // waiters so awaiting controllers never hang, and release session
            // ownership so other media recovers. Resuming after the
            // interruption ends is deliberate follow-up work, not silent
            // breakage.
            self.stop()
        }
    }

    @objc private func handleMediaServicesReset(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.stop() }
    }

    /// A route change can stop the rendering engine under a live lease
    /// (AirPods disconnect, dock/undock). Settle instead of leaving buffers
    /// undrained and ownership claimed by audio that can never play. A
    /// conversation drain self-heals: the next PCM buffer reacquires
    /// ownership and restarts the engine on a fresh graph. Changes from
    /// replaced engines are not this stream's.
    private func engineConfigurationChanged(generation: UInt64) {
        guard Self.settlesOnConfigurationChange(
            from: generation,
            liveEngine: engineGeneration,
            holdsLease: lease != nil,
            engineRunning: engine.isRunning
        ) else { return }
        stop()
    }

    /// Internal for tests: whether a configuration change ends the stream.
    nonisolated static func settlesOnConfigurationChange(
        from generation: UInt64,
        liveEngine: UInt64,
        holdsLease: Bool,
        engineRunning: Bool
    ) -> Bool {
        generation == liveEngine && holdsLease && !engineRunning
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
