//
//  AppState+LiveStatusEveryProfile.swift
//  Conduit
//
//  Live status for every bot (the multi-instance plan's first quick win):
//  Running and waits for the profiles other than the one in use, wherever
//  their chats or bots show (All, a project's page, Bots Home). Hermes'
//  session authority lists only the profile `session.active_list` names
//  (gateway/session_active_list.py, Hermes 0.22.5), so the profile in use's
//  read never had theirs: each one on screen is read by name beside it.
//

import Foundation

/// Something on screen that shows other profiles' live status, and which.
struct LiveStatusAsk: Equatable {
    let token: UUID
    let profiles: [String]
}

extension AppState {
    /// Bots Home's registry read while it shows, apart from the Chats
    /// list's poll, which stops there: its portraits say what each bot's
    /// chats do. A wait shows at once by its push (Needs you reads then).
    static let botsHomeLiveStatusInterval: TimeInterval = 10

    /// While something on screen shows `profiles`' rows or bots, their
    /// registries are read with the profile in use's. Returns the token
    /// that ends it.
    @discardableResult
    func askLiveStatus(_ key: String, profiles: [String]) -> UUID {
        let token = UUID()
        liveStatusAsks[key] = LiveStatusAsk(token: token, profiles: profiles)
        return token
    }

    /// It no longer shows. A newer ask under the same key stays: SwiftUI
    /// can end a view's old task after starting its new one.
    func endLiveStatusAsk(_ key: String, token: UUID) {
        guard liveStatusAsks[key]?.token == token else { return }
        liveStatusAsks[key] = nil
    }

    /// The other profiles whose registries are read: those All lists while
    /// it's on, and those a project's page or Bots Home shows, each once,
    /// never the profile in use (its own read covers it).
    var liveStatusOtherProfiles: [String] {
        var asked = isAllProfilesChatsOn ? allProfilesIncluded : []
        for key in liveStatusAsks.keys.sorted() { asked += liveStatusAsks[key]?.profiles ?? [] }
        var seen = Set<String>([OtherProfilesLiveStatus.key(activeProfile)])
        return asked.filter { seen.insert(OtherProfilesLiveStatus.key($0)).inserted }
    }

    /// Starts each other profile's read; `finishOtherProfilesLiveStatusReads`
    /// keeps what they answer.
    func startOtherProfilesLiveStatusReads(_ client: HermesClient) -> [(profile: String, read: Task<[LiveSessionStatus], Error>)] {
        let probe = chatResumeLifecycleOperations.probeProfileActiveSessions
        return liveStatusOtherProfiles.map { profile in
            (profile: profile, read: Task { @MainActor in
                if let probe { return try await probe(client, profile) }
                return try await client.activeSessions(inProfile: profile)
            })
        }
    }

    /// Keeps each other profile's registry as read. A failed read (a
    /// profile the gateway doesn't serve, a moment offline) keeps what it
    /// last showed; a profile nothing asks for any more goes.
    func finishOtherProfilesLiveStatusReads(
        _ reads: [(profile: String, read: Task<[LiveSessionStatus], Error>)],
        client: HermesClient
    ) async {
        var next = otherProfilesLiveStatus
        let dashboardID = activeDashboardID?.uuidString
        var recheck = false
        for (profile, read) in reads {
            guard let rows = try? await read.value else { continue }
            // A connection replaced while the reads were out: not this one's.
            guard self.client === client else { return }
            next.set(SessionLiveStatusIndex(rows: rows), for: profile, client: ObjectIdentifier(client))
            // A turn's Lock Screen progress in that profile (a Bot Chat's)
            // settles from its own registry, as the profile in use's does.
            if liveTurnActivitiesRegistrySnapshot(Self.liveTurnSessionIDs(rows), profile, dashboardID) { recheck = true }
        }
        next.keep(liveStatusOtherProfiles)
        // Assigned only on a change: every publish redraws the lists.
        if next != otherProfilesLiveStatus { otherProfilesLiveStatus = next }
        if recheck { scheduleLiveTurnRegistryRecheck() }
    }

    /// Another profile's row, from its profile's registry and the plugin's
    /// list of what waits on the user. `fallback` (the profile in use's
    /// registry, which on the legacy dashboard lists every profile's) stands
    /// until its own profile was read; after that its own read decides, so
    /// a chat of the same id running in another profile (a profile copied
    /// with its chats) no longer lights it.
    func otherProfileLiveStatus(_ session: SessionSummary, fallback: SessionLiveStatus?) -> SessionLiveStatus? {
        guard isConnected else { return nil }
        let profile = rowProfile(session)
        let ids = Set([session.id, session.storedSessionId, session.lineageRootId].compactMap { $0 } + session.alternateIds)
        if needsYou.items.contains(where: {
            $0.roomID == nil && Self.profilesMatch($0.profile, profile) && !ids.isDisjoint(with: $0.sessionIDs)
        }) {
            return .needsInput
        }
        guard let index = otherProfilesLiveStatus.index(for: profile, client: client.map { ObjectIdentifier($0) }) else {
            return fallback
        }
        return index.status(for: session)
    }

    /// The other profiles' busy rows among `listed`, as the Chats list's
    /// poll keys its own (a change brings it back to 4 s), and whether one
    /// runs a turn.
    func otherProfilesListedLiveRows(_ listed: Set<String>) -> (keys: Set<String>, running: Bool) {
        var keys = Set<String>()
        var running = false
        for profile in liveStatusOtherProfiles {
            guard let index = otherProfilesLiveStatus.index(for: profile, client: client.map { ObjectIdentifier($0) }) else { continue }
            for row in index.busyRows where !row.ids.isDisjoint(with: listed) {
                keys.insert("\(OtherProfilesLiveStatus.key(profile))|\(row.ids.sorted().joined(separator: "|"))|\(row.status)")
                if row.status == .working { running = true }
            }
        }
        return (keys, running)
    }

    /// What a bot's chats do now: how many run, from its profile's registry
    /// (the profile in use's own read, or its read by name), and how many
    /// wait on the user, from the same and the plugin's list of waits.
    /// Its workstreams are left out: their own list counts them. Nil while
    /// nothing is known (not read yet, or a legacy registry that lists
    /// every profile's chats under each).
    func botLiveChats(_ bot: String, leavingOut workstreams: Set<String> = []) -> BotLiveChats? {
        guard isConnected else { return nil }
        let index: SessionLiveStatusIndex?
        if Self.profilesMatch(bot, activeProfile) {
            index = liveSessionStatusProfile == activeProfile ? liveSessionStatusIndex : nil
        } else {
            index = otherProfilesLiveStatus.index(for: bot, client: client.map { ObjectIdentifier($0) })
        }
        let waits = needsYou.items.filter {
            $0.roomID == nil && Self.profilesMatch($0.profile, bot) && Set($0.sessionIDs).isDisjoint(with: workstreams)
        }.count
        guard var counts = index?.counts(leavingOut: workstreams) else {
            return waits > 0 ? BotLiveChats(working: 0, waiting: waits) : nil
        }
        // The registry's waiting chats and the plugin's waits are the same
        // ones seen twice: the larger count stands.
        counts.waiting = max(counts.waiting, waits)
        return counts
    }

    /// The newest wait in a bot's chats, which its portrait's "needs you"
    /// opens when none of its workstreams waits.
    func newestBotChatWait(_ bot: String) -> NeedsYouItem? {
        needsYou.items.first { $0.roomID == nil && Self.profilesMatch($0.profile, bot) }
    }

    /// Bots Home's registry reads while it shows: every bot's, the profile
    /// in use's included, every `botsHomeLiveStatusInterval` seconds
    /// (stretched in Low Power and Low Data Mode). The view runs it and
    /// ends it with its task.
    func runBotsHomeLiveStatus(bots: [String]) async {
        let token = askLiveStatus("bots", profiles: bots)
        defer { endLiveStatusAsk("bots", token: token) }
        while !Task.isCancelled {
            await refreshLiveSessionStatuses()
            try? await Task.sleep(for: .seconds(PollCadence.stretched(Self.botsHomeLiveStatusInterval, by: deviceConditions())))
        }
    }
}
