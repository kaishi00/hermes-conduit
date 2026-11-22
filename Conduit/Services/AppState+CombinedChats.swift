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
    /// Its cron runs' ids, read only to tell one Hermes saved twice (issue
    /// 2761): the dashboard on screen counts its own cron rows, so this one's
    /// count too. Read once per connection and again every half hour, as a
    /// cron run's id never changes.
    var cronIDs: Set<String> = []
    var cronAt: Date? = nil
}

extension AppState {
    /// How many of another dashboard's newest chats the list shows.
    static let combinedDashboardChatsLimit = 50

    /// How long another dashboard's chats stand before the poll reads them
    /// again. A pull on the list reads them at once.
    static let combinedDashboardChatsMaxAge: TimeInterval = 60

    /// How long another dashboard's cron ids stand, and how many of each
    /// profile's newest are read (identity evidence only, issue 2761).
    static let combinedDashboardCronMaxAge: TimeInterval = 30 * 60
    static let combinedDashboardCronLimit = 20

    /// Reads each other combined dashboard's newest chats, every one of its
    /// profiles (Eric, 2026-11-16: All combines all of it), through its
    /// kept connection. Quiet on failure: a profile that can't be read
    /// keeps what it showed, and a dashboard let go or opened says nothing
    /// more. `only`: that dashboard's alone (its own `sessions.changed`).
    func readOtherCombinedDashboardsChats(force: Bool = false, only: UUID? = nil, now: Date = Date()) async {
        let kept = keptDashboardRuntimes.filter {
            isInCombinedGroup($0.key) && $0.key != activeDashboardID && (only == nil || $0.key == only)
        }
        // One that dropped by itself keeps its last list until it's back;
        // out of the group or opened here, it goes.
        let gone = combinedDashboardChats.keys.filter { !isInCombinedGroup($0) || $0 == activeDashboardID }
        if !gone.isEmpty { combinedDashboardChats = combinedDashboardChats.filter { !gone.contains($0.key) } }
        // Siri, Spotlight and the widgets know them too, once per pass,
        // however it ends.
        var wroteAny = false
        defer { if wroteAny { publishCombinedWidgetWorkspaces() } }
        for (id, runtime) in kept.sorted(by: { $0.value.keptAt < $1.value.keptAt }) {
            guard isSceneActive else { return }
            let bridge = ObjectIdentifier(runtime.bridge)
            // No profile list to be had (a reconnect lost it and the read
            // failed): the profiles it listed last, so none of them drops.
            let listed = await keptDashboardProfileNames(id, runtime)
            let profiles = listed
                ?? combinedDashboardChats[id].flatMap { $0.profiles.isEmpty ? nil : $0.profiles }
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
            // Its cron runs' ids, so it counts them as the dashboard on
            // screen does (issue 2761). Kept from the last read on this
            // connection while fresh.
            let last = combinedDashboardChats[id].flatMap { $0.bridge == bridge ? $0 : nil }
            var cronIDs = last?.cronIDs ?? []
            var cronAt = last?.cronAt
            if cronAt.map({ now.timeIntervalSince($0) >= Self.combinedDashboardCronMaxAge }) ?? true {
                var read: Set<String> = []
                // Replaced only when every profile answers, so one that
                // failed keeps the evidence it gave last (#2800 review).
                var cronAnswered = true
                for profile in profiles {
                    guard isSceneActive else { return }
                    let path = cronSessionsPath(profile, limit: Self.combinedDashboardCronLimit)
                    guard let batch = (try? await readKeptDashboardJSON(runtime.bridge, path: path))?["sessions"] as? [Any] else {
                        cronAnswered = false
                        continue
                    }
                    read.formUnion(Self.dashboardOwnedSessions(batch, profile: profile)
                        .flatMap { [$0.id, $0.storedSessionId].compactMap { $0 } })
                }
                guard keptDashboardRuntimes[id]?.bridge === runtime.bridge, activeDashboardID != id,
                      isInCombinedGroup(id),
                      !(combinedDashboardChats[id].map { $0.at > now || ($0.seededAt.map { $0 > now } ?? false) } ?? false) else {
                    continue
                }
                if cronAnswered {
                    cronIDs = read
                    cronAt = now
                }
            }
            combinedDashboardChats[id] = CombinedDashboardChats(
                bridge: bridge,
                profiles: profiles,
                sessions: sessions,
                at: now,
                cronIDs: cronIDs,
                cronAt: cronAt
            )
            // A profile its Hermes no longer lists leaves Siri, Spotlight
            // and the widgets too, as it leaves the strip and All.
            if let listed { retainWidgetProfiles(Set(listed), dashboardID: id) }
            wroteAny = true
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

    /// A switch to another combined dashboard during a call it would end
    /// says to end the call first, as a notification from that dashboard
    /// does. A live call on the phone goes on across it, on its own
    /// dashboard (no-switch stage 2), so that switch goes ahead: only
    /// Classic voice, CarPlay, the Watch and a ringing call from Hermes
    /// still refuse.
    func refusesCombinedSwitchDuringCall(to dashboardID: UUID?) -> Bool {
        guard isCallEndingDashboardSwitch(to: dashboardID) else { return false }
        showCallRefusal(AppLocalization.string("End the call to open a chat in another workspace."))
        return true
    }

    /// Opens another combined dashboard's row: in place on its own runtime
    /// while it's kept connected, else the switch to its dashboard, then the
    /// chat in its own profile, as a notification from that dashboard opens.
    func openCombinedChat(_ session: SessionSummary, in dashboardID: UUID) {
        // Kept connected: it opens in place, on that dashboard's own
        // runtime, with no switch (no-switch stage 2, AppState+FarChat.swift).
        if openFarChatInPlace(session, in: dashboardID) { return }
        // The notification path refuses during a call too; saying so here
        // keeps it to the tap.
        guard !refusesCombinedSwitchDuringCall(to: dashboardID) else { return }
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
        // This dashboard's copy is always the one kept. Which dashboards are
        // one Hermes comes from what their lists share, a chat, a wait or a
        // Bot Chat, so a Hermes running no bots is found too (issue 2741).
        let (kept, twins) = Self.oneChipPerHermes(chips, hermes: combinedHermesGroups, onScreen: activeDashboardID)
        chips = kept
        let saved = CombinedBotsHomeOrder.handingOn(combinedBotsHomeOrder, twins: twins)
        return CombinedBotsHomeOrder.ordered(chips, saved: saved, key: \.id)
    }

    /// Each dashboard of the group to its Hermes' number, from what the
    /// lists share (`combinedHermesEvidence`) and the rosters' Bot Chats.
    var combinedHermesGroups: [UUID?: Int] {
        var evidence = combinedHermesEvidence
        for bot in shownBotRoster {
            if let id = bot.canonicalSession?.id { evidence[activeDashboardID, default: []].insert(id) }
        }
        for section in otherCombinedDashboardsBots {
            for bot in section.bots {
                if let id = bot.canonicalSession?.id { evidence[section.dashboardID, default: []].insert(id) }
            }
        }
        return Self.oneHermesGroups(evidence)
    }

    /// One chip per profile per Hermes: the dashboard on screen's copy,
    /// else the first in `chips`' order. `twins`: each kept chip's key to
    /// the keys of the copies left out, which take its place in the order.
    static func oneChipPerHermes(
        _ chips: [CombinedProfileChip],
        hermes: [UUID?: Int],
        onScreen: UUID?
    ) -> (kept: [CombinedProfileChip], twins: [String: [String]]) {
        func oneHermes(_ a: UUID?, _ b: UUID?) -> Bool {
            a == b || (hermes[a] != nil && hermes[a] == hermes[b])
        }
        var kept: [CombinedProfileChip] = []
        var dropped = Set<String>()
        var twins: [String: [String]] = [:]
        let first = chips.filter { $0.dashboardID == onScreen }
        for chip in first + chips.filter({ $0.dashboardID != onScreen }) {
            let name = chip.profile.lowercased()
            if let twin = kept.first(where: { $0.dashboardID != chip.dashboardID && $0.profile.lowercased() == name && oneHermes($0.dashboardID, chip.dashboardID) }) {
                dropped.insert(chip.id)
                twins[twin.id, default: []].append(chip.id)
            } else {
                kept.append(chip)
            }
        }
        return (dropped.isEmpty ? chips : chips.filter { !dropped.contains($0.id) }, twins)
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
    ///
    /// A profile its Hermes no longer has (deleted or renamed there since
    /// the strip's last read) switches nothing and leaves the strip; one
    /// the switch's own profile list doesn't name leaves its All as it was
    /// (issue 2646).
    func switchForCombinedProfile(in dashboardID: UUID, profile: String? = nil) async -> Bool {
        guard !refusesCombinedSwitchDuringCall(to: dashboardID) else { return false }
        if let profile {
            guard await combinedProfileStillListed(profile, in: dashboardID) else { return false }
            // The switch resumes on the picked profile, not first on the
            // one it last used there (Eric, 2026-11-16).
            rememberActiveProfile(profile, for: dashboardID)
        }
        await switchDashboard(to: dashboardID)
        guard activeDashboardID == dashboardID else { return false }
        // Its own list has the last word: the profile list read moves off a
        // profile it doesn't name, and its All stays as it was.
        if let profile, !profiles.isEmpty, !profiles.contains(where: { profilesMatch($0, profile) }) { return false }
        setAllProfilesChatsOn(false)
        return true
    }

    /// Whether another combined dashboard's Hermes still has a profile its
    /// strip chip shows, asked anew through its kept connection at the tap.
    /// One it no longer lists leaves the strip, its chats leave All and its
    /// waits leave Needs you at once (issue 2646). With no kept connection,
    /// or no list to be had, nothing speaks against the chip.
    func combinedProfileStillListed(_ profile: String, in dashboardID: UUID) async -> Bool {
        guard let runtime = keptDashboardRuntimes[dashboardID],
              let listed = await keptDashboardProfileNames(dashboardID, runtime, fresh: true) else { return true }
        guard !listed.contains(where: { profilesMatch($0, profile) }) else { return true }
        // Let go, opened or out of the group while the read was out: the
        // chip is gone with it.
        guard keptDashboardRuntimes[dashboardID]?.bridge === runtime.bridge, activeDashboardID != dashboardID else {
            return false
        }
        if let chats = combinedDashboardChats[dashboardID] {
            // Seeded now, so a pass that read the old list before this
            // can't bring the chip back.
            combinedDashboardChats[dashboardID] = CombinedDashboardChats(
                bridge: chats.bridge,
                profiles: chats.profiles.filter { !profilesMatch($0, profile) },
                sessions: chats.sessions.filter { !profilesMatch($0.profile ?? "", profile) },
                at: chats.at,
                seededAt: Date(),
                cronIDs: chats.cronIDs,
                cronAt: chats.cronAt
            )
        }
        needsYou.forgetOther(dashboardID, profilesOtherThan: Set(listed))
        retainWidgetProfiles(Set(listed), dashboardID: dashboardID)
        // A visit there before the deletion left it remembered: the next
        // switch there resumes on one it lists, not on the deleted one.
        if let remembered = rememberedActiveProfile(for: dashboardID),
           !listed.contains(where: { profilesMatch($0, remembered) }) {
            forgetActiveProfile(for: dashboardID)
        }
        return false
    }
}
