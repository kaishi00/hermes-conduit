//
//  LineBoards.swift
//  Conduit
//
//  Boards a reply names by line. A weak model can write conduit_show out as
//  text in its reply instead of calling it (Hermes puts plugin tools behind
//  its tool-search bridge, so a card is a call inside a call). The plugin
//  shows that call itself, keeps the board on the host, and the reply holds
//  `::conduit-board{id="cb-…"}` in its place (notifier leaked_calls.py, the
//  plugin's /boards/desktop). Conduit reads the board and draws it under the
//  reply. A line whose board a conduit_show row in the chat already drew
//  (Hermes Desktop's answer names it as its `directive`) isn't read again.
//

import Foundation

enum LineBoards {
    static let capability = "desktop-boards"
    static let path = "/api/plugins/conduit_push/boards/desktop"

    static func readPath(profile: String, id: String) -> String {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "profile", value: profile), URLQueryItem(name: "id", value: id)]
        return path + "?" + (components.percentEncodedQuery ?? "")
    }

    /// The board ids `text`'s lines name, in order, each once: only lines
    /// the chat takes as boards (TranscriptDirectives), so one in code, a
    /// quote or a table is an example and draws nothing.
    static func ids(in text: String) -> [String] {
        var seen: Set<String> = []
        return TranscriptDirectives.boardIDs(in: text).filter { id in
            id.range(of: #"^cb-[0-9a-f]{12}$"#, options: .regularExpression) != nil && seen.insert(id).inserted
        }
    }

    /// Each reply's board ids that no conduit_show row in `rows` drew, by
    /// the reply's row id.
    static func waiting(in rows: [ChatMessage]) -> [String: [String]] {
        var named: [String: [String]] = [:]
        var drawn: Set<String> = []
        for row in rows {
            switch row.role {
            case .assistant:
                let found = Self.ids(in: row.content)
                if !found.isEmpty { named[row.id] = found }
            case .tool:
                guard let tool = row.tool, tool.name.lowercased() == RichCard.toolName,
                      let output = tool.output, output.contains("conduit-board") else { continue }
                drawn.formUnion(Self.ids(in: (jsonObject(output)?["directive"] as? String) ?? ""))
            default:
                continue
            }
        }
        guard !drawn.isEmpty else { return named }
        return named.compactMapValues { named in
            let left = named.filter { !drawn.contains($0) }
            return left.isEmpty ? nil : left
        }
    }

    /// `latest` (each live card's last row, RichCard.latestLiveRows) with
    /// the replies whose read boards bring a live card up to date later in
    /// the chat; `order`: the rows' places in it.
    static func latestLiveRows(_ latest: [String: String], order: [String: Int], waiting: [String: [String]],
                               boards: [String: RichBoard]) -> [String: String] {
        var latest = latest
        let replies = waiting.keys.compactMap { id in order[id].map { (id, $0) } }.sorted { $0.1 < $1.1 }
        for (reply, place) in replies {
            for id in waiting[reply] ?? [] {
                for name in (boards[id]?.cards ?? []).compactMap(\.live)
                where latest[name].flatMap({ order[$0] }).map({ $0 < place }) ?? true {
                    latest[name] = reply
                }
            }
        }
        return latest
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The route's answer as the board it keeps, or nil when Conduit can't
    /// draw it at all.
    static func board(_ answer: [String: Any], id: String) -> RichBoard? {
        guard let body = answer["board"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: ["ok": true].merging(body) { $1 }),
              let output = String(data: data, encoding: .utf8) else { return nil }
        let tool = ToolActivity(id: "line-board-\(id)", name: RichCard.toolName, input: nil, output: output,
                                status: .complete)
        return RichBoard.board(for: tool)
    }
}
