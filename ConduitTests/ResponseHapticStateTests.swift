import XCTest
@testable import Conduit

final class ResponseHapticStateTests: XCTestCase {
    func testVisibleAnswerStartsOncePerTurn() {
        var state = ResponseHapticState()

        XCTAssertEqual(state.registerActivity(playsStart: false), [])
        XCTAssertEqual(state.registerActivity(playsStart: true), [.responseStarted])
        XCTAssertEqual(state.registerActivity(playsStart: true), [])
        XCTAssertTrue(state.isActive)
        XCTAssertTrue(state.startPlayed)
    }

    func testToolFeedbackIsDebouncedAndSubordinateToResponseStart() {
        var state = ResponseHapticState()
        let first = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(state.registerTool(at: first), [.toolStarted])
        XCTAssertEqual(state.registerTool(at: first.addingTimeInterval(0.249)), [])
        XCTAssertEqual(
            state.registerTool(at: first.addingTimeInterval(0.25)),
            [.toolStarted]
        )
        XCTAssertEqual(state.registerActivity(playsStart: true), [.responseStarted])
    }

    func testLatestConclusionTokenOwnsCompletion() throws {
        var state = ResponseHapticState()
        _ = state.registerActivity(playsStart: true)
        let stale = try XCTUnwrap(state.scheduleConclusion(sessionID: "session"))
        let current = try XCTUnwrap(state.scheduleConclusion(sessionID: "session"))

        XCTAssertNil(state.finishConclusion(stale))
        XCTAssertEqual(state.pendingConclusion, current)
        XCTAssertEqual(state.finishConclusion(current), .responseConcluded)
        XCTAssertFalse(state.isActive)
        XCTAssertFalse(state.startPlayed)
    }

    func testNewActivityInvalidatesPendingConclusion() throws {
        var state = ResponseHapticState()
        _ = state.registerActivity(playsStart: true)
        let pending = try XCTUnwrap(state.scheduleConclusion(sessionID: "session"))

        XCTAssertEqual(state.registerActivity(playsStart: false), [])

        XCTAssertNil(state.pendingConclusion)
        XCTAssertNil(state.finishConclusion(pending))
        XCTAssertTrue(state.isActive)
    }

    func testBackgroundSuppressesFeedbackAndClearsTurn() throws {
        var state = ResponseHapticState()
        _ = state.registerActivity(playsStart: true)
        let stale = try XCTUnwrap(state.scheduleConclusion(sessionID: "session"))

        XCTAssertEqual(state.setForegroundActive(false), .cancelPattern)
        XCTAssertFalse(state.isActive)
        XCTAssertFalse(state.startPlayed)
        XCTAssertNil(state.pendingConclusion)
        XCTAssertNil(state.finishConclusion(stale))
        XCTAssertEqual(state.registerActivity(playsStart: true), [])
        XCTAssertEqual(state.setForegroundActive(true), nil)
        XCTAssertEqual(state.registerActivity(playsStart: true), [])
        XCTAssertEqual(state.reset(), [.cancelPattern])
        XCTAssertEqual(state.registerActivity(playsStart: true), [.responseStarted])
    }

    func testFailureCancelsPatternAndReportsErrorOnlyForActiveTurn() {
        var state = ResponseHapticState()

        XCTAssertEqual(state.fail(), [.cancelPattern])
        _ = state.registerActivity(playsStart: false)
        XCTAssertEqual(state.fail(), [.cancelPattern, .error])
        XCTAssertFalse(state.isActive)
        XCTAssertFalse(state.startPlayed)
        XCTAssertNil(state.pendingConclusion)
    }

    func testResetInvalidatesTurnAndAllowsNextStart() throws {
        var state = ResponseHapticState()
        _ = state.registerActivity(playsStart: true)
        let stale = try XCTUnwrap(state.scheduleConclusion(sessionID: "old"))

        XCTAssertEqual(state.reset(), [.cancelPattern])
        XCTAssertNil(state.finishConclusion(stale))
        XCTAssertEqual(state.registerActivity(playsStart: true), [.responseStarted])
    }
}

final class ResponseHapticPolicyTests: XCTestCase {
    func testMapsEveryLifecycleEventCategory() {
        let sessionID = "session"
        let approval = ApprovalActivity(
            sessionId: sessionID,
            command: "echo hi",
            description: "Run command",
            choices: nil,
            allowPermanent: false,
            smartDenied: false,
            status: .pending,
            choice: nil,
            error: nil
        )
        let delegateTool = DelegateAgentActivity(
            id: "agent",
            goal: "goal",
            model: nil,
            status: .running,
            taskCount: 1,
            taskIndex: 0,
            currentTool: "shell",
            summary: nil,
            stream: [DelegateAgentActivity.StreamLine(kind: .tool, text: "tool", isError: false)]
        )
        var delegateProgress = delegateTool
        delegateProgress.stream = [
            DelegateAgentActivity.StreamLine(kind: .progress, text: "working", isError: false)
        ]

        XCTAssertEqual(ResponseHapticPolicy.signal(for: .messageStart(sessionId: sessionID)), .activity(playsStart: false))
        XCTAssertEqual(ResponseHapticPolicy.signal(for: .reasoningDelta(sessionId: sessionID, text: "thinking")), .activity(playsStart: false))
        XCTAssertEqual(ResponseHapticPolicy.signal(for: .messageDelta(sessionId: sessionID, text: "answer")), .activity(playsStart: true))
        XCTAssertEqual(ResponseHapticPolicy.signal(for: .clarify(sessionId: sessionID, activity: ClarifyActivity(requestId: "request", question: "Choose", choices: []))), .activity(playsStart: false))
        XCTAssertEqual(ResponseHapticPolicy.signal(for: .clarifyExpire(sessionId: sessionID, requestId: "request")), .activity(playsStart: false))
        XCTAssertEqual(ResponseHapticPolicy.signal(for: .approval(sessionId: sessionID, activity: approval)), .activity(playsStart: false))
        XCTAssertEqual(ResponseHapticPolicy.signal(for: .toolStart(sessionId: sessionID, toolName: "shell", toolInput: nil)), .tool)
        XCTAssertEqual(ResponseHapticPolicy.signal(for: .delegateAgent(sessionId: sessionID, activity: delegateTool)), .tool)
        XCTAssertNil(ResponseHapticPolicy.signal(for: .delegateAgent(sessionId: sessionID, activity: delegateProgress)))
        XCTAssertEqual(ResponseHapticPolicy.signal(for: .messageError(sessionId: sessionID, message: "failed")), .failure)
        XCTAssertEqual(ResponseHapticPolicy.signal(for: .messageInterrupted(sessionId: sessionID)), .reset)
        XCTAssertNil(ResponseHapticPolicy.signal(for: .toolStart(sessionId: sessionID, toolName: "clarify", toolInput: nil)))
        XCTAssertNil(ResponseHapticPolicy.signal(for: .messageComplete(sessionId: sessionID, messageId: nil, content: nil, reasoning: nil)))
        XCTAssertNil(ResponseHapticPolicy.signal(for: .toolComplete(sessionId: sessionID, toolName: "shell", toolOutput: nil)))
        XCTAssertNil(ResponseHapticPolicy.signal(for: .sessionBusy(sessionId: sessionID, busy: false)))
    }

    func testScenePhasePolicySuppressesOnlyBackgroundFeedback() {
        XCTAssertTrue(ResponseHapticPolicy.treatsAsForegroundActive(.active))
        XCTAssertTrue(ResponseHapticPolicy.treatsAsForegroundActive(.inactive))
        XCTAssertFalse(ResponseHapticPolicy.treatsAsForegroundActive(.background))
    }

    func testIdleConclusionRequiresAnIdleNonInteractiveTurn() {
        XCTAssertFalse(ResponseHapticPolicy.shouldScheduleIdleConclusion(isBusy: true, hasPendingConclusion: false, awaitsUserInput: false))
        XCTAssertFalse(ResponseHapticPolicy.shouldScheduleIdleConclusion(isBusy: false, hasPendingConclusion: true, awaitsUserInput: false))
        XCTAssertFalse(ResponseHapticPolicy.shouldScheduleIdleConclusion(isBusy: false, hasPendingConclusion: false, awaitsUserInput: true))
        XCTAssertTrue(ResponseHapticPolicy.shouldScheduleIdleConclusion(isBusy: false, hasPendingConclusion: false, awaitsUserInput: false))
    }
}

@MainActor
final class HapticsEmissionTests: XCTestCase {
    func testDevicePreferenceSuppressesEveryConduitEmission() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: Haptics.preferenceKey)
        let previousHandler = Haptics.testEmissionHandler
        let previousSuppressesHardware = Haptics.testSuppressesHardware
        var emissions: [Haptics.Event] = []
        Haptics.testSuppressesHardware = true
        Haptics.testEmissionHandler = { emissions.append($0) }
        defer {
            Haptics.testEmissionHandler = previousHandler
            Haptics.testSuppressesHardware = previousSuppressesHardware
            if let previousValue {
                defaults.set(previousValue, forKey: Haptics.preferenceKey)
            } else {
                defaults.removeObject(forKey: Haptics.preferenceKey)
            }
        }

        Haptics.enabled = false
        emitEveryHaptic()

        XCTAssertFalse(Haptics.enabled)
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: Haptics.preferenceKey) as? Bool,
            false
        )
        XCTAssertEqual(emissions, [])

        Haptics.enabled = true
        emitEveryHaptic()

        XCTAssertEqual(
            emissions,
            [
                .soft,
                .light,
                .medium,
                .rigid,
                .success,
                .error,
                .warning,
                .selection,
                .toolStarted,
                .responseStarted,
                .responseConcluded
            ]
        )
    }

    private func emitEveryHaptic() {
        Haptics.soft()
        Haptics.light()
        Haptics.medium()
        Haptics.rigid()
        Haptics.success()
        Haptics.error()
        Haptics.warning()
        Haptics.selection()
        Haptics.toolStarted()
        Haptics.responseStarted()
        Haptics.responseConcluded()
    }
}
