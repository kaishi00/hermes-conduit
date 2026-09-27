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

@MainActor
protocol GeminiLiveSocket: AnyObject {
    func send(_ text: String) async throws
    /// The next frame's payload (text frames as UTF-8). Throws when the
    /// socket closes.
    func receive() async throws -> Data
    func close()
}

@MainActor
final class URLSessionGeminiLiveSocket: GeminiLiveSocket {
    private let task: URLSessionWebSocketTask

    init(url: URL, session: URLSession = .shared) {
        task = session.webSocketTask(with: url)
        // Model audio frames are larger than URLSession's 1 MB default.
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
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
        hasConnectedOnce = false
        state = .connecting
        connectTask = Task { [weak self] in await self?.connect(attempt: 0) }
    }

    func stop() {
        connectTask?.cancel()
        connectTask = nil
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
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket, id: id) }
    }

    private func receiveLoop(_ socket: GeminiLiveSocket, id: UUID) async {
        while !Task.isCancelled {
            let data: Data
            do {
                data = try await socket.receive()
            } catch {
                connectionFailed(id, error: error)
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

    private func connectionFailed(_ id: UUID, error: Error) {
        guard id == connectionID, state != .stopped else { return }
        // Never the error's description: it can carry the connection URL,
        // whose access_token is a live credential.
        let nsError = error as NSError
        geminiLiveLogger.error("Gemini Live connection lost: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
        socket?.close()
        socket = nil
        receiveTask = nil
        connectionID = UUID()
        state = .reconnecting
        connectTask?.cancel()
        connectTask = Task { [weak self] in await self?.connect(attempt: 0) }
    }

    private func retry(after attempt: Int, error: Error) async {
        guard attempt < Self.maximumReconnectAttempts else {
            state = .failed(AppLocalization.string("Couldn't connect to Gemini Live."))
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
