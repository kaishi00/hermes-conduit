//
//  RoomReplayCoordinatorTests.swift
//  Conduit
//
//  Deterministic replay acceptance for the ANVIL Room seam: cursor replay,
//  empty/multi-page/duplicate/out-of-order pages, interruption + resume,
//  process-restart restoration, projection-unavailable staleness, and
//  per-dashboard state isolation. Transport is a scripted fake — no network.
//

import Foundation
import XCTest
@testable import Conduit

/// Scripted Hub: handlers are ordinary closures over the fixture builders,
/// pages are consumed in order, and every replay `after` is recorded.
private final class ScriptedHub {
    var snapshot: (() throws -> RoomSnapshot)?
    var pages: [(URLRequest) throws -> RoomEventPage] = []
    var afterValues: [Int] = []
    var requestCount = 0

    var transport: RoomTransport {
        RoomTransport { request in
            self.requestCount += 1
            guard let url = request.url else { throw URLError(.badURL) }
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            if url.path.hasSuffix("/events") {
                let after = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "after" }
                    .flatMap { $0.value.flatMap(Int.init) } ?? 0
                self.afterValues.append(after)
                guard !self.pages.isEmpty else { throw URLError(.networkConnectionLost) }
                let handler = self.pages.removeFirst()
                return (try JSONEncoder().encode(handler(request)), response)
            }
            guard let snapshot = self.snapshot else { throw URLError(.networkConnectionLost) }
            return (try JSONEncoder().encode(snapshot()), response)
        }
    }
}

@MainActor
final class RoomReplayCoordinatorTests: XCTestCase {
    static let roomID = "10000000-0000-4000-8000-0000000000a1"
    static let correlation = "10000000-0000-4000-8000-0000000000d1"
    let dashboardID = UUID()
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "RoomReplayCoordinatorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeCoordinator(
        hub: ScriptedHub,
        defaults: UserDefaults? = nil,
        dashboardID: UUID? = nil
    ) throws -> RoomReplayCoordinator {
        let client = try RoomProjectionClient(
            credential: RoomHubCredential(hubBaseURL: "https://hub.test", token: "tok"),
            transport: hub.transport
        )
        return RoomReplayCoordinator(
            client: client,
            store: RoomReplayStore(defaults: defaults ?? self.defaults),
            dashboardID: dashboardID ?? self.dashboardID
        )
    }

    // MARK: - Fixture builders (models encode to the exact H1 wire shape)

    nonisolated private func room(latestSeq: Int) -> ProjectedRoom {
        ProjectedRoom(
            roomID: Self.roomID,
            projectRef: "anvil/core",
            status: .active,
            correlationID: Self.correlation,
            latestSeq: latestSeq,
            createdAt: "2026-09-15T10:00:00.000Z",
            updatedAt: "2026-09-15T12:00:00.000Z"
        )
    }

    nonisolated private func event(_ seq: Int, roomID: String = RoomReplayCoordinatorTests.roomID) -> RoomEvent {
        RoomEvent(
            eventID: "20000000-0000-4000-8000-\(String(format: "%012x", seq))",
            roomID: roomID,
            roomSeq: seq,
            kind: .message,
            producer: "agent:10000000-0000-4000-8000-0000000000c2",
            payload: ["text": .string("event \(seq)")],
            link: [:],
            correlationID: Self.correlation,
            causationID: nil,
            taskRef: nil,
            campaignID: nil,
            idempotencyKey: "agent:x:\(seq)",
            occurredAt: nil,
            createdAt: "2026-09-15T11:00:00.000Z"
        )
    }

    nonisolated private func snapshot(latestSeq: Int) -> RoomSnapshot {
        RoomSnapshot(room: room(latestSeq: latestSeq), participants: [])
    }

    nonisolated private func page(
        _ events: [RoomEvent],
        latestSeq: Int,
        nextCursor: Int,
        hasMore: Bool
    ) -> RoomEventPage {
        RoomEventPage(
            room: room(latestSeq: latestSeq),
            events: events,
            latestSeq: latestSeq,
            nextCursor: nextCursor,
            hasMore: hasMore
        )
    }

    // MARK: - Cursor replay

    func testSyncReplaysFromDurableCursorAndCommitsHighWater() async throws {
        let hub = ScriptedHub()
        hub.snapshot = { self.snapshot(latestSeq: 4) }
        hub.pages = [{ _ in self.page([self.event(1), self.event(2), self.event(3)], latestSeq: 4, nextCursor: 3, hasMore: false) }]
        let coordinator = try makeCoordinator(hub: hub)

        let report = try await coordinator.sync(roomID: Self.roomID)

        XCTAssertEqual(hub.afterValues, [0], "First sync must replay from cursor 0")
        XCTAssertEqual(report.eventsApplied, 3)
        XCTAssertEqual(report.finalCursor, 3)
        let projection = coordinator.projection(for: Self.roomID)
        XCTAssertEqual(projection.events.map(\.roomSeq), [1, 2, 3])
        XCTAssertEqual(projection.freshness, .live)
        XCTAssertEqual(projection.cursor, 3)
    }

    func testEmptyReplayAdvancesCursorWithoutApplying() async throws {
        let hub = ScriptedHub()
        hub.snapshot = { self.snapshot(latestSeq: 0) }
        hub.pages = [{ _ in self.page([], latestSeq: 0, nextCursor: 0, hasMore: false) }]
        let coordinator = try makeCoordinator(hub: hub)

        let report = try await coordinator.sync(roomID: Self.roomID)

        XCTAssertEqual(report.eventsApplied, 0)
        XCTAssertEqual(report.pagesFetched, 1)
        XCTAssertTrue(coordinator.projection(for: Self.roomID).events.isEmpty)
        XCTAssertEqual(coordinator.projection(for: Self.roomID).freshness, .live)
    }

    func testMultiPageReplayFollowsNextCursorUntilHighWater() async throws {
        let hub = ScriptedHub()
        hub.snapshot = { self.snapshot(latestSeq: 6) }
        hub.pages = [
            { _ in self.page([self.event(1), self.event(2)], latestSeq: 6, nextCursor: 2, hasMore: true) },
            { _ in self.page([self.event(3), self.event(4)], latestSeq: 6, nextCursor: 4, hasMore: true) },
            { _ in self.page([self.event(5), self.event(6)], latestSeq: 6, nextCursor: 6, hasMore: false) }
        ]
        let coordinator = try makeCoordinator(hub: hub)

        let report = try await coordinator.sync(roomID: Self.roomID)

        XCTAssertEqual(hub.afterValues, [0, 2, 4], "Pagination must follow the server next_cursor")
        XCTAssertEqual(report.pagesFetched, 3)
        XCTAssertEqual(report.eventsApplied, 6)
        XCTAssertEqual(coordinator.projection(for: Self.roomID).events.map(\.roomSeq), [1, 2, 3, 4, 5, 6])
    }

    // MARK: - Duplicate replay

    func testDuplicateEventsAcrossPagesApplyOnce() async throws {
        let hub = ScriptedHub()
        hub.snapshot = { self.snapshot(latestSeq: 4) }
        // A re-delivering proxy emits seq 2 in both pages.
        hub.pages = [
            { _ in self.page([self.event(1), self.event(2)], latestSeq: 4, nextCursor: 2, hasMore: true) },
            { _ in self.page([self.event(2), self.event(3), self.event(4)], latestSeq: 4, nextCursor: 4, hasMore: false) }
        ]
        let coordinator = try makeCoordinator(hub: hub)

        let report = try await coordinator.sync(roomID: Self.roomID)

        XCTAssertEqual(report.eventsApplied, 4)
        XCTAssertEqual(report.duplicatesDropped, 1)
        XCTAssertEqual(
            coordinator.projection(for: Self.roomID).events.map(\.roomSeq),
            [1, 2, 3, 4],
            "(room_id, room_seq) dedupe: seq 2 must never apply twice"
        )
    }

    func testSecondSyncReplayingCommittedEventsAppliesNothing() async throws {
        let hub = ScriptedHub()
        hub.snapshot = { self.snapshot(latestSeq: 2) }
        hub.pages = [
            { _ in self.page([self.event(1), self.event(2)], latestSeq: 2, nextCursor: 2, hasMore: false) },
            // A misbehaving projection re-emits committed seqs on the next pass.
            { _ in self.page([self.event(1), self.event(2)], latestSeq: 2, nextCursor: 2, hasMore: false) }
        ]
        let coordinator = try makeCoordinator(hub: hub)

        _ = try await coordinator.sync(roomID: Self.roomID)
        let second = try await coordinator.sync(roomID: Self.roomID)

        XCTAssertEqual(second.eventsApplied, 0)
        XCTAssertEqual(second.duplicatesDropped, 2)
        XCTAssertEqual(coordinator.projection(for: Self.roomID).events.count, 2)
    }

    // MARK: - Out-of-order

    func testOutOfOrderPageAppliesInAuthorityOrderDeterministically() async throws {
        let hub = ScriptedHub()
        hub.snapshot = { self.snapshot(latestSeq: 3) }
        hub.pages = [{ _ in self.page([self.event(3), self.event(1), self.event(2)], latestSeq: 3, nextCursor: 3, hasMore: false) }]
        let coordinator = try makeCoordinator(hub: hub)

        let report = try await coordinator.sync(roomID: Self.roomID)

        XCTAssertEqual(report.outOfOrderDeliveries, 1)
        XCTAssertEqual(
            coordinator.projection(for: Self.roomID).events.map(\.roomSeq),
            [1, 2, 3],
            "Arrival order must never corrupt the authority-order projection"
        )
    }

    func testForeignRoomEventIsDroppedAsContractViolation() async throws {
        let hub = ScriptedHub()
        hub.snapshot = { self.snapshot(latestSeq: 3) }
        hub.pages = [{ _ in self.page(
            [self.event(1), self.event(2, roomID: "90000000-0000-4000-8000-0000000000ff"), self.event(3)],
            latestSeq: 3, nextCursor: 3, hasMore: false
        ) }]
        let coordinator = try makeCoordinator(hub: hub)

        let report = try await coordinator.sync(roomID: Self.roomID)

        XCTAssertEqual(report.foreignEventsDropped, 1)
        XCTAssertEqual(coordinator.projection(for: Self.roomID).events.map(\.roomSeq), [1, 3])
    }

    // MARK: - Projection unavailable / stale

    func testProjectionUnavailableMarksStaleWithoutLosingState() async throws {
        let hub = ScriptedHub()
        hub.snapshot = { self.snapshot(latestSeq: 2) }
        hub.pages = [{ _ in self.page([self.event(1), self.event(2)], latestSeq: 2, nextCursor: 2, hasMore: false) }]
        let coordinator = try makeCoordinator(hub: hub)
        _ = try await coordinator.sync(roomID: Self.roomID)

        // Hub reports the seam unconfigured on the next pass.
        hub.snapshot = {
            throw RoomProjectionError.projectionUnavailable(RoomProblem(
                type: nil, title: "Room projection unavailable", status: 503,
                detail: "This Hub instance is not configured with an ANVIL Room read seam.",
                code: "room_projection_unavailable", requestID: "req-1"
            ))
        }
        do {
            _ = try await coordinator.sync(roomID: Self.roomID)
            XCTFail("Expected projectionUnavailable")
        } catch let error as RoomProjectionError {
            guard case .projectionUnavailable = error else {
                return XCTFail("Expected .projectionUnavailable, got \(error)")
            }
        }

        let projection = coordinator.projection(for: Self.roomID)
        guard case .stale = projection.freshness else {
            return XCTFail("Projection must be marked stale, got \(projection.freshness)")
        }
        XCTAssertEqual(projection.events.map(\.roomSeq), [1, 2], "Stale projection keeps the last durable events")
        XCTAssertNotNil(projection.lastError)
    }

    // MARK: - Interruption + resume

    func testNetworkInterruptionResumesFromLastCommittedPage() async throws {
        let hub = ScriptedHub()
        hub.snapshot = { self.snapshot(latestSeq: 5) }
        hub.pages = [
            { _ in self.page([self.event(1), self.event(2)], latestSeq: 5, nextCursor: 2, hasMore: true) },
            { _ in throw URLError(.networkConnectionLost) }
        ]
        let coordinator = try makeCoordinator(hub: hub)

        do {
            _ = try await coordinator.sync(roomID: Self.roomID)
            XCTFail("Expected transport failure")
        } catch let error as RoomProjectionError {
            guard case .transport = error else {
                return XCTFail("Expected .transport, got \(error)")
            }
        }
        let stale = coordinator.projection(for: Self.roomID)
        guard case .stale = stale.freshness else {
            return XCTFail("Interrupted projection must be stale")
        }
        XCTAssertEqual(stale.cursor, 2, "Durable cursor must sit at the last committed page")
        XCTAssertEqual(stale.events.map(\.roomSeq), [1, 2])

        // Network heals; replay continues from the committed cursor.
        hub.pages = [{ _ in self.page([self.event(3), self.event(4), self.event(5)], latestSeq: 5, nextCursor: 5, hasMore: false) }]
        let report = try await coordinator.sync(roomID: Self.roomID)

        XCTAssertEqual(hub.afterValues, [0, 2, 2], "Resume must re-issue the last committed cursor")
        XCTAssertEqual(report.eventsApplied, 3)
        XCTAssertEqual(coordinator.projection(for: Self.roomID).events.map(\.roomSeq), [1, 2, 3, 4, 5])
        XCTAssertEqual(coordinator.projection(for: Self.roomID).freshness, .live)
    }

    // MARK: - State restoration after process restart

    func testColdRestartRestoresProjectionAndResumesFromDurableCursor() async throws {
        let hub = ScriptedHub()
        hub.snapshot = { self.snapshot(latestSeq: 4) }
        hub.pages = [{ _ in self.page([self.event(1), self.event(2), self.event(3)], latestSeq: 4, nextCursor: 3, hasMore: false) }]
        let first = try makeCoordinator(hub: hub)
        _ = try await first.sync(roomID: Self.roomID)

        // Process restart: new store + coordinator instances over the same
        // UserDefaults suite. The dedupe window and cursor come back.
        let secondHub = ScriptedHub()
        secondHub.snapshot = { self.snapshot(latestSeq: 4) }
        secondHub.pages = [{ _ in self.page([self.event(4)], latestSeq: 4, nextCursor: 4, hasMore: false) }]
        let second = try makeCoordinator(hub: secondHub)

        let restored = second.restore(roomID: Self.roomID)
        XCTAssertEqual(restored.cursor, 3)
        XCTAssertEqual(restored.events.map(\.roomSeq), [1, 2, 3])
        XCTAssertEqual(restored.freshness, .live)

        let report = try await second.sync(roomID: Self.roomID)
        XCTAssertEqual(secondHub.afterValues, [3], "Restart must resume from the durable cursor, not 0")
        XCTAssertEqual(report.eventsApplied, 1)
        XCTAssertEqual(second.projection(for: Self.roomID).events.map(\.roomSeq), [1, 2, 3, 4])
    }

    func testRestartDedupesEventsRedeliveredAcrossTheCrashBoundary() async throws {
        // Events 1..3 applied and committed; then simulate the
        // crash-between-apply-and-commit window by rewinding the durable
        // cursor one event behind the persisted dedupe window.
        let hub = ScriptedHub()
        hub.snapshot = { self.snapshot(latestSeq: 4) }
        hub.pages = [{ _ in self.page([self.event(1), self.event(2), self.event(3)], latestSeq: 4, nextCursor: 3, hasMore: false) }]
        let first = try makeCoordinator(hub: hub)
        _ = try await first.sync(roomID: Self.roomID)

        var store = RoomReplayStore(defaults: defaults)
        let record = store.record(dashboardID: dashboardID, roomID: Self.roomID)
        store.clear(dashboardID: dashboardID, roomID: Self.roomID)
        store.commitPage(
            dashboardID: dashboardID,
            roomID: Self.roomID,
            cursor: 2,
            newlyAppliedSeqs: record.appliedSeqs,
            room: record.room,
            participants: record.participants,
            appliedEvents: record.events,
            syncedAt: Date()
        )

        // After the "restart" the upstream re-delivers seq 3 (cursor 2 was
        // durable, seq 3 was applied) alongside new seq 4.
        let secondHub = ScriptedHub()
        secondHub.snapshot = { self.snapshot(latestSeq: 4) }
        secondHub.pages = [{ _ in self.page([self.event(3), self.event(4)], latestSeq: 4, nextCursor: 4, hasMore: false) }]
        let second = try makeCoordinator(hub: secondHub)
        _ = second.restore(roomID: Self.roomID)

        let report = try await second.sync(roomID: Self.roomID)
        XCTAssertEqual(secondHub.afterValues, [2])
        XCTAssertEqual(report.duplicatesDropped, 1, "Re-delivered seq 3 must dedupe on (room_id, room_seq)")
        XCTAssertEqual(report.eventsApplied, 1)
        XCTAssertEqual(second.projection(for: Self.roomID).events.map(\.roomSeq), [1, 2, 3, 4])
    }

    // MARK: - Dashboard isolation

    func testReplayStateIsIsolatedPerDashboard() async throws {
        let otherDashboard = UUID()
        let hub = ScriptedHub()
        hub.snapshot = { self.snapshot(latestSeq: 2) }
        hub.pages = [{ _ in self.page([self.event(1), self.event(2)], latestSeq: 2, nextCursor: 2, hasMore: false) }]
        let coordinator = try makeCoordinator(hub: hub)
        _ = try await coordinator.sync(roomID: Self.roomID)

        let store = RoomReplayStore(defaults: defaults)
        XCTAssertEqual(store.record(dashboardID: dashboardID, roomID: Self.roomID).cursor, 2)
        XCTAssertEqual(
            store.record(dashboardID: otherDashboard, roomID: Self.roomID),
            .empty,
            "The same room_id under another dashboard must have independent state"
        )

        // A second dashboard syncing the same room gets its own record.
        let secondHub = ScriptedHub()
        secondHub.snapshot = { self.snapshot(latestSeq: 1) }
        secondHub.pages = [{ _ in self.page([self.event(1)], latestSeq: 1, nextCursor: 1, hasMore: false) }]
        let other = try makeCoordinator(hub: secondHub, dashboardID: otherDashboard)
        _ = try await other.sync(roomID: Self.roomID)

        // Re-read durable state after the second dashboard's sync.
        let after = RoomReplayStore(defaults: defaults)
        XCTAssertEqual(after.record(dashboardID: otherDashboard, roomID: Self.roomID).cursor, 1)
        XCTAssertEqual(after.record(dashboardID: dashboardID, roomID: Self.roomID).cursor, 2)

        var clearing = RoomReplayStore(defaults: defaults)
        clearing.clearDashboard(otherDashboard)
        XCTAssertEqual(clearing.record(dashboardID: otherDashboard, roomID: Self.roomID), .empty)
        XCTAssertEqual(
            clearing.record(dashboardID: dashboardID, roomID: Self.roomID).cursor,
            2,
            "Clearing one dashboard must not reach another's replay state"
        )
    }
}
