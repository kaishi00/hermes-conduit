//
//  AppleOnDeviceSpeechTranscriber.swift
//  Conduit
//

import Foundation
import OSLog
import Speech

private let speechTranscriberLogger = Logger(subsystem: "com.milim.relay", category: "VoiceSpeech")

/// A zero-configuration transcription route backed by Apple's system-managed
/// speech model. `requiresOnDeviceRecognition` is always true: Conduit never
/// silently sends audio to Apple's recognition servers.
@MainActor
final class AppleOnDeviceSpeechTranscriber: DeviceSpeechTranscriptionService {
    private var recognitionTask: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String, Error>?
    private var temporaryAudioURL: URL?

    static func currentAvailability(locale: Locale = SpeechRecognitionLocale.preferred(accepts: SpeechRecognitionLocale.recognizesOnDevice)) -> AppleSpeechRecognitionAvailability {
        let identifier = locale.identifier
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            return .unsupported(localeIdentifier: identifier)
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .ready(localeIdentifier: identifier)
        case .notDetermined: return .permissionRequired(localeIdentifier: identifier)
        case .denied, .restricted: return .permissionDenied
        @unknown default: return .unsupported(localeIdentifier: identifier)
        }
    }

    func requestPermission() async -> Bool {
        await requestAuthorization() == .authorized
    }

    func transcribe(_ audio: VoiceCapturedAudio) async throws -> String {
        cancel()
        let locale = SpeechRecognitionLocale.preferred(accepts: SpeechRecognitionLocale.recognizesOnDevice)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw VoiceAudioError.unavailable(AppLocalization.string("On-device Apple speech recognition is unavailable for \(locale.identifier)."))
        }
        guard await requestPermission() else {
            throw VoiceAudioError.unavailable(AppLocalization.string("Speech Recognition permission is required for on-device transcription."))
        }
        guard recognizer.isAvailable else {
            throw VoiceAudioError.unavailable(AppLocalization.string("Apple speech recognition is temporarily unavailable."))
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-speech-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        do {
            try audio.wavData.write(to: url, options: .atomic)
        } catch {
            throw VoiceAudioError.unavailable(AppLocalization.string("Conduit could not prepare captured audio for transcription."))
        }
        temporaryAudioURL = url

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.addsPunctuation = true

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    let transcript = result?.bestTranscription.formattedString
                    let isFinal = result?.isFinal ?? false
                    let errorDescription = error?.localizedDescription
                    Task { @MainActor [weak self] in
                        self?.receive(transcript: transcript, isFinal: isFinal, errorDescription: errorDescription)
                    }
                }
                if Task.isCancelled { self.cancel() }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() {
        recognitionTask?.cancel()
        recognitionTask = nil
        complete(.failure(CancellationError()))
    }

    private func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func receive(transcript: String?, isFinal: Bool, errorDescription: String?) {
        if let errorDescription {
            // The framework's text ("kAFAssistantErrorDomain error 1101") is for
            // the log; the person gets what to try.
            speechTranscriberLogger.error("on-device recognition failed: \(errorDescription, privacy: .public)")
            complete(.failure(VoiceAudioError.unavailable(AppLocalization.string("Apple speech recognition stopped. Try again, or choose another speech-to-text option in Settings > Voice."))))
            return
        }
        guard isFinal else { return }
        let text = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            complete(.failure(VoiceAudioError.noAudioCaptured))
            return
        }
        complete(.success(text))
    }

    private func complete(_ result: Result<String, Error>) {
        guard let continuation else {
            removeTemporaryAudio()
            return
        }
        self.continuation = nil
        recognitionTask = nil
        removeTemporaryAudio()
        continuation.resume(with: result)
    }

    private func removeTemporaryAudio() {
        guard let temporaryAudioURL else { return }
        self.temporaryAudioURL = nil
        try? FileManager.default.removeItem(at: temporaryAudioURL)
    }
}
