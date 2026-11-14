//
//  AppState+Steering.swift
//  Conduit
//
//  Steering a running turn, redirecting or interrupting it to send, the
//  queued sends' rows, and cancelling the current turn. Moved out of
//  AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Steering, interrupting and queued sends

    func steer(
        _ text: String,
        context: ComposerSubmissionContext? = nil,
        surfacesFailure: Bool = true
    ) async -> Bool {
        let submissionContext = context ?? composerSubmissionContext()
        guard isCurrentComposerSubmission(submissionContext) else { return false }
        guard let client, let sessionId = activeSessionId else { return false }
        cancelChatResumeRestoration()
        let outboundText = mentionAnnotatedOutboundText(text)
        // Only a failure already shown is this send's to clear; one a
        // send made while this one was on its way stays.
        let failureBefore = sendFailureMark
        let persistedTwinsBefore = persistedSteerIDs(matching: outboundText)
        do {
            if let steer = chatResumeLifecycleOperations.steer {
                try await steer(client, sessionId, outboundText)
            } else {
                try await client.steer(sessionId, text: outboundText, profile: presentationProfile(for: sessionId))
            }
            // A successful steer proves Hermes applied the session's busy
            // policy — the session was RUNNING when the steer landed. That is
            // authoritative live liveness evidence for the recovery stamp
            // guard, even though steer writes no local turn state. It is
            // evidence about the ORIGINATING conversation only: the RPC may
            // complete after the user switched conversations, and a late
            // Session-A steer must never contaminate Session B's global
            // evidence — a stale running claim here would let B's older
            // ambiguous recovery resurrect ownership over B's newer settled
            // edge. Alias rotation within the same conversation still counts;
            // a genuine handoff does not.
            // Bool test only — the re-homed context it computes internally is
            // not needed, because steer performs no further session-scoped
            // writes after this point.
            if isCurrentOrAliasedComposerSubmission(submissionContext) {
                shownChat.turnLifecycleEvidence = TurnLifecycleEvidence(
                    revision: shownChat.turnLifecycleEvidence.revision &+ 1,
                    running: true
                )
                // Confirm the steer in the transcript (issue #337): Hermes
                // persists it as a `display_kind: "steer"` user row only
                // when the agent next reaches a tool boundary, so without
                // this the text just vanished from the composer.
                appendLocalSteerMessage(outboundText, persistedTwinsBefore: persistedTwinsBefore)
                clearSendFailureAfterSend(failureBefore)
            }
            // A successful steer is accepted by Hermes even if the user
            // switched sessions while the RPC was suspended. Apart from the
            // ownership-gated evidence write above it has no local post-await
            // mutation, so preserve success for draft handling.
            return true
        } catch {
            // A spoken steer that fails is dropped by Voice; there is no
            // composer draft to recover or banner to show.
            guard surfacesFailure,
                  isCurrentOrAliasedComposerSubmission(submissionContext) else {
                if surfacesFailure, Self.isAmbiguousPromptDelivery(error) {
                    composerSubmissionsOfUnknownDelivery.append(submissionContext)
                }
                return false
            }
            errorMessage = UserFacingError.message(for: error)
            await recoverComposerSubmission(using: submissionContext)
            return false
        }
    }

    /// The modern Hermes path. It interrupts and rebuilds the live model
    /// request while retaining completed work; gateways can also acknowledge a
    /// correction as queued during their agent-build window. Older gateways
    /// retain the established `session.interrupt` then `prompt.submit` flow.
    func redirectOrInterruptAndSend(
        _ text: String,
        retriedAfterResume: Bool = false,
        context: ComposerSubmissionContext? = nil
    ) async -> Bool {
        let submissionContext = context ?? composerSubmissionContext()
        guard isCurrentComposerSubmission(submissionContext) else { return false }
        guard let client, let sessionId = activeSessionId else { return false }
        cancelChatResumeRestoration()
        // Fallbacks below re-enter `sendMessage` with the RAW text, which
        // annotates on its own; only the redirect itself sends this copy.
        let outboundText = mentionAnnotatedOutboundText(text)
        // Only a failure already shown is this send's to clear; one a
        // send made while this one was on its way stays.
        let failureBefore = sendFailureMark

        do {
            let outcome: SessionRedirectOutcome
            if let redirect = chatResumeLifecycleOperations.redirect {
                outcome = try await redirect(client, sessionId, outboundText)
            } else {
                outcome = try await client.redirect(sessionId, text: outboundText, profile: presentationProfile(for: sessionId))
            }
            switch outcome {
            case .redirected, .queued:
                if isCurrentOrAliasedComposerSubmission(submissionContext) {
                    appendLocalUserMessage(outboundText)
                    clearSendFailureAfterSend(failureBefore)
                }
                return true
            case .rejected:
                // A reject commonly means the turn won the race to completion.
                // Reconcile first so we submit directly when it is already idle
                // instead of surfacing a misleading interrupt failure.
                guard isCurrentOrAliasedComposerSubmission(submissionContext) else { return false }
                guard let recoveredContext = await recoverComposerSubmission(using: submissionContext) else {
                    return false
                }
                guard isCurrentComposerSubmission(recoveredContext) else { return false }
                if turnState == .idle {
                    return await sendMessage(
                        text,
                        attachments: [],
                        context: recoveredContext
                    )
                }
                guard turnState == .running else { return false }
                return await interruptAndSendLegacy(text, context: recoveredContext)
            }
        } catch let error as RpcError {
            guard isCurrentOrAliasedComposerSubmission(submissionContext) else { return false }
            if isUnsupportedRedirect(error) {
                guard let currentContext = currentComposerSubmissionContextIfOwnedAndAliased(submissionContext) else {
                    return false
                }
                return await interruptAndSendLegacy(text, context: currentContext)
            }

            // A runtime session can be rotated while the app was backgrounded.
            // Reconcile once, then retry against the recovered runtime id.
            if !retriedAfterResume, isSessionNotFound(error) {
                guard let recoveredContext = await recoverComposerSubmission(using: submissionContext) else {
                    return false
                }
                guard isCurrentComposerSubmission(recoveredContext) else { return false }
                if turnState == .running {
                    return await redirectOrInterruptAndSend(
                        text,
                        retriedAfterResume: true,
                        context: recoveredContext
                    )
                }
                if turnState == .idle {
                    return await sendMessage(
                        text,
                        attachments: [],
                        context: recoveredContext
                    )
                }
                return false
            }

            errorMessage = AppLocalization.string("Could not redirect the active response: \(UserFacingError.message(for: error))")
            await recoverComposerSubmission(using: submissionContext)
            return false
        } catch {
            guard isCurrentOrAliasedComposerSubmission(submissionContext) else {
                // Its chat was left; the redirect may only have lost its reply.
                if Self.isAmbiguousPromptDelivery(error) { composerSubmissionsOfUnknownDelivery.append(submissionContext) }
                return false
            }
            errorMessage = AppLocalization.string("Could not redirect the active response: \(UserFacingError.message(for: error))")
            await recoverComposerSubmission(using: submissionContext)
            return false
        }
    }

    private func interruptAndSendLegacy(
        _ text: String,
        context: ComposerSubmissionContext
    ) async -> Bool {
        guard await interruptForReplacement(context: context) else { return false }
        guard let currentContext = currentComposerSubmissionContextIfOwnedAndAliased(context) else {
            return false
        }
        return await sendMessage(text, attachments: [], context: currentContext)
    }

    static func isLocalSteerTwin(_ candidate: ChatMessage, of persisted: ChatMessage) -> Bool {
        candidate.isSteer
            && candidate.id.hasPrefix("local-")
            && candidate.content.trimmingCharacters(in: .whitespacesAndNewlines)
                == persisted.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The gateway applied its busy policy and steered a prompt Conduit sent
    /// as a new turn: restyle its optimistic bubble as a steer so it reads
    /// the same as one sent with the Steer button. Attachment rows keep
    /// their ordinary bubble, since the steer row cannot show attachments.
    func markOptimisticRowAsSteer(_ id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              messages[index].role == .user,
              messages[index].attachments?.isEmpty ?? true else { return }
        messages[index].displayKind = ChatMessage.steerDisplayKind
        // Match the persisted twin's visible text (image tokens moved out).
        messages[index].content = MessageNormalizer.visibleUserText(messages[index].content)
        cacheMessagePresentation()
    }

    /// Ids of durable steer rows on screen whose visible text matches `text`.
    func persistedSteerIDs(matching text: String) -> Set<String> {
        let visible = MessageNormalizer.visibleUserText(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Set(messages.lazy.filter {
            $0.isSteer
                && !$0.id.hasPrefix("local-")
                && $0.content.trimmingCharacters(in: .whitespacesAndNewlines) == visible
        }.map(\.id))
    }

    func appendLocalSteerMessage(_ text: String, persistedTwinsBefore: Set<String>) {
        // A reconcile while the steer RPC was suspended may already have
        // adopted THIS steer's persisted row; don't confirm it twice. Only a
        // matching row that appeared during the RPC counts, so repeating an
        // earlier steer word for word still gets its own confirmation. (The
        // RPC returns no row identity, so an identical steer persisted from
        // another surface in that window also suppresses it.)
        if !persistedSteerIDs(matching: text).isSubset(of: persistedTwinsBefore) {
            return
        }
        // Same ordering rule as a redirect correction: the steer sits above
        // the live reasoning card's eventual commit.
        settleReasoningSegmentIntoTranscript()
        messages.append(ChatMessage(
            id: "local-steer-\(UUID().uuidString)",
            role: .user,
            // The persisted row's visible text (image tokens moved out), so
            // the local row and its persisted twin compare equal.
            content: MessageNormalizer.visibleUserText(text),
            rawContent: nil,
            timestamp: Self.localTimestamp(),
            author: nil,
            displayKind: ChatMessage.steerDisplayKind
        ))
        requestChatScrollToLatest()
        cacheMessagePresentation()
    }

    /// Another connection or a sign-out: no queue, and no held bubble,
    /// carries over to the next account's chats.
    func clearAuthorityQueueState() {
        authorityQueue.clear()
        sessionControl.clear()
        queuedSendRows = [:]
        queuedSendOrder = []
        ownSendRowIDs = [:]
        startedAdmissionIDs = []
        startedAdmissionAnchors = [:]
    }

    /// Keeps a queued message's bubble for when its turn starts. One whose
    /// turn already started (its start came before this send's reply)
    /// stays in the transcript.
    func holdQueuedSendRow(_ row: ChatMessage, admissionID: String) {
        guard !startedAdmissionIDs.contains(admissionID) else {
            if !messages.contains(where: { $0.id == row.id }) {
                // Above the rows its turn has already streamed: they follow
                // the row that was last when it started.
                let turnStart: Int
                switch startedAdmissionAnchors[admissionID] {
                case .some(.some(let anchorID)):
                    turnStart = messages.firstIndex(where: { $0.id == anchorID }).map { $0 + 1 } ?? messages.endIndex
                case .some(.none):
                    turnStart = messages.startIndex
                case .none:
                    turnStart = messages.endIndex
                }
                messages.insert(row, at: turnStart)
                requestChatScrollToLatest()
                cacheMessagePresentation()
            }
            return
        }
        queuedSendRows[admissionID] = row
        queuedSendOrder.removeAll { $0 == admissionID }
        queuedSendOrder.append(admissionID)
        while queuedSendOrder.count > 32 {
            queuedSendRows.removeValue(forKey: queuedSendOrder.removeFirst())
        }
    }

    /// A send the authority admitted as a new turn, with its bubble.
    func noteOwnSend(admissionID: String, rowID: String) {
        if ownSendRowIDs.count >= 32 { ownSendRowIDs.removeAll() }
        ownSendRowIDs[admissionID] = rowID
    }

    /// The user's sends the chat's queue lists as waiting (or cut off by a
    /// restart): their bubbles go to the dock until their turn starts.
    func adoptOwnQueuedSends(_ rows: [QueuedPrompt]) {
        var moved = false
        for row in rows where (row.status == .queued && !row.steering) || row.status == .unknown {
            guard let rowID = ownSendRowIDs.removeValue(forKey: row.admissionID),
                  !startedAdmissionIDs.contains(row.admissionID),
                  let index = messages.firstIndex(where: { $0.id == rowID }) else { continue }
            holdQueuedSendRow(messages.remove(at: index), admissionID: row.admissionID)
            moved = true
        }
        if moved { cacheMessagePresentation() }
    }

    func takeQueuedSendRow(admissionID: String) -> ChatMessage? {
        queuedSendOrder.removeAll { $0 == admissionID }
        return queuedSendRows.removeValue(forKey: admissionID)
    }

    /// A send the authority queued behind the running turn: its bubble
    /// leaves the transcript for the dock above the composer, where it can
    /// be cancelled, edited or sent now, and comes back when its turn starts.
    func moveQueuedSendToDock(rowID: String, sessionID: String) {
        guard let admissionID = HermesClient.admittedAdmissionID(for: sessionID),
              !startedAdmissionIDs.contains(admissionID),
              let index = messages.firstIndex(where: { $0.id == rowID }) else { return }
        holdQueuedSendRow(messages.remove(at: index), admissionID: admissionID)
        cacheMessagePresentation()
    }

    /// A turn the authority started from the chat's queue (its
    /// `message.start` names the admission): a message of the user's that
    /// waited in the dock takes its place in the transcript, above the
    /// reply. Another client's queued message shows as other turns do.
    func noteQueuedTurnStarted(sessionID: String, admissionID: String) {
        ownSendRowIDs.removeValue(forKey: admissionID)
        if startedAdmissionIDs.count >= 64 {
            startedAdmissionIDs.removeAll()
            startedAdmissionAnchors.removeAll()
        }
        startedAdmissionIDs.insert(admissionID)
        guard let row = takeQueuedSendRow(admissionID: admissionID) else {
            if eventBelongsToActiveSession(sessionID) {
                startedAdmissionAnchors[admissionID] = .some(messages.last?.id)
            }
            return
        }
        authorityQueue.drop(admissionID)
        guard eventBelongsToActiveSession(sessionID) else { return }
        settleReasoningSegmentIntoTranscript()
        var started = row
        started.timestamp = Self.localTimestamp()
        messages.append(started)
        requestChatScrollToLatest()
        cacheMessagePresentation()
    }

    /// The user's message as the composer shows it before Hermes stores it.
    func localUserRow(_ text: String) -> ChatMessage {
        ChatMessage(
            id: "local-queued-\(UUID().uuidString)",
            role: .user,
            content: text,
            rawContent: nil,
            timestamp: Self.localTimestamp(),
            author: nil
        )
    }

    func appendLocalUserMessage(_ text: String) {
        // Hermes records redirect corrections itself. When the correction is
        // just a repeat of the prompt it interrupted, avoid rendering a second
        // identical outgoing bubble while the gateway catches up.
        if let interruption = messages.last,
           interruption.role == .system,
           MessageNormalizer.isUserCorrectionInterruptionNotice(interruption.rawContent ?? interruption.content),
           let previousUser = messages.dropLast().last(where: { $0.role == .user }),
           previousUser.content.trimmingCharacters(in: .whitespacesAndNewlines)
                == text.trimmingCharacters(in: .whitespacesAndNewlines) {
            return
        }
        // Mid-turn ordering rule: a steer/redirect correction bubble must sit
        // above the live reasoning card's eventual commit. Reasoning that
        // resumes after the correction mounts a fresh segment below it,
        // matching the tool-boundary precedent.
        settleReasoningSegmentIntoTranscript()
        messages.append(ChatMessage(
            id: "local-correction-\(Date().timeIntervalSince1970)",
            role: .user,
            content: text,
            rawContent: nil,
            timestamp: Self.localTimestamp(),
            author: nil
        ))
        cacheMessagePresentation()
    }

    func isUnsupportedRedirect(_ error: RpcError) -> Bool {
        Self.isUnsupportedRedirect(code: error.code, message: error.message)
    }

    /// A gateway without `session.redirect` (Hermes before the active-turn
    /// redirect) answers JSON-RPC "method not found": code -32601 with
    /// "unknown method: session.redirect" on the TUI gateway.
    nonisolated static func isUnsupportedRedirect(code: Int?, message: String) -> Bool {
        let message = message.lowercased()
        return code == 4010
            || code == -32601
            || message.contains("does not support active-turn redirect")
            || message.contains("method not found")
            // The TUI gateway's wording ("unknown method: session.redirect"):
            // only when it names this method.
            || (message.contains("unknown method") && message.contains("session.redirect"))
    }

    /// A gateway without `session.steer` answers JSON-RPC "method not found",
    /// as isUnsupportedRedirect reads it for `session.redirect`.
    nonisolated static func isUnsupportedSteer(code: Int?, message: String) -> Bool {
        let message = message.lowercased()
        return code == -32601
            || message.contains("method not found")
            || (message.contains("unknown method") && message.contains("session.steer"))
    }

    private func isSessionNotFound(_ error: RpcError) -> Bool {
        error.message.lowercased().contains("session not found")
    }

    private func interruptForReplacement(
        context: ComposerSubmissionContext? = nil
    ) async -> Bool {
        let submissionContext = context ?? composerSubmissionContext()
        guard let currentContext = currentComposerSubmissionContextIfOwnedAndAliased(submissionContext) else {
            return false
        }
        guard let client, let sessionId = currentContext.sessionID else { return false }
        let noteBeforeCancel = voiceCancelNote(in: sessionId)
        let wasRunning = isBusy
        noteRunningTurnBeforeCancel(in: sessionId)
        let noteWrite = voiceCancelNoteWrites[sessionId]
        cancelChatResumeRestoration()
        turnState = .synchronizing
        do {
            if let interrupt = chatResumeLifecycleOperations.interrupt {
                try await interrupt(client, sessionId)
            } else {
                let stopped = try await client.cancel(sessionId, profile: presentationProfile(for: sessionId))
                noteVoiceStoppedTurn(sessionId: sessionId, generation: stopped, wasRunning: wasRunning, ifStill: noteWrite)
            }
            guard isCurrentOrAliasedComposerSubmission(currentContext) else { return false }
            return true
        } catch {
            // The turn wasn't stopped, so Voice may still hear it.
            restoreVoiceCancelNote(in: sessionId, to: noteBeforeCancel, ifStill: noteWrite)
            guard isCurrentOrAliasedComposerSubmission(currentContext) else { return false }
            errorMessage = AppLocalization.string("Could not interrupt the active response: \(UserFacingError.message(for: error))")
            await recoverComposerSubmission(using: currentContext)
            return false
        }
    }

    /// Cancels the authoritative Hermes turn, reporting whether the
    /// cancellation succeeded. "Success" also covers nothing being left to
    /// cancel (the turn already settled server-side).
    /// `stopsWorkstream`: the composer's Stop, which stops an open
    /// workstream through the plugin when this chat has no turn of its own
    /// (voice's interrupts and cleanups don't).
    @discardableResult
    func cancelCurrent(stopsWorkstream: Bool = false) async -> Bool {
        guard isBusy else {
            if stopsWorkstream, let open = workstreamStoppedByComposer {
                return await actOnWorkstream(open.item, profile: open.profile, action: .stop)
            }
            return true
        }
        let submissionContext = composerSubmissionContext()
        guard await interruptForReplacement(context: submissionContext) else { return false }
        guard let currentContext = currentComposerSubmissionContextIfOwnedAndAliased(submissionContext) else { return true }
        await recoverComposerSubmission(using: currentContext)
        return true
    }
}
