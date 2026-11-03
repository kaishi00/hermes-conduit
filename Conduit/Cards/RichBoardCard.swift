//
//  RichBoardCard.swift
//  Conduit
//
//  The board kinds of rich card (tables, timelines, checklists, lists,
//  progress and callouts) as the views read them, and a board: everything
//  one `conduit_show` call showed, with its layout, its follow-ups and its
//  Markdown (Cards Hermes shows in docs/FEATURE_MAP.md).
//

import Foundation

struct RichTable: Equatable, Hashable {
    let columns: [String]
    /// Each row has one cell per column (the schema's rules).
    let rows: [[String]]

    init?(json: Any?) {
        guard let json = json as? [String: Any], let columns = json["columns"] as? [String], !columns.isEmpty else {
            return nil
        }
        let rows = (json["rows"] as? [[String]] ?? []).filter { $0.count == columns.count }
        guard !rows.isEmpty else { return nil }
        self.columns = columns
        self.rows = rows
    }

    init(columns: [String], rows: [[String]]) {
        self.columns = columns
        self.rows = rows
    }

    /// A cell read as a number to sort by: its digits, sign and decimal
    /// point, whatever unit or currency is around them ("$1.2M" reads as
    /// 1.2 million, "4.5%" as 4.5). Nil for text.
    static func sortNumber(_ cell: String) -> Double? {
        let scalars = Array(cell.unicodeScalars)
        guard let first = scalars.firstIndex(where: { CharacterSet.decimalDigits.contains($0) }) else { return nil }
        var text = ""
        var index = first
        if first > 0, scalars[first - 1] == "-" || scalars[first - 1] == "\u{2212}" { text = "-" }
        while index < scalars.count {
            let scalar = scalars[index]
            if CharacterSet.decimalDigits.contains(scalar) || scalar == "." {
                text.unicodeScalars.append(scalar)
            } else if scalar != "," {
                break
            }
            index += 1
        }
        guard var value = Double(text) else { return nil }
        let rest = String(String.UnicodeScalarView(scalars[index...])).trimmingCharacters(in: .whitespaces)
        switch rest.first.map({ String($0).uppercased() }) {
        case "K": value *= 1e3
        case "M": value *= 1e6
        case "B": value *= 1e9
        case "T": value *= 1e12
        default: break
        }
        return value
    }

    /// Whether a column reads as numbers (every cell that isn't blank does):
    /// it's sorted by value and aligned to the trailing edge.
    func isNumeric(_ column: Int) -> Bool {
        let cells = rows.map { $0[column] }.filter { $0 != RichCardSchema.blankCell }
        return !cells.isEmpty && cells.allSatisfy { Self.sortNumber($0) != nil }
    }

    /// The rows sorted by a column: numbers by value in a numeric column,
    /// text by the user's language otherwise, blanks last either way.
    func sorted(by column: Int, ascending: Bool) -> [[String]] {
        let numeric = isNumeric(column)
        let blanks = rows.filter { $0[column] == RichCardSchema.blankCell }
        let filled = rows.filter { $0[column] != RichCardSchema.blankCell }
        let ordered = filled.enumerated().sorted { left, right in
            let a = left.element[column], b = right.element[column]
            let order: ComparisonResult
            if numeric, let x = Self.sortNumber(a), let y = Self.sortNumber(b) {
                order = x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
            } else {
                order = a.localizedStandardCompare(b)
            }
            // Equal cells keep the order Hermes gave.
            if order == .orderedSame { return left.offset < right.offset }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }.map(\.element)
        return ordered + blanks
    }
}

struct RichTimelineDay: Equatable, Hashable {
    struct Stop: Equatable, Hashable {
        let time: String?
        let text: String
        /// A name and area Apple Maps can find.
        let place: String?
        let note: String?
    }

    let label: String
    let title: String?
    let stops: [Stop]

    init?(json: [String: Any]) {
        guard let label = json["label"] as? String else { return nil }
        let stops = (json["stops"] as? [[String: Any]] ?? []).compactMap { stop -> Stop? in
            guard let text = stop["text"] as? String else { return nil }
            return Stop(time: stop["time"] as? String, text: text, place: stop["place"] as? String,
                        note: stop["note"] as? String)
        }
        guard !stops.isEmpty else { return nil }
        self.label = label
        title = json["title"] as? String
        self.stops = stops
    }
}

struct RichChecklistItem: Equatable, Hashable {
    let text: String
    let group: String?

    init?(json: [String: Any]) {
        guard let text = json["text"] as? String else { return nil }
        self.text = text
        group = json["group"] as? String
    }
}

struct RichListItem: Equatable, Hashable {
    struct Photo: Equatable, Hashable {
        let url: URL
        let source: String
    }

    let title: String
    let detail: String?
    let value: String?
    let url: URL?
    let photo: Photo?

    init?(json: [String: Any]) {
        guard let title = json["title"] as? String else { return nil }
        self.title = title
        detail = json["detail"] as? String
        value = json["value"] as? String
        url = RichJSON.webURL(json["url"])
        if let photo = json["photo"] as? [String: Any], let url = RichJSON.webURL(photo["url"]),
           url.scheme?.lowercased() == "https", let source = photo["source"] as? String {
            self.photo = Photo(url: url, source: source)
        } else {
            photo = nil
        }
    }
}

struct RichProgress: Equatable, Hashable {
    let label: String
    let value: Double
    let goal: Double
    let unit: String?

    init?(json: [String: Any]) {
        guard let label = json["label"] as? String, let value = RichJSON.number(json["value"]),
              let goal = RichJSON.number(json["goal"]), goal > 0, value >= 0 else { return nil }
        self.label = label
        self.value = value
        self.goal = goal
        unit = json["unit"] as? String
    }

    /// How far along, from 0 to 1 (a goal passed is full).
    var fraction: Double { min(value / goal, 1) }
}

struct RichCallout: Equatable, Hashable {
    enum Tone: String {
        case tip, note, warning
    }

    let text: String
    let tone: Tone

    init?(json: Any?) {
        guard let json = json as? [String: Any], let text = json["text"] as? String else { return nil }
        self.text = text
        tone = (json["tone"] as? String).flatMap(Tone.init(rawValue:)) ?? .note
    }
}

/// Everything one finished `conduit_show` call showed in a chat.
struct RichBoard: Equatable {
    let cards: [RichCard]
    /// One card at a time, each card's title its tab.
    let tabs: Bool
    /// The follow-ups a tap sends as the user's message.
    let followUps: [String]
    /// The cards' Markdown, from the plugin (0.128+): shown in the board's
    /// place when Conduit can't draw every card.
    let markdown: String?

    /// The board of a finished `conduit_show` row, or nil when the row
    /// isn't one. A board whose cards can't all be drawn comes back with
    /// no cards and its Markdown, so the row never shows part of it or
    /// nothing at all.
    static func board(for tool: ToolActivity, schema: RichCardSchema? = .bundled) -> RichBoard? {
        guard tool.name.lowercased() == RichCard.toolName, tool.status == .complete else { return nil }
        let answer = RichBoard.jsonObject(tool.output)
        let markdown = (answer?["markdown"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let cards = RichCard.cards(for: tool, schema: schema)
        let given = (answer?["cards"] as? [Any])?.count
            ?? (((answer?["ok"] as? Bool) == true) ? (RichBoard.jsonObject(tool.input)?["cards"] as? [Any])?.count : nil)
            ?? 0
        guard given > 0 || !cards.isEmpty else { return nil }
        if cards.count < given, let markdown {
            return RichBoard(cards: [], tabs: false, followUps: [], markdown: markdown)
        }
        guard !cards.isEmpty else {
            // An older plugin's answer has no Markdown: nothing to draw.
            return nil
        }
        return RichBoard(cards: cards, tabs: answer?["layout"] as? String == "tabs" && cards.count > 1,
                         followUps: RichCardSchema.followUps(answer?["next"]), markdown: markdown)
    }

    /// The newest board in the turn that's last, when it has follow-ups:
    /// nothing has been sent since, so a tap asks the next question.
    static func followUpRow(in rows: [ChatMessage]) -> String? {
        for row in rows.reversed() {
            if row.role == .user { return nil }
            guard row.role == .tool, let tool = row.tool, tool.name.lowercased() == RichCard.toolName else { continue }
            if let board = board(for: tool), !board.followUps.isEmpty { return row.id }
        }
        return nil
    }

    private static func jsonObject(_ text: String?) -> [String: Any]? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
