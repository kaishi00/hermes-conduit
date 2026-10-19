//
//  LocationModels.swift
//  Conduit
//
//  Location for Hermes (designs/location-awareness.md, wire contract
//  designs/location-v1-contract.md). Two opt-in layers: "while I'm talking
//  to Hermes" (a fix when a message is sent or a voice call runs) and "in
//  the background" (saved places, visits, significant moves, and answers to
//  the agent's on-demand locate). Each has its own precision. Everything
//  goes straight from this iPhone to one Hermes profile on one dashboard,
//  sealed end to end, never through the push relay.
//
//  Shared with the Location Push extension, which answers a locate with
//  the same rules. No UI strings here: the extension has no catalog.
//

import CoreLocation
import Foundation

/// How much a fix tells the host.
enum LocationPrecision: String, Codable, CaseIterable, Identifiable {
    /// Saved place or "not at a saved place": no coordinates, no area.
    case places
    /// Neighbourhood, city and country, and a coordinate to about 1 km.
    case area
    /// The coordinate as measured, with its accuracy.
    case precise

    var id: String { rawValue }

    /// The coarser of the two.
    func capped(at other: LocationPrecision) -> LocationPrecision {
        rank <= other.rank ? self : other
    }

    private var rank: Int {
        switch self {
        case .places: return 0
        case .area: return 1
        case .precise: return 2
        }
    }
}

enum LocationPlaceKind: String, Codable, CaseIterable, Identifiable {
    case home, work, gym, school, other

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .work: return "briefcase"
        case .gym: return "dumbbell"
        case .school: return "graduationcap"
        case .other: return "mappin"
        }
    }
}

/// A place the user saved. Its center and radius never leave the phone:
/// the host gets the id, name and kind, and distances per fix.
struct LocationSavedPlace: Codable, Equatable, Identifiable {
    static let minRadius: Double = 100
    static let maxRadius: Double = 500
    static let defaultRadius: Double = 150
    /// iOS monitors up to 20 conditions per app.
    static let maxCount = 20
    static let maxNameLength = 40

    var id: String
    var name: String
    var kind: LocationPlaceKind
    /// Inside a private place the host hears only "at a private place".
    var isPrivate: Bool
    var latitude: Double
    var longitude: Double
    var radius: Double

    init(id: String = LocationSavedPlace.newID(), name: String, kind: LocationPlaceKind, isPrivate: Bool = false,
         latitude: Double, longitude: Double, radius: Double = LocationSavedPlace.defaultRadius) {
        self.id = id
        self.name = String(name.prefix(Self.maxNameLength))
        self.kind = kind
        self.isPrivate = isPrivate
        self.latitude = latitude
        self.longitude = longitude
        self.radius = min(Self.maxRadius, max(Self.minRadius, radius))
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var center: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }

    func distance(to location: CLLocation) -> CLLocationDistance { location.distance(from: center) }

    /// `p_` and 12 hex digits: inside the host's `^[A-Za-z0-9_-]{1,40}$`.
    static func newID() -> String {
        "p_" + LocationIDs.hex(bytes: 6)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, isPrivate, latitude, longitude, radius
    }

    /// Tolerates keys an older or newer Conduit didn't write. Only the
    /// coordinate is required: a place without one can't be monitored.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: (try? container.decodeIfPresent(String.self, forKey: .id)) ?? Self.newID(),
            name: (try? container.decodeIfPresent(String.self, forKey: .name)) ?? "",
            kind: (try? container.decodeIfPresent(LocationPlaceKind.self, forKey: .kind)) ?? .other,
            isPrivate: (try? container.decodeIfPresent(Bool.self, forKey: .isPrivate)) ?? false,
            latitude: try container.decode(Double.self, forKey: .latitude),
            longitude: try container.decode(Double.self, forKey: .longitude),
            radius: (try? container.decodeIfPresent(Double.self, forKey: .radius)) ?? Self.defaultRadius
        )
    }
}

/// What the user chose to share. Sent with every batch (`sharing`), so the
/// host always knows what's on, paused or off.
struct LocationSharingSettings: Codable, Equatable {
    static let retentionChoices = [0, 1, 7, 30, 365]
    static let defaultRetention = 7

    var talking = false
    var talkingPrecision: LocationPrecision = .precise
    var background = false
    var backgroundPrecision: LocationPrecision = .area
    var retentionDays = LocationSharingSettings.defaultRetention
    /// Nothing is sent while this is in the future; `.distantFuture` is
    /// "until I turn it back on".
    var pausedUntil: Date?
    /// Whether the host may answer maps lookups itself (its own Apple Maps
    /// access) when this iPhone can't. Off is "Keep maps lookups on this
    /// iPhone" (`sharing.maps_host: false`, designs/maps-v1-contract.md
    /// section 1).
    var mapsHost = true

    var isOn: Bool { talking || background }

    func isPaused(at now: Date) -> Bool {
        guard let pausedUntil else { return false }
        return pausedUntil > now
    }

    /// Whether a fix from `source` may be taken and sent now.
    func shares(_ source: LocationFixSource, at now: Date) -> Bool {
        guard !isPaused(at: now) else { return false }
        return source.isTalking ? talking : background
    }

    func precision(for source: LocationFixSource) -> LocationPrecision {
        source.isTalking ? talkingPrecision : backgroundPrecision
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case talking, talkingPrecision, background, backgroundPrecision, retentionDays, pausedUntil, mapsHost
    }

    /// Missing or unknown values fall back to the defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LocationSharingSettings()
        talking = (try? container.decodeIfPresent(Bool.self, forKey: .talking)) ?? defaults.talking
        talkingPrecision = (try? container.decodeIfPresent(LocationPrecision.self, forKey: .talkingPrecision)) ?? defaults.talkingPrecision
        background = (try? container.decodeIfPresent(Bool.self, forKey: .background)) ?? defaults.background
        backgroundPrecision = (try? container.decodeIfPresent(LocationPrecision.self, forKey: .backgroundPrecision)) ?? defaults.backgroundPrecision
        retentionDays = (try? container.decodeIfPresent(Int.self, forKey: .retentionDays)) ?? defaults.retentionDays
        pausedUntil = try? container.decodeIfPresent(Date.self, forKey: .pausedUntil)
        mapsHost = (try? container.decodeIfPresent(Bool.self, forKey: .mapsHost)) ?? defaults.mapsHost
    }

    /// The `sharing` object of a batch.
    func json(at now: Date, timeZone: TimeZone, formatter: ISO8601DateFormatter) -> [String: Any] {
        var paused: Any = NSNull()
        if isPaused(at: now), let pausedUntil { paused = formatter.string(from: pausedUntil) }
        return [
            "talking": talking,
            "talking_precision": talkingPrecision.rawValue,
            "background": background,
            "background_precision": backgroundPrecision.rawValue,
            "retention_days": Self.retentionChoices.contains(retentionDays) ? retentionDays : Self.defaultRetention,
            "paused_until": paused,
            "time_zone": timeZone.identifier,
            "maps_host": mapsHost,
        ]
    }
}

/// Why a fix was taken (`fix.source`).
enum LocationFixSource: String, Codable {
    /// Layer 1: a message sent from Conduit, a voice call.
    case message, call
    /// Layer 2: a visit, a saved place's arrive/leave, a significant move,
    /// Conduit opened.
    case visit, place, significant, app
    /// The agent's on-demand request, answered by the extension.
    case locate

    var isTalking: Bool { self == .message || self == .call }
}

/// Where location goes: one profile on one saved dashboard, fixed when the
/// user first turns a layer on.
struct LocationBinding: Codable, Equatable {
    var dashboardID: UUID
    var profile: String
    /// The dashboard's address, for display.
    var host: String

    init(dashboardID: UUID, profile: String, host: String) {
        self.dashboardID = dashboardID
        self.profile = profile
        self.host = host
    }

    private enum CodingKeys: String, CodingKey {
        case dashboardID, profile, host
    }

    /// Only the dashboard is required; the profile falls back to the
    /// default one and the host label to nothing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dashboardID = try container.decode(UUID.self, forKey: .dashboardID)
        profile = (try? container.decodeIfPresent(String.self, forKey: .profile)) ?? "default"
        host = (try? container.decodeIfPresent(String.self, forKey: .host)) ?? ""
    }
}

/// Everything the app and the Location Push extension both read: in the App
/// Group container, readable after first unlock, never backed up. The saved
/// places' coordinates are here and only here.
struct LocationSharedConfig: Codable, Equatable {
    var binding: LocationBinding?
    var settings = LocationSharingSettings()
    var places: [LocationSavedPlace] = []
    /// This phone's id on the host (`^[A-Za-z0-9_-]{8,64}$`), kept across
    /// turning sharing off so the host's copy can still be deleted.
    var deviceID: String = LocationIDs.hex(bytes: 16)
    /// Whether iOS gave only approximate location.
    var approximateOnly = false
    /// A change of the sharing choices or places the host hasn't had yet
    /// (made offline, or the send failed): sent when the host is next
    /// reachable, even with sharing off, since "off" and "paused" matter
    /// most.
    var settingsPending = false
    /// Live voice modes the user lets read the shared location on a call
    /// (`LiveVoiceModeName.storageID`); nil is none. Kept on this iPhone:
    /// the phone makes every voice read, so the host never needs it.
    var voiceReaders: [String]?

    init(binding: LocationBinding? = nil, settings: LocationSharingSettings = LocationSharingSettings(),
         places: [LocationSavedPlace] = [], deviceID: String = LocationIDs.hex(bytes: 16), approximateOnly: Bool = false,
         settingsPending: Bool = false) {
        self.binding = binding
        self.settings = settings
        self.places = places
        self.deviceID = deviceID
        self.approximateOnly = approximateOnly
        self.settingsPending = settingsPending
    }

    private enum CodingKeys: String, CodingKey {
        case binding, settings, places, deviceID, approximateOnly, settingsPending, voiceReaders
    }

    /// Tolerates missing keys, and a saved place that can't be read is
    /// skipped instead of losing the whole configuration.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        binding = try? container.decodeIfPresent(LocationBinding.self, forKey: .binding)
        settings = (try? container.decodeIfPresent(LocationSharingSettings.self, forKey: .settings)) ?? LocationSharingSettings()
        if binding == nil, container.contains(.binding), (try? container.decodeNil(forKey: .binding)) != true {
            // A binding that can't be read sends nothing, so the layers show
            // off rather than on; turning one on binds again.
            settings.talking = false
            settings.background = false
        }
        places = (try? container.decodeIfPresent([LossyPlace].self, forKey: .places))?.compactMap(\.place) ?? []
        deviceID = (try? container.decodeIfPresent(String.self, forKey: .deviceID)) ?? LocationIDs.hex(bytes: 16)
        approximateOnly = (try? container.decodeIfPresent(Bool.self, forKey: .approximateOnly)) ?? false
        settingsPending = (try? container.decodeIfPresent(Bool.self, forKey: .settingsPending)) ?? false
        voiceReaders = try? container.decodeIfPresent([String].self, forKey: .voiceReaders)
    }

    /// Whether a live call on the mode with this storage id may read the
    /// shared location: only while a layer is on and sharing isn't paused.
    func letsVoiceRead(_ storageID: String, at now: Date) -> Bool {
        readsByVoice(at: now) && (voiceReaders ?? []).contains(storageID)
    }

    /// Whether any live voice mode may read the shared location now (the
    /// key then needs its voice keys).
    func readsByVoice(at now: Date) -> Bool {
        binding != nil && settings.isOn && !settings.isPaused(at: now) && !(voiceReaders ?? []).isEmpty
    }

    mutating func setVoiceRead(_ storageID: String, allowed: Bool) {
        var readers = Set(voiceReaders ?? [])
        if allowed { readers.insert(storageID) } else { readers.remove(storageID) }
        voiceReaders = readers.isEmpty ? nil : readers.sorted()
    }

    private struct LossyPlace: Decodable {
        var place: LocationSavedPlace?
        init(from decoder: Decoder) throws { place = try? LocationSavedPlace(from: decoder) }
    }
}

/// A saved place's arrive or leave (`events`).
struct LocationPlaceEvent: Codable, Equatable {
    enum Kind: String, Codable { case arrive, leave }

    var id: String
    var kind: Kind
    var placeID: String
    var at: Date
    var isPrivate: Bool

    init(id: String = "e_" + LocationIDs.hex(bytes: 12), kind: Kind, placeID: String, at: Date, isPrivate: Bool) {
        self.id = id
        self.kind = kind
        self.placeID = placeID
        self.at = at
        self.isPrivate = isPrivate
    }

    func json(formatter: ISO8601DateFormatter) -> [String: Any] {
        ["id": id, "kind": kind.rawValue, "place_id": placeID, "at": formatter.string(from: at), "private": isPrivate]
    }
}

/// Neighbourhood, city and country from on-phone reverse geocoding.
struct LocationArea: Codable, Equatable {
    var name: String?
    var locality: String?
    var region: String?
    var country: String?
    var countryCode: String?

    var isEmpty: Bool { [name, locality, region, country, countryCode].allSatisfy { ($0 ?? "").isEmpty } }

    /// The longest field the host takes (location_store MAX_AREA_CHARS,
    /// counted in code points); a longer one refuses the whole batch.
    static let maxFieldCharacters = 80

    var json: [String: Any] {
        var object: [String: Any] = [:]
        func field(_ value: String) -> String {
            String(String.UnicodeScalarView(value.unicodeScalars.prefix(Self.maxFieldCharacters)))
        }
        if let name, !name.isEmpty { object["name"] = field(name) }
        if let locality, !locality.isEmpty { object["locality"] = field(locality) }
        if let region, !region.isEmpty { object["region"] = field(region) }
        if let country, !country.isEmpty { object["country"] = field(country) }
        if let countryCode, !countryCode.isEmpty { object["country_code"] = countryCode }
        return object
    }
}

/// A measured position, before any precision rule.
struct LocationRawFix: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var accuracy: Double
    var timestamp: Date
    var speed: Double?
    var course: Double?

    init(latitude: Double, longitude: Double, accuracy: Double, timestamp: Date, speed: Double? = nil, course: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.timestamp = timestamp
        self.speed = speed
        self.course = course
    }

    init(_ location: CLLocation) {
        self.init(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracy: max(0, location.horizontalAccuracy),
            timestamp: location.timestamp,
            speed: location.speed >= 0 ? location.speed : nil,
            course: location.course >= 0 ? location.course : nil
        )
    }

    var location: CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: timestamp
        )
    }
}

enum LocationIDs {
    static func hex(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    static func batchID() -> String { "b_" + hex(bytes: 12) }
    static func fixID() -> String { "f_" + hex(bytes: 12) }

    /// device_id and batch_id: `^[A-Za-z0-9_-]{8,64}$`.
    static func isValidWireID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{8,64}$", options: .regularExpression) != nil
    }
}

/// Local time with its offset, as the contract writes times
/// (`2026-10-14T08:02:11+01:00`).
enum LocationTime {
    static func formatter(timeZone: TimeZone = .current) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter
    }
}
