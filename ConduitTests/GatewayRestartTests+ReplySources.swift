import XCTest
@testable import Conduit

/// Which sources' replies notify (ReplySourceNotifications.swift), kept by
/// the host's notifier plugin. An extension, so no new class to plan.
@MainActor
extension GatewayRestartTests {
    func testReplySourcesReadEverySource() async throws {
        var asked: [(String, String, [String: Any]?)] = []
        let client = ReplySourcesClient { path, method, body in
            asked.append((path, method, body))
            return ["ok": true, "sources": ["conduit": true, "desktop": false, "messaging": false, "later": false]]
        }
        let settings = try await client.settings(profile: "work")
        XCTAssertEqual(settings, [.conduit: true, .desktop: false, .messaging: false, .terminal: true])
        XCTAssertEqual(asked.first?.0, "/api/plugins/conduit_push/notifications/reply-sources?profile=work")
        XCTAssertEqual(asked.first?.1, "GET")
    }

    func testReplySourcesSendTheSourceAndChoice() async throws {
        var sent: [String: Any]?
        var path: String?
        let client = ReplySourcesClient { requestPath, method, body in
            XCTAssertEqual(method, "PUT")
            path = requestPath
            sent = body
            return ["ok": true, "sources": ["conduit": true, "desktop": false, "messaging": true, "terminal": true]]
        }
        let settings = try await client.setNotify(false, source: .desktop, profile: "default")
        XCTAssertEqual(settings[.desktop], false)
        XCTAssertEqual(sent?["source"] as? String, "desktop")
        XCTAssertEqual(sent?["notify"] as? Bool, false)
        // The default profile uses the bare path.
        XCTAssertEqual(path, ReplySourcesClient.path)
    }

    func testAMalformedReplySourcesAnswerThrows() {
        XCTAssertThrowsError(try ReplySourcesClient.parse(["ok": true]))
        XCTAssertThrowsError(try ReplySourcesClient.parse(["ok": false, "sources": [:]]))
    }
}
