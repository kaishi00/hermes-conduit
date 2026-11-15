//
//  AppState+KeptChatSend.swift
//  Conduit
//
//  Writing in a chat kept beside the open one, or in a chat window (all-live
//  stage 2). A plain message, sent to the chat's own session by id as a
//  voice job's request is; its reply follows into the chat's own state
//  through the events Hermes sends for it (AppState+BackgroundChats.swift).
//  Anything richer, attachments, a slash command, an answer to a card,
//  stays with the chat's own column: Swap or Open in Main Window.
//

import Foundation

extension AppState {
    /// Whether `chat` takes a message here now: connected, on the profile
    /// on screen, and between turns.
    func canSendInKeptChat(_ chat: BackgroundChat) -> Bool {
        isConnected && client != nil && !chat.isRunning
            && chat.dashboardID == activeDashboardID && chat.profile == activeProfile
            && keptChatIDs.map { !chat.sessionIDs.isDisjoint(with: $0) } == true
    }

    /// The id the chat's turns run under on this connection: the runtime id
    /// Hermes bound it to, else the id it was left as. An id Hermes has
    /// since bound to another chat is never a target: nil sends nothing.
    func keptChatSendTarget(_ chat: BackgroundChat) -> String? {
        let index = conversationIdentityIndex
        func isThisChat(_ durable: String) -> Bool {
            chat.sessionIDs.contains(durable) || chat.durableSessionID == durable
        }
        var runtime: String?
        var free: [String] = []
        for id in chat.sessionIDs.sorted() {
            guard let durable = index.durableID(forRuntime: id, profile: chat.profile) else {
                free.append(id)
                continue
            }
            guard isThisChat(durable) else { continue }
            if durable != id, runtime == nil { runtime = id } else { free.append(id) }
        }
        return runtime
            ?? free.first { $0 != chat.durableSessionID }
            ?? free.first
    }

    /// Sends `text` to the kept chat. The message shows in it at once and
    /// its reply follows there. False when it didn't go: the message comes
    /// off the chat, the turn isn't running, and the box keeps the words.
    @discardableResult
    func sendInKeptChat(_ chat: BackgroundChat, text: String) async -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, canSendInKeptChat(chat), let client,
              let target = keptChatSendTarget(chat) else { return false }
        let rowID = "user-kept-\(UUID().uuidString)"
        chat.state.messages.append(ChatMessage(
            id: rowID, role: .user, content: words, timestamp: Self.localTimestamp(), author: nil
        ))
        act(on: chat) { setRunning(true) }
        besideChatLive.moved()
        do {
            _ = try await client.sendPrompt(target, text: words)
            return true
        } catch {
            // A send that timed out after Hermes took it: its echo gave the
            // row Hermes' id, or the reply has started under it. Keep both.
            if let at = chat.state.messages.firstIndex(where: { $0.id == rowID }),
               chat.state.messages[at].rowId != nil || at < chat.state.messages.count - 1 {
                return true
            }
            chat.state.messages.removeAll { $0.id == rowID }
            act(on: chat) { setRunning(false) }
            besideChatLive.moved()
            return false
        }
    }
}
