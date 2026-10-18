//
//  RichCardSchema.swift
//  Conduit
//
//  Rich cards (maps and places) are defined once, in hermes-conduit-
//  notifier's cards/card-schema.json. This app ships a byte-identical copy
//  (card-schema.json beside this file); scripts/check-card-schema.py fails
//  CI when it differs from the plugin's main. Nothing here names a card's
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
//  - then the schema's rules: a route only on a map whose places all
//    survived, naming places in the list, from one to another; a place
//    card keeps its first place.
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
        for raw in list {
            if cards.count == maxCards { break }
            if let card = normalizeCard(raw) { cards.append(card) }
        }
        return cards
    }

    /// One card, or nil when it isn't valid.
    func normalizeCard(_ raw: Any) -> [String: Any]? {
        guard case .valid(let value) = Self.normalize(card, raw), var normalized = value as? [String: Any] else {
            return nil
        }
        Self.applyRules(&normalized, raw: raw as? [String: Any] ?? [:])
        return normalized
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

    private static func applyRules(_ card: inout [String: Any], raw: [String: Any]) {
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
