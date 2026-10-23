//
//  GeminiLiveSessionControlling.swift
//  Conduit and the Conduit Watch app
//
//  The seam a live voice conversation drives its session through: Gemini
//  Live's own, or Grok Live's (xAI's events read as Gemini Live's), on
//  the iPhone and on the Watch alike.
//

import Foundation

@MainActor
protocol GeminiLiveSessionControlling: AnyObject {
    var onEvent: (@MainActor (GeminiLiveProtocol.ServerEvent) -> Void)? { get set }
    var onStateChange: (@MainActor (GeminiLiveSession.State) -> Void)? { get set }
    var onConnectionReplaced: (@MainActor () -> Void)? { get set }
    /// A new server session replaced one Google wouldn't resume, so the
    /// model lost the conversation (see `GeminiLiveSession.onFreshSession`).
    var onFreshSession: (@MainActor (_ heardDropout: Bool) -> Void)? { get set }
    var isReady: Bool { get }
    /// True when this connection runs a provider's own agent (Live > Local):
    /// the model on the front decides and Hermes works behind it, so what
    /// Hermes finds out later is news to the call. False when Hermes answers
    /// each utterance itself.
    var runsAgentTurns: Bool { get }
    /// Changes whenever a new connection takes over; calls made before
    /// the change can't be answered after it.
    var connectionGeneration: Int { get }
    /// The session's state, for logs.
    var stateDescription: String { get }
    /// True when each input transcription is a whole finished utterance
    /// (Grok Live's come once the user stopped), so it needn't end like a
    /// sentence to count as finished. Gemini's arrive in pieces.
    var transcribesWholeUtterances: Bool { get }
    func start()
    func stop()
    /// `onSent` runs once the socket took the message; `onFailure` when it
    /// never reached the socket.
    func send(_ message: LiveVoiceClientMessage, onSent: (@MainActor () -> Void)?, onFailure: (@MainActor () -> Void)?)
}

extension GeminiLiveSessionControlling {
    var connectionGeneration: Int { 0 }
    /// Sessions that never resume (Grok Live) never start one fresh, so
    /// setting this on them does nothing, on purpose.
    var onFreshSession: (@MainActor (_ heardDropout: Bool) -> Void)? {
        get { nil }
        set {}
    }
    var stateDescription: String { "" }
    var transcribesWholeUtterances: Bool { false }
    /// Only Local Live has a mode of its own; every other session here is
    /// the live model itself.
    var runsAgentTurns: Bool { false }
    func send(_ message: LiveVoiceClientMessage) { send(message, onSent: nil, onFailure: nil) }
    func send(_ message: LiveVoiceClientMessage, onFailure: (@MainActor () -> Void)?) {
        send(message, onSent: nil, onFailure: onFailure)
    }
}

extension GeminiLiveSession: GeminiLiveSessionControlling {
    var stateDescription: String { "\(state)" }
}
