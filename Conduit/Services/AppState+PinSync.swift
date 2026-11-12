//
//  AppState+PinSync.swift
//  Conduit
//
//  Pinned chats kept on the phone and on the host (SessionPinSync), and
//  the replies pinned in a chat. Moved out of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Pins kept on the phone and on the host, and pinned replies

    func restorePinnedSessions(for profile: String) {
        pinnedSessionIDs = pinnedSessionIDsByProfile[profile] ?? []
    }

    func persistPinnedSessions() {
        guard let data = try? JSONEncoder().encode(pinnedSessionIDsByProfile) else { return }
        defaults.set(data, forKey: pinnedSessionIDsByProfileKey)
    }

    func persistPinnedReplies() {
        PinnedRepliesRevision.value &+= 1
        guard let data = try? JSONEncoder().encode(pinnedRepliesByProfile) else { return }
        defaults.set(data, forKey: pinnedRepliesByProfileKey)
    }

    /// The open chat's pinned replies and the rows they show, worked out
    /// once per transcript, pin or catalog change: the rows read them on
    /// every publish, streaming included.
    var pinnedRepliesForOpenChat: (pins: [PinnedReply], messageIDs: Set<String>) {
        guard canPinReplies, let active = activeSessionId else { return ([], []) }
        let stored = pinnedRepliesByProfile[activeProfile] ?? []
        guard !stored.isEmpty else { return ([], []) }
        let key = OpenChatPinnedRepliesKey(
            profile: activeProfile,
            active: active,
            stored: stored,
            transcriptRevision: chatTranscriptRevision,
            sessionsRevision: sessionsRevision,
            cronSessionsRevision: cronSessionsRevision
        )
        if let cached = openChatPinnedRepliesCache, cached.key == key { return cached.value }
        let own = openChatPinIDs().own
        let pins = PinnedReplies.barOrder(stored.filter { pinBelongs($0, toOwnIDs: own) }, in: messages)
        let value = (pins: pins, messageIDs: PinnedReplies.pinnedMessageIDs(pins, in: messages))
        openChatPinnedRepliesCache = (key, value)
        return value
    }

    /// The id a pin made now is kept under (the chat's row id, else its
    /// durable id, else the open id), and every id the open chat is known
    /// by. Never its row's alternate ids, which another row can share, so
    /// another chat's pins never show in this one's bar.
    func openChatPinIDs() -> (store: String, own: Set<String>) {
        guard let active = activeSessionId, !active.isEmpty else { return ("", []) }
        let durable = confirmedDurableSessionID(forRuntime: active)
        let summary = activeChatSessionSummary
        var own = chatOwnSessionIDs(for: active)
        own.insert(active)
        if let durable { own.insert(durable) }
        if let summary {
            own.insert(summary.id)
            if let stored = summary.storedSessionId { own.insert(stored) }
        }
        return (summary?.id ?? durable ?? active, own)
    }

    /// Whether a pin belongs to the chat known by `ownIDs`: its id is one
    /// of them, or a runtime id Hermes has since confirmed as one.
    func pinBelongs(_ pin: PinnedReply, toOwnIDs ownIDs: Set<String>) -> Bool {
        if ownIDs.contains(pin.sessionID) { return true }
        guard let durable = confirmedDurableSessionID(forRuntime: pin.sessionID) else { return false }
        return ownIDs.contains(durable)
    }

    /// Signed out or reset: pinned replies belong to the chats that went.
    func clearPinnedReplies() {
        pinnedRepliesByProfile = [:]
        pendingPinnedReplyReveal = nil
        defaults.removeObject(forKey: pinnedRepliesByProfileKey)
    }

    func pinID(for session: SessionSummary) -> String {
        SessionPinSync.pinID(for: session)
    }

    func persistHostPinSyncState() {
        if sessionPinSync.adopted.isEmpty {
            defaults.removeObject(forKey: hostPinsAdoptedKey)
        } else {
            defaults.set(sessionPinSync.adopted.sorted(), forKey: hostPinsAdoptedKey)
        }
        if sessionPinSync.phoneOnly.isEmpty {
            defaults.removeObject(forKey: phoneOnlyPinsKey)
        } else {
            defaults.set(sessionPinSync.phoneOnly.sorted(), forKey: phoneOnlyPinsKey)
        }
    }

    /// Hermes didn't take this chat's pin change, so the pin stays as set,
    /// on the phone, instead of flipping back. A listing that landed while
    /// a slow failure was in flight may already have flipped it; the
    /// failed write's value is put back. Returns false when a newer write
    /// replaced this one, which then decides.
    @discardableResult
    func keepPinOnPhone(_ pinID: String, profile: String, generation: UInt64, pinned: Bool) -> Bool {
        guard sessionPinSync.keepOnPhone(pinID: pinID, profile: profile, generation: generation) else { return false }
        persistHostPinSyncState()
        let pins = pinnedSessionIDsByProfile[profile] ?? []
        if pinned, !pins.contains(pinID) {
            storePins(pins + [pinID], profile: profile)
            publishWidgetSnapshot()
        } else if !pinned, pins.contains(pinID) {
            storePins(pins.filter { $0 != pinID }, profile: profile)
            publishWidgetSnapshot()
        }
        return true
    }

    /// Says for a moment that a pin change stayed on this phone, and why.
    func showPinSyncNotice(for error: Error, pinned: Bool) {
        publishNotice(PinSyncNotice(error: error, pinned: pinned))
    }

    func dismissPinSyncNotice(_ id: UUID) {
        guard pinSyncNotice?.id == id else { return }
        pinSyncNotice = nil
    }

    /// The phone's pins are gone, so no host owns them any more: the next
    /// listing takes the host's pins as they are.
    func resetHostPins() {
        sessionPinSync.reset()
        defaults.removeObject(forKey: hostPinsAdoptedKey)
        defaults.removeObject(forKey: phoneOnlyPinsKey)
    }

    /// Folds Hermes' `pinned` flag from rows fetched just now into the
    /// profile's pins, and sends phone-only pins up the first time the host
    /// reports the flag (#555). A host without the flag changes nothing.
    func applyHostPins(_ listed: [SessionSummary], profile: String, using bridge: DashboardTicketBridge) {
        sessionPinSync.setHost(bridge.baseURL)
        let current = pinnedSessionIDsByProfile[profile] ?? []
        let adoptedBefore = sessionPinSync.adopted
        let outcome = sessionPinSync.reconcile(pins: current, listed: listed, profile: profile)
        if sessionPinSync.adopted != adoptedBefore { persistHostPinSyncState() }
        if outcome.pins != current { storePins(outcome.pins, profile: profile) }
        for upload in outcome.uploads {
            let generation = sessionPinSync.recordWrite(pinID: upload.pinID, profile: profile, pinned: true)
            enqueueHostPinWrite { [weak self] in
                // Another host's sync starts over; nothing here is its.
                guard let self, self.sessionPinSync.host == bridge.baseURL else { return }
                do {
                    try await self.sendHostPin(upload.hostID, pinned: true, profile: profile, using: bridge)
                    guard self.sessionPinSync.host == bridge.baseURL else { return }
                    self.sessionPinSync.uploadSucceeded(pinID: upload.pinID, profile: profile)
                } catch let error where SessionMutationIdentity.isRefusal(error) {
                    sessionCatalogLog.notice("Pin upload kept on phone: \(LogRedaction.describing(error), privacy: .public)")
                    guard self.sessionPinSync.host == bridge.baseURL else { return }
                    self.keepPinOnPhone(upload.pinID, profile: profile, generation: generation, pinned: true)
                } catch DashboardTicketBridgeError.http(status: let status, detail: _) where status == 404 || status == 410 {
                    // The chat is gone from the host; so is its pin.
                    guard self.sessionPinSync.host == bridge.baseURL,
                          self.sessionPinSync.discardWrite(pinID: upload.pinID, profile: profile, generation: generation)
                    else { return }
                    let pins = self.pinnedSessionIDsByProfile[profile] ?? []
                    if pins.contains(upload.pinID) {
                        self.storePins(pins.filter { $0 != upload.pinID }, profile: profile)
                        self.publishWidgetSnapshot()
                    }
                } catch {
                    // Its pending value holds off a resend until it lapses.
                    sessionCatalogLog.notice("Pin upload failed: \(LogRedaction.describing(error), privacy: .public)")
                }
            }
        }
    }

    /// Pin writes go out one at a time, in the order they were made, so the
    /// newest one for a chat is the one Hermes keeps.
    func enqueueHostPinWrite(_ write: @escaping @MainActor () async -> Void) {
        let previous = hostPinWriteChain
        hostPinWriteChain = Task { @MainActor in
            await previous?.value
            await write()
        }
    }

    func storePins(_ pins: [String], profile: String) {
        let unpinned = Set(pinnedSessionIDsByProfile[profile] ?? []).subtracting(pins)
        if !unpinned.isEmpty { dropFromPinnedChatOrder(unpinned, profile: profile) }
        pinnedSessionIDsByProfile[profile] = pins
        if profile == activeProfile { pinnedSessionIDs = pins }
        persistPinnedSessions()
    }

    /// Writes Hermes' pin flag, which Desktop shows and changes too.
    func sendHostPin(_ hostID: String, pinned: Bool, profile: String, using bridge: DashboardTicketBridge) async throws {
        try await sendSessionMutation(hostID, body: ["pinned": pinned], profile: profile, bridge: bridge)
    }

    // MARK: - Pins kept on the phone and on the host, and pinned replies

    /// `unpinOnHost`: also clear Hermes' flag, so a chat restored later
    /// doesn't come back pinned (an archived row keeps its flag there).
    func removePinnedState(for session: SessionSummary, unpinOnHost: Bool = false) {
        let profile = activeProfile
        let wasPinned = isSessionPinned(session)
        let ids = SessionPinSync.pinIDs(for: session)
        pinnedSessionIDs.removeAll { ids.contains($0) }
        pinnedSessionIDsByProfile[profile] = pinnedSessionIDs
        persistPinnedSessions()
        dropFromPinnedChatOrder(ids, profile: profile)
        let pinID = pinID(for: session)
        if !unpinOnHost, sessionPinSync.clearPhoneOnly(pinID: pinID, profile: profile) {
            // Deleted: nothing left for the mark to protect.
            persistHostPinSyncState()
        }
        // An archived phone-only chat keeps its mark, so listings leave the
        // removal be.
        guard unpinOnHost, wasPinned, let bridge = dashboardTicketBridge,
              sessionPinSync.supportsPins(profile: profile, host: bridge.baseURL),
              !sessionPinSync.isPhoneOnly(pinID: pinID, profile: profile) else { return }
        let generation = sessionPinSync.recordWrite(pinID: pinID, profile: profile, pinned: false)
        enqueueHostPinWrite { [weak self] in
            guard let self, self.sessionPinSync.host == bridge.baseURL else { return }
            do {
                try await self.sendHostPin(session.id, pinned: false, profile: profile, using: bridge)
            } catch let error where SessionMutationIdentity.isRefusal(error) {
                sessionCatalogLog.notice("Pin clear kept on phone: \(LogRedaction.describing(error), privacy: .public)")
                guard self.sessionPinSync.host == bridge.baseURL else { return }
                self.keepPinOnPhone(pinID, profile: profile, generation: generation, pinned: false)
            } catch {
                sessionCatalogLog.notice("Pin clear failed: \(LogRedaction.describing(error), privacy: .public)")
            }
        }
    }
}
