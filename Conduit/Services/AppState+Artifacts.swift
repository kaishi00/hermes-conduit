//
//  AppState+Artifacts.swift
//  Conduit
//
//  The Artifacts screens: what a profile's chats produced, listed by the
//  host's notifier plugin, opened in the viewers chats already use, and
//  "Show in chat", which scrolls the chat to the message it came from.
//

import Foundation

/// A message to scroll to once its chat's transcript has it.
struct ArtifactReveal: Equatable {
    /// Hermes' `messages.id`.
    let messageID: Int
    /// The chat being opened for it; nil when it's in the open chat. Until
    /// that chat is the active one, the transcript is still the old chat's.
    let opening: String?
    let expires: Date

    init(messageID: Int, opening: String? = nil, now: Date = Date()) {
        self.messageID = messageID
        self.opening = opening
        // A chat that takes longer to open (or never shows the row, an old
        // part of a long history) doesn't jump later, out of nowhere.
        self.expires = now.addingTimeInterval(20)
    }

    /// The row to show: the message itself, else the last one before it (a
    /// tool call is split off its message and keeps no id of its own).
    static func rowID(for messageID: Int, in messages: [ChatMessage]) -> String? {
        var before: ChatMessage?
        for message in messages {
            guard let rowId = message.rowId else { continue }
            if rowId == messageID { return message.id }
            if rowId < messageID, rowId >= (before?.rowId ?? Int.min) { before = message }
        }
        return before?.id
    }
}

extension AppState {
    /// Whether the host's notifier plugin lists artifacts.
    var supportsArtifacts: Bool {
        notifierPlugin.reports(ArtifactsClient.capability)
    }

    var artifactsClient: ArtifactsClient {
        ArtifactsClient(request: { [weak self] path in
            guard let bridge = self?.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
            // A long history takes the host a moment to read.
            return try await bridge.requestJSON(path: path, timeoutMilliseconds: 30_000)
        })
    }

    /// Every id the open chat is known by, for its own Artifacts sheet.
    /// Empty when no chat with a row of its own is open (a room, a new chat).
    var activeChatArtifactSessionIDs: [String] {
        guard let session = activeChatSessionSummary else { return [] }
        let seeds = [session.id, session.storedSessionId].compactMap { $0 } + session.alternateIds
        return Array(chatOwnSessionIDs(for: session.id).union(seeds)).sorted()
    }

    /// The stores an Artifacts list reads. A chat's own list reads the
    /// chat's store: a Bot Chat is kept in its bot's profile. The Artifacts
    /// page reads the profile in use (each profile All shows, while it's
    /// on) and every other bot's Bot Chat.
    func artifactSources(for scope: ArtifactScope) -> [ArtifactSource] {
        switch scope {
        case .chat(let ids):
            guard let bot = botStoreProfile(forSessionIDs: ids) else {
                return [ArtifactSource(profile: activeProfile, sessionIDs: ids)]
            }
            return [ArtifactSource(profile: bot, sessionIDs: ids, label: botLabel(bot), isBotChat: true)]
        case .profile:
            // The profile in use is read even when All leaves it out.
            var listed = [activeProfile]
            if isAllProfilesChatsOn {
                listed += allProfilesIncluded.filter { !Self.profilesMatch($0, activeProfile) }
            }
            var sources = listed.map { profile in
                // A profile read whole that is also a bot's still names its
                // Bot Chat's rows after the bot.
                let bot = botRoster.first { Self.profilesMatch($0.name, profile) }
                return ArtifactSource(profile: profile, sessionIDs: [],
                                      label: Self.profilesMatch(profile, activeProfile) ? nil : profileDisplayName(profile),
                                      botChatIDs: bot.map(Self.botChatIDs) ?? [], botLabel: bot?.displayLabel)
            }
            // A bot whose whole profile is read already has its chat listed.
            for bot in botRoster where !listed.contains(where: { Self.profilesMatch($0, bot.name) }) {
                let ids = Self.botChatIDs(bot)
                guard !ids.isEmpty else { continue }
                sources.append(ArtifactSource(profile: bot.name, sessionIDs: ids, label: bot.displayLabel,
                                              isBotChat: true))
            }
            return sources
        }
    }

    /// A bot's Bot Chat by its registry id and lineage tip.
    private static func botChatIDs(_ bot: BotProfile) -> [String] {
        Set([bot.canonicalSession?.id, bot.canonicalSession?.resolvedID].compactMap { id -> String? in
            let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }).sorted()
    }

    private func botLabel(_ profile: String) -> String {
        botRoster.first(where: { $0.name == profile })?.displayLabel ?? profile
    }

    /// Whether the transcript on screen is the chat a reveal waits for.
    func isShowingChat(for reveal: ArtifactReveal) -> Bool {
        guard let opening = reveal.opening else { return true }
        guard let active = activeSessionId, !active.isEmpty else { return false }
        return active == opening || chatOwnSessionIDs(for: active).contains(opening)
    }

    /// Opens the artifact's chat (unless it's the open one) and scrolls to
    /// the message it came from.
    func showArtifactInChat(_ item: ArtifactItem, chatIsOpen: Bool) {
        // Another profile's chat doesn't open during a call (it says so),
        // so nothing waits to scroll.
        let refused = !chatIsOpen && item.otherProfile != nil && !item.isBotChat && isVoiceCallInProgress
        if !refused {
            pendingArtifactReveal = ArtifactReveal(messageID: item.messageID, opening: chatIsOpen ? nil : item.sessionID)
        }
        guard !chatIsOpen else { return }
        dismissSidebarDrawer()
        if item.isBotChat {
            // A Bot Chat opens the way Bots opens it, under the bot's profile.
            openLinkedBotChat(item.otherProfile ?? activeProfile)
        } else if let profile = item.otherProfile {
            // Another profile's chat opens the way All opens it.
            openOtherProfileChat(item.sessionID, inProfile: profile)
        } else {
            requestOpenSession(item.sessionID)
        }
    }
}
