//
//  AppleSpeechWakeWordService.swift
//  Conduit
//
//  Foreground wake phrase listening (#174) on Apple's on-device speech
//  recognizer. Audio never leaves the phone: `requiresOnDeviceRecognition`
//  is always set, and nothing is recorded or kept. The listener runs only
//  while AppState's wake lifecycle says so (Conduit in the foreground, no
//  call or other audio running).
//

import AVFAudio
import Foundation
import OSLog
import Speech

private let wakeLogger = Logger(subsystem: "com.milim.relay", category: "VoiceWake")

@MainActor
final class AppleSpeechWakeWordService: WakeWordService {
    /// The phrases to listen for. Updated in place while armed.
    var bindings: [WakePhraseBinding] = [] {
        didSet {
            guard bindings != oldValue, isArmed else { return }
            // New phrases also become recognition hints on the next cycle.
            startRecognitionCycle()
        }
    }
    /// Called once per detection, after the listener has fully stopped and
    /// released the microphone, so a voice conversation can take it over.
    var onDetection: ((WakePhraseBinding) -> Void)?
    /// Called when the listener stopped on its own (audio or recognizer
    /// failure it could not recover from).
    var onFailure: ((String) -> Void)?

    private(set) var isArmed = false

    /// How long one recognition request runs before a fresh one replaces it,
    /// so partial transcripts stay short and matching stays cheap.
    private let cycleDuration: Duration
    private let audioCoordinator: VoiceAudioSessionCoordinator
    private let audioSink = WakeAudioSink()
    private var recognizer: SFSpeechRecognizer?
    private var engine: AVAudioEngine?
    private var lease: VoiceAudioLease?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var cycleTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var cycleGeneration: UInt64 = 0
    private var consecutiveFailures = 0
    private var observers: [NSObjectProtocol] = []

    private static let maximumConsecutiveFailures = 5

    init(
        audioCoordinator: VoiceAudioSessionCoordinator? = nil,
        cycleDuration: Duration = .seconds(30)
    ) {
        self.audioCoordinator = audioCoordinator ?? .shared
        self.cycleDuration = cycleDuration
    }

    static var isSpeechAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    static var isMicrophoneAuthorized: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// Asks for whichever of microphone and speech recognition access is
    /// still undecided. Returns true when both are granted.
    static func requestPermissions() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            let _: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status) }
            }
        }
        if AVAudioApplication.shared.recordPermission == .undetermined {
            _ = await AVAudioApplication.requestRecordPermission()
        }
        return isSpeechAuthorized && isMicrophoneAuthorized
    }

    func arm() throws {
        guard !isArmed else { return }
        guard bindings.contains(where: { WakePhraseMatcher.isUsable($0.phrase) }) else {
            throw WakeWordServiceError.notPrepared
        }
        guard Self.isSpeechAuthorized, Self.isMicrophoneAuthorized else {
            throw WakeWordServiceError.unavailable(
                AppLocalization.string("Wake phrases need microphone and speech recognition access.")
            )
        }
        let locale = Locale.current
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw WakeWordServiceError.unavailable(
                AppLocalization.string("On-device Apple speech recognition is unavailable for \(locale.identifier).")
            )
        }
        self.recognizer = recognizer
        isArmed = true
        consecutiveFailures = 0
        do {
            try startAudio()
        } catch {
            stopEverything()
            throw WakeWordServiceError.unavailable(error.localizedDescription)
        }
        observeAudioDisruptions()
        startRecognitionCycle()
        wakeLogger.info("wake listening armed with \(self.bindings.count, privacy: .public) phrase(s)")
    }

    func disarm() {
        guard isArmed || engine != nil || lease != nil else { return }
        stopEverything()
        wakeLogger.info("wake listening disarmed")
    }

    // MARK: - Audio

    private func startAudio() throws {
        if lease == nil {
            lease = try audioCoordinator.acquire(.wakeListening)
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw WakeWordServiceError.unavailable(
                AppLocalization.string("The microphone is not available right now.")
            )
        }
        let sink = audioSink
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            // Runs on the audio render thread. The buffer request accepts
            // appends from any thread; the sink only guards the swap.
            sink.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
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

    private func observeAudioDisruptions() {
        removeObservers()
        let center = NotificationCenter.default
        // A route change or another app taking the session reconfigures the
        // engine and stops it; an interruption (a phone call) does the same.
        for name in [Notification.Name.AVAudioEngineConfigurationChange, AVAudioSession.interruptionNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleAudioRecovery() }
            })
        }
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func scheduleAudioRecovery() {
        guard isArmed, recoveryTask == nil else { return }
        recoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.recoveryTask = nil
            guard self.isArmed else { return }
            // Another owner (a call, Read Aloud) has the session: AppState
            // disarms the listener for it, so do not fight over the route.
            guard !self.audioCoordinator.hasOwnersOtherThanWakeListening else { return }
            self.stopAudio()
            do {
                try self.audioCoordinator.reassert()
                try self.startAudio()
                self.startRecognitionCycle()
            } catch {
                self.recordFailure(error.localizedDescription)
            }
        }
    }

    // MARK: - Recognition

    private func startRecognitionCycle() {
        guard isArmed, let recognizer else { return }
        cycleGeneration &+= 1
        let generation = cycleGeneration
        recognitionTask?.cancel()
        recognitionTask = nil
        cycleTask?.cancel()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .search
        // Bias the recognizer toward the bound phrases (profile names are
        // often unusual words).
        request.contextualStrings = bindings.map(\.phrase)
        audioSink.replace(with: request)

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                self?.receive(transcript: transcript, isFinal: isFinal, failed: failed, generation: generation)
            }
        }
        cycleTask = Task { @MainActor [weak self, cycleDuration] in
            try? await Task.sleep(for: cycleDuration)
            guard let self, !Task.isCancelled, self.cycleGeneration == generation else { return }
            self.startRecognitionCycle()
        }
    }

    private func receive(transcript: String?, isFinal: Bool, failed: Bool, generation: UInt64) {
        guard isArmed, generation == cycleGeneration else { return }
        if let transcript, let binding = WakePhraseMatcher.match(transcript: transcript, bindings: bindings) {
            wakeLogger.info("wake phrase detected for profile \(binding.key.profileID, privacy: .private)")
            stopEverything()
            onDetection?(binding)
            return
        }
        if failed {
            consecutiveFailures += 1
            guard consecutiveFailures < Self.maximumConsecutiveFailures else {
                recordFailure(AppLocalization.string("Apple speech recognition is temporarily unavailable."))
                return
            }
            cycleTask?.cancel()
            cycleTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.cycleGeneration == generation else { return }
                self.startRecognitionCycle()
            }
            return
        }
        if transcript?.isEmpty == false { consecutiveFailures = 0 }
        if isFinal { startRecognitionCycle() }
    }

    private func recordFailure(_ message: String) {
        wakeLogger.error("wake listening stopped: \(message, privacy: .public)")
        stopEverything()
        onFailure?(message)
    }

    private func stopEverything() {
        isArmed = false
        cycleGeneration &+= 1
        cycleTask?.cancel()
        cycleTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        removeObservers()
        audioSink.replace(with: nil)
        recognitionTask?.cancel()
        recognitionTask = nil
        stopAudio()
        if let lease {
            self.lease = nil
            audioCoordinator.release(lease)
        }
    }
}

/// Hands microphone buffers from the render thread to whichever recognition
/// request is current.
private final class WakeAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func replace(with newRequest: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        let old = request
        request = newRequest
        lock.unlock()
        old?.endAudio()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        lock.unlock()
        current?.append(buffer)
    }
}
