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
    var isReady: Bool { get }
    /// Changes whenever a new connection takes over; calls made before
    /// the change can't be answered after it.
    var connectionGeneration: Int { get }
    func start()
    func stop()
    /// `onSent` runs once the socket took the message; `onFailure` when it
    /// never reached the socket.
    func send(_ message: LiveVoiceClientMessage, onSent: (@MainActor () -> Void)?, onFailure: (@MainActor () -> Void)?)
}

extension GeminiLiveSessionControlling {
    var connectionGeneration: Int { 0 }
    func send(_ message: LiveVoiceClientMessage) { send(message, onSent: nil, onFailure: nil) }
    func send(_ message: LiveVoiceClientMessage, onFailure: (@MainActor () -> Void)?) {
        send(message, onSent: nil, onFailure: onFailure)
    }
}

extension GeminiLiveSession: GeminiLiveSessionControlling {}
