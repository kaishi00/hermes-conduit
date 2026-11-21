//
//  CombinedRoomViews.swift
//  Conduit
//
//  Another combined dashboard's group chat on Bots Home: a portrait among
//  the rooms, or a row in the list, with its dashboard's badge. A tap
//  switches to that dashboard and opens the room there.
//

import SwiftUI

/// Another combined dashboard's group chat as a portrait among Bots Home's
/// rooms, with its dashboard's badge, as that dashboard's bots have.
struct CombinedRoomPortrait: View {
    let tile: CombinedRoomTile
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Button {
            Haptics.light()
            // Opens in Bots, so Back returns to Bots Home (Eric, 2026-11-21:
            // it landed on Chats).
            Task { await appState.openCombinedRoom(tile, inBots: true) }
        } label: {
            BotRoomPortraitLabel(title: tile.name, talking: talking) { size in
                CombinedRoomIcon(tile: tile, size: size)
            }
            .opacity(tile.isOver ? 0.55 : 1)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(Text(verbatim: tile.name))
        .accessibilityValue(Text(verbatim: CombinedRoomText.value(tile, appState: appState)))
        .accessibilityHint(Text(AppLocalization.string("Opens this group chat.")))
        .accessibilityIdentifier("bots.combinedRoom.\(tile.id)")
    }

    /// A copy says whether its room is talking; a hosted room's state is
    /// read only on its own dashboard.
    private var talking: Bool {
        if case .copy(let copy) = tile.kind { return copy.state.working && !copy.isOver }
        return false
    }
}

/// Another combined dashboard's group chat as a row of the list.
struct CombinedRoomRosterRow: View {
    let tile: CombinedRoomTile
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Button {
            Haptics.light()
            Task { await appState.openCombinedRoom(tile) }
        } label: {
            RosterIconRow(title: tile.name, subtitle: CombinedRoomText.line(tile)) { size in
                CombinedRoomIcon(tile: tile, size: size)
            }
        }
        .buttonStyle(.plain)
        .rosterListRow()
        .accessibilityLabel(Text(verbatim: tile.name))
        .accessibilityValue(Text(verbatim: CombinedRoomText.value(tile, appState: appState)))
        .accessibilityHint(Text(AppLocalization.string("Opens this group chat.")))
    }
}

/// The room's members' faces, with its dashboard's badge.
struct CombinedRoomIcon: View {
    let tile: CombinedRoomTile
    let size: CGFloat

    var body: some View {
        GroupRoomIcon(picture: nil, members: tile.room.members, size: size)
            .modifier(RoomTileBadge(systemImage: RoomTileBadge.linked, shown: tile.room.isLinked))
            // On the other corner from the linked mark.
            .overlay(alignment: .bottomLeading) {
                CombinedDashboardBadge(dashboardID: tile.dashboardID, size: max(16, size * 0.36))
                    .offset(x: -2, y: 2)
                    .accessibilityHidden(true)
            }
    }
}

/// What another dashboard's group chat says of itself.
enum CombinedRoomText {
    /// The row's line: a copy's as on its own dashboard, a hosted room's
    /// member count.
    static func line(_ tile: CombinedRoomTile) -> String {
        switch tile.kind {
        case .hosted(let room): return AppLocalization.string("\(room.members.count) members")
        case .copy(let copy): return RoomCopyText.line(for: copy)
        }
    }

    /// VoiceOver's value: its dashboard's name, then the line.
    @MainActor
    static func value(_ tile: CombinedRoomTile, appState: AppState) -> String {
        [appState.combinedDashboardBadge(tile.dashboardID)?.name, line(tile)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}
