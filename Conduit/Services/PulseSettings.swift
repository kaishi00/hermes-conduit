//
//  PulseSettings.swift
//  Conduit
//
//  Pulse, the notifier plugin's proactivity feature, as Settings > Pulse
//  (beta) reads and changes it on TestFlight and Xcode builds. The plugin
//  serves Pulse's state and settings on its dashboard routes
//  (/api/plugins/conduit_push/pulse…, plugin's pulse_control.py). Pulse is
//  one per host, in the dashboard's own Hermes home, so the routes take no
//  profile. A step Pulse won't take comes back as 409 with a code
//  (`{"detail": {"code": "pulse_off"}}`) that Conduit words itself.
//

import Foundation

/// Reads JSON numbers and flags the way the plugin sends them: a JSON
/// boolean is never a number, and epochs may carry fractions.
enum PulseJSON {
    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    /// nil for a value no Int holds (inf, NaN, out of range) rather than a trap.
    static func int(_ value: Any?) -> Int? {
        double(value).flatMap { Int(exactly: $0.rounded(.towardZero)) }
    }

    static func date(_ value: Any?) -> Date? {
        double(value).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func strings(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { $0 as? String }
    }

    /// `{name: count}` objects (checks by state, memory items by kind).
    static func counts(_ value: Any?) -> [String: Int] {
        var counts: [String: Int] = [:]
        for (key, raw) in value as? [String: Any] ?? [:] {
            if let count = int(raw) { counts[key] = count }
        }
        return counts
    }
}

/// The chat Pulse speaks in.
struct PulseHomeChat: Equatable {
    let id: String
    let title: String
    let pinned: Bool
}

/// One of Pulse's latest checks of the chats or reports.
struct PulseRecentAttempt: Equatable, Identifiable {
    /// The row's place in the host's list: two attempts can share a time.
    let id: Int
    let at: Date
    /// "probe" (a check of the chats) or "report".
    let kind: String
    let state: String
    let detail: String
}

/// Reading older chats into memory.
struct PulseBackfill: Equatable {
    enum Phase: String {
        case none, reading, paused, done, cancelled
    }

    var phase: Phase = .none
    var from: Date?
    var to: Date?
    var days: Int?
    /// Done for this profile only, while memory now reads every profile.
    var narrow = false
    /// Profiles whose chats couldn't be read while reading.
    var unreadable: [String] = []

    init() {}

    init(json: Any?) {
        guard let object = json as? [String: Any] else { return }
        phase = (object["state"] as? String).flatMap(Phase.init(rawValue:)) ?? .none
        from = PulseJSON.date(object["from"])
        to = PulseJSON.date(object["to"])
        days = PulseJSON.int(object["days"])
        narrow = PulseJSON.bool(object["narrow"]) ?? false
        unreadable = PulseJSON.strings(object["unreadable"])
    }

    /// Start (or Carry on) and an estimate are offered in these.
    var canStart: Bool { phase == .none || phase == .done || phase == .cancelled }
}

/// How a report's lines of one kind were rated.
struct PulseRating: Equatable {
    let yes: Int
    let no: Int
}

/// Everything Settings > Pulse shows (GET /pulse).
struct PulseState: Equatable {
    var enabled = false
    var running = false
    var staleBuild = false
    var homeChat: PulseHomeChat?
    var homeProblem = ""
    var homeTitle = "Pulse"
    var checks: [String: Int] = [:]
    var recent: [PulseRecentAttempt] = []
    var dailyReport = false
    /// "HH:MM", in `timeZone`.
    var reportTimes: [String] = []
    /// When the morning brief comes each day with what's still open and
    /// anything held for it ("HH:MM"; the plugin's default until it answers).
    var briefTime = "07:00"
    var timeZone = ""
    /// "" while Pulse uses the phone's or the host's zone.
    var timeZoneSet = ""
    var nextReportAt: Date?
    /// "all" or "this".
    var reportProfiles = "this"
    var otherProfiles: [String] = []
    var memory = false
    var memoryCounts: [String: Int] = [:]
    var memoryChunks = 0
    var memoryTokens = 0
    var dailyTokens = 0
    var tokensToday = 0
    var backfill = PulseBackfill()
    var backfillDays = 30
    var ratings: [String: PulseRating] = [:]
    /// The model Pulse's turns run on (0.57.0); nil, the Pulse chat's own.
    var model: PulseModel?
    /// How much Pulse nudges (0.63.0): one of PulseNudge.levels.
    var nudge = PulseNudge.defaultLevel
    /// The note to Pulse: what the user wants from it, in their own words
    /// (0.78.2). "" when there is none.
    var note = ""
    /// Quiet times (0.80.2): the weekdays Pulse keeps to itself, as the
    /// plugin numbers them (Monday 0 to Sunday 6).
    var quietDays: [Int] = []
    /// When the quiet spell set (a vacation, or Quiet for today) ends: the
    /// start of the first day back. Nil when none is set.
    var quietUntil: Date?
    /// Why Pulse is quiet right now; nil while it isn't.
    var quietNow: PulseQuietReason?
    /// When Pulse speaks up again: the spell's end, past any quiet days
    /// after it; nil while it isn't quiet, or when every day is.
    var quietEndsAt: Date?
    /// Follow-ups on promises and to-dos are on.
    var followups = false
    var followupDailyTokens = 0
    var followupTokensToday = 0
    /// False while follow-ups' budget goes with the nudge level.
    var followupDailyTokensSet = false

    init() {}

    /// Nil unless the body is Pulse's state.
    init?(json: [String: Any]) {
        guard let enabled = PulseJSON.bool(json["enabled"]) else { return nil }
        self.enabled = enabled
        running = PulseJSON.bool(json["running"]) ?? false
        staleBuild = PulseJSON.bool(json["stale_build"]) ?? false
        if let chat = json["home_chat"] as? [String: Any], let id = chat["id"] as? String, !id.isEmpty {
            homeChat = PulseHomeChat(
                id: id,
                title: chat["title"] as? String ?? "",
                pinned: PulseJSON.bool(chat["pinned"]) ?? false
            )
        }
        homeProblem = json["home_problem"] as? String ?? ""
        if let title = json["home_title"] as? String, !title.isEmpty { homeTitle = title }
        checks = PulseJSON.counts(json["checks"])
        recent = (json["recent"] as? [Any] ?? []).enumerated().compactMap { index, raw in
            guard let row = raw as? [String: Any], let at = PulseJSON.date(row["at"]) else { return nil }
            return PulseRecentAttempt(
                id: index,
                at: at,
                kind: row["kind"] as? String ?? "",
                state: row["state"] as? String ?? "",
                detail: row["detail"] as? String ?? ""
            )
        }
        dailyReport = PulseJSON.bool(json["daily_report"]) ?? false
        reportTimes = PulseJSON.strings(json["report_times"]).filter { PulseReportTime.minutes($0) != nil }
        if let brief = json["brief_time"] as? String, PulseReportTime.minutes(brief) != nil { briefTime = brief }
        timeZone = json["time_zone"] as? String ?? ""
        timeZoneSet = json["time_zone_set"] as? String ?? ""
        nextReportAt = PulseJSON.date(json["next_report_at"])
        reportProfiles = json["report_profiles"] as? String == "all" ? "all" : "this"
        otherProfiles = PulseJSON.strings(json["other_profiles"])
        memory = PulseJSON.bool(json["memory"]) ?? false
        memoryCounts = PulseJSON.counts(json["memory_counts"])
        memoryChunks = PulseJSON.int(json["memory_chunks"]) ?? 0
        memoryTokens = PulseJSON.int(json["memory_tokens"]) ?? 0
        dailyTokens = PulseJSON.int(json["daily_tokens"]) ?? 0
        tokensToday = PulseJSON.int(json["tokens_today"]) ?? 0
        backfill = PulseBackfill(json: json["backfill"])
        if let days = PulseJSON.int(json["backfill_days"]), (1...PulseBackfillEstimate.maxDays).contains(days) {
            backfillDays = days
        }
        if let level = json["nudge"] as? String, PulseNudge.levels.contains(level) { nudge = level }
        note = json["note"] as? String ?? ""
        quietDays = PulseQuiet.days(json["quiet_days"])
        quietUntil = PulseJSON.date(json["quiet_until"])
        quietNow = (json["quiet_now"] as? String).flatMap(PulseQuietReason.init(rawValue:))
        quietEndsAt = PulseJSON.date(json["quiet_ends_at"])
        followups = PulseJSON.bool(json["followups"]) ?? false
        followupDailyTokens = PulseJSON.int(json["followup_daily_tokens"]) ?? 0
        followupTokensToday = PulseJSON.int(json["followup_tokens_today"]) ?? 0
        followupDailyTokensSet = PulseJSON.bool(json["followup_daily_tokens_set"]) ?? false
        if let raw = json["model"] as? [String: Any], let name = raw["model"] as? String, !name.isEmpty {
            model = PulseModel(provider: raw["provider"] as? String ?? "", model: name)
        }
        for (kind, raw) in json["ratings"] as? [String: Any] ?? [:] {
            guard let counts = raw as? [String: Any] else { continue }
            ratings[kind] = PulseRating(yes: PulseJSON.int(counts["yes"]) ?? 0, no: PulseJSON.int(counts["no"]) ?? 0)
        }
    }

    /// The profile choice is offered when there's more than this profile to
    /// report on, or the user already narrowed it to this one.
    var offersProfileChoice: Bool { !otherProfiles.isEmpty || reportProfiles == "this" }
}

/// The note to Pulse (0.78.2): the plugin's reports, morning brief and
/// follow-up checks read it before their own rules.
enum PulseNote {
    /// The plugin's bound on its length (pulse_control.NOTE_LIMIT), in code points.
    static let limit = 1_500
}

/// Why Pulse is quiet now (0.80.2): a spell set until a day (a vacation,
/// or Quiet for today), or a quiet day of the week.
enum PulseQuietReason: String {
    case until
    case day
}

/// Quiet times (0.80.2): days of the week Pulse keeps to itself, and a
/// spell until a day. While quiet, nothing comes on its own: no report or
/// morning brief, and follow-ups wait for the first brief after.
enum PulseQuiet {
    /// The plugin's weekdays (Monday 0 to Sunday 6), valid and in order.
    static func days(_ value: Any?) -> [Int] {
        Array(Set((value as? [Any] ?? []).compactMap { PulseJSON.int($0) }.filter { (0..<7).contains($0) })).sorted()
    }

    /// A plugin day (Monday 0) from Calendar's weekday symbol index (Sunday
    /// 0), and back.
    static func pluginDay(calendarIndex: Int) -> Int { (calendarIndex + 6) % 7 }
    static func calendarIndex(pluginDay: Int) -> Int { (pluginDay + 1) % 7 }

    /// The plugin's days in the order the user's week runs: Sunday first
    /// where weeks start on Sunday, Monday first where they start on Monday.
    static func weekOrder(calendar: Calendar = .current) -> [Int] {
        (0..<7).map { pluginDay(calendarIndex: (calendar.firstWeekday - 1 + $0) % 7) }
    }

    /// A day as the plugin takes `quiet_until` ("YYYY-MM-DD"): Pulse is
    /// quiet until that day starts.
    static func dayText(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The days a vacation can end on: tomorrow to a year ahead, as the
    /// plugin takes them.
    static func returnDays(now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Date> {
        let today = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        let last = calendar.date(byAdding: .day, value: 365, to: today) ?? first
        return first...max(first, last)
    }

    /// The relay gateways whose Pulse pushes offer Quiet for today, once
    /// the plugin of the host behind `gateways` has answered: with them when
    /// it takes it, without them when not. Nil while it hasn't answered, or
    /// before the host said which gateways are its own.
    static func sharedGateways(_ current: Set<String>, gateways: Set<String>, plugin: NotifierPluginStatus) -> Set<String>? {
        guard !gateways.isEmpty, case .reported = plugin.state else { return nil }
        return plugin.reports(PulseClient.quietCapability) ? current.union(gateways) : current.subtracting(gateways)
    }

    /// A vacation's first day back when it's switched on: a week from today.
    static func defaultReturn(now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now)) ?? now
    }

    /// When Pulse speaks up again, as the Pulse screen says it: later today,
    /// tomorrow or a weekday this week as a card put off says it, else the date.
    static func backText(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        guard days >= 7 else { return PulseRest.backText(date, now: now, calendar: calendar) }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = AppLocalization.formattingLocale
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return AppLocalization.string("Back on \(formatter.string(from: date))")
    }
}

/// A model Pulse runs on: its reports, brief and follow-ups in the Pulse chat,
/// and its memory (Hermes' `pulse_memory` slot).
struct PulseModel: Equatable {
    let provider: String
    let model: String

    /// PUT /pulse's "model".
    var setting: [String: Any] { ["provider": provider, "model": model] }
}

/// How much Pulse nudges: reminders a day, how soon promises are checked
/// again, and how much its reports bring up (plugin's pulse_learning.NUDGES).
enum PulseNudge {
    static let levels = ["gentle", "balanced", "eager"]
    static let defaultLevel = "balanced"

    static func title(_ level: String) -> String {
        switch level {
        case "gentle": return AppLocalization.string("Gentle")
        case "eager": return AppLocalization.string("Eager")
        default: return AppLocalization.string("Balanced")
        }
    }

    static func detail(_ level: String) -> String {
        switch level {
        case "gentle":
            return AppLocalization.string("Only what's worth interrupting you for: one reminder a day, and promises checked less often.")
        case "eager":
            return AppLocalization.string("Small things too: six reminders a day, and promises checked sooner.")
        default:
            return AppLocalization.string("A heads-up on what's open or coming due: three reminders a day.")
        }
    }

    /// Daily token budgets the pickers offer, with the current one added
    /// when it's set to something else.
    static func budgets(_ presets: [Int], current: Int) -> [Int] {
        Array(Set(presets + (current > 0 ? [current] : []))).sorted()
    }

    static let memoryBudgets = [100_000, 200_000, 300_000, 500_000, 1_000_000, 2_000_000]
    static let followupBudgets = [30_000, 60_000, 150_000, 300_000, 600_000, 1_000_000]
}

/// What reading back some days would cost (POST /pulse/backfill estimate).
struct PulseBackfillEstimate: Equatable {
    static let maxDays = 365

    let days: Int
    let from: Date?
    let to: Date?
    let chats: Int
    let chars: Int
    let chunks: Int
    let tokens: Int
    let dailyTokens: Int
    let daysNeeded: Int
    let unreadable: [String]

    init?(json: Any?) {
        guard let object = json as? [String: Any],
              let days = PulseJSON.int(object["days"]),
              let tokens = PulseJSON.int(object["tokens"]) else { return nil }
        self.days = days
        self.tokens = tokens
        from = PulseJSON.date(object["from"])
        to = PulseJSON.date(object["to"])
        chats = PulseJSON.int(object["chats"]) ?? 0
        chars = PulseJSON.int(object["chars"]) ?? 0
        chunks = PulseJSON.int(object["chunks"]) ?? 0
        dailyTokens = PulseJSON.int(object["daily_tokens"]) ?? 0
        daysNeeded = PulseJSON.int(object["days_needed"]) ?? 0
        unreadable = PulseJSON.strings(object["unreadable"])
    }
}

/// One thing Pulse remembers (GET /pulse/memory).
struct PulseMemoryItem: Equatable, Identifiable {
    let id: Int
    let kind: String
    let text: String
    let evidence: String
    let explicit: Bool
    /// The due date as the chat put it ("Friday"), or "".
    let due: String
    let dueAt: Date?
    let mentionedAt: Date?
    let profile: String
    let chatID: String

    init?(json: Any) {
        guard let object = json as? [String: Any],
              let id = PulseJSON.int(object["id"]),
              let text = object["text"] as? String else { return nil }
        self.id = id
        self.text = text
        kind = object["kind"] as? String ?? ""
        evidence = object["evidence"] as? String ?? ""
        explicit = PulseJSON.bool(object["explicit"]) ?? false
        due = object["due"] as? String ?? ""
        dueAt = PulseJSON.date(object["due_at"])
        mentionedAt = PulseJSON.date(object["mentioned_at"])
        profile = object["profile"] as? String ?? ""
        chatID = object["chat_id"] as? String ?? ""
    }
}

/// The kinds of things Pulse remembers, in the order the page lists them.
enum PulseMemoryKind {
    static let order = ["commitment", "promise", "intention", "interest", "fact", "watch"]

    /// A kind's name as a heading; a kind this build doesn't know shows as
    /// the plugin sends it.
    static func title(_ kind: String) -> String {
        switch kind {
        case "commitment": return AppLocalization.string("Commitments")
        case "promise": return AppLocalization.string("Promises")
        case "intention": return AppLocalization.string("Intentions")
        case "interest": return AppLocalization.string("Interests")
        case "fact": return AppLocalization.string("Facts")
        case "watch": return AppLocalization.string("Things to watch")
        default: return kind
        }
    }

    /// Known kinds first, in order, then any others by name.
    static func sorted(_ kinds: some Sequence<String>) -> [String] {
        Array(Set(kinds)).sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs) ?? order.count
            let right = order.firstIndex(of: rhs) ?? order.count
            return left == right ? lhs < rhs : left < right
        }
    }
}

/// Report times as Pulse keeps them: "HH:MM".
enum PulseReportTime {
    static let maxCount = 12

    /// Minutes after midnight, or nil for anything but "HH:MM".
    static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    static func text(minutes: Int) -> String {
        let clamped = ((minutes % 1_440) + 1_440) % 1_440
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    /// Sorted and without repeats.
    static func normalized(_ times: [String]) -> [String] {
        Array(Set(times.compactMap(minutes))).sorted().map { text(minutes: $0) }
    }

    /// A new time for Add: an hour after the last, or noon.
    static func next(after times: [String]) -> String {
        let taken = Set(times.compactMap(minutes))
        var candidate = (times.compactMap(minutes).max() ?? 11 * 60) + 60
        for _ in 0..<24 where taken.contains(candidate % 1_440) {
            candidate += 60
        }
        return text(minutes: candidate)
    }

    /// The time as a Date today, for an hour-and-minute picker. Read back
    /// with the same calendar, so the zone doesn't matter.
    static func date(_ text: String, calendar: Calendar = .current, now: Date = Date()) -> Date {
        let total = minutes(text) ?? 0
        return calendar.date(bySettingHour: total / 60, minute: total % 60, second: 0, of: now) ?? now
    }

    static func text(from date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return text(minutes: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }
}

/// A step Pulse wouldn't take (409, or 400 for a value it doesn't take),
/// read from the code the plugin sends.
struct PulseRefusal: Equatable {
    let code: String

    init?(error: Error) {
        guard let bridgeError = error as? DashboardTicketBridgeError,
              case .http(let status, let detail) = bridgeError,
              status == 409 || status == 400,
              let data = detail.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["code"] as? String, !code.isEmpty else { return nil }
        self.code = code
    }

    init(code: String) {
        self.code = code
    }

    var message: String {
        switch code {
        case "reading": return AppLocalization.string("Pulse is already reading older chats.")
        case "paused": return AppLocalization.string("A paused read is waiting. Carry on or cancel it first.")
        case "already_read": return AppLocalization.string("Pulse has already read back that far.")
        case "memory_off": return AppLocalization.string("Turn on Pulse's memory first.")
        case "pulse_off": return AppLocalization.string("Turn on Pulse first.")
        case "no_home_chat": return AppLocalization.string("Pulse needs its chat first.")
        case "unreadable": return AppLocalization.string("Pulse couldn't read Hermes' chats on the host.")
        case "not_running": return AppLocalization.string("Nothing is being read right now.")
        case "nothing_to_cancel": return AppLocalization.string("There's nothing to cancel.")
        case "changed": return AppLocalization.string("Pulse changed in the meantime. Try again.")
        case "invalid": return AppLocalization.string("Pulse didn't accept that value.")
        default: return AppLocalization.string("Pulse didn't take that step.")
        }
    }

    /// What to show for a failed Pulse request.
    static func message(for error: Error) -> String {
        PulseRefusal(error: error)?.message ?? UserFacingError.message(for: error)
    }
}

enum PulseBackfillAction: String {
    case start, stop, cancel
}

/// Pulse's dashboard routes.
@MainActor
struct PulseClient {
    static let capability = "pulse"
    static let path = "/api/plugins/conduit_push/pulse"

    typealias Request = @MainActor (_ path: String, _ method: String, _ body: [String: Any]?) async throws -> [String: Any]

    /// The dashboard the requests go to (nil in tests).
    var dashboardID: UUID?
    let request: Request

    init(dashboardID: UUID? = nil, request: @escaping Request) {
        self.dashboardID = dashboardID
        self.request = request
    }

    func state() async throws -> PulseState {
        let response = try await request(Self.path, "GET", nil)
        return try Self.state(from: response)
    }

    /// Any of enabled, memory, daily_report, report_profiles, report_times,
    /// brief_time, time_zone, model, nudge, memory_daily_tokens,
    /// followup_daily_tokens and note; answers with the new state.
    func update(_ changes: [String: Any]) async throws -> PulseState {
        let response = try await request(Self.path, "PUT", changes)
        return try Self.state(from: response)
    }

    func sendReport() async throws {
        _ = try await request("\(Self.path)/report", "POST", [:])
    }

    func estimate(days: Int) async throws -> PulseBackfillEstimate {
        let response = try await request("\(Self.path)/backfill", "POST", ["action": "estimate", "days": days])
        guard let estimate = PulseBackfillEstimate(json: response["estimate"]) else { throw HermesError.invalidResponse }
        return estimate
    }

    func backfill(_ action: PulseBackfillAction, days: Int? = nil) async throws -> PulseState {
        var body: [String: Any] = ["action": action.rawValue]
        if let days { body["days"] = days }
        let response = try await request("\(Self.path)/backfill", "POST", body)
        return try Self.state(from: response)
    }

    func memory() async throws -> [PulseMemoryItem] {
        let response = try await request("\(Self.path)/memory", "GET", nil)
        return (response["items"] as? [Any] ?? []).compactMap(PulseMemoryItem.init(json:))
    }

    /// False when the item was no longer open.
    func forget(id: Int) async throws -> Bool {
        let response = try await request("\(Self.path)/memory/forget", "POST", ["id": id])
        return PulseJSON.bool(response["forgotten"]) ?? false
    }

    static func state(from response: [String: Any]) throws -> PulseState {
        guard let state = PulseState(json: response) else { throw HermesError.invalidResponse }
        return state
    }
}
