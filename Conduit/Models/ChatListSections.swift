//
//  ChatListSections.swift
//  Conduit
//
//  The Chats list's collapsible sections (#696): Pinned, then the recent
//  chats by day like Hermes Desktop's sidebar (Today, Yesterday, Last 7
//  days, Older). Pure list shaping, so the day boundaries and the saved
//  open/closed state stay testable without a view.
//

import Foundation

enum ChatListSection: String, CaseIterable, Hashable {
    case pinned
    case today
    case yesterday
    case lastSevenDays
    case older

    static let dateSections: [ChatListSection] = [.today, .yesterday, .lastSevenDays, .older]

    /// A first launch shows today's and yesterday's chats and closes the
    /// rest (#696).
    static let collapsedByDefault: Set<ChatListSection> = [.lastSevenDays, .older]

    /// The stored form of `collapsedByDefault`, the store's default value.
    static let defaultCollapsedRaw = storageValue(collapsedByDefault)

    var title: String {
        switch self {
        case .pinned: return AppLocalization.string("Pinned")
        case .today: return AppLocalization.string("Today")
        case .yesterday: return AppLocalization.string("Yesterday")
        case .lastSevenDays: return AppLocalization.string("Last 7 days")
        case .older: return AppLocalization.string("Older")
        }
    }

    /// The closed sections, stored as "lastSevenDays,older". An empty
    /// string is every section open; unknown names are dropped.
    static func collapsed(from raw: String) -> Set<ChatListSection> {
        Set(raw.split(separator: ",").compactMap { ChatListSection(rawValue: String($0)) })
    }

    static func storageValue(_ collapsed: Set<ChatListSection>) -> String {
        allCases.filter(collapsed.contains).map(\.rawValue).joined(separator: ",")
    }

    /// The day section an activity instant falls in. Today and Yesterday
    /// are calendar days; Last 7 days is the five days before those, so
    /// the three together span a week.
    static func dateSection(for activity: TimeInterval, now: Date, calendar: Calendar) -> ChatListSection {
        let startOfToday = calendar.startOfDay(for: now)
        let date = Date(timeIntervalSince1970: activity)
        if date >= startOfToday { return .today }
        if let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
           date >= startOfYesterday {
            return .yesterday
        }
        if let startOfWeek = calendar.date(byAdding: .day, value: -6, to: startOfToday),
           date >= startOfWeek {
            return .lastSevenDays
        }
        return .older
    }

    struct DateGroup: Identifiable, Equatable {
        let section: ChatListSection
        let nodes: [SessionNesting.Node]

        var id: ChatListSection { section }
    }

    /// The recent roots split by day, in list order, empty sections left
    /// out. A nest files under its newest row, so a parent whose call ran
    /// today sits in Today. A root without a timestamp follows the root
    /// before it, since the list is newest first; one at the very top goes
    /// in Today.
    static func byDate(
        _ nodes: [SessionNesting.Node],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DateGroup] {
        var buckets: [ChatListSection: [SessionNesting.Node]] = [:]
        var previous = ChatListSection.today
        for node in nodes {
            let section = latestActivity(in: node)
                .map { dateSection(for: $0, now: now, calendar: calendar) } ?? previous
            buckets[section, default: []].append(node)
            previous = section
        }
        return dateSections.compactMap { section in
            buckets[section].map { DateGroup(section: section, nodes: $0) }
        }
    }

    /// The section listing the row `active` identifies, its own row or
    /// one nested under a root there; nil when no listed row answers.
    static func section(of active: String, pinned: [SessionNesting.Node], recent: [DateGroup]) -> ChatListSection? {
        if SessionNesting.ancestorKeys(of: active, in: pinned).rowIsListed { return .pinned }
        return recent.first { SessionNesting.ancestorKeys(of: active, in: $0.nodes).rowIsListed }?.section
    }

    /// The newest activity in a nest: the row's own or any row below it.
    static func latestActivity(in node: SessionNesting.Node) -> TimeInterval? {
        node.children.reduce(node.session.lastActivityAt) { latest, child in
            switch (latest, latestActivity(in: child)) {
            case let (left?, right?): return max(left, right)
            case let (left, right): return left ?? right
            }
        }
    }
}

/// Whether the Chats list also shows the chats that live in a project,
/// which otherwise appear only on the project's page (and in search). A
/// listed one names its project under the title, as search does.
enum ProjectChatsInChats: String, CaseIterable, Identifiable {
    /// Only on the project's page, unless pinned.
    case hidden
    /// The ones active today or yesterday.
    case recent
    case all

    static let key = "conduit.v2.projectChatsInChats"
    /// Recent since #1317; an install from before keeps Off (`settleDefault`).
    static let defaultValue = ProjectChatsInChats.recent
    /// Set once the launch after #1317 has settled an older install's choice.
    static let defaultSettledKey = "conduit.v2.projectChatsDefaultSettled"

    var id: String { rawValue }

    static func stored(_ raw: String?) -> ProjectChatsInChats {
        raw.flatMap(ProjectChatsInChats.init(rawValue:)) ?? defaultValue
    }

    /// An install from before Recent became the default saved nothing for
    /// Off, which was the default then: it keeps Off rather than change
    /// under its user. Runs once; a new install (no saved dashboards) keeps
    /// the default, and a choice already made stays.
    static func settleDefault(in defaults: UserDefaults, existingInstall: Bool) {
        guard !defaults.bool(forKey: defaultSettledKey) else { return }
        if existingInstall, defaults.object(forKey: key) == nil {
            defaults.set(ProjectChatsInChats.hidden.rawValue, forKey: key)
        }
        defaults.set(true, forKey: defaultSettledKey)
    }

    /// Whether a project's chat with this last activity is listed. A chat
    /// without a time isn't recent.
    func shows(lastActivity: TimeInterval?, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .hidden: return false
        case .all: return true
        case .recent:
            guard let lastActivity else { return false }
            let section = ChatListSection.dateSection(for: lastActivity, now: now, calendar: calendar)
            return section == .today || section == .yesterday
        }
    }
}

/// The projects whose chats Chats leaves out (Filter ▸ Projects), kept per
/// profile since each profile has its own projects. Chats in no project
/// (Home's) are one more choice. Saved as profile → project ids.
enum HiddenChatProjects {
    static let key = "conduit.v2.hiddenChatProjects"
    /// Stands for the chats in no project.
    static let noProject = "~no-project"

    static func ids(in stored: Any?, profile: String) -> Set<String> {
        Set((stored as? [String: [String]])?[profile] ?? [])
    }

    /// `stored` with `profile`'s choice replaced; an empty one is dropped.
    static func setting(_ ids: Set<String>, profile: String, in stored: Any?) -> [String: [String]] {
        var all = stored as? [String: [String]] ?? [:]
        all[profile] = ids.isEmpty ? nil : ids.sorted()
        return all
    }

    /// Whether a row in `projectID` (nil: in no project) is left out. A
    /// pinned one stays, since pinning asks for it in Chats.
    static func hides(projectID: String?, pinned: Bool, hidden: Set<String>) -> Bool {
        !pinned && hidden.contains(projectID ?? noProject)
    }
}
