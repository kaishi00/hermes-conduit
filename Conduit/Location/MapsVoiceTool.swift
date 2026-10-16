//
//  MapsVoiceTool.swift
//  Conduit
//
//  The live voice modes' own maps tool (designs/maps-v1-contract.md section
//  6): Gemini Live, Grok Live and GPT-Live look places up, get directions
//  and travel times straight from Apple's MapKit on this iPhone, with no
//  host round trip (MapsEngine, the same code that answers the host's
//  conduit_maps). Lookups between named places need no consent; "me" and
//  the saved places need the mode's location voice consent (Settings >
//  Location > Live voice calls) and the "while I'm talking" layer, and
//  follow its detail level. Every lookup is listed in Settings > Location.
//  Descriptions and answers are for the model, not UI copy, so not
//  localized.
//

import CoreLocation
import Foundation

@MainActor
enum MapsVoiceTool {
    static let name = "maps"
    /// What seals it: nothing, it never leaves the phone.
    static let key = "maps"
    /// The lookup; a fix comes first when it uses "me". Together they stay
    /// within the 12 s the other voice host reads get, so a call isn't left
    /// waiting.
    static let lookupDeadline: TimeInterval = 7
    static let fixTimeout: Duration = .seconds(5)
    /// A fix iOS already has is good enough this long (as the talking
    /// layer's own reads: a car moves far in two minutes).
    static let fixMaxAge: TimeInterval = 30

    static let tool = VoiceHostTool(
        name: name,
        description: "Apple Maps on the user's iPhone, answered at once. search: places matching a query or category near "
            + "somewhere (default near the user). lookup: one named place or address, best match first. reverse_geocode: "
            + "what is at a place (default the user's position). directions: routes with times, distances and turns from "
            + "one place to another (default from the user). travel_times: how long from one place to up to 10 others. "
            + "navigate: open Apple Maps with directions to one place from where the user is, when they ask to go there "
            + "or to open it in Maps (on the car screen in CarPlay; behind a notification when the phone is locked). "
            + "Places are \"me\" (where the user is), one of their saved places by name, an address or a place's name, "
            + "\"lat,lon\", or \"place_id:<id>\" from an earlier answer. Times are about: say them rounded, by ear.",
        parameters: [
            "type": "object",
            "properties": [
                "action": ["type": "string", "enum": ["search", "lookup", "reverse_geocode", "directions", "travel_times", "navigate"]],
                "query": ["type": "string", "description": "search: what to find, like pharmacy or EV charger. lookup: the place or address."],
                "near": ["type": "string", "description": "search, lookup, reverse_geocode: where. search and reverse_geocode default to me."],
                "from": ["type": "string", "description": "directions, travel_times: the start; default me."],
                "to": [
                    "type": "string",
                    "list": true,
                    "description": "directions, navigate: the destination. travel_times: one place, or up to 10 as a JSON list like [\"Home\", \"Heathrow Terminal 5\"].",
                ],
                "mode": ["type": "string", "enum": ["driving", "walking", "transit", "cycling"],
                         "description": "directions, travel_times, navigate: default driving. transit gives times only."],
                "depart_at": ["type": "string", "description": "directions, travel_times: leaving at this local time, like 2026-10-16T08:30. Optional."],
                "arrive_by": ["type": "string", "description": "directions, travel_times: arriving by this local time; the answer says when to leave. Optional."],
                "limit": ["type": "integer", "description": "search: how many places, 1 to 25; default 10."],
            ],
            "required": ["action"],
        ],
        key: key
    )

    static let notShared = "The user doesn't share their location with this voice mode on this Hermes profile, so lookups from where they are or "
        + "their saved places aren't available. Lookups between named places and addresses still work. They can allow "
        + "it in Conduit's Settings > Location."

    static let answerNote = "From Apple Maps on the user's iPhone. Answer by ear: names, rough distances and times, rounded. "
        + "Never read out coordinates or ids."

    // MARK: Running it

    /// One call of the tool on `mode`. What the model hears back.
    /// `sharedHere`: the call is on the dashboard and profile the location
    /// is shared with; elsewhere only lookups between named places run.
    static func run(_ arguments: [String: Any], mode: LiveVoiceModeName,
                    controller: LocationSharingController, sharedHere: Bool) async -> [String: String] {
        // Checked at each call: the user may have turned it off mid-call.
        let locationAllowed = sharedHere && controller.letsVoiceRead(mode) && controller.settings.talking
        let places = locationAllowed ? controller.places : []
        if (arguments["action"] as? String)?.lowercased() == "navigate" {
            return await navigate(arguments, mode: mode, controller: controller, places: places, locationAllowed: locationAllowed)
        }
        guard let actionName = arguments["action"] as? String, let action = MapsRequest.Action(rawValue: actionName) else {
            return ["error": "action is search, lookup, reverse_geocode, directions, travel_times or navigate."]
        }
        let built = makeRequest(action: action, arguments: arguments, places: places, meByDefault: locationAllowed)
        let request: MapsRequest
        switch built {
        case .failure(let failure): return ["error": failure.note]
        case .success(let checked): request = checked
        }
        if !locationAllowed, usesLocation(request) { return ["error": notShared] }

        var me: MapsMe?
        if request.usesMe {
            var precision = controller.settings.talkingPrecision
            if controller.approximate || controller.fixes.isApproximate { precision = precision.capped(at: .area) }
            if precision == .places {
                me = .unavailable(.noLocation("Location detail is Places only, so nothing can be worked out from where the user is."))
            } else if let location = await controller.fixes.currentFix(
                accuracy: LocationFixProvider.desiredAccuracy(for: precision), maxAge: fixMaxAge, timeout: fixTimeout) {
                me = .at(location, precision)
            } else {
                me = .unavailable(.noLocation())
            }
        }
        let answer = await MapsEngine.answer(request, context: MapsContext(me: me, places: places), deadline: lookupDeadline)
        // Listed whatever the outcome: a lookup was attempted.
        HealthVoiceReadLog.record(mode: mode, action: "maps \(action.rawValue)", key: HealthVoiceReadLog.locationStorageKey)
        switch answer {
        case .failure(let failure):
            return ["error": "\(failure.code): \(failure.note)"]
        case .result(let result):
            return modelResult(result)
        }
    }

    /// Opens Apple Maps with directions to `to`. Opening Maps reveals
    /// nothing to the model; a saved place still needs the location consent
    /// (its name stands for where it is), and "nearest" text is looked for
    /// near the user only with it.
    static func navigate(_ arguments: [String: Any], mode: LiveVoiceModeName, controller: LocationSharingController,
                         places: [LocationSavedPlace], locationAllowed: Bool) async -> [String: String] {
        let targets = destinations(arguments["to"])
        guard targets.count == 1, let place = ref(targets[0], places: places) else {
            return ["error": "navigate needs one place in to."]
        }
        if place == .me { return ["error": "Directions start from where the user is; give where to go."] }
        if !locationAllowed, case .saved? = Self.ref(targets[0], places: controller.places) { return ["error": notShared] }
        var travel = MapsRequest.Mode.driving
        if let modeName = arguments["mode"] as? String {
            guard let chosen = MapsRequest.Mode(rawValue: modeName.lowercased()) else {
                return ["error": "mode is driving, walking, transit or cycling."]
            }
            travel = chosen
        }
        var hint: CLLocationCoordinate2D?
        if locationAllowed, controller.settings.talkingPrecision != .places {
            hint = await controller.fixes.currentFix(accuracy: LocationFixProvider.desiredAccuracy(for: .area),
                                                     maxAge: 300, timeout: .seconds(2))?.coordinate
        }
        let outcome = await MapsNavigator.open(place, mode: travel, places: places, near: hint)
        HealthVoiceReadLog.record(mode: mode, action: "maps navigate", key: HealthVoiceReadLog.locationStorageKey)
        switch outcome {
        case .openedInCar(let name):
            return ["result": "Apple Maps is open on the car screen with directions to \(name). The call keeps going."]
        case .opened(let name):
            return ["result": "Apple Maps is open on the phone with directions to \(name); tell the user to tap Go there. The call keeps going."]
        case .notified(let name):
            return ["result": "The phone isn't unlocked in Conduit, so a notification is waiting: tapping it opens Apple Maps with directions to \(name). Tell the user."]
        case .failed(let failure):
            return ["error": "\(failure.code): \(failure.note)"]
        }
    }

    /// Whether a request reads the user's position or saved places.
    static func usesLocation(_ request: MapsRequest) -> Bool {
        let refs = [request.near, request.from].compactMap { $0 } + request.to
        return refs.contains { ref in
            switch ref {
            case .me, .saved: return true
            default: return false
            }
        }
    }

    /// The request the arguments make. `meByDefault`: "near" and "from"
    /// left out mean the user's position (otherwise a search is anywhere).
    static func makeRequest(action: MapsRequest.Action, arguments: [String: Any], places: [LocationSavedPlace],
                        meByDefault: Bool) -> Result<MapsRequest, MapsFailure> {
        var request = MapsRequest(id: "voice", action: action)
        // No extra cap here: the caller's precision is already in `me`.
        request.detail = .precise
        if let query = arguments["query"] as? String {
            request.query = MapsText.cleanOrNil(query, limit: MapsRequest.maxQueryLength)
        }
        if let near = (arguments["near"] as? String).flatMap({ ref($0, places: places) }) {
            request.near = near
        } else if action == .search || action == .reverseGeocode, meByDefault {
            request.near = .me
        } else if action == .reverseGeocode {
            // Nothing to look at without the user's position.
            return .failure(MapsFailure(code: "no_location", note: notShared))
        }
        if let from = (arguments["from"] as? String).flatMap({ ref($0, places: places) }) {
            request.from = from
        } else if action == .directions || action == .travelTimes {
            request.from = .me
        }
        request.to = destinations(arguments["to"]).compactMap { ref($0, places: places) }
        if let modeName = arguments["mode"] as? String {
            guard let mode = MapsRequest.Mode(rawValue: modeName.lowercased()) else {
                return .failure(.failed("mode is driving, walking, transit or cycling."))
            }
            request.mode = mode
        }
        request.departAt = (arguments["depart_at"] as? String).flatMap(localDate)
        request.arriveBy = (arguments["arrive_by"] as? String).flatMap(localDate)
        if let limit = (arguments["limit"] as? Int) ?? (arguments["limit"] as? NSNumber)?.intValue { request.limit = limit }
        return request.checked()
    }

    /// `to` as one place, a JSON list, or a list.
    static func destinations(_ value: Any?) -> [String] {
        if let list = value as? [Any] { return list.compactMap { $0 as? String } }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return [] }
        if text.hasPrefix("["), let list = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any] {
            return list.compactMap { $0 as? String }
        }
        return [text]
    }

    /// A place as the model names it: "me", a saved place's name,
    /// "place_id:…", "lat,lon", or text to look for.
    static func ref(_ raw: String, places: [LocationSavedPlace]) -> MapsPlaceRef? {
        let text = MapsText.clean(raw, limit: MapsPlaceRef.maxTextLength)
        guard !text.isEmpty else { return nil }
        let lowered = text.lowercased()
        if ["me", "my location", "current location", "here", "where i am"].contains(lowered) { return .me }
        if lowered.hasPrefix("place_id:") {
            let id = text.dropFirst("place_id:".count).trimmingCharacters(in: .whitespaces)
            return id.isEmpty ? nil : .placeID(id)
        }
        if let place = places.first(where: {
            $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(text) == .orderedSame
        }) {
            return .saved(place.id)
        }
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, let latitude = Double(parts[0]), let longitude = Double(parts[1]),
           (-90...90).contains(latitude), (-180...180).contains(longitude) {
            return .coordinate(latitude: latitude, longitude: longitude)
        }
        return .text(text)
    }

    /// A time with an offset, or a local one on this iPhone's clock.
    static func localDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let date = MapsDates.parse(trimmed) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// The answer for the model, cut (steps first) to fit a call.
    static func modelResult(_ result: [String: Any]) -> [String: String] {
        var result = result
        for _ in 0..<6 {
            if JSONSerialization.isValidJSONObject(result),
               let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8), text.count <= VoiceHostTool.maximumResultCharacters {
                return ["result": text, "note": answerNote]
            }
            result = MapsAnswer.trimmed(result)
        }
        return ["error": "That answer is too long for a call. Ask for fewer places."]
    }
}
