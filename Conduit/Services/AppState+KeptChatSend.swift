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

import SwiftUI
import UIKit

extension AppState {
    /// Whether `chat` takes a message here now: connected, on the profile
    /// on screen, and between turns.
    func canSendInKeptChat(_ chat: BackgroundChat) -> Bool {
        isConnected && client != nil && !chat.isRunning
            && chat.dashboardID == activeDashboardID && chat.profile == activeProfile
            && keptChatIDs.map { !chat.sessionIDs.isDisjoint(with: $0) } == true
    }

    /// The id the chat's turns run under on this connection: the id its
    /// events came under last (a runtime id Hermes bound it to, here or on
    /// another device), else the runtime id it was left with, else the id
    /// it was left as. An id Hermes has since bound to another chat is
    /// never a target: nil sends nothing.
    func keptChatSendTarget(_ chat: BackgroundChat) -> String? {
        let index = conversationIdentityIndex
        func isThisChat(_ durable: String) -> Bool {
            chat.sessionIDs.contains(durable) || chat.durableSessionID == durable
        }
        if let latest = keptChatEventIDs[Self.keptChatKey(chat)],
           index.durableID(forRuntime: latest, profile: chat.profile).map(isThisChat)
               ?? chat.sessionIDs.contains(latest) {
            return latest
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

    /// Notes the id a kept chat's event came under, the one its next
    /// message goes to (`keptChatSendTarget`).
    func noteKeptChatEvent(_ chat: BackgroundChat, sessionID: String) {
        if keptChatEventIDs.count > 16 { keptChatEventIDs.removeAll() }
        keptChatEventIDs[Self.keptChatKey(chat)] = sessionID
    }

    nonisolated static func keptChatKey(_ chat: BackgroundChat) -> String {
        chat.durableSessionID ?? chat.sessionIDs.sorted().first ?? ""
    }

    /// Sends `text` to the kept chat as the chat's own composer sends a
    /// message: where it was sent from goes to the plugin first (#888), its
    /// turn gets a Live Activity (#605), and the message shows in the chat
    /// at once with its reply following there. False when it didn't go:
    /// the message comes off the chat, the turn isn't running, and the box
    /// keeps the words.
    @discardableResult
    func sendInKeptChat(_ chat: BackgroundChat, text: String) async -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, canSendInKeptChat(chat), let client,
              let target = keptChatSendTarget(chat) else { return false }
        // A reply still settling from the last turn is no word of this one.
        let replyWasSettled = chat.state.streamingBuffer.isEmpty
        let rowID = "user-kept-\(UUID().uuidString)"
        chat.state.messages.append(ChatMessage(
            id: rowID, role: .user, content: words, timestamp: Self.localTimestamp(), author: nil
        ))
        act(on: chat) { setRunning(true) }
        besideChatLive.moved()
        let ids = chat.sessionIDs.union([target])
        let reportedOn = activeDashboardID
        await reportTurnSurface(messageTurnSurface(spoken: false), runtimeSessionID: target, text: words)?.value
        LiveTurnActivities.shared?.turnSubmitting(sessionIDs: ids)
        // The client as of the send: a reconnect during the report replaced it.
        let sender = self.client ?? client
        do {
            let outcome: PromptSubmissionOutcome
            if let sendPrompt = chatResumeLifecycleOperations.sendPrompt {
                outcome = try await sendPrompt(sender, target, words)
            } else {
                outcome = try await sender.sendPrompt(target, text: words)
            }
            // Steered, redirected or queued: a turn was running there
            // already, so the message joined it and its card stands.
            guard outcome == .accepted else { return true }
            LiveTurnActivities.shared?.turnStarted(
                sessionIDs: ids,
                primaryID: target,
                linkID: chat.durableSessionID,
                title: chat.title,
                profile: chat.profile,
                glowHex: profileGlowColors()[chat.profile]?.hex
                    ?? profileGlowTint(chat.profile).flatMap { ProfileGlowRGB(UIColor($0).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))?.hex },
                dashboardID: chat.dashboardID.uuidString
            )
            return true
        } catch {
            // A send that failed after Hermes took it: its echo gave the row
            // Hermes' id, or its reply streams. Keep it. A row from
            // elsewhere landing after it (a job's post, another device's
            // message) is no word of this one.
            if let at = chat.state.messages.firstIndex(where: { $0.id == rowID }),
               chat.state.messages[at].rowId != nil
                || (replyWasSettled && !chat.state.streamingBuffer.isEmpty) {
                return true
            }
            discardTurnSurface(runtimeSessionID: target, text: words, after: error, reportedOn: reportedOn)
            chat.state.messages.removeAll { $0.id == rowID }
            act(on: chat) { setRunning(false) }
            besideChatLive.moved()
            return false
        }
    }
}
