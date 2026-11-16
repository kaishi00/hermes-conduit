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

import SwiftUI

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
    /// `sessionID`, of this dashboard and profile: by its own ids, or by
    /// a runtime id Hermes has since bound to it (another device resumed
    /// it), as its reply's events find it.
    func keptChat(answering sessionID: String) -> BackgroundChat? {
        guard let kept = keptChatIDs,
              let index = backgroundChats.firstIndex(where: { $0.answers(to: sessionID) })
                ?? followedChatIndex(reboundTo: sessionID) else { return nil }
        let chat = backgroundChats[index]
        guard chat.dashboardID == activeDashboardID, chat.profile == activeProfile,
              !chat.sessionIDs.isDisjoint(with: kept) else { return nil }
        return chat
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
    /// written to, and shows it there, whatever the main window showed
    /// (Tasks, Settings, the list alone). Landing there lets go of the
    /// followed copy, and the window closes. True when no main window is
    /// open, so the caller opens one first: closing the chat window would
    /// otherwise leave nothing showing the chat.
    @discardableResult
    func openWindowChatInMainWindow(_ key: String) -> Bool {
        guard let chat = windowChat(key),
              let target = chat.durableSessionID ?? chat.sessionIDs.sorted().first else { return false }
        requestOpenSession(target)
        // Uncovering the chat pushes it in the shell (V2Shell's showSidebar).
        showSidebar = false
        let opensMainWindow = windowScenePhases[Self.mainWindowScene] == nil
        // The window that opens starts on the list unless told otherwise.
        mainWindowOpensChat = opensMainWindow
        return opensMainWindow
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

    /// The main window's scene key in `windowScenePhases`.
    static let mainWindowScene = "main"

    /// A window's scene phase changed, or a chat window closed (nil). The
    /// app's lifecycle (handleScenePhase) follows the most active of its
    /// windows: a chat window on screen keeps the connection and its chat
    /// live while the main window is behind it, and the app is in the
    /// background only once every window is. With the main window alone,
    /// its own phase, as before.
    func noteScenePhase(_ phase: ScenePhase?, scene: String) {
        if let phase {
            windowScenePhases[scene] = phase
        } else {
            windowScenePhases.removeValue(forKey: scene)
        }
        guard let merged = Self.mergedScenePhase(Array(windowScenePhases.values)),
              merged != mergedScenePhase else { return }
        mergedScenePhase = merged
        handleScenePhase(merged)
    }

    /// A window's phase from before any phase was handled (the main
    /// window's first frame at launch): counted with the others from now,
    /// without the steps a change runs. Its first change runs them, as it
    /// did before. Once a phase was handled, `noteScenePhase` instead.
    func countScenePhaseBeforeAnyHeard(_ phase: ScenePhase, scene: String) {
        guard mergedScenePhase == nil else {
            noteScenePhase(phase, scene: scene)
            return
        }
        windowScenePhases[scene] = phase
    }

    /// The most active of `phases`: active, then inactive, then background.
    nonisolated static func mergedScenePhase(_ phases: [ScenePhase]) -> ScenePhase? {
        if phases.contains(.active) { return .active }
        if phases.contains(.inactive) { return .inactive }
        return phases.isEmpty ? nil : .background
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
