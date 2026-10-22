//
//  AppState+Pulse.swift
//  Conduit
//
//  Settings > Pulse (beta): shown on TestFlight and Xcode builds when the
//  dashboard's plugin serves Pulse (PulseSettings.swift). Pulse lives in the
//  dashboard's own Hermes home, so its chat is made in the dashboard's
//  default profile, whichever profile Conduit has open.
//

import Foundation

extension AppState {
    /// The profile Pulse reads its chat from: the dashboard's own.
    static let pulseHomeProfile = "default"

    /// TestFlight and Xcode builds only, and only where the plugin serves it.
    var showsPulseSettings: Bool {
        appInstallSource != .appStore && notifierPlugin.reports(PulseClient.capability)
    }

    /// Pulse's routes on the dashboard in use now. Each request checks it is
    /// still that dashboard before it goes out, so one made after a switch
    /// fails instead of reaching another host.
    var pulseClient: PulseClient {
        let dashboard = activeDashboardID
        return PulseClient(dashboardID: dashboard) { [weak self] path, method, body in
            guard let self, self.activeDashboardID == dashboard,
                  let bridge = self.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
            return try await bridge.requestJSON(path: path, method: method, body: body)
        }
    }

    /// Makes Pulse's chat: a new chat in the dashboard's default profile,
    /// titled as Pulse looks for it, and pinned so pruning never removes it.
    /// A pin Hermes doesn't take leaves the chat made; the page then offers
    /// Pin it.
    func createPulseHomeChat(title: String) async throws {
        guard let client, let bridge = dashboardTicketBridge else { throw HermesError.notConnected }
        let profile = Self.pulseHomeProfile
        let inUse = profilesMatch(profile, activeProfile)
        let created = try await client.createSession(inProfile: inUse ? nil : profile)
        if let returned = created.profile, !profilesMatch(returned, profile) {
            throw HermesError.invalidResponse
        }
        try await client.setSessionTitle(created.sessionId, title: title, profile: inUse ? nil : profile)
        _ = try? await sendSessionMutation(
            created.storedSessionId ?? created.sessionId, body: ["pinned": true], profile: profile, bridge: bridge
        )
        if inUse { await loadSessions(forceRefresh: true) }
    }

    /// Hermes' model slot for Pulse's memory and follow-up checks, which
    /// the plugin registers; nil follows the main model.
    static let pulseMemoryTask = "pulse_memory"

    /// Puts Pulse's memory on `model` (nil: the main model), in the
    /// dashboard's default profile where Pulse runs. The user picked it for
    /// Pulse, so Hermes' price check doesn't ask again. It goes to the
    /// dashboard in use: the caller checks that's still the one it means.
    func setPulseMemoryModel(_ model: PulseModel?) async throws {
        guard let bridge = dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        let profile = Self.pulseHomeProfile
        _ = try await bridge.requestJSON(
            path: DashboardPath.withProfile("/api/model/set", profile: profile),
            method: "POST",
            body: [
                "scope": "auxiliary",
                "task": Self.pulseMemoryTask,
                "provider": model.map { $0.provider.isEmpty ? "auto" : $0.provider } ?? "auto",
                "model": model?.model ?? "",
                "confirm_expensive_model": true,
                "profile": profile
            ]
        )
    }

    /// Pins Pulse's chat on the host.
    func pinPulseHomeChat(id: String) async throws {
        guard let bridge = dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        let profile = Self.pulseHomeProfile
        try await sendSessionMutation(id, body: ["pinned": true], profile: profile, bridge: bridge)
        if profilesMatch(profile, activeProfile) { await loadSessions(forceRefresh: true) }
    }
}
