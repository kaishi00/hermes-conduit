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
/// nowhere. A group room's replies replace each other (one notification per
/// room, issue 2064). Conduit itself re-verifies the envelope on tap; nothing this
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
            // Never seen: with no copy to strip, only generic text goes out.
            deliver(Self.generic(UNMutableNotificationContent(), type: nil))
            return
        }
        // Only this extension writes the chat note, on a push it verified
        // (or a keyless pairing's room push): one the push arrived with is
        // dropped on every path.
        content.userInfo.removeValue(forKey: ReadChatHint.userInfoKey)
        let userInfo = content.userInfo
        let type = (NotificationE2E.routingStub(userInfo)?["type"] as? String)
        // Prepared up front so a timeout can only ever deliver generic text.
        // It takes the chat note once the push verifies.
        let prepared = Self.generic(content.mutableCopy() as? UNMutableNotificationContent ?? content, type: type)
        lock.withLock { fallback = prepared }

        switch NotificationE2E.evaluate(
            userInfo,
            records: KeychainE2EKeyStore().records(),
            knownGatewayIDs: NotificationSharedSettings.knownGatewayIDs,
            keysProvisioned: NotificationSharedSettings.keysProvisioned
        ) {
        case .legacy:
            // A keyless pairing's room push keeps one per room too (issue
            // 2064), noted like a verified one: the note only clears.
            let note = ReadChatHint.note(NotificationE2E.plaintextRouting(userInfo))
            if let thread = ReadChatHint.roomThread(note) {
                content.userInfo[ReadChatHint.userInfoKey] = note
                deliverInRoom(content, note: note, thread: thread, request: request)
                return
            }
            deliver(content)
        case .untrusted(let type):
            deliver(Self.generic(content, type: type))
        case .verified(let verified):
            // Which chat this is, for Conduit to clear it once that chat is read.
            let note = ReadChatHint.note(verified.routingPayload)
            lock.withLock {
                if let noted = fallback?.mutableCopy() as? UNMutableNotificationContent {
                    noted.userInfo[ReadChatHint.userInfoKey] = note
                    fallback = noted
                }
            }
            guard E2ESeenStore.shared.insert(verified.envelope.replayKey, namespace: "delivered") else {
                // A second copy: generic and routing nowhere, but it clears with its chat.
                let copy = Self.generic(content, type: verified.type)
                copy.userInfo[ReadChatHint.userInfoKey] = note
                deliver(copy)
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
            content.userInfo[ReadChatHint.userInfoKey] = note
            // Quiet for today on a Pulse push, where its plugin takes it.
            if PulseNotifications.offersQuietToday(
                titleLabel: verified.content["title_label"] as? String,
                gatewayID: verified.record.gatewayID,
                quietGateways: NotificationSharedSettings.pulseQuietGateways
            ) {
                content.categoryIdentifier = PulseNotifications.categoryIdentifier
            }
            if let thread = ReadChatHint.roomThread(note) {
                deliverInRoom(content, note: note, thread: thread, request: request)
                return
            }
            deliver(content)
        }
    }

    /// A group room keeps one notification: this one replaces the room's
    /// last, whichever bot sent it (issue 2064), and waits for one handed
    /// over just before it to show first.
    private func deliverInRoom(
        _ content: UNMutableNotificationContent, note: [String: String], thread: String, request: UNNotificationRequest
    ) {
        content.threadIdentifier = thread
        let pending = RoomHandoffs.record(request.identifier, thread: thread, defaults: NotificationSharedSettings.defaults)
        Self.replaceEarlier(
            in: note, pending: Set(pending), until: Date().addingTimeInterval(RoomHandoffs.wait)
        ) { [weak self] in self?.deliver(content) }
    }

    /// Removes the room's notifications already shown, and those `pending`
    /// once they show (two bots finishing together), until `deadline`.
    private static func replaceEarlier(
        in note: [String: String], pending: Set<String>, until deadline: Date, then: @escaping () -> Void
    ) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let shown = Set(delivered.map(\.request.identifier))
            let earlier = delivered
                .filter { ReadChatHint.replaces(note, delivered: $0.request.content.userInfo) }
                .map(\.request.identifier)
            let gone = Set(earlier).union(pending.intersection(shown))
            if !gone.isEmpty { center.removeDeliveredNotifications(withIdentifiers: Array(gone)) }
            let waiting = pending.subtracting(shown)
            guard !waiting.isEmpty, Date() < deadline else { return then() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                Self.replaceEarlier(in: note, pending: waiting, until: deadline, then: then)
            }
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
