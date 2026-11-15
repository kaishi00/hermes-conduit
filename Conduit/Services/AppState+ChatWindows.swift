//
//  AppState+ChatWindows.swift
//  Conduit
//
//  A chat in a window of its own, on an iPad and a Mac (all-live stage 2).
//  The window shows a chat as the pane beside the open chat does
//  (AppState+BesideChat.swift): a followed copy with its own ChatState,
//  live from the events Hermes sends for it. A chat gets there from the
//  pane, so it has been on screen in this connection and Hermes streams
//  its turns here. The window only shows; Open in Main Window brings the
//  chat back to the chat's own column to write in.
//

import Foundation

extension AppState {
    /// How many chats have windows of their own at once.
    static let chatWindowLimit = 3

    /// Every id of a chat on show away from the chat's own column: the
    /// pane's and each window's. Those chats stay followed with no reply
    /// running. Nil with none.
    var keptChatIDs: Set<String>? {
        let all = windowChatIDs.reduce(besideChatIDs ?? []) { $0.union($1) }
        return all.isEmpty ? nil : all
    }

    /// The chat on show in the pane or a window that answers to
    /// `sessionID`, of this dashboard and profile.
    func keptChat(answering sessionID: String) -> BackgroundChat? {
        guard let kept = keptChatIDs else { return nil }
        return backgroundChats.first {
            $0.dashboardID == activeDashboardID && $0.profile == activeProfile
                && $0.answers(to: sessionID) && !$0.sessionIDs.isDisjoint(with: kept)
        }
    }

    /// The chat the window opened as `key` draws. Nil once its chat is
    /// followed no longer, or after a relaunch: the window closes.
    func windowChat(_ key: String) -> BackgroundChat? {
        guard let ids = windowChatIDs.first(where: { $0.contains(key) }) else { return nil }
        return backgroundChats.first {
            $0.dashboardID == activeDashboardID && $0.profile == activeProfile
                && !$0.sessionIDs.isDisjoint(with: ids)
        }
    }

    /// Whether the pane's chat can move to a window of its own.
    var canMoveBesideChatToWindow: Bool {
        besideChat != nil && windowChatIDs.count < Self.chatWindowLimit
    }

    /// Hands the pane's chat to a window: the pane closes, and the chat
    /// goes on being followed. Returns what the window opens as.
    func moveBesideChatToWindow() -> String? {
        guard canMoveBesideChatToWindow, let chat = besideChat, let ids = besideChatIDs,
              let key = chat.durableSessionID ?? chat.sessionIDs.sorted().first else { return nil }
        windowChatIDs.append(ids.union(chat.sessionIDs))
        besideChatIDs = nil
        return key
    }

    /// The window opened as `key` closed. Its chat goes on being followed
    /// only while a reply still runs in it.
    func closeChatWindow(_ key: String) {
        guard let index = windowChatIDs.firstIndex(where: { $0.contains(key) }) else { return }
        let ids = windowChatIDs.remove(at: index)
        letGoOfIdleFollowedChat(answering: ids)
    }

    /// Opens a window's chat in the chat's own column, where it can be
    /// written to. Landing there lets go of the followed copy, and the
    /// window closes.
    func openWindowChatInMainWindow(_ key: String) {
        guard let chat = windowChat(key),
              let target = chat.durableSessionID ?? chat.sessionIDs.sorted().first else { return }
        requestOpenSession(target)
    }

    /// A profile or dashboard switch: the pane and every chat window
    /// close. The chats there are the outgoing one's.
    func closeKeptChats() {
        closeBesideChat()
        let windows = windowChatIDs
        guard !windows.isEmpty else { return }
        windowChatIDs = []
        for ids in windows { letGoOfIdleFollowedChat(answering: ids) }
    }

    /// A window closes once its chat is followed no longer: opened in the
    /// chat's own column, or deleted.
    func closeChatWindowsWithoutTheirChats() {
        let live = windowChatIDs.filter { ids in
            backgroundChats.contains { !$0.sessionIDs.isDisjoint(with: ids) }
        }
        if live.count != windowChatIDs.count { windowChatIDs = live }
    }
}
