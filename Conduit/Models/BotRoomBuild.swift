//
//  BotRoomBuild.swift
//  Conduit
//
//  A room being started on Bots Home, before anything goes to Hermes: the
//  bots dropped together or tapped in, in the order they came, up to a
//  room's limit. Create opens New Group Chat with them; until then it's
//  only this list.
//

import Foundation

struct BotRoomBuild: Equatable {
    private(set) var names: [String] = []

    var isEmpty: Bool { names.isEmpty }
    var isFull: Bool { names.count >= GroupRoomLimits.maxMembers }

    func contains(_ name: String) -> Bool {
        names.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// How many of `bots` would join (the ones not in it yet, each once).
    private func joining(_ bots: [String]) -> [String] {
        var seen = Set<String>()
        return bots.filter { !contains($0) && seen.insert($0.lowercased()).inserted }
    }

    /// Whether all of `bots` fit: a merge that would overflow the room
    /// isn't offered.
    func fits(_ bots: [String]) -> Bool {
        names.count + joining(bots).count <= GroupRoomLimits.maxMembers
    }

    /// Adds `bots`, all or none. False when they don't fit.
    @discardableResult
    mutating func add(_ bots: [String]) -> Bool {
        guard fits(bots) else { return false }
        names += joining(bots)
        return true
    }

    mutating func remove(_ name: String) {
        names.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    mutating func clear() { names = [] }

    /// Only the bots still `visible`: one hidden or deleted meanwhile
    /// leaves the room.
    func pruned(visible: [String]) -> BotRoomBuild {
        var build = self
        build.names = names.filter { name in visible.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
        return build
    }
}
