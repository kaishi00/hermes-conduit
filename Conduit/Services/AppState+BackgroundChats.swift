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
    /// kept and follow the rest of the reply. A chat being opened stays
    /// followed until its open lands (releaseFollowedChat), so an open that
    /// fails or is overtaken leaves it followed.
    func followLeftChatIfItsReplyRuns(leaving oldID: String?, for newID: String?) {
        guard let oldID, let newID, oldID != newID else { return }
        let ids = knownSessionIDs(for: oldID).union([oldID])
        // The same conversation under a new runtime id (a resume or a
        // voice thread's rebind) isn't a chat being left.
        guard !isSameConversation(ids, as: newID) else { return }
        followChatOnScreen(answering: ids, openAs: oldID, turnRunning: turnState == .running)
    }

    /// A profile switch leaves the chat on screen for the target profile's.
    /// Called before the profile changes, so the chat is followed under the
    /// profile it belongs to. The switch has already set the turn to
    /// synchronizing, so it says whether the chat's turn was running.
    func followChatLeftForProfileSwitch(turnWasRunning: Bool) {
        guard let oldID = activeSessionId else { return }
        followChatOnScreen(answering: knownSessionIDs(for: oldID).union([oldID]), openAs: oldID, turnRunning: turnWasRunning)
    }

    /// The chat a profile switch opens on, when it's one a switch left
    /// mid-reply: its rows and the reply so far show. It stays followed
    /// until the switch lands (releaseFollowedChatOnScreen), so a switch
    /// that fails or that a newer navigation overtakes leaves it followed.
    /// False when it isn't one.
    func presentFollowedChatAfterProfileChange(_ sessionID: String) -> Bool {
        // Only a switch that shows a followed copy has one to release; an
        // earlier switch that never landed leaves none behind.
        followedChatShownBySwitch = nil
        guard let left = followedChat(answering: knownSessionIDs(for: sessionID).union([sessionID])) else {
            return false
        }
        // Released by its own ids: the switch's resume can move the chat on
        // screen to a runtime id the entry never knew.
        followedChatShownBySwitch = left.sessionIDs
        return presentBackgroundChat(left, openedAs: sessionID)
    }

    /// The chat a profile switch showed from a followed copy, once the
    /// switch lands on it, is followed no longer: its own transcript has
    /// taken over.
    func releaseFollowedChatOnScreen() {
        guard let ids = followedChatShownBySwitch else { return }
        followedChatShownBySwitch = nil
        releaseFollowedChat(answering: ids)
    }

    /// The followed chat of this dashboard and profile that answers to any
    /// of `ids`, left on the list: an open shows it while it loads.
    func followedChat(answering ids: Set<String>) -> BackgroundChat? {
        backgroundChats.first {
            $0.dashboardID == activeDashboardID && $0.profile == activeProfile
                && !$0.sessionIDs.isDisjoint(with: ids)
        }
    }

    /// The chat an open (or a switch) landed on is followed no longer.
    func releaseFollowedChat(answering ids: Set<String>) {
        backgroundChats.removeAll {
            $0.dashboardID == activeDashboardID && $0.profile == activeProfile
                && !$0.sessionIDs.isDisjoint(with: ids)
        }
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

    private func followChatOnScreen(answering ids: Set<String>, openAs oldID: String, turnRunning: Bool) {
        guard isConnected,
              turnRunning || !shownChat.streamingBuffer.isEmpty,
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
    /// events until it knows its own. A followed chat that is on screen
    /// again (its open hasn't landed yet) takes its events too, so it's
    /// current if the open is overtaken, and the screen still gets them.
    func applyBackgroundChatEvent(_ event: StreamEvent) -> Bool {
        guard !backgroundChats.isEmpty else { return false }
        let id = sessionID(for: event)
        guard !id.isEmpty,
              let index = backgroundChats.firstIndex(where: { $0.answers(to: id) }) else { return false }
        if eventBelongsToActiveSession(id) {
            // The chat on screen saves its own copy.
            _ = backgroundChats[index].apply(event)
            return false
        }
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
