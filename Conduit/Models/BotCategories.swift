//
//  BotCategories.swift
//  Conduit
//
//  Bot categories: folders the person makes for their bots (Home,
//  Business), drawn as headings on Bots Home and in the desktop's Bots
//  sidebar (Eric, 2026-11-27, option A). Hermes Desktop calls them
//  sections and keeps a bot's on the bot itself: `sectionId` and
//  `sectionName` in its profile's `ui_meta['hermes-bots']`
//  (apps/desktop/src/plugins/hermes-bots/user-sections.ts). Conduit reads
//  and writes the same two fields, so a bot filed in either app shows
//  filed in the other, on every device.
//
//  A category is its name: Hermes gives each section a random id, so the
//  same category has another id on each host and on each Desktop that
//  made it before the name rode along. Bots group by name, in any case;
//  filing into a name a host already has reuses that host's id, so Hermes
//  Desktop there draws one section. A category exists while a bot is in
//  it (Hermes keeps empty ones on its own computer only). Bots in none
//  come last, under Other, and with no categories at all Bots Home draws
//  as it did before.
//
//  The categories' order is a BotOrder of their names, one per dashboard
//  and synced as `bots.categories`: Hermes keeps its sections' order on
//  each computer only.
//

import Foundation

/// A bot's category as its profile keeps it.
struct BotCategoryTag: Codable, Equatable, Hashable {
    let id: String
    let name: String
}

/// One heading's bots: `name` is nil for Other.
struct BotCategorySection<Item>: Identifiable {
    let name: String?
    let items: [Item]

    var id: String { name.map(BotCategories.key) ?? BotCategories.otherKey }
}

enum BotCategories {
    static let idField = "sectionId"
    static let nameField = "sectionName"
    /// The local key of the categories' order, per dashboard
    /// (AppState.dashboardPreferenceBucket), synced as `bots.categories`.
    static let storageKey = "conduit.botCategoryOrder.v1"
    static let syncKey = "bots.categories"
    /// Folded headings, by key, on this device only.
    static let foldedKey = "conduit.botCategories.folded.v1"
    /// Other's key among the headings: no category's name can take it.
    static let otherKey = "\u{1}other"
    /// Hermes Desktop's longest is what its dialog allows; this keeps a
    /// name a heading can show.
    static let maxNameLength = 40

    static func storageKey(scope: String?) -> String {
        scope.map { "\(storageKey).\($0)" } ?? storageKey
    }

    /// Group chats filed under a category, room id to name. Hermes keeps
    /// no field for it on a room (Hermes Desktop keeps a room's section on
    /// that computer only), so it's kept per dashboard and synced as
    /// `groups.categories`, which Conduit for desktop reads too.
    static let roomStorageKey = "conduit.groupRoomCategories.v1"
    static let roomSyncKey = "groups.categories"

    static func roomStorageKey(scope: String?) -> String {
        scope.map { "\(roomStorageKey).\($0)" } ?? roomStorageKey
    }

    /// The rooms' categories from a synced or saved value: names cleaned,
    /// blank ones dropped.
    static func roomCategories(_ value: Any?) -> [String: String] {
        guard let object = value as? [String: Any] else { return [:] }
        var rooms: [String: String] = [:]
        for (roomID, name) in object where !roomID.isEmpty {
            if let name = clean(name as? String) { rooms[roomID] = name }
        }
        return rooms
    }

    /// The rooms' categories after a rename (`to`) or delete (nil) of `old`.
    static func refiling(_ rooms: [String: String], _ old: String, to new: String?) -> [String: String] {
        var rooms = rooms
        for (roomID, name) in rooms where same(name, old) { rooms[roomID] = clean(new) }
        return rooms
    }

    /// The name a category goes by, trimmed; nil when blank.
    static func clean(_ name: String?) -> String? {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxNameLength))
    }

    /// Two names are one category in any case.
    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func same(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return key(a) == key(b)
        default: return false
        }
    }

    /// A bot's category from its `ui_meta['hermes-bots']`. A section filed
    /// by an old Hermes Desktop that never wrote the name has none to show,
    /// so it reads as Other until that Desktop stamps the name.
    static func tag(in meta: [String: AnyCodable]) -> BotCategoryTag? {
        guard let id = meta[idField]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
              let name = clean(meta[nameField]?.stringValue) else { return nil }
        return BotCategoryTag(id: id, name: name)
    }

    /// The ui_meta patch that files a bot under `tag`, or takes it out of
    /// its category (nil), as Hermes Desktop writes it.
    static func patch(_ tag: BotCategoryTag?) -> [String: Any?] {
        [idField: tag?.id, nameField: tag?.name]
    }

    /// The patch Edit Bot and New Bot write for the Category the person
    /// left: nil when it's the bot's own already; the bot's id kept for a
    /// name it already has in another case, else the host's id for it.
    static func editPatch(current: BotCategoryTag?, to name: String?, among bots: [BotProfile]) -> [String: Any?]? {
        let name = clean(name)
        guard current?.name != name else { return nil }
        guard let name else { return patch(nil) }
        if let current, same(current.name, name) { return patch(BotCategoryTag(id: current.id, name: name)) }
        return patch(tag(named: name, among: bots))
    }

    /// The tag a bot on one host takes for `name`: the id another of that
    /// host's bots already files that name under, else a new one in Hermes
    /// Desktop's shape.
    static func tag(named name: String, among bots: [BotProfile], now: Date = Date()) -> BotCategoryTag {
        if let existing = bots.compactMap(\.category).first(where: { same($0.name, name) }) {
            return BotCategoryTag(id: existing.id, name: name)
        }
        return BotCategoryTag(id: newID(now: now), name: name)
    }

    static func newID(now: Date = Date()) -> String {
        let millis = String(Int64(now.timeIntervalSince1970 * 1000), radix: 36)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let suffix = String((0..<5).map { _ in alphabet.randomElement()! })
        return "sec-\(millis)-\(suffix)"
    }

    /// The headings for `items`, in `order` (names it doesn't hold yet
    /// in the order their first bot shows), each with its bots in the order
    /// they came, Other last; `alsoNamed` adds the categories the group
    /// chats are in. Nil when nothing is in a category: Bots Home then
    /// draws no headings at all.
    static func sections<Item>(
        _ items: [Item],
        order: BotOrder,
        alsoNamed extra: [String] = [],
        category: (Item) -> String?
    ) -> [BotCategorySection<Item>]? {
        var names: [String] = []
        var buckets: [String: [Item]] = [:]
        var other: [Item] = []
        for item in items {
            guard let name = clean(category(item)) else {
                other.append(item)
                continue
            }
            let key = key(name)
            if buckets[key] == nil { names.append(name) }
            buckets[key, default: []].append(item)
        }
        // Categories only group chats are in still draw their heading.
        for name in extra.compactMap(clean) where buckets[key(name)] == nil {
            names.append(name)
            buckets[key(name)] = []
        }
        guard !names.isEmpty else { return nil }
        var sections = order.arrange(names) { $0 }.map { name in
            BotCategorySection(name: name, items: buckets[key(name)] ?? [])
        }
        if !other.isEmpty { sections.append(BotCategorySection(name: nil, items: other)) }
        return sections
    }

    /// The categories' order after `name` moves one place (`step` -1 or 1)
    /// among the `shown` ones.
    static func moving(_ order: BotOrder, _ name: String, by step: Int, shown: [String]) -> BotOrder {
        guard let index = shown.firstIndex(where: { same($0, name) }) else { return order }
        let target = index + step
        guard shown.indices.contains(target) else { return order }
        // Down: before the one after the neighbour (or at the end).
        let before: String? = step < 0 ? shown[target] : (shown.indices.contains(target + 1) ? shown[target + 1] : nil)
        return order.moving(name, before: before, shown: shown)
    }

    /// The order with a renamed category in its old name's place.
    static func renaming(_ order: BotOrder, _ old: String, to new: String) -> BotOrder {
        guard !order.isEmpty else { return order }
        let names = order.names.compactMap { name -> String? in
            if same(name, old) { return new }
            return same(name, new) ? nil : name
        }
        return BotOrder(names: names)
    }
}
