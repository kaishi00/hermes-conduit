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
        guard let response = try? await owner.bridge.requestJSON(path: path), ownsDashboardRuntime(owner) else { return nil }
        return ChatLiveWork(response: response)
    }

    /// A read of the open chat's turn in the gateway: its queue into the
    /// dock (without buttons), the user's own waiting messages back into
    /// the chat once their turn has started, and the chat read again when
    /// the turn it followed there has ended.
    func applyChatLiveWork(_ work: ChatLiveWork, previous: ChatLiveWork?, for chatID: String) {
        guard activeSessionId == chatID, client?.speaksSessionAuthority != true else { return }
        authorityQueue.apply(work.queued, for: chatID, readOnly: true)
        // A message of the user's that left the queue started its turn there.
        let waiting = Set(work.queued.map(\.admissionID))
        for admissionID in shownChat.queuedSendOrder where !waiting.contains(admissionID) {
            noteQueuedTurnStarted(sessionID: chatID, admissionID: admissionID)
        }
        // Its rows are stored now: the chat shows what the turn did.
        if previous?.running == true, !work.running, !isBusy {
            Task { await refreshActiveSession() }
        }
    }

    /// A send `hermes dashboard` handed to the gateway's queue, behind a
    /// turn running there (its receipt says `forwarded`): the bubble waits
    /// in the dock until its turn starts, as on the gateway's own listener,
    /// where the plugin's reads keep it (Eric, 2026-11-27).
    func holdForwardedSend(rowID: String, text: String, sessionID: String) {
        guard let admissionID = HermesClient.admittedAdmissionID(for: sessionID),
              activeSessionId == sessionID || knownSessionIDs(for: sessionID).contains(activeSessionId ?? "") else { return }
        moveQueuedSendToDock(rowID: rowID, sessionID: sessionID)
        guard authorityQueue.row(admissionID) == nil else { return }
        let row = QueuedPrompt(admissionID: admissionID, text: text, status: .queued,
                               sequence: (authorityQueue.rows.map(\.sequence).max() ?? 0) + 1)
        let rows = authorityQueue.sessionID == activeSessionId ? authorityQueue.rows : []
        authorityQueue.apply(rows + [row], for: activeSessionId ?? sessionID, readOnly: true)
    }

    /// The queued message a `message.start` begins: the one Hermes names on
    /// its own listener, else, on `hermes dashboard`, the oldest of the
    /// user's forwarded ones (the dashboard relays only a forwarded
    /// message's own turn, without naming it).
    func admissionStarting(named admissionID: String?, by client: HermesClient?) -> String? {
        if let admissionID { return admissionID }
        guard let client, !client.speaksSessionAuthority, authorityQueue.readOnly else { return nil }
        return shownChat.queuedSendOrder.first
    }
}
