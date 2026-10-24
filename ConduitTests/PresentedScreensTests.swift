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

    func testPresentedConfirmRefusalsNeverConfirmWhateverHermesListedAsAYes() {
        let refusals = ["no", "cancel", "wait", "never", "not", "absolutely not", "definitely not", "of course not",
                        "i don't want it", "hell no", "that's a no"]
        let prompt = PresentedConfirm(id: "p1", title: "Send to Mei?", preview: "", actionLabel: "Send",
                                      spokenYes: ["send it", "no problem"] + refusals)
        for refusal in refusals {
            let listed = PresentedConfirm(id: "p1", title: "Send to Mei?", preview: "", actionLabel: "Send",
                                          spokenYes: [refusal])
            XCTAssertFalse(listed.isConfirmed(by: refusal), refusal)
            XCTAssertFalse(listed.isConfirmed(by: refusal.capitalized + "."), refusal)
        }
        // A genuine yes still confirms, a no-led one included.
        XCTAssertTrue(prompt.isConfirmed(by: "send it"))
        XCTAssertTrue(prompt.isConfirmed(by: "No problem"))
        XCTAssertTrue(prompt.isConfirmed(by: "yes"))
    }

    func testPresentedConfirmARefusalAnywhereInTheWordsNeverConfirms() {
        // Not at the start, or said only through the verb: still a no.
        let refusals = ["不", "不不不", "Momento", "Sekunde", "Sebentar", "send it, no wait", "yes, send it, no wait", "send it. wait", "send it later, not now", "please cancel",
                        "raczej nie", "chyba nie", "şimdi gönderme", "нет, не отправляй",
                        "지금 보내지 마", "보내지마세요", "보내지 않을래요", "그건 하지 말아요",
                        "我不想发", "先别发", "現在別發", "送らないで", "送信しないでください", "やっぱりやめて"]
        for refusal in refusals {
            let listed = PresentedConfirm(id: "p1", title: "Send to Mei?", preview: "", actionLabel: "Send",
                                          spokenYes: [refusal])
            XCTAssertFalse(listed.isConfirmed(by: refusal), refusal)
        }
        // A phrase in any shipped language that says yes still confirms.
        // A negating character or a length of time inside a yes isn't a no.
        for yes in ["send it", "envíalo", "wyślij", "gönder", "보내 줘", "发吧", "送って", "the second one",
                    "沒問題", "没有问题", "特别好，发吧", "发给别人", "不错，发吧", "問題ありません", "すみません、送って"] {
            let listed = PresentedConfirm(id: "p1", title: "Send to Mei?", preview: "", actionLabel: "Send",
                                          spokenYes: [yes])
            XCTAssertTrue(listed.isConfirmed(by: yes), yes)
        }
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

    /// The request holds the dashboard bridge: a finished sync keeps
    /// nothing of it, like the agent settings sync.
    func testAFinishedSyncKeepsNoHoldOnItsRequest() async throws {
        final class Bridge {}
        let suite = "present-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sync = PresentedScreensSync(defaults: defaults)
        weak var released: Bridge?
        do {
            let bridge = Bridge()
            released = bridge
            await sync.sync(scope: "host|default", profile: "default", installationID: "install-1") { _, _ in
                withExtendedLifetime(bridge) {}
                return ["ok": true, "prompts": []]
            }
        }
        XCTAssertNil(released, "The sync let go of its request and the bridge it holds")
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
        XCTAssertEqual(sent["features"] as? [String], ["maps-navigate", "show-cards", "chat-cards", "info-cards", "media-cards", "live-cards", "text-drafts"])
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

    func testAnAnswerSyncedDuringABusyExchangeStillReachesTheHost() async throws {
        let suite = "present-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sync = PresentedScreensSync(defaults: defaults)
        // The host lists the confirmation until the answer lands; the first
        // three exchanges wait until the test lets them answer.
        var bodies: [[String: Any]] = []
        var held: [CheckedContinuation<Void, Never>] = []
        let exchange: PresentedScreensSync.Request = { _, body in
            bodies.append(body)
            if bodies.count <= 3 { await withCheckedContinuation { held.append($0) } }
            return ["ok": true, "prompts": [["id": "p1", "title": "Send?", "action_label": "Send"]]]
        }
        func waitForExchange(_ count: Int) async {
            while bodies.count < count || held.isEmpty { await Task.yield() }
        }
        // Another trigger while an exchange is on its way: it coalesces.
        func syncAgain() async {
            await sync.sync(scope: "host|default", profile: "default", installationID: "i", request: exchange)
        }

        let first = Task { await sync.sync(scope: "host|default", profile: "default", installationID: "i", request: exchange) }
        await waitForExchange(1)
        await syncAgain() // a tool started
        held.removeFirst().resume()
        await waitForExchange(2)
        await syncAgain() // the tool finished
        held.removeFirst().resume()
        await waitForExchange(3)
        // The user answers while the third exchange is on its way.
        let prompt = try XCTUnwrap(sync.prompts.first)
        sync.answer(prompt, outcome: .confirmed, via: .tap)
        await syncAgain()
        held.removeFirst().resume()
        await first.value

        XCTAssertEqual(bodies.count, 4, "the sync asked for after the answer runs")
        let results = bodies.last?["results"] as? [[String: Any]]
        XCTAssertEqual(results?.first?["id"] as? String, "p1")
        XCTAssertEqual(results?.first?["outcome"] as? String, "confirmed")
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
