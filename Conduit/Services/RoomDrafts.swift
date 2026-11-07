//
//  RoomDrafts.swift
//  Conduit
//
//  Rooms with people you've linked (designs/cross-owner-agents, C3b): New
//  Group Chat with linked people makes a draft on this Hermes, which sends
//  each of them an invite over their Link and waits for their answers. The
//  host's notifier plugin keeps the drafts for the whole installation
//  (room_invites.py) and starts the room in Hermes once everyone has
//  answered, or with Start now. A started draft is its room, which
//  `groups.list` shows under the same id; until then the draft is a row in
//  Group Chats, and one that ended says why until it's removed.
//

import Foundation

/// A room this Hermes hosts with people you've linked, as the plugin shows it.
struct RoomDraft: Identifiable, Equatable {
    /// Someone invited, by their Link.
    struct Person: Identifiable, Equatable {
        /// The Link's id.
        let id: String
        let name: String
        /// `waiting`, `joined` or `declined`. A status a newer plugin adds
        /// is kept as it is and shown with none.
        let status: String
        /// The names of the agents they joined with.
        let agents: [String]
    }

    /// The room's id, which the room keeps once it starts.
    let id: String
    let name: String
    /// `waiting`, `starting` (the rooms loop is starting it), `started` or
    /// `ended`. One that ran out reads as ended.
    let status: String
    /// Why it ended: `withdrawn`, `lapsed`, `too_few`, `start_failed`, or
    /// `disbanded` once its room was.
    let reason: String?
    let createdAt: Date?
    /// When the invites run out.
    let expiresAt: Date?
    /// The names of your agents in it.
    let agents: [String]
    let people: [Person]

    var waiting: [Person] { people.filter { $0.status == "waiting" } }
    var joined: [Person] { people.filter { $0.status == "joined" } }

    /// Start now makes a room: someone hasn't answered (else it starts by
    /// itself), and someone has joined or two of your agents are in it
    /// (else it ends with no room, `too_few`).
    var canStartNow: Bool {
        status == "waiting" && !waiting.isEmpty && (!joined.isEmpty || agents.count >= 2)
    }
}

struct RoomDraftsList: Equatable {
    /// Newest first.
    var drafts: [RoomDraft]
    /// False on a Hermes the plugin can't start rooms with linked people on
    /// (`starts.reason` is `unsupported`).
    var startsAvailable: Bool

    /// What Group Chats lists: the drafts waiting or starting, and those
    /// that ended until they're removed. A started one is its room's row, a
    /// disbanded one was a room, and a status a newer plugin adds isn't
    /// listed.
    func rows(dismissed: Set<String>) -> [RoomDraft] {
        drafts.filter { draft in
            switch draft.status {
            case "waiting", "starting":
                return true
            case "ended":
                return draft.reason != "disbanded" && !dismissed.contains(draft.id)
            default:
                return false
            }
        }
    }

    /// A draft just made or answered: in its place, or first.
    mutating func adopt(_ draft: RoomDraft) {
        if let index = drafts.firstIndex(where: { $0.id == draft.id }) {
            drafts[index] = draft
        } else {
            drafts.insert(draft, at: 0)
        }
    }
}

/// The drafts as Group Chats last read them, with the people you can
/// invite, for the dashboard they were read from.
struct LinkedRoomDrafts: Equatable {
    let dashboardID: UUID?
    var list: RoomDraftsList
    /// Your Links that are linked: the people New Group Chat can invite.
    var people: [RoomLink]
}

/// How New Group Chat's request for a draft went.
enum LinkedRoomDraftCreation: Equatable {
    case made
    /// Not made; `errorMessage` says why.
    case refused
    /// Made, with its invites still going out when the request gave up:
    /// the same picks again would invite everyone twice.
    case sending
}

/// One of your agents in a new draft: its profile, the handle a room of
/// your own bots would give it, and its name.
struct RoomDraftAgent: Equatable {
    let profile: String
    let handle: String
    let displayName: String

    /// Your bots as a draft's agents, with the handles `createGroupRoom`
    /// gives them; nil when two would claim one handle.
    static func agents(for bots: [BotProfile]) -> [RoomDraftAgent]? {
        guard let handles = BotMentions.roomHandles(for: bots) else { return nil }
        return zip(bots, handles).map { bot, handle in
            RoomDraftAgent(profile: bot.name, handle: handle, displayName: bot.displayLabel)
        }
    }

    /// As the plugin takes it. Its choices are null, not left out: the
    /// plugin then gives it those of its last room with the same people,
    /// else its defaults, and Group Info changes them once the room starts.
    var body: [String: Any] {
        ["profile": profile, "handle": handle, "display_name": displayName, "choices": NSNull()]
    }
}

/// New Group Chat's limits: 2 to 6 of your bots, or with people you've
/// linked, at least one bot and a place for each person, up to 6 agents in
/// all and 5 people (room_invites.py's MAX_AGENTS and MAX_LINKS).
enum GroupCreateLimits {
    static let maxAgents = 6
    static let maxPeople = 5

    static func canCreate(bots: Int, people: Int) -> Bool {
        guard people > 0 else { return (2...maxAgents).contains(bots) }
        return bots >= 1 && people <= maxPeople && bots + people <= maxAgents
    }

    static func canPickBot(bots: Int, people: Int) -> Bool {
        bots + people < maxAgents
    }

    static func canPickPerson(bots: Int, people: Int) -> Bool {
        people < maxPeople && bots + people < maxAgents
    }

    /// One bot is enough when there's someone to invite.
    static func offersNewGroup(visibleBots: Int, invitesPeople: Bool) -> Bool {
        visibleBots >= 2 || (invitesPeople && visibleBots >= 1)
    }
}

/// What Group Chats and a draft's sheet say about a draft.
enum RoomDraftText {
    /// Names as a list in the app's language ("Mona and Kazuha").
    static func names(_ names: [String]) -> String {
        names.formatted(.list(type: .and).locale(AppLocalization.formattingLocale))
    }

    /// When invites run out. They run for a week, so the day comes with
    /// the time.
    static func until(_ date: Date) -> String {
        date.formatted(
            .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute().locale(AppLocalization.formattingLocale)
        )
    }

    /// Who it waits for, that it's starting, or why it ended.
    static func line(for draft: RoomDraft) -> String {
        switch draft.status {
        case "ended":
            switch draft.reason {
            case "lapsed":
                return AppLocalization.string("The invites ran out before everyone answered")
            case "too_few":
                return AppLocalization.string("Nobody else joined, so it didn't start")
            case "start_failed":
                return AppLocalization.string("Your Hermes couldn't start it")
            case "withdrawn":
                return AppLocalization.string("You took it back")
            default:
                return AppLocalization.string("It ended before it started")
            }
        case "waiting":
            // Everyone answered: the rooms loop starts it on its next pass.
            guard !draft.waiting.isEmpty else { return AppLocalization.string("Starting…") }
            let waiting = names(draft.waiting.map(\.name))
            let joined = draft.joined.map(\.name)
            guard !joined.isEmpty else { return AppLocalization.string("Waiting for \(waiting)") }
            return AppLocalization.string("\(names(joined)) joined, waiting for \(waiting)")
        default:
            return AppLocalization.string("Starting…")
        }
    }

    /// How someone answered, or nil for a status a newer plugin adds.
    static func status(of person: RoomDraft.Person) -> String? {
        switch person.status {
        case "joined":
            return AppLocalization.string("Joined with \(names(person.agents))")
        case "waiting":
            return AppLocalization.string("Hasn't answered yet")
        case "declined":
            return AppLocalization.string("Declined")
        default:
            return nil
        }
    }
}

/// The plugin's drafts routes. They take no profile but a new draft's,
/// whose room service the room starts in: the drafts are the
/// installation's. Making one and taking one back wait on the rooms
/// mailbox, which carries the invites and the word that it's off.
struct RoomDraftsClient {
    static let capability = "room-invites"
    static let path = "/api/plugins/conduit_push/rooms/drafts"

    typealias Request = RoomLinksClient.Request

    /// The dashboard the requests go to (nil in tests).
    var dashboardID: UUID?
    /// What names a new draft's profile: `profile`, or `conduit_profile`
    /// on a plugin that takes it there (`room-dashboard-profiles`).
    var profileParameter: String
    let request: Request

    init(dashboardID: UUID? = nil, profileParameter: String = "profile", request: @escaping Request) {
        self.dashboardID = dashboardID
        self.profileParameter = profileParameter
        self.request = request
    }

    func drafts() async throws -> RoomDraftsList {
        try Self.parseList(try await request(Self.path, "GET", nil, nil))
    }

    /// A room with the people of `links` and your `agents`, waiting for
    /// their answers, made in the room service `profile`'s requests use.
    func create(name: String, agents: [RoomDraftAgent], links: [String], profile: String) async throws -> RoomDraft {
        let path = DashboardPath.withProfile(Self.path, profile: profile, parameter: profileParameter)
        let body: [String: Any] = ["name": name, "agents": agents.map(\.body), "links": links]
        return try Self.parseDraft(try await request(path, "POST", body, RoomLinksClient.mailboxTimeoutMilliseconds))
    }

    /// Start now: the room starts with whoever has joined on the rooms
    /// loop's next pass, and the rest are told it started without them.
    func start(_ roomID: String) async throws -> RoomDraft {
        try Self.parseDraft(try await request("\(Self.path)/start", "POST", ["room_id": roomID], nil))
    }

    /// Take back: everyone invited who hasn't declined is told, and their
    /// Hermes undoes their agents' joins.
    func withdraw(_ roomID: String) async throws -> RoomDraft {
        guard let room = DashboardPath.encodedQueryComponent(roomID) else { throw HermesError.invalidResponse }
        let response = try await request("\(Self.path)?room_id=\(room)", "DELETE", nil, RoomLinksClient.mailboxTimeoutMilliseconds)
        return try Self.parseDraft(response)
    }

    /// A draft or a person the list can't show (no id, name or status) is
    /// left out rather than refusing the whole list.
    static func parseList(_ response: [String: Any]) throws -> RoomDraftsList {
        guard response["ok"] as? Bool == true,
              let drafts = response["drafts"] as? [[String: Any]],
              let starts = response["starts"] as? [String: Any] else { throw HermesError.invalidResponse }
        return RoomDraftsList(drafts: drafts.compactMap(draft), startsAvailable: starts["available"] as? Bool ?? false)
    }

    static func parseDraft(_ response: [String: Any]) throws -> RoomDraft {
        guard response["ok"] as? Bool == true, let object = response["draft"] as? [String: Any],
              let draft = Self.draft(object) else { throw HermesError.invalidResponse }
        return draft
    }

    static func draft(_ object: [String: Any]) -> RoomDraft? {
        guard let id = object["room_id"] as? String, !id.isEmpty,
              let name = object["name"] as? String,
              let status = object["status"] as? String, !status.isEmpty else { return nil }
        return RoomDraft(
            id: id,
            name: name,
            status: status,
            reason: (object["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            createdAt: RoomLinksClient.date(object["created_at"]),
            expiresAt: RoomLinksClient.date(object["expires_at"]),
            agents: names(object["agents"]),
            people: (object["people"] as? [[String: Any]] ?? []).compactMap(person)
        )
    }

    static func person(_ object: [String: Any]) -> RoomDraft.Person? {
        guard let link = object["link"] as? String, !link.isEmpty,
              let name = object["name"] as? String,
              let status = object["status"] as? String else { return nil }
        return RoomDraft.Person(id: link, name: name, status: status, agents: names(object["agents"]))
    }

    /// The agents' display names.
    private static func names(_ value: Any?) -> [String] {
        (value as? [[String: Any]] ?? []).compactMap { $0["display_name"] as? String }
    }

    /// What a failed drafts request says: the plugin's own words, as
    /// RoomLinksClient keeps them, and a 501's too, which the plugin
    /// answers on a Hermes that can't host rooms with linked people.
    static func message(for error: Error) -> String {
        if case DashboardTicketBridgeError.http(let status, let detail) = error, status == 501,
           let words = DashboardTicketBridgeError.meaningfulDetail(detail, status: status) {
            return words
        }
        return RoomLinksClient.message(for: error)
    }

    /// Why New Group Chat didn't make one. A 504 is the mailbox taking
    /// longer than the request: the draft was made, and its invites are
    /// still going out.
    static func createRefusal(for error: Error) -> String {
        if case DashboardTicketBridgeError.http(504, _) = error {
            return AppLocalization.string("Your Hermes is still sending the invites. The room shows under Group Chats once it has.")
        }
        return AppLocalization.string("Could not create the group chat: \(message(for: error))")
    }
}

extension BotMentions {
    /// The handle each bot takes in a room of yours, in order: its mention
    /// tag, or its profile's handle when another bot took the tag. Never
    /// `@all` or `@everyone`, nor `@user`, the room's person, who a member
    /// claiming it would be styled as. Nil when two bots would claim one.
    static func roomHandles(for bots: [BotProfile]) -> [String]? {
        var used: Set<String> = ["all", "everyone", "user"]
        var handles: [String] = []
        for bot in bots {
            var tag = mentionTag(for: bot)
            if used.contains(tag.lowercased()) {
                tag = handle(for: bot)
            }
            guard isValidMentionToken(tag), !used.contains(tag.lowercased()) else { return nil }
            used.insert(tag.lowercased())
            handles.append(tag)
        }
        return handles
    }
}

extension AppState {
    /// Whether the host's plugin makes rooms with people you've linked. Not
    /// in `usedCapabilities`, as with Links.
    var canInviteLinkedPeople: Bool {
        notifierPlugin.reports(RoomDraftsClient.capability)
    }

    /// Requests stay with the dashboard they were made for.
    var roomDraftsClient: RoomDraftsClient {
        let dashboard = activeDashboardID
        let parameter = notifierPlugin.roomDashboardProfileParameter
        return RoomDraftsClient(dashboardID: dashboard, profileParameter: parameter) { [weak self] path, method, body, timeout in
            guard let self, self.activeDashboardID == dashboard else { throw DashboardTicketBridgeError.notReady }
            return try await self.roomRouteJSON(path: path, method: method, body: body, timeoutMilliseconds: timeout)
        }
    }

    /// The drafts as last read for the dashboard in use.
    private var currentLinkedRoomDrafts: LinkedRoomDrafts? {
        guard canInviteLinkedPeople, groupChatPhase == .available,
              let drafts = linkedRoomDrafts, drafts.dashboardID == activeDashboardID else { return nil }
        return drafts
    }

    /// Group Chats' draft rows.
    var linkedRoomDraftRows: [RoomDraft] {
        currentLinkedRoomDrafts?.list.rows(dismissed: dismissedRoomDraftIDs) ?? []
    }

    /// A draft by its room's id, started or not.
    func linkedRoomDraft(_ roomID: String) -> RoomDraft? {
        currentLinkedRoomDrafts?.list.drafts.first { $0.id == roomID }
    }

    /// The people New Group Chat can invite: none while this Hermes can't
    /// start rooms with them.
    var invitableLinkedPeople: [RoomLink] {
        guard let drafts = currentLinkedRoomDrafts, drafts.list.startsAvailable else { return [] }
        return drafts.people
    }

    /// There are people to invite, but this Hermes can't start rooms with
    /// them, which New Group Chat says.
    var linkedRoomStartsUnavailable: Bool {
        guard let drafts = currentLinkedRoomDrafts else { return false }
        return !drafts.list.startsAvailable && !drafts.people.isEmpty
    }

    /// Reads the drafts, with your Links unless `readingPeople` is false
    /// (a draft's sheet, which reads them every few seconds). A read that
    /// fails keeps what was read last, and one that a sign-out or another
    /// dashboard overtook is dropped, as the room list's is.
    func refreshLinkedRoomDrafts(readingPeople: Bool = true) async {
        guard canInviteLinkedPeople, groupChatPhase == .available, isConnected else { return }
        let epoch = groupRoomEpoch
        let client = roomDraftsClient
        let links = roomLinksClient
        do {
            let list = try await client.drafts()
            var people = linkedRoomDrafts?.dashboardID == client.dashboardID ? linkedRoomDrafts?.people : nil
            if readingPeople || people == nil, let read = try? await links.list() {
                people = read.links.filter { $0.status == "linked" }
            }
            guard groupRoomEpoch == epoch, activeDashboardID == client.dashboardID else { return }
            linkedRoomDrafts = LinkedRoomDrafts(dashboardID: client.dashboardID, list: list, people: people ?? [])
        } catch {
            // The rows stay as they were: a stale row is safer than none.
        }
    }

    /// The drafts, the people to invite and the invites, read once the
    /// host's plugin is first known to make rooms with people you've
    /// linked, and the approvals once it's first known to list them: Group
    /// Chats may have been read before its status came.
    func linkedRoomInvitesReported(before couldInvite: Bool, approvals couldAnswer: Bool) {
        guard groupChatPhase == .available, isConnected else { return }
        let invites = !couldInvite && canInviteLinkedPeople
        let approvals = !couldAnswer && canAnswerRoomApprovals
        guard invites || approvals else { return }
        Task {
            if invites {
                await refreshLinkedRoomDrafts()
                await refreshLinkedRoomInvites()
            }
            if approvals {
                await refreshLinkedRoomApprovals()
            }
        }
    }

    /// A draft that a request just made or answered, in the list it
    /// belongs to.
    func adoptLinkedRoomDraft(_ draft: RoomDraft, from dashboardID: UUID?) {
        guard activeDashboardID == dashboardID, var drafts = linkedRoomDrafts, drafts.dashboardID == dashboardID else { return }
        drafts.list.adopt(draft)
        linkedRoomDrafts = drafts
    }

    /// New Group Chat with people you've linked: a draft on this Hermes,
    /// which invites them and waits for their answers. The sheet shows why
    /// one wasn't made.
    func createLinkedRoomDraft(name: String, bots: [BotProfile], links: [String]) async -> LinkedRoomDraftCreation {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canInviteLinkedPeople, isConnected else {
            errorMessage = AppLocalization.string("Connect to Hermes to create a group chat.")
            return .refused
        }
        guard GroupCreateLimits.canCreate(bots: bots.count, people: links.count) else {
            errorMessage = AppLocalization.string("A room holds up to 6 agents: your bots, and at least one for each person.")
            return .refused
        }
        guard !trimmedName.isEmpty else { return .refused }
        errorMessage = nil
        guard let agents = RoomDraftAgent.agents(for: bots) else {
            errorMessage = AppLocalization.string(
                "Two of these bots would claim the same @handle. Rename one bot's title, then try again."
            )
            return .refused
        }
        let client = roomDraftsClient
        do {
            let draft = try await client.create(name: trimmedName, agents: agents, links: links, profile: activeProfile)
            adoptLinkedRoomDraft(draft, from: client.dashboardID)
            if linkedRoomDraft(draft.id) == nil {
                await refreshLinkedRoomDrafts(readingPeople: false)
            }
            return .made
        } catch {
            guard activeDashboardID == client.dashboardID else { return .refused }
            errorMessage = RoomDraftsClient.createRefusal(for: error)
            guard case DashboardTicketBridgeError.http(504, _) = error else { return .refused }
            // It was made: its row shows once read.
            await refreshLinkedRoomDrafts(readingPeople: false)
            return .sending
        }
    }
}
