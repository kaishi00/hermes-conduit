//
//  OfflineChatCache.swift
//  Conduit
//
//  Read-only on-disk copy of recently opened conversations (#99), so a cold
//  launch (after iOS reclaimed the process, or with the server unreachable)
//  can still show the last chat, and of the Chats list as it was last shown,
//  so a launch opens to the real list while it connects.
//
//  The copy never enters `AppState.messages` or `AppState.sessions`, so
//  nothing that decides resume, pagination, conversation selection,
//  bot-vs-workspace routing, or pending approval/clarify cards can read it.
//  While it stands in for a chat, the chat's own scroll view draws its rows,
//  marked provisional, and the server's first answer replaces them by id, so
//  rows that didn't change aren't drawn again (#1533).
//

import CryptoKit
import Foundation
import os

/// One persisted transcript row. Only the fields the read-only transcript
/// renders; interactive rows (approval/clarify cards, streaming partials)
/// are never stored.
struct OfflineCachedMessage: Codable, Equatable {
    let id: String
    let role: MessageRole
    let content: String
    let timestamp: String
    let author: String?
    let reasoning: String?
    let tool: ToolActivity?
    let displayKind: String?
    // What else the live transcript draws: pictures (kept on the phone),
    // reactions, a thinking step's time, notice and review cards. Rows
    // saved before these were kept have none.
    let rawContent: String?
    let review: ReviewActivity?
    let attachments: [Attachment]?
    let code: String?
    let reactions: [MessageReaction]?
    let stepDuration: TimeInterval?
    /// Hermes' own id for the row, so a row Hermes sends again unchanged
    /// equals the one drawn from the copy and isn't drawn again. Rows saved
    /// before it was kept have none.
    let rowId: Int?

    static let storableRoles: Set<MessageRole> = [.user, .assistant, .reasoning, .system, .tool]

    init?(_ message: ChatMessage) {
        guard Self.storableRoles.contains(message.role) else { return nil }
        id = message.id
        role = message.role
        content = message.content
        timestamp = message.timestamp
        author = message.author
        reasoning = message.reasoning
        tool = message.tool
        displayKind = message.displayKind
        rawContent = message.rawContent
        review = message.review
        attachments = message.attachments
        code = message.code
        reactions = message.reactions.isEmpty ? nil : message.reactions
        stepDuration = message.stepDuration
        rowId = message.rowId
    }

    var chatMessage: ChatMessage {
        var message = ChatMessage(
            id: id,
            role: role,
            content: content,
            rawContent: rawContent,
            timestamp: timestamp,
            author: author,
            reasoning: reasoning,
            tool: tool,
            review: review,
            attachments: attachments,
            code: code,
            displayKind: displayKind,
            rowId: rowId,
            reactions: reactions ?? []
        )
        message.stepDuration = stepDuration
        return message
    }
}

struct OfflineCachedSession: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let updatedLabel: String
    let lastActivityAt: TimeInterval?
    let source: SessionSource
    /// The row's other identities (runtime id, catalog aliases), so a
    /// transcript recorded while the live catalog is empty can still be
    /// keyed by this durable `id`.
    let aliases: [String]

    init(
        id: String,
        title: String,
        updatedLabel: String,
        lastActivityAt: TimeInterval?,
        source: SessionSource,
        aliases: [String] = []
    ) {
        self.id = id
        self.title = title
        self.updatedLabel = updatedLabel
        self.lastActivityAt = lastActivityAt
        self.source = source
        self.aliases = aliases
    }

    init(_ summary: SessionSummary) {
        let durable = summary.storedSessionId ?? summary.id
        id = durable
        title = summary.title
        updatedLabel = summary.updatedLabel
        lastActivityAt = summary.lastActivityAt
        source = summary.source
        aliases = ([summary.id] + summary.alternateIds).filter { $0 != durable }
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, updatedLabel, lastActivityAt, source, aliases
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        updatedLabel = try container.decode(String.self, forKey: .updatedLabel)
        lastActivityAt = try container.decodeIfPresent(TimeInterval.self, forKey: .lastActivityAt)
        source = try container.decode(SessionSource.self, forKey: .source)
        // Rows written before aliases were recorded decode with none.
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }

    func matches(_ identities: Set<String>) -> Bool {
        identities.contains(id) || !identities.isDisjoint(with: aliases)
    }
}

/// One saved conversation with its rows: a file of its own beside its
/// scope's index.
struct OfflineCachedTranscript: Codable, Equatable {
    let sessionID: String
    let title: String
    let savedAt: Date
    let messages: [OfflineCachedMessage]
}

/// A saved conversation as its scope's index lists it, without its rows.
struct OfflineCachedTranscriptEntry: Codable, Equatable {
    let sessionID: String
    let title: String
    let savedAt: Date
    /// Its file's size, for the scope's budget. Copies saved before it was
    /// kept have none, and count by their file's size on the disk.
    var bytes: Int?

    init(_ transcript: OfflineCachedTranscript, bytes: Int? = nil) {
        sessionID = transcript.sessionID
        title = transcript.title
        savedAt = transcript.savedAt
        self.bytes = bytes
    }
}

/// The index of what is cached for one (dashboard, profile) scope. Each
/// conversation's rows are in a file of their own
/// (`OfflineChatCacheStore.loadTranscript`), so a launch reads only the one
/// it shows and recording a chat rewrites only that chat.
struct OfflineChatSnapshot: Codable, Equatable {
    /// 2: a file per conversation. 1 kept every conversation in this file.
    static let formatVersion = 2

    var version: Int = Self.formatVersion
    var lastSessionID: String?
    var sessions: [OfflineCachedSession]
    /// Most recently opened first.
    var transcripts: [OfflineCachedTranscriptEntry]

    func transcript(for sessionID: String) -> OfflineCachedTranscriptEntry? {
        transcripts.first { $0.sessionID == sessionID }
    }
}

/// A scope saved in the first format, with every conversation's rows in its
/// one file.
private struct FirstFormatOfflineChatSnapshot: Decodable {
    let version: Int
    let lastSessionID: String?
    let sessions: [OfflineCachedSession]
    let transcripts: [OfflineCachedTranscript]
}

/// The Chats list as it was last shown for one (dashboard, profile) scope:
/// whole rows, so a launch or a profile switch draws it through the live
/// list's own code until the live list lands. PRESENTATION ONLY, like the
/// saved transcripts: it never enters `AppState.sessions`, and nothing that
/// resumes, routes or sends reads it.
struct SavedChatList: Codable, Equatable {
    static let formatVersion = 1
    static let maxSessions = 200
    static let maxCronSessions = 50

    var version: Int = Self.formatVersion
    var savedAt: Date
    /// The newest chats, then any pinned one past them, in list order.
    var sessions: [SessionSummary]
    /// The newest scheduled runs, then any pinned one past them.
    var cronSessions: [SessionSummary]
    /// The saved rows that showed as pinned. The Pinned section holds them
    /// while the phone has no pins of its own for the scope (a dashboard
    /// switch starts those over until Hermes' arrive).
    var pinnedRowIDs: [String]
    /// The saved rows' voice tags by id: call and job icons, and nests.
    var voiceTags: [String: VoiceSessionTag]
    /// The project tree, so project chats stay on their own pages.
    var projects: [ProjectSummary]
    var supportsProjects: Bool

    /// The list as shown: archived rows left out, the newest rows up to the
    /// caps, and every pinned row whatever its age.
    static func capture(
        sessions: [SessionSummary],
        cronSessions: [SessionSummary],
        isPinned: (SessionSummary) -> Bool,
        voiceTags: [String: VoiceSessionTag],
        projects: [ProjectSummary],
        supportsProjects: Bool,
        now: Date = Date()
    ) -> SavedChatList {
        let chats = sessions.filter { !$0.isArchived }
        let runs = cronSessions.filter { !$0.isArchived }
        let savedSessions = Array(chats.prefix(maxSessions)) + chats.dropFirst(maxSessions).filter(isPinned)
        let savedCron = Array(runs.prefix(maxCronSessions)) + runs.dropFirst(maxCronSessions).filter(isPinned)
        let savedRows = savedSessions + savedCron
        var tags: [String: VoiceSessionTag] = [:]
        for row in savedRows {
            for id in row.nestingIDs {
                if let tag = voiceTags[id] { tags[id] = tag }
            }
        }
        return SavedChatList(
            savedAt: now,
            sessions: savedSessions,
            cronSessions: savedCron,
            pinnedRowIDs: savedRows.filter(isPinned).map(\.id),
            voiceTags: tags,
            projects: projects,
            supportsProjects: supportsProjects
        )
    }

    /// The rows as a launch shows them: each time worked out again from its
    /// instant, the way the live list formats it, so a row saved yesterday
    /// doesn't still show only a time.
    func relabeled(now: Date = Date()) -> SavedChatList {
        func relabel(_ row: SessionSummary) -> SessionSummary {
            // Persisted input: anything outside 2000 ... now + 1 day is not
            // a real activity instant, so the row keeps its saved label.
            guard let instant = row.lastActivityAt,
                  instant.isFinite,
                  instant >= 946_684_800,
                  instant <= now.timeIntervalSince1970 + 86_400 else { return row }
            var row = row
            row.updatedLabel = MessageNormalizer.formattedSessionTimestamp(instant)
            return row
        }
        var list = self
        list.sessions = sessions.map(relabel)
        list.cronSessions = cronSessions.map(relabel)
        return list
    }
}

/// The saved list on screen for its scope, until the live one lands.
struct SavedChatListPresentation: Equatable {
    let dashboardID: UUID
    let profile: String
    var list: SavedChatList
    /// Set once the live list's newest page is listed while its older pages
    /// still load: the saved pinned rows that page doesn't have, kept under
    /// it so they don't blink out until the rest lands.
    var keptPinnedRows: [SessionSummary]?

    /// Whether the list on screen is still the saved one.
    var isShowingSavedRows: Bool { keptPinnedRows == nil }

    /// Whether `row` showed as pinned in the saved list.
    func showedAsPinned(_ row: SessionSummary) -> Bool {
        row.nestingIDs.contains { list.pinnedRowIDs.contains($0) }
    }

    /// Whether `row` is one of the kept pinned rows, which came from the
    /// saved list, not from Hermes.
    func isKeptRow(_ row: SessionSummary) -> Bool {
        guard let kept = keptPinnedRows, !kept.isEmpty else { return false }
        let ids = Set(row.nestingIDs)
        return kept.contains { !ids.isDisjoint(with: $0.nestingIDs) }
    }

    /// What stays once the live list's newest page alone is listed: the
    /// saved pinned rows it lacks, or nil when it lacks none.
    func keepingPinnedRows(
        missingFrom live: [SessionSummary],
        isPinned: (SessionSummary) -> Bool
    ) -> SavedChatListPresentation? {
        let liveIDs = Set(live.flatMap(\.nestingIDs))
        let kept = list.sessions.filter { isPinned($0) && liveIDs.isDisjoint(with: $0.nestingIDs) }
        guard !kept.isEmpty else { return nil }
        var presentation = self
        presentation.keptPinnedRows = kept
        return presentation
    }

    /// The chats listed over `live`: the saved rows while they show, else
    /// the live rows and then each kept row the live list still lacks (one
    /// it has since gained, opened or loaded, is listed once, as live).
    func listedRows(live: [SessionSummary]) -> [SessionSummary] {
        guard let kept = keptPinnedRows else { return list.sessions }
        guard !kept.isEmpty else { return live }
        let liveIDs = Set(live.flatMap(\.nestingIDs))
        return live + kept.filter { liveIDs.isDisjoint(with: $0.nestingIDs) }
    }
}

/// What the chat surface presents while the server has not answered yet:
/// the saved rows the chat's scroll view draws as the chat's own, marked
/// provisional, until Hermes' rows replace them (#1533).
struct OfflineChatPresentation: Equatable {
    let dashboardID: UUID
    let profile: String
    /// The scope's index: its saved conversations, without their rows.
    let snapshot: OfflineChatSnapshot
    /// The saved conversation on screen, with its rows.
    let displayedTranscript: OfflineCachedTranscript?
    /// Its rows as chat rows, made once per displayed conversation, not on
    /// every render. The chat view places them as it does Hermes' rows.
    let displayedMessages: [ChatMessage]
    /// A chat tapped in the saved list before the live one landed. Its
    /// saved copy (or the wait for one) shows in place of any transcript
    /// still on screen until that chat's own open lands.
    var picked: PickedChat?

    struct PickedChat: Equatable {
        /// The row's title, for the header.
        let title: String
        /// Every id the row answers to, so the open it leads to is known.
        var sessionIDs: Set<String>
        /// The id its saved copy and its draft are kept under.
        var durableSessionID: String? = nil
    }

    var isPickedChat: Bool { picked != nil }

    /// The chat the composer types into while this is on screen: the saved
    /// conversation's, else a picked chat's. Nil with neither.
    var composerSessionID: String? {
        displayedTranscript?.sessionID ?? picked?.durableSessionID
    }

    /// Every id the chat on screen answers to, so a message sent while it
    /// opens is matched to the chat that lands.
    var chatSessionIDs: Set<String> {
        var ids = picked?.sessionIDs ?? []
        if let durable = picked?.durableSessionID { ids.insert(durable) }
        if let sessionID = displayedTranscript?.sessionID {
            ids.insert(sessionID)
            if let row = snapshot.sessions.first(where: { $0.matches([sessionID]) }) {
                ids.insert(row.id)
                ids.formUnion(row.aliases)
            }
        }
        return ids
    }

    init(
        dashboardID: UUID,
        profile: String,
        snapshot: OfflineChatSnapshot,
        displayedTranscript: OfflineCachedTranscript?,
        picked: PickedChat? = nil
    ) {
        self.dashboardID = dashboardID
        self.profile = profile
        self.snapshot = snapshot
        self.displayedTranscript = displayedTranscript
        self.displayedMessages = displayedTranscript?.messages.map(\.chatMessage) ?? []
        self.picked = picked
    }

    var displayedSessionID: String? { displayedTranscript?.sessionID }
}

/// File-backed store. Per (dashboard, profile): an index, a file for each
/// saved conversation's rows and one for the Chats list, all JSON written
/// atomically with complete-until-first-user-authentication protection and
/// excluded from backups.
///
/// The app's store writes on a queue of its own (`writesAsynchronously`):
/// leaving a chat, a reply settling or the Chats list changing never waits
/// on encoding or the disk. It answers from memory (a Chats list as soon as
/// it's given, a copy or an index once written) while the files catch up,
/// and reads ahead what a tap shows next. Removals wait for the writes
/// queued before them, so nothing a removal took is written back.
final class OfflineChatCacheStore {
    /// The rows the chat had loaded when it was left, up to this many, so a
    /// chat read further back stays readable that far (#1525).
    static let maxMessagesPerTranscript = 500
    /// The last chats opened keep a copy, so most chats picked from the
    /// saved list open to their own rows: up to this many, while their files
    /// fit `maxScopeBytes`. The newest copy always stays.
    static let maxTranscripts = 100
    static let maxScopeBytes = 64 * 1024 * 1024
    /// At least `maxTranscripts`, so every kept copy keeps a row to open it from.
    static let maxSessions = 120
    /// A copy saved again with the same rows within this long keeps its
    /// file: leaving a chat that hasn't changed writes nothing. Past it the
    /// copy is written again, so its saved time says how fresh it is.
    static let unchangedCopyRewriteInterval: TimeInterval = 5 * 60

    /// Complete-until-first-user-authentication: unreadable from a device
    /// that has not been unlocked since boot, while still writable at the
    /// background transition after the device locks.
    static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    private let directory: URL
    private let fileManager: FileManager
    /// Guards every memory copy below: the main actor reads them while the
    /// store's queue writes and reads ahead. Never held across disk work.
    private let memoryLock = NSLock()
    /// The copies last read, written or read ahead, by file, with their
    /// files' sizes, so a chat opened again shows its copy without reading
    /// and decoding it on the tap (#1352). A kept copy is what its file
    /// holds: one is kept only once its file is written or read.
    private var keptTranscripts: [URL: (transcript: OfflineCachedTranscript, bytes: Int)] = [:]
    /// Least recently used first.
    private var keptTranscriptOrder: [URL] = []
    private var keptTranscriptBytes = 0
    static let maxKeptTranscripts = 16
    /// What the kept copies' files add up to, at most (the newest always
    /// stays).
    static let maxKeptTranscriptBytes = 32 * 1024 * 1024
    /// Each scope's index and saved Chats list as last read or written, by
    /// file, when the store writes asynchronously: memory is then ahead of
    /// the disk.
    private var keptIndexes: [URL: OfflineChatSnapshot] = [:]
    private var keptChatLists: [URL: SavedChatList] = [:]
    /// Screens' kept answers as last read, written or read ahead, by file
    /// (`recordAnswer`), least recently used first in `keptAnswerOrder`,
    /// with their files' sizes once known.
    private var keptAnswers: [URL: [String: Any]] = [:]
    private var keptAnswerOrder: [URL] = []
    private var keptAnswerBytes: [URL: Int] = [:]
    /// Which `recordAnswer` put each answer in memory, so the queue's size
    /// check only drops the one it measured.
    private var keptAnswerGenerations: [URL: UInt64] = [:]
    private var keptAnswerGeneration: UInt64 = 0
    /// How many copies each scope has had read ahead since the last
    /// removal: a later ask for more (the profile switched to, after its
    /// last chat was read ahead for the switch) reads the rest.
    private var prefetchedLimits: [String: Int] = [:]
    /// The scopes whose kept answers were read ahead since the last removal.
    private var answersPrefetched: Set<String> = []
    /// Removals waiting for the queue: a read ahead still queued skips
    /// itself, so a removal waits for the writes queued before it and at
    /// most one read ahead in progress.
    private var waitingRemovals = 0
    /// A copy whose file is larger than this isn't read ahead.
    static let maxPrefetchedTranscriptBytes = 4 * 1024 * 1024
    /// Where the files are written when the store writes asynchronously;
    /// nil writes them on the caller, as tests do. Nothing on it waits on
    /// the main thread, so the main thread may wait on it (removals).
    private let ioQueue: DispatchQueue?

    private let scopeBytes: Int
    /// Moves with every removal (a deleted chat, a wipe), so a read that was
    /// in flight across one keeps nothing (#1525).
    var removals: Int { memoryLock.withLock { removalCount } }
    private var removalCount = 0

    init(
        directory: URL,
        fileManager: FileManager = .default,
        scopeBytes: Int = OfflineChatCacheStore.maxScopeBytes,
        writesAsynchronously: Bool = false
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.scopeBytes = scopeBytes
        self.ioQueue = writesAsynchronously
            ? DispatchQueue(label: "conduit.offlineChatCache.write", qos: .utility)
            : nil
    }

    /// Runs disk work on the store's queue, after the work queued before
    /// it, or at once on the caller when the store writes synchronously.
    private func perform(_ work: @escaping () -> Void) {
        if let ioQueue {
            ioQueue.async(execute: work)
        } else {
            work()
        }
    }

    /// Runs disk work after every write queued before it and returns once
    /// it's done: removals, so a copy queued before one never lands after
    /// it, and what they took is gone when they return.
    private func performAndWait(_ work: () -> Void) {
        guard let ioQueue else {
            work()
            return
        }
        memoryLock.withLock { waitingRemovals += 1 }
        ioQueue.sync(execute: work)
        memoryLock.withLock { waitingRemovals -= 1 }
    }

    /// Blocks until every queued write and read ahead has landed: twice, as
    /// a read ahead queues its copies from the queue. Test-only.
    #if DEBUG
    func waitForPendingWrites() {
        ioQueue?.sync {}
        ioQueue?.sync {}
    }
    #endif

    /// Calls `completion` on the main queue once every write queued so far
    /// has landed, without blocking the caller, so a background task can
    /// keep the app alive until then.
    func notifyWhenPendingWritesLand(_ completion: @escaping @MainActor () -> Void) {
        guard let ioQueue else {
            DispatchQueue.main.async { completion() }
            return
        }
        ioQueue.async {
            DispatchQueue.main.async { completion() }
        }
    }

    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("OfflineChatCache", isDirectory: true)
    }

    /// The scope's index, or nil when nothing is saved for it (or it was
    /// saved in a format this build doesn't read).
    func load(dashboardID: UUID, profile: String) -> OfflineChatSnapshot? {
        let url = fileURL(dashboardID: dashboardID, profile: profile)
        if ioQueue != nil, let kept = memoryLock.withLock({ keptIndexes[url] }) { return kept }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let snapshot: OfflineChatSnapshot?
        if let decoded = try? JSONDecoder().decode(OfflineChatSnapshot.self, from: data),
           decoded.version == OfflineChatSnapshot.formatVersion {
            snapshot = decoded
        } else {
            snapshot = moveFirstFormat(data, dashboardID: dashboardID, profile: profile)
        }
        guard let snapshot else { return nil }
        // One the queue wrote while this was read is the newer one.
        return keepIfAbsent(snapshot, in: \.keptIndexes, at: url)
    }

    /// One saved conversation with its rows, or nil when it has none.
    func loadTranscript(_ sessionID: String, dashboardID: UUID, profile: String) -> OfflineCachedTranscript? {
        let url = transcriptFileURL(sessionID, dashboardID: dashboardID, profile: profile)
        if let kept = memoryLock.withLock({ () -> OfflineCachedTranscript? in
            guard let kept = keptTranscripts[url] else { return nil }
            keepLocked(kept.transcript, bytes: kept.bytes, at: url)
            return kept.transcript
        }) {
            return kept
        }
        guard let data = try? Data(contentsOf: url),
              let transcript = try? JSONDecoder().decode(OfflineCachedTranscript.self, from: data),
              transcript.sessionID == sessionID else {
            return nil
        }
        return memoryLock.withLock { () -> OfflineCachedTranscript in
            // A copy saved while the file was read is the newer one.
            if let newer = keptTranscripts[url] { return newer.transcript }
            keepLocked(transcript, bytes: data.count, at: url)
            return transcript
        }
    }

    /// Keeps a copy as the most recently used, then lets the least recently
    /// used go past `maxKeptTranscripts` or `maxKeptTranscriptBytes` (the
    /// newest always stays). Under `memoryLock`.
    private func keepLocked(_ transcript: OfflineCachedTranscript, bytes: Int, at url: URL) {
        keptTranscriptBytes -= keptTranscripts[url]?.bytes ?? 0
        keptTranscripts[url] = (transcript, bytes)
        keptTranscriptBytes += bytes
        keptTranscriptOrder.removeAll { $0 == url }
        keptTranscriptOrder.append(url)
        while keptTranscriptOrder.count > 1,
              keptTranscriptOrder.count > Self.maxKeptTranscripts
                || keptTranscriptBytes > Self.maxKeptTranscriptBytes {
            let oldest = keptTranscriptOrder.removeFirst()
            keptTranscriptBytes -= keptTranscripts.removeValue(forKey: oldest)?.bytes ?? 0
        }
    }

    private func keep(_ transcript: OfflineCachedTranscript, bytes: Int, at url: URL) {
        memoryLock.withLock { keepLocked(transcript, bytes: bytes, at: url) }
    }

    /// Kept copies go with their files.
    private func forgetKeptTranscripts(where isGone: (URL) -> Bool) {
        memoryLock.withLock {
            keptTranscriptOrder.removeAll(where: isGone)
            for url in keptTranscripts.keys.filter(isGone) {
                keptTranscriptBytes -= keptTranscripts.removeValue(forKey: url)?.bytes ?? 0
            }
        }
    }

    /// Memory's copy of a scope's index or list when it has one, else
    /// `value`, kept: what the queue wrote meanwhile is newer than a read.
    private func keepIfAbsent<Value>(
        _ value: Value,
        in memory: ReferenceWritableKeyPath<OfflineChatCacheStore, [URL: Value]>,
        at url: URL
    ) -> Value {
        guard ioQueue != nil else { return value }
        return memoryLock.withLock { () -> Value in
            if let newer = self[keyPath: memory][url] { return newer }
            self[keyPath: memory][url] = value
            return value
        }
    }

    /// Sets memory's copy of a scope's index or list (asynchronous mode
    /// only: in synchronous mode the disk is what's read).
    private func keepInMemory<Value>(
        _ value: Value,
        in memory: ReferenceWritableKeyPath<OfflineChatCacheStore, [URL: Value]>,
        at url: URL
    ) {
        guard ioQueue != nil else { return }
        memoryLock.withLock { self[keyPath: memory][url] = value }
    }

    /// Notes a removal before its disk work: reads in flight across it keep
    /// nothing, and every scope is read ahead again.
    private func noteRemoval() {
        memoryLock.withLock {
            removalCount &+= 1
            prefetchedLimits.removeAll()
            answersPrefetched.removeAll()
        }
    }

    /// A scope saved in the first format moves to a file per conversation
    /// the first time it is read, so an update doesn't lose the copies.
    private func moveFirstFormat(_ data: Data, dashboardID: UUID, profile: String) -> OfflineChatSnapshot? {
        guard let old = try? JSONDecoder().decode(FirstFormatOfflineChatSnapshot.self, from: data),
              old.version == 1 else { return nil }
        let moved = old.transcripts.compactMap { transcript in
            write(transcript, dashboardID: dashboardID, profile: profile)
                .map { OfflineCachedTranscriptEntry(transcript, bytes: $0) }
        }
        let snapshot = OfflineChatSnapshot(
            lastSessionID: old.lastSessionID,
            sessions: old.sessions,
            transcripts: moved
        )
        write(snapshot, dashboardID: dashboardID, profile: profile)
        return snapshot
    }

    /// Records the newest page of `messages` (moved to the front of the
    /// recent list) together with the current session list.
    ///
    /// The transcript is keyed by the conversation's DURABLE id — the same
    /// key as its saved session-list row — so the sidebar always lines up
    /// with it: `sessionID` when the caller resolved it from the live
    /// catalog, otherwise the saved row matching any of `identities`. With
    /// neither, nothing is written. Older transcripts stored under the
    /// conversation's other identities are dropped. An empty storable
    /// transcript records nothing.
    ///
    /// Only the rows are taken on the caller; resolving, encoding and the
    /// files happen on the store's queue when it writes asynchronously.
    func record(
        dashboardID: UUID,
        profile: String,
        sessionID: String?,
        identities: Set<String> = [],
        title: String,
        messages: [ChatMessage],
        sessions: [SessionSummary],
        now: Date = Date()
    ) {
        let rows = Array(messages.compactMap(OfflineCachedMessage.init)
            .suffix(Self.maxMessagesPerTranscript))
        guard !rows.isEmpty else { return }
        let catalogRows = sessions
            .filter { $0.source != .cron && !$0.isArchived }
            .map(OfflineCachedSession.init)
        perform { [self] in
            let signposter = ResponsivenessSignposts.signposter
            let saving = signposter.beginInterval("Save chat copy", id: signposter.makeSignpostID())
            defer { signposter.endInterval("Save chat copy", saving) }
            recordRows(
                rows,
                dashboardID: dashboardID,
                profile: profile,
                sessionID: sessionID,
                identities: identities,
                title: title,
                catalogRows: catalogRows,
                now: now
            )
        }
    }

    private func recordRows(
        _ rows: [OfflineCachedMessage],
        dashboardID: UUID,
        profile: String,
        sessionID: String?,
        identities: Set<String>,
        title: String,
        catalogRows: [OfflineCachedSession],
        now: Date
    ) {
        var snapshot = load(dashboardID: dashboardID, profile: profile)
            ?? OfflineChatSnapshot(lastSessionID: nil, sessions: [], transcripts: [])
        var allIdentities = identities
        if let sessionID { allIdentities.insert(sessionID) }
        // Resolve against the FULL catalog (or the saved list when the live
        // one is empty), before any cap can drop the conversation's row.
        let resolutionRows = catalogRows.isEmpty ? snapshot.sessions : catalogRows
        guard let sessionID = sessionID
            ?? resolutionRows.first(where: { $0.matches(allIdentities) })?.id else { return }
        if let row = snapshot.sessions.first(where: { $0.id == sessionID }) {
            allIdentities.formUnion(row.aliases)
        }
        let entry: OfflineCachedTranscriptEntry
        if let unchanged = unchangedEntry(snapshot, sessionID: sessionID, title: title, rows: rows, now: now,
                                          dashboardID: dashboardID, profile: profile) {
            entry = unchanged
        } else {
            let transcript = OfflineCachedTranscript(sessionID: sessionID, title: title, savedAt: now, messages: rows)
            // Its rows land first, so the index never lists a copy that isn't there.
            guard let bytes = write(transcript, dashboardID: dashboardID, profile: profile) else { return }
            entry = OfflineCachedTranscriptEntry(transcript, bytes: bytes)
        }
        let saved = snapshot
        snapshot.transcripts.removeAll { $0.sessionID == sessionID || allIdentities.contains($0.sessionID) }
        snapshot.transcripts.insert(entry, at: 0)
        snapshot.transcripts = boundedTranscripts(snapshot.transcripts, dashboardID: dashboardID, profile: profile)
        if !catalogRows.isEmpty {
            // Every retained transcript (current conversation first) keeps a
            // row to open it from, whatever its position in the catalog.
            snapshot.sessions = Self.cappedSessions(
                catalogRows,
                keeping: snapshot.transcripts.map(\.sessionID),
                previouslySaved: snapshot.sessions
            )
        }
        snapshot.lastSessionID = sessionID
        // The same chat left again with nothing new: nothing to write, but a
        // copy an earlier failed index write left behind still goes.
        if snapshot != saved {
            guard write(snapshot, dashboardID: dashboardID, profile: profile) else { return }
        }
        removeUnlistedTranscripts(snapshot, dashboardID: dashboardID, profile: profile)
    }

    /// The index's entry for a copy saved within
    /// `unchangedCopyRewriteInterval` with the same title and rows, whose
    /// file is still there, so it isn't encoded and written again; nil when
    /// the copy has to be written.
    private func unchangedEntry(
        _ snapshot: OfflineChatSnapshot,
        sessionID: String,
        title: String,
        rows: [OfflineCachedMessage],
        now: Date,
        dashboardID: UUID,
        profile: String
    ) -> OfflineCachedTranscriptEntry? {
        let url = transcriptFileURL(sessionID, dashboardID: dashboardID, profile: profile)
        guard let entry = snapshot.transcript(for: sessionID),
              let kept = memoryLock.withLock({ keptTranscripts[url] }),
              now.timeIntervalSince(kept.transcript.savedAt) < Self.unchangedCopyRewriteInterval,
              kept.transcript.title == title,
              kept.transcript.messages == rows,
              fileManager.fileExists(atPath: url.path) else { return nil }
        keep(kept.transcript, bytes: kept.bytes, at: url)
        return entry
    }

    /// A deleted conversation leaves the scope: its saved rows under any of
    /// `sessionIDs` (or a saved row's aliases), its row in the saved session
    /// list and the saved Chats list, and its place as the chat a launch
    /// opens to. The index is rewritten before the files go, as `record`
    /// does, so it never lists a copy that isn't there.
    func removeTranscripts(sessionIDs: Set<String>, dashboardID: UUID, profile: String) {
        performAndWait {
            removeTranscriptsNow(sessionIDs: sessionIDs, dashboardID: dashboardID, profile: profile)
        }
    }

    private func removeTranscriptsNow(sessionIDs: Set<String>, dashboardID: UUID, profile: String) {
        noteRemoval()
        let ids = sessionIDs.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        if var snapshot = load(dashboardID: dashboardID, profile: profile) {
            var allIdentities = ids
            for row in snapshot.sessions where row.matches(ids) {
                allIdentities.insert(row.id)
                allIdentities.formUnion(row.aliases)
            }
            snapshot.transcripts.removeAll { allIdentities.contains($0.sessionID) }
            snapshot.sessions.removeAll { $0.matches(allIdentities) }
            if let last = snapshot.lastSessionID, allIdentities.contains(last) {
                snapshot.lastSessionID = snapshot.transcripts.first?.sessionID
            }
            if write(snapshot, dashboardID: dashboardID, profile: profile) {
                removeUnlistedTranscripts(snapshot, dashboardID: dashboardID, profile: profile)
            }
            // Its rows go even if the index couldn't be rewritten: a listed
            // copy with no file just doesn't show.
            removeTranscriptFiles(allIdentities, dashboardID: dashboardID, profile: profile)
        } else {
            removeTranscriptFiles(ids, dashboardID: dashboardID, profile: profile)
        }
        if var list = loadChatList(dashboardID: dashboardID, profile: profile) {
            let isDeleted: (SessionSummary) -> Bool = { !ids.isDisjoint(with: $0.nestingIDs) }
            guard list.sessions.contains(where: isDeleted) || list.cronSessions.contains(where: isDeleted) else { return }
            let removedRows = (list.sessions + list.cronSessions).filter(isDeleted)
            let removedRowIDs = Set(removedRows.map(\.id))
            let removedNestingIDs = Set(removedRows.flatMap(\.nestingIDs))
            list.sessions.removeAll(where: isDeleted)
            list.cronSessions.removeAll(where: isDeleted)
            list.pinnedRowIDs.removeAll { removedRowIDs.contains($0) }
            list.voiceTags = list.voiceTags.filter { !removedNestingIDs.contains($0.key) }
            let url = chatListFileURL(dashboardID: dashboardID, profile: profile)
            keepInMemory(list, in: \.keptChatLists, at: url)
            writeChatList(list, to: url)
        }
    }

    private func removeTranscriptFiles(_ sessionIDs: Set<String>, dashboardID: UUID, profile: String) {
        let urls = Set(sessionIDs.map { transcriptFileURL($0, dashboardID: dashboardID, profile: profile) })
        forgetKeptTranscripts { urls.contains($0) }
        let heldRows = sessionIDs.map { heldRowsFileURL($0, dashboardID: dashboardID, profile: profile) }
        for url in urls.union(heldRows) {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Removes the scope's chat files its index doesn't list: the copies it
    /// let go, and any an earlier save left behind (a chat whose index write
    /// failed, or an index that could no longer be read).
    private func removeUnlistedTranscripts(_ snapshot: OfflineChatSnapshot, dashboardID: UUID, profile: String) {
        let prefix = "\(Self.scopeFileStem(dashboardID: dashboardID, profile: profile)).chat-"
        let listed = Set(snapshot.transcripts.map {
            transcriptFileURL($0.sessionID, dashboardID: dashboardID, profile: profile).lastPathComponent
        })
        forgetKeptTranscripts { $0.lastPathComponent.hasPrefix(prefix) && !listed.contains($0.lastPathComponent) }
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.lastPathComponent.hasPrefix(prefix) && !listed.contains(file.lastPathComponent) {
            try? fileManager.removeItem(at: file)
        }
    }

    /// The newest copies, up to `maxTranscripts` and while their files fit
    /// the scope's budget (`maxScopeBytes`); the newest always stays. A copy saved before sizes
    /// were kept is measured on the disk, once.
    private func boundedTranscripts(
        _ entries: [OfflineCachedTranscriptEntry],
        dashboardID: UUID,
        profile: String
    ) -> [OfflineCachedTranscriptEntry] {
        var kept: [OfflineCachedTranscriptEntry] = []
        var total = 0
        for var entry in entries.prefix(Self.maxTranscripts) {
            if entry.bytes == nil {
                let url = transcriptFileURL(entry.sessionID, dashboardID: dashboardID, profile: profile)
                entry.bytes = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            }
            let bytes = entry.bytes ?? 0
            if !kept.isEmpty && total + bytes > scopeBytes { break }
            total += bytes
            kept.append(entry)
        }
        return kept
    }

    /// At most `maxSessions` rows. Slots are reserved first for the rows of
    /// `keptSessionIDs` (the retained transcripts, current conversation
    /// first) found in the live catalog or, failing that, in the previous
    /// saved list; the rest are filled from the newest catalog rows. Catalog
    /// rows keep catalog order, followed by reserved rows only the previous
    /// saved list had. A retained transcript whose conversation appears in
    /// either list therefore keeps a sidebar row to open it from.
    private static func cappedSessions(
        _ catalog: [OfflineCachedSession],
        keeping keptSessionIDs: [String],
        previouslySaved: [OfflineCachedSession]
    ) -> [OfflineCachedSession] {
        var selected = Set<String>()
        var savedOnly: [OfflineCachedSession] = []
        for id in keptSessionIDs where selected.count < maxSessions {
            if catalog.contains(where: { $0.id == id }) {
                selected.insert(id)
            } else if let row = previouslySaved.first(where: { $0.id == id }) {
                selected.insert(id)
                savedOnly.append(row)
            }
        }
        for row in catalog where selected.count < maxSessions {
            selected.insert(row.id)
        }
        return catalog.filter { selected.contains($0.id) } + savedOnly
    }

    func removeDashboard(_ dashboardID: UUID) {
        performAndWait {
            noteRemoval()
            let prefix = dashboardID.uuidString.lowercased() + "--"
            forgetMemory { $0.lastPathComponent.hasPrefix(prefix) }
            guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                return
            }
            for file in files where file.lastPathComponent.hasPrefix(prefix) {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    /// Deletes a profile's held rows on one dashboard, as its profile is
    /// deleted (a bot): they are its raw chat history. A read still in flight
    /// for it keeps nothing, as after the other removals.
    func removeHeldRows(dashboardID: UUID, profile: String) {
        performAndWait {
            noteRemoval()
            let prefix = Self.scopeFileStem(dashboardID: dashboardID, profile: profile) + Self.heldRowsInfix
            guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                return
            }
            for file in files where file.lastPathComponent.hasPrefix(prefix) {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    /// Deletes presentation copies across dashboards, preserving accepted
    /// unsent messages even when their dashboard is not loaded in memory.
    func removeSavedChats() {
        performAndWait {
            noteRemoval()
            forgetMemory { _ in true }
            guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                return
            }
            for file in files where !file.lastPathComponent.hasSuffix(Self.pendingSendSuffix) {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    func removeAll() {
        performAndWait {
            noteRemoval()
            forgetMemory { _ in true }
            try? fileManager.removeItem(at: directory)
        }
    }

    /// Every memory copy of a file a wipe removes: the kept copies and
    /// answers, and the indexes and lists kept when the store writes
    /// asynchronously.
    private func forgetMemory(where isGone: (URL) -> Bool) {
        forgetKeptTranscripts(where: isGone)
        memoryLock.withLock {
            keptIndexes = keptIndexes.filter { !isGone($0.key) }
            keptChatLists = keptChatLists.filter { !isGone($0.key) }
            for url in keptAnswerOrder where isGone(url) { forgetAnswerLocked(url) }
        }
    }

    /// The scope's saved Chats list, or nil when none was saved (or it was
    /// saved in another format).
    func loadChatList(dashboardID: UUID, profile: String) -> SavedChatList? {
        let url = chatListFileURL(dashboardID: dashboardID, profile: profile)
        if ioQueue != nil, let kept = memoryLock.withLock({ keptChatLists[url] }) { return kept }
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode(SavedChatList.self, from: data),
              list.version == SavedChatList.formatVersion else {
            return nil
        }
        // One recorded while this was read is the newer one.
        return keepIfAbsent(list, in: \.keptChatLists, at: url)
    }

    /// Replaces the scope's saved Chats list. Its file sits beside the
    /// scope's transcripts, so every wipe that removes those removes it.
    /// When the store writes asynchronously, the list is what memory answers
    /// with at once, and the queue writes it.
    func recordChatList(_ list: SavedChatList, dashboardID: UUID, profile: String) {
        let url = chatListFileURL(dashboardID: dashboardID, profile: profile)
        keepInMemory(list, in: \.keptChatLists, at: url)
        perform { [self] in writeChatList(list, to: url) }
    }

    private func writeChatList(_ list: SavedChatList, to url: URL) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        write(data, to: url)
    }

    /// Keeps a chat's held rows (`writeHeldRows`) on the store's queue, so
    /// a removal after this waits for them and takes them too.
    func recordHeldRows(_ held: HistoryPage.HeldRows, to url: URL) {
        perform { [fileManager] in
            Self.writeHeldRows(held, to: url, fileManager: fileManager)
        }
    }

    // MARK: Kept answers

    /// What a screen last read from Hermes for one route (a Settings page's
    /// config, the model catalog), kept beside the scope's saved chats so
    /// every wipe that takes those takes these: the screen opens on it while
    /// Hermes is asked again (#1533). An answer bigger than this isn't kept,
    /// on disk or in memory.
    static let maxKeptAnswerBytes = 2 * 1024 * 1024
    /// Answers held in memory at most, by count and by their files' bytes;
    /// the least recently used goes first.
    static let maxKeptAnswersInMemory = 32
    static let maxKeptAnswerMemoryBytes = 8 * 1024 * 1024
    static let keptAnswerInfix = ".answer-"

    /// The answer last kept for the route in the scope, or nil: memory's
    /// when it has it (the open profile's are read ahead), else its file's.
    func keptAnswer(_ route: String, dashboardID: UUID, profile: String) -> [String: Any]? {
        let url = keptAnswerFileURL(route, dashboardID: dashboardID, profile: profile)
        let (memory, removals) = memoryLock.withLock { (keptAnswerLocked(at: url), removalCount) }
        if let memory { return memory }
        guard let read = Self.readKeptAnswer(at: url), read.route == route else { return nil }
        return memoryLock.withLock { () -> [String: Any]? in
            // One kept while the file was read is the newer one, and one a
            // removal took meanwhile is gone.
            if let newer = keptAnswerLocked(at: url) { return newer }
            guard removalCount == removals else { return nil }
            keepAnswerLocked(read.answer, at: url, bytes: read.bytes)
            return read.answer
        }
    }

    /// Keeps a screen's answer for the route: memory has it at once, and
    /// the file is written on the store's queue, so a removal after this
    /// takes it too. Memory and the file both leave out credentials
    /// (`withoutCredentials`, keeping the keys of the objects under
    /// `namesUnder`), and one too big to keep leaves memory again once the
    /// queue has measured it.
    func recordAnswer(
        _ answer: [String: Any], route: String, dashboardID: UUID, profile: String, namesUnder names: Set<String> = []
    ) {
        let url = keptAnswerFileURL(route, dashboardID: dashboardID, profile: profile)
        let kept = Self.withoutCredentials(answer, namesUnder: names)
        let generation = memoryLock.withLock { () -> UInt64 in
            keepAnswerLocked(kept, at: url, bytes: nil)
            keptAnswerGeneration &+= 1
            keptAnswerGenerations[url] = keptAnswerGeneration
            return keptAnswerGeneration
        }
        perform { [self] in
            let bytes = writeKeptAnswer(kept, route: route, to: url)
            memoryLock.withLock {
                guard keptAnswerGenerations[url] == generation, keptAnswers[url] != nil else { return }
                guard let bytes else {
                    forgetAnswerLocked(url)
                    return
                }
                keptAnswerBytes[url] = bytes
                trimKeptAnswersLocked()
            }
        }
    }

    /// An answer without its credential-shaped keys, at any depth: any key
    /// (`api_key`, `ssh_key`, `api_keys`), a token, a password, passphrase or
    /// secret, credentials, an Authorization header, auth or a cookie (a
    /// config can hold them, as a custom endpoint's `api_key`), a pair's
    /// value when its name is one of those (`{"name": "Authorization",
    /// "value": …}`), and without the user and password a URL can carry or
    /// a credential in its query (`?api_key=…`). A key shaped like one
    /// whose value is true or false stays: it's a setting about them
    /// (`redact_secrets`); so does a count under a name ending in tokens
    /// (`max_tokens`), or in a pair so named, a `key` naming that count
    /// (`{"key": "max_tokens", "value": 4096}`), and a `key` beside
    /// `is_set`, which names the variable whose presence that reports
    /// (Hermes' rows of keys). No screen shows a credential, and a key to an account
    /// mustn't sit in a file; a name that only looks like one (`sort_key`)
    /// comes back with Hermes' answer. The objects under `namesUnder` are
    /// keyed by names, not values (a schema's `fields`, by config path), so
    /// their keys stay and what's under each is filtered.
    static func withoutCredentials(_ answer: [String: Any], namesUnder names: Set<String> = []) -> [String: Any] {
        let credentialName = ["name", "key"].lazy.compactMap { answer[$0] as? String }.first(where: isCredentialKey)
        // Its `key` names what it reports: a variable's presence (`is_set`),
        // or the count it holds.
        let keyNamesNoCredential = (answer["is_set"].map(isFlag) ?? false)
            || (credentialName.flatMap { name in answer["value"].map { isCount($0, named: name) } } ?? false)
        return answer.reduce(into: [String: Any]()) { kept, entry in
            if names.contains(entry.key), let named = entry.value as? [String: Any] {
                kept[entry.key] = named.mapValues { withoutCredentials(inValue: $0) }
            } else if !holdsCredential(entry.key, entry.value, credentialName: credentialName, keyNamesNoCredential: keyNamesNoCredential) {
                kept[entry.key] = withoutCredentials(inValue: entry.value)
            }
        }
    }

    /// Whether an object's entry is a credential, in an object whose `name`
    /// or `key` is a credential's (`credentialName`), or whose `key` names
    /// a variable's presence (`is_set`) or a count it holds.
    private static func holdsCredential(_ key: String, _ value: Any, credentialName: String?, keyNamesNoCredential: Bool) -> Bool {
        if isFlag(value) { return false }
        if key == "value" { return credentialName.map { !isCount(value, named: $0) } ?? false }
        guard isCredentialKey(key) else { return false }
        return !isCount(value, named: key) && !(key == "key" && keyNamesNoCredential)
    }

    /// A number under a name ending in tokens (`max_tokens`): a count.
    private static func isCount(_ value: Any, named name: String) -> Bool {
        value is NSNumber && name.lowercased().hasSuffix("tokens")
    }

    private static func withoutCredentials(inValue value: Any) -> Any {
        if let object = value as? [String: Any] { return withoutCredentials(object) }
        if let list = value as? [Any] { return list.map { withoutCredentials(inValue: $0) } }
        if let text = value as? String { return withoutURLCredentials(text) }
        return value
    }

    /// Names that end like a credential's, with or without the underscore:
    /// `signing_key`, `apikeys`, `GITHUB_TOKEN`, `access_tokens`,
    /// `clientSecret`, `session_cookie`, `proxy_authorization`, `basic_auth`.
    private static let credentialKeySuffixes = [
        "key", "keys", "token", "tokens", "secret", "secrets", "cookie", "cookies", "auth", "authorization",
    ]
    /// Words that make any name a credential's.
    private static let credentialKeyWords = ["password", "passwd", "passphrase", "credential"]

    static func isCredentialKey(_ key: String) -> Bool {
        let name = key.lowercased().replacingOccurrences(of: "-", with: "_")
        return credentialKeySuffixes.contains { name.hasSuffix($0) }
            || credentialKeyWords.contains { name.contains($0) }
            // `auth_header`, `proxy_auth_user`, but not `author`.
            || name.split(separator: "_").contains("auth")
    }

    /// A JSON true or false, which never holds a credential.
    private static func isFlag(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// The URL without its user and password (`https://user:key@host`) and
    /// a credential in its query (`?api_key=…`), or the text as it was.
    /// Text with a space or a line break in it is prose, or a URL typed
    /// with one, never for the parser: since iOS 17 it takes such text by
    /// escaping the space, and an address in the prose after a URL becomes
    /// the host, everything before it the user and password.
    private static func withoutURLCredentials(_ text: String) -> String {
        guard text.contains("://"), text.contains("@") || text.contains("?") else { return text }
        guard !text.contains(where: \.isWhitespace), var components = URLComponents(string: text) else {
            return withoutUnparsedURLCredentials(text)
        }
        let query = components.queryItems ?? []
        let keptQuery = query.filter { !isCredentialKey($0.name) }
        guard components.user != nil || components.password != nil || keptQuery.count < query.count else { return text }
        components.user = nil
        components.password = nil
        if keptQuery.count < query.count { components.queryItems = keptQuery.isEmpty ? nil : keptQuery }
        return components.string ?? ""
    }

    /// A user and password after a `://`, up to the `@` before the host. A
    /// password may hold a space, as a URL typed with one does, and an `@`
    /// with no space after it before the next `@`: a host never holds a
    /// space, so prose after a URL (an address in it included) stays. A
    /// password never runs past the line's end, nor starts with a port, a
    /// number the host's colon leads to that ends before a word does
    /// (`localhost:8080 and mail me@…`).
    private static let unparsedUserInfo = try! NSRegularExpression(
        pattern: #"(?<=://)(?:[^/?#\s@:]*:(?!\d+(?:[^\w@]|$))[^/?#@\r\n]*|[^/?#\s@]*)(?:@[^/?#@\s]*)*@"#
    )
    /// A query's name, with its `=`.
    private static let unparsedQueryName = try! NSRegularExpression(pattern: #"(?<=[?&])([^=&#\s]+)="#)

    /// Text with a space in it, or that the URL parser rejects, loses the
    /// same by pattern: any user and password, and a credential's value in
    /// a query, its name left. That value runs to the next `&` or `#`, or
    /// the end of the line, a space in it included.
    private static func withoutUnparsedURLCredentials(_ text: String) -> String {
        var kept = unparsedUserInfo.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
        )
        let names = unparsedQueryName.matches(in: kept, range: NSRange(kept.startIndex..., in: kept))
        for match in names.reversed() {
            guard let name = Range(match.range(at: 1), in: kept), isCredentialKey(String(kept[name])),
                  let item = Range(match.range, in: kept) else { continue }
            let end = kept[item.upperBound...].firstIndex { $0 == "&" || $0 == "#" || $0.isNewline } ?? kept.endIndex
            kept.removeSubrange(item.upperBound..<end)
        }
        return kept
    }

    /// Deletes a profile's kept answers on one dashboard, as its profile is
    /// deleted (a bot), so a new one of the same name doesn't open on them.
    func removeKeptAnswers(dashboardID: UUID, profile: String) {
        performAndWait {
            noteRemoval()
            let prefix = Self.scopeFileStem(dashboardID: dashboardID, profile: profile) + Self.keptAnswerInfix
            forgetMemory { $0.lastPathComponent.hasPrefix(prefix) }
            guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                return
            }
            for file in files where file.lastPathComponent.hasPrefix(prefix) {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    /// Writes the answer's file and returns its size, or removes the file
    /// and returns nil when the answer is too big to keep or the write
    /// failed (a full disk).
    private func writeKeptAnswer(_ answer: [String: Any], route: String, to url: URL) -> Int? {
        let object: [String: Any] = ["route": route, "answer": answer]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              data.count <= Self.maxKeptAnswerBytes,
              write(data, to: url) else {
            // Not kept: an older answer mustn't open the screen next time.
            try? fileManager.removeItem(at: url)
            return nil
        }
        return data.count
    }

    /// Reads the scope's kept answers into memory, on the store's queue,
    /// into room memory has free: one read ahead never pushes out an answer
    /// a screen used.
    private func readKeptAnswersAhead(scope: String) {
        let prefix = scope + Self.keptAnswerInfix
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            // Named as `keptAnswerFileURL` names it, so a screen finds it.
            let url = directory.appendingPathComponent(file.lastPathComponent)
            guard memoryLock.withLock({ fitsAnswerAheadLocked(url, bytes: 0) }),
                  let read = Self.readKeptAnswer(at: url) else { continue }
            memoryLock.withLock {
                guard fitsAnswerAheadLocked(url, bytes: read.bytes) else { return }
                keptAnswers[url] = read.answer
                keptAnswerBytes[url] = read.bytes
                // Least recently used, so it goes before any answer used.
                keptAnswerOrder.insert(url, at: 0)
            }
        }
    }

    /// Under `memoryLock`.
    private func fitsAnswerAheadLocked(_ url: URL, bytes: Int) -> Bool {
        waitingRemovals == 0
            && keptAnswers[url] == nil
            && keptAnswerOrder.count < Self.maxKeptAnswersInMemory
            && keptAnswerBytes.values.reduce(0, +) + bytes <= Self.maxKeptAnswerMemoryBytes
    }

    private static func readKeptAnswer(at url: URL) -> (route: String, answer: [String: Any], bytes: Int)? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let route = object["route"] as? String,
              let answer = object["answer"] as? [String: Any] else { return nil }
        return (route, answer, data.count)
    }

    /// Memory's answer for the file, now the most recently used. Under
    /// `memoryLock`.
    private func keptAnswerLocked(at url: URL) -> [String: Any]? {
        guard let answer = keptAnswers[url] else { return nil }
        keptAnswerOrder.removeAll { $0 == url }
        keptAnswerOrder.append(url)
        return answer
    }

    /// Under `memoryLock`. `bytes` is the answer's file size, nil until the
    /// queue has written it.
    private func keepAnswerLocked(_ answer: [String: Any], at url: URL, bytes: Int?) {
        keptAnswers[url] = answer
        keptAnswerBytes[url] = bytes
        keptAnswerOrder.removeAll { $0 == url }
        keptAnswerOrder.append(url)
        trimKeptAnswersLocked()
    }

    /// Under `memoryLock`: drops the least recently used answers until
    /// memory is within its count and bytes, keeping the newest.
    private func trimKeptAnswersLocked() {
        while let oldest = keptAnswerOrder.first, keptAnswerOrder.count > 1,
              keptAnswerOrder.count > Self.maxKeptAnswersInMemory
                || keptAnswerBytes.values.reduce(0, +) > Self.maxKeptAnswerMemoryBytes {
            forgetAnswerLocked(oldest)
        }
    }

    /// Under `memoryLock`.
    private func forgetAnswerLocked(_ url: URL) {
        keptAnswers.removeValue(forKey: url)
        keptAnswerBytes.removeValue(forKey: url)
        keptAnswerGenerations.removeValue(forKey: url)
        keptAnswerOrder.removeAll { $0 == url }
    }

    /// A route's kept answer, named by a hash of the route, which can be
    /// any text.
    func keptAnswerFileURL(_ route: String, dashboardID: UUID, profile: String) -> URL {
        let name = SHA256.hash(data: Data(route.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(Self.scopeFileStem(dashboardID: dashboardID, profile: profile))\(Self.keptAnswerInfix)\(name).json")
    }

    // MARK: Reading ahead

    /// Reads ahead, on the store's queue, what opening something in a scope
    /// shows first: its saved Chats list, and the copies of the chats opened
    /// there last, up to `transcripts`, so opening one of them shows its
    /// copy from memory instead of reading its file on the tap. Once per
    /// scope until the next removal, unless asked for more copies than
    /// before. A copy already in memory, or one whose file is larger than
    /// `maxPrefetchedTranscriptBytes`, isn't read, and a copy read ahead only
    /// takes room memory has free, never a place a chat opened since holds.
    /// With `answers`, the scope's kept answers too, so its screens open on
    /// them without reading a file. Asynchronous mode only.
    func prefetch(dashboardID: UUID, profile: String, transcripts limit: Int, answers: Bool = false) {
        guard let ioQueue else { return }
        let scope = Self.scopeFileStem(dashboardID: dashboardID, profile: profile)
        let (readsCopies, readsAnswers) = memoryLock.withLock { () -> (Bool, Bool) in
            let copies = limit > prefetchedLimits[scope, default: -1]
            if copies { prefetchedLimits[scope] = limit }
            return (copies, answers && answersPrefetched.insert(scope).inserted)
        }
        guard readsCopies || readsAnswers else { return }
        ioQueue.async { [self] in
            guard memoryLock.withLock({ waitingRemovals == 0 }) else { return }
            if readsAnswers { readKeptAnswersAhead(scope: scope) }
            guard readsCopies else { return }
            _ = loadChatList(dashboardID: dashboardID, profile: profile)
            guard limit > 0, let snapshot = load(dashboardID: dashboardID, profile: profile) else { return }
            for entry in snapshot.transcripts.prefix(limit)
            where (entry.bytes ?? 0) <= Self.maxPrefetchedTranscriptBytes {
                // A copy a turn, so a removal or a write waits for one read
                // at most.
                ioQueue.async { [self] in
                    prefetchTranscript(entry, dashboardID: dashboardID, profile: profile)
                }
            }
        }
    }

    private func prefetchTranscript(_ entry: OfflineCachedTranscriptEntry, dashboardID: UUID, profile: String) {
        let url = transcriptFileURL(entry.sessionID, dashboardID: dashboardID, profile: profile)
        guard memoryLock.withLock({ fitsAheadLocked(url, bytes: entry.bytes ?? 0) }),
              let data = try? Data(contentsOf: url),
              // An older entry has no size: its file says.
              data.count <= Self.maxPrefetchedTranscriptBytes,
              let transcript = try? JSONDecoder().decode(OfflineCachedTranscript.self, from: data),
              transcript.sessionID == entry.sessionID else { return }
        memoryLock.withLock {
            guard fitsAheadLocked(url, bytes: data.count) else { return }
            keptTranscripts[url] = (transcript, data.count)
            keptTranscriptBytes += data.count
            // Least recently used, so it goes before any copy opened.
            keptTranscriptOrder.insert(url, at: 0)
        }
    }

    /// Whether a copy read ahead fits in memory without pushing a kept one
    /// out, with no removal waiting. Under `memoryLock`.
    private func fitsAheadLocked(_ url: URL, bytes: Int) -> Bool {
        waitingRemovals == 0
            && keptTranscripts[url] == nil
            && keptTranscriptOrder.count < Self.maxKeptTranscripts
            && keptTranscriptBytes + bytes <= Self.maxKeptTranscriptBytes
    }

    /// Keeps a message waiting for its chat, so a launch after the app was
    /// stopped can put it back in its chat's draft. Its file sits beside its
    /// scope's, so the same wipes remove it. Intentionally synchronous, unlike
    /// the saved copies: recording finishes before the composer clears its
    /// submitted draft.
    @discardableResult
    func recordPendingSend(_ pending: PendingComposerSend) -> Bool {
        guard let data = try? JSONEncoder().encode(pending) else { return false }
        guard write(data, to: pendingSendFileURL(dashboardID: pending.dashboardID, profile: pending.profile, id: pending.id)) else { return false }
        // Migrate the earlier single-file format only after the new copy is safe.
        let legacy = pendingSendFileURL(dashboardID: pending.dashboardID, profile: pending.profile)
        if let data = try? Data(contentsOf: legacy),
           let old = try? JSONDecoder().decode(PendingComposerSend.self, from: data),
           old.id == pending.id {
            try? fileManager.removeItem(at: legacy)
        }
        return true
    }

    /// The messages an earlier run left waiting on this dashboard.
    func loadPendingSends(dashboardID: UUID) -> [PendingComposerSend] {
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        let prefix = dashboardID.uuidString.lowercased() + "--"
        var seen: Set<UUID> = []
        return files
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.hasSuffix(Self.pendingSendSuffix) }
            // Per-message filenames sort before the legacy scope filename.
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { file -> PendingComposerSend? in
                guard let data = try? Data(contentsOf: file),
                      let pending = try? JSONDecoder().decode(PendingComposerSend.self, from: data) else { return nil }
                // Its own scope's file: one copied under another name is left.
                let expected = pendingSendFileURL(dashboardID: dashboardID, profile: pending.profile, id: pending.id)
                let legacy = pendingSendFileURL(dashboardID: dashboardID, profile: pending.profile)
                guard pending.dashboardID == dashboardID,
                      (file.lastPathComponent == expected.lastPathComponent || file.lastPathComponent == legacy.lastPathComponent),
                      seen.insert(pending.id).inserted else { return nil }
                return pending
            }
            .sorted { $0.queuedAt < $1.queuedAt }
    }

    /// Removes only this message, including an earlier single-file copy.
    func removePendingSend(id: UUID, dashboardID: UUID, profile: String) {
        for url in [
            pendingSendFileURL(dashboardID: dashboardID, profile: profile, id: id),
            pendingSendFileURL(dashboardID: dashboardID, profile: profile),
        ] {
            guard let data = try? Data(contentsOf: url),
                  let pending = try? JSONDecoder().decode(PendingComposerSend.self, from: data),
                  pending.id == id, pending.dashboardID == dashboardID, pending.profile == profile else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    @discardableResult
    private func write(_ snapshot: OfflineChatSnapshot, dashboardID: UUID, profile: String) -> Bool {
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        let url = fileURL(dashboardID: dashboardID, profile: profile)
        guard write(data, to: url) else { return false }
        keepInMemory(snapshot, in: \.keptIndexes, at: url)
        return true
    }

    /// The file's size when it was written, else nil.
    private func write(_ transcript: OfflineCachedTranscript, dashboardID: UUID, profile: String) -> Int? {
        guard let data = try? JSONEncoder().encode(transcript) else { return nil }
        let url = transcriptFileURL(transcript.sessionID, dashboardID: dashboardID, profile: profile)
        guard write(data, to: url) else { return nil }
        keep(transcript, bytes: data.count, at: url)
        return data.count
    }

    @discardableResult
    private func write(_ data: Data, to url: URL) -> Bool {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var directoryURL = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directoryURL.setResourceValues(values)
            try data.write(to: url, options: Self.writeOptions)
            return true
        } catch {
            // Display caches are best effort. Pending sends check the result
            // before accepting the user's words and clearing their draft.
            return false
        }
    }

    /// The scope's index.
    func fileURL(dashboardID: UUID, profile: String) -> URL {
        directory.appendingPathComponent("\(Self.scopeFileStem(dashboardID: dashboardID, profile: profile)).json")
    }

    /// One saved conversation's rows, named by a hash of its id, which can
    /// be any text.
    func transcriptFileURL(_ sessionID: String, dashboardID: UUID, profile: String) -> URL {
        let name = SHA256.hash(data: Data(sessionID.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(Self.scopeFileStem(dashboardID: dashboardID, profile: profile)).chat-\(name).json")
    }

    /// The newest page of a chat's raw rows as Hermes last sent it, with
    /// their fingerprints (#1525), named by a hash of the id it was read by.
    func heldRowsFileURL(_ sessionID: String, dashboardID: UUID, profile: String) -> URL {
        let name = SHA256.hash(data: Data(sessionID.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(Self.scopeFileStem(dashboardID: dashboardID, profile: profile))\(Self.heldRowsInfix)\(name).json")
    }

    static let heldRowsInfix = ".rows-"
    /// The held rows' own budget per scope, beside the copies' `maxScopeBytes`.
    static let maxHeldRowsBytes = 32 * 1024 * 1024

    /// A chat's held rows, or nil when none are kept for it. Read off the
    /// main actor: a page of rows can be large.
    static func loadHeldRows(at url: URL, sessionID: String) -> HistoryPage.HeldRows? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["session_id"] as? String == sessionID,
              let digests = object["digests"] as? [String],
              let rows = object["rows"] as? [Any],
              digests.count == rows.count else { return nil }
        return HistoryPage.HeldRows(sessionID: sessionID, digests: digests, rows: rows)
    }

    /// Keeps a chat's held rows, then lets go of the scope's oldest beyond
    /// `maxTranscripts` files or `maxHeldRowsBytes`, as the saved copies are
    /// bounded (the newest always stays). Best effort, like the copies.
    static func writeHeldRows(_ held: HistoryPage.HeldRows, to url: URL, fileManager: FileManager = .default) {
        let object: [String: Any] = ["session_id": held.sessionID, "digests": held.digests, "rows": held.rows]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let directory = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var directoryURL = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directoryURL.setResourceValues(values)
            try data.write(to: url, options: writeOptions)
        } catch {
            return
        }
        guard let infix = url.lastPathComponent.range(of: heldRowsInfix) else { return }
        let prefix = String(url.lastPathComponent[..<infix.upperBound])
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }
        let held = files
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .map { file in
                (file, (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
        var total = 0
        for (index, (file, _)) in held.enumerated() {
            let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += bytes
            if index >= maxTranscripts || (index > 0 && total > maxHeldRowsBytes) {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    func chatListFileURL(dashboardID: UUID, profile: String) -> URL {
        directory.appendingPathComponent("\(Self.scopeFileStem(dashboardID: dashboardID, profile: profile)).list.json")
    }

    private static let pendingSendSuffix = ".pending-send.json"

    func pendingSendFileURL(dashboardID: UUID, profile: String, id: UUID? = nil) -> URL {
        let message = id.map { "." + $0.uuidString.lowercased() } ?? ""
        return directory.appendingPathComponent("\(Self.scopeFileStem(dashboardID: dashboardID, profile: profile))\(message)\(Self.pendingSendSuffix)")
    }

    /// "<dashboard>--<profile>": the dashboard prefix is what
    /// `removeDashboard` matches. A profile's "." is percent-encoded, so no
    /// profile's index can be named like another's list or chat file.
    private static func scopeFileStem(dashboardID: UUID, profile: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safeProfile = profile.addingPercentEncoding(withAllowedCharacters: allowed) ?? "default"
        return "\(dashboardID.uuidString.lowercased())--\(safeProfile)"
    }
}
