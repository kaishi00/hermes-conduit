//
//  AppState+BotOrder.swift
//  Conduit
//
//  The bots in the order the person sets on Bots Home (BotOrder): dragged
//  in the grid or from Reorder Bots. Every list of bots follows it: Bots
//  Home, New Group Chat's members, Mention a Bot and the widget.
//

import Foundation

extension AppState {
    /// `bots` in the person's order.
    func orderedBots(_ bots: [BotProfile]) -> [BotProfile] {
        botOrder.arrange(bots, name: \.name)
    }

    /// A portrait dropped before `target` (nil: at the end), among `shown`.
    func moveBot(_ moved: String, before target: String?, shown: [String]) {
        setBotOrder(botOrder.moving(moved, before: target, shown: shown))
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
}
