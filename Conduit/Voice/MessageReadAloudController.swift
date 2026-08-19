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

import Combine
import Foundation

@MainActor
final class MessageReadAloudController: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing(messageID: String)
        case playing(messageID: String)
        case failed(messageID: String, message: String)
    }

    @Published private(set) var state: State = .idle

    private let playback: SpeechPlaybackService
    private let reportError: @MainActor (String) -> Void
    private var activeGateway: VoiceGatewayService?
    private var speechStream: VoiceSpeechStream?
    private var playbackTask: Task<Void, Never>?
    private var operationGeneration: UInt64 = 0
    private var isForegroundActive = true

    init(
        playback: SpeechPlaybackService? = nil,
        gateway: VoiceGatewayService? = nil,
        reportError: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.playback = playback ?? AVSpeechPlaybackService()
        self.activeGateway = gateway
        self.reportError = reportError
    }

    deinit { playbackTask?.cancel() }

    var gateway: VoiceGatewayService? { activeGateway }

    /// TTS-only availability, independent of transcription. Kept as a pure
    /// function so the "no STT required" contract is testable in isolation.
    static func unavailableReason(
        isConnected: Bool,
        isVoiceEnabled: Bool,
        snapshot: VoiceCapabilitySnapshot
    ) -> String? {
        if !isConnected { return "Connect to Hermes before reading responses aloud." }
        if !isVoiceEnabled { return "Enable voice for this profile in Settings." }
        if !snapshot.supportsSpeech {
            return "This Hermes profile has no ready text-to-speech provider."
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
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard isForegroundActive else { return }
        stop()
        startPlayback(messageID: messageID, content: content)
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
        state = .idle
    }

    /// The active stream belongs to the gateway that opened it. A replaced or
    /// cleared gateway (disconnect, profile change) invalidates the in-flight
    /// operation, so any replacement stops it.
    func setGateway(_ gateway: VoiceGatewayService?) {
        guard activeGateway !== gateway else { return }
        activeGateway = gateway
        stop()
    }

    func setForegroundActive(_ active: Bool) {
        isForegroundActive = active
        guard !active else { return }
        stop()
    }

    private func startPlayback(messageID: String, content: String) {
        operationGeneration &+= 1
        let generation = operationGeneration
        state = .preparing(messageID: messageID)
        playbackTask = Task { [weak self] in
            await self?.runPlayback(generation: generation, messageID: messageID, content: content)
        }
    }

    private func runPlayback(generation: UInt64, messageID: String, content: String) async {
        defer { if operationGeneration == generation { playbackTask = nil } }
        guard let gateway = activeGateway else {
            fail(messageID: messageID, message: "Read aloud needs a connected Hermes gateway.", generation: generation)
            return
        }
        do {
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
            try await stream.append(content)
            guard isCurrent(generation) else { return }
            _ = try await stream.finish()
            guard isCurrent(generation) else { return }
            speechStream = nil
            try playback.finish()
            await playback.drain()
            guard isCurrent(generation) else { return }
            state = .idle
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
                state = .idle
                return
            }
            // The stream can die after audio is already sounding; settle the
            // engine so no unattributed audio keeps playing under .failed.
            playback.stop()
            fail(messageID: messageID, message: error.localizedDescription, generation: generation)
        }
    }

    private func transitionToPlaying(messageID: String, generation: UInt64) {
        guard isCurrent(generation) else { return }
        if case .preparing(let id) = state, id == messageID {
            state = .playing(messageID: messageID)
        }
    }

    private func fail(messageID: String, message: String, generation: UInt64) {
        guard isCurrent(generation) else { return }
        state = .failed(messageID: messageID, message: message)
        reportError(message)
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == operationGeneration && isForegroundActive
    }
}
