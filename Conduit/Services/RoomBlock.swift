//
//  RoomBlock.swift
//  Conduit
//
//  Block, from Group Info (App Store guideline 1.2): the people in the open
//  room you're linked with, each of whom Block unlinks. There's no report:
//  a Link is made on purpose between people who know each other, and what
//  they share never passes through the developer, so there's nobody to
//  report to (Eric 2026-11-12). Unlinking is the block: once a Link goes,
//  nothing from their Hermes reaches yours, their agents' grants in your
//  rooms lapse, and linking again takes a new invite.
//

import Foundation

/// Someone Block can unlink: their Link and the name it shows.
struct RoomBlockTarget: Identifiable, Equatable {
    /// The Link's id.
    let id: String
    let name: String
}

enum RoomBlock {
    /// The people in a room you're linked with: a copy's host, or the
    /// people a room this Hermes hosts invited, each once, by name.
    static func targets(copy: RoomCopy?, draft: RoomDraft?) -> [RoomBlockTarget] {
        var seen = Set<String>()
        var targets: [RoomBlockTarget] = []
        if let copy {
            targets.append(RoomBlockTarget(id: copy.link, name: copy.from))
        } else if let draft {
            targets = draft.people.map { RoomBlockTarget(id: $0.id, name: $0.name) }
        }
        return targets.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func title(_ name: String) -> String {
        AppLocalization.string("Block \(name)?", table: .rooms)
    }

    static func message(_ name: String) -> String {
        AppLocalization.string("This unlinks \(name)'s Hermes from yours, on both sides: nothing more from them reaches your Hermes, and the rooms you share with them stop. Linking again takes a new invite.", table: .rooms)
    }
}

extension AppState {
    /// Who Group Info's Block lists for the open room.
    var activeRoomBlockTargets: [RoomBlockTarget] {
        guard canInviteLinkedPeople, let surface = activeRoomSurface else { return [] }
        if let copy = surface.copy { return RoomBlock.targets(copy: copy, draft: nil) }
        return RoomBlock.targets(copy: nil, draft: linkedRoomDraft(surface.room.roomID))
    }

    /// Unlinks them, then reads the rooms again. False when the Link was
    /// already gone.
    func block(_ target: RoomBlockTarget) async throws -> Bool {
        let removed = try await roomLinksClient.unlink(target.id)
        await refreshGroupRooms()
        await refreshLinkedRoomCopies()
        await refreshLinkedRoomDrafts()
        return removed
    }
}
