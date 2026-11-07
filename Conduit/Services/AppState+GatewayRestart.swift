//
//  AppState+GatewayRestart.swift
//  Conduit
//
//  Restart Gateway, from the chat's Gateway sheet and Settings > Connection:
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
            // Diagnostics & logs, if open, reads what the gateway did itself
            // (GatewayDiagnosticsSheet's restart onChange), in the chat's
            // sheet and in Settings alike.
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

// MARK: - What a restart waits on, and Restart now (GatewayWork.swift)

extension AppState {
    /// Whether this dashboard's plugin names the work a gateway restart
    /// waits on (plugin 0.135+).
    var namesGatewayWork: Bool {
        dashboardTicketBridge != nil && notifierPlugin.reports(GatewayWork.capability)
    }

    /// What a gateway restart waits on now, or nil when the plugin can't say
    /// (an older one, or a gateway that serves the dashboard and refuses
    /// requests while it drains).
    func gatewayWork() async -> GatewayWork? {
        guard namesGatewayWork, let bridge = dashboardTicketBridge,
              let json = try? await bridge.requestJSON(path: GatewayWork.path, method: "GET") else { return nil }
        return GatewayWork(json: json)
    }

    /// Restart now: the update stops waiting, Conduit stops the chats the
    /// restart waits on, and whatever is still running after that (work
    /// Conduit can't stop, a chat that didn't stop) the plugin ends with a
    /// restart through the gateway's service manager. Returns why it
    /// couldn't, or nil.
    func restartGatewayNow() async -> String? {
        guard !gatewayRestartingNow else { return nil }
        guard let bridge = dashboardTicketBridge else {
            return AppLocalization.string("Connect to this dashboard first.")
        }
        gatewayRestartingNow = true
        defer { gatewayRestartingNow = false }
        do {
            _ = try await bridge.requestJSON(path: GatewayWork.restartNowPath, method: "POST")
        } catch {
            return UserFacingError.message(for: error)
        }
        if let work = await gatewayWork(), let client {
            for unit in work.units where unit.canStop {
                guard let sessionID = unit.sessionID else { continue }
                // A chat that won't stop is ended by the forced restart below.
                _ = try? await client.cancel(sessionID, profile: unit.profile ?? activeProfile)
            }
        }
        // Stopped chats end within a few seconds; an update still waiting
        // sends its restart once the flag lands. A read that fails proves
        // nothing, so only an answer with no work skips the force.
        for _ in 0..<5 {
            try? await Task.sleep(for: .seconds(2))
            if let work = await gatewayWork(), work.count == 0 { return nil }
        }
        do {
            _ = try await bridge.requestJSON(path: GatewayWork.forceRestartPath, method: "POST", timeoutMilliseconds: 40_000)
        } catch {
            // The restart can take this dashboard down with the gateway
            // before it answers, so a request that went out and got no
            // answer is how a forced restart looks. Anything the dashboard
            // answered, or that never went out (signed out), is a failure.
            if let refusal = error as? DashboardTicketBridgeError {
                switch refusal {
                case .notReady, .answeredAfterSwitch: break
                default: return UserFacingError.message(for: error)
                }
            }
        }
        return nil
    }
}
