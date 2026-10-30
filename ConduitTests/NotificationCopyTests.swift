//
//  NotificationCopyTests.swift
//
//  Notifications in the App Language (#1144): the phone writes a
//  notification's chrome from the event type or the host's `title_label`,
//  and keeps the host's content (body, chat title, call details).
//

import UserNotifications
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

    func testAPrivatePulsePushSaysOnlyThatPulseHasSomething() {
        let content: [String: Any] = [
            "title_label": "pulse.followup", "body": "Pulse has something for you.", "private": true,
        ]
        XCTAssertEqual(NotificationCopy.preview(content).title, "Pulse · Follow-up")
        XCTAssertEqual(NotificationCopy.preview(content).body, "Pulse has something for you.")
        standardDefaults.set("de", forKey: AppLanguageStore.defaultsKey)
        XCTAssertEqual(NotificationCopy.preview(content).body, "Pulse hat etwas für dich.")
        XCTAssertEqual(NotificationCopy.preview(["title_label": "pulse.followup", "body": "Book it.", "private": "yes"]).body,
                       "Book it.", "only a private flag the plugin set")
        XCTAssertEqual(NotificationCopy.preview(["title_label": "response.ready", "body": "Done.", "private": true]).body,
                       "Done.", "only on a Pulse push")
    }

    func testPulsePushesOfferQuietForTodayWhereTheirPluginTakesIt() {
        let quiet: Set<String> = ["gw-home"]
        let offers = { (label: String?, gateway: String) in
            PulseNotifications.offersQuietToday(titleLabel: label, gatewayID: gateway, quietGateways: quiet)
        }
        XCTAssertTrue(offers("pulse.noticed", "gw-home"))
        XCTAssertTrue(offers("pulse.brief", " gw-home "))
        XCTAssertTrue(offers("pulse.followup", "gw-home"))
        XCTAssertFalse(offers("response.ready", "gw-home"))
        XCTAssertFalse(offers(nil, "gw-home"))
        XCTAssertFalse(offers("pulse.followup", "gw-other"))
        XCTAssertFalse(offers("pulse.followup", ""))

        // The button works without opening Conduit, in the App Language.
        let category = PulseNotifications.category()
        XCTAssertEqual(category.identifier, PulseNotifications.categoryIdentifier)
        XCTAssertEqual(category.actions.map(\.identifier), [PulseNotifications.quietTodayActionIdentifier])
        XCTAssertEqual(category.actions.first?.title, "Quiet for today")
        XCTAssertFalse(category.actions.first?.options.contains(.foreground) ?? true)
        // One that couldn't be done in the background keeps the push's dashboard and gateway to try again on.
        let target = PulseQuietTarget(dashboardID: UUID().uuidString, gatewayID: "gw-home")
        let retry = PulseNotifications.retryRequest(target: target)
        XCTAssertEqual(retry.identifier, PulseNotifications.retryIdentifier)
        XCTAssertNil(retry.trigger)
        XCTAssertEqual(retry.content.title, "Pulse isn't quiet yet")
        XCTAssertEqual(retry.content.body, "Tap to try again in Conduit.")
        XCTAssertEqual(PulseNotifications.retryTarget(retry.content.userInfo), target)
        let legacy = PulseQuietTarget(dashboardID: nil, gatewayID: "gw-home")
        XCTAssertEqual(PulseNotifications.retryTarget(PulseNotifications.retryRequest(target: legacy).content.userInfo), legacy)
        XCTAssertNil(PulseNotifications.retryTarget(PulseNotifications.retryRequest(target: nil).content.userInfo))
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
        ]).subtitle, "Work", "an unnamed profile shows its id, capitalized as in Conduit")
        XCTAssertEqual(NotificationCopy.preview([
            "title_label": "response.ready", "session_title": "Skills research", "profile": "work", "profile_name": "work",
        ]).subtitle, "Work", "a name that is only the id is capitalized too")
        XCTAssertEqual(NotificationCopy.preview([
            "title_label": "response.ready", "session_title": "Skills research", "profile": "Work", "profile_name": "work",
        ]).subtitle, "Work", "in any case, as routing reads the id")
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
        XCTAssertEqual(NotificationCopy.chatNames(["title": "Head to the airport", "profile": "work"]).subtitle, "Work")
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

    /// The main bot goes by its Conduit name (Eric 2026-10-28).
    func testTheMainBotGoesByItsConduitName() {
        let botChat: [String: Any] = ["title_label": "response.ready", "session_title": "Hermes", "profile": "default", "body": "Done."]
        let renamed = NotificationCopy.preview(NotificationCopy.named(botChat, mainName: "Jarvis"))
        XCTAssertEqual(renamed.title, "Jarvis", "its Bot Chat is titled with the name given it in Conduit")
        XCTAssertNil(renamed.subtitle, "which the title already says")
        XCTAssertEqual(NotificationCopy.preview(NotificationCopy.named(botChat, mainName: nil)).title, "Hermes")
        XCTAssertEqual(NotificationCopy.preview(NotificationCopy.named(botChat, mainName: "Hermes")).title, "Hermes", "Conduit's own name is no rename")
        let older = ["title_label": "response.ready", "session_title": "Default", "profile": "default"]
        XCTAssertEqual(NotificationCopy.preview(NotificationCopy.named(older, mainName: nil)).title, "Hermes", "an older plugin's \"Default\"")

        let titled: [String: Any] = ["title_label": "approval.needed", "session_title": "Muse", "profile": "default", "profile_name": "Muse"]
        XCTAssertEqual(NotificationCopy.chatNames(NotificationCopy.named(titled, mainName: "Jarvis")).title, "Approval needed · Jarvis", "the Conduit name over the bot's")
        XCTAssertEqual(NotificationCopy.chatNames(NotificationCopy.named(titled, mainName: nil)).title, "Approval needed · Muse")

        let chat: [String: Any] = ["title_label": "response.ready", "session_title": "Groceries", "profile": "default"]
        let named = NotificationCopy.preview(NotificationCopy.named(chat, mainName: "Jarvis"))
        XCTAssertEqual(named.title, "Groceries", "another chat keeps its title")
        // A push carries no Bot Chat marker, so a chat titled only the bot's
        // name reads as its Bot Chat (an open gap in the feature map).
        let lookalike: [String: Any] = ["title_label": "response.ready", "session_title": "Hermes", "profile": "default"]
        XCTAssertEqual(NotificationCopy.named(lookalike, mainName: "Jarvis")["session_title"] as? String, "Jarvis")
        XCTAssertEqual(named.subtitle, "Jarvis", "and says which bot, as for a bot named in Hermes")
        XCTAssertNil(NotificationCopy.preview(NotificationCopy.named(chat, mainName: nil)).subtitle)
        let hostNamed: [String: Any] = ["title_label": "response.ready", "session_title": "Groceries", "profile": "default", "profile_name": "Hermes"]
        XCTAssertNil(NotificationCopy.preview(NotificationCopy.named(hostNamed, mainName: nil)).subtitle, "a host's \"Hermes\" is an unnamed main bot")
        XCTAssertEqual(NotificationCopy.preview(NotificationCopy.named(hostNamed, mainName: "Jarvis")).subtitle, "Jarvis")

        let other: [String: Any] = ["title_label": "response.ready", "session_title": "Hermes", "profile": "atlas"]
        XCTAssertEqual(NotificationCopy.named(other, mainName: "Jarvis")["session_title"] as? String, "Hermes", "only the main profile")
    }

    func testTheMainNameIsThePushsDashboards() {
        let one = UUID().uuidString, two = UUID().uuidString
        let names = [one: "Jarvis", two: "Home"]
        XCTAssertEqual(NotificationCopy.mainName(dashboardID: one, activeDashboardID: two, names: names), "Jarvis", "the key's dashboard")
        XCTAssertEqual(NotificationCopy.mainName(dashboardID: nil, activeDashboardID: two, names: names), "Home", "else the open one")
        XCTAssertEqual(NotificationCopy.mainName(dashboardID: one.lowercased(), activeDashboardID: nil, names: names), "Jarvis", "in any case")
        XCTAssertNil(NotificationCopy.mainName(dashboardID: UUID().uuidString, activeDashboardID: two, names: names), "a dashboard with no name")
        XCTAssertNil(NotificationCopy.mainName(dashboardID: nil, activeDashboardID: nil, names: names))
    }
}
