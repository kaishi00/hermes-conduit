//
//  AppState+PinnedChatOrder.swift
//  Conduit
//
//  The Pinned section in the order the person sets (issue 1354): dragged
//  in place in the V2 Chats list, or from Reorder pinned chats in a pinned
//  chat's touch-and-hold menu. The order itself is PinnedChatOrder.
//

import Foundation
import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    /// `rows` with each profile's pinned chats in its order.
    func arrangePinned<Row>(_ rows: [Row], session: (Row) -> SessionSummary) -> [Row] {
        let order = pinnedChatOrder
        guard !order.isEmpty else { return rows }
        return PinnedChatOrder.arrange(
            rows,
            profile: { rowProfile(session($0)) },
            ids: { SessionPinSync.pinIDs(for: session($0)) },
            order: { order.ids(profile: $0) },
            // All grouped by profile splits the rows per profile, each in
            // its own order: the mix is for the mixed section only.
            mixed: allProfilesGroupsByProfile ? [] : order.mixed
        )
    }

    func arrangePinnedNodes(_ nodes: [SessionNesting.Node]) -> [SessionNesting.Node] {
        arrangePinned(nodes, session: \.session)
    }

    /// A drag in a Pinned section: `shown` is every pinned chat that
    /// section shows, as they were shown, moved as a List's `onMove`
    /// reports it counted among them. A pinned chat that can't move (a
    /// saved row) is among them, so it keeps its place. In All's mixed
    /// Pinned section the chat also stays where it was dropped among the
    /// other profiles' (issue 1486).
    func movePinnedChats(_ shown: [SessionSummary], fromOffsets source: IndexSet, toOffset destination: Int) {
        let order = pinnedChatOrder
        let shownProfiles = Set(shown.map { rowProfile($0) })
        let mixes = shownProfiles.count > 1
        if mixes {
            setPinnedChatMixedOrder(PinnedChatOrder.mixedOrder(
                moving: shown,
                fromOffsets: source,
                toOffset: destination,
                profile: { rowProfile($0) },
                pinID: { SessionPinSync.pinID(for: $0) },
                ids: { SessionPinSync.pinIDs(for: $0) },
                mixed: order.mixed
            ))
        }
        let orders = PinnedChatOrder.orders(
            moving: shown,
            fromOffsets: source,
            toOffset: destination,
            profile: { rowProfile($0) },
            pinID: { SessionPinSync.pinID(for: $0) },
            ids: { SessionPinSync.pinIDs(for: $0) },
            order: { order.ids(profile: $0) },
            // In the mix every profile shown keeps the order it was shown
            // in, so later activity doesn't move a chat dropped among its.
            alsoSaving: mixes ? shownProfiles : []
        )
        for (profile, ids) in orders {
            setPinnedChatOrder(ids, profile: profile)
        }
    }

    /// The pinned chats Reorder pinned chats lists for `profile`, in the
    /// Pinned section's order: its pinned cron runs and chats, as the
    /// Chats list's All shows them.
    func pinnedChatsForOrdering(profile: String) -> [SessionSummary] {
        let rows = chatListCronSessions + chatListSessions
        var seen = Set<String>()
        let pinned = rows.filter { session in
            !session.isArchived && isSessionPinned(session)
                && rowProfile(session) == profile
                && seen.insert(SessionPinSync.pinID(for: session)).inserted
        }
        return arrangePinned(pinned, session: { $0 })
    }

    /// The profile in use's Pinned order, for Sync across devices. Each
    /// profile's ledger is its own, as Hermes keeps its pins per profile.
    var pinnedChatOrderSlot: SyncedPreferenceSlot {
        SyncedPreferenceSlot(
            key: "chats.pinned_order",
            read: { [weak self] in
                guard let self else { return nil }
                let ids = self.pinnedChatOrder.ids(profile: self.activeProfile)
                return ids.isEmpty ? nil : ids
            },
            write: { [weak self] value in
                guard let self else { return }
                self.setPinnedChatOrder(value as? [String] ?? [], profile: self.activeProfile)
            }
        )
    }
}

extension AppState {
    // MARK: - Pinning chats, and the saved order of chats, bots and rooms

    func isSessionPinned(_ session: SessionSummary) -> Bool {
        let ids = SessionPinSync.pinIDs(for: session)
        let owner = rowProfile(session)
        if owner != activeProfile {
            // Another profile's row in All: Hermes' flag when its listing
            // has one, else the pins this phone keeps for that profile.
            // A pin Hermes refused stays on this phone, over the listing.
            let kept = (pinnedSessionIDsByProfile[owner] ?? []).contains { ids.contains($0) }
            if kept, sessionPinSync.isPhoneOnly(pinID: pinID(for: session), profile: owner) { return true }
            return session.isPinned ?? kept
        }
        if pinnedSessionIDs.contains(where: { ids.contains($0) }) { return true }
        guard let saved = savedChatListForActiveScope else { return false }
        // A kept row is listed only because it is pinned.
        if saved.isKeptRow(session) { return true }
        // A dashboard switch starts the phone's pins over until Hermes'
        // arrive with its list; the saved list keeps its own meanwhile.
        guard pinnedSessionIDs.isEmpty, saved.isShowingSavedRows else { return false }
        return saved.showedAsPinned(session)
    }

    func toggleSessionPinned(_ session: SessionSummary) {
        let profile = rowProfile(session)
        guard sessionBelongsToProfile(session, profile: profile) else { return }
        let pinned = !isSessionPinned(session)
        setLocalPin(session, pinned: pinned, profile: profile)
        if profile != activeProfile {
            updateAllProfilesCatalogRow(session) { $0.isPinned = pinned }
        }
        let pinID = pinID(for: session)
        guard let bridge = dashboardTicketBridge,
              sessionPinSync.supportsPins(profile: profile, host: bridge.baseURL) else { return }
        if sessionPinSync.isPhoneOnly(pinID: pinID, profile: profile) {
            // Hermes didn't take this chat's pin before: an unpin stays on
            // the phone, with the mark keeping listings off it. A pin asks
            // Hermes again; another failure marks it again.
            guard pinned else { return }
            sessionPinSync.clearPhoneOnly(pinID: pinID, profile: profile)
            persistHostPinSyncState()
        }
        let generation = sessionPinSync.recordWrite(pinID: pinID, profile: profile, pinned: pinned)
        enqueueHostPinWrite { [weak self] in
            guard let self, self.sessionPinSync.host == bridge.baseURL else { return }
            do {
                try await self.sendHostPin(session.id, pinned: pinned, profile: profile, using: bridge)
            } catch {
                // Hermes refused the chat (old local history only the
                // computer running it may change) or the write failed. The
                // pin stays as the person set it, on the phone only, rather
                // than flip back; the notice says why. Pinning it again asks
                // Hermes again.
                sessionCatalogLog.notice("Pin kept on phone: \(LogRedaction.describing(error), privacy: .public)")
                guard self.sessionPinSync.host == bridge.baseURL,
                      self.keepPinOnPhone(pinID, profile: profile, generation: generation, pinned: pinned),
                      profile == self.activeProfile else { return }
                self.showPinSyncNotice(for: error, pinned: pinned)
            }
        }
    }

    func setLocalPin(_ session: SessionSummary, pinned: Bool, profile: String) {
        let pinID = pinID(for: session)
        var pins = pinnedSessionIDsByProfile[profile] ?? []
        if pinned {
            pins.removeAll { $0 == pinID }
            pins.append(pinID)
        } else {
            let ids = SessionPinSync.pinIDs(for: session)
            pins.removeAll { ids.contains($0) }
        }
        storePins(pins, profile: profile)
        publishWidgetSnapshot()
    }

    /// Saves a profile's Pinned order (issue 1354): the chats' pin ids,
    /// top first.
    func setPinnedChatOrder(_ ids: [String], profile: String) {
        var order = pinnedChatOrder
        order.set(ids, profile: profile)
        guard order != pinnedChatOrder else { return }
        pinnedChatOrder = order
        order.save(to: defaults)
    }

    /// Saves the bots' order (BotOrder), set here or from Sync across
    /// devices.
    func setBotOrder(_ order: BotOrder) {
        guard order != botOrder else { return }
        botOrder = order
        order.save(to: defaults)
        publishWidgetSnapshot()
    }

    /// Saves the group chats' order, set on Bots Home or from Sync across
    /// devices.
    func setGroupRoomOrder(_ order: BotOrder) {
        let order = order.kind == .rooms ? order : BotOrder(names: order.names, kind: .rooms)
        guard order != groupRoomOrder else { return }
        groupRoomOrder = order
        order.save(to: defaults, key: BotOrder.roomStorageKey)
    }

    /// Saves where All's mixed Pinned section holds each profile's chats
    /// (issue 1486), on this device only.
    func setPinnedChatMixedOrder(_ keys: [String]) {
        var order = pinnedChatOrder
        order.setMixed(keys)
        guard order != pinnedChatOrder else { return }
        pinnedChatOrder = order
        order.save(to: defaults)
    }

    /// An unpinned chat leaves the order, so pinning it again puts it on top.
    func dropFromPinnedChatOrder(_ ids: Set<String>, profile: String) {
        var order = pinnedChatOrder
        order.drop(ids, profile: profile)
        guard order != pinnedChatOrder else { return }
        pinnedChatOrder = order
        order.save(to: defaults)
    }
}
