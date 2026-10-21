//
//  AppState+FinishSetup.swift
//  Conduit
//
//  Finish setting up: a card at the top of Chats after the first
//  connection to a dashboard added on this iPhone, with the Conduit plugin
//  on its host, notifications and voice (V2FinishSetupCard). Not now, or
//  the last step done, ends it for that dashboard.
//

import Foundation
import UserNotifications

/// Where each step of Finish setting up stands.
struct FinishSetupStatus: Equatable {
    enum Plugin: Equatable {
        /// The host hasn't answered yet.
        case unknown
        case updating
        /// Missing, or too old to say what it serves (`offersInstall`).
        case install
        case update
        /// The new plugin is on the host and waits for Hermes to restart.
        case restart
        /// On the host, but this dashboard doesn't run it: turned off, or
        /// installed after it started (`NotifierPluginStatus.isNotServed`).
        case notRunning
        case done
    }

    enum Notifications: Equatable {
        case off
        /// iOS has notifications turned off for Conduit.
        case denied
        case done
    }

    var plugin: Plugin
    var notifications: Notifications
    var voiceReady: Bool

    var isComplete: Bool { plugin == .done && notifications == .done && voiceReady }

    static func plugin(_ status: NotifierPluginStatus, updating: Bool) -> Plugin {
        if updating { return .updating }
        switch status.state {
        case .unknown: return .unknown
        case .predatesCapabilities:
            if status.isNotServed { return .notRunning }
            return status.offersInstall ? .install : .update
        case .reported:
            if status.updateRecommended { return .update }
            if status.restartPending { return .restart }
            return .done
        }
    }

    /// Turned on in Conduit counts only while iOS allows them. Not asked
    /// yet (or not read yet, or reset by a reinstall that kept the
    /// registration) is off, so the card neither finishes early nor hides
    /// Turn on, which asks iOS.
    static func notifications(enabled: Bool, authorization: UNAuthorizationStatus) -> Notifications {
        switch authorization {
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return enabled ? .done : .off
        case .notDetermined: return .off
        @unknown default: return .off
        }
    }
}

extension AppState {
    static let finishSetupDashboardsKey = "conduit.finishSetup.dashboards"

    /// The card shows while connected to a dashboard still finishing setup,
    /// never over a saved copy of the chats.
    var showsFinishSetup: Bool {
        guard isConnected, offlineChatPresentation == nil, let id = activeDashboardID else { return false }
        return dashboardsFinishingSetup.contains(id)
    }

    /// Not now, or every step done: the card doesn't come back for the
    /// dashboard in use.
    func endFinishSetup() {
        guard let id = activeDashboardID, dashboardsFinishingSetup.contains(id) else { return }
        dashboardsFinishingSetup.remove(id)
    }

    /// Turn on from the card, as Settings > Notifications does: iOS asks
    /// first, then this dashboard's profile pairs right away rather than on
    /// the next connect.
    func turnOnNotificationsFromSetup() async {
        let notifications = PushNotificationService.shared
        let step = FinishSetupStatus.notifications(enabled: notifications.isEnabled, authorization: notifications.authorizationStatus)
        guard step == .off else { return }
        await notifications.enable()
        guard notifications.isEnabled, notifications.lastError == nil else {
            Haptics.error()
            return
        }
        Haptics.success()
        await refreshNotifierPluginStatus()
    }
}
