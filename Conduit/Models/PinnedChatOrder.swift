//
//  PinnedChatOrder.swift
//  Conduit
//
//  The order of the Pinned section (issue 1354). Hermes keeps whether a
//  chat is pinned, not where it sits, so the order stays here, per profile,
//  under each chat's pin id (its lineage root, so a compacted chat keeps its
//  place). Until a profile's pins are reordered they follow recent activity
//  as before. A pinned chat the order doesn't name yet (pinned since, here
//  or on another device) goes on top.
//

import SwiftUI

struct PinnedChatOrder: Equatable {
    static let storageKey = "conduit.pinnedChatOrderByProfile.v1"

    private(set) var idsByProfile: [String: [String]]

    init(idsByProfile: [String: [String]] = [:]) {
        self.idsByProfile = idsByProfile.filter { !$0.value.isEmpty }
    }

    init(defaults: UserDefaults) {
        guard let data = defaults.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            self.init()
            return
        }
        self.init(idsByProfile: stored)
    }

    func save(to defaults: UserDefaults) {
        if idsByProfile.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(idsByProfile) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    func ids(profile: String) -> [String] {
        idsByProfile[profile] ?? []
    }

    mutating func set(_ ids: [String], profile: String) {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        idsByProfile[profile] = unique.isEmpty ? nil : unique
    }

    /// A pin that went or came: either way it leaves the order, so a chat
    /// pinned again goes on top rather than back to its old place.
    mutating func drop(_ ids: Set<String>, profile: String) {
        guard let current = idsByProfile[profile] else { return }
        set(current.filter { !ids.contains($0) }, profile: profile)
    }

    mutating func forget(profile: String) {
        idsByProfile.removeValue(forKey: profile)
    }

    /// Puts each profile's pinned rows in its order, in the places that
    /// profile's rows already hold, so All's mixed Pinned section keeps
    /// how the profiles interleave. Rows the order doesn't name lead their
    /// profile's rows, in the order they came.
    static func arrange<Row>(
        _ rows: [Row],
        profile: (Row) -> String,
        ids: (Row) -> Set<String>,
        order: (String) -> [String]
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
        for owner in profiles {
            let saved = order(owner)
            guard !saved.isEmpty, let slots = slotsByProfile[owner], slots.count > 1 else { continue }
            var rankOf: [String: Int] = [:]
            for (rank, id) in saved.enumerated() where rankOf[id] == nil { rankOf[id] = rank }
            let ranked = slots.map { slot in (slot: slot, rank: ids(rows[slot]).compactMap { rankOf[$0] }.min()) }
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
        return arranged
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
