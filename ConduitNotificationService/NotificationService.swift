import UserNotifications

/// Decrypts end-to-end encrypted Conduit notifications on the iPhone (#431).
///
/// The relay sends encrypted pushes with the generic copy for their type and
/// `mutable-content`, so iOS hands them here first. Every encrypted push is
/// rewritten in the App Language (#1144): a push that verifies gets its real
/// title, profile and body with Show in notifications on Full previews
/// (NotificationCopy), its chat's title and profile over the generic body
/// with Chat names (#1415), and the generic copy for its type otherwise. Anything that doesn't
/// verify, is a replay, or is plaintext for a pairing that has a key shows
/// only the generic copy and loses its routing data, so tapping it routes
/// nowhere. Conduit itself re-verifies the envelope on tap; nothing this
/// extension writes into the notification is trusted on its own.
final class NotificationService: UNNotificationServiceExtension {
    // didReceive and serviceExtensionTimeWillExpire may run on different
    // threads; the lock makes sure the handler is called exactly once.
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var fallback: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        lock.withLock { self.contentHandler = contentHandler }
        AppLocalization.adopt(appLanguage: NotificationSharedSettings.appLanguage)
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            deliver(request.content)
            return
        }
        let userInfo = content.userInfo
        let type = (NotificationE2E.routingStub(userInfo)?["type"] as? String)
        // Prepared up front so a timeout can only ever deliver generic text.
        let prepared = Self.generic(content.mutableCopy() as? UNMutableNotificationContent ?? content, type: type)
        lock.withLock { fallback = prepared }

        switch NotificationE2E.evaluate(
            userInfo,
            records: KeychainE2EKeyStore().records(),
            knownGatewayIDs: NotificationSharedSettings.knownGatewayIDs,
            keysProvisioned: NotificationSharedSettings.keysProvisioned
        ) {
        case .legacy:
            deliver(content)
        case .untrusted(let type):
            deliver(Self.generic(content, type: type))
        case .verified(let verified):
            guard E2ESeenStore.shared.insert(verified.envelope.replayKey, namespace: "delivered") else {
                deliver(Self.generic(content, type: verified.type))
                return
            }
            let generic = NotificationCopy.generic(for: verified.type)
            content.title = generic.title
            content.subtitle = ""
            content.body = generic.body
            // The main bot by the name Conduit gives it on the push's dashboard.
            let named = NotificationCopy.named(verified.content, mainName: NotificationCopy.mainName(
                dashboardID: verified.record.dashboardID,
                activeDashboardID: NotificationSharedSettings.activeDashboardID,
                names: NotificationSharedSettings.mainProfileNames
            ))
            if NotificationSharedSettings.showPreviews {
                let preview = NotificationCopy.preview(named)
                if let title = preview.title { content.title = title }
                if let subtitle = preview.subtitle { content.subtitle = subtitle }
                if let body = preview.body { content.body = body }
            } else if NotificationSharedSettings.showChatNames {
                let names = NotificationCopy.chatNames(named)
                if let title = names.title { content.title = title }
                if let subtitle = names.subtitle { content.subtitle = subtitle }
            }
            // Quiet for today on a Pulse push, where its plugin takes it.
            if PulseNotifications.offersQuietToday(
                titleLabel: verified.content["title_label"] as? String,
                gatewayID: verified.record.gatewayID,
                quietGateways: NotificationSharedSettings.pulseQuietGateways
            ) {
                content.categoryIdentifier = PulseNotifications.categoryIdentifier
            }
            deliver(content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let fallback = lock.withLock({ fallback }) { deliver(fallback) }
    }

    private func deliver(_ content: UNNotificationContent) {
        let handler: ((UNNotificationContent) -> Void)? = lock.withLock {
            defer { contentHandler = nil }
            return contentHandler
        }
        handler?(content)
    }

    /// Generic copy, and no routing data or envelope left to act on.
    private static func generic(_ content: UNMutableNotificationContent, type: String?) -> UNMutableNotificationContent {
        let copy = NotificationCopy.generic(for: type)
        content.title = copy.title
        content.subtitle = ""
        content.body = copy.body
        content.userInfo = [:]
        // A call's Talk button would have nothing to open.
        content.categoryIdentifier = ""
        return content
    }
}
