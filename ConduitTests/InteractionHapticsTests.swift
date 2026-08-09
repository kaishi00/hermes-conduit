import XCTest
@testable import Conduit

@MainActor
final class InteractionHapticsTests: XCTestCase {
    func testUnchangedSelectionIsSilent() {
        XCTAssertTrue(capture(enabled: true) {
            Haptics.selectionChanged(false)
        }.isEmpty)
    }

    func testChangedSelectionEmitsSelectionFeedback() {
        XCTAssertEqual(capture(enabled: true) {
            Haptics.selectionChanged(true)
        }, [.selection])
    }

    func testSuccessfulMutationEmitsSuccessFeedback() {
        XCTAssertEqual(capture(enabled: true) {
            Haptics.mutationCompleted(true)
        }, [.success])
    }

    func testFailedMutationEmitsErrorFeedback() {
        XCTAssertEqual(capture(enabled: true) {
            Haptics.mutationCompleted(false)
        }, [.error])
    }

    func testDisabledPreferenceSuppressesEveryInteractionOutcome() {
        XCTAssertTrue(capture(enabled: false) {
            Haptics.selectionChanged(true)
            Haptics.mutationCompleted(true)
            Haptics.mutationCompleted(false)
        }.isEmpty)
    }

    private func capture(enabled: Bool, _ action: () -> Void) -> [Haptics.Event] {
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
        Haptics.enabled = enabled
        action()
        return events
    }
}
