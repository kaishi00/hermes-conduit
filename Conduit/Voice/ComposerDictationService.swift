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

    /// The whole transcript of this dictation so far, each time it changes.
    var onTranscript: ((String) -> Void)?
    /// Called once the dictation is over, with whether it produced text.
    var onFinish: ((Bool) -> Void)?

    private let audioCoordinator: VoiceAudioSessionCoordinator
    private let audioSink = DictationAudioSink()
    private var engine: AVAudioEngine?
    private var lease: VoiceAudioLease?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var finishTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var producedText = false

    init(audioCoordinator: VoiceAudioSessionCoordinator? = nil) {
        self.audioCoordinator = audioCoordinator ?? .shared
    }

    /// Starts listening. Throws a message for the user when it can't.
    func start() async throws {
        guard !isDictating else { return }
        guard await AppleSpeechWakeWordService.requestPermissions() else {
            throw DictationError.message(AppLocalization.string("Dictation needs microphone and speech recognition access. You can allow them in Settings."))
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
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
            lease = try audioCoordinator.acquire(.conversationCapture)
            try startAudio()
        } catch {
            releaseAudio()
            throw DictationError.message(AppLocalization.string("The microphone is not available right now."))
        }
        audioSink.replace(with: request)
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
    /// last words, briefly.
    func stop() {
        guard isDictating else { return }
        stopAudio()
        audioSink.replace(with: nil)
        let generation = generation
        finishTask?.cancel()
        finishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.finish()
        }
    }

    /// Ends it now (the composer went away or was disabled).
    func cancel() {
        guard isDictating else { return }
        finish()
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
        isDictating = false
        onFinish?(producedText)
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
