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
    }

    private func makeAppState(recorder: ReconnectRecorder) -> AppState {
        let suite = "CarPlayTransportRecoveryTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
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
            }
        )
        appState.connection = HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket")
        appState.isConnected = false
        appState.isConnecting = false
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

    func testOverlayDipWithCarPlayActiveReArmsTheReconnect() {
        let recorder = ReconnectRecorder()
        let appState = makeAppState(recorder: recorder)
        appState.setCarPlayVoiceSurfaceActive(true)

        appState.handleScenePhase(.inactive)

        XCTAssertEqual(recorder.scheduledDelays.count, 1, "the dropped timer is re-armed for CarPlay")
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
}
