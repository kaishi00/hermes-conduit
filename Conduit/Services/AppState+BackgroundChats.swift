//
//  AppState+BackgroundChats.swift
//  Conduit
//
//  A chat left while its reply was still coming keeps following that reply
//  (all-live stage 2, BackgroundChat.swift): its rows grow as the reply
//  streams on the shared socket, and going back to it shows them at once.
//

import Foundation

extension AppState {
    /// The chat on screen is being left for `newID` (setActiveSessionState).
    /// While its reply is still coming, its rows and the reply so far are
    /// kept and follow the rest of the reply. A chat being opened stops
    /// being followed: its own transcript takes over.
    func followLeftChatIfItsReplyRuns(leaving oldID: String?, for newID: String?) {
        guard let oldID, let newID, oldID != newID else { return }
        backgroundChats.removeAll { $0.answers(to: newID) }
        let ids = knownSessionIDs(for: oldID).union([oldID])
        guard !ids.contains(newID),
              isConnected,
              turnState == .running || !shownChat.streamingBuffer.isEmpty,
              offlineChatPresentation == nil,
              activeRoomSurface == nil,
              !messages.isEmpty || !shownChat.streamingBuffer.isEmpty,
              let dashboardID = activeDashboardID else { return }
        let listed = (sessions + cronSessions).first { session in
            ids.contains(session.id)
                || session.storedSessionId.map(ids.contains) == true
                || !ids.isDisjoint(with: session.alternateIds)
        }
        let isBotChat = botStoreProfile(forSessionIDs: Array(ids)) != nil
            || botConversationProfile(for: oldID) != nil
        let chat = BackgroundChat(
            sessionIDs: ids.union(listed?.nestingIDs ?? []),
            durableSessionID: isBotChat ? nil : listed.map { $0.storedSessionId ?? $0.id },
            title: activeSessionTitle,
            dashboardID: dashboardID,
            profile: activeProfile,
            isBotChat: isBotChat,
            rows: messages,
            streamingText: shownChat.streamingBuffer
        )
        backgroundChats = BackgroundChat.adding(chat, to: currentBackgroundChats())
    }

    /// The followed chats of the dashboard and profile on screen; the rest
    /// are let go.
    func currentBackgroundChats() -> [BackgroundChat] {
        backgroundChats.filter { $0.dashboardID == activeDashboardID && $0.profile == activeProfile }
    }

    /// Applies a stream event of a chat that was left mid-reply. True when
    /// the event was that chat's, so nothing else takes it: not the chat
    /// on screen, and not an open reconcile, which accepts any chat's
    /// events until it knows its own.
    func applyBackgroundChatEvent(_ event: StreamEvent) -> Bool {
        guard !backgroundChats.isEmpty else { return false }
        let id = sessionID(for: event)
        guard !id.isEmpty, !eventBelongsToActiveSession(id),
              let index = backgroundChats.firstIndex(where: { $0.answers(to: id) }) else { return false }
        guard backgroundChats[index].dashboardID == activeDashboardID,
              backgroundChats[index].profile == activeProfile else {
            backgroundChats.remove(at: index)
            return false
        }
        if backgroundChats[index].apply(event) == .ended {
            saveBackgroundChatCopy(backgroundChats[index])
        }
        return true
    }

    /// A finished reply's rows become the chat's saved copy, so it shows
    /// even once the chat is no longer followed. A Bot Chat keeps no copy
    /// on the phone (`keepBotChatCopy`), and the copy doesn't become the one
    /// a cold launch shows first.
    private func saveBackgroundChatCopy(_ chat: BackgroundChat) {
        guard !chat.isBotChat, let durableSessionID = chat.durableSessionID else { return }
        offlineChatCache.record(
            dashboardID: chat.dashboardID,
            profile: chat.profile,
            sessionID: durableSessionID,
            identities: chat.sessionIDs,
            title: chat.title,
            messages: chat.rows,
            sessions: sessions,
            becomesLastOpened: false
        )
    }

    /// The followed chat a chat being opened is, taken off the list.
    func takeBackgroundChat(answering ids: Set<String>) -> BackgroundChat? {
        guard let index = backgroundChats.firstIndex(where: { !$0.sessionIDs.isDisjoint(with: ids) }) else {
            return nil
        }
        return backgroundChats.remove(at: index)
    }

    /// Shows a followed chat's rows while it opens, as a saved copy shows
    /// (#1352): Hermes' rows replace them once they land. False when there
    /// is nothing to show here, so the open shows its saved copy instead.
    func presentBackgroundChat(_ chat: BackgroundChat, openedAs sessionID: String) -> Bool {
        guard chat.dashboardID == activeDashboardID,
              chat.profile == activeProfile,
              messages.isEmpty else { return false }
        let rows = OfflineChatCacheStore.keptRows(of: chat.rows)
        guard !rows.isEmpty else { return false }
        // Under the id the chat's saved copy and draft are kept by: a Bot
        // Chat's own id, as its kept copy is shown (presentKeptBotChatCopy).
        let durableSessionID = chat.durableSessionID ?? sessionID
        offlineChatPresentation = OfflineChatPresentation(
            dashboardID: chat.dashboardID,
            profile: chat.profile,
            snapshot: OfflineChatSnapshot(lastSessionID: nil, sessions: [], transcripts: []),
            displayedTranscript: OfflineCachedTranscript(
                sessionID: durableSessionID,
                title: chat.title,
                savedAt: Date(),
                messages: rows
            ),
            picked: OfflineChatPresentation.PickedChat(
                title: chat.title,
                sessionIDs: chat.sessionIDs.union([sessionID]),
                durableSessionID: durableSessionID
            )
        )
        return true
    }
}
