import XCTest
@testable import Conduit

private typealias State = HermesTurnAttributes.ContentState
private let start = Date(timeIntervalSince1970: 1_800_000_000)

/// A turn's Live Activity is updated at most every 2 seconds, with its
/// newest state, and at once when it starts or stops waiting on the user
/// (LiveActivityUpdateThrottle). An extension of an existing class, so the
/// CI planner's lanes stay within their batch budget.
extension WidgetLaunchLinkTests {
    func testLiveActivityUpdatesComeAtMostEveryTwoSecondsWithTheNewestState() {
        var throttle = LiveActivityUpdateThrottle()
        throttle.started("a", showing: State(phase: .thinking), at: start)

        // Within the interval: held, due when it is up.
        let writing = State(phase: .writing)
        XCTAssertEqual(throttle.offer(writing, for: "a", at: start.addingTimeInterval(0.5)), .at(start.addingTimeInterval(2)))
        let tool = State(phase: .tool, tool: .web, tools: 1)
        XCTAssertEqual(throttle.offer(tool, for: "a", at: start.addingTimeInterval(1)), .at(start.addingTimeInterval(2)))
        let thinking = State(phase: .thinking, tools: 1)
        XCTAssertEqual(throttle.offer(thinking, for: "a", at: start.addingTimeInterval(1.5)), .at(start.addingTimeInterval(2)))

        // Only the newest goes out, once.
        XCTAssertEqual(throttle.due(for: "a", at: start.addingTimeInterval(2)), thinking)
        XCTAssertNil(throttle.due(for: "a", at: start.addingTimeInterval(2)))

        // The next interval counts from that send.
        XCTAssertEqual(throttle.offer(writing, for: "a", at: start.addingTimeInterval(3)), .at(start.addingTimeInterval(4)))
        // A state once the interval is up goes at once, and drops what was held.
        XCTAssertEqual(throttle.offer(tool, for: "a", at: start.addingTimeInterval(4.2)), .now)
        XCTAssertNil(throttle.due(for: "a", at: start.addingTimeInterval(4.2)))
    }

    func testLiveActivityWaitingOnTheUserAndEndingAreNeverHeld() {
        var throttle = LiveActivityUpdateThrottle()
        throttle.started("a", showing: State(phase: .thinking), at: start)
        XCTAssertEqual(throttle.offer(State(phase: .writing), for: "a", at: start.addingTimeInterval(0.2)), .at(start.addingTimeInterval(2)))

        // An approval goes out at once, and replaces what was held.
        XCTAssertEqual(throttle.offer(State(phase: .approval), for: "a", at: start.addingTimeInterval(0.4)), .now)
        XCTAssertNil(throttle.due(for: "a", at: start.addingTimeInterval(2)))
        // So does the user's answer being taken (no longer waiting).
        XCTAssertEqual(throttle.offer(State(phase: .thinking), for: "a", at: start.addingTimeInterval(0.6)), .now)
        // A question after a tool too.
        XCTAssertEqual(throttle.offer(State(phase: .tool, tool: .terminal, tools: 1), for: "a", at: start.addingTimeInterval(0.8)), .at(start.addingTimeInterval(2.6)))
        XCTAssertEqual(throttle.offer(State(phase: .input, tools: 1), for: "a", at: start.addingTimeInterval(1)), .now)
        // Between two waits nothing is urgent.
        XCTAssertEqual(throttle.offer(State(phase: .approval, tools: 1), for: "a", at: start.addingTimeInterval(1.2)), .at(start.addingTimeInterval(3)))
        // An end is never held.
        XCTAssertEqual(throttle.offer(LiveTurnProgress.finished(State(phase: .writing), .done, now: start), for: "a", at: start.addingTimeInterval(1.4)), .now)
    }

    func testLiveActivityAHeldStateLongOverdueIsDropped() {
        var throttle = LiveActivityUpdateThrottle()
        throttle.started("a", showing: State(phase: .thinking), at: start)
        XCTAssertEqual(throttle.offer(State(phase: .writing), for: "a", at: start.addingTimeInterval(1)), .at(start.addingTimeInterval(2)))
        XCTAssertTrue(throttle.holds("a"))
        // Conduit was suspended: the wait ends long after its time.
        XCTAssertNil(throttle.due(for: "a", at: start.addingTimeInterval(2 + LiveActivityUpdateThrottle.overdueAfter + 1)))
        XCTAssertFalse(throttle.holds("a"))

        // A little late still goes, as does one sent early (Conduit leaving the screen).
        throttle.started("b", showing: State(phase: .thinking), at: start)
        _ = throttle.offer(State(phase: .writing), for: "b", at: start.addingTimeInterval(1))
        XCTAssertEqual(throttle.due(for: "b", at: start.addingTimeInterval(1.2)), State(phase: .writing))
        _ = throttle.offer(State(phase: .tool, tools: 1), for: "b", at: start.addingTimeInterval(1.5))
        XCTAssertEqual(throttle.due(for: "b", at: start.addingTimeInterval(3.2 + LiveActivityUpdateThrottle.overdueAfter)), State(phase: .tool, tools: 1))
    }

    func testLiveActivitiesAreThrottledEachOnTheirOwn() {
        var throttle = LiveActivityUpdateThrottle()
        throttle.started("a", showing: State(phase: .thinking), at: start)
        throttle.started("b", showing: State(phase: .thinking), at: start.addingTimeInterval(1))
        XCTAssertEqual(throttle.offer(State(phase: .writing), for: "a", at: start.addingTimeInterval(2.5)), .now)
        XCTAssertEqual(throttle.offer(State(phase: .writing), for: "b", at: start.addingTimeInterval(2.5)), .at(start.addingTimeInterval(3)))
        // One not started through it (unknown) goes at once.
        XCTAssertEqual(throttle.offer(State(phase: .writing), for: "c", at: start), .now)
        // A forgotten one sends nothing it held.
        throttle.forget("b")
        XCTAssertNil(throttle.due(for: "b", at: start.addingTimeInterval(3)))
    }

    /// A 30-second turn whose state changes every 300 ms (tools starting
    /// and finishing, thinking, writing) updates its activity 15 times
    /// at most rather than 100.
    func testLiveActivityAStreamingTurnUpdatesAboutEveryTwoSeconds() {
        var throttle = LiveActivityUpdateThrottle()
        throttle.started("a", showing: State(phase: .thinking), at: start)
        let phases: [HermesTurnPhase] = [.tool, .thinking, .writing]
        var sends = 0
        var dueAt: Date?
        var last: State?
        for step in 1...100 {
            let at = start.addingTimeInterval(Double(step) * 0.3)
            if let due = dueAt, due <= at, let state = throttle.due(for: "a", at: due) {
                sends += 1
                last = state
                dueAt = nil
            }
            let state = State(phase: phases[step % 3], tools: step / 3)
            switch throttle.offer(state, for: "a", at: at) {
            case .now:
                sends += 1
                last = state
                dueAt = nil
            case .at(let due):
                if dueAt == nil { dueAt = due }
            }
        }
        if let due = dueAt, let state = throttle.due(for: "a", at: due) {
            sends += 1
            last = state
        }
        XCTAssertLessThanOrEqual(sends, 16)
        XCTAssertGreaterThanOrEqual(sends, 14)
        // The trailing send carries the newest state.
        XCTAssertEqual(last, State(phase: phases[100 % 3], tools: 100 / 3))
    }
}
