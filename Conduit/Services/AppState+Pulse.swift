//
//  AppState+Pulse.swift
//  Conduit
//
//  Settings > Pulse (beta): shown when the dashboard's plugin serves Pulse
//  (PulseSettings.swift). Pulse lives in the dashboard's own Hermes home, so
//  its chat is made in the dashboard's default profile, whichever profile
//  Conduit has open.
//

import Foundation

extension AppState {
    /// The profile Pulse reads its chat from: the dashboard's own.
    static let pulseHomeProfile = "default"

    /// Wherever the plugin serves it, App Store builds included.
    var showsPulseSettings: Bool {
        notifierPlugin.reports(PulseClient.capability)
    }

    /// Pulse's routes on the dashboard in use now. Each request checks it is
    /// still that dashboard before it goes out, so one made after a switch
    /// fails instead of reaching another host. Pulse's state and what it
    /// remembers are kept as they're answered, once per dashboard (Pulse is
    /// one per host), so Settings > Pulse and What Pulse remembers open on
    /// them next time (#1533).
    var pulseClient: PulseClient {
        let dashboard = activeDashboardID
        return PulseClient(dashboardID: dashboard) { [weak self] path, method, body in
            guard let self, self.activeDashboardID == dashboard,
                  let owner = self.currentDashboardRuntimeOwner() else { throw DashboardTicketBridgeError.notReady }
            // A step answers with the state it made.
            return try await self.keepingAnswer(
                profile: KeptRoute.everyProfile, owner: owner,
                keptAs: { PulseClient.keptRoute(path: path, method: method, answer: $0) }, writes: method != "GET"
            ) {
                try await owner.bridge.requestJSON(path: path, method: method, body: body)
            }
        }
    }

    /// Pulse's state as Settings > Pulse last showed it on this dashboard,
    /// or nil when none is kept.
    func keptPulseState() -> PulseState? {
        keptAnswer(PulseClient.path, profile: KeptRoute.everyProfile).flatMap(PulseState.init(json:))
    }

    /// What Pulse remembers, as its list last showed it, or nil when none
    /// is kept.
    func keptPulseMemory() -> [PulseMemoryItem]? {
        keptAnswer(PulseClient.memoryPath, profile: KeptRoute.everyProfile).map(PulseClient.memoryItems(from:))
    }

    /// Takes an item Pulse forgot out of the kept list too, so the list
    /// never opens on it, even when reading it again fails, or when a read
    /// asked before the forget answers after it.
    func forgetKeptPulseMemoryItem(id: Int) async {
        guard let owner = currentDashboardRuntimeOwner() else { return }
        guard var kept = keptAnswer(PulseClient.memoryPath, profile: KeptRoute.everyProfile) else {
            noteKeptAnswerWrite(for: PulseClient.memoryPath, profile: KeptRoute.everyProfile, owner: owner)
            return
        }
        kept["items"] = (kept["items"] as? [Any] ?? []).filter { PulseMemoryItem(json: $0)?.id != id }
        _ = try? await keepingAnswer(
            profile: KeptRoute.everyProfile, owner: owner, keptAs: { _ in PulseClient.memoryPath }, writes: true
        ) {
            kept
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

    /// Hermes' model slot for Pulse's memory, report lists, and follow-up
    /// and Do it checks, which the plugin registers; nil leaves it on
    /// "auto", where the plugin runs them on Pulse's hidden chat's model
    /// (Hermes' main model when the chat has none of its own, or its provider
    /// is gone): Settings > Pulse's Default.
    static let pulseMemoryTask = "pulse_memory"

    /// Puts Pulse's memory on `model` (nil: Default, its chat's model), in the
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

    // MARK: Quiet for today (Pulse's quiet times, 0.80.2)

    /// Tells the Notification Service Extension whether the host behind the
    /// dashboard in use takes Quiet for today, by the relay gateways it
    /// pairs this iPhone through, so it offers the button on that host's
    /// Pulse pushes; only once its plugin has answered. A gateway no saved
    /// dashboard pairs through any more drops out.
    func sharePulseQuiet() {
        let current = NotificationSharedSettings.pulseQuietGateways
        let next = PulseQuiet.sharedGateways(current, gateways: activeDashboardRelayGatewayIDs, plugin: notifierPlugin,
                                             known: knownRelayGatewayIDs)
        guard next != current else { return }
        NotificationSharedSettings.pulseQuietGateways = next
    }

    /// Whose Pulse push `target` is, as a tap on it is owned
    /// (NotificationDashboardOwnership): the dashboard in use, another saved
    /// one, or one Conduit can't tell.
    func pulseQuietOwnership(_ target: PulseQuietTarget?) -> NotificationDashboardOwnership.Outcome {
        let raw = target?.dashboardID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let dashboardID = UUID(uuidString: raw)
        return NotificationDashboardOwnership.resolve(
            targetDashboardID: dashboardID,
            hasMalformedDashboardID: !raw.isEmpty && dashboardID == nil,
            activeDashboardID: activeDashboardID,
            savedDashboardIDs: savedDashboardRegistry.dashboards.map(\.id),
            targetGatewayID: target?.gatewayID,
            activeDashboardGatewayIDs: activeDashboardRelayGatewayIDs
        )
    }

    /// Quiet for today from a Pulse notification: Pulse keeps to itself
    /// until midnight (a longer spell already set stays), on the dashboard
    /// the push came from (`target`), owned as a tap on the push is
    /// (NotificationDashboardOwnership; nil: the dashboard in use, when it's
    /// the only one). Conduit may be waking in the background, still
    /// connecting: it waits up to `wait` for a connection, then gives the
    /// request `timeoutMilliseconds`, so a background tap fits the time iOS
    /// gives it. A push from another saved dashboard switches to it only
    /// when `switching` (Conduit is open), and never during a call: it waits
    /// for the call to end, as a tapped notification does, and says so.
    /// Whether Pulse said it's quiet.
    func quietPulseForToday(_ target: PulseQuietTarget?, switching: Bool, wait: Duration,
                            timeoutMilliseconds: Int = 15_000) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: wait)
        while dashboardTicketBridge == nil || activeDashboardID == nil, clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
        }
        guard !Task.isCancelled else { return false }
        switch pulseQuietOwnership(target) {
        case .route:
            break
        case .switchFirst(let id):
            guard switching else { return false }
            guard !isVoiceCallInProgress else {
                showCallRefusal(AppLocalization.string("Pulse goes quiet in the other workspace when the call ends."))
                if let target { PushNotificationService.shared.pulseQuietAwaitsCall(target) }
                return false
            }
            await switchDashboard(to: id)
            // As a tap on the push: only once that dashboard is connected.
            guard isConnected, activeDashboardID == id else { return false }
        case .failClosed:
            return false
        }
        guard let active = activeDashboardID, let owner = currentDashboardRuntimeOwner() else { return false }
        do {
            // Kept as Pulse's own steps are, so Settings > Pulse opens on the quiet it set.
            let response = try await keepingAnswer(
                profile: KeptRoute.everyProfile, owner: owner,
                keptAs: { PulseClient.keptRoute(path: PulseClient.path, method: "PUT", answer: $0) }, writes: true
            ) {
                try await owner.bridge.requestJSON(path: PulseClient.path, method: "PUT",
                                                   body: ["quiet_until": "today"], timeoutMilliseconds: timeoutMilliseconds)
            }
            guard activeDashboardID == active else { return false }
            // A plugin from before quiet times answers without them: nothing went quiet.
            return (try? PulseClient.state(from: response))?.quietUntil != nil
        } catch {
            return false
        }
    }
}
