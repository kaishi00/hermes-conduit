import XCTest

/// Issue #117, part 2: on an iPhone-sized screen the software keyboard used
/// to cover the optional Cloudflare service-token fields with no way to
/// reach them. The login form is now a keyboard-aware scroll view, so this
/// drives the REAL gesture pipeline — toggle the Cloudflare section, focus
/// its fields through the return-key chain, and assert every control stays
/// hittable while the keyboard is up.
final class LoginKeyboardUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCloudflareFieldsAndConnectStayReachableWithKeyboardVisible() throws {
        let app = XCUIApplication()
        app.launch()

        let serverField = app.textFields.firstMatch
        XCTAssertTrue(serverField.waitForExistence(timeout: 10), "Login screen did not appear. Tree:\n\(app.debugDescription)")

        let cfToggle = app.switches["Use Cloudflare Access service token"]
        XCTAssertTrue(cfToggle.waitForExistence(timeout: 5), "Cloudflare toggle not found. Tree:\n\(app.debugDescription)")
        cfToggle.tap()

        let clientID = app.textFields["Cloudflare Client ID"]
        XCTAssertTrue(clientID.waitForExistence(timeout: 5), "Cloudflare Client ID did not appear after enabling the toggle")
        clientID.tap()
        // Typing proves the software keyboard is actually up and focused here
        // (typeText waits for focus, so no fixed sleep for the keyboard).
        clientID.typeText("access-client-id.example")

        // The keyboard toolbar Done affordance must render with the form.
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Keyboard Done button did not appear")

        // Return walks the focus chain to the Cloudflare Client Secret; the
        // view must scroll that field into view from behind the keyboard.
        clientID.typeText("\n")
        let secret = app.secureTextFields["Cloudflare Client Secret"]
        XCTAssertTrue(secret.waitForExistence(timeout: 5))
        // The focus-driven scroll animates for ~0.25s; poll hittability
        // instead of asserting while the scroll may still be in flight.
        XCTAssertTrue(
            pollHittability(of: secret, timeout: 5),
            "Cloudflare Client Secret must scroll into view when it receives focus"
        )
        secret.typeText("access-client-secret")

        // The Connect control itself must also remain reachable on the
        // compact keyboard-obscured layout.
        let connect = app.buttons["Connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        if !connect.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(connect.isHittable, "Connect must remain reachable with the keyboard visible")
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
