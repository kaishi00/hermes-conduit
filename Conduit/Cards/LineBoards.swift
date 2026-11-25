//
//  LineBoards.swift
//  Conduit
//
//  Boards a reply names by line, `::conduit-board{id="cb-…"}`, drawn where
//  the line is (issue 3215). conduit_show's answer names its board's line
//  as its `directive`, and a reply of the same turn that writes the line
//  takes the board from the call's row, which then draws nothing; a reply
//  without the line leaves the board at the row. A weak model can also
//  write conduit_show out as text in its reply instead of calling it (Hermes
//  puts plugin tools behind its tool-search bridge, so a card is a call
//  inside a call): the plugin shows that call itself, keeps the board on
//  the host, and the reply holds the line in its place (notifier
//  leaked_calls.py, the plugin's /boards/desktop), so Conduit reads the
//  board from the host. A line naming a board an earlier turn's row drew
//  draws nothing and isn't read.
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

    /// Where a chat's boards go.
    struct Placement: Equatable {
        /// Each reply's board ids it draws where its lines are, in the
        /// lines' order, by the reply's row id: those in `shown`, and those
        /// in `waiting` once read.
        var placed: [String: [String]] = [:]
        /// The boards replies take from a conduit_show row of their turn,
        /// by board id, and the row each came from.
        var shown: [String: RichBoard] = [:]
        var rows: [String: String] = [:]
        /// Each reply's board ids no conduit_show row in the chat drew, to
        /// read from the host, by the reply's row id.
        var waiting: [String: [String]] = [:]

        /// The conduit_show rows that draw nothing: a reply draws their board.
        var hiddenRows: Set<String> { Set(rows.values) }
    }

    /// Where `rows`' boards go. A reply takes a board from a conduit_show
    /// row above it in its own turn (no message of the user's between; a
    /// steer is part of the turn it steers), the
    /// first reply to name it; a board no row in `rows` drew is read from
    /// the host; a line naming an earlier turn's board, or one a reply
    /// already took, places nothing.
    static func placement(in rows: [ChatMessage]) -> Placement {
        var placement = Placement()
        var named: [(reply: String, ids: [String])] = []
        // Every board a row in the chat drew, and the turn's own, not yet taken.
        var drawn: Set<String> = []
        var turn: [String: (row: String, board: RichBoard)] = [:]
        var takers: [String: String] = [:]
        for row in rows {
            switch row.role {
            case .user:
                if !row.isSteer { turn = [:] }
            case .assistant:
                let found = Self.ids(in: row.content)
                guard !found.isEmpty else { continue }
                named.append((row.id, found))
                for id in found {
                    guard let taken = turn.removeValue(forKey: id) else { continue }
                    placement.shown[id] = taken.board
                    placement.rows[id] = taken.row
                    takers[id] = row.id
                }
            case .tool:
                guard let tool = row.tool, tool.name.lowercased() == RichCard.toolName,
                      let output = tool.output, output.contains("conduit-board") else { continue }
                let ids = Self.ids(in: (jsonObject(output)?["directive"] as? String) ?? "")
                // A row whose board can't be drawn here drew none: its
                // line is read from the host, like any board no row drew.
                guard let board = RichBoard.board(for: tool) else { continue }
                drawn.formUnion(ids)
                if let id = ids.first { turn[id] = (row.id, board) }
            default:
                continue
            }
        }
        for (reply, ids) in named {
            let waiting = ids.filter { !drawn.contains($0) }
            if !waiting.isEmpty { placement.waiting[reply] = waiting }
            let placed = ids.filter { takers[$0] == reply || !drawn.contains($0) }
            if !placed.isEmpty { placement.placed[reply] = placed }
        }
        return placement
    }

    /// Each reply's board ids that no conduit_show row in `rows` drew, by
    /// the reply's row id.
    static func waiting(in rows: [ChatMessage]) -> [String: [String]] {
        placement(in: rows).waiting
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
