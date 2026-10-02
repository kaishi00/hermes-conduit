//
//  ComposerDictationService.swift
//  Conduit
//
//  Hold the composer's mic to dictate (issue #290). Apple's speech
//  recognizer turns the hold into text in the draft; nothing is sent. It
//  runs on the device when the language supports it. The microphone is
//  taken through the shared audio coordinator, so wake listening steps
//  aside while it runs.
//

import AVFAudio
import Foundation
import os
import Speech

@MainActor
final class ComposerDictationService: ObservableObject {
    @Published private(set) var isDictating = false
    /// Permission or the microphone is still coming up.
    @Published private(set) var isStarting = false
    /// The microphone is open. A dictation still settling its last words
    /// after the release is dictating but no longer capturing.
    @Published private(set) var isCapturing = false

    /// The whole transcript of this dictation so far, each time it changes.
    /// Cleared when the dictation ends: the view that set it is captured.
    var onTranscript: ((String) -> Void)?
    /// Called once the dictation is over, with whether it produced text,
    /// then cleared.
    var onFinish: ((Bool) -> Void)?

    private let audioCoordinator: VoiceAudioSessionCoordinator
    private let audioSink = DictationAudioSink()
    private var engine: AVAudioEngine?
    private var lease: VoiceAudioLease?
    /// Interruption, media-reset and engine-configuration observers while
    /// the microphone is open.
    private var audioObservers: [NSObjectProtocol] = []
    private var recognitionTask: SFSpeechRecognitionTask?
    private var finishTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var producedText = false
    /// Bumped by `cancel()` so a reserved start that hasn't run, or is
    /// still awaiting permission, gives up.
    private var startToken: UInt64 = 0

    init(audioCoordinator: VoiceAudioSessionCoordinator? = nil) {
        self.audioCoordinator = audioCoordinator ?? .shared
    }

    /// Reserves a start, synchronously: a `cancel()` that lands before
    /// `start(token:)` runs still stops it. A dictation still settling its
    /// last words ends here, so its results never reach the new one.
    /// Returns nil while one is starting or capturing.
    func reserveStart() -> UInt64? {
        guard !isStarting, !isCapturing else { return nil }
        if isDictating { finish() }
        startToken &+= 1
        isStarting = true
        return startToken
    }

    /// Starts listening for the start `reserveStart()` returned. Throws a
    /// message for the user when it can't.
    func start(token: UInt64) async throws {
        guard startToken == token, !isDictating else { return }
        defer { if startToken == token { isStarting = false } }
        let allowed = await AppleSpeechWakeWordService.requestPermissions()
        // Cancelled (the composer went away) while permission was asked;
        // cancel() already cleared the callbacks.
        guard startToken == token else { return }
        guard allowed else {
            clearCallbacks()
            throw DictationError.message(AppLocalization.string("Dictation needs microphone and speech recognition access. You can allow them in Settings."))
        }
        // A voice conversation already has the microphone (one the
        // composer hasn't re-rendered for yet).
        guard !audioCoordinator.hasCaptureOwner else {
            clearCallbacks()
            throw DictationError.message(AppLocalization.string("The microphone is not available right now."))
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            clearCallbacks()
            throw DictationError.message(AppLocalization.string("Dictation isn't available right now."))
        }
        generation &+= 1
        let generation = generation
        producedText = false
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        // On the device when the language allows it.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        do {
            // Voice or a live call taking the microphone ends dictation.
            lease = try audioCoordinator.acquire(.conversationCapture) { [weak self] in
                self?.audioWasLost(generation: generation)
            }
            try startAudio()
            observeAudioLoss(generation: generation)
        } catch {
            releaseAudio()
            clearCallbacks()
            throw DictationError.message(AppLocalization.string("The microphone is not available right now."))
        }
        audioSink.replace(with: request)
        isCapturing = true
        isDictating = true
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = (result?.isFinal ?? false) || error != nil
            Task { @MainActor [weak self] in
                self?.receive(transcript: transcript, isFinal: isFinal, generation: generation)
            }
        }
    }

    /// The finger lifted: stop listening and let the recognizer settle its
    /// last words, briefly. The microphone is let go at once.
    func stop() {
        guard isCapturing else { return }
        isCapturing = false
        stopAudio()
        releaseAudio()
        audioSink.replace(with: nil)
        let generation = generation
        finishTask?.cancel()
        finishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.finish()
        }
    }

    /// Ends it now (the composer went away or was disabled), including a
    /// start still waiting on permission.
    func cancel() {
        startToken &+= 1
        isStarting = false
        if isDictating {
            finish()
        } else {
            clearCallbacks()
        }
    }

    /// The microphone went away underneath dictation: a call, Siri, a route
    /// change, a media-services reset, or a voice conversation taking it.
    /// Ends it with the words so far.
    private func audioWasLost(generation: UInt64) {
        guard isDictating, generation == self.generation else { return }
        finish()
    }

    private func observeAudioLoss(generation: UInt64) {
        let center = NotificationCenter.default
        let lost: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in self?.audioWasLost(generation: generation) }
        }
        audioObservers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                    .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                if type == .began { lost(note) }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil, using: lost),
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil, using: lost),
        ]
    }

    private func receive(transcript: String?, isFinal: Bool, generation: UInt64) {
        guard isDictating, generation == self.generation else { return }
        if let transcript, !transcript.isEmpty {
            producedText = true
            onTranscript?(transcript)
        }
        // A final result after the release ends it; one while still
        // holding (a recognizer error) does too.
        if isFinal { finish() }
    }

    private func finish() {
        generation &+= 1
        finishTask?.cancel()
        finishTask = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        audioSink.replace(with: nil)
        stopAudio()
        releaseAudio()
        isCapturing = false
        isDictating = false
        let onFinish = onFinish
        clearCallbacks()
        onFinish?(producedText)
    }

    private func clearCallbacks() {
        onTranscript = nil
        onFinish = nil
    }

    private func startAudio() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DictationError.message(AppLocalization.string("The microphone is not available right now."))
        }
        let sink = audioSink
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            sink.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            throw error
        }
        self.engine = engine
    }

    private func stopAudio() {
        for observer in audioObservers { NotificationCenter.default.removeObserver(observer) }
        audioObservers = []
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func releaseAudio() {
        if let lease {
            self.lease = nil
            audioCoordinator.release(lease)
        }
    }

    enum DictationError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            }
        }
    }
}

/// Where dictated text goes in the draft: after what was there when the
/// hold began, replacing only what this dictation wrote.
enum ComposerDictation {
    /// How long the mic is held before it dictates instead of opening Voice.
    static let holdDuration: Double = 0.35
    /// Set once a dictation has produced text: the tip has done its job.
    static let tipDoneKey = "conduit.composerDictationTipDone"

    static func draft(before prefix: String, dictated: String) -> String {
        let dictated = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dictated.isEmpty else { return prefix }
        guard let last = prefix.last else { return dictated }
        return last.isWhitespace ? prefix + dictated : prefix + " " + dictated
    }
}

/// Hands microphone buffers from the render thread to the current request.
private final class DictationAudioSink: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<SFSpeechAudioBufferRecognitionRequest?>(uncheckedState: nil)

    func replace(with newRequest: SFSpeechAudioBufferRecognitionRequest?) {
        state.withLockUnchecked { request in
            request?.endAudio()
            request = newRequest
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        state.withLockUnchecked { request in
            request?.append(buffer)
        }
    }
}
