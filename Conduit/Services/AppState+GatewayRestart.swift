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
        guard namesGatewayWork, let bridge = dashboardTicketBridge else { return nil }
        return await Self.gatewayWork(from: bridge)
    }

    private static func gatewayWork(from bridge: DashboardTicketBridge) async -> GatewayWork? {
        guard let json = try? await bridge.requestJSON(path: GatewayWork.path, method: "GET") else { return nil }
        return GatewayWork(json: json)
    }

    /// Restart now (GatewayRestartNow), on the dashboard it started on even
    /// if another becomes active meanwhile. Why it couldn't lands in
    /// gatewayRestartNowFailure.
    func restartGatewayNow() async {
        guard !gatewayRestartingNow else { return }
        let dashboardID = activeDashboardID
        gatewayRestartNowFailure = nil
        guard let bridge = dashboardTicketBridge else {
            gatewayRestartNowFailure = .init(
                message: AppLocalization.string("Connect to this dashboard first."), dashboardID: dashboardID, at: Date())
            return
        }
        gatewayRestartingNow = true
        defer { gatewayRestartingNow = false }
        let client = client
        let profile = activeProfile
        let steps = GatewayRestartNow(
            endWait: {
                do {
                    _ = try await bridge.requestJSON(path: GatewayWork.restartNowPath, method: "POST")
                    return nil
                } catch {
                    return UserFacingError.message(for: error)
                }
            },
            readWork: { await Self.gatewayWork(from: bridge) },
            stop: { unit in
                guard let sessionID = unit.sessionID else { return }
                _ = try? await client?.cancel(sessionID, profile: unit.profile ?? profile)
            },
            force: {
                do {
                    _ = try await bridge.requestJSON(
                        path: GatewayWork.forceRestartPath, method: "POST", timeoutMilliseconds: 40_000)
                } catch {
                    // The restart can take this dashboard down with the
                    // gateway before it answers, so a request that went out
                    // and got no answer is how a forced restart looks.
                    // Anything the dashboard answered, or that never went
                    // out (signed out), is a failure.
                    // (.notReady is also how a page that went down with the
                    // gateway mid-request ends, so it counts as sent.)
                    if let refusal = error as? DashboardTicketBridgeError {
                        switch refusal {
                        case .notReady, .answeredAfterSwitch: break
                        case .http(status: 501, _):
                            // The gateway isn't a systemd service.
                            return AppLocalization.string("Conduit can only force a restart for a gateway that systemd runs. Run hermes gateway stop, then hermes gateway start, on the host.")
                        default: return UserFacingError.message(for: error)
                        }
                    } else if let dropped = error as? URLError,
                              [.networkConnectionLost, .timedOut, .cannotConnectToHost].contains(dropped.code) {
                        // The native sign-in's connection, gone with the dashboard.
                    } else if !(error is CancellationError) {
                        return UserFacingError.message(for: error)
                    }
                }
                return nil
            },
            pause: { try? await Task.sleep(for: .seconds(2)) }
        )
        // A sign-out or switch meanwhile leaves the failure with the run.
        if let message = await steps.run(), activeDashboardID == dashboardID, dashboardTicketBridge === bridge {
            gatewayRestartNowFailure = .init(message: message, dashboardID: dashboardID, at: Date())
        }
    }
}
