//
//  BotOrder.swift
//  Conduit
//
//  The order of the bots on Bots Home, set by dragging a portrait or from
//  Reorder Bots. Hermes keeps whether a bot is pinned, not where it sits,
//  so the order stays here, by profile name, and goes to other devices
//  through Sync across devices (`bots.order`). Until it's set the bots
//  follow Hermes' order (pinned, then recent activity). A bot the order
//  doesn't name yet (made since, here or elsewhere) goes at the end; a
//  hidden or deleted bot keeps its name in the order, so it comes back to
//  its place.
//
//  The same order keeps Bots Home's group chats, by room id, under a key
//  of its own (`roomStorageKey`, synced as `groups.order`): Hermes lists
//  rooms by activity and keeps no place for them either. Room ids match
//  exactly (the gateway's are case-sensitive), and a room the order
//  doesn't name yet goes first, where Hermes lists a room just made.
//

import Foundation
import SwiftUI // Array.move(fromOffsets:toOffset:)

struct BotOrder: Equatable {
    static let storageKey = "conduit.botOrder.v1"
    /// The group chats' order, by room id.
    static let roomStorageKey = "conduit.groupRoomOrder.v1"

    /// What the order holds: bots by profile name, matched in any case,
    /// with ones it doesn't name last; or rooms by id, matched exactly,
    /// with ones it doesn't name first.
    enum Kind: Equatable { case bots, rooms }

    private(set) var names: [String]
    let kind: Kind

    init(names: [String] = [], kind: Kind = .bots) {
        self.kind = kind
        var seen = Set<String>()
        let key: (String) -> String = kind == .rooms ? { $0 } : { $0.lowercased() }
        self.names = names.filter { !$0.isEmpty && seen.insert(key($0)).inserted }
    }

    init(defaults: UserDefaults, key: String = BotOrder.storageKey, kind: Kind = .bots) {
        self.init(names: defaults.stringArray(forKey: key) ?? [], kind: kind)
    }

    /// An empty order of the group chats.
    static var rooms: BotOrder { BotOrder(kind: .rooms) }

    func save(to defaults: UserDefaults, key: String = BotOrder.storageKey) {
        if names.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(names, forKey: key)
        }
    }

    var isEmpty: Bool { names.isEmpty }

    private func key(_ value: String) -> String { kind == .rooms ? value : value.lowercased() }
    private func same(_ a: String, _ b: String) -> Bool { key(a) == key(b) }

    /// `bots` in this order: the ones it names as it names them, and the
    /// rest in the order they came, after them (bots) or before them
    /// (rooms).
    func arrange<Bot>(_ bots: [Bot], name: (Bot) -> String) -> [Bot] {
        guard !names.isEmpty else { return bots }
        var place: [String: Int] = [:]
        for (index, value) in names.enumerated() { place[key(value)] = index }
        let ranked = bots.enumerated().map { offset, bot in
            let unnamed = kind == .rooms ? offset - bots.count : names.count + offset
            return (bot: bot, rank: place[key(name(bot))] ?? unnamed)
        }
        return ranked.sorted { $0.rank < $1.rank }.map(\.bot)
    }

    /// The order with every shown name in it: the ones it doesn't name yet
    /// where `arrange` shows them.
    private func filled(with shown: [String]) -> [String] {
        let missing = shown.filter { value in !names.contains(where: { same($0, value) }) }
        return kind == .rooms ? missing + names : names + missing
    }

    /// The order after `moved` is dropped before `target` (or at the end
    /// when `target` is nil), among the bots `shown` in their current
    /// order. Names the order already holds but that aren't shown (hidden
    /// or gone) keep their places relative to the rest.
    func moving(_ moved: String, before target: String?, shown: [String]) -> BotOrder {
        if let target, same(moved, target) { return self }
        // Every shown bot gets a place, so the order is total from now on.
        var full = filled(with: shown)
        full.removeAll { same($0, moved) }
        if let target, let index = full.firstIndex(where: { same($0, target) }) {
            full.insert(moved, at: index)
        } else if let last = shown.last(where: { !same($0, moved) }),
                  let index = full.firstIndex(where: { same($0, last) }) {
            full.insert(moved, at: index + 1)
        } else {
            full.append(moved)
        }
        return BotOrder(names: full, kind: kind)
    }

    /// The order after `moved` is dropped on `target` (nil: past the last
    /// one), whose place it takes, as an app does on the Home Screen:
    /// carried on, it goes after the one it lands on; carried back, before
    /// it. So two neighbours swap, where "before" left a drop on the next
    /// one where it was.
    func dropping(_ moved: String, onto target: String?, shown: [String]) -> BotOrder {
        guard let target, let from = shown.firstIndex(where: { same($0, moved) }),
              let to = shown.firstIndex(where: { same($0, target) }), from < to else {
            return moving(moved, before: target, shown: shown)
        }
        // Carried on: right after the target in the order itself, not before
        // whatever shows next, which (pinned bots show first) may sit
        // before the target in the order.
        var full = filled(with: shown)
        full.removeAll { same($0, moved) }
        guard let index = full.firstIndex(where: { same($0, target) }) else {
            return moving(moved, before: nil, shown: shown)
        }
        full.insert(moved, at: index + 1)
        return BotOrder(names: full, kind: kind)
    }

    /// The order after a List's `onMove` among `shown`.
    func moving(fromOffsets source: IndexSet, toOffset destination: Int, shown: [String]) -> BotOrder {
        var reordered = shown
        reordered.move(fromOffsets: source, toOffset: destination)
        // Unshown names keep their places: shown ones fill the shown slots.
        let full = filled(with: shown)
        let shownKeys = Set(shown.map(key))
        var queue = reordered[...]
        let merged = full.map { value -> String in
            guard shownKeys.contains(key(value)), let next = queue.popFirst() else { return value }
            return next
        }
        return BotOrder(names: merged, kind: kind)
    }
}
