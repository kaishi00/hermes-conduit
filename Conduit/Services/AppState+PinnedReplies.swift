//
//  AppState+PinnedReplies.swift
//  Conduit
//
//  Replies pinned to the top of their chat (#918): Pin reply or, for just
//  the selected passage, Pin in a reply's long-press menu (#1147), the
//  bar over the open chat that cycles through its pins, and the overview
//  of every pin, from the Chats list or from the bar on this chat's pins
//  (#1267), which opens a chat at the reply and labels pins. Pins stay on this device, per dashboard and profile; Hermes has no
//  pinned message of its own to share them with.
//

import Foundation

extension AppState {
    /// The dashboard in scope's pins, per profile: the one on screen's, or
    /// inside another combined dashboard's runtime scope, that one's.
    var pinnedRepliesByProfile: [String: [PinnedReply]] {
        get { pinnedRepliesByDashboard[Self.dashboardPreferenceBucket(activeDashboardID)] ?? [:] }
        set {
            let bucket = Self.dashboardPreferenceBucket(activeDashboardID)
            let kept = newValue.filter { !$0.value.isEmpty }
            pinnedRepliesByDashboard[bucket] = kept.isEmpty ? nil : kept
        }
    }

    /// The active profile's pinned replies, in the order they were pinned.
    var activePinnedReplies: [PinnedReply] {
        pinnedReplies(of: screenPinOwner)
    }

    /// The pins the overview lists: the profile in use's, or from another
    /// combined dashboard's chat opened in place, that chat's own (a pin of
    /// another of its chats would open on the dashboard on screen).
    func pinnedRepliesOverview(fromOpenChat: Bool) -> [PinnedReply] {
        if fromOpenChat, !chatOnScreenIsInScope { return openChatPinnedReplies }
        return activePinnedReplies
    }

    /// The owner of a pin the bar or the overview shows: the open chat's
    /// (another combined dashboard's chat keeps its own), else the screen's.
    private func owner(of pin: PinnedReply) -> PinnedReplyOwner? {
        [openChatPinOwner, screenPinOwner].first { owner in
            pinnedReplies(of: owner).contains { $0.id == pin.id }
        }
    }

    /// Whether replies in the open conversation can be pinned: a chat with
    /// an id, not a group room or the read-only saved copy.
    var canPinReplies: Bool {
        activeRoomSurface == nil
            && offlineChatPresentation == nil
            && !(activeSessionId ?? "").isEmpty
    }

    /// The open chat's pins, in the bar's order (oldest first, as the
    /// replies sit in the chat).
    var openChatPinnedReplies: [PinnedReply] {
        pinnedRepliesForOpenChat.pins
    }

    /// The transcript rows of the open chat that are pinned.
    var openChatPinnedMessageIDs: Set<String> {
        pinnedRepliesForOpenChat.messageIDs
    }

    /// The title saved with a pin made now: the chat's row's, or for another
    /// combined dashboard's chat (not in this dashboard's list), its own.
    private var openChatPinTitle: String {
        guard chatOnScreenIsInScope else { return activeSessionTitle }
        return activeChatSessionSummary?.title ?? activeSessionTitle
    }

    /// Pins the whole of `message` to the top of the open chat, or unpins
    /// it.
    func togglePinnedReply(_ message: ChatMessage) {
        guard canPinReplies, message.role == .assistant,
              message.content.contains(where: { !$0.isWhitespace }) else { return }
        let pins = openChatPinnedReplies
        if let existing = PinnedReplies.pin(for: message, in: pins, messages: messages) {
            unpinReply(existing)
            return
        }
        let pin = PinnedReply(
            sessionID: openChatPinIDs().store,
            message: message,
            chatTitle: openChatPinTitle
        )
        let owner = openChatPinOwner
        setPinnedReplies(pinnedReplies(of: owner) + [pin], of: owner)
        persistPinnedReplies()
    }

    /// Pins the selected `passage` of `message` (#1147), or unpins it when
    /// that passage is pinned already.
    func togglePinnedPassage(_ passage: String, of message: ChatMessage) {
        guard canPinReplies, message.role == .assistant,
              PinnedReply.normalizedPassage(passage) != nil else { return }
        if let existing = PinnedReplies.pin(
            forPassage: passage, of: message, in: openChatPinnedReplies, messages: messages
        ) {
            unpinReply(existing)
            return
        }
        pinPassage(passage, of: message)
    }

    /// Pins the selected `passage` of `message` unless it is pinned already.
    func pinPassage(_ passage: String, of message: ChatMessage) {
        guard canPinReplies, message.role == .assistant,
              PinnedReply.normalizedPassage(passage) != nil,
              PinnedReplies.pin(
                  forPassage: passage, of: message, in: openChatPinnedReplies, messages: messages
              ) == nil else { return }
        let pin = PinnedReply(
            sessionID: openChatPinIDs().store,
            message: message,
            chatTitle: openChatPinTitle,
            passage: passage
        )
        let owner = openChatPinOwner
        setPinnedReplies(pinnedReplies(of: owner) + [pin], of: owner)
        persistPinnedReplies()
    }

    /// Whether `passage` of the open chat's `messageID` is pinned.
    func isPassagePinned(_ passage: String, messageID: String) -> Bool {
        guard let message = messages.first(where: { $0.id == messageID }) else { return false }
        return PinnedReplies.pin(
            forPassage: passage, of: message, in: openChatPinnedReplies, messages: messages
        ) != nil
    }

    /// Names a pin for the bar and the list; a blank label clears it.
    func setPinnedReplyLabel(_ pin: PinnedReply, to label: String) {
        guard let owner = owner(of: pin) else { return }
        var stored = pinnedReplies(of: owner)
        guard let index = stored.firstIndex(where: { $0.id == pin.id }) else { return }
        let normalized = PinnedReply.normalizedLabel(label)
        guard stored[index].label != normalized else { return }
        stored[index].label = normalized
        setPinnedReplies(stored, of: owner)
        persistPinnedReplies()
    }

    func unpinReply(_ pin: PinnedReply) {
        guard let owner = owner(of: pin) else { return }
        setPinnedReplies(pinnedReplies(of: owner).filter { $0.id != pin.id }, of: owner)
        if pendingPinnedReplyReveal?.pin.id == pin.id { pendingPinnedReplyReveal = nil }
        persistPinnedReplies()
    }

    /// The pins of the open chat take the ids their rows have now: a reply
    /// pinned as it arrived gets its durable id from the reload, and a pin
    /// made before the chat had a row in the list moves to the row's id, so
    /// it still finds its chat once the runtime id is gone.
    func refreshOpenChatPinnedReplies() {
        let open = openChatPinnedReplies
        guard !open.isEmpty else { return }
        var refreshed = PinnedReplies.refreshed(open, in: messages) ?? open
        // Only this dashboard's rows: another combined dashboard's chat
        // isn't in its list, though one id can name chats on both.
        if chatOnScreenIsInScope, let rowID = activeChatSessionSummary?.id {
            refreshed = refreshed.map { pin in
                var moved = pin
                moved.sessionID = rowID
                return moved
            }
        }
        guard refreshed != open else { return }
        let byID = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.id, $0) })
        let owner = openChatPinOwner
        setPinnedReplies(pinnedReplies(of: owner).map { byID[$0.id] ?? $0 }, of: owner)
        persistPinnedReplies()
    }

    /// The title the overview shows for a pin's chat: the chat's current
    /// one while it is listed, else the one saved with the pin.
    func pinnedReplyChatTitle(_ pin: PinnedReply) -> String {
        // Another combined dashboard's pin: this dashboard's list isn't its
        // chat's, though one id can name chats on both.
        guard pinnedReplies(of: screenPinOwner).contains(where: { $0.id == pin.id }) else { return pin.chatTitle }
        let listed = sessions.first { session in
            session.id == pin.sessionID
                || session.storedSessionId == pin.sessionID
                || session.alternateIds.contains(pin.sessionID)
        }
        let title = listed?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? pin.chatTitle : title
    }

    /// A deleted chat's pinned replies go with it, under the dashboard and
    /// profile it was deleted in (the screen may have moved to another one
    /// since). `dashboard` is the dashboard's preference bucket, captured
    /// before the delete's await; nil is the dashboard in scope.
    func dropPinnedReplies(forDeleted session: SessionSummary, profile: String? = nil, dashboard: String? = nil) {
        let inScope = Self.dashboardPreferenceBucket(activeDashboardID)
        let bucket = dashboard ?? inScope
        // Its own ids, and an alternate one only while no other row lists
        // it: a pin made before the chat was listed may still be kept under
        // that runtime id, and another chat may share one. Another
        // dashboard's rows aren't on hand to tell, so its alternates stay.
        let own = [session.id] + [session.storedSessionId].compactMap { $0 }
        let unshared: [String]
        if bucket == inScope {
            let others = (sessions + cronSessions).filter { $0.id != session.id }
            unshared = session.alternateIds.filter { id in
                !others.contains { $0.id == id || $0.storedSessionId == id || $0.alternateIds.contains(id) }
            }
        } else {
            unshared = []
        }
        let ids = Set(own + unshared)
        let owner = PinnedReplyOwner(dashboard: bucket, profile: profile ?? activeProfile)
        let stored = pinnedReplies(of: owner)
        let remaining = stored.filter { pin in
            if ids.contains(pin.sessionID) { return false }
            // A runtime id Hermes confirmed as this chat's, in the profile
            // it was deleted in.
            guard bucket == inScope,
                  let durable = confirmedDurableSessionID(forRuntime: pin.sessionID, profile: owner.profile)
            else { return true }
            return !ids.contains(durable)
        }
        guard remaining.count != stored.count else { return }
        setPinnedReplies(remaining, of: owner)
        if let reveal = pendingPinnedReplyReveal,
           stored.contains(where: { $0.id == reveal.pin.id }),
           !remaining.contains(where: { $0.id == reveal.pin.id }) {
            pendingPinnedReplyReveal = nil
        }
        persistPinnedReplies()
    }

    /// A deleted profile's pinned replies go with it, so a profile given the
    /// same name later starts with none. `dashboard` as for a deleted chat.
    func forgetPinnedReplies(profile: String, dashboard: String? = nil) {
        let owner = PinnedReplyOwner(dashboard: dashboard ?? Self.dashboardPreferenceBucket(activeDashboardID), profile: profile)
        let stored = pinnedReplies(of: owner)
        guard !stored.isEmpty else { return }
        setPinnedReplies([], of: owner)
        if let reveal = pendingPinnedReplyReveal, stored.contains(where: { $0.id == reveal.pin.id }) {
            pendingPinnedReplyReveal = nil
        }
        persistPinnedReplies()
    }

    /// Whether the transcript on screen is the chat a reveal waits for. A
    /// reveal made in the open chat is checked too: another chat may have
    /// opened before it ran.
    func isShowingChat(for reveal: PinnedReplyReveal) -> Bool {
        isOpenChatsPin(reveal.pin)
    }

    /// Whether `pin` is one of the open chat's: kept under its dashboard
    /// and profile, and one of its ids (another combined dashboard's chat
    /// can share the id).
    private func isOpenChatsPin(_ pin: PinnedReply) -> Bool {
        guard canPinReplies,
              pinnedReplies(of: openChatPinOwner).contains(where: { $0.id == pin.id }) else { return false }
        return pinBelongs(pin, toOwnIDs: openChatPinIDs().own)
    }

    /// Opens the pin's chat (unless it's the open one) and scrolls to the
    /// reply.
    func showPinnedReply(_ pin: PinnedReply) {
        let chatIsOpen = isOpenChatsPin(pin)
        pendingPinnedReplyReveal = PinnedReplyReveal(pin: pin, opening: chatIsOpen ? nil : pin.sessionID)
        guard !chatIsOpen else { return }
        dismissSidebarDrawer()
        let listed = (sessions + cronSessions).contains { session in
            session.id == pin.sessionID
                || session.storedSessionId == pin.sessionID
                || session.alternateIds.contains(pin.sessionID)
        }
        if listed {
            requestOpenSession(pin.sessionID) { [weak self] _ in
                guard let self, self.pendingPinnedReplyReveal?.pin.id == pin.id else { return }
                self.pendingPinnedReplyReveal = nil
            }
        } else {
            // Older than any listed chat: the link route opens it and
            // refreshes the list, as content search does.
            openAppLink(.session(id: pin.sessionID))
        }
    }
}
