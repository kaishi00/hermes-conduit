//
//  WatchBridgeDelegation.swift
//  Conduit and the Conduit Watch app
//
//  GPT-Live's delegations in a Watch call (designs/apple-watch-gpt-live.md).
//  GPT-Live has no tools of its own on the subscription: it hands real
//  work to the app, and on the phone each delegation runs as a Hermes
//  background job (GPTLiveDelegationBridge). The Watch does the same
//  through the call's grant: start_job sealed through the push relay, the
//  job's news asked for the same way, and its outcome sent back on the
//  delegation. The texts mirror the phone's, checked by parity tests.
//  Written for the model, not shown, so not localized.
//

import Foundation

enum WatchBridgeDelegation {
    /// GPTLiveConversationController.delegationContextMarker.
    static let contextMarker = "\n\n[Recent voice conversation, for context only. Do just the request above: earlier requests marked \"handled separately\" were passed on before (to a job, the chat, or an answer, or turned down), so skip them unless the request above asks for them.]\n"
    /// The host takes up to 3,000 bytes of instructions for a Watch job
    /// (WATCH_JOB_MAX_INSTRUCTION_BYTES); JSON escaping needs some room.
    static let maxRequestBytes = 2_600
    /// The lines of conversation a request carries for context, at most.
    static let contextLines = 8

    /// The relay or Hermes turned away a call that went out because its
    /// grant is over, so it didn't run: `WatchToolRelayClient`'s reasons
    /// for those answers, pinned by a test against the client.
    static func refused(_ reason: String) -> Bool {
        ["relay 401", "relay 404", "relay 410", "host 403", "host 410"].contains(reason)
            || reason.hasSuffix(" grant_exhausted")
    }

    struct Line: Equatable {
        var role: WatchVoiceWire.DirectTurn.Role
        var text: String
        /// Already passed on with an earlier delegation.
        var handled: Bool
    }

    /// The work a delegation asks for: its own text when it carries any,
    /// otherwise the user's words since the last delegation, with the
    /// recent conversation for context, as the phone builds it
    /// (GPTLiveConversationController.delegationRequest), within the host's
    /// limit. Empty when there's nothing to ask for.
    static func request(itemText: String, lines: [Line]) -> String {
        let own = itemText.trimmingCharacters(in: .whitespacesAndNewlines)
        let userWords = lines.filter { $0.role == .user && !$0.handled }.map(\.text).joined(separator: " ")
        let request = clipped(own.isEmpty ? userWords : own, bytes: maxRequestBytes)
        guard !request.isEmpty else { return "" }
        var budget = maxRequestBytes - request.utf8.count - contextMarker.utf8.count
        var context = ""
        for line in lines.suffix(contextLines).reversed() {
            let speaker = line.role == .user ? (line.handled ? "User (handled separately): " : "User: ") : "Assistant: "
            let text = speaker + line.text + "\n"
            guard text.utf8.count <= budget else { break }
            budget -= text.utf8.count
            context = text + context
        }
        guard !context.isEmpty else { return request }
        return request + contextMarker + context
    }

    /// `text` cut to `bytes` UTF-8 bytes, never inside a character.
    static func clipped(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var result = ""
        var size = 0
        for character in text {
            let width = String(character).utf8.count
            guard size + width <= bytes else { break }
            result.append(character)
            size += width
        }
        return result
    }

    /// GPTLiveDelegationBridge's quiet note once Hermes took the job.
    static func working(title: String) -> String {
        "Hermes is working on this as a background job (\"\(title)\"). Its result will follow on this delegation; don't guess it."
    }

    /// GeminiLiveToolBridge.relayPrompt, as GPTLiveDelegationBridge.relay.
    static func relay(_ notice: String) -> String {
        WatchJobAnswer.updatePrompt(notice)
    }

    static let noRequest = relay("Hermes didn't get a request to work on. Ask the user what they want done.")

    /// The call's grant is spent or about to end: a Watch call's access
    /// to Hermes lasts up to half an hour.
    static let grantRanOut = "this call's access to Hermes has run out. The user can end the call and start a new one."
    /// Too little of the grant is left to follow a new job to its result.
    static let grantNearlyOut = "this call has used nearly all its access to Hermes, so it can't follow a new job to its result. The user can end the call and start a new one."

    /// When a delegation can't become a job from the Watch.
    static func notStarted(_ reason: String) -> String {
        relay("The job didn't start: \(reason)")
    }
}
