//
//  HermesTimestamp.swift
//  Conduit
//
//  The times Hermes writes: a cron run's, a quota window's reset. In
//  Shared/ so the Plan limits widget reads them as the app does (issue 2796).
//

import Foundation

enum HermesTimestamp {
    private static let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainISOFormatter = ISO8601DateFormatter()

    /// Built once per time zone. A stored formatter is never changed again,
    /// and NSCache is thread-safe.
    private static let localFormatters = NSCache<NSString, ISO8601DateFormatter>()

    /// The last second of year 9999: later epoch values aren't times.
    private static let latestEpochSeconds: TimeInterval = 253_402_300_799

    /// ISO 8601 with an offset (Python's isoformat, with or without
    /// microseconds), the same without an offset (read in `timeZone`), or
    /// epoch seconds or milliseconds. Anything else, or an epoch outside
    /// 1970 through 9999, is nil (#997).
    static func parse(_ raw: String, timeZone: TimeZone = .current) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = fractionalISOFormatter.date(from: trimmed) { return date }
        if let date = isoDate(trimmed, timeZone: timeZone) { return date }
        // Microseconds, which the formatters above don't all read: drop
        // the fraction and parse the rest.
        if let dot = trimmed.firstIndex(of: "."), trimmed.contains("T") {
            let fractionEnd = trimmed[trimmed.index(after: dot)...].firstIndex { !$0.isNumber } ?? trimmed.endIndex
            let whole = String(trimmed[..<dot]) + String(trimmed[fractionEnd...])
            if let date = isoDate(whole, timeZone: timeZone) { return date }
        }
        guard let number = Double(trimmed), number.isFinite else { return nil }
        let seconds = number > 10_000_000_000 ? number / 1000 : number
        guard (0...latestEpochSeconds).contains(seconds) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Whole-second ISO 8601, with an offset or (Python's naive isoformat)
    /// without one.
    private static func isoDate(_ text: String, timeZone: TimeZone) -> Date? {
        if let date = plainISOFormatter.date(from: text) { return date }
        let key = timeZone.identifier as NSString
        let local: ISO8601DateFormatter
        if let cached = localFormatters.object(forKey: key) {
            local = cached
        } else {
            local = ISO8601DateFormatter()
            local.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            local.timeZone = timeZone
            localFormatters.setObject(local, forKey: key)
        }
        return local.date(from: text)
    }
}
