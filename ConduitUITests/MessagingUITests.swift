import XCTest

final class MessagingUITests: XCTestCase {
    func testMissingPluginOffersSetupOnBotsAndPreservesSessionsList() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", "https://conduit-uitest.example",
            "-CONDUIT_UI_TEST_INBOX_FIXTURE", "multi-profile",
            "-CONDUIT_UI_TEST_MESSAGING",
            "-CONDUIT_UI_TEST_MESSAGING_MISSING",
            "-conduit.messaging.discovery.v1.ui-test-messaging", "NO",
            "-conduit.chatsHomePane", "bots",
        ]
        app.launch()

        let homePane = app.segmentedControls["chats.home.pane"]
        XCTAssertTrue(homePane.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(homePane.buttons["Bots"].isSelected)

        let enable = app.buttons["messaging.enable"]
        XCTAssertTrue(enable.waitForExistence(timeout: 5), "Enable card lives on the default Bots pane")
        enable.tap()
        XCTAssertTrue(app.staticTexts["A shared inbox for your bots"].waitForExistence(timeout: 5))
        let setup = XCTAttachment(screenshot: app.screenshot()); setup.name = "Optional messaging setup"; setup.lifetime = .keepAlways; add(setup)
        XCTAssertTrue(app.buttons["messaging.setup.agent"].waitForExistence(timeout: 3), "Offer agent-assisted setup")
        XCTAssertFalse(app.buttons["Install on Hermes"].exists, "Do not offer an unsupported installer")
        app.buttons["Close"].tap()
        XCTAssertTrue(enable.waitForExistence(timeout: 5))

        homePane.buttons["Sessions"].tap()
        XCTAssertFalse(app.buttons["messaging.enable"].exists, "Sessions list has no messaging promo card")
        XCTAssertTrue(
            app.buttons["New Chat"].waitForExistence(timeout: 5)
                || app.staticTexts["New Chat"].waitForExistence(timeout: 2),
            "Sessions pane shows upstream SessionList with New Chat"
        )
    }

    func testMessagingInboxOpensDMAndSendsWithoutSessionSheet() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", "https://conduit-uitest.example",
            "-CONDUIT_UI_TEST_INBOX_FIXTURE", "multi-profile",
            "-CONDUIT_UI_TEST_MESSAGING",
            "-conduit.chatsHomePane", "bots",
        ]
        app.launch()
        let homePane = app.segmentedControls["chats.home.pane"]
        XCTAssertTrue(homePane.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(homePane.buttons["Bots"].isSelected)

        let designer = app.buttons.matching(NSPredicate(format: "label == %@", "Designer")).firstMatch
        XCTAssertTrue(designer.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Messages"].exists, "Bots home is a profile shelf, not a Messages list")
        XCTAssertFalse(app.staticTexts["Groups"].exists, "Groups sit inline with bots, not a separate section")
        let group = app.buttons.matching(NSPredicate(format: "label == %@", "Design crew")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 5), app.debugDescription)
        let inbox = XCTAttachment(screenshot: app.screenshot()); inbox.name = "Bots shelf"; inbox.lifetime = .keepAlways; add(inbox)
        designer.tap()
        // DM opens in the conversation host (Back to Bots), not a fullScreenCover.
        let back = app.buttons["Back to Bots"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        let composer = app.textFields["messaging.composer"]
        let multiline = app.textViews["messaging.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5) || multiline.exists, app.debugDescription)
        let field = composer.exists ? composer : multiline
        field.tap(); field.typeText("Looks good")
        XCTAssertFalse(
            app.buttons["composer.model-picker"].exists,
            "Bot/group composer reuses ComposerBar without the session model chip"
        )
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value == %@ OR label == %@", "Looks good", "Looks good")).firstMatch.waitForExistence(timeout: 5)
            || app.staticTexts["Looks good"].waitForExistence(timeout: 2), app.debugDescription)
        let chat = XCTAttachment(screenshot: app.screenshot()); chat.name = "Persistent DM"; chat.lifetime = .keepAlways; add(chat)
        back.tap()
        XCTAssertTrue(designer.waitForExistence(timeout: 5))
    }

    func testGroupShowsRunPresenceAvatarsInsteadOfStatusLabels() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", "https://conduit-uitest.example",
            "-CONDUIT_UI_TEST_INBOX_FIXTURE", "multi-profile",
            "-CONDUIT_UI_TEST_MESSAGING",
            "-conduit.chatsHomePane", "bots",
        ]
        app.launch()
        let homePane = app.segmentedControls["chats.home.pane"]
        XCTAssertTrue(homePane.waitForExistence(timeout: 10), app.debugDescription)
        let group = app.buttons.matching(NSPredicate(format: "label == %@", "Design crew")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 10), app.debugDescription)
        group.tap()

        let presence = app.otherElements["messaging.run-presence"]
        XCTAssertTrue(presence.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.otherElements["messaging.run-presence.designer-id"].waitForExistence(timeout: 3)
            || app.descendants(matching: .any)["Designer is queued"].waitForExistence(timeout: 2),
            app.debugDescription)
        XCTAssertTrue(app.otherElements["messaging.run-presence.swe-id"].exists
            || app.descendants(matching: .any)["SWE is running"].exists,
            app.debugDescription)
        XCTAssertFalse(app.staticTexts["Designer: queued"].exists)
        XCTAssertFalse(app.staticTexts["SWE: running"].exists)
        XCTAssertFalse(app.otherElements["messaging.awaiting-reply"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Group run presence"; shot.lifetime = .keepAlways; add(shot)
    }

    func testDMSendShowsAwaitingReplyDotsBeforeRuns() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", "https://conduit-uitest.example",
            "-CONDUIT_UI_TEST_INBOX_FIXTURE", "multi-profile",
            "-CONDUIT_UI_TEST_MESSAGING",
            "-conduit.chatsHomePane", "bots",
        ]
        app.launch()
        let homePane = app.segmentedControls["chats.home.pane"]
        XCTAssertTrue(homePane.waitForExistence(timeout: 10), app.debugDescription)
        let designer = app.buttons.matching(NSPredicate(format: "label == %@", "Designer")).firstMatch
        XCTAssertTrue(designer.waitForExistence(timeout: 10), app.debugDescription)
        designer.tap()
        XCTAssertTrue(app.buttons["Back to Bots"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.otherElements["messaging.awaiting-reply"].exists)
        let composer = app.textFields["messaging.composer"]
        let multiline = app.textViews["messaging.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5) || multiline.exists, app.debugDescription)
        let field = composer.exists ? composer : multiline
        field.tap(); field.typeText("Kick off a run")
        app.buttons["Send message"].tap()
        XCTAssertTrue(
            app.otherElements["messaging.awaiting-reply"].waitForExistence(timeout: 5)
                || app.descendants(matching: .any)["Waiting for a reply"].waitForExistence(timeout: 2),
            app.debugDescription
        )
        XCTAssertFalse(app.otherElements["messaging.run-presence"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "DM awaiting reply"; shot.lifetime = .keepAlways; add(shot)
    }
}
