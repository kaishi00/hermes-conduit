import XCTest

@testable import Conduit

/// Room files as Hermes' own message attachments (`groups.attachment.*`,
/// Hermes 0.22.6+, issue 2035): Hermes hands their pictures to each bot as
/// a chat's, so a bot without vision reads them through the auxiliary
/// vision model. An extension, so the test planner sees no new class.
extension GroupChatModelsTests {
    private static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D])

    private func attachmentsStaged(_ name: String, data: Data, mimeType: String?, kind: Attachment.Kind) throws -> Attachment {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Attachment(id: UUID().uuidString, name: name, uri: url.absoluteString, mimeType: mimeType, kind: kind)
    }

    /// `linked` adds a guest's agent (a `peer` member, Linked Rooms).
    private func attachmentsRoom(linked: Bool = false) -> GroupRoom {
        var members = [
            GroupMember(memberID: "researcher", profile: "researcher", handle: "research-buddy",
                        displayName: "Research Buddy", target: nil, extra: [:]),
        ]
        if linked {
            members.append(GroupMember(memberID: "guest", profile: "guest", handle: "guest-bot",
                                       displayName: "Guest Bot", target: ["kind": .string("peer")], extra: [:]))
        }
        return GroupRoom(
            roomID: "room-1",
            name: "Planning",
            members: members,
            authorityGatewayID: "gw-a",
            authorityEpoch: 1,
            revision: 1,
            createdAt: 0,
            updatedAt: 0,
            disbandedAt: nil,
            latestSeq: 0
        )
    }

    private func attachmentsUserEvent(seq: Int, attachments: [[String: Any]]) throws -> GroupEvent {
        try XCTUnwrap(GroupDecoders.event(AnyCodable.from([
            "room_id": "room-1",
            "seq": seq,
            "event_id": "srv-\(seq)",
            "kind": "message.user",
            "actor": ["kind": "user", "id": "human"],
            "payload": ["text": "", "thread_id": "main", "attachments": attachments],
            "created_at": 1.0,
        ] as [String: Any])))
    }

    /// What the fake Hermes was asked.
    private final class AttachmentsHermes {
        var uploads: [(uploadID: String, kind: String, name: String, mime: String, data: Data)] = []
        var sentAttachments: [[GroupRoomAttachment]] = []
        var downloads: [(eventID: String, attachmentID: String)] = []
        var refuseUploads = false
        /// Files Hermes turns down by name.
        var refusedNames: Set<String> = []
        /// What the plugin's `/room-files` stored, by name.
        var pluginStored: [String] = []
        var downloadError: Error?
        /// The send's outcome is unknown: the message stays pending.
        var sendsFail = false
        var logEvents: [GroupEvent] = []
    }

    @MainActor
    private func attachmentsAppState(
        _ hermes: AttachmentsHermes, attachmentMethods: Bool = true, linked: Bool = false
    ) -> AppState {
        let suite = "GroupChatModelsTests.attachments.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let room = attachmentsRoom(linked: linked)
        var methods = GroupWire.requiredMethods
        if attachmentMethods {
            methods.formUnion(["groups.attachment.upload", "groups.attachment.download"])
        }
        var operations = GroupChatLifecycleOperations(
            capabilities: { _ in
                GroupCapabilities(protocolVersion: 2, driverReady: true, authorityGatewayID: "gw-a", features: [],
                                  methods: methods, maxLogLimit: 500)
            },
            list: { _ in ([room], nil) },
            state: { _, _ in (room, nil) },
            log: { _, _, sinceSeq, _ in
                let events = hermes.logEvents.filter { $0.seq > sinceSeq }
                return GroupLogPage(events: events, cursor: events.last?.seq ?? sinceSeq,
                                    latestSeq: hermes.logEvents.last?.seq ?? 0, hasMore: false,
                                    authorityGatewayID: "gw-a", authorityEpoch: 1)
            },
            send: { _, roomID, eventID, _, _ in
                if hermes.sendsFail { throw URLError(.networkConnectionLost) }
                guard let event = GroupDecoders.event(AnyCodable.from([
                    "room_id": roomID,
                    "seq": 1,
                    // Hermes files a user message under its client id's digest.
                    "event_id": GroupRoomOutbox.serverEventID(forClientEventID: eventID),
                    "kind": "message.user",
                    "actor": ["kind": "user", "id": "human"],
                    "payload": ["text": "", "thread_id": "main"],
                    "created_at": 1.0,
                ] as [String: Any])) else {
                    XCTFail("the fake send's event didn't decode")
                    throw RpcError(code: -1, message: "fixture")
                }
                return GroupSendResult(event: event, accepted: true, driverStarted: false)
            }
        )
        operations.roomRoute = { path, _, body, _ in
            guard path == GroupRoomFilesClient.path else { return ["ok": false] }
            let name = body?["name"] as? String ?? ""
            hermes.pluginStored.append(name)
            return ["ok": true, "path": "/h/conduit/room-files/u\(hermes.pluginStored.count)/\(name)"]
        }
        operations.sendAttachments = { hermes.sentAttachments.append($0) }
        operations.uploadAttachment = { _, _, uploadID, kind, name, mime, base64 in
            if hermes.refuseUploads || hermes.refusedNames.contains(name) {
                throw RpcError(code: 4002, message: "attachment refused")
            }
            hermes.uploads.append((uploadID, kind, name, mime, Data(base64Encoded: base64) ?? Data()))
            return GroupRoomAttachment(attachmentID: "att-\(hermes.uploads.count)", kind: kind, name: name,
                                       size: Data(base64Encoded: base64)?.count ?? 0, mime: mime)
        }
        operations.downloadAttachment = { _, _, eventID, attachmentID in
            hermes.downloads.append((eventID, attachmentID))
            if let error = hermes.downloadError { throw error }
            return "data:image/png;base64,\(Self.pngBytes.base64EncodedString())"
        }
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: .live,
            groupChatOperations: operations,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://groups.example", ticket: "groups-test"),
            profile: "default"
        )
        appState.isConnected = true
        _ = appState.adoptDashboard(forNormalizedURL: "https://groups.example")
        return appState
    }

    @MainActor
    private func attachmentsWait(
        _ what: String, until condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(what)", file: file, line: line)
    }

    func testRoomAttachmentsDecodeFromUserMessagesOnly() throws {
        let line: [String: Any] = ["attachment_id": "a1", "kind": "image", "name": "cat.png", "size": 12, "mime": "image/png"]
        let event = try attachmentsUserEvent(seq: 3, attachments: [line, ["kind": "image"]])
        XCTAssertEqual(event.attachments, [GroupRoomAttachment(attachmentID: "a1", kind: "image", name: "cat.png", size: 12, mime: "image/png")],
                       "a line without an id is dropped")
        let reply = try XCTUnwrap(GroupDecoders.event(AnyCodable.from([
            "room_id": "room-1", "seq": 4, "event_id": "m4", "kind": "message.member",
            "actor": ["kind": "member", "id": "researcher"],
            "payload": ["text": "hi", "attachments": [line]], "created_at": 1.0,
        ] as [String: Any])))
        XCTAssertTrue(reply.attachments.isEmpty)
    }

    func testRoomAttachmentPathsRoundTripAndManifestCarriesHermesFields() {
        let attachment = GroupRoomAttachment(attachmentID: "a1", kind: "pdf", name: "notes/plan.pdf", size: 9, mime: "application/pdf")
        let path = attachment.path(roomID: "room-1")
        XCTAssertEqual(path, "/conduit-room-attachments/room-1/a1/notes/plan.pdf")
        let parsed = GroupRoomAttachment.parse(path: path)
        XCTAssertEqual(parsed?.roomID, "room-1")
        XCTAssertEqual(parsed?.attachmentID, "a1")
        XCTAssertNil(GroupRoomAttachment.parse(path: "/h/conduit/room-files/a/plan.pdf"))
        XCTAssertNil(GroupRoomAttachment.parse(path: "/conduit-room-attachments/room-1//plan.pdf"))
        XCTAssertEqual(Set(attachment.manifest.keys), ["attachment_id", "kind", "name", "size", "mime"])
        XCTAssertEqual(attachment.attachment(roomID: "room-1").kind, .document)
        XCTAssertTrue(GroupRoomFilesClient.isStoredFile(attachment.attachment(roomID: "room-1")))
    }

    func testHermesUploadsTypePicturesAndPDFsByTheirBytes() throws {
        let png = try attachmentsStaged("cat.png", data: Self.pngBytes, mimeType: "image/png", kind: .image)
        XCTAssertEqual(GroupRoomHermesUpload(png)?.kind, "image")
        XCTAssertEqual(GroupRoomHermesUpload(png)?.mime, "image/png")
        // Named .jpg, bytes a PNG: Hermes checks the bytes against the type.
        let misnamed = try attachmentsStaged("cat.jpg", data: Self.pngBytes, mimeType: "image/jpeg", kind: .image)
        XCTAssertEqual(GroupRoomHermesUpload(misnamed)?.mime, "image/png")
        let pdf = try attachmentsStaged("plan.pdf", data: Data("%PDF-1.7\n".utf8), mimeType: "application/pdf", kind: .document)
        XCTAssertEqual(GroupRoomHermesUpload(pdf)?.kind, "pdf")
        let text = try attachmentsStaged("notes.md", data: Data("# Notes".utf8), mimeType: "text/markdown", kind: .document)
        XCTAssertEqual(GroupRoomHermesUpload(text)?.kind, "file")
        XCTAssertEqual(GroupRoomHermesUpload(text)?.mime, "text/plain")
        // A picture Hermes doesn't recognize goes to the plugin instead.
        let heic = try attachmentsStaged("cat.heic", data: Data("ftypheic....".utf8), mimeType: "image/heic", kind: .image)
        XCTAssertNil(GroupRoomHermesUpload(heic))
        let binaryText = try attachmentsStaged("x.txt", data: Data([0x41, 0, 0x42]), mimeType: "text/plain", kind: .document)
        XCTAssertNil(GroupRoomHermesUpload(binaryText))
    }

    func testHermesUploadIDsFollowTheStagedFileAndItsBytes() throws {
        let png = try attachmentsStaged("cat.png", data: Self.pngBytes, mimeType: "image/png", kind: .image)
        let upload = try XCTUnwrap(GroupRoomHermesUpload(png))
        XCTAssertEqual(upload.uploadID(stagedID: "ABC-1/x"), upload.uploadID(stagedID: "ABC-1/x"))
        XCTAssertNotEqual(upload.uploadID(stagedID: "ABC-1"), upload.uploadID(stagedID: "ABC-2"))
        XCTAssertTrue(upload.uploadID(stagedID: "ABC-1/x").hasPrefix("conduit-ABC-1x-"))
    }

    /// A retry of a send keeps its attachments, under the same event id.
    func testARoomSendRetryKeepsItsAttachments() {
        let picture = GroupRoomAttachment(attachmentID: "a1", kind: "image", name: "cat.png", size: 12, mime: "image/png")
        var outbox = GroupRoomOutbox()
        let first = outbox.beginSend(text: "", attachments: [picture]) { "conduit-1" }
        let retry = outbox.beginSend(text: "", attachments: []) { "conduit-2" }
        XCTAssertEqual(retry.eventID, first.eventID)
        XCTAssertEqual(retry.attachments, [picture])
    }

    /// A picture goes up as Hermes' attachment and its send names it; the
    /// typed text goes as typed, with no `@file:` line.
    @MainActor
    func testRoomPicturesSendAsHermesAttachments() async throws {
        let hermes = AttachmentsHermes()
        let appState = attachmentsAppState(hermes)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(attachmentsRoom())
        XCTAssertTrue(appState.roomTakesHermesAttachments)
        XCTAssertTrue(appState.canAttachRoomFiles, "Hermes takes files without the plugin")
        XCTAssertEqual(appState.roomFileCapMegabytes, GroupRoomFilesClient.hermesMaximumMegabytes)

        let png = try attachmentsStaged("cat.png", data: Self.pngBytes, mimeType: "image/png", kind: .image)
        let message = try await appState.roomMessage("look", attachments: [png])
        XCTAssertEqual(message.text, "look")
        XCTAssertEqual(hermes.uploads.map(\.kind), ["image"])
        XCTAssertEqual(hermes.uploads.first?.data, Self.pngBytes)
        XCTAssertEqual(message.attachments.map(\.attachmentID), ["att-1"])

        let sent = await appState.sendGroupRoomMessage(message.text, attachments: message.attachments)
        XCTAssertTrue(sent)
        XCTAssertEqual(hermes.sentAttachments, [message.attachments])
        appState.closeGroupRoom()
    }

    /// Files alone are a message: nothing typed still sends them.
    @MainActor
    func testRoomFilesAloneSend() async throws {
        let hermes = AttachmentsHermes()
        let appState = attachmentsAppState(hermes)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(attachmentsRoom())
        let pdf = try attachmentsStaged("plan.pdf", data: Data("%PDF-1.7\n".utf8), mimeType: "application/pdf", kind: .document)
        let message = try await appState.roomMessage("", attachments: [pdf])
        XCTAssertEqual(message.text, "")
        let sent = await appState.sendGroupRoomMessage(message.text, attachments: message.attachments)
        XCTAssertTrue(sent)
        XCTAssertEqual(hermes.sentAttachments.first?.map(\.kind), ["pdf"])
        let empty = await appState.sendGroupRoomMessage("   ")
        XCTAssertFalse(empty, "nothing typed and no files is no message")
        appState.closeGroupRoom()
    }

    /// Without the plugin, a file Hermes refuses fails the send rather than
    /// going without it.
    @MainActor
    func testARefusedUploadWithoutThePluginFailsTheMessage() async throws {
        let hermes = AttachmentsHermes()
        hermes.refuseUploads = true
        let appState = attachmentsAppState(hermes)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(attachmentsRoom())
        let png = try attachmentsStaged("cat.png", data: Self.pngBytes, mimeType: "image/png", kind: .image)
        do {
            _ = try await appState.roomMessage("look", attachments: [png])
            XCTFail("expected the refusal")
        } catch {
            XCTAssertTrue(error is RpcError, "\(error)")
        }
        appState.closeGroupRoom()
    }

    /// With the plugin, what Hermes won't take goes to its room files: a
    /// refused file, and a ninth past Hermes' eight a message.
    @MainActor
    func testWhatHermesWontTakeGoesToThePlugin() async throws {
        let hermes = AttachmentsHermes()
        hermes.refusedNames = ["odd.png"]
        let appState = attachmentsAppState(hermes)
        appState.applyNotifierPluginReport(["ok": true, "version": "0.143.0", "capabilities": [GroupRoomFilesClient.capability]])
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(attachmentsRoom())
        var files = [try attachmentsStaged("odd.png", data: Self.pngBytes, mimeType: "image/png", kind: .image)]
        for index in 1...9 {
            files.append(try attachmentsStaged("p\(index).png", data: Self.pngBytes, mimeType: "image/png", kind: .image))
        }

        let message = try await appState.roomMessage("look", attachments: files)

        XCTAssertEqual(message.attachments.map(\.name), (1...8).map { "p\($0).png" })
        XCTAssertEqual(hermes.pluginStored, ["odd.png", "p9.png"])
        XCTAssertEqual(message.text, "@file:/h/conduit/room-files/u1/odd.png\n@file:/h/conduit/room-files/u2/p9.png\n\nlook")
        appState.closeGroupRoom()
    }

    /// Past Hermes' 25 MB a message, the rest goes to the plugin; without
    /// the plugin the message fails rather than going without it.
    @MainActor
    func testWhatPassesHermesMessageTotalGoesToThePlugin() async throws {
        let big = Self.pngBytes + Data(count: 13_000_000)
        let first = try attachmentsStaged("a.png", data: big, mimeType: "image/png", kind: .image)
        let second = try attachmentsStaged("b.png", data: big, mimeType: "image/png", kind: .image)

        let hermes = AttachmentsHermes()
        let appState = attachmentsAppState(hermes)
        appState.applyNotifierPluginReport(["ok": true, "version": "0.143.0", "capabilities": [GroupRoomFilesClient.capability]])
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(attachmentsRoom())
        let message = try await appState.roomMessage("", attachments: [first, second])
        XCTAssertEqual(message.attachments.map(\.name), ["a.png"])
        XCTAssertEqual(hermes.pluginStored, ["b.png"])
        appState.closeGroupRoom()

        let alone = AttachmentsHermes()
        let withoutPlugin = attachmentsAppState(alone)
        await withoutPlugin.refreshGroupChatSupport()
        await withoutPlugin.openGroupRoom(attachmentsRoom())
        do {
            _ = try await withoutPlugin.roomMessage("", attachments: [first, second])
            XCTFail("expected the message to fail")
        } catch {
            XCTAssertTrue(error is GroupRoomFilesClient.Failure, "\(error)")
        }
        withoutPlugin.closeGroupRoom()
    }

    /// A room reads only what its host takes: Hermes' attachments where it
    /// downloads them, the plugin's pictures and other files by its own
    /// capabilities. An older plugin's file stays a name.
    @MainActor
    func testARoomReadsOnlyTheFilesItsHostTakes() async {
        let appState = attachmentsAppState(AttachmentsHermes())
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(attachmentsRoom())
        let hermesPicture = GroupRoomAttachment(attachmentID: "a1", kind: "image", name: "cat.png", size: 12, mime: "image/png")
            .attachment(roomID: "room-1")
        let pluginPicture = Attachment(id: "p", name: "dog.png", uri: "/h/conduit/room-files/u1/dog.png", mimeType: "image/png", kind: .image)
        let pluginFile = Attachment(id: "f", name: "plan.pdf", uri: "/h/conduit/room-files/u2/plan.pdf", mimeType: "application/pdf", kind: .document)

        let hermesOnly = appState.roomFilePicturesResolver
        XCTAssertEqual(hermesOnly?.roomFileReads.reads(hermesPicture), true)
        XCTAssertEqual(hermesOnly?.roomFileReads.reads(pluginPicture), false)
        XCTAssertEqual(hermesOnly?.roomFileReads.reads(pluginFile), false)

        appState.applyNotifierPluginReport(["ok": true, "version": "0.142.0", "capabilities": [
            GroupRoomFilesClient.capability, GroupRoomFilesClient.pictureCapability,
        ]])
        let withPictures = appState.roomFilePicturesResolver
        XCTAssertFalse(withPictures === hermesOnly, "what it reads changed, so the rows draw again")
        XCTAssertEqual(withPictures?.roomFileReads.reads(pluginPicture), true)
        XCTAssertEqual(withPictures?.roomFileReads.reads(pluginFile), false)
        XCTAssertTrue(appState.roomFileReadsResolver === withPictures)
        appState.closeGroupRoom()
    }

    /// A file in a message still sending reads by the event Hermes files
    /// that message under, not its client id.
    @MainActor
    func testAStillSendingMessagesFileReadsByItsServerEvent() async throws {
        let hermes = AttachmentsHermes()
        hermes.sendsFail = true
        let appState = attachmentsAppState(hermes)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(attachmentsRoom())
        let pdf = GroupRoomAttachment(attachmentID: "a1", kind: "pdf", name: "plan.pdf", size: 9, mime: "application/pdf")
        _ = await appState.sendGroupRoomMessage("", attachments: [pdf])
        let pending = try XCTUnwrap(appState.pendingRoomMessage, "an unknown outcome keeps the message pending")

        let read = await appState.roomFileRead(for: pdf.path(roomID: "room-1"))
        XCTAssertNotEqual(read, .gone)
        XCTAssertEqual(hermes.downloads.first?.eventID, GroupRoomOutbox.serverEventID(forClientEventID: pending.eventID))
        XCTAssertEqual(hermes.downloads.first?.attachmentID, "a1")
        appState.closeGroupRoom()
    }

    /// A linked room's files go through the plugin as `@file:` lines: Hermes'
    /// peer route carries no attachments and fails a guest agent's turn on
    /// a message that has them.
    @MainActor
    func testALinkedRoomSendsFilesThroughThePlugin() async throws {
        let hermes = AttachmentsHermes()
        let appState = attachmentsAppState(hermes, linked: true)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(attachmentsRoom(linked: true))
        XCTAssertFalse(appState.roomTakesHermesAttachments)
        XCTAssertFalse(appState.canAttachRoomFiles, "no plugin, no way to carry the files")

        appState.applyNotifierPluginReport(["ok": true, "version": "0.143.0", "capabilities": [GroupRoomFilesClient.capability]])
        XCTAssertTrue(appState.canAttachRoomFiles)
        let png = try attachmentsStaged("cat.png", data: Self.pngBytes, mimeType: "image/png", kind: .image)
        let message = try await appState.roomMessage("look", attachments: [png])
        XCTAssertTrue(hermes.uploads.isEmpty)
        XCTAssertTrue(message.attachments.isEmpty)
        XCTAssertEqual(message.text, "@file:/h/conduit/room-files/u1/cat.png\n\nlook")
        appState.closeGroupRoom()
    }

    /// A Hermes before room attachments: the composer takes no files
    /// without the plugin.
    @MainActor
    func testAnOlderHermesTakesNoRoomFilesWithoutThePlugin() async {
        let appState = attachmentsAppState(AttachmentsHermes(), attachmentMethods: false)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(attachmentsRoom())
        XCTAssertFalse(appState.roomTakesHermesAttachments)
        XCTAssertFalse(appState.canAttachRoomFiles)
        XCTAssertNil(appState.roomFilePicturesResolver)
        appState.closeGroupRoom()
    }

    /// A message's attachment is read by the message carrying it; Hermes
    /// refusing it is `gone`, not a retryable failure.
    @MainActor
    func testRoomAttachmentsReadByTheirMessage() async throws {
        let hermes = AttachmentsHermes()
        hermes.logEvents = try [attachmentsUserEvent(seq: 1, attachments: [
            ["attachment_id": "a1", "kind": "image", "name": "cat.png", "size": 12, "mime": "image/png"],
        ])]
        let appState = attachmentsAppState(hermes)
        await appState.refreshGroupChatSupport()
        await appState.openGroupRoom(attachmentsRoom())
        await attachmentsWait("the log", until: { !appState.activeRoomReplay.events.isEmpty })
        let resolver = appState.roomFilePicturesResolver
        XCTAssertNotNil(resolver, "Hermes reads its own attachments without the plugin")

        let path = GroupRoomAttachment(attachmentID: "a1", kind: "image", name: "cat.png", size: 12, mime: "image/png")
            .path(roomID: "room-1")
        let read = await appState.roomFileRead(for: path)
        XCTAssertEqual(read, .dataURL("data:image/png;base64,\(Self.pngBytes.base64EncodedString())"))
        XCTAssertEqual(hermes.downloads.map(\.eventID), ["srv-1"])
        XCTAssertEqual(hermes.downloads.map(\.attachmentID), ["a1"])

        hermes.downloadError = RpcError(code: 4004, message: "attachment expired")
        let gone = await appState.roomFileRead(for: path)
        XCTAssertEqual(gone, .gone)
        let unknown = await appState.roomFileRead(
            for: GroupRoomAttachment(attachmentID: "zz", kind: "image", name: "x.png", size: 1, mime: "image/png").path(roomID: "room-1")
        )
        XCTAssertEqual(unknown, .failed, "no message carries it yet")
        // A plugin file without the plugin: nothing can read it.
        let pluginFile = await appState.roomFileRead(for: "/h/conduit/room-files/a/cat.png")
        XCTAssertEqual(pluginFile, .gone)
        appState.closeGroupRoom()
    }
}
