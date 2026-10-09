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
        gatewayRestartDashboardID == activeDashboardID ? gatewayRestart : .idle
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
        gatewayRestartDashboardID = dashboardID
        gatewayRestart = .requesting
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
                    // Another dashboard is in use now: stop following this
                    // one, so coming back to it doesn't show a stale restart.
                    self.gatewayRestartTask?.cancel()
                    self.gatewayRestartTask = nil
                    self.gatewayRestart = .idle
                    self.gatewayRestartDashboardID = nil
                    return
                }
                self.gatewayRestart = state
            }
            guard let self, !Task.isCancelled, self.activeDashboardID == dashboardID else { return }
            self.gatewayRestart = outcome
            self.gatewayRestartTask = nil
            // The sheet's state and logs show what the gateway did.
            if self.showGatewaySheet { await self.refreshGatewayDiagnostics() }
            // The chat connection goes through the dashboard, not the
            // gateway, so it normally stays up; reconnect only if it dropped.
            if case .restarted = outcome, !self.isConnected { await self.reconnect() }
        }
    }

    /// Clears a finished restart's outcome. A restart in progress stays.
    func dismissGatewayRestartOutcome() {
        guard !gatewayRestart.isInProgress else { return }
        gatewayRestart = .idle
    }
}
