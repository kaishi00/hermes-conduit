//
//  AppState+CombinedPulse.swift
//  Conduit
//
//  All-live stage 4d: a chip per combined dashboard on top of Pulse. Pulse
//  is one per host, its cards' steps (Done, Not now, Do it, ratings) are
//  that host's, so a chip shows that dashboard's Pulse: a tap switches to
//  it, through its kept connection, at once. Each other dashboard's chip
//  says how many of its cards are new, read through its kept connection.
//

import Foundation

/// Another combined dashboard's Pulse, as its feed last answered.
struct CombinedDashboardPulse: Equatable {
    let bridge: ObjectIdentifier
    let unseen: Int
    /// Its Pulse chat and the profile it's in, as the feed named them, so
    /// Chats keeps that chat behind its Pulse before it's opened here.
    var homeChatID: String? = nil
    var profile: String? = nil
    let at: Date
}

/// One chip on top of Pulse.
struct PulseDashboardChip: Identifiable, Equatable {
    let dashboardID: UUID
    let badge: V2DashboardBadge
    let unseen: Int
    let isOnScreen: Bool
    var id: UUID { dashboardID }
}

extension AppState {
    /// How long another dashboard's count stands before Pulse's page reads
    /// it again.
    static let combinedDashboardPulseMaxAge: TimeInterval = 50

    /// Reads each other combined dashboard's Pulse feed through its kept
    /// connection, for its count of new cards. One whose plugin has no
    /// feed has no chip; a read that fails keeps what the chip said.
    func readOtherCombinedDashboardsPulse(force: Bool = false, now: Date = Date()) async {
        let kept = keptDashboardRuntimes.filter { isInCombinedGroup($0.key) && $0.key != activeDashboardID }
        // One that dropped by itself keeps its last list until it's back;
        // out of the group or opened here, it goes.
        if combinedDashboardPulse.keys.contains(where: { !isInCombinedGroup($0) || $0 == activeDashboardID }) {
            combinedDashboardPulse = combinedDashboardPulse.filter { isInCombinedGroup($0.key) && $0.key != activeDashboardID }
        }
        for (id, runtime) in kept.sorted(by: { $0.value.keptAt < $1.value.keptAt }) {
            guard isSceneActive else { return }
            let bridge = ObjectIdentifier(runtime.bridge)
            if !force, let last = combinedDashboardPulse[id], last.bridge == bridge,
               now.timeIntervalSince(last.at) < Self.combinedDashboardPulseMaxAge { continue }
            // Suggestions asked for, as the page it opens asks where they're
            // on: a plugin without them ignores the ask, and the count then
            // matches what that page shows new.
            let path = "\(PulseClient.path)/feed" + PulseClient.feedQuery(proposals: true, looks: false)
            let response = try? await readKeptDashboardJSON(runtime.bridge, path: path)
            // Let go, opened, or out of the group while the read was out.
            guard keptDashboardRuntimes[id]?.bridge === runtime.bridge, activeDashboardID != id,
                  isInCombinedGroup(id), let response, let page = PulseFeedPage(json: response) else { continue }
            // A read started later already stored its count: keep that one.
            if let stored = combinedDashboardPulse[id], stored.at > now { continue }
            combinedDashboardPulse[id] = CombinedDashboardPulse(
                bridge: bridge, unseen: page.unseen, homeChatID: page.homeChatID, profile: page.profile, at: now
            )
        }
    }

    /// The chips on top of Pulse: the dashboard on screen's, then each
    /// other combined dashboard whose Pulse answered, in Saved Dashboards
    /// order. None unless there's another to show.
    var pulseDashboardChips: [PulseDashboardChip] {
        guard let active = activeDashboardID, isInCombinedGroup(active) else { return [] }
        let chips: [PulseDashboardChip] = savedDashboardRegistry.dashboards.compactMap { dashboard in
            guard isInCombinedGroup(dashboard.id), let badge = combinedDashboardBadge(dashboard.id) else { return nil }
            let mark = V2DashboardBadge(letter: badge.letter, colorIndex: badge.colorIndex, name: badge.name)
            if dashboard.id == active {
                return PulseDashboardChip(dashboardID: active, badge: mark, unseen: pulseUnseen, isOnScreen: true)
            }
            guard let pulse = combinedDashboardPulse[dashboard.id] else { return nil }
            return PulseDashboardChip(dashboardID: dashboard.id, badge: mark, unseen: pulse.unseen, isOnScreen: false)
        }
        return chips.count > 1 ? chips : []
    }

    /// Shows another combined dashboard's Pulse: the switch to it, through
    /// its kept connection, then its Pulse page.
    func openCombinedPulse(_ dashboardID: UUID) {
        guard dashboardID != activeDashboardID, !refusesCombinedSwitchDuringCall() else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Open as soon as its sync settles, as its bots do.
            await self.switchToCombinedDashboardUntilSettled(dashboardID)
            // Another dashboard picked meanwhile owns the screen.
            guard self.activeDashboardID == dashboardID else { return }
            self.openPulse(card: nil)
        }
    }
}
