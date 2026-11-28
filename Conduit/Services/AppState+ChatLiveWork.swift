//
//  AppState+ChatLiveWork.swift
//  Conduit
//
//  The open chat's turn running in the gateway on `hermes dashboard`
//  (ChatLiveWork.swift, Eric 2026-11-27): read from the notifier plugin's
//  `GET /sessions/live-work`, for the working line above the composer and
//  the queue dock, whose rows the dashboard itself can't list.
//

import Foundation

extension AppState {
    /// The open chat's turn in the gateway, by the id Hermes stores it
    /// under, in the profile it runs under. Nil when there's nothing to
    /// say: no open chat, no connection, the gateway's own listener (its
    /// stream and `pending` tell it all), a plugin without the route, a chat
    /// Hermes has no row for yet, a failed read, or a dashboard that changed
    /// while it was out.
    func loadOpenChatLiveWork() async -> ChatLiveWork? {
        guard activeSessionId != nil else { return nil }
        // Another combined dashboard's chat on screen: read on its own
        // runtime, from its own dashboard and profile (AppState+FarChat.swift).
        if let routed = await onChatRuntime(unreachable: ChatLiveWork?.none, { await loadOpenChatLiveWork() }) {
            return routed
        }
        guard client?.speaksSessionAuthority != true,
              let sessionID = openChatUsageSessionID(),
              let route = ChatLiveWork.route(sessionID: sessionID),
              isConnected, let owner = currentDashboardRuntimeOwner() else { return nil }
        guard case .reported(_, let capabilities) = notifierPlugin.state,
              capabilities.contains(ChatLiveWork.capability) else { return nil }
        let path = DashboardPath.withProfile(route, profile: conversationIdentityProfile)
        let askedAt = Date()
        guard let response = try? await owner.bridge.requestJSON(path: path), ownsDashboardRuntime(owner) else { return nil }
        return ChatLiveWork(response: response, askedAt: askedAt)
    }

    /// A read of the open chat's turn in the gateway: its queue into the
    /// dock (without buttons), the user's own waiting messages back into
    /// the chat once their turn has started, and the chat read again when
    /// the turn it followed there has ended.
    func applyChatLiveWork(_ work: ChatLiveWork, previous: ChatLiveWork?, for chatID: String) {
        // The chat's own runtime says which listener it is on: a far combined
        // dashboard's chat may differ from the one on screen.
        guard activeSessionId == chatID,
              !onChatRuntimeValue(unreachable: true, { client?.speaksSessionAuthority == true }) else { return }
        let waiting = Set(work.queued.map(\.admissionID))
        // Only this chat's sends: another chat's wait in their own chat's reads.
        let ours = { (admissionID: String) in
            (self.shownChat.forwardedSendChats[admissionID] ?? chatID) == chatID
        }
        // A send held after the read was asked isn't in it yet: it keeps its row.
        let newer = { (admissionID: String) in
            (self.shownChat.forwardedSendTimes[admissionID] ?? .distantPast) > work.askedAt
        }
        var settled = false
        for admissionID in shownChat.queuedSendOrder where ours(admissionID) && !waiting.contains(admissionID) && !newer(admissionID) {
            shownChat.forwardedSendTimes.removeValue(forKey: admissionID)
            if work.startedAdmissions.contains(admissionID) {
                // Its turn runs there now; the unnamed start still to come is its
                // own (its chat kept, so only that chat's start takes it).
                noteQueuedTurnStarted(sessionID: chatID, admissionID: admissionID)
                shownChat.readStartedAdmissions = Array((shownChat.readStartedAdmissions + [admissionID]).suffix(8))
            } else {
                // It ran and ended between reads, or was withdrawn in the Webapp
                // or Hermes Desktop: the chat's stored rows tell which.
                shownChat.forwardedSendChats.removeValue(forKey: admissionID)
                _ = takeQueuedSendRow(admissionID: admissionID)
                authorityQueue.drop(admissionID)
                settled = true
            }
        }
        // A message the last read listed whose turn runs now, that nothing here
        // holds (the chat was reopened while it waited, or another app sent it):
        // its words come in once, from the queue, as a held one would.
        for row in previous?.queued ?? [] where work.startedAdmissions.contains(row.admissionID)
            && !shownChat.startedAdmissionIDs.contains(row.admissionID)
            && !shownChat.queuedSendOrder.contains(row.admissionID)
            && !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            holdQueuedSendRow(localUserRow(row.text), admissionID: row.admissionID)
            noteQueuedTurnStarted(sessionID: chatID, admissionID: row.admissionID)
            // Its unnamed start already came and no held send took it (#3420).
            if let seen = shownChat.otherAppStartsSeen.firstIndex(of: row.admissionID) {
                shownChat.otherAppStartsSeen.remove(at: seen)
                continue
            }
            shownChat.forwardedSendChats[row.admissionID] = chatID
            shownChat.readStartedAdmissions = Array((shownChat.readStartedAdmissions + [row.admissionID]).suffix(8))
        }
        // One the last read listed, that nothing holds and is now neither waiting
        // nor running, ran and ended between reads or was withdrawn: the chat's
        // stored rows tell which. Not while a turn runs there: its words drawn in
        // above may not be stored yet, and the turn's end reads the chat anyway.
        if queuedMessageLeftUnrun(work, previous: previous) {
            settled = true
        }
        // No turn runs there: no unnamed start is still to come.
        if !work.running {
            for admissionID in shownChat.readStartedAdmissions where ours(admissionID) {
                shownChat.forwardedSendChats.removeValue(forKey: admissionID)
            }
            shownChat.readStartedAdmissions.removeAll(where: ours)
            shownChat.otherAppStartsSeen.removeAll()
        }
        let held = authorityQueue.sessionID == chatID
            ? authorityQueue.rows.filter { !waiting.contains($0.admissionID) && shownChat.queuedSendOrder.contains($0.admissionID) }
            : []
        authorityQueue.apply(work.queued + held, for: chatID, readOnly: true)
        // Its rows are stored now: the chat shows what the turn did.
        if (previous?.running == true && !work.running) || settled, !isBusy {
            Task { await refreshActiveSession() }
        }
    }

    /// A message the last read listed, that nothing here holds, is now
    /// neither waiting nor running, and no turn runs there: it ran and ended
    /// between reads or was withdrawn, so the chat is read again (#3415).
    func queuedMessageLeftUnrun(_ work: ChatLiveWork, previous: ChatLiveWork?) -> Bool {
        guard !work.running, let previous else { return false }
        let waiting = Set(work.queued.map(\.admissionID))
        return previous.queued.contains { !waiting.contains($0.admissionID)
            && !work.startedAdmissions.contains($0.admissionID)
            && !shownChat.queuedSendOrder.contains($0.admissionID) }
    }

    /// A send `hermes dashboard` handed to the gateway's queue, behind a
    /// turn running there (its receipt says `forwarded`): the bubble waits
    /// in the dock until its turn starts, as on the gateway's own listener,
    /// where the plugin's reads keep it (Eric, 2026-11-27).
    func holdForwardedSend(rowID: String, text: String, sessionID: String) {
        guard let admissionID = HermesClient.admittedAdmissionID(for: sessionID) else { return }
        holdForwardedSend(admissionID: admissionID, rowID: rowID, text: text, sessionID: sessionID)
    }

    func holdForwardedSend(admissionID: String, rowID: String, text: String, sessionID: String) {
        guard let chatID = activeSessionId,
              chatID == sessionID || knownSessionIDs(for: sessionID).contains(chatID),
              !shownChat.startedAdmissionIDs.contains(admissionID) else { return }
        if shownChat.forwardedSendTimes.count >= 32 {
            // Only sends no longer held, nor awaiting their own start, let go of their stamps.
            let held = Set(shownChat.queuedSendOrder + shownChat.readStartedAdmissions)
            shownChat.forwardedSendTimes = shownChat.forwardedSendTimes.filter { held.contains($0.key) }
            shownChat.forwardedSendChats = shownChat.forwardedSendChats.filter { held.contains($0.key) }
        }
        shownChat.forwardedSendTimes[admissionID] = Date()
        shownChat.forwardedSendChats[admissionID] = chatID
        if let index = messages.firstIndex(where: { $0.id == rowID }) {
            holdQueuedSendRow(messages.remove(at: index), admissionID: admissionID)
            cacheMessagePresentation()
        }
        guard authorityQueue.row(admissionID) == nil else { return }
        let rows = authorityQueue.sessionID == chatID ? authorityQueue.rows : []
        let row = QueuedPrompt(admissionID: admissionID, text: text, status: .queued,
                               sequence: (rows.map(\.sequence).max() ?? 0) + 1)
        authorityQueue.apply(rows + [row], for: chatID, readOnly: true)
    }

    /// The queued message a `message.start` begins: the one Hermes names on
    /// its own listener, else, on `hermes dashboard`, the oldest of the
    /// user's forwarded ones into that chat (the dashboard relays only a
    /// forwarded message's own turn, without naming it).
    func admissionStarting(named admissionID: String?, by client: HermesClient?, in sessionID: String?) -> String? {
        if let admissionID { return admissionID }
        guard let client, !client.speaksSessionAuthority, authorityQueue.readOnly else { return nil }
        return forwardedSendStarting(in: sessionID)
    }

    /// The forwarded send an unnamed `message.start` in `sessionID` begins:
    /// one a read already brought back (its start is its own), else the
    /// oldest held, unless the last read listed another app's message ahead
    /// of it. Only sends forwarded into that chat: another chat's waiting
    /// send, or a held row no forward recorded, is never this start.
    func forwardedSendStarting(in sessionID: String?) -> String? {
        guard let sessionID else { return nil }
        // The chat by any of its own ids (a compacted chat's turn may start under
        // another), never one another chat owns or carries too (issue 2602).
        let known = followedSessionIDs(for: sessionID)
        let into: (String) -> Bool = { self.shownChat.forwardedSendChats[$0].map(known.contains) ?? false }
        if let index = shownChat.readStartedAdmissions.firstIndex(where: into) {
            let admissionID = shownChat.readStartedAdmissions.remove(at: index)
            shownChat.forwardedSendChats.removeValue(forKey: admissionID)
            return admissionID
        }
        let othersAhead = { (before: Int?) -> QueuedPrompt? in
            guard let queue = self.authorityQueue.sessionID, known.contains(queue) else { return nil }
            return self.authorityQueue.queued
                .filter { row in before.map { row.sequence < $0 } ?? true
                    && !self.shownChat.queuedSendOrder.contains(row.admissionID)
                    && self.shownChat.forwardedSendChats[row.admissionID] == nil
                    && !self.shownChat.otherAppStartsSeen.contains(row.admissionID) }
                .min { $0.sequence < $1.sequence }
        }
        guard let admissionID = shownChat.queuedSendOrder.first(where: into) else {
            // Nothing held: the start is the oldest message another app queued
            // there, so a send held after it, and the read that brings its words
            // in, don't wait for its start again (#3444).
            if let ahead = othersAhead(nil) {
                shownChat.otherAppStartsSeen = Array((shownChat.otherAppStartsSeen + [ahead.admissionID]).suffix(8))
            }
            return nil
        }
        // The last read listed a message nothing here holds ahead of it
        // (another app's): the gateway starts that one first, so this start
        // is its turn, not this send's. The next read brings its words in
        // and names this send's start when it comes (#3420).
        if let mine = authorityQueue.row(admissionID), let ahead = othersAhead(mine.sequence) {
            shownChat.otherAppStartsSeen = Array((shownChat.otherAppStartsSeen + [ahead.admissionID]).suffix(8))
            return nil
        }
        shownChat.forwardedSendTimes.removeValue(forKey: admissionID)
        shownChat.forwardedSendChats.removeValue(forKey: admissionID)
        return admissionID
    }
}
