//
//  PresentedScreensTests.swift
//  ConduitTests
//
//  Confirmations Hermes asks the phone to present (PresentedScreens.swift).
//  An extension of an existing class, so the test planner needs no new entry.
//

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

    func testAnExpiredConfirmIsntShown() {
        let prompt = PresentedConfirm(id: "p1", title: "Buy it?", preview: "", actionLabel: "Buy",
                                      expiresAt: Date().addingTimeInterval(-1))
        XCTAssertTrue(prompt.isExpired())
    }
}
