//
//  SpeechServerTranscription.swift
//  Conduit
//

import Foundation

/// Speech-to-text through the user's own speech server: Hugging Face
/// speech-to-speech, the one Hermes Live Voice's local mode runs, or any
/// server speaking the OpenAI Realtime WebSocket protocol. Conduit reaches
/// it only through the notifier's relay on the Hermes host
/// (`/api/plugins/conduit_push/speech-server/socket`), so the server can sit
/// on another machine on the user's network without being exposed.
///
/// One socket per utterance. Conduit asks for transcription only
/// (`create_response: false`, so the server never runs its own model or
/// voice), streams 24 kHz PCM16, and collects every finished segment the
/// server's turn detector produces. At the end of speech it sends a little
/// silence so the detector closes the last segment, then waits until every
/// segment that started has finished.
@MainActor
final class SpeechServerTranscription: VoiceLiveTranscription {
    static let socketPath = "/api/plugins/conduit_push/speech-server/socket"
    static let statusPath = "/api/plugins/conduit_push/speech-server/status"
    static let testPath = "/api/plugins/conduit_push/speech-server/test"
    /// What the speech server is sent: the OpenAI Realtime input rate.
    static let inputSampleRate: Double = 24_000
    /// Trailing silence at the end of speech, longer than a typical turn
    /// detector's silence window.
    static let trailingSilence = Data(count: Int(inputSampleRate * 0.8) * 2)

    private enum Outcome {
        case finished(String?)
        case failed(String)
    }

    private let socket: any HermesSpeechSocket
    private let captureSampleRate: Double
    private let finishTimeout: Duration
    /// How long to allow more segments to start after the last audio is
    /// sent: earlier completed segments do not prove the final audio was
    /// processed.
    private let quietGrace: Duration
    private let onPartial: @MainActor (String) -> Void
    private let onFailure: @MainActor (String) -> Void
    private var receiveTask: Task<Void, Never>?
    /// Sends run one after another so frames reach the server in order.
    private var sendChain: Task<Void, Never>?
    private var outcome: Outcome?
    private var waiter: CheckedContinuation<String?, Never>?
    private var ended = false
    private var quietGraceElapsed = false
    private var startedSegments = 0
    private var finishedSegments = 0
    /// Finished transcripts in the order the server produced them.
    private var segments: [String] = []
    /// The segment being recognized, built from deltas.
    private var pendingText = ""
    private var lastError: String?
    /// What the screen shows, so a segment that failed can clear its words.
    private var publishedPartial = ""

    init(
        socket: any HermesSpeechSocket,
        sampleRate: Double,
        finishTimeout: Duration = .seconds(12),
        quietGrace: Duration = .seconds(2),
        onPartial: @escaping @MainActor (String) -> Void,
        onFailure: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.socket = socket
        self.captureSampleRate = sampleRate
        self.finishTimeout = finishTimeout
        self.quietGrace = quietGrace
        self.onPartial = onPartial
        self.onFailure = onFailure
        if let update = try? Self.encode(Self.sessionUpdate) {
            enqueue(.string(update))
        }
        receiveTask = Task { @MainActor [weak self] in await self?.receiveLoop() }
    }

    deinit {
        receiveTask?.cancel()
        sendChain?.cancel()
        socket.cancel(with: .goingAway, reason: nil)
    }

    /// Transcription only: the server's own model and voice stay idle.
    static var sessionUpdate: [String: Any] {
        let format: [String: Any] = ["type": "audio/pcm", "rate": Int(inputSampleRate)]
        let turnDetection: [String: Any] = [
            "type": "server_vad",
            "create_response": false,
            "interrupt_response": false,
        ]
        let input: [String: Any] = ["format": format, "turn_detection": turnDetection]
        let session: [String: Any] = ["type": "realtime", "audio": ["input": input] as [String: Any]]
        return ["type": "session.update", "session": session]
    }

    func push(_ pcm16: Data) {
        guard outcome == nil, !ended, !pcm16.isEmpty else { return }
        sendAudio(pcm16)
    }

    /// Every finished segment joined, or nil when nothing was recognized or
    /// the server failed (the reason goes to `onFailure`).
    func finish() async -> String? {
        if let outcome { return Self.transcript(outcome) }
        guard !ended else { return nil }
        ended = true
        enqueueAudio(Self.trailingSilence)
        if let commit = try? Self.encode(["type": "input_audio_buffer.commit"]) {
            enqueue(.string(commit))
        }
        let timeout = Task { @MainActor [weak self, finishTimeout] in
            try? await Task.sleep(for: finishTimeout)
            guard !Task.isCancelled, let self else { return }
            if self.segments.isEmpty {
                self.resolve(.failed(self.lastError ?? AppLocalization.string("Your speech server didn't send any words back in time.")))
            } else {
                self.resolve(.finished(self.joinedTranscript))
            }
        }
        // The grace runs from when the last audio went out: a whole short
        // recording sent at once can take a while on a slow uplink.
        let sent = sendChain
        let grace = Task { @MainActor [weak self, quietGrace] in
            await sent?.value
            try? await Task.sleep(for: quietGrace)
            guard !Task.isCancelled, let self else { return }
            self.quietGraceElapsed = true
            self.resolveIfSettled()
        }
        defer {
            timeout.cancel()
            grace.cancel()
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let outcome {
                    continuation.resume(returning: Self.transcript(outcome))
                } else if Task.isCancelled {
                    resolve(.finished(nil))
                    continuation.resume(returning: nil)
                } else {
                    waiter = continuation
                    resolveIfSettled()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() {
        ended = true
        resolve(.finished(nil))
    }

    /// Captured audio in frames of at most a second, so a backlog (the
    /// pre-roll, or a whole short utterance) stays under the relay's frame cap.
    private func sendAudio(_ pcm16: Data) {
        let chunkBytes = max(2, Int(captureSampleRate) * 2)
        var offset = pcm16.startIndex
        while offset < pcm16.endIndex {
            let end = pcm16.index(offset, offsetBy: chunkBytes, limitedBy: pcm16.endIndex) ?? pcm16.endIndex
            let chunk = pcm16.subdata(in: offset..<end)
            enqueueAudio(Self.resampled(chunk, from: captureSampleRate))
            offset = end
        }
    }

    /// Capture audio at the server's 24 kHz input rate. Conduit captures at
    /// 16 kHz (the Grok Live 3:2 path); any other rate is resampled linearly.
    static func resampled(_ pcm16: Data, from rate: Double) -> Data {
        if rate == inputSampleRate { return pcm16 }
        if rate == 16_000 { return GrokLiveProtocol.upsampledForInput(pcm16) }
        guard rate > 0 else { return Data() }
        let samples: [Int16] = pcm16.withUnsafeBytes { raw in
            (0..<(raw.count / 2)).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) }
        }
        guard samples.count > 1 else { return Data() }
        let step = rate / inputSampleRate
        let count = Int((Double(samples.count) / step).rounded(.down))
        var output = Data(capacity: count * 2)
        for index in 0..<count {
            let position = Double(index) * step
            let lower = min(Int(position), samples.count - 1)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = position - Double(lower)
            let value = Double(samples[lower]) * (1 - fraction) + Double(samples[upper]) * fraction
            var sample = Int16(max(-32_768, min(32_767, value.rounded()))).littleEndian
            withUnsafeBytes(of: &sample) { output.append(contentsOf: $0) }
        }
        return output
    }

    private func enqueueAudio(_ pcm24: Data) {
        guard !pcm24.isEmpty, let frame = try? Self.encode([
            "type": "input_audio_buffer.append",
            "audio": pcm24.base64EncodedString(),
        ]) else { return }
        enqueue(.string(frame))
    }

    private func enqueue(_ message: URLSessionWebSocketTask.Message) {
        let previous = sendChain
        sendChain = Task { @MainActor [weak self, socket] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try await socket.send(message)
            } catch {
                self?.resolve(.failed(AppLocalization.string("Lost the connection to your speech server.")))
            }
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled, outcome == nil {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                handleClose()
                return
            }
            guard let frame = Self.frame(message), let type = frame["type"] as? String else { continue }
            handle(type: type, frame: frame)
        }
    }

    private func handle(type: String, frame: [String: Any]) {
        switch type {
        case "input_audio_buffer.speech_started":
            startedSegments += 1
        case "conversation.item.input_audio_transcription.delta":
            pendingText += frame["delta"] as? String ?? ""
            publishPartial()
        case "conversation.item.input_audio_transcription.completed":
            let text = (frame["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { segments.append(text) }
            pendingText = ""
            finishedSegments += 1
            // A server that never reports speech_started still settles.
            startedSegments = max(startedSegments, finishedSegments)
            publishPartial()
            resolveIfSettled()
        case "conversation.item.input_audio_transcription.failed":
            pendingText = ""
            finishedSegments += 1
            startedSegments = max(startedSegments, finishedSegments)
            lastError = Self.errorMessage(frame) ?? lastError
            publishPartial()
            resolveIfSettled()
        case "error":
            // A refused commit on an empty buffer is expected after a
            // segment already closed; anything else is kept as the reason
            // if no words come.
            if let message = Self.errorMessage(frame), !Self.isEmptyCommit(frame) {
                lastError = AppLocalization.string("Your speech server reported: \(message)")
            }
        default:
            break
        }
    }

    private func publishPartial() {
        let text = (segments + [pendingText])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard text != publishedPartial, outcome == nil else { return }
        publishedPartial = text
        onPartial(text)
    }

    /// After the final audio and the quiet grace: every started segment
    /// has finished.
    private func resolveIfSettled() {
        guard ended, quietGraceElapsed, outcome == nil,
              finishedSegments >= startedSegments else { return }
        resolve(.finished(joinedTranscript))
    }

    private func handleClose() {
        guard outcome == nil else { return }
        // Every segment the server started has finished: what it heard is
        // complete, even if that was nothing, so a close during the quiet
        // grace is no failure.
        if ended, startedSegments > 0, finishedSegments >= startedSegments {
            resolve(.finished(joinedTranscript))
        } else {
            resolve(.failed(lastError ?? AppLocalization.string("Lost the connection to your speech server.")))
        }
    }

    private var joinedTranscript: String? {
        let text = segments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func resolve(_ result: Outcome) {
        guard outcome == nil else { return }
        outcome = result
        if case .failed(let reason) = result { onFailure(reason) }
        waiter?.resume(returning: Self.transcript(result))
        waiter = nil
        receiveTask?.cancel()
        // Frames still queued have nowhere to go.
        sendChain?.cancel()
        socket.cancel(with: .normalClosure, reason: nil)
    }

    private static func transcript(_ outcome: Outcome) -> String? {
        guard case .finished(let text) = outcome else { return nil }
        return text
    }

    private static func errorMessage(_ frame: [String: Any]) -> String? {
        let error = frame["error"] as? [String: Any]
        let message = (error?["message"] as? String ?? frame["message"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let message, !message.isEmpty else { return nil }
        return String(message.prefix(200))
    }

    private static func isEmptyCommit(_ frame: [String: Any]) -> Bool {
        let error = frame["error"] as? [String: Any]
        let code = error?["code"] as? String ?? error?["type"] as? String ?? ""
        return code.contains("commit_empty") || code.contains("buffer_too_small")
    }

    static func encode(_ message: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func frame(_ message: URLSessionWebSocketTask.Message) -> [String: Any]? {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum VoiceSpeechServerError: LocalizedError, Equatable {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

/// A gateway that can open the user's speech server through the relay.
@MainActor
protocol SpeechServerTranscriptionGateway: AnyObject {
    func openSpeechServerTranscription(
        sampleRate: Double,
        onPartial: @escaping @MainActor (String) -> Void,
        onFailure: @escaping @MainActor (String) -> Void
    ) async -> VoiceLiveTranscription?
}

extension HermesVoiceGateway: SpeechServerTranscriptionGateway {
    func openSpeechServerTranscription(
        sampleRate: Double,
        onPartial: @escaping @MainActor (String) -> Void,
        onFailure: @escaping @MainActor (String) -> Void
    ) async -> VoiceLiveTranscription? {
        guard let ticket = try? await bridge.mintTicket(),
              let unauthorized = try? Self.speechServerRequest(
                baseURL: baseURL,
                ticket: ticket,
                profile: profile,
                profileParameter: profileParameter,
                cloudflareAccess: bridge.cloudflareAccess
              ),
              // The dashboard's own session cookies (cookie mode), on the
              // cookie-less, redirect-refusing dashboard socket session.
              let request = try? await bridge.requestAuthorizer.authorizeUpgrade(unauthorized) else { return nil }
        let task = bridge.requestAuthorizer.webSocketTask(with: request)
        task.resume()
        return SpeechServerTranscription(
            socket: task,
            sampleRate: sampleRate,
            onPartial: onPartial,
            onFailure: onFailure
        )
    }

    /// The relay's upgrade request, authenticated like the speech stream.
    static func speechServerRequest(
        baseURL: String,
        ticket: String,
        profile: String,
        profileParameter: String = "profile",
        cloudflareAccess: CloudflareAccessCredentials?
    ) throws -> URLRequest {
        let url = try ConnectionURLPolicy.webSocketURL(
            baseURL: baseURL,
            path: SpeechServerTranscription.socketPath,
            queryItems: [URLQueryItem(name: "ticket", value: ticket)]
                + DashboardPath.socketProfileItems(profile, parameter: profileParameter)
        )
        return URLRequest(url: url).applyingProxyHeaders(cloudflare: cloudflareAccess)
    }
}

/// What the notifier says about this profile's speech server.
struct SpeechServerStatus: Equatable {
    var configured: Bool
    var available: Bool
    /// The WebSocket URL the host dials, normalized.
    var url: String?
    var hasKey: Bool
    var reason: String?
    var pluginMissing: Bool
    /// Hermes didn't answer; `reason` says why. Not what's set: what was
    /// shown stays (#1533).
    var readFailed = false

    static var pluginMissingReason: String {
        AppLocalization.string("Update the Conduit plugin on your Hermes host to use your own speech server.")
    }

    static var pluginMissing: SpeechServerStatus {
        SpeechServerStatus(configured: false, available: false, url: nil, hasKey: false,
                           reason: pluginMissingReason, pluginMissing: true)
    }

    static func failed(_ reason: String) -> SpeechServerStatus {
        var status = SpeechServerStatus(configured: false, available: false, url: nil, hasKey: false,
                                        reason: reason, pluginMissing: false)
        status.readFailed = true
        return status
    }

    init(configured: Bool, available: Bool, url: String?, hasKey: Bool, reason: String?, pluginMissing: Bool) {
        self.configured = configured
        self.available = available
        self.url = url
        self.hasKey = hasKey
        self.reason = reason
        self.pluginMissing = pluginMissing
    }

    init(response: [String: Any]) {
        configured = response["configured"] as? Bool ?? false
        available = response["available"] as? Bool ?? false
        url = (response["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        hasKey = response["has_key"] as? Bool ?? false
        reason = (response["reason"] as? String ?? response["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        pluginMissing = false
    }
}

/// The host's connection test against the speech server.
struct SpeechServerTestResult: Equatable {
    var connected: Bool
    var latencyMilliseconds: Int?
    var reason: String?

    init(connected: Bool, latencyMilliseconds: Int?, reason: String?) {
        self.connected = connected
        self.latencyMilliseconds = latencyMilliseconds
        self.reason = reason
    }

    init(response: [String: Any]) {
        connected = response["connected"] as? Bool ?? false
        latencyMilliseconds = (response["latency_ms"] as? NSNumber)?.intValue
        reason = (response["reason"] as? String ?? response["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    var message: String {
        if connected {
            if let latencyMilliseconds {
                return AppLocalization.string("Connected. Your speech server answered in \(String(latencyMilliseconds)) ms.")
            }
            return AppLocalization.string("Connected to your speech server.")
        }
        return reason ?? AppLocalization.string("Could not reach your speech server.")
    }
}
