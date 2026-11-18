import Foundation

/// This device's opt-in is deliberately outside synced app preferences.
struct DeviceNotificationPairing {
    static let capability = "multi-device-notifications"
    static let e2ePath = "/api/plugins/conduit_push/e2e"
    private static let enabledKey = "conduit.notifications.all-bots-on-this-device"
    private static let registeredKey = "conduit.notifications.registered-device-profiles"
    let defaults: UserDefaults

    var enabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    func setEnabled(_ enabled: Bool) {
        if enabled && !self.enabled { defaults.removeObject(forKey: Self.registeredKey) }
        defaults.set(enabled, forKey: Self.enabledKey)
    }

    static func profiles(known: [String], active: String, allBots: Bool, supported: Bool) -> [String] {
        guard allBots else { return [active] }
        guard supported else { return [] }
        return Array(Set(known + [active])).sorted()
    }

    static func statusPath(profile: String, installationID: String?, supported: Bool) -> String {
        let path = DashboardPath.withProfile(e2ePath, profile: profile)
        guard supported, let installationID else { return path }
        return DashboardPath.withExplicitProfile(path, profile: installationID, parameter: "installation_id")
    }

    func shouldRegister(dashboardID: UUID, profile: String, installationID: String) -> Bool {
        !registered.contains(Self.key(dashboardID: dashboardID, profile: profile, installationID: installationID))
    }

    func remember(dashboardID: UUID, profile: String, installationID: String) {
        let key = Self.key(dashboardID: dashboardID, profile: profile, installationID: installationID)
        guard !registered.contains(key) else { return }
        defaults.set(registered + [key], forKey: Self.registeredKey)
    }

    private var registered: [String] { defaults.stringArray(forKey: Self.registeredKey) ?? [] }

    private static func key(dashboardID: UUID, profile: String, installationID: String) -> String {
        // Encode the tuple rather than joining with a separator a profile can contain.
        [dashboardID.uuidString, profile, installationID].map { Data($0.utf8).base64EncodedString() }.joined(separator: ":")
    }
}
