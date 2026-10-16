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
}
