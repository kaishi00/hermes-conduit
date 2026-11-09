//
//  ChatOnScreenTests.swift
//  ConduitTests
//
//  A reply that lands in the chat Conduit has on screen sends no push: while
//  the open chat's turn runs and someone used Conduit lately, Conduit holds
//  it on the host, renewing at a pace Low Power and Low Data Mode stretch,
//  and lets go when the user leaves the chat or the app (plugin
//  chat_on_screen.py).
//

import XCTest
@testable import Conduit

@MainActor
final class ChatOnScreenTests: XCTestCase {

    // MARK: - Pace and body

    func testTheRenewalStretchesLikeOtherPollsAndTheHoldStaysThreeRenewalsLong() {
        XCTAssertEqual(ChatOnScreen.renewalInterval(under: DeviceConditions()), 30)
        XCTAssertEqual(ChatOnScreen.renewalInterval(under: DeviceConditions(lowDataMode: true)), 60)
        XCTAssertEqual(ChatOnScreen.renewalInterval(under: DeviceConditions(expensivePath: true)), 60)
        XCTAssertEqual(ChatOnScreen.renewalInterval(under: DeviceConditions(lowPowerMode: true, lowDataMode: true)), 90)
        XCTAssertEqual(ChatOnScreen.holdSeconds(renewingEvery: 30), 90)
        XCTAssertEqual(ChatOnScreen.holdSeconds(renewingEvery: 90), 270)
        XCTAssertEqual(ChatOnScreen.holdSeconds(renewingEvery: 1_000), ChatOnScreen.maximumHoldSeconds)
    }

    func testTheBodyNamesTheChatsOwnIdsOrReleasesTheDevicesHold() {
        let claim = ChatOnScreen.Claim(profile: "default", sessionIDs: ["stored-1", "rt-1", "rt-1", ""])
        XCTAssertEqual(claim.sessionIDs, ["rt-1", "stored-1"])
        XCTAssertEqual(ChatOnScreen.body(device: "mac", claim: claim, holdSeconds: 90) as NSDictionary,
                       ["device": "mac", "session_ids": ["rt-1", "stored-1"], "hold_s": 90])
        XCTAssertEqual(ChatOnScreen.body(device: "mac", claim: claim, holdSeconds: 0) as NSDictionary,
                       ["device": "mac", "hold_s": 0])
        let many = ChatOnScreen.Claim(profile: "default", sessionIDs: (0..<40).map { "id-\($0)" })
        XCTAssertEqual(many.sessionIDs.count, ChatOnScreen.maximumIDs)
    }

    func testOnlyAPluginThatReportsTheCapabilityTakesReports() {
        var plugin = NotifierPluginStatus()
        XCTAssertFalse(ChatOnScreen.isTaken(by: plugin))
        plugin.state = .reported(version: "0.54.1", capabilities: ["reply-sources", "turn-surface"])
        XCTAssertFalse(ChatOnScreen.isTaken(by: plugin))
        plugin.state = .reported(version: "0.55.0", capabilities: ["reply-sources", "chat-on-screen"])
        XCTAssertTrue(ChatOnScreen.isTaken(by: plugin))
    }

    // MARK: - A chat on screen clears its notifications (#1579)

    func testReadingAChatClearsItsNotificationsFromItsDashboardOnly() {
        let here = UUID()
        let there = UUID()
        func target(_ session: String, durable: String? = nil, dashboard: UUID?, gateway: String? = nil,
                    malformed: Bool = false, type: String = "response.ready") -> ConduitNotificationTarget {
            ConduitNotificationTarget(profile: "default", sessionId: session, durableSessionID: durable, dashboardID: dashboard,
                                      hasMalformedDashboardID: malformed, relayGatewayID: gateway, type: type)
        }
        let delivered: [(identifier: String, target: ConduitNotificationTarget?)] = [
            ("reply", target("rt-1", dashboard: here)),
            ("by-durable-id", target("rt-old", durable: "stored-1", dashboard: here, type: "turn.failed")),
            ("same-host-other-entry", target("rt-1", dashboard: there, gateway: "gw-here")),
            ("old-relay", target("rt-1", dashboard: nil)),
            ("other-dashboard", target("rt-1", dashboard: there, gateway: "gw-there")),
            ("malformed", target("rt-1", dashboard: nil, malformed: true)),
            ("approval", target("rt-1", dashboard: here, type: "approval.needed")),
            ("question", target("rt-1", dashboard: here, type: "input.needed")),
            ("call", target("rt-1", dashboard: here, type: "call.requested")),
            ("calendar", target("rt-1", dashboard: here, type: "phone.changes")),
            ("other-chat", target("rt-2", dashboard: here)),
            ("unreadable", nil),
        ]
        func read(saved: [UUID], sessionIDs: Set<String> = ["rt-1", "stored-1"]) -> [String] {
            ReadChatNotifications.identifiers(of: delivered, sessionIDs: sessionIDs, activeDashboardID: here,
                                              savedDashboardIDs: saved, activeDashboardGatewayIDs: ["gw-here"])
        }
        XCTAssertEqual(read(saved: [here]), ["reply", "by-durable-id", "same-host-other-entry", "old-relay"],
                       "what waits on the user stays until it's answered")
        XCTAssertEqual(read(saved: [here, there]), ["reply", "by-durable-id", "same-host-other-entry"],
                       "a push with no dashboard can't be placed among several, as a tap can't")
        XCTAssertEqual(read(saved: [here], sessionIDs: []), [])
    }

    func testTheExtensionsNoteFindsASealedPushsChatAfterItStopsVerifying() {
        let dashboard = UUID()
        let note = ReadChatHint.note(["session_id": "rt-1", "stored_session_id": "stored-1", "dashboard_id": dashboard.uuidString,
                                      "type": "response.ready", "gateway_id": "gw", "decision": ["kind": "approval"],
                                      "profile": "default"])
        XCTAssertEqual(note, ["session_id": "rt-1", "stored_session_id": "stored-1", "dashboard_id": dashboard.uuidString,
                              "type": "response.ready", "gateway_id": "gw"], "only the chat, where it's from and its kind")
        let userInfo: [AnyHashable: Any] = [ReadChatHint.userInfoKey: note, "conduit_e2e": ["v": 1]]
        let target = PushNotificationService.readChatTarget(from: userInfo, records: [])
        XCTAssertEqual(target?.sessionId, "rt-1")
        XCTAssertEqual(target?.durableSessionID, "stored-1")
        XCTAssertEqual(target?.dashboardID, dashboard)
        XCTAssertEqual(target?.relayGatewayID, "gw")
        XCTAssertEqual(target?.type, "response.ready")
        XCTAssertNil(ReadChatHint.read([ReadChatHint.userInfoKey: ["dashboard_id": dashboard.uuidString]]), "no chat, no note")
    }

    /// Issue 2064: a push from a group room this Hermes hosts opens, is read
    /// with and keeps one notification for the room, not the bot's hidden
    /// chat there.
    func testAHostedRoomsPushesOpenAreReadWithAndReplaceEachOtherInTheRoom() throws {
        let dashboard = UUID()
        func parsed(_ type: String, room: Any? = ["id": "conduit-1"]) -> ConduitNotificationTarget? {
            var payload: [String: Any] = ["session_id": "hidden-1", "type": type, "dashboard_id": dashboard.uuidString]
            payload["room"] = room
            return PushNotificationService.parseNotificationTarget(from: ["body": ["conduit": payload]], records: [],
                                                                   knownGatewayIDs: [], keysProvisioned: false)
        }
        for type in ["response.ready", "turn.failed", "background_task.finished", "approval.needed"] {
            XCTAssertEqual(parsed(type)?.roomID, "conduit-1", type)
            XCTAssertEqual(parsed(type)?.sessionId, "hidden-1", "an older app still has the chat")
        }
        XCTAssertNil(parsed("input.needed")?.roomID, "nothing else names a room")
        XCTAssertNil(parsed("room.invite")?.roomID, "an invite's room is another host's")
        XCTAssertNil(parsed("response.ready", room: ["id": "  "])?.roomID)
        XCTAssertNil(parsed("response.ready", room: nil)?.roomID, "an older notifier's")
        // The relay's own layout for a keyless pairing: a routing stub on
        // top, the room only in body.conduit.
        let stub: [String: Any] = ["session_id": "hidden-1", "type": "response.ready", "dashboard_id": dashboard.uuidString]
        var rich = stub
        rich["room"] = ["id": "conduit-1"]
        let relayed: [AnyHashable: Any] = ["conduit": stub, "body": ["conduit": rich]]
        XCTAssertEqual(PushNotificationService.parseNotificationTarget(from: relayed, records: [], knownGatewayIDs: [],
                                                                      keysProvisioned: false)?.roomID, "conduit-1")
        XCTAssertEqual(ReadChatHint.roomThread(ReadChatHint.note(NotificationE2E.plaintextRouting(relayed))),
                       "room:\(dashboard.uuidString):conduit-1", "the extension keeps one per room for it too")
        XCTAssertNil(NotificationE2E.plaintextRouting(["conduit": stub])["room"], "a stub alone has none")
        // The relay builds body.conduit from the stub it checked: a nested
        // copy naming another pairing, dashboard or chat isn't taken.
        for (field, value) in [("gateway_id", "another-pairing"), ("dashboard_id", UUID().uuidString), ("session_id", "hidden-2")] {
            var elsewhere = rich
            elsewhere[field] = value
            let mixed: [AnyHashable: Any] = ["conduit": stub, "body": ["conduit": elsewhere]]
            XCTAssertNil(NotificationE2E.plaintextRouting(mixed)["room"], field)
            XCTAssertNil(PushNotificationService.parseNotificationTarget(from: mixed, records: [], knownGatewayIDs: [],
                                                                         keysProvisioned: false)?.roomID, field)
        }

        // The extension's note keeps the room, so reading it clears the push after it stops verifying.
        let note = ReadChatHint.note(["session_id": "hidden-1", "type": "response.ready", "dashboard_id": dashboard.uuidString,
                                      "room": ["id": "conduit-1"]])
        XCTAssertEqual(note["room_id"], "conduit-1")
        XCTAssertEqual(PushNotificationService.readChatTarget(from: [ReadChatHint.userInfoKey: note], records: [])?.roomID,
                       "conduit-1")

        // The room on screen reads its replies and failures; an approval waits to be answered.
        let delivered: [(identifier: String, target: ConduitNotificationTarget?)] = [
            ("reply", parsed("response.ready")), ("failed", parsed("turn.failed")),
            ("approval", parsed("approval.needed")), ("other-room", parsed("response.ready", room: ["id": "conduit-2"])),
        ]
        XCTAssertEqual(ReadChatNotifications.identifiers(of: delivered, sessionIDs: [], roomID: "conduit-1",
                                                         activeDashboardID: dashboard, savedDashboardIDs: [dashboard],
                                                         activeDashboardGatewayIDs: []), ["reply", "failed"])
        XCTAssertEqual(ReadChatNotifications.identifiers(of: delivered, sessionIDs: [], activeDashboardID: dashboard,
                                                         savedDashboardIDs: [dashboard], activeDashboardGatewayIDs: []), [],
                       "no room on screen reads none")

        // One notification per room (Eric, 2026-11-09): a reply, failure or task replaces the room's last.
        func noted(_ type: String, room: String = "conduit-1", on board: UUID = dashboard) -> [String: String] {
            ReadChatHint.note(["session_id": "hidden-\(type)", "type": type, "dashboard_id": board.uuidString, "room": ["id": room]])
        }
        let thread = try XCTUnwrap(ReadChatHint.roomThread(noted("response.ready")))
        XCTAssertEqual(ReadChatHint.roomThread(noted("background_task.finished")), thread)
        XCTAssertNil(ReadChatHint.roomThread(noted("approval.needed")), "an approval keeps its own until answered")
        XCTAssertNil(ReadChatHint.roomThread(ReadChatHint.note(["session_id": "chat", "type": "response.ready"])))
        let reply = noted("response.ready")
        XCTAssertTrue(ReadChatHint.replaces(reply, delivered: [ReadChatHint.userInfoKey: noted("turn.failed")]))
        XCTAssertFalse(ReadChatHint.replaces(reply, delivered: [ReadChatHint.userInfoKey: noted("approval.needed")]))
        XCTAssertFalse(ReadChatHint.replaces(reply, delivered: [ReadChatHint.userInfoKey: noted("response.ready", room: "conduit-2")]))
        XCTAssertFalse(ReadChatHint.replaces(reply, delivered: [ReadChatHint.userInfoKey: noted("response.ready", on: UUID())]),
                       "another dashboard's room of the same id")
        XCTAssertFalse(ReadChatHint.replaces(reply, delivered: [:]))

        // Needs you opens the room for a wait in one.
        let wait = try XCTUnwrap(NeedsYouItem(host: ["id": "w1", "kind": "approval", "session_ids": ["hidden-1"],
                                                     "title": "Zoo trip", "room": "conduit-1"], profile: "furina"))
        XCTAssertEqual(wait.roomID, "conduit-1")
        XCTAssertNil(NeedsYouItem(host: ["id": "w2", "kind": "approval", "session_ids": ["chat"]], profile: "default")?.roomID)
    }

    /// Issue 2064: two bots finishing together each hand a room
    /// notification over before the other shows, so the later one waits
    /// for the earlier one (handed over within the window) to replace it.
    func testARoomsNotificationWaitsForTheOneHandedOverJustBeforeIt() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var handoffs = RoomHandoffs()
        XCTAssertEqual(handoffs.record("a", thread: "room:d:r1", now: start), [])
        XCTAssertEqual(handoffs.record("x", thread: "room:d:r2", now: start), [], "Another room's is its own")
        XCTAssertEqual(handoffs.record("b", thread: "room:d:r1", now: start.addingTimeInterval(0.2)), ["a"])
        XCTAssertEqual(handoffs.record("c", thread: "room:d:r1", now: start.addingTimeInterval(1)), ["b"],
                       "Only the last: b waits on and replaces a")
        XCTAssertEqual(handoffs.record("c", thread: "room:d:r1", now: start.addingTimeInterval(1.1)), ["b"],
                       "The same notification again doesn't wait on itself")
        XCTAssertEqual(
            handoffs.record("d", thread: "room:d:r1", now: start.addingTimeInterval(RoomHandoffs.window + 0.5)),
            ["c"], "Ones handed over before the window have shown, or never will"
        )
        XCTAssertEqual(handoffs.entries.map(\.id), ["c", "d"])
        XCTAssertEqual(handoffs.record("e", thread: "room:d:r1", now: start.addingTimeInterval(2)), ["d"],
                       "A clock set back keeps the one in flight")
        XCTAssertEqual(handoffs.record("f", thread: "room:d:r1", now: start.addingTimeInterval(-60)), [],
                       "One far off either way is gone")
        XCTAssertLessThan(RoomHandoffs.wait, RoomHandoffs.window)

        // Kept in the app group between the extension's runs.
        let suite = "RoomHandoffs-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(RoomHandoffs.record("a", thread: "room:d:r1", defaults: defaults, now: start), [])
        XCTAssertEqual(RoomHandoffs.record("b", thread: "room:d:r1", defaults: defaults, now: start.addingTimeInterval(0.1)), ["a"])
    }

    func testARunningTurnDoesNotCountAsSomeoneLooking() {
        let clock = UptimeBox()
        let idle = InteractionIdleState(idleAfter: 120, now: { clock.now }, schedule: { _, _ in {} },
                                        notificationCenter: NotificationCenter())
        XCTAssertTrue(idle.usedWithin(ChatOnScreen.engagedWindow))
        idle.setTurnRunning(true)
        clock.now += 121
        XCTAssertFalse(idle.isIdle, "The backdrop stays awake for the turn")
        XCTAssertFalse(idle.usedWithin(ChatOnScreen.engagedWindow), "Nobody touched or typed for two minutes")
        idle.noteInteraction()
        XCTAssertTrue(idle.usedWithin(ChatOnScreen.engagedWindow))
    }

    func testATurnStartingOrEndingIsNotSomeoneLooking() {
        // A queued message sends itself when a turn ends, starting the next
        // turn with nobody there: neither edge renews the 2-minute window.
        let clock = UptimeBox()
        let idle = InteractionIdleState(idleAfter: 120, now: { clock.now }, schedule: { _, _ in {} },
                                        notificationCenter: NotificationCenter())
        clock.now += 121
        idle.setTurnRunning(true)
        XCTAssertFalse(idle.usedWithin(ChatOnScreen.engagedWindow))
        idle.setTurnRunning(false)
        XCTAssertFalse(idle.usedWithin(ChatOnScreen.engagedWindow))
        idle.setVoiceConversationShown(true)
        XCTAssertFalse(idle.usedWithin(ChatOnScreen.engagedWindow))
        XCTAssertFalse(idle.isIdle, "The backdrop still wakes for them")
    }

    // MARK: - Tracker

    private let chat = ChatOnScreen.Claim(profile: "default", sessionIDs: ["rt-1", "stored-1"])
    private let other = ChatOnScreen.Claim(profile: "default", sessionIDs: ["rt-2"])

    func testAnIdleOpenChatSendsNothing() {
        var tracker = ChatOnScreen.Tracker()
        XCTAssertEqual(tracker.update(wanted: chat, turnRunning: false), [])
        XCTAssertEqual(tracker.update(wanted: nil, turnRunning: false), [])
    }

    func testARunningTurnIsHeldThenRunsOutOnItsOwnAfterTheReply() {
        var tracker = ChatOnScreen.Tracker()
        XCTAssertEqual(tracker.update(wanted: chat, turnRunning: true), [.startRenewing(chat)])
        XCTAssertEqual(tracker.update(wanted: chat, turnRunning: true), [], "One renewal loop")
        // No release at the turn's end: the reply's hooks run around now.
        XCTAssertEqual(tracker.update(wanted: chat, turnRunning: false), [.stopRenewing])
        XCTAssertEqual(tracker.held, chat)
        // The next turn in the same chat holds it again.
        XCTAssertEqual(tracker.update(wanted: chat, turnRunning: true), [.startRenewing(chat)])
    }

    func testLeavingTheChatOrTheAppReleasesIt() {
        var tracker = ChatOnScreen.Tracker()
        _ = tracker.update(wanted: chat, turnRunning: true)
        XCTAssertEqual(tracker.update(wanted: nil, turnRunning: true), [.stopRenewing, .release(chat)])
        XCTAssertNil(tracker.held)

        _ = tracker.update(wanted: chat, turnRunning: true)
        _ = tracker.update(wanted: chat, turnRunning: false)
        XCTAssertEqual(tracker.update(wanted: nil, turnRunning: false), [.release(chat)],
                       "A hold still running out goes too")
        XCTAssertEqual(tracker.update(wanted: nil, turnRunning: false), [])
    }

    func testAnotherChatWithItsTurnRunningReplacesTheHoldWithoutARelease() {
        var tracker = ChatOnScreen.Tracker()
        _ = tracker.update(wanted: chat, turnRunning: true)
        XCTAssertEqual(tracker.update(wanted: other, turnRunning: true), [.stopRenewing, .startRenewing(other)])
    }

    func testAnotherChatWithNoTurnReleasesTheFirst() {
        var tracker = ChatOnScreen.Tracker()
        _ = tracker.update(wanted: chat, turnRunning: true)
        XCTAssertEqual(tracker.update(wanted: other, turnRunning: false), [.stopRenewing, .release(chat)])
    }

    // MARK: - AppState

    func testARunningTurnHoldsTheOpenChatAndGoingToTheBackgroundReleasesIt() async throws {
        let recorder = OnScreenRecorder()
        let appState = makeAppState(recorder: recorder)
        openChat("rt-held", in: appState)
        XCTAssertTrue(recorder.reports.isEmpty, "An idle open chat sends nothing")

        appState.handleStreamEvent(.sessionBusy(sessionId: "rt-held", busy: true))
        XCTAssertEqual(appState.turnState, .running)
        try await recorder.waitFor(count: 1)
        XCTAssertEqual(recorder.reports.first?.path, ChatOnScreen.path)
        XCTAssertEqual(recorder.reports.first?.ids, ["rt-held"])
        XCTAssertEqual(recorder.reports.first?.hold, 90)
        XCTAssertEqual(recorder.reports.first?.device, ChatOnScreen.device)

        _ = appState.handleScenePhase(.background)
        try await recorder.waitFor(count: 2)
        XCTAssertEqual(recorder.reports.last?.hold, 0)
        XCTAssertEqual(recorder.reports.last?.ids, [])
    }

    func testTheTurnEndingLetsTheHoldRunOutAndTheListCoveringTheChatReleasesIt() async throws {
        let recorder = OnScreenRecorder()
        let appState = makeAppState(recorder: recorder)
        openChat("rt-list", in: appState)
        appState.handleStreamEvent(.sessionBusy(sessionId: "rt-list", busy: true))
        try await recorder.waitFor(count: 1)

        appState.handleStreamEvent(.sessionBusy(sessionId: "rt-list", busy: false))
        // A release would be queued behind the last report: wait that out.
        await appState.chatOnScreenLastSend?.value
        XCTAssertEqual(recorder.reports.count, 1, "The reply's hooks still find the hold")

        appState.showSidebar = true
        try await recorder.waitFor(count: 2)
        XCTAssertEqual(recorder.reports.last?.hold, 0)
    }

    func testAGroupRoomTakingTheChatsPlaceReleasesIt() async throws {
        let recorder = OnScreenRecorder()
        let appState = makeAppState(recorder: recorder)
        openChat("rt-room", in: appState)
        appState.handleStreamEvent(.sessionBusy(sessionId: "rt-room", busy: true))
        try await recorder.waitFor(count: 1)

        appState.setActiveRoomSurfaceForTesting(AppState.GroupRoomSurface(dashboardID: UUID(), room: Self.room))
        XCTAssertNil(appState.chatOnScreenClaim, "The room covers the chat, whose session is unchanged")
        try await recorder.waitFor(count: 2)
        XCTAssertEqual(recorder.reports.last?.hold, 0)

        // Back from the room with the turn still running: held again.
        appState.setActiveRoomSurfaceForTesting(nil)
        try await recorder.waitFor(count: 3)
        XCTAssertEqual(recorder.reports.last?.ids, ["rt-room"])
        XCTAssertEqual(recorder.reports.last?.hold, 90)
    }

    func testAPluginWithoutTheRouteIsNeverAsked() async throws {
        let appState = makeAppState(recorder: nil)
        openChat("rt-old", in: appState)
        appState.setNotifierPluginStateForTesting(.reported(version: "0.54.1", capabilities: ["turn-surface"]))
        XCTAssertNil(appState.chatOnScreenClaim)
        appState.setNotifierPluginStateForTesting(.reported(version: "0.55.0", capabilities: ["chat-on-screen"]))
        XCTAssertEqual(appState.chatOnScreenClaim?.sessionIDs, ["rt-old"])
    }

    // MARK: - Harness

    private func makeAppState(recorder: OnScreenRecorder?) -> AppState {
        let suite = "ChatOnScreenTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        let operations = ChatResumeLifecycleOperations()
        let store = ChatResumeStore(defaults: defaults)
        let appState = AppState(
            defaults: defaults,
            chatResumeCoordinator: ChatResumeCoordinator(store: store),
            recoverySequence: ChatResumeRecoverySequence(),
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: operations,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        if let recorder {
            appState.chatOnScreenSender = { path, body in recorder.report(path: path, body: body) }
        }
        // Default pace whatever the test device's Low Power and Low Data
        // Mode, and someone just used Conduit (the suite may have run for
        // longer than the 2-minute window before this class).
        appState.deviceConditions = { DeviceConditions() }
        InteractionIdleState.shared.noteInteraction()
        return appState
    }

    private static let room = GroupRoom(
        roomID: "room-1",
        name: "Planning",
        members: [],
        authorityGatewayID: "gw-a",
        authorityEpoch: 1,
        revision: 1,
        createdAt: 0,
        updatedAt: 0,
        disbandedAt: nil,
        latestSeq: 0
    )

    private func openChat(_ id: String, in appState: AppState) {
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.sessions = [SessionSummary(
            id: id,
            storedSessionId: nil,
            alternateIds: [],
            title: id,
            model: "Hermes",
            updatedLabel: "now",
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )]
        appState.showSidebar = false
        appState.activeSessionId = id
    }
}

private final class UptimeBox {
    var now: TimeInterval = 1_000
}

@MainActor
private final class OnScreenRecorder {
    struct Report: Equatable {
        var path: String
        var device: String
        var ids: [String]
        var hold: Int
    }

    var reports: [Report] = []

    func report(path: String, body: [String: Any]) {
        reports.append(Report(
            path: path,
            device: body["device"] as? String ?? "?",
            ids: body["session_ids"] as? [String] ?? [],
            hold: body["hold_s"] as? Int ?? -1
        ))
    }

    func waitFor(count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 where reports.count < count {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThanOrEqual(reports.count, count, "Reports: \(reports)", file: file, line: line)
    }
}
