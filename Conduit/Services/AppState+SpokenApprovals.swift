//
//  AppState+SpokenApprovals.swift
//  Conduit
//
//  Classic voice's yes or no to what waits on the user's OK, answered here
//  as a tap would answer it (SpokenApprovals).
//

import Foundation

extension AppState {
    /// What waits on the user now: the phone's change cards, Hermes'
    /// confirmations on screen, and approvals in the open chat.
    func spokenApprovalsWaiting() -> SpokenApprovals.Waiting {
        var waiting = SpokenApprovals.Waiting()
        waiting.phoneChanges = phoneSync.prompts.map(\.id)
        waiting.cancellingAlarms = Set(phoneSync.prompts.filter { $0.change.kind == .cancelAlarm }.map(\.id))
        waiting.staleChanges = phoneChangesWaitingAtLastWords ?? Set(waiting.phoneChanges)
        waiting.presented = presentedScreens.prompts.filter { !$0.isExpired() }
        if let sessionId = activeSessionId, !sessionId.isEmpty {
            let open = chatOwnSessionIDs(for: sessionId)
            waiting.chatApprovals = messages.compactMap { message -> String? in
                guard let approval = message.approval, approval.status == .pending || approval.status == .error,
                      open.contains(approval.sessionId) else { return nil }
                return message.id
            }
        }
        // A job's approval whose card is already counted in the open chat
        // isn't counted twice.
        let shownRequests = Set(messages.compactMap { $0.approval?.requestId })
        waiting.jobApprovals = voiceBackgroundJobSupervisor.jobs.compactMap { job -> UUID? in
            guard job.status == .needsInput, let approval = job.waitingApproval else { return nil }
            if let request = approval.requestId, shownRequests.contains(request), !waiting.chatApprovals.isEmpty { return nil }
            return job.id
        }
        return waiting
    }

    /// Answers the one thing waiting when Classic voice's `words` are a plain
    /// yes or no to it, and reports whether they did. Its card goes, and
    /// Hermes hears how it went before the words reach it.
    @discardableResult
    func answerWaitingBySpeech(_ words: String) async -> Bool {
        let waiting = spokenApprovalsWaiting()
        noteUserWordsSent()
        guard let answer = SpokenApprovals.answer(words, waiting: waiting) else { return false }
        let approve = answer.approve
        switch answer.target {
        case .phoneChange(let id):
            guard let prompt = phoneSync.prompts.first(where: { $0.id == id }) else { return false }
            // Applied now; reported in the background, so the words reach
            // Hermes without waiting on the sync.
            await phoneSync.answer(prompt, approve: approve)
            Task { await self.runPhoneSync(reason: .answered) }
        case .presented(let id):
            guard let prompt = presentedScreens.prompts.first(where: { $0.id == id && !$0.isExpired() }) else { return false }
            presentedScreens.answer(prompt, outcome: approve ? .confirmed : .declined, via: .voice)
            // Reported (and Maps opened) in the background, as with the phone's changes.
            Task { await self.reportPresentedAnswer(prompt, outcome: approve ? .confirmed : .declined) }
        case .chatApproval(let messageID):
            await respondToApproval(messageId: messageID, choice: approve ? "once" : "deny")
            // Not taken (the card moved on or the send failed): the words go
            // on as speech.
            let status = messages.first { $0.id == messageID }?.approval?.status
            guard status == .approved || status == .rejected else { return false }
        case .jobApproval(let id):
            // Gone by the time it was answered: the words go on as speech.
            switch await voiceBackgroundJobSupervisor.answerJobApproval(id, choice: approve ? "once" : "deny") {
            case .approved, .denied: break
            default: return false
            }
        }
        return true
    }

    /// The user sent words (typed or spoken): a phone change waiting now
    /// wasn't asked for in the reply their next words answer.
    func noteUserWordsSent() {
        phoneChangesWaitingAtLastWords = Set(phoneSync.prompts.map(\.id))
    }

    /// A job's approval answered out loud in a call: through the open
    /// chat's card when it shows there (the card then shows the answer),
    /// else straight to Hermes. False when Hermes no longer waits on it.
    func respondToApprovalByVoice(_ approval: ApprovalActivity, choice: String, profile: String?) async throws -> Bool {
        if let message = messages.first(where: { message in
            guard let shown = message.approval, shown.status == .pending || shown.status == .error else { return false }
            return approval.requestId.map { shown.requestId == $0 } ?? shown.asksSameAs(approval)
        }) {
            await respondToApproval(messageId: message.id, choice: choice)
            let status = messages.first { $0.id == message.id }?.approval?.status
            // The card's own error: the answer didn't reach Hermes, which
            // may still wait, so it isn't too late.
            if status == .error { throw HermesError.notConnected }
            return status == .approved || status == .rejected
        }
        guard let client else { throw HermesError.notConnected }
        return try await client.respondToApproval(sessionId: approval.sessionId, requestId: approval.requestId,
                                                  choice: choice, profile: profile)
    }
}
