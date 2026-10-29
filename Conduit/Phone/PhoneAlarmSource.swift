//
//  PhoneAlarmSource.swift
//  Conduit
//
//  Alarms and timers Hermes sets on this iPhone, through iOS 26's AlarmKit.
//  They ring like the Clock app's, through Silent mode and Focus, which is
//  why the user turns them on separately and approves each one unless they
//  chose "Add without asking". A timer is an alarm at a fixed time (now plus
//  its length), so it needs no Live Activity. Hermes sees only the alarms
//  Conduit set, as the `alarms` list (phone-v1-contract.md section 6), with
//  the names Conduit remembers for them: AlarmKit doesn't hand names back.
//

import Foundation
import SwiftUI
#if canImport(AlarmKit)
import AlarmKit
#endif

enum PhoneAlarmError: LocalizedError {
    case unsupported
    case unavailable
    case denied
    case past
    case notFound

    var errorDescription: String? {
        switch self {
        case .unsupported: return AppLocalization.string("Alarms from Hermes need iOS 26 or later.")
        case .unavailable: return AppLocalization.string("Alarms couldn't be reached just now. Try again.")
        case .denied: return AppLocalization.string("Conduit isn't allowed to set alarms. Allow it in the Settings app.")
        case .past: return AppLocalization.string("That alarm time has already passed.")
        case .notFound: return AppLocalization.string("That alarm isn't on this iPhone any more.")
        }
    }
}

/// Setting and listing alarms; a fake stands in for tests.
protocol PhoneAlarmSource: AnyObject {
    /// This iOS has AlarmKit.
    var isSupported: Bool { get }
    var authorized: Bool { get }
    /// Asks iOS (once); throws when the user said no.
    func requestAccess() async throws
    /// The alarms and timers Conduit set that are still on the phone, as the
    /// host takes them: `{id, kind, label?, fires_at?, repeats?, state?}`.
    /// Nil when AlarmKit couldn't be read: nothing is known, so nothing is
    /// forgotten or sent.
    func alarms(now: Date, calendar: Calendar) -> [[String: Any]]?
    /// Applies a `set_alarm`, `set_timer` or `cancel_alarm`; the alarm's id.
    func apply(_ change: PhoneChange, now: Date) async throws -> String
    /// Takes back an alarm Conduit set (the banner's Undo).
    func cancel(id: String) throws
}

/// What Conduit remembers about each alarm it set, by AlarmKit id.
struct PhoneAlarmRecord: Codable, Equatable {
    var kind: String
    var label: String?
    var repeats: [String]?

    static let storageKey = "conduit.phoneSync.alarms.v1"
    static let maximum = 50

    static func load(from defaults: UserDefaults) -> [String: PhoneAlarmRecord] {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([String: PhoneAlarmRecord].self, from: $0) } ?? [:]
    }

    static func save(_ records: [String: PhoneAlarmRecord], to defaults: UserDefaults) {
        guard !records.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

enum PhoneAlarmSources {
    /// AlarmKit on iOS 26, a source that can't set anything before it. The
    /// iPad app on a Vision Pro reports iOS 26 but has no AlarmKit: its
    /// weak-linked `AlarmManager.shared` is address 0 there, and calling it
    /// crashed at launch.
    static func system(
        defaults: UserDefaults = .standard,
        hasAlarmKit: Bool? = nil
    ) -> PhoneAlarmSource {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *), hasAlarmKit ?? alarmKitLoaded {
            return AlarmKitPhoneSource(defaults: defaults)
        }
        #endif
        return UnsupportedPhoneAlarmSource()
    }

    /// Whether `AlarmManager.shared`'s getter is bound in this process: the
    /// symbol AlarmKit.tbd lists for it.
    static var alarmKitLoaded: Bool {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "$s8AlarmKit0A7ManagerC6sharedACvgZ") != nil
    }

    /// The next time a clock-time alarm rings after `now`.
    static func nextRing(_ time: PhoneClockTime, repeats: [String]?, after now: Date, calendar: Calendar) -> Date? {
        let days = repeats ?? []
        guard !days.isEmpty else {
            return calendar.nextDate(after: now, matching: DateComponents(hour: time.hour, minute: time.minute, second: 0),
                                     matchingPolicy: .nextTime)
        }
        return days.compactMap { day -> Date? in
            guard let index = PhoneChangeFields.weekdays.firstIndex(of: day) else { return nil }
            // Calendar weekdays run Sunday = 1 … Saturday = 7.
            let weekday = (index + 1) % 7 + 1
            return calendar.nextDate(after: now, matching: DateComponents(hour: time.hour, minute: time.minute, second: 0,
                                                                            weekday: weekday),
                                     matchingPolicy: .nextTime)
        }.min()
    }
}

final class UnsupportedPhoneAlarmSource: PhoneAlarmSource {
    var isSupported: Bool { false }
    var authorized: Bool { false }
    func requestAccess() async throws { throw PhoneAlarmError.unsupported }
    func alarms(now: Date, calendar: Calendar) -> [[String: Any]]? { [] }
    func apply(_ change: PhoneChange, now: Date) async throws -> String { throw PhoneAlarmError.unsupported }
    func cancel(id: String) throws { throw PhoneAlarmError.unsupported }
}

#if canImport(AlarmKit)
/// AlarmKit needs a metadata type; Conduit's alarms carry none.
@available(iOS 26.0, *)
struct ConduitAlarmMetadata: AlarmMetadata {}

@available(iOS 26.0, *)
final class AlarmKitPhoneSource: PhoneAlarmSource {
    /// Read when used, not when made.
    private var manager: AlarmManager { AlarmManager.shared }
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var isSupported: Bool { true }
    var authorized: Bool { manager.authorizationState == .authorized }

    func requestAccess() async throws {
        switch manager.authorizationState {
        case .authorized: return
        case .denied: throw PhoneAlarmError.denied
        default:
            guard try await manager.requestAuthorization() == .authorized else { throw PhoneAlarmError.denied }
        }
    }

    func alarms(now: Date, calendar: Calendar) -> [[String: Any]]? {
        guard authorized else { return [] }
        // A failed read isn't an empty list: the labels would be lost for good.
        guard let scheduled = try? manager.alarms else { return nil }
        var records = PhoneAlarmRecord.load(from: defaults)
        // Forget the ones that rang and went, or were deleted in Clock.
        let live = Set(scheduled.map { $0.id.uuidString.lowercased() })
        let kept = records.filter { live.contains($0.key) }
        if kept.count != records.count {
            records = kept
            PhoneAlarmRecord.save(records, to: defaults)
        }
        return scheduled.prefix(PhoneAlarmRecord.maximum).map { alarm in
            let id = alarm.id.uuidString.lowercased()
            let record = records[id]
            var entry: [String: Any] = ["id": id, "kind": record?.kind ?? "alarm"]
            if let label = record?.label { entry["label"] = label }
            if let ring = Self.nextRing(alarm.schedule, now: now, calendar: calendar) {
                entry["fires_at"] = PhoneDates.format(ring)
            }
            if let repeats = record?.repeats { entry["repeats"] = repeats }
            switch alarm.state {
            case .scheduled: entry["state"] = "scheduled"
            case .countdown: entry["state"] = "countdown"
            case .paused: entry["state"] = "paused"
            case .alerting: entry["state"] = "alerting"
            @unknown default: break
            }
            return entry
        }
    }

    private static func nextRing(_ schedule: Alarm.Schedule?, now: Date, calendar: Calendar) -> Date? {
        switch schedule {
        case .fixed(let date):
            return date
        case .relative(let relative):
            let time = PhoneClockTime(hour: relative.time.hour, minute: relative.time.minute)
            var days: [String]?
            if case .weekly(let weekdays) = relative.repeats {
                days = weekdays.map(Self.name)
            }
            return PhoneAlarmSources.nextRing(time, repeats: days, after: now, calendar: calendar)
        default:
            return nil
        }
    }

    func apply(_ change: PhoneChange, now: Date) async throws -> String {
        guard authorized else { throw PhoneAlarmError.denied }
        let fields = change.fields
        switch change.kind {
        case .cancelAlarm:
            let id = change.alarmID?.lowercased() ?? ""
            try cancel(id: id)
            return id
        case .setTimer:
            // PhoneChange already refuses a timer outside this range.
            guard let seconds = fields.seconds, (5...86_400).contains(seconds) else { throw PhoneAlarmError.notFound }
            let label = fields.label ?? AppLocalization.string("Timer")
            return try await schedule(.fixed(now.addingTimeInterval(TimeInterval(seconds))), label: label,
                                      record: PhoneAlarmRecord(kind: "timer", label: fields.label))
        case .setAlarm:
            let label = fields.label ?? AppLocalization.string("Alarm")
            if let at = fields.at {
                guard at > now else { throw PhoneAlarmError.past }
                return try await schedule(.fixed(at), label: label, record: PhoneAlarmRecord(kind: "alarm", label: fields.label))
            }
            guard let time = fields.time else { throw PhoneAlarmError.notFound }
            let days = fields.repeats ?? []
            let repeats: Alarm.Schedule.Relative.Recurrence = days.isEmpty ? .never : .weekly(days.compactMap(Self.weekday))
            let relative = Alarm.Schedule.Relative(time: .init(hour: time.hour, minute: time.minute), repeats: repeats)
            return try await schedule(.relative(relative), label: label,
                                      record: PhoneAlarmRecord(kind: "alarm", label: fields.label, repeats: fields.repeats))
        default:
            throw PhoneAlarmError.notFound
        }
    }

    private func schedule(_ schedule: Alarm.Schedule, label: String, record: PhoneAlarmRecord) async throws -> String {
        let stop = AlarmButton(text: LocalizedStringResource("Stop"), textColor: .white, systemImageName: "stop.circle")
        // The label is the user's (or Hermes') own words, so it goes in as an
        // argument: the key is just "%@" (in a table that doesn't exist), and
        // the label shows as typed even when it matches a key such as "Timer"
        // or holds a "%".
        let title = LocalizedStringResource("\(label)", table: "Verbatim")
        let alert = AlarmPresentation.Alert(title: title, stopButton: stop)
        let attributes = AlarmAttributes<ConduitAlarmMetadata>(presentation: AlarmPresentation(alert: alert),
                                                              metadata: ConduitAlarmMetadata(), tintColor: .orange)
        let configuration = AlarmManager.AlarmConfiguration<ConduitAlarmMetadata>(schedule: schedule, attributes: attributes)
        let id = UUID()
        _ = try await manager.schedule(id: id, configuration: configuration)
        let key = id.uuidString.lowercased()
        var records = PhoneAlarmRecord.load(from: defaults)
        records[key] = record
        PhoneAlarmRecord.save(records, to: defaults)
        return key
    }

    func cancel(id: String) throws {
        guard let uuid = UUID(uuidString: id) else { throw PhoneAlarmError.notFound }
        // A failed read isn't "gone": the alarm may still ring.
        guard let scheduled = try? manager.alarms else { throw PhoneAlarmError.unavailable }
        guard scheduled.contains(where: { $0.id == uuid }) else { throw PhoneAlarmError.notFound }
        try manager.cancel(id: uuid)
        var records = PhoneAlarmRecord.load(from: defaults)
        records[id.lowercased()] = nil
        PhoneAlarmRecord.save(records, to: defaults)
    }

    private static func weekday(_ name: String) -> Locale.Weekday? {
        switch name {
        case "mon": return .monday
        case "tue": return .tuesday
        case "wed": return .wednesday
        case "thu": return .thursday
        case "fri": return .friday
        case "sat": return .saturday
        case "sun": return .sunday
        default: return nil
        }
    }

    private static func name(_ weekday: Locale.Weekday) -> String {
        switch weekday {
        case .monday: return "mon"
        case .tuesday: return "tue"
        case .wednesday: return "wed"
        case .thursday: return "thu"
        case .friday: return "fri"
        case .saturday: return "sat"
        default: return "sun"
        }
    }
}
#endif
