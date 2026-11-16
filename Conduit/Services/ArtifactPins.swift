import Foundation

/// Saved artifacts (issue 2467): the files, pages and links the user kept
/// from the Artifacts list, so one that mattered doesn't scroll back under
/// everything since, or go with its chat. The host's notifier plugin keeps
/// them per profile (plugin 0.177+, capability `artifact-pins`), shared by
/// every device signed in to it, with a copy of each file that opens once
/// the original, its chat or its session is gone, and a short note.
struct ArtifactPinsClient {
    static let capability = "artifact-pins"
    static let path = "/api/plugins/conduit_push/artifacts/pins"
    /// The host's limit on a note, in Unicode code points (Python's len).
    static let maxNoteLength = 200

    typealias Request = @MainActor (_ path: String, _ method: String, _ body: [String: Any]?) async throws -> [String: Any]

    enum Failure: Error {
        case malformed
    }

    let request: Request

    /// The profile's saved artifacts, the one saved last first. With
    /// `answers`, kept so Saved opens on them next time, offline too.
    @MainActor
    func list(profile: String, keptIn answers: KeptAnswers? = nil) async throws -> [ArtifactItem] {
        let route = Self.listPath(profile: profile)
        guard let answers else { return try Self.parse(await request(route, "GET", nil)) }
        return try Self.parse(await answers.keep(route, false) {
            let answer = try await request(route, "GET", nil)
            _ = try ArtifactPinsClient.parse(answer)
            return answer
        })
    }

    /// The profile's saved artifacts as last read, or nil.
    @MainActor
    static func kept(profile: String, in answers: KeptAnswers) -> [ArtifactItem]? {
        answers.kept(listPath(profile: profile)).flatMap { try? parse($0) }
    }

    /// Saves `item` in `profile` with `note`, or changes the note of one
    /// already saved; answers with the saved row.
    @MainActor
    func save(_ item: ArtifactItem, note: String?, profile: String) async throws -> ArtifactItem {
        var body: [String: Any] = ["item": Self.row(item)]
        if let note = Self.cleanNote(note) { body["note"] = note }
        let answer = try await request(Self.listPath(profile: profile), "POST", body)
        guard answer["ok"] as? Bool == true, let row = answer["pin"] as? [String: Any],
              let saved = ArtifactItem(savedRow: row) else { throw Failure.malformed }
        return saved
    }

    /// Unsaves `item` in `profile`; the host removes its copy.
    @MainActor
    func remove(_ item: ArtifactItem, profile: String) async throws {
        guard let id = item.path ?? item.url?.absoluteString,
              let encoded = DashboardPath.encodedQueryComponent(id) else { throw Failure.malformed }
        let answer = try await request(DashboardPath.withProfile("\(Self.path)?id=\(encoded)", profile: profile),
                                       "DELETE", nil)
        guard answer["ok"] as? Bool == true else { throw Failure.malformed }
    }

    static func listPath(profile: String) -> String {
        DashboardPath.withProfile(path, profile: profile)
    }

    static func parse(_ response: [String: Any]) throws -> [ArtifactItem] {
        guard response["ok"] as? Bool == true, let rows = response["pins"] as? [[String: Any]] else {
            throw Failure.malformed
        }
        return ArtifactsClient.merged([], with: rows.compactMap(ArtifactItem.init(savedRow:)))
    }

    /// The row the host keeps, as the list gave it.
    static func row(_ item: ArtifactItem) -> [String: Any] {
        var row: [String: Any] = [
            "kind": item.kind.rawValue, "source": item.source.rawValue, "name": item.name,
            "session_id": item.sessionID, "session_title": item.sessionTitle,
            "message_id": item.messageID, "timestamp": item.date.timeIntervalSince1970,
        ]
        if let path = item.path { row["path"] = path }
        if let url = item.url { row["url"] = url.absoluteString }
        return row
    }

    /// Fits the host's code-point limit without splitting a visible character.
    /// The editor uses this too, keeping spaces intact while the user types.
    static func limitedNote(_ note: String) -> String {
        var remaining = maxNoteLength
        return String(note.prefix { character in
            let count = character.unicodeScalars.count
            guard count <= remaining else { return false }
            remaining -= count
            return true
        })
    }

    /// A note as the host keeps it: one line, nil when empty.
    static func cleanNote(_ note: String?) -> String? {
        let words = (note ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let limited = limitedNote(words)
        return limited.isEmpty ? nil : limited
    }

    /// What Saved lists for `sources`, from each source's profile's saved
    /// set (`saved[i]` for `sources[i]`, nil for one not read): a store read
    /// for some chats lists only theirs, as the list does. Each artifact
    /// once, the one saved last first, matching `query`. An artifact saved
    /// in more than one store is its newest row, tagged with the store that
    /// holds it, so its note, its place and its menu are that pin's.
    static func items(sources: [ArtifactSource], saved: [[ArtifactItem]?], query: String = "") -> [ArtifactItem] {
        var newest: [String: ArtifactItem] = [:]
        var order: [String] = []
        for (index, source) in sources.enumerated() {
            guard index < saved.count, let rows = saved[index] else { continue }
            let chats = Set(source.sessionIDs)
            let covered = chats.isEmpty ? rows : rows.filter { chats.contains($0.sessionID) }
            for item in ArtifactFeed.tagged(covered, from: source) {
                if let current = newest[item.id] {
                    if (item.savedAt ?? .distantPast) > (current.savedAt ?? .distantPast) { newest[item.id] = item }
                } else {
                    newest[item.id] = item
                    order.append(item.id)
                }
            }
        }
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return order.compactMap { newest[$0] }
            .filter { words.isEmpty || matches($0, words) }
            .sorted { ($0.savedAt ?? .distantPast) > ($1.savedAt ?? .distantPast) }
    }

    /// A run of saved artifacts drawn the same way: pictures in a grid,
    /// the rest as rows.
    struct Run: Identifiable {
        let isVisual: Bool
        var items: [ArtifactItem]
        var id: String { "\(isVisual)|\(items.first?.id ?? "")" }
    }

    /// `items` as runs, in their order: each run of pictures or of other
    /// artifacts together, so a grid never moves an item past another.
    static func runs(_ items: [ArtifactItem]) -> [Run] {
        var runs: [Run] = []
        for item in items {
            if let last = runs.last, last.isVisual == item.isVisual {
                runs[runs.count - 1].items.append(item)
            } else {
                runs.append(Run(isVisual: item.isVisual, items: [item]))
            }
        }
        return runs
    }

    /// The list's search: the name, the chat's title and the note.
    static func matches(_ item: ArtifactItem, _ words: String) -> Bool {
        [item.name, item.sessionTitle, item.note ?? "", item.otherProfileLabel ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(words) }
    }
}

extension ArtifactItem {
    /// A row of the host's saved set.
    init?(savedRow raw: [String: Any]) {
        guard var item = ArtifactItem(raw) else { return nil }
        item.savedAt = (raw["pinned_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        item.note = (raw["note"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        item.keptPath = (raw["kept_path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self = item
    }
}
