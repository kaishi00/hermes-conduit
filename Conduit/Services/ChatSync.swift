//
//  ChatSync.swift
//  Conduit
//
//  One Hermes chat used from two devices. A gateway older than Hermes
//  v0.21.6 sends a session's live events only to the client that last
//  resumed or sent in it: the other device's list and open chat go stale,
//  and a turn it started can stay "Working…" after the reply streamed
//  elsewhere. These rules work from what Conduit already reads, the
//  gateway's `session.active_list` registry, and never resume a chat whose
//  turn another device is receiving: with one event sink per session, that
//  would take the stream away from it. A turn run in another process (the
//  TUI) never reaches the registry; Hermes v0.22's `sessions.changed` and
//  the catalog's stored counts catch it (CatalogChangeSignal).
//

import Foundation

/// When the Chats list reads the catalog again on its own, besides Back and
/// a pull to refresh.
struct ChatListCatalogFreshness {
    /// A chat the registry lists and the catalog doesn't (one started on
    /// another device) asks for a read at most this often…
    static let unlistedReadInterval: TimeInterval = 10
    /// …and at most this many times for one state of that chat (its id,
    /// status and count): a live chat the catalog never lists (an archived
    /// one, a bot's) stops asking until it changes.
    static let unlistedReadsPerChat = 2
    /// Renames, deletions and titles made elsewhere are read at the first
    /// poll at least this long after the last read while the list is on
    /// screen: 30 s while it polls every 4 s, up to its slowest step (60 s,
    /// longer in Low Power or Low Data Mode, PollCadence) while nothing
    /// moves.
    static let fallbackInterval: TimeInterval = 30
    /// Coming back to the app reads the list again when the last read is
    /// older than this.
    static let sceneActiveInterval: TimeInterval = 10

    private(set) var lastLoadedAt: Date?
    private var lastUnlistedReadAt: Date?
    private var lastTimedReadAt: Date?
    private var readsByChat: [String: Int] = [:]

    mutating func noteLoaded(at now: Date) {
        lastLoadedAt = now
    }

    /// Whether these registry chats, absent from the list, call for a read
    /// now. Counts the read against each one it covers.
    mutating func shouldRead(forUnlisted ids: Set<String>, now: Date) -> Bool {
        // Only chats still unlisted keep a count.
        readsByChat = readsByChat.filter { ids.contains($0.key) }
        let due = ids.filter { readsByChat[$0, default: 0] < Self.unlistedReadsPerChat }
        guard !due.isEmpty else { return false }
        if let last = lastUnlistedReadAt, now.timeIntervalSince(last) < Self.unlistedReadInterval {
            return false
        }
        lastUnlistedReadAt = now
        for id in due { readsByChat[id, default: 0] += 1 }
        return true
    }

    /// Whether the last catalog read is older than `interval`. Nothing is due
    /// before a first read (the list's own first load owns that), and a read
    /// asked for here waits the same interval before another, so a failing
    /// read can't repeat every tick.
    mutating func shouldRead(olderThan interval: TimeInterval, now: Date) -> Bool {
        guard let lastLoadedAt, now.timeIntervalSince(lastLoadedAt) >= interval else { return false }
        if let last = lastTimedReadAt, now.timeIntervalSince(last) < interval { return false }
        lastTimedReadAt = now
        return true
    }
}

/// A chat made here that Hermes doesn't list yet: Hermes stores a chat
/// with its first message (`AppState.newChatAwaitingListing`, issue 1454).
struct NewChatAwaitingListing: Equatable {
    /// Every id the chat goes by: its stored id and the runtime's.
    let ids: Set<String>
    let profile: String
    /// The folder it started in; nil for a plain chat, which lands in Home.
    let cwd: String?

    func matches(_ session: SessionSummary) -> Bool {
        ids.contains(session.id)
            || session.storedSessionId.map(ids.contains) == true
            || session.alternateIds.contains(where: ids.contains)
    }

    /// Whether the chat belongs on `project`'s page: started in its folder,
    /// or, for Home, in none.
    func isIn(_ project: ProjectSummary) -> Bool {
        guard let folder = Self.folder(cwd) else { return project.isHome }
        return Self.folder(project.primaryPath) == folder
    }

    /// A project page's lanes with the chat on top of the lane of the
    /// folder it started in, or of a new Recent lane when none is that
    /// folder (a plain chat on Home's page among them). Hermes names a
    /// lane's folder in its path, or in its label when the two are one.
    func lanes(_ lanes: [ProjectSessionLane], with row: SessionSummary, newLaneID: String) -> [ProjectSessionLane] {
        guard !lanes.contains(where: { $0.sessions.contains(where: matches) }) else { return lanes }
        var lanes = lanes
        if let folder = Self.folder(cwd),
           let index = lanes.firstIndex(where: { Self.folder($0.path ?? $0.title) == folder }) {
            lanes[index].sessions.insert(row, at: 0)
        } else {
            lanes.insert(ProjectSessionLane(id: newLaneID, title: AppLocalization.string("Recent"), sessions: [row]), at: 0)
        }
        return lanes
    }

    private static func folder(_ path: String?) -> String? {
        var trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Hermes' `sessions.changed`: a stored session row moved, whichever
/// process wrote it. A turn run in the TUI on the gateway's computer, or
/// through another gateway on the same Hermes home, shows only here and in
/// the stored rows: this gateway's live registry never lists it (#1026).
/// Each signal reads the catalog again, at most every 5 s, and never while
/// a turn runs here (its own rows move the catalog the whole time); one
/// held back is read once the wait or the turn is over.
struct CatalogChangeSignal {
    static let minimumInterval: TimeInterval = 5

    private(set) var isPending = false
    private var lastReadAt: Date?

    mutating func noteChanged() {
        isPending = true
    }

    /// Whether the pending change is read now. Taking it clears it.
    mutating func takeRead(now: Date, turnRunningHere: Bool) -> Bool {
        guard isPending, !turnRunningHere, delayUntilDue(now: now) == 0 else { return false }
        isPending = false
        lastReadAt = now
        return true
    }

    /// How long until a pending change may be read: nil when none is
    /// pending, 0 when it may be read now.
    func delayUntilDue(now: Date) -> TimeInterval? {
        guard isPending else { return nil }
        guard let lastReadAt else { return 0 }
        return max(0, Self.minimumInterval - now.timeIntervalSince(lastReadAt))
    }
}

/// The open chat as this device holds it, for one check.
struct OpenChatLocalTurn: Equatable {
    var sessionID: String
    /// A turn is running here (`turnState == .running`).
    var isRunning: Bool
    /// A tool of the running turn is still running here: a long tool
    /// streams nothing until it ends.
    var hasRunningTool: Bool
    /// The chat's latest text here (the last user message and what followed
    /// it, the reply streaming here), to tell the registry's preview of a
    /// turn from another device's.
    var ownTexts: [String]
}

/// The registry's row for the open chat.
struct OpenChatRegistryRow: Equatable {
    var isRunning: Bool
    /// "starting": present, but neither busy nor idle yet.
    var isStarting: Bool
    var messageCount: Int?
    var preview: String?

    init(isRunning: Bool, isStarting: Bool = false, messageCount: Int? = nil, preview: String? = nil) {
        self.isRunning = isRunning
        self.isStarting = isStarting
        self.messageCount = messageCount
        self.preview = preview
    }
}

enum OpenChatSyncAction: Equatable {
    case none
    /// The turn running here is over on the server and this device missed
    /// its end: read the chat again, which settles the turn. Nothing runs,
    /// so resuming takes no stream away.
    case settleTurn
    /// A turn ran elsewhere while the chat sat idle here: read its new rows.
    case readNewRows
}

/// The open chat's view of the registry, one snapshot at a time.
struct OpenChatSync {
    /// A running turn that streamed nothing here for this long is checked
    /// against the registry.
    static let streamSilence: TimeInterval = 20
    /// How often a silent turn is checked. Never stretched: it only runs
    /// while a turn of this device's has streamed nothing for 20 s.
    static let silentTurnCheckInterval: TimeInterval = 8
    /// How often an idle open chat is checked: 15 s, then 30 s and 60 s
    /// while the registry shows the chat unchanged (PollCadence). A change,
    /// a send here, a turn running elsewhere or a return to the app goes
    /// back to 15 s.
    static let idleCheckInterval: TimeInterval = PollCadence.openChatIdleSteps[0]
    /// An idle chat shows another device's turn once it has been idle here
    /// this long (the registry can lag this device's own turn edges).
    static let localIdleGrace: TimeInterval = 5
    /// Reads of the chat at most this often.
    static let readInterval: TimeInterval = 10

    private(set) var sessionID: String?
    private(set) var lastStreamEventAt: Date?
    private var runningSince: Date?
    private var idleSince: Date?
    private var lastSnapshotAt: Date?
    private var lastCheckAt: Date?
    /// Back-to-back snapshots with no running turn, under a silent local
    /// turn. One read can miss a live row (a runtime id rotating); two
    /// settle it.
    private var notRunningSnapshots = 0
    private var messageCountBaseline: Int?
    private var sentHereSinceBaseline = false
    private var sawRunElsewhere = false
    private var lastReadAt: Date?
    /// Another device is getting the reply of a turn in this chat.
    private(set) var repliesElsewhere = false
    /// The idle check's pace, and the registry row it last saw.
    private(set) var idleBackoff = PollBackoff(steps: PollCadence.openChatIdleSteps)
    private var lastIdleRow: OpenChatRegistryRow?
    private var sawIdleRow = false
    /// The open chat's stored message count at the last catalog read, to
    /// tell a turn the registry never saw (#1026).
    private var catalogCountBaseline: Int?
    private var sentHereSinceCatalogBaseline = false
    /// A read a moved stored count asked for was called off: the next
    /// catalog read asks again, whatever the count.
    private var catalogReadPending = false

    /// This device sent something in the open chat: the registry's count
    /// moving next is its own doing.
    mutating func noteSentHere() {
        sentHereSinceBaseline = true
        sentHereSinceCatalogBaseline = true
        idleBackoff.reset()
    }

    /// Hermes announced a user message another client sent in this chat
    /// (`user.message`): its turn's rows are read once the chat is idle
    /// here and on the server, as for a turn the registry saw run.
    mutating func noteUserMessageElsewhere() {
        sawRunElsewhere = true
        idleBackoff.reset()
    }

    /// Back in the app, or the chat shown again: the idle check goes back
    /// to its shortest interval.
    mutating func resetIdlePace() {
        idleBackoff.reset()
        lastIdleRow = nil
        sawIdleRow = false
    }

    /// A read asked for was called off (the chat ran again before it could
    /// resume): the next idle snapshot asks again.
    mutating func readCalledOff() {
        sawRunElsewhere = true
        catalogReadPending = true
        lastReadAt = nil
    }

    /// A live event of the open chat arrived here: the stream is here.
    mutating func noteStreamEvent(at now: Date) {
        lastStreamEventAt = now
        repliesElsewhere = false
        notRunningSnapshots = 0
    }

    /// Whether the open chat wants a registry snapshot now. Called on every
    /// tick, it also tracks the local turn's edges. `conditions` stretch the
    /// idle check (Low Power Mode, Low Data Mode); a silent turn's check
    /// keeps its pace, so a turn that ended elsewhere still settles.
    mutating func checkDue(_ local: OpenChatLocalTurn, now: Date, conditions: DeviceConditions = DeviceConditions()) -> Bool {
        track(local, now: now)
        let due: Bool
        if local.isRunning {
            guard silence(now) >= Self.streamSilence else { return false }
            due = lastCheckAt.map { now.timeIntervalSince($0) >= Self.silentTurnCheckInterval } ?? true
        } else {
            // A turn running elsewhere is checked every 15 s whatever the
            // conditions, so it settles here soon after it ends.
            let interval = watchingTurnElsewhere
                ? idleBackoff.interval
                : PollCadence.stretched(idleBackoff.interval, by: conditions)
            due = lastCheckAt.map { now.timeIntervalSince($0) >= interval } ?? true
        }
        // Stamped when asked, so a registry that keeps failing is asked at
        // the same pace.
        if due { lastCheckAt = now }
        return due
    }

    /// Applies one registry snapshot taken at `snapshotAt`; a snapshot
    /// already seen does nothing. `row` is nil when the chat has no live
    /// runtime. `chatVisible` is false when the chat is behind the list:
    /// a silent turn still settles, new rows wait for the chat.
    mutating func observe(
        _ row: OpenChatRegistryRow?,
        snapshotAt: Date,
        local: OpenChatLocalTurn,
        now: Date,
        chatVisible: Bool
    ) -> OpenChatSyncAction {
        track(local, now: now)
        if let lastSnapshotAt, snapshotAt <= lastSnapshotAt { return .none }
        lastSnapshotAt = snapshotAt
        lastCheckAt = now
        if local.isRunning {
            return observeRunningTurn(row, local: local, now: now)
        }
        let action = observeIdleChat(row, local: local, now: now, chatVisible: chatVisible)
        paceIdleCheck(after: row, action: action)
        return action
    }

    /// Applies one catalog read's stored message count for the open chat
    /// (nil when the listing carries none, or doesn't list the chat). A
    /// count that moved while the chat sat idle here is another device's
    /// turn, or one the TUI ran: read its rows. The count moving with a turn
    /// running here, within 5 s of one ending, or after a send here is this
    /// device's own doing.
    mutating func observeCatalog(
        messageCount count: Int?,
        local: OpenChatLocalTurn,
        now: Date,
        chatVisible: Bool
    ) -> OpenChatSyncAction {
        track(local, now: now)
        guard let count else { return .none }
        let idleLongEnough = idleSince.map { now.timeIntervalSince($0) >= Self.localIdleGrace } ?? false
        if local.isRunning || !idleLongEnough || sentHereSinceCatalogBaseline || catalogCountBaseline == nil {
            if !local.isRunning { sentHereSinceCatalogBaseline = false }
            // A turn here brings the chat current (its send reads first).
            if local.isRunning { catalogReadPending = false }
            catalogCountBaseline = count
            return .none
        }
        guard count != catalogCountBaseline || catalogReadPending else { return .none }
        // Off screen, the change waits like the registry's: the baseline
        // keeps it due for the next read while the chat shows.
        guard chatVisible, readAllowed(now) else { return .none }
        catalogCountBaseline = count
        catalogReadPending = false
        sawRunElsewhere = false
        lastReadAt = now
        return .readNewRows
    }

    /// The registry last showed a turn running or starting elsewhere in this
    /// idle chat, or one ran and its rows are still to read.
    private var watchingTurnElsewhere: Bool {
        sawRunElsewhere || (lastIdleRow.map { $0.isRunning || $0.isStarting } ?? false)
    }

    /// The same row twice with nothing to do waits longer before the next
    /// check; anything else (a turn running or starting elsewhere, a moved
    /// count, a read, a chat waiting to show a change) checks again at 15 s.
    private mutating func paceIdleCheck(after row: OpenChatRegistryRow?, action: OpenChatSyncAction) {
        let unchanged = sawIdleRow && row == lastIdleRow
        lastIdleRow = row
        sawIdleRow = true
        let busyElsewhere = row.map { $0.isRunning || $0.isStarting } ?? false
        if action == .none, unchanged, !busyElsewhere, !sawRunElsewhere {
            idleBackoff.lengthen()
        } else {
            idleBackoff.reset()
        }
    }

    private mutating func observeRunningTurn(
        _ row: OpenChatRegistryRow?,
        local: OpenChatLocalTurn,
        now: Date
    ) -> OpenChatSyncAction {
        guard silence(now) >= Self.streamSilence else {
            notRunningSnapshots = 0
            repliesElsewhere = false
            return .none
        }
        if let row, row.isRunning {
            notRunningSnapshots = 0
            // Silence alone can be a slow model or a long upload; the
            // registry's preview of the turn showing text this device never
            // had says another device is getting it.
            repliesElsewhere = !local.hasRunningTool
                && Self.previewIsForeign(row.preview, ownTexts: local.ownTexts)
            return .none
        }
        repliesElsewhere = false
        if row?.isStarting == true { return .none }
        notRunningSnapshots += 1
        guard notRunningSnapshots >= 2, readAllowed(now) else { return .none }
        notRunningSnapshots = 0
        lastReadAt = now
        // The read brings the rows; the next idle snapshot sets the count.
        messageCountBaseline = nil
        return .settleTurn
    }

    private mutating func observeIdleChat(
        _ row: OpenChatRegistryRow?,
        local: OpenChatLocalTurn,
        now: Date,
        chatVisible: Bool
    ) -> OpenChatSyncAction {
        notRunningSnapshots = 0
        guard let row else {
            repliesElsewhere = false
            return .none
        }
        if row.isRunning {
            // Not this device's own turn winding down (the registry lags its
            // end, and /goal judging runs after the reply): idle here for a
            // while, and text this device doesn't have.
            let idleLongEnough = idleSince.map { now.timeIntervalSince($0) >= Self.localIdleGrace } ?? false
            if idleLongEnough, Self.previewIsForeign(row.preview, ownTexts: local.ownTexts) {
                repliesElsewhere = true
                sawRunElsewhere = true
            }
            return .none
        }
        repliesElsewhere = false
        guard !row.isStarting else { return .none }
        let count = row.messageCount
        if sentHereSinceBaseline || messageCountBaseline == nil {
            // This device's own turn moved the count: nothing to read.
            sentHereSinceBaseline = false
            if !sawRunElsewhere {
                messageCountBaseline = count
                return .none
            }
        }
        let moved = count != nil && messageCountBaseline != nil && count != messageCountBaseline
        guard moved || sawRunElsewhere else { return .none }
        // Off screen, the change waits: reopening the chat reads it anyway,
        // and the baseline keeps it due for when the chat shows here.
        guard chatVisible, readAllowed(now) else { return .none }
        messageCountBaseline = count
        sawRunElsewhere = false
        lastReadAt = now
        return .readNewRows
    }

    private mutating func track(_ local: OpenChatLocalTurn, now: Date) {
        if local.sessionID != sessionID {
            self = OpenChatSync()
            sessionID = local.sessionID
        }
        if local.isRunning {
            if runningSince == nil { runningSince = now }
            idleSince = nil
        } else {
            runningSince = nil
            if idleSince == nil {
                idleSince = now
                // A turn just ended here: another device's reply to it may
                // follow, so the idle check starts over at its shortest.
                resetIdlePace()
            }
        }
    }

    private func silence(_ now: Date) -> TimeInterval {
        let start = runningSince ?? now
        let latest = max(start, lastStreamEventAt ?? start)
        return now.timeIntervalSince(latest)
    }

    private func readAllowed(_ now: Date) -> Bool {
        lastReadAt.map { now.timeIntervalSince($0) >= Self.readInterval } ?? true
    }

    /// Whether the registry's preview of a running turn (its reply so far,
    /// else its prompt; whitespace-collapsed, 160 characters) is text this
    /// device doesn't have. A prompt Hermes got with file references ahead
    /// of the typed text still reads as this device's.
    static func previewIsForeign(_ preview: String?, ownTexts: [String]) -> Bool {
        let shown = squashed(preview ?? "")
        guard !shown.isEmpty else { return false }
        for own in ownTexts.map(squashed) where !own.isEmpty {
            if shown.hasPrefix(own) || own.hasPrefix(shown) { return false }
            if shown.contains(own.prefix(40)) { return false }
        }
        return true
    }

    /// The registry's preview shape: words joined by one space, cut at 160.
    static func squashed(_ text: String) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(160))
    }
}
