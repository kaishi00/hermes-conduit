//
//  ProfileTimeZone.swift
//  Conduit
//
//  The profile's `timezone` setting. Hermes reads it with Python's
//  zoneinfo, which wants an exact IANA name ("America/Toronto"), and falls
//  back to the server's local time for a blank or unknown one. Nobody types
//  those names from memory, so Settings offers this iPhone's zone and checks
//  what was typed against the names iOS knows before saving it.
//

import Foundation

enum ProfileTimeZone {
    /// The config key Hermes reads.
    static let configKey = "timezone"

    /// What a typed value saves as.
    enum Resolution: Equatable {
        /// Blank: Hermes uses the server's local time.
        case serverLocal
        /// A known IANA name, spelled the way zoneinfo wants it.
        case identifier(String)
        /// Not a time zone Conduit can vouch for.
        case invalid

        /// The config value to save, or nil when there is nothing valid to save.
        var storedValue: String? {
            switch self {
            case .serverLocal: return ""
            case .identifier(let id): return id
            case .invalid: return nil
            }
        }
    }

    /// The names a value is checked against: what iOS knows, plus "UTC",
    /// which zoneinfo accepts and iOS lists only as "GMT".
    static let knownIdentifiers: [String] = {
        var ids = TimeZone.knownTimeZoneIdentifiers
        if !ids.contains("UTC") { ids.append("UTC") }
        return ids
    }()

    private static let identifiersByLowercase: [String: String] = Dictionary(
        knownIdentifiers.map { ($0.lowercased(), $0) },
        uniquingKeysWith: { first, _ in first }
    )

    /// Resolves a typed value: blank is the server's local time, a known
    /// name in any letter case becomes its canonical spelling, and spaces
    /// stand in for underscores ("america/new york").
    static func resolve(_ raw: String, known: [String: String] = identifiersByLowercase) -> Resolution {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .serverLocal }
        let key = trimmed.lowercased()
        if let id = known[key] { return .identifier(id) }
        if let id = known[key.replacingOccurrences(of: " ", with: "_")] { return .identifier(id) }
        return .invalid
    }

    /// Whether a saved value already names this zone.
    static func matches(_ saved: String, _ identifier: String) -> Bool {
        saved.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(identifier) == .orderedSame
    }

    /// The zone a profile's schedules run in, when it differs from this
    /// iPhone's and is worth naming next to a time: nil for a blank or
    /// unknown setting (the server's own zone, which Conduit can't see) and
    /// for the iPhone's own zone, whose times need no label.
    static func scheduleZoneLabel(profileSetting: String?, device: TimeZone = .current) -> String? {
        guard let profileSetting, case .identifier(let id) = resolve(profileSetting),
              let zone = TimeZone(identifier: id) else { return nil }
        if zone.identifier == device.identifier { return nil }
        // Another name for the same rules (an alias) reads the same here.
        let now = Date()
        if zone.secondsFromGMT(for: now) == device.secondsFromGMT(for: now),
           zone.nextDaylightSavingTimeTransition(after: now) == device.nextDaylightSavingTimeTransition(after: now) {
            return nil
        }
        return id
    }
}
