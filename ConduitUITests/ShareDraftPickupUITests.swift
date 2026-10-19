//
//  ShareDraftPickupUITests.swift
//  ConduitUITests
//
//  A draft shared from another app (#812) shows in the composer of the chat
//  it was meant for, unsent. XCUITest can't reliably drive another app's
//  share sheet into an app extension, so the DEBUG fixture stages the draft
//  in a scratch inbox exactly as the extension writes it; from there the app
//  picks it up through its real path (scene activation, the widget launch
//  coordinator, the composer's restore requests).
//

import XCTest

final class ShareDraftPickupUITests: XCTestCase {
    private enum Identity {
        static let connectedDashboard = "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD"
        static let seededProfiles = "-CONDUIT_UI_TEST_PROFILES"
        static let shareDraft = "-CONDUIT_UI_TEST_SHARE_DRAFT"
        static let sessionID = "widget-ui-test-session"
        static let conversationOutcome = "widgetUITestConversation"
        static let freshConversationOutcome = "widgetUITestFreshConversation"
        static let notice = "composer.notice"
        static let sharedText = "Shared from another app: https://example.com/article"
        static let sharedFileName = "shared-note.png"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSharedDraftOpensItsChatWithTheDraftUnsent() throws {
        let app = launchApp(mode: "resume")

        let conversation = app.otherElements[Identity.conversationOutcome]
        XCTAssertTrue(conversation.waitForExistence(timeout: 15), tree(app))
        XCTAssertEqual(conversation.value as? String, Identity.sessionID)
        assertDraftInComposer(app)
    }

    func testSharedDraftForANewChatStartsOne() throws {
        let app = launchApp(mode: "newChat")

        let fresh = app.otherElements[Identity.freshConversationOutcome]
        XCTAssertTrue(fresh.waitForExistence(timeout: 15), tree(app))
        XCTAssertNotEqual(fresh.value as? String, Identity.sessionID)
        assertDraftInComposer(app)
    }

    private func assertDraftInComposer(_ app: XCUIApplication) {
        XCTAssertTrue(app.otherElements[Identity.notice].waitForExistence(timeout: 10)
            || app.staticTexts.matching(identifier: Identity.notice).firstMatch.waitForExistence(timeout: 1), tree(app))
        XCTAssertTrue(app.buttons["Remove \(Identity.sharedFileName)"].waitForExistence(timeout: 10), tree(app))
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), tree(app))
        XCTAssertEqual(field.value as? String, Identity.sharedText, "the shared text waits in the composer, unsent")
        XCTAssertFalse(app.staticTexts[Identity.sharedText].exists, "nothing is sent until the user sends it")
    }

    private func launchApp(mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        app.launchArguments += [
            Identity.connectedDashboard, "https://conduit-ui-test.invalid",
            Identity.seededProfiles, "work,staging",
            Identity.shareDraft, mode,
        ]
        app.launch()
        return app
    }

    private func tree(_ app: XCUIApplication) -> String {
        "Shared draft outcome missing. Tree:\n\(app.debugDescription)"
    }
}
