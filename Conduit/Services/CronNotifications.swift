import Foundation

/// Which cron jobs don't notify, as the host's notifier plugin keeps them
/// (plugin 0.33+, capability `cron-notifications`). A job not listed
/// notifies; a run that answers [SILENT] never does, whatever the setting.
final class CronNotificationsClient {
    static let capability = "cron-notifications"
    /// The same route's `act`: a job delivered to a Bot Chat just shows its
    /// report there, unless it lets the bot act on it (cron_bot_chat).
    static let botChatReportsCapability = "cron-bot-chat-reports"

    /// A profile's per-job choices: the jobs that don't notify, and the
    /// jobs delivered to a Bot Chat whose report starts the bot's turn.
    struct Choices: Equatable {
        var muted: Set<String> = []
        var act: Set<String> = []
        /// Whether this Hermes can show a report without a turn; without
        /// it every Bot Chat job takes Hermes' turn and there's no choice.
        var showsReports = false
    }
    static let path = "/api/plugins/conduit_push/cron/notifications"

    typealias Request = @MainActor (_ path: String, _ method: String, _ body: [String: Any]?) async throws -> [String: Any]

    enum Failure: Error {
        case malformed
    }

    private let request: Request

    init(request: @escaping Request) {
        self.request = request
    }

    /// The muted job ids.
    func muted(profile: String) async throws -> Set<String> {
        try Self.parse(await request(DashboardPath.withProfile(Self.path, profile: profile), "GET", nil))
    }

    /// Turns one job's notifications on or off; returns the muted ids as the
    /// host kept them.
    func setNotify(_ notify: Bool, jobID: String, profile: String) async throws -> Set<String> {
        try Self.parse(await request(
            DashboardPath.withProfile(Self.path, profile: profile),
            "PUT",
            ["job_id": jobID, "notify": notify]
        ))
    }

    /// Both choices; a plugin without the Bot Chat one lists no `act`.
    func choices(profile: String) async throws -> Choices {
        try Self.parseChoices(await request(DashboardPath.withProfile(Self.path, profile: profile), "GET", nil))
    }

    /// Whether one job's Bot Chat report starts the bot's turn; returns
    /// both choices as the host kept them.
    func setActs(_ act: Bool, jobID: String, profile: String) async throws -> Choices {
        try Self.parseChoices(await request(
            DashboardPath.withProfile(Self.path, profile: profile),
            "PUT",
            ["job_id": jobID, "act": act]
        ))
    }

    static func parseChoices(_ response: [String: Any]) throws -> Choices {
        let muted = try parse(response)
        guard let act = response["act"] else { return Choices(muted: muted) }
        guard let ids = act as? [String] else { throw Failure.malformed }
        return Choices(muted: muted, act: Set(ids), showsReports: response["shows_reports"] as? Bool ?? false)
    }

    static func parse(_ response: [String: Any]) throws -> Set<String> {
        guard response["ok"] as? Bool == true, let muted = response["muted"] as? [String] else {
            throw Failure.malformed
        }
        return Set(muted)
    }
}
