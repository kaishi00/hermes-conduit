//
//  PresentedScreensTests.swift
//  ConduitTests
//
//  Confirmations Hermes asks the phone to present (PresentedScreens.swift).
//  An extension of an existing class, so the test planner needs no new entry.
//

import CoreLocation
import XCTest
@testable import Conduit

extension AppStateVoiceCapabilityTests {
    func testPresentedConfirmParsesTheHostsPrompt() throws {
        let prompt = try XCTUnwrap(PresentedConfirm(json: [
            "id": "p1", "title": " Send to Mei? ", "preview": "**Hi Mei**, running late.",
            "action_label": "Send", "spoken_yes": ["send it", " ", "go ahead"], "session_id": "",
            "expires_at": Date().addingTimeInterval(60).timeIntervalSince1970,
        ]))
        XCTAssertEqual(prompt.title, "Send to Mei?")
        XCTAssertEqual(prompt.actionLabel, "Send")
        XCTAssertEqual(prompt.spokenYes, ["send it", "go ahead"])
        XCTAssertNil(prompt.sessionID)
        XCTAssertFalse(prompt.isExpired())
        XCTAssertNil(PresentedConfirm(json: ["id": "p2", "title": "  "]))
        XCTAssertNil(PresentedConfirm(json: ["title": "No id"]))
    }

    func testPresentedConfirmNeedsTheUsersOwnYes() {
        let prompt = PresentedConfirm(id: "p1", title: "Send to Mei?", preview: "", actionLabel: "Send", spokenYes: ["send it"])
        XCTAssertTrue(prompt.isConfirmed(by: "yes"))
        XCTAssertTrue(prompt.isConfirmed(by: "Send it."))
        XCTAssertTrue(prompt.isConfirmed(by: "Yes, send it please"))
        XCTAssertFalse(prompt.isConfirmed(by: "send it?"))
        XCTAssertFalse(prompt.isConfirmed(by: "don't send it"))
        XCTAssertFalse(prompt.isConfirmed(by: "send it to Alex instead"))
        XCTAssertFalse(prompt.isConfirmed(by: "what does it say"))
        XCTAssertFalse(prompt.isConfirmed(by: ""))
    }

    func testAVoiceConfirmNeedsWordsFromAfterThePanelAndYieldsToATap() async throws {
        let suite = "present-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sync = PresentedScreensSync(defaults: defaults)
        await sync.sync(scope: "host|default", profile: "default", installationID: "install-1") { _, _ in
            ["ok": true, "prompts": [["id": "p1", "title": "Send?", "preview": "Hi", "action_label": "Send",
                                      "spoken_yes": ["send it"]]]]
        }
        let prompt = try XCTUnwrap(sync.prompts.first)

        // A yes from before the panel appeared answers something else.
        let earlier = UUID()
        sync.noteShown(prompt.id, userTurn: earlier)
        var confirmed = false
        let stale = await PresentVoiceTool.run(["action": "confirm", "id": prompt.id], sync: sync,
                                               lastUserTurn: { (earlier, "yes") }) { _, _ in confirmed = true }
        XCTAssertNotNil(stale["error"])
        XCTAssertFalse(confirmed)

        // Tapped Not now while the spoken words were on their way: the tap stands.
        var calls = 0
        let tapped = await PresentVoiceTool.run(["action": "confirm", "id": prompt.id], sync: sync, lastUserTurn: {
            calls += 1
            if calls == 1 {
                sync.answer(prompt, outcome: .declined, via: .tap)
                return (UUID(), "hmm")
            }
            return (UUID(), "yes")
        }) { _, _ in confirmed = true }
        XCTAssertNotNil(tapped["error"])
        XCTAssertFalse(confirmed)
        XCTAssertTrue(sync.prompts.isEmpty)

        // A second tap on the panel already gone doesn't change the answer.
        sync.answer(prompt, outcome: .confirmed, via: .tap)
        let all = defaults.dictionary(forKey: "conduit.presentedScreens.results.v1") as? [String: [[String: Any]]]
        XCTAssertEqual(all?["host|default"]?.first?["outcome"] as? String, "declined")
    }

    func testAGoConfirmationCarriesWhereMapsOpens() async throws {
        let prompt = try XCTUnwrap(PresentedConfirm(json: [
            "id": "p1", "title": "Directions to Heathrow?", "action_label": "Go",
            "maps": ["to": " Heathrow Terminal 5 ", "mode": "transit"],
        ]))
        XCTAssertEqual(prompt.maps, PresentedMapsTarget(to: "Heathrow Terminal 5", mode: .transit))
        XCTAssertEqual(PresentedConfirm(json: ["id": "p2", "title": "Go?", "maps": ["to": "Paris"]])?.maps?.mode, .driving)
        XCTAssertNil(PresentedConfirm(json: ["id": "p3", "title": "Go?", "maps": ["to": "Paris", "mode": "rocket"]])?.maps)
        XCTAssertEqual(PresentedConfirm(json: ["id": "p5", "title": "Go?", "maps": ["to": "Paris", "mode": "Walking"]])?.maps?.mode, .walking)
        XCTAssertNil(PresentedConfirm(json: ["id": "p4", "title": "Send?"])?.maps)

        // Each exchange tells the host this Conduit opens Apple Maps for them.
        let suite = "present-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var sent: [String: Any] = [:]
        await PresentedScreensSync(defaults: defaults).sync(scope: "host|default", profile: "default",
                                                            installationID: "install-1") { _, body in
            sent = body
            return ["ok": true, "prompts": []]
        }
        XCTAssertEqual(sent["features"] as? [String], ["maps-navigate", "show-cards", "chat-cards", "info-cards", "media-cards", "live-cards"])
    }

    func testMapsOpensWithDirectionsFromALinkOnlyItMade() throws {
        let to = CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12)
        XCTAssertEqual(MapsNavigator.mapsURL(to: to, mode: .walking)?.absoluteString, "maps://?daddr=51.500000,-0.120000&dirflg=w")
        XCTAssertEqual(MapsNavigator.mapsURL(to: to, mode: .cycling)?.absoluteString, "maps://?daddr=51.500000,-0.120000")
        let url = try XCTUnwrap(MapsNavigator.mapsURL(to: to, mode: .driving))
        XCTAssertEqual(MapsNavigator.url(fromNotification: [MapsNavigator.urlKey: url.absoluteString]), url)
        XCTAssertNil(MapsNavigator.url(fromNotification: [MapsNavigator.urlKey: "https://example.com"]))
        XCTAssertNil(MapsNavigator.url(fromNotification: ["aps": [:]]))
    }

    func testOnlyASentNavigateOpensMapsWithoutATap() {
        let sent = #"{"ok": true, "action": "navigate", "status": "sent", "prompt_id": "p1", "to": "Paris"}"#
        XCTAssertEqual(AppState.mapsNavigatePromptID(sent), "p1")
        XCTAssertNil(AppState.mapsNavigatePromptID(#"{"ok": true, "action": "directions", "to": "navigate street"}"#))
        XCTAssertNil(AppState.mapsNavigatePromptID(#"{"ok": false, "action": "navigate", "error": "not_set_up"}"#))
        XCTAssertNil(AppState.mapsNavigatePromptID("navigate"))
        XCTAssertNil(AppState.mapsNavigatePromptID(nil))
    }

    func testAnExpiredConfirmIsntShown() {
        let prompt = PresentedConfirm(id: "p1", title: "Buy it?", preview: "", actionLabel: "Buy",
                                      expiresAt: Date().addingTimeInterval(-1))
        XCTAssertTrue(prompt.isExpired())
    }

    func testHermesCardsAreHandedOnOnceAndNotFromBeforeTheApp() async throws {
        let suite = "present-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sync = PresentedScreensSync(defaults: defaults)
        var handed: [[String]] = []
        sync.onCards = { cards in handed.append(cards.map(\.id)) }
        var cards: [[String: Any]] = [["id": "old", "title": "Before", "markdown": "| a |"]]
        let exchange: PresentedScreensSync.Request = { _, _ in ["ok": true, "prompts": [], "cards": cards] }

        await sync.sync(scope: "host|default", profile: "default", installationID: "install-1", request: exchange)
        XCTAssertEqual(handed, [], "a card from before this app's first exchange was for another conversation")

        cards.append(["id": "new", "title": "Forecast", "markdown": " | Mon | 20 | "])
        cards.append(["id": "empty", "title": "Nothing", "markdown": "  "])
        await sync.sync(scope: "host|default", profile: "default", installationID: "install-1", request: exchange)
        await sync.sync(scope: "host|default", profile: "default", installationID: "install-1", request: exchange)
        XCTAssertEqual(handed, [["new"]], "once, and never a card with nothing to show")
        XCTAssertEqual(PresentedCard(json: cards[1]), PresentedCard(id: "new", title: "Forecast", markdown: "| Mon | 20 |"))

        // Another host or profile starts over.
        await sync.sync(scope: "host|bot", profile: "bot", installationID: "install-1", request: exchange)
        XCTAssertEqual(handed, [["new"]])
    }

    func testAHermesCardDrawsItsPlacesAndLeavesOutTheirOwnText() throws {
        let map: [String: Any] = ["type": "map", "places": [["name": "Kin Khao", "lat": 37.7853, "lon": -122.4089]]]
        let drawn = try XCTUnwrap(PresentedCard(json: [
            "id": "dinner", "title": "Dinner", "markdown": "- **Kin Khao**", "cards": [map], "fallback": true,
        ]))
        XCTAssertEqual(drawn.cards.count, 1)
        XCTAssertEqual(drawn.markdown, "", "the places' own text would show them twice")

        let written = try XCTUnwrap(PresentedCard(json: [
            "id": "plan", "title": "Plan", "markdown": "| a |", "cards": [map],
        ]))
        XCTAssertEqual(written.markdown, "| a |", "what Hermes wrote shows beside the cards")
        XCTAssertNotEqual(drawn, PresentedCard(id: "dinner", title: "Dinner", markdown: ""), "the cards count")
    }
}
