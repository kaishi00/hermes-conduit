//
//  AppState+HermesUpdate.swift
//  Conduit
//
//  Update Hermes, from Settings > Connection: checks whether the host is
//  behind, runs `hermes update` there and follows it through the restart
//  (HermesUpdate.swift). Like Restart Gateway, it belongs to the dashboard
//  it started on.
//

import Foundation

extension AppState {
    /// Update Hermes' state for the dashboard in use.
    var activeHermesUpdate: HermesUpdateState {
        hermesUpdateDashboardID == activeDashboardID ? hermesUpdate : .idle
    }

    /// Whether Check for Updates and Update Hermes can be offered: signed in
    /// to a dashboard, with no update or gateway restart running.
    var canUpdateHermes: Bool {
        dashboardTicketBridge != nil && !activeHermesUpdate.isInProgress && !activeGatewayRestart.isInProgress
    }

    private func hermesUpdater(for dashboardID: UUID?) -> HermesUpdater {
        HermesUpdater(request: { [weak self] path, method in
            guard let self, self.activeDashboardID == dashboardID, let bridge = self.dashboardTicketBridge else {
                throw DashboardTicketBridgeError.notReady
            }
            if let request = self.hermesUpdateRequest { return try await request(path, method) }
            // An update's own answer comes at once; the check may fetch from
            // the update source first.
            do {
                return try await bridge.requestJSON(path: path, method: method, timeoutMilliseconds: 30_000)
            } catch DashboardTicketBridgeError.signInRequired {
                // The dashboard that came back on the new version started a
                // new sign-in session: sign in again, as the plugin update does.
                guard let dashboardID, await self.renewDashboardSignIn(dashboardID: dashboardID),
                      self.activeDashboardID == dashboardID, let renewed = self.dashboardTicketBridge else {
                    throw DashboardTicketBridgeError.signInRequired
                }
                return try await renewed.requestJSON(path: path, method: method, timeoutMilliseconds: 30_000)
            }
        })
    }

    /// Asks the dashboard whether its host is behind. `force` makes Hermes
    /// look again rather than answer from its cache.
    func checkHermesUpdate(force: Bool) {
        guard canUpdateHermes else { return }
        hermesUpdateTask?.cancel()
        let dashboardID = activeDashboardID
        hermesUpdateDashboardID = dashboardID
        hermesUpdate = .checking
        let updater = hermesUpdater(for: dashboardID)
        hermesUpdateTask = Task { [weak self] in
            let outcome = await updater.check(force: force)
            guard let self, !Task.isCancelled else { return }
            self.hermesUpdateTask = nil
            guard self.activeDashboardID == dashboardID else {
                self.clearHermesUpdate()
                return
            }
            self.hermesUpdate = outcome
        }
    }

    /// Runs `hermes update` on the host and follows it until Hermes is back.
    func updateHermes() {
        guard canUpdateHermes else { return }
        hermesUpdateTask?.cancel()
        let dashboardID = activeDashboardID
        hermesUpdateDashboardID = dashboardID
        let updater = hermesUpdater(for: dashboardID)
        hermesUpdateTask = Task { [weak self] in
            let outcome = await updater.run { state in
                guard let self, !Task.isCancelled else { return }
                guard self.activeDashboardID == dashboardID else {
                    // Another dashboard is in use now: stop following this one.
                    self.hermesUpdateTask?.cancel()
                    self.hermesUpdateTask = nil
                    self.clearHermesUpdate()
                    return
                }
                self.hermesUpdate = state
            }
            guard let self, !Task.isCancelled else { return }
            self.hermesUpdateTask = nil
            guard self.activeDashboardID == dashboardID else {
                self.clearHermesUpdate()
                return
            }
            self.hermesUpdate = outcome
            // The chat connection goes through the dashboard, which the
            // update restarts: reconnect if it dropped.
            if case .updated = outcome, !self.isConnected { await self.reconnect() }
        }
    }

    /// Stops following an update and forgets it, for sign-out.
    func stopFollowingHermesUpdate() {
        hermesUpdateTask?.cancel()
        hermesUpdateTask = nil
        clearHermesUpdate()
    }

    private func clearHermesUpdate() {
        hermesUpdate = .idle
        hermesUpdateDashboardID = nil
    }
}
