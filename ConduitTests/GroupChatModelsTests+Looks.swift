import XCTest
import UIKit

@testable import Conduit

/// How other people's agents and the people look in rooms over Links
/// (RoomLooks.swift, room_looks.py).
extension GroupChatModelsTests {
    private var looksJPEG: Data { Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 7, count: 40) }

    private func looksResponse() -> [String: Any] {
        [
            "ok": true,
            "room_id": "conduit-9",
            "members": [
                "m-laifu": ["picture": looksJPEG.base64EncodedString(), "color": "#AA3300"],
                "m-bare": ["picture": NSNull(), "color": NSNull()],
                "m-odd": ["picture": NSNull(), "color": "red"],
            ],
            "people": [
                ["name": "Mona Lisa", "poster": "Mona", "look": ["picture": NSNull(), "color": "#00AA00"]],
            ],
            "home": ["picture": looksJPEG.base64EncodedString(), "color": NSNull()],
        ]
    }

    func testRoomLooksReadEachMemberPersonAndTheHost() throws {
        var looks = RoomLooks(looksResponse())
        XCTAssertEqual(looks.members.keys.sorted(), ["m-laifu"], "a look with neither, or a color that isn't one, is left out")
        XCTAssertEqual(looks.members["m-laifu"], RoomLook(picture: looksJPEG, color: "#AA3300"))
        // A person is found by their Link's name and by the name their posts carry.
        XCTAssertEqual(looks.person(named: "Mona Lisa")?.color, "#00AA00")
        XCTAssertEqual(looks.person(named: " Mona ")?.color, "#00AA00")
        XCTAssertNil(looks.person(named: "Furina"), "the host only by the host's name")
        // The host, by the name your Link gives them.
        looks.hostName = "Furina"
        XCTAssertEqual(looks.person(named: "Furina")?.picture, looksJPEG)
        XCTAssertNil(looks.person(named: nil))
        XCTAssertEqual(RoomLooks(["ok": true]), .empty)
    }

    func testOnlyAnotherPersonsAgentTakesItsOwnersLook() {
        let looks = RoomLooks(looksResponse())
        let peer = GroupMember(memberID: "m-laifu", profile: nil, handle: "laifu", displayName: "Laifu",
                               target: ["kind": .string("peer")], extra: [:], owner: "Mona")
        XCTAssertEqual(looks.member(peer)?.color, "#AA3300")
        var yours = peer
        yours.isYours = true
        XCTAssertNil(looks.member(yours), "yours is drawn as your bot")
        let local = GroupMember(memberID: "m-laifu", profile: "default", handle: "laifu", displayName: "Laifu",
                                target: ["kind": .string("local")], extra: [:])
        XCTAssertNil(looks.member(local))
        XCTAssertNil(looks.member(nil))
        XCTAssertEqual(GroupRoomTurns.shownOwner(of: peer), "Mona")
        XCTAssertNil(GroupRoomTurns.shownOwner(of: yours))
    }

    func testAPictureSentIsASmallSquareJPEG() throws {
        // A noisy photo, the hardest to make small.
        let size = CGSize(width: 900, height: 600)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            for x in stride(from: 0, to: 900, by: 6) {
                for y in stride(from: 0, to: 600, by: 6) {
                    UIColor(red: CGFloat((x * 7 + y * 13) % 255) / 255, green: CGFloat((x * y) % 255) / 255,
                            blue: CGFloat((x + y * 3) % 255) / 255, alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: 6, height: 6))
                }
            }
        }
        let data = try XCTUnwrap(RoomLooksUpload.picture(image))
        XCTAssertLessThanOrEqual(data.count, RoomLooksUpload.maxPictureBytes)
        XCTAssertEqual(Array(data.prefix(3)), [0xFF, 0xD8, 0xFF])
        let decoded = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(decoded.size.width, decoded.size.height)
        XCTAssertLessThanOrEqual(decoded.size.width * decoded.scale, 96)
    }

    func testTheBodySaysEachBotsLookAndYoursAndItsDigestIsStable() throws {
        let agents = ["work": RoomLook(picture: nil, color: "#112233"), "default": RoomLook(picture: looksJPEG, color: nil)]
        let body = RoomLooksUpload.body(agents: agents, person: nil)
        let sent = try XCTUnwrap(body["agents"] as? [String: [String: Any]])
        XCTAssertEqual(sent["work"]?["color"] as? String, "#112233")
        XCTAssertTrue(sent["work"]?["picture"] is NSNull)
        XCTAssertEqual(sent["default"]?["picture"] as? String, looksJPEG.base64EncodedString())
        XCTAssertTrue(body["person"] is NSNull)
        let person = RoomLook(picture: looksJPEG, color: nil)
        XCTAssertEqual(RoomLooksUpload.digest(agents: agents, person: person),
                       RoomLooksUpload.digest(agents: agents, person: person))
        XCTAssertNotEqual(RoomLooksUpload.digest(agents: agents, person: person),
                          RoomLooksUpload.digest(agents: agents, person: nil))
        XCTAssertNotEqual(RoomLooksUpload.digest(agents: agents, person: nil),
                          RoomLooksUpload.digest(agents: ["work": RoomLook(picture: nil, color: "#112244")], person: nil))
    }

    @MainActor
    func testAnotherPersonsAgentIsTintedInItsOwnersColor() throws {
        let appState = try copiesAppState(CopiesRoutes(copies: []))
        let peer = GroupMember(memberID: "m-laifu", profile: nil, handle: "laifu", displayName: "Laifu",
                               target: ["kind": .string("peer")], extra: [:], owner: "Mona")
        let before = appState.groupMemberTints([peer])["m-laifu"]
        appState.activeRoomLooks = RoomLooks(looksResponse())
        let tint = try XCTUnwrap(appState.groupMemberTints([peer])["m-laifu"])
        XCTAssertNotEqual(tint, before)
        XCTAssertEqual(tint, CustomAccentColor(hex: "#AA3300"))
    }

    // MARK: - Reading them in an open room

    /// A room with one of your agents and Mona's Laifu, on a plugin that
    /// keeps looks, open.
    @MainActor
    private func looksRoomAppState(_ routes: CopiesRoutes) async throws -> AppState {
        routes.people = ["ok": true, "room_id": "conduit-5", "home": NSNull(), "members": [
            ["member_id": "m-nahida", "handle": "nahida", "display_name": "Nahida", "owner": NSNull(), "status": "in"],
            ["member_id": "m-laifu", "handle": "laifu", "display_name": "Laifu", "owner": "Mona", "status": "in"],
        ]]
        routes.looks = ["ok": true, "room_id": "conduit-5", "members": [
            "m-laifu": ["picture": NSNull(), "color": "#AA3300"],
        ], "people": [[String: Any]](), "home": NSNull()]
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
        var report = copiesPluginReport
        report["capabilities"] = (report["capabilities"] as? [String] ?? []) + [RoomLooksUpload.capability]
        appState.applyNotifierPluginReport(report)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(room)
        return appState
    }

    @MainActor
    func testAFailedLooksReadIsTriedAgainOnTheNextPoll() async throws {
        let routes = CopiesRoutes(copies: [])
        routes.failingLooksReads = 1
        let appState = try await looksRoomAppState(routes)
        await copiesWait("the first looks read", until: { routes.looksReads >= 1 })
        await copiesWait("the failed read settles", until: { appState.activeRoomLooksReadAt == nil
            || appState.activeRoomLooks.members["m-laifu"] != nil })
        // The next poll reads again, not 30 s on.
        appState.readActiveRoomLooksIfDue()
        await copiesWait("Laifu's look", until: { appState.activeRoomLooks.members["m-laifu"] != nil })
        XCTAssertGreaterThanOrEqual(routes.looksReads, 2)
        XCTAssertEqual(appState.activeRoomLooks.members["m-laifu"]?.color, "#AA3300")
    }

    @MainActor
    func testOneLooksReadAtATimeAndALateOneIsDroppedOnceTheRoomCloses() async throws {
        let routes = CopiesRoutes(copies: [])
        let appState = try await looksRoomAppState(routes)
        await copiesWait("Laifu's look", until: { appState.activeRoomLooks.members["m-laifu"] != nil })
        let before = routes.looksReads
        routes.looksDelays = [.milliseconds(300), .milliseconds(300)]
        routes.looks["members"] = ["m-laifu": ["picture": NSNull(), "color": "#0033AA"]]
        let epoch = appState.groupRoomEpoch
        // The people read and the poll can both start one.
        let first = Task { await appState.readActiveRoomLooks(epoch: epoch) }
        let second = Task { await appState.readActiveRoomLooks(epoch: epoch) }
        await copiesWait("a read asked", until: { routes.looksReads > before })
        appState.closeGroupRoom()
        await first.value
        await second.value
        XCTAssertEqual(routes.looksReads, before + 1, "the second read is skipped while the first is out")
        XCTAssertEqual(appState.activeRoomLooks, .empty, "a read answering after the room closed is dropped")
    }

    // MARK: - On Bots Home

    @MainActor
    func testBotsHomeKeepsEachLinkedRoomsLooksForItsPicture() async throws {
        let routes = CopiesRoutes(copies: [])
        let appState = try await looksRoomAppState(routes)
        await copiesWait("Laifu's look", until: { appState.activeRoomLooks.members["m-laifu"] != nil })
        XCTAssertTrue(appState.shownGroupRooms.first { $0.roomID == "conduit-5" }?.isLinked == true)
        XCTAssertEqual(appState.homeLinkedRoomIDs, ["conduit-5"])
        XCTAssertEqual(appState.homeRoomLooks(roomID: "conduit-5").members["m-laifu"]?.color, "#AA3300",
                       "the open room's read is kept for its tile")
        XCTAssertEqual(appState.homeRoomLooks(roomID: "conduit-other"), .empty)

        appState.closeGroupRoom()
        routes.looks["members"] = ["m-laifu": ["picture": NSNull(), "color": "#0033AA"]]
        let before = routes.looksReads
        await appState.readHomeRoomLooks()
        XCTAssertEqual(routes.looksReads, before, "read again only 30 s on")
        appState.homeRoomLooksReadAt = [:]
        await appState.readHomeRoomLooks()
        XCTAssertEqual(routes.looksReads, before + 1)
        XCTAssertEqual(appState.homeRoomLooks(roomID: "conduit-5").members["m-laifu"]?.color, "#0033AA")
    }

    // MARK: - Giving yours

    @MainActor
    func testLooksAreGivenOnceForEachChangeAndAFailedOneIsTriedAgain() async throws {
        let routes = CopiesRoutes(copies: [])
        let bot = BotProfile(
            name: "default", botTitle: "Furina", displayName: "", profileDescription: "", model: nil, provider: nil,
            hasAvatar: false, isPinned: false, isHiddenByMeta: false, appearanceColor: "#AA3300",
            canonicalSession: nil, lastActive: nil, lastPreview: nil
        )
        var chatResume = ChatResumeLifecycleOperations.live
        chatResume.botRoster = { _ in BotRosterSnapshot(bots: [bot], supportsBotProtocol: true) }
        let appState = try copiesAppState(routes, chatResume: chatResume)
        copiesConnect(appState)
        var report = copiesPluginReport
        report["capabilities"] = (report["capabilities"] as? [String] ?? [])
            + [RoomDraftsClient.capability, RoomLooksUpload.capability]
        appState.applyNotifierPluginReport(report)
        await appState.refreshBotRoster()
        XCTAssertEqual(appState.shownBotRoster.map(\.name), ["default"])
        XCTAssertNil(appState.roomPersonPicture, "read from this AppState's own defaults")

        // A failed one isn't counted as given, so the next try sends it.
        routes.failingLooksPuts = 1
        await appState.shareRoomLooksIfNeeded()
        await appState.shareRoomLooksIfNeeded()
        XCTAssertEqual(routes.looksPuts.count, 2)
        let agents = try XCTUnwrap(routes.looksPuts.last?["agents"] as? [String: Any])
        XCTAssertEqual(agents.keys.sorted(), ["default"])
        XCTAssertTrue(routes.looksPuts.last?["person"] is NSNull)

        // Nothing changed: nothing sent.
        await appState.shareRoomLooksIfNeeded()
        XCTAssertEqual(routes.looksPuts.count, 2)

        // Your picture is a change, kept on this AppState's defaults.
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        let taken = await appState.setRoomPersonPicture(image)
        XCTAssertTrue(taken)
        XCTAssertEqual(routes.looksPuts.count, 3)
        let person = try XCTUnwrap(routes.looksPuts.last?["person"] as? [String: Any])
        XCTAssertNotNil(person["picture"] as? String)
        XCTAssertNotNil(appState.appDefaults.data(forKey: RoomLooksUpload.personPictureKey))

        await appState.setRoomPersonPicture(nil)
        XCTAssertEqual(routes.looksPuts.count, 4)
        XCTAssertNil(appState.appDefaults.data(forKey: RoomLooksUpload.personPictureKey))
    }
}
