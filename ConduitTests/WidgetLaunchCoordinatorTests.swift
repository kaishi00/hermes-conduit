import XCTest
@testable import Conduit

@MainActor
final class WidgetLaunchCoordinatorTests: XCTestCase {
    func testDuplicateInFlightDeliveryRunsOnceButLaterTapRunsAgain() async throws {
        let link = try XCTUnwrap(WidgetLaunchLink(action: .newChat, workspace: workspace, reference: nil))
        let prepareGate = AsyncLaunchGate()
        let firstPrepareEntered = AsyncLaunchGate()
        let secondPrepareEntered = AsyncLaunchGate()
        let firstFinish = AsyncLaunchGate()
        let secondFinish = AsyncLaunchGate()
        var createCount = 0
        var prepareCount = 0
        var finishCount = 0
        let coordinator = WidgetLaunchCoordinator(
            now: { .zero },
            prepare: { _, _ in
                prepareCount += 1
                if prepareCount == 1 { await firstPrepareEntered.signal() }
                if prepareCount == 2 { await secondPrepareEntered.signal() }
                return .handled
            },
            perform: { _, _ in
                createCount += 1
                if createCount == 1 { await prepareGate.wait() }
                return .handled
            },
            finish: { _ in
                finishCount += 1
                if finishCount == 1 { Task { await firstFinish.signal() } }
                if finishCount == 2 { Task { await secondFinish.signal() } }
            }
        )

        coordinator.receive(link)
        await firstPrepareEntered.wait()
        coordinator.receive(link)
        await prepareGate.signal()
        await firstFinish.wait()
        XCTAssertEqual(createCount, 1, "duplicate delivery during the in-flight action must coalesce")

        coordinator.receive(link)
        await secondPrepareEntered.wait()
        await secondFinish.wait()
        XCTAssertEqual(createCount, 2, "a later deliberate tap must create another conversation")
    }

    func testSupersededSuspendedPreparationCannotPerform() async throws {
        let first = try XCTUnwrap(WidgetLaunchLink(action: .newChat, workspace: workspace, reference: nil))
        let second = try XCTUnwrap(WidgetLaunchLink(action: .talk, workspace: workspace, reference: nil))
        let prepareGate = AsyncLaunchGate()
        let entered = AsyncLaunchGate()
        let stalePreparationResumed = AsyncLaunchGate()
        let secondFinished = AsyncLaunchGate()
        var performed: [WidgetLaunchAction] = []
        let coordinator = WidgetLaunchCoordinator(
            now: { .zero },
            prepare: { link, _ in
                if link == first {
                    await entered.signal()
                    await prepareGate.wait()
                    await stalePreparationResumed.signal()
                }
                return .handled
            },
            perform: { link, _ in
                performed.append(link.action)
                return .handled
            },
            finish: { outcome in
                if case .handled = outcome { Task { await secondFinished.signal() } }
            }
        )

        coordinator.receive(first)
        await entered.wait()
        coordinator.receive(second)
        await secondFinished.wait()
        await prepareGate.signal()
        await stalePreparationResumed.wait()

        XCTAssertEqual(performed, [.talk], "stale preparation must not perform after a newer explicit route")
    }

    func testDeadlineExpiresAtExactlyThirtySecondsAndFinishesOnce() async throws {
        let link = try XCTUnwrap(WidgetLaunchLink(action: .newChat, workspace: workspace, reference: nil))
        let finished = AsyncLaunchGate()
        let firstDeferred = AsyncLaunchGate()
        var now: Duration = .zero
        var prepareCount = 0
        var outcomes: [WidgetLaunchOutcome] = []
        let coordinator = WidgetLaunchCoordinator(
            now: { now },
            prepare: { _, _ in
                prepareCount += 1
                if prepareCount == 1 { await firstDeferred.signal() }
                return .deferred
            },
            perform: { _, _ in XCTFail("an unprepared request must not perform"); return .handled },
            finish: { outcome in
                outcomes.append(outcome)
                Task { await finished.signal() }
            }
        )

        coordinator.receive(link)
        await firstDeferred.wait()
        XCTAssertEqual(prepareCount, 1)
        now = .seconds(30)
        coordinator.readinessChanged()
        await finished.wait()

        XCTAssertEqual(outcomes.count, 1)
        guard case .failed = try XCTUnwrap(outcomes.first) else {
            return XCTFail("the request must finish with terminal expiry feedback")
        }
        XCTAssertEqual(prepareCount, 1, "deadline equality is expired and cannot retry")
    }

    func testDeferredReadinessRetriesOnlyCurrentRequest() async throws {
        let link = try XCTUnwrap(WidgetLaunchLink(action: .resume, workspace: workspace, reference: reference))
        let firstDeferred = AsyncLaunchGate()
        let finished = AsyncLaunchGate()
        var prepareCount = 0
        var performCount = 0
        let coordinator = WidgetLaunchCoordinator(
            now: { .zero },
            prepare: { _, _ in
                prepareCount += 1
                if prepareCount == 1 {
                    await firstDeferred.signal()
                    return .deferred
                }
                return .handled
            },
            perform: { _, _ in performCount += 1; return .handled },
            finish: { _ in Task { await finished.signal() } }
        )

        coordinator.receive(link)
        await firstDeferred.wait()
        coordinator.readinessChanged()
        await finished.wait()

        XCTAssertEqual(prepareCount, 2)
        XCTAssertEqual(performCount, 1)
    }

    func testDeferredSameLinkRetapStartsFreshRequestAndDeadline() async throws {
        let link = try XCTUnwrap(WidgetLaunchLink(action: .newChat, workspace: workspace, reference: nil))
        let firstDeferred = AsyncLaunchGate()
        let secondDeferred = AsyncLaunchGate()
        let finished = AsyncLaunchGate()
        var now: Duration = .zero
        var prepareCount = 0
        var finalOutcome: WidgetLaunchOutcome?
        let coordinator = WidgetLaunchCoordinator(
            now: { now },
            prepare: { _, _ in
                prepareCount += 1
                if prepareCount == 1 {
                    await firstDeferred.signal()
                    return .deferred
                }
                await secondDeferred.signal()
                return .deferred
            },
            perform: { _, _ in XCTFail("deferred preparation must not perform"); return .handled },
            finish: { outcome in
                finalOutcome = outcome
                Task { await finished.signal() }
            }
        )

        coordinator.receive(link)
        await firstDeferred.wait()
        now = .seconds(20)
        coordinator.receive(link)
        await secondDeferred.wait()
        now = .seconds(49)
        coordinator.readinessChanged()
        XCTAssertTrue(coordinator.hasPendingRequest, "the retap at t=20 must move the expiry to t=50")
        now = .seconds(50)
        coordinator.readinessChanged()
        await finished.wait()

        XCTAssertEqual(prepareCount, 2)
        guard case .failed = finalOutcome else { return XCTFail("the refreshed request expires exactly 30 seconds after the retap") }
    }

    func testDisplayedWorkspaceWinsOverCurrentWorkspace() async throws {
        let displayedWorkspace = workspace
        let currentWorkspace = WidgetWorkspaceID(
            dashboardID: UUID(uuidString: "00000000-0000-0000-0000-000000000456")!,
            profile: "work"
        )
        let link = try XCTUnwrap(WidgetLaunchLink(action: .resume, workspace: displayedWorkspace, reference: reference))
        let finished = AsyncLaunchGate()
        var openedWorkspace: WidgetWorkspaceID?
        let coordinator = WidgetLaunchCoordinator(
            now: { .zero },
            prepare: { request, _ in
                XCTAssertEqual(request.workspace, displayedWorkspace)
                XCTAssertNotEqual(request.workspace, currentWorkspace)
                return .handled
            },
            perform: { request, _ in
                openedWorkspace = request.workspace
                return .handled
            },
            finish: { _ in Task { await finished.signal() } }
        )

        coordinator.receive(link)
        await finished.wait()

        XCTAssertEqual(openedWorkspace, displayedWorkspace)
    }

    func testRemovedTargetNeverOpensCurrentDashboard() async throws {
        let removedWorkspace = workspace
        let currentWorkspace = WidgetWorkspaceID(
            dashboardID: UUID(uuidString: "00000000-0000-0000-0000-000000000456")!,
            profile: "default"
        )
        let link = try XCTUnwrap(WidgetLaunchLink(action: .resume, workspace: removedWorkspace, reference: reference))
        let finished = AsyncLaunchGate()
        var openCount = 0
        let coordinator = WidgetLaunchCoordinator(
            now: { .zero },
            prepare: { request, _ in
                XCTAssertEqual(request.workspace, removedWorkspace)
                return request.workspace == currentWorkspace ? .handled : .failed("removed")
            },
            perform: { _, _ in openCount += 1; return .handled },
            finish: { _ in Task { await finished.signal() } }
        )

        coordinator.receive(link)
        await finished.wait()

        XCTAssertEqual(openCount, 0)
    }

    func testTalkLeaseSurvivesRouteCompletionUntilCaptureStarts() async throws {
        let link = try XCTUnwrap(WidgetLaunchLink(action: .talk, workspace: workspace, reference: nil))
        let finished = AsyncLaunchGate()
        var authorization: WidgetInitialCaptureAuthorization?
        let coordinator = WidgetLaunchCoordinator(
            now: { .zero },
            prepare: { _, _ in .handled },
            perform: { _, lease in
                authorization = lease.initialCaptureAuthorization()
                return .handled
            },
            finish: { _ in Task { await finished.signal() } }
        )

        coordinator.receive(link)
        await finished.wait()

        XCTAssertFalse(coordinator.hasPendingRequest)
        XCTAssertTrue(try XCTUnwrap(authorization).mayStartCapture)
        authorization?.captureDidStart()
        XCTAssertTrue(try XCTUnwrap(authorization).mayStartCapture, "the established call is independent of the launch lease")
    }

    func testHandedOffTalkExpiresWithFeedbackIfCaptureHasNotStarted() async throws {
        let link = try XCTUnwrap(WidgetLaunchLink(action: .talk, workspace: workspace, reference: nil))
        let routed = AsyncLaunchGate()
        let expired = AsyncLaunchGate()
        var now: Duration = .zero
        var authorization: WidgetInitialCaptureAuthorization?
        var outcomes: [WidgetLaunchOutcome] = []
        let coordinator = WidgetLaunchCoordinator(
            now: { now },
            prepare: { _, _ in .handled },
            perform: { _, lease in
                authorization = lease.initialCaptureAuthorization()
                return .handled
            },
            finish: { outcome in
                outcomes.append(outcome)
                Task {
                    if outcomes.count == 1 { await routed.signal() }
                    else { await expired.signal() }
                }
            }
        )

        coordinator.receive(link)
        await routed.wait()
        XCTAssertTrue(try XCTUnwrap(authorization).mayStartCapture)
        now = .seconds(30)
        coordinator.readinessChanged()
        await expired.wait()

        XCTAssertFalse(try XCTUnwrap(authorization).mayStartCapture)
        XCTAssertEqual(outcomes.count, 2)
        guard case .failed = try XCTUnwrap(outcomes.last) else {
            return XCTFail("an uncaptured handed-off Talk must surface terminal expiry feedback")
        }
    }

    func testNewRouteRevokesTalkLeaseBeforeInitialCapture() async throws {
        let talk = try XCTUnwrap(WidgetLaunchLink(action: .talk, workspace: workspace, reference: nil))
        let next = try XCTUnwrap(WidgetLaunchLink(action: .open, workspace: nil, reference: nil))
        let talkFinished = AsyncLaunchGate()
        let openFinished = AsyncLaunchGate()
        var authorization: WidgetInitialCaptureAuthorization?
        var finishCount = 0
        let coordinator = WidgetLaunchCoordinator(
            now: { .zero },
            prepare: { _, _ in .handled },
            perform: { link, lease in
                if link == talk { authorization = lease.initialCaptureAuthorization() }
                return .handled
            },
            finish: { _ in
                finishCount += 1
                if finishCount == 1 { Task { await talkFinished.signal() } }
                if finishCount == 2 { Task { await openFinished.signal() } }
            }
        )

        coordinator.receive(talk)
        await talkFinished.wait()
        coordinator.receive(next)
        await openFinished.wait()

        XCTAssertFalse(try XCTUnwrap(authorization).mayStartCapture)
    }

    func testAuthCancellationIsTerminal() async throws {
        let link = try XCTUnwrap(WidgetLaunchLink(action: .newChat, workspace: workspace, reference: nil))
        let finished = AsyncLaunchGate()
        var outcomes: [WidgetLaunchOutcome] = []
        var performCount = 0
        let coordinator = WidgetLaunchCoordinator(
            now: { .zero },
            prepare: { _, _ in .failed("authentication cancelled") },
            perform: { _, _ in performCount += 1; return .handled },
            finish: { outcome in outcomes.append(outcome); Task { await finished.signal() } }
        )

        coordinator.receive(link)
        await finished.wait()
        coordinator.readinessChanged()

        XCTAssertEqual(performCount, 0)
        XCTAssertEqual(outcomes, [.failed("authentication cancelled")])
    }

    func testStableOfflineFailureDoesNotReplayAfterReconnect() async throws {
        let link = try XCTUnwrap(WidgetLaunchLink(action: .resume, workspace: workspace, reference: reference))
        let finished = AsyncLaunchGate()
        var prepareCount = 0
        var outcomes: [WidgetLaunchOutcome] = []
        let coordinator = WidgetLaunchCoordinator(
            now: { .zero },
            prepare: { _, _ in
                prepareCount += 1
                return .failed("offline")
            },
            perform: { _, _ in XCTFail("offline must be terminal before open"); return .handled },
            finish: { outcome in outcomes.append(outcome); Task { await finished.signal() } }
        )

        coordinator.receive(link)
        await finished.wait()
        coordinator.readinessChanged()

        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(outcomes, [.failed("offline")])
    }

    private var workspace: WidgetWorkspaceID {
        WidgetWorkspaceID(dashboardID: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!, profile: "default")
    }

    private var reference: WidgetConversationReference {
        WidgetConversationReference(kind: .dashboard, scopeProfile: "default", botName: nil, botLabel: nil, sessionID: "session-1", isUnverified: false)
    }
}

@MainActor
private final class AsyncLaunchGate {
    private var entered = false
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []
    private var parked: CheckedContinuation<Void, Never>?

    func signal() async {
        entered = true
        let waiters = enterWaiters
        enterWaiters.removeAll()
        waiters.forEach { $0.resume() }
        parked?.resume()
        parked = nil
    }

    func wait() async {
        if entered {
            entered = false
            return
        }
        await withCheckedContinuation { parked = $0 }
    }

    func waitForSignal() async {
        if entered {
            entered = false
            return
        }
        await withCheckedContinuation { enterWaiters.append($0) }
    }
}
