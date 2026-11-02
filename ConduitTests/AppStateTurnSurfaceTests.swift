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

    private func makeHarness(recorder: TurnSurfaceRecorder?) -> Harness {
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
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: operations,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        if let recorder {
            appState.turnSurfaceSender = { body in try await recorder.report(body) }
            appState.turnSurfaceDiscarder = { body in
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

    func report(_ body: [String: Any]) async throws {
        if let reportDelay { try await Task.sleep(for: reportDelay) }
        if let reportError { throw reportError }
        let session = body["session_id"] as? String ?? "?"
        let surface = body["surface"] as? String ?? "?"
        digests.append(body["text_sha256"] as? String ?? "")
        events.append("report \(session) \(surface) \(body["input"] as? String ?? "-")")
    }
}
