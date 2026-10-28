//
//  RoomInvites.swift
//  Conduit
//
//  Rooms with people you've linked, from the invited side (designs/
//  cross-owner-agents, C3c): someone you've linked invites this Hermes to a
//  room they host, over your Link. The invite is a row in Group Chats until
//  it's answered and after, and its join card brings your bots, each with
//  its choices for the room, or declines. The notifier plugin keeps the
//  invites for the whole installation (room_invites.py) and sends your
//  answer to the host over the rooms mailbox. A room that started is hosted
//  elsewhere: the Chats list shows it with C4.
//

import Foundation

/// A room someone you've linked invited this Hermes to, as the plugin
/// shows it.
struct RoomInvite: Identifiable, Equatable {
    /// One of your agents in it.
    struct Agent: Equatable {
        let profile: String
        let displayName: String
        /// Its handle in the room, and how it went (`left`, `removed`,
        /// `ended`): for `gone` only.
        var handle: String? = nil
        var reason: String? = nil
    }

    /// The Link and the room, as the plugin keys an invite: the same room
    /// over another Link is another invite.
    var id: String { "\(link)/\(roomID)" }
    let link: String
    let roomID: String
    /// Who invited you, by the name the Link shows them; empty for a Link
    /// without one.
    let from: String
    let name: String
    /// The other people invited, by name.
    let people: [String]
    /// The host's agents, by name.
    let hostAgents: [String]
    /// How many of your agents it has places for.
    let places: Int
    let expiresAt: Date?
    /// `waiting` (for your answer), `joined`, `declined`, `started`,
    /// `cancelled`, `left`, `ended` or `lapsed`. A status a newer plugin
    /// adds is kept as it is.
    let status: String
    /// Why it was cancelled or ended: `withdrawn`, `lapsed`, `too_few`,
    /// `start_failed`, `refused`, `started_without_you`, `removed`,
    /// `disbanded` or `left`.
    let reason: String?
    /// Your agents in it, once you joined.
    let joined: [Agent]
    /// The profiles that can join, in the plugin's order: those whose
    /// choices for it could be read.
    let profiles: [String]
    /// Each profile's choices for the room: those of its last room with the
    /// same people, else its defaults.
    let choices: [String: RoomChoices]
    /// Your agents that were in it and are out: left, taken out, or there
    /// when it ended. Their hidden chats for it stay until it's deleted.
    var gone: [Agent] = []
}

/// What Group Chats lists of the invites.
enum RoomInviteRows {
    /// Those waiting on you or on the room, and those that started, ran
    /// out, or were cancelled or ended, until they're removed. One you
    /// declined or left was your own doing, and a status a newer plugin
    /// adds isn't listed.
    static func rows(_ invites: [RoomInvite], dismissed: Set<String>) -> [RoomInvite] {
        invites.filter { invite in
            switch invite.status {
            case "waiting", "joined":
                return true
            case "started", "cancelled", "lapsed", "ended":
                return !dismissed.contains(invite.id)
            default:
                return false
            }
        }
    }

    /// One waiting on you or on the room stays.
    static func canRemove(_ invite: RoomInvite) -> Bool {
        !["waiting", "joined"].contains(invite.status)
    }
}

/// The invites as Group Chats last read them, for the dashboard they were
/// read from.
struct LinkedRoomInvites: Equatable {
    let dashboardID: UUID?
    /// Newest first.
    var invites: [RoomInvite]

    /// An invite just answered: in its place, or first.
    mutating func adopt(_ invite: RoomInvite) {
        if let index = invites.firstIndex(where: { $0.id == invite.id }) {
            invites[index] = invite
        } else {
            invites.insert(invite, at: 0)
        }
    }
}

/// One of your bots joining a room it's invited to: the handle a room of
/// your own bots would give it, and its choices for the room.
struct RoomInviteAgent: Equatable {
    let agent: RoomDraftAgent
    let choices: RoomChoices

    /// Your bots with the handles `createGroupRoom` gives them, each with
    /// its choices; nil when one has none (the plugin can't bring it) or
    /// two would claim one handle.
    static func agents(for bots: [BotProfile], choices: [String: RoomChoices]) -> [RoomInviteAgent]? {
        guard let agents = RoomDraftAgent.agents(for: bots) else { return nil }
        var joining: [RoomInviteAgent] = []
        for agent in agents {
            guard let chosen = choices[agent.profile] else { return nil }
            joining.append(RoomInviteAgent(agent: agent, choices: chosen))
        }
        return joining
    }

    /// As the plugin takes it, with every choice: the plugin fills one left
    /// out from its plain defaults, not from the join card's.
    var body: [String: Any] {
        ["profile": agent.profile, "handle": agent.handle, "display_name": agent.displayName, "choices": choices.body]
    }
}

/// How many of your bots the join card brings: at least one to join, and
/// no more than the invite has places for, nor than 5 (a room has 6
/// agents, the host's at least one of them).
enum RoomInviteLimits {
    static let maxAgents = 5

    static func canPick(picked: Int, places: Int) -> Bool {
        picked < min(places, maxAgents)
    }

    static func canJoin(picked: Int, places: Int) -> Bool {
        picked >= 1 && picked <= min(places, maxAgents)
    }

    /// The bots picked that the invite no longer lists: a read since
    /// picking them took them off.
    static func unlisted(picked: Set<String>, profiles: [String]) -> Set<String> {
        picked.subtracting(profiles)
    }
}

/// What Group Chats and the join card say about an invite.
enum RoomInviteText {
    /// Who invited you: the name the Link shows them, else who they are.
    static func sender(of invite: RoomInvite) -> String {
        invite.from.isEmpty ? AppLocalization.string("Someone you've linked with") : invite.from
    }

    /// Who invited you, where the invite stands, or why it ended.
    static func line(for invite: RoomInvite) -> String {
        let sender = sender(of: invite)
        switch invite.status {
        case "waiting":
            return AppLocalization.string("\(sender) invited you")
        case "joined":
            return AppLocalization.string("You joined, waiting for the room to start")
        case "started":
            return AppLocalization.string("Started with your agents in it")
        case "lapsed":
            return AppLocalization.string("The invite ran out")
        case "declined":
            return AppLocalization.string("You declined")
        case "left":
            return AppLocalization.string("Your agents left")
        case "cancelled":
            switch invite.reason {
            case "withdrawn":
                return AppLocalization.string("\(sender) took it back")
            case "lapsed":
                return AppLocalization.string("It ran out before the room started")
            case "too_few":
                return AppLocalization.string("Too few joined, so it didn't start")
            case "start_failed":
                return AppLocalization.string("Their Hermes couldn't start it")
            case "refused":
                return AppLocalization.string("It started, but your agents couldn't be added")
            case "started_without_you":
                return AppLocalization.string("It started without you")
            default:
                return AppLocalization.string("It was called off")
            }
        case "ended":
            switch invite.reason {
            case "removed":
                return AppLocalization.string("\(sender) took your agents out")
            case "disbanded":
                return AppLocalization.string("\(sender) ended the room")
            default:
                return AppLocalization.string("It ended")
            }
        default:
            return AppLocalization.string("It ended")
        }
    }

    /// A row's line: one waiting on you says until when.
    static func rowLine(for invite: RoomInvite) -> String {
        guard invite.status == "waiting", let expiresAt = invite.expiresAt else { return line(for: invite) }
        return AppLocalization.string("\(sender(of: invite)) invited you, answer by \(RoomDraftText.until(expiresAt))")
    }
}

/// The plugin's invites routes. Like the drafts', they take no profile:
/// the invites are the installation's. An answer waits on the rooms
/// mailbox, which takes it to the host.
struct RoomInvitesClient {
    static let capability = "room-invites"
    static let path = "/api/plugins/conduit_push/rooms/invites"

    typealias Request = RoomLinksClient.Request

    /// The dashboard the requests go to (nil in tests).
    var dashboardID: UUID?
    let request: Request

    init(dashboardID: UUID? = nil, request: @escaping Request) {
        self.dashboardID = dashboardID
        self.request = request
    }

    func invites() async throws -> [RoomInvite] {
        try Self.parseList(try await request(Self.path, "GET", nil, nil))
    }

    /// Joins with `agents`, or declines with none.
    func answer(_ invite: RoomInvite, agents: [RoomInviteAgent]) async throws -> RoomInvite {
        let body: [String: Any] = ["link": invite.link, "room_id": invite.roomID, "agents": agents.map(\.body)]
        let response = try await request("\(Self.path)/answer", "POST", body, RoomLinksClient.mailboxTimeoutMilliseconds)
        guard response["ok"] as? Bool == true, let object = response["invite"] as? [String: Any],
              let answered = Self.invite(object) else { throw HermesError.invalidResponse }
        return answered
    }

    /// An invite the list can't show (no room, Link, name or status) is
    /// left out rather than refusing the whole list.
    static func parseList(_ response: [String: Any]) throws -> [RoomInvite] {
        guard response["ok"] as? Bool == true,
              let invites = response["invites"] as? [[String: Any]] else { throw HermesError.invalidResponse }
        return invites.compactMap(invite)
    }

    static func invite(_ object: [String: Any]) -> RoomInvite? {
        guard let roomID = object["room_id"] as? String, !roomID.isEmpty,
              let link = object["link"] as? String, !link.isEmpty,
              let name = object["name"] as? String,
              let status = object["status"] as? String, !status.isEmpty else { return nil }
        var profiles: [String] = []
        var choices: [String: RoomChoices] = [:]
        for entry in object["profiles"] as? [[String: Any]] ?? [] {
            guard let profile = entry["profile"] as? String, !profile.isEmpty, choices[profile] == nil,
                  let read = (entry["choices"] as? [String: Any]).flatMap({ RoomChoicesClient.choices($0, saved: false) })
            else { continue }
            profiles.append(profile)
            choices[profile] = read
        }
        return RoomInvite(
            link: link,
            roomID: roomID,
            from: object["from"] as? String ?? "",
            name: name,
            people: (object["people"] as? [Any] ?? []).compactMap { $0 as? String },
            hostAgents: (object["agents"] as? [[String: Any]] ?? []).compactMap { $0["display_name"] as? String },
            places: object["slots"] as? Int ?? 0,
            expiresAt: RoomLinksClient.date(object["expires_at"]),
            status: status,
            reason: (object["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            joined: agents(object["joined"]),
            profiles: profiles,
            choices: choices,
            gone: goneAgents(object["gone"])
        )
    }

    private static func goneAgents(_ value: Any?) -> [RoomInvite.Agent] {
        (value as? [[String: Any]] ?? []).compactMap { agent in
            guard let profile = agent["profile"] as? String, let name = agent["display_name"] as? String else { return nil }
            return RoomInvite.Agent(profile: profile, displayName: name,
                                    handle: agent["handle"] as? String, reason: agent["reason"] as? String)
        }
    }

    private static func agents(_ value: Any?) -> [RoomInvite.Agent] {
        (value as? [[String: Any]] ?? []).compactMap { agent in
            guard let profile = agent["profile"] as? String, let name = agent["display_name"] as? String else { return nil }
            return RoomInvite.Agent(profile: profile, displayName: name)
        }
    }

    /// What a failed invites request says: the plugin's own words, as
    /// RoomLinksClient keeps them (an invite answered already, a Link no
    /// longer linked, one that ran out).
    static func message(for error: Error) -> String {
        RoomLinksClient.message(for: error)
    }

    /// Why an answer didn't go. A 504 is the mailbox taking longer than the
    /// request: the answer is still on its way.
    static func answerRefusal(for error: Error, joining: Bool) -> String {
        if case DashboardTicketBridgeError.http(504, _) = error {
            return AppLocalization.string("Your Hermes is still sending your answer. The invite shows it once it has.")
        }
        let words = message(for: error)
        return joining
            ? AppLocalization.string("Could not join: \(words)")
            : AppLocalization.string("Could not decline: \(words)")
    }
}

/// The invite a room.invite notification opens: its Link and room, from
/// the push's `room`, and the dashboard it came from.
struct RoomInviteTarget: Identifiable, Equatable {
    let link: String
    let roomID: String
    var dashboardID: UUID? = nil
    /// The push named a dashboard that isn't a UUID: it opens nothing.
    var hasMalformedDashboardID = false
    var relayGatewayID: String? = nil

    var id: String { "\(dashboardID?.uuidString ?? "-"):\(link)/\(roomID)" }

    /// A routing payload's invite: type `room.invite`, with a `room` whose
    /// Link and room ids are as the relay checks them (relay/src/server.mjs
    /// ROOM_LINK_PATTERN and ROOM_ID_PATTERN); nil for anything else.
    static func parse(_ payload: [String: Any]) -> RoomInviteTarget? {
        guard payload["type"] as? String == "room.invite",
              let room = payload["room"] as? [String: Any],
              let link = room["link"] as? String,
              link.range(of: #"\A[A-Za-z0-9_-]{1,48}\z"#, options: .regularExpression) != nil,
              let roomID = room["id"] as? String,
              roomID.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z"#, options: .regularExpression) != nil
        else { return nil }
        // As a chat's tap reads them (PushNotificationService): a dashboard
        // that isn't a UUID fails closed.
        let rawDashboardID = (payload["dashboard_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let dashboardID = rawDashboardID.isEmpty ? nil : UUID(uuidString: rawDashboardID)
        let gatewayID = (payload["gateway_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return RoomInviteTarget(
            link: link,
            roomID: roomID,
            dashboardID: dashboardID,
            hasMalformedDashboardID: !rawDashboardID.isEmpty && dashboardID == nil,
            relayGatewayID: gatewayID.isEmpty ? nil : gatewayID
        )
    }
}

/// How opening a tapped invite went.
enum RoomInviteOpening: Equatable {
    /// Its card is up.
    case opened
    /// Not yet: Conduit isn't connected, or the plugin hasn't said what it
    /// keeps. It's tried again when that changes.
    case waiting
    /// A call is on, and it said the invite opens once the call has ended.
    case afterCall
    /// The dashboard changed while the invites were read: try again, on
    /// the one in use now.
    case retry
    /// It can't open; `errorMessage` says why, or nothing will open it.
    case failed
}

/// How the join card's answer went.
enum RoomInviteAnswering: Equatable {
    case answered
    /// Not answered, with why.
    case refused(String)
    /// The mailbox is still taking it, with what that means.
    case sending(String)
}

extension AppState {
    /// Requests stay with the dashboard they were made for.
    var roomInvitesClient: RoomInvitesClient {
        let dashboard = activeDashboardID
        return RoomInvitesClient(dashboardID: dashboard) { [weak self] path, method, body, timeout in
            guard let self, self.activeDashboardID == dashboard else { throw DashboardTicketBridgeError.notReady }
            return try await self.roomRouteJSON(path: path, method: method, body: body, timeoutMilliseconds: timeout)
        }
    }

    /// The invites as last read for the dashboard in use.
    private var currentLinkedRoomInvites: LinkedRoomInvites? {
        guard canInviteLinkedPeople, let invites = linkedRoomInvites, invites.dashboardID == activeDashboardID else {
            return nil
        }
        return invites
    }

    /// Group Chats' invite rows.
    var linkedRoomInviteRows: [RoomInvite] {
        guard groupChatPhase == .available, let invites = currentLinkedRoomInvites else { return [] }
        // A room your Hermes has a copy of is listed as the room.
        let copied = linkedRoomCopyInviteIDs
        return RoomInviteRows.rows(invites.invites, dismissed: dismissedRoomInviteIDs).filter { !copied.contains($0.id) }
    }

    /// An invite by its id, whatever its status.
    func linkedRoomInvite(_ id: String) -> RoomInvite? {
        currentLinkedRoomInvites?.invites.first { $0.id == id }
    }

    /// The invites were read, and that one isn't among them any more: the
    /// plugin forgot it, so its card can't answer it.
    func linkedRoomInviteIsGone(_ id: String) -> Bool {
        guard let invites = currentLinkedRoomInvites else { return false }
        return !invites.invites.contains { $0.id == id }
    }

    /// Reads the invites. A read that fails keeps what was read last, and
    /// one that a sign-out or another dashboard overtook is dropped, as the
    /// drafts' is.
    func refreshLinkedRoomInvites() async {
        _ = await readLinkedRoomInvites()
    }

    /// Whether the invites were read now and kept.
    func readLinkedRoomInvites() async -> Bool {
        guard canInviteLinkedPeople, isConnected else { return false }
        let epoch = groupRoomEpoch
        let client = roomInvitesClient
        do {
            let invites = try await client.invites()
            guard groupRoomEpoch == epoch, activeDashboardID == client.dashboardID else { return false }
            linkedRoomInvites = LinkedRoomInvites(dashboardID: client.dashboardID, invites: invites)
            return true
        } catch {
            // The rows stay as they were: a stale row is safer than none.
            return false
        }
    }

    /// An invite that a request just answered, in the list it belongs to.
    func adoptLinkedRoomInvite(_ invite: RoomInvite, from dashboardID: UUID?) {
        guard activeDashboardID == dashboardID else { return }
        var invites = linkedRoomInvites?.dashboardID == dashboardID
            ? linkedRoomInvites ?? LinkedRoomInvites(dashboardID: dashboardID, invites: [])
            : LinkedRoomInvites(dashboardID: dashboardID, invites: [])
        invites.adopt(invite)
        linkedRoomInvites = invites
    }

    /// The join card's answer: your bots in `agents`, or none to decline. A
    /// 504 means the answer is still going to the host, so the invites are
    /// read again.
    func answerLinkedRoomInvite(_ invite: RoomInvite, agents: [RoomInviteAgent]) async -> RoomInviteAnswering {
        let client = roomInvitesClient
        do {
            let answered = try await client.answer(invite, agents: agents)
            adoptLinkedRoomInvite(answered, from: client.dashboardID)
            return .answered
        } catch {
            let message = RoomInvitesClient.answerRefusal(for: error, joining: !agents.isEmpty)
            guard case DashboardTicketBridgeError.http(504, _) = error else { return .refused(message) }
            await refreshLinkedRoomInvites()
            return .sending(message)
        }
    }

    /// A tapped invite's notification: on the dashboard that sent it,
    /// switching to it as a chat's tap does, its card once Conduit is
    /// connected, the plugin has said it keeps invites, and they've been
    /// read. During a call it waits for the call to end, and says so: the
    /// card can't open over the call's screen, and a switch would end it.
    func openRoomInvite(_ target: RoomInviteTarget) async -> RoomInviteOpening {
        let ownership = NotificationDashboardOwnership.resolve(
            targetDashboardID: target.dashboardID,
            hasMalformedDashboardID: target.hasMalformedDashboardID,
            activeDashboardID: activeDashboardID,
            savedDashboardIDs: savedDashboardRegistry.dashboards.map(\.id),
            targetGatewayID: target.relayGatewayID,
            activeDashboardGatewayIDs: activeDashboardRelayGatewayIDs
        )
        if case .failClosed(let failure) = ownership {
            switch failure {
            case .unrecognizedDashboard:
                errorMessage = AppLocalization.string("This notification belongs to a dashboard this device doesn't recognize. Add that dashboard again to continue.")
            case .unscopedPush:
                errorMessage = AppLocalization.string("This notification predates multi-dashboard pairing. Update the notifier on the sending gateway and pair it again to continue.")
            }
            return .failed
        }
        guard !isVoiceCallInProgress else {
            showCallRefusal(AppLocalization.string("This invite opens when the call ends."))
            return .afterCall
        }
        if case .switchFirst(let dashboardID) = ownership {
            await switchDashboard(to: dashboardID)
            // Still connecting waits: the connection tries again. Signing
            // in is the user's step, and a dashboard picked meanwhile owns
            // the screen.
            guard activeDashboardID == dashboardID, !showLogin else {
                errorMessage = AppLocalization.string("Could not connect to that dashboard to open this notification.")
                return .failed
            }
        }
        guard isConnected, client != nil, notifierPlugin.state != .unknown else { return .waiting }
        guard canInviteLinkedPeople else {
            errorMessage = AppLocalization.string("This invite isn't on your Hermes any more.")
            return .failed
        }
        let epoch = groupRoomEpoch
        let reader = roomInvitesClient
        let invites: [RoomInvite]
        do {
            invites = try await reader.invites()
        } catch {
            guard !Task.isCancelled else { return .waiting }
            errorMessage = AppLocalization.string("Could not open the invite: \(RoomInvitesClient.message(for: error))")
            return .failed
        }
        guard !Task.isCancelled else { return .waiting }
        guard activeDashboardID == reader.dashboardID else { return .retry }
        if groupRoomEpoch == epoch {
            linkedRoomInvites = LinkedRoomInvites(dashboardID: reader.dashboardID, invites: invites)
        }
        guard let invite = invites.first(where: { $0.link == target.link && $0.roomID == target.roomID }) else {
            errorMessage = AppLocalization.string("This invite isn't on your Hermes any more.")
            return .failed
        }
        presentedRoomInvite = invite
        return .opened
    }
}
