import XCTest
@testable import Conduit

/// Chat pictures without their inline copies (#652): the transcript reads
/// Hermes' `[image]` stand-ins, each picture keeps a way back to the copy
/// stored inside its message, and loaded pictures are kept on the phone.
/// An extension so the test planner gains no new class.
extension MessageNormalizerTests {
    private var imageScope: TranscriptImageScope {
        TranscriptImageScope(sessionId: "stored-a", profile: "work")
    }

    func testPersistedPromptPairsItsPictureFileWithTheCopyInsideTheMessage() throws {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(41),
                "role": .string("user"),
                "content": .string("Look at this\n@image:/root/.hermes/images/upload_ab12.png\n[image]")
            ])
        ], imageScope: imageScope)

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].content, "Look at this")
        XCTAssertEqual(messages[0].rawContent, "Look at this\n@image:/root/.hermes/images/upload_ab12.png")
        XCTAssertEqual(messages[0].attachments?.count, 1)
        let attachment = try XCTUnwrap(messages[0].attachments?.first)
        XCTAssertEqual(attachment.uri, "/root/.hermes/images/upload_ab12.png")
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(
            attachment.inlineImage,
            InlineImageRef(sessionId: "stored-a", profile: "work", rowId: 41, index: 0)
        )
    }

    /// An older Hermes ignores `inline_images=false` and sends the picture
    /// itself. A picture that came in through a chat platform is named by
    /// the gateway's hint, under the caption the gateway writes for a
    /// picture sent without one.
    func testPictureSentInsideTheMessageNeverShowsAsText() throws {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(7),
                "role": .string("user"),
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("What do you see in this image?\n\n[Image attached at: /root/.hermes/cache/images/img_9f.jpg]")
                    ]),
                    .object([
                        "type": .string("image_url"),
                        "image_url": .object(["url": .string("data:image/jpeg;base64,/9j/4AAQSkZJRg==")])
                    ])
                ])
            ])
        ], imageScope: imageScope)

        XCTAssertEqual(messages[0].content, "")
        XCTAssertFalse(messages[0].rawContent?.contains("base64") ?? false)
        let attachment = try XCTUnwrap(messages[0].attachments?.first)
        XCTAssertEqual(messages[0].attachments?.count, 1)
        XCTAssertEqual(attachment.uri, "/root/.hermes/cache/images/img_9f.jpg")
        XCTAssertEqual(attachment.name, "img_9f.jpg")
        XCTAssertEqual(attachment.mimeType, "image/jpeg")
        XCTAssertEqual(attachment.inlineImage?.index, 0)
        XCTAssertEqual(attachment.inlineImage?.rowId, 7)
    }

    func testPromptWithAFileKeepsPictureStandInsOutOfItsRawText() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(14),
                "role": .string("user"),
                "content": .string("@file:/root/.hermes/attachments/report.pdf\n\nCompare these\n@image:/root/.hermes/images/a.png\n[image]")
            ])
        ], imageScope: imageScope)

        XCTAssertEqual(messages[0].content, "Compare these")
        // Branching replays the raw text as the new prompt.
        XCTAssertEqual(
            messages[0].rawContent,
            "@file:/root/.hermes/attachments/report.pdf\n\nCompare these\n@image:/root/.hermes/images/a.png"
        )
        XCTAssertEqual(messages[0].attachments?.map(\.uri), [
            "/root/.hermes/attachments/report.pdf",
            "/root/.hermes/images/a.png"
        ])
        XCTAssertEqual(messages[0].attachments?.last?.inlineImage?.rowId, 14)
    }

    /// #887: Hermes before d0f5ef7041 saved the description its vision
    /// wrote for a picture as the user's own words. The bubble shows the
    /// typed text and the picture, which carries the description.
    func testOldVisionDescriptionBecomesThePicturesDescription() throws {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(21),
                "role": .string("user"),
                "content": .string("[The user attached an image:\nA receipt from a café, total 12.40 [EUR].]\n[You can examine it with vision_analyze using image_url: /opt/data/images/upload_7c.jpg]\n\nHow much did I pay?")
            ])
        ], imageScope: imageScope)

        XCTAssertEqual(messages[0].content, "How much did I pay?")
        let attachment = try XCTUnwrap(messages[0].attachments?.first)
        XCTAssertEqual(messages[0].attachments?.count, 1)
        XCTAssertEqual(attachment.uri, "/opt/data/images/upload_7c.jpg")
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.imageDescription, "A receipt from a café, total 12.40 [EUR].")
    }

    func testOldVisionDescriptionsOfEveryWordingLeaveTheBubble() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(22),
                "role": .string("user"),
                "content": .string([
                    "[The user attached an image but analysis failed.]\n[You can examine it with vision_analyze using image_url: /opt/data/images/a.png]",
                    "[The user sent an image~ Here's what I can see:\nA cat on a sofa.]\n[If you need a closer look, use vision_analyze with image_url: /root/.hermes/cache/images/b.jpg ~]",
                    "[The user sent an image but I couldn't quite see it this time (>_<) You can try looking at it yourself with vision_analyze using image_url: /root/.hermes/cache/images/c.jpg]",
                    "Which is best?",
                ].joined(separator: "\n\n"))
            ])
        ], imageScope: imageScope)

        XCTAssertEqual(messages[0].content, "Which is best?")
        XCTAssertEqual(messages[0].attachments?.map(\.uri), [
            "/opt/data/images/a.png",
            "/root/.hermes/cache/images/b.jpg",
            "/root/.hermes/cache/images/c.jpg",
        ])
        XCTAssertEqual(messages[0].attachments?.map(\.imageDescription), [nil, "A cat on a sofa.", nil])
    }

    /// Text that only mentions the wording is the user's own.
    func testTypedTextAboutVisionStays() {
        let text = "Why did you write [The user attached an image: a cat] earlier?"
        XCTAssertEqual(MessageNormalizer.visibleUserText(text), text)
    }

    func testCaptionedPlatformPictureKeepsItsCaption() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(8),
                "role": .string("user"),
                "content": .string("Is this mould?\n\n[Image attached at: /root/.hermes/cache/images/img_1.jpg]\n[image]")
            ])
        ], imageScope: imageScope)

        XCTAssertEqual(messages[0].content, "Is this mould?")
        XCTAssertEqual(messages[0].attachments?.map(\.uri), ["/root/.hermes/cache/images/img_1.jpg"])
    }

    func testPictureNamingNoFileBecomesItsOwnAttachment() throws {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(9),
                "role": .string("user"),
                "content": .string("From the API\n[image]\n[image]")
            ])
        ], imageScope: imageScope)

        XCTAssertEqual(messages[0].content, "From the API")
        XCTAssertEqual(messages[0].attachments?.count, 2)
        XCTAssertEqual(messages[0].attachments?.map(\.uri), ["", ""])
        XCTAssertEqual(messages[0].attachments?.map(\.kind), [Attachment.Kind.image, .image])
        XCTAssertEqual(messages[0].attachments?.compactMap(\.inlineImage?.index), [0, 1])
        let ids = try XCTUnwrap(messages[0].attachments).map(\.id)
        XCTAssertEqual(Set(ids).count, 2)
    }

    func testTwoPicturesPairWithTheirCopiesInOrder() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(10),
                "role": .string("user"),
                "content": .string("@image:/root/.hermes/images/a.png\n@image:/root/.hermes/images/b.png\n[image]\n[image]")
            ])
        ], imageScope: imageScope)

        XCTAssertEqual(messages[0].attachments?.map(\.uri), [
            "/root/.hermes/images/a.png",
            "/root/.hermes/images/b.png"
        ])
        XCTAssertEqual(messages[0].attachments?.compactMap(\.inlineImage?.index), [0, 1])
    }

    func testTypedImageStandInStaysInTheText() {
        let typed = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(11),
                "role": .string("user"),
                "content": .string("Write [image] here\nand there")
            ])
        ], imageScope: imageScope)

        XCTAssertEqual(typed[0].content, "Write [image] here\nand there")
        XCTAssertNil(typed[0].attachments)
        // Only a persisted row carries Hermes' stand-ins.
        XCTAssertEqual(MessageNormalizer.visibleUserText("hello\n[image]"), "hello\n[image]")
    }

    func testRowsWithoutAScopeShowThePictureWithoutAWayBack() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(12),
                "role": .string("user"),
                "content": .string("hi\n[image]")
            ])
        ])

        XCTAssertEqual(messages[0].content, "hi")
        XCTAssertEqual(messages[0].attachments?.count, 1)
        XCTAssertNil(messages[0].attachments?.first?.inlineImage)
    }

    func testAssistantPictureShowsTheStandInNotItsBytes() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(13),
                "role": .string("assistant"),
                "content": .array([
                    .object(["type": .string("text"), "text": .string("Here it is")]),
                    .object([
                        "type": .string("image_url"),
                        "image_url": .object(["url": .string("data:image/png;base64,iVBORw0KGgo=")])
                    ])
                ])
            ])
        ])

        XCTAssertEqual(messages[0].content, "Here it is\n[image]")
    }

    func testInlinePicturesAreReadFromTheRequestedRowInOrder() {
        let rows: [Any] = [
            [
                "id": 40,
                "role": "user",
                "content": [["type": "image_url", "image_url": ["url": "data:image/png;base64,AAAA"]]]
            ],
            [
                "id": 41,
                "role": "user",
                "content": [
                    ["type": "text", "text": "two pictures and a link"],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,BBBB"]],
                    ["type": "image_url", "image_url": ["url": "https://example.com/c.png"]],
                    ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "CCCC"]]
                ]
            ]
        ]

        XCTAssertEqual(
            MessageNormalizer.inlineImageDataURLs(inRows: rows, rowId: 41),
            ["data:image/jpeg;base64,BBBB", nil, "data:image/png;base64,CCCC"]
        )
        XCTAssertEqual(MessageNormalizer.inlineImageDataURLs(inRows: rows, rowId: 99), [])
    }

    func testInlinePictureIsReadThroughTheTimelineRoute() {
        XCTAssertEqual(
            AppState.inlineImageRowPath(InlineImageRef(sessionId: "stored a", profile: "work", rowId: 41, index: 1)),
            "/api/sessions/stored%20a/messages/around?row_id=41&limit=1&profile=work"
        )
        XCTAssertEqual(
            AppState.inlineImageRowPath(InlineImageRef(sessionId: "stored-a", profile: "default", rowId: 7, index: 0)),
            "/api/sessions/stored-a/messages/around?row_id=7&limit=1"
        )
    }

    func testTranscriptPageNamesTheStoredSessionItsPicturesLiveIn() {
        XCTAssertEqual(
            AppState.transcriptImageScope(in: ["session_id": "stored-a"], sessionId: "runtime-a", profile: "work"),
            TranscriptImageScope(sessionId: "stored-a", profile: "work")
        )
        XCTAssertEqual(
            AppState.transcriptImageScope(in: [:], sessionId: "runtime-a", profile: "work"),
            TranscriptImageScope(sessionId: "runtime-a", profile: "work")
        )
    }

    func testLoadedPictureIsKeptOnThePhone() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptImageCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { TranscriptImageCache.removeAll(in: directory) }
        let key = TranscriptImageCache.key(
            dashboard: "d1",
            inlineImage: InlineImageRef(sessionId: "s", profile: "default", rowId: 41, index: 0)
        )

        XCTAssertNil(TranscriptImageCache.cachedFile(for: key, in: directory))
        let stored = try XCTUnwrap(TranscriptImageCache.store(
            dataURL: "data:image/png;base64,iVBORw0KGgo=",
            for: key,
            in: directory
        ))
        XCTAssertEqual(stored.pathExtension, "png")
        XCTAssertEqual(TranscriptImageCache.cachedFile(for: key, in: directory), stored)
        XCTAssertEqual(try Data(contentsOf: stored), Data(base64Encoded: "iVBORw0KGgo="))
        XCTAssertNil(TranscriptImageCache.store(dataURL: "data:text/plain;base64,aGk=", for: key, in: directory))

        // Kept again under another type, the newer copy is the one found.
        let jpeg = try XCTUnwrap(TranscriptImageCache.store(
            dataURL: "data:image/jpeg;base64,/9j/4AAQSkZJRg==",
            for: key,
            in: directory
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
        XCTAssertEqual(TranscriptImageCache.store(dataURL: "data:image/png;base64,iVBORw0KGgo=", for: key, in: directory), stored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: jpeg.path))
        XCTAssertEqual(TranscriptImageCache.cachedFile(for: key, in: directory), stored)

        // Another server's same-named file is kept apart.
        XCTAssertNotEqual(
            TranscriptImageCache.key(dashboard: "d1", profile: "default", path: "/root/.hermes/images/a.png"),
            TranscriptImageCache.key(dashboard: "d2", profile: "default", path: "/root/.hermes/images/a.png")
        )
    }

    func testAPictureLoadedAcrossASignOutIsNotKept() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptImageCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { TranscriptImageCache.removeAll(in: directory) }
        let key = TranscriptImageCache.key(dashboard: "d1", profile: "default", path: "/root/.hermes/images/a.png")
        let png = "data:image/png;base64,iVBORw0KGgo="

        // The load started, then sign-out purged the cache before its write.
        let started = TranscriptImageCache.generation
        await TranscriptImageCache.purge(in: directory).value
        XCTAssertNil(TranscriptImageCache.store(dataURL: png, for: key, in: directory, generation: started))
        XCTAssertNil(TranscriptImageCache.cachedFile(for: key, in: directory))

        // A load that starts after it keeps its picture.
        let next = TranscriptImageCache.generation
        XCTAssertNotNil(TranscriptImageCache.store(dataURL: png, for: key, in: directory, generation: next))
        XCTAssertNotNil(TranscriptImageCache.cachedFile(for: key, in: directory))
    }

    func testPictureCacheDropsTheOldestPastItsBudget() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptImageCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { TranscriptImageCache.removeAll(in: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = directory.appendingPathComponent("old.png")
        let new = directory.appendingPathComponent("new.png")
        try Data(count: 600).write(to: old)
        try Data(count: 600).write(to: new)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)

        TranscriptImageCache.trim(directory, budget: 1000, target: 700)

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.path))
    }
}
