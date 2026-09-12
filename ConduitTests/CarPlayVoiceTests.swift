//
//  CarPlayVoiceTests.swift
//  Conduit
//
//  CarPlay Voice V1: scene manifest regression, state mapping, template
//  shape, duplicate-suppression, same-instance guarantees, surface-activity
//  lifecycle (phone background vs CarPlay), attach-without-restart, the
//  authoritative End teardown, re-listen with Continuous Conversation OFF,
//  unavailability fail-closed behavior, and stale-generation fencing.
//
//  No CarPlay hardware is involved: the coordinator is exercised through the
//  CarPlayInterfacing seam and a state-activator recorder; only plain
//  CarPlay value/container objects are constructed.
//

import AVFAudio
import CarPlay
import XCTest
@testable import Conduit

// MARK: - Scene manifest regression

@MainActor
final class CarPlaySceneManifestTests: XCTestCase {
    private var sceneManifest: [String: Any] {
        Bundle.main.infoDictionary?["UIApplicationSceneManifest"] as? [String: Any] ?? [:]
    }

    func testSupportsMultipleScenesEnabledForPhoneAndCarPlayCoexistence() {
        // UIKit creates the phone UIWindow scene AND the connected
        // CPTemplateApplicationScene concurrently, so multiple-scene support
        // must be enabled. The foreground role stays single-window through
        // SwiftUI's singleton `Window` scene (not WindowGroup), so this is
        // never an iPad multi-window product. These plist assertions pin the
        // supported CONFIGURATION only — runtime coexistence additionally
        // needs the CarPlay Simulator / a vehicle and stays on the physical
        // checklist.
        XCTAssertEqual(sceneManifest["UIApplicationSupportsMultipleScenes"] as? Bool, true)
    }

    func testCarPlaySceneConfigurationReferencesTemplateApplicationSceneDelegate() {
        let configurations = sceneManifest["UISceneConfigurations"] as? [String: Any]
        let carPlayConfigs = configurations?["CPTemplateApplicationSceneSessionRoleApplication"] as? [[String: Any]]
        XCTAssertEqual(carPlayConfigs?.count, 1, "exactly one CarPlay scene configuration")
        let config = carPlayConfigs?.first
        XCTAssertEqual(config?["UISceneConfigurationName"] as? String, "CarPlayVoice")
        XCTAssertEqual(
            config?["UISceneClassName"] as? String, "CPTemplateApplicationScene",
            "the CarPlay role pins Apple's template-application scene class explicitly"
        )
        let delegateName = config?["UISceneDelegateClassName"] as? String
        XCTAssertTrue(
            delegateName?.hasSuffix(".CarPlayVoiceSceneDelegate") == true,
            "the delegate class name must use the product module namespace"
        )
        let delegateClass = delegateName.flatMap(NSClassFromString)
        XCTAssertTrue(
            delegateClass === CarPlayVoiceSceneDelegate.self,
            "the manifest-declared delegate must resolve to CarPlayVoiceSceneDelegate"
        )
    }

    func testNoApplicationRoleSceneConfigurationIsDeclared() {
        // The phone scene stays on the SwiftUI default configuration: adding
        // one would change foreground scene behavior beyond the CarPlay role.
        let configurations = sceneManifest["UISceneConfigurations"] as? [String: Any]
        XCTAssertNil(configurations?["UIApplicationSceneSessionRoleApplication"])
        XCTAssertNil(configurations?["UISceneSessionRoleApplication"])
    }
}

// MARK: - Controller state → CarPlay state mapping

final class CarPlayVoiceStateMappingTests: XCTestCase {
    func testAllControllerStatesMapAsSpecified() {
        XCTAssertEqual(CarPlayVoiceState.map(.idle), .ready)
        XCTAssertEqual(CarPlayVoiceState.map(.listening), .listening)
        XCTAssertEqual(CarPlayVoiceState.map(.transcribing), .processing)
        XCTAssertEqual(CarPlayVoiceState.map(.thinking), .processing)
        XCTAssertEqual(CarPlayVoiceState.map(.speaking), .responding)
        XCTAssertEqual(CarPlayVoiceState.map(.muted), .responding)
        XCTAssertEqual(CarPlayVoiceState.map(.failed("anything")), .error)
    }

    func testExactlyFiveStatesWithStableIdentifiersAndSafeTitles() {
        XCTAssertEqual(CarPlayVoiceState.allCases.count, 5)
        XCTAssertEqual(
            CarPlayVoiceState.allCases.map(\.identifier),
            ["ready", "listening", "processing", "responding", "error"]
        )
        for state in CarPlayVoiceState.allCases {
            XCTAssertFalse(state.titleVariants.isEmpty)
            for title in state.titleVariants {
                // No transcript content, errors, or verbose strings leak:
                // titles are the fixed, short driver-safe strings.
                XCTAssertLessThan(title.count, 40)
            }
        }
        XCTAssertEqual(CarPlayVoiceState.ready.titleVariants, ["Ready"])
        XCTAssertEqual(CarPlayVoiceState.listening.titleVariants, ["Listening…"])
        XCTAssertEqual(CarPlayVoiceState.processing.titleVariants, ["Thinking…"])
        XCTAssertEqual(CarPlayVoiceState.responding.titleVariants, ["Responding…"])
        XCTAssertEqual(CarPlayVoiceState.error.titleVariants, ["Voice unavailable"])
    }

    func testFailureMessageIsDroppedByTheMapping() {
        // `.failed` carries internals (provider errors, etc.) that must never
        // reach the CarPlay display.
        let mapped = CarPlayVoiceState.map(.failed("provider websocket exploded with secret details"))
        XCTAssertEqual(mapped, .error)
        XCTAssertFalse(
            CarPlayVoiceState.error.titleVariants.contains { $0.contains("provider") },
            "the error state titles must not carry failure internals"
        )
    }
}

// MARK: - Duplicate suppression

final class CarPlayVoiceStateActivationTests: XCTestCase {
    func testDuplicateTransitionsAreSuppressed() {
        XCTAssertNil(CarPlayVoiceStateActivation.activationTarget(lastActivated: .listening, newState: .listening))
        XCTAssertEqual(
            CarPlayVoiceStateActivation.activationTarget(lastActivated: .listening, newState: .processing),
            .processing
        )
        XCTAssertEqual(CarPlayVoiceStateActivation.activationTarget(lastActivated: nil, newState: .ready), .ready)
    }

    func testMutedAndSpeakingCollapseIntoOneRespondingActivation() {
        XCTAssertNil(
            CarPlayVoiceStateActivation.activationTarget(lastActivated: .responding, newState: .responding),
            ".muted ↔ .speaking oscillation must not spam state activation"
        )
    }
}

// MARK: - Template shape

@MainActor
final class CarPlayVoiceTemplateFactoryTests: XCTestCase {
    func testTemplateHasAtMostFiveStatesWithTheExpectedIdentifiers() {
        let template = CarPlayVoiceTemplateFactory.makeTemplate(
            handlers: CarPlayVoiceActionHandlers(startListening: {}, endConversation: {})
        )
        XCTAssertLessThanOrEqual(template.voiceControlStates.count, 5, "the template's documented maximum")
        XCTAssertEqual(
            template.voiceControlStates.map(\.identifier),
            ["ready", "listening", "processing", "responding", "error"]
        )
    }

    func testStateTitlesAreDriverSafe() {
        let template = CarPlayVoiceTemplateFactory.makeTemplate(
            handlers: CarPlayVoiceActionHandlers(startListening: {}, endConversation: {})
        )
        for state in template.voiceControlStates {
            for title in state.titleVariants ?? [] {
                XCTAssertLessThanOrEqual(title.count, 40)
            }
        }
    }

    func testActionButtonsAreMinimalAndStateAppropriate() throws {
        guard #available(iOS 26.4, *) else {
            throw XCTSkip("CarPlay action buttons require iOS 26.4")
        }
        let template = CarPlayVoiceTemplateFactory.makeTemplate(
            handlers: CarPlayVoiceActionHandlers(startListening: {}, endConversation: {})
        )
        let buttonsByID = Dictionary(uniqueKeysWithValues: template.voiceControlStates.map { (
            $0.identifier,
            $0.actionButtons ?? []
        ) })
        XCTAssertEqual(buttonsByID.values.map(\.count).max() ?? 0, 1, "exactly one control per state")
        XCTAssertEqual(buttonsByID["ready"]?.count, 1, "Ready offers Listen")
        XCTAssertEqual(buttonsByID["listening"]?.count, 1, "an active turn offers End")
        XCTAssertEqual(buttonsByID["processing"]?.count, 1)
        XCTAssertEqual(buttonsByID["responding"]?.count, 1)
        XCTAssertEqual(buttonsByID["error"]?.count, 1, "Error offers Listen to retry")
    }
}

// MARK: - Process-wide AppState registry (same-instance invariant)

@MainActor
final class AppStateRuntimeRegistryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AppStateRuntimeRegistry.shared.resetForTesting()
    }

    override func tearDown() {
        AppStateRuntimeRegistry.shared.resetForTesting()
        super.tearDown()
    }

    func testRegistryReturnsOneInstanceAcrossAccesses() {
        let first = AppStateRuntimeRegistry.shared.appState
        let second = AppStateRuntimeRegistry.shared.appState
        XCTAssertTrue(first === second, "the process has exactly one AppState")
    }

    func testCarPlayFirstLaunchOrderBindsTheSameInstanceAsThePhoneSurface() {
        // Simulated ordering: the CarPlay scene connects before any phone
        // scene renders, so the registry creates the instance; the SwiftUI
        // @StateObject autoclosure then adopts the same one.
        let carPlayResolved = AppStateRuntimeRegistry.shared.appState
        let phoneAdopted = AppStateRuntimeRegistry.shared.appState
        XCTAssertTrue(carPlayResolved === phoneAdopted)
    }

    func testCarPlayCoordinatorBindsTheRegistryInstance() {
        let spy = InterfacingSpy()
        let coordinator = CarPlayVoiceCoordinator()
        coordinator.appStateProvider = { AppStateRuntimeRegistry.shared.appState }
        coordinator.autoEstablishOnConnect = false
        coordinator.handleConnect(spy)
        XCTAssertTrue(coordinator.lastBoundAppState === AppStateRuntimeRegistry.shared.appState)
        coordinator.handleDisconnect()
    }
}

// MARK: - Presentation drain helper

@MainActor
extension CarPlayVoiceCoordinator {
    /// The install completion reaches presentation through a MainActor Task
    /// hop; this bounded drain lets tests await that hop deterministically.
    func waitForPresentation(budget: Int = 50) async {
        for _ in 0..<budget where !isTemplatePresented {
            await Task.yield()
        }
    }
}

// MARK: - Interfacing seam

@MainActor
final class InterfacingSpy: CarPlayInterfacing {
    private(set) var setRootTemplateCount = 0
    private(set) var installedTemplates: [CPTemplate] = []
    /// When false, `setRootTemplate` completions are PARKED instead of
    /// invoked; tests flush them via `completeParkedInstall` to control the
    /// presentation timing.
    var completesImmediately = true
    private var parkedCompletions: [((Bool, (any Error)?) -> Void)?] = []

    func setRootTemplate(
        _ rootTemplate: CPTemplate,
        animated: Bool,
        completion: ((Bool, (any Error)?) -> Void)?
    ) {
        setRootTemplateCount += 1
        installedTemplates.append(rootTemplate)
        if completesImmediately {
            completion?(true, nil)
        } else {
            parkedCompletions.append(completion)
        }
    }

    var parkedInstallCount: Int { parkedCompletions.count }

    func completeParkedInstall(success: Bool = true, error: (any Error)? = nil) {
        let completions = parkedCompletions
        parkedCompletions.removeAll()
        completions.forEach { $0?(success, error) }
    }
}

// MARK: - Coordinator + AppState lifecycle

@MainActor
final class CarPlayVoiceCoordinatorTests: XCTestCase {
    @MainActor
    struct Harness {
        let appState: AppState
        let controller: VoiceConversationController
        let capture: FakeCapture
        let gateway: FakeGateway
        let spy: InterfacingSpy
        let coordinator: CarPlayVoiceCoordinator
        let defaults: UserDefaults
        let defaultsSuiteName: String
        let activatorBox: CarPlayVoiceCoordinatorTests.ActivationRecorder

        var activations: [CarPlayVoiceState] { activatorBox.states }

        func openVoice(session: String) {
            appState.activeSessionId = session
            appState.showVoiceSheet = true
            controller.beginVoiceTurn(sessionID: session)
            appState.voiceControllerSessionProfile = appState.activeProfile
        }
    }

    final class ActivationRecorder {
        var states: [CarPlayVoiceState] = []
    }

    private func makeHarness(
        connected: Bool = true,
        continuousConversation: Bool = true
    ) -> Harness {
        let harness = Self.makeSharedHarness(
            connected: connected,
            continuousConversation: continuousConversation
        )
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        return harness
    }

    /// Harness factory shared with other test classes. Cleanup of the
    /// UserDefaults suite is the CALLER's responsibility (the instance
    /// wrapper registers an XCTest teardown).
    static func makeSharedHarness(
        connected: Bool = true,
        continuousConversation: Bool = true
    ) -> Harness {
        let suite = "CarPlayVoiceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        defaults.set("default", forKey: "conduit.activeProfile")
        defaults.set(true, forKey: "conduit.voice.enabled.v1.https://example.com.default")
        if !continuousConversation {
            var preferences = VoiceProfilePreferences()
            preferences.continuousConversation = false
            if let data = try? JSONEncoder().encode(preferences) {
                defaults.set(data, forKey: "conduit.voice.preferences.v1.https://example.com.default")
            }
        }

        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.voiceCapabilityRequesterForTesting = ImmediateVoiceConfigRequester(mode: .fullSupport)
        if connected {
            appState.connection = HermesConnection(baseUrl: "https://example.com", ticket: "test-ticket")
            appState.isConnected = true
        }
        appState.installVoiceCapabilityStateForTesting(
            bridge: DashboardTicketBridge(baseURL: "https://example.com"),
            snapshot: VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: true,
                supportsSpeech: true,
                unavailableReason: nil
            ),
            isVoiceEnabled: true
        )

        let capture = FakeCapture(permissionGranted: true)
        let gateway = FakeGateway(transcript: "Question")
        let controller = VoiceConversationController(
            capture: capture,
            playback: FakePlayback(),
            gateway: gateway,
            routePolicyProvider: { .fullDuplex },
            submit: { _ in true },
            interrupt: { true },
            onEndConversation: { [weak appState] in appState?.closeVoiceConversation() }
        )
        appState.voiceConversationController = controller

        let spy = InterfacingSpy()
        let coordinator = CarPlayVoiceCoordinator()
        let recorder = CarPlayVoiceCoordinatorTests.ActivationRecorder()
        coordinator.appStateProvider = { appState }
        coordinator.autoEstablishOnConnect = false
        coordinator.stateActivator = { _, state in recorder.states.append(state) }

        return Harness(
            appState: appState,
            controller: controller,
            capture: capture,
            gateway: gateway,
            spy: spy,
            coordinator: coordinator,
            defaults: defaults,
            defaultsSuiteName: suite,
            activatorBox: recorder
        )
    }

    // MARK: connect

    func testConnectInstallsRootTemplateImmediatelyAndCompletesPresentation() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        XCTAssertFalse(harness.coordinator.isConnected)

        harness.coordinator.handleConnect(harness.spy)

        XCTAssertEqual(harness.spy.setRootTemplateCount, 1, "the root template installs before the callback returns")
        XCTAssertTrue(harness.spy.installedTemplates.first is CPVoiceControlTemplate)
        XCTAssertTrue(harness.coordinator.isConnected)
        XCTAssertTrue(harness.appState.isCarPlayVoiceSurfaceActive, "CarPlay registers as an active Voice surface")
        await harness.coordinator.waitForPresentation()
        XCTAssertTrue(harness.coordinator.isTemplatePresented, "the completion marks presentation")
        XCTAssertTrue(harness.activations.isEmpty, "the default Ready state is shown by presentation itself")
        XCTAssertEqual(harness.coordinator.lastActivatedState, .ready, "dedupe is primed against the default")
    }

    func testCarPlayFirstLaunchUsesTheRegistryAppStateWithoutAnyPhoneView() {
        AppStateRuntimeRegistry.shared.resetForTesting()
        defer { AppStateRuntimeRegistry.shared.resetForTesting() }

        let spy = InterfacingSpy()
        let coordinator = CarPlayVoiceCoordinator()
        coordinator.appStateProvider = { AppStateRuntimeRegistry.shared.appState }
        coordinator.autoEstablishOnConnect = false

        // The CarPlay scene connects with NO phone RootView having run.
        coordinator.handleConnect(spy)

        let adoptedBySwiftUI = AppStateRuntimeRegistry.shared.appState
        XCTAssertTrue(
            coordinator.lastBoundAppState === adoptedBySwiftUI,
            "the CarPlay-created AppState is the exact instance the phone surface adopts"
        )
    }

    // MARK: shared conversation / no second stack

    func testLiveVoiceConversationAttachesWithoutRestartOrTranscriptLoss() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.openVoice(session: "session-1")
        // Drive a real phone turn to audible playback (user asked, Hermes
        // answers) exactly like the suspension fixture does.
        await harness.controller.startListening()
        let start = Date()
        harness.controller.ingestAudioLevel(0.1, at: start)
        harness.controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(harness.controller.state, .thinking)
        harness.controller.receiveAssistantEvent(.started(sessionID: "session-1"))
        harness.controller.receiveAssistantEvent(.delta(sessionID: "session-1", text: "Answer."))
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(harness.controller.state, .speaking)
        let sheetBefore = harness.appState.showVoiceSheet
        let autoListenBefore = harness.appState.voiceSheetShouldAutoListen
        let transcriptBefore = harness.controller.conversationTranscript

        // CarPlay connects mid-turn: attach only.
        harness.coordinator.handleConnect(harness.spy)
        await harness.coordinator.establishVoice(generation: harness.coordinator.connectionGeneration)
        await harness.coordinator.waitForPresentation()

        XCTAssertTrue(harness.controller.hasLiveVoiceSession, "the live conversation is preserved")
        XCTAssertTrue(harness.controller.isGatewayAttached, "the in-place gateway is retained")
        XCTAssertEqual(
            harness.controller.conversationTranscript, transcriptBefore,
            "transcript survives the attach untouched"
        )
        XCTAssertEqual(harness.appState.showVoiceSheet, sheetBefore, "CarPlay never mutates phone presentation flags")
        XCTAssertEqual(harness.appState.voiceSheetShouldAutoListen, autoListenBefore, "attach never arms a hot mic")
        XCTAssertEqual(harness.controller.state, .speaking, "no restart of the in-flight turn")
        XCTAssertEqual(harness.activations.last, .responding, "the mid-turn state displays without any restart")
    }

    func testCarPlayConnectWithNoLiveVoicePreparesThroughTheSharedPathAndStartsListening() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.appState.activeSessionId = "existing-session"
        harness.coordinator.handleConnect(harness.spy)
        let generation = harness.coordinator.connectionGeneration

        await harness.coordinator.establishVoice(generation: generation)
        await harness.coordinator.waitForPresentation()

        XCTAssertTrue(harness.controller.hasLiveVoiceSession, "the shared prepare path armed the conversation")
        XCTAssertTrue(harness.controller.isGatewayAttached)
        XCTAssertEqual(harness.appState.activeSessionId, "existing-session")
        XCTAssertEqual(harness.controller.state, .listening, "the launcher tap is the listen intent")
        XCTAssertFalse(harness.appState.showVoiceSheet, "CarPlay open does not present the phone sheet")
        XCTAssertEqual(harness.activations.last, .listening)
    }

    func testCarPlayConnectContinuesTheCurrentConversationInsteadOfCreatingANewSession() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.appState.activeSessionId = "existing-session"
        harness.coordinator.handleConnect(harness.spy)

        await harness.coordinator.establishVoice(generation: harness.coordinator.connectionGeneration)

        XCTAssertEqual(
            harness.appState.activeSessionId, "existing-session",
            "an existing session continues; no new session is created for CarPlay"
        )
    }

    // MARK: phone background vs CarPlay

    func testPhoneBackgroundWithCarPlayActiveKeepsVoiceLive() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.openVoice(session: "session-1")
        await harness.controller.startListening()
        harness.appState.setCarPlayVoiceSurfaceActive(true)

        harness.appState.handleScenePhase(.background)

        XCTAssertTrue(harness.appState.hasActiveVoiceSurface)
        XCTAssertFalse(harness.controller.isRuntimeSuspended, "Voice stays live for CarPlay")
        XCTAssertTrue(harness.controller.hasLiveVoiceSession)
        XCTAssertNil(harness.appState.suspendedVoiceConversation, "no restoration descriptor is recorded")
        XCTAssertEqual(harness.controller.state, .listening)
    }

    func testPhoneBackgroundWithoutCarPlayStillSuspends() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.openVoice(session: "session-1")
        await harness.controller.startListening()

        harness.appState.handleScenePhase(.background)

        XCTAssertTrue(harness.controller.isRuntimeSuspended, "the PR #161 path is unchanged without CarPlay")
        XCTAssertEqual(harness.appState.suspendedVoiceConversation?.sessionID, "session-1")
    }

    func testCarPlayDisconnectWithActivePhoneVoiceDoesNotTouchIt() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.openVoice(session: "session-1")
        await harness.controller.startListening()
        // Phone foreground is the default fresh-AppState state; CarPlay
        // connected and then disconnected while the phone presents Voice.
        harness.coordinator.handleConnect(harness.spy)
        XCTAssertTrue(harness.appState.hasActiveVoiceSurface)

        harness.coordinator.handleDisconnect()

        XCTAssertFalse(harness.appState.isCarPlayVoiceSurfaceActive)
        XCTAssertTrue(harness.controller.hasLiveVoiceSession, "the phone Voice surface still presents the conversation")
        XCTAssertFalse(harness.controller.isRuntimeSuspended)
        XCTAssertNil(harness.appState.suspendedVoiceConversation)
        XCTAssertEqual(harness.controller.state, .listening)
    }

    func testCarPlayOnlyDisconnectWithPhoneInactiveSuspendsAndRecordsDescriptor() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.openVoice(session: "session-1")
        await harness.controller.startListening()
        harness.coordinator.handleConnect(harness.spy)
        // The phone goes to the background; CarPlay is the only remaining
        // surface, so the suspension is skipped and Voice stays live.
        harness.appState.handleScenePhase(.background)
        XCTAssertTrue(harness.controller.hasLiveVoiceSession, "CarPlay kept Voice live")
        XCTAssertFalse(harness.controller.isRuntimeSuspended)

        harness.coordinator.handleDisconnect()

        XCTAssertTrue(harness.controller.isRuntimeSuspended, "no Voice surface remains: runtime released")
        XCTAssertTrue(harness.controller.hasLiveVoiceSession, "the logical conversation is preserved for restore")
        XCTAssertEqual(harness.appState.suspendedVoiceConversation?.sessionID, "session-1")
        XCTAssertFalse(harness.appState.consumeVoiceSheetAutoListen())
    }

    func testCarPlayOnlyDisconnectWithClosedPhoneSheetStopsTheRuntime() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        // The conversation lives only on CarPlay: the phone sheet is closed.
        harness.appState.activeSessionId = "session-1"
        harness.controller.beginVoiceTurn(sessionID: "session-1")
        await harness.controller.startListening()
        harness.coordinator.handleConnect(harness.spy)
        harness.appState.handleScenePhase(.background)
        XCTAssertTrue(harness.controller.hasLiveVoiceSession, "CarPlay kept Voice live")
        XCTAssertNil(harness.appState.suspendedVoiceConversation)

        harness.coordinator.handleDisconnect()

        XCTAssertFalse(harness.controller.hasLiveVoiceSession, "a CarPlay-only disconnect is release, not Close")
        XCTAssertNil(harness.appState.suspendedVoiceConversation)
    }

    // MARK: controls

    func testExplicitEndConvergesOnTheAuthoritativeCloseTeardown() {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.openVoice(session: "session-1")
        harness.coordinator.handleConnect(harness.spy)

        harness.coordinator.endConversation()

        XCTAssertNil(harness.appState.suspendedVoiceConversation)
        XCTAssertFalse(harness.appState.voiceSheetShouldAutoListen)
        XCTAssertFalse(harness.controller.hasLiveVoiceSession, "Close tears the session down")
        XCTAssertEqual(harness.controller.state, .idle)
        XCTAssertFalse(harness.appState.showVoiceSheet)
    }

    func testContinuousConversationOffCanReListenThroughCarPlayWithoutChangingThePreference() async {
        let harness = makeHarness(continuousConversation: false)
        harness.appState.activeSessionId = "existing-session"
        harness.coordinator.handleConnect(harness.spy)
        await harness.coordinator.establishVoice(generation: harness.coordinator.connectionGeneration)
        await harness.coordinator.waitForPresentation()
        XCTAssertEqual(harness.controller.state, .listening)
        let preferenceBefore = harness.appState.continuousConversationEnabled
        // Simulate the continuous-OFF end-of-turn settle (the controller's
        // own turn-end logic is covered by its suite): the shared session is
        // logically open and settled, so CarPlay returns to Ready.
        harness.controller.suspendRuntimeForLifecycle()
        XCTAssertEqual(harness.activations.last, .ready, "Ready offers the Listen control again")

        await harness.coordinator.performStartListeningTurn(generation: harness.coordinator.connectionGeneration)

        XCTAssertEqual(harness.controller.state, .listening, "the driver can start another listening turn")
        XCTAssertFalse(harness.controller.isRuntimeSuspended, "the re-listen re-arms the settled runtime")
        XCTAssertEqual(
            harness.appState.continuousConversationEnabled, preferenceBefore,
            "re-listening never overrides the saved Continuous Conversation preference"
        )
    }

    // MARK: unavailability

    func testVoiceUnavailableSettlesIntoErrorStateWithoutMicrophone() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness(connected: false)
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.coordinator.handleConnect(harness.spy)
        let generation = harness.coordinator.connectionGeneration

        await harness.coordinator.establishVoice(generation: generation)
        await harness.coordinator.waitForPresentation()

        XCTAssertEqual(harness.activations.last, .error, "unavailable Hermes settles into the error state")
        XCTAssertFalse(harness.controller.hasLiveVoiceSession, "no Voice conversation was acquired")
        XCTAssertEqual(harness.capture.startCount, 0, "the microphone is never acquired")
        XCTAssertTrue(harness.coordinator.isConnected, "the CarPlay scene stays stable")
    }

    // MARK: stale-generation fencing

    func testStaleDisconnectCannotResurrectVoice() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.coordinator.handleConnect(harness.spy)
        let staleGeneration = harness.coordinator.connectionGeneration

        harness.coordinator.handleDisconnect()
        XCTAssertFalse(harness.controller.hasLiveVoiceSession)
        XCTAssertEqual(harness.spy.setRootTemplateCount, 1, "the dead interface controller is not touched again")

        // The connect-time establishment completes AFTER the disconnect: the
        // rotated generation must make it a silent no-op.
        await harness.coordinator.establishVoice(generation: staleGeneration)

        XCTAssertFalse(harness.controller.hasLiveVoiceSession, "a stale completion cannot reopen Voice")
        XCTAssertNil(harness.appState.suspendedVoiceConversation)
        XCTAssertFalse(harness.coordinator.isConnected)
    }

    func testStaleReconnectCannotMutateTheNewConnection() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        // connect A → disconnect → reconnect B
        harness.coordinator.handleConnect(harness.spy)
        let staleGeneration = harness.coordinator.connectionGeneration
        harness.coordinator.handleDisconnect()
        harness.coordinator.handleConnect(harness.spy)
        XCTAssertGreaterThan(harness.coordinator.connectionGeneration, staleGeneration)

        // Stale async work from connection A completes under B's session.
        await harness.coordinator.performStartListeningTurn(generation: staleGeneration)

        XCTAssertEqual(harness.controller.state, .idle, "stale A work must not drive B's Voice")
        XCTAssertFalse(harness.controller.hasLiveVoiceSession)
        XCTAssertEqual(harness.spy.setRootTemplateCount, 2, "B's template is installed exactly once")
    }

    // MARK: surface reporting

    func testDisconnectCancelsStateObservation() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.coordinator.handleConnect(harness.spy)
        harness.coordinator.handleDisconnect()
        XCTAssertTrue(harness.activations.isEmpty, "nothing is forwarded without a bound interface")

        await harness.controller.startListening()

        XCTAssertTrue(harness.activations.isEmpty, "no CarPlay state is forwarded after disconnect")
    }
}

// MARK: - Review-driven regressions (gate re-assert, stale prepare, attach)

@MainActor
final class CarPlayVoiceLifecycleRegressionTests: XCTestCase {
    /// The reconnect flow every CarPlay driver hits: Voice live on CarPlay,
    /// the phone locks, the car disconnects (runtime released, gate false),
    /// then wireless CarPlay re-associates while the phone is still locked.
    /// The Listen button must reach the microphone — no scene-phase event
    /// fires while locked, so the surface activation itself must re-assert
    /// the controller's gate.
    func testReconnectAfterCarPlayOnlyDisconnectReArmsTheListenPath() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.appState.activeSessionId = "session-1"
        harness.controller.beginVoiceTurn(sessionID: "session-1")
        await harness.controller.startListening()

        harness.coordinator.handleConnect(harness.spy)
        harness.appState.handleScenePhase(.background)
        XCTAssertTrue(harness.controller.hasLiveVoiceSession, "CarPlay keeps Voice live across the phone lock")

        harness.coordinator.handleDisconnect()
        // No sheet presentation survives (the conversation lived on CarPlay),
        // so the release is a full stop; the reconnect re-prepares cleanly.
        XCTAssertFalse(harness.controller.hasLiveVoiceSession, "CarPlay-only disconnect releases the runtime")
        XCTAssertFalse(harness.appState.hasActiveVoiceSurface)

        // Wireless CarPlay re-associates; the phone is still locked.
        harness.coordinator.handleConnect(harness.spy)
        await harness.coordinator.establishVoice(generation: harness.coordinator.connectionGeneration)
        await harness.coordinator.performStartListeningTurn(generation: harness.coordinator.connectionGeneration)
        await harness.coordinator.waitForPresentation()

        XCTAssertEqual(harness.controller.state, .listening, "the re-asserted gate lets Listen reach the microphone")
        XCTAssertFalse(harness.controller.isRuntimeSuspended, "the re-listen re-arms the suspended runtime")
        XCTAssertEqual(harness.activations.last, .listening)
    }

    func testStalePrepareCompletionWithActivePhoneSurfaceKeepsTheConversation() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.appState.activeSessionId = "session-1"
        harness.controller.beginVoiceTurn(sessionID: "session-1")
        await harness.controller.startListening()

        // A prepare captured under a DIFFERENT generation completes while the
        // phone surface is active: the conversation is not torn down — the
        // phone still legitimately presents it.
        await harness.coordinator.completeVoiceEstablishment(
            generation: harness.coordinator.connectionGeneration &+ 1,
            outcome: .handled
        )

        XCTAssertTrue(harness.controller.hasLiveVoiceSession, "the phone surface keeps the conversation")
        XCTAssertEqual(harness.controller.state, .listening)
        XCTAssertNil(harness.appState.suspendedVoiceConversation)
    }

    func testStalePrepareCompletionWithNoActiveSurfaceDoesNotOrphanAnArmedSession() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.openVoice(session: "session-1")
        await harness.controller.startListening()
        harness.appState.handleScenePhase(.background)
        XCTAssertTrue(harness.controller.isRuntimeSuspended)

        // A prepare completing after the surface disappeared must apply the
        // no-surface release contract instead of leaving the session armed.
        await harness.coordinator.completeVoiceEstablishment(
            generation: harness.coordinator.connectionGeneration &+ 1,
            outcome: .handled
        )

        XCTAssertTrue(harness.controller.isRuntimeSuspended, "the session stays released, not resurrected-armed")
        XCTAssertEqual(harness.appState.suspendedVoiceConversation?.sessionID, "session-1", "still restorable")
        XCTAssertEqual(harness.capture.startCount, 1, "no capture was (re)started by the stale completion")
    }

    func testFailedAttachSettlesIntoErrorStateAndKeepsThePhoneRestorePath() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.openVoice(session: "session-1")
        await harness.controller.startListening()
        // The phone backgrounds without CarPlay: the runtime suspends and the
        // restoration descriptor is recorded.
        harness.appState.handleScenePhase(.background)
        XCTAssertNotNil(harness.appState.suspendedVoiceConversation)
        // Capabilities collapse while backgrounded: the attach re-arm must
        // fail, and when it does the descriptor must survive.
        harness.appState.installVoiceCapabilityStateForTesting(
            bridge: DashboardTicketBridge(baseURL: "https://example.com"),
            snapshot: VoiceCapabilitySnapshot(
                isGatewayConnected: true,
                supportsTranscription: false,
                supportsSpeech: false,
                unavailableReason: "no providers"
            ),
            isVoiceEnabled: false
        )
        harness.controller.setGateway(nil)

        harness.coordinator.handleConnect(harness.spy)
        await harness.coordinator.establishVoice(generation: harness.coordinator.connectionGeneration)
        await harness.coordinator.waitForPresentation()

        XCTAssertEqual(harness.activations.last, .error, "a failed attach settles into the error state")
        XCTAssertNotNil(
            harness.appState.suspendedVoiceConversation,
            "a failed attach must not discard the phone-restoration descriptor"
        )
        XCTAssertEqual(harness.capture.startCount, 1, "the microphone is never acquired by the failed attach")
    }
}

// MARK: - Presentation-gated state activation

@MainActor
final class CarPlayVoicePresentationGatingTests: XCTestCase {
    private func makeSpeakingHarness() async -> CarPlayVoiceCoordinatorTests.Harness {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.openVoice(session: "session-1")
        await harness.controller.startListening()
        let start = Date()
        harness.controller.ingestAudioLevel(0.1, at: start)
        harness.controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 250_000_000)
        harness.controller.receiveAssistantEvent(.started(sessionID: "session-1"))
        harness.controller.receiveAssistantEvent(.delta(sessionID: "session-1", text: "Answer."))
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(harness.controller.state, .speaking)
        return harness
    }

    /// Reproduces the frozen-Ready bug: an existing Voice conversation is
    /// mid-response when CarPlay connects. The observer fires before the
    /// root template is presented, so NOTHING may be activated yet; the
    /// retained .responding activates exactly once on presentation success.
    func testConnectWhileSpeakingActivatesOnlyAfterPresentation() async {
        let harness = await makeSpeakingHarness()
        harness.spy.completesImmediately = false

        harness.coordinator.handleConnect(harness.spy)
        await harness.coordinator.establishVoice(generation: harness.coordinator.connectionGeneration)

        XCTAssertFalse(harness.coordinator.isTemplatePresented)
        XCTAssertEqual(harness.activations, [], "pre-presentation activation is a documented no-op")
        XCTAssertEqual(
            harness.coordinator.pendingPresentationState, .responding,
            "the latest desired state is retained, not lost"
        )

        harness.spy.completeParkedInstall()
        await harness.coordinator.waitForPresentation()

        XCTAssertTrue(harness.coordinator.isTemplatePresented)
        XCTAssertEqual(harness.activations, [.responding], "responding activates exactly once on presentation")
        XCTAssertNil(harness.coordinator.pendingPresentationState)

        // Post-presentation dedupe: a mute oscillation maps to responding and
        // must not re-activate.
        harness.controller.setOutputMuted(true)
        XCTAssertEqual(harness.activations, [.responding])
    }

    /// A parked install completion from connection A must never mark
    /// connection B's template presented or activate through it.
    func testStaleTemplateCompletionCannotPresentTheNewConnection() async {
        let harness = await makeSpeakingHarness()
        harness.spy.completesImmediately = false

        // Connect A (install parked), disconnect, connect B (install parked).
        harness.coordinator.handleConnect(harness.spy)
        let spyA = harness.spy
        harness.coordinator.handleDisconnect()
        let spyB = InterfacingSpy()
        spyB.completesImmediately = false
        harness.coordinator.handleConnect(spyB)
        XCTAssertEqual(spyB.parkedInstallCount, 1)
        XCTAssertFalse(harness.coordinator.isTemplatePresented)

        // A's late completion fires: fenced out of B.
        spyA.completeParkedInstall()
        await harness.coordinator.waitForPresentation()

        XCTAssertFalse(
            harness.coordinator.isTemplatePresented,
            "a stale completion cannot present the new connection's template"
        )
        XCTAssertEqual(harness.activations, [], "and cannot activate through it")

        // B's own completion presents normally.
        spyB.completeParkedInstall()
        await harness.coordinator.waitForPresentation()
        XCTAssertTrue(harness.coordinator.isTemplatePresented)
        XCTAssertEqual(harness.activations.last, .responding)
    }

    /// A failed install keeps the template unpresented: the desired state
    /// stays retained (a later successful presentation will activate it) and
    /// nothing is forwarded in the meantime.
    func testPresentationFailureKeepsTemplateUnpresentedAndRetainsDesiredState() {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.spy.completesImmediately = false
        harness.coordinator.handleConnect(harness.spy)
        XCTAssertEqual(harness.coordinator.pendingPresentationState, .ready)

        harness.coordinator.handleControllerState(.listening)
        harness.spy.completeParkedInstall(success: false, error: URLError(.badURL))

        XCTAssertFalse(harness.coordinator.isTemplatePresented)
        XCTAssertEqual(harness.activations, [])
        XCTAssertEqual(
            harness.coordinator.pendingPresentationState, .listening,
            "the desired state is retained across the failed presentation"
        )
    }
}

// MARK: - Single-window claim (multi-scene for CarPlay only)

@MainActor
final class ConduitWindowClaimKeeperTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ConduitWindowClaimKeeper.resetForTesting()
    }

    override func tearDown() {
        ConduitWindowClaimKeeper.resetForTesting()
        super.tearDown()
    }

    func testFirstWindowClaimsAndLaterWindowsAreRejected() {
        XCTAssertTrue(ConduitWindowClaimKeeper.claimPrimaryWindow(), "the first window becomes primary")
        XCTAssertFalse(
            ConduitWindowClaimKeeper.claimPrimaryWindow(),
            "a second foreground Conduit window dismisses itself"
        )
        XCTAssertFalse(ConduitWindowClaimKeeper.claimPrimaryWindow())
    }

    func testClosingThePrimaryWindowReleasesTheClaim() {
        XCTAssertTrue(ConduitWindowClaimKeeper.claimPrimaryWindow())
        ConduitWindowClaimKeeper.releaseClaim()
        XCTAssertTrue(
            ConduitWindowClaimKeeper.claimPrimaryWindow(),
            "the next window to appear may become primary"
        )
    }
}

// MARK: - Phone-open attach to a live (CarPlay-owned) Voice session

@MainActor
final class CarPlayVoicePhoneAttachTests: XCTestCase {
    /// CarPlay owns a live conversation with transcript content; the phone
    /// sheet is NOT presented. Tapping the composer Voice control
    /// (startsFreshConversation == false) must ATTACH: same controller, same
    /// session, transcript untouched, assistant ownership preserved, sheet
    /// presented — no beginVoiceTurn reset and no "stop the current
    /// response" rejection.
    func testPhoneOpenAttachesToCarPlayOwnedLiveSessionWithoutReset() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.appState.activeSessionId = "session-S"
        harness.controller.beginVoiceTurn(sessionID: "session-S")
        await harness.controller.startListening()
        let start = Date()
        harness.controller.ingestAudioLevel(0.1, at: start)
        harness.controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 250_000_000)
        harness.controller.receiveAssistantEvent(.started(sessionID: "session-S"))
        harness.controller.receiveAssistantEvent(.delta(sessionID: "session-S", text: "Answer."))
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(harness.controller.hasLiveVoiceSession)
        XCTAssertFalse(harness.controller.conversationTranscript.isEmpty)
        let transcriptBefore = harness.controller.conversationTranscript

        harness.coordinator.handleConnect(harness.spy)
        await harness.coordinator.establishVoice(generation: harness.coordinator.connectionGeneration)

        let opened = await harness.appState.openVoiceConversation(
            PendingVoiceIntent(profile: nil, startsFreshConversation: false, source: .composer)
        )

        XCTAssertTrue(opened)
        XCTAssertTrue(harness.appState.showVoiceSheet, "the phone sheet presents the attached conversation")
        XCTAssertEqual(harness.appState.activeSessionId, "session-S", "same session, not a new one")
        XCTAssertEqual(
            harness.controller.conversationTranscript, transcriptBefore,
            "the shared transcript survives the phone attach"
        )
        XCTAssertNil(harness.appState.errorMessage, "no spurious rejection on attach")

        // Assistant ownership survived: deltas for the same session still
        // append to the preserved transcript.
        harness.controller.receiveAssistantEvent(.delta(sessionID: "session-S", text: " More."))
        let expectedLastText = (transcriptBefore.last?.text ?? "") + " More."
        XCTAssertEqual(
            harness.controller.conversationTranscript.last?.text,
            expectedLastText,
            "assistant stream ownership is still armed for session-S"
        )
    }

    /// The same continuation while an assistant turn is IN FLIGHT: phone
    /// presentation attaches instead of rejecting with "Stop the current
    /// response" merely because the live session already owns the turn.
    func testPhoneOpenAttachesWhileAssistantTurnIsInFlight() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        // The phone sheet is closed; the live Voice conversation is owned by
        // the CarPlay surface.
        harness.appState.activeSessionId = "session-S"
        harness.controller.beginVoiceTurn(sessionID: "session-S")
        await harness.controller.startListening()
        let start = Date()
        harness.controller.ingestAudioLevel(0.1, at: start)
        harness.controller.ingestAudioLevel(0, at: start.addingTimeInterval(1.3))
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(harness.controller.state, .thinking, "an assistant turn is in flight")
        let transcriptBefore = harness.controller.conversationTranscript

        harness.coordinator.handleConnect(harness.spy)

        let opened = await harness.appState.openVoiceConversation(
            PendingVoiceIntent(profile: nil, startsFreshConversation: false, source: .composer)
        )

        XCTAssertTrue(opened)
        XCTAssertTrue(harness.appState.showVoiceSheet)
        XCTAssertEqual(harness.appState.activeSessionId, "session-S")
        XCTAssertEqual(
            harness.controller.conversationTranscript, transcriptBefore,
            "the in-flight turn's transcript is untouched by the attach"
        )
        XCTAssertNil(
            harness.appState.errorMessage,
            "attaching to the live session must not emit the turn-running rejection"
        )
    }
}

// MARK: - Route policy regression (CarPlay stays conservative)

final class CarPlayVoiceRoutePolicyTests: XCTestCase {
    private func port(_ type: AVAudioSession.Port, name: String) -> VoiceAudioRoutePort {
        VoiceAudioRoutePort(type: type, name: name)
    }

    func testCarPlayAudioOutputIsSpeakerSafeHalfDuplex() {
        let policy = VoiceBargeInRoutePolicy.resolve(
            outputs: [port(.carAudio, name: "Chevy Bolt")],
            inputs: []
        )
        XCTAssertEqual(policy, .speakerSafeHalfDuplex, "the conservative half-duplex policy is preserved for CarPlay")
    }

    func testCarPlayRouteWithCarMicrophoneStaysHalfDuplex() {
        // Even when the car exposes its own microphone input, capture and
        // playback do not form an Apple-managed full-duplex pairing.
        let policy = VoiceBargeInRoutePolicy.resolve(
            outputs: [port(.carAudio, name: "Chevy Bolt")],
            inputs: [port(.carAudio, name: "Chevy Bolt")]
        )
        XCTAssertEqual(policy, .speakerSafeHalfDuplex)
    }

    func testKnownRoutesKeepTheirExistingClassifications() {
        XCTAssertEqual(
            VoiceBargeInRoutePolicy.resolve(outputs: [port(.builtInSpeaker, name: "Speaker")], inputs: []),
            .speakerSafeHalfDuplex,
            "speaker"
        )
        XCTAssertEqual(
            VoiceBargeInRoutePolicy.resolve(outputs: [port(.builtInReceiver, name: "Receiver")], inputs: []),
            .speakerSafeHalfDuplex,
            "receiver"
        )
        XCTAssertEqual(
            VoiceBargeInRoutePolicy.resolve(
                outputs: [port(.bluetoothHFP, name: "AirPods Pro")],
                inputs: [port(.bluetoothHFP, name: "AirPods Pro")]
            ),
            .fullDuplex,
            "paired Bluetooth headset"
        )
        XCTAssertEqual(
            VoiceBargeInRoutePolicy.resolve(outputs: [port(.headphones, name: "Wired")], inputs: []),
            .fullDuplex,
            "wired headset"
        )
    }
}

// MARK: - Fakes (file-local copies of the established voice doubles)

@MainActor
private final class ImmediateVoiceConfigRequester: VoiceConfigurationRequesting {
    enum Mode { case failing, fullSupport }

    private let mode: Mode

    init(mode: Mode = .failing) { self.mode = mode }

    func requestJSON(path: String, method: String, body: [String: Any]?) async throws -> [String: Any] {
        switch mode {
        case .failing:
            throw URLError(.notConnectedToInternet)
        case .fullSupport:
            if path.hasSuffix("/api/config") {
                return ["stt": ["enabled": true], "tts": ["provider": "edge"]]
            }
            if path.hasSuffix("/api/tools/toolsets/tts/config") {
                return ["providers": [[
                    "name": "Microsoft Edge TTS",
                    "tts_provider": "edge",
                    "status": "ready",
                    "is_active": true,
                ]]]
            }
            throw URLError(.notConnectedToInternet)
        }
    }
}

@MainActor
final class FakeCapture: AudioCaptureService {
    let events: AsyncStream<VoiceCaptureEvent>
    var captureGeneration: UInt64 = 0
    private var continuation: AsyncStream<VoiceCaptureEvent>.Continuation?
    private let permissionGranted: Bool
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var resumeCount = 0

    init(permissionGranted: Bool) {
        self.permissionGranted = permissionGranted
        var captured: AsyncStream<VoiceCaptureEvent>.Continuation?
        events = AsyncStream { captured = $0 }
        continuation = captured
    }
    func requestPermission() async -> Bool { permissionGranted }
    func startListening(includePreRoll: Bool) throws {
        startCount += 1
        captureGeneration &+= 1
    }
    func beginBargeInMonitoring() throws {}
    func pause() { captureGeneration &+= 1 }
    func resume() throws {
        resumeCount += 1
        captureGeneration &+= 1
    }
    func finishUtterance() throws -> VoiceCapturedAudio {
        VoiceCapturedAudio(wavData: Data([1]), pcm16Data: Data([1, 0]), sampleRate: 16_000, duration: 0.01)
    }
    func stop() {
        stopCount += 1
        captureGeneration &+= 1
    }
    func emit(level: Float, at date: Date = Date()) {
        continuation?.yield(.level(level, date: date, generation: captureGeneration))
    }
}

@MainActor
private final class FakePlayback: SpeechPlaybackService {
    var isPlaying = false
    var ownershipIntent: VoiceAudioIntent = .standalonePlayback
    func start(sampleRate: Double) throws { isPlaying = true }
    func enqueuePCM16(_ data: Data, sampleRate: Double) throws -> Int { data.count - (data.count % 2) }
    func playEncodedAudioData(_ data: Data) throws { isPlaying = true }
    func finish() throws {}
    func drain() async { isPlaying = false }
    func stop() { isPlaying = false }
}

@MainActor
final class FakeGateway: VoiceGatewayService {
    let profile = "default"
    var transcript: String
    private(set) var transcriptionCount = 0
    init(transcript: String) { self.transcript = transcript }
    func transcribe(_ audio: VoiceCapturedAudio) async throws -> String {
        transcriptionCount += 1
        return transcript
    }
    func openSpeechStream(
        onStart: @escaping @MainActor (Double) throws -> Void,
        onPCM16: @escaping @MainActor (Data, Double) throws -> Void,
        onEncodedAudio: @escaping @MainActor (Data) throws -> Void
    ) async throws -> VoiceSpeechStream {
        try onStart(24_000)
        return FakeSpeechStream()
    }
}

@MainActor
private final class FakeSpeechStream: VoiceSpeechStream {
    func append(_ text: String) async throws {}
    func finish() async throws -> Bool { false }
    func cancel() {}
}
