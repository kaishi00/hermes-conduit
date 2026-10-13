//
//  AppState+NotifierPluginUpdate.swift
//  Conduit
//
//  The Conduit plugin from inside Conduit: the one-tap update (or install)
//  that Settings > Conduit plugin and the update notice run
//  (NotifierPluginUpdate.swift), the notice's "not now" per version, and
//  pairing this dashboard's profile for notifications without a code to
//  type (plugin 0.24+).
//

import Foundation

extension AppState {
    /// The plugin update's state for the dashboard in use.
    var activeNotifierPluginUpdate: NotifierPluginUpdateState {
        notifierPluginUpdate.state(on: activeDashboardID)
    }

    /// Why the update can't run right now, or nil when it can. A call
    /// would lose its connection while Hermes restarts.
    var notifierPluginUpdateBlocker: String? {
        if dashboardTicketBridge == nil { return AppLocalization.string("Connect to this dashboard first.") }
        if isVoiceCallInProgress { return AppLocalization.string("End the call first: Hermes restarts during the update.") }
        if activeGatewayRestart.isInProgress { return AppLocalization.string("Wait for the gateway restart to finish.") }
        return nil
    }

    var canUpdateNotifierPlugin: Bool {
        notifierPluginUpdateBlocker == nil && !activeNotifierPluginUpdate.isInProgress
    }

    /// Updates the plugin on this dashboard's host, or installs it when
    /// `install` is set, then restarts the gateway and the dashboard.
    func updateNotifierPlugin(install: Bool = false) {
        guard canUpdateNotifierPlugin else { return }
        notifierPluginUpdateTask?.cancel()
        let dashboardID = activeDashboardID
        let runID = notifierPluginUpdate.start(on: dashboardID)
        let updater = NotifierPluginUpdater(request: { [weak self] path, method, body in
            guard let self, self.activeDashboardID == dashboardID, let bridge = self.dashboardTicketBridge else {
                throw DashboardTicketBridgeError.notReady
            }
            // Hermes pulls or clones the plugin before it answers.
            let timeout = path.hasPrefix("/api/dashboard/agent-plugins") ? 180_000 : 12_000
            return try await bridge.requestJSON(path: path, method: method, body: body, timeoutMilliseconds: timeout)
        }, install: install)
        notifierPluginUpdateTask = Task { [weak self] in
            let outcome = await updater.run { state in
                guard let self, !Task.isCancelled else { return }
                guard self.activeDashboardID == dashboardID else {
                    // Another dashboard is in use now: stop following this one.
                    self.notifierPluginUpdateTask?.cancel()
                    self.notifierPluginUpdateTask = nil
                    self.notifierPluginUpdate.finish(.idle, run: runID, activeDashboardID: self.activeDashboardID)
                    return
                }
                self.notifierPluginUpdate.update(state, run: runID)
            }
            guard let self, !Task.isCancelled else { return }
            self.notifierPluginUpdateTask = nil
            self.notifierPluginUpdate.finish(outcome, run: runID, activeDashboardID: self.activeDashboardID)
            guard self.activeDashboardID == dashboardID else { return }
            // The dashboard restart drops the chat connection.
            if !self.isConnected { await self.reconnect() }
            await self.refreshNotifierPluginStatus()
        }
    }

    func dismissNotifierPluginUpdateOutcome() {
        notifierPluginUpdate.dismiss()
    }

    /// Stops following an update and forgets it, for sign-out. Hermes
    /// finishes whatever step it already took.
    func stopFollowingNotifierPluginUpdate() {
        notifierPluginUpdateTask?.cancel()
        notifierPluginUpdateTask = nil
        notifierPluginUpdate = NotifierPluginUpdateSlot()
    }

    // MARK: - Update notice

    static let dismissedPluginUpdateKey = "conduit.notifierPlugin.dismissedUpdateVersion"

    /// The notice over the main screen: an update is offered, or one is
    /// running or just ended. "Not now" hides it until a newer Conduit
    /// offers a newer plugin.
    var showsNotifierPluginUpdateNotice: Bool {
        if activeNotifierPluginUpdate != .idle { return true }
        guard notifierPlugin.updateAvailable else { return false }
        return dismissedPluginUpdateVersion != notifierPlugin.offeredVersion
    }

    func dismissNotifierPluginUpdateNotice() {
        if activeNotifierPluginUpdate.isInProgress { return }
        if activeNotifierPluginUpdate != .idle {
            dismissNotifierPluginUpdateOutcome()
        } else {
            dismissedPluginUpdateVersion = notifierPlugin.offeredVersion
        }
    }

    // MARK: - Pairing

    /// Pairs the active profile with this iPhone when notifications are on
    /// and nothing receives them yet. It never replaces another iPhone's
    /// pairing (Settings > Notifications offers that), and tries once per
    /// dashboard and profile each launch.
    func pairActiveProfileAutomatically(bridge: DashboardTicketBridge) async {
        let notifications = PushNotificationService.shared
        guard notifierPlugin.reports("pairing"),
              notifications.isEnabled,
              let installationID = notifications.installationID,
              let dashboardID = activeDashboardID else { return }
        let profile = activeProfile
        let attempt = "\(dashboardID.uuidString)|\(profile)"
        guard !automaticPairingAttempts.contains(attempt) else { return }
        let statusPath = DashboardPath.withProfile(PushNotificationService.e2ePath, profile: profile)
        guard let status = try? await bridge.requestJSON(path: statusPath),
              bridge === dashboardTicketBridge,
              PushNotificationService.profilePairing(status: status, installationID: installationID) == .unpaired else { return }
        automaticPairingAttempts.insert(attempt)
        try? await pairProfile(profile, bridge: bridge, dashboardID: dashboardID)
    }

    /// Pairs `profile` on the active dashboard with this iPhone (Settings >
    /// Notifications' button, and the automatic pairing above), then hands
    /// it its encryption key.
    func pairProfileWithThisDevice(_ profile: String) async throws {
        guard let bridge = dashboardTicketBridge, let dashboardID = activeDashboardID else {
            throw DashboardTicketBridgeError.notReady
        }
        try await pairProfile(profile, bridge: bridge, dashboardID: dashboardID)
    }

    private func pairProfile(_ profile: String, bridge: DashboardTicketBridge, dashboardID: UUID) async throws {
        try await PushNotificationService.shared.pairProfile(profile, dashboardID: dashboardID) { [weak self] path, method, body in
            // A dashboard switch mid-run stops it: the pairing would belong
            // to the old dashboard's host.
            guard let self, bridge === self.dashboardTicketBridge, self.activeDashboardID == dashboardID else {
                throw DashboardTicketBridgeError.notReady
            }
            return try await bridge.requestJSON(path: path, method: method, body: body)
        }
        // The new pairing gets its key right away, before its first push.
        await refreshNotifierPluginStatus()
    }
}
