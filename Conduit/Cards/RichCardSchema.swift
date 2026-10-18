//
//  RichCardSchema.swift
//  Conduit
//
//  Rich cards (maps, places, stats, charts, forecasts, comparisons, steps,
//  media, contacts and statuses) are defined once, in hermes-conduit-notifier's
//  cards/card-schema.json. This app ships a byte-identical copy
//  (card-schema.json beside this file); scripts/check-card-schema.py fails
//  CI when it differs from the plugin's main. Only the rules name a card's
//  fields: the live models' show_on_screen parameter is built from the
//  copy, and normalizing walks it, the same way the plugin's card_schema.py
//  does. Both run the plugin's cards/card-vectors.json (RichCardSchemaTests):
//
//  - unknown keys are dropped;
//  - text has control characters turned into spaces, is trimmed, and is cut
//    to maxLength code points (a URL that's too long, or holds a space,
//    quote, bracket or parenthesis, is invalid instead);
//  - an invalid optional value is dropped, an invalid list item is dropped
//    (then the list is cut to maxItems), and an invalid required value
//    makes its object invalid;
//  - enums match without regard to case and come out as the schema writes
//    them;
//  - then the schema's rules: a card keeps only its type's fields and needs
//    its type's own; a route only on a map whose places all survived,
//    naming places in the list, from one to another; a place card keeps
//    its first place; a chart keeps the series that fit its labels (one,
//    never negative, for a pie); a forecast needs a source and something
//    to show, and drops a day whose low is above its high; a comparison
//    recommends one option at most; media needs a source and https links,
//    and an image has no duration or artwork; a contact keeps only a phone and an email
//    that look like one; a live name is kept on the first card of a set
//    that has it.
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
        guard case .valid(let value) = Self.normalize(card, raw), let normalized = value as? [String: Any] else {
            return nil
        }
        return Self.applyRules(normalized, raw: raw as? [String: Any] ?? [:])
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
            let text = cleanText(raw)
            guard !text.isEmpty else { return .invalid }
            let limit = schema["maxLength"] as? Int
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

    /// Control characters become spaces; trimmed.
    static func cleanText(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            scalars.append(scalar.properties.generalCategory == .control ? " " : scalar)
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
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
        "media": ["media"], "contact": ["people"], "status": ["status"],
    ]

    /// The cards about places; every other type can name a source.
    static let placeTypes: Set<String> = ["map", "place", "places"]

    /// A phone number's characters, and an address with nothing that could
    /// end a link or a header early (the plugin's _PHONE and _EMAIL).
    private static let phonePattern = try! NSRegularExpression(pattern: #"^[0-9+\-(). ]+$"#)
    private static let emailPattern = try! NSRegularExpression(
        pattern: #"^[^@\s<>()\[\]"'`,;:\\]+@[^@\s<>()\[\]"'`,;:\\]+\.[^@\s<>()\[\]"'`,;:\\.]+$"#)

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
                return person
            }
        default:
            break
        }
        return card
    }

    private static func placeRules(_ card: inout [String: Any], raw: [String: Any]) {
        let type = card["type"] as? String
        var places = card["places"] as? [Any] ?? []
        if type == "place" {
            places = Array(places.prefix(1))
            card["places"] = places
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
    func liveToolParameter(description: String) -> [String: Any] {
        [
            "type": "ARRAY",
            "maxItems": maxCards,
            "description": description,
            "items": Self.geminiSchema(card),
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
