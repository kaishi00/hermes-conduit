//
//  ReconnectBackoffTests.swift
//  Conduit
//
//  A dropped chat socket reconnects on an exponential backoff with full
//  jitter, capped at 60 s, and waits for a usable network path instead of
//  retrying into nothing; a path change reconnects at once. An extension
//  of CarPlayTransportRecoveryTests: the hosted planner's lanes are full,
//  so a new class would need another lane.
//

import Combine
import XCTest
@testable import Conduit

private final class BackoffRecorder {
    var delays: [TimeInterval] = []
    var operations: [@MainActor () async -> Void] = []
    var cancelled = 0
    var executed = 0
}

extension CarPlayTransportRecoveryTests {
    private func makeBackoffAppState(
        _ recorder: BackoffRecorder,
        conditions: @escaping @MainActor () -> DeviceConditions = { DeviceConditions() },
        jitter: Double = 1,
        updates: AnyPublisher<DeviceConditions, Never> = Empty().eraseToAnyPublisher()
    ) -> AppState {
        let defaults = makeScratchDefaults("ReconnectBackoffTests")
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            reconnectScheduler: { delay, operation in
                recorder.delays.append(delay)
                recorder.operations.append(operation)
                return { recorder.cancelled += 1 }
            },
            reconnectExecutor: { _ in recorder.executed += 1 },
            deviceConditionsUpdates: updates
        )
        appState.connection = HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket")
        appState.isConnected = false
        appState.isConnecting = false
        appState.reconnectJitter = { jitter }
        appState.deviceConditions = conditions
        return appState
    }

    func testOnScreenTheBackoffStopsAtEightSecondsInTheUpperHalf() {
        XCTAssertEqual(PollCadence.reconnectDelay(attempt: 0, random: 1, onScreen: true), 1)
        XCTAssertEqual(PollCadence.reconnectDelay(attempt: 3, random: 1, onScreen: true), 8)
        XCTAssertEqual(PollCadence.reconnectDelay(attempt: 9, random: 1, onScreen: true), 8)
        XCTAssertEqual(PollCadence.reconnectDelay(attempt: 9, random: 0, onScreen: true), 4)
        XCTAssertEqual(PollCadence.reconnectDelay(attempt: 0, random: 0, onScreen: true), 0.5)
    }

    func testTheReadinessProbeCountsAnyAnswerButAProxysDownPage() {
        XCTAssertTrue(GatewayReadinessProbe.answered(status: 200))
        XCTAssertTrue(GatewayReadinessProbe.answered(status: 302), "A sign-in redirect is a gateway that answers")
        XCTAssertTrue(GatewayReadinessProbe.answered(status: 405), "HEAD refused is still an answer")
        XCTAssertTrue(GatewayReadinessProbe.answered(status: 401))
        XCTAssertFalse(GatewayReadinessProbe.answered(status: 502))
        XCTAssertFalse(GatewayReadinessProbe.answered(status: 503))
        XCTAssertFalse(GatewayReadinessProbe.answered(status: 504))
        for status in [520, 521, 522, 523, 524, 530] {
            XCTAssertFalse(GatewayReadinessProbe.answered(status: status), "Cloudflare's origin-down \(status)")
        }
    }

    func testOnScreenAGatewayThatDoesntAnswerCostsOnlyAProbe() async {
        let recorder = BackoffRecorder()
        let appState = makeBackoffAppState(recorder)
        var probes = 0
        var answers = false
        appState.gatewayReadinessProbe = { _ in probes += 1; return answers }
        appState.scheduleReconnect()
        for _ in 0..<5 { await recorder.operations.last?() }
        XCTAssertEqual(probes, 5)
        XCTAssertEqual(recorder.executed, 0, "No full reconnect while the gateway doesn't answer")
        XCTAssertEqual(recorder.delays, [1, 2, 4, 8, 8, 8], "Each unanswered probe is a step")

        answers = true
        await recorder.operations.last?()
        XCTAssertEqual(probes, 6)
        XCTAssertEqual(recorder.executed, 1, "The gateway back: the full reconnect runs at that step")
    }

    func testOffScreenTheBackoffStillGoesToAMinuteWithoutProbes() async {
        let recorder = BackoffRecorder()
        let appState = makeBackoffAppState(recorder)
        var probes = 0
        appState.gatewayReadinessProbe = { _ in probes += 1; return false }
        appState.handleScenePhase(.background)
        appState.isNativeHermesCallActive = true
        for _ in 0..<8 {
            appState.scheduleReconnect()
            await recorder.operations.last?()
        }
        XCTAssertEqual(recorder.delays, [1, 2, 4, 8, 16, 32, 60, 60])
        XCTAssertEqual(probes, 0)
        XCTAssertEqual(recorder.executed, 8)
    }

    func testReconnectBackoffDoublesToAMinuteWithFullJitter() {
        XCTAssertEqual(PollCadence.reconnectDelay(attempt: 0, random: 1), 1)
        XCTAssertEqual(PollCadence.reconnectDelay(attempt: 3, random: 1), 8)
        XCTAssertEqual(PollCadence.reconnectDelay(attempt: 6, random: 1), 60)
        XCTAssertEqual(PollCadence.reconnectDelay(attempt: 40, random: 1), 60, "Capped, and no overflow")
        XCTAssertEqual(PollCadence.reconnectDelay(attempt: 6, random: 0.5), 30)
        XCTAssertEqual(PollCadence.reconnectDelay(attempt: 6, random: 0), 0.5, "Never a tight loop")
        XCTAssertEqual(PollCadence.reconnectDelay(attempt: -1, random: 1), 1)
    }

    func testOnScreenRepeatedFailuresBackOffToEightSeconds() async {
        let recorder = BackoffRecorder()
        let appState = makeBackoffAppState(recorder)
        for _ in 0..<8 {
            appState.scheduleReconnect()
            await recorder.operations.last?()
        }
        XCTAssertEqual(recorder.delays, [1, 2, 4, 8, 8, 8, 8, 8])
        XCTAssertEqual(recorder.executed, 8, "No probe in tests that bring their own executor")
    }

    func testWithoutANetworkTheReconnectWaitsForTheNetworkToComeBack() async {
        let recorder = BackoffRecorder()
        var conditions = DeviceConditions(pathSatisfied: false)
        let appState = makeBackoffAppState(recorder, conditions: { conditions })
        appState.scheduleReconnect()
        XCTAssertEqual(recorder.delays, [60], "Only a fallback timer while offline")

        // A path that isn't usable yet changes nothing.
        appState.networkPathChanged(satisfied: false)
        XCTAssertEqual(recorder.delays, [60])

        conditions.pathSatisfied = true
        appState.networkPathChanged(satisfied: true)
        XCTAssertEqual(recorder.cancelled, 1, "The fallback timer goes")
        XCTAssertEqual(recorder.delays.last ?? 0, 0.1, accuracy: 0.001, "The network back reconnects at once")
        await recorder.operations.last?()
        XCTAssertEqual(recorder.executed, 1)
    }

    /// A socket that drops mid-reply reconnects at once, but only with a
    /// network to reconnect over: offline it waits for the path like any
    /// other drop.
    func testADropMidReplyWaitsForTheNetworkLikeAnyOther() {
        for (pathSatisfied, expected) in [(false, 60.0), (true, 0.1)] {
            let recorder = BackoffRecorder()
            let appState = makeBackoffAppState(recorder, conditions: { DeviceConditions(pathSatisfied: pathSatisfied) })
            appState.activeSessionId = "chat"
            appState.handleStreamEvent(.sessionBusy(sessionId: "chat", busy: true))
            XCTAssertEqual(appState.turnState, .running)
            appState.handleDisconnectForTesting()
            XCTAssertEqual(recorder.delays.count, 1, "path satisfied: \(pathSatisfied)")
            XCTAssertEqual(recorder.delays.first ?? 0, expected, accuracy: 0.001, "path satisfied: \(pathSatisfied)")
        }
    }

    func testAPathChangeSkipsTheRestOfALongBackoff() async {
        let recorder = BackoffRecorder()
        let appState = makeBackoffAppState(recorder)
        for _ in 0..<5 {
            appState.scheduleReconnect()
            await recorder.operations.last?()
        }
        appState.scheduleReconnect()
        XCTAssertEqual(recorder.delays.last, 8)

        appState.networkPathChanged(satisfied: true)
        XCTAssertEqual(recorder.delays.last ?? 0, 0.1, accuracy: 0.001)
        await recorder.operations.last?()
        appState.scheduleReconnect()
        XCTAssertEqual(recorder.delays.last, 1, "The backoff starts over after a path change")
    }

    func testAPathChangeWhileConnectedLeavesReconnectAlone() {
        let recorder = BackoffRecorder()
        let appState = makeBackoffAppState(recorder)
        appState.isConnected = true
        appState.networkPathChanged(satisfied: true)
        XCTAssertTrue(recorder.delays.isEmpty)
    }

    func testThePathMonitorCountsChangesAfterItsFirstReport() {
        let monitor = DeviceConditionsMonitor(processInfo: .processInfo, notificationCenter: NotificationCenter())
        monitor.notePath(constrained: false, expensive: false, satisfied: true)
        XCTAssertEqual(monitor.current.pathGeneration, 0, "The first report is the current path, not a change")
        monitor.notePath(constrained: false, expensive: true, satisfied: true)
        XCTAssertEqual(monitor.current.pathGeneration, 1)
        XCTAssertTrue(monitor.current.expensivePath)
        monitor.notePath(constrained: true, expensive: true, satisfied: false)
        XCTAssertEqual(monitor.current.pathGeneration, 2)
        XCTAssertFalse(monitor.current.pathSatisfied)
        XCTAssertEqual(monitor.current.pollStretch, 2)
    }

    func testThePathMonitorDrivesReconnectAndTheNetworkState() async {
        let recorder = BackoffRecorder()
        let updates = PassthroughSubject<DeviceConditions, Never>()
        var conditions = DeviceConditions()
        let appState = makeBackoffAppState(recorder, conditions: { conditions }, updates: updates.eraseToAnyPublisher())
        appState.scheduleReconnect()
        XCTAssertTrue(appState.networkPathUsable)

        // The network goes: the status says so at once, and nothing retries
        // but the fallback timer.
        conditions = DeviceConditions(pathSatisfied: false, pathGeneration: 1)
        updates.send(conditions)
        XCTAssertFalse(appState.networkPathUsable, "The status words read offline, not reconnecting")
        await recorder.operations.last?()
        appState.scheduleReconnect()
        XCTAssertEqual(recorder.delays.last, 60)

        // It comes back: an immediate reconnect.
        conditions = DeviceConditions(pathSatisfied: true, pathGeneration: 2)
        updates.send(conditions)
        XCTAssertTrue(appState.networkPathUsable)
        XCTAssertEqual(recorder.delays.last ?? 0, 0.1, accuracy: 0.001)
    }

    func testAnUnchangedPathReportDoesNothing() {
        let recorder = BackoffRecorder()
        let updates = PassthroughSubject<DeviceConditions, Never>()
        let appState = makeBackoffAppState(recorder, updates: updates.eraseToAnyPublisher())
        appState.scheduleReconnect()
        // The same generation (a Low Power change, a replay) is no path change.
        updates.send(DeviceConditions(lowPowerMode: true))
        XCTAssertEqual(recorder.delays, [1])
        XCTAssertEqual(recorder.cancelled, 0)
    }

    func testAChurnyNetworkRestartsTheBackoffAtMostEveryThirtySeconds() async {
        let recorder = BackoffRecorder()
        let appState = makeBackoffAppState(recorder)
        let start = Date(timeIntervalSince1970: 1_000_000)
        for _ in 0..<4 {
            appState.scheduleReconnect()
            await recorder.operations.last?()
        }
        appState.scheduleReconnect()
        appState.networkPathChanged(satisfied: true, now: start)
        XCTAssertEqual(recorder.delays.last ?? 0, 0.1, accuracy: 0.001)
        await recorder.operations.last?()
        for _ in 0..<3 {
            appState.scheduleReconnect()
            await recorder.operations.last?()
        }
        appState.scheduleReconnect()
        let armed = recorder.delays.count
        appState.networkPathChanged(satisfied: true, now: start.addingTimeInterval(10))
        XCTAssertEqual(recorder.delays.count, armed, "A handover 10 s later leaves the backoff alone")
        appState.networkPathChanged(satisfied: true, cameBack: true, now: start.addingTimeInterval(12))
        XCTAssertEqual(recorder.delays.last ?? 0, 0.1, accuracy: 0.001, "The network coming back always reconnects")
    }

    func testAPathChangeDuringAConnectLeavesItAlone() {
        let recorder = BackoffRecorder()
        let appState = makeBackoffAppState(recorder)
        appState.scheduleReconnect()
        appState.isConnecting = true
        appState.networkPathChanged(satisfied: true)
        XCTAssertEqual(recorder.delays, [1])
        XCTAssertEqual(recorder.cancelled, 0)
    }
}
