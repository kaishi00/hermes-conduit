//
//  AppState+AuthorityQueue.swift
//  Conduit
//
//  The open chat's queue on the gateway's own listener (AuthorityQueue.swift):
//  what the dock above the composer does with a queued message (Cancel,
//  Edit, Send now) and with a turn a gateway restart cut off (Discard,
//  Resend). `hermes dashboard` keeps no queue, so none of this shows there.
//

import Foundation

extension AppState {
    /// The queue the dock shows, while it is the open chat's.
    func authorityQueueIsOpenChat(_ sessionID: String?) -> Bool {
        guard let sessionID, let activeSessionId else { return false }
        return sessionID == activeSessionId
            || knownSessionIDs(for: activeSessionId).contains(sessionID)
    }

    /// Withdraws a queued message. It never runs.
    func cancelQueuedPrompt(_ row: QueuedPrompt) async {
        await queueAction(row) { client, sessionID in
            _ = try await client.cancelQueuedPrompt(sessionID, admissionID: row.admissionID)
            HermesClient.forgetUnansweredSubmission(row.inputID, for: sessionID)
            _ = self.takeQueuedSendRow(admissionID: row.admissionID)
            self.authorityQueue.drop(row.admissionID)
        }
    }

    /// New words for a queued message. Hermes queues the edit at the back
    /// of the line in place of the old one.
    func editQueuedPrompt(_ row: QueuedPrompt, text: String) async {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Emptied is no edit: Remove from queue is the way to withdraw it.
        let before = BotMentions.strippingAnnotation(row.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, words != before else { return }
        // Sent as a send is: a bot the edited words name gets its note.
        let outbound = mentionAnnotatedOutboundText(words)
        // One id for the edit: a retry after a lost reply is the same edit.
        let submissionID = UUID().uuidString.lowercased()
        await queueAction(row) { client, sessionID in
            let receipt = try await client.replaceQueuedPrompt(
                sessionID, admissionID: row.admissionID, text: outbound, submissionID: submissionID
            )
            // The old words are settled: sending them again is a new message.
            HermesClient.forgetUnansweredSubmission(row.inputID, for: sessionID)
            let kept = self.takeQueuedSendRow(admissionID: row.admissionID)
            self.authorityQueue.drop(row.admissionID)
            // The user's own message still comes back to the transcript when
            // its turn starts, now with the new words. A file it carried
            // stays with it (Hermes keeps it on the edit's admission). Only
            // in its own chat: one opened meanwhile reads it from Hermes.
            if !receipt.admissionID.isEmpty, self.authorityQueueIsOpenChat(sessionID) {
                var edited = kept ?? self.localUserRow(words)
                edited.content = words
                edited.rawContent = nil
                self.holdQueuedSendRow(edited, admissionID: receipt.admissionID)
            }
        }
    }

    /// Sends a queued message into the running turn now, as a steer.
    func sendQueuedPromptNow(_ row: QueuedPrompt) async {
        await queueAction(row) { client, sessionID in
            let persistedTwinsBefore = self.persistedSteerIDs(matching: row.text)
            _ = try await client.sendQueuedPromptNow(sessionID, admissionID: row.admissionID)
            // Steered in: the same words sent later are a new message.
            HermesClient.forgetUnansweredSubmission(row.inputID, for: sessionID)
            _ = self.takeQueuedSendRow(admissionID: row.admissionID)
            self.authorityQueue.drop(row.admissionID)
            if self.authorityQueueIsOpenChat(sessionID) {
                self.appendLocalSteerMessage(row.text, persistedTwinsBefore: persistedTwinsBefore)
            }
        }
    }

    /// Lets go of a turn a gateway restart cut off: Hermes marks it
    /// interrupted, never runs it again, and the messages behind it go on.
    @discardableResult
    func discardLostPrompt(_ row: QueuedPrompt, onUnreachable: (@MainActor () -> Void)? = nil) async -> Bool {
        guard let generation = row.executionGeneration else {
            authorityQueue.notice = AppLocalization.string("Hermes didn't say which turn this was. Reopen the chat and try again.")
            return false
        }
        return await queueAction(row, onUnreachable: onUnreachable) { client, sessionID in
            _ = try await client.discardLostPrompt(sessionID, admissionID: row.admissionID, generation: generation)
            // Resend's words then go as a new message, never as this one again.
            HermesClient.forgetUnansweredSubmission(row.inputID, for: sessionID)
            _ = self.takeQueuedSendRow(admissionID: row.admissionID)
            self.authorityQueue.drop(row.admissionID)
        }
    }

    /// Discards a cut-off turn and sends its words again, as a new message.
    /// The messages that waited behind it run first.
    func resendLostPrompt(_ row: QueuedPrompt) async {
        let sessionID = authorityQueue.sessionID
        // Where the words go back if the resend doesn't go: this chat's
        // draft, wherever the user is by then.
        let draftKey = durableComposerDraftKeyOnScreen
        let dashboardID = activeDashboardID
        let title = displayedChatTitle
        // The user's own words: sending them annotates @mentions afresh.
        let words = BotMentions.strippingAnnotation(row.text)
        func putWordsBack() {
            if let dashboardID {
                returnFailedComposerSubmission(
                    ComposerDraft(text: words, attachments: []),
                    key: draftKey,
                    dashboardID: dashboardID,
                    title: title,
                    stoppedQuietly: true
                )
            } else {
                prefillComposer(words)
            }
        }
        // Its own discard says whether it went: another row's refusal
        // meanwhile must not keep these words from going. A refused
        // discard keeps the card, and the words with it. One whose reply
        // never came may have gone, and one refused as no longer waiting
        // has: the card can vanish at the next queue push, so the words go
        // back in the draft and a later send of them is a new message.
        guard await discardLostPrompt(row, onUnreachable: {
            if let sessionID { HermesClient.forgetUnansweredSubmission(row.inputID, for: sessionID) }
            _ = self.takeQueuedSendRow(admissionID: row.admissionID)
            putWordsBack()
        }) else { return }
        // Hermes took these words as a message once: they go as one again,
        // never as a slash command run here.
        if authorityQueueIsOpenChat(sessionID),
           await submitComposer(text: words, busyMode: .queue, runsSlashCommands: false) {
            return
        }
        // The card is gone: the words go back in the chat's draft rather
        // than nowhere.
        putWordsBack()
    }

    /// Runs one of the dock's actions on the open chat's queue, saying why
    /// it didn't go when Hermes refuses it. True when the action went.
    @discardableResult
    private func queueAction(
        _ row: QueuedPrompt,
        onUnreachable: (@MainActor () -> Void)? = nil,
        _ action: @escaping @MainActor (HermesClient, String) async throws -> Void
    ) async -> Bool {
        guard let sessionID = authorityQueue.sessionID, !authorityQueue.working.contains(row.admissionID) else { return false }
        guard let client, client.speaksSessionAuthority else {
            authorityQueue.notice = AppLocalization.string("Hermes isn't connected. Try again once it is.")
            return false
        }
        authorityQueue.notice = nil
        authorityQueue.setWorking(row.admissionID, true)
        defer { authorityQueue.setWorking(row.admissionID, false) }
        do {
            try await action(client, sessionID)
            return true
        } catch {
            // No answer at all: Hermes may have done it. Or the row is
            // settled already (another client, or Hermes): either way the
            // card can vanish at the next queue push.
            if !(error is RpcError) || Self.refusalMeansSettled(error) { onUnreachable?() }
            // Said under its own chat's queue only, not one opened meanwhile.
            guard authorityQueue.sessionID == sessionID else { return false }
            authorityQueue.notice = Self.queueActionRefusal(error)
            return false
        }
    }

    /// Whether a refusal says the row isn't waiting any more.
    static func refusalMeansSettled(_ error: Error) -> Bool {
        guard let refusal = error as? RpcError else { return false }
        return ["not_found", "stale_generation", "admission_terminal"].contains(refusal.reason ?? refusal.message)
    }

    /// The words for a refused queue action. Hermes' reasons: the turn has
    /// no agent to take a steer yet, the message already started, or no
    /// turn runs to send it into; it stays queued in each.
    static func queueActionRefusal(_ error: Error) -> String {
        guard let refusal = error as? RpcError else {
            return AppLocalization.string("Hermes couldn't be reached. Check the queue before you try again.")
        }
        switch refusal.reason ?? refusal.message {
        case "steer_unavailable":
            return AppLocalization.string("Hermes can't take it into this reply yet. It stays queued.")
        case "admission_started":
            return AppLocalization.string("Hermes already started on it.")
        case "session_idle":
            return AppLocalization.string("No reply is running to send it into. It runs next.")
        case "not_found", "stale_generation", "admission_terminal":
            return AppLocalization.string("That message isn't waiting any more.")
        default:
            return refusal.errorDescription ?? refusal.message
        }
    }
}
