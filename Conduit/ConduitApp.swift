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
                        notifications.discardPendingTarget(target)
                    }
                }
                .task(id: voiceIntentRouteKey) {
                    guard appState.isConnected else { return }
                    let router = PendingVoiceIntentRouter(store: pendingVoiceIntents)
                    await router.routePending { intent in
                        await appState.openVoiceConversation(intent)
                    }
                }
        }
    }

    private var notificationRouteKey: String {
        "\(notifications.pendingTarget?.id ?? "none"):\(appState.isConnected):\(notifications.navigationAttempt)"
    }

    private var voiceIntentRouteKey: String {
        "\(pendingVoiceIntents.revision):\(appState.isConnected)"
    }
}
