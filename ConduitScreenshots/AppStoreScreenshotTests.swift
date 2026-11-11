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
        if name.contains("testRecordPreview"), ProcessInfo.processInfo.environment["CONDUIT_RECORD_PREVIEW"] != "1" {
            throw XCTSkip("Only the preview recording runs this")
        }
        if name.contains("testRecordPromo"), ProcessInfo.processInfo.environment["CONDUIT_RECORD_PROMO"] != "1" {
            throw XCTSkip("Only the promo recording runs this")
        }
        app = XCUIApplication()
        app.launchEnvironment["TZ"] = Self.timeZoneNearStatusBarTime()
        // No tips over the screens (BotsHomeGesturesTip).
        app.launchEnvironment["CONDUIT_HIDE_TIPS"] = "1"
        // A still backdrop, so XCUITest's settle wait doesn't hang on its
        // drift and every shot shows the glows in the same place.
        app.launchEnvironment["CONDUIT_STILL_BACKDROP"] = "1"
        app.launch()
    }

    /// The status bar reads 9:41, so run the app in the zone where the demo
    /// chats, seeded minutes ago, were sent a little before that: 9 a.m.
    /// local, or 8 a.m. late in the hour so no time reads after 9:41.
    static func timeZoneNearStatusBarTime(now: Date = Date()) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let parts = utc.dateComponents([.hour, .minute], from: now)
        var offset = ((parts.minute ?? 0) <= 41 ? 9 : 8) - (parts.hour ?? 0)
        if offset > 14 { offset -= 24 }
        if offset < -12 { offset += 24 }
        // POSIX zone names flip the sign: Etc/GMT-5 is five hours ahead.
        return offset == 0 ? "Etc/GMT" : String(format: "Etc/GMT%+d", -offset)
    }

    func testCaptureAppStoreScreens() throws {
        signInIfNeeded()
        openSessions()
        dismissFinishSetupCard()
        // The list fills from the dashboard; wait for the newest chat.
        if !app.staticTexts["Weekend trip to Big Sur"].waitForExistence(timeout: 30) {
            XCTFail("The seeded chats never showed in the Chats list")
        }
        settle()
        snap("01-chats")

        if openChat("Q3 spending summary", waitingFor: "Dining out") { snap("02-chat-steps") }
        backToTabs()

        if openChat("Weekend trip to Big Sur", waitingFor: "Sierra Mar") { snap("03-chat-trip") }
        backToTabs()

        if openChat("Fix the flaky upload test", waitingFor: "50 runs") { snap("04-chat-code") }
        backToTabs()

        for (number, tab) in [(5, "Tasks"), (7, "Bots"), (8, "Settings")] {
            let button = app.buttons[tab]
            guard button.waitForExistence(timeout: 5) else {
                XCTFail("No \(tab) tab, so no \(tab) screenshot")
                continue
            }
            button.tap()
            if tab == "Tasks" { showBoardWork() }
            settle(3)
            snap(String(format: "%02d-%@", number, tab.lowercased()))
            if tab == "Tasks" {
                // The scheduled jobs share the tab with the board.
                let scheduled = app.buttons["Scheduled"]
                if scheduled.waitForExistence(timeout: 5) {
                    scheduled.tap()
                    if !app.staticTexts["Morning briefing"].waitForExistence(timeout: 10) {
                        XCTFail("The seeded scheduled jobs never showed")
                    }
                    settle(2)
                    snap("06-scheduled")
                    app.buttons["Board"].tap()
                } else {
                    XCTFail("No Scheduled button on the Tasks tab, so no scheduled screenshot")
                }
            }
        }
        app.buttons["Sessions"].tap()

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
        guard app.staticTexts["Book campsite for Big Sur"].waitForExistence(timeout: 30) else {
            XCTFail("The seeded board never loaded")
            return
        }
        let window = app.windows.firstMatch.frame
        let target = window.width > 700 ? "Compare flights to Tokyo" : "Book campsite for Big Sur"
        let card = app.staticTexts[target]
        let board = app.windows.firstMatch
        for _ in 0..<5 {
            if card.exists, window.contains(card.frame) { return }
            board.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.55))
                .press(forDuration: 0.05, thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.55)))
            settle(1)
        }
        if card.exists, window.contains(card.frame) { return }
        XCTFail("Could not scroll the board to \(target)")
    }

    /// The App Preview: the workflow records the screen while this runs.
    /// Starts on the Sessions list, opens a new chat, asks, and lets the
    /// scripted answer stream in.
    /// setUp skips it unless the recording asked for it.
    func testRecordPreview() throws {
        signInIfNeeded()
        openSessions()
        dismissFinishSetupCard()
        guard app.staticTexts["Weekend trip to Big Sur"].waitForExistence(timeout: 30) else {
            XCTFail("The seeded chats never showed, so the preview would start on an empty list")
            return
        }
        settle(2)
        // Wall-clock markers in the test log, so the recording can be cut
        // to the part worth showing (scripts/app-store/cut-preview.sh).
        print("PREVIEW_MARK start \(Date().timeIntervalSince1970)")
        let newChat = app.buttons["New Chat"]
        guard newChat.waitForExistence(timeout: 10) else {
            snap("debug-no-new-chat")
            XCTFail("No New Chat button, so the preview has nothing to record")
            return
        }
        newChat.tap()
        settle(1.5)
        let composer = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        // The composer can miss its first tap while the new chat settles.
        for _ in 0..<3 {
            composer.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 3) { break }
        }
        composer.typeText("What should we pack?")
        settle(0.5)
        app.buttons["Send message"].tap()
        // The scripted answer streams for about 15 s.
        let done = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'trip notes'")).firstMatch
        if !done.waitForExistence(timeout: 40) {
            XCTFail("The scripted packing answer never arrived")
        }
        settle(3)
        print("PREVIEW_MARK end \(Date().timeIntervalSince1970)")
        snap("10-preview-end")
        // The recording's last frame is the home screen this brings up, so
        // the cut dates the video from here (recordVideo starts late).
        app.terminate()
        print("PREVIEW_MARK stop \(Date().timeIntervalSince1970)")
    }

    /// The promo footage (app-store-promo.yml, against promo-script.json):
    /// Bots Home, then Conduit Chan's Bot Chat handing a weekend plan to
    /// two workstreams, approving the one that needs you, and back home.
    /// PROMO_MARK lines date each part for the edit. setUp skips it unless
    /// the promo recording asked for it.
    func testRecordPromo() throws {
        signInIfNeeded()
        // The setup card would push the portraits down Bots Home.
        dismissVisibleSetupCard()
        let portrait = app.buttons["Conduit Chan"].firstMatch
        // The hosted Mac can sit on "Loading bots…" well past its first
        // read; a relaunch (the sign-in is kept) reads the roster again.
        if !portrait.waitForExistence(timeout: 90) {
            snap("debug-bots-still-loading")
            app.terminate()
            app.launch()
            dismissVisibleSetupCard()
        }
        guard portrait.waitForExistence(timeout: 90) else {
            snap("debug-no-conduit-chan")
            XCTFail("Conduit Chan's portrait never showed on Bots Home")
            return
        }
        // The bots' pictures load after the roster: give them time. The
        // setup card can come in meanwhile (once the plugin is checked).
        settle(12)
        dismissVisibleSetupCard()
        print("PROMO_MARK home \(Date().timeIntervalSince1970)")
        snap("promo-01-bots-home")
        settle(2)
        // The Bot Chat is ready once its history shows (her morning reply).
        // On the hosted Mac its first read can fail; back out and open it
        // again rather than film a chat that can't send.
        let history = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'dentist is at 2'")).firstMatch
        let restoreFailed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Failed to restore'")).firstMatch
        var opened = false
        for attempt in 1...4 {
            portrait.tap()
            if history.waitForExistence(timeout: 30), !restoreFailed.exists {
                opened = true
                break
            }
            snap("debug-bot-chat-attempt-\(attempt)")
            print("PROMO_MARK reopen \(Date().timeIntervalSince1970)")
            leaveBotChat()
            if !portrait.waitForExistence(timeout: 10) { app.buttons["Bots"].firstMatch.tap() }
            settle(8)
        }
        guard opened else {
            XCTFail("Conduit Chan's Bot Chat never opened with its history")
            return
        }
        let composer = app.textViews.firstMatch.exists
            ? app.textViews.firstMatch
            : app.textFields.matching(NSPredicate(format: "NOT (placeholderValue BEGINSWITH 'Search')")).firstMatch
        settle(2.5)
        print("PROMO_MARK botchat \(Date().timeIntervalSince1970)")
        for _ in 0..<3 {
            composer.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 3) { break }
        }
        composer.typeText("Plan our Kyoto weekend: find a ryokan under $300, and clear the duplicates out of my trip photos.")
        settle(0.8)
        app.buttons["Send message"].tap()
        print("PROMO_MARK sent \(Date().timeIntervalSince1970)")
        // Both workstreams start; W1 reports, then W2 asks before it
        // deletes, and the line under the title says it needs you.
        let needsYou = app.buttons["botWork.titleLine"].firstMatch
        let asking = NSPredicate(format: "label CONTAINS[c] 'needs you'")
        expectation(for: asking, evaluatedWith: needsYou)
        waitForExpectations(timeout: 120) { error in
            if error != nil { self.snap("debug-no-needs-you") }
        }
        // Conduit Chan says so too (her update lands a few seconds later).
        _ = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'needs your OK'")).firstMatch
            .waitForExistence(timeout: 30)
        settle(2.5)
        print("PROMO_MARK needs-you \(Date().timeIntervalSince1970)")
        snap("promo-02-needs-you")
        let approve = app.buttons["Approve"].firstMatch
        let panel = app.descendants(matching: .any)["botWork.panel"].firstMatch
        // The Work panel: both workstreams, and W2's approval card. A tap
        // while the chat is still settling can miss it, so try again.
        for _ in 0..<2 where !approve.isHittable {
            needsYou.tap()
            print("PROMO_MARK panel \(Date().timeIntervalSince1970)")
            if panel.waitForExistence(timeout: 6) || approve.waitForExistence(timeout: 2) { break }
        }
        // On the hosted Mac the status line's tap sometimes opens nothing.
        // The same panel is the bot's overview on Bots Home (its ⓘ), with
        // Chat with Conduit Chan to come back.
        var fromOverview = false
        if !approve.waitForExistence(timeout: 4) {
            leaveBotChat()
            let overview = app.buttons["bots.overview.conduit-chan"].firstMatch
            if overview.waitForExistence(timeout: 10) {
                overview.tap()
                fromOverview = true
                print("PROMO_MARK overview \(Date().timeIntervalSince1970)")
            }
        }
        guard approve.waitForExistence(timeout: 15) else {
            snap("debug-no-approval")
            XCTFail("The photo cleanup's approval never showed")
            return
        }
        settle(3)
        print("PROMO_MARK approval \(Date().timeIntervalSince1970)")
        snap("promo-03-approval")
        approve.tap()
        print("PROMO_MARK approved \(Date().timeIntervalSince1970)")
        // W2 finishing shows on its row before the panel goes.
        _ = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] '214 duplicates deleted'")).firstMatch
            .waitForExistence(timeout: 30)
        settle(2.5)
        if fromOverview {
            // Back into her Bot Chat for the wrap-up.
            let chat = app.descendants(matching: .any)["botOverview.chat"].firstMatch
            if chat.waitForExistence(timeout: 5) { chat.tap() }
            print("PROMO_MARK back-to-chat \(Date().timeIntervalSince1970)")
        } else if app.otherElements["botWork.panel"].exists {
            let close = app.otherElements["botWork.panel"].buttons["Close"].firstMatch
            if close.exists, close.isHittable {
                close.tap()
            } else {
                app.otherElements["botWork.panel"].swipeDown(velocity: .fast)
            }
            print("PROMO_MARK panel-closed \(Date().timeIntervalSince1970)")
        }
        let done = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'all set'")).firstMatch
        if !done.waitForExistence(timeout: 90) {
            XCTFail("Conduit Chan never wrapped up")
        }
        // Her last reply in full, not under the jump-to-latest button.
        // SwiftUI names the button after its icon; its label is the words.
        let latest = app.buttons["arrow.down"].exists
            ? app.buttons["arrow.down"].firstMatch
            : app.buttons["Scroll to latest message"].firstMatch
        if latest.exists, latest.isHittable { latest.tap() }
        settle(4)
        print("PROMO_MARK done \(Date().timeIntervalSince1970)")
        snap("promo-04-wrapped-up")
        leaveBotChat()
        let bots = app.buttons["Bots"].firstMatch
        if bots.exists, !portrait.isHittable { bots.tap() }
        settle(4)
        print("PROMO_MARK home-again \(Date().timeIntervalSince1970)")
        snap("promo-05-bots-home-after")
        settle(2)
        print("PROMO_MARK end \(Date().timeIntervalSince1970)")
    }

    /// The setup card's Not now, only where it's on screen. The Sessions
    /// tab keeps its own copy in the tree, so a card already gone from Bots
    /// Home still matches; tapping where that copy sits would land on a
    /// portrait instead.
    private func dismissVisibleSetupCard() {
        let visible = app.buttons.matching(identifier: "finish-setup.not-now")
            .allElementsBoundByIndex.first { $0.isHittable }
        guard let visible else { return }
        visible.tap()
        settle(2)
    }

    /// Back from a Bot Chat to Bots Home: its back button (labelled with
    /// the screen it returns to), tapped where it is.
    private func leaveBotChat() {
        let back = app.buttons["BackButton"].firstMatch
        for _ in 0..<3 {
            guard back.waitForExistence(timeout: 3) else { return }
            back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if back.waitForNonExistence(timeout: 4) { break }
        }
        settle()
    }

    /// Opens a seeded chat and waits for its answer. False (and a failed
    /// test) when either is missing, so no other screen is saved under the
    /// chat's name.
    private func openChat(_ title: String, waitingFor text: String) -> Bool {
        let row = app.staticTexts[title]
        guard row.waitForExistence(timeout: 15) else {
            snap("debug-missing-\(title)")
            XCTFail("Seeded chat \(title) is not in the list")
            return false
        }
        row.tap()
        let content = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
        guard content.waitForExistence(timeout: 20) else {
            snap("debug-slow-\(title)")
            XCTFail("\(title) never showed \(text)")
            return false
        }
        settle(3)
        return true
    }

    /// The app opens on Bots; the chats are the Sessions tab.
    private func openSessions() {
        let sessions = app.buttons["Sessions"].firstMatch
        if sessions.waitForExistence(timeout: 10) { sessions.tap() }
    }

    /// Back to the Sessions list. The list and tab bar stay in the hierarchy
    /// under a pushed chat, so the chat's own menu button is the sign a
    /// chat is still showing. Beside the list on an iPad, the chat's Close.
    private func backToTabs() {
        let chatMenu = app.buttons["conversation.menu"]
        let close = app.buttons["conversation.close"]
        if close.exists {
            close.tap()
            _ = chatMenu.waitForNonExistence(timeout: 4)
        }
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
            XCTFail("Could not leave the chat after 3 Back attempts")
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
        // Bots Home and the Sessions tab can both hold the card: the one on
        // screen is the one to dismiss.
        let cards = app.buttons.matching(identifier: "finish-setup.not-now")
        guard cards.firstMatch.waitForExistence(timeout: 10) else {
            settle()
            return
        }
        let notNow = cards.allElementsBoundByIndex.first { $0.isHittable } ?? cards.firstMatch
        do {
            snap("debug-finish-setup")
            // Beside the empty chat column on an iPad, accessibility's hit
            // test misses the button though a touch lands; tap its point.
            if notNow.isHittable {
                notNow.tap()
            } else {
                notNow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            if !notNow.waitForNonExistence(timeout: 5) {
                snap("debug-finish-setup-stayed")
            }
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
