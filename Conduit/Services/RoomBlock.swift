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
            targets.append(RoomBlockTarget(id: copy.link, name: RoomCopyText.hostName(for: copy)))
        } else if let draft {
            let someone = AppLocalization.string("Someone you've linked with", table: .rooms)
            targets = draft.people.map {
                let name = $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return RoomBlockTarget(id: $0.id, name: name.isEmpty ? someone : name)
            }
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
        let targets = surface.copy.map { RoomBlock.targets(copy: $0, draft: nil) }
            ?? RoomBlock.targets(copy: nil, draft: linkedRoomDraft(surface.room.roomID))
        // The room's own dashboard: a surface left from before a switch
        // then fails block(_:)'s check instead of reaching the new Hermes.
        let dashboard = surface.dashboardID
        return targets.map { RoomBlockTarget(id: $0.id, name: $0.name, dashboardID: dashboard) }
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
