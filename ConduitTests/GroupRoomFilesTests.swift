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
            sent.append(body)
            return ["ok": true, "path": "/h/room-files/\(body["name"] as? String ?? "")"]
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
