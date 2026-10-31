import Foundation

/// The Folder tab's reads and changes (#1389): one root at a time, the open
/// chat's working folder or a project's folder, through the host's notifier
/// plugin (`/workspace/*`, plugin 0.109+). The plugin keeps every path inside
/// the root it's given and leaves out files that hold keys or passwords;
/// file contents are read through Hermes' own `/api/fs/*` routes.
final class WorkspaceFilesClient {
    static let capability = "workspace-files"
    static let path = "/api/plugins/conduit_push/workspace"

    typealias Request = @MainActor (_ path: String, _ method: String, _ body: [String: Any]?) async throws -> [String: Any]

    enum Failure: Error {
        case malformed
    }

    private let profile: String
    private let request: Request

    init(profile: String, request: @escaping Request) {
        self.profile = profile
        self.request = request
    }

    /// With `answers`, the listing is kept as the plugin gave it, so the
    /// folder opens on it next time (#1533).
    @MainActor
    func list(root: String, path: String, keptIn answers: KeptAnswers? = nil) async throws -> WorkspaceListing {
        try Self.listing(await get("list", ["root": root, "path": path], keptIn: answers) {
            _ = try WorkspaceFilesClient.listing($0, path: path)
        }, path: path)
    }

    /// The listing kept for the folder, or nil.
    @MainActor
    func keptListing(root: String, path: String, in answers: KeptAnswers) -> WorkspaceListing? {
        answers.kept(keptRoute("list", ["root": root, "path": path])).flatMap { try? WorkspaceFilesClient.listing($0, path: path) }
    }

    private static func listing(_ response: [String: Any], path: String) throws -> WorkspaceListing {
        guard let rows = response["entries"] as? [[String: Any]] else { throw Failure.malformed }
        return WorkspaceListing(
            path: response["path"] as? String ?? path,
            entries: rows.compactMap(WorkspaceEntry.init(row:)),
            truncated: response["truncated"] as? Bool ?? false
        )
    }

    @MainActor
    func search(root: String, query: String, contents: Bool = true) async throws -> WorkspaceSearchResult {
        let response = try await get("search", ["root": root, "q": query, "contents": contents ? "true" : "false"])
        guard let names = response["names"] as? [[String: Any]],
              let matches = response["matches"] as? [[String: Any]] else { throw Failure.malformed }
        return WorkspaceSearchResult(
            query: query,
            names: names.compactMap(WorkspaceEntry.init(row:)),
            matches: matches.compactMap(WorkspaceSearchMatch.init(row:)),
            truncated: response["truncated"] as? Bool ?? false
        )
    }

    /// With `answers`, kept as `list` keeps a listing.
    @MainActor
    func recent(root: String, keptIn answers: KeptAnswers? = nil) async throws -> [WorkspaceEntry] {
        try Self.recentEntries(await get("recent", ["root": root], keptIn: answers) {
            _ = try WorkspaceFilesClient.recentEntries($0)
        })
    }

    /// The recent files kept for the folder, or nil.
    @MainActor
    func keptRecent(root: String, in answers: KeptAnswers) -> [WorkspaceEntry]? {
        answers.kept(keptRoute("recent", ["root": root])).flatMap { try? WorkspaceFilesClient.recentEntries($0) }
    }

    private static func recentEntries(_ response: [String: Any]) throws -> [WorkspaceEntry] {
        guard let rows = response["entries"] as? [[String: Any]] else { throw Failure.malformed }
        return rows.compactMap(WorkspaceEntry.init(row:))
    }

    @MainActor
    @discardableResult
    func makeFolder(root: String, in folder: String, name: String) async throws -> WorkspaceEntry? {
        try await change("mkdir", ["root": root, "path": folder, "name": name])
    }

    @MainActor
    @discardableResult
    func makeFile(root: String, in folder: String, name: String, content: String = "") async throws -> WorkspaceEntry? {
        try await change("new-file", ["root": root, "path": folder, "name": name, "content": content])
    }

    /// Refused with 409 when the file changed since `readAt` (its date when
    /// the editor read it); nil saves over whatever is there.
    @MainActor
    @discardableResult
    func save(root: String, path: String, content: String, readAt: Date?) async throws -> WorkspaceEntry? {
        var body: [String: Any] = ["root": root, "path": path, "content": content]
        if let readAt { body["expected_mtime"] = readAt.timeIntervalSince1970 }
        return try await change("save", body)
    }

    /// A rename is a move within the same folder.
    @MainActor
    @discardableResult
    func move(root: String, path: String, to folder: String, name: String, replacing: Bool = false) async throws -> WorkspaceEntry? {
        try await change("move", ["root": root, "path": path, "to": folder, "name": name, "overwrite": replacing])
    }

    @MainActor
    @discardableResult
    func duplicate(root: String, path: String) async throws -> WorkspaceEntry? {
        try await change("duplicate", ["root": root, "path": path])
    }

    @MainActor
    func delete(root: String, path: String) async throws {
        _ = try await request(actionPath("delete"), "POST", ["root": root, "path": path])
    }

    @MainActor
    @discardableResult
    func upload(root: String, in folder: String, name: String, data: Data, replacing: Bool = false) async throws -> WorkspaceEntry? {
        try await change("upload", ["root": root, "path": folder, "name": name,
                                    "data": data.base64EncodedString(), "overwrite": replacing])
    }

    // MARK: - Requests

    private func actionPath(_ action: String) -> String {
        DashboardPath.withProfile("\(Self.path)/\(action)", profile: profile)
    }

    /// Only an answer `readable` takes is kept, so one the folder can't
    /// read never takes the last one's place.
    @MainActor
    private func get(
        _ action: String, _ query: [String: String], keptIn answers: KeptAnswers? = nil,
        readable: (([String: Any]) throws -> Void)? = nil
    ) async throws -> [String: Any] {
        let path = DashboardPath.withProfile(Self.requestPath(action, query), profile: profile)
        let read = { () async throws -> [String: Any] in
            let response = try await self.request(path, "GET", nil)
            guard response["ok"] as? Bool == true else { throw Failure.malformed }
            try readable?(response)
            return response
        }
        guard let answers else { return try await read() }
        return try await answers.keep(keptRoute(action, query), false, read)
    }

    /// Where an answer is kept: one folder's of many, so only the folders
    /// opened last keep theirs.
    private func keptRoute(_ action: String, _ query: [String: String]) -> String {
        OfflineChatCacheStore.lastOpenedRoutePrefix + DashboardPath.withProfile(Self.requestPath(action, query), profile: profile)
    }

    @MainActor
    private func change(_ action: String, _ body: [String: Any]) async throws -> WorkspaceEntry? {
        let response = try await request(actionPath(action), "POST", body)
        guard response["ok"] as? Bool == true else { throw Failure.malformed }
        return (response["entry"] as? [String: Any]).flatMap(WorkspaceEntry.init(row:))
    }

    static func requestPath(_ action: String, _ query: [String: String]) -> String {
        let items = query.keys.sorted().compactMap { key -> String? in
            guard let value = query[key], let encoded = DashboardPath.encodedQueryComponent(value) else { return nil }
            return "\(key)=\(encoded)"
        }
        return "\(path)/\(action)?\(items.joined(separator: "&"))"
    }
}

struct WorkspaceListing: Equatable {
    var path: String
    var entries: [WorkspaceEntry]
    var truncated: Bool
}

struct WorkspaceSearchMatch: Identifiable, Equatable {
    struct Line: Equatable, Hashable {
        let number: Int
        let text: String
        /// Where the match sits in `text`, in characters.
        let matchStart: Int
        let matchLength: Int
    }

    let path: String
    let name: String
    let lines: [Line]

    var id: String { path }

    init?(row: [String: Any]) {
        guard let path = row["path"] as? String, !path.isEmpty else { return nil }
        self.path = path
        let name = row["name"] as? String ?? ""
        self.name = name.isEmpty ? (path as NSString).lastPathComponent : name
        lines = (row["lines"] as? [[String: Any]] ?? []).compactMap { line in
            guard let number = line["line"] as? Int, let text = line["text"] as? String else { return nil }
            return Line(number: number, text: text,
                        matchStart: max(0, line["matchStart"] as? Int ?? 0),
                        matchLength: max(0, line["matchLength"] as? Int ?? 0))
        }
    }
}

struct WorkspaceSearchResult: Equatable {
    var query: String
    var names: [WorkspaceEntry]
    var matches: [WorkspaceSearchMatch]
    var truncated: Bool
}

extension WorkspaceEntry {
    init?(row: [String: Any]) {
        guard let name = row["name"] as? String, let path = row["path"] as? String,
              !name.isEmpty, !path.isEmpty else { return nil }
        self.init(
            name: name,
            path: path,
            isDirectory: row["isDirectory"] as? Bool ?? false,
            size: (row["size"] as? NSNumber)?.int64Value,
            modified: (row["mtime"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        )
    }

    /// The folder holding it.
    var folder: String {
        (path as NSString).deletingLastPathComponent
    }
}

/// A folder the Folder tab can open: the chat's own, or a project's.
struct WorkspaceRoot: Identifiable, Equatable, Hashable {
    enum Kind: Equatable, Hashable {
        case chat
        case project
    }

    let path: String
    let title: String
    let kind: Kind

    var id: String { path }
}

/// A file to show in the Folder tab: one a reply named (a tapped path), or
/// a search match at its line.
struct WorkspaceReveal: Equatable, Identifiable {
    let id = UUID()
    let path: String
    var line: Int?

    static func == (lhs: WorkspaceReveal, rhs: WorkspaceReveal) -> Bool { lhs.id == rhs.id }
}

/// File paths in a reply, made tappable: they open in the Folder tab.
/// Inline code that names a path (`docs/guide.md`, `/srv/app/main.py`,
/// `~/notes.txt`), and in plain text only a path with a folder and a file
/// type (`meta-app-review/tutorial.md`), so ordinary words with a slash
/// ("and/or") stay text.
enum WorkspacePathLinks {
    static let maxLength = 512

    /// The link for inline code holding a path, or nil.
    static func url(forCode code: String) -> URL? {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPathShaped(text, needsFolder: false) else { return nil }
        return ConduitAppLink.file(path: text).url
    }

    /// Ranges of plain text that name a path, with each one's link.
    static func links(inText text: String) -> [(range: NSRange, url: URL)] {
        guard text.contains("/"), text.contains("."), let pattern = tokenPattern else { return [] }
        let string = text as NSString
        var found: [(NSRange, URL)] = []
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            var range = match.range
            var token = string.substring(with: range)
            // A sentence's last word keeps its period out of the path.
            while let last = token.last, ".,;:!?)".contains(last) {
                token.removeLast()
                range.length -= (String(last) as NSString).length
            }
            guard isPathShaped(token, needsFolder: true) else { continue }
            found.append((range, ConduitAppLink.file(path: token).url))
        }
        return found
    }

    /// Whether `text` reads as a file path: one token, no web address, and
    /// either a folder (`/`) or a known file type. Plain text needs both.
    static func isPathShaped(_ text: String, needsFolder: Bool) -> Bool {
        guard !text.isEmpty, text.count <= maxLength,
              text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !text.contains("://"), !text.hasPrefix("@"), !text.contains("`"),
              text.rangeOfCharacter(from: .letters) != nil else { return false }
        let hasFolder = text.contains("/") && text != "/" && !text.hasSuffix("//")
        let name = (text as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        let hasType = !ext.isEmpty && fileTypes.contains(ext) && name.count > ext.count + 1
        if needsFolder { return hasFolder && hasType }
        // In code: a folder path (`src/app/`), or a file name with a known type.
        if hasType { return true }
        guard hasFolder else { return false }
        // `a/b` in code still needs to look like a path rather than a ratio
        // or a command option.
        return text.hasPrefix("/") || text.hasPrefix("~/") || text.hasPrefix("./") || text.hasPrefix("../")
            || text.split(separator: "/").count >= 2 && text.range(of: #"^[\w.~-]+(/[\w.@+-]+)+/?$"#, options: .regularExpression) != nil
    }

    /// Nil only if the pattern were mistyped: plain text then links nothing.
    private static let tokenPattern = try? NSRegularExpression(
        pattern: #"(?<![\w/@:.~-])(?:~/|\.{1,2}/|/)?[\w@+.-]+(?:/[\w@+.-]+)+\.[A-Za-z0-9]{1,8}[.,;:!?)]*"#
    )

    /// File types common enough in replies to read as files rather than
    /// words ("e.g." or "v1.2" aren't).
    static let fileTypes: Set<String> = [
        "md", "markdown", "txt", "rtf", "pdf", "csv", "tsv", "json", "jsonl", "yaml", "yml", "toml", "ini", "xml",
        "html", "htm", "css", "scss", "js", "mjs", "cjs", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "swift", "kt",
        "java", "c", "h", "cpp", "hpp", "cs", "php", "sh", "zsh", "bash", "sql", "lua", "r", "ipynb", "log",
        "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "mp3", "m4a", "wav", "mp4", "mov", "zip", "tar", "gz",
        "docx", "xlsx", "pptx", "key", "pages", "numbers", "env", "conf", "cfg", "lock", "vue", "svelte", "dart",
    ]
}
