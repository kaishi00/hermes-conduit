import Foundation

/// Which plugin versions the update notice asks for (Settings > Conduit
/// plugin > Update notices). Everyone hears about the stable version unless
/// they choose otherwise: asking after each plugin merge between Conduit
/// releases nags. Testers who want every release pick Every new version.
enum NotifierPluginNoticeChannel: String, CaseIterable, Identifiable {
    /// Every plugin version on main.
    case everyVersion
    /// Only the stable version: the plugin this build was archived with,
    /// or channels.yaml's `stable:` when that is newer.
    case stableOnly
    /// No notice for any version or missing feature: updates wait in
    /// Settings > Conduit plugin. An update already on the host still asks
    /// for its restart.
    case never

    static let key = "conduit.notifierPlugin.noticeChannel"

    var id: String { rawValue }

    /// Stable versions only when nothing is saved, and for the Automatic
    /// choice this replaced, which asked TestFlight builds for every version
    /// (2026-10-30, too many plugin updates).
    static func load(from defaults: UserDefaults) -> NotifierPluginNoticeChannel {
        defaults.string(forKey: key).flatMap(NotifierPluginNoticeChannel.init(rawValue:)) ?? .stableOnly
    }

    /// Whether the notice asks for every version on main.
    var followsMain: Bool { self == .everyVersion }

    /// Whether the notice, the Settings card and Finish setting up ask for
    /// an update at all.
    var asksToUpdate: Bool { self != .never }
}
