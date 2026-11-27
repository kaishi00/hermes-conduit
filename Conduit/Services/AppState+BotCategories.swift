//
//  AppState+BotCategories.swift
//  Conduit
//
//  Filing bots under categories (BotCategories): each write goes to the
//  bot's own Hermes, this dashboard's or, for another combined dashboard's
//  bot, through its kept connection, as a ui_meta patch read fresh first
//  (Hermes Desktop's way), so a field another client wrote meanwhile is
//  carried over. A rename or delete re-files every bot the category holds
//  on every dashboard shown; one whose dashboard is offline keeps its old
//  name until it's filed again.
//

import Foundation

extension AppState {
    /// The categories' order for Sync across devices.
    var botCategoryOrderSlot: SyncedPreferenceSlot {
        SyncedPreferenceSlot(
            key: BotCategories.syncKey,
            read: { [weak self] in
                guard let self, !self.botCategoryOrder.isEmpty else { return nil }
                return self.botCategoryOrder.names
            },
            write: { [weak self] value in
                self?.setBotCategoryOrder(BotOrder(names: value as? [String] ?? []))
            }
        )
    }

    /// The group chats' categories for Sync across devices.
    var groupRoomCategoriesSlot: SyncedPreferenceSlot {
        SyncedPreferenceSlot(
            key: BotCategories.roomSyncKey,
            read: { [weak self] in
                guard let self, !self.groupRoomCategories.isEmpty else { return nil }
                return self.groupRoomCategories
            },
            write: { [weak self] value in
                self?.setGroupRoomCategories(BotCategories.roomCategories(value))
            }
        )
    }

    /// Saves the group chats' categories, set here or from Sync across
    /// devices.
    func setGroupRoomCategories(_ rooms: [String: String]) {
        guard rooms != groupRoomCategories else { return }
        groupRoomCategories = rooms
        let key = BotCategories.roomStorageKey(scope: dashboardListsScope)
        if rooms.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(rooms, forKey: key) }
    }

    /// Files one of this dashboard's group chats under `name` (nil: takes
    /// it out).
    func fileGroupRoom(_ roomID: String, under name: String?) {
        var rooms = groupRoomCategories
        rooms[roomID] = BotCategories.clean(name)
        setGroupRoomCategories(rooms)
    }

    /// The category a group chat on Bots Home is filed under.
    func groupRoomCategory(_ roomID: String) -> String? {
        groupRoomCategories[roomID]
    }

    /// The categories this dashboard's shown group chats are in.
    var shownGroupRoomCategoryNames: [String] {
        shownGroupRooms.compactMap { groupRoomCategories[$0.roomID] }
    }

    /// Saves the categories' order, set here or from Sync across devices.
    func setBotCategoryOrder(_ order: BotOrder) {
        guard order != botCategoryOrder else { return }
        botCategoryOrder = order
        order.save(to: defaults, key: BotCategories.storageKey(scope: dashboardListsScope))
    }

    /// A heading moved one place among the `shown` ones.
    func moveBotCategory(_ name: String, by step: Int, shown: [String]) {
        setBotCategoryOrder(BotCategories.moving(botCategoryOrder, name, by: step, shown: shown))
    }

    /// The headings of Bots Home's bots (this dashboard's and the other
    /// combined dashboards'), nil when none is in a category.
    func botCategorySections(_ items: [CombinedBotsHomeItem]) -> [BotCategorySection<CombinedBotsHomeItem>]? {
        BotCategories.sections(items, order: botCategoryOrder, alsoNamed: shownGroupRoomCategoryNames) { $0.bot.category?.name }
    }

    /// Every category a bot shown on Bots Home is in, in the headings'
    /// order: the choices a bot's Category menu offers.
    func shownBotCategoryNames() -> [String] {
        let items = combinedBotsHomeItems(own: shownBotRoster.filter { !$0.isHiddenByMeta })
        let hidden = shownBotRoster.filter(\.isHiddenByMeta).map { CombinedBotsHomeItem(dashboardID: activeDashboardID, kind: .own($0)) }
        return (botCategorySections(items + hidden) ?? []).compactMap(\.name)
    }

    /// Files `item`'s bot under `name` (nil: takes it out of its category).
    /// Nil when it's saved, else what to tell the person. The same name in
    /// another case keeps the bot's id and re-stamps the name (a rename).
    @discardableResult
    func fileBot(_ item: CombinedBotsHomeItem, under name: String?, refreshes: Bool = true) async -> String? {
        let name = BotCategories.clean(name)
        guard item.bot.category?.name != name else { return nil }
        let failure = AppLocalization.string("Could not update \(item.bot.displayLabel).")
        func tag(among bots: [BotProfile]) -> BotCategoryTag? {
            guard let name else { return nil }
            if let current = item.bot.category, BotCategories.same(current.name, name) {
                return BotCategoryTag(id: current.id, name: name)
            }
            return BotCategories.tag(named: name, among: bots)
        }
        switch item.kind {
        case .own(let bot):
            guard let client, isConnected, !bot.isKeptCopy else {
                return AppLocalization.string("Connect to Hermes to manage bots.")
            }
            let saved = await writeBotCategory(bot.name, tag: tag(among: botRoster), client: client)
            if refreshes { await refreshBotRosterAfterWrite() }
            return saved ? nil : failure
        case .other(let bot, let section):
            guard let runtime = keptDashboardRuntimes[section.dashboardID] else {
                return AppLocalization.string("Connect to Hermes to manage bots.")
            }
            let saved = await writeBotCategory(bot.name, tag: tag(among: section.bots), client: runtime.client)
            if refreshes { await readOtherCombinedDashboardsBots(force: true) }
            return saved ? nil : failure
        }
    }

    /// Renames a category on every bot it holds, here and on the other
    /// combined dashboards, and keeps its place among the headings.
    @discardableResult
    func renameBotCategory(_ old: String, to new: String, items: [CombinedBotsHomeItem]) async -> String? {
        guard let new = BotCategories.clean(new), new != old else { return nil }
        setBotCategoryOrder(BotCategories.renaming(botCategoryOrder, old, to: new))
        setGroupRoomCategories(BotCategories.refiling(groupRoomCategories, old, to: new))
        return await refile(items.filter { BotCategories.same($0.bot.category?.name, old) }, under: new)
    }

    /// Deletes a category: its bots go back to Other and its group chats to
    /// Group Chats; nothing else changes.
    @discardableResult
    func deleteBotCategory(_ name: String, items: [CombinedBotsHomeItem]) async -> String? {
        setGroupRoomCategories(BotCategories.refiling(groupRoomCategories, name, to: nil))
        return await refile(items.filter { BotCategories.same($0.bot.category?.name, name) }, under: nil)
    }

    /// One write per bot, in turn, then one read of each roster that
    /// changed; the first failure is what's said.
    private func refile(_ items: [CombinedBotsHomeItem], under name: String?) async -> String? {
        var problem: String?
        var ownChanged = false
        var farChanged = false
        for item in items {
            let failure = await fileBot(item, under: name, refreshes: false)
            if problem == nil { problem = failure }
            if case .own = item.kind { ownChanged = true } else { farChanged = true }
        }
        if ownChanged { await refreshBotRosterAfterWrite() }
        if farChanged { await readOtherCombinedDashboardsBots(force: true) }
        return problem
    }

    /// A bot's category written over the Hermes `client` reaches: its
    /// ui_meta read fresh, patched and written with its revision, read
    /// again once when another client wrote first.
    func writeBotCategory(_ name: String, tag: BotCategoryTag?, client: HermesClient) async -> Bool {
        if let botCategoryWriterForTesting { return await botCategoryWriterForTesting(name, tag) }
        for _ in 0..<2 {
            guard let roster = try? await client.botRoster(),
                  let fresh = roster.bots.first(where: { $0.name == name }) else { return false }
            guard let result = try? await client.configureBotProfile(
                name: name,
                botMeta: BotMetaPatch.merged(existing: fresh.botMeta, patch: BotCategories.patch(tag)),
                expectedMetaRevision: fresh.botMetaRevision
            ) else { return false }
            switch BotMetaWriteOutcome(configureResult: result) {
            case .persisted, .unsupported: return true
            case .conflict: continue
            case .failed: return false
            }
        }
        return false
    }

    /// A bot Bots Home dragged (its name, or another combined dashboard's
    /// key), as the item a category files.
    func botsHomeItem(dragged: String) -> CombinedBotsHomeItem? {
        if let far = combinedBotsHomeBot(forKey: dragged) {
            return CombinedBotsHomeItem(dashboardID: far.section.dashboardID, kind: .other(far.bot, far.section))
        }
        let name = CombinedBotsHomeOrder.isKey(dragged)
            ? String(dragged.split(separator: "|", maxSplits: 1).last ?? "")
            : dragged
        guard let bot = shownBotRoster.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        return CombinedBotsHomeItem(dashboardID: activeDashboardID, kind: .own(bot))
    }
}
