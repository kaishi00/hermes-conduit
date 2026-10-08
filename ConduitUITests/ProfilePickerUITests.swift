//
//  ProfilePickerUITests.swift
//  ConduitUITests
//
//  Coverage for the profile-selection card (PR #198). The card's visible body
//  selects the profile while its nested controls (choose photo) keep their own
//  actions and must NOT also select — the invariant that decided the card's
//  structure during review.
//
//  Reaching a selectable row needs an active profile plus at least one other
//  discovered profile. A UI test has no transport for `/api/profiles` discovery
//  and the connection-scoped reset clears the persisted known-profile list, so
//  the roster comes from the DEBUG-only `-CONDUIT_UI_TEST_PROFILES` launch
//  argument (see `AppState.uiTestSeededProfiles()`), which seeds through the
//  same `orderedProfiles` a real discovery uses. Any future UI test that needs
//  a multi-profile roster can reuse it through `launchWithSeededProfiles`.
//
//  Both tests seed TWO profiles and act on whichever one is not current, so
//  they do not depend on the active profile a previous run left in the
//  simulator's defaults.
//

import XCTest

final class ProfilePickerUITests: XCTestCase {
    private enum Identity {
        static let connectedDashboard = "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD"
        static let seededProfiles = "-CONDUIT_UI_TEST_PROFILES"
        static let openSidebar = "Open sessions"
        static let workspace = "sidebar.workspace"
        static let pickerTitle = "Profiles"
        static let currentMarker = "Current"
    }

    /// Seeded as a pair so exactly one of them is selectable whatever the
    /// persisted active profile is. `profileDisplayName` uppercases the first
    /// letter, so these are also the display names the UI shows.
    private static let seededProfiles = ["work", "staging"]
    private static let seededDisplayNames = ["Work", "Staging"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Tapping the card body — not the name text and not a control — starts a
    /// profile switch.
    ///
    /// The signal is that the switch goes *in flight*: the row's own select
    /// button becomes disabled while `AppState.isProfileSwitching` is set, which
    /// nothing but a switch attempt does. A dismissal alone is NOT a signal (a
    /// mutation run showed the picker can disappear for unrelated reasons, and a
    /// dismissal-only assertion passed with the card's selection surface
    /// removed), and the reported failure copy arrives only once the attempt
    /// fails, which took longer than the assertion window on CI — observed in
    /// this test's first CI run, where the rows were disabled exactly as a
    /// switch in flight predicts. The failure copy is still accepted so a fast
    /// failure cannot slip past the poll.
    ///
    /// The active profile is asserted nowhere here: it cannot change without a
    /// transport. Profile discovery and switch bookkeeping are unit-tested in
    /// `ProfileDiscoveryTests` and `YoloProfileSwitchBookkeepingTests`.
    func testTappingTheCardBodyInvokesSelection() throws {
        let app = launchWithSeededProfiles()
        openProfilePicker(app)
        let target = selectableProfileDisplayName(in: app)
        let photoControl = photoControl(for: target, in: app)
        let selectButton = selectButton(for: target, in: app)
        XCTAssertTrue(selectButton.isEnabled, "The target row must start selectable. Tree:\n\(app.debugDescription)")

        // Control: a part of the picker that holds no selection target must not
        // start a switch. The sheet title is a plain text, and the close control
        // sits at the trailing edge, away from its centre.
        let title = app.staticTexts[Identity.pickerTitle]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Picker title missing. Tree:\n\(app.debugDescription)")
        tapInWindow(app, at: CGPoint(x: title.frame.midX, y: title.frame.midY))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(
            selectButton.isEnabled && !switchAttemptReported(in: app),
            "A place with no selection target must not start a switch. Tree:\n\(app.debugDescription)"
        )

        // The probe is the gap just past the row's accessory: every interactive
        // element in the row ends at that accessory's trailing edge, so a point
        // beyond it is reached only by the card-sized selection surface behind
        // the row. (Taking the accessory's mid-point instead lands inside the
        // text column's button on rows whose accessory is a narrow chevron — the
        // mutation check for this test failed on exactly that mistake.) `x` comes
        // from the current row's marker and `y` from the target row's avatar, so
        // the probe is row-specific without depending on the card's bounds.
        let accessorySlot = app.staticTexts[Identity.currentMarker]
        XCTAssertTrue(accessorySlot.waitForExistence(timeout: 5), "No current profile marked. Tree:\n\(app.debugDescription)")
        tapInWindow(app, at: CGPoint(x: accessorySlot.frame.maxX + 6, y: photoControl.frame.midY))

        XCTAssertTrue(
            waitForSwitchInFlight(selectButton, in: app, timeout: 10),
            "Tapping the card body must invoke selection. Tree:\n\(app.debugDescription)"
        )
    }

    /// The nested photo control keeps its own action and must not also select the
    /// profile — that would switch and dismiss the picker underneath it.
    func testTappingThePhotoControlDoesNotSelectTheProfile() throws {
        let app = launchWithSeededProfiles()
        openProfilePicker(app)
        let before = app.buttons[Identity.workspace].label
        let target = selectableProfileDisplayName(in: app)

        photoControl(for: target, in: app).tap()

        // Positive control: the nested control's own action ran. The photo
        // library's permission alert can appear on a fresh simulator and would
        // otherwise block the picker the test waits for.
        allowPhotoAccessIfAsked(app)
        // The library UI runs out of process, and its first launch on a cold
        // hosted simulator is slow: in passing hosted runs Cancel appeared about
        // 17s after the tap, and all 8 failures of the old 15s wait (about 20s
        // after the tap) showed the picker sheet presented but its remote
        // content not yet loaded. Wait long enough for that cold start.
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 60), "The photo picker must appear. Tree:\n\(app.debugDescription)")
        cancel.tap()

        // The invariant: nothing selected behind it, so the picker is still
        // presented and the active profile is untouched.
        XCTAssertTrue(
            app.staticTexts[Identity.pickerTitle].waitForExistence(timeout: 5),
            "The profile picker must still be presented. Tree:\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            app.staticTexts[Identity.currentMarker].exists,
            "A current profile must still be marked. Tree:\n\(app.debugDescription)"
        )
        XCTAssertEqual(
            app.buttons[Identity.workspace].label,
            before,
            "No profile may switch underneath the picker"
        )
    }

    // MARK: - Helpers

    /// Launches the remembered-connected stub with the seeded profile roster.
    /// `profiles` stays optional rather than defaulted to a `Self.` constant: a
    /// covariant `Self` is not allowed in a default-argument expression.
    private func launchWithSeededProfiles(profiles: [String]? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [Identity.connectedDashboard, "https://conduit-ui-test.invalid"]
        app.launchArguments += [Identity.seededProfiles, (profiles ?? Self.seededProfiles).joined(separator: ",")]
        app.launch()
        return app
    }

    private func openProfilePicker(_ app: XCUIApplication) {
        let drawer = app.buttons[Identity.openSidebar]
        XCTAssertTrue(drawer.waitForExistence(timeout: 10), "Main UI did not appear. Tree:\n\(app.debugDescription)")
        drawer.tap()

        let workspace = app.buttons[Identity.workspace]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10), "Sidebar did not appear. Tree:\n\(app.debugDescription)")
        workspace.tap()

        XCTAssertTrue(
            app.staticTexts[Identity.pickerTitle].waitForExistence(timeout: 10),
            "Profile picker did not appear. Tree:\n\(app.debugDescription)"
        )
    }

    /// The seeded profile that is not the active one: the card only selects when
    /// the row is selectable, and with two seeds exactly one always is.
    ///
    /// Determined from row geometry — the row whose photo control sits at a
    /// different height than the current marker — rather than from the header
    /// label, which always contains the literal word "Workspace" and would make
    /// a name-substring test match every profile.
    private func selectableProfileDisplayName(in app: XCUIApplication) -> String {
        let marker = app.staticTexts[Identity.currentMarker]
        XCTAssertTrue(marker.waitForExistence(timeout: 5), "No current profile marked. Tree:\n\(app.debugDescription)")
        let currentRowMidY = marker.frame.midY
        let candidate = Self.seededDisplayNames.first { displayName in
            let control = app.buttons["Choose photo for \(displayName)"]
            return control.exists && abs(control.frame.midY - currentRowMidY) > 4
        }
        XCTAssertNotNil(candidate, "No selectable seeded row found. Tree:\n\(app.debugDescription)")
        return candidate ?? Self.seededDisplayNames[0]
    }

    /// The nested control that opens the photo picker for a row. Its label is
    /// built from the profile's display name, so it identifies the row without
    /// depending on the row's position.
    private func photoControl(for displayName: String, in app: XCUIApplication) -> XCUIElement {
        let control = app.buttons["Choose photo for \(displayName)"]
        XCTAssertTrue(control.waitForExistence(timeout: 5), "Photo control for \(displayName) missing. Tree:\n\(app.debugDescription)")
        return control
    }

    /// The row's own selection button: the one labelled with the profile's
    /// display name, alone or followed by its subtitle ("Work, Hermes profile";
    /// the photo control above starts with "Choose"). The name must end at the
    /// comma: a bare prefix match also hit the chat list's "Working" filter
    /// chip behind the sheet. It is disabled exactly while a switch is in flight.
    private func selectButton(for displayName: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label BEGINSWITH %@", displayName, displayName + ",")
        ).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Select button for \(displayName) missing. Tree:\n\(app.debugDescription)")
        return button
    }

    /// Taps an absolute point in the app's window — the card's padding has no
    /// element of its own to tap.
    private func tapInWindow(_ app: XCUIApplication, at point: CGPoint) {
        let window = app.windows.firstMatch
        let bounds = window.frame
        XCTAssertTrue(
            point.x > bounds.minX && point.x < bounds.maxX && point.y > bounds.minY && point.y < bounds.maxY,
            "Probe \(point) falls outside the window \(bounds)"
        )
        window
            .coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x, dy: point.y))
            .tap()
    }

    /// The photo control opens `UIImagePickerController`, which can ask for the
    /// photo library on a fresh simulator. Allow it when asked so the picker the
    /// test waits for can appear; a denial would leave the test failing on its
    /// own assertion rather than on an unexpected alert.
    private func allowPhotoAccessIfAsked(_ app: XCUIApplication) {
        let allow = app.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) {
            allow.tap()
        }
    }

    /// Whether the app has reported a workspace-switch attempt. Under the
    /// connected stub every attempt fails for lack of a transport, so a reported
    /// failure also proves selection ran; the copy asserted here is only a prefix
    /// so a reworded reason does not break the test.
    private func switchAttemptReported(in app: XCUIApplication) -> Bool {
        app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Could not switch")
        ).firstMatch.exists
    }

    /// Whether a switch is in flight: the row's select button is disabled while
    /// `AppState.isProfileSwitching` is set, and the reported failure covers the
    /// case where the attempt already failed by the time we look.
    private func waitForSwitchInFlight(_ selectButton: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !selectButton.isEnabled || switchAttemptReported(in: app) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return !selectButton.isEnabled || switchAttemptReported(in: app)
    }
}
