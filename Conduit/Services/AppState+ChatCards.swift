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

    /// Hands the cards the transcript on screen, and in a workstream's
    /// chat its checklist, which is the plan that chat shows.
    func refreshChatCards() {
        let chat = chatCardsChat()
        chatCards.transcriptChanged(messages, for: chat)
        refreshWorkPlan(for: chat)
    }

    /// The open workstream's checklist as its chat's Tasks line. Only once
    /// the bot's work has been read: until then the chat isn't known to
    /// be a workstream's, and its first read isn't news.
    func refreshWorkPlan(for chat: ChatCardsChat? = nil) {
        // Resolved work, or work that left the bot's list, keeps no
        // checklist on its chat: a step left "doing" would read as still
        // under way (the Work panel draws a resolved row's stopped step as
        // not started, see checklistPlan).
        guard let workstream = activeWorkstream, !workstream.item.isClosed else {
            chatCards.clearWorkPlan()
            return
        }
        chatCards.applyWorkPlan(workstream.item.checklistPlan, for: chat ?? chatCardsChat())
    }
}
