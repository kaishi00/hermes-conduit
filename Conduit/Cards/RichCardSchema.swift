//
//  RichCardSchema.swift
//  Conduit
//
//  Rich cards (maps, places, stats, charts, forecasts, comparisons, steps,
//  media, contacts, statuses, and the board kinds: tables, timelines,
//  checklists, lists, progress and callouts) are defined once, in hermes-conduit-notifier's
//  cards/card-schema.json. This app ships a byte-identical copy
//  (card-schema.json beside this file); scripts/check-card-schema.py fails
//  CI when it differs from the plugin's main. Only the rules name a card's
//  fields: the live models' show_on_screen parameter is built from the
//  copy, and normalizing walks it, the same way the plugin's card_schema.py
//  does. Both run the plugin's cards/card-vectors.json (RichCardSchemaTests):
//
//  - a table's cells and column names are made text first, so each keeps
//    its place (prepared);
//  - unknown keys are dropped;
//  - text has control characters turned into spaces and hidden bidi and
//    zero-width characters dropped (in a line each shows as U+FFFD, and a
//    line is never trimmed), is trimmed, and is cut to maxLength code points (a URL that's too long, or holds a space,
//    quote, bracket or parenthesis, is invalid instead);
//  - an invalid optional value is dropped, an invalid list item is dropped
//    (then the list is cut to maxItems), and an invalid required value
//    makes its object invalid;
//  - enums match without regard to case and come out as the schema writes
//    them;
//  - then the schema's rules: a card keeps only its type's fields and needs
//    its type's own; a route only on a map whose places all survived,
//    naming places in the list, from one to another; a place card keeps
//    its first place; a place's or person's photo needs an https url; a
//    chart keeps the series that fit its labels (one,
//    never negative, for a pie); a forecast needs a source and something
//    to show, and drops a day whose low is above its high; a comparison
//    recommends one option at most; media needs a source and https links,
//    and an image has no duration or artwork; a contact keeps only a phone and an email
//    that look like one, and a person's message only with their phone; a
//    table keeps the rows with one cell per column; a checklist keeps one
//    item per text; a list item's photo needs an https url; a progress goal
//    is above 0; a diff hunk keeps the lines that start with +, - or a
//    space, a binary file no lines, and an id only the host's; a live name
//    is kept on the first card of a set that has it.
//  - a diff line (format line) keeps its spaces: never trimmed. The plugin
//    reads a patch into those lines; the app only ever sees them read.
//

import Foundation

struct RichCardSchema {
    let version: Int
    let maxCards: Int
    /// The card's JSON Schema, as the file has it.
    let card: [String: Any]

    /// The bundled copy; nil only in a build that lost the file, where
    /// cards are simply never drawn or offered.
    static let bundled: RichCardSchema? = {
        guard let url = Bundle.main.url(forResource: "card-schema", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return RichCardSchema(data: data)
    }()

    init?(data: Data) {
        guard let definition = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = definition["version"] as? Int,
              let maxCards = definition["max_cards"] as? Int,
              let card = definition["card"] as? [String: Any] else { return nil }
        self.version = version
        self.maxCards = maxCards
        self.card = card
    }

    // MARK: Normalizing

    /// The valid cards in `value`, normalized; invalid ones are dropped.
    func normalizeCards(_ value: Any?) -> [[String: Any]] {
        guard let list = value as? [Any] else { return [] }
        var cards: [[String: Any]] = []
        var live: Set<String> = []
        for raw in list {
            if cards.count == maxCards { break }
            guard var card = normalizeCard(raw) else { continue }
            if let name = card["live"] as? String, !live.insert(name).inserted {
                card["live"] = nil
            }
            cards.append(card)
        }
        return cards
    }

    /// One card, or nil when it isn't valid.
    func normalizeCard(_ raw: Any) -> [String: Any]? {
        let raw = Self.prepared(raw)
        guard case .valid(let value) = Self.normalize(card, raw), let normalized = value as? [String: Any] else {
            return nil
        }
        return Self.applyRules(normalized, raw: raw as? [String: Any] ?? [:])
    }

    /// What a table cell with nothing in it reads as.
    static let blankCell = "\u{2013}"

    /// A table's cells and column names as text, so a number, a blank or a
    /// null keeps its place in the row (the plugin's _prepared): a string
    /// stays as it is (an empty one is a dash), a number becomes its digits,
    /// anything else is a dash.
    static func prepared(_ raw: Any) -> Any {
        guard var object = raw as? [String: Any], (object["type"] as? String).map({ cleanText($0).lowercased() }) == "table",
              var table = object["table"] as? [String: Any] else { return raw }
        if let columns = table["columns"] as? [Any] {
            table["columns"] = columns.map(cell)
        }
        if let rows = table["rows"] as? [Any] {
            table["rows"] = rows.map { row -> Any in (row as? [Any]).map { $0.map(cell) } ?? row }
        }
        object["table"] = table
        return object
    }

    static func cell(_ value: Any) -> Any {
        if let text = value as? String {
            return cleanText(text).isEmpty ? blankCell : text
        }
        guard let number = value as? NSNumber, !isBoolean(number) else { return blankCell }
        let double = number.doubleValue
        guard double.isFinite, abs(double) < 1e15 else { return blankCell }
        if double.rounded() == double {
            return String(Int(double))
        }
        return "\(double)"
    }

    private enum Outcome {
        case valid(Any)
        case invalid
    }

    private static func normalize(_ schema: [String: Any], _ value: Any) -> Outcome {
        switch schema["type"] as? String {
        case "object":
            guard let object = value as? [String: Any] else { return .invalid }
            let required = Set(schema["required"] as? [String] ?? [])
            var result: [String: Any] = [:]
            for (key, inner) in schema["properties"] as? [String: Any] ?? [:] {
                guard let inner = inner as? [String: Any] else { continue }
                guard let given = object[key], !(given is NSNull) else {
                    if required.contains(key) { return .invalid }
                    continue
                }
                switch normalize(inner, given) {
                case .valid(let clean): result[key] = clean
                case .invalid: if required.contains(key) { return .invalid }
                }
            }
            return .valid(result)
        case "array":
            guard let list = value as? [Any], let itemSchema = schema["items"] as? [String: Any] else { return .invalid }
            let maxItems = schema["maxItems"] as? Int
            var items: [Any] = []
            for raw in list {
                if let maxItems, items.count == maxItems { break }
                if case .valid(let clean) = normalize(itemSchema, raw) { items.append(clean) }
            }
            if items.count < (schema["minItems"] as? Int ?? 0) { return .invalid }
            return .valid(items)
        case "string":
            guard let raw = value as? String else { return .invalid }
            let limit = schema["maxLength"] as? Int
            if schema["format"] as? String == "line" {
                // A line of code or text keeps its spaces: never trimmed.
                let line = cleanLine(raw)
                guard !line.isEmpty else { return .invalid }
                guard let limit, line.unicodeScalars.count > limit else { return .valid(line) }
                return .valid(String(String.UnicodeScalarView(line.unicodeScalars.prefix(limit))))
            }
            let text = cleanText(raw)
            guard !text.isEmpty else { return .invalid }
            if schema["format"] as? String == "uri" {
                guard isURI(text), limit.map({ text.unicodeScalars.count <= $0 }) ?? true else { return .invalid }
                return .valid(text)
            }
            var cut = text
            if let limit, text.unicodeScalars.count > limit {
                cut = String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit)))
                cut = trimmingTrailingWhitespace(cut)
            }
            if let options = schema["enum"] as? [String] {
                guard let option = options.first(where: { $0.lowercased() == cut.lowercased() }) else { return .invalid }
                return .valid(option)
            }
            return .valid(cut)
        case "number", "integer":
            guard let number = value as? NSNumber, !isBoolean(number) else { return .invalid }
            let double = number.doubleValue
            guard double.isFinite else { return .invalid }
            var clean: Any = double
            if schema["type"] as? String == "integer" {
                guard double.rounded() == double, abs(double) < 1e15 else { return .invalid }
                clean = Int(double)
            }
            if let minimum = (schema["minimum"] as? NSNumber)?.doubleValue, double < minimum { return .invalid }
            if let maximum = (schema["maximum"] as? NSNumber)?.doubleValue, double > maximum { return .invalid }
            return .valid(clean)
        case "boolean":
            guard let number = value as? NSNumber, isBoolean(number) else { return .invalid }
            return .valid(number.boolValue)
        default:
            return .invalid
        }
    }

    /// Invisible characters that can make text read differently from what it
    /// holds (Trojan Source, issue 1852): the bidi embeddings, overrides and
    /// isolates, and the zero-width space, word joiner and BOM (the plugin's
    /// _HIDDEN). ZWJ and ZWNJ stay (emoji, Persian and Indic spelling need
    /// them), and so do the plain marks LRM, RLM and ALM.
    static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x202A...0x202E, 0x2066...0x2069, 0x200B, 0x2060, 0xFEFF: return true
        default: return false
        }
    }

    /// Control characters become spaces and hidden ones are dropped; trimmed.
    static func cleanText(_ text: String) -> String {
        cleaned(text, hidden: nil).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Control characters become spaces; a hidden one becomes U+FFFD, so a
    /// line of code shows where one was and a copied patch doesn't hide it.
    static func cleanLine(_ text: String) -> String {
        cleaned(text, hidden: "\u{FFFD}")
    }

    /// A board's Markdown fallback (issue 1867): a hidden character becomes
    /// U+FFFD, as in a line, and control characters other than line breaks
    /// and tabs become spaces, so the Markdown keeps its lines.
    static func cleanMarkdown(_ text: String) -> String {
        cleaned(text, hidden: "\u{FFFD}", keeping: ["\n", "\r", "\t"])
    }

    private static func cleaned(_ text: String, hidden: Unicode.Scalar?, keeping: Set<Unicode.Scalar> = []) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if keeping.contains(scalar) {
                scalars.append(scalar)
            } else if scalar.properties.generalCategory == .control {
                scalars.append(" ")
            } else if isHidden(scalar) {
                if let hidden { scalars.append(hidden) }
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        while let last = scalars.last, CharacterSet.whitespacesAndNewlines.contains(last) { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    /// No spaces, quotes, brackets or parentheses: the plugin also puts a
    /// URL inside a Markdown link, where any of them could end it early.
    private static let uriExcluded = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "()<>[]{}\"'`\\"))

    private static func isURI(_ text: String) -> Bool {
        let lowered = text.lowercased()
        guard lowered.hasPrefix("https://") || lowered.hasPrefix("http://") else { return false }
        let rest = text.unicodeScalars.dropFirst(lowered.hasPrefix("https://") ? 8 : 7)
        return !rest.isEmpty && !rest.contains { uriExcluded.contains($0) }
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Each type's own fields, its main one first; a card keeps them and
    /// the shared ones, and nothing else.
    private static let typeFields: [String: [String]] = [
        "map": ["places", "route"], "place": ["places"], "places": ["places"], "stats": ["stats"],
        "chart": ["chart"], "weather": ["weather"], "comparison": ["options"], "steps": ["steps", "needs"],
        "media": ["media"], "contact": ["people"], "status": ["status"], "table": ["table"],
        "timeline": ["timeline"], "checklist": ["checklist"], "list": ["list", "ranked"],
        "progress": ["progress"], "callout": ["callout"], "diff": ["diff"],
    ]

    /// The cards about places; every other type can name a source.
    static let placeTypes: Set<String> = ["map", "place", "places"]

    /// A phone number's characters, and an address with nothing that could
    /// end a link or a header early, or add a header or recipient to its
    /// mailto: link (the plugin's _PHONE and _EMAIL).
    private static let phonePattern = try! NSRegularExpression(pattern: #"^[0-9+\-(). ]+$"#)
    private static let emailPattern = try! NSRegularExpression(
        pattern: #"^[^@\s<>()\[\]"'`,;:\\?#%&=]+@[^@\s<>()\[\]"'`,;:\\?#%&=]+\.[^@\s<>()\[\]"'`,;:\\?#%&=.]+$"#)

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func isPhone(_ text: String) -> Bool {
        let digits = text.unicodeScalars.filter { (48...57).contains($0.value) }.count
        return matches(phonePattern, text) && (3...20).contains(digits)
    }

    private static func isHTTPS(_ value: Any?) -> Bool {
        (value as? String).map { $0.prefix(8).lowercased() == "https://" } ?? false
    }

    static func isEmail(_ text: String) -> Bool {
        matches(emailPattern, text)
    }

    /// The card after the schema's rules, or nil when they drop it.
    private static func applyRules(_ card: [String: Any], raw: [String: Any]) -> [String: Any]? {
        guard let type = card["type"] as? String, let fields = typeFields[type], let field = fields.first else { return nil }
        var keep = Set(fields).union(["type", "title", "live"])
        if !placeTypes.contains(type) { keep.insert("source") }
        var card = card.filter { keep.contains($0.key) }
        guard card[field] != nil else { return nil }
        switch type {
        case "map", "place", "places":
            placeRules(&card, raw: raw)
        case "chart":
            guard let chart = chartRules(card["chart"] as? [String: Any] ?? [:]) else { return nil }
            card["chart"] = chart
        case "weather":
            var weather = card["weather"] as? [String: Any] ?? [:]
            if let days = weather["days"] as? [[String: Any]] {
                weather["days"] = days.filter { (($0["low"] as? NSNumber)?.doubleValue ?? 0) <= (($0["high"] as? NSNumber)?.doubleValue ?? 0) }
            }
            // An empty list counts as none.
            for key in ["hours", "days"] where (weather[key] as? [Any])?.isEmpty == true {
                weather.removeValue(forKey: key)
            }
            card["weather"] = weather
            guard card["source"] != nil, ["now", "hours", "days"].contains(where: { weather[$0] != nil }) else { return nil }
        case "comparison":
            var seen = false
            card["options"] = (card["options"] as? [[String: Any]] ?? []).map { option in
                guard (option["recommended"] as? Bool) == true else { return option }
                defer { seen = true }
                var option = option
                if seen { option["recommended"] = nil }
                return option
            }
        case "media":
            guard card["source"] != nil else { return nil }
            // The phone loads media over https only.
            let media = (card["media"] as? [[String: Any]] ?? []).filter { isHTTPS($0["url"]) }
            guard !media.isEmpty else { return nil }
            card["media"] = media.map { item in
                var item = item
                if item["kind"] as? String == "image" || (item["artwork"] != nil && !isHTTPS(item["artwork"])) {
                    item["artwork"] = nil
                }
                if item["kind"] as? String == "image" { item["duration"] = nil }
                return item
            }
        case "contact":
            card["people"] = (card["people"] as? [[String: Any]] ?? []).map { person in
                var person = person
                if let phone = person["phone"] as? String, !isPhone(phone) { person["phone"] = nil }
                if let email = person["email"] as? String, !isEmail(email) { person["email"] = nil }
                // A text goes to their number, so there's none without it.
                if person["phone"] == nil { person["message"] = nil }
                // The phone loads photos over https only.
                if let photo = person["photo"] as? [String: Any], !isHTTPS(photo["url"]) { person["photo"] = nil }
                return person
            }
        case "table":
            var table = card["table"] as? [String: Any] ?? [:]
            let width = (table["columns"] as? [Any])?.count ?? 0
            let rows = (table["rows"] as? [[Any]] ?? []).filter { $0.count == width }
            guard !rows.isEmpty else { return nil }
            table["rows"] = rows
            card["table"] = table
        case "checklist":
            var seen: Set<String> = []
            card["checklist"] = (card["checklist"] as? [[String: Any]] ?? []).filter { item in
                seen.insert((item["text"] as? String ?? "").lowercased()).inserted
            }
        case "list":
            card["list"] = (card["list"] as? [[String: Any]] ?? []).map { item in
                var item = item
                // The phone loads photos over https only.
                if let photo = item["photo"] as? [String: Any], !isHTTPS(photo["url"]) { item["photo"] = nil }
                return item
            }
        case "progress":
            let items = (card["progress"] as? [[String: Any]] ?? []).filter {
                (($0["goal"] as? NSNumber)?.doubleValue ?? 0) > 0
            }
            guard !items.isEmpty else { return nil }
            card["progress"] = items
        case "diff":
            card["diff"] = diffRules(card["diff"] as? [String: Any] ?? [:])
        default:
            break
        }
        return card
    }

    // MARK: Diffs

    private static let diffID = try! NSRegularExpression(pattern: #"^cd-[0-9a-f]{16}$"#)

    /// Whether an id names a diff the host keeps.
    static func isDiffID(_ text: String) -> Bool {
        matches(diffID, text)
    }

    /// A line a patch can hold: + added, - removed, a space unchanged.
    static func isDiffLine(_ line: String) -> Bool {
        guard let first = line.unicodeScalars.first else { return false }
        return first == "+" || first == "-" || first == " "
    }

    /// A hunk keeps the lines a patch can hold (+, - or a space first) and
    /// goes when none is left; a binary file has no lines; an id is the
    /// host's (the plugin's _diff_rules).
    private static func diffRules(_ diff: [String: Any]) -> [String: Any] {
        var diff = diff
        if let id = diff["id"] as? String, !isDiffID(id) { diff["id"] = nil }
        diff["files"] = (diff["files"] as? [[String: Any]] ?? []).map { file in
            var file = file
            if (file["binary"] as? Bool) == true { file["hunks"] = nil }
            let hunks: [[String: Any]] = (file["hunks"] as? [[String: Any]] ?? []).compactMap { hunk in
                let lines = (hunk["lines"] as? [String] ?? []).filter(isDiffLine)
                guard !lines.isEmpty else { return nil }
                var hunk = hunk
                hunk["lines"] = lines
                return hunk
            }
            file["hunks"] = hunks.isEmpty ? nil : hunks
            return file
        }
        return diff
    }

    /// A whole diff the host kept (GET /boards/diffs), checked as a diff
    /// card's is; nil when it isn't one.
    func normalizeDiff(_ value: Any?) -> [String: Any]? {
        guard let value else { return nil }
        return normalizeCard(["type": "diff", "diff": value])?["diff"] as? [String: Any]
    }

    // MARK: A board's follow-ups

    /// The most follow-ups a board shows (the schema's board.next).
    static let maxFollowUps = 4
    private static let followUpMention = try! NSRegularExpression(pattern: #"@[\w/.~]"#)

    /// The follow-ups worth offering under a board (the plugin's
    /// normalize_next): plain messages only, each once, the first four.
    static func followUps(_ value: Any?) -> [String] {
        guard let list = value as? [Any] else { return [] }
        var kept: [String] = []
        for raw in list {
            guard let given = raw as? String else { continue }
            var text = cleanText(given)
            guard !text.isEmpty else { continue }
            if text.unicodeScalars.count > 200 {
                text = trimmingTrailingWhitespace(String(String.UnicodeScalarView(text.unicodeScalars.prefix(200))))
            }
            if text.hasPrefix("/") || text.hasPrefix("!") || text.contains("`") || matches(followUpMention, text) {
                continue
            }
            if kept.contains(where: { $0.lowercased() == text.lowercased() }) { continue }
            if kept.count == maxFollowUps { break }
            kept.append(text)
        }
        return kept
    }

    private static func placeRules(_ card: inout [String: Any], raw: [String: Any]) {
        let type = card["type"] as? String
        var places = card["places"] as? [Any] ?? []
        if type == "place" {
            places = Array(places.prefix(1))
        }
        // The phone loads photos over https only.
        card["places"] = places.map { place -> Any in
            guard var place = place as? [String: Any], let photo = place["photo"] as? [String: Any], !isHTTPS(photo["url"]) else { return place }
            place["photo"] = nil
            return place
        }
        guard let route = card.removeValue(forKey: "route") as? [String: Any], type == "map" else { return }
        let survived = (raw["places"] as? [Any])?.count == places.count
        guard survived, let to = route["to"] as? Int, to < places.count else { return }
        if let from = route["from"] as? Int, from >= places.count || from == to { return }
        card["route"] = route
    }

    /// The series that fit the labels: one, never negative, for a pie.
    private static func chartRules(_ chart: [String: Any]) -> [String: Any]? {
        let count = (chart["labels"] as? [Any])?.count ?? 0
        var series = (chart["series"] as? [[String: Any]] ?? []).filter { ($0["values"] as? [Any])?.count == count }
        if chart["kind"] as? String == "pie" {
            series = Array(series.prefix(1))
            if let values = series.first?["values"] as? [Any], values.contains(where: { (($0 as? NSNumber)?.doubleValue ?? 0) < 0 }) {
                series = []
            }
        }
        guard !series.isEmpty else { return nil }
        var chart = chart
        chart["series"] = series
        return chart
    }

    // MARK: Tool definitions

    /// The `cards` parameter of a live model's tool, in Gemini's schema
    /// dialect (upper-case types; Grok's and GPT's sessions lower-case them
    /// again). Formats are left out: Gemini knows none of them.
    /// The kinds a live model isn't offered: a diff comes from a patch
    /// Hermes read on its host, which a call's model has none of.
    static let notLiveTypes: Set<String> = ["diff"]

    func liveToolParameter(description: String) -> [String: Any] {
        var live = card
        var properties = live["properties"] as? [String: Any] ?? [:]
        for type in Self.notLiveTypes { properties[type] = nil }
        if var kind = properties["type"] as? [String: Any], let kinds = kind["enum"] as? [String] {
            kind["enum"] = kinds.filter { !Self.notLiveTypes.contains($0) }
            properties["type"] = kind
        }
        live["properties"] = properties
        return [
            "type": "ARRAY",
            "maxItems": maxCards,
            "description": description,
            "items": Self.geminiSchema(live),
        ]
    }

    private static func geminiSchema(_ schema: [String: Any]) -> [String: Any] {
        var converted: [String: Any] = [:]
        for (key, value) in schema {
            switch key {
            case "type":
                converted[key] = (value as? String)?.uppercased() ?? value
            case "format":
                continue
            case "properties":
                var properties: [String: Any] = [:]
                for (name, inner) in value as? [String: Any] ?? [:] {
                    if let inner = inner as? [String: Any] { properties[name] = geminiSchema(inner) }
                }
                converted[key] = properties
            case "items":
                if let inner = value as? [String: Any] { converted[key] = geminiSchema(inner) }
            default:
                converted[key] = value
            }
        }
        return converted
    }
}
