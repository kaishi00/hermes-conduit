//
//  PendingVoiceIntentLifecycleTests.swift
//  Conduit
//
//  Siri / external voice-launch lifecycle: exactly-once routing, profile
//  preservation, and terminal failure so a stale Siri request can never open
//  Voice after an unrelated reconnect.
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
                isConnected: false,
                now: .distantFuture
            ),
            .waiting
        )
    }

    // MARK: - Readiness / disconnected lifecycle

    func testConnectedSiriLaunchIsReady() {
        let now = Date()
        let intent = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: nil, now: now)
        XCTAssertEqual(
            PendingVoiceLaunchPolicy.readiness(for: intent, isConnected: true, now: now),
            .ready
        )
    }

    func testSiriLaunchWithinWindowWaitsWhileDisconnected() {
        let now = Date()
        let intent = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: nil, now: now, budget: 30)
        XCTAssertEqual(
            PendingVoiceLaunchPolicy.readiness(
                for: intent,
                isConnected: false,
                now: now.addingTimeInterval(1)
            ),
            .waiting
        )
    }

    func testExpiredSiriLaunchFailsAndNeverWaitsForReconnect() {
        let now = Date()
        let intent = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: nil, now: now, budget: 30)
        let later = now.addingTimeInterval(31)
        XCTAssertEqual(
            PendingVoiceLaunchPolicy.readiness(for: intent, isConnected: false, now: later),
            .failed(message: PendingVoiceLaunchPolicy.expiredFailureMessage)
        )
    }

    func testExpiredSiriLaunchFailsEvenIfConnectionReturnsTooLate() {
        // Reconnect minutes later must not open Voice from an old Siri request.
        let now = Date()
        let intent = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: nil, now: now, budget: 30)
        let minutesLater = now.addingTimeInterval(5 * 60)
        XCTAssertEqual(
            PendingVoiceLaunchPolicy.readiness(for: intent, isConnected: true, now: minutesLater),
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
        let first = await router.routePending(isConnected: true) { intent in
            handled.append(intent)
            return true
        }
        XCTAssertEqual(first, .routed)
        XCTAssertFalse(store.hasPendingIntent)

        let second = await router.routePending(isConnected: true) { intent in
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

        let outcome = await router.routePending(isConnected: false) { _ in
            handlerCalls += 1
            return true
        }

        XCTAssertEqual(outcome, .deferred)
        XCTAssertTrue(store.hasPendingIntent)
        XCTAssertEqual(handlerCalls, 0)
        XCTAssertEqual(store.pendingSource, .siri)
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

        let outcome = await router.routePending(isConnected: false, now: Date()) { _ in
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

        let failure = await router.routePending(isConnected: false, now: Date()) { _ in
            XCTFail("Expired Siri launch must not invoke the voice handler")
            return true
        }
        XCTAssertEqual(
            failure,
            .failed(message: PendingVoiceLaunchPolicy.expiredFailureMessage)
        )

        // Hermes is healthy again — but the store is empty.
        var handled = 0
        let afterReconnect = await router.routePending(isConnected: true) { _ in
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

        let outcome = await router.routePending(isConnected: true) { _ in false }

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

        let outcome = await router.routePending(isConnected: true) { _ in false }

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
        let outcome = await router.routePending(isConnected: true) { intent in
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
        let outcome = await router.routePending(isConnected: true) { _ in
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

        let outcome = await router.routePending(isConnected: false) { _ in
            XCTFail("Waiting must not call the handler")
            return true
        }

        XCTAssertEqual(outcome, .deferred)
        XCTAssertTrue(store.hasPendingIntent)
        // A revision bump here would re-fire the scene's revision-keyed task
        // in a hot loop while Hermes is still connecting.
        XCTAssertEqual(store.revision, afterEnqueue)
    }

    func testDeferredRequeueDoesNotClobberNewerPendingRequest() {
        let older = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "old")
        let newer = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "new")

        // requeue is only valid when the slot is empty (the same request was
        // just taken). It must never overwrite a newer explicit enqueue.
        store.enqueue(newer)
        store.requeueAsDeferred(older)

        XCTAssertTrue(store.hasPendingIntent)
        XCTAssertEqual(store.pendingSource, .siri)
        // Slot still holds the newer request: requeue was a no-op.
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
        _ = await router.routePending(isConnected: false, now: now.addingTimeInterval(5)) { _ in
            XCTFail("Waiting must not call the handler")
            return true
        }
        _ = await router.routePending(isConnected: false, now: now.addingTimeInterval(10)) { _ in
            true
        }

        // Still the original 30s window from first enqueue — not slid forward.
        let expired = await router.routePending(
            isConnected: false,
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

        async let first = router.routePending(isConnected: true) { _ in true }
        async let second = router.routePending(isConnected: true) { _ in true }
        let outcomes = await [first, second]

        let routed = outcomes.filter { $0 == .routed }.count
        let idle = outcomes.filter { $0 == .idle }.count
        XCTAssertEqual(routed, 1)
        XCTAssertEqual(idle, 1)
        XCTAssertFalse(store.hasPendingIntent)
    }

    func testBootstrapOrderingKeepsSiriRequestUntilConnectedThenRoutesOnce() async {
        // Scene can observe the store before Hermes finishes cold bootstrap.
        store.enqueue(PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "default"))
        let router = PendingVoiceIntentRouter(store: store)

        // First lifecycle pass: not connected yet (still restoring).
        let waiting = await router.routePending(isConnected: false, now: Date()) { _ in
            XCTFail("Must wait for Hermes before opening Voice")
            return true
        }
        XCTAssertEqual(waiting, .deferred)
        XCTAssertTrue(store.hasPendingIntent)

        // Connection completes — one route, one consume.
        var routes = 0
        let connected = await router.routePending(isConnected: true) { _ in
            routes += 1
            return true
        }
        XCTAssertEqual(connected, .routed)
        XCTAssertEqual(routes, 1)
        XCTAssertFalse(store.hasPendingIntent)

        // A later scene pass cannot double-route.
        let again = await router.routePending(isConnected: true) { _ in
            routes += 1
            return true
        }
        XCTAssertEqual(again, .idle)
        XCTAssertEqual(routes, 1)
    }

    func testDeletedProfileStyleHandlerSuccessConsumesWithoutRetryLoop() async {
        // openVoiceConversation surfaces an error and returns true when the
        // requested profile cannot be activated — that is a terminal consume,
        // not a defer.
        store.enqueue(
            PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "deleted-profile")
        )
        let router = PendingVoiceIntentRouter(store: store)

        var calls = 0
        let first = await router.routePending(isConnected: true) { intent in
            calls += 1
            XCTAssertEqual(intent.profile, "deleted-profile")
            return true // handled (with errorMessage on AppState)
        }
        XCTAssertEqual(first, .routed)
        XCTAssertFalse(store.hasPendingIntent)

        let second = await router.routePending(isConnected: true) { _ in
            calls += 1
            return true
        }
        XCTAssertEqual(second, .idle)
        XCTAssertEqual(calls, 1)
    }

    // MARK: - App Intent foreground-mode compatibility

    func testStartVoiceConversationIntentDeclaresForegroundFirstExecution() {
        // Pre-iOS-26 contract: openAppWhenRun must stay true (boolean literal —
        // App Intents metadata rejects computed values).
        XCTAssertTrue(StartVoiceConversationIntent.openAppWhenRun)

        if #available(iOS 26.0, *) {
            XCTAssertEqual(
                StartVoiceConversationIntent.supportedModes,
                .foreground(.immediate)
            )
        }
    }
}
