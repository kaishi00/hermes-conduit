import Foundation

/// Pulse's pushes on the iPhone: their category, which carries Quiet for
/// today where the host's plugin takes it (Pulse's quiet times, notifier
/// 0.80.2). Shared with the Notification Service Extension, which gives a
/// verified Pulse push the category; the app registers the category
/// (NotificationCategories) and handles the button.
enum PulseNotifications {
    static let categoryIdentifier = "PULSE"
    static let quietTodayActionIdentifier = "PULSE_QUIET_TODAY"
    /// The notification Conduit posts when Quiet for today couldn't reach
    /// Hermes from the background; its tap tries again with Conduit open.
    static let retryIdentifier = "pulse-quiet-retry"
    /// Where that notification keeps the push's dashboard and relay
    /// gateway, to try again on.
    static let retryDashboardKey = "conduit_pulse_quiet_dashboard"
    static let retryGatewayKey = "conduit_pulse_quiet_gateway"

    /// Whether a verified push offers Quiet for today: a Pulse push
    /// (`title_label` pulse.<kind>) through a relay gateway whose host's
    /// plugin takes it (`quietGateways`, as NotificationSharedSettings keeps
    /// them).
    static func offersQuietToday(titleLabel: String?, gatewayID: String, quietGateways: Set<String>) -> Bool {
        guard let titleLabel, titleLabel.hasPrefix("pulse.") else { return false }
        let gateway = gatewayID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !gateway.isEmpty && quietGateways.contains(gateway)
    }
}

/// Where Quiet for today is for: the dashboard and relay gateway the Pulse
/// push came from, as the key it was sealed with says.
struct PulseQuietTarget: Equatable {
    let dashboardID: String?
    let gatewayID: String?
}
