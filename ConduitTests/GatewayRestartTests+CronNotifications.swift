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

    func testABotChatJobsChoiceIsReadSentAndOptional() async throws {
        var sent: [String: Any]?
        let client = CronNotificationsClient { _, method, body in
            if method == "PUT" { sent = body }
            return ["ok": true, "muted": ["m1"], "act": ["a1"], "shows_reports": true]
        }
        let read = try await client.choices(profile: "default")
        XCTAssertEqual(read, CronNotificationsClient.Choices(muted: ["m1"], act: ["a1"], showsReports: true))
        _ = try await client.setActs(true, jobID: "a1", profile: "default")
        XCTAssertEqual(sent?["job_id"] as? String, "a1")
        XCTAssertEqual(sent?["act"] as? Bool, true)
        XCTAssertNil(sent?["notify"])
        // An older plugin lists no `act`, and Conduit offers no choice there.
        XCTAssertEqual(try CronNotificationsClient.parseChoices(["ok": true, "muted": []]), .init())
        XCTAssertThrowsError(try CronNotificationsClient.parseChoices(["ok": true, "muted": [], "act": "a1"]))
    }

    /// Issue 581: the plugin writes a delivered picture or file as the
    /// `@image:`/`@file:` reference Hermes Desktop shows on the note's user
    /// row; the card draws it as the transcript draws a `MEDIA:` tag, and
    /// the folded card names it instead of showing its path.
    func testABotChatReportDrawsItsPicturesAndFiles() {
        let report = CronBotChatReport(job: "Quiz", report: [
            "@image:/cards/quiz.png",
            "Quiz: kapott?",
            "@file:`/var/mit leer.pdf`",
            "MEDIA:/old/plugin.png",
            "See @image:/x.png here.",
            "@file:/a b.pdf",
            "```",
            "@image:/example.png",
            "```",
        ].joined(separator: "\n"))
        XCTAssertEqual(report.shown, [
            "MEDIA:`/cards/quiz.png`",
            "Quiz: kapott?",
            "MEDIA:`/var/mit leer.pdf`",
            "MEDIA:/old/plugin.png",
            "See @image:/x.png here.",
            "@file:/a b.pdf",
            "```",
            "@image:/example.png",
            "```",
        ].joined(separator: "\n"))
        XCTAssertEqual(report.preview.components(separatedBy: "\n").prefix(4), ["quiz.png", "Quiz: kapott?", "mit leer.pdf", "plugin.png"])
        XCTAssertEqual(CronBotChatReport(job: "News", report: "Rain at 9.").shown, "Rain at 9.")
        // A list marker goes, so the tag is a line of its own and the folded
        // card names it; a quote and a math block stay as written.
        let marked = CronBotChatReport(job: "Q", report: "- @image:/cards/a.png\n  > @file:/cards/b.pdf\n$$\n@image:/x.png\n$$\n@file:\"")
        XCTAssertEqual(marked.shown, "MEDIA:`/cards/a.png`\n  > @file:/cards/b.pdf\n$$\n@image:/x.png\n$$\n@file:\"")
        XCTAssertEqual(marked.preview.components(separatedBy: "\n").first, "a.png")
        let bracketMath = "\\[\n@image:/x.png\n\\]\n@image:/after.png"
        XCTAssertEqual(CronBotChatReport(job: "Q", report: bracketMath).shown, "\\[\n@image:/x.png\n\\]\nMEDIA:`/after.png`")
        // Two references on a line, quoted or run together, stay as written.
        for twoFiles in ["@file:\"/tmp/a.pdf\" @file:\"/tmp/b.pdf\"", "@file:/tmp/a.pdf,@file:/tmp/b.pdf"] {
            XCTAssertEqual(CronBotChatReport(job: "Q", report: twoFiles).shown, twoFiles)
        }
        // A backtick line inside a tilde fence doesn't close it.
        XCTAssertEqual(
            CronBotChatReport(job: "Q", report: "~~~\n```\n@image:/in/code.png\n~~~\n@image:/after.png").shown,
            "~~~\n```\n@image:/in/code.png\n~~~\nMEDIA:`/after.png`"
        )
        // The folded card leaves a tag in code or math as written too.
        let examples = CronBotChatReport(job: "Q", report: "```\nMEDIA:/example.png\n```\n$$\nMEDIA:/m.png\n$$\nMEDIA:/real.png")
        XCTAssertEqual(examples.preview, "```\nMEDIA:/example.png\n```\n$$\nMEDIA:/m.png\n$$\nreal.png")
    }

    func testABotChatReportReadsAsTheJobAndItsReport() {
        let report = CronBotChatReport.parse(
            "[Cron job \"Morning news\" report: shown in the chat, no reply asked for]\n\nRain at 9.\n\n- Bring a coat"
        )
        XCTAssertEqual(report, CronBotChatReport(job: "Morning news", report: "Rain at 9.\n\n- Bring a coat"))
        XCTAssertNil(CronBotChatReport.parse("[Cron job \"Morning news\" output — scheduled job, not the user.]\n\nRain"))
        XCTAssertNil(CronBotChatReport.parse("Rain at 9."))
        XCTAssertTrue(CronDeliveryTarget.deliversToBotChat("bot-chat"))
        XCTAssertTrue(CronDeliveryTarget.deliversToBotChat("telegram, Bot-Chat:furina"))
        XCTAssertFalse(CronDeliveryTarget.deliversToBotChat("local"))
        XCTAssertFalse(CronDeliveryTarget.deliversToBotChat("bot-chatter"))
    }
}
