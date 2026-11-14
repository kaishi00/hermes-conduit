//
//  AppState+Reactions.swift
//  Conduit
//
//  Reacting to a message, the agent's reactions, and branching a new chat
//  from a reply. Moved out of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Reactions, and branching from a reply

    /// Which row a reaction on `message` addresses, or nil when it can't be
    /// addressed yet. A row with a durable id is always addressable. A live
    /// reply that hasn't been reloaded can only be named as "the newest
    /// assistant row", which is right only for the latest reply while no
    /// turn is writing newer rows.
    func reactionTarget(for message: ChatMessage) -> MessageReactionTarget? {
        Self.reactionTarget(
            for: message,
            isBusy: isBusy,
            latestAssistantMessageID: messages.last(where: { $0.role == .assistant })?.id
        )
    }

    /// Also how a chat row decides, from what it shows (ChatRowState).
    nonisolated static func reactionTarget(
        for message: ChatMessage,
        isBusy: Bool,
        latestAssistantMessageID: String?
    ) -> MessageReactionTarget? {
        guard message.role == .assistant else { return nil }
        if let rowId = message.rowId { return .row(rowId) }
        guard !isBusy, latestAssistantMessageID == message.id else { return nil }
        return .newest(role: "assistant")
    }

    /// Whether a reaction can be sent at all, whatever the message.
    var reactionsAvailable: Bool {
        offlineChatPresentation == nil
            && activeSessionId != nil
            && (client != nil || messageReactionSender != nil)
    }

    func canReact(to message: ChatMessage) -> Bool {
        reactionsAvailable
            && message.content.contains(where: { !$0.isWhitespace })
            && reactionTarget(for: message) != nil
    }

    /// Tapback on an agent reply: paints at once, then saves with
    /// `message.react` and adopts the server's list. Picking the reaction
    /// the user already has retracts it. A failed save puts the old list
    /// back and says why. Hermes passes the reaction to the agent with the
    /// next message, so nothing is sent now.
    func react(to messageId: String, with emoji: String) async {
        guard let sessionId = activeSessionId,
              let index = messages.firstIndex(where: { $0.id == messageId }),
              canReact(to: messages[index]),
              let target = reactionTarget(for: messages[index]) else { return }
        let previous = messages[index].reactions
        // A replaced reaction keeps its chip's place while it saves.
        let picked = MessageReaction.applying(
            emoji,
            author: MessageReaction.userAuthor,
            to: previous
        ).first(where: \.isFromUser)
        messages[index].reactions = Self.reactions(previous, withUserReaction: picked)
        shownChat.lastReactionRequestGeneration += 1
        let generation = shownChat.lastReactionRequestGeneration
        shownChat.reactionRequestGenerations[messageId] = generation
        defer {
            if shownChat.reactionRequestGenerations[messageId] == generation {
                shownChat.reactionRequestGenerations[messageId] = nil
            }
        }
        Haptics.light()

        do {
            let result: MessageReactionResult
            if let sender = messageReactionSender {
                result = try await sender(sessionId, target, emoji)
            } else if let client {
                result = try await client.reactToMessage(sessionId: sessionId, target: target, emoji: emoji)
            } else {
                throw HermesError.notConnected
            }
            guard activeSessionId == sessionId,
                  shownChat.reactionRequestGenerations[messageId] == generation,
                  let current = messages.firstIndex(where: { $0.id == messageId }) else { return }
            // "Newest assistant row" is resolved when Hermes handles the
            // call. The result belongs to this reply when the reply has
            // since learned that same row id, or is still the newest reply
            // with no turn writing newer rows. Otherwise the save may have
            // landed on a newer row, so this reply drops the pick it can't
            // confirm and the next reload paints the truth.
            if case .newest = target {
                let message = messages[current]
                let confirmed = message.rowId.map { $0 == result.rowId }
                    ?? (!isBusy && messages.last(where: { $0.role == .assistant })?.id == message.id)
                if !confirmed {
                    messages[current].reactions = Self.reactions(
                        message.reactions,
                        withUserReaction: previous.first(where: \.isFromUser)
                    )
                    return
                }
            }
            messages[current].rowId = result.rowId
            messages[current].reactions = result.reactions
        } catch {
            guard activeSessionId == sessionId,
                  shownChat.reactionRequestGenerations[messageId] == generation,
                  let current = messages.firstIndex(where: { $0.id == messageId }) else { return }
            // Put back only the user's own reaction: an agent reaction that
            // arrived during the call stays.
            messages[current].reactions = Self.reactions(
                messages[current].reactions,
                withUserReaction: previous.first(where: \.isFromUser)
            )
            errorMessage = AppLocalization.string("Your reaction wasn't saved. \(UserFacingError.message(for: error))")
        }
    }

    /// `reactions` with the user's entry replaced by `userReaction` (or
    /// removed when nil), keeping it where it sat in `reactions` if it did.
    static func reactions(
        _ reactions: [MessageReaction],
        withUserReaction userReaction: MessageReaction?
    ) -> [MessageReaction] {
        var result = reactions
        let index = result.firstIndex(where: \.isFromUser)
        result.removeAll(where: \.isFromUser)
        if let userReaction {
            result.insert(userReaction, at: min(index ?? result.count, result.count))
        }
        return result
    }

    /// The agent's `message.reaction` event, carrying the row's full
    /// reaction list. The row is matched by its durable id; a live row with
    /// no id yet is the newest row of the reacted role, which is the agent
    /// tool's default target, and learns its id so a later tapback
    /// addresses it directly. An unknown role only matches by id.
    func applyAgentReaction(rowId: Int, reactions: [MessageReaction], role: String) {
        if let index = messages.firstIndex(where: { $0.rowId == rowId }) {
            paintAgentReactions(reactions, at: index)
            return
        }
        let messageRole: MessageRole
        switch role {
        case "assistant": messageRole = .assistant
        case "user": messageRole = .user
        default: return
        }
        guard let index = messages.lastIndex(where: { $0.role == messageRole && $0.rowId == nil }) else { return }
        messages[index].rowId = rowId
        paintAgentReactions(reactions, at: index)
    }

    /// While the user's own tapback is still saving, the event's list can
    /// predate it: keep the user's pick until the save answers.
    private func paintAgentReactions(_ reactions: [MessageReaction], at index: Int) {
        let message = messages[index]
        messages[index].reactions = shownChat.reactionRequestGenerations[message.id] == nil
            ? reactions
            : Self.reactions(reactions, withUserReaction: message.reactions.first(where: \.isFromUser))
    }

    /// Forks only the history through the selected assistant response. The
    /// original conversation remains untouched; the new session becomes active
    /// and is resumed through the normal authoritative recovery path.
    func branchFromAssistantMessage(_ messageId: String) async {
        guard !isBusy, !isBranchingChat, !isProfileSwitching,
              let client,
              let parentSessionId = activeSessionId,
              let messageIndex = messages.firstIndex(where: { $0.id == messageId }),
              messages[messageIndex].role == .assistant else { return }

        let prefix = messages[...messageIndex].compactMap { message -> SessionBranchMessage? in
            guard message.role == .user || message.role == .assistant else { return nil }
            let content = (message.role == .user ? message.rawContent : nil) ?? message.content
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return SessionBranchMessage(
                role: message.role,
                content: trimmed,
                rowId: message.rowId,
                isNewest: message.id == messages.last?.id
            )
        }
        guard !prefix.isEmpty else {
            errorMessage = AppLocalization.string("There is no message history to branch from.")
            return
        }

        isBranchingChat = true
        defer { isBranchingChat = false }
        let previousTurnState = turnState
        let profile = activeProfile
        // A branch is made in its parent's profile: a Bot Chat's is the
        // bot's (issue 2281).
        let branchProfile = client.sessionProfile(for: parentSessionId) ?? presentationProfile(for: parentSessionId)
        turnState = .synchronizing
        let title = AppLocalization.string("Branch of \(activeSessionTitle)")
        let transitionGeneration = acceptChatResumeConversationReplacement(.branch)
        defer {
            cancelChatViewportTransitionIfNoReplacement(generation: transitionGeneration)
        }

        do {
            let branched: ChatResumeLifecycleOperations.BranchResult
            if let branchSession = chatResumeLifecycleOperations.branchSession {
                branched = try await branchSession(
                    client,
                    parentSessionId,
                    Array(prefix),
                    title,
                    runtime.cwd
                )
            } else {
                branched = try await client.branchSession(
                    parentSessionId: parentSessionId,
                    messages: Array(prefix),
                    title: title,
                    cwd: runtime.cwd
                )
            }
            guard chatViewportTransitionIsCurrent(generation: transitionGeneration),
                  profile == activeProfile,
                  self.client === client else { return }
            if let returnedProfile = branched.profile,
               !profilesMatch(returnedProfile, branchProfile) {
                turnState = previousTurnState
                errorMessage = AppLocalization.string("Hermes created this branch in \(profileDisplayName(returnedProfile)), not \(profileDisplayName(branchProfile)). It was not opened.")
                guard await loadSessions(
                    forceRefresh: true,
                    requiredViewportTransitionGeneration: transitionGeneration
                ), chatViewportTransitionIsCurrent(
                    generation: transitionGeneration
                ) else { return }
                return
            }
            if let setSessionTitle = chatResumeLifecycleOperations.setSessionTitle {
                try? await setSessionTitle(client, branched.sessionId, title)
            } else {
                try? await client.setSessionTitle(branched.sessionId, title: title)
            }
            guard chatViewportTransitionIsCurrent(generation: transitionGeneration),
                  profile == activeProfile,
                  self.client === client else { return }

            // Hermes' session.resume finds a conversation by its stored id
            // (or title), never by the runtime id session.create answered
            // with: resuming that one is "session not found" (issue 1400).
            // The stored id reattaches the live session the create made.
            let storedID = branched.storedSessionId.flatMap { $0.isEmpty ? nil : $0 }
                ?? branched.sessionId
            let summary = SessionSummary(
                id: storedID,
                alternateIds: [branched.sessionId].filter { $0 != storedID },
                title: title,
                model: runtime.model.isEmpty ? "Hermes" : runtime.model,
                updatedLabel: AppLocalization.string("now"),
                // Fresh activity, like the create path: a branch is the
                // newest conversation the moment it exists.
                lastActivityAt: Date().timeIntervalSince1970,
                profile: branchProfile,
                source: .chat,
                isActive: true,
                isArchived: false,
                lineageRootId: parentSessionId
            )
            // A branch is its own durable conversation: its response ids are
            // fresh authoritative evidence for the BRANCH only (adopted into
            // the catalog below). They must never alias the source
            // conversation, and the source keeps its own mappings.
            if let runtime = ChatScrollIdentityNormalization.sessionID(branched.sessionId),
               let durable = ChatScrollIdentityNormalization.sessionID(storedID),
               runtime != durable {
                conversationIdentityIndex.recordAuthoritative(
                    runtimeID: runtime,
                    durableID: durable,
                    profile: branchProfile,
                    source: .branch
                )
            }
            sessions = [summary] + sessions.map { existing in
                var updated = existing
                updated.isActive = false
                return updated
            }

            activeSessionTitle = title
            // The branch is another conversation: the parent's agents stay
            // with the parent.
            keepDelegateAgents(of: knownSessionIDs(for: branched.sessionId))
            let token = beginReconciliation()
            let reconciled = await reconcile(
                sessionId: storedID,
                using: client,
                token: token,
                acceptedSessionIDs: knownSessionIDs(for: storedID),
                conversationIdentity: captureConversationIdentity(for: storedID),
                requiredViewportTransitionGeneration: transitionGeneration,
                // A Bot Chat's branch resumes, reads its history and is
                // kept in the bot's profile, as its parent is.
                conversationProfile: profilesMatch(branchProfile, profile) ? nil : branchProfile
            )
            guard chatViewportTransitionIsCurrent(generation: transitionGeneration),
                  profile == activeProfile,
                  self.client === client else { return }
            let loadedFinalCatalog = await loadSessions(
                forceRefresh: false,
                requiredViewportTransitionGeneration: transitionGeneration
            )
            guard chatViewportTransitionIsCurrent(generation: transitionGeneration),
                  profile == activeProfile,
                  self.client === client else { return }
            if !reconciled {
                finishChatViewportTransition(generation: transitionGeneration)
                return
            }
            guard loadedFinalCatalog else { return }
        } catch {
            guard chatViewportTransitionIsCurrent(generation: transitionGeneration),
                  profile == activeProfile,
                  self.client === client else { return }
            turnState = previousTurnState
            errorMessage = AppLocalization.string("Could not branch conversation: \(UserFacingError.message(for: error))")
        }
    }
}
