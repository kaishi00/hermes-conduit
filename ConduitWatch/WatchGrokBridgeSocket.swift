//
//  WatchGrokBridgeSocket.swift
//  Conduit Watch
//
//  A Watch call to Grok: the Watch runs the conversation as it runs
//  Gemini's (GrokLiveSession, shared with the iPhone), and xAI's session is
//  held by the Hermes host, on its own xAI sign-in, reached through the
//  call grant's audio bridge (designs/apple-watch-gpt-live.md, "Bridge
//  design"). This is the session's socket over that bridge: one bridge
//  stream per connection, opened with the hello and a sealed start, and
//  ready once the host says the engine started. Then xAI's events go both
//  ways as sealed engine events. The host strips xAI's audio deltas to
//  pace them, so its audio comes back as one again here, and the session's
//  input_audio_buffer.append events go as audio, which the host appends.
//

import Foundation

/// Where the call's Grok connections go, read from its grant.
struct WatchGrokBridge {
    let url: URL
    let grantID: String
    let root: Data
    let watchKey: String
    let voice: String?
}

/// GrokLiveSession's connection seam, for a call on the Watch: the host
/// already said Grok is available when the grant opened its bridge.
@MainActor
final class WatchGrokConnection: GrokLiveConnecting {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func availability() async throws -> GrokLiveAvailability {
        .available(model: GrokLiveProtocol.defaultModel, voice: nil, auth: nil)
    }

    func socketRequest() async throws -> URLRequest {
        URLRequest(url: url)
    }
}

@MainActor
final class WatchGrokBridgeSocket: GeminiLiveSocket {
    /// How long the host may take to start xAI's session. `send` waits for the start,
    /// so this, not the session's setup timeout, bounds a bridge's first
    /// connect.
    static let startWait: TimeInterval = 20
    /// The relay closes a socket silent for a minute.
    static let pingInterval: TimeInterval = 20
    /// The rates the host's Grok runs at (GROK_WATCH_RATE).
    static let rate = Int(GrokLiveProtocol.inputSampleRate)

    enum Failure: LocalizedError {
        case closed
        case timedOut
        case unsealable

        var errorDescription: String? {
            switch self {
            case .closed: return String(localized: "Lost the connection to Hermes.")
            case .timedOut: return String(localized: "Hermes didn't start Grok in time.")
            case .unsealable: return String(localized: "Couldn't reconnect to Hermes.")
            }
        }
    }

    /// Socket events for the call log: open, started, closed.
    var onNote: ((String, [String: Any]) -> Void)?

    private let socket: WatchBridgeSocket?
    private var stream: WatchAudioBridgeStream?
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Error>] = []
    private var inbox: [Data] = []
    private var receiver: CheckedContinuation<Data, Error>?
    private var failure: Error?
    /// The host's refusal, as the session reads a server's close.
    private var refusal: GeminiLiveServerClose?
    private var pingTimer: Timer?
    private var startTimer: Timer?

    /// `stream` is nil once the grant has no stream ids left: the socket
    /// then fails its first send.
    init(bridge: WatchGrokBridge, stream: WatchAudioBridgeStream?) {
        self.stream = stream
        guard stream != nil else {
            socket = nil
            failure = Failure.unsealable
            return
        }
        let socket = WatchBridgeSocket(url: bridge.url, watchKey: bridge.watchKey)
        self.socket = socket
        socket.onEvent = { [weak self] kind, fields in self?.socketEvent(kind, fields, voice: bridge.voice) }
        socket.onMessage = { [weak self] data in self?.received(data) }
        startTimer = WatchVoiceMain.timer(every: Self.startWait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.started else { return }
                self.fail(Failure.timedOut)
            }
        }
    }

    // MARK: GeminiLiveSocket

    func send(_ text: String) async throws {
        try await waitForStart()
        // The microphone goes as audio, which the host appends to xAI's
        // input itself: a quarter fewer bytes through the relay.
        if let pcm = Self.appendedAudio(text) {
            try await seal(pcm, kind: .audio)
        } else {
            try await seal(Data(text.utf8), kind: .event)
        }
    }

    /// The PCM of an input_audio_buffer.append event, else nil.
    static func appendedAudio(_ text: String) -> Data? {
        guard text.contains("input_audio_buffer.append"),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              object["type"] as? String == "input_audio_buffer.append",
              let audio = object["audio"] as? String else { return nil }
        return Data(base64Encoded: audio)
    }

    func receive() async throws -> Data {
        if !inbox.isEmpty { return inbox.removeFirst() }
        if let failure { throw failure }
        return try await withCheckedThrowingContinuation { continuation in
            // One receive at a time, as the session reads.
            receiver?.resume(throwing: Failure.closed)
            receiver = continuation
        }
    }

    func close() {
        if started, let stream, socket != nil {
            // Ends xAI's session now; the relay's notice would too.
            try? sealNow(WatchAudioBridgeWire.end, kind: .control, stream: stream)
        }
        fail(Failure.closed)
    }

    func serverClose(within timeout: Duration) async -> GeminiLiveServerClose? {
        refusal
    }

    // MARK: Bridge

    private func waitForStart() async throws {
        if started { return }
        if let failure { throw failure }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startWaiters.append(continuation)
        }
    }

    private func seal(_ plain: Data, kind: WatchAudioBridgeWire.Kind) async throws {
        guard let socket, var stream, failure == nil else { throw failure ?? Failure.closed }
        let message: Data
        do {
            message = try stream.seal(plain, kind: kind)
        } catch {
            throw Failure.unsealable
        }
        self.stream = stream
        let sent: Bool = await withCheckedContinuation { continuation in
            socket.send(message) { continuation.resume(returning: $0) }
        }
        if !sent { throw failure ?? Failure.closed }
    }

    /// Sends without waiting for the socket: the hello's start and the end.
    private func sealNow(_ plain: Data, kind: WatchAudioBridgeWire.Kind, stream: WatchAudioBridgeStream) throws {
        var stream = stream
        let message = try stream.seal(plain, kind: kind)
        self.stream = stream
        socket?.send(message)
    }

    private func socketEvent(_ kind: String, _ fields: [String: Any], voice: String?) {
        guard failure == nil else { return }
        switch kind {
        case "open":
            onNote?("open", [:])
            guard let stream else { return }
            socket?.send(WatchAudioBridgeWire.hello(streamID: stream.streamID))
            // xAI's session is the Watch's to set up: the start carries
            // only the engine and voice.
            let start = WatchAudioBridgeWire.start(engine: WatchAudioBridgeWire.grok, voice: voice, briefing: nil, greeting: nil, history: [])
            do {
                try sealNow(start, kind: .control, stream: stream)
            } catch {
                fail(Failure.unsealable)
            }
        case "close", "complete", "receiveFailed":
            var details = fields
            details["event"] = kind
            details["started"] = started
            onNote?("closed", details)
            // The call's grant ended: closed on Hermes or the relay, or
            // expired. Nothing to reconnect to.
            if (fields["code"] as? Int ?? socket?.closeCode) == 4010 {
                refusal = GeminiLiveServerClose(code: 4010, reason: String(localized: "The call's access to Hermes ended."))
            } else if !started, let status = fields["http"] as? Int, status != 101 {
                // The relay refused the upgrade (no plugin route, a bad
                // grant): the session words it as an update to make.
                refusal = GeminiLiveServerClose(code: status, reason: "", isHTTPStatus: true)
            }
            fail(Failure.closed)
        default:
            break
        }
    }

    private func received(_ data: Data) {
        guard failure == nil, WatchAudioBridgeWire.notice(data) == nil, var stream else { return }
        let opened: (kind: WatchAudioBridgeWire.Kind, plain: Data)
        do {
            opened = try stream.open(data)
            self.stream = stream
        } catch {
            onNote?("unopened", ["error": "\(error)", "bytes": data.count])
            return
        }
        switch opened.kind {
        case .control:
            guard let control = WatchAudioBridgeWire.control(opened.plain) else { return }
            handle(control)
        case .event:
            deliver(opened.plain)
        case .audio:
            // As xAI sent it, before the host took it out to pace it.
            let event: [String: Any] = ["type": "response.output_audio.delta", "delta": opened.plain.base64EncodedString()]
            if let text = try? JSONSerialization.data(withJSONObject: event) { deliver(text) }
        }
    }

    private func handle(_ control: WatchAudioBridgeWire.Control) {
        switch control {
        case .started(let info):
            onNote?("started", ["inputRate": info.inputRate, "outputRate": info.outputRate, "voice": info.voice as Any])
            // Other rates would play at the wrong speed and send mis-framed
            // audio.
            guard info.inputRate == Self.rate, info.outputRate == Self.rate else {
                refusal = GeminiLiveServerClose(code: 4400, reason: String(localized: "Hermes sends Grok's audio in a format this Watch build can't play. Update Conduit and the conduit_push plugin together."))
                fail(Failure.closed)
                return
            }
            // A host that started another engine on this stream isn't talking to Grok.
            guard info.engine.isEmpty || info.engine == WatchAudioBridgeWire.grok else {
                refusal = GeminiLiveServerClose(code: 4400, reason: String(localized: "Hermes started \(info.engine), not Grok. Update Conduit and the conduit_push plugin together."))
                fail(Failure.closed)
                return
            }
            started = true
            startTimer?.invalidate()
            startTimer = nil
            pingTimer?.invalidate()
            pingTimer = WatchVoiceMain.timer(every: Self.pingInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.socket?.ping { _ in } }
            }
            let waiters = startWaiters
            startWaiters = []
            for waiter in waiters { waiter.resume() }
        case .ended(let reason):
            onNote?("ended", ["reason": reason as Any])
            fail(Failure.closed)
        case .error(let code, let message):
            onNote?("hostError", ["code": code as Any, "message": String(message.prefix(200))])
            switch code ?? "" {
            case "unreachable", "failed":
                // Worth another try: xAI or the host dropped.
                break
            default:
                // The host or xAI refused what a retry would send again.
                refusal = GeminiLiveServerClose(code: 4403, reason: message)
            }
            fail(Failure.closed)
        }
    }

    private func deliver(_ data: Data) {
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: data)
        } else {
            inbox.append(data)
        }
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        startTimer?.invalidate()
        startTimer = nil
        pingTimer?.invalidate()
        pingTimer = nil
        socket?.close()
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters { waiter.resume(throwing: error) }
        if let receiver {
            self.receiver = nil
            receiver.resume(throwing: error)
        }
    }
}
