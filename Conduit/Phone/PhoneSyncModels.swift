//
//  PhoneSyncModels.swift
//  Conduit
//
//  Calendar, Reminders, Focus and phone status for Hermes. Each is its own
//  opt-in; what the user turns on goes straight from this iPhone to one
//  Hermes profile on one dashboard, sealed end to end (PhoneSyncCrypto),
//  never through the push relay. The notifier plugin keeps it for the
//  `conduit_calendar` and `conduit_phone` tools. Hermes can also ask for
//  calendar and reminder changes, which this phone applies: after the user
//  says yes, or straight away for new items when they chose "Add without
//  asking". (hermes-conduit designs/calendar-reminders-and-more.md, wire
//  contract designs/phone-v1-contract.md)
//

import Foundation

/// How much of the calendar Hermes gets.
enum PhoneCalendarAccess: String, CaseIterable, Identifiable, Codable {
    /// Reads events and asks to add or change them.
    case full
    /// Reads events, never adds, changes or deletes any. Needs the same
    /// full access from iOS (there's no read-only one): Conduit refuses the
    /// changes itself, and tells the host so it doesn't ask.
    case readOnly = "read_only"
    /// Can ask to add events, never reads them (iOS 17's write-only access).
    case writeOnly = "write_only"
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: return AppLocalization.string("Read and add")
        case .readOnly: return AppLocalization.string("Read only")
        case .writeOnly: return AppLocalization.string("Add only")
        case .off: return AppLocalization.string("Off")
        }
    }

    /// Hermes reads events.
    var reads: Bool { self == .full || self == .readOnly }
    /// Hermes may ask to add events.
    var adds: Bool { self == .full || self == .writeOnly }
}

/// How far ahead events are shared. Past events always reach back a week.
enum PhoneCalendarWindow: Int, CaseIterable, Identifiable, Codable {
    case days30 = 30
    case days60 = 60
    case days180 = 180

    static let `default`: PhoneCalendarWindow = .days60
    static let pastDays = 7

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .days30: return AppLocalization.string("Next 30 days")
        case .days60: return AppLocalization.string("Next 60 days")
        case .days180: return AppLocalization.string("Next 6 months")
        }
    }
}

typealias PhoneSyncDestination = HealthSyncDestination

/// The user's choices, kept in UserDefaults (no calendar data in them).
struct PhoneSyncPreferences: Codable, Equatable {
    var destination: PhoneSyncDestination?
    var calendar: PhoneCalendarAccess = .off
    var reminders = false
    /// Event and reminder notes, attendees and links (off by default).
    var details = false
    var attendeeEmails = false
    var status = false
    var focus = false
    /// New events and reminders Hermes asks for go in without a card.
    /// Changes and deletions always ask.
    var autoAdd = false
    var window: PhoneCalendarWindow = .default
    /// Calendars and reminder lists the user left out, by EventKit id.
    var hiddenCalendars: Set<String> = []
    /// Stored optional so preferences saved before them still decode; read
    /// `alarms` and `contacts`.
    var alarmsChoice: Bool?
    var contactsChoice: Bool?
    /// Hermes reads reminders but never adds, changes, completes or
    /// deletes one. Optional so preferences saved before it still decode;
    /// read `remindersReadOnly`.
    var remindersReadOnlyChoice: Bool?
    /// Live voice modes the user lets read what's shared on a call, answer
    /// Hermes' changes and add events and reminders
    /// (`LiveVoiceModeName.storageID`). Optional so preferences saved before
    /// it still decode; nil is none.
    var voiceReaders: [String]?
    /// Shortcuts the user lets Hermes run, by name (designs/phone-v1-contract.md
    /// `shortcuts`). Optional so preferences saved before them still decode;
    /// read `shortcuts`, `shortcutsRunWithoutAsking` and `shortcutList`.
    var shortcutsChoice: Bool?
    var shortcutsAutoChoice: Bool?
    var shortcutListChoice: [PhoneShortcut]?
    /// Hermes may ask to add a contact, or change or delete a picked
    /// person's; always on a card. Read `contactsEdit`.
    var contactsEditChoice: Bool?

    /// Hermes may set alarms and timers on this phone (iOS 26's AlarmKit).
    /// They ring through Silent and Focus, so it's its own choice.
    var alarms: Bool {
        get { alarmsChoice ?? false }
        set { alarmsChoice = newValue ? true : nil }
    }

    /// The people the user picked in Conduit go to Hermes (no address-book
    /// access: they're chosen one by one).
    var contacts: Bool {
        get { contactsChoice ?? false }
        set { contactsChoice = newValue ? true : nil }
    }

    var remindersReadOnly: Bool {
        get { remindersReadOnlyChoice ?? false }
        set { remindersReadOnlyChoice = newValue ? true : nil }
    }

    /// Part of sharing the picked people: off with them.
    var contactsEdit: Bool {
        get { contacts && (contactsEditChoice ?? false) }
        set { contactsEditChoice = newValue ? true : nil }
    }

    /// Hermes may ask to run the Shortcuts in `shortcutList`.
    var shortcuts: Bool {
        get { shortcutsChoice ?? false }
        set { shortcutsChoice = newValue ? true : nil }
    }

    /// A run Hermes asks for starts without a card, when Conduit is on
    /// screen (a run opens the Shortcuts app, which iOS allows only then).
    var shortcutsRunWithoutAsking: Bool {
        get { shortcuts && (shortcutsAutoChoice ?? false) }
        set { shortcutsAutoChoice = newValue ? true : nil }
    }

    var shortcutList: [PhoneShortcut] {
        get { shortcutListChoice ?? [] }
        set { shortcutListChoice = newValue.isEmpty ? nil : Array(newValue.prefix(PhoneShortcut.maximum)) }
    }

    /// The listed shortcut a run names, in any case.
    func listedShortcut(named name: String) -> PhoneShortcut? {
        shortcutList.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Whether the user lets Hermes make this change at all (before any
    /// card): nothing in a read-only calendar or reminders, and only
    /// additions to an add-only calendar.
    func allows(_ kind: PhoneChange.Kind) -> Bool {
        if kind.isAlarm { return alarms }
        if kind == .runShortcut { return shortcuts }
        if kind.isContact { return contactsEdit }
        if kind.isEvent { return kind.isAddition ? calendar.adds : calendar == .full }
        return reminders && !remindersReadOnly
    }

    /// Something Hermes may ask to add or change.
    var takesChanges: Bool { calendar.adds || (reminders && !remindersReadOnly) || alarms || shortcuts || contactsEdit }

    var isOn: Bool { destination != nil && sharesAnything }
    var sharesAnything: Bool { calendar != .off || reminders || status || focus || alarms || contacts || shortcuts }

    /// Whether a live call on `mode` may use the calendar and phone.
    func letsVoiceUse(_ mode: LiveVoiceModeName) -> Bool {
        isOn && (voiceReaders ?? []).contains(mode.storageID)
    }

    mutating func setVoiceUse(_ mode: LiveVoiceModeName, allowed: Bool) {
        var readers = Set(voiceReaders ?? [])
        if allowed { readers.insert(mode.storageID) } else { readers.remove(mode.storageID) }
        voiceReaders = readers.isEmpty ? nil : readers.sorted()
    }

    static let storageKey = "conduit.phoneSync.preferences.v1"

    static func load(from defaults: UserDefaults = .standard) -> PhoneSyncPreferences {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(PhoneSyncPreferences.self, from: data) else {
            return PhoneSyncPreferences()
        }
        return value
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// The `sharing` object every upload carries.
    /// A read-only calendar goes as "full" with `calendar_read_only`, so a
    /// host from before it still takes the batch (and Conduit still refuses
    /// the changes it asks for).
    var sharingJSON: [String: Any] {
        [
            "calendar": calendar == .readOnly ? PhoneCalendarAccess.full.rawValue : calendar.rawValue,
            "calendar_read_only": calendar == .readOnly,
            "reminders": reminders,
            "reminders_read_only": reminders && remindersReadOnly,
            "details": details,
            "attendee_emails": details && attendeeEmails,
            "status": status,
            "focus": focus,
            "auto_add": autoAdd,
            "alarms": alarms,
            "contacts": contacts,
            "shortcuts": shortcuts,
            "shortcuts_auto": shortcutsRunWithoutAsking,
            "contacts_edit": contactsEdit,
            "past_days": PhoneCalendarWindow.pastDays,
            "future_days": window.rawValue,
        ]
    }

    /// What decides the shape of what's sent: a change sends everything again.
    var fingerprint: String {
        [calendar.rawValue, String(reminders), String(details), String(attendeeEmails), String(window.rawValue),
         hiddenCalendars.sorted().joined(separator: ",")].joined(separator: "|")
    }
}

/// A shortcut from the user's Shortcuts app that Hermes may run, with a
/// note on what it does for Hermes to read.
struct PhoneShortcut: Codable, Equatable, Identifiable, Hashable {
    var name: String
    var note: String?

    var id: String { name.lowercased() }

    /// The notifier's phone_store limits.
    static let maximum = 50
    static let nameChars = 100
    static let noteChars = 200
    static let inputChars = 4_000

    init?(name: String, note: String? = nil) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.nameChars))
        guard !name.isEmpty else { return nil }
        self.name = name
        let note = note.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.noteChars)) }
        self.note = note?.isEmpty == false ? note : nil
    }

    var json: [String: Any] {
        var value: [String: Any] = ["name": name]
        if let note { value["note"] = note }
        return value
    }
}

/// A deletion the user asked for while the host couldn't be reached.
struct PhoneSyncPendingDeletion: Codable, Equatable {
    var dashboardID: UUID
    var profile: String
    var deviceID: String

    static let storageKey = "conduit.phoneSync.pendingDeletions.v1"

    static func all(in defaults: UserDefaults = .standard) -> [PhoneSyncPendingDeletion] {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([PhoneSyncPendingDeletion].self, from: $0) } ?? []
    }

    static func owed(on dashboardID: UUID, in defaults: UserDefaults = .standard) -> PhoneSyncPendingDeletion? {
        all(in: defaults).first { $0.dashboardID == dashboardID }
    }

    func save(to defaults: UserDefaults = .standard) {
        Self.store(Self.all(in: defaults).filter { $0 != self } + [self], in: defaults)
    }

    func clear(from defaults: UserDefaults = .standard) {
        Self.store(Self.all(in: defaults).filter { $0 != self }, in: defaults)
    }

    private static func store(_ deletions: [PhoneSyncPendingDeletion], in defaults: UserDefaults) {
        guard !deletions.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(deletions) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

/// Why sharing is paused, in words the settings page shows.
enum PhoneSyncPause: Codable, Equatable {
    case signInRequired
    case pluginMissing
    case otherDashboard
    /// The profile turned the plugin off: how to turn it on (issue 1671).
    case pluginOff(String)
    case refused(String)

    var message: String { message(managedBy: PluginUpdateAsk.managedBy) }

    /// The words for a destination whose host's plugin is kept up to date
    /// by `managedBy` (nil when the host doesn't manage it), which may not
    /// be the active dashboard's.
    func message(managedBy: String?) -> String {
        switch self {
        case .signInRequired:
            return AppLocalization.string("Paused: sign in to this dashboard again. Sharing catches up when you open Conduit.")
        case .pluginMissing:
            return PluginUpdateAsk.text(AppLocalization.string("Paused: update the Conduit plugin on this host to share your calendar and phone status."),
                                        lead: AppLocalization.string("Sharing is paused."), managedBy: managedBy)
        case .otherDashboard:
            return AppLocalization.string("Waiting: this goes only to the dashboard it was turned on for. Switch back to it to sync.")
        case .pluginOff(let remedy):
            return AppLocalization.string("Paused: \(remedy)")
        case .refused(let detail):
            return AppLocalization.string("Paused: the host refused the upload (\(detail)).")
        }
    }
}

/// The outcome of a change Hermes asked for, reported on the next exchange.
struct PhoneChangeResult: Codable, Equatable {
    enum Outcome: String, Codable {
        case applied, edited, dismissed, failed, expired
    }

    var id: String
    var outcome: Outcome
    var itemID: String?
    var note: String?
    /// The text a shortcut gave back.
    var result: String?

    static let resultChars = 4_000
    /// What every shortcut in one exchange gave back, together, so the
    /// sealed body stays under the host's 64 KiB cap (it trims to the same).
    static let resultsChars = 16_000

    /// Each result as the exchange sends it, later shortcuts' text cut once
    /// the exchange's share is spent.
    static func json(for results: [PhoneChangeResult]) -> [[String: Any]] {
        var budget = resultsChars
        return results.map { item in
            var item = item
            if let text = item.result.map({ String($0.prefix(min(resultChars, budget))) }) {
                item.result = text.isEmpty ? nil : text
                budget -= text.count
            }
            return item.json
        }
    }

    var json: [String: Any] {
        var value: [String: Any] = ["id": id, "outcome": outcome.rawValue]
        if let itemID { value["item_id"] = itemID }
        if let note { value["note"] = String(note.prefix(200)) }
        if let result, !result.isEmpty { value["result"] = String(result.prefix(Self.resultChars)) }
        return value
    }
}

/// A change Hermes asked for, as the host sends it.
struct PhoneChange: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case addEvent = "add_event"
        case updateEvent = "update_event"
        case deleteEvent = "delete_event"
        case addReminder = "add_reminder"
        case updateReminder = "update_reminder"
        case completeReminder = "complete_reminder"
        case deleteReminder = "delete_reminder"
        case setAlarm = "set_alarm"
        case setTimer = "set_timer"
        case cancelAlarm = "cancel_alarm"
        case runShortcut = "run_shortcut"
        case addContact = "add_contact"
        case updateContact = "update_contact"
        case deleteContact = "delete_contact"

        /// A new calendar event or reminder.
        var isAddition: Bool { self == .addEvent || self == .addReminder }
        var isEvent: Bool { self == .addEvent || self == .updateEvent || self == .deleteEvent }
        var isAlarm: Bool { self == .setAlarm || self == .setTimer || self == .cancelAlarm }
        var isContact: Bool { self == .addContact || self == .updateContact || self == .deleteContact }
        /// What "Add without asking" lets in: new items, never changes or
        /// cancellations.
        var addsWithoutAsking: Bool { isAddition || self == .setAlarm || self == .setTimer }
    }

    var id: String
    var kind: Kind
    var auto: Bool
    var reason: String?
    var sessionTitle: String?
    var eventID: String?
    var reminderID: String?
    var alarmID: String?
    /// The picked person a contact change is about (PhonePerson.id).
    var contactID: String?
    /// "this" or "future" for a recurring event.
    var span: String?
    var fields: PhoneChangeFields
    var createdAt: Date?

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty, id.count <= 80,
              let kindText = json["kind"] as? String, let kind = Kind(rawValue: kindText) else { return nil }
        self.id = id
        self.kind = kind
        auto = (json["auto"] as? Bool) ?? false
        reason = (json["reason"] as? String).map { String($0.prefix(200)) }
        sessionTitle = (json["session_title"] as? String).map { String($0.prefix(80)) }
        let target = json["target"] as? [String: Any]
        eventID = target?["event_id"] as? String
        reminderID = target?["reminder_id"] as? String
        alarmID = target?["alarm_id"] as? String
        contactID = target?["contact_id"] as? String
        let fieldsJSON = json["fields"] as? [String: Any] ?? [:]
        span = (fieldsJSON["span"] as? String) ?? (target?["span"] as? String)
        fields = PhoneChangeFields(json: fieldsJSON)
        createdAt = (json["created_at"] as? String).flatMap(PhoneDates.parse)
        switch kind {
        case .updateEvent, .deleteEvent:
            guard eventID != nil else { return nil }
        case .updateReminder, .completeReminder, .deleteReminder:
            guard reminderID != nil else { return nil }
        case .addEvent:
            guard fields.title != nil, fields.start != nil else { return nil }
        case .addReminder:
            guard fields.title != nil else { return nil }
        case .setAlarm:
            guard fields.at != nil || fields.time != nil else { return nil }
        case .setTimer:
            guard let seconds = fields.seconds, (5...86_400).contains(seconds) else { return nil }
        case .cancelAlarm:
            guard alarmID != nil else { return nil }
        case .runShortcut:
            guard fields.shortcut != nil else { return nil }
        case .addContact:
            guard fields.contact?.hasName == true else { return nil }
        case .updateContact:
            guard contactID != nil, fields.contact != nil else { return nil }
        case .deleteContact:
            guard contactID != nil else { return nil }
        }
    }
}

/// The fields of a change; only those present change anything.
struct PhoneChangeFields: Equatable {
    var title: String?
    var start: Date?
    var end: Date?
    var allDay: Bool?
    var calendarID: String?
    var location: String?
    var notes: String?
    var url: URL?
    var alarmsMinutes: [Int]?
    var due: Date?
    var dueAllDay: Bool?
    /// The due date as sent, `YYYY-MM-DD` for an all-day due date.
    var dueText: String?
    var priority: Int?
    var listID: String?
    var completed: Bool?
    var locationAlarmName: String?
    /// An alarm's or timer's name.
    var label: String?
    /// A one-off alarm's time.
    var at: Date?
    /// A clock-time alarm, `HH:MM` local, as hour and minute.
    var time: PhoneClockTime?
    /// The weekdays a clock-time alarm repeats on, `mon`…`sun`.
    var repeats: [String]?
    /// A timer's length.
    var seconds: Int?
    /// The shortcut a run names, and the text it's given.
    var shortcut: String?
    var input: String?
    /// What a contact change sets, when it sets anything.
    var contact: PhoneContactEdit?
    /// The person's name as shared, for the card.
    var personName: String?

    static let weekdays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

    init(json: [String: Any]) {
        title = (json["title"] as? String).map { String($0.prefix(200)) }
        start = (json["start"] as? String).flatMap(PhoneDates.parse)
        end = (json["end"] as? String).flatMap(PhoneDates.parse)
        allDay = json["all_day"] as? Bool
        calendarID = json["calendar_id"] as? String
        location = (json["location"] as? String).map { String($0.prefix(300)) }
        notes = (json["notes"] as? String).map { String($0.prefix(2000)) }
        url = (json["url"] as? String).flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        alarmsMinutes = (json["alarms_min"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue }.filter { (0...10_080).contains($0) }
        dueText = json["due"] as? String
        dueAllDay = json["due_all_day"] as? Bool
        due = dueText.flatMap(PhoneDates.parse)
        priority = (json["priority"] as? NSNumber)?.intValue
        listID = json["list_id"] as? String
        completed = json["completed"] as? Bool
        locationAlarmName = (json["location_alarm"] as? [String: Any])?["name"] as? String
        label = (json["label"] as? String).map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)) }
            .flatMap { $0.isEmpty ? nil : $0 }
        at = (json["at"] as? String).flatMap(PhoneDates.parse)
        time = (json["time"] as? String).flatMap(Self.clockTime)
        let days = (json["repeats"] as? [Any])?.compactMap { ($0 as? String)?.lowercased() }
        repeats = days.map { list in Self.weekdays.filter { list.contains($0) } }.flatMap { $0.isEmpty ? nil : $0 }
        seconds = (json["seconds"] as? NSNumber)?.intValue
        shortcut = (json["shortcut"] as? String).map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(PhoneShortcut.nameChars)) }
            .flatMap { $0.isEmpty ? nil : $0 }
        input = (json["input"] as? String).map { String($0.prefix(PhoneShortcut.inputChars)) }.flatMap { $0.isEmpty ? nil : $0 }
        contact = PhoneContactEdit(json: json)
        personName = (json["name"] as? String).map { String($0.prefix(120)) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `HH:MM` on a 24-hour clock.
    static func clockTime(_ text: String) -> PhoneClockTime? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 }), let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return PhoneClockTime(hour: hour, minute: minute)
    }
}

/// A time of day on the phone's clock.
struct PhoneClockTime: Equatable, Codable {
    var hour: Int
    var minute: Int

    var text: String { String(format: "%02d:%02d", hour, minute) }
}

/// What a Focus filter told Conduit, kept for the next upload. Written by
/// the Focus filter intent, which iOS runs as a Focus turns on or off.
struct PhoneFocusSnapshot: Codable, Equatable {
    var active: Bool
    var label: String?
    var holdCalls: Bool
    var at: Date

    static let storageKey = "conduit.phoneSync.focus.v1"

    static func load(from defaults: UserDefaults = .standard) -> PhoneFocusSnapshot? {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(PhoneFocusSnapshot.self, from: $0) }
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    var json: [String: Any] {
        var value: [String: Any] = ["at": PhoneDates.format(at), "active": active, "hold_calls": holdCalls]
        if let label, !label.isEmpty { value["label"] = String(label.prefix(40)) }
        return value
    }
}

/// ISO 8601 with the phone's local offset, as the host expects.
enum PhoneDates {
    static func format(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatter(for: timeZone).string(from: date)
    }

    /// One formatter per time zone: a full sync formats thousands of dates.
    /// ISO8601DateFormatter is thread-safe once configured.
    private static func formatter(for timeZone: TimeZone) -> ISO8601DateFormatter {
        formattersLock.withLock {
            if let known = formatters[timeZone.identifier] { return known }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            formatter.timeZone = timeZone
            formatters[timeZone.identifier] = formatter
            return formatter
        }
    }

    private static let formattersLock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: ISO8601DateFormatter] = [:]

    /// A wire `YYYY-MM-DD` day: Gregorian whatever the device's calendar,
    /// or a Japanese-calendar device would send its era year.
    static func day(_ date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1)
    }

    /// A time with an offset, with or without fractional seconds, or a bare
    /// `YYYY-MM-DD` (midnight, local).
    static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard text.count == 10, parts.count == 3 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

enum PhoneSyncLimits {
    static let maxEvents = 4_000
    static let maxReminders = 1_000
    static let notesChars = 2_000
    /// The longest link the host takes (phone_store MAX_URL_CHARS).
    static let urlChars = 1_000
    /// Completed reminders stay shared this long.
    static let completedReminderDays = 14
    /// Everything is sent whole again at least this often, so a missed
    /// deletion can't linger on the host.
    static let fullSyncInterval: TimeInterval = 24 * 3600
    /// Status goes again after this long even when nothing changed, so its
    /// age on the host stays honest.
    static let statusRefresh: TimeInterval = 15 * 60
    /// The most one upload carries (the notifier's phone_store MAX_ITEMS);
    /// a larger one goes in parts.
    static let batchItems = 5_000
    /// The JSON one upload carries. Sealed, it grows by a third as base64,
    /// and the notifier refuses bodies over 4 MiB
    /// (dashboard/api/phone_data.py PHONE_MAX_INGEST_BODY_BYTES).
    static let batchBytes = 3_000_000
}
