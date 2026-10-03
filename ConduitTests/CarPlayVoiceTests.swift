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

    func testActionButtonsAreStateAppropriateAndAtMostTwo() throws {
        guard #available(iOS 26.4, *) else {
            throw XCTSkip("CarPlay action buttons require iOS 26.4")
        }
        let template = CarPlayVoiceTemplateFactory.makeTemplate(
            handlers: CarPlayVoiceActionHandlers(startListening: {}, endConversation: {})
        )
        let titlesByID = Dictionary(uniqueKeysWithValues: template.voiceControlStates.map { (
            $0.identifier,
            ($0.actionButtons ?? []).map { $0.title ?? "" }
        ) })
        XCTAssertLessThanOrEqual(titlesByID.values.map(\.count).max() ?? 0, 2, "the template shows at most two")
        XCTAssertEqual(titlesByID["ready"], ["Listen", "New Chat"])
        XCTAssertEqual(titlesByID["error"], ["Listen", "New Chat"], "Error offers Listen to retry")
        XCTAssertEqual(titlesByID["listening"], ["Mute", "End"])
        XCTAssertEqual(titlesByID["processing"], ["Mute", "End"])
        XCTAssertEqual(titlesByID["responding"], ["Mute", "End"])
    }

    func testTemplateIsBuiltForItsControlsAndOpensOnTheGivenState() throws {
        guard #available(iOS 26.4, *) else {
            throw XCTSkip("CarPlay action buttons require iOS 26.4")
        }
        let template = CarPlayVoiceTemplateFactory.makeTemplate(
            controls: CarPlayVoiceControls(isClassic: false, isMicrophoneMuted: true),
            presenting: .listening,
            handlers: CarPlayVoiceActionHandlers(startListening: {}, endConversation: {})
        )
        XCTAssertEqual(
            template.voiceControlStates.map(\.identifier),
            ["listening", "ready", "processing", "responding", "error"],
            "the template presents its first state, so a replacement opens where the car was"
        )
        let titlesByID = Dictionary(uniqueKeysWithValues: template.voiceControlStates.map { (
            $0.identifier,
            ($0.actionButtons ?? []).map { $0.title ?? "" }
        ) })
        XCTAssertEqual(titlesByID["ready"], ["Listen"])
        XCTAssertEqual(titlesByID["listening"], ["Unmute", "End"])
    }

    func testButtonsForEachStateAndControls() {
        let classic = CarPlayVoiceControls(isClassic: true, isMicrophoneMuted: false)
        let liveMuted = CarPlayVoiceControls(isClassic: false, isMicrophoneMuted: true)
        XCTAssertEqual(CarPlayVoiceButton.buttons(for: .ready, controls: classic), [.listen, .newChat])
        XCTAssertEqual(CarPlayVoiceButton.buttons(for: .ready, controls: liveMuted), [.listen])
        XCTAssertEqual(CarPlayVoiceButton.buttons(for: .error, controls: liveMuted), [.listen])
        XCTAssertEqual(CarPlayVoiceButton.buttons(for: .listening, controls: classic), [.mute, .end])
        XCTAssertEqual(CarPlayVoiceButton.buttons(for: .responding, controls: liveMuted), [.unmute, .end])
        let classicPaused = CarPlayVoiceControls(isClassic: true, isMicrophoneMuted: true)
        XCTAssertEqual(
            CarPlayVoiceButton.buttons(for: .listening, controls: classicPaused), [.resume, .end],
            "a classic microphone paused by silence offers Listen, not Unmute"
        )
    }

    func testEveryStateHasAnIconWithinTheTemplateLimits() throws {
        for state in CarPlayVoiceState.allCases {
            let image = try XCTUnwrap(CarPlayVoiceArtwork.image(for: state), "\(state) has an icon")
            XCTAssertLessThanOrEqual(image.size.width, 150, "the template's 150 pt limit")
            XCTAssertLessThanOrEqual(image.size.height, 150)
            if CarPlayVoiceArtwork.isAnimated(state) {
                XCTAssertEqual(image.images?.count, CarPlayVoiceArtwork.frameCount, "\(state) animates")
                XCTAssertGreaterThanOrEqual(image.duration, 0.3, "the system's minimum cycle")
                XCTAssertLessThanOrEqual(image.duration, 5, "the system's maximum cycle")
            } else {
                XCTAssertNil(image.images, "\(state) is still")
            }
        }
        let template = CarPlayVoiceTemplateFactory.makeTemplate(
            handlers: CarPlayVoiceActionHandlers(startListening: {}, endConversation: {})
        )
        for voiceControlState in template.voiceControlStates {
            XCTAssertNotNil(voiceControlState.image, "\(voiceControlState.identifier) shows its icon")
        }
    }
}

// MARK: - Browse screens, sounds and settings

// Kept in an existing test class: the hosted lane plan caps batches per lane.
@MainActor
extension CarPlayVoiceTemplateFactoryTests {
    private func session(
        _ id: String,
        title: String? = nil,
        activity: TimeInterval? = nil,
        archived: Bool = false
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            storedSessionId: "stored-\(id)",
            alternateIds: [],
            title: title ?? id,
            model: "Hermes",
            updatedLabel: "now",
            lastActivityAt: activity,
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: archived,
            lineageRootId: nil
        )
    }

    func testRecentChatsAreNewestFirstWithoutArchivedRows() {
        let rows = CarPlayBrowse.recentChats(from: [
            session("old", activity: 10),
            session("undated"),
            session("archived", activity: 99, archived: true),
            session("new", activity: 20),
            session("blank", title: "  ", activity: 5),
        ])
        XCTAssertEqual(rows.map(\.sessionID), ["new", "old", "blank", "undated"])
        XCTAssertEqual(rows.last?.thread.storedSessionID, "stored-undated", "a call attaches by both ids")
        XCTAssertEqual(rows[2].title, "New Chat", "a blank title still reads as a chat")
    }

    func testChatListPutsPinnedChatsFirstWithinTheCap() {
        let sessions = (0..<20).map { session("s\($0)", activity: TimeInterval($0)) }
        let pinnedIDs: Set<String> = ["s2", "s5"]
        let list = CarPlayBrowse.chatList(from: sessions, isPinned: { pinnedIDs.contains($0.id) })
        XCTAssertEqual(list.pinned.map(\.sessionID), ["s5", "s2"], "pinned chats, newest first")
        XCTAssertEqual(list.recent.first?.sessionID, "s19")
        XCTAssertFalse(list.recent.contains { pinnedIDs.contains($0.sessionID) }, "a pinned chat is listed once")
        XCTAssertEqual(list.pinned.count + list.recent.count, CarPlayBrowse.maximumChats)
    }

    func testChatListOpensWithNewVoiceChat() throws {
        var newChats = 0
        var opened: [String] = []
        let list = CarPlayChatList(
            pinned: [CarPlayChatRow(sessionID: "p", storedSessionID: nil, title: "Pinned chat", detail: "")],
            recent: [CarPlayChatRow(sessionID: "r", storedSessionID: nil, title: "Recent chat", detail: "now")]
        )
        let template = CarPlayBrowseTemplateFactory.chatsTemplate(
            chats: list,
            handlers: CarPlayBrowseHandlers(openChat: { opened.append($0.sessionID) }, newVoiceChat: { newChats += 1 })
        )
        XCTAssertEqual(template.sections.map(\.header), [nil, "Pinned", "Recent"])
        let first = try XCTUnwrap(template.sections[0].items.first as? CPListItem)
        XCTAssertEqual(first.text, "New voice chat")
        first.handler?(first, {})
        XCTAssertEqual(newChats, 1)
        let pinned = try XCTUnwrap(template.sections[1].items.first as? CPListItem)
        pinned.handler?(pinned, {})
        XCTAssertEqual(opened, ["p"])
    }

    func testRecentChatsAreCapped() {
        let sessions = (0..<30).map { session("s\($0)", activity: TimeInterval($0)) }
        XCTAssertEqual(CarPlayBrowse.recentChats(from: sessions).count, CarPlayBrowse.maximumChats)
    }

    func testJobRowsSayWhereEachJobIsAndOnlySettledOnesReplay() {
        let running = VoiceBackgroundJob(id: UUID(), title: "Check the server", instructions: "x", status: .running, startedAt: Date(timeIntervalSince1970: 1))
        let done = VoiceBackgroundJob(id: UUID(), title: "Review the PR", instructions: "y", status: .finished, startedAt: Date(timeIntervalSince1970: 2))
        let rows = CarPlayBrowse.jobRows(from: [running, done])
        XCTAssertEqual(rows.map(\.title), ["Review the PR", "Check the server"], "newest first")
        XCTAssertEqual(rows.map(\.status), ["Done", "Running"])
        XCTAssertEqual(rows.map(\.canReplay), [true, false])
    }

    func testAgentsAreOfferedOnlyWhenThereIsAChoice() {
        XCTAssertTrue(CarPlayBrowse.agentRows(profiles: ["default"], active: "default", displayName: { $0 }).isEmpty)
        let rows = CarPlayBrowse.agentRows(profiles: ["default", "work"], active: "work", displayName: { $0.uppercased() })
        XCTAssertEqual(rows, [
            CarPlayOptionRow(title: "DEFAULT", isSelected: false),
            CarPlayOptionRow(title: "WORK", isSelected: true),
        ])
    }

    func testModeRowsMarkTheCurrentMode() {
        let rows = CarPlayBrowse.modeRows(current: .gptLive)
        XCTAssertEqual(rows.count, CarPlayVoiceMode.all.count)
        XCTAssertEqual(rows.filter(\.isSelected).map(\.title), ["GPT-Live"])
    }

    func testEmptyShortcutsShowWhereToAddThem() {
        let template = CarPlayBrowseTemplateFactory.shortcutsTemplate(shortcuts: [], handlers: CarPlayBrowseHandlers())
        XCTAssertTrue(template is CPListTemplate)
        let grid = CarPlayBrowseTemplateFactory.shortcutsTemplate(
            shortcuts: [CarPlayShortcut(title: "Brief", prompt: "Give me my morning brief")],
            handlers: CarPlayBrowseHandlers()
        )
        XCTAssertEqual((grid as? CPGridTemplate)?.gridButtons.count, 1)
    }

    func testEarconsPlayOnlyForSentTurnsAndNewFailures() {
        XCTAssertEqual(CarPlayEarcon.forTransition(from: .listening, to: .processing), .sent)
        XCTAssertEqual(CarPlayEarcon.forTransition(from: .responding, to: .error), .failed)
        XCTAssertNil(CarPlayEarcon.forTransition(from: nil, to: .error), "no sound for the screen opening on Error")
        XCTAssertNil(CarPlayEarcon.forTransition(from: .ready, to: .processing), "connecting is not a sent turn")
        XCTAssertNil(CarPlayEarcon.forTransition(from: .processing, to: .responding))
    }

    func testEarconAudioIsAPlayableWave() throws {
        let data = CarPlayEarconPlayer.wav(for: .sent)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertNoThrow(try AVAudioPlayer(data: data))
    }

    func testShortcutsAreTrimmedCappedAndSaved() throws {
        let suite = "CarPlayShortcutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let preferences = CarPlayPreferences(defaults: defaults)
        XCTAssertTrue(preferences.playsSounds, "sounds are on by default")
        XCTAssertTrue(preferences.choosesChatFirst, "CarPlay opens on the chat list by default")

        XCTAssertFalse(preferences.save(CarPlayShortcut(title: "  ", prompt: "x")), "a blank name is refused")
        XCTAssertTrue(preferences.save(CarPlayShortcut(title: " Brief ", prompt: " Morning brief ")))
        XCTAssertEqual(preferences.shortcuts.first?.title, "Brief")
        for index in 1..<CarPlayPreferences.maximumShortcuts {
            XCTAssertTrue(preferences.save(CarPlayShortcut(title: "S\(index)", prompt: "p")))
        }
        XCTAssertFalse(preferences.save(CarPlayShortcut(title: "Ninth", prompt: "p")), "CarPlay's grid holds eight")
        preferences.setPlaysSounds(false)
        preferences.setChoosesChatFirst(false)

        let reloaded = CarPlayPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.shortcuts.count, CarPlayPreferences.maximumShortcuts)
        XCTAssertFalse(reloaded.playsSounds)
        XCTAssertFalse(reloaded.choosesChatFirst)
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

    private(set) var pushedTemplates: [CPTemplate] = []
    private(set) var popToRootCount = 0

    func pushTemplate(
        _ templateToPush: CPTemplate,
        animated: Bool,
        completion: ((Bool, (any Error)?) -> Void)?
    ) {
        pushedTemplates.append(templateToPush)
        completion?(true, nil)
    }

    func popToRootTemplate(
        animated: Bool,
        completion: ((Bool, (any Error)?) -> Void)?
    ) {
        popToRootCount += 1
        completion?(true, nil)
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
        let capture: MockCapture
        let gateway: MockGateway
        let submits: SubmitSpy
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

        let capture = MockCapture(permissionGranted: true)
        let gateway = MockGateway(transcript: "Question", startsPlaybackOnOpen: true)
        let submits = SubmitSpy()
        let controller = VoiceConversationController(
            capture: capture,
            playback: MockPlayback(),
            gateway: gateway,
            routePolicyProvider: { .fullDuplex },
            submit: { await submits.submit($0) },
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
        // No real connection wait by default: a disconnected harness settles
        // immediately. Tests covering the wait install their own waiter.
        coordinator.connectionWaiter = { $0.isConnected }

        return Harness(
            appState: appState,
            controller: controller,
            capture: capture,
            gateway: gateway,
            submits: submits,
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
        await harness.submits.waitUntilSubmitted(1)
        XCTAssertEqual(harness.controller.state, .thinking)
        harness.controller.receiveAssistantEvent(.started(sessionID: "session-1"))
        harness.controller.receiveAssistantEvent(.delta(sessionID: "session-1", text: "Answer."))
        let speaking = await harness.controller.waitForState(.speaking)
        XCTAssertTrue(speaking, "the assistant reply is audible")
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

    func testAnEndTapAfterADisconnectKeepsThePhoneConversation() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.openVoice(session: "session-1")
        await harness.controller.startListening()
        harness.coordinator.handleConnect(harness.spy)
        harness.coordinator.handleDisconnect()

        harness.coordinator.endConversation()

        XCTAssertTrue(harness.controller.hasLiveVoiceSession, "a stale car tap never closes the phone's conversation")
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

    func testMuteButtonPausesTheClassicMicrophoneAndTheButtonsFollow() async {
        let harness = makeHarness()
        harness.openVoice(session: "session-1")
        await harness.controller.startListening()
        harness.coordinator.handleConnect(harness.spy)
        XCTAssertEqual(harness.coordinator.controls, CarPlayVoiceControls(isClassic: true, isMicrophoneMuted: false))

        harness.coordinator.toggleMicrophone()

        XCTAssertTrue(harness.controller.isMicrophonePaused, "Mute is the same pause the phone's sheet uses")
        XCTAssertTrue(harness.coordinator.controls.isMicrophoneMuted, "the button turns into Unmute")
        XCTAssertTrue(harness.controller.hasLiveVoiceSession, "muting never ends the conversation")
    }

    /// #361: the car keeps the buttons it was given, so Mute installs a new
    /// template built for the muted microphone instead of changing the
    /// buttons of the one on screen.
    func testMuteInstallsANewTemplateOpenOnTheShownState() async throws {
        guard #available(iOS 26.4, *) else {
            throw XCTSkip("CarPlay action buttons require iOS 26.4")
        }
        let harness = makeHarness()
        harness.openVoice(session: "session-1")
        await harness.controller.startListening()
        harness.coordinator.handleConnect(harness.spy)
        await harness.coordinator.waitForPresentation()
        harness.coordinator.handleControllerState(harness.controller.state)
        let shown = try XCTUnwrap(harness.coordinator.lastActivatedState)
        XCTAssertNotEqual(shown, .ready)
        let first = try XCTUnwrap(harness.spy.installedTemplates.last as? CPVoiceControlTemplate)
        let installs = harness.spy.setRootTemplateCount

        harness.coordinator.toggleMicrophone()
        await harness.coordinator.waitForPresentation()

        XCTAssertEqual(harness.spy.setRootTemplateCount, installs + 1, "new controls arrive as a new template")
        let second = try XCTUnwrap(harness.spy.installedTemplates.last as? CPVoiceControlTemplate)
        XCTAssertFalse(first === second)
        XCTAssertEqual(second.voiceControlStates.first?.identifier, shown.identifier, "it opens where the car was")
        let buttons = (second.voiceControlStates.first?.actionButtons ?? []).map { $0.title ?? "" }
        XCTAssertEqual(buttons, ["Listen", "End"], "a paused classic microphone offers Listen")
        let oldButtons = (first.voiceControlStates.first { $0.identifier == shown.identifier }?.actionButtons ?? [])
            .map { $0.title ?? "" }
        XCTAssertEqual(oldButtons, ["Mute", "End"], "the template on the car is never changed in place")
        XCTAssertTrue(harness.coordinator.isTemplatePresented)
    }

    func testAFailedReplacementKeepsTheTemplateOnTheCar() async throws {
        let harness = makeHarness()
        harness.openVoice(session: "session-1")
        await harness.controller.startListening()
        harness.coordinator.handleConnect(harness.spy)
        await harness.coordinator.waitForPresentation()
        harness.coordinator.handleControllerState(harness.controller.state)
        let onCar = try XCTUnwrap(harness.coordinator.template)

        harness.spy.completesImmediately = false
        harness.coordinator.toggleMicrophone()
        XCTAssertFalse(harness.coordinator.template === onCar, "a replacement is on its way")
        harness.spy.completeParkedInstall(success: false, error: URLError(.badURL))
        await harness.coordinator.waitForPresentation()

        XCTAssertTrue(harness.coordinator.template === onCar, "the template still on the car is driven again")
        XCTAssertTrue(harness.coordinator.isTemplatePresented)
        XCTAssertNotNil(harness.coordinator.lastActivatedState)
        XCTAssertFalse(harness.coordinator.didTemplateInstallFail, "the first install did not fail")
    }

    func testCarPlayOpensOnTheChatListWhenNothingIsRunning() async throws {
        let harness = makeHarness()
        let suite = "CarPlayChooseChat.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let preferences = CarPlayPreferences(defaults: defaults)
        harness.coordinator.preferencesProvider = { preferences }
        harness.appState.activeSessionId = "existing-session"
        harness.coordinator.handleConnect(harness.spy)

        await harness.coordinator.establishOnConnect(generation: harness.coordinator.connectionGeneration)
        await harness.coordinator.waitForPresentation()

        let list = try XCTUnwrap(harness.spy.pushedTemplates.last as? CPListTemplate)
        XCTAssertEqual((list.sections.first?.items.first as? CPListItem)?.text, "New voice chat")
        XCTAssertFalse(harness.controller.hasLiveVoiceSession, "Voice waits for the driver's pick")

        // Off: CarPlay starts Voice at once, as before.
        preferences.setChoosesChatFirst(false)
        harness.coordinator.handleDisconnect()
        harness.coordinator.handleConnect(harness.spy)
        let pushed = harness.spy.pushedTemplates.count
        await harness.coordinator.establishOnConnect(generation: harness.coordinator.connectionGeneration)
        await harness.coordinator.waitForPresentation()
        XCTAssertEqual(harness.spy.pushedTemplates.count, pushed, "no list")
        XCTAssertTrue(harness.controller.hasLiveVoiceSession)
    }

    func testAFailedVoiceScreenInstallStartsVoiceInsteadOfTheChatList() async throws {
        for listFirst in [true, false] {
            let harness = makeHarness()
            let suite = "CarPlayChooseChat.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
            let preferences = CarPlayPreferences(defaults: defaults)
            harness.coordinator.preferencesProvider = { preferences }
            harness.appState.activeSessionId = "existing-session"
            harness.spy.completesImmediately = false
            harness.coordinator.handleConnect(harness.spy)
            let generation = harness.coordinator.connectionGeneration

            // Either order: the list asked for before or after the failure.
            if listFirst {
                await harness.coordinator.establishOnConnect(generation: generation)
                XCTAssertTrue(harness.coordinator.isChatPickerPending)
            }
            harness.spy.completeParkedInstall(success: false, error: URLError(.badURL))
            for _ in 0..<50 where !harness.coordinator.didTemplateInstallFail { await Task.yield() }
            if !listFirst {
                await harness.coordinator.establishOnConnect(generation: generation)
            }
            for _ in 0..<200 where !harness.controller.hasLiveVoiceSession { await Task.yield() }

            XCTAssertFalse(harness.coordinator.isChatPickerPending, "listFirst=\(listFirst)")
            XCTAssertTrue(harness.spy.pushedTemplates.isEmpty, "listFirst=\(listFirst)")
            XCTAssertTrue(harness.controller.hasLiveVoiceSession, "Voice starts as before, listFirst=\(listFirst)")
        }
    }

    func testCarPlayShowsARunningConversationInsteadOfTheChatList() async throws {
        let harness = makeHarness()
        let suite = "CarPlayChooseChat.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let preferences = CarPlayPreferences(defaults: defaults)
        harness.coordinator.preferencesProvider = { preferences }
        harness.openVoice(session: "session-1")
        await harness.controller.startListening()
        harness.coordinator.handleConnect(harness.spy)

        await harness.coordinator.establishOnConnect(generation: harness.coordinator.connectionGeneration)
        await harness.coordinator.waitForPresentation()

        XCTAssertTrue(harness.spy.pushedTemplates.isEmpty, "the conversation on the phone is shown")
        XCTAssertTrue(harness.controller.hasLiveVoiceSession)
    }

    func testListenAtReadyReopensAPausedClassicMicrophone() async {
        let harness = makeHarness(continuousConversation: false)
        harness.appState.activeSessionId = "existing-session"
        harness.coordinator.handleConnect(harness.spy)
        await harness.coordinator.establishVoice(generation: harness.coordinator.connectionGeneration)
        harness.controller.pauseMicrophone()
        harness.controller.suspendRuntimeForLifecycle()
        XCTAssertTrue(harness.controller.isMicrophonePaused, "the pause outlives the settle to Ready")

        await harness.coordinator.performStartListeningTurn(generation: harness.coordinator.connectionGeneration)

        XCTAssertFalse(harness.controller.isMicrophonePaused, "Listen reopens the microphone instead of a silent window")
    }

    func testListenShowsErrorWhenThePausedMicrophoneCannotReopen() async {
        let harness = makeHarness(continuousConversation: false)
        harness.appState.activeSessionId = "existing-session"
        harness.coordinator.handleConnect(harness.spy)
        await harness.coordinator.establishVoice(generation: harness.coordinator.connectionGeneration)
        await harness.coordinator.waitForPresentation()
        harness.controller.pauseMicrophone()
        harness.capture.resumeError = URLError(.unknown)

        await harness.coordinator.performStartListeningTurn(generation: harness.coordinator.connectionGeneration)
        // The mute changes install new voice templates (#361), so Error
        // reaches the car once the latest one is up.
        for _ in 0..<200 where harness.activations.last != .error { await Task.yield() }

        XCTAssertTrue(harness.controller.isMicrophonePaused, "the microphone never reopened")
        XCTAssertEqual(harness.activations.last, .error, "never Listening with a closed microphone")
    }

    func testAChatThatFailsToOpenShowsError() async {
        let harness = makeHarness()
        harness.coordinator.handleConnect(harness.spy)
        await harness.coordinator.waitForPresentation()
        let row = CarPlayChatRow(sessionID: "missing", storedSessionID: nil, title: "Chat", detail: "")

        // The harness has no client, so the open fails.
        await harness.coordinator.performOpenChat(row, generation: harness.coordinator.connectionGeneration)

        XCTAssertEqual(harness.activations.last, .error)
    }

    func testButtonsFromAnEarlierConnectionDoNothing() async {
        let harness = makeHarness()
        harness.openVoice(session: "session-1")
        await harness.controller.startListening()
        harness.coordinator.handleConnect(harness.spy)
        let staleButtons = harness.coordinator.makeHandlers()
        let staleRows = harness.coordinator.makeBrowseHandlers()
        harness.coordinator.handleDisconnect()
        harness.coordinator.handleConnect(harness.spy)

        staleButtons.endConversation()
        staleButtons.startNewChat()
        staleButtons.toggleMicrophone()
        staleButtons.startListening()
        staleRows.selectMode(.gptLive)
        staleRows.openChat(CarPlayChatRow(sessionID: "other", storedSessionID: nil, title: "Other", detail: ""))
        await Task.yield()

        XCTAssertFalse(harness.appState.isGPTLiveEnabled, "a stale row never changes the mode")
        XCTAssertTrue(harness.spy.pushedTemplates.isEmpty)
        XCTAssertEqual(harness.spy.popToRootCount, 0, "a stale row never navigates")

        XCTAssertTrue(harness.controller.hasLiveVoiceSession, "a tap from the old template never ends the new connection's conversation")
        XCTAssertFalse(harness.controller.isMicrophonePaused, "nor mutes it")
        XCTAssertEqual(harness.controller.state, .listening)
    }

    func testNewChatClosesTheCurrentConversationAndPreparesAFreshOne() async {
        let harness = makeHarness()
        harness.openVoice(session: "session-1")
        harness.coordinator.handleConnect(harness.spy)
        await harness.coordinator.waitForPresentation()

        await harness.coordinator.performStartNewChat(generation: harness.coordinator.connectionGeneration)

        // The harness cannot create sessions, so the fresh prepare fails;
        // Listen would have re-attached session-1 instead.
        XCTAssertFalse(harness.controller.hasLiveVoiceSession, "the current chat's conversation is not continued")
        XCTAssertEqual(harness.activations.last, .error)
    }

    func testBrowseButtonsShowOnlyOutsideAConversation() async {
        let harness = makeHarness()
        harness.coordinator.handleConnect(harness.spy)
        await harness.coordinator.waitForPresentation()
        XCTAssertTrue(harness.coordinator.showsBrowseButtons, "Ready offers Chats, Jobs, Shortcuts and Voice")

        harness.coordinator.handleControllerState(.listening)
        XCTAssertFalse(harness.coordinator.showsBrowseButtons, "the voice screen stays put while Voice runs")

        harness.coordinator.handleControllerState(.idle)
        XCTAssertTrue(harness.coordinator.showsBrowseButtons)
    }

    func testBrowseScreensOpenOneLevelDown() async throws {
        let harness = makeHarness()
        let suite = "CarPlayBrowse.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let preferences = CarPlayPreferences(defaults: defaults)
        harness.coordinator.preferencesProvider = { preferences }
        harness.coordinator.handleConnect(harness.spy)

        harness.coordinator.showChats()
        harness.coordinator.showJobs()
        harness.coordinator.showShortcuts()
        harness.coordinator.showVoiceOptions()

        XCTAssertEqual(harness.spy.pushedTemplates.count, 4)
        XCTAssertTrue(harness.spy.pushedTemplates.allSatisfy { $0 is CPListTemplate }, "no shortcuts yet shows the empty list")
    }

    func testLeavingTheJobsListStopsKeepingItCurrent() async throws {
        let harness = makeHarness()
        harness.coordinator.handleConnect(harness.spy)

        harness.coordinator.showJobs()
        XCTAssertTrue(harness.coordinator.isObservingJobs)
        let jobs = try XCTUnwrap(harness.spy.pushedTemplates.last)

        harness.coordinator.handleTemplateDidDisappear(try XCTUnwrap(harness.coordinator.template))
        XCTAssertTrue(harness.coordinator.isObservingJobs, "another screen leaving changes nothing")
        harness.coordinator.handleTemplateDidDisappear(jobs)
        XCTAssertFalse(harness.coordinator.isObservingJobs, "the car's back button ends the observation")
    }

    func testAShortcutStartsItsPromptAsAVoiceJob() async {
        let harness = makeHarness()
        let fake = FakeVoiceJobBackend()
        let supervisor = VoiceBackgroundJobSupervisor(backend: fake.backend, pollInterval: .seconds(3_600))
        harness.appState.voiceBackgroundJobSupervisor = supervisor
        harness.coordinator.handleConnect(harness.spy)
        await harness.coordinator.waitForPresentation()

        await harness.coordinator.performRunShortcut(
            CarPlayShortcut(title: "Brief", prompt: "give me my morning brief"),
            generation: harness.coordinator.connectionGeneration
        )

        XCTAssertEqual(supervisor.jobs.count, 1)
        XCTAssertTrue(fake.submissions.first?.1.hasSuffix("give me my morning brief") == true)
    }

    func testARefusedShortcutShowsErrorWithoutOpeningAConversation() async {
        let harness = makeHarness()
        let fake = FakeVoiceJobBackend()
        let supervisor = VoiceBackgroundJobSupervisor(backend: fake.backend, pollInterval: .seconds(3_600))
        harness.appState.voiceBackgroundJobSupervisor = supervisor
        for index in 0..<VoiceBackgroundJobSupervisor.maximumActiveJobs {
            _ = await supervisor.startJob(instructions: "job \(index)")
        }
        harness.coordinator.handleConnect(harness.spy)
        await harness.coordinator.waitForPresentation()

        await harness.coordinator.performRunShortcut(
            CarPlayShortcut(title: "Brief", prompt: "give me my morning brief"),
            generation: harness.coordinator.connectionGeneration
        )

        XCTAssertEqual(supervisor.jobs.count, VoiceBackgroundJobSupervisor.maximumActiveJobs, "no job was added")
        XCTAssertEqual(harness.activations.last, .error)
        XCTAssertFalse(harness.controller.hasLiveVoiceSession, "no conversation opens for a refused job")
    }

    func testABrowseTapAfterADisconnectDoesNothing() async {
        let harness = makeHarness()
        harness.coordinator.handleConnect(harness.spy)
        harness.coordinator.handleDisconnect()

        harness.coordinator.showChats()
        harness.coordinator.showJobs()
        harness.coordinator.selectVoiceMode(.gptLive)
        harness.coordinator.selectAgent(at: 0)

        XCTAssertTrue(harness.spy.pushedTemplates.isEmpty)
        XCTAssertFalse(harness.coordinator.isObservingJobs)
        XCTAssertFalse(harness.appState.isGPTLiveEnabled, "a stale list never changes the saved mode")
    }

    func testPickingAVoiceModeFromTheCarSwitchesTheProfileMode() async {
        let harness = makeHarness()
        harness.coordinator.handleConnect(harness.spy)
        XCTAssertEqual(harness.coordinator.observedVoiceMode, .classic)

        harness.coordinator.selectVoiceMode(.gptLive)

        XCTAssertTrue(harness.appState.isGPTLiveEnabled)
        XCTAssertEqual(harness.coordinator.observedVoiceMode, .gptLive, "the car follows the new mode")
        XCTAssertEqual(harness.spy.popToRootCount, 1, "back to the voice screen")

        harness.coordinator.selectVoiceMode(.classic)
        XCTAssertFalse(harness.appState.isGPTLiveEnabled)
        XCTAssertEqual(harness.coordinator.observedVoiceMode, .classic)
    }

    func testSentTurnPlaysTheStatusSoundUnlessTurnedOff() async throws {
        let harness = makeHarness()
        let suite = "CarPlaySounds.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let preferences = CarPlayPreferences(defaults: defaults)
        var played: [CarPlayEarcon] = []
        harness.coordinator.preferencesProvider = { preferences }
        harness.coordinator.earconPlayer = { played.append($0) }
        harness.coordinator.handleConnect(harness.spy)
        await harness.coordinator.waitForPresentation()

        harness.coordinator.handleControllerState(.listening)
        harness.coordinator.handleControllerState(.thinking)
        XCTAssertEqual(played, [.sent])

        preferences.setPlaysSounds(false)
        harness.coordinator.handleControllerState(.listening)
        harness.coordinator.handleControllerState(.thinking)
        XCTAssertEqual(played, [.sent], "the setting turns the sounds off")
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

    // MARK: connection still being restored (phone locked in the car)

    func testDeferredPrepareWaitsForTheConnectionAndThenListens() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.appState.activeSessionId = "existing-session"
        // A saved-connection restore is still in flight when CarPlay connects.
        harness.appState.isConnected = false
        harness.appState.isConnecting = true
        var waits = 0
        harness.coordinator.connectionWaiter = { appState in
            waits += 1
            appState.isConnecting = false
            appState.isConnected = true
            return true
        }
        harness.coordinator.handleConnect(harness.spy)

        await harness.coordinator.establishVoice(generation: harness.coordinator.connectionGeneration)
        await harness.coordinator.waitForPresentation()

        XCTAssertEqual(waits, 1, "the deferred prepare waited for the connection once")
        XCTAssertTrue(harness.controller.hasLiveVoiceSession, "the retried prepare armed the conversation")
        XCTAssertEqual(harness.controller.state, .listening)
        XCTAssertNotEqual(harness.activations.last, .error, "a connection seconds away is not Voice unavailable")
    }

    func testDeferredListenTapWaitsForTheConnectionAndThenListens() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.appState.activeSessionId = "existing-session"
        harness.appState.isConnected = false
        harness.appState.isConnecting = true
        harness.coordinator.connectionWaiter = { appState in
            appState.isConnecting = false
            appState.isConnected = true
            return true
        }
        harness.coordinator.handleConnect(harness.spy)

        await harness.coordinator.performStartListeningTurn(generation: harness.coordinator.connectionGeneration)

        XCTAssertTrue(harness.controller.hasLiveVoiceSession)
        XCTAssertEqual(harness.controller.state, .listening)
    }

    func testConnectionThatNeverArrivesStillSettlesIntoErrorState() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.appState.isConnected = false
        harness.appState.isConnecting = true
        harness.coordinator.connectionWaiter = { _ in false }
        harness.coordinator.handleConnect(harness.spy)

        await harness.coordinator.establishVoice(generation: harness.coordinator.connectionGeneration)
        await harness.coordinator.waitForPresentation()

        XCTAssertEqual(harness.activations.last, .error)
        XCTAssertFalse(harness.controller.hasLiveVoiceSession)
        XCTAssertEqual(harness.capture.startCount, 0, "the microphone is never acquired")
    }

    func testConnectionArrivingAfterDisconnectDoesNotReopenVoice() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.appState.isConnected = false
        harness.appState.isConnecting = true
        let coordinator = harness.coordinator
        coordinator.connectionWaiter = { [weak coordinator] appState in
            // The car disconnects while the connection is still restoring.
            coordinator?.handleDisconnect()
            appState.isConnecting = false
            appState.isConnected = true
            return true
        }
        coordinator.handleConnect(harness.spy)

        await coordinator.establishVoice(generation: coordinator.connectionGeneration)

        XCTAssertFalse(harness.controller.hasLiveVoiceSession, "a stale wait cannot reopen Voice")
        XCTAssertEqual(harness.capture.startCount, 0)
    }

    func testDisconnectCancelsAnInFlightConnectionWait() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.appState.isConnected = false
        harness.appState.isConnecting = true
        let coordinator = harness.coordinator
        // The real waiter with a long timeout: only cancellation ends it.
        coordinator.connectionWaiter = nil
        coordinator.connectionWaitTimeout = .seconds(60)
        coordinator.handleConnect(harness.spy)
        let generation = coordinator.connectionGeneration

        let establish = Task { @MainActor in
            await coordinator.establishVoice(generation: generation)
        }
        for _ in 0..<20 { await Task.yield() }
        coordinator.handleDisconnect()
        let start = ContinuousClock.now
        await establish.value

        XCTAssertLessThan(ContinuousClock.now - start, .seconds(10), "the stale wait resolved at once")
        XCTAssertFalse(harness.controller.hasLiveVoiceSession)
    }

    func testWaitingForTheConnectionShowsProcessingInsteadOfReady() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.appState.activeSessionId = "existing-session"
        harness.appState.isConnected = false
        harness.appState.isConnecting = true
        var activationsDuringWait: [CarPlayVoiceState] = []
        harness.coordinator.connectionWaiter = { appState in
            activationsDuringWait = harness.activations
            appState.isConnecting = false
            appState.isConnected = true
            return true
        }
        harness.coordinator.handleConnect(harness.spy)
        await harness.coordinator.waitForPresentation()

        await harness.coordinator.establishVoice(generation: harness.coordinator.connectionGeneration)

        XCTAssertEqual(activationsDuringWait.last, .processing)
        XCTAssertEqual(harness.activations.last, .listening)
    }

    func testAwaitConnectionResolvesWhenTheConnectionLands() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        let appState = harness.appState
        appState.isConnected = false
        Task { @MainActor in
            await Task.yield()
            appState.isConnected = true
        }

        let connected = await CarPlayVoiceCoordinator.awaitConnection(of: appState, timeout: .seconds(5))

        XCTAssertTrue(connected)
    }

    func testAwaitConnectionTimesOut() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.appState.isConnected = false

        let connected = await CarPlayVoiceCoordinator.awaitConnection(
            of: harness.appState,
            timeout: .milliseconds(20)
        )

        XCTAssertFalse(connected)
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

    func testStalePrepareCompletionWithPhoneSheetPresentingKeepsTheConversation() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.openVoice(session: "session-1")
        await harness.controller.startListening()

        // A prepare captured under a DIFFERENT generation completes while the
        // phone sheet still presents Voice: the conversation is not torn
        // down — the phone legitimately presents it.
        await harness.coordinator.completeVoiceEstablishment(
            generation: harness.coordinator.connectionGeneration &+ 1,
            outcome: .handled
        )

        XCTAssertTrue(harness.controller.hasLiveVoiceSession, "the presenting sheet keeps the conversation")
        XCTAssertEqual(harness.controller.state, .listening)
        XCTAssertNil(harness.appState.suspendedVoiceConversation)
        XCTAssertEqual(harness.capture.startCount, 1, "and capture keeps running")
    }

    func testStalePrepareCompletionWithNoPresentingSurfaceReleasesTheConversation() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        // The Voice sheet is closed and no CarPlay surface exists: a stale
        // armed session presents nothing, so the fence releases it.
        harness.appState.activeSessionId = "session-1"
        harness.controller.beginVoiceTurn(sessionID: "session-1")
        await harness.controller.startListening()

        await harness.coordinator.completeVoiceEstablishment(
            generation: harness.coordinator.connectionGeneration &+ 1,
            outcome: .handled
        )

        XCTAssertFalse(
            harness.controller.hasLiveVoiceSession,
            "the stale armed session must not survive with no presenting surface"
        )
        XCTAssertEqual(harness.controller.state, .idle)
        XCTAssertGreaterThanOrEqual(harness.capture.stopCount, 1, "capture is released")
        XCTAssertNil(harness.appState.suspendedVoiceConversation)
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
        await harness.submits.waitUntilSubmitted(1)
        harness.controller.receiveAssistantEvent(.started(sessionID: "session-1"))
        harness.controller.receiveAssistantEvent(.delta(sessionID: "session-1", text: "Answer."))
        let speaking = await harness.controller.waitForState(.speaking)
        XCTAssertTrue(speaking, "the assistant reply is audible")
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

// MARK: - Duplicate-window dismissal source contract

final class CarPlayDuplicateWindowDismissalTests: XCTestCase {
    /// Static source contract (UIKit/iPad runtime behavior stays on the
    /// physical checklist): the duplicate-window path must dismiss the
    /// CURRENT instance via the environment-scoped `dismissWindow()`, and
    /// must never use ID-scoped `dismissWindow(id:)`, which targets the
    /// whole WindowGroup — including the primary window.
    func testDuplicateWindowUsesEnvironmentScopedDismissal() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()   // ConduitTests
            .deletingLastPathComponent()   // repo root
        let rootViewSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Conduit/Views/RootView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            rootViewSource.contains("dismissWindow()"),
            "the duplicate window must dismiss only itself"
        )
        XCTAssertFalse(
            rootViewSource.contains("dismissWindow(id:"),
            "ID-scoped dismissal would close the entire WindowGroup, primary included"
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
        await harness.submits.waitUntilSubmitted(1)
        harness.controller.receiveAssistantEvent(.started(sessionID: "session-S"))
        harness.controller.receiveAssistantEvent(.delta(sessionID: "session-S", text: "Answer."))
        let speaking = await harness.controller.waitForState(.speaking)
        XCTAssertTrue(speaking, "the assistant reply is audible")
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
        await harness.submits.waitUntilSubmitted(1)
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

// MARK: - Prepare outcome semantics + surface-gate matrix

@MainActor
final class CarPlayVoicePrepareOutcomeTests: XCTestCase {
    private func makeHarness(
        voiceEnabled: Bool = true,
        activeSessionID: String? = nil
    ) -> CarPlayVoiceCoordinatorTests.Harness {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.appState.activeSessionId = activeSessionID
        if !voiceEnabled {
            harness.defaults.set(false, forKey: "conduit.voice.enabled.v1.https://example.com.default")
        }
        return harness
    }

    /// Voice capability unavailable: prepare is REJECTED (.failed), the
    /// open contract stays router-friendly (returns true = consumed), the
    /// error is surfaced, and NOTHING Voice-shaped is presented or armed.
    func testCapabilityUnavailableFailsPreparationWithoutPresentingVoice() async {
        let harness = makeHarness(voiceEnabled: false)

        let outcome = await harness.appState.prepareVoiceConversation(
            profile: nil,
            startsFreshConversation: false
        )

        guard case .failed(let message) = outcome else {
            return XCTFail("capability-unavailable preparation must fail, got \(outcome)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(harness.appState.errorMessage, message)
        XCTAssertFalse(harness.controller.hasLiveVoiceSession)
        XCTAssertEqual(harness.capture.startCount, 0)

        // The phone open contract: consumed (router-friendly) but Voice is
        // never presented and auto-listen is never armed.
        let opened = await harness.appState.openVoiceConversation(
            PendingVoiceIntent(profile: nil, startsFreshConversation: false, source: .composer)
        )
        XCTAssertTrue(opened, "the request is consumed with the error surfaced")
        XCTAssertEqual(harness.appState.errorMessage, message)
        XCTAssertFalse(harness.appState.showVoiceSheet, "a rejected preparation must not present Voice")
        XCTAssertFalse(harness.appState.consumeVoiceSheetAutoListen())
        XCTAssertEqual(harness.capture.startCount, 0, "the microphone is never acquired")
    }

    /// A non-fresh request with NO session (session creation is a no-op
    /// without a client here) must fail instead of presenting a dead sheet.
    func testMissingSessionFailsPreparation() async {
        let harness = makeHarness()
        XCTAssertNil(harness.appState.activeSessionId)

        let outcome = await harness.appState.prepareVoiceConversation(
            profile: nil,
            startsFreshConversation: false
        )

        guard case .failed(let message) = outcome else {
            return XCTFail("missing-session preparation must fail, got \(outcome)")
        }
        XCTAssertEqual(message, "Hermes could not prepare a voice conversation.")
        XCTAssertEqual(harness.appState.errorMessage, message)
        XCTAssertFalse(harness.controller.hasLiveVoiceSession)
        XCTAssertEqual(harness.capture.startCount, 0)
    }

    /// Fresh-session creation failure is likewise a .failed rejection.
    func testFreshSessionCreationFailureFailsPreparation() async {
        let harness = makeHarness()
        XCTAssertNil(harness.appState.activeSessionId)

        let outcome = await harness.appState.prepareVoiceConversation(
            profile: nil,
            startsFreshConversation: true
        )

        guard case .failed(let message) = outcome else {
            return XCTFail("failed fresh creation must be a .failed rejection, got \(outcome)")
        }
        XCTAssertEqual(message, "Hermes could not create the requested voice conversation.")
        XCTAssertFalse(harness.controller.hasLiveVoiceSession)
        XCTAssertEqual(harness.capture.startCount, 0)
    }
}

@MainActor
final class CarPlayVoiceSurfaceGateTests: XCTestCase {
    /// The original privacy case: CarPlay-only Voice listening while the
    /// phone is foreground with its Voice sheet closed. When CarPlay
    /// disconnects, a foreground phone scene must NOT count as an active
    /// Voice surface — capture must be released with no Voice controls
    /// anywhere.
    func testCarPlayDisconnectWithForegroundPhoneButClosedSheetReleasesVoice() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        // Phone foreground (fresh AppState default), Voice sheet closed,
        // CarPlay listening.
        harness.appState.activeSessionId = "session-1"
        harness.controller.beginVoiceTurn(sessionID: "session-1")
        await harness.controller.startListening()
        harness.coordinator.handleConnect(harness.spy)
        XCTAssertTrue(harness.controller.hasLiveVoiceSession)
        let startsBefore = harness.capture.startCount

        harness.coordinator.handleDisconnect()

        XCTAssertFalse(
            harness.controller.hasLiveVoiceSession,
            "no Voice surface remains: the runtime must be released"
        )
        XCTAssertGreaterThanOrEqual(
            harness.capture.stopCount, 1,
            "capture is stopped on the CarPlay-only disconnect"
        )
        XCTAssertEqual(harness.capture.startCount, startsBefore, "capture is never restarted")
        XCTAssertNil(harness.appState.suspendedVoiceConversation)
    }

    /// Ordinary phone Voice must still open and listen after the predicate
    /// change: the gate is false while the sheet is closed, presenting the
    /// sheet re-asserts it, and the sheet's auto-listen reaches the
    /// microphone.
    func testPhoneVoiceOpenReArmsTheGateAndListens() async {
        let harness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = harness.defaults, suite = harness.defaultsSuiteName] in
            defaults.removePersistentDomain(forName: suite)
        }
        harness.appState.activeSessionId = "session-1"
        // Background/foreground cycle with the sheet closed: under the new
        // predicate the gate ends false (no Voice surface is presenting).
        harness.appState.handleScenePhase(.background)
        harness.appState.handleScenePhase(.active)

        await harness.controller.startListening()
        XCTAssertEqual(
            harness.controller.state, .idle,
            "listening is gated while no Voice surface presents"
        )

        // The user taps Voice: prepare arms the conversation, the sheet
        // presents, the gate is re-asserted, and listen reaches capture.
        let opened = await harness.appState.openVoiceConversation(
            PendingVoiceIntent(profile: nil, startsFreshConversation: false, source: .composer)
        )
        XCTAssertTrue(opened)
        XCTAssertTrue(harness.appState.showVoiceSheet)

        await harness.controller.startListening()
        XCTAssertEqual(harness.controller.state, .listening, "the re-asserted gate lets the sheet's listen work")
        XCTAssertEqual(harness.capture.startCount, 1)
    }

    /// Sheet matrix for the CarPlay disconnect boundary, phone foreground:
    /// sheet open → the phone Voice surface survives the disconnect; sheet
    /// closed → the runtime is released.
    func testPhoneForegroundDisconnectMatrix() async {
        // Sheet OPEN: the phone still presents Voice.
        let openHarness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = openHarness.defaults, suite = openHarness.defaultsSuiteName] in
            openHarness.defaults.removePersistentDomain(forName: openHarness.defaultsSuiteName)
        }
        openHarness.openVoice(session: "session-1")
        await openHarness.controller.startListening()
        openHarness.coordinator.handleConnect(openHarness.spy)
        openHarness.coordinator.handleDisconnect()
        XCTAssertTrue(openHarness.controller.hasLiveVoiceSession, "the phone sheet keeps Voice alive")
        XCTAssertFalse(openHarness.controller.isRuntimeSuspended)
        XCTAssertEqual(openHarness.controller.state, .listening)

        // Sheet CLOSED: nothing presents Voice after the disconnect.
        let closedHarness = CarPlayVoiceCoordinatorTests.makeSharedHarness()
        addTeardownBlock { [defaults = closedHarness.defaults, suite = closedHarness.defaultsSuiteName] in
            closedHarness.defaults.removePersistentDomain(forName: closedHarness.defaultsSuiteName)
        }
        closedHarness.appState.activeSessionId = "session-1"
        closedHarness.controller.beginVoiceTurn(sessionID: "session-1")
        await closedHarness.controller.startListening()
        closedHarness.coordinator.handleConnect(closedHarness.spy)
        closedHarness.coordinator.handleDisconnect()
        XCTAssertFalse(closedHarness.controller.hasLiveVoiceSession, "nothing presents Voice: runtime released")
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

// MARK: - Voice doubles

// The voice doubles (MockCapture/MockPlayback/MockGateway, SubmitSpy,
// ImmediateVoiceConfigRequester) live in VoiceTestSupport.swift, shared with
// the other Voice/CarPlay/AppState suites. The speech-path signals
// (`waitUntilSpeechStreamOpened`, `waitUntilSubmitted`, `waitForState`)
// replace the fixed settling sleeps this file previously relied on.
