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
    /// How long a call may stay in WebRTC's temporary `.disconnected`
    /// state (a network handoff) before it counts as lost.
    nonisolated static let reconnectGrace: Duration = .seconds(6)

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    private(set) var sessionID: String?
    /// Set when the host did not start the call with the voice asked for.
    private(set) var voiceNote: String?
    /// True when the host already gave the model the briefing (see
    /// `GPTLiveSessionAnswer.briefingApplied`).
    private(set) var briefingApplied = false
    /// True when the host made the model greet first.
    private(set) var greetingApplied = false

    var onEvent: (@MainActor (GPTLiveProtocol.ServerEvent) -> Void)?
    var onStateChange: (@MainActor (State) -> Void)?
    /// The call's audio paused for another sound or came back.
    var onAudioPaused: (@MainActor (Bool) -> Void)?

    private let client: GPTLiveSessionProviding
    private let history: [[String: Any]]
    /// The voice for this call; nil keeps the host's configured voice.
    private let voice: String?
    /// Conduit's rules for this call, offered to the host with the offer.
    private let briefing: String?
    /// The greeting the user asked for when the call connects (#290).
    private let greeting: String?
    private let makePeer: @MainActor () -> GPTLivePeer
    private let startTimeout: Duration
    private let reconnectGrace: Duration
    private var peer: GPTLivePeer?
    private var connectTask: Task<Void, Never>?
    private var startWatchdog: Task<Void, Never>?
    /// Runs while the connection is interrupted; fails the call if it
    /// doesn't come back in time.
    private var reconnectWatchdog: Task<Void, Never>?

    init(
        client: GPTLiveSessionProviding,
        history: [[String: Any]] = [],
        voice: String? = nil,
        briefing: String? = nil,
        greeting: String? = nil,
        makePeer: @escaping @MainActor () -> GPTLivePeer = { WebRTCGPTLivePeer() },
        startTimeout: Duration = GPTLiveSession.startTimeout,
        reconnectGrace: Duration = GPTLiveSession.reconnectGrace
    ) {
        self.client = client
        self.history = history
        self.voice = voice
        self.briefing = briefing
        self.greeting = greeting
        self.makePeer = makePeer
        self.startTimeout = startTimeout
        self.reconnectGrace = reconnectGrace
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
        peer.onConnectionInterrupted = { [weak self, weak peer] interrupted in
            guard let self, let peer, self.peer === peer else { return }
            self.connectionInterrupted(interrupted, peer: peer)
        }
        peer.onAudioPaused = { [weak self, weak peer] paused in
            guard let self, let peer, self.peer === peer, self.state == .ready || self.state == .connecting else { return }
            self.onAudioPaused?(paused)
        }
        connectTask = Task { [weak self] in await self?.connect(peer) }
    }

    /// Ends the call now: GPT-Live is told (`session.close`, best effort)
    /// and the peer closes without waiting for its answer. The controller
    /// only ends a call once the goodbye has played, so nothing is left to
    /// wait for.
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
    /// Empty text has nothing to deliver and counts as delivered.
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
            let answer = try await client.createSession(offer: offer, history: history, voice: voice, briefing: briefing, greeting: greeting)
            guard isCurrent(peer) else { return }
            sessionID = answer.sessionID
            briefingApplied = answer.briefingApplied
            greetingApplied = answer.greetingApplied
            voiceNote = Self.voiceNote(requested: voice, applied: answer.voice)
            try await peer.acceptAnswer(answer.sdp)
            guard isCurrent(peer) else { return }
        } catch {
            guard isCurrent(peer) else { return }
            fail(UserFacingError.message(for: error))
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

    /// Explains a chosen voice the host didn't use. Nil when none was asked
    /// for, or the host used it.
    nonisolated static func voiceNote(requested: String?, applied: String?) -> String? {
        guard let requested, !requested.isEmpty else { return nil }
        guard let applied else {
            return AppLocalization.string("The Conduit plugin on your Hermes server didn't confirm the voice you chose. Update the plugin to pick a voice.")
        }
        guard applied.lowercased() != requested.lowercased() else { return nil }
        return AppLocalization.string("Your Hermes server used the voice \(applied) instead of \(requested).")
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

    /// WebRTC dropped to `.disconnected`, which usually recovers: the call
    /// is kept for `reconnectGrace` and only then counted as lost.
    private func connectionInterrupted(_ interrupted: Bool, peer: GPTLivePeer) {
        reconnectWatchdog?.cancel()
        reconnectWatchdog = nil
        guard interrupted, state == .ready || state == .connecting else { return }
        let grace = reconnectGrace
        reconnectWatchdog = Task { [weak self, weak peer] in
            do { try await Task.sleep(for: grace) } catch { return }
            guard let self, let peer, self.peer === peer else { return }
            self.reconnectWatchdog = nil
            gptLiveLogger.notice("GPT-Live connection didn't come back")
            self.connectionLost()
        }
    }

    private func connectionLost() {
        guard state == .ready || state == .connecting else { return }
        gptLiveLogger.notice("GPT-Live connection lost")
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
        reconnectWatchdog?.cancel()
        reconnectWatchdog = nil
        peer?.onMessage = nil
        peer?.onDisconnected = nil
        peer?.onConnectionInterrupted = nil
        peer?.onAudioPaused = nil
        peer?.close()
        peer = nil
    }
}
