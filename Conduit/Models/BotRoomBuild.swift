//
//  BotRoomBuild.swift
//  Conduit
//
//  A room being started on Bots Home, before anything goes to Hermes: the
//  bots dropped together or tapped in, in the order they came, up to a
//  room's limit, and the name typed for it in the bar. Create makes the
//  room from the bar; until then it's only this.
//

import Foundation

struct BotRoomBuild: Equatable {
    private(set) var names: [String] = []
    /// The name typed in the bar, as typed; empty uses the bots' names.
    var name = ""
    /// The id Create sends, minted once per room so a retry of an
    /// ambiguous create reuses it and the gateway dedups instead of making
    /// a twin (as New Group Chat does, GroupCreateAttempt).
    private(set) var roomID = GroupCreateAttempt.mintRoomID()
    /// What `roomID` was first sent with: a retry with another name or
    /// other bots is another room, with an id of its own.
    private var attempted: GroupCreateAttempt.Inputs?

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

    /// Drops the bots and the name; the next room gets a fresh id.
    mutating func clear() { self = BotRoomBuild() }

    /// The room's name: what was typed, trimmed, or `suggested` (the bots'
    /// names) when nothing was.
    func roomName(suggested: String) -> String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? suggested.trimmingCharacters(in: .whitespacesAndNewlines) : typed
    }

    /// The id to send for a create with `inputs`: the same one again for
    /// the same inputs, a fresh one once they changed.
    mutating func attempt(_ inputs: GroupCreateAttempt.Inputs) -> String {
        roomID = GroupCreateAttempt.roomID(for: inputs, current: roomID, attempted: attempted)
        attempted = inputs
        return roomID
    }

    /// Only the bots still `visible`: one hidden or deleted meanwhile
    /// leaves the room.
    func pruned(visible: [String]) -> BotRoomBuild {
        var build = self
        build.names = names.filter { name in visible.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
        return build
    }
}

/// How the room Hermes makes from a room being started takes its place on
/// Bots Home: a room listed after Create was tapped stays out of the grid
/// while the room being started still stands in for it, and only a made
/// room Hermes lists slides into place (else it shows as it lands).
enum NewRoomLanding {
    /// Whether the room `roomID` shows among the rooms. `before`: the rooms
    /// there were as Create was tapped, nil before that or once it's done.
    static func shows(_ roomID: String, before: Set<String>?, starting: Bool) -> Bool {
        guard let before, starting else { return true }
        return before.contains(roomID)
    }

    /// The room that takes the new room's place: the made one, once listed.
    static func landing(made roomID: String, listed: [String]) -> String? {
        listed.contains(roomID) ? roomID : nil
    }
}
