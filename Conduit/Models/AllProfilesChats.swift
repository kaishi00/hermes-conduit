//
//  AllProfilesChats.swift
//  Conduit
//
//  The Chats list's All view: one list of the chats of several profiles on
//  the dashboard in use, newest first, each row badged with its profile, or
//  grouped into a section per profile, each listing its pinned chats and
//  its five newest until "Show more". Hermes reads every profile's chats
//  in one request (`/api/profiles/sessions?profile=all`, rows tagged with
//  their profile); the profile in use keeps its own, fuller list.
//
//  Saved per dashboard: whether All is on, the profiles left out of it (so
//  a profile added later is in), and whether the list groups by profile.
//

import Foundation

struct AllProfilesChatsSettings: Equatable {
    struct Dashboard: Codable, Equatable {
        var isOn = false
        /// Left out of All, by name. Every profile left out means all of
        /// them, so All never lists nothing.
        var excluded: [String] = []
        var groupsByProfile = false
    }

    static let storageKey = "conduit.v2.allProfilesChats.v1"

    private(set) var dashboards: [String: Dashboard] = [:]

    init(dashboards: [String: Dashboard] = [:]) {
        self.dashboards = dashboards.filter { $0.value != Dashboard() }
    }

    init(defaults: UserDefaults) {
        guard let data = defaults.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode([String: Dashboard].self, from: data) else {
            self.init()
            return
        }
        self.init(dashboards: stored)
    }

    func save(to defaults: UserDefaults) {
        if dashboards.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(dashboards) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    subscript(dashboard id: UUID?) -> Dashboard {
        get { dashboards[Self.key(id)] ?? Dashboard() }
        set { dashboards[Self.key(id)] = newValue == Dashboard() ? nil : newValue }
    }

    private static func key(_ id: UUID?) -> String { id?.uuidString ?? "-" }
}

/// The other profiles' chats for All, as Hermes last listed them.
struct AllProfilesCatalog: Equatable {
    var dashboardID: UUID?
    /// Every profile's chats, each tagged with its profile, newest first.
    var sessions: [SessionSummary] = []
    var isLoaded = false
}

enum AllProfilesChats {
    /// The read: every profile's chats with a message, not archived, newest
    /// first, cron runs left to each profile's own list and Kanban workers to
    /// the board. Hermes reads this many rows from each profile and returns
    /// the newest of them all.
    static let pageSize = 300

    static var sessionsPath: String {
        "/api/profiles/sessions?limit=\(pageSize)&offset=0&min_messages=1&archived=exclude&order=recent&exclude_sources=\(SessionSource.chatListExcludedSources)&profile=all"
    }

    /// All needs two profiles to mean anything.
    static func isAvailable(profiles: [String]) -> Bool {
        profiles.count >= 2
    }

    /// The profiles All lists, in the strip's order: every one not left
    /// out, or all of them when every one is.
    static func included(_ profiles: [String], excluded: [String]) -> [String] {
        let kept = profiles.filter { profile in
            !excluded.contains { AppState.profilesMatch($0, profile) }
        }
        return kept.isEmpty ? profiles : kept
    }

    /// The profile in `profiles` a row's owner names, spelled as listed.
    static func profile(named owner: String?, in profiles: [String]) -> String? {
        guard let owner = owner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty else { return nil }
        return profiles.first { AppState.profilesMatch($0, owner) }
    }

    /// What All lists: the profile in use from its own list (`activeRows`)
    /// and the other included profiles from the combined read, newest
    /// first. While the profile in use has no list of its own yet (a
    /// switch just emptied it), its rows come from the combined read too,
    /// so the list doesn't flash empty under a tap.
    static func rows(
        active: String,
        activeRows: [SessionSummary],
        combined: [SessionSummary],
        included: [String]
    ) -> [SessionSummary] {
        let activeIncluded = included.contains { AppState.profilesMatch($0, active) }
        let usesOwnList = activeIncluded && !activeRows.isEmpty
        var seen = Set<String>()
        var rows: [SessionSummary] = []
        if usesOwnList {
            for session in activeRows where seen.insert(identity(session, fallback: active)).inserted {
                rows.append(session)
            }
        }
        for session in combined {
            guard let owner = profile(named: session.profile, in: included) else { continue }
            if usesOwnList, AppState.profilesMatch(owner, active) { continue }
            guard seen.insert(identity(session, fallback: owner)).inserted else { continue }
            rows.append(session)
        }
        return newestFirst(rows)
    }

    /// Newest activity first; a row without a time keeps its place among
    /// the others without one, after every timed row.
    static func newestFirst(_ rows: [SessionSummary]) -> [SessionSummary] {
        rows.enumerated().sorted { lhs, rhs in
            switch (lhs.element.lastActivityAt, rhs.element.lastActivityAt) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// `items` split by profile, in `profiles` order; a profile with none
    /// has no group. An item whose owner isn't listed goes with `fallback`.
    static func groups<Item>(
        _ items: [Item],
        profiles: [String],
        fallback: String,
        owner: (Item) -> String?
    ) -> [(profile: String, items: [Item])] {
        var byProfile: [String: [Item]] = [:]
        for item in items {
            let key = profile(named: owner(item), in: profiles) ?? fallback
            byProfile[key, default: []].append(item)
        }
        return profiles.compactMap { profile in
            guard let items = byProfile[profile], !items.isEmpty else { return nil }
            return (profile, items)
        }
    }

    /// How many of a profile's chats its section lists, past its pinned
    /// ones, until "Show more": one busy profile doesn't push the others
    /// off the screen.
    static let groupPreviewCount = 5

    /// The items a profile's section lists, in their own order: every
    /// pinned one, the `groupPreviewCount` others with the newest
    /// `activity` (a nest's newest row, as the date sections file it) and
    /// the open chat wherever it falls; all of them when `showsAll`.
    /// `hidden` counts what "Show more" brings.
    static func preview<Item>(
        _ items: [Item],
        showsAll: Bool,
        isPinned: (Item) -> Bool,
        isOpen: (Item) -> Bool,
        activity: (Item) -> TimeInterval? = { _ in nil }
    ) -> (shown: [Item], hidden: Int) {
        guard !showsAll else { return (items, 0) }
        let pinned = items.map(isPinned)
        let newest = items.indices
            .filter { !pinned[$0] }
            .map { (index: $0, time: activity(items[$0])) }
            .sorted { lhs, rhs in
                switch (lhs.time, rhs.time) {
                case let (l?, r?) where l != r: return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.index < rhs.index
                }
            }
            .prefix(groupPreviewCount)
        let kept = Set(newest.map(\.index))
        var shown: [Item] = []
        var hidden = 0
        for (index, item) in items.enumerated() {
            if pinned[index] || kept.contains(index) || isOpen(item) {
                shown.append(item)
            } else {
                hidden += 1
            }
        }
        return (shown, hidden)
    }

    /// Whether `node`, or a chat nested under it, is open: such a nest
    /// stays listed past the preview.
    static func holdsOpen(_ node: SessionNesting.Node, isOpen: (SessionSummary) -> Bool) -> Bool {
        isOpen(node.session) || node.children.contains { holdsOpen($0, isOpen: isOpen) }
    }

    private static func identity(_ session: SessionSummary, fallback: String) -> String {
        (session.profile?.lowercased() ?? fallback.lowercased()) + "\u{1F}" + session.id
    }
}
