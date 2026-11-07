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
            _ = self.takeQueuedSendRow(admissionID: row.admissionID)
            self.authorityQueue.drop(row.admissionID)
        }
    }

    /// New words for a queued message. Hermes queues the edit at the back
    /// of the line in place of the old one.
    func editQueuedPrompt(_ row: QueuedPrompt, text: String) async {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Emptied is no edit: Remove from queue is the way to withdraw it.
        guard !words.isEmpty, words != row.text.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        // One id for the edit: a retry after a lost reply is the same edit.
        let submissionID = UUID().uuidString.lowercased()
        await queueAction(row) { client, sessionID in
            let receipt = try await client.replaceQueuedPrompt(
                sessionID, admissionID: row.admissionID, text: words, submissionID: submissionID
            )
            let kept = self.takeQueuedSendRow(admissionID: row.admissionID)
            self.authorityQueue.drop(row.admissionID)
            // The user's own message still comes back to the transcript when
            // its turn starts, now with the new words. A file it carried
            // stays with it (Hermes keeps it on the edit's admission).
            if !receipt.admissionID.isEmpty {
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
            _ = self.takeQueuedSendRow(admissionID: row.admissionID)
            self.authorityQueue.drop(row.admissionID)
            if self.authorityQueueIsOpenChat(sessionID) {
                self.appendLocalSteerMessage(row.text, persistedTwinsBefore: persistedTwinsBefore)
            }
        }
    }

    /// Lets go of a turn a gateway restart cut off: Hermes marks it
    /// interrupted, never runs it again, and the messages behind it go on.
    func discardLostPrompt(_ row: QueuedPrompt) async {
        guard let generation = row.executionGeneration else {
            authorityQueue.notice = AppLocalization.string("Hermes didn't say which turn this was. Reopen the chat and try again.")
            return
        }
        await queueAction(row) { client, sessionID in
            _ = try await client.discardLostPrompt(sessionID, admissionID: row.admissionID, generation: generation)
            _ = self.takeQueuedSendRow(admissionID: row.admissionID)
            self.authorityQueue.drop(row.admissionID)
        }
    }

    /// Discards a cut-off turn and sends its words again, as a new message.
    /// The messages that waited behind it run first.
    func resendLostPrompt(_ row: QueuedPrompt) async {
        let sessionID = authorityQueue.sessionID
        await discardLostPrompt(row)
        guard authorityQueue.row(row.admissionID) == nil, authorityQueue.notice == nil,
              authorityQueueIsOpenChat(sessionID) else { return }
        // Hermes took these words as a message once: they go as one again,
        // never as a slash command run here.
        _ = await submitComposer(text: row.text, busyMode: .queue, runsSlashCommands: false)
    }

    /// Runs one of the dock's actions on the open chat's queue, saying why
    /// it didn't go when Hermes refuses it.
    private func queueAction(
        _ row: QueuedPrompt,
        _ action: @escaping @MainActor (HermesClient, String) async throws -> Void
    ) async {
        guard let sessionID = authorityQueue.sessionID, !authorityQueue.working.contains(row.admissionID) else { return }
        guard let client, client.speaksSessionAuthority else {
            authorityQueue.notice = AppLocalization.string("Hermes isn't connected. Try again once it is.")
            return
        }
        authorityQueue.notice = nil
        authorityQueue.setWorking(row.admissionID, true)
        defer { authorityQueue.setWorking(row.admissionID, false) }
        do {
            try await action(client, sessionID)
        } catch {
            // Said under its own chat's queue only, not one opened meanwhile.
            guard authorityQueue.sessionID == sessionID else { return }
            authorityQueue.notice = Self.queueActionRefusal(error)
        }
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
