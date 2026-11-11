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
    /// The language is the app's, until a sentence is long enough to tell.
    private var languageIsGuess = false
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
        // Whole sentences start speaking while the rest of the reply streams in,
        // each its own utterance: a Premium voice given a long run of them can
        // go quiet past the watchdog partway and lose the rest (issue 2191).
        queue.append(contentsOf: Self.takeCompleteSentences(from: &pending))
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
        // A reply that opens too short to tell ("OK.", "42.") speaks in the
        // app's language until a sentence says what the reply is in.
        if language == nil || languageIsGuess {
            if let detected = Self.language(of: text) {
                language = detected
                languageIsGuess = false
            } else if language == nil {
                language = fallbackLanguage
                languageIsGuess = true
            }
        }
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

    /// Moves every finished sentence out of `text`, one string each, leaving
    /// the unfinished tail. A sentence ends at . ! ? … followed by whitespace
    /// (so "3.5" isn't split), with any closing quotes or brackets in
    /// between kept on it, or right after a line break or a CJK full stop.
    /// A period after a list number, a title or an abbreviation ("1.",
    /// "Dr.", "e.g.") doesn't end one, so it's said with what follows, and
    /// nothing inside a Markdown link does, so the link reaches PreviewText
    /// whole and its address isn't read.
    static func takeCompleteSentences(from text: inout String) -> [String] {
        var sentences: [String] = []
        var start = text.startIndex
        var index = text.startIndex
        var inLinkText = false
        var addressDepth = 0
        while index < text.endIndex {
            let character = text[index]
            var next = text.index(after: index)
            var ends = false
            if inLinkText {
                if character == "]" {
                    inLinkText = false
                    if next < text.endIndex, text[next] == "(" {
                        addressDepth = 1
                        next = text.index(after: next)
                    }
                }
            } else if addressDepth > 0 {
                // An address can hold parentheses of its own ("a_(b)"); an
                // escaped one ("a\\(b") is just a character.
                if character == "\\", next < text.endIndex {
                    next = text.index(after: next)
                } else if character == "(" {
                    addressDepth += 1
                } else if character == ")" {
                    addressDepth -= 1
                }
            } else if character == "[", opensLink(text[next...]) {
                inLinkText = true
            } else if "。！？".contains(character) || character.isNewline {
                ends = true
                // 「你好。」 keeps its closing quote.
                if !character.isNewline {
                    while next < text.endIndex, sentenceClosers.contains(text[next]) { next = text.index(after: next) }
                }
            } else if ".!?…".contains(character) {
                var end = next
                while end < text.endIndex, sentenceClosers.contains(text[end]) { end = text.index(after: end) }
                if end < text.endIndex, text[end].isWhitespace,
                   character != "." || !endsAbbreviation(text[start..<index]) {
                    ends = true
                    next = end
                }
            }
            if ends {
                let sentence = text[start..<next].trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { sentences.append(sentence) }
                start = next
            }
            index = next
        }
        if start > text.startIndex { text = String(text[start...]) }
        return sentences
    }

    /// Quotes and brackets that close a sentence after its last mark.
    private static let sentenceClosers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", "\u{00BB}", ")", "]", "\u{300D}", "\u{300F}"]

    /// Whether the "[" just before `rest` opens a link: its "](" comes
    /// before any other "[". A link still streaming in (no "]" yet, or one
    /// with its "(" still to come) holds too, so it isn't cut before its
    /// address arrives, but only for a link's length: a stray bracket
    /// ("[sic") doesn't hold sentences for long.
    private static func opensLink(_ rest: Substring) -> Bool {
        if let close = rest.range(of: "](") {
            return !rest[..<close.lowerBound].contains("[")
        }
        guard rest.count < 200, !rest.contains("[") else { return false }
        return !rest.dropLast().contains("]") && (rest.last == "]" || !rest.contains("]"))
    }

    /// Whether the word just before a period is a list number (a short
    /// number opening its sentence: "1."), a title ("Dr", "Mrs"), an initial
    /// ("J"), or short letter groups each followed by a period ("e.g", "U.S",
    /// "Ph.D"). Any other
    /// word ends its sentence: short ones ("do it."), a number closing one
    /// ("costs 42."), domains, file names and decimals.
    private static func endsAbbreviation(_ before: Substring) -> Bool {
        let words = before.split(whereSeparator: { $0.isWhitespace })
        let word = (words.last ?? "").drop(while: { !$0.isLetter && !$0.isNumber })
        guard !word.isEmpty else { return false }
        if word.allSatisfy(\.isNumber) { return words.count == 1 && word.count <= 3 }
        if word.contains(".") {
            // "e.g", "U.S", and degrees like "Ph.D" and "M.Sc".
            let parts = word.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.allSatisfy({ (1...2).contains($0.count) && $0.allSatisfy(\.isLetter) }) else { return false }
            // A degree's parts each start with a capital; "My.md" is a file.
            return parts.allSatisfy { $0.count == 1 } || parts.allSatisfy { $0.first?.isUppercase == true }
        }
        if word.count == 1, let letter = word.first, letter.isUppercase { return true }
        return titles.contains(word.lowercased())
    }

    private static let titles: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "st", "jr", "sr", "vs"]

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
        default: return detectedTag(best.key.rawValue)
        }
    }

    /// The tag a detected language is spoken by. Cantonese ("yue") goes to
    /// zh-HK, so it reaches Cantonese voices (iOS tags them zh-HK or yue, both
    /// under Traditional Chinese's key) and a Traditional Chinese pick.
    nonisolated static func detectedTag(_ raw: String) -> String {
        raw.lowercased() == "yue" ? "zh-HK" : raw
    }

    nonisolated static var appLanguage: String? {
        speechLanguage(of: AppLanguage.current.locale ?? Locale(identifier: Locale.preferredLanguages.first ?? "en"))
    }

    /// A locale's language as speech picks voices by it: the language code,
    /// and for Chinese its script, as language(of:) tells replies apart, so
    /// an app in Traditional Chinese speaks short replies with a Traditional
    /// voice.
    nonisolated static func speechLanguage(of locale: Locale) -> String? {
        guard let code = locale.language.languageCode?.identifier else { return nil }
        guard code == "zh" else { return detectedTag(code) }
        // A script named outright wins over the region (zh-Hans-HK is Simplified).
        switch locale.language.script?.identifier {
        case "Hant": return "zh-TW"
        case "Hans": return "zh-CN"
        default:
            return ["TW", "HK", "MO"].contains(locale.language.region?.identifier ?? "") ? "zh-TW" : "zh-CN"
        }
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
                    onDeviceSpeechLog.notice("iPhone speech went quiet without ending; moving on")
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

    /// The voice picked for `language` in Settings, or else the best one
    /// installed (IPhoneVoices).
    private func voice(for language: String?) -> AVSpeechSynthesisVoice? {
        let wanted = language ?? AVSpeechSynthesisVoice.currentLanguageCode()
        let chosen = IPhoneVoices.voice(for: wanted)
        if chosen == nil { onDeviceSpeechLog.notice("No iPhone voice for \(wanted, privacy: .public)") }
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
