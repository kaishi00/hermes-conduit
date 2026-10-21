//
//  OnDeviceSpeech.swift
//  Conduit
//
//  Classic voice's assistant speech on this iPhone: iOS's own voices
//  (AVSpeechSynthesizer) render each reply to PCM, which plays through the
//  same playback path as Hermes speech, so echo cancellation, barge-in and
//  Read Aloud's speed work unchanged. Nothing to install or pay for on the
//  Hermes host, which makes it the default for profiles without a working
//  Hermes voice of their own.
//

import AVFoundation
import Foundation
import NaturalLanguage
import OSLog

private let onDeviceSpeechLog = Logger(subsystem: "com.milim.relay", category: "OnDeviceSpeech")

/// Who speaks Classic voice replies.
enum VoiceSpeechOutput: String, Codable, Equatable {
    /// iOS's built-in voices, on this iPhone.
    case onDevice
    /// The profile's text-to-speech provider on Hermes.
    case hermes
    /// The user's own speech server, the one Classic can listen through
    /// (SpeechServerSpeechStream): one server listens and speaks.
    case speechServer

    /// A saved choice wins. With none saved, a profile keeps a Hermes voice
    /// that is ready and isn't Edge TTS (someone set it up on purpose);
    /// everything else speaks on this iPhone. Edge is Hermes' default and
    /// breaks whenever Microsoft changes its handshake.
    static func resolved(chosen: VoiceSpeechOutput?, snapshot: VoiceCapabilitySnapshot) -> VoiceSpeechOutput {
        if let chosen { return chosen }
        let provider = snapshot.selectedTTSProvider.trimmingCharacters(in: .whitespaces).lowercased()
        let hermesVoiceIsOwn = snapshot.supportsSpeech
            && !provider.isEmpty
            && provider != VoiceSetupDefaults.edgeTTSProviderID
        return hermesVoiceIsOwn ? .hermes : .onDevice
    }
}

/// Renders one piece of text to 16-bit mono PCM. Abstracted so the stream's
/// queueing is testable without real speech.
@MainActor
protocol OnDeviceSpeechSynthesizing: AnyObject {
    /// Speaks `text` in `language` (BCP 47, or nil for the system's), calling
    /// `onAudio` with PCM chunks in order and `onDone` once, after the last.
    func speak(
        _ text: String,
        language: String?,
        onAudio: @escaping @MainActor (Data, Double) -> Void,
        onDone: @escaping @MainActor () -> Void
    )
    func stop()
}

@MainActor
final class OnDeviceSpeechStream: VoiceSpeechStream {
    private let synthesizer: OnDeviceSpeechSynthesizing
    private let fallbackLanguage: String?
    private let onStart: @MainActor (Double) throws -> Void
    private let onPCM16: @MainActor (Data, Double) throws -> Void
    private var pending = ""
    private var queue: [String] = []
    private var speaking = false
    private var language: String?
    private var sampleRate: Double?
    private var finishRequested = false
    private var terminal = false
    private var terminalError: Error?
    private var completion: CheckedContinuation<Bool, Error>?

    init(
        synthesizer: OnDeviceSpeechSynthesizing? = nil,
        fallbackLanguage: String? = OnDeviceSpeechStream.appLanguage,
        onStart: @escaping @MainActor (Double) throws -> Void,
        onPCM16: @escaping @MainActor (Data, Double) throws -> Void
    ) {
        self.synthesizer = synthesizer ?? SystemSpeechSynthesizer()
        self.fallbackLanguage = fallbackLanguage
        self.onStart = onStart
        self.onPCM16 = onPCM16
    }

    func append(_ text: String) async throws {
        if terminal { throw terminalError ?? CancellationError() }
        pending += text
        // Whole sentences start speaking while the rest of the reply streams in.
        if let sentences = Self.takeCompleteSentences(from: &pending) { queue.append(sentences) }
        speakNext()
    }

    func finish() async throws -> Bool {
        if terminal {
            if let terminalError { throw terminalError }
            return sampleRate != nil
        }
        let rest = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        if !rest.isEmpty { queue.append(rest) }
        finishRequested = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.completion = continuation
                self.speakNext()
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() {
        guard !terminal else { return }
        synthesizer.stop()
        complete(.failure(CancellationError()))
    }

    private func speakNext() {
        guard !terminal, !speaking else { return }
        guard !queue.isEmpty else {
            if finishRequested { complete(.success(sampleRate != nil)) }
            return
        }
        // Markdown marks are written, not said: "**Québec**" reads "Québec".
        // Hermes' own speech strips them on the gateway; this voice is ours.
        let text = PreviewText.plain(queue.removeFirst())
        guard !text.isEmpty else { return speakNext() }
        if language == nil { language = Self.language(of: text) ?? fallbackLanguage }
        speaking = true
        synthesizer.speak(
            text,
            language: language,
            onAudio: { [weak self] data, rate in self?.receive(data, sampleRate: rate) },
            onDone: { [weak self] in
                guard let self, !self.terminal else { return }
                self.speaking = false
                self.speakNext()
            }
        )
    }

    private func receive(_ data: Data, sampleRate rate: Double) {
        guard !terminal, !data.isEmpty else { return }
        do {
            if sampleRate == nil {
                try onStart(rate)
                sampleRate = rate
            }
            try onPCM16(data, rate)
        } catch {
            synthesizer.stop()
            complete(.failure(error))
        }
    }

    private func complete(_ result: Result<Bool, Error>) {
        guard !terminal else { return }
        terminal = true
        queue.removeAll()
        if case .failure(let error) = result { terminalError = error }
        let continuation = completion
        completion = nil
        continuation?.resume(with: result)
    }

    /// Moves every finished sentence out of `text`, leaving the unfinished
    /// tail. A sentence ends at . ! ? … followed by whitespace (so "3.5"
    /// isn't split), or right after a line break or a CJK full stop.
    static func takeCompleteSentences(from text: inout String) -> String? {
        var boundary: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if "。！？".contains(character) {
                boundary = next
            } else if character == "\n" {
                boundary = next
            } else if ".!?…".contains(character), next < text.endIndex, text[next].isWhitespace {
                boundary = next
            }
            index = next
        }
        guard let boundary else { return nil }
        let sentences = String(text[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        text = String(text[boundary...])
        return sentences.isEmpty ? nil : sentences
    }

    /// The reply's language, so a German answer gets a German voice even
    /// with the app in English. Nil when the text is too short to tell.
    static func language(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.6 else { return nil }
        switch best.key {
        case .simplifiedChinese: return "zh-CN"
        case .traditionalChinese: return "zh-TW"
        case .undetermined: return nil
        default: return best.key.rawValue
        }
    }

    nonisolated static var appLanguage: String? {
        let locale = AppLanguage.current.locale ?? Locale(identifier: Locale.preferredLanguages.first ?? "en")
        return locale.language.languageCode?.identifier
    }
}

/// iOS's speech synthesizer, rendering to buffers instead of the speaker so
/// Conduit's own playback plays them.
@MainActor
final class SystemSpeechSynthesizer: NSObject, OnDeviceSpeechSynthesizing, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var utterance = 0
    private var onDone: (@MainActor () -> Void)?
    private var request: AVSpeechUtterance?
    private var watchdog: Task<Void, Never>?
    /// When the current utterance last produced audio (or started).
    private var lastAudio = ContinuousClock.now
    /// Best voice per language, shared by every reply; a cached nil means
    /// none is installed.
    private static var voices: [String: AVSpeechSynthesisVoice?] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(
        _ text: String,
        language: String?,
        onAudio: @escaping @MainActor (Data, Double) -> Void,
        onDone: @escaping @MainActor () -> Void
    ) {
        utterance += 1
        let id = utterance
        self.onDone = onDone
        let request = AVSpeechUtterance(string: text)
        request.voice = voice(for: language)
        self.request = request
        armWatchdog(id)
        synthesizer.write(request) { [weak self] buffer in
            // Called off the main thread, in order; the main queue keeps it.
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            let data = Self.int16Data(pcm)
            let rate = pcm.format.sampleRate
            let isEnd = pcm.frameLength == 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.utterance == id else { return }
                    if isEnd {
                        self.finish(id)
                    } else {
                        self.lastAudio = .now
                        if !data.isEmpty { onAudio(data, rate) }
                    }
                }
            }
        }
    }

    func stop() {
        utterance += 1
        onDone = nil
        request = nil
        watchdog?.cancel()
        watchdog = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func finish(_ id: Int) {
        guard utterance == id, let onDone else { return }
        // Late buffers of a finished utterance are dropped.
        utterance += 1
        self.onDone = nil
        request = nil
        watchdog?.cancel()
        watchdog = nil
        onDone()
    }

    /// iOS doesn't always send the empty end-of-speech buffer: an utterance
    /// that has gone quiet this long is done.
    private func armWatchdog(_ id: Int) {
        watchdog?.cancel()
        lastAudio = .now
        let quiet = Duration.seconds(8)
        watchdog = Task { @MainActor [weak self] in
            while let self, self.utterance == id {
                do { try await Task.sleep(until: self.lastAudio + quiet, clock: .continuous) } catch { return }
                if ContinuousClock.now - self.lastAudio >= quiet {
                    self.finish(id)
                    return
                }
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // A backup for the end-of-speech buffer, after the last buffers
        // already queued on the main queue have played through. Only for
        // the utterance still speaking, never the next one.
        let finished = ObjectIdentifier(utterance)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let request = self.request, ObjectIdentifier(request) == finished else { return }
                self.finish(self.utterance)
            }
        }
    }

    /// The best voice installed for `language`: Premium, then Enhanced,
    /// then the default one, preferring the iPhone's own region. Novelty
    /// and Personal Voices are never picked.
    private func voice(for language: String?) -> AVSpeechSynthesisVoice? {
        let key = language ?? ""
        if let cached = Self.voices[key] { return cached }
        let wanted = language ?? AVSpeechSynthesisVoice.currentLanguageCode()
        let base = wanted.split(separator: "-").first.map(String.init) ?? wanted
        let region = Locale.current.region?.identifier
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            !voice.voiceTraits.contains(.isNoveltyVoice)
                && !voice.voiceTraits.contains(.isPersonalVoice)
                && (voice.language == wanted || voice.language.hasPrefix(base + "-") || voice.language == base)
        }
        func rank(_ voice: AVSpeechSynthesisVoice) -> (Int, Int, Int) {
            let exact = voice.language == wanted ? 1 : 0
            let local = region.map { voice.language.hasSuffix("-" + $0) } == true ? 1 : 0
            return (voice.quality.rawValue, exact, local)
        }
        let chosen = candidates.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: wanted)
        if chosen == nil { onDeviceSpeechLog.notice("No iPhone voice for \(wanted, privacy: .public)") }
        Self.voices[key] = .some(chosen)
        return chosen
    }

    nonisolated static func int16Data(_ buffer: AVAudioPCMBuffer) -> Data {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return Data() }
        if let int16 = buffer.int16ChannelData {
            return Data(bytes: int16[0], count: frames * MemoryLayout<Int16>.size)
        }
        if let float = buffer.floatChannelData {
            let source = float[0]
            var samples = [Int16](repeating: 0, count: frames)
            for index in 0..<frames {
                let value = source[index]
                samples[index] = value.isFinite ? Int16(max(-1, min(1, value)) * Float(Int16.max)) : 0
            }
            return samples.withUnsafeBufferPointer { Data(buffer: $0) }
        }
        return Data()
    }
}

/// Hermes speech that falls back to this iPhone's voice when Hermes fails
/// before any audio played (a provider refusing, a missing endpoint, a
/// dropped stream), so a broken provider costs one slow reply instead of
/// silence. Audio that already started is never replayed.
@MainActor
final class FallbackSpeechStream: VoiceSpeechStream {
    typealias OpenHermes = @MainActor (
        _ onStart: @escaping @MainActor (Double) throws -> Void,
        _ onPCM16: @escaping @MainActor (Data, Double) throws -> Void,
        _ onEncodedAudio: @escaping @MainActor (Data) throws -> Void
    ) async throws -> VoiceSpeechStream
    typealias OpenOnDevice = @MainActor (
        _ onStart: @escaping @MainActor (Double) throws -> Void,
        _ onPCM16: @escaping @MainActor (Data, Double) throws -> Void
    ) -> VoiceSpeechStream

    private let openOnDevice: OpenOnDevice
    private let onFallback: @MainActor (Error) -> Void
    private let onStart: @MainActor (Double) throws -> Void
    private let onPCM16: @MainActor (Data, Double) throws -> Void
    private var current: VoiceSpeechStream?
    private var text = ""
    private var audioStarted = false
    private var hermesError: Error?
    private var usingFallback = false
    private var cancelled = false

    private init(
        openOnDevice: @escaping OpenOnDevice,
        onFallback: @escaping @MainActor (Error) -> Void,
        onStart: @escaping @MainActor (Double) throws -> Void,
        onPCM16: @escaping @MainActor (Data, Double) throws -> Void
    ) {
        self.openOnDevice = openOnDevice
        self.onFallback = onFallback
        self.onStart = onStart
        self.onPCM16 = onPCM16
    }

    static func open(
        hermes: OpenHermes,
        onDevice: @escaping OpenOnDevice,
        onFallback: @escaping @MainActor (Error) -> Void,
        onStart: @escaping @MainActor (Double) throws -> Void,
        onPCM16: @escaping @MainActor (Data, Double) throws -> Void,
        onEncodedAudio: @escaping @MainActor (Data) throws -> Void
    ) async throws -> VoiceSpeechStream {
        let stream = FallbackSpeechStream(openOnDevice: onDevice, onFallback: onFallback, onStart: onStart, onPCM16: onPCM16)
        do {
            stream.current = try await hermes(
                { rate in try onStart(rate) },
                { [weak stream] data, rate in
                    try onPCM16(data, rate)
                    if !data.isEmpty { stream?.audioStarted = true }
                },
                { [weak stream] data in
                    try onEncodedAudio(data)
                    if !data.isEmpty { stream?.audioStarted = true }
                }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            stream.hermesError = error
        }
        return stream
    }

    func append(_ chunk: String) async throws {
        if cancelled { throw CancellationError() }
        text += chunk
        if usingFallback {
            try await current?.append(chunk)
            return
        }
        // Hermes already failed: the text waits for the iPhone at finish().
        guard hermesError == nil, let current else { return }
        do {
            try await current.append(chunk)
        } catch {
            try hermesFailed(error)
        }
    }

    func finish() async throws -> Bool {
        if cancelled { throw CancellationError() }
        if !usingFallback, hermesError != nil { try await switchToOnDevice() }
        guard let current else { throw hermesError ?? CancellationError() }
        do {
            let streamedPCM = try await current.finish()
            text = ""
            return streamedPCM
        } catch {
            guard !usingFallback else { throw error }
            try hermesFailed(error)
            try await switchToOnDevice()
            guard let fallback = self.current else { throw CancellationError() }
            let streamedPCM = try await fallback.finish()
            text = ""
            return streamedPCM
        }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        current?.cancel()
    }

    /// Keeps a failure that the iPhone can still cover; anything else
    /// (audio already played, a cancel) is the caller's.
    private func hermesFailed(_ error: Error) throws {
        if cancelled || error is CancellationError || audioStarted { throw error }
        hermesError = error
    }

    private func switchToOnDevice() async throws {
        guard let hermesError else { return }
        current?.cancel()
        usingFallback = true
        onFallback(hermesError)
        let fallback = openOnDevice(onStart, onPCM16)
        current = fallback
        if cancelled {
            fallback.cancel()
            throw CancellationError()
        }
        if !text.isEmpty { try await fallback.append(text) }
    }
}
