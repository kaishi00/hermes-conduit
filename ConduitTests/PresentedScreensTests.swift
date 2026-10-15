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

    func testAnExpiredConfirmIsntShown() {
        let prompt = PresentedConfirm(id: "p1", title: "Buy it?", preview: "", actionLabel: "Buy",
                                      expiresAt: Date().addingTimeInterval(-1))
        XCTAssertTrue(prompt.isExpired())
    }
}
