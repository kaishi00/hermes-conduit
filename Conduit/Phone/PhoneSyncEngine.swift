//
//  PhoneSyncEngine.swift
//  Conduit
//
//  One pass: make sure this phone and the Hermes profile share a key, send
//  what changed in the calendar, reminders, Focus and phone status since the
//  last pass, then trade results for the changes Hermes is waiting on.
//
//  EventKit has no change history, so the phone remembers a hash of each
//  item it last sent and uploads only the difference, and nothing at all
//  when nothing changed (the host's status says what's waiting; a keepalive
//  still goes every few hours); everything goes whole again once a day,
//  when the user changes what's shared, or when the host's store is new.
//  Hashes move only after the host took the batch, so a lost answer just
//  means the next pass sends it again (the host's writes are idempotent).
//  Changes Hermes asks for come back from the exchange: new items apply
//  straight away when the user chose "Add without asking", everything else
//  waits for the user's answer on a card (or, in a live voice call, out
//  loud).
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
    var alarmsHash: String?
    var contactsHash: String?
    var lastFullSync: Date?
    /// The time zone and sharing the last upload the host took reported,
    /// hashed, and when it went: a pass with nothing new sends nothing
    /// until the keepalive (ContextUploadPolicy). Optional so a state file
    /// from before still reads.
    var frameHash: String?
    var lastIngest: Date?
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
        alarmsHash = nil
        contactsHash = nil
        lastFullSync = nil
        fingerprint = nil
        frameHash = nil
        lastIngest = nil
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

/// One serial queue for the state file, so writes stay off the main thread
/// and land in the order they were made.
final class PhoneSyncStateWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.milim.relay.phone-sync.state", qos: .utility)

    func save(_ state: PhoneSyncState, to store: PhoneSyncStateStore, failed: @escaping @MainActor () -> Void) {
        queue.async {
            guard !store.save(state) else { return }
            Task { @MainActor in failed() }
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
    /// The alarm a cancellation is about, by name and time.
    var alarmTitle: String?
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
    /// An alarm or timer: Undo cancels it.
    var isAlarm = false
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
    /// The people the user picked for Hermes.
    @Published private(set) var people: [PhonePerson]

    let calendarSource: PhoneCalendarSource
    let statusSource: PhoneStatusSource
    let alarmSource: PhoneAlarmSource
    private let store: PhoneSyncStateStore
    private let keys: PhoneSyncKeyStore
    private let defaults: UserDefaults
    private let now: () -> Date
    private let deviceName: () -> String
    var calendar: Calendar
    private var running: Task<Outcome, Never>?
    private var turnOffs = 0
    private var stateUnread = false
    /// What the state file holds (or is about to): a pass that changed
    /// nothing writes nothing.
    private var saved: PhoneSyncState?
    private let writer = PhoneSyncStateWriter()
    /// Changes being applied right now, so an exchange that lands meanwhile
    /// doesn't hand the same one out again. In memory: it covers races in
    /// one run of the app.
    private var applying: Set<String> = []

    init(
        calendarSource: PhoneCalendarSource,
        statusSource: PhoneStatusSource,
        alarmSource: PhoneAlarmSource = PhoneAlarmSources.system(),
        store: PhoneSyncStateStore = .standard,
        keys: PhoneSyncKeyStore = .keychain,
        defaults: UserDefaults = .standard,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init,
        deviceName: @escaping () -> String = { "iPhone" }
    ) {
        self.calendarSource = calendarSource
        self.statusSource = statusSource
        self.alarmSource = alarmSource
        self.store = store
        self.keys = keys
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
        self.deviceName = deviceName
        preferences = PhoneSyncPreferences.load(from: defaults)
        people = PhonePeopleStore.load(from: defaults)
        if let state = store.loadIfReadable() {
            self.state = state
            saved = state
        } else {
            self.state = PhoneSyncState()
            stateUnread = true
        }
    }

    func savePreferences(_ preferences: PhoneSyncPreferences) {
        preferences.save(to: defaults)
        self.preferences = preferences
    }

    func savePeople(_ people: [PhonePerson]) {
        let kept = Array(people.prefix(PhonePerson.maximum))
        PhonePeopleStore.save(kept, to: defaults)
        self.people = kept
    }

    /// Runs a pass, or joins the one already running and runs once more
    /// after it, so what changed meanwhile isn't missed.
    /// `keepalive`: how old the last upload may be before one goes with
    /// nothing new (ContextUploadPolicy.phoneKeepalive(for:)).
    func sync(deadline: Date, keepalive: TimeInterval = ContextUploadPolicy.phoneKeepalive,
              request: @escaping Request) async -> Outcome {
        let turnOffs = self.turnOffs
        if let current = running {
            _ = await current.value
            guard self.turnOffs == turnOffs else { return .off }
            if running == current { running = nil }
            if let newer = running { return await newer.value }
        }
        let task = Task { await self.pass(deadline: deadline, keepalive: keepalive, request: request) }
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
        persist()
    }

    /// Encodes and writes the state off the main thread, in order.
    private func persist() {
        guard state != saved else { return }
        saved = state
        let written = state
        writer.save(state, to: store) { [weak self] in
            // Not on disk (still locked, or full): the next change writes again.
            if self?.saved == written { self?.saved = nil }
        }
    }

    @discardableResult
    func readStateIfNeeded() -> Bool {
        guard stateUnread else { return true }
        guard let state = store.loadIfReadable() else { return false }
        self.state = state
        saved = state
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
        persist()
        return deleted
    }

    // MARK: The pass

    private func pass(deadline: Date, keepalive: TimeInterval, request: @escaping Request) async -> Outcome {
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
        defer { persist() }
        do {
            let (key, hostPending) = try await ensureKey(request: request)
            try checkTime(deadline)
            let pending = try await upload(preferences: preferences, key: key, hostPending: hostPending,
                                           keepalive: keepalive, request: request)
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
            case .http(let status, let detail) where status == 409 && HostKeyConflict.isKeyLoss(detail):
                // The host lost or replaced this phone's key: set it up again.
                keys.clear()
                state.forgetSent()
                lastError = detail
                return .unfinished
            case .http(let status, let detail) where status == 400 || status == 409 || status == 413:
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

    /// The agreed key, and the changes the host has waiting when its status
    /// says (nil from a plugin whose status doesn't, or with a new key).
    private func ensureKey(request: Request) async throws -> (PhoneSyncCrypto.SessionKey, Int?) {
        let status = try await request("\(Self.base)/status?device_id=\(state.deviceID)", "GET", nil)
        let generation = status["generation"] as? String
        let device = status["device"] as? [String: Any]
        let hostKid = device?["kid"] as? String
        if let generation, let known = state.generation, known != generation {
            state.forgetSent()
        }
        if let key = keys.load(), key.kid == hostKid {
            state.generation = generation ?? state.generation
            return (key, (device?["pending"] as? NSNumber)?.intValue)
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
        return (key, nil)
    }

    /// The calendar window this pass shares.
    var window: (from: Date, to: Date) {
        let today = calendar.startOfDay(for: now())
        let from = calendar.date(byAdding: .day, value: -PhoneCalendarWindow.pastDays, to: today) ?? today
        let to = calendar.date(byAdding: .day, value: preferences.window.rawValue + 1, to: today) ?? today
        return (from, to)
    }

    /// Sends what changed; the number of changes the host has waiting.
    /// Nothing changed: nothing goes (until the keepalive), and the count
    /// is the one the host's status gave.
    private func upload(preferences: PhoneSyncPreferences, key: PhoneSyncCrypto.SessionKey, hostPending: Int?,
                        keepalive: TimeInterval, request: Request) async throws -> Int {
        let currentNow = now()
        let full = state.fingerprint != preferences.fingerprint
            || state.lastFullSync.map { currentNow.timeIntervalSince($0) > PhoneSyncLimits.fullSyncInterval } ?? true
        let window = self.window
        var batch: [String: Any] = [
            "sent_at": PhoneDates.format(currentNow),
            "time_zone": TimeZone.current.identifier,
            "sharing": Self.effectiveSharing(preferences, access: calendarSource.eventAccess,
                                             remindersAuthorized: calendarSource.remindersAuthorized,
                                             alarmsAuthorized: alarmSource.authorized),
        ]
        var newEventHashes = state.eventHashes
        var newReminderHashes = state.reminderHashes
        var newCalendarsHash = state.calendarsHash
        var newStatusHash = state.statusHash
        var newFocusHash = state.focusHash
        var newAlarmsHash = state.alarmsHash
        var newContactsHash = state.contactsHash
        var statusSent = false

        let readsEvents = preferences.calendar.reads && calendarSource.eventAccess == .full
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
            // The host drops every stored event when the batch's sharing
            // says write-only or off (notifier phone_store `_apply`).
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
            // Likewise reminders when they're no longer shared.
            newReminderHashes = [:]
        }

        if preferences.status {
            var status = await statusSource.snapshot()
            let hash = Self.hash(Self.comparableStatus(status))
            let stale = state.statusSentAt.map { currentNow.timeIntervalSince($0) > PhoneSyncLimits.statusRefresh } ?? true
            if full || hash != state.statusHash || stale {
                status["at"] = PhoneDates.format(currentNow)
                batch["status"] = status
                newStatusHash = hash
                statusSent = true
            }
        } else {
            // The host forgets it when it's off, so turning it back on sends it again.
            newStatusHash = nil
        }
        if preferences.focus, let focus = PhoneFocusSnapshot.load(from: defaults) {
            let hash = Self.hash(focus.json)
            if full || hash != state.focusHash {
                batch["focus"] = focus.json
                newFocusHash = hash
            }
        } else if !preferences.focus {
            newFocusHash = nil
        }
        // Alarms and people go whole whenever they change; the host forgets
        // them when they're no longer shared.
        if preferences.alarms, alarmSource.authorized {
            // An unreadable AlarmKit keeps what the host has until the next pass.
            let alarms = alarmSource.alarms(now: currentNow, calendar: calendar)
            let hash = alarms.map { Self.hash($0) } ?? state.alarmsHash
            if let alarms, full || hash != state.alarmsHash {
                batch["alarms"] = alarms
                newAlarmsHash = hash
            }
        } else {
            newAlarmsHash = nil
        }
        if preferences.contacts {
            let contacts = people.map(\.json)
            let hash = Self.hash(contacts)
            if full || hash != state.contactsHash {
                batch["contacts"] = contacts
                newContactsHash = hash
            }
        } else {
            newContactsHash = nil
        }

        let frame = Self.hash(Self.frame(of: batch))
        let send = ContextUploadPolicy.phoneIngestNeeded(
            carriesNews: Self.carriesNews(batch), frame: frame, lastFrame: state.frameHash,
            lastPosted: state.lastIngest, hostReportsPending: hostPending != nil, keepalive: keepalive, now: currentNow)
        var pending = hostPending ?? 0
        if send {
            // A large upload goes in parts the host takes. Nothing below
            // counts as sent until it took the last one, so a refused part
            // sends the whole pass again (a full one starting over).
            let parts = await Self.partsInBackground(batch, maxItems: PhoneSyncLimits.batchItems,
                                                     maxBytes: PhoneSyncLimits.batchBytes)
            for var part in parts {
                let batchID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                part["batch_id"] = batchID
                let body = try await Self.sealBatch(part, key: key, deviceID: state.deviceID, batchID: batchID)
                let answer = try await request("\(Self.base)/ingest", "POST", body)
                pending = (answer["pending"] as? NSNumber)?.intValue ?? 0
            }
            state.frameHash = frame
            state.lastIngest = currentNow
        }
        // Taken (or nothing to take): what was read is now what the host has.
        state.eventHashes = newEventHashes
        state.reminderHashes = newReminderHashes
        state.calendarsHash = newCalendarsHash
        state.statusHash = newStatusHash
        state.focusHash = newFocusHash
        state.alarmsHash = newAlarmsHash
        state.contactsHash = newContactsHash
        if statusSent { state.statusSentAt = currentNow }
        state.fingerprint = preferences.fingerprint
        if full { state.lastFullSync = currentNow }
        persist()
        return pending
    }

    /// The status as far as sending it again goes: its time is left out,
    /// and the battery counts in 5% steps above 20% (the 15-minute refresh
    /// still brings the exact level), so a phone in use doesn't upload
    /// with every percent it loses.
    nonisolated static func comparableStatus(_ status: [String: Any]) -> [String: Any] {
        var comparable = status.filter { $0.key != "at" }
        if let battery = (comparable["battery"] as? NSNumber)?.doubleValue, battery > 0.2 {
            comparable["battery"] = (battery * 20).rounded(.down) / 20
        }
        return comparable
    }

    /// What every upload carries besides its sections. Any other key counts
    /// as news, so a section added later always goes (fails safe).
    nonisolated static let frameKeys: Set<String> = ["sent_at", "time_zone", "sharing", "batch_id"]

    /// The time zone and sharing an upload reports; `sent_at` changes every
    /// time and says nothing new.
    nonisolated static func frame(of batch: [String: Any]) -> [String: Any] {
        batch.filter { $0.key == "time_zone" || $0.key == "sharing" }
    }

    /// Whether an upload has a section to send.
    nonisolated static func carriesNews(_ batch: [String: Any]) -> Bool {
        batch.keys.contains { !frameKeys.contains($0) }
    }

    /// The sharing as it really is: access taken away in the Settings app
    /// narrows it, so the host drops what it can no longer have. Attendee
    /// emails go with full calendar access; "details" with full access or
    /// reminders (it also covers reminder notes).
    nonisolated static func effectiveSharing(_ preferences: PhoneSyncPreferences, access: PhoneCalendarAccess,
                                             remindersAuthorized: Bool, alarmsAuthorized: Bool = false) -> [String: Any] {
        var sharing = preferences.sharingJSON
        let calendar: PhoneCalendarAccess
        switch (preferences.calendar, access) {
        case (.full, .full): calendar = .full
        case (.readOnly, .full), (.readOnly, .readOnly), (.full, .readOnly): calendar = .readOnly
        // Read-only without read access leaves nothing Hermes may have.
        case (.off, _), (_, .off), (.readOnly, .writeOnly), (.writeOnly, .readOnly): calendar = .off
        case (.full, .writeOnly), (.writeOnly, .full), (.writeOnly, .writeOnly): calendar = .writeOnly
        }
        sharing["calendar"] = calendar == .readOnly ? PhoneCalendarAccess.full.rawValue : calendar.rawValue
        sharing["calendar_read_only"] = calendar == .readOnly
        if !calendar.reads { sharing["attendee_emails"] = false }
        let reminders = preferences.reminders && remindersAuthorized
        sharing["reminders"] = reminders
        sharing["reminders_read_only"] = reminders && preferences.remindersReadOnly
        if !calendar.reads, !reminders { sharing["details"] = false }
        sharing["alarms"] = preferences.alarms && alarmsAuthorized
        return sharing
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

    /// An upload as parts the host takes, each with at most `maxItems` items
    /// (what phone_store counts against MAX_ITEMS: calendars, upserts,
    /// deletions, alarms and people) and about `maxBytes` of JSON. The first
    /// part is the upload with as many event and reminder deletions, then
    /// upserts, as fit: it carries every other section and each section's
    /// `full`. The others only add deletions and upserts (never `full`) under
    /// the same `sent_at`, which the host applies after the first. An upload
    /// that fits is one part.
    ///
    /// The host applies each part on its own, so between a full first part
    /// and the last one it has only some of the snapshot; if a later part is
    /// refused, nothing counts as sent and the next pass sends it all again.
    nonisolated static func parts(of batch: [String: Any], maxItems: Int, maxBytes: Int) -> [[String: Any]] {
        func size(_ value: Any) -> Int {
            (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]))?.count ?? 0
        }
        func count(_ value: Any?) -> Int { (value as? [Any])?.count ?? 0 }
        var head = batch
        // Deletions first, so an upload that fits keeps them all in its first part.
        var deletes: [(section: String, list: String, item: Any)] = []
        var upserts: [(section: String, list: String, item: Any)] = []
        var later = batch.filter { frameKeys.contains($0.key) }
        for section in ["events", "reminders"] {
            guard var body = batch[section] as? [String: Any] else { continue }
            deletes += (body["delete"] as? [Any] ?? []).map { (section, "delete", $0) }
            upserts += (body["upsert"] as? [Any] ?? []).map { (section, "upsert", $0) }
            body["upsert"] = [[String: Any]]()
            if body["delete"] != nil { body["delete"] = [String]() }
            head[section] = body
            var more: [String: Any] = ["full": false, "upsert": [[String: Any]](), "delete": [String]()]
            more["from"] = body["from"]
            more["to"] = body["to"]
            later[section] = more
        }
        var items = count(head["calendars"]) + count(head["alarms"]) + count(head["contacts"])
        var bytes = size(head)
        var base = head
        var taken: [String: [String: [Any]]] = [:]
        var parts: [[String: Any]] = []
        func close() {
            var part = base
            for (section, lists) in taken {
                var body = part[section] as? [String: Any] ?? [:]
                for (list, values) in lists { body[list] = values }
                part[section] = body
            }
            // A later part has only the sections it adds to.
            if !parts.isEmpty {
                part = part.filter { frameKeys.contains($0.key) || taken[$0.key] != nil }
            }
            parts.append(part)
        }
        for (section, list, item) in deletes + upserts {
            let itemBytes = size(item) + 1
            // A later part takes at least one item, however large.
            let mustTakeOne = !parts.isEmpty && taken.isEmpty
            if !mustTakeOne, items + 1 > maxItems || bytes + itemBytes > maxBytes {
                close()
                base = later
                taken = [:]
                items = 0
                bytes = size(later)
            }
            taken[section, default: [:]][list, default: []].append(item)
            items += 1
            bytes += itemBytes
        }
        close()
        return parts
    }

    nonisolated private static func partsInBackground(_ batch: [String: Any], maxItems: Int,
                                                      maxBytes: Int) async -> [[String: Any]] {
        parts(of: batch, maxItems: maxItems, maxBytes: maxBytes)
    }

    /// A full upload can be thousands of items, so it's serialized and
    /// sealed off the main thread.
    nonisolated private static func sealBatch(_ batch: [String: Any], key: PhoneSyncCrypto.SessionKey,
                                              deviceID: String, batchID: String) async throws -> [String: Any] {
        let plaintext = try JSONSerialization.data(withJSONObject: batch, options: [.sortedKeys])
        return try PhoneSyncCrypto.envelope(plaintext: plaintext, key: key, deviceID: deviceID, batchID: batchID)
    }

    /// Hashing thousands of items is kept off the main thread.
    nonisolated private static func diffInBackground(_ items: [[String: Any]], against sent: [String: String],
                                                     full: Bool, truncated: Bool) async -> Section {
        diff(items, against: sent, full: full, truncated: truncated)
    }

    nonisolated static func hash(_ value: Any) -> String {
        ContextFingerprint.of(value)
    }

    // MARK: Changes from Hermes

    /// Reports outcomes and takes the changes still waiting.
    private func exchange(key: PhoneSyncCrypto.SessionKey, request: Request) async throws {
        let callID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let reporting = state.unreported
        let results: [[String: Any]] = reporting.map { $0.json }
        let payload: [String: Any] = ["call_id": callID, "results": results]
        let plaintext = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
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
            if applying.contains(change.id) { continue }
            if let known = state.answered[change.id] {
                // Answered, but the report was lost: say it again.
                if !state.unreported.contains(known) { state.unreported.append(known) }
                continue
            }
            if !preferences.allows(change.kind) {
                // Read-only (or no longer shared): never a card, whatever
                // the host asked. A host from before read-only can ask.
                // Reported, not remembered as answered: it's the setting
                // now, so the same change asked again after the user allows
                // changes gets its card.
                let refusal = PhoneChangeResult(id: change.id, outcome: .failed, note: Self.refusalNote(change.kind))
                if !state.unreported.contains(refusal) { state.unreported.append(refusal) }
                continue
            }
            if change.auto, change.kind.addsWithoutAsking, preferences.autoAdd {
                await applyNow(change, auto: true)
            } else {
                fresh.append(PhoneChangePrompt(change: change, calendarTitle: calendarTitle(for: change),
                                               alarmTitle: alarmTitle(for: change)))
            }
        }
        prompts = fresh
        persist()
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

    private func calendarTitle(for change: PhoneChange) -> String? {
        guard !change.kind.isAlarm else { return nil }
        return calendarSource.calendarTitle(id: change.fields.calendarID ?? change.fields.listID, forEvents: change.kind.isEvent)
    }

    private func alarmTitle(for change: PhoneChange) -> String? {
        guard change.kind == .cancelAlarm,
              let alarm = alarmSource.alarms(now: now(), calendar: calendar)?.first(where: { ($0["id"] as? String)?.lowercased() == change.alarmID?.lowercased() })
        else { return nil }
        let ring = (alarm["fires_at"] as? String).flatMap(PhoneDates.parse)?.formatted(date: .abbreviated, time: .shortened)
        let parts = [alarm["label"] as? String, ring].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Why a change the user doesn't allow was refused, for Hermes (not UI
    /// copy, so not localized).
    nonisolated static func refusalNote(_ kind: PhoneChange.Kind) -> String {
        if kind.isAlarm { return "The user doesn't let Hermes set alarms on this iPhone" }
        return kind.isEvent
            ? "The user doesn't let Hermes make this change to their calendar (read-only or not shared)"
            : "The user doesn't let Hermes change their reminders (read-only or not shared)"
    }

    private func applyNow(_ change: PhoneChange, auto: Bool) async {
        guard state.answered[change.id] == nil, applying.insert(change.id).inserted else { return }
        defer { applying.remove(change.id) }
        // The user can make it read-only while a card waits.
        guard preferences.allows(change.kind) else {
            record(PhoneChangeResult(id: change.id, outcome: .failed, note: Self.refusalNote(change.kind)))
            return
        }
        if change.kind.isAlarm {
            await applyAlarm(change, auto: auto)
            return
        }
        do {
            let itemID = try await calendarSource.apply(change, window: window)
            record(PhoneChangeResult(id: change.id, outcome: .applied, itemID: itemID))
            // Counted as sent, so the next upload sends the new item, or its
            // deletion if the user takes it back (Undo, or in Calendar).
            if change.kind.isAddition, let itemID {
                if change.kind.isEvent {
                    if state.eventHashes[itemID] == nil { state.eventHashes[itemID] = "" }
                } else if state.reminderHashes[itemID] == nil {
                    state.reminderHashes[itemID] = ""
                }
                persist()
            }
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

    private func applyAlarm(_ change: PhoneChange, auto: Bool) async {
        do {
            let alarmID = try await alarmSource.apply(change, now: now())
            record(PhoneChangeResult(id: change.id, outcome: .applied, itemID: alarmID))
            if auto {
                autoAdded = PhoneAutoAdded(changeID: change.id, itemID: alarmID,
                                           title: PhoneChangeWording.alarmSummary(change.fields, kind: change.kind),
                                           calendarTitle: nil, isEvent: false, isAlarm: true)
            }
        } catch {
            record(PhoneChangeResult(id: change.id, outcome: .failed, note: Self.describe(error)))
            if !auto { lastError = Self.describe(error) }
        }
    }

    private func record(_ result: PhoneChangeResult) {
        state.answered[result.id] = result
        state.unreported.append(result)
        persist()
    }

    // MARK: Live voice calls

    struct VoiceNotReady: Error {}

    /// One sealed read for a live voice call (`op: "voice"`, at `path`): the
    /// host's result, for this iPhone's data only. Checks only that sharing
    /// is on: the caller checks the voice mode may use it
    /// (`AppState.callVoiceHostTool`).
    func voiceRead(tool: String, arguments: [String: Any], provider: String, path: String,
                   request: Request) async throws -> Any {
        guard preferences.isOn, readStateIfNeeded(), let key = keys.load() else { throw VoiceNotReady() }
        let deviceID = state.deviceID
        let callID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let payload: [String: Any] = ["call_id": callID, "tool": tool, "args": arguments, "provider": provider]
        // JSONSerialization raises, rather than throws, on anything else.
        guard JSONSerialization.isValidJSONObject(payload) else { throw PhoneSyncCrypto.Failure.malformedAnswer }
        let plaintext = try JSONSerialization.data(withJSONObject: payload)
        let body = try PhoneSyncCrypto.exchangeEnvelope(plaintext: plaintext, op: "voice", key: key,
                                                        deviceID: deviceID, callID: callID)
        let answer = try await request(path, "POST", body)
        let opened = try PhoneSyncCrypto.openAnswer(answer, op: "voice", key: key, deviceID: deviceID, callID: callID)
        guard let json = try JSONSerialization.jsonObject(with: opened) as? [String: Any],
              json["call_id"] as? String == callID else {
            throw PhoneSyncCrypto.Failure.malformedAnswer
        }
        return json["result"] ?? NSNull()
    }

    /// Adds, changes or deletes an event or reminder, or sets or cancels an
    /// alarm, the user asked for in a voice call, straight away (no card:
    /// they said so out loud). The next upload sends it. Like `voiceRead`,
    /// the caller checks the voice mode may use it.
    func applyFromVoice(_ change: PhoneChange) async throws -> String? {
        // Still shared, and not read-only, after the wait for the user's yes.
        guard preferences.isOn, preferences.allows(change.kind), readStateIfNeeded() else { throw VoiceNotReady() }
        if change.kind.isAlarm {
            return try await alarmSource.apply(change, now: now())
        }
        if !change.kind.isAddition {
            let isEvent = change.kind.isEvent
            // Only what's still shared: an id read before its calendar was
            // left out isn't.
            if let calendar = await calendarSource.itemCalendar(itemID: (isEvent ? change.eventID : change.reminderID) ?? "",
                                                                isEvent: isEvent, window: window),
               preferences.hiddenCalendars.contains(calendar) {
                throw PhoneCalendarSourceError.notFound
            }
        }
        let itemID = try await calendarSource.apply(change, window: window)
        // A change or deletion needs nothing here: the next upload sees it.
        if change.kind.isAddition, let itemID {
            if change.kind.isEvent {
                if state.eventHashes[itemID] == nil { state.eventHashes[itemID] = "" }
            } else if state.reminderHashes[itemID] == nil {
                state.reminderHashes[itemID] = ""
            }
            persist()
        }
        return itemID
    }

    /// The banner's Undo: takes back an addition made without asking.
    func undo(_ added: PhoneAutoAdded) async {
        if autoAdded == added { autoAdded = nil }
        do {
            if added.isAlarm {
                try alarmSource.cancel(id: added.itemID)
                return
            }
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
