import XCTest

/// Round-5 Connection Setup UI coverage: the Settings entry for an
/// already-connected user. The app starts in the inert DEBUG connected stub
/// (`-CONDUIT_UI_TEST_CONNECTED_DASHBOARD`: a snapshot connection with no
/// transport), and the staged test runs against the deterministic
/// `-CONNECTION_SETUP_TEST_RESULT` stub — no test touches a real server.
///
/// The simulator has no saved credentials, so the seed is the passwordless
/// interactive-auth shape: the wizard opens directly on the staged test with
/// the current URL preserved, and Back reaches the editable details screens.
final class ConnectionSetupSettingsUITests: XCTestCase {
    private enum Identity {
        static let stubDashboardURL = "https://conduit-uitest.example"
        static let settingsRow = "settings.connection-setup"
        static let gatewayRow = "settings.gateway"
        static let urlField = "setup.url"
        static let addressPreview = "setup.address-preview"
        static let next = "setup.next"
        static let username = "setup.username"
        static let password = "setup.password"
        static let back = "setup.back"
        static let testRun = "setup.test.run"
        static let useSettings = "setup.use-settings"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSettingsConnectionSetupEditsTestsAndAppliesWithoutTouchingTheSession() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", Identity.stubDashboardURL,
            "-CONNECTION_SETUP_TEST_RESULT", "success"
        ]
        app.launch()

        openSettings(app)

        // The Connection section carries the current dashboard (the Gateway
        // row) and the new Connection Setup entry.
        tapVisible(app.buttons[Identity.settingsRow], in: app)

        // The passwordless seed opens straight on the staged test with the
        // current URL preserved exactly — no first-run readiness questions,
        // no meaningless password field.
        let preview = row(app, Identity.addressPreview)
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "Wizard did not open on the staged test. Tree:\n\(app.debugDescription)")
        XCTAssertEqual(preview.label, Identity.stubDashboardURL)

        // Back reaches the editable details screen, also prefilled with the
        // exact current address.
        tapVisible(app.buttons[Identity.back], in: app)
        let urlField = app.textFields[Identity.urlField]
        XCTAssertTrue(urlField.waitForExistence(timeout: 5), "Details screen did not appear. Tree:\n\(app.debugDescription)")
        XCTAssertEqual(urlField.value as? String, Identity.stubDashboardURL)

        tapVisible(app.buttons[Identity.next], in: app)
        let username = app.textFields[Identity.username]
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        tapVisible(username, in: app)
        username.typeText("uitest-user")
        let password = app.secureTextFields[Identity.password]
        tapVisible(password, in: app)
        password.typeText("uitest-fixture")
        dismissKeyboard(app)
        tapVisible(app.buttons[Identity.next], in: app)

        // The real Round-4 staged test screen, driven by the stub.
        XCTAssertTrue(app.buttons[Identity.testRun].waitForExistence(timeout: 5), "Test screen did not appear. Tree:\n\(app.debugDescription)")
        tapVisible(app.buttons[Identity.testRun], in: app)
        XCTAssertTrue(app.staticTexts["setup.test.ready"].waitForExistence(timeout: 5))

        // Applying the changed configuration (a typed password) closes the
        // wizard and lands back on Settings. Nothing connects, no reconnect
        // fires, and the session stub is untouched.
        tapVisible(app.buttons[Identity.useSettings], in: app)
        XCTAssertTrue(app.buttons[Identity.settingsRow].waitForExistence(timeout: 5), "Wizard did not return to Settings. Tree:\n\(app.debugDescription)")

        // Unchanged URL and no previously saved credentials: applying is a
        // no-op, so no confirmation alert appears.
        XCTAssertFalse(app.alerts.firstMatch.exists, "A no-op apply must not claim to have changed settings")

        // The active connection is intact: still inside Settings, still the
        // stubbed connected session, never bounced to the login card.
        XCTAssertFalse(app.textFields["login.server-url"].exists, "The live session must never be disrupted by the wizard")
        let gatewayRow = app.buttons[Identity.gatewayRow]
        XCTAssertTrue(gatewayRow.waitForExistence(timeout: 5))
        XCTAssertTrue(
            gatewayRow.label.contains(Identity.stubDashboardURL),
            "The Gateway row still shows the current dashboard, got: \(gatewayRow.label)"
        )
    }

    func testInteractiveSignInOutcomeFromSettingsOffersDoneAndDismissesSafely() {
        // A browser-sign-in deployment with no stored password: the staged
        // test ends in the supported interactive outcome, Review offers plain
        // Done (unchanged settings), and dismissing leaves the active
        // session untouched.
        let app = XCUIApplication()
        app.launchArguments += [
            "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", Identity.stubDashboardURL,
            "-CONNECTION_SETUP_TEST_RESULT", "auth:interactiveSignInRequired"
        ]
        app.launch()

        openSettings(app)
        tapVisible(app.buttons[Identity.settingsRow], in: app)

        let preview = row(app, Identity.addressPreview)
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "Wizard did not open on the staged test. Tree:\n\(app.debugDescription)")
        XCTAssertEqual(preview.label, Identity.stubDashboardURL)

        tapVisible(app.buttons[Identity.testRun], in: app)

        // Review, reached by auto-advance: browser sign-in is explained,
        // "Login successful" is never claimed, and unchanged settings offer
        // Done instead of Use These Settings.
        let interactiveReady = app.staticTexts["setup.test.interactive-ready"]
        XCTAssertTrue(interactiveReady.waitForExistence(timeout: 5))
        XCTAssertTrue(interactiveReady.label.contains("browser-based sign-in"), "Got: \(interactiveReady.label)")
        XCTAssertFalse(app.staticTexts["setup.test.ready"].exists, "Interactive auth must never claim the connection is ready to use")
        let authRow = row(app, "setup.test.stage.authentication")
        XCTAssertTrue(authRow.exists)
        XCTAssertTrue(authRow.label.lowercased().contains("browser sign-in required"), "Got: \(authRow.label)")

        tapVisible(app.buttons[Identity.useSettings], in: app)
        XCTAssertTrue(app.buttons[Identity.settingsRow].waitForExistence(timeout: 5), "Done did not return to Settings. Tree:\n\(app.debugDescription)")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Done on unchanged settings applies nothing and needs no confirmation")
        XCTAssertFalse(app.textFields["login.server-url"].exists, "The live session must never be disrupted by the wizard")
    }

    func testNativeDashboardWithoutSavedCredentialsStopsAtCredentialsRequired() {
        // The real no-saved-credentials native scenario: credential absence
        // is NOT interactive auth. Discovery proves a password dashboard,
        // the staged test stops at Credentials required — no empty-credential
        // login request is ever sent — and Enter Credentials routes to the
        // existing credentials step with the URL preserved.
        let app = XCUIApplication()
        app.launchArguments += [
            "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", Identity.stubDashboardURL,
            "-CONNECTION_SETUP_TEST_RESULT", "auth:credentialsRequired"
        ]
        app.launch()

        openSettings(app)
        tapVisible(app.buttons[Identity.settingsRow], in: app)

        let preview = row(app, Identity.addressPreview)
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "Wizard did not open on the staged test. Tree:\n\(app.debugDescription)")
        XCTAssertEqual(preview.label, Identity.stubDashboardURL)

        tapVisible(app.buttons[Identity.testRun], in: app)

        // The partial outcome: two passed stages, then Credentials required
        // — never Login successful, never Browser sign-in required, and no
        // ready claim.
        let notice = app.staticTexts["setup.test.credentials-required"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        let authRow = row(app, "setup.test.stage.authentication")
        XCTAssertTrue(authRow.exists)
        XCTAssertTrue(authRow.label.lowercased().contains("credentials required"), "Got: \(authRow.label)")
        XCTAssertFalse(app.staticTexts["setup.test.ready"].exists)
        XCTAssertFalse(app.staticTexts["setup.test.interactive-ready"].exists)
        XCTAssertFalse(app.buttons[Identity.useSettings].exists, "A partial test must not authorize the settings handoff")

        // Enter Credentials routes to the existing credentials step with the
        // current URL intact.
        tapVisible(app.buttons["setup.test.enter-credentials"], in: app)
        let username = app.textFields[Identity.username]
        XCTAssertTrue(username.waitForExistence(timeout: 5), "Credentials step did not appear. Tree:\n\(app.debugDescription)")
        let urlField = app.textFields[Identity.urlField]
        XCTAssertFalse(urlField.exists, "The URL is owned by the details step; credentials step only asks for credentials")
        XCTAssertTrue(app.buttons[Identity.back].exists, "Back returns toward the tested connection")
    }

    // MARK: - Walk helpers

    private func openSettings(_ app: XCUIApplication) {
        // Inbox is the compact root; Settings lives under the More menu.
        let more = app.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "Inbox shell did not appear. Tree:\n\(app.debugDescription)")
        more.tap()

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "More menu did not show Settings. Tree:\n\(app.debugDescription)")
        settings.tap()
    }

    /// Stage rows and the address preview are single combined accessibility
    /// elements, so query by identifier across element types.
    private func row(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

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
