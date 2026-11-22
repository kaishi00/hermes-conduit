//
//  AppState+CombinedRooms.swift
//  Conduit
//
//  Group Chats in a combined group: every combined dashboard's group
//  chats, read through each one's kept connection, beside the dashboard on
//  screen's own, each with its dashboard's badge. A room shows once, under
//  the one dashboard you talk in it from: the Hermes that hosts it, when
//  that Hermes is in the group, else the first dashboard in Saved
//  Dashboards order that has a copy of it. So you're the same person in it
//  whichever dashboard is on screen (Eric, 2026-11-20). A tap opens the
//  room in place on that dashboard's own runtime (its kept connection),
//  with no switch (no-switch stage 2).
//

import Foundation
import UIKit

/// Another combined dashboard's group chats: the rooms its Hermes hosts
/// and its copies of rooms another Hermes hosts, as last read.
struct CombinedDashboardRooms: Equatable {
    /// The kept client it was read through; none for the one on screen's
    /// lists, kept as it shows them.
    let client: ObjectIdentifier?
    var rooms: [GroupRoom]
    var copies: [RoomCopy]
    let at: Date
}

/// One of another combined dashboard's group chats on Bots Home.
struct CombinedRoomTile: Identifiable, Equatable {
    enum Kind: Equatable {
        /// A room its Hermes hosts.
        case hosted(GroupRoom)
        /// Its copy of a room another Hermes hosts.
        case copy(RoomCopy)
    }

    let dashboardID: UUID
    let kind: Kind

    /// Its kind too: a room id is unique only on its host, so one
    /// dashboard can hold a room it hosts and a copy of another with the
    /// same id.
    var id: String {
        switch kind {
        case .hosted(let room): return "\(dashboardID.uuidString)|hosted|\(room.roomID)"
        case .copy(let copy): return "\(dashboardID.uuidString)|copy|\(copy.id)"
        }
    }

    var roomID: String {
        switch kind {
        case .hosted(let room): return room.roomID
        case .copy(let copy): return copy.roomID
        }
    }

    var name: String {
        switch kind {
        case .hosted(let room): return room.name
        case .copy(let copy): return copy.name
        }
    }

    /// The room as its screen draws it.
    var room: GroupRoom {
        switch kind {
        case .hosted(let room): return room
        case .copy(let copy): return copy.room
        }
    }

    var updatedAt: Double {
        switch kind {
        case .hosted(let room): return room.updatedAt
        case .copy(let copy): return copy.updatedAt
        }
    }

    /// Ended, or your agents left: dimmed, as this dashboard's copies are.
    var isOver: Bool {
        if case .copy(let copy) = kind { return copy.isOver }
        return false
    }
}

extension AppState {
    /// How long another dashboard's group chats stand before a read again.
    /// Bots Home's pull reads them at once.
    static let combinedDashboardRoomsMaxAge: TimeInterval = 60

    /// Reads each other combined dashboard's group chats through its kept
    /// connection: the rooms its Hermes hosts (`groups.list` on its kept
    /// client) and its copies of rooms elsewhere (the plugin's copies
    /// route). Quiet on failure: what can't be read keeps what it showed,
    /// and a dashboard let go or opened says nothing more.
    func readOtherCombinedDashboardsRooms(force: Bool = false, now: Date = Date()) async {
        let kept = keptDashboardRuntimes.filter { isInCombinedGroup($0.key) && $0.key != activeDashboardID }
        // One that dropped by itself keeps its last list until it's back,
        // and so does the one on screen (its own lists show while it is), so
        // leaving it shows its rooms at once; out of the group, it goes.
        if combinedDashboardRooms.keys.contains(where: { !isInCombinedGroup($0) }) {
            combinedDashboardRooms = combinedDashboardRooms.filter { isInCombinedGroup($0.key) }
        }
        // The one on screen's rooms as it shows them, for when it's left,
        // as its chats and bots are: read anew there on the next pass.
        if let active = activeDashboardID, isInCombinedGroup(active), groupRoomsListed {
            let seed = CombinedDashboardRooms(client: nil, rooms: shownGroupRooms.filter { !$0.isDisbanded },
                                              copies: linkedRoomCopyRows, at: .distantPast)
            if seed != combinedDashboardRooms[active] { combinedDashboardRooms[active] = seed }
        }
        for (id, runtime) in kept.sorted(by: { $0.value.keptAt < $1.value.keptAt }) {
            guard isSceneActive else { return }
            let client = ObjectIdentifier(runtime.client)
            let last = combinedDashboardRooms[id]
            if !force, let last, last.client == client,
               now.timeIntervalSince(last.at) < Self.combinedDashboardRoomsMaxAge { continue }
            // Kept anew (opened and left again) while the read was out: the
            // lists that visit showed are newer than this read. The client
            // alone can't tell, since a switch back takes up the same one.
            let keptAt = runtime.keptAt
            var stillKept: Bool {
                keptDashboardRuntimes[id]?.client === runtime.client && keptDashboardRuntimes[id]?.keptAt == keptAt
                    && activeDashboardID != id && isInCombinedGroup(id)
            }
            var rooms = last?.rooms
            var answered = false
            do {
                let listed: [GroupRoom]
                if let keptDashboardRoomsReader {
                    listed = try await keptDashboardRoomsReader(runtime.client)
                } else {
                    listed = try await Self.everyGroupRoom(runtime.client)
                }
                rooms = listed.filter { !$0.isDisbanded }
                answered = true
            } catch {
                // A Hermes that hosts no rooms has none; anything else keeps
                // what it showed.
                if HermesClient.isMissingRPCMethod(error) {
                    rooms = []
                    answered = true
                }
            }
            guard stillKept else { continue }
            var copies = last?.copies
            // Its plugin's routes unknown (not read yet), its copies stay as
            // they were; a plugin without copies has none.
            if let capabilities = await combinedDashboardCapabilities(id, runtime) {
                if !capabilities.contains(RoomCopiesClient.capability) {
                    copies = []
                } else if let response = try? await readKeptDashboardJSON(runtime.bridge, path: RoomCopiesClient.path),
                          let read = try? RoomCopiesClient.parseList(response) {
                    copies = read
                    answered = true
                }
            }
            guard stillKept, answered || last != nil else { continue }
            // A read started later already stored its list: keep that one.
            if let stored = combinedDashboardRooms[id], stored.at > now { continue }
            let read = CombinedDashboardRooms(client: client, rooms: rooms ?? [], copies: copies ?? [], at: now)
            if read != combinedDashboardRooms[id] { combinedDashboardRooms[id] = read }
        }
    }

    /// Most pages of `groups.list` one read follows.
    static let combinedDashboardRoomsMaxPages = 10

    /// The rooms a Hermes hosts: `groups.list` page by page, while it names
    /// a next page further on, up to `combinedDashboardRoomsMaxPages` (an
    /// empty page with a next one still goes on: a partial page).
    static func everyGroupRoom(_ client: HermesClient) async throws -> [GroupRoom] {
        try await everyGroupRoom { offset in try await client.groupsList(offset: offset) }
    }

    /// The same, from `read`, which answers the page at an offset.
    static func everyGroupRoom(
        page read: (Int?) async throws -> (rooms: [GroupRoom], nextOffset: Int?)
    ) async throws -> [GroupRoom] {
        var rooms: [GroupRoom] = []
        var offset: Int?
        for _ in 0..<combinedDashboardRoomsMaxPages {
            let page = try await read(offset)
            rooms += page.rooms
            guard let next = page.nextOffset, next > (offset ?? 0) else { break }
            offset = next
        }
        var seen = Set<String>()
        return rooms.filter { seen.insert($0.roomID).inserted }
    }

    /// Whether two lists of a room's members are one room's: a room's id is
    /// only unique on the Hermes that hosts it, so a copy is that room's
    /// when they share a member too (or either names none).
    static func sameRoomMembers(_ a: [String], _ b: [String]) -> Bool {
        a.isEmpty || b.isEmpty || !Set(a).isDisjoint(with: b)
    }

    /// Every dashboard of the group in Saved Dashboards order, each with
    /// the rooms it hosts and its copies, the one on screen's as Bots Home
    /// shows them.
    private var combinedGroupRoomLists: [(id: UUID, rooms: [GroupRoom], copies: [RoomCopy])] {
        savedDashboardRegistry.dashboards.compactMap { dashboard in
            guard isInCombinedGroup(dashboard.id) else { return nil }
            if dashboard.id == activeDashboardID {
                return (dashboard.id, shownGroupRooms.filter { !$0.isDisbanded }, linkedRoomCopyRows)
            }
            guard let read = combinedDashboardRooms[dashboard.id] else { return nil }
            return (dashboard.id, read.rooms, read.copies)
        }
    }

    /// The dashboard of the group you talk in each room from: the one
    /// whose Hermes hosts it, else the first in Saved Dashboards order with
    /// a copy of it. Nil outside the group. Indexed by room id once per
    /// pass, so finding a room's home doesn't scan every dashboard's rooms
    /// for every room (issue 2990).
    struct CombinedRoomHomes {
        private typealias Entry = (id: UUID, members: [String])
        private var hosts: [String: [Entry]] = [:]
        private var copies: [String: [Entry]] = [:]
        private let active: UUID?

        init(_ lists: [(id: UUID, rooms: [GroupRoom], copies: [RoomCopy])], active: UUID?) {
            self.active = active
            // In Saved Dashboards order, as the lists come.
            for list in lists {
                for room in list.rooms {
                    hosts[room.roomID, default: []].append((list.id, room.members.compactMap(\.memberID)))
                }
                for copy in list.copies {
                    copies[copy.roomID, default: []].append((list.id, copy.members.compactMap(\.memberID)))
                }
            }
        }

        func home(roomID: String, memberIDs: [String]) -> UUID? {
            // The one on screen first among hosts: one Hermes saved at two
            // addresses hosts the room on both, and shows it as this one's.
            let hosting = (hosts[roomID] ?? []).filter { AppState.sameRoomMembers($0.members, memberIDs) }
            if let host = hosting.first(where: { $0.id == active }) ?? hosting.first { return host.id }
            return (copies[roomID] ?? []).first { AppState.sameRoomMembers($0.members, memberIDs) }?.id
        }
    }

    /// This dashboard's copies Bots Home shows: all of them outside a
    /// group; in one, only those of rooms you talk in from here, since the
    /// rest show under the dashboard that hosts them or the first with a
    /// copy (Eric, 2026-11-20: who you are in a room went with the
    /// dashboard on screen).
    var shownLinkedRoomCopyRows: [RoomCopy] {
        let copies = linkedRoomCopyRows
        guard isInCombinedGroup(activeDashboardID), !combinedDashboardRooms.isEmpty else { return copies }
        let homes = CombinedRoomHomes(combinedGroupRoomLists, active: activeDashboardID)
        return copies.filter { copy in
            homes.home(roomID: copy.roomID, memberIDs: copy.members.compactMap(\.memberID))
                .map { $0 == activeDashboardID } ?? true
        }
    }

    /// Every other combined dashboard's group chat Bots Home shows, as
    /// `combinedRoomTilesAroundThisDashboard` places them.
    var otherCombinedDashboardsRoomTiles: [CombinedRoomTile] {
        let around = combinedRoomTilesAroundThisDashboard
        return around.before + around.after
    }

    /// The other combined dashboards' group chats: every room its Hermes
    /// hosts that no dashboard before it in Saved Dashboards shows, and its
    /// copies of rooms you talk in from there, split where Saved Dashboards
    /// puts this dashboard: the ones
    /// before show before its group chats, the rest after. Each
    /// dashboard's show as they do when it's on screen, its rooms in its
    /// own order then its copies, so opening one (in place, or through a
    /// switch when it isn't kept) moves nothing (Eric, 2026-11-21: the group chats' order shifted on
    /// a tap; it put this dashboard's first and the others newest first).
    var combinedRoomTilesAroundThisDashboard: (before: [CombinedRoomTile], after: [CombinedRoomTile]) {
        guard isInCombinedGroup(activeDashboardID), !combinedDashboardRooms.isEmpty else { return ([], []) }
        let lists = combinedGroupRoomLists
        let homes = CombinedRoomHomes(lists, active: activeDashboardID)
        var before: [CombinedRoomTile] = []
        var after: [CombinedRoomTile] = []
        var passed = !lists.contains { $0.id == activeDashboardID }
        for list in lists {
            if list.id == activeDashboardID {
                passed = true
                continue
            }
            let order = BotOrder(defaults: defaults,
                                 key: BotOrder.roomStorageKey(scope: Self.dashboardPreferenceBucket(list.id)),
                                 kind: .rooms)
            var own: [CombinedRoomTile] = []
            for room in order.arrange(list.rooms, name: \.roomID) {
                let members = room.members.compactMap(\.memberID)
                guard homes.home(roomID: room.roomID, memberIDs: members) == list.id else { continue }
                own.append(CombinedRoomTile(dashboardID: list.id, kind: .hosted(room)))
            }
            for copy in list.copies {
                let members = copy.members.compactMap(\.memberID)
                guard homes.home(roomID: copy.roomID, memberIDs: members) == list.id else { continue }
                own.append(CombinedRoomTile(dashboardID: list.id, kind: .copy(copy)))
            }
            if passed { after += own } else { before += own }
        }
        return (before, after)
    }

    /// Whether the dashboard on screen lists the tile's room already, so
    /// opening it needs no read: a hosted room in its rooms, a copy in its
    /// copies with the plugin's routes known.
    func listsCombinedRoomTile(_ tile: CombinedRoomTile) -> Bool {
        guard activeDashboardID == tile.dashboardID else { return false }
        switch tile.kind {
        case .hosted(let room):
            return groupRoomsListed && groupRooms.contains { $0.roomID == room.roomID }
        case .copy(let copy):
            return canReadRoomCopies && linkedRoomCopyRows.contains { $0.id == copy.id }
        }
    }

    /// The open group chat's runtime when it's another combined
    /// dashboard's, opened in place on its own runtime with no switch
    /// (no-switch stage 2); nil for the one on screen's, or one let go.
    var farRoomRuntime: DashboardRuntime? {
        guard let id = activeRoomSurface?.dashboardID, id != dashboardIDOnScreen else { return nil }
        return runtime(for: id)
    }

    /// Whether `roomID` is the open far group chat's.
    func isOpenFarRoom(_ roomID: String) -> Bool {
        farRoomRuntime != nil && activeRoomSurface?.room.roomID == roomID
    }

    /// The far room's runtime when a step isn't already acting on it: a
    /// room entry point called from its screen enters it first.
    var roomRuntimeToEnter: DashboardRuntime? {
        guard let runtime = farRoomRuntime, runtime !== shownRuntime else { return nil }
        return runtime
    }

    /// Where the open room's media are read: a far room's through its own
    /// dashboard's connection, from `profile` there (a member's own), else
    /// the profile it last used. The one on screen's resolvers otherwise.
    func roomGatewayMediaResolver(for profile: String? = nil) -> GatewayMediaDataURLResolver {
        guard let runtime = farRoomRuntime, let id = activeRoomSurface?.dashboardID else {
            return profile.map { gatewayMediaResolver(for: $0) } ?? gatewayMediaResolver
        }
        let profile = profile ?? runtime.keptListsProfile ?? "default"
        let key = "\(id.uuidString)|\(profile)"
        if let cached = farRoomMediaResolvers[key] { return cached }
        let resolver = act(onRuntime: runtime) { GatewayMediaDataURLResolver(appState: self, profile: profile) }
        farRoomMediaResolvers[key] = resolver
        return resolver
    }

    /// Runs a step of the open group chat on its own dashboard's runtime
    /// across its awaits: a far room's sends, polls and reads go through
    /// its dashboard's connection and lists, never the one on screen's.
    func onRoomRuntime<T>(_ body: () async -> T) async -> T {
        guard let runtime = farRoomRuntime else { return await body() }
        return await actAcrossAwaits(onRuntime: runtime, body)
    }

    /// Reads what the open group chat's screen draws (its capabilities, its
    /// bots, its plugin's routes) from its own dashboard's runtime.
    func readingRoomRuntime<T>(_ body: () -> T) -> T {
        guard let runtime = farRoomRuntime else { return body() }
        return act(onRuntime: runtime, body)
    }

    /// Opens another combined dashboard's group chat. Kept connected, it
    /// opens in place on that dashboard's own runtime: no switch, and you
    /// talk in it as that Hermes' own person (no-switch stage 2). One not
    /// connected here switches there first, as before.
    /// `inBots`: tapped on Bots Home, so its screen opens in Bots and Back
    /// returns there, as this dashboard's rooms' portraits do.
    func openCombinedRoom(_ tile: CombinedRoomTile, inBots: Bool = false) async {
        dismissSidebarDrawer()
        if let runtime = keptRuntimeOpeningRoomsInPlace(tile.dashboardID) {
            let mark = inBots ? BotZoomArm.roomKey(tile.roomID) : nil
            if let mark { beginOpeningBotChat(mark) }
            defer { if let mark { endOpeningBotChat(mark) } }
            // A chat or room opened while its support is read owns the screen.
            let viewport = chatViewportTransitionGeneration, roomEpoch = groupRoomEpoch
            guard await readyKeptRuntimeForRooms(runtime, tile.dashboardID),
                  chatViewportTransitionGeneration == viewport, groupRoomEpoch == roomEpoch else { return }
            // Its kept connection went meanwhile: say so, rather than nothing.
            guard keptRuntimeOpeningRoomsInPlace(tile.dashboardID) === runtime else {
                errorMessage = AppLocalization.string("Couldn't open that chat. Try again.")
                return
            }
            await actAcrossAwaits(onRuntime: runtime) { await openCombinedRoomTile(tile) }
            closeFarRoomIfLetGo(runtime, tile.dashboardID)
            return
        }
        guard !refusesCombinedSwitchDuringCall(to: tile.dashboardID) else { return }
        // Opens once the dashboard is connected if it still lists the room
        // as it was left (its kept lists show at once on the switch back),
        // rather than after the switch's sync. The mark is made once the
        // switch has connected there or settled, since a switch clears Bot
        // Mode's state, an open on its way included.
        await switchToCombinedDashboardUntilSettled(tile.dashboardID) { [weak self] in
            self?.listsCombinedRoomTile(tile) == true
        }
        guard !Task.isCancelled, activeDashboardID == tile.dashboardID else { return }
        let mark = inBots ? BotZoomArm.roomKey(tile.roomID) : nil
        if let mark { beginOpeningBotChat(mark) }
        defer { if let mark { endOpeningBotChat(mark) } }
        await openCombinedRoomTile(tile)
    }

    /// Another combined dashboard's runtime when its group chats open in
    /// place: kept beside the one on screen and connected. Nil otherwise,
    /// and the open switches there as before.
    func keptRuntimeOpeningRoomsInPlace(_ id: UUID) -> DashboardRuntime? {
        guard let runtime = runtime(for: id), runtime !== runtimeOnScreen, runtime.isConnected else { return nil }
        return runtime
    }

    /// A far room that opened as its dashboard's kept connection went:
    /// nothing is left to act on it, so it closes and says so, as the drop
    /// closes one already open.
    func closeFarRoomIfLetGo(_ runtime: DashboardRuntime, _ id: UUID) {
        guard keptRuntimeOpeningRoomsInPlace(id) !== runtime, activeRoomSurface?.dashboardID == id,
              id != dashboardIDOnScreen else { return }
        closeRoomSurface(clearingRoomError: false)
        errorMessage = AppLocalization.string("Couldn't open that chat. Try again.")
    }

    /// Reads what a kept dashboard's rooms need on its own runtime, once
    /// while it's kept: what its plugin serves (pictures, files, copies),
    /// then its group chats, since signed in quietly beside this one it
    /// read only what the lists show. Its bots as its list read them stand
    /// in for its roster, for the room's faces and names, until that's
    /// read. False when the open was cancelled meanwhile.
    func readyKeptRuntimeForRooms(_ runtime: DashboardRuntime, _ id: UUID) async -> Bool {
        await readKeptPluginStatusIfUnknown(id)
        guard !Task.isCancelled else { return false }
        await actAcrossAwaits(onRuntime: runtime) {
            if groupChatPhase != .available || groupCapabilities == nil { await refreshGroupChatSupport() }
            if botRoster.isEmpty, let bots = combinedDashboardBots[id]?.bots { botRoster = bots }
        }
        return !Task.isCancelled
    }

    /// A kept dashboard's plugin status on its own runtime, read through its
    /// kept connection when it isn't known there yet: just what the plugin
    /// serves, none of what the read on screen sets going (shares, Watch
    /// voices, update notices).
    func readKeptPluginStatusIfUnknown(_ id: UUID) async {
        guard let kept = keptDashboardRuntimes[id], case .unknown = kept.runtime.notifierPlugin.state,
              let response = try? await readKeptDashboardJSON(kept.bridge, path: NotifierPluginStatus.path),
              keptDashboardRuntimes[id]?.bridge === kept.bridge else { return }
        let state = NotifierPluginStatus.state(from: response)
        guard state != .unknown, case .unknown = kept.runtime.notifierPlugin.state else { return }
        kept.runtime.notifierPlugin.state = state
        kept.runtime.notifierPlugin.runtime = NotifierPluginStatus.runtime(from: response)
        if case .reported(_, let capabilities) = state {
            combinedDashboardPluginCapabilities[id] = (ObjectIdentifier(kept.bridge), capabilities)
        }
    }

    /// Opens the tile's room on its dashboard, the one acted on (in place,
    /// or after the switch).
    private func openCombinedRoomTile(_ tile: CombinedRoomTile) async {
        switch tile.kind {
        case .hosted(let room):
            if await openNotificationRoom(room.roomID) == .retry, activeDashboardID == tile.dashboardID {
                errorMessage = AppLocalization.string("Couldn't open that chat. Try again.")
            }
        case .copy(let copy):
            // A chat or room opened while its copies are read owns the
            // screen: the tap is dropped, not opened over it, as a hosted
            // room's is.
            let viewport = chatViewportTransitionGeneration
            let roomEpoch = groupRoomEpoch
            var superseded: Bool { chatViewportTransitionGeneration != viewport || groupRoomEpoch != roomEpoch }
            // Its plugin's routes may not be read yet (a switch reads them
            // after its sync settles): its copies can be read once they're
            // known. In place, they were read before.
            if !canReadRoomCopies, actingOnRuntimeOnScreen {
                await refreshNotifierPluginStatusOnce()
                guard !Task.isCancelled, activeDashboardID == tile.dashboardID, !superseded else { return }
            }
            // Read afresh before it opens: the list on hand can be what the
            // dashboard showed when it was left (its kept lists), and the
            // copy opens at its tail and polls by what its row says, so one
            // its host reopened or moved on since would open on the old
            // window and stay there (#3048). Only a list read without it
            // shows it gone; one that couldn't be read opens from the list
            // on hand, or is tried again, as a hosted room's is.
            let listed = linkedRoomCopyRows.first { $0.id == copy.id }
            let read = await readLinkedRoomCopies()
            let unread = read == nil
            let found = unread ? listed : read?.first { $0.id == copy.id }
            guard !Task.isCancelled, activeDashboardID == tile.dashboardID, !superseded else { return }
            guard let found else {
                errorMessage = unread
                    ? AppLocalization.string("Couldn't open that chat. Try again.")
                    : AppLocalization.string("That chat is no longer available.")
                return
            }
            await openRoomCopy(found)
        }
    }
}

// MARK: - Another dashboard's room tiles on Bots Home

extension AppState {
    /// Another dashboard's hosted room's runtime, kept beside the one on
    /// screen, for what its tile draws and does.
    private func keptRuntime(of tile: CombinedRoomTile) -> DashboardRuntime? {
        guard let runtime = runtime(for: tile.dashboardID), runtime !== runtimeOnScreen else { return nil }
        return runtime
    }

    /// Whether another dashboard's group chat is talking now: a copy says
    /// so itself, a hosted room as its own runtime last read it
    /// (`refreshCombinedRoomTilesIfDue`).
    func combinedRoomTalking(_ tile: CombinedRoomTile) -> Bool {
        switch tile.kind {
        case .copy(let copy):
            return copy.state.working && !copy.isOver
        case .hosted(let room):
            return keptRuntime(of: tile)?.talkingRoomIDs.contains(room.roomID) == true
        }
    }

    /// Another dashboard's hosted room's group picture, as its own runtime
    /// holds it: what this phone kept from its last visit, adopted on its
    /// first read, then what its plugin lists. Read straight from that
    /// runtime, never an open room's that shares the id, and never the
    /// kept copy once its plugin has answered (a removed picture stays gone).
    func combinedRoomPicture(_ tile: CombinedRoomTile) -> UIImage? {
        guard case .hosted(let room) = tile.kind, let runtime = keptRuntime(of: tile),
              let data = runtime.groupRoomPictureData[room.roomID] else { return nil }
        return GroupRoomPictureImages.image(from: data)
    }

    /// Whether another dashboard's hosted room can be disbanded from its
    /// tile: its Hermes said it can, as read on its own runtime.
    func canDisbandCombinedRoom(_ tile: CombinedRoomTile) -> Bool {
        guard case .hosted = tile.kind, let runtime = keptRuntime(of: tile) else { return false }
        return runtime.groupCapabilities?.supports("groups.disband") == true
    }

    /// Whether another dashboard's hosted room's Group Settings can be
    /// edited from its tile: its Hermes serves them, as read on its own
    /// runtime (this dashboard's tiles ask the same of theirs).
    func canEditCombinedRoomSettings(_ tile: CombinedRoomTile) -> Bool {
        guard case .hosted = tile.kind, let runtime = keptRuntime(of: tile) else { return false }
        return runtime.groupCapabilities?.supports("groups.context") == true
    }

    /// Disbands another dashboard's hosted room on its own runtime, then
    /// reads that dashboard's rooms again. The failure, if any, for Bots
    /// Home's notice.
    func disbandCombinedRoom(_ tile: CombinedRoomTile) async -> String? {
        guard case .hosted(let room) = tile.kind, let runtime = keptRuntime(of: tile) else { return nil }
        let failure = await actAcrossAwaits(onRuntime: runtime) { await disbandGroupRoom(room.roomID) }
        await readOtherCombinedDashboardsRooms(force: true)
        return failure
    }

    /// Asks for another dashboard's room's Group Settings, then opens it in
    /// place, where its screen shows them once its Hermes has read them.
    func openCombinedRoomSettings(_ tile: CombinedRoomTile, inBots: Bool = false) async {
        let request = GroupSettingsRequest(roomID: tile.roomID)
        groupSettingsOnOpen = request
        await openCombinedRoom(tile, inBots: inBots)
        // An open that failed leaves no request behind for a later open.
        if activeRoomSurface?.room.roomID != tile.roomID, groupSettingsOnOpen == request { groupSettingsOnOpen = nil }
    }

    /// The hosted tile beside another dashboard's room among its own
    /// dashboard's (-1 before, +1 after), for VoiceOver's Move Earlier and
    /// Move Later: dropping on it moves the room one place, as a drag does.
    func combinedRoomNeighbor(_ tile: CombinedRoomTile, by step: Int) -> CombinedRoomTile? {
        guard case .hosted = tile.kind else { return nil }
        let own = otherCombinedDashboardsRoomTiles.filter { other in
            guard other.dashboardID == tile.dashboardID, case .hosted = other.kind else { return false }
            return true
        }
        guard let index = own.firstIndex(where: { $0.id == tile.id }), own.indices.contains(index + step) else { return nil }
        return own[index + step]
    }

    /// Another dashboard's room's tile dropped on `target`'s, of the same
    /// dashboard (nil: past its last), whose place it takes in that
    /// dashboard's room order, kept on this phone as its tiles read it. A
    /// tile of another dashboard, or this one's, moves nothing: each
    /// dashboard's rooms keep their place among the group's. Whether it
    /// moved.
    @discardableResult
    func dropCombinedRoom(_ moved: String, onto target: String?, dashboardID: UUID) -> Bool {
        let tiles = otherCombinedDashboardsRoomTiles.filter { $0.dashboardID == dashboardID }
        let hosted = tiles.compactMap { tile -> String? in
            if case .hosted(let room) = tile.kind { return room.roomID }
            return nil
        }
        guard let movedTile = tiles.first(where: { $0.id == moved }), case .hosted(let room) = movedTile.kind else { return false }
        var onto: String?
        if let target {
            guard let targetTile = tiles.first(where: { $0.id == target }) else { return false }
            // A copy follows the rooms: dropped on one, it goes past the last.
            if case .hosted(let targetRoom) = targetTile.kind { onto = targetRoom.roomID }
        }
        let key = BotOrder.roomStorageKey(scope: Self.dashboardPreferenceBucket(dashboardID))
        let order = BotOrder(defaults: defaults, key: key, kind: .rooms)
        let dropped = order.dropping(room.roomID, onto: onto, shown: hosted)
        // What shows already: the last dropped past the end, say, with no
        // order saved yet moves nothing and saves nothing.
        guard dropped.arrange(hosted, name: { $0 }) != hosted else { return false }
        objectWillChange.send()
        dropped.save(to: defaults, key: key)
        return true
    }

    /// The other combined dashboards' hosted rooms on Bots Home, read on
    /// their own runtimes through their kept connections on Bots Home's
    /// talking tick: which are talking, and the pictures that changed.
    /// Each at most once per `every`, as the one on screen's.
    func refreshCombinedRoomTilesIfDue(every: Duration) async {
        let interval = Double(every.components.seconds) - 1
        var hosted: [UUID: [GroupRoom]] = [:]
        for tile in otherCombinedDashboardsRoomTiles {
            if case .hosted(let room) = tile.kind { hosted[tile.dashboardID, default: []].append(room) }
        }
        for (id, rooms) in hosted.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard !Task.isCancelled, let kept = keptDashboardRuntimes[id], kept.runtime.isConnected else { continue }
            let runtime = kept.runtime
            if let at = runtime.talkingRoomsReadAt, Date().timeIntervalSince(at) < interval { continue }
            let firstRead = runtime.talkingRoomsReadAt == nil
            runtime.talkingRoomsReadAt = Date()
            await readKeptPluginStatusIfUnknown(id)
            guard keptDashboardRuntimes[id]?.runtime === runtime else { continue }
            let talking = runtime.talkingRoomIDs, pictures = runtime.groupRoomPictureData, capabilities = runtime.groupCapabilities
            await actAcrossAwaits(onRuntime: runtime) {
                await refreshTalkingRooms(among: rooms)
                // What this phone kept from its last visit, once, then what
                // changed: a picture its plugin no longer lists isn't adopted
                // again on the next tick.
                if firstRead, !groupRoomsListed { adoptKeptGroupRoomPictures() }
                await refreshGroupRoomPictures(among: rooms)
                // Whether its Hermes can disband them and serves their
                // settings, for the tiles' menus:
                // just the capabilities, not the room reads an open does.
                await readGroupCapabilitiesIfUnknown()
            }
            // Its runtime isn't the screen's: say its tiles changed.
            if runtime.talkingRoomIDs != talking || runtime.groupRoomPictureData != pictures || runtime.groupCapabilities != capabilities {
                objectWillChange.send()
            }
        }
    }
}
