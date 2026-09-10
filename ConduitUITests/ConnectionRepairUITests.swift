import XCTest

/// Round-6 Repair Connection UI coverage. All paths are deterministic:
/// `-CONDUIT_UI_TEST_FAILED_CONNECTION` starts the app on a failed stubbed
/// session (Repair Connection visible), `-CONNECTION_SETUP_TEST_RESULT`
/// scripts the staged probe, and `-CONDUIT_REPAIR_ACTIVATION` scripts the
/// explicit activation outcome. No test touches a real Hermes server.
final class ConnectionRepairUITests: XCTestCase {
    private enum Identity {
        static let stubDashboardURL = "https://repair-uitest.example"
        static let repairButton = "composer.repair-connection"
        static let urlField = "setup.url"
        static let username = "setup.username"
        static let password = "setup.password"
        static let next = "setup.next"
        static let back = "setup.back"
        static let testRun = "setup.test.run"
        static let reconnectNow = "setup.review.reconnect-now"
        static let signInReconnect = "setup.review.sign-in-reconnect"
        static let enterCredentials = "setup.test.enter-credentials"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFailedConnectionOffersRepairSeededWithTheCurrentURL() {
        // The stable failure surfaces the Repair entry; the wizard opens
        // seeded from the failed connection's exact URL.
        let app = XCUIApplication()
        app.launchArguments += [
            "-CONDUIT_UI_TEST_FAILED_CONNECTION", Identity.stubDashboardURL,
            "-CONNECTION_SETUP_TEST_RESULT", "server:hostNotFound"
        ]
        app.launch()

        let repair = app.buttons[Identity.repairButton]
        XCTAssertTrue(repair.waitForExistence(timeout: 10), "Repair Connection did not appear. Tree:\n\(app.debugDescription)")
        repair.tap()

        let urlField = app.textFields[Identity.urlField]
        XCTAssertTrue(urlField.waitForExistence(timeout: 5), "Repair did not open on the details screen. Tree:\n\(app.debugDescription)")
        XCTAssertEqual(urlField.value as? String, Identity.stubDashboardURL)
    }

    func testNativeRepairTestsReconnectsAndReturnsToChat() {
        // Full native repair: seeded URL → credentials → staged success →
        // Reconnect Now (scripted activation) → back on chat, never bounced
        // to the login card.
        let app = XCUIApplication()
        app.launchArguments += [
            "-CONDUIT_UI_TEST_FAILED_CONNECTION", Identity.stubDashboardURL,
            "-CONNECTION_SETUP_TEST_RESULT", "success",
            "-CONDUIT_REPAIR_ACTIVATION", "success"
        ]
        app.launch()

        let repair = app.buttons[Identity.repairButton]
        XCTAssertTrue(repair.waitForExistence(timeout: 10))
        tapVisible(repair, in: app)

        let urlField = app.textFields[Identity.urlField]
        XCTAssertTrue(urlField.waitForExistence(timeout: 5))
        XCTAssertEqual(urlField.value as? String, Identity.stubDashboardURL)
        tapVisible(app.buttons[Identity.next], in: app)

        let username = app.textFields[Identity.username]
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        tapVisible(username, in: app)
        username.typeText("repair-user")
        let password = app.secureTextFields[Identity.password]
        tapVisible(password, in: app)
        password.typeText("repair-fixture")
        dismissKeyboard(app)
        tapVisible(app.buttons[Identity.next], in: app)

        XCTAssertTrue(app.buttons[Identity.testRun].waitForExistence(timeout: 5), "Test screen did not appear. Tree:\n\(app.debugDescription)")
        tapVisible(app.buttons[Identity.testRun], in: app)
        XCTAssertTrue(app.staticTexts["setup.test.ready"].waitForExistence(timeout: 5))

        // Reconnect Now is the Repair review's final action (not "Use these
        // settings"), and it activates the validated transaction from the
        // test — the scripted activation reports success and the wizard
        // closes.
        XCTAssertTrue(app.buttons[Identity.reconnectNow].waitForExistence(timeout: 5), "Reconnect Now did not appear. Tree:\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons["setup.use-settings"].exists, "Repair mode must not show the login handoff")
        tapVisible(app.buttons[Identity.reconnectNow], in: app)

        // Back on the chat surface: still the (stubbed) failed session in
        // its stable state — never the login card.
        XCTAssertTrue(app.buttons[Identity.repairButton].waitForExistence(timeout: 5), "Wizard did not return to chat. Tree:\n\(app.debugDescription)")
        XCTAssertFalse(app.textFields["login.server-url"].exists, "Repair must never strand the user on the login card")
    }

    func testRepairWithoutCredentialsStopsAtCredentialsRequiredAndRoutesToEntry() {
        // A repair whose seed has no credentials: discovery finds a password
        // dashboard and the staged test stops at Credentials required —
        // Enter Credentials routes to the credentials step. No empty-credential
        // login ever fires.
        let app = XCUIApplication()
        app.launchArguments += [
            "-CONDUIT_UI_TEST_FAILED_CONNECTION", Identity.stubDashboardURL,
            "-CONDUIT_UI_TEST_FAILURE_KIND", "none",
            "-CONNECTION_SETUP_TEST_RESULT", "auth:credentialsRequired"
        ]
        app.launch()

        let repair = app.buttons[Identity.repairButton]
        XCTAssertTrue(repair.waitForExistence(timeout: 10))
        tapVisible(repair, in: app)

        // No retained failure: the repair opens straight on the staged test.
        // The preview is a single Text element (exposed as a static text);
        // a typed query keeps snapshot evaluation out of the whole tree.
        let preview = app.staticTexts["setup.address-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "Repair did not open on the staged test. Tree:\n\(app.debugDescription)")
        XCTAssertEqual(preview.label, Identity.stubDashboardURL)
        tapVisible(app.buttons[Identity.testRun], in: app)

        XCTAssertTrue(app.staticTexts["setup.test.credentials-required"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[Identity.reconnectNow].exists, "A partial test must never authorize Reconnect Now")
        tapVisible(app.buttons[Identity.enterCredentials], in: app)
        XCTAssertTrue(app.textFields[Identity.username].waitForExistence(timeout: 5), "Enter Credentials did not route to the credentials step. Tree:\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons[Identity.back].exists, "Back keeps the tested address reachable")
    }

    func testInteractiveRepairOffersSignInToReconnect() {
        // A browser-auth deployment: the review offers Sign In to Reconnect
        // (the existing AuthWebView runs on tap) and never claims login
        // success.
        let app = XCUIApplication()
        app.launchArguments += [
            "-CONDUIT_UI_TEST_FAILED_CONNECTION", Identity.stubDashboardURL,
            "-CONDUIT_UI_TEST_FAILURE_KIND", "none",
            "-CONNECTION_SETUP_TEST_RESULT", "auth:interactiveSignInRequired"
        ]
        app.launch()

        let repair = app.buttons[Identity.repairButton]
        XCTAssertTrue(repair.waitForExistence(timeout: 10))
        tapVisible(repair, in: app)

        let preview = app.staticTexts["setup.address-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        tapVisible(app.buttons[Identity.testRun], in: app)

        let interactiveReady = app.staticTexts["setup.test.interactive-ready"]
        XCTAssertTrue(interactiveReady.waitForExistence(timeout: 5))
        XCTAssertTrue(interactiveReady.label.contains("Sign in now to reconnect"), "Got: \(interactiveReady.label)")
        XCTAssertFalse(app.staticTexts["setup.test.ready"].exists, "Interactive auth must never claim login success")
        XCTAssertTrue(app.buttons[Identity.signInReconnect].waitForExistence(timeout: 5), "Sign In to Reconnect did not appear. Tree:\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons[Identity.reconnectNow].exists)
    }

    func testFailedActivationShowsClassifiedFailureAndForcesFreshTest() {
        // A test success is not a guarantee the world is unchanged: when the
        // explicit activation fails, the classified failure is shown on
        // Review, the candidate is consumed, and the only way forward is a
        // fresh Test Connection — no automatic retry.
        let app = XCUIApplication()
        app.launchArguments += [
            "-CONDUIT_UI_TEST_FAILED_CONNECTION", Identity.stubDashboardURL,
            "-CONNECTION_SETUP_TEST_RESULT", "success",
            "-CONDUIT_REPAIR_ACTIVATION", "transportFailure"
        ]
        app.launch()

        let repair = app.buttons[Identity.repairButton]
        XCTAssertTrue(repair.waitForExistence(timeout: 10))
        tapVisible(repair, in: app)

        let urlField = app.textFields[Identity.urlField]
        XCTAssertTrue(urlField.waitForExistence(timeout: 5))
        XCTAssertEqual(urlField.value as? String, Identity.stubDashboardURL)
        tapVisible(app.buttons[Identity.next], in: app)

        let username = app.textFields[Identity.username]
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        tapVisible(username, in: app)
        username.typeText("repair-user")
        let password = app.secureTextFields[Identity.password]
        tapVisible(password, in: app)
        password.typeText("repair-fixture")
        dismissKeyboard(app)
        tapVisible(app.buttons[Identity.next], in: app)

        XCTAssertTrue(app.buttons[Identity.testRun].waitForExistence(timeout: 5))
        tapVisible(app.buttons[Identity.testRun], in: app)
        XCTAssertTrue(app.staticTexts["setup.test.ready"].waitForExistence(timeout: 5))
        tapVisible(app.buttons[Identity.reconnectNow], in: app)

        // Still on Review with the classified failure — never a silent drop
        // to a wiped test screen, never a retry. The consumed candidate
        // means the only way forward is a fresh Test Connection.
        XCTAssertTrue(app.staticTexts["setup.review.reconnect-failure"].waitForExistence(timeout: 5), "Classified activation failure not shown. Tree:\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["setup.review.test-again"].exists, "Test Connection Again must be the offered next step")
        XCTAssertFalse(app.buttons[Identity.reconnectNow].exists, "A consumed candidate must not authorize another Reconnect Now")
        XCTAssertFalse(app.staticTexts["setup.test.ready"].exists, "A failed reconnect must not claim the connection is ready")
        XCTAssertFalse(app.textFields["login.server-url"].exists, "A failed activation must never strand the user on the login card")
    }

    // MARK: - Walk helpers

    private func tapVisible(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        for _ in 0..<6 {
            if element.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
        element.tap()
    }

    private func dismissKeyboard(_ app: XCUIApplication) {
        let done = app.buttons["setup.keyboard-done"]
        guard done.waitForExistence(timeout: 2) else { return }
        done.tap()
    }
}
