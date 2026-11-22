//
//  AppState+FarNotification.swift
//  Conduit
//
//  A push or chat link from another combined dashboard opens in place (no-
//  switch stage 2, the notifications thread): its route runs on that
//  dashboard's own runtime, through its kept connection, as the far Chats
//  row's open does (AppState+FarChat.swift), while the dashboard on screen
//  stays as it is. So does a widget's, Siri's or Spotlight's chat of
//  another combined dashboard (its row in the launcher widget's picker, Open
//  Chat). What opens on another surface keeps the switch until that surface
//  opens in place: a group room's, a Pulse report's, a call's and a Bot
//  Chat's, and a widget's New Chat or Talk.
//  The plan: /mnt/project-files/all-live/no-switch-plan.md.
//

import Foundation

extension AppState {
    /// Opens the chat a push or chat link for another combined dashboard
    /// names in place, as its Chats row does, and lands a wait's push on its
    /// card: `.opened` once its chat opened, waited on so the card's reveal
    /// names the chat that opened, as on screen; `.retry` when the open
    /// failed, to be tried again, its words held for the retries' end;
    /// `.failed` when Hermes refused the chat (gone, or another one), which
    /// says so at once. A card the push carried leaves with an open that
    /// failed, as the switch's does. Nil when it opens through a
    /// switch as before: the dashboard isn't kept connected (or its socket
    /// can't be handed to the chat's profile), its list doesn't hold the
    /// chat, or the push opens a room, its Pulse, a call or a Bot Chat; and
    /// while its bots aren't read yet, since a Bot Chat's push can't be told
    /// from a chat's then, nor its Pulse chat while nothing knows where its
    /// Pulse lives: the switch reads them and opens it in Bots or on Pulse.
    func openFarNotificationInPlace(_ target: ConduitNotificationTarget, in dashboardID: UUID) async -> NotificationOpenOutcome? {
        let requested = target.sessionId
        let attempt = FarNotificationOpenAttempt()
        guard dashboardID != dashboardIDOnScreen, isInCombinedGroup(dashboardID),
              let kept = keptDashboardRuntimes[dashboardID],
              combinedDashboardBots[dashboardID] != nil || !kept.runtime.botRoster.isEmpty,
              // Its Pulse's feed read, or its Pulse chat known some other way.
              combinedDashboardPulse[dashboardID] != nil || !farPulseHomes(in: dashboardID).isEmpty,
              let session = Self.farNotificationChat(
                  target,
                  listed: combinedDashboardChats[dashboardID]?.sessions ?? [],
                  botChats: farBotChatIDs(in: dashboardID),
                  pulseHomes: farPulseHomes(in: dashboardID)
              ),
              let open = startFarChatOpen(session, in: dashboardID, prepare: {
                  // A wait raised while Conduit was away comes on the push:
                  // its card is recorded on that dashboard's runtime before
                  // the open, whose resume merges it in, as on screen.
                  guard let decision = target.decision else { return }
                  let ids = [session.id, requested, target.durableSessionID].compactMap { $0 }.filter { !$0.isEmpty }
                  attempt.cardIDs = requested == session.id ? [requested] : [requested, session.id]
                  recordNotificationDecision(decision, sessionIDs: ids, cacheSessionIDs: attempt.cardIDs)
              }, onFailed: { [weak self] wasRefused in
                  attempt.refused = wasRefused
                  // Runs on that dashboard's runtime, as the card was recorded.
                  guard let self, let decision = target.decision,
                        let key = Self.pendingDecisionEvictionKey(for: decision),
                        let first = attempt.cardIDs.first else { return }
                  self.sessionPresentationCache.removePendingDecision(
                      key: key, profile: self.presentationProfile(for: first), sessionIDs: attempt.cardIDs
                  )
              }) else { return nil }
        // An approval's or a question's push lands on its card, as on screen.
        var reveal: NeedsYouReveal?
        if let type = target.type, NeedsYouStore.notificationTypes.contains(type) {
            reveal = NeedsYouReveal(opening: target.durableSessionID ?? target.sessionId)
            pendingNeedsYouReveal = reveal
        }
        // The open's own answer can be false for an open that a later read
        // of the same chat took over (the chat still came up), so the chat
        // on screen decides too.
        let opened = await open.value || farChatIsShown(session, in: dashboardID)
        if opened {
            discardNotificationRouteFailure(for: target)
            return .opened
        }
        // One that didn't open is tried again: its card's reveal waits for
        // that try rather than land on another chat. A newer tap's reveal
        // stays.
        if let reveal, pendingNeedsYouReveal == reveal { pendingNeedsYouReveal = nil }
        // Superseded by another open: the newer one says what happened.
        guard let refused = attempt.refused else { return .retry }
        let message = Self.linkedSessionFailureMessage(
            current: nil, sessionWasNotFound: refused,
            unavailable: AppLocalization.string("WidgetLaunch.ConversationUnavailable")
        )
        if refused {
            // The same open would hear the same answer.
            discardNotificationRouteFailure(for: target)
            errorMessage = message
            return .failed
        }
        // Said when the retries run out with no chat opened, as the
        // switch's open does (publishNotificationRouteFailure).
        notificationRouteFailure = NotificationRouteFailure(
            target: target, message: message, transition: viewportTransitionGeneration, roomEpoch: groupRoomEpoch
        )
        return .retry
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
        pulseHomes: Set<String>
    ) -> SessionSummary? {
        guard target.call == nil, target.roomID == nil else { return nil }
        let ids = Set([target.sessionId, target.durableSessionID].compactMap { $0 }.filter { !$0.isEmpty })
        guard !ids.isEmpty, ids.isDisjoint(with: botChats) else { return nil }
        guard ids.isDisjoint(with: pulseHomes) else { return nil }
        let profile = target.profile.flatMap { $0.isEmpty ? nil : $0 }
        // The durable id first, as the switch's route resolves it.
        func match(_ candidates: Set<String>) -> SessionSummary? {
            listed.first { row in
                !candidates.isDisjoint(with: SessionContentSearch.identities(of: row))
                    && profile.map { profilesMatch(row.profile ?? "default", $0) } ?? true
            }
        }
        let durable = Set([target.durableSessionID].compactMap { $0 }.filter { !$0.isEmpty })
        guard let row = match(durable) ?? match(ids),
              Set(SessionContentSearch.identities(of: row)).isDisjoint(with: pulseHomes) else { return nil }
        return row
    }

    /// Another combined dashboard's Bot Chats, by its bots as Bots Home or
    /// its kept runtime read them.
    func farBotChatIDs(in dashboardID: UUID) -> Set<String> {
        let roster = (combinedDashboardBots[dashboardID]?.bots ?? [])
            + (keptDashboardRuntimes[dashboardID]?.runtime.botRoster ?? [])
        return Set(roster.compactMap(\.canonicalSessionID))
    }

    /// Another combined dashboard's Pulse chat, as any of its feed read
    /// through its kept connection, its runtime or its last visit here names
    /// it: one of them can be behind the others.
    func farPulseHomes(in dashboardID: UUID) -> Set<String> {
        Set([
            combinedDashboardPulse[dashboardID]?.homeChatID,
            keptDashboardRuntimes[dashboardID]?.runtime.pulseHomeChatID,
            pulseRememberedHomes[dashboardID.uuidString],
        ].compactMap { $0 }.filter { !$0.isEmpty })
    }

    /// Whether another dashboard's chat is the one on screen, opened in place.
    func farChatIsShown(_ session: SessionSummary, in dashboardID: UUID) -> Bool {
        guard farChatDashboardID == dashboardID, let active = activeSessionId, !active.isEmpty else { return false }
        return SessionContentSearch.identities(of: session).contains(active)
    }

    /// Opens a widget's or Siri's chat of another combined dashboard in
    /// place, on that dashboard's runtime, as its Chats row does: the chat
    /// its kept read lists for that profile. False when the launch goes on
    /// as before (through a switch, or its refusal during a call): a call
    /// going on, not a chat's resume, the dashboard on
    /// screen's, not kept connected, its bots not read yet, not listed, its
    /// Pulse chat, or a Bot Chat (startFarChatOpen's isFarBotChat). An open
    /// that fails later shows the launch's error.
    func openWidgetChatInPlace(_ link: WidgetLaunchLink) -> Bool {
        // During a call a widget's chat refuses, as the switch's launch
        // does (A switch during a call): end the call first.
        guard !isVoiceCallInProgress,
              link.action == .resume, let workspace = link.workspace,
              let reference = link.reference, reference.kind == .dashboard,
              workspace.dashboardID != dashboardIDOnScreen,
              let kept = keptDashboardRuntimes[workspace.dashboardID],
              // Its bots read, so a Bot Chat is told from a chat, as a push's.
              combinedDashboardBots[workspace.dashboardID] != nil || !kept.runtime.botRoster.isEmpty,
              let session = combinedDashboardChats[workspace.dashboardID]?.sessions.first(where: {
                  profilesMatch($0.profile ?? "default", workspace.profile)
                      && SessionContentSearch.identities(of: $0).contains(reference.sessionID)
              }),
              // Its Pulse chat opens through a switch, on the Pulse screen.
              Set(SessionContentSearch.identities(of: session))
                  .isDisjoint(with: farPulseHomes(in: workspace.dashboardID)) else { return false }
        // An open that fails says so, as the switch's launch does: the chat
        // gone there since its list was read, or its connection lost.
        let unavailable = AppLocalization.string("WidgetLaunch.ConversationUnavailable")
        let open = startFarChatOpen(session, in: workspace.dashboardID, onFailure: { [weak self] sessionWasNotFound in
            guard let self else { return }
            self.errorMessage = Self.linkedSessionFailureMessage(
                current: self.errorMessage, sessionWasNotFound: sessionWasNotFound, unavailable: unavailable
            )
        })
        if open != nil { errorMessage = nil }
        return open != nil
    }
}

/// What a far push's open learned as it went: the ids its card was recorded
/// under, and, once it failed, whether Hermes refused the chat.
@MainActor
private final class FarNotificationOpenAttempt {
    var cardIDs: [String] = []
    var refused: Bool?
}
