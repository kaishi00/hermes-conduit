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
        self.exists = raw["exists"] as? Bool ?? true
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

final class ArtifactsClient {
    static let capability = "artifacts"
    static let path = "/api/plugins/conduit_push/artifacts"
    static let pageSize = 60

    typealias Request = @MainActor (_ path: String) async throws -> [String: Any]

    enum Failure: Error {
        case malformed
    }

    private let request: Request

    init(request: @escaping Request) {
        self.request = request
    }

    @MainActor
    func page(profile: String, sessionIDs: [String] = [], filter: ArtifactFilter = .all, query: String = "",
              before: Int? = nil) async throws -> ArtifactPage {
        try Self.parse(await request(Self.requestPath(
            profile: profile, sessionIDs: sessionIDs, filter: filter, query: query, before: before
        )))
    }

    /// `sessionIDs` names one chat by every id it's known by; empty reads
    /// every chat in the profile.
    static func requestPath(profile: String, sessionIDs: [String], filter: ArtifactFilter, query: String,
                            before: Int?) -> String {
        var parameters = ["limit=\(pageSize)"]
        for id in sessionIDs.sorted() {
            if let encoded = DashboardPath.encodedQueryComponent(id) { parameters.append("session_id=\(encoded)") }
        }
        if let kind = filter.hostKind { parameters.append("kind=\(kind)") }
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty, let encoded = DashboardPath.encodedQueryComponent(words) {
            parameters.append("q=\(encoded)")
        }
        if let before { parameters.append("before=\(before)") }
        return DashboardPath.withProfile("\(path)?\(parameters.joined(separator: "&"))", profile: profile)
    }

    static func parse(_ response: [String: Any]) throws -> ArtifactPage {
        guard response["ok"] as? Bool == true, let rows = response["items"] as? [[String: Any]] else {
            throw Failure.malformed
        }
        // Each artifact once, so list identity holds whatever the host sends.
        return ArtifactPage(items: merged([], with: rows.compactMap(ArtifactItem.init)),
                            nextBefore: response["next_before"] as? Int)
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
