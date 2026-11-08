//
//  RoomBoards.swift
//  Conduit
//
//  Boards in group rooms. A room's log carries messages only, so a board an
//  agent shows there is kept on the host (the plugin's /boards/rooms, 0.129+)
//  with the profile that showed it and when; the room draws each under the
//  next message that agent posts.
//

import SwiftUI

struct RoomBoard: Equatable {
    let profile: String
    let at: Double
    let board: RichBoard

    static let capability = "room-boards"
    static let path = "/api/plugins/conduit_push/boards/rooms"
    /// A board waits this long for its agent's message; one whose turn ended
    /// without a message never lands on a later one.
    static let landsWithin: Double = 15 * 60
    /// The host's and the room's clocks can differ a little.
    static let clockSlack: Double = 5

    static func readPath(profile: String, roomID: String) -> String {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "profile", value: profile),
                                 URLQueryItem(name: "room_id", value: roomID)]
        return path + "?" + (components.percentEncodedQuery ?? "")
    }

    /// The route's answer as boards, oldest first. A board Conduit can't
    /// draw at all is left out.
    static func boards(_ answer: [String: Any]) -> [RoomBoard] {
        let rows = answer["boards"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let profile = row["profile"] as? String, !profile.isEmpty,
                  let at = (row["at"] as? NSNumber)?.doubleValue,
                  let body = row["board"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: ["ok": true].merging(body) { $1 }),
                  let output = String(data: data, encoding: .utf8) else { return nil }
            let tool = ToolActivity(id: "room-board-\(at)", name: RichCard.toolName, input: nil, output: output,
                                    status: .complete)
            return RichBoard.board(for: tool).map { RoomBoard(profile: profile, at: at, board: $0) }
        }
        .sorted { $0.at < $1.at }
    }

    /// Each board under the first message its agent posted at or after it,
    /// keyed by the message's event id; several boards of one turn go under
    /// the same message, in order.
    static func placed(_ boards: [RoomBoard], in events: [GroupEvent]) -> [String: [RichBoard]] {
        var placed: [String: [RichBoard]] = [:]
        let messages = events.filter(\.isMemberMessage)
        for board in boards {
            let profile = board.profile.lowercased()
            guard let message = messages.first(where: { event in
                let speaker = (event.actor.profile ?? event.actor.id).lowercased()
                return speaker == profile && event.createdAt >= board.at - clockSlack
                    && event.createdAt <= board.at + landsWithin
            }) else { continue }
            placed[message.id, default: []].append(board.board)
        }
        return placed
    }
}

/// A room message's boards, under its bubble: the board's cards, read-only
/// (a room's checklists keep no ticks), with no follow-ups.
struct RoomBoardsView: View {
    let boards: [RichBoard]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(boards.enumerated()), id: \.offset) { _, board in
                if board.cards.isEmpty, let markdown = board.markdown {
                    // A board this Conduit can't fully draw: its text.
                    RichBoardMarkdown(markdown: markdown)
                } else {
                    RichCardsView(cards: board.cards, tabs: board.tabs)
                }
            }
        }
        .environment(\.richChecklistInChat, true)
        .environment(\.richChecklistContext, nil)
    }
}
