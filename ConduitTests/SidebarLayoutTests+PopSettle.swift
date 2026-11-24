//
//  SidebarLayoutTests+PopSettle.swift
//  Conduit
//
//  Bots Home's reads as it shows again wait out a pop's slide
//  (`V2ShownUpdates.settled`): asked during it, they run together once
//  it's over; shown with nothing sliding, at once.
//

import XCTest
@testable import Conduit

extension SidebarLayoutTests {
    @MainActor
    private func popSettleUpdates() -> V2ShownUpdates {
        V2ShownUpdates(AppState(defaults: makeScratchDefaults("PopSettle"), loadSavedConnection: false))
    }

    @MainActor
    func testReadsAskedDuringAPopRunTogetherOnceItHasSlid() async throws {
        let updates = popSettleUpdates()
        updates.isShown = false
        var ran: [String] = []
        let roster = Task { @MainActor in await updates.settled(); ran.append("roster") }
        let work = Task { @MainActor in await updates.settled(); ran.append("work") }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(ran, [], "covered, nothing runs")
        // The pop shows it: the reads wait out the slide.
        updates.revealDelay = 0.15
        updates.isShown = true
        XCTAssertFalse(updates.hasSettled)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(ran, [], "the slide is still on")
        // A read asked during the slide joins them.
        let rooms = Task { @MainActor in await updates.settled(); ran.append("rooms") }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(ran, [], "a read asked during the slide waits too")
        _ = await (roster.value, work.value, rooms.value)
        XCTAssertEqual(Set(ran), ["roster", "work", "rooms"])
        XCTAssertTrue(updates.hasSettled)
        // Settled, a read runs at once.
        await updates.settled()
    }

    @MainActor
    func testShownWithNothingSlidingReadsAtOnce() async throws {
        let updates = popSettleUpdates()
        updates.isShown = false
        var ran = false
        let read = Task { @MainActor in await updates.settled(); ran = true }
        updates.revealDelay = 0
        updates.isShown = true
        await read.value
        XCTAssertTrue(ran)
    }

    /// A pop given up (the chat dragged back) covers the list again: the
    /// reads wait for the next showing, and one whose view went returns.
    @MainActor
    func testACancelledPopKeepsTheReadsWaitingAndAGoneViewsReadReturns() async throws {
        let updates = popSettleUpdates()
        updates.isShown = false
        var ran = false
        let read = Task { @MainActor in await updates.settled(); ran = true }
        updates.revealDelay = 0.1
        updates.isShown = true
        updates.isShown = false
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(ran, "covered again before the slide ended")
        updates.revealDelay = 0
        updates.isShown = true
        await read.value
        XCTAssertTrue(ran, "the next showing runs it")

        updates.isShown = false
        var cancelledReturned = false
        let gone = Task { @MainActor in await updates.settled(); cancelledReturned = true }
        try await Task.sleep(for: .milliseconds(20))
        gone.cancel()
        await gone.value
        XCTAssertTrue(cancelledReturned)
        XCTAssertTrue(gone.isCancelled)
    }

    /// A Bot Chat's zoom back runs about a second: the wait ends as the
    /// popped screen goes, not at a fixed time, and at its cap at most.
    @MainActor
    func testAPopsWaitEndsAsThePoppedScreenGoes() async throws {
        let updates = popSettleUpdates()
        updates.isShown = false
        var ran = false
        let read = Task { @MainActor in await updates.settled(); ran = true }
        updates.revealDelay = 30
        updates.isShown = true
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(ran, "the zoom is still on")
        NotificationCenter.default.post(name: V2ShownUpdates.routeLeft, object: nil)
        await read.value
        XCTAssertTrue(ran)
        XCTAssertTrue(updates.hasSettled)
        XCTAssertGreaterThan(V2ShownUpdates.popSlide, 1.2, "the cap outlasts the longest zoom measured")
    }

    /// The reads it held answer one by one after the wait: their publishes
    /// draw the list once, at the burst's end, not once per answer.
    @MainActor
    func testAnswersRightAfterAPopDrawOnce() async throws {
        let updates = popSettleUpdates()
        updates.popBurst = 0.2
        var sent = 0
        let watch = updates.objectWillChange.sink { sent += 1 }
        defer { watch.cancel() }
        updates.isShown = false
        updates.revealDelay = 0.05
        updates.isShown = true
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(updates.hasSettled)
        sent = 0
        updates.appState.objectWillChange.send()
        try await Task.sleep(for: .milliseconds(30))
        updates.appState.objectWillChange.send()
        XCTAssertEqual(sent, 0, "held for the burst")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(sent, 1, "one draw for the burst")
        // Past it, a publish draws at once again.
        updates.appState.objectWillChange.send()
        XCTAssertEqual(sent, 2)
    }
}
