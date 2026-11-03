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

import Foundation

struct BotOrder: Equatable {
    static let storageKey = "conduit.botOrder.v1"

    private(set) var names: [String]

    init(names: [String] = []) {
        var seen = Set<String>()
        self.names = names.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    init(defaults: UserDefaults) {
        self.init(names: defaults.stringArray(forKey: Self.storageKey) ?? [])
    }

    func save(to defaults: UserDefaults) {
        if names.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else {
            defaults.set(names, forKey: Self.storageKey)
        }
    }

    var isEmpty: Bool { names.isEmpty }

    /// `bots` in this order: the ones it names first, as it names them,
    /// then the rest in the order they came.
    func arrange<Bot>(_ bots: [Bot], name: (Bot) -> String) -> [Bot] {
        guard !names.isEmpty else { return bots }
        var place: [String: Int] = [:]
        for (index, value) in names.enumerated() { place[value.lowercased()] = index }
        let ranked = bots.enumerated().map { offset, bot in
            (bot: bot, rank: place[name(bot).lowercased()] ?? names.count + offset)
        }
        return ranked.sorted { $0.rank < $1.rank }.map(\.bot)
    }

    /// The order after `moved` is dropped before `target` (or at the end
    /// when `target` is nil), among the bots `shown` in their current
    /// order. Names the order already holds but that aren't shown (hidden
    /// or gone) keep their places relative to the rest.
    func moving(_ moved: String, before target: String?, shown: [String]) -> BotOrder {
        guard moved.caseInsensitiveCompare(target ?? "") != .orderedSame else { return self }
        // Every shown bot gets a place, so the order is total from now on.
        var full = names
        for value in shown where !full.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
            full.append(value)
        }
        full.removeAll { $0.caseInsensitiveCompare(moved) == .orderedSame }
        if let target, let index = full.firstIndex(where: { $0.caseInsensitiveCompare(target) == .orderedSame }) {
            full.insert(moved, at: index)
        } else if let last = shown.last(where: { $0.caseInsensitiveCompare(moved) != .orderedSame }),
                  let index = full.firstIndex(where: { $0.caseInsensitiveCompare(last) == .orderedSame }) {
            full.insert(moved, at: index + 1)
        } else {
            full.append(moved)
        }
        return BotOrder(names: full)
    }

    /// The order after a List's `onMove` among `shown`.
    func moving(fromOffsets source: IndexSet, toOffset destination: Int, shown: [String]) -> BotOrder {
        var reordered = shown
        reordered.move(fromOffsets: source, toOffset: destination)
        // Unshown names keep their places: shown ones fill the shown slots.
        var full = names
        for value in shown where !full.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
            full.append(value)
        }
        let shownKeys = Set(shown.map { $0.lowercased() })
        var queue = reordered[...]
        let merged = full.map { value -> String in
            guard shownKeys.contains(value.lowercased()), let next = queue.popFirst() else { return value }
            return next
        }
        return BotOrder(names: merged)
    }
}
