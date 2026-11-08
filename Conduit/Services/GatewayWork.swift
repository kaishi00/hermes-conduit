//
//  GatewayWork.swift
//  Conduit
//
//  What a gateway restart waits on, as the plugin names it (GET
//  /api/plugins/conduit_push/self/gateway-work, plugin 0.135+), and Restart
//  now. Hermes' restart lets running work finish first, up to
//  agent.restart_after_turn_timeout (30 minutes by default), and a second
//  restart only joins the first, so "Letting running tasks finish…" says
//  what it waits on and offers a way out: Conduit stops the chats it names
//  (session.interrupt, which a draining gateway still takes), and what it
//  can't stop the plugin ends with a restart through systemd.
//

import Foundation

struct GatewayWork: Equatable {
    struct Unit: Equatable {
        /// `chat`, `cron`, `managed`, `api` or `deferred`.
        var kind: String
        var profile: String?
        var bot: String?
        var title: String?
        /// The chat's session, when Conduit can stop it.
        var sessionID: String?
        var jobID: String?
        /// When it started, from its running time when it was read.
        var startedAt: Date?

        var canStop: Bool { kind == "chat" && sessionID != nil }
    }

    var units: [Unit]
    /// How many the restart waits on: an older gateway names none.
    var count: Int
    var draining: Bool
    /// When the gateway restarts anyway, while it drains.
    var restartsBy: Date?

    static let capability = "gateway-work"
    static let path = "/api/plugins/conduit_push/self/gateway-work"
    static let restartNowPath = "/api/plugins/conduit_push/self/gateway-work/restart-now"
    static let forceRestartPath = restartNowPath + "?force=true"

    init(units: [Unit], count: Int, draining: Bool, restartsBy: Date? = nil) {
        self.units = units
        self.count = count
        self.draining = draining
        self.restartsBy = restartsBy
    }

    init?(json: [String: Any], now: Date = Date()) {
        guard let rawUnits = json["units"] as? [[String: Any]] else { return nil }
        func text(_ value: Any?) -> String? {
            (value as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        units = rawUnits.map { unit in
            let elapsed = (unit["elapsed_s"] as? NSNumber)?.doubleValue
            return Unit(
                kind: text(unit["kind"]) ?? "work",
                profile: text(unit["profile"]),
                bot: text(unit["bot"]),
                title: text(unit["title"]),
                sessionID: text(unit["session_id"]),
                jobID: text(unit["job_id"]),
                startedAt: elapsed.map { now.addingTimeInterval(-$0) }
            )
        }
        count = max(units.count, (json["count"] as? NSNumber)?.intValue ?? 0)
        draining = json["draining"] as? Bool ?? false
        restartsBy = (json["restarts_by"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }

    /// One line per unit: whose chat and which, or the job, and how long it
    /// has run.
    func lines(now: Date) -> [String] {
        var lines = units.map { unit -> String in
            let name: String
            switch unit.kind {
            case "chat":
                let bot = unit.bot ?? "Hermes"
                name = unit.title.map { AppLocalization.string("\(bot): \($0)") }
                    ?? AppLocalization.string("\(bot): a chat")
            case "cron":
                name = AppLocalization.string("Scheduled job \(unit.title ?? unit.jobID ?? "?")")
            default:
                name = AppLocalization.string("A background task")
            }
            guard let startedAt = unit.startedAt else { return name }
            return AppLocalization.string("\(name), running \(Self.duration(now.timeIntervalSince(startedAt)))")
        }
        if units.isEmpty, count > 0 {
            lines.append(AppLocalization.string("Hermes doesn't say what's running."))
        }
        return lines
    }

    static func duration(_ seconds: TimeInterval) -> String {
        // Clamped as a Double first: an absurd running time from the
        // gateway mustn't trap the conversion.
        let minutes = Int(min(max((seconds / 60).rounded(), 1), 1_000_000))
        let components = DateComponents(hour: minutes / 60, minute: minutes % 60)
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = minutes >= 60 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .short
        formatter.calendar = {
            var calendar = Calendar.current
            calendar.locale = AppLocalization.formattingLocale
            return calendar
        }()
        return formatter.string(from: components) ?? "\(minutes) min"
    }
}

/// Restart now's steps, apart from the dashboard they go to (so a test can
/// script them): the update stops waiting, the chats the restart waits on
/// are stopped, and whatever still runs after a few reads is ended with a
/// forced restart. Each step answers why it failed, or nil.
struct GatewayRestartNow {
    struct Failure: Equatable {
        var message: String
        var dashboardID: UUID?
        var at: Date

        /// A failure shows on the dashboard it came from, for 15 minutes or
        /// until the next Restart now.
        func shows(on dashboardID: UUID?, now: Date = Date()) -> Bool {
            self.dashboardID == dashboardID && now.timeIntervalSince(at) < 15 * 60
        }
    }

    var endWait: () async -> String?
    /// What the restart waits on, from the dashboard Restart now started
    /// on; nil when the read failed.
    var readWork: () async -> GatewayWork?
    var stop: (GatewayWork.Unit) async -> Void
    var force: () async -> String?
    var pause: () async -> Void
    var reads = 5

    func run() async -> String? {
        if let failure = await endWait() { return failure }
        if let work = await readWork() {
            // All at once, so one chat that doesn't answer holds the rest
            // up for its own timeout only. A chat that won't stop is ended by
            // the forced restart below.
            await withTaskGroup(of: Void.self) { group in
                for unit in work.units where unit.canStop {
                    group.addTask { await stop(unit) }
                }
            }
        }
        // Stopped chats end within a few seconds; an update still waiting
        // sends its restart once the flag lands. A read that fails proves
        // nothing, so only an answer with no work skips the force.
        for _ in 0..<reads {
            await pause()
            if let work = await readWork(), work.count == 0 { return nil }
        }
        return await force()
    }
}
