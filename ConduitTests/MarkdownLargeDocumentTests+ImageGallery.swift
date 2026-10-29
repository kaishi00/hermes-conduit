import XCTest
@testable import Conduit

/// The picture viewer pages through the pictures around the one tapped and
/// closes on a swipe down. These cover the pure pieces: which pictures a
/// chat, a room or a reply lists, in what order, where the tapped one sits,
/// and when a drag closes the viewer.
///
/// An extension rather than its own class, as the media preview tests are:
/// the CI planner caps sequential batches per lane.
extension MarkdownLargeDocumentTests {

    @MainActor
    private func galleryAppState() throws -> AppState {
        let suiteName = "image-gallery-tests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return AppState(defaults: defaults, loadSavedConnection: false)
    }

    private func galleryMessage(_ id: String, _ role: MessageRole, _ content: String,
                                attachments: [Attachment]? = nil, tool: ToolActivity? = nil) -> ChatMessage {
        ChatMessage(id: id, role: role, content: content, timestamp: "", tool: tool, attachments: attachments)
    }

    @MainActor
    func testGalleryListsAChatsPicturesInOrder() throws {
        let appState = try galleryAppState()
        let resolver = GatewayMediaDataURLResolver(appState: appState, profile: "default")
        let photo = Attachment(id: "a1", name: "beach.jpg", uri: "/root/.hermes/images/beach.jpg", mimeType: "image/jpeg", kind: .image)
        let report = Attachment(id: "a2", name: "report.pdf", uri: "/root/report.pdf", mimeType: "application/pdf", kind: .document)
        let screenshot = ToolActivity(
            name: "browser_vision",
            output: #"{"screenshot_path": "/tmp/shot.png", "analysis": "A page"}"#,
            status: .complete
        )
        let messages = [
            galleryMessage("u1", .user, "Look at these\n\n![sky](https://example.com/sky.png)", attachments: [photo, report]),
            galleryMessage("a1", .assistant, "Here you go\n\nMEDIA:/root/out/chart.png\n\nMEDIA:/root/out/clip.mp4"),
            galleryMessage("t1", .tool, "", tool: screenshot),
            galleryMessage("r1", .reasoning, "![not drawn](https://example.com/thinking.png)"),
            // The same picture again shows once, where it first showed.
            galleryMessage("a2", .assistant, "Again:\n\nMEDIA:/root/out/chart.png"),
        ]

        let ids = ChatImageGallery.items(in: messages, resolver: resolver).map(\.id)

        XCTAssertEqual(ids, [
            ImageGalleryItem.webID("https://example.com/sky.png"),
            ImageGalleryItem.mediaID(path: "/root/.hermes/images/beach.jpg"),
            ImageGalleryItem.mediaID(path: "/root/out/chart.png"),
            ImageGalleryItem.mediaID(path: "/tmp/shot.png"),
        ], "text pictures, then attachments, then tool pictures; no video, document or thinking")
    }

    @MainActor
    func testGalleryWithoutAResolverListsOnlyWebPictures() {
        let messages = [galleryMessage("a1", .assistant, "MEDIA:/root/out/chart.png\n\n![](https://example.com/a.png)")]

        XCTAssertEqual(ChatImageGallery.items(in: messages, resolver: nil).map(\.id),
                       [ImageGalleryItem.webID("https://example.com/a.png")],
                       "a surface with no gateway resolver draws no MEDIA: pictures, so none page")
    }

    @MainActor
    func testGalleryPlacesTheTappedPictureAndFallsBackToItAlone() {
        let item = { (id: String) in ImageGalleryItem(id: id, title: id) { .unavailable } }
        let listed = [item("a"), item("b"), item("a"), item("c")]

        let placed = ImageGallery.placing(item("c"), in: listed)
        XCTAssertEqual(placed.items.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(placed.index, 2)

        let missing = ImageGallery.placing(item("z"), in: listed)
        XCTAssertEqual(missing.items.map(\.id), ["z"], "a picture its list doesn't have opens alone")
        XCTAssertEqual(missing.index, 0)
    }

    @MainActor
    func testRoomGalleryListsMessagePicturesOnly() {
        func event(_ seq: Int, _ kind: String, _ text: String) -> GroupEvent {
            GroupEvent(
                roomID: "room",
                seq: seq,
                eventID: "e\(seq)",
                kind: kind,
                actor: GroupActor(kind: "member", id: "atlas", profile: "atlas", displayName: "Atlas", connectionID: nil),
                authorityEpoch: nil,
                payload: ["text": .string(text)],
                createdAt: 0
            )
        }
        let events = [
            event(1, "message.user", "![one](https://example.com/1.png)"),
            event(2, "turn.started", "![skip](https://example.com/skip.png)"),
            event(3, "message.member", "Two\n\n![two](https://example.com/2.png)"),
        ]

        XCTAssertEqual(GroupRoomImageGallery.items(in: events).map(\.id), [
            ImageGalleryItem.webID("https://example.com/1.png"),
            ImageGalleryItem.webID("https://example.com/2.png"),
        ])
    }

    func testGalleryPrefilterKeepsEveryPictureSource() {
        XCTAssertTrue(ChatImageGallery.mayHoldPictures("![a](b.png)"))
        XCTAssertTrue(ChatImageGallery.mayHoldPictures("https://example.com/a.png"))
        XCTAssertTrue(ChatImageGallery.mayHoldPictures("media:/root/a.png"))
        XCTAssertTrue(ChatImageGallery.mayHoldPictures("::preview{file=\"/root/a.png\"}"))
        XCTAssertFalse(ChatImageGallery.mayHoldPictures("Just words, no pictures."))
        XCTAssertFalse(ChatImageGallery.mayHoldPictures("See https://example.com/docs for more."),
                       "a link to a page alone doesn't parse the message")
    }

    func testSwipeDownClosesPastAFifthOrWhenFlung() {
        XCTAssertFalse(ImageGallery.dragCloses(translation: 60, velocity: 100, height: 800), "a short drag springs back")
        XCTAssertTrue(ImageGallery.dragCloses(translation: 200, velocity: 100, height: 800), "past a fifth of the screen")
        XCTAssertTrue(ImageGallery.dragCloses(translation: 40, velocity: 1400, height: 800), "a fling")
        XCTAssertTrue(ImageGallery.dragCloses(translation: -220, velocity: -300, height: 800), "upwards too, as Photos")
        XCTAssertFalse(ImageGallery.dragCloses(translation: 200, velocity: -1400, height: 800), "flung back towards the middle")
        XCTAssertFalse(ImageGallery.dragCloses(translation: 8, velocity: 2000, height: 800), "a twitch is not a swipe")
    }

    func testAnimatedPicturesStayWithinTheirMemoryBudget() {
        let frames = 120
        let side = ImageGalleryDecoder.animatedMaxPixelSize(width: 1024, height: 768, frames: frames)
        let drawn = side * side * 768 / 1024 * 4 * CGFloat(frames)
        XCTAssertLessThanOrEqual(drawn, CGFloat(ImageGalleryDecoder.animatedMaxBytes))
        XCTAssertEqual(ImageGalleryDecoder.animatedMaxPixelSize(width: 200, height: 200, frames: 4), 200,
                       "a small GIF keeps its own size")
    }

    @MainActor
    func testViewerRemovesItsCopiesWhenItCloses() async throws {
        let first = try XCTUnwrap(MediaPreviewPresenter.stage(data: Data([1, 2, 3]), filename: "first.png"))
        let late = try XCTUnwrap(MediaPreviewPresenter.stage(data: Data([4]), filename: "late.png"))
        let (gate, _) = AsyncStream<Void>.makeStream()
        let items = [
            ImageGalleryItem(id: "first", title: "first.png") {
                .file(ImageGalleryFile(url: first.file, ownedDirectory: first.directory))
            },
            // Still arriving when the viewer closes: it ends with the close.
            ImageGalleryItem(id: "late", title: "late.png") {
                for await _ in gate {}
                return .file(ImageGalleryFile(url: late.file, ownedDirectory: late.directory))
            },
        ]
        let viewer = ImageGalleryViewController(items: items, startingAt: 0, placeholder: nil)
        viewer.loadViewIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.directory.path), "the shown picture's copy stays while open")

        viewer.finish()
        for _ in 0..<40 where FileManager.default.fileExists(atPath: late.directory.path) {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.directory.path), "closing removes what it fetched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.directory.path), "and a copy that lands after the close")
    }

    func testAFailedPictureIsFetchedAgainUnlessTooLarge() {
        XCTAssertTrue(ImageGallery.fetchesAgain(afterFailure: false), "a dropped connection tries again")
        XCTAssertFalse(ImageGallery.fetchesAgain(afterFailure: true), "too large stays too large")
        XCTAssertFalse(ImageGallery.fetchesAgain(afterFailure: nil), "nothing failed")
    }

    @MainActor
    func testTheTappedPictureKeepsItsOwnFetch() async {
        let listed = [ImageGalleryItem(id: "a", title: "listed") { .unavailable }]
        let tapped = ImageGalleryItem(id: "a", title: "tapped") { .tooLarge }
        let placed = ImageGallery.placing(tapped, in: listed)
        XCTAssertEqual(placed.items.first?.title, "tapped")
        guard case .tooLarge = await placed.items[0].load() else {
            return XCTFail("the row's own fetch runs")
        }
    }

    func testViewerFetchesThePageThenItsNeighbours() {
        XCTAssertEqual(ImageGallery.prefetchOrder(around: 0, count: 3), [0, 1])
        XCTAssertEqual(ImageGallery.prefetchOrder(around: 1, count: 3), [1, 2, 0])
        XCTAssertEqual(ImageGallery.prefetchOrder(around: 2, count: 3), [2, 1])
        XCTAssertEqual(ImageGallery.prefetchOrder(around: 0, count: 1), [0])
    }
}
