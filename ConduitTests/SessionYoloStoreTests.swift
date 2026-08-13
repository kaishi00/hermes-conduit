import XCTest
@testable import Conduit

@MainActor
final class SessionYoloStoreTests: XCTestCase {
    func testMissingOverrideIsDistinctFromExplicitFalse() {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")

        XCTAssertNil(store.storedOverride(for: "default", sessionID: "session-a"))

        store.setOverride(false, for: "default", sessionID: "session-a")

        XCTAssertEqual(store.storedOverride(for: "default", sessionID: "session-a"), false)
        XCTAssertNil(store.storedOverride(for: "default", sessionID: "session-b"))
    }

    func testTrueAndFalseOverridesRoundTripThroughDefaults() {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "test.session-yolo"
        let store = SessionYoloStore(defaults: defaults, storageKey: key)

        store.setOverride(true, for: "Default", sessionID: "session-a")
        store.setOverride(false, for: "default", sessionID: "session-b")

        let recreated = SessionYoloStore(defaults: defaults, storageKey: key)
        XCTAssertEqual(recreated.storedOverride(for: " default ", sessionID: "session-a"), true)
        XCTAssertEqual(recreated.storedOverride(for: "DEFAULT", sessionID: "session-b"), false)
    }

    func testOverridesAreIsolatedByProfileAndSession() {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")

        store.setOverride(true, for: "work", sessionID: "same-session")
        store.setOverride(false, for: "personal", sessionID: "same-session")
        store.setOverride(false, for: "work", sessionID: "other-session")

        XCTAssertEqual(store.storedOverride(for: "work", sessionID: "same-session"), true)
        XCTAssertEqual(store.storedOverride(for: "personal", sessionID: "same-session"), false)
        XCTAssertEqual(store.storedOverride(for: "work", sessionID: "other-session"), false)
        XCTAssertNil(store.storedOverride(for: "personal", sessionID: "other-session"))
    }

    func testInvalidKeysDoNotPersistAnOverride() {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionYoloStore(defaults: defaults, storageKey: "test.session-yolo")

        store.setOverride(true, for: "   ", sessionID: "session-a")
        store.setOverride(true, for: "default", sessionID: "   ")

        XCTAssertNil(store.storedOverride(for: "default", sessionID: "session-a"))
        XCTAssertNil(store.storedOverride(for: "default", sessionID: ""))
    }

    func testCorruptPersistedPayloadReportsDiagnostic() {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "test.session-yolo"
        defaults.set(Data("not-json".utf8), forKey: key)
        var diagnostics: [SessionYoloStoreDiagnostic] = []

        let store = SessionYoloStore(
            defaults: defaults,
            storageKey: key,
            diagnosticHandler: { diagnostics.append($0) }
        )

        XCTAssertNil(store.storedOverride(for: "default", sessionID: "session-a"))
        XCTAssertEqual(diagnostics, [.decodeFailure])
    }

    func testUnsupportedPersistedPayloadVersionReportsDiagnostic() throws {
        let (suite, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "test.session-yolo"
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 99,
            "overrides": [:]
        ])
        defaults.set(data, forKey: key)
        var diagnostics: [SessionYoloStoreDiagnostic] = []

        let store = SessionYoloStore(
            defaults: defaults,
            storageKey: key,
            diagnosticHandler: { diagnostics.append($0) }
        )

        XCTAssertNil(store.storedOverride(for: "default", sessionID: "session-a"))
        XCTAssertEqual(diagnostics, [.unsupportedVersion(99)])
    }

    private func makeDefaults() -> (String, UserDefaults) {
        let suite = "SessionYoloStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Could not create isolated UserDefaults suite")
        }
        return (suite, defaults)
    }
}
