//
//  AppState+BotOrder.swift
//  Conduit
//
//  The bots in the order the person sets on Bots Home (BotOrder): dragged
//  in the grid or from Reorder Bots. Every list of bots follows it: Bots
//  Home, New Group Chat's members, Mention a Bot and the widget. The group
//  chats keep an order of their own the same way, by room id: dragged on
//  Bots Home or from Reorder Group Chats.
//

import Foundation

extension AppState {
    /// `bots` in the person's order.
    /// Pinned bots first, as Hermes Desktop lists them, each group in the
    /// person's order (Eric 2026-11-04: pinning did nothing once he had
    /// dragged the bots into an order).
    func orderedBots(_ bots: [BotProfile]) -> [BotProfile] {
        let arranged = botOrder.arrange(bots, name: \.name)
        return arranged.filter(\.isPinned) + arranged.filter { !$0.isPinned }
    }

    /// A portrait dropped before `target` (nil: at the end), among `shown`.
    func moveBot(_ moved: String, before target: String?, shown: [String]) {
        setBotOrder(botOrder.moving(moved, before: target, shown: shown))
    }

    /// A portrait dropped on `target`'s (nil: past the last one), whose
    /// place it takes (BotOrder.dropping).
    func dropBot(_ moved: String, onto target: String?, shown: [String]) {
        setBotOrder(botOrder.dropping(moved, onto: target, shown: shown))
    }

    /// Reorder Bots' list moved a row.
    func moveBots(fromOffsets source: IndexSet, toOffset destination: Int, shown: [String]) {
        setBotOrder(botOrder.moving(fromOffsets: source, toOffset: destination, shown: shown))
    }

    /// The bots' order for Sync across devices. The roster is the gateway's,
    /// so every profile's copy holds the same list.
    var botOrderSlot: SyncedPreferenceSlot {
        SyncedPreferenceSlot(
            key: "bots.order",
            read: { [weak self] in
                guard let self, !self.botOrder.isEmpty else { return nil }
                return self.botOrder.names
            },
            write: { [weak self] value in
                guard let self else { return }
                self.setBotOrder(BotOrder(names: value as? [String] ?? []))
            }
        )
    }

    /// A room's tile dropped before `target` (nil: at the end), among `shown`.
    func moveGroupRoom(_ moved: String, before target: String?, shown: [String]) {
        setGroupRoomOrder(groupRoomOrder.moving(moved, before: target, shown: shown))
    }

    /// A room's tile dropped on `target`'s (nil: past the last one): it takes
    /// that tile's place, as an app does on the Home Screen, so a tile
    /// carried further on goes after the one it lands on, and one carried
    /// back goes before it. Before, it always went before, so a tile
    /// dropped on its neighbour on the right stayed put.
    func dropGroupRoom(_ moved: String, onto target: String?, shown: [String]) {
        setGroupRoomOrder(groupRoomOrder.dropping(moved, onto: target, shown: shown))
    }

    /// Reorder Group Chats' list moved a row.
    func moveGroupRooms(fromOffsets source: IndexSet, toOffset destination: Int, shown: [String]) {
        setGroupRoomOrder(groupRoomOrder.moving(fromOffsets: source, toOffset: destination, shown: shown))
    }

    /// The group chats' order for Sync across devices. Rooms are the
    /// gateway's, so every profile's copy holds the same list.
    var groupRoomOrderSlot: SyncedPreferenceSlot {
        SyncedPreferenceSlot(
            key: "groups.order",
            read: { [weak self] in
                guard let self, !self.groupRoomOrder.isEmpty else { return nil }
                return self.groupRoomOrder.names
            },
            write: { [weak self] value in
                guard let self else { return }
                self.setGroupRoomOrder(BotOrder(names: value as? [String] ?? [], kind: .rooms))
            }
        )
    }
}

/// Group Settings asked for from a room's tile on Bots Home, which opens the
/// room first. It counts for a short while only, so a room opened much later
/// (the open failed, or Hermes keeps no settings) doesn't pop its settings.
struct GroupSettingsRequest: Equatable {
    let roomID: String
    var at = Date()

    static let lifetime: TimeInterval = 15

    /// Whether the open room's screen shows the settings now.
    func shows(openRoomID: String?, canEdit: Bool, now: Date = Date()) -> Bool {
        openRoomID == roomID && canEdit && now.timeIntervalSince(at) < Self.lifetime
    }
}
