//
//  AppState+CombinedBots.swift
//  Conduit
//
//  All-live stage 4c: Bots Home shows every combined dashboard's bots.
//  Each other dashboard's roster is read through its kept client and
//  shown under the dashboard on screen's, a section per dashboard in Saved
//  Dashboards order, each headed by its badge and name. A portrait's tap
//  switches to that dashboard (through the kept connection) and opens the
//  bot's chat.
//

import Foundation

/// Another combined dashboard's bots, with what they were read through,
/// the pictures it saved on this phone, and when.
struct CombinedDashboardBots: Equatable {
    let client: ObjectIdentifier
    let bots: [BotProfile]
    let avatars: [String: URL]
    let at: Date
}

/// One other dashboard's section on Bots Home.
struct CombinedDashboardBotsSection: Identifiable, Equatable {
    let dashboardID: UUID
    let badge: V2DashboardBadge
    let bots: [BotProfile]
    let avatars: [String: URL]
    var id: UUID { dashboardID }
}

extension AppState {
    /// How long another dashboard's roster stands before a read again.
    static let combinedDashboardBotsMaxAge: TimeInterval = 300

    /// Reads each other combined dashboard's bots through its kept client.
    /// Quiet on failure: a roster that can't be read keeps what it showed.
    func readOtherCombinedDashboardsBots(force: Bool = false, now: Date = Date()) async {
        let kept = keptDashboardRuntimes.filter { isInCombinedGroup($0.key) && $0.key != activeDashboardID }
        if combinedDashboardBots.keys.contains(where: { kept[$0] == nil }) {
            combinedDashboardBots = combinedDashboardBots.filter { kept[$0.key] != nil }
        }
        for (id, runtime) in kept.sorted(by: { $0.value.keptAt < $1.value.keptAt }) {
            guard isSceneActive else { return }
            let client = ObjectIdentifier(runtime.client)
            if !force, let last = combinedDashboardBots[id], last.client == client,
               now.timeIntervalSince(last.at) < Self.combinedDashboardBotsMaxAge { continue }
            let snapshot: BotRosterSnapshot?
            if let keptDashboardBotRosterReader {
                snapshot = try? await keptDashboardBotRosterReader(runtime.client)
            } else {
                snapshot = try? await runtime.client.botRoster()
            }
            // Let go, opened, or out of the group while the read was out.
            guard let snapshot, keptDashboardRuntimes[id]?.client === runtime.client, activeDashboardID != id,
                  isInCombinedGroup(id) else { continue }
            combinedDashboardBots[id] = CombinedDashboardBots(
                client: client,
                bots: BotProfile.displayOrder(snapshot.bots.filter { !$0.isHiddenByMeta }),
                avatars: profileAppearanceStore.loadAvatarURLs(dashboardID: id),
                at: now
            )
        }
    }

    /// The other combined dashboards' sections, in Saved Dashboards order.
    /// Only while the dashboard on screen is in the group.
    var otherCombinedDashboardsBots: [CombinedDashboardBotsSection] {
        guard isInCombinedGroup(activeDashboardID) else { return [] }
        return savedDashboardRegistry.dashboards.compactMap { dashboard in
            guard dashboard.id != activeDashboardID, isInCombinedGroup(dashboard.id),
                  let read = combinedDashboardBots[dashboard.id], !read.bots.isEmpty,
                  let badge = combinedDashboardBadge(dashboard.id) else { return nil }
            return CombinedDashboardBotsSection(
                dashboardID: dashboard.id,
                badge: V2DashboardBadge(letter: badge.letter, colorIndex: badge.colorIndex, name: badge.name),
                bots: read.bots,
                avatars: read.avatars
            )
        }
    }

    /// Opens another combined dashboard's bot: the switch to its dashboard
    /// (through its kept connection), then the bot's chat, as a link to it
    /// opens.
    func openCombinedBot(_ bot: BotProfile, in dashboardID: UUID) {
        guard !refusesCombinedSwitchDuringCall() else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.switchDashboard(to: dashboardID)
            // Another dashboard picked meanwhile owns the screen.
            guard self.activeDashboardID == dashboardID else { return }
            self.openLinkedBotChat(bot.name)
        }
    }
}
