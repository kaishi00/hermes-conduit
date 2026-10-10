//
//  ConduitApp.swift
//  Conduit — native SwiftUI iOS client for Hermes Agent
//
//  Created by Hermes Agent (Furina) — July 2026
//  This is a NATIVE SwiftUI app, not a React Native port.
//

import SwiftUI
import UIKit
import UserNotifications

final class ConduitAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // A "Hermes wants to talk" notification's Talk button (#449).
        HermesCallNotifications.registerCategory()
        // Set up before launch returns: a call the Apple Watch starts can
        // launch Conduit in the background, and its message waits on this.
        MainActor.assumeIsolated {
            WatchVoiceLink.shared.activate()
            // Calls from Hermes ring through PushKit (#449): a call that
            // launched Conduit is delivered once the registry is up.
            HermesNativeCalls.shared.activate()
        }
        Task.detached(priority: .background) {
            AttachmentStaging.sweepStaleFiles()
        }
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
        Task { @MainActor in
            if request.trigger is UNPushNotificationTrigger {
                PushNotificationService.shared.receiveNotificationPayload(request.content.userInfo)
            } else {
                // Conduit posts only "Hermes wants to talk" itself (#449).
                PushNotificationService.shared.receiveLocalCallNotification(request.content.userInfo)
            }
        }
        completionHandler()
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
        if notification.request.content.categoryIdentifier == HermesCallNotifications.categoryIdentifier {
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
                HermesCallNotifications.registerCategory()
            }
            .preferredColorScheme(appState.themePreference.colorScheme)
            .tint(.conduitAccent)
            // Links Conduit writes into chats (a voice call's job link)
            // open inside the app; every other link goes to the system.
            .environment(\.openURL, OpenURLAction { url in
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
                guard let link = ConduitAppLink(externalURL: url) else { return }
                pendingExternalLink = link
            }
            .task(id: externalLinkRouteKey) {
                guard appState.isConnected, let link = pendingExternalLink else { return }
                pendingExternalLink = nil
                appState.openAppLink(link)
            }
            .task { await PushNotificationService.shared.refresh() }
            // Siri learns the cached profile names for its profile phrases.
            .task { SiriProfileShortcuts.refresh() }
            .task(id: notificationRouteKey) {
                guard appState.isConnected, let target = notifications.pendingTarget else { return }
                if await appState.openNotificationTarget(target) {
                    // A call from Hermes (#449) opens voice in its chat,
                    // unless its CallKit call ended meanwhile and let go of
                    // the route. Started before the route clears, which ends
                    // this task.
                    if let call = target.call, notifications.pendingTarget == target, !appState.answerHermesCall(call) {
                        HermesNativeCalls.shared.routedAnswerFailed(target)
                    }
                    notifications.clearPendingTarget(target)
                } else if !notifications.handleFailedNotificationRoute(target), target.call != nil {
                    HermesNativeCalls.shared.routedAnswerFailed(target)
                }
            }
            .task(id: voiceIntentRouteKey) {
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
            break
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
