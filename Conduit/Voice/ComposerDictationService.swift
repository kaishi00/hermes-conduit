//
//  ComposerDictationService.swift
//  Conduit
//
//  The composer's dictate button (issues #290, #335). Apple's speech
//  recognizer turns what is said into text in the draft; nothing is sent. It
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
    private var transcript = DictationTranscript()
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
        guard let recognizer = SFSpeechRecognizer(locale: SpeechRecognitionLocale.preferred()) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            clearCallbacks()
            throw DictationError.message(AppLocalization.string("Dictation isn't available right now."))
        }
        generation &+= 1
        let generation = generation
        producedText = false
        transcript = DictationTranscript()
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
            // Set on the result that closes an utterance (a pause); the
            // recognizer may start the next one from empty.
            let endsUtterance = result?.speechRecognitionMetadata != nil
            let isFinal = (result?.isFinal ?? false) || error != nil
            Task { @MainActor [weak self] in
                self?.receive(transcript: transcript, endsUtterance: endsUtterance, isFinal: isFinal, generation: generation)
            }
        }
    }

    /// Tapped again: stop listening and let the recognizer settle its
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

    private func receive(transcript text: String?, endsUtterance: Bool, isFinal: Bool, generation: UInt64) {
        guard isDictating, generation == self.generation else { return }
        if let text, !text.isEmpty {
            transcript.receive(text, endsUtterance: endsUtterance)
            producedText = true
            onTranscript?(transcript.text)
        }
        // A final result after the stop ends it; one while still
        // listening (a recognizer error) does too.
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

/// Where dictated text goes in the draft: after what was there when
/// dictation began, replacing only what this dictation wrote.
enum ComposerDictation {
    /// What a tap on the composer's dictate button does (#335).
    enum Tap: Equatable {
        case start
        /// Listening: stop, keeping the words.
        case stop
        /// Still coming up (permission, microphone): call it off.
        case cancelStart
        case nothing
    }

    static func tap(isCapturing: Bool, isStarting: Bool, canDictate: Bool) -> Tap {
        if isCapturing { return .stop }
        if isStarting { return .cancelStart }
        return canDictate ? .start : .nothing
    }

    /// Whether a change the full editor reported counts as typing: any
    /// change but the draft dictation itself last wrote, programmatic
    /// replacements included (dictation would write over those too).
    static func isTyping(_ text: String, dictationWrote dictated: String?) -> Bool {
        text != dictated
    }

    /// Whether the draft is still what dictation last wrote, or what it
    /// began from before its first words. Anything else changed since, and
    /// a new result must not write over it.
    static func draftIsAsDictationLeftIt(_ text: String, prefix: String, lastWrite: String?) -> Bool {
        text == (lastWrite ?? prefix)
    }

    static func draft(before prefix: String, dictated: String) -> String {
        let dictated = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dictated.isEmpty else { return prefix }
        guard let last = prefix.last else { return dictated }
        return last.isWhitespace ? prefix + dictated : prefix + " " + dictated
    }
}

/// The whole of one dictation. After a pause the recognizer can start its
/// next utterance from empty, so each result is either the current
/// utterance growing or a new one; the finished ones are kept (#333).
struct DictationTranscript: Equatable {
    /// Utterances the recognizer has moved past.
    private(set) var committed = ""
    /// The utterance still being recognized.
    private(set) var current = ""
    /// The last result closed its utterance.
    private var atBoundary = false

    var text: String { Self.join(committed, current) }

    mutating func receive(_ result: String, endsUtterance: Bool) {
        defer { atBoundary = endsUtterance }
        // A result that repeats the kept utterances, rather than growing the
        // current one, is the whole text again (some final results are).
        let words = Self.words(result)
        if !committed.isEmpty, !words.starts(with: Self.words(current)),
           words.starts(with: Self.words(committed)) {
            committed = ""
            current = result
            return
        }
        if Self.startsOver(from: current, to: result, afterBoundary: atBoundary) {
            committed = Self.join(committed, current)
        }
        current = result
    }

    /// Whether `next` begins a new utterance rather than revising `previous`.
    /// A continuation repeats more than half of what came before. After the
    /// recognizer marked a boundary, a result that doesn't, or is shorter, is new
    /// (continuing past a boundary only grows). Without that mark
    /// only a much shorter result that also changes the first word is: a
    /// revision can rewrite words, but rarely discards most of them.
    static func startsOver(from previous: String, to next: String, afterBoundary: Bool) -> Bool {
        let before = words(previous)
        guard !before.isEmpty else { return false }
        let after = words(next)
        let shared = zip(before, after).prefix(while: { $0.0 == $0.1 }).count
        if shared == before.count { return false }
        if afterBoundary { return after.count < before.count || shared * 2 <= before.count }
        guard before.count >= 3, after.count * 2 <= before.count else { return false }
        return shared == 0
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
    }

    private static func join(_ first: String, _ second: String) -> String {
        let first = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = second.trimmingCharacters(in: .whitespacesAndNewlines)
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        return first + " " + second
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
