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
//  whichever dashboard is on screen (Eric, 2026-11-20). A tap switches to
//  that dashboard (through its kept connection) and opens the room there.
//

import Foundation

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
            var stillKept: Bool {
                keptDashboardRuntimes[id]?.client === runtime.client && activeDashboardID != id && isInCombinedGroup(id)
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
        var rooms: [GroupRoom] = []
        var offset: Int?
        for _ in 0..<combinedDashboardRoomsMaxPages {
            let page = try await client.groupsList(offset: offset)
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

    /// The dashboard of the group you talk in a room from: the one whose
    /// Hermes hosts it, else the first in Saved Dashboards order with a
    /// copy of it. Nil outside the group.
    private func combinedRoomHome(roomID: String, memberIDs: [String],
                                  in lists: [(id: UUID, rooms: [GroupRoom], copies: [RoomCopy])]) -> UUID? {
        // The one on screen first among hosts: one Hermes saved at two
        // addresses hosts the room on both, and shows it as this one's.
        let hosts = lists.filter { list in
            list.rooms.contains { $0.roomID == roomID && Self.sameRoomMembers($0.members.compactMap(\.memberID), memberIDs) }
        }
        if let host = hosts.first(where: { $0.id == activeDashboardID }) ?? hosts.first { return host.id }
        return lists.first { list in
            list.copies.contains { $0.roomID == roomID && Self.sameRoomMembers($0.members.compactMap(\.memberID), memberIDs) }
        }?.id
    }

    /// This dashboard's copies Bots Home shows: all of them outside a
    /// group; in one, only those of rooms you talk in from here, since the
    /// rest show under the dashboard that hosts them or the first with a
    /// copy (Eric, 2026-11-20: who you are in a room went with the
    /// dashboard on screen).
    var shownLinkedRoomCopyRows: [RoomCopy] {
        let copies = linkedRoomCopyRows
        guard isInCombinedGroup(activeDashboardID), !combinedDashboardRooms.isEmpty else { return copies }
        let lists = combinedGroupRoomLists
        return copies.filter { copy in
            combinedRoomHome(roomID: copy.roomID, memberIDs: copy.members.compactMap(\.memberID), in: lists)
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
    /// own order then its copies, so opening one, which switches there,
    /// moves nothing (Eric, 2026-11-21: the group chats' order shifted on
    /// a tap; it put this dashboard's first and the others newest first).
    var combinedRoomTilesAroundThisDashboard: (before: [CombinedRoomTile], after: [CombinedRoomTile]) {
        guard isInCombinedGroup(activeDashboardID), !combinedDashboardRooms.isEmpty else { return ([], []) }
        let lists = combinedGroupRoomLists
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
                guard combinedRoomHome(roomID: room.roomID, memberIDs: members, in: lists) == list.id else { continue }
                own.append(CombinedRoomTile(dashboardID: list.id, kind: .hosted(room)))
            }
            for copy in list.copies {
                let members = copy.members.compactMap(\.memberID)
                guard combinedRoomHome(roomID: copy.roomID, memberIDs: members, in: lists) == list.id else { continue }
                own.append(CombinedRoomTile(dashboardID: list.id, kind: .copy(copy)))
            }
            if passed { after += own } else { before += own }
        }
        return (before, after)
    }

    /// Opens another combined dashboard's group chat: the switch to its
    /// dashboard through its kept connection, then the room there, where
    /// you talk in it as that Hermes' own person.
    /// `inBots`: tapped on Bots Home, so its screen opens in Bots and Back
    /// returns there, as this dashboard's rooms' portraits do. The mark is
    /// made once the switch has settled, since a switch clears Bot Mode's
    /// state, an open on its way included.
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

    func openCombinedRoom(_ tile: CombinedRoomTile, inBots: Bool = false) async {
        guard !refusesCombinedSwitchDuringCall() else { return }
        dismissSidebarDrawer()
        // Opens once the dashboard is connected if it still lists the room
        // as it was left (its kept lists show at once on the switch back),
        // rather than after the switch's sync.
        await switchToCombinedDashboardUntilSettled(tile.dashboardID) { [weak self] in
            self?.listsCombinedRoomTile(tile) == true
        }
        guard !Task.isCancelled, activeDashboardID == tile.dashboardID else { return }
        let mark = inBots ? BotZoomArm.roomKey(tile.roomID) : nil
        if let mark { beginOpeningBotChat(mark) }
        defer { if let mark { endOpeningBotChat(mark) } }
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
            // The switch reads the plugin's routes after its sync settles:
            // its copies can be read once they're known.
            if !canReadRoomCopies {
                await refreshNotifierPluginStatusOnce()
                guard !Task.isCancelled, activeDashboardID == tile.dashboardID, !superseded else { return }
            }
            var found = linkedRoomCopyRows.first { $0.id == copy.id }
            // Only a list read without it shows it gone; one that couldn't
            // be read is tried again, as a hosted room's is.
            var unread = false
            if found == nil {
                let read = await readLinkedRoomCopies()
                found = read?.first { $0.id == copy.id }
                unread = read == nil
            }
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
