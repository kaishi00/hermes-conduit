//
//  LocationSpots.swift
//  Conduit
//
//  Walking past (the notifier's designs/pulse-walking-past.md): the kinds of
//  shop Pulse asks this iPhone to watch, and the shops it came near. The
//  host sends only search words, each with an intent and a circle for
//  walking and one for driving, in the sealed reply to a batch that carries
//  `spot_entries`; the phone searches Apple Maps, watches the nearest few
//  and reports the shop's name, when, and the fix it took then. Never the
//  shop's coordinates.
//

import CoreLocation
import CryptoKit
import Foundation

/// A kind of shop to watch, from the host's reply.
struct LocationSpotWatch: Codable, Equatable {
    /// The host's id ("0.c12"): which profile's watch, and for what.
    var id: String
    /// Apple Maps search words ("florist").
    var query: String
    var until: Date
    /// "opportunity", "errand" or "arrival".
    var intent: String
    var walkRadius: CLLocationDistance
    var driveRadius: CLLocationDistance

    static let intents: Set<String> = ["opportunity", "errand", "arrival"]
    static let maxCount = 6
    static let maxQueryLength = 40
    /// What iOS's circles can be: the host keeps within this anyway.
    static let radiusRange: ClosedRange<CLLocationDistance> = 50...5_000

    func radius(driving: Bool) -> CLLocationDistance { driving ? driveRadius : walkRadius }

    /// The usable watches in a reply's `spots`: one that doesn't parse is
    /// dropped, never the rest. `date` reads the host's ISO 8601 dates (the
    /// app passes LocationHostDates.parse, which also takes fractions).
    static func parse(_ object: [String: Any],
                      date: (String) -> Date? = { ISO8601DateFormatter().date(from: $0) }) -> [LocationSpotWatch] {
        guard let spots = object["spots"] as? [[String: Any]] else { return [] }
        var found: [LocationSpotWatch] = []
        for spot in spots.prefix(maxCount) {
            guard let id = spot["id"] as? String, LocationSpotEntry.isWatchID(id),
                  let query = spot["query"] as? String, !query.isEmpty, query.count <= maxQueryLength,
                  let untilText = spot["until"] as? String, let until = date(untilText),
                  let radius = spot["radius"] as? [String: Any],
                  let walk = (radius["walk"] as? NSNumber)?.doubleValue,
                  let drive = (radius["drive"] as? NSNumber)?.doubleValue
            else { continue }
            let intent = (spot["intent"] as? String).flatMap { intents.contains($0) ? $0 : nil } ?? "opportunity"
            found.append(LocationSpotWatch(
                id: id, query: query, until: until, intent: intent,
                walkRadius: min(max(walk, radiusRange.lowerBound), radiusRange.upperBound),
                driveRadius: min(max(drive, radiusRange.lowerBound), radiusRange.upperBound)
            ))
        }
        return found
    }
}

/// A watched shop the phone came within the circle of, as it goes on the
/// wire: the shop's name, when iOS said so, and the fix taken then.
struct LocationSpotEntry: Codable, Equatable {
    var id: String = "s_" + LocationIDs.hex(bytes: 12)
    var spotID: String
    var name: String
    var at: Date
    var fixAt: Date?
    var distance: CLLocationDistance?
    var accuracy: CLLocationAccuracy?
    var speed: CLLocationSpeed?
    var radius: CLLocationDistance

    static let maxNameLength = 120
    /// Kept for the next batch at most; older ones aren't news.
    static let maxUnsent = 20

    /// The host's watch ids: a profile's index, then a card or an item.
    static func isWatchID(_ id: String) -> Bool {
        id.range(of: #"^[0-9]{1,2}\.[ci][0-9]{1,12}$"#, options: .regularExpression) != nil
    }

    func json(formatter: ISO8601DateFormatter) -> [String: Any] {
        var object: [String: Any] = [
            "id": id,
            "spot_id": spotID,
            "name": String(name.prefix(Self.maxNameLength)),
            "at": formatter.string(from: at),
            "radius_m": Int(radius.rounded()),
        ]
        if let fixAt { object["fix_at"] = formatter.string(from: fixAt) }
        if let distance { object["distance_m"] = Int(distance.rounded()) }
        if let accuracy { object["accuracy_m"] = Int(accuracy.rounded()) }
        if let speed, speed >= 0 { object["speed_mps"] = LocationPrecisionRules.rounded(speed, decimals: 1) }
        return object
    }
}

/// What the app's spot watcher (PulseSpotWatcher) keeps between launches.
struct PulseSpotState: Codable, Equatable {
    struct Spot: Codable, Equatable {
        var id: String
        var watchID: String
        var name: String
        var latitude: Double
        var longitude: Double
        var radius: CLLocationDistance

        var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
    }

    var watches: [LocationSpotWatch] = []
    var spots: [Spot] = []
    /// Whether the phone was last inside each spot, so a monitor's first
    /// answer isn't taken for an entry.
    var inside: [String: Bool] = [:]
    var searchLatitude: Double?
    var searchLongitude: Double?
    var searchedAt: Date?
    var driving = false

    var searchCentre: CLLocation? {
        guard let searchLatitude, let searchLongitude else { return nil }
        return CLLocation(latitude: searchLatitude, longitude: searchLongitude)
    }
}

extension LocationCrypto {
    /// The reply to a batch that carried `spot_entries`, sealed by the host
    /// with the ingest key under its own associated data. Must match the
    /// notifier's location store (`spots_aad`).
    static func spotsAAD(kid: String, deviceID: String, batchID: String) -> Data {
        Data([aadTag, "spots", "kid=\(kid)", "dev=\(deviceID)", "batch=\(batchID)"].joined(separator: "\n").utf8)
    }

    /// The reply's JSON object, from the ingest answer's `reply`
    /// (`{nonce, ct}`); nil when there's none, it doesn't open, or what
    /// opens isn't a JSON object.
    static func openSpotsReply(_ reply: Any?, key: SessionKey, batchID: String) -> [String: Any]? {
        openSpotsPlaintext(reply, key: key, batchID: batchID)
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    /// The reply's opened bytes; nil when there's none or it doesn't open.
    static func openSpotsPlaintext(_ reply: Any?, key: SessionKey, batchID: String) -> Data? {
        guard let reply = reply as? [String: Any],
              let nonceText = reply["nonce"] as? String, let nonce = NotificationE2E.base64URLDecoded(nonceText),
              let sealedText = reply["ct"] as? String, let sealed = NotificationE2E.base64URLDecoded(sealedText),
              nonce.count == 12, sealed.count >= 16,
              let box = try? ChaChaPoly.SealedBox(combined: nonce + sealed),
              let plaintext = try? ChaChaPoly.open(
                  box, using: SymmetricKey(data: key.key),
                  authenticating: spotsAAD(kid: key.kid, deviceID: key.deviceID, batchID: batchID))
        else { return nil }
        return plaintext
    }
}
