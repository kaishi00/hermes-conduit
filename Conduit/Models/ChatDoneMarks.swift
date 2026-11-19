//
//  ChatDoneMarks.swift
//  Conduit
//
//  Done chats: a chat the user or their agent marked done (the row's menu
//  or swipe, or the plugin's conduit_chat_done tool). The plugin keeps the
//  marks per profile (`/chats/done`, plugin 0.183+), so every iPhone, iPad,
//  Mac and desktop shows the same ones, under every id of the chat it was
//  given: its lineage root, which a compaction keeps, and its sessions.
//

import Foundation

struct ChatDoneMarks: Equatable {
    struct Mark: Equatable {
        let ids: Set<String>
        let at: Date
        /// Marked by the agent's tool rather than from a row.
        let byAgent: Bool
    }

    static let capability = "chat-done"
    static let path = "/api/plugins/conduit_push/chats/done"
    /// The plugin keeps at most this many of a chat's ids.
    static let maxIDs = 8

    /// The dashboard these marks are from: another's chats aren't these.
    private(set) var dashboardID: UUID?
    private(set) var marksByProfile: [String: [Mark]] = [:]
    /// The profiles (lowercased) whose marks a read of this dashboard put
    /// here: one another dashboard's read dropped is read again at once.
    private(set) var readProfiles: Set<String> = []

    init(dashboardID: UUID? = nil, marksByProfile: [String: [Mark]] = [:]) {
        self.dashboardID = dashboardID
        self.marksByProfile = marksByProfile
    }

    /// This dashboard's marks for the profile came from a read and are kept.
    func hasRead(_ profile: String, dashboardID: UUID?) -> Bool {
        self.dashboardID == dashboardID && readProfiles.contains(profile.lowercased())
    }

    func mark(for session: SessionSummary, profile: String) -> Mark? {
        guard let marks = marksByProfile[profile], !marks.isEmpty else { return nil }
        let ids = SessionPinSync.pinIDs(for: session)
        return marks.first { !$0.ids.isDisjoint(with: ids) }
    }

    func isDone(_ session: SessionSummary, profile: String) -> Bool {
        mark(for: session, profile: profile) != nil
    }

    /// A profile's marks as its plugin read them; another dashboard's
    /// marks are dropped first.
    func replacing(_ marks: [Mark], profile: String, dashboardID: UUID?) -> ChatDoneMarks {
        var next = self.dashboardID == dashboardID ? self : ChatDoneMarks(dashboardID: dashboardID)
        next.marksByProfile[profile] = marks.isEmpty ? nil : marks
        next.readProfiles.insert(profile.lowercased())
        return next
    }

    /// The chat marked done, or open again, before the plugin answers.
    func setting(_ session: SessionSummary, done: Bool, profile: String, dashboardID: UUID?,
                 at date: Date = Date()) -> ChatDoneMarks {
        var next = self.dashboardID == dashboardID ? self : ChatDoneMarks(dashboardID: dashboardID)
        let ids = SessionPinSync.pinIDs(for: session)
        var marks = (next.marksByProfile[profile] ?? []).filter { $0.ids.isDisjoint(with: ids) }
        if done { marks.insert(Mark(ids: Set(Self.ids(for: session)), at: date, byAgent: false), at: 0) }
        next.marksByProfile[profile] = marks.isEmpty ? nil : marks
        return next
    }

    /// The ids a mark is kept under: the lineage root first, which a
    /// compaction keeps, then the chat's other ids.
    static func ids(for session: SessionSummary) -> [String] {
        let root = SessionPinSync.pinID(for: session)
        let others = ([session.id] + session.alternateIds).filter { !$0.isEmpty && $0 != root }
        var ids = [root]
        for id in others where !ids.contains(id) { ids.append(id) }
        return Array(ids.prefix(maxIDs))
    }

    /// The default profile's without a parameter, as every plugin route.
    static func readPath(profile: String) -> String {
        DashboardPath.withProfile(path, profile: profile)
    }

    static func savePath(profile: String) -> String {
        DashboardPath.withProfile(path, profile: profile)
    }

    static func body(for session: SessionSummary, done: Bool) -> [String: Any] {
        ["ids": ids(for: session), "done": done]
    }

    /// The route's answer, read; nil when it isn't one.
    static func marks(from answer: [String: Any]) -> [Mark]? {
        guard let rows = answer["done"] as? [Any] else { return nil }
        return rows.compactMap { row -> Mark? in
            guard let row = row as? [String: Any],
                  let ids = row["ids"] as? [String], !ids.isEmpty,
                  let at = (row["at"] as? NSNumber)?.doubleValue else { return nil }
            return Mark(ids: Set(ids), at: Date(timeIntervalSince1970: at), byAgent: row["by"] as? String == "agent")
        }
    }
}
