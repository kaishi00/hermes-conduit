//
//  OfflineChatCache.swift
//  Conduit
//
//  Read-only on-disk copy of recently opened conversations (#99), so a cold
//  launch (after iOS reclaimed the process, or with the server unreachable)
//  can still show the last chat.
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

    /// Relative to now when the row carried a machine-readable instant (the
    /// saved `updatedLabel` was formatted at save time and goes stale).
    @MainActor
    func displayUpdatedLabel(now: Date = Date()) -> String {
        // Persisted input: anything outside 2000 ... now + 1 day is not a
        // real activity instant, so keep the saved label.
        guard let lastActivityAt,
              lastActivityAt.isFinite,
              lastActivityAt >= 946_684_800,
              lastActivityAt <= now.timeIntervalSince1970 + 86_400 else { return updatedLabel }
        return Self.relativeFormatter.localizedString(for: Date(timeIntervalSince1970: lastActivityAt), relativeTo: now)
    }

    /// One formatter for every saved row (the sidebar renders up to
    /// `maxSessions` of them). Main-actor confined: formatters are not
    /// thread-safe, and only the sidebar reads it. Its locale is the one
    /// current at first use.
    @MainActor
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

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

    init(dashboardID: UUID, profile: String, snapshot: OfflineChatSnapshot, displayedSessionID: String?) {
        self.dashboardID = dashboardID
        self.profile = profile
        self.snapshot = snapshot
        self.displayedSessionID = displayedSessionID
        self.displayedMessages = Self.messages(in: snapshot, for: displayedSessionID)
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

    private func write(_ snapshot: OfflineChatSnapshot, dashboardID: UUID, profile: String) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var directoryURL = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directoryURL.setResourceValues(values)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(
                to: fileURL(dashboardID: dashboardID, profile: profile),
                options: Self.writeOptions
            )
        } catch {
            // Best effort: the cache is a convenience copy, never a source of
            // truth, so a failed write only means a colder next launch.
        }
    }

    func fileURL(dashboardID: UUID, profile: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safeProfile = profile.addingPercentEncoding(withAllowedCharacters: allowed) ?? "default"
        return directory.appendingPathComponent(
            "\(dashboardID.uuidString.lowercased())--\(safeProfile).json"
        )
    }
}
