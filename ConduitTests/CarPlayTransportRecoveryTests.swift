//
//  CarPlayTransportRecoveryTests.swift
//  Conduit
//
//  In a car the phone is usually locked, so no phone scene-phase event ever
//  re-establishes a transport that died during an earlier background
//  suspension. A connected CarPlay Voice surface counts as a foreground
//  surface for transport recovery and starts the reconnect itself; without
//  CarPlay, the phone-scene gate is unchanged.
//

import XCTest
@testable import Conduit

@MainActor
final class CarPlayTransportRecoveryTests: XCTestCase {
    private final class ReconnectRecorder {
        var scheduledDelays: [TimeInterval] = []
        var operations: [@MainActor () async -> Void] = []
        var executedPurposes: [ChatResumeSyncPurpose] = []
        /// What the executed cycle does, such as landing the connection.
        var onExecute: (@MainActor () -> Void)?
    }

    private func makeAppState(recorder: ReconnectRecorder) -> AppState {
        let defaults = makeScratchDefaults("CarPlayTransportRecoveryTests")
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            reconnectScheduler: { delay, operation in
                recorder.scheduledDelays.append(delay)
                recorder.operations.append(operation)
                return {}
            },
            reconnectExecutor: { purpose in
                recorder.executedPurposes.append(purpose)
                recorder.onExecute?()
            }
        )
        appState.connection = HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket")
        appState.isConnected = false
        appState.isConnecting = false
        // The backoff's jitter at its top, so each step's delay is its cap.
        appState.reconnectJitter = { 1 }
        appState.deviceConditions = { DeviceConditions() }
        return appState
    }

    func testBackgroundedPhoneWithoutCarPlayStillDefersReconnect() {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.handleScenePhase(.background)

        appState.scheduleReconnect(immediately: true)
        appState.recoverTransportForCarPlayIfNeeded()

        XCTAssertTrue(recorder.scheduledDelays.isEmpty, "the phone-scene gate is unchanged without CarPlay")
    }

    func testCarPlayActivationWithLockedPhoneReconnectsADeadTransport() async {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.handleScenePhase(.background)

        appState.setCarPlayVoiceSurfaceActive(true)
        appState.handleCarPlayVoiceSurfaceActivated()

        XCTAssertEqual(recorder.scheduledDelays.count, 1, "CarPlay starts the reconnect itself")
        await recorder.operations.first?()
        XCTAssertEqual(recorder.executedPurposes.count, 1, "the cycle runs while only CarPlay is on screen")
    }

    func testTransportLossDuringACarPlayDriveSchedulesReconnect() async {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.isConnected = true
        appState.setCarPlayVoiceSurfaceActive(true)
        appState.handleCarPlayVoiceSurfaceActivated()
        appState.handleScenePhase(.background)
        XCTAssertTrue(recorder.scheduledDelays.isEmpty, "a healthy transport needs no recovery")

        appState.isConnected = false
        appState.scheduleReconnect()

        XCTAssertEqual(recorder.scheduledDelays.count, 1)
        await recorder.operations.first?()
        XCTAssertEqual(recorder.executedPurposes.count, 1)
    }

    func testCarPlayActivationWithAnActivePhoneSceneLeavesRecoveryToThePhone() {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        // Phone unlocked and foregrounded (the scene starts active).

        appState.setCarPlayVoiceSurfaceActive(true)
        appState.handleCarPlayVoiceSurfaceActivated()

        XCTAssertTrue(
            recorder.scheduledDelays.isEmpty,
            "the active phone scene's own recovery owns the transport"
        )
    }

    /// #378: the car launched Conduit, so no phone scene exists and no
    /// scene-phase event ever reported the phone off screen.
    func testCarPlayLaunchWithNoPhoneScreenReconnectsADeadTransport() async {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.setCarPlayVoiceSurfaceActive(true)
        appState.handleCarPlayVoiceSurfaceActivated()
        XCTAssertTrue(recorder.scheduledDelays.isEmpty, "the launch value claims a phone screen")

        appState.handleCarPlayConnectedWithoutPhoneScreen()

        XCTAssertEqual(recorder.scheduledDelays.count, 1, "CarPlay starts the reconnect itself")
        XCTAssertEqual(recorder.scheduledDelays.first ?? 0, 0.1, accuracy: 0.001)
        await recorder.operations.first?()
        XCTAssertEqual(recorder.executedPurposes.count, 1)
        XCTAssertTrue(appState.hasActiveVoiceSurface, "CarPlay still presents Voice")
    }

    func testOverlayDipWithCarPlayActiveReArmsTheReconnect() {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.setCarPlayVoiceSurfaceActive(true)

        appState.handleScenePhase(.inactive)

        XCTAssertEqual(recorder.scheduledDelays.count, 1, "the dropped timer is re-armed for CarPlay")
    }

    func testCarPlayReArmsFollowTheBackoffAfterTheImmediateConnectRetry() async {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.handleScenePhase(.background)
        appState.setCarPlayVoiceSurfaceActive(true)
        appState.handleCarPlayVoiceSurfaceActivated()
        await recorder.operations.last?()

        // Phone-scene transitions during the drive re-arm the dead transport.
        appState.handleScenePhase(.background)
        await recorder.operations.last?()
        appState.handleScenePhase(.background)

        XCTAssertEqual(recorder.scheduledDelays.count, 3)
        XCTAssertEqual(recorder.scheduledDelays[0], 0.1, accuracy: 0.001, "CarPlay connect retries at once")
        XCTAssertGreaterThan(recorder.scheduledDelays[1], 0.1, "later re-arms use the backoff delay")
        XCTAssertGreaterThan(
            recorder.scheduledDelays[2], recorder.scheduledDelays[1],
            "the backoff grows instead of resetting to an immediate retry"
        )
    }

    func testFailedRestoreDuringACarPlayWaitHandsOffToRecovery() async {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.handleScenePhase(.background)
        appState.setCarPlayVoiceSurfaceActive(true)
        appState.isConnecting = true
        appState.handleCarPlayVoiceSurfaceActivated()
        XCTAssertTrue(recorder.scheduledDelays.isEmpty, "the in-flight restore owns the flow")

        let wait = Task { @MainActor in
            await CarPlayVoiceCoordinator.awaitConnection(of: appState, timeout: .milliseconds(500))
        }
        // The restore fails: still disconnected, no longer connecting. The
        // watcher may or may not have subscribed yet; either order hands off.
        appState.isConnecting = false
        for _ in 0..<500 where recorder.scheduledDelays.isEmpty { await Task.yield() }

        XCTAssertEqual(recorder.scheduledDelays.count, 1, "the failed restore handed off to a reconnect")
        let connected = await wait.value
        XCTAssertFalse(connected)
    }

    func testCarPlayActivationLeavesAnInFlightRestoreAlone() {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.handleScenePhase(.background)
        appState.isConnecting = true

        appState.setCarPlayVoiceSurfaceActive(true)
        appState.handleCarPlayVoiceSurfaceActivated()

        XCTAssertTrue(recorder.scheduledDelays.isEmpty)
    }

    func testCarPlayActivationWithoutASavedConnectionDoesNothing() {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.handleScenePhase(.background)
        appState.connection = nil

        appState.setCarPlayVoiceSurfaceActive(true)
        appState.handleCarPlayVoiceSurfaceActivated()

        XCTAssertTrue(recorder.scheduledDelays.isEmpty)
    }

    // MARK: - #1060: back on the car's screen, and call requests during a drop

    private final class RequestProgress {
        var finished = false
    }

    func testCarPlayScreenReturningReconnectsAtOnceInsteadOfWaitingOutTheBackoff() {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.handleScenePhase(.background)
        appState.setCarPlayVoiceSurfaceActive(true)
        appState.scheduleReconnect()
        XCTAssertEqual(recorder.scheduledDelays.count, 1)
        XCTAssertGreaterThan(recorder.scheduledDelays[0], 0.1, "a drop waits out its backoff")

        appState.handleCarPlaySceneWillEnterForeground()

        XCTAssertEqual(recorder.scheduledDelays.count, 2, "the armed backoff is replaced")
        XCTAssertEqual(recorder.scheduledDelays[1], 0.1, accuracy: 0.001, "the driver is back: reconnect now")
    }

    func testCarPlayScreenReturningWithThePhoneOnScreenLeavesRecoveryToThePhone() {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.setCarPlayVoiceSurfaceActive(true)

        appState.handleCarPlaySceneWillEnterForeground()

        XCTAssertTrue(recorder.scheduledDelays.isEmpty)
    }

    func testCarPlayScreenReturningLeavesAReconnectUnderWayAlone() {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.handleScenePhase(.background)
        appState.setCarPlayVoiceSurfaceActive(true)
        appState.isConnecting = true

        appState.handleCarPlaySceneWillEnterForeground()

        XCTAssertTrue(recorder.scheduledDelays.isEmpty)
    }

    func testCallRequestDuringADropWaitsForTheReconnect() async throws {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.handleScenePhase(.background)
        appState.setCarPlayVoiceSurfaceActive(true)
        let client = HermesClient(
            connection: HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket"),
            profile: "default"
        )
        appState.client = client
        appState.isConnecting = true
        appState.voiceRequestConnectionWait = .seconds(30)

        let progress = RequestProgress()
        let request = Task { @MainActor () -> HermesClient? in
            defer { progress.finished = true }
            return try? await appState.clientForVoiceRequest()
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(progress.finished, "the request waits while the connection comes back")

        let started = Date()
        appState.isConnected = true
        appState.isConnecting = false
        let resolved = await request.value

        XCTAssertTrue(resolved === client)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "it goes as soon as Hermes is back")
    }

    func testCallRequestWithoutADropDoesNotWait() async throws {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        let client = HermesClient(
            connection: HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket"),
            profile: "default"
        )
        appState.client = client
        appState.voiceRequestConnectionWait = .seconds(30)

        let started = Date()
        let resolved = try await appState.clientForVoiceRequest()

        XCTAssertTrue(resolved === client)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertTrue(recorder.scheduledDelays.isEmpty, "nothing was dropped, so nothing reconnects")
    }

    func testCallRequestGivesUpWhenTheConnectionDoesNotComeBack() async throws {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.handleScenePhase(.background)
        appState.setCarPlayVoiceSurfaceActive(true)
        appState.isConnecting = true
        appState.voiceRequestConnectionWait = .milliseconds(200)

        do {
            _ = try await appState.clientForVoiceRequest()
            XCTFail("no client to send on")
        } catch HermesError.notConnected {
            // As before the wait: the request isn't sent.
        }
    }

    func testCallRequestGivesUpOnAStaleClientWhenTheConnectionDoesNotComeBack() async throws {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.handleScenePhase(.background)
        appState.setCarPlayVoiceSurfaceActive(true)
        // A drop leaves the old client in place, its socket closed.
        appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket"),
            profile: "default"
        )
        appState.isConnecting = true
        appState.voiceRequestConnectionWait = .milliseconds(200)

        do {
            _ = try await appState.clientForVoiceRequest()
            XCTFail("the dead connection's client is not handed out")
        } catch HermesError.notConnected {}
    }

    func testCallRequestWithoutCarPlayOffScreenFailsAtOnce() async throws {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.handleScenePhase(.background)
        appState.isConnecting = true
        appState.voiceRequestConnectionWait = .seconds(30)

        let started = Date()
        do {
            _ = try await appState.clientForVoiceRequest()
            XCTFail("no client to send on")
        } catch HermesError.notConnected {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "nothing here may reconnect, so nothing waits")
    }

    /// CarPlay woke Conduit with the phone locked, on a socket that died
    /// while iOS held it suspended and still looks open. A call's request
    /// checks it first, and waits for the reconnect rather than going out
    /// on the dead socket until it times out (#1362).
    func testAnOffScreenRequestOnAQuietDeadSocketWaitsForTheReconnect() async throws {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.handleScenePhase(.background)
        appState.setCarPlayVoiceSurfaceActive(true)
        let client = HermesClient(
            connection: HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket"),
            profile: "default"
        )
        appState.client = client
        appState.isConnected = true
        appState.voiceRequestConnectionWait = .seconds(30)
        var checks = 0
        appState.quietTransportLiveness = { _ in
            checks += 1
            // The unanswered ping closes the socket; the reconnect starts.
            appState.isConnected = false
            appState.isConnecting = true
            return false
        }

        let progress = RequestProgress()
        let request = Task { @MainActor () -> HermesClient? in
            defer { progress.finished = true }
            return try? await appState.clientForVoiceRequest()
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(checks, 1)
        XCTAssertFalse(progress.finished, "the request waits for the reconnect")

        appState.isConnected = true
        appState.isConnecting = false
        let resolved = await request.value

        XCTAssertTrue(resolved === client)
    }

    func testAnOffScreenRequestOnALiveSocketGoesAtOnce() async throws {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.handleScenePhase(.background)
        appState.setCarPlayVoiceSurfaceActive(true)
        let client = HermesClient(
            connection: HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket"),
            profile: "default"
        )
        appState.client = client
        appState.isConnected = true
        var checks = 0
        appState.quietTransportLiveness = { _ in
            checks += 1
            return true
        }

        let resolved = try await appState.clientForVoiceRequest()

        XCTAssertTrue(resolved === client)
        XCTAssertEqual(checks, 1)
        XCTAssertTrue(recorder.scheduledDelays.isEmpty, "a live socket isn't reconnected")
    }

    /// With the phone on screen its own foreground check owns the socket.
    func testARequestWithThePhoneOnScreenDoesNotCheckTheSocket() async throws {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        XCTAssertTrue(appState.isSceneActive)
        let client = HermesClient(
            connection: HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket"),
            profile: "default"
        )
        appState.client = client
        appState.isConnected = true
        var checks = 0
        appState.quietTransportLiveness = { _ in
            checks += 1
            return false
        }

        let resolved = try await appState.clientForVoiceRequest()

        XCTAssertTrue(resolved === client)
        XCTAssertEqual(checks, 0)
    }

    /// Requests at the same time share one check.
    func testConcurrentOffScreenRequestsShareOneCheck() async throws {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.handleScenePhase(.background)
        appState.setCarPlayVoiceSurfaceActive(true)
        let client = HermesClient(
            connection: HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket"),
            profile: "default"
        )
        appState.client = client
        appState.isConnected = true
        var checks = 0
        var held: CheckedContinuation<Bool?, Never>?
        appState.quietTransportLiveness = { _ in
            checks += 1
            return await withCheckedContinuation { held = $0 }
        }

        let first = Task { @MainActor in try? await appState.clientForVoiceRequest() }
        for _ in 0..<50 where held == nil { await Task.yield() }
        let second = Task { @MainActor in try? await appState.clientForVoiceRequest() }
        for _ in 0..<20 { await Task.yield() }
        held?.resume(returning: true)
        let resolved = [await first.value, await second.value]

        XCTAssertEqual(checks, 1)
        XCTAssertTrue(resolved.allSatisfy { $0 === client })
    }

    // MARK: Shortcut sends (#2164)

    /// A Send to Hermes run with Conduit in the background: the socket died
    /// while Conduit was suspended, and nothing else may reconnect it. The
    /// run reconnects at once, and only while it lasts.
    func testShortcutSendInTheBackgroundReconnectsADeadTransport() async {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.handleScenePhase(.background)
        let request = ShortcutSendRequest(text: "Buy milk", chatName: nil, profile: nil, waitsForAnswer: false)

        // A deadline already reached: the run gives up at once.
        do {
            _ = try await appState.sendFromShortcut(request, deadline: Date())
            XCTFail("nothing connected")
        } catch {
            XCTAssertEqual(error as? ShortcutSendError, .notConnected)
        }

        XCTAssertFalse(recorder.scheduledDelays.isEmpty, "the run starts the reconnect itself")
        XCTAssertLessThanOrEqual(recorder.scheduledDelays.first ?? .infinity, 0.1, "not at the end of a backoff")
        XCTAssertEqual(appState.shortcutSendsRunning, 0, "the run's permission ends with it")
        await recorder.operations.first?()
        XCTAssertTrue(recorder.executedPurposes.isEmpty, "a cycle that comes due after the run waits for the phone")
    }

    func testShortcutSendRunningAdmitsTheReconnectCycle() async {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.handleScenePhase(.background)
        appState.shortcutSendsRunning = 1

        appState.recoverTransportForCarPlayIfNeeded()

        XCTAssertEqual(recorder.scheduledDelays.count, 1)
        await recorder.operations.first?()
        XCTAssertEqual(recorder.executedPurposes.count, 1, "the cycle runs while the shortcut does")
    }

    /// The run waits for the reconnect it started, and goes on once it lands.
    func testShortcutSendInTheBackgroundGoesOnOnceTheReconnectLands() async {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.handleScenePhase(.background)
        appState.shortcutSendsRunning = 1
        recorder.onExecute = {
            appState.client = HermesClient(
                connection: HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket"),
                profile: "default"
            )
            appState.isConnected = true
        }

        let connect = appState.makeShortcutSendBackend().connect
        let run = Task { @MainActor in await connect(Date().addingTimeInterval(20)) }
        for _ in 0..<500 where recorder.operations.isEmpty { await Task.yield() }
        await recorder.operations.first?()

        let connected = await run.value
        XCTAssertTrue(connected)
        XCTAssertEqual(recorder.executedPurposes.count, 1, "the cycle ran during the send")
    }

    /// A connect the run started outlives the run: it may run on until it
    /// settles, so it never leaves Conduit "connecting" with nothing
    /// running, for the next run to wait on in vain.
    func testAConnectUnderWayRunsOnAfterTheRunUntilItSettles() async {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.handleScenePhase(.background)
        appState.shortcutSendsRunning = 1
        appState.isConnecting = true

        appState.endShortcutSend()

        XCTAssertEqual(appState.shortcutSendsRunning, 0)
        XCTAssertTrue(appState.isShortcutSendRunning, "the connect under way may still finish")
        // However long it takes: no time limit cuts a slow connect off.
        for _ in 0..<200 { await Task.yield() }
        XCTAssertTrue(appState.shortcutConnectHeld, "still under way, still held")
        appState.isConnecting = false
        for _ in 0..<500 where appState.shortcutConnectHeld { await Task.yield() }
        XCTAssertFalse(appState.isShortcutSendRunning, "settled, the phone's gate is back")
    }

    func testARunWithNothingUnderWayEndsAtOnce() {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.handleScenePhase(.background)
        appState.shortcutSendsRunning = 1

        appState.endShortcutSend()

        XCTAssertFalse(appState.isShortcutSendRunning)
    }

    /// A socket that still looks open after the suspension, and has been
    /// quiet, is checked before the run sends, as a call's request is.
    func testShortcutSendChecksAQuietSocketOffScreen() async {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.handleScenePhase(.background)
        appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket"),
            profile: "default"
        )
        appState.isConnected = true
        var checks = 0
        appState.quietTransportLiveness = { _ in
            checks += 1
            return true
        }

        let connected = await appState.makeShortcutSendBackend().connect(Date().addingTimeInterval(20))

        XCTAssertTrue(connected)
        XCTAssertEqual(checks, 1)
        XCTAssertTrue(recorder.scheduledDelays.isEmpty, "a socket that answers needs no reconnect")
    }
}
