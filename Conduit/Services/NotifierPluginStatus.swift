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
    /// ROUTE_CAPABILITIES in hermes-conduit-notifier's dashboard/api/capabilities.py.
    static let usedCapabilities = [
        "session-takeover",
        "voice-sessions",
        "voice-tags",
        "voice-summary",
        "personality",
        "memory",
        "web-search",
        "gemini-live",
        "qwen-live",
        "gpt-live",
        "grok-live",
        "e2e-notifications",
        "desktop-views",
        "hermes-calls",
        DashboardPath.dashboardProfilesCapability,
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
    static let recommendedVersion = "0.48.0"

    /// The plugin version on notifier main when this build was archived
    /// (scripts/stamp-plugin-version.py): the stable version a build asks
    /// for by default, so each build moves it forward. Nil for a Run or CI
    /// build, or when GitHub couldn't be reached at archive time.
    static let archivedVersion = Bundle.main.object(forInfoDictionaryKey: "ConduitArchivedPluginVersion") as? String

    /// Where Hermes installs it from (`hermes plugins install …`).
    static let repository = "kaishi00/hermes-conduit-notifier"

    var state: State = .unknown
    /// The plugin's copy in Hermes' plugin list, read only while the
    /// capabilities route is missing. Nil when not read, or the host
    /// couldn't say.
    var hostCopy: HostCopy?

    enum HostCopy: Equatable {
        /// Hermes doesn't list the plugin.
        case missing
        /// Listed, older than 0.4 (or without a version): it predates the
        /// capabilities route, so an update brings it.
        case old
        /// Listed at 0.4 or newer, yet its routes don't answer: turned off,
        /// or installed after the dashboard started. Neither an install
        /// (Hermes refuses one over an existing copy) nor an update fixes
        /// it: turning it on and restarting the dashboard does
        /// (`isNotServed`).
        case notServed
    }

    /// The first plugin version that serves the capabilities route.
    static let capabilitiesVersion = "0.4.0"
    /// Nil until a plugin 0.24+ reports it.
    var runtime: Runtime?
    /// The plugin on its repository's main branch, when Conduit has read it
    /// (NotifierPluginLatestVersion.swift).
    var latestVersion: String?
    /// The stable plugin version (notifier main's channels.yaml), when read.
    /// It can raise the archived one between builds, never lower it.
    var stableVersion: String?
    /// This build's archived plugin version (`Self.archivedVersion`).
    var archivedVersion: String? = Self.archivedVersion
    /// The notice asks for every version on main; otherwise only up to the
    /// stable one (NotifierPluginNoticeChannel).
    var followsMain = true
    /// False: nothing asks for an update unprompted, only for the restart
    /// of one already on the host (NotifierPluginNoticeChannel.never).
    var asksToUpdate = true

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

    /// Installing it is the step: the capabilities route is missing and
    /// the host's list has no copy of it, or couldn't be read.
    var offersInstall: Bool {
        state == .predatesCapabilities && (hostCopy == .missing || hostCopy == nil)
    }

    /// The host has a 0.4+ copy that this dashboard doesn't run: Conduit
    /// offers no install or update, only the steps that turn it on.
    var isNotServed: Bool {
        state == .predatesCapabilities && hostCopy == .notServed
    }

    /// Settings points at the plugin's page: an update or the install is
    /// asked for, a restart is left, or the copy on the host isn't running.
    var needsAttention: Bool {
        updateRecommended || restartPending || isNotServed
    }

    /// Worth offering an update: something Conduit uses is missing, or the
    /// plugin is older than the version an update brings. A plugin that
    /// is already new enough on disk only needs its restart. Settings >
    /// Conduit plugin offers it; the notice waits for `updateRecommended`.
    var updateAvailable: Bool {
        isUpdate(below: offeredVersion)
    }

    /// Worth asking for an update unprompted: the update notice, the
    /// Settings badge and Finish setting up. On the stable channel a newer
    /// plugin on main alone doesn't count; on Never nothing does.
    var updateRecommended: Bool {
        asksToUpdate && isUpdate(below: noticeVersion)
    }

    private func isUpdate(below target: String) -> Bool {
        switch state {
        case .unknown:
            return false
        case .predatesCapabilities:
            return !isNotServed
        case .reported(let version, _):
            let older = Self.isOlder(version, than: target)
            return restartPending ? older : (needsUpdate || older)
        }
    }

    /// The version an update brings: the latest plugin, or this build's
    /// floor when the latest isn't known or is older.
    var offeredVersion: String {
        // Not older also means readable: an unreadable version counts as older.
        guard let latestVersion, !Self.isOlder(latestVersion, than: floorVersion) else {
            return floorVersion
        }
        return latestVersion
    }

    /// The least an update brings: this build's recommended version, or the
    /// plugin it was archived with, which main had then.
    var floorVersion: String {
        guard let archivedVersion, !Self.isOlder(archivedVersion, than: Self.recommendedVersion) else {
            return Self.recommendedVersion
        }
        return archivedVersion
    }

    /// The version below which the notice asks for an update: every
    /// version on main, or on the stable channel the newer of the archived
    /// and stable ones (never below this build's floor, never above what an
    /// update brings).
    var noticeVersion: String {
        guard !followsMain else { return offeredVersion }
        var target = floorVersion
        if let stableVersion, !Self.isOlder(stableVersion, than: target) {
            target = stableVersion
        }
        return Self.isOlder(offeredVersion, than: target) ? offeredVersion : target
    }

    /// The version a "Not now" on the notice belongs to. Never offers only
    /// restarts, so one is dismissed for the version waiting on disk: the
    /// next update's restart asks again.
    var noticeDismissalVersion: String {
        guard !asksToUpdate, restartPending, let version else { return noticeVersion }
        return version
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

    /// Whether the running plugin takes `?conduit_profile=` on the routes
    /// that need the dashboard process (DashboardPath.conduitProfileParameter).
    var servesDashboardProfiles: Bool { reports(DashboardPath.dashboardProfilesCapability) }

    /// The query parameter that names the profile on those routes.
    var dashboardProfileParameter: String {
        servesDashboardProfiles ? DashboardPath.conduitProfileParameter : "profile"
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

    /// Hermes' list of installed plugins, which `hostCopy` is read from.
    static let pluginsHubPath = "/api/dashboard/plugins/hub"

    /// This plugin in Hermes' plugin list, under its manifest name or the
    /// folder it was cloned into. Nil when the answer has no list.
    static func hostCopy(inPluginsHub response: [String: Any]) -> HostCopy? {
        guard response["plugins"] is [Any] else { return nil }
        let names: Set<String> = ["conduit_push", "hermes-conduit-notifier"]
        guard let row = AgentPluginRow.list(from: response).first(where: { names.contains($0.name) || names.contains($0.folderName) }) else {
            return .missing
        }
        return isOlder(row.version, than: capabilitiesVersion) ? .old : .notServed
    }

    static func state(from error: Error) -> State {
        if case DashboardTicketBridgeError.http(let status, _) = error, status == 404 || status == 405 {
            return .predatesCapabilities
        }
        return .unknown
    }
}

/// What the update notice over the main screen offers while no update
/// runs (AppState.showsNotifierPluginUpdateNotice).
enum NotifierPluginNoticeOffer: Equatable {
    case none
    /// The plugin isn't on the host, as far as Conduit can tell.
    case install
    case update
    /// The new plugin is on the host and waits for Hermes to restart.
    case restart
}

extension NotifierPluginStatus {
    /// `finishSetupOffersInstall`: the Finish setting up card is still
    /// pending, and its Conduit plugin row offers Install itself. One call
    /// to action is enough, and an Update for a plugin that isn't there
    /// misleads.
    func noticeOffer(finishSetupOffersInstall: Bool) -> NotifierPluginNoticeOffer {
        switch state {
        case .unknown:
            return .none
        case .predatesCapabilities:
            switch hostCopy {
            case .old: return asksToUpdate ? .update : .none
            // Nothing one tap fixes; Settings > Conduit plugin has the steps.
            case .notServed: return .none
            case .missing, nil: return finishSetupOffersInstall ? .none : .install
            }
        case .reported:
            if updateRecommended { return .update }
            if restartPending { return .restart }
            return .none
        }
    }
}
