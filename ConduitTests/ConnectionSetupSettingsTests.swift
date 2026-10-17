//
//  ConnectionSetupSettingsTests.swift
//  Conduit
//
//  Round 5: the Settings current-connection entry into the Connection Setup
//  wizard. Covers the semantic entry destination (question-free, seeded from
//  the current configuration), the interactive-auth path that must never be
//  blocked by meaningless password fields, the unchanged-settings Done offer,
//  cancel safety, and the pure apply plan whose writes never touch the live
//  connection.
//

import XCTest
@testable import Conduit

final class ConnectionSetupSettingsTests: XCTestCase {
    private let currentURL = "https://hermes.example:9443/hermes"

    private func seededFlow(password: String) -> ConnectionSetupFlow {
        ConnectionSetupFlow(
            entry: .currentConnection,
            draft: ConnectionSetupDraft(
                existingServerURL: currentURL,
                username: password.isEmpty ? "" : "eric",
                password: password
            )
        )
    }

    // MARK: - Entry destinations

    func testEntryStepMappingForCurrentConnection() {
        XCTAssertEqual(ConnectionSetupFlow.entryStep(for: .currentConnection), .connectionDetails)
        XCTAssertEqual(
            ConnectionSetupFlow(entry: .currentConnection, draft: ConnectionSetupDraft(
                existingServerURL: currentURL, username: "eric", password: "fixture"
            )).step,
            .connectionDetails
        )
    }

    func testCredentialsUnavailableEntryOpensTheStagedTestDirectly() {
        // Both credential fields empty means credentials are simply
        // UNAVAILABLE to the wizard — never an authentication mode. Provider
        // discovery runs without credentials and decides the auth mode, so
        // the wizard opens straight on the staged test. Never park the user
        // on a meaningless password field, and never make an
        // already-connected user answer the first-run readiness questions.
        let flow = ConnectionSetupFlow(
            entry: .currentConnection,
            draft: ConnectionSetupDraft(existingServerURL: currentURL)
        )
        XCTAssertEqual(flow.step, .connectionTest)
        XCTAssertTrue(flow.enteredFromCurrentConnection)
        XCTAssertNil(flow.progressLabel, "The Settings entry sits outside the numbered first-run sequence")
        XCTAssertTrue(flow.canGoBack, "Back from the test must reach an editable address")
        var editable = flow
        editable.back()
        XCTAssertEqual(editable.step, .connectionDetails)
    }

    func testNativeDashboardWithoutSavedCredentialsStopsAtCredentialsRequiredAndNeverLogsIn() throws {
        // THE Round-5.1 regression: an actively-connected native-password
        // user who chose not to save credentials seeds an empty draft.
        // Discovery proves a password dashboard; the staged test must stop
        // at the credentials-required partial outcome — no empty-credential
        // login attempt, no review authorization, live connection untouched.
        var flow = ConnectionSetupFlow(
            entry: .currentConnection,
            draft: ConnectionSetupDraft(existingServerURL: currentURL)
        )
        XCTAssertEqual(flow.step, .connectionTest)
        let generation = try XCTUnwrap(flow.beginTest())
        for event in StagedTestDriver.successEvents.prefix(5) {
            XCTAssertTrue(flow.applyTestEvent(event, generation: generation))
        }
        XCTAssertTrue(flow.applyTestEvent(.requiresCredentials(.authentication), generation: generation))

        XCTAssertEqual(flow.testState.server, .succeeded)
        XCTAssertEqual(flow.testState.dashboard, .succeeded)
        XCTAssertEqual(flow.testState.authentication, .requiresCredentials)
        XCTAssertTrue(flow.testState.requiresCredentials)
        XCTAssertFalse(flow.testState.allSucceeded)
        XCTAssertFalse(flow.testState.requiresInteractiveSignIn)
        XCTAssertFalse(flow.canUseSettings, "A partial test never authorizes the settings handoff")
        XCTAssertEqual(flow.step, .connectionTest, "The partial outcome stays on the test screen")
        XCTAssertNil(flow.complete())

        // Enter Credentials routes to the existing credentials step, leaving
        // the test step, which resets the partial display for a fresh run.
        flow.editAfterFailedTest(.loginCredentials)
        XCTAssertEqual(flow.step, .loginCredentials)
        XCTAssertEqual(flow.testState, ConnectionSetupTestState(), "The partial result never outlives the test step")
        XCTAssertTrue(flow.draft.usesExistingAddress, "The current URL is preserved for the retry")
    }

    func testStaleCredentialsRequiredOutcomeCannotOutliveANewerRun() throws {
        var flow = ConnectionSetupFlow(
            entry: .currentConnection,
            draft: ConnectionSetupDraft(existingServerURL: currentURL)
        )
        let staleGeneration = try XCTUnwrap(flow.beginTest())
        for event in StagedTestDriver.successEvents.prefix(5) {
            flow.applyTestEvent(event, generation: staleGeneration)
        }
        flow.applyTestEvent(.requiresCredentials(.authentication), generation: staleGeneration)
        XCTAssertTrue(flow.testState.requiresCredentials)

        // A fresh run resets the partial outcome and rotates the generation;
        // the stale run's late terminal event must be dropped entirely.
        let freshGeneration = try XCTUnwrap(flow.beginTest())
        XCTAssertNotEqual(staleGeneration, freshGeneration)
        XCTAssertEqual(flow.testState, ConnectionSetupTestState())
        XCTAssertFalse(
            flow.applyTestEvent(.requiresCredentials(.authentication), generation: staleGeneration),
            "A stale credentials-required event is ignored, not applied"
        )
        XCTAssertEqual(flow.testState.authentication, .pending)

        // The fresh run succeeds normally.
        for event in StagedTestDriver.successEvents {
            flow.applyTestEvent(event, generation: freshGeneration)
        }
        XCTAssertEqual(flow.step, .review)
        XCTAssertTrue(flow.canUseSettings)
    }

    func testFaceIDWithheldSeedLandsOnDetailsInsteadOfAnEmptyPasswordProbe() {
        // A username with a withheld (Face ID-protected) password is a NATIVE
        // deployment: the wizard must ask for the password, never open
        // straight onto a staged test that would spend an empty-credential
        // login attempt on the user's own server.
        let flow = ConnectionSetupFlow(
            entry: .currentConnection,
            draft: ConnectionSetupDraft(existingServerURL: currentURL, username: "eric", password: "")
        )
        XCTAssertEqual(flow.step, .connectionDetails)
    }

    func testUnbuildableSeedAddressFallsBackToTheDetailsEntry() {
        let flow = ConnectionSetupFlow(
            entry: .currentConnection,
            draft: ConnectionSetupDraft(existingServerURL: "not a url")
        )
        XCTAssertEqual(flow.step, .connectionDetails, "A broken address belongs on the details screen, which surfaces the validation")
    }

    // MARK: - Existing native-auth connection

    func testSeededNativeConnectionReachesTheTestWithoutRetypingAndPreservesTheExactAddress() throws {
        var flow = seededFlow(password: "fixture")
        XCTAssertEqual(flow.step, .connectionDetails)

        // Both screens are prefilled from the seeded configuration; no
        // first-run question ever appears.
        flow.submitDetails()
        XCTAssertEqual(flow.step, .loginCredentials)
        XCTAssertEqual(flow.draft.username, "eric")
        XCTAssertEqual(flow.draft.password, "fixture")
        flow.submitCredentials()
        XCTAssertEqual(flow.step, .connectionTest)

        StagedTestDriver.runSuccessfulTest(on: &flow)
        XCTAssertEqual(flow.step, .review)
        XCTAssertTrue(flow.testedSettingsUnchanged, "An untouched seeded configuration is unchanged")

        let result = try XCTUnwrap(flow.complete())
        XCTAssertEqual(
            result.serverURL, currentURL,
            "Scheme, host, port, and path prefix must all survive the round trip"
        )
    }

    func testEditedAddressIsNeverTreatedAsUnchanged() throws {
        var flow = seededFlow(password: "fixture")
        flow.draft.existingServerURL = "https://new.example/hermes"
        flow.submitDetails()
        flow.submitCredentials()
        XCTAssertEqual(flow.step, .connectionTest)
        StagedTestDriver.runSuccessfulTest(on: &flow)
        XCTAssertEqual(flow.step, .review)

        XCTAssertFalse(flow.testedSettingsUnchanged, "A deliberate edit must be applied, not dismissed as Done")
        let result = try XCTUnwrap(flow.complete())
        XCTAssertEqual(result.serverURL, "https://new.example/hermes")
    }

    // MARK: - Cancel safety

    func testBackingOutBeforeReviewCanNeverProduceAConfigurationToApply() {
        var flow = seededFlow(password: "fixture")
        flow.draft.existingServerURL = "https://new.example/hermes"
        flow.submitDetails()

        // The user dismisses the wizard here. Only Review can hand off a
        // configuration, so a cancelled edit can never persist anything.
        XCTAssertNil(flow.complete())
        XCTAssertNil(flow.validationError, "An abandoned edit leaves no error behind")
    }

    func testUnchangedDetectionRequiresACurrentTest() {
        var flow = seededFlow(password: "fixture")
        XCTAssertFalse(flow.testedSettingsUnchanged, "Untested settings are never Done-eligible")
        flow.draft.accessMethod = .reverseProxy
        XCTAssertFalse(flow.testedSettingsUnchanged)
    }

    func testLoginEntryAlwaysOffersTheSettingsHandoffEvenWhenUnchanged() throws {
        // The "Done" offer belongs to the Settings entry alone: the
        // LoginView-driven wizard keeps its normal "Use these settings"
        // handoff even when the user edited nothing.
        var flow = ConnectionSetupFlow(entry: .credentials, draft: ConnectionSetupDraft(
            existingServerURL: currentURL, username: "eric", password: "fixture"
        ))
        flow.answerCredentials(.yes)
        XCTAssertEqual(flow.step, .loginCredentials)
        flow.submitCredentials()
        StagedTestDriver.runSuccessfulTest(on: &flow)
        XCTAssertEqual(flow.step, .review)
        XCTAssertFalse(flow.testedSettingsUnchanged, "The login entry must never collapse the handoff into Done")
    }

    func testInteractiveEntryCanContinueWithEmptyCredentialsAfterEditingTheAddress() throws {
        // Edit-after-failure must not dead-end at a meaningless password
        // screen for an interactive-auth deployment: with both fields empty
        // and a buildable address, the edited address goes straight back to
        // the test, whose discovery decides.
        var flow = ConnectionSetupFlow(
            entry: .currentConnection,
            draft: ConnectionSetupDraft(existingServerURL: currentURL)
        )
        XCTAssertEqual(flow.step, .connectionTest)
        flow.back()
        XCTAssertEqual(flow.step, .connectionDetails)
        flow.draft.existingServerURL = "https://fixed.example/hermes"
        flow.submitDetails()
        XCTAssertEqual(flow.step, .connectionTest, "Empty credentials must not block the Settings interactive path")
        XCTAssertNil(flow.validationError)
    }

    func testSettingsCredentialsStepStillAcceptsBothFieldsEmpty() {
        // Settings seeded with a saved password shows it for review; clearing
        // both fields (the address now points at a browser-auth dashboard)
        // still reaches the test instead of dead-ending.
        var flow = seededFlow(password: "fixture")
        flow.submitDetails()
        XCTAssertEqual(flow.step, .loginCredentials)
        flow.draft.username = ""
        flow.draft.password = ""
        flow.submitCredentials()
        XCTAssertEqual(flow.step, .connectionTest)
        XCTAssertNil(flow.validationError)
    }

    func testCredentialsStepAsksForBothFieldsOnceAPasswordIsKnownToApply() {
        // The login card's authentication-recovery entry follows a rejected
        // password, so the dashboard is known to use one: its credentials
        // step asks for both fields. (First run never reaches this step
        // before discovery; see ConnectionSetupFlowTests.)
        var flow = ConnectionSetupFlow(entry: .credentials, draft: ConnectionSetupDraft(
            existingServerURL: currentURL
        ))
        flow.answerCredentials(.yes)
        flow.submitCredentials()
        XCTAssertEqual(flow.step, .loginCredentials)
        XCTAssertEqual(flow.validationError, .credentialsRequired)
    }

    // MARK: - Interactive auth from Settings

    func testInteractiveAuthDeploymentTestsAndCompletesWithoutAnyPassword() throws {
        // Credential absence does NOT decide the auth mode — the discovery
        // result does. A dashboard whose discovery reports interactive
        // sign-in ends in the supported terminal outcome with no login, no
        // ticket, and an address-only completion; the unchanged Settings
        // entry may offer plain Done.
        var flow = ConnectionSetupFlow(
            entry: .currentConnection,
            draft: ConnectionSetupDraft(existingServerURL: currentURL)
        )
        XCTAssertEqual(flow.step, .connectionTest)

        let generation = try XCTUnwrap(flow.beginTest())
        for event in StagedTestDriver.successEvents.dropLast(2) {
            XCTAssertTrue(flow.applyTestEvent(event, generation: generation))
        }
        XCTAssertTrue(flow.applyTestEvent(.started(.authentication), generation: generation))
        XCTAssertTrue(flow.applyTestEvent(.requiresInteractiveSignIn(.authentication, .browser(.authProxyRedirect)), generation: generation))
        XCTAssertEqual(flow.step, .review)

        XCTAssertTrue(flow.testedSettingsUnchanged, "The untouched interactive deployment is Done-eligible")
        let result = try XCTUnwrap(flow.complete())
        XCTAssertEqual(result.serverURL, currentURL, "The address-only configuration completes the handoff")
        XCTAssertTrue(result.username.isEmpty)
        XCTAssertTrue(result.password.isEmpty)
    }

    func testInteractiveOutcomeDoesNotRelaxAcceptanceForNativeSuccess() throws {
        // The credentialsRequired relaxation is bound to the interactive
        // outcome: a full native success with empty credentials is
        // impossible, and any other validation failure stays a failure.
        var flow = ConnectionSetupFlow(
            entry: .currentConnection,
            draft: ConnectionSetupDraft(existingServerURL: currentURL)
        )
        flow.draft.existingServerURL = "not a url"
        flow.draft.username = ""
        XCTAssertEqual(flow.step, .connectionTest)
        StagedTestDriver.runSuccessfulTest(on: &flow)
        XCTAssertEqual(flow.step, .review, "The staged test advanced before the address was corrupted")
        XCTAssertEqual(
            flow.reviewState(), .failure(.policy(.invalidURL)),
            "A broken address is never accepted, interactively or otherwise"
        )
        XCTAssertNil(flow.complete())
    }

    func testInheritedCloudflareTokenAppliesDuringInteractiveDiscovery() throws {
        let access = try XCTUnwrap(CloudflareAccessCredentials.from(clientID: "id", clientSecret: "secret"))
        let flow = ConnectionSetupFlow(
            entry: .currentConnection,
            draft: ConnectionSetupDraft(existingServerURL: currentURL),
            inheritedCloudflareAccess: access,
            inheritedCloudflareOriginURL: currentURL
        )
        XCTAssertEqual(try XCTUnwrap(flow.cloudflareAccessForDraft()), access,
                       "The same-origin token must reach discovery even with no credentials in the draft")
    }

    func testInheritedCloudflareTokenNeverAppliesCrossOriginWithoutCredentials() throws {
        let access = try XCTUnwrap(CloudflareAccessCredentials.from(clientID: "id", clientSecret: "secret"))
        let flow = ConnectionSetupFlow(
            entry: .currentConnection,
            draft: ConnectionSetupDraft(existingServerURL: currentURL),
            inheritedCloudflareAccess: access,
            inheritedCloudflareOriginURL: "https://other.example:9443"
        )
        XCTAssertNil(flow.cloudflareAccessForDraft(),
                     "Origin safety does not depend on credentials being present in the draft")
    }

    func testTestConfigurationPreservesTheAddressWithoutRequiringCredentials() throws {
        let draft = ConnectionSetupDraft(existingServerURL: currentURL, username: "", password: "")
        let configuration = try draft.testConfiguration()
        XCTAssertEqual(configuration.serverURL, currentURL)
        XCTAssertTrue(configuration.username.isEmpty)
        XCTAssertTrue(configuration.password.isEmpty)
        XCTAssertFalse(configuration.hasUsableCredentials)
        XCTAssertThrowsError(try draft.result(), "Full acceptance stays strict for empty credentials")

        // Presence-only: whitespace-only fields are as unusable as empty
        // ones, and the values themselves are never trimmed or rewritten.
        let padded = ConnectionSetupResult(serverURL: currentURL, username: "  ", password: "\n")
        XCTAssertFalse(padded.hasUsableCredentials)
        let present = ConnectionSetupResult(serverURL: currentURL, username: " eric ", password: " secret ")
        XCTAssertTrue(present.hasUsableCredentials)
        XCTAssertEqual(present.username, " eric ")
        XCTAssertEqual(present.password, " secret ")
    }

    // MARK: - Seeding

    func testWizardCredentialsSeedOnlyMatchingUnprotectedRecords() {
        let matching = DashboardCredentials(
            baseURL: currentURL, username: "eric", password: "fixture", requiresFaceID: false
        )
        let seeded = ConnectionSetupSeeding.wizardCredentials(for: currentURL, saved: matching)
        XCTAssertEqual(seeded?.username, "eric")
        XCTAssertEqual(seeded?.password, "fixture")

        // The same address spelled with a trailing slash still seeds: both
        // sides are compared policy-normalized.
        let trailingSlash = ConnectionSetupSeeding.wizardCredentials(
            for: currentURL + "/", saved: matching
        )
        XCTAssertEqual(trailingSlash?.username, "eric")

        let faceID = DashboardCredentials(
            baseURL: currentURL, username: "eric", password: "fixture", requiresFaceID: true
        )
        let protected = ConnectionSetupSeeding.wizardCredentials(for: currentURL, saved: faceID)
        XCTAssertEqual(protected?.username, "eric")
        XCTAssertEqual(protected?.password, "", "A Face ID-protected record keeps its password back")

        let foreign = DashboardCredentials(
            baseURL: "https://other.example", username: "eric", password: "fixture", requiresFaceID: false
        )
        XCTAssertNil(ConnectionSetupSeeding.wizardCredentials(for: currentURL, saved: foreign))
        XCTAssertNil(ConnectionSetupSeeding.wizardCredentials(for: currentURL, saved: nil))
    }

    // MARK: - Apply plan (pure policy)

    private let savedCredentials = DashboardCredentials(
        baseURL: "https://hermes.example:9443/hermes",
        username: "eric",
        password: "fixture",
        requiresFaceID: true
    )

    func testUnchangedResultProducesAnEmptyPlan() {
        let plan = ConnectionSetupApplication.plan(
            result: ConnectionSetupResult(serverURL: currentURL, username: "eric", password: "fixture"),
            currentDashboardURL: currentURL,
            savedCredentials: savedCredentials,
            savedCloudflareAccess: nil
        )
        XCTAssertTrue(plan.isEmpty)
        XCTAssertFalse(plan.clearsSavedCredentials)
    }

    func testChangedURLRemembersTheAddressAndReplacesExistingSavedCredentials() {
        let plan = ConnectionSetupApplication.plan(
            result: ConnectionSetupResult(serverURL: "https://new.example/hermes", username: "eric", password: "next"),
            currentDashboardURL: currentURL,
            savedCredentials: savedCredentials,
            savedCloudflareAccess: nil
        )
        XCTAssertEqual(plan.dashboardURLToRemember, "https://new.example/hermes")
        XCTAssertEqual(
            plan.credentialsToSave,
            DashboardCredentials(
                baseURL: "https://new.example/hermes",
                username: "eric",
                password: "next",
                requiresFaceID: true
            ),
            "The replacement preserves the saved Face ID preference"
        )
        XCTAssertFalse(plan.clearsSavedCredentials)
    }

    func testPlanNeverCreatesCredentialsWhenNoneWereSaved() {
        let plan = ConnectionSetupApplication.plan(
            result: ConnectionSetupResult(serverURL: "https://new.example", username: "eric", password: "next"),
            currentDashboardURL: currentURL,
            savedCredentials: nil,
            savedCloudflareAccess: nil
        )
        XCTAssertEqual(plan.dashboardURLToRemember, "https://new.example")
        XCTAssertNil(plan.credentialsToSave, "An explicit apply never starts persisting credentials the user never saved")
        XCTAssertFalse(plan.clearsSavedCredentials)
    }

    func testCredentiallessApplyToANewURLClearsStaleSavedCredentials() {
        let plan = ConnectionSetupApplication.plan(
            result: ConnectionSetupResult(serverURL: "https://new.example", username: "", password: ""),
            currentDashboardURL: currentURL,
            savedCredentials: savedCredentials,
            savedCloudflareAccess: nil
        )
        XCTAssertTrue(plan.clearsSavedCredentials, "The applied configuration cannot use the old password; keeping it would send it to the new address")
        XCTAssertNil(plan.credentialsToSave)
    }

    func testCredentiallessApplyToTheSameURLKeepsSavedCredentials() {
        let plan = ConnectionSetupApplication.plan(
            result: ConnectionSetupResult(serverURL: currentURL, username: "", password: ""),
            currentDashboardURL: currentURL,
            savedCredentials: savedCredentials,
            savedCloudflareAccess: nil
        )
        XCTAssertTrue(plan.isEmpty, "Testing the current address interactively changes nothing")
        XCTAssertFalse(plan.clearsSavedCredentials)
    }

    func testCredentiallessResultWithNoSavedCredentialsNeverTouchesCredentials() {
        let plan = ConnectionSetupApplication.plan(
            result: ConnectionSetupResult(serverURL: "https://new.example", username: "", password: ""),
            currentDashboardURL: currentURL,
            savedCredentials: nil,
            savedCloudflareAccess: nil
        )
        XCTAssertEqual(plan.dashboardURLToRemember, "https://new.example")
        XCTAssertNil(plan.credentialsToSave)
        XCTAssertFalse(plan.clearsSavedCredentials, "There is nothing to clear when nothing was ever saved")
    }

    func testSameOriginPathMoveRewritesTheCloudflareTokenWithoutCopyingAcrossOrigins() throws {
        let access = try XCTUnwrap(CloudflareAccessCredentials.from(clientID: "id", clientSecret: "secret"))
        let plan = ConnectionSetupApplication.plan(
            result: ConnectionSetupResult(serverURL: "https://hermes.example:9443/team", username: "eric", password: "fixture"),
            currentDashboardURL: currentURL,
            savedCredentials: nil,
            savedCloudflareAccess: access
        )
        XCTAssertEqual(
            plan.cloudflareTokenRewrite,
            ConnectionSetupApplication.CloudflareAccessRewrite(access: access, origin: "https://hermes.example:9443/team"),
            "A path-only move is same-origin: the token is re-bound to the new normalized URL"
        )
    }

    func testCrossOriginApplyLeavesTheCloudflareTokenUntouched() throws {
        let access = try XCTUnwrap(CloudflareAccessCredentials.from(clientID: "id", clientSecret: "secret"))
        let plan = ConnectionSetupApplication.plan(
            result: ConnectionSetupResult(serverURL: "https://new.example", username: "eric", password: "fixture"),
            currentDashboardURL: currentURL,
            savedCredentials: nil,
            savedCloudflareAccess: access
        )
        XCTAssertNil(plan.cloudflareTokenRewrite, "A service token is never copied to another origin nor deleted from its own")
    }

    func testApplicationDescriptionIsRedacted() {
        let plan = ConnectionSetupApplication.plan(
            result: ConnectionSetupResult(serverURL: "https://new.example", username: "eric", password: "super-secret"),
            currentDashboardURL: currentURL,
            savedCredentials: savedCredentials,
            savedCloudflareAccess: nil
        )
        XCTAssertFalse(String(describing: plan).contains("super-secret"))
        XCTAssertFalse(String(reflecting: plan).contains("super-secret"))
    }
}
