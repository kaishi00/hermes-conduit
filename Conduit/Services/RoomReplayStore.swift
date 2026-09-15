//
//  RoomReplayStore.swift
//  Conduit
//
//  Durable replay state for the ANVIL Room projection, per (dashboard, room).
//
//  Storage is UserDefaults, not the Keychain: the replay cursor, applied-seq
//  dedupe window, and projected event tail are connection STATE (like
//  ChatResumeStore's snapshots), not secrets. Secrets — the Hub bearer
//  credential — live in the dashboard-scoped Keychain record; this store
//  deliberately holds no token material.
//
//  Durable invariants the coordinator relies on:
//  - `cursor` is the consumed replay high-water (the last server-emitted
//    next_cursor committed atomically with the page's applied seqs), so a
//    relaunch resumes with `after = cursor` and never re-requests committed
//    history;
//  - `appliedSeqs` is a bounded tail of applied room_seqs. It exists so an
//    event re-delivered after restart (crash between apply and commit,
//    misbehaving proxy, duplicate page) can never become duplicate semantic
//    state — dedupe is by (room_id, room_seq) membership, never by seq
//    comparison alone;
//  - `events` is a bounded applied tail for projection restore; the cursor
//    and dedupe window are the correctness-critical fields.
//

import Foundation

struct RoomReplayRecord: Codable, Equatable {
    /// Consumed replay high-water (server next_cursor of the last committed
    /// page), 0 before the first sync.
    var cursor: Int
    /// Bounded tail of applied room_seqs — the durable dedupe window.
    var appliedSeqs: [Int]
    /// Bounded applied event tail, ascending room_seq.
    var events: [RoomEvent]
    var room: ProjectedRoom?
    var participants: [RoomParticipant]
    var lastSyncAt: Date?
    /// Last sync failure the projection is still marked stale by.
    var lastSyncError: String?

    static let empty = RoomReplayRecord(
        cursor: 0,
        appliedSeqs: [],
        events: [],
        room: nil,
        participants: [],
        lastSyncAt: nil,
        lastSyncError: nil
    )
}

struct RoomReplayStore {
    static let schemaVersion = 1
    static let defaultStorageKey = "conduit.roomReplay.v1"
    /// Dedupe window per room. Replay `> cursor` can only re-deliver recently
    /// committed seqs, so a bounded tail is sufficient for the no-duplicate
    /// invariant.
    static let maximumAppliedSeqWindow = 2048
    static let maximumEventTail = 500
    static let maximumRooms = 64

    private struct Payload: Codable, Equatable {
        let version: Int
        var records: [String: RoomReplayRecord]
        /// Insertion-ordered record keys for bounded eviction.
        var order: [String]
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private var payload: Payload

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = RoomReplayStore.defaultStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        guard let data = defaults.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode(Payload.self, from: data),
              stored.version == Self.schemaVersion else {
            payload = Payload(version: Self.schemaVersion, records: [:], order: [])
            return
        }
        payload = stored
    }

    static func recordKey(dashboardID: UUID, roomID: String) -> String {
        "\(dashboardID.uuidString)/\(roomID)"
    }

    func record(dashboardID: UUID, roomID: String) -> RoomReplayRecord {
        payload.records[Self.recordKey(dashboardID: dashboardID, roomID: roomID)] ?? .empty
    }

    /// Atomically commits one consumed replay page: the consumed cursor and
    /// the page's newly applied seqs move together, so a crash can never
    /// persist a cursor ahead of its dedupe window.
    mutating func commitPage(
        dashboardID: UUID,
        roomID: String,
        cursor: Int,
        newlyAppliedSeqs: [Int],
        room: ProjectedRoom?,
        participants: [RoomParticipant]?,
        appliedEvents: [RoomEvent],
        syncedAt: Date
    ) {
        var record = self.record(dashboardID: dashboardID, roomID: roomID)
        record.cursor = max(record.cursor, cursor)
        if !newlyAppliedSeqs.isEmpty {
            record.appliedSeqs.append(contentsOf: newlyAppliedSeqs)
            if record.appliedSeqs.count > Self.maximumAppliedSeqWindow {
                record.appliedSeqs.removeFirst(record.appliedSeqs.count - Self.maximumAppliedSeqWindow)
            }
        }
        record.events = appliedEvents.suffix(Self.maximumEventTail).map { $0 }
        if let room { record.room = room }
        if let participants { record.participants = participants }
        record.lastSyncAt = syncedAt
        record.lastSyncError = nil
        write(record, key: Self.recordKey(dashboardID: dashboardID, roomID: roomID))
    }

    /// Marks the projection stale without moving the cursor: the next sync
    /// resumes from the last committed page.
    mutating func markSyncFailed(dashboardID: UUID, roomID: String, error: String, at: Date) {
        var record = self.record(dashboardID: dashboardID, roomID: roomID)
        record.lastSyncError = error
        record.lastSyncAt = at
        write(record, key: Self.recordKey(dashboardID: dashboardID, roomID: roomID))
    }

    /// Removes one dashboard's replay record for a room. Scoped like the
    /// credential records: deleting dashboard A's state cannot reach
    /// dashboard B's record for the same room_id.
    mutating func clear(dashboardID: UUID, roomID: String) {
        let key = Self.recordKey(dashboardID: dashboardID, roomID: roomID)
        guard payload.records.removeValue(forKey: key) != nil else { return }
        payload.order.removeAll { $0 == key }
        persist()
    }

    /// Removes every replay record belonging to a dashboard (sign-out /
    /// dashboard removal).
    mutating func clearDashboard(_ dashboardID: UUID) {
        let prefix = "\(dashboardID.uuidString)/"
        let keys = payload.records.keys.filter { $0.hasPrefix(prefix) }
        guard !keys.isEmpty else { return }
        for key in keys { payload.records.removeValue(forKey: key) }
        payload.order.removeAll { keys.contains($0) }
        persist()
    }

    private mutating func write(_ record: RoomReplayRecord, key: String) {
        if payload.records[key] == nil {
            payload.order.append(key)
            while payload.order.count > Self.maximumRooms, let evicted = payload.order.first {
                payload.order.removeFirst()
                payload.records.removeValue(forKey: evicted)
            }
        }
        payload.records[key] = record
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
