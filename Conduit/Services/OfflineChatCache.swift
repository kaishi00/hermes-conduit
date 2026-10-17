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
    }

    var chatMessage: ChatMessage {
        ChatMessage(
            id: id,
            role: role,
            content: content,
            timestamp: timestamp,
            author: author,
            reasoning: reasoning,
            tool: tool,
            displayKind: displayKind
        )
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

struct OfflineCachedTranscript: Codable, Equatable {
    let sessionID: String
    let title: String
    let savedAt: Date
    let messages: [OfflineCachedMessage]
}

/// Everything cached for one (dashboard, profile) scope.
struct OfflineChatSnapshot: Codable, Equatable {
    static let formatVersion = 1

    var version: Int = Self.formatVersion
    var lastSessionID: String?
    var sessions: [OfflineCachedSession]
    /// Most recently opened first.
    var transcripts: [OfflineCachedTranscript]

    func transcript(for sessionID: String) -> OfflineCachedTranscript? {
        transcripts.first { $0.sessionID == sessionID }
    }
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
    func relabeled() -> SavedChatList {
        func relabel(_ row: SessionSummary) -> SessionSummary {
            guard let instant = row.lastActivityAt else { return row }
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
    let snapshot: OfflineChatSnapshot
    var displayedSessionID: String? {
        didSet { displayedMessages = Self.messages(in: snapshot, for: displayedSessionID) }
    }
    /// Mapped once per displayed conversation, not on every render.
    private(set) var displayedMessages: [ChatMessage]
    /// A chat tapped in the saved list before the live one landed. Its
    /// saved copy (or the wait for one) shows over any transcript still on
    /// screen until that chat's own open lands.
    var picked: PickedChat?

    struct PickedChat: Equatable {
        /// The row's title, for the header.
        let title: String
        /// Every id the row answers to, so the open it leads to is known.
        var sessionIDs: Set<String>
    }

    var isPickedChat: Bool { picked != nil }

    init(
        dashboardID: UUID,
        profile: String,
        snapshot: OfflineChatSnapshot,
        displayedSessionID: String?,
        picked: PickedChat? = nil
    ) {
        self.dashboardID = dashboardID
        self.profile = profile
        self.snapshot = snapshot
        self.displayedSessionID = displayedSessionID
        self.displayedMessages = Self.messages(in: snapshot, for: displayedSessionID)
        self.picked = picked
    }

    var displayedTranscript: OfflineCachedTranscript? {
        displayedSessionID.flatMap(snapshot.transcript(for:))
    }

    private static func messages(in snapshot: OfflineChatSnapshot, for sessionID: String?) -> [ChatMessage] {
        sessionID.flatMap(snapshot.transcript(for:))?.messages.map(\.chatMessage) ?? []
    }
}

/// File-backed store. One JSON file per (dashboard, profile), written
/// atomically with complete-until-first-user-authentication protection and
/// excluded from backups.
final class OfflineChatCacheStore {
    static let maxMessagesPerTranscript = 120
    static let maxTranscripts = 5
    static let maxSessions = 60

    /// Complete-until-first-user-authentication: unreadable from a device
    /// that has not been unlocked since boot, while still writable at the
    /// background transition after the device locks.
    static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("OfflineChatCache", isDirectory: true)
    }

    func load(dashboardID: UUID, profile: String) -> OfflineChatSnapshot? {
        let url = fileURL(dashboardID: dashboardID, profile: profile)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(OfflineChatSnapshot.self, from: data),
              snapshot.version == OfflineChatSnapshot.formatVersion else {
            return nil
        }
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
        snapshot.transcripts.removeAll { $0.sessionID == sessionID || allIdentities.contains($0.sessionID) }
        snapshot.transcripts.insert(
            OfflineCachedTranscript(sessionID: sessionID, title: title, savedAt: now, messages: Array(rows)),
            at: 0
        )
        snapshot.transcripts = Array(snapshot.transcripts.prefix(Self.maxTranscripts))
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
        write(snapshot, dashboardID: dashboardID, profile: profile)
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
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        let prefix = dashboardID.uuidString.lowercased() + "--"
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            try? fileManager.removeItem(at: file)
        }
    }

    func removeAll() {
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

    private func write(_ snapshot: OfflineChatSnapshot, dashboardID: UUID, profile: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        write(data, to: fileURL(dashboardID: dashboardID, profile: profile))
    }

    private func write(_ data: Data, to url: URL) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var directoryURL = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directoryURL.setResourceValues(values)
            try data.write(to: url, options: Self.writeOptions)
        } catch {
            // Best effort: the cache is a convenience copy, never a source of
            // truth, so a failed write only means a colder next launch.
        }
    }

    func fileURL(dashboardID: UUID, profile: String) -> URL {
        directory.appendingPathComponent("\(Self.scopeFileStem(dashboardID: dashboardID, profile: profile)).json")
    }

    func chatListFileURL(dashboardID: UUID, profile: String) -> URL {
        directory.appendingPathComponent("\(Self.scopeFileStem(dashboardID: dashboardID, profile: profile)).list.json")
    }

    /// "<dashboard>--<profile>": the dashboard prefix is what
    /// `removeDashboard` matches. A profile's "." is percent-encoded, so no
    /// profile's transcript file can be named like another's list file.
    private static func scopeFileStem(dashboardID: UUID, profile: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safeProfile = profile.addingPercentEncoding(withAllowedCharacters: allowed) ?? "default"
        return "\(dashboardID.uuidString.lowercased())--\(safeProfile)"
    }
}
