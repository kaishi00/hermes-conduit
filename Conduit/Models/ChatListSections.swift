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
