//
//  AppState+PinnedChatOrder.swift
//  Conduit
//
//  The Pinned section in the order the person sets (issue 1354): dragged
//  in place in the V2 Chats list, or from Reorder pinned chats in a pinned
//  chat's touch-and-hold menu. The order itself is PinnedChatOrder.
//

import Foundation

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
