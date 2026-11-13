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
    /// The dashboard the Link is on, so a Block confirmed after a switch
    /// doesn't go to another Hermes.
    var dashboardID: UUID? = nil
}

enum RoomBlock {
    /// The people in a room you're linked with: a copy's host, or the
    /// people a room this Hermes hosts invited, each once, by name.
    static func targets(copy: RoomCopy?, draft: RoomDraft?) -> [RoomBlockTarget] {
        var seen = Set<String>()
        var targets: [RoomBlockTarget] = []
        if let copy {
            targets.append(RoomBlockTarget(id: copy.link, name: copy.from.trimmingCharacters(in: .whitespacesAndNewlines)))
        } else if let draft {
            targets = draft.people.map {
                RoomBlockTarget(id: $0.id, name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return targets.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The open room's targets, each stamped with the room's own dashboard:
    /// a surface left from before a switch then fails block(_:)'s check
    /// instead of reaching the new Hermes. `draft` is the room's, when this
    /// Hermes hosts it.
    static func targets(for surface: AppState.GroupRoomSurface, draft: RoomDraft?) -> [RoomBlockTarget] {
        let listed = surface.copy.map { Self.targets(copy: $0, draft: nil) } ?? Self.targets(copy: nil, draft: draft)
        return listed.map { RoomBlockTarget(id: $0.id, name: $0.name, dashboardID: surface.dashboardID) }
    }

    // A Link with no name reads as "this person" rather than splicing a
    // stand-in into a name's place ("Block The host's Hermes").

    static func button(_ name: String) -> String {
        name.isEmpty
            ? AppLocalization.string("Block this person", table: .rooms)
            : AppLocalization.string("Block \(name)", table: .rooms)
    }

    static func title(_ name: String) -> String {
        name.isEmpty
            ? AppLocalization.string("Block this person?", table: .rooms)
            : AppLocalization.string("Block \(name)?", table: .rooms)
    }

    static func message(_ name: String) -> String {
        name.isEmpty
            ? AppLocalization.string("This unlinks their Hermes from yours, on both sides: nothing more from them reaches your Hermes, and the rooms you share with them stop. Linking again takes a new invite.", table: .rooms)
            : AppLocalization.string("This unlinks \(name)'s Hermes from yours, on both sides: nothing more from them reaches your Hermes, and the rooms you share with them stop. Linking again takes a new invite.", table: .rooms)
    }

    static func refusalTitle(_ name: String) -> String {
        name.isEmpty
            ? AppLocalization.string("Could not block this person", table: .rooms)
            : AppLocalization.string("Could not block \(name)", table: .rooms)
    }
}

extension AppState {
    /// Who Group Info's Block lists for the open room.
    var activeRoomBlockTargets: [RoomBlockTarget] {
        guard canInviteLinkedPeople, let surface = activeRoomSurface else { return [] }
        return RoomBlock.targets(for: surface, draft: surface.copy == nil ? linkedRoomDraft(surface.room.roomID) : nil)
    }

    /// Unlinks them, then reads the rooms again. False when the Link was
    /// already gone. Refused once the dashboard it was listed on isn't the
    /// active one.
    func block(_ target: RoomBlockTarget) async throws -> Bool {
        guard target.dashboardID == nil || target.dashboardID == activeDashboardID else {
            throw CancellationError()
        }
        let removed = try await roomLinksClient.unlink(target.id)
        await refreshGroupRooms()
        await refreshLinkedRoomCopies()
        await refreshLinkedRoomDrafts()
        return removed
    }
}
