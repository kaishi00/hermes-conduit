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
        app.launchEnvironment["TZ"] = Self.timeZoneNearStatusBarTime()
        app.launch()
    }

    /// The status bar reads 9:41, so run the app in the zone where the demo
    /// chats, seeded minutes ago, were sent a little before that: 9 a.m.
    /// local, or 8 a.m. late in the hour so no time reads after 9:41.
    static func timeZoneNearStatusBarTime(now: Date = Date()) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents([.hour, .minute], from: now)
        var offset = ((parts.minute ?? 0) <= 41 ? 9 : 8) - (parts.hour ?? 0)
        if offset > 14 { offset -= 24 }
        if offset < -12 { offset += 24 }
        // POSIX zone names flip the sign: Etc/GMT-5 is five hours ahead.
        return offset == 0 ? "Etc/GMT" : String(format: "Etc/GMT%+d", -offset)
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

        for (number, tab) in [(5, "Tasks"), (7, "Bots"), (8, "Settings")] {
            let button = app.buttons[tab]
            guard button.waitForExistence(timeout: 5) else { continue }
            button.tap()
            if tab == "Tasks" { showBoardWork() }
            settle(3)
            snap(String(format: "%02d-%@", number, tab.lowercased()))
            if tab == "Tasks" {
                // The scheduled jobs share the tab with the board.
                let scheduled = app.buttons["Scheduled"]
                if scheduled.waitForExistence(timeout: 5) {
                    scheduled.tap()
                    _ = app.staticTexts["Morning briefing"].waitForExistence(timeout: 10)
                    settle(2)
                    snap("06-scheduled")
                    app.buttons["Board"].tap()
                }
            }
        }
        app.buttons["Chats"].tap()

        // Live voice: the real call screen over a scripted conversation
        // (Conduit/Services/ScreenshotCallFixture.swift); the sign-in is saved.
        for (number, state) in [(9, "speaking"), (10, "listening")] {
            app.terminate()
            app.launchArguments = ["-conduitScreenshotCall", state]
            app.launch()
            settle(5)
            snap(String(format: "%02d-voice-%@", number, state))
        }
    }

    /// Waits for the board, then scrolls it past the empty Triage column:
    /// to Ready on a phone, to Ready and Running on an iPad.
    private func showBoardWork() {
        _ = app.staticTexts["Book campsite for Big Sur"].waitForExistence(timeout: 30)
        let window = app.windows.firstMatch.frame
        let card = app.staticTexts[window.width > 700 ? "Compare flights to Tokyo" : "Book campsite for Big Sur"]
        for _ in 0..<5 {
            if card.exists, window.contains(card.frame) { return }
            let board = app.windows.firstMatch
            board.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.55))
                .press(forDuration: 0.05, thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.55)))
            settle(1)
        }
    }

    /// The App Preview: the workflow records the screen while this runs.
    /// Starts on the Chats list, opens a new chat, asks, and lets the
    /// scripted answer stream in.
    func testRecordPreview() throws {
        guard ProcessInfo.processInfo.environment["CONDUIT_RECORD_PREVIEW"] == "1" else {
            throw XCTSkip("Only the preview recording runs this")
        }
        signInIfNeeded()
        dismissFinishSetupCard()
        _ = app.staticTexts["Weekend trip to Big Sur"].waitForExistence(timeout: 30)
        settle(2)
        // Wall-clock markers in the test log, so the recording can be cut
        // to the part worth showing (scripts/app-store/cut-preview.sh).
        print("PREVIEW_MARK start \(Date().timeIntervalSince1970)")
        let newChat = app.buttons["New Chat"]
        guard newChat.waitForExistence(timeout: 10) else {
            snap("debug-no-new-chat")
            return
        }
        newChat.tap()
        settle(1.5)
        let composer = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        composer.tap()
        composer.typeText("What should we pack for the Big Sur trip?")
        settle(0.5)
        app.buttons["Send message"].tap()
        // The scripted answer streams for about 15 s.
        let done = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'trip notes'")).firstMatch
        _ = done.waitForExistence(timeout: 40)
        settle(3)
        print("PREVIEW_MARK end \(Date().timeIntervalSince1970)")
        snap("10-preview-end")
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

    /// Back to the Chats list. The list and tab bar stay in the hierarchy
    /// under a pushed chat, so the chat's own menu button is the sign a
    /// chat is still showing.
    private func backToTabs() {
        let chatMenu = app.buttons["conversation.menu"]
        for _ in 0..<3 where chatMenu.exists {
            // The V2 conversation's Back: the small round button top left.
            let screen = app.frame
            let back = app.buttons.allElementsBoundByIndex.first { button in
                let f = button.frame
                return f.width > 0 && f.width <= 64 && f.minX < screen.width * 0.15 && f.minY < screen.height * 0.12
            }
            if let back, back.isHittable {
                back.tap()
            } else {
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
            }
            let deadline = Date().addingTimeInterval(4)
            while chatMenu.exists, Date() < deadline { Thread.sleep(forTimeInterval: 0.3) }
        }
        if chatMenu.exists {
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
