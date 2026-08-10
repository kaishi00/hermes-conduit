import XCTest
@testable import Conduit

@MainActor
final class HapticsTests: XCTestCase {
    func testEnabledUsesDevicePreference() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: Haptics.preferenceKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: Haptics.preferenceKey)
            } else {
                defaults.removeObject(forKey: Haptics.preferenceKey)
            }
        }

        defaults.removeObject(forKey: Haptics.preferenceKey)
        XCTAssertTrue(Haptics.enabled)

        Haptics.enabled = false
        XCTAssertFalse(Haptics.enabled)
        XCTAssertEqual(
            defaults.object(forKey: Haptics.preferenceKey) as? Bool,
            false
        )

        Haptics.enabled = true
        XCTAssertTrue(Haptics.enabled)
        XCTAssertEqual(
            defaults.object(forKey: Haptics.preferenceKey) as? Bool,
            true
        )
    }

    func testDisabledPreferenceSuppressesEveryBaseEmitter() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: Haptics.preferenceKey)
        let previousHandler = Haptics.testEmissionHandler
        let previousSuppressesHardware = Haptics.testSuppressesHardware
        var events: [Haptics.Event] = []
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: Haptics.preferenceKey)
            } else {
                defaults.removeObject(forKey: Haptics.preferenceKey)
            }
            Haptics.testEmissionHandler = previousHandler
            Haptics.testSuppressesHardware = previousSuppressesHardware
        }

        Haptics.testEmissionHandler = { events.append($0) }
        Haptics.testSuppressesHardware = true
        Haptics.enabled = false

        Haptics.soft()
        Haptics.light()
        Haptics.medium()
        Haptics.rigid()
        Haptics.success()
        Haptics.error()
        Haptics.warning()
        Haptics.selection()

        XCTAssertTrue(events.isEmpty)
    }

    func testEnabledPreferenceRecordsEveryBaseEmitterInOrder() {
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: Haptics.preferenceKey)
        let previousHandler = Haptics.testEmissionHandler
        let previousSuppressesHardware = Haptics.testSuppressesHardware
        var events: [Haptics.Event] = []
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: Haptics.preferenceKey)
            } else {
                defaults.removeObject(forKey: Haptics.preferenceKey)
            }
            Haptics.testEmissionHandler = previousHandler
            Haptics.testSuppressesHardware = previousSuppressesHardware
        }

        Haptics.testEmissionHandler = { events.append($0) }
        Haptics.testSuppressesHardware = true
        Haptics.enabled = true

        Haptics.soft()
        Haptics.light()
        Haptics.medium()
        Haptics.rigid()
        Haptics.success()
        Haptics.error()
        Haptics.warning()
        Haptics.selection()

        XCTAssertEqual(events, [.soft, .light, .medium, .rigid, .success, .error, .warning, .selection])
    }
}
