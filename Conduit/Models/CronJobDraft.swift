//
//  CronJobDraft.swift
//  Conduit
//
//  What the scheduled-job editor holds while a job is created or changed
//  (#819): its name, prompt, delivery and a schedule in the shapes people
//  pick ("8:00 on weekdays", "every 2 hours", "once on Friday at 9:00"),
//  turned into a string Hermes' parse_schedule reads. Also the server's
//  blueprint catalog and delivery targets the editor offers.
//

import Foundation

/// A schedule as the editor shows it. `scheduleString` is what Hermes is
/// sent: a cron expression, "every 30m", an ISO timestamp, or the text as
/// typed.
struct CronScheduleDraft: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        /// A time of day on chosen days of the week.
        case time
        /// Every N minutes, hours or days.
        case interval
        /// One run at a date and time.
        case once
        /// Any other schedule Hermes reads, typed as is.
        case custom

        var id: String { rawValue }
    }

    enum IntervalUnit: String, CaseIterable, Identifiable {
        case minutes, hours, days

        var id: String { rawValue }
        var minutes: Int {
            switch self {
            case .minutes: 1
            case .hours: 60
            case .days: 1_440
            }
        }
        /// parse_duration's suffix.
        fileprivate var suffix: String {
            switch self {
            case .minutes: "m"
            case .hours: "h"
            case .days: "d"
            }
        }
    }

    var mode: Mode = .time
    /// The schedule's wall clock: the profile zone Hermes runs schedules in.
    var hour = 8
    var minute = 0
    /// Days of the week, Sunday as 0; all seven is every day.
    var days: Set<Int> = Set(0...6)
    var intervalValue = 1
    var intervalUnit: IntervalUnit = .hours
    var runAt = Date().addingTimeInterval(60 * 60)
    var custom = ""

    static let everyDay: Set<Int> = Set(0...6)
    static let weekdays: Set<Int> = Set(1...5)
    static let weekends: Set<Int> = [0, 6]

    init() {}

    /// A job's schedule in the editor's shapes; anything else is kept as
    /// custom text so saving unchanged leaves it alone.
    init(schedule: CronSchedule?, display: String?) {
        let kind = schedule?.kind?.lowercased()
        if kind == "interval", let minutes = schedule?.minutes, minutes > 0 {
            mode = .interval
            if minutes % IntervalUnit.days.minutes == 0 {
                intervalUnit = .days
            } else if minutes % IntervalUnit.hours.minutes == 0 {
                intervalUnit = .hours
            } else {
                intervalUnit = .minutes
            }
            intervalValue = minutes / intervalUnit.minutes
            return
        }
        if kind == "once", let raw = schedule?.runAt, let date = CronScheduleText.parseDate(raw) {
            mode = .once
            runAt = date
            return
        }
        let expression = schedule?.expr ?? schedule?.display ?? display ?? ""
        if let parsed = Self.timeOfDay(expression) {
            mode = .time
            (hour, minute, days) = parsed
            return
        }
        mode = .custom
        custom = expression
    }

    /// "M H * * D" with a plain minute and hour, as (hour, minute, days).
    static func timeOfDay(_ expression: String) -> (Int, Int, Set<Int>)? {
        let fields = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5, fields[2] == "*", fields[3] == "*",
              let minute = Int(fields[0]), (0...59).contains(minute),
              let hour = Int(fields[1]), (0...23).contains(hour) else { return nil }
        if fields[4] == "*" { return (hour, minute, everyDay) }
        guard let days = CronScheduleText.weekdays(fields[4]) else { return nil }
        return (hour, minute, days)
    }

    /// The day-of-week field: "*", "1-5", or a list.
    private var dayOfWeekField: String {
        if days == Self.everyDay { return "*" }
        if days == Self.weekdays { return "1-5" }
        return days.sorted().map(String.init).joined(separator: ",")
    }

    private static let runAtFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()

    /// What Hermes is sent, or nil while the draft isn't a schedule yet (no
    /// day picked, no interval, nothing typed).
    var scheduleString: String? {
        switch mode {
        case .time:
            guard !days.isEmpty else { return nil }
            return "\(minute) \(hour) * * \(dayOfWeekField)"
        case .interval:
            guard intervalValue > 0 else { return nil }
            return "every \(intervalValue)\(intervalUnit.suffix)"
        case .once:
            // An instant with this iPhone's offset, so the profile's zone
            // doesn't move it.
            var seconds = runAt.timeIntervalSinceReferenceDate
            seconds -= seconds.truncatingRemainder(dividingBy: 60)
            return Self.runAtFormatter.string(from: Date(timeIntervalSinceReferenceDate: seconds))
        case .custom:
            let text = custom.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    /// The draft as Hermes would parse it, for the plain-words preview.
    var previewSchedule: CronSchedule? {
        guard let text = scheduleString else { return nil }
        switch mode {
        case .time, .custom: return CronSchedule(expr: text, kind: "cron")
        case .interval: return CronSchedule(kind: "interval", minutes: intervalValue * intervalUnit.minutes)
        case .once: return CronSchedule(kind: "once", runAt: text)
        }
    }
}

/// The editor's whole form: a new job's POST body, or only the fields that
/// changed for an edit's PUT, so whatever the form doesn't show (skills,
/// model, script) stays as it is.
struct CronJobDraft: Equatable {
    var name = ""
    var prompt = ""
    var schedule = CronScheduleDraft()
    var deliver = "local"
    /// A job that runs a script or no agent can do without a prompt.
    var promptOptional = false

    init() {}

    init(job: CronJob) {
        name = job.name ?? ""
        prompt = job.prompt ?? ""
        schedule = CronScheduleDraft(schedule: job.schedule, display: job.scheduleDisplay)
        deliver = job.deliver.flatMap { $0.isEmpty ? nil : $0 } ?? "local"
        promptOptional = job.noAgent == true || job.script?.isEmpty == false
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canSave: Bool {
        schedule.scheduleString != nil && (promptOptional || !trimmedPrompt.isEmpty)
    }

    /// POST /api/cron/jobs.
    var createBody: [String: Any]? {
        guard canSave, let scheduleString = schedule.scheduleString else { return nil }
        return [
            "name": trimmedName,
            "prompt": trimmedPrompt,
            "schedule": scheduleString,
            "deliver": deliver
        ]
    }

    /// PUT /api/cron/jobs/<id>'s `updates`: what differs from `original`.
    func updates(from original: CronJobDraft) -> [String: Any] {
        var updates: [String: Any] = [:]
        if trimmedName != original.trimmedName { updates["name"] = trimmedName }
        if trimmedPrompt != original.trimmedPrompt { updates["prompt"] = trimmedPrompt }
        if let scheduleString = schedule.scheduleString, scheduleString != original.schedule.scheduleString {
            updates["schedule"] = scheduleString
        }
        if deliver != original.deliver { updates["deliver"] = deliver }
        return updates
    }
}

/// Where a job's output goes: `local` (saved only) or a connected
/// platform's home channel.
struct CronDeliveryTarget: Identifiable, Equatable {
    let id: String
    let name: String
    /// False when the platform has no home channel to deliver to yet.
    let homeTargetSet: Bool

    init(id: String, name: String, homeTargetSet: Bool = true) {
        self.id = id
        self.name = name
        self.homeTargetSet = homeTargetSet
    }

    init?(_ value: Any) {
        guard let dict = value as? [String: Any], let id = dict["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        name = (dict["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
        homeTargetSet = dict["home_target_set"] as? Bool ?? true
    }

    /// The choices for a picker: the targets Hermes lists, with the job's
    /// current one kept when Hermes doesn't list it ("origin", a chat id).
    static func choices(_ targets: [CronDeliveryTarget], keeping current: String) -> [CronDeliveryTarget] {
        let listed = targets.isEmpty ? [CronDeliveryTarget(id: "local", name: "local")] : targets
        if current.isEmpty || listed.contains(where: { $0.id == current }) { return listed }
        return listed + [CronDeliveryTarget(id: current, name: current)]
    }
}

/// One of Hermes' automation blueprints (GET /api/cron/blueprints): a ready
/// job with a few blanks to fill, instantiated by the server.
struct CronBlueprint: Identifiable, Equatable {
    struct Field: Identifiable, Equatable {
        enum Kind: String {
            /// "HH:MM", 24 hours.
            case time
            /// One of `options` (Hermes' "enum").
            case choice = "enum"
            case text
            /// everyday, weekdays or weekends.
            case weekdays
        }

        let name: String
        let kind: Kind
        let label: String
        let defaultValue: String
        let options: [String]
        let optional: Bool
        let help: String

        var id: String { name }
    }

    let key: String
    let title: String
    let summary: String
    let category: String
    /// Hermes' own wording of the default schedule ("weekdays at 08:00").
    let scheduleText: String
    let fields: [Field]

    var id: String { key }

    init?(_ value: Any) {
        guard let dict = value as? [String: Any], let key = dict["key"] as? String, !key.isEmpty else { return nil }
        self.key = key
        title = (dict["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key
        summary = dict["description"] as? String ?? ""
        category = dict["category"] as? String ?? ""
        scheduleText = dict["scheduleHuman"] as? String ?? ""
        // A gateway blueprint can repeat a field name; keep the first so
        // `defaultValues` never traps and the form's field identities stay unique.
        var seenFieldNames = Set<String>()
        fields = (dict["fields"] as? [Any] ?? []).compactMap { raw in
            guard let field = raw as? [String: Any], let name = field["name"] as? String,
                  let kind = Field.Kind(rawValue: field["type"] as? String ?? ""),
                  seenFieldNames.insert(name).inserted else { return nil }
            return Field(
                name: name,
                kind: kind,
                label: (field["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name,
                defaultValue: Self.text(field["default"]),
                options: (field["options"] as? [Any] ?? []).map(Self.text).filter { !$0.isEmpty },
                optional: field["optional"] as? Bool ?? false,
                help: field["help"] as? String ?? ""
            )
        }
    }

    private static func text(_ value: Any?) -> String {
        switch value {
        case let string as String: string
        case let number as NSNumber: number.stringValue
        default: ""
        }
    }

    /// Each field's starting value.
    var defaultValues: [String: String] {
        Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.defaultValue) })
    }

    /// The `values` to instantiate with: blanks left out, so an optional
    /// field stays unset and a required one gets Hermes' own message.
    static func instantiateValues(_ values: [String: String], fields: [Field]) -> [String: String] {
        var result: [String: String] = [:]
        for field in fields {
            let value = (values[field.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result[field.name] = value }
        }
        return result
    }

    /// "HH:MM" as hour and minute.
    static func clock(_ value: String) -> (hour: Int, minute: Int)? {
        let parts = value.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    static func clockText(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }
}
