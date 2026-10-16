//
//  MapsEngine.swift
//  Conduit
//
//  Maps lookups answered on this iPhone with Apple's MapKit
//  (designs/maps-v1-contract.md): search, lookup, reverse geocoding,
//  directions and travel times. The host's `conduit_maps` asks through the
//  Location Push extension (sealed, sections 2-4); a live voice call asks
//  in the app (section 6). Both run the same code, so the "me" rules are
//  applied the same way:
//
//  - the user's own position never goes into an answer: "me" is "Current
//    location" (Precise) or the area's name (Area), never coordinates;
//  - at Area, distances from "me" are rounded to 100 m and a route that
//    starts or ends at "me" has no steps (the first turns give the street);
//  - inside a private saved place, a request that uses "me" is refused, and
//    a private saved place is never an origin or destination;
//  - saved places go to the host by name only, never their coordinates.
//
//  Apple sees the queries, the start and the destination (a saved place's
//  coordinates included), as with any Apple Maps use. Answers are for a model, not UI copy, so not localized.
//

import CoreLocation
import Foundation
import MapKit

// MARK: Request

/// An error the host or the voice model hears (`error`, `note`).
struct MapsFailure: Error, Equatable {
    var code: String
    var note: String

    static func notFound(_ note: String = "Nothing matched that.") -> MapsFailure { MapsFailure(code: "not_found", note: note) }
    static func noRoute(_ note: String = "Apple Maps has no route for that.") -> MapsFailure { MapsFailure(code: "no_route", note: note) }
    static func noTransit(_ note: String = "Apple Maps has no public transport times there.") -> MapsFailure {
        MapsFailure(code: "no_transit", note: note)
    }
    static let throttled = MapsFailure(code: "throttled", note: "Apple Maps is limiting lookups from this iPhone for a minute.")
    static let privatePlace = MapsFailure(code: "private", note: "That involves a private place.")
    static let paused = MapsFailure(code: "paused", note: "Location sharing is paused or off on the iPhone.")
    static func noLocation(_ note: String = "The iPhone couldn't get its position.") -> MapsFailure {
        MapsFailure(code: "no_location", note: note)
    }
    static let timeout = MapsFailure(code: "timeout", note: "Apple Maps didn't answer in time.")
    static func failed(_ note: String = "The lookup failed.") -> MapsFailure { MapsFailure(code: "failed", note: note) }
}

/// A place in a request (contract section 3): exactly one of these.
enum MapsPlaceRef: Equatable {
    case me
    /// A saved place's id (its coordinates are on this phone only).
    case saved(String)
    /// An address or a name, found with a MapKit search.
    case text(String)
    /// An Apple Maps place identifier from an earlier answer (iOS 18).
    case placeID(String)
    case coordinate(latitude: Double, longitude: Double)

    static let maxTextLength = 200

    /// The ref in a request's JSON, or nil when it's none of them.
    static func parse(_ value: Any?) -> MapsPlaceRef? {
        guard let object = value as? [String: Any] else { return nil }
        if (object["me"] as? NSNumber)?.boolValue == true { return .me }
        if let id = object["saved"] as? String {
            let clean = MapsText.clean(id, limit: 40)
            return clean.isEmpty ? nil : .saved(clean)
        }
        if let text = object["text"] as? String {
            let clean = MapsText.clean(text, limit: maxTextLength)
            return clean.isEmpty ? nil : .text(clean)
        }
        if let id = object["place_id"] as? String {
            let clean = MapsText.clean(id, limit: maxTextLength)
            return clean.isEmpty ? nil : .placeID(clean)
        }
        if let latitude = (object["lat"] as? NSNumber)?.doubleValue, let longitude = (object["lon"] as? NSNumber)?.doubleValue,
           (-90...90).contains(latitude), (-180...180).contains(longitude) {
            return .coordinate(latitude: latitude, longitude: longitude)
        }
        return nil
    }
}

/// One maps request (contract section 3).
struct MapsRequest {
    enum Action: String {
        case search, lookup, directions
        case reverseGeocode = "reverse_geocode"
        case travelTimes = "travel_times"
    }

    enum Mode: String {
        case driving, walking, transit, cycling
    }

    static let maxSearchResults = 25
    static let maxLookupResults = 5
    static let maxDestinations = 10
    static let maxQueryLength = 200

    var id: String
    var action: Action
    var expiresAt: Date?
    /// How much "me" may reveal, from the host: the phone applies its own
    /// setting again and uses the stricter.
    var detail: LocationPrecision = .precise
    var query: String?
    var near: MapsPlaceRef?
    var limit = 10
    var from: MapsPlaceRef?
    var to: [MapsPlaceRef] = []
    var mode: Mode = .driving
    var departAt: Date?
    var arriveBy: Date?
    var alternatives = true
    var steps = true

    init(id: String, action: Action) {
        self.id = id
        self.action = action
    }

    /// Whether answering needs the phone's position.
    var usesMe: Bool { near == .me || from == .me || to.contains(.me) }

    /// The request in a sealed body, with the contract's defaults: `near`
    /// and `from` are "me" when left out (not for `lookup`).
    static func parse(_ json: [String: Any]) -> Result<MapsRequest, MapsFailure> {
        guard let id = json["id"] as? String else { return .failure(.failed("The request has no id.")) }
        guard let actionName = json["action"] as? String, let action = Action(rawValue: actionName) else {
            return .failure(.failed("action is search, lookup, reverse_geocode, directions or travel_times."))
        }
        var request = MapsRequest(id: id, action: action)
        request.expiresAt = (json["expires_at"] as? String).flatMap(MapsDates.parse)
        if let detail = (json["detail"] as? String).flatMap(LocationPrecision.init(rawValue:)) { request.detail = detail }
        if let query = json["query"] as? String {
            let clean = MapsText.clean(query, limit: maxQueryLength)
            if !clean.isEmpty { request.query = clean }
        }
        if let limit = (json["limit"] as? NSNumber)?.intValue { request.limit = limit }
        if let modeName = json["mode"] as? String {
            guard let mode = Mode(rawValue: modeName.lowercased()) else { return .failure(.failed("mode is driving, walking, transit or cycling.")) }
            request.mode = mode
        }
        request.departAt = (json["depart_at"] as? String).flatMap(MapsDates.parse)
        request.arriveBy = (json["arrive_by"] as? String).flatMap(MapsDates.parse)
        if let alternatives = json["alternatives"] as? NSNumber { request.alternatives = alternatives.boolValue }
        if let steps = json["steps"] as? NSNumber { request.steps = steps.boolValue }

        func ref(_ key: String, default fallback: MapsPlaceRef?) -> Result<MapsPlaceRef?, MapsFailure> {
            guard let value = json[key], !(value is NSNull) else { return .success(fallback) }
            guard let parsed = MapsPlaceRef.parse(value) else { return .failure(.failed("\(key) isn't a place this iPhone can read.")) }
            return .success(parsed)
        }
        let meByDefault: MapsPlaceRef? = action == .lookup ? nil : .me
        switch ref("near", default: meByDefault) {
        case .success(let near): request.near = near
        case .failure(let failure): return .failure(failure)
        }
        switch ref("from", default: meByDefault) {
        case .success(let from): request.from = from
        case .failure(let failure): return .failure(failure)
        }
        if let value = json["to"], !(value is NSNull) {
            let list = (value as? [Any]) ?? [value]
            var refs: [MapsPlaceRef] = []
            for item in list {
                guard let parsed = MapsPlaceRef.parse(item) else { return .failure(.failed("to isn't a place this iPhone can read.")) }
                refs.append(parsed)
            }
            request.to = refs
        }
        return request.checked()
    }

    /// The request with only what its action uses, or why it can't run.
    func checked() -> Result<MapsRequest, MapsFailure> {
        var request = self
        switch action {
        case .search, .lookup:
            guard query != nil else { return .failure(.failed("\(action.rawValue) needs a query.")) }
            let most = action == .search ? Self.maxSearchResults : Self.maxLookupResults
            request.limit = action == .search ? min(most, max(1, limit)) : most
            request.from = nil
            request.to = []
        case .reverseGeocode:
            guard near != nil else { return .failure(.failed("reverse_geocode needs near.")) }
            request.query = nil
            request.from = nil
            request.to = []
        case .directions:
            guard from != nil else { return .failure(.failed("directions needs from.")) }
            guard to.count == 1 else { return .failure(.failed("directions needs one place in to.")) }
            request.near = nil
            request.query = nil
        case .travelTimes:
            guard from != nil else { return .failure(.failed("travel_times needs from.")) }
            guard (1...Self.maxDestinations).contains(to.count) else {
                return .failure(.failed("travel_times needs 1 to \(Self.maxDestinations) places in to."))
            }
            request.near = nil
            request.query = nil
        }
        if request.departAt != nil, request.arriveBy != nil { request.departAt = nil }
        return .success(request)
    }
}

/// Where "me" is for one request, or why it can't be used.
enum MapsMe {
    /// The phone's position and how much of it the answer may reveal
    /// (`area` or `precise`; `places` refuses "me").
    case at(CLLocation, LocationPrecision)
    case unavailable(MapsFailure)
}

struct MapsContext {
    /// Nil when the request doesn't use "me" (no fix was taken).
    var me: MapsMe?
    var places: [LocationSavedPlace]
    var now = Date()
    var timeZone = TimeZone.current

    init(me: MapsMe?, places: [LocationSavedPlace], now: Date = Date(), timeZone: TimeZone = .current) {
        self.me = me
        self.places = places
        self.now = now
        self.timeZone = timeZone
    }
}

/// The answer (contract section 4).
enum MapsAnswer {
    case result([String: Any])
    case failure(MapsFailure)

    /// The plaintext limit.
    static let maximumBytes = 64_000

    func json(id: String) -> [String: Any] {
        switch self {
        case .result(let result): return ["id": id, "ok": true, "result": result]
        case .failure(let failure): return ["id": id, "ok": false, "error": failure.code, "note": failure.note]
        }
    }

    /// The answer's JSON, cut to fit `maximumBytes`: steps go first, then
    /// half the places or results at a time.
    func plaintext(id: String) -> Data {
        var answer = self
        for _ in 0..<8 {
            let object = answer.json(id: id)
            if JSONSerialization.isValidJSONObject(object),
               let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
               data.count <= Self.maximumBytes {
                return data
            }
            guard case .result(let result) = answer else { break }
            answer = .result(Self.trimmed(result))
        }
        let fallback = MapsAnswer.failure(.failed("The answer was too long.")).json(id: id)
        return (try? JSONSerialization.data(withJSONObject: fallback, options: [.sortedKeys])) ?? Data()
    }

    static func trimmed(_ result: [String: Any]) -> [String: Any] {
        var result = result
        if var routes = result["routes"] as? [[String: Any]], routes.contains(where: { $0["steps"] != nil }) {
            for index in routes.indices { routes[index]["steps"] = nil }
            result["routes"] = routes
            return result
        }
        for key in ["places", "results", "routes"] {
            if let list = result[key] as? [Any], list.count > 1 {
                result[key] = Array(list.prefix(list.count / 2))
            }
        }
        return result
    }
}

// MARK: Text and dates

enum MapsText {
    /// Control characters become spaces; trimmed and cut to `limit`.
    static func clean(_ text: String, limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            scalars.append(scalar.properties.generalCategory == .control ? " " : scalar)
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(limit))
    }

    static func cleanOrNil(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let clean = clean(text, limit: limit)
        return clean.isEmpty ? nil : clean
    }
}

enum MapsDates {
    static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: trimmed) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: trimmed)
    }
}

// MARK: Engine

@MainActor
enum MapsEngine {
    static let searchSpan: CLLocationDistance = 10_000
    static let resolveSpan: CLLocationDistance = 50_000
    static let areaNameTimeout: TimeInterval = 1.5
    /// MapKit allows about 50 lookups a minute: a few at a time.
    static let concurrentLookups = 4

    /// Runs `request`, giving up with `timeout` after `deadline` seconds.
    static func answer(_ request: MapsRequest, context: MapsContext, deadline: TimeInterval) async -> MapsAnswer {
        await MapsDeadline.run(after: deadline, fallback: MapsAnswer.failure(.timeout)) {
            await MapsEngine.answer(request, context: context)
        }
    }

    static func answer(_ request: MapsRequest, context: MapsContext) async -> MapsAnswer {
        let run = MapsRun(request: request, context: context)
        do {
            return .result(try await run.result())
        } catch {
            return .failure(MapsRun.failure(error, transit: request.mode == .transit))
        }
    }

    /// The place `ref` names, resolved as a lookup resolves it, to open
    /// Apple Maps there (navigate). Never "me": directions start there.
    static func destination(_ ref: MapsPlaceRef, places: [LocationSavedPlace], near hint: CLLocationCoordinate2D?,
                            deadline: TimeInterval) async -> Result<MKMapItem, MapsFailure> {
        let run = MapsRun(request: MapsRequest(id: "navigate", action: .lookup), context: MapsContext(me: nil, places: places))
        return await MapsDeadline.run(after: deadline, fallback: .failure(.timeout)) {
            do {
                return .success(try await run.destination(ref, near: hint))
            } catch {
                return .failure(MapsRun.failure(error, transit: false))
            }
        }
    }
}

/// One request's work: the places it resolved and "me".
@MainActor
private final class MapsRun {
    struct Resolved {
        var item: MKMapItem
        var coordinate: CLLocationCoordinate2D
        /// What the answer says about it.
        var json: [String: Any]
        var isMe: Bool
    }

    let request: MapsRequest
    let context: MapsContext
    private var meLocation: CLLocation?
    private var mePrecision: LocationPrecision = .precise
    private var mePlace: [String: Any]?

    init(request: MapsRequest, context: MapsContext) {
        self.request = request
        self.context = context
    }

    func result() async throws -> [String: Any] {
        if request.usesMe { try checkMe() }
        switch request.action {
        case .search: return try await search()
        case .lookup: return try await lookup()
        case .reverseGeocode: return try await reverseGeocode()
        case .directions: return try await directions()
        case .travelTimes: return try await travelTimes()
        }
    }

    // MARK: Me

    private func checkMe() throws {
        guard let me = context.me else { throw MapsFailure.noLocation() }
        switch me {
        case .unavailable(let failure):
            throw failure
        case .at(let location, let shared):
            let precision = shared.capped(at: request.detail)
            guard precision != .places else {
                throw MapsFailure.noLocation("Location detail is Places only, so nothing can be worked out from where the user is.")
            }
            if LocationPrecisionRules.containingPrivatePlace(LocationRawFix(location), places: context.places) != nil {
                throw MapsFailure.privatePlace
            }
            meLocation = location
            mePrecision = precision
        }
    }

    private var meAtArea: Bool { mePrecision != .precise }

    /// "Me" as an answer says it: the area's name at Area, "Current
    /// location" and the street address at Precise. Never coordinates.
    private func meJSON() async -> [String: Any] {
        if let mePlace { return mePlace }
        guard let meLocation else { return ["name": "Current location"] }
        let placemark = await MapsDeadline.run(after: MapsEngine.areaNameTimeout, fallback: nil as CLPlacemark?) {
            try? await MapsKit.reverseGeocode(meLocation)
        }
        var json: [String: Any]
        if meAtArea {
            json = ["name": placemark.flatMap(Self.areaName) ?? "Current area"]
        } else {
            json = ["name": "Current location"]
            if let placemark, let address = Self.address(placemark) { json["address"] = address }
        }
        if let zone = placemark?.timeZone?.identifier { json["time_zone"] = zone }
        mePlace = json
        return json
    }

    private static func areaName(_ placemark: CLPlacemark) -> String? {
        var parts: [String] = []
        for part in [placemark.subLocality, placemark.locality, placemark.country] {
            if let part = MapsText.cleanOrNil(part, limit: 80), !parts.contains(part) { parts.append(part) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: Resolving places

    /// Where a text ref is looked for: near "me" when the request has it,
    /// else near `fallback`.
    private func hint(_ fallback: CLLocationCoordinate2D? = nil) -> CLLocationCoordinate2D? {
        meLocation?.coordinate ?? fallback
    }

    func destination(_ ref: MapsPlaceRef, near hint: CLLocationCoordinate2D?) async throws -> MKMapItem {
        if ref == .me { throw MapsFailure.failed("Directions start from where the user is; give where to go.") }
        return try await resolve(ref, near: hint).item
    }

    private func resolve(_ ref: MapsPlaceRef, near hint: CLLocationCoordinate2D?) async throws -> Resolved {
        switch ref {
        case .me:
            guard let meLocation else { throw MapsFailure.noLocation() }
            return Resolved(item: MapsKit.item(at: meLocation.coordinate, name: nil), coordinate: meLocation.coordinate,
                            json: await meJSON(), isMe: true)
        case .saved(let id):
            guard let place = context.places.first(where: { $0.id == id }) else {
                throw MapsFailure.notFound("There's no saved place with that id on this iPhone.")
            }
            guard !place.isPrivate else { throw MapsFailure.privatePlace }
            // The host hears its name only; Apple routes from its coordinates.
            let name = MapsText.clean(place.name, limit: LocationSavedPlace.maxNameLength)
            return Resolved(item: MapsKit.item(at: place.coordinate, name: name), coordinate: place.coordinate,
                            json: ["name": name.isEmpty ? "Saved place" : name], isMe: false)
        case .text(let text):
            let found = try await MapsKit.search(text, near: hint, span: MapsEngine.resolveSpan)
            guard let item = found.first else { throw MapsFailure.notFound("Nothing matched \(text).") }
            return Resolved(item: item, coordinate: item.placemark.coordinate, json: placeJSON(item, from: nil), isMe: false)
        case .placeID(let id):
            guard #available(iOS 18.0, *) else {
                throw MapsFailure.notFound("Place ids need iOS 18 on the iPhone; look it up by name instead.")
            }
            let item = try await MapsKit.item(placeID: id)
            return Resolved(item: item, coordinate: item.placemark.coordinate, json: placeJSON(item, from: nil), isMe: false)
        case .coordinate(let latitude, let longitude):
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            return Resolved(item: MapsKit.item(at: coordinate, name: nil), coordinate: coordinate,
                            json: ["name": Self.coordinateName(coordinate), "lat": Self.rounded(latitude), "lon": Self.rounded(longitude)],
                            isMe: false)
        }
    }

    private static func coordinateName(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", locale: Locale(identifier: "en_US_POSIX"), coordinate.latitude, coordinate.longitude)
    }

    /// The name a destination that failed is listed by.
    private func label(_ ref: MapsPlaceRef) -> String {
        switch ref {
        case .me: return meAtArea ? "Current area" : "Current location"
        case .saved(let id):
            return context.places.first { $0.id == id && !$0.isPrivate }.map(\.name) ?? "Saved place"
        case .text(let text): return text
        case .placeID(let id): return id
        case .coordinate(let latitude, let longitude):
            return Self.coordinateName(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        }
    }

    // MARK: Places in answers

    private func placeJSON(_ item: MKMapItem, from origin: Resolved?) -> [String: Any] {
        let placemark = item.placemark
        var json: [String: Any] = [
            "name": MapsText.cleanOrNil(item.name, limit: 120) ?? MapsText.cleanOrNil(placemark.name, limit: 120) ?? "Place",
            "lat": Self.rounded(placemark.coordinate.latitude),
            "lon": Self.rounded(placemark.coordinate.longitude),
        ]
        if let address = Self.address(placemark) { json["address"] = address }
        if let category = item.pointOfInterestCategory.flatMap(Self.category) { json["category"] = category }
        if let phone = MapsText.cleanOrNil(item.phoneNumber, limit: 40) { json["phone"] = phone }
        if let url = item.url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            json["url"] = String(url.absoluteString.prefix(300))
        }
        if #available(iOS 18.0, *), let identifier = item.identifier {
            json["place_id"] = String(identifier.rawValue.prefix(200))
        }
        if let zone = item.timeZone?.identifier { json["time_zone"] = zone }
        if let origin {
            let meters = CLLocation(latitude: origin.coordinate.latitude, longitude: origin.coordinate.longitude)
                .distance(from: CLLocation(latitude: placemark.coordinate.latitude, longitude: placemark.coordinate.longitude))
            json["distance_m"] = distance(meters, fromMe: origin.isMe)
        }
        return json
    }

    /// Meters as an answer gives them: to 100 m from "me" at Area, 10 m from
    /// "me" at Precise, to the metre otherwise.
    private func distance(_ meters: CLLocationDistance, fromMe: Bool) -> Int {
        guard meters.isFinite, meters >= 0, meters < 1e9 else { return 0 }
        guard fromMe else { return Int(meters.rounded()) }
        return LocationPrecisionRules.roundedDistance(meters, step: meAtArea ? 100 : 10)
    }

    static func rounded(_ value: Double) -> Double {
        value.isFinite ? LocationPrecisionRules.rounded(value, decimals: 5) : 0
    }

    /// Seconds or metres as a whole number (0 for anything MapKit leaves
    /// unknown).
    static func whole(_ value: Double) -> Int {
        value.isFinite && abs(value) < 1e9 ? Int(value.rounded()) : 0
    }

    static func address(_ placemark: CLPlacemark) -> String? {
        let street = [placemark.subThoroughfare, placemark.thoroughfare].compactMap { MapsText.cleanOrNil($0, limit: 100) }
            .joined(separator: " ")
        let town = [placemark.locality, placemark.postalCode].compactMap { MapsText.cleanOrNil($0, limit: 60) }
            .joined(separator: " ")
        let parts = [street, town, MapsText.cleanOrNil(placemark.country, limit: 60) ?? ""].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : String(parts.joined(separator: ", ").prefix(300))
    }

    /// "MKPOICategoryPublicTransport" as "public transport".
    static func category(_ category: MKPointOfInterestCategory) -> String? {
        var raw = category.rawValue
        if raw.hasPrefix("MKPOICategory") { raw = String(raw.dropFirst("MKPOICategory".count)) }
        var words = ""
        for character in raw {
            if character.isUppercase, !words.isEmpty { words.append(" ") }
            words.append(character)
        }
        let clean = MapsText.clean(words.lowercased(), limit: 60)
        return clean.isEmpty ? nil : clean
    }

    // MARK: Actions

    private func search() async throws -> [String: Any] {
        var centre: Resolved?
        if let near = request.near { centre = try await resolve(near, near: hint()) }
        let items = try await MapsKit.search(request.query ?? "", near: centre?.coordinate, span: MapsEngine.searchSpan)
        guard !items.isEmpty else { throw MapsFailure.notFound() }
        return ["places": items.prefix(request.limit).map { placeJSON($0, from: centre) }]
    }

    private func lookup() async throws -> [String: Any] {
        var centre: Resolved?
        if let near = request.near { centre = try await resolve(near, near: hint()) }
        let items = try await MapsKit.search(request.query ?? "", near: centre?.coordinate ?? hint(), span: MapsEngine.resolveSpan)
        guard !items.isEmpty else { throw MapsFailure.notFound() }
        return ["places": items.prefix(MapsRequest.maxLookupResults).map { placeJSON($0, from: centre) }]
    }

    private func reverseGeocode() async throws -> [String: Any] {
        guard let near = request.near else { throw MapsFailure.failed("reverse_geocode needs near.") }
        switch near {
        case .me:
            return ["places": [await meJSON()]]
        case .saved:
            // Its address would tell where it is: the name only.
            return ["places": [try await resolve(near, near: nil).json]]
        case .text, .placeID:
            return ["places": [try await resolve(near, near: hint()).json]]
        case .coordinate(let latitude, let longitude):
            let placemark = try await MapsKit.reverseGeocode(CLLocation(latitude: latitude, longitude: longitude))
            var json: [String: Any] = [
                "name": MapsText.cleanOrNil(placemark.name, limit: 120) ?? Self.coordinateName(
                    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)),
                "lat": Self.rounded(latitude),
                "lon": Self.rounded(longitude),
            ]
            if let address = Self.address(placemark) { json["address"] = address }
            if let zone = placemark.timeZone?.identifier { json["time_zone"] = zone }
            return ["places": [json]]
        }
    }

    private func endpoints() async throws -> (from: Resolved, to: Resolved) {
        guard let fromRef = request.from, let toRef = request.to.first else { throw MapsFailure.failed("directions needs from and to.") }
        // A text endpoint is looked for near the other one when "me" isn't in it.
        if case .text = fromRef, toRef != .me {
            let to = try await resolve(toRef, near: hint())
            let from = try await resolve(fromRef, near: hint(to.coordinate))
            return (from, to)
        }
        let from = try await resolve(fromRef, near: hint())
        let to = try await resolve(toRef, near: hint(from.coordinate))
        return (from, to)
    }

    private func directionsRequest(from: Resolved, to: Resolved) throws -> MKDirections.Request {
        let directions = MKDirections.Request()
        directions.source = from.item
        directions.destination = to.item
        switch request.mode {
        case .driving: directions.transportType = .automobile
        case .walking: directions.transportType = .walking
        case .transit: directions.transportType = .transit
        case .cycling:
            throw MapsFailure.noRoute("Apple Maps on this iPhone gives no cycling times; try walking or driving.")
        }
        if let departAt = request.departAt {
            directions.departureDate = departAt
        } else if let arriveBy = request.arriveBy {
            directions.arrivalDate = arriveBy
        }
        return directions
    }

    private func timeFields(duration: TimeInterval, departure: Date?, arrival: Date?) -> [String: Any] {
        let formatter = LocationTime.formatter(timeZone: context.timeZone)
        var json: [String: Any] = [:]
        if let arriveBy = request.arriveBy {
            let leave = arriveBy.addingTimeInterval(-duration)
            json["leave_by"] = formatter.string(from: leave)
            json["depart_at"] = formatter.string(from: departure ?? leave)
            json["arrive_at"] = formatter.string(from: arrival ?? arriveBy)
        } else {
            let depart = departure ?? request.departAt ?? context.now
            json["depart_at"] = formatter.string(from: depart)
            json["arrive_at"] = formatter.string(from: arrival ?? depart.addingTimeInterval(duration))
        }
        return json
    }

    private func directions() async throws -> [String: Any] {
        let (from, to) = try await endpoints()
        let directions = try directionsRequest(from: from, to: to)
        var json: [String: Any] = ["from": from.json, "to": to.json, "mode": request.mode.rawValue]
        if request.mode == .transit {
            // MapKit gives transit times, not steps.
            let eta = try await MapsKit.eta(directions)
            json["routes"] = [[
                "name": "Public transport",
                "duration_s": Self.whole(eta.expectedTravelTime),
                "distance_m": distance(eta.distance, fromMe: from.isMe || to.isMe),
            ] as [String: Any]]
            json.merge(timeFields(duration: eta.expectedTravelTime, departure: eta.expectedDepartureDate,
                                  arrival: eta.expectedArrivalDate)) { _, new in new }
            return json
        }
        directions.requestsAlternateRoutes = request.alternatives
        let routes = try await MapsKit.routes(directions)
        guard let first = routes.first else { throw MapsFailure.noRoute() }
        // The first and last turns would give the street "me" is on.
        let withSteps = request.steps && !((from.isMe || to.isMe) && meAtArea)
        json["routes"] = routes.prefix(request.alternatives ? 3 : 1).map { route -> [String: Any] in
            var entry: [String: Any] = [
                "name": MapsText.cleanOrNil(route.name, limit: 120) ?? "Route",
                "duration_s": Self.whole(route.expectedTravelTime),
                "distance_m": distance(route.distance, fromMe: from.isMe || to.isMe),
                "has_tolls": route.hasTolls,
            ]
            let advisories = route.advisoryNotices.prefix(5).compactMap { MapsText.cleanOrNil($0, limit: 200) }
            if !advisories.isEmpty { entry["advisories"] = advisories }
            if withSteps {
                entry["steps"] = route.steps.compactMap { step -> [String: Any]? in
                    guard let text = MapsText.cleanOrNil(step.instructions, limit: 200) else { return nil }
                    return ["text": text, "distance_m": Self.whole(step.distance)]
                }.prefix(60).map { $0 }
            }
            return entry
        }
        json.merge(timeFields(duration: first.expectedTravelTime, departure: nil, arrival: nil)) { _, new in new }
        return json
    }

    private func travelTimes() async throws -> [String: Any] {
        guard let fromRef = request.from else { throw MapsFailure.failed("travel_times needs from.") }
        let from = try await resolve(fromRef, near: hint())
        travelOrigin = from
        travelResults = [:]
        let count = request.to.count
        var start = 0
        while start < count, !Task.isCancelled {
            let chunk = Array(start..<min(count, start + MapsEngine.concurrentLookups))
            // Each child stores its own result: a task group's results must
            // be Sendable, and the answers' JSON isn't.
            await withTaskGroup(of: Void.self) { group in
                for index in chunk {
                    group.addTask { await self.storeTravelTime(index) }
                }
            }
            start += MapsEngine.concurrentLookups
        }
        let results: [[String: Any]] = (0..<count).map { index in
            travelResults[index] ?? ["to": ["name": label(request.to[index])], "error": "failed"]
        }
        return ["from": from.json, "mode": request.mode.rawValue, "results": results]
    }

    private var travelOrigin: Resolved?
    private var travelResults: [Int: [String: Any]] = [:]

    private func storeTravelTime(_ index: Int) async {
        guard let from = travelOrigin, request.to.indices.contains(index) else { return }
        travelResults[index] = await travelTime(from: from, to: request.to[index])
    }

    private func travelTime(from: Resolved, to ref: MapsPlaceRef) async -> [String: Any] {
        do {
            let to = try await resolve(ref, near: hint(from.coordinate))
            let eta = try await MapsKit.eta(try directionsRequest(from: from, to: to))
            var entry: [String: Any] = [
                "to": to.json,
                "duration_s": Self.whole(eta.expectedTravelTime),
                "distance_m": distance(eta.distance, fromMe: from.isMe || to.isMe),
            ]
            let times = timeFields(duration: eta.expectedTravelTime, departure: eta.expectedDepartureDate,
                                   arrival: eta.expectedArrivalDate)
            entry["arrive_at"] = times["arrive_at"]
            if let leave = times["leave_by"] { entry["leave_by"] = leave }
            return entry
        } catch {
            let failure = Self.failure(error, transit: request.mode == .transit)
            return ["to": ["name": label(ref)], "error": failure.code]
        }
    }

    // MARK: Errors

    static func failure(_ error: Error, transit: Bool) -> MapsFailure {
        if let failure = error as? MapsFailure { return failure }
        let nsError = error as NSError
        if nsError.domain == MKErrorDomain {
            switch nsError.code {
            case Int(MKError.Code.loadingThrottled.rawValue): return .throttled
            case Int(MKError.Code.directionsNotFound.rawValue): return transit ? .noTransit() : .noRoute()
            case Int(MKError.Code.placemarkNotFound.rawValue): return .notFound()
            default: return .failed("Apple Maps couldn't answer just now.")
            }
        }
        if nsError.domain == kCLErrorDomain, nsError.code == CLError.Code.geocodeFoundNoResult.rawValue {
            return .notFound()
        }
        if nsError.domain == NSURLErrorDomain { return .failed("The iPhone couldn't reach Apple Maps.") }
        return .failed()
    }
}

// MARK: MapKit calls

/// MapKit's completion-handler calls as async ones. Cancelling the task
/// (a deadline passing) cancels the MapKit call and throws
/// CancellationError, so nothing keeps running after the answer is sent.
@MainActor
enum MapsKit {
    /// One completion-handler call: resumed once, by its completion or by
    /// cancellation, whichever comes first.
    private final class Pending<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        private var cancelled = false
        private let stop: () -> Void

        init(stop: @escaping () -> Void) { self.stop = stop }

        func begin(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
            lock.withLock {
                guard !cancelled else { return false }
                self.continuation = continuation
                return true
            }
        }

        func finish(_ result: Result<Value, Error>) {
            let pending: CheckedContinuation<Value, Error>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(with: result)
        }

        func cancel() {
            let pending: CheckedContinuation<Value, Error>? = lock.withLock {
                cancelled = true
                defer { continuation = nil }
                return continuation
            }
            guard let pending else { return }
            pending.resume(throwing: CancellationError())
            DispatchQueue.main.async { self.stop() }
        }
    }

    private static func call<Value>(stop: @escaping () -> Void,
                                    _ start: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        let pending = Pending<Value>(stop: stop)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                guard pending.begin(continuation) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                start { pending.finish($0) }
            }
        } onCancel: {
            pending.cancel()
        }
    }

    static func item(at coordinate: CLLocationCoordinate2D, name: String?) -> MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        if let name, !name.isEmpty { item.name = name }
        return item
    }

    static func search(_ query: String, near centre: CLLocationCoordinate2D?, span: CLLocationDistance) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let centre {
            request.region = MKCoordinateRegion(center: centre, latitudinalMeters: span, longitudinalMeters: span)
        }
        let search = MKLocalSearch(request: request)
        return try await call(stop: { search.cancel() }) { done in
            search.start { response, error in
                withExtendedLifetime(search) {}
                if let response {
                    done(.success(response.mapItems))
                } else {
                    done(.failure(error ?? MapsFailure.notFound()))
                }
            }
        }
    }

    @available(iOS 18.0, *)
    static func item(placeID: String) async throws -> MKMapItem {
        let identifier: MKMapItem.Identifier? = MKMapItem.Identifier(rawValue: placeID)
        guard let identifier else { throw MapsFailure.notFound("That place id isn't one Apple Maps knows.") }
        let request = MKMapItemRequest(mapItemIdentifier: identifier)
        return try await call(stop: { request.cancel() }) { done in
            request.getMapItem { item, error in
                withExtendedLifetime(request) {}
                if let item {
                    done(.success(item))
                } else {
                    done(.failure(error ?? MapsFailure.notFound()))
                }
            }
        }
    }

    static func reverseGeocode(_ location: CLLocation) async throws -> CLPlacemark {
        let geocoder = CLGeocoder()
        return try await call(stop: { geocoder.cancelGeocode() }) { done in
            geocoder.reverseGeocodeLocation(location) { placemarks, error in
                withExtendedLifetime(geocoder) {}
                if let placemark = placemarks?.first {
                    done(.success(placemark))
                } else {
                    done(.failure(error ?? MapsFailure.notFound()))
                }
            }
        }
    }

    static func routes(_ request: MKDirections.Request) async throws -> [MKRoute] {
        let directions = MKDirections(request: request)
        return try await call(stop: { directions.cancel() }) { done in
            directions.calculate { response, error in
                withExtendedLifetime(directions) {}
                if let response {
                    done(.success(response.routes))
                } else {
                    done(.failure(error ?? MapsFailure.noRoute()))
                }
            }
        }
    }

    static func eta(_ request: MKDirections.Request) async throws -> MKDirections.ETAResponse {
        let directions = MKDirections(request: request)
        return try await call(stop: { directions.cancel() }) { done in
            directions.calculateETA { response, error in
                withExtendedLifetime(directions) {}
                if let response {
                    done(.success(response))
                } else {
                    done(.failure(error ?? MapsFailure.noRoute()))
                }
            }
        }
    }
}

// MARK: Deadlines

/// The first of an operation's result and a deadline's fallback.
enum MapsDeadline {
    private final class Once<Value> {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Never>?

        init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }

        func resume(_ value: Value) {
            let pending: CheckedContinuation<Value, Never>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: value)
        }
    }

    static func run<Value>(after seconds: TimeInterval, fallback: Value,
                           _ operation: @escaping @MainActor () async -> Value) async -> Value {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
            let once = Once(continuation)
            let task = Task { @MainActor in
                let value = await operation()
                once.resume(value)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                once.resume(fallback)
                task.cancel()
            }
        }
    }
}
