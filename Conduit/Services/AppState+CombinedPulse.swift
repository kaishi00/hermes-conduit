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
    /// Its kept connection dropped: a tap switches there and signs in.
    var switches = false
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
            // Shown here, its feed read on its own runtime knows best; once
            // another is shown, whichever read is newer: the page's last one
            // there (its cards just seen) or the background read since.
            var unseen = pulse.unseen
            let kept = runtime(for: dashboard.id)
            if let runtime = kept, let applied = runtime.pulseFeedAppliedAt,
               shown == dashboard.id || applied.at > pulse.at {
                unseen = runtime.pulseUnseen
            }
            return PulseDashboardChip(
                dashboardID: dashboard.id, badge: mark, unseen: unseen, isShown: shown == dashboard.id,
                switches: kept == nil
            )
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

    /// Before the page reads another dashboard's feed in place: what its
    /// plugin serves, read on its own runtime when one signed in quietly
    /// beside this one hasn't been asked yet, so its feed is asked for
    /// suggestions and looks, and its cards get their buttons, as there.
    func readyShownPulseRuntime() async {
        guard pulseRuntime != nil, let id = pulseShownDashboardID else { return }
        await readKeptPluginStatusIfUnknown(id)
    }

    /// Shows another combined dashboard's Pulse in place: the page reads
    /// and acts on its feed through its kept connection, with no switch, so
    /// no call ends either. Its own chip goes back to the one on screen's;
    /// one whose kept connection dropped switches there, signs in and opens
    /// its Pulse (refused during a call).
    func openCombinedPulse(_ dashboardID: UUID) {
        let other = dashboardID != dashboardIDOnScreen
        // A chip whose kept connection dropped (its list stays, below) signs
        // in as a switch does, as the chip did before stage 2.
        if other, runtime(for: dashboardID) == nil {
            guard !refusesCombinedSwitchDuringCall(to: dashboardID) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.switchToCombinedDashboardUntilSettled(dashboardID)
                // Another dashboard picked meanwhile owns the screen.
                guard self.activeDashboardID == dashboardID else { return }
                if self.pulseShownDashboardID != nil { self.pulseShownDashboardID = nil }
                self.openPulse(card: nil)
            }
            return
        }
        let shown: UUID? = other ? dashboardID : nil
        if pulseShownDashboardID != shown { pulseShownDashboardID = shown }
    }

    /// A card's chat on another combined dashboard's Pulse shown in place:
    /// it opens as a chat link naming that dashboard is routed, in place on its
    /// own runtime through its kept connection with no switch (a Bot Chat,
    /// a listed chat or one its list doesn't hold), at the message the card
    /// came from; the link's route switches only when that dashboard can't
    /// open it in place. `dashboard` is the one whose Pulse the page showed
    /// at the tap. False when the card is the dashboard on screen's, the
    /// page has left that Pulse, or its kept connection is gone: the caller
    /// goes on as before (`switchForFarPulseStep`).
    func openFarPulseCardChat(_ card: PulseCard, for dashboard: UUID?) -> Bool {
        guard let id = dashboard, id != dashboardIDOnScreen, pulseDashboardID == id,
              let runtime = runtime(for: id) else { return false }
        // What the card names, as its own Pulse reads it, its profile
        // spelled as that dashboard lists it (its default is its own).
        let (hasChat, profile) = act(onRuntime: runtime) {
            (pulseCardHasChat(card), notificationProfileID(card.profile.isEmpty ? pulseHomeProfile : card.profile))
        }
        guard hasChat else { return true }
        let reveal = card.messageID.map { ArtifactReveal(messageID: $0, opening: card.chatID) }
        pendingArtifactReveal = reveal
        widgetLaunchCoordinator.supersede()
        // A workstream's hidden chat opens on its bot's profile, as its
        // link does (`openAppLink`). One that can't start (its socket busy
        // with a request, so not handed to that profile now) has said so,
        // and nothing waits to scroll.
        if let workstreamProfile = runtime.botWork.workstreamProfile(forSession: [card.chatID]) {
            let open = openFarWorkstreamInPlace(
                card.chatID, profile: profile ?? workstreamProfile, in: id
            )
            if open == nil, pendingArtifactReveal == reveal { pendingArtifactReveal = nil }
            return true
        }
        // The route tries it in place first, so a call goes on; only a
        // switch it falls back to is refused during one.
        PushNotificationService.shared.routeChatLink(
            ConduitNotificationTarget(
                profile: profile, sessionId: card.chatID, dashboardID: id, type: nil, isChatLink: true
            )
        )
        return true
    }

    /// Before a Pulse card's step that opens a task or starts Do it's chat,
    /// or changes this phone's calendar, on another combined dashboard's
    /// Pulse: the switch there (its board and its new chats are that
    /// dashboard's own pages, and this phone shares its calendar with the
    /// one on screen). A card's chat link doesn't come here while that
    /// dashboard is kept connected (`openFarPulseCardChat`). `dashboard`
    /// is the one whose Pulse the page showed at the tap (`pulseDashboardID`
    /// then). True when the step can go ahead on that dashboard, the page
    /// still showing its Pulse: never on another one, as a chip picked
    /// meanwhile, a switch or a connection let go would make it.
    func switchForFarPulseStep(for dashboard: UUID?) async -> Bool {
        guard let id = dashboard else { return false }
        guard id != dashboardIDOnScreen else { return pulseDashboardID == id }
        // A chip picked since the tap: no switch for a step the page left.
        guard pulseDashboardID == id, runtime(for: id) != nil else { return false }
        guard !refusesCombinedSwitchDuringCall(to: id) else { return false }
        await switchToCombinedDashboardUntilSettled(id)
        guard !Task.isCancelled, activeDashboardID == id else { return false }
        if pulseShownDashboardID == id { pulseShownDashboardID = nil }
        return pulseDashboardID == id
    }
}
