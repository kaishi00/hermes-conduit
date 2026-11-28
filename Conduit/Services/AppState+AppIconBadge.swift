import Combine
import Foundation
import UserNotifications

/// The number on Conduit's app icon (issue 3458): the chats waiting on the
/// user, as AppIconBadge counts them. Counted again whenever the Chats
/// list, its read state, Needs you or the scene changes, and handed to the
/// Notification Service Extension (AppIconBadge.ledger), which counts each
/// push in while Conduit isn't running.
extension AppState {
    /// What moves the number: the list on screen and its read state, All's
    /// rows, and every dashboard's waits.
    func appIconBadgeChanges() -> AnyCancellable {
        let runtime = $runtimeOnScreen
            .map { runtime in
                Publishers.CombineLatest3(runtime.$sessions, runtime.$chatReadState, runtime.$allProfilesCatalog)
                    .map { _ in () }
            }
            .switchToLatest()
        let waits = Publishers.CombineLatest(needsYou.$items, needsYou.$otherDashboards).map { _ in () }
        return runtime.merge(with: waits)
            .sink { [weak self] _ in self?.scheduleAppIconBadgeRefresh() }
    }

    /// Counts again a moment from now: a burst of changes counts once.
    func scheduleAppIconBadgeRefresh() {
        appIconBadgeRefresh?.cancel()
        appIconBadgeRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.refreshAppIconBadge()
        }
    }

    func refreshAppIconBadge() async {
        let mode = AppIconBadge.mode
        let center = UNUserNotificationCenter.current()
        guard mode != .off else {
            AppIconBadge.ledger = AppIconBadge.Ledger()
            await setAppIconBadge(0, center: center)
            return
        }
        // Permission given before Conduit asked for badges (a step timer's
        // card asked for alerts and sounds only) has no Badges switch in
        // iOS Settings: asking again adds it, with no prompt.
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .authorized, settings.badgeSetting == .notSupported {
            _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
        }
        let known = appIconBadgeKnownChats(mode: mode)
        let delivered = await center.deliveredNotifications()
        guard !Task.isCancelled else { return }
        let records = PushNotificationService.e2eKeyStore.records()
        var counted: [AppIconBadge.Chat] = []
        var cleared: [[String]] = []
        for notification in delivered {
            let userInfo = notification.request.content.userInfo
            guard let chat = AppIconBadge.chat(userInfo: userInfo, mode: mode) else { continue }
            counted.append(chat)
            if appIconBadgeKnowsDone(chat, target: PushNotificationService.readChatTarget(from: userInfo, records: records)) {
                cleared.append(chat.ids)
            }
        }
        AppIconBadge.ledger = AppIconBadge.Ledger(known: known, cleared: cleared)
        await setAppIconBadge(
            AppIconBadge.count(known: known, delivered: counted, cleared: cleared, mode: mode),
            center: center
        )
    }

    private func setAppIconBadge(_ count: Int, center: UNUserNotificationCenter) async {
        guard count != appIconBadgeShown else { return }
        do {
            try await center.setBadgeCount(count)
            appIconBadgeShown = count
        } catch {
            appIconBadgeShown = nil
        }
    }

    /// The listed rows the number reads: the list on screen's, and All's
    /// other profiles' when All is on (as `profilesWithUnread`).
    private var appIconBadgeRows: [SessionSummary] {
        let others = isAllProfilesChatsOn && allProfilesCatalog.dashboardID == activeDashboardID
            ? allProfilesCatalog.sessions : []
        return sessions + others
    }

    private static func ids(_ session: SessionSummary) -> [String] {
        [session.id, session.storedSessionId, session.lineageRootId].compactMap { $0 }
    }

    private var appIconBadgeWaits: [NeedsYouItem] {
        needsYou.items + needsYou.otherDashboards.values.flatMap { $0 }
    }

    /// The chats this device knows wait on the user: unread rows (not
    /// under Needs you only) and every dashboard's waits.
    func appIconBadgeKnownChats(mode: AppIconBadge.Mode) -> [AppIconBadge.Chat] {
        var chats = appIconBadgeWaits.map { item in
            AppIconBadge.Chat(ids: item.sessionIDs + (item.roomID.map { ["room:\($0)"] } ?? []), waits: true)
        }
        if mode == .chats {
            chats += appIconBadgeRows.filter { isSessionUnread($0) }.map { AppIconBadge.Chat(ids: Self.ids($0), waits: false) }
        }
        return chats.filter { !$0.ids.isEmpty }
    }

    /// Whether a notification still in Notification Center is for a chat
    /// this device knows is read, or a wait it knows was answered: a chat
    /// read on another device keeps its notification here (only this
    /// device clears its own), and an answered wait's stays too.
    private func appIconBadgeKnowsDone(_ chat: AppIconBadge.Chat, target: ConduitNotificationTarget?) -> Bool {
        guard let target else { return false }
        let ownership = NotificationDashboardOwnership.resolve(
            targetDashboardID: target.dashboardID,
            hasMalformedDashboardID: target.hasMalformedDashboardID,
            activeDashboardID: activeDashboardID,
            savedDashboardIDs: savedDashboardRegistry.dashboards.map(\.id),
            targetGatewayID: target.relayGatewayID,
            activeDashboardGatewayIDs: activeDashboardRelayGatewayIDs
        )
        if chat.waits {
            // Answered: a dashboard whose waits were read names none for it.
            let read: Bool
            switch ownership {
            case .route: read = needsYou.dashboardID != nil && needsYou.dashboardID == activeDashboardID
            case .switchFirst(let dashboardID): read = needsYou.otherDashboards[dashboardID] != nil
            case .failClosed: read = false
            }
            return read && !appIconBadgeWaits.contains { chat.shares($0.sessionIDs) }
        }
        // Read: the list on screen has the chat, and it isn't unread.
        guard ownership == .route else { return false }
        let rows = appIconBadgeRows.filter { chat.shares(Self.ids($0)) }
        return !rows.isEmpty && !rows.contains { isSessionUnread($0) }
    }
}

extension AppIconBadge.Mode {
    var title: String {
        switch self {
        case .chats: return AppLocalization.string("Unread chats", table: .settings)
        case .needsYou: return AppLocalization.string("Needs you only", table: .settings)
        case .off: return AppLocalization.string("Off")
        }
    }

    var caption: String {
        switch self {
        case .chats:
            return AppLocalization.string("Counts the chats with a reply you haven't seen or an approval or question waiting on you.", table: .settings)
        case .needsYou:
            return AppLocalization.string("Counts the chats with an approval or question waiting on you.", table: .settings)
        case .off:
            return AppLocalization.string("Conduit's icon shows no number.", table: .settings)
        }
    }
}
