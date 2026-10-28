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

    // #1415: which profile a push came from, and Chat names.

    func testSubtitleNamesTheProfile() {
        XCTAssertEqual(NotificationCopy.preview([
            "title_label": "response.ready", "session_title": "Skills research",
            "profile": "segundo-cerebro", "profile_name": "Segundo Cérebro", "body": "Found five repos.",
        ]).subtitle, "Segundo Cérebro", "the bot's name over the id")
        XCTAssertEqual(NotificationCopy.preview([
            "title_label": "response.ready", "session_title": "Skills research", "profile": "work",
        ]).subtitle, "work", "an unnamed profile shows its id")
        XCTAssertNil(NotificationCopy.preview([
            "title_label": "response.ready", "session_title": "Skills research", "profile": "default",
        ]).subtitle, "an unnamed default profile says nothing")
        XCTAssertNil(NotificationCopy.preview([
            "title_label": "response.ready", "profile": " Default ",
        ]).subtitle, "as routing reads it, trimmed and in any case")
        XCTAssertNil(NotificationCopy.preview([
            "title_label": "response.ready", "session_title": "Ada", "profile": "ada", "profile_name": "Ada",
        ]).subtitle, "a Bot Chat's title already names its bot")
        XCTAssertNil(NotificationCopy.preview([
            "title_label": "approval.needed", "session_title": "Ada", "profile_name": "Ada",
        ]).subtitle, "nor when the bot ends a joined title")
    }

    func testChatNamesKeepHermesWordsOut() {
        let names = NotificationCopy.chatNames([
            "title_label": "response.ready", "session_title": "Skills research",
            "profile": "segundo-cerebro", "profile_name": "Segundo Cérebro", "body": "Found five repos.",
        ])
        XCTAssertEqual(names.title, "Skills research")
        XCTAssertEqual(names.subtitle, "Segundo Cérebro")
        XCTAssertEqual(NotificationCopy.chatNames([
            "title_label": "approval.needed", "session_title": "Deploy",
        ]).title, "Approval needed · Deploy")
        XCTAssertNil(NotificationCopy.chatNames(["title": "Head to the airport", "profile": "work"]).title,
                     "an unlabelled host title may be content, so the generic title stays")
        XCTAssertEqual(NotificationCopy.chatNames(["title": "Head to the airport", "profile": "work"]).subtitle, "work")
    }

    func testWrittenHeadlineIsOnlyInThePreviewCopy() {
        let content: [String: Any] = [
            "title_label": "response.ready", "session_title": "Planning ", "headline": "Report finished",
            "profile": "segundo-cerebro", "profile_name": "Segundo Cérebro", "body": "All 150 products analysed.",
        ]
        let preview = NotificationCopy.preview(content)
        XCTAssertEqual(preview.title, "Report finished")
        XCTAssertEqual(preview.subtitle, "Planning · Segundo Cérebro")
        XCTAssertEqual(preview.body, "All 150 products analysed.")
        XCTAssertEqual(NotificationCopy.chatNames(content).title, "Planning ", "Chat names never shows Hermes' words")
        XCTAssertNil(NotificationCopy.preview(["title_label": "response.ready", "headline": "Done"]).subtitle)
    }

    func testBotChatSuffixIgnoresCase() {
        XCTAssertNil(NotificationCopy.preview([
            "title_label": "response.ready", "session_title": "ada ", "profile_name": "Ada",
        ]).subtitle)
    }
}
