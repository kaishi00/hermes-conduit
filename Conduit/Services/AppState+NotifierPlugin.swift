//
//  AppState+NotifierPlugin.swift
//  Conduit
//
//  The Conduit plugin's status on this dashboard: its version and the
//  newest one, its changelog and notice channel, and provisioning
//  notification encryption. Moved out of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - The Conduit plugin's status on this dashboard

    var freshNotifierPluginStatus: NotifierPluginStatus {
        NotifierPluginStatus(
            latestVersion: latestNotifierPluginVersion,
            stableVersion: stableNotifierPluginVersion,
            followsMain: notifierPluginNoticeChannel.followsMain,
            asksToUpdate: notifierPluginNoticeChannel.asksToUpdate
        )
    }

    /// The dashboard|version update notices the user closed with Not now
    /// (AppState+NotifierPluginUpdate.swift).
    var dismissedPluginUpdates: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.dismissedPluginUpdateKey) ?? []) }
        set {
            defaults.set(newValue.sorted(), forKey: Self.dismissedPluginUpdateKey)
            objectWillChange.send()
        }
    }

    /// Dashboards added on this iPhone whose Finish setting up card hasn't
    /// been closed or finished yet (AppState+FinishSetup.swift).
    var dashboardsFinishingSetup: Set<UUID> {
        get { Set((defaults.stringArray(forKey: Self.finishSetupDashboardsKey) ?? []).compactMap(UUID.init(uuidString:))) }
        set {
            defaults.set(newValue.map(\.uuidString).sorted(), forKey: Self.finishSetupDashboardsKey)
            objectWillChange.send()
        }
    }

    /// Asks the plugin what it serves. Cheap, so it runs on every connect.
    func refreshNotifierPluginStatus() async {
        guard let bridge = dashboardTicketBridge else { return }
        // Connected, so the saved dashboards were read: sharing bound to one
        // removed earlier ends first, whatever the status read says.
        endSharingWithRemovedDashboards()
        notifierPluginStatusGeneration += 1
        let generation = notifierPluginStatusGeneration
        let state: NotifierPluginStatus.State
        var runtime: NotifierPluginStatus.Runtime?
        var managedBy: String?
        do {
            let response = try await bridge.requestJSON(path: NotifierPluginStatus.path)
            state = NotifierPluginStatus.state(from: response)
            runtime = NotifierPluginStatus.runtime(from: response)
            managedBy = NotifierPluginStatus.managedBy(from: response)
        } catch {
            state = NotifierPluginStatus.state(from: error)
        }
        // No capabilities route: a plugin older than 0.4, one the dashboard
        // doesn't serve, or none at all. Hermes' plugin list tells them apart.
        var hostCopy: NotifierPluginStatus.HostCopy?
        if state == .predatesCapabilities,
           let hub = try? await bridge.requestJSON(path: NotifierPluginStatus.pluginsHubPath, timeoutMilliseconds: 5_000) {
            hostCopy = NotifierPluginStatus.hostCopy(inPluginsHub: hub)
        }
        // A bridge swapped mid-request belongs to another host, and a failed
        // request says nothing new: keep the last real answer.
        guard bridge === dashboardTicketBridge, generation > notifierPluginStatusAcceptedGeneration,
              state != .unknown else { return }
        notifierPluginStatusAcceptedGeneration = generation
        let couldInviteLinkedPeople = canInviteLinkedPeople
        let couldAnswerRoomApprovals = canAnswerRoomApprovals
        // A failed list read keeps what this host's list said before.
        notifierPlugin.hostCopy = state == .predatesCapabilities
            ? hostCopy ?? (notifierPlugin.state == .predatesCapabilities ? notifierPlugin.hostCopy : nil)
            : nil
        notifierPlugin.state = state
        notifierPlugin.runtime = runtime
        notifierPlugin.managedBy = NotifierPluginStatus.managedBy(
            after: state, reported: managedBy,
            before: notifierPlugin.managedBy ?? NotifierPluginStatus.Remembered.managedBy(for: activeDashboardID, in: defaults)
        )
        NotifierPluginStatus.Remembered.remember(notifierPlugin.managedBy, for: activeDashboardID, in: defaults)
        linkedRoomInvitesReported(before: couldInviteLinkedPeople, approvals: couldAnswerRoomApprovals)
        Task { await refreshLatestNotifierPluginVersion() }
        clearSettledNotifierPluginUpdateOutcome()
        // Calls declined or missed while this host was out of reach.
        deliverHermesCallOutcomes()
        // Whether calls can ring the Watch, for this host and profile.
        Task { await refreshWatchCallVoices() }
        // Settings Hermes may change: share them, take its requests.
        Task { await syncAgentSettings() }
        // Preferences shared with this profile's other devices.
        Task { await syncPreferences() }
        // Confirmations Hermes is waiting on.
        Task { await syncPresentedScreens() }
        await provisionNotificationEncryption(bridge: bridge)
        // Notifications from this dashboard's profile, without a pairing
        // code, after the rest so connecting doesn't wait on it.
        Task { await pairActiveProfileAutomatically(bridge: bridge) }
        // Health data catches up once this host is known to serve it.
        Task { await runHealthSync(reason: .connected) }
        // Location waiting to go to this host, and its host pass.
        Task { await locationHostConnected() }
        // The Pulse widget reads Pulse with its own pass (issue 2190).
        Task { await savePulseWidgetAccess() }
        Task { await runPhoneSync(reason: .connected) }
        // Log to Hermes events that waited for this host.
        Task { await drainShortcutInbox() }
    }

    /// The plugin's capabilities answer read at the end of an update: it
    /// replaces the status right away, and any status read already on its
    /// way (asked of the old plugin) lands under it, so "Finish Update"
    /// doesn't linger until the next refresh (#299).
    func applyNotifierPluginReport(_ json: [String: Any]) {
        let state = NotifierPluginStatus.state(from: json)
        guard state != .unknown else { return }
        notifierPluginStatusGeneration += 1
        notifierPluginStatusAcceptedGeneration = notifierPluginStatusGeneration
        let couldInviteLinkedPeople = canInviteLinkedPeople
        let couldAnswerRoomApprovals = canAnswerRoomApprovals
        notifierPlugin.hostCopy = nil
        notifierPlugin.state = state
        notifierPlugin.runtime = NotifierPluginStatus.runtime(from: json)
        notifierPlugin.managedBy = NotifierPluginStatus.managedBy(from: json)
        NotifierPluginStatus.Remembered.remember(notifierPlugin.managedBy, for: activeDashboardID, in: defaults)
        linkedRoomInvitesReported(before: couldInviteLinkedPeople, approvals: couldAnswerRoomApprovals)
        clearSettledNotifierPluginUpdateOutcome()
    }

    /// Reads the latest and stable plugin versions (saved, then from GitHub
    /// at most hourly), so a plugin release is offered without a new
    /// Conduit build.
    private func refreshLatestNotifierPluginVersion() async {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        if latestNotifierPluginVersion == nil, let saved = NotifierPluginLatestVersion.cached(in: defaults) {
            applyLatestNotifierPluginVersion(saved)
        }
        if stableNotifierPluginVersion == nil, let saved = NotifierPluginLatestVersion.cachedStable(in: defaults) {
            applyStableNotifierPluginVersion(saved)
        }
        if notifierPluginChangelog == nil, let saved = NotifierPluginChangelog.cached(in: defaults) {
            notifierPluginChangelog = saved
        }
        guard let fetched = await NotifierPluginLatestVersion.refresh(defaults: defaults) else { return }
        if let latest = fetched.latest { applyLatestNotifierPluginVersion(latest) }
        if let stable = fetched.stable { applyStableNotifierPluginVersion(stable) }
        if let changelog = fetched.changelog, changelog != notifierPluginChangelog { notifierPluginChangelog = changelog }
    }

    private func applyLatestNotifierPluginVersion(_ version: String) {
        latestNotifierPluginVersion = version
        guard notifierPlugin.latestVersion != version else { return }
        notifierPlugin.latestVersion = version
        clearSettledNotifierPluginUpdateOutcome()
    }

    private func applyStableNotifierPluginVersion(_ version: String) {
        stableNotifierPluginVersion = version
        guard notifierPlugin.stableVersion != version else { return }
        notifierPlugin.stableVersion = version
    }

    /// Settings > Conduit plugin > Update notices.
    func setNotifierPluginNoticeChannel(_ channel: NotifierPluginNoticeChannel) {
        notifierPluginNoticeChannel = channel
        defaults.set(channel.rawValue, forKey: NotifierPluginNoticeChannel.key)
        applyNotifierPluginNoticeChannel()
    }

    private func applyNotifierPluginNoticeChannel() {
        let followsMain = notifierPluginNoticeChannel.followsMain
        let asksToUpdate = notifierPluginNoticeChannel.asksToUpdate
        guard notifierPlugin.followsMain != followsMain
                || notifierPlugin.asksToUpdate != asksToUpdate else { return }
        notifierPlugin.followsMain = followsMain
        notifierPlugin.asksToUpdate = asksToUpdate
    }

    /// Hands each of this dashboard's paired profiles an end-to-end
    /// encryption key for its notifications (#431), over this dashboard
    /// connection so the key never passes through the push relay. Runs on
    /// every connect and Settings > Notifications visit; pairings that
    /// already have a key are left alone.
    func provisionNotificationEncryption(bridge: DashboardTicketBridge) async {
        let notifications = PushNotificationService.shared
        guard case .reported(_, let capabilities) = notifierPlugin.state,
              capabilities.contains("e2e-notifications"),
              notifications.isEnabled,
              let dashboardID = activeDashboardID else { return }
        let names = Array(Set(profiles + [activeProfile])).sorted()
        await notifications.provisionEncryption(dashboardID: dashboardID, profiles: names) { [weak self] path, method, body in
            // A dashboard switch mid-run stops it: the key would belong to
            // the old dashboard's pairing.
            guard let self, bridge === self.dashboardTicketBridge, self.activeDashboardID == dashboardID else {
                throw DashboardTicketBridgeError.notReady
            }
            return try await bridge.requestJSON(path: path, method: method, body: body)
        }
    }

    /// Settings > Notifications > Rotate: runs provisioning now on this
    /// dashboard's connection (a rotation waits for the next connect when
    /// there is none).
    func provisionNotificationEncryptionNow() async {
        guard let bridge = dashboardTicketBridge else { return }
        await provisionNotificationEncryption(bridge: bridge)
    }
}
