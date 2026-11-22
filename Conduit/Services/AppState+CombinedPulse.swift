//
//  AppState+CombinedPulse.swift
//  Conduit
//
//  All-live stage 4d: a chip per combined dashboard on top of Pulse. Pulse
//  is one per host, its cards' steps (Done, Not now, Do it, ratings) are
//  that host's, so a chip shows that dashboard's Pulse: in place, on that
//  dashboard's own runtime through its kept connection, with no switch
//  (no-switch stage 2). Each other dashboard's chip says how many of its
//  cards are new, read through its kept connection.
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
    /// The page shows its Pulse.
    let isShown: Bool
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
        let shown = pulseDashboardID
        let chips: [PulseDashboardChip] = savedDashboardRegistry.dashboards.compactMap { dashboard in
            guard isInCombinedGroup(dashboard.id), let badge = combinedDashboardBadge(dashboard.id) else { return nil }
            let mark = V2DashboardBadge(letter: badge.letter, colorIndex: badge.colorIndex, name: badge.name)
            if dashboard.id == active {
                return PulseDashboardChip(dashboardID: active, badge: mark, unseen: pulseUnseen, isShown: shown == active)
            }
            guard let pulse = combinedDashboardPulse[dashboard.id] else { return nil }
            // Its feed read on its own runtime (shown here) knows best.
            var unseen = pulse.unseen
            if let runtime = runtime(for: dashboard.id), runtime.pulseFeedAppliedAt != nil { unseen = runtime.pulseUnseen }
            return PulseDashboardChip(dashboardID: dashboard.id, badge: mark, unseen: unseen, isShown: shown == dashboard.id)
        }
        return chips.count > 1 ? chips : []
    }

    /// The dashboard the Pulse page shows: a chip's, while it's kept
    /// connected (no-switch stage 2), else the one on screen.
    var pulseDashboardID: UUID? { pulseRuntime == nil ? activeDashboardID : pulseShownDashboardID }

    /// The runtime of the other combined dashboard the Pulse page shows;
    /// nil while it shows the one on screen's.
    var pulseRuntime: DashboardRuntime? {
        guard let id = pulseShownDashboardID, id != dashboardIDOnScreen else { return nil }
        return runtime(for: id)
    }

    /// What the plugin of the Pulse shown serves: the one on screen's but
    /// while the page shows another dashboard's (its chip), which goes back
    /// as the page leaves, so Settings > Pulse stays the one on screen's.
    var pulsePlugin: NotifierPluginStatus { readingPulseRuntime { notifierPlugin } }

    /// What the Pulse page draws (what its plugin serves, its counts), from
    /// the dashboard it shows.
    func readingPulseRuntime<T>(_ body: () -> T) -> T {
        guard let runtime = pulseRuntime, runtime !== shownRuntime else { return body() }
        return act(onRuntime: runtime, body)
    }

    /// A step of the Pulse page on the dashboard it shows.
    func onPulseRuntime<T>(_ body: () async -> T) async -> T {
        guard let runtime = pulseRuntime, runtime !== shownRuntime else { return await body() }
        return await actAcrossAwaits(onRuntime: runtime, body)
    }

    /// Shows another combined dashboard's Pulse in place: the page reads
    /// and acts on its feed through its kept connection, with no switch, so
    /// no call ends either. Its own chip, or one not connected here, goes
    /// back to the one on screen's (one let go shows the screen's anyway).
    func openCombinedPulse(_ dashboardID: UUID) {
        let far = dashboardID != dashboardIDOnScreen && runtime(for: dashboardID) != nil
        let shown: UUID? = far ? dashboardID : nil
        if pulseShownDashboardID != shown { pulseShownDashboardID = shown }
    }

    /// Before a Pulse card's step that opens a chat or task, or changes
    /// this phone's calendar, on another combined dashboard's Pulse: the
    /// switch there, until chats of another dashboard open in place too
    /// (this phone shares its calendar with the one on screen). True when
    /// the step can go ahead on the dashboard the page showed.
    func switchForFarPulseStep() async -> Bool {
        guard let id = pulseShownDashboardID, pulseRuntime != nil else { return true }
        guard !refusesCombinedSwitchDuringCall(to: id) else { return false }
        await switchToCombinedDashboardUntilSettled(id)
        guard !Task.isCancelled, activeDashboardID == id else { return false }
        pulseShownDashboardID = nil
        return true
    }
}
