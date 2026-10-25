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
import CallKit
import Foundation
import OSLog
import os
import Speech

private let wakeLogger = Logger(subsystem: "com.milim.relay", category: "VoiceWake")

@MainActor
final class AppleSpeechWakeWordService: WakeWordService {
    /// The phrases to listen for. Updated in place while armed.
    var bindings: [WakePhraseBinding] = [] {
        didSet {
            guard bindings != oldValue, isArmed else { return }
            // New phrases also become recognition hints on the next cycle,
            // and one in another language brings its recognizer.
            makeRecognizers()
            guard !recognizers.isEmpty else {
                // No phrase left that a recognizer here hears: stop, as
                // arming would, rather than keep the old phrases' cycle.
                recordFailure(unheardReason())
                return
            }
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
    /// One recognizer per language the phrases are heard in, each with
    /// its phrases as hints. They all hear the same microphone.
    private var recognizers: [WakeRecognizer] = []
    private var engine: AVAudioEngine?
    private var lease: VoiceAudioLease?
    private var recognitionTasks: [SFSpeechRecognitionTask] = []
    private var cycleTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var cycleGeneration: UInt64 = 0
    private var consecutiveFailures = 0
    /// This listener set the session's preferred input (CarPlay) and must
    /// clear it before handing the session back.
    private var prefersBuiltInMicrophone = false
    /// A system interruption (a call, Siri) is in progress.
    private var isInterrupted = false
    private var observers: [NSObjectProtocol] = []
    private var engineObserver: NSObjectProtocol?
    /// Which engine a configuration change belongs to: a change already
    /// queued for an engine this listener stopped or replaced is dropped.
    private var engineGeneration: UInt64 = 0

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
        makeRecognizers()
        guard !recognizers.isEmpty else {
            throw WakeWordServiceError.unavailable(unheardReason())
        }
        isArmed = true
        consecutiveFailures = 0
        do {
            try startAudio()
        } catch {
            stopEverything()
            wakeLogger.error("wake audio start failed: \(LogRedaction.message(error), privacy: .public)")
            throw WakeWordServiceError.unavailable(AppLocalization.string("Wake listening couldn't use the microphone. Close other apps using it, then try again."))
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
        try VoiceAudioEngineRecovery.startFresh(
            rebuild: { stopAudio() },
            reassert: { try audioCoordinator.reassert() },
            start: {
                try applyPreferredInput()
                try startAudioAttempt()
            }
        )
    }

    private func startAudioAttempt() throws {
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
        let sink = audioSink
        input.installTap(onBus: 0, bufferSize: 1_024, format: tapFormat) { buffer, _ in
            // Runs on the audio render thread. The buffer request accepts
            // appends from any thread; the sink only guards the swap.
            sink.append(buffer)
        }
        self.engine = engine
        observeConfigurationChanges(of: engine)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stopAudio()
            throw error
        }
    }

    private func stopAudio() {
        stopObservingConfigurationChanges()
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// A route change reconfigures the engine and stops it: rebuild it.
    /// Only this listener's engine: another engine in the app reconfiguring
    /// must not restart the microphone, and every restart re-activates the
    /// session, which makes other apps' audio drop out for a moment. As in
    /// AVSpeechPlaybackService, the handler never reads the notification's
    /// object; the captured generation says whose change it was.
    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        stopObservingConfigurationChanges()
        let generation = engineGeneration
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.engineGeneration == generation else { return }
                self.scheduleAudioRecovery()
            }
        }
    }

    private func stopObservingConfigurationChanges() {
        engineGeneration &+= 1
        guard let engineObserver else { return }
        NotificationCenter.default.removeObserver(engineObserver)
        self.engineObserver = nil
    }

    /// On CarPlay, record from the iPhone's own microphone: recording
    /// through the car switches it to a voice stream, and music from other
    /// apps then plays from one side only. Elsewhere, the system default.
    /// Never falls back to the car's microphone: that is what plays other
    /// apps' music from one side, so wake stops instead.
    private func applyPreferredInput() throws {
        guard WakeRoutePolicy.currentRouteIsCarPlay() else {
            clearPreferredInput()
            return
        }
        let session = AVAudioSession.sharedInstance()
        guard let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
            throw WakeWordServiceError.unavailable(
                AppLocalization.string("Wake listening on CarPlay needs the iPhone's microphone, which is not available right now.")
            )
        }
        try session.setPreferredInput(builtIn)
        prefersBuiltInMicrophone = true
    }

    /// A conversation that takes the session over uses the car's own
    /// microphone again.
    private func clearPreferredInput() {
        guard prefersBuiltInMicrophone else { return }
        prefersBuiltInMicrophone = false
        do {
            try AVAudioSession.sharedInstance().setPreferredInput(nil)
        } catch {
            wakeLogger.error("wake listening could not clear its preferred input: \(LogRedaction.message(error), privacy: .public)")
        }
    }

    private func observeAudioDisruptions() {
        removeObservers()
        let center = NotificationCenter.default
        // Connecting or leaving CarPlay changes which microphone wake must
        // use, even if the engine does not report a configuration change.
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if WakeRoutePolicy.currentRouteIsCarPlay() != self.prefersBuiltInMicrophone {
                    self.scheduleAudioRecovery()
                }
            }
        })
        // A phone call, Siri or an alarm is not a Conduit audio owner: stop
        // listening for its whole duration and only resume once it ends.
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = rawType.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            Task { @MainActor [weak self] in self?.handleInterruption(type) }
        })
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        guard isArmed else { return }
        switch type {
        case .began:
            isInterrupted = true
            watchInterruption()
            cycleGeneration &+= 1
            cycleTask?.cancel()
            cycleTask = nil
            audioSink.replace(with: [])
            cancelRecognition()
            stopAudio()
        case .ended:
            // The watchdog may have resumed already: nothing to recover.
            guard isInterrupted else { return }
            isInterrupted = false
            recoveryTask?.cancel()
            recoveryTask = nil
            scheduleAudioRecovery()
        default:
            break
        }
    }

    /// Watchdog for an `.ended` iOS never posts. It resumes only on
    /// evidence the interruption is over: no phone call in progress (a
    /// CarPlay call can run for an hour), no other Conduit audio owner,
    /// and the session activating again. Otherwise it keeps waiting, with
    /// the interruption observer in place for the real `.ended` (#1004).
    private func watchInterruption() {
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.interruptionWatchdogInterval)
            guard let self, !Task.isCancelled, self.isArmed, self.isInterrupted else { return }
            self.recoveryTask = nil
            guard !Self.isPhoneCallInProgress(),
                  !self.audioCoordinator.hasOwnersOtherThanWakeListening else {
                self.watchInterruption()
                return
            }
            do {
                try self.audioCoordinator.reassert()
                try self.startAudio()
            } catch {
                // The session is still held elsewhere: still interrupted.
                self.stopAudio()
                self.watchInterruption()
                return
            }
            wakeLogger.info("wake listening resumed after an interruption without an end")
            self.isInterrupted = false
            self.startRecognitionCycle()
        }
    }

    private static let interruptionWatchdogInterval: Duration = .seconds(60)
    private static let callObserver = CXCallObserver()

    private static func isPhoneCallInProgress() -> Bool {
        callObserver.calls.contains { !$0.hasEnded }
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func scheduleAudioRecovery() {
        guard isArmed, !isInterrupted, recoveryTask == nil else { return }
        recoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.recoveryTask = nil
            guard self.isArmed, !self.isInterrupted else { return }
            // Another owner (a call, Read Aloud) has the session: AppState
            // disarms the listener for it, so do not fight over the route.
            guard !self.audioCoordinator.hasOwnersOtherThanWakeListening else { return }
            self.stopAudio()
            do {
                try self.audioCoordinator.reassert()
                try self.startAudio()
                self.startRecognitionCycle()
            } catch {
                wakeLogger.error("wake audio restart failed: \(LogRedaction.message(error), privacy: .public)")
                self.recordFailure(AppLocalization.string("Wake listening couldn't use the microphone. Close other apps using it, then try again."))
            }
        }
    }

    // MARK: - Recognition

    /// A recognizer for each language the usable phrases are heard in
    /// (WakeSpeechLocale): Latin-letter phrases in the app's locale, and a
    /// phrase in another writing system in a language that writes it. A
    /// phrase no on-device recognizer here writes is left out; Settings
    /// says so beside it.
    private func makeRecognizers() {
        let phrases = bindings.map(\.phrase).filter(WakePhraseMatcher.isUsable)
        recognizers = WakeSpeechLocale.listening(for: phrases).compactMap { group -> WakeRecognizer? in
            // Reused while its language stays, so a phrase edit doesn't
            // rebuild a recognizer that is listening.
            let recognizer = recognizers.first(where: { $0.locale.identifier == group.locale.identifier })?.recognizer
                ?? SFSpeechRecognizer(locale: group.locale)
            guard let recognizer, recognizer.supportsOnDeviceRecognition else { return nil }
            return WakeRecognizer(locale: group.locale, recognizer: recognizer, phrases: group.phrases)
        }
    }

    /// Why no recognizer hears the phrases: the phrase's own language when
    /// that's what is missing, as Settings says beside it.
    private func unheardReason() -> String {
        let phrases = bindings.map(\.phrase).filter(WakePhraseMatcher.isUsable)
        if let note = phrases.lazy.compactMap({ WakeSpeechLocale.note(for: $0, among: phrases) }).first {
            return note.text
        }
        let locale = Locale.current
        return AppLocalization.string("On-device Apple speech recognition is unavailable for \(locale.identifier).")
    }

    private func cancelRecognition() {
        for task in recognitionTasks { task.cancel() }
        recognitionTasks = []
    }

    private func startRecognitionCycle() {
        guard isArmed, !recognizers.isEmpty else { return }
        cycleGeneration &+= 1
        let generation = cycleGeneration
        cancelRecognition()
        cycleTask?.cancel()

        var requests: [SFSpeechAudioBufferRecognitionRequest] = []
        for wake in recognizers {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.taskHint = .search
            // Bias the recognizer toward its bound phrases (profile names
            // are often unusual words).
            request.contextualStrings = wake.phrases
            requests.append(request)
            recognitionTasks.append(wake.recognizer.recognitionTask(with: request) { [weak self] result, error in
                let transcript = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let failed = error != nil
                Task { @MainActor [weak self] in
                    self?.receive(transcript: transcript, isFinal: isFinal, failed: failed, generation: generation)
                }
            })
        }
        audioSink.replace(with: requests)
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
        if isFinal {
            // Restart on a later turn, never from inside this task's own
            // result delivery.
            cycleTask?.cancel()
            cycleTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !Task.isCancelled, self.cycleGeneration == generation else { return }
                self.startRecognitionCycle()
            }
        }
    }

    private func recordFailure(_ message: String) {
        wakeLogger.error("wake listening stopped: \(message, privacy: .public)")
        stopEverything()
        onFailure?(message)
    }

    private func stopEverything() {
        isArmed = false
        isInterrupted = false
        cycleGeneration &+= 1
        cycleTask?.cancel()
        cycleTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        removeObservers()
        audioSink.replace(with: [])
        cancelRecognition()
        recognizers = []
        stopAudio()
        clearPreferredInput()
        if let lease {
            self.lease = nil
            audioCoordinator.release(lease)
        }
    }
}

/// One language's recognizer and the phrases it listens for.
private struct WakeRecognizer {
    let locale: Locale
    let recognizer: SFSpeechRecognizer
    var phrases: [String]
}

/// Hands microphone buffers from the render thread to the current
/// recognition requests, one per language.
private final class WakeAudioSink: @unchecked Sendable {
    /// An unfair lock: the render thread only ever waits for a request swap,
    /// never for a contended mutex with priority inversion.
    private let state = OSAllocatedUnfairLock<[SFSpeechAudioBufferRecognitionRequest]>(uncheckedState: [])

    /// Both calls hold the lock for the whole operation, so a render-thread
    /// append never runs concurrently with endAudio on the same request.
    func replace(with newRequests: [SFSpeechAudioBufferRecognitionRequest]) {
        state.withLockUnchecked { requests in
            for request in requests { request.endAudio() }
            requests = newRequests
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        state.withLockUnchecked { requests in
            for request in requests { request.append(buffer) }
        }
    }
}
