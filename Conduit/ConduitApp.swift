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
        Task { @MainActor in
            PushNotificationService.shared.receiveNotificationPayload(response.notification.request.content.userInfo)
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
        // for when the app is not being actively used.
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
            }
            .preferredColorScheme(appState.themePreference.colorScheme)
            .tint(.conduitAccent)
            // Links Conduit writes into chats (a voice call's job link)
            // open inside the app; every other link goes to the system.
            .environment(\.openURL, OpenURLAction { url in
                guard let link = ConduitAppLink(url: url) else { return .systemAction }
                Task { @MainActor in appState.openAppLink(link) }
                return .handled
            })
            .task { await PushNotificationService.shared.refresh() }
            // Siri learns the cached profile names for its profile phrases.
            .task { SiriProfileShortcuts.refresh() }
            .task(id: notificationRouteKey) {
                guard appState.isConnected, let target = notifications.pendingTarget else { return }
                if await appState.openNotificationTarget(target) {
                    notifications.clearPendingTarget(target)
                } else {
                    notifications.handleFailedNotificationRoute(target)
                }
            }
            .task(id: voiceIntentRouteKey) {
                await resolvePendingVoiceIntent()
            }
            .task(id: voiceIntentDeadlineKey) {
                await waitOutPendingVoiceDeadline()
            }
            // A screenshot kept while Hermes was unreachable is attached
            // once it connects and settles.
            .task(id: parkedScreenQuestionKey) {
                // Not cancelled with this task: the resume can switch
                // profiles, which changes the key.
                Task { await appState.resumeParkedScreenQuestion() }
            }
    }

    private var parkedScreenQuestionKey: String {
        "\(appState.isConnected):\(appState.isConnecting):\(appState.isProfileSwitching):\(appState.parkedScreenQuestionRevision)"
    }

    private var notificationRouteKey: String {
        "\(notifications.pendingTarget?.id ?? "none"):\(appState.isConnected):\(notifications.navigationAttempt)"
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
    /// discarded without publishing.
    private func resolvePendingVoiceIntent() async {
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
            // attached, with the keyboard, once Hermes connects.
            if let request = routed?.screenQuestion {
                appState.parkScreenQuestion(request, profile: routed?.profile)
            }
            appState.errorMessage = message
        case .superseded:
            // A newer request took over while this one found Hermes gone.
            if screenQuestionOpened == false, let request = routed?.screenQuestion {
                appState.settleSupersededScreenQuestion(
                    request,
                    profile: routed?.profile,
                    newerScreenQuestionPending: pendingVoiceIntents.peekClaim()?.intent.screenQuestion != nil
                )
            }
        case .idle, .routed, .deferred:
            break
        }
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
            appState.errorMessage = PendingVoiceLaunchPolicy.screenQuestionFailureMessage
        }
    }
}
