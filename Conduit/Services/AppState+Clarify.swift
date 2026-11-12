//
//  AppState+Clarify.swift
//  Conduit
//
//  What the agent asks the user mid-turn: clarify questions and forms,
//  approvals, input prompts and connection asks, with their expiry and
//  the push cards they replace. Moved out of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Clarify, approvals, input prompts and connections

    /// Answers one question of a clarification request. Batch questions route
    /// per question (`question_id` + the gateway's authoritative `remaining`
    /// list); a `nil` questionId targets the card's single question — the
    /// shape every push-relay card and legacy gateway produces. A nil
    /// `answer` leaves one of a form's questions blank (`isForm`), which
    /// Hermes reads as skipped.
    func respondToClarify(requestId: String, questionId: String? = nil, answer: String?) async {
        let trimmedAnswer = answer?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAnswer?.isEmpty != true,
              let index = messages.firstIndex(where: { $0.clarify?.requestId == requestId }),
              var activity = messages[index].clarify,
              !activity.isExpired,
              trimmedAnswer != nil || activity.isForm else { return }

        let questionIndex: Int?
        if let questionId {
            questionIndex = activity.questions.firstIndex { $0.id == questionId }
        } else {
            // Request-level answer: only valid while exactly one question is
            // open; a batch must always answer through its qids.
            questionIndex = activity.questions.count == 1 ? 0 : activity.questions.firstIndex { $0.status == .pending || $0.status == .error }
        }
        guard let questionIndex,
              activity.questions[questionIndex].status == .pending
                  || activity.questions[questionIndex].status == .error else { return }

        activity.questions[questionIndex].status = .submitting
        activity.questions[questionIndex].error = nil
        messages[index].clarify = activity
        setRunning(true)
        cacheMessagePresentation()
        await sendClarifyAnswer(trimmedAnswer ?? "", for: activity.questions[questionIndex], requestId: requestId)
    }

    /// Sends a form's fields together (`ClarifyActivity.isForm`): every
    /// question still open, with its answer in `answers` by qid, or left
    /// blank when it has none there, which Hermes reads as skipped.
    func respondToClarifyForm(requestId: String, answers: [String: String]) async {
        guard let index = messages.firstIndex(where: { $0.clarify?.requestId == requestId }),
              var activity = messages[index].clarify,
              !activity.isExpired, activity.isForm else { return }
        var sending: [(question: ClarifyQuestion, answer: String)] = []
        for questionIndex in activity.questions.indices where activity.questions[questionIndex].isAnswerable {
            activity.questions[questionIndex].status = .submitting
            activity.questions[questionIndex].error = nil
            let answer = answers[activity.questions[questionIndex].id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            sending.append((activity.questions[questionIndex], answer))
        }
        guard !sending.isEmpty else { return }
        messages[index].clarify = activity
        setRunning(true)
        cacheMessagePresentation()
        // One at a time, in order: the last lock resolves the request.
        var stillOpen: Set<String>?
        for (question, answer) in sending {
            // Expired meanwhile: every open question went with it. A card
            // that left the screen (another chat opened) still sends.
            if messages.first(where: { $0.clarify?.requestId == requestId })?.clarify?.isExpired == true { return }
            // No longer on Hermes' list of open questions: another device
            // answered it while the form was sending.
            if let stillOpen, !stillOpen.contains(question.id) {
                settleClarifyQuestionAnsweredElsewhere(requestId: requestId, questionId: question.id)
                continue
            }
            if let remaining = await sendClarifyAnswer(answer, for: question, requestId: requestId) {
                stillOpen = Set(remaining)
            }
        }
    }

    /// Settles one question another device answered, without showing this
    /// device's answer as what Hermes received.
    private func settleClarifyQuestionAnsweredElsewhere(requestId: String, questionId: String) {
        guard let index = messages.firstIndex(where: { $0.clarify?.requestId == requestId }),
              var activity = messages[index].clarify,
              let questionIndex = activity.questions.firstIndex(where: { $0.id == questionId }) else {
            return
        }
        activity.questions[questionIndex].status = .answered
        activity.questions[questionIndex].answer = nil
        activity.questions[questionIndex].error = nil
        messages[index].clarify = activity
        cacheMessagePresentation()
    }

    /// Sends one question's answer, already marked submitting; an empty
    /// `answer` leaves it blank. Returns the questions Hermes still waits on
    /// after it, when its reply lists them.
    @discardableResult
    private func sendClarifyAnswer(_ answer: String, for question: ClarifyQuestion, requestId: String) async -> [String]? {
        // Plugin-minted clarify ids are answered through the relay's decision
        // loop (the gateway's own clarify id never reached this device); the
        // gateway-side middleware polls the relay and resolves the tool call.
        // Routed BEFORE the gateway-client guard: the relay answer needs only
        // the relay registration, and answering from a freshly-resumed push
        // is exactly when the gateway client may still be reconnecting.
        // Batch relay decisions answer per question; the legacy scalar relay
        // card keeps the whole-decision response shape.
        if requestId.hasPrefix(PendingDecisionPayload.relayRequestPrefix) {
            if question.isSyntheticID {
                await respondToRelayClarify(requestId: requestId, answer: answer)
                return nil
            }
            return await respondToRelayClarifyQuestion(
                requestId: requestId,
                questionId: question.id,
                answer: answer
            )
        }
        guard let client else {
            markClarifyQuestionError(
                requestId: requestId,
                questionId: question.id,
                message: AppLocalization.string("Gateway connection is unavailable.")
            )
            return nil
        }
        // Ownership snapshot for the gateway-owned respond below — same fence
        // as `respondToApproval`: a completion (success or failure) from a
        // replaced client must not touch whatever decision state is current,
        // even under colliding ids. The relay branch above is deliberately
        // NOT fenced: it is owned by the relay registration, not by this
        // HermesClient (push server identity is a separate prerequisite).
        let profile = activeProfile
        // The wire answer for a multi-select question must be the array form
        // Hermes' batch parser accepts; typed custom text arrives as a bare
        // string and is wrapped here so every multi-select path is uniform.
        // A blank stays empty: Hermes reads it as skipped.
        let wireAnswer: String
        if question.multiSelect, !answer.isEmpty,
           (try? JSONSerialization.jsonObject(with: Data(answer.utf8))) as? [String] == nil {
            wireAnswer = ClarifyQuestion.multiSelectAnswer([answer])
        } else {
            wireAnswer = answer
        }
        do {
            let outcome = try await client.respondToClarification(
                requestId: requestId,
                answer: wireAnswer,
                // Only gateway-minted qids may address a question. A locally
                // synthesized id (legacy scalar card) rides the request-level
                // respond shape every gateway generation accepts.
                questionId: question.isSyntheticID ? nil : question.id,
                // The card is in the open chat: on the session authority its
                // resume names a prompt this socket didn't see asked (#1618),
                // under the chat's own profile (a bot chat's).
                sessionId: activeSessionId,
                profile: presentationProfile(for: activeSessionId)
            )
            guard profile == activeProfile, self.client === client else { return nil }
            applyClarifyResponseOutcome(
                outcome,
                requestId: requestId,
                questionId: question.id,
                answer: wireAnswer
            )
            guard case .accepted(let remaining) = outcome else { return nil }
            return remaining
        } catch {
            guard profile == activeProfile, self.client === client else { return nil }
            if Self.isExpiredPromptError(error) {
                // Older gateways report expiry as RPC 4009 instead of the
                // typed `expired` status — same teardown either way.
                expireClarifyRequest(requestId: requestId)
            } else if HermesClient.isSessionNotFoundError(error) {
                // The chat's runtime is gone (reaped, or re-opened elsewhere),
                // as the approval card reads it: nothing waits on this answer.
                applyClarifyResponseOutcome(.ended, requestId: requestId, questionId: question.id, answer: wireAnswer)
            } else if let unsent = error as? HermesClient.AnswerNotSent {
                // Never sent: why Hermes couldn't be reached, and the
                // question can be answered again.
                markClarifyQuestionError(
                    requestId: requestId,
                    questionId: question.id,
                    message: UserFacingError.message(for: unsent.underlying)
                )
            } else {
                markClarifyQuestionError(
                    requestId: requestId,
                    questionId: question.id,
                    message: AppLocalization.string("Hermes did not accept that answer."),
                    globalMessage: UserFacingError.message(for: error)
                )
            }
            return nil
        }
    }

    /// Restores exactly one question to an answerable/error state after a
    /// failed respond; answered and in-flight-free sibling questions keep
    /// their state.
    private func markClarifyQuestionError(
        requestId: String,
        questionId: String,
        message: String,
        globalMessage: String? = nil
    ) {
        guard let index = messages.firstIndex(where: { $0.clarify?.requestId == requestId }),
              var activity = messages[index].clarify,
              let questionIndex = activity.questions.firstIndex(where: { $0.id == questionId }) else {
            return
        }
        activity.questions[questionIndex].status = .error
        activity.questions[questionIndex].answer = nil
        activity.questions[questionIndex].error = message
        messages[index].clarify = activity
        if let globalMessage {
            errorMessage = globalMessage
        }
        cacheMessagePresentation()
    }

    /// Answers ONE question of a batch relay decision. First-answer-wins per
    /// question: only the targeted qid locks; sibling questions stay open
    /// until their own answers land. Returns the questions the relay still
    /// waits on, when it lists them.
    private func respondToRelayClarifyQuestion(
        requestId: String,
        questionId: String,
        answer: String
    ) async -> [String]? {
        do {
            let outcome = try await relayQuestionResponder(requestId, questionId, answer)
            guard let index = messages.firstIndex(where: { $0.clarify?.requestId == requestId }),
                  var activity = messages[index].clarify,
                  let questionIndex = activity.questions.firstIndex(where: { $0.id == questionId }) else {
                return nil
            }
            var stillOpen: [String]?
            switch outcome {
            case .locked(let remaining):
                stillOpen = remaining
                activity.questions[questionIndex].status = .answered
                // What the user gave: a blank shows Skipped even where an
                // older relay got "(left blank)" for it (`blankAnswer`).
                activity.questions[questionIndex].answer = answer
                activity.questions[questionIndex].error = nil
                // An explicit remaining list is authoritative about what is
                // still open, exactly like the native gateway's contract.
                if let remaining {
                    let open = Set(remaining)
                    for sibling in activity.questions.indices
                    where sibling != questionIndex
                        && activity.questions[sibling].status == .pending
                        && !open.contains(activity.questions[sibling].id) {
                        activity.questions[sibling].status = .answered
                        activity.questions[sibling].answer = nil
                    }
                }
            case .questionAlreadyLocked:
                // Another device locked this qid first; settle it without
                // displaying this device's rejected text. Sibling questions
                // keep their state — a locked qid never retires the batch.
                activity.questions[questionIndex].status = .answered
                activity.questions[questionIndex].answer = nil
            case .decisionReleased, .noLongerActive:
                // Released (the native gateway path resolved the whole
                // clarify) and timed-out/gone decisions are different relay
                // reasons for the same card outcome: unanswered questions go
                // inactive, answered history stays locked, and no sibling
                // remains answerable.
                activity.isExpired = true
                for questionIndex in activity.questions.indices
                where activity.questions[questionIndex].status != .answered {
                    activity.questions[questionIndex].status = .expired
                    activity.questions[questionIndex].error = nil
                }
                activity.error = Self.clarifyExpiredNotice(for: activity.questions.count)
            }
            messages[index].clarify = activity
            cacheMessagePresentation()
            return stillOpen
        } catch {
            guard let index = messages.firstIndex(where: { $0.clarify?.requestId == requestId }),
                  var activity = messages[index].clarify,
                  let questionIndex = activity.questions.firstIndex(where: { $0.id == questionId }) else {
                return nil
            }
            activity.questions[questionIndex].status = .error
            activity.questions[questionIndex].answer = nil
            activity.questions[questionIndex].error = UserFacingError.message(for: error)
            messages[index].clarify = activity
            cacheMessagePresentation()
            return nil
        }
    }

    private func respondToRelayClarify(requestId: String, answer: String) async {
        do {
            let outcome = try await PushNotificationService.shared.respondToRelayDecision(
                requestId: requestId,
                answer: answer
            )
            guard let updatedIndex = messages.firstIndex(where: { $0.clarify?.requestId == requestId }),
                  var activity = messages[updatedIndex].clarify,
                  !activity.questions.isEmpty else { return }
            // Relay cards are single-question by construction: the notifier
            // mints one request per pushed decision.
            switch outcome {
            case .answered:
                activity.questions[0].status = .answered
                activity.questions[0].answer = answer
            case .alreadyAnsweredElsewhere:
                // Another device resolved the decision with its own answer;
                // settle the card but do not display this device's rejected
                // text as if it were what Hermes received.
                activity.questions[0].status = .answered
                activity.questions[0].answer = nil
            case .noLongerActive:
                activity.questions[0].status = .error
                activity.questions[0].answer = nil
                activity.questions[0].error = AppLocalization.string("This question is no longer active — it was timed out or already resolved.")
            }
            messages[updatedIndex].clarify = activity
            cacheMessagePresentation()
        } catch {
            guard let updatedIndex = messages.firstIndex(where: { $0.clarify?.requestId == requestId }),
                  var activity = messages[updatedIndex].clarify,
                  !activity.questions.isEmpty else { return }
            activity.questions[0].status = .error
            activity.questions[0].answer = nil
            activity.questions[0].error = UserFacingError.message(for: error)
            messages[updatedIndex].clarify = activity
            cacheMessagePresentation()
        }
    }

    enum ApprovalSubmissionIdentity: Hashable {
        case identified(String)
        case legacy(String)
    }

    func hasLiveApprovalSubmission(
        for activity: ApprovalActivity,
        equivalentSessionIDs: Set<String>? = nil
    ) -> Bool {
        if let requestId = activity.requestId {
            return liveApprovalSubmissions.contains(.identified(requestId))
        }
        if liveApprovalSubmissions.contains(.legacy(activity.sessionId)) {
            return true
        }
        if let equivalentSessionIDs {
            return liveApprovalSubmissions.contains(where: {
                if case .legacy(let sid) = $0 {
                    return equivalentSessionIDs.contains(sid)
                }
                return false
            })
        }
        return false
    }

    private static func sameLegacyApprovalRequest(
        _ lhs: ApprovalActivity,
        _ rhs: ApprovalActivity
    ) -> Bool {
        lhs.requestId == nil
            && rhs.requestId == nil
            && lhs.command == rhs.command
            && lhs.description == rhs.description
            && lhs.choices == rhs.choices
            && lhs.allowPermanent == rhs.allowPermanent
            && lhs.smartDenied == rhs.smartDenied
    }

    private func shouldPreserveLocalApprovalState(
        existing: ApprovalActivity,
        incoming: ApprovalActivity,
        authoritative: Bool,
        hasLiveSubmission: Bool
    ) -> Bool {
        switch existing.status {
        case .submitting:
            return hasLiveSubmission || !authoritative
        case .approved, .rejected, .expired:
            return true
        case .error:
            if existing.requestId == nil, incoming.requestId == nil {
                return !authoritative && Self.sameLegacyApprovalRequest(existing, incoming)
            }
            return !authoritative
        case .pending:
            return false
        }
    }

    /// Upserts an approval by Hermes request identity. Legacy events without a
    /// request id retain the historical one-card-per-session behavior. A
    /// modern authoritative replay removes only an ambiguous legacy card for
    /// that session; explicitly identified queued approvals remain distinct.
    func applyApprovalActivity(
        _ activity: ApprovalActivity,
        authoritative: Bool,
        commitsStreamedText: Bool = false
    ) {
        let equivalentSessionIDs = activeChatScrollSessionIdentity.equivalentSessionIDs
            .union([activity.sessionId])

        if authoritative, activity.requestId != nil {
            messages.removeAll { message in
                guard let existing = message.approval,
                      equivalentSessionIDs.contains(existing.sessionId),
                      existing.requestId == nil else { return false }
                return existing.status != .submitting
                    && SessionPresentationCache.isPendingDecision(existing.status)
            }
            let cacheSessionIDs = presentationCacheSessionIDs(for: activity.sessionId)
            for sessionID in equivalentSessionIDs {
                sessionPresentationCache.removePendingDecision(
                    key: "approval:\(sessionID)",
                    profile: presentationProfile(for: activity.sessionId),
                    sessionIDs: cacheSessionIDs
                )
            }
        }

        let matchingIndex: Int?
        if let requestId = activity.requestId {
            matchingIndex = messages.lastIndex(where: {
                $0.approval?.requestId == requestId
            })
        } else {
            // Legacy approvals share the session namespace, but multiple
            // sequential commands in the same session each produce a legacy
            // approval. A terminal card (.approved, .rejected, .expired) from an
            // earlier command must not swallow a subsequent legacy approval.
            // An incoming legacy event matches only an active existing card.
            matchingIndex = messages.lastIndex(where: {
                guard let existing = $0.approval else { return false }
                return existing.requestId == nil
                    && equivalentSessionIDs.contains(existing.sessionId)
                    && (existing.status == .pending || existing.status == .submitting || existing.status == .error)
            })
        }

        if let index = matchingIndex, let existing = messages[index].approval {
            let hasLiveSubmission = hasLiveApprovalSubmission(
                for: existing,
                equivalentSessionIDs: equivalentSessionIDs
            )
            if shouldPreserveLocalApprovalState(
                existing: existing,
                incoming: activity,
                authoritative: authoritative,
                hasLiveSubmission: hasLiveSubmission
            ) {
                var replay = activity
                replay.status = existing.status
                replay.choice = existing.choice
                replay.error = existing.error
                messages[index].content = replay.description
                messages[index].approval = replay
                return
            }
            messages[index].content = activity.description
            messages[index].approval = activity
            return
        }

        settleReasoningSegmentIntoTranscript()
        if commitsStreamedText { flushStreamingPartial() }
        let identity = activity.requestId ?? activity.sessionId
        messages.append(ChatMessage(
            id: "approval-\(identity)-\(UUID().uuidString)",
            role: .approval,
            content: activity.description,
            timestamp: Self.localTimestamp(),
            approval: activity
        ))
    }

    /// How a clarification activity reached AppState. Replay defenses for the
    /// one-shot stream event are deliberately weaker than the gateway's
    /// authoritative `pending_clarify` snapshot — they are not equally
    /// authoritative and must not share one merge policy.
    enum ClarifyActivitySource {
        /// A duplicate/replayed one-shot `clarify.request` (WS replay
        /// buffer). Local states are strictly newer than the stale event.
        case streamEvent
        /// `session.resume` / `session.info` `pending_clarify`: the
        /// gateway's current truth. Its question list and locked
        /// `answers[qid]` outrank local presentation state.
        case authoritativeSnapshot
    }

    /// Upserts one normalized clarification card, keyed by the gateway
    /// `request_id`. Re-delivered events update the existing card in place
    /// rather than duplicating it. Merge policy differs by source:
    ///
    /// - `.streamEvent`: a replayed event is stale by definition — never
    ///   unlock a question this device answered or has in flight, never
    ///   resurrect an expired request, and keep rows only the local card
    ///   holds.
    /// - `.authoritativeSnapshot`: the gateway's question list and locked
    ///   answers win outright — a locally cached `.submitting`/`.error`
    ///   presentation must not override the server, and the snapshot's
    ///   existence proves the request is still active, so a locally sticky
    ///   expired flag yields to it.
    func applyClarifyActivity(
        _ activity: ClarifyActivity,
        source: ClarifyActivitySource
    ) {
        if let index = messages.firstIndex(where: { $0.clarify?.requestId == activity.requestId }) {
            var merged = activity
            if let existing = messages[index].clarify {
                switch source {
                case .streamEvent:
                    // Expiry is sticky for this request id: a replayed
                    // one-shot event must not re-arm controls the gateway
                    // already expired.
                    merged.isExpired = merged.isExpired || existing.isExpired
                    let incomingIDs = Set(merged.questions.map(\.id))
                    for questionIndex in merged.questions.indices {
                        guard let prior = existing.questions.first(where: { $0.id == merged.questions[questionIndex].id }),
                              prior.status == .answered || prior.status == .submitting || prior.status == .expired else { continue }
                        // Local answered/submitting state is strictly newer
                        // than a replayed pending event; expired state stays
                        // expired.
                        merged.questions[questionIndex].status = prior.status
                        merged.questions[questionIndex].answer = prior.answer
                    }
                    // Questions only the local card holds survive the merge —
                    // a partial replay must not erase rows the user can still
                    // see.
                    let survivingExtras = existing.questions.filter { !incomingIDs.contains($0.id) }
                    merged.questions.append(contentsOf: survivingExtras)
                case .authoritativeSnapshot:
                    // The snapshot already carries the gateway's locked
                    // answers (normalizer applies `answers[qid]`). Nothing
                    // local outranks it — least of all a `.submitting` from a
                    // previous process whose RPC outcome is unknown.
                    merged.isExpired = false
                }
            }
            if merged.isExpired {
                for questionIndex in merged.questions.indices
                where merged.questions[questionIndex].status != .answered {
                    merged.questions[questionIndex].status = .expired
                    merged.questions[questionIndex].error = nil
                }
                // The user-facing explanation must survive any merge that
                // keeps the expired state — an EXPIRED card with no notice
                // reads as a broken card.
                if (merged.error ?? "").isEmpty {
                    merged.error = Self.clarifyExpiredNotice(for: merged.questions.count)
                }
            }
            messages[index].content = merged.displayQuestion
            messages[index].clarify = merged
            // A push copy that came in after this card (a resume's cached
            // decisions, a notification while it showed) goes too, or the
            // one question shows as two answerable cards (Eric 2026-11-04).
            removePushCardsSuperseded(by: merged)
            return
        }

        removePushCardsSuperseded(by: activity)
        // The clarify row must sit below everything the turn produced before
        // it: settle the live reasoning segment, then commit streamed
        // assistant text (the explanation leading up to the question).
        // Hermes' clarify tool.start is skipped above, so nothing else
        // flushes that text and it would render below the card (#572).
        // Only the live event does this: a resume snapshot lands before the
        // stream buffer is rebuilt from the recovered in-flight text.
        settleReasoningSegmentIntoTranscript()
        if source == .streamEvent { flushStreamingPartial() }
        messages.append(ChatMessage(
            id: "clarify-\(activity.requestId)",
            role: .clarify,
            content: activity.displayQuestion,
            timestamp: Self.localTimestamp(),
            clarify: activity
        ))
    }

    /// Takes still-pending push-delivered cards for the same logical clarify
    /// as `activity` out of the transcript and the presentation cache.
    func removePushCardsSuperseded(by activity: ClarifyActivity) {
        guard !activity.requestId.hasPrefix(PendingDecisionPayload.relayRequestPrefix) else { return }
        // A still-pending push-delivered card for the same logical clarify is
        // superseded by the live event (different ids: gateway vs
        // plugin-minted), so one logical clarify never renders two
        // answerable cards. A copy whose relay answer failed (.error) goes
        // too: it is still answerable, and Hermes' card is the answer path
        // now. Resolved history stays visible, and a
        // .submitting card is left alone: its relay answer may already
        // be in flight and will settle it by request id.
        //
        // Correlation is deliberately conservative (see
        // pushCardSupersededBy): the plugin mints its own request ids, so no
        // trustworthy shared identifier exists — question text is the only
        // compatibility signal, and a full batch push must match the whole
        // question set, never just its first question.
        var supersededRequestIds: [String] = []
        messages.removeAll { message in
            guard let clarify = message.clarify,
                  clarify.requestId.hasPrefix(PendingDecisionPayload.relayRequestPrefix),
                  clarify.presentationStatus == .pending || clarify.presentationStatus == .error,
                  Self.pushCardSupersededBy(clarify, live: activity) else {
                return false
            }
            supersededRequestIds.append(clarify.requestId)
            return true
        }
        // The superseded card must also leave the presentation cache —
        // the ordinary flush re-appends still-pending stored cards, so
        // an in-memory-only removal would resurface as a duplicate
        // answerable card after the next cold-start resume.
        let cacheSessionIDs = [
            activeSessionId,
            reconciliation?.requestedSessionId,
            reconciliation?.resolvedSessionId
        ].compactMap { $0 }
        for requestId in supersededRequestIds {
            sessionPresentationCache.removePendingDecision(
                key: "clarify:\(requestId)",
                profile: presentationProfile(for: activeSessionId),
                sessionIDs: cacheSessionIDs
            )
        }
    }

    /// Applies `clarify.expire { request_id }`: unanswered questions stop
    /// presenting answer controls and a late response can no longer make the
    /// request read as answered. Request identity — never question text —
    /// decides which card is torn down, so unrelated clarifies are untouched.
    func expireClarifyRequest(requestId: String, reason: String? = nil) {
        guard let index = messages.firstIndex(where: { $0.clarify?.requestId == requestId }),
              var activity = messages[index].clarify,
              !activity.isExpired else { return }
        activity.isExpired = true
        for questionIndex in activity.questions.indices
        where activity.questions[questionIndex].status != .answered {
            activity.questions[questionIndex].status = .expired
            activity.questions[questionIndex].error = nil
        }
        activity.error = Self.clarifyExpiredNotice(for: activity.questions.count, reason: reason)
        messages[index].clarify = activity
        cacheMessagePresentation()
    }

    /// Upserts one masked input card keyed by its server request id. A
    /// re-delivery (resume replay) never re-arms a card this device already
    /// answered, skipped or has in flight. The one exception mirrors
    /// approvals: a `.submitting` card whose send was fenced off by a client
    /// or profile replacement has no live submission left to settle it, so
    /// the gateway's authoritative open-request list re-arms it. A one-shot
    /// stream re-delivery is not authoritative and leaves it alone.
    func applyInputPromptActivity(
        _ activity: InputPromptActivity,
        authoritative: Bool,
        commitsStreamedText: Bool = false
    ) {
        if let index = messages.firstIndex(where: { $0.inputPrompt?.requestId == activity.requestId }) {
            guard let existing = messages[index].inputPrompt else { return }
            let orphanedSubmission = authoritative
                && existing.status == .submitting
                && !liveInputPromptSubmissions.contains(activity.requestId)
            guard existing.isAnswerable || orphanedSubmission else { return }
            var replacement = activity
            replacement.profile = activeProfile
            messages[index].content = activity.title
            messages[index].inputPrompt = replacement
            return
        }
        settleReasoningSegmentIntoTranscript()
        if commitsStreamedText { flushStreamingPartial() }
        // A resume rebuild drops input cards (they are live-only), so a
        // request whose answer is still in flight comes back here: it stays
        // `.submitting` for that send to settle, never answerable twice.
        var appended = activity
        appended.profile = activeProfile
        if liveInputPromptSubmissions.contains(activity.requestId) {
            appended.status = .submitting
            appended.error = nil
        }
        messages.append(ChatMessage(
            id: "input-prompt-\(activity.requestId)",
            role: .inputPrompt,
            content: activity.title,
            timestamp: Self.localTimestamp(),
            inputPrompt: appended
        ))
    }

    /// Applies `request.cancel` for a masked input prompt: the gateway
    /// stopped waiting, so the card stops offering input. Like
    /// `withdrawApproval`, an answer this device already has in flight owns
    /// the card's outcome.
    func expireInputPrompt(requestId: String, reason: String? = nil) {
        guard let index = messages.firstIndex(where: { $0.inputPrompt?.requestId == requestId }),
              var activity = messages[index].inputPrompt else { return }
        if activity.status == .submitting,
           liveInputPromptSubmissions.contains(requestId) {
            // The in-flight send owns the card; its completion reports the
            // withdrawal instead of a success Hermes never received.
            withdrawnInFlightInputPrompts[requestId] = reason ?? ""
            return
        }
        if activity.status == .submitting {
            // A `.submitting` card no send owns any more: its send was
            // fenced off by a client replacement, and only an open-request
            // replay could re-arm it. A withdrawn request never comes back
            // in one, so the withdrawal settles the card now.
            activity.status = .expired
            activity.error = Self.inputPromptWithdrawnNotice(reason: reason)
            messages[index].inputPrompt = activity
            return
        }
        guard activity.isAnswerable else { return }
        activity.status = .expired
        activity.error = Self.inputPromptWithdrawnNotice(reason: reason)
        messages[index].inputPrompt = activity
    }

    /// Only a timeout may claim Hermes stopped waiting and carried on; a
    /// request another surface answered says so; anything else is neutral.
    private static func inputPromptWithdrawnNotice(reason: String?) -> String {
        switch reason {
        case "timeout":
            return AppLocalization.string("This request is no longer active — Hermes stopped waiting and continued.")
        case "resolved":
            return AppLocalization.string("This request was answered elsewhere.")
        default:
            return AppLocalization.string("This request is no longer active.")
        }
    }

    /// Settles a card whose request was withdrawn mid-send; false when it
    /// was not.
    private func settleWithdrawnInFlightInputPrompt(at index: Int, requestId: String) -> Bool {
        guard let reason = withdrawnInFlightInputPrompts.removeValue(forKey: requestId) else { return false }
        messages[index].inputPrompt?.status = .expired
        messages[index].inputPrompt?.error = Self.inputPromptWithdrawnNotice(reason: reason)
        return true
    }

    /// A send whose completion failed the ownership fence leaves its card to
    /// the replacement client, which can re-arm it from an open-request
    /// replay. A request withdrawn mid-send never comes back in one, so its
    /// card settles as withdrawn here, on the profile it belongs to.
    private func settleFencedOffWithdrawnInputPrompt(messageId: String, requestId: String, profile: String) {
        guard profile == activeProfile,
              let index = messages.firstIndex(where: { $0.id == messageId }),
              messages[index].inputPrompt?.status == .submitting else { return }
        _ = settleWithdrawnInFlightInputPrompt(at: index, requestId: requestId)
    }

    /// Sends the value typed into a masked input card, or `nil` to skip.
    /// The value is handed to the client and dropped; only the card's
    /// status is recorded.
    func respondToInputPrompt(messageId: String, value: String?) async {
        guard let index = messages.firstIndex(where: { $0.id == messageId }),
              let current = messages[index].inputPrompt,
              current.isAnswerable else { return }
        // A card left from the profile before a switch: its answer (a
        // password, a login) must not go out on the new profile's
        // connection.
        guard current.profile.isEmpty || current.profile == activeProfile else {
            messages[index].inputPrompt?.status = .expired
            messages[index].inputPrompt?.error = Self.inputPromptWithdrawnNotice(reason: nil)
            return
        }
        let skipped = value == nil
        liveInputPromptSubmissions.insert(current.requestId)
        defer { liveInputPromptSubmissions.remove(current.requestId) }
        messages[index].inputPrompt?.status = .submitting
        messages[index].inputPrompt?.error = nil
        // Same as approvals and clarifies: answering resumes the turn.
        setRunning(true)
        guard let client else {
            messages[index].inputPrompt?.status = .error
            messages[index].inputPrompt?.error = AppLocalization.string("Gateway connection is unavailable.")
            return
        }
        // Same ownership fence as respondToApproval: a completion from a
        // replaced client must not touch whatever card is current.
        let profile = activeProfile
        // Whatever the completion path (including a rejected ownership
        // fence), a mid-send withdrawal record never outlives this send.
        defer { withdrawnInFlightInputPrompts.removeValue(forKey: current.requestId) }
        do {
            try await client.respondToInputPrompt(requestId: current.requestId, value: value ?? "")
            guard profile == activeProfile, self.client === client,
                  let updated = messages.firstIndex(where: { $0.id == messageId }),
                  messages[updated].inputPrompt?.status == .submitting else {
                settleFencedOffWithdrawnInputPrompt(messageId: messageId, requestId: current.requestId, profile: profile)
                return
            }
            if settleWithdrawnInFlightInputPrompt(at: updated, requestId: current.requestId) { return }
            messages[updated].inputPrompt?.status = skipped ? .skipped : .submitted
        } catch {
            guard profile == activeProfile, self.client === client,
                  let updated = messages.firstIndex(where: { $0.id == messageId }),
                  messages[updated].inputPrompt?.status == .submitting else {
                settleFencedOffWithdrawnInputPrompt(messageId: messageId, requestId: current.requestId, profile: profile)
                return
            }
            if settleWithdrawnInFlightInputPrompt(at: updated, requestId: current.requestId) { return }
            messages[updated].inputPrompt?.status = .error
            messages[updated].inputPrompt?.error = AppLocalization.string("Hermes did not receive that answer.")
            errorMessage = UserFacingError.message(for: error)
        }
    }

    // MARK: Connect cards

    /// Shows a connect card or moves it on: Hermes sends the operation's
    /// whole snapshot each time, so the newest frame is the card, and an
    /// older one changes nothing. A settled operation leaves its rows'
    /// outcomes on the card.
    @discardableResult
    func applyConnectionActivity(_ activity: ConnectionActivity, commitsStreamedText: Bool = false) -> Bool {
        if let pending = liveConnectionSubmissions[activity.opID], activity.settled || activity.seq > pending.seq {
            liveConnectionSubmissions[activity.opID] = nil
        }
        if let index = messages.firstIndex(where: { $0.connection?.opID == activity.opID }) {
            // A settled operation leaves nothing to press: no frame reopens it.
            guard let existing = messages[index].connection, !(existing.settled && activity.isOpen),
                  let next = activity.applied(over: existing) else { return false }
            messages[index].content = ConnectionActivity.transcriptLine(next)
            messages[index].connection = next
            return true
        }
        // A settled operation this device never showed has nothing to ask.
        guard activity.isOpen else { return false }
        settleReasoningSegmentIntoTranscript()
        if commitsStreamedText { flushStreamingPartial() }
        var appended = activity
        appended.profile = activeProfile
        // A resume rebuilt the transcript while an answer was on its way.
        if let pending = liveConnectionSubmissions[activity.opID] {
            appended.status = .sending
            appended.sentAtSeq = pending.seq
        }
        var row = ChatMessage(
            id: "connection-\(activity.opID)",
            role: .connection,
            content: ConnectionActivity.transcriptLine(appended),
            timestamp: Self.localTimestamp()
        )
        row.connection = appended
        messages.append(row)
        return true
    }

    /// One connect card's answer: rows approved (with the keys typed for
    /// them, which go once onto the socket and nowhere else) or skipped,
    /// or Continue. The buttons wait until Hermes' next frame shows what
    /// it made of it.
    func respondToConnection(messageId: String, targets: [[String: Any]] = [], continues: Bool = false) async {
        guard let index = messages.firstIndex(where: { $0.id == messageId }),
              let current = messages[index].connection, current.needsUser else { return }
        guard let client = connectionClient(for: current, at: index) else { return }
        let profile = activeProfile
        messages[index].connection?.status = .sending
        messages[index].connection?.sentAtSeq = current.seq
        messages[index].connection?.error = nil
        let token = UUID()
        liveConnectionSubmissions[current.opID] = (token, current.seq)
        setRunning(true)
        do {
            try await client.respondToConnection(opID: current.opID, sessionId: current.sessionId, targets: targets, continues: continues)
        } catch {
            failConnectionAnswer(messageId: messageId, opID: current.opID, token: token, profile: profile, client: client, error: error)
        }
    }

    /// Try Again on an app whose sign-in page went dead.
    func reissueConnection(messageId: String, target name: String) async {
        guard let index = messages.firstIndex(where: { $0.id == messageId }),
              let current = messages[index].connection, current.needsUser else { return }
        guard let client = connectionClient(for: current, at: index) else { return }
        let profile = activeProfile
        messages[index].connection?.status = .sending
        messages[index].connection?.sentAtSeq = current.seq
        messages[index].connection?.error = nil
        let token = UUID()
        liveConnectionSubmissions[current.opID] = (token, current.seq)
        do {
            try await client.reissueConnection(sessionId: current.sessionId, name: name)
        } catch {
            failConnectionAnswer(messageId: messageId, opID: current.opID, token: token, profile: profile, client: client, error: error)
        }
    }

    /// The sign-in page closed: Hermes looks at the account now. Only
    /// shortens the wait; Hermes' own check finds it anyway.
    func wakeConnection(messageId: String) async {
        guard let index = messages.firstIndex(where: { $0.id == messageId }),
              let current = messages[index].connection, current.isOpen,
              current.profile.isEmpty || current.profile == activeProfile,
              let client else { return }
        try? await client.wakeConnection(opID: current.opID, sessionId: current.sessionId)
    }

    /// A message sent into a chat whose connect card is open continues it
    /// first, as Hermes Desktop's composer does: the turn waits inside the
    /// tool until the card answers, so the message would wait behind it.
    func continueOpenConnections(beforeSendingIn sessionId: String) {
        let open = chatOwnSessionIDs(for: sessionId)
        for message in messages {
            guard let connection = message.connection, connection.needsUser,
                  open.contains(connection.sessionId) else { continue }
            let id = message.id
            Task { [weak self] in await self?.respondToConnection(messageId: id, continues: true) }
        }
    }

    /// The client a card's answer goes out on, or nil when there is none
    /// or the card is from the profile before a switch (it then stops
    /// offering anything: its operation is that profile's).
    private func connectionClient(for card: ConnectionActivity, at index: Int) -> HermesClient? {
        guard card.profile.isEmpty || card.profile == activeProfile else {
            messages[index].connection?.settled = true
            messages[index].connection?.status = .open
            return nil
        }
        guard let client else {
            messages[index].connection?.status = .error
            messages[index].connection?.error = AppLocalization.string("Gateway connection is unavailable.")
            return nil
        }
        return client
    }

    private func failConnectionAnswer(messageId: String, opID: String, token: UUID, profile: String, client: HermesClient, error: Error) {
        // Only this submission's failure: a later answer owns the card now.
        guard liveConnectionSubmissions[opID]?.token == token else { return }
        liveConnectionSubmissions[opID] = nil
        guard profile == activeProfile, self.client === client,
              let index = messages.firstIndex(where: { $0.id == messageId }),
              messages[index].connection?.opID == opID,
              messages[index].connection?.status == .sending else { return }
        messages[index].connection?.status = .error
        messages[index].connection?.sentAtSeq = nil
        if let rpc = error as? RpcError, rpc.reason == "UNKNOWN_OPERATION" || rpc.code == 4004 {
            // Hermes stopped waiting: the operation is gone.
            messages[index].connection?.settled = true
            messages[index].connection?.status = .open
            return
        }
        messages[index].connection?.error = AppLocalization.string("Hermes did not receive that answer.")
    }

    /// Applies `request.cancel` for an approval server request. Only a card
    /// still waiting on this user changes: an in-flight or settled answer
    /// from this device already owns the card's outcome.
    func withdrawApproval(requestId: String, reason: String) {
        guard let index = messages.lastIndex(where: { $0.approval?.requestId == requestId }),
              let current = messages[index].approval,
              current.status == .pending || current.status == .error else { return }
        messages[index].approval?.status = .expired
        messages[index].approval?.choice = nil
        switch reason {
        case "resolved":
            messages[index].approval?.error = AppLocalization.string("This approval was answered elsewhere.")
        case "timeout":
            messages[index].approval?.error = AppLocalization.string("This approval is no longer active — Hermes timed it out and continued.")
        default:
            messages[index].approval?.error = AppLocalization.string("This approval is no longer active.")
        }
        cacheMessagePresentation()
    }

    /// Only a timeout (or the legacy `clarify.expire`, which is always one)
    /// may claim Hermes timed out; an interrupt or closed session must not.
    private static func clarifyExpiredNotice(for questionCount: Int, reason: String?) -> String {
        guard let reason, reason != "timeout" else { return clarifyExpiredNotice(for: questionCount) }
        if reason == "answered_elsewhere" {
            return questionCount > 1
                ? AppLocalization.string("These questions were answered elsewhere.")
                : AppLocalization.string("This question was answered elsewhere.")
        }
        return questionCount > 1
            ? AppLocalization.string("These questions are no longer active.")
            : AppLocalization.string("This question is no longer active.")
    }

    private static func clarifyExpiredNotice(for questionCount: Int) -> String {
        questionCount > 1
            ? AppLocalization.string("These questions are no longer active — Hermes timed them out and continued.")
            : AppLocalization.string("This question is no longer active — Hermes timed it out and continued.")
    }

    /// Whether a still-pending push-delivered card describes the same logical
    /// clarify as a live gateway event and must be superseded by it.
    ///
    /// Documented limitation: the notifier plugin mints its own
    /// `conduit-push-…` request ids, so no trustworthy shared identifier
    /// exists between the push copy and the gateway copy — normalized
    /// question text is the only compatibility signal. To keep that weak
    /// signal safe:
    ///
    /// - A legacy collapsed push card (scalar payload, synthetic qid) keeps
    ///   the historical first-question correlation: the old notifier reduced
    ///   a batch to question 1, so its lone text matching ANY live question
    ///   means "same request, collapsed".
    /// - A full batch push card (real qids) must match the ENTIRE question
    ///   set. Two unrelated requests that merely share a first question —
    ///   or a genuine single-question push against a bigger live batch —
    ///   never cross-supersede.
    static func pushCardSupersededBy(_ pushed: ClarifyActivity, live: ClarifyActivity) -> Bool {
        func normalized(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let liveTexts = Set(live.questions.map { normalized($0.question) })
        guard !liveTexts.isEmpty else { return false }
        if pushed.questions.contains(where: \.isSyntheticID) {
            return liveTexts.contains(normalized(pushed.correlationQuestion))
        }
        return pushed.questions.count == live.questions.count
            && pushed.questions.allSatisfy { liveTexts.contains(normalized($0.question)) }
    }

    /// Applies the typed `clarify.respond` outcome to the matching card. The
    /// gateway's `remaining` list is the authority on whether one sub-question
    /// was locked or the whole request completed, and an expired outcome never
    /// reads as success. Only the targeted question mutates on failure, so one
    /// question's network error cannot corrupt unrelated answered questions.
    private func applyClarifyResponseOutcome(
        _ outcome: HermesClient.ClarifyResponseOutcome,
        requestId: String,
        questionId: String,
        answer: String
    ) {
        guard let index = messages.firstIndex(where: { $0.clarify?.requestId == requestId }),
              var activity = messages[index].clarify else { return }
        switch outcome {
        case .expired, .answeredElsewhere, .ended:
            activity.isExpired = true
            for questionIndex in activity.questions.indices
            where activity.questions[questionIndex].status != .answered {
                activity.questions[questionIndex].status = .expired
                activity.questions[questionIndex].error = nil
            }
            // Only a timeout may say Hermes timed it out; another surface's
            // answer, or a turn that ended, says the question is no longer active.
            activity.error = outcome == .expired
                ? Self.clarifyExpiredNotice(for: activity.questions.count)
                : Self.clarifyExpiredNotice(for: activity.questions.count, reason: outcome == .answeredElsewhere ? "answered_elsewhere" : "ended")
        case .accepted(let remaining):
            // A late accepted outcome can never resurrect an expired request.
            guard !activity.isExpired,
                  let questionIndex = activity.questions.firstIndex(where: { $0.id == questionId }) else {
                return
            }
            activity.questions[questionIndex].status = .answered
            activity.questions[questionIndex].answer = answer
            activity.questions[questionIndex].error = nil
            // Sibling reconciliation is allowed ONLY on an explicit remaining
            // list — the gateway's authority on what is still open. A locally
            // pending question it no longer lists was locked by another
            // surface; settle it without claiming this device's answer text.
            // An OMITTED remaining field (older/minimal gateways) carries no
            // sibling information, so only the submitted question is marked.
            if let remaining {
                let open = Set(remaining)
                for index in activity.questions.indices
                where index != questionIndex
                    && activity.questions[index].status == .pending
                    && !open.contains(activity.questions[index].id) {
                    activity.questions[index].status = .answered
                    activity.questions[index].answer = nil
                }
            }
        }
        messages[index].clarify = activity
        cacheMessagePresentation()
    }
}

extension AppState {
    /// Hermes blocks a clarify/approval prompt for only ~5 minutes server-side
    /// (JSON-RPC error 4009, "no pending … request"), while a restored or
    /// push-delivered card can legitimately outlive it — a notification opened
    /// an hour later is the feature's ordinary case, not an error. Treat that
    /// outcome as "the decision is no longer active" instead of a generic
    /// failure the user can retry forever.
    static func isExpiredPromptError(_ error: Error) -> Bool {
        if let rpcError = error as? RpcError {
            if rpcError.code == 4009 { return true }
            return rpcError.message.lowercased().contains("no pending")
        }
        return error.localizedDescription.lowercased().contains("no pending")
    }

    /// Where an answer to a card without a request id goes.
    enum LegacyApprovalTarget: Equatable {
        /// The gateway names no request ids: it answers the session's queue.
        case sessionQueue
        /// The queued request that asks what the card shows.
        case request(String)
        /// Nothing queued asks what the card shows any more.
        case noLongerPending
        /// A card without its command matches queued requests that run
        /// different commands: the queue's own cards are shown instead.
        case ambiguous
        /// The queue could not be read; nothing is sent. Carries why, for
        /// the card.
        case unknown(String)
    }

    /// A card without a request id (one a push restored, or one from a
    /// gateway before request ids) is answered by session, and Hermes then
    /// settles the oldest queued approval, which need not be the command
    /// the card shows. So read the queue first: a gateway that names its
    /// requests is answered on the one whose command and explanation the
    /// card shows (a push card carries no command, so only the
    /// explanation is compared, as the notifier sends it: collapsed, cut,
    /// or redacted), and nothing is sent when none does. Only
    /// a gateway that names no requests, or has no `approval.pending`,
    /// keeps the session-wide answer.
    private func legacyApprovalTarget(
        for card: ApprovalActivity,
        using client: HermesClient,
        profile: String?
    ) async -> LegacyApprovalTarget {
        let queued: [ApprovalActivity]
        do {
            if let pendingApprovalsWithProfile = chatResumeLifecycleOperations.pendingApprovalsWithProfile {
                queued = try await pendingApprovalsWithProfile(client, card.sessionId, profile)
            } else if let pendingApprovals = chatResumeLifecycleOperations.pendingApprovals {
                queued = try await pendingApprovals(client, card.sessionId)
            } else {
                queued = try await client.pendingApprovals(sessionId: card.sessionId, profile: profile)
            }
        } catch {
            if HermesClient.isMissingRPCMethod(error) { return .sessionQueue }
            // The card's runtime is gone, and with it the wait.
            if HermesClient.isSessionNotFoundError(error) { return .noLongerPending }
            return .unknown(UserFacingError.message(for: error))
        }
        return Self.legacyApprovalTarget(for: card, in: queued)
    }

    /// The explanation a redacted push carries in place of the real one
    /// (conduit-push-notifier `events.py`, `REDACTED_APPROVAL_TEXT`, used by
    /// `redact_event` for profiles with `hermes conduit-push redact on`).
    /// Keep it in step with the notifier.
    static let redactedApprovalPushDescription = "Hermes needs your approval. Open Conduit for details."

    /// How long a push's explanation can be: the notifier collapses its
    /// whitespace and cuts it at 500 code points, with no ellipsis
    /// (`sanitize_decision` / `_clean` in its `events.py`).
    static let approvalPushDescriptionLimit = 500

    static func legacyApprovalTarget(
        for card: ApprovalActivity,
        in queued: [ApprovalActivity]
    ) -> LegacyApprovalTarget {
        if queued.isEmpty { return .noLongerPending }
        let identified = queued.filter { $0.requestId != nil }
        if identified.isEmpty { return .sessionQueue }
        let description = collapsedWhitespace(card.description)
        if card.command.isEmpty, description == redactedApprovalPushDescription {
            // A redacted push names nothing to match: answerable only when
            // one request is queued; with more, the queue's own cards show.
            guard identified.count == 1, let requestId = identified[0].requestId else { return .ambiguous }
            return .request(requestId)
        }
        let command = card.command.trimmingCharacters(in: .whitespacesAndNewlines)
        // The parser trims the push text, so a cut that ended on a space
        // arrives one shorter than the limit.
        let clipped = card.command.isEmpty
            && description.unicodeScalars.count >= approvalPushDescriptionLimit - 1
        let matches = identified.filter { entry in
            let queuedDescription = collapsedWhitespace(entry.description)
            let sameDescription = queuedDescription == description
                || (clipped && queuedDescription.unicodeScalars.starts(with: description.unicodeScalars))
            return sameDescription
                && (command.isEmpty
                    || entry.command.trimmingCharacters(in: .whitespacesAndNewlines) == command)
        }
        guard let requestId = matches.first?.requestId else { return .noLongerPending }
        if Set(matches.map(\.command)).count > 1 { return .ambiguous }
        return .request(requestId)
    }

    /// Text as the notifier sends it: whitespace runs collapsed to one
    /// space, ends trimmed.
    private static func collapsedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `shown` is the approval as the card drew it when the person tapped.
    /// When the card has since changed to ask something else (a legacy card
    /// is updated in place by the next command), nothing is sent: the card
    /// on screen already shows the new question to answer.
    func respondToApproval(messageId: String, choice: String, shown: ApprovalActivity? = nil) async {
        guard let index = messages.firstIndex(where: { $0.id == messageId }),
              let current = messages[index].approval,
              current.status == .pending || current.status == .error else { return }
        if let shown, !current.asksSameAs(shown) { return }
        let decisionKey = SessionPresentationCache.decisionKey(for: messages[index])

        let submissionIdentity = current.requestId.map { ApprovalSubmissionIdentity.identified($0) }
            ?? ApprovalSubmissionIdentity.legacy(current.sessionId)
        liveApprovalSubmissions.insert(submissionIdentity)
        defer {
            liveApprovalSubmissions.remove(submissionIdentity)
        }

        messages[index].approval?.status = .submitting
        messages[index].approval?.choice = choice
        messages[index].approval?.error = nil
        setRunning(true)
        cacheMessagePresentation()

        guard let client else {
            messages[index].approval?.status = .error
            messages[index].approval?.choice = nil
            messages[index].approval?.error = AppLocalization.string("Gateway connection is unavailable.")
            cacheMessagePresentation()
            return
        }
        // Ownership snapshot: the completion below may only land while this
        // exact client (and profile) still owns AppState. A client/server
        // replacement while the RPC is suspended must turn the stale
        // continuation inert — success and failure alike — even when profile,
        // session, and message ids collide across the two connections. This
        // is the same fence `loadProjects`/`synchronizeTransportContinuation`
        // use; only client ownership changed here, so no epoch beyond the
        // pointer identity is needed.
        let profile = activeProfile
        let conversationProfile = presentationProfile(for: current.sessionId)
        var answeredRequestId = current.requestId
        if current.requestId == nil {
            let target = await legacyApprovalTarget(for: current, using: client, profile: conversationProfile)
            guard profile == activeProfile, self.client === client,
                  let updatedIndex = messages.firstIndex(where: { $0.id == messageId }),
                  SessionPresentationCache.decisionKey(for: messages[updatedIndex]) == decisionKey else { return }
            // The next command replaced the card while the queue was read:
            // a session-queue answer would go to it. Nothing is sent.
            if rearmIfReplaced(at: updatedIndex, asking: current) { return }
            switch target {
            case .sessionQueue:
                break
            case .request(let requestId):
                answeredRequestId = requestId
            case .noLongerPending:
                messages[updatedIndex].approval?.status = .expired
                messages[updatedIndex].approval?.choice = nil
                messages[updatedIndex].approval?.error = AppLocalization.string("This approval is no longer active.")
                cacheMessagePresentation()
                schedulePendingApprovalsRefresh(sessionId: current.sessionId, using: client)
                return
            case .ambiguous:
                // Back to pending, so the queue's identified cards, each
                // with its command, replace this one.
                messages[updatedIndex].approval?.status = .pending
                messages[updatedIndex].approval?.choice = nil
                cacheMessagePresentation()
                schedulePendingApprovalsRefresh(sessionId: current.sessionId, using: client)
                return
            case .unknown(let reason):
                // Nothing was sent, so not "Hermes did not accept": why
                // the queue couldn't be read, and another read to recover.
                messages[updatedIndex].approval?.status = .error
                messages[updatedIndex].approval?.choice = nil
                messages[updatedIndex].approval?.error = reason
                cacheMessagePresentation()
                schedulePendingApprovalsRefresh(
                    sessionId: current.sessionId,
                    using: client,
                    replacingLegacyErrorMessageID: messageId
                )
                return
            }
        }
        do {
            let outcome: HermesClient.ApprovalResponseOutcome
            if let respondToApproval = chatResumeLifecycleOperations.respondToApproval {
                outcome = try await respondToApproval(
                    client,
                    current.sessionId,
                    answeredRequestId,
                    choice,
                    conversationProfile
                ) ? .accepted : .noLongerWaiting
            } else {
                outcome = try await client.respondToApprovalOutcome(
                    sessionId: current.sessionId,
                    requestId: answeredRequestId,
                    choice: choice,
                    profile: conversationProfile
                )
            }
            guard profile == activeProfile, self.client === client else { return }
            guard let updatedIndex = messages.firstIndex(where: { $0.id == messageId }),
                  SessionPresentationCache.decisionKey(for: messages[updatedIndex]) == decisionKey else { return }
            // A legacy card the next command replaced in flight asks
            // something this answer never saw.
            if rearmIfReplaced(at: updatedIndex, asking: current) {
                schedulePendingApprovalsRefresh(sessionId: current.sessionId, using: client)
                return
            }
            switch outcome {
            case .accepted:
                messages[updatedIndex].approval?.status = choice == "deny" ? .rejected : .approved
            case .noLongerWaiting:
                messages[updatedIndex].approval?.status = .expired
                messages[updatedIndex].approval?.choice = nil
                messages[updatedIndex].approval?.error = AppLocalization.string("This approval is no longer active — Hermes timed it out and continued.")
            case .ended:
                // Its turn ended (stopped, or the chat moved on): not a timeout.
                messages[updatedIndex].approval?.status = .expired
                messages[updatedIndex].approval?.choice = nil
                messages[updatedIndex].approval?.error = AppLocalization.string("This approval is no longer active.")
            case .answeredElsewhere:
                messages[updatedIndex].approval?.status = .expired
                messages[updatedIndex].approval?.choice = nil
                messages[updatedIndex].approval?.error = AppLocalization.string("This approval was answered elsewhere.")
            }
            cacheMessagePresentation()
            schedulePendingApprovalsRefresh(sessionId: current.sessionId, using: client)
        } catch {
            guard profile == activeProfile, self.client === client else { return }
            guard let updatedIndex = messages.firstIndex(where: { $0.id == messageId }),
                  SessionPresentationCache.decisionKey(for: messages[updatedIndex]) == decisionKey else { return }
            if rearmIfReplaced(at: updatedIndex, asking: current) { return }
            messages[updatedIndex].approval?.status = .error
            messages[updatedIndex].approval?.choice = nil
            if Self.isExpiredPromptError(error) {
                messages[updatedIndex].approval?.status = .expired
                messages[updatedIndex].approval?.error = AppLocalization.string("This approval is no longer active — Hermes timed it out and continued.")
            } else if HermesClient.isSessionNotFoundError(error) {
                // The card's runtime is gone (reaped, or re-opened
                // elsewhere), so nothing waits on this answer any more.
                messages[updatedIndex].approval?.status = .expired
                messages[updatedIndex].approval?.error = AppLocalization.string("This approval is no longer active.")
            } else if let unsent = error as? HermesClient.AnswerNotSent {
                // Never sent: why Hermes couldn't be reached, and the card
                // can be answered again.
                messages[updatedIndex].approval?.error = UserFacingError.message(for: unsent.underlying)
            } else {
                messages[updatedIndex].approval?.error = AppLocalization.string("Hermes did not accept that decision.")
                errorMessage = UserFacingError.message(for: error)
            }
            cacheMessagePresentation()
            if current.requestId == nil {
                switch messages[updatedIndex].approval?.status {
                case .error:
                    schedulePendingApprovalsRefresh(
                        sessionId: current.sessionId,
                        using: client,
                        replacingLegacyErrorMessageID: messageId
                    )
                case .expired:
                    // The legacy request is definitively terminal, so fresh
                    // identified queued rows can be added without replacing
                    // or re-arming its expired presentation.
                    schedulePendingApprovalsRefresh(
                        sessionId: current.sessionId,
                        using: client
                    )
                default:
                    break
                }
            }
        }
    }

    /// When the legacy card at `index` no longer asks what `answered`
    /// asked (it is updated in place by the next command), it goes back to
    /// pending for the new question, and true is returned. An identified
    /// card is the same request whatever its text says now.
    private func rearmIfReplaced(at index: Int, asking answered: ApprovalActivity) -> Bool {
        guard answered.requestId == nil,
              let approval = messages[index].approval, !approval.asksSameAs(answered) else { return false }
        messages[index].approval?.status = .pending
        messages[index].approval?.choice = nil
        messages[index].approval?.error = nil
        cacheMessagePresentation()
        return true
    }
}
