//
//  EventKitPhoneSource.swift
//  Conduit
//
//  Reads the user's calendars and reminders for Hermes, and applies the
//  changes Hermes asked for, through EventKit. Everything that leaves the
//  phone is built here as the JSON the host takes (phone-v1-contract.md
//  section 2), already trimmed to what the user chose: no notes, attendees
//  or links unless they turned details on, no attendee emails unless they
//  turned those on too. The host drops them again if one slips through.
//
//  Ids are made here and stay stable across passes: an event's is its
//  EventKit id and the start of that occurrence, hashed, so each instance
//  of a repeating event has its own; a reminder's and a calendar's are
//  their EventKit ids, hashed. The host never sees EventKit's own ids.
//

import CryptoKit
import CoreGraphics
import EventKit
import Foundation

enum PhoneCalendarSourceError: LocalizedError {
    case denied
    case notFound
    case readOnly
    case writeOnly
    case locationAlarm

    var errorDescription: String? {
        switch self {
        case .denied: return AppLocalization.string("Conduit doesn't have access to your calendar or reminders. Allow it in the Settings app.")
        case .notFound: return AppLocalization.string("That item isn't on this iPhone any more.")
        case .readOnly: return AppLocalization.string("That calendar can't be changed.")
        case .writeOnly: return AppLocalization.string("Conduit can only add events, so it can't find existing ones.")
        case .locationAlarm: return AppLocalization.string("Reminders that go off at a place can't be set from Hermes yet.")
        }
    }
}

/// The reading and writing a pass needs; a fake stands in for tests.
protocol PhoneCalendarSource: AnyObject {
    var eventAccess: PhoneCalendarAccess { get }
    var remindersAuthorized: Bool { get }
    func requestAccess(calendar: PhoneCalendarAccess, reminders: Bool) async throws
    /// Calendars and reminder lists, each `{id, title, kind, color, source, writable, shared, default}`.
    func calendars(eventsReadable: Bool, reminders: Bool) -> [[String: Any]]
    /// Events overlapping [from, to), at most `limit`, soonest first.
    func events(from: Date, to: Date, hidden: Set<String>, details: Bool, emails: Bool, limit: Int) async -> [[String: Any]]
    /// Open reminders and those completed since `completedSince`.
    func reminders(hidden: Set<String>, details: Bool, completedSince: Date, limit: Int) async -> [[String: Any]]
    /// Applies one change; the id of the item it made or touched.
    func apply(_ change: PhoneChange, window: (from: Date, to: Date)) async throws -> String?
    /// Undoes an addition this phone made (the banner's Undo).
    func removeAdded(itemID: String, isEvent: Bool, window: (from: Date, to: Date)) async throws
    /// The EventKit id of the calendar or list an item is in; nil when it
    /// isn't found.
    func itemCalendar(itemID: String, isEvent: Bool, window: (from: Date, to: Date)) async -> String?
    /// The title of the calendar or list an item would go to.
    func calendarTitle(id: String?, forEvents: Bool) -> String?
    /// The EventKit id behind a shared calendar id, for leaving it out.
    func eventKitCalendarID(forShared id: String) -> String?
    func startObservingChanges(_ handler: @escaping @Sendable () -> Void)
}

/// The async reads run off the main thread; everything else (applying
/// changes, the calendar list, the change observer) is called from the main
/// actor by PhoneSyncEngine and the settings page. The one piece of state
/// both sides touch, the reminder id map, is behind a lock.
final class EventKitPhoneSource: PhoneCalendarSource, @unchecked Sendable {
    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    private let lock = NSLock()
    /// Shared reminder id to EventKit's, from the last read, so applying a
    /// change finds its reminder without fetching them all.
    private var reminderIdentifiers: [String: String] = [:]

    var eventAccess: PhoneCalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .full
        case .writeOnly: return .writeOnly
        default: return .off
        }
    }

    var remindersAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    func requestAccess(calendar: PhoneCalendarAccess, reminders: Bool) async throws {
        switch calendar {
        case .full:
            if eventAccess != .full {
                guard try await store.requestFullAccessToEvents() else { throw PhoneCalendarSourceError.denied }
            }
        case .writeOnly:
            if eventAccess == .off {
                guard try await store.requestWriteOnlyAccessToEvents() else { throw PhoneCalendarSourceError.denied }
            }
        case .off:
            break
        }
        if reminders, !remindersAuthorized {
            guard try await store.requestFullAccessToReminders() else { throw PhoneCalendarSourceError.denied }
        }
    }

    // MARK: Ids

    static func hashed(_ prefix: String, _ parts: String...) -> String {
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1f}").utf8))
        return prefix + String(NotificationE2E.base64URL(Data(digest)).prefix(22))
    }

    static func eventID(_ event: EKEvent) -> String {
        let occurrence = event.occurrenceDate ?? event.startDate ?? Date.distantPast
        return hashed("e_", event.eventIdentifier ?? event.calendarItemIdentifier, String(Int(occurrence.timeIntervalSince1970)))
    }

    static func reminderID(_ reminder: EKReminder) -> String {
        hashed("r_", reminder.calendarItemIdentifier)
    }

    static func calendarID(_ calendar: EKCalendar) -> String {
        hashed("c_", calendar.calendarIdentifier)
    }

    // MARK: Reading

    func calendars(eventsReadable: Bool, reminders: Bool) -> [[String: Any]] {
        var answer: [[String: Any]] = []
        func add(_ calendar: EKCalendar, kind: String, isDefault: Bool) {
            answer.append([
                "id": Self.calendarID(calendar),
                "title": String(calendar.title.prefix(100)),
                "kind": kind,
                "color": Self.hex(calendar.cgColor),
                "source": String((calendar.source?.title ?? "").prefix(60)),
                "writable": calendar.allowsContentModifications,
                // EventKit doesn't say whether a calendar is shared with
                // other people; subscribed ones are read-only anyway.
                "shared": false,
                "default": isDefault,
            ])
        }
        if eventsReadable {
            let defaultID = store.defaultCalendarForNewEvents?.calendarIdentifier
            for calendar in store.calendars(for: .event).prefix(100) {
                add(calendar, kind: "event", isDefault: calendar.calendarIdentifier == defaultID)
            }
        }
        if reminders {
            let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
            for calendar in store.calendars(for: .reminder).prefix(100 - answer.count) {
                add(calendar, kind: "reminder", isDefault: calendar.calendarIdentifier == defaultID)
            }
        }
        return answer
    }

    /// The calendars of a kind the user didn't leave out, by EventKit id.
    private func shownCalendars(_ type: EKEntityType, hidden: Set<String>) -> [EKCalendar] {
        store.calendars(for: type).filter { !hidden.contains($0.calendarIdentifier) }
    }

    /// Async so the fetch runs off the main thread: a wide window on a busy
    /// calendar can take a while.
    func events(from: Date, to: Date, hidden: Set<String>, details: Bool, emails: Bool, limit: Int) async -> [[String: Any]] {
        let calendars = shownCalendars(.event, hidden: hidden)
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
        let found = store.events(matching: predicate).sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
        // Cut after dropping unreadable items, so a full list means the cut was hit.
        return Array(found.lazy.compactMap { Self.json($0, details: details, emails: emails) }.prefix(limit))
    }

    static func json(_ event: EKEvent, details: Bool, emails: Bool) -> [String: Any]? {
        guard let start = event.startDate, let end = event.endDate, let calendar = event.calendar else { return nil }
        let zone = event.timeZone ?? .current
        var value: [String: Any] = [
            "id": eventID(event),
            "calendar_id": calendarID(calendar),
            "title": String((event.title ?? "").prefix(200)),
            "start": PhoneDates.format(start, timeZone: zone),
            "end": PhoneDates.format(end, timeZone: zone),
            "all_day": event.isAllDay,
            "time_zone": zone.identifier,
            "availability": availability(event.availability),
            "status": status(event.status),
            "recurring": event.hasRecurrenceRules,
            "organizer_is_me": event.organizer?.isCurrentUser ?? (event.organizer == nil),
            "my_status": (event.attendees?.first { $0.isCurrentUser }).map { participantStatus($0.participantStatus) } ?? "none",
        ]
        if let location = event.location, !location.isEmpty { value["location"] = String(location.prefix(300)) }
        if let geo = event.structuredLocation?.geoLocation {
            value["lat"] = (geo.coordinate.latitude * 10_000).rounded() / 10_000
            value["lon"] = (geo.coordinate.longitude * 10_000).rounded() / 10_000
        }
        let alarms = (event.alarms ?? []).filter { $0.absoluteDate == nil }.map { max(0, Int(-$0.relativeOffset / 60)) }
        if !alarms.isEmpty { value["alarms_min"] = Array(alarms.prefix(5)) }
        if details {
            if let notes = event.notes, !notes.isEmpty { value["notes"] = String(notes.prefix(PhoneSyncLimits.notesChars)) }
            if let url = Self.sharedURL(event.url) { value["url"] = url }
            let attendees = (event.attendees ?? []).prefix(30).map { person -> [String: Any] in
                var entry: [String: Any] = [
                    "name": String((person.name ?? "").prefix(100)),
                    "status": participantStatus(person.participantStatus),
                    "role": role(person.participantRole),
                ]
                if emails, person.url.scheme?.lowercased() == "mailto" {
                    entry["email"] = String(person.url.absoluteString.dropFirst("mailto:".count).prefix(200))
                }
                return entry
            }
            if !attendees.isEmpty { value["attendees"] = attendees }
        }
        return value
    }

    /// An item's link, left out when it's longer than the host takes: one
    /// over phone_store's MAX_URL_CHARS refuses the whole upload, and a cut
    /// link wouldn't open.
    static func sharedURL(_ url: URL?) -> String? {
        guard let text = url?.absoluteString, text.unicodeScalars.count <= PhoneSyncLimits.urlChars else { return nil }
        return text
    }

    func reminders(hidden: Set<String>, details: Bool, completedSince: Date, limit: Int) async -> [[String: Any]] {
        let calendars = shownCalendars(.reminder, hidden: hidden)
        guard !calendars.isEmpty else { return [] }
        let open = await fetch(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars))
        let done = await fetch(store.predicateForCompletedReminders(withCompletionDateStarting: completedSince, ending: nil, calendars: calendars))
        let all = open + done
        var identifiers: [String: String] = [:]
        for reminder in all { identifiers[Self.reminderID(reminder)] = reminder.calendarItemIdentifier }
        lock.withLock { reminderIdentifiers = identifiers }
        return Array(all.lazy.compactMap { Self.json($0, details: details) }.prefix(limit))
    }

    private func fetch(_ predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            // EventKit can call this more than once; only the first counts.
            let once = ResumeOnce()
            store.fetchReminders(matching: predicate) { found in
                if once.claim() { continuation.resume(returning: found ?? []) }
            }
        }
    }

    static func json(_ reminder: EKReminder, details: Bool) -> [String: Any]? {
        guard let calendar = reminder.calendar else { return nil }
        var value: [String: Any] = [
            "id": reminderID(reminder),
            "list_id": calendarID(calendar),
            "title": String((reminder.title ?? "").prefix(200)),
            "priority": max(0, min(9, reminder.priority)),
            "completed": reminder.isCompleted,
            "recurring": reminder.hasRecurrenceRules,
        ]
        if let parts = reminder.dueDateComponents {
            let allDay = parts.hour == nil
            var calendarForDue = Calendar(identifier: .gregorian)
            calendarForDue.timeZone = parts.timeZone ?? .current
            if allDay, let year = parts.year, let month = parts.month, let day = parts.day {
                value["due"] = String(format: "%04d-%02d-%02d", year, month, day)
                value["due_all_day"] = true
            } else if let date = calendarForDue.date(from: parts) {
                value["due"] = PhoneDates.format(date, timeZone: calendarForDue.timeZone)
                value["due_all_day"] = false
            }
        }
        if let completed = reminder.completionDate { value["completed_at"] = PhoneDates.format(completed) }
        if let alarm = reminder.alarms?.first(where: { $0.structuredLocation != nil && $0.proximity != EKAlarmProximity.none }),
           let place = alarm.structuredLocation {
            value["location_alarm"] = ["name": String(place.title?.prefix(100) ?? ""),
                                       "proximity": alarm.proximity == .enter ? "arrive" : "leave"]
        }
        if details {
            if let notes = reminder.notes, !notes.isEmpty { value["notes"] = String(notes.prefix(PhoneSyncLimits.notesChars)) }
            if let url = Self.sharedURL(reminder.url) { value["url"] = url }
        }
        return value
    }

    // MARK: Writing

    func calendarTitle(id: String?, forEvents: Bool) -> String? {
        if let calendar = calendar(id: id, type: forEvents ? .event : .reminder) { return calendar.title }
        return forEvents ? store.defaultCalendarForNewEvents?.title : store.defaultCalendarForNewReminders()?.title
    }

    func eventKitCalendarID(forShared id: String) -> String? {
        (store.calendars(for: .event) + store.calendars(for: .reminder)).first { Self.calendarID($0) == id }?.calendarIdentifier
    }

    private func calendar(id: String?, type: EKEntityType) -> EKCalendar? {
        guard let id else { return nil }
        return store.calendars(for: type).first { Self.calendarID($0) == id }
    }

    private func findEvent(_ id: String, window: (from: Date, to: Date)) throws -> EKEvent {
        guard eventAccess == .full else { throw PhoneCalendarSourceError.writeOnly }
        // Wider than what's shared: the agent may have read it a day ago.
        let from = window.from.addingTimeInterval(-30 * 86_400), to = window.to.addingTimeInterval(30 * 86_400)
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        guard let event = store.events(matching: predicate).first(where: { Self.eventID($0) == id }) else {
            throw PhoneCalendarSourceError.notFound
        }
        return event
    }

    private func findReminder(_ id: String) async throws -> EKReminder {
        guard remindersAuthorized else { throw PhoneCalendarSourceError.denied }
        let known = lock.withLock { reminderIdentifiers[id] }
        if let known, let reminder = store.calendarItem(withIdentifier: known) as? EKReminder, Self.reminderID(reminder) == id {
            return reminder
        }
        let all = await fetch(store.predicateForReminders(in: nil))
        guard let reminder = all.first(where: { Self.reminderID($0) == id }) else { throw PhoneCalendarSourceError.notFound }
        return reminder
    }

    func apply(_ change: PhoneChange, window: (from: Date, to: Date)) async throws -> String? {
        let fields = change.fields
        let span: EKSpan = change.span == "future" ? .futureEvents : .thisEvent
        // Saying "applied" without the place alert would be untrue.
        if !change.kind.isEvent, fields.locationAlarmName != nil { throw PhoneCalendarSourceError.locationAlarm }
        switch change.kind {
        case .addEvent:
            guard eventAccess != .off else { throw PhoneCalendarSourceError.denied }
            let event = EKEvent(eventStore: store)
            guard let target = calendar(id: fields.calendarID, type: .event) ?? store.defaultCalendarForNewEvents else {
                throw PhoneCalendarSourceError.notFound
            }
            guard target.allowsContentModifications else { throw PhoneCalendarSourceError.readOnly }
            event.calendar = target
            fill(event, with: fields, isNew: true)
            try store.save(event, span: .thisEvent, commit: true)
            return eventAccess == .full ? Self.eventID(event) : nil
        case .updateEvent:
            let event = try findEvent(change.eventID ?? "", window: window)
            guard event.calendar?.allowsContentModifications ?? false else { throw PhoneCalendarSourceError.readOnly }
            if let moved = try Self.moveDestination(fields.calendarID, find: { calendar(id: $0, type: .event) }, isWritable: \.allowsContentModifications) {
                event.calendar = moved
            }
            fill(event, with: fields, isNew: false)
            try store.save(event, span: span, commit: true)
            return Self.eventID(event)
        case .deleteEvent:
            let event = try findEvent(change.eventID ?? "", window: window)
            guard event.calendar?.allowsContentModifications ?? false else { throw PhoneCalendarSourceError.readOnly }
            let id = Self.eventID(event)
            try store.remove(event, span: span, commit: true)
            return id
        case .addReminder:
            guard remindersAuthorized else { throw PhoneCalendarSourceError.denied }
            let reminder = EKReminder(eventStore: store)
            guard let list = calendar(id: fields.listID, type: .reminder) ?? store.defaultCalendarForNewReminders() else {
                throw PhoneCalendarSourceError.notFound
            }
            guard list.allowsContentModifications else { throw PhoneCalendarSourceError.readOnly }
            reminder.calendar = list
            fill(reminder, with: fields)
            try store.save(reminder, commit: true)
            return Self.reminderID(reminder)
        case .updateReminder, .completeReminder:
            let reminder = try await findReminder(change.reminderID ?? "")
            guard reminder.calendar?.allowsContentModifications ?? false else { throw PhoneCalendarSourceError.readOnly }
            if change.kind == .completeReminder {
                reminder.isCompleted = fields.completed ?? true
            } else {
                if let moved = try Self.moveDestination(fields.listID, find: { calendar(id: $0, type: .reminder) }, isWritable: \.allowsContentModifications) {
                    reminder.calendar = moved
                }
                fill(reminder, with: fields)
            }
            try store.save(reminder, commit: true)
            return Self.reminderID(reminder)
        case .deleteReminder:
            let reminder = try await findReminder(change.reminderID ?? "")
            guard reminder.calendar?.allowsContentModifications ?? false else { throw PhoneCalendarSourceError.readOnly }
            let id = Self.reminderID(reminder)
            try store.remove(reminder, commit: true)
            return id
        case .setAlarm, .setTimer, .cancelAlarm:
            // Alarms go to PhoneAlarmSource, never here.
            throw PhoneCalendarSourceError.notFound
        }
    }

    private func fill(_ event: EKEvent, with fields: PhoneChangeFields, isNew: Bool) {
        if let title = fields.title { event.title = title }
        let allDay = fields.allDay ?? (isNew ? false : event.isAllDay)
        event.isAllDay = allDay
        if let start = fields.start {
            let length = event.endDate.flatMap { end in event.startDate.map { end.timeIntervalSince($0) } } ?? 3600
            event.startDate = start
            if fields.end == nil {
                event.endDate = allDay ? Self.allDayEnd(start: start, previousLength: length, calendar: .current) : start.addingTimeInterval(max(length, 0))
            }
        }
        if let end = fields.end { event.endDate = end }
        if isNew, event.endDate == nil, let start = event.startDate {
            event.endDate = allDay ? Self.allDayEnd(start: start, previousLength: nil, calendar: .current) : start.addingTimeInterval(3600)
        }
        if let location = fields.location { event.location = location }
        if let notes = fields.notes { event.notes = notes }
        if let url = fields.url { event.url = url }
        if let minutes = fields.alarmsMinutes {
            event.alarms = minutes.prefix(3).map { EKAlarm(relativeOffset: TimeInterval(-$0 * 60)) }
        }
    }

    /// Where an update moves an item: nil when it names no calendar or
    /// list. One that's gone or can't be changed fails the update rather
    /// than saving the rest in the old place and reporting it applied. An add
    /// instead falls back to the default calendar or list when the named
    /// one is gone; only a read-only one fails it.
    static func moveDestination<Destination>(_ id: String?, find: (String) -> Destination?, isWritable: (Destination) -> Bool) throws -> Destination? {
        guard let id else { return nil }
        guard let found = find(id) else { throw PhoneCalendarSourceError.notFound }
        guard isWritable(found) else { throw PhoneCalendarSourceError.readOnly }
        return found
    }

    /// An all-day event's end: whole calendar days after the day it starts
    /// (its previous length rounded to days, at least one). Days, not
    /// seconds: a day with a clock change has 23 or 25 hours, and 86 400 s
    /// from its midnight lands in the next date.
    static func allDayEnd(start: Date, previousLength: TimeInterval?, calendar: Calendar) -> Date {
        let days = max(1, Int(((previousLength ?? 86_400) / 86_400).rounded()))
        let day = calendar.startOfDay(for: start)
        return calendar.date(byAdding: .day, value: days, to: day) ?? day.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    private func fill(_ reminder: EKReminder, with fields: PhoneChangeFields) {
        if let title = fields.title { reminder.title = title }
        if let notes = fields.notes { reminder.notes = notes }
        if let url = fields.url { reminder.url = url }
        if let priority = fields.priority { reminder.priority = max(0, min(9, priority)) }
        if let due = fields.due {
            let allDay = fields.dueAllDay ?? (fields.dueText?.count == 10)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let oldDue = Self.timedDue(reminder.dueDateComponents, calendar: calendar)
            var newDue: Date?
            if allDay {
                reminder.dueDateComponents = calendar.dateComponents([.year, .month, .day], from: due)
            } else {
                var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                parts.timeZone = calendar.timeZone
                reminder.dueDateComponents = parts
                // On the minute, as the due date is kept.
                newDue = calendar.date(from: parts) ?? due
            }
            let alarms = Self.dueAlarms(reminder.alarms ?? [], oldDue: oldDue, newDue: newDue)
            reminder.alarms = alarms.isEmpty ? nil : alarms
        }
    }

    /// When a reminder with a due time is due; nil for none or a date only.
    static func timedDue(_ parts: DateComponents?, calendar: Calendar) -> Date? {
        guard let parts, parts.hour != nil else { return nil }
        var calendar = calendar
        if let zone = parts.timeZone { calendar.timeZone = zone }
        return calendar.date(from: parts)
    }

    /// A reminder's alarms after its due date moves. Only the due alarm
    /// (the one alarm at the old due time, as the Reminders app and Conduit
    /// both set it) moves with it; the user's own alarms (a place, another
    /// time, an offset, a second one near the due time) stay. A timed due
    /// date rings from the Reminders app, host or not, so it gets a due
    /// alarm unless one is already set for then; a date-only one gets none.
    /// Offsets count in neither check: EventKit measures them from a start
    /// date the reminder need not share with its due date.
    static func dueAlarms(_ alarms: [EKAlarm], oldDue: Date?, newDue: Date?) -> [EKAlarm] {
        // How far a time alarm is from a due time, within the minute the
        // due components keep; nil for any other alarm.
        func gap(_ alarm: EKAlarm, _ date: Date) -> TimeInterval? {
            guard alarm.structuredLocation == nil, let at = alarm.absoluteDate else { return nil }
            let gap = abs(at.timeIntervalSince(date))
            return gap < 60 ? gap : nil
        }
        var kept = alarms
        if let oldDue {
            let near = kept.indices.compactMap { index in gap(kept[index], oldDue).map { (index, $0) } }
            if let due = near.min(by: { $0.1 < $1.1 }) { kept.remove(at: due.0) }
        }
        if let newDue, !kept.contains(where: { gap($0, newDue) != nil }) {
            kept.append(EKAlarm(absoluteDate: newDue))
        }
        return kept
    }

    func removeAdded(itemID: String, isEvent: Bool, window: (from: Date, to: Date)) async throws {
        if isEvent {
            let event = try findEvent(itemID, window: window)
            try store.remove(event, span: .thisEvent, commit: true)
        } else {
            let reminder = try await findReminder(itemID)
            try store.remove(reminder, commit: true)
        }
    }

    func itemCalendar(itemID: String, isEvent: Bool, window: (from: Date, to: Date)) async -> String? {
        if isEvent { return (try? findEvent(itemID, window: window))?.calendar?.calendarIdentifier }
        return (try? await findReminder(itemID))?.calendar?.calendarIdentifier
    }

    func startObservingChanges(_ handler: @escaping @Sendable () -> Void) {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: nil) { _ in
            handler()
        }
    }

    // MARK: Spelling

    private static func hex(_ color: CGColor?) -> String {
        guard let color, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let components = color.converted(to: space, intent: .defaultIntent, options: nil)?.components,
              components.count >= 3 else { return "#888888" }
        let value = components.prefix(3).map { Int((max(0, min(1, $0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", value[0], value[1], value[2])
    }

    private static func availability(_ value: EKEventAvailability) -> String {
        switch value {
        case .busy: return "busy"
        case .free: return "free"
        case .tentative: return "tentative"
        case .unavailable: return "unavailable"
        default: return "none"
        }
    }

    private static func status(_ value: EKEventStatus) -> String {
        switch value {
        case .confirmed: return "confirmed"
        case .tentative: return "tentative"
        case .canceled: return "canceled"
        default: return "none"
        }
    }

    private static func participantStatus(_ value: EKParticipantStatus) -> String {
        switch value {
        case .accepted: return "accepted"
        case .declined: return "declined"
        case .tentative: return "tentative"
        case .pending: return "pending"
        default: return "none"
        }
    }

    private static func role(_ value: EKParticipantRole) -> String {
        switch value {
        case .required: return "required"
        case .optional: return "optional"
        case .chair: return "chair"
        case .nonParticipant: return "non_participant"
        default: return "unknown"
        }
    }
}

/// Lets a callback that may run more than once resume a continuation once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
