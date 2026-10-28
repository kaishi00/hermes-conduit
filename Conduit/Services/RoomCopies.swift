//
//  RoomCopies.swift
//  Conduit
//
//  Rooms other people host (designs/cross-owner-agents, C4a). Once a room
//  you joined starts, its home sends your Hermes its log and what it's
//  doing over your Link, and the notifier plugin keeps a copy of it
//  (room_copies.py). Group Chats lists each copy after your own rooms, and
//  its room screen reads the copy: the log as `groups.log` pages, what the
//  room is doing from the copy's state; posting in it is RoomPosts.swift
//  (C5a). One that ended can be deleted: your agents' hidden chats for it, then the
//  copy. The others keep theirs.
//

import Foundation

/// A room hosted elsewhere, as your Hermes' copy of it shows it.
struct RoomCopy: Identifiable, Equatable {
    /// A member, as the home shows it to everyone in the room.
    struct Member: Equatable {
        let memberID: String
        let handle: String?
        let displayName: String?
        /// Whose agent it is, by the name the home's Link gives them; nil
        /// for the home's own.
        let owner: String?
    }

    /// One of your agents in it.
    struct Agent: Equatable {
        let memberID: String
        let profile: String
        let handle: String?
    }

    /// The Link and the room, as its invite is keyed.
    var id: String { "\(link)/\(roomID)" }
    let roomID: String
    let name: String
    let link: String
    /// Who hosts it, by the name your Link shows them; empty for a Link
    /// without one.
    let from: String
    let members: [Member]
    /// Your agents in it, while they are; empty once they're out.
    let yours: [Agent]
    /// `started`, `left` (your agents left) or `ended`. A status a newer
    /// plugin adds is kept as it is.
    let status: String
    /// Why it ended: `disbanded`, `removed`, `left`.
    let reason: String?
    /// What it's doing, as a room's driver status: working, each member's
    /// turn and the routes to the members on other Hermes. Never the
    /// home's approvals.
    let state: GroupDriverStatus
    /// The last event the copy holds.
    let lastSeq: Int
    let updatedAt: Double

    /// It ended, or your agents left: nothing more comes, and it can be
    /// deleted.
    var isOver: Bool { status == "ended" || status == "left" }

    /// The room screen's room. Your agents are your own members, named by
    /// their profiles; everyone else's are on another Hermes, each with its
    /// owner, the host for its own.
    var room: GroupRoom {
        let host = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let members = self.members.map { member -> GroupMember in
            let agent = yours.first { $0.memberID == member.memberID }
            var shown = GroupMember(
                memberID: member.memberID,
                profile: agent?.profile,
                handle: member.handle,
                displayName: member.displayName,
                target: ["kind": .string(agent == nil ? "peer" : "local")],
                extra: [:]
            )
            if agent == nil {
                shown.owner = member.owner ?? (host.isEmpty ? nil : host)
            }
            return shown
        }
        return GroupRoom(
            roomID: roomID,
            name: name,
            members: members,
            authorityGatewayID: "",
            authorityEpoch: 0,
            revision: 0,
            createdAt: 0,
            updatedAt: updatedAt,
            disbandedAt: nil,
            latestSeq: lastSeq
        )
    }
}

/// The copies as Group Chats last read them, for the dashboard they were
/// read from.
struct LinkedRoomCopies: Equatable {
    let dashboardID: UUID?
    /// The one that changed last first.
    var copies: [RoomCopy]
}

/// What Group Chats and the room screen say about a copy.
enum RoomCopyText {
    /// The row's line: who hosts it and how it stands.
    static func line(for copy: RoomCopy) -> String {
        switch copy.status {
        case "ended":
            return AppLocalization.string("Ended")
        case "left":
            return AppLocalization.string("Your agents left")
        default:
            break
        }
        let host = copy.from.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.state.working {
            return host.isEmpty
                ? AppLocalization.string("Hosted elsewhere · working…")
                : AppLocalization.string("Hosted by \(host) · working…")
        }
        // The count in a string of its own, for its plural.
        let hostLine = self.host(for: copy)
        let members = AppLocalization.string("\(copy.members.count) members")
        return AppLocalization.string("\(hostLine) · \(members)")
    }

    /// Group Info's first line.
    static func host(for copy: RoomCopy) -> String {
        let host = copy.from.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? AppLocalization.string("Hosted elsewhere") : AppLocalization.string("Hosted by \(host)")
    }

    /// Who posts the room's people's messages, by the host's name.
    static func hostName(for copy: RoomCopy) -> String {
        let host = copy.from.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? AppLocalization.string("The host") : host
    }

    /// In the composer's place, when it can't be posted in: it's over, or
    /// the plugin doesn't post (`canPost` false).
    static func readOnly(for copy: RoomCopy, canPost: Bool) -> String {
        let host = copy.from.trimmingCharacters(in: .whitespacesAndNewlines)
        if canPost {
            return host.isEmpty
                ? AppLocalization.string("Hosted elsewhere. You can read it here.")
                : AppLocalization.string("Hosted by \(host). You can read it here.")
        }
        return host.isEmpty
            ? AppLocalization.string("Hosted elsewhere. Update the Conduit plugin on your Hermes to post in it.")
            : AppLocalization.string("Hosted by \(host). Update the Conduit plugin on your Hermes to post in it.")
    }

    static var deleteTitle: String { AppLocalization.string("Delete this room?") }
    static var deleteMessage: String {
        AppLocalization.string("Your copy of it and your agents' chats for it are deleted from your Hermes. The others keep theirs.")
    }

    static func deleteRefusal(for error: Error) -> String {
        AppLocalization.string("Could not delete this room: \(RoomLinksClient.message(for: error))")
    }
}

/// Deleting a copy.
enum RoomCopyDeletion: Equatable {
    case deleted
    /// The plugin's words; the copy stays.
    case refused(String)
    /// Still going: your agents leave it first (C4b).
    case notOver
}

/// The plugin's copies routes. Like the invites', they take no profile: the
/// copies are the installation's. Deleting an agent's chats for a room goes
/// to that agent's profile.
struct RoomCopiesClient {
    static let capability = "room-copies"
    /// `DELETE /rooms/sessions`.
    static let forgetCapability = "room-forget"
    static let path = "/api/plugins/conduit_push/rooms/copies"
    static let sessionsPath = "/api/plugins/conduit_push/rooms/sessions"
    /// room_copies.MAX_LOG_LIMIT.
    static let maxLogLimit = 500

    typealias Request = RoomLinksClient.Request

    /// The dashboard the requests go to (nil in tests).
    var dashboardID: UUID?
    let request: Request

    init(dashboardID: UUID? = nil, request: @escaping Request) {
        self.dashboardID = dashboardID
        self.request = request
    }

    func copies() async throws -> [RoomCopy] {
        try Self.parseList(try await request(Self.path, "GET", nil, nil))
    }

    /// The copy's events after `sinceSeq`, as a `groups.log` page.
    func log(roomID: String, sinceSeq: Int, limit: Int) async throws -> GroupLogPage {
        guard let room = DashboardPath.encodedQueryComponent(roomID) else { throw HermesError.invalidResponse }
        let bounded = min(max(1, limit), Self.maxLogLimit)
        let response = try await request(
            "\(Self.path)/log?room_id=\(room)&since_seq=\(max(0, sinceSeq))&limit=\(bounded)", "GET", nil, nil)
        return try Self.parseLog(response)
    }

    /// Deletes the copy.
    func forget(roomID: String) async throws {
        guard let room = DashboardPath.encodedQueryComponent(roomID) else { throw HermesError.invalidResponse }
        let response = try await request("\(Self.path)?room_id=\(room)", "DELETE", nil, nil)
        guard response["ok"] as? Bool == true else { throw HermesError.invalidResponse }
    }

    /// Deletes `profile`'s hidden chats for the room.
    func forgetSessions(roomID: String, profile: String) async throws {
        guard let room = DashboardPath.encodedQueryComponent(roomID) else { throw HermesError.invalidResponse }
        let path = DashboardPath.withProfile("\(Self.sessionsPath)?room_id=\(room)", profile: profile)
        let response = try await request(path, "DELETE", nil, nil)
        guard response["ok"] as? Bool == true else { throw HermesError.invalidResponse }
    }

    /// A copy without a room id, Link or name is left out rather than
    /// refusing the whole list.
    static func parseList(_ response: [String: Any]) throws -> [RoomCopy] {
        guard response["ok"] as? Bool == true,
              let copies = response["copies"] as? [[String: Any]] else { throw HermesError.invalidResponse }
        return copies.compactMap(copy)
    }

    static func copy(_ object: [String: Any]) -> RoomCopy? {
        guard let roomID = text(object["room_id"]), let link = text(object["link"]),
              let name = text(object["name"]),
              let status = text(object["status"]) else { return nil }
        let members = (object["members"] as? [[String: Any]] ?? []).compactMap { member -> RoomCopy.Member? in
            guard let memberID = text(member["member_id"]) else { return nil }
            return RoomCopy.Member(
                memberID: memberID,
                handle: text(member["handle"]),
                displayName: text(member["display_name"]),
                owner: text(member["owner"])
            )
        }
        let yours = (object["yours"] as? [[String: Any]] ?? []).compactMap { agent -> RoomCopy.Agent? in
            guard let memberID = text(agent["member_id"]), let profile = text(agent["profile"]) else { return nil }
            return RoomCopy.Agent(memberID: memberID, profile: profile, handle: text(agent["handle"]))
        }
        return RoomCopy(
            roomID: roomID,
            name: name,
            link: link,
            from: object["from"] as? String ?? "",
            members: members,
            yours: yours,
            status: status,
            reason: text(object["reason"]),
            state: state(object["state"] as? [String: Any] ?? [:]),
            lastSeq: object["last_seq"] as? Int ?? 0,
            updatedAt: (object["updated_at"] as? NSNumber)?.doubleValue ?? 0
        )
    }

    /// The copy's state as the room screen reads a driver's: working, each
    /// member's turn, the routes. No approvals: those are the home's.
    static func state(_ object: [String: Any]) -> GroupDriverStatus {
        func pairs(_ key: String) -> [(String, String)] {
            (object[key] as? [[String: Any]] ?? []).compactMap { pair in
                guard let member = text(pair["member_id"]), let status = text(pair["status"]) else { return nil }
                return (member, status)
            }
        }
        let working = object["working"] as? Bool == true
        return GroupDriverStatus(
            running: false,
            working: working,
            blocked: false,
            counts: [:],
            pendingActions: [],
            peerRoutes: pairs("routes").map { GroupPeerRoute(memberID: $0.0, status: .init(wire: $0.1)) },
            memberActivity: pairs("activity").map { GroupMemberActivity(memberID: $0.0, status: $0.1) }
        )
    }

    /// A `/rooms/copies/log` answer, which has `groups.log`'s shape.
    static func parseLog(_ response: [String: Any]) throws -> GroupLogPage {
        guard response["ok"] as? Bool == true,
              let page = GroupDecoders.logPage(AnyCodable(jsonObject: response)) else { throw HermesError.invalidResponse }
        return page
    }

    /// A string with something in it, else nil.
    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// Whether the copy is gone: the plugin has none for the room.
    static func isNoCopy(_ error: Error) -> Bool {
        if case DashboardTicketBridgeError.http(404, _) = error { return true }
        return false
    }
}

/// Who's who in a room over Links, by member id (`GET /rooms/people`);
/// read by `RoomPeople.people` (RoomLeave.swift).
enum RoomPeople {
    static let path = "/api/plugins/conduit_push/rooms/people"
}

extension AppState {
    /// Whether the host's plugin keeps copies of rooms other people host.
    /// Not in `usedCapabilities`, as with Links.
    var canReadRoomCopies: Bool {
        notifierPlugin.reports(RoomCopiesClient.capability)
    }

    /// Whether an ended copy can be deleted, with your agents' chats for it.
    var canDeleteRoomCopies: Bool {
        canReadRoomCopies && notifierPlugin.reports(RoomCopiesClient.forgetCapability)
    }

    /// Requests stay with the dashboard they were made for.
    var roomCopiesClient: RoomCopiesClient {
        let dashboard = activeDashboardID
        return RoomCopiesClient(dashboardID: dashboard) { [weak self] path, method, body, timeout in
            guard let self, self.activeDashboardID == dashboard else { throw DashboardTicketBridgeError.notReady }
            return try await self.roomRouteJSON(path: path, method: method, body: body, timeoutMilliseconds: timeout)
        }
    }

    /// The copies as last read for the dashboard in use.
    private var currentLinkedRoomCopies: LinkedRoomCopies? {
        guard canReadRoomCopies, let copies = linkedRoomCopies, copies.dashboardID == activeDashboardID else {
            return nil
        }
        return copies
    }

    /// Group Chats' rows of rooms other people host.
    var linkedRoomCopyRows: [RoomCopy] {
        guard groupChatPhase == .available else { return [] }
        return currentLinkedRoomCopies?.copies ?? []
    }

    /// The rooms your Hermes has a copy of, by invite id (Link and room),
    /// which Group Chats lists in their invites' place.
    var linkedRoomCopyInviteIDs: Set<String> {
        Set((currentLinkedRoomCopies?.copies ?? []).map(\.id))
    }

    /// Reads the copies. A read that fails keeps what was read last, and
    /// one that a sign-out or another dashboard overtook is dropped, as the
    /// invites' is.
    func refreshLinkedRoomCopies() async {
        _ = await readLinkedRoomCopies()
    }

    /// The copies read now, kept for Group Chats; nil when the read failed
    /// or was overtaken.
    func readLinkedRoomCopies() async -> [RoomCopy]? {
        guard canReadRoomCopies, isConnected else { return nil }
        let epoch = groupRoomEpoch
        let generation = linkedRoomCopiesGeneration
        let client = roomCopiesClient
        // A read a delete overtook could still list the deleted copy.
        guard let copies = try? await client.copies(), groupRoomEpoch == epoch,
              linkedRoomCopiesGeneration == generation, activeDashboardID == client.dashboardID else { return nil }
        let read = LinkedRoomCopies(dashboardID: client.dashboardID, copies: copies)
        // The room screen reads them each quiet tick: unchanged, nothing is published.
        if read != linkedRoomCopies { linkedRoomCopies = read }
        return copies
    }

    /// Your agents' approvals in the open room, when it's hosted elsewhere:
    /// its room screen shows their cards.
    var activeRoomCopyApprovals: [RoomApproval] {
        guard let copy = activeRoomSurface?.copy else { return [] }
        // Room ids are only unique per host: one without its Link is this
        // room's only when no other copy has the same id.
        let shared = (linkedRoomCopies?.copies ?? []).contains { $0.roomID == copy.roomID && $0.link != copy.link }
        return linkedRoomApprovalRows.filter {
            $0.roomID == copy.roomID && ($0.link == copy.link || ($0.link == nil && !shared))
        }
    }

    /// Deletes an ended copy: each of your agents' hidden chats for it,
    /// then the copy. A refusal keeps the copy and says the plugin's words.
    func deleteLinkedRoomCopy(_ copy: RoomCopy) async -> RoomCopyDeletion {
        guard copy.isOver else { return .notOver }
        guard canDeleteRoomCopies else { return .refused(RoomCopyText.deleteRefusal(for: HermesError.invalidResponse)) }
        let client = roomCopiesClient
        let inviteID = copy.id
        // Your agents that left are only on its invite, whatever `yours`
        // still lists: without it read now, their chats would stay behind.
        guard await readLinkedRoomInvites() else {
            return .refused(RoomCopyText.deleteRefusal(for: HermesError.invalidResponse))
        }
        let invite = linkedRoomInvite(inviteID)
        var profiles: [String] = []
        for profile in copy.yours.map(\.profile) + (invite?.joined.map(\.profile) ?? []) + (invite?.gone.map(\.profile) ?? [])
        where !profile.isEmpty && !profiles.contains(profile) {
            profiles.append(profile)
        }
        do {
            for profile in profiles {
                try await client.forgetSessions(roomID: copy.roomID, profile: profile)
            }
            try await client.forget(roomID: copy.roomID)
        } catch {
            return .refused(RoomCopyText.deleteRefusal(for: error))
        }
        linkedRoomCopiesGeneration &+= 1
        if var copies = linkedRoomCopies, copies.dashboardID == client.dashboardID {
            copies.copies.removeAll { $0.id == copy.id }
            linkedRoomCopies = copies
        }
        // Its invite, ended, would take its row back.
        dismissRoomInvite(inviteID)
        guard activeDashboardID == client.dashboardID else { return .deleted }
        if activeRoomSurface?.copy?.id == copy.id {
            closeGroupRoom()
        }
        return .deleted
    }
}
