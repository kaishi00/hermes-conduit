import UIKit
import XCTest
@testable import Conduit

/// The short off-screen hold that keeps the chat socket answering Hermes'
/// pings through a quick trip to another app (notifier #296).
@MainActor
final class BackgroundConnectionGraceTests: XCTestCase {
    private var nextID = 1
    private var ended: [UIBackgroundTaskIdentifier] = []
    private var expirations: [() -> Void] = []

    private func makeGrace(
        sleep: @escaping (TimeInterval) async -> Void,
        refuse: Bool = false
    ) -> BackgroundConnectionGrace {
        BackgroundConnectionGrace(
            window: 25,
            beginTask: { [unowned self] expired in
                if refuse { return .invalid }
                self.expirations.append(expired)
                defer { self.nextID += 1 }
                return UIBackgroundTaskIdentifier(rawValue: self.nextID)
            },
            endTask: { [unowned self] id in self.ended.append(id) },
            sleep: sleep
        )
    }

    /// A sleep that never returns on its own: only cancellation ends it.
    private static let neverWakes: (TimeInterval) async -> Void = { _ in
        while !Task.isCancelled { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    func testTheHoldEndsWhenTheWindowRunsOut() async {
        var slept: [TimeInterval] = []
        let grace = makeGrace(sleep: { slept.append($0) })
        let done = expectation(description: "hold ended")
        grace.begin()
        XCTAssertTrue(grace.isHolding)
        Task { @MainActor in
            while grace.isHolding { try? await Task.sleep(nanoseconds: 10_000_000) }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(slept, [25])
        XCTAssertEqual(ended, [UIBackgroundTaskIdentifier(rawValue: 1)])
    }

    func testComingBackEndsTheHoldOnce() async {
        let grace = makeGrace(sleep: Self.neverWakes)
        grace.begin()
        XCTAssertTrue(grace.isHolding)
        grace.end()
        grace.end()
        XCTAssertFalse(grace.isHolding)
        XCTAssertEqual(ended, [UIBackgroundTaskIdentifier(rawValue: 1)])
    }

    func testIOSRunningOutOfTimeEndsTheHold() {
        let grace = makeGrace(sleep: Self.neverWakes)
        grace.begin()
        expirations.first?()
        XCTAssertFalse(grace.isHolding)
        XCTAssertEqual(ended, [UIBackgroundTaskIdentifier(rawValue: 1)])
    }

    func testLeavingAgainStartsANewHold() {
        let grace = makeGrace(sleep: Self.neverWakes)
        grace.begin()
        grace.begin()
        XCTAssertTrue(grace.isHolding)
        XCTAssertEqual(ended, [UIBackgroundTaskIdentifier(rawValue: 1)])
        grace.end()
        XCTAssertEqual(ended, [UIBackgroundTaskIdentifier(rawValue: 1), UIBackgroundTaskIdentifier(rawValue: 2)])
    }

    func testALateExpiryForAnEarlierHoldLeavesTheNewOneRunning() {
        let grace = makeGrace(sleep: Self.neverWakes)
        grace.begin()
        grace.begin()
        expirations.first?()
        XCTAssertTrue(grace.isHolding)
        XCTAssertEqual(ended, [UIBackgroundTaskIdentifier(rawValue: 1)])
    }

    func testTheTaskStillEndsWhenTheGraceGoesAway() async {
        let done = expectation(description: "task ended")
        var grace: BackgroundConnectionGrace? = BackgroundConnectionGrace(
            window: 25,
            beginTask: { _ in UIBackgroundTaskIdentifier(rawValue: 9) },
            endTask: { id in
                XCTAssertEqual(id, UIBackgroundTaskIdentifier(rawValue: 9))
                done.fulfill()
            },
            sleep: { _ in }
        )
        grace?.begin()
        grace = nil
        await fulfillment(of: [done], timeout: 5)
    }

    func testNoHoldWhenIOSGivesNoTime() {
        let grace = makeGrace(sleep: Self.neverWakes, refuse: true)
        grace.begin()
        XCTAssertFalse(grace.isHolding)
        grace.end()
        XCTAssertTrue(ended.isEmpty)
    }
}
