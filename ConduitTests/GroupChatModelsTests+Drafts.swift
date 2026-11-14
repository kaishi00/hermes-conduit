import XCTest

@testable import Conduit

/// Rooms with people you've linked (designs/cross-owner-agents, C3b): New
/// Group Chat with linked people makes a draft on this Hermes, which waits
/// for their answers in Group Chats. Notifier 0.89 (`room_invites.py`, the
/// drafts routes) and 0.99 (`?conduit_profile=` on a new draft and the
/// setup, #419). An extension, so no new class to plan.
extension GroupChatModelsTests {
    private func draftsBot(_ name: String, title: String? = nil) -> BotProfile {
        BotProfile(
            name: name,
            botTitle: title,
            displayName: "",
            profileDescription: "",
            model: nil,
            provider: nil,
            hasAvatar: false,
            isPinned: false,
            isHiddenByMeta: false,
            appearanceColor: nil,
            canonicalSession: nil,
            lastActive: nil,
            lastPreview: nil
        )
    }

    private func draftsPerson(
        _ link: String?,
        name: String? = "Laifu",
        status: String = "waiting",
        agents: [String] = []
    ) -> [String: Any] {
        var person: [String: Any] = [
            "status": status,
            "agents": agents.enumerated().map { index, agent -> [String: Any] in
                ["member_id": "l0a1b2c3d4e5f-\(index + 1)", "handle": agent.lowercased(), "display_name": agent]
            },
        ]
        if let link { person["link"] = link }
        if let name { person["name"] = name }
        return person
    }

    private func draftsDraft(
        _ id: String?,
        name: String? = "Zoo trip",
        status: String = "waiting",
        reason: String? = nil,
        people: [[String: Any]] = []
    ) -> [String: Any] {
        var draft: [String: Any] = [
            "status": status,
            "created_at": 1_790_000_000,
            "expires_at": 1_790_604_800,
            "started_at": NSNull(),
            "agents": [["profile": "default", "handle": "hermes", "display_name": "Furina"]],
            "people": people,
            "cut_off": [String](),
            "left": [String](),
            "removed": [String](),
            "members": NSNull(),
        ]
        if let id { draft["room_id"] = id }
        if let name { draft["name"] = name }
        if let reason {
            draft["reason"] = reason
        } else {
            draft["reason"] = NSNull()
        }
        return draft
    }

    /// The least of notifier 0.85's setup answer the app reads.
    private func draftsSetupAnswer() -> [String: Any] {
        let server: [String: Any] = ["address": "127.0.0.1:8642"]
        return ["ok": true, "ready": true, "needs": [String](), "api_server": server, "ceiling": [String]()]
    }

    // MARK: - The drafts

    @MainActor
    func testDraftsListReadsPeopleStatusesAndStarts() async throws {
        let client = RoomDraftsClient { path, method, body, timeout in
            XCTAssertEqual(path, "/api/plugins/conduit_push/rooms/drafts", "the list takes no profile")
            XCTAssertEqual(method, "GET")
            XCTAssertNil(body)
            XCTAssertNil(timeout)
            let starts: [String: Any] = ["available": true, "reason": NSNull()]
            return [
                "ok": true,
                "drafts": [
                    self.draftsDraft("conduit-2", people: [
                        self.draftsPerson("lk1", name: "Laifu", status: "joined", agents: ["Laifu's helper", "Scout"]),
                        self.draftsPerson("lk2", name: "Mona"),
                        self.draftsPerson("lk3", name: "Kazuha", status: "declined"),
                        // A status a newer plugin adds is kept as it is.
                        self.draftsPerson("lk4", name: "Xiao", status: "paused"),
                        // Someone the sheet can't show is left out: no Link, no name.
                        self.draftsPerson(nil, name: "Venti"),
                        self.draftsPerson("lk6", name: nil),
                    ]),
                    self.draftsDraft("conduit-1", name: "Book club", status: "ended", reason: "lapsed"),
                    // A draft the list can't show is left out: no id, no name, no status.
                    self.draftsDraft(nil, name: "Gone"),
                    self.draftsDraft("conduit-0", name: nil),
                    self.draftsDraft("conduit-3", status: ""),
                ],
                "starts": starts,
            ]
        }
        let list = try await client.drafts()
        XCTAssertEqual(list.drafts.map(\.id), ["conduit-2", "conduit-1"])
        XCTAssertTrue(list.startsAvailable)
        let zoo = try XCTUnwrap(list.drafts.first)
        XCTAssertEqual(zoo.name, "Zoo trip")
        XCTAssertEqual(zoo.status, "waiting")
        XCTAssertNil(zoo.reason)
        XCTAssertEqual(zoo.agents, ["Furina"])
        XCTAssertEqual(zoo.createdAt, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(zoo.expiresAt, Date(timeIntervalSince1970: 1_790_604_800))
        XCTAssertEqual(zoo.people, [
            RoomDraft.Person(id: "lk1", name: "Laifu", status: "joined", agents: ["Laifu's helper", "Scout"]),
            RoomDraft.Person(id: "lk2", name: "Mona", status: "waiting", agents: []),
            RoomDraft.Person(id: "lk3", name: "Kazuha", status: "declined", agents: []),
            RoomDraft.Person(id: "lk4", name: "Xiao", status: "paused", agents: []),
        ])
        XCTAssertEqual(zoo.waiting.map(\.name), ["Mona"])
        XCTAssertEqual(zoo.joined.map(\.name), ["Laifu"])
        XCTAssertEqual(list.drafts[1].status, "ended")
        XCTAssertEqual(list.drafts[1].reason, "lapsed")

        // A Hermes that can't start them says so.
        let unsupported: [String: Any] = ["available": false, "reason": "unsupported"]
        XCTAssertFalse(try RoomDraftsClient.parseList(["ok": true, "drafts": [[String: Any]](), "starts": unsupported]).startsAvailable)
        // An answer that isn't ok, or without the drafts or starts, isn't a list.
        let available: [String: Any] = ["available": true]
        XCTAssertThrowsError(try RoomDraftsClient.parseList(["ok": false, "drafts": [[String: Any]](), "starts": available]))
        XCTAssertThrowsError(try RoomDraftsClient.parseList(["ok": true, "starts": available]))
        XCTAssertThrowsError(try RoomDraftsClient.parseList(["ok": true, "drafts": [[String: Any]]()]))
    }

    /// Group Chats keeps following while a room is on its way: a draft
    /// waiting or starting, or started with its room not listed yet, and
    /// an invite you joined; nothing once each has its room or ended.
    @MainActor
    func testARoomOnItsWayKeepsGroupChatsFollowing() throws {
        let appState = draftsAppState(DraftsRoutes(drafts: []))
        let starts: [String: Any] = ["available": true, "reason": NSNull()]
        func drafts(_ statuses: [String]) throws -> LinkedRoomDrafts {
            let list = try RoomDraftsClient.parseList([
                "ok": true, "starts": starts,
                "drafts": statuses.enumerated().map { draftsDraft("conduit-\($0.offset)", status: $0.element) },
            ])
            return LinkedRoomDrafts(dashboardID: appState.activeDashboardID, list: list, people: [])
        }
        XCTAssertFalse(appState.linkedRoomOnItsWay, "nothing read, nothing on its way")
        for status in ["waiting", "starting", "started"] {
            appState.linkedRoomDrafts = try drafts(["ended", status])
            XCTAssertTrue(appState.linkedRoomOnItsWay, "a draft \(status), its room not listed")
            // Past the first 15 minutes (issue 2359) a draft waiting on
            // answers is left to its push; one starting is followed on.
            XCTAssertEqual(appState.linkedRoomOnItsWay(waiting: false), status != "waiting", status)
        }
        // Everyone who joined it did so with none of their agents (Just me): its people are still read.
        let ownOnly = GroupRoom(roomID: "conduit-1", name: "Zoo trip", members: [], authorityGatewayID: "gw", authorityEpoch: 1,
                                revision: 1, createdAt: 0, updatedAt: 0, disbandedAt: nil, latestSeq: 0)
        XCTAssertTrue(appState.hasLinkedPeople(ownOnly))
        XCTAssertFalse(appState.hasLinkedPeople(GroupRoom(roomID: "conduit-7", name: "Ours", members: [], authorityGatewayID: "gw",
                                                          authorityEpoch: 1, revision: 1, createdAt: 0, updatedAt: 0,
                                                          disbandedAt: nil, latestSeq: 0)))
        appState.linkedRoomDrafts = try drafts(["ended"])
        XCTAssertFalse(appState.linkedRoomOnItsWay, "an ended draft won't change")
        appState.linkedRoomDrafts = LinkedRoomDrafts(dashboardID: UUID(), list: try drafts(["waiting"]).list, people: [])
        XCTAssertFalse(appState.linkedRoomOnItsWay, "another dashboard's drafts aren't followed here")

        appState.linkedRoomDrafts = nil
        func invites(_ status: String) throws -> LinkedRoomInvites {
            let invite = try XCTUnwrap(RoomInvitesClient.invite([
                "room_id": "conduit-9", "link": "lk1a2b3c4d5e6f", "from": "Furina", "name": "Zoo trip",
                "status": status, "people": ["Mona"], "slots": 1,
                "expires_at": 1_790_604_800, "joined": [[String: Any]](),
            ]))
            return LinkedRoomInvites(dashboardID: appState.activeDashboardID, invites: [invite])
        }
        appState.linkedRoomInvites = try invites("joined")
        XCTAssertTrue(appState.linkedRoomOnItsWay, "an invite you joined waits for its room")
        XCTAssertFalse(appState.linkedRoomOnItsWay(waiting: false), "past 15 minutes it's left to its push")
        appState.linkedRoomInvites = try invites("waiting")
        XCTAssertFalse(appState.linkedRoomOnItsWay, "one waiting on you is yours to answer, not followed")
    }

    func testDraftRowsKeepWaitingAndEndedDraftsUntilDismissed() throws {
        let list = try RoomDraftsClient.parseList([
            "ok": true,
            "drafts": [
                draftsDraft("conduit-1", status: "waiting"),
                draftsDraft("conduit-2", status: "starting"),
                // A started one is its room's row now.
                draftsDraft("conduit-3", status: "started"),
                draftsDraft("conduit-4", status: "ended", reason: "too_few"),
                draftsDraft("conduit-5", status: "ended", reason: "lapsed"),
                // A disbanded one was a room.
                draftsDraft("conduit-6", status: "ended", reason: "disbanded"),
                // A status a newer plugin adds isn't listed.
                draftsDraft("conduit-7", status: "paused"),
            ],
            "starts": ["available": true],
        ])
        XCTAssertEqual(list.rows(dismissed: []).map(\.id), ["conduit-1", "conduit-2", "conduit-4", "conduit-5"])
        XCTAssertEqual(list.rows(dismissed: ["conduit-4", "conduit-1"]).map(\.id), ["conduit-1", "conduit-2", "conduit-5"],
                       "only an ended draft is dismissed")

        // A draft just made or answered takes its place, or goes first.
        var updated = list
        let started = try XCTUnwrap(RoomDraftsClient.draft(draftsDraft("conduit-1", status: "started")))
        updated.adopt(started)
        XCTAssertEqual(updated.drafts.first { $0.id == "conduit-1" }?.status, "started")
        XCTAssertEqual(updated.drafts.count, list.drafts.count)
        let made = try XCTUnwrap(RoomDraftsClient.draft(draftsDraft("conduit-9")))
        updated.adopt(made)
        XCTAssertEqual(updated.drafts.first?.id, "conduit-9")
    }

    // MARK: - Making one

    @MainActor
    func testCreatingWithPeoplePostsAgentsWithNullChoicesAndLinks() async throws {
        let bots = [
            draftsBot("default"),
            draftsBot("research", title: "Research Buddy"),
            // Its title's tag is taken, so it falls back to its profile's.
            draftsBot("helper", title: "research buddy"),
        ]
        // The handles a room of your own bots gives them.
        XCTAssertEqual(BotMentions.roomHandles(for: bots), ["hermes", "research-buddy", "helper"])
        let agents = try XCTUnwrap(RoomDraftAgent.agents(for: bots))
        XCTAssertEqual(agents, [
            RoomDraftAgent(profile: "default", handle: "hermes", displayName: "Default"),
            RoomDraftAgent(profile: "research", handle: "research-buddy", displayName: "Research Buddy"),
            RoomDraftAgent(profile: "helper", handle: "helper", displayName: "research buddy"),
        ])
        // A bot whose tag and profile handle are both reserved makes none.
        XCTAssertNil(RoomDraftAgent.agents(for: [draftsBot("everyone")]))
        XCTAssertNil(BotMentions.roomHandles(for: [draftsBot("everyone")]))

        var sent: (path: String, method: String, body: [String: Any]?, timeout: Int?)?
        let client = RoomDraftsClient { path, method, body, timeout in
            sent = (path, method, body, timeout)
            return ["ok": true, "draft": self.draftsDraft("conduit-9", people: [
                self.draftsPerson("lk1", name: "Laifu"),
                self.draftsPerson("lk2", name: "Mona"),
            ])]
        }
        let draft = try await client.create(name: "Zoo trip", agents: agents, links: ["lk1", "lk2"], profile: "default")
        XCTAssertEqual(draft.id, "conduit-9")
        XCTAssertEqual(draft.waiting.map(\.name), ["Laifu", "Mona"])
        let request = try XCTUnwrap(sent)
        XCTAssertEqual(request.path, "/api/plugins/conduit_push/rooms/drafts")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.timeout, RoomLinksClient.mailboxTimeoutMilliseconds, "a new draft sends its invites over the mailbox")
        let body = try XCTUnwrap(request.body)
        XCTAssertEqual(Set(body.keys), ["name", "agents", "links"])
        XCTAssertEqual(body["name"] as? String, "Zoo trip")
        XCTAssertEqual(body["links"] as? [String], ["lk1", "lk2"])
        let posted = try XCTUnwrap(body["agents"] as? [[String: Any]])
        XCTAssertEqual(posted.map { $0["profile"] as? String }, ["default", "research", "helper"])
        XCTAssertEqual(posted.map { $0["handle"] as? String }, ["hermes", "research-buddy", "helper"])
        XCTAssertEqual(posted.map { $0["display_name"] as? String }, ["Default", "Research Buddy", "research buddy"])
        for agent in posted {
            // Null, not left out: the plugin then takes the choices of the
            // last room with the same people, else the defaults.
            XCTAssertEqual(Set(agent.keys), ["profile", "handle", "display_name", "choices"])
            XCTAssertTrue(agent["choices"] is NSNull)
        }

        // An answer without its draft isn't read as made.
        let vague = RoomDraftsClient { _, _, _, _ in ["ok": true] }
        do {
            _ = try await vague.create(name: "Zoo trip", agents: agents, links: ["lk1"], profile: "default")
            XCTFail("A draft without its answer read as made")
        } catch HermesError.invalidResponse {}
    }

    func testPeopleAndBotsStayWithinSixAgents() {
        // Your bots alone: 2 to 6, as before.
        XCTAssertFalse(GroupCreateLimits.canCreate(bots: 1, people: 0))
        XCTAssertTrue(GroupCreateLimits.canCreate(bots: 2, people: 0))
        XCTAssertTrue(GroupCreateLimits.canCreate(bots: 6, people: 0))
        XCTAssertFalse(GroupCreateLimits.canCreate(bots: 7, people: 0))
        // With people, one bot is enough, and each person needs a place.
        XCTAssertFalse(GroupCreateLimits.canCreate(bots: 0, people: 1))
        XCTAssertTrue(GroupCreateLimits.canCreate(bots: 1, people: 1))
        XCTAssertTrue(GroupCreateLimits.canCreate(bots: 1, people: 5))
        XCTAssertTrue(GroupCreateLimits.canCreate(bots: 3, people: 3))
        XCTAssertFalse(GroupCreateLimits.canCreate(bots: 2, people: 5))
        XCTAssertFalse(GroupCreateLimits.canCreate(bots: 4, people: 3))
        XCTAssertFalse(GroupCreateLimits.canCreate(bots: 0, people: 6))
        // Picking stops at 6 agents in all and 5 people.
        XCTAssertTrue(GroupCreateLimits.canPickBot(bots: 5, people: 0))
        XCTAssertFalse(GroupCreateLimits.canPickBot(bots: 6, people: 0))
        XCTAssertFalse(GroupCreateLimits.canPickBot(bots: 3, people: 3))
        XCTAssertTrue(GroupCreateLimits.canPickBot(bots: 0, people: 5))
        XCTAssertTrue(GroupCreateLimits.canPickPerson(bots: 0, people: 0))
        XCTAssertTrue(GroupCreateLimits.canPickPerson(bots: 1, people: 4))
        XCTAssertFalse(GroupCreateLimits.canPickPerson(bots: 1, people: 5))
        XCTAssertFalse(GroupCreateLimits.canPickPerson(bots: 2, people: 4))
        XCTAssertFalse(GroupCreateLimits.canPickPerson(bots: 6, people: 0))
        // New Group Chat is offered with one bot when the plugin invites people.
        XCTAssertTrue(GroupCreateLimits.offersNewGroup(visibleBots: 2, invitesPeople: false))
        XCTAssertFalse(GroupCreateLimits.offersNewGroup(visibleBots: 1, invitesPeople: false))
        XCTAssertTrue(GroupCreateLimits.offersNewGroup(visibleBots: 1, invitesPeople: true))
        XCTAssertFalse(GroupCreateLimits.offersNewGroup(visibleBots: 0, invitesPeople: true))
    }

    // MARK: - Your other Hermes' bots

    func testBotsOfYourOtherHermesCountTowardSixWithinTheirShare() {
        // One bot here and one of your other Hermes make a room.
        XCTAssertTrue(GroupCreateLimits.canCreate(bots: 1, far: ["own1": 1], people: 0))
        // This Hermes hosts it: at least one of its bots.
        XCTAssertFalse(GroupCreateLimits.canCreate(bots: 0, far: ["own1": 2], people: 0))
        // Alone, the other Hermes may fill every place this one leaves.
        XCTAssertTrue(GroupCreateLimits.canCreate(bots: 1, far: ["own1": 5], people: 0))
        XCTAssertFalse(GroupCreateLimits.canCreate(bots: 2, far: ["own1": 5], people: 0))
        // With a person, the places split by Link: (6 - 2) / 2 = 2 each.
        XCTAssertTrue(GroupCreateLimits.canCreate(bots: 2, far: ["own1": 2], people: 1))
        XCTAssertFalse(GroupCreateLimits.canCreate(bots: 2, far: ["own1": 3], people: 1))
        // Two other Hermes: (6 - 2) / 2 = 2 each.
        XCTAssertTrue(GroupCreateLimits.canCreate(bots: 2, far: ["own1": 2, "own2": 2], people: 0))
        XCTAssertFalse(GroupCreateLimits.canCreate(bots: 1, far: ["own1": 4, "own2": 1], people: 0))
        // No far bots: the rules of your own and people's rooms.
        XCTAssertFalse(GroupCreateLimits.canCreate(bots: 1, far: [:], people: 0))
        XCTAssertTrue(GroupCreateLimits.canCreate(bots: 1, far: ["own1": 0], people: 1))
    }

    @MainActor
    func testADraftBringsYourOtherHermesBotsByLink() async throws {
        var sent: [String: Any]?
        let client = RoomDraftsClient { _, _, body, _ in
            sent = body
            return ["ok": true, "draft": self.draftsDraft("conduit-9")]
        }
        let agents = try XCTUnwrap(RoomDraftAgent.agents(for: [draftsBot("default")]))
        _ = try await client.create(name: "Both", agents: agents, links: ["own1"], bring: ["own1": ["yelan", "nahida"]],
                                    profile: "default")
        let body = try XCTUnwrap(sent)
        XCTAssertEqual(Set(body.keys), ["name", "agents", "links", "bring"])
        XCTAssertEqual(body["links"] as? [String], ["own1"])
        XCTAssertEqual(body["bring"] as? [String: [String]], ["own1": ["yelan", "nahida"]])
        // Nothing to bring: the body an older plugin takes.
        _ = try await client.create(name: "Both", agents: agents, links: ["lk1"], profile: "default")
        XCTAssertEqual(Set(try XCTUnwrap(sent).keys), ["name", "agents", "links"])
    }

    // MARK: - The profile

    @MainActor
    func testDraftsAndSetupSendConduitProfileOnlyWhenThePluginTakesIt() async throws {
        var plugin = NotifierPluginStatus()
        XCTAssertEqual(plugin.roomDashboardProfileParameter, "profile", "not asked yet: as before")
        plugin.state = .reported(version: "0.97.0", capabilities: ["room-invites", DashboardPath.dashboardProfilesCapability])
        XCTAssertEqual(plugin.roomDashboardProfileParameter, "profile", "the voice routes' capability doesn't cover these")
        plugin.state = .reported(version: "0.99.0", capabilities: ["room-invites", DashboardPath.roomDashboardProfilesCapability])
        XCTAssertEqual(plugin.roomDashboardProfileParameter, DashboardPath.conduitProfileParameter)

        var paths: [String] = []
        let answer: [String: Any] = ["ok": true, "draft": draftsDraft("conduit-9")]
        let agents = [RoomDraftAgent(profile: "work", handle: "work", displayName: "Work")]
        let current = RoomDraftsClient(profileParameter: DashboardPath.conduitProfileParameter) { path, _, _, _ in
            paths.append(path)
            return answer
        }
        _ = try await current.create(name: "Zoo trip", agents: agents, links: ["lk1"], profile: "work")
        _ = try await current.create(name: "Zoo trip", agents: agents, links: ["lk1"], profile: "default")
        let older = RoomDraftsClient { path, _, _, _ in
            paths.append(path)
            return answer
        }
        _ = try await older.create(name: "Zoo trip", agents: agents, links: ["lk1"], profile: "work")
        XCTAssertEqual(paths, [
            "/api/plugins/conduit_push/rooms/drafts?conduit_profile=work",
            "/api/plugins/conduit_push/rooms/drafts",
            "/api/plugins/conduit_push/rooms/drafts?profile=work",
        ])

        var setupPaths: [String] = []
        let setup = RoomSetupClient(profileParameter: DashboardPath.conduitProfileParameter) { path, _, _ in
            setupPaths.append(path)
            return self.draftsSetupAnswer()
        }
        _ = try await setup.state(profile: "work")
        _ = try await setup.setUp(profile: "work", ceiling: nil)
        _ = try await setup.state(profile: "default")
        let olderSetup = RoomSetupClient { path, _, _ in
            setupPaths.append(path)
            return self.draftsSetupAnswer()
        }
        _ = try await olderSetup.state(profile: "work")
        XCTAssertEqual(setupPaths, [
            "/api/plugins/conduit_push/rooms/setup?conduit_profile=work",
            "/api/plugins/conduit_push/rooms/setup?conduit_profile=work",
            "/api/plugins/conduit_push/rooms/setup",
            "/api/plugins/conduit_push/rooms/setup?profile=work",
        ])
    }

    // MARK: - Start now and Take back

    func testStartNowOnlyWhenItWouldMakeARoom() {
        func draft(_ answers: [String], agents: [String] = ["Furina"], status: String = "waiting") -> RoomDraft {
            RoomDraft(
                id: "conduit-1", name: "Zoo trip", status: status, reason: nil, createdAt: nil, expiresAt: nil,
                agents: agents,
                people: answers.enumerated().map { index, answer in
                    RoomDraft.Person(id: "lk\(index)", name: "Person \(index)", status: answer,
                                     agents: answer == "joined" ? ["Scout"] : [])
                }
            )
        }
        // Someone joined and someone hasn't answered: it starts with those who joined.
        XCTAssertTrue(draft(["joined", "waiting"]).canStartNow)
        // Everyone answered: it starts by itself.
        XCTAssertFalse(draft(["joined", "declined"]).canStartNow)
        // Nobody joined: two of your agents make a room, one would end it.
        XCTAssertTrue(draft(["waiting", "declined"], agents: ["Furina", "Kazuha"]).canStartNow)
        XCTAssertFalse(draft(["waiting", "declined"]).canStartNow)
        // Only while it waits.
        XCTAssertFalse(draft(["joined", "waiting"], status: "starting").canStartNow)
        XCTAssertFalse(draft(["joined", "waiting"], status: "ended").canStartNow)
    }

    @MainActor
    func testStartNowAndTakeBackPostTheRoom() async throws {
        var asked: [(path: String, method: String, body: [String: Any]?, timeout: Int?)] = []
        let client = RoomDraftsClient(profileParameter: DashboardPath.conduitProfileParameter) { path, method, body, timeout in
            asked.append((path, method, body, timeout))
            let ended = method == "DELETE"
            return ["ok": true, "draft": self.draftsDraft("conduit 1&x", status: ended ? "ended" : "waiting",
                                                         reason: ended ? "withdrawn" : nil)]
        }
        let started = try await client.start("conduit 1&x")
        let withdrawn = try await client.withdraw("conduit 1&x")
        XCTAssertEqual(started.status, "waiting", "Start now starts it on the rooms loop's next pass")
        XCTAssertEqual(withdrawn.status, "ended")
        XCTAssertEqual(withdrawn.reason, "withdrawn")
        // The room's id, and no profile: the drafts are the installation's.
        XCTAssertEqual(asked.map(\.path), [
            "/api/plugins/conduit_push/rooms/drafts/start",
            "/api/plugins/conduit_push/rooms/drafts?room_id=conduit%201%26x",
        ])
        XCTAssertEqual(asked.map(\.method), ["POST", "DELETE"])
        XCTAssertEqual(asked[0].body?["room_id"] as? String, "conduit 1&x")
        XCTAssertEqual(asked[0].body?.count, 1)
        XCTAssertNil(asked[1].body)
        // Take back tells everyone over the mailbox; Start now only marks the draft.
        XCTAssertNil(asked[0].timeout)
        XCTAssertEqual(asked[1].timeout, RoomLinksClient.mailboxTimeoutMilliseconds)

        // An answer without the draft isn't read as done.
        let vague = RoomDraftsClient { _, _, _, _ in ["ok": true] }
        do {
            _ = try await vague.start("conduit-1")
            XCTFail("A Start now without its draft read as done")
        } catch HermesError.invalidResponse {}
        do {
            _ = try await vague.withdraw("conduit-1")
            XCTFail("A Take back without its draft read as done")
        } catch HermesError.invalidResponse {}
    }

    // MARK: - What it says

    func testADraftsWaitingLineNamesWhoItWaitsFor() throws {
        func draft(status: String = "waiting", reason: String? = nil, _ people: [(String, String)] = []) throws -> RoomDraft {
            let shown = people.enumerated().map { index, person in
                draftsPerson("lk\(index)", name: person.0, status: person.1, agents: person.1 == "joined" ? ["\(person.0)'s agent"] : [])
            }
            return try XCTUnwrap(RoomDraftsClient.draft(draftsDraft("conduit-1", status: status, reason: reason, people: shown)))
        }
        let mona = RoomDraftText.names(["Mona"])
        XCTAssertEqual(mona, "Mona")
        let two = RoomDraftText.names(["Mona", "Kazuha"])
        XCTAssertTrue(two.contains("Mona") && two.contains("Kazuha"), two)

        XCTAssertEqual(RoomDraftText.line(for: try draft([("Mona", "waiting")])),
                       AppLocalization.string("Waiting for \(mona)", table: .rooms))
        XCTAssertEqual(RoomDraftText.line(for: try draft([("Mona", "waiting"), ("Kazuha", "waiting")])),
                       AppLocalization.string("Waiting for \(two)", table: .rooms))
        XCTAssertEqual(RoomDraftText.line(for: try draft([("Laifu", "joined"), ("Mona", "waiting")])),
                       AppLocalization.string("\(RoomDraftText.names(["Laifu"])) joined, waiting for \(mona)", table: .rooms))
        // Who declined isn't waited for.
        XCTAssertEqual(RoomDraftText.line(for: try draft([("Kazuha", "declined"), ("Mona", "waiting")])),
                       AppLocalization.string("Waiting for \(mona)", table: .rooms))
        // Everyone answered: it starts on the rooms loop's next pass.
        XCTAssertEqual(RoomDraftText.line(for: try draft([("Laifu", "joined"), ("Kazuha", "declined")])),
                       AppLocalization.string("Starting…"))
        XCTAssertEqual(RoomDraftText.line(for: try draft(status: "starting", [("Mona", "joined")])),
                       AppLocalization.string("Starting…"))
        // Why one ended.
        XCTAssertEqual(RoomDraftText.line(for: try draft(status: "ended", reason: "lapsed")),
                       AppLocalization.string("The invites ran out before everyone answered", table: .rooms))
        XCTAssertEqual(RoomDraftText.line(for: try draft(status: "ended", reason: "too_few")),
                       AppLocalization.string("Nobody else joined, so it didn't start", table: .rooms))
        XCTAssertEqual(RoomDraftText.line(for: try draft(status: "ended", reason: "start_failed")),
                       AppLocalization.string("Your Hermes couldn't start it", table: .rooms))
        XCTAssertEqual(RoomDraftText.line(for: try draft(status: "ended", reason: "withdrawn")),
                       AppLocalization.string("You took it back", table: .rooms))
        XCTAssertEqual(RoomDraftText.line(for: try draft(status: "ended", reason: "later")),
                       AppLocalization.string("It ended before it started", table: .rooms))

        // Each person, in the sheet.
        let people = try draft([("Laifu", "joined"), ("Mona", "waiting"), ("Kazuha", "declined"), ("Xiao", "paused")]).people
        XCTAssertEqual(people.map(RoomDraftText.status(of:)), [
            AppLocalization.string("Joined with \(RoomDraftText.names(["Laifu's agent"]))", table: .rooms),
            AppLocalization.string("Hasn't answered yet", table: .rooms),
            AppLocalization.string("Declined"),
            nil,
        ])
        // In it with none of their agents ("Just me"), and once they left.
        let alone = try XCTUnwrap(RoomDraftsClient.person(["link": "lk2", "name": "Mona", "status": "joined", "just_me": true, "agents": []]))
        XCTAssertEqual(RoomDraftText.status(of: alone), AppLocalization.string("Joined without their bots", table: .rooms))
        let gone = try XCTUnwrap(RoomDraftsClient.person(["link": "lk2", "name": "Mona", "status": "left", "just_me": false, "agents": []]))
        XCTAssertEqual(RoomDraftText.status(of: gone), AppLocalization.string("Left", table: .rooms))
    }

    func testDraftRefusalsShowThePluginsWords() {
        // The plugin's own words for a 409, a 501 and a 503.
        let tooMany = "A room has up to 6 agents: with 2 of yours, invite at most 4 people"
        XCTAssertEqual(RoomDraftsClient.message(for: DashboardTicketBridgeError.http(status: 409, detail: tooMany)), tooMany)
        let unsupported = "This Hermes can't host rooms with linked people; update Hermes"
        XCTAssertEqual(RoomDraftsClient.message(for: DashboardTicketBridgeError.http(status: 501, detail: unsupported)), unsupported)
        let apiServer = "Your Hermes' API server didn't answer for one of your agents"
        XCTAssertEqual(RoomDraftsClient.message(for: DashboardTicketBridgeError.http(status: 503, detail: apiServer)), apiServer)
        // A status with no words of its own gets Conduit's.
        let bare = DashboardTicketBridgeError.http(status: 501, detail: "")
        XCTAssertEqual(RoomDraftsClient.message(for: bare), UserFacingError.message(for: bare))

        // Making one: the reason it wasn't made, or for a 504, that the
        // invites are still going out and the draft shows once they have.
        XCTAssertEqual(RoomDraftsClient.createRefusal(for: DashboardTicketBridgeError.http(status: 409, detail: tooMany)),
                       AppLocalization.string("Could not create the group chat: \(tooMany)"))
        let timedOut = DashboardTicketBridgeError.http(
            status: 504, detail: "The rooms mailbox didn't answer in time; look at the room again in a minute")
        XCTAssertEqual(RoomDraftsClient.createRefusal(for: timedOut),
                       AppLocalization.string("Your Hermes is still sending the invites. The room shows under Group Chats once it has.", table: .rooms))
    }

    // MARK: - When the drafts are read

    /// An AppState on defaults of its own, connected to a gateway that
    /// hosts Group Chats (one room), whose plugin's rooms routes are
    /// `routes`.
    @MainActor
    private func draftsAppState(_ routes: DraftsRoutes) -> AppState {
        let suite = "GroupChatModelsTests.drafts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let room = draftsRoom()
        let methods: Set<String> = [
            "groups.list", "groups.create", "groups.state", "groups.send", "groups.log", "groups.disband", "groups.stop",
        ]
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in
                GroupCapabilities(protocolVersion: 2, driverReady: true, authorityGatewayID: "gw-a", features: [],
                                  methods: methods, maxLogLimit: 500)
            },
            list: { _ in ([room], nil) },
            state: { _, _ in (room, nil) },
            log: { _, _, sinceSeq, _ in
                GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
                             authorityGatewayID: "gw-a", authorityEpoch: 1)
            },
            send: { _, roomID, _, _, _ in
                let event = GroupDecoders.event(AnyCodable.from([
                    "room_id": roomID,
                    "seq": 1,
                    "event_id": "srv-1",
                    "kind": "message.user",
                    "actor": ["kind": "user", "id": "human"],
                    "payload": ["text": "hello", "thread_id": "main"],
                    "created_at": 1.0,
                ]))!
                return GroupSendResult(event: event, accepted: true, driverStarted: false)
            },
            roomRoute: { path, method, body, timeout in try await routes.answer(path, method, body, timeout) }
        )
        return AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: .live,
            groupChatOperations: operations,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
    }

    @MainActor
    private func draftsConnect(_ appState: AppState) {
        appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://groups.example", ticket: "groups-test"),
            profile: "default"
        )
        appState.isConnected = true
        _ = appState.adoptDashboard(forNormalizedURL: "https://groups.example")
    }

    private func draftsRoom() -> GroupRoom {
        GroupRoom(
            roomID: "room-1",
            name: "Planning",
            members: [
                GroupMember(memberID: "researcher", profile: "researcher", handle: "research-buddy",
                            displayName: "Research Buddy", target: nil, extra: [:]),
            ],
            authorityGatewayID: "gw-a",
            authorityEpoch: 1,
            revision: 1,
            createdAt: 0,
            updatedAt: 0,
            disbandedAt: nil,
            latestSeq: 0
        )
    }

    /// The plugin's answer once it makes rooms with people you've linked.
    private var draftsPluginReport: [String: Any] {
        ["ok": true, "version": "0.99.0", "capabilities": [RoomDraftsClient.capability]]
    }

    /// Waits until `condition` holds, failing after a few seconds.
    @MainActor
    private func draftsWait(
        _ what: String, until condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "timed out: \(what)", file: file, line: line)
    }

    /// A room's send and its polls read the room list, and the drafts
    /// aren't read with it: Group Chats reads them, so a send never waits
    /// on them.
    @MainActor
    func testOpeningAndSendingInARoomDontReadTheDrafts() async {
        let routes = DraftsRoutes(drafts: [draftsDraft("conduit-1")])
        let appState = draftsAppState(routes)
        draftsConnect(appState)
        appState.applyNotifierPluginReport(draftsPluginReport)
        await appState.refreshGroupChatSupport()
        XCTAssertEqual(routes.draftsReads, 1, "Group Chats reads them")
        XCTAssertEqual(appState.linkedRoomDraftRows.map(\.id), ["conduit-1"])

        await appState.openGroupRoom(draftsRoom())
        let sent = await appState.sendGroupRoomMessage("hello")
        XCTAssertTrue(sent)
        XCTAssertNil(appState.pendingRoomMessage, "it went")
        XCTAssertEqual(routes.draftsReads, 1, "the send's room list read doesn't read them")
        appState.closeGroupRoom()
    }

    /// Group Chats can be read before the plugin's status comes: the drafts
    /// are read once it says it makes them.
    @MainActor
    func testDraftsAreReadOnceThePluginSaysItMakesThem() async {
        let routes = DraftsRoutes(drafts: [draftsDraft("conduit-1")])
        let appState = draftsAppState(routes)
        draftsConnect(appState)
        await appState.refreshGroupChatSupport()
        XCTAssertEqual(appState.groupChatPhase, .available)
        XCTAssertEqual(routes.draftsReads, 0, "not before the plugin says it makes them")

        appState.applyNotifierPluginReport(draftsPluginReport)
        await draftsWait("the drafts read", until: { appState.linkedRoomDraftRows.map(\.id) == ["conduit-1"] })
        XCTAssertEqual(routes.draftsReads, 1)
    }

    /// A drafts read made before a Block that answers after it is dropped:
    /// it would bring back the blocked host's rows (issue 2347).
    @MainActor
    func testADraftsReadABlockOvertookIsDropped() async throws {
        let backend = InMemoryKeychainBackend()
        KeychainHelper.useBackendForTesting(backend)
        defer { KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend()) }
        let routes = DraftsRoutes(drafts: [draftsDraft("conduit-1")])
        routes.holdsFirstRead = true
        let appState = draftsAppState(routes)
        draftsConnect(appState)
        // Group Chats is available first, so the plugin's word reads the drafts.
        await appState.refreshGroupChatSupport()
        appState.applyNotifierPluginReport(draftsPluginReport)
        let before = Task { @MainActor in await appState.refreshLinkedRoomDrafts() }
        await draftsWait("the held read", until: { routes.holding })

        // The Block takes the host's draft away: the plugin lists it no more.
        routes.drafts = []
        let removed = try await appState.block(RoomBlockTarget(id: "lk-mona", name: "Mona"))
        XCTAssertTrue(removed)
        XCTAssertEqual(routes.unlinks, 1)
        XCTAssertEqual(appState.linkedRoomDraftRows.map(\.id), [], "Block reads the drafts again itself")

        routes.answerHeldRead()
        await before.value
        XCTAssertEqual(appState.linkedRoomDraftRows.map(\.id), [], "the read from before the Block is dropped")
    }

    /// A read from before a sign-out answers after the sign-in on the same
    /// dashboard, whose own read failed: it's dropped, as the room list's
    /// is, and shows nothing of the signed-out session.
    @MainActor
    func testADraftsReadFromBeforeASignOutIsDropped() async {
        let backend = InMemoryKeychainBackend()
        KeychainHelper.useBackendForTesting(backend)
        defer { KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend()) }
        let routes = DraftsRoutes(drafts: [draftsDraft("conduit-1")])
        routes.holdsFirstRead = true
        routes.laterReadsFail = true
        let appState = draftsAppState(routes)
        draftsConnect(appState)
        appState.applyNotifierPluginReport(draftsPluginReport)
        let before = Task { @MainActor in await appState.refreshGroupChatSupport() }
        await draftsWait("the first read", until: { routes.holding })

        appState.disconnect()
        draftsConnect(appState)
        appState.applyNotifierPluginReport(draftsPluginReport)
        await appState.refreshGroupChatSupport()
        XCTAssertEqual(routes.draftsReads, 2, "the sign-in's own read, which failed")

        routes.answerHeldRead()
        await before.value
        XCTAssertEqual(appState.groupChatPhase, .available)
        XCTAssertEqual(appState.linkedRoomDraftRows.map(\.id), [])
    }
}

/// The plugin's rooms routes behind an AppState: drafts reads are counted,
/// the first can wait until the test answers it, and Links reads fail.
@MainActor
private final class DraftsRoutes {
    /// What the plugin lists; a held read answers with what was listed when
    /// it was made.
    var drafts: [[String: Any]]
    private(set) var unlinks = 0
    /// The first drafts read waits until `answerHeldRead()`.
    var holdsFirstRead = false
    /// Drafts reads after the first fail.
    var laterReadsFail = false
    private(set) var draftsReads = 0
    private(set) var holding = false
    private var released = false

    init(drafts: [[String: Any]]) {
        self.drafts = drafts
    }

    func answer(_ path: String, _ method: String, _ body: [String: Any]?, _ timeout: Int?) async throws -> [String: Any] {
        if path == "\(RoomLinksClient.path)/links?link_id=lk-mona", method == "DELETE" {
            unlinks += 1
            return ["ok": true, "removed": true]
        }
        guard path == RoomDraftsClient.path, method == "GET" else { throw URLError(.fileDoesNotExist) }
        draftsReads += 1
        let listed = drafts
        if draftsReads == 1, holdsFirstRead {
            holding = true
            while !released, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            holding = false
        } else if draftsReads > 1, laterReadsFail {
            throw URLError(.timedOut)
        }
        let starts: [String: Any] = ["available": true, "reason": NSNull()]
        return ["ok": true, "drafts": listed, "starts": starts]
    }

    func answerHeldRead() {
        released = true
    }
}
