import XCTest
@testable import Conduit

final class ChatReadStateTests: XCTestCase {
    private let profile = "default"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(
        _ id: String,
        count: Int?,
        unread: Bool? = nil,
        lastActivityAt: TimeInterval? = nil,
        lineageRoot: String? = nil
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: [],
            title: id,
            model: "Hermes",
            updatedLabel: "",
            lastActivityAt: lastActivityAt,
            profile: profile,
            source: .chat,
            isActive: false,
            isArchived: false,
            messageCount: count,
            isUnread: unread,
            lineageRootId: lineageRoot
        )
    }

    func testFirstSightSeedsAsRead() {
        var state = ChatReadState()
        let session = row("a", count: 7)
        state.observe([session], profile: profile, now: t0)
        XCTAssertFalse(state.isUnread(session, profile: profile, now: t0))
    }

    func testNewMessagesAfterSeedAreUnreadUntilSeen() {
        var state = ChatReadState()
        state.observe([row("a", count: 7)], profile: profile, now: t0)
        let grown = row("a", count: 9)
        state.observe([grown], profile: profile, now: t0)
        XCTAssertTrue(state.isUnread(grown, profile: profile, now: t0))

        state.markSeen(grown, profile: profile, at: t0)
        XCTAssertFalse(state.isUnread(grown, profile: profile, now: t0))
    }

    func testHermesFlagAloneMakesARowUnread() {
        var state = ChatReadState()
        let flagged = row("a", count: 3, unread: true)
        state.observe([flagged], profile: profile, now: t0)
        XCTAssertTrue(state.isUnread(flagged, profile: profile, now: t0))
        XCTAssertTrue(state.serverUnread(flagged, profile: profile, now: t0))
    }

    func testOwnWriteOutranksAStaleListingUntilConfirmedOrLapsed() {
        var state = ChatReadState()
        let flagged = row("a", count: 3, unread: true)
        state.observe([flagged], profile: profile, now: t0)
        state.markSeen(flagged, profile: profile, at: t0)
        state.recordServerWrite(flagged, profile: profile, unread: false, at: t0)

        // A listing fetched before the PATCH landed still says unread.
        state.observe([flagged], profile: profile, now: t0.addingTimeInterval(1))
        XCTAssertFalse(state.isUnread(flagged, profile: profile, now: t0.addingTimeInterval(1)))

        // A confirming listing retires the pending value.
        let confirmed = row("a", count: 3, unread: false)
        state.observe([confirmed], profile: profile, now: t0.addingTimeInterval(2))
        XCTAssertTrue(state.pendingServerValues.isEmpty)
        XCTAssertFalse(state.isUnread(confirmed, profile: profile, now: t0.addingTimeInterval(2)))
    }

    func testLapsedWriteYieldsToTheListing() {
        var state = ChatReadState()
        let flagged = row("a", count: 3, unread: true)
        state.recordServerWrite(flagged, profile: profile, unread: false, at: t0)
        let later = t0.addingTimeInterval(ChatReadState.pendingServerValueLifetime + 1)
        XCTAssertTrue(state.isUnread(flagged, profile: profile, now: later))
    }

    func testMarkUnreadSticksUntilSeen() {
        var state = ChatReadState()
        let session = row("a", count: 4)
        state.observe([session], profile: profile, now: t0)
        state.markUnread(session, profile: profile)
        XCTAssertTrue(state.isUnread(session, profile: profile, now: t0))
        XCTAssertTrue(state.isMarkedUnread(session, profile: profile))

        state.markSeen(session, profile: profile, at: t0)
        XCTAssertFalse(state.isUnread(session, profile: profile, now: t0))
        XCTAssertNil(state.ledger.markedUnread[profile])
    }

    func testLeavingAChatAdoptsItsLaggingCountButNotLaterActivity() {
        var state = ChatReadState()
        state.observe([row("a", count: 4)], profile: profile, now: t0)
        // The user watched their own turn finish, then switched away.
        state.markSeen(row("a", count: 4), profile: profile, at: t0)
        let ownTurn = row("a", count: 6, lastActivityAt: t0.timeIntervalSince1970 - 2)
        state.observe([ownTurn], profile: profile, now: t0.addingTimeInterval(10))
        XCTAssertFalse(state.isUnread(ownTurn, profile: profile, now: t0))

        // A reply that lands after they left stays unread.
        state.markSeen(ownTurn, profile: profile, at: t0)
        let laterReply = row("a", count: 8, lastActivityAt: t0.timeIntervalSince1970 + 60)
        state.observe([laterReply], profile: profile, now: t0.addingTimeInterval(70))
        XCTAssertTrue(state.isUnread(laterReply, profile: profile, now: t0.addingTimeInterval(70)))
    }

    func testCompressionKeepsReadStateThroughTheLineageRoot() {
        var state = ChatReadState()
        state.observe([row("root", count: 10)], profile: profile, now: t0)
        let tip = row("tip", count: 10, lineageRoot: "root")
        state.observe([tip], profile: profile, now: t0)
        XCTAssertFalse(state.isUnread(tip, profile: profile, now: t0))
        XCTAssertEqual(ChatReadState.durableID(for: tip), "root")
    }

    func testProfilesDoNotShareState() {
        var state = ChatReadState()
        let session = row("a", count: 2)
        state.observe([session], profile: "work", now: t0)
        state.markUnread(session, profile: "work")
        XCTAssertTrue(state.isUnread(session, profile: "work", now: t0))
        XCTAssertFalse(state.isUnread(session, profile: profile, now: t0))
    }

    func testForgetDropsEverything() {
        var state = ChatReadState()
        let session = row("a", count: 2)
        state.observe([session], profile: profile, now: t0)
        state.markUnread(session, profile: profile)
        state.recordServerWrite(session, profile: profile, unread: true, at: t0)
        state.forget(session, profile: profile)
        XCTAssertNil(state.ledger.seenCounts[profile]?["a"])
        XCTAssertFalse(state.isMarkedUnread(session, profile: profile))
        XCTAssertTrue(state.pendingServerValues.isEmpty)
    }

    func testLedgerRoundTripsThroughJSON() throws {
        var state = ChatReadState()
        let session = row("a", count: 2)
        state.observe([session], profile: profile, now: t0)
        state.markUnread(session, profile: profile)
        let data = try JSONEncoder().encode(state.ledger)
        XCTAssertEqual(try JSONDecoder().decode(ChatReadLedger.self, from: data), state.ledger)
    }

    func testDashboardRowsCarryHermesUnreadFlag() {
        let rows: [[String: Any]] = [
            ["id": "a", "title": "A", "message_count": 3, "unread": true, "profile": "default"],
            ["id": "b", "title": "B", "message_count": 3, "profile": "default"],
        ]
        let sessions = MessageNormalizer.normalizeSessions(
            AnyCodable.from(["sessions": rows] as [String: Any]),
            profile: nil
        )
        XCTAssertEqual(sessions.first { $0.id == "a" }?.isUnread, true)
        XCTAssertNil(sessions.first { $0.id == "b" }?.isUnread)
    }
}
