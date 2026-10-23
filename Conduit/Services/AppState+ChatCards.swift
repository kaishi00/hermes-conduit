//
//  AppState+ChatCards.swift
//  Conduit
//
//  Feeds the open chat's plan card (ChatCardsModel): which
//  chat is open, and its transcript as it changes.
//

import Foundation

extension AppState {
    /// The open chat, by every id it is known by; nil when no chat with a
    /// row of its own is open (a New Chat on its way).
    func chatCardsChat(including extra: [String?] = []) -> ChatCardsChat? {
        guard let active = activeSessionId, !active.isEmpty else { return nil }
        let identity = activeChatScrollSessionIdentity
        let ids: [String?] = [active, identity.canonicalSessionID]
            + identity.equivalentSessionIDs.map { Optional($0) } + extra
        return ChatCardsChat(profile: activeProfile, ids: ids)
    }

    /// The cards don't show over the saved copy or a New Chat on its way,
    /// which aren't the transcript they're read from.
    var showsChatCards: Bool {
        !showsOfflineChatCopy && !showsPendingNewChat
    }

    /// Hands the cards the transcript on screen.
    func refreshChatCards() {
        chatCards.transcriptChanged(messages, for: chatCardsChat())
    }
}
