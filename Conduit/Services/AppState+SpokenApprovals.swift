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
        guard let answer = SpokenApprovals.answer(words, waiting: waiting) else {
            // Nothing waits on a yes or no: the words may answer a question.
            return waiting.count == 0 ? await answerQuestionBySpeech(words) : false
        }
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

    /// Classic voice's words answer the one question Hermes waits on, in
    /// the open chat or a voice job: Hermes is paused on it, so the words
    /// could only wait behind it otherwise. A choice they point at ("two",
    /// "the recommended one") sends what its tap sends; other words go as
    /// the answer, for Hermes to read. False when no question, or more
    /// than one, waits.
    func answerQuestionBySpeech(_ words: String) async -> Bool {
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let cards = openChatWaitingQuestions
        let shown = Set(cards.compactMap { $0.clarify?.requestId })
        let jobs = voiceBackgroundJobSupervisor.jobsWaitingOnQuestion.filter { id in
            guard let request = voiceBackgroundJobSupervisor.jobs.first(where: { $0.id == id })?.waitingQuestion?.requestId else { return false }
            return !shown.contains(request)
        }
        // Which one the words answer would be a guess.
        guard cards.count + jobs.count == 1 else { return false }
        if let message = cards.first, let clarify = message.clarify,
           let question = HermesCallWaiting(clarify: clarify)?.openQuestion {
            let value = HermesCallWaiting.answerValue(for: trimmed, question: question)
            await respondToClarify(requestId: clarify.requestId, questionId: clarify.questions.count == 1 ? nil : question.id, answer: value)
            let status = messages.first { $0.id == message.id }?.clarify?.questions.first { $0.id == question.id }?.status
            // Not taken: the words go on as speech.
            guard status == .answered || status == .submitting else { return false }
            if let after = messages.first(where: { $0.id == message.id })?.clarify,
               let next = HermesCallWaiting(clarify: after)?.openQuestion {
                voiceConversationController.noteApprovalWaiting(
                    sessionID: activeSessionId ?? "",
                    request: clarify.requestId + "/" + next.id,
                    line: HermesCallWaiting.spokenQuestion(next),
                    stillWaiting: { [weak self] in self?.openChatWaitingQuestions.contains { $0.id == message.id } == true }
                )
            }
            return true
        }
        guard let jobID = jobs.first else { return false }
        switch await voiceBackgroundJobSupervisor.answerJobQuestion(jobID, answer: trimmed) {
        case .answered: return true
        default: return false
        }
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
        // A call's request like any other: a socket off screen is checked
        // first, and a drop is waited out (#1060, #1362).
        let client = try await clientForVoiceRequest()
        return try await client.respondToApproval(sessionId: approval.sessionId, requestId: approval.requestId,
                                                  choice: choice, profile: profile)
    }

    /// Answers one question of the clarify a voice call's job waits on:
    /// through its card when the chat is on screen, else straight to
    /// Hermes; nil `answer` leaves a form's question blank. The card as it
    /// stands after; nil once Hermes stopped waiting.
    func respondToClarifyByVoice(
        _ clarify: ClarifyActivity,
        questionID: String?,
        answer: String?,
        sessionID: String? = nil,
        profile: String? = nil
    ) async throws -> ClarifyActivity? {
        if messages.contains(where: { $0.clarify?.requestId == clarify.requestId }) {
            await respondToClarify(requestId: clarify.requestId, questionId: questionID, answer: answer)
            guard let after = messages.first(where: { $0.clarify?.requestId == clarify.requestId })?.clarify,
                  !after.isExpired else { return nil }
            // The card's own error: the answer didn't reach Hermes, which
            // may still wait.
            let target = questionID.flatMap { id in after.questions.first { $0.id == id } } ?? after.questions.first
            if target?.status == .error { throw HermesError.notConnected }
            return after
        }
        let client = try await clientForVoiceRequest()
        guard let index = questionID.flatMap({ id in clarify.questions.firstIndex { $0.id == id } })
                ?? clarify.questions.firstIndex(where: { $0.status == .pending || $0.status == .error }) else { return nil }
        let question = clarify.questions[index]
        // As the card sends it: a multi-select answer is always a list, and
        // a blank is empty, which Hermes reads as skipped.
        let answer = answer ?? ""
        let wire = question.multiSelect && !answer.isEmpty && (try? JSONSerialization.jsonObject(with: Data(answer.utf8))) as? [String] == nil
            ? ClarifyQuestion.multiSelectAnswer([answer])
            : answer
        let outcome = try await client.respondToClarification(
            requestId: clarify.requestId,
            answer: wire,
            questionId: question.isSyntheticID ? nil : question.id,
            // On the session authority, a question this socket never saw
            // asked (one from before a relaunch) is read from its chat.
            sessionId: sessionID,
            profile: profile
        )
        guard case .accepted(let remaining) = outcome else { return nil }
        var after = clarify
        after.questions[index].status = .answered
        after.questions[index].answer = wire
        if let remaining {
            let open = Set(remaining)
            for other in after.questions.indices where other != index && after.questions[other].status == .pending && !open.contains(after.questions[other].id) {
                after.questions[other].status = .answered
            }
        }
        return after
    }
}

extension AppState {
    /// Hermes' turn in a Classic voice conversation stopped on an approval:
    /// its card is in the chat behind the voice screen, so the conversation
    /// says what it asks and listens for the yes or no, instead of sitting
    /// on Thinking with nothing to say.
    func noteApprovalForClassicVoice(_ activity: ApprovalActivity, sessionID: String) {
        guard activity.status == .pending else { return }
        // Without a request id, the card it updated or added: a resend
        // updates the same card, the next approval adds another.
        guard let request = activity.requestId ?? messages.last(where: { message in
            guard let shown = message.approval, shown.requestId == nil else { return false }
            return shown.sessionId == activity.sessionId && shown.asksSameAs(activity)
        })?.id else { return }
        voiceConversationController.noteApprovalWaiting(
            sessionID: sessionID,
            request: request,
            line: LocalLiveTurnRunner.approvalLine(activity),
            stillWaiting: { [weak self] in
                guard let self else { return false }
                return self.messages.contains { message in
                    guard let shown = message.approval, shown.status == .pending || shown.status == .error else { return false }
                    // A request id is unique; without one, only this chat's card counts.
                    return activity.requestId.map { shown.requestId == $0 }
                        ?? (shown.sessionId == activity.sessionId && shown.asksSameAs(activity))
                }
            }
        )
    }
}

extension AppState {
    /// Hermes' turn in a Classic voice conversation stopped on a question:
    /// the conversation reads it out with its choices and listens for the
    /// answer, instead of sitting on Thinking with nothing to say.
    func noteClarifyForClassicVoice(_ activity: ClarifyActivity, sessionID: String) {
        guard let question = HermesCallWaiting(clarify: activity)?.openQuestion else { return }
        voiceConversationController.noteApprovalWaiting(
            sessionID: sessionID,
            request: activity.requestId + "/" + question.id,
            line: HermesCallWaiting.spokenQuestion(question),
            stillWaiting: { [weak self] in
                self?.openChatWaitingQuestions.contains { $0.clarify?.requestId == activity.requestId } == true
            }
        )
    }

    /// The open chat's question cards with a question still open.
    var openChatWaitingQuestions: [ChatMessage] {
        guard let sessionId = activeSessionId, !sessionId.isEmpty else { return [] }
        return messages.filter { message in
            guard let clarify = message.clarify else { return false }
            return HermesCallWaiting(clarify: clarify) != nil
        }
    }

    /// The open chat's approval, question and input cards still waiting on
    /// the user (or on their answer reaching Hermes), for the Classic voice
    /// screen and the call screen that cover the chat. An input card (a
    /// password, login or code) is only shown there, never asked for by
    /// voice: what the user types must not be spoken or heard.
    var openChatWaitingCards: [ChatMessage] {
        guard turnState.isRunning else { return [] }
        let approvals = openChatWaitingApprovals
        let questions = openChatWaitingQuestions
        let inputs = openChatWaitingInputs
        // In the chat's order: Hermes asks one at a time.
        return messages.filter { message in
            approvals.contains { $0.id == message.id } || questions.contains { $0.id == message.id }
                || inputs.contains { $0.id == message.id }
        }
    }

    /// The open chat's input cards still waiting on the user (or on their
    /// answer reaching Hermes).
    var openChatWaitingInputs: [ChatMessage] {
        guard turnState.isRunning, let sessionId = activeSessionId, !sessionId.isEmpty else { return [] }
        let open = chatOwnSessionIDs(for: sessionId)
        return messages.filter { message in
            guard let prompt = message.inputPrompt else { return false }
            return (prompt.isAnswerable || prompt.status == .submitting) && open.contains(prompt.sessionId)
        }
    }

    /// The open chat's approval cards still waiting on the user (or on
    /// their answer reaching Hermes), for the Classic voice screen that
    /// covers the chat.
    var openChatWaitingApprovals: [ChatMessage] {
        // A card left over from a turn that ended waits on nobody.
        guard turnState.isRunning, let sessionId = activeSessionId, !sessionId.isEmpty else { return [] }
        let open = chatOwnSessionIDs(for: sessionId)
        return messages.filter { message in
            guard let approval = message.approval else { return false }
            switch approval.status {
            case .pending, .submitting, .error: return open.contains(approval.sessionId)
            case .approved, .rejected, .expired: return false
            }
        }
    }
}
