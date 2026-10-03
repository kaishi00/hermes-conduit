//
//  GeminiLiveSession.swift
//  Conduit
//
//  One logical Gemini Live conversation over one or more WebSockets. Every
//  connection gets a fresh single-use token from Hermes. A GoAway or a lost
//  socket reconnects with the latest session-resumption handle, so the
//  conversation (and its context-window compression) carries over. On a
//  GoAway the old connection keeps carrying the conversation, both ways,
//  until the new one is set up: the handoff is not heard as a dropout.
//

import Foundation
import OSLog

private let geminiLiveLogger = Logger(subsystem: "com.milim.relay", category: "GeminiLive")

// MARK: - Transport

/// How the server ended a WebSocket: its close code and reason text, or
/// the HTTP status when it refused the WebSocket upgrade itself.
struct GeminiLiveServerClose: Equatable {
    let code: Int
    let reason: String
    var isHTTPStatus = false

    /// Codes that mean Google rejected what was sent (the setup, token or
    /// model), which a retry won't change: unsupported or invalid data,
    /// a policy violation, and the application-defined 4xxx range, or an
    /// upgrade refused as bad, unauthorized, forbidden or not found. An
    /// exhausted quota is final too: every retry would only spend more of
    /// it. Going away, abnormal, internal-error, a bare rate limit (429)
    /// and 5xx stay retryable.
    var isRefusal: Bool {
        if isQuotaExhausted { return true }
        if isHTTPStatus { return [400, 401, 403, 404].contains(code) }
        return [1003, 1007, 1008].contains(code) || (4000...4999).contains(code)
    }

    /// Google's wording for a spent quota ("You exceeded your current
    /// quota…", RESOURCE_EXHAUSTED), not any reason that mentions a quota.
    var isQuotaExhausted: Bool {
        let text = reason.lowercased().replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.contains("exceeded your current quota") || text.contains("resource exhausted")
            // gRPC's RESOURCE_EXHAUSTED text.
            || text.contains("resource has been exhausted")
    }

    /// What the user is shown: the first line of Google's reason (capped),
    /// or the code when there is none.
    var summary: String {
        var text = reason.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        // Google appends "For more information on this error, head to: <url>";
        // a link can't be followed from the sheet and would be cut mid-URL.
        if let pointer = text.range(of: "For more information on this error", options: .caseInsensitive) {
            text = String(text[..<pointer.lowerBound])
        }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            if isHTTPStatus { return "HTTP \(code)" }
            return AppLocalization.string("close code \(String(code))")
        }
        guard text.count > 300 else { return text }
        let capped = text.prefix(300)
        // A space too early would drop most of the reason: cut hard instead.
        var cut = capped.lastIndex(of: " ") ?? capped.endIndex
        if capped.distance(from: capped.startIndex, to: cut) < 200 { cut = capped.endIndex }
        return String(capped[..<cut]) + "…"
    }
}

@MainActor
protocol GeminiLiveSocket: AnyObject {
    func send(_ text: String) async throws
    /// The next frame's payload (text frames as UTF-8). Throws when the
    /// socket closes.
    func receive() async throws -> Data
    func close()
    /// How the server closed the socket, waiting up to `timeout` for the
    /// close frame to be reported (it can land after `receive()` throws).
    /// Nil when the connection simply dropped.
    func serverClose(within timeout: Duration) async -> GeminiLiveServerClose?
}

extension GeminiLiveSocket {
    func serverClose(within timeout: Duration) async -> GeminiLiveServerClose? { nil }
}

/// URLSession reports a server's close frame through its delegate, and
/// not necessarily before a pending `receive()` fails, so it is recorded
/// here rather than read from the task.
private final class GeminiLiveSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: GeminiLiveServerClose?

    var serverClose: GeminiLiveServerClose? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let text = reason.flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lock.lock()
        recorded = GeminiLiveServerClose(code: closeCode.rawValue, reason: text)
        lock.unlock()
    }
}

@MainActor
final class URLSessionGeminiLiveSocket: GeminiLiveSocket {
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let delegate = GeminiLiveSocketDelegate()

    convenience init(url: URL) {
        self.init(request: URLRequest(url: url))
    }

    /// `request` carries any headers the upgrade needs (Cloudflare Access
    /// in front of the Hermes dashboard, for Grok Live's relay).
    init(request: URLRequest) {
        // A session of its own, so its delegate hears this socket's close.
        session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        task = session.webSocketTask(with: request)
        // Model audio frames are larger than URLSession's 1 MB default.
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
    }

    deinit {
        // A socket dropped without close() must not keep its session.
        session.invalidateAndCancel()
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .string(let text): return Data(text.utf8)
        case .data(let data): return data
        @unknown default: return Data()
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        // The session retains its delegate until invalidated; finishing
        // (rather than cancelling) lets the normal-closure frame go out.
        session.finishTasksAndInvalidate()
    }

    func serverClose(within timeout: Duration) async -> GeminiLiveServerClose? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !Task.isCancelled {
            if let recorded = delegate.serverClose { return recorded }
            if task.closeCode != .invalid {
                let text = task.closeReason.flatMap { String(data: $0, encoding: .utf8) }?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return GeminiLiveServerClose(code: task.closeCode.rawValue, reason: text)
            }
            // No close frame, but the upgrade itself was refused.
            if let http = task.response as? HTTPURLResponse, http.statusCode != 101 {
                return GeminiLiveServerClose(code: http.statusCode, reason: "", isHTTPStatus: true)
            }
            guard ContinuousClock.now < deadline else { return nil }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return nil
            }
        }
        return nil
    }
}

// MARK: - Session

@MainActor
final class GeminiLiveSession {
    enum State: Equatable {
        case idle
        case connecting
        case ready
        /// Switching to a new connection after the old one dropped. A GoAway
        /// handoff stays `ready`: the old connection serves until the new
        /// one takes over.
        case reconnecting
        case failed(String)
        case stopped
    }

    /// Retries after a connection attempt fails, for the first connect and
    /// every reconnect alike (so at most 1 + 3 attempts in a row).
    static let maximumReconnectAttempts = 3

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    /// Latest resumable handle from the server; nil until the first update.
    private(set) var resumptionHandle: String?

    var onEvent: (@MainActor (GeminiLiveProtocol.ServerEvent) -> Void)?
    var onStateChange: (@MainActor (State) -> Void)?
    /// A new connection took over. Function calls opened on the previous
    /// connection can no longer be answered on this one.
    var onConnectionReplaced: (@MainActor () -> Void)?
    /// Counts connections that took over: a function call made under one
    /// value can't be answered once it changes.
    private(set) var connectionGeneration = 0

    private let tokens: GeminiLiveTokenProviding
    private let openSocket: @MainActor (URL) -> GeminiLiveSocket
    private let systemInstruction: String
    private let functions: [GeminiLiveProtocol.FunctionDeclaration]
    /// Whether this session's lookups use Google Search at all (the user may
    /// have chosen the Hermes host's search, or none).
    private let usesGoogleSearch: Bool
    /// The prebuilt voice Gemini speaks with; nil is Gemini's default.
    private let voice: String?
    /// MainActor like the session: a nonisolated delay would hop to the
    /// cooperative pool and back on every retry, which tests' fixed
    /// `Task.yield` settles cannot always cover on a loaded runner.
    private let reconnectDelay: @MainActor @Sendable (Int) async throws -> Void

    private var socket: GeminiLiveSocket?
    /// Identity of the connection whose frames are current. Frames from any
    /// other connection are ignored.
    private var connectionID = UUID()
    private var receiveTask: Task<Void, Never>?
    /// A GoAway handoff is under way: the current connection keeps serving
    /// while the next one fetches its token and sets up.
    private var isHandingOff = false
    /// The connection taking over in a GoAway handoff, until its
    /// setupComplete makes it the current one.
    private var handoffSocket: GeminiLiveSocket?
    private var handoffID: UUID?
    private var handoffReceiveTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var hasConnectedOnce = false
    /// The connection still waiting for setupComplete, and which attempt it
    /// is. A socket that closes before setup is a failed attempt, not a
    /// lost connection, so it counts toward the retry limit.
    private var awaitingSetup: (id: UUID, attempt: Int)?
    /// The last close Google sent before setup, named if retries run out.
    private var lastSetupClose: GeminiLiveServerClose?
    /// Whether setup asks for Google Search. Search is metered on its own,
    /// so once Google refuses a setup for quota the session carries on
    /// without it rather than failing.
    private var googleSearch = true

    init(
        tokens: GeminiLiveTokenProviding,
        systemInstruction: String,
        functions: [GeminiLiveProtocol.FunctionDeclaration],
        googleSearch: Bool = true,
        voice: String? = nil,
        openSocket: @escaping @MainActor (URL) -> GeminiLiveSocket = { URLSessionGeminiLiveSocket(url: $0) },
        reconnectDelay: @escaping @MainActor @Sendable (Int) async throws -> Void = { attempt in
            try await Task.sleep(for: .seconds(min(8, 1 << attempt)))
        }
    ) {
        self.tokens = tokens
        self.systemInstruction = systemInstruction
        self.functions = functions
        self.usesGoogleSearch = googleSearch
        self.googleSearch = googleSearch
        self.voice = voice
        self.openSocket = openSocket
        self.reconnectDelay = reconnectDelay
    }

    var isReady: Bool { state == .ready }

    func start() {
        guard state == .idle || state == .stopped || isFailed else { return }
        resumptionHandle = nil
        lastSetupClose = nil
        googleSearch = usesGoogleSearch
        hasConnectedOnce = false
        state = .connecting
        connectTask = Task { [weak self] in await self?.connect(attempt: 0) }
    }

    func stop() {
        connectTask?.cancel()
        connectTask = nil
        closeAllConnections()
        state = .stopped
    }

    /// Ends the session with `message`: every connection (live, retiring
    /// or still in setup) is closed and nothing from them is heard again.
    private func fail(_ message: String) {
        closeAllConnections()
        state = .failed(message)
    }

    private func closeAllConnections() {
        connectTask?.cancel()
        awaitingSetup = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.close()
        socket = nil
        dropHandoff()
        connectionID = UUID()
    }

    /// Abandons the connection a GoAway handoff was setting up.
    private func dropHandoff() {
        isHandingOff = false
        handoffReceiveTask?.cancel()
        handoffReceiveTask = nil
        handoffSocket?.close()
        handoffSocket = nil
        handoffID = nil
    }

    func send(_ message: LiveVoiceClientMessage, onSent: (@MainActor () -> Void)?, onFailure: (@MainActor () -> Void)?) {
        guard state == .ready, let socket, let text = try? GeminiLiveProtocol.encode(GeminiLiveProtocol.message(for: message)) else {
            onFailure?()
            return
        }
        let id = connectionID
        Task { [weak self] in
            do {
                try await socket.send(text)
                onSent?()
            } catch {
                onFailure?()
                self?.connectionFailed(id, error: error)
            }
        }
    }

    // MARK: Connection

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func connect(attempt: Int) async {
        let token: GeminiLiveToken
        do {
            token = try await tokens.freshToken()
        } catch {
            guard !Task.isCancelled, state != .stopped else { return }
            // A missing plugin or key will not fix itself on retry.
            if error is GeminiLiveTokenError {
                fail(error.localizedDescription)
                return
            }
            await retry(after: attempt, error: error)
            return
        }
        guard !Task.isCancelled, state != .stopped else { return }
        let socket = openSocket(token.connectURL)
        let id = UUID()
        let setup = GeminiLiveProtocol.setupMessage(
            model: token.model,
            systemInstruction: systemInstruction,
            functions: functions,
            googleSearch: googleSearch,
            voice: voice,
            resumptionHandle: resumptionHandle
        )
        do {
            try await socket.send(try GeminiLiveProtocol.encode(setup))
        } catch {
            // A refused WebSocket upgrade surfaces here, on the first send.
            let close = await socket.serverClose(within: .milliseconds(400))
            socket.close()
            guard !Task.isCancelled, state != .stopped, !isFailed else { return }
            if let close, close.isRefusal {
                refused(close, attempt: attempt)
                return
            }
            if let close { lastSetupClose = close }
            await retry(after: attempt, error: error)
            return
        }
        guard !Task.isCancelled, state != .stopped else {
            socket.close()
            return
        }
        awaitingSetup = (id, attempt)
        if isHandingOff, self.socket != nil {
            // The current connection keeps carrying the conversation (a
            // GoAway still gives it `timeLeft`) until this one is set up.
            handoffSocket?.close()
            handoffReceiveTask?.cancel()
            handoffSocket = socket
            handoffID = id
            handoffReceiveTask = Task { [weak self] in await self?.receiveLoop(socket, id: id) }
            return
        }
        // No live connection left to hand off from.
        isHandingOff = false
        receiveTask?.cancel()
        self.socket?.close()
        self.socket = socket
        connectionID = id
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket, id: id) }
    }

    private func receiveLoop(_ socket: GeminiLiveSocket, id: UUID) async {
        while !Task.isCancelled {
            let data: Data
            do {
                data = try await socket.receive()
            } catch {
                // A close before setup decides between failing and retrying,
                // so give its close frame a moment to be reported. For a
                // live connection the reason is only logged (best effort).
                let beforeSetup = awaitingSetup?.id == id
                let close = await socket.serverClose(within: beforeSetup ? .milliseconds(400) : .milliseconds(100))
                connectionFailed(id, error: error, serverClose: close)
                return
            }
            guard id == connectionID || id == handoffID else { return }
            for event in GeminiLiveProtocol.decode(data) {
                // An event can retire this connection mid-frame.
                guard id == connectionID || id == handoffID else { return }
                handle(event, connection: id)
            }
        }
    }

    private func handle(_ event: GeminiLiveProtocol.ServerEvent, connection id: UUID) {
        switch event {
        case .setupComplete:
            if id == handoffID, let next = handoffSocket {
                // The handoff connection takes over; the old one closes.
                receiveTask?.cancel()
                socket?.close()
                socket = next
                receiveTask = handoffReceiveTask
                connectionID = id
                handoffSocket = nil
                handoffReceiveTask = nil
                handoffID = nil
            }
            isHandingOff = false
            let replaced = hasConnectedOnce
            hasConnectedOnce = true
            awaitingSetup = nil
            lastSetupClose = nil
            // Calls opened on the previous connection are gone before anyone
            // sees `.ready` and starts answering on this one.
            if replaced {
                connectionGeneration += 1
                onConnectionReplaced?()
            }
            if state == .ready {
                // A handoff never left `ready`; say it again so listeners
                // treat the new connection as freshly ready.
                onStateChange?(.ready)
            } else {
                state = .ready
            }
        case .resumptionUpdate(let handle, let resumable):
            if resumable, let handle { resumptionHandle = handle }
        case .goAway(let timeLeft):
            // Only the current connection's GoAway starts a handoff.
            guard id == connectionID else { return }
            geminiLiveLogger.notice("GoAway received (timeLeft=\(timeLeft ?? -1, privacy: .public)s); reconnecting with resumption")
            beginHandoff()
            return
        default:
            break
        }
        onEvent?(event)
    }

    /// Sets up the next connection while the current one keeps serving.
    private func beginHandoff() {
        guard state == .ready, !isHandingOff else { return }
        isHandingOff = true
        connectTask?.cancel()
        connectTask = Task { [weak self] in await self?.connect(attempt: 0) }
    }

    private func connectionFailed(_ id: UUID, error: Error, serverClose: GeminiLiveServerClose? = nil) {
        guard state != .stopped, !isFailed else { return }
        if id == handoffID {
            handoffFailed(error: error, serverClose: serverClose)
            return
        }
        guard id == connectionID else { return }
        // Never the error's description: it can carry the connection URL,
        // whose access_token is a live credential. Google's close reason
        // names the problem (a rejected model or token), not the token.
        let nsError = error as NSError
        geminiLiveLogger.error("Gemini Live connection lost: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) closeCode=\(serverClose?.code ?? 0, privacy: .public) closeReason=\(serverClose?.reason ?? "", privacy: .private)")
        socket?.close()
        socket = nil
        receiveTask = nil
        connectionID = UUID()
        let pendingSetup = awaitingSetup?.id == id ? awaitingSetup : nil
        if pendingSetup != nil { awaitingSetup = nil }
        // A refusal before setup won't change on retry. On a live
        // connection only a spent quota is handled that way; other closes
        // reconnect with resumption as before.
        if let serverClose, pendingSetup != nil ? serverClose.isRefusal : serverClose.isQuotaExhausted {
            dropHandoff()
            connectTask?.cancel()
            refused(serverClose, attempt: pendingSetup?.attempt ?? 0)
            return
        }
        guard let pendingSetup else {
            state = .reconnecting
            // The connection a GoAway handoff is already setting up carries
            // on and takes over once ready.
            guard !isHandingOff else { return }
            connectTask?.cancel()
            connectTask = Task { [weak self] in await self?.connect(attempt: 0) }
            return
        }
        connectTask?.cancel()
        // Closed before setupComplete: a failed attempt, not a lost
        // connection. The most recent explained close is the one worth naming.
        if let serverClose { lastSetupClose = serverClose }
        connectTask = Task { [weak self] in await self?.retry(after: pendingSetup.attempt, error: error) }
    }

    /// The connection a GoAway handoff was setting up closed before its
    /// setupComplete: a failed attempt. The current connection keeps
    /// serving while the next attempt runs.
    private func handoffFailed(error: Error, serverClose: GeminiLiveServerClose?) {
        let nsError = error as NSError
        geminiLiveLogger.error("Gemini Live handoff connection lost: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) closeCode=\(serverClose?.code ?? 0, privacy: .public) closeReason=\(serverClose?.reason ?? "", privacy: .private)")
        let attempt = awaitingSetup?.id == handoffID ? awaitingSetup?.attempt ?? 0 : 0
        awaitingSetup = nil
        handoffReceiveTask = nil
        handoffSocket?.close()
        handoffSocket = nil
        handoffID = nil
        connectTask?.cancel()
        if let serverClose, serverClose.isQuotaExhausted, googleSearch {
            // Search's own quota, as in `refused`: the next attempt goes
            // without it, still handing off from the current connection.
            geminiLiveLogger.notice("Gemini Live handoff refused for quota; retrying without Google Search")
            googleSearch = false
            let delay = reconnectDelay
            connectTask = Task { [weak self] in
                do { try await delay(attempt) } catch { return }
                guard let self, !Task.isCancelled, self.state != .stopped, !self.isFailed else { return }
                await self.connect(attempt: attempt)
            }
            return
        }
        if let serverClose, serverClose.isRefusal {
            fail(AppLocalization.string("Gemini Live refused the connection: \(serverClose.summary)"))
            return
        }
        if let serverClose { lastSetupClose = serverClose }
        connectTask = Task { [weak self] in await self?.retry(after: attempt, error: error) }
    }

    /// Google refused the connection. A spent quota while Search is on is
    /// most likely Search's own, so the same attempt runs again without it
    /// after the usual backoff; any other refusal (or a quota one without
    /// Search) is final.
    private func refused(_ close: GeminiLiveServerClose, attempt: Int) {
        if close.isQuotaExhausted, googleSearch {
            geminiLiveLogger.notice("Gemini Live refused for quota; retrying without Google Search")
            googleSearch = false
            if state == .ready { state = .reconnecting }
            connectTask?.cancel()
            let delay = reconnectDelay
            connectTask = Task { [weak self] in
                do { try await delay(attempt) } catch { return }
                guard let self, !Task.isCancelled, self.state != .stopped, !self.isFailed else { return }
                await self.connect(attempt: attempt)
            }
            return
        }
        fail(AppLocalization.string("Gemini Live refused the connection: \(close.summary)"))
    }

    private func retry(after attempt: Int, error: Error) async {
        guard attempt < Self.maximumReconnectAttempts else {
            if let close = lastSetupClose {
                fail(AppLocalization.string("Couldn't connect to Gemini Live: \(close.summary)"))
            } else {
                fail(AppLocalization.string("Couldn't connect to Gemini Live."))
            }
            return
        }
        // A handoff's current connection is still serving: stay ready.
        if state != .connecting, !(isHandingOff && socket != nil) { state = .reconnecting }
        do {
            try await reconnectDelay(attempt)
        } catch {
            return
        }
        guard !Task.isCancelled, state != .stopped, !isFailed else { return }
        await connect(attempt: attempt + 1)
    }
}
