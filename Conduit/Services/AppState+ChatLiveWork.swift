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
        guard activeSessionId == chatID, client?.speaksSessionAuthority != true else { return }
        let waiting = Set(work.queued.map(\.admissionID))
        // A send held after the read was asked isn't in it yet: it keeps its row.
        let newer = { (admissionID: String) in
            (self.shownChat.forwardedSendTimes[admissionID] ?? .distantPast) > work.askedAt
        }
        var settled = false
        for admissionID in shownChat.queuedSendOrder where !waiting.contains(admissionID) && !newer(admissionID) {
            shownChat.forwardedSendTimes.removeValue(forKey: admissionID)
            if work.startedAdmissions.contains(admissionID) {
                // Its turn runs there now; the unnamed start still to come is its own.
                noteQueuedTurnStarted(sessionID: chatID, admissionID: admissionID)
                shownChat.readStartedAdmissions = Array((shownChat.readStartedAdmissions + [admissionID]).suffix(8))
            } else {
                // It ran and ended between reads, or was withdrawn in the Webapp
                // or Hermes Desktop: the chat's stored rows tell which.
                _ = takeQueuedSendRow(admissionID: admissionID)
                authorityQueue.drop(admissionID)
                settled = true
            }
        }
        // No turn runs there: no unnamed start is still to come.
        if !work.running { shownChat.readStartedAdmissions = [] }
        let held = authorityQueue.sessionID == chatID
            ? authorityQueue.rows.filter { !waiting.contains($0.admissionID) && shownChat.queuedSendOrder.contains($0.admissionID) }
            : []
        authorityQueue.apply(work.queued + held, for: chatID, readOnly: true)
        // Its rows are stored now: the chat shows what the turn did.
        if (previous?.running == true && !work.running) || settled, !isBusy {
            Task { await refreshActiveSession() }
        }
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
            // Only sends no longer held let go of their stamps.
            let held = Set(shownChat.queuedSendOrder)
            shownChat.forwardedSendTimes = shownChat.forwardedSendTimes.filter { held.contains($0.key) }
        }
        shownChat.forwardedSendTimes[admissionID] = Date()
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
    /// user's forwarded ones (the dashboard relays only a forwarded
    /// message's own turn, without naming it).
    func admissionStarting(named admissionID: String?, by client: HermesClient?) -> String? {
        if let admissionID { return admissionID }
        guard let client, !client.speaksSessionAuthority, authorityQueue.readOnly else { return nil }
        return forwardedSendStarting()
    }

    /// The forwarded send an unnamed `message.start` begins: one a read
    /// already brought back (its start is its own), else the oldest held.
    func forwardedSendStarting() -> String? {
        if !shownChat.readStartedAdmissions.isEmpty { return shownChat.readStartedAdmissions.removeFirst() }
        return shownChat.queuedSendOrder.first
    }
}
