import Foundation

/// Which conversations have activity the user hasn't seen yet (#454).
///
/// Two sources feed one answer, mirroring Hermes Desktop:
///
/// 1. Hermes' own read watermark (`sessions.last_read_at`), surfaced as the
///    `unread` flag on dashboard session rows. It is shared with Desktop:
///    Desktop's "Mark as unread" sets it, and opening a flagged chat on either
///    client clears it. Rows Hermes has never tracked report `unread: false`.
/// 2. A local seen watermark: the `message_count` this device last showed the
///    user for each conversation. It catches replies that landed while the
///    user was elsewhere even when Hermes isn't tracking the row. A row seen
///    for the first time is seeded as read, so a fresh install doesn't light
///    up every chat.
///
/// State is bucketed by profile and keyed by the conversation's DURABLE id
/// (the compression lineage root, same rule as pins), so compression's id
/// rotation keeps its read state.
struct ChatReadLedger: Codable, Equatable {
    /// profile → durable id → message count the user has seen.
    var seenCounts: [String: [String: Int]] = [:]
    /// profile → durable ids the user marked unread on this device.
    var markedUnread: [String: [String]] = [:]

    /// Upper bound on remembered watermarks per profile. Past it, entries for
    /// conversations missing from the current listing are dropped; they
    /// reseed as read if they come back, which is the safe default.
    static let maxSeenCountsPerProfile = 2_000
}

struct ChatReadState: Equatable {
    /// A value Conduit just wrote to Hermes' read flag. A listing fetched
    /// before the write landed would otherwise repaint the old value.
    struct PendingServerValue: Equatable {
        var unread: Bool
        var writtenAt: Date
    }

    /// How long a written value outranks listings that disagree with it.
    static let pendingServerValueLifetime: TimeInterval = 30

    private(set) var ledger: ChatReadLedger
    /// "profile\u{1F}durable id" → value Conduit wrote to Hermes.
    private(set) var pendingServerValues: [String: PendingServerValue] = [:]
    /// Conversations the user had on screen, with when, whose listed count
    /// may predate what they saw (their own last turn, a reply that streamed
    /// in). A later listing adopts its count as seen unless the row's activity
    /// is newer than that moment.
    private(set) var seenPendingRefresh: [String: Date] = [:]

    /// Slack for clock skew between this device and the Hermes host when
    /// comparing a row's activity with the moment the user looked at it.
    static let activityClockSlack: TimeInterval = 5

    init(ledger: ChatReadLedger = ChatReadLedger()) {
        self.ledger = ledger
    }

    static func durableID(for session: SessionSummary) -> String {
        if let root = session.lineageRootId?.trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty {
            return root
        }
        return session.id
    }

    private static func key(_ profile: String, _ durableID: String) -> String {
        "\(profile)\u{1F}\(durableID)"
    }

    // MARK: Reading

    /// Whether the row has something the user hasn't seen.
    func isUnread(_ session: SessionSummary, profile: String, now: Date = Date()) -> Bool {
        serverUnread(session, profile: profile, now: now) || locallyUnread(session, profile: profile)
    }

    /// Hermes' shared flag, with Conduit's own recent write taking precedence.
    func serverUnread(_ session: SessionSummary, profile: String, now: Date = Date()) -> Bool {
        let id = Self.durableID(for: session)
        if let pending = pendingServerValues[Self.key(profile, id)],
           now.timeIntervalSince(pending.writtenAt) < Self.pendingServerValueLifetime {
            return pending.unread
        }
        return session.isUnread == true
    }

    func isMarkedUnread(_ session: SessionSummary, profile: String) -> Bool {
        ledger.markedUnread[profile]?.contains(Self.durableID(for: session)) == true
    }

    func locallyUnread(_ session: SessionSummary, profile: String) -> Bool {
        let id = Self.durableID(for: session)
        if ledger.markedUnread[profile]?.contains(id) == true { return true }
        guard let count = session.messageCount,
              let seen = ledger.seenCounts[profile]?[id] else { return false }
        return count > seen
    }

    // MARK: Updating

    /// Folds a fresh listing in: seeds unknown rows as read, adopts counts for
    /// chats the user just had on screen, and retires pending server values
    /// the listing now confirms (or that have lapsed).
    mutating func observe(_ sessions: [SessionSummary], profile: String, now: Date = Date()) {
        var counts = ledger.seenCounts[profile] ?? [:]
        var listed = Set<String>()
        for session in sessions {
            let id = Self.durableID(for: session)
            listed.insert(id)
            let key = Self.key(profile, id)
            if let count = session.messageCount {
                if counts[id] == nil {
                    counts[id] = count
                } else if let seenAt = seenPendingRefresh[key] {
                    let activityIsNewer = session.lastActivityAt.map {
                        $0 > seenAt.timeIntervalSince1970 + Self.activityClockSlack
                    } ?? false
                    if !activityIsNewer {
                        counts[id] = max(count, counts[id] ?? 0)
                    }
                    seenPendingRefresh[key] = nil
                }
            }
            if let pending = pendingServerValues[key],
               session.isUnread == pending.unread
                || now.timeIntervalSince(pending.writtenAt) >= Self.pendingServerValueLifetime {
                pendingServerValues[key] = nil
            }
        }
        if counts.count > ChatReadLedger.maxSeenCountsPerProfile {
            counts = counts.filter { listed.contains($0.key) }
        }
        if ledger.seenCounts[profile] != counts {
            ledger.seenCounts[profile] = counts
        }
    }

    /// The user is looking at this conversation: everything in it is seen,
    /// including whatever the next listing reports for it.
    mutating func markSeen(_ session: SessionSummary, profile: String, at date: Date = Date()) {
        let id = Self.durableID(for: session)
        if let count = session.messageCount {
            let seen = max(count, ledger.seenCounts[profile]?[id] ?? 0)
            if ledger.seenCounts[profile]?[id] != seen {
                ledger.seenCounts[profile, default: [:]][id] = seen
            }
        }
        seenPendingRefresh[Self.key(profile, id)] = date
        clearMark(session, profile: profile)
    }

    mutating func markUnread(_ session: SessionSummary, profile: String) {
        let id = Self.durableID(for: session)
        seenPendingRefresh[Self.key(profile, id)] = nil
        if ledger.markedUnread[profile]?.contains(id) != true {
            ledger.markedUnread[profile, default: []].append(id)
        }
    }

    mutating func clearMark(_ session: SessionSummary, profile: String) {
        let id = Self.durableID(for: session)
        ledger.markedUnread[profile]?.removeAll { $0 == id }
        if ledger.markedUnread[profile]?.isEmpty == true {
            ledger.markedUnread[profile] = nil
        }
    }

    mutating func recordServerWrite(_ session: SessionSummary, profile: String, unread: Bool, at date: Date = Date()) {
        pendingServerValues[Self.key(profile, Self.durableID(for: session))] = PendingServerValue(unread: unread, writtenAt: date)
    }

    /// A write that failed no longer speaks for the row.
    mutating func discardServerWrite(_ session: SessionSummary, profile: String) {
        pendingServerValues[Self.key(profile, Self.durableID(for: session))] = nil
    }

    /// Forget a deleted conversation.
    mutating func forget(_ session: SessionSummary, profile: String) {
        let id = Self.durableID(for: session)
        let key = Self.key(profile, id)
        ledger.seenCounts[profile]?[id] = nil
        clearMark(session, profile: profile)
        pendingServerValues[key] = nil
        seenPendingRefresh[key] = nil
    }
}
