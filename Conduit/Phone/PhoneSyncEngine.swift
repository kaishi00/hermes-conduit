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
    /// Optional fields read as nil from a state file written before them.
    var shortcutsHash: String?
    /// What the host has of each photo's description, by photo id.
    var photoHashes: [String: String]?
    /// Photos the user said yes to, by change id, waiting to go up: each
    /// one's JPEG is in `PhoneSyncEngine.photoUploadsFolder`.
    var photoUploads: [String]?
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
        shortcutsHash = nil
        photoHashes = nil
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
    /// The picked person a contact change or deletion is about, by the
    /// name the phone knows them by, not the one Hermes sent.
    var personName: String?
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
    /// What to do when the last turn-off's delete met a profile that turned
    /// the plugin off (nothing was deleted), or nil (issue 1671).
    private(set) var deleteRefusedPluginOff: String?
    @Published private(set) var preferences: PhoneSyncPreferences
    /// Changes waiting for the user's answer, oldest first.
    @Published private(set) var prompts: [PhoneChangePrompt] = []
    /// The latest addition made without asking, until the banner goes.
    @Published var autoAdded: PhoneAutoAdded?
    /// The people the user picked for Hermes.
    @Published private(set) var people: [PhonePerson]
    /// Picked people the last read from Contacts missed, by id, with why.
    @Published private(set) var peopleProblems: [String: PhonePersonProblem] = [:]
    /// Whether the picked people can be read again from Contacts.
    @Published private(set) var contactsAccess: PhoneContactsAccess

    let calendarSource: PhoneCalendarSource
    let statusSource: PhoneStatusSource
    let alarmSource: PhoneAlarmSource
    let contactsSource: PhoneContactsSource
    let shortcutRunner: PhoneShortcutRunning
    let photoSource: PhonePhotoSource
    /// Reports a run that went without asking as soon as it ends, as an
    /// answered card is: nothing else would send it while Conduit stays open.
    var onRanWithoutAsking: (@MainActor () async -> Void)?
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
    /// Changes the user approved on a Pulse card (Add, or Undo of one), by
    /// id, with when the approval lapses: the tap was the asking, so this
    /// app applies them without the phone's own card. In memory too: the
    /// host hands a change out right after the tap, and one that comes
    /// later, or after a relaunch, gets the usual card.
    private var approvedOnCard: [String: Date] = [:]
    static let cardApprovalWindow: TimeInterval = 15 * 60

    init(
        calendarSource: PhoneCalendarSource,
        statusSource: PhoneStatusSource,
        alarmSource: PhoneAlarmSource = PhoneAlarmSources.system(),
        contactsSource: PhoneContactsSource = SystemContactsSource(),
        shortcutRunner: PhoneShortcutRunning? = nil,
        photoSource: PhonePhotoSource? = nil,
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
        self.contactsSource = contactsSource
        self.shortcutRunner = shortcutRunner ?? PhoneShortcutRunner.shared
        self.photoSource = photoSource ?? SystemPhotoLibrary.shared
        contactsAccess = contactsSource.access
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
        // Photos off: pictures the user said yes to but not yet sent never go.
        if !preferences.photos, let waiting = state.photoUploads {
            for changeID in waiting {
                settlePhoto(PhoneChangeResult(id: changeID, outcome: .failed, note: Self.refusalNote(.sendPhoto)))
            }
        }
    }

    func savePeople(_ people: [PhonePerson]) {
        let kept = Array(people.prefix(PhonePerson.maximum))
        PhonePeopleStore.save(kept, to: defaults)
        self.people = kept
        peopleProblems = peopleProblems.filter { id, _ in kept.contains { $0.id == id } }
    }

    /// Reads the picked people again from Contacts, when Conduit may: what a
    /// contact says now replaces what Conduit had (their relation stays),
    /// and someone who can't be read keeps their last copy and is listed in
    /// `peopleProblems`.
    func refreshPeople() async {
        contactsAccess = contactsSource.access
        guard contactsAccess.canRead, !people.isEmpty else {
            peopleProblems = [:]
            return
        }
        let missing = Set(people.filter { $0.contactID == nil }.map(\.id))
        let found = missing.isEmpty ? [:] : await contactsSource.identifiers(for: missing)
        let identifiers = people.compactMap { $0.contactID ?? found?[$0.id] }
        let reads = await contactsSource.read(identifiers)
        // People changed while Contacts was read are matched by id, so an
        // edit or removal made meanwhile stands.
        let (refreshed, problems) = PhonePeopleStore.refreshed(people, reads: reads, found: found, access: contactsAccess)
        if refreshed != people { savePeople(refreshed) }
        peopleProblems = problems
    }

    /// Asks once for Contacts access, then reads the picked people again.
    func requestContactsAccess() async {
        contactsAccess = await contactsSource.requestAccess()
        await refreshPeople()
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
        deleteRefusedPluginOff = nil
        if let request {
            do {
                _ = try await request("\(Self.base)/wipe", "POST", ["device_id": state.deviceID])
                deleted = true
            } catch DashboardTicketBridgeError.http(let status, let detail)
                        where status == 404 && !DashboardTicketBridgeError.isPluginOffDetail(detail) {
                deleted = true
            } catch {
                lastError = Self.describe(error)
                deleteRefusedPluginOff = DashboardTicketBridgeError.pluginOffDetail(of: error)
            }
        }
        state.startOver()
        persist()
        try? FileManager.default.removeItem(at: Self.photoUploadsFolder)
        photoSource.forget()
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
                                           keepalive: keepalive, deadline: deadline, request: request)
            try checkTime(deadline)
            // A picture the host can't take now never holds up the other
            // changes: the exchange still runs, then the pass reports it.
            var photoError: Error?
            do {
                try await uploadPhotos(key: key, deadline: deadline, request: request)
            } catch where error is CancellationError || error is DeadlineReached {
                throw error
            } catch {
                photoError = error
            }
            try checkTime(deadline)
            if pending > 0 || !state.unreported.isEmpty || !prompts.isEmpty {
                try await exchange(key: key, request: request)
            }
            if let photoError { throw photoError }
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
                // A profile that turned the plugin off says how to turn it on.
                let pause = DashboardTicketBridgeError.pluginOffDetail(of: error).map(PhoneSyncPause.pluginOff) ?? .pluginMissing
                state.pause = pause
                return .paused(pause)
            case .http(let status, let detail) where status == 409 && HostKeyConflict.isKeyLoss(detail):
                // The host lost or replaced this phone's key: set it up again.
                keys.clear()
                state.forgetSent()
                lastError = detail
                return .unfinished
            case .http(let status, let detail) where status == 409 && HostKeyConflict.isNewerPluginStore(detail):
                // A store written by a newer plugin: updating the plugin
                // fixes it, a new key wouldn't. The key and hashes stay.
                state.pause = .pluginMissing
                return .paused(.pluginMissing)
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
                        keepalive: TimeInterval, deadline: Date = .distantFuture, request: Request) async throws -> Int {
        let currentNow = now()
        let full = state.fingerprint != preferences.fingerprint
            || state.lastFullSync.map { currentNow.timeIntervalSince($0) > PhoneSyncLimits.fullSyncInterval } ?? true
        let window = self.window
        var batch: [String: Any] = [
            "sent_at": PhoneDates.format(currentNow),
            "time_zone": TimeZone.current.identifier,
            "sharing": Self.effectiveSharing(preferences, access: calendarSource.eventAccess,
                                             remindersAuthorized: calendarSource.remindersAuthorized,
                                             alarmsAuthorized: alarmSource.authorized,
                                             photosAuthorized: photoSource.access.canRead),
        ]
        var newEventHashes = state.eventHashes
        var newReminderHashes = state.reminderHashes
        var newCalendarsHash = state.calendarsHash
        var newStatusHash = state.statusHash
        var newFocusHash = state.focusHash
        var newAlarmsHash = state.alarmsHash
        var newContactsHash = state.contactsHash
        var newShortcutsHash = state.shortcutsHash
        var newPhotoHashes = state.photoHashes
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
            await refreshPeople()
            let contacts = people.map(\.json)
            let hash = Self.hash(contacts)
            if full || hash != state.contactsHash {
                batch["contacts"] = contacts
                newContactsHash = hash
            }
        } else {
            newContactsHash = nil
        }
        if preferences.shortcuts {
            let shortcuts = preferences.shortcutList.map(\.json)
            let hash = Self.hash(shortcuts)
            if full || hash != state.shortcutsHash {
                batch["shortcuts"] = shortcuts
                newShortcutsHash = hash
            }
        } else {
            newShortcutsHash = nil
        }
        // Photos read live, not from the pass's start: turned off while the
        // pass ran, nothing more is described or sent, and the host hears
        // it's off now.
        if preferences.photos, self.preferences.photos, photoSource.access.canRead {
            // A few dozen more described each pass, newest first.
            await photoSource.describeMore(budget: PhoneSyncLimits.photosPerPass,
                                           until: min(deadline, now().addingTimeInterval(20)))
        }
        if !self.preferences.photos, var sharing = batch["sharing"] as? [String: Any] {
            sharing["photos"] = false
            batch["sharing"] = sharing
        }
        if preferences.photos, self.preferences.photos, photoSource.access.canRead {
            let photos = photoSource.descriptions()
            let section = await Self.diffInBackground(photos, against: state.photoHashes ?? [:], full: full,
                                                      truncated: false)
            if full || !section.upsert.isEmpty || !section.delete.isEmpty {
                let photos: [String: Any] = ["full": full, "upsert": section.upsert, "delete": section.delete]
                batch["photos"] = photos
            }
            newPhotoHashes = section.hashes
        } else {
            // The host forgets them when they're no longer shared.
            newPhotoHashes = nil
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
        state.shortcutsHash = newShortcutsHash
        state.photoHashes = newPhotoHashes
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
                                             remindersAuthorized: Bool, alarmsAuthorized: Bool = false,
                                             photosAuthorized: Bool = false) -> [String: Any] {
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
        sharing["photos"] = preferences.photos && photosAuthorized
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
        for section in ["events", "reminders", "photos"] {
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
        let results = PhoneChangeResult.json(for: reporting)
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
            // Said yes to, and going up: no card again.
            if state.photoUploads?.contains(change.id) == true { continue }
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
            // A photo goes only from its own card, with the picture showing:
            // a Pulse card's approval doesn't send one.
            if let approved = approvedOnCard.removeValue(forKey: change.id), approved > now(),
               change.kind != .sendPhoto {
                await applyNow(change, auto: false)
            } else if change.auto, change.kind.addsWithoutAsking, preferences.autoAdd {
                await applyNow(change, auto: true)
            } else if change.kind == .runShortcut, change.auto, preferences.shortcutsRunWithoutAsking,
                      shortcutRunner.canRun {
                // Only on screen: iOS opens Shortcuts for an app in front.
                // Otherwise it waits on its card like any other.
                // Not awaited: a run lasts as long as the shortcut does.
                Task {
                    await self.applyNow(change, auto: true)
                    await self.onRanWithoutAsking?()
                }
            } else {
                fresh.append(PhoneChangePrompt(change: change, calendarTitle: calendarTitle(for: change),
                                               alarmTitle: alarmTitle(for: change), personName: personName(for: change)))
            }
        }
        // One approved on a card while this ran gets no card: the pass the
        // approval runs applies it.
        prompts = fresh.filter { approvedOnCard[$0.id] == nil }
        persist()
    }

    /// A change the user approved on a Pulse card, by its id: applied now
    /// if its card is already waiting here, else when the host hands it out
    /// within 15 minutes (AppState.applyPulseApproval runs the pass). A
    /// change for another device never comes here, and its approval lapses.
    func approveFromCard(_ changeID: String) async {
        let now = self.now()
        approvedOnCard = approvedOnCard.filter { $0.value > now }
        if let prompt = prompts.first(where: { $0.id == changeID }) {
            // A photo waits on its own card (see the exchange).
            if prompt.change.kind != .sendPhoto { await answer(prompt, approve: true) }
            return
        }
        approvedOnCard[changeID] = now.addingTimeInterval(Self.cardApprovalWindow)
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
        guard !change.kind.isAlarm, change.kind != .runShortcut, !change.kind.isContact, change.kind != .sendPhoto
        else { return nil }
        return calendarSource.calendarTitle(id: change.fields.calendarID ?? change.fields.listID, forEvents: change.kind.isEvent)
    }

    /// The picked person a change or deletion names, as the phone has them.
    private func personName(for change: PhoneChange) -> String? {
        guard change.kind.isContact, change.kind != .addContact, let id = change.contactID else { return nil }
        return people.first { $0.id == id }?.name
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
        if kind == .runShortcut { return "The user doesn't let Hermes run Shortcuts on this iPhone" }
        if kind.isContact { return "The user doesn't let Hermes change their contacts" }
        if kind == .sendPhoto { return "The user doesn't share their photos with Hermes on this iPhone" }
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
        if change.kind == .runShortcut {
            await applyShortcut(change)
            return
        }
        if change.kind.isContact {
            await applyContact(change)
            return
        }
        if change.kind == .sendPhoto {
            await stagePhoto(change)
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

    /// Runs a shortcut the user listed (a name the host passed that isn't
    /// listed here any more is refused), and reports the text it gave back.
    private func applyShortcut(_ change: PhoneChange) async {
        guard let name = change.fields.shortcut, let listed = preferences.listedShortcut(named: name) else {
            record(PhoneChangeResult(id: change.id, outcome: .failed,
                                     note: "The user doesn't let Hermes run a shortcut by that name any more"))
            return
        }
        // A run can take minutes: what it gave back goes only to the host
        // that asked, and only while the user still lets Hermes run it.
        // Sharing turned off and on again, even to the same host, is
        // another sharing: the device id survives that, the count doesn't.
        let askedBy = ShortcutAsker(device: state.deviceID, turnOffs: turnOffs, destination: preferences.destination)
        do {
            let text = try await shortcutRunner.run(name: listed.name, input: change.fields.input)
            guard stillAsked(by: askedBy) else { return }
            record(PhoneChangeResult(id: change.id, outcome: .applied,
                                     result: text.map { String($0.prefix(PhoneChangeResult.resultChars)) }))
        } catch PhoneShortcutError.cancelled {
            guard stillAsked(by: askedBy) else { return }
            record(PhoneChangeResult(id: change.id, outcome: .dismissed, note: "The user cancelled the shortcut"))
        } catch {
            // Not on screen: no answer yet, so the card comes back on the
            // next exchange.
            if case .notOnScreen? = error as? PhoneShortcutError { return }
            guard stillAsked(by: askedBy) else { return }
            record(PhoneChangeResult(id: change.id, outcome: .failed, note: Self.shortcutNote(error)))
            lastError = Self.describe(error)
        }
    }

    /// The sharing a shortcut run was asked in.
    private struct ShortcutAsker {
        var device: String
        var turnOffs: Int
        var destination: PhoneSyncDestination?
    }

    /// Whether the sharing that asked for a run is still the one on, and
    /// still lets Hermes run shortcuts.
    private func stillAsked(by asker: ShortcutAsker) -> Bool {
        state.deviceID == asker.device && turnOffs == asker.turnOffs
            && preferences.destination == asker.destination && preferences.shortcuts
    }

    /// Adds a contact, or changes or deletes a picked person's card. A new
    /// contact joins the picked people (with the relation Hermes gave), a
    /// deleted one leaves them, and a changed one is read again, so the
    /// next upload tells Hermes.
    private func applyContact(_ change: PhoneChange) async {
        var person: PhonePerson?
        var contactID: String?
        if change.kind != .addContact {
            guard let id = change.contactID, let picked = people.first(where: { $0.id == id }) else {
                record(PhoneChangeResult(id: change.id, outcome: .failed,
                                         note: "That person isn't among the people the user picked any more"))
                return
            }
            person = picked
            contactID = picked.contactID
            if contactID == nil, contactsSource.access.canRead {
                contactID = await contactsSource.identifiers(for: [id])?[id]
            }
        }
        do {
            let identifier = try await contactsSource.applyChange(change, contactID: contactID)
            switch change.kind {
            case .addContact:
                let read = await contactsSource.read([identifier])
                var added: PhonePerson
                if case .person(let person)? = read[identifier] {
                    added = person
                } else {
                    // Not readable back (limited access can hide it): what the change said.
                    let edit = change.fields.contact
                    let typed = [edit?.givenName, edit?.familyName].compactMap { $0 }.joined(separator: " ")
                    let name = change.fields.personName ?? (typed.isEmpty ? edit?.organization : typed)
                    added = PhonePerson(id: PhonePerson.id(forContact: identifier), name: name ?? AppLocalization.string("Contact"))
                    added.organization = edit?.organization
                    added.nickname = edit?.nickname
                    added.phones = edit?.phones ?? []
                    added.emails = edit?.emails ?? []
                    added.birthday = edit?.birthday
                }
                added.contactID = identifier
                added.relation = change.fields.contact?.relation
                savePeople(PhonePeopleStore.merging([added], into: people))
                record(PhoneChangeResult(id: change.id, outcome: .applied, itemID: added.id))
            case .deleteContact:
                savePeople(people.filter { $0.id != person?.id })
                record(PhoneChangeResult(id: change.id, outcome: .applied, itemID: person?.id))
            default:
                if let relation = change.fields.contact?.relation, let id = person?.id {
                    savePeople(people.map { var kept = $0; if kept.id == id { kept.relation = relation }; return kept })
                }
                await refreshPeople()
                record(PhoneChangeResult(id: change.id, outcome: .applied, itemID: person?.id))
            }
        } catch {
            record(PhoneChangeResult(id: change.id, outcome: .failed, note: Self.describe(error)))
            lastError = Self.describe(error)
        }
    }

    /// Why a run failed, for Hermes (not UI copy, so not localized).
    static func shortcutNote(_ error: Error) -> String {
        switch error as? PhoneShortcutError {
        case .couldNotOpen?: return "The Shortcuts app couldn't be opened"
        case .failed(let message)?: return message.map { "The shortcut stopped with an error: \($0)" } ?? "The shortcut stopped with an error"
        case .noAnswer?: return "The Shortcuts app didn't say how the shortcut went"
        case .cancelled?: return "The user cancelled the shortcut"
        case .notOnScreen?: return "Conduit wasn't open, so iOS wouldn't start the shortcut"
        case nil: return describe(error)
        }
    }

    // MARK: Photos

    /// Where the pictures the user said yes to wait to go up. Not backed up;
    /// gone when sharing is turned off.
    nonisolated static var photoUploadsFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PhoneSync", isDirectory: true)
            .appendingPathComponent("PhotoUploads", isDirectory: true)
    }

    nonisolated static func photoUploadURL(_ changeID: String) -> URL {
        // A change id is the host's ("ch_" and URL-safe characters).
        let safe = changeID.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return photoUploadsFolder.appendingPathComponent("\(safe).jpg")
    }

    /// The user said yes to a photo: its JPEG waits on disk for this
    /// pass (or the next) to send it, so a lost connection doesn't lose
    /// the yes. Sent only by the upload, never by the result alone.
    private func stagePhoto(_ change: PhoneChange) async {
        guard let photoID = change.photoID,
              let data = await photoSource.jpeg(photoID: photoID, maxBytes: PhoneSyncLimits.photoFileBytes) else {
            record(PhoneChangeResult(id: change.id, outcome: .failed,
                                     note: "That photo isn't on this iPhone any more, or couldn't be read"))
            return
        }
        // Turned off while it was read: nothing goes.
        guard preferences.photos else {
            record(PhoneChangeResult(id: change.id, outcome: .failed, note: Self.refusalNote(.sendPhoto)))
            return
        }
        do {
            try FileManager.default.createDirectory(at: Self.photoUploadsFolder, withIntermediateDirectories: true)
            var folder = Self.photoUploadsFolder
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
            try data.write(to: Self.photoUploadURL(change.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            record(PhoneChangeResult(id: change.id, outcome: .failed, note: "The photo couldn't be saved for sending"))
            return
        }
        var uploads = state.photoUploads ?? []
        if !uploads.contains(change.id) { uploads.append(change.id) }
        state.photoUploads = uploads
        persist()
    }

    /// Sends each photo the user said yes to, one per upload, and records
    /// how it went. A refusal (the host no longer waits for it, or won't
    /// take it) answers that photo alone; a lost connection keeps it for
    /// the next pass.
    private func uploadPhotos(key: PhoneSyncCrypto.SessionKey, deadline: Date, request: Request) async throws {
        guard let uploads = state.photoUploads, !uploads.isEmpty else { return }
        for changeID in uploads {
            // What's left waits for the next pass.
            try checkTime(deadline)
            // The choice as it is now, not when the pass began: Photos may
            // have been turned off while an earlier upload was answered.
            let preferences = self.preferences
            let file = Self.photoUploadURL(changeID)
            guard preferences.photos, photoSource.access.canRead, let data = try? Data(contentsOf: file) else {
                settlePhoto(PhoneChangeResult(id: changeID, outcome: .failed,
                                         note: preferences.photos ? "The photo couldn't be read for sending"
                                             : Self.refusalNote(.sendPhoto)))
                continue
            }
            let batchID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let batch: [String: Any] = [
                "batch_id": batchID,
                "sent_at": PhoneDates.format(now()),
                "time_zone": TimeZone.current.identifier,
                "sharing": Self.effectiveSharing(preferences, access: calendarSource.eventAccess,
                                                 remindersAuthorized: calendarSource.remindersAuthorized,
                                                 alarmsAuthorized: alarmSource.authorized, photosAuthorized: true),
                "photo_files": [["change_id": changeID, "data": data.base64EncodedString()]],
            ]
            do {
                let body = try await Self.sealBatch(batch, key: key, deviceID: state.deviceID, batchID: batchID)
                let answer = try await request("\(Self.base)/ingest", "POST", body)
                let sent = (answer["photos_sent"] as? [String] ?? []).contains(changeID)
                settlePhoto(sent ? PhoneChangeResult(id: changeID, outcome: .applied)
                       : PhoneChangeResult(id: changeID, outcome: .failed, note: "Hermes no longer waited for this photo"))
            } catch DashboardTicketBridgeError.http(let status, let detail) where status == 400 || status == 413 {
                settlePhoto(PhoneChangeResult(id: changeID, outcome: .failed, note: "The host refused the photo: \(detail)"))
            }
            // Anything else (no connection, the host away) throws: it stays
            // for the next pass.
        }
    }

    /// A photo answered (sent or refused): it waits no more.
    private func settlePhoto(_ result: PhoneChangeResult) {
        try? FileManager.default.removeItem(at: Self.photoUploadURL(result.id))
        state.photoUploads?.removeAll { $0 == result.id }
        if state.photoUploads?.isEmpty == true { state.photoUploads = nil }
        record(result)
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

    /// Photos turned on without access to the library.
    struct PhotosNotAllowed: LocalizedError {
        var errorDescription: String? {
            AppLocalization.string("Conduit can't see your photos. Allow Photos for Conduit in Settings to share them with Hermes.")
        }
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? DashboardTicketBridgeError, let description = error.errorDescription { return description }
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        return error.localizedDescription
    }
}
