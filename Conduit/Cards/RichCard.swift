//
//  RichCard.swift
//  Conduit
//
//  A rich card as the views read it, built from a card RichCardSchema has
//  normalized (the information cards' own parts are in RichInfoCard.swift).
//  Hermes supplies the facts here: a place's name and where it
//  is, its own note, and ratings, hours, prices and photos it found, each
//  with its source. What Apple Maps knows (address, category, phone,
//  website, travel time) is looked up on the phone when the card is drawn
//  (RichPlaceLookup), never taken from the model.
//
//  Cards come from Hermes' `conduit_show` (its answer keeps the normalized
//  cards, so the chat's history redraws them) and from a live model's
//  `show_on_screen`.
//

import CoreLocation
import Foundation

struct RichCard: Identifiable, Equatable, Hashable {
    enum Kind: String {
        case map
        case place
        case places
        case stats
        case chart
        case weather
        case comparison
        case steps
    }

    enum TravelMode: String {
        case driving, walking, transit, cycling
    }

    struct Route: Equatable, Hashable {
        /// Nil starts where the user is.
        let from: Int?
        let to: Int
        let mode: TravelMode
    }

    /// Its place among the cards it came with, so a list of cards keeps
    /// stable ids.
    let id: Int
    let kind: Kind
    let title: String?
    /// map, place and places.
    let places: [RichPlace]
    let route: Route?
    /// The information cards: where they're from, when Hermes said.
    let source: RichCardSource?
    let stats: [RichStat]
    let chart: RichChart?
    let weather: RichWeather?
    let options: [RichOption]
    let needs: [String]
    let steps: [RichStep]

    init?(normalized json: [String: Any], id: Int) {
        guard let kind = (json["type"] as? String).flatMap(Kind.init(rawValue:)) else { return nil }
        // Numbered after any unusable place is left out, so an index is a
        // place's position in `places` (normalized cards never leave one out).
        let usable = (json["places"] as? [[String: Any]] ?? []).filter { RichPlace(json: $0, index: 0) != nil }
        let places = usable.enumerated().compactMap { RichPlace(json: $1, index: $0) }
        self.id = id
        self.kind = kind
        self.title = json["title"] as? String
        self.places = places
        if let route = json["route"] as? [String: Any], let to = route["to"] as? Int, places.indices.contains(to) {
            let from = (route["from"] as? Int).flatMap { places.indices.contains($0) ? $0 : nil }
            self.route = Route(from: from, to: to,
                               mode: (route["mode"] as? String).flatMap(TravelMode.init(rawValue:)) ?? .driving)
        } else {
            self.route = nil
        }
        source = RichCardSource(json: json["source"])
        stats = (json["stats"] as? [[String: Any]] ?? []).compactMap(RichStat.init(json:))
        chart = RichChart(json: json["chart"])
        weather = RichWeather(json: json["weather"])
        options = (json["options"] as? [[String: Any]] ?? []).compactMap(RichOption.init(json:))
        needs = json["needs"] as? [String] ?? []
        steps = (json["steps"] as? [[String: Any]] ?? []).compactMap(RichStep.init(json:))
        switch kind {
        case .map, .place, .places: guard !places.isEmpty else { return nil }
        case .stats: guard !stats.isEmpty else { return nil }
        case .chart: guard chart != nil else { return nil }
        case .weather: guard weather != nil, source != nil else { return nil }
        case .comparison: guard options.count >= 2 else { return nil }
        case .steps: guard !steps.isEmpty else { return nil }
        }
    }

    /// The cards in a normalized list.
    static func cards(_ normalized: [[String: Any]]) -> [RichCard] {
        normalized.enumerated().compactMap { RichCard(normalized: $1, id: $0) }
    }

    /// Cards in raw JSON (a tool's arguments or answer), checked against
    /// the schema first.
    static func cards(raw value: Any?, schema: RichCardSchema? = .bundled) -> [RichCard] {
        guard let schema else { return [] }
        return cards(schema.normalizeCards(value))
    }

    // MARK: From a chat's conduit_show

    static let toolName = "conduit_show"

    /// The cards a finished `conduit_show` call showed: its answer's
    /// `cards` (normalized by the plugin, checked again here), or, for an
    /// answer that doesn't carry them, its arguments' when it succeeded.
    static func cards(for tool: ToolActivity, schema: RichCardSchema? = .bundled) -> [RichCard] {
        guard tool.name.lowercased() == toolName, tool.status == .complete else { return [] }
        let answer = jsonObject(tool.output)
        if let given = answer?["cards"] {
            return cards(raw: given, schema: schema)
        }
        guard (answer?["ok"] as? Bool) == true else { return [] }
        return cards(raw: jsonObject(tool.input)?["cards"], schema: schema)
    }

    /// Whether a transcript row is a `conduit_show` call that drew cards.
    static func hasCards(_ message: ChatMessage) -> Bool {
        guard message.role == .tool, let tool = message.tool else { return false }
        return !cards(for: tool).isEmpty
    }

    private static func jsonObject(_ text: String?) -> [String: Any]? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// A fact Hermes found, with where it's from.
struct RichSourcedFact: Equatable, Hashable {
    let text: String
    let source: String
    let url: URL?
}

struct RichPlace: Equatable, Hashable {
    struct Rating: Equatable, Hashable {
        let value: Double
        let count: Int?
        let source: String
        let url: URL?
    }

    struct Photo: Equatable, Hashable {
        let url: URL
        let source: String
        let pageURL: URL?
    }

    /// Counted from 0 in its card, as a route names it.
    let index: Int
    let name: String
    /// The address Hermes gave, used to find the place; the card shows
    /// Apple Maps' own.
    let address: String?
    let latitude: Double?
    let longitude: Double?
    let placeID: String?
    /// Hermes' own words about it.
    let note: String?
    let rating: Rating?
    let hours: RichSourcedFact?
    let price: RichSourcedFact?
    let photo: Photo?

    init?(json: [String: Any], index: Int) {
        guard let name = json["name"] as? String, !name.isEmpty else { return nil }
        self.index = index
        self.name = name
        address = json["address"] as? String
        latitude = (json["lat"] as? NSNumber)?.doubleValue
        longitude = (json["lon"] as? NSNumber)?.doubleValue
        placeID = json["place_id"] as? String
        note = json["note"] as? String
        if let rating = json["rating"] as? [String: Any], let value = (rating["value"] as? NSNumber)?.doubleValue,
           let source = rating["source"] as? String {
            self.rating = Rating(value: value, count: (rating["count"] as? NSNumber)?.intValue, source: source, url: Self.webURL(rating["url"]))
        } else {
            rating = nil
        }
        hours = Self.fact(json["hours"])
        price = Self.fact(json["price"])
        if let photo = json["photo"] as? [String: Any], let url = Self.webURL(photo["url"]), url.scheme?.lowercased() == "https",
           let source = photo["source"] as? String {
            self.photo = Photo(url: url, source: source, pageURL: Self.webURL(photo["page_url"]))
        } else {
            photo = nil
        }
    }

    /// Where Hermes said it is, when it gave both coordinates.
    var givenCoordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// What a lookup of this place is cached under.
    var lookupKey: String {
        [name, address ?? "", latitude.map { String($0) } ?? "", longitude.map { String($0) } ?? "", placeID ?? ""]
            .joined(separator: "\u{1F}")
    }

    private static func fact(_ value: Any?) -> RichSourcedFact? {
        guard let fact = value as? [String: Any], let text = fact["text"] as? String,
              let source = fact["source"] as? String else { return nil }
        return RichSourcedFact(text: text, source: source, url: webURL(fact["url"]))
    }

    private static func webURL(_ value: Any?) -> URL? {
        RichJSON.webURL(value)
    }
}
