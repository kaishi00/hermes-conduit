//
//  RoomLeave.swift
//  Conduit
//
//  Taking agents out of rooms over Links (designs/cross-owner-agents, C4b):
//  your agents leave a room someone else hosts (POST /rooms/leave), you take
//  another person's agent out of a room you host (POST /rooms/drafts/remove),
//  and Group Info says who left or was taken out (GET /rooms/people).
//

import Foundation

/// How a member is out of a room over Links.
enum RoomMemberOut: String, Equatable, Codable {
    /// Its owner took it out (`left`).
    case left
    /// The room's host took it out (`removed`).
    case removed
}

/// A member as `GET /rooms/people` shows it.
struct RoomPerson: Equatable {
    /// Its owner as your Link names them; nil for yours.
    let owner: String?
    /// Yours: the plugin's owner is null.
    let isYours: Bool
    let out: RoomMemberOut?
}

/// What leaving or taking out answered.
enum RoomLeaveResult: Equatable {
    case done
    /// The plugin's words.
    case refused(String)
    /// Your Hermes is still telling the others (a 504): what it says.
    case sending(String)
}

enum RoomLeaveText {
    static func outLine(_ out: RoomMemberOut) -> String {
        switch out {
        case .left: return AppLocalization.string("Left the room", table: .rooms)
        case .removed: return AppLocalization.string("Taken out", table: .rooms)
        }
    }

    static func takeOutTitle(_ name: String) -> String {
        AppLocalization.string("Take \(name) out of this room?", table: .rooms)
    }

    /// A bot of your other Hermes, in a room of only your own Hermes (either
    /// side's Take Out, and Leave on the far side).
    static func takeOutOwnMessage(_ name: String) -> String {
        AppLocalization.string("\(name) stops taking part, and your other Hermes is told.", table: .rooms)
    }

    static var leaveOwnMessage: String {
        AppLocalization.string(
            "Your bots stop taking part, and your other Hermes is told. Your copy of the room and their chats for it stay until you delete it.", table: .rooms)
    }

    /// Another person's agent, in a room you host.
    static func takeOutMessage(_ name: String, owner: String?) -> String {
        if let owner = owner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty {
            return AppLocalization.string("\(name) stops taking part, and \(owner)'s Hermes is told.", table: .rooms)
        }
        return AppLocalization.string("\(name) stops taking part, and their Hermes is told.", table: .rooms)
    }

    /// Your agent, in a room someone else hosts.
    static func takeOutMessage(_ name: String, in copy: RoomCopy) -> String {
        let host = copy.from.trimmingCharacters(in: .whitespacesAndNewlines)
        if !host.isEmpty {
            return AppLocalization.string("\(name) stops taking part, and \(host) is told.", table: .rooms)
        }
        return AppLocalization.string("\(name) stops taking part, and the host is told.", table: .rooms)
    }

    static var leaveTitle: String { AppLocalization.string("Leave this room?", table: .rooms) }

    static func leaveMessage(_ copy: RoomCopy) -> String {
        let host = copy.from.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.justMe {
            return host.isEmpty
                ? AppLocalization.string("You stop getting this room, and the host is told. Your copy of it stays until you delete it.", table: .rooms)
                : AppLocalization.string("You stop getting this room, and \(host) is told. Your copy of it stays until you delete it.", table: .rooms)
        }
        if !host.isEmpty {
            return AppLocalization.string(
                "Your agents stop taking part, and \(host) is told. Your copy of the room and their chats for it stay until you delete it.", table: .rooms)
        }
        return AppLocalization.string(
            "Your agents stop taking part, and the host is told. Your copy of the room and their chats for it stay until you delete it.", table: .rooms)
    }

    static func takeOutRefusal(for error: Error) -> String {
        AppLocalization.string("Could not take this agent out: \(RoomLinksClient.message(for: error))", table: .rooms)
    }

    static func leaveRefusal(for error: Error) -> String {
        AppLocalization.string("Could not leave this room: \(RoomLinksClient.message(for: error))", table: .rooms)
    }

    static var stillSendingTitle: String { AppLocalization.string("Still on its way", table: .rooms) }

    static var stillSending: String {
        AppLocalization.string("Your Hermes is still sending this. The room shows it once it has.", table: .rooms)
    }

    /// A 504: the mailbox hasn't answered yet, and the change may be made.
    static func isStillSending(_ error: Error) -> Bool {
        if case DashboardTicketBridgeError.http(504, _) = error { return true }
        return false
    }
}

/// The plugin's routes for taking agents out. Like the invites', they take
/// no profile, and wait on the mailbox.
struct RoomLeaveClient {
    static let capability = "room-leave"
    static let leavePath = "/api/plugins/conduit_push/rooms/leave"
    static let removePath = "/api/plugins/conduit_push/rooms/drafts/remove"

    typealias Request = RoomLinksClient.Request

    /// The dashboard the requests go to (nil in tests).
    var dashboardID: UUID?
    let request: Request

    init(dashboardID: UUID? = nil, request: @escaping Request) {
        self.dashboardID = dashboardID
        self.request = request
    }

    /// Your agents of `profiles` out of the room someone else hosts, or all
    /// still in (nil). Answers its invite as the join card shows it.
    func leave(link: String, roomID: String, profiles: [String]?) async throws -> RoomInvite {
        let body: [String: Any] = ["link": link, "room_id": roomID, "agents": profiles.map { $0 as Any } ?? NSNull()]
        let response = try await request(Self.leavePath, "POST", body, RoomLinksClient.mailboxTimeoutMilliseconds)
        guard response["ok"] as? Bool == true, let object = response["invite"] as? [String: Any],
              let invite = RoomInvitesClient.invite(object) else { throw HermesError.invalidResponse }
        return invite
    }

    /// Another person's agent out of a room you host, by its member id.
    func remove(roomID: String, memberID: String) async throws {
        let body: [String: Any] = ["room_id": roomID, "member": memberID]
        let response = try await request(Self.removePath, "POST", body, RoomLinksClient.mailboxTimeoutMilliseconds)
        guard response["ok"] as? Bool == true else { throw HermesError.invalidResponse }
    }
}

extension RoomPeople {
    /// Each member by id: its owner, whether it's yours, and how it's out.
    static func people(_ response: [String: Any]) -> [String: RoomPerson] {
        guard response["ok"] as? Bool == true else { return [:] }
        var people: [String: RoomPerson] = [:]
        for member in response["members"] as? [[String: Any]] ?? [] {
            guard let id = member["member_id"] as? String, !id.isEmpty else { continue }
            let raw = member["owner"]
            let owner = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            people[id] = RoomPerson(
                owner: owner?.isEmpty == false ? owner : nil,
                isYours: raw == nil || raw is NSNull,
                out: (member["status"] as? String).flatMap(RoomMemberOut.init(rawValue:))
            )
        }
        return people
    }
}

extension AppState {
    /// Whether the host's plugin takes agents out of rooms over Links. Not
    /// in `usedCapabilities`, as with Links.
    var canLeaveLinkedRooms: Bool {
        notifierPlugin.reports(RoomLeaveClient.capability)
    }

    /// Requests stay with the dashboard they were made for.
    var roomLeaveClient: RoomLeaveClient {
        let dashboard = activeDashboardID
        return RoomLeaveClient(dashboardID: dashboard) { [weak self] path, method, body, timeout in
            guard let self, self.activeDashboardID == dashboard else { throw DashboardTicketBridgeError.notReady }
            return try await self.roomRouteJSON(path: path, method: method, body: body, timeoutMilliseconds: timeout)
        }
    }

    /// The open room's member that can be taken out: another person's
    /// agent still in a room you host.
    func canTakeOut(_ member: GroupMember) -> Bool {
        guard canLeaveLinkedRooms, let surface = activeRoomSurface, member.memberID?.isEmpty == false else {
            return false
        }
        guard member.out == nil else { return false }
        if let copy = surface.copy {
            return !copy.isOver && !member.isPeer && member.profile?.isEmpty == false
        }
        return member.isPeer
    }

    /// Whether your agents, or you with Just me, can leave the open room
    /// someone else hosts.
    var canLeaveActiveRoom: Bool {
        guard canLeaveLinkedRooms, let copy = activeRoomSurface?.copy else { return false }
        return !copy.isOver && (!copy.yours.isEmpty || copy.justMe)
    }

    /// Takes `member` out of the open room: your agent out of a room someone
    /// else hosts, or another person's out of yours. Who's in is read again.
    func takeOut(_ member: GroupMember) async -> RoomLeaveResult {
        guard canTakeOut(member), let surface = activeRoomSurface, let memberID = member.memberID else {
            return .refused(RoomLeaveText.takeOutRefusal(for: HermesError.invalidResponse))
        }
        let client = roomLeaveClient
        do {
            if let copy = surface.copy, let profile = member.profile {
                let invite = try await client.leave(link: copy.link, roomID: copy.roomID, profiles: [profile])
                linkedRosterGeneration &+= 1
                adoptLinkedRoomInvite(invite, from: client.dashboardID)
            } else {
                try await client.remove(roomID: surface.room.roomID, memberID: memberID)
                linkedRosterGeneration &+= 1
            }
        } catch {
            return await refused(error, in: surface, saying: RoomLeaveText.takeOutRefusal(for: error))
        }
        await afterTakingOut(surface)
        return .done
    }

    /// All your agents out of the open room someone else hosts. Its copy
    /// stays, ended for you, to delete when you like.
    func leaveActiveRoom() async -> RoomLeaveResult {
        guard canLeaveActiveRoom, let surface = activeRoomSurface, let copy = surface.copy else {
            return .refused(RoomLeaveText.leaveRefusal(for: HermesError.invalidResponse))
        }
        let client = roomLeaveClient
        do {
            let invite = try await client.leave(link: copy.link, roomID: copy.roomID, profiles: nil)
            // A read issued before the leave could put back what it changed.
            linkedRosterGeneration &+= 1
            adoptLinkedRoomInvite(invite, from: client.dashboardID)
        } catch {
            return await refused(error, in: surface, saying: RoomLeaveText.leaveRefusal(for: error))
        }
        await afterTakingOut(surface)
        return .done
    }

    /// A refusal's words; for a 504, which may have been made, the room is
    /// read again (with its invite, for a copy) and says it's still going.
    private func refused(_ error: Error, in surface: GroupRoomSurface, saying words: String) async -> RoomLeaveResult {
        guard RoomLeaveText.isStillSending(error) else { return .refused(words) }
        if surface.copy != nil { await refreshLinkedRoomInvites() }
        await afterTakingOut(surface)
        return .sending(RoomLeaveText.stillSending)
    }

    /// Who's in, read again for the room still open; for a copy, the copy
    /// too, which says your agents left.
    private func afterTakingOut(_ surface: GroupRoomSurface) async {
        guard activeRoomSurface?.dashboardID == surface.dashboardID,
              activeRoomSurface?.room.roomID == surface.room.roomID else { return }
        if surface.copy != nil {
            await refreshActiveRoomCopy()
        }
        await refreshActiveRoomPeople()
    }
}
