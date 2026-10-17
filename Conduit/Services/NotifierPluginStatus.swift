import Foundation

/// What the host's Conduit notifier plugin serves, from its capabilities
/// route (plugin 0.4+). Conduit uses it to nudge an update when a feature it
/// relies on is missing, instead of finding out when the feature is used.
struct NotifierPluginStatus: Equatable {
    enum State: Equatable {
        /// Not asked yet, or the host couldn't answer.
        case unknown
        /// The route is missing: the plugin is older than 0.4 or isn't installed.
        case predatesCapabilities
        case reported(version: String?, capabilities: Set<String>)
    }

    static let path = "/api/plugins/conduit_push/capabilities"

    /// Plugin features Conduit uses, by the plugin's capability id. Must match
    /// ROUTE_CAPABILITIES in hermes-conduit-notifier's dashboard/plugin_api.py.
    static let usedCapabilities = [
        "session-takeover",
        "voice-sessions",
        "voice-tags",
        "voice-summary",
        "personality",
        "memory",
        "web-search",
        "gemini-live",
        "gpt-live",
        "grok-live",
        "e2e-notifications",
        "desktop-views",
        "hermes-calls",
        // "watch-chats" is left out on purpose: only Watch calls use it, and
        // they fall back to the phone without it, so it's no reason to nag.
    ]

    /// What a plugin 0.24+ adds to its report: which version this dashboard
    /// process is actually running, since Hermes imports the plugin's routes
    /// once and a `hermes plugins update` only changes the files on disk.
    struct Runtime: Equatable {
        /// The version the dashboard process imported.
        var loadedVersion: String?
        /// The files on disk are another version than the running one.
        var restartNeeded: Bool
        /// New with every dashboard process.
        var bootID: String?
    }

    /// The plugin version this Conduit build was made against: the least it
    /// offers, even when GitHub can't be reached for the latest
    /// (`latestVersion`).
    static let recommendedVersion = "0.44.0"

    /// Where Hermes installs it from (`hermes plugins install …`).
    static let repository = "kaishi00/hermes-conduit-notifier"

    var state: State = .unknown
    /// Nil until a plugin 0.24+ reports it.
    var runtime: Runtime?
    /// The plugin on its repository's main branch, when Conduit has read it
    /// (NotifierPluginLatestVersion.swift).
    var latestVersion: String?

    /// The version installed on disk, as the plugin reports it.
    var version: String? {
        if case .reported(let version, _) = state { return version }
        return nil
    }

    /// The version the dashboard is serving. Older plugins only report the
    /// version on disk, which is the best there is.
    var runningVersion: String? {
        runtime?.loadedVersion ?? (restartPending ? nil : version)
    }

    /// The plugin was updated on disk but the dashboard still runs the old
    /// one. A plugin that reports 0.24+ on disk without the running version
    /// is old code serving new files: every 0.24+ reports it.
    var restartPending: Bool {
        if let runtime { return runtime.restartNeeded }
        guard case .reported(let version, _) = state else { return false }
        return version != nil && !Self.isOlder(version, than: Self.runtimeReportingVersion)
    }

    /// The first plugin version that reports `loaded_version`.
    static let runtimeReportingVersion = "0.24.0"

    /// The plugin on the host is missing or older than one-tap updates
    /// (0.24), so the first update after installing a new Conduit build is a
    /// manual one. Not a 0.24+ on disk that the old process still serves:
    /// that one only needs its restart.
    var predatesOneTapUpdate: Bool {
        guard runtime == nil else { return false }
        switch state {
        case .unknown: return false
        case .predatesCapabilities: return true
        case .reported(let version, _): return Self.isOlder(version, than: Self.runtimeReportingVersion)
        }
    }

    /// Worth offering an update: something Conduit uses is missing, or the
    /// plugin is older than the version an update brings. A plugin that
    /// is already new enough on disk only needs its restart.
    var updateAvailable: Bool {
        switch state {
        case .unknown:
            return false
        case .predatesCapabilities:
            return true
        case .reported(let version, _):
            let older = Self.isOlder(version, than: offeredVersion)
            return restartPending ? older : (needsUpdate || older)
        }
    }

    /// The version an update brings: the latest plugin, or this build's
    /// recommended one when the latest isn't known or is older.
    var offeredVersion: String {
        // Not older also means readable: an unreadable version counts as older.
        guard let latestVersion, !Self.isOlder(latestVersion, than: Self.recommendedVersion) else {
            return Self.recommendedVersion
        }
        return latestVersion
    }

    /// Dotted numeric versions compared part by part ("0.9.1" < "0.10.0").
    /// An unreadable or missing version counts as older.
    static func isOlder(_ version: String?, than other: String) -> Bool {
        guard let version, let lhs = numericParts(version), let rhs = numericParts(other) else { return true }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    private static func numericParts(_ version: String) -> [Int]? {
        let core = version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? version
        let parts = core.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }
    }

    /// Whether the plugin should be updated: it predates capability
    /// reporting, or it reports without a feature Conduit uses.
    var needsUpdate: Bool {
        switch state {
        case .unknown: return false
        case .predatesCapabilities: return true
        case .reported(_, let capabilities):
            return Self.usedCapabilities.contains { !capabilities.contains($0) }
        }
    }

    /// False only when the plugin reported its capabilities without this
    /// one. A plugin that predates reporting may still serve it.
    func mightSupport(_ capability: String) -> Bool {
        if case .reported(_, let capabilities) = state { return capabilities.contains(capability) }
        return true
    }

    /// The plugin version whose /voice-tools serves the location tool.
    static let locationVoiceVersion = "0.28.0"

    /// Whether the running plugin answers live voice reads of the location.
    /// Older ones serve /voice-tools with health only.
    var servesLocationVoice: Bool {
        reports("voice-tools") && !Self.isOlder(runningVersion, than: Self.locationVoiceVersion)
    }

    /// True only when the plugin reported this capability.
    func reports(_ capability: String) -> Bool {
        if case .reported(_, let capabilities) = state { return capabilities.contains(capability) }
        return false
    }

    static func state(from response: [String: Any]) -> State {
        guard response["ok"] as? Bool == true, let capabilities = response["capabilities"] as? [String] else {
            return .unknown
        }
        return .reported(version: response["version"] as? String, capabilities: Set(capabilities))
    }

    static func runtime(from response: [String: Any]) -> Runtime? {
        guard response["ok"] as? Bool == true, response.keys.contains("loaded_version") else { return nil }
        return Runtime(
            loadedVersion: response["loaded_version"] as? String,
            restartNeeded: response["restart_needed"] as? Bool ?? false,
            bootID: response["boot_id"] as? String
        )
    }

    static func state(from error: Error) -> State {
        if case DashboardTicketBridgeError.http(let status, _) = error, status == 404 || status == 405 {
            return .predatesCapabilities
        }
        return .unknown
    }
}
