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
        /// Orders writes for one conversation: only the latest one's
        /// completion may change state.
        var generation: UInt64
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

    private var writeGeneration: UInt64 = 0
    /// "profile\u{1F}durable id" → when Conduit last wrote the flag, until a
    /// listing confirms it. Passive catch-up won't rewrite an unconfirmed
    /// value within `passiveRewriteInterval`, so a gateway that accepts the
    /// write but never stores it isn't asked on every listing.
    private(set) var lastWriteAttempts: [String: Date] = [:]
    static let passiveRewriteInterval: TimeInterval = 5 * 60
    /// A "seen" moment newer than this is left as is, so a chat sitting on
    /// screen doesn't republish state on every listing.
    static let seenRestampInterval: TimeInterval = 60

    /// How long a "seen while on screen" moment waits for a listing.
    static let seenPendingRefreshLifetime: TimeInterval = 10 * 60

    /// Slack for clock skew between this device and the Hermes host when
    /// comparing a row's activity with the moment the user looked at it.
    static let activityClockSlack: TimeInterval = 5

    /// profile → stored chat id → until when Hermes Desktop (or the web
    /// dashboard) on the host had the chat, in host time (notifier plugin
    /// 0.12+). Runtime only: the host keeps the record and is asked again.
    private(set) var desktopSeenThrough: [String: [String: TimeInterval]] = [:]

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
        if locallyUnread(session, profile: profile) { return true }
        return serverUnread(session, profile: profile, now: now)
            && !desktopSawFlaggedActivity(session, profile: profile, now: now)
    }

    /// Hermes' flag came from activity, not a mark, and Desktop had the chat
    /// when that activity landed. Desktop doesn't clear the flag for a reply
    /// it shows live, so its record answers for it. Both times are the host's.
    func desktopSawFlaggedActivity(_ session: SessionSummary, profile: String, now: Date = Date()) -> Bool {
        guard !isExplicitlyUnread(session, profile: profile, now: now),
              let seenThrough = desktopSeenTime(for: session, profile: profile),
              let activity = session.lastActivityAt else { return false }
        return activity <= seenThrough
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

    /// Unread because someone chose it: marked on this device, a mark Conduit
    /// just wrote, or Hermes' explicit mark (`last_read_at` = 0, which is what
    /// "Mark as unread" stores). Organic unread, activity newer than a real
    /// watermark, is not a mark: looking at the chat clears it.
    func isExplicitlyUnread(_ session: SessionSummary, profile: String, now: Date = Date()) -> Bool {
        if isMarkedUnread(session, profile: profile) { return true }
        if let pending = pendingServerValues[Self.key(profile, Self.durableID(for: session))],
           now.timeIntervalSince(pending.writtenAt) < Self.pendingServerValueLifetime {
            return pending.unread
        }
        return session.isUnread == true && session.readWatermark == 0
    }

    func locallyUnread(_ session: SessionSummary, profile: String) -> Bool {
        let id = Self.durableID(for: session)
        if ledger.markedUnread[profile]?.contains(id) == true { return true }
        guard let count = session.messageCount,
              let seen = ledger.seenCounts[profile]?[id] else { return false }
        return count > seen
    }

    /// The latest time Desktop had this conversation, under any of its ids.
    func desktopSeenTime(for session: SessionSummary, profile: String) -> TimeInterval? {
        guard let views = desktopSeenThrough[profile], !views.isEmpty else { return nil }
        let ids = [session.id, session.storedSessionId, session.lineageRootId].compactMap { $0 } + session.alternateIds
        return ids.compactMap { views[$0] }.max()
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
                    // Without a timestamp a newer reply can't be ruled out:
                    // leave it unread rather than swallow it.
                    let activityIsNewer = session.lastActivityAt.map {
                        $0 > seenAt.timeIntervalSince1970 + Self.activityClockSlack
                    } ?? true
                    if !activityIsNewer {
                        counts[id] = max(count, counts[id] ?? 0)
                    }
                    seenPendingRefresh[key] = nil
                }
                // Desktop had the chat when its latest activity landed, so
                // everything in it was on a screen. Both times are the host's.
                if let seenThrough = desktopSeenTime(for: session, profile: profile),
                   let activity = session.lastActivityAt, activity <= seenThrough {
                    counts[id] = max(count, counts[id] ?? 0)
                }
            }
            if let pending = pendingServerValues[key], session.isUnread == pending.unread {
                // Hermes holds the value now. A confirmed mark no longer
                // needs its local stand-in, so reading the chat on Desktop
                // clears it here too.
                if pending.unread { clearMark(session, profile: profile) }
                pendingServerValues[key] = nil
                lastWriteAttempts[key] = nil
            }
        }
        pendingServerValues = pendingServerValues.filter {
            now.timeIntervalSince($0.value.writtenAt) < Self.pendingServerValueLifetime
        }
        seenPendingRefresh = seenPendingRefresh.filter {
            now.timeIntervalSince($0.value) < Self.seenPendingRefreshLifetime
        }
        lastWriteAttempts = lastWriteAttempts.filter {
            now.timeIntervalSince($0.value) < Self.passiveRewriteInterval
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
        let key = Self.key(profile, id)
        if let stamped = seenPendingRefresh[key], date.timeIntervalSince(stamped) < Self.seenRestampInterval {
            // Recent enough: keep the state unchanged.
        } else {
            seenPendingRefresh[key] = date
        }
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

    /// Records a write about to be sent and returns its generation.
    @discardableResult
    mutating func recordServerWrite(_ session: SessionSummary, profile: String, unread: Bool, at date: Date = Date()) -> UInt64 {
        writeGeneration &+= 1
        lastWriteAttempts[Self.key(profile, Self.durableID(for: session))] = date
        pendingServerValues[Self.key(profile, Self.durableID(for: session))] = PendingServerValue(
            unread: unread,
            writtenAt: date,
            generation: writeGeneration
        )
        return writeGeneration
    }

    /// The chat is on screen but its read write is held back: hide Hermes'
    /// stale flag locally for a while without sending anything.
    mutating func recordLocalRead(_ session: SessionSummary, profile: String, at date: Date = Date()) {
        writeGeneration &+= 1
        pendingServerValues[Self.key(profile, Self.durableID(for: session))] = PendingServerValue(
            unread: false,
            writtenAt: date,
            generation: writeGeneration
        )
    }

    /// Whether passive catch-up may write the flag again for this row.
    func mayRewritePassively(_ session: SessionSummary, profile: String, now: Date = Date()) -> Bool {
        guard let last = lastWriteAttempts[Self.key(profile, Self.durableID(for: session))] else { return true }
        return now.timeIntervalSince(last) >= Self.passiveRewriteInterval
    }

    /// A write that failed no longer speaks for the row, unless a newer
    /// write has replaced it since.
    mutating func discardServerWrite(_ session: SessionSummary, profile: String, generation: UInt64) {
        let key = Self.key(profile, Self.durableID(for: session))
        guard pendingServerValues[key]?.generation == generation else { return }
        pendingServerValues[key] = nil
    }

    /// Folds in what the host reported Desktop had; the next listing
    /// applies it. Each chat keeps its latest time.
    mutating func recordDesktopViews(_ views: [String: TimeInterval], profile: String) {
        var current = desktopSeenThrough[profile] ?? [:]
        for (id, seenThrough) in views where seenThrough > (current[id] ?? -.infinity) {
            current[id] = seenThrough
        }
        if current.count > ChatReadLedger.maxSeenCountsPerProfile {
            let newest = current.sorted { $0.value > $1.value }.prefix(ChatReadLedger.maxSeenCountsPerProfile)
            current = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        if desktopSeenThrough[profile] != current {
            desktopSeenThrough[profile] = current
        }
    }

    /// Another host's Desktop record never applies to this one's chats.
    mutating func forgetDesktopViews() {
        if !desktopSeenThrough.isEmpty { desktopSeenThrough = [:] }
    }

    /// Forget a deleted conversation.
    mutating func forget(_ session: SessionSummary, profile: String) {
        let id = Self.durableID(for: session)
        let key = Self.key(profile, id)
        ledger.seenCounts[profile]?[id] = nil
        clearMark(session, profile: profile)
        pendingServerValues[key] = nil
        seenPendingRefresh[key] = nil
        lastWriteAttempts[key] = nil
    }
}
