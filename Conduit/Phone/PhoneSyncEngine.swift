//
//  PhoneSyncEngine.swift
//  Conduit
//
//  One pass: make sure this phone and the Hermes profile share a key, send
//  what changed in the calendar, reminders, Focus and phone status since the
//  last pass, then trade results for the changes Hermes is waiting on.
//
//  EventKit has no change history, so the phone remembers a hash of each
//  item it last sent and uploads only the difference; everything goes whole
//  again once a day, when the user changes what's shared, or when the host's
//  store is new. Hashes move only after the host took the batch, so a lost
//  answer just means the next pass sends it again (the host's writes are
//  idempotent). Changes Hermes asks for come back from the exchange: new
//  items apply straight away when the user chose "Add without asking",
//  everything else waits for the user's answer on a card (or, in a live
//  voice call, out loud).
//

import CryptoKit
import Foundation

/// What a pass remembers between runs: hashes, never calendar content.
struct PhoneSyncState: Codable, Equatable {
    var deviceID: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    var destination: PhoneSyncDestination?
    var generation: String?
    var fingerprint: String?
    var eventHashes: [String: String] = [:]
    var reminderHashes: [String: String] = [:]
    var calendarsHash: String?
    var statusHash: String?
    var statusSentAt: Date?
    var focusHash: String?
    var lastFullSync: Date?
    var lastSync: Date?
    var lastAttempt: Date?
    var pause: PhoneSyncPause?
    /// Outcomes not yet reported to the host.
    var unreported: [PhoneChangeResult] = []
    /// Changes already answered here, so a lost report never applies one twice.
    var answered: [String: PhoneChangeResult] = [:]

    mutating func startOver(keepingDevice: Bool = true) {
        let device = deviceID
        self = PhoneSyncState()
        if keepingDevice { deviceID = device }
    }

    mutating func forgetSent() {
        eventHashes = [:]
        reminderHashes = [:]
        calendarsHash = nil
        statusHash = nil
        statusSentAt = nil
        focusHash = nil
        lastFullSync = nil
        fingerprint = nil
    }
}

struct PhoneSyncStateStore {
    var url: URL

    static var standard: PhoneSyncStateStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return PhoneSyncStateStore(url: base.appendingPathComponent("PhoneSync", isDirectory: true)
            .appendingPathComponent("state.json"))
    }

    /// Nil when the file is there but can't be read yet (not unlocked since restart).
    func loadIfReadable() -> PhoneSyncState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return PhoneSyncState() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let state = try? JSONDecoder().decode(PhoneSyncState.self, from: data) { return state }
        var fresh = PhoneSyncState()
        if let known = try? JSONDecoder().decode(DeviceOnly.self, from: data) { fresh.deviceID = known.deviceID }
        return fresh
    }

    private struct DeviceOnly: Decodable { var deviceID: String }

    @discardableResult
    func save(_ state: PhoneSyncState) -> Bool {
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

struct PhoneSyncKeyStore {
    var load: () -> PhoneSyncCrypto.SessionKey?
    var save: (PhoneSyncCrypto.SessionKey) -> Void
    var clear: () -> Void

    static let keychain = PhoneSyncKeyStore(
        load: {
            KeychainHelper.loadPhoneSyncKey().flatMap { try? JSONDecoder().decode(PhoneSyncCrypto.SessionKey.self, from: $0) }
        },
        save: { key in
            if let data = try? JSONEncoder().encode(key) { KeychainHelper.savePhoneSyncKey(data) }
        },
        clear: { KeychainHelper.clearPhoneSyncKey() }
    )
}

/// A change waiting for the user, with what the card shows.
struct PhoneChangePrompt: Identifiable, Equatable {
    var change: PhoneChange
    /// The calendar or list it goes to, by name.
    var calendarTitle: String?
    var id: String { change.id }
}

/// An addition made without asking, for the banner's Undo.
struct PhoneAutoAdded: Identifiable, Equatable {
    var id: String { changeID }
    var changeID: String
    var itemID: String
    var title: String
    var calendarTitle: String?
    var isEvent: Bool
}

@MainActor
final class PhoneSyncEngine: ObservableObject {
    typealias Request = (_ path: String, _ method: String, _ body: [String: Any]?) async throws -> [String: Any]

    enum Outcome: Equatable {
        case synced
        case unfinished
        case paused(PhoneSyncPause)
        case off
        case failed(String)
    }

    static let base = "/api/plugins/conduit_push/phone"

    @Published private(set) var state: PhoneSyncState
    @Published private(set) var isSyncing = false
    @Published private(set) var lastError: String?
    @Published private(set) var preferences: PhoneSyncPreferences
    /// Changes waiting for the user's answer, oldest first.
    @Published private(set) var prompts: [PhoneChangePrompt] = []
    /// The latest addition made without asking, until the banner goes.
    @Published var autoAdded: PhoneAutoAdded?

    let calendarSource: PhoneCalendarSource
    let statusSource: PhoneStatusSource
    private let store: PhoneSyncStateStore
    private let keys: PhoneSyncKeyStore
    private let defaults: UserDefaults
    private let now: () -> Date
    private let deviceName: () -> String
    var calendar: Calendar
    private var running: Task<Outcome, Never>?
    private var turnOffs = 0
    private var stateUnread = false

    init(
        calendarSource: PhoneCalendarSource,
        statusSource: PhoneStatusSource,
        store: PhoneSyncStateStore = .standard,
        keys: PhoneSyncKeyStore = .keychain,
        defaults: UserDefaults = .standard,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init,
        deviceName: @escaping () -> String = { "iPhone" }
    ) {
        self.calendarSource = calendarSource
        self.statusSource = statusSource
        self.store = store
        self.keys = keys
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
        self.deviceName = deviceName
        preferences = PhoneSyncPreferences.load(from: defaults)
        if let state = store.loadIfReadable() {
            self.state = state
        } else {
            self.state = PhoneSyncState()
            stateUnread = true
        }
    }

    func savePreferences(_ preferences: PhoneSyncPreferences) {
        preferences.save(to: defaults)
        self.preferences = preferences
    }

    /// Runs a pass, or joins the one already running and runs once more
    /// after it, so what changed meanwhile isn't missed.
    func sync(deadline: Date, request: @escaping Request) async -> Outcome {
        let turnOffs = self.turnOffs
        if let current = running {
            _ = await current.value
            guard self.turnOffs == turnOffs else { return .off }
            if running == current { running = nil }
            if let newer = running { return await newer.value }
        }
        let task = Task { await self.pass(deadline: deadline, request: request) }
        running = task
        isSyncing = true
        let outcome = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if running == task {
            running = nil
            isSyncing = false
        }
        return outcome
    }

    func note(_ pause: PhoneSyncPause?) {
        guard readStateIfNeeded(), state.pause != pause else { return }
        state.pause = pause
        store.save(state)
    }

    @discardableResult
    func readStateIfNeeded() -> Bool {
        guard stateUnread else { return true }
        guard let state = store.loadIfReadable() else { return false }
        self.state = state
        stateUnread = false
        return true
    }

    /// Sharing turned off: forget the key and hashes, and optionally delete
    /// this phone's data on the host first. True when the host confirmed it.
    func turnOff(deleteFromHost request: Request?) async -> Bool {
        turnOffs += 1
        if let running {
            running.cancel()
            _ = await running.value
            if self.running == running {
                self.running = nil
                isSyncing = false
            }
        }
        prompts = []
        autoAdded = nil
        keys.clear()
        guard readStateIfNeeded() else { return false }
        var deleted = false
        if let request {
            do {
                _ = try await request("\(Self.base)/wipe", "POST", ["device_id": state.deviceID])
                deleted = true
            } catch DashboardTicketBridgeError.http(let status, _) where status == 404 {
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

    private func pass(deadline: Date, request: @escaping Request) async -> Outcome {
        let preferences = self.preferences
        guard preferences.isOn, let destination = preferences.destination else { return .off }
        guard readStateIfNeeded() else { return .unfinished }
        if state.destination != destination {
            keys.clear()
            state.startOver()
            state.destination = destination
        }
        state.lastAttempt = now()
        state.pause = nil
        lastError = nil
        defer { store.save(state) }
        do {
            let key = try await ensureKey(request: request)
            try checkTime(deadline)
            let pending = try await upload(preferences: preferences, key: key, request: request)
            try checkTime(deadline)
            if pending > 0 || !state.unreported.isEmpty || !prompts.isEmpty {
                try await exchange(key: key, request: request)
            }
            state.lastSync = now()
            return .synced
        } catch is CancellationError {
            return .unfinished
        } catch is DeadlineReached {
            // Out of the time iOS gave: the next pass carries on.
            return .unfinished
        } catch let error as DashboardTicketBridgeError {
            switch error {
            case .signInRequired:
                state.pause = .signInRequired
                return .paused(.signInRequired)
            case .http(let status, _) where status == 404:
                state.pause = .pluginMissing
                return .paused(.pluginMissing)
            case .http(let status, let detail) where status == 409:
                // The host lost or replaced this phone's key: set it up again.
                keys.clear()
                state.forgetSent()
                lastError = detail
                return .unfinished
            case .http(let status, let detail) where status == 400 || status == 413:
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

    private func checkTime(_ deadline: Date) throws {
        try Task.checkCancellation()
        if now() >= deadline { throw DeadlineReached() }
    }

    private func ensureKey(request: Request) async throws -> PhoneSyncCrypto.SessionKey {
        let status = try await request("\(Self.base)/status?device_id=\(state.deviceID)", "GET", nil)
        let generation = status["generation"] as? String
        let hostKid = (status["device"] as? [String: Any])?["kid"] as? String
        if let generation, let known = state.generation, known != generation {
            state.forgetSent()
        }
        if let key = keys.load(), key.kid == hostKid {
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
            throw DashboardTicketBridgeError.requestFailed(AppLocalization.string("The host didn't return a key."))
        }
        let key = try PhoneSyncCrypto.agree(devicePrivate: devicePrivate, deviceID: state.deviceID, hostPublicKey: hostPublic, kid: kid)
        try Task.checkCancellation()
        keys.save(key)
        state.forgetSent()
        state.generation = (answer["generation"] as? String) ?? generation
        return key
    }

    /// The calendar window this pass shares.
    var window: (from: Date, to: Date) {
        let today = calendar.startOfDay(for: now())
        let from = calendar.date(byAdding: .day, value: -PhoneCalendarWindow.pastDays, to: today) ?? today
        let to = calendar.date(byAdding: .day, value: preferences.window.rawValue + 1, to: today) ?? today
        return (from, to)
    }

    /// Sends what changed; the number of changes the host has waiting.
    private func upload(preferences: PhoneSyncPreferences, key: PhoneSyncCrypto.SessionKey, request: Request) async throws -> Int {
        let currentNow = now()
        let full = state.fingerprint != preferences.fingerprint
            || state.lastFullSync.map { currentNow.timeIntervalSince($0) > PhoneSyncLimits.fullSyncInterval } ?? true
        let window = self.window
        var batch: [String: Any] = [
            "sent_at": PhoneDates.format(currentNow),
            "time_zone": TimeZone.current.identifier,
            "sharing": preferences.sharingJSON,
        ]
        var newEventHashes = state.eventHashes
        var newReminderHashes = state.reminderHashes
        var newCalendarsHash = state.calendarsHash
        var newStatusHash = state.statusHash
        var newFocusHash = state.focusHash
        var statusSent = false

        let readsEvents = preferences.calendar == .full && calendarSource.eventAccess == .full
        let readsReminders = preferences.reminders && calendarSource.remindersAuthorized
        let calendars = calendarSource.calendars(eventsReadable: readsEvents, reminders: readsReminders)
            .filter { entry in
                // Hidden calendars are left out by EventKit id; the list has hashed ids.
                !preferences.hiddenCalendars.contains { EventKitPhoneSource.hashed("c_", $0) == entry["id"] as? String }
            }
        let calendarsHash = Self.hash(calendars)
        if full || calendarsHash != state.calendarsHash {
            batch["calendars"] = calendars
            newCalendarsHash = calendarsHash
        }

        if readsEvents {
            let events = await calendarSource.events(from: window.from, to: window.to, hidden: preferences.hiddenCalendars,
                                                     details: preferences.details,
                                                     emails: preferences.details && preferences.attendeeEmails,
                                                     limit: PhoneSyncLimits.maxEvents)
            let section = await Self.diffInBackground(events, against: state.eventHashes, full: full,
                                                      truncated: events.count >= PhoneSyncLimits.maxEvents)
            if full || !section.upsert.isEmpty || !section.delete.isEmpty {
                let events: [String: Any] = [
                    "full": full, "from": PhoneDates.format(window.from), "to": PhoneDates.format(window.to),
                    "upsert": section.upsert, "delete": section.delete,
                ]
                batch["events"] = events
            }
            newEventHashes = section.hashes
        } else {
            newEventHashes = [:]
        }

        if readsReminders {
            let since = calendar.date(byAdding: .day, value: -PhoneSyncLimits.completedReminderDays, to: currentNow) ?? currentNow
            let reminders = await calendarSource.reminders(hidden: preferences.hiddenCalendars, details: preferences.details,
                                                           completedSince: since, limit: PhoneSyncLimits.maxReminders)
            let section = await Self.diffInBackground(reminders, against: state.reminderHashes, full: full,
                                                      truncated: reminders.count >= PhoneSyncLimits.maxReminders)
            if full || !section.upsert.isEmpty || !section.delete.isEmpty {
                let reminders: [String: Any] = ["full": full, "upsert": section.upsert, "delete": section.delete]
                batch["reminders"] = reminders
            }
            newReminderHashes = section.hashes
        } else {
            newReminderHashes = [:]
        }

        if preferences.status {
            var status = await statusSource.snapshot()
            let comparable = status.filter { $0.key != "at" }
            let hash = Self.hash(comparable)
            let stale = state.statusSentAt.map { currentNow.timeIntervalSince($0) > PhoneSyncLimits.statusRefresh } ?? true
            if full || hash != state.statusHash || stale {
                status["at"] = PhoneDates.format(currentNow)
                batch["status"] = status
                newStatusHash = hash
                statusSent = true
            }
        }
        if preferences.focus, let focus = PhoneFocusSnapshot.load(from: defaults) {
            let hash = Self.hash(focus.json)
            if full || hash != state.focusHash {
                batch["focus"] = focus.json
                newFocusHash = hash
            }
        }

        let batchID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        batch["batch_id"] = batchID
        let plaintext = try JSONSerialization.data(withJSONObject: batch, options: [.sortedKeys])
        let body = try PhoneSyncCrypto.envelope(plaintext: plaintext, key: key, deviceID: state.deviceID, batchID: batchID)
        let answer = try await request("\(Self.base)/ingest", "POST", body)
        // Taken: what was sent is now what the host has.
        state.eventHashes = newEventHashes
        state.reminderHashes = newReminderHashes
        state.calendarsHash = newCalendarsHash
        state.statusHash = newStatusHash
        state.focusHash = newFocusHash
        if statusSent { state.statusSentAt = currentNow }
        state.fingerprint = preferences.fingerprint
        if full { state.lastFullSync = currentNow }
        store.save(state)
        return (answer["pending"] as? NSNumber)?.intValue ?? 0
    }

    struct Section {
        var upsert: [[String: Any]]
        var delete: [String]
        var hashes: [String: String]
    }

    /// What to send of `items` given the hashes last sent: everything when
    /// `full`, otherwise new and changed items and the ids that went away.
    /// When the list was cut at its limit, an item missing from it may only
    /// have fallen past the cut, so nothing is reported deleted.
    nonisolated static func diff(_ items: [[String: Any]], against sent: [String: String], full: Bool,
                                 truncated: Bool = false) -> Section {
        var hashes: [String: String] = [:]
        var upsert: [[String: Any]] = []
        for item in items {
            guard let id = item["id"] as? String else { continue }
            let hash = Self.hash(item)
            hashes[id] = hash
            if full || sent[id] != hash { upsert.append(item) }
        }
        guard !full, !truncated else { return Section(upsert: upsert, delete: [], hashes: hashes) }
        let delete = sent.keys.filter { hashes[$0] == nil }.sorted()
        return Section(upsert: upsert, delete: delete, hashes: hashes)
    }

    /// Hashing thousands of items is kept off the main thread.
    nonisolated private static func diffInBackground(_ items: [[String: Any]], against sent: [String: String],
                                                     full: Bool, truncated: Bool) async -> Section {
        diff(items, against: sent, full: full, truncated: truncated)
    }

    nonisolated static func hash(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Changes from Hermes

    /// Reports outcomes and takes the changes still waiting.
    private func exchange(key: PhoneSyncCrypto.SessionKey, request: Request) async throws {
        let callID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let reporting = state.unreported
        let request: [String: Any] = ["call_id": callID, "results": reporting.map(\.json)]
        let plaintext = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let body = try PhoneSyncCrypto.exchangeEnvelope(plaintext: plaintext, op: "changes", key: key,
                                                        deviceID: state.deviceID, callID: callID)
        let answer = try await request("\(Self.base)/exchange", "POST", body)
        let opened = try PhoneSyncCrypto.openAnswer(answer, op: "changes", key: key, deviceID: state.deviceID, callID: callID)
        guard let json = try JSONSerialization.jsonObject(with: opened) as? [String: Any],
              json["call_id"] as? String == callID else {
            throw PhoneSyncCrypto.Failure.malformedAnswer
        }
        // Reported: drop them, keeping anything answered meanwhile.
        state.unreported.removeAll { reported in reporting.contains(reported) }
        let changes = (json["changes"] as? [[String: Any]] ?? []).compactMap(PhoneChange.init(json:))
        let waiting = Set(changes.map(\.id))
        // Answers the host no longer asks about are settled.
        state.answered = state.answered.filter { waiting.contains($0.key) || state.unreported.contains($0.value) }
        var fresh: [PhoneChangePrompt] = []
        for change in changes {
            if let known = state.answered[change.id] {
                // Answered, but the report was lost: say it again.
                if !state.unreported.contains(known) { state.unreported.append(known) }
                continue
            }
            if change.auto, change.kind.isAddition, preferences.autoAdd {
                await applyNow(change, auto: true)
            } else {
                fresh.append(PhoneChangePrompt(change: change,
                                               calendarTitle: calendarSource.calendarTitle(id: change.fields.calendarID ?? change.fields.listID,
                                                                                            forEvents: change.kind.isEvent)))
            }
        }
        prompts = fresh
        store.save(state)
    }

    /// The user's answer to a card (or to the question in a voice call).
    func answer(_ prompt: PhoneChangePrompt, approve: Bool) async {
        prompts.removeAll { $0.id == prompt.id }
        if approve {
            await applyNow(prompt.change, auto: false)
        } else {
            record(PhoneChangeResult(id: prompt.id, outcome: .dismissed))
        }
    }

    private func applyNow(_ change: PhoneChange, auto: Bool) async {
        do {
            let itemID = try await calendarSource.apply(change, window: window)
            record(PhoneChangeResult(id: change.id, outcome: .applied, itemID: itemID))
            if auto, let itemID {
                autoAdded = PhoneAutoAdded(changeID: change.id, itemID: itemID, title: change.fields.title ?? "",
                                           calendarTitle: calendarSource.calendarTitle(id: change.fields.calendarID ?? change.fields.listID,
                                                                                       forEvents: change.kind.isEvent),
                                           isEvent: change.kind.isEvent)
            }
        } catch {
            record(PhoneChangeResult(id: change.id, outcome: .failed, note: Self.describe(error)))
            if !auto { lastError = Self.describe(error) }
        }
    }

    private func record(_ result: PhoneChangeResult) {
        state.answered[result.id] = result
        state.unreported.append(result)
        store.save(state)
    }

    /// The banner's Undo: takes back an addition made without asking.
    func undo(_ added: PhoneAutoAdded) async {
        if autoAdded == added { autoAdded = nil }
        do {
            try await calendarSource.removeAdded(itemID: added.itemID, isEvent: added.isEvent, window: window)
        } catch {
            lastError = Self.describe(error)
        }
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? DashboardTicketBridgeError, let description = error.errorDescription { return description }
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        return error.localizedDescription
    }
}
