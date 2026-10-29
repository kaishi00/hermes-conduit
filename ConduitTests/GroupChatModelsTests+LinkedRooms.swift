import XCTest

@testable import Conduit

/// Rooms with agents from another installation (designs/cross-owner-agents,
/// C1): each peer route's state where "responding" was, the disband warning,
/// and your agents' per-room choices. Hermes c73cbcc4 and 9e01b44
/// (`tui_gateway/hosted_room_service.py` `_route_statuses`,
/// `member_activity`); notifier 0.81 (`room_choices.py`). An extension, so no
/// new class to plan.
extension GroupChatModelsTests {
    private func linkedRoomMember(_ id: String, profile: String? = nil, peer: Bool = false) -> GroupMember {
        let kind: AnyCodable = .string(peer ? "peer" : "local")
        return GroupMember(
            memberID: id,
            profile: profile ?? id,
            handle: id,
            displayName: id.capitalized,
            target: ["kind": kind],
            extra: [:]
        )
    }

    private func linkedRoomDriver(
        routes: [GroupPeerRoute] = [],
        activity: [GroupMemberActivity]? = nil
    ) -> GroupDriverStatus {
        GroupDriverStatus(
            running: true,
            working: true,
            blocked: false,
            counts: [:],
            pendingActions: [],
            peerRoutes: routes,
            memberActivity: activity
        )
    }

    private func linkedRoomBot(_ name: String, title: String? = nil) -> BotProfile {
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

    private func linkedRoomChoices(
        _ choices: [String: Any],
        saved: Bool? = nil,
        room: String = "conduit-1"
    ) -> [String: Any] {
        var answer: [String: Any] = ["ok": true, "room_id": room, "choices": choices]
        if let saved { answer["saved"] = saved }
        return answer
    }

    // MARK: - Driver status

    func testDriverStatusReadsPeerRoutesAndMemberActivity() {
        let payload: [String: Any] = [
            "running": true,
            "working": true,
            "blocked": false,
            "peer_routes": [
                ["room_id": "conduit-1", "member_id": "laifu", "status": "ready"],
                ["room_id": "conduit-1", "member_id": "mona-bot", "status": "needs_reauthorization"],
                ["room_id": "conduit-1", "member_id": "kazuha", "status": "unavailable"],
                ["room_id": "conduit-1", "member_id": "venti", "status": "rebuilding"],
                // No member to show it on.
                ["room_id": "conduit-1", "status": "unavailable"],
                ["room_id": "conduit-1", "member_id": "  ", "status": "unavailable"],
            ],
            "member_activity": [
                ["member_id": "furina", "status": "running"],
                ["member_id": "laifu", "status": "queued"],
                ["status": "queued"],
            ],
        ]
        let status = GroupDecoders.driverStatus(AnyCodable.from(payload))
        XCTAssertEqual(status?.peerRoutes, [
            GroupPeerRoute(memberID: "laifu", status: .ready),
            GroupPeerRoute(memberID: "mona-bot", status: .cutOff),
            GroupPeerRoute(memberID: "kazuha", status: .unreachable),
            GroupPeerRoute(memberID: "venti", status: .other("rebuilding")),
        ])
        XCTAssertEqual(status?.memberActivity, [
            GroupMemberActivity(memberID: "furina", status: "running"),
            GroupMemberActivity(memberID: "laifu", status: "queued"),
        ])

        // 9e01b44 sends neither: no routes, and who's live stays the log's.
        let older = GroupDecoders.driverStatus(AnyCodable.from(["running": true, "working": true] as [String: Any]))
        XCTAssertEqual(older?.peerRoutes, [])
        XCTAssertNil(older?.memberActivity)
        // Nobody live is an answer too.
        let idle = GroupDecoders.driverStatus(AnyCodable.from(["working": false, "member_activity": [Any]()] as [String: Any]))
        XCTAssertEqual(idle?.memberActivity, [])
    }

    func testLiveMemberPrefersARunningTurnOverAQueuedOne() {
        let members = [linkedRoomMember("furina"), linkedRoomMember("laifu", peer: true)]
        XCTAssertEqual(GroupRoomTurns.liveMember([
            GroupMemberActivity(memberID: "laifu", status: "queued"),
            GroupMemberActivity(memberID: "furina", status: "running"),
        ], members: members)?.memberID, "furina")
        // A turn that's stopping still has the room.
        XCTAssertEqual(GroupRoomTurns.liveMember([
            GroupMemberActivity(memberID: "laifu", status: "queued"),
            GroupMemberActivity(memberID: "furina", status: "stopping"),
        ], members: members)?.memberID, "furina")
        // Only queued turns: the first admitted.
        XCTAssertEqual(GroupRoomTurns.liveMember([
            GroupMemberActivity(memberID: "laifu", status: "queued"),
            GroupMemberActivity(memberID: "furina", status: "queued"),
        ], members: members)?.memberID, "laifu")
        XCTAssertNil(GroupRoomTurns.liveMember([], members: members))
    }

    func testLiveMemberSkipsAStatusThisBuildDoesntKnow() {
        let members = [linkedRoomMember("furina"), linkedRoomMember("laifu", peer: true)]
        XCTAssertEqual(GroupRoomTurns.liveMember([
            GroupMemberActivity(memberID: "furina", status: "finishing"),
            GroupMemberActivity(memberID: "laifu", status: "queued"),
        ], members: members)?.memberID, "laifu")
        XCTAssertNil(GroupRoomTurns.liveMember([
            GroupMemberActivity(memberID: "furina", status: "finishing"),
            GroupMemberActivity(memberID: "laifu", status: ""),
        ], members: members))
    }

    func testLiveMemberSkipsIdsOutsideTheRoom() {
        let members = [linkedRoomMember("furina"), linkedRoomMember("laifu", peer: true)]
        XCTAssertEqual(GroupRoomTurns.liveMember([
            GroupMemberActivity(memberID: "ghost", status: "running"),
            GroupMemberActivity(memberID: "laifu", status: "queued"),
        ], members: members)?.memberID, "laifu")
        XCTAssertNil(GroupRoomTurns.liveMember(
            [GroupMemberActivity(memberID: "ghost", status: "running")],
            members: members
        ))
    }

    // MARK: - Who can't answer

    func testACutOffPeerReadsCutOffUntilItsTurnRuns() {
        let laifu = linkedRoomMember("laifu", peer: true)
        let room = [linkedRoomMember("furina"), laifu]
        var status = linkedRoomDriver(
            routes: [GroupPeerRoute(memberID: "laifu", status: .cutOff)],
            activity: [GroupMemberActivity(memberID: "laifu", status: "queued")]
        )
        XCTAssertEqual(status.routeStatus(for: laifu), .cutOff)
        XCTAssertEqual(status.responderState(for: laifu, in: room), .cutOff)
        status.memberActivity = [GroupMemberActivity(memberID: "laifu", status: "running")]
        XCTAssertEqual(status.responderState(for: laifu, in: room), .responding)
        // A gateway that doesn't report live turns: the route alone says.
        status.memberActivity = nil
        XCTAssertEqual(status.responderState(for: laifu, in: room), .cutOff)
    }

    func testATurnNamedByItsProfileIsThatMembersRunningTurn() {
        // A task with no member id of its own is named by its profile, and
        // reads as the member liveMember puts first.
        let laifu = linkedRoomMember("m-laifu", profile: "laifu", peer: true)
        let room = [linkedRoomMember("furina"), laifu]
        let status = linkedRoomDriver(
            routes: [GroupPeerRoute(memberID: "m-laifu", status: .cutOff)],
            activity: [GroupMemberActivity(memberID: "laifu", status: "running")]
        )
        XCTAssertEqual(GroupRoomTurns.liveMember(status.memberActivity ?? [], members: room), laifu)
        XCTAssertEqual(status.responderState(for: laifu, in: room), .responding)
        // Without the room's list, it still reads its own turn.
        XCTAssertEqual(status.responderState(for: laifu, in: []), .responding)
        // A member whose id is that name has the turn instead.
        let named = linkedRoomMember("laifu")
        XCTAssertEqual(GroupRoomTurns.liveMember(status.memberActivity ?? [], members: room + [named]), named)
        XCTAssertEqual(status.responderState(for: laifu, in: room + [named]), .cutOff)
    }

    func testAnUnreachablePeerReadsUnreachable() {
        let laifu = linkedRoomMember("laifu", peer: true)
        let status = linkedRoomDriver(routes: [GroupPeerRoute(memberID: "laifu", status: .unreachable)])
        XCTAssertEqual(status.responderState(for: laifu, in: [laifu]), .unreachable)
        // Ready, a state this build doesn't know, or another member's route:
        // nothing in the way.
        for route in [
            GroupPeerRoute(memberID: "laifu", status: .ready),
            GroupPeerRoute(memberID: "laifu", status: .other("rebuilding")),
            GroupPeerRoute(memberID: "kazuha", status: .unreachable),
        ] {
            XCTAssertEqual(linkedRoomDriver(routes: [route]).responderState(for: laifu, in: [laifu]), .responding)
        }
    }

    func testYourOwnAgentAlwaysReadsResponding() {
        // A route row can only be a peer's: one that names your agent's id
        // says nothing about it.
        let furina = linkedRoomMember("furina")
        let status = linkedRoomDriver(routes: [GroupPeerRoute(memberID: "furina", status: .cutOff)])
        XCTAssertNil(status.routeStatus(for: furina))
        XCTAssertEqual(status.responderState(for: furina, in: [furina]), .responding)
    }

    // MARK: - Disband and pictures

    func testDisbandWarningSaysOtherPeoplesAgentsKeepTheirs() {
        let linked = GroupRoomDisband.warning(members: [
            linkedRoomMember("furina"), linkedRoomMember("laifu", peer: true),
        ])
        XCTAssertEqual(linked, AppLocalization.string(
            "The room ends for everyone, and your agents' sessions for it are deleted. Agents on other people's Hermes keep theirs. This cannot be undone."
        ))
        let own = GroupRoomDisband.warning(members: [linkedRoomMember("furina"), linkedRoomMember("nahida")])
        XCTAssertEqual(own, AppLocalization.string(
            "The room, its history, and every member's session end permanently. This cannot be undone."
        ))
    }

    func testAMemberOnAnotherHermesNeverTakesYourBotsPicture() {
        let roster = [linkedRoomBot("default", title: "Furina"), linkedRoomBot("nahida")]
        // Mona's default agent, and one named like yours.
        XCTAssertNil(GroupRoomTurns.rosterBot(
            for: linkedRoomMember("mona-bot", profile: "default", peer: true), name: "Laifu", in: roster
        ))
        XCTAssertNil(GroupRoomTurns.rosterBot(
            for: linkedRoomMember("furina-2", profile: "furina", peer: true), name: "Furina", in: roster
        ))
        // Your own agents still are your bots, by profile or by name.
        XCTAssertEqual(GroupRoomTurns.rosterBot(
            for: linkedRoomMember("furina", profile: "default"), name: "Furina", in: roster
        )?.name, "default")
        XCTAssertEqual(GroupRoomTurns.rosterBot(for: nil, name: "nahida", in: roster)?.name, "nahida")
    }

    // MARK: - Your agent's choices

    @MainActor
    func testRoomChoicesClientSendsOneChoiceToTheAgentsProfile() async throws {
        var asked: [(path: String, method: String, body: [String: Any]?)] = []
        var room = "conduit-1"
        let client = RoomChoicesClient { path, method, body in
            asked.append((path, method, body))
            return self.linkedRoomChoices([
                "tools": "look", "custom_tools": [String](), "share": "nothing", "search_chats": false,
                "takes_part": "joins", "daily_limit": 40, "note": "",
            ], room: room)
        }
        let kept = try await client.set(["share": "nothing"], roomID: "conduit-1", profile: "furina")
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.path, "/api/plugins/conduit_push/rooms/choices?profile=furina")
        XCTAssertEqual(asked.first?.method, "PUT")
        XCTAssertEqual(asked.first?.body?["room_id"] as? String, "conduit-1")
        let sent = asked.first?.body?["choices"] as? [String: Any]
        XCTAssertEqual(sent?.count, 1)
        XCTAssertEqual(sent?["share"] as? String, "nothing")
        // A change's answer has no `saved`: the room now has its own.
        XCTAssertEqual(kept, RoomChoices(
            tools: "look", customTools: [], share: "nothing", searchChats: false, note: "", saved: true
        ))

        // The default profile asks the bare path; the room id is escaped.
        room = "conduit-a b"
        _ = try await client.choices(roomID: "conduit-a b", profile: "default")
        XCTAssertEqual(asked.last?.path, "/api/plugins/conduit_push/rooms/choices?room_id=conduit-a%20b")
        XCTAssertEqual(asked.last?.method, "GET")
        XCTAssertNil(asked.last?.body)
    }

    @MainActor
    func testRoomChoicesReadTheDefaultsForARoomWithNone() async throws {
        var path: String?
        let client = RoomChoicesClient { requestPath, method, _ in
            XCTAssertEqual(method, "GET")
            path = requestPath
            return self.linkedRoomChoices([
                "tools": "talk", "custom_tools": [String](), "share": "ask", "search_chats": false,
                "takes_part": "joins", "daily_limit": 40, "note": "",
            ], saved: false)
        }
        let choices = try await client.choices(roomID: "conduit-1", profile: "furina")
        XCTAssertEqual(path, "/api/plugins/conduit_push/rooms/choices?room_id=conduit-1&profile=furina")
        XCTAssertEqual(choices, RoomChoices(
            tools: "talk", customTools: [], share: "ask", searchChats: false, note: "", saved: false
        ))
        // An answer without what the page shows is refused.
        XCTAssertThrowsError(try RoomChoicesClient.parse(["ok": true], roomID: "conduit-1"))
        XCTAssertThrowsError(try RoomChoicesClient.parse(
            linkedRoomChoices(["tools": "talk", "share": "ask"]), roomID: "conduit-1"
        ))
    }

    @MainActor
    func testRoomChoicesRefuseAnAnswerThatIsntOkOrIsAnotherRooms() async throws {
        let choices: [String: Any] = ["tools": "talk", "share": "ask", "search_chats": false]
        XCTAssertNoThrow(try RoomChoicesClient.parse(linkedRoomChoices(choices), roomID: "conduit-1"))
        var refused = linkedRoomChoices(choices)
        refused["ok"] = false
        XCTAssertThrowsError(try RoomChoicesClient.parse(refused, roomID: "conduit-1"))
        refused.removeValue(forKey: "ok")
        XCTAssertThrowsError(try RoomChoicesClient.parse(refused, roomID: "conduit-1"))
        // An answer that names no room is the one asked about.
        var unnamed = linkedRoomChoices(choices)
        unnamed.removeValue(forKey: "room_id")
        XCTAssertNoThrow(try RoomChoicesClient.parse(unnamed, roomID: "conduit-2"))

        // Another room's answer, to a read or a change, is never shown.
        let elsewhere = RoomChoicesClient { _, _, _ in self.linkedRoomChoices(choices, room: "conduit-2") }
        do {
            _ = try await elsewhere.choices(roomID: "conduit-1", profile: "furina")
            XCTFail("A read showed another room's choices")
        } catch HermesError.invalidResponse {}
        do {
            _ = try await elsewhere.set(["share": "ask"], roomID: "conduit-1", profile: "furina")
            XCTFail("A change showed another room's choices")
        } catch HermesError.invalidResponse {}
    }

    @MainActor
    func testACustomChoiceSetOnTheHostShowsItsTools() throws {
        let choices = try RoomChoicesClient.parse(linkedRoomChoices([
            "tools": "custom", "custom_tools": ["web_search", "write_file"], "share": "helps",
            "search_chats": true, "note": "No spoilers",
        ]), roomID: "conduit-1")
        XCTAssertEqual(choices.customTools, ["web_search", "write_file"])
        XCTAssertEqual(choices.note, "No spoilers")
        let detail = RoomAgentChoicesView.toolsDetail(choices, freeBusy: true)
        XCTAssertTrue(detail.contains("web_search, write_file"), detail)
        var none = choices
        none.customTools = []
        XCTAssertEqual(
            RoomAgentChoicesView.toolsDetail(none, freeBusy: true),
            AppLocalization.string("No tools are picked for it on your Hermes.")
        )
    }

    @MainActor
    func testUseMyDataSaysItSharesWhenYoureBusyOnlyWhereThePluginDoes() throws {
        let data = try XCTUnwrap(RoomChoicesClient.choices(["tools": "data", "share": "ask", "search_chats": false],
                                                           saved: true))
        let busy = RoomAgentChoicesView.toolsDetail(data, freeBusy: true)
        XCTAssertTrue(busy.contains("when you're busy") && busy.contains("only the times"), busy)
        // An older plugin's Use my data is only lookups.
        XCTAssertEqual(
            RoomAgentChoicesView.toolsDetail(data, freeBusy: false),
            AppLocalization.string("It can search the web and X, read web pages and look at images.")
        )
        XCTAssertEqual(RoomChoicesClient.freeBusyCapability, "room-free-busy")
    }

    @MainActor
    func testANoteIsClippedToThePluginsLimitInCodePoints() {
        let limit = RoomChoicesClient.noteLimit
        // The note's footer says so in words.
        XCTAssertEqual(limit, 1000)
        let fits = String(repeating: "a", count: limit)
        XCTAssertEqual(RoomChoicesClient.clippedNote(fits), fits)
        XCTAssertEqual(RoomChoicesClient.clippedNote(fits + "b"), fits)
        // A flag is one character of two code points: it goes whole or not at all.
        let almost = String(repeating: "a", count: limit - 1)
        XCTAssertEqual(RoomChoicesClient.clippedNote(almost + "🇯🇵"), almost)
        let room = String(repeating: "a", count: limit - 2)
        XCTAssertEqual(RoomChoicesClient.clippedNote(room + "🇯🇵"), room + "🇯🇵")
    }
}
