//
//  AppState+GatewayRestart.swift
//  Conduit
//
//  Restart Gateway, from the chat's Gateway sheet and Settings > Gateway:
//  runs the dashboard's own restart action and follows the gateway until
//  it is back (GatewayRestart.swift).
//

import Foundation

extension AppState {
    /// Restart Gateway's state for the dashboard in use. A restart started
    /// on another dashboard shows nothing here.
    var activeGatewayRestart: GatewayRestartState {
        gatewayRestart.state(on: activeDashboardID)
    }

    /// Whether Restart Gateway can be offered: signed in to a dashboard and
    /// no restart already running.
    var canRestartGateway: Bool {
        dashboardTicketBridge != nil && !activeGatewayRestart.isInProgress
    }

    func restartGateway() {
        guard canRestartGateway else { return }
        gatewayRestartTask?.cancel()
        let dashboardID = activeDashboardID
        let restartID = gatewayRestart.start(on: dashboardID)
        let restarter = GatewayRestarter(request: { [weak self] path, method in
            guard let self, self.activeDashboardID == dashboardID, let bridge = self.dashboardTicketBridge else {
                throw DashboardTicketBridgeError.notReady
            }
            return try await bridge.requestJSON(path: path, method: method)
        })
        gatewayRestartTask = Task { [weak self] in
            let outcome = await restarter.run { state in
                guard let self, !Task.isCancelled else { return }
                guard self.activeDashboardID == dashboardID else {
                    // Another dashboard is in use now: stop following this one.
                    self.gatewayRestartTask?.cancel()
                    self.gatewayRestartTask = nil
                    self.gatewayRestart.finish(.idle, restart: restartID, activeDashboardID: self.activeDashboardID)
                    return
                }
                self.gatewayRestart.update(state, restart: restartID)
            }
            // A cancelled restart was replaced or dropped by whoever cancelled it.
            guard let self, !Task.isCancelled else { return }
            self.gatewayRestartTask = nil
            // Off its dashboard by now, this clears rather than keeping the
            // outcome (or a step) for a dashboard no longer shown.
            self.gatewayRestart.finish(outcome, restart: restartID, activeDashboardID: self.activeDashboardID)
            guard self.activeDashboardID == dashboardID else { return }
            // The sheet's state and logs show what the gateway did.
            if self.showGatewaySheet { await self.refreshGatewayDiagnostics() }
            // The chat connection goes through the dashboard, not the
            // gateway, so it normally stays up; reconnect only if it dropped.
            if case .restarted = outcome, !self.isConnected { await self.reconnect() }
        }
    }

    /// Clears a finished restart's outcome. A restart in progress stays.
    func dismissGatewayRestartOutcome() {
        gatewayRestart.dismiss()
    }

    /// Stops following a restart and forgets it, for sign-out.
    func stopFollowingGatewayRestart() {
        gatewayRestartTask?.cancel()
        gatewayRestartTask = nil
        gatewayRestart = GatewayRestartSlot()
    }
}
