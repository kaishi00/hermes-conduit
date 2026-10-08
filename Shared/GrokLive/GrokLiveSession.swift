//
//  GrokLiveSession.swift
//  Conduit and the Conduit Watch app
//
//  One Grok Live conversation through the Hermes host: the phone's relay
//  socket on the dashboard, or the Watch's audio bridge through the push
//  relay (WatchGrokBridgeSocket). The first frame is the session.update
//  (instructions, voice, tools); the session is ready once xAI confirms
//  it. xAI has no session resumption, so a dropped connection reconnects
//  as a new xAI session: calls opened on the old one can't be answered
//  there, and the controller hears about it through
//  `onConnectionReplaced`.
//
//  It speaks the same seam as Gemini Live's session, so the Gemini Live
//  conversation controller (phases, transcript, jobs, the speaker echo
//  guard, hands-free end) drives Grok Live unchanged.
//

import Foundation
import OSLog

private let grokLiveLogger = Logger(subsystem: "com.milim.relay", category: "GrokLive")

@MainActor
final class GrokLiveSession: GeminiLiveSessionControlling {
    typealias State = GeminiLiveSession.State

    /// Retries after a connection attempt fails, for the first connect and
    /// every reconnect alike (so at most 1 + 3 attempts in a row).
    static let maximumReconnectAttempts = 3

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    var onEvent: (@MainActor (GeminiLiveProtocol.ServerEvent) -> Void)?
    var onStateChange: (@MainActor (State) -> Void)?
    var onConnectionReplaced: (@MainActor () -> Void)?
    private(set) var connectionGeneration = 0

    private let client: GrokLiveConnecting
    private let instructions: String
    private let functions: [GeminiLiveProtocol.FunctionDeclaration]
    private let voice: String?
    private let openSocket: @MainActor (URLRequest) -> GeminiLiveSocket
    /// MainActor like the session: a nonisolated delay would hop to the
    /// cooperative pool and back on every retry, which tests' fixed
    /// `Task.yield` settles cannot always cover on a loaded runner.
    private let reconnectDelay: @MainActor @Sendable (Int) async throws -> Void

    private var socket: GeminiLiveSocket?
    /// Identity of the current connection; frames from any other are ignored.
    private var connectionID = UUID()
    private var receiveTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var hasConnectedOnce = false
    /// The connection still waiting for session.updated, and which attempt
    /// it is: a socket that closes before then is a failed attempt.
    private var awaitingSetup: (id: UUID, attempt: Int)?
    private var lastSetupClose: GeminiLiveServerClose?
    /// Whether xAI is producing a response. A `response.create` while one
    /// runs is refused, so it waits for the running one to finish.
    private var responseActive = false
    private var responseRequested = false
    /// Whether xAI confirmed (response.created) the response counted as
    /// running. An error before that means it refused the request, and no
    /// response.done will follow to clear it.
    private var responseConfirmed = false
    /// Turns sent while a response ran, waiting for their response.create.
    private var queuedTurns: [Turn] = []
    /// Turns whose response.create went out, until xAI starts the response
    /// (delivered) or refuses it (failed, so they are sent again).
    private var unconfirmedTurns: [Turn] = []
    /// How long a running response may go without any event before it
    /// counts as lost, so a missing response.done can't silence the call.
    private let responseTimeout: Duration
    private var responseWatchdog: Task<Void, Never>?
    /// How long a connection may wait for session.updated before it counts
    /// as a failed attempt.
    private let setupTimeout: Duration
    private var setupTimeoutTask: Task<Void, Never>?
    /// Whether the current response's transcript came as deltas; if not,
    /// its final transcript is shown instead.
    private var responseHadTranscript = false

    init(
        client: GrokLiveConnecting,
        instructions: String,
        functions: [GeminiLiveProtocol.FunctionDeclaration],
        voice: String? = nil,
        openSocket: @escaping @MainActor (URLRequest) -> GeminiLiveSocket = { URLSessionGeminiLiveSocket(request: $0) },
        setupTimeout: Duration = .seconds(15),
        responseTimeout: Duration = .seconds(30),
        reconnectDelay: @escaping @MainActor @Sendable (Int) async throws -> Void = { attempt in
            try await Task.sleep(for: .seconds(min(8, 1 << attempt)))
        }
    ) {
        self.client = client
        self.instructions = instructions
        self.functions = functions
        self.voice = voice
        self.openSocket = openSocket
        self.setupTimeout = setupTimeout
        self.responseTimeout = responseTimeout
        self.reconnectDelay = reconnectDelay
    }

    var isReady: Bool { state == .ready }

    func start() {
        guard state == .idle || state == .stopped || isFailed else { return }
        lastSetupClose = nil
        hasConnectedOnce = false
        state = .connecting
        connectTask = Task { [weak self] in await self?.connect(attempt: 0) }
    }

    func stop() {
        closeConnection()
        state = .stopped
    }

    func send(_ message: LiveVoiceClientMessage, onSent: (@MainActor () -> Void)?, onFailure: (@MainActor () -> Void)?) {
        let (frames, wantsResponse) = GrokLiveProtocol.frames(for: message)
        guard state == .ready, let socket else {
            onFailure?()
            return
        }
        let texts = frames.compactMap { try? GrokLiveProtocol.encode($0) }
        guard texts.count == frames.count else {
            onFailure?()
            return
        }
        let id = connectionID
        Task { [weak self] in
            do {
                for text in texts { try await socket.send(text) }
            } catch {
                onFailure?()
                self?.connectionFailed(id, error: error)
                return
            }
            guard wantsResponse else {
                onSent?()
                return
            }
            // A turn the model should answer is delivered once xAI confirms
            // the response (response.created); a refused request, a stall
            // or a lost connection before that reports it failed, so its
            // update is requeued instead of dropped.
            switch self?.takeResponseRequest(on: id, turn: (sent: onSent, failed: onFailure)) {
            case .send(let create)?:
                do {
                    try await socket.send(create)
                } catch {
                    // Settles the turn with the rest of the connection's.
                    self?.connectionFailed(id, error: error)
                }
            case .queued?:
                break
            case .connectionGone?, nil:
                // The connection was replaced or ended while this turn was
                // going out: nothing will answer it here.
                onFailure?()
            }
        }
    }

    // MARK: Responses

    private typealias Turn = (sent: (@MainActor () -> Void)?, failed: (@MainActor () -> Void)?)

    private enum ResponseRequest {
        /// Send this response.create now.
        case send(String)
        /// Sent once the running response ends.
        case queued
        /// The connection the turn went out on is no longer the session's.
        case connectionGone
    }

    /// Asks the model to answer, now or once the current response ends.
    private func takeResponseRequest(on id: UUID, turn: Turn) -> ResponseRequest {
        guard id == connectionID, state == .ready,
              let text = try? GrokLiveProtocol.encode(GrokLiveProtocol.responseCreate) else { return .connectionGone }
        guard !responseActive else {
            responseRequested = true
            queuedTurns.append(turn)
            return .queued
        }
        beginRequest(with: [turn])
        return .send(text)
    }

    /// Counts a response as running from its request on, so a second
    /// request waits for it; `turns` are settled when xAI answers.
    private func beginRequest(with turns: [Turn]) {
        responseRequested = false
        responseActive = true
        responseConfirmed = false
        unconfirmedTurns += turns
        armResponseWatchdog()
    }

    /// Sends the queued request for the turns that waited on it.
    private func sendResponseCreate() {
        guard let socket, let text = try? GrokLiveProtocol.encode(GrokLiveProtocol.responseCreate) else { return }
        let turns = queuedTurns
        queuedTurns = []
        beginRequest(with: turns)
        let id = connectionID
        Task { [weak self] in
            do {
                try await socket.send(text)
            } catch {
                self?.connectionFailed(id, error: error)
            }
        }
    }

    /// xAI started the requested response: its turns were delivered.
    private func confirmRequest() {
        responseConfirmed = true
        let turns = unconfirmedTurns
        unconfirmedTurns = []
        for turn in turns { turn.sent?() }
    }

    /// The request got no response (refused, or stalled before starting):
    /// its turns go back to be sent again.
    private func failUnconfirmedTurns() {
        let turns = unconfirmedTurns
        unconfirmedTurns = []
        for turn in turns { turn.failed?() }
    }

    /// (Re)starts the wait for the running response's next event.
    private func armResponseWatchdog() {
        responseWatchdog?.cancel()
        let id = connectionID
        let timeout = responseTimeout
        responseWatchdog = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, id == self.connectionID, self.responseActive else { return }
            grokLiveLogger.error("Grok Live response stalled; no longer waiting for it")
            self.responseActive = false
            self.failUnconfirmedTurns()
            if self.responseRequested { self.sendResponseCreate() }
        }
    }

    /// The connection ended: nothing runs on it, and turns not yet answered
    /// on it never will be.
    private func dropResponseState() {
        responseWatchdog?.cancel()
        responseWatchdog = nil
        responseActive = false
        responseRequested = false
        failUnconfirmedTurns()
        let turns = queuedTurns
        queuedTurns = []
        for turn in turns { turn.failed?() }
    }

    // MARK: Connection

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func fail(_ message: String) {
        closeConnection()
        state = .failed(message)
    }

    private func closeConnection() {
        connectTask?.cancel()
        connectTask = nil
        awaitingSetup = nil
        setupTimeoutTask?.cancel()
        setupTimeoutTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.close()
        socket = nil
        connectionID = UUID()
        dropResponseState()
    }

    private func connect(attempt: Int) async {
        let request: URLRequest
        do {
            request = try await client.socketRequest()
        } catch {
            guard !Task.isCancelled, state != .stopped, !isFailed else { return }
            await retry(after: attempt, error: error)
            return
        }
        guard !Task.isCancelled, state != .stopped, !isFailed else { return }
        let socket = openSocket(request)
        let update = GrokLiveProtocol.sessionUpdate(instructions: instructions, functions: functions, voice: voice)
        do {
            try await socket.send(try GrokLiveProtocol.encode(update))
        } catch {
            // A refused WebSocket upgrade surfaces here, on the first send.
            let close = await socket.serverClose(within: .milliseconds(400))
            socket.close()
            guard !Task.isCancelled, state != .stopped, !isFailed else { return }
            if let close, Self.isRefusal(close) {
                fail(Self.refusalMessage(close))
                return
            }
            if let close { lastSetupClose = close }
            await retry(after: attempt, error: error)
            return
        }
        guard !Task.isCancelled, state != .stopped, !isFailed else {
            socket.close()
            return
        }
        let id = UUID()
        receiveTask?.cancel()
        self.socket?.close()
        self.socket = socket
        connectionID = id
        awaitingSetup = (id, attempt)
        responseActive = false
        responseRequested = false
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket, id: id) }
        // A server that neither confirms the session nor closes would leave
        // the call connecting forever.
        let timeout = setupTimeout
        setupTimeoutTask?.cancel()
        setupTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.awaitingSetup?.id == id else { return }
            grokLiveLogger.error("Grok Live session setup timed out")
            self.connectionFailed(id, error: URLError(.timedOut))
        }
    }

    private func receiveLoop(_ socket: GeminiLiveSocket, id: UUID) async {
        while !Task.isCancelled {
            let data: Data
            do {
                data = try await socket.receive()
            } catch {
                let beforeSetup = awaitingSetup?.id == id
                let close = await socket.serverClose(within: beforeSetup ? .milliseconds(400) : .milliseconds(100))
                connectionFailed(id, error: error, serverClose: close)
                return
            }
            for frame in GrokLiveProtocol.decode(data) {
                // A frame can end this connection.
                guard id == connectionID else { return }
                handle(frame, connection: id)
            }
        }
    }

    private func handle(_ frame: GrokLiveProtocol.ServerFrame, connection id: UUID) {
        switch frame {
        case .sessionUpdated:
            guard awaitingSetup?.id == id else { return }
            awaitingSetup = nil
            setupTimeoutTask?.cancel()
            setupTimeoutTask = nil
            lastSetupClose = nil
            let replaced = hasConnectedOnce
            hasConnectedOnce = true
            if replaced {
                connectionGeneration += 1
                onConnectionReplaced?()
            }
            state = .ready
        case .error(let message):
            // Before the session is set up, xAI refused it (the instructions,
            // tools or voice): a retry would send the same.
            if awaitingSetup?.id == id {
                grokLiveLogger.error("Grok Live refused the session setup")
                fail(message.isEmpty
                    ? AppLocalization.string("Grok Live refused the connection.")
                    : AppLocalization.string("Grok Live refused the connection: \(Self.clipped(message))"))
                return
            }
            // A refused response.create or similar: the conversation goes on.
            grokLiveLogger.notice("Grok Live error event: \(message, privacy: .private)")
            if responseActive, !responseConfirmed {
                // The request that was counted as running was refused: no
                // response.done will clear it, so later turns would wait forever.
                responseActive = false
                responseWatchdog?.cancel()
                failUnconfirmedTurns()
                if responseRequested { sendResponseCreate() }
            }
        case .responseStarted:
            responseActive = true
            confirmRequest()
            responseHadTranscript = false
            armResponseWatchdog()
        case .responseDone:
            responseActive = false
            responseWatchdog?.cancel()
            // A response that ended without ever starting answered nothing.
            failUnconfirmedTurns()
            if responseRequested { sendResponseCreate() }
        case .outputTranscriptDone(let text):
            if !responseHadTranscript { onEvent?(.outputTranscription(text)) }
        case .event(let event):
            if case .outputTranscription = event { responseHadTranscript = true }
            if responseActive { armResponseWatchdog() }
            onEvent?(event)
        }
    }

    private func connectionFailed(_ id: UUID, error: Error, serverClose: GeminiLiveServerClose? = nil) {
        guard id == connectionID, state != .stopped, !isFailed else { return }
        // Never the error's description: it can carry the connection URL,
        // whose ticket is a credential.
        let nsError = error as NSError
        grokLiveLogger.error("Grok Live connection lost: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) closeCode=\(serverClose?.code ?? 0, privacy: .public)")
        let pendingSetup = awaitingSetup?.id == id ? awaitingSetup : nil
        socket?.close()
        socket = nil
        receiveTask?.cancel()
        receiveTask = nil
        awaitingSetup = nil
        setupTimeoutTask?.cancel()
        setupTimeoutTask = nil
        connectionID = UUID()
        dropResponseState()
        if let serverClose, Self.isRefusal(serverClose) {
            fail(Self.refusalMessage(serverClose))
            return
        }
        connectTask?.cancel()
        guard let pendingSetup else {
            // A live conversation dropped: start a new xAI session.
            state = .reconnecting
            connectTask = Task { [weak self] in await self?.connect(attempt: 0) }
            return
        }
        if let serverClose { lastSetupClose = serverClose }
        connectTask = Task { [weak self] in await self?.retry(after: pendingSetup.attempt, error: error) }
    }

    private func retry(after attempt: Int, error: Error) async {
        guard attempt < Self.maximumReconnectAttempts else {
            if let close = lastSetupClose {
                fail(AppLocalization.string("Couldn't connect to Grok Live: \(close.summary)"))
            } else if let reason = (error as? LocalizedError)?.errorDescription, !(error is URLError) {
                // The dashboard's own reason (signed out, no ticket…).
                fail(reason)
            } else {
                fail(AppLocalization.string("Couldn't connect to Grok Live."))
            }
            return
        }
        if state != .connecting { state = .reconnecting }
        do {
            try await reconnectDelay(attempt)
        } catch {
            return
        }
        guard !Task.isCancelled, state != .stopped, !isFailed else { return }
        await connect(attempt: attempt + 1)
    }

    // MARK: Closes

    /// The relay's 4502 (xAI unreachable or dropped) is worth retrying; any
    /// other 4xxx is the plugin or xAI refusing what a retry would resend,
    /// as is a dashboard that refused the upgrade.
    nonisolated static func isRefusal(_ close: GeminiLiveServerClose) -> Bool {
        if close.isHTTPStatus { return [400, 401, 403, 404].contains(close.code) }
        if close.code == 4502 { return false }
        return [1003, 1007, 1008, 1009].contains(close.code) || (4000...4999).contains(close.code)
    }

    nonisolated static func refusalMessage(_ close: GeminiLiveServerClose) -> String {
        if close.isHTTPStatus, close.code == 404 {
            return GrokLiveAvailability.pluginMissing.userFacingReason ?? close.summary
        }
        return AppLocalization.string("Grok Live refused the connection: \(close.summary)")
    }

    nonisolated static func clipped(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        guard line.count > 300 else { return line }
        return String(line.prefix(300)) + "…"
    }
}
