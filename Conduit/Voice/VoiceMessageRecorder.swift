//
//  VoiceMessageRecorder.swift
//  Conduit
//
//  Voice messages from a chat's composer: record, preview or throw away,
//  then send the audio with what was said. The recording is an AAC file
//  the chat keeps and plays; the words come from the dictation engine the
//  person picked (Apple on the phone by default, or Hermes), recognized
//  while they speak, so the agent reads the message rather than guessing
//  at a file it can't hear. A recognizer that gives up (permission, a
//  dropped connection, a time limit) never stops the recording: the
//  message goes with the words so far, or none.
//

import AVFAudio
import Foundation
import os

@MainActor
final class VoiceMessageRecorder: ObservableObject {
    /// One recorder for the app: the chat's big button starts it and the
    /// composer shows it.
    static let shared = VoiceMessageRecorder()

    enum Phase: Equatable {
        case idle
        /// Permission or the microphone is still coming up.
        case starting
        case recording
        /// Stopped; the last words are on their way.
        case finishing
        /// Ready to preview and send.
        case recorded
    }

    struct Recording: Equatable {
        let url: URL
        let duration: TimeInterval
        let transcript: String
    }

    /// The longest message: past this the recording stops by itself.
    static let maximumDuration: TimeInterval = 15 * 60
    /// Shorter than this is a slip of the finger, not a message.
    static let minimumDuration: TimeInterval = 0.5
    /// Level bars kept for the recording bar's waveform.
    static let levelCount = 32

    /// What changes many times a second while recording, published apart
    /// so only the recording bar redraws for it, not the whole composer.
    @MainActor
    final class Meter: ObservableObject {
        @Published fileprivate(set) var elapsed: TimeInterval = 0
        /// Recent loudness, 0...1, oldest first.
        @Published fileprivate(set) var levels: [Float] = []
        /// The words so far.
        @Published fileprivate(set) var transcript = ""
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var recording: Recording?
    let meter = Meter()
    /// A send is on its way: Send waits for it.
    @Published var isSending = false
    /// Recording while the chat's big button is held: letting go sends.
    @Published var isHeld = false
    /// Why the last start failed, for the composer to say.
    @Published var errorMessage: String?
    /// The chat the message is for: it is dropped if another opens.
    private(set) var sessionID: String?

    private let audioCoordinator: VoiceAudioSessionCoordinator
    private let sink = VoiceMessageAudioSink()
    private var engine: AVAudioEngine?
    private var lease: VoiceAudioLease?
    private var audioObservers: [NSObjectProtocol] = []
    private var recognizer: (any DictationRecognizer)?
    private var writer: VoiceMessageFileWriter?
    /// The stopped file while its last words settle, before `recording`.
    private var pendingURL: URL?
    private var startedAt: Date?
    private var ticker: Task<Void, Never>?
    private var settling: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(audioCoordinator: VoiceAudioSessionCoordinator? = nil) {
        self.audioCoordinator = audioCoordinator ?? .shared
    }

    var isActive: Bool { phase != .idle }

    /// Starts recording for the chat `sessionID`. `hermesGateway` makes the
    /// connected Hermes' gateway, for the Hermes dictation engine.
    func start(
        sessionID: String?,
        engine choice: DictationEngine = .current(),
        words: [String] = DictationCustomWords.load(),
        hermesGateway: () -> HermesVoiceGateway? = { nil }
    ) async {
        guard phase == .idle else { return }
        generation &+= 1
        let generation = generation
        phase = .starting
        errorMessage = nil
        self.sessionID = sessionID
        meter.transcript = ""
        meter.levels = []
        meter.elapsed = 0
        recording = nil

        if AVAudioApplication.shared.recordPermission == .undetermined {
            _ = await AVAudioApplication.requestRecordPermission()
        }
        guard self.generation == generation else { return }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            fail(AppLocalization.string("Voice messages need microphone access. You can allow it in Settings."))
            return
        }
        // Words are a bonus: without a recognizer the audio still goes.
        let recognizer = try? await ComposerDictationService.makeRecognizer(choice, words: words, hermesGateway: hermesGateway)
        guard self.generation == generation else {
            recognizer?.cancel()
            return
        }
        guard !audioCoordinator.hasCaptureOwner else {
            recognizer?.cancel()
            fail(AppLocalization.string("The microphone is not available right now."))
            return
        }
        let url: URL
        let format: AVAudioFormat
        let writer: VoiceMessageFileWriter
        do {
            lease = try audioCoordinator.acquire(.conversationCapture) { [weak self] in
                self?.audioWasLost(generation: generation)
            }
            format = try startAudio()
            url = Self.newFileURL()
            writer = try VoiceMessageFileWriter(url: url, format: format)
            observeAudioLoss(generation: generation)
        } catch {
            recognizer?.cancel()
            stopAudio()
            releaseAudio()
            fail(AppLocalization.string("The microphone is not available right now."))
            return
        }
        var recognizerInput: (any DictationAudioInput)?
        if let recognizer {
            recognizerInput = try? recognizer.begin(format: format) { [weak self] update in
                self?.receive(update, generation: generation)
            }
            if recognizerInput != nil { self.recognizer = recognizer } else { recognizer.cancel() }
        }
        self.writer = writer
        sink.start(writer: writer, recognizer: recognizerInput)
        startedAt = Date()
        phase = .recording
        tick(generation: generation)
    }

    /// Stops recording and waits briefly for the last words, then the
    /// message is ready to preview and send. Returns it, or nil when it was
    /// too short (and is thrown away).
    @discardableResult
    func stop() async -> Recording? {
        guard phase == .recording else { return recording }
        let generation = generation
        phase = .finishing
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? meter.elapsed
        meter.elapsed = duration
        ticker?.cancel()
        ticker = nil
        let writeFailed = sink.stop()
        stopAudio()
        releaseAudio()
        writer?.close()
        guard let url = writer?.url else {
            reset()
            return nil
        }
        writer = nil
        guard !writeFailed else {
            // A gap in the file: not something to send.
            recognizer?.cancel()
            recognizer = nil
            try? FileManager.default.removeItem(at: url)
            fail(AppLocalization.string("Couldn't save the voice message."))
            return nil
        }
        // Until the preview takes it, so a cancel while the last words
        // settle still removes the file.
        pendingURL = url
        guard duration >= Self.minimumDuration else {
            recognizer?.cancel()
            recognizer = nil
            try? FileManager.default.removeItem(at: url)
            reset()
            return nil
        }
        if let recognizer {
            recognizer.endAudio()
            let timeout = recognizer.settleTimeout
            // Its final words, or what it had when time ran out.
            settling = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                self.recognizerDone()
            }
            await settling?.value
            settling = nil
        }
        guard self.generation == generation else { return nil }
        let recording = Recording(
            url: url,
            duration: duration,
            transcript: meter.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        self.recording = recording
        pendingURL = nil
        phase = .recorded
        return recording
    }

    /// Throws the message away, recorded or not.
    func cancel() {
        generation &+= 1
        let url = recording?.url ?? writer?.url ?? pendingURL
        ticker?.cancel()
        ticker = nil
        settling?.cancel()
        settling = nil
        sink.stop()
        stopAudio()
        releaseAudio()
        writer?.close()
        writer = nil
        recognizer?.cancel()
        recognizer = nil
        if let url { try? FileManager.default.removeItem(at: url) }
        reset()
    }

    /// The message went out (its file was staged as an attachment): back
    /// to idle, and the recording's own copy is removed.
    func finishSending() {
        cancel()
    }

    private func reset() {
        phase = .idle
        isHeld = false
        meter.elapsed = 0
        meter.levels = []
        meter.transcript = ""
        recording = nil
        pendingURL = nil
        startedAt = nil
        sessionID = nil
    }

    private func fail(_ message: String) {
        reset()
        errorMessage = message
    }

    private func receive(_ update: DictationUpdate, generation: UInt64) {
        guard generation == self.generation, recognizer != nil else { return }
        switch update {
        case .text(let text, let isFinal):
            if !text.isEmpty { meter.transcript = text }
            // Settled (after the stop, or a recognizer's own time limit):
            // the words so far are what the message carries.
            if isFinal { recognizerDone() }
        case .failed:
            // Recording goes on; the words so far stay.
            recognizerDone()
        }
    }

    /// The recognizer has nothing more to say.
    private func recognizerDone() {
        recognizer?.cancel()
        recognizer = nil
        sink.dropRecognizer()
        settling?.cancel()
    }

    /// The microphone went away (a phone call, Siri, a route change):
    /// keep what was recorded, ready to send.
    private func audioWasLost(generation: UInt64) {
        guard generation == self.generation, phase == .recording else { return }
        Task { await stop() }
    }

    private func tick(generation: UInt64) {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, !Task.isCancelled, self.generation == generation,
                      self.phase == .recording, let startedAt = self.startedAt else { return }
                let elapsed = Date().timeIntervalSince(startedAt)
                self.meter.elapsed = elapsed
                var levels = self.meter.levels
                levels.append(self.sink.takePeakLevel())
                if levels.count > Self.levelCount { levels.removeFirst(levels.count - Self.levelCount) }
                self.meter.levels = levels
                if elapsed >= Self.maximumDuration {
                    Task { await self.stop() }
                    return
                }
            }
        }
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

    /// Opens the microphone and returns the format its buffers come in.
    private func startAudio() throws -> AVAudioFormat {
        var format: AVAudioFormat?
        try VoiceAudioEngineRecovery.startFresh(
            rebuild: { stopAudio() },
            reassert: { try audioCoordinator.reassert() },
            start: { format = try startAudioAttempt() }
        )
        guard let format else { throw VoiceAudioInputFormatUnavailable() }
        return format
    }

    private func startAudioAttempt() throws -> AVAudioFormat {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardwareFormat = input.inputFormat(forBus: 0)
        let nodeOutputFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
              nodeOutputFormat.sampleRate > 0, nodeOutputFormat.channelCount > 0 else {
            throw VoiceAudioInputFormatUnavailable()
        }
        let tapFormat = VoiceAudioEngineRecovery.tapFormat(
            nodeOutput: nodeOutputFormat,
            hardware: hardwareFormat
        )
        let sink = sink
        input.installTap(onBus: 0, bufferSize: 1_024, format: tapFormat) { buffer, _ in
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
        return tapFormat ?? nodeOutputFormat
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

    private static func newFileURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(VoiceMessage.filePrefix)\(formatter.string(from: Date())).m4a"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceMessages", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }
}

/// The microphone's buffers, from the audio thread: into the file, to the
/// recognizer while it listens, and the loudest sample for the waveform.
private final class VoiceMessageAudioSink: @unchecked Sendable {
    private struct State {
        var writer: VoiceMessageFileWriter?
        var recognizer: (any DictationAudioInput)?
        var peak: Float = 0
        var writeFailed = false
    }

    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

    func start(writer: VoiceMessageFileWriter, recognizer: (any DictationAudioInput)?) {
        state.withLockUnchecked { state in
            state.writer = writer
            state.recognizer = recognizer
            state.peak = 0
            state.writeFailed = false
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let level = Self.peak(of: buffer)
        state.withLockUnchecked { state in
            if state.writer?.write(buffer) == false { state.writeFailed = true }
            state.recognizer?.append(buffer)
            state.peak = max(state.peak, level)
        }
    }

    /// The loudest level since the last call, 0...1.
    func takePeakLevel() -> Float {
        state.withLockUnchecked { state in
            defer { state.peak = 0 }
            return state.peak
        }
    }

    /// The recognizer is done; the file keeps recording.
    func dropRecognizer() {
        state.withLockUnchecked { state in
            state.recognizer?.end()
            state.recognizer = nil
        }
    }

    /// Returns whether any buffer failed to reach the file.
    @discardableResult
    func stop() -> Bool {
        state.withLockUnchecked { state in
            state.recognizer?.end()
            state.recognizer = nil
            state.writer = nil
            state.peak = 0
            return state.writeFailed
        }
    }

    /// A buffer's peak, scaled so speech fills most of the bar.
    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var peak: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(channel[index]))
        }
        // Speech peaks well under full scale; a square root lifts it.
        return min(1, sqrt(peak) * 1.2)
    }
}

/// An AAC file written from the microphone's buffers.
final class VoiceMessageFileWriter: @unchecked Sendable {
    let url: URL
    private let file = OSAllocatedUnfairLock<AVAudioFile?>(uncheckedState: nil)

    init(url: URL, format: AVAudioFormat) throws {
        self.url = url
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 48_000 * Int(format.channelCount),
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        self.file.withLockUnchecked { $0 = file }
    }

    /// False when the buffer couldn't be written.
    func write(_ buffer: AVAudioPCMBuffer) -> Bool {
        file.withLockUnchecked { file in
            guard let file else { return true }
            do {
                try file.write(from: buffer)
                return true
            } catch {
                return false
            }
        }
    }

    /// Finishes the file: AVAudioFile writes its header when released.
    func close() {
        file.withLockUnchecked { $0 = nil }
    }
}

/// How a voice message reads in its prompt, and back in the bubble. The
/// first line tells the agent what it has (in English, like Hermes' own
/// attachment notes); the transcript follows.
enum VoiceMessage {
    static let filePrefix = "voice-message-"

    /// The prompt text sent with the audio file.
    static func promptText(duration: TimeInterval, transcript: String) -> String {
        let length = durationLabel(duration)
        let words = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            return "[Voice message, \(length). No transcript: listen to the attached audio file if you can.]"
        }
        return "[Voice message, \(length). Transcript:]\n\(words)"
    }

    /// A sent voice message's parts, or nil for any other message.
    static func parse(_ text: String) -> (duration: String, transcript: String)? {
        guard let match = text.firstMatch(of: #/^\[Voice message, (\d+:\d{2}(?::\d{2})?)(?:\.[^\]\n]*)?\][ \t]*(?:\r?\n|$)/#) else {
            return nil
        }
        let transcript = String(text[match.range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(match.1), transcript)
    }

    /// "0:14", "12:03", "1:02:03".
    static func durationLabel(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Whether a file is a recorded voice message, by the name Conduit
    /// gives it.
    static func isVoiceMessageFile(_ name: String) -> Bool {
        // Hermes may put its own prefix on the stored name.
        (name as NSString).lastPathComponent.contains(filePrefix)
    }
}
