//
//  CronScheduleText.swift
//  Conduit
//
//  What the Scheduled list says about a job: its schedule in plain words
//  ("Weekdays at 8:00 AM") instead of the cron expression Hermes keeps
//  ("0 8 * * 1-5"), and when it runs next. Hermes evaluates a schedule in
//  the profile's configured `timezone`, not this iPhone's, so a schedule
//  names that zone when it differs (ProfileTimeZone.scheduleZoneLabel).
//  Anything it doesn't recognize keeps Hermes' own wording.
//

import Foundation

enum CronScheduleText {
    // MARK: Schedule

    /// The schedule line for a job: plain words when the pattern is a common
    /// one, otherwise what Hermes displays. `zoneLabel` is the profile zone
    /// to name next to a wall-clock time.
    static func describe(_ job: CronJob, zoneLabel: String?, locale: Locale = AppLocalization.formattingLocale) -> String? {
        if let schedule = job.schedule, let text = describe(schedule, zoneLabel: zoneLabel, locale: locale) {
            return text
        }
        if let display = job.scheduleDisplay ?? job.schedule?.display ?? job.schedule?.expr {
            // An older Hermes sends only the display text, which for a cron
            // job is the expression itself.
            if let text = describe(expression: display, locale: locale) {
                return withZone(text, zoneLabel: zoneLabel, isWallClock: true)
            }
            return display
        }
        return nil
    }

    static func describe(_ schedule: CronSchedule, zoneLabel: String?, locale: Locale = AppLocalization.formattingLocale) -> String? {
        switch schedule.kind?.lowercased() {
        case "interval":
            if let minutes = schedule.minutes, minutes > 0 { return describe(intervalMinutes: minutes) }
        case "once":
            if let raw = schedule.runAt, let date = parseDate(raw) {
                // An instant: shown in this iPhone's time, so no zone label.
                return AppLocalization.string("Once, \(absoluteDateText(date, locale: locale))")
            }
        default:
            if let expr = schedule.expr ?? schedule.display, let text = describe(expression: expr, locale: locale) {
                return withZone(text, zoneLabel: zoneLabel, isWallClock: true)
            }
        }
        return nil
    }

    /// Hermes' "every N minutes" schedules.
    static func describe(intervalMinutes minutes: Int) -> String {
        if minutes == 1 { return AppLocalization.string("Every minute") }
        if minutes == 60 { return AppLocalization.string("Every hour") }
        if minutes == 1_440 { return AppLocalization.string("Every day") }
        if minutes % 1_440 == 0 {
            let dayCount = minutes / 1_440
            return AppLocalization.string("Every \(dayCount) days")
        }
        if minutes % 60 == 0 {
            let hourCount = minutes / 60
            return AppLocalization.string("Every \(hourCount) hours")
        }
        let minuteCount = minutes
        return AppLocalization.string("Every \(minuteCount) minutes")
    }

    /// A five-field cron expression in words, or nil for a pattern this
    /// doesn't cover (several hours, ranges of days of the month, steps that
    /// don't divide evenly…). The time is the schedule's wall clock.
    static func describe(expression: String, locale: Locale = AppLocalization.formattingLocale) -> String? {
        let fields = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else { return nil }
        let (minute, hour, dayOfMonth, month, dayOfWeek) = (fields[0], fields[1], fields[2], fields[3], fields[4])
        guard month == "*" else { return nil }

        // Every N minutes / every N hours / every hour.
        if hour == "*", dayOfMonth == "*", dayOfWeek == "*" {
            if minute == "*" { return AppLocalization.string("Every minute") }
            if let step = step(minute), 60 % step == 0 {
                return step == 1 ? AppLocalization.string("Every minute") : describe(intervalMinutes: step)
            }
            if let value = Int(minute), (0...59).contains(value) {
                if value == 0 { return AppLocalization.string("Every hour") }
                let pastHour = String(format: "%02d", value)
                return AppLocalization.string("Every hour at :\(pastHour)")
            }
            return nil
        }
        if let hourStep = step(hour), 24 % hourStep == 0, Int(minute) == 0, dayOfMonth == "*", dayOfWeek == "*" {
            return hourStep == 1 ? AppLocalization.string("Every hour") : describe(intervalMinutes: hourStep * 60)
        }

        // A time of day, then which days.
        guard let minuteValue = Int(minute), (0...59).contains(minuteValue),
              let hourValue = Int(hour), (0...23).contains(hourValue) else { return nil }
        let time = timeText(hour: hourValue, minute: minuteValue, locale: locale)

        if dayOfMonth == "*" {
            guard dayOfWeek != "*" else { return AppLocalization.string("Daily at \(time)") }
            guard let days = weekdays(dayOfWeek) else { return nil }
            if days == Set(1...5) { return AppLocalization.string("Weekdays at \(time)") }
            if days == [0, 6] { return AppLocalization.string("Weekends at \(time)") }
            if days == Set(0...6) { return AppLocalization.string("Daily at \(time)") }
            let names = weekdayNames(days, locale: locale)
            return AppLocalization.string("Every \(names) at \(time)")
        }
        if dayOfWeek == "*", let day = Int(dayOfMonth), (1...31).contains(day) {
            let dayText = String(day)
            return AppLocalization.string("Monthly on day \(dayText) at \(time)")
        }
        return nil
    }

    /// "*/N" (or "0/N") as N.
    private static func step(_ field: String) -> Int? {
        let parts = field.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "*" || parts[0] == "0", let value = Int(parts[1]), value > 0 else { return nil }
        return value
    }

    /// The days a day-of-week field names, Sunday as 0 (cron's 7 too), or
    /// nil when it uses something other than numbers, lists and ranges.
    static func weekdays(_ field: String) -> Set<Int>? {
        var days = Set<Int>()
        for item in field.split(separator: ",") {
            let bounds = item.split(separator: "-", omittingEmptySubsequences: false)
            switch bounds.count {
            case 1:
                guard let day = Int(bounds[0]), (0...7).contains(day) else { return nil }
                days.insert(day % 7)
            case 2:
                guard let start = Int(bounds[0]), let end = Int(bounds[1]),
                      (0...7).contains(start), (0...7).contains(end), start <= end else { return nil }
                for day in start...end { days.insert(day % 7) }
            default:
                return nil
            }
        }
        return days.isEmpty ? nil : days
    }

    private static func weekdayNames(_ days: Set<Int>, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = calendar.weekdaySymbols
        // In the locale's week order (Monday first in most of the world).
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 }
        let names = order.filter(days.contains).map { symbols[$0] }
        return names.formatted(.list(type: .and).locale(locale))
    }

    private static func timeText(hour: Int, minute: Int, locale: Locale) -> String {
        let utc = TimeZone(identifier: "UTC") ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let date = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: hour, minute: minute)) ?? Date()
        return dateFormatter("jmm", locale: locale, timeZone: utc) { $0.setLocalizedDateFormatFromTemplate("jmm") }
            .string(from: date)
    }

    // MARK: Formatters

    /// Built once per configuration: list rows format on every redraw. A
    /// stored formatter is never changed again, and NSCache is thread-safe.
    private static let formatterCache = NSCache<NSString, Formatter>()

    private static func cachedFormatter<F: Formatter>(_ key: String, make: () -> F) -> F {
        if let cached = formatterCache.object(forKey: key as NSString) as? F { return cached }
        let formatter = make()
        formatterCache.setObject(formatter, forKey: key as NSString)
        return formatter
    }

    private static func gregorian(locale: Locale, timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        return calendar
    }

    /// A date formatter for `name` (a template or a style), in `locale`
    /// and `timeZone`; `configure` runs once, when it is first built.
    private static func dateFormatter(
        _ name: String,
        locale: Locale,
        timeZone: TimeZone,
        configure: (DateFormatter) -> Void
    ) -> DateFormatter {
        cachedFormatter("date|\(name)|\(locale.identifier)|\(timeZone.identifier)") {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.calendar = gregorian(locale: locale, timeZone: timeZone)
            configure(formatter)
            return formatter
        }
    }

    private static func withZone(_ text: String, zoneLabel: String?, isWallClock: Bool) -> String {
        guard isWallClock, let zoneLabel, !zoneLabel.isEmpty else { return text }
        return AppLocalization.string("\(text) (\(zoneLabel))")
    }

    // MARK: Next run

    /// Runs nearer than this read as "in 3 hours"; later ones as a day and
    /// time, since "in 1 day" can mean anything from 24 to 47 hours.
    static let relativeHorizon: TimeInterval = 20 * 60 * 60

    /// When a run happens, for "Next run …": "in 25 minutes", "in 3 hours",
    /// "tomorrow at 8:00 AM", "Monday 8:00 AM", "Oct 27, 8:00 AM".
    static func runTimeText(
        _ date: Date,
        now: Date = Date(),
        locale: Locale = AppLocalization.formattingLocale,
        timeZone: TimeZone = .current
    ) -> String {
        let interval = date.timeIntervalSince(now)
        if interval < relativeHorizon {
            let formatter: RelativeDateTimeFormatter = cachedFormatter("relative|\(locale.identifier)|\(timeZone.identifier)") {
                let formatter = RelativeDateTimeFormatter()
                formatter.locale = locale
                formatter.unitsStyle = .full
                formatter.formattingContext = .middleOfSentence
                formatter.calendar = gregorian(locale: locale, timeZone: timeZone)
                return formatter
            }
            // Rounded, not truncated: 2 h 50 min is "in 3 hours".
            let magnitude = abs(interval)
            let sign = interval < 0 ? -1 : 1
            let components: DateComponents
            if magnitude < 90 * 60 {
                components = DateComponents(minute: sign * max(1, Int((magnitude / 60).rounded())))
            } else if magnitude < relativeHorizon {
                components = DateComponents(hour: sign * Int((magnitude / 3_600).rounded()))
            } else {
                // Only an overdue run gets here: "3 days ago", not "72 hours ago".
                // A date too far off for a day count reads as a date (#997).
                guard let days = Int(exactly: (magnitude / 86_400).rounded()) else {
                    return absoluteDateText(date, locale: locale, timeZone: timeZone)
                }
                components = DateComponents(day: sign * days)
            }
            return formatter.localizedString(from: components)
        }
        let calendar = gregorian(locale: locale, timeZone: timeZone)
        let startOfToday = calendar.startOfDay(for: now)
        let dayOffset = calendar.dateComponents([.day], from: startOfToday, to: calendar.startOfDay(for: date)).day ?? 0
        let formatter: DateFormatter
        // Later today but too far off for "in N hours" says "today", like
        // tomorrow: a bare weekday would read as next week's.
        if dayOffset == 0 || dayOffset == 1 {
            formatter = dateFormatter("tomorrow", locale: locale, timeZone: timeZone) {
                $0.formattingContext = .middleOfSentence
                $0.dateStyle = .medium
                $0.timeStyle = .short
                $0.doesRelativeDateFormatting = true
            }
            // The formatter says "today" and "tomorrow" against the real clock, not
            // `now`. Moving the run by the whole days between the two keeps
            // its wall-clock time and makes its day relative to `now` (they
            // differ only when a caller passes another `now`, as tests do).
            let realToday = calendar.startOfDay(for: Date())
            let shift = calendar.dateComponents([.day], from: startOfToday, to: realToday).day ?? 0
            if shift != 0, let shown = calendar.date(byAdding: .day, value: shift, to: date) {
                return formatter.string(from: shown)
            }
        } else {
            let template = dayOffset < 7 ? "EEEEjmm"
                : calendar.isDate(date, equalTo: now, toGranularity: .year) ? "MMMdjmm" : "yMMMdjmm"
            formatter = dateFormatter(template, locale: locale, timeZone: timeZone) {
                $0.formattingContext = .middleOfSentence
                $0.setLocalizedDateFormatFromTemplate(template)
            }
        }
        return formatter.string(from: date)
    }

    /// A run's full date and time, for the job's details.
    static func absoluteDateText(_ date: Date, locale: Locale = AppLocalization.formattingLocale, timeZone: TimeZone = .current) -> String {
        dateFormatter("EEEyMMMdjmm", locale: locale, timeZone: timeZone) {
            $0.setLocalizedDateFormatFromTemplate("EEEyMMMdjmm")
        }
        .string(from: date)
    }

    // MARK: Dates

    private static let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainISOFormatter = ISO8601DateFormatter()

    /// The last second of year 9999: later epoch values aren't run times.
    private static let latestEpochSeconds: TimeInterval = 253_402_300_799

    /// Hermes' run times: ISO 8601 with an offset (Python's isoformat, with
    /// or without microseconds), the same without an offset (read in
    /// `timeZone`), or epoch seconds or milliseconds. Anything else, or an
    /// epoch outside 1970 through 9999, is nil (#997).
    static func parseDate(_ raw: String, timeZone: TimeZone = .current) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = fractionalISOFormatter.date(from: trimmed) { return date }
        if let date = isoDate(trimmed, timeZone: timeZone) { return date }
        // Microseconds, which the formatters above don't all read: drop
        // the fraction and parse the rest.
        if let dot = trimmed.firstIndex(of: "."), trimmed.contains("T") {
            let fractionEnd = trimmed[trimmed.index(after: dot)...].firstIndex { !$0.isNumber } ?? trimmed.endIndex
            let whole = String(trimmed[..<dot]) + String(trimmed[fractionEnd...])
            if let date = isoDate(whole, timeZone: timeZone) { return date }
        }
        guard let number = Double(trimmed), number.isFinite else { return nil }
        let seconds = number > 10_000_000_000 ? number / 1000 : number
        guard (0...latestEpochSeconds).contains(seconds) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Whole-second ISO 8601, with an offset or (Python's naive isoformat)
    /// without one.
    private static func isoDate(_ text: String, timeZone: TimeZone) -> Date? {
        if let date = plainISOFormatter.date(from: text) { return date }
        let local: ISO8601DateFormatter = cachedFormatter("isoWithoutOffset|\(timeZone.identifier)") {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            formatter.timeZone = timeZone
            return formatter
        }
        return local.date(from: text)
    }
}
