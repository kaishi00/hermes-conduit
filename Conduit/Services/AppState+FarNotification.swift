//
//  AppState+FarNotification.swift
//  Conduit
//
//  A push or chat link from another combined dashboard opens in place (no-
//  switch stage 2, the notifications thread): its route runs on that
//  dashboard's own runtime, through its kept connection, as the far Chats
//  row's open does (AppState+FarChat.swift), while the dashboard on screen
//  stays as it is. What opens on another surface keeps the switch until
//  that surface opens in place: a group room's, a Pulse report's, a call's
//  and a Bot Chat's.
//  The plan: /mnt/project-files/all-live/no-switch-plan.md.
//

import Foundation

extension AppState {
    /// The runtime a push for another combined dashboard opens on in place:
    /// that dashboard's kept one, on the push's profile. Nil when it opens
    /// through a switch as before: the dashboard isn't kept connected (or
    /// its socket can't be handed to that profile), or the push opens a
    /// room, its Pulse, a call or a Bot Chat, or an approval for a chat its
    /// list doesn't hold (a room's hidden chat, whose card is the room's).
    /// Also nil while its bots aren't read yet, since a Bot Chat's push
    /// can't be told from a chat's then: the switch reads them and opens it
    /// in Bots, as before. A push that names no profile opens on the one
    /// that dashboard is on, as a switch resumes it.
    func farNotificationRuntime(_ target: ConduitNotificationTarget, in dashboardID: UUID) -> DashboardRuntime? {
        guard dashboardID != dashboardIDOnScreen, isInCombinedGroup(dashboardID),
              let kept = keptDashboardRuntimes[dashboardID],
              combinedDashboardBots[dashboardID] != nil || !kept.runtime.botRoster.isEmpty,
              Self.farNotificationOpensInPlace(
                  target,
                  listed: combinedDashboardChats[dashboardID]?.sessions ?? [],
                  botChats: farBotChatIDs(in: dashboardID),
                  pulseHome: farPulseHome(in: dashboardID)
              ) else { return nil }
        let profile = target.profile.flatMap { $0.isEmpty ? nil : $0 } ?? kept.runtime.activeProfile
        return keptRuntime(dashboardID, on: profile)
    }

    /// Whether a push for another combined dashboard is one its chat opens
    /// in place for: a chat's reply, failure or background task, a wait's
    /// question or approval in a chat its list holds, or a chat link. Pure,
    /// for tests.
    static func farNotificationOpensInPlace(
        _ target: ConduitNotificationTarget,
        listed: [SessionSummary],
        botChats: Set<String>,
        pulseHome: String?
    ) -> Bool {
        guard target.call == nil, target.roomID == nil else { return false }
        let ids = Set([target.sessionId, target.durableSessionID].compactMap { $0 }.filter { !$0.isEmpty })
        guard !ids.isEmpty, ids.isDisjoint(with: botChats) else { return false }
        if let pulseHome, ids.contains(pulseHome) { return false }
        if case .approval = target.decision {
            return listed.contains { !ids.isDisjoint(with: SessionContentSearch.identities(of: $0)) }
        }
        return true
    }

    /// Another combined dashboard's Bot Chats, by its bots as Bots Home or
    /// its kept runtime read them.
    func farBotChatIDs(in dashboardID: UUID) -> Set<String> {
        let roster = (combinedDashboardBots[dashboardID]?.bots ?? [])
            + (keptDashboardRuntimes[dashboardID]?.runtime.botRoster ?? [])
        return Set(roster.compactMap(\.canonicalSessionID))
    }

    /// Another combined dashboard's Pulse chat, as its kept runtime, its
    /// feed or its last visit here named it.
    func farPulseHome(in dashboardID: UUID) -> String? {
        keptDashboardRuntimes[dashboardID]?.runtime.pulseHomeChatID
            ?? combinedDashboardPulse[dashboardID]?.homeChatID
            ?? pulseRememberedHomes[dashboardID.uuidString]
    }
}
