import XCTest

@testable import Conduit

/// Files sent into a room and the room screen's message grouping. An
/// extension, so the test planner sees no new class.
extension GroupChatModelsTests {
    private func roomEvent(seq: Int, kind: String, actorID: String, text: String = "hi") -> GroupEvent? {
        GroupDecoders.event(AnyCodable.from([
            "room_id": "room-1",
            "seq": seq,
            "event_id": "e\(seq)",
            "kind": kind,
            "actor": ["kind": kind == "message.user" ? "user" : "member", "id": actorID],
            "payload": ["text": text],
            "created_at": 1_760_000_000.0,
        ] as [String: Any]))
    }

    /// Past the room's 50 MB cap a higher Settings limit can't help, so
    /// the message names the room's cap and doesn't send the user to
    /// Settings (#935). Under it, the Settings limit is the one that bound.
    func testRoomTooLargeMessageNamesTheRoomCapWhenItBinds() {
        let capped = GroupRoomFilesClient.tooLargeMessage(names: ["clip.mov"], preference: 256)
        XCTAssertTrue(capped.contains("clip.mov") && capped.contains("50"), capped)
        XCTAssertFalse(capped.contains("Settings"), capped)
        let cappedMany = GroupRoomFilesClient.tooLargeMessage(names: ["a.mov", "b.mov"], preference: 128)
        XCTAssertTrue(cappedMany.contains("a.mov") && cappedMany.contains("b.mov") && cappedMany.contains("50"), cappedMany)
        XCTAssertFalse(cappedMany.contains("Settings"), cappedMany)

        let preferred = GroupRoomFilesClient.tooLargeMessage(names: ["clip.mov"], preference: 16)
        XCTAssertEqual(preferred, AttachmentSizeLimit.tooLargeMessage(names: ["clip.mov"], megabytes: 16))
    }

    func testRoomFileReferenceTakesTheHostsRefText() throws {
        let reference = try GroupRoomFilesClient.reference(from: [
            "ok": true, "path": "/h/conduit/room-files/a/photo.jpg", "ref_text": "@file:/h/conduit/room-files/a/photo.jpg",
        ])
        XCTAssertEqual(reference, "@file:/h/conduit/room-files/a/photo.jpg")
    }

    func testRoomFileReferenceFallsBackToAQuotedPath() throws {
        let reference = try GroupRoomFilesClient.reference(from: ["ok": true, "path": "/h/room files/my photo.jpg"])
        XCTAssertEqual(reference, "@file:`/h/room files/my photo.jpg`")
    }

    func testRoomFileReferenceRefusesAnAnswerWithoutAPath() {
        XCTAssertThrowsError(try GroupRoomFilesClient.reference(from: ["ok": true]))
        XCTAssertThrowsError(try GroupRoomFilesClient.reference(from: ["ok": false, "path": "/x"]))
    }

    @MainActor
    func testRoomMessageShowsLeadingFileReferencesAsFiles() {
        let text = AppState.promptText("Look at this", fileReferences: [
            "@file:/h/conduit/room-files/a/photo.jpg",
            "@file:`/h/conduit/room-files/b/my notes.pdf`",
        ])
        let parts = GroupMessageParts(text)
        XCTAssertEqual(parts.text, "Look at this")
        XCTAssertEqual(parts.files.map(\.name), ["photo.jpg", "my notes.pdf"])
        XCTAssertEqual(parts.files.first?.kind, .image)
    }

    func testRoomMessageWithoutFilesIsUnchanged() {
        let parts = GroupMessageParts("Hello @all, see @file:/x mid-sentence")
        XCTAssertEqual(parts.text, "Hello @all, see @file:/x mid-sentence")
        XCTAssertTrue(parts.files.isEmpty)
    }

    func testOneSpeakersRunOfRepliesIsGrouped() throws {
        let first = try XCTUnwrap(roomEvent(seq: 1, kind: "message.member", actorID: "m-1"))
        let second = try XCTUnwrap(roomEvent(seq: 2, kind: "message.member", actorID: "m-1"))
        let other = try XCTUnwrap(roomEvent(seq: 3, kind: "message.member", actorID: "m-2"))
        let user = try XCTUnwrap(roomEvent(seq: 4, kind: "message.user", actorID: "human"))
        let userAgain = try XCTUnwrap(roomEvent(seq: 5, kind: "message.user", actorID: "human"))
        XCTAssertTrue(GroupEventRow.sameSpeaker(first, second))
        XCTAssertFalse(GroupEventRow.sameSpeaker(second, other))
        XCTAssertFalse(GroupEventRow.sameSpeaker(other, user))
        XCTAssertTrue(GroupEventRow.sameSpeaker(user, userAgain))
    }

    private func stagedFile(_ name: String, contents: String) throws -> Attachment {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
        try Data(contents.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Attachment(id: UUID().uuidString, name: name, uri: url.absoluteString, mimeType: "text/plain", kind: .document)
    }

    @MainActor
    func testRoomFilesUploadInOrderAndReturnTheirReferences() async throws {
        let files = [try stagedFile("a.txt", contents: "one"), try stagedFile("b.txt", contents: "two")]
        var sent: [[String: Any]] = []
        let client = GroupRoomFilesClient(request: { path, body in
            XCTAssertEqual(path, GroupRoomFilesClient.path)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            sent.append(json)
            return ["ok": true, "path": "/h/room-files/\(json["name"] as? String ?? "")"]
        })
        let references = try await client.upload(files)
        XCTAssertEqual(references, ["@file:/h/room-files/a.txt", "@file:/h/room-files/b.txt"])
        XCTAssertEqual(sent.compactMap { $0["data_base64"] as? String }, [Data("one".utf8).base64EncodedString(), Data("two".utf8).base64EncodedString()])
    }

    @MainActor
    func testRoomFileUploadRefusesAnUnreadableFile() async {
        let missing = Attachment(id: "x", name: "gone.txt", uri: "file:///nonexistent/gone.txt", mimeType: nil, kind: .document)
        let client = GroupRoomFilesClient(request: { _, _ in
            XCTFail("nothing to send")
            return [:]
        })
        do {
            _ = try await client.upload([missing])
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? GroupRoomFilesClient.Failure, .unreadable("gone.txt"))
        }
    }

    @MainActor
    func testRoomFileUploadRefusesAHostThatSaysNo() async throws {
        let file = try stagedFile("a.txt", contents: "one")
        let client = GroupRoomFilesClient(request: { _, _ in ["ok": false] })
        do {
            _ = try await client.upload([file])
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? GroupRoomFilesClient.Failure, .malformed)
        }
    }
}

/// Group chat pictures: the plugin's answers, Desktop's synced picture and
/// the default icon's member layout.
extension GroupChatModelsTests {
    func testRoomPicturePathsEscapeNothingAndRefuseOddIDs() {
        XCTAssertEqual(GroupRoomPictures.path(for: "room_1:a.b-c"), "/api/plugins/conduit_push/room-images/room_1:a.b-c")
        XCTAssertNil(GroupRoomPictures.path(for: ""))
        XCTAssertNil(GroupRoomPictures.path(for: "a/b"))
        XCTAssertNil(GroupRoomPictures.path(for: "a b"))
    }

    func testRoomPictureAnswersDecode() {
        XCTAssertEqual(
            GroupRoomPictures.revisions(from: ["ok": true, "revisions": ["r1": "1-a", "r2": "", "r3": 4]]),
            ["r1": "1-a"]
        )
        XCTAssertNil(GroupRoomPictures.revisions(from: ["ok": false]))
        let picture = GroupRoomPictures.picture(from: [
            "ok": true, "rev": "2-b", "data_base64": Data([0xFF, 0xD8, 0xFF]).base64EncodedString(),
        ])
        XCTAssertEqual(picture?.data, Data([0xFF, 0xD8, 0xFF]))
        XCTAssertEqual(picture?.revision, "2-b")
        XCTAssertNil(GroupRoomPictures.picture(from: ["ok": true, "rev": "2-b", "data_base64": "%%"]))
        XCTAssertEqual(GroupRoomPictures.storedRevision(from: ["ok": true, "rev": "3-c"]), "3-c")
        XCTAssertNil(GroupRoomPictures.storedRevision(from: ["ok": true]))
    }

    func testARoomPictureChangedDuringARefreshKeepsTheChange() {
        let old = Data([1]), new = Data([2]), other = Data([3])
        // The refresh saw r1's old picture and r2 still listed, then the user
        // set r1's picture and removed r2's before it finished.
        let merged = GroupRoomPictures.merged(
            data: ["r1": new, "r3": other, "gone": other],
            revisions: ["r1": "2-new", "r3": "1-c", "gone": "1-g"],
            listed: ["r1": "1-old", "r2": "1-b", "r3": "2-c"],
            fetched: ["r1": (old, "1-old"), "r2": (other, "1-b"), "r3": (new, "2-c")],
            changed: ["r1", "r2"]
        )
        XCTAssertEqual(merged.data["r1"], new, "the picture just set stays")
        XCTAssertEqual(merged.revisions["r1"], "2-new")
        XCTAssertNil(merged.data["r2"], "the picture just removed stays removed")
        XCTAssertNil(merged.revisions["r2"])
        XCTAssertEqual(merged.data["r3"], new, "an untouched room takes what the refresh fetched")
        XCTAssertEqual(merged.revisions["r3"], "2-c")
        XCTAssertNil(merged.data["gone"], "a room the host no longer lists loses its picture")
    }

    func testARefreshLeavesRoomsWhoseChangeWasStillOnItsWay() {
        // r1's set was sent before the refresh began and is still on its way;
        // r2 was set after it began; r3 was changed long before and settled.
        let changed = GroupRoomPictures.changed(
            started: ["r1": 1, "r3": 4],
            generations: ["r1": 1, "r2": 1, "r3": 4],
            changingAtStart: ["r1"]
        )
        XCTAssertEqual(changed, ["r1", "r2"])
        XCTAssertEqual(GroupRoomPictures.changed(started: ["r3": 4], generations: ["r3": 4], changingAtStart: []), [])
    }

    func testDesktopProjectionCarriesTheRoomPictureAndID() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let room: [String: Any] = [
            "name": "Pictured", "roomId": "r-pic", "revision": 1,
            "image": "data:image/png;base64," + png.base64EncodedString(),
            "members": [["name": "Writer"]],
            "log": [["id": "m1", "from": ["kind": "user", "name": "You"], "text": "hi", "at": 1_000.0]],
        ]
        let plain: [String: Any] = ["name": "Plain", "revision": 1, "image": "https://example.com/a.png", "log": []]
        let groups = DesktopGroupChatDecoder.decode(snapshot: AnyCodable.from([
            "version": 3, "rooms": ["id:r-pic": room, "name:Plain": plain],
        ] as [String: Any]))
        let pictured = groups.first { $0.name == "Pictured" }
        XCTAssertEqual(pictured?.imageData, png)
        XCTAssertEqual(pictured?.roomID, "r-pic")
        XCTAssertEqual(pictured?.groupMembers.first?.displayName, "Writer")
        let unpictured = groups.first { $0.name == "Plain" }
        XCTAssertNil(unpictured?.imageData)
        XCTAssertNil(unpictured?.roomID)
    }

    func testDefaultGroupIconKeepsEveryMemberInsideItsFrame() {
        XCTAssertTrue(GroupRoomIcon.layout(count: 0).isEmpty)
        for count in 1...5 {
            let spots = GroupRoomIcon.layout(count: count)
            XCTAssertEqual(spots.count, min(count, 3))
            for spot in spots {
                XCTAssertLessThanOrEqual(abs(spot.x) + spot.diameter / 2, 0.5 + 0.0001)
                XCTAssertLessThanOrEqual(abs(spot.y) + spot.diameter / 2, 0.5 + 0.0001)
            }
        }
    }
}
