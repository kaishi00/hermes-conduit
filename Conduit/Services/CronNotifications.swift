import Foundation

/// Which cron jobs don't notify, as the host's notifier plugin keeps them
/// (plugin 0.33+, capability `cron-notifications`). A job not listed
/// notifies; a run that answers [SILENT] never does, whatever the setting.
final class CronNotificationsClient {
    static let capability = "cron-notifications"
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

    static func parse(_ response: [String: Any]) throws -> Set<String> {
        guard response["ok"] as? Bool == true, let muted = response["muted"] as? [String] else {
            throw Failure.malformed
        }
        return Set(muted)
    }
}
