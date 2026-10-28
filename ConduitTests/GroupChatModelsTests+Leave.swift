import XCTest

@testable import Conduit

/// Taking agents out of rooms over Links (designs/cross-owner-agents, C4b):
/// your agents leave a room someone else hosts, all of them or one, you take
/// another person's agent out of a room you host, and Group Info says who
/// left or was taken out. An extension, so no new class to plan; the routes
/// stand-in is the copies' (GroupChatModelsTests+Copies.swift).
extension GroupChatModelsTests {
    /// The plugin's answer once it takes agents out too.
    private var leavePluginReport: [String: Any] {
        var report = copiesPluginReport
        report["capabilities"] = (report["capabilities"] as? [String] ?? []) + [RoomLeaveClient.capability]
        return report
    }

    /// An AppState with the copies read, on a plugin that reports `report`.
    @MainActor
    private func leaveAppState(
        _ routes: CopiesRoutes, room: GroupRoom? = nil, report: [String: Any]? = nil
    ) async throws -> AppState {
        let appState = try copiesAppState(routes, room: room)
        copiesConnect(appState)
        appState.applyNotifierPluginReport(report ?? leavePluginReport)
        await appState.refreshGroupChatSupport()
        return appState
    }

    /// Your own room, with your Nahida and Mona's Laifu.
    private var leaveOwnRoom: GroupRoom {
        GroupRoom(
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
    }

    /// GET /rooms/people for the own room, with Laifu `status`.
    private func leaveOwnPeople(laifu status: String) -> [String: Any] {
        ["ok": true, "room_id": "conduit-5", "home": NSNull(), "members": [
            ["member_id": "m-nahida", "handle": "nahida", "display_name": "Nahida", "owner": NSNull(), "status": "in"],
            ["member_id": "m-laifu", "handle": "laifu", "display_name": "Laifu", "owner": "Mona", "status": status],
        ]]
    }

    func testPeopleSayWhoIsOutAndWhoIsYours() {
        let people = RoomPeople.people(["ok": true, "members": [
            ["member_id": "m-nahida", "owner": NSNull(), "status": "in"],
            ["member_id": "m-kuro", "status": "left"],
            ["member_id": "m-laifu", "owner": " Mona ", "status": "removed"],
            ["member_id": "m-quill", "owner": "", "status": "gone somewhere"],
            ["member_id": "", "owner": "Mona"],
        ]])
        XCTAssertEqual(people, [
            "m-nahida": RoomPerson(owner: nil, isYours: true, out: nil),
            "m-kuro": RoomPerson(owner: nil, isYours: true, out: .left),
            "m-laifu": RoomPerson(owner: "Mona", isYours: false, out: .removed),
            "m-quill": RoomPerson(owner: nil, isYours: false, out: nil),
        ])
        XCTAssertEqual(RoomPeople.people(["ok": false, "members": [["member_id": "m-kuro"]]]), [:])
    }

    func testAMemberThatsOutSaysSoBesideWhoseItIs() throws {
        let copy = try XCTUnwrap(RoomCopiesClient.copy(copiesCopy(status: "left", yours: [])))
        let people = [
            "m-kuro": RoomPerson(owner: nil, isYours: true, out: .left),
            "m-laifu": RoomPerson(owner: "Mona", isYours: false, out: .removed),
        ]
        let members = GroupRoomTurns.members(copy.room.members, people: people)
        let yours = AppLocalization.string("Your agent")
        let left = AppLocalization.string("Left the room")
        let mona = AppLocalization.string("Mona's agent")
        let takenOut = AppLocalization.string("Taken out")
        XCTAssertEqual(members.map(GroupRoomTurns.ownerLine(of:)), [
            AppLocalization.string("Furina's agent"),
            // Once yours left, the copy lists it as the host's, as Eric's:
            // the plugin's people say it's yours.
            AppLocalization.string("\(yours) · \(left)"),
            AppLocalization.string("\(mona) · \(takenOut)"),
        ])
        XCTAssertEqual(GroupRoomTurns.ownedName("Kuro", of: members[1]), "Kuro", "yours is just its name")
        // Renamed by your roster, it's still out.
        let bot = BotProfile(
            name: "nahida", botTitle: "Kusanali", displayName: "Nahida", profileDescription: "",
            model: nil, provider: nil, hasAvatar: false, isPinned: false, isHiddenByMeta: false,
            appearanceColor: nil, canonicalSession: nil, lastActive: nil, lastPreview: nil
        )
        let out = GroupRoomTurns.members(
            leaveOwnRoom.members, people: ["m-nahida": RoomPerson(owner: nil, isYours: true, out: .left)])
        let renamed = GroupRoomTurns.members(out, namedBy: [bot])
        XCTAssertNotEqual(renamed[0].displayName, "Nahida", "renamed")
        XCTAssertEqual(renamed.map(\.out), [.left, nil])
    }

    @MainActor
    func testLeavingARoomSomeoneElseHostsTakesOutAllYourAgents() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy()])
        let appState = try await leaveAppState(routes)
        let copy = try XCTUnwrap(appState.linkedRoomCopyRows.first)
        await appState.openRoomCopy(copy)
        XCTAssertTrue(appState.canLeaveActiveRoom)
        XCTAssertTrue(appState.isPollingActiveRoom)

        // The plugin's copy, once the home took them out.
        routes.copies = [copiesCopy(status: "left", yours: [])]
        routes.people = ["ok": true, "room_id": "conduit-9", "home": "Furina", "members": [
            ["member_id": "m-nahida", "owner": "Furina", "status": "in"],
            ["member_id": "m-kuro", "owner": NSNull(), "status": "left"],
            ["member_id": "m-laifu", "owner": "Mona", "status": "in"],
        ]]
        let result = await appState.leaveActiveRoom()
        XCTAssertEqual(result, .done)
        XCTAssertEqual(routes.leaves.count, 1)
        let body = try XCTUnwrap(routes.leaves.first)
        XCTAssertEqual(body["link"] as? String, "lk1a2b3c4d5e6f")
        XCTAssertEqual(body["room_id"] as? String, "conduit-9")
        XCTAssertTrue(body["agents"] is NSNull, "all of yours still in")

        XCTAssertEqual(appState.activeRoomSurface?.copy?.status, "left", "the copy stays, ended for you")
        XCTAssertFalse(appState.canLeaveActiveRoom)
        XCTAssertFalse(appState.isPollingActiveRoom, "nothing more comes")
        XCTAssertEqual(appState.linkedRoomInvite(copy.id)?.status, "left")
        XCTAssertEqual(appState.linkedRoomInvite(copy.id)?.gone.map(\.profile), ["research"])
        let kuro = try XCTUnwrap(appState.activeRoomMembers.first { $0.memberID == "m-kuro" })
        XCTAssertEqual(kuro.out, .left)
        XCTAssertTrue(kuro.isYours)
    }

    @MainActor
    func testTakingOneOfYourAgentsOutOfACopySendsItsProfile() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy()])
        let appState = try await leaveAppState(routes)
        await appState.openRoomCopy(try XCTUnwrap(appState.linkedRoomCopyRows.first))
        let members = appState.activeRoomMembers
        let kuro = try XCTUnwrap(members.first { $0.memberID == "m-kuro" })
        let laifu = try XCTUnwrap(members.first { $0.memberID == "m-laifu" })
        XCTAssertTrue(appState.canTakeOut(kuro))
        XCTAssertFalse(appState.canTakeOut(laifu), "only the host takes others out")

        let result = await appState.takeOut(kuro)
        XCTAssertEqual(result, .done)
        XCTAssertEqual(routes.leaves.first?["agents"] as? [String], ["research"])
        XCTAssertEqual(routes.removes.count, 0)
        XCTAssertFalse(routes.peopleReads.isEmpty, "who's in is read again")
    }

    @MainActor
    func testTakingAnotherPersonsAgentOutOfYourRoomRemovesIt() async throws {
        let routes = CopiesRoutes(copies: [])
        routes.people = leaveOwnPeople(laifu: "in")
        let appState = try await leaveAppState(routes, room: leaveOwnRoom)
        await appState.openGroupRoom(leaveOwnRoom)
        await copiesWait("the people read", until: { appState.activeRoomPeople["m-laifu"]?.owner == "Mona" })
        let nahida = try XCTUnwrap(appState.activeRoomMembers.first { $0.memberID == "m-nahida" })
        let laifu = try XCTUnwrap(appState.activeRoomMembers.first { $0.memberID == "m-laifu" })
        XCTAssertFalse(appState.canTakeOut(nahida), "your own agents leave by the room's own means")
        XCTAssertTrue(appState.canTakeOut(laifu))
        XCTAssertFalse(appState.canLeaveActiveRoom, "you host it")

        routes.people = leaveOwnPeople(laifu: "removed")
        let result = await appState.takeOut(laifu)
        XCTAssertEqual(result, .done)
        XCTAssertEqual(routes.removes.count, 1)
        XCTAssertEqual(routes.removes.first?["room_id"] as? String, "conduit-5")
        XCTAssertEqual(routes.removes.first?["member"] as? String, "m-laifu")
        XCTAssertEqual(routes.leaves.count, 0)

        let out = try XCTUnwrap(appState.activeRoomMembers.first { $0.memberID == "m-laifu" })
        XCTAssertEqual(out.out, .removed)
        let mona = AppLocalization.string("Mona's agent")
        let takenOut = AppLocalization.string("Taken out")
        XCTAssertEqual(GroupRoomTurns.ownerLine(of: out), AppLocalization.string("\(mona) · \(takenOut)"))
        XCTAssertFalse(appState.canTakeOut(out), "it's out already")
        appState.closeGroupRoom()
    }

    @MainActor
    func testARefusedLeaveKeepsTheRoomAsItWas() async throws {
        let refusal = "The room's home isn't answering"
        let routes = CopiesRoutes(copies: [copiesCopy()])
        routes.refusesLeaving = refusal
        let appState = try await leaveAppState(routes)
        await appState.openRoomCopy(try XCTUnwrap(appState.linkedRoomCopyRows.first))

        let result = await appState.leaveActiveRoom()
        XCTAssertEqual(result, .refused(AppLocalization.string("Could not leave this room: \(refusal)")))
        XCTAssertEqual(appState.activeRoomSurface?.copy?.status, "started")
        XCTAssertTrue(appState.canLeaveActiveRoom)
        XCTAssertTrue(appState.isPollingActiveRoom)

        let kuro = try XCTUnwrap(appState.activeRoomMembers.first { $0.memberID == "m-kuro" })
        let refused = await appState.takeOut(kuro)
        XCTAssertEqual(refused, .refused(AppLocalization.string("Could not take this agent out: \(refusal)")))
        appState.closeGroupRoom()
    }

    @MainActor
    func testALeaveStillOnItsWayReadsTheRoomAgain() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy()])
        routes.refusesLeaving = "The mailbox didn't answer"
        routes.leavingStatus = 504
        routes.invites = [["room_id": "conduit-9", "link": "lk1a2b3c4d5e6f", "name": "Zoo trip", "status": "started",
                           "from": "Furina", "joined": [["profile": "research", "handle": "kuro", "display_name": "Kuro"]]]]
        let appState = try await leaveAppState(routes)
        let copy = try XCTUnwrap(appState.linkedRoomCopyRows.first)
        await appState.openRoomCopy(copy)

        // Your Hermes took them out; telling the home is what waits.
        routes.copies = [copiesCopy(status: "left", yours: [])]
        routes.invites = [routes.leftInvite]
        let result = await appState.leaveActiveRoom()
        XCTAssertEqual(result, .sending(AppLocalization.string("Your Hermes is still sending this. The room shows it once it has.")))
        XCTAssertEqual(appState.activeRoomSurface?.copy?.status, "left", "the copy is read again")
        XCTAssertEqual(appState.linkedRoomInvite(copy.id)?.status, "left", "and its invite")
        XCTAssertFalse(appState.canLeaveActiveRoom)
    }

    @MainActor
    func testYourAgentsThatLeftAreYoursFromTheInviteBeforeThePeopleRead() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy(status: "left", yours: [])])
        routes.invites = [routes.leftInvite]
        let appState = try await leaveAppState(routes)
        await appState.openRoomCopy(try XCTUnwrap(appState.linkedRoomCopyRows.first))
        XCTAssertEqual(appState.activeRoomPeople, [:], "the people read failed")

        let kuro = try XCTUnwrap(appState.activeRoomMembers.first { $0.memberID == "m-kuro" })
        XCTAssertTrue(kuro.isYours)
        XCTAssertEqual(kuro.out, .left)
        let yours = AppLocalization.string("Your agent")
        let left = AppLocalization.string("Left the room")
        XCTAssertEqual(GroupRoomTurns.ownerLine(of: kuro), AppLocalization.string("\(yours) · \(left)"))
        XCTAssertEqual(GroupRoomTurns.ownedName("Kuro", of: kuro), "Kuro", "not the host's name for you")
        let laifu = try XCTUnwrap(appState.activeRoomMembers.first { $0.memberID == "m-laifu" })
        XCTAssertFalse(laifu.isYours)
        XCTAssertNil(laifu.out)
    }

    @MainActor
    func testAnOlderPeopleReadAnsweringLaterIsDropped() async throws {
        let routes = CopiesRoutes(copies: [])
        routes.people = leaveOwnPeople(laifu: "in")
        routes.peopleDelays = [.milliseconds(400)]
        let appState = try await leaveAppState(routes, room: leaveOwnRoom)
        await appState.openGroupRoom(leaveOwnRoom)
        // The opening read is asked and waits, with Laifu still in.
        await copiesWait("the opening read asked", until: { routes.peopleReads.count == 1 })

        routes.people = leaveOwnPeople(laifu: "removed")
        let laifu = try XCTUnwrap(appState.activeRoomMembers.first { $0.memberID == "m-laifu" })
        let result = await appState.takeOut(laifu)
        XCTAssertEqual(result, .done)
        XCTAssertEqual(appState.activeRoomPeople["m-laifu"]?.out, .removed)

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(appState.activeRoomPeople["m-laifu"]?.out, .removed, "the older read doesn't put it back in")
        appState.closeGroupRoom()
    }

    @MainActor
    func testNothingIsTakenOutOfARoomThatsOverOrOnAnOlderPlugin() async throws {
        let older = CopiesRoutes(copies: [copiesCopy()])
        let olderState = try await leaveAppState(older, report: copiesPluginReport)
        await olderState.openRoomCopy(try XCTUnwrap(olderState.linkedRoomCopyRows.first))
        XCTAssertFalse(olderState.canLeaveActiveRoom)
        XCTAssertFalse(olderState.canTakeOut(try XCTUnwrap(olderState.activeRoomMembers.first { $0.memberID == "m-kuro" })))
        olderState.closeGroupRoom()

        let routes = CopiesRoutes(copies: [copiesCopy(status: "ended", reason: "disbanded")])
        let appState = try await leaveAppState(routes)
        await appState.openRoomCopy(try XCTUnwrap(appState.linkedRoomCopyRows.first))
        XCTAssertFalse(appState.canLeaveActiveRoom)
        XCTAssertFalse(appState.canTakeOut(try XCTUnwrap(appState.activeRoomMembers.first { $0.memberID == "m-kuro" })))
        let result = await appState.leaveActiveRoom()
        guard case .refused = result else { return XCTFail("left a room that's over") }
        XCTAssertEqual(routes.leaves.count, 0, "nothing is sent")
    }

    @MainActor
    func testAnEndedCopyWhoseOpeningReadFailedIsPolledUntilItsTailComes() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy(status: "ended", reason: "disbanded")])
        routes.events = (1...3).map { copiesEvent($0) }
        routes.failingLogReads = 1
        let appState = try await leaveAppState(routes)
        await appState.openRoomCopy(try XCTUnwrap(appState.linkedRoomCopyRows.first))
        XCTAssertEqual(appState.activeRoomReplay.events, [])
        XCTAssertTrue(appState.isPollingActiveRoom, "its tail is read again")

        await appState.pollActiveRoom()
        XCTAssertEqual(appState.activeRoomReplay.events.last?.seq, 3)
        XCTAssertFalse(appState.isPollingActiveRoom, "then nothing more comes")
        appState.closeGroupRoom()
    }

    @MainActor
    func testLeavingBeforeTheTailCameKeepsPollingUntilItDoes() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy()])
        routes.events = (1...3).map { copiesEvent($0) }
        routes.failingLogReads = 1
        let appState = try await leaveAppState(routes)
        await appState.openRoomCopy(try XCTUnwrap(appState.linkedRoomCopyRows.first))
        XCTAssertEqual(appState.activeRoomReplay.events, [])

        routes.copies = [copiesCopy(status: "left", yours: [])]
        let result = await appState.leaveActiveRoom()
        XCTAssertEqual(result, .done)
        XCTAssertTrue(appState.isPollingActiveRoom, "its tail hasn't come")

        await appState.pollActiveRoom()
        XCTAssertEqual(appState.activeRoomReplay.events.last?.seq, 3)
        XCTAssertFalse(appState.isPollingActiveRoom)
        appState.closeGroupRoom()
    }

    @MainActor
    func testDeletingACopyReadsItsInviteAgainEvenWhenOneWasRead() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy(status: "ended", reason: "disbanded")])
        routes.invites = [["room_id": "conduit-9", "link": "lk1a2b3c4d5e6f", "name": "Zoo trip", "status": "ended",
                           "from": "Furina", "joined": [["profile": "research", "handle": "kuro", "display_name": "Kuro"]]]]
        let appState = try await leaveAppState(routes)
        let copy = try XCTUnwrap(appState.linkedRoomCopyRows.first)
        XCTAssertNotNil(appState.linkedRoomInvite(copy.id))
        // Since that read, another of yours turned out to have left.
        routes.invites = [["room_id": "conduit-9", "link": "lk1a2b3c4d5e6f", "name": "Zoo trip", "status": "ended",
                           "from": "Furina", "joined": [["profile": "research", "handle": "kuro", "display_name": "Kuro"]],
                           "gone": [["profile": "writer", "handle": "quill", "display_name": "Quill", "reason": "left"]]]]

        let result = await appState.deleteLinkedRoomCopy(copy)
        XCTAssertEqual(result, .deleted)
        XCTAssertEqual(routes.deletes, [
            "/api/plugins/conduit_push/rooms/sessions?room_id=conduit-9&profile=research",
            "/api/plugins/conduit_push/rooms/sessions?room_id=conduit-9&profile=writer",
            "/api/plugins/conduit_push/rooms/copies?room_id=conduit-9",
        ])
    }

    @MainActor
    func testAnEndedCopyWithAgentsStillListedIsntDeletedWhenItsInviteCantBeRead() async throws {
        // One of yours could have left before it ended: only its invite says.
        let routes = CopiesRoutes(copies: [copiesCopy(status: "ended", reason: "disbanded")])
        routes.failsInvites = true
        let appState = try await leaveAppState(routes)
        let copy = try XCTUnwrap(appState.linkedRoomCopyRows.first)

        let result = await appState.deleteLinkedRoomCopy(copy)
        guard case .refused = result else { return XCTFail("deleted without knowing whose chats to delete") }
        XCTAssertEqual(routes.deletes, [])
        XCTAssertEqual(appState.linkedRoomCopyRows.map(\.id), [copy.id])
    }
}
