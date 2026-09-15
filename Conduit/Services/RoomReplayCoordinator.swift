//
//  RoomReplayCoordinator.swift
//  Conduit
//
//  Deterministic replay state for the ANVIL Room read seam. This is the
//  state-integration half of the lane: it drives RoomProjectionClient,
//  commits durable progress to RoomReplayStore, and owns the in-memory
//  projection the (future) Room surface renders.
//
//  Replay contract (H1 @ 078ff5a2):
//  - `after` is the durable consumed cursor; the server emits committed
//    events with room_seq > after, ascending, deduplicated upstream;
//  - `next_cursor` is the server-emitted continuation point — pagination
//    follows next_cursor, NOT the last applied seq, so re-delivered or
//    deduped events can never stall the loop;
//  - dedupe identity is (room_id, room_seq): a re-delivered event is dropped
//    by key membership and can never become duplicate semantic state;
//  - out-of-order deliveries are handled deterministically: each page is
//    applied in ascending room_seq order and the projection log is kept
//    sorted, so arrival order can never change the final projection;
//  - events whose room_id is not the synced room are contract violations —
//    dropped and counted, never applied.
//
//  Stale/offline is explicit state: a failed sync leaves the last durable
//  projection marked `.stale(reason)` — never silently empty, never
//  failed-open as live.
//

import Foundation

@MainActor
final class RoomReplayCoordinator {
    enum Freshness: Equatable {
        /// No successful sync has ever committed for this room.
        case neverSynced
        /// The projection reflects the committed high-water as of lastSyncAt.
        case live
        /// The last sync failed; the projection is the last durable state.
        case stale(String)
    }

    /// The renderable projection of one room.
    struct Projection: Equatable {
        var room: ProjectedRoom?
        var participants: [RoomParticipant] = []
        /// Applied events, ascending room_seq, deduplicated by
        /// (room_id, room_seq).
        var events: [RoomEvent] = []
        /// The consumed replay cursor (durable high-water).
        var cursor: Int = 0
        var freshness: Freshness = .neverSynced
        var lastSyncAt: Date?
        var lastError: String?
    }

    /// Diagnostic report for one sync pass — the tiny harness surface the
    /// lane allows: enough to prove what replay did without a finished UI.
    struct SyncReport: Equatable {
        var pagesFetched = 0
        var eventsApplied = 0
        var duplicatesDropped = 0
        var foreignEventsDropped = 0
        var outOfOrderDeliveries = 0
        var finalCursor = 0
    }

    private let client: RoomProjectionClient
    private var store: RoomReplayStore
    private let dashboardID: UUID
    private let clock: () -> Date
    /// Session-exact dedupe: every (room_id, room_seq) applied since launch,
    /// seeded from the durable window. Persisted dedupe is a bounded tail;
    /// the in-memory set is unbounded so a long session cannot regress.
    private var appliedKeys: [String: Set<RoomEventKey>] = [:]
    private var projections: [String: Projection] = [:]

    init(
        client: RoomProjectionClient,
        store: RoomReplayStore,
        dashboardID: UUID,
        clock: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.store = store
        self.dashboardID = dashboardID
        self.clock = clock
    }

    /// The current in-memory projection, hydrated from the durable record on
    /// first access — this is also the post-relaunch restore path.
    func projection(for roomID: String) -> Projection {
        if let existing = projections[roomID] { return existing }
        let restored = restore(roomID: roomID)
        projections[roomID] = restored
        return restored
    }

    /// Rehydrate the projection from durable state alone — what a cold
    /// process restart sees before any network traffic.
    @discardableResult
    func restore(roomID: String) -> Projection {
        let record = store.record(dashboardID: dashboardID, roomID: roomID)
        appliedKeys[roomID] = Set(record.events.map(\.dedupeKey))
            .union(record.appliedSeqs.map { RoomEventKey(roomID: roomID, roomSeq: $0) })
        let projection = Projection(
            room: record.room,
            participants: record.participants,
            events: record.events,
            cursor: record.cursor,
            freshness: record.lastSyncAt == nil
                ? .neverSynced
                : (record.lastSyncError.map { .stale($0) } ?? .live),
            lastSyncAt: record.lastSyncAt,
            lastError: record.lastSyncError
        )
        projections[roomID] = projection
        return projection
    }

    /// One full catch-up: snapshot + replay pages from the durable cursor
    /// until the committed high-water is consumed. On any failure the
    /// durable cursor stays at the last committed page and the projection
    /// is marked stale — a retry is always a resume, never a restart.
    @discardableResult
    func sync(roomID: String) async throws -> SyncReport {
        var report = SyncReport()
        var projection = self.projection(for: roomID)
        do {
            let snapshot = try await client.roomSnapshot(roomID: roomID)
            projection.room = snapshot.room
            projection.participants = snapshot.participants

            var after = store.record(dashboardID: dashboardID, roomID: roomID).cursor
            while true {
                let page = try await client.replayEvents(roomID: roomID, after: after)
                report.pagesFetched += 1
                projection.room = page.room
                let applied = apply(
                    page: page,
                    roomID: roomID,
                    into: &projection,
                    report: &report
                )

                // Commit consumed cursor + dedupe window atomically per page:
                // the cursor never advances past a seq the dedupe window
                // cannot explain.
                let committedCursor = max(
                    store.record(dashboardID: dashboardID, roomID: roomID).cursor,
                    page.nextCursor
                )
                store.commitPage(
                    dashboardID: dashboardID,
                    roomID: roomID,
                    cursor: committedCursor,
                    newlyAppliedSeqs: applied.map(\.roomSeq),
                    room: page.room,
                    participants: snapshot.participants,
                    appliedEvents: projection.events,
                    syncedAt: clock()
                )
                projection.cursor = committedCursor
                projection.lastSyncAt = clock()
                projections[roomID] = projection

                guard page.hasMore else { break }
                after = page.nextCursor
            }
            projection.freshness = .live
            projection.lastError = nil
            projections[roomID] = projection
            report.finalCursor = projection.cursor
            return report
        } catch {
            let reason = error.localizedDescription
            projection.freshness = .stale(reason)
            projection.lastError = reason
            projections[roomID] = projection
            store.markSyncFailed(
                dashboardID: dashboardID,
                roomID: roomID,
                error: reason,
                at: clock()
            )
            throw error
        }
    }

    /// Applies one replay page deterministically: events are sorted into
    /// ascending room_seq before application (arrival order can never
    /// corrupt the projection), deduped by (room_id, room_seq), and
    /// foreign-room events are dropped as contract violations. Returns the
    /// events this page newly applied.
    private func apply(
        page: RoomEventPage,
        roomID: String,
        into projection: inout Projection,
        report: inout SyncReport
    ) -> [RoomEvent] {
        var keys = appliedKeys[roomID] ?? []
        var applied: [RoomEvent] = []
        let ordered = page.events.sorted { lhs, rhs in
            if lhs.roomSeq != rhs.roomSeq { return lhs.roomSeq < rhs.roomSeq }
            return lhs.eventID < rhs.eventID
        }
        if zip(page.events, page.events.dropFirst()).contains(where: { $0.roomSeq > $1.roomSeq }) {
            report.outOfOrderDeliveries += 1
        }
        for event in ordered {
            guard event.roomID == roomID else {
                report.foreignEventsDropped += 1
                continue
            }
            guard keys.insert(event.dedupeKey).inserted else {
                report.duplicatesDropped += 1
                continue
            }
            insertSorted(event, into: &projection.events)
            applied.append(event)
            report.eventsApplied += 1
        }
        appliedKeys[roomID] = keys
        return applied
    }

    private func insertSorted(_ event: RoomEvent, into events: inout [RoomEvent]) {
        // First index whose seq is >= the incoming event's: keeps the log in
        // authority order regardless of arrival order.
        let index = events.firstIndex { $0.roomSeq >= event.roomSeq } ?? events.endIndex
        events.insert(event, at: index)
    }
}
