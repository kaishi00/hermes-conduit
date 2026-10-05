import XCTest
@testable import Conduit

final class WakeConfigurationStoreTests: XCTestCase {
    func testListensOnCarPlayDefaultsOnAndPersists() {
        let suite = "WakeConfigurationStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WakeConfigurationStore(defaults: defaults, storageKey: "wake")
        XCTAssertTrue(store.listensOnCarPlay)

        store.listensOnCarPlay = false
        XCTAssertFalse(WakeConfigurationStore(defaults: defaults, storageKey: "wake").listensOnCarPlay)
    }

    func testListensOverOtherAudioDefaultsOffAndPersists() throws {
        let suite = "WakeConfigurationStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WakeConfigurationStore(defaults: defaults, storageKey: "wake")
        XCTAssertFalse(store.listensOverOtherAudio, "other apps' audio pauses wake by default")

        store.listensOverOtherAudio = true
        XCTAssertTrue(WakeConfigurationStore(defaults: defaults, storageKey: "wake").listensOverOtherAudio)
        XCTAssertTrue(store.listensOnCarPlay, "the CarPlay setting is separate")
    }

    func testStoresPreferencesPerGatewayAndProfileAndDeduplicatesPhrases() {
        let suite = "WakeConfigurationStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WakeConfigurationStore(defaults: defaults, storageKey: "wake")
        let defaultKey = WakeProfileKey(gatewayID: "gateway-a", profileID: "default")
        let workKey = WakeProfileKey(gatewayID: "gateway-b", profileID: "work")

        store.save(.init(enabledPhrases: ["Hey Conduit", " hey   conduit ", "Hermes"], startsFreshConversation: true), for: defaultKey)
        store.save(.init(enabledPhrases: ["Talk Hermes"], startsFreshConversation: false), for: workKey)

        XCTAssertEqual(store.preferences(for: defaultKey).enabledPhrases, ["hey conduit", "hermes"])
        XCTAssertTrue(store.preferences(for: defaultKey).startsFreshConversation)
        XCTAssertFalse(store.preferences(for: workKey).startsFreshConversation)
        XCTAssertEqual(Set(store.enabledBindings().map(\.key)), Set([defaultKey, workKey]))

        let restored = WakeConfigurationStore(defaults: defaults, storageKey: "wake")
        XCTAssertEqual(restored.preferences(for: defaultKey).enabledPhrases, ["hey conduit", "hermes"])
    }
}
