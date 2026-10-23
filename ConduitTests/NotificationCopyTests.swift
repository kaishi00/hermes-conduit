//
//  NotificationCopyTests.swift
//
//  Notifications in the App Language (#1144): the phone writes a
//  notification's chrome from the event type or the host's `title_label`,
//  and keeps the host's content (body, chat title, call details).
//

import XCTest
@testable import Conduit

final class NotificationCopyTests: XCTestCase {
    private let standardDefaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        standardDefaults.set("en", forKey: AppLanguageStore.defaultsKey)
    }

    override func tearDown() {
        standardDefaults.removeObject(forKey: AppLanguageStore.defaultsKey)
        super.tearDown()
    }

    func testGenericCopyFollowsTheAppLanguage() {
        XCTAssertEqual(NotificationCopy.generic(for: "approval.needed").title, "Approval needed")
        standardDefaults.set("zh-Hans", forKey: AppLanguageStore.defaultsKey)
        let copy = NotificationCopy.generic(for: "approval.needed")
        XCTAssertEqual(copy.title, "需要批准")
        XCTAssertEqual(copy.body, "Hermes 正在等待你的批准。")
    }

    func testGenericCopyCoversEveryAlertType() {
        XCTAssertEqual(NotificationCopy.generic(for: "phone.changes").title, "Hermes has a change for you")
        XCTAssertEqual(NotificationCopy.generic(for: "call.requested").body, "Tap to talk to Hermes.")
        XCTAssertEqual(NotificationCopy.generic(for: nil).title, "Response ready")
    }

    func testLabelledTitleJoinsTheChatTitle() {
        let preview = NotificationCopy.preview([
            "title": "Approval needed · Deploy", "title_label": "approval.needed",
            "session_title": "Deploy", "body": "rm -rf build",
        ])
        XCTAssertEqual(preview.title, "Approval needed · Deploy")
        XCTAssertEqual(preview.body, "rm -rf build")

        standardDefaults.set("zh-Hans", forKey: AppLanguageStore.defaultsKey)
        let chinese = NotificationCopy.preview([
            "title": "Approval needed · Deploy", "title_label": "approval.needed", "session_title": "Deploy",
        ])
        XCTAssertEqual(chinese.title, "需要批准 · Deploy")
        XCTAssertNil(chinese.body, "no host body: the generic body stays")
    }

    func testReplyTitleIsTheChatTitleElseResponseReady() {
        XCTAssertEqual(NotificationCopy.preview([
            "title_label": "response.ready", "session_title": "Trip plan", "body": "Done.",
        ]).title, "Trip plan")
        XCTAssertEqual(NotificationCopy.preview([
            "title_label": "response.ready", "body": "Done.",
        ]).title, "Response ready")
    }

    func testPulsePushesAreTitledByWhatTheyBring() {
        XCTAssertEqual(NotificationCopy.preview([
            "title_label": "pulse.noticed", "count": 3, "title": "Pulse noticed 3 things", "body": "A · B · C",
        ]).title, "Pulse noticed 3 things")
        XCTAssertEqual(NotificationCopy.preview(["title_label": "pulse.noticed", "count": 1]).title,
                       "Pulse noticed something")
        XCTAssertEqual(NotificationCopy.preview(["title_label": "pulse.brief", "body": "Two things waited."]).title,
                       "Your morning brief")
        XCTAssertEqual(NotificationCopy.preview(["title_label": "pulse.followup"]).title, "Pulse · Follow-up")
    }

    func testUnlabelledPushKeepsTheHostText() {
        // An older plugin, or a title that is content (a tool's prompt).
        let preview = NotificationCopy.preview(["title": "Head to the airport", "body": "Tap Go."])
        XCTAssertEqual(preview.title, "Head to the airport")
        XCTAssertEqual(preview.body, "Tap Go.")
        XCTAssertNil(NotificationCopy.preview([:]).title)
    }

    func testPhoneChangeLabels() {
        XCTAssertEqual(NotificationCopy.preview([
            "title_label": "phone.add_event", "title": "Hermes wants to add an event", "body": "Lunch, Fri 12:00",
        ]).title, "Hermes wants to add an event")
        XCTAssertEqual(NotificationCopy.preview(["title_label": "phone.auto.set_timer"]).title,
                       "Hermes is starting a timer")
        XCTAssertEqual(NotificationCopy.preview(["title_label": "phone.unknown", "title": "Host"]).title,
                       "Host", "an unknown label keeps the host's title")
    }

    func testCallLineComposesFromTheCall() {
        func line(_ call: [String: Any]) -> String? {
            NotificationCopy.preview([
                "title_label": "call.requested", "body": "host line", "call": call,
            ]).body
        }
        XCTAssertEqual(line(["kind": "done", "title": "Check the server"]), "“Check the server” finished.")
        XCTAssertEqual(line(["kind": "failed"]), "Your job failed.")
        XCTAssertEqual(line(["kind": "done", "reason": "The build is green"]), "The build is green")
        XCTAssertEqual(line(["kind": "approval", "reason": "Deploy now?"]), "Hermes needs your OK. Deploy now?")
        XCTAssertEqual(line(["kind": "question"]), "Hermes has a question for you.")
        XCTAssertEqual(line(["kind": "failed", "origin": "alert"]), "Hermes ran into a problem with your request.")
        XCTAssertEqual(line(["title": "No kind"]), "host line", "a call without an outcome keeps the host's line")
        XCTAssertEqual(line(["kind": "paused", "title": "Backup"]), "“Backup” ended.", "as HermesCallCopy.outcome says it")
        XCTAssertEqual(NotificationCopy.preview(["title_label": "call.requested"]).title,
                       "Hermes wants to talk")
    }
}
