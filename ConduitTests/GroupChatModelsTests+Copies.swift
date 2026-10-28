import XCTest

@testable import Conduit

/// Rooms other people host (designs/cross-owner-agents, C4a): your Hermes'
/// copy of each (`room_copies.py`, notifier 0.110) is a row in Group Chats
/// and opens the room screen, read from the copy; the members' owners show
/// on their names; and one that ended can be deleted. An extension, so no
/// new class to plan.
extension GroupChatModelsTests {
    /// A copy as `GET /rooms/copies` shows it (room_copies._shown).
    func copiesCopy(
        room: String = "conduit-9",
        link: String = "lk1a2b3c4d5e6f",
        status: String = "started",
        reason: String? = nil,
        from: String = "Furina",
        yours: [[String: Any]] = [["member_id": "m-kuro", "profile": "research", "handle": "kuro"]],
        working: Bool = false,
        lastSeq: Int = 3
    ) -> [String: Any] {
        [
            "room_id": room,
            "name": "Zoo trip",
            "link": link,
            "from": from,
            "members": [
                ["member_id": "m-nahida", "handle": "nahida", "display_name": "Nahida", "owner": NSNull()],
                ["member_id": "m-kuro", "handle": "kuro", "display_name": "Kuro", "owner": "Eric"],
                ["member_id": "m-laifu", "handle": "laifu", "display_name": "Laifu", "owner": "Mona"],
            ],
            "yours": yours,
            "status": status,
            "reason": reason ?? NSNull(),
            "started_at": 1_790_000_000.0,
            "ended_at": NSNull(),
            "state": [
                "ended": NSNull(),
                "working": working,
                "activity": [["member_id": "m-laifu", "status": "running"]],
                "routes": [["member_id": "m-laifu", "status": "unavailable"]],
            ] as [String: Any],
            "last_seq": lastSeq,
            "latest_seq": lastSeq,
            "updated_at": 1_790_000_100.5,
        ]
    }

    /// An event of a copy's log, in groups.log's shape.
    func copiesEvent(_ seq: Int, room: String = "conduit-9", kind: String = "message.member",
                             actor: [String: Any] = ["kind": "member", "id": "m-laifu"],
                             text: String = "hi") -> [String: Any] {
        ["room_id": room, "seq": seq, "event_id": "ev-\(seq)", "kind": kind, "actor": actor,
         "authority_epoch": 1, "payload": ["text": text, "thread_id": "main"], "created_at": 1_790_000_000.0 + Double(seq)]
    }

    func testCopiesListReadsHostMembersYoursAndState() async throws {
        let client = RoomCopiesClient { path, method, body, _ in
            XCTAssertEqual(path, "/api/plugins/conduit_push/rooms/copies", "the list takes no profile")
            XCTAssertEqual(method, "GET")
            XCTAssertNil(body)
            return ["ok": true, "copies": [
                self.copiesCopy(working: true),
                // One without a room id, Link or name is left out.
                ["room_id": "", "link": "lk", "name": "x", "status": "started"],
                ["room_id": "r", "name": "x", "status": "started"],
                ["room_id": "r", "link": "lk", "name": "", "status": "started"],
            ]]
        }
        let copies = try await client.copies()
        XCTAssertEqual(copies.count, 1)
        let copy = try XCTUnwrap(copies.first)
        XCTAssertEqual(copy.id, "lk1a2b3c4d5e6f/conduit-9")
        XCTAssertEqual(copy.name, "Zoo trip")
        XCTAssertEqual(copy.from, "Furina")
        XCTAssertEqual(copy.members.map(\.memberID), ["m-nahida", "m-kuro", "m-laifu"])
        XCTAssertEqual(copy.members.map(\.owner), [nil, "Eric", "Mona"])
        XCTAssertEqual(copy.yours, [RoomCopy.Agent(memberID: "m-kuro", profile: "research", handle: "kuro")])
        XCTAssertEqual(copy.status, "started")
        XCTAssertFalse(copy.isOver)
        XCTAssertEqual(copy.lastSeq, 3)
        XCTAssertEqual(copy.updatedAt, 1_790_000_100.5)

        // The room screen's room: your agent is yours, by its profile; the
        // others are on another Hermes, each with its owner, the host for
        // its own.
        let room = copy.room
        XCTAssertEqual(room.roomID, "conduit-9")
        XCTAssertEqual(room.members.map(\.isPeer), [true, false, true])
        XCTAssertEqual(room.members.map(\.owner), ["Furina", nil, "Mona"])
        XCTAssertEqual(room.members.map(\.profile), [nil, "research", nil])
        XCTAssertFalse(room.isDisbanded)
        // Without a name for the host's Link, its own agents have no owner.
        let unnamed = try XCTUnwrap(RoomCopiesClient.copy(copiesCopy(from: "")))
        XCTAssertNil(unnamed.room.members[0].owner)

        XCTAssertThrowsError(try RoomCopiesClient.parseList(["ok": false, "copies": [[String: Any]]()]))
        XCTAssertThrowsError(try RoomCopiesClient.parseList(["ok": true]))
    }

    func testACopysRowSaysWhoHostsItAndHowItStands() throws {
        func line(_ object: [String: Any]) throws -> String {
            RoomCopyText.line(for: try XCTUnwrap(RoomCopiesClient.copy(object)))
        }
        let host = "Furina"
        let count = 3
        let members = AppLocalization.string("\(count) members")
        let hostedBy = AppLocalization.string("Hosted by \(host)")
        let elsewhere = AppLocalization.string("Hosted elsewhere")
        XCTAssertEqual(try line(copiesCopy()), AppLocalization.string("\(hostedBy) · \(members)"))
        XCTAssertEqual(try line(copiesCopy(working: true)), AppLocalization.string("Hosted by \(host) · working…"))
        XCTAssertEqual(try line(copiesCopy(from: "")), AppLocalization.string("\(elsewhere) · \(members)"))
        XCTAssertEqual(try line(copiesCopy(from: "", working: true)), AppLocalization.string("Hosted elsewhere · working…"))
        XCTAssertEqual(try line(copiesCopy(status: "ended", reason: "disbanded")), AppLocalization.string("Ended"))
        XCTAssertEqual(try line(copiesCopy(status: "left", yours: [])), AppLocalization.string("Your agents left"))
        XCTAssertTrue(try XCTUnwrap(RoomCopiesClient.copy(copiesCopy(status: "ended"))).isOver)
        XCTAssertTrue(try XCTUnwrap(RoomCopiesClient.copy(copiesCopy(status: "left"))).isOver)

        // In the composer's place, until posting comes.
        let copy = try XCTUnwrap(RoomCopiesClient.copy(copiesCopy()))
        XCTAssertEqual(RoomCopyText.noPosting(for: copy),
                       AppLocalization.string("Hosted by \(host). You can read it here; posting in rooms other people host comes later."))
        XCTAssertEqual(RoomCopyText.host(for: copy), AppLocalization.string("Hosted by \(host)"))
        XCTAssertEqual(RoomCopyText.hostName(for: copy), "Furina")
    }

    @MainActor
    func testAnInviteWithACopyIsNotListed() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy()])
        routes.invites = [
            ["room_id": "conduit-9", "link": "lk1a2b3c4d5e6f", "name": "Zoo trip", "status": "started", "from": "Furina",
             "joined": [["profile": "research", "display_name": "Kuro"]],
             "gone": [["profile": "writer", "handle": "quill", "display_name": "Quill", "reason": "left"]]],
            ["room_id": "conduit-8", "link": "lk1a2b3c4d5e6f", "name": "Picnic", "status": "waiting", "from": "Furina"],
        ]
        let appState = try copiesAppState(routes)
        copiesConnect(appState)
        appState.applyNotifierPluginReport(copiesPluginReport)
        await appState.refreshGroupChatSupport()
        await copiesWait("the copies read", until: { appState.linkedRoomCopyRows.count == 1 })
        XCTAssertEqual(appState.linkedRoomInviteRows.map(\.roomID), ["conduit-8"], "the copy is the room now")
        XCTAssertEqual(appState.linkedRoomInvite("lk1a2b3c4d5e6f/conduit-9")?.gone.map(\.profile), ["writer"])
    }

    @MainActor
    func testACopyOpensFromItsLogAndPollsAfterTheCursor() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy(lastSeq: 2)])
        routes.events = [copiesEvent(1, kind: "message.user", actor: ["kind": "user", "id": "furina"]), copiesEvent(2)]
        let appState = try copiesAppState(routes)
        copiesConnect(appState)
        appState.applyNotifierPluginReport(copiesPluginReport)
        await appState.refreshGroupChatSupport()
        let copy = try XCTUnwrap(appState.linkedRoomCopyRows.first)

        await appState.openRoomCopy(copy)
        let surface = try XCTUnwrap(appState.activeRoomSurface)
        XCTAssertEqual(surface.copy?.id, copy.id)
        XCTAssertEqual(surface.room.name, "Zoo trip")
        XCTAssertEqual(appState.activeRoomReplay.events.map(\.seq), [1, 2])
        XCTAssertEqual(routes.logReads.first?.since, 0, "the tail: from the last seq less the window")
        XCTAssertEqual(routes.logReads.first?.limit, GroupRoomReplay.tailWindow)
        XCTAssertTrue(appState.isPollingActiveRoom)

        // A tick reads after the cursor and adopts what's new.
        routes.events.append(copiesEvent(3, text: "more"))
        routes.copies = [copiesCopy(lastSeq: 3)]
        await appState.pollActiveRoom()
        XCTAssertEqual(routes.logReads.last?.since, 2)
        XCTAssertEqual(appState.activeRoomReplay.events.map(\.seq), [1, 2, 3])

        // Nothing goes to the gateway from it: no send.
        let sent = await appState.sendGroupRoomMessage("hello")
        XCTAssertFalse(sent)
        XCTAssertFalse(appState.canQuoteIntoRoom(), "no composer to quote or mention into")
        await appState.disbandActiveRoom()
        XCTAssertNotNil(appState.activeRoomSurface, "a room someone else hosts isn't yours to disband")

        appState.closeGroupRoom()
        XCTAssertNil(appState.activeRoomSurface)
    }

    @MainActor
    func testAFailedOpeningReadReadsTheTailAgainNotTheFirstEvents() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy(lastSeq: 300)])
        routes.events = (1...300).map { copiesEvent($0) }
        routes.failingLogReads = 1
        let appState = try copiesAppState(routes)
        copiesConnect(appState)
        appState.applyNotifierPluginReport(copiesPluginReport)
        await appState.refreshGroupChatSupport()
        await appState.openRoomCopy(try XCTUnwrap(appState.linkedRoomCopyRows.first))
        XCTAssertEqual(appState.activeRoomReplay.events, [])
        XCTAssertTrue(appState.isPollingActiveRoom)

        await appState.pollActiveRoom()
        XCTAssertEqual(routes.logReads.last?.since, 300 - GroupRoomReplay.tailWindow)
        XCTAssertEqual(appState.activeRoomReplay.events.last?.seq, 300)
        XCTAssertNil(appState.errorMessage)
        appState.closeGroupRoom()
    }

    @MainActor
    func testACopysStateIsTheRoomsDriverStatus() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy(working: true)])
        let appState = try copiesAppState(routes)
        copiesConnect(appState)
        appState.applyNotifierPluginReport(copiesPluginReport)
        await appState.refreshGroupChatSupport()
        await appState.openRoomCopy(try XCTUnwrap(appState.linkedRoomCopyRows.first))

        let driver = try XCTUnwrap(appState.activeRoomDriverStatus)
        XCTAssertTrue(driver.working)
        XCTAssertEqual(driver.pendingApprovals, [], "the home's approvals never come")
        XCTAssertEqual(appState.activeRoomResponder?.memberID, "m-laifu")
        XCTAssertEqual(appState.activeRoomResponderState, .responding, "its turn is running")
        let laifu = try XCTUnwrap(appState.activeRoomSurface?.room.members.first { $0.memberID == "m-laifu" })
        XCTAssertEqual(driver.routeStatus(for: laifu), .unreachable)

        // A tick the log brings nothing in reads the copy again.
        routes.copies = [copiesCopy(working: false)]
        let reads = routes.copiesReads
        await appState.pollActiveRoom()
        XCTAssertEqual(routes.copiesReads, reads + 1)
        XCTAssertEqual(appState.activeRoomDriverStatus?.working, false)
    }

    @MainActor
    func testAnEndedCopyStopsPolling() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy()])
        let appState = try copiesAppState(routes)
        copiesConnect(appState)
        appState.applyNotifierPluginReport(copiesPluginReport)
        await appState.refreshGroupChatSupport()
        await appState.openRoomCopy(try XCTUnwrap(appState.linkedRoomCopyRows.first))
        XCTAssertTrue(appState.isPollingActiveRoom)

        routes.copies = [copiesCopy(status: "ended", reason: "disbanded")]
        await appState.pollActiveRoom()
        XCTAssertEqual(appState.activeRoomSurface?.copy?.status, "ended")
        XCTAssertFalse(appState.isPollingActiveRoom, "nothing more comes")

        // Opened again once it ended, it isn't polled.
        await appState.openRoomCopy(try XCTUnwrap(appState.linkedRoomCopyRows.first))
        XCTAssertNotNil(appState.activeRoomSurface)
        XCTAssertFalse(appState.isPollingActiveRoom)
    }

    @MainActor
    func testYourApprovalsInACopyShowInItsRoom() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy()])
        let approval: [String: Any] = [
            "run_id": "run_a1", "request_id": "req-1", "room_id": "conduit-9", "link": "lk1a2b3c4d5e6f",
            "room": "Zoo trip", "from": "Furina", "agent": ["profile": "research", "handle": "kuro", "display_name": "Kuro"],
            "description": "Run a shell command", "command": "ls", "choices": ["once", "deny"], "session_key": NSNull(),
        ]
        var elsewhere = approval
        elsewhere["room_id"] = "conduit-1"
        elsewhere["run_id"] = "run_b2"
        routes.approvals = [approval, elsewhere]
        let appState = try copiesAppState(routes)
        copiesConnect(appState)
        appState.applyNotifierPluginReport(copiesPluginReport)
        await appState.refreshGroupChatSupport()
        XCTAssertEqual(appState.activeRoomCopyApprovals, [], "no room open")
        await appState.openRoomCopy(try XCTUnwrap(appState.linkedRoomCopyRows.first))
        XCTAssertEqual(appState.activeRoomCopyApprovals.map(\.id), ["run_a1/req-1"], "only this room's")
        XCTAssertEqual(appState.activeRoomPendingApprovals, [], "no card of the home's")

        // Answered here, it stays gone though a read still lists it.
        let answered = await appState.answerLinkedRoomApproval(appState.activeRoomCopyApprovals[0], choice: "once")
        XCTAssertEqual(answered, .sent)
        await appState.pollActiveRoom()
        XCTAssertEqual(routes.approvals.count, 2, "the plugin still lists it")
        XCTAssertEqual(appState.activeRoomCopyApprovals, [])
        XCTAssertEqual(appState.linkedRoomApprovalRows.map(\.id), ["run_b2/req-1"])
    }

    @MainActor
    func testAnApprovalWithoutItsLinkShowsOnlyWhereItsRoomIdIsOne() async throws {
        // Room ids are only unique per host: two Links' rooms can share one.
        let routes = CopiesRoutes(copies: [copiesCopy(), copiesCopy(link: "lk9z8y7x6w5v4u")])
        routes.approvals = [[
            "run_id": "run_a1", "request_id": "req-1", "room_id": "conduit-9", "link": NSNull(),
            "room": "Zoo trip", "from": "Furina", "agent": ["profile": "research", "handle": "kuro"],
            "description": "Run a shell command", "command": "ls", "choices": ["once", "deny"], "session_key": NSNull(),
        ]]
        let appState = try copiesAppState(routes)
        copiesConnect(appState)
        appState.applyNotifierPluginReport(copiesPluginReport)
        await appState.refreshGroupChatSupport()
        XCTAssertEqual(appState.linkedRoomCopyRows.count, 2)
        await appState.openRoomCopy(appState.linkedRoomCopyRows[0])
        XCTAssertEqual(appState.activeRoomCopyApprovals, [], "it could be either room's")

        routes.copies = [copiesCopy()]
        await appState.refreshGroupChatSupport()
        await appState.openRoomCopy(try XCTUnwrap(appState.linkedRoomCopyRows.first))
        XCTAssertEqual(appState.activeRoomCopyApprovals.map(\.id), ["run_a1/req-1"], "the only room with that id")
    }

    @MainActor
    func testOwnersComeFromPeopleInYourOwnRoom() async throws {
        let routes = CopiesRoutes(copies: [])
        routes.people = ["ok": true, "room_id": "conduit-5", "home": NSNull(), "members": [
            ["member_id": "m-nahida", "handle": "nahida", "display_name": "Nahida", "owner": NSNull(), "status": "in"],
            ["member_id": "m-laifu", "handle": "laifu", "display_name": "Laifu", "owner": "Mona", "status": "in"],
        ]]
        let room = GroupRoom(
            roomID: "conduit-5", name: "Picnic",
            members: [
                GroupMember(memberID: "m-nahida", profile: "nahida", handle: "nahida", displayName: "Nahida",
                            target: ["kind": .string("local")], extra: [:]),
                GroupMember(memberID: "m-laifu", profile: nil, handle: "laifu", displayName: "Laifu",
                            target: ["kind": .string("peer")], extra: [:]),
            ],
            authorityGatewayID: "gw-a", authorityEpoch: 1, revision: 1, createdAt: 0, updatedAt: 0,
            disbandedAt: nil, latestSeq: 0
        )
        let appState = try copiesAppState(routes, room: room)
        copiesConnect(appState)
        appState.applyNotifierPluginReport(copiesPluginReport)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)
        await copiesWait("the owners read", until: {
            appState.activeRoomPeople["m-laifu"] == RoomPerson(owner: "Mona", isYours: false, out: nil)
        })
        XCTAssertEqual(routes.peopleReads, ["/api/plugins/conduit_push/rooms/people?room_id=conduit-5"])
        XCTAssertEqual(appState.activeRoomMembers.map(\.owner), [nil, "Mona"])
        XCTAssertEqual(appState.activeRoomMembers.map(GroupRoomTurns.ownerLine(of:)),
                       [AppLocalization.string("Your agent"), AppLocalization.string("Mona's agent")])

        // A room of only your own agents reads nobody.
        appState.closeGroupRoom()
        XCTAssertEqual(appState.activeRoomPeople, [:])
    }

    func testAnotherPersonsAgentIsNamedWithItsOwner() throws {
        let copy = try XCTUnwrap(RoomCopiesClient.copy(copiesCopy()))
        let members = copy.room.members
        let name = "Laifu"
        let owner = "Mona"
        XCTAssertEqual(GroupRoomTurns.ownedName(name, of: members[2]), AppLocalization.string("\(name) · \(owner)'s"))
        XCTAssertEqual(GroupRoomTurns.ownedName("Kuro", of: members[1]), "Kuro", "your own agent is just its name")
        XCTAssertEqual(GroupRoomTurns.ownedName("Laifu", of: nil), "Laifu")
        XCTAssertEqual(GroupRoomTurns.ownerLine(of: members[0]), AppLocalization.string("Furina's agent"))
        XCTAssertEqual(GroupRoomTurns.ownerLine(of: members[1]), AppLocalization.string("Your agent"))
        let unnamed = try XCTUnwrap(RoomCopiesClient.copy(copiesCopy(from: ""))).room.members[0]
        XCTAssertEqual(GroupRoomTurns.ownerLine(of: unnamed), AppLocalization.string("On another Hermes"))
        // Renamed by your roster, it keeps its owner.
        XCTAssertEqual(GroupRoomTurns.members(members, namedBy: []).map(\.owner), ["Furina", nil, "Mona"])
    }

    @MainActor
    func testDeletingAnEndedCopyForgetsEachAgentsChatsThenTheCopy() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy(status: "ended", reason: "disbanded")])
        routes.invites = [
            ["room_id": "conduit-9", "link": "lk1a2b3c4d5e6f", "name": "Zoo trip", "status": "ended", "from": "Furina",
             "reason": "disbanded",
             "joined": [["profile": "research", "display_name": "Kuro"]],
             "gone": [["profile": "default", "handle": "quill", "display_name": "Quill", "reason": "left"]]],
        ]
        let appState = try copiesAppState(routes)
        copiesConnect(appState)
        appState.applyNotifierPluginReport(copiesPluginReport)
        await appState.refreshGroupChatSupport()
        let copy = try XCTUnwrap(appState.linkedRoomCopyRows.first)
        await appState.openRoomCopy(copy)

        let result = await appState.deleteLinkedRoomCopy(copy)
        XCTAssertEqual(result, .deleted)
        XCTAssertEqual(routes.deletes, [
            "/api/plugins/conduit_push/rooms/sessions?room_id=conduit-9&profile=research",
            "/api/plugins/conduit_push/rooms/sessions?room_id=conduit-9",
            "/api/plugins/conduit_push/rooms/copies?room_id=conduit-9",
        ], "each agent's chats (the default profile's without a profile), then the copy")
        XCTAssertEqual(appState.linkedRoomCopyRows, [])
        XCTAssertEqual(appState.linkedRoomInviteRows, [], "its ended invite doesn't take its row back")
        XCTAssertNil(appState.activeRoomSurface, "its room screen closes")
    }

    @MainActor
    func testARefusedDeleteKeepsTheCopy() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy(status: "left", yours: [])])
        routes.refusesSessionDeletes = true
        routes.invites = [
            ["room_id": "conduit-9", "link": "lk1a2b3c4d5e6f", "name": "Zoo trip", "status": "left", "from": "Furina",
             "gone": [["profile": "research", "handle": "kuro", "display_name": "Kuro", "reason": "left"]]],
        ]
        let appState = try copiesAppState(routes)
        copiesConnect(appState)
        appState.applyNotifierPluginReport(copiesPluginReport)
        await appState.refreshGroupChatSupport()
        let copy = try XCTUnwrap(appState.linkedRoomCopyRows.first)

        let result = await appState.deleteLinkedRoomCopy(copy)
        XCTAssertEqual(result, .refused(AppLocalization.string("Could not delete this room: \(CopiesRoutes.going)")))
        XCTAssertEqual(routes.deletes.count, 1, "the copy isn't deleted after a refusal")
        XCTAssertEqual(appState.linkedRoomCopyRows.map(\.id), [copy.id])
    }

    @MainActor
    func testDeletingALeftCopyReadsItsInviteForTheAgentsThatLeft() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy(status: "left", yours: [])])
        let appState = try copiesAppState(routes)
        copiesConnect(appState)
        appState.applyNotifierPluginReport(copiesPluginReport)
        await appState.refreshGroupChatSupport()
        let copy = try XCTUnwrap(appState.linkedRoomCopyRows.first)
        // The invite comes after the last read: only it says who left.
        routes.invites = [
            ["room_id": "conduit-9", "link": "lk1a2b3c4d5e6f", "name": "Zoo trip", "status": "left", "from": "Furina",
             "gone": [["profile": "research", "handle": "kuro", "display_name": "Kuro", "reason": "left"]]],
        ]

        let result = await appState.deleteLinkedRoomCopy(copy)
        XCTAssertEqual(result, .deleted)
        XCTAssertEqual(routes.deletes, [
            "/api/plugins/conduit_push/rooms/sessions?room_id=conduit-9&profile=research",
            "/api/plugins/conduit_push/rooms/copies?room_id=conduit-9",
        ])
    }

    @MainActor
    func testALeftCopyIsntDeletedWhenItsInviteCantBeRead() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy(status: "left", yours: [])])
        routes.failsInvites = true
        let appState = try copiesAppState(routes)
        copiesConnect(appState)
        appState.applyNotifierPluginReport(copiesPluginReport)
        await appState.refreshGroupChatSupport()
        let copy = try XCTUnwrap(appState.linkedRoomCopyRows.first)

        let result = await appState.deleteLinkedRoomCopy(copy)
        guard case .refused = result else { return XCTFail("deleted without knowing whose chats to delete") }
        XCTAssertEqual(routes.deletes, [], "its agents' chats would stay behind")
        XCTAssertEqual(appState.linkedRoomCopyRows.map(\.id), [copy.id])
    }

    @MainActor
    func testACopyStillGoingCantBeDeleted() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy()])
        let appState = try copiesAppState(routes)
        copiesConnect(appState)
        appState.applyNotifierPluginReport(copiesPluginReport)
        await appState.refreshGroupChatSupport()
        let copy = try XCTUnwrap(appState.linkedRoomCopyRows.first)
        XCTAssertTrue(appState.canDeleteRoomCopies)

        let result = await appState.deleteLinkedRoomCopy(copy)
        XCTAssertEqual(result, .notOver)
        XCTAssertEqual(routes.deletes, [], "nothing is sent")
        XCTAssertEqual(appState.linkedRoomCopyRows.count, 1)
    }

    // MARK: - Helpers

    /// An AppState on defaults of its own, connected to a gateway that
    /// hosts Group Chats with `room`, whose plugin's rooms routes are
    /// `routes`.
    @MainActor
    func copiesAppState(_ routes: CopiesRoutes, room: GroupRoom? = nil) throws -> AppState {
        let suite = "GroupChatModelsTests.copies.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in
                GroupCapabilities(protocolVersion: 2, driverReady: true, authorityGatewayID: "gw-a", features: [],
                                  methods: ["groups.list", "groups.create", "groups.state", "groups.send", "groups.log", "groups.disband"],
                                  maxLogLimit: 500)
            },
            list: { _ in (room.map { [$0] } ?? [], nil) },
            state: { _, _ in
                guard let room else { throw URLError(.fileDoesNotExist) }
                return (room, nil)
            },
            log: { _, _, _, _ in
                GroupLogPage(events: [], cursor: 0, latestSeq: 0, hasMore: false, authorityGatewayID: "gw-a", authorityEpoch: 1)
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
    func copiesConnect(_ appState: AppState, url: String = "https://groups.example") {
        appState.client = HermesClient(
            connection: HermesConnection(baseUrl: url, ticket: "groups-test"),
            profile: "default"
        )
        appState.isConnected = true
        _ = appState.adoptDashboard(forNormalizedURL: url)
    }

    /// The plugin's answer once it keeps copies and forgets room chats.
    var copiesPluginReport: [String: Any] {
        ["ok": true, "version": "0.110.0", "capabilities": [
            RoomInvitesClient.capability, RoomApprovalsClient.capability,
            RoomCopiesClient.capability, RoomCopiesClient.forgetCapability,
        ]]
    }

    /// Waits until `condition` holds, failing after a few seconds.
    @MainActor
    func copiesWait(
        _ what: String, until condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "timed out: \(what)", file: file, line: line)
    }
}

/// The plugin's rooms routes behind an AppState for the copies: the copies,
/// their log, the invites, approvals and people, and the deletes, leaves
/// and removes, kept in order.
@MainActor
final class CopiesRoutes {
    static let going = "This room is still going here; leave it first"

    var copies: [[String: Any]]
    /// The copy's log, for every room.
    var events: [[String: Any]] = []
    var invites: [[String: Any]] = []
    var approvals: [[String: Any]] = []
    var people: [String: Any] = ["ok": false]
    /// Deleting an agent's chats is refused.
    var refusesSessionDeletes = false
    /// The invites read fails.
    var failsInvites = false
    /// The next this many log reads fail.
    var failingLogReads = 0
    private(set) var copiesReads = 0
    private(set) var logReads: [(since: Int, limit: Int)] = []
    private(set) var peopleReads: [String] = []
    private(set) var deletes: [String] = []
    /// POST /rooms/leave's and /rooms/drafts/remove's bodies.
    private(set) var leaves: [[String: Any]] = []
    private(set) var removes: [[String: Any]] = []
    /// Leaving and taking out are refused with this, at this status.
    var refusesLeaving: String?
    var leavingStatus = 409
    /// The next people reads each wait this long, answering what the people
    /// were when they were asked.
    var peopleDelays: [Duration] = []
    /// The invite a leave answers.
    var leftInvite: [String: Any] = [
        "room_id": "conduit-9", "link": "lk1a2b3c4d5e6f", "name": "Zoo trip", "status": "left", "from": "Furina",
        "gone": [["profile": "research", "handle": "kuro", "display_name": "Kuro", "reason": "left"]],
    ]

    init(copies: [[String: Any]]) {
        self.copies = copies
    }

    func answer(_ path: String, _ method: String, _ body: [String: Any]?, _ timeout: Int?) async throws -> [String: Any] {
        if method == "DELETE" {
            deletes.append(path)
            if path.hasPrefix(RoomCopiesClient.sessionsPath) {
                if refusesSessionDeletes { throw DashboardTicketBridgeError.http(status: 409, detail: Self.going) }
                return ["ok": true, "deleted": 1, "kept": 0]
            }
            let room = URLComponents(string: path)?.queryItems?.first { $0.name == "room_id" }?.value
            copies.removeAll { $0["room_id"] as? String == room }
            return ["ok": true, "room_id": room ?? "", "forgotten": true]
        }
        if path.hasPrefix("\(RoomCopiesClient.path)/log") {
            let items = URLComponents(string: path)?.queryItems ?? []
            let since = Int(items.first { $0.name == "since_seq" }?.value ?? "") ?? -1
            let limit = Int(items.first { $0.name == "limit" }?.value ?? "") ?? -1
            logReads.append((since, limit))
            if failingLogReads > 0 {
                failingLogReads -= 1
                throw DashboardTicketBridgeError.http(status: 502, detail: "Bad gateway")
            }
            let page = Array(events.filter { ($0["seq"] as? Int ?? 0) > since }.prefix(limit))
            let latest = events.compactMap { $0["seq"] as? Int }.max() ?? 0
            let cursor = (page.last?["seq"] as? Int) ?? since
            return ["ok": true, "events": page, "cursor": cursor, "latest_seq": latest, "has_more": cursor < latest,
                    "authority": ["gateway_id": "gw-home", "epoch": 1]]
        }
        if path.hasPrefix(RoomPeople.path) {
            peopleReads.append(path)
            let answer = people
            if !peopleDelays.isEmpty {
                try await Task.sleep(for: peopleDelays.removeFirst())
            }
            return answer
        }
        switch (path, method) {
        case (RoomCopiesClient.path, "GET"):
            copiesReads += 1
            return ["ok": true, "copies": copies]
        case (RoomDraftsClient.path, "GET"):
            let starts: [String: Any] = ["available": true, "reason": NSNull()]
            return ["ok": true, "drafts": [[String: Any]](), "starts": starts]
        case (RoomInvitesClient.path, "GET"):
            if failsInvites { throw DashboardTicketBridgeError.http(status: 502, detail: "Bad gateway") }
            return ["ok": true, "invites": invites]
        case (RoomApprovalsClient.path, "GET"):
            return ["ok": true, "approvals": approvals]
        case (RoomLeaveClient.leavePath, "POST"):
            leaves.append(body ?? [:])
            if let refusesLeaving { throw DashboardTicketBridgeError.http(status: leavingStatus, detail: refusesLeaving) }
            return ["ok": true, "invite": leftInvite]
        case (RoomLeaveClient.removePath, "POST"):
            removes.append(body ?? [:])
            if let refusesLeaving { throw DashboardTicketBridgeError.http(status: leavingStatus, detail: refusesLeaving) }
            return ["ok": true, "draft": ["room_id": body?["room_id"] ?? ""]]
        case ("\(RoomApprovalsClient.path)/answer", "POST"):
            // Taken, though the list still has it for a read.
            return ["ok": true, "approval": body ?? [:]]
        default:
            throw URLError(.fileDoesNotExist)
        }
    }
}
