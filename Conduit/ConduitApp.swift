//
//  ConduitApp.swift
//  Conduit — native SwiftUI iOS client for Hermes Agent
//
//  Created by Hermes Agent (Furina) — July 2026
//  This is a NATIVE SwiftUI app, not a React Native port.
//

import Combine
import SwiftUI
import UIKit
import UserNotifications
import os

private let backgroundPushLogger = Logger(subsystem: "com.milim.relay", category: "BackgroundPush")

final class ConduitAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // A "Hermes wants to talk" notification's Talk button (#449).
        HermesCallNotifications.registerCategory()
        // Set up before launch returns: a call the Apple Watch starts can
        // launch Conduit in the background, and its message waits on this.
        MainActor.assumeIsolated {
            // Low Power Mode and Low Data Mode stretch every poll.
            DeviceConditionsMonitor.shared.start()
            WatchVoiceLink.shared.activate()
            // Calls from Hermes ring through PushKit (#449): a call that
            // launched Conduit is delivered once the registry is up.
            HermesNativeCalls.shared.activate()
            // The relay needs this launch's push token if it changed.
            PushNotificationService.shared.refreshDeviceTokenAtLaunch()
            // Apple Health wakes Conduit when shared data changes, and a
            // background refresh catches up.
            AppState.registerHealthSyncTask()
            if HealthSyncPreferences.load().isOn {
                AppStateRuntimeRegistry.shared.appState.resumeHealthSyncAtLaunch()
            }
            // Saved places, visits and significant moves relaunch Conduit
            // in the background: their monitors are set up again before
            // launch returns so the event that woke it arrives.
            let location = LocationSharingController.shared
            if location.settings.isOn || location.configUnreadable {
                AppStateRuntimeRegistry.shared.appState.activateLocationSharing()
            }
            // Without background sharing the location monitor has no token
            // to report: say so, so a token the relay still holds is cleared
            // (notifier #287). An unreadable config says nothing yet.
            if !location.settings.background, !location.configUnreadable {
                PushNotificationService.shared.updateLocationToken(nil)
            }
            // Calendar, reminders and phone status: a background refresh, and
            // the calendar changing while Conduit runs.
            AppState.registerPhoneSyncTask()
            if PhoneSyncPreferences.load().isOn {
                AppStateRuntimeRegistry.shared.appState.resumePhoneSyncAtLaunch()
            }
            // Lock Screen progress of a turn sent before a relaunch (#605):
            // the chat's stream can still update and end it.
            LiveTurnActivities.shared.adoptExisting()
            // Hermes dictations whose words never came, from this run's
            // predecessor too: offered in the composer for Retry.
            Task { await DictationClipInbox.shared.load() }
        }
        Task.detached(priority: .background) {
            AttachmentStaging.sweepStaleFiles()
        }
        // iOS's daily usage and hang reports, kept on this device for
        // Diagnostics & logs. Subscribes on its own background queue.
        MetricKitReports.shared.start()
        if let payload = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            Task { @MainActor in
                PushNotificationService.shared.receiveNotificationPayload(payload)
            }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            PushNotificationService.shared.didReceiveDeviceToken(deviceToken)
        }
    }

    /// A background push: the host saying Hermes asked for a calendar change
    /// that applies without asking. Conduit fetches it from the host and
    /// applies it in the time iOS gives.
    ///
    /// The relay's only other silent push is its registration challenge: a
    /// nonce Conduit sends back to prove it holds this device token. Visible
    /// pushes are handled by the notification center delegate (willPresent /
    /// didReceive), so anything else here has nothing to do; it's logged so
    /// an unexpected one shows up.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        if let nonce = PushNotificationService.tokenChallenge(in: userInfo) {
            Task { @MainActor in
                PushNotificationService.shared.receiveTokenChallenge(nonce)
                completionHandler(.noData)
            }
            return
        }
        guard AppState.isPhoneChangesPush(userInfo) else {
            backgroundPushLogger.info("Background push that isn't a phone.changes push: nothing to do")
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            let outcome = await AppStateRuntimeRegistry.shared.appState.handlePhoneChangesPush(userInfo)
            switch outcome {
            case .synced?: completionHandler(.newData)
            case .failed?: completionHandler(.failed)
            default: completionHandler(.noData)
            }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            PushNotificationService.shared.didFailToRegister(error)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        // "Draft ready in Conduit" from the share sheet (#812): coming to the
        // front picks the draft up; one already on screen takes it now.
        if request.identifier.hasPrefix(ShareDraftInbox.notificationIdentifierPrefix), !(request.trigger is UNPushNotificationTrigger) {
            Task { @MainActor in
                AppStateRuntimeRegistry.shared.appState.sharedDraftWasStaged()
                completionHandler()
            }
            return
        }
        // Only the notification Conduit posted itself, never a push carrying the key.
        if request.identifier == MapsNavigator.notificationIdentifier, !(request.trigger is UNPushNotificationTrigger),
           let maps = MapsNavigator.url(fromNotification: request.content.userInfo) {
            // Directions Conduit couldn't open from the background: done once Maps opened.
            Task { @MainActor in
                _ = await UIApplication.shared.open(maps)
                completionHandler()
            }
            return
        }
        Task { @MainActor in
            if AppState.isPhoneChangesPush(request.content.userInfo) {
                // A calendar change Hermes asked for: its card shows once fetched.
                await AppStateRuntimeRegistry.shared.appState.handlePhoneChangesPush(request.content.userInfo)
            } else if request.trigger is UNPushNotificationTrigger {
                PushNotificationService.shared.receiveNotificationPayload(request.content.userInfo)
            } else {
                // Conduit posts only "Hermes wants to talk" itself (#449).
                PushNotificationService.shared.receiveLocalCallNotification(request.content.userInfo)
            }
            completionHandler()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // The active conversation is already visible while Conduit is in the
        // foreground. Keep remote pushes quiet here and reserve banners/sound
        // for when the app is not being actively used. A call from Hermes
        // (#449) still shows: it asks for the user, wherever they are.
        // A calendar change Hermes asked for while Conduit is open: fetch it
        // and show its card in the app instead of a banner.
        if AppState.isPhoneChangesPush(notification.request.content.userInfo) {
            let userInfo = notification.request.content.userInfo
            Task { @MainActor in
                await AppStateRuntimeRegistry.shared.appState.handlePhoneChangesPush(userInfo)
            }
            completionHandler([])
            return
        }
        // A draft shared while Conduit is on screen opens in it: no banner.
        if notification.request.identifier.hasPrefix(ShareDraftInbox.notificationIdentifierPrefix),
           !(notification.request.trigger is UNPushNotificationTrigger) {
            Task { @MainActor in
                AppStateRuntimeRegistry.shared.appState.sharedDraftWasStaged()
            }
            completionHandler([])
            return
        }
        // Directions to tap: posted from the background, kept if Conduit
        // came to the front before it showed.
        if notification.request.identifier == MapsNavigator.notificationIdentifier {
            completionHandler([.banner, .list, .sound])
            return
        }
        if notification.request.content.categoryIdentifier == HermesCallNotifications.categoryIdentifier {
            completionHandler([.banner, .list, .sound])
            return
        }
        // A step's timer from a rich card rings wherever the user is.
        if notification.request.identifier.hasPrefix(RichStepsMemory.notificationPrefix) {
            completionHandler([.banner, .list, .sound])
            return
        }
        completionHandler([])
    }
}

@main
struct ConduitApp: App {
    @UIApplicationDelegateAdaptor(ConduitAppDelegate.self) private var appDelegate
    /// Resolved through the process-wide registry (NOT created directly) so a
    /// CarPlay-first launch — where the CarPlay scene connects before any
    /// phone scene renders — binds the exact same AppState instance this
    /// SwiftUI surface adopts, whichever surface needs it first.
    @StateObject private var appState = AppStateRuntimeRegistry.shared.appState
    @ObservedObject private var notifications = PushNotificationService.shared
    @ObservedObject private var pendingVoiceIntents = PendingVoiceIntentStore.shared
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    /// The accent picked in Settings > Appearance (#697).
    @AppStorage(ConduitAccent.storageKey) private var accentChoice = ConduitAccent.defaultValue
    /// A chat another app asked to open (`conduit://session/<id>`), held
    /// until Hermes is connected: a cold launch opens it once connecting
    /// finishes instead of failing against an empty session list.
    @State private var pendingExternalLink: ConduitAppLink?

    var body: some Scene {
        // Multi-scene support is enabled in the manifest so the CarPlay
        // CPTemplateApplicationScene can coexist with the phone scene
        // (Apple: the flag governs ALL scene creation). SwiftUI's singleton
        // `Window` scene — the ideal foreground counterpart — is
        // iOS-unavailable (macOS 13+/visionOS only), so the phone surface
        // stays a `WindowGroup` and duplicate iPad windows are closed by the
        // RootView first-window guard instead: never an iPad multi-window
        // product.
        WindowGroup(id: "conduit-primary") {
#if DEBUG
            // The fixture is compiled out of release builds, so the launch
            // argument branch must be too.
            if ProcessInfo.processInfo.arguments.contains(SelectionFixtureView.launchArgument) {
                SelectionFixtureView()
            } else {
                rootContent
            }
#else
            rootContent
#endif
        }
    }

    private var rootContent: some View {
        RootView()
            .environmentObject(appState)
            // In-app App Language: literal SwiftUI keys resolve through the
            // same selection as AppLocalization.string(…). The environment
            // locale propagates reactively (Text re-renders without identity
            // changes), and every view holding String-context copy observes
            // AppLanguageStore itself, so switching language re-renders
            // exactly those views — the root is never rebuilt, and
            // navigation/composer/sheet/window-claim state is untouched.
            .environment(\.locale, appLanguage.resolvedLocale)
            .onChange(of: appLanguage.selection) { _, _ in
                // AppState-owned display caches (slash command descriptions)
                // re-resolve outside SwiftUI state, so view re-renders alone
                // cannot refresh them.
                appState.appLanguageDidChange()
                appState.publishWidgetLanguage()
                // The Notification Service Extension writes banners in it.
                NotificationSharedSettings.appLanguage = AppLanguage.current.rawValue
                HermesCallNotifications.registerCategory()
            }
            .preferredColorScheme(appState.themePreference.colorScheme)
            .tint(.conduitAccent)
            // The accent colours resolve the choice from this trait, so a
            // new pick redraws in place: no view is rebuilt.
            .environment(\.conduitAccent, accentChoice)
            .background(WindowAccentTint(choice: accentChoice))
            // Notes touches app-wide so the backdrop can rest when idle.
            .background(InteractionIdleTouchProbe())
            // The Watch app draws in the same accent. Shared once a pick
            // settles: dragging in the colour picker changes it many times.
            .task(id: accentChoice) {
                guard (try? await Task.sleep(for: .milliseconds(600))) != nil else { return }
                appState.shareWatchCallVoices()
            }
            // So does the padlock or shield: shared again once any change to
            // the notifications state settles (keys, confirmations, the
            // switch, and also unrelated ones such as push routes; the Watch
            // link sends only a context that differs from the last one).
            .task {
                let changes = PushNotificationService.shared.objectWillChange
                    .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
                for await _ in changes.values {
                    appState.shareWatchCallVoices()
                }
            }
            // And when the active dashboard changes, even when nothing about
            // notifications does (a switch whose sign-in fails).
            .task(id: appState.activeDashboardID) {
                appState.shareWatchCallVoices()
            }
#if DEBUG
            .modifier(WidgetLaunchUITestFixture.modifier(appState: appState))
            .modifier(ScreenshotCallFixtureModifier(appState: appState))
#endif
            // Links Conduit writes into chats (a voice call's job link)
            // open inside the app; every other link goes to the system.
            .environment(\.openURL, OpenURLAction { url in
                if appState.routeWidgetLaunchURL(url) { return .handled }
                // A sign-in code Hermes sent in a chat asks before it signs in.
                if appState.routeConnectLink(url) { return .handled }
                guard let link = ConduitAppLink(url: url) else {
                    // The scheme is registered, so the system would hand a
                    // conduit link Conduit can't read straight back to it.
                    return url.scheme?.lowercased() == ConduitAppLink.scheme ? .discarded : .systemAction
                }
                Task { @MainActor in appState.openAppLink(link) }
                return .handled
            })
            // On iPad (multiple scenes are on for CarPlay) SwiftUI opens a
            // new window for a link no open window claims, and the
            // duplicate-window guard would close it at once: the open
            // window takes every link, and every other external event
            // (Handoff) too, since Conduit has one window.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            // Another app opening a chat: only session links, opened through
            // the same route as an in-app link once Hermes is connected.
            .onOpenURL { url in
                if appState.routeWidgetLaunchURL(url) { return }
                // A sign-in code tapped in another app (a Telegram chat with
                // Hermes): Conduit asks before it signs in.
                if appState.routeConnectLink(url) { return }
                guard let link = ConduitAppLink(externalURL: url) else { return }
                pendingExternalLink = link
            }
            .task(id: externalLinkRouteKey) {
                guard appState.isConnected, let link = pendingExternalLink else { return }
                pendingExternalLink = nil
                appState.openAppLink(link)
            }
            // A draft shared from another app while Conduit is on screen.
            .task { SharedDraftStagedObserver.start() }
            // Pictures' sizes and cards' heights from earlier launches, read
            // once off the main thread as the app opens, so the rows of a
            // chat it restores take their final height when they mount
            // (#1238). ChatView asks too; a read under way is joined.
            .task { await TranscriptPictureMemory.loadKeptSizes() }
            .task { await PushNotificationService.shared.refresh() }
            // Siri learns the cached profile names for its profile phrases.
            .task { SiriProfileShortcuts.refresh() }
            .task(id: notificationRouteKey) {
                guard let target = notifications.pendingTarget else { return }
                if notifications.pendingRouteAwaitsCall {
                    // Waiting for the call its switch would have ended (or,
                    // after a relaunch, the one Conduit closing ended): it
                    // opens once there's no call and Conduit is on screen,
                    // unless a newer tap replaced it meanwhile.
                    guard await PushNotificationService.waitForCallToEnd(
                        interval: Self.callEndRecheckInterval,
                        isReady: { appState.callWaitCanEnd }
                    ), !Task.isCancelled, notifications.pendingTarget == target else { return }
                }
                // A refusal an earlier run left on the drawer shell's error
                // line is done with: the call it waited for ended, or this
                // tap replaced the one it was about.
                appState.clearCallRefusal()
                guard appState.isConnected else {
                    notifications.notificationRouteAwaitsConnection(target)
                    return
                }
                guard notifications.beginNotificationRoute(target) else {
                    // Its window ran out while the app was offline.
                    if target.call != nil {
                        HermesNativeCalls.shared.routedAnswerFailed(target)
                    }
                    return
                }
                let outcome = await appState.openNotificationTargetOutcome(target)
                // Cancelled: a newer tap, a reconnect or a retry started
                // this route over, and that run decides what happens. An
                // identical newer tap shares this target, so clearing it
                // here would drop that run's route.
                guard !Task.isCancelled else { return }
                switch outcome {
                case .opened:
                    // A call from Hermes (#449) opens voice in its chat,
                    // unless its CallKit call ended meanwhile and let go of
                    // the route. Started before the route clears, which ends
                    // this task.
                    if let call = target.call, notifications.pendingTarget == target, !appState.answerHermesCall(call) {
                        HermesNativeCalls.shared.routedAnswerFailed(target)
                    }
                    notifications.clearPendingTarget(target)
                case .retry, .unverified:
                    if !notifications.handleFailedNotificationRoute(target) {
                        // The window ran out: the last failure says why, if
                        // it has something to say.
                        if case .unverified(let message) = outcome {
                            appState.errorMessage = message
                        }
                        if target.call != nil {
                            HermesNativeCalls.shared.routedAnswerFailed(target)
                        }
                    }
                case .failed:
                    // The open already said why it can't; another try would
                    // only say it again.
                    notifications.clearPendingTarget(target)
                    if target.call != nil {
                        HermesNativeCalls.shared.routedAnswerFailed(target)
                    }
                case .afterCall:
                    // It said it opens when the call ends; never a call's
                    // own open, which switches during its call.
                    notifications.notificationRouteAwaitsCall(target)
                }
            }
            .task(id: voiceIntentRouteKey) {
                // Siri's call shows its screen while it waits for Hermes.
                appState.presentWaitingCallIfNeeded()
                // A screenshot waits for Conduit to settle after connecting.
                // Settling can end on state this view doesn't observe, so
                // the route is retried on a short timer; the launch
                // deadline still bounds the wait.
                while await resolvePendingVoiceIntent() {
                    do { try await Task.sleep(for: Self.settleRecheckInterval) } catch { return }
                }
            }
            .task(id: voiceIntentDeadlineKey) {
                await waitOutPendingVoiceDeadline()
            }
            // A screenshot kept while Hermes was unreachable is attached
            // once it connects and settles.
            .task(id: parkedScreenQuestionKey) {
                appState.scheduleParkedScreenQuestionResume(recheck: Self.settleRecheckInterval)
            }
    }

    /// How often a screenshot waiting for Conduit to settle checks again.
    private static let settleRecheckInterval: Duration = .milliseconds(250)

    /// How often a notification waiting for a call checks it again; it
    /// opens once two checks in a row find no call, with Conduit on screen.
    private static let callEndRecheckInterval: Duration = .seconds(1)

    private var parkedScreenQuestionKey: String {
        "\(appState.isConnected):\(appState.isConnecting):\(appState.isProfileSwitching):\(appState.parkedScreenQuestionRevision)"
    }

    private var notificationRouteKey: String {
        "\(notifications.pendingTarget?.id ?? "none"):\(appState.isConnected):\(notifications.navigationAttempt)"
    }

    private var externalLinkRouteKey: String {
        "\(pendingExternalLink?.url.absoluteString ?? "none"):\(appState.isConnected)"
    }

    private var voiceIntentRouteKey: String {
        let connection = appState.voiceLaunchConnectionSnapshot()
        // Phase (not a bare isConnected flag) so connecting → stableFailure
        // re-evaluates the pending request while remaining disconnected.
        // Do not embed pendingSource: take() clears it without a revision
        // bump, and openVoiceConversation’s @Published mutations would flip
        // the key mid-handler and cancel the in-flight route task.
        return "\(pendingVoiceIntents.revision):\(connection.phase.rawValue)"
    }

    /// Deadline changes (new Siri enqueue / supersede) re-arm the wait; the
    /// revision already covers every other store mutation.
    private var voiceIntentDeadlineKey: String {
        guard let deadline = pendingVoiceIntents.pendingExternalLaunchDeadline else { return "none" }
        return "\(pendingVoiceIntents.revision):\(Int(deadline.timeIntervalSinceReferenceDate))"
    }

    /// Resolves the pending voice launch once. Ownership token: only the
    /// claimed request may be routed or failed; a superseded completion is
    /// discarded without publishing. Returns true when a screenshot is
    /// left waiting for Conduit to settle.
    private func resolvePendingVoiceIntent() async -> Bool {
        let router = PendingVoiceIntentRouter(store: pendingVoiceIntents)
        let connection = appState.voiceLaunchConnectionSnapshot()
        // The router takes this exact request first, before it awaits.
        let routed = pendingVoiceIntents.peekClaim()?.intent
        var screenQuestionOpened: Bool?
        let outcome = await router.routePending(connection: connection) { intent in
            if intent.source == .screenQuestion {
                let opened = await appState.openScreenQuestion(intent)
                screenQuestionOpened = opened
                return opened
            }
            return await appState.openVoiceConversation(intent)
        }
        switch outcome {
        case .failed(let message):
            // Its call screen, if one came up for it, goes.
            appState.endWaitingCall(owner: .siri)
            // A screenshot is kept when Hermes can't be reached: it is
            // attached once Hermes connects and Conduit settles.
            let request = routed?.screenQuestion
            if let request {
                appState.parkScreenQuestion(request, profile: routed?.profile)
            }
            // Past its deadline while connected but still settling, Hermes
            // was reached: the screenshot waits without the banner.
            if request == nil || !appState.isConnected {
                appState.errorMessage = message
            }
        case .superseded:
            // A newer request took over while this one found Hermes gone.
            // A call screen up for this one waits for that one instead.
            if screenQuestionOpened == false, let request = routed?.screenQuestion {
                appState.settleSupersededScreenQuestion(
                    request,
                    profile: routed?.profile,
                    newerScreenQuestionPending: pendingVoiceIntents.peekClaim()?.intent.screenQuestion != nil
                )
            }
        case .deferred:
            return routed?.screenQuestion != nil && connection.isSettling
        case .idle, .routed:
            // A call screen that came up for a launch that didn't open its
            // call (nothing pending now, or voice refused it) goes.
            appState.endWaitingCall(owner: .siri)
        }
        return false
    }

    /// Authoritative 30s backstop. Sleeps on the monotonic clock, then
    /// expires the exact claim that armed the wait — never routes through
    /// generic readiness (which could return `.waiting` again).
    private func waitOutPendingVoiceDeadline() async {
        guard let claim = pendingVoiceIntents.peekClaim(),
              let elapsedDeadline = claim.intent.externalLaunchElapsedDeadline else {
            return
        }
        let now = ContinuousClock.now
        if now < elapsedDeadline {
            do {
                try await Task.sleep(for: now.duration(to: elapsedDeadline))
            } catch {
                // Superseded/cancelled waiter must not resolve a different intent.
                return
            }
        }
        guard let expired = pendingVoiceIntents.expireClaimIfCurrent(claim) else {
            return
        }
        appState.endWaitingCall(owner: .siri)
        if expired.source == .siri {
            appState.errorMessage = PendingVoiceLaunchPolicy.expiredFailureMessage
        } else if let request = expired.screenQuestion {
            appState.parkScreenQuestion(request, profile: expired.profile)
            // Connected but still settling, Hermes was reached: the
            // screenshot is attached once Conduit settles.
            if !appState.isConnected {
                appState.errorMessage = PendingVoiceLaunchPolicy.screenQuestionFailureMessage
            }
        }
    }
}
