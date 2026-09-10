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
    @StateObject private var appState = AppState()
    @ObservedObject private var notifications = PushNotificationService.shared
    @ObservedObject private var pendingVoiceIntents = PendingVoiceIntentStore.shared

    var body: some Scene {
        WindowGroup {
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
            .preferredColorScheme(appState.themePreference.colorScheme)
            .tint(.conduitAccent)
            .task { await PushNotificationService.shared.refresh() }
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

    /// Resolves the pending voice launch once. Connected Siri/in-app routes
    /// consume the request; expired or stable-failed external requests fail
    /// with a visible error and are discarded so a later reconnect cannot
    /// resurrect them.
    private func resolvePendingVoiceIntent() async {
        let router = PendingVoiceIntentRouter(store: pendingVoiceIntents)
        let connection = appState.voiceLaunchConnectionSnapshot()
        let outcome = await router.routePending(connection: connection) { intent in
            await appState.openVoiceConversation(intent)
        }
        if case .failed(let message) = outcome {
            appState.errorMessage = message
        }
    }

    /// Siri external launches are bounded: when the launch window ends
    /// without Hermes becoming ready, fail the request immediately instead of
    /// leaving it pending across an arbitrary later reconnect.
    private func waitOutPendingVoiceDeadline() async {
        guard let deadline = pendingVoiceIntents.pendingExternalLaunchDeadline else { return }
        let remaining = deadline.timeIntervalSinceNow
        if remaining > 0 {
            do {
                try await Task.sleep(for: .seconds(remaining))
            } catch {
                // Superseded/cancelled waiter must not resolve a different intent.
                return
            }
        }
        await resolvePendingVoiceIntent()
    }
}
