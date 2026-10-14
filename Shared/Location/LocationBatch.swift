//
//  LocationBatch.swift
//  Conduit
//
//  What one sealed upload says (designs/location-v1-contract.md section 2),
//  with the precision rules applied on the phone before sealing. The host
//  applies them again, so a bug here can't widen what it keeps:
//
//  - places: the saved place the fix is in, if any. No coordinates, no
//    accuracy, no area, no distances.
//  - area: the coordinate rounded to 2 decimals (about 1 km), accuracy at
//    least 1000 m, the on-phone geocoded area, distances to saved places
//    rounded to 100 m.
//  - precise: the coordinate and accuracy as measured, the area, distances
//    rounded to 10 m, speed and course.
//  - Inside a private place, at any precision: that place's id and nothing
//    else, so the host says "at a private place".
//

import CoreLocation
import Foundation

/// A fix as it goes on the wire, built from a raw measurement.
struct LocationFixRecord: Equatable {
    var id: String
    var source: LocationFixSource
    var raw: LocationRawFix
    var area: LocationArea?

    init(id: String = LocationIDs.fixID(), source: LocationFixSource, raw: LocationRawFix, area: LocationArea? = nil) {
        self.id = id
        self.source = source
        self.raw = raw
        self.area = area
    }
}

enum LocationPrecisionRules {
    /// Area precision never claims better than this.
    static let areaMinimumAccuracy: Double = 1_000
    /// Past this accuracy (an approximate-only fix) a saved place can't be
    /// told apart from its neighbours: no place is named.
    static let placeMatchMaximumAccuracy: Double = 500

    /// The saved place the fix is in: the one whose center is nearest
    /// relative to its radius.
    static func containingPlace(_ raw: LocationRawFix, places: [LocationSavedPlace]) -> LocationSavedPlace? {
        guard raw.accuracy <= placeMatchMaximumAccuracy else { return nil }
        let location = raw.location
        return places
            .map { (place: $0, ratio: $0.distance(to: location) / $0.radius) }
            .filter { $0.ratio <= 1 }
            .min { $0.ratio < $1.ratio }?
            .place
    }

    /// The private place the fix's raw coordinate falls in, whatever its
    /// accuracy, including an approximate-only fix: where a private place is
    /// must never follow from a fix sent near it.
    static func containingPrivatePlace(_ raw: LocationRawFix, places: [LocationSavedPlace]) -> LocationSavedPlace? {
        let location = raw.location
        return places
            .filter(\.isPrivate)
            .map { (place: $0, ratio: $0.distance(to: location) / $0.radius) }
            .filter { $0.ratio <= 1 }
            .min { $0.ratio < $1.ratio }?
            .place
    }

    static func rounded(_ value: Double, decimals: Int) -> Double {
        let scale = pow(10, Double(decimals))
        return (value * scale).rounded() / scale
    }

    static func roundedDistance(_ meters: Double, step: Double) -> Int {
        Int((meters / step).rounded() * step)
    }

    /// The `fix` object at `precision`. `approximateOnly`: iOS gave only an
    /// approximate position, so no place is named and nothing is precise.
    static func json(
        _ fix: LocationFixRecord,
        precision requested: LocationPrecision,
        places: [LocationSavedPlace],
        approximateOnly: Bool,
        formatter: ISO8601DateFormatter
    ) -> [String: Any] {
        let precision = approximateOnly ? requested.capped(at: .area) : requested
        var object: [String: Any] = [
            "id": fix.id,
            "at": formatter.string(from: fix.raw.timestamp),
            "source": fix.source.rawValue,
            "precision": precision.rawValue,
        ]
        // Inside a private place only its id goes, even for a fix too rough
        // to name an ordinary place: where it is would follow from more.
        if let privatePlace = containingPrivatePlace(fix.raw, places: places) {
            object["place_id"] = privatePlace.id
            return object
        }
        if !approximateOnly, let place = containingPlace(fix.raw, places: places) {
            object["place_id"] = place.id
        }
        guard precision != .places else { return object }

        let location = fix.raw.location
        let step: Double = precision == .precise ? 10 : 100
        var distances: [String: Int] = [:]
        for other in places where !other.isPrivate {
            distances[other.id] = roundedDistance(other.distance(to: location), step: step)
        }
        if !distances.isEmpty { object["distances_m"] = distances }
        if let area = fix.area, !area.isEmpty { object["area"] = area.json }

        switch precision {
        case .area:
            object["lat"] = rounded(fix.raw.latitude, decimals: 2)
            object["lon"] = rounded(fix.raw.longitude, decimals: 2)
            object["accuracy_m"] = Int(max(areaMinimumAccuracy, fix.raw.accuracy).rounded())
        case .precise:
            object["lat"] = rounded(fix.raw.latitude, decimals: 6)
            object["lon"] = rounded(fix.raw.longitude, decimals: 6)
            object["accuracy_m"] = Int(fix.raw.accuracy.rounded())
            if let speed = fix.raw.speed { object["speed_mps"] = rounded(speed, decimals: 1) }
            if let course = fix.raw.course { object["course"] = rounded(course, decimals: 0) }
        case .places:
            break
        }
        return object
    }

    /// The `places` list: names and kinds only. A private place is listed
    /// without its name or kind, so rules can name it but nobody reads what
    /// or where it is.
    static func placesJSON(_ places: [LocationSavedPlace]) -> [[String: Any]] {
        places.prefix(LocationSavedPlace.maxCount).map { place -> [String: Any] in
            [
                "id": place.id,
                "name": place.isPrivate ? privatePlaceName : String(place.name.prefix(LocationSavedPlace.maxNameLength)),
                "kind": place.isPrivate ? LocationPlaceKind.other.rawValue : place.kind.rawValue,
                "private": place.isPrivate,
            ]
        }
    }

    /// What the host lists a private place as. English, like the relay's
    /// generic copy: it's the agent's text, not the app's.
    static let privatePlaceName = "Private place"

    /// Changes when anything the host keeps about the places changes.
    static func placesDigest(_ places: [LocationSavedPlace]) -> String {
        places.prefix(LocationSavedPlace.maxCount)
            .map { place -> String in
                let name = place.isPrivate ? privatePlaceName : String(place.name.prefix(LocationSavedPlace.maxNameLength))
                let kind = place.isPrivate ? LocationPlaceKind.other.rawValue : place.kind.rawValue
                return [place.id, name, kind, place.isPrivate ? "1" : "0"].joined(separator: "|")
            }
            .joined(separator: "\n")
    }
}

/// One upload's plaintext.
struct LocationBatch {
    var batchID = LocationIDs.batchID()
    var sentAt: Date
    var settings: LocationSharingSettings
    var timeZone: TimeZone = .current
    var approximateOnly = false
    /// The saved places, when the host's copy needs replacing.
    var places: [LocationSavedPlace]?
    /// All saved places, for naming the place a fix is in and distances.
    var knownPlaces: [LocationSavedPlace] = []
    var fix: LocationFixRecord?
    var events: [LocationPlaceEvent] = []
    var locateID: String?
    /// What this iPhone can answer for the host (`sharing.features`):
    /// "maps" is MapKit lookups (designs/maps-v1-contract.md section 1).
    /// Emptied when the key can't open a maps request (LocationIngest).
    var features: [String] = LocationBatch.phoneFeatures

    static let phoneFeatures = ["maps"]

    func json() -> [String: Any] {
        let formatter = LocationTime.formatter(timeZone: timeZone)
        var sharing = settings.json(at: sentAt, timeZone: timeZone, formatter: formatter)
        if !features.isEmpty { sharing["features"] = features }
        var object: [String: Any] = [
            "batch_id": batchID,
            "sent_at": formatter.string(from: sentAt),
            "sharing": sharing,
        ]
        if let places { object["places"] = LocationPrecisionRules.placesJSON(places) }
        if let fix {
            object["fix"] = LocationPrecisionRules.json(
                fix, precision: settings.precision(for: fix.source), places: knownPlaces,
                approximateOnly: approximateOnly, formatter: formatter
            )
        }
        if !events.isEmpty { object["events"] = events.map { $0.json(formatter: formatter) } }
        if let locateID { object["locate_id"] = locateID }
        return object
    }

    func plaintext() throws -> Data {
        try JSONSerialization.data(withJSONObject: json(), options: [.sortedKeys])
    }
}
