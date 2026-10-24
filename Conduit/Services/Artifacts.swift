import Foundation

/// Something a chat produced that the user may want to open again: a file
/// Hermes sent or wrote, an HTML page it drew, a file the user attached, or a
/// link in a reply. The host's notifier plugin lists them (plugin 0.40+,
/// capability `artifacts`) from the profile's session store.
struct ArtifactItem: Identifiable, Equatable, Hashable {
    enum Kind: String {
        case image, video, audio, page, document, file, link
    }

    enum Source: String {
        /// Sent with a `MEDIA:` tag.
        case delivered
        /// Drawn in place with `::preview{file=…}`.
        case preview
        /// Written by one of Hermes' tools.
        case written
        /// A file the user sent.
        case attached
        /// A web link in a reply.
        case link
    }

    let kind: Kind
    let source: Source
    let name: String
    /// The file on the Hermes host, for everything but links.
    let path: String?
    let url: URL?
    let host: String?
    /// False when the host no longer has the file.
    let exists: Bool
    let size: Int64?
    let sessionID: String
    let sessionTitle: String
    /// Hermes' `messages.id` of the message it came from.
    let messageID: Int
    let date: Date
    /// The profile whose store listed it, when that isn't the profile in
    /// use: a bot's (a Bot Chat is kept in the bot's own profile), or
    /// another profile All shows. Its files are read through that profile.
    var otherProfile: String?
    /// That profile's name for the detail line, or the bot's.
    var otherProfileLabel: String?
    /// From a bot's Bot Chat: it goes by the bot's name and opens the way
    /// Bots opens it.
    var isBotChat = false

    /// One path or URL is one artifact, listed at its newest mention, even
    /// when several chats sent it (the host lists it the same way).
    var id: String { path ?? url?.absoluteString ?? "\(messageID)|\(name)" }

    var isVisual: Bool { kind == .image || kind == .video }

    init?(_ raw: [String: Any]) {
        guard let kindValue = raw["kind"] as? String, let kind = Kind(rawValue: kindValue),
              let sourceValue = raw["source"] as? String, let source = Source(rawValue: sourceValue),
              let sessionID = raw["session_id"] as? String, !sessionID.isEmpty,
              let messageID = raw["message_id"] as? Int,
              let timestamp = (raw["timestamp"] as? NSNumber)?.doubleValue else { return nil }
        let path = (raw["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let url = (raw["url"] as? String).flatMap(URL.init(string:)).flatMap { url -> URL? in
            guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
            return url
        }
        // A file needs its path; a link needs a web address.
        if source == .link {
            guard url != nil else { return nil }
        } else {
            guard path != nil else { return nil }
        }
        self.kind = kind
        self.source = source
        let name = (raw["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = name.isEmpty ? (path.map { ($0 as NSString).lastPathComponent } ?? url?.host() ?? "") : name
        self.path = path
        self.url = url
        self.host = raw["host"] as? String
        // A link has no file to miss.
        self.exists = source == .link || raw["exists"] as? Bool ?? true
        self.size = (raw["size"] as? NSNumber)?.int64Value
        self.sessionID = sessionID
        self.sessionTitle = (raw["session_title"] as? String) ?? ""
        self.messageID = messageID
        self.date = Date(timeIntervalSince1970: timestamp)
    }
}

/// The chips over an artifact list.
enum ArtifactFilter: String, CaseIterable, Identifiable {
    case all, images, pages, files, links

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return AppLocalization.string("All")
        case .images: return AppLocalization.string("Images")
        case .pages: return AppLocalization.string("Pages")
        case .files: return AppLocalization.string("Files")
        case .links: return AppLocalization.string("Links")
        }
    }

    /// The host's `kind` filter; nil lists everything.
    var hostKind: String? { self == .all ? nil : rawValue }

    func includes(_ kind: ArtifactItem.Kind) -> Bool {
        switch self {
        case .all: return true
        case .images: return kind == .image || kind == .video
        case .pages: return kind == .page
        case .files: return kind == .audio || kind == .document || kind == .file
        case .links: return kind == .link
        }
    }
}

/// A day's artifacts, under one heading.
struct ArtifactDay: Identifiable {
    let day: Date
    let items: [ArtifactItem]

    var id: Date { day }
}

/// One page of artifacts and where the next one starts.
struct ArtifactPage: Equatable {
    let items: [ArtifactItem]
    /// Nil once the history is read to its start.
    let nextBefore: Int?
}

/// A session store an artifacts list reads: the profile in use, another
/// profile All shows, or a bot's Bot Chat, which is kept in the bot's own
/// profile.
struct ArtifactSource: Equatable {
    let profile: String
    /// The chat's ids; empty reads every chat in the profile.
    let sessionIDs: [String]
    /// The profile's name, or the bot's; nil for the profile in use.
    var label: String?
    var isBotChat = false
}

/// Several stores' pages as one list, newest first. Each store pages from
/// its own cursor, so a row shows once no store still paging could hold a
/// newer one: the list stops at the newest of their oldest rows read.
struct ArtifactFeed: Equatable {
    struct Cursor: Equatable {
        let source: Int
        let before: Int
    }

    let sources: [ArtifactSource]
    private var read: [[ArtifactItem]]
    private var cursors: [Int?]

    /// `pages` are the sources' first pages, in order; nil for one that
    /// couldn't be read, which then adds nothing.
    init(sources: [ArtifactSource], pages: [ArtifactPage?]) {
        self.sources = sources
        read = sources.indices.map { index in
            (index < pages.count ? pages[index]?.items : nil).map { Self.tagged($0, from: sources[index]) } ?? []
        }
        cursors = sources.indices.map { index in index < pages.count ? pages[index]?.nextBefore : nil }
    }

    /// The rows to show, newest first, each artifact once.
    var items: [ArtifactItem] {
        let horizon = self.horizon
        var heads = Array(repeating: 0, count: read.count)
        var seen = Set<String>()
        var merged: [ArtifactItem] = []
        while true {
            // The newest next row of any store; a tie goes to the earlier one.
            var pick: Int?
            for index in read.indices where heads[index] < read[index].count {
                if let current = pick, read[current][heads[current]].date >= read[index][heads[index]].date { continue }
                pick = index
            }
            guard let index = pick else { break }
            let item = read[index][heads[index]]
            heads[index] += 1
            if let horizon, item.date < horizon { continue }
            if seen.insert(item.id).inserted { merged.append(item) }
        }
        return merged
    }

    /// The page to read next: from the store still paging whose rows read
    /// so far reach the least far back. Nil once every store is read.
    var nextCursor: Cursor? {
        var best: Cursor?
        var bestOldest: Date?
        for index in sources.indices {
            guard let before = cursors[index] else { continue }
            // A store with nothing read yet is read before anything else.
            guard let oldest = read[index].map(\.date).min() else { return Cursor(source: index, before: before) }
            if bestOldest.map({ oldest > $0 }) ?? true {
                best = Cursor(source: index, before: before)
                bestOldest = oldest
            }
        }
        return best
    }

    /// Adds the page read at `cursor`.
    mutating func append(_ page: ArtifactPage, at cursor: Cursor) {
        guard sources.indices.contains(cursor.source), cursors[cursor.source] == cursor.before else { return }
        read[cursor.source] += Self.tagged(page.items, from: sources[cursor.source])
        cursors[cursor.source] = page.nextBefore
    }

    /// Rows older than this wait: a store still paging may hold newer ones.
    private var horizon: Date? {
        var horizon: Date?
        for index in sources.indices where cursors[index] != nil {
            guard let oldest = read[index].map(\.date).min() else { return .distantFuture }
            horizon = max(horizon ?? oldest, oldest)
        }
        return horizon
    }

    private static func tagged(_ items: [ArtifactItem], from source: ArtifactSource) -> [ArtifactItem] {
        guard let label = source.label else { return items }
        return items.map { item in
            var item = item
            item.otherProfile = source.profile
            item.otherProfileLabel = label
            item.isBotChat = source.isBotChat
            return item
        }
    }
}

final class ArtifactsClient {
    static let capability = "artifacts"
    static let path = "/api/plugins/conduit_push/artifacts"
    static let pageSize = 60
    /// Whether the lists show files no longer on the host (off by default).
    static let showMissingKey = "artifacts.showMissing"

    typealias Request = @MainActor (_ path: String) async throws -> [String: Any]

    enum Failure: Error {
        case malformed
    }

    private let request: Request

    init(request: @escaping Request) {
        self.request = request
    }

    @MainActor
    func page(_ source: ArtifactSource, filter: ArtifactFilter = .all, query: String = "",
              showMissing: Bool = true, before: Int? = nil) async throws -> ArtifactPage {
        try await page(profile: source.profile, sessionIDs: source.sessionIDs, filter: filter, query: query,
                       showMissing: showMissing, before: before)
    }

    @MainActor
    func page(profile: String, sessionIDs: [String] = [], filter: ArtifactFilter = .all, query: String = "",
              showMissing: Bool = true, before: Int? = nil) async throws -> ArtifactPage {
        try Self.parse(await request(Self.requestPath(
            profile: profile, sessionIDs: sessionIDs, filter: filter, query: query, showMissing: showMissing,
            before: before
        )), showMissing: showMissing)
    }

    /// `sessionIDs` names one chat by every id it's known by; empty reads
    /// every chat in the profile.
    static func requestPath(profile: String, sessionIDs: [String], filter: ArtifactFilter, query: String,
                            showMissing: Bool = true, before: Int?) -> String {
        var parameters = ["limit=\(pageSize)"]
        for id in sessionIDs.sorted() {
            if let encoded = DashboardPath.encodedQueryComponent(id) { parameters.append("session_id=\(encoded)") }
        }
        if let kind = filter.hostKind { parameters.append("kind=\(kind)") }
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty, let encoded = DashboardPath.encodedQueryComponent(words) {
            parameters.append("q=\(encoded)")
        }
        // The host leaves them out (plugin 0.51.8+), so a history of
        // deleted files doesn't leave pages mostly empty.
        if !showMissing { parameters.append("missing=hide") }
        if let before { parameters.append("before=\(before)") }
        return DashboardPath.withProfile("\(path)?\(parameters.joined(separator: "&"))", profile: profile)
    }

    static func parse(_ response: [String: Any], showMissing: Bool = true) throws -> ArtifactPage {
        guard response["ok"] as? Bool == true, let rows = response["items"] as? [[String: Any]] else {
            throw Failure.malformed
        }
        // An older plugin lists missing files whatever it was asked.
        let items = rows.compactMap(ArtifactItem.init).filter { showMissing || $0.exists }
        // Each artifact once, so list identity holds whatever the host sends.
        return ArtifactPage(items: merged([], with: items), nextBefore: response["next_before"] as? Int)
    }

    /// `older` appended to `items`, each artifact once (its newest mention
    /// stays, which the earlier page holds).
    static func merged(_ items: [ArtifactItem], with older: [ArtifactItem]) -> [ArtifactItem] {
        var seen = Set(items.map(\.id))
        return items + older.filter { seen.insert($0.id).inserted }
    }

    /// Items grouped by the calendar day they came from, newest first.
    static func days(_ items: [ArtifactItem], calendar: Calendar = .current) -> [ArtifactDay] {
        var order: [Date] = []
        var groups: [Date: [ArtifactItem]] = [:]
        for item in items {
            let day = calendar.startOfDay(for: item.date)
            if groups[day] == nil { order.append(day) }
            groups[day, default: []].append(item)
        }
        return order.map { ArtifactDay(day: $0, items: groups[$0] ?? []) }
    }
}
