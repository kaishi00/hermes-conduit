//
//  ChatMutes.swift
//  Conduit
//
//  Muted chats: a chat whose replies and failures send no notification for
//  15 minutes, an hour, a day or until unmuted, set from its row's menu.
//  The plugin keeps them per profile (`/notifications/muted-chats`, plugin
//  0.193+) and skips the pushes itself, so the mute holds on every device
//  paired with the profile and for sealed pushes. Approvals and questions
//  still notify. Kept under the chat's ids as Done marks are
//  (ChatDoneMarks.ids): its lineage root, which a compaction keeps, first.
//

import Foundation

struct ChatMutes: Equatable {
    struct Mute: Equatable {
        let ids: Set<String>
        /// When it ends; nil until the user unmutes it.
        let until: Date?

        func isActive(at now: Date) -> Bool {
            until.map { $0 > now } ?? true
        }
    }

    /// How long a mute lasts, as the menu offers it.
    enum Duration: CaseIterable, Identifiable {
        case fifteenMinutes, oneHour, oneDay, untilUnmuted

        var id: Self { self }

        /// The route's `mute_s`: nil mutes until unmuted.
        var seconds: Int? {
            switch self {
            case .fifteenMinutes: 15 * 60
            case .oneHour: 60 * 60
            case .oneDay: 24 * 60 * 60
            case .untilUnmuted: nil
            }
        }
    }

    static let capability = "chat-mute"
    static let path = "/api/plugins/conduit_push/notifications/muted-chats"
    /// The plugin's own bound (chat_mute.py MAX_IDS).
    static let maxIDs = 16

    /// The dashboard these mutes are from: another's chats aren't these.
    private(set) var dashboardID: UUID?
    private(set) var mutesByProfile: [String: [Mute]] = [:]
    /// The profiles (lowercased) whose mutes a read of this dashboard put here.
    private(set) var readProfiles: Set<String> = []

    init(dashboardID: UUID? = nil, mutesByProfile: [String: [Mute]] = [:]) {
        self.dashboardID = dashboardID
        self.mutesByProfile = mutesByProfile
    }

    func hasRead(_ profile: String, dashboardID: UUID?) -> Bool {
        self.dashboardID == dashboardID && readProfiles.contains(profile.lowercased())
    }

    /// The chat's mute while it lasts.
    func mute(for session: SessionSummary, profile: String, now: Date = Date()) -> Mute? {
        guard let mutes = mutesByProfile[profile], !mutes.isEmpty else { return nil }
        let ids = Set(Self.ids(for: session))
        return mutes.first { $0.isActive(at: now) && !$0.ids.isDisjoint(with: ids) }
    }

    /// A profile's mutes as its plugin read them; another dashboard's are
    /// dropped first.
    func replacing(_ mutes: [Mute], profile: String, dashboardID: UUID?) -> ChatMutes {
        var next = self.dashboardID == dashboardID ? self : ChatMutes(dashboardID: dashboardID)
        next.mutesByProfile[profile] = mutes.isEmpty ? nil : mutes
        next.readProfiles.insert(profile.lowercased())
        return next
    }

    /// The chat muted for `duration`, or unmuted (nil), before the plugin answers.
    func setting(_ session: SessionSummary, duration: Duration?, profile: String, dashboardID: UUID?,
                 now: Date = Date()) -> ChatMutes {
        var next = self.dashboardID == dashboardID ? self : ChatMutes(dashboardID: dashboardID)
        let ids = Self.ids(for: session)
        var mutes = (next.mutesByProfile[profile] ?? []).filter { $0.ids.isDisjoint(with: ids) && $0.isActive(at: now) }
        if let duration {
            mutes.append(Mute(ids: Set(ids), until: duration.seconds.map { now.addingTimeInterval(TimeInterval($0)) }))
        }
        next.mutesByProfile[profile] = mutes.isEmpty ? nil : mutes
        return next
    }

    /// The ids a mute is kept under: Done marks' (the lineage root first).
    static func ids(for session: SessionSummary) -> [String] {
        Array(ChatDoneMarks.ids(for: session).prefix(maxIDs))
    }

    static func path(profile: String) -> String {
        DashboardPath.withProfile(path, profile: profile)
    }

    /// The PUT's body: `mute_s` null mutes until unmuted, 0 unmutes.
    static func body(for session: SessionSummary, duration: Duration?) -> [String: Any] {
        let seconds: Any = duration.map { $0.seconds.map { $0 as Any } ?? NSNull() } ?? 0
        return ["session_ids": ids(for: session), "mute_s": seconds]
    }

    /// The route's answer, read against this device's clock (`remaining_s`,
    /// so the host's clock doesn't matter); nil when it isn't one.
    static func mutes(from answer: [String: Any], now: Date = Date()) -> [Mute]? {
        guard let rows = answer["chats"] as? [Any] else { return nil }
        return rows.compactMap { row -> Mute? in
            guard let row = row as? [String: Any], let ids = row["session_ids"] as? [String], !ids.isEmpty else { return nil }
            if row["remaining_s"] is NSNull || row["remaining_s"] == nil {
                return Mute(ids: Set(ids), until: nil)
            }
            guard let remaining = (row["remaining_s"] as? NSNumber)?.doubleValue else { return nil }
            return Mute(ids: Set(ids), until: now.addingTimeInterval(remaining))
        }
    }
}
