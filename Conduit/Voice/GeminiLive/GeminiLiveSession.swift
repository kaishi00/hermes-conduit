//
//  GeminiLiveSession.swift
//  Conduit
//
//  One logical Gemini Live conversation over one or more WebSockets. Every
//  connection gets a fresh single-use token from Hermes. A GoAway or a lost
//  socket reconnects with the latest session-resumption handle, so the
//  conversation (and its context-window compression) carries over.
//

import Foundation
import OSLog

private let geminiLiveLogger = Logger(subsystem: "com.milim.relay", category: "GeminiLive")

// MARK: - Transport

/// How the server ended a WebSocket: its close code and reason text.
struct GeminiLiveServerClose: Equatable {
    let code: Int
    let reason: String

    /// Codes that mean Google rejected what was sent (the setup, token or
    /// model), which a retry won't change: unsupported or invalid data,
    /// a policy violation, and the application-defined 4xxx range. Going
    /// away, abnormal and internal-error closes stay retryable.
    var isRefusal: Bool {
        [1003, 1007, 1008].contains(code) || (4000...4999).contains(code)
    }

    /// What the user is shown: the first line of Google's reason (capped),
    /// or the code when there is none.
    var summary: String {
        let firstLine = reason.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard !firstLine.isEmpty else {
            return AppLocalization.string("close code \(String(code))")
        }
        return firstLine.count > 200 ? String(firstLine.prefix(200)) + "…" : firstLine
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

    init(url: URL) {
        // A session of its own, so its delegate hears this socket's close.
        session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        task = session.webSocketTask(with: url)
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
        // The session retains its delegate until invalidated.
        session.finishTasksAndInvalidate()
    }

    func serverClose(within timeout: Duration) async -> GeminiLiveServerClose? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            if let recorded = delegate.serverClose { return recorded }
            if task.closeCode != .invalid {
                let text = task.closeReason.flatMap { String(data: $0, encoding: .utf8) }?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return GeminiLiveServerClose(code: task.closeCode.rawValue, reason: text)
            }
            guard ContinuousClock.now < deadline else { return nil }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

// MARK: - Session

@MainActor
final class GeminiLiveSession {
    enum State: Equatable {
        case idle
        case connecting
        case ready
        /// Switching to a new connection (GoAway or a dropped socket).
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

    private let tokens: GeminiLiveTokenProviding
    private let openSocket: @MainActor (URL) -> GeminiLiveSocket
    private let systemInstruction: String
    private let functions: [GeminiLiveProtocol.FunctionDeclaration]
    private let reconnectDelay: @Sendable (Int) async throws -> Void

    private var socket: GeminiLiveSocket?
    /// Identity of the connection whose frames are current. Frames from any
    /// other connection are ignored.
    private var connectionID = UUID()
    private var receiveTask: Task<Void, Never>?
    /// The connection being replaced during a GoAway handoff, closed once
    /// the new one is ready.
    private var retiringSocket: GeminiLiveSocket?
    private var retiringReceiveTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var hasConnectedOnce = false
    /// The connection still waiting for setupComplete, and which attempt it
    /// is. A socket that closes before setup is a failed attempt, not a
    /// lost connection, so it counts toward the retry limit.
    private var awaitingSetup: (id: UUID, attempt: Int)?
    /// The last close Google sent before setup, named if retries run out.
    private var lastSetupClose: GeminiLiveServerClose?

    init(
        tokens: GeminiLiveTokenProviding,
        systemInstruction: String,
        functions: [GeminiLiveProtocol.FunctionDeclaration],
        openSocket: @escaping @MainActor (URL) -> GeminiLiveSocket = { URLSessionGeminiLiveSocket(url: $0) },
        reconnectDelay: @escaping @Sendable (Int) async throws -> Void = { attempt in
            try await Task.sleep(for: .seconds(min(8, 1 << attempt)))
        }
    ) {
        self.tokens = tokens
        self.systemInstruction = systemInstruction
        self.functions = functions
        self.openSocket = openSocket
        self.reconnectDelay = reconnectDelay
    }

    var isReady: Bool { state == .ready }

    func start() {
        guard state == .idle || state == .stopped || isFailed else { return }
        resumptionHandle = nil
        lastSetupClose = nil
        hasConnectedOnce = false
        state = .connecting
        connectTask = Task { [weak self] in await self?.connect(attempt: 0) }
    }

    func stop() {
        connectTask?.cancel()
        connectTask = nil
        awaitingSetup = nil
        receiveTask?.cancel()
        receiveTask = nil
        retiringReceiveTask?.cancel()
        retiringReceiveTask = nil
        socket?.close()
        socket = nil
        retiringSocket?.close()
        retiringSocket = nil
        connectionID = UUID()
        state = .stopped
    }

    func send(_ message: [String: Any], onFailure: (@MainActor () -> Void)?) {
        guard state == .ready, let socket, let text = try? GeminiLiveProtocol.encode(message) else {
            onFailure?()
            return
        }
        let id = connectionID
        Task { [weak self] in
            do {
                try await socket.send(text)
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
                retireHandoff()
                receiveTask?.cancel()
                receiveTask = nil
                socket?.close()
                socket = nil
                state = .failed(error.localizedDescription)
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
            resumptionHandle: resumptionHandle
        )
        do {
            try await socket.send(try GeminiLiveProtocol.encode(setup))
        } catch {
            socket.close()
            guard !Task.isCancelled, state != .stopped else { return }
            await retry(after: attempt, error: error)
            return
        }
        guard !Task.isCancelled, state != .stopped else {
            socket.close()
            return
        }
        // The previous connection (if any) keeps serving until this one is
        // set up: a GoAway still gives it `timeLeft` to finish.
        if let current = self.socket {
            retiringSocket = current
            retiringReceiveTask = receiveTask
        }
        self.socket = socket
        connectionID = id
        awaitingSetup = (id, attempt)
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
            guard id == connectionID else { return }
            for event in GeminiLiveProtocol.decode(data) {
                handle(event, connection: id)
            }
        }
    }

    private func handle(_ event: GeminiLiveProtocol.ServerEvent, connection id: UUID) {
        switch event {
        case .setupComplete:
            let replaced = hasConnectedOnce
            hasConnectedOnce = true
            awaitingSetup = nil
            lastSetupClose = nil
            retiringReceiveTask?.cancel()
            retiringReceiveTask = nil
            retiringSocket?.close()
            retiringSocket = nil
            // Calls opened on the previous connection are gone before anyone
            // sees `.ready` and starts answering on this one.
            if replaced { onConnectionReplaced?() }
            state = .ready
        case .resumptionUpdate(let handle, let resumable):
            if resumable, let handle { resumptionHandle = handle }
        case .goAway(let timeLeft):
            geminiLiveLogger.notice("GoAway received (timeLeft=\(timeLeft ?? -1, privacy: .public)s); reconnecting with resumption")
            beginReconnect()
            return
        default:
            break
        }
        onEvent?(event)
    }

    private func beginReconnect() {
        guard state != .stopped, state != .reconnecting else { return }
        state = .reconnecting
        connectTask?.cancel()
        connectTask = Task { [weak self] in await self?.connect(attempt: 0) }
    }

    private func connectionFailed(_ id: UUID, error: Error, serverClose: GeminiLiveServerClose? = nil) {
        guard id == connectionID, state != .stopped else { return }
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
        awaitingSetup = nil
        connectTask?.cancel()
        guard let pendingSetup else {
            state = .reconnecting
            connectTask = Task { [weak self] in await self?.connect(attempt: 0) }
            return
        }
        // Closed before setupComplete: a failed attempt, not a lost
        // connection. A deliberate refusal won't change on retry.
        if let serverClose, serverClose.isRefusal {
            retireHandoff()
            state = .failed(AppLocalization.string("Gemini Live refused the connection: \(serverClose.summary)"))
            return
        }
        if let serverClose { lastSetupClose = serverClose }
        connectTask = Task { [weak self] in await self?.retry(after: pendingSetup.attempt, error: error) }
    }

    /// The connection a GoAway handoff was replacing, closed when the
    /// session gives up on the handoff.
    private func retireHandoff() {
        retiringReceiveTask?.cancel()
        retiringReceiveTask = nil
        retiringSocket?.close()
        retiringSocket = nil
    }

    private func retry(after attempt: Int, error: Error) async {
        guard attempt < Self.maximumReconnectAttempts else {
            retireHandoff()
            if let close = lastSetupClose {
                state = .failed(AppLocalization.string("Couldn't connect to Gemini Live: \(close.summary)"))
            } else {
                state = .failed(AppLocalization.string("Couldn't connect to Gemini Live."))
            }
            return
        }
        if state != .connecting { state = .reconnecting }
        do {
            try await reconnectDelay(attempt)
        } catch {
            return
        }
        guard !Task.isCancelled, state != .stopped else { return }
        await connect(attempt: attempt + 1)
    }
}
