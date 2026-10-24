import XCTest
@testable import Conduit

/// The Artifacts screens' list (Artifacts.swift), read from the host's
/// notifier plugin. An extension, so no new class to plan.
@MainActor
extension GatewayRestartTests {
    private func artifactRow(_ fields: [String: Any]) -> [String: Any] {
        var row: [String: Any] = [
            "kind": "image", "source": "delivered", "name": "map.png", "path": "/root/out/map.png",
            "exists": true, "size": 2048, "session_id": "s1", "session_title": "Weekend trip",
            "message_id": 12, "timestamp": 1_760_000_000.0,
        ]
        row.merge(fields) { _, new in new }
        return row
    }

    func testArtifactsAskForOneChatByEachOfItsIDs() async throws {
        var asked: [String] = []
        let client = ArtifactsClient { path in
            asked.append(path)
            return ["ok": true, "items": [], "next_before": NSNull()]
        }
        _ = try await client.page(profile: "work", sessionIDs: ["tip", "root"], filter: .images,
                                  query: " road trip ", before: 40)
        XCTAssertEqual(
            asked,
            ["/api/plugins/conduit_push/artifacts?limit=60&session_id=root&session_id=tip&kind=images"
                + "&q=road%20trip&before=40&profile=work"]
        )
        _ = try await client.page(profile: "default")
        XCTAssertEqual(asked.last, "/api/plugins/conduit_push/artifacts?limit=60")
    }

    func testArtifactsHideMissingFilesUnlessAsked() async throws {
        var asked: [String] = []
        let rows = [
            artifactRow([:]),
            artifactRow(["exists": false, "path": "/root/gone.pdf", "kind": "document", "name": "gone.pdf"]),
            artifactRow(["kind": "link", "source": "link", "path": NSNull(), "url": "https://curate.example/r",
                         "name": "Curate", "exists": false]),
        ]
        // An older plugin lists missing files whatever it was asked.
        let client = ArtifactsClient { path in
            asked.append(path)
            return ["ok": true, "items": rows, "next_before": 5]
        }
        let hidden = try await client.page(profile: "default", showMissing: false)
        XCTAssertEqual(asked.last, "/api/plugins/conduit_push/artifacts?limit=60&missing=hide")
        XCTAssertEqual(hidden.items.map(\.name), ["map.png", "Curate"], "a link has no file to miss")
        XCTAssertEqual(hidden.nextBefore, 5, "a page the filter emptied still pages on")
        XCTAssertTrue(hidden.items[1].exists, "a link is never shown as missing")
        let emptied = try ArtifactsClient.parse(["ok": true, "items": [rows[1]], "next_before": 3], showMissing: false)
        XCTAssertTrue(emptied.items.isEmpty)
        XCTAssertEqual(emptied.nextBefore, 3, "a page the filter emptied still pages on")
        let shown = try await client.page(profile: "default", showMissing: true)
        XCTAssertEqual(asked.last, "/api/plugins/conduit_push/artifacts?limit=60")
        XCTAssertEqual(shown.items.map(\.name), ["map.png", "gone.pdf", "Curate"])

        let key = ArtifactsListKey(dashboard: nil, profile: "default", filter: .all, query: "", showMissing: false)
        let showing = ArtifactsListKey(dashboard: nil, profile: "default", filter: .all, query: "", showMissing: true)
        XCTAssertNotEqual(key, showing, "the toggle reads the list again")
        XCTAssertTrue(showing.showsRows(of: key))
        XCTAssertTrue(ArtifactsListKey(dashboard: nil, profile: "default", filter: .all, query: "").showMissing,
                      "a key without the setting lists everything, as the host does")
    }

    func testArtifactListsBelongToTheirDashboard() {
        let first = UUID()
        let second = UUID()
        let onFirst = ArtifactsListKey(dashboard: first, profile: "default", filter: .all, query: "")
        let onSecond = ArtifactsListKey(dashboard: second, profile: "default", filter: .all, query: "")
        let imagesOnFirst = ArtifactsListKey(dashboard: first, profile: "default", filter: .images, query: "")

        // Every server has a "default" profile: switching servers reads the list again...
        XCTAssertNotEqual(onFirst, onSecond)
        // ...and doesn't leave the other server's rows up while it does.
        XCTAssertFalse(onSecond.showsRows(of: onFirst))
        XCTAssertTrue(imagesOnFirst.showsRows(of: onFirst), "another filter keeps the rows up, dimmed")

        XCTAssertNotEqual(
            ArtifactsListKey.thumbnailCacheKey(dashboard: first, profile: "default", path: "/root/out/map.png"),
            ArtifactsListKey.thumbnailCacheKey(dashboard: second, profile: "default", path: "/root/out/map.png")
        )
        XCTAssertNotEqual(
            ArtifactsListKey.thumbnailCacheKey(dashboard: first, profile: "default", path: "/root/out/map.png"),
            ArtifactsListKey.thumbnailCacheKey(dashboard: first, profile: "work", path: "/root/out/map.png")
        )
        XCTAssertEqual(
            ArtifactsListKey.thumbnailCacheKey(dashboard: first, profile: "default", path: "/root/out/map.png"),
            ArtifactsListKey.thumbnailCacheKey(dashboard: first, profile: "default", path: "/root/out/map.png")
        )
    }

    func testArtifactsParseFilesAndLinksAndSkipBrokenRows() throws {
        let page = try ArtifactsClient.parse([
            "ok": true,
            "items": [
                artifactRow([:]),
                artifactRow(["kind": "link", "source": "link", "path": NSNull(), "url": "https://curate.example/r",
                              "host": "curate.example", "name": "Curate", "message_id": 11]),
                artifactRow(["kind": "link", "source": "link", "path": NSNull(), "url": "javascript:alert(1)"]),
                artifactRow(["kind": "sticker"]),
                artifactRow(["path": NSNull()]),
                artifactRow(["timestamp": NSNull(), "path": "/root/undated.png"]),
                artifactRow(["exists": false, "path": "/root/gone.pdf", "kind": "document", "name": "gone.pdf"]),
            ],
            "next_before": 9,
        ])
        XCTAssertEqual(page.nextBefore, 9)
        XCTAssertEqual(page.items.map(\.name), ["map.png", "Curate", "gone.pdf"])
        XCTAssertEqual(page.items[0].size, 2048)
        XCTAssertTrue(page.items[0].isVisual)
        XCTAssertEqual(page.items[1].url?.host(), "curate.example")
        XCTAssertNil(page.items[1].path)
        XCTAssertFalse(page.items[2].exists)
        XCTAssertThrowsError(try ArtifactsClient.parse(["ok": false]))
    }

    func testArtifactPagesMergeEachArtifactOnce() throws {
        let first = try ArtifactsClient.parse(["ok": true, "items": [artifactRow([:])]]).items
        let older = try ArtifactsClient.parse(["ok": true, "items": [
            artifactRow(["message_id": 3]),
            artifactRow(["path": "/root/older.png", "name": "older.png", "message_id": 2]),
        ]]).items
        let merged = ArtifactsClient.merged(first, with: older)
        XCTAssertEqual(merged.map(\.name), ["map.png", "older.png"])
        XCTAssertEqual(merged.first?.messageID, 12)
        let repeated = try ArtifactsClient.parse(["ok": true, "items": [artifactRow([:]), artifactRow(["message_id": 3])]])
        XCTAssertEqual(repeated.items.map(\.messageID), [12])
    }

    func testArtifactFiltersMatchTheHostsGroups() {
        XCTAssertTrue(ArtifactFilter.images.includes(.video))
        XCTAssertTrue(ArtifactFilter.files.includes(.audio))
        XCTAssertFalse(ArtifactFilter.files.includes(.page))
        XCTAssertNil(ArtifactFilter.all.hostKind)
        XCTAssertEqual(ArtifactFilter.links.hostKind, "links")
    }

    func testArtifactsGroupByDayNewestFirst() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let items = try ArtifactsClient.parse(["ok": true, "items": [
            artifactRow(["timestamp": 1_760_090_000.0, "path": "/a.png"]),
            artifactRow(["timestamp": 1_760_086_500.0, "path": "/b.png"]),
            artifactRow(["timestamp": 1_760_000_000.0, "path": "/c.png"]),
        ]]).items
        let days = ArtifactsClient.days(items, calendar: calendar)
        XCTAssertEqual(days.map { $0.items.map(\.id) }, [["/a.png", "/b.png"], ["/c.png"]])
    }

    func testShowInChatFindsTheMessageOrTheOneBeforeIt() {
        func row(_ id: String, _ rowId: Int?) -> ChatMessage {
            var message = ChatMessage(id: id, role: .assistant, content: "", timestamp: "")
            message.rowId = rowId
            return message
        }
        let messages = [row("u", 10), row("tool", nil), row("a", 14)]
        XCTAssertEqual(ArtifactReveal.rowID(for: 14, in: messages), "a")
        // A tool call split off message 12 shows the turn before it.
        XCTAssertEqual(ArtifactReveal.rowID(for: 12, in: messages), "u")
        XCTAssertNil(ArtifactReveal.rowID(for: 5, in: messages))
    }

    func testArtifactsPageMergesBotChatsNewestFirst() throws {
        func item(_ path: String, _ time: Double) -> ArtifactItem {
            ArtifactItem(artifactRow(["path": path, "timestamp": time]))!
        }
        let sources = [
            ArtifactSource(profile: "default", sessionIDs: []),
            ArtifactSource(profile: "atlas", sessionIDs: ["bot-chat"], label: "Atlas", isBotChat: true),
        ]
        var feed = ArtifactFeed(sources: sources, pages: [
            ArtifactPage(items: [item("/w1", 100), item("/w2", 80)], nextBefore: 7),
            ArtifactPage(items: [item("/b1", 90), item("/b2", 50), item("/w2", 40)], nextBefore: nil),
        ])
        // The workspace may still hold rows between 80 and 50, so the bot's
        // older rows wait for its next page.
        XCTAssertEqual(feed.items.map(\.id), ["/w1", "/b1", "/w2"])
        XCTAssertEqual(feed.items[1].otherProfile, "atlas")
        XCTAssertEqual(feed.items[1].otherProfileLabel, "Atlas")
        XCTAssertTrue(feed.items[1].isBotChat)
        XCTAssertNil(feed.items[0].otherProfile)
        XCTAssertEqual(feed.nextCursor, ArtifactFeed.Cursor(source: 0, before: 7))
        feed.append(ArtifactPage(items: [item("/w3", 60)], nextBefore: nil), at: ArtifactFeed.Cursor(source: 0, before: 7))
        XCTAssertNil(feed.nextCursor)
        XCTAssertEqual(feed.items.map(\.id), ["/w1", "/b1", "/w2", "/w3", "/b2"],
                       "a file both stores list shows once, at its newest mention")
        // A stale page doesn't land twice.
        let before = feed
        feed.append(ArtifactPage(items: [item("/w9", 10)], nextBefore: nil), at: ArtifactFeed.Cursor(source: 0, before: 7))
        XCTAssertEqual(feed, before)
    }

    func testArtifactsFeedReadsAnEmptyStoreBeforeShowingOlderRows() {
        let sources = [
            ArtifactSource(profile: "default", sessionIDs: []),
            ArtifactSource(profile: "atlas", sessionIDs: ["bot-chat"], label: "Atlas", isBotChat: true),
        ]
        let feed = ArtifactFeed(sources: sources, pages: [
            ArtifactPage(items: [], nextBefore: 30),
            ArtifactPage(items: [ArtifactItem(artifactRow(["path": "/b1"]))!], nextBefore: 9),
        ])
        XCTAssertTrue(feed.items.isEmpty, "a page the filter emptied may still hold newer rows")
        XCTAssertEqual(feed.nextCursor, ArtifactFeed.Cursor(source: 0, before: 30))
        // A store that couldn't be read adds nothing and pages no further.
        let partial = ArtifactFeed(sources: sources, pages: [
            ArtifactPage(items: [ArtifactItem(artifactRow(["path": "/w1"]))!], nextBefore: nil), nil,
        ])
        XCTAssertEqual(partial.items.map(\.id), ["/w1"])
        XCTAssertNil(partial.nextCursor)
    }

    func testArtifactsOneStoreKeepsTheHostsOrder() {
        let rows = ["/c", "/a", "/b"].map { ArtifactItem(artifactRow(["path": $0]))! }
        let feed = ArtifactFeed(sources: [ArtifactSource(profile: "default", sessionIDs: [])],
                                pages: [ArtifactPage(items: rows, nextBefore: 4)])
        XCTAssertEqual(feed.items.map(\.id), ["/c", "/a", "/b"])
        XCTAssertEqual(feed.nextCursor, ArtifactFeed.Cursor(source: 0, before: 4))
    }
}
