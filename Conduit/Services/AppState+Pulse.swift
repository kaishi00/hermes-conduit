//
//  AppState+Pulse.swift
//  Conduit
//
//  Settings > Pulse (beta): shown when the dashboard's plugin serves Pulse
//  (PulseSettings.swift). Pulse lives in the Hermes home of the profile its
//  plugin runs in, which it names (the default profile from an older
//  plugin), so its chat is made there, whichever profile Conduit has open.
//

import Foundation
import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    /// The profile an older plugin's Pulse reads its chat from, which names
    /// none: the dashboard's default profile (`pulseHomeProfile`).
    static let pulseDefaultProfile = "default"

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

    /// Takes an item Pulse forgot out of the list kept for the dashboard it
    /// was forgotten on (`owner`, as the forget was asked), another one
    /// open by then or not, so the list never opens on it, even when
    /// reading it again fails, or when a read asked before the forget
    /// answers after it.
    func forgetKeptPulseMemoryItem(id: Int, owner: DashboardRuntimeOwner) async {
        guard var kept = keptAnswer(PulseClient.memoryPath, profile: KeptRoute.everyProfile, on: owner) else {
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

    /// Makes Pulse's chat: a new chat in the profile Pulse runs in
    /// (`profile`, as Settings > Pulse's state names it; nil, the default
    /// profile, for an older plugin), titled as Pulse looks for it, and pinned so pruning never removes it.
    /// A pin Hermes doesn't take leaves the chat made; the page then offers
    /// Pin it.
    func createPulseHomeChat(title: String, profile: String?) async throws {
        guard let client, let bridge = dashboardTicketBridge else { throw HermesError.notConnected }
        let profile = profile ?? Self.pulseDefaultProfile
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
    /// profile Pulse runs in (`profile`, as for createPulseHomeChat). The user picked it for
    /// Pulse, so Hermes' price check doesn't ask again. It goes to the
    /// dashboard in use: the caller checks that's still the one it means.
    func setPulseMemoryModel(_ model: PulseModel?, profile: String?) async throws {
        guard let bridge = dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        let profile = profile ?? Self.pulseDefaultProfile
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

    /// Pins Pulse's chat on the host, in the profile Pulse runs in
    /// (`profile`, as for createPulseHomeChat).
    func pinPulseHomeChat(id: String, profile: String?) async throws {
        guard let bridge = dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        let profile = profile ?? Self.pulseDefaultProfile
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
        // A launch waiting for a dashboard pick signs in for it.
        releaseLaunchDashboardChoice(for: "Pulse's Quiet for Today")
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
                showCallRefusal(AppLocalization.string("Pulse goes quiet in the other workspace when the call ends.", table: .pulse))
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

extension AppState {
    // MARK: - Pulse's remembered homes, Do it bots and folded briefs

    /// Sets where Do it goes for a card from no chat on this dashboard:
    /// `bot`'s Bot Chat, or a new chat for nil.
    func setPulseDoItBot(_ bot: String?) {
        guard let key = activeDashboardID?.uuidString, pulseDoItBots[key] != bot else { return }
        var bots = pulseDoItBots
        bots[key] = bot
        storePulseDoItBots(bots)
    }

    private func storePulseDoItBots(_ bots: [String: String]) {
        objectWillChange.send()
        pulseDoItBots = bots
        defaults.set(bots, forKey: Self.pulseDoItBotsKey)
    }

    func rememberPulseHome(_ chat: String?, profile: String?) {
        guard let key = activeDashboardID?.uuidString else { return }
        if pulseRememberedProfiles[key] != profile {
            var profiles = pulseRememberedProfiles
            profiles[key] = profile
            storePulseProfiles(profiles)
        }
        guard pulseRememberedHomes[key] != chat else { return }
        var homes = pulseRememberedHomes
        homes[key] = chat
        storePulseHomes(homes)
    }

    /// A removed dashboard's Pulse chat goes with it.
    func forgetPulseHome(of dashboardID: UUID) {
        var bots = pulseDoItBots
        if bots.removeValue(forKey: dashboardID.uuidString) != nil { storePulseDoItBots(bots) }
        var profiles = pulseRememberedProfiles
        if profiles.removeValue(forKey: dashboardID.uuidString) != nil { storePulseProfiles(profiles) }
        var homes = pulseRememberedHomes
        guard homes.removeValue(forKey: dashboardID.uuidString) != nil else { return }
        storePulseHomes(homes)
    }

    /// Do it's New Chat, for a Pulse item from no chat (PulseFeed.swift):
    /// only when New Chat can start one at once, never one that waits. The
    /// chat is the one this call's own create opened, as createNewSession
    /// returns it, while it's still the one open: another create landing
    /// meanwhile (a call's chat, Ask Hermes About, a widget) opens a chat
    /// that isn't this one's. The Pulse screen stays up until it opened, so
    /// a chat that didn't start leaves it there to say why. Nil when none
    /// started.
    func startPulseNewChat() async -> String? {
        guard canStartNewChatNow, !isStartingNewChat, !showsPendingNewChat else { return nil }
        guard let created = await createNewSessionMarkingStart(), activeSessionId == created else { return nil }
        dismissSidebarDrawer()
        return created
    }

    /// Do it's switch to Pulse's profile, for a new chat there: whether it
    /// finished with that profile on screen. False when a newer navigation
    /// took the screen meanwhile, which a new chat mustn't replace.
    func switchProfileForPulse() async -> Bool {
        await switchProfile(to: pulseHomeProfile, reusing: nil)
    }

    private func storePulseHomes(_ homes: [String: String]) {
        objectWillChange.send()
        pulseRememberedHomes = homes
        defaults.set(homes, forKey: Self.pulseHomesKey)
    }

    private func storePulseProfiles(_ profiles: [String: String]) {
        objectWillChange.send()
        pulseRememberedProfiles = profiles
        defaults.set(profiles, forKey: Self.pulseProfilesKey)
    }

    static let pulseFoldedBriefsKey = "conduit.pulse.foldedBriefs"

    static let pulseFoldedBriefsKept = 30

    /// The cards `brief` had open when it was folded, by id, each with when
    /// it came; nil while it isn't folded.
    func pulseBriefFold(_ brief: Int) -> [Int: Double]? {
        guard let key = activeDashboardID?.uuidString,
              let open = pulseFoldedBriefs[key]?[String(brief)] else { return nil }
        let cards = open.compactMap { card, at in Int(card).map { ($0, at) } }
        return Dictionary(cards, uniquingKeysWith: { first, _ in first })
    }

    /// Folds `brief` with `open`, the cards in it still open then
    /// (PulseLayout.Brief.openCards), or opens it again (nil).
    func foldPulseBrief(_ brief: Int, open: [Int: Double]?) {
        guard let key = activeDashboardID?.uuidString else { return }
        var briefs = pulseFoldedBriefs[key] ?? [:]
        let noted = open.map { cards in Dictionary(uniqueKeysWithValues: cards.map { (String($0.key), $0.value) }) }
        guard briefs[String(brief)] != noted else { return }
        briefs[String(brief)] = noted
        // An older brief folded now stays folded: the oldest other fold goes.
        let others = briefs.keys.compactMap { Int($0) }.filter { $0 != brief }.sorted()
        let kept = Set(others.suffix(Self.pulseFoldedBriefsKept - 1)).union([brief])
        briefs = briefs.filter { id, _ in Int(id).map { kept.contains($0) } ?? false }
        var all = pulseFoldedBriefs
        all[key] = briefs.isEmpty ? nil : briefs
        storePulseFoldedBriefs(all)
    }

    /// `card`, in `brief`, put back open with Undo or Put back: the fold no
    /// longer counts it as open when it was folded, so a folded brief opens
    /// to show it, and folds again once it's handled.
    func unfoldPulseCard(_ card: Int, in brief: Int) {
        guard var open = pulseBriefFold(brief), open.removeValue(forKey: card) != nil else { return }
        foldPulseBrief(brief, open: open)
    }

    /// A removed dashboard's folded briefs go with it.
    func forgetPulseFoldedBriefs(of dashboardID: UUID) {
        var all = pulseFoldedBriefs
        guard all.removeValue(forKey: dashboardID.uuidString) != nil else { return }
        storePulseFoldedBriefs(all)
    }

    private func storePulseFoldedBriefs(_ all: [String: [String: [String: Double]]]) {
        objectWillChange.send()
        pulseFoldedBriefs = all
        defaults.set(all, forKey: Self.pulseFoldedBriefsKey)
    }
}
