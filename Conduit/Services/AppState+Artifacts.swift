//
//  AppState+Artifacts.swift
//  Conduit
//
//  The Artifacts screens: what a profile's chats produced, listed by the
//  host's notifier plugin, opened in the viewers chats already use, and
//  "Show in chat", which scrolls the chat to the message it came from.
//

import Foundation

/// A message to scroll to once its chat's transcript has it.
struct ArtifactReveal: Equatable {
    /// Hermes' `messages.id`.
    let messageID: Int
    /// The chat being opened for it; nil when it's in the open chat. Until
    /// that chat is the active one, the transcript is still the old chat's.
    let opening: String?
    let expires: Date

    init(messageID: Int, opening: String? = nil, now: Date = Date()) {
        self.messageID = messageID
        self.opening = opening
        // A chat that takes longer to open (or never shows the row, an old
        // part of a long history) doesn't jump later, out of nowhere.
        self.expires = now.addingTimeInterval(20)
    }

    /// The row to show: the message itself, else the last one before it (a
    /// tool call is split off its message and keeps no id of its own).
    static func rowID(for messageID: Int, in messages: [ChatMessage]) -> String? {
        var before: ChatMessage?
        for message in messages {
            guard let rowId = message.rowId else { continue }
            if rowId == messageID { return message.id }
            if rowId < messageID, rowId >= (before?.rowId ?? Int.min) { before = message }
        }
        return before?.id
    }
}

extension AppState {
    /// Whether the host's notifier plugin lists artifacts.
    var supportsArtifacts: Bool {
        notifierPlugin.reports(ArtifactsClient.capability)
    }

    var artifactsClient: ArtifactsClient {
        ArtifactsClient(request: { [weak self] path in
            guard let bridge = self?.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
            // A long history takes the host a moment to read.
            return try await bridge.requestJSON(path: path, timeoutMilliseconds: 30_000)
        })
    }

    /// Every id the open chat is known by, for its own Artifacts sheet.
    /// Empty when no chat with a row of its own is open (a room, a new chat).
    var activeChatArtifactSessionIDs: [String] {
        guard let session = activeChatSessionSummary else { return [] }
        let seeds = [session.id, session.storedSessionId].compactMap { $0 } + session.alternateIds
        return Array(chatOwnSessionIDs(for: session.id).union(seeds)).sorted()
    }

    /// Whether the transcript on screen is the chat a reveal waits for.
    func isShowingChat(for reveal: ArtifactReveal) -> Bool {
        guard let opening = reveal.opening else { return true }
        guard let active = activeSessionId, !active.isEmpty else { return false }
        return active == opening || chatOwnSessionIDs(for: active).contains(opening)
    }

    /// Opens the artifact's chat (unless it's the open one) and scrolls to
    /// the message it came from.
    func showArtifactInChat(_ item: ArtifactItem, chatIsOpen: Bool) {
        pendingArtifactReveal = ArtifactReveal(messageID: item.messageID, opening: chatIsOpen ? nil : item.sessionID)
        guard !chatIsOpen else { return }
        dismissSidebarDrawer()
        requestOpenSession(item.sessionID)
    }
}
