import UserNotifications

/// Conduit's notification categories, registered together: each
/// registration replaces the whole set, so it carries every category. At
/// launch and when the app's language changes, so their buttons read in it.
enum NotificationCategories {
    static func register(center: UNUserNotificationCenter = .current()) {
        center.setNotificationCategories([HermesCallNotifications.category(), PulseNotifications.category()])
    }
}

extension PulseNotifications {
    /// A Pulse push's category: Quiet for today, done in the background
    /// (ConduitAppDelegate). The extension gives it to a verified Pulse push
    /// from a dashboard whose plugin takes it.
    static func category() -> UNNotificationCategory {
        let quiet = UNNotificationAction(identifier: quietTodayActionIdentifier,
                                         title: AppLocalization.string("Quiet for today"), options: [])
        return UNNotificationCategory(identifier: categoryIdentifier, actions: [quiet], intentIdentifiers: [], options: [])
    }

    /// When Quiet for today couldn't reach Hermes from the background: a
    /// notification saying so, whose tap tries again with Conduit open.
    static func retryRequest(target: PulseQuietTarget?) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = AppLocalization.string("Pulse isn't quiet yet")
        content.body = AppLocalization.string("Conduit couldn't reach Hermes. Tap to try again.")
        content.threadIdentifier = "pulse"
        var userInfo: [String: String] = [:]
        if let dashboard = target?.dashboardID { userInfo[retryDashboardKey] = dashboard }
        if let gateway = target?.gatewayID { userInfo[retryGatewayKey] = gateway }
        content.userInfo = userInfo
        // One at a time: a second failure replaces the first.
        return UNNotificationRequest(identifier: retryIdentifier, content: content, trigger: nil)
    }

    /// Where a retry notification tries again; nil when the push it came
    /// from couldn't be read.
    static func retryTarget(_ userInfo: [AnyHashable: Any]) -> PulseQuietTarget? {
        let dashboard = userInfo[retryDashboardKey] as? String
        let gateway = userInfo[retryGatewayKey] as? String
        guard dashboard != nil || gateway != nil else { return nil }
        return PulseQuietTarget(dashboardID: dashboard, gatewayID: gateway)
    }
}
