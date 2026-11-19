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
//  CONDUIT_DEMO_LOCALE=zh-Hans runs the app in Simplified Chinese against the
//  dashboards of scripts/app-store/videos/zh-Hans/: every label the test taps
//  and every line it types or waits for goes through L(_:).
//

import XCTest

final class DemoVideoTests: XCTestCase {
    private var app: XCUIApplication!

    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var homeURL: String { env["CONDUIT_DEMO_URL"] ?? "" }
    private var studioURL: String { env["CONDUIT_DEMO_URL_B"] ?? "" }
    private var demoUser: String { env["CONDUIT_DEMO_USER"] ?? "demo" }
    private var demoPassword: String { env["CONDUIT_DEMO_PASSWORD"] ?? "" }
    private var locale: String { env["CONDUIT_DEMO_LOCALE"] ?? "" }
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
        if locale == "zh-Hans" {
            app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        }
        // The backdrop drifts as it does for people: these are videos.
        app.launch()
    }

    func testRecordDemoScenes() throws {
        // Getting started: the sign-in screen, its Connection Setup guide
        // (is the dashboard running, then the ways to reach it, and what
        // to ask Hermes for Tailscale), then signing in to Home, one bot.
        scene("onboarding") {
            showConnectionSetup()
            signIn(to: homeURL)
            dismissSystemAlerts()
            dismissFinishSetupCard()
            openTab("Bots")
            XCTAssertTrue(named("Conduit-chan").waitForExistence(timeout: 40),
                          "Home's lone bot never showed on Bots Home")
            settle(3)
        }
        // Bots Home shows its own Finish setting up card, kept out of the shots.
        dismissFinishSetupCard()
        settle(3)

        // A new chat on Home: a plan that streams in as Markdown, then a follow-up.
        scene("chat") {
            openTab("Sessions")
            settle(2)
            let newChat = app.buttons[L("New Chat")].firstMatch
            if newChat.waitForExistence(timeout: 10) {
                newChat.tap()
                settle(1.5)
                send(L("Can you plan a weekend in Big Sur for us? Leaving from SF Saturday morning."))
                XCTAssertTrue(waitForText(L("Want me to check campsites"), timeout: 60), "The trip plan never arrived")
                settle(4)
                send(L("Yes please, and find somewhere good for dinner Saturday."))
                XCTAssertTrue(waitForText(L("trip notes"), timeout: 60), "The dinner answer never arrived")
                settle(5)
                goBack()
            } else {
                XCTFail("No New Chat button on Sessions")
            }
            settle(2)
        }

        // The Tasks tab: Home's board, then its scheduled jobs.
        scene("tasks") {
            openTab("Tasks")
            if waitForText(L("Book campsite for Big Sur"), timeout: 30) {
                settle(3)
                let board = app.windows.firstMatch
                for _ in 0..<2 {
                    board.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.55))
                        .press(forDuration: 0.05, thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.55)))
                    settle(2)
                }
                let scheduled = app.buttons[L("Scheduled")].firstMatch
                if scheduled.waitForExistence(timeout: 5) {
                    scheduled.tap()
                    _ = waitForText(L("Morning briefing"), timeout: 10)
                    settle(4)
                    app.buttons[L("Board")].firstMatch.tap()
                }
            } else {
                XCTFail("Home's board never loaded")
            }
            settle(2)
        }

        openTab("Bots")
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

        // Bot Mode: Mira's Bot Chat hands a two-part request to two
        // workstreams, the Work panel shows them running, and each one's
        // report comes back into the chat.
        scene("bot-work") {
            tapBot("Mira")
            settle(2)
            send(L("Tidy up the 2.4 release notes, and see what people on Reddit are saying about 2.4."))
            XCTAssertTrue(waitForText(L("Started two workstreams"), timeout: 60), "Mira never started her workstreams")
            settle(2)
            let titleLine = app.buttons["botWork.titleLine"].firstMatch
            if titleLine.waitForExistence(timeout: 30) {
                titleLine.tap()
                let panel = app.descendants(matching: .any)["botWork.panel"].firstMatch
                XCTAssertTrue(app.descendants(matching: .any)["botWork.row.W1"].firstMatch.waitForExistence(timeout: 30),
                              "The Work panel never listed W1")
                settle(10)
                // The panel is a sheet on a phone: pulled down from its top.
                if panel.exists {
                    panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
                        .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch
                            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
                    settle(1)
                }
            } else {
                XCTFail("Mira's Bot Chat showed no work under its title")
            }
            XCTAssertTrue(waitForText(L("add a setup section"), timeout: 120), "W2's report never came back to Mira's Bot Chat")
            settle(5)
            goBack()
            settle(2)
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
            XCTAssertTrue(waitForText(L("friendly, one line per change"), timeout: 30), "Lucien's Bot Chat never opened")
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
            let studioChats = L("Release checklist for 2.4"), homeChats = L("Garden watering schedule")
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
            send(L("Plan a picnic for Saturday, four of us, no grill."))
            settle(3)
            goBack()
            direct("prompt", ["dashboard": "studio", "profile": "lucien", "text": L("Draft the release notes for 2.4")])
            settle(8)
            openTab("Sessions")
            settle(6)
            openTab("Bots")
            settle(4)
        }

        scene("reorder") {
            settle(2)
            // Studio's bots: a far portrait has no long-press menu, so a
            // press lifts it rather than opening one.
            reorder("Lucien", onto: "Riri")
            settle(3)
            reorder("Kael", onto: "Piko")
            settle(4)
        }

        readOwnBots()
        scene("room-across") {
            settle(2)
            // Studio's Lucien held over Home's Mira past the merge dwell: a room.
            let create = app.buttons["bots.newRoom.create"]
            if drag(bot: "Lucien", onto: "Mira", overFace: true, hold: 1.5, until: { create.waitForExistence(timeout: 5) }) {
                let name = app.textFields["bots.newRoom.name"]
                if name.exists {
                    name.tap()
                    name.typeText(L("Launch plan"))
                }
                settle(1)
                create.tap()
            } else {
                XCTFail("Dropping Lucien on Mira started no room")
            }
            settle(2)
            openRoom(L("Launch plan"))
            send(L("@Mira @Lucien plan the launch post for Friday"))
            XCTAssertTrue(waitForText(L("subreddit"), timeout: 60), "The room's bots never answered")
            settle(6)
        }

        scene("room-approval") {
            // Mira is the room host's own bot, so her approval is the room's
            // to answer; a far bot's waits on its own Hermes.
            send(L("@Mira publish the draft to the blog"))
            let run = app.buttons[L("Run")].firstMatch
            if run.waitForExistence(timeout: 60) {
                settle(3)
                run.tap()
                XCTAssertTrue(waitForText(L("Published"), timeout: 60), "Mira never finished after the approval")
            } else {
                XCTFail("No approval card in the room")
            }
            settle(5)
            goBack()
        }

        // A room with another person: Sam, on his own Hermes, linked as
        // someone else rather than as yours. New Group Chat invites him with
        // Conduit-chan; he joins with his bot Nori, and his lines come from
        // the director, as they would from his Conduit.
        scene("multiplayer") {
            settle(2)
            inviteSam(to: L("Weekend at Big Sur"))
            direct("join-room", ["dashboard": "sam", "room": L("Weekend at Big Sur")], timeout: 300)
            openRoom(L("Weekend at Big Sur"))
            send(L("@conduit-chan can you find us a campsite near Big Sur for the 22nd?"))
            XCTAssertTrue(waitForText(L("Kirk Creek"), timeout: 60), "Conduit-chan never answered in the room with Sam")
            settle(3)
            direct("room-say", ["dashboard": "sam", "room": L("Weekend at Big Sur"),
                                "text": L("Love it! @nori what's the drive time from the city, and where do we stop for lunch?")],
                   timeout: 300)
            XCTAssertTrue(waitForText(L("Carmel"), timeout: 90), "Sam's Nori never answered")
            settle(6)
            goBack()
        }

        scene("needs-you") {
            openTab("Sessions")
            settle(3)
            direct("prompt", ["dashboard": "studio", "profile": "chibi-conduit", "text": L("Clear out the old mockups")])
            let banner = app.buttons["needsYou.banner.open"]
            if banner.waitForExistence(timeout: 60) {
                settle(3)
                banner.tap()
                let run = app.buttons[L("Run")].firstMatch
                if run.waitForExistence(timeout: 30) {
                    settle(3)
                    run.tap()
                    XCTAssertTrue(waitForText(L("current designs are untouched"), timeout: 60),
                                  "Chibi never finished after the approval")
                } else {
                    XCTFail("Needs you opened no approval")
                }
            } else {
                XCTFail("No Needs you banner for Studio's approval")
            }
            settle(5)
        }
        // The video is dated from its end (cut-scenes.sh): a last change on
        // screen, the mark, and the recorder stopped right then.
        if !app.buttons[L("Bots")].firstMatch.exists { goBack() }
        openTab("Bots")
        settle(2)
        // Live voice: the real call screen over a scripted conversation
        // (ScreenshotCallFixture), titled Qwen Live, the provider a person in
        // China would pick; the sign-in is saved across the relaunch.
        app.terminate()
        app.launchArguments += ["-conduitScreenshotCall", "speaking", "-conduitScreenshotCallProvider", "qwen"]
        app.launch()
        settle(6)
        scene("voice") {
            settle(8)
        }
        print("SCENE stop all \(Date().timeIntervalSince1970)")
        direct("stop-recording", [:])
        app.terminate()
    }

    // MARK: - Locale

    /// `s` as the zh-Hans run shows or types it: the app's own label for a
    /// control (Localizable.xcstrings), or the line in videos/zh-Hans/.
    private func L(_ s: String) -> String {
        locale == "zh-Hans" ? (Self.zhHans[s] ?? s) : s
    }

    private static let zhHans: [String: String] = [
        // The app's labels.
        "Bots": "机器人", "Sessions": "会话", "Settings": "设置", "Run": "运行", "Create": "创建", "Cancel": "取消",
        "Delete Bot": "删除机器人", "Duplicate": "复制", "Send message": "发送消息", "Username": "用户名",
        "Group name": "群聊名称", "Waiting": "正在等待", "Starting": "正在启动", "New Chat": "新聊天",
        "Tasks": "任务", "Scheduled": "已排期", "Board": "看板",
        "A room can bring bots from one of your other Hermes": "一个房间可以在至少一个你在这里的机器人之外",
        // Lines from the zh-Hans dashboards.
        "Can you plan a weekend in Big Sur for us? Leaving from SF Saturday morning.": "帮我们规划一个莫干山周末？周六早上从上海出发。",
        "Want me to check campsites": "要我查一下营地吗",
        "Yes please, and find somewhere good for dinner Saturday.": "好啊，再找个周六晚饭的地方。",
        "trip notes": "行程笔记",
        "Book campsite for Big Sur": "预订莫干山营地",
        "Morning briefing": "早间简报",
        "friendly, one line per change": "每条改动一行",
        "Release checklist for 2.4": "2.4 发布清单",
        "Garden watering schedule": "花园浇水计划",
        "Plan a picnic for Saturday, four of us, no grill.": "帮我们安排周六的野餐，四个人，不能烧烤。",
        "Draft the release notes for 2.4": "写一下 2.4 的版本说明",
        "Launch plan": "发布计划",
        "@Mira @Lucien plan the launch post for Friday": "@Mira @Lucien 规划一下周五的发布帖",
        "subreddit": "V2EX",
        "@Mira publish the draft to the blog": "@Mira 把草稿发布到博客",
        "Published": "已发布",
        "Weekend at Big Sur": "莫干山周末",
        "@conduit-chan can you find us a campsite near Big Sur for the 22nd?": "@conduit-chan 帮我们找一下莫干山附近的营地，22 号的？",
        "Kirk Creek": "营位",
        "Love it! @nori what's the drive time from the city, and where do we stop for lunch?":
            "太好了！@nori 从市区开过去要多久，中午在哪儿吃？",
        "Carmel": "德清",
        "Tidy up the 2.4 release notes, and see what people on Reddit are saying about 2.4.":
            "把 2.4 的发布说明整理好，再看看 V2EX 上大家对 2.4 的反馈。",
        "Started two workstreams": "开了两个工作",
        "add a setup section": "加一节连接设置",
        "Clear out the old mockups": "清理一下旧的设计稿",
        "current designs are untouched": "现在的设计都没动",
    ]

    // MARK: - Scenes

    private var wantedScenes: Set<String>? {
        guard let list = env["CONDUIT_DEMO_SCENES"], !list.isEmpty else { return nil }
        return Set(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// Marks a scene for the cut. A scene that wasn't asked for still runs,
    /// since the next one may build on it, but isn't marked.
    private func scene(_ name: String, _ body: () -> Void) {
        let marked = wantedScenes?.contains(name) ?? true
        if marked {
            print("SCENE start \(name) \(Date().timeIntervalSince1970)")
            // With the end one, a check that the cut begins and ends on the scene.
            snap("scene-\(name)-start")
        }
        body()
        if marked { print("SCENE end \(name) \(Date().timeIntervalSince1970)") }
        snap("scene-\(name)-end")
    }

    // MARK: - Director

    /// Asks demo_director.py to act on a dashboard and waits for it.
    private func direct(_ action: String, _ body: [String: String], timeout: TimeInterval = 180) {
        var request = URLRequest(url: director.appendingPathComponent(action))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout
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
        wait(for: [done], timeout: timeout + 20)
        if let failure { XCTFail("director \(action) \(body): \(failure)") }
    }

    // MARK: - Steps

    private func openTab(_ name: String) {
        let tab = app.buttons[L(name)].firstMatch
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
    /// Lifts `bot` and drops it on `target` (over its face, or its name),
    /// until `done` says the drop took. A press can miss the lift: the system
    /// takes it for the portrait's context menu (closed again here, so the
    /// next press can't land on one of its items) or for a scroll of the
    /// grid. Either way it presses again, for a different time.
    @discardableResult
    private func drag(bot: String, onto target: String, overFace: Bool, hold: TimeInterval,
                      before: () -> Void = {}, until done: () -> Bool) -> Bool {
        for press in [0.8, 0.6, 1.2] {
            let from = portrait(bot)
            let to = portrait(target)
            guard from.waitForExistence(timeout: 10), to.waitForExistence(timeout: 10) else {
                XCTFail("Can't drag \(bot) onto \(target): one isn't on screen")
                return false
            }
            before()
            let start = from.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            // The portrait button is the face; its name sits just under it.
            let end = to.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: overFace ? 0.45 : 1.25))
            start.press(forDuration: press, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: hold)
            settle(1)
            if botMenuIsOpen() {
                print("DEMO drag \(bot) onto \(target): the press \(press)s opened the menu, pressing again")
                closeBotMenu()
                continue
            }
            if done() { return true }
            print("DEMO drag \(bot) onto \(target): the press \(press)s didn't take, pressing again (from \(from.frame) to \(to.frame))")
            settle(1)
        }
        if botMenuIsOpen() { closeBotMenu() }
        return false
    }

    /// Drags `bot` over `target`'s name, so it takes that place; true once
    /// it sits where `target` was (a scroll of the grid moves both, so it
    /// doesn't count).
    @discardableResult
    private func reorder(_ bot: String, onto target: String) -> Bool {
        var place: CGRect?
        let moved = drag(bot: bot, onto: target, overFace: false, hold: 0.8, before: {
            place = portrait(target).frame
        }) {
            guard let place, !place.isEmpty else { return false }
            let now = portrait(bot).frame
            return abs(now.midX - place.midX) < 20 && abs(now.midY - place.midY) < 20
        }
        if !moved { XCTFail("\(bot) never took \(target)'s place") }
        return moved
    }

    /// Opens a room from Bots Home's Group Chats once it has started: a room
    /// with Studio's bots is a draft row first ("Waiting for Studio", then
    /// "Starting…"), with the same name as the room's tile that replaces it,
    /// so it waits for the row to go before tapping the tile.
    private func openRoom(_ name: String) {
        let draft = app.buttons.matching(NSPredicate(
            format: "label == %@ AND (value BEGINSWITH %@ OR value BEGINSWITH %@)", name, L("Waiting"), L("Starting"))).firstMatch
        let deadline = Date().addingTimeInterval(120)
        while draft.exists, Date() < deadline { settle(2) }
        if draft.exists { print("DEMO \(name) is still a draft: \(draft.value ?? "")") }
        let tile = app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier BEGINSWITH 'bots.room.'", name)).firstMatch
        // A room Group Chats hasn't read yet shows once it's read again: a
        // pull to refresh, as a person would.
        var shown = tile.waitForExistence(timeout: 10)
        for _ in 0..<3 where !shown {
            pullToRefresh()
            shown = tile.waitForExistence(timeout: 10)
        }
        guard shown else {
            XCTFail("No \(name) in Group Chats")
            return
        }
        tile.tap()
        settle(3)
    }

    /// New Group Chat: a room named `name` with Conduit-chan, inviting Sam.
    /// It waits on Bots Home as a draft until Sam answers.
    private func inviteSam(to name: String) {
        let add = app.buttons["bots.newGroupChat"]
        guard add.waitForExistence(timeout: 10) else {
            XCTFail("No New Group Chat button on Bots Home")
            return
        }
        add.tap()
        let field = app.textFields[L("Group name")].firstMatch
        guard field.waitForExistence(timeout: 10) else {
            XCTFail("New Group Chat has no name field")
            return
        }
        field.tap()
        field.typeText(name)
        settle(1)
        // Conduit-chan's row shows its profile, "default", under the name.
        let rows = app.staticTexts.matching(NSPredicate(format: "label == %@", "default"))
        if rows.firstMatch.waitForExistence(timeout: 10),
           let bot = rows.allElementsBoundByIndex.first(where: \.isHittable) {
            bot.tap()
        } else {
            XCTFail("No Conduit-chan in New Group Chat")
        }
        settle(1)
        let sam = app.staticTexts["Sam"].firstMatch
        for _ in 0..<4 where sam.exists && !sam.isHittable {
            app.swipeUp()
            settle(1)
        }
        if sam.exists { sam.tap() } else {
            let labels = app.staticTexts.allElementsBoundByIndex.prefix(60).map(\.label)
            print("DEMO New Group Chat shows: \(labels)")
            XCTFail("No Sam in New Group Chat")
        }
        settle(2)
        let create = app.navigationBars.buttons[L("Create")].firstMatch
        if create.waitForExistence(timeout: 5) { create.tap() } else { XCTFail("No Create in New Group Chat") }
        settle(3)
    }

    /// Opens New Group Chat and closes it again, so Conduit reads your other
    /// Hermes' bots afresh (a far bot starts a room on Bots Home only once
    /// it's read as ready), and says whether they were offered.
    private func readOwnBots() {
        let add = app.buttons["bots.newGroupChat"]
        guard add.waitForExistence(timeout: 10) else {
            print("DEMO no New Group Chat button on Bots Home")
            return
        }
        add.tap()
        let far = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", L("A room can bring bots from one of your other Hermes"))).firstMatch
        print("DEMO New Group Chat offers the other Hermes' bots: \(far.waitForExistence(timeout: 20))")
        if !far.exists {
            let labels = app.staticTexts.allElementsBoundByIndex.prefix(60).map(\.label)
            print("DEMO New Group Chat shows: \(labels)")
        }
        let cancel = app.navigationBars.buttons[L("Cancel")].firstMatch
        if cancel.exists { cancel.tap() } else { app.swipeDown() }
        settle(2)
    }

    /// A bot's long-press menu (Edit Bot, Duplicate, Delete Bot, …) is up.
    private func botMenuIsOpen() -> Bool {
        app.buttons[L("Delete Bot")].exists || app.buttons[L("Duplicate")].exists
    }

    /// Closes the menu by a tap well clear of it, at the top of the screen.
    private func closeBotMenu() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.03)).tap()
        settle(1)
    }

    /// The first element labelled exactly so: on Bots Home, a bot's portrait.
    private func named(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// A bot's portrait on Bots Home: the button labelled with its name that
    /// is on screen (the other tabs stay mounted, and may hold one too).
    private func portrait(_ label: String) -> XCUIElement {
        let all = app.buttons.matching(NSPredicate(format: "label == %@", label))
        _ = all.firstMatch.waitForExistence(timeout: 10)
        return all.allElementsBoundByIndex.first { $0.isHittable } ?? all.firstMatch
    }

    private func pullToRefresh() {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
    }

    private func send(_ text: String) {
        // A chat's composer is a text view; wait for it, since a chat just
        // opened may still be loading and a tab left earlier keeps its
        // search field (Tasks' 搜索任务) in the tree, off screen.
        let composer = app.textViews.firstMatch.waitForExistence(timeout: 10)
            ? app.textViews.firstMatch : app.textFields.firstMatch
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
        // A chat's composer labels it Send message; a room's is room.composer.send.
        let roomSend = app.buttons["room.composer.send"].firstMatch
        let button = roomSend.exists ? roomSend : app.buttons[L("Send message")].firstMatch
        guard button.waitForExistence(timeout: 5) else {
            XCTFail("No send button for \(text)")
            return
        }
        button.tap()
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

    /// The sign-in screen's "Need help connecting?" guide, as a newcomer
    /// walks it: the dashboard is running, the three ways to reach it, the
    /// Tailscale page with the prompt for Hermes, then Done, back at sign-in.
    private func showConnectionSetup() {
        let help = app.buttons["login.connection-setup"].firstMatch
        guard help.waitForExistence(timeout: 20) else {
            XCTFail("No Need help connecting? on the sign-in screen")
            return
        }
        settle(3)
        help.tap()
        let running = app.buttons["setup.answer-yes"].firstMatch
        guard running.waitForExistence(timeout: 10) else {
            XCTFail("Connection Setup never asked whether the dashboard runs")
            return
        }
        settle(3)
        running.tap()
        let tailscale = app.buttons["setup.method-tailscale"].firstMatch
        if tailscale.waitForExistence(timeout: 10) {
            settle(5)
            tailscale.tap()
            settle(4)
            app.swipeUp(velocity: .slow)
            settle(4)
        } else {
            XCTFail("Connection Setup never showed the ways to reach Hermes")
        }
        let done = app.buttons["connection-setup.done"].firstMatch
        if done.waitForExistence(timeout: 5) { done.tap() }
        settle(2)
    }

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
        if let current = username.value as? String, !current.isEmpty, current != L("Username") {
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
        _ = app.buttons[L("Bots")].waitForExistence(timeout: 60)
        dismissFinishSetupCard()
        settle(3)
    }

    private func dismissFinishSetupCard() {
        // The card can show on more than one screen at once (Settings and
        // the tab behind it), so each copy is answered by its own element.
        // Only a copy on screen is tapped: a tap at a hidden copy's place lands
        // on whatever covers it, the card's own Turn on for notifications
        // among them, and that system prompt then blocks every later tap.
        let cards = app.buttons.matching(identifier: "finish-setup.not-now")
        guard cards.firstMatch.waitForExistence(timeout: 8) else { return }
        for notNow in cards.allElementsBoundByIndex where notNow.exists && notNow.isHittable {
            notNow.tap()
            settle(1)
        }
    }

    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Don’t Allow", "Not Now", "OK", "允许", "不允许", "以后再说", "好"] {
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
