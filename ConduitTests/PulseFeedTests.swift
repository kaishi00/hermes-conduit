//
//  PulseFeedTests.swift
//  Conduit
//
//  The Pulse screen reads the notifier plugin's /pulse/feed and
//  /pulse/learned as pulse_learning.py writes them: cards, the unseen
//  count, each kind's loudness and the lessons ratings made.
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
          {"id": 6, "kind": "followup"}]}
        """)))

        XCTAssertEqual(learned.levels, ["followup": .screen])
        XCTAssertEqual(learned.lessons.map(\.id), [1, 2, 3, 4, 5])
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

        // Before 0.80.3 thumbs move the levels; a plugin that learns says the level is the loudest Pulse gets.
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
        // The card a push opened stays where it is, though cleared.
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
        // The one a push opened stays where it is.
        XCTAssertEqual(PulseLayout(cards: page.cards, keeping: [5]).briefs.map(\.id), [9, 5])
        let alone = PulseLayout(cards: page.cards.filter { $0.kind == "brief" })
        XCTAssertTrue(alone.open.isEmpty)
        XCTAssertFalse(alone.isCaughtUp, "the summary lists what's still open")
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
}
