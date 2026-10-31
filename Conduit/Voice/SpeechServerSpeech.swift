//
//  SpeechServerSpeech.swift
//  Conduit
//

import Foundation
import os

private let speechServerSpeechLog = Logger(subsystem: "com.milim.relay", category: "SpeechServerSpeech")

/// Classic voice's replies spoken by the user's own speech server (Hugging
/// Face speech-to-speech, the one Hermes Live Voice runs), so one server
/// both listens and speaks. Conduit reaches it only through the notifier's
/// relay (`/local-live/socket?mode=speak`).
///
/// A speech-to-speech server only speaks what its model address answers.
/// With that address set to the notifier's Local Live route, a speak socket's
/// turns are read back unchanged: each sentence goes out as a user item plus
/// `response.create`, and the server says exactly those words in its own
/// voice. One response at a time, in order. Turn detection stays on with
/// `create_response: false`, and no audio is ever sent, so the server never
/// answers on its own.
///
/// A server still pointed at another model would answer the reply instead
/// of reading it, so each response's transcript is checked against the
/// words sent. The first mismatch fails the stream, and the reply is
/// spoken on this iPhone instead.
@MainActor
final class SpeechServerSpeechStream: VoiceSpeechStream {
    static let socketPath = "/api/plugins/conduit_push/local-live/socket"
    static let statusPath = "/api/plugins/conduit_push/local-live/status"
    static let keyPath = "/api/plugins/conduit_push/local-live/key"
    /// The OpenAI Realtime output rate.
    static let sampleRate: Double = 24_000
    /// A sentence this long is sent without waiting for its end.
    static let maximumChunkCharacters = 280

    private let socket: any HermesSpeechSocket
    private let onStart: @MainActor (Double) throws -> Void
    private let onPCM16: @MainActor (Data, Double) throws -> Void
    private let idleTimeout: Duration
    private var receiveTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    /// Sends run one after another so frames reach the server in order.
    private var sendChain: Task<Void, Never>?
    /// Text not yet sent: the start of a sentence still streaming in.
    private var pending = ""
    /// Sentences waiting for the running response to finish.
    private var queued: [String] = []
    /// The words the running response should say, and what it said so far.
    private var speaking: String?
    private var spokenTranscript = ""
    /// Whether the running response has sent audio: audio with no
    /// transcript can't be checked, so it fails like a wrong one.
    private var responseHadAudio = false
    private var finishRequested = false
    private var started = false
    private var receivedPCM = false
    private var terminal = false
    private var terminalError: Error?
    private var completed: CheckedContinuation<Bool, Error>?
    private var lastActivity = ContinuousClock.now

    init(
        socket: any HermesSpeechSocket,
        idleTimeout: Duration = .seconds(20),
        onStart: @escaping @MainActor (Double) throws -> Void,
        onPCM16: @escaping @MainActor (Data, Double) throws -> Void
    ) {
        self.socket = socket
        self.idleTimeout = idleTimeout
        self.onStart = onStart
        self.onPCM16 = onPCM16
        send(Self.sessionUpdate)
        receiveTask = Task { @MainActor [weak self] in await self?.receiveLoop() }
    }

    deinit {
        receiveTask?.cancel()
        idleTask?.cancel()
        sendChain?.cancel()
        socket.cancel(with: .goingAway, reason: nil)
    }

    /// Audio out only. The input side matches Classic's listening socket so
    /// the server's turn detector stays quiet: no audio is ever sent here.
    static var sessionUpdate: [String: Any] {
        let format: [String: Any] = ["type": "audio/pcm", "rate": Int(sampleRate)]
        let turnDetection: [String: Any] = [
            "type": "server_vad",
            "create_response": false,
            "interrupt_response": false,
        ]
        let input: [String: Any] = ["format": format, "turn_detection": turnDetection]
        let output: [String: Any] = ["format": format]
        let session: [String: Any] = [
            "type": "realtime",
            "output_modalities": ["audio"],
            "audio": ["input": input, "output": output] as [String: Any],
        ]
        return ["type": "session.update", "session": session]
    }

    static func userItem(_ text: String) -> [String: Any] {
        let content: [[String: Any]] = [["type": "input_text", "text": text]]
        let item: [String: Any] = ["type": "message", "role": "user", "content": content]
        return ["type": "conversation.item.create", "item": item]
    }

    func append(_ text: String) async throws {
        guard !terminal else { throw terminalError ?? CancellationError() }
        guard !text.isEmpty else { return }
        pending += text
        // A long run without sentence ends goes out a chunk at a time.
        while true {
            let (ready, rest) = Self.splitSentences(pending)
            guard !ready.isEmpty else { break }
            pending = rest
            enqueue(ready)
        }
    }

    func finish() async throws -> Bool {
        guard !terminal else {
            if let terminalError { throw terminalError }
            return receivedPCM
        }
        finishRequested = true
        let rest = pending
        pending = ""
        if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { enqueue(rest) }
        if speaking == nil, queued.isEmpty {
            complete(.success(receivedPCM))
            return receivedPCM
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Cancelled (or failed) before this ran: nothing will resume it.
                if self.terminal {
                    continuation.resume(with: self.terminalError.map { .failure($0) } ?? .success(self.receivedPCM))
                    return
                }
                self.completed = continuation
                self.armIdleTimeout()
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() {
        guard !terminal else { return }
        if speaking != nil { send(["type": "response.cancel"], afterEnd: true) }
        complete(.failure(CancellationError()))
        receiveTask?.cancel()
        closeAfterSending()
    }

    // MARK: Sentences

    /// Whole sentences ready to speak, and the unfinished rest. A sentence
    /// ends at 。！？ or a line break, or at . ! ? … followed by whitespace
    /// (so "3.5" stays whole); a very long one is cut at its last space, or
    /// anywhere in text without spaces.
    static func splitSentences(_ text: String) -> (ready: String, rest: String) {
        var cut: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            // The first sentence end: one sentence a response, so the
            // first one's audio doesn't wait for the rest.
            if character.isNewline || "。！？".contains(character) {
                cut = next
                break
            } else if ".!?…".contains(character), next < text.endIndex, text[next].isWhitespace {
                cut = next
                break
            }
            index = next
        }
        if let cut {
            return (String(text[..<cut]), String(text[cut...]))
        }
        if text.count > maximumChunkCharacters {
            let limit = text.index(text.startIndex, offsetBy: maximumChunkCharacters)
            let space = text[..<limit].lastIndex(where: { $0 == " " })
            let split = space.flatMap { $0 > text.startIndex ? $0 : nil } ?? limit
            return (String(text[..<split]), String(text[split...]))
        }
        return ("", text)
    }

    /// Letters and digits only, lowercased: how the server's transcript is
    /// compared with the words sent.
    static func comparable(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(folded.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Whether `transcript`, so far, is the server reading `words`: the
    /// start of them, with nothing of its own added.
    static func isReadingBack(_ transcript: String, words: String) -> Bool {
        comparable(words).hasPrefix(comparable(transcript))
    }

    // MARK: Responses

    private func enqueue(_ text: String) {
        // Markdown marks are written, not said, as for on-device speech.
        let words = PreviewText.plain(text).trimmingCharacters(in: .whitespacesAndNewlines)
        // Punctuation or emoji alone has nothing to read back or check.
        guard !Self.comparable(words).isEmpty else { return }
        queued.append(words)
        speakNext()
    }

    private func speakNext() {
        guard !terminal, speaking == nil, !queued.isEmpty else { return }
        let words = queued.removeFirst()
        speaking = words
        spokenTranscript = ""
        responseHadAudio = false
        send(Self.userItem(words))
        send(["type": "response.create"])
    }

    /// Each response must voice its whole sentence: a silent one fails the
    /// stream (so a reply not yet started goes to this iPhone), and so does
    /// one whose transcript isn't exactly the words sent.
    private func responseFinished() {
        if let words = speaking {
            guard responseHadAudio else {
                // The cancel goes out before the socket closes.
                send(["type": "response.cancel"], afterEnd: true)
                complete(.failure(VoiceAudioError.unavailable(AppLocalization.string("Your speech server couldn't speak the reply."))))
                closeAfterSending()
                return
            }
            guard Self.comparable(spokenTranscript) == Self.comparable(words) else {
                failNotReadingBack()
                return
            }
        }
        speaking = nil
        spokenTranscript = ""
        speakNext()
        if finishRequested, speaking == nil, queued.isEmpty { complete(.success(receivedPCM)) }
    }

    private func failNotReadingBack() {
        send(["type": "response.cancel"], afterEnd: true)
        complete(.failure(VoiceAudioError.unavailable(AppLocalization.string("Your speech server answered instead of reading the reply. Set its model address to the one in Conduit's voice settings."))))
        closeAfterSending()
    }

    // MARK: Socket

    /// `afterEnd` sends even once the stream has ended: the cancel that
    /// stops a response going on without us.
    private func send(_ object: [String: Any], afterEnd: Bool = false) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return }
        let previous = sendChain
        sendChain = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, afterEnd || !self.terminal else { return }
            do {
                try await self.socket.send(.string(string))
            } catch {
                self.fail(error)
            }
        }
    }

    /// Closes the socket once the frames already queued are sent.
    private func closeAfterSending() {
        let previous = sendChain
        sendChain = Task { @MainActor [weak self] in
            await previous?.value
            self?.socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private func receiveLoop() async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                lastActivity = .now
                let data: Data?
                switch message {
                case .string(let string): data = string.data(using: .utf8)
                case .data(let bytes): data = bytes
                @unknown default: data = nil
                }
                guard let data, let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                try handle(event)
                if terminal { return }
            }
        } catch {
            guard !Task.isCancelled else { return }
            fail(error)
        }
    }

    private func handle(_ event: [String: Any]) throws {
        guard !terminal else { return }
        switch event["type"] as? String {
        case "response.output_audio.delta", "response.audio.delta":
            guard let delta = event["delta"] as? String, let pcm = Data(base64Encoded: delta), !pcm.isEmpty else { return }
            if !started {
                try onStart(Self.sampleRate)
                started = true
            }
            try onPCM16(pcm, Self.sampleRate)
            receivedPCM = true
            responseHadAudio = true
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            guard let delta = event["delta"] as? String, let words = speaking else { return }
            spokenTranscript += delta
            if !Self.isReadingBack(spokenTranscript, words: words) { failNotReadingBack() }
        case "response.done":
            responseFinished()
        case "error":
            let error = event["error"] as? [String: Any]
            let message = (error?["message"] as? String ?? event["message"] as? String)
                .map(HermesSpeechFailure.message)
            fail(VoiceAudioError.unavailable(message ?? AppLocalization.string("Your speech server couldn't speak the reply.")))
        default:
            break
        }
    }

    private func fail(_ error: Error) {
        guard !terminal else { return }
        complete(.failure(error))
        socket.cancel(with: .goingAway, reason: nil)
    }

    /// Fires once the server has sent nothing for the whole window after
    /// `finish()`, measured from its latest frame.
    private func armIdleTimeout() {
        idleTask?.cancel()
        lastActivity = .now
        let timeout = idleTimeout
        idleTask = Task { @MainActor [weak self] in
            while true {
                guard let deadline = self.map({ $0.lastActivity + timeout }) else { return }
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                guard let self, !self.terminal else { return }
                if ContinuousClock.now - self.lastActivity >= timeout { break }
            }
            self?.fail(VoiceAudioError.unavailable(AppLocalization.string("Your speech server stopped speaking.")))
        }
    }

    private func complete(_ result: Result<Bool, Error>) {
        guard !terminal else { return }
        terminal = true
        idleTask?.cancel()
        idleTask = nil
        if case .failure(let error) = result { terminalError = error }
        let continuation = completed
        completed = nil
        continuation?.resume(with: result)
        // One socket per reply: the relay frees the server's pipeline.
        if case .success = result {
            receiveTask?.cancel()
            socket.cancel(with: .normalClosure, reason: nil)
        }
    }
}

extension HermesVoiceGateway {
    /// Opens the speak socket to this profile's speech server.
    func openSpeechServerSpeech(
        onStart: @escaping @MainActor (Double) throws -> Void,
        onPCM16: @escaping @MainActor (Data, Double) throws -> Void
    ) async throws -> VoiceSpeechStream {
        let ticket = try await bridge.mintTicket()
        let unauthorized: URLRequest
        do {
            unauthorized = try Self.speechServerSpeechRequest(
                baseURL: baseURL,
                ticket: ticket,
                profile: profile,
                profileParameter: profileParameter,
                cloudflareAccess: bridge.cloudflareAccess
            )
        } catch {
            speechServerSpeechLog.notice("Speech server speak request failed: \(String(describing: error), privacy: .private)")
            throw VoiceAudioError.unavailable(AppLocalization.string("Could not open the speech stream."))
        }
        // The dashboard's own session cookies (cookie mode), on the
        // cookie-less, redirect-refusing dashboard socket session, like the
        // speech stream: a redirect never carries the ticket or the
        // Cloudflare token anywhere.
        let request = try await bridge.requestAuthorizer.authorizeUpgrade(unauthorized)
        let task = bridge.requestAuthorizer.webSocketTask(with: request)
        task.resume()
        return SpeechServerSpeechStream(socket: task, onStart: onStart, onPCM16: onPCM16)
    }

    /// The relay's upgrade request in speak mode, authenticated like the
    /// speech stream.
    static func speechServerSpeechRequest(
        baseURL: String,
        ticket: String,
        profile: String,
        profileParameter: String = "profile",
        cloudflareAccess: CloudflareAccessCredentials?
    ) throws -> URLRequest {
        let url = try ConnectionURLPolicy.webSocketURL(
            baseURL: baseURL,
            path: SpeechServerSpeechStream.socketPath,
            queryItems: [URLQueryItem(name: "ticket", value: ticket)]
                + LocalLiveProtocol.profileQueryItems(profile, parameter: profileParameter)
                + [URLQueryItem(name: "mode", value: "speak")]
        )
        return URLRequest(url: url).applyingProxyHeaders(cloudflare: cloudflareAccess)
    }
}

/// What the notifier says about speaking through the speech server
/// (`/local-live/status`): whether it can, and what to set on the server.
/// The host's fast model for Local (agent mode), from Local Live's status.
struct LocalLiveFrontModelStatus: Equatable {
    var configured: Bool
    var available: Bool
    var baseURL: String?
    var model: String?
    var hasKey: Bool
    var reason: String?

    init(response: [String: Any]) {
        configured = response["configured"] as? Bool ?? false
        available = response["available"] as? Bool ?? false
        baseURL = (response["base_url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        model = (response["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        hasKey = response["has_key"] as? Bool ?? false
        reason = (response["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct SpeechServerVoiceStatus: Equatable {
    var available: Bool
    var reason: String?
    /// The server's model address: this phone's dashboard address plus the
    /// notifier's route. Nil when the plugin can't take the server's key.
    var modelAddress: String?
    var modelName: String
    var apiKey: String?
    /// When the server last asked the plugin for words: it is pointed at it.
    var lastRequestAt: Date?
    /// The speech server's address the Hermes host dials (Speech to text's).
    var speechServerURL: String?
    var pluginMissing: Bool
    /// Local's fast model (agent mode); nil from a plugin before it.
    var frontModel: LocalLiveFrontModelStatus?
    /// Hermes didn't answer; `reason` says why. The fast model shown stays
    /// (#1533).
    var readFailed = false

    static var pluginMissingReason: String {
        AppLocalization.string("Update the Conduit plugin on your Hermes host to have your speech server speak the replies.")
    }

    static var pluginMissing: SpeechServerVoiceStatus {
        var status = SpeechServerVoiceStatus(unavailable: pluginMissingReason)
        status.pluginMissing = true
        return status
    }

    init(unavailable reason: String) {
        available = false
        self.reason = reason
        modelAddress = nil
        modelName = "conduit"
        apiKey = nil
        lastRequestAt = nil
        speechServerURL = nil
        pluginMissing = false
        frontModel = nil
    }

    init(response: [String: Any], dashboardBaseURL: String?) {
        available = response["available"] as? Bool ?? false
        reason = (response["reason"] as? String ?? response["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let path = (response["model_path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        apiKey = (response["api_key"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        modelAddress = apiKey == nil ? nil : path.flatMap { Self.modelAddress(baseURL: dashboardBaseURL, path: $0) }
        modelName = (response["model_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "conduit"
        lastRequestAt = (response["last_request_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        speechServerURL = ((response["speech_server"] as? [String: Any])?["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        pluginMissing = false
        frontModel = (response["front_model"] as? [String: Any]).map(LocalLiveFrontModelStatus.init(response:))
    }

    /// `baseURL` (the dashboard, maybe with a path prefix) joined with the
    /// route's path.
    static func modelAddress(baseURL: String?, path: String) -> String? {
        guard let base = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty else { return nil }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return trimmed + (path.hasPrefix("/") ? path : "/" + path)
    }

    /// The flags to start Hugging Face speech-to-speech with.
    var serverFlags: String? {
        guard let modelAddress, let apiKey else { return nil }
        return "--llm_backend chat-completions --responses_api_base_url \(Self.shellQuoted(modelAddress)) --responses_api_api_key \(Self.shellQuoted(apiKey)) --model_name \(Self.shellQuoted(modelName)) --stream_batch_sentences 1 --num_pipelines 2"
    }

    /// The whole setup as one block to hand to whoever runs the server,
    /// such as the user's Hermes agent: what to set and why, with every
    /// value filled in. Written for an agent to act on, so it stays English.
    var agentSetupText: String? {
        guard let modelAddress, let apiKey, let serverFlags else { return nil }
        var lines = [
            "Please point my Hugging Face speech-to-speech server at Conduit, so Hermes writes every reply it speaks.",
            "",
        ]
        if let speechServerURL {
            lines += ["Speech server: \(speechServerURL) (the address my Hermes host connects to).", ""]
        }
        lines += [
            "Set its language model to Conduit's model address (OpenAI-compatible chat completions, streamed):",
            "- base URL: \(modelAddress)",
            "- API key: \(apiKey)",
            "- model name: \(modelName)",
            "",
            "As start flags (add them, or replace the same flags; keep its speech-to-text, text-to-speech and other settings):",
            serverFlags,
            "",
            "Notes:",
            "- --num_pipelines 2 lets Conduit listen and speak over two connections at once.",
            "- --stream_batch_sentences 1 speaks each sentence as soon as Hermes writes it.",
            "- The server's machine must reach the base URL. Check from there: curl -sS -H \(Self.shellQuoted("Authorization: Bearer " + apiKey)) \(Self.shellQuoted(modelAddress + "/models")) should list the model \"\(modelName)\".",
            "- Restart the server after changing its flags (for example its systemd service), and check its log for the language model warming up without errors.",
            "- Keep the key private. Conduit can make a new one in Settings > Voice.",
        ]
        return lines.joined(separator: "\n")
    }

    /// `value` as one shell word: as is when it's plain, else single-quoted.
    static func shellQuoted(_ value: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:/=@%+,"))
        if !value.isEmpty, value.unicodeScalars.allSatisfy(plain.contains) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
