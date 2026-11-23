//
//  CombinedRoomViews.swift
//  Conduit
//
//  Another combined dashboard's group chat on Bots Home: a portrait among
//  the rooms, or a row in the list, with its dashboard's badge. A tap
//  opens the room in place, on that dashboard's own runtime.
//

import SwiftUI
import UniformTypeIdentifiers

/// Another combined dashboard's group chat as a portrait among Bots Home's
/// rooms, with its dashboard's badge, as that dashboard's bots have. A tap
/// opens it in place; a touch and hold has its menu, and a drag moves it
/// among its own dashboard's rooms, as this dashboard's rooms' do.
struct CombinedRoomPortrait: View {
    let tile: CombinedRoomTile
    /// Asks first (the dialog is Bots Home's, not the menu's).
    var onDisband: ((CombinedRoomTile) -> Void)? = nil
    /// Another room's tile is over this one.
    @State private var dropTarget = false
    /// Bots Home's held updates (`V2ShownUpdates`): hidden or covered,
    /// it doesn't redraw on AppState's publishes (audit 1722).
    @EnvironmentObject private var updates: V2ShownUpdates
    private var appState: AppState { updates.appState }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isHosted: Bool {
        if case .hosted = tile.kind { return true }
        return false
    }

    var body: some View {
        Button {
            Haptics.light()
            // Opens in Bots, so Back returns to Bots Home (Eric, 2026-11-21:
            // it landed on Chats).
            Task { await appState.openCombinedRoom(tile, inBots: true) }
        } label: {
            BotRoomPortraitLabel(title: tile.name, talking: appState.combinedRoomTalking(tile)) { size in
                CombinedRoomIcon(tile: tile, size: size)
            }
            .opacity(tile.isOver ? 0.55 : 1)
            .scaleEffect(dropTarget ? 1.06 : 1)
        }
        .buttonStyle(PressableButtonStyle())
        .contextMenu { menu }
        .modifier(RoomTileDrag(roomID: tile.id, enabled: isHosted) {
            // Drawn outside the view's environment, as a bot's preview:
            // the icon reads the tab's updates, so they're handed in too
            // (shown, as Bots Home is while a tile is dragged).
            CombinedRoomIcon(tile: tile, size: 56)
                .environmentObject(updates)
                .environmentObject(appState)
        })
        .onDrop(of: [UTType.text], delegate: RoomTileDrop(target: tile.id, targeted: $dropTarget) { dragged in
            move(dragged, onto: tile.id)
        })
        .accessibilityLabel(Text(verbatim: tile.name))
        .accessibilityValue(Text(verbatim: CombinedRoomText.value(tile, appState: appState, talking: true)))
        .accessibilityHint(Text(AppLocalization.string("Opens this group chat.")))
        // The drag's moves, for VoiceOver: one place among its own
        // dashboard's rooms.
        .accessibilityActions {
            if let earlier = appState.combinedRoomNeighbor(tile, by: -1) {
                Button(AppLocalization.string("Move Earlier")) {
                    move(tile.id, onto: earlier.id)
                }
            }
            if let later = appState.combinedRoomNeighbor(tile, by: 1) {
                Button(AppLocalization.string("Move Later")) {
                    move(tile.id, onto: later.id)
                }
            }
        }
        .accessibilityIdentifier("bots.combinedRoom.\(tile.id)")
    }

    /// A drag's or VoiceOver's move among its own dashboard's rooms, eased
    /// as this dashboard's rooms move; only a move that took buzzes.
    private func move(_ dragged: String, onto target: String) {
        let moved = withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) {
            appState.dropCombinedRoom(dragged, onto: target, dashboardID: tile.dashboardID)
        }
        if moved { Haptics.selection() }
    }

    /// Its menu, as this dashboard's rooms' less what needs this
    /// dashboard's sheets: Group Settings, which opens it in place, and
    /// Disband Group where its Hermes allows it.
    @ViewBuilder
    private var menu: some View {
        if isHosted {
            if appState.canEditCombinedRoomSettings(tile) {
                Button {
                    Task { await appState.openCombinedRoomSettings(tile, inBots: true) }
                } label: {
                    Label(AppLocalization.string("Group Settings"), systemImage: "gearshape")
                }
            }
            if let onDisband, appState.canDisbandCombinedRoom(tile) {
                Divider()
                Button(role: .destructive) { onDisband(tile) } label: {
                    Label(AppLocalization.string("Disband Group"), systemImage: "trash")
                }
            }
        }
    }
}

/// Another combined dashboard's group chat as a row of the list.
struct CombinedRoomRosterRow: View {
    let tile: CombinedRoomTile
    /// Bots Home's held updates (`V2ShownUpdates`): hidden or covered,
    /// it doesn't redraw on AppState's publishes (audit 1722).
    @EnvironmentObject private var updates: V2ShownUpdates
    private var appState: AppState { updates.appState }

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

/// The room's group picture, else its members' faces, with its dashboard's
/// badge.
struct CombinedRoomIcon: View {
    let tile: CombinedRoomTile
    let size: CGFloat
    /// Bots Home's held updates (`V2ShownUpdates`): hidden or covered,
    /// it doesn't redraw on AppState's publishes (audit 1722).
    @EnvironmentObject private var updates: V2ShownUpdates
    private var appState: AppState { updates.appState }

    var body: some View {
        GroupRoomIcon(picture: appState.combinedRoomPicture(tile), members: tile.room.members, size: size)
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

    /// VoiceOver's value, as this dashboard's rooms say it: on a tile,
    /// which draws its talking ring, whether it's talking (a row draws
    /// none); with linked people; its dashboard's name, then the line.
    @MainActor
    static func value(_ tile: CombinedRoomTile, appState: AppState, talking: Bool = false) -> String {
        let linked: Bool
        switch tile.kind {
        case .hosted(let room): linked = room.isLinked
        case .copy: linked = true
        }
        return [talking && appState.combinedRoomTalking(tile) ? BotRoomTalkingText.now : nil,
                linked ? AppLocalization.string("With linked people") : nil,
                appState.combinedDashboardBadge(tile.dashboardID)?.name, line(tile)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}
