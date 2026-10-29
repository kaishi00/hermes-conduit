//
//  ConnectionRepairTests.swift
//  Conduit
//
//  Round 6: the explicit Repair Connection flow. Covers the failure-taxonomy
//  entry routing, the validated-transaction candidate lifecycle (edits, new
//  runs, cancellation, consumption), the activation path through the
//  authoritative AppState connection machinery with .preserveCurrent session
//  semantics, persistence timing (only after successful activation), the
//  takeover of automatic recovery authority, and the major race: an explicit
//  repair reconnect must outrank a late automatic reconnect.
//

import XCTest
@testable import Conduit

@MainActor
final class ConnectionRepairTests: XCTestCase {
    private static let failedURL = "https://hermes.example:9443/hermes"
    private var keychainBackend: InMemoryKeychainBackend!

    override func setUp() {
        super.setUp()
        keychainBackend = InMemoryKeychainBackend()
        KeychainHelper.useBackendForTesting(keychainBackend)
    }

    override func tearDown() {
        KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend())
        keychainBackend = nil
        super.tearDown()
    }

    // MARK: - Harness (mirrors AppStateChatResumeTests)

    private func makeHarness(
        lifecycleOperations: ChatResumeLifecycleOperations = .live,
        reconnectScheduler: ChatResumeReconnectScheduler? = nil
    ) -> (appState: AppState, coordinator: ChatResumeCoordinator, store: ChatResumeStore,
          recoverySequence: ChatResumeRecoverySequence, defaults: UserDefaults) {
        let defaults = makeScratchDefaults("ConnectionRepairTests")
        let store = ChatResumeStore(defaults: defaults)
        let coordinator = ChatResumeCoordinator(store: store)
        let recoverySequence = ChatResumeRecoverySequence()
        let appState = AppState(
            defaults: defaults,
            chatResumeCoordinator: coordinator,
            recoverySequence: recoverySequence,
            loadSavedConnection: false,
            reconnectScheduler: reconnectScheduler,
            chatResumeLifecycleOperations: lifecycleOperations
        )
        return (appState, coordinator, store, recoverySequence, defaults)
    }

    private func session(_ id: String) -> SessionSummary {
        SessionSummary(
            id: id,
            storedSessionId: nil,
            alternateIds: [],
            title: id,
            model: "Hermes",
            updatedLabel: "now",
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
    }

    /// Activation fakes: the connect boundary plus the post-connect profile/
    /// preference loaders, which must never fall through to live network
    /// calls under the fake client.
    private func activationFakes(
        connectClient: @escaping @MainActor (HermesClient) async throws -> Void,
        loadCatalog: @escaping @MainActor (HermesClient, Bool) async throws -> [SessionSummary]
    ) -> ChatResumeLifecycleOperations {
        ChatResumeLifecycleOperations(
            connectClient: connectClient,
            loadCatalog: loadCatalog,
            openSession: { _, id, _ in
                SessionResumeResult(sessionId: id, messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            refreshContext: { _, _ in },
            loadProfiles: {},
            loadBusyInputMode: { _ in },
            loadProfileDisplayPreferences: {},
            loadSlashCommands: {}
        )
    }

    private func sessionPreservingFakes(connectClient: @escaping @MainActor (HermesClient) async throws -> Void) -> ChatResumeLifecycleOperations {
        activationFakes(connectClient: connectClient, loadCatalog: { _, _ in [self.session("stored-a")] })
    }

    private func candidate(
        serverURL: String = ConnectionRepairTests.failedURL,
        ticket: String,
        revision: Int,
        generation: Int
    ) -> ConnectionRepairCandidate {
        ConnectionRepairCandidate(
            configuration: ConnectionSetupResult(serverURL: serverURL, username: "u", password: "p"),
            nativeConnection: .debugStub(ticket: ticket),
            validatedRevision: revision,
            generation: generation
        )
    }

    private func oauthTokens(_ suffix: String) -> NativeOAuthTokenSet {
        NativeOAuthTokenSet(
            accessToken: "access-\(suffix)",
            refreshToken: "refresh-\(suffix)",
            expiresAt: Date().addingTimeInterval(3_600).timeIntervalSince1970,
            provider: "google",
            userID: "user-\(suffix)"
        )
    }

    // MARK: - Entry routing (spec 6)

    func testRepairRoutingStartsNearTheClassifiedProblem() {
        let draft = ConnectionSetupDraft(
            existingServerURL: ConnectionRepairTests.failedURL, username: "u", password: "p"
        )
        XCTAssertEqual(
            ConnectionSetupFlow.initialPath(for: .repairConnection, draft: draft, repairFailure: .authenticationRejected),
            [.connectionDetails, .loginCredentials]
        )
        XCTAssertEqual(
            ConnectionSetupFlow.initialPath(for: .repairConnection, draft: draft, repairFailure: .cloudflareTokenRejected),
            [.connectionDetails, .cloudflareTroubleshooting]
        )
        for failure: ConnectionFailure in [.tlsUntrusted, .tlsBadDate, .tlsFailure, .tlsHostnameMismatch, .tlsNotStandardsCompliant] {
            XCTAssertEqual(
                ConnectionSetupFlow.initialPath(for: .repairConnection, draft: draft, repairFailure: failure),
                [.connectionDetails, .tlsTroubleshooting]
            )
        }
        for failure: ConnectionFailure in [.invalidAddress, .hostNotFound, .unreachable, .connectionRefused, .timedOut, .offline, .dashboardUnavailable, .unexpectedServerResponse] {
            XCTAssertEqual(
                ConnectionSetupFlow.initialPath(for: .repairConnection, draft: draft, repairFailure: failure),
                [.connectionDetails],
                "\(failure) should route to the editable address"
            )
        }
        // A throttled login must never route toward another login.
        XCTAssertEqual(
            ConnectionSetupFlow.initialPath(for: .repairConnection, draft: draft, repairFailure: .rateLimited),
            [.connectionDetails]
        )
        // No strong diagnosis: the seeded staged test is the diagnostic.
        XCTAssertEqual(
            ConnectionSetupFlow.initialPath(for: .repairConnection, draft: draft, repairFailure: .unknown),
            [.connectionDetails, .connectionTest]
        )
        XCTAssertEqual(
            ConnectionSetupFlow.initialPath(for: .repairConnection, draft: draft, repairFailure: nil),
            [.connectionDetails, .connectionTest]
        )
        // A sign-in page that didn't open says nothing about the address.
        XCTAssertEqual(
            ConnectionSetupFlow.initialPath(for: .repairConnection, draft: draft, repairFailure: .signInPageFailed),
            [.connectionDetails, .connectionTest]
        )
        XCTAssertEqual(ConnectionSetupFlow.entryStep(for: .repairConnection), .connectionDetails)
    }

    func testRepairEntryAlwaysKeepsTheAddressOneBackStepAway() throws {
        let draft = ConnectionSetupDraft(existingServerURL: ConnectionRepairTests.failedURL, username: "u", password: "p")
        var flow = ConnectionSetupFlow(
            entry: .repairConnection,
            draft: draft,
            repairFailure: .authenticationRejected
        )
        XCTAssertEqual(flow.step, .loginCredentials)
        XCTAssertTrue(flow.canGoBack)
        flow.back()
        XCTAssertEqual(flow.step, .connectionDetails, "The initial diagnosis being wrong must not strand the user")

        var testFirst = ConnectionSetupFlow(
            entry: .repairConnection,
            draft: draft,
            repairFailure: .unknown
        )
        XCTAssertEqual(testFirst.step, .connectionTest)
        XCTAssertTrue(testFirst.isRepairingConnection)
        testFirst.back()
        XCTAssertEqual(testFirst.step, .connectionDetails)
    }

    func testRepairEntryCanTestWithoutCredentialsThenEnterThem() {
        // The no-saved-credentials repair: the staged test runs discovery
        // first (Credentials required stops before any login), and Enter
        // Credentials routes to the credentials step, from which the fresh
        // full test runs.
        var flow = ConnectionSetupFlow(
            entry: .repairConnection,
            draft: ConnectionSetupDraft(existingServerURL: ConnectionRepairTests.failedURL)
        )
        XCTAssertEqual(flow.step, .connectionTest)
        flow.back()
        XCTAssertEqual(flow.step, .connectionDetails)
        flow.submitDetails()
        XCTAssertEqual(flow.step, .connectionTest, "Empty credentials must not block the repair test path")
        XCTAssertNil(flow.validationError)

        // The credentials-required partial outcome routes to credentials and
        // never authorizes reconnect.
        let generation = flow.beginTest()
        XCTAssertNotNil(generation)
        for event in StagedTestDriver.successEvents.prefix(5) {
            flow.applyTestEvent(event, generation: generation!)
        }
        flow.applyTestEvent(.requiresCredentials(.authentication), generation: generation!)
        XCTAssertTrue(flow.testState.requiresCredentials)
        XCTAssertFalse(flow.canUseSettings, "Credentials required never authorizes Reconnect Now")
        flow.editAfterFailedTest(.loginCredentials)
        XCTAssertEqual(flow.step, .loginCredentials)
        flow.back()
        XCTAssertEqual(flow.step, .connectionDetails, "The credentials step replaced the spent test")
    }

    // MARK: - Sign In to Reconnect fencing

    /// A Repair flow whose staged test ended in `terminal` (an interactive
    /// outcome), sitting on Review.
    private func repairFlowAtReview(ending terminal: ConnectionSetupTestEvent) throws -> ConnectionSetupFlow {
        var flow = ConnectionSetupFlow(
            entry: .repairConnection,
            draft: ConnectionSetupDraft(existingServerURL: ConnectionRepairTests.failedURL)
        )
        XCTAssertEqual(flow.step, .connectionTest)
        let generation = try XCTUnwrap(flow.beginTest())
        for event in StagedTestDriver.successEvents.prefix(5) {
            flow.applyTestEvent(event, generation: generation)
        }
        flow.applyTestEvent(terminal, generation: generation)
        XCTAssertEqual(flow.step, .review)
        return flow
    }

    func testSignInToReconnectAnswerIsDroppedAfterAnEditOrANewerTest() throws {
        for terminal in [
            ConnectionSetupTestEvent.requiresInteractiveSignIn(.authentication, .browser(.authProxyRedirect)),
            .requiresSignInChoice(.authentication, .nativeCapable(provider: "self-hosted"))
        ] {
            var flow = try repairFlowAtReview(ending: terminal)
            let result = try XCTUnwrap(flow.complete())
            let request = ConnectionRepairSignInRequest(
                configuration: result,
                revision: flow.draftRevision,
                generation: flow.testGeneration
            )
            XCTAssertTrue(request.isCurrent(in: flow), "\(terminal)")

            // The user goes Back and edits the address while the capability
            // check runs: its late answer must not open a sign-in at all.
            var edited = flow
            edited.back()
            edited.back()
            XCTAssertEqual(edited.step, .connectionDetails)
            edited.draft.existingServerURL = "https://other.example.test"
            XCTAssertFalse(request.isCurrent(in: edited), "\(terminal): an edited draft")

            // A newer test supersedes it too, even for the same address.
            var retested = flow
            retested.invalidateTestForRepairRetry()
            XCTAssertFalse(request.isCurrent(in: retested), "\(terminal): a newer test")
        }
    }

    func testSignInChoiceInRepairOffersThePasswordRoute() throws {
        var flow = try repairFlowAtReview(ending: .requiresSignInChoice(.authentication, .legacyOAuth))
        XCTAssertTrue(flow.canUseSettings, "Sign In to Reconnect is available for the choice")
        flow.enterCredentialsForSignInChoice()
        XCTAssertEqual(flow.step, .loginCredentials, "Enter Credentials leads to a password test instead")
        XCTAssertFalse(flow.canUseSettings)
    }

    /// Counts capability checks; Sign In to Reconnect has no discovery seam
    /// at all, so it can only open what the staged test decided.
    private final class CapabilitySeam {
        var calls = 0
        let answer: Result<Bool, Error>

        init(_ answer: Result<Bool, Error>) {
            self.answer = answer
        }

        var resolver: DashboardSignInResolver {
            DashboardSignInResolver(supportsNativeOAuth: { [self] in
                calls += 1
                return try answer.get()
            })
        }
    }

    private enum CapabilityFixture: Error { case unavailable }

    func testSignInToReconnectOpensTheSignInTheTestDecided() async throws {
        for signIn in [
            DashboardInteractiveSignIn.nativeOAuth(provider: "self-hosted"),
            .nativeOAuth(provider: nil),
            .browser(.legacyOAuth),
            .browser(.authProxyRedirect)
        ] {
            let flow = try repairFlowAtReview(ending: .requiresInteractiveSignIn(.authentication, signIn))
            // Whatever the dashboard would answer now, the tested decision
            // stands: no second discovery, no capability check.
            let seam = CapabilitySeam(.failure(CapabilityFixture.unavailable))
            let opened = try await ConnectionRepairSignIn.signIn(for: flow.testState, resolver: seam.resolver)
            XCTAssertEqual(opened, signIn)
            XCTAssertEqual(seam.calls, 0, "\(signIn)")
        }
    }

    func testPrivateSignInSwitchShowsOnlyWhereSignInCanBeNative() throws {
        // A tested native sign-in, or a choice the capability check may still
        // send to Safari, reads the switch; the embedded browser never does.
        for (terminal, shows) in [
            (ConnectionSetupTestEvent.requiresInteractiveSignIn(.authentication, .nativeOAuth(provider: "self-hosted")), true),
            (.requiresInteractiveSignIn(.authentication, .browser(.legacyOAuth)), false),
            (.requiresInteractiveSignIn(.authentication, .browser(.authProxyRedirect)), false),
            (.requiresSignInChoice(.authentication, .nativeCapable(provider: "self-hosted")), true),
            (.requiresSignInChoice(
                .authentication,
                .nativeCapable(provider: "self-hosted", advertisedFlows: ["cookie", "native_pkce"])
            ), true),
            (.requiresSignInChoice(.authentication, .legacyOAuth), false)
        ] {
            let flow = try repairFlowAtReview(ending: terminal)
            XCTAssertEqual(ConnectionRepairSignIn.mayOpenNativeSignIn(for: flow.testState), shows, "\(terminal)")
        }
        XCTAssertFalse(ConnectionRepairSignIn.mayOpenNativeSignIn(for: ConnectionSetupTestState()))
    }

    func testSignInToReconnectFromAChoiceChecksCapabilityOnlyForANativeCapableOffer() async throws {
        let native = CapabilitySeam(.success(true))
        let nativeFlow = try repairFlowAtReview(
            ending: .requiresSignInChoice(.authentication, .nativeCapable(provider: "self-hosted"))
        )
        let nativeOpened = try await ConnectionRepairSignIn.signIn(for: nativeFlow.testState, resolver: native.resolver)
        XCTAssertEqual(nativeOpened, .nativeOAuth(provider: "self-hosted"))
        XCTAssertEqual(native.calls, 1)

        let older = CapabilitySeam(.success(false))
        let olderOpened = try await ConnectionRepairSignIn.signIn(for: nativeFlow.testState, resolver: older.resolver)
        XCTAssertEqual(olderOpened, .browser(.legacyOAuth))

        let legacy = CapabilitySeam(.success(true))
        let legacyFlow = try repairFlowAtReview(ending: .requiresSignInChoice(.authentication, .legacyOAuth))
        let legacyOpened = try await ConnectionRepairSignIn.signIn(for: legacyFlow.testState, resolver: legacy.resolver)
        XCTAssertEqual(legacyOpened, .browser(.legacyOAuth))
        XCTAssertEqual(legacy.calls, 0)
    }

    func testSignInToReconnectFromAChoiceWhoseTestAdvertisedNativeSignInAsksNothing() async throws {
        let flow = try repairFlowAtReview(
            ending: .requiresSignInChoice(
                .authentication,
                .nativeCapable(provider: "self-hosted", advertisedFlows: ["cookie", "native_pkce"])
            )
        )
        // Behind an auth edge the capability check would be refused; the
        // tested provider answer already said.
        let seam = CapabilitySeam(.failure(CapabilityFixture.unavailable))
        let opened = try await ConnectionRepairSignIn.signIn(for: flow.testState, resolver: seam.resolver)
        XCTAssertEqual(opened, .nativeOAuth(provider: "self-hosted"))
        XCTAssertEqual(seam.calls, 0)
    }

    func testSignInToReconnectFailsClosedWhenAChoicesCapabilityCheckFails() async throws {
        let flow = try repairFlowAtReview(
            ending: .requiresSignInChoice(.authentication, .nativeCapable(provider: "self-hosted"))
        )
        do {
            let opened = try await ConnectionRepairSignIn.signIn(
                for: flow.testState,
                resolver: CapabilitySeam(.failure(CapabilityFixture.unavailable)).resolver
            )
            XCTFail("A failed capability check must not open a sign-in, got \(String(describing: opened))")
        } catch {
            XCTAssertEqual(error as? CapabilityFixture, .unavailable, "An error, never the browser view instead")
        }
    }

    func testSignInToReconnectOpensNothingForAPasswordOutcome() async throws {
        var flow = ConnectionSetupFlow(
            entry: .repairConnection,
            draft: ConnectionSetupDraft(existingServerURL: ConnectionRepairTests.failedURL, username: "u", password: "p")
        )
        StagedTestDriver.runSuccessfulTest(on: &flow)
        let seam = CapabilitySeam(.success(true))
        let opened = try await ConnectionRepairSignIn.signIn(for: flow.testState, resolver: seam.resolver)
        XCTAssertNil(opened, "A password outcome reconnects through its tested candidate, never a browser")
        XCTAssertEqual(seam.calls, 0)
    }

    // MARK: - Candidate lifecycle (spec 11, 17, 32)

    func testCandidateLifecycleTracksTheFlowRevisionAndGeneration() throws {
        let seed = ConnectionSetupDraft(
            existingServerURL: ConnectionRepairTests.failedURL, username: "u", password: "p"
        )
        var flow = ConnectionSetupFlow(entry: .repairConnection, draft: seed)
        XCTAssertEqual(flow.step, .connectionTest)
        StagedTestDriver.runSuccessfulTest(on: &flow)

        let candidateA = candidate(
            ticket: "candidate-a",
            revision: try XCTUnwrap(flow.testSucceededAtRevision),
            generation: flow.testGeneration
        )
        XCTAssertTrue(candidateA.isCurrent(
            hasCurrentSuccessfulTest: flow.hasCurrentSuccessfulTest,
            testGeneration: flow.testGeneration,
            testSucceededAtRevision: flow.testSucceededAtRevision
        ))

        // A draft edit invalidates the staged success and the candidate:
        // Back walks Review → test → details, then Continue reaches the
        // credentials step.
        flow.back()
        flow.back()
        flow.submitDetails()
        XCTAssertEqual(flow.step, .loginCredentials)
        flow.draft.password = "edited"
        XCTAssertFalse(flow.hasCurrentSuccessfulTest)
        XCTAssertFalse(candidateA.isCurrent(
            hasCurrentSuccessfulTest: flow.hasCurrentSuccessfulTest,
            testGeneration: flow.testGeneration,
            testSucceededAtRevision: flow.testSucceededAtRevision
        ))

        // A newer run mints a newer generation; candidate B is the only
        // current one, and a late candidate A can never reconnect.
        flow.submitCredentials()
        StagedTestDriver.runSuccessfulTest(on: &flow)
        let candidateB = candidate(
            ticket: "candidate-b",
            revision: try XCTUnwrap(flow.testSucceededAtRevision),
            generation: flow.testGeneration
        )
        XCTAssertTrue(candidateB.isCurrent(
            hasCurrentSuccessfulTest: flow.hasCurrentSuccessfulTest,
            testGeneration: flow.testGeneration,
            testSucceededAtRevision: flow.testSucceededAtRevision
        ))
        XCTAssertNotEqual(candidateA.generation, candidateB.generation)
        XCTAssertFalse(candidateA.isCurrent(
            hasCurrentSuccessfulTest: flow.hasCurrentSuccessfulTest,
            testGeneration: flow.testGeneration,
            testSucceededAtRevision: flow.testSucceededAtRevision
        ))

        // A newer test run rotates the generation and invalidates everything
        // (cancelling a FINISHED success is a deliberate no-op — Round-4
        // semantics — so the invalidation trigger is the next run). Back to
        // the test screen first: the still-current success survives Back.
        flow.back()
        XCTAssertTrue(flow.hasCurrentSuccessfulTest)
        XCTAssertNotNil(flow.beginTest())
        XCTAssertFalse(candidateB.isCurrent(
            hasCurrentSuccessfulTest: flow.hasCurrentSuccessfulTest,
            testGeneration: flow.testGeneration,
            testSucceededAtRevision: flow.testSucceededAtRevision
        ))
    }

    func testInvalidateTestForRepairRetryRequiresAFreshTest() throws {
        let seed = ConnectionSetupDraft(
            existingServerURL: ConnectionRepairTests.failedURL, username: "u", password: "p"
        )
        var flow = ConnectionSetupFlow(entry: .repairConnection, draft: seed)
        flow.submitDetails()
        flow.submitCredentials()
        StagedTestDriver.runSuccessfulTest(on: &flow)
        XCTAssertEqual(flow.step, .review)
        XCTAssertTrue(flow.canUseSettings)
        XCTAssertNotNil(flow.complete())

        flow.invalidateTestForRepairRetry()

        XCTAssertEqual(flow.step, .connectionTest, "The wizard returns to the test screen")
        XCTAssertFalse(flow.canUseSettings, "A consumed or failed attempt authorizes nothing")
        XCTAssertNil(flow.complete())
        XCTAssertEqual(flow.testState, ConnectionSetupTestState())
    }

    // MARK: - Repair takeover of automatic recovery (spec 8, 27)

    func testEnteringRepairStopsTheAutomaticRetryLoopWithoutSideEffects() async {
        let reconnectSpy = RepairReconnectExecutionSpy()
        let scheduler = RepairControlledReconnectScheduler()
        let suite = "ConnectionRepairTests.scheduler.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Failed to create test defaults suite")
            return
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let coordinator = ChatResumeCoordinator(store: ChatResumeStore(defaults: defaults))
        let appState = AppState(
            defaults: defaults,
            chatResumeCoordinator: coordinator,
            recoverySequence: ChatResumeRecoverySequence(),
            loadSavedConnection: false,
            reconnectScheduler: scheduler.schedule(after:operation:),
            reconnectExecutor: { purpose in reconnectSpy.purposes.append(purpose) }
        )
        appState.connection = HermesConnection(baseUrl: ConnectionRepairTests.failedURL, ticket: "failed-ticket")

        // The existing system schedules its automatic retry.
        appState.scheduleReconnect(purpose: .preserveCurrent)
        XCTAssertEqual(scheduler.pendingCount, 1)

        // Entering Repair hands recovery authority to the user: the loop
        // stops, and running the (cancelled) schedule executes nothing.
        let context = appState.beginConnectionRepair()
        XCTAssertEqual(context?.draft.existingServerURL, ConnectionRepairTests.failedURL)
        XCTAssertEqual(scheduler.pendingCount, 0)
        await scheduler.runAll()
        XCTAssertEqual(reconnectSpy.purposes, [], "No background connection attempt may follow repair entry")

        // Cancellation has no persistence side effects: the saved-in-memory
        // connection target is untouched and no failure state appeared.
        XCTAssertNotNil(appState.connection)
        XCTAssertFalse(appState.isConnected)
    }

    func testFailedReconnectRetainsTypedFailureUntilRecoverySucceeds() async {
        var mintAttempts = 0
        let scheduler = RepairControlledReconnectScheduler()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                connectClient: { _ in },
                loadCatalog: { _, _ in [self.session("stored-a")] },
                mintTicket: { _ in
                    mintAttempts += 1
                    if mintAttempts == 1 {
                        throw URLError(.cannotFindHost)
                    }
                    return "fresh-ticket"
                },
                openSession: { _, id, _ in
                    SessionResumeResult(sessionId: id, messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
                },
                refreshContext: { _, _ in },
                loadProfiles: {},
                loadBusyInputMode: { _ in },
                loadProfileDisplayPreferences: {},
                loadSlashCommands: {}
            ),
            reconnectScheduler: scheduler.schedule(after:operation:)
        )
        harness.appState.connection = HermesConnection(baseUrl: ConnectionRepairTests.failedURL, ticket: "stale-ticket")
        harness.appState.client = HermesClient(connection: HermesConnection(baseUrl: ConnectionRepairTests.failedURL, ticket: "t"), profile: "default")

        // First reconnect fails: the typed classification must remain
        // available for Repair seeding and routing.
        await harness.appState.reconnectForRetry(purpose: .preserveCurrent)
        XCTAssertFalse(harness.appState.isConnected)
        XCTAssertNotNil(harness.appState.lastConnectionFailure,
                        "A failed reconnect must leave the typed classification available for Repair")
        XCTAssertNotNil(harness.appState.errorMessage)
        XCTAssertEqual(scheduler.pendingCount, 1, "The failure arms the ordinary automatic retry")

        // The later reconnect succeeds: the stale classification is cleared
        // alongside the banner, so a future unrelated failure routes Repair
        // from itself, not from this stale event.
        await harness.appState.reconnectForRetry(purpose: .preserveCurrent)
        XCTAssertTrue(harness.appState.isConnected)
        XCTAssertNil(harness.appState.lastConnectionFailure,
                     "A successful reconnect makes any previous classification stale")
        XCTAssertNil(harness.appState.errorMessage)
        XCTAssertEqual(mintAttempts, 2)
        // The retry armed by the failure was cancelled when the explicit
        // reconnect began; a successful reconnect leaves nothing scheduled.
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    // MARK: - Activation (spec 13, 14, 16, 28, 30)

    func testSameConnectionRepairActivatesOnceAndPreservesTheSession() async {
        let connectCount = RepairConnectCount()
        let harness = makeHarness(lifecycleOperations: sessionPreservingFakes(connectClient: { _ in
            connectCount.value += 1
        }))
        let failedConnection = HermesConnection(baseUrl: ConnectionRepairTests.failedURL, ticket: "stale-ticket")
        harness.appState.connection = failedConnection
        harness.appState.client = HermesClient(connection: failedConnection, profile: "default")
        // The visible session A is the established, durably stored identity.
        harness.store.setLastSessionID("stored-a", for: "default")
        harness.appState.activeSessionId = "stored-a"

        let outcome = await harness.appState.performConnectionRepair(.native(candidate(
            ticket: "repaired-ticket",
            revision: 4,
            generation: 2
        )))

        XCTAssertEqual(outcome, .activated)
        XCTAssertTrue(harness.appState.isConnected)
        XCTAssertEqual(harness.appState.connection?.ticket, "repaired-ticket")
        XCTAssertEqual(harness.appState.activeSessionId, "stored-a", "The server confirmed the preserved session")
        XCTAssertEqual(connectCount.value, 1, "Exactly one activation")
    }

    func testRepairToAnotherSavedDashboardsAddressConnectsAndWritesNothing() async {
        let connectCount = RepairConnectCount()
        let harness = makeHarness(lifecycleOperations: sessionPreservingFakes(connectClient: { _ in
            connectCount.value += 1
        }))
        let repairing = harness.appState.registerDashboard(forNormalizedURL: ConnectionRepairTests.failedURL)
        let other = harness.appState.registerDashboard(forNormalizedURL: "https://other.example")
        let otherCredentials = DashboardCredentials(baseURL: "https://other.example", username: "b", password: "b-secret", requiresFaceID: false)
        KeychainHelper.saveCredentials(otherCredentials, dashboardID: other)
        harness.appState.connection = HermesConnection(baseUrl: ConnectionRepairTests.failedURL, ticket: "stale-ticket")

        let outcome = await harness.appState.performConnectionRepair(.native(candidate(
            serverURL: "https://other.example",
            ticket: "repaired-ticket",
            revision: 4,
            generation: 2
        )))

        guard case .addressBelongsToDashboard(let id, _) = outcome else {
            return XCTFail("expected the other dashboard's address to be refused, got \(outcome)")
        }
        XCTAssertEqual(id, other)
        XCTAssertEqual(connectCount.value, 0, "Nothing connects")
        XCTAssertEqual(harness.appState.connection?.ticket, "stale-ticket")
        XCTAssertEqual(KeychainHelper.loadCredentials(dashboardID: other), otherCredentials, "B's sign-in is untouched")
        // Its own address, or a new one, still repairs.
        XCTAssertNil(harness.appState.repairAddressOwner(ConnectionRepairTests.failedURL, repairing: ConnectionRepairTests.failedURL))
        XCTAssertNil(harness.appState.repairAddressOwner("https://new.example", repairing: ConnectionRepairTests.failedURL))
        XCTAssertNotEqual(repairing, other)
        // A new address a repair's sign-in registered stays that repair's.
        let registered = harness.appState.registerRepairDashboard(forURL: "https://fresh.example")
        XCTAssertNotNil(registered)
        XCTAssertNil(harness.appState.repairAddressOwner("https://fresh.example", repairing: ConnectionRepairTests.failedURL))
        XCTAssertEqual(harness.appState.registerRepairDashboard(forURL: "https://other.example"), other)
        XCTAssertNotNil(harness.appState.repairAddressOwner("https://other.example", repairing: ConnectionRepairTests.failedURL),
                        "An address that was already saved is still another dashboard's")
        // A later repair doesn't inherit it.
        _ = harness.appState.beginSavedConnectionRepair()
        XCTAssertNotNil(harness.appState.repairAddressOwner("https://fresh.example", repairing: ConnectionRepairTests.failedURL))
    }

    func testChangedEndpointFailsSafelyIntoTheExistingIdentityBoundary() async {
        let harness = makeHarness(lifecycleOperations: activationFakes(
            connectClient: { _ in },
            loadCatalog: { _, _ in [self.session("stored-new")] }
        ))
        harness.appState.connection = HermesConnection(baseUrl: ConnectionRepairTests.failedURL, ticket: "stale-ticket")
        harness.appState.client = HermesClient(connection: HermesConnection(baseUrl: ConnectionRepairTests.failedURL, ticket: "t"), profile: "default")
        harness.appState.activeSessionId = "old-session"

        let outcome = await harness.appState.performConnectionRepair(.native(candidate(
            serverURL: "https://other.example",
            ticket: "repaired-ticket",
            revision: 4,
            generation: 2
        )))

        XCTAssertEqual(outcome, .activated, "Activation itself succeeded")
        XCTAssertEqual(harness.appState.connection?.baseUrl, "https://other.example")
        // A different server identity clears the old session through the
        // existing boundary; the replacement endpoint's SERVER-CONFIRMED
        // catalog is what selects the next conversation — the old session
        // identity is never blindly reused.
        XCTAssertNotEqual(harness.appState.activeSessionId, "old-session")
    }

    func testFailedActivationPersistsNothingAndRequiresAFreshTest() async {
        let remembered = "https://hermes.example:9443/hermes"
        let harness = makeHarness(lifecycleOperations: activationFakes(
            connectClient: { _ in throw RepairControlledError.activationFailed },
            loadCatalog: { _, _ in [] }
        ))
        harness.appState.connection = HermesConnection(baseUrl: remembered, ticket: "stale-ticket")
        harness.appState.client = HermesClient(connection: HermesConnection(baseUrl: remembered, ticket: "t"), profile: "default")
        harness.defaults.set(remembered, forKey: "conduit.dashboardURL")

        let outcome = await harness.appState.performConnectionRepair(.native(candidate(
            serverURL: "https://replacement.example",
            ticket: "candidate-ticket",
            revision: 4,
            generation: 2
        )))

        guard case .failed = outcome else {
            return XCTFail("A failed activation must be a classified failure, got: \(outcome)")
        }
        XCTAssertNotNil(harness.appState.lastConnectionFailure, "The activation failure arrives classified")
        XCTAssertEqual(harness.defaults.string(forKey: "conduit.dashboardURL"), remembered,
                       "A failed activation must not move the remembered dashboard")
        XCTAssertFalse(harness.appState.isConnected)
        XCTAssertNil(harness.appState.repairAddressOwner("https://replacement.example", repairing: remembered),
                     "The address this repair registered stays its own, so a fresh test there isn't refused")
    }

    func testBrowserSignInRepairActivatesAndRemembersWithoutInventingCredentials() async {
        let harness = makeHarness(lifecycleOperations: sessionPreservingFakes(connectClient: { _ in }))
        harness.appState.connection = HermesConnection(baseUrl: ConnectionRepairTests.failedURL, ticket: "stale-ticket")
        harness.appState.client = HermesClient(connection: HermesConnection(baseUrl: ConnectionRepairTests.failedURL, ticket: "t"), profile: "default")
        harness.defaults.set(ConnectionRepairTests.failedURL, forKey: "conduit.dashboardURL")

        let outcome = await harness.appState.performConnectionRepair(.browserSignIn(
            ticket: "browser-ticket",
            baseURL: ConnectionRepairTests.failedURL,
            configuration: ConnectionSetupResult(serverURL: ConnectionRepairTests.failedURL, username: "", password: "")
        ))

        XCTAssertEqual(outcome, .activated)
        XCTAssertTrue(harness.appState.isConnected)
        XCTAssertEqual(harness.appState.connection?.ticket, "browser-ticket")
        // Existing browser-auth semantics: the activated dashboard is
        // remembered and no native credentials are invented.
        XCTAssertEqual(harness.defaults.string(forKey: "conduit.dashboardURL"), ConnectionRepairTests.failedURL)
    }

    func testFailedNativeOAuthRepairRestoresPriorAuthenticationState() async throws {
        let harness = makeHarness(lifecycleOperations: activationFakes(
            connectClient: { _ in throw RepairControlledError.activationFailed },
            loadCatalog: { _, _ in [] }
        ))
        let dashboardID = try XCTUnwrap(harness.appState.resolveDashboardID(
            forURL: ConnectionRepairTests.failedURL,
            registerIfMissing: true
        ))
        let previousTokens = oauthTokens("previous")
        let previousCredentials = DashboardCredentials(
            baseURL: ConnectionRepairTests.failedURL,
            username: "existing-user",
            password: "existing-password",
            requiresFaceID: false
        )
        let previousCookies = Data("existing-cookies".utf8)
        KeychainHelper.saveNativeOAuthTokens(previousTokens, dashboardID: dashboardID)
        KeychainHelper.saveCredentials(previousCredentials, dashboardID: dashboardID)
        KeychainHelper.saveDashboardCookies(previousCookies, dashboardID: dashboardID)

        let outcome = await harness.appState.performConnectionRepair(.nativeOAuth(
            result: NativeOAuthLoginResult(tokens: oauthTokens("candidate"), ticket: "candidate-ticket"),
            baseURL: ConnectionRepairTests.failedURL,
            configuration: ConnectionSetupResult(
                serverURL: ConnectionRepairTests.failedURL,
                username: "",
                password: ""
            )
        ))

        guard case .failed = outcome else {
            return XCTFail("Expected failed activation, got: \(outcome)")
        }
        XCTAssertEqual(KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardID), previousTokens)
        XCTAssertEqual(KeychainHelper.loadCredentials(dashboardID: dashboardID), previousCredentials)
        XCTAssertEqual(KeychainHelper.loadDashboardCookies(dashboardID: dashboardID), previousCookies)
    }

    func testSuccessfulNativeOAuthRepairCommitsNewModeAfterActivation() async throws {
        let harness = makeHarness(lifecycleOperations: sessionPreservingFakes(connectClient: { _ in }))
        let dashboardID = try XCTUnwrap(harness.appState.resolveDashboardID(
            forURL: ConnectionRepairTests.failedURL,
            registerIfMissing: true
        ))
        let previousCredentials = DashboardCredentials(
            baseURL: ConnectionRepairTests.failedURL,
            username: "existing-user",
            password: "existing-password",
            requiresFaceID: false
        )
        KeychainHelper.saveCredentials(previousCredentials, dashboardID: dashboardID)
        KeychainHelper.saveDashboardCookies(Data("existing-cookies".utf8), dashboardID: dashboardID)
        let candidateTokens = oauthTokens("candidate")

        let outcome = await harness.appState.performConnectionRepair(.nativeOAuth(
            result: NativeOAuthLoginResult(tokens: candidateTokens, ticket: "candidate-ticket"),
            baseURL: ConnectionRepairTests.failedURL,
            configuration: ConnectionSetupResult(
                serverURL: ConnectionRepairTests.failedURL,
                username: "",
                password: ""
            )
        ))

        XCTAssertEqual(outcome, .activated)
        XCTAssertEqual(KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardID), candidateTokens)
        XCTAssertNil(KeychainHelper.loadCredentials(dashboardID: dashboardID))
        XCTAssertNil(KeychainHelper.loadDashboardCookies(dashboardID: dashboardID))
    }

    func testColdStartNativeGrantMintsTicketBeforeSavedPasswordRestore() async throws {
        let connected = expectation(description: "native token connection activated")
        // The app state can reconnect again after this test's assertions (for
        // example a late automatic retry). Fulfilling on every connect then
        // over-fulfills the expectation and crashes whichever test runs next.
        let connectCount = RepairConnectCount()
        var mintedBaseURL: String?
        let lifecycle = ChatResumeLifecycleOperations(
            connectClient: { _ in
                connectCount.value += 1
                if connectCount.value == 1 { connected.fulfill() }
            },
            loadCatalog: { _, _ in [self.session("stored-a")] },
            mintTicket: { baseURL in
                mintedBaseURL = baseURL
                return "native-ticket"
            },
            openSession: { _, id, _ in
                SessionResumeResult(
                    sessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            loadProfiles: {},
            loadBusyInputMode: { _ in },
            loadProfileDisplayPreferences: {},
            loadSlashCommands: {}
        )
        let harness = makeHarness(lifecycleOperations: lifecycle)
        let dashboardID = harness.appState.adoptDashboard(
            forNormalizedURL: ConnectionRepairTests.failedURL
        )
        KeychainHelper.saveNativeOAuthTokens(oauthTokens("durable"), dashboardID: dashboardID)
        KeychainHelper.saveCredentials(DashboardCredentials(
            baseURL: ConnectionRepairTests.failedURL,
            username: "saved-user",
            password: "saved-password",
            requiresFaceID: false
        ), dashboardID: dashboardID)

        harness.appState.setActiveProfileForTesting("work")
        harness.appState.loadSavedConnection()
        await fulfillment(of: [connected], timeout: 2)

        // The transport hook fires before connect() finishes restoring the
        // session. Credential cleanup happens only after that work returns.
        let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while KeychainHelper.loadCredentials(dashboardID: dashboardID) != nil,
              ContinuousClock.now < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(harness.appState.activeProfile, "work")
        XCTAssertEqual(mintedBaseURL, ConnectionRepairTests.failedURL)
        XCTAssertTrue(harness.appState.isConnected)
        XCTAssertEqual(harness.appState.connection?.ticket, "native-ticket")
        XCTAssertTrue(KeychainHelper.loadCredentials(dashboardID: dashboardID) == nil,
                      "Successful OAuth restoration must clear saved password credentials")
    }

    /// A browser sign-in's saved ticket was spent when it last opened the
    /// socket (Hermes' tickets are single-use and last 30 seconds). Cold
    /// launch mints a fresh one with the dashboard's cookies and connects
    /// with that, instead of a first attempt Hermes is bound to refuse.
    func testColdStartSavedSessionConnectsWithFreshTicket() async throws {
        let connected = expectation(description: "saved session connected")
        let connectCount = RepairConnectCount()
        var connectedTickets: [String] = []
        var mintedBaseURLs: [String] = []
        let harness = makeHarness(lifecycleOperations: coldStartLifecycle(
            mint: { baseURL in
                mintedBaseURLs.append(baseURL)
                return "fresh-ticket"
            },
            connected: { client in
                connectedTickets.append(client.connection.ticket)
                connectCount.value += 1
                if connectCount.value == 1 { connected.fulfill() }
            }
        ))
        let dashboardID = harness.appState.adoptDashboard(forNormalizedURL: Self.failedURL)
        KeychainHelper.saveConnection(
            HermesConnection(baseUrl: Self.failedURL, ticket: "spent-ticket"),
            dashboardID: dashboardID
        )

        harness.appState.loadSavedConnection()
        await fulfillment(of: [connected], timeout: 2)

        XCTAssertEqual(mintedBaseURLs.first, Self.failedURL)
        XCTAssertEqual(connectedTickets.first, "fresh-ticket")
        XCTAssertEqual(harness.appState.connection?.ticket, "fresh-ticket")
    }

    /// A mint that fails (the page not up yet, the cookies refused) connects
    /// with the saved record as before; its refusal schedules the reconnect.
    func testColdStartSavedSessionKeepsSavedTicketWhenMintFails() async throws {
        let connected = expectation(description: "saved session connected")
        let connectCount = RepairConnectCount()
        var connectedTickets: [String] = []
        let harness = makeHarness(lifecycleOperations: coldStartLifecycle(
            mint: { _ in throw DashboardTicketBridgeError.notReady },
            connected: { client in
                connectedTickets.append(client.connection.ticket)
                connectCount.value += 1
                if connectCount.value == 1 { connected.fulfill() }
            }
        ))
        let dashboardID = harness.appState.adoptDashboard(forNormalizedURL: Self.failedURL)
        KeychainHelper.saveConnection(
            HermesConnection(baseUrl: Self.failedURL, ticket: "saved-ticket"),
            dashboardID: dashboardID
        )

        harness.appState.loadSavedConnection()
        await fulfillment(of: [connected], timeout: 2)

        XCTAssertEqual(connectedTickets.first, "saved-ticket")
    }

    /// A mint cancelled under it (the bridge torn down by a switch or a
    /// sign-out) ends this restore: it never connects with the spent ticket.
    func testColdStartSavedSessionStopsWhenItsMintIsCancelled() async throws {
        let connectCount = RepairConnectCount()
        var mints = 0
        let harness = makeHarness(lifecycleOperations: coldStartLifecycle(
            mint: { _ in
                mints += 1
                throw CancellationError()
            },
            connected: { _ in connectCount.value += 1 }
        ))
        let dashboardID = harness.appState.adoptDashboard(forNormalizedURL: Self.failedURL)
        KeychainHelper.saveConnection(
            HermesConnection(baseUrl: Self.failedURL, ticket: "spent-ticket"),
            dashboardID: dashboardID
        )

        harness.appState.loadSavedConnection()
        let deadline = Date().addingTimeInterval(2)
        while (mints == 0 || harness.appState.isConnecting) && connectCount.value == 0 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(mints, 1)
        XCTAssertEqual(connectCount.value, 0, "the spent ticket is never tried")
        XCTAssertFalse(harness.appState.isConnecting, "the restore that still owns the flow stops connecting")
        XCTAssertNotEqual(harness.appState.turnState, .synchronizing, "nor leaves the composer synchronizing")
    }

    private func coldStartLifecycle(
        mint: @escaping @MainActor (String) async throws -> String,
        connected: @escaping @MainActor (HermesClient) async throws -> Void
    ) -> ChatResumeLifecycleOperations {
        ChatResumeLifecycleOperations(
            connectClient: connected,
            loadCatalog: { _, _ in [] },
            mintTicket: mint,
            openSession: { _, id, _ in
                SessionResumeResult(
                    sessionId: id,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            loadProfiles: {},
            loadBusyInputMode: { _ in },
            loadProfileDisplayPreferences: {},
            loadSlashCommands: {}
        )
    }

    func testNativeOAuthBridgeRebuildsAfterSameModeGrantReplacement() throws {
        let app = makeHarness().appState
        let id = app.adoptDashboard(forNormalizedURL: Self.failedURL)
        KeychainHelper.saveNativeOAuthTokens(oauthTokens("old"), dashboardID: id)
        app.prepareDashboardBridge(for: Self.failedURL)
        let oldBridge = try XCTUnwrap(app.dashboardTicketBridge)
        app.prepareDashboardBridge(for: Self.failedURL)
        XCTAssertTrue(app.dashboardTicketBridge === oldBridge, "Unchanged grants reuse the bridge")

        let replacement = oauthTokens("replacement")
        KeychainHelper.saveNativeOAuthTokens(replacement, dashboardID: id)
        app.prepareDashboardBridge(for: Self.failedURL)
        XCTAssertFalse(app.dashboardTicketBridge === oldBridge)
        XCTAssertTrue(app.dashboardTicketBridge?.matchesNativeOAuthTokens(replacement) == true)
        app.dashboardTicketBridge?.invalidate()
    }

    func testRejectedColdStartDiscardsTheStaleBearerBridge() async throws {
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            mintTicket: { _ in throw DashboardTicketBridgeError.signInRequired }
        ))
        let app = harness.appState
        let id = app.adoptDashboard(forNormalizedURL: Self.failedURL)
        KeychainHelper.saveNativeOAuthTokens(oauthTokens("rejected"), dashboardID: id)
        app.prepareDashboardBridge(for: Self.failedURL)
        XCTAssertTrue(app.dashboardTicketBridge?.usesNativeOAuth == true)
        // Model the rejected-refresh boundary: storage has been cleared but
        // the live bridge still owns the previous in-memory session.
        KeychainHelper.clearNativeOAuthTokens(dashboardID: id)
        await app.restoreNativeOAuthConnection(baseURL: Self.failedURL, dashboardID: id)
        XCTAssertNil(app.dashboardTicketBridge)
        XCTAssertTrue(app.showLogin)
        XCTAssertFalse(app.isConnected)
    }

    // MARK: - Race: explicit repair outranks late automatic recovery (spec 26)

    func testExplicitRepairOutranksLateAutomaticReconnect() async {
        let mintGate = RepairControlledSuspension()
        let connectCount = RepairConnectCount()
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            connectClient: { _ in connectCount.value += 1 },
            loadCatalog: { _, _ in [self.session("stored-a")] },
            mintTicket: { _ in
                await mintGate.suspend()
                return "late-ticket"
            },
            openSession: { _, id, _ in
                SessionResumeResult(sessionId: id, messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            refreshContext: { _, _ in },
            loadProfiles: {},
            loadBusyInputMode: { _ in },
            loadProfileDisplayPreferences: {},
            loadSlashCommands: {}
        ))
        let failedConnection = HermesConnection(baseUrl: ConnectionRepairTests.failedURL, ticket: "stale-ticket")
        harness.appState.connection = failedConnection
        harness.appState.client = HermesClient(connection: failedConnection, profile: "default")
        harness.appState.activeSessionId = "stored-a"
        harness.store.setLastSessionID("stored-a", for: "default")

        // Automatic reconnect A begins and suspends at the mint boundary.
        let taskA = Task { @MainActor in
            await harness.appState.reconnectForRetry(purpose: .automaticReturn)
        }
        await mintGate.waitUntilSuspended()

        // The user enters Repair: automatic recovery loses authority.
        XCTAssertNotNil(harness.appState.beginConnectionRepair())

        // Reconnect Now (candidate B) wins: explicit, preserveCurrent.
        let outcome = await harness.appState.performConnectionRepair(.native(candidate(
            ticket: "repaired-ticket",
            revision: 4,
            generation: 2
        )))
        XCTAssertEqual(outcome, .activated)
        XCTAssertEqual(harness.appState.connection?.ticket, "repaired-ticket")
        XCTAssertEqual(harness.appState.activeSessionId, "stored-a")
        XCTAssertEqual(harness.recoverySequence.currentPurpose, .preserveCurrent,
                       "The explicit repair reconnect never becomes an automaticReturn selection")

        // A finishes late — it must abort at its post-mint continuation
        // checkpoint, leaving B's connection and session untouched.
        mintGate.resume()
        await taskA.value

        XCTAssertEqual(harness.appState.connection?.ticket, "repaired-ticket", "A cannot overwrite B's connection")
        XCTAssertEqual(harness.appState.activeSessionId, "stored-a", "A cannot choose a different session")
        XCTAssertEqual(harness.recoverySequence.currentPurpose, .preserveCurrent,
                       "No automaticReturn selection occurs after B wins")
        XCTAssertEqual(connectCount.value, 1, "Only the explicit repair ever reached a connection")
    }
}

enum RepairControlledError: Error {
    case activationFailed
}

@MainActor
final class RepairReconnectExecutionSpy {
    var purposes: [ChatResumeSyncPurpose] = []
}

/// Minimal replicas of the AppStateChatResumeTests test doubles (those are
/// file-private there).
@MainActor
final class RepairConnectCount {
    var value = 0
}

@MainActor
final class RepairControlledSuspension {
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false

    func suspend() async {
        if resumed {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
        }
    }

    func resume() {
        resumed = true
        continuation?.resume()
        continuation = nil
    }

    func waitUntilSuspended() async {
        while continuation == nil {
            await Task.yield()
        }
    }
}

@MainActor
final class RepairControlledReconnectScheduler {
    struct Pending {
        let operation: @MainActor () async -> Void
    }

    private(set) var pending: [Pending] = []

    var pendingCount: Int { pending.count }

    func schedule(
        after delay: TimeInterval,
        operation: @escaping @MainActor () async -> Void
    ) -> ChatResumeReconnectCancellation {
        pending.append(Pending(operation: operation))
        return { [weak self] in
            self?.pending.removeAll()
        }
    }

    func runAll() async {
        let operations = pending.map(\.operation)
        pending.removeAll()
        for operation in operations {
            await operation()
        }
    }
}
