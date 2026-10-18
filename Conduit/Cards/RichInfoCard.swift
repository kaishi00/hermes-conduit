//
//  RichInfoCard.swift
//  Conduit
//
//  The information cards as the views read them: stats, a chart, a
//  forecast, a comparison and steps, built from cards RichCardSchema has
//  normalized. Unlike a place, nothing here is looked up on the phone: the
//  numbers are Hermes', and the card says where they're from when Hermes
//  names a source (a forecast always does), and reads as Hermes' own
//  otherwise.
//

import Foundation

/// Where an information card's numbers are from.
struct RichCardSource: Equatable, Hashable {
    let name: String
    let url: URL?

    init?(json: Any?) {
        guard let json = json as? [String: Any], let name = json["name"] as? String, !name.isEmpty else { return nil }
        self.name = name
        url = RichJSON.webURL(json["url"])
    }
}

struct RichStat: Equatable, Hashable {
    enum Trend: String {
        case up, down, flat
    }

    enum Tone: String {
        case good, bad, neutral
    }

    let label: String
    let value: String
    let detail: String?
    let change: String?
    let trend: Trend?
    let tone: Tone
    /// Recent values, oldest first.
    let spark: [Double]

    init?(json: [String: Any]) {
        guard let label = json["label"] as? String, let value = json["value"] as? String else { return nil }
        self.label = label
        self.value = value
        detail = json["detail"] as? String
        change = json["change"] as? String
        trend = (json["trend"] as? String).flatMap(Trend.init(rawValue:))
        tone = (json["tone"] as? String).flatMap(Tone.init(rawValue:)) ?? .neutral
        let spark = RichJSON.numbers(json["spark"])
        self.spark = spark.count >= 2 ? spark : []
    }
}

struct RichChart: Equatable, Hashable {
    enum Kind: String {
        case line, bar, area, pie
    }

    struct Series: Equatable, Hashable {
        let name: String?
        /// One per label.
        let values: [Double]
    }

    let kind: Kind
    let labels: [String]
    let series: [Series]
    let unit: String?

    init?(json: Any?) {
        guard let json = json as? [String: Any], let kind = (json["kind"] as? String).flatMap(Kind.init(rawValue:)),
              let labels = json["labels"] as? [String], !labels.isEmpty else { return nil }
        let series = (json["series"] as? [[String: Any]] ?? []).compactMap { line -> Series? in
            let values = RichJSON.numbers(line["values"])
            guard values.count == labels.count else { return nil }
            return Series(name: line["name"] as? String, values: values)
        }
        guard !series.isEmpty else { return nil }
        self.kind = kind
        self.labels = labels
        self.series = kind == .pie ? Array(series.prefix(1)) : series
        unit = json["unit"] as? String
    }
}

struct RichWeather: Equatable, Hashable {
    enum Condition: String {
        case clear
        case partlyCloudy = "partly_cloudy"
        case cloudy, fog, drizzle, rain
        case heavyRain = "heavy_rain"
        case thunderstorm, snow, sleet, wind
    }

    struct Now: Equatable, Hashable {
        let temp: Double
        let condition: Condition
        let text: String?
    }

    struct Hour: Equatable, Hashable {
        let time: String
        let temp: Double
        let condition: Condition?
        /// Chance of rain or snow, in percent.
        let precip: Int?
    }

    struct Day: Equatable, Hashable {
        let day: String
        let low: Double
        let high: Double
        let condition: Condition?
        let precip: Int?
    }

    let place: String?
    /// C or F.
    let unit: String
    let now: Now?
    let hours: [Hour]
    let days: [Day]

    init?(json: Any?) {
        guard let json = json as? [String: Any], let unit = json["unit"] as? String else { return nil }
        self.unit = unit
        place = json["place"] as? String
        if let now = json["now"] as? [String: Any], let temp = RichJSON.number(now["temp"]),
           let condition = (now["condition"] as? String).flatMap(Condition.init(rawValue:)) {
            self.now = Now(temp: temp, condition: condition, text: now["text"] as? String)
        } else {
            now = nil
        }
        hours = (json["hours"] as? [[String: Any]] ?? []).compactMap { hour in
            guard let time = hour["time"] as? String, let temp = RichJSON.number(hour["temp"]) else { return nil }
            return Hour(time: time, temp: temp, condition: (hour["condition"] as? String).flatMap(Condition.init(rawValue:)),
                        precip: RichJSON.percent(hour["precip"]))
        }
        days = (json["days"] as? [[String: Any]] ?? []).compactMap { day in
            guard let name = day["day"] as? String, let low = RichJSON.number(day["low"]),
                  let high = RichJSON.number(day["high"]), low <= high else { return nil }
            return Day(day: name, low: low, high: high, condition: (day["condition"] as? String).flatMap(Condition.init(rawValue:)),
                       precip: RichJSON.percent(day["precip"]))
        }
        guard now != nil || !hours.isEmpty || !days.isEmpty else { return nil }
    }
}

struct RichOption: Equatable, Hashable {
    struct Fact: Equatable, Hashable {
        let label: String
        let value: String
    }

    let name: String
    let summary: String?
    let facts: [Fact]
    let pros: [String]
    let cons: [String]
    let recommended: Bool

    init?(json: [String: Any]) {
        guard let name = json["name"] as? String else { return nil }
        self.name = name
        summary = json["summary"] as? String
        facts = (json["facts"] as? [[String: Any]] ?? []).compactMap { fact in
            guard let label = fact["label"] as? String, let value = fact["value"] as? String else { return nil }
            return Fact(label: label, value: value)
        }
        pros = json["pros"] as? [String] ?? []
        cons = json["cons"] as? [String] ?? []
        recommended = json["recommended"] as? Bool ?? false
    }
}

struct RichStep: Equatable, Hashable {
    let text: String
    /// Seconds, when the step waits a set time.
    let timer: Int?

    init?(json: [String: Any]) {
        guard let text = json["text"] as? String else { return nil }
        self.text = text
        // The schema's bounds: a second to a day.
        timer = RichJSON.number(json["timer"]).map { Int($0.rounded()) }.flatMap { (1...86_400).contains($0) ? $0 : nil }
    }
}

/// Reading normalized card JSON.
enum RichJSON {
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    /// A whole percent from 0 to 100.
    static func percent(_ value: Any?) -> Int? {
        number(value).map { Int(min(max($0, 0), 100).rounded()) }
    }

    static func numbers(_ value: Any?) -> [Double] {
        (value as? [Any] ?? []).compactMap(number)
    }

    static func webURL(_ value: Any?) -> URL? {
        guard let text = value as? String, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }
}
