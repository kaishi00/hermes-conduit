//
//  LocalLiveNoticeRoute.swift
//  Conduit
//
//  A Local Live call has two shapes, and what a finished background job's
//  news is worth differs between them.
//

import Foundation

/// What a Local Live call does with a pending background-job notice.
///
/// An agent call (Live > Local) has the host's fast model on the front: a
/// job's result is news it hasn't heard, and the call says it as one of its
/// own turns, as Gemini, GPT and Grok Live do. A call that hands each
/// utterance to Hermes (`hermes_turns`) drops it instead: Hermes' reply is
/// already the call's own turn, so a notice would be said a second time.
enum LocalLiveNoticeHandling: Equatable {
    case deliverAsUpdate
    case drop

    /// What this call does with a notice now.
    ///
    /// - Parameters:
    ///   - runsAgentTurns: the live connection's own mode
    ///     (`GeminiLiveConversationController.sessionRunsAgentTurns`). False
    ///     both for a Hermes-turns call and before a session exists.
    ///   - sessionIsReady: whether that connection can take a send yet
    ///     (`sessionIsReady`, the session's own snapshot, never the setting).
    ///   - configuredAgent: what Settings picks for the next connection
    ///     (`AppState.isLocalLiveAgent`).
    ///
    /// Once the connection is ready, it is the only thing that decides: a
    /// call that switched modes mid-conversation keeps the mode it connected
    /// with until it reconnects, and its notice must not go into the other
    /// shape. Before that — nothing connected, permission pending, the
    /// handshake — agent mode is what the connection that arrives will be, so
    /// the notice is queued rather than spent: the controller holds it until
    /// the session is ready and redelivers it there. Holding everything not
    /// yet ready would be wrong the other way: a ready Classic call sends a
    /// text turn, and Classic would turn the notice into a second Hermes
    /// turn.
    static func forCall(
        runsAgentTurns: Bool,
        sessionIsReady: Bool,
        configuredAgent: Bool
    ) -> LocalLiveNoticeHandling {
        guard sessionIsReady else { return configuredAgent ? .deliverAsUpdate : .drop }
        return runsAgentTurns ? .deliverAsUpdate : .drop
    }
}
