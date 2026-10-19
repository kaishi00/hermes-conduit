import Combine
import UIKit
import XCTest
@testable import Conduit

/// The idle countdown that rests the backdrop, on a manual clock: no real
/// timers or sleeps. An extension of AppStateVoiceCapabilityTests (which
/// already covers the backdrop's motion policy) so the test plan gains no
/// class.
extension AppStateVoiceCapabilityTests {
    func testIdleBackdropGoesIdleAtTheDeadlineAndPublishesOnce() {
        let h = IdleHarness()
        let state = h.state
        let flips = h.recordFlips()
        XCTAssertFalse(state.isIdle)

        h.clock.advance(by: 119)
        XCTAssertFalse(state.isIdle)
        h.clock.advance(by: 1)
        XCTAssertTrue(state.isIdle)

        // Nothing more is scheduled while idle, and it stays idle.
        XCTAssertEqual(h.clock.pendingCount, 0)
        h.clock.advance(by: 3_600)
        XCTAssertEqual(flips(), [true])
    }

    func testIdleBackdropTouchPushesTheDeadlineWithoutReschedulingPerTouch() {
        let h = IdleHarness()
        let state = h.state
        h.clock.advance(by: 100)
        let schedulesBefore = h.clock.scheduleCount
        for _ in 0..<50 {
            state.noteInteraction()
            h.clock.advance(by: 0.1)
        }
        // Touches only move the deadline; the one pending timer stays.
        XCTAssertEqual(h.clock.scheduleCount, schedulesBefore)
        XCTAssertEqual(h.clock.pendingCount, 1)

        // The original deadline passes; the timer checks and waits on.
        h.clock.advance(by: 20)
        XCTAssertFalse(state.isIdle)
        XCTAssertEqual(h.clock.pendingCount, 1)

        // 120 s after the last touch (at 104.9 s) it goes idle.
        h.clock.advance(by: 99)
        XCTAssertFalse(state.isIdle)
        h.clock.advance(by: 1)
        XCTAssertTrue(state.isIdle)
    }

    func testIdleBackdropTouchWhileIdleWakesOnceAndRestartsTheCountdown() {
        let h = IdleHarness()
        let state = h.state
        let flips = h.recordFlips()
        h.clock.advance(by: 120)
        XCTAssertTrue(state.isIdle)

        state.noteInteraction()
        state.noteInteraction()
        XCTAssertFalse(state.isIdle)
        XCTAssertEqual(flips(), [true, false], "A burst of touches publishes one wake")

        h.clock.advance(by: 119)
        XCTAssertFalse(state.isIdle)
        h.clock.advance(by: 1)
        XCTAssertTrue(state.isIdle)
        XCTAssertEqual(flips(), [true, false, true])
    }

    func testIdleBackdropRunningTurnHoldsItAwakeAndItsEndRestartsTheCountdown() {
        let h = IdleHarness()
        let state = h.state
        h.clock.advance(by: 60)
        state.setTurnRunning(true)
        // A long turn with no touches never goes idle.
        h.clock.advance(by: 3_600)
        XCTAssertFalse(state.isIdle)

        state.setTurnRunning(false)
        h.clock.advance(by: 119)
        XCTAssertFalse(state.isIdle)
        h.clock.advance(by: 1)
        XCTAssertTrue(state.isIdle)
    }

    func testIdleBackdropVoiceConversationHoldsItAwakeLikeATurn() {
        let h = IdleHarness()
        let state = h.state
        h.clock.advance(by: 120)
        XCTAssertTrue(state.isIdle)

        // A hands-free call: no touches, no turn.
        state.setVoiceConversationShown(true)
        XCTAssertFalse(state.isIdle)
        XCTAssertEqual(h.clock.pendingCount, 0, "No timer runs while held awake")
        h.clock.advance(by: 3_600)
        XCTAssertFalse(state.isIdle)

        // A turn ending mid-call doesn't let it go idle either.
        state.setTurnRunning(true)
        state.setTurnRunning(false)
        h.clock.advance(by: 600)
        XCTAssertFalse(state.isIdle)

        state.setVoiceConversationShown(false)
        h.clock.advance(by: 119)
        XCTAssertFalse(state.isIdle)
        h.clock.advance(by: 1)
        XCTAssertTrue(state.isIdle)
    }

    func testIdleBackdropTurnStartingWakesAnIdleApp() {
        let h = IdleHarness()
        let state = h.state
        h.clock.advance(by: 120)
        XCTAssertTrue(state.isIdle)
        state.setTurnRunning(true)
        XCTAssertFalse(state.isIdle)
        // Repeating the same edge changes nothing.
        state.setTurnRunning(true)
        h.clock.advance(by: 600)
        XCTAssertFalse(state.isIdle)
    }

    func testIdleBackdropSceneActivationAndTypingResetTheIdleClock() {
        let h = IdleHarness()
        let state = h.state
        h.clock.advance(by: 120)
        XCTAssertTrue(state.isIdle)

        h.center.post(name: UIScene.didActivateNotification, object: nil)
        XCTAssertFalse(state.isIdle)
        h.clock.advance(by: 100)
        // A hardware keyboard sends no touches; typing still counts.
        h.center.post(name: UITextView.textDidChangeNotification, object: nil)
        h.clock.advance(by: 100)
        XCTAssertFalse(state.isIdle)
        h.center.post(name: UITextField.textDidChangeNotification, object: nil)
        h.clock.advance(by: 119)
        XCTAssertFalse(state.isIdle)
        h.clock.advance(by: 1)
        XCTAssertTrue(state.isIdle)
    }
}

/// A fake clock and one-shot timer queue standing in for the run loop, and an
/// idle tracker wired to them and to a private notification center.
@MainActor
private final class IdleHarness {
    final class ManualClock {
        var now: TimeInterval = 1_000
        private var scheduled: [(id: Int, fireAt: TimeInterval, fire: @MainActor () -> Void)] = []
        private(set) var scheduleCount = 0
        private var nextID = 0

        var pendingCount: Int { scheduled.count }

        func schedule(_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void {
            nextID += 1
            scheduleCount += 1
            let id = nextID
            scheduled.append((id, now + delay, fire))
            return { [weak self] in self?.scheduled.removeAll { $0.id == id } }
        }

        /// Moves time forward, firing every timer that comes due, in order.
        @MainActor
        func advance(by seconds: TimeInterval) {
            let target = now + seconds
            while let next = scheduled.min(by: { $0.fireAt < $1.fireAt }), next.fireAt <= target {
                scheduled.removeAll { $0.id == next.id }
                now = max(now, next.fireAt)
                next.fire()
            }
            now = target
        }
    }

    let clock: ManualClock
    let center: NotificationCenter
    let state: InteractionIdleState
    private var cancellables: Set<AnyCancellable> = []

    init(idleAfter: TimeInterval = 120) {
        let clock = ManualClock()
        let center = NotificationCenter()
        self.clock = clock
        self.center = center
        state = InteractionIdleState(
            idleAfter: idleAfter,
            now: { clock.now },
            schedule: { clock.schedule($0, $1) },
            notificationCenter: center
        )
    }

    /// Every value `isIdle` publishes after the initial one.
    func recordFlips() -> () -> [Bool] {
        var values: [Bool] = []
        state.$isIdle.dropFirst().sink { values.append($0) }.store(in: &cancellables)
        return { values }
    }
}
