//
//  PendingVoiceIntentLifecycleTests.swift
//  Conduit
//
//  Siri / external voice-launch lifecycle: exactly-once routing, profile
//  preservation, and terminal failure so a stale Siri request can never open
//  Voice after an unrelated reconnect. Connection readiness is lifecycle-
//  driven (connecting vs stable failure vs inconclusive bootstrap); the
//  30s deadline is only the inconclusive-state backstop.
//

import XCTest
@testable import Conduit

@MainActor
final class PendingVoiceIntentLifecycleTests: XCTestCase {
    private var store: PendingVoiceIntentStore!

    override func setUp() {
        super.setUp()
        store = PendingVoiceIntentStore()
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    private func connected() -> VoiceLaunchConnectionSnapshot {
        .init(isConnected: true, isConnecting: false, hasStableFailureEvidence: false, classifiedFailure: nil)
    }

    private func connecting() -> VoiceLaunchConnectionSnapshot {
        .init(isConnected: false, isConnecting: true, hasStableFailureEvidence: false, classifiedFailure: nil)
    }

    private func inconclusiveBootstrap() -> VoiceLaunchConnectionSnapshot {
        .init(isConnected: false, isConnecting: false, hasStableFailureEvidence: false, classifiedFailure: nil)
    }

    private func stableFailure(_ failure: ConnectionFailure = .unreachable) -> VoiceLaunchConnectionSnapshot {
        .init(isConnected: false, isConnecting: false, hasStableFailureEvidence: true, classifiedFailure: failure)
    }

    // MARK: - Siri intent factory

    func testSiriFactoryCreatesFreshSiriIntentWithBudgetDeadline() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let intent = PendingVoiceLaunchPolicy.makeSiriPendingIntent(
            profile: "default",
            now: now,
            budget: 30
        )

        XCTAssertEqual(intent.profile, "default")
        XCTAssertTrue(intent.startsFreshConversation)
        XCTAssertEqual(intent.source, .siri)
        XCTAssertEqual(
            intent.externalLaunchDeadline,
            now.addingTimeInterval(30)
        )
    }

    func testSiriFactoryTrimsAndDropsBlankProfiles() {
        XCTAssertNil(
            PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: nil).profile
        )
        XCTAssertNil(
            PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "   \n\t ").profile
        )
        XCTAssertEqual(
            PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "  work \n").profile,
            "work"
        )
    }

    func testComposerLaunchHasNoExternalDeadline() {
        let intent = PendingVoiceIntent(
            profile: "default",
            startsFreshConversation: false,
            source: .composer
        )
        XCTAssertNil(intent.externalLaunchDeadline)
        XCTAssertEqual(
            PendingVoiceLaunchPolicy.readiness(
                for: intent,
                connection: stableFailure(),
                now: .distantFuture
            ),
            // In-app keeps defer-and-retry even on a classified failure.
            .waiting
        )
    }

    // MARK: - Connection phase derivation

    func testSnapshotPhasePrefersConnectingOverPriorFailureEvidence() {
        // lastConnectionFailure often remains set while a new attempt runs.
        let snapshot = VoiceLaunchConnectionSnapshot(
            isConnected: false,
            isConnecting: true,
            hasStableFailureEvidence: true,
            classifiedFailure: .unreachable
        )
        XCTAssertEqual(snapshot.phase, .connecting)
    }

    func testSnapshotPhaseIsStableFailureOnlyWithPositiveEvidenceWhileIdle() {
        XCTAssertEqual(
            VoiceLaunchConnectionSnapshot(
                isConnected: false,
                isConnecting: false,
                hasStableFailureEvidence: true,
                classifiedFailure: .loginRequired
            ).phase,
            .stableFailure
        )
        XCTAssertEqual(inconclusiveBootstrap().phase, .inconclusive)
        XCTAssertEqual(connected().phase, .connected)
    }

    func testRoutingKeyPhaseChangesWhenConnectingBecomesStableFailure() {
        // ConduitApp.voiceIntentRouteKey embeds phase so a disconnect-only
        // transition still re-evaluates the pending Siri request.
        let connectingKey = "1:\(connecting().phase.rawValue):siri"
        let failedKey = "1:\(stableFailure().phase.rawValue):siri"
        XCTAssertNotEqual(connectingKey, failedKey)
        XCTAssertEqual(connecting().phase.rawValue, "connecting")
        XCTAssertEqual(stableFailure().phase.rawValue, "stableFailure")
    }

    func testAppStateVoiceLaunchSnapshotReflectsRecordedFailure() {
        let suite = "PendingVoiceIntentLifecycleTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Failed to create test UserDefaults suite")
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)

        // Cold bootstrap: no positive failure evidence yet — not terminal.
        appState.isConnected = false
        appState.isConnecting = false
        appState.lastConnectionFailure = nil
        appState.pendingLoginFailure = nil
        XCTAssertEqual(appState.voiceLaunchConnectionSnapshot().phase, .inconclusive)

        // Connecting: still wait.
        appState.isConnecting = true
        XCTAssertEqual(appState.voiceLaunchConnectionSnapshot().phase, .connecting)

        // Stable failure after the attempt ends: classified evidence.
        appState.isConnecting = false
        appState.lastConnectionFailure = .connectionRefused
        let failed = appState.voiceLaunchConnectionSnapshot()
        XCTAssertEqual(failed.phase, .stableFailure)
        XCTAssertEqual(failed.classifiedFailure, .connectionRefused)

        // Auth-required presentation is also positive evidence.
        appState.lastConnectionFailure = nil
        appState.pendingLoginFailure = .presenting(.loginRequired)
        XCTAssertEqual(appState.voiceLaunchConnectionSnapshot().phase, .stableFailure)
    }

    // MARK: - Readiness / disconnected lifecycle

    func testConnectedSiriLaunchIsReady() {
        let now = Date()
        let intent = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: nil, now: now)
        XCTAssertEqual(
            PendingVoiceLaunchPolicy.readiness(for: intent, connection: connected(), now: now),
            .ready
        )
    }

    func testSiriLaunchWaitsWhileActivelyConnecting() {
        let now = Date()
        let intent = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: nil, now: now)
        XCTAssertEqual(
            PendingVoiceLaunchPolicy.readiness(
                for: intent,
                connection: connecting(),
                now: now.addingTimeInterval(1)
            ),
            .waiting
        )
    }

    func testSiriLaunchWaitsDuringColdBootstrapWithoutFailureEvidence() {
        let now = Date()
        let intent = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: nil, now: now)
        // !isConnected && !isConnecting is NOT terminal until failure evidence exists.
        XCTAssertEqual(
            PendingVoiceLaunchPolicy.readiness(
                for: intent,
                connection: inconclusiveBootstrap(),
                now: now.addingTimeInterval(1)
            ),
            .waiting
        )
    }

    func testKnownStableConnectionFailureFailsSiriBeforeDeadline() {
        let now = Date()
        let intent = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: nil, now: now, budget: 30)
        let connection = stableFailure(.unreachable)
        let message = PendingVoiceLaunchPolicy.stableFailureMessage(for: connection)

        XCTAssertEqual(
            PendingVoiceLaunchPolicy.readiness(
                for: intent,
                connection: connection,
                now: now.addingTimeInterval(2)
            ),
            .failed(message: message)
        )
        // Classified copy wins over the generic disconnected string.
        XCTAssertTrue(message.contains(ConnectionFailure.unreachable.userMessage))
        XCTAssertNotEqual(message, PendingVoiceLaunchPolicy.disconnectedFailureMessage)
    }

    func testStableLoginRequiredFailureUsesClassifiedCopy() {
        let now = Date()
        let intent = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: nil, now: now)
        let connection = stableFailure(.loginRequired)
        XCTAssertEqual(
            PendingVoiceLaunchPolicy.readiness(for: intent, connection: connection, now: now),
            .failed(message: PendingVoiceLaunchPolicy.stableFailureMessage(for: connection))
        )
        XCTAssertTrue(
            PendingVoiceLaunchPolicy.stableFailureMessage(for: connection)
                .contains(ConnectionFailure.loginRequired.userTitle)
        )
    }

    func testExpiredSiriLaunchFailsAndNeverWaitsForReconnect() {
        let now = Date()
        let intent = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: nil, now: now, budget: 30)
        let later = now.addingTimeInterval(31)
        XCTAssertEqual(
            PendingVoiceLaunchPolicy.readiness(for: intent, connection: inconclusiveBootstrap(), now: later),
            .failed(message: PendingVoiceLaunchPolicy.expiredFailureMessage)
        )
    }

    func testExpiredSiriLaunchFailsEvenIfConnectionReturnsTooLate() {
        // Reconnect minutes later must not open Voice from an old Siri request.
        let now = Date()
        let intent = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: nil, now: now, budget: 30)
        let minutesLater = now.addingTimeInterval(5 * 60)
        XCTAssertEqual(
            PendingVoiceLaunchPolicy.readiness(for: intent, connection: connected(), now: minutesLater),
            .failed(message: PendingVoiceLaunchPolicy.expiredFailureMessage)
        )
    }

    // MARK: - Store + router exactly-once

    func testConnectedRouteConsumesExactlyOnceAndDoesNotReenqueue() async {
        store.enqueue(
            PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "default")
        )

        var handled: [PendingVoiceIntent] = []
        let router = PendingVoiceIntentRouter(store: store)
        let first = await router.routePending(connection: connected()) { intent in
            handled.append(intent)
            return true
        }
        XCTAssertEqual(first, .routed)
        XCTAssertFalse(store.hasPendingIntent)

        let second = await router.routePending(connection: connected()) { intent in
            handled.append(intent)
            return true
        }
        XCTAssertEqual(second, .idle)
        XCTAssertEqual(handled.count, 1)
        XCTAssertEqual(handled.first?.profile, "default")
        XCTAssertEqual(handled.first?.source, .siri)
    }

    func testTemporaryNotReadySiriLaunchIsRetainedWithoutHandler() async {
        store.enqueue(
            PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "work")
        )
        let router = PendingVoiceIntentRouter(store: store)
        var handlerCalls = 0

        let outcome = await router.routePending(connection: connecting()) { _ in
            handlerCalls += 1
            return true
        }

        XCTAssertEqual(outcome, .deferred)
        XCTAssertTrue(store.hasPendingIntent)
        XCTAssertEqual(handlerCalls, 0)
        XCTAssertEqual(store.pendingSource, .siri)
    }

    func testActivelyConnectingDefersWithoutConsuming() async {
        store.enqueue(PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "default"))
        let router = PendingVoiceIntentRouter(store: store)
        let outcome = await router.routePending(connection: connecting()) { _ in
            XCTFail("Connecting must not invoke the voice handler")
            return true
        }
        XCTAssertEqual(outcome, .deferred)
        XCTAssertTrue(store.hasPendingIntent)
    }

    func testStableFailureConsumesSiriRequestImmediatelyBeforeDeadline() async {
        store.enqueue(
            PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "default", budget: 30)
        )
        let router = PendingVoiceIntentRouter(store: store)
        let connection = stableFailure(.hostNotFound)
        var handlerCalls = 0

        let outcome = await router.routePending(connection: connection) { _ in
            handlerCalls += 1
            return true
        }

        let expected = PendingVoiceLaunchPolicy.stableFailureMessage(for: connection)
        XCTAssertEqual(outcome, .failed(message: expected))
        XCTAssertFalse(store.hasPendingIntent)
        XCTAssertEqual(handlerCalls, 0)
    }

    func testReconnectAfterStableFailureDoesNotLaunchStaleSiriVoice() async {
        store.enqueue(
            PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: nil, budget: 30)
        )
        let router = PendingVoiceIntentRouter(store: store)

        let failure = await router.routePending(connection: stableFailure(.timedOut)) { _ in
            XCTFail("Stable failure must not invoke the voice handler")
            return true
        }
        XCTAssertEqual(
            failure,
            .failed(message: PendingVoiceLaunchPolicy.stableFailureMessage(for: stableFailure(.timedOut)))
        )

        // Hermes is healthy again — but the store is empty.
        var handled = 0
        let afterReconnect = await router.routePending(connection: connected()) { _ in
            handled += 1
            return true
        }
        XCTAssertEqual(afterReconnect, .idle)
        XCTAssertEqual(handled, 0)
        XCTAssertFalse(store.hasPendingIntent)
    }

    func testExpiredDisconnectedSiriLaunchIsClearedNotRetained() async {
        let enqueuedAt = Date(timeIntervalSinceNow: -60)
        store.enqueue(
            PendingVoiceLaunchPolicy.makeSiriPendingIntent(
                profile: nil,
                now: enqueuedAt,
                budget: 30
            )
        )
        let router = PendingVoiceIntentRouter(store: store)
        var handlerCalls = 0

        let outcome = await router.routePending(connection: inconclusiveBootstrap(), now: Date()) { _ in
            handlerCalls += 1
            return true
        }

        XCTAssertEqual(
            outcome,
            .failed(message: PendingVoiceLaunchPolicy.expiredFailureMessage)
        )
        XCTAssertFalse(store.hasPendingIntent)
        XCTAssertEqual(handlerCalls, 0)
    }

    func testReconnectAfterTerminalFailureDoesNotLaunchStaleSiriVoice() async {
        let enqueuedAt = Date(timeIntervalSinceNow: -120)
        store.enqueue(
            PendingVoiceLaunchPolicy.makeSiriPendingIntent(
                profile: nil,
                now: enqueuedAt,
                budget: 30
            )
        )
        let router = PendingVoiceIntentRouter(store: store)

        let failure = await router.routePending(connection: inconclusiveBootstrap(), now: Date()) { _ in
            XCTFail("Expired Siri launch must not invoke the voice handler")
            return true
        }
        XCTAssertEqual(
            failure,
            .failed(message: PendingVoiceLaunchPolicy.expiredFailureMessage)
        )

        var handled = 0
        let afterReconnect = await router.routePending(connection: connected()) { _ in
            handled += 1
            return true
        }
        XCTAssertEqual(afterReconnect, .idle)
        XCTAssertEqual(handled, 0)
        XCTAssertFalse(store.hasPendingIntent)
    }

    func testSiriHandlerFailureIsTerminalAndDoesNotReenqueue() async {
        store.enqueue(
            PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "default")
        )
        let router = PendingVoiceIntentRouter(store: store)

        let outcome = await router.routePending(connection: connected()) { _ in false }

        XCTAssertEqual(
            outcome,
            .failed(message: PendingVoiceLaunchPolicy.disconnectedFailureMessage)
        )
        XCTAssertFalse(store.hasPendingIntent)
    }

    func testInAppHandlerFailureStillDefersForRetry() async {
        store.enqueue(
            PendingVoiceIntent(
                profile: "default",
                startsFreshConversation: false,
                source: .composer
            )
        )
        let router = PendingVoiceIntentRouter(store: store)

        let outcome = await router.routePending(connection: connected()) { _ in false }

        XCTAssertEqual(outcome, .deferred)
        XCTAssertTrue(store.hasPendingIntent)
        XCTAssertEqual(store.pendingSource, .composer)
    }

    func testNewerSiriRequestSupersedesOlderPendingRequest() async {
        let older = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "old")
        let newer = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "new")
        store.enqueue(older)
        store.enqueue(newer)

        let router = PendingVoiceIntentRouter(store: store)
        var handled: [PendingVoiceIntent] = []
        let outcome = await router.routePending(connection: connected()) { intent in
            handled.append(intent)
            return true
        }

        XCTAssertEqual(outcome, .routed)
        XCTAssertEqual(handled.map(\.profile), ["new"])
        XCTAssertEqual(handled.count, 1)
        XCTAssertFalse(store.hasPendingIntent)
    }

    func testClearCannotLaterResurrectTheRequest() async {
        store.enqueue(
            PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "default")
        )
        store.clear()
        XCTAssertFalse(store.hasPendingIntent)

        let router = PendingVoiceIntentRouter(store: store)
        let outcome = await router.routePending(connection: connected()) { _ in
            XCTFail("Cleared request must not route")
            return true
        }
        XCTAssertEqual(outcome, .idle)
    }

    func testRevisionAdvancesOnEnqueueSupersedeAndClear() {
        let initial = store.revision
        store.enqueue(PendingVoiceIntent(profile: "a", startsFreshConversation: true, source: .composer))
        let afterEnqueue = store.revision
        store.enqueue(PendingVoiceIntent(profile: "b", startsFreshConversation: true, source: .composer))
        let afterSupersede = store.revision
        store.clear()
        let afterClear = store.revision

        XCTAssertGreaterThan(afterEnqueue, initial)
        XCTAssertGreaterThan(afterSupersede, afterEnqueue)
        XCTAssertGreaterThan(afterClear, afterSupersede)
    }

    func testWaitingDeferralDoesNotAdvanceRevision() async {
        store.enqueue(PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "default"))
        let afterEnqueue = store.revision
        let router = PendingVoiceIntentRouter(store: store)

        let outcome = await router.routePending(connection: connecting()) { _ in
            XCTFail("Waiting must not call the handler")
            return true
        }

        XCTAssertEqual(outcome, .deferred)
        XCTAssertTrue(store.hasPendingIntent)
        XCTAssertEqual(store.revision, afterEnqueue)
    }

    func testDeferredRequeueDoesNotClobberNewerPendingRequest() {
        let older = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "old")
        let newer = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "new")

        store.enqueue(newer)
        store.requeueAsDeferred(older)

        XCTAssertTrue(store.hasPendingIntent)
        XCTAssertEqual(store.pendingSource, .siri)
        XCTAssertEqual(store.pendingProfile, "new")
    }

    func testTemporaryDeferenceDoesNotExtendExternalDeadline() async {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let intent = PendingVoiceLaunchPolicy.makeSiriPendingIntent(
            profile: "default",
            now: now,
            budget: 30
        )
        store.enqueue(intent)
        let originalDeadline = intent.externalLaunchDeadline

        let router = PendingVoiceIntentRouter(store: store)
        _ = await router.routePending(connection: connecting(), now: now.addingTimeInterval(5)) { _ in
            XCTFail("Waiting must not call the handler")
            return true
        }
        _ = await router.routePending(connection: connecting(), now: now.addingTimeInterval(10)) { _ in
            true
        }

        let expired = await router.routePending(
            connection: connecting(),
            now: now.addingTimeInterval(31)
        ) { _ in
            XCTFail("Expired after original deadline")
            return true
        }
        XCTAssertEqual(
            expired,
            .failed(message: PendingVoiceLaunchPolicy.expiredFailureMessage)
        )
        XCTAssertFalse(store.hasPendingIntent)
        _ = originalDeadline
    }

    // MARK: - Cold-start / double-route guards

    func testTwoLaunchAttemptsCannotCauseDuplicateConsumption() async {
        store.enqueue(PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "default"))
        let router = PendingVoiceIntentRouter(store: store)

        async let first = router.routePending(connection: connected()) { _ in true }
        async let second = router.routePending(connection: connected()) { _ in true }
        let outcomes = await [first, second]

        let routed = outcomes.filter { $0 == .routed }.count
        let idle = outcomes.filter { $0 == .idle }.count
        XCTAssertEqual(routed, 1)
        XCTAssertEqual(idle, 1)
        XCTAssertFalse(store.hasPendingIntent)
    }

    func testBootstrapOrderingKeepsSiriRequestUntilConnectedThenRoutesOnce() async {
        store.enqueue(PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "default"))
        let router = PendingVoiceIntentRouter(store: store)

        let waiting = await router.routePending(connection: inconclusiveBootstrap(), now: Date()) { _ in
            XCTFail("Must wait for Hermes before opening Voice")
            return true
        }
        XCTAssertEqual(waiting, .deferred)
        XCTAssertTrue(store.hasPendingIntent)

        var routes = 0
        let connectedOutcome = await router.routePending(connection: connected()) { _ in
            routes += 1
            return true
        }
        XCTAssertEqual(connectedOutcome, .routed)
        XCTAssertEqual(routes, 1)
        XCTAssertFalse(store.hasPendingIntent)

        let again = await router.routePending(connection: connected()) { _ in
            routes += 1
            return true
        }
        XCTAssertEqual(again, .idle)
        XCTAssertEqual(routes, 1)
    }

    func testConnectingToStableFailureTransitionFailsPendingSiriRequest() async {
        // Simulates the scene re-evaluating when phase flips while still
        // disconnected (voiceIntentRouteKey embeds phase).
        store.enqueue(PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "default"))
        let router = PendingVoiceIntentRouter(store: store)

        let waiting = await router.routePending(connection: connecting()) { _ in
            XCTFail("Still connecting — keep waiting")
            return true
        }
        XCTAssertEqual(waiting, .deferred)
        XCTAssertTrue(store.hasPendingIntent)

        let connection = stableFailure(.offline)
        let failed = await router.routePending(connection: connection) { _ in
            XCTFail("Stable failure must not open Voice")
            return true
        }
        XCTAssertEqual(
            failed,
            .failed(message: PendingVoiceLaunchPolicy.stableFailureMessage(for: connection))
        )
        XCTAssertFalse(store.hasPendingIntent)
    }

    func testDeletedProfileStyleHandlerSuccessConsumesWithoutRetryLoop() async {
        store.enqueue(
            PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "deleted-profile")
        )
        let router = PendingVoiceIntentRouter(store: store)

        var calls = 0
        let first = await router.routePending(connection: connected()) { intent in
            calls += 1
            XCTAssertEqual(intent.profile, "deleted-profile")
            return true
        }
        XCTAssertEqual(first, .routed)
        XCTAssertFalse(store.hasPendingIntent)

        let second = await router.routePending(connection: connected()) { _ in
            calls += 1
            return true
        }
        XCTAssertEqual(second, .idle)
        XCTAssertEqual(calls, 1)
    }

    // MARK: - App Intent foreground-mode compatibility

    func testStartVoiceConversationIntentDeclaresForegroundFirstExecution() {
        XCTAssertTrue(StartVoiceConversationIntent.openAppWhenRun)

        if #available(iOS 26.0, *) {
            XCTAssertEqual(
                StartVoiceConversationIntent.supportedModes,
                .foreground(.immediate)
            )
        }
    }
}
