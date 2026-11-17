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

    /// The client a store's list is read with: another combined
    /// dashboard's through its kept connection, while it has one.
    func artifactsClient(for source: ArtifactSource) -> ArtifactsClient {
        guard let id = source.dashboardID else { return artifactsClient }
        return ArtifactsClient(request: { [weak self] path in
            guard let self, id != self.activeDashboardID,
                  let bridge = self.keptDashboardRuntimes[id]?.bridge else { throw DashboardTicketBridgeError.notReady }
            if let reader = self.keptDashboardJSONReader { return try await reader(bridge, path) }
            return try await bridge.requestJSON(path: path, timeoutMilliseconds: 30_000)
        })
    }

    /// Where another combined dashboard's artifact files are read: its kept
    /// connection, as that profile.
    func keptGatewayMediaResolver(dashboardID: UUID, profile: String) -> GatewayMediaDataURLResolver {
        let key = "\(dashboardID.uuidString)|\(profile)"
        if let cached = keptGatewayMediaResolvers[key] { return cached }
        let resolver = GatewayMediaDataURLResolver(appState: self, profile: profile, keptDashboardID: dashboardID)
        keptGatewayMediaResolvers[key] = resolver
        return resolver
    }

    /// The other combined dashboards whose artifacts All lists: kept
    /// connected, in Saved Dashboards order, one Hermes saved twice once
    /// (as Bots Home shows its bots), each with its profiles as last read.
    var otherCombinedArtifactDashboards: [(id: UUID, name: String, profiles: [String])] {
        guard isInCombinedGroup(activeDashboardID) else { return [] }
        // A copy is left out only for a twin that's listed itself: on
        // screen, or kept connected. With that one's connection dropped,
        // this copy lists the Hermes (#2644 review).
        let listable = Set(savedDashboardRegistry.dashboards.map(\.id).filter {
            $0 == activeDashboardID || keptDashboardRuntimes[$0] != nil
        }.map { "\($0.uuidString)|" })
        let copies = Set(combinedBotsHomeTwins.filter { key, _ in
            listable.contains { key.hasPrefix($0) }
        }.values.joined())
        return savedDashboardRegistry.dashboards.compactMap { dashboard in
            guard dashboard.id != activeDashboardID, isInCombinedGroup(dashboard.id),
                  keptDashboardRuntimes[dashboard.id] != nil else { return nil }
            // A copy of a Hermes another dashboard shows already.
            let prefix = "\(dashboard.id.uuidString)|"
            guard !copies.contains(where: { $0.hasPrefix(prefix) }) else { return nil }
            let name = dashboard.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return (dashboard.id, name, otherCombinedDashboardProfiles(dashboard.id) ?? ["default"])
        }
    }

    /// Whether the host's notifier plugin keeps saved artifacts (plugin
    /// 0.177+, issue 2467).
    var supportsArtifactPins: Bool {
        notifierPlugin.reports(ArtifactPinsClient.capability)
    }

    var artifactPinsClient: ArtifactPinsClient {
        ArtifactPinsClient(request: { [weak self] path, method, body in
            guard let bridge = self?.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
            // Saving a file copies it on the host, which takes a moment for
            // a large one.
            return try await bridge.requestJSON(path: path, method: method, body: body,
                                                timeoutMilliseconds: method == "POST" ? 90_000 : 20_000)
        })
    }

    /// Every id the open chat is known by, for its own Artifacts sheet, its
    /// checklists' ticks and its cards' taps. Empty when no chat with ids of
    /// its own is open (a room, a new chat). A Bot Chat has no row in the
    /// workspace's list: it goes by its own ids and the roster's registry id
    /// and lineage tip for it. Nor does a workstream's chat (left out of
    /// the list for its bot): it goes by its own ids, the durable one its
    /// bot's profile confirmed and the plugin's id for it (issue 2520).
    var activeChatArtifactSessionIDs: [String] {
        if let session = activeChatSessionSummary {
            let seeds = [session.id, session.storedSessionId].compactMap { $0 } + session.alternateIds
            return Array(chatOwnSessionIDs(for: session.id).union(seeds)).sorted()
        }
        guard activeRoomSurface == nil, offlineChatPresentation == nil, !showsPendingNewChat,
              let sessionID = activeSessionId, !sessionID.isEmpty else { return [] }
        guard let profile = botChatStoreProfile(forSessionID: sessionID) else {
            return activeWorkstreamChatIDs(sessionID)
        }
        // The open id is the runtime one; its store keeps the durable id,
        // confirmed under the bot's profile even when the registry hasn't
        // noted the chat yet (after a relaunch).
        var ids = chatOwnSessionIDs(for: sessionID)
        if let durable = ChatScrollIdentityNormalization.sessionID(
            confirmedDurableSessionID(forRuntime: sessionID, profile: profile)
        ) {
            ids.insert(durable)
        }
        if let bot = botRoster.first(where: { Self.profilesMatch($0.name, profile) }) {
            ids.formUnion(Self.botChatIDs(bot))
        }
        return ids.sorted()
    }

    /// A workstream's chat by its ids, when it's open on its bot's profile,
    /// the store its checklists, taps and files are kept in; else none.
    private func activeWorkstreamChatIDs(_ sessionID: String) -> [String] {
        var ids = chatOwnSessionIDs(for: sessionID).union([sessionID])
        guard let profile = botWork.workstreamProfile(forSession: ids),
              Self.profilesMatch(profile, activeProfile) else { return [] }
        if let durable = ChatScrollIdentityNormalization.sessionID(
            confirmedDurableSessionID(forRuntime: sessionID, profile: profile)
        ) {
            ids.insert(durable)
        }
        if let item = botWork.workstream(forSession: ids)?.item, !item.sessionID.isEmpty {
            ids.insert(item.sessionID)
        }
        return ids.sorted()
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
        case .bot(let name):
            // The bot's whole profile, as `.profile` reads the one in use.
            let bot = botRoster.first { Self.profilesMatch($0.name, name) }
            let inUse = Self.profilesMatch(name, activeProfile)
            return [ArtifactSource(profile: name, sessionIDs: [],
                                   label: inUse ? nil : (bot?.displayLabel ?? profileDisplayName(name)),
                                   botChatIDs: bot.map(Self.botChatIDs) ?? [], botLabel: bot?.displayLabel)]
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
            // The page reaches every combined dashboard (Eric, 2026-11-16),
            // with or without All: each profile of each other one, read
            // through its kept connection, its rows named by that dashboard
            // and profile, a chip per dashboard to narrow to one.
            for dashboard in otherCombinedArtifactDashboards {
                for profile in dashboard.profiles {
                    let label = profile == "default" ? dashboard.name : "\(dashboard.name) · \(profile)"
                    sources.append(ArtifactSource(profile: profile, sessionIDs: [], label: label,
                                                  dashboardID: dashboard.id))
                }
            }
            return sources
        }
    }

    /// The bot whose Bot Chat the open id is, by the store that keeps it or
    /// the roster's chat it was rebound to; nil for any other chat. Its ids
    /// and the store its ticks and taps go to both ask here, so they agree.
    func botChatStoreProfile(forSessionID sessionID: String) -> String? {
        botStoreProfile(forSessionIDs: [sessionID]) ?? reboundBotChatProfile(sessionID)
    }

    /// The bot whose Bot Chat a runtime id was rebound to (a shortcut
    /// reopening a dead runtime records only its durable id).
    private func reboundBotChatProfile(_ sessionID: String) -> String? {
        botRoster.first { bot in
            guard let durable = confirmedDurableSessionID(forRuntime: sessionID, profile: bot.name) else { return false }
            return Self.botChatIDs(bot).contains(durable)
        }?.name
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
        let refused = !chatIsOpen && item.otherProfile != nil && !item.isBotChat && isCallEndingProfileSwitch
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
