import XCTest
@testable import Conduit

@MainActor
final class WakeLifecycleTests: XCTestCase {
    func testArmsOnlyForForegroundReadyIdleSession() {
        let service = FakeWakeWordService()
        let coordinator = WakeLifecycleCoordinator(service: service)
        let ready = WakeLifecycleSnapshot(
            isForegroundActive: true,
            isAuthenticated: true,
            isGatewayConnected: true,
            microphonePermitted: true,
            isVoiceIdle: true,
            hasWakePhrases: true
        )

        coordinator.update(for: ready)
        XCTAssertTrue(service.isArmed)
        XCTAssertEqual(service.armCount, 1)

        coordinator.update(for: WakeLifecycleSnapshot(
            isForegroundActive: true,
            isAuthenticated: true,
            isGatewayConnected: true,
            microphonePermitted: true,
            isVoiceIdle: false,
            hasWakePhrases: true
        ))
        XCTAssertFalse(service.isArmed)

        coordinator.update(for: WakeLifecycleSnapshot(
            isForegroundActive: false,
            isAuthenticated: true,
            isGatewayConnected: true,
            microphonePermitted: true,
            isVoiceIdle: true,
            hasWakePhrases: true
        ))
        XCTAssertFalse(service.isArmed)
        XCTAssertGreaterThanOrEqual(service.disarmCount, 2)
    }

    func testRecordsServiceFailureWithoutLeavingWakeArmed() {
        let service = FakeWakeWordService(error: WakeWordServiceError.unavailable("No model"))
        let coordinator = WakeLifecycleCoordinator(service: service)
        coordinator.update(for: .init(isForegroundActive: true, isAuthenticated: true, isGatewayConnected: true, microphonePermitted: true, isVoiceIdle: true, hasWakePhrases: true))
        XCTAssertFalse(service.isArmed)
        XCTAssertEqual(coordinator.lastFailureReason, "No model")
    }

    func testDefaultSherpaAdapterStaysUnavailableBehindPackagingGate() {
        let service = SherpaWakeWordService()
        XCTAssertFalse(service.isArmed)
        XCTAssertEqual(
            service.availability,
            .unavailable(WakeModelDescriptor.bundledBilingualPack.licenseReviewNote)
        )
        XCTAssertThrowsError(try service.arm()) { error in
            XCTAssertEqual(
                error as? WakeWordServiceError,
                .unavailable(WakeModelDescriptor.bundledBilingualPack.licenseReviewNote)
            )
        }
    }

    func testBundledPackMetadataPinsReviewedRuntimeAndArchive() {
        let pack = WakeModelDescriptor.bundledBilingualPack
        XCTAssertEqual(pack.sherpaONNXVersion, "1.13.2")
        XCTAssertEqual(pack.packagingStatus, .blockedPendingLicenseReview)
        XCTAssertEqual(pack.archiveSHA256, "68447f4fbc67e70eee3a93961f36e81e98f47aef73ce7e7ca00885c6cd3616a6")
        XCTAssertEqual(
            pack.assets.prefix(3).map(\.relativePath),
            [
                "encoder-epoch-13-avg-2-chunk-8-left-64.int8.onnx",
                "decoder-epoch-13-avg-2-chunk-8-left-64.onnx",
                "joiner-epoch-13-avg-2-chunk-8-left-64.int8.onnx"
            ]
        )
        XCTAssertTrue(pack.assets.allSatisfy { $0.sha256 == nil && $0.checksumStatus == .notRecorded })
    }
}

extension WakeLifecycleTests {
    func testRoutePolicyIdentifiesCarPlay() {
        let car = VoiceAudioRoutePort(type: .carAudio, name: "CarPlay")
        let speaker = VoiceAudioRoutePort(type: .builtInSpeaker, name: "Speaker")
        let a2dp = VoiceAudioRoutePort(type: .bluetoothA2DP, name: "Buds")
        XCTAssertTrue(WakeRoutePolicy.isCarPlay(outputs: [car]))
        XCTAssertFalse(WakeRoutePolicy.isCarPlay(outputs: [speaker]))
        XCTAssertFalse(WakeRoutePolicy.isCarPlay(outputs: [a2dp]))
        XCTAssertFalse(WakeRoutePolicy.isCarPlay(outputs: []), "an empty route fails open")
        XCTAssertTrue(WakeRoutePolicy.isCarPlay(outputs: [speaker, car]), "any CarPlay output counts")

        var snapshot = WakeLifecycleSnapshot(
            isForegroundActive: true,
            isAuthenticated: true,
            isGatewayConnected: true,
            microphonePermitted: true,
            isVoiceIdle: true,
            hasWakePhrases: true
        )
        XCTAssertTrue(snapshot.canArm)
        snapshot.isRouteSuitable = false
        XCTAssertFalse(snapshot.canArm)
    }

    func testOtherAppsAudioPausesWakeOnly() {
        var snapshot = WakeLifecycleSnapshot(
            isForegroundActive: true,
            isAuthenticated: true,
            isGatewayConnected: true,
            microphonePermitted: true,
            isVoiceIdle: true,
            hasWakePhrases: true
        )
        XCTAssertTrue(snapshot.otherAudioAllowsListening, "allowed unless something says otherwise")
        XCTAssertFalse(snapshot.isPausedForOtherAudio)

        snapshot.otherAudioAllowsListening = false
        XCTAssertFalse(snapshot.canArm)
        XCTAssertTrue(snapshot.canArmIgnoringOtherAudio)
        XCTAssertTrue(snapshot.isPausedForOtherAudio)

        snapshot.isVoiceIdle = false
        XCTAssertFalse(snapshot.isPausedForOtherAudio, "a call, not the podcast, keeps wake off")

        let service = FakeWakeWordService()
        let coordinator = WakeLifecycleCoordinator(service: service)
        snapshot.isVoiceIdle = true
        coordinator.update(for: snapshot)
        XCTAssertFalse(service.isArmed, "wake waits for the other app's audio to stop")
        snapshot.otherAudioAllowsListening = true
        coordinator.update(for: snapshot)
        XCTAssertTrue(service.isArmed, "and listens again once it does")
        snapshot.otherAudioAllowsListening = false
        coordinator.update(for: snapshot)
        XCTAssertFalse(service.isArmed, "a podcast starting stops an armed listener")
    }

    func testAppStateOtherAudioFollowsTheSetting() throws {
        let suite = "WakeLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false, clearSessionPresentationCache: {})
        var otherAudioPlaying = true
        appState.wakeOtherAudioProbe = { otherAudioPlaying }
        XCTAssertFalse(appState.wakeListensOverOtherAudio, "off by default")

        appState.noteWakeOtherAudio(playing: true)
        XCTAssertTrue(appState.isWakeOtherAudioPlaying)
        XCTAssertFalse(appState.wakeLifecycleSnapshot.otherAudioAllowsListening)

        let revision = appState.wakeSettingsRevision
        appState.setWakeListensOverOtherAudio(true)
        XCTAssertNotEqual(appState.wakeSettingsRevision, revision, "the change must publish")
        XCTAssertTrue(appState.wakeLifecycleSnapshot.otherAudioAllowsListening, "kept listening over other audio")

        otherAudioPlaying = false
        appState.setWakeListensOverOtherAudio(false)
        XCTAssertFalse(appState.isWakeOtherAudioPlaying, "turning it off re-reads what plays now")
        XCTAssertTrue(appState.wakeLifecycleSnapshot.otherAudioAllowsListening)

        otherAudioPlaying = true
        appState.setWakeListensOverOtherAudio(true)
        appState.setWakeListensOverOtherAudio(false)
        XCTAssertFalse(appState.wakeLifecycleSnapshot.otherAudioAllowsListening, "a playing podcast pauses wake again")
    }

    func testStaysDisarmedWithoutWakePhrases() {
        let service = FakeWakeWordService()
        let coordinator = WakeLifecycleCoordinator(service: service)
        coordinator.update(for: .init(
            isForegroundActive: true,
            isAuthenticated: true,
            isGatewayConnected: true,
            microphonePermitted: true,
            isVoiceIdle: true,
            hasWakePhrases: false
        ))
        XCTAssertFalse(service.isArmed)
        XCTAssertEqual(service.armCount, 0)
    }

    func testDisarmImmediatelyStopsAnArmedListener() {
        let service = FakeWakeWordService()
        let coordinator = WakeLifecycleCoordinator(service: service)
        coordinator.update(for: .init(
            isForegroundActive: true,
            isAuthenticated: true,
            isGatewayConnected: true,
            microphonePermitted: true,
            isVoiceIdle: true,
            hasWakePhrases: true
        ))
        XCTAssertTrue(service.isArmed)
        coordinator.disarmImmediately()
        XCTAssertFalse(service.isArmed)
    }

    func testAppStateWakeBindingsAreScopedToTheActiveDashboard() throws {
        let suite = "WakeLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dashboard = SavedDashboard(id: UUID(), label: "Home", normalizedURL: "https://hermes.example")
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard]),
            clearSessionPresentationCache: {}
        )
        let gatewayID = try XCTUnwrap(appState.wakeGatewayID)
        XCTAssertEqual(gatewayID, dashboard.id.uuidString)
        appState.setWakePreferences(
            WakeProfilePreferences(enabledPhrases: ["Hey Default"], startsFreshConversation: false),
            forProfile: "default"
        )
        appState.wakeConfiguration.save(
            WakeProfilePreferences(enabledPhrases: ["hey elsewhere"]),
            for: WakeProfileKey(gatewayID: "another-dashboard", profileID: "default")
        )
        XCTAssertEqual(appState.activeWakeBindings.map(\.normalizedPhrase), ["hey default"])
        XCTAssertEqual(appState.activeWakeBindings.first?.key.gatewayID, gatewayID)
        XCTAssertEqual(appState.wakePreferences(forProfile: "default").startsFreshConversation, false)

        appState.setWakePreferences(WakeProfilePreferences(enabledPhrases: []), forProfile: "default")
        XCTAssertTrue(appState.activeWakeBindings.isEmpty)
    }

    func testAppStateWakeRouteFollowsTheCarPlaySetting() throws {
        let suite = "WakeLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false, clearSessionPresentationCache: {})
        XCTAssertTrue(appState.wakeListensOnCarPlay, "on by default")

        appState.isWakeRouteCarPlay = false
        XCTAssertTrue(appState.wakeLifecycleSnapshot.isRouteSuitable)
        appState.isWakeRouteCarPlay = true
        XCTAssertTrue(appState.wakeLifecycleSnapshot.isRouteSuitable, "CarPlay listens through the iPhone microphone")

        let revision = appState.wakeSettingsRevision
        appState.setWakeListensOnCarPlay(false)
        XCTAssertNotEqual(appState.wakeSettingsRevision, revision, "the change must publish")
        XCTAssertFalse(appState.isWakeRouteCarPlay, "the change re-reads the live route (no CarPlay in tests)")
        XCTAssertTrue(appState.wakeLifecycleSnapshot.isRouteSuitable, "the setting only affects CarPlay")
        appState.isWakeRouteCarPlay = true
        XCTAssertFalse(appState.wakeLifecycleSnapshot.isRouteSuitable, "turned off, CarPlay stops wake")
    }
}

@MainActor
private final class FakeWakeWordService: WakeWordService {
    var isArmed = false
    var armCount = 0
    var disarmCount = 0
    var error: Error?

    init(error: Error? = nil) { self.error = error }

    func arm() throws {
        armCount += 1
        if let error { throw error }
        isArmed = true
    }

    func disarm() {
        disarmCount += 1
        isArmed = false
    }
}
