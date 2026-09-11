//
//  PendingVoiceIntentLifecycleTests.swift
//  Conduit
//
//  Siri pending-launch lifecycle with ownership claims: exactly-once routing,
//  lifecycle-driven stable failure, authoritative deadline expiry, and no
//  stale async completion can mutate a later request.
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

    // MARK: - Factory

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
        XCTAssertEqual(intent.externalLaunchDeadline, now.addingTimeInterval(30))
        XCTAssertNotNil(intent.externalLaunchElapsedDeadline)
    }

    func testSiriFactoryTrimsAndDropsBlankProfiles() {
        XCTAssertNil(PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: nil).profile)
        XCTAssertNil(PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "   \n\t ").profile)
        XCTAssertEqual(PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "  work \n").profile, "work")
    }

    func testComposerLaunchHasNoExternalDeadline() {
        let intent = PendingVoiceIntent(
            profile: "default",
            startsFreshConversation: false,
            source: .composer
        )
        XCTAssertNil(intent.externalLaunchDeadline)
        XCTAssertNil(intent.externalLaunchElapsedDeadline)
        XCTAssertEqual(
            PendingVoiceLaunchPolicy.readiness(for: intent, connection: stableFailure(), now: .distantFuture),
            .waiting
        )
    }

    // MARK: - Connection phase / AppState provenance

    func testSnapshotPhasePrefersConnectingOverPriorFailureEvidence() {
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

    func testAppStateSnapshotMapsClassifiedFailureAndLoginRequiredPresentation() {
        let suite = "PendingVoiceIntentLifecycleTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Failed to create test UserDefaults suite")
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)

        appState.isConnected = false
        appState.isConnecting = false
        appState.lastConnectionFailure = nil
        appState.pendingLoginFailure = nil
        XCTAssertEqual(appState.voiceLaunchConnectionSnapshot().phase, .inconclusive)

        appState.isConnecting = true
        XCTAssertEqual(appState.voiceLaunchConnectionSnapshot().phase, .connecting)

        appState.isConnecting = false
        appState.lastConnectionFailure = .connectionRefused
        XCTAssertEqual(appState.voiceLaunchConnectionSnapshot().classifiedFailure, .connectionRefused)

        // Typed login-required presentation is fallback evidence.
        appState.lastConnectionFailure = nil
        appState.pendingLoginFailure = .presenting(.loginRequired)
        let loginRequired = appState.voiceLaunchConnectionSnapshot()
        XCTAssertEqual(loginRequired.phase, .stableFailure)
        XCTAssertEqual(loginRequired.classifiedFailure, .loginRequired)

        // Hand-authored notice is NOT login-required evidence.
        appState.pendingLoginFailure = .notice(title: "Something else", message: "")
        XCTAssertEqual(appState.voiceLaunchConnectionSnapshot().phase, .inconclusive)
        XCTAssertNil(appState.voiceLaunchConnectionSnapshot().classifiedFailure)
    }

    // MARK: - Readiness

    func testConnectedSiriLaunchIsReady() {
        let now = Date()
        let intent = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: nil, now: now)
        XCTAssertEqual(PendingVoiceLaunchPolicy.readiness(for: intent, connection: connected(), now: now), .ready)
    }

    func testSiriLaunchWaitsWhileActivelyConnecting() {
        let now = Date()
        let intent = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: nil, now: now)
        XCTAssertEqual(
            PendingVoiceLaunchPolicy.readiness(for: intent, connection: connecting(), now: now.addingTimeInterval(1)),
            .waiting
        )
    }

    func testSiriLaunchWaitsDuringColdBootstrapWithoutFailureEvidence() {
        let now = Date()
        let intent = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: nil, now: now)
        XCTAssertEqual(
            PendingVoiceLaunchPolicy.readiness(for: intent, connection: inconclusiveBootstrap(), now: now.addingTimeInterval(1)),
            .waiting
        )
    }

    func testKnownStableConnectionFailureFailsSiriBeforeDeadline() {
        let now = Date()
        let intent = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: nil, now: now, budget: 30)
        let connection = stableFailure(.unreachable)
        let message = PendingVoiceLaunchPolicy.stableFailureMessage(for: connection)

        XCTAssertEqual(
            PendingVoiceLaunchPolicy.readiness(for: intent, connection: connection, now: now.addingTimeInterval(2)),
            .failed(message: message)
        )
        XCTAssertTrue(message.contains(ConnectionFailure.unreachable.userMessage))
        XCTAssertNotEqual(message, PendingVoiceLaunchPolicy.disconnectedFailureMessage)
    }

    func testStableLoginRequiredFailureUsesClassifiedCopy() {
        let now = Date()
        let intent = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: nil, now: now)
        let connection = stableFailure(.loginRequired)
        let message = PendingVoiceLaunchPolicy.stableFailureMessage(for: connection)
        XCTAssertEqual(
            PendingVoiceLaunchPolicy.readiness(for: intent, connection: connection, now: now),
            .failed(message: message)
        )
        XCTAssertTrue(message.contains(ConnectionFailure.loginRequired.userTitle))
    }

    func testExpiredSiriLaunchFailsAndNeverWaitsForReconnect() {
        let now = Date()
        let intent = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: nil, now: now, budget: 30)
        XCTAssertEqual(
            PendingVoiceLaunchPolicy.readiness(for: intent, connection: inconclusiveBootstrap(), now: now.addingTimeInterval(31)),
            .failed(message: PendingVoiceLaunchPolicy.expiredFailureMessage)
        )
    }

    func testExpiryAtExactBoundaryCannotReturnToWaiting() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let intent = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: nil, now: now, budget: 30)
        let boundary = intent.externalLaunchDeadline!
        XCTAssertEqual(
            PendingVoiceLaunchPolicy.readiness(for: intent, connection: inconclusiveBootstrap(), now: boundary),
            .failed(message: PendingVoiceLaunchPolicy.expiredFailureMessage)
        )
    }

    func testExpiredSiriLaunchFailsEvenIfConnectionReturnsTooLate() {
        let now = Date()
        let intent = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: nil, now: now, budget: 30)
        XCTAssertEqual(
            PendingVoiceLaunchPolicy.readiness(for: intent, connection: connected(), now: now.addingTimeInterval(5 * 60)),
            .failed(message: PendingVoiceLaunchPolicy.expiredFailureMessage)
        )
    }

    // MARK: - Router exactly-once / connecting / stable failure

    func testConnectedRouteConsumesExactlyOnceAndDoesNotReenqueue() async {
        store.enqueue(PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "default"))

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
        XCTAssertEqual(handled.map(\.profile), ["default"])
    }

    func testConnectingSiriRequestRemainsPendingWithoutRevisionBump() async {
        store.enqueue(PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "default"))
        let afterEnqueue = store.revision
        let router = PendingVoiceIntentRouter(store: store)

        let outcome = await router.routePending(connection: connecting()) { _ in
            XCTFail("Connecting must not invoke the voice handler")
            return true
        }

        XCTAssertEqual(outcome, .deferred)
        XCTAssertTrue(store.hasPendingIntent)
        XCTAssertEqual(store.revision, afterEnqueue)
    }

    func testStableFailureConsumesSiriRequestImmediatelyBeforeDeadline() async {
        store.enqueue(PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "default", budget: 30))
        let router = PendingVoiceIntentRouter(store: store)
        let connection = stableFailure(.hostNotFound)
        var handlerCalls = 0

        let outcome = await router.routePending(connection: connection) { _ in
            handlerCalls += 1
            return true
        }

        XCTAssertEqual(outcome, .failed(message: PendingVoiceLaunchPolicy.stableFailureMessage(for: connection)))
        XCTAssertFalse(store.hasPendingIntent)
        XCTAssertEqual(handlerCalls, 0)
    }

    func testReconnectAfterStableFailureDoesNotLaunchStaleSiriVoice() async {
        store.enqueue(PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: nil, budget: 30))
        let router = PendingVoiceIntentRouter(store: store)

        let failure = await router.routePending(connection: stableFailure(.timedOut)) { _ in
            XCTFail("Stable failure must not invoke the voice handler")
            return true
        }
        XCTAssertEqual(
            failure,
            .failed(message: PendingVoiceLaunchPolicy.stableFailureMessage(for: stableFailure(.timedOut)))
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

    func testLaterReconnectAfterExpiryCannotLaunchStaleRequest() async {
        let enqueuedAt = Date(timeIntervalSinceNow: -120)
        store.enqueue(PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: nil, now: enqueuedAt, budget: 30))
        let router = PendingVoiceIntentRouter(store: store)

        let expired = await router.routePending(connection: inconclusiveBootstrap(), now: Date()) { _ in
            XCTFail("Expired launch must not invoke the voice handler")
            return true
        }
        XCTAssertEqual(expired, .failed(message: PendingVoiceLaunchPolicy.expiredFailureMessage))

        var handled = 0
        let afterReconnect = await router.routePending(connection: connected()) { _ in
            handled += 1
            return true
        }
        XCTAssertEqual(afterReconnect, .idle)
        XCTAssertEqual(handled, 0)
    }

    func testSiriHandlerFailureIsTerminalAndDoesNotReenqueue() async {
        store.enqueue(PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "default"))
        let router = PendingVoiceIntentRouter(store: store)

        let outcome = await router.routePending(connection: connected()) { _ in false }

        XCTAssertEqual(outcome, .failed(message: PendingVoiceLaunchPolicy.disconnectedFailureMessage))
        XCTAssertFalse(store.hasPendingIntent)
    }

    // MARK: - Ownership / supersede fencing

    func testClearWhileHandlerSuspendedCannotResurrectOrPublishFailure() async {
        store.enqueue(PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "default"))
        let router = PendingVoiceIntentRouter(store: store)

        let gate = LaunchHandlerGate()
        async let outcome = router.routePending(connection: connected()) { _ in
            await gate.markStarted()
            await gate.waitUntilOpen()
            return true
        }
        await gate.waitUntilStarted()
        store.clear()
        await gate.open()
        let result = await outcome

        XCTAssertEqual(result, .superseded)
        XCTAssertFalse(store.hasPendingIntent)
    }

    func testClearWhileHandlerSuspendedDiscardsHandlerFalseFailure() async {
        store.enqueue(PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "default"))
        let router = PendingVoiceIntentRouter(store: store)

        let gate = LaunchHandlerGate()
        async let outcome = router.routePending(connection: connected()) { _ in
            await gate.markStarted()
            await gate.waitUntilOpen()
            return false
        }
        await gate.waitUntilStarted()
        store.clear()
        await gate.open()
        let result = await outcome

        // Stale completion must not surface a Siri failure for a cleared request.
        XCTAssertEqual(result, .superseded)
        XCTAssertFalse(store.hasPendingIntent)
    }

    func testEnqueueBDuringHandlerASuspensionPreventsAFromTouchingB() async {
        let a = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "A")
        store.enqueue(a)
        let router = PendingVoiceIntentRouter(store: store)

        let gate = LaunchHandlerGate()
        async let outcome = router.routePending(connection: connected()) { intent in
            XCTAssertEqual(intent.profile, "A")
            await gate.markStarted()
            await gate.waitUntilOpen()
            return false
        }
        await gate.waitUntilStarted()
        let b = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "B")
        store.enqueue(b)
        await gate.open()
        let result = await outcome

        XCTAssertEqual(result, .superseded)
        // B still owns the slot — A must not requeue or fail over it.
        XCTAssertTrue(store.hasPendingIntent)
        XCTAssertEqual(store.pendingProfile, "B")
    }

    func testWaiterForACannotAffectReplacementB() {
        let a = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "A")
        store.enqueue(a)
        guard let claimA = store.peekClaim() else {
            return XCTFail("expected claim A")
        }
        _ = store.takeClaim()
        let b = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "B")
        store.enqueue(b)

        // A's waiter wakes: must no-op.
        XCTAssertNil(store.expireClaimIfCurrent(claimA))
        XCTAssertEqual(store.pendingProfile, "B")
    }

    func testConsumeAWhileWaiterSleepsMakesOldWaiterNoop() {
        let a = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "A")
        store.enqueue(a)
        guard let claimA = store.peekClaim() else {
            return XCTFail("expected claim A")
        }
        // Simulate successful route consuming A.
        guard let taken = store.takeClaim() else {
            return XCTFail("expected take")
        }
        XCTAssertEqual(taken.generation, claimA.generation)
        XCTAssertNil(store.takeClaim())

        // Old waiter expire on a already-taken (consumed) claim: no pending
        // intent remains, so expiry is a no-op.
        XCTAssertNil(store.expireClaimIfCurrent(claimA))
        XCTAssertFalse(store.hasPendingIntent)
    }

    func testClearInvalidatesClaimSoExpiredWaiterCannotResurrect() {
        let a = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "A")
        store.enqueue(a)
        guard let claimA = store.peekClaim() else {
            return XCTFail("expected claim A")
        }
        store.clear()
        XCTAssertNil(store.expireClaimIfCurrent(claimA))
        XCTAssertFalse(store.hasPendingIntent)
    }

    // MARK: - Authoritative store expiry

    func testAuthoritativeExpiryAlwaysConsumesTheRequest() {
        store.enqueue(PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "default"))
        guard let claim = store.peekClaim() else {
            return XCTFail("expected claim")
        }
        let expired = store.expireClaimIfCurrent(claim)
        XCTAssertEqual(expired?.profile, "default")
        XCTAssertFalse(store.hasPendingIntent)
        // Second expire is a no-op — request is gone, no new timer needed.
        XCTAssertNil(store.expireClaimIfCurrent(claim))
    }

    func testDeferralDoesNotExtendOriginalLaunchBudget() async {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let intent = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "default", now: now, budget: 30)
        let originalDeadline = intent.externalLaunchDeadline
        let originalElapsed = intent.externalLaunchElapsedDeadline
        store.enqueue(intent)

        let router = PendingVoiceIntentRouter(store: store)
        _ = await router.routePending(connection: connecting(), now: now.addingTimeInterval(5)) { _ in
            XCTFail("Waiting must not call the handler")
            return true
        }

        XCTAssertEqual(store.pendingExternalLaunchDeadline, originalDeadline)
        XCTAssertEqual(store.pendingProfile, "default")
        // Elapsed deadline is immutable metadata on the intent.
        let claim = store.peekClaim()
        XCTAssertEqual(claim?.intent.externalLaunchElapsedDeadline, originalElapsed)

        let expired = await router.routePending(connection: connecting(), now: now.addingTimeInterval(30)) { _ in
            XCTFail("Expired at boundary")
            return true
        }
        XCTAssertEqual(expired, .failed(message: PendingVoiceLaunchPolicy.expiredFailureMessage))
        XCTAssertFalse(store.hasPendingIntent)
    }

    // MARK: - Supersede / clear / double-route

    func testNewerSiriRequestSupersedesOlderPendingRequest() async {
        store.enqueue(PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "old"))
        store.enqueue(PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "new"))

        let router = PendingVoiceIntentRouter(store: store)
        var handled: [PendingVoiceIntent] = []
        let outcome = await router.routePending(connection: connected()) { intent in
            handled.append(intent)
            return true
        }

        XCTAssertEqual(outcome, .routed)
        XCTAssertEqual(handled.map(\.profile), ["new"])
        XCTAssertFalse(store.hasPendingIntent)
    }

    func testClearCannotLaterResurrectTheRequest() async {
        store.enqueue(PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "default"))
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
        store.enqueue(PendingVoiceIntent(profile: "a", startsFreshConversation: true, source: .siri))
        let afterEnqueue = store.revision
        store.enqueue(PendingVoiceIntent(profile: "b", startsFreshConversation: true, source: .siri))
        let afterSupersede = store.revision
        store.clear()
        let afterClear = store.revision

        XCTAssertGreaterThan(afterEnqueue, initial)
        XCTAssertGreaterThan(afterSupersede, afterEnqueue)
        XCTAssertGreaterThan(afterClear, afterSupersede)
    }

    func testDeferredRequeueDoesNotClobberNewerPendingRequest() {
        let older = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "old")
        store.enqueue(older)
        guard let claim = store.takeClaim() else {
            return XCTFail("expected take")
        }
        store.enqueue(PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "new"))
        XCTAssertFalse(store.requeueDeferred(claim))
        XCTAssertEqual(store.pendingProfile, "new")
    }

    func testTwoLaunchAttemptsCannotCauseDuplicateConsumption() async {
        store.enqueue(PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "default"))
        let router = PendingVoiceIntentRouter(store: store)

        async let first = router.routePending(connection: connected()) { _ in true }
        async let second = router.routePending(connection: connected()) { _ in true }
        let outcomes = await [first, second]

        XCTAssertEqual(outcomes.filter { $0 == .routed }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .idle }.count, 1)
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

        let again = await router.routePending(connection: connected()) { _ in
            routes += 1
            return true
        }
        XCTAssertEqual(again, .idle)
        XCTAssertEqual(routes, 1)
    }

    func testConnectingToStableFailureTransitionFailsPendingSiriRequest() async {
        store.enqueue(PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "default"))
        let router = PendingVoiceIntentRouter(store: store)

        let waiting = await router.routePending(connection: connecting()) { _ in
            XCTFail("Still connecting")
            return true
        }
        XCTAssertEqual(waiting, .deferred)

        let connection = stableFailure(.offline)
        let failed = await router.routePending(connection: connection) { _ in
            XCTFail("Stable failure must not open Voice")
            return true
        }
        XCTAssertEqual(failed, .failed(message: PendingVoiceLaunchPolicy.stableFailureMessage(for: connection)))
        XCTAssertFalse(store.hasPendingIntent)
    }

    /// `openVoiceConversation` surfaces an error and returns true when the
    /// requested profile cannot be activated — a terminal consume, not a loop.
    func testUnusableProfileStyleHandlerSuccessConsumesWithoutRetryLoop() async {
        store.enqueue(PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "deleted-profile"))
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

    // MARK: - App Intent foreground-mode

    func testStartVoiceConversationIntentDeclaresForegroundFirstExecution() {
        XCTAssertTrue(StartVoiceConversationIntent.openAppWhenRun)
        if #available(iOS 26.0, *) {
            XCTAssertEqual(StartVoiceConversationIntent.supportedModes, .foreground(.immediate))
        }
    }
}

// MARK: - Continuation gate (no timing sleeps)

/// Deterministic suspension gate for handler-ownership tests. The handler
/// signals `markStarted()` then parks on `waitUntilOpen()`; the test mutates
/// the store before `open()`.
actor LaunchHandlerGate {
    private var isOpen = false
    private var isStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        isStarted = true
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilStarted() async {
        if isStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilOpen() async {
        if isOpen { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }
}
