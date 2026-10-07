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

    private let playback: SpeechPlaybackService
    private let reportError: @MainActor (String) -> Void
    /// Read Aloud speed, read when each playback starts so a change in
    /// Settings applies from the next tap.
    private let playbackRate: @MainActor () -> Float
    private var activeGateway: VoiceGatewayService?
    private var speechStream: VoiceSpeechStream?
    private var playbackTask: Task<Void, Never>?
    private var operationGeneration: UInt64 = 0
    private var isForegroundActive = true
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

    init(
        playback: SpeechPlaybackService? = nil,
        gateway: VoiceGatewayService? = nil,
        playbackRate: @escaping @MainActor () -> Float = { ReadAloudSpeed.current().rate },
        beginBackgroundActivity: (@MainActor (@escaping @MainActor () -> Void) -> @MainActor () -> Void)? = nil,
        nowPlaying: ReadAloudNowPlayingPresenting? = nil,
        reportError: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.playback = playback ?? AVSpeechPlaybackService()
        self.nowPlaying = nowPlaying ?? SystemReadAloudNowPlaying()
        self.activeGateway = gateway
        self.playbackRate = playbackRate
        self.beginBackgroundActivity = beginBackgroundActivity ?? Self.beginApplicationBackgroundTask
        self.reportError = reportError
    }

    deinit {
        playbackTask?.cancel()
        pausedStopTask?.cancel()
        let end = endBackgroundActivity
        let nowPlaying = nowPlaying
        Task { @MainActor in
            end?()
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
        snapshot: VoiceCapabilitySnapshot
    ) -> String? {
        if !isConnected { return AppLocalization.string("Connect to Hermes before reading responses aloud.") }
        if !isVoiceEnabled { return VoiceSetupIssue.voiceOff.message }
        if !snapshot.supportsSpeech {
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
        // `MEDIA:` file tags are attachments, not words (#439).
        let readable = GatewayMediaTags.removingTags(from: content)
        guard !readable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Starting is an on-screen action; a reply already playing is not
        // tied to the foreground and keeps going in the background.
        guard isForegroundActive else { return }
        stop()
        startPlayback(messageID: messageID, content: readable)
    }

    /// Cancels any active or in-flight read aloud operation and returns to
    /// idle. Safe to call repeatedly, and safe to call mid-operation: a
    /// superseded operation cannot observe this stop and resurrect playback.
    func stop() {
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
        guard playback.pause() else { return false }
        isPaused = true
        nowPlaying.setPaused(true)
        let delay = pausedStopDelay
        let generation = operationGeneration
        pausedStopTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self,
                  self.isCurrent(generation), self.isPaused,
                  self.playback.isPaused else { return }
            self.stop()
        }
        return true
    }

    @discardableResult
    func resume() -> Bool {
        guard case .playing = state else { return false }
        guard isPaused else { return true }
        // The service stopped underneath the pause (a phone call, a media
        // services reset): there is nothing left to resume, so settle the
        // reply instead of advertising playback that cannot sound.
        guard playback.isPaused else {
            stop()
            return false
        }
        playback.resume()
        isPaused = false
        pausedStopTask?.cancel()
        pausedStopTask = nil
        nowPlaying.setPaused(false)
        return true
    }

    @discardableResult
    func togglePause() -> Bool {
        isPaused ? resume() : pause()
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
        operationGeneration &+= 1
        let generation = operationGeneration
        state = .preparing(messageID: messageID)
        nowPlayingTitle = ReadAloudNowPlaying.title(for: content)
        endBackgroundActivity = beginBackgroundActivity { [weak self] in
            // Time ran out before any audio: the app is about to suspend
            // with the stream still opening. Fail closed rather than leave
            // the reply spinning when the app comes back.
            guard let self, self.isCurrent(generation),
                  case .preparing = self.state else { return }
            self.stop()
        }
        playbackTask = Task { [weak self] in
            await self?.runPlayback(generation: generation, messageID: messageID, content: content)
        }
    }

    private func runPlayback(generation: UInt64, messageID: String, content: String) async {
        defer { if operationGeneration == generation { playbackTask = nil } }
        guard let gateway = activeGateway else {
            fail(messageID: messageID, message: AppLocalization.string("Read aloud needs a connection to Hermes. Wait for Conduit to reconnect, then try again."), generation: generation)
            return
        }
        do {
            // Pin output-only ownership per operation rather than inheriting
            // whatever intent a shared playback instance last claimed.
            playback.ownershipIntent = .standalonePlayback
            playback.playbackRate = playbackRate()
            let stream = try await gateway.openSpeechStream(
                onStart: { [weak self] sampleRate in
                    guard let self, self.isCurrent(generation) else { return }
                    try self.playback.start(sampleRate: sampleRate)
                    self.transitionToPlaying(messageID: messageID, generation: generation)
                },
                onPCM16: { [weak self] data, sampleRate in
                    guard let self, self.isCurrent(generation) else { return }
                    _ = try self.playback.enqueuePCM16(data, sampleRate: sampleRate)
                    self.transitionToPlaying(messageID: messageID, generation: generation)
                },
                onEncodedAudio: { [weak self] data in
                    guard let self, self.isCurrent(generation) else { return }
                    try self.playback.playEncodedAudioData(data)
                    self.transitionToPlaying(messageID: messageID, generation: generation)
                }
            )
            // The open can outlive a stop(): if this operation was superseded
            // while the stream was being created, drop the stream immediately
            // instead of adopting it into the newer operation's state.
            guard isCurrent(generation) else {
                stream.cancel()
                return
            }
            speechStream = stream
            // A reply that is all action or emoji is read as written rather
            // than not at all.
            let spoken = SpokenTextFilter.filter(content)
            try await stream.append(spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? content : spoken)
            guard isCurrent(generation) else { return }
            _ = try await stream.finish()
            guard isCurrent(generation) else { return }
            speechStream = nil
            try playback.finish()
            await playback.drain()
            guard isCurrent(generation) else { return }
            settle(.idle)
        } catch {
            // A superseded operation must not touch shared state: the stream
            // reference may now belong to a newer operation, and only that
            // operation's stop() may release it.
            guard isCurrent(generation) else { return }
            let stream = speechStream
            speechStream = nil
            stream?.cancel()
            if isCancellation(error) {
                // The stream died on its own (or was stopped); settle back to
                // idle so the message is tappable again.
                playback.stop()
                settle(.idle)
                return
            }
            // The stream can die after audio is already sounding; settle the
            // engine so no unattributed audio keeps playing under .failed.
            playback.stop()
            fail(messageID: messageID, message: UserFacingError.message(for: error), generation: generation)
        }
    }

    private func transitionToPlaying(messageID: String, generation: UInt64) {
        guard isCurrent(generation) else { return }
        // Safety net: the playback service holds a pause across a stream
        // restart, but if anything ever leaves the reply sounding, stop
        // reporting it paused so the paused-stop timer cannot end it.
        if isPaused, !playback.isPaused {
            isPaused = false
            pausedStopTask?.cancel()
            pausedStopTask = nil
            nowPlaying.setPaused(false)
        }
        if case .preparing(let id) = state, id == messageID {
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
        }
    }

    private func fail(messageID: String, message: String, generation: UInt64) {
        guard isCurrent(generation) else { return }
        settle(.failed(messageID: messageID, message: message))
        reportError(message)
    }

    /// Ends the operation: the background activity it held is released with
    /// the state change, on every terminal path.
    private func settle(_ terminal: State) {
        state = terminal
        isPaused = false
        pausedStopTask?.cancel()
        pausedStopTask = nil
        nowPlaying.end()
        let end = endBackgroundActivity
        endBackgroundActivity = nil
        end?()
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == operationGeneration
    }
}
