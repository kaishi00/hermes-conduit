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
        static let advanced = "login.advanced"
        static let cloudflareToggle = "login.cloudflare-toggle"
        static let cloudflareClientID = "login.cloudflare-client-id"
        static let cloudflareClientSecret = "login.cloudflare-client-secret"
        static let connect = "login.connect"
        static let connectionSetup = "login.connection-setup"
        static let errorTitle = "login.error.title"
        static let troubleshoot = "login.error.troubleshoot"
        static let connectionSetupDone = "connection-setup.done"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCloudflareFieldsAndConnectStayReachableWithKeyboardVisible() throws {
        let app = XCUIApplication()
        app.launch()

        let serverField = app.textFields[Identity.serverURL]
        XCTAssertTrue(serverField.waitForExistence(timeout: 10), "Login screen did not appear. Tree:\n\(app.debugDescription)")

        // The Cloudflare token lives under Advanced on the address step.
        let advanced = app.buttons[Identity.advanced]
        XCTAssertTrue(advanced.waitForExistence(timeout: 5), "Advanced row missing. Tree:\n\(app.debugDescription)")
        XCTAssertTrue(pollHittability(of: advanced, timeout: 5))
        advanced.tap()

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

        // Continue itself must also remain reachable on the compact
        // keyboard-obscured layout.
        let connect = app.buttons[Identity.connect]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        let beforeScroll = "connect=\(connect.frame) enabled=\(connect.isEnabled) keyboard=\(app.keyboards.firstMatch.frame)"
        // The focus scroll leaves Connect just under the keyboard toolbar.
        // Scroll it up the way a person would: drag the form from a point
        // above the keyboard. A plain app.swipeUp() never moved the form on
        // hosted runs (Connect kept its exact frame in every nightly from
        // 2026-10-05 to 2026-10-11). Each drag gets a moment to settle before
        // the next, so a slow scroll is not mistaken for a stuck one.
        var drags = 0
        while app.keyboards.firstMatch.exists && !pollAboveKeyboard(connect, in: app, timeout: 1) && drags < 3 {
            dragFormUp(app)
            drags += 1
        }
        XCTAssertTrue(
            app.keyboards.firstMatch.exists,
            "The keyboard must still be up after scrolling, or this test no longer covers the keyboard layout. Tree:\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            pollAboveKeyboard(connect, in: app, timeout: 5),
            "Connect must remain reachable with the keyboard visible. Before scrolling: \(beforeScroll). After \(drags) drag(s): connect=\(connect.frame) enabled=\(connect.isEnabled) keyboard=\(app.keyboards.firstMatch.frame) done=\(app.buttons["Done"].firstMatch.frame). Tree:\n\(app.debugDescription)"
        )
    }

    // MARK: - Connection Setup affordance (Round 1)

    /// The permanent "Need help connecting?" affordance must be visible near
    /// the top of the login card and open the Connection Setup shell without
    /// touching any other control.
    func testConnectionSetupAffordanceIsReachableAndOpensShell() throws {
        let app = XCUIApplication()
        app.launch()

        let serverField = app.textFields[Identity.serverURL]
        XCTAssertTrue(serverField.waitForExistence(timeout: 10), "Login screen did not appear. Tree:\n\(app.debugDescription)")

        let setup = app.buttons[Identity.connectionSetup]
        XCTAssertTrue(
            setup.waitForExistence(timeout: 5),
            "Connection Setup affordance must be visible on the login card. Tree:\n\(app.debugDescription)"
        )
        if !setup.isHittable { app.swipeDown() }
        XCTAssertTrue(pollHittability(of: setup, timeout: 5), "Connection Setup affordance must be hittable at the top of the login card")

        setup.tap()
        let sheetDone = app.buttons[Identity.connectionSetupDone]
        XCTAssertTrue(
            sheetDone.waitForExistence(timeout: 5),
            "Connection Setup sheet must open from the affordance. Tree:\n\(app.debugDescription)"
        )

        sheetDone.tap()
        XCTAssertTrue(
            serverField.waitForExistence(timeout: 5),
            "Dismissing the Connection Setup sheet must return to the login form"
        )
    }

    /// Types text after clearing any existing content, so a filled-in
    /// address (a Connection Setup handoff) can never form an unpredictable
    /// value. Deletes past the start of an empty field are no-ops, so the
    /// overshooting delete count lands on exactly `text` no matter where the
    /// tap placed the cursor.
    private func clearAndType(_ text: String, into field: XCUIElement) {
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 60))
        field.typeText(text)
    }

    /// Dismisses the keyboard via its toolbar Done affordance. XCUI can
    /// report controls under the keyboard window as hittable, so a raw tap
    /// lands on the keyboard instead of the control (observed directly:
    /// Connect at y≈498 behind a keyboard starting at y=491 reported
    /// hittable). Waiting for the Done button to disappear means Connect is
    /// genuinely tappable afterwards.
    private func dismissKeyboard(_ app: XCUIApplication) {
        let done = app.buttons["Done"]
        guard done.waitForExistence(timeout: 3) else { return }
        done.tap()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, done.exists {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// A malformed dashboard URL classifies locally (no network I/O) into the
    /// invalid-address failure: the error presentation must show actionable
    /// copy and a Troubleshoot action that lands in the Connection Setup
    /// shell — and it must not trap Connect below the keyboard/viewport.
    func testMalformedURLShowsActionableErrorWithTroubleshootAndConnectStaysReachable() throws {
        let app = XCUIApplication()
        app.launch()

        let serverField = app.textFields[Identity.serverURL]
        XCTAssertTrue(serverField.waitForExistence(timeout: 10), "Login screen did not appear. Tree:\n\(app.debugDescription)")
        // A scheme Conduit doesn't speak → invalidURL policy failure;
        // classification never hits the network, so this stays deterministic
        // offline. (A bare host is no longer malformed: Conduit adds https.)
        // Any prefilled dashboard address is cleared first.
        clearAndType("ftp://not-a-dashboard", into: serverField)
        dismissKeyboard(app)

        let connect = app.buttons[Identity.connect]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        if !connect.isHittable { app.swipeUp() }
        XCTAssertTrue(pollHittability(of: connect, timeout: 5), "Connect must be reachable to submit the malformed URL")
        connect.tap()

        let errorTitle = app.staticTexts[Identity.errorTitle]
        XCTAssertTrue(
            errorTitle.waitForExistence(timeout: 5),
            "Classified invalid-address failure must appear. Tree:\n\(app.debugDescription)"
        )
        XCTAssertEqual(errorTitle.label, "Check the dashboard address")

        let troubleshoot = app.buttons[Identity.troubleshoot]
        XCTAssertTrue(troubleshoot.waitForExistence(timeout: 5), "Invalid-address failure must offer Troubleshoot Connection")
        if !troubleshoot.isHittable { app.swipeUp() }
        XCTAssertTrue(pollHittability(of: troubleshoot, timeout: 5))
        troubleshoot.tap()
        XCTAssertTrue(
            app.buttons[Identity.connectionSetupDone].waitForExistence(timeout: 5),
            "Troubleshoot Connection must open the Connection Setup shell"
        )
        app.buttons[Identity.connectionSetupDone].tap()

        XCTAssertTrue(serverField.waitForExistence(timeout: 5), "Dismissing the sheet must return to the login form")
        if !connect.isHittable { app.swipeUp() }
        XCTAssertTrue(
            pollHittability(of: connect, timeout: 5),
            "Connect must remain reachable under the multiline error presentation"
        )
    }

    /// Remote plain HTTP classifies locally into the insecure-transport
    /// failure (still no network I/O: the policy rejects before any request),
    /// with its own title distinct from the malformed-URL case.
    func testRemotePlainHTTPShowsInsecureTransportErrorAndConnectStaysReachable() throws {
        let app = XCUIApplication()
        app.launch()

        let serverField = app.textFields[Identity.serverURL]
        XCTAssertTrue(serverField.waitForExistence(timeout: 10), "Login screen did not appear. Tree:\n\(app.debugDescription)")
        // TEST-NET-3 documentation address: never routed, and the transport
        // policy rejects it before any connection attempt.
        clearAndType("http://203.0.113.10:9119", into: serverField)
        dismissKeyboard(app)

        let connect = app.buttons[Identity.connect]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        if !connect.isHittable { app.swipeUp() }
        XCTAssertTrue(pollHittability(of: connect, timeout: 5), "Connect must be reachable to submit the insecure URL")
        connect.tap()

        let errorTitle = app.staticTexts[Identity.errorTitle]
        XCTAssertTrue(
            errorTitle.waitForExistence(timeout: 5),
            "Classified insecure-transport failure must appear. Tree:\n\(app.debugDescription)"
        )
        XCTAssertEqual(errorTitle.label, "Insecure dashboard address")

        if !connect.isHittable { app.swipeUp() }
        XCTAssertTrue(
            pollHittability(of: connect, timeout: 5),
            "Connect must remain reachable under the insecure-transport error presentation"
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

    /// Drags the login form up by about a third of the screen. It starts at
    /// 6% of the width, left of every control (on the iPhone 17 Pro the
    /// nightly runs, that is the card's own padding, and controls start at
    /// 44 pt), at 45% of the height, which is above the keyboard and its
    /// toolbar there. The short press before the move makes it a drag, not a
    /// fling, so the distance scrolled is predictable.
    private func dragFormUp(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.45))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.12))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    /// Polls until `element` is hittable AND sits entirely above the keyboard
    /// and its Done toolbar. isHittable alone is not enough here: XCUI has
    /// reported Connect hittable behind the keyboard window (see
    /// dismissKeyboard), so the frame check is what proves it is reachable.
    private func pollAboveKeyboard(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        func isAbove() -> Bool {
            // No keyboard means no keyboard layout to check; the caller's
            // keyboard assertion reports that case.
            guard app.keyboards.firstMatch.exists, element.isHittable else { return false }
            var top = app.keyboards.firstMatch.frame.minY
            let done = app.buttons["Done"].firstMatch
            if done.exists { top = min(top, done.frame.minY) }
            return element.frame.maxY <= top
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isAbove() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return isAbove()
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
