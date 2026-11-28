//
//  HermesAutoAnswerTests.swift
//  ConduitTests
//
//  "Answer automatically" for calls from Hermes (issue 3421). In
//  VoiceConversationControllerTests, like HermesRingtoneTests.swift, as the
//  unit suite is at its class cap.
//

import XCTest
@testable import Conduit

extension VoiceConversationControllerTests {
    private func autoAnswerDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "HermesAutoAnswerTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testCallsAnswerByHandUntilAWaitIsPicked() {
        let store = HermesAutoAnswerStore(defaults: autoAnswerDefaults())
        XCTAssertEqual(store.choice(profile: "furina"), .off)
        XCTAssertNil(HermesAutoAnswer.off.delay)
        // A wait a later build offers and this one doesn't.
        store.defaults.set([HermesAutoAnswerStore.bot("furina"): 7], forKey: HermesAutoAnswerStore.botsKey)
        XCTAssertEqual(store.choice(profile: "furina"), .off)
    }

    func testEachBotKeepsItsOwnAutoAnswer() {
        let store = HermesAutoAnswerStore(defaults: autoAnswerDefaults())
        store.set(.after5, profile: "Furina")
        XCTAssertEqual(store.choice(profile: "furina"), .after5, "A bot is its profile, as for its contact's address")
        XCTAssertEqual(store.choice(profile: "furina").delay, .seconds(5))
        XCTAssertEqual(store.choice(profile: "nova"), .off, "Other bots still ring until answered")
        store.set(.after3, profile: nil)
        XCTAssertEqual(store.choice(profile: nil), .after3, "The main profile has its own")
        XCTAssertEqual(store.choice(profile: "default"), .after3, "Settings names the main profile; its call may name none")
        XCTAssertEqual(store.choice(profile: " "), .after3)
        XCTAssertEqual(store.choice(profile: "furina"), .after5)
        store.set(.off, profile: "furina")
        store.set(.off, profile: nil)
        XCTAssertNil(store.defaults.object(forKey: HermesAutoAnswerStore.botsKey), "Nothing kept once every bot is off")
    }

    func testAnotherCallKeepsACallFromAnsweringByItself() {
        let id = UUID()
        XCTAssertFalse(HermesNativeCalls.otherCallBlocksAutoAnswer(id, calls: [(uuid: id, hasEnded: false)]), "Its own call doesn't count")
        XCTAssertFalse(HermesNativeCalls.otherCallBlocksAutoAnswer(id, calls: [(uuid: id, hasEnded: false), (uuid: UUID(), hasEnded: true)]), "An ended call doesn't either")
        XCTAssertTrue(HermesNativeCalls.otherCallBlocksAutoAnswer(id, calls: [(uuid: id, hasEnded: false), (uuid: UUID(), hasEnded: false)]), "A cellular call would go on hold")
    }

    func testARecentsCallFindsItsBot() {
        let bots = ["default", "Furina", "nova.dev"]
        XCTAssertEqual(HermesNativeCalls.profile(calling: "hermes+furina@hermesconduit.app", among: bots), "Furina", "The address folds case: matched to the bot, not read back")
        XCTAssertEqual(HermesNativeCalls.profile(calling: " HERMES+default@hermesconduit.app ", among: bots), "default")
        XCTAssertEqual(HermesNativeCalls.profile(calling: "hermes+nova.dev@hermesconduit.app", among: bots), "nova.dev")
        XCTAssertNil(HermesNativeCalls.profile(calling: "hermes@hermesconduit.app", among: bots), "A call naming no bot")
        XCTAssertNil(HermesNativeCalls.profile(calling: "hermes+atlas@hermesconduit.app", among: bots), "A bot not on this dashboard")
        XCTAssertNil(HermesNativeCalls.profile(calling: "furina@example.com", among: bots))
    }
}
