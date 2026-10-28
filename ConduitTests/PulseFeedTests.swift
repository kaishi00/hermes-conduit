//
//  PulseFeedTests.swift
//  Conduit
//
//  The Pulse screen reads the notifier plugin's /pulse/feed and
//  /pulse/learned as pulse_learning.py writes them: cards, the unseen
//  count, each kind's loudness and the lessons ratings made, what
//  learning holds, and what the reports left out (/pulse/left_out).
//

import XCTest
@testable import Conduit

@MainActor
final class PulseFeedTests: XCTestCase {
    private func appState() throws -> AppState {
        let suite = "PulseFeedTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppState(defaults: defaults, loadSavedConnection: false, clearSessionPresentationCache: {})
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testFeedDecodesThePluginsPayload() throws {
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"ok": true, "unseen": 2, "levels": {"followup": "brief", "other": "loud", "bad": 3},
         "cards": [
          {"id": 7, "kind": "followup", "level": "brief", "title": "Check the flight", "quote": "I'll check back",
           "news": "Flight is on time", "why": "Hermes said it would check", "profile": "work",
           "chat_id": "20261021_080000_abc", "chat_title": "Trip", "message_id": 42, "item_id": 11, "done_at": 1761040000, "done_by": "pulse",
           "created_at": 1761033600.5, "seen_at": null, "briefed_at": null, "rating": "", "reason": ""},
          {"id": 3, "kind": "followup", "level": "push", "title": "", "quote": "", "news": "Done",
           "why": "", "profile": "", "chat_id": "", "chat_title": "", "message_id": null,
           "created_at": 1761030000, "seen_at": 1761031000, "briefed_at": null, "rating": "down",
           "reason": "too_late"},
          {"kind": "followup"}, "junk"]}
        """)))

        XCTAssertEqual(page.unseen, 2)
        XCTAssertEqual(page.levels, ["followup": .brief])
        XCTAssertEqual(page.cards.map(\.id), [7, 3])

        let held = page.cards[0]
        XCTAssertEqual(held.chatID, "20261021_080000_abc")
        XCTAssertEqual(held.chatTitle, "Trip")
        XCTAssertEqual(held.messageID, 42)
        XCTAssertEqual(held.createdAt, Date(timeIntervalSince1970: 1761033600.5))
        XCTAssertNil(held.seenAt)
        XCTAssertTrue(held.isHeld)

        // A follow-up from a chat can be acted on there, with its news.
        XCTAssertTrue(held.isActionable)
        XCTAssertTrue(held.actionMessage.contains("Flight is on time"))
        // A follow-up about a promise can be marked done; the feed says when.
        XCTAssertEqual(held.itemID, 11)
        XCTAssertTrue(held.canBeDone)
        XCTAssertEqual(held.doneAt, Date(timeIntervalSince1970: 1761040000))
        XCTAssertEqual(held.doneBy, "pulse")

        let rated = page.cards[1]
        XCTAssertFalse(rated.isActionable)  // no chat to act in
        XCTAssertFalse(rated.canBeDone)  // no promise to close
        XCTAssertNil(rated.doneAt)
        XCTAssertEqual(rated.doneBy, "")
        XCTAssertNil(rated.messageID)
        XCTAssertFalse(rated.isHeld)
        XCTAssertEqual(rated.rating, "down")
        XCTAssertEqual(PulseDownReason(rawValue: rated.reason), .tooLate)
    }

    func testFeedNamesPulsesChatAndItsTurnCards() throws {
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"home_chat_id": " pulse_chat ", "cards": [
          {"id": 2, "kind": "brief", "level": "push", "news": "**Morning.**\\n- Flight on time", "chat_id": "pulse_chat"},
          {"id": 1, "kind": "report", "level": "screen", "news": "Nothing new"}]}
        """)))

        XCTAssertEqual(page.homeChatID, "pulse_chat")
        XCTAssertFalse(page.cards[0].isRatable)
        XCTAssertFalse(page.cards[0].isHeld)
        XCTAssertEqual(String(page.cards[0].formattedNews.characters), "Morning.\n- Flight on time")
        XCTAssertEqual(PulseCardKind.title("report"), AppLocalization.string("Reports"))
        XCTAssertEqual(PulseCardKind.title("brief"), AppLocalization.string("Morning brief"))

        let older = try XCTUnwrap(PulseFeedPage(json: json(#"{"home_chat_id": "", "cards": []}"#)))
        XCTAssertNil(older.homeChatID)
    }

    func testFeedWithoutCardsIsInvalid() throws {
        XCTAssertNil(PulseFeedPage(json: try json(#"{"ok": true, "unseen": 1}"#)))
    }

    func testSourcesMapMessagesToTheirNewestCard() throws {
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 9, "chat_id": "a", "message_id": 5},
          {"id": 8, "chat_id": "b", "message_id": 1},
          {"id": 4, "chat_id": "a", "message_id": 5},
          {"id": 2, "chat_id": "a", "message_id": 6},
          {"id": 1, "chat_id": "", "message_id": 7},
          {"id": 0, "chat_id": "c"}]}
        """)))

        XCTAssertEqual(page.sources, ["a": [5: 9, 6: 2], "b": [1: 8]])
    }

    func testLearnedDecodesLessonsAndTheirText() throws {
        let learned = try XCTUnwrap(PulseLearned(json: json("""
        {"ok": true, "levels": {"followup": "screen"},
         "lessons": [
          {"id": 1, "kind": "followup", "what": "level", "value": "screen", "cause": "2 thumbs down",
           "created_at": 1761033600},
          {"id": 2, "kind": "followup", "what": "rule", "value": "the weather", "cause": "not relevant"},
          {"id": 3, "kind": "followup", "what": "sooner", "value": "", "cause": "too late"},
          {"id": 4, "kind": "followup", "what": "seen", "value": "", "cause": "already knew"},
          {"id": 5, "kind": "followup", "what": "level", "value": "off", "cause": "set"},
          {"id": 6, "kind": "followup"},
          {"id": 7, "kind": "commitment", "what": "level", "value": "brief", "cause": "too often"},
          {"id": 8, "kind": "date", "what": "sooner", "value": "", "cause": "too late"},
          {"id": 9, "kind": "fact", "what": "seen", "value": "", "cause": "already knew"},
          {"id": 10, "kind": "noticed", "what": "rule", "value": "Send the deck", "cause": "not relevant"}]}
        """)))

        XCTAssertEqual(learned.levels, ["followup": .screen])
        XCTAssertEqual(learned.lessons.map(\.id), [1, 2, 3, 4, 5, 7, 8, 9, 10])
        let lessons = learned.lessons

        XCTAssertEqual(lessons[0].text, AppLocalization.string("\(PulseCardKind.title("followup")): \(PulseLevel.screen.title)"))
        XCTAssertEqual(lessons[0].causeText, AppLocalization.string("After thumbs down"))
        XCTAssertEqual(lessons[0].createdAt, Date(timeIntervalSince1970: 1761033600))

        XCTAssertEqual(lessons[1].text, AppLocalization.string("No updates about “\("the weather")”"))
        XCTAssertEqual(lessons[1].causeText, AppLocalization.string("You said not relevant"))
        XCTAssertEqual(lessons[2].text, AppLocalization.string("Check on promises sooner"))
        XCTAssertEqual(lessons[2].causeText, AppLocalization.string("You said too late"))
        XCTAssertEqual(lessons[3].text, AppLocalization.string("Skip news you already saw in the chat"))
        XCTAssertEqual(lessons[3].causeText, AppLocalization.string("You said you already knew"))
        XCTAssertEqual(lessons[4].text, AppLocalization.string("\(PulseCardKind.title("followup")): \(PulseLevel.off.title)"))
        XCTAssertNil(lessons[4].causeText)
        // A report card's reasons teach about its topic (0.81.1), and its lessons say which.
        XCTAssertEqual(lessons[5].text, AppLocalization.string("\(PulseCardKind.topic("commitment")): \(PulseLevel.brief.title)"))
        XCTAssertEqual(lessons[5].causeText, AppLocalization.string("You said too often"))
        XCTAssertEqual(lessons[6].text, AppLocalization.string("\(PulseCardKind.topic("date")): Bring up sooner"))
        XCTAssertEqual(lessons[7].text, AppLocalization.string("\(PulseCardKind.topic("fact")): Skip what you already know"))
        XCTAssertEqual(lessons[8].text, AppLocalization.string("No updates about “\("Send the deck")”"))
        XCTAssertEqual(PulseCardKind.name("followup"), PulseCardKind.title("followup"))
        XCTAssertEqual(PulseCardKind.name("noticed"), PulseCardKind.title("noticed"))
        XCTAssertEqual(PulseCardKind.name("other"), PulseCardKind.topic("other"))

        // Before 0.81.1 thumbs move the levels; a plugin that learns says the level is the loudest Pulse gets.
        XCTAssertEqual(PulseLearned.levelsFooter(learns: false),
                       AppLocalization.string("Thumbs move these too: two down make it quieter, two up louder."))
        XCTAssertEqual(PulseLearned.levelsFooter(learns: true), AppLocalization.string(
            "The loudest Pulse gets for each. Within that, your thumbs, Do it and Done teach it what to bring up and how loudly."))
        XCTAssertEqual(PulseLearned.noLessons(learns: false),
                       AppLocalization.string("Nothing yet. Rate Pulse's cards and what it learns shows up here."))
        XCTAssertEqual(PulseLearned.noLessons(learns: true), AppLocalization.string(
            "Nothing yet. When you give a reason with a thumbs down, what it changes shows up here."))
        XCTAssertEqual(PulseClient.learnsCapability, "pulse_learns")
    }

    func testLearnedListsWhatLearningHoldsAndResetsSayWhatTheyForgot() throws {
        let learned = try XCTUnwrap(PulseLearned(json: json("""
        {"ok": true, "levels": {},
         "lessons": [
          {"id": 11, "kind": "place", "what": "reset", "value": "chat::c1", "cause": "reset", "chat_title": "Deploy"},
          {"id": 12, "kind": "everything", "what": "reset", "value": "", "cause": "reset"},
          {"id": 13, "kind": "timely", "what": "reset", "value": "yes", "cause": "reset"}],
         "preferences": [
          {"scope": "place", "value": "chat::c1", "effect": -1.8, "useful": 0, "votes": 2,
           "profile": "", "chat_id": "c1", "chat_title": "Deploy"},
          {"scope": "loud", "value": "followup", "effect": 0.6, "pushes": 3},
          {"scope": "kind", "value": "promise", "effect": 0.7, "useful": 2.5, "votes": 3},
          {"scope": "place", "value": "area:health", "effect": -0.3, "useful": 1, "votes": 4},
          {"scope": "place", "value": "source:calendar", "effect": 0.2, "useful": 1, "votes": 1},
          {"scope": "timely", "value": "no", "effect": -0.2, "useful": 0, "votes": 0},
          {"scope": "all", "value": "", "effect": 0.4, "useful": 3, "votes": 5},
          {"scope": "place", "value": "chat::c2", "effect": 0.2, "useful": 1, "votes": 1},
          {"scope": "everything", "value": "", "effect": 1},
          {"scope": "kind", "value": "date"}]}
        """)))

        let found = learned.preferences
        XCTAssertEqual(found.map(\.id), [
            "place|chat::c1", "loud|followup", "kind|promise", "place|area:health", "place|source:calendar",
            "timely|no", "all|", "place|chat::c2"
        ])
        // Every vote leans over Pulse's cards in general: only Start over forgets that.
        XCTAssertEqual(found.map(\.canReset), [true, true, true, true, true, true, false, true])
        XCTAssertEqual(found.map(\.subject), [
            AppLocalization.string("Things from “\("Deploy")”"),
            AppLocalization.string("How loudly “\(PulseCardKind.title("followup"))” cards come up"),
            AppLocalization.string("“\(PulseCardKind.topic("promise"))” cards"),
            AppLocalization.string("Things about “\(AppLocalization.string("Health and wellbeing"))”"),
            AppLocalization.string("Things from “\(AppLocalization.string("Calendar"))”"),
            AppLocalization.string("What isn't due within a day"),
            AppLocalization.string("Pulse's cards in general"),
            AppLocalization.string("Things from a chat")
        ])
        let dot = " · "
        XCTAssertEqual(found[0].detail, [
            AppLocalization.string("Brings up less"), AppLocalization.string("Strong effect"),
            AppLocalization.string("Useful \(PulsePreference.number(0)) out of \(PulsePreference.number(2)) lately")
        ].joined(separator: dot))
        let pushCount = 3
        XCTAssertEqual(found[1].detail, AppLocalization.string("Louder") + dot
            + AppLocalization.string("After \(pushCount) notifications you acted on within the hour"))
        XCTAssertEqual(found[2].detail, [
            AppLocalization.string("Brings up more"), AppLocalization.string("Moderate effect"),
            AppLocalization.string("Useful \(PulsePreference.number(2.5)) out of \(PulsePreference.number(3)) lately")
        ].joined(separator: dot))
        XCTAssertEqual(found[3].strength, AppLocalization.string("Slight effect"))
        // No votes left in the window: which way, and how strongly.
        XCTAssertEqual(found[5].detail, AppLocalization.string("Brings up less") + dot + AppLocalization.string("Slight effect"))
        XCTAssertEqual(PulsePlace.area("travel"), AppLocalization.string("Trips and travel"))
        XCTAssertEqual(PulsePlace.area("something new"), AppLocalization.string("Other matters"))
        XCTAssertEqual(PulsePlace.source("notes"), AppLocalization.string("Hermes' notes"))
        XCTAssertEqual(PulsePlace.source("chat"), AppLocalization.string("Chats"))

        // A reset says what it forgot; Undo takes it back like any lesson.
        let lessons = learned.lessons
        XCTAssertEqual(lessons.map(\.id), [11, 12, 13])
        XCTAssertEqual(lessons[0].text, AppLocalization.string("Reset: \(AppLocalization.string("Things from “\("Deploy")”"))"))
        XCTAssertNil(lessons[0].causeText)
        XCTAssertEqual(lessons[1].text, AppLocalization.string("Forgot everything learned before this"))
        XCTAssertEqual(lessons[2].text, AppLocalization.string("Reset: \(AppLocalization.string("What's overdue or due within a day"))"))
        XCTAssertEqual(PulseLearned.noPreferences, AppLocalization.string(
            "Nothing stands out yet. The more you use thumbs, Do it and Done, the more Pulse learns what to bring up."))
        // A plugin from before lists none.
        let older = try XCTUnwrap(PulseLearned(json: json(#"{"lessons": []}"#)))
        XCTAssertEqual(older.preferences, [])
        XCTAssertEqual(PulseClient.explainsCapability, "pulse_explains")
    }

    func testPulseCardsForChatFindsTheOpenChat() throws {
        let state = try appState()
        state.pulseSources = ["a": [5: 9]]

        XCTAssertEqual(state.pulseCards(forChat: "a"), [5: 9])
        XCTAssertEqual(state.pulseCards(forChat: "b"), [:])
        XCTAssertEqual(state.pulseCards(forChat: nil), [:])
    }

    func testApplyingAFeedSetsTheBadgeAndMarks() throws {
        let state = try appState()
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"unseen": 3, "cards": [{"id": 9, "chat_id": "a", "message_id": 5}]}
        """)))

        state.applyPulseFeed(page)

        XCTAssertEqual(state.pulseUnseen, 3)
        XCTAssertEqual(state.pulseSources, ["a": [5: 9]])
        XCTAssertNil(state.pulseHomeChatID)

        state.applyPulseFeed(try XCTUnwrap(PulseFeedPage(json: json(#"{"home_chat_id": "p", "cards": []}"#))))
        XCTAssertEqual(state.pulseHomeChatID, "p")
    }

    func testPulseKeepsItsButtonAndHiddenChatUntilThePluginReportsAgain() throws {
        let suite = "PulseFeedTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let dashboard = SavedDashboard(id: UUID(), label: "Home", normalizedURL: "http://127.0.0.1:1")
        let registry = SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard])
        let first = AppState(defaults: defaults, loadSavedConnection: false, dashboardRegistry: registry,
                             clearSessionPresentationCache: {})
        first.applyPulseFeed(try XCTUnwrap(PulseFeedPage(json: json(#"{"home_chat_id": "p", "cards": []}"#))))

        // The next launch: the plugin hasn't answered yet.
        let next = AppState(defaults: defaults, loadSavedConnection: false, dashboardRegistry: registry,
                            clearSessionPresentationCache: {})
        XCTAssertNil(next.pulseHomeChatID)
        XCTAssertEqual(next.pulseHomeChat, "p")
        XCTAssertTrue(next.showsPulseScreen)

        // It answers with Pulse before the feed is read: still hidden.
        next.setNotifierPluginStateForTesting(.reported(version: "0.74.0",
                                                        capabilities: [PulseClient.capability, PulseClient.feedCapability]))
        XCTAssertEqual(next.pulseHomeChat, "p")
        XCTAssertTrue(next.showsPulseScreen)

        // It answers without Pulse, or predates reporting: gone, and forgotten.
        next.setNotifierPluginStateForTesting(.reported(version: "0.40.0", capabilities: []))
        XCTAssertNil(next.pulseHomeChat)
        XCTAssertFalse(next.showsPulseScreen)
        let later = AppState(defaults: defaults, loadSavedConnection: false, dashboardRegistry: registry,
                             clearSessionPresentationCache: {})
        XCTAssertNil(later.pulseHomeChat)

        later.applyPulseFeed(try XCTUnwrap(PulseFeedPage(json: json(#"{"home_chat_id": "p", "cards": []}"#))))
        let older = AppState(defaults: defaults, loadSavedConnection: false, dashboardRegistry: registry,
                             clearSessionPresentationCache: {})
        older.setNotifierPluginStateForTesting(.predatesCapabilities)
        XCTAssertNil(older.pulseHomeChat)
        XCTAssertFalse(older.showsPulseScreen)
    }

    func testARemovedDashboardTakesItsRememberedPulseChatWithIt() throws {
        let suite = "PulseFeedTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let active = SavedDashboard(id: UUID(), label: "Home", normalizedURL: "http://127.0.0.1:1")
        let other = SavedDashboard(id: UUID(), label: "Office", normalizedURL: "http://127.0.0.1:2")
        defaults.set([active.id.uuidString: "p", other.id.uuidString: "q"], forKey: AppState.pulseHomesKey)
        let appState = AppState(defaults: defaults, loadSavedConnection: false,
                                dashboardRegistry: SavedDashboardRegistry(activeDashboardID: active.id,
                                                                          dashboards: [active, other]),
                                clearSessionPresentationCache: {})

        appState.removeDashboard(other.id)

        XCTAssertEqual(defaults.dictionary(forKey: AppState.pulseHomesKey) as? [String: String],
                       [active.id.uuidString: "p"])
        XCTAssertEqual(appState.pulseHomeChat, "p")
    }

    func testDoneAndActedPostTheCardToThePlugin() async throws {
        var calls: [(path: String, method: String, body: [String: Any]?)] = []
        var answer: [String: Any] = ["ok": true, "changed": true]
        let client = PulseClient { path, method, body in
            calls.append((path, method, body))
            return answer
        }

        let changed = try await client.markDone(card: 7, done: true)
        XCTAssertTrue(changed)
        answer = ["ok": true, "changed": false]
        let unchanged = try await client.markDone(card: 7, done: false)
        XCTAssertFalse(unchanged)
        try await client.acted(card: 9)

        XCTAssertEqual(calls.map(\.path), [
            "\(PulseClient.path)/done", "\(PulseClient.path)/done", "\(PulseClient.path)/acted"
        ])
        XCTAssertEqual(calls.map(\.method), ["POST", "POST", "POST"])
        XCTAssertEqual(calls[0].body?["card"] as? Int, 7)
        XCTAssertEqual(calls[0].body?["done"] as? Bool, true)
        XCTAssertEqual(calls[1].body?["done"] as? Bool, false)
        XCTAssertEqual(calls[2].body?["card"] as? Int, 9)
    }

    func testReportItemsAreTheirOwnRatableCards() throws {
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 1, "kind": "noticed", "topic": "promise", "item_id": 4, "level": "screen", "news": "Send the deck",
           "chat_id": "work", "title": "Send the deck to Mara"},
          {"id": 2, "kind": "noticed", "topic": "date", "level": "screen", "news": "Dentist Friday", "chat_id": "pulse"},
          {"id": 3, "kind": "report", "level": "screen", "news": "Here's your report."}
        ]}
        """)))
        let owed = page.cards[0], date = page.cards[1], report = page.cards[2]
        XCTAssertTrue(owed.isNoticed && owed.isRatable && owed.canBeDone && owed.isActionable)
        XCTAssertEqual(owed.topic, "promise")
        XCTAssertEqual(owed.heading, PulseCardKind.topic("promise"))
        XCTAssertTrue(date.isRatable)
        XCTAssertFalse(date.canBeDone || date.isActionable)  // nothing remembered behind it
        XCTAssertTrue(date.isFound)
        XCTAssertFalse(owed.isFound || report.isFound)
        XCTAssertFalse(report.isRatable)
        XCTAssertEqual(report.heading, PulseCardKind.title("report"))
        XCTAssertEqual(PulseCardKind.topic("something new"), PulseCardKind.topic(""))  // unknown topics read "Noticed"
    }

    func testWhyShowsOnAReportCardOnceThePluginGivesItsReason() throws {
        let state = try appState()
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 1, "kind": "followup", "level": "push", "news": "The deploy is still waiting.",
           "why": "You said you would check it."},
          {"id": 2, "kind": "noticed", "topic": "date", "level": "screen", "news": "Dentist Friday",
           "why": "Your calendar has it for Friday."},
          {"id": 3, "kind": "noticed", "topic": "fact", "level": "screen", "news": "Ana is in town", "why": ""},
          {"id": 4, "kind": "brief", "level": "screen", "news": "Your morning brief",
           "why": "Your morning brief: what's still outstanding."},
          {"id": 5, "kind": "report", "level": "push", "news": "Pulse noticed 2 things",
           "why": "Your Pulse report: what Hermes saw in your chats since the last one."},
          {"id": 6, "kind": "report", "level": "push", "news": "Pulse noticed 2 things", "why": ""}
        ]}
        """)))
        let followup = page.cards[0], dated = page.cards[1], plain = page.cards[2]
        let brief = page.cards[3], whole = page.cards[4], wholeNow = page.cards[5]
        // A plugin from before gave report and brief cards stock lines: only a follow-up's reason shows.
        state.setNotifierPluginStateForTesting(.reported(version: "0.80.0", capabilities: [PulseClient.feedCapability]))
        XCTAssertTrue(state.explainsPulseCard(followup))
        XCTAssertFalse(state.explainsPulseCard(dated))
        XCTAssertFalse(state.explainsPulseCard(plain))
        XCTAssertFalse(state.explainsPulseCard(brief))
        XCTAssertFalse(state.explainsPulseCard(whole))
        // One that gives each report item its candidate's reason (0.80.1): Why? where there is one.
        state.setNotifierPluginStateForTesting(.reported(version: "0.80.1", capabilities: [
            PulseClient.feedCapability, PulseClient.cardWhyCapability
        ]))
        XCTAssertTrue(state.explainsPulseCard(followup))
        XCTAssertTrue(state.explainsPulseCard(dated))
        XCTAssertTrue(state.explainsPulseCard(brief))
        // Such a plugin clears the old stock lines, so a whole report's card has no why;
        // one that had a why would show it.
        XCTAssertFalse(state.explainsPulseCard(wholeNow))
        XCTAssertTrue(state.explainsPulseCard(whole))
        XCTAssertFalse(state.explainsPulseCard(plain))
    }

    func testWhyNamesWhatLearningDidOnceThePluginSays() throws {
        let state = try appState()
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 1, "kind": "followup", "level": "brief", "news": "The deploy is still waiting.", "why": "",
           "profile": "", "chat_id": "c1", "chat_title": "Deploy",
           "learned": {"scope": "place", "value": "chat::c1", "effect": -0.9, "useful": 0, "votes": 2}},
          {"id": 2, "kind": "noticed", "topic": "promise", "level": "screen", "news": "Send the deck",
           "why": "You said you'd send it.",
           "learned": {"scope": "kind", "value": "promise", "effect": 0.6, "useful": 2, "votes": 2}},
          {"id": 3, "kind": "noticed", "topic": "fact", "level": "screen", "news": "Ana is in town", "why": "",
           "learned": null},
          {"id": 4, "kind": "noticed", "topic": "date", "level": "screen", "news": "Dentist", "why": "",
           "chat_id": "c1", "chat_title": "Deploy",
           "learned": {"scope": "place", "value": "chat::c2", "effect": 0.5}},
          {"id": 5, "kind": "noticed", "topic": "date", "level": "screen", "news": "Flight", "why": "",
           "learned": {"scope": "bogus", "value": "x", "effect": 1}}
        ]}
        """)))
        let held = page.cards[0], promised = page.cards[1], plain = page.cards[2]
        let elsewhere = page.cards[3], odd = page.cards[4]
        state.setNotifierPluginStateForTesting(.reported(version: "0.84.0", capabilities: [
            PulseClient.feedCapability, PulseClient.cardWhyCapability, PulseClient.learnsCapability,
            PulseClient.explainsCapability
        ]))
        XCTAssertTrue(state.pulseExplainsLearning)
        // Held for the brief by what thumbs taught about its chat: Why? says so, by the card's chat title.
        XCTAssertEqual(held.learned?.subject, AppLocalization.string("Things from “\("Deploy")”"))
        XCTAssertTrue(state.explainsPulseCard(held))
        XCTAssertFalse(state.explainsPulseCardReason(held))
        XCTAssertEqual(promised.learned?.subject, AppLocalization.string("“\(PulseCardKind.topic("promise"))” cards"))
        XCTAssertTrue(state.explainsPulseCardReason(promised))
        XCTAssertNil(plain.learned)
        XCTAssertFalse(state.explainsPulseCard(plain))
        // Another chat's title isn't the card's to give.
        XCTAssertEqual(elsewhere.learned?.subject, AppLocalization.string("Things from a chat"))
        XCTAssertNil(odd.learned)
        // A plugin from before has no What Pulse left out and no Reset, and
        // its Why? says nothing about learning even if a card carries it.
        state.setNotifierPluginStateForTesting(.reported(version: "0.82.0", capabilities: [
            PulseClient.feedCapability, PulseClient.cardWhyCapability, PulseClient.learnsCapability
        ]))
        XCTAssertFalse(state.pulseExplainsLearning)
        XCTAssertFalse(state.explainsPulseCard(held))
        XCTAssertTrue(state.explainsPulseCard(promised))  // its own reason, which 0.80.1 on gives
    }

    func testAReportCardsThumbsDownAsksWhyOnceThePluginActsOnIt() throws {
        let state = try appState()
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 1, "kind": "followup", "level": "push", "news": "The deploy is still waiting."},
          {"id": 2, "kind": "noticed", "topic": "date", "level": "screen", "news": "Dentist Friday"},
          {"id": 3, "kind": "report", "level": "push", "news": "Pulse noticed 2 things"}
        ]}
        """)))
        let followup = page.cards[0], dated = page.cards[1], whole = page.cards[2]
        // Before 0.81.1 a report card's reason changed nothing: its thumbs down is enough.
        state.setNotifierPluginStateForTesting(.reported(version: "0.81.0", capabilities: [PulseClient.feedCapability]))
        XCTAssertTrue(state.asksPulseDownReason(followup))
        XCTAssertFalse(state.asksPulseDownReason(dated) || state.asksPulseDownReason(whole))
        // A plugin that learns acts on a report card's reason too.
        state.setNotifierPluginStateForTesting(.reported(version: "0.81.1", capabilities: [
            PulseClient.feedCapability, PulseClient.learnsCapability
        ]))
        XCTAssertTrue(state.asksPulseDownReason(followup) && state.asksPulseDownReason(dated))
        XCTAssertFalse(state.asksPulseDownReason(whole))  // a whole report has no thumbs
    }

    func testDoItsMessageFitsWhatTheCardIsAbout() throws {
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 1, "kind": "followup", "level": "push", "news": "The backup is still on the server", "chat_id": "work"},
          {"id": 2, "kind": "noticed", "topic": "promise", "item_id": 4, "level": "screen", "news": "I still owe you the build check", "chat_id": "work"},
          {"id": 3, "kind": "noticed", "topic": "commitment", "item_id": 5, "level": "screen", "news": "Renew your passport", "chat_id": "work"},
          {"id": 4, "kind": "noticed", "topic": "reminder", "level": "screen", "news": "Send the release notes", "chat_id": ""},
          {"id": 5, "kind": "noticed", "topic": "date", "level": "screen", "news": "Ana lands at 18:00", "chat_id": ""},
          {"id": 6, "kind": "noticed", "topic": "watch", "level": "screen", "news": "The deploy is still flaky", "chat_id": "work"},
          {"id": 7, "kind": "noticed", "topic": "interest", "level": "screen", "news": "A new Swift release is out", "chat_id": "work"},
          {"id": 8, "kind": "noticed", "topic": "fact", "level": "screen", "news": "", "title": "Your sister is Ana", "chat_id": "work"},
          {"id": 9, "kind": "noticed", "topic": "", "level": "screen", "news": "Something else", "chat_id": "work"}
        ]}
        """)))
        let message = Dictionary(uniqueKeysWithValues: page.cards.map { ($0.id, $0.actionMessage) })
        // What Hermes said it would do gets a go-ahead, whether the card is a
        // follow-up or a remembered promise.
        XCTAssertEqual(message[1], "Pulse reminded me: The backup is still on the server\n\nGo ahead with it now.")
        XCTAssertEqual(message[2], "Pulse reminded me: I still owe you the build check\n\nGo ahead with it now.")
        // What the user meant to do gets taken care of.
        XCTAssertEqual(message[3], "Pulse reminded me: Renew your passport\n\nLet's take care of it now.")
        XCTAssertEqual(message[4], "Pulse reminded me: Send the release notes\n\nLet's take care of it now.")
        XCTAssertEqual(message[5], "Pulse brought this up: Ana lands at 18:00\n\nHelp me get ready for it.")
        XCTAssertEqual(message[6], "Pulse brought this up: The deploy is still flaky\n\nWhere does that stand now?")
        XCTAssertEqual(message[7], "Pulse brought this up: A new Swift release is out\n\nTell me more.")
        // The title stands in for empty news; a fact or an unknown topic gets a look.
        XCTAssertEqual(message[8], "Pulse brought this up: Your sister is Ana\n\nLet's look into it.")
        XCTAssertEqual(message[9], "Pulse brought this up: Something else\n\nLet's look into it.")
    }

    func testACardPointingAtPulsesOwnChatOpensNoChat() throws {
        let state = try appState()
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"home_chat_id": "pulse_chat", "cards": [
          {"id": 1, "kind": "brief", "level": "push", "news": "Morning", "chat_id": "pulse_chat"},
          {"id": 2, "kind": "followup", "level": "push", "news": "Deck", "chat_id": "work"}
        ]}
        """)))
        state.applyPulseFeed(page)
        XCTAssertFalse(state.pulseCardHasChat(page.cards[0]))
        XCTAssertTrue(state.pulseCardHasChat(page.cards[1]))
    }

    func testDoneAndDoItReachReportItemsPulseFoundOnItsOwnWhereThePluginTakesThem() throws {
        let state = try appState()
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"home_chat_id": "pulse_chat", "cards": [
          {"id": 1, "kind": "noticed", "topic": "date", "level": "screen", "news": "Dentist Friday", "chat_id": "pulse_chat"},
          {"id": 2, "kind": "noticed", "topic": "fact", "level": "screen", "news": "The repo moved", "chat_id": "work"},
          {"id": 3, "kind": "noticed", "topic": "promise", "item_id": 4, "level": "screen", "news": "Send the deck",
           "chat_id": "work"},
          {"id": 4, "kind": "report", "level": "screen", "news": "Here's your report.", "chat_id": "pulse_chat"}
        ]}
        """)))
        let date = page.cards[0], fact = page.cards[1], owed = page.cards[2], report = page.cards[3]
        // A plugin that takes Done and Do it only on what Pulse remembers (0.64.0).
        state.setNotifierPluginStateForTesting(.reported(version: "0.76.0", capabilities: [
            PulseClient.feedCapability, PulseClient.doneCapability, PulseClient.actedCapability
        ]))
        state.applyPulseFeed(page)
        XCTAssertTrue(state.canMarkPulseCardDone(owed) && state.canActOnPulseCard(owed))
        XCTAssertFalse(state.canMarkPulseCardDone(date) || state.canActOnPulseCard(date))
        XCTAssertFalse(state.canMarkPulseCardDone(fact) || state.canActOnPulseCard(fact))
        // One that takes them on every report item (0.77.0).
        state.setNotifierPluginStateForTesting(.reported(version: "0.77.0", capabilities: [
            PulseClient.feedCapability, PulseClient.doneCapability, PulseClient.actedCapability,
            PulseClient.foundActionsCapability
        ]))
        XCTAssertTrue(state.canMarkPulseCardDone(date) && state.canActOnPulseCard(date))
        XCTAssertTrue(state.canMarkPulseCardDone(fact) && state.canActOnPulseCard(fact))
        XCTAssertFalse(state.canMarkPulseCardDone(report) || state.canActOnPulseCard(report))
        // Found in a chat, Do it opens that chat; from no chat, Pulse's own is
        // no chat to open, so it starts a new one.
        XCTAssertTrue(state.pulseCardHasChat(fact))
        XCTAssertFalse(state.pulseCardHasChat(date))
        XCTAssertNil(state.pulseNewChatRefusal(for: fact))  // its own chat opens, connected or not
        // A plugin without Done takes it on no card.
        state.setNotifierPluginStateForTesting(.reported(version: "0.77.0", capabilities: [
            PulseClient.feedCapability, PulseClient.foundActionsCapability
        ]))
        XCTAssertFalse(state.canMarkPulseCardDone(date) || state.canMarkPulseCardDone(owed))
    }

    func testDoItOnAReportItemFromNoChatFillsOnlyTheChatItsNewChatMade() async throws {
        let state = try appState()
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"home_chat_id": "pulse_chat", "cards": [
          {"id": 1, "kind": "noticed", "topic": "date", "level": "screen", "news": "Dentist Friday", "chat_id": "pulse_chat"}
        ]}
        """)))
        state.setNotifierPluginStateForTesting(.reported(version: "0.77.0", capabilities: [
            PulseClient.feedCapability, PulseClient.doneCapability, PulseClient.actedCapability,
            PulseClient.foundActionsCapability
        ]))
        state.applyPulseFeed(page)
        let date = try XCTUnwrap(page.cards.first)
        // Offline, Do it says so at once instead of waiting for a chat.
        XCTAssertEqual(state.pulseNewChatRefusal(for: date),
                       AppLocalization.string("Couldn't start a new chat. Check your connection and try again."))
        let refused = await state.actOnPulseCard(date)
        XCTAssertFalse(refused)
        // Connecting, it says so too: New Chat would make a chat that waits.
        state.isConnecting = true
        XCTAssertEqual(state.pulseNewChatRefusal(for: date),
                       AppLocalization.string("Conduit is still connecting to your dashboard. Try again in a moment."))
        state.isConnecting = false
        state.isConnected = true
        state.client = HermesClient(connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
                                    profile: "default")
        XCTAssertNil(state.pulseNewChatRefusal(for: date))
        // A chat an earlier New Chat made is still open, under the chat list.
        state.activeSessionId = "earlier"
        state.newChatOpenedSessionID = "earlier"
        state.showSidebar = true
        // A new chat that doesn't start gets nothing, and the earlier one isn't taken for it.
        state.widgetSessionCreatorOverride = { _, _ in throw URLError(.timedOut) }
        let failed = await state.actOnPulseCard(date)
        XCTAssertFalse(failed)
        XCTAssertEqual(state.activeSessionId, "earlier")
        XCTAssertEqual(state.composerPrefillText, "")
        XCTAssertTrue(state.showSidebar, "the Pulse screen stays up to say why")
        // The chat its New Chat made gets the reminder, uncovered.
        state.showSidebar = true
        state.widgetSessionCreatorOverride = { _, _ in ("fresh", "fresh", "default") }
        let opened = await state.actOnPulseCard(date)
        XCTAssertTrue(opened)
        XCTAssertEqual(state.activeSessionId, "fresh")
        XCTAssertFalse(state.showSidebar)
        XCTAssertEqual(state.composerPrefillText, date.actionMessage)
        XCTAssertEqual(state.composerPrefillDraftKey, ComposerBar.composerDraftKey(for: "fresh", profile: "default"))
    }

    func testDoItNeverFillsAChatAnotherCreateOpenedWhileItsOwnWasStarting() async throws {
        let state = try appState()
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"home_chat_id": "pulse_chat", "cards": [
          {"id": 1, "kind": "noticed", "topic": "date", "level": "screen", "news": "Dentist Friday", "chat_id": "pulse_chat"}
        ]}
        """)))
        state.setNotifierPluginStateForTesting(.reported(version: "0.77.0", capabilities: [
            PulseClient.feedCapability, PulseClient.doneCapability, PulseClient.actedCapability,
            PulseClient.foundActionsCapability
        ]))
        state.applyPulseFeed(page)
        let date = try XCTUnwrap(page.cards.first)
        state.isConnected = true
        state.client = HermesClient(connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
                                    profile: "default")
        // Another create (a call's chat, Ask Hermes About) starts while Do
        // it's own is on its way, and opens its chat first.
        var creates = 0
        state.widgetSessionCreatorOverride = { [weak state] _, _ in
            creates += 1
            guard creates == 1 else { return ("other", "other", "default") }
            _ = await state?.createNewSession()
            return ("mine", "mine", "default")
        }
        let opened = await state.actOnPulseCard(date)
        XCTAssertEqual(creates, 2)
        XCTAssertFalse(opened)
        XCTAssertEqual(state.activeSessionId, "other")
        XCTAssertEqual(state.composerPrefillText, "", "the reminder never goes into a chat Do it didn't start")
        XCTAssertFalse(state.isStartingNewChat)
    }

    func testDoItOnAnItemFoundInAChatFillsThatChat() async throws {
        let state = try appState()
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"home_chat_id": "pulse_chat", "cards": [
          {"id": 2, "kind": "noticed", "topic": "fact", "level": "screen", "news": "The repo moved", "chat_id": "work",
           "message_id": 42}
        ]}
        """)))
        state.setNotifierPluginStateForTesting(.reported(version: "0.77.0", capabilities: [
            PulseClient.feedCapability, PulseClient.doneCapability, PulseClient.actedCapability,
            PulseClient.foundActionsCapability
        ]))
        state.applyPulseFeed(page)
        let fact = try XCTUnwrap(page.cards.first)
        var creates = 0
        state.widgetSessionCreatorOverride = { _, _ in
            creates += 1
            return ("fresh", "fresh", "default")
        }
        state.activeSessionId = "work"
        let opened = await state.actOnPulseCard(fact)
        XCTAssertTrue(opened)
        XCTAssertEqual(creates, 0, "an item found in a chat starts no new one")
        XCTAssertEqual(state.pendingArtifactReveal?.messageID, 42)
        XCTAssertEqual(state.composerPrefillText, fact.actionMessage)
        XCTAssertEqual(state.composerPrefillDraftKey, ComposerBar.composerDraftKey(for: "work", profile: "default"))
    }

    func testOpeningACardsChatShowsTheMessageItCameFrom() throws {
        let state = try appState()
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"home_chat_id": "pulse_chat", "cards": [
          {"id": 1, "kind": "followup", "level": "push", "news": "Deck", "chat_id": "work", "message_id": 42},
          {"id": 2, "kind": "followup", "level": "push", "news": "Call", "chat_id": "home"},
          {"id": 3, "kind": "brief", "level": "push", "news": "Morning", "chat_id": "pulse_chat", "message_id": 7}
        ]}
        """)))
        state.applyPulseFeed(page)
        state.openPulseCardChat(page.cards[0])
        XCTAssertEqual(state.pendingArtifactReveal?.messageID, 42)
        XCTAssertEqual(state.pendingArtifactReveal?.opening, "work")
        // No message: the chat lands where it would, not at an older card's.
        state.openPulseCardChat(page.cards[1])
        XCTAssertNil(state.pendingArtifactReveal)
        // Pulse's own chat opens nothing, so nothing waits to scroll.
        state.openPulseCardChat(page.cards[2])
        XCTAssertNil(state.pendingArtifactReveal)
    }

    func testABriefShowsWithTheCardsItBroughtAndFoldsOnceHandled() throws {
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 9, "kind": "noticed", "topic": "date", "level": "screen", "news": "New", "created_at": 300},
          {"id": 8, "kind": "brief", "level": "push", "news": "Two things waited.", "brief": "b2", "created_at": 200},
          {"id": 7, "kind": "followup", "level": "brief", "news": "Deck", "brief": "b2", "created_at": 120, "item_id": 1},
          {"id": 6, "kind": "followup", "level": "brief", "news": "Gym", "brief": "b2", "created_at": 110,
           "dismissed_at": 250},
          {"id": 5, "kind": "brief", "level": "push", "news": "Old", "brief": "b1", "created_at": 100},
          {"id": 4, "kind": "followup", "level": "brief", "news": "Paid", "brief": "b1", "created_at": 50,
           "done_at": 90, "item_id": 2},
          {"id": 3, "kind": "brief", "level": "push", "news": "From an older plugin", "created_at": 40},
          {"id": 2, "kind": "noticed", "topic": "fact", "level": "screen", "news": "Gone", "dismissed_at": 60,
           "created_at": 30}
        ]}
        """)))
        let layout = PulseLayout(cards: page.cards)
        XCTAssertEqual(layout.briefs.map(\.id), [8])
        let brief = try XCTUnwrap(layout.briefs.first)
        XCTAssertEqual(brief.items.map(\.id), [6, 7], "oldest first")
        XCTAssertEqual(brief.left, 1)
        XCTAssertFalse(brief.isHandled)
        XCTAssertEqual(layout.open.map(\.id), [9, 3], "an untagged brief is a card of its own")
        XCTAssertEqual(layout.cleared.map(\.id), [2])
        XCTAssertEqual(layout.clearedBriefs.map(\.id), [5], "an older brief all handled folds into Done and cleared")
        XCTAssertEqual(layout.clearedCount, 2)
        XCTAssertEqual(page.cards.first { $0.id == 6 }?.dismissedAt, Date(timeIntervalSince1970: 250))

        // The newest brief stays at the top, folded, once everything in it is handled.
        var handled = page
        if let index = handled.cards.firstIndex(where: { $0.id == 7 }) { handled.cards[index].doneAt = Date() }
        XCTAssertEqual(PulseLayout(cards: handled.cards).briefs.map(\.isHandled), [true])
        XCTAssertFalse(layout.isCaughtUp)
        XCTAssertTrue(PulseLayout(cards: handled.cards.filter { [8, 7, 6].contains($0.id) }).isCaughtUp)
        // The card a Pulse mark opened stays where it is, though cleared.
        XCTAssertEqual(PulseLayout(cards: page.cards, keeping: [2]).open.map(\.id), [9, 3, 2])
    }

    func testABriefThatBroughtNoCardsShowsAsItsSummary() throws {
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 9, "kind": "brief", "level": "push", "news": "A calm day.", "brief": "b3", "created_at": 300},
          {"id": 8, "kind": "noticed", "topic": "date", "level": "screen", "news": "New", "created_at": 250},
          {"id": 5, "kind": "brief", "level": "push", "news": "Yesterday", "brief": "b2", "created_at": 200}
        ]}
        """)))
        let layout = PulseLayout(cards: page.cards)
        XCTAssertEqual(layout.briefs.map(\.id), [9], "the newest brief stays at the top")
        XCTAssertEqual(layout.briefs.first?.isSummary, true)
        XCTAssertEqual(layout.open.map(\.id), [8])
        XCTAssertEqual(layout.clearedBriefs.map(\.id), [5], "older ones fold into Done and cleared")
        XCTAssertEqual(layout.clearedCount, 1)
        // The one a Pulse mark opened stays where it is.
        XCTAssertEqual(PulseLayout(cards: page.cards, keeping: [5]).briefs.map(\.id), [9, 5])
        let alone = PulseLayout(cards: page.cards.filter { $0.kind == "brief" })
        XCTAssertTrue(alone.open.isEmpty)
        XCTAssertFalse(alone.isCaughtUp, "the summary lists what's still open")
    }

    /// A brief folds to one row once the user folds it, a summary alone and
    /// one with cards left too, and stays folded until it's opened again;
    /// one all handled folds by itself unless opened on this visit. A Pulse
    /// mark pointing into it opens it, and so does a card in it that comes
    /// back open after the fold, from Not now or with Undo, whether or not
    /// it was open at the fold.
    func testABriefFoldsOnceTheUserFoldsItOrOnceItIsAllHandled() throws {
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 9, "kind": "brief", "level": "push", "news": "A calm day.", "brief": "b3", "created_at": 300},
          {"id": 8, "kind": "brief", "level": "push", "news": "Two things waited.", "brief": "b2", "created_at": 200},
          {"id": 7, "kind": "followup", "level": "brief", "news": "Deck", "brief": "b2", "created_at": 120, "item_id": 1},
          {"id": 6, "kind": "followup", "level": "brief", "news": "Gym", "brief": "b2", "created_at": 110,
           "done_at": 250}
        ]}
        """)))
        let layout = PulseLayout(cards: page.cards)
        let summary = try XCTUnwrap(layout.briefs.first { $0.id == 9 })
        let open = try XCTUnwrap(layout.briefs.first { $0.id == 8 })
        XCTAssertEqual(layout.brief(bringing: 7)?.id, 8)
        XCTAssertEqual(layout.brief(bringing: 6)?.id, 8, "done, still the brief's")
        XCTAssertNil(layout.brief(bringing: 8), "a brief brings its cards, not itself")
        XCTAssertEqual(open.openCards, [7: 120], "Gym is done")
        XCTAssertEqual(summary.openCards, [:])
        XCTAssertFalse(summary.isFolded(folded: nil, opened: false, focused: nil), "open until it's folded")
        XCTAssertTrue(summary.isFolded(folded: summary.openCards, opened: false, focused: nil))
        XCTAssertFalse(open.isFolded(folded: nil, opened: false, focused: nil), "a card in it is left")
        XCTAssertTrue(open.isFolded(folded: open.openCards, opened: false, focused: nil))
        XCTAssertFalse(open.isFolded(folded: open.openCards, opened: false, focused: 7),
                       "a Pulse mark pointed at one of its cards")
        XCTAssertFalse(summary.isFolded(folded: summary.openCards, opened: false, focused: 9),
                       "or at the brief itself")

        // Deck, open at the fold, put off with Not now from a Pulse mark: it comes back as new
        // (the host gives it a new created_at), so the brief opens to show it.
        let back = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 8, "kind": "brief", "level": "push", "news": "Two things waited.", "brief": "b2", "created_at": 200},
          {"id": 7, "kind": "followup", "level": "brief", "news": "Deck", "brief": "b2", "created_at": 400, "item_id": 1},
          {"id": 6, "kind": "followup", "level": "brief", "news": "Gym", "brief": "b2", "created_at": 110,
           "done_at": 250}
        ]}
        """)))
        let returned = try XCTUnwrap(PulseLayout(cards: back.cards).briefs.first { $0.id == 8 })
        XCTAssertFalse(returned.isFolded(folded: open.openCards, opened: false, focused: nil))
        XCTAssertTrue(returned.isFolded(folded: returned.openCards, opened: false, focused: nil), "folded again")

        // Gym put back with Undo after the fold: as it came, but open again, so the brief opens too.
        var undone = page
        if let index = undone.cards.firstIndex(where: { $0.id == 6 }) { undone.cards[index].doneAt = nil }
        let putBack = try XCTUnwrap(PulseLayout(cards: undone.cards).briefs.first { $0.id == 8 })
        XCTAssertFalse(putBack.isFolded(folded: open.openCards, opened: false, focused: nil))

        var handled = page
        if let index = handled.cards.firstIndex(where: { $0.id == 7 }) { handled.cards[index].doneAt = Date() }
        let done = try XCTUnwrap(PulseLayout(cards: handled.cards).clearedBriefs.first { $0.id == 8 })
        XCTAssertTrue(done.isFolded(folded: open.openCards, opened: false, focused: nil), "Deck done after the fold")
        // Deck put back with Undo then drops out of the fold (AppState.unfoldPulseCard): open again, it opens the brief.
        XCTAssertFalse(open.isFolded(folded: [:], opened: false, focused: nil))
        XCTAssertEqual(PulseLayout(cards: handled.cards).brief(bringing: 7)?.id, 8, "all handled, among the cleared")
        XCTAssertTrue(done.isFolded(folded: nil, opened: false, focused: nil), "all handled")
        XCTAssertFalse(done.isFolded(folded: nil, opened: true, focused: nil), "opened again on this visit")
    }

    /// A folded brief stays folded across a relaunch, on its own dashboard
    /// only. Opening it forgets the fold, a card in it put back open drops
    /// out of it, only the newest folds are kept besides the one just made,
    /// and a removed dashboard's go with it.
    func testFoldedBriefsAreKeptPerDashboardAcrossLaunches() throws {
        let suite = "PulseFeedTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let active = SavedDashboard(id: UUID(), label: "Home", normalizedURL: "http://127.0.0.1:1")
        let other = SavedDashboard(id: UUID(), label: "Office", normalizedURL: "http://127.0.0.1:2")
        func launch(_ dashboard: SavedDashboard) -> AppState {
            AppState(defaults: defaults, loadSavedConnection: false,
                     dashboardRegistry: SavedDashboardRegistry(activeDashboardID: dashboard.id,
                                                               dashboards: [active, other]),
                     clearSessionPresentationCache: {})
        }
        let morning: [Int: Double] = [5: 1_800_000_000]
        launch(other).foldPulseBrief(3, open: morning)
        let appState = launch(active)
        appState.foldPulseBrief(8, open: morning)
        XCTAssertEqual(launch(active).pulseBriefFold(8), morning, "kept across a relaunch")
        XCTAssertNil(launch(other).pulseBriefFold(8), "another dashboard's card 8 is another brief")
        appState.foldPulseBrief(9, open: [:])
        XCTAssertEqual(launch(active).pulseBriefFold(9), [:], "folded with nothing open")
        appState.foldPulseBrief(8, open: nil)
        XCTAssertNil(launch(active).pulseBriefFold(8), "opened again")

        // Deck, open when the brief was folded, done from a push and put back with Undo: the brief opens to show it.
        appState.foldPulseBrief(4, open: [5: 1_800_000_000, 6: 1_800_000_060])
        appState.unfoldPulseCard(5, in: 4)
        XCTAssertEqual(launch(active).pulseBriefFold(4), [6: 1_800_000_060])
        appState.unfoldPulseCard(5, in: 4)
        XCTAssertEqual(appState.pulseBriefFold(4), [6: 1_800_000_060], "already out of the fold")
        appState.unfoldPulseCard(5, in: 8)
        XCTAssertNil(appState.pulseBriefFold(8), "a brief not folded stays open")

        let kept = AppState.pulseFoldedBriefsKept
        for brief in 1...(kept + 5) { appState.foldPulseBrief(brief, open: morning) }
        XCTAssertNil(appState.pulseBriefFold(5), "only the newest are kept")
        XCTAssertEqual(appState.pulseBriefFold(kept + 5), morning)
        // An older brief folded now stays folded; the oldest other fold goes.
        appState.foldPulseBrief(2, open: morning)
        XCTAssertEqual(appState.pulseBriefFold(2), morning)
        XCTAssertNil(appState.pulseBriefFold(6))
        XCTAssertEqual(appState.pulseBriefFold(7), morning)
        XCTAssertEqual(launch(other).pulseBriefFold(3), morning)

        appState.removeDashboard(other.id)
        let stored = defaults.dictionary(forKey: AppState.pulseFoldedBriefsKey) as? [String: [String: [String: Double]]]
        XCTAssertEqual(stored?.keys.sorted(), [active.id.uuidString])
    }

    func testFeedSaysWhenPulseIsQuiet() throws {
        let quiet = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [], "quiet_now": "day", "quiet_ends_at": 1800000000}
        """)))
        XCTAssertEqual(quiet.quietNow, .day)
        XCTAssertEqual(quiet.quietEndsAt, Date(timeIntervalSince1970: 1_800_000_000))
        // Not quiet, a plugin from before quiet times, or a reason this build doesn't know.
        for body in [#"{"cards": [], "quiet_now": "", "quiet_ends_at": null}"#, #"{"cards": []}"#,
                     #"{"cards": [], "quiet_now": "later", "quiet_ends_at": 5}"#] {
            let page = try XCTUnwrap(PulseFeedPage(json: json(body)))
            XCTAssertNil(page.quietNow)
            XCTAssertNil(page.quietEndsAt)
        }
        XCTAssertEqual(PulseClient.quietCapability, "pulse_quiet")
    }

    func testWrongTimeIsOfferedOnceThePluginPicksTheTimeAndPutsTheCardAway() async throws {
        let state = try appState()
        state.setNotifierPluginStateForTesting(.reported(version: "0.84.0", capabilities: [
            PulseClient.feedCapability, PulseClient.learnsCapability
        ]))
        XCTAssertEqual(state.pulseDownReasons, [.notRelevant, .alreadyKnew, .tooLate, .tooOften])
        state.setNotifierPluginStateForTesting(.reported(version: "0.86.0", capabilities: [
            PulseClient.feedCapability, PulseClient.learnsCapability, PulseClient.hoursCapability
        ]))
        XCTAssertEqual(state.pulseDownReasons, PulseDownReason.allCases)
        XCTAssertEqual(PulseDownReason.wrongTime.rawValue, "wrong_time")
        XCTAssertEqual(PulseDownReason.wrongTime.title, AppLocalization.string("Wrong time"))
        XCTAssertEqual(PulseClient.hoursCapability, "pulse_hours")

        // The plugin answers with when the card comes back, and what it learned.
        var calls: [(path: String, body: [String: Any]?)] = []
        let client = PulseClient { path, _, body in
            calls.append((path, body))
            return ["ok": true, "rest_until": 1_800_000_000, "learned": [
                ["id": 4, "kind": "followup", "what": "part", "value": "evening", "cause": "wrong time"] as [String: Any]
            ]]
        }
        let rated = try await client.rate(card: 9, up: false, reason: .wrongTime)
        XCTAssertEqual(calls.first?.path, "\(PulseClient.path)/rate")
        XCTAssertEqual(calls.first?.body?["reason"] as? String, "wrong_time")
        XCTAssertEqual(rated.restUntil, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(rated.lessons.map(\.id), [4])
        // Any other rating, or a plugin from before, leaves the card where it is.
        let older = PulseClient { _, _, _ in ["ok": true, "learned": [Any]()] }
        let plain = try await older.rate(card: 9, up: false, reason: .tooOften)
        XCTAssertEqual(plain, PulseRated(lessons: [], restUntil: nil))
    }

    func testWrongTimeTeachesNoNotificationsInAPartOfTheDay() throws {
        let learned = try XCTUnwrap(PulseLearned(json: json("""
        {"levels": {}, "lessons": [
          {"id": 1, "kind": "followup", "what": "part", "value": "morning", "cause": "wrong time"},
          {"id": 2, "kind": "followup", "what": "part", "value": "midday", "cause": "wrong time"},
          {"id": 3, "kind": "date", "what": "part", "value": "evening", "cause": "wrong time"},
          {"id": 4, "kind": "followup", "what": "part", "value": "night", "cause": "wrong time"},
          {"id": 5, "kind": "followup", "what": "part", "value": "teatime", "cause": "wrong time"}]}
        """)))
        let followups = PulseCardKind.title("followup")
        XCTAssertEqual(learned.lessons.map(\.text), [
            AppLocalization.string("\(followups): No notifications in the morning"),
            AppLocalization.string("\(followups): No notifications in the middle of the day"),
            AppLocalization.string("\(PulseCardKind.topic("date")): No notifications in the evening"),
            AppLocalization.string("\(followups): No notifications at night"),
            AppLocalization.string("\(followups): No notifications at that time of day")
        ])
        XCTAssertEqual(learned.lessons.first?.causeText, AppLocalization.string("You said wrong time"))
    }

    func testNotNowsLaterTodayEndsWhenTheNightStarts() throws {
        let page = try XCTUnwrap(PulseFeedPage(json: json(#"{"cards": [], "night": ["22:00", "07:00"]}"#)))
        XCTAssertEqual(page.night, PulseNight(start: 22 * 60, end: 7 * 60))
        for body in [#"{"cards": [], "night": []}"#, #"{"cards": []}"#] {
            XCTAssertNil(try XCTUnwrap(PulseFeedPage(json: json(body))).night)  // no night, or a plugin from before
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let midnight = Date(timeIntervalSince1970: 1_799_971_200)  // 2027-01-15 00:00 UTC
        let choices = { (hour: Int, minute: Int, night: PulseNight?) in
            PulseRest.choices(now: midnight.addingTimeInterval(Double(hour * 3600 + minute * 60)), night: night,
                              calendar: calendar)
        }
        let tomorrow: [PulseRest] = [.tomorrow, .nextWeek]
        let night = PulseNight(start: 22 * 60, end: 7 * 60)
        // The plugin gives three hours, by the night's start, and never under half an hour.
        XCTAssertEqual(choices(21, 29, night), PulseRest.allCases)
        XCTAssertEqual(choices(21, 30, night), tomorrow)
        // At night it's the morning brief's time: tomorrow's before midnight, today's after.
        XCTAssertEqual(choices(23, 0, night), tomorrow)
        XCTAssertEqual(choices(2, 0, night), PulseRest.allCases)
        // A night that starts after 23:00, or after midnight, leaves 23:00 the end of today.
        XCTAssertEqual(choices(22, 29, PulseNight(start: 23 * 60 + 30, end: 6 * 60)), PulseRest.allCases)
        XCTAssertEqual(choices(22, 30, PulseNight(start: 23 * 60 + 30, end: 6 * 60)), tomorrow)
        let late = PulseNight(start: 60, end: 8 * 60)
        XCTAssertEqual(choices(22, 30, late), tomorrow)
        XCTAssertEqual(choices(0, 29, late), PulseRest.allCases)
        XCTAssertEqual(choices(0, 30, late), tomorrow)
        XCTAssertEqual(choices(3, 0, late), PulseRest.allCases)
        // No night: by 23:00, as before.
        XCTAssertEqual(choices(22, 29, nil), PulseRest.allCases)
        XCTAssertEqual(choices(22, 30, nil), tomorrow)
        // With the brief's time, at night it's ten minutes before that brief, half an hour away or more:
        // a night past the 07:00 brief has no later today left after it.
        let page07 = try XCTUnwrap(PulseFeedPage(json: json(#"{"cards": [], "brief_time": "07:00"}"#)))
        XCTAssertEqual(page07.briefTime, 7 * 60)
        XCTAssertNil(try XCTUnwrap(PulseFeedPage(json: json(#"{"cards": []}"#))).briefTime)
        let briefed = { (hour: Int, minute: Int, night: PulseNight, brief: Int) in
            PulseRest.choices(now: midnight.addingTimeInterval(Double(hour * 3600 + minute * 60)), night: night,
                              brief: brief, calendar: calendar)
        }
        let longer = PulseNight(start: 23 * 60, end: 8 * 60)
        XCTAssertEqual(briefed(3, 0, longer, 7 * 60), PulseRest.allCases)
        XCTAssertEqual(briefed(6, 20, longer, 7 * 60), PulseRest.allCases)
        XCTAssertEqual(briefed(6, 21, longer, 7 * 60), tomorrow)
        XCTAssertEqual(briefed(7, 30, longer, 7 * 60), tomorrow)
        XCTAssertEqual(briefed(23, 30, longer, 7 * 60), tomorrow)
        // A night over noon, and a brief after it: today's brief is still to come.
        XCTAssertEqual(briefed(12, 30, PulseNight(start: 22 * 60, end: 13 * 60), 14 * 60), PulseRest.allCases)
        // A brief just after midnight: before it, later today would be tomorrow's brief, as Tomorrow is.
        XCTAssertEqual(briefed(22, 30, night, 5), tomorrow)
        // Without the brief's time it's the brief's own 07:00, not the morning's end: a night in the
        // morning, or over noon, has no later today left once 07:00 has gone.
        XCTAssertEqual(choices(6, 20, night), PulseRest.allCases)
        XCTAssertEqual(choices(6, 21, night), tomorrow)
        XCTAssertEqual(choices(10, 30, PulseNight(start: 10 * 60, end: 11 * 60)), tomorrow)
        XCTAssertEqual(choices(12, 30, PulseNight(start: 22 * 60, end: 13 * 60)), tomorrow)
    }

    func testACardIsAwayForWrongTimeOnlyWhileTheRatingPutItAway() throws {
        let card = { (dismissed: Int?, reason: String) throws -> PulseCard in
            let away = dismissed.map { String($0) } ?? "null"
            return try XCTUnwrap(PulseCard(json: self.json("""
            {"id": 3, "kind": "followup", "level": "push", "rating": "down", "reason": "\(reason)",
             "rated_at": 1800000000, "dismissed_at": \(away)}
            """)))
        }
        XCTAssertEqual(try card(1_800_000_000, "wrong_time").ratedAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(try card(1_800_000_000, "wrong_time").isAwayForWrongTime)
        // Put back and swiped away later, it's Not now's; and a card back from its rest isn't away.
        XCTAssertFalse(try card(1_800_003_600, "wrong_time").isAwayForWrongTime)
        XCTAssertFalse(try card(nil, "wrong_time").isAwayForWrongTime)
        XCTAssertFalse(try card(1_800_000_000, "too_often").isAwayForWrongTime)
    }

    func testNotNowPostsTheCardToThePlugin() async throws {
        var calls: [(path: String, body: [String: Any]?)] = []
        let client = PulseClient { path, _, body in
            calls.append((path, body))
            return ["ok": true, "changed": true]
        }
        let answer = try await client.dismiss(card: 4, dismissed: true)
        XCTAssertTrue(answer.changed)
        XCTAssertNil(answer.restUntil)
        XCTAssertEqual(calls.first?.path, "\(PulseClient.path)/dismiss")
        XCTAssertEqual(calls.first?.body?["card"] as? Int, 4)
        XCTAssertEqual(calls.first?.body?["dismissed"] as? Bool, true)
        XCTAssertNil(calls.first?.body?["until"])
    }

    func testNotNowUntilATimeSendsTheChoiceAndReadsWhenItComesBack() async throws {
        var calls: [(path: String, body: [String: Any]?)] = []
        let client = PulseClient { path, _, body in
            calls.append((path, body))
            return ["ok": true, "changed": true, "rest_until": 1_800_000_000]
        }
        let answer = try await client.dismiss(card: 4, dismissed: true, until: .tomorrow)
        XCTAssertEqual(answer, PulseDismissal(changed: true, restUntil: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertEqual(calls.first?.body?["until"] as? String, "tomorrow")
        XCTAssertEqual(PulseRest.allCases.map(\.rawValue), ["later_today", "tomorrow", "next_week"])
        // A card put off carries when it comes back; one swiped away for good doesn't.
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 1, "kind": "noticed", "topic": "date", "level": "screen", "news": "Dentist", "created_at": 30,
           "dismissed_at": 60, "rest_until": 90},
          {"id": 2, "kind": "noticed", "topic": "fact", "level": "screen", "news": "Gone", "dismissed_at": 60,
           "created_at": 30}
        ]}
        """)))
        XCTAssertEqual(page.cards.map(\.restUntil), [Date(timeIntervalSince1970: 90), nil])
        XCTAssertTrue(page.cards.allSatisfy(\.isCleared))
    }

    func testACardPulseMarksDoneWhileItRestsShowsAsDone() throws {
        // Marked done while it's put off, it won't come back at its time: its cleared row says
        // Done, not when it comes back, and Undo there leaves it put off.
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 1, "kind": "followup", "level": "screen", "news": "Call the bank", "item_id": 7, "created_at": 30,
           "dismissed_at": 60, "rest_until": 90, "done_at": 70, "done_by": "pulse"},
          {"id": 2, "kind": "followup", "level": "screen", "news": "Book the car", "item_id": 8, "created_at": 30,
           "dismissed_at": 60, "rest_until": 90},
          {"id": 3, "kind": "followup", "level": "screen", "news": "Pay the rent", "item_id": 9, "created_at": 30,
           "done_at": 70, "done_by": "user"},
          {"id": 4, "kind": "noticed", "topic": "date", "level": "screen", "news": "Concert", "created_at": 30,
           "done_at": 70, "done_by": "pulse"}
        ]}
        """)))
        let cards = page.cards
        XCTAssertEqual(cards.map(\.isResting), [false, true, false, false])
        XCTAssertTrue(cards.allSatisfy(\.isCleared))
        // In whatever language the test host's app is in.
        XCTAssertEqual(cards.map(\.clearedTitle), [
            AppLocalization.string("Done, seen in the chat"),
            AppLocalization.string("Not now") + " · " + PulseRest.backText(Date(timeIntervalSince1970: 90)),
            AppLocalization.string("Done"),
            AppLocalization.string("Done, seen in the chat"),
        ])
        // Undo on the done ones (the one only put off has Put back): the one put off stays put
        // off, a remembered thing is checked on again, and a found item is back on the list.
        XCTAssertEqual(cards.filter { $0.doneAt != nil }.map(\.undoDoneHint), [
            AppLocalization.string("Keeps the card put away"),
            AppLocalization.string("Pulse checks on it again"),
            AppLocalization.string("Puts the card back on the list"),
        ])
    }

    func testTheClearedRowSaysWhenAPutOffCardComesBack() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let noon = Date(timeIntervalSince1970: 1_800_014_400)  // 2027-01-15 12:00 UTC
        let back = { (hours: Double) in
            PulseRest.backText(noon.addingTimeInterval(hours * 3600), now: noon, calendar: calendar)
        }
        // In whatever language the test host's app is in.
        XCTAssertEqual(back(3), AppLocalization.string("Back later today"))
        XCTAssertEqual(back(-1), AppLocalization.string("Back later today"))  // its time came; the plugin brings it back on its next pass
        XCTAssertEqual(back(19), AppLocalization.string("Back tomorrow"))
        let weekday = back(3 * 24)
        XCTAssertFalse(weekday.contains("%@"))
        XCTAssertFalse([back(3), back(19), back(7 * 24)].contains(weekday))
        XCTAssertEqual(back(7 * 24), AppLocalization.string("Back next week"))
        // The Undo bar says the time the plugin set, not the one asked for:
        // later today asked for at 22:40 comes back tomorrow.
        let returning = { (hours: Double) in
            PulseRest.returning(noon.addingTimeInterval(hours * 3600), now: noon, calendar: calendar)
        }
        XCTAssertEqual([returning(3), returning(19), returning(7 * 24 - 1)], [.laterToday, .tomorrow, .nextWeek])
        // Later today isn't offered once the plugin would make it tomorrow.
        XCTAssertEqual(PulseRest.choices(now: noon, calendar: calendar), PulseRest.allCases)
        XCTAssertEqual(PulseRest.choices(now: noon.addingTimeInterval(10.5 * 3600), calendar: calendar), [.tomorrow, .nextWeek])
        XCTAssertEqual(PulseRest.choices(now: noon.addingTimeInterval(10.4 * 3600), calendar: calendar), PulseRest.allCases)
    }

    func testWhatPulseLeftOutSaysWhyEachStayedOut() throws {
        let entries = try XCTUnwrap(json("""
        {"left_out": [
          {"id": 1, "kind": "watch", "text": "The gym at 7", "decision": "quieted", "skip": "", "profile": "",
           "chat_id": "c1", "chat_title": "Deploy", "created_at": 1761033600, "card_id": null,
           "learned": {"scope": "place", "value": "chat::c1", "effect": -0.8, "useful": 0, "votes": 3}},
          {"id": 2, "kind": "date", "text": "Dinner", "decision": "muted"},
          {"id": 3, "kind": "date", "text": "Flight", "decision": "off"},
          {"id": 4, "kind": "fact", "text": "Ana's birthday", "decision": "over_limit", "card_id": 40},
          {"id": 5, "text": "Book the dentist", "decision": "not_picked"},
          {"id": 6, "text": "Water the plants", "decision": "unanswered"},
          {"id": 7, "text": "Call Sam", "decision": "resting", "skip": "rated"},
          {"id": 8, "text": "Pay the rent", "decision": "resting", "skip": "put away"},
          {"id": 9, "text": "Renew the passport", "decision": "skipped", "skip": "done"},
          {"id": 10, "text": "Standup at 9", "decision": "skipped", "skip": "covered"},
          {"id": 11, "text": "The release", "decision": "skipped", "skip": "raised"},
          {"id": 12, "text": "The weather", "decision": "skipped", "skip": "rated"},
          {"id": 13, "text": "A typo", "decision": "skipped", "skip": "minor"},
          {"id": 14, "text": "Something else", "decision": "skipped", "skip": "other"},
          {"id": 15, "text": "", "decision": "not_picked"},
          {"text": "No id", "decision": "not_picked"}]}
        """)["left_out"] as? [Any])

        let found = entries.compactMap(PulseLeftOut.init(json:))
        XCTAssertEqual(found.map(\.id), Array(1...14))
        // What the user taught or set kept these out, so they're listed first.
        XCTAssertEqual(found.filter(\.isKeptOut).map(\.id), [1, 2, 3])
        XCTAssertEqual(found.map(\.reason), [
            AppLocalization.string("What you did with cards like this kept it out"),
            AppLocalization.string("You said things from this chat aren't relevant"),
            AppLocalization.string("You turned this kind off"),
            AppLocalization.string("Picked, but the report was full"),
            AppLocalization.string("Not picked for the report"),
            AppLocalization.string("The report passed over it"),
            AppLocalization.string("Resting after your thumbs down"),
            AppLocalization.string("Resting after you said Not now"),
            AppLocalization.string("Already done"),
            AppLocalization.string("Your calendar, reminders or a scheduled job covers it"),
            AppLocalization.string("Brought up lately, and nothing changed since"),
            AppLocalization.string("You said before that it wasn't useful"),
            AppLocalization.string("Too minor to bring up"),
            AppLocalization.string("Pulse chose to leave it out")
        ])
        let gym = found[0]
        XCTAssertEqual(gym.kind, "watch")
        XCTAssertEqual(gym.chatTitle, "Deploy")
        XCTAssertEqual(gym.createdAt, Date(timeIntervalSince1970: 1761033600))
        XCTAssertEqual(gym.learned?.subject, AppLocalization.string("Things from “\("Deploy")”"))
        XCTAssertNil(gym.cardID)
        // One already brought up says which card it became.
        XCTAssertEqual(found[3].cardID, 40)
        XCTAssertNil(found[1].learned)
        // Before 0.88.0 only reports left things out.
        XCTAssertFalse(found.contains(where: \.isLookAhead))
    }

    func testWhatTheLookAheadLeftOutSaysSo() throws {
        let entries = try XCTUnwrap(json("""
        {"left_out": [
          {"id": 1, "kind": "date", "text": "Sam's birthday", "decision": "over_limit", "from": "look_ahead"},
          {"id": 2, "text": "Pack for Kyoto", "decision": "not_picked", "from": "look_ahead"},
          {"id": 3, "text": "The party", "decision": "unanswered", "from": "look_ahead"},
          {"id": 4, "text": "A gift for Sam", "decision": "skipped", "skip": "done", "from": "look_ahead"},
          {"id": 5, "text": "Book the dentist", "decision": "not_picked", "from": "report"},
          {"id": 6, "text": "Water the plants", "decision": "unanswered", "from": "report"}]}
        """)["left_out"] as? [Any])

        let found = entries.compactMap(PulseLeftOut.init(json:))
        XCTAssertEqual(found.filter(\.isLookAhead).map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(found.map(\.from), ["look_ahead", "look_ahead", "look_ahead", "look_ahead", "report", "report"])
        XCTAssertEqual(found.map(\.reason), [
            AppLocalization.string("Picked, but the look ahead was full"),
            AppLocalization.string("Not picked in the look ahead"),
            AppLocalization.string("The look ahead passed over it"),
            AppLocalization.string("Already done"),
            AppLocalization.string("Not picked for the report"),
            AppLocalization.string("The report passed over it")
        ])
        XCTAssertEqual(PulseClient.datesCapability, "pulse_dates")
    }

    func testPeopleSettingsSayPulseBringsUpBirthdaysWithAPluginThatDoes() throws {
        let state = try appState()
        state.setNotifierPluginStateForTesting(.reported(version: "0.87.1", capabilities: [
            PulseClient.capability, PulseClient.feedCapability
        ]))
        XCTAssertFalse(state.pulseBringsUpBirthdays)
        state.setNotifierPluginStateForTesting(.reported(version: "0.88.0", capabilities: [
            PulseClient.capability, PulseClient.feedCapability, PulseClient.datesCapability
        ]))
        XCTAssertTrue(state.pulseBringsUpBirthdays)
        // Without Pulse on the host, nothing to say.
        state.setNotifierPluginStateForTesting(.reported(version: "0.88.0", capabilities: [PulseClient.datesCapability]))
        XCTAssertFalse(state.pulseBringsUpBirthdays)
    }

    func testADeadlineFromTheShortcutsInboxIsItsOwnCardAndDoItStartsAChat() async throws {
        let state = try appState()
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"home_chat_id": "pulse_chat", "cards": [
          {"id": 3, "kind": "noticed", "topic": "deadline", "item_id": 12, "level": "brief",
           "news": "Netflix free trial ends tomorrow, Wednesday 21 October.", "title": "Netflix free trial ends",
           "quote": "Your free trial ends on 21 October", "chat_id": ""}
        ]}
        """)))
        state.setNotifierPluginStateForTesting(.reported(version: "0.90.0", capabilities: [
            PulseClient.capability, PulseClient.feedCapability, PulseClient.doneCapability,
            PulseClient.actedCapability, PulseClient.inboxCapability
        ]))
        state.applyPulseFeed(page)
        let deadline = try XCTUnwrap(page.cards.first)
        XCTAssertEqual(deadline.heading, AppLocalization.string("Deadline"))
        XCTAssertEqual(PulseCardKind.name("deadline"), AppLocalization.string("Deadlines"))
        // Done closes the deadline, and Do it works on it, though it came from no chat.
        XCTAssertTrue(deadline.canBeDone && deadline.isActionable)
        XCTAssertFalse(deadline.isFound)
        XCTAssertTrue(state.canMarkPulseCardDone(deadline) && state.canActOnPulseCard(deadline))
        XCTAssertFalse(state.pulseCardHasChat(deadline))
        XCTAssertEqual(deadline.actionMessage,
                       "Pulse brought this up: Netflix free trial ends tomorrow, Wednesday 21 October.\n\nHelp me take care of it before then.")
        // Another remembered item with no chat still has nowhere to act.
        let other = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [{"id": 4, "kind": "noticed", "topic": "promise", "item_id": 5, "level": "screen", "news": "x", "chat_id": ""}]}
        """))?.cards.first)
        XCTAssertFalse(other.isActionable)
        // What learning learns about deadlines is about the Shortcuts inbox.
        XCTAssertEqual(PulsePlace.source("inbox"), AppLocalization.string("Shortcuts inbox"))
        XCTAssertEqual(PulsePreference.subject(scope: "place", value: "source:inbox", chatTitle: ""),
                       AppLocalization.string("Things from “\(AppLocalization.string("Shortcuts inbox"))”"))
        // Do it starts a chat in Pulse's profile and fills it.
        state.isConnected = true
        state.client = HermesClient(connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
                                    profile: "default")
        state.widgetSessionCreatorOverride = { _, _ in ("fresh", "fresh", "default") }
        let opened = await state.actOnPulseCard(deadline)
        XCTAssertTrue(opened)
        XCTAssertEqual(state.activeSessionId, "fresh")
        XCTAssertEqual(state.composerPrefillText, deadline.actionMessage)
    }

    func testANextStepIsItsOwnCardWithALevelOfItsOwn() throws {
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 5, "kind": "noticed", "topic": "next", "level": "brief", "item_id": null,
           "news": "Book the hotel for the 12th to the 15th.", "title": "Book the hotel", "chat_id": "trip",
           "why": "You booked the flights in Trip plan this morning; nothing shows a hotel."}
        ], "levels": {"followup": "push", "deadline": "brief", "next": "brief"}}
        """)))
        let next = try XCTUnwrap(page.cards.first)
        XCTAssertEqual(next.heading, AppLocalization.string("Next step"))
        XCTAssertEqual(PulseCardKind.name("next"), AppLocalization.string("Next steps"))
        // Pulse's own idea, held for the morning brief by default.
        XCTAssertTrue(next.isFound && next.isHeld)
        XCTAssertEqual(page.levels["next"], .brief)
        XCTAssertEqual(next.actionMessage,
                       "Pulse reminded me: Book the hotel for the 12th to the 15th.\n\nLet's take care of it now.")
        XCTAssertNil(next.backText())
    }

    func testACardBackAfterAStalledDoItSaysWhenDoItWasTapped() throws {
        let card = { (back: String) throws -> PulseCard in
            try XCTUnwrap(PulseCard(json: self.json("""
            {"id": 7, "kind": "followup", "level": "brief", "news": "x",
             "why": "You tapped Do it yesterday but didn't send it.", "back": "\(back)", "back_acted_at": 1800000000}
            """)))
        }
        // The next calendar day, whatever a clock change in between.
        let now = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertEqual(try card("unsent").backActedAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(try card("unsent").backText(now: now), "You tapped Do it yesterday but didn't send it.")
        XCTAssertEqual(try card("not_done").backText(now: now), "You tapped Do it yesterday, and it isn't done yet.")
        // One that never came back, or from a plugin before 0.107.0, keeps the plugin's why.
        XCTAssertNil(try card("").backText(now: now))
        XCTAssertNil(try card("later").backText(now: now))
        XCTAssertNil(try XCTUnwrap(PulseCard(json: json(#"{"id": 8, "kind": "followup", "why": "x"}"#))).backText(now: now))
    }

    func testTheShortcutsInboxSaysPulseKeepsDeadlinesWithAPluginThatDoes() throws {
        let state = try appState()
        state.setNotifierPluginStateForTesting(.reported(version: "0.88.0", capabilities: [
            PulseClient.capability, PulseClient.feedCapability
        ]))
        XCTAssertFalse(state.pulseKeepsInboxDeadlines)
        state.setNotifierPluginStateForTesting(.reported(version: "0.90.0", capabilities: [
            PulseClient.capability, PulseClient.feedCapability, PulseClient.inboxCapability
        ]))
        XCTAssertTrue(state.pulseKeepsInboxDeadlines)
        XCTAssertEqual(PulseClient.inboxCapability, "pulse_inbox")
        // Without Pulse on the host, nothing to say.
        state.setNotifierPluginStateForTesting(.reported(version: "0.90.0", capabilities: [PulseClient.inboxCapability]))
        XCTAssertFalse(state.pulseKeepsInboxDeadlines)
    }

    /// The page's caption speaks only for an inbox Pulse reads: the active
    /// dashboard's, in Pulse's own profile. A page still showing another
    /// dashboard's inbox, or another profile's, says nothing.
    func testTheShortcutsInboxCaptionIsOnlyForTheInboxPulseReads() throws {
        let suite = "PulseFeedTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let dashboard = SavedDashboard(id: UUID(), label: "Home", normalizedURL: "http://127.0.0.1:1")
        let state = AppState(defaults: defaults, loadSavedConnection: false,
                             dashboardRegistry: SavedDashboardRegistry(activeDashboardID: dashboard.id,
                                                                       dashboards: [dashboard]),
                             clearSessionPresentationCache: {})
        state.setNotifierPluginStateForTesting(.reported(version: "0.90.0", capabilities: [
            PulseClient.capability, PulseClient.feedCapability, PulseClient.inboxCapability
        ]))
        XCTAssertTrue(state.pulseKeepsDeadlines(from: ShortcutInboxScope(dashboardID: dashboard.id, profile: "Default")))
        XCTAssertFalse(state.pulseKeepsDeadlines(from: ShortcutInboxScope(dashboardID: dashboard.id, profile: "work")))
        XCTAssertFalse(state.pulseKeepsDeadlines(from: ShortcutInboxScope(dashboardID: UUID(), profile: "default")))
        XCTAssertFalse(state.pulseKeepsDeadlines(from: nil))
        state.setNotifierPluginStateForTesting(.reported(version: "0.88.0", capabilities: [
            PulseClient.capability, PulseClient.feedCapability
        ]))
        XCTAssertFalse(state.pulseKeepsDeadlines(from: ShortcutInboxScope(dashboardID: dashboard.id, profile: "default")))
    }

    func testResetLeftOutAndBringUpReachThePlugin() async throws {
        var calls: [(path: String, method: String, body: [String: Any]?)] = []
        var answer = try json(#"{"ok": true, "levels": {}, "lessons": [], "preferences": []}"#)
        let client = PulseClient { path, method, body in
            calls.append((path, method, body))
            return answer
        }
        let raw = try json(#"{"scope": "place", "value": "chat::c1", "effect": -1.0}"#)
        let chat = try XCTUnwrap(PulsePreference(json: raw))

        _ = try await client.reset(chat)
        _ = try await client.reset(nil)
        answer = try json(#"{"ok": true, "left_out": [{"id": 3, "text": "The gym at 7", "decision": "not_picked"}, {"id": 4}]}"#)
        let left = try await client.leftOut()
        XCTAssertEqual(left.map(\.id), [3])
        answer = try json(#"{"ok": true, "card": {"id": 21, "kind": "noticed", "topic": "watch", "level": "screen", "news": "The gym at 7"}}"#)
        let card = try await client.bringUp(3)
        XCTAssertEqual(card.id, 21)

        XCTAssertEqual(calls.map(\.path), [
            "\(PulseClient.path)/learned/reset", "\(PulseClient.path)/learned/reset",
            "\(PulseClient.path)/left_out", "\(PulseClient.path)/left_out/bring_up"
        ])
        XCTAssertEqual(calls.map(\.method), ["POST", "POST", "GET", "POST"])
        XCTAssertEqual(calls[0].body?["scope"] as? String, "place")
        XCTAssertEqual(calls[0].body?["value"] as? String, "chat::c1")
        // Start over forgets everything.
        XCTAssertEqual(calls[1].body?["scope"] as? String, "everything")
        XCTAssertEqual(calls[1].body?["value"] as? String, "")
        XCTAssertNil(calls[2].body)
        XCTAssertEqual(calls[3].body?["id"] as? Int, 3)

        // An answer without its list or card is no answer.
        answer = try json(#"{"ok": true}"#)
        do {
            _ = try await client.leftOut()
            XCTFail("an answer without left_out")
        } catch {}
        do {
            _ = try await client.bringUp(3)
            XCTFail("an answer without a card")
        } catch {}
    }

    // MARK: Look first, then ask (0.96.0, 0.98.0)

    func testASuggestionIsItsOwnCardAndSaysWhereItStands() throws {
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 1, "kind": "proposal", "level": "screen", "title": "Add to Personal: Dinner at Nopa, Sat 25 Oct, 19:00 to 21:00",
           "why": "Pulse suggested this in its report.", "chat_id": "pulse",
           "proposal": {"id": 4, "kind": "add_event", "line": "Add to Personal: Dinner at Nopa, Sat 25 Oct, 19:00 to 21:00",
                        "state": "waiting", "expires_at": 1761400000}},
          {"id": 2, "kind": "proposal", "level": "screen", "title": "Add to Errands: Call the bank",
           "proposal": {"id": 5, "kind": "add_reminder", "line": "Add to Errands: Call the bank", "state": "adding",
                        "change_id": "ch_add"}},
          {"id": 3, "kind": "proposal", "level": "screen", "title": "x",
           "proposal": {"id": 6, "kind": "add_event", "line": "x", "state": "added", "change_id": "ch_a"}},
          {"id": 4, "kind": "proposal", "level": "screen", "title": "x",
           "proposal": {"id": 7, "kind": "add_event", "line": "x", "state": "failed", "note": "No access to Calendar",
                        "change_id": "ch_f"}},
          {"id": 5, "kind": "proposal", "level": "screen", "title": "x", "dismissed_at": 1761000000,
           "proposal": {"id": 8, "kind": "add_event", "line": "x", "state": "not_added"}},
          {"id": 6, "kind": "proposal", "level": "screen", "title": "x",
           "proposal": {"id": 9, "kind": "add_reminder", "line": "x", "state": "removing", "change_id": "ch_r",
                        "undo_id": "ch_u"}},
          {"id": 7, "kind": "proposal", "level": "screen", "title": "Add: Something",
           "proposal": {"id": 10, "kind": "add_event", "line": "x", "state": "something_new"}}
        ]}
        """)))
        let waiting = page.cards[0], adding = page.cards[1], added = page.cards[2], failed = page.cards[3]
        let notAdded = page.cards[4], removing = page.cards[5], unknown = page.cards[6]
        XCTAssertTrue(page.cards.allSatisfy(\.isProposal))
        XCTAssertEqual(waiting.heading, AppLocalization.string("Suggestion"))
        XCTAssertEqual(waiting.proposal?.id, 4)
        XCTAssertEqual(waiting.proposal?.line, "Add to Personal: Dinner at Nopa, Sat 25 Oct, 19:00 to 21:00")
        XCTAssertEqual(waiting.proposal?.expiresAt, Date(timeIntervalSince1970: 1_761_400_000))
        XCTAssertNil(waiting.proposal?.changeID)
        XCTAssertTrue(waiting.proposal?.isEvent == true)
        XCTAssertFalse(adding.proposal?.isEvent == true)
        // Nothing to rate, mark done or act on in a chat: Add and Not now are its buttons.
        XCTAssertFalse(waiting.isRatable || waiting.canBeDone || waiting.isActionable)
        // Waiting and on its way it's open; settled, added or not, it's cleared.
        XCTAssertFalse(waiting.isCleared)
        XCTAssertFalse(adding.isCleared)
        XCTAssertTrue(added.isCleared && failed.isCleared && notAdded.isCleared && removing.isCleared)
        XCTAssertEqual(adding.proposal?.changeID, "ch_add")
        XCTAssertEqual(removing.proposal?.undoID, "ch_u")
        XCTAssertTrue(adding.proposal?.isInFlight == true && removing.proposal?.isInFlight == true)
        // Undo once it's on the phone, not before or after.
        XCTAssertEqual(page.cards.compactMap(\.proposal).filter(\.canUndo).map(\.id), [6])
        XCTAssertEqual(added.proposal?.stateText, AppLocalization.string("Added to your calendar"))
        XCTAssertEqual(adding.proposal?.stateText, AppLocalization.string("Adding…"))
        XCTAssertEqual(failed.proposal?.stateText, AppLocalization.string("Couldn't add it"))
        XCTAssertEqual(failed.proposal?.note, "No access to Calendar")
        XCTAssertEqual(removing.proposal?.stateText, AppLocalization.string("Removing…"))
        XCTAssertEqual(PulseProposal(json: ["id": 1, "kind": "add_reminder", "state": "removed"])?.stateText,
                       AppLocalization.string("Removed from your reminders"))
        // A state this app doesn't know: no buttons, and out of the way.
        XCTAssertNil(unknown.proposal)
        XCTAssertTrue(unknown.isCleared)
        XCTAssertEqual(PulseProposal.kind, "proposal")

        // Never one of a brief's cards, even one naming a brief: Add and Undo are on its own card.
        let briefed = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 9, "kind": "brief", "level": "push", "news": "Morning.", "brief": "b1", "created_at": 200},
          {"id": 8, "kind": "followup", "level": "brief", "news": "Deck", "brief": "b1", "created_at": 120},
          {"id": 1, "kind": "proposal", "level": "screen", "title": "Add: Dinner", "brief": "b1", "created_at": 210,
           "proposal": {"id": 4, "kind": "add_event", "line": "Add: Dinner", "state": "waiting"}}
        ]}
        """)))
        let layout = PulseLayout(cards: briefed.cards)
        XCTAssertEqual(layout.briefs.map(\.id), [9])
        XCTAssertEqual(layout.briefs.first?.items.map(\.id), [8])
        XCTAssertEqual(layout.open.map(\.id), [1])
    }

    func testSuggestionsReachThePluginAndTheFeedAsksForThem() async throws {
        var calls: [(path: String, method: String, body: [String: Any]?)] = []
        var answer = try json(#"{"ok": true, "cards": [], "unseen": 0}"#)
        let client = PulseClient { path, method, body in
            calls.append((path, method, body))
            return answer
        }
        _ = try await client.feed(proposals: true)
        _ = try await client.feed()
        answer = try json(#"{"ok": true, "proposal": {"id": 4, "kind": "add_event", "line": "Add: Dinner", "state": "adding", "change_id": "ch_1"}}"#)
        let adding = try await client.addProposal(4)
        XCTAssertEqual(adding.state, .adding)
        XCTAssertEqual(adding.changeID, "ch_1")
        answer = try json(#"{"ok": true, "proposal": {"id": 4, "kind": "add_event", "line": "Add: Dinner", "state": "removing", "change_id": "ch_1", "undo_id": "ch_2"}}"#)
        let removing = try await client.undoProposal(4)
        XCTAssertEqual(removing.undoID, "ch_2")
        answer = try json(#"{"ok": true, "proposal": {"id": 5, "kind": "add_reminder", "line": "Add: Milk", "state": "not_added"}}"#)
        let dismissed = try await client.dismissProposal(5)
        XCTAssertEqual(dismissed.state, .notAdded)

        XCTAssertEqual(calls.map(\.path), [
            "\(PulseClient.path)/feed?proposals=1", "\(PulseClient.path)/feed",
            "\(PulseClient.path)/proposals/4/add", "\(PulseClient.path)/proposals/4/undo",
            "\(PulseClient.path)/proposals/5/dismiss"
        ])
        XCTAssertEqual(calls.map(\.method), ["GET", "GET", "POST", "POST", "POST"])

        // Seen for every card takes the suggestion cards only when the screen shows them.
        calls = []
        answer = try json(#"{"ok": true, "seen": 2}"#)
        try await client.markSeen(nil, proposals: true)
        try await client.markSeen(nil)
        XCTAssertEqual(calls.map(\.path), ["\(PulseClient.path)/feed/seen", "\(PulseClient.path)/feed/seen"])
        XCTAssertNotNil(calls[0].body?["ids"] as? NSNull)
        XCTAssertEqual(calls[0].body?["proposals"] as? Bool, true)
        XCTAssertNil(calls[1].body?["proposals"])

        // An answer without the suggestion is no answer.
        answer = try json(#"{"ok": true}"#)
        do {
            _ = try await client.addProposal(4)
            XCTFail("an answer without a proposal")
        } catch {}
    }

    func testLookUpsAndSuggestionsGoWithAPluginThatHasThem() throws {
        let state = try appState()
        state.setNotifierPluginStateForTesting(.reported(version: "0.90.0", capabilities: [
            PulseClient.capability, PulseClient.feedCapability
        ]))
        XCTAssertFalse(state.pulseLooksFirst)
        XCTAssertFalse(state.pulseSuggests)
        // The look-ups came first (0.96.0); suggestions with them (0.98.0).
        state.setNotifierPluginStateForTesting(.reported(version: "0.96.0", capabilities: [
            PulseClient.capability, PulseClient.feedCapability, PulseClient.lookCapability
        ]))
        XCTAssertTrue(state.pulseLooksFirst)
        XCTAssertFalse(state.pulseSuggests)
        state.setNotifierPluginStateForTesting(.reported(version: "0.98.0", capabilities: [
            PulseClient.capability, PulseClient.feedCapability, PulseClient.lookCapability,
            PulseClient.proposalsCapability
        ]))
        XCTAssertTrue(state.pulseSuggests)
        XCTAssertEqual(PulseClient.lookCapability, "pulse_look")
        XCTAssertEqual(PulseClient.proposalsCapability, "pulse_proposals")
    }

    func testWhySaysWhatPulseLookedAtFirst() throws {
        let state = try appState()
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 1, "kind": "noticed", "topic": "date", "level": "screen", "news": "Dinner at Nopa at 19:00",
           "why": "", "looked": ["calendar", "maps", "something_new"]},
          {"id": 2, "kind": "noticed", "topic": "date", "level": "screen", "news": "Dentist Friday", "why": ""},
          {"id": 3, "kind": "noticed", "topic": "date", "level": "screen", "news": "x", "looked": ["something_new"]}
        ]}
        """)))
        let looked = page.cards[0], plain = page.cards[1], unknown = page.cards[2]
        XCTAssertEqual(looked.looked, ["calendar", "maps", "something_new"])
        let names = [AppLocalization.string("your calendar"), AppLocalization.string("Maps")]
        let list = names.formatted(.list(type: .and).locale(AppLocalization.formattingLocale))
        XCTAssertEqual(looked.lookedText, AppLocalization.string("Before writing this, Pulse looked at \(list)."))
        XCTAssertNil(plain.lookedText)
        XCTAssertNil(unknown.lookedText)
        // Why? shows it once the plugin looks things up.
        state.setNotifierPluginStateForTesting(.reported(version: "0.90.0", capabilities: [
            PulseClient.feedCapability, PulseClient.cardWhyCapability
        ]))
        XCTAssertFalse(state.explainsPulseCard(looked))
        state.setNotifierPluginStateForTesting(.reported(version: "0.96.0", capabilities: [
            PulseClient.feedCapability, PulseClient.cardWhyCapability, PulseClient.lookCapability
        ]))
        XCTAssertTrue(state.explainsPulseCard(looked))
        XCTAssertFalse(state.explainsPulseCard(plain))
        XCTAssertFalse(state.explainsPulseCard(unknown))
        for label in ["calendar", "phone", "contacts", "maps", "web", "location"] {
            XCTAssertNotNil(PulseCardKind.lookedSource(label), label)
        }
        XCTAssertEqual(PulseCardKind.lookedSource("location"), AppLocalization.string("where you are"))
    }
}
