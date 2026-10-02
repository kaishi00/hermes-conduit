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

    /// Plugin features Conduit uses, by the plugin's capability id.
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
    ]

    var state: State = .unknown

    var version: String? {
        if case .reported(let version, _) = state { return version }
        return nil
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

    static func state(from response: [String: Any]) -> State {
        guard response["ok"] as? Bool == true, let capabilities = response["capabilities"] as? [String] else {
            return .unknown
        }
        return .reported(version: response["version"] as? String, capabilities: Set(capabilities))
    }

    static func state(from error: Error) -> State {
        if case DashboardTicketBridgeError.http(let status, _) = error, status == 404 || status == 405 {
            return .predatesCapabilities
        }
        return .unknown
    }
}
