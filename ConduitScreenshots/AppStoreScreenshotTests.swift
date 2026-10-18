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
        continueAfterFailure = true
        guard demoURL != nil else { throw XCTSkip("CONDUIT_DEMO_URL is not set") }
        app = XCUIApplication()
        app.launch()
    }

    func testCaptureAppStoreScreens() throws {
        signInIfNeeded()
        dismissFinishSetupCard()
        // The list fills from the dashboard; wait for the newest chat.
        _ = app.staticTexts["Weekend trip to Big Sur"].waitForExistence(timeout: 30)
        settle()
        snap("01-chats")

        openChat("Q3 spending summary", waitingFor: "Dining out")
        snap("02-chat-steps")
        backToTabs()

        openChat("Weekend trip to Big Sur", waitingFor: "Sierra Mar")
        snap("03-chat-trip")
        backToTabs()

        openChat("Fix the flaky upload test", waitingFor: "50 runs")
        snap("04-chat-code")
        backToTabs()

        for (number, tab) in [(5, "Tasks"), (6, "Bots"), (7, "Settings")] {
            let button = app.buttons[tab]
            guard button.waitForExistence(timeout: 5) else { continue }
            button.tap()
            settle(3)
            snap(String(format: "%02d-%@", number, tab.lowercased()))
        }
        app.buttons["Chats"].tap()
    }

    private func openChat(_ title: String, waitingFor text: String) {
        let row = app.staticTexts[title]
        guard row.waitForExistence(timeout: 15) else {
            snap("debug-missing-\(title)")
            return
        }
        row.tap()
        let content = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
        if !content.waitForExistence(timeout: 20) { snap("debug-slow-\(title)") }
        settle(3)
    }

    /// Back to the Chats list. The tab bar stays in the hierarchy (and
    /// reports itself hittable) under a pushed chat, so the list's own
    /// search field is the sign the list is showing.
    private func backToTabs() {
        let list = app.descendants(matching: .any)
            .matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Search' OR label BEGINSWITH 'Search'")).firstMatch
        for _ in 0..<3 {
            if list.exists && list.isHittable { break }
            // The V2 conversation's Back is the top-left round button.
            let screen = app.frame
            let back = app.buttons.allElementsBoundByIndex.first { button in
                let f = button.frame
                return f.width > 0 && f.minX < screen.width * 0.15 && f.minY < screen.height * 0.12
            }
            if let back {
                back.tap()
            } else {
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
            }
            _ = list.waitForExistence(timeout: 4)
        }
        if !list.exists {
            snap("debug-back-failed")
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "debug-back-tree"
            tree.lifetime = .keepAlways
            add(tree)
        }
        settle()
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
