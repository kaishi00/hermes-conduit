//
//  ConnectionSetupFlowTests.swift
//  Conduit
//
//  Routing and safety coverage for the guided Connection Setup wizard model:
//  destination entry points, question transitions, access-method branches,
//  back navigation, and the Ask Hermes prompt safety phrases.
//

import XCTest
@testable import Conduit

final class ConnectionSetupFlowTests: XCTestCase {
    func testBranchConfirmationOpensRealConnectionDetails() {
        var flow = ConnectionSetupFlow(entry: .network)
        flow.selectAccessMethod(.lan)
        flow.confirmDetailsReady()
        XCTAssertEqual(String(describing: flow.step), "connectionDetails")
    }

    func testDiscoveryFirstDetailsCredentialsReviewAndTypedResultPreserveBackEdits() throws {
        var flow = ConnectionSetupFlow(entry: .network)
        flow.selectAccessMethod(.lan)
        flow.confirmDetailsReady()
        flow.submitDetails()
        XCTAssertEqual(flow.step, .connectionDetails)
        XCTAssertNotNil(flow.validationError)
        flow.draft.lan.host = "192.168.1.28"
        flow.draft.lan.port = "9119"
        flow.submitDetails()
        XCTAssertEqual(flow.step, .connectionTest, "The address alone reaches the test: discovery decides whether a password applies")

        // Discovery proves a password dashboard; only now are credentials
        // asked for, and the credentials step takes the spent test's place.
        let generation = try XCTUnwrap(flow.beginTest())
        for event in StagedTestDriver.successEvents.prefix(5) {
            flow.applyTestEvent(event, generation: generation)
        }
        flow.applyTestEvent(.requiresCredentials(.authentication), generation: generation)
        flow.editAfterFailedTest(.loginCredentials)
        XCTAssertEqual(flow.step, .loginCredentials)
        flow.submitCredentials()
        XCTAssertEqual(flow.step, .loginCredentials, "Once a password is known to apply, the step asks for both fields")
        XCTAssertEqual(flow.validationError, .credentialsRequired)
        flow.draft.username = "eric"
        flow.draft.password = "in-memory-fixture"
        flow.submitCredentials()
        XCTAssertEqual(flow.step, .connectionTest, "Credentials now lead to the staged connection test")
        StagedTestDriver.runSuccessfulTest(on: &flow)
        XCTAssertEqual(flow.step, .review)
        flow.back()
        XCTAssertEqual(flow.step, .connectionTest)
        flow.back()
        XCTAssertEqual(flow.step, .loginCredentials)
        XCTAssertTrue(flow.draft.password == "in-memory-fixture")
        flow.back()
        XCTAssertEqual(flow.step, .connectionDetails, "Back from the credentials step returns to the address, not a spent test")
        XCTAssertEqual(flow.draft.lan.port, "9119")
        flow.draft.lan.port = "9120"
        flow.submitDetails()
        XCTAssertEqual(flow.step, .loginCredentials, "Typed credentials are shown again before they are sent to the edited address")
        flow.submitCredentials()
        XCTAssertEqual(flow.step, .connectionTest)
        StagedTestDriver.runSuccessfulTest(on: &flow)
        let result = try XCTUnwrap(flow.complete())
        XCTAssertEqual(result.serverURL, "http://192.168.1.28:9120")
        XCTAssertEqual(result.username, "eric")
        XCTAssertTrue(result.password == "in-memory-fixture")
        XCTAssertEqual(flow.step, .review, "Completion only returns values; the caller owns dismissal")
        flow.draft.lan.port = "0"
        XCTAssertNil(flow.complete(), "Handoff must revalidate, not return a stale reviewed result")
    }

    func testRouteChangesKeepIndependentDraftsAndNeverReuseIncompatibleInputs() throws {
        var flow = ConnectionSetupFlow(entry: .network)
        flow.selectAccessMethod(.lan)
        flow.draft.lan.host = "192.168.1.28"
        flow.draft.lan.port = "9119"
        flow.back()
        flow.selectAccessMethod(.reverseProxy)
        XCTAssertThrowsError(try ConnectionSetupAddressBuilder.build(flow.draft))
        flow.draft.reverseProxyURL = "https://example.com/hermes"
        XCTAssertEqual(try ConnectionSetupAddressBuilder.build(flow.draft), "https://example.com/hermes")
        flow.back()
        flow.selectAccessMethod(.tailscale)
        XCTAssertTrue(flow.draft.tailscale.host.isEmpty)
        XCTAssertTrue(flow.draft.tailscale.port.isEmpty)
        flow.back()
        flow.selectAccessMethod(.lan)
        XCTAssertEqual(try ConnectionSetupAddressBuilder.build(flow.draft), "http://192.168.1.28:9119")
    }

    func testAuthenticationRecoveryReusesExpertAddressAndSkippedAnswersRemainUnknown() throws {
        var flow = ConnectionSetupFlow(entry: .credentials, draft: ConnectionSetupDraft(
            existingServerURL: "https://example.com:9443/hermes", username: "eric", password: "fixture"
        ))
        flow.answerCredentials(.yes)
        XCTAssertEqual(flow.step, .loginCredentials)
        flow.draft.password = "updated-fixture"
        flow.submitCredentials()
        XCTAssertEqual(flow.step, .connectionTest)
        StagedTestDriver.runSuccessfulTest(on: &flow)
        XCTAssertEqual(try XCTUnwrap(flow.complete()).serverURL, "https://example.com:9443/hermes")
        XCTAssertNil(flow.dashboardAnswer)
        XCTAssertNil(flow.accessMethod)
    }

    func testInvalidSeededAddressRoutesToEditableFullURLAndCanRecover() throws {
        var flow = ConnectionSetupFlow(entry: .credentials, draft: ConnectionSetupDraft(
            existingServerURL: "http://remote.example/hermes", username: "eric", password: "fixture"
        ))
        flow.answerCredentials(.yes)
        flow.submitCredentials()
        XCTAssertEqual(flow.step, .connectionDetails)
        XCTAssertTrue(flow.draft.usesExistingAddress)
        XCTAssertEqual(flow.validationError, .policy(.insecureTransport))
        flow.draft.existingServerURL = "https://remote.example/hermes"
        flow.submitDetails()
        flow.submitCredentials()
        XCTAssertEqual(flow.step, .connectionTest)
        StagedTestDriver.runSuccessfulTest(on: &flow)
        XCTAssertEqual(try XCTUnwrap(flow.complete()).serverURL, "https://remote.example/hermes")
    }

    func testNetworkRecoveryCanEditExistingURLOrChooseFreshRoute() throws {
        var flow = ConnectionSetupFlow(entry: .network, draft: ConnectionSetupDraft(
            existingServerURL: "https://example.com:9443/prefix", username: "eric", password: "fixture"
        ))
        flow.useExistingAddress()
        XCTAssertEqual(flow.step, .connectionDetails)
        XCTAssertEqual(try ConnectionSetupAddressBuilder.build(flow.draft), "https://example.com:9443/prefix")
        flow.back()
        flow.selectAccessMethod(.lan)
        XCTAssertFalse(flow.draft.usesExistingAddress)
        XCTAssertThrowsError(try ConnectionSetupAddressBuilder.build(flow.draft))
        XCTAssertNil(flow.complete(), "Only Review can hand off a configuration")
    }
    // MARK: - Entry destinations

    func testManualEntryBeginsAtDashboard() {
        XCTAssertEqual(ConnectionSetupFlow(entry: .start).step, .dashboard)
    }

    func testFailureDestinationsMapToSensibleWizardEntries() {
        XCTAssertEqual(ConnectionSetupFlow.entryStep(for: .start), .dashboard)
        XCTAssertEqual(ConnectionSetupFlow.entryStep(for: .dashboard), .dashboard)
        XCTAssertEqual(ConnectionSetupFlow.entryStep(for: .credentials), .credentials)
        XCTAssertEqual(ConnectionSetupFlow.entryStep(for: .network), .accessMethod)
        XCTAssertEqual(ConnectionSetupFlow.entryStep(for: .tls), .tlsTroubleshooting)
        XCTAssertEqual(ConnectionSetupFlow.entryStep(for: .cloudflare), .cloudflareTroubleshooting)
        XCTAssertEqual(ConnectionSetupFlow.entryStep(for: .currentConnection), .connectionDetails)
    }

    func testTLSAndCloudflareEntriesOpenTroubleshootingDirectly() {
        XCTAssertEqual(ConnectionSetupFlow(entry: .tls).step, .tlsTroubleshooting)
        XCTAssertEqual(ConnectionSetupFlow(entry: .cloudflare).step, .cloudflareTroubleshooting)
    }

    // MARK: - Core question transitions

    func testDashboardYesAdvancesToAccessMethodWithoutACredentialsQuestion() {
        var flow = ConnectionSetupFlow(entry: .start)
        flow.answerDashboard(.yes)
        XCTAssertEqual(flow.step, .accessMethod, "First run never asks about credentials before discovery")
        XCTAssertEqual(flow.dashboardAnswer, .yes)
        XCTAssertNil(flow.credentialsAnswer)
    }

    func testFreshFirstRunReachesTheConnectionTestWithEmptyCredentials() throws {
        // The fixture-matrix row: a fresh first-run with only an address
        // reaches discovery (the staged test) without a credentials screen.
        var flow = ConnectionSetupFlow(entry: .start)
        flow.answerDashboard(.yes)
        flow.selectAccessMethod(.reverseProxy)
        flow.confirmDetailsReady()
        flow.draft.reverseProxyURL = "https://dashboard.example.test/hermes"
        flow.submitDetails()
        XCTAssertEqual(flow.step, .connectionTest)
        XCTAssertFalse(flow.path.contains(.loginCredentials))
        XCTAssertFalse(flow.path.contains(.credentials))
        let configuration = try flow.draft.testConfiguration()
        XCTAssertEqual(configuration.serverURL, "https://dashboard.example.test/hermes")
        XCTAssertFalse(configuration.hasUsableCredentials, "The probe stops at Credentials required; it never sends an empty login")
    }

    func testDashboardNoAndUnknownStayWithGuidanceUntilConfirmedReady() {
        var flow = ConnectionSetupFlow(entry: .start)
        flow.answerDashboard(.no)
        XCTAssertEqual(flow.step, .dashboard, "No must keep the question up with its Ask Hermes guidance")
        XCTAssertEqual(flow.dashboardAnswer, .no)

        flow.confirmDashboardReady()
        XCTAssertEqual(flow.step, .accessMethod)
        XCTAssertEqual(
            flow.dashboardAnswer, .no,
            "Confirming readiness is navigation — it must not rewrite the recorded answer to Yes"
        )
    }

    func testAnswerSurvivesConfirmAndBackRoundTrip() {
        // Answer No, confirm ready, go Back: the recorded answer and its
        // Ask Hermes guidance state must be exactly what the user said.
        var flow = ConnectionSetupFlow(entry: .start)
        flow.answerDashboard(.no)
        flow.confirmDashboardReady()
        flow.back()
        XCTAssertEqual(flow.step, .dashboard)
        XCTAssertEqual(flow.dashboardAnswer, .no, "Back must restore the original No answer, not a fabricated Yes")

        // Re-confirming from the restored state advances cleanly again.
        flow.confirmDashboardReady()
        XCTAssertEqual(flow.step, .accessMethod)
    }

    func testDashboardUnknownThenConfirmAdvances() {
        var flow = ConnectionSetupFlow(entry: .start)
        flow.answerDashboard(.unknown)
        XCTAssertEqual(flow.step, .dashboard)
        flow.confirmDashboardReady()
        XCTAssertEqual(flow.step, .accessMethod)
    }

    func testCredentialsNoAndUnknownStayWithGuidanceUntilConfirmedReady() {
        // The credentials question belongs to authentication recovery (a
        // rejected password proved the dashboard uses one).
        var flow = ConnectionSetupFlow(entry: .credentials)
        flow.answerCredentials(.no)
        XCTAssertEqual(flow.step, .credentials)
        XCTAssertEqual(flow.credentialsAnswer, .no)

        flow.confirmCredentialsReady()
        XCTAssertEqual(flow.step, .accessMethod)
        XCTAssertEqual(
            flow.credentialsAnswer, .no,
            "Confirming readiness is navigation — it must not rewrite the recorded answer to Yes"
        )
    }

    func testRepeatedConfirmationsAreIdempotent() {
        var flow = ConnectionSetupFlow(entry: .start)
        flow.answerDashboard(.yes)
        flow.answerDashboard(.yes)
        flow.selectAccessMethod(.lan)
        flow.confirmDetailsReady()
        XCTAssertEqual(flow.step, .connectionDetails)
        // Double-taps on a continue/confirm button must not push duplicates.
        flow.confirmDetailsReady()
        flow.confirmDetailsReady()
        XCTAssertEqual(flow.step, .connectionDetails)
        XCTAssertEqual(flow.path.count, 4, "Path must stay entry step + one entry per real navigation")
    }

    func testEntryAtCredentialsSkipsDashboardQuestion() {
        var flow = ConnectionSetupFlow(entry: .credentials)
        XCTAssertEqual(flow.step, .credentials)
        flow.answerCredentials(.yes)
        XCTAssertEqual(flow.step, .accessMethod)
        XCTAssertNil(flow.dashboardAnswer, "Entering mid-wizard must not invent answers for skipped questions")
    }

    // MARK: - Access methods

    func testAccessMethodChoicesRouteToTheirBranches() {
        for (method, expectedStep) in [
            (ConnectionAccessMethod.lan, ConnectionSetupStep.lan),
            (ConnectionAccessMethod.tailscale, ConnectionSetupStep.tailscale),
            (ConnectionAccessMethod.reverseProxy, ConnectionSetupStep.reverseProxy)
        ] {
            var flow = ConnectionSetupFlow(entry: .start)
            flow.answerDashboard(.yes)
            flow.selectAccessMethod(method)
            XCTAssertEqual(flow.step, expectedStep, "\(method) must route to \(expectedStep)")
            XCTAssertEqual(flow.accessMethod, method)
        }
    }

    func testSupportedMethodSetIsExactlyTheSafeThree() {
        // Closed set: LAN, Tailscale, existing reverse proxy. There is no
        // public-IP/open-port method anywhere in the model.
        XCTAssertEqual(
            Set(ConnectionAccessMethod.allCases),
            [.lan, .tailscale, .reverseProxy]
        )
    }

    func testDetailsReadyFollowsBranchConfirmation() {
        var flow = ConnectionSetupFlow(entry: .start)
        flow.answerDashboard(.yes)
        flow.selectAccessMethod(.tailscale)
        flow.confirmDetailsReady()
        XCTAssertEqual(flow.step, .connectionDetails)
    }

    // MARK: - Back navigation

    func testBackWalksThePathWithoutLosingEntryStep() {
        var flow = ConnectionSetupFlow(entry: .start)
        XCTAssertFalse(flow.canGoBack, "The entry step has nowhere to go back to")
        flow.back()
        XCTAssertEqual(flow.step, .dashboard, "Back on the entry step must be a no-op")

        flow.answerDashboard(.yes)
        flow.selectAccessMethod(.tailscale)
        XCTAssertTrue(flow.canGoBack)

        flow.back()
        XCTAssertEqual(flow.step, .accessMethod)
        flow.back()
        XCTAssertEqual(flow.step, .dashboard)
        XCTAssertFalse(flow.canGoBack)
    }

    // MARK: - Troubleshooting topic switching

    func testTroubleshootingTopicsReplaceEachOtherInsteadOfStacking() {
        // A topic switch is replacement, not navigation: flipping TLS ⇄
        // Cloudflare repeatedly must never grow the back path.
        var flow = ConnectionSetupFlow(entry: .tls)
        flow.showTroubleshooting(.cloudflare)
        XCTAssertEqual(flow.step, .cloudflareTroubleshooting)
        XCTAssertEqual(flow.path.count, 1)
        XCTAssertFalse(flow.canGoBack, "Back after a topic replacement leaves troubleshooting entirely")
        flow.showTroubleshooting(.tls)
        XCTAssertEqual(flow.step, .tlsTroubleshooting)
        XCTAssertEqual(flow.path.count, 1)
        flow.showTroubleshooting(.tls)
        XCTAssertEqual(flow.step, .tlsTroubleshooting, "Same-topic switch is a no-op")
    }

    func testWizardDestinationsDoNotJumpOutOfTheQuestionSequence() {
        // The troubleshooting switch is only for the tls/cloudflare surfaces;
        // it must not be usable to skip straight to branches.
        var flow = ConnectionSetupFlow(entry: .start)
        flow.showTroubleshooting(.network)
        XCTAssertEqual(flow.step, .dashboard)
    }

    // MARK: - Progress labeling

    func testProgressLabelsCoverTheTwoFirstRunQuestions() {
        XCTAssertEqual(ConnectionSetupFlow(entry: .start).progressLabel, "Step 1 of 2")
        // The bar has a segment per numbered question and fills to the label.
        XCTAssertEqual(ConnectionSetupFlow.progressStepCount, 2)
        XCTAssertEqual(ConnectionSetupFlow(entry: .start).progressStep, 1)

        var flow = ConnectionSetupFlow(entry: .start)
        flow.answerDashboard(.yes)
        XCTAssertEqual(flow.progressLabel, "Step 2 of 2")
        XCTAssertEqual(flow.progressStep, 2)

        flow.selectAccessMethod(.lan)
        XCTAssertNil(flow.progressLabel, "Branch screens sit outside the numbered question sequence")
        XCTAssertNil(flow.progressStep)
        XCTAssertNil(ConnectionSetupFlow(entry: .credentials).progressStep)

        // Non-question entries are unnumbered too, including the
        // authentication-recovery credentials question.
        XCTAssertNil(ConnectionSetupFlow(entry: .tls).progressLabel)
        XCTAssertNil(ConnectionSetupFlow(entry: .cloudflare).progressLabel)
        XCTAssertNil(ConnectionSetupFlow(entry: .credentials).progressLabel)
        var detailsFlow = ConnectionSetupFlow(entry: .start)
        detailsFlow.answerDashboard(.yes)
        detailsFlow.selectAccessMethod(.lan)
        detailsFlow.confirmDetailsReady()
        XCTAssertNil(detailsFlow.progressLabel)
    }

    // MARK: - Step-gated confirmations

    func testDashboardReadyConfirmationIsStepGated() {
        var flow = ConnectionSetupFlow(entry: .start)
        flow.confirmDashboardReady()
        XCTAssertEqual(flow.step, .accessMethod, "The legitimate call from the dashboard step advances")
        XCTAssertEqual(flow.path.count, 2)

        // A stray call from any other step must be a deterministic no-op.
        flow.confirmDashboardReady()
        XCTAssertEqual(flow.step, .accessMethod)
        XCTAssertEqual(flow.path.count, 2, "Stray confirmDashboardReady calls must not mutate the path")

        flow.selectAccessMethod(.lan)
        let before = flow.path
        flow.confirmDashboardReady()
        XCTAssertEqual(flow.path, before)
    }

    func testReviewStateRevalidatesPurelyForRendering() throws {
        var flow = ConnectionSetupFlow(entry: .network)
        flow.selectAccessMethod(.lan)
        flow.confirmDetailsReady()
        flow.draft.lan.host = "192.168.1.28"
        flow.draft.lan.port = "9119"
        flow.draft.username = "eric"
        flow.draft.password = "fixture"
        flow.submitDetails()
        flow.submitCredentials()
        XCTAssertEqual(flow.step, .connectionTest)
        StagedTestDriver.runSuccessfulTest(on: &flow)
        XCTAssertEqual(flow.step, .review)

        guard case .success(let result) = flow.reviewState() else {
            return XCTFail("A complete draft must revalidate at Review")
        }
        XCTAssertEqual(result.serverURL, "http://192.168.1.28:9119")
        XCTAssertEqual(flow.step, .review)

        // A draft that stops validating after reaching Review must surface a
        // typed failure the Review card can render, not silently blank it.
        flow.draft.password = " "
        guard case .failure(let error) = flow.reviewState() else {
            return XCTFail("An incomplete draft must fail Review revalidation")
        }
        XCTAssertEqual(error, .credentialsRequired)
        XCTAssertEqual(error.message, ConnectionSetupValidationError.credentialsRequired.message)
        XCTAssertEqual(flow.step, .review)
        XCTAssertEqual(flow.path.count, 6, "Render-time revalidation must never mutate the path")
        XCTAssertNil(flow.validationError, "Render-time revalidation is pure and records nothing")
        XCTAssertFalse(flow.hasCurrentSuccessfulTest, "The edit also invalidates the staged test")
    }

    // MARK: - Ask Hermes prompt safety

    func testEveryPromptPreservesDashboardAuthentication() {
        for prompt in ConnectionSetupPrompt.allCases {
            let text = prompt.text.lowercased()
            XCTAssertTrue(
                text.contains("authentication"),
                "\(prompt) prompt never mentions authentication: \(prompt.text)"
            )
            XCTAssertTrue(
                text.contains("enabled") || text.contains("disable") || text.contains("requires authentication"),
                "\(prompt) prompt must explicitly ask Hermes to keep authentication on: \(prompt.text)"
            )
        }
    }

    func testTailscalePromptReferencesTailscaleServe() {
        XCTAssertTrue(
            ConnectionSetupPrompt.tailscaleServe.text.contains("Tailscale Serve"),
            "The Tailscale branch prompt must include the Tailscale Serve configuration path"
        )
    }

    func testLANPromptRequestsAnIPAddressNotAHostname() {
        // LAN entry is IP-address-only: canonical transport policy rejects
        // local hostnames (hermes.local, hermes.home.arpa), so neither the
        // prompt nor the wizard copy may promise them.
        let prompt = ConnectionSetupPrompt.lanDetails.text.lowercased()
        XCTAssertTrue(prompt.contains("ip address"), "The LAN prompt must request the machine's local IP address: \(prompt)")
        XCTAssertFalse(prompt.contains("hostname"), "The LAN prompt must not promise hostname support: \(prompt)")
    }

    func testNoPromptRequestsPublicExposureOrHardCodedPorts() {
        let forbidden = ["public internet", "port forward", "port-forward", "firewall", "expose", "8080", "9119", "443"]
        for prompt in ConnectionSetupPrompt.allCases {
            let text = prompt.text.lowercased()
            for phrase in forbidden {
                XCTAssertFalse(
                    text.contains(phrase),
                    "\(prompt) prompt must not contain '\(phrase)': \(prompt.text)"
                )
            }
        }
    }

    func testGuidanceMethodLabelsContainNoExposureLanguage() {
        // The shipped card titles come from the model's displayTitle — the
        // same strings the wizard renders — so this guards real copy, not
        // local literals.
        let labels = ConnectionAccessMethod.allCases.map { $0.displayTitle }
        XCTAssertEqual(labels.count, 3)
        for label in labels {
            let lowered = label.lowercased()
            XCTAssertFalse(lowered.contains("public"))
            XCTAssertFalse(lowered.contains("open port"))
        }
    }
}
