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
            return ComposerDraftKey(profile: activeProfile, sessionID: ComposerDraftKey.newConversationSessionID)
        case .savedCopy:
            if let sessionID = offlineChatPresentation?.composerSessionID {
                return ComposerDraftKey(profile: activeProfile, sessionID: sessionID)
            }
        case .live, .none:
            break
        }
        return ComposerBar.composerDraftKey(for: activeSessionId, profile: activeProfile)
    }

    /// A restoration can outlive the current runtime alias. Capture the
    /// durable destination while this chat still owns that alias.
    var durableComposerDraftKeyOnScreen: ComposerDraftKey {
        let key = composerDraftKeyOnScreen
        guard !key.isNewConversation else { return key }
        return ComposerDraftKey(profile: key.profile, sessionID: durableComposerSessionID(for: key.sessionID))
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
                guard sessionID == newChatOpenedSessionID, let created = newChatOpenedDurableSessionID else { return false }
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
        composerRestoreRequests.append(ComposerRestoreRequest(
            dashboardID: dashboardID,
            key: key,
            draft: draft,
            focuses: false,
            pending: nil
        ))
        // Another dashboard or profile on screen: its composer's notices
        // are about its own chats.
        guard stoppedQuietly, dashboardID == activeDashboardID, key.profile == activeProfile else { return }
        let named = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AppLocalization.string("New chat") : title
        composerNotice = composerDraftKeysAreSameChat(key, durableComposerDraftKeyOnScreen)
            ? AppLocalization.string("Your message wasn't sent. It's back in the composer.")
            : AppLocalization.string("Your message to “\(named)” wasn't sent. It's back in that chat's draft.")
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
        composerNotice = nil
    }

    // MARK: Settling

    /// Looks at the waiting message once the current update is done: its
    /// chat may have landed, gone or become ready.
    func schedulePendingComposerSendCheck() {
        guard pendingComposerSend != nil, !pendingComposerSendCheckScheduled else { return }
        pendingComposerSendCheckScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingComposerSendCheckScheduled = false
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
        deliveringPendingComposerSendIDs.insert(pending.id)
        let context = composerSubmissionContext()
        let key = durableComposerDraftKeyOnScreen
        Task { @MainActor [weak self] in
            guard let self else { return }
            let sent = await self.submitComposer(text: pending.outboundText, context: context)
            self.deliveringPendingComposerSendIDs.remove(pending.id)
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
        composerRestoreRequests.append(
            restoreRequest(
                for: pending,
                key: chatIsGone ? durableComposerDraftKeyOnScreen : submittedDraftKey,
                redirects: chatIsGone,
                focuses: false
            )
        )
        if !onScreen, !mayHaveGone, pending.dashboardID == activeDashboardID, pending.profile == activeProfile {
            composerNotice = pendingComposerSendNotice(for: pending, onScreen: onScreen, chatIsGone: chatIsGone)
        }
    }

    private func cancelPendingComposerSendRecheck() {
        pendingComposerSendRecheckTask?.cancel()
        pendingComposerSendRecheckTask = nil
    }

    private func recheckPendingComposerSendSoon() {
        guard pendingComposerSendRecheckTask == nil else { return }
        pendingComposerSendRecheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.pendingComposerSendRecheckTask = nil
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
        composerRestoreRequests.append(
            restoreRequest(
                for: pending,
                key: onScreen || chatIsGone ? durableComposerDraftKeyOnScreen : nil,
                redirects: chatIsGone,
                focuses: false
            )
        )
        if pending.dashboardID == activeDashboardID, pending.profile == activeProfile {
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
                && !deliveringPendingComposerSendIDs.contains(file.id)
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
    func leaveComposerSends(dashboardID: UUID?) {
        forgetComposerSubmissionsOfUnknownDelivery()
        if let pending = pendingComposerSend, dashboardID == nil || pending.dashboardID == dashboardID {
            pendingComposerSend = nil
            cancelPendingComposerSendRecheck()
        }
        if composerRestoreRequests.contains(where: { dashboardID == nil || $0.dashboardID == dashboardID }) {
            composerRestoreRequests.removeAll { dashboardID == nil || $0.dashboardID == dashboardID }
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
            return AppLocalization.string("Your message to “\(pending.title)” wasn't sent: Hermes no longer has that chat. It's in the composer now.")
        }
        if pending.isNewChat {
            return AppLocalization.string("Your message for a new chat wasn't sent. It's saved for your next new chat.")
        }
        if onScreen {
            return AppLocalization.string("Your message wasn't sent. It's back in the composer.")
        }
        return AppLocalization.string("Your message to “\(pending.title)” wasn't sent. It's back in that chat's draft.")
    }
}
