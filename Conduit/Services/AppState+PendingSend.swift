//
//  AppState+PendingSend.swift
//  Conduit
//
//  Typing while Conduit connects (#417). A message sent before its chat is
//  ready waits in that chat as "Sends when connected" and goes through the
//  normal send once the chat is. It is tied to the chat on screen when it
//  was sent: if another chat lands instead, or Conduit stops or is away a
//  long time first, it goes back into its chat's draft and is never sent
//  on its own.
//

import Foundation
import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

/// Words for the composer to put back, and the draft they belong to.
struct ComposerRestoreRequest: Equatable, Identifiable {
    let id = UUID()
    let dashboardID: UUID
    let key: ComposerDraftKey
    let draft: ComposerDraft
    /// The field takes focus too (the waiting message's Edit).
    let focuses: Bool
    /// The waiting message they come from: its file goes once they're back.
    let pending: PendingComposerSend?
    /// The shared draft they come from (#812): it leaves the share inbox
    /// once they're in the composer, so a draft is never only in memory.
    var sharedDraftID: UUID? = nil
    /// The kept dictation recording a Retry transcribed: deleted once its
    /// words are in the composer, the same way.
    var dictationClipID: UUID? = nil
}

/// A send checking Hermes before its message shows, and the chat it's in.
struct ComposerSendCheck: Equatable, Identifiable {
    let id = UUID()
    let sessionID: String?
    let viewportTransitionGeneration: UInt64
    /// Starting the chat from the empty canvas.
    let startsChat: Bool
    /// The chat an earlier New Chat opened, when this check began.
    let earlierNewChat: String?
}

/// The chat the composer types into right now.
enum ComposerChatOnScreen: Equatable {
    case none
    /// A New Chat Hermes hasn't created yet.
    case newChat
    /// A saved copy, by every id its chat answers to.
    case savedCopy(Set<String>)
    /// The live chat, by the id it is open by.
    case live(String)
}

extension AppState {
    /// Away from Conduit this long, a waiting message isn't sent on its own
    /// when it comes back: by then the chat may have moved on.
    static let pendingComposerSendAbsenceLimit: TimeInterval = 10 * 60

    var composerChatOnScreen: ComposerChatOnScreen {
        if showsPendingNewChat { return .newChat }
        if showsOfflineChatCopy, let copy = offlineChatPresentation {
            let ids = copy.chatSessionIDs
            return ids.isEmpty ? .none : .savedCopy(ids)
        }
        if let activeSessionId { return .live(activeSessionId) }
        return .none
    }

    /// The chat on screen is on its way and takes a message to send once it
    /// is ready: a New Chat Hermes hasn't created, a saved copy while
    /// Conduit connects, or a chat synchronizing or reconnecting. Also while
    /// a message waits there, so the next one goes after it.
    var composerWaitsForChat: Bool {
        // A Hermes too old to recover turns safely can't take it: the
        // composer stays locked and says why.
        guard isConnected || isRecoveringConnection, turnState != .unsupportedGateway else { return false }
        switch composerChatOnScreen {
        case .none:
            return false
        case .newChat, .savedCopy:
            return true
        case .live:
            return liveChatIsOnItsWay || pendingComposerSendOnScreen != nil
        }
    }

    /// The field takes text: its chat is ready, or on its way.
    var composerTakesText: Bool {
        composerIsEnabled || composerWaitsForChat
    }

    /// The draft the composer shows: the saved copy's chat while the copy
    /// is up, the New Chat draft while one is on its way, else the open
    /// chat's.
    var composerDraftKeyOnScreen: ComposerDraftKey {
        switch composerChatOnScreen {
        case .newChat:
            return ComposerDraftKey(dashboard: activeDashboardID, profile: activeProfile, sessionID: ComposerDraftKey.newConversationSessionID)
        case .savedCopy:
            // The copy's own dashboard and profile: a far chat's while it
            // opens, so words typed then carry over to its live draft.
            if let presentation = offlineChatPresentation, let sessionID = presentation.composerSessionID {
                return ComposerDraftKey(dashboard: presentation.dashboardID, profile: presentation.profile, sessionID: sessionID)
            }
        case .live, .none:
            break
        }
        // Another combined dashboard's chat on screen keeps its draft under
        // its own dashboard and profile, as its sends name it.
        if let farChat {
            return ComposerBar.composerDraftKey(for: activeSessionId, profile: farChat.profile, dashboard: farChat.dashboardID)
        }
        return ComposerBar.composerDraftKey(for: activeSessionId, profile: activeProfile, dashboard: activeDashboardID)
    }

    /// A restoration can outlive the current runtime alias. Capture the
    /// durable destination while this chat still owns that alias.
    var durableComposerDraftKeyOnScreen: ComposerDraftKey {
        let key = composerDraftKeyOnScreen
        guard !key.isNewConversation else { return key }
        return ComposerDraftKey(dashboard: key.dashboard, profile: key.profile, sessionID: durableComposerSessionID(for: key.sessionID))
    }

    /// The waiting message, while its chat is the one on screen.
    var pendingComposerSendOnScreen: PendingComposerSend? {
        guard let pending = pendingComposerSend, isOnScreen(pending) else { return nil }
        return pending
    }

    /// Whether `pending`'s chat is the one on screen. The chat a New Chat
    /// created is that New Chat's while it's the one open.
    func isOnScreen(_ pending: PendingComposerSend) -> Bool {
        guard pending.dashboardID == activeDashboardID, pending.profile == activeProfile else { return false }
        switch composerChatOnScreen {
        case .none:
            return false
        case .newChat:
            return pending.isNewChat
        case .savedCopy(let ids):
            return !pending.isNewChat && ids.contains(pending.draftSessionID)
        case .live(let sessionID):
            if pending.isNewChat {
                guard sessionID == shownChat.newChatOpenedSessionID, let created = shownChat.newChatOpenedDurableSessionID else { return false }
                return liveChatOwnsComposerDraftSessionID(created)
            }
            return liveChatOwnsComposerDraftSessionID(pending.draftSessionID)
        }
    }

    // MARK: Sending

    /// A send while the chat on screen is on its way: the message waits for
    /// it, after any message already waiting there. False when there is no
    /// chat it could wait for.
    @discardableResult
    func sendWhenConnected(_ text: String, replyReference: ComposerReplyReference?) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard composerWaitsForChat, !trimmed.isEmpty, Self.parseSlashCommand(trimmed) == nil,
              let dashboardID = activeDashboardID else { return false }
        let pending: PendingComposerSend
        if let waiting = pendingComposerSendOnScreen {
            pending = waiting.appending(trimmed, replyReference: replyReference)
        } else {
            guard let chat = waitingChatOnScreen() else { return false }
            pending = PendingComposerSend(
                draftText: trimmed,
                replyReference: replyReference,
                dashboardID: dashboardID,
                profile: activeProfile,
                sessionIDs: chat.sessionIDs,
                draftSessionID: chat.draftSessionID,
                isNewChat: chat.isNewChat,
                title: displayedChatTitle
            )
        }
        // Accept only once the file is safe. On failure the caller keeps
        // its draft, and any previously accepted message stays unchanged.
        guard recordPendingComposerSendFile(pending) else { return false }
        composerNotice = nil
        if let other = pendingComposerSend, other.id != pending.id {
            returnPendingComposerSendToDraft(other)
        }
        pendingComposerSend = pending
        // A message that waits says why: a reconnect kept quiet after
        // coming back to the app shows from now (#1624).
        endQuietReturn()
        // The chat shows it below its rows, the saved copy's included.
        switch composerChatOnScreen {
        case .live, .savedCopy: requestChatScrollToLatest()
        case .newChat, .none: break
        }
        schedulePendingComposerSendCheck()
        return true
    }

    /// The chat a message sent now waits for: every id it answers to, the
    /// id its draft is kept under, and whether it's a New Chat.
    private func waitingChatOnScreen() -> (sessionIDs: Set<String>, draftSessionID: String, isNewChat: Bool)? {
        switch composerChatOnScreen {
        case .none:
            return nil
        case .newChat:
            return ([], ComposerDraftKey.newConversationSessionID, true)
        case .savedCopy(let ids):
            guard let sessionID = offlineChatPresentation?.composerSessionID else { return nil }
            return (ids, sessionID, false)
        case .live(let sessionID):
            return (liveChatSessionIDs(), durableComposerSessionID(for: sessionID), false)
        }
    }

    /// The bubble's Edit: the waiting message goes back into the composer,
    /// to change or delete.
    func editPendingComposerSend() {
        guard let pending = pendingComposerSendOnScreen else { return }
        cancelPendingComposerSendRecheck()
        pendingComposerSend = nil
        composerNotice = nil
        composerRestoreRequests.append(restoreRequest(for: pending, key: durableComposerDraftKeyOnScreen, focuses: true))
    }

    /// A send that didn't go: its words go back into the draft they were
    /// typed in. Through here rather than the composer that sent them,
    /// which may have gone (the chat left while the send was on its way)
    /// and would take them with it; whichever composer is on screen puts
    /// them in its field, or in their chat's stored draft (#1401).
    /// `stoppedQuietly`: the send stopped without an error to say so (its
    /// chat was left before its message showed), so a notice says where
    /// the words went.
    func returnFailedComposerSubmission(
        _ draft: ComposerDraft,
        key: ComposerDraftKey,
        dashboardID: UUID,
        title: String,
        stoppedQuietly: Bool
    ) {
        let request = ComposerRestoreRequest(
            dashboardID: dashboardID,
            key: key,
            draft: draft,
            focuses: false,
            pending: nil
        )
        // Refused because another app held the chat, which Conduit is now
        // taking over on its own: it keeps the words and sends them itself
        // (issue 2140).
        if !stoppedQuietly, keepsWordsForChatTakeover(request) { return }
        composerRestoreRequests.append(request)
        // Another dashboard or profile on screen: its composer's notices
        // are about its own chats.
        guard stoppedQuietly, dashboardID == activeDashboardID, key.profile == activeProfile else { return }
        let named = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AppLocalization.string("New chat") : title
        composerNotice = composerDraftKeysAreSameChat(key, durableComposerDraftKeyOnScreen)
            ? AppLocalization.string("Your message wasn't sent. It's back in the composer.", table: .chat)
            : AppLocalization.string("Your message to “\(named)” wasn't sent. It's back in that chat's draft.", table: .chat)
    }

    /// The composer put the words back: the waiting message's file goes too.
    func consumeComposerRestoreRequest(_ id: UUID) {
        guard let index = composerRestoreRequests.firstIndex(where: { $0.id == id }) else { return }
        let request = composerRestoreRequests.remove(at: index)
        if let pending = request.pending { removePendingComposerSendFile(pending) }
        if let sharedDraftID = request.sharedDraftID { sharedDraftReachedComposer(sharedDraftID) }
        if let dictationClipID = request.dictationClipID { DictationClipInbox.shared.delivered(dictationClipID) }
    }

    func dismissComposerNotice() {
        // A file lookup's notice gives back the one it covered.
        if let said = workspaceLookupNotice, composerNotice == said {
            clearWorkspaceLookupNotice()
            return
        }
        composerNotice = nil
    }

    // MARK: Settling

    /// Looks at the waiting message once the current update is done: its
    /// chat may have landed, gone or become ready.
    func schedulePendingComposerSendCheck() {
        guard pendingComposerSend != nil, !shownChat.pendingComposerSendCheckScheduled else { return }
        shownChat.pendingComposerSendCheckScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.shownChat.pendingComposerSendCheckScheduled = false
            self.settlePendingComposerSend()
        }
    }

    func settlePendingComposerSend() {
        guard let pending = pendingComposerSend else { return }
        // Another dashboard's: its file stays, and the next visit there
        // puts it back as a draft.
        guard pending.dashboardID == activeDashboardID else {
            pendingComposerSend = nil
            cancelPendingComposerSendRecheck()
            return
        }
        // Another chat landed: it isn't sent anywhere.
        guard isOnScreen(pending) else {
            returnPendingComposerSendToDraft(pending)
            return
        }
        // A saved copy or a New Chat: its chat is still on its way.
        guard case .live = composerChatOnScreen else { return }
        if turnState == .unsupportedGateway {
            // This Hermes can't take it: the composer says why.
            returnPendingComposerSendToDraft(pending, saysWhy: false)
            return
        }
        guard composerIsEnabled, isConnected, client != nil else { return }
        // A sync or reconnect still running could replace the chat.
        guard !isSettlingConnection else {
            recheckPendingComposerSendSoon()
            return
        }
        deliverPendingComposerSend(pending)
    }

    /// Through the normal send, busy mode and all. One that doesn't go
    /// comes back to the composer, like any send that didn't.
    private func deliverPendingComposerSend(_ pending: PendingComposerSend) {
        cancelPendingComposerSendRecheck()
        pendingComposerSend = nil
        shownChat.deliveringPendingComposerSendIDs.insert(pending.id)
        let context = composerSubmissionContext()
        let key = durableComposerDraftKeyOnScreen
        Task { @MainActor [weak self] in
            guard let self else { return }
            let sent = await self.submitComposer(text: pending.outboundText, context: context)
            self.shownChat.deliveringPendingComposerSendIDs.remove(pending.id)
            if sent {
                self.removePendingComposerSendFile(pending)
                return
            }
            self.restoreFailedPendingComposerSend(
                pending,
                submittedDraftKey: key,
                mayHaveGone: self.takeComposerSubmissionOfUnknownDelivery(context)
            )
        }
    }

    /// A submission can fail after sign-out or dashboard removal. Those
    /// account boundaries wipe its file; a late failure must not put the
    /// previous account's words back into a later login's draft.
    /// `mayHaveGone`: its reply was lost after its chat was left, so Hermes
    /// may have it; its words come back without a "wasn't sent" notice.
    func restoreFailedPendingComposerSend(
        _ pending: PendingComposerSend,
        submittedDraftKey: ComposerDraftKey,
        mayHaveGone: Bool = false
    ) {
        guard pendingComposerSendFiles(dashboardID: pending.dashboardID).contains(where: { $0.id == pending.id }),
              !composerRestoreRequests.contains(where: { $0.pending?.id == pending.id }) else { return }
        let onScreen = isOnScreen(pending)
        // Its chat went while it was being sent: as when it's handed back.
        let chatIsGone = !onScreen && pendingComposerSendChatIsGone(pending)
        let request = restoreRequest(
            for: pending,
            key: chatIsGone ? durableComposerDraftKeyOnScreen : submittedDraftKey,
            redirects: chatIsGone,
            focuses: false
        )
        // Refused because another app held the chat, which Conduit is now
        // taking over on its own: it keeps the message, file and all, and
        // sends it itself (issue 2140).
        if !mayHaveGone, keepsWordsForChatTakeover(request) { return }
        composerRestoreRequests.append(request)
        if !onScreen, !mayHaveGone, pending.dashboardID == activeDashboardID, pending.profile == activeProfile {
            composerNotice = pendingComposerSendNotice(for: pending, onScreen: onScreen, chatIsGone: chatIsGone)
        }
    }

    private func cancelPendingComposerSendRecheck() {
        shownChat.pendingComposerSendRecheckTask?.cancel()
        shownChat.pendingComposerSendRecheckTask = nil
    }

    private func recheckPendingComposerSendSoon() {
        guard shownChat.pendingComposerSendRecheckTask == nil else { return }
        shownChat.pendingComposerSendRecheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.shownChat.pendingComposerSendRecheckTask = nil
            self.settlePendingComposerSend()
        }
    }

    /// The waiting message isn't sent: its words go back into its chat's
    /// draft, or the composer when that chat is the one on screen, with a
    /// line saying so. A chat Hermes no longer has can't be opened again,
    /// so its words go into the composer on screen instead, unsent.
    func returnPendingComposerSendToDraft(_ pending: PendingComposerSend, saysWhy: Bool = true) {
        let onScreen = isOnScreen(pending)
        let chatIsGone = !onScreen && pendingComposerSendChatIsGone(pending)
        if pendingComposerSend?.id == pending.id {
            pendingComposerSend = nil
            cancelPendingComposerSendRecheck()
        }
        // A gone chat's words go to the composer on screen, unless that's
        // another dashboard's far chat: then to its own dashboard's New
        // Chat draft, never into another Hermes' chat.
        let screenKey = durableComposerDraftKeyOnScreen
        let goneKey = screenKey.dashboard == pending.dashboardID ? screenKey
            : ComposerDraftKey(dashboard: pending.dashboardID, profile: pending.profile,
                               sessionID: ComposerDraftKey.newConversationSessionID)
        composerRestoreRequests.append(
            restoreRequest(
                for: pending,
                key: onScreen ? screenKey : chatIsGone ? goneKey : nil,
                redirects: chatIsGone,
                focuses: false
            )
        )
        // The composer on screen says why only when it's this dashboard's:
        // a far chat's composer doesn't hold these words.
        if pending.dashboardID == activeDashboardID, pending.profile == activeProfile,
           composerDraftKeyOnScreen.dashboard == pending.dashboardID {
            composerNotice = saysWhy
                ? pendingComposerSendNotice(for: pending, onScreen: onScreen, chatIsGone: chatIsGone)
                : nil
        }
    }

    /// The waiting message's chat is one Hermes said it no longer has: the
    /// composer on screen takes its words instead (with no chat open, the
    /// next New Chat's draft).
    private func pendingComposerSendChatIsGone(_ pending: PendingComposerSend) -> Bool {
        guard !pending.isNewChat,
              pending.dashboardID == activeDashboardID,
              pending.profile == activeProfile else { return false }
        // By its durable id only: a runtime alias says nothing about
        // whether the conversation itself is gone.
        return conversationIsGone(
            sessionIDs: [pending.draftSessionID],
            dashboardID: pending.dashboardID,
            profile: pending.profile
        )
    }

    /// A time away long enough that the chat may have moved on: the
    /// message comes back as a draft, as after Conduit was stopped.
    func returnPendingComposerSendAfterLongAbsence(now: Date = Date()) {
        guard let pending = pendingComposerSend,
              let leftAt = lastLeftForegroundAt, leftAt >= pending.queuedAt,
              now.timeIntervalSince(leftAt) >= Self.pendingComposerSendAbsenceLimit else { return }
        returnPendingComposerSendToDraft(pending)
    }

    /// Messages an earlier run, or an earlier visit to this dashboard, left
    /// waiting come back as drafts. None is sent on its own.
    func restorePendingSendsLeftBehind(dashboardID: UUID) {
        guard dashboardID == activeDashboardID else { return }
        let leftBehind = pendingComposerSendFiles(dashboardID: dashboardID).filter { file in
            file.id != pendingComposerSend?.id
                && !shownChat.deliveringPendingComposerSendIDs.contains(file.id)
                && !composerRestoreRequests.contains { $0.pending?.id == file.id }
        }
        composerRestoreRequests.append(contentsOf: leftBehind.map { restoreRequest(for: $0, focuses: false) })
        if let newest = leftBehind.last(where: { $0.profile == activeProfile }) {
            composerNotice = pendingComposerSendNotice(for: newest, onScreen: isOnScreen(newest))
        }
    }

    /// A dashboard's waiting message, and words on their way back to its
    /// drafts, leave memory with it. The message's file stays unless the
    /// dashboard's saved chats are wiped, so the next visit puts it back.
    /// `keepingWordsOnTheirWay`: a switch between saved dashboards keeps a
    /// failed send's words on their way back to its chat's draft, which the
    /// switch keeps too (issue 2702). One with a file of its own (a waiting
    /// message, a shared draft, a dictation Retry) goes, since the file
    /// brings it back on the next visit. Words a server with no saved
    /// dashboard sent back go too: nothing can show them from here on.
    func leaveComposerSends(dashboardID: UUID?, keepingWordsOnTheirWay: Bool = false) {
        forgetComposerSubmissionsOfUnknownDelivery()
        if let pending = pendingComposerSend, dashboardID == nil || pending.dashboardID == dashboardID {
            pendingComposerSend = nil
            cancelPendingComposerSendRecheck()
        }
        func leaves(_ request: ComposerRestoreRequest) -> Bool {
            guard dashboardID == nil || request.dashboardID == dashboardID else { return false }
            return !keepingWordsOnTheirWay || request.dashboardID == nil
                || request.pending != nil || request.sharedDraftID != nil || request.dictationClipID != nil
        }
        if composerRestoreRequests.contains(where: leaves) {
            composerRestoreRequests.removeAll(where: leaves)
        }
        if dashboardID == nil || dashboardID == activeDashboardID {
            composerNotice = nil
        }
    }

    /// `redirects`: the message's own chat is gone, so `key` takes its words.
    private func restoreRequest(
        for pending: PendingComposerSend,
        key: ComposerDraftKey? = nil,
        redirects: Bool = false,
        focuses: Bool
    ) -> ComposerRestoreRequest {
        ComposerRestoreRequest(
            dashboardID: pending.dashboardID,
            // Normal chats keep their captured durable key. Historical
            // runtime aliases must not redirect a deferred restoration.
            key: pending.isNewChat || redirects ? key ?? pending.draftKey : pending.draftKey,
            draft: pending.draft,
            focuses: focuses,
            pending: pending
        )
    }

    func pendingComposerSendNotice(for pending: PendingComposerSend, onScreen: Bool, chatIsGone: Bool = false) -> String {
        if chatIsGone {
            return AppLocalization.string("Your message to “\(pending.title)” wasn't sent: Hermes no longer has that chat. It's in the composer now.", table: .chat)
        }
        if pending.isNewChat {
            return AppLocalization.string("Your message for a new chat wasn't sent. It's saved for your next new chat.", table: .chat)
        }
        if onScreen {
            return AppLocalization.string("Your message wasn't sent. It's back in the composer.", table: .chat)
        }
        return AppLocalization.string("Your message to “\(pending.title)” wasn't sent. It's back in that chat's draft.", table: .chat)
    }
}

extension AppState {
    // MARK: - Sending while connecting: what reads private state

    /// The saved copy is the chat on screen: over an empty transcript, or
    /// over any transcript for a chat picked in the saved list.
    var showsOfflineChatCopy: Bool {
        guard let offline = offlineChatPresentation else { return false }
        return messages.isEmpty || offline.isPickedChat
    }

    /// The rows the chat view draws: the saved copy's while it is the chat
    /// on screen, else the live transcript. Hermes' rows take over from the
    /// copy's in place, by id (#1533).
    var chatRowsOnScreen: [ChatMessage] {
        guard showsOfflineChatCopy, let copy = offlineChatPresentation else { return messages }
        return copy.displayedMessages
    }

    /// A turn runs in the chat drawn: not in a chat picked in the saved
    /// list, which isn't the live chat until it opens.
    var chatOnScreenIsBusy: Bool {
        isBusy && savedCopyScrollSessionKey == nil
    }

    /// The conversation the chat view draws while the saved copy on screen
    /// isn't the live chat's: a chat picked in the saved list before it
    /// opens, or a launch's copy before its chat resumes. Nil while no copy
    /// shows, or while it's the live chat's own: that one draws under the
    /// live chat's key, so Hermes' rows taking over isn't a switch.
    var savedCopyScrollSessionKey: ChatScrollSessionKey? {
        guard showsOfflineChatCopy, let copy = offlineChatPresentation else { return nil }
        if let active = activeSessionId, copy.chatSessionIDs.contains(active) { return nil }
        guard let sessionID = copy.composerSessionID else { return nil }
        let key = ChatScrollSessionKey(profile: copy.profile, sessionID: sessionID)
        return key.isValid ? key : nil
    }

    /// The live chat on screen is on its way back: synchronizing or
    /// reconnecting while the connection is up or coming back. Not while a
    /// New Chat creates its chat: the transcript up until then is the one
    /// being left.
    var liveChatIsOnItsWay: Bool {
        guard activeSessionId != nil, newSessionCreationsInFlight == 0,
              turnState == .synchronizing || turnState == .reconnecting else { return false }
        return isConnected || isRecoveringConnection
    }

    /// Every id the live chat on screen answers to.
    func liveChatSessionIDs() -> Set<String> {
        guard var ids = offlineChatIdentities() else { return [] }
        if let activeSessionId { ids.insert(activeSessionId) }
        for row in sessions + cronSessions where !ids.isDisjoint(with: row.nestingIDs) {
            ids.formUnion(row.nestingIDs)
        }
        return ids
    }

    /// A current catalog claim wins over historical scroll aliases: a
    /// runtime id can be reassigned to a different durable conversation.
    func liveChatOwnsComposerDraftSessionID(_ sessionID: String) -> Bool {
        guard let activeSessionId else { return false }
        // The chat on screen's row: the one recorded as it opened, else the
        // row owning its id (own or stored id first, else a single
        // borrower), so two rows carrying a moved alias never decide by
        // their order (#2794 review).
        // Two chats claiming the id with nothing recorded can't say which is
        // on screen: the message waits rather than land in the other one.
        let row: SessionSummary?
        if let kept = rowOfChatOnScreen, kept.dashboardID == activeDashboardID, kept.profile == activeProfile,
           kept.openIDs.contains(activeSessionId) {
            row = kept.row
        } else {
            let owning = Self.composerDraftOwningRow(of: activeSessionId, in: composerDraftRows(profile: activeProfile))
            if owning.isListed, owning.row == nil { return false }
            row = owning.row
        }
        if let row {
            return row.nestingIDs.contains(sessionID) || row.durableKey == sessionID
        }
        return liveChatSessionIDs().contains(sessionID)
    }

    /// The id a live chat's waiting message is kept under: its durable one,
    /// which outlives the runtime id the chat is open by.
    func durableComposerSessionID(for sessionID: String) -> String {
        canonicalSessionID(for: sessionID) ?? sessionID
    }

    /// Whether two drafts are the same chat's: the same key, the chat under
    /// another of its ids, or the New Chat draft and the chat it created.
    func composerDraftKeysAreSameChat(_ lhs: ComposerDraftKey, _ rhs: ComposerDraftKey) -> Bool {
        guard lhs.dashboard == rhs.dashboard, lhs.profile == rhs.profile else { return false }
        if lhs == rhs { return true }
        // A kept dashboard's draft: told from its own list, on its runtime.
        if let farRuntime = composerDraftFarRuntime(for: lhs) {
            // Its chat on screen: every check below is its own.
            if farChat?.dashboardID == lhs.dashboard {
                return act(onRuntime: farRuntime) { composerDraftKeysAreSameChat(lhs, rhs) }
            }
            // Left: only its list says. The chat state on screen (a New
            // Chat, a lost chat's replacement) is another chat's.
            return act(onRuntime: farRuntime) {
                let rows = composerDraftRows(profile: lhs.profile)
                guard let left = Self.composerDraftOwningRow(of: lhs.sessionID, in: rows).row,
                      let right = Self.composerDraftOwningRow(of: rhs.sessionID, in: rows).row else { return false }
                return left.durableKey == right.durableKey
            }
        }
        // The lists and ids below are the dashboard on screen's: another
        // dashboard's draft is only ever its own key.
        guard lhs.dashboard == activeDashboardID else { return false }
        if let replacement = shownChat.lostChatReplacement, lhs.profile == activeProfile,
           activeSessionId.map(replacement.fresh.contains) == true,
           replacement.lost.contains(lhs.sessionID) && replacement.fresh.contains(rhs.sessionID)
            || replacement.lost.contains(rhs.sessionID) && replacement.fresh.contains(lhs.sessionID) {
            return true
        }
        if lhs.isNewConversation || rhs.isNewConversation {
            let chat = lhs.isNewConversation ? rhs : lhs
            return !chat.isNewConversation && chat.profile == activeProfile
                && (chat.sessionID == shownChat.newChatOpenedSessionID || chat.sessionID == shownChat.newChatOpenedDurableSessionID)
                && shownChat.newChatOpenedDurableSessionID.map(liveChatOwnsComposerDraftSessionID) == true
        }
        // Each id is the chat of the row that owns it: a row whose id or
        // stored id it is, else the one row carrying it among its aliases.
        // An alias two rows carry is neither's (issue 2781), so a moved
        // alias never carries one chat's draft into another, whatever the
        // rows' order.
        let rows = composerDraftRows(profile: lhs.profile)
        let left = Self.composerDraftOwningRow(of: lhs.sessionID, in: rows)
        let right = Self.composerDraftOwningRow(of: rhs.sessionID, in: rows)
        if left.isListed || right.isListed {
            guard let leftRow = left.row, let rightRow = right.row else { return false }
            return leftRow.durableKey == rightRow.durableKey
        }
        return lhs.profile == activeProfile
            && ComposerBar.draftKeysAreEquivalent(lhs, rhs, identity: activeChatScrollSessionIdentity)
    }

    /// Whether the chat left under `leftID` is the chat now on screen under
    /// another of its ids (a reconnect's new runtime id), not another
    /// conversation. The scroll identity unions catalog aliases, so a row
    /// still listing an id Hermes handed to another chat would read the
    /// two as one: when the list names a different owning row for each id,
    /// they're different chats (issue 2858), as for drafts (issue 2781).
    func leftChatIsChatOnScreen(_ leftID: String?) -> Bool {
        guard let leftID, activeChatScrollSessionIdentity.contains(leftID) else { return false }
        guard let activeSessionId, leftID != activeSessionId else { return true }
        if reconciliation?.movedOnSessionIDs.contains(leftID) == true { return false }
        let rows = composerDraftRows(profile: activeProfile)
        let left = Self.composerDraftOwningRow(of: leftID, in: rows)
        let open = Self.composerDraftOwningRow(of: activeSessionId, in: rows)
        // As drafts decide it: an id two rows claim is neither's, so a listed
        // id with no single owner isn't the same chat (#2864 review).
        if left.isListed || open.isListed {
            guard let leftRow = left.row, let openRow = open.row else { return false }
            return leftRow.durableKey == openRow.durableKey
        }
        return true
    }

    /// The durable id of the chat a draft under `key` is for, from the list
    /// on screen: the owning row's stored id (else its id). Nil when no row
    /// owns the key's id, an alias two rows carry included (issue 2782).
    func composerDraftOwner(for key: ComposerDraftKey) -> String? {
        // A far chat's draft: from its own dashboard's list, on its runtime.
        if let farRuntime = composerDraftFarRuntime(for: key) {
            return act(onRuntime: farRuntime) { composerDraftOwner(for: key) }
        }
        guard !key.isNewConversation, key.dashboard == activeDashboardID else { return nil }
        return Self.composerDraftOwningRow(of: key.sessionID, in: composerDraftRows(profile: key.profile)).row?.durableKey
    }

    /// Whether the draft kept under `key` for the chat `owner` names is
    /// another chat's now: Hermes handed the key's runtime id to a chat the
    /// list names otherwise, or two rows carry it (issue 2782). An id no
    /// row lists says nothing, and the draft stays.
    func composerDraftKey(_ key: ComposerDraftKey, isNotChatOf owner: String) -> Bool {
        if let farRuntime = composerDraftFarRuntime(for: key) {
            return act(onRuntime: farRuntime) { composerDraftKey(key, isNotChatOf: owner) }
        }
        guard !key.isNewConversation, key.sessionID != owner, key.dashboard == activeDashboardID else { return false }
        let owning = Self.composerDraftOwningRow(of: key.sessionID, in: composerDraftRows(profile: key.profile))
        guard owning.isListed else { return false }
        return owning.row?.durableKey != owner
    }

    /// The kept dashboard's runtime when `key` is its draft, its chat on
    /// screen or not: its list is that dashboard's, read there.
    private func composerDraftFarRuntime(for key: ComposerDraftKey) -> DashboardRuntime? {
        // Its chat may have been left since: its dashboard's list still
        // names it while that dashboard is kept.
        guard let dashboard = key.dashboard, dashboard != activeDashboardID,
              let farRuntime = runtime(for: dashboard), farRuntime !== shownRuntime else { return nil }
        return farRuntime
    }

    private func composerDraftRows(profile: String) -> [SessionSummary] {
        (sessions + cronSessions).filter { sessionBelongsToProfile($0, profile: profile) }
    }

    /// The row owning `sessionID` among `rows`, and whether any row lists it
    /// at all: own id or stored id first, else a single borrower.
    static func composerDraftOwningRow(of sessionID: String, in rows: [SessionSummary]) -> (row: SessionSummary?, isListed: Bool) {
        // Two chats owning the id directly (Hermes gave a runtime id on
        // while the old row is still listed) is neither's, as a shared alias
        // is (#2794 review).
        let direct = rows.filter { $0.id == sessionID || $0.storedSessionId == sessionID }
        if let own = direct.first {
            return Set(direct.map(\.durableKey)).count == 1 ? (own, true) : (nil, true)
        }
        let borrowers = rows.filter { $0.alternateIds.contains(sessionID) }
        let owners = Set(borrowers.map(\.durableKey))
        return (owners.count == 1 ? borrowers.first : nil, !borrowers.isEmpty)
    }

    /// Typing over a saved copy makes its chat the one that opens, as a tap
    /// on it in the saved list does: until the live list lands, the
    /// automatic resume could still open another chat under the words.
    func noteComposerEditOverSavedCopy() {
        guard case .savedCopy = composerChatOnScreen,
              let copy = offlineChatPresentation, !copy.isPickedChat,
              let transcript = copy.displayedTranscript,
              chatPickedFromSavedList == nil,
              copy.dashboardID == activeDashboardID, copy.profile == activeProfile,
              !liveChatListLanded(dashboardID: copy.dashboardID, profile: copy.profile) else { return }
        let ids = copy.chatSessionIDs
        chatPickedFromSavedList = SavedChatListPick(
            dashboardID: copy.dashboardID,
            profile: copy.profile,
            sessionIDs: ids,
            openID: transcript.sessionID,
            rowID: copy.snapshot.sessions.first { $0.matches([transcript.sessionID]) }?.id ?? transcript.sessionID
        )
        offlineChatPresentation?.picked = OfflineChatPresentation.PickedChat(
            title: transcript.title,
            sessionIDs: ids,
            durableSessionID: transcript.sessionID
        )
    }

    @discardableResult
    func recordPendingComposerSendFile(_ pending: PendingComposerSend) -> Bool {
        offlineChatCache.recordPendingSend(pending)
    }

    func removePendingComposerSendFile(_ pending: PendingComposerSend) {
        offlineChatCache.removePendingSend(id: pending.id, dashboardID: pending.dashboardID, profile: pending.profile)
    }

    func pendingComposerSendFiles(dashboardID: UUID) -> [PendingComposerSend] {
        offlineChatCache.loadPendingSends(dashboardID: dashboardID)
    }
}
