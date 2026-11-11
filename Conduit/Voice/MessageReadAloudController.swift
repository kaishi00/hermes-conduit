//
//  MessageReadAloudController.swift
//  Conduit
//
//  Manual per-message read aloud. Deliberately a single-message playback
//  operation rather than a voice conversation: it opens the same streaming
//  TTS transport and plays through the same playback service, but never
//  touches microphone, STT, or voice-conversation state, so it stays usable
//  on profiles that configure TTS without transcription.
//
//  Playback outlives the app's foreground (#373): a reply that started on
//  screen keeps playing with the app in the background or the phone locked,
//  like a podcast. Only starting a new reply needs the app on screen.
//
//  With Read replies aloud on (notifier issue 674) it also reads the open
//  chat's replies as they stream, the way a voice turn's are spoken
//  (`followReply`), and a group room's new messages one after another
//  (`enqueue`).
//

import AVFoundation
import Combine
import Foundation
import UIKit

@MainActor
final class MessageReadAloudController: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing(messageID: String)
        case playing(messageID: String)
        case failed(messageID: String, message: String)
    }

    @Published private(set) var state: State = .idle
    /// True while the playing reply is held by a Now Playing pause (lock
    /// screen, Control Center, AirPods). The chat button still reads Stop.
    @Published private(set) var isPaused = false

    /// The reply being read, for the floating player (#759). Set from the
    /// tap until playback settles.
    struct NowReading: Equatable {
        let messageID: String
        let title: String
    }

    @Published private(set) var nowReading: NowReading?
    /// The speed the playing reply uses; the player changes it live.
    @Published private(set) var speed: ReadAloudSpeed = .normal

    private let playback: SpeechPlaybackService
    private let reportError: @MainActor (String) -> Void
    /// Read Aloud speed, read when each playback starts so a change in
    /// Settings applies from the next tap.
    private let playbackRate: @MainActor () -> Float
    /// Saves a speed picked in the player as the Read Aloud setting.
    private let storeSpeed: @MainActor (ReadAloudSpeed) -> Void
    private var activeGateway: VoiceGatewayService?
    private var speechStream: VoiceSpeechStream?
    private var playbackTask: Task<Void, Never>?
    private var operationGeneration: UInt64 = 0
    private var isForegroundActive = true
    /// Whether a reading may start now: Conduit is on screen.
    var isOnScreen: Bool { isForegroundActive }
    /// Held for the whole operation, from the tap until it settles. What it
    /// buys is the gap before the first audio (the stream is still opening
    /// when the phone is locked); once audio plays, the `audio` background
    /// mode keeps the app alive on its own. The argument runs if the system
    /// reclaims the time first; the returned closure ends the activity.
    private let beginBackgroundActivity: @MainActor (@escaping @MainActor () -> Void) -> @MainActor () -> Void
    private var endBackgroundActivity: (@MainActor () -> Void)?
    private let nowPlaying: ReadAloudNowPlayingPresenting
    private var nowPlayingTitle = ""
    /// A reply left paused this long is stopped, so a forgotten pause does
    /// not keep the app running in the background. Internal for tests.
    var pausedStopDelay: Duration = .seconds(10 * 60)
    private var pausedStopTask: Task<Void, Never>?
    private var routeObserver: NSObjectProtocol?
    /// Headphones came out while this operation was still opening: its
    /// first audio starts paused rather than on the speaker.
    private var pauseWhenAudioStarts: UInt64?
    /// Dictation, a voice message or a call holds the microphone, or a
    /// call from Hermes holds the session.
    private let microphoneIsHeld: @MainActor () -> Bool

    /// Read replies aloud: the open chat's turn being followed, from its
    /// start until its completion. Its words go to the reading through
    /// `continuation` once the first of them arrive.
    private struct LiveReply {
        let sessionID: String
        var filter = SpokenTextFilter()
        var receivedDelta = false
        var lastInterim: String?
        /// A segment's opening words while they could still be all of a
        /// silence marker ("[SILENT]"), which is never read.
        var held = ""
        var holding = true
        var continuation: AsyncStream<LiveSpeech>.Continuation?

        /// `raw` once the segment's words can no longer be a silence
        /// marker; until then nothing. A reply opening with a marker's
        /// prefix ("S", "NO", "[") waits for its next delta before its
        /// first word is read.
        mutating func admit(_ raw: String) -> String {
            guard holding else { return raw }
            held += raw
            let trimmed = held.trimmingCharacters(in: .whitespacesAndNewlines)
            if MessageNormalizer.silenceMarkers.contains(where: { $0.hasPrefix(trimmed) }) { return "" }
            return release()
        }

        /// What is held, at a segment's end: nothing when it is a whole
        /// silence marker.
        mutating func release() -> String {
            guard holding else { return "" }
            holding = false
            defer { held = "" }
            return MessageNormalizer.isSilenceMarker(held) ? "" : held
        }
    }

    private enum LiveSpeech {
        case text(String)
        /// Ends a segment: commentary before a tool runs is heard now, not
        /// held in the speech server's sentence buffer until the reply.
        case boundary
    }

    private var liveReply: LiveReply?
    /// A followed reply between segments (a tool runs): nothing sounds, so
    /// a pause holds the next segment until Resume rather than the engine.
    private var betweenSegments = false
    private var segmentWaiter: CheckedContinuation<Void, Never>?

    /// A group room's messages waiting to be read after the one playing.
    private struct QueuedReading {
        let messageID: String
        let content: String
        /// Readies the gateway for the message's speaker; it may stop
        /// whatever is playing.
        let prepare: @MainActor () -> Bool
    }

    private var queue: [QueuedReading] = []

    /// The audio session held across the gap between a reading and the
    /// next queued one, or a followed reply's segment and its next: each
    /// stream's playback lets the session go as it drains, and deactivating
    /// it there brought other audio back up and dropped Now Playing between
    /// every message (issue 2148). Released once the next stream sounds, the
    /// reading ends with nothing after it, or `sessionHoldLimit` passes
    /// from when the last one drained.
    private var sessionHold: (@MainActor () -> Void)?
    private var sessionHoldTimeout: Task<Void, Never>?
    var sessionHoldLimit: Duration = .seconds(10)
    /// Now Playing kept through a held gap rather than ended with the
    /// reading: the next stream retitles it, a release ends it.
    private var nowPlayingKeptForNext = false
    /// The next queued message is being readied: another bot's gateway
    /// stops the controller, which mustn't let the hold go (issue 2148).
    private var carryingSessionHold = false

    init(
        playback: SpeechPlaybackService? = nil,
        gateway: VoiceGatewayService? = nil,
        playbackRate: @escaping @MainActor () -> Float = { ReadAloudSpeed.current().rate },
        storeSpeed: @escaping @MainActor (ReadAloudSpeed) -> Void = {
            UserDefaults.standard.set($0.rawValue, forKey: ReadAloudSpeed.preferenceKey)
        },
        beginBackgroundActivity: (@MainActor (@escaping @MainActor () -> Void) -> @MainActor () -> Void)? = nil,
        nowPlaying: ReadAloudNowPlayingPresenting? = nil,
        microphoneIsHeld: @escaping @MainActor () -> Bool = {
            let coordinator = VoiceAudioSessionCoordinator.shared
            return coordinator.hasCaptureOwner || coordinator.isInNativeCall
        },
        reportError: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.microphoneIsHeld = microphoneIsHeld
        self.playback = playback ?? AVSpeechPlaybackService()
        self.nowPlaying = nowPlaying ?? SystemReadAloudNowPlaying()
        self.activeGateway = gateway
        self.playbackRate = playbackRate
        self.storeSpeed = storeSpeed
        self.beginBackgroundActivity = beginBackgroundActivity ?? Self.beginApplicationBackgroundTask
        self.reportError = reportError
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            // Route notifications can arrive off the main thread.
            Task { @MainActor [weak self] in
                guard let reason else { return }
                self?.routeChanged(reason: reason)
            }
        }
    }

    deinit {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        playbackTask?.cancel()
        pausedStopTask?.cancel()
        sessionHoldTimeout?.cancel()
        let end = endBackgroundActivity
        let nowPlaying = nowPlaying
        let hold = sessionHold
        Task { @MainActor in
            end?()
            hold?()
            nowPlaying.end()
        }
    }

    private static func beginApplicationBackgroundTask(
        onExpiration: @escaping @MainActor () -> Void
    ) -> @MainActor () -> Void {
        var taskID = UIBackgroundTaskIdentifier.invalid
        let end: @MainActor () -> Void = {
            guard taskID != .invalid else { return }
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
        let expire: @MainActor () -> Void = {
            onExpiration()
            end()
        }
        taskID = UIApplication.shared.beginBackgroundTask(
            withName: "conduit.readAloud",
            expirationHandler: {
                // UIKit delivers this on the main thread in practice, but it
                // is not documented: hop rather than trap if it ever isn't.
                if Thread.isMainThread {
                    MainActor.assumeIsolated { expire() }
                } else {
                    DispatchQueue.main.async { expire() }
                }
            }
        )
        return end
    }

    var gateway: VoiceGatewayService? { activeGateway }

    /// TTS-only availability, independent of transcription. Kept as a pure
    /// function so the "no STT required" contract is testable in isolation.
    static func unavailableReason(
        isConnected: Bool,
        isVoiceEnabled: Bool,
        snapshot: VoiceCapabilitySnapshot,
        speechOutput: VoiceSpeechOutput = .hermes
    ) -> String? {
        if !isConnected { return AppLocalization.string("Connect to Hermes before reading responses aloud.") }
        if !isVoiceEnabled { return VoiceSetupIssue.voiceOff.message }
        // This iPhone's voice needs nothing from Hermes' speech setup.
        if speechOutput == .hermes, !snapshot.supportsSpeech {
            return VoiceSetupIssue.noTextToSpeech.message
        }
        return nil
    }

    func isActiveMessage(_ messageID: String) -> Bool {
        switch state {
        case .preparing(let id), .playing(let id): return id == messageID
        case .idle, .failed: return false
        }
    }

    /// Handles the read aloud action for one assistant message. Stops the
    /// playback if this message already owns it; otherwise takes over from
    /// whatever (if anything) is active. Whitespace-only content is a no-op
    /// so tapping an unreadable message never kills active playback.
    func toggle(messageID: String, content: String) {
        if isActiveMessage(messageID) {
            stop()
            return
        }
        // `MEDIA:` file tags are attachments, not words (#439); a Desktop
        // card is a short note (#1522).
        let readable = GatewayMediaTags.removingTags(from: TranscriptDirectives.readable(from: content))
        guard !readable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Starting is an on-screen action; a reply already playing is not
        // tied to the foreground and keeps going in the background.
        guard isForegroundActive else { return }
        stop()
        startPlayback(messageID: messageID, content: readable)
    }

    /// The id a reply read as it streams has until its row is in place.
    static func liveMessageID(sessionID: String) -> String { "live:\(sessionID)" }

    /// Read replies aloud in the open chat (notifier issue 674): follows
    /// its turn as Classic voice does, reading the words as they stream,
    /// commentary before a tool as its own segment, and a reply that
    /// arrives whole at its completion. `mayStart` is asked when a reply's
    /// first words arrive: it says whether reading may start now and
    /// readies the gateway. Stop (the button, the player, a call, a tap on
    /// another reply) ends the reading for the rest of that turn.
    func followReply(_ event: VoiceAssistantEvent, mayStart: @MainActor () -> Bool) {
        switch event {
        case .started(let sessionID):
            // A new turn: what the last one still has to say plays out, and
            // this one's first words take over from it.
            liveReply?.continuation?.finish()
            liveReply = LiveReply(sessionID: sessionID)
        case .delta(let sessionID, let text):
            guard var reply = liveReply, reply.sessionID == sessionID else { return }
            reply.receivedDelta = true
            let admitted = reply.admit(text)
            let spoken = reply.filter.feed(admitted)
            liveReply = reply
            speakLive(spoken, mayStart: mayStart)
        case .interim(let sessionID, let text, let alreadyStreamed):
            guard var reply = liveReply, reply.sessionID == sessionID else { return }
            // Commentary that streamed here is already said; one this
            // reading joined after is said from the interim's own text.
            let streamedHere = alreadyStreamed && reply.receivedDelta
            var spoken = ""
            if !streamedHere {
                let admitted = reply.admit(text)
                spoken = reply.filter.feed(admitted)
            }
            let held = reply.release()
            spoken += reply.filter.feed(held)
            spoken += reply.filter.finish()
            reply.filter.reset()
            // The next segment's opening words are checked again.
            reply.holding = true
            reply.receivedDelta = false
            reply.lastInterim = text.trimmingCharacters(in: .whitespacesAndNewlines)
            liveReply = reply
            speakLive(spoken, mayStart: mayStart)
            liveReply?.continuation?.yield(.boundary)
        case .completed(let sessionID, let content, let alreadyShown):
            guard var reply = liveReply, reply.sessionID == sessionID else { return }
            // The final snapshot is a recovery value: said only when no
            // words streamed, and never when it repeats the interim said.
            let repeatsInterim = alreadyShown
                && reply.lastInterim == content?.trimmingCharacters(in: .whitespacesAndNewlines)
            var spoken = ""
            if !repeatsInterim {
                if !reply.receivedDelta {
                    let admitted = reply.admit(content ?? "")
                    spoken = reply.filter.feed(admitted)
                }
                let held = reply.release()
                spoken += reply.filter.feed(held)
                spoken += reply.filter.finish()
            }
            liveReply = reply
            speakLive(spoken, mayStart: mayStart)
            liveReply?.continuation?.finish()
            liveReply = nil
        case .failed(let sessionID, _), .interrupted(let sessionID):
            guard let reply = liveReply, reply.sessionID == sessionID else { return }
            if reply.continuation != nil {
                // Stopped or failed: the reading ends with the turn.
                stop()
            } else {
                liveReply = nil
            }
        }
    }

    /// The open chat changed: the turn followed there won't send more, so
    /// what it said plays out and the reading ends.
    func stopFollowing(sessionIDBelongsToOpenChat: (String) -> Bool) {
        guard let reply = liveReply, !sessionIDBelongsToOpenChat(reply.sessionID) else { return }
        reply.continuation?.finish()
        liveReply = nil
    }

    /// The reply read as it streamed now has its row: the button under it
    /// shows Stop.
    func adoptLiveReply(sessionID: String, messageID: String) {
        let live = Self.liveMessageID(sessionID: sessionID)
        switch state {
        case .preparing(let id) where id == live: state = .preparing(messageID: messageID)
        case .playing(let id) where id == live: state = .playing(messageID: messageID)
        default: return
        }
        if let reading = nowReading, reading.messageID == live {
            nowReading = NowReading(messageID: messageID, title: reading.title)
        }
    }

    private func speakLive(_ text: String, mayStart: @MainActor () -> Bool) {
        guard let reply = liveReply else { return }
        if let continuation = reply.continuation {
            continuation.yield(.text(text))
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Off screen nothing starts, so the gateway isn't readied either.
        // Readying the gateway may stop whatever plays, which forgets the
        // turn; it is still the one to read.
        guard isForegroundActive, mayStart() else {
            liveReply = nil
            return
        }
        endOperation()
        let (items, continuation) = AsyncStream<LiveSpeech>.makeStream()
        var started = reply
        started.continuation = continuation
        liveReply = started
        continuation.yield(.text(text))
        startOperation(
            messageID: Self.liveMessageID(sessionID: reply.sessionID),
            title: ReadAloudNowPlaying.title(for: text),
            traceLabel: "a reply as it streams"
        ) { [weak self] generation in
            await self?.runLivePlayback(generation: generation, items: items)
        }
    }

    /// Read replies aloud in a group room: reads `content` once what plays
    /// now has finished, or at once when nothing does.
    func enqueue(messageID: String, content: String, prepare: @escaping @MainActor () -> Bool) {
        let readable = GatewayMediaTags.removingTags(from: TranscriptDirectives.readable(from: content))
        guard !readable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let reading = QueuedReading(messageID: messageID, content: readable, prepare: prepare)
        switch state {
        case .preparing, .playing:
            queue.append(reading)
        case .idle, .failed:
            guard isForegroundActive else { return }
            start(reading, rest: queue)
        }
    }

    private func startNextQueued() {
        guard !queue.isEmpty else {
            releaseSessionHold()
            return
        }
        // Only the message already playing carries on off screen.
        guard isForegroundActive else {
            queue = []
            releaseSessionHold()
            return
        }
        let next = queue.removeFirst()
        start(next, rest: queue)
    }

    private func start(_ reading: QueuedReading, rest: [QueuedReading]) {
        // Readying the gateway may stop (and clear the queue). A message
        // that may no longer be read (its room was left) is skipped; the
        // ones after it may still be.
        var reading = reading
        var remaining = rest
        carryingSessionHold = true
        while !reading.prepare() {
            guard !remaining.isEmpty else {
                carryingSessionHold = false
                queue = []
                releaseSessionHold()
                return
            }
            reading = remaining.removeFirst()
        }
        endOperation()
        carryingSessionHold = false
        queue = remaining.filter { $0.messageID != reading.messageID }
        startPlayback(messageID: reading.messageID, content: reading.content)
    }

    /// Cancels any active or in-flight read aloud operation and returns to
    /// idle, and reads nothing more on its own: the open chat's turn and a
    /// room's waiting messages are dropped. Safe to call repeatedly, and
    /// safe to call mid-operation: a superseded operation cannot observe
    /// this stop and resurrect playback.
    func stop() {
        LiveCallTrace.readAloud.note("Stopped")
        liveReply?.continuation?.finish()
        liveReply = nil
        queue = []
        endOperation()
    }

    private func endOperation() {
        operationGeneration &+= 1
        let task = playbackTask
        playbackTask = nil
        let stream = speechStream
        speechStream = nil
        task?.cancel()
        stream?.cancel()
        playback.stop()
        settle(.idle)
    }

    /// Now Playing pause: holds the playing reply in place. Only a reply
    /// that is already sounding can pause.
    @discardableResult
    func pause() -> Bool {
        guard case .playing = state else { return false }
        guard !isPaused else { return true }
        guard betweenSegments || playback.pause() else { return false }
        LiveCallTrace.readAloud.note("Paused")
        isPaused = true
        nowPlaying.setPaused(true)
        let delay = pausedStopDelay
        let generation = operationGeneration
        pausedStopTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            // Also when the service settled under the pause (a route change
            // whose engine wouldn't start): the reply can't sound again.
            guard !Task.isCancelled, let self,
                  self.isCurrent(generation), self.isPaused else { return }
            self.stop()
        }
        return true
    }

    @discardableResult
    func resume() -> Bool {
        guard case .playing = state else { return false }
        guard isPaused else { return true }
        if betweenSegments {
            isPaused = false
            pausedStopTask?.cancel()
            pausedStopTask = nil
            nowPlaying.setPaused(false)
            let waiter = segmentWaiter
            segmentWaiter = nil
            waiter?.resume()
            return true
        }
        // The service stopped underneath the pause (a phone call, a media
        // services reset): there is nothing left to resume, so settle the
        // reply instead of advertising playback that cannot sound.
        guard playback.isPaused else {
            stop()
            return false
        }
        playback.resume()
        LiveCallTrace.readAloud.note("Resumed")
        isPaused = false
        pausedStopTask?.cancel()
        pausedStopTask = nil
        nowPlaying.setPaused(false)
        return true
    }

    /// Headphones taken out (AirPods back in the case, a cable pulled) pause
    /// the reply rather than carrying on out loud from the speaker, as iOS
    /// media does; Resume picks it up on the new route. Any other route
    /// change plays on (#1641). Internal for tests.
    func routeChanged(reason: AVAudioSession.RouteChangeReason) {
        LiveCallTrace.readAloud.note("Route change (\(Self.traceName(of: reason))), now \(Self.traceRoute())")
        guard reason == .oldDeviceUnavailable else { return }
        if case .preparing = state {
            pauseWhenAudioStarts = operationGeneration
            return
        }
        pause()
    }

    @discardableResult
    func togglePause() -> Bool {
        isPaused ? resume() : pause()
    }

    /// The player's speed control (#759): retimes the reply already playing
    /// and becomes the Read Aloud speed setting for later replies.
    func setSpeed(_ speed: ReadAloudSpeed) {
        self.speed = speed
        storeSpeed(speed)
        switch state {
        case .preparing, .playing: playback.changeRate(speed.rate)
        case .idle, .failed: break
        }
    }

    /// The active stream belongs to the gateway that opened it. A replaced or
    /// cleared gateway (disconnect, profile change) invalidates the in-flight
    /// operation, so any replacement stops it.
    ///
    /// Pinned Option A semantics, deliberately different from
    /// `VoiceConversationController.setGateway`: a read aloud operation is one
    /// short single-message stream fully bound to its gateway, so a swap
    /// mid-operation is always an ownership change and stops playback here.
    /// The voice conversation instead survives same-server capability
    /// refreshes that install fresh equivalent instances, so its swap is
    /// future-operations-only and connection replacement stops it explicitly.
    func setGateway(_ gateway: VoiceGatewayService?) {
        guard activeGateway !== gateway else { return }
        activeGateway = gateway
        stop()
    }

    /// Records whether the app is on screen. Leaving the foreground (Home,
    /// lock, Control Center) never stops a reply that is already playing
    /// (#373); it only refuses new taps until the app is back.
    func setForegroundActive(_ active: Bool) {
        isForegroundActive = active
    }

    private func startPlayback(messageID: String, content: String) {
        startOperation(messageID: messageID, title: ReadAloudNowPlaying.title(for: content), traceLabel: "\(content.count) characters") { [weak self] generation in
            await self?.runPlayback(generation: generation, content: content)
        }
    }

    private func startOperation(
        messageID: String,
        title: String,
        traceLabel: String,
        run: @escaping @MainActor (UInt64) async -> Void
    ) {
        operationGeneration &+= 1
        let generation = operationGeneration
        state = .preparing(messageID: messageID)
        nowPlayingTitle = title
        speed = ReadAloudSpeed.closest(to: playbackRate())
        LiveCallTrace.readAloud.begin("Read Aloud", first: "Reading \(traceLabel) at \(String(format: "%gx", speed.rawValue)), on \(Self.traceRoute())")
        nowReading = NowReading(messageID: messageID, title: nowPlayingTitle)
        endBackgroundActivity = beginBackgroundActivity { [weak self] in
            // Time ran out before any audio: the app is about to suspend
            // with the stream still opening. Fail closed rather than leave
            // the reply spinning when the app comes back.
            guard let self, self.isCurrent(generation),
                  case .preparing = self.state else { return }
            self.stop()
        }
        playbackTask = Task {
            await run(generation)
        }
    }

    private func runPlayback(generation: UInt64, content: String) async {
        defer { if operationGeneration == generation { playbackTask = nil } }
        guard let gateway = activeGateway else {
            fail(message: AppLocalization.string("Read aloud needs a connection to Hermes. Wait for Conduit to reconnect, then try again."), generation: generation)
            return
        }
        do {
            preparePlayback(generation: generation)
            let stream = try await openStream(gateway: gateway, generation: generation)
            // The open can outlive a stop(): if this operation was superseded
            // while the stream was being created, drop the stream immediately
            // instead of adopting it into the newer operation's state.
            guard isCurrent(generation) else {
                stream.cancel()
                return
            }
            speechStream = stream
            LiveCallTrace.readAloud.note("Speaking with \(Self.traceEngine(of: stream))")
            // A reply that is all action or emoji is read as written rather
            // than not at all.
            let spoken = SpokenTextFilter.filter(content)
            try await stream.append(spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? content : spoken)
            guard isCurrent(generation) else { return }
            _ = try await stream.finish()
            guard isCurrent(generation) else { return }
            speechStream = nil
            // Held through the drain, as a room's next message may arrive
            // while this one still sounds; `settle` lets it go when nothing
            // waits by then.
            holdSessionForNext()
            try playback.finish()
            await playback.drain()
            guard isCurrent(generation) else { return }
            settle(.idle)
            startNextQueued()
        } catch {
            // A superseded operation must not touch shared state: the stream
            // reference may now belong to a newer operation, and only that
            // operation's stop() may release it.
            guard isCurrent(generation) else { return }
            let stream = speechStream
            speechStream = nil
            stream?.cancel()
            if isCancellation(error) {
                LiveCallTrace.readAloud.note("Speech ended early (cancelled)")
                // The stream died on its own (or was stopped); settle back to
                // idle so the message is tappable again.
                playback.stop()
                settle(.idle)
                startNextQueued()
                return
            }
            // The stream can die after audio is already sounding; settle the
            // engine so no unattributed audio keeps playing under .failed.
            playback.stop()
            fail(message: UserFacingError.message(for: error), generation: generation)
        }
    }

    private func preparePlayback(generation: UInt64) {
        // Pin output-only ownership per operation rather than inheriting
        // whatever intent a shared playback instance last claimed.
        playback.ownershipIntent = .standalonePlayback
        // Dictation, a voice message or a call taking the microphone
        // ends the reading, so the microphone never hears it and two
        // voices never play at once (issue 1770).
        playback.onTakenOverByCapture = { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            self.stop()
        }
        playback.keepsRateAdjustable = true
        // The player shows one of the Read Aloud speeds, so the reply
        // plays at exactly that one.
        playback.playbackRate = ReadAloudSpeed.closest(to: playbackRate()).rate
    }

    private func openStream(gateway: VoiceGatewayService, generation: UInt64) async throws -> VoiceSpeechStream {
        try await gateway.openSpeechStream(
            onStart: { [weak self] sampleRate in
                guard let self, self.isCurrent(generation) else { return }
                try self.yieldToHeldMicrophone()
                try self.playback.start(sampleRate: sampleRate)
                self.transitionToPlaying(generation: generation)
            },
            onPCM16: { [weak self] data, sampleRate in
                guard let self, self.isCurrent(generation) else { return }
                try self.yieldToHeldMicrophone()
                _ = try self.playback.enqueuePCM16(data, sampleRate: sampleRate)
                self.transitionToPlaying(generation: generation)
            },
            onEncodedAudio: { [weak self] data in
                guard let self, self.isCurrent(generation) else { return }
                try self.yieldToHeldMicrophone()
                try self.playback.playEncodedAudioData(data)
                self.transitionToPlaying(generation: generation)
            }
        )
    }

    /// A reply read as it streams: each segment its own speech stream, as
    /// Classic voice speaks one, until the turn completes.
    private func runLivePlayback(generation: UInt64, items: AsyncStream<LiveSpeech>) async {
        defer { if operationGeneration == generation { playbackTask = nil } }
        guard let gateway = activeGateway else {
            fail(message: AppLocalization.string("Read aloud needs a connection to Hermes. Wait for Conduit to reconnect, then try again."), generation: generation)
            return
        }
        preparePlayback(generation: generation)
        var open: VoiceSpeechStream?
        do {
            for await item in items {
                guard isCurrent(generation) else { return }
                switch item {
                case .text(let text):
                    if open == nil {
                        // Nothing to say opens no stream (an empty or
                        // silent answer after a tool), and a paused reply
                        // isn't held for it.
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        // Paused while a tool ran: the next segment waits.
                        if isPaused, betweenSegments {
                            await withCheckedContinuation { segmentWaiter = $0 }
                            guard isCurrent(generation) else { return }
                        }
                        betweenSegments = false
                        let stream = try await openStream(gateway: gateway, generation: generation)
                        guard isCurrent(generation) else {
                            stream.cancel()
                            return
                        }
                        speechStream = stream
                        LiveCallTrace.readAloud.note("Speaking with \(Self.traceEngine(of: stream))")
                        open = stream
                    }
                    try await open?.append(text)
                case .boundary:
                    guard let stream = open else { continue }
                    _ = try await stream.finish()
                    guard isCurrent(generation) else { return }
                    speechStream = nil
                    open = nil
                    // A tool runs; the turn's next segment opens its own
                    // stream, and the session stays up into it.
                    holdSessionForNext()
                    try playback.finish()
                    await playback.drain()
                    guard isCurrent(generation) else { return }
                    armSessionHoldLimit()
                    betweenSegments = true
                }
                guard isCurrent(generation) else { return }
            }
            guard isCurrent(generation) else { return }
            if let stream = open {
                _ = try await stream.finish()
                guard isCurrent(generation) else { return }
                speechStream = nil
                // A room message may be waiting behind the reply, or
                // arrive as it drains.
                holdSessionForNext()
                try playback.finish()
                await playback.drain()
                guard isCurrent(generation) else { return }
            }
            settle(.idle)
            startNextQueued()
        } catch {
            guard isCurrent(generation) else { return }
            let stream = speechStream
            speechStream = nil
            stream?.cancel()
            playback.stop()
            // The turn may still be streaming: nothing more of it is read.
            liveReply?.continuation?.finish()
            liveReply = nil
            if isCancellation(error) {
                settle(.idle)
                startNextQueued()
                return
            }
            fail(message: UserFacingError.message(for: error), generation: generation)
        }
    }

    private func transitionToPlaying(generation: UInt64) {
        guard isCurrent(generation) else { return }
        if case .preparing = state { LiveCallTrace.readAloud.note("First audio") }
        // The stream sounding holds the session itself now; Now Playing,
        // kept through the gap, is retitled below.
        releaseSessionHold(endingNowPlaying: false)
        // Safety net: the playback service holds a pause across a stream
        // restart, but if anything ever leaves the reply sounding, stop
        // reporting it paused so the paused-stop timer cannot end it.
        if isPaused, !playback.isPaused {
            isPaused = false
            pausedStopTask?.cancel()
            pausedStopTask = nil
            nowPlaying.setPaused(false)
        }
        // The operation's own id, which a reply read as it streams changes
        // once its row is in place.
        if case .preparing(let messageID) = state {
            state = .playing(messageID: messageID)
            nowPlaying.begin(title: nowPlayingTitle, commands: ReadAloudRemoteCommands(
                pause: { [weak self] in self?.pause() ?? false },
                resume: { [weak self] in self?.resume() ?? false },
                togglePause: { [weak self] in self?.togglePause() ?? false },
                stop: { [weak self] in
                    guard let self, self.state != .idle else { return false }
                    self.stop()
                    return true
                }
            ))
            if pauseWhenAudioStarts == generation {
                pauseWhenAudioStarts = nil
                pause()
            }
        }
    }

    /// Audio that would reach a held microphone ends the reading instead:
    /// one that opened as dictation started (issue 1770). A cancellation,
    /// so the gateway never takes it for a Hermes speech failure and falls
    /// back to the iPhone's voice.
    private func yieldToHeldMicrophone() throws {
        guard microphoneIsHeld() else { return }
        stop()
        throw CancellationError()
    }

    private func fail(message: String, generation: UInt64) {
        guard isCurrent(generation) else { return }
        let messageID: String
        switch state {
        case .preparing(let id), .playing(let id), .failed(let id, _): messageID = id
        case .idle: messageID = nowReading?.messageID ?? ""
        }
        // Nothing more is read on its own after a failure.
        liveReply?.continuation?.finish()
        liveReply = nil
        queue = []
        settle(.failed(messageID: messageID, message: message))
        reportError(message)
    }

    /// Ends the operation: the background activity it held is released with
    /// the state change, on every terminal path.
    private func settle(_ terminal: State) {
        if case .failed = terminal {
            LiveCallTrace.readAloud.end("Ended with an error")
        } else {
            LiveCallTrace.readAloud.end("Ended")
        }
        // Nothing waits to be read: the session goes as the reading did.
        // Readying the next one may stop the controller, which keeps it.
        if queue.isEmpty, !carryingSessionHold { releaseSessionHold() }
        state = terminal
        isPaused = false
        betweenSegments = false
        let waiter = segmentWaiter
        segmentWaiter = nil
        waiter?.resume()
        nowReading = nil
        pausedStopTask?.cancel()
        pausedStopTask = nil
        if sessionHold != nil, terminal == .idle {
            // Held into the next message: Now Playing stays on the lock
            // screen, and the limit runs from here, once this one drained.
            nowPlayingKeptForNext = true
            armSessionHoldLimit()
        } else {
            nowPlayingKeptForNext = false
            nowPlaying.end()
        }
        let end = endBackgroundActivity
        endBackgroundActivity = nil
        end?()
    }

    /// Takes the hold before the stream drains, so the session never
    /// drops; its limit starts once it has (`armSessionHoldLimit`), as
    /// speech still queued can outlast it.
    private func holdSessionForNext() {
        guard sessionHold == nil,
              let release = playback.holdSession(onTakenOver: { [weak self] in self?.stop() }) else { return }
        sessionHold = release
    }

    private func armSessionHoldLimit() {
        guard sessionHold != nil else { return }
        sessionHoldTimeout?.cancel()
        sessionHoldTimeout = Task { [weak self] in
            guard let limit = self?.sessionHoldLimit else { return }
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            self?.releaseSessionHold()
        }
    }

    private func releaseSessionHold(endingNowPlaying: Bool = true) {
        sessionHoldTimeout?.cancel()
        sessionHoldTimeout = nil
        let release = sessionHold
        sessionHold = nil
        release?()
        if nowPlayingKeptForNext {
            nowPlayingKeptForNext = false
            if endingNowPlaying { nowPlaying.end() }
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    /// Read Aloud's trace (issue 1641): which engine speaks, by its kind.
    static func traceEngine(of stream: VoiceSpeechStream) -> String {
        switch stream {
        case is OnDeviceSpeechStream: "the iPhone voice"
        case is HermesSpeechStream: "Hermes speech"
        case is SpeechServerSpeechStream: "the speech server"
        case let fallback as FallbackSpeechStream: "\(fallback.primaryName), the iPhone voice if it fails first"
        default: String(describing: type(of: stream))
        }
    }

    /// The outputs playing now, by kind ("Speaker", "BluetoothA2DPOutput").
    private static func traceRoute() -> String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue)
        return outputs.isEmpty ? "no output" : outputs.joined(separator: " + ")
    }

    private static func traceName(of reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .newDeviceAvailable: "new device"
        case .oldDeviceUnavailable: "device gone"
        case .categoryChange: "category change"
        case .override: "override"
        case .wakeFromSleep: "wake from sleep"
        case .noSuitableRouteForCategory: "no suitable route"
        case .routeConfigurationChange: "configuration change"
        default: "reason \(reason.rawValue)"
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == operationGeneration
    }
}
