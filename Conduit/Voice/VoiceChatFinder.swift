//
//  VoiceChatFinder.swift
//  Conduit
//
//  "Find the chat where we talked about the GPU setup and open it": a live
//  call looks up the user's earlier Hermes chats and opens one in Conduit
//  while the call goes on, minimised.
//
//  The search is Hermes' own `GET /api/sessions/search` (session ids, then
//  message text, then titles), on the profile in use. A Hermes without it
//  falls back to the titles of the chats Conduit has listed. The matches
//  are numbered, so the model opens one by its number and never has to
//  repeat a session id aloud or in a tool call.
//

import Foundation

/// One chat a call's search found.
struct VoiceChatMatch: Equatable {
    let sessionID: String
    let title: String
    /// The matching text, without Hermes' match markers; "" when there is none.
    let snippet: String
    let lastActive: Date?
}

/// What a call's chat search came back with.
enum VoiceChatSearchOutcome: Equatable {
    case found([VoiceChatMatch])
    case noMatches
    case failed(String)
}

/// What opening a found chat did.
enum VoiceChatOpenOutcome: Equatable {
    case opened(title: String)
    /// The number or id names none of the last search's matches.
    case unknownChat
    /// Conduit couldn't open chats right now (not connected).
    case unavailable
}

enum VoiceChatFinder {
    static let searchPath = "/api/sessions/search"
    /// Matches a search hands the model: enough to pick from, few enough to read out.
    static let resultLimit = 5
    static let maximumQueryCharacters = 200
    static let maximumSnippetCharacters = 160

    /// The query Hermes' full-text search can take: words only. FTS5 reads
    /// quotes, dashes, colons and asterisks as syntax, and the endpoint adds
    /// its own prefix wildcards.
    static func searchQuery(_ raw: String) -> String {
        let cleaned = raw.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        // Whole words only: a cut word would be searched as a fragment.
        var query = ""
        for word in String(cleaned).split(whereSeparator: \.isWhitespace) {
            let next = query.isEmpty ? String(word) : query + " " + word
            guard next.count <= maximumQueryCharacters else { break }
            query = next
        }
        return query
    }

    /// The match number in "2", "#2" or "number 2"; nil for anything else,
    /// so an id that merely holds digits never opens a numbered match.
    static func matchNumber(_ reference: String) -> Int? {
        guard let range = reference.range(of: #"^(?:(?:number|no\.?|#)\s*)?(\d{1,2})$"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return Int(reference[range].filter(\.isNumber))
    }

    /// The words a search that matched nothing tries one at a time, longest
    /// first: Hermes needs every word of a query to match, and a model's
    /// query often carries one word the chat never used.
    static func fallbackWords(_ query: String) -> [String] {
        let words = query.split(separator: " ").map(String.init)
        guard words.count > 1 else { return [] }
        var seen = Set<String>()
        let distinct = words.filter { $0.count > 2 && seen.insert($0.lowercased()).inserted }
        return Array(distinct.sorted { $0.count > $1.count }.prefix(2))
    }

    static func path(query: String, profile: String) -> String {
        let encoded = DashboardPath.encodedQueryComponent(query) ?? ""
        return DashboardPath.withProfile("\(searchPath)?q=\(encoded)&limit=\(resultLimit)", profile: profile)
    }

    /// The search response's chats, in Hermes' order.
    static func matches(from response: [String: Any]) -> [VoiceChatMatch] {
        guard let rows = response["results"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return rows.compactMap { row -> VoiceChatMatch? in
            let id = (text(row["session_id"]) ?? text(row["id"]) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            let title = (row["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let active = epoch(row["last_active"]) ?? epoch(row["session_started"]) ?? epoch(row["started_at"])
            return VoiceChatMatch(
                sessionID: id,
                title: title,
                snippet: plainSnippet(row["snippet"] as? String ?? ""),
                lastActive: active.map { Date(timeIntervalSince1970: $0) }
            )
        }
    }

    /// Chats whose titles hold every word of `query`, newest first: what a
    /// Hermes without the search endpoint can still be asked.
    static func titleMatches(in sessions: [SessionSummary], query: String) -> [VoiceChatMatch] {
        let words = query.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let hits = sessions.filter { session in
            !session.isArchived && words.allSatisfy { session.title.localizedCaseInsensitiveContains($0) }
        }
        let ordered = hits.enumerated().sorted { lhs, rhs in
            let left = lhs.element.lastActivityAt ?? 0
            let right = rhs.element.lastActivityAt ?? 0
            return left == right ? lhs.offset < rhs.offset : left > right
        }
        return ordered.prefix(resultLimit).map { _, session in
            VoiceChatMatch(
                sessionID: session.storedSessionId ?? session.id,
                title: session.title,
                snippet: "",
                lastActive: session.lastActivityAt.map { Date(timeIntervalSince1970: $0) }
            )
        }
    }

    /// Hermes marks the matched words `>>>like this<<<`; the model hears the
    /// text without them, on one line, clipped.
    static func plainSnippet(_ raw: String) -> String {
        let unmarked = raw.replacingOccurrences(of: ">>>", with: "").replacingOccurrences(of: "<<<", with: "")
        let line = unmarked.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > maximumSnippetCharacters else { return line }
        return String(line.prefix(maximumSnippetCharacters)) + "…"
    }

    /// The matches as numbered lines for the model. Not UI copy, so not localized.
    static func summary(_ matches: [VoiceChatMatch], now: Date = Date()) -> String {
        matches.enumerated().map { index, match in
            let title = match.title.isEmpty ? "Untitled chat" : "\"\(match.title)\""
            var line = "\(index + 1). \(title)"
            if let when = match.lastActive { line += ", last active \(spokenAge(of: when, now: now))" }
            if !match.snippet.isEmpty { line += ": \(match.snippet)" }
            return line
        }.joined(separator: "\n")
    }

    /// "today", "yesterday", "3 days ago", in English: the model says it in
    /// the user's language itself.
    static func spokenAge(of date: Date, now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "today"
        case 1: return "yesterday"
        case 2..<14: return "\(days) days ago"
        case 14..<60: return "\(days / 7) weeks ago"
        case 60..<730: return "\(days / 30) months ago"
        default: return "\(days / 365) years ago"
        }
    }

    private static func text(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        return (value as? NSNumber)?.stringValue
    }

    private static func epoch(_ value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber {
            let seconds = number.doubleValue
            return seconds > 0 ? seconds : nil
        }
        if let text = value as? String, let seconds = Double(text), seconds > 0 { return seconds }
        return nil
    }
}
