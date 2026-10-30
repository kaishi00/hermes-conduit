//
//  OfflineChatCache.swift
//  Conduit
//
//  Read-only on-disk copy of recently opened conversations (#99), so a cold
//  launch (after iOS reclaimed the process, or with the server unreachable)
//  can still show the last chat, and of the Chats list as it was last shown,
//  so a launch opens to the real list while it connects.
//
//  The copy is PRESENTATION ONLY. It never enters `AppState.messages` or
//  `AppState.sessions`, so nothing that decides resume, pagination,
//  conversation selection, bot-vs-workspace routing, or pending
//  approval/clarify cards can read it. The first authoritative answer from
//  the server replaces it wholesale.
//

import CryptoKit
import Foundation

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

/// What the chat surface presents while the server has not answered yet.
struct OfflineChatPresentation: Equatable {
    let dashboardID: UUID
    let profile: String
    /// The scope's index: its saved conversations, without their rows.
    let snapshot: OfflineChatSnapshot
    /// The saved conversation on screen, with its rows.
    let displayedTranscript: OfflineCachedTranscript?
    /// Its rows as the live transcript has them, each turn's run of steps
    /// placed so it draws as one card. Worked out once per displayed
    /// conversation, not on every render.
    let displayedRows: [ChatMessageScrollTarget]
    /// A chat tapped in the saved list before the live one landed. Its
    /// saved copy (or the wait for one) shows over any transcript still on
    /// screen until that chat's own open lands.
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
        var rows = ChatMessageScrollTargetCache()
        rows.update(for: displayedTranscript?.messages.map(\.chatMessage) ?? [])
        self.displayedRows = rows.targets
        self.picked = picked
    }

    var displayedSessionID: String? { displayedTranscript?.sessionID }

    var displayedMessages: [ChatMessage] { displayedRows.map(\.message) }
}

/// File-backed store. Per (dashboard, profile): an index, a file for each
/// saved conversation's rows and one for the Chats list, all JSON written
/// atomically with complete-until-first-user-authentication protection and
/// excluded from backups.
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

    /// Complete-until-first-user-authentication: unreadable from a device
    /// that has not been unlocked since boot, while still writable at the
    /// background transition after the device locks.
    static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    private let directory: URL
    private let fileManager: FileManager
    /// The copies last read or written, by file, so a chat opened again
    /// shows its copy without reading and decoding it on the tap (#1352).
    private var keptTranscripts: [URL: OfflineCachedTranscript] = [:]
    private var keptTranscriptOrder: [URL] = []
    static let maxKeptTranscripts = 8

    private let scopeBytes: Int

    init(directory: URL, fileManager: FileManager = .default, scopeBytes: Int = OfflineChatCacheStore.maxScopeBytes) {
        self.directory = directory
        self.fileManager = fileManager
        self.scopeBytes = scopeBytes
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
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let snapshot = try? JSONDecoder().decode(OfflineChatSnapshot.self, from: data),
           snapshot.version == OfflineChatSnapshot.formatVersion {
            return snapshot
        }
        return moveFirstFormat(data, dashboardID: dashboardID, profile: profile)
    }

    /// One saved conversation with its rows, or nil when it has none.
    func loadTranscript(_ sessionID: String, dashboardID: UUID, profile: String) -> OfflineCachedTranscript? {
        let url = transcriptFileURL(sessionID, dashboardID: dashboardID, profile: profile)
        if let kept = keptTranscripts[url] {
            keep(kept, at: url)
            return kept
        }
        guard let data = try? Data(contentsOf: url),
              let transcript = try? JSONDecoder().decode(OfflineCachedTranscript.self, from: data),
              transcript.sessionID == sessionID else {
            return nil
        }
        keep(transcript, at: url)
        return transcript
    }

    private func keep(_ transcript: OfflineCachedTranscript, at url: URL) {
        keptTranscripts[url] = transcript
        keptTranscriptOrder.removeAll { $0 == url }
        keptTranscriptOrder.append(url)
        while keptTranscriptOrder.count > Self.maxKeptTranscripts {
            keptTranscripts[keptTranscriptOrder.removeFirst()] = nil
        }
    }

    /// Kept copies go with their files.
    private func forgetKeptTranscripts(where isGone: (URL) -> Bool) {
        keptTranscriptOrder.removeAll(where: isGone)
        keptTranscripts = keptTranscripts.filter { !isGone($0.key) }
    }

    /// A scope saved in the first format moves to a file per conversation
    /// the first time it is read, so an update doesn't lose the copies.
    private func moveFirstFormat(_ data: Data, dashboardID: UUID, profile: String) -> OfflineChatSnapshot? {
        guard let old = try? JSONDecoder().decode(FirstFormatOfflineChatSnapshot.self, from: data),
              old.version == 1 else { return nil }
        let moved = old.transcripts.filter { write($0, dashboardID: dashboardID, profile: profile) != nil }
        let snapshot = OfflineChatSnapshot(
            lastSessionID: old.lastSessionID,
            sessions: old.sessions,
            transcripts: moved.map(OfflineCachedTranscriptEntry.init)
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
        let rows = messages.compactMap(OfflineCachedMessage.init)
            .suffix(Self.maxMessagesPerTranscript)
        guard !rows.isEmpty else { return }
        var snapshot = load(dashboardID: dashboardID, profile: profile)
            ?? OfflineChatSnapshot(lastSessionID: nil, sessions: [], transcripts: [])
        let catalogRows = sessions
            .filter { $0.source != .cron && !$0.isArchived }
            .map(OfflineCachedSession.init)
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
        let transcript = OfflineCachedTranscript(sessionID: sessionID, title: title, savedAt: now, messages: Array(rows))
        // Its rows land first, so the index never lists a copy that isn't there.
        guard let bytes = write(transcript, dashboardID: dashboardID, profile: profile) else { return }
        snapshot.transcripts.removeAll { $0.sessionID == sessionID || allIdentities.contains($0.sessionID) }
        snapshot.transcripts.insert(OfflineCachedTranscriptEntry(transcript, bytes: bytes), at: 0)
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
        guard write(snapshot, dashboardID: dashboardID, profile: profile) else { return }
        removeUnlistedTranscripts(snapshot, dashboardID: dashboardID, profile: profile)
    }

    /// A deleted conversation leaves the scope: its saved rows under any of
    /// `sessionIDs` (or a saved row's aliases), its row in the saved session
    /// list and the saved Chats list, and its place as the chat a launch
    /// opens to. The index is rewritten before the files go, as `record`
    /// does, so it never lists a copy that isn't there.
    func removeTranscripts(sessionIDs: Set<String>, dashboardID: UUID, profile: String) {
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
            recordChatList(list, dashboardID: dashboardID, profile: profile)
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
        let prefix = dashboardID.uuidString.lowercased() + "--"
        forgetKeptTranscripts { $0.lastPathComponent.hasPrefix(prefix) }
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            try? fileManager.removeItem(at: file)
        }
    }

    /// Deletes presentation copies across dashboards, preserving accepted
    /// unsent messages even when their dashboard is not loaded in memory.
    func removeSavedChats() {
        forgetKeptTranscripts { _ in true }
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where !file.lastPathComponent.hasSuffix(Self.pendingSendSuffix) {
            try? fileManager.removeItem(at: file)
        }
    }

    func removeAll() {
        forgetKeptTranscripts { _ in true }
        try? fileManager.removeItem(at: directory)
    }

    /// The scope's saved Chats list, or nil when none was saved (or it was
    /// saved in another format).
    func loadChatList(dashboardID: UUID, profile: String) -> SavedChatList? {
        guard let data = try? Data(contentsOf: chatListFileURL(dashboardID: dashboardID, profile: profile)),
              let list = try? JSONDecoder().decode(SavedChatList.self, from: data),
              list.version == SavedChatList.formatVersion else {
            return nil
        }
        return list
    }

    /// Replaces the scope's saved Chats list. Its file sits beside the
    /// scope's transcripts, so every wipe that removes those removes it.
    func recordChatList(_ list: SavedChatList, dashboardID: UUID, profile: String) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        write(data, to: chatListFileURL(dashboardID: dashboardID, profile: profile))
    }

    /// Keeps a message waiting for its chat, so a launch after the app was
    /// stopped can put it back in its chat's draft. Its file sits beside its
    /// scope's, so the same wipes remove it. Intentionally synchronous, like
    /// the saved-chat cache: recording finishes before the composer clears
    /// its submitted draft.
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
        return write(data, to: fileURL(dashboardID: dashboardID, profile: profile))
    }

    /// The file's size when it was written, else nil.
    private func write(_ transcript: OfflineCachedTranscript, dashboardID: UUID, profile: String) -> Int? {
        guard let data = try? JSONEncoder().encode(transcript) else { return nil }
        let url = transcriptFileURL(transcript.sessionID, dashboardID: dashboardID, profile: profile)
        guard write(data, to: url) else { return nil }
        keep(transcript, at: url)
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
    /// `maxTranscripts`, as the saved copies are bounded. Best effort, like
    /// the copies.
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
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let held = files
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .map { file in
                (file, (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
        for (file, _) in held.dropFirst(maxTranscripts) {
            try? fileManager.removeItem(at: file)
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
