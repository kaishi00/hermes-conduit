//
//  ConnectionSetupTestTests.swift
//  Conduit
//
//  Round-4 staged connection test coverage: the state machine reducer, the
//  flow's test-gating and invalidation rules, the recovery/retry policy,
//  copy pins, and the probe's orchestration boundary (failure mapping and
//  side-effect freedom) against the real NativeAuthClient through a
//  URLProtocol stub.
//

import XCTest
@testable import Conduit

/// Drives a real staged-test success through the flow model's event reducer,
/// so flow tests exercise the same path the probe and view use.
enum StagedTestDriver {
    static let successEvents: [ConnectionSetupTestEvent] = [
        .started(.server), .succeeded(.server),
        .started(.dashboard), .succeeded(.dashboard),
        .started(.authentication), .succeeded(.authentication)
    ]

    /// Runs a full successful test on a flow sitting at `.connectionTest`.
    /// Returns the generation token used.
    @discardableResult
    static func runSuccessfulTest(on flow: inout ConnectionSetupFlow) -> Int? {
        guard let generation = flow.beginTest() else { return nil }
        for event in successEvents {
            flow.applyTestEvent(event, generation: generation)
        }
        return generation
    }
}

final class ConnectionSetupTestTests: XCTestCase {
    // MARK: - Flow factory

    /// A flow sitting at `.connectionTest` via the full LAN walk.
    private func makeFlowAtTestStep(
        username: String = "probe-user",
        password: String = "in-memory-fixture"
    ) -> ConnectionSetupFlow {
        var flow = ConnectionSetupFlow(entry: .network)
        flow.selectAccessMethod(.lan)
        flow.confirmDetailsReady()
        flow.draft.lan.host = "192.168.1.28"
        flow.draft.lan.port = "9119"
        flow.submitDetails()
        flow.draft.username = username
        flow.draft.password = password
        flow.submitCredentials()
        XCTAssertEqual(flow.step, .connectionTest)
        return flow
    }

    /// A flow at `.connectionTest` via the short auth-recovery route
    /// (credentials entry with an existing expert address).
    private func makeAuthRecoveryFlowAtTestStep() -> ConnectionSetupFlow {
        var flow = ConnectionSetupFlow(entry: .credentials, draft: ConnectionSetupDraft(
            existingServerURL: "https://hermes.example:9443",
            username: "probe-user",
            password: "in-memory-fixture"
        ))
        flow.answerCredentials(.yes)
        XCTAssertEqual(flow.step, .loginCredentials)
        flow.submitCredentials()
        XCTAssertEqual(flow.step, .connectionTest)
        return flow
    }

    /// A flow at `.connectionTest` via the Settings current-connection entry
    /// with an empty credential seed (credentials unavailable — the exact
    /// shape of an actively-connected user who never saved credentials).
    private func makeCredentialsLessSettingsFlowAtTestStep() -> ConnectionSetupFlow {
        let flow = ConnectionSetupFlow(entry: .currentConnection, draft: ConnectionSetupDraft(
            existingServerURL: "https://hermes.example:9443/hermes"
        ))
        XCTAssertEqual(flow.step, .connectionTest, "The credentials-unavailable Settings entry lands on the staged test")
        return flow
    }

    // MARK: - State machine (spec 19)

    func testFullSuccessSequenceReachesAcceptableState() {
        var flow = makeFlowAtTestStep()
        guard let generation = flow.beginTest() else { return XCTFail("beginTest must start on the test step") }

        flow.applyTestEvent(.started(.server), generation: generation)
        XCTAssertEqual(flow.testState.server, .running)
        flow.applyTestEvent(.succeeded(.server), generation: generation)
        XCTAssertEqual(flow.testState.server, .succeeded)
        flow.applyTestEvent(.started(.dashboard), generation: generation)
        XCTAssertEqual(flow.testState.dashboard, .running)
        flow.applyTestEvent(.succeeded(.dashboard), generation: generation)
        XCTAssertEqual(flow.testState.dashboard, .succeeded)
        flow.applyTestEvent(.started(.authentication), generation: generation)
        XCTAssertEqual(flow.testState.authentication, .running)
        flow.applyTestEvent(.succeeded(.authentication), generation: generation)

        XCTAssertTrue(flow.testState.allSucceeded)
        XCTAssertEqual(flow.step, .review, "The final success advances to Review")
        XCTAssertTrue(flow.hasCurrentSuccessfulTest)
        XCTAssertNotNil(flow.complete(), "A current successful test authorizes acceptance")
    }

    func testReachabilityFailureKeepsLaterStagesPending() throws {
        var flow = makeFlowAtTestStep()
        let generation = try XCTUnwrap(flow.beginTest())
        flow.applyTestEvent(.started(.server), generation: generation)
        flow.applyTestEvent(.failed(.server, .connectionRefused), generation: generation)

        XCTAssertEqual(flow.testState.server, .failed(.connectionRefused))
        XCTAssertEqual(flow.testState.dashboard, .pending)
        XCTAssertEqual(flow.testState.authentication, .pending)
        XCTAssertEqual(flow.testState.failedFailure, .connectionRefused)
        XCTAssertEqual(flow.testState.failedStage, .server)
        XCTAssertEqual(flow.step, .connectionTest, "A failure must not navigate")
        XCTAssertNil(flow.complete())
    }

    func testDashboardFailureKeepsAuthenticationPendingAndServerSuccess() throws {
        var flow = makeFlowAtTestStep()
        let generation = try XCTUnwrap(flow.beginTest())
        flow.applyTestEvent(.started(.server), generation: generation)
        flow.applyTestEvent(.succeeded(.server), generation: generation)
        flow.applyTestEvent(.started(.dashboard), generation: generation)
        flow.applyTestEvent(.failed(.dashboard, .unexpectedServerResponse), generation: generation)

        XCTAssertEqual(flow.testState.server, .succeeded, "Prior success must remain visible")
        XCTAssertEqual(flow.testState.dashboard, .failed(.unexpectedServerResponse))
        XCTAssertEqual(flow.testState.authentication, .pending)
        XCTAssertEqual(flow.testState.failedStage, .dashboard)
    }

    func testAuthenticationFailurePreservesPriorSuccesses() throws {
        var flow = makeFlowAtTestStep()
        let generation = try XCTUnwrap(flow.beginTest())
        for event in StagedTestDriver.successEvents.prefix(4) {
            flow.applyTestEvent(event, generation: generation)
        }
        flow.applyTestEvent(.failed(.authentication, .authenticationRejected), generation: generation)

        XCTAssertEqual(flow.testState.server, .succeeded)
        XCTAssertEqual(flow.testState.dashboard, .succeeded)
        XCTAssertEqual(flow.testState.authentication, .failed(.authenticationRejected))
        XCTAssertEqual(flow.step, .connectionTest)
        XCTAssertNil(flow.complete())
    }

    func testRetryRestartsCleanAndIgnoresTheOldGeneration() throws {
        var flow = makeFlowAtTestStep()
        let firstGeneration = try XCTUnwrap(flow.beginTest())
        flow.applyTestEvent(.started(.server), generation: firstGeneration)
        flow.applyTestEvent(.failed(.server, .timedOut), generation: firstGeneration)

        // Retry: a clean staged rerun with a fresh generation.
        let secondGeneration = flow.beginTest()
        XCTAssertNotNil(secondGeneration)
        XCTAssertNotEqual(firstGeneration, secondGeneration)
        XCTAssertEqual(flow.testState, ConnectionSetupTestState(), "Retry must reset every stage to untested")

        // A late event from the abandoned run is dropped.
        flow.applyTestEvent(.succeeded(.server), generation: firstGeneration)
        XCTAssertEqual(flow.testState.server, .pending)
    }

    func testBeginTestIsGuardedOffTheTestStep() {
        var flow = makeFlowAtTestStep()
        StagedTestDriver.runSuccessfulTest(on: &flow)
        XCTAssertEqual(flow.step, .review)
        XCTAssertNil(flow.beginTest(), "No test may start from Review")

        var fresh = ConnectionSetupFlow(entry: .start)
        XCTAssertNil(fresh.beginTest())
    }

    func testBeginTestRejectsConcurrentRuns() throws {
        var flow = makeFlowAtTestStep()
        let first = try XCTUnwrap(flow.beginTest())
        flow.applyTestEvent(.started(.server), generation: first)
        XCTAssertNil(flow.beginTest(), "Tests never queue: one run at a time")
    }

    func testCancellationResetsRunningStagesAndDropsLateEvents() throws {
        var flow = makeFlowAtTestStep()
        let generation = try XCTUnwrap(flow.beginTest())
        flow.applyTestEvent(.started(.server), generation: generation)

        flow.cancelTest()
        XCTAssertEqual(flow.testState, ConnectionSetupTestState(), "A cancelled run resets to untested")
        flow.applyTestEvent(.succeeded(.server), generation: generation)
        XCTAssertEqual(flow.testState.server, .pending, "Late events from the cancelled run are dropped")

        // A completed (non-running) state survives cancelTest untouched.
        StagedTestDriver.runSuccessfulTest(on: &flow)
        flow.cancelTest()
        XCTAssertTrue(flow.hasCurrentSuccessfulTest, "Cancelling never retracts a finished success")
    }

    func testEventsStopApplyingAfterTheSuccessAdvance() {
        var flow = makeFlowAtTestStep()
        StagedTestDriver.runSuccessfulTest(on: &flow)
        XCTAssertEqual(flow.step, .review)
        // A same-generation event arriving after the advance is dropped.
        let generation = flow.testGeneration
        flow.applyTestEvent(.failed(.authentication, .authenticationRejected), generation: generation)
        XCTAssertTrue(flow.hasCurrentSuccessfulTest)
    }

    func testCompleteRequiresACurrentSuccessfulTest() throws {
        var flow = makeFlowAtTestStep()
        XCTAssertNil(flow.complete(), "Untested configuration is never handed off")

        StagedTestDriver.runSuccessfulTest(on: &flow)
        let result = try XCTUnwrap(flow.complete())
        XCTAssertEqual(result.serverURL, "http://192.168.1.28:9119")
    }

    // MARK: - Edit invalidation (spec 14)

    func testDraftEditInvalidatesPreviousSuccessAndResetsOnReentry() {
        var flow = makeFlowAtTestStep()
        StagedTestDriver.runSuccessfulTest(on: &flow)
        XCTAssertTrue(flow.hasCurrentSuccessfulTest)

        // Back to credentials and edit: the success is immediately invalid.
        flow.back()
        XCTAssertEqual(flow.step, .connectionTest)
        XCTAssertTrue(flow.hasCurrentSuccessfulTest, "Back alone does not invalidate")
        flow.back()
        XCTAssertEqual(flow.step, .loginCredentials)
        flow.draft.username = "changed-user"
        XCTAssertFalse(flow.hasCurrentSuccessfulTest, "Any draft edit invalidates the success")

        flow.submitCredentials()
        XCTAssertEqual(flow.step, .connectionTest)
        XCTAssertEqual(flow.testState, ConnectionSetupTestState(), "Re-entry with a stale success resets to untested")
        XCTAssertNil(flow.complete())
    }

    func testStaleLateFailureCannotOverwriteNewerSuccessfulRun() throws {
        var flow = makeFlowAtTestStep()
        // Test A begins with the old credentials.
        let generationA = try XCTUnwrap(flow.beginTest())
        flow.applyTestEvent(.started(.server), generation: generationA)

        // The user edits credentials and starts Test B.
        flow.back()
        flow.draft.password = "newer-fixture"
        flow.submitCredentials()
        let generationB = try XCTUnwrap(flow.beginTest())
        XCTAssertNotEqual(generationA, generationB)

        // Test A finishes late with a rejection — dropped.
        flow.applyTestEvent(.failed(.authentication, .authenticationRejected), generation: generationA)
        XCTAssertEqual(flow.testState.failedStage, nil)

        // Test B succeeds; the final state remains successful.
        for event in StagedTestDriver.successEvents {
            flow.applyTestEvent(event, generation: generationB)
        }
        XCTAssertEqual(flow.step, .review)
        XCTAssertTrue(flow.hasCurrentSuccessfulTest)

        // Even a later stale event cannot corrupt the finished run.
        flow.back()
        flow.applyTestEvent(.failed(.server, .hostNotFound), generation: generationA)
        XCTAssertTrue(flow.hasCurrentSuccessfulTest)
        XCTAssertNil(flow.testState.failedStage)
    }

    // MARK: - Interactive sign-in outcome (flow model)

    /// The staged interactive-auth run: server and dashboard succeed and
    /// authentication stops at "browser sign-in required".
    static let interactiveAuthEvents: [ConnectionSetupTestEvent] = [
        .started(.server), .succeeded(.server),
        .started(.dashboard), .succeeded(.dashboard),
        .started(.authentication),
        .requiresInteractiveSignIn(.authentication)
    ]

    @discardableResult
    private static func runInteractiveTest(on flow: inout ConnectionSetupFlow) -> Int? {
        guard let generation = flow.beginTest() else { return nil }
        for event in interactiveAuthEvents {
            flow.applyTestEvent(event, generation: generation)
        }
        return generation
    }

    func testInteractiveOutcomeAdvancesToReviewAsDistinctTerminalState() {
        var flow = makeFlowAtTestStep()
        ConnectionSetupTestTests.runInteractiveTest(on: &flow)

        XCTAssertEqual(flow.step, .review, "The supported interactive outcome advances to Review")
        XCTAssertEqual(flow.testState.server, .succeeded)
        XCTAssertEqual(flow.testState.dashboard, .succeeded)
        XCTAssertEqual(flow.testState.authentication, .requiresInteractiveSignIn)
        XCTAssertNil(flow.testState.failedStage, "Interactive auth is not a failure")
        XCTAssertFalse(flow.testState.allSucceeded, "Authentication is never marked succeeded")
        XCTAssertFalse(flow.hasCurrentSuccessfulTest)
        XCTAssertFalse(flow.fullyAuthenticated, "The user has not authenticated yet")
        XCTAssertTrue(flow.hasCurrentInteractiveAuthOutcome)
        XCTAssertTrue(flow.canUseSettings, "The validated configuration may still be handed off")
        XCTAssertNotNil(flow.complete())
    }

    func testNativeSuccessIsFullyAuthenticatedWhileInteractiveIsNot() {
        var native = makeFlowAtTestStep()
        StagedTestDriver.runSuccessfulTest(on: &native)
        XCTAssertTrue(native.canUseSettings)
        XCTAssertTrue(native.fullyAuthenticated)
        XCTAssertFalse(native.hasCurrentInteractiveAuthOutcome)

        var interactive = makeFlowAtTestStep()
        ConnectionSetupTestTests.runInteractiveTest(on: &interactive)
        XCTAssertTrue(interactive.canUseSettings)
        XCTAssertFalse(interactive.fullyAuthenticated)
        XCTAssertTrue(interactive.hasCurrentInteractiveAuthOutcome)
    }

    func testUntestedAndFailedConfigurationsCannotUseSettings() throws {
        var untested = makeFlowAtTestStep()
        XCTAssertFalse(untested.canUseSettings)
        XCTAssertFalse(untested.fullyAuthenticated)
        XCTAssertFalse(untested.hasCurrentInteractiveAuthOutcome)
        XCTAssertNil(untested.complete())

        var failed = makeFlowAtTestStep()
        let generation = try XCTUnwrap(failed.beginTest())
        failed.applyTestEvent(.started(.server), generation: generation)
        failed.applyTestEvent(.failed(.server, .hostNotFound), generation: generation)
        XCTAssertFalse(failed.canUseSettings)
        XCTAssertNil(failed.complete())
    }

    func testDraftEditInvalidatesInteractiveOutcomeLikeNativeSuccess() {
        var flow = makeFlowAtTestStep()
        ConnectionSetupTestTests.runInteractiveTest(on: &flow)
        XCTAssertTrue(flow.hasCurrentInteractiveAuthOutcome)

        flow.back()
        flow.back()
        flow.draft.username = "changed-user"
        XCTAssertFalse(flow.hasCurrentInteractiveAuthOutcome, "An edit invalidates the interactive authorization")
        XCTAssertFalse(flow.canUseSettings)

        flow.submitCredentials()
        XCTAssertEqual(flow.step, .connectionTest)
        XCTAssertEqual(flow.testState, ConnectionSetupTestState(), "Re-entry with a stale outcome resets to untested")
        XCTAssertNil(flow.complete())
    }

    func testStaleInteractiveCompletionCannotOverwriteNewerNativeSuccess() throws {
        var flow = makeFlowAtTestStep()
        // Run A starts and reaches the authentication stage.
        let generationA = try XCTUnwrap(flow.beginTest())
        for event in ConnectionSetupTestTests.interactiveAuthEvents.prefix(5) {
            flow.applyTestEvent(event, generation: generationA)
        }
        // The user edits the server address; Run B tests natively and wins.
        flow.back()
        flow.back()
        flow.draft.lan.host = "192.168.1.29"
        flow.submitDetails()
        flow.submitCredentials()
        let generationB = try XCTUnwrap(flow.beginTest())
        XCTAssertNotEqual(generationA, generationB)
        for event in StagedTestDriver.successEvents {
            flow.applyTestEvent(event, generation: generationB)
        }
        XCTAssertEqual(flow.step, .review)
        XCTAssertTrue(flow.hasCurrentSuccessfulTest)

        // Run A's interactive completion arrives late: dropped.
        flow.back()
        let applied = flow.applyTestEvent(
            .requiresInteractiveSignIn(.authentication), generation: generationA
        )
        XCTAssertFalse(applied, "A stale interactive completion must never apply")
        XCTAssertTrue(flow.hasCurrentSuccessfulTest, "Run B stays authoritative")
        XCTAssertFalse(flow.hasCurrentInteractiveAuthOutcome)
        XCTAssertTrue(flow.canUseSettings)
    }

    func testStaleNativeSuccessCannotOverwriteNewerInteractiveOutcome() throws {
        var flow = makeFlowAtTestStep()
        // Run A (native) gets partway, then the user edits and Run B ends in
        // the interactive outcome.
        let generationA = try XCTUnwrap(flow.beginTest())
        flow.applyTestEvent(.started(.server), generation: generationA)
        flow.back()
        flow.back()
        flow.draft.lan.host = "192.168.1.29"
        flow.submitDetails()
        flow.submitCredentials()
        ConnectionSetupTestTests.runInteractiveTest(on: &flow)
        XCTAssertEqual(flow.step, .review)
        XCTAssertTrue(flow.hasCurrentInteractiveAuthOutcome)

        // Run A's native success arrives late: dropped, the interactive
        // outcome stays authoritative.
        flow.back()
        for event in StagedTestDriver.successEvents {
            let applied = flow.applyTestEvent(event, generation: generationA)
            XCTAssertFalse(applied)
        }
        XCTAssertTrue(flow.hasCurrentInteractiveAuthOutcome)
        XCTAssertFalse(flow.fullyAuthenticated)
        XCTAssertTrue(flow.canUseSettings)
    }

    func testReducerKeepsInteractiveOutcomeMonotonic() {
        var state = ConnectionSetupTestState()
        state.apply(.started(.authentication))
        state.apply(.requiresInteractiveSignIn(.authentication))
        XCTAssertEqual(state.authentication, .requiresInteractiveSignIn)
        // A terminal stage never reverts, whatever arrives later.
        state.apply(.failed(.authentication, .authenticationRejected))
        state.apply(.succeeded(.authentication))
        state.apply(.started(.authentication))
        state.apply(.requiresInteractiveSignIn(.authentication))
        XCTAssertEqual(state.authentication, .requiresInteractiveSignIn)
    }

    // MARK: - Recovery routing (spec 11/12/17)

    func testEditAfterFailedTestPopsToConnectionDetails() throws {
        var flow = makeFlowAtTestStep()
        let generation = try XCTUnwrap(flow.beginTest())
        flow.applyTestEvent(.failed(.server, .hostNotFound), generation: generation)
        let pathCount = flow.path.count

        flow.editAfterFailedTest(.connectionDetails)
        XCTAssertEqual(flow.step, .connectionDetails)
        XCTAssertEqual(flow.path.count, pathCount - 2, "The path truncates back to details")
    }

    func testEditAfterFailedTestInsertsDetailsOnTheShortcutRoute() throws {
        var flow = makeAuthRecoveryFlowAtTestStep()
        let generation = try XCTUnwrap(flow.beginTest())
        flow.applyTestEvent(.failed(.dashboard, .dashboardUnavailable), generation: generation)

        flow.editAfterFailedTest(.connectionDetails)
        XCTAssertEqual(flow.step, .connectionDetails)
        flow.back()
        XCTAssertEqual(flow.step, .loginCredentials, "The inserted details step walks back to credentials")
    }

    func testEditAfterFailedTestTargetsCredentials() throws {
        var flow = makeFlowAtTestStep()
        let generation = try XCTUnwrap(flow.beginTest())
        flow.applyTestEvent(.failed(.authentication, .authenticationRejected), generation: generation)

        flow.editAfterFailedTest(.loginCredentials)
        XCTAssertEqual(flow.step, .loginCredentials)
    }

    func testEditAfterFailedTestIsGuarded() {
        var flow = makeFlowAtTestStep()
        // Only from the test step, and only to the two editable steps.
        flow.back()
        flow.editAfterFailedTest(.connectionDetails)
        XCTAssertEqual(flow.step, .loginCredentials, "Guarded off the test step")

        flow.submitCredentials()
        flow.editAfterFailedTest(.review)
        XCTAssertEqual(flow.step, .connectionTest, "Only details/credentials are valid remediation targets")
    }

    func testContinueToReviewRequiresCurrentSuccess() {
        var flow = makeFlowAtTestStep()
        flow.continueToReview()
        XCTAssertEqual(flow.step, .connectionTest, "No continue without a successful test")

        StagedTestDriver.runSuccessfulTest(on: &flow)
        XCTAssertEqual(flow.step, .review)
        flow.back()
        flow.continueToReview()
        XCTAssertEqual(flow.step, .review, "A current success allows continuing without re-testing")
    }

    // MARK: - Recovery plan policy

    func testAuthenticationRecoveryTargetsCredentialsAndKeepsRetrySecondary() {
        let plan = ConnectionSetupTestRecoveryPlan.plan(for: .authentication, failure: .authenticationRejected)
        XCTAssertEqual(plan.remediationStep, .loginCredentials)
        XCTAssertEqual(plan.remediationLabel, "Edit Credentials")
        XCTAssertTrue(plan.offersRetry, "Retry stays available but is never the primary action")
    }

    func testRateLimitingNeverOffersARetryAction() {
        for stage in ConnectionSetupTestStage.allCases {
            let plan = ConnectionSetupTestRecoveryPlan.plan(for: stage, failure: .rateLimited)
            XCTAssertFalse(plan.offersRetry, "\(stage) rate limiting must not invite an immediate retry")
        }
    }

    func testTransportFailuresTargetConnectionDetails() {
        let transportFailures: [ConnectionFailure] = [
            .hostNotFound, .unreachable, .connectionRefused, .timedOut,
            .offline, .tlsUntrusted, .tlsBadDate, .tlsFailure, .insecureTransport, .invalidAddress
        ]
        for failure in transportFailures {
            let plan = ConnectionSetupTestRecoveryPlan.plan(for: .server, failure: failure)
            XCTAssertEqual(plan.remediationStep, .connectionDetails, "\(failure) is fixed at the details step")
            XCTAssertTrue(plan.offersRetry)
        }
        let plan = ConnectionSetupTestRecoveryPlan.plan(for: .dashboard, failure: .dashboardUnavailable)
        XCTAssertEqual(plan.remediationStep, .connectionDetails)
    }

    // MARK: - Copy and accessibility pins (spec 10/24)

    func testStageCopyMatchesTheShippedContract() {
        XCTAssertEqual(ConnectionSetupTestStage.server.objectiveLabel, "Dashboard reachable")
        XCTAssertEqual(ConnectionSetupTestStage.server.runningLabel, "Checking server…")
        XCTAssertEqual(ConnectionSetupTestStage.server.successLabel, "Dashboard reachable")
        XCTAssertEqual(ConnectionSetupTestStage.dashboard.objectiveLabel, "Hermes dashboard found")
        XCTAssertEqual(ConnectionSetupTestStage.dashboard.runningLabel, "Checking dashboard…")
        XCTAssertEqual(ConnectionSetupTestStage.dashboard.successLabel, "Hermes dashboard found")
        XCTAssertEqual(ConnectionSetupTestStage.authentication.objectiveLabel, "Authentication")
        XCTAssertEqual(ConnectionSetupTestStage.authentication.runningLabel, "Authenticating…")
        XCTAssertEqual(ConnectionSetupTestStage.authentication.successLabel, "Login successful")
        XCTAssertEqual(ConnectionSetupTestState.readyMessage, "This connection is ready to use.")
        XCTAssertEqual(
            ConnectionSetupTestState.interactiveReadyMessage,
            "This dashboard uses browser-based sign-in. "
                + "Conduit will open the sign-in page after you return to the login screen."
        )
    }

    func testInteractiveOutcomeCopyNeverClaimsAuthentication() {
        var state = ConnectionSetupTestState()
        state.apply(.started(.authentication))
        state.apply(.requiresInteractiveSignIn(.authentication))

        XCTAssertEqual(
            state.rowLabel(for: .authentication),
            "Browser sign-in required",
            "The interactive row must never read as Login successful"
        )
        XCTAssertEqual(state.accessibilityLabel(for: .authentication), "Authentication, browser sign-in required")
        XCTAssertNotEqual(state.rowLabel(for: .authentication), ConnectionSetupTestStage.authentication.successLabel)
    }

    func testAccessibilityLabelsCarryStateWordsNotJustIcons() {
        var state = ConnectionSetupTestState()
        XCTAssertEqual(state.accessibilityLabel(for: .server), "Dashboard reachable, waiting")
        state.apply(.started(.server))
        state.apply(.succeeded(.server))
        XCTAssertEqual(state.accessibilityLabel(for: .server), "Dashboard reachable, passed")
        state.apply(.started(.dashboard))
        XCTAssertEqual(state.accessibilityLabel(for: .dashboard), "Hermes dashboard found, checking")
        state.apply(.failed(.authentication, .authenticationRejected))
        XCTAssertEqual(state.accessibilityLabel(for: .authentication), "Authentication, failed")
    }

    func testRowLabelsFollowStageState() {
        var state = ConnectionSetupTestState()
        XCTAssertEqual(state.rowLabel(for: .authentication), "Authentication")
        state.apply(.started(.authentication))
        XCTAssertEqual(state.rowLabel(for: .authentication), "Authenticating…")
        state.apply(.succeeded(.authentication))
        XCTAssertEqual(state.rowLabel(for: .authentication), "Login successful")
    }

    // MARK: - Credentials-required partial outcome, flow model (Round 5.1)

    /// The staged credentials-required run: server and dashboard succeed and
    /// authentication stops BEFORE any login attempt because the tested
    /// configuration carries no usable credentials.
    static let credentialsRequiredEvents: [ConnectionSetupTestEvent] = [
        .started(.server), .succeeded(.server),
        .started(.dashboard), .succeeded(.dashboard),
        .started(.authentication),
        .requiresCredentials(.authentication)
    ]

    func testCredentialsRequiredOutcomeIsNeitherSuccessNorFailureNorInteractive() throws {
        var flow = makeCredentialsLessSettingsFlowAtTestStep()
        let generation = try XCTUnwrap(flow.beginTest())
        for event in Self.credentialsRequiredEvents {
            XCTAssertTrue(flow.applyTestEvent(event, generation: generation))
        }

        XCTAssertEqual(flow.testState.server, .succeeded)
        XCTAssertEqual(flow.testState.dashboard, .succeeded)
        XCTAssertEqual(flow.testState.authentication, .requiresCredentials)
        XCTAssertTrue(flow.testState.requiresCredentials)
        XCTAssertFalse(flow.testState.allSucceeded, "A partial test is never a success")
        XCTAssertFalse(flow.testState.requiresInteractiveSignIn, "Credential absence is never an authentication mode")
        XCTAssertFalse(flow.canUseSettings, "A partial test never authorizes the settings handoff")
        XCTAssertEqual(flow.step, .connectionTest, "The partial outcome does not advance to Review")
        XCTAssertNil(flow.complete())
        XCTAssertNil(flow.testSucceededAtRevision, "Nothing was sealed: the outcome authorizes nothing")
    }

    func testCredentialsRequiredOutcomeRoutesToCredentialsEntryAndResets() throws {
        var flow = makeCredentialsLessSettingsFlowAtTestStep()
        let generation = try XCTUnwrap(flow.beginTest())
        for event in Self.credentialsRequiredEvents {
            flow.applyTestEvent(event, generation: generation)
        }
        XCTAssertTrue(flow.testState.requiresCredentials)

        flow.editAfterFailedTest(.loginCredentials)
        XCTAssertEqual(flow.step, .loginCredentials)
        XCTAssertEqual(flow.testState, ConnectionSetupTestState(), "Leaving the test step invalidates the partial result")

        // With both credentials entered, the rerun takes the normal path.
        flow.draft.username = "probe-user"
        flow.draft.password = "in-memory-fixture"
        flow.submitCredentials()
        XCTAssertEqual(flow.step, .connectionTest)
        let rerun = try XCTUnwrap(flow.beginTest())
        for event in StagedTestDriver.successEvents {
            flow.applyTestEvent(event, generation: rerun)
        }
        XCTAssertEqual(flow.step, .review, "A full rerun with present credentials succeeds normally")
    }

    func testStaleCredentialsRequiredEventFromAnOlderRunIsDropped() throws {
        var flow = makeCredentialsLessSettingsFlowAtTestStep()
        let staleGeneration = try XCTUnwrap(flow.beginTest())
        for event in Self.credentialsRequiredEvents {
            flow.applyTestEvent(event, generation: staleGeneration)
        }

        // A newer run rotates the generation and resets the state.
        let freshGeneration = try XCTUnwrap(flow.beginTest())
        flow.applyTestEvent(.started(.server), generation: freshGeneration)
        XCTAssertEqual(flow.testState.server, .running)

        // The old run's late partial outcome cannot corrupt the newer run.
        flow.applyTestEvent(.requiresCredentials(.authentication), generation: staleGeneration)
        XCTAssertEqual(flow.testState.authentication, .pending, "The stale partial outcome is ignored")
        XCTAssertFalse(flow.testState.requiresCredentials)
    }

    func testCredentialsRequiredRowCarriesDistinctMeaningAndSafeCopy() {
        var state = ConnectionSetupTestState()
        state.apply(Self.credentialsRequiredEvents[4]) // started(.authentication)
        state.apply(.requiresCredentials(.authentication))
        XCTAssertEqual(state.rowLabel(for: .authentication), "Credentials required")
        XCTAssertEqual(state.accessibilityLabel(for: .authentication), "Authentication, credentials required")
        XCTAssertNotEqual(state.rowLabel(for: .authentication), ConnectionSetupTestStage.authentication.successLabel)
    }

    func testCredentialsRequiredOutcomeIsMonotonicWithinARun() {
        // A terminal stage never reverts, whatever arrives later in the same
        // run: the partial outcome can be superseded only by a new run, not
        // by late events.
        var state = ConnectionSetupTestState()
        state.apply(Self.credentialsRequiredEvents[4]) // started(.authentication)
        state.apply(.requiresCredentials(.authentication))
        state.apply(.succeeded(.authentication))
        XCTAssertEqual(state.authentication, .requiresCredentials)
        state.apply(.failed(.authentication, .authenticationRejected))
        XCTAssertEqual(state.authentication, .requiresCredentials)
    }

    func testTestCopyContainsNoExposureOrCredentialLanguage() {
        // `ConnectionSetupTestState.credentialsRequiredMessage` is
        // deliberately absent from this scan: as the recovery notice for a
        // proven password dashboard it must name the username-and-password
        // auth mode, so the "password" forbidden word below — which guards
        // row labels and ready claims, not recovery notices — does not
        // apply to it.
        var allStrings = [
            ConnectionSetupTestState.readyMessage,
            ConnectionSetupTestState.interactiveReadyMessage,
            "Browser sign-in required",
            "Credentials required"
        ]
        for stage in ConnectionSetupTestStage.allCases {
            allStrings.append(contentsOf: [stage.objectiveLabel, stage.runningLabel, stage.successLabel])
        }
        let forbidden = ["password", "secret", "token", "public", "port forward", "firewall", "expose"]
        for string in allStrings {
            for phrase in forbidden {
                XCTAssertFalse(
                    string.lowercased().contains(phrase),
                    "Stage copy must not contain '\(phrase)': \(string)"
                )
            }
        }
    }

    // MARK: - Probe orchestration (spec 20) — real NativeAuthClient through URLProtocol

    override func setUp() {
        super.setUp()
        SetupProbeURLProtocol.reset()
    }

    override func tearDown() {
        SetupProbeURLProtocol.reset()
        super.tearDown()
    }

    private static func makeProbeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SetupProbeURLProtocol.self]
        return configuration
    }

    @MainActor
    private func runProbe(
        _ baseURL: String,
        cloudflareAccess: CloudflareAccessCredentials? = nil
    ) async -> [ConnectionSetupTestEvent] {
        let probe = ConnectionSetupProbe(sessionConfiguration: Self.makeProbeConfiguration())
        var events: [ConnectionSetupTestEvent] = []
        await probe.runTest(
            result: ConnectionSetupResult(
                serverURL: baseURL,
                username: "probe-user",
                password: "probe-password-fixture"
            ),
            cloudflareAccess: cloudflareAccess,
            onEvent: { events.append($0) }
        )
        return events
    }

    func testProbeFullSuccessEmitsTheExactStagedSequence() async {
        let events = await runProbe("https://probe-success.example")
        XCTAssertEqual(events, StagedTestDriver.successEvents)
    }

    // MARK: - Validated transaction acquisition (Round 6)

    @MainActor
    private func runProbeWithAcquisition(
        _ baseURL: String
    ) async -> (events: [ConnectionSetupTestEvent], acquisition: ConnectionSetupTestAcquisition?) {
        let probe = ConnectionSetupProbe(sessionConfiguration: Self.makeProbeConfiguration())
        var events: [ConnectionSetupTestEvent] = []
        let acquisition = await probe.runTest(
            result: ConnectionSetupResult(
                serverURL: baseURL,
                username: "probe-user",
                password: "probe-password-fixture"
            ),
            cloudflareAccess: nil,
            onEvent: { events.append($0) }
        )
        return (events, acquisition)
    }

    func testProbeFullSuccessReturnsTheValidatedTransactionMemoryOnly() async throws {
        // Round 6: a successful native test hands back the validated
        // transaction (memory only — the probe never commits it), so Repair
        // can reconnect without repeating the password login.
        let (events, acquisition) = await runProbeWithAcquisition("https://probe-success.example")
        XCTAssertEqual(events, StagedTestDriver.successEvents)
        let validated = try XCTUnwrap(acquisition)
        XCTAssertEqual(validated.configuration.serverURL, "https://probe-success.example")
        XCTAssertEqual(validated.nativeConnection.ticket, "probe-ticket")
    }

    func testProbeDiagnosticOutcomesReturnNoAcquisition() async {
        let interactive = await runProbeWithAcquisition("https://probe-interactive.example")
        XCTAssertNil(interactive.acquisition, "The interactive outcome produces no native transaction")
        let rejected = await runProbeWithAcquisition("https://probe-auth401.example")
        XCTAssertNil(rejected.acquisition, "A rejected login produces no native transaction")
        let dns = await runProbeWithAcquisition("https://probe-dns.example")
        XCTAssertNil(dns.acquisition, "A transport failure produces no native transaction")
    }

    func testProbeDNSFailureMapsToHostNotFoundAtServerStage() async {
        let events = await runProbe("https://probe-dns.example")
        XCTAssertEqual(events, [.started(.server), .failed(.server, .hostNotFound)])
    }

    func testProbeRefusedMapsToConnectionRefusedAtServerStage() async {
        let events = await runProbe("https://probe-refused.example")
        XCTAssertEqual(events, [.started(.server), .failed(.server, .connectionRefused)])
    }

    func testProbeTimeoutMapsToTimedOutAtServerStage() async {
        let events = await runProbe("https://probe-timeout.example")
        XCTAssertEqual(events, [.started(.server), .failed(.server, .timedOut)])
    }

    func testProbeTLSUntrustedMapsToTLSUntrustedAtServerStage() async {
        let events = await runProbe("https://probe-tls.example")
        XCTAssertEqual(events, [.started(.server), .failed(.server, .tlsUntrusted)])
    }

    func testProbeTLSBadDateMapsToTLSBadDateAtServerStage() async {
        let events = await runProbe("https://probe-tlsdate.example")
        XCTAssertEqual(events, [.started(.server), .failed(.server, .tlsBadDate)])
    }

    func testProbeTLSHandshakeFailureMapsToTLSFailureAtServerStage() async {
        let events = await runProbe("https://probe-tlsfailure.example")
        XCTAssertEqual(events, [.started(.server), .failed(.server, .tlsFailure)])
    }

    func testProbeDashboard5xxMapsToDashboardUnavailableAfterTransportSuccess() async {
        let events = await runProbe("https://probe-5xx.example")
        XCTAssertEqual(events, [
            .started(.server),
            .succeeded(.server),
            .started(.dashboard),
            .failed(.dashboard, .dashboardUnavailable)
        ])
    }

    func testProbeNonHermesWebsiteMapsToUnexpectedServerResponse() async {
        // A 200 response without a password-capable provider is never a
        // Hermes dashboard, and never success.
        let events = await runProbe("https://probe-foreign.example")
        XCTAssertEqual(events, [
            .started(.server),
            .succeeded(.server),
            .started(.dashboard),
            .failed(.dashboard, .unexpectedServerResponse)
        ])
    }

    func testProbeRejectedCredentialsMapToAuthenticationRejected() async {
        let events = await runProbe("https://probe-auth401.example")
        XCTAssertEqual(events, Array(StagedTestDriver.successEvents.prefix(5)) + [
            .failed(.authentication, .authenticationRejected)
        ])
    }

    func testProbeLogin429MapsToRateLimited() async {
        let events = await runProbe("https://probe-auth429.example")
        XCTAssertEqual(events, Array(StagedTestDriver.successEvents.prefix(5)) + [
            .failed(.authentication, .rateLimited)
        ])
    }

    func testProbeTicketFailureMapsToSessionTicketFailure() async {
        // Password accepted, but no host-scoped session cookie survived —
        // the existing session-ticket semantics, not "wrong password".
        let events = await runProbe("https://probe-cookieless.example")
        XCTAssertEqual(events, Array(StagedTestDriver.successEvents.prefix(5)) + [
            .failed(.authentication, .sessionTicketFailure)
        ])
    }

    func testProbeAppliesTheInheritedCloudflareTokenAndClassifiesRejection() async {
        let events = await runProbe(
            "https://probe-cfreject.example",
            cloudflareAccess: CloudflareAccessCredentials(clientID: "probe-client-id", clientSecret: "probe-client-secret")
        )
        XCTAssertEqual(events, [
            .started(.server),
            .succeeded(.server),
            .started(.dashboard),
            .failed(.dashboard, .cloudflareTokenRejected)
        ])
        // The token reached the dashboard origin with the discovery request.
        XCTAssertEqual(
            SetupProbeURLProtocol.requestHeader(forPath: "/api/auth/providers", name: "CF-Access-Client-Id"),
            "probe-client-id"
        )
    }

    func testCancelledProbeStaysSilentAfterItsStartEvent() async throws {
        let probe = ConnectionSetupProbe(sessionConfiguration: Self.makeProbeConfiguration())
        var events: [ConnectionSetupTestEvent] = []
        let task = Task { @MainActor in
            await probe.runTest(
                result: ConnectionSetupResult(
                    serverURL: "https://probe-hang.example",
                    username: "probe-user",
                    password: "probe-password-fixture"
                ),
                cloudflareAccess: nil,
                onEvent: { events.append($0) }
            )
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        await task.value
        XCTAssertEqual(events, [.started(.server)], "Cancellation must emit no failure events")
    }

    // MARK: - Credentials-required partial outcome, probe (Round 5.1)

    @MainActor
    private func runProbeWithCredentials(
        _ baseURL: String,
        username: String,
        password: String
    ) async -> [ConnectionSetupTestEvent] {
        let probe = ConnectionSetupProbe(sessionConfiguration: Self.makeProbeConfiguration())
        var events: [ConnectionSetupTestEvent] = []
        await probe.runTest(
            result: ConnectionSetupResult(
                serverURL: baseURL,
                username: username,
                password: password
            ),
            cloudflareAccess: nil,
            onEvent: { events.append($0) }
        )
        return events
    }

    func testProbePasswordCapableDashboardWithoutCredentialsNeverAttemptsLogin() async {
        // THE Round-5.1 invariant: a password-capable dashboard plus missing
        // credentials performs EXACTLY ONE provider-discovery request and
        // ZERO password-login and ws-ticket requests. An empty-credential
        // login would be a real, rate-limited authentication attempt against
        // a connection that may already be known to work.
        let host = "probe-success.example"
        let events = await runProbeWithCredentials("https://\(host)", username: "", password: "")
        XCTAssertEqual(events, Array(StagedTestDriver.successEvents.prefix(5)) + [
            .requiresCredentials(.authentication)
        ])
        XCTAssertEqual(SetupProbeURLProtocol.requestCount(forPath: "/api/auth/providers", host: host), 1)
        XCTAssertEqual(
            SetupProbeURLProtocol.requestCount(forPath: "/auth/password-login", host: host), 0,
            "No password-login request may occur without present credentials"
        )
        XCTAssertEqual(
            SetupProbeURLProtocol.requestCount(forPath: "/api/auth/ws-ticket", host: host), 0,
            "No ticket mint may occur without present credentials"
        )
    }

    func testProbeWhitespaceOnlyCredentialsAlsoStopAtCredentialsRequired() async {
        // Presence, not content: whitespace-only credentials are as unusable
        // as empty ones, and neither is ever sent.
        let host = "probe-success.example"
        let events = await runProbeWithCredentials("https://\(host)", username: " ", password: " ")
        XCTAssertEqual(events, Array(StagedTestDriver.successEvents.prefix(5)) + [
            .requiresCredentials(.authentication)
        ])
        XCTAssertEqual(SetupProbeURLProtocol.requestCount(forPath: "/api/auth/providers", host: host), 1)
        XCTAssertEqual(SetupProbeURLProtocol.requestCount(forPath: "/auth/password-login", host: host), 0)
        XCTAssertEqual(SetupProbeURLProtocol.requestCount(forPath: "/api/auth/ws-ticket", host: host), 0)
    }

    // MARK: - Interactive sign-in outcome

    func testProbeInteractiveSignInEmitsDistinctTerminalOutcomeWithDiscoveryOnlyTraffic() async {
        // A dashboard whose edge redirects provider discovery to a sign-in
        // page has proven everything the probe can verify. The run ends in
        // the supported interactive outcome: server and dashboard succeed,
        // authentication stops at "browser sign-in required", and the probe
        // performs EXACTLY ONE request — provider discovery. No native
        // credential attempt, no ticket mint, no cookie store write.
        let events = await runProbe("https://probe-interactive.example")
        XCTAssertEqual(events, [
            .started(.server),
            .succeeded(.server),
            .started(.dashboard),
            .succeeded(.dashboard),
            .started(.authentication),
            .requiresInteractiveSignIn(.authentication)
        ])
        let host = "probe-interactive.example"
        XCTAssertEqual(SetupProbeURLProtocol.requestCount(forPath: "/api/auth/providers", host: host), 1)
        XCTAssertEqual(
            SetupProbeURLProtocol.requestCount(forPath: "/auth/password-login", host: host), 0,
            "Interactive-auth discovery must never attempt password login"
        )
        XCTAssertEqual(
            SetupProbeURLProtocol.requestCount(forPath: "/api/auth/ws-ticket", host: host), 0,
            "Interactive-auth discovery must never mint a ticket"
        )
        let jarCookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://\(host)/")!) ?? []
        XCTAssertTrue(jarCookies.isEmpty, "The probe commits nothing, interactive outcome included")
    }

    func testProbeProviderLess200IsUnexpectedServerResponseNotInteractive() async {
        // A 200 with a valid but empty providers array is recognizable
        // Hermes structure with no password capability: an unexpected server
        // response for the probe, never the interactive-auth outcome.
        let events = await runProbe("https://probe-empty-providers.example")
        XCTAssertEqual(events, [
            .started(.server),
            .succeeded(.server),
            .started(.dashboard),
            .failed(.dashboard, .unexpectedServerResponse)
        ])
    }

    func testProbeNativeOAuthOnlyDashboardRequiresApprovedInteractiveSignIn() async {
        let host = "probe-native-oauth.example"
        let events = await runProbe("https://\(host)")
        XCTAssertEqual(events, [
            .started(.server),
            .succeeded(.server),
            .started(.dashboard),
            .succeeded(.dashboard),
            .started(.authentication),
            .requiresInteractiveSignIn(.authentication),
        ])
        XCTAssertEqual(SetupProbeURLProtocol.requestCount(forPath: "/api/auth/providers", host: host), 1)
        XCTAssertEqual(SetupProbeURLProtocol.requestCount(forPath: "/api/status", host: host), 1)
        XCTAssertEqual(SetupProbeURLProtocol.requestCount(forPath: "/auth/password-login", host: host), 0)
        XCTAssertEqual(SetupProbeURLProtocol.requestCount(forPath: "/api/auth/ws-ticket", host: host), 0)
    }

    func testProbeMalformed200IsUnexpectedServerResponseNotInteractive() async {
        // Arbitrary website content: an unexpected server response, never
        // the interactive-auth outcome.
        let events = await runProbe("https://probe-malformed.example")
        XCTAssertEqual(events, [
            .started(.server),
            .succeeded(.server),
            .started(.dashboard),
            .failed(.dashboard, .unexpectedServerResponse)
        ])
    }

    // MARK: - Side-effect freedom (spec 21)

    @MainActor
    func testSuccessfulProbePersistsNothingAndMakesExactlyOneAuthAttempt() async {
        let fixtureURL = URL(string: "https://probe-success.example/")!
        _ = await runProbe("https://probe-success.example")

        let jarCookies = HTTPCookieStorage.shared.cookies(for: fixtureURL) ?? []
        XCTAssertTrue(
            jarCookies.isEmpty,
            "The probe must never commit cookies to the shared store: \(jarCookies.map(\.name))"
        )
        XCTAssertEqual(
            SetupProbeURLProtocol.requestCount(forPath: "/auth/password-login", host: "probe-success.example"),
            1,
            "One user-requested test equals exactly one authentication attempt"
        )
        XCTAssertEqual(
            SetupProbeURLProtocol.requestCount(forPath: "/api/auth/ws-ticket", host: "probe-success.example"), 1
        )
        XCTAssertEqual(
            SetupProbeURLProtocol.requestCount(forPath: "/api/auth/providers", host: "probe-success.example"), 1
        )
    }

    // MARK: - Inherited Cloudflare token origin gate (spec 9/18)

    private func makeOriginGateFlow(
        existingServerURL: String,
        origin: String,
        access: CloudflareAccessCredentials?
    ) -> ConnectionSetupFlow {
        ConnectionSetupFlow(
            entry: .credentials,
            draft: ConnectionSetupDraft(
                existingServerURL: existingServerURL,
                username: "probe-user",
                password: "in-memory-fixture"
            ),
            inheritedCloudflareAccess: access,
            inheritedCloudflareOriginURL: origin
        )
    }

    func testInheritedCloudflareTokenIsUsedOnlySameOrigin() {
        let token = CloudflareAccessCredentials(clientID: "gate-client-id", clientSecret: "gate-client-secret")
        let address = "https://hermes.example:9443"

        // Same origin (including an added path prefix): token applies.
        let sameOrigin = makeOriginGateFlow(existingServerURL: address, origin: address, access: token)
        XCTAssertEqual(sameOrigin.cloudflareAccessForDraft(), token)
        let pathPrefixed = makeOriginGateFlow(
            existingServerURL: "\(address)/hermes", origin: address, access: token
        )
        XCTAssertEqual(pathPrefixed.cloudflareAccessForDraft(), token)

        // A different host, scheme, or effective port never receives it.
        let otherHost = makeOriginGateFlow(existingServerURL: address, origin: "https://other.example:9443", access: token)
        XCTAssertNil(otherHost.cloudflareAccessForDraft())
        let otherScheme = makeOriginGateFlow(existingServerURL: address, origin: "http://hermes.example:9443", access: token)
        XCTAssertNil(otherScheme.cloudflareAccessForDraft())
        let otherPort = makeOriginGateFlow(existingServerURL: address, origin: "https://hermes.example", access: token)
        XCTAssertNil(otherPort.cloudflareAccessForDraft())

        // No recorded origin, or an unconfigured token: nothing is sent.
        let noOrigin = makeOriginGateFlow(existingServerURL: address, origin: "", access: token)
        XCTAssertNil(noOrigin.cloudflareAccessForDraft())
        let unconfigured = makeOriginGateFlow(
            existingServerURL: address, origin: address,
            access: CloudflareAccessCredentials(clientID: "  ", clientSecret: "")
        )
        XCTAssertNil(unconfigured.cloudflareAccessForDraft())
        let noToken = makeOriginGateFlow(existingServerURL: address, origin: address, access: nil)
        XCTAssertNil(noToken.cloudflareAccessForDraft())
    }

    func testEditingTheDraftAwayFromTheTokenOriginDropsTheToken() {
        let token = CloudflareAccessCredentials(clientID: "gate-client-id", clientSecret: "gate-client-secret")
        var flow = makeOriginGateFlow(
            existingServerURL: "https://hermes.example:9443", origin: "https://hermes.example:9443", access: token
        )
        XCTAssertEqual(flow.cloudflareAccessForDraft(), token)

        // The user edits the dashboard address inside the wizard: the token
        // must not follow it to the new origin.
        flow.draft.existingServerURL = "https://elsewhere.example:9443"
        XCTAssertNil(flow.cloudflareAccessForDraft(), "A service token is never sent cross-origin")
    }
}

// MARK: - URLProtocol stub (fixture hosts disjoint from NativeAuthClientTests)

private final class SetupProbeURLProtocol: URLProtocol {
    private struct ResponseRecord {
        let host: String
        let statusCode: Int?
        let headers: [String: String]
    }

    private static let lock = NSLock()
    private static var responseRecords: [ResponseRecord] = []
    private static var requestRecords: [URLRequest] = []

    private static let fixtureHosts: Set<String> = [
        "probe-success.example",
        "probe-dns.example",
        "probe-refused.example",
        "probe-timeout.example",
        "probe-tls.example",
        "probe-tlsdate.example",
        "probe-tlsfailure.example",
        "probe-5xx.example",
        "probe-foreign.example",
        "probe-auth401.example",
        "probe-auth429.example",
        "probe-cookieless.example",
        "probe-cfreject.example",
        "probe-hang.example",
        "probe-interactive.example",
        "probe-native-oauth.example",
        "probe-empty-providers.example",
        "probe-malformed.example"
    ]

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return fixtureHosts.contains(host)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.record(request: request)
        if url.host == "probe-hang.example" {
            // Never completes: the cancellation test cancels the task.
            return
        }
        if let transportError = Self.transportError(for: url.host ?? "") {
            client?.urlProtocol(self, didFailWithError: transportError)
            return
        }
        let fixture = Self.fixture(for: request)
        Self.record(
            host: url.host ?? "",
            statusCode: fixture?.statusCode,
            headers: fixture?.headers ?? [:]
        )
        guard let fixture,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: fixture.statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: fixture.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    // MARK: - Inspection

    /// Clears all recorded traffic so per-test exact-count assertions are
    /// independent of execution order.
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        responseRecords.removeAll()
        requestRecords.removeAll()
    }

    static func requestCount(forPath path: String, host: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestRecords.filter { $0.url?.path == path && $0.url?.host == host }.count
    }

    static func requestHeader(forPath path: String, name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return requestRecords.last(where: { $0.url?.path == path })?.value(forHTTPHeaderField: name)
    }

    private static func record(request: URLRequest) {
        lock.lock()
        requestRecords.append(request)
        lock.unlock()
    }

    private static func record(host: String, statusCode: Int?, headers: [String: String]) {
        lock.lock()
        responseRecords.append(ResponseRecord(host: host, statusCode: statusCode, headers: headers))
        lock.unlock()
    }

    // MARK: - Fixtures

    private static func transportError(for host: String) -> URLError? {
        switch host {
        case "probe-dns.example": return URLError(.cannotFindHost)
        case "probe-refused.example": return URLError(.cannotConnectToHost)
        case "probe-timeout.example": return URLError(.timedOut)
        case "probe-tls.example": return URLError(.serverCertificateUntrusted)
        case "probe-tlsdate.example": return URLError(.serverCertificateHasBadDate)
        case "probe-tlsfailure.example": return URLError(.secureConnectionFailed)
        default: return nil
        }
    }

    private struct Fixture {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    private static func fixture(for request: URLRequest) -> Fixture? {
        guard let host = request.url?.host else { return nil }
        let providers = Fixture(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"providers":[{"name":"basic","supports_password":true}]}"#.utf8)
        )
        let acceptedLogin = Fixture(
            statusCode: 200,
            headers: [
                "Content-Type": "application/json",
                "Set-Cookie": "hermes_session_at=probe-session-token; Path=/; HttpOnly"
            ],
            body: Data(#"{"ok":true}"#.utf8)
        )
        let ticket = Fixture(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"ticket":"probe-ticket"}"#.utf8)
        )

        switch host {
        case "probe-success.example":
            switch request.url?.path {
            case "/api/auth/providers": return providers
            case "/auth/password-login": return acceptedLogin
            case "/api/auth/ws-ticket": return ticket
            default: return nil
            }
        case "probe-native-oauth.example":
            switch request.url?.path {
            case "/api/auth/providers":
                return Fixture(
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"providers":[{"name":"google","supports_password":false}]}"#.utf8)
                )
            case "/api/status":
                return Fixture(
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"auth_flows":["native_pkce"]}"#.utf8)
                )
            default: return nil
            }
        case "probe-cookieless.example":
            switch request.url?.path {
            case "/api/auth/providers": return providers
            case "/auth/password-login":
                // Only a foreign-domain cookie: exact-host acceptance drops it.
                return Fixture(
                    statusCode: 200,
                    headers: [
                        "Content-Type": "application/json",
                        "Set-Cookie": "foreign_session=unusable; Domain=probe-foreign-domain.invalid; Path=/"
                    ],
                    body: Data(#"{"ok":true}"#.utf8)
                )
            default: return nil
            }
        case "probe-auth401.example":
            switch request.url?.path {
            case "/api/auth/providers": return providers
            case "/auth/password-login":
                return Fixture(
                    statusCode: 401,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"detail":"Invalid credentials"}"#.utf8)
                )
            default: return nil
            }
        case "probe-auth429.example":
            switch request.url?.path {
            case "/api/auth/providers": return providers
            case "/auth/password-login":
                return Fixture(
                    statusCode: 429,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"detail":"Too many attempts"}"#.utf8)
                )
            default: return nil
            }
        case "probe-5xx.example":
            return Fixture(
                statusCode: 500,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"origin unavailable"}"#.utf8)
            )
        case "probe-foreign.example":
            // An arbitrary website: 200 with HTML, no Hermes providers.
            return Fixture(
                statusCode: 200,
                headers: ["Content-Type": "text/html"],
                body: Data("<html><body>not hermes</body></html>".utf8)
            )
        case "probe-cfreject.example":
            return Fixture(
                statusCode: 302,
                headers: ["Location": "https://probe-tenant.cloudflareaccess.com/cdn-cgi/access/login"],
                body: Data()
            )
        case "probe-interactive.example":
            // The unauthenticated interactive-auth signal: the edge bounces
            // provider discovery to a sign-in page (cross-origin, so the
            // redirect delegate cancels it and the 302 is the final answer).
            return Fixture(
                statusCode: 302,
                headers: ["Location": "https://sso.probe-interactive.example/signin"],
                body: Data()
            )
        case "probe-empty-providers.example":
            // Valid Hermes provider JSON with zero providers: recognizable
            // structure, never the interactive-auth signal.
            return Fixture(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"providers":[]}"#.utf8)
            )
        case "probe-malformed.example":
            // Arbitrary website content answered 200.
            return Fixture(
                statusCode: 200,
                headers: ["Content-Type": "text/html"],
                body: Data("<html><body>not hermes</body></html>".utf8)
            )
        default:
            return nil
        }
    }
}
