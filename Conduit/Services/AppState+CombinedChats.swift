//
//  AppState+CombinedChats.swift
//  Conduit
//
//  All-live stage 4b: the Chats list shows every combined dashboard's
//  chats. Each other dashboard's newest are read through its kept
//  connection, for the profile it last used, and merged into the list by
//  last activity, each row marked with its dashboard's badge. A tap
//  switches to that dashboard (through the kept connection, no sign-in)
//  and opens the chat, as a notification from it does.
//

import Foundation

/// Another combined dashboard's newest chats, with what they were read
/// through and when.
struct CombinedDashboardChats: Equatable {
    let bridge: ObjectIdentifier
    let profile: String
    let sessions: [SessionSummary]
    let at: Date
}

extension AppState {
    /// How many of another dashboard's newest chats the list shows.
    static let combinedDashboardChatsLimit = 50

    /// How long another dashboard's chats stand before the poll reads them
    /// again. A pull on the list reads them at once.
    static let combinedDashboardChatsMaxAge: TimeInterval = 60

    /// Reads each other combined dashboard's newest chats through its kept
    /// connection. Quiet on failure: a dashboard that can't be read keeps
    /// what it showed, and one let go or opened says nothing more.
    func readOtherCombinedDashboardsChats(force: Bool = false, now: Date = Date()) async {
        let kept = keptDashboardRuntimes.filter { isInCombinedGroup($0.key) && $0.key != activeDashboardID }
        let gone = combinedDashboardChats.keys.filter { kept[$0] == nil }
        if !gone.isEmpty { combinedDashboardChats = combinedDashboardChats.filter { kept[$0.key] != nil } }
        for (id, runtime) in kept.sorted(by: { $0.value.keptAt < $1.value.keptAt }) {
            guard isSceneActive else { return }
            let bridge = ObjectIdentifier(runtime.bridge)
            let profile = rememberedActiveProfile(for: id) ?? "default"
            if !force, let last = combinedDashboardChats[id], last.bridge == bridge,
               profilesMatch(last.profile, profile),
               now.timeIntervalSince(last.at) < Self.combinedDashboardChatsMaxAge { continue }
            let path = profileSessionsPath(profile, limit: Self.combinedDashboardChatsLimit)
            let response = try? await readKeptDashboardJSON(runtime.bridge, path: path)
            // Let go, opened, or out of the group while the read was out.
            // Its profile changed meanwhile, or a read started later already
            // stored its answer: either way this one is stale.
            guard keptDashboardRuntimes[id]?.bridge === runtime.bridge, activeDashboardID != id,
                  isInCombinedGroup(id), profilesMatch(rememberedActiveProfile(for: id) ?? "default", profile),
                  !(combinedDashboardChats[id].map { $0.at > now } ?? false) else { continue }
            // An answer with no list (an error body) is a failed read.
            guard let batch = response?["sessions"] as? [Any] else { continue }
            let sessions = Self.dashboardOwnedSessions(batch, profile: profile).map { row -> SessionSummary in
                var row = row
                row.combinedDashboardID = id
                return row
            }
            combinedDashboardChats[id] = CombinedDashboardChats(bridge: bridge, profile: profile, sessions: sessions, at: now)
        }
    }

    /// The other combined dashboards' chats the Chats list merges in,
    /// newest first. Only while the dashboard on screen is in the group,
    /// and none whose id the list already holds (one Hermes saved twice).
    func otherCombinedDashboardsChats(excluding listed: Set<String>) -> [SessionSummary] {
        guard isInCombinedGroup(activeDashboardID) else { return [] }
        var merged: [SessionSummary] = []
        // An id another dashboard already gave keeps the first one's row, so
        // the list never holds one id twice.
        var taken = listed
        for dashboard in savedDashboardRegistry.dashboards where dashboard.id != activeDashboardID {
            guard isInCombinedGroup(dashboard.id), let chats = combinedDashboardChats[dashboard.id] else { continue }
            // That dashboard's Pulse chat, as its feed names it or as it last
            // named it there, stays behind its Pulse, as this one's does.
            let key = dashboard.id.uuidString
            let feed = combinedDashboardPulse[dashboard.id]
            let home = feed?.homeChatID.map { ($0, feed?.profile) }
                ?? pulseRememberedHomes[key].map { ($0, pulseRememberedProfiles[key]) }
            let pulseHome = home.flatMap { profilesMatch(chats.profile, $0.1 ?? chats.profile) ? $0.0 : nil }
            let fresh = chats.sessions.filter {
                !taken.contains($0.id) && !(pulseHome.map($0.nestingIDs.contains) ?? false)
            }
            taken.formUnion(fresh.map(\.id))
            merged = V2FilterSelection.mergedByRecency(merged, fresh)
        }
        return merged
    }

    /// The dashboard another combined dashboard's row came from; nil for
    /// the dashboard on screen's own rows.
    func combinedChatDashboard(_ session: SessionSummary) -> UUID? {
        guard let id = session.combinedDashboardID, id != activeDashboardID else { return nil }
        return id
    }

    /// The badge another combined dashboard's row carries.
    func combinedChatBadge(_ session: SessionSummary) -> V2DashboardBadge? {
        guard let id = combinedChatDashboard(session), let badge = combinedDashboardBadge(id) else { return nil }
        return V2DashboardBadge(letter: badge.letter, colorIndex: badge.colorIndex, name: badge.name)
    }

    /// A switch to another combined dashboard during a call says to end the
    /// call first, as a notification from that dashboard does: the switch
    /// would end it.
    func refusesCombinedSwitchDuringCall() -> Bool {
        guard isVoiceCallInProgress else { return false }
        showCallRefusal(AppLocalization.string("End the call to open a chat in another workspace."))
        return true
    }

    /// Opens another combined dashboard's row: the switch to its dashboard
    /// (through its kept connection), then the chat in the profile it was
    /// read for, as a notification from that dashboard opens.
    func openCombinedChat(_ session: SessionSummary, in dashboardID: UUID) {
        // The notification path refuses during a call too; saying so here
        // keeps it to the tap.
        guard !refusesCombinedSwitchDuringCall() else { return }
        PushNotificationService.shared.routeChatLink(combinedChatTarget(session, in: dashboardID))
    }

    /// Where another combined dashboard's row opens: its chat, in the
    /// profile it was read for, on its dashboard.
    func combinedChatTarget(_ session: SessionSummary, in dashboardID: UUID) -> ConduitNotificationTarget {
        ConduitNotificationTarget(
            profile: combinedDashboardChats[dashboardID]?.profile ?? session.profile ?? "default",
            sessionId: session.id,
            dashboardID: dashboardID,
            type: nil,
            isChatLink: true
        )
    }
}
