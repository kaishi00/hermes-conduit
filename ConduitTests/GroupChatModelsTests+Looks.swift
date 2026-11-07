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
        let looks = RoomLooks(looksResponse())
        XCTAssertEqual(looks.members.keys.sorted(), ["m-laifu"], "a look with neither, or a color that isn't one, is left out")
        XCTAssertEqual(looks.members["m-laifu"], RoomLook(picture: looksJPEG, color: "#AA3300"))
        // A person is found by their Link's name and by the name their posts carry.
        XCTAssertEqual(looks.person(named: "Mona Lisa", hostName: nil)?.color, "#00AA00")
        XCTAssertEqual(looks.person(named: " Mona ", hostName: nil)?.color, "#00AA00")
        // The host, by the name your Link gives them.
        XCTAssertEqual(looks.person(named: "Furina", hostName: "Furina")?.picture, looksJPEG)
        XCTAssertNil(looks.person(named: "Furina", hostName: nil))
        XCTAssertNil(looks.person(named: nil, hostName: "Furina"))
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
}
