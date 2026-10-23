//
//  AppState+PinnedReplies.swift
//  Conduit
//
//  Replies pinned to the top of their chat (#918): Pin reply or, for just
//  the selected passage, Pin in a reply's long-press menu (#1147), the
//  bar over the open chat that cycles through its pins, and the Chats
//  list's overview of every pin, which opens a chat at the reply and
//  labels pins. Pins stay on this device, per profile; Hermes has no
//  pinned message of its own to share them with.
//

import Foundation

extension AppState {
    /// The active profile's pinned replies, in the order they were pinned.
    var activePinnedReplies: [PinnedReply] {
        pinnedRepliesByProfile[activeProfile] ?? []
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
        let session = activeChatSessionSummary
        let pin = PinnedReply(
            sessionID: openChatPinIDs().store,
            message: message,
            chatTitle: session?.title ?? activeSessionTitle
        )
        var stored = activePinnedReplies
        stored.append(pin)
        pinnedRepliesByProfile[activeProfile] = stored
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
            chatTitle: activeChatSessionSummary?.title ?? activeSessionTitle,
            passage: passage
        )
        var stored = activePinnedReplies
        stored.append(pin)
        pinnedRepliesByProfile[activeProfile] = stored
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
        let profile = activeProfile
        var stored = pinnedRepliesByProfile[profile] ?? []
        guard let index = stored.firstIndex(where: { $0.id == pin.id }) else { return }
        let normalized = PinnedReply.normalizedLabel(label)
        guard stored[index].label != normalized else { return }
        stored[index].label = normalized
        pinnedRepliesByProfile[profile] = stored
        persistPinnedReplies()
    }

    func unpinReply(_ pin: PinnedReply) {
        let profile = activeProfile
        let stored = pinnedRepliesByProfile[profile] ?? []
        guard stored.contains(where: { $0.id == pin.id }) else { return }
        let remaining = stored.filter { $0.id != pin.id }
        pinnedRepliesByProfile[profile] = remaining.isEmpty ? nil : remaining
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
        if let rowID = activeChatSessionSummary?.id {
            refreshed = refreshed.map { pin in
                var moved = pin
                moved.sessionID = rowID
                return moved
            }
        }
        guard refreshed != open else { return }
        let byID = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.id, $0) })
        pinnedRepliesByProfile[activeProfile] = activePinnedReplies.map { byID[$0.id] ?? $0 }
        persistPinnedReplies()
    }

    /// The title the overview shows for a pin's chat: the chat's current
    /// one while it is listed, else the one saved with the pin.
    func pinnedReplyChatTitle(_ pin: PinnedReply) -> String {
        let listed = sessions.first { session in
            session.id == pin.sessionID
                || session.storedSessionId == pin.sessionID
                || session.alternateIds.contains(pin.sessionID)
        }
        let title = listed?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? pin.chatTitle : title
    }

    /// A deleted chat's pinned replies go with it, under the profile it was
    /// deleted in (the screen may have moved to another one since).
    func dropPinnedReplies(forDeleted session: SessionSummary, profile: String? = nil) {
        // Its own ids, and an alternate one only while no other row lists
        // it: a pin made before the chat was listed may still be kept under
        // that runtime id, and another chat may share one.
        let own = [session.id] + [session.storedSessionId].compactMap { $0 }
        let others = (sessions + cronSessions).filter { $0.id != session.id }
        let unshared = session.alternateIds.filter { id in
            !others.contains { $0.id == id || $0.storedSessionId == id || $0.alternateIds.contains(id) }
        }
        let ids = Set(own + unshared)
        let profile = profile ?? activeProfile
        let stored = pinnedRepliesByProfile[profile] ?? []
        let remaining = stored.filter { pin in
            if ids.contains(pin.sessionID) { return false }
            // A runtime id Hermes confirmed as this chat's, in the profile
            // it was deleted in.
            guard let durable = confirmedDurableSessionID(forRuntime: pin.sessionID, profile: profile)
            else { return true }
            return !ids.contains(durable)
        }
        guard remaining.count != stored.count else { return }
        pinnedRepliesByProfile[profile] = remaining.isEmpty ? nil : remaining
        if profile == activeProfile, let reveal = pendingPinnedReplyReveal,
           !remaining.contains(where: { $0.id == reveal.pin.id }) {
            pendingPinnedReplyReveal = nil
        }
        persistPinnedReplies()
    }

    /// A deleted profile's pinned replies go with it, so a profile given the
    /// same name later starts with none.
    func forgetPinnedReplies(profile: String) {
        guard pinnedRepliesByProfile[profile] != nil else { return }
        pinnedRepliesByProfile.removeValue(forKey: profile)
        if profile == activeProfile { pendingPinnedReplyReveal = nil }
        persistPinnedReplies()
    }

    /// Whether the transcript on screen is the chat a reveal waits for.
    func isShowingChat(for reveal: PinnedReplyReveal) -> Bool {
        guard reveal.opening != nil else { return true }
        guard canPinReplies else { return false }
        return pinBelongs(reveal.pin, toOwnIDs: openChatPinIDs().own)
    }

    /// Opens the pin's chat (unless it's the open one) and scrolls to the
    /// reply.
    func showPinnedReply(_ pin: PinnedReply) {
        let chatIsOpen = canPinReplies && pinBelongs(pin, toOwnIDs: openChatPinIDs().own)
        pendingPinnedReplyReveal = PinnedReplyReveal(pin: pin, opening: chatIsOpen ? nil : pin.sessionID)
        guard !chatIsOpen else { return }
        dismissSidebarDrawer()
        let listed = (sessions + cronSessions).contains { session in
            session.id == pin.sessionID
                || session.storedSessionId == pin.sessionID
                || session.alternateIds.contains(pin.sessionID)
        }
        if listed {
            requestOpenSession(pin.sessionID) { [weak self] in
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
