//
//  DemoVideoTests.swift
//  ConduitScreenshots
//
//  Plays the demo video scenes against two demo dashboards, Home and Studio
//  (scripts/app-store/videos/), while .github/workflows/demo-videos.yml
//  records the simulator. Each scene prints `SCENE start <name> <time>` and
//  `SCENE end <name> <time>`; scripts/app-store/cut-scenes.sh cuts one video
//  per scene from the recording, so the setup between scenes (signing in,
//  adding the second dashboard) never shows.
//
//  What changes on a dashboard mid-scene, a bot being added or a bot that
//  starts work on its own, comes from scripts/app-store/demo_director.py, a
//  server on the capture Mac that acts on the dashboards themselves.
//
//  Skipped unless CONDUIT_DEMO_VIDEOS=1. CONDUIT_DEMO_SCENES (comma-separated
//  names) limits which scenes are marked; the setup they need still runs.
//

import XCTest

final class DemoVideoTests: XCTestCase {
    private var app: XCUIApplication!

    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var homeURL: String { env["CONDUIT_DEMO_URL"] ?? "" }
    private var studioURL: String { env["CONDUIT_DEMO_URL_B"] ?? "" }
    private var demoUser: String { env["CONDUIT_DEMO_USER"] ?? "demo" }
    private var demoPassword: String { env["CONDUIT_DEMO_PASSWORD"] ?? "" }
    private var director: URL {
        URL(string: env["CONDUIT_DEMO_DIRECTOR"] ?? "") ?? URL(string: "http://127.0.0.1:8780")!
    }

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard env["CONDUIT_DEMO_VIDEOS"] == "1", !homeURL.isEmpty, !studioURL.isEmpty else {
            throw XCTSkip("Only the demo video recording runs this")
        }
        app = XCUIApplication()
        app.launchEnvironment["TZ"] = AppStoreScreenshotTests.timeZoneNearStatusBarTime()
        app.launchEnvironment["CONDUIT_HIDE_TIPS"] = "1"
        // The backdrop drifts as it does for people: these are videos.
        app.launch()
    }

    func testRecordDemoScenes() throws {
        // Setup: Home alone, one bot.
        signIn(to: homeURL)
        dismissSystemAlerts()
        dismissFinishSetupCard()
        openTab("Bots")
        XCTAssertTrue(named("Conduit-chan").waitForExistence(timeout: 40),
                      "Home's lone bot never showed on Bots Home")
        // Bots Home shows its own Finish setting up card, kept out of the shots.
        dismissFinishSetupCard()
        settle(3)

        scene("bots-home-layouts") {
            settle(4)
            for (bot, title) in [("mira", "Mira"), ("piko", "Piko"), ("riri", "Riri")] {
                direct("add-bot", ["dashboard": "home", "bot": bot])
                pullToRefresh()
                if !named(title).waitForExistence(timeout: 30) {
                    XCTFail("\(title) never joined Bots Home")
                }
                settle(4)
            }
        }

        // Setup: add Studio and combine the two, then come back to Home.
        addDashboard(studioURL)
        combineDashboards()
        switchToDashboard(containing: "hermes.tail-demo")
        openTab("Bots")
        XCTAssertTrue(named("Lucien").waitForExistence(timeout: 60),
                      "Studio's bots never joined Home's Bots Home")
        dismissFinishSetupCard()
        settle(4)

        scene("mixed-bots-home") {
            settle(4)
            tapBot("Lucien")
            XCTAssertTrue(waitForText("friendly, one line per change", timeout: 30), "Lucien's Bot Chat never opened")
            settle(4)
            goBack()
            settle(3)
        }

        scene("chats-strip") {
            openTab("Sessions")
            settle(4)
            // The other dashboard's default profile (Conduit-chan on Home,
            // Kael on Studio): its chip is v2.profile.<dashboard id>.default
            // and a tap switches straight there.
            let studioChats = "Release checklist for 2.4", homeChats = "Garden watering schedule"
            // Each tap lands on the dashboard it didn't start on. On a profile
            // without either list (Lucien's, say) the first tap may land on either.
            var shown: String? = waitForText(studioChats, timeout: 4) ? studioChats
                : (waitForText(homeChats, timeout: 2) ? homeChats : nil)
            // Over and back, ending on Home: the scenes after it start rooms
            // and chats from Home, the host of the room.
            for tap in 0..<3 {
                if tap >= 2 && shown == homeChats { break }
                let other = otherDashboardChip("default")
                guard other.waitForExistence(timeout: 20) else {
                    snap("debug-no-other-dashboard-chip")
                    XCTFail("No chip for the other dashboard's default profile in the Chats strip")
                    break
                }
                other.tap()
                // Neither list showing is Studio on another profile (Lucien's, after
                // mixed-bots-home), so Home is the likelier landing: tried first.
                let expected = shown.map { $0 == studioChats ? [homeChats] : [studioChats] } ?? [homeChats, studioChats]
                let landed = expected.first { waitForText($0, timeout: expected.count == 1 ? 30 : 20) }
                XCTAssertNotNil(landed, "The other dashboard's chats (\(expected.joined(separator: " or "))) never showed")
                shown = landed
                settle(4)
            }
        }

        scene("two-replying") {
            openTab("Bots")
            settle(2)
            tapBot("Piko")
            send("Plan a picnic for Saturday, four of us, no grill.")
            settle(3)
            goBack()
            direct("prompt", ["dashboard": "studio", "profile": "lucien", "text": "Draft the release notes for 2.4"])
            settle(8)
            openTab("Sessions")
            settle(6)
            openTab("Bots")
            settle(4)
        }

        scene("reorder") {
            settle(2)
            drag(bot: "Riri", onto: "Conduit-chan", overFace: false, hold: 0.8)
            settle(3)
            drag(bot: "Mira", onto: "Piko", overFace: false, hold: 0.8)
            settle(4)
        }

        scene("room-across") {
            settle(2)
            // Held over Lucien's face past the merge dwell: a room.
            drag(bot: "Mira", onto: "Lucien", overFace: true, hold: 1.5)
            let create = app.buttons["bots.newRoom.create"]
            if create.waitForExistence(timeout: 15) {
                let name = app.textFields["bots.newRoom.name"]
                if name.exists {
                    name.tap()
                    name.typeText("Launch plan")
                }
                settle(1)
                create.tap()
            } else {
                XCTFail("Dropping Mira on Lucien started no room")
            }
            settle(4)
            send("@Mira @Lucien plan the launch post for Friday")
            XCTAssertTrue(waitForText("subreddit", timeout: 60), "The room's bots never answered")
            settle(6)
        }

        scene("room-approval") {
            // Mira is the room host's own bot, so her approval is the room's
            // to answer; a far bot's waits on its own Hermes.
            send("@Mira publish the draft to the blog")
            let run = app.buttons["Run"].firstMatch
            if run.waitForExistence(timeout: 60) {
                settle(3)
                run.tap()
                XCTAssertTrue(waitForText("Published", timeout: 60), "Mira never finished after the approval")
            } else {
                XCTFail("No approval card in the room")
            }
            settle(5)
            goBack()
        }

        scene("needs-you") {
            openTab("Sessions")
            settle(3)
            direct("prompt", ["dashboard": "studio", "profile": "chibi-conduit", "text": "Clear out the old mockups"])
            let banner = app.buttons["needsYou.banner.open"]
            if banner.waitForExistence(timeout: 60) {
                settle(3)
                banner.tap()
                let run = app.buttons["Run"].firstMatch
                if run.waitForExistence(timeout: 30) {
                    settle(3)
                    run.tap()
                    XCTAssertTrue(waitForText("current designs are untouched", timeout: 60),
                                  "Chibi never finished after the approval")
                } else {
                    XCTFail("Needs you opened no approval")
                }
            } else {
                XCTFail("No Needs you banner for Studio's approval")
            }
            settle(5)
        }
        app.terminate()
        print("SCENE stop all \(Date().timeIntervalSince1970)")
    }

    // MARK: - Scenes

    private var wantedScenes: Set<String>? {
        guard let list = env["CONDUIT_DEMO_SCENES"], !list.isEmpty else { return nil }
        return Set(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// Marks a scene for the cut. A scene that wasn't asked for still runs,
    /// since the next one may build on it, but isn't marked.
    private func scene(_ name: String, _ body: () -> Void) {
        let marked = wantedScenes?.contains(name) ?? true
        if marked { print("SCENE start \(name) \(Date().timeIntervalSince1970)") }
        body()
        if marked { print("SCENE end \(name) \(Date().timeIntervalSince1970)") }
        snap("scene-\(name)-end")
    }

    // MARK: - Director

    /// Asks demo_director.py to act on a dashboard and waits for it.
    private func direct(_ action: String, _ body: [String: String]) {
        var request = URLRequest(url: director.appendingPathComponent(action))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 180
        let done = expectation(description: "director \(action)")
        var failure: String?
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                failure = error.localizedDescription
            } else if (response as? HTTPURLResponse)?.statusCode != 200 {
                failure = String(data: data ?? Data(), encoding: .utf8)
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 200)
        if let failure { XCTFail("director \(action) \(body): \(failure)") }
    }

    // MARK: - Steps

    private func openTab(_ name: String) {
        let tab = app.buttons[name].firstMatch
        if tab.waitForExistence(timeout: 10) { tab.tap() } else { XCTFail("No \(name) tab") }
    }

    private func tapBot(_ title: String) {
        let bot = named(title)
        guard bot.waitForExistence(timeout: 20) else {
            XCTFail("No \(title) on Bots Home")
            return
        }
        bot.tap()
    }

    /// Picks a bot's portrait up and carries it to another's. Held over
    /// the target's name, off its face, past BotDragPayload.slideDwell
    /// (300 ms) it takes the target's place (a reorder); held still over the
    /// face past mergeDwell (500 ms) it starts a room, when the two can make
    /// one (a far bot needs a bot of the dashboard on screen).
    private func drag(bot: String, onto target: String, overFace: Bool, hold: TimeInterval) {
        let from = named(bot)
        let to = named(target)
        guard from.waitForExistence(timeout: 10), to.waitForExistence(timeout: 10) else {
            XCTFail("Can't drag \(bot) onto \(target): one isn't on screen")
            return
        }
        let start = from.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        // The portrait button is the face; its name sits just under it.
        let end = to.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: overFace ? 0.45 : 1.25))
        start.press(forDuration: 1.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: hold)
    }

    /// The first element labelled exactly so: on Bots Home, a bot's portrait.
    private func named(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func pullToRefresh() {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
    }

    private func send(_ text: String) {
        let composer = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        guard composer.waitForExistence(timeout: 20) else {
            XCTFail("No composer to send \(text)")
            return
        }
        for _ in 0..<3 {
            composer.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 3) { break }
        }
        waitForKeyboardFocus(composer)
        composer.typeText(text)
        settle(0.5)
        app.buttons["Send message"].firstMatch.tap()
    }

    /// Another combined dashboard's chip for `profile` in the profile strip
    /// (V2TopBar.otherChip): v2.profile.<dashboard UUID>.<profile>.
    private func otherDashboardChip(_ profile: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier MATCHES %@",
                                         "v2\\.profile\\.[0-9A-Fa-f-]{36}\\.\(profile)")).firstMatch
    }

    private func waitForText(_ text: String, timeout: TimeInterval) -> Bool {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text))
            .firstMatch.waitForExistence(timeout: timeout)
    }

    /// Back out of a chat or room: its Close beside the list on an iPad,
    /// else the round Back button top left, else an edge swipe.
    private func goBack() {
        let close = app.buttons["conversation.close"]
        if close.exists {
            close.tap()
            return
        }
        let screen = app.frame
        let back = app.buttons.allElementsBoundByIndex.first { button in
            let f = button.frame
            return f.width > 0 && f.width <= 64 && f.minX < screen.width * 0.15 && f.minY < screen.height * 0.12
        }
        if let back, back.isHittable {
            back.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        }
        settle(1)
    }

    // MARK: - Dashboards

    /// Signs in on the first-launch login (`login.` fields) or the Add
    /// Dashboard sheet (`add-dashboard.`; LoginContext.identifierPrefix).
    /// Already signed in at launch, there's no address field: that's fine
    /// only for the first-launch login.
    private func signIn(to url: String, prefix: String = "login") {
        let serverField = app.textFields["\(prefix).server-url"]
        guard serverField.waitForExistence(timeout: 20) else {
            if prefix != "login" {
                snap("debug-no-address-field")
                XCTFail("No \(prefix).server-url field to sign in to \(url)")
            }
            return
        }
        serverField.tap()
        waitForKeyboardFocus(serverField)
        serverField.typeText(url + "\n")
        enterCredentials(for: url)
    }

    /// The sign-in step's username and password, typed fresh.
    private func enterCredentials(for url: String) {
        let username = app.textFields["login.username"]
        guard username.waitForExistence(timeout: 30) else {
            snap("debug-no-sign-in-step")
            XCTFail("Sign-in step missing for \(url)")
            return
        }
        username.tap()
        waitForKeyboardFocus(username)
        if let current = username.value as? String, !current.isEmpty, current != "Username" {
            username.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        username.typeText(demoUser)
        let password = app.secureTextFields["login.password"]
        password.tap()
        waitForKeyboardFocus(password)
        password.typeText(demoPassword + "\n")
    }

    /// Settings > Saved Dashboards, from wherever Settings was left: the
    /// tab keeps its pushed page, so an open one is used as it is, and a
    /// deeper one is backed out of until the Settings home shows.
    private func openSavedDashboards() {
        openTab("Settings")
        let onPage = app.buttons["settings.add-dashboard"].firstMatch
        if onPage.waitForExistence(timeout: 3) { return }
        let row = app.buttons["settings.saved-dashboards"].firstMatch
        for _ in 0..<3 where !row.waitForExistence(timeout: 3) {
            goBack()
            if onPage.exists { return }
        }
        if row.waitForExistence(timeout: 10) {
            row.tap()
        } else {
            snap("debug-no-saved-dashboards")
            XCTFail("No Saved Dashboards row in Settings")
        }
    }

    private func addDashboard(_ url: String) {
        openSavedDashboards()
        let add = app.buttons["settings.add-dashboard"].firstMatch
        guard add.waitForExistence(timeout: 10) else {
            XCTFail("No Add Dashboard button")
            return
        }
        add.tap()
        signIn(to: url, prefix: "add-dashboard")
        dismissSystemAlerts()
        // The sheet closes once the new dashboard is signed in.
        _ = app.buttons["add-dashboard.cancel"].waitForNonExistence(timeout: 60)
        dismissFinishSetupCard()
        settle(3)
    }

    private func combineDashboards() {
        openSavedDashboards()
        let switches = app.switches.matching(identifier: "settings.combine-dashboard")
        let first = switches.firstMatch
        guard first.waitForExistence(timeout: 10) else {
            XCTFail("No Combine Dashboards switches")
            return
        }
        for index in 0..<switches.count {
            let toggle = switches.element(boundBy: index)
            if (toggle.value as? String) != "1" {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
                settle(1)
            }
        }
        settle(5)
    }

    /// Opens a saved dashboard by a word of its row (its address).
    private func switchToDashboard(containing text: String) {
        openSavedDashboards()
        let row = app.buttons.matching(NSPredicate(format: "identifier == 'settings.dashboard.row' AND label CONTAINS[c] %@", text)).firstMatch
        if row.waitForExistence(timeout: 10) {
            row.tap()
            settle(5)
        } else {
            XCTFail("No saved dashboard with \(text)")
            return
        }
        // The simulator build is unsigned, so the Keychain keeps no sign-in
        // (errSecMissingEntitlement) and going back to a dashboard asks for
        // one again: Welcome back, its row, then the sign-in step. The one
        // left stays connected beside it, being combined.
        let welcome = app.buttons.matching(NSPredicate(
            format: "identifier == 'login.dashboard.combined' OR identifier == 'login.dashboard.row'")).firstMatch
        guard welcome.waitForExistence(timeout: 10) else { return }
        welcome.tap()
        enterCredentials(for: text)
        dismissSystemAlerts()
        _ = app.buttons["Bots"].waitForExistence(timeout: 60)
        dismissFinishSetupCard()
        settle(3)
    }

    private func dismissFinishSetupCard() {
        // The card can show on more than one screen at once (Settings and
        // the tab behind it), so each copy is answered by its own element.
        let cards = app.buttons.matching(identifier: "finish-setup.not-now")
        guard cards.firstMatch.waitForExistence(timeout: 8) else { return }
        for notNow in cards.allElementsBoundByIndex where notNow.exists {
            if notNow.isHittable {
                notNow.tap()
            } else {
                notNow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            settle(1)
        }
    }

    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Don’t Allow", "Not Now", "OK"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 2) { button.tap() }
        }
    }

    private func waitForKeyboardFocus(_ field: XCUIElement, timeout: TimeInterval = 40) {
        let deadline = Date().addingTimeInterval(timeout)
        let retapAt = Date().addingTimeInterval(timeout / 2)
        var tappedAgain = false
        while Date() < deadline {
            if (field.value(forKey: "hasKeyboardFocus") as? Bool) == true { return }
            if !tappedAgain, Date() >= retapAt {
                tappedAgain = true
                if field.isHittable { field.tap() }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("A field never got keyboard focus")
    }

    private func settle(_ seconds: TimeInterval = 2) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// A still per scene, for checking a run without the video.
    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
