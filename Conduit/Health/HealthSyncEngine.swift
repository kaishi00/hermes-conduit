//
//  HealthSyncEngine.swift
//  Conduit
//
//  One sync pass: make sure this phone and the Hermes profile share a key,
//  recompute the recent days (the Watch syncs late) and send the windows
//  that changed since the host last took them, then new and deleted
//  workouts, sleep stages and raw readings, then one more step of older
//  history. Recent days go whole every few hours, or when the user asks.
//  Every piece is re-readable from Apple Health, so there is no outbox: an
//  anchor, the history cursor or a window's hash moves only after the host
//  has acknowledged the batch, and a crash or a timeout just means the next
//  pass sends it again (the host's writes are idempotent).
//
//  The pass stops at its deadline (a background wake gets about half a
//  minute) and picks up where it left off next time.
//

import CryptoKit
import Foundation

/// What a pass remembers between runs. No health values: anchors, a date
/// cursor and the host's store generation. Kept in Application Support,
/// readable after first unlock, never backed up.
struct HealthSyncState: Codable, Equatable {
    var deviceID: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    /// Where this state belongs; a different destination starts over.
    var destination: HealthSyncDestination?
    var generation: String?
    /// How far back sharing reaches (fixed per depth so anchors stay valid).
    var historyStart: Date?
    var history: HealthHistoryDepth?
    /// The oldest day already sent; history before it is still to go.
    var backfillCursor: Date?
    /// The categories the history walk covers (its chunks go out with the
    /// categories on now). Nil in a state from before this was kept, or
    /// before the first walk: the next walk starts over to be safe.
    var backfilledCategories: Set<HealthCategory>?
    var anchors: [String: Data] = [:]
    /// Each recent window the host last took, by metric, grain and range,
    /// as a hash of what it carried (HealthBatch.windowPrints), and when
    /// they last all went. Optional so a state file from before still reads.
    var recentWindows: [String: String]?
    var recentWholeAt: Date?
    /// When the host last took an upload, empty or not: only an upload
    /// moves its `last_seen`, so a pass with nothing to send still posts
    /// one every so often (ContextUploadPolicy.healthKeepalive).
    var lastIngest: Date?
    var lastSync: Date?
    var lastAttempt: Date?
    var pause: HealthSyncPause?

    mutating func startOver(keepingDevice: Bool = true) {
        let device = deviceID
        self = HealthSyncState()
        if keepingDevice { deviceID = device }
    }
}

/// The state file. Owner-only, readable in the background after first
/// unlock (as HealthKit itself is), excluded from backups.
struct HealthSyncStateStore {
    var url: URL

    static var standard: HealthSyncStateStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return HealthSyncStateStore(url: base.appendingPathComponent("HealthSync", isDirectory: true)
            .appendingPathComponent("state.json"))
    }

    func load() -> HealthSyncState {
        loadIfReadable() ?? HealthSyncState()
    }

    /// Nil when the file is there but can't be read yet (a phone not unlocked
    /// since restart): a fresh state then would forget this device's ID.
    func loadIfReadable() -> HealthSyncState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return HealthSyncState() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let state = try? JSONDecoder().decode(HealthSyncState.self, from: data) { return state }
        // Unreadable (an older shape, a damaged file): start over, but as the
        // same device, so the host's copy can still be found and deleted.
        var fresh = HealthSyncState()
        if let known = try? JSONDecoder().decode(DeviceOnly.self, from: data) { fresh.deviceID = known.deviceID }
        return fresh
    }

    private struct DeviceOnly: Decodable { var deviceID: String }

    /// False when the file couldn't be written (a locked phone): the caller
    /// keeps its anchors in memory and the next pass re-sends.
    @discardableResult
    func save(_ state: HealthSyncState) -> Bool {
        do {
            var folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
            try JSONEncoder().encode(state).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }
}

/// The agreed key in the Keychain (readable after first unlock).
struct HealthSyncKeyStore {
    var load: () -> HealthSyncCrypto.SessionKey?
    var save: (HealthSyncCrypto.SessionKey) -> Void
    var clear: () -> Void

    static let keychain = HealthSyncKeyStore(
        load: {
            KeychainHelper.loadHealthSyncKey().flatMap { try? JSONDecoder().decode(HealthSyncCrypto.SessionKey.self, from: $0) }
        },
        save: { key in
            if let data = try? JSONEncoder().encode(key) { KeychainHelper.saveHealthSyncKey(data) }
        },
        clear: { KeychainHelper.clearHealthSyncKey() }
    )
}

@MainActor
final class HealthSyncEngine: ObservableObject {
    typealias Request = (_ path: String, _ method: String, _ body: [String: Any]?) async throws -> [String: Any]

    enum Outcome: Equatable {
        case synced
        /// Stopped at the deadline or on a locked phone; the next pass goes on.
        case unfinished
        case paused(HealthSyncPause)
        /// Nothing to do: sharing is off.
        case off
        case failed(String)
    }

    static let base = "/api/plugins/conduit_push/health"

    @Published private(set) var state: HealthSyncState
    @Published private(set) var isSyncing = false
    @Published private(set) var lastError: String?

    let source: HealthDataSource
    private let store: HealthSyncStateStore
    private let keys: HealthSyncKeyStore
    private let now: () -> Date
    private let deviceName: () -> String
    var calendar: Calendar
    private var running: Task<Outcome, Never>?
    private var runningPreferences: HealthSyncPreferences?
    private var runningOptions = HealthPassOptions()
    /// Apple Health woke Conduit with new data while a pass had only just
    /// run: the next pass, for any reason, runs without waiting its turn.
    var changesWaiting = false
    private var turnOffs = 0
    /// The state file couldn't be read at launch; nothing runs until it can.
    private var stateUnread = false

    init(
        source: HealthDataSource,
        store: HealthSyncStateStore = .standard,
        keys: HealthSyncKeyStore = .keychain,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init,
        deviceName: @escaping () -> String = { "iPhone" }
    ) {
        self.source = source
        self.store = store
        self.keys = keys
        self.calendar = calendar
        self.now = now
        self.deviceName = deviceName
        if let state = store.loadIfReadable() {
            self.state = state
        } else {
            self.state = HealthSyncState()
            stateUnread = true
        }
    }

    /// Runs a pass, or joins the one already running. A pass started with
    /// other choices, or that does less than these options ask (Sync now
    /// during a routine pass), is followed by one with these, so a change
    /// isn't lost.
    func sync(preferences: HealthSyncPreferences, deadline: Date, options: HealthPassOptions = HealthPassOptions(),
              request: @escaping Request) async -> Outcome {
        let turnOffs = self.turnOffs
        while let current = running {
            let joined = runningPreferences
            let joinedOptions = runningOptions
            let outcome = await current.value
            if joined == preferences, joinedOptions.covers(options) { return outcome }
            // Turned off meanwhile: these choices no longer hold.
            guard self.turnOffs == turnOffs else { return .off }
            if running == current { running = nil }
        }
        let task = Task { await self.pass(preferences: preferences, deadline: deadline, options: options, request: request) }
        running = task
        runningPreferences = preferences
        runningOptions = options
        isSyncing = true
        // An expiring background task stops the pass with it.
        let outcome = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        // A follow-up may have taken over already.
        if running == task {
            running = nil
            isSyncing = false
        }
        return outcome
    }

    /// Records a pause found outside a pass (another dashboard in use).
    func note(_ pause: HealthSyncPause?) {
        guard readStateIfNeeded(), state.pause != pause else { return }
        state.pause = pause
        store.save(state)
    }

    /// Reads the state file again if it couldn't be read before. False while
    /// it still can't be.
    @discardableResult
    func readStateIfNeeded() -> Bool {
        guard stateUnread else { return true }
        guard let state = store.loadIfReadable() else { return false }
        self.state = state
        stateUnread = false
        return true
    }

    /// This phone's id and agreed key, for a live voice call's read of its
    /// own data. Nil until a sync has agreed a key that reads.
    func voiceReadKey() -> (deviceID: String, key: HealthSyncCrypto.SessionKey)? {
        guard readStateIfNeeded(), let key = keys.load(), key.readsByVoice else { return nil }
        return (state.deviceID, key)
    }

    /// Sharing turned off: forget the key, the anchors and the cursor, and
    /// optionally delete this phone's data on the host first. True when the
    /// host confirmed the deletion.
    func turnOff(deleteFromHost request: Request?) async -> Bool {
        turnOffs += 1
        // A pass still running could save a key after it was forgotten.
        if let running {
            running.cancel()
            _ = await running.value
            if self.running == running {
                self.running = nil
                runningPreferences = nil
                isSyncing = false
            }
        }
        await source.stopObserving()
        keys.clear()
        // Without the saved state this phone's ID is unknown: leave the file
        // and the host alone rather than wipe or save under a new one.
        guard readStateIfNeeded() else { return false }
        var deleted = false
        if let request {
            do {
                _ = try await request("\(Self.base)/wipe", "POST", ["device_id": state.deviceID])
                deleted = true
            } catch DashboardTicketBridgeError.http(let status, _) where status == 404 {
                // No health sync on this host any more: nothing left to delete.
                deleted = true
            } catch {
                lastError = Self.describe(error)
            }
        }
        state.startOver()
        store.save(state)
        return deleted
    }

    // MARK: The pass

    private func pass(preferences: HealthSyncPreferences, deadline: Date, options: HealthPassOptions,
                      request: @escaping Request) async -> Outcome {
        guard preferences.isOn, let destination = preferences.destination else { return .off }
        // Health is unreadable until the user unlocks the phone, this file too.
        guard readStateIfNeeded() else { return .unfinished }
        if state.destination != destination {
            // Health data never follows the user to another destination.
            keys.clear()
            state.startOver()
            state.destination = destination
        }
        state.lastAttempt = now()
        // Each outcome below sets its own pause; an old one would hide a new error.
        state.pause = nil
        lastError = nil
        defer { store.save(state) }
        let postedBefore = state.lastIngest
        do {
            let key = try await ensureKey(request: request)
            prepareHistory(preferences.history)
            var session = Session(engine: self, key: key, preferences: preferences, options: options, request: request,
                                  deadline: deadline)
            try await session.sendRecentDays()
            try await session.sendEvents()
            // Low Data Mode: older history waits for another network.
            if !options.lowData { try await session.sendHistory() }
            if state.lastIngest == postedBefore,
               ContextUploadPolicy.healthNeedsKeepalive(lastPosted: state.lastIngest, now: now()) {
                try await session.sendKeepalive()
            }
            state.lastSync = now()
            state.pause = nil
            lastError = nil
            return .synced
        } catch is CancellationError {
            return .unfinished
        } catch HealthDataSourceError.locked {
            // Health is unreadable until the user unlocks the phone.
            return .unfinished
        } catch is DeadlineReached {
            return .unfinished
        } catch let error as DashboardTicketBridgeError {
            switch error {
            case .signInRequired:
                state.pause = .signInRequired
                return .paused(.signInRequired)
            case .http(let status, _) where status == 404:
                state.pause = .pluginMissing
                return .paused(.pluginMissing)
            case .http(let status, let detail) where status == 409 && HostKeyConflict.isKeyLoss(detail):
                // The host lost or replaced this phone's key (a wipe, a
                // reinstall of the plugin's store): set it up again next pass.
                keys.clear()
                lastError = detail
                return .unfinished
            case .http(let status, let detail) where status == 400 || status == 409 || status == 413:
                // Any other 409 (too many devices, a store from a newer
                // plugin) isn't fixed by a new key: the key stays.
                state.pause = .refused(detail)
                return .paused(.refused(detail))
            default:
                lastError = Self.describe(error)
                return .failed(Self.describe(error))
            }
        } catch {
            lastError = Self.describe(error)
            return .failed(Self.describe(error))
        }
    }

    /// The agreed key, set up again whenever the host doesn't know it.
    private func ensureKey(request: Request) async throws -> HealthSyncCrypto.SessionKey {
        let status = try await request("\(Self.base)/status?device_id=\(state.deviceID)", "GET", nil)
        let generation = status["generation"] as? String
        let hostKid = (status["device"] as? [String: Any])?["kid"] as? String
        if let generation, let known = state.generation, known != generation {
            // A new store on the host: everything goes again.
            restart()
        }
        // A key agreed before voice reads existed is set up again, once:
        // the host then drops what it sent and this pass sends it all again.
        if let key = keys.load(), key.kid == hostKid, key.readsByVoice {
            state.generation = generation ?? state.generation
            return key
        }
        let devicePrivate = Curve25519.KeyAgreement.PrivateKey()
        let answer = try await request("\(Self.base)/key", "POST", [
            "device_id": state.deviceID,
            "device_name": deviceName(),
            "public_key": NotificationE2E.base64URL(devicePrivate.publicKey.rawRepresentation),
        ])
        guard let hostPublic = answer["host_public_key"] as? String, let kid = answer["kid"] as? String else {
            throw DashboardTicketBridgeError.requestFailed(AppLocalization.string("The host didn't return a health key."))
        }
        let key = try HealthSyncCrypto.agree(devicePrivate: devicePrivate, deviceID: state.deviceID, hostPublicKey: hostPublic, kid: kid)
        // Turned off while the host answered: keep nothing.
        try Task.checkCancellation()
        keys.save(key)
        // The host has nothing from this key yet.
        restart()
        state.generation = (answer["generation"] as? String) ?? generation
        return key
    }

    private func restart() {
        state.anchors = [:]
        state.recentWindows = nil
        state.recentWholeAt = nil
        state.backfillCursor = nil
        state.backfilledCategories = nil
        state.historyStart = nil
        state.history = nil
    }

    /// Fixes how far back sharing reaches. Another choice starts the
    /// anchors over (their query changes); a shallower one sends nothing
    /// older from then on, and what was already sent stays on the host
    /// until the user deletes it.
    private func prepareHistory(_ depth: HealthHistoryDepth) {
        let today = calendar.startOfDay(for: now())
        let start: Date = depth.days.map { calendar.date(byAdding: .day, value: -$0, to: today) ?? today }
            ?? calendar.startOfDay(for: source.earliestDate())
        if state.historyStart != nil, state.history == depth { return }
        if state.historyStart != nil { state.anchors = [:] }
        state.historyStart = start
        state.history = depth
    }

    fileprivate func acknowledged(_ update: (inout HealthSyncState) -> Void) {
        update(&state)
        store.save(state)
    }

    fileprivate func notePosted() {
        state.lastIngest = now()
    }

    fileprivate var currentNow: Date { now() }
    fileprivate var currentDeviceName: String { deviceName() }

    static func describe(_ error: Error) -> String {
        if let error = error as? DashboardTicketBridgeError, let description = error.errorDescription { return description }
        return error.localizedDescription
    }
}

/// Stops a pass when its time is up.
struct DeadlineReached: Error {}

/// One pass's sending, with the pieces it shares.
@MainActor
private struct Session {
    let engine: HealthSyncEngine
    let key: HealthSyncCrypto.SessionKey
    let preferences: HealthSyncPreferences
    let options: HealthPassOptions
    let request: HealthSyncEngine.Request
    let deadline: Date

    var calendar: Calendar { engine.calendar }
    var categories: Set<HealthCategory> { preferences.categories }

    init(engine: HealthSyncEngine, key: HealthSyncCrypto.SessionKey, preferences: HealthSyncPreferences,
         options: HealthPassOptions, request: @escaping HealthSyncEngine.Request, deadline: Date) {
        self.engine = engine
        self.key = key
        self.preferences = preferences
        self.options = options
        self.request = request
        self.deadline = deadline
    }

    func checkTime() throws {
        try Task.checkCancellation()
        if engine.currentNow >= deadline { throw DeadlineReached() }
    }

    func newBatch() -> HealthBatch {
        HealthBatch(computedAt: engine.currentNow, deviceName: engine.currentDeviceName, timeZone: calendar.timeZone,
                    categories: HealthCategory.allCases.filter(categories.contains),
                    detailed: HealthCategory.allCases.filter { preferences.detailed.contains($0) && categories.contains($0) })
    }

    /// Sends `batch` in parts. Returns the windows (HealthBatch.windowPrints
    /// keys) in parts where the host kept a newer computation of some
    /// window over this one (`stale_windows`): those aren't the host's yet.
    @discardableResult
    func send(_ batch: HealthBatch) async throws -> Set<String> {
        var notTaken: Set<String> = []
        for part in batch.split() {
            let answer = try await post(part)
            if ((answer["stale_windows"] as? NSNumber)?.intValue ?? 0) > 0 {
                notTaken.formUnion(part.windowPrints().map(\.key))
            }
        }
        return notTaken
    }

    private func post(_ part: HealthBatch) async throws -> [String: Any] {
        try checkTime()
        let plaintext = try JSONSerialization.data(withJSONObject: part.json(), options: [.sortedKeys])
        let body = try HealthSyncCrypto.envelope(plaintext: plaintext, key: key, deviceID: engine.state.deviceID,
                                                 batchID: part.batchID)
        let answer = try await request("\(HealthSyncEngine.base)/ingest", "POST", body)
        engine.notePosted()
        return answer
    }

    /// An upload with nothing in it, so the host knows this phone is still
    /// sharing and has nothing new (split() drops an empty batch).
    func sendKeepalive() async throws {
        _ = try await post(newBatch())
    }

    /// Buckets and nights for [from, to), as windows the host replaces.
    func windows(from: Date, to: Date) async throws -> [HealthWindow] {
        var windows: [HealthWindow] = []
        let today = calendar.startOfDay(for: engine.currentNow)
        let hourlyFloor = calendar.date(byAdding: .day, value: -HealthSyncLimits.hourlyHistoryDays, to: today) ?? today
        for category in HealthCategory.allCases where categories.contains(category) {
            for metric in category.metrics {
                try checkTime()
                let daily = try await engine.source.buckets(metric, grain: .day, from: from, to: to, calendar: calendar)
                windows.append(HealthWindow(metric: metric.rawValue, grain: .day, unit: metric.unit,
                                            from: from, to: to, buckets: daily))
                if metric.hasHourlyBuckets, to > hourlyFloor {
                    let start = max(from, hourlyFloor)
                    let hourly = try await engine.source.buckets(metric, grain: .hour, from: start, to: to, calendar: calendar)
                    windows.append(HealthWindow(metric: metric.rawValue, grain: .hour, unit: metric.unit,
                                                from: start, to: to, buckets: hourly))
                }
            }
        }
        if categories.contains(.sleep) {
            try checkTime()
            let range = HealthSleepNights.window(mornings: from, until: to, calendar: calendar)
            let segments = try await engine.source.sleepSegments(from: range.from, to: range.to)
            windows.append(HealthWindow(metric: "sleep", grain: .night, unit: "min", from: range.from, to: range.to,
                                        buckets: HealthSleepNights.summaries(segments, calendar: calendar)))
        }
        return windows
    }

    /// Today and the days before it that the Watch may still fill in: the
    /// windows that changed since the host took them, or all of them every
    /// few hours. A sample added, edited or deleted in these days changes
    /// its window, so it still goes.
    mutating func sendRecentDays() async throws {
        let now = engine.currentNow
        let today = calendar.startOfDay(for: now)
        let from = calendar.date(byAdding: .day, value: -(HealthSyncLimits.recomputedDays - 1), to: today) ?? today
        let to = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        var batch = newBatch()
        batch.windows = try await windows(from: from, to: to)
        let prints = batch.windowPrints()
        let whole = ContextUploadPolicy.healthResendsRecent(options, lastWhole: engine.state.recentWholeAt, now: now)
        if !whole {
            let sent = engine.state.recentWindows ?? [:]
            batch.windows = zip(batch.windows, prints).filter { sent[$1.key] != $1.hash }.map(\.0)
        }
        let notTaken = try await send(batch)
        engine.acknowledged { state in
            let taken = prints.filter { !notTaken.contains($0.key) }
            state.recentWindows = Dictionary(taken.map { ($0.key, $0.hash) }, uniquingKeysWith: { _, last in last })
            if whole { state.recentWholeAt = now }
            if state.backfillCursor == nil { state.backfillCursor = from }
        }
    }

    /// New and deleted workouts, sleep stages and (where the user chose
    /// detailed readings) raw readings, each stream from its own anchor.
    mutating func sendEvents() async throws {
        guard let since = engine.state.historyStart else { return }
        var streams: [HealthEventStream] = []
        if categories.contains(.workouts) { streams.append(.workouts) }
        if categories.contains(.sleep) { streams.append(.sleep) }
        for category in HealthCategory.allCases where categories.contains(category) && preferences.detailed.contains(category) {
            streams.append(contentsOf: category.metrics.map(HealthEventStream.samples))
        }
        for stream in streams {
            var more = true
            while more {
                try checkTime()
                let page = try await engine.source.changes(stream, since: since, anchor: engine.state.anchors[stream.key],
                                                           limit: HealthSyncLimits.samplesPerQuery)
                var batch = newBatch()
                batch.events = page.added
                batch.deleted = page.deleted
                if !batch.isEmpty { try await send(batch) }
                engine.acknowledged { $0.anchors[stream.key] = page.anchor }
                more = page.more
            }
        }
    }

    /// One step further back per loop, newest first, until history is in.
    mutating func sendHistory() async throws {
        guard let target = engine.state.historyStart else { return }
        // A category turned on after some history went still needs its
        // older days: walk the range again for the new set. The host
        // replaces windows, so re-sending what it has is harmless. The
        // cursor goes back to the days the recent-days pass keeps fresh
        // (HealthSyncLimits.recomputedDays); nothing older is covered
        // anywhere else.
        if categories != engine.state.backfilledCategories {
            let missing = categories.subtracting(engine.state.backfilledCategories ?? [])
            let today = calendar.startOfDay(for: engine.currentNow)
            let from = calendar.date(byAdding: .day, value: -(HealthSyncLimits.recomputedDays - 1), to: today) ?? today
            engine.acknowledged { state in
                state.backfilledCategories = categories
                if !missing.isEmpty { state.backfillCursor = from }
            }
        }
        while let cursor = engine.state.backfillCursor, cursor > target {
            try checkTime()
            let start = max(target, calendar.date(byAdding: .day, value: -HealthSyncLimits.backfillChunkDays, to: cursor) ?? target)
            var batch = newBatch()
            batch.windows = try await windows(from: start, to: cursor)
            try await send(batch)
            engine.acknowledged { $0.backfillCursor = start }
        }
    }
}
