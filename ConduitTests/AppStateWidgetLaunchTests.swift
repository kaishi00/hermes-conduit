import XCTest
@testable import Conduit

@MainActor
final class AppStateWidgetLaunchTests: XCTestCase {
    func testAdmittedWidgetLaunchTakesPriorityOverAutomaticReturnSurface() throws {
        let suite = "AppStateWidgetLaunchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dashboard = SavedDashboard(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!,
            label: "Primary",
            normalizedURL: "https://primary.example"
        )
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard]),
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        appState.setChatReturnSurface(.sessions)
        appState.requestPreferredReturnSurface()
        let workspace = WidgetWorkspaceID(dashboardID: dashboard.id, profile: "default")
        let link = try XCTUnwrap(WidgetLaunchLink(action: .newChat, workspace: workspace, reference: nil))

        let coordinator = appState.widgetLaunchCoordinator
        coordinator.receive(link)

        XCTAssertTrue(appState.hasPendingExplicitNavigation)
        XCTAssertFalse(appState.claimPreferredReturnSurfacePresentation())
        coordinator.supersede()
        XCTAssertFalse(appState.hasPendingExplicitNavigation)
        XCTAssertFalse(appState.claimPreferredReturnSurfacePresentation(), "the explicit launch consumes the deferred return request")
    }

    func testActiveCallRefusesBeforeWorkspaceSwitch() async throws {
        let suite = "AppStateWidgetLaunchTests.call.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = dashboard("Current", id: "00000000-0000-0000-0000-0000000000a2")
        let requested = dashboard("Requested", id: "00000000-0000-0000-0000-0000000000a3")
        let appState = makeAppState(defaults: defaults, active: current, dashboards: [current, requested])
        _ = appState.handleScenePhase(.active)
        appState.showVoiceSheet = true
        let link = try XCTUnwrap(WidgetLaunchLink(
            action: .newChat,
            workspace: WidgetWorkspaceID(dashboardID: requested.id, profile: "default"),
            reference: nil
        ))
        let lease = WidgetLaunchLease(isCurrent: { true })

        let outcome = await appState.prepareWidgetLaunch(link, lease: lease)

        guard case .failed = outcome else { return XCTFail("a current call must reject another dashboard before switching") }
        XCTAssertEqual(appState.activeDashboardID, current.id)
    }

    func testActiveCallRefusesScopedOpenToAnotherDashboardBeforeChangingOwner() async throws {
        let suite = "AppStateWidgetLaunchTests.open-other-dashboard.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = dashboard("Current", id: "00000000-0000-0000-0000-0000000000b2")
        let requested = dashboard("Requested", id: "00000000-0000-0000-0000-0000000000b3")
        let appState = makeAppState(defaults: defaults, active: current, dashboards: [current, requested])
        _ = appState.handleScenePhase(.active)
        appState.showVoiceSheet = true
        let link = try XCTUnwrap(WidgetLaunchLink(
            action: .open,
            workspace: WidgetWorkspaceID(dashboardID: requested.id, profile: "default"),
            reference: nil
        ))

        let outcome = await appState.prepareWidgetLaunch(link, lease: WidgetLaunchLease(isCurrent: { true }))

        XCTAssertEqual(outcome, .failed(AppLocalization.string("End the call to open a chat in another workspace.")))
        XCTAssertEqual(appState.activeDashboardID, current.id)
        XCTAssertEqual(appState.activeProfile, "default")
        XCTAssertTrue(appState.showVoiceSheet)
        XCTAssertTrue(appState.isVoiceCallInProgress)
    }

    func testActiveCallRefusesScopedOpenToAnotherProfileBeforeSwitchAttempt() async throws {
        struct TicketBlocked: Error {}
        let suite = "AppStateWidgetLaunchTests.open-other-profile.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = dashboard("Current", id: "00000000-0000-0000-0000-0000000000b4")
        var ticketRequests = 0
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: current.id, dashboards: [current]),
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: ChatResumeLifecycleOperations(mintTicket: { _ in
                ticketRequests += 1
                throw TicketBlocked()
            }),
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        _ = appState.handleScenePhase(.active)
        appState.connection = HermesConnection(baseUrl: current.normalizedURL, ticket: "test")
        appState.isConnected = true
        appState.profiles = ["default", "work"]
        appState.showVoiceSheet = true
        let link = try XCTUnwrap(WidgetLaunchLink(
            action: .open,
            workspace: WidgetWorkspaceID(dashboardID: current.id, profile: "work"),
            reference: nil
        ))

        let outcome = await appState.prepareWidgetLaunch(link, lease: WidgetLaunchLease(isCurrent: { true }))

        XCTAssertEqual(outcome, .failed(AppLocalization.string("End the call to open a chat in another workspace.")))
        XCTAssertEqual(ticketRequests, 0, "a call must be refused before profile ticket mint or teardown")
        XCTAssertEqual(appState.activeDashboardID, current.id)
        XCTAssertEqual(appState.activeProfile, "default")
        XCTAssertTrue(appState.showVoiceSheet)
        XCTAssertTrue(appState.isVoiceCallInProgress)
    }

    func testActiveCallAllowsOpenWithoutWorkspaceChange() async throws {
        let suite = "AppStateWidgetLaunchTests.open-same-owner.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = dashboard("Current", id: "00000000-0000-0000-0000-0000000000b5")
        let appState = makeAppState(defaults: defaults, active: current, dashboards: [current])
        _ = appState.handleScenePhase(.active)
        appState.isConnected = true
        appState.showVoiceSheet = true
        let sameWorkspace = try XCTUnwrap(WidgetLaunchLink(
            action: .open,
            workspace: WidgetWorkspaceID(dashboardID: current.id, profile: "default"),
            reference: nil
        ))
        let unscoped = try XCTUnwrap(WidgetLaunchLink(action: .open, workspace: nil, reference: nil))

        let sameOutcome = await appState.prepareWidgetLaunch(sameWorkspace, lease: WidgetLaunchLease(isCurrent: { true }))
        let unscopedOutcome = await appState.prepareWidgetLaunch(unscoped, lease: WidgetLaunchLease(isCurrent: { true }))

        XCTAssertEqual(sameOutcome, .handled)
        XCTAssertEqual(unscopedOutcome, .handled)
        XCTAssertEqual(appState.activeDashboardID, current.id)
        XCTAssertEqual(appState.activeProfile, "default")
        XCTAssertTrue(appState.isVoiceCallInProgress)
    }

    func testUnsettledCatalogIsReadInsteadOfWaitedFor() async throws {
        let suite = "AppStateWidgetLaunchTests.unsettled-catalog.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = dashboard("Current", id: "00000000-0000-0000-0000-0000000000a7")
        var catalogLoads = 0
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: current.id, dashboards: [current]),
            clearSessionPresentationCache: {},
            sessionCatalogLoader: { _ in
                catalogLoads += 1
                return []
            },
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        _ = appState.handleScenePhase(.active)
        appState.isConnected = true
        // The link cancelled the sync that would have settled the catalog.
        XCTAssertNil(appState.widgetSettledCatalogOwner)
        let workspace = WidgetWorkspaceID(dashboardID: current.id, profile: "default")
        let link = try XCTUnwrap(WidgetLaunchLink(action: .newChat, workspace: workspace, reference: nil))

        let outcome = await appState.prepareWidgetLaunch(link, lease: WidgetLaunchLease(isCurrent: { true }))

        XCTAssertEqual(outcome, .handled, "New Chat must not wait for a catalog load nothing else starts")
        XCTAssertEqual(catalogLoads, 1)
        XCTAssertEqual(appState.widgetSettledCatalogOwner, workspace)
    }

    func testMissingConversationStaysInRequestedWorkspace() async throws {
        let suite = "AppStateWidgetLaunchTests.missing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = dashboard("Current", id: "00000000-0000-0000-0000-0000000000a4")
        let appState = makeAppState(defaults: defaults, active: current, dashboards: [current])
        _ = appState.handleScenePhase(.active)
        appState.isConnected = true
        let workspace = WidgetWorkspaceID(dashboardID: current.id, profile: "default")
        appState.widgetSettledCatalogOwner = workspace
        let reference = WidgetConversationReference(
            kind: .dashboard,
            scopeProfile: "default",
            botName: nil,
            botLabel: nil,
            sessionID: "removed-session",
            isUnverified: false
        )
        let link = try XCTUnwrap(WidgetLaunchLink(action: .resume, workspace: workspace, reference: reference))

        let outcome = await appState.prepareWidgetLaunch(link, lease: WidgetLaunchLease(isCurrent: { true }))

        guard case .failed = outcome else { return XCTFail("a settled missing target must be terminal") }
        XCTAssertEqual(appState.activeDashboardID, current.id)
        XCTAssertEqual(appState.activeProfile, "default")
        XCTAssertNil(appState.activeSessionId)
    }

    func testWidgetWaitsForInteractiveAuthentication() async throws {
        let suite = "AppStateWidgetLaunchTests.authentication.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = dashboard("Current", id: "00000000-0000-0000-0000-0000000000a5")
        let requested = dashboard("Requested", id: "00000000-0000-0000-0000-0000000000a6")
        let appState = makeAppState(defaults: defaults, active: current, dashboards: [current, requested])
        _ = appState.handleScenePhase(.active)
        let link = try XCTUnwrap(WidgetLaunchLink(
            action: .newChat,
            workspace: WidgetWorkspaceID(dashboardID: requested.id, profile: "default"),
            reference: nil
        ))

        let outcome = await appState.prepareWidgetLaunch(link, lease: WidgetLaunchLease(isCurrent: { true }))

        XCTAssertEqual(outcome, .deferred)
        XCTAssertTrue(appState.showLogin)
        XCTAssertEqual(appState.widgetAwaitingInteractiveAuthenticationDashboardID, requested.id)
    }

    func testWorkspaceFreeOpenWaitsForForegroundReadiness() async throws {
        let suite = "AppStateWidgetLaunchTests.open-readiness.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appState = makeAppState(defaults: defaults, active: dashboard("Current", id: "00000000-0000-0000-0000-0000000000a7"), dashboards: [])
        let link = try XCTUnwrap(WidgetLaunchLink(action: .open, workspace: nil, reference: nil))
        let outcome = await appState.prepareWidgetLaunch(link, lease: WidgetLaunchLease(isCurrent: { true }))
        XCTAssertEqual(outcome, .deferred)
    }

    func testWidgetCreateCannotAdoptSessionAfterLeaseRevocationDuringCreate() async throws {
        let suite = "AppStateWidgetLaunchTests.create-suspension.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = dashboard("Current", id: "00000000-0000-0000-0000-0000000000a8")
        let appState = makeAppState(defaults: defaults, active: current, dashboards: [current])
        let connection = HermesConnection(baseUrl: current.normalizedURL, ticket: "test")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true
        appState.activeSessionId = "existing-session"
        let createEntered = WidgetLaunchTestGate()
        let createRelease = WidgetLaunchTestGate()
        appState.widgetSessionCreatorOverride = { _, _ in
            await createEntered.signal()
            await createRelease.wait()
            return ("widget-created-runtime", "widget-created-stored", "default")
        }
        var currentLease = true
        let lease = WidgetLaunchLease(isCurrent: { currentLease })

        let creating = Task { await appState.createNewSession(widgetLease: lease) }
        guard await waitForGate(createEntered, "widget create never reached session creation") else { return }
        currentLease = false
        await createRelease.signal()
        _ = await creating.value

        XCTAssertEqual(appState.activeSessionId, "existing-session")
        XCTAssertEqual(appState.turnState, .idle, "the chat still open must not stay synchronizing")
    }

    /// #916: a new chat runs on the profile's default model, so it must not
    /// show the model the chat open before it was switched to.
    func testANewChatDoesNotShowThePreviousChatsModel() async throws {
        let suite = "AppStateWidgetLaunchTests.new-chat-model.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = dashboard("Current", id: "00000000-0000-0000-0000-0000000000b6")
        let appState = makeAppState(defaults: defaults, active: current, dashboards: [current])
        let connection = HermesConnection(baseUrl: current.normalizedURL, ticket: "test")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true
        appState.activeSessionId = "existing-session"
        appState.runtime.model = "minimax-m3"
        appState.runtime.provider = "minimax"
        appState.widgetSessionCreatorOverride = { _, _ in ("new-runtime", "new-stored", "default") }

        await appState.createNewSession()

        XCTAssertEqual(appState.activeSessionId, "new-runtime")
        XCTAssertEqual(appState.runtime.model, "", "the old chat's model is not this chat's")
        XCTAssertEqual(appState.runtime.provider, "")
        XCTAssertNotEqual(appState.sessions.first?.model, "minimax-m3")
    }

    func testWidgetResumeDoesNotAdoptResponseAfterLeaseRevocation() async throws {
        let suite = "AppStateWidgetLaunchTests.resume-suspension.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = dashboard("Current", id: "00000000-0000-0000-0000-0000000000a9")
        let entered = WidgetLaunchTestGate()
        let release = WidgetLaunchTestGate()
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: current.id, dashboards: [current]),
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    await entered.signal()
                    await release.wait()
                    return SessionResumeResult(
                        sessionId: sessionID,
                        storedSessionId: sessionID,
                        messages: [ChatMessage(id: "resume-response", role: .assistant, content: "Accepted response", timestamp: "1")],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in }
            ),
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        _ = appState.handleScenePhase(.active)
        let connection = HermesConnection(baseUrl: current.normalizedURL, ticket: "test")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true
        let workspace = WidgetWorkspaceID(dashboardID: current.id, profile: "default")
        appState.widgetSettledCatalogOwner = workspace
        appState.sessions = [session("requested-session")]
        let reference = WidgetConversationReference(
            kind: .dashboard,
            scopeProfile: "default",
            botName: nil,
            botLabel: nil,
            sessionID: "requested-session",
            isUnverified: false
        )
        var leaseIsCurrent = true
        let lease = WidgetLaunchLease(isCurrent: { leaseIsCurrent })
        let opening = Task { await appState.openWidgetConversation(reference, workspace: workspace, lease: lease) }
        guard await waitForGate(entered, "widget resume never reached the suspended RPC") else { return }
        leaseIsCurrent = false
        await release.signal()
        _ = await opening.value

        XCTAssertFalse(appState.messages.contains(where: { $0.id == "resume-response" }), "a revoked response with matching durable identity must not publish its transcript")
        XCTAssertNotEqual(appState.turnState, .synchronizing, "an expired open settles like a failed one")
    }

    func testCurrentWidgetResumeAdoptsIdentityConsistentResponse() async throws {
        let suite = "AppStateWidgetLaunchTests.resume-positive-control.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = dashboard("Current", id: "00000000-0000-0000-0000-0000000000af")
        let entered = WidgetLaunchTestGate()
        let release = WidgetLaunchTestGate()
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: current.id, dashboards: [current]),
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    await entered.signal()
                    await release.wait()
                    return SessionResumeResult(
                        sessionId: sessionID,
                        storedSessionId: sessionID,
                        messages: [ChatMessage(id: "resume-response", role: .assistant, content: "Accepted response", timestamp: "1")],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in }
            ),
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        _ = appState.handleScenePhase(.active)
        let connection = HermesConnection(baseUrl: current.normalizedURL, ticket: "test")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true
        let workspace = WidgetWorkspaceID(dashboardID: current.id, profile: "default")
        appState.widgetSettledCatalogOwner = workspace
        appState.sessions = [session("requested-session")]
        let reference = WidgetConversationReference(
            kind: .dashboard,
            scopeProfile: "default",
            botName: nil,
            botLabel: nil,
            sessionID: "requested-session",
            isUnverified: false
        )

        let opening = Task {
            await appState.openWidgetConversation(
                reference,
                workspace: workspace,
                lease: WidgetLaunchLease(isCurrent: { true })
            )
        }
        guard await waitForGate(entered, "current widget resume never reached the suspended RPC") else { return }
        await release.signal()
        let outcome = await opening.value

        XCTAssertEqual(outcome, .handled)
        XCTAssertTrue(appState.messages.contains(where: { $0.id == "resume-response" }), "the matching positive control must actually admit the response")
    }

    func testWidgetProfileSwitchStopsAfterTicketMintWhenLeaseIsRevoked() async throws {
        let suite = "AppStateWidgetLaunchTests.profile-suspension.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = dashboard("Current", id: "00000000-0000-0000-0000-0000000000ac")
        let ticketEntered = WidgetLaunchTestGate()
        let ticketRelease = WidgetLaunchTestGate()
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: current.id, dashboards: [current]),
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: ChatResumeLifecycleOperations(mintTicket: { _ in
                await ticketEntered.signal()
                await ticketRelease.wait()
                return "next-ticket"
            }),
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        let connection = HermesConnection(baseUrl: current.normalizedURL, ticket: "test")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true
        var leaseIsCurrent = true
        let lease = WidgetLaunchLease(isCurrent: { leaseIsCurrent })

        let switching = Task { await appState.switchProfileForWidget(to: "work", lease: lease) }
        guard await waitForGate(ticketEntered, "widget profile switch never reached ticket mint") else { return }
        leaseIsCurrent = false
        await ticketRelease.signal()

        let switched = await switching.value
        XCTAssertFalse(switched)
        XCTAssertEqual(appState.activeProfile, "default", "a canceled profile ticket must not commit the new profile")
        XCTAssertNotEqual(appState.turnState, .synchronizing, "the previous profile gets its turn state back")
    }

    func testWidgetVoiceCapabilityWaitStopsBeforeSessionCreationAfterRevocation() async throws {
        let suite = "AppStateWidgetLaunchTests.voice-capability-suspension.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = dashboard("Current", id: "00000000-0000-0000-0000-0000000000ad")
        let appState = makeAppState(defaults: defaults, active: current, dashboards: [current])
        let connection = HermesConnection(baseUrl: current.normalizedURL, ticket: "test")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true
        appState.installVoiceCapabilityStateForTesting(
            bridge: DashboardTicketBridge(baseURL: current.normalizedURL),
            snapshot: VoiceCapabilitySnapshot(isGatewayConnected: true, supportsTranscription: true, supportsSpeech: true, unavailableReason: nil),
            isVoiceEnabled: true
        )
        let requester = SuspendedWidgetVoiceConfigurationRequester()
        appState.voiceCapabilityRequesterForTesting = requester
        var leaseIsCurrent = true
        let lease = WidgetLaunchLease(isCurrent: { leaseIsCurrent })

        let preparing = Task {
            await appState.prepareVoiceConversation(profile: "default", startsFreshConversation: true, widgetLease: lease)
        }
        guard await waitForGate(requester.entered, "widget voice preparation never reached capability refresh") else { return }
        leaseIsCurrent = false
        await requester.release.signal()

        let outcome = await preparing.value
        XCTAssertEqual(outcome, .deferred)
        XCTAssertNil(appState.activeSessionId, "revocation during capability refresh must precede fresh-session creation")
        XCTAssertFalse(appState.showVoiceSheet)
    }

    func testWidgetResumeSupersedesSuspendedAutomaticRestoration() async throws {
        let suite = "AppStateWidgetLaunchTests.automatic-restore-suspension.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = dashboard("Current", id: "00000000-0000-0000-0000-0000000000ae")
        let store = ChatResumeStore(defaults: defaults, storageKey: "resume.\(suite)")
        store.setLastSession(.dashboard(profile: "default", sessionID: "automatic-target"), for: "default")
        let automaticEntered = WidgetLaunchTestGate()
        let automaticRelease = WidgetLaunchTestGate()
        var openCount = 0
        let appState = AppState(
            defaults: defaults,
            chatResumeCoordinator: ChatResumeCoordinator(store: store),
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: current.id, dashboards: [current]),
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [self.session("automatic-target"), self.session("widget-target")] },
                openSession: { _, sessionID, _ in
                    openCount += 1
                    if openCount == 1 {
                        await automaticEntered.signal()
                        await automaticRelease.wait()
                    }
                    return SessionResumeResult(
                        sessionId: sessionID,
                        storedSessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                botRoster: { _ in BotRosterSnapshot(bots: [], supportsBotProtocol: false) }
            ),
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        _ = appState.handleScenePhase(.active)
        let connection = HermesConnection(baseUrl: current.normalizedURL, ticket: "test")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true
        let automatic = Task {
            await appState.syncSession(purpose: .automaticReturn, using: nil, automaticWorkToken: nil)
        }
        guard await waitForGate(automaticEntered, "automatic restoration never reached its suspended resume") else { return }

        let workspace = WidgetWorkspaceID(dashboardID: current.id, profile: "default")
        appState.widgetSettledCatalogOwner = workspace
        appState.sessions = [session("automatic-target"), session("widget-target")]
        let reference = WidgetConversationReference(
            kind: .dashboard,
            scopeProfile: "default",
            botName: nil,
            botLabel: nil,
            sessionID: "widget-target",
            isUnverified: false
        )
        let widgetOutcome = await appState.openWidgetConversation(
            reference,
            workspace: workspace,
            lease: WidgetLaunchLease(isCurrent: { true })
        )
        XCTAssertEqual(widgetOutcome, .handled)
        XCTAssertEqual(appState.activeSessionId, "widget-target")

        await automaticRelease.signal()
        await automatic.value
        XCTAssertEqual(appState.activeSessionId, "widget-target", "the suspended automatic restore must not replace explicit widget selection")
    }

    func testBotOwnerCollisionUsesTypedReference() async throws {
        let suite = "AppStateWidgetLaunchTests.bot-collision.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = dashboard("Current", id: "00000000-0000-0000-0000-0000000000aa")
        let bot = BotProfile(
            name: "bot-a",
            botTitle: nil,
            displayName: "Bot A",
            profileDescription: "",
            model: nil,
            provider: nil,
            hasAvatar: false,
            isPinned: false,
            isHiddenByMeta: false,
            appearanceColor: nil,
            canonicalSession: BotCanonicalSession(id: "stored-bot-chat", resolvedID: "shared-runtime-id", lastActive: nil, preview: nil),
            lastActive: nil,
            lastPreview: nil
        )
        var opened: [(String, String?)] = []
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: current.id, dashboards: [current]),
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: ChatResumeLifecycleOperations(
                openSessionWithProfile: { _, sessionID, _, profile in
                    opened.append((sessionID, profile))
                    return SessionResumeResult(
                        sessionId: sessionID,
                        storedSessionId: "stored-bot-chat",
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                botRoster: { _ in BotRosterSnapshot(bots: [bot], supportsBotProtocol: true) },
                findBotChat: { _, name in
                    XCTAssertEqual(name, "bot-a")
                    return [BotChatLookupRow(id: "stored-bot-chat", resolvedID: "shared-runtime-id", title: "Bot Chat")]
                }
            ),
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        _ = appState.handleScenePhase(.active)
        let connection = HermesConnection(baseUrl: current.normalizedURL, ticket: "test")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true
        await appState.refreshBotRoster()
        let workspace = WidgetWorkspaceID(dashboardID: current.id, profile: "default")
        appState.widgetSettledCatalogOwner = workspace
        appState.sessions = [session("shared-runtime-id", profile: "default")]
        let reference = WidgetConversationReference(
            kind: .bot,
            scopeProfile: "bot-a",
            botName: "bot-a",
            botLabel: nil,
            sessionID: "shared-runtime-id",
            isUnverified: false
        )

        let outcome = await appState.openWidgetConversation(
            reference,
            workspace: workspace,
            lease: WidgetLaunchLease(isCurrent: { true })
        )

        XCTAssertEqual(outcome, .handled)
        XCTAssertEqual(opened.map { $0.0 }, ["shared-runtime-id"])
        XCTAssertEqual(opened.map { $0.1 }, ["bot-a"], "same-ID dashboard ownership must not override the typed Bot reference")
    }

    func testUnavailableBotLookupLeavesViewportUnfrozen() async throws {
        let suite = "AppStateWidgetLaunchTests.bot-unavailable.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = dashboard("Current", id: "00000000-0000-0000-0000-0000000000b0")
        let store = ChatResumeStore(defaults: defaults, storageKey: "resume.\(suite)")
        let bot = BotProfile(
            name: "bot-a",
            botTitle: nil,
            displayName: "Bot A",
            profileDescription: "",
            model: nil,
            provider: nil,
            hasAvatar: false,
            isPinned: false,
            isHiddenByMeta: false,
            appearanceColor: nil,
            canonicalSession: BotCanonicalSession(id: "stored-bot-chat", resolvedID: nil, lastActive: nil, preview: nil),
            lastActive: nil,
            lastPreview: nil
        )
        let appState = AppState(
            defaults: defaults,
            chatResumeCoordinator: ChatResumeCoordinator(store: store),
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: current.id, dashboards: [current]),
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: ChatResumeLifecycleOperations(
                refreshContext: { _, _ in },
                botRoster: { _ in BotRosterSnapshot(bots: [bot], supportsBotProtocol: true) },
                findBotChat: { _, _ in [] }
            ),
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        _ = appState.handleScenePhase(.active)
        let connection = HermesConnection(baseUrl: current.normalizedURL, ticket: "test")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true
        await appState.refreshBotRoster()
        appState.activeSessionId = "visible-session"
        let workspace = WidgetWorkspaceID(dashboardID: current.id, profile: "default")
        appState.widgetSettledCatalogOwner = workspace
        let reference = WidgetConversationReference(
            kind: .bot,
            scopeProfile: "bot-a",
            botName: "bot-a",
            botLabel: nil,
            sessionID: "stored-bot-chat",
            isUnverified: false
        )

        let outcome = await appState.openWidgetConversation(
            reference,
            workspace: workspace,
            lease: WidgetLaunchLease(isCurrent: { true })
        )

        guard case .failed = outcome else { return XCTFail("a Bot whose exact chat cannot be resolved should fail") }
        let visibleKey = ChatScrollSessionKey(profile: "default", sessionID: "visible-session")
        appState.recordChatViewport(.latest, for: visibleKey)
        appState.flushChatResumeViewport()
        XCTAssertEqual(store.snapshot(for: visibleKey), .latest, "a failed Bot lookup must not leave the existing viewport frozen")
    }

    func testColdNewChatAndWarmTalkStartFreshOnce() async throws {
        let suite = "AppStateWidgetLaunchTests.warm-cold.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = dashboard("Current", id: "00000000-0000-0000-0000-0000000000ab")
        let createEntered = WidgetLaunchTestGate()
        let createRelease = WidgetLaunchTestGate()
        let talkCreateEntered = WidgetLaunchTestGate()
        let talkCreateRelease = WidgetLaunchTestGate()
        var createdIDs: [String] = []
        let appState = makeAppState(defaults: defaults, active: current, dashboards: [current])
        let connection = HermesConnection(baseUrl: current.normalizedURL, ticket: "test")
        appState.widgetSessionCreatorOverride = { _, _ in
            let id = "widget-create-\(createdIDs.count + 1)"
            createdIDs.append(id)
            switch createdIDs.count {
            case 1:
                await createEntered.signal()
                await createRelease.wait()
            case 3:
                await talkCreateEntered.signal()
                await talkCreateRelease.wait()
            default:
                break
            }
            return (id, id, "default")
        }
        let workspace = WidgetWorkspaceID(dashboardID: current.id, profile: "default")
        appState.widgetSettledCatalogOwner = workspace
        let coldNewChat = try XCTUnwrap(WidgetLaunchLink(action: .newChat, workspace: workspace, reference: nil))

        appState.widgetLaunchCoordinator.receive(coldNewChat)
        XCTAssertEqual(appState.widgetLaunchCoordinator.hasPendingRequest, true)
        _ = appState.handleScenePhase(.active)
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true
        guard await waitForGate(createEntered, "cold New Chat never reached session creation", retryReadinessIn: appState) else { return }
        appState.widgetLaunchCoordinator.receive(coldNewChat)
        await createRelease.signal()
        guard await waitForLaunchCompletion(appState) else { return }
        XCTAssertEqual(createdIDs, ["widget-create-1"], "a cold-start duplicate during one create is coalesced")
        appState.widgetLaunchCoordinator.receive(coldNewChat)
        guard await waitForLaunchCompletion(appState) else { return }
        XCTAssertEqual(createdIDs, ["widget-create-1", "widget-create-2"], "a deliberate New Chat retap after completion starts a new fresh session")

        appState.voiceCapabilityRequesterForTesting = ImmediateVoiceConfigRequester(mode: .fullSupport)
        appState.installVoiceCapabilityStateForTesting(
            bridge: DashboardTicketBridge(baseURL: current.normalizedURL),
            snapshot: VoiceCapabilitySnapshot(isGatewayConnected: true, supportsTranscription: true, supportsSpeech: true, unavailableReason: nil),
            isVoiceEnabled: true
        )
        defaults.set(true, forKey: "conduit.voice.enabled.v1.\(current.normalizedURL).default")
        let talk = try XCTUnwrap(WidgetLaunchLink(action: .talk, workspace: workspace, reference: nil))

        appState.widgetLaunchCoordinator.receive(talk)
        guard await waitForGate(talkCreateEntered, "warm Talk never reached session creation") else { return }
        appState.widgetLaunchCoordinator.receive(talk)
        await talkCreateRelease.signal()
        guard await waitForLaunchCompletion(appState) else { return }

        XCTAssertEqual(createdIDs, ["widget-create-1", "widget-create-2", "widget-create-3"], "an in-flight Talk duplicate shares one fresh call session")
        XCTAssertTrue(appState.showVoiceSheet)
        XCTAssertEqual(appState.activeSessionId, "widget-create-3")
    }

    func testColdTalkAndWarmNewChatStartFreshOnce() async throws {
        let suite = "AppStateWidgetLaunchTests.cold-talk-warm-new-chat.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = dashboard("Current", id: "00000000-0000-0000-0000-0000000000b1")
        let talkCreateEntered = WidgetLaunchTestGate()
        let talkCreateRelease = WidgetLaunchTestGate()
        var createdIDs: [String] = []
        let appState = makeAppState(defaults: defaults, active: current, dashboards: [current])
        let connection = HermesConnection(baseUrl: current.normalizedURL, ticket: "test")
        appState.widgetSessionCreatorOverride = { _, _ in
            let id = "cold-talk-create-\(createdIDs.count + 1)"
            createdIDs.append(id)
            if createdIDs.count == 1 {
                await talkCreateEntered.signal()
                await talkCreateRelease.wait()
            }
            return (id, id, "default")
        }
        let workspace = WidgetWorkspaceID(dashboardID: current.id, profile: "default")
        appState.widgetSettledCatalogOwner = workspace
        let talk = try XCTUnwrap(WidgetLaunchLink(action: .talk, workspace: workspace, reference: nil))

        appState.widgetLaunchCoordinator.receive(talk)
        XCTAssertTrue(appState.widgetLaunchCoordinator.hasPendingRequest, "a cold Talk waits for scene foreground readiness")
        _ = appState.handleScenePhase(.active)
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true
        appState.voiceCapabilityRequesterForTesting = ImmediateVoiceConfigRequester(mode: .fullSupport)
        appState.installVoiceCapabilityStateForTesting(
            bridge: DashboardTicketBridge(baseURL: current.normalizedURL),
            snapshot: VoiceCapabilitySnapshot(isGatewayConnected: true, supportsTranscription: true, supportsSpeech: true, unavailableReason: nil),
            isVoiceEnabled: true
        )
        defaults.set(true, forKey: "conduit.voice.enabled.v1.\(current.normalizedURL).default")
        guard await waitForGate(talkCreateEntered, "cold Talk never reached session creation", retryReadinessIn: appState) else { return }
        appState.widgetLaunchCoordinator.receive(talk)
        await talkCreateRelease.signal()
        guard await waitForLaunchCompletion(appState) else { return }

        XCTAssertEqual(createdIDs, ["cold-talk-create-1"], "duplicate cold Talk delivery during creation is coalesced")
        XCTAssertTrue(appState.showVoiceSheet)
        XCTAssertEqual(appState.activeSessionId, "cold-talk-create-1")

        appState.closeVoiceConversation()
        XCTAssertFalse(appState.isVoiceCallInProgress)
        let newChat = try XCTUnwrap(WidgetLaunchLink(action: .newChat, workspace: workspace, reference: nil))
        appState.widgetLaunchCoordinator.receive(newChat)
        guard await waitForLaunchCompletion(appState) else { return }
        XCTAssertEqual(createdIDs, ["cold-talk-create-1", "cold-talk-create-2"], "warm New Chat creates one separate fresh session")
        XCTAssertEqual(appState.activeSessionId, "cold-talk-create-2")
    }

    func testWidgetNewChatClosesTheSessionsDrawerAndSheetsOverTheChat() async throws {
        let suite = "AppStateWidgetLaunchTests.reveal-chat.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = dashboard("Current", id: "00000000-0000-0000-0000-0000000000c1")
        let appState = makeAppState(defaults: defaults, active: current, dashboards: [current])
        appState.widgetSessionCreatorOverride = { _, _ in ("widget-reveal", "widget-reveal", "default") }
        let workspace = WidgetWorkspaceID(dashboardID: current.id, profile: "default")
        appState.widgetSettledCatalogOwner = workspace
        _ = appState.handleScenePhase(.active)
        let connection = HermesConnection(baseUrl: current.normalizedURL, ticket: "test")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true
        // Left open when the app went away, or put up as the Sessions
        // return surface before the widget's link arrived.
        appState.showSidebar = true
        appState.showModelPicker = true
        appState.isSettingsSheetPresented = true
        let settingsDismissals = appState.settingsDismissRequest
        let newChat = try XCTUnwrap(WidgetLaunchLink(action: .newChat, workspace: workspace, reference: nil))

        appState.widgetLaunchCoordinator.receive(newChat)
        guard await waitForLaunchCompletion(appState) else { return }

        XCTAssertEqual(appState.activeSessionId, "widget-reveal")
        XCTAssertFalse(appState.showSidebar, "the new chat must not open behind the Sessions drawer")
        XCTAssertFalse(appState.showModelPicker)
        XCTAssertNotEqual(appState.settingsDismissRequest, settingsDismissals, "Settings is asked to close too")
    }

    /// New Chat tapped while Conduit connects shows its chat at once, as the
    /// empty chat it will be, and Hermes creates it once connected.
    func testNewChatWhileConnectingShowsItsChatAtOnce() async throws {
        let suite = "AppStateWidgetLaunchTests.new-chat-connecting.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = dashboard("Current", id: "00000000-0000-0000-0000-0000000000c2")
        let appState = makeAppState(defaults: defaults, active: current, dashboards: [current])
        appState.widgetSessionCreatorOverride = { _, _ in ("in-app-new", "in-app-new", "default") }
        let workspace = WidgetWorkspaceID(dashboardID: current.id, profile: "default")
        _ = appState.handleScenePhase(.active)
        appState.showLogin = false
        let connection = HermesConnection(baseUrl: current.normalizedURL, ticket: "test")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        XCTAssertFalse(appState.canTapNewChat, "with no connection on its way there is nothing to wait for")
        appState.isConnecting = true
        appState.showSidebar = true
        XCTAssertTrue(appState.canTapNewChat, "New Chat works while Conduit connects")

        appState.startNewChat()

        XCTAssertEqual(appState.pendingNewChat, workspace)
        XCTAssertFalse(appState.showSidebar, "the new chat shows straight away")
        XCTAssertEqual(appState.displayedChatTitle, AppLocalization.string("New conversation"))
        XCTAssertNil(appState.activeChatSessionSummary)
        XCTAssertFalse(appState.composerIsEnabled, "remote controls wait for the chat's creation")
        XCTAssertTrue(appState.composerTakesText, "text can wait for the new chat")
        XCTAssertEqual(appState.composerAction(hasText: true, hasAttachments: false), .send)
        XCTAssertEqual(
            appState.composerPlaceholder,
            AppLocalization.string("Message \(appState.profileDisplayName(appState.activeProfile))…")
        )
        appState.startNewChat()
        XCTAssertEqual(appState.pendingNewChat, workspace, "another tap shows the same new chat")

        appState.widgetSettledCatalogOwner = workspace
        appState.isConnecting = false
        appState.isConnected = true
        guard await waitForLaunchCompletion(appState) else { return }

        XCTAssertEqual(appState.activeSessionId, "in-app-new")
        XCTAssertFalse(appState.showsPendingNewChat)
    }

    /// A New Chat from the app that can't start says so in the app's words;
    /// a widget's keeps the widget's, and shows its chat as its link arrives.
    func testNewChatThatCantStartSaysSo() async throws {
        struct CreateRefused: Error {}
        let suite = "AppStateWidgetLaunchTests.new-chat-failed.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = dashboard("Current", id: "00000000-0000-0000-0000-0000000000c3")
        let appState = makeAppState(defaults: defaults, active: current, dashboards: [current])
        appState.widgetSessionCreatorOverride = { _, _ in throw CreateRefused() }
        let workspace = WidgetWorkspaceID(dashboardID: current.id, profile: "default")
        _ = appState.handleScenePhase(.active)
        appState.showLogin = false
        let connection = HermesConnection(baseUrl: current.normalizedURL, ticket: "test")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.widgetSettledCatalogOwner = workspace
        let openChat = appState.activeSessionId
        appState.isConnecting = true

        appState.startNewChat()
        appState.isConnecting = false
        appState.isConnected = true
        guard await waitForLaunchCompletion(appState) else { return }

        XCTAssertFalse(appState.showsPendingNewChat)
        XCTAssertEqual(appState.activeSessionId, openChat)
        XCTAssertEqual(appState.errorMessage, AppLocalization.string("Couldn't start a new chat. Check your connection and try again."))

        appState.isConnected = false
        appState.isConnecting = true
        appState.showSidebar = true
        let newChat = try XCTUnwrap(WidgetLaunchLink(action: .newChat, workspace: workspace, reference: nil))
        XCTAssertTrue(appState.routeWidgetLaunchURL(newChat.url))
        XCTAssertEqual(appState.pendingNewChat, workspace)
        XCTAssertFalse(appState.showSidebar, "the widget's new chat shows as its link arrives")
        appState.isConnecting = false
        appState.isConnected = true
        guard await waitForLaunchCompletion(appState) else { return }

        XCTAssertFalse(appState.showsPendingNewChat)
        XCTAssertEqual(appState.errorMessage, AppLocalization.string("WidgetLaunch.ConversationUnavailable"))
    }

    /// Talk tapped while Conduit connects shows its call screen at once,
    /// connecting, and the call starts on that screen once Hermes answers.
    func testTalkWhileConnectingShowsItsCallScreenAtOnce() async throws {
        let suite = "AppStateWidgetLaunchTests.talk-connecting.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = dashboard("Current", id: "00000000-0000-0000-0000-0000000000c4")
        let (appState, connection, session) = makeConnectingGPTLiveAppState(defaults: defaults, dashboard: current)
        let workspace = WidgetWorkspaceID(dashboardID: current.id, profile: "default")
        appState.showSidebar = true
        let talk = try XCTUnwrap(WidgetLaunchLink(action: .talk, workspace: workspace, reference: nil))

        XCTAssertTrue(appState.routeWidgetLaunchURL(talk.url))

        XCTAssertTrue(appState.showGPTLiveSheet, "the call screen shows as the link arrives")
        XCTAssertEqual(appState.waitingCall?.engine, .gptLive)
        XCTAssertFalse(appState.showSidebar)
        XCTAssertFalse(appState.isVoiceCallInProgress, "a screen waiting for its call is no call yet")
        XCTAssertEqual(session.started, 0, "the call waits for Hermes")

        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnecting = false
        appState.isConnected = true
        guard await waitForLaunchCompletion(appState) else { return }
        guard await waitUntil("the call never started", { session.started == 1 }) else { return }

        XCTAssertTrue(appState.gptLiveController.isActive, "the call starts on the screen that waited for it")
        XCTAssertNil(appState.waitingCall)
        XCTAssertTrue(appState.showGPTLiveSheet)
        appState.closeGPTLiveConversation()
    }

    /// End or Close on a Talk's waiting screen calls the Talk off. The app's
    /// screen giving way under it doesn't, and a newer destination takes the
    /// screen with the Talk.
    func testHangingUpATalkStillConnectingCallsItOff() async throws {
        let suite = "AppStateWidgetLaunchTests.talk-hang-up.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = dashboard("Current", id: "00000000-0000-0000-0000-0000000000c5")
        let (appState, connection, session) = makeConnectingGPTLiveAppState(defaults: defaults, dashboard: current)
        let workspace = WidgetWorkspaceID(dashboardID: current.id, profile: "default")
        let talk = try XCTUnwrap(WidgetLaunchLink(action: .talk, workspace: workspace, reference: nil))
        XCTAssertTrue(appState.routeWidgetLaunchURL(talk.url))
        XCTAssertTrue(appState.showGPTLiveSheet)

        // What SwiftUI reports when the screen presenting the sheet goes.
        appState.liveVoiceSheetDismissed(.gptLive)
        XCTAssertTrue(appState.widgetLaunchCoordinator.hasPendingRequest, "the Talk still opens its call once it can")
        XCTAssertEqual(appState.waitingCall?.engine, .gptLive)

        appState.closeGPTLiveConversation()

        XCTAssertFalse(appState.showGPTLiveSheet)
        XCTAssertNil(appState.waitingCall)
        XCTAssertFalse(appState.widgetLaunchCoordinator.hasPendingRequest, "hanging up calls the Talk off")

        XCTAssertTrue(appState.routeWidgetLaunchURL(talk.url))
        XCTAssertTrue(appState.showGPTLiveSheet)
        appState.widgetLaunchCoordinator.supersede()
        XCTAssertFalse(appState.showGPTLiveSheet, "a newer destination takes the waiting screen with it")
        XCTAssertNil(appState.waitingCall)

        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnecting = false
        appState.isConnected = true
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(session.started, 0, "nothing starts once Hermes answers")
    }

    /// Conduit on its way to `dashboard`, connecting with no connection yet
    /// (a cold launch signing in), and GPT-Live chosen there over a fake call.
    private func makeConnectingGPTLiveAppState(
        defaults: UserDefaults,
        dashboard: SavedDashboard
    ) -> (AppState, HermesConnection, FakeGPTLiveSessionControl) {
        let appState = makeAppState(defaults: defaults, active: dashboard, dashboards: [dashboard])
        appState.widgetSettledCatalogOwner = WidgetWorkspaceID(dashboardID: dashboard.id, profile: "default")
        _ = appState.handleScenePhase(.active)
        appState.showLogin = false
        let connection = HermesConnection(baseUrl: dashboard.normalizedURL, ticket: "test")
        // The setting is kept for the dashboard's server.
        appState.connection = connection
        appState.setGPTLiveEnabled(true)
        appState.connection = nil
        appState.isConnecting = true
        let session = FakeGPTLiveSessionControl()
        let client = FakeGPTLiveClient()
        _ = appState.gptLiveController
        appState.gptLiveController = GPTLiveConversationController(
            makeSession: { session },
            availability: { try await client.availability() },
            briefing: { "[rules]" },
            supervisor: appState.voiceBackgroundJobSupervisor,
            requestPermission: { true }
        )
        return (appState, connection, session)
    }

    /// Yields until `condition` holds, for up to 10 s: a fixed number of
    /// yields can run out on a busy hosted runner.
    private func waitUntil(_ failure: String, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail(failure)
                return false
            }
            await Task.yield()
        }
        return true
    }

    private func session(_ id: String, profile: String? = "default") -> SessionSummary {
        SessionSummary(
            id: id,
            storedSessionId: nil,
            alternateIds: [],
            title: id,
            model: "Hermes",
            updatedLabel: "",
            profile: profile,
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
    }

    private func waitForGate(
        _ gate: WidgetLaunchTestGate,
        _ failure: String,
        retryReadinessIn appState: AppState? = nil
    ) async -> Bool {
        for _ in 0..<10_000 {
            if gate.isSignaled { return true }
            appState?.widgetLaunchCoordinator.readinessChanged()
            await Task.yield()
        }
        XCTFail(failure)
        return false
    }

    /// On a Mac the app's own New Chat opens ready to type, connected or
    /// waiting for the connection; elsewhere the keyboard stays down.
    func testInAppNewChatFocusesItsComposerOnlyOnAMac() async throws {
        for focuses in [true, false] {
            let suite = "AppStateWidgetLaunchTests.new-chat-focus.\(focuses).\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let current = dashboard("Current", id: "00000000-0000-0000-0000-0000000000c4")
            let appState = makeAppState(defaults: defaults, active: current, dashboards: [current])
            appState.newChatFocusesComposer = focuses
            appState.widgetSessionCreatorOverride = { _, _ in ("queued-new", "queued-new", "default") }
            _ = appState.handleScenePhase(.active)
            appState.showLogin = false
            let connection = HermesConnection(baseUrl: current.normalizedURL, ticket: "test")
            appState.connection = connection
            appState.client = HermesClient(connection: connection, profile: "default")
            appState.widgetSettledCatalogOwner = WidgetWorkspaceID(dashboardID: current.id, profile: "default")
            appState.isConnecting = true

            appState.startNewChat()
            appState.isConnecting = false
            appState.isConnected = true
            guard await waitForLaunchCompletion(appState) else { return }

            XCTAssertEqual(appState.activeSessionId, "queued-new")
            XCTAssertEqual(appState.composerFocusRequest?.sessionID, focuses ? "queued-new" : nil)

            appState.composerFocusRequest = nil
            appState.widgetSessionCreatorOverride = { _, _ in ("direct-new", "direct-new", "default") }
            appState.startNewChat()
            guard await waitForNewChatStart(appState) else { return }

            XCTAssertEqual(appState.activeSessionId, "direct-new")
            XCTAssertEqual(appState.composerFocusRequest?.sessionID, focuses ? "direct-new" : nil)
        }
    }

    /// A chat that came on screen while New Chat was being created (a
    /// notification, a list tap) isn't the new chat, and keeps its keyboard
    /// down even though the open chat changed.
    func testNewChatDoesNotFocusAChatOpenedWhileItWasCreated() async throws {
        struct CreateRefused: Error {}
        let suite = "AppStateWidgetLaunchTests.new-chat-focus-race.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = dashboard("Current", id: "00000000-0000-0000-0000-0000000000c5")
        let appState = makeAppState(defaults: defaults, active: current, dashboards: [current])
        appState.newChatFocusesComposer = true
        _ = appState.handleScenePhase(.active)
        appState.showLogin = false
        let connection = HermesConnection(baseUrl: current.normalizedURL, ticket: "test")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true
        appState.activeSessionId = "earlier-new"
        appState.newChatOpenedSessionID = "earlier-new"
        appState.widgetSessionCreatorOverride = { [weak appState] _, _ in
            appState?.activeSessionId = "opened-meanwhile"
            throw CreateRefused()
        }

        appState.startNewChat()
        guard await waitForNewChatStart(appState) else { return }

        XCTAssertEqual(appState.activeSessionId, "opened-meanwhile")
        XCTAssertNil(appState.composerFocusRequest)
    }

    private func waitForNewChatStart(_ appState: AppState) async -> Bool {
        for _ in 0..<10_000 {
            if !appState.isStartingNewChat { return true }
            await Task.yield()
        }
        XCTFail("New Chat did not finish before the deterministic wait budget ended")
        return false
    }

    private func waitForLaunchCompletion(_ appState: AppState) async -> Bool {
        for _ in 0..<10_000 {
            if !appState.widgetLaunchCoordinator.hasPendingRequest { return true }
            await Task.yield()
        }
        XCTFail("widget launch did not complete before the deterministic wait budget ended")
        return false
    }

    private func dashboard(_ label: String, id: String) -> SavedDashboard {
        SavedDashboard(
            id: UUID(uuidString: id)!,
            label: label,
            normalizedURL: "https://\(label.lowercased()).example"
        )
    }

    private func makeAppState(defaults: UserDefaults, active: SavedDashboard, dashboards: [SavedDashboard]) -> AppState {
        AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: active.id, dashboards: dashboards),
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
    }
}

@MainActor
private final class SuspendedWidgetVoiceConfigurationRequester: VoiceConfigurationRequesting {
    let entered = WidgetLaunchTestGate()
    let release = WidgetLaunchTestGate()
    private var hasSuspendedFirstRequest = false

    func requestJSON(path: String, method: String, body: [String: Any]?) async throws -> [String: Any] {
        if !hasSuspendedFirstRequest {
            hasSuspendedFirstRequest = true
            await entered.signal()
            await release.wait()
        }
        return [:]
    }
}

@MainActor
private final class WidgetLaunchTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var isSignaled: Bool { isOpen }

    func signal() async {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
