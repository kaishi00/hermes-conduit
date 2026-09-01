//
//  HermesVoiceGateway.swift
//  Conduit
//

import Foundation

@MainActor
final class HermesVoiceGateway: VoiceGatewayService {
    /// Mirrors Hermes Desktop's transcription request policy
    /// (apps/desktop/src/api/system.ts): remote providers and long recordings
    /// regularly exceed short request ceilings, so every request gets a
    /// generous floor that scales with the payload and clamps at a cap.
    static let transcriptionMinimumRequestTimeoutMilliseconds = 180_000
    static let transcriptionMaximumRequestTimeoutMilliseconds = 600_000
    /// The payload is the base64 audio data URL itself, so its length tracks
    /// clip size. Conduit records 16kHz mono 16-bit WAV (~42.7k base64
    /// characters per second of audio), so 0.1ms per character budgets ~4.3s
    /// of timeout per 1s of audio before the cap clamps it.
    static let transcriptionTimeoutMillisecondsPerDataURLCharacter = 0.1

    static func transcriptionRequestTimeoutMilliseconds(dataURLCharacterCount: Int) -> Int {
        let estimated = max(
            transcriptionMinimumRequestTimeoutMilliseconds,
            Int(ceil(Double(dataURLCharacterCount) * transcriptionTimeoutMillisecondsPerDataURLCharacter))
        )
        return min(transcriptionMaximumRequestTimeoutMilliseconds, estimated)
    }

    let profile: String
    private let bridge: DashboardTicketBridge
    private let baseURL: String

    init(bridge: DashboardTicketBridge, baseURL: String, profile: String) {
        self.bridge = bridge
        self.baseURL = (try? ConnectionURLPolicy.normalizedBaseURL(baseURL))
            ?? baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.profile = profile
    }

    func transcribe(_ audio: VoiceCapturedAudio) async throws -> String {
        // Base64 encoding is expensive for long recordings — build the data
        // URL once and reuse it for both the payload and the timeout budget.
        let dataURL = audio.dataURL
        let response = try await bridge.requestJSON(
            path: "/api/audio/transcribe" + profileQuery,
            method: "POST",
            body: ["data_url": dataURL, "mime_type": "audio/wav"],
            timeoutMilliseconds: Self.transcriptionRequestTimeoutMilliseconds(
                dataURLCharacterCount: dataURL.utf8.count
            )
        )
        if let error = response["error"] as? String, !error.isEmpty { throw DashboardTicketBridgeError.requestFailed(error) }
        guard let rawTranscript = response["transcript"] as? String ?? response["text"] as? String else {
            throw DashboardTicketBridgeError.requestFailed("Hermes did not return a transcription.")
        }
        // Hermes deliberately returns an empty transcript for quiet audio or
        // filtered hallucinations. The controller treats that as re-listen,
        // not a failed chat submission.
        return rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var profileQuery: String {
        DashboardPath.withProfile("", profile: profile)
    }

    func openSpeechStream(
        onStart: @escaping @MainActor (Double) throws -> Void,
        onPCM16: @escaping @MainActor (Data, Double) throws -> Void,
        onEncodedAudio: @escaping @MainActor (Data) throws -> Void
    ) async throws -> VoiceSpeechStream {
        let ticket = try await bridge.mintTicket()
        let url: URL
        do {
            url = try ConnectionURLPolicy.webSocketURL(
                baseURL: baseURL,
                path: "/api/audio/speak-stream",
                queryItems: [URLQueryItem(name: "ticket", value: ticket), URLQueryItem(name: "profile", value: profile)]
            )
        } catch {
            throw VoiceAudioError.unavailable("Could not open the speech stream.")
        }
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        return HermesSpeechStream(
            task: task,
            fallback: { [bridge, profile] text in
                try await Self.loadFallbackAudio(bridge: bridge, profile: profile, text: text)
            },
            onStart: onStart,
            onPCM16: onPCM16,
            onEncodedAudio: onEncodedAudio
        )
    }

    private static func loadFallbackAudio(bridge: DashboardTicketBridge, profile: String, text: String) async throws -> Data {
        let response = try await bridge.requestJSON(
            path: DashboardPath.withProfile("/api/audio/speak", profile: profile),
            method: "POST",
            body: ["text": text],
            timeoutMilliseconds: 90_000,
            maxResponseBytes: DataURLLimits.maxJSONResponseBytes
        )
        if let error = response["error"] as? String, !error.isEmpty { throw DashboardTicketBridgeError.requestFailed(error) }
        guard let dataURL = response["data_url"] as? String ?? response["dataUrl"] as? String,
              let data = DataURLLimits.decodeBase64DataURL(dataURL) else {
            throw DashboardTicketBridgeError.requestFailed("Hermes returned invalid fallback audio.")
        }
        return data
    }
}

@MainActor
private final class HermesSpeechStream: VoiceSpeechStream {
    private let task: URLSessionWebSocketTask
    private let fallback: @MainActor (String) async throws -> Data
    private let onStart: @MainActor (Double) throws -> Void
    private let onPCM16: @MainActor (Data, Double) throws -> Void
    private let onEncodedAudio: @MainActor (Data) throws -> Void
    private var receiveTask: Task<Void, Never>?
    private var completed: CheckedContinuation<Bool, Error>?
    private var allText = ""
    private var receivedPCM = false
    private var sampleRate = 24_000.0
    private var started = false
    private var terminalError: Error?
    private var terminal = false
    private var fallbackMode = false
    private var fallbackAttempted = false
    private var finishRequested = false
    private var cancelledByClient = false
    private var finishTimeoutTask: Task<Void, Never>?
    private var finishSendTask: Task<Void, Never>?

    init(
        task: URLSessionWebSocketTask,
        fallback: @escaping @MainActor (String) async throws -> Data,
        onStart: @escaping @MainActor (Double) throws -> Void,
        onPCM16: @escaping @MainActor (Data, Double) throws -> Void,
        onEncodedAudio: @escaping @MainActor (Data) throws -> Void
    ) {
        self.task = task
        self.fallback = fallback
        self.onStart = onStart
        self.onPCM16 = onPCM16
        self.onEncodedAudio = onEncodedAudio
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
    }

    deinit {
        finishTimeoutTask?.cancel()
        finishSendTask?.cancel()
        receiveTask?.cancel()
        task.cancel(with: .goingAway, reason: nil)
    }

    func append(_ text: String) async throws {
        guard !terminal else { throw terminalError ?? CancellationError() }
        guard !text.isEmpty else { return }
        allText += text
        if fallbackMode { return }
        try await sendJSON(["text": text])
    }

    func finish() async throws -> Bool {
        guard !terminal else {
            if let terminalError { throw terminalError }
            return receivedPCM
        }
        finishRequested = true
        return try await withCheckedThrowingContinuation { continuation in
            completed = continuation
            finishTimeoutTask?.cancel()
            finishTimeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(20)) }
                catch { return }
                guard let self, !self.terminal, !self.cancelledByClient else { return }
                if self.receivedPCM {
                    self.complete(.failure(VoiceAudioError.unavailable("Hermes speech streaming timed out.")))
                } else {
                    self.fallbackMode = true
                    // A send of {done:true} can remain suspended even after
                    // the stream timeout. Retire it before scheduling the
                    // fallback task, otherwise its occupied slot prevents
                    // fallback audio from ever starting.
                    self.finishSendTask?.cancel()
                    self.finishSendTask = nil
                    self.startFallbackIfNeeded()
                }
            }
            finishSendTask = Task { [weak self] in
                guard let self else { return }
                do {
                    guard !self.cancelledByClient, !self.terminal else { return }
                    if self.fallbackMode {
                        _ = try await self.playFallback()
                    } else {
                        try await self.sendJSON(["done": true])
                        if !Task.isCancelled { self.finishSendTask = nil }
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    guard !self.cancelledByClient, !self.terminal else { return }
                    if self.receivedPCM { self.complete(.failure(error)) }
                    else {
                        self.fallbackMode = true
                        do { _ = try await self.playFallback() }
                        catch { self.complete(.failure(error)) }
                    }
                }
            }
        }
    }

    func cancel() {
        guard !cancelledByClient else { return }
        cancelledByClient = true
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        finishSendTask?.cancel()
        finishSendTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        task.cancel(with: .goingAway, reason: nil)
        complete(.failure(CancellationError()))
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else { throw VoiceAudioError.unavailable("Could not encode speech request.") }
        // Hermes uses receive_json(), so these must be WebSocket text frames.
        try await task.send(.string(string))
    }

    private func receiveLoop() async {
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                switch message {
                case .data(let data):
                    if let control = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        try handleControl(control)
                    } else if !data.isEmpty {
                        try emitPCM(data)
                    }
                case .string(let string):
                    guard let data = string.data(using: .utf8),
                          let control = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    try handleControl(control)
                @unknown default:
                    continue
                }
            }
        } catch is CancellationError {
            guard !terminal, !cancelledByClient else { return }
            if !receivedPCM { fallbackMode = true; startFallbackIfNeeded() }
        } catch {
            guard !terminal, !cancelledByClient else { return }
            if !receivedPCM { fallbackMode = true; startFallbackIfNeeded() }
            else { complete(.failure(error)) }
        }
    }

    private func handleControl(_ object: [String: Any]) throws {
        guard !terminal, !cancelledByClient else { return }
        switch object["type"] as? String {
        case "start":
            sampleRate = object["sample_rate"] as? Double ?? object["sampleRate"] as? Double ?? 24_000
            if !started { try onStart(sampleRate); started = true }
        case "end":
            complete(.success(receivedPCM))
        case "fallback":
            fallbackMode = true
            task.cancel(with: .goingAway, reason: nil)
            startFallbackIfNeeded()
        case "error":
            complete(.failure(DashboardTicketBridgeError.requestFailed(object["message"] as? String ?? "Hermes speech stream failed.")))
        default:
            break
        }
    }

    private func emitPCM(_ data: Data) throws {
        guard !terminal, !cancelledByClient else { return }
        if !started { try onStart(sampleRate); started = true }
        try onPCM16(data, sampleRate)
        receivedPCM = true
    }

    private func playFallback() async throws -> Bool {
        guard !cancelledByClient, !terminal else { throw CancellationError() }
        guard !receivedPCM else { return true }
        guard !fallbackAttempted else { return false }
        fallbackAttempted = true
        let data = try await fallback(allText)
        guard !cancelledByClient, !terminal else { throw CancellationError() }
        try onEncodedAudio(data)
        complete(.success(false))
        return false
    }

    private func startFallbackIfNeeded() {
        guard !terminal, !cancelledByClient, finishRequested, !fallbackAttempted, finishSendTask == nil else { return }
        finishSendTask = Task { [weak self] in
            guard let self else { return }
            do { _ = try await self.playFallback() }
            catch {
                guard !self.cancelledByClient, !self.terminal else { return }
                self.complete(.failure(error))
            }
        }
    }

    private func complete(_ result: Result<Bool, Error>) {
        guard !terminal else { return }
        terminal = true
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        finishSendTask?.cancel()
        finishSendTask = nil
        if case .failure(let error) = result { terminalError = error }
        let continuation = completed
        completed = nil
        continuation?.resume(with: result)
    }
}
