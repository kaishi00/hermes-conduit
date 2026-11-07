import XCTest

@testable import Conduit

/// Rooms with people you've linked, from the invited side (designs/
/// cross-owner-agents, C3c): someone you've linked invites this Hermes to a
/// room they host, and its join card brings your bots with their choices,
/// or declines. Notifier 0.89 (`room_invites.py`, the invites routes). An
/// extension, so no new class to plan.
extension GroupChatModelsTests {
    private func invitesBot(_ name: String, title: String? = nil) -> BotProfile {
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

    /// Choices as the plugin fills them (room_choices.RoomChoices.as_dict);
    /// nil leaves a field out, as a plugin from before it did.
    private func invitesChoices(
        tools: String = "talk",
        share: String = "ask",
        takesPart: String? = "joins",
        dailyLimit: Int? = 40
    ) -> [String: Any] {
        var choices: [String: Any] = [
            "tools": tools, "custom_tools": [String](), "share": share, "search_chats": false, "note": "",
        ]
        if let takesPart { choices["takes_part"] = takesPart }
        if let dailyLimit { choices["daily_limit"] = dailyLimit }
        return choices
    }

    /// An invite as `GET /rooms/invites` shows it (room_invites._shown_invite).
    private func invitesInvite(
        _ roomID: String?,
        link: String? = "lk1a2b3c4d5e6f",
        from: String = "Furina",
        name: String? = "Zoo trip",
        status: String? = "waiting",
        reason: String? = nil,
        joined: [[String: Any]] = [],
        profiles: [[String: Any]]? = nil
    ) -> [String: Any] {
        var invite: [String: Any] = [
            "from": from,
            "people": ["Mona"],
            "agents": [
                ["handle": "furina", "display_name": "Furina's helper"],
                ["handle": "scout", "display_name": "Scout"],
            ],
            "slots": 2,
            "expires_at": 1_790_604_800,
            "joined": joined,
            "gone": [[String: Any]](),
            "profiles": profiles ?? [
                ["profile": "default", "choices": invitesChoices()],
                ["profile": "research", "choices": invitesChoices(tools: "look", share: "helps", takesPart: "asked", dailyLimit: 10)],
            ],
        ]
        if let roomID { invite["room_id"] = roomID }
        if let link { invite["link"] = link }
        if let name { invite["name"] = name }
        if let status { invite["status"] = status }
        if let reason {
            invite["reason"] = reason
        } else {
            invite["reason"] = NSNull()
        }
        return invite
    }

    func testInvitesListReadsStatusesPlacesAndEachProfilesChoices() async throws {
        let client = RoomInvitesClient { path, method, body, timeout in
            XCTAssertEqual(path, "/api/plugins/conduit_push/rooms/invites", "the list takes no profile")
            XCTAssertEqual(method, "GET")
            XCTAssertNil(body)
            XCTAssertNil(timeout)
            return [
                "ok": true,
                "invites": [
                    self.invitesInvite("conduit-2", profiles: [
                        ["profile": "default", "choices": self.invitesChoices()],
                        // A plugin from before how it takes part and its turns a day.
                        ["profile": "research", "choices": self.invitesChoices(tools: "look", share: "helps", takesPart: nil, dailyLimit: nil)],
                        // Choices that can't be read, or no profile: it can't be brought.
                        ["profile": "helper", "choices": ["tools": "talk"]],
                        ["choices": self.invitesChoices()],
                    ]),
                    self.invitesInvite("conduit-1", from: "", name: "Book club", status: "joined", joined: [
                        ["profile": "default", "handle": "hermes", "display_name": "Hermes"],
                    ]),
                    // An invite the list can't show is left out: no room, Link, name or status.
                    self.invitesInvite(nil),
                    self.invitesInvite("conduit-3", link: nil),
                    self.invitesInvite("conduit-4", name: nil),
                    self.invitesInvite("conduit-5", status: ""),
                ],
            ]
        }
        let invites = try await client.invites()
        XCTAssertEqual(invites.map(\.roomID), ["conduit-2", "conduit-1"])
        let zoo = try XCTUnwrap(invites.first)
        XCTAssertEqual(zoo.id, "lk1a2b3c4d5e6f/conduit-2", "the Link and the room, as the plugin keys it")
        XCTAssertEqual(zoo.link, "lk1a2b3c4d5e6f")
        XCTAssertEqual(zoo.from, "Furina")
        XCTAssertEqual(zoo.name, "Zoo trip")
        XCTAssertEqual(zoo.people, ["Mona"])
        XCTAssertEqual(zoo.hostAgents, ["Furina's helper", "Scout"])
        XCTAssertEqual(zoo.places, 2)
        XCTAssertEqual(zoo.expiresAt, Date(timeIntervalSince1970: 1_790_604_800))
        XCTAssertEqual(zoo.status, "waiting")
        XCTAssertNil(zoo.reason)
        XCTAssertEqual(zoo.joined, [])
        XCTAssertEqual(zoo.profiles, ["default", "research"])
        XCTAssertEqual(zoo.choices["default"], RoomChoices(
            tools: "talk", customTools: [], share: "ask", searchChats: false, takesPart: "joins", dailyLimit: 40,
            note: "", saved: false
        ))
        XCTAssertEqual(zoo.choices["research"]?.tools, "look")
        XCTAssertEqual(zoo.choices["research"]?.share, "helps")
        XCTAssertEqual(zoo.choices["research"]?.takesPart, "joins")
        XCTAssertEqual(zoo.choices["research"]?.dailyLimit, 40)
        XCTAssertNil(zoo.choices["helper"])
        let book = invites[1]
        XCTAssertEqual(book.from, "", "a Link without a name")
        XCTAssertEqual(book.status, "joined")
        XCTAssertEqual(book.joined, [RoomInvite.Agent(profile: "default", displayName: "Hermes")])

        // An answer that isn't ok, or without the invites, isn't a list.
        XCTAssertThrowsError(try RoomInvitesClient.parseList(["ok": false, "invites": [[String: Any]]()]))
        XCTAssertThrowsError(try RoomInvitesClient.parseList(["ok": true]))
    }

    func testInviteRowsHideDeclinedAndKeepEndedUntilDismissed() throws {
        let invites = try RoomInvitesClient.parseList([
            "ok": true,
            "invites": [
                invitesInvite("conduit-1", status: "waiting"),
                invitesInvite("conduit-2", status: "joined"),
                invitesInvite("conduit-3", status: "started"),
                invitesInvite("conduit-4", status: "cancelled", reason: "withdrawn"),
                invitesInvite("conduit-5", status: "lapsed"),
                invitesInvite("conduit-6", status: "ended", reason: "disbanded"),
                // Your own doing: no row.
                invitesInvite("conduit-7", status: "declined"),
                invitesInvite("conduit-8", status: "left", reason: "left"),
                // A status a newer plugin adds isn't listed.
                invitesInvite("conduit-9", status: "paused"),
            ],
        ])
        let rows = RoomInviteRows.rows(invites, dismissed: [])
        XCTAssertEqual(rows.map(\.roomID), ["conduit-1", "conduit-2", "conduit-3", "conduit-4", "conduit-5", "conduit-6"])
        XCTAssertEqual(rows.map(RoomInviteRows.canRemove), [false, false, true, true, true, true],
                       "one that waits on you or on the room stays")
        let removed = Set((1...4).map { "lk1a2b3c4d5e6f/conduit-\($0)" })
        XCTAssertEqual(RoomInviteRows.rows(invites, dismissed: removed).map(\.roomID),
                       ["conduit-1", "conduit-2", "conduit-5", "conduit-6"])

        // An invite just answered takes its place, or goes first.
        var list = LinkedRoomInvites(dashboardID: nil, invites: invites)
        let joined = try XCTUnwrap(RoomInvitesClient.invite(invitesInvite("conduit-1", status: "joined")))
        list.adopt(joined)
        XCTAssertEqual(list.invites.first { $0.roomID == "conduit-1" }?.status, "joined")
        XCTAssertEqual(list.invites.count, invites.count)
        let other = try XCTUnwrap(RoomInvitesClient.invite(invitesInvite("conduit-1", link: "lk9z8y7x6w5v")))
        list.adopt(other)
        XCTAssertEqual(list.invites.first?.id, "lk9z8y7x6w5v/conduit-1", "the same room over another Link is another invite")
        XCTAssertEqual(list.invites.count, invites.count + 1)
    }

    // MARK: - Answering

    @MainActor
    func testJoiningPostsEachBotWithItsHandleAndAllItsChoices() async throws {
        let invite = try XCTUnwrap(RoomInvitesClient.invite(invitesInvite("conduit-2")))
        let bots = [invitesBot("default"), invitesBot("research", title: "Research Buddy")]
        var choices = invite.choices
        choices["research"]?.takesPart = "listens"
        choices["research"]?.dailyLimit = 150
        let agents = try XCTUnwrap(RoomInviteAgent.agents(for: bots, choices: choices))
        // The handles a room of your own bots gives them.
        XCTAssertEqual(agents.map(\.agent), [
            RoomDraftAgent(profile: "default", handle: "hermes", displayName: "default"),
            RoomDraftAgent(profile: "research", handle: "research-buddy", displayName: "Research Buddy"),
        ])
        // A bot the invite has no choices for can't come, nor two that
        // would claim one handle.
        XCTAssertNil(RoomInviteAgent.agents(for: [invitesBot("helper")], choices: choices))
        XCTAssertNil(RoomInviteAgent.agents(for: [invitesBot("everyone")], choices: ["everyone": try XCTUnwrap(choices["default"])]))

        var sent: (path: String, method: String, body: [String: Any]?, timeout: Int?)?
        let client = RoomInvitesClient { path, method, body, timeout in
            sent = (path, method, body, timeout)
            return ["ok": true, "invite": self.invitesInvite("conduit-2", status: "joined", joined: [
                ["profile": "default", "handle": "hermes", "display_name": "default"],
                ["profile": "research", "handle": "research-buddy", "display_name": "Research Buddy"],
            ])]
        }
        let answered = try await client.answer(invite, agents: agents)
        XCTAssertEqual(answered.status, "joined")
        XCTAssertEqual(answered.joined.map(\.profile), ["default", "research"])
        let request = try XCTUnwrap(sent)
        XCTAssertEqual(request.path, "/api/plugins/conduit_push/rooms/invites/answer")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.timeout, RoomLinksClient.mailboxTimeoutMilliseconds, "the answer goes over the mailbox")
        let body = try XCTUnwrap(request.body)
        XCTAssertEqual(Set(body.keys), ["link", "room_id", "agents"])
        XCTAssertEqual(body["link"] as? String, "lk1a2b3c4d5e6f")
        XCTAssertEqual(body["room_id"] as? String, "conduit-2")
        let posted = try XCTUnwrap(body["agents"] as? [[String: Any]])
        XCTAssertEqual(posted.map { $0["profile"] as? String }, ["default", "research"])
        XCTAssertEqual(posted.map { $0["handle"] as? String }, ["hermes", "research-buddy"])
        XCTAssertEqual(posted.map { $0["display_name"] as? String }, ["default", "Research Buddy"])
        // Every choice, not only those changed: the plugin fills one left
        // out from its plain defaults, not from the card's.
        let research = try XCTUnwrap(posted.last?["choices"] as? [String: Any])
        XCTAssertEqual(Set(research.keys), ["tools", "custom_tools", "share", "search_chats", "takes_part", "daily_limit", "note"])
        XCTAssertEqual(research["tools"] as? String, "look")
        XCTAssertEqual(research["custom_tools"] as? [String], [])
        XCTAssertEqual(research["share"] as? String, "helps")
        XCTAssertEqual(research["search_chats"] as? Bool, false)
        XCTAssertEqual(research["takes_part"] as? String, "listens")
        XCTAssertEqual(research["daily_limit"] as? Int, 150)
        XCTAssertEqual(research["note"] as? String, "")

        // An answer without its invite isn't read as answered.
        let vague = RoomInvitesClient { _, _, _, _ in ["ok": true] }
        do {
            _ = try await vague.answer(invite, agents: agents)
            XCTFail("An answer without its invite read as answered")
        } catch HermesError.invalidResponse {}
    }

    @MainActor
    func testDecliningPostsNoAgents() async throws {
        let invite = try XCTUnwrap(RoomInvitesClient.invite(invitesInvite("conduit-2")))
        var body: [String: Any]?
        let client = RoomInvitesClient { _, _, sent, _ in
            body = sent
            return ["ok": true, "invite": self.invitesInvite("conduit-2", status: "declined")]
        }
        let declined = try await client.answer(invite, agents: [])
        XCTAssertEqual(declined.status, "declined")
        let agents = try XCTUnwrap(body?["agents"] as? [Any])
        XCTAssertTrue(agents.isEmpty, "no agents is a decline")
        XCTAssertEqual(body?["room_id"] as? String, "conduit-2")
    }

    func testBringStopsAtTheInvitesPlaces() {
        XCTAssertTrue(RoomInviteLimits.canPick(picked: 0, places: 2))
        XCTAssertTrue(RoomInviteLimits.canPick(picked: 1, places: 2))
        XCTAssertFalse(RoomInviteLimits.canPick(picked: 2, places: 2))
        XCTAssertFalse(RoomInviteLimits.canPick(picked: 0, places: 0))
        // At most 5 of yours: a room holds 6 agents, one of them the host's at least.
        XCTAssertTrue(RoomInviteLimits.canPick(picked: 4, places: 9))
        XCTAssertFalse(RoomInviteLimits.canPick(picked: 5, places: 9))
        XCTAssertFalse(RoomInviteLimits.canJoin(picked: 0, places: 2), "joining with none is declining")
        XCTAssertTrue(RoomInviteLimits.canJoin(picked: 1, places: 2))
        XCTAssertTrue(RoomInviteLimits.canJoin(picked: 2, places: 2))
        XCTAssertFalse(RoomInviteLimits.canJoin(picked: 3, places: 2))
    }

    func testInviteRefusalsShowThePluginsWords() {
        // The plugin's own words for a 404, a 409 and a 410.
        let notLinked = "This Hermes isn't linked with them any more"
        XCTAssertEqual(RoomInvitesClient.message(for: DashboardTicketBridgeError.http(status: 404, detail: notLinked)), notLinked)
        let answered = "This invite has been answered"
        XCTAssertEqual(RoomInvitesClient.answerRefusal(for: DashboardTicketBridgeError.http(status: 409, detail: answered), joining: true),
                       AppLocalization.string("Could not join: \(answered)"))
        let lapsed = "This invite ran out"
        XCTAssertEqual(RoomInvitesClient.answerRefusal(for: DashboardTicketBridgeError.http(status: 410, detail: lapsed), joining: false),
                       AppLocalization.string("Could not decline: \(lapsed)"))
        // A 504: the answer is still on its way over the mailbox.
        let timedOut = DashboardTicketBridgeError.http(
            status: 504, detail: "The rooms mailbox didn't answer in time; look at the room again in a minute")
        XCTAssertEqual(RoomInvitesClient.answerRefusal(for: timedOut, joining: true),
                       AppLocalization.string("Your Hermes is still sending your answer. The invite shows it once it has."))
        XCTAssertEqual(RoomInvitesClient.answerRefusal(for: timedOut, joining: false),
                       AppLocalization.string("Your Hermes is still sending your answer. The invite shows it once it has."))
    }

    // MARK: - What it says

    func testAnInvitesStatusLineSaysWhyItEnded() throws {
        func line(_ status: String, reason: String? = nil, from: String = "Furina") throws -> String {
            RoomInviteText.line(for: try XCTUnwrap(RoomInvitesClient.invite(
                invitesInvite("conduit-1", from: from, status: status, reason: reason)
            )))
        }
        let furina = "Furina"
        let someone = AppLocalization.string("Someone you've linked with")
        XCTAssertEqual(try line("waiting"), AppLocalization.string("\(furina) invited you"))
        XCTAssertEqual(try line("waiting", from: ""), AppLocalization.string("\(someone) invited you"))
        XCTAssertEqual(try line("joined"), AppLocalization.string("You joined, waiting for the room to start"))
        XCTAssertEqual(try line("started"), AppLocalization.string("Started with your agents in it"))
        XCTAssertEqual(try line("lapsed"), AppLocalization.string("The invite ran out"))
        XCTAssertEqual(try line("declined"), AppLocalization.string("You declined"))
        XCTAssertEqual(try line("left", reason: "left"), AppLocalization.string("Your agents left"))
        // Why it was called off, before it started.
        XCTAssertEqual(try line("cancelled", reason: "withdrawn"), AppLocalization.string("\(furina) took it back"))
        XCTAssertEqual(try line("cancelled", reason: "withdrawn", from: ""), AppLocalization.string("\(someone) took it back"))
        XCTAssertEqual(try line("cancelled", reason: "lapsed"), AppLocalization.string("It ran out before the room started"))
        XCTAssertEqual(try line("cancelled", reason: "too_few"), AppLocalization.string("Too few joined, so it didn't start"))
        XCTAssertEqual(try line("cancelled", reason: "start_failed"), AppLocalization.string("Their Hermes couldn't start it"))
        XCTAssertEqual(try line("cancelled", reason: "refused"),
                       AppLocalization.string("It started, but your agents couldn't be added"))
        XCTAssertEqual(try line("cancelled", reason: "started_without_you"), AppLocalization.string("It started without you"))
        XCTAssertEqual(try line("cancelled", reason: "later"), AppLocalization.string("It was called off"))
        // Why it ended, once it had started.
        XCTAssertEqual(try line("ended", reason: "removed"), AppLocalization.string("\(furina) took your agents out"))
        XCTAssertEqual(try line("ended", reason: "disbanded"), AppLocalization.string("\(furina) ended the room"))
        XCTAssertEqual(try line("ended", reason: "later"), AppLocalization.string("It ended"))
    }

    func testRoomChoicesReadTakesPartAndTurnsADay() throws {
        let read = try RoomChoicesClient.parse([
            "ok": true, "room_id": "conduit-1", "saved": true,
            "choices": invitesChoices(tools: "look", takesPart: "asked", dailyLimit: 300),
        ], roomID: "conduit-1")
        XCTAssertEqual(read.takesPart, "asked")
        XCTAssertEqual(read.dailyLimit, 300)
        XCTAssertTrue(read.saved)
        // A plugin from before them: its defaults.
        let older = try RoomChoicesClient.parse(["ok": true, "choices": invitesChoices(takesPart: nil, dailyLimit: nil)],
                                                roomID: "conduit-1")
        XCTAssertEqual(older.takesPart, "joins")
        XCTAssertEqual(older.dailyLimit, 40)

        // Every choice goes back, as the plugin takes them.
        let body = read.body
        XCTAssertEqual(Set(body.keys), ["tools", "custom_tools", "share", "search_chats", "takes_part", "daily_limit", "note"])
        XCTAssertEqual(body["tools"] as? String, "look")
        XCTAssertEqual(body["takes_part"] as? String, "asked")
        XCTAssertEqual(body["daily_limit"] as? Int, 300)

        // Turns a day: the card's steps, with its own number when it's another.
        XCTAssertEqual(RoomChoices.dailyLimitSteps(including: 40), [5, 10, 20, 40, 80, 150, 300, 500])
        XCTAssertEqual(RoomChoices.dailyLimitSteps(including: 7), [5, 7, 10, 20, 40, 80, 150, 300, 500])
        XCTAssertEqual(RoomChoices.dailyLimitSteps(including: 1), [1, 5, 10, 20, 40, 80, 150, 300, 500])
    }

    // MARK: - When the invites are read

    /// An AppState on defaults of its own, connected to a gateway that
    /// hosts Group Chats, whose plugin's rooms routes are `routes`.
    @MainActor
    private func invitesAppState(_ routes: InvitesRoutes) -> AppState {
        let suite = "GroupChatModelsTests.invites.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in
                GroupCapabilities(protocolVersion: 2, driverReady: true, authorityGatewayID: "gw-a", features: [],
                                  methods: ["groups.list", "groups.create", "groups.state", "groups.send", "groups.log", "groups.disband"],
                                  maxLogLimit: 500)
            },
            list: { _ in ([], nil) },
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
    private func invitesConnect(_ appState: AppState) {
        appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://groups.example", ticket: "groups-test"),
            profile: "default"
        )
        appState.isConnected = true
        _ = appState.adoptDashboard(forNormalizedURL: "https://groups.example")
    }

    /// The plugin's answer once it keeps invites.
    private var invitesPluginReport: [String: Any] {
        ["ok": true, "version": "0.105.0", "capabilities": [RoomInvitesClient.capability]]
    }

    /// Waits until `condition` holds, failing after a few seconds.
    @MainActor
    private func invitesWait(
        _ what: String, until condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "timed out: \(what)", file: file, line: line)
    }

    /// Group Chats reads the invites with the drafts, once the plugin says
    /// it keeps them; a read from before a sign-out answers after the
    /// sign-in, whose own read failed, and is dropped.
    @MainActor
    func testInvitesAreReadWithTheDraftsAndDroppedAfterASignOut() async {
        let backend = InMemoryKeychainBackend()
        KeychainHelper.useBackendForTesting(backend)
        defer { KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend()) }
        let routes = InvitesRoutes(invites: [invitesInvite("conduit-1")])
        let appState = invitesAppState(routes)
        invitesConnect(appState)
        await appState.refreshGroupChatSupport()
        XCTAssertEqual(appState.groupChatPhase, .available)
        XCTAssertEqual(routes.invitesReads, 0, "not before the plugin says it keeps them")

        appState.applyNotifierPluginReport(invitesPluginReport)
        await invitesWait("the invites read", until: { appState.linkedRoomInviteRows.map(\.roomID) == ["conduit-1"] })
        XCTAssertEqual(routes.invitesReads, 1)
        await appState.refreshGroupChatSupport()
        XCTAssertEqual(routes.invitesReads, 2, "Group Chats reads them, as it reads the drafts")
        XCTAssertEqual(routes.draftsReads, 2)

        routes.holdsNextRead = true
        let before = Task { @MainActor in await appState.refreshGroupChatSupport() }
        await invitesWait("the held read", until: { routes.holding })
        appState.disconnect()
        XCTAssertEqual(appState.linkedRoomInviteRows, [], "a sign-out clears them")
        routes.readsFail = true
        invitesConnect(appState)
        appState.applyNotifierPluginReport(invitesPluginReport)
        await appState.refreshGroupChatSupport()
        routes.answerHeldRead()
        await before.value
        XCTAssertEqual(appState.groupChatPhase, .available)
        XCTAssertEqual(appState.linkedRoomInviteRows, [], "the read from before the sign-out is dropped")
    }

    /// An invite's notification opens its card once the plugin's status
    /// is in; one the plugin no longer lists says so, and one from a
    /// dashboard this device doesn't know opens nothing.
    @MainActor
    func testATappedInviteOpensItsCard() async {
        let routes = InvitesRoutes(invites: [invitesInvite("conduit-1"), invitesInvite("conduit-2", status: "joined")])
        let appState = invitesAppState(routes)
        invitesConnect(appState)
        let dashboard = appState.activeDashboardID
        let tapped = RoomInviteTarget(link: "lk1a2b3c4d5e6f", roomID: "conduit-2", dashboardID: dashboard)
        let early = await appState.openRoomInvite(tapped)
        XCTAssertEqual(early, .waiting, "it waits for the plugin's status")
        XCTAssertNil(appState.presentedRoomInvite)

        appState.applyNotifierPluginReport(invitesPluginReport)
        let opened = await appState.openRoomInvite(tapped)
        XCTAssertEqual(opened, .opened)
        XCTAssertEqual(appState.presentedRoomInvite?.id, "lk1a2b3c4d5e6f/conduit-2")
        XCTAssertEqual(appState.presentedRoomInvite?.status, "joined")

        // During a call it waits for the call to end: the card can't open
        // over the call's screen.
        appState.presentedRoomInvite = nil
        appState.isNativeHermesCallActive = true
        let duringCall = await appState.openRoomInvite(tapped)
        XCTAssertEqual(duringCall, .afterCall)
        XCTAssertNil(appState.presentedRoomInvite)
        appState.isNativeHermesCallActive = false

        let gone = await appState.openRoomInvite(RoomInviteTarget(link: "lk1a2b3c4d5e6f", roomID: "conduit-9", dashboardID: dashboard))
        XCTAssertEqual(gone, .failed)
        XCTAssertNil(appState.presentedRoomInvite)
        XCTAssertEqual(appState.errorMessage, AppLocalization.string("This invite isn't on your Hermes any more."))

        let unknown = await appState.openRoomInvite(RoomInviteTarget(link: "lk1a2b3c4d5e6f", roomID: "conduit-1", dashboardID: UUID()))
        XCTAssertEqual(unknown, .failed)
        XCTAssertNil(appState.presentedRoomInvite)
        XCTAssertEqual(appState.errorMessage, AppLocalization.string(
            "This notification belongs to a dashboard this device doesn't recognize. Add that dashboard again to continue."
        ))
    }
}

/// The plugin's rooms routes behind an AppState for the invites: reads of
/// each list are counted, the next invites read can wait until the test
/// answers it, and Links reads fail.
@MainActor
private final class InvitesRoutes {
    let invites: [[String: Any]]
    /// The next invites read waits until `answerHeldRead()`.
    var holdsNextRead = false
    /// Invites reads fail from now on.
    var readsFail = false
    private(set) var invitesReads = 0
    private(set) var draftsReads = 0
    private(set) var holding = false
    private var released = false

    init(invites: [[String: Any]]) {
        self.invites = invites
    }

    func answer(_ path: String, _ method: String, _ body: [String: Any]?, _ timeout: Int?) async throws -> [String: Any] {
        if path == RoomDraftsClient.path, method == "GET" {
            draftsReads += 1
            let starts: [String: Any] = ["available": true, "reason": NSNull()]
            return ["ok": true, "drafts": [[String: Any]](), "starts": starts]
        }
        guard path == RoomInvitesClient.path, method == "GET" else { throw URLError(.fileDoesNotExist) }
        invitesReads += 1
        if holdsNextRead {
            holdsNextRead = false
            holding = true
            while !released, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            holding = false
        } else if readsFail {
            throw URLError(.timedOut)
        }
        return ["ok": true, "invites": invites]
    }

    func answerHeldRead() {
        released = true
    }
}
