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
    /// The call's grant ran out, for a relay call that failed: one that may
    /// have gone out counts only when the relay or Hermes turned it away.
    static func grantRanOut(reason: String, grantGone: Bool, sent: Bool) -> Bool {
        sent ? refused(reason) : grantGone || reason == "grantExpiring"
    }

    /// VoiceThreadRouting.removingQuickMarker for the marked form the models
    /// write ("Quick: …", "quickly, …"): routing, not part of the task.
    static func removingQuickMarker(_ request: String) -> String {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let marker = trimmed.range(of: #"^(quickly|quick)\s*[:,，：]\s*|^(快速|快)\s*[:,，：]\s*"#,
                                         options: [.regularExpression, .caseInsensitive]) else { return trimmed }
        let rest = trimmed[marker.upperBound...]
        return rest.isEmpty ? trimmed : String(rest)
    }

    /// GPTLiveDelegationBridge.statusContext for the Watch's relay jobs:
    /// each running job by its number, as the phone tells GPT-Live.
    static func statusContext(_ jobs: [(number: Int, title: String, status: String)]) -> String {
        guard !jobs.isEmpty else { return "[Background jobs: none running.]" }
        let lines = jobs.map { "Job \($0.number) (\($0.title)): \(statusName($0.status))" }
        return "[Background jobs on Hermes: " + lines.joined(separator: "; ") + ".]"
    }

    /// The host's job status, in GeminiLiveToolBridge.statusName's words.
    static func statusName(_ status: String) -> String {
        status == "needs_approval" ? "needs_approval_on_the_watch" : status
    }

    /// `grantRanOut` without its closing period, to sit inside a sentence.
    static var grantRanOutClause: String {
        grantRanOut.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

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

    /// GPTLiveDelegationBridge's quiet note once Hermes took the job; with
    /// the job's number in this call when it can take corrections.
    static func working(title: String, number: Int? = nil) -> String {
        guard let number else {
            return "Hermes is working on this as a background job (\"\(title)\"). Its result will follow on this delegation; don't guess it."
        }
        return "Hermes is working on this as background job \(number) (\"\(title)\"). Its result will follow on this delegation; don't guess it. If the user corrects or changes it while it runs, delegate their words starting with \"Job \(number):\"."
    }

    // MARK: Follow-ups (#455)

    /// GPTLiveDelegationBridge.jobMarker: "Job 2: make it Alex" → (2,
    /// "make it Alex"), only at the very start, never a time or a decimal.
    static func jobMarker(in request: String) -> (number: Int, rest: String)? {
        guard let range = request.range(of: #"^\s*job\s*#?\s*[0-9]{1,4}\s*[:,.\-–—](?![0-9])"#, options: [.regularExpression, .caseInsensitive]),
              let number = Int(String(request[range].filter { $0.isASCII && $0.isNumber })) else { return nil }
        let rest = request[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (number, rest)
    }

    /// GPTLiveDelegationBridge.followUpWords: the user's own words since
    /// the last delegation, else the delegation's.
    static func followUpWords(userWords: String, delegated: String) -> String {
        let spoken = userWords.trimmingCharacters(in: .whitespacesAndNewlines)
        guard spoken.isEmpty else { return spoken }
        let own = delegated.components(separatedBy: contextMarker).first ?? delegated
        return own.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// GPTLiveDelegationBridge.followUpReply: taken, quiet, since the model
    /// already acknowledged it; not taken, said aloud.
    static func followUpReply(_ outcome: WatchJobAnswer.FollowUp) -> (text: String, speakable: Bool) {
        switch outcome {
        case .interrupted(let title):
            return ("Conduit put the user's words into \(WatchJobAnswer.quoted(title)) at once; Hermes keeps its work so far and changes course now. Its result still follows on the earlier delegation; don't guess it.", false)
        case .queued(let title):
            return ("Conduit passed the user's words to \(WatchJobAnswer.quoted(title)); Hermes takes them right after the step it is finishing. Its result still follows on the earlier delegation; don't guess it.", false)
        case .finished(let title):
            return (relay("\(WatchJobAnswer.quoted(title)) had already finished, so Hermes didn't get this. Ask the user what they want instead."), true)
        case .failed(let message):
            return (relay("Hermes didn't get that (\(message))."), true)
        case .unknownJob:
            return (relay("Hermes didn't get that (that job isn't one this call started)."), true)
        }
    }

    /// The host's plugin predates follow-ups from the Watch.
    static let followUpsUnavailable = relay("Hermes didn't get that (\(WatchJobAnswer.followUpsNeedNewerPlugin)).")

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
