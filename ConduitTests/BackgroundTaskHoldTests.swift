import UIKit
import XCTest
@testable import Conduit

/// The one-shot background task the calls, the Watch broker, location
/// sharing and voice transcript saves keep Conduit running with (#1247).
@MainActor
final class BackgroundTaskHoldTests: XCTestCase {
    private var begun: [String] = []
    private var ended: [UIBackgroundTaskIdentifier] = []
    private var expire: (@MainActor @Sendable () -> Void)?

    private func begin(_ name: String = "conduit.test", granted: Bool = true) -> () -> Void {
        BackgroundTaskHold.begin(
            name,
            beginTask: { [unowned self] name, expired in
                self.begun.append(name)
                self.expire = expired
                return granted ? UIBackgroundTaskIdentifier(rawValue: 7) : .invalid
            },
            endTask: { [unowned self] id in self.ended.append(id) }
        )
    }

    func testEndEndsTheTaskOnce() {
        let end = begin("conduit.test.once")
        XCTAssertEqual(begun, ["conduit.test.once"])
        end()
        end()
        XCTAssertEqual(ended, [UIBackgroundTaskIdentifier(rawValue: 7)])
    }

    func testExpiryEndsTheTaskAndALaterEndDoesNothing() {
        let end = begin()
        expire?()
        XCTAssertEqual(ended, [UIBackgroundTaskIdentifier(rawValue: 7)])
        end()
        expire?()
        XCTAssertEqual(ended, [UIBackgroundTaskIdentifier(rawValue: 7)])
    }

    func testATaskIOSRefusedIsNeverEnded() {
        let end = begin(granted: false)
        end()
        expire?()
        XCTAssertTrue(ended.isEmpty)
    }
}
