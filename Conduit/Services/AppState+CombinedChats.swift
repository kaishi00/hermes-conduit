//
//  AppState+CombinedChats.swift
//  Conduit
//
//  All-live stage 4b: the Chats list shows every combined dashboard's
//  chats. Each other dashboard's newest are read through its kept
//  connection, every one of its profiles, and merged into the list by
//  last activity, each row marked with its dashboard's badge. A tap
//  switches to that dashboard (through the kept connection, no sign-in)
//  and opens the chat, as a notification from it does.
//

import Foundation

/// Another combined dashboard's newest chats, with what they were read
/// through and when.
struct CombinedDashboardChats: Equatable {
    let bridge: ObjectIdentifier
    /// Every profile read there, in that dashboard's order. Each row
    /// names its own.
    let profiles: [String]
    let sessions: [SessionSummary]
    let at: Date
    /// When a switch seeded it from the list on screen (`at` is then long
    /// ago, so the next pass reads anew): a read started before this
    /// can't overwrite it (#2644 review).
    var seededAt: Date? = nil
}

extension AppState {
    /// How many of another dashboard's newest chats the list shows.
    static let combinedDashboardChatsLimit = 50

    /// How long another dashboard's chats stand before the poll reads them
    /// again. A pull on the list reads them at once.
    static let combinedDashboardChatsMaxAge: TimeInterval = 60

    /// Reads each other combined dashboard's newest chats, every one of its
    /// profiles (Eric, 2026-11-16: All combines all of it), through its
    /// kept connection. Quiet on failure: a profile that can't be read
    /// keeps what it showed, and a dashboard let go or opened says nothing
    /// more.
    func readOtherCombinedDashboardsChats(force: Bool = false, now: Date = Date()) async {
        let kept = keptDashboardRuntimes.filter { isInCombinedGroup($0.key) && $0.key != activeDashboardID }
        // One that dropped by itself keeps its last list until it's back;
        // out of the group or opened here, it goes.
        let gone = combinedDashboardChats.keys.filter { !isInCombinedGroup($0) || $0 == activeDashboardID }
        if !gone.isEmpty { combinedDashboardChats = combinedDashboardChats.filter { !gone.contains($0.key) } }
        for (id, runtime) in kept.sorted(by: { $0.value.keptAt < $1.value.keptAt }) {
            guard isSceneActive else { return }
            let bridge = ObjectIdentifier(runtime.bridge)
            // No profile list to be had (a reconnect lost it and the read
            // failed): the profiles it listed last, so none of them drops.
            let profiles = await keptDashboardProfileNames(id, runtime)
                ?? combinedDashboardChats[id]?.profiles
                ?? [rememberedActiveProfile(for: id) ?? "default"]
            guard keptDashboardRuntimes[id]?.bridge === runtime.bridge else { continue }
            if !force, let last = combinedDashboardChats[id], last.bridge == bridge, last.profiles == profiles,
               now.timeIntervalSince(last.at) < Self.combinedDashboardChatsMaxAge { continue }
            var sessions: [SessionSummary] = []
            var answered = false
            var stale = false
            for profile in profiles {
                guard isSceneActive else { return }
                let path = profileSessionsPath(profile, limit: Self.combinedDashboardChatsLimit)
                let response = try? await readKeptDashboardJSON(runtime.bridge, path: path)
                // Let go, opened, or out of the group while the read was
                // out, or a read started later (or a switch's seed) already
                // stored its answer: this one is stale.
                guard keptDashboardRuntimes[id]?.bridge === runtime.bridge, activeDashboardID != id,
                      isInCombinedGroup(id),
                      !(combinedDashboardChats[id].map { $0.at > now || ($0.seededAt.map { $0 > now } ?? false) } ?? false) else {
                    stale = true
                    break
                }
                // An answer with no list (an error body) is a failed read:
                // that profile keeps what it shows now, the list kept
                // through a reconnect or an overlapping read's included.
                guard let batch = response?["sessions"] as? [Any] else {
                    let kept = combinedDashboardChats[id]?.sessions.filter { profilesMatch($0.profile ?? "", profile) } ?? []
                    sessions = V2FilterSelection.mergedByRecency(sessions, kept)
                    continue
                }
                answered = true
                let rows = Self.dashboardOwnedSessions(batch, profile: profile).map { row -> SessionSummary in
                    var row = row
                    row.combinedDashboardID = id
                    return row
                }
                sessions = V2FilterSelection.mergedByRecency(sessions, rows)
            }
            guard !stale, answered else { continue }
            combinedDashboardChats[id] = CombinedDashboardChats(
                bridge: bridge,
                profiles: profiles,
                sessions: sessions,
                at: now
            )
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
            let fresh = chats.sessions.filter { row in
                guard !taken.contains(row.id) else { return false }
                guard let home, profilesMatch(row.profile ?? "", home.1 ?? row.profile ?? "") else { return true }
                return !row.nestingIDs.contains(home.0)
            }
            taken.formUnion(fresh.map(\.id))
            merged = V2FilterSelection.mergedByRecency(merged, fresh)
        }
        return merged
    }

    /// The other combined dashboards' chats the Chats list shows: only in
    /// All, since one profile's list holds that profile's chats alone (Eric,
    /// 2026-11-16). Grouped by profile, each dashboard's get a section of
    /// their own.
    func chatListCombinedChats(excluding listed: Set<String>) -> [SessionSummary] {
        isAllProfilesChatsOn ? otherCombinedDashboardsChats(excluding: listed) : []
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
    /// (through its kept connection), then the chat in its own profile, as
    /// a notification from that dashboard opens.
    func openCombinedChat(_ session: SessionSummary, in dashboardID: UUID) {
        // The notification path refuses during a call too; saying so here
        // keeps it to the tap.
        guard !refusesCombinedSwitchDuringCall() else { return }
        PushNotificationService.shared.routeChatLink(combinedChatTarget(session, in: dashboardID))
    }

    /// Where another combined dashboard's row opens: its chat, in its own
    /// profile, on its dashboard.
    func combinedChatTarget(_ session: SessionSummary, in dashboardID: UUID) -> ConduitNotificationTarget {
        ConduitNotificationTarget(
            profile: session.profile ?? "default",
            sessionId: session.id,
            dashboardID: dashboardID,
            type: nil,
            isChatLink: true
        )
    }
}

/// One picture of Chats' profile strip in a combined group: a profile of
/// the dashboard on screen, or of another combined dashboard.
struct CombinedProfileChip: Identifiable, Equatable {
    /// The dashboard whose profile it is; nil only outside a group.
    let dashboardID: UUID?
    let profile: String
    /// Another dashboard's: a tap switches there.
    let isOther: Bool

    /// Its key in the group's one order (Bots Home's): a profile and its
    /// bot are the same thing in Hermes.
    var id: String { CombinedBotsHomeOrder.key(dashboardID, profile) }
}

extension AppState {
    /// Chats' profile strip in a combined group: every dashboard's profiles
    /// in one row, in the order the person set on Bots Home (Eric,
    /// 2026-11-16: "a row of portraits on top like one dashboard"). Until
    /// arranged, each dashboard's in Saved Dashboards order, this one's
    /// (`own`) in its own order. Outside a group, or with no other
    /// dashboard's profiles known yet, just `own`.
    func combinedProfileStrip(own: [String]) -> [CombinedProfileChip] {
        let mine = own.map { CombinedProfileChip(dashboardID: activeDashboardID, profile: $0, isOther: false) }
        guard isInCombinedGroup(activeDashboardID) else { return mine }
        var chips: [CombinedProfileChip] = []
        var others = false
        var mineListed = false
        for dashboard in savedDashboardRegistry.dashboards {
            if dashboard.id == activeDashboardID {
                chips += mine
                mineListed = true
            } else if isInCombinedGroup(dashboard.id), let profiles = otherCombinedDashboardProfiles(dashboard.id) {
                chips += profiles.map { CombinedProfileChip(dashboardID: dashboard.id, profile: $0, isOther: true) }
                others = true
            }
        }
        guard others else { return mine }
        if !mineListed { chips = mine + chips }
        // One Hermes saved at two addresses: its profile shows once, as
        // Bots Home shows its bot, at the place its copies were saved at.
        // This dashboard's copy is always the one kept.
        let twins = combinedBotsHomeTwins
        let shownKeys = Set(chips.map(\.id))
        let copies = Set(twins.filter { shownKeys.contains($0.key) }.values.joined())
        chips.removeAll { copies.contains($0.id) }
        let saved = CombinedBotsHomeOrder.handingOn(combinedBotsHomeOrder, twins: twins)
        return CombinedBotsHomeOrder.ordered(chips, saved: saved, key: \.id)
    }

    /// Another combined dashboard's profiles as last read: with its chats,
    /// else with its waits. They stand through a dropped connection, as its
    /// chats do.
    func otherCombinedDashboardProfiles(_ id: UUID) -> [String]? {
        let profiles = combinedDashboardChats[id]?.profiles ?? keptDashboardProfiles[id]?.profiles
        return profiles.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The picture another combined dashboard's profile has on this phone.
    func otherCombinedDashboardProfileAvatar(_ profile: String, in id: UUID) -> URL? {
        profileAppearanceStore.loadAvatarURLs(dashboardID: id)[profile]
    }

    /// A strip pick of another combined dashboard's profile: the switch
    /// there through its kept connection, the strip staying as it was (the
    /// group's one order), its list no longer All. True once it's on screen;
    /// the caller then picks the profile as the strip does on one dashboard.
    func switchForCombinedProfile(in dashboardID: UUID, profile: String? = nil) async -> Bool {
        guard !refusesCombinedSwitchDuringCall() else { return false }
        // The switch resumes on the picked profile, not first on the one
        // it last used there (Eric, 2026-11-16).
        if let profile { rememberActiveProfile(profile, for: dashboardID) }
        await switchDashboard(to: dashboardID)
        guard activeDashboardID == dashboardID else { return false }
        setAllProfilesChatsOn(false)
        return true
    }
}
