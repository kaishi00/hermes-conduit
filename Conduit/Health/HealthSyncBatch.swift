//
//  HealthSyncBatch.swift
//  Conduit
//
//  What a health upload carries, independent of HealthKit so it can be
//  tested: windows of buckets (a window replaces what the host had for its
//  range), events with their own HealthKit ids, deletions, and the nightly
//  sleep summary rule. The JSON shape is health_store.py's.
//

import Foundation

enum HealthGrain: String, Codable {
    case hour
    case day
    case night
}

/// One hourly, daily or nightly value. Sums carry `sum`; discrete metrics
/// carry `min`/`avg`/`max`; a night carries `data`.
struct HealthBucket: Equatable {
    var start: Date
    var end: Date
    var sum: Double?
    var min: Double?
    var avg: Double?
    var max: Double?
    /// A night: the morning it ended (local date).
    var date: String?
    var data: [String: HealthValue] = [:]
    var source: String?
}

/// A whole range the phone recomputed for one metric and grain. The host
/// drops what it had in [from, to) and keeps these instead.
struct HealthWindow: Equatable {
    var metric: String
    var grain: HealthGrain
    var unit: String
    var from: Date
    var to: Date
    var buckets: [HealthBucket]
}

enum HealthValue: Equatable {
    case number(Double)
    case text(String)

    var json: Any {
        switch self {
        case .number(let value): return value
        case .text(let value): return value
        }
    }
}

enum HealthEventKind: String {
    case workout
    case sleep
    case sample
}

/// A workout, a sleep stage segment or a raw reading, by its HealthKit id.
struct HealthEvent: Equatable {
    var id: String
    var kind: HealthEventKind
    var metric: String
    var start: Date
    var end: Date
    var value: Double?
    var unit: String?
    var data: [String: HealthValue] = [:]
    var source: String?
}

struct HealthBatch {
    var batchID: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    var computedAt: Date
    var deviceName: String
    var timeZone: TimeZone
    var categories: [HealthCategory]
    var detailed: [HealthCategory]
    var windows: [HealthWindow] = []
    var events: [HealthEvent] = []
    var deleted: [String] = []

    var itemCount: Int { windows.reduce(0) { $0 + $1.buckets.count } + events.count + deleted.count }
    var isEmpty: Bool { windows.isEmpty && events.isEmpty && deleted.isEmpty }

    func json() -> [String: Any] {
        let format = HealthDateFormat(timeZone: timeZone)
        return [
            "batch_id": batchID,
            "computed_at": format.string(computedAt),
            "device": ["name": deviceName, "time_zone": timeZone.identifier],
            "categories": categories.map(\.rawValue).sorted(),
            "detailed": detailed.map(\.rawValue).sorted(),
            "windows": windows.map { Self.json($0, format: format) },
            "events": events.map { event -> [String: Any] in
                var entry: [String: Any] = [
                    "id": event.id, "kind": event.kind.rawValue, "metric": event.metric,
                    "start": format.string(event.start), "end": format.string(event.end),
                ]
                if let value = event.value { entry["value"] = value }
                if let unit = event.unit { entry["unit"] = unit }
                if let source = event.source { entry["source"] = String(source.prefix(120)) }
                if !event.data.isEmpty { entry["data"] = event.data.mapValues(\.json) }
                return entry
            },
            "deleted": deleted,
        ]
    }

    private static func json(_ window: HealthWindow, format: HealthDateFormat) -> [String: Any] {
        [
            "metric": window.metric,
            "grain": window.grain.rawValue,
            "unit": window.unit,
            "from": format.string(window.from),
            "to": format.string(window.to),
            "buckets": window.buckets.map { bucket -> [String: Any] in
                var entry: [String: Any] = ["start": format.string(bucket.start), "end": format.string(bucket.end)]
                if let sum = bucket.sum { entry["sum"] = sum }
                if let min = bucket.min { entry["min"] = min }
                if let avg = bucket.avg { entry["avg"] = avg }
                if let max = bucket.max { entry["max"] = max }
                if let date = bucket.date { entry["date"] = date }
                if let source = bucket.source { entry["source"] = String(source.prefix(120)) }
                if !bucket.data.isEmpty { entry["data"] = bucket.data.mapValues(\.json) }
                return entry
            },
        ]
    }

    /// Each window's place on the host (metric, grain and range) and a hash
    /// of what it carries, in `windows`' order. What the batch says around
    /// the windows (device, time zone, what's shared) is in every hash, so
    /// a change there sends every window again. `batch_id` and
    /// `computed_at` change every time and say nothing new.
    func windowPrints() -> [(key: String, hash: String)] {
        let format = HealthDateFormat(timeZone: timeZone)
        let scope: [String: Any] = [
            "device": ["name": deviceName, "time_zone": timeZone.identifier],
            "categories": categories.map(\.rawValue).sorted(),
            "detailed": detailed.map(\.rawValue).sorted(),
        ]
        return windows.map { window in
            let entry = Self.json(window, format: format)
            let key = "\(window.metric)|\(window.grain.rawValue)|\(format.string(window.from))|\(format.string(window.to))"
            return (key, ContextFingerprint.of(["scope": scope, "window": entry]))
        }
    }

    /// Splits into batches the host and the dashboard page take, keeping
    /// each window whole (a window replaces its range on the host). A window
    /// bigger than the limit goes alone.
    func split(limit: Int = HealthSyncLimits.maxItemsPerBatch) -> [HealthBatch] {
        var batches: [HealthBatch] = []
        var current = emptyCopy()
        func flush() {
            if !current.isEmpty { batches.append(current) }
            current = emptyCopy()
        }
        for window in windows {
            if current.itemCount + window.buckets.count > limit { flush() }
            current.windows.append(window)
        }
        for event in events {
            if current.itemCount + 1 > limit { flush() }
            current.events.append(event)
        }
        for id in deleted {
            if current.itemCount + 1 > limit { flush() }
            current.deleted.append(id)
        }
        flush()
        return batches
    }

    private func emptyCopy() -> HealthBatch {
        HealthBatch(computedAt: computedAt, deviceName: deviceName, timeZone: timeZone,
                    categories: categories, detailed: detailed)
    }
}

/// ISO 8601 with the local offset, so "the 13th" stays the user's 13th on
/// the host.
struct HealthDateFormat {
    private let formatter: ISO8601DateFormatter
    private let dayFormatter: DateFormatter

    init(timeZone: TimeZone) {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"
    }

    func string(_ date: Date) -> String { formatter.string(from: date) }
    func day(_ date: Date) -> String { dayFormatter.string(from: date) }
}

// MARK: - Sleep

enum HealthSleepStage: String {
    case inBed = "in_bed"
    case asleep
    case core
    case deep
    case rem
    case awake

    var isAsleep: Bool { self == .asleep || self == .core || self == .deep || self == .rem }
}

/// One sleep sample as HealthKit gave it.
struct HealthSleepSegment: Equatable {
    var id: String
    var stage: HealthSleepStage
    var start: Date
    var end: Date
    /// The app or device that recorded it ("Apple Watch").
    var source: String
    /// Recorded by an Apple Watch (its product type starts with "Watch").
    var fromWatch: Bool
}

/// The nightly summary rule: a night runs noon to
/// noon and is named by the morning it ends. Apps overlap, so one source
/// is chosen per night: an Apple Watch first, otherwise the source with the
/// most time asleep (in bed when nothing says asleep). Fixed and
/// deterministic.
enum HealthSleepNights {
    static func nightEnding(_ date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let noon = calendar.date(byAdding: .hour, value: 12, to: day) ?? day
        return date < noon ? day : (calendar.date(byAdding: .day, value: 1, to: day) ?? day)
    }

    /// The window for the nights whose mornings fall in [firstMorning,
    /// endMorning): noon before the first morning to noon before the end.
    static func window(mornings firstMorning: Date, until endMorning: Date, calendar: Calendar) -> (from: Date, to: Date) {
        let from = calendar.date(byAdding: .hour, value: -12, to: calendar.startOfDay(for: firstMorning)) ?? firstMorning
        let to = calendar.date(byAdding: .hour, value: -12, to: calendar.startOfDay(for: endMorning)) ?? endMorning
        return (from, to)
    }

    static func summaries(_ segments: [HealthSleepSegment], calendar: Calendar) -> [HealthBucket] {
        let format = HealthDateFormat(timeZone: calendar.timeZone)
        let byNight = Dictionary(grouping: segments) { nightEnding($0.start, calendar: calendar) }
        return byNight.keys.sorted().compactMap { morning in
            guard let chosen = chosenSource(byNight[morning] ?? []) else { return nil }
            let night = chosen.segments.sorted { $0.start < $1.start }
            guard let first = night.first, let last = night.max(by: { $0.end < $1.end }) else { return nil }
            func minutes(_ stages: Set<HealthSleepStage>) -> Double {
                (night.filter { stages.contains($0.stage) }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } / 60).rounded()
            }
            let asleep = minutes([.asleep, .core, .deep, .rem])
            let explicitInBed = minutes([.inBed])
            var data: [String: HealthValue] = [
                "asleep": .number(asleep),
                "in_bed": .number(explicitInBed > 0 ? explicitInBed : (last.end.timeIntervalSince(first.start) / 60).rounded()),
                "awake": .number(minutes([.awake])),
                "wake_count": .number(Double(night.filter { $0.stage == .awake }.count)),
                "bedtime": .text(format.string(first.start)),
                "wake_time": .text(format.string(last.end)),
            ]
            if night.contains(where: { [.core, .deep, .rem].contains($0.stage) }) {
                data["core"] = .number(minutes([.core]))
                data["deep"] = .number(minutes([.deep]))
                data["rem"] = .number(minutes([.rem]))
            }
            let unspecified = minutes([.asleep])
            if unspecified > 0 { data["unspecified"] = .number(unspecified) }
            return HealthBucket(start: first.start, end: last.end, date: format.day(morning), data: data,
                                source: chosen.source)
        }
    }

    private static func chosenSource(_ segments: [HealthSleepSegment]) -> (source: String, segments: [HealthSleepSegment])? {
        let bySource = Dictionary(grouping: segments, by: \.source)
        func score(_ group: [HealthSleepSegment]) -> (Int, Double, Double) {
            let asleep = group.filter { $0.stage.isAsleep }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            let total = group.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            return (group.contains(where: \.fromWatch) ? 1 : 0, asleep, total)
        }
        // Ties fall back to the name, so the same data always picks the same source.
        return bySource.max { lhs, rhs in
            let left = score(lhs.value), right = score(rhs.value)
            return left != right ? left < right : lhs.key > rhs.key
        }.map { ($0.key, $0.value) }
    }
}
