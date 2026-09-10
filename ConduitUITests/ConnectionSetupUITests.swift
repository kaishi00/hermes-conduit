import XCTest

/// Round-2 Connection Setup wizard UI coverage: the guided flow opens from the
/// login card's entry point, walks Dashboard → Credentials → Access Method,
/// supports back navigation, shows Copy Prompt on the No / I don't know
/// paths, and reaches the Tailscale branch. Everything runs offline — no
/// step performs network I/O.
final class ConnectionSetupUITests: XCTestCase {
    private enum Identity {
        static let connectionSetup = "login.connection-setup"
        static let done = "connection-setup.done"
        static let back = "setup.back"
        static let answerYes = "setup.answer-yes"
        static let answerNo = "setup.answer-no"
        static let answerUnknown = "setup.answer-unknown"
        static let copyPrompt = "setup.copy-prompt"
        static let methodTailscale = "setup.method-tailscale"
        static let stepLabel = "setup.step-label"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLANDetailsValidationReviewAndHandoffWithoutConnecting() {
        let app = XCUIApplication()
        // The staged connection test runs against a deterministic stub probe:
        // UI tests never depend on a real Hermes server.
        app.launchArguments += ["-CONNECTION_SETUP_TEST_RESULT", "success"]
        app.launch()
        openSetup(app)
        tapVisible(app.buttons[Identity.answerYes], in: app)
        tapVisible(app.buttons[Identity.answerYes], in: app)
        tapVisible(app.buttons["setup.method-lan"], in: app)
        tapVisible(app.buttons["setup.details-ready"], in: app)
        let host = app.textFields["setup.host"]
        tapVisible(host, in: app)
        host.typeText("192.168.1.28")
        let port = app.textFields["setup.port"]
        tapVisible(port, in: app)
        port.typeText("0")
        // Dismiss the keyboard before tapping Continue: with the number pad
        // up, the Continue button can sit behind the keyboard window yet
        // still report hittable, so a synthesized tap hits the keyboard and
        // the button never fires.
        dismissKeyboard(app)
        tapVisible(app.buttons["setup.next"], in: app)
        XCTAssertTrue(app.staticTexts["Enter a port between 1 and 65535."].waitForExistence(timeout: 3))
        tapVisible(port, in: app)
        port.typeText(XCUIKeyboardKey.delete.rawValue + "9119")
        dismissKeyboard(app)
        tapVisible(app.buttons["setup.next"], in: app)
        let username = app.textFields["setup.username"]
        tapVisible(username, in: app)
        username.typeText("round3-user")
        let password = app.secureTextFields["setup.password"]
        tapVisible(password, in: app)
        password.typeText("round3-private-fixture")
        tapVisible(app.buttons["setup.next"], in: app)
        // The staged test screen sits between credentials and Review.
        XCTAssertTrue(app.buttons["setup.test.run"].waitForExistence(timeout: 5))
        tapVisible(app.buttons["setup.test.run"], in: app)
        XCTAssertTrue(app.staticTexts["setup.test.ready"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["http://192.168.1.28:9119"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Entered"].exists)
        XCTAssertFalse(app.staticTexts["round3-private-fixture"].exists)
        tapVisible(app.buttons[Identity.back], in: app)
        // Back from Review lands on the test screen, which still shows the
        // passing result.
        XCTAssertTrue(app.buttons["setup.test.continue"].waitForExistence(timeout: 5))
        tapVisible(app.buttons[Identity.back], in: app)
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        // Retained password permits the test screen without re-entry; never
        // read its value. No edits happened, so the success stays current.
        tapVisible(app.buttons["setup.next"], in: app)
        XCTAssertTrue(app.buttons["setup.test.continue"].waitForExistence(timeout: 5))
        tapVisible(app.buttons["setup.test.continue"], in: app)
        XCTAssertTrue(app.staticTexts["setup.test.ready"].waitForExistence(timeout: 5))
        tapVisible(app.buttons["setup.use-settings"], in: app)
        let server = app.textFields["login.server-url"]
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        XCTAssertEqual(server.value as? String, "http://192.168.1.28:9119")
        XCTAssertEqual(app.textFields["login.username"].value as? String, "round3-user")
        XCTAssertTrue(app.buttons["Connect"].isEnabled)
        XCTAssertFalse(app.staticTexts["Connecting..."].exists)
        // Reopening uses the in-memory login fields, including the password.
        openSetup(app)
        tapVisible(app.buttons[Identity.answerYes], in: app)
        tapVisible(app.buttons[Identity.answerYes], in: app)
        tapVisible(app.buttons["setup.use-existing"], in: app)
        XCTAssertEqual(app.textFields["setup.url"].value as? String, "http://192.168.1.28:9119")
        tapVisible(app.buttons["setup.next"], in: app)
        tapVisible(app.buttons["setup.next"], in: app)
        XCTAssertTrue(app.buttons["setup.test.run"].waitForExistence(timeout: 5))
        tapVisible(app.buttons["setup.test.run"], in: app)
        XCTAssertTrue(app.staticTexts["Entered"].waitForExistence(timeout: 5))
    }

    func testTailscaleServeDetailEntryUsesHTTPSWithoutDefaultPort() {
        let app = XCUIApplication()
        app.launch()
        openSetup(app)
        tapVisible(app.buttons[Identity.answerYes], in: app)
        tapVisible(app.buttons[Identity.answerYes], in: app)
        tapVisible(app.buttons[Identity.methodTailscale], in: app)
        tapVisible(app.buttons["setup.details-ready"], in: app)
        let host = app.textFields["setup.host"]
        tapVisible(host, in: app)
        host.typeText("machine.tailnet.ts.net")
        tapVisible(app.buttons["setup.next"], in: app)
        XCTAssertTrue(app.textFields["setup.username"].waitForExistence(timeout: 5))
        tapVisible(app.buttons[Identity.back], in: app)
        XCTAssertEqual(host.value as? String, "machine.tailnet.ts.net")
        XCTAssertTrue(app.staticTexts["https://machine.tailnet.ts.net"].exists)
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

    /// Tap the keyboard toolbar's Done control when present, so a Continue
    /// button that would sit behind the keyboard window is tapped for real.
    private func dismissKeyboard(_ app: XCUIApplication) {
        let done = app.buttons["setup.keyboard-done"]
        guard done.waitForExistence(timeout: 2) else { return }
        done.tap()
    }

    private func openSetup(_ app: XCUIApplication) {
        let serverField = app.textFields["login.server-url"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 10), "Login screen did not appear. Tree:\n\(app.debugDescription)")

        let setup = app.buttons[Identity.connectionSetup]
        XCTAssertTrue(setup.waitForExistence(timeout: 5), "Connection Setup entry point missing. Tree:\n\(app.debugDescription)")
        if !setup.isHittable { app.swipeDown() }
        XCTAssertTrue(pollHittability(of: setup, timeout: 5))
        setup.tap()
    }

    private func stepLabel(_ app: XCUIApplication, _ expected: String) {
        // Poll rather than assert once: during the NavigationStack push/pop
        // transition both steps can be mounted, so the first snapshot may
        // still show the outgoing label.
        let label = app.staticTexts[Identity.stepLabel]
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if label.exists, label.label == expected { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("Expected step '\(expected)', saw '\(label.exists ? label.label : "none")'. Tree:\n\(app.debugDescription)")
    }

    func testWizardAdvancesThroughQuestionsToTailscaleBranchAndBack() throws {
        let app = XCUIApplication()
        app.launch()
        openSetup(app)

        // Step 1: dashboard readiness, answered No → Ask Hermes guidance.
        stepLabel(app, "Step 1 of 3")
        let no = app.buttons[Identity.answerNo]
        XCTAssertTrue(no.waitForExistence(timeout: 5), "Dashboard answers missing. Tree:\n\(app.debugDescription)")
        if !no.isHittable { app.swipeUp() }
        no.tap()

        let copyPrompt = app.buttons[Identity.copyPrompt]
        XCTAssertTrue(copyPrompt.waitForExistence(timeout: 5), "Copy Prompt must appear on the No path")
        if !copyPrompt.isHittable { app.swipeUp() }
        copyPrompt.tap()
        // The visible "Copied" label intentionally disappears after ~2s,
        // which a hosted runner can outrun between the tap and the first
        // hierarchy snapshot. The button therefore carries a DURABLE
        // accessibility value for the current prompt ("Copied"), and the
        // assertion waits on that semantic state instead of racing the
        // transient label.
        let copiedValue = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Copied"),
            object: copyPrompt
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [copiedValue], timeout: 3),
            .completed,
            "Copying must confirm to the user"
        )

        let continueButton = app.buttons["setup.continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 3))
        if !continueButton.isHittable { app.swipeUp() }
        XCTAssertTrue(pollHittability(of: continueButton, timeout: 3))
        continueButton.tap()

        // Step 2: credentials, answered Yes.
        stepLabel(app, "Step 2 of 3")
        let yes = app.buttons[Identity.answerYes]
        XCTAssertTrue(yes.waitForExistence(timeout: 5))
        if !yes.isHittable { app.swipeUp() }
        yes.tap()

        // Step 3: access method, choose Tailscale.
        stepLabel(app, "Step 3 of 3")
        let tailscale = app.buttons[Identity.methodTailscale]
        XCTAssertTrue(tailscale.waitForExistence(timeout: 5), "Tailscale method card missing. Tree:\n\(app.debugDescription)")
        if !tailscale.isHittable { app.swipeUp() }
        XCTAssertTrue(pollHittability(of: tailscale, timeout: 3))
        tailscale.tap()

        // Tailscale branch mentions Tailscale Serve.
        let serve = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Tailscale Serve'")
        ).firstMatch
        XCTAssertTrue(serve.waitForExistence(timeout: 5), "Tailscale branch must present the Tailscale Serve path")

        // Back navigation returns through the wizard.
        let back = app.buttons[Identity.back]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        stepLabel(app, "Step 3 of 3")

        back.tap()
        stepLabel(app, "Step 2 of 3")

        let done = app.buttons[Identity.done]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(
            serverFieldAgain(app).waitForExistence(timeout: 5),
            "Done must return to the login form"
        )
    }

    func testDontKnowPathShowsCopyPromptAndCompactsStayScrollable() throws {
        let app = XCUIApplication()
        app.launch()
        openSetup(app)

        stepLabel(app, "Step 1 of 3")
        let unknown = app.buttons[Identity.answerUnknown]
        XCTAssertTrue(unknown.waitForExistence(timeout: 5))
        if !unknown.isHittable { app.swipeUp() }
        unknown.tap()

        let copyPrompt = app.buttons[Identity.copyPrompt]
        XCTAssertTrue(copyPrompt.waitForExistence(timeout: 5), "Copy Prompt must appear on the I don't know path")

        // Compact layout: the continue action below the prompt must remain
        // reachable by scrolling.
        let continueButton = app.buttons["setup.continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 3))
        var hittable = continueButton.isHittable
        var attempts = 0
        while !hittable, attempts < 3 {
            app.swipeUp()
            hittable = continueButton.isHittable
            attempts += 1
        }
        XCTAssertTrue(hittable, "Continue must stay reachable on a compact iPhone layout")

        continueButton.tap()
        stepLabel(app, "Step 2 of 3")
    }

    private func serverFieldAgain(_ app: XCUIApplication) -> XCUIElement {
        app.textFields["login.server-url"]
    }

    /// XCUIElement has no waitForHittability; poll isHittable on a deadline.
    private func pollHittability(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return element.isHittable
    }
}
