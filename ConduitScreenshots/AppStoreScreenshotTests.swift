//
//  AppStoreScreenshotTests.swift
//  ConduitScreenshots
//
//  Walks the app against the demo dashboard that
//  scripts/app-store/start-demo-hermes.sh starts, and keeps a named
//  screenshot of each App Store screen as a test attachment
//  (.github/workflows/app-store-screenshots.yml exports them). Skipped
//  unless CONDUIT_DEMO_URL is set (xcodebuild passes TEST_RUNNER_CONDUIT_DEMO_URL),
//  so it never runs against nothing.
//

import XCTest

final class AppStoreScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    private var demoURL: String? { ProcessInfo.processInfo.environment["CONDUIT_DEMO_URL"] }
    private var demoUser: String { ProcessInfo.processInfo.environment["CONDUIT_DEMO_USER"] ?? "demo" }
    private var demoPassword: String { ProcessInfo.processInfo.environment["CONDUIT_DEMO_PASSWORD"] ?? "" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard demoURL != nil else { throw XCTSkip("CONDUIT_DEMO_URL is not set") }
        app = XCUIApplication()
        app.launch()
    }

    func testCaptureAppStoreScreens() throws {
        signInIfNeeded()
        dismissFinishSetupCard()
        snap("01-chats")

        let chat = app.staticTexts["Weekend trip to Big Sur"]
        XCTAssertTrue(chat.waitForExistence(timeout: 20), "Demo chat missing. Tree:\n\(app.debugDescription)")
        chat.tap()
        settle()
        snap("02-chat")
    }

    // MARK: - Steps

    private func signInIfNeeded() {
        let serverField = app.textFields["login.server-url"]
        guard serverField.waitForExistence(timeout: 15) else { return }
        serverField.tap()
        serverField.typeText(demoURL ?? "")
        snap("debug-login-address")
        // Return submits the address. Tapping Continue under the keyboard
        // can land on the keyboard toolbar's Done instead.
        serverField.typeText("\n")

        let username = app.textFields["login.username"]
        if !username.waitForExistence(timeout: 30) {
            snap("debug-no-sign-in-step")
            XCTFail("Sign-in step missing. Tree:\n\(app.debugDescription)")
            return
        }
        snap("debug-login-password-step")
        username.tap()
        if let current = username.value as? String, !current.isEmpty, current != "Username" {
            username.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        username.typeText(demoUser)
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText(demoPassword + "\n")
        snap("debug-after-sign-in")
        dismissSystemAlerts()
    }

    private func dismissFinishSetupCard() {
        let notNow = app.buttons["finish-setup.not-now"]
        if notNow.waitForExistence(timeout: 10) {
            snap("debug-finish-setup")
            notNow.tap()
        }
        settle()
    }

    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Don’t Allow", "Not Now", "OK"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 2) { button.tap() }
        }
    }

    // MARK: - Capture

    private func settle(_ seconds: TimeInterval = 2) {
        // Screenshots want the screen at rest, not a condition: animations,
        // image loads and the streaming caret all finish within this.
        Thread.sleep(forTimeInterval: seconds)
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
