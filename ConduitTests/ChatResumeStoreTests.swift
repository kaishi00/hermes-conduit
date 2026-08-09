import XCTest
@testable import Conduit

final class ChatResumeStoreTests: XCTestCase {
    private func defaults() -> (UserDefaults, String) {
        let suite = "ChatResumeStoreTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    func testUnsavedBehaviorDefaultsToContinueWhereLeftOff() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ChatResumeStore(defaults: defaults).behavior, .continueWhereLeftOff)
    }

    func testPreferenceSessionAndAnchorSurviveStoreRecreation() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        let snapshot = ChatScrollSnapshot(
            anchorMessageID: "anchor-12",
            followsLatest: false,
            anchorMetadata: .init(fingerprint: "fingerprint", duplicateCount: 1),
            anchorSourceMessageID: "source-12"
        )
        let store = ChatResumeStore(defaults: defaults)

        store.setBehavior(.latestActivity)
        store.setLastSessionID("stored-a", for: "default")
        store.save(snapshot, for: key, at: Date(timeIntervalSince1970: 100))
        store.flush()

        let restored = ChatResumeStore(defaults: defaults)
        XCTAssertEqual(restored.behavior, .latestActivity)
        XCTAssertEqual(restored.lastSessionID(for: "default"), "stored-a")
        XCTAssertEqual(restored.snapshot(for: key), snapshot)
    }

    func testCorruptPayloadFallsBackWithoutThrowing() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not-json".utf8), forKey: ChatResumeStore.defaultStorageKey)

        let store = ChatResumeStore(defaults: defaults)

        XCTAssertEqual(store.behavior, .continueWhereLeftOff)
        XCTAssertNil(store.lastSessionID(for: "default"))
    }

    func testLegacySessionMapImportsOnlyOnce() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["default": "stored-a"], forKey: "legacy")
        _ = ChatResumeStore(defaults: defaults, legacyActiveSessionsKey: "legacy")
        defaults.set(["default": "stored-b"], forKey: "legacy")

        XCTAssertEqual(
            ChatResumeStore(defaults: defaults, legacyActiveSessionsKey: "legacy").lastSessionID(for: "default"),
            "stored-a"
        )
    }

    func testUnknownVersionResetsToDefault() throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 999,
            "behavior": "latestActivity",
            "lastSessionIDsByProfile": ["default": "stored-a"],
            "snapshots": []
        ])
        defaults.set(data, forKey: ChatResumeStore.defaultStorageKey)

        XCTAssertEqual(ChatResumeStore(defaults: defaults).behavior, .continueWhereLeftOff)
    }

    func testPruningKeepsNewestHundredSnapshots() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatResumeStore(defaults: defaults)
        for index in 0...100 {
            store.save(
                .init(anchorMessageID: "anchor-\(index)", followsLatest: false),
                for: .init(profile: "default", sessionID: "session-\(index)"),
                at: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        XCTAssertNil(store.snapshot(for: .init(profile: "default", sessionID: "session-0")))
        XCTAssertNotNil(store.snapshot(for: .init(profile: "default", sessionID: "session-100")))
    }

    func testClearResumeStatePreservesBehavior() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatResumeStore(defaults: defaults)
        store.setBehavior(.latestActivity)
        store.setLastSessionID("stored-a", for: "default")
        store.save(.latest, for: .init(profile: "default", sessionID: "stored-a"), at: Date())
        store.clearResumeState()

        XCTAssertEqual(store.behavior, .latestActivity)
        XCTAssertNil(store.lastSessionID(for: "default"))
        XCTAssertNil(store.snapshot(for: .init(profile: "default", sessionID: "stored-a")))
    }

    func testSnapshotMigratesFromRuntimeToCanonicalKey() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatResumeStore(defaults: defaults)
        let runtime = ChatScrollSessionKey(profile: "default", sessionID: "runtime-a")
        let canonical = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        let snapshot = ChatScrollSnapshot(
            anchorMessageID: "anchor-12",
            followsLatest: false,
            anchorMetadata: .init(fingerprint: "fingerprint", duplicateCount: 2),
            anchorSourceMessageID: "source-12"
        )
        store.save(snapshot, for: runtime, at: Date())

        store.migrateSnapshot(from: runtime, to: canonical)

        XCTAssertEqual(store.snapshot(for: canonical), snapshot)
    }
}
