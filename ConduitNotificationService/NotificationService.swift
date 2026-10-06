import UserNotifications

/// Decrypts end-to-end encrypted Conduit notifications on the iPhone (#431).
///
/// The relay sends encrypted pushes with the generic copy for their type and
/// `mutable-content`, so iOS hands them here first. A push that verifies gets
/// its real title and body (when Show previews is on). Anything that doesn't
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
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
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
            if NotificationSharedSettings.showPreviews {
                if let title = verified.content["title"] as? String, !title.isEmpty { content.title = title }
                if let body = verified.content["body"] as? String, !body.isEmpty { content.body = body }
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
        let copy = NotificationE2E.genericCopy(for: type)
        content.title = copy.title
        content.subtitle = ""
        content.body = copy.body
        content.userInfo = [:]
        return content
    }
}
