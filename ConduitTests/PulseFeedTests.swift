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
        XCTAssertFalse(report.isRatable)
        XCTAssertEqual(report.heading, PulseCardKind.title("report"))
        XCTAssertEqual(PulseCardKind.topic("something new"), PulseCardKind.topic(""))  // unknown topics read "Noticed"
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
}
