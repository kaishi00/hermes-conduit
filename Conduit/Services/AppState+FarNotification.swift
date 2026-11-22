//
//  AppState+FarNotification.swift
//  Conduit
//
//  A push or chat link from another combined dashboard opens in place (no-
//  switch stage 2, the notifications thread): the chat it names opens as
//  its far Chats row does (openFarChatInPlace, AppState+FarChat.swift), on
//  that dashboard's own runtime through its kept connection, while the
//  dashboard on screen stays as it is. What opens on another surface keeps
//  the switch until that surface opens in place: a group room's, a Pulse
//  report's, a call's and a Bot Chat's.
//  The plan: /mnt/project-files/all-live/no-switch-plan.md.
//

import Foundation

extension AppState {
    /// Opens the chat a push or chat link for another combined dashboard
    /// names in place, as its Chats row does, and lands a wait's push on its
    /// card: true once its chat opened, waited on so the card's reveal names
    /// the chat that opened, as on screen; false when the open failed, to
    /// be tried again. Nil when it opens through a
    /// switch as before: the dashboard isn't kept connected (or its socket
    /// can't be handed to the chat's profile), its list doesn't hold the
    /// chat, or the push opens a room, its Pulse, a call or a Bot Chat; and
    /// while its bots aren't read yet, since a Bot Chat's push can't be told
    /// from a chat's then: the switch reads them and opens it in Bots.
    func openFarNotificationInPlace(_ target: ConduitNotificationTarget, in dashboardID: UUID) async -> Bool? {
        guard dashboardID != dashboardIDOnScreen, isInCombinedGroup(dashboardID),
              let kept = keptDashboardRuntimes[dashboardID],
              combinedDashboardBots[dashboardID] != nil || !kept.runtime.botRoster.isEmpty,
              let session = Self.farNotificationChat(
                  target,
                  listed: combinedDashboardChats[dashboardID]?.sessions ?? [],
                  botChats: farBotChatIDs(in: dashboardID),
                  pulseHome: farPulseHome(in: dashboardID)
              ),
              let open = startFarChatOpen(session, in: dashboardID, prepare: {
                  // A wait raised while Conduit was away comes on the push:
                  // its card is recorded on that dashboard's runtime before
                  // the open, whose resume merges it in, as on screen.
                  guard let decision = target.decision else { return }
                  let requested = target.sessionId
                  let ids = [session.id, requested, target.durableSessionID].compactMap { $0 }.filter { !$0.isEmpty }
                  recordNotificationDecision(decision, sessionIDs: ids, cacheSessionIDs: Array(Set([requested, session.id])))
              }) else { return nil }
        // An approval's or a question's push lands on its card, as on screen.
        var reveal: NeedsYouReveal?
        if let type = target.type, NeedsYouStore.notificationTypes.contains(type) {
            reveal = NeedsYouReveal(opening: target.durableSessionID ?? target.sessionId)
            pendingNeedsYouReveal = reveal
        }
        let opened = await open.value
        // One that didn't open is tried again: its card's reveal waits for
        // that try rather than land on another chat. A newer tap's reveal
        // stays.
        if !opened, let reveal, pendingNeedsYouReveal == reveal { pendingNeedsYouReveal = nil }
        return opened
    }

    /// The chat of another combined dashboard's list a push opens in place:
    /// a chat's reply, failure or background task, a wait's question or
    /// approval, or a chat link, for a chat its list holds. Nil for a room's
    /// push, a call's, its Pulse chat's, a Bot Chat's, or a chat it doesn't
    /// list (a room's hidden chat, a chat newer than its last read). Pure,
    /// for tests.
    static func farNotificationChat(
        _ target: ConduitNotificationTarget,
        listed: [SessionSummary],
        botChats: Set<String>,
        pulseHome: String?
    ) -> SessionSummary? {
        guard target.call == nil, target.roomID == nil else { return nil }
        let ids = Set([target.sessionId, target.durableSessionID].compactMap { $0 }.filter { !$0.isEmpty })
        guard !ids.isEmpty, ids.isDisjoint(with: botChats) else { return nil }
        if let pulseHome, ids.contains(pulseHome) { return nil }
        let profile = target.profile.flatMap { $0.isEmpty ? nil : $0 }
        return listed.first { row in
            !ids.isDisjoint(with: SessionContentSearch.identities(of: row))
                && profile.map { profilesMatch(row.profile ?? "default", $0) } ?? true
        }
    }

    /// Another combined dashboard's Bot Chats, by its bots as Bots Home or
    /// its kept runtime read them.
    func farBotChatIDs(in dashboardID: UUID) -> Set<String> {
        let roster = (combinedDashboardBots[dashboardID]?.bots ?? [])
            + (keptDashboardRuntimes[dashboardID]?.runtime.botRoster ?? [])
        return Set(roster.compactMap(\.canonicalSessionID))
    }

    /// Another combined dashboard's Pulse chat, as its feed read through
    /// its kept connection names it, else its runtime or its last visit here.
    func farPulseHome(in dashboardID: UUID) -> String? {
        combinedDashboardPulse[dashboardID]?.homeChatID
            ?? keptDashboardRuntimes[dashboardID]?.runtime.pulseHomeChatID
            ?? pulseRememberedHomes[dashboardID.uuidString]
    }
}
