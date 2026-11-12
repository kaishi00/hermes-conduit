//
//  AppStateTurnSurfaceTests.swift
//  ConduitTests
//
//  Where in Conduit a message was sent from (#888): each send tells the
//  notifier plugin the surface and how the message was entered, before
//  prompt.submit, and a plugin that is slow or missing never holds it up.
//

import XCTest
@testable import Conduit

@MainActor
final class AppStateTurnSurfaceTests: XCTestCase {

    // MARK: - The surface

    func testATypedMessageIsTheDevicesAndASpokenOneInTheCarIsCarPlays() {
        XCTAssertEqual(TurnSurface.message(spoken: false, carPlay: true, device: .ipad), TurnSurface(place: .ipad, input: .typed))
        XCTAssertEqual(TurnSurface.message(spoken: true, carPlay: false, device: .iphone), TurnSurface(place: .iphone, input: .spoken))
        XCTAssertEqual(TurnSurface.message(spoken: true, carPlay: true, device: .iphone), TurnSurface(place: .carplay, input: .spoken))
    }

    func testTheReportNamesTheChatsRuntimeAndLeavesOutAnUnknownInput() {
        let spoken = TurnSurface(place: .carplay, input: .spoken).body(runtimeSessionID: "rt-1", text: "hi")
        // `printf hi | shasum -a 256`
        let hi = "8f434346648f6b96df89dda901c5176b10a6d83961dd3c1ac88b59b2dc327aa4"
        XCTAssertEqual(spoken as NSDictionary, ["session_id": "rt-1", "text_sha256": hi, "surface": "carplay", "input": "spoken"])
        XCTAssertEqual(TurnSurface.shortcut.body(runtimeSessionID: "rt-2", text: "hi") as NSDictionary,
                       ["session_id": "rt-2", "text_sha256": hi, "surface": "siri"])
    }

    func testATypedMessageReadAloudSaysItsReplyIsHeard() {
        // `printf hi | shasum -a 256`
        let hi = "8f434346648f6b96df89dda901c5176b10a6d83961dd3c1ac88b59b2dc327aa4"
        let typed = TurnSurface.message(spoken: false, carPlay: false, device: .iphone, heard: true)
        XCTAssertEqual(typed.body(runtimeSessionID: "rt-1", text: "hi") as NSDictionary,
                       ["session_id": "rt-1", "text_sha256": hi, "surface": "iphone", "input": "typed", "heard": true])
        // A spoken message is heard anyway: no flag.
        let spoken = TurnSurface.message(spoken: true, carPlay: false, device: .iphone, heard: true)
        XCTAssertNil(spoken.body(runtimeSessionID: "rt-1", text: "hi")["heard"])
    }

    // MARK: - Sending

    func testATypedMessageReportsItsSurfaceBeforeItIsSent() async {
        let recorder = TurnSurfaceRecorder()
        let harness = makeHarness(recorder: recorder)
        openChat("rt-typed", in: harness)

        let sent = await harness.appState.submitComposer(text: "What's on today?")

        XCTAssertTrue(sent)
        XCTAssertEqual(recorder.events, [
            "report rt-typed \(TurnSurface.device.rawValue) typed",
            "prompt rt-typed What's on today?"
        ])
        XCTAssertEqual(recorder.digests, [
            TurnSurface.shortcut.body(runtimeSessionID: "", text: "What's on today?")["text_sha256"] as? String
        ], "The hash is of the text prompt.submit sends")
    }

    func testASpokenMessageReportsSpoken() async {
        let recorder = TurnSurfaceRecorder()
        let harness = makeHarness(recorder: recorder)
        openChat("rt-voice", in: harness)

        let sent = await harness.appState.submitVoiceTranscript("Remind me at five")

        XCTAssertTrue(sent)
        XCTAssertEqual(recorder.events.first, "report rt-voice \(TurnSurface.device.rawValue) spoken")
    }

    func testACallersSurfaceWinsOverTheComposers() async {
        let recorder = TurnSurfaceRecorder()
        let harness = makeHarness(recorder: recorder)
        openChat("rt-shortcut", in: harness)
        harness.appState.submissionTurnSurface = ("Log my water", .shortcut)
        defer { harness.appState.submissionTurnSurface = nil }

        _ = await harness.appState.submitComposer(text: "Log my water")

        XCTAssertEqual(recorder.events.first, "report rt-shortcut siri -")
    }

    func testATypedSendDuringAShortcutsSendKeepsItsOwnSurface() async {
        let recorder = TurnSurfaceRecorder()
        let harness = makeHarness(recorder: recorder)
        openChat("rt-mixed", in: harness)
        harness.appState.submissionTurnSurface = ("Log my water", .shortcut)
        defer { harness.appState.submissionTurnSurface = nil }

        _ = await harness.appState.submitComposer(text: "Something else")

        XCTAssertEqual(recorder.events.first, "report rt-mixed \(TurnSurface.device.rawValue) typed")
    }

    func testASlowPluginDoesNotHoldTheSendUp() async {
        let recorder = TurnSurfaceRecorder()
        recorder.reportDelay = .seconds(10)
        let harness = makeHarness(recorder: recorder)
        openChat("rt-slow", in: harness)
        let started = ContinuousClock.now

        let sent = await harness.appState.submitComposer(text: "Still there?")

        XCTAssertTrue(sent)
        XCTAssertEqual(recorder.events, ["prompt rt-slow Still there?"], "The report never finished")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    func testAReportThatMissesTheSendIsCancelled() async throws {
        let recorder = TurnSurfaceRecorder()
        recorder.reportDelay = .seconds(1)
        let harness = makeHarness(recorder: recorder)
        openChat("rt-late", in: harness)

        _ = await harness.appState.submitComposer(text: "Late?")
        try await Task.sleep(for: .seconds(2))

        XCTAssertEqual(recorder.events, ["prompt rt-late Late?"], "A late report could label the next turn")
    }

    func testAFailedReportStillSends() async {
        let recorder = TurnSurfaceRecorder()
        recorder.reportError = URLError(.notConnectedToInternet)
        let harness = makeHarness(recorder: recorder)
        openChat("rt-failed", in: harness)

        let sent = await harness.appState.submitComposer(text: "Hello")

        XCTAssertTrue(sent)
        XCTAssertEqual(recorder.events.last, "prompt rt-failed Hello")
    }

    func testARefusedSendDiscardsItsReport() async throws {
        let recorder = TurnSurfaceRecorder()
        recorder.sendError = RpcError(code: 4001, message: "invalid_params")
        let harness = makeHarness(recorder: recorder)
        openChat("rt-refused", in: harness)

        _ = await harness.appState.submitComposer(text: "yes")

        for _ in 0..<50 where recorder.discards.isEmpty { await Task.yield() }
        XCTAssertEqual(recorder.discards, ["rt-refused \(recorder.digests.first ?? "?")"],
                       "No turn of it is coming: the same words from another client mustn't take its line")
    }

    func testADiscardThatFailedToGoIsTriedAgain() async {
        // Notifier issue 610: a discard lost to a passing failure left the
        // report for another client's turn of the same words.
        let recorder = TurnSurfaceRecorder()
        recorder.sendError = RpcError(code: 4001, message: "invalid_params")
        recorder.discardErrors = [URLError(.timedOut), DashboardTicketBridgeError.http(status: 503, detail: "")]
        let harness = makeHarness(recorder: recorder)
        harness.appState.turnSurfaceDiscardRetryDelays = [.milliseconds(1), .milliseconds(1), .milliseconds(1)]
        openChat("rt-retry", in: harness)

        _ = await harness.appState.submitComposer(text: "yes")

        for _ in 0..<200 where recorder.discards.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(recorder.discardTries, 3)
        XCTAssertEqual(recorder.discards, ["rt-retry \(recorder.digests.first ?? "?")"])
    }

    func testADiscardThePluginRefusedIsNotTriedAgain() {
        XCTAssertFalse(TurnSurface.discardMayGoLater(DashboardTicketBridgeError.http(status: 400, detail: "")))
        XCTAssertFalse(TurnSurface.discardMayGoLater(DashboardTicketBridgeError.http(status: 404, detail: "")))
        XCTAssertFalse(TurnSurface.discardMayGoLater(DashboardTicketBridgeError.answeredAfterSwitch),
                       "The old dashboard took it")
        XCTAssertTrue(TurnSurface.discardMayGoLater(DashboardTicketBridgeError.http(status: 0, detail: "")))
        XCTAssertTrue(TurnSurface.discardMayGoLater(DashboardTicketBridgeError.signInRequired))
        XCTAssertTrue(TurnSurface.discardMayGoLater(URLError(.timedOut)))
        XCTAssertTrue(TurnSurface.discardMayGoLater(DashboardTicketBridgeError.http(status: 408, detail: "")))
        XCTAssertTrue(TurnSurface.discardMayGoLater(DashboardTicketBridgeError.http(status: 429, detail: "")))
        XCTAssertFalse(TurnSurface.discardMayGoLater(DashboardTicketBridgeError.oversizedResponse(limit: 0)))
    }

    func testARefusedDiscardIsSentOnce() async {
        let recorder = TurnSurfaceRecorder()
        recorder.sendError = RpcError(code: 4001, message: "invalid_params")
        recorder.discardErrors = [DashboardTicketBridgeError.http(status: 400, detail: "")]
        let harness = makeHarness(recorder: recorder)
        harness.appState.turnSurfaceDiscardRetryDelays = [.milliseconds(1), .milliseconds(1), .milliseconds(1)]
        openChat("rt-refused-discard", in: harness)

        _ = await harness.appState.submitComposer(text: "yes")

        for _ in 0..<200 where recorder.discardTries == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.discardTries, 1, "The plugin refused it: trying again changes nothing")
        XCTAssertEqual(recorder.discards, [])
    }

    func testADiscardAfterADashboardSwitchGoesNowhere() async {
        // Issue 2222: a send that failed because its dashboard was switched
        // away mustn't hand its text to the dashboard now active.
        let recorder = TurnSurfaceRecorder()
        let harness = makeHarness(recorder: recorder)
        let appState = harness.appState

        appState.discardTurnSurface(runtimeSessionID: "rt-left", text: "yes",
                                    after: ShortcutSendError.chatOnAnotherDashboard, reportedOn: UUID())
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(recorder.discardTries, 0, "Reported on another dashboard: nothing discarded on this one")

        appState.discardTurnSurface(runtimeSessionID: "rt-stayed", text: "yes",
                                    after: RpcError(code: 4001, message: "invalid_params"),
                                    reportedOn: appState.activeDashboardID)
        for _ in 0..<50 where recorder.discards.isEmpty { await Task.yield() }
        XCTAssertEqual(recorder.discards.count, 1, "Still on the dashboard it reported to")
    }

    func testADiscardStopsRetryingOnceItsDashboardIsSwitchedAway() async {
        // Issue 2222 follow-up: a switch while a discard waits to try again
        // ends it; the retry never goes to either dashboard.
        let keychain = InMemoryKeychainBackend()
        KeychainHelper.useBackendForTesting(keychain)
        defer { KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend()) }
        let first = SavedDashboard(id: UUID(), label: "First", normalizedURL: "https://one.example")
        let second = SavedDashboard(id: UUID(), label: "Second", normalizedURL: "https://two.example")
        let harness = makeHarness(recorder: nil,
                                  registry: SavedDashboardRegistry(activeDashboardID: first.id, dashboards: [first, second]))
        let appState = harness.appState
        appState.turnSurfaceDiscardRetryDelays = [.milliseconds(1), .milliseconds(1), .milliseconds(1)]
        let recorder = TurnSurfaceRecorder()
        // The first try fails, and the dashboard switches before it returns:
        // whenever the retry wakes, the switch has already landed.
        appState.turnSurfaceDiscarder = { [weak appState] _ in
            recorder.discardTries += 1
            appState?.selectDashboardTarget(second.id)
            throw URLError(.timedOut)
        }

        appState.discardTurnSurface(runtimeSessionID: "rt-first", text: "yes",
                                    after: RpcError(code: 4001, message: "invalid_params"), reportedOn: first.id)
        for _ in 0..<200 where recorder.discardTries == 0 { try? await Task.sleep(for: .milliseconds(1)) }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.discardTries, 1, "Switched away while it waited: no retry goes")

        appState.discardTurnSurface(runtimeSessionID: "rt-first", text: "again",
                                    after: RpcError(code: 4001, message: "invalid_params"), reportedOn: first.id)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(recorder.discardTries, 1, "Reported on the first dashboard: nothing goes to the second")
    }

    func testASendWhoseReplyWasLostKeepsItsReport() async {
        let recorder = TurnSurfaceRecorder()
        recorder.sendError = URLError(.networkConnectionLost)
        let harness = makeHarness(recorder: recorder)
        openChat("rt-lost", in: harness)

        _ = await harness.appState.submitComposer(text: "yes")

        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(recorder.discards, [], "It may have started: its turn still takes the line")
    }

    func testOnlyAPluginThatReportsTheCapabilityTakesReports() {
        var plugin = NotifierPluginStatus()
        XCTAssertFalse(TurnSurface.isTaken(by: plugin), "Nothing reported yet")
        plugin.state = .predatesCapabilities
        XCTAssertFalse(TurnSurface.isTaken(by: plugin))
        plugin.state = .reported(version: "0.50.1", capabilities: ["desktop-views"])
        XCTAssertFalse(TurnSurface.isTaken(by: plugin))
        plugin.state = .reported(version: "0.51.0", capabilities: ["desktop-views", "turn-surface"])
        XCTAssertTrue(TurnSurface.isTaken(by: plugin))
        XCTAssertNil(makeHarness(recorder: nil).appState.reportTurnSurface(.shortcut, runtimeSessionID: "rt-none", text: "hi"))
    }

    // MARK: - Harness

    private typealias Harness = (appState: AppState, defaults: UserDefaults)

    private func makeHarness(recorder: TurnSurfaceRecorder?, registry: SavedDashboardRegistry? = nil) -> Harness {
        let defaults = makeScratchDefaults("AppStateTurnSurfaceTests")
        let operations = ChatResumeLifecycleOperations(
            sendPrompt: { _, sessionID, text in
                recorder?.events.append("prompt \(sessionID) \(text)")
                if let error = recorder?.sendError { throw error }
                return .accepted
            }
        )
        let store = ChatResumeStore(defaults: defaults)
        let appState = AppState(
            defaults: defaults,
            chatResumeCoordinator: ChatResumeCoordinator(store: store),
            recoverySequence: ChatResumeRecoverySequence(),
            loadSavedConnection: false,
            dashboardRegistry: registry,
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: operations,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        if let recorder {
            appState.turnSurfaceSender = { body in try await recorder.report(body) }
            appState.turnSurfaceDiscarder = { body in
                recorder.discardTries += 1
                if !recorder.discardErrors.isEmpty { throw recorder.discardErrors.removeFirst() }
                recorder.discards.append("\(body["session_id"] as? String ?? "?") \(body["text_sha256"] as? String ?? "?")")
            }
        }
        return (appState, defaults)
    }

    private func openChat(_ id: String, in harness: Harness) {
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")
        harness.appState.sessions = [SessionSummary(
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
        harness.appState.activeSessionId = id
    }
}

@MainActor
private final class TurnSurfaceRecorder {
    var events: [String] = []
    var digests: [String] = []
    var reportDelay: Duration?
    var reportError: Error?
    var sendError: Error?
    var discards: [String] = []
    var discardErrors: [Error] = []
    var discardTries = 0

    func report(_ body: [String: Any]) async throws {
        if let reportDelay { try await Task.sleep(for: reportDelay) }
        if let reportError { throw reportError }
        let session = body["session_id"] as? String ?? "?"
        let surface = body["surface"] as? String ?? "?"
        digests.append(body["text_sha256"] as? String ?? "")
        events.append("report \(session) \(surface) \(body["input"] as? String ?? "-")")
    }
}
