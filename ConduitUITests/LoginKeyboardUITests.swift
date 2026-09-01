import XCTest

/// Issue #117, part 2: on an iPhone-sized screen the software keyboard used
/// to cover the optional Cloudflare service-token fields with no way to
/// reach them. The login form is now a keyboard-aware scroll view, so this
/// drives the REAL gesture pipeline — toggle the Cloudflare section, focus
/// its fields through the return-key chain, and assert every control stays
/// hittable while the keyboard is up.
///
/// The Cloudflare toggle is driven through `ensureSwitchOn`, which verifies
/// the actual accessibility state transition instead of assuming one
/// `tap()` succeeded: a mis-aimed tap (element still settling from the
/// form's entrance animation) used to leave the switch OFF, the fields
/// unmounted, and this test failed with "Client ID did not appear" — a
/// product illusion with no product bug behind it. Each tap is gated on the
/// observed OFF state (never a blind double-tap, which could mask a real
/// toggle bug by flipping it back off), and a failure dumps the
/// accessibility tree plus the switch's observed values.
final class LoginKeyboardUITests: XCTestCase {
    /// Stable XCUI handles defined in LoginView (decoupled from copy).
    private enum Identity {
        static let serverURL = "login.server-url"
        static let cloudflareToggle = "login.cloudflare-toggle"
        static let cloudflareClientID = "login.cloudflare-client-id"
        static let cloudflareClientSecret = "login.cloudflare-client-secret"
        static let connect = "login.connect"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCloudflareFieldsAndConnectStayReachableWithKeyboardVisible() throws {
        let app = XCUIApplication()
        app.launch()

        let serverField = app.textFields[Identity.serverURL]
        XCTAssertTrue(serverField.waitForExistence(timeout: 10), "Login screen did not appear. Tree:\n\(app.debugDescription)")

        let cfToggle = app.switches[Identity.cloudflareToggle]
        XCTAssertTrue(
            ensureSwitchOn(cfToggle, app: app),
            "Cloudflare toggle did not reach the ON state. Observed values: \(toggleObservations). Tree:\n\(app.debugDescription)"
        )

        // The switch is verifiably ON (accessibility state, not an assumed
        // tap): the fields mount in the same transaction. If they still do
        // not appear, that is a production mount/exposure problem and the
        // dump below captures the mounted tree for diagnosis.
        let clientID = app.textFields[Identity.cloudflareClientID]
        XCTAssertTrue(
            clientID.waitForExistence(timeout: 10),
            "Cloudflare Client ID did not appear although the toggle is verifiably ON (value: \(cfToggle.value ?? "nil")). Tree:\n\(app.debugDescription)"
        )
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
        let secret = app.secureTextFields[Identity.cloudflareClientSecret]
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
        let connect = app.buttons[Identity.connect]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        if !connect.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(
            pollHittability(of: connect, timeout: 5),
            "Connect must remain reachable with the keyboard visible"
        )
    }

    // MARK: - Toggle state transition

    /// Accumulated switch-value observations for failure diagnostics.
    private var toggleObservations: [String] = []

    private func switchIsOn(_ element: XCUIElement) -> Bool {
        // SwiftUI switches expose their state via `value` as the string
        // "0"/"1" (NSString); some configurations surface a Bool NSNumber.
        switch element.value as? String {
        case "1": return true
        case "0": return false
        default: return (element.value as? Bool) == true
        }
    }

    /// Drives the toggle to ON and verifies the state actually changed.
    /// Waits for existence + hittability first, taps only while observed
    /// OFF (a second tap gated on state would otherwise be a blind
    /// double-tap), waits for the value to flip after each tap, and bounds
    /// the whole transition. The first unresponsive tap is logged so CI
    /// logs distinguish "tap did not flip the switch" from "switch flipped
    /// but the fields did not mount".
    private func ensureSwitchOn(_ element: XCUIElement, app: XCUIApplication) -> Bool {
        guard element.waitForExistence(timeout: 10) else {
            toggleObservations.append("toggle never existed")
            return false
        }
        var settled = false
        let hittableDeadline = Date().addingTimeInterval(5)
        while Date() < hittableDeadline {
            if element.isHittable { settled = true; break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        toggleObservations.append("initial value: \(element.value ?? "nil") hittable: \(settled)")
        if switchIsOn(element) { return true }

        let transitionDeadline = Date().addingTimeInterval(15)
        var taps = 0
        while Date() < transitionDeadline, taps < 3 {
            taps += 1
            element.tap()
            let flipped = waitForSwitchOn(element, timeout: 3)
            toggleObservations.append("tap \(taps) -> value: \(element.value ?? "nil") flipped: \(flipped)")
            if !flipped, taps == 1 {
                // Diagnostic for the intermittent flake: the first tap did
                // not change the switch state at all (tap vs. mount race),
                // as opposed to the fields failing to mount after a real
                // state change.
                NSLog("LoginKeyboardUITests: first toggle tap did not flip the switch (value=%@) - retrying", element.value.map { "\($0)" } ?? "nil")
            }
            if flipped { return true }
        }
        return switchIsOn(element)
    }

    private func waitForSwitchOn(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if switchIsOn(element) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return switchIsOn(element)
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
