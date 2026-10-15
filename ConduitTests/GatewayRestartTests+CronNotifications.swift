import XCTest
@testable import Conduit

/// Per-job cron notifications (CronNotifications.swift), kept by the host's
/// notifier plugin. An extension, so no new class to plan.
@MainActor
extension GatewayRestartTests {
    func testCronNotificationsReadTheMutedJobs() async throws {
        var asked: [(String, String, [String: Any]?)] = []
        let client = CronNotificationsClient { path, method, body in
            asked.append((path, method, body))
            return ["ok": true, "muted": ["a1b2c3d4e5f6"]]
        }
        let muted = try await client.muted(profile: "work")
        XCTAssertEqual(muted, ["a1b2c3d4e5f6"])
        XCTAssertEqual(asked.first?.0, "/api/plugins/conduit_push/cron/notifications?profile=work")
        XCTAssertEqual(asked.first?.1, "GET")
    }

    func testCronNotificationsSendTheJobAndChoice() async throws {
        var sent: [String: Any]?
        let client = CronNotificationsClient { _, method, body in
            XCTAssertEqual(method, "PUT")
            sent = body
            return ["ok": true, "muted": []]
        }
        let muted = try await client.setNotify(true, jobID: "job-1", profile: "default")
        XCTAssertEqual(muted, [])
        XCTAssertEqual(sent?["job_id"] as? String, "job-1")
        XCTAssertEqual(sent?["notify"] as? Bool, true)
    }

    func testAMalformedCronNotificationsAnswerThrows() {
        XCTAssertThrowsError(try CronNotificationsClient.parse(["ok": true]))
        XCTAssertThrowsError(try CronNotificationsClient.parse(["ok": false, "muted": []]))
    }
}
