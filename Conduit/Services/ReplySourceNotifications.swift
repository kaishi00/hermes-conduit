import Foundation

/// Where a message Hermes replies to was sent from, as the host's notifier
/// plugin tells them apart (plugin 0.35+, capability `reply-sources`).
enum ReplySource: String, CaseIterable, Identifiable {
    case conduit, desktop, messaging, terminal

    var id: String { rawValue }
}

/// Which sources' replies send a "Response ready" notification, per profile,
/// as the host's notifier plugin keeps them. Every source notifies until the
/// user turns it off; approvals, questions, failures, tasks and calls don't
/// follow this.
final class ReplySourcesClient {
    static let capability = "reply-sources"
    static let path = "/api/plugins/conduit_push/notifications/reply-sources"

    typealias Request = @MainActor (_ path: String, _ method: String, _ body: [String: Any]?) async throws -> [String: Any]

    enum Failure: LocalizedError {
        case malformed

        var errorDescription: String? {
            AppLocalization.string("The host's answer couldn't be read. Update the Conduit plugin and try again.")
        }
    }

    private let request: Request

    init(request: @escaping Request) {
        self.request = request
    }

    /// Whether each source's replies notify.
    func settings(profile: String) async throws -> [ReplySource: Bool] {
        try Self.parse(await request(DashboardPath.withProfile(Self.path, profile: profile), "GET", nil))
    }

    /// Turns one source's reply notifications on or off; returns every
    /// source as the host kept them.
    func setNotify(_ notify: Bool, source: ReplySource, profile: String) async throws -> [ReplySource: Bool] {
        try Self.parse(await request(
            DashboardPath.withProfile(Self.path, profile: profile),
            "PUT",
            ["source": source.rawValue, "notify": notify]
        ))
    }

    /// A source the host doesn't list notifies, as the host defaults; one
    /// this app doesn't know is ignored.
    static func parse(_ response: [String: Any]) throws -> [ReplySource: Bool] {
        guard response["ok"] as? Bool == true, let sources = response["sources"] as? [String: Any] else {
            throw Failure.malformed
        }
        var settings: [ReplySource: Bool] = [:]
        for source in ReplySource.allCases {
            settings[source] = sources[source.rawValue] as? Bool ?? true
        }
        return settings
    }
}
