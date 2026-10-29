//
//  DictationRecognizers.swift
//  Conduit
//
//  The speech recognizers behind the composer's dictate button. The
//  dictation service owns the microphone and hands each buffer to the
//  recognizer's input; the recognizer reports the whole text so far.
//

import AVFAudio
import Foundation
import os
import Speech

/// What a recognizer reports.
enum DictationUpdate: Equatable {
    /// The whole dictation so far. A final one ends the dictation.
    case text(String, isFinal: Bool)
    /// It can't go on; the message is for the person. Ends the dictation
    /// with the words so far.
    case failed(String)
}

/// Where the microphone's buffers go, on the audio render thread. The
/// dictation service calls it under one lock, never after `end()`.
protocol DictationAudioInput: AnyObject, Sendable {
    func append(_ buffer: AVAudioPCMBuffer)
    /// The microphone closed.
    func end()
}

/// One dictation's recognizer, made once its engine is ready (permission,
/// language, model) and before the microphone opens.
@MainActor
protocol DictationRecognizer: AnyObject {
    /// How long its last words may take once the microphone closes.
    var settleTimeout: Duration { get }
    /// Its words reach the draft only once it settles (an upload), so a
    /// new dictation must not cut that short.
    var holdsWordsWhileSettling: Bool { get }
    /// Starts recognizing the microphone's audio, which comes in `format`.
    func begin(
        format: AVAudioFormat,
        onUpdate: @escaping @MainActor (DictationUpdate) -> Void
    ) throws -> any DictationAudioInput
    /// The microphone closed: settle the last words and send a final text.
    func endAudio()
    /// Stops without another update.
    func cancel()
}

// MARK: - Apple (SFSpeechRecognizer)

@MainActor
final class AppleSpeechDictationRecognizer: DictationRecognizer {
    let settleTimeout: Duration = .milliseconds(1_500)
    let holdsWordsWhileSettling = false
    private let recognizer: SFSpeechRecognizer
    private let words: [String]
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var transcript = DictationTranscript()
    private var onUpdate: (@MainActor (DictationUpdate) -> Void)?

    init(words: [String]) throws {
        guard let recognizer = SFSpeechRecognizer(locale: SpeechRecognitionLocale.preferred()) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            throw ComposerDictationService.DictationError.message(AppLocalization.string("Dictation isn't available right now."))
        }
        self.recognizer = recognizer
        self.words = words
    }

    func begin(
        format: AVAudioFormat,
        onUpdate: @escaping @MainActor (DictationUpdate) -> Void
    ) throws -> any DictationAudioInput {
        self.onUpdate = onUpdate
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.contextualStrings = words
        // On the device when the language allows it.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            // Set on the result that closes an utterance (a pause); the
            // recognizer may start the next one from empty.
            let endsUtterance = result?.speechRecognitionMetadata != nil
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                self?.receive(text, endsUtterance: endsUtterance, isFinal: isFinal, failed: failed)
            }
        }
        return SpeechRequestAudioInput(request: request)
    }

    func endAudio() {
        // The sink already ended the request; again is harmless.
        request?.endAudio()
    }

    func cancel() {
        onUpdate = nil
        request = nil
        task?.cancel()
        task = nil
    }

    private func receive(_ text: String?, endsUtterance: Bool, isFinal: Bool, failed: Bool) {
        if let text, !text.isEmpty {
            transcript.receive(text, endsUtterance: endsUtterance)
        }
        // Keep any recognized words, then report a runtime failure separately.
        onUpdate?(.text(transcript.text, isFinal: isFinal && !failed))
        if failed {
            onUpdate?(.failed(AppLocalization.string("Dictation isn't available right now.")))
        }
    }
}

private final class SpeechRequestAudioInput: DictationAudioInput, @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }
    func end() { request.endAudio() }
}

// MARK: - Apple's new model (SpeechAnalyzer, iOS 26)

@available(iOS 26.0, *)
@MainActor
final class SpeechAnalyzerDictationRecognizer: DictationRecognizer {
    let settleTimeout: Duration = .seconds(3)
    let holdsWordsWhileSettling = false
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    /// The format the model wants; nil takes the microphone's as it is.
    private let analyzerFormat: AVAudioFormat?
    private var transcript = AnalyzerTranscript()
    private var onUpdate: (@MainActor (DictationUpdate) -> Void)?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var finishing: Task<Void, Never>?

    private init(transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer, analyzerFormat: AVAudioFormat?) {
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.analyzerFormat = analyzerFormat
    }

    static func make(words: [String]) async throws -> SpeechAnalyzerDictationRecognizer {
        let transcriber = try await makeTranscriber()
        try await installModel(for: transcriber)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !words.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = words
            try? await analyzer.setContext(context)
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        return SpeechAnalyzerDictationRecognizer(transcriber: transcriber, analyzer: analyzer, analyzerFormat: format)
    }

    /// Downloads the model for the person's language ahead of the first
    /// dictation, when the engine is picked. Failures wait for that
    /// dictation, which says why.
    static func prepare() async {
        guard let transcriber = try? await makeTranscriber() else { return }
        try? await installModel(for: transcriber)
    }

    private static func makeTranscriber() async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else {
            throw ComposerDictationService.DictationError.message(AppLocalization.string("Apple's new speech model isn't available on this iPhone."))
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: SpeechRecognitionLocale.preferred()) else {
            throw ComposerDictationService.DictationError.message(AppLocalization.string("Apple's new speech model doesn't support your language yet. Pick Apple in Voice settings."))
        }
        return SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
    }

    private static func installModel(for transcriber: SpeechTranscriber) async throws {
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw ComposerDictationService.DictationError.message(AppLocalization.string("Apple's new speech model couldn't be downloaded. Check your connection and try again."))
        }
    }

    func begin(
        format: AVAudioFormat,
        onUpdate: @escaping @MainActor (DictationUpdate) -> Void
    ) throws -> any DictationAudioInput {
        self.onUpdate = onUpdate
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        self.input = input
        resultsTask = Task { [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    self?.receive(String(result.text.characters), isFinal: result.isFinal)
                }
                self?.resultsEnded(failed: false)
            } catch {
                self?.resultsEnded(failed: !Task.isCancelled)
            }
        }
        startTask = Task { [weak self, analyzer] in
            do {
                try await analyzer.start(inputSequence: stream)
            } catch {
                guard !Task.isCancelled else { return }
                self?.resultsEnded(failed: true)
            }
        }
        return AnalyzerAudioInput(input: input, format: analyzerFormat ?? format)
    }

    func endAudio() {
        input?.finish()
        finishing = Task { [analyzer] in
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
    }

    func cancel() {
        onUpdate = nil
        input?.finish()
        resultsTask?.cancel()
        startTask?.cancel()
        finishing?.cancel()
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }

    private func receive(_ text: String, isFinal: Bool) {
        transcript.receive(text, isFinal: isFinal)
        onUpdate?(.text(transcript.text, isFinal: false))
    }

    private func resultsEnded(failed: Bool) {
        // Once: the start failing also ends the results.
        guard let onUpdate else { return }
        self.onUpdate = nil
        if failed, transcript.text.isEmpty {
            onUpdate(.failed(AppLocalization.string("Dictation isn't available right now.")))
        } else {
            onUpdate(.text(transcript.text, isFinal: true))
        }
    }
}

/// The new model's text: finished stretches are kept, and the stretch still
/// being heard is replaced by each new guess.
struct AnalyzerTranscript: Equatable {
    private(set) var finalized = ""
    private(set) var volatile = ""

    var text: String { DictationTranscript.join(finalized, volatile) }

    mutating func receive(_ result: String, isFinal: Bool) {
        if isFinal {
            finalized = DictationTranscript.join(finalized, result)
            volatile = ""
        } else {
            volatile = result
        }
    }
}

@available(iOS 26.0, *)
private final class AnalyzerAudioInput: DictationAudioInput, @unchecked Sendable {
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let converter: DictationAudioConverter

    init(input: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) {
        self.input = input
        converter = DictationAudioConverter(output: format)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        // Always a fresh buffer, even in the microphone's own format: the
        // tap's buffer is only valid during its callback.
        guard let converted = converter.convert(buffer) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    func end() { input.finish() }
}

// MARK: - Hermes

/// Hermes' own speech to text: live words over the transcribe-stream
/// socket when the host streams them, and the whole recording uploaded
/// when you stop otherwise (or when the live words fail). With `clips`
/// (composer dictation) the recording is kept on disk before it goes up,
/// the upload is tried again on a brief network gap, and a recording
/// whose words never came stays there for Retry.
@MainActor
final class HermesDictationRecognizer: DictationRecognizer {
    nonisolated static let sampleRate = VoiceAudioSessionConfiguration.capture.outputSampleRate
    /// Hosts and profiles that answered they have no live speech to text,
    /// so later dictations there go straight to the upload until relaunch.
    private static var liveUnavailable = Set<String>()
    /// A watchdog only: the upload has the gateway's own request budget,
    /// sized for long recordings and remote providers. It isn't stretched
    /// to cover every retry: it bounds how long Send waits, and a dictation
    /// it ends keeps its recording for Retry.
    let settleTimeout: Duration = .milliseconds(HermesVoiceGateway.transcriptionMaximumRequestTimeoutMilliseconds + 10_000)
    let holdsWordsWhileSettling = true
    private let gateway: HermesVoiceGateway
    private var onUpdate: (@MainActor (DictationUpdate) -> Void)?
    private var input: HermesAudioInput?
    private var live: VoiceLiveTranscription?
    private var opening: Task<Void, Never>?
    private var finishing: Task<Void, Never>?
    /// The whole recording, 16 kHz mono PCM16, for the upload. Never more
    /// than `maximumRecordedBytes`: the dictation stops itself there.
    private var recorded = Data()
    /// The dictation limit's worth of audio, with a second to spare for
    /// buffers still on their way when it stops.
    static let maximumRecordedBytes = Int(sampleRate) * 2 * Int(VoiceMessageRecorder.maximumDuration + 1)
    private var sentBytes = 0
    private var partial = ""
    private let clips: DictationClipInbox?
    /// This dictation's recording on disk, until its words are delivered.
    private var clip: DictationClip?

    init(gateway: HermesVoiceGateway, clips: DictationClipInbox? = nil) {
        self.gateway = gateway
        self.clips = clips
    }

    func begin(
        format: AVAudioFormat,
        onUpdate: @escaping @MainActor (DictationUpdate) -> Void
    ) throws -> any DictationAudioInput {
        guard let output = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1) else {
            throw ComposerDictationService.DictationError.message(AppLocalization.string("The microphone is not available right now."))
        }
        self.onUpdate = onUpdate
        let identity = gateway.identity
        if !Self.liveUnavailable.contains(identity) {
            opening = Task { [weak self, gateway] in
                let session = await gateway.openLiveTranscription(
                    sampleRate: Self.sampleRate,
                    onPartial: { [weak self] text in self?.receivePartial(text) },
                    onUnavailable: { Self.liveUnavailable.insert(identity) }
                )
                guard let self, !Task.isCancelled else {
                    session?.cancel()
                    return
                }
                self.live = session
                // What was recorded while the socket opened goes first.
                self.pump()
            }
        }
        let input = HermesAudioInput(output: output) { [weak self] in
            Task { @MainActor [weak self] in self?.pump() }
        }
        self.input = input
        return input
    }

    func endAudio() {
        finishing = Task { [weak self] in
            guard let self else { return }
            // The microphone is closed: the recording is whole. On disk
            // first, so nothing below can lose it.
            self.pump()
            await self.keepRecording()
            guard !Task.isCancelled else { return }
            // The live socket may still be opening: give it the recording.
            await self.opening?.value
            guard !Task.isCancelled else { return }
            self.pump()
            if let live = self.live, let text = await live.finish(), !text.isEmpty {
                guard !Task.isCancelled else { return }
                self.deliver(text)
                return
            }
            guard !Task.isCancelled else { return }
            await self.upload()
        }
    }

    func cancel() {
        // Ended while still listening (a call took the microphone, the
        // composer went away) with no words from the live socket: what was
        // said is only in the recording, so it is kept for Retry.
        if clips != nil, finishing == nil, partial.isEmpty, let pcm = input?.drain() {
            recorded.append(pcm.prefix(max(0, Self.maximumRecordedBytes - recorded.count)))
        }
        let unheard = finishing == nil && partial.isEmpty
            && Double(recorded.count) / 2 / Self.sampleRate >= DictationClipInbox.shortestKept
        onUpdate = nil
        opening?.cancel()
        finishing?.cancel()
        live?.cancel()
        live = nil
        // Stopped before its words came (the settle ran out, or the
        // composer went away): the recording stays for Retry.
        releaseClip()
        if unheard, let clips {
            let recording = recorded
            let identity = gateway.identity
            Task {
                guard let clip = await clips.keep(pcm16: recording, sampleRate: Self.sampleRate, identity: identity) else { return }
                clips.release(clip.id)
            }
        }
    }

    /// Takes what the microphone recorded since last time, in order, and
    /// sends what the live socket hasn't had yet.
    private func pump() {
        guard onUpdate != nil else { return }
        if let pcm = input?.drain() {
            recorded.append(pcm.prefix(max(0, Self.maximumRecordedBytes - recorded.count)))
        }
        guard let live, recorded.count > sentBytes else { return }
        live.push(recorded.subdata(in: sentBytes..<recorded.count))
        sentBytes = recorded.count
    }

    private func receivePartial(_ text: String) {
        guard !text.isEmpty else { return }
        partial = text
        onUpdate?(.text(text, isFinal: false))
    }

    private func upload() async {
        guard !recorded.isEmpty else {
            deliver(partial)
            return
        }
        let audio = VoiceCapturedAudio.dictation(pcm16: recorded, sampleRate: Self.sampleRate)
        do {
            let text: String
            if let clips, let clip {
                text = try await DictationUploadRetry.run(
                    attempt: { [gateway] in try await gateway.transcribe(audio) },
                    onFailedAttempt: { error in clips.attemptFailed(clip.id, error: error) }
                )
            } else {
                text = try await gateway.transcribe(audio)
            }
            guard !Task.isCancelled else { return }
            if text.isEmpty, let clip, clip.duration >= DictationClipInbox.quietClipLimit {
                // Nothing heard in a long recording: keep it for Retry
                // rather than trust the silence.
                releaseClip()
                onUpdate?(.text(partial, isFinal: true))
                return
            }
            deliver(text.isEmpty ? partial : text)
        } catch {
            guard !Task.isCancelled else { return }
            releaseClip()
            onUpdate?(.failed(AppLocalization.string("Hermes couldn't transcribe that: \(UserFacingError.message(for: error))")))
        }
    }

    /// Writes the whole recording to disk (composer dictation only).
    private func keepRecording() async {
        guard let clips, clip == nil, !recorded.isEmpty else { return }
        let kept = await clips.keep(pcm16: recorded, sampleRate: Self.sampleRate, identity: gateway.identity)
        clip = kept
        // Cancelled while it was written: cancel() found nothing to let go.
        if Task.isCancelled { releaseClip() }
    }

    /// The final words, and the recording they came from is no longer needed.
    private func deliver(_ text: String) {
        guard let onUpdate else { return }
        if let clip {
            self.clip = nil
            clips?.delivered(clip.id)
        }
        onUpdate(.text(text, isFinal: true))
    }

    private func releaseClip() {
        guard let clip else { return }
        self.clip = nil
        clips?.release(clip.id)
    }
}

extension VoiceCapturedAudio {
    /// A Hermes dictation's recording (16 kHz mono PCM16) as the upload
    /// sends it.
    @MainActor
    static func dictation(pcm16: Data, sampleRate: Double) -> VoiceCapturedAudio {
        VoiceCapturedAudio(
            wavData: AVAudioCaptureService.wavWrapping(pcm16: pcm16, sampleRate: Int(sampleRate)),
            pcm16Data: pcm16,
            sampleRate: sampleRate,
            duration: Double(pcm16.count) / 2 / sampleRate
        )
    }
}

/// Converts the microphone to PCM16 on the render thread and keeps it,
/// in order, until the recognizer drains it on the main actor. One wake
/// is in flight at a time, not one per buffer.
private final class HermesAudioInput: DictationAudioInput, @unchecked Sendable {
    private struct Pending {
        var pcm = Data()
        var wakeScheduled = false
    }

    private let converter: DictationAudioConverter
    private let pending = OSAllocatedUnfairLock(initialState: Pending())
    private let wake: @Sendable () -> Void

    init(output: AVAudioFormat, wake: @escaping @Sendable () -> Void) {
        converter = DictationAudioConverter(output: output)
        self.wake = wake
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer),
              let channel = converted.floatChannelData?[0] else { return }
        let pcm = VoicePCMEncoding.encode(channel, count: Int(converted.frameLength)).data
        guard !pcm.isEmpty else { return }
        let shouldWake = pending.withLock { state in
            state.pcm.append(pcm)
            defer { state.wakeScheduled = true }
            return !state.wakeScheduled
        }
        if shouldWake { wake() }
    }

    func end() {}

    /// Everything recorded since the last drain.
    func drain() -> Data {
        pending.withLock { state in
            defer {
                state.pcm = Data()
                state.wakeScheduled = false
            }
            return state.pcm
        }
    }
}

// MARK: - Conversion

/// Converts microphone buffers to one format, on the render thread. Not
/// thread-safe: one input uses it, under the dictation service's lock.
final class DictationAudioConverter {
    let output: AVAudioFormat
    private var converter: AVAudioConverter?

    init(output: AVAudioFormat) {
        self.output = output
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: output)
        }
        guard let converter, buffer.frameLength > 0 else { return nil }
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio) + 32)
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var suppliedInput = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            guard !suppliedInput else {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, status != .error, converted.frameLength > 0 else { return nil }
        return converted
    }
}
