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

    /// The update here ended with the gateway restarted and only the
    /// dashboard left running the old plugin (a Desktop or plugin host
    /// that can't restart it): the restart texts name the dashboard, not
    /// Hermes (notifier issue 778).
    var notifierPluginOnlyDashboardLeft: Bool {
        guard notifierPlugin.restartPending else { return false }
        if case .needsDashboardRestart = activeNotifierPluginUpdate { return true }
        return false
    }

    /// Why the update can't run right now, or nil when it can. A call
    /// would lose its connection while Hermes restarts.
    var notifierPluginUpdateBlocker: String? {
        if dashboardTicketBridge == nil { return AppLocalization.string("Connect to this dashboard first.") }
        if isVoiceCallInProgress { return AppLocalization.string("End the call first: Hermes restarts during the update.", table: .notifications) }
        if activeGatewayRestart.isInProgress { return AppLocalization.string("Wait for the gateway restart to finish.", table: .notifications) }
        if hermesUpdateIsRunning { return AppLocalization.string("Wait for the Hermes update to finish.") }
        // Restart now's own steps can outlast the restart they ended.
        if gatewayRestartingNow { return AppLocalization.string("Wait for the gateway restart to finish.", table: .notifications) }
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
        let restartOnly = notifierPlugin.updateRunsOnlyRestarts(install: install)
        let runID = notifierPluginUpdate.start(on: dashboardID, first: restartOnly ? .restartingGateway(nil) : .downloading)
        let updater = NotifierPluginUpdater(request: { [weak self] path, method, body in
            guard let self, self.activeDashboardID == dashboardID, let bridge = self.dashboardTicketBridge else {
                throw DashboardTicketBridgeError.notReady
            }
            // Hermes pulls or clones the plugin before it answers.
            let timeout = path.hasPrefix("/api/dashboard/agent-plugins") ? 180_000 : 12_000
            return try await bridge.requestJSON(path: path, method: method, body: body, timeoutMilliseconds: timeout)
        }, install: install, renewSignIn: { [weak self] in
            guard let self, let dashboardID, self.activeDashboardID == dashboardID else { return false }
            return await self.renewDashboardSignIn(dashboardID: dashboardID)
        }, onHost: notifierPlugin.reports(NotifierPluginUpdater.selfUpdateCapability),
           restartOnly: restartOnly,
           profile: activeProfile, report: { [weak self] json in
            guard let self, self.activeDashboardID == dashboardID else { return }
            self.applyNotifierPluginReport(json)
        })
        notifierPluginUpdateTask = Task { [weak self] in
            let outcome = await updater.run { state in
                guard let self, !Task.isCancelled else { return }
                guard self.activeDashboardID == dashboardID else {
                    // Another dashboard is in use now: stop following this one.
                    // Only this run's own task: the shared one may already
                    // be the new dashboard's update.
                    withUnsafeCurrentTask { $0?.cancel() }
                    self.notifierPluginUpdate.finish(.idle, run: runID, activeDashboardID: self.activeDashboardID)
                    return
                }
                self.notifierPluginUpdate.update(state, run: runID)
            }
            guard let self, !Task.isCancelled else { return }
            switch outcome {
            case .updated, .failed, .runningOnHost:
                break
            default:
                // Nothing restarted, or the dashboard waits on a restart:
                // how it ended shows right away.
                self.notifierPluginUpdateTask = nil
                self.notifierPluginUpdate.finish(outcome, run: runID, activeDashboardID: self.activeDashboardID)
                guard self.activeDashboardID == dashboardID else { return }
                await self.refreshNotifierPluginStatus()
                return
            }
            guard self.activeDashboardID == dashboardID else {
                self.notifierPluginUpdateTask = nil
                self.notifierPluginUpdate.finish(outcome, run: runID, activeDashboardID: self.activeDashboardID)
                return
            }
            // The dashboard restart dropped the chat connection: the notice
            // keeps its progress until Conduit is back and has read the new
            // plugin, so "ready" means ready.
            self.notifierPluginUpdate.update(.updating(.reconnecting), run: runID)
            let ended = await self.reconnectAfterNotifierPluginUpdate(outcome, dashboardID: dashboardID)
            guard !Task.isCancelled else { return }
            self.notifierPluginUpdateTask = nil
            self.notifierPluginUpdate.finish(ended, run: runID, activeDashboardID: self.activeDashboardID)
        }
    }

    /// How long Conduit waits for the gateway after an update before it
    /// says the gateway didn't come back.
    static let notifierPluginGatewayWaitLimit: TimeInterval = 180

    /// Reconnects after an update and reads the new plugin's report, then
    /// says how the update ended. A failure the report contradicts (the new
    /// plugin runs) is an update: Hermes' gateway restart can take the
    /// dashboard down with it, and the job that dashboard ran with it. An
    /// update is ready once the gateway serves again too.
    private func reconnectAfterNotifierPluginUpdate(_ outcome: NotifierPluginUpdateState,
                                                    dashboardID: UUID?) async -> NotifierPluginUpdateState {
        if !isConnected { await reconnect() }
        guard !Task.isCancelled, activeDashboardID == dashboardID else { return outcome }
        await refreshNotifierPluginStatus()
        let updated: Bool
        switch outcome {
        case .updated:
            // A read that failed right after the restart keeps the old
            // plugin's "restart to finish": ask once more (#299).
            if notifierPlugin.restartPending {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, activeDashboardID == dashboardID else { return outcome }
                await refreshNotifierPluginStatus()
            }
            if notifierPlugin.restartPending { return .needsDashboardRestart(detail: nil) }
            updated = true
        case .failed, .runningOnHost:
            // The new version runs and nothing is left to update (a plugin
            // missing capabilities still needs one).
            updated = notifierPlugin.settles(outcome) && !notifierPlugin.updateAvailable
        default:
            updated = false
        }
        guard updated else { return outcome }
        guard await waitForGatewayAfterNotifierPluginUpdate(dashboardID: dashboardID) else {
            if Task.isCancelled || activeDashboardID != dashboardID { return outcome }
            return .failed(detail: AppLocalization.string("The plugin is updated, but the gateway didn't come back. Run hermes gateway status on the host.", table: .notifications))
        }
        if case .updated(let version?) = outcome { return .updated(version: version) }
        return .updated(version: notifierPlugin.runningVersion)
    }

    /// Whether the gateway serves again (Hermes' `/api/status`), polling
    /// until `notifierPluginGatewayWaitLimit`. A Hermes that doesn't report
    /// its gateway there counts as serving.
    private func waitForGatewayAfterNotifierPluginUpdate(dashboardID: UUID?) async -> Bool {
        let started = Date()
        while Date().timeIntervalSince(started) < Self.notifierPluginGatewayWaitLimit {
            if await gatewayServesNow(dashboardID: dashboardID) { return true }
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled || activeDashboardID != dashboardID { return false }
        }
        return false
    }

    /// One `/api/status` read: whether the gateway serves. A Hermes that
    /// doesn't report its gateway there counts as serving; a failed read
    /// doesn't.
    private func gatewayServesNow(dashboardID: UUID?) async -> Bool {
        guard activeDashboardID == dashboardID, let bridge = dashboardTicketBridge,
              let json = try? await bridge.requestJSON(path: GatewayRestarter.statusPath),
              activeDashboardID == dashboardID else { return false }
        if json["gateway_running"] == nil { return true }
        return GatewayRestartGatewayStatus(json: json)?.isServing == true
    }

    /// Signs in to the dashboard in use again with its saved password, the
    /// way a chat reconnect does, and hands the new session to the
    /// dashboard page. False when there is no saved password for this
    /// address or Hermes refused it.
    func renewDashboardSignIn(dashboardID: UUID) async -> Bool {
        guard let bridge = dashboardTicketBridge,
              let credentials = KeychainHelper.loadCredentials(dashboardID: dashboardID),
              Self.sameDashboardAddress(credentials.baseURL, bridge.baseURL) else { return false }
        let access = KeychainHelper.loadCloudflareAccess(dashboardID: dashboardID, for: credentials.baseURL)
        guard let authenticated = try? await NativeAuthClient(baseURL: credentials.baseURL, cloudflareAccess: access)
            .connect(username: credentials.username, password: credentials.password) else { return false }
        // Another dashboard may be in use by now.
        guard activeDashboardID == dashboardID, dashboardTicketBridge === bridge else { return false }
        authenticated.commitCookies(dashboardID: dashboardID)
        // URLSession and WebKit keep separate cookies: reload the page so it
        // picks up the new session.
        bridge.reload()
        return true
    }

    private static func sameDashboardAddress(_ a: String, _ b: String) -> Bool {
        let slash = CharacterSet(charactersIn: "/")
        return a.trimmingCharacters(in: slash) == b.trimmingCharacters(in: slash)
    }

    func dismissNotifierPluginUpdateOutcome() {
        notifierPluginUpdate.dismiss()
    }

    /// "Restart the dashboard to finish" is stale once the plugin reports
    /// nothing left to do: the user restarted Hermes. So is "still updating
    /// on the host" once the offered version is running: the host finished
    /// after Conduit stopped following it. Either way the update is done, and
    /// the notice says so. So is a failure the report contradicts, once the
    /// gateway serves too: a report or gateway that came back after the run
    /// stopped waiting.
    func clearSettledNotifierPluginUpdateOutcome() {
        let outcome = activeNotifierPluginUpdate
        guard notifierPlugin.settles(outcome) else { return }
        if case .failed = outcome {
            guard !notifierPlugin.updateAvailable else { return }
            let dashboardID = activeDashboardID
            Task { [weak self] in
                guard let self, await self.gatewayServesNow(dashboardID: dashboardID),
                      self.activeNotifierPluginUpdate == outcome, self.notifierPlugin.settles(outcome),
                      !self.notifierPlugin.updateAvailable else { return }
                self.notifierPluginUpdate.settle(as: .updated(version: self.notifierPlugin.runningVersion))
            }
            return
        }
        if notifierPlugin.updateAvailable {
            dismissNotifierPluginUpdateOutcome()
        } else {
            notifierPluginUpdate.settle(as: .updated(version: notifierPlugin.runningVersion))
        }
    }

    /// Stops following a running update (Cancel). Hermes finishes whatever
    /// step it already took; the status refresh shows where that left it.
    func cancelNotifierPluginUpdate() {
        guard activeNotifierPluginUpdate.isInProgress else { return }
        stopFollowingNotifierPluginUpdate()
        Task { await refreshNotifierPluginStatus() }
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

    /// The notice over the main screen: an update (or the install) is
    /// offered, or one is running or just ended. "Not now" hides it on this
    /// dashboard until a newer plugin is offered.
    var showsNotifierPluginUpdateNotice: Bool {
        if activeNotifierPluginUpdate != .idle { return true }
        // A plugin already on the host that waits for a restart is offered
        // too: Update finishes it.
        guard notifierPluginNoticeOffer != .none else { return false }
        return !dismissedPluginUpdates.contains(pluginUpdateDismissalToken)
    }

    /// What the notice offers. While Finish setting up is pending for this
    /// dashboard, its plugin row is the one place that offers the install,
    /// update or restart.
    var notifierPluginNoticeOffer: NotifierPluginNoticeOffer {
        let finishingSetup = activeDashboardID.map(dashboardsFinishingSetup.contains) ?? false
        return notifierPlugin.noticeOffer(finishSetupOffersPlugin: finishingSetup && V2ShellPreference.isOn)
    }

    /// "Not now" belongs to one dashboard and one asked-for version.
    private var pluginUpdateDismissalToken: String {
        "\(activeDashboardID?.uuidString ?? "")|\(notifierPlugin.noticeDismissalVersion)"
    }

    func dismissNotifierPluginUpdateNotice() {
        if activeNotifierPluginUpdate.isInProgress { return }
        // Closing an outcome closes the offer behind it too, or a failed or
        // half-finished update would reappear as the offer right away.
        if activeNotifierPluginUpdate != .idle {
            dismissNotifierPluginUpdateOutcome()
        }
        // This dashboard's older dismissals no longer matter. Others keep
        // theirs: under Never a restart's version differs per dashboard.
        let dashboard = "\(activeDashboardID?.uuidString ?? "")|"
        dismissedPluginUpdates = dismissedPluginUpdates.filter { !$0.hasPrefix(dashboard) }
            .union([pluginUpdateDismissalToken])
    }

    // MARK: - Pairing

    /// Pairs this dashboard's profiles with this device when notifications
    /// are on, and tries once per dashboard, profile and installation each
    /// launch. With a plugin that keeps a pairing per device (0.178+, issue
    /// 2758) that's every profile on the dashboard, newly added ones too,
    /// besides the devices each notifies already; the plugin leaves out a
    /// device someone removed from a profile until it's paired by hand. With
    /// an older one, only the active profile, and only when nothing receives
    /// its notifications yet: pairing there would move them off another
    /// iPhone (Settings > Notifications offers that).
    func pairProfilesAutomatically(bridge: DashboardTicketBridge) async {
        let notifications = PushNotificationService.shared
        guard notifierPlugin.reports("pairing"),
              notifications.isEnabled,
              notifications.installationID != nil,
              let dashboardID = activeDashboardID else { return }
        let everyDevice = notifierPlugin.reports("pairing-devices")
        let names = everyDevice ? Array(Set(profiles + [activeProfile])).sorted() : [activeProfile]
        for profile in names {
            guard bridge === dashboardTicketBridge, activeDashboardID == dashboardID else { return }
            await pairAutomatically(profile, besideOthers: everyDevice, bridge: bridge, dashboardID: dashboardID)
        }
    }

    private func pairAutomatically(_ profile: String, besideOthers: Bool, bridge: DashboardTicketBridge, dashboardID: UUID) async {
        guard let installationID = PushNotificationService.shared.installationID else { return }
        // Per installation too: notifications turned off and on again are a
        // new installation that hasn't paired.
        let attempt = "\(dashboardID.uuidString)|\(profile)|\(installationID)"
        // Taken before the first await, so refreshes running side by side
        // check (and pair) once.
        guard automaticPairingAttempts.insert(attempt).inserted else { return }
        let statusPath = PushNotificationService.e2eStatusPath(profile: profile, installationID: installationID)
        guard let status = try? await bridge.requestJSON(path: statusPath) else {
            // Nothing learned: the next refresh asks again.
            automaticPairingAttempts.remove(attempt)
            return
        }
        // Reconnected or switched meanwhile: the next refresh checks again.
        // Only the active profile's switch matters with an older plugin.
        guard bridge === dashboardTicketBridge, activeDashboardID == dashboardID, besideOthers || activeProfile == profile else {
            automaticPairingAttempts.remove(attempt)
            return
        }
        let pairing = PushNotificationService.profilePairing(status: status, installationID: installationID)
        if pairing == .thisDevice, let gatewayID = status["gateway_id"] as? String {
            // Pushes through this pairing come from the host on screen, even
            // when it was paired from another saved entry for it.
            recordRelayGatewayID(gatewayID, for: dashboardID, profile: profile)
        } else if pairing != .thisDevice {
            // This host no longer pairs the profile with this iPhone: the id
            // recorded for it no longer counts. A status without the id says
            // nothing either way.
            forgetRelayGatewayID(for: dashboardID, profile: profile)
        }
        guard pairing == .unpaired || (besideOthers && pairing == .otherDevice) else { return }
        do {
            try await pairProfile(profile, bridge: bridge, dashboardID: dashboardID, automatically: true)
        } catch DashboardTicketBridgeError.notReady {
            // Another notification change was running: a later refresh tries
            // again. Other failures (a removed device's refusal among them)
            // wait for the next launch (or the button).
            automaticPairingAttempts.remove(attempt)
        } catch {}
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

    /// The devices `profile` on the active dashboard notifies, the main one
    /// (calls ring it) first; empty with an older plugin or no pairing.
    func pairedDevices(_ profile: String) async throws -> [PushNotificationService.PairedDevice] {
        guard let bridge = dashboardTicketBridge, notifierPlugin.reports("pairing-devices") else { return [] }
        let installationID = PushNotificationService.shared.installationID
        let status = try await bridge.requestJSON(
            path: PushNotificationService.e2eStatusPath(profile: profile, installationID: installationID)
        )
        return PushNotificationService.pairedDevices(status: status)
    }

    /// Settings > Notifications: unpairs one device from `profile`; the
    /// others keep theirs (issue 2758). Returns the devices left.
    func removePairedDevice(_ installationID: String, profile: String) async throws -> [PushNotificationService.PairedDevice] {
        try await pairedDeviceChange(PushNotificationService.pairRemovePath, installationID: installationID, profile: profile)
    }

    /// Settings > Notifications: calls from `profile` ring this device (and
    /// the phone's tools reach it) instead of the main one.
    func makeMainDevice(_ installationID: String, profile: String) async throws -> [PushNotificationService.PairedDevice] {
        try await pairedDeviceChange(PushNotificationService.pairMainPath, installationID: installationID, profile: profile)
    }

    private func pairedDeviceChange(_ path: String, installationID: String, profile: String) async throws
        -> [PushNotificationService.PairedDevice] {
        guard let bridge = dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        let response = try await bridge.requestJSON(path: DashboardPath.withProfile(path, profile: profile), method: "POST",
                                                    body: ["installation_id": installationID])
        // Only a success body says what's left: anything else is a refusal,
        // never an empty list.
        guard response["ok"] as? Bool == true, let devices = response["devices"] as? [[String: Any]] else {
            throw DashboardTicketBridgeError.requestFailed(AppLocalization.string("The plugin didn't confirm the change.", table: .notifications))
        }
        return PushNotificationService.pairedDevices(status: ["paired": true, "devices": devices])
    }

    private func pairProfile(_ profile: String, bridge: DashboardTicketBridge, dashboardID: UUID,
                             automatically: Bool = false) async throws {
        let gatewayID = try await PushNotificationService.shared.pairProfile(
            profile, dashboardID: dashboardID, automatically: automatically
        ) { [weak self] path, method, body in
            // A dashboard switch mid-run stops it: the pairing would belong
            // to the old dashboard's host.
            guard let self, bridge === self.dashboardTicketBridge, self.activeDashboardID == dashboardID else {
                throw DashboardTicketBridgeError.notReady
            }
            return try await bridge.requestJSON(path: path, method: method, body: body,
                                                timeoutMilliseconds: PushNotificationService.pairTimeoutMilliseconds)
        }
        // Still the host it was paired on: a switch or move meanwhile isn't.
        if let gatewayID, bridge === dashboardTicketBridge, activeDashboardID == dashboardID {
            recordRelayGatewayID(gatewayID, for: dashboardID, profile: profile)
        }
        // The new pairing gets its key right away, before its first push.
        await provisionNotificationEncryption(bridge: bridge)
    }
}

extension NotifierPluginStatus {
    /// Whether this report makes `outcome` stale
    /// (AppState.clearSettledNotifierPluginUpdateOutcome).
    func settles(_ outcome: NotifierPluginUpdateState) -> Bool {
        switch outcome {
        case .needsDashboardRestart:
            // Routes that still don't answer are still waiting on that
            // restart, whatever an update would offer.
            guard case .reported = state else { return false }
            return !updateAvailable && !restartPending
        case .failed, .runningOnHost:
            guard !restartPending, let running = runtime?.loadedVersion else { return false }
            return !Self.isOlder(running, than: offeredVersion)
        default:
            return false
        }
    }
}
