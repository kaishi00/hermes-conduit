//
//  SessionContentSearch.swift
//  Conduit
//
//  Full-text chat search for the Chats list. The search field filters the
//  chats Conduit has listed by title and preview at once; this asks Hermes'
//  own `GET /api/sessions/search` (session ids, then message text, then, on
//  newer hosts, titles) for chats whose messages hold the words, so a chat
//  that only *talked about* recycling is found too.
//
//  Request: `?q=<words>&limit=<n>[&profile=<name>]`, the profile in use the
//  way the other session routes take it. Response: `{"results": [row]}`,
//  one row per conversation (Hermes collapses a compression chain onto its
//  live tip): `session_id` (the tip), `lineage_root`, `snippet` (the match
//  marked `>>>like this<<<`), `role`, `source`, `model`, `session_started`;
//  newer hosts add `title`, `last_active`, `archived` and the rest of a list
//  row. No row says which message matched, so a result opens its chat, not
//  a message in it.
//
//  A Hermes without the route (404, 405, 410) is remembered per dashboard
//  connection and never asked again on it; other failures keep the list's
//  own matches and say nothing.
//

import Foundation
import SwiftUI

/// A search snippet split into plain text and the words that matched.
struct SessionSearchSnippet: Equatable {
    struct Run: Equatable {
        let text: String
        let isMatch: Bool
    }

    let runs: [Run]

    var plainText: String { runs.map(\.text).joined() }
    var hasMatch: Bool { runs.contains(where: \.isMatch) }

    static let matchStart = ">>>"
    static let matchEnd = "<<<"

    /// Hermes' snippet on one line, with its `>>>…<<<` marks as match runs.
    /// A snippet without marks (a session-id hit's preview, the substring
    /// search short CJK queries take) gets the query's words marked instead.
    static func parse(_ raw: String, query: String) -> SessionSearchSnippet {
        let line = oneLine(raw)
        guard line.contains(matchStart) || line.contains(matchEnd) else {
            return SessionSearchSnippet(runs: highlighting(words(in: query), in: line))
        }
        var runs: [Run] = []
        var remaining = Substring(line)
        var inMatch = false
        while !remaining.isEmpty {
            let marker = inMatch ? matchEnd : matchStart
            if let range = remaining.range(of: marker) {
                append(String(remaining[..<range.lowerBound]), isMatch: inMatch, to: &runs)
                remaining = remaining[range.upperBound...]
                inMatch.toggle()
            } else {
                append(String(remaining), isMatch: inMatch, to: &runs)
                remaining = ""
            }
        }
        // A stray closing mark outside a match is noise, not text.
        runs = runs.map { Run(text: $0.text.replacingOccurrences(of: matchEnd, with: ""), isMatch: $0.isMatch) }
            .filter { !$0.text.isEmpty }
        return SessionSearchSnippet(runs: merged(runs))
    }

    /// The snippet for a row: matched words semibold in the accent color.
    func attributed(matchColor: Color = .conduitAccent) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            if run.isMatch {
                piece.font = .subheadline.weight(.semibold)
                piece.foregroundColor = matchColor
            }
            result += piece
        }
        return result
    }

    /// Newlines and runs of spaces become one space; FTS5's `...` ellipsis
    /// becomes `…`.
    static func oneLine(_ raw: String) -> String {
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var line = collapsed
        if line.hasPrefix("...") { line = "…" + line.dropFirst(3) }
        if line.hasSuffix("...") { line = line.dropLast(3) + "…" }
        return line
    }

    private static func words(in query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
    }

    /// `line` with every case- and diacritic-insensitive occurrence of
    /// `words` as a match run.
    private static func highlighting(_ words: [String], in line: String) -> [Run] {
        guard !line.isEmpty else { return [] }
        var matched: [Range<String.Index>] = []
        for word in words {
            var searchStart = line.startIndex
            while searchStart < line.endIndex,
                  let range = line.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<line.endIndex) {
                matched.append(range)
                searchStart = range.upperBound
            }
        }
        guard !matched.isEmpty else { return [Run(text: line, isMatch: false)] }
        matched.sort { $0.lowerBound < $1.lowerBound }
        var runs: [Run] = []
        var cursor = line.startIndex
        for range in matched {
            let start = max(range.lowerBound, cursor)
            guard start < range.upperBound else { continue }
            append(String(line[cursor..<start]), isMatch: false, to: &runs)
            append(String(line[start..<range.upperBound]), isMatch: true, to: &runs)
            cursor = range.upperBound
        }
        append(String(line[cursor...]), isMatch: false, to: &runs)
        return merged(runs)
    }

    private static func append(_ text: String, isMatch: Bool, to runs: inout [Run]) {
        guard !text.isEmpty else { return }
        runs.append(Run(text: text, isMatch: isMatch))
    }

    private static func merged(_ runs: [Run]) -> [Run] {
        var result: [Run] = []
        for run in runs {
            if let last = result.last, last.isMatch == run.isMatch {
                result[result.count - 1] = Run(text: last.text + run.text, isMatch: run.isMatch)
            } else {
                result.append(run)
            }
        }
        return result
    }
}

/// One conversation Hermes' full-text search found.
struct SessionContentSearchHit: Identifiable, Equatable {
    /// The conversation's live tip, the id that opens it.
    let sessionID: String
    let lineageRootID: String?
    /// Hermes' title for it; "" on hosts that don't send one.
    let title: String
    let snippet: SessionSearchSnippet
    let lastActive: TimeInterval?
    let isArchived: Bool
    /// The profile it was found in, when a search went to more than the
    /// one in use (the Chats list's All view).
    var profile: String? = nil

    var id: String { sessionID }

    /// The ids a listed chat can carry for this conversation.
    var identities: Set<String> {
        var ids: Set<String> = [sessionID]
        if let lineageRootID, !lineageRootID.isEmpty { ids.insert(lineageRootID) }
        return ids
    }
}

/// A content match as the Chats list shows it: the listed chat it belongs
/// to when Conduit has one, for its title and its row actions.
struct SessionContentSearchRow: Identifiable, Equatable {
    let hit: SessionContentSearchHit
    let session: SessionSummary?

    /// Another profile's match carries its profile, as All's list rows do:
    /// two profiles can hold the same chat id.
    var id: String { (hit.profile.map { $0.lowercased() + "\u{1F}" } ?? "") + openID }
    /// The id that opens it: the listed chat's, else Hermes' tip.
    var openID: String { session?.id ?? hit.sessionID }

    var title: String {
        if let title = session?.title.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        let title = hit.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? AppLocalization.string("Untitled conversation") : title
    }
}

enum SessionContentSearch {
    static let path = "/api/sessions/search"
    static let minimumQueryCharacters = 2
    /// Enough to scroll through; Hermes caps a page at 100.
    static let resultLimit = 20

    /// The words of `raw` Hermes can search, or nil while there's too little
    /// to ask about.
    static func searchableQuery(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumQueryCharacters else { return nil }
        let words = VoiceChatFinder.searchQuery(trimmed)
        return words.isEmpty ? nil : words
    }

    static func path(query: String, profile: String) -> String {
        let encoded = DashboardPath.encodedQueryComponent(query) ?? ""
        return DashboardPath.withProfile("\(path)?q=\(encoded)&limit=\(resultLimit)", profile: profile)
    }

    /// A Hermes older than the route: it doesn't know the path or the method.
    static func isUnsupported(_ error: Error) -> Bool {
        guard case DashboardTicketBridgeError.http(let status, _) = error else { return false }
        return status == 404 || status == 405 || status == 410
    }

    /// The response's conversations in Hermes' order, one per id. Nil when
    /// the body isn't a search response at all (a host answering the path
    /// with something else).
    static func hits(from response: [String: Any], query: String) -> [SessionContentSearchHit]? {
        guard let rows = response["results"] as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        return rows.compactMap { row -> SessionContentSearchHit? in
            let id = (text(row["session_id"]) ?? text(row["id"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            let root = text(row["lineage_root"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            return SessionContentSearchHit(
                sessionID: id,
                lineageRootID: root?.isEmpty == false ? root : nil,
                title: text(row["title"]) ?? "",
                snippet: SessionSearchSnippet.parse(row["snippet"] as? String ?? "", query: query),
                lastActive: epoch(row["last_active"]) ?? epoch(row["session_started"]) ?? epoch(row["started_at"]),
                isArchived: row["archived"] as? Bool ?? false
            )
        }
    }

    /// The content matches the list doesn't already show: a hit for a chat
    /// among `listed` (the title and preview matches on screen) is dropped,
    /// as is an archived chat the list leaves out. `known` is every chat
    /// Conduit has for the profile, for titles; `allowed`, when set, keeps
    /// only matches among those chats (an active filter).
    ///
    /// In All, `owner` names each chat's profile and a hit's profile is its
    /// tag (else `activeProfile`), so a chat id two profiles share matches
    /// only within its own profile.
    static func rows(
        hits: [SessionContentSearchHit],
        listed: [SessionSummary],
        known: [SessionSummary],
        allowed: [SessionSummary]? = nil,
        activeProfile: String = "",
        owner: (SessionSummary) -> String = { _ in "" }
    ) -> [SessionContentSearchRow] {
        func scoped(_ profile: String, _ ids: [String]) -> [String] {
            let prefix = profile.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "\u{1F}"
            return ids.map { prefix + $0 }
        }
        func keys(_ session: SessionSummary) -> [String] { scoped(owner(session), identities(of: session)) }
        let listedIDs = Set(listed.flatMap(keys))
        var knownByID: [String: SessionSummary] = [:]
        for session in known {
            for id in keys(session) where knownByID[id] == nil { knownByID[id] = session }
        }
        let allowedIDs = allowed.map { Set($0.flatMap(keys)) }
        var shown = Set<String>()
        return hits.compactMap { hit -> SessionContentSearchRow? in
            let profile = hit.profile ?? activeProfile
            let hitIDs = Set(scoped(profile, Array(hit.identities)))
            guard hitIDs.isDisjoint(with: listedIDs) else { return nil }
            if let allowedIDs, hitIDs.isDisjoint(with: allowedIDs) { return nil }
            let session = scoped(profile, [hit.sessionID] + (hit.lineageRootID.map { [$0] } ?? []))
                .lazy.compactMap { knownByID[$0] }.first
            // A call Hermes archived at its end is still a listed row here
            // (#1124); a chat Conduit knows as archived stays out, as before.
            if session?.isArchived ?? hit.isArchived { return nil }
            let row = SessionContentSearchRow(hit: hit, session: session)
            guard shown.insert(row.id).inserted else { return nil }
            return row
        }
    }

    static func identities(of session: SessionSummary) -> [String] {
        ([session.id, session.storedSessionId, session.lineageRootId].compactMap { $0 } + session.alternateIds)
            .filter { !$0.isEmpty }
    }

    private static func text(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        return jsonNumber(value)?.stringValue
    }

    private static func epoch(_ value: Any?) -> TimeInterval? {
        if let number = jsonNumber(value) {
            let seconds = number.doubleValue
            return seconds > 0 ? seconds : nil
        }
        if let text = value as? String, let seconds = Double(text), seconds > 0 { return seconds }
        return nil
    }

    /// A JSON number, never a JSON true or false, which also arrive as NSNumber.
    private static func jsonNumber(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number
    }
}

/// The dashboard connections whose Hermes has no search route, held weakly:
/// a new connection (another dashboard, a fresh sign-in) is asked again.
@MainActor
final class SessionContentSearchSupport {
    static let shared = SessionContentSearchSupport()

    private let unsupported = NSHashTable<AnyObject>.weakObjects()

    func isUnsupported(_ scope: AnyObject) -> Bool { unsupported.contains(scope) }
    func markUnsupported(_ scope: AnyObject) { unsupported.add(scope) }
}

/// The Chats list's content search: debounced, one request at a time, and
/// only the latest query's answer is kept.
@MainActor
final class SessionContentSearchModel: ObservableObject {
    typealias Requester = @MainActor (String) async throws -> [String: Any]

    /// Where a search goes: the dashboard connection (its identity scopes
    /// the "unsupported" memory), the profile, and how to ask it.
    struct Context {
        let scope: AnyObject
        let profile: String
        /// More profiles to search with it (the Chats list's All view),
        /// one request each, their hits after the profile in use's.
        var otherProfiles: [String] = []
        let request: Requester
    }

    /// The hits for `resultsQuery`, in Hermes' order.
    @Published private(set) var hits: [SessionContentSearchHit] = []
    /// The query `hits` answer; nil while there are none to show.
    @Published private(set) var resultsQuery: String?
    /// The current query is waiting for its debounce or for Hermes.
    @Published private(set) var isSearching = false

    private let support: SessionContentSearchSupport
    private let debounce: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var task: Task<Void, Never>?
    private var generation = 0
    private var currentKey: Key?

    private struct Key: Equatable {
        let query: String
        let profile: String
        let otherProfiles: [String]
        let scope: ObjectIdentifier
    }

    init(
        support: SessionContentSearchSupport? = nil,
        debounce: Duration = .milliseconds(300),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        // The shared memory by default, so a list rebuilt on the same
        // connection doesn't ask an old Hermes again.
        self.support = support ?? .shared
        self.debounce = debounce
        self.sleep = sleep
    }

    deinit { task?.cancel() }

    /// Follows the search field. A new query cancels the one in flight and
    /// clears its hits; the same query on the same connection and profile
    /// changes nothing. Nil context (not connected) or a short query clears.
    func update(query raw: String, context: Context?) {
        guard let context, let query = SessionContentSearch.searchableQuery(raw),
              !support.isUnsupported(context.scope) else {
            reset()
            return
        }
        let key = Key(
            query: query,
            profile: context.profile,
            otherProfiles: context.otherProfiles,
            scope: ObjectIdentifier(context.scope)
        )
        guard key != currentKey else { return }
        reset()
        currentKey = key
        // Searching from the first keystroke, debounce included: the list
        // doesn't flash "no results" before Hermes is asked.
        isSearching = true
        generation += 1
        let generation = generation
        let path = SessionContentSearch.path(query: query, profile: context.profile)
        let others = context.otherProfiles.map { (profile: $0, path: SessionContentSearch.path(query: query, profile: $0)) }
        let scope = context.scope
        let request = context.request
        let debounce = debounce
        let sleep = sleep
        task = Task { @MainActor [weak self] in
            do { try await sleep(debounce) } catch { return }
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            let outcome: Result<[String: Any], Error>
            do { outcome = .success(try await request(path)) } catch { outcome = .failure(error) }
            // The bridge doesn't stop a request it already sent: an answer
            // for a query the field has moved past is dropped here.
            guard self.generation == generation else { return }
            switch outcome {
            case .success(let response):
                guard var hits = SessionContentSearch.hits(from: response, query: query) else {
                    self.isSearching = false
                    self.support.markUnsupported(scope)
                    return
                }
                // The other profiles' hits follow; one that fails is left
                // out, as the list's own matches still show.
                for other in others {
                    guard let response = try? await request(other.path) else { continue }
                    guard self.generation == generation else { return }
                    let found = SessionContentSearch.hits(from: response, query: query) ?? []
                    hits += found.map { hit in
                        var hit = hit
                        hit.profile = other.profile
                        return hit
                    }
                }
                guard self.generation == generation else { return }
                self.isSearching = false
                self.hits = hits
                self.resultsQuery = query
            case .failure(let error):
                self.isSearching = false
                if SessionContentSearch.isUnsupported(error) {
                    self.support.markUnsupported(scope)
                } else {
                    // A failed answer settles nothing: the same query,
                    // asked again, is sent again.
                    self.currentKey = nil
                }
            }
        }
    }

    /// Drops the hits and any search in flight.
    func reset() {
        generation += 1
        task?.cancel()
        task = nil
        currentKey = nil
        if isSearching { isSearching = false }
        if !hits.isEmpty { hits = [] }
        if resultsQuery != nil { resultsQuery = nil }
    }

    /// Test seam: waits for the search in flight, if any, to settle.
    func waitForPendingSearch() async {
        await task?.value
    }
}

extension AppState {
    /// Where the Chats list's content search goes, while a dashboard is
    /// connected: its bridge, the profile in use, and the bridge's
    /// `requestJSON`, as the other dashboard routes are asked.
    var sessionContentSearchContext: SessionContentSearchModel.Context? {
        sessionContentSearchContext(acrossAllProfiles: false)
    }

    /// The same, and in All every other included profile too.
    func sessionContentSearchContext(acrossAllProfiles: Bool) -> SessionContentSearchModel.Context? {
        guard isConnected, let bridge = dashboardTicketBridge else { return nil }
        let others = acrossAllProfiles ? allProfilesIncluded.filter { !AppState.profilesMatch($0, activeProfile) } : []
        return SessionContentSearchModel.Context(scope: bridge, profile: activeProfile, otherProfiles: others) { [weak bridge] path in
            guard let bridge else { throw DashboardTicketBridgeError.notReady }
            return try await bridge.requestJSON(path: path)
        }
    }
}
