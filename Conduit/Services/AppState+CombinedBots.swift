//
//  AppState+CombinedBots.swift
//  Conduit
//
//  All-live stage 4c: Bots Home shows every combined dashboard's bots.
//  Each other dashboard's roster is read through its kept client and
//  shown in the same grid as the dashboard on screen's, mixed in one order
//  for the group kept on this phone (until arranged, each dashboard's in
//  Saved Dashboards order), every portrait with its badge. A portrait's tap
//  switches to that dashboard (through the kept connection) and opens the
//  bot's chat; the portrait stays where it was.
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

/// One other dashboard's bots on Bots Home's grid.
struct CombinedDashboardBotsSection: Identifiable, Equatable {
    let dashboardID: UUID
    let badge: V2DashboardBadge
    let bots: [BotProfile]
    let avatars: [String: URL]
    var id: UUID { dashboardID }
}

/// One portrait of Bots Home's grid in a combined group: this dashboard's
/// bot, or another combined dashboard's.
struct CombinedBotsHomeItem: Identifiable {
    enum Kind {
        case own(BotProfile)
        case other(BotProfile, CombinedDashboardBotsSection)
    }

    let dashboardID: UUID?
    let kind: Kind

    var bot: BotProfile {
        switch kind {
        case .own(let bot), .other(let bot, _): return bot
        }
    }

    var id: String { CombinedBotsHomeOrder.key(dashboardID, bot.name) }
}

/// Bots Home's order for a combined group's bots: one list of keys (the
/// dashboard and the bot), mixed across the dashboards, kept on this phone.
/// Each Hermes keeps its own order for its own bots, as before; this one
/// only arranges the group's grid. A bot it doesn't name yet goes after the
/// ones it does.
enum CombinedBotsHomeOrder {
    static let storageKey = "CombinedBotsHomeOrder"

    static func key(_ dashboardID: UUID?, _ bot: String) -> String {
        "\(dashboardID?.uuidString ?? "-")|\(bot.lowercased())"
    }

    /// A dragged portrait's name as a key: another dashboard's portrait
    /// carries its key, this dashboard's its bot's name.
    static func key(dragged: String, onScreen: UUID?) -> String {
        isKey(dragged) ? dragged : key(onScreen, dragged)
    }

    /// Whether a dragged name is another dashboard's key (a dashboard id,
    /// or "-", then "|"), rather than a bot's name, which may hold "|".
    static func isKey(_ dragged: String) -> Bool {
        guard let bar = dragged.firstIndex(of: "|") else { return false }
        let head = dragged[..<bar]
        return head == "-" || UUID(uuidString: String(head)) != nil
    }

    static func load(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: storageKey) ?? []
    }

    static func save(_ order: [String], _ defaults: UserDefaults = .standard) {
        defaults.set(order, forKey: storageKey)
    }

    /// `items` in the saved order; the ones it doesn't name follow, as
    /// they came.
    static func ordered<Item>(_ items: [Item], saved: [String], key: (Item) -> String) -> [Item] {
        let place = Dictionary(saved.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let known = items.filter { place[key($0)] != nil }.sorted { place[key($0)]! < place[key($1)]! }
        return known + items.filter { place[key($0)] == nil }
    }

    /// The saved order with `shown` keys it lacks added at the end, in
    /// the order shown.
    static func settled(_ saved: [String], shown: [String]) -> [String] {
        let known = Set(saved)
        return saved + shown.filter { !known.contains($0) }
    }

    /// `dragged` dropped on `target` takes its place, as on the Home
    /// Screen: carried on from before it, it lands just after it, else just
    /// before. Nil, or a target the order lacks: at the end.
    static func moving(_ order: [String], _ dragged: String, onto target: String?) -> [String] {
        guard dragged != target else { return order }
        let carriedOn = target.flatMap { target in
            order.firstIndex(of: dragged).flatMap { from in order.firstIndex(of: target).map { from < $0 } }
        } ?? false
        var order = order.filter { $0 != dragged }
        if let target, let index = order.firstIndex(of: target) {
            order.insert(dragged, at: carriedOn ? index + 1 : index)
        } else {
            order.append(dragged)
        }
        return order
    }
}

extension AppState {
    /// Bots Home's grid while other combined dashboards' bots join it:
    /// every dashboard's bots in the group's one order, this dashboard's
    /// shown ones (`own`, in its own order) among them. Until it's arranged,
    /// each dashboard's in Saved Dashboards order, this one's included.
    func combinedBotsHomeItems(own: [BotProfile]) -> [CombinedBotsHomeItem] {
        let others = otherCombinedDashboardsBots
        let mine = own.map { CombinedBotsHomeItem(dashboardID: activeDashboardID, kind: .own($0)) }
        guard !others.isEmpty else { return mine }
        var items: [CombinedBotsHomeItem] = []
        var mineListed = false
        for dashboard in savedDashboardRegistry.dashboards {
            if dashboard.id == activeDashboardID {
                items += mine
                mineListed = true
            } else if let section = others.first(where: { $0.dashboardID == dashboard.id }) {
                items += section.bots.map { CombinedBotsHomeItem(dashboardID: dashboard.id, kind: .other($0, section)) }
            }
        }
        if !mineListed { items = mine + items }
        return CombinedBotsHomeOrder.ordered(items, saved: combinedBotsHomeOrder, key: \.id)
    }

    /// Every other dashboard of the group has its bots on the grid: until
    /// then the grid keeps its starting order (Saved Dashboards order)
    /// rather than fixing a partial one.
    var combinedBotsHomeRostersIn: Bool {
        savedDashboardRegistry.dashboards.allSatisfy { dashboard in
            dashboard.id == activeDashboardID || !isInCombinedGroup(dashboard.id)
                || !(combinedDashboardBots[dashboard.id]?.bots.isEmpty ?? true)
        }
    }

    /// The grid as shown names every bot the order lacks: they keep the
    /// place they have now, so a switch never moves them.
    func settleCombinedBotsHomeOrder(_ shown: [String]) {
        // A dashboard out of the group (removed, or no longer combined)
        // leaves the order with its bots, whether or not every roster is in.
        let group = Set(savedDashboardRegistry.dashboards.map(\.id).filter { isInCombinedGroup($0) }.map(\.uuidString))
        let kept = combinedBotsHomeOrder.filter { key in
            // "-" is a dashboard with no saved entry: not one that left.
            key.split(separator: "|", maxSplits: 1).first.map { $0 == "-" || group.contains(String($0)) } ?? false
        }
        let settled = combinedBotsHomeRostersIn ? CombinedBotsHomeOrder.settled(kept, shown: shown) : kept
        guard settled != combinedBotsHomeOrder else { return }
        combinedBotsHomeOrder = settled
        CombinedBotsHomeOrder.save(settled, defaults)
    }

    /// A portrait of the mixed grid dropped on another (`onto`, its key),
    /// or at the end (nil). Either may be this dashboard's or another's.
    func moveCombinedBot(_ dragged: String, onto target: String?, shown: [String]) {
        let order = CombinedBotsHomeOrder.settled(combinedBotsHomeOrder, shown: shown)
        let moved = CombinedBotsHomeOrder.moving(
            order,
            CombinedBotsHomeOrder.key(dragged: dragged, onScreen: activeDashboardID),
            onto: target
        )
        guard moved != combinedBotsHomeOrder else { return }
        combinedBotsHomeOrder = moved
        CombinedBotsHomeOrder.save(moved, defaults)
    }

    /// How long another dashboard's roster stands before a read again.
    static let combinedDashboardBotsMaxAge: TimeInterval = 300

    /// Reads each other combined dashboard's bots through its kept client.
    /// Quiet on failure: a roster that can't be read keeps what it showed.
    func readOtherCombinedDashboardsBots(force: Bool = false, now: Date = Date()) async {
        let kept = keptDashboardRuntimes.filter { isInCombinedGroup($0.key) && $0.key != activeDashboardID }
        // One that dropped by itself keeps its last list until it's back;
        // out of the group or opened here, it goes.
        if combinedDashboardBots.keys.contains(where: { !isInCombinedGroup($0) || $0 == activeDashboardID }) {
            combinedDashboardBots = combinedDashboardBots.filter { isInCombinedGroup($0.key) && $0.key != activeDashboardID }
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
            // A read started later already stored its roster: keep that one.
            if let stored = combinedDashboardBots[id], stored.at > now { continue }
            combinedDashboardBots[id] = CombinedDashboardBots(
                client: client,
                bots: BotProfile.displayOrder(snapshot.bots.filter { !$0.isHiddenByMeta }),
                avatars: profileAppearanceStore.loadAvatarURLs(dashboardID: id),
                at: now
            )
        }
    }

    /// A dashboard just left, kept connected: its bots as it showed them,
    /// so Bots Home has them before the first read through the kept client.
    func seedCombinedDashboardBots(_ id: UUID, from roster: [BotProfile], client: HermesClient, now: Date = Date()) {
        let bots = BotProfile.displayOrder(roster.filter { !$0.isHiddenByMeta })
        guard !bots.isEmpty else { return }
        combinedDashboardBots[id] = CombinedDashboardBots(
            client: ObjectIdentifier(client),
            bots: bots,
            avatars: profileAppearanceStore.loadAvatarURLs(dashboardID: id),
            at: now
        )
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
    /// `zooms`: the chat grows out of the portrait (not when it opens
    /// beside the grid).
    func openCombinedBot(_ bot: BotProfile, in dashboardID: UUID, zooms: Bool = true) {
        guard !refusesCombinedSwitchDuringCall() else { return }
        // The chat grows out of the portrait as this dashboard's do: the
        // portrait stays where it is through the switch (the group's one
        // order), now this dashboard's, under the same name.
        if zooms { botZoom.tap(bot.name) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.switchDashboard(to: dashboardID)
            // Another dashboard picked meanwhile owns the screen.
            guard self.activeDashboardID == dashboardID else {
                // No chat comes: the arm goes, so a namesake here never
                // zooms another open.
                if zooms { self.botZoom.openFailed(bot.name) }
                return
            }
            self.openLinkedBotChat(bot.name, inDashboard: dashboardID)
        }
    }
}
