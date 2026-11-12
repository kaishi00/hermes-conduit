//
//  AppState+AppLinks.swift
//  Conduit
//
//  Opening a conduit:// link: a chat, a bot's Bot Chat or a call's
//  transcript, on whichever profile it belongs to. Moved out of
//  AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Opening app links

    /// Opens a link Conduit wrote into a chat (a voice call's job link), or
    /// one another app opened Conduit with.
    func openAppLink(_ link: ConduitAppLink) {
        widgetLaunchCoordinator.supersede()
        switch link {
        case .session(let id, let profile, let dashboard):
            // A chat a link places on another dashboard (a Live Activity's
            // card outlives a dashboard switch) goes the way a notification
            // for it does: owner-aware, switching to that saved dashboard
            // first, failing closed for one this device doesn't know.
            if let dashboard {
                guard let owner = UUID(uuidString: dashboard) else {
                    errorMessage = AppLocalization.string("That chat is no longer available.")
                    return
                }
                if owner != activeDashboardID {
                    guard !isVoiceCallInProgress else {
                        showCallRefusal(AppLocalization.string("End the call to open a chat in another workspace."))
                        return
                    }
                    PushNotificationService.shared.routeChatLink(
                        ConduitNotificationTarget(
                            profile: notificationProfileID(profile), sessionId: id, dashboardID: owner, type: nil, isChatLink: true
                        )
                    )
                    return
                }
            }
            // A blank profile names none: the chat opens on the profile in use.
            if let named = notificationProfileID(profile), named != activeProfile {
                Task { @MainActor [weak self] in await self?.routeLinkedSession(id, toProfile: named) }
                return
            }
            // A bot's own chat opens through the bot that owns it, as it
            // does from a link for another profile. A Live Activity's card
            // names the chat's own ids, which outrank a runtime id Hermes
            // may since have given another chat; the link's id still counts
            // when they name no bot (a Bot Chat's link can be its only one).
            let cardIDs = LiveTurnActivities.sessionIDs(linkedTo: id, profile: activeProfile, dashboardID: activeDashboardID?.uuidString)
            if let owner = botOwnership.botProfileName(owningAny: Set(cardIDs)) ?? botOwnership.botProfileName(owningAny: [id]) {
                openLinkedBotChat(owner)
                return
            }
            // Job links and chat-turn links share this route.
            openLinkedSession(id, unavailable: AppLocalization.string("That chat is no longer available."))
        case .bot(let profile):
            openLinkedBotChat(profile)
        case .settings(let page):
            settingsLinkRequest = page
        case .file(let path):
            revealWorkspaceFile(path)
        }
    }

    /// Routes a chat a link puts on another profile. It goes the way a
    /// notification for that chat goes: that route switches profile and
    /// keeps the switch's own sync from opening a different chat. Another
    /// app can send the link, so it only switches to a profile this
    /// dashboard lists, and never while a call would end with the switch.
    func routeLinkedSession(_ id: String, toProfile profile: String) async {
        // A bot's own chat opens through the bot that owns it, whatever
        // profile the link names. That switches nothing, so a call goes on.
        if let owner = botOwnership.botProfileName(owningAny: [id]) {
            openLinkedBotChat(owner)
            return
        }
        guard !isVoiceCallInProgress else {
            showCallRefusal(AppLocalization.string("End the call to open a chat in another profile."))
            return
        }
        if let listed = notificationProfileID(profile), listed != "default", !profiles.contains(listed) {
            // The saved list can predate a new profile (or a first pairing):
            // read it once before saying the chat is gone. A list that
            // can't be read (offline) says nothing about the profile.
            let dashboardID = activeDashboardID
            let read = await readProfiles()
            // A dashboard switched meanwhile is the later choice; the link
            // was read in the one before it.
            guard activeDashboardID == dashboardID else { return }
            guard read else {
                errorMessage = AppLocalization.string(
                    "Conduit isn't connected to Hermes right now. It reconnects on its own, so try again in a moment."
                )
                return
            }
        }
        guard let target = notificationProfileID(profile),
              target == "default" || profiles.contains(target) else {
            errorMessage = AppLocalization.string("That chat is no longer available.")
            return
        }
        PushNotificationService.shared.routeChatLink(
            ConduitNotificationTarget(
                profile: target, sessionId: id, dashboardID: activeDashboardID, type: nil, isChatLink: true
            )
        )
    }

    /// Opens a bot's chat from a link or card Conduit wrote, or from one of
    /// its artifacts. The roster is read once when it doesn't list the bot
    /// yet (just after launch).
    func openLinkedBotChat(_ profile: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Offline, the roster can't say whether the bot is still there.
            guard self.isConnected else {
                self.errorMessage = AppLocalization.string("Connect to Hermes to chat with bots.")
                return
            }
            var bot = Self.linkedBot(named: profile, in: self.botRoster)
            if bot == nil {
                let openBefore = self.activeSessionId
                await self.refreshBotRoster()
                // A chat opened meanwhile is the later choice; it stays.
                guard self.activeSessionId == openBefore else { return }
                bot = Self.linkedBot(named: profile, in: self.botRoster)
            }
            guard let bot else {
                self.errorMessage = Self.missingLinkedBotMessage(for: self.botModePhase)
                return
            }
            // Like a chat link, a bot's chat comes forward over V2's Chats
            // list. True means this open finished and holds the viewport (a
            // superseded one returns false), as for the roster's own taps.
            if await self.openBotChat(for: bot) {
                self.dismissSidebarDrawer()
            }
        }
    }

    /// What a bot link says when the roster doesn't list its bot. Only a
    /// roster that was read says the bot is gone; one that couldn't be
    /// read, or isn't read yet, says nothing about it.
    static func missingLinkedBotMessage(for phase: BotModePhase) -> String {
        switch phase {
        case .available:
            return AppLocalization.string("That chat is no longer available.")
        case .failed(let message):
            return message
        case .gatewayUnsupported:
            return AppLocalization.string("Update Hermes to use Bot Mode.")
        case .idle, .loading:
            return AppLocalization.string("Could not load bots.")
        }
    }

    /// The roster's bot for a profile name a link carries: the exact
    /// spelling first, then one differing only in case (a scope an older
    /// build stored may be case-folded), then a name the bot had before a
    /// rename. A live name always outranks another bot's old one, and an
    /// old name two bots once had opens neither, as in `BotMentions`.
    static func linkedBot(named profile: String, in roster: [BotProfile]) -> BotProfile? {
        let name = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        // Same result as the trimmed-names array this replaces, without
        // building it first (each probe still trims the names it visits;
        // this matcher runs per transcript row render).
        if let index = roster.firstIndex(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == name
        }) ?? roster.firstIndex(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame
        }) {
            return roster[index]
        }
        let renamed = roster.filter { bot in
            bot.previousNames.contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame
            }
        }
        return renamed.count == 1 ? renamed[0] : nil
    }

    /// Opens a session a saved call or chat card linked to. The link can
    /// name a runtime that has since ended (written before Hermes named
    /// the stored session), so it is resolved to the session's current row
    /// first, refreshing the list once when nothing here knows it.
    func openLinkedSession(_ id: String, unavailable: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var target = self.linkedSessionTarget(id)
            // A bot's workstream isn't in the list here (Hermes hides an
            // open one, and this app leaves a resolved one out), so a refresh
            // never finds its row: it only held the open up for seconds
            // (Eric's build 248 test). It resumes by its id straight away.
            if target == nil, !self.isWorkstreamSession(id) {
                let openBefore = self.activeSessionId
                await self.loadSessions(forceRefresh: true)
                // A chat opened meanwhile is the later choice; it stays.
                guard self.activeSessionId == openBefore else { return }
                target = self.linkedSessionTarget(id)
            }
            // Still no row: the stored id learned for a reaped runtime
            // resumes where the runtime id can't.
            let fallback = self.conversationIdentityIndex.durableID(forRuntime: id, profile: self.activeProfile)
            // An error already up (an earlier link's, say) isn't this open's:
            // the tap clears it, so any error after the open is its own.
            self.errorMessage = nil
            let opened = await self.requestOpenSession(target ?? fallback ?? id) { [weak self] sessionWasNotFound in
                guard let self else { return }
                self.errorMessage = Self.linkedSessionFailureMessage(
                    current: self.errorMessage,
                    sessionWasNotFound: sessionWasNotFound,
                    unavailable: unavailable
                )
            }.value
            // From outside a chat (a Live Activity, another app) the chat
            // must come forward: V2 keeps the Chats list over it until the
            // sidebar is let go, as a notification's open does (once the open
            // succeeded, so a dead link leaves the list up with its error).
            // Not while a newer open is still under way; one that already
            // finished has brought its own chat forward anyway.
            if opened, self.explicitSessionOpenRequestID == nil { self.dismissSidebarDrawer() }
        }
    }

    /// What a link's failed open says. Only Hermes' own answer that the
    /// chat isn't there (the resume's 4007, never a history read's 404),
    /// from this open's reconcile, says the link's words,
    /// that the chat is gone; a Kanban worker's refusal keeps its own
    /// explanation. Any other failure (a socket that dropped, a client a
    /// reconnect replaced mid-open, no connection yet) proves nothing about
    /// the chat: it keeps the error it came with, and one that came with
    /// none says to try again, as the retry opens it (#1917).
    static func linkedSessionFailureMessage(
        current: String?,
        sessionWasNotFound: Bool,
        unavailable: String
    ) -> String {
        if sessionWasNotFound { return unavailable }
        return current ?? AppLocalization.string("Couldn't open that chat. Try again.")
    }

    /// The id a linked chat is resumed by. A Live Activity's card from an
    /// older build names the chat's runtime id, which Hermes forgets once
    /// that runtime is reaped (Conduit was away a while): the stored id
    /// learned for it, or another id the card carries, still finds the
    /// chat's row. A row's stored id is resumed over its runtime id, as a
    /// notification's open and a refresh resume it: a list read before the
    /// reaping still names the dead runtime. Nil when nothing here knows
    /// any of the ids (a voice alias with no row still answers).
    private func linkedSessionTarget(_ id: String) -> String? {
        let rows = sessions + cronSessions
        let durable = conversationIdentityIndex.durableID(forRuntime: id, profile: activeProfile)
        // Positively known ids first: the raw id may be a runtime Hermes
        // has since given another chat.
        let candidates = Self.linkedSessionCandidates(
            [durable].compactMap { $0 } + LiveTurnActivities.sessionIDs(linkedTo: id, profile: activeProfile, dashboardID: activeDashboardID?.uuidString) + [id],
            rows: rows
        )
        for candidate in candidates {
            if let target = Self.linkedSessionTarget(candidate, rows: rows, aliases: voiceSessionAliases) {
                // A voice alias can be how the row was found.
                let aliased = voiceSessionAliases.storedID(forRuntime: candidate) ?? candidate
                return Self.linkedResumeID(target, matching: candidate, aliased, rows: rows)
            }
        }
        return nil
    }

    /// `ids` de-duplicated, with any that is a row's durable id (its stored
    /// id, else its own) first: that names one chat for good, while a
    /// card's runtime ids can since belong to another chat.
    static func linkedSessionCandidates(_ ids: [String], rows: [SessionSummary]) -> [String] {
        var seen = Set<String>()
        let unique = ids.filter { !$0.isEmpty && seen.insert($0).inserted }
        let stored = Set(rows.map { ($0.storedSessionId ?? $0.id).trimmingCharacters(in: .whitespacesAndNewlines) })
        return unique.filter { stored.contains($0) } + unique.filter { !stored.contains($0) }
    }

    /// The stored id of the row `target` names that carries one of
    /// `candidates` (two rows can share a runtime id), when it has one;
    /// else `target`.
    static func linkedResumeID(_ target: String, matching candidates: String..., rows: [SessionSummary]) -> String {
        let row = rows.first { row in
            row.id == target && candidates.contains(where: row.nestingIDs.contains)
        }
        guard let stored = row?.storedSessionId?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty else { return target }
        return stored
    }

    /// The id a Live Activity's card opens its chat by: the durable one,
    /// which outlives the runtime id the turn was sent on. A Bot Chat's is
    /// read in its bot's scope, as a refresh reads it: a dashboard row with
    /// the same runtime id says nothing about the Bot Chat. The tap comes
    /// back through `ConduitAppLink(externalURL:)`, so an id that isn't a
    /// plain token keeps the runtime id.
    func liveActivityLinkSessionID(for sessionID: String) -> String {
        let botProfile = botScopeProfile(forSessionIDs: [sessionID], workspaceProfile: activeProfile)
        guard let durable = captureConversationIdentity(for: sessionID, scopeProfile: botProfile)?.durableSessionID,
              ConduitAppLink.isPlainToken(durable) else { return sessionID }
        return durable
    }

    /// The row a linked id opens as: the row that carries it (or the stored
    /// id learned for it) as any of its ids, else the learned stored id.
    /// Nil when nothing knows the id.
    static func linkedSessionTarget(_ id: String, rows: [SessionSummary], aliases: VoiceSessionAliases) -> String? {
        let stored = aliases.storedID(forRuntime: id)
        for candidate in [stored, id].compactMap({ $0 }) {
            if let row = rows.first(where: { $0.storedSessionId == candidate }) ?? rows.first(where: { $0.id == candidate || $0.alternateIds.contains(candidate) }) {
                return row.id
            }
        }
        return stored
    }
}
