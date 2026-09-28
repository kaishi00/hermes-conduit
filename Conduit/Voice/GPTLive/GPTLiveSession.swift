//
//  GPTLiveSession.swift
//  Conduit
//
//  One GPT-Live call: the WebRTC offer goes to the Hermes host, which
//  starts the call on the ChatGPT subscription and returns GPT-Live's
//  answer; the session is ready once GPT-Live reports `session.started` on
//  the data channel. A call that drops is not resumed (a new call is a new
//  conversation): the session fails and the user can start again.
//

import Foundation
import OSLog

private let gptLiveLogger = Logger(subsystem: "com.milim.relay", category: "GPTLive")

@MainActor
final class GPTLiveSession {
    enum State: Equatable {
        case idle
        case connecting
        case ready
        case failed(String)
        case stopped
    }

    /// How long GPT-Live has, after the answer, to start the session.
    nonisolated static let startTimeout: Duration = .seconds(15)
    /// How long a graceful close waits for `session.closed`.
    nonisolated static let closeTimeout: Duration = .seconds(2)

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    private(set) var sessionID: String?

    var onEvent: (@MainActor (GPTLiveProtocol.ServerEvent) -> Void)?
    var onStateChange: (@MainActor (State) -> Void)?

    private let client: GPTLiveSessionProviding
    private let history: [[String: Any]]
    private let makePeer: @MainActor () -> GPTLivePeer
    private let startTimeout: Duration
    private var peer: GPTLivePeer?
    private var connectTask: Task<Void, Never>?
    private var startWatchdog: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?

    init(
        client: GPTLiveSessionProviding,
        history: [[String: Any]] = [],
        makePeer: @escaping @MainActor () -> GPTLivePeer = { WebRTCGPTLivePeer() },
        startTimeout: Duration = GPTLiveSession.startTimeout
    ) {
        self.client = client
        self.history = history
        self.makePeer = makePeer
        self.startTimeout = startTimeout
    }

    var isReady: Bool { state == .ready }

    func start() {
        guard state == .idle || state == .stopped || isFailed else { return }
        sessionID = nil
        state = .connecting
        let peer = makePeer()
        self.peer = peer
        peer.onMessage = { [weak self, weak peer] text in
            guard let self, let peer, self.peer === peer else { return }
            self.received(text)
        }
        peer.onDisconnected = { [weak self, weak peer] in
            guard let self, let peer, self.peer === peer else { return }
            self.connectionLost()
        }
        peer.onAudioLost = { [weak self, weak peer] message in
            guard let self, let peer, self.peer === peer, self.state == .ready || self.state == .connecting else { return }
            self.fail(message)
        }
        connectTask = Task { [weak self] in await self?.connect(peer) }
    }

    /// Ends the call now, without waiting for GPT-Live.
    func stop() {
        guard state != .stopped else { return }
        if let peer, state == .ready {
            // Best effort: lets GPT-Live end its side cleanly.
            peer.send((try? GPTLiveProtocol.encode(GPTLiveProtocol.sessionCloseMessage())) ?? "")
        }
        tearDown()
        state = .stopped
    }

    /// Sends `text` as context appends (chunked). True once any of it went
    /// out, so a caller never sends it twice; false only when none did.
    @discardableResult
    func appendContext(_ text: String, channel: GPTLiveProtocol.Channel, delegationID: String?) -> Bool {
        guard state == .ready, let peer else { return false }
        let messages = GPTLiveProtocol.contextAppendMessages(text, channel: channel, delegationID: delegationID)
        guard !messages.isEmpty else { return true }
        for (index, message) in messages.enumerated() {
            guard let encoded = try? GPTLiveProtocol.encode(message), peer.send(encoded) else {
                if index > 0 {
                    gptLiveLogger.error("GPT-Live context append cut short after \(index, privacy: .public) of \(messages.count, privacy: .public) chunks")
                }
                return index > 0
            }
        }
        return true
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        peer?.setMicrophoneEnabled(enabled)
    }

    // MARK: Connection

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func connect(_ peer: GPTLivePeer) async {
        do {
            let offer = try await peer.makeOffer()
            guard isCurrent(peer) else { return }
            let answer = try await client.createSession(offer: offer, history: history)
            guard isCurrent(peer) else { return }
            sessionID = answer.sessionID
            try await peer.acceptAnswer(answer.sdp)
            guard isCurrent(peer) else { return }
        } catch {
            guard isCurrent(peer) else { return }
            fail(error.localizedDescription)
            return
        }
        let timeout = startTimeout
        startWatchdog = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.isCurrent(peer), self.state == .connecting else { return }
            gptLiveLogger.error("GPT-Live never reported session.started")
            self.fail(AppLocalization.string("GPT-Live didn't start the conversation. Try again."))
        }
    }

    private func isCurrent(_ peer: GPTLivePeer) -> Bool {
        !Task.isCancelled && self.peer === peer && state == .connecting
    }

    private func received(_ text: String) {
        guard let event = GPTLiveProtocol.decode(text) else { return }
        switch event {
        case .sessionStarted(let id):
            if let id { sessionID = id }
            if state == .connecting {
                startWatchdog?.cancel()
                startWatchdog = nil
                state = .ready
            }
        case .error(let code, let message):
            // A late append after a close is expected noise.
            if code == "context_injection_incomplete" { return }
            gptLiveLogger.error("GPT-Live error: code=\(code ?? "", privacy: .public) message=\(message, privacy: .private)")
            if state == .connecting {
                fail(message.isEmpty
                    ? AppLocalization.string("GPT-Live didn't start the conversation. Try again.")
                    : AppLocalization.string("GPT-Live refused the conversation: \(message)"))
                return
            }
        case .sessionClosed:
            closeTask?.cancel()
            closeTask = nil
            onEvent?(event)
            if state != .stopped, !isFailed {
                tearDown()
                state = .stopped
            }
            return
        default:
            break
        }
        onEvent?(event)
    }

    /// Asks GPT-Live to end the call and tears down once it confirms (or
    /// after `closeTimeout`). `session.closed` still reaches `onEvent`.
    func close() {
        guard state == .ready, let peer, closeTask == nil else {
            stop()
            return
        }
        guard let message = try? GPTLiveProtocol.encode(GPTLiveProtocol.sessionCloseMessage()), peer.send(message) else {
            stop()
            return
        }
        closeTask = Task { [weak self] in
            do { try await Task.sleep(for: GPTLiveSession.closeTimeout) } catch { return }
            guard let self, self.peer === peer else { return }
            self.closeTask = nil
            self.onEvent?(.sessionClosed(reason: "close_requested"))
            if self.state != .stopped {
                self.tearDown()
                self.state = .stopped
            }
        }
    }

    private func connectionLost() {
        guard state == .ready || state == .connecting else { return }
        gptLiveLogger.notice("GPT-Live connection lost")
        if closeTask != nil {
            // Closing anyway: the drop is the close.
            closeTask?.cancel()
            closeTask = nil
            onEvent?(.sessionClosed(reason: "connection_lost"))
            tearDown()
            state = .stopped
            return
        }
        fail(AppLocalization.string("The GPT-Live connection was lost."))
    }

    private func fail(_ message: String) {
        tearDown()
        state = .failed(message)
    }

    private func tearDown() {
        connectTask?.cancel()
        connectTask = nil
        startWatchdog?.cancel()
        startWatchdog = nil
        closeTask?.cancel()
        closeTask = nil
        peer?.onMessage = nil
        peer?.onDisconnected = nil
        peer?.onAudioLost = nil
        peer?.close()
        peer = nil
    }
}
