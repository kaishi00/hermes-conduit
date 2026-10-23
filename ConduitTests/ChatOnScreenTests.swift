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
