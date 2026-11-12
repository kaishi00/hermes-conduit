//
//  AppState+ChatTakeover.swift
//  Conduit
//
//  Taking over a chat another device or the CLI is running, for a typed
//  send and for a call, and the message held while it waits. Moved out
//  of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Chat takeover

    static let chatTakeoverPollInterval: Duration = .seconds(3)

    /// How long Conduit waits for the other app's running turn to finish.
    static let chatTakeoverWaitLimit: TimeInterval = 15 * 60

    var takesOverChatsAutomatically: Bool {
        UserDefaults.standard.object(forKey: ChatTakeoverPreference.automaticKey) as? Bool
            ?? ChatTakeoverPreference.automaticDefault
    }

    /// The takeover for the open chat, matched on every id the chat goes by,
    /// so a runtime id rotated mid-takeover keeps the notice and the resend.
    var activeChatTakeover: ChatTakeoverState? {
        guard let active = activeSessionId, chatTakeoverMatches(active) else { return nil }
        return chatTakeover
    }

    /// Whether the takeover belongs to the chat `sessionID` names, by any of its ids.
    func chatTakeoverMatches(_ sessionID: String) -> Bool {
        guard let takeover = chatTakeover else { return false }
        let ids = Set(takeover.sessionIDs)
        if ids.contains(sessionID) { return true }
        if let canonical = canonicalSessionID(for: sessionID), ids.contains(canonical) { return true }
        return false
    }

    /// The stored chat behind a runtime id, so a rotated runtime id doesn't
    /// re-arm automatic takeover for the same chat.
    func chatTakeoverGuardKey(_ sessionID: String) -> String {
        canonicalSessionID(for: sessionID) ?? sessionID
    }

    /// Records a send refused because another app owns the chat.
    func noteChatOwnedElsewhere(
        _ refusal: RpcError,
        sessionID: String,
        knownSessionIDs: Set<String>,
        refusedText: String
    ) {
        let details = ChatTakeoverState.details(fromRefusal: refusal.message)
        var ids = [sessionID]
        for id in [details.sessionID, canonicalSessionID(for: sessionID)].compactMap({ $0 }) + knownSessionIDs.sorted()
        where !ids.contains(id) {
            ids.append(id)
        }
        chatTakeoverTask?.cancel()
        chatTakeoverTask = nil
        chatTakeoverKeepsRefusedWords = nil
        errorMessage = nil
        chatTakeover = ChatTakeoverState(
            sessionID: sessionID, sessionIDs: ids, surface: details.surface, refusedText: refusedText,
            // A plugin that reported no takeover route can't help: say so
            // now rather than after a tap.
            phase: notifierPlugin.mightSupport("session-takeover")
                ? .offered
                : .unavailable(Self.chatTakeoverFailureMessage(ChatTakeoverError.pluginMissing))
        )
        // The plugin may have been updated since the last check: ask again,
        // so the next refusal can offer the takeover.
        if !notifierPlugin.mightSupport("session-takeover") {
            Task { await refreshNotifierPluginStatus() }
        }
        lifecycleLog.notice(
            "prompt.submit refused: chat owned by \(details.surface ?? "another surface", privacy: .public) session=\(sessionID, privacy: .private(mask: .hash))"
        )
    }

    /// The profile whose claims the takeover route reads: a Bot Chat's bot,
    /// else the workspace. A Bot Chat's claim is in its bot's registry, so
    /// asking the workspace found nobody holding it, the resend was refused
    /// again, and the offer never went away.
    private func chatTakeoverProfile(_ state: ChatTakeoverState) -> String {
        botScopeProfile(forSessionIDs: Set(state.sessionIDs), workspaceProfile: activeProfile) ?? activeProfile
    }

    /// Asks the host to drop the other app's claim, waiting while it runs a
    /// turn. On success the composer sends its draft again.
    func takeOverChat() {
        guard var state = chatTakeover else { return }
        switch state.phase {
        case .offered, .failed: break
        case .waiting, .ready, .heldHere, .unavailable: return
        }
        chatTakeoverTask?.cancel()
        state.phase = .waiting
        chatTakeover = state
        let client = chatTakeoverClient
        let profile = chatTakeoverProfile(state)
        let waiting = state
        // Only `client` is held across the awaits; `self` is re-taken weakly
        // just to publish the result.
        chatTakeoverTask = Task { [weak self] in
            let phase = await Self.runChatTakeover(client: client, state: waiting, profile: profile, onOwner: { surface in
                self?.noteChatTakeoverOwner(surface, sessionID: waiting.sessionID)
            })
            guard let self else { return }
            // Only the latest takeover clears its own handle.
            if !Task.isCancelled { self.chatTakeoverTask = nil }
            guard let phase, !Task.isCancelled,
                  self.chatTakeover?.sessionID == waiting.sessionID else { return }
            // A typed message this takeover kept goes now, sent by Conduit
            // rather than left for the composer to find (issue 2140).
            if phase == .ready, let held = self.chatTakeoverHeldMessage, held.sessionID == waiting.sessionID {
                self.chatTakeoverHeldMessage = nil
                if self.canSendHeldTakeoverMessage(held) {
                    // Bound to the chat that refused it: one opened before
                    // the send starts gets nothing, and the words go back.
                    let context = self.composerSubmissionContext()
                    let clearCount = self.composerDraftStore.clearCount
                    self.dismissChatTakeover()
                    Task { @MainActor [weak self] in
                        await self?.sendHeldTakeoverMessage(held, context: context, clearCount: clearCount)
                    }
                    return
                }
                // Not from here right now (another chat is open, or the
                // composer is locked while the chat syncs): the words go
                // back, and the composer sends them once it can, as after
                // a takeover the user asked for.
                self.composerRestoreRequests.append(held.restore)
            }
            var settled = waiting
            settled.surface = self.chatTakeover?.surface ?? waiting.surface
            settled.phase = phase
            if phase == .ready {
                self.chatTakeoverReadyCount &+= 1
                settled.readyToken = self.chatTakeoverReadyCount
            } else if self.chatTakeoverAutomaticSessionID == self.chatTakeoverGuardKey(waiting.sessionID) {
                // Nothing is resent after a takeover that didn't happen, so
                // there's no loop to stop: a later refusal tries again.
                self.chatTakeoverAutomaticSessionID = nil
            }
            self.chatTakeover = settled
        }
    }

    /// Keeps the words of the typed message whose refusal started the
    /// automatic takeover, instead of putting them back in the composer:
    /// Conduit sends them itself once the chat is its own, as a call does
    /// its request (#1061). Before, the composer resent only when its
    /// field still held exactly that message, so words that came back
    /// anywhere else were lost behind "Send your message again" (issue
    /// 2140). True when kept; they go back if the takeover doesn't happen.
    func keepsWordsForChatTakeover(_ request: ComposerRestoreRequest) -> Bool {
        guard chatTakeoverHeldMessage == nil, let takeover = chatTakeover,
              chatTakeoverKeepsRefusedWords == takeover.sessionID, takeover.phase == .waiting else { return false }
        let draft = request.draft
        let outbound = ComposerReplyReference.outboundText(
            draft.text.trimmingCharacters(in: .whitespacesAndNewlines),
            hasAttachments: !draft.attachments.isEmpty,
            replyingTo: draft.replyReference
        )
        guard takeover.isRefusedMessage(outbound, hasAttachments: !draft.attachments.isEmpty) else { return false }
        chatTakeoverKeepsRefusedWords = nil
        chatTakeoverHeldMessage = ChatTakeoverHeldMessage(
            sessionID: takeover.sessionID, sessionIDs: takeover.sessionIDs, text: takeover.refusedText, restore: request
        )
        return true
    }

    /// The kept words go back to the composer once their takeover ends
    /// without the chat becoming Conduit's: it failed, can't happen here,
    /// was dismissed, or a profile or dashboard switch or another refusal
    /// replaced it.
    func returnHeldTakeoverMessageIfEnded() {
        guard let held = chatTakeoverHeldMessage else { return }
        if let takeover = chatTakeover, takeover.sessionID == held.sessionID, takeover.phase == .waiting { return }
        chatTakeoverHeldMessage = nil
        composerRestoreRequests.append(held.restore)
    }

    /// The kept message can go from here: its chat is the one open and the
    /// composer would send.
    private func canSendHeldTakeoverMessage(_ held: ChatTakeoverHeldMessage) -> Bool {
        guard composerIsEnabled, let current = activeSessionId else { return false }
        let ids = Set(held.sessionIDs)
        if ids.contains(current) { return true }
        return canonicalSessionID(for: current).map(ids.contains) == true
    }

    /// Sends the kept message as the composer would have, into the chat
    /// that refused it. One that doesn't go comes back to the composer like
    /// any send that didn't; refused again, the composer offers the button
    /// instead of looping. A sign-out while it was on its way wiped the
    /// drafts and the waiting messages' files: the outgoing user's words
    /// don't come back.
    /// `clearCount`: the draft store's, when the takeover finished.
    private func sendHeldTakeoverMessage(
        _ held: ChatTakeoverHeldMessage,
        context: ComposerSubmissionContext,
        clearCount: UInt64
    ) async {
        guard composerDraftStore.clearCount == clearCount else { return }
        lifecycleLog.notice("took the chat over; sending the refused message again")
        if await submitComposer(text: held.text, attachments: held.restore.draft.attachments, context: context) {
            if let pending = held.restore.pending { removePendingComposerSendFile(pending) }
            return
        }
        guard composerDraftStore.clearCount == clearCount else { return }
        if let pending = held.restore.pending,
           !pendingComposerSendFiles(dashboardID: pending.dashboardID).contains(where: { $0.id == pending.id })
            || composerRestoreRequests.contains(where: { $0.pending?.id == pending.id }) {
            return
        }
        composerRestoreRequests.append(held.restore)
    }

    /// Who the plugin says holds the chat while Conduit waits. Hermes'
    /// refusal doesn't name another bot's message running in a Bot Chat, so
    /// the notice says so once the plugin does, instead of "another window".
    private func noteChatTakeoverOwner(_ surface: String, sessionID: String) {
        guard var state = chatTakeover, state.sessionID == sessionID, state.phase == .waiting,
              state.surface != surface else { return }
        state.surface = surface
        chatTakeover = state
    }

    /// Polls the takeover route until it settles: while the owner is mid-turn,
    /// and through a few transient failures (bridge not ready, 5xx, network).
    /// `onOwner` hears who holds the chat when a busy answer names it. Nil
    /// when cancelled.
    static func runChatTakeover(
        client: ChatTakeoverClient,
        state: ChatTakeoverState,
        profile: String,
        pollInterval: Duration = chatTakeoverPollInterval,
        waitLimit: TimeInterval = chatTakeoverWaitLimit,
        keepWaiting: () -> Bool = { true },
        onOwner: (String) -> Void = { _ in }
    ) async -> ChatTakeoverState.Phase? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(waitLimit))
        var state = state
        var transientFailures = 0
        while !Task.isCancelled, keepWaiting() {
            do {
                switch try await client.takeOver(sessionIDs: state.sessionIDs, profile: profile) {
                case .ready:
                    return .ready
                case .sameHost:
                    return .heldHere
                case .busy(let surface):
                    transientFailures = 0
                    if let surface {
                        state.surface = surface
                        onOwner(surface)
                    }
                    guard clock.now < deadline else {
                        return .failed(state.stillReplyingMessage)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return nil }
                transientFailures += 1
                guard isTransientChatTakeoverFailure(error),
                      transientFailures < chatTakeoverTransientRetryLimit,
                      clock.now < deadline else {
                    if case ChatTakeoverError.pluginMissing = error { return .unavailable(chatTakeoverFailureMessage(error)) }
                    if case ChatTakeoverError.pluginOff = error { return .unavailable(chatTakeoverFailureMessage(error)) }
                    if case ChatTakeoverError.unsupported = error { return .unavailable(chatTakeoverFailureMessage(error)) }
                    if case ChatTakeoverError.malformed = error { return .unavailable(chatTakeoverFailureMessage(error)) }
                    return .failed(chatTakeoverFailureMessage(error))
                }
            }
            try? await Task.sleep(for: pollInterval)
        }
        return nil
    }

    static let chatTakeoverTransientRetryLimit = 5

    static func isTransientChatTakeoverFailure(_ error: Error) -> Bool {
        switch error {
        case DashboardTicketBridgeError.notReady, DashboardTicketBridgeError.answeredAfterSwitch:
            return true
        case DashboardTicketBridgeError.http(let status, _):
            // The client already maps 501 to `.unsupported`; excluded here too
            // so the predicate stands on its own.
            return status == 0 || status == 408 || status == 429 || (status >= 500 && status != 501)
        case is URLError:
            return true
        default:
            return false
        }
    }

    /// How long a call's request waits for the other app's reply to finish
    /// before the call says the chat is still busy there.
    static let callChatTakeoverWaitLimit: TimeInterval = 20

    /// A call's request sent through the composer: Classic voice, Local
    /// Live, and the live modes' requests in the open chat. Hermes refuses
    /// it while Hermes Desktop or a terminal still holds the chat; Conduit
    /// then takes the chat over and sends the same request once more
    /// (#1061), so the call's first request isn't lost. Calls take over
    /// regardless of Take over automatically: starting a call in the chat
    /// already says the user wants it here. `stillWanted` is asked before
    /// the resend: a turn the call moved past isn't sent late.
    /// The composer's own resend never runs for it: its draft isn't the
    /// request, and the notice is gone once the chat is Conduit's.
    func submitComposerForCall(
        text: String,
        onBusy: (() -> Void)? = nil,
        stillWanted: @escaping () -> Bool = { true }
    ) async -> Bool {
        callSubmissionTexts.append(text)
        defer {
            if let index = callSubmissionTexts.firstIndex(of: text) { callSubmissionTexts.remove(at: index) }
        }
        if await submitComposer(text: text, onBusy: onBusy) { return true }
        guard let sessionID = activeSessionId, chatTakeoverMatches(sessionID),
              let refused = chatTakeover, refused.phase == .offered, refused.isRefusedMessage(text),
              await takeOverChatForCall(stillWanted: stillWanted) else { return false }
        // The user may have opened another chat while it waited: the
        // request belongs to the chat that refused it, never that one.
        guard !Task.isCancelled, stillWanted(), let current = activeSessionId,
              chatTakeoverGuardKey(current) == chatTakeoverGuardKey(sessionID) else { return false }
        return await submitComposer(text: text, onBusy: onBusy)
    }

    /// Takes the refused open chat over for a call's request, waiting 20
    /// seconds at most. True when the chat is Conduit's now; otherwise the
    /// notice keeps the outcome for the composer. Each request takes over
    /// once at most, so it needs no loop guard, and a later request can
    /// try again once the user fixed what stopped this one.
    private func takeOverChatForCall(stillWanted: @escaping () -> Bool) async -> Bool {
        guard var state = chatTakeover, state.phase == .offered else { return false }
        chatTakeoverTask?.cancel()
        chatTakeoverTask = nil
        state.phase = .waiting
        chatTakeover = state
        let client = chatTakeoverClient
        let profile = chatTakeoverProfile(state)
        let waiting = state
        let wait = Task { () -> ChatTakeoverState.Phase? in
            await Self.runChatTakeover(
                client: client, state: waiting, profile: profile, waitLimit: Self.callChatTakeoverWaitLimit,
                keepWaiting: stillWanted, onOwner: { [weak self] surface in
                    self?.noteChatTakeoverOwner(surface, sessionID: waiting.sessionID)
                }
            )
        }
        // Held as the takeover's task, so dismissing the notice (or a profile
        // or dashboard switch) stops the wait as it does the composer's.
        let handle = Task {
            await withTaskCancellationHandler { _ = await wait.value } onCancel: { wait.cancel() }
        }
        chatTakeoverTask = handle
        let phase = await withTaskCancellationHandler { await wait.value } onCancel: { wait.cancel() }
        if chatTakeoverTask == handle { chatTakeoverTask = nil }
        // Dismissed, or replaced by another refusal, while it waited.
        guard chatTakeover?.sessionID == state.sessionID, chatTakeover?.phase == .waiting else { return false }
        // Keeps the owner the plugin named while it waited.
        state.surface = chatTakeover?.surface ?? state.surface
        guard let phase else {
            // The call moved on: the composer offers the button again.
            state.phase = .offered
            chatTakeover = state
            return false
        }
        if phase == .ready {
            dismissChatTakeover()
            return true
        }
        state.phase = phase
        chatTakeover = state
        return false
    }

    /// Why the open chat refused a call's request, when another app holds it.
    func callRefusalMessageForOpenChat() -> String? {
        activeChatTakeover?.callRefusalMessage
    }

    /// A call's request to a chat that isn't on screen. Refused because
    /// another app holds the chat, it's sent once more after taking the chat
    /// over, as in the open chat (#1061).
    func sendCallPromptTakingOver(
        runtimeID: String,
        otherSessionIDs: [String],
        profile: String?,
        stillWanted: () -> Bool = { true },
        send: () async throws -> PromptSubmissionOutcome
    ) async throws -> PromptSubmissionOutcome {
        do {
            return try await send()
        } catch let refusal as RpcError where refusal.isSessionNotOwned {
            let bridge = dashboardTicketBridge
            let details = ChatTakeoverState.details(fromRefusal: refusal.message)
            var ids = [runtimeID]
            for id in [details.sessionID].compactMap({ $0 }) + otherSessionIDs where !id.isEmpty && !ids.contains(id) {
                ids.append(id)
            }
            var state = ChatTakeoverState(sessionID: runtimeID, sessionIDs: ids, surface: details.surface, phase: .offered)
            // Nil: the call ended while it waited, so there's no refusal to report.
            guard let phase = await Self.runChatTakeover(
                client: chatTakeoverClient, state: state, profile: profile ?? activeProfile,
                waitLimit: Self.callChatTakeoverWaitLimit, keepWaiting: stillWanted,
                onOwner: { state.surface = $0 }
            ) else { throw CancellationError() }
            // What a refusal of the resend says: the other app holds it
            // again, named as the plugin named it during the wait.
            let refusedAgainMessage = state.openElsewhereMessage
            state.phase = phase
            guard state.phase == .ready else { throw VoiceAudioError.unavailable(state.callRefusalMessage) }
            // Another host now, or a turn the call moved past: nothing to send.
            guard bridge === dashboardTicketBridge, stillWanted() else { throw CancellationError() }
            lifecycleLog.notice(
                "call request: took chat over from \(details.surface ?? "another surface", privacy: .public); sending again session=\(runtimeID, privacy: .private(mask: .hash))"
            )
            do {
                return try await send()
            } catch let again as RpcError where again.isSessionNotOwned {
                // The other app took it straight back: no third try.
                throw VoiceAudioError.unavailable(refusedAgainMessage)
            }
        }
    }

    /// Stops waiting and hides the offer.
    func dismissChatTakeover() {
        chatTakeoverTask?.cancel()
        chatTakeoverTask = nil
        chatTakeoverKeepsRefusedWords = nil
        chatTakeover = nil
    }

    static func chatTakeoverFailureMessage(_ error: Error) -> String {
        switch error {
        case ChatTakeoverError.pluginMissing:
            return PluginUpdateAsk.text(AppLocalization.string("Update the Conduit notifier plugin on your Hermes host to take chats over."))
        case ChatTakeoverError.pluginOff(let remedy):
            return remedy
        case ChatTakeoverError.unsupported:
            return AppLocalization.string("This Hermes version can't hand a chat over.")
        case ChatTakeoverError.malformed:
            // A managed host's plugin isn't missing the route: keep the retry, name who updates it.
            return PluginUpdateAsk.text(AppLocalization.string("The Conduit notifier plugin gave an unexpected answer. Update it on your Hermes host and try again."),
                                        instead: AppLocalization.string("The Conduit notifier plugin gave an unexpected answer. Try again in a moment."))
        default:
            let detail = UserFacingError.message(for: error).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !detail.isEmpty, !(error is DashboardTicketBridgeError) else {
                return AppLocalization.string("Couldn't take this chat over. Check the connection to your Hermes host and try again.")
            }
            return AppLocalization.string("Couldn't take this chat over: \(detail)")
        }
    }

    /// What `prompt.submit` carries: each staged file's `@file:` reference
    /// on its own line ahead of the typed text, as Hermes Desktop sends it,
    /// so the agent is told where the file is.
    nonisolated static func promptText(_ text: String, fileReferences: [String]) -> String {
        let references = fileReferences.joined(separator: "\n")
        guard !references.isEmpty else { return text }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return references }
        return "\(references)\n\n\(text)"
    }

    /// Hermes refused an upload as an image (an extension it doesn't list,
    /// or past its image size cap) rather than failing to store it.
    nonisolated static func isImageAttachRefusal(_ error: RpcError) -> Bool {
        error.code == 4016 || error.code == 4018
    }
}
