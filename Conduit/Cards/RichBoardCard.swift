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

    /// A cell read as a number to sort by: one that starts the cell (after
    /// a sign or a currency) and is the cell's only number, whatever unit is
    /// after it ("$1.2M" reads as 1.2 million, "4.5%" as 4.5, "1,250 kg" as
    /// 1250). A letter before it ("Nov 3") or another number after it
    /// ("2026-11-03") makes the cell text. Nil for text.
    static func sortNumber(_ cell: String) -> Double? {
        let scalars = Array(cell.unicodeScalars)
        guard let first = scalars.firstIndex(where: { CharacterSet.decimalDigits.contains($0) }) else { return nil }
        let before = scalars[..<first]
        guard !before.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }
        var token = ""
        var index = first
        while index < scalars.count {
            let scalar = scalars[index]
            guard CharacterSet.decimalDigits.contains(scalar) || scalar == "." || scalar == "," else { break }
            token.unicodeScalars.append(scalar)
            index += 1
        }
        // A sign or accounting brackets anywhere before it: "-4.5", "-$4.5M", "($4.5M)".
        let sign = before.contains(where: { $0 == "-" || $0 == "\u{2212}" || $0 == "(" }) ? "-" : ""
        guard let digits = Self.plainDigits(token), var value = Double(sign + digits) else { return nil }
        let rest = Array(scalars[index...])
        guard !rest.contains(where: { CharacterSet.decimalDigits.contains($0) }) else { return nil }
        // A multiplier only right after the number, as a word of its own
        // ("1.2M", "950K", never "5 m" or "3 kg"), or as a size's prefix
        // ("900KB", "2MB", "512GB", "3TB").
        // Either case: "$950m", "2b", "512gb".
        if let first = rest.first {
            let letter = String(first).uppercased()
            let alone = rest.count == 1 || !CharacterSet.letters.contains(rest[1])
            let size = rest.count >= 2 && (rest[1] == "B" || rest[1] == "b")
                && (rest.count == 2 || !CharacterSet.letters.contains(rest[2]))
            switch (letter, alone, size) {
            case ("K", true, _), ("K", _, true): value *= 1e3
            case ("M", true, _), ("M", _, true): value *= 1e6
            case ("B", true, _), ("G", _, true): value *= 1e9
            case ("T", true, _), ("T", _, true): value *= 1e12
            default: break
            }
        }
        return value
    }

    /// A number's digits with "." as its decimal point, either way it was
    /// written: "1,250.5" and "1.250,5" are both 1250.5, "980,00" is 980,
    /// "1.250.000" is a million and a quarter. A lone "." stays a decimal
    /// point ("1.250" is 1.25).
    static func plainDigits(_ token: String) -> String? {
        // A sentence's full stop or comma after it isn't part of it.
        var token = Substring(token)
        while token.last == "." || token.last == "," { token = token.dropLast() }
        guard !token.isEmpty else { return nil }
        let dots = token.filter { $0 == "." }.count, commas = token.filter { $0 == "," }.count
        let decimal: Character?
        if let dot = token.lastIndex(of: "."), let comma = token.lastIndex(of: ",") {
            decimal = dot > comma ? "." : ","
        } else if commas == 1 {
            // "1,250" groups thousands; "980,00" and "4,5" have a decimal comma.
            decimal = token.split(separator: ",", omittingEmptySubsequences: false).last?.count == 3 ? nil : ","
        } else if dots == 1 {
            decimal = "."
        } else {
            decimal = nil
        }
        var digits = ""
        for character in token {
            if character == decimal {
                digits.append(".")
            } else if character.isNumber {
                digits.append(character)
            }
        }
        return digits
    }

    /// Whether a column reads as numbers (every cell that isn't blank does):
    /// it's sorted by value and aligned to the trailing edge.
    func isNumeric(_ column: Int) -> Bool {
        guard columns.indices.contains(column) else { return false }
        let cells = rows.map { $0[column] }.filter { $0 != RichCardSchema.blankCell }
        return !cells.isEmpty && cells.allSatisfy { Self.sortNumber($0) != nil }
    }

    /// The rows sorted by a column: numbers by value in a numeric column,
    /// text by the user's language otherwise, blanks last either way.
    func sorted(by column: Int, ascending: Bool) -> [[String]] {
        // A sort kept from another table can name a column this one lacks.
        guard columns.indices.contains(column) else { return rows }
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
    ///
    /// A row's body asks on every publish while it's on screen, so each
    /// finished answer is read once and kept (issue 1851): an answer can
    /// be megabytes of JSON.
    static func board(for tool: ToolActivity) -> RichBoard? {
        guard tool.name.lowercased() == RichCard.toolName, tool.status == .complete else { return nil }
        return boards.value(for: tool) { board(for: tool, schema: .bundled) }
    }

    private static let boards = FinishedToolMemo<RichBoard?>()

    /// `board(for:)` read against `schema`, not kept.
    static func board(for tool: ToolActivity, schema: RichCardSchema?) -> RichBoard? {
        guard tool.name.lowercased() == RichCard.toolName, tool.status == .complete else { return nil }
        let answer = RichBoard.jsonObject(tool.output)
        // The fallback is card text too (issue 1867): what it draws and
        // copies is the cleaned string.
        let markdown = (answer?["markdown"] as? String).map(RichCardSchema.cleanMarkdown)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let cards = RichCard.cards(for: tool, schema: schema)
        let given = (answer?["cards"] as? [Any])?.count
            ?? (((answer?["ok"] as? Bool) == true) ? (RichBoard.jsonObject(tool.input)?["cards"] as? [Any])?.count : nil)
            ?? 0
        // No cards given is no board: a Markdown-only show, or an answer
        // whose Markdown Hermes was told to put in its reply (not_conduit,
        // group_room), which would show twice.
        guard given > 0 || !cards.isEmpty else { return nil }
        if cards.count < given, let markdown {
            return RichBoard(cards: [], tabs: false, followUps: RichCardSchema.followUps(answer?["next"]),
                             markdown: markdown)
        }
        guard !cards.isEmpty else {
            // An older plugin's answer has no Markdown: nothing to draw.
            return nil
        }
        return RichBoard(cards: cards, tabs: answer?["layout"] as? String == "tabs" && cards.count > 1,
                         followUps: RichCardSchema.followUps(answer?["next"]), markdown: markdown)
    }

    /// The last turn's last board, when it has follow-ups: nothing has
    /// been sent since, so a tap asks the next question. A board shown after
    /// it without follow-ups means there are none to offer.
    static func followUpRow(in rows: [ChatMessage]) -> String? {
        for row in rows.reversed() {
            if row.role == .user { return nil }
            guard row.role == .tool, let tool = row.tool, tool.name.lowercased() == RichCard.toolName,
                  let board = board(for: tool) else { continue }
            return board.followUps.isEmpty ? nil : row.id
        }
        return nil
    }

    private static func jsonObject(_ text: String?) -> [String: Any]? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// What Conduit read from finished tool rows, kept so a row drawn again
/// isn't read again. A finished call's input and output don't change, but a
/// row can be replaced (history read again, an id reused), so an entry is
/// used only while the call's name, input and output are still the same.
/// Comparing a string the row still holds with the one kept is a pointer
/// check; an equal copy read again is compared once, then kept in its place.
/// It keeps at most `limit` rows and about `byteBudget` of their text, so
/// closed chats' answers don't stay in memory for long.
final class FinishedToolMemo<Value>: @unchecked Sendable {
    private struct Key: Hashable {
        let id: String
        // Counts only: hashing a megabyte answer on every look-up costs
        // what the memo saves.
        let input: Int
        let output: Int
    }

    private struct Entry {
        var name: String
        var input: String?
        var output: String?
        let value: Value
    }

    private let limit: Int
    private let byteBudget: Int
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var bytes = 0

    init(limit: Int = 200, byteBudget: Int = 16_000_000) {
        self.limit = limit
        self.byteBudget = byteBudget
    }

    /// The value kept for `tool` under `id` (the tool call's id when nil),
    /// or `make()`'s, kept for next time.
    func value(for tool: ToolActivity, id: String? = nil, make: () -> Value) -> Value {
        let key = Key(id: id ?? tool.id ?? "", input: tool.input?.utf8.count ?? -1,
                      output: tool.output?.utf8.count ?? -1)
        lock.lock()
        if var entry = entries[key], entry.name == tool.name, entry.input == tool.input, entry.output == tool.output {
            // Keep the row's own strings, so the next check is a pointer's.
            entry.input = tool.input
            entry.output = tool.output
            entries[key] = entry
            lock.unlock()
            return entry.value
        }
        lock.unlock()
        let value = make()
        let size = max(key.input, 0) + max(key.output, 0)
        lock.lock()
        if let old = entries[key] {
            bytes -= (old.input?.utf8.count ?? 0) + (old.output?.utf8.count ?? 0)
        }
        if entries.count >= limit || bytes + size > byteBudget {
            entries.removeAll(keepingCapacity: true)
            bytes = 0
        }
        entries[key] = Entry(name: tool.name, input: tool.input, output: tool.output, value: value)
        bytes += size
        lock.unlock()
        return value
    }
}
