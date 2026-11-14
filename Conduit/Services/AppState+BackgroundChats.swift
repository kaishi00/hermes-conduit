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
        // The same conversation under a new runtime id (a resume or a
        // voice thread's rebind) isn't a chat being left.
        guard !isSameConversation(ids, as: newID) else { return }
        followChatOnScreen(answering: ids, openAs: oldID)
    }

    /// A profile switch leaves the chat on screen for the target profile's.
    /// Called before the profile changes, so the chat is followed under the
    /// profile it belongs to.
    func followChatLeftForProfileSwitch() {
        guard let oldID = activeSessionId else { return }
        followChatOnScreen(answering: knownSessionIDs(for: oldID).union([oldID]), openAs: oldID)
    }

    private func isSameConversation(_ ids: Set<String>, as newID: String) -> Bool {
        if ids.contains(newID) { return true }
        let index = conversationIdentityIndex
        let profile = activeProfile
        let durableIDs = Set(ids.compactMap { index.durableID(forRuntime: $0, profile: profile) })
        if durableIDs.contains(newID) { return true }
        guard let newDurableID = index.durableID(forRuntime: newID, profile: profile) else { return false }
        return durableIDs.contains(newDurableID) || ids.contains(newDurableID)
    }

    private func followChatOnScreen(answering ids: Set<String>, openAs oldID: String) {
        guard isConnected,
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

    /// The followed chats of the dashboard on screen, any of its profiles
    /// (a profile switch leaves one); other dashboards' are let go.
    func currentBackgroundChats() -> [BackgroundChat] {
        backgroundChats.filter { $0.dashboardID == activeDashboardID }
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
        guard backgroundChats[index].dashboardID == activeDashboardID else {
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
            // The list on screen is another scope's when the chat was left
            // by a profile switch: the copy then keeps its scope's own list.
            sessions: chat.profile == activeProfile ? sessions : [],
            becomesLastOpened: false
        )
    }

    /// Stops following the chats on `dashboardID` (every dashboard when
    /// nil) that answer to any of `sessionIDs` (all of them when nil): a
    /// deleted chat, a removed dashboard, a sign-out, Delete saved chats. Its
    /// reply's end then saves nothing.
    func stopFollowingChats(dashboardID: UUID?, sessionIDs: Set<String>? = nil) {
        backgroundChats.removeAll { chat in
            (dashboardID == nil || chat.dashboardID == dashboardID)
                && sessionIDs.map { !chat.sessionIDs.isDisjoint(with: $0) } != false
        }
    }

    /// The followed chat a chat being opened is, taken off the list.
    func takeBackgroundChat(answering ids: Set<String>) -> BackgroundChat? {
        guard let index = backgroundChats.firstIndex(where: {
            $0.profile == activeProfile && !$0.sessionIDs.isDisjoint(with: ids)
        }) else {
            return nil
        }
        return backgroundChats.remove(at: index)
    }

    /// An open that took a followed chat and then didn't land (another open
    /// took over, or it failed) puts it back, so the reply goes on being
    /// followed. Not when the chat is on screen again or followed anew.
    func putBackBackgroundChat(_ chat: BackgroundChat) {
        guard chat.isRunning,
              chat.dashboardID == activeDashboardID,
              activeSessionId.map { chat.answers(to: $0) } != true,
              !backgroundChats.contains(where: { !$0.sessionIDs.isDisjoint(with: chat.sessionIDs) }) else { return }
        backgroundChats = BackgroundChat.adding(chat, to: currentBackgroundChats())
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
