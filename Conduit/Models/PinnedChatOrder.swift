//
//  PinnedChatOrder.swift
//  Conduit
//
//  The order of the Pinned section (issue 1354). Hermes keeps whether a
//  chat is pinned, not where it sits, so the order stays here, per profile,
//  under each chat's pin id (its lineage root, so a compacted chat keeps its
//  place). Until a profile's pins are reordered they follow recent activity
//  as before. A pinned chat the order doesn't name yet (pinned since, here
//  or on another device) goes on top. All's mixed Pinned section also keeps
//  where each profile's chats sit among the others' (issue 1486), on this
//  device only, like All's other settings.
//

import SwiftUI

struct PinnedChatOrder: Equatable {
    static let storageKey = "conduit.pinnedChatOrderByProfile.v1"
    static let mixedStorageKey = "conduit.pinnedChatOrderAllProfiles.v1"

    private(set) var idsByProfile: [String: [String]]
    /// All's mixed Pinned section, top first: each chat as `key(profile:id:)`.
    private(set) var mixed: [String]

    init(idsByProfile: [String: [String]] = [:], mixed: [String] = []) {
        self.idsByProfile = idsByProfile.filter { !$0.value.isEmpty }
        self.mixed = Self.unique(mixed)
    }

    init(defaults: UserDefaults) {
        let stored = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
        self.init(idsByProfile: stored, mixed: defaults.stringArray(forKey: Self.mixedStorageKey) ?? [])
    }

    func save(to defaults: UserDefaults) {
        if idsByProfile.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(idsByProfile) {
            defaults.set(data, forKey: Self.storageKey)
        }
        if mixed.isEmpty {
            defaults.removeObject(forKey: Self.mixedStorageKey)
        } else {
            defaults.set(mixed, forKey: Self.mixedStorageKey)
        }
    }

    var isEmpty: Bool { idsByProfile.isEmpty && mixed.isEmpty }

    /// A chat in the mixed order: its profile and pin id.
    static func key(profile: String, id: String) -> String {
        profile + "\u{1F}" + id
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    func ids(profile: String) -> [String] {
        idsByProfile[profile] ?? []
    }

    mutating func set(_ ids: [String], profile: String) {
        let unique = Self.unique(ids)
        idsByProfile[profile] = unique.isEmpty ? nil : unique
    }

    mutating func setMixed(_ keys: [String]) {
        mixed = Self.unique(keys)
    }

    /// A pin that went or came: either way it leaves the order, so a chat
    /// pinned again goes on top rather than back to its old place.
    mutating func drop(_ ids: Set<String>, profile: String) {
        if let current = idsByProfile[profile] {
            set(current.filter { !ids.contains($0) }, profile: profile)
        }
        let keys = Set(ids.map { Self.key(profile: profile, id: $0) })
        mixed.removeAll { keys.contains($0) }
    }

    mutating func forget(profile: String) {
        idsByProfile.removeValue(forKey: profile)
        let prefix = Self.key(profile: profile, id: "")
        mixed.removeAll { $0.hasPrefix(prefix) }
    }

    /// Puts each profile's pinned rows in its order, in the places that
    /// profile's rows already hold. Rows the order doesn't name lead their
    /// profile's rows, in the order they came. With a `mixed` order, All's
    /// mixed Pinned section then gives each profile the places the person
    /// left its chats in (issue 1486).
    static func arrange<Row>(
        _ rows: [Row],
        profile: (Row) -> String,
        ids: (Row) -> Set<String>,
        order: (String) -> [String],
        mixed: [String] = []
    ) -> [Row] {
        guard rows.count > 1 else { return rows }
        var slotsByProfile: [String: [Int]] = [:]
        var profiles: [String] = []
        for (index, row) in rows.enumerated() {
            let owner = profile(row)
            if slotsByProfile[owner] == nil { profiles.append(owner) }
            slotsByProfile[owner, default: []].append(index)
        }
        var arranged = rows
        var ordered = Set<String>()
        for owner in profiles {
            let saved = order(owner)
            guard !saved.isEmpty, let slots = slotsByProfile[owner], slots.count > 1 else { continue }
            var rankOf: [String: Int] = [:]
            for (rank, id) in saved.enumerated() where rankOf[id] == nil { rankOf[id] = rank }
            let ranked = slots.map { slot in (slot: slot, rank: ids(rows[slot]).compactMap { rankOf[$0] }.min()) }
            if ranked.contains(where: { $0.rank != nil }) { ordered.insert(owner) }
            let sorted = ranked.enumerated().sorted { lhs, rhs in
                switch (lhs.element.rank, rhs.element.rank) {
                case let (left?, right?) where left != right: return left < right
                case (nil, .some): return true
                case (.some, nil): return false
                default: return lhs.offset < rhs.offset
                }
            }
            for (slot, source) in zip(slots, sorted) {
                arranged[slot] = rows[source.element.slot]
            }
        }
        return interleave(arranged, profile: profile, ids: ids, mixed: mixed, ordered: ordered)
    }

    /// Which profile holds each place, from the mixed order: rows it names
    /// in its order, after the rows it doesn't (a chat pinned since goes on
    /// top). Each profile's rows then fill its places in the order they
    /// came, which is the profile's own order; a profile that has none
    /// (`ordered` doesn't name it) puts the rows the mix doesn't name first.
    private static func interleave<Row>(
        _ rows: [Row],
        profile: (Row) -> String,
        ids: (Row) -> Set<String>,
        mixed: [String],
        ordered: Set<String>
    ) -> [Row] {
        guard !mixed.isEmpty else { return rows }
        var rankOf: [String: Int] = [:]
        for (rank, key) in mixed.enumerated() where rankOf[key] == nil { rankOf[key] = rank }
        let ranks = rows.map { row in
            let owner = profile(row)
            return ids(row).compactMap { rankOf[key(profile: owner, id: $0)] }.min()
        }
        let places = rows.indices.sorted { lhs, rhs in
            switch (ranks[lhs], ranks[rhs]) {
            case let (left?, right?) where left != right: return left < right
            case (nil, .some): return true
            case (.some, nil): return false
            default: return lhs < rhs
            }
        }
        var queues: [String: [Row]] = [:]
        for index in rows.indices.filter({ ranks[$0] == nil }) + rows.indices.filter({ ranks[$0] != nil }) {
            let owner = profile(rows[index])
            guard !ordered.contains(owner) else { continue }
            queues[owner, default: []].append(rows[index])
        }
        for row in rows where ordered.contains(profile(row)) {
            queues[profile(row), default: []].append(row)
        }
        var taken: [String: Int] = [:]
        return places.map { place in
            let owner = profile(rows[place])
            let next = taken[owner, default: 0]
            taken[owner] = next + 1
            return queues[owner]![next]
        }
    }

    /// The orders a drag leaves: `rows` as shown, moved the way a List's
    /// `onMove` reports it. Each moved row's profile gets its shown rows in
    /// their new places, then any of its saved ids not shown (a pinned chat
    /// not listed right now) in their old order.
    static func orders<Row>(
        moving rows: [Row],
        fromOffsets source: IndexSet,
        toOffset destination: Int,
        profile: (Row) -> String,
        pinID: (Row) -> String,
        ids: (Row) -> Set<String>,
        order: (String) -> [String]
    ) -> [String: [String]] {
        let movedProfiles = Set(source.filter { rows.indices.contains($0) }.map { profile(rows[$0]) })
        guard !movedProfiles.isEmpty else { return [:] }
        var moved = rows
        moved.move(fromOffsets: source, toOffset: destination)
        var result: [String: [String]] = [:]
        for owner in movedProfiles {
            let shown = moved.filter { profile($0) == owner }
            let shownIDs = shown.reduce(into: Set<String>()) { $0.formUnion(ids($1)) }
            result[owner] = shown.map(pinID) + order(owner).filter { !shownIDs.contains($0) }
        }
        return result
    }

    /// The mixed order a drag leaves in All's mixed Pinned section: `rows`
    /// moved as `onMove` reports it, where the first of them was, among the
    /// saved keys of chats not shown (a profile left out of All for now),
    /// which keep their places. A row the mix didn't name was shown on top,
    /// so then the rows go first.
    static func mixedOrder<Row>(
        moving rows: [Row],
        fromOffsets source: IndexSet,
        toOffset destination: Int,
        profile: (Row) -> String,
        pinID: (Row) -> String,
        ids: (Row) -> Set<String>,
        mixed: [String]
    ) -> [String] {
        var moved = rows
        moved.move(fromOffsets: source, toOffset: destination)
        let rowKeys = rows.map { row in Set(ids(row).map { key(profile: profile(row), id: $0) }) }
        let shownKeys = rowKeys.reduce(into: Set<String>()) { $0.formUnion($1) }
        let named = Set(mixed)
        let start = rowKeys.allSatisfy { !$0.isDisjoint(with: named) }
            ? mixed.firstIndex(where: shownKeys.contains) ?? mixed.count
            : 0
        let unshown = mixed.filter { !shownKeys.contains($0) }
        return Array(unshown.prefix(start)) + moved.map { key(profile: profile($0), id: pinID($0)) } + unshown.dropFirst(start)
    }

    /// Where a move lands among the rows that can move, when a List section
    /// also holds rows that can't (a nest's "3 jobs" line and its open
    /// children, or All's recent chats under a profile's pinned ones).
    /// `movable` marks each List row; the answer counts in movable rows
    /// only, and is nil when a row that can't move is among the sources.
    static func movableOffsets(
        fromOffsets source: IndexSet,
        toOffset destination: Int,
        movable: [Bool]
    ) -> (source: IndexSet, destination: Int)? {
        var movableIndex: [Int: Int] = [:]
        var count = 0
        for (index, canMove) in movable.enumerated() where canMove {
            movableIndex[index] = count
            count += 1
        }
        var mapped = IndexSet()
        for index in source {
            guard let position = movableIndex[index] else { return nil }
            mapped.insert(position)
        }
        let before = movable.prefix(max(0, min(destination, movable.count))).filter { $0 }.count
        return (mapped, before)
    }
}
