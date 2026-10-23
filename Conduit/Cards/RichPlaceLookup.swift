//
//  RichPlaceLookup.swift
//  Conduit
//
//  What Apple Maps knows about a card's places, looked up on this iPhone
//  when the card is drawn: the place itself (name, where, address, phone,
//  website, category), travel time from the user, routes, and the map
//  pictures chat rows show. Hermes' card only says which place it means;
//  nothing here comes from the model. Lookups are cached for a while, so a
//  card scrolled past again doesn't ask Apple again, and a chat opened
//  tomorrow looks everything up fresh.
//

import CoreLocation
import MapKit
import UIKit

/// A card's place as Apple Maps found it, or where Hermes said it is when
/// Apple Maps has nothing there.
final class RichPlaceMatch {
    let item: MKMapItem
    let coordinate: CLLocationCoordinate2D
    let name: String
    /// Found in Apple Maps: the details below are Apple's. False means a
    /// pin at the coordinates Hermes gave, with no details.
    let isVerified: Bool
    let address: String?
    let phone: String?
    let website: URL?
    let category: MKPointOfInterestCategory?

    init(item: MKMapItem, fallbackName: String, isVerified: Bool) {
        self.item = item
        coordinate = item.placemark.coordinate
        let appleName = isVerified ? MapsText.cleanOrNil(item.name, limit: 120) : nil
        name = appleName ?? fallbackName
        self.isVerified = isVerified
        address = isVerified ? Self.address(item.placemark) : nil
        phone = isVerified ? MapsText.cleanOrNil(item.phoneNumber, limit: 40) : nil
        if isVerified, let url = item.url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            website = url
        } else {
            website = nil
        }
        category = isVerified ? item.pointOfInterestCategory : nil
        if item.name == nil || !isVerified { item.name = name }
    }

    static func address(_ placemark: CLPlacemark) -> String? {
        let street = [placemark.subThoroughfare, placemark.thoroughfare].compactMap { MapsText.cleanOrNil($0, limit: 100) }
            .joined(separator: " ")
        let town = MapsText.cleanOrNil(placemark.locality, limit: 60) ?? ""
        let parts = [street, town].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    var telURL: URL? {
        guard let phone else { return nil }
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        return digits.isEmpty ? nil : URL(string: "tel:\(digits)")
    }

    /// A symbol for the kind of place.
    var symbol: String {
        guard let category else { return isVerified ? "mappin.circle.fill" : "mappin" }
        switch category {
        case .restaurant: return "fork.knife"
        case .cafe, .bakery: return "cup.and.saucer.fill"
        case .nightlife, .brewery, .winery: return "wineglass.fill"
        case .hotel: return "bed.double.fill"
        case .museum: return "building.columns.fill"
        case .theater, .movieTheater: return "theatermasks.fill"
        case .park, .nationalPark, .beach: return "tree.fill"
        case .store, .foodMarket: return "bag.fill"
        case .pharmacy: return "cross.case.fill"
        case .hospital: return "cross.fill"
        case .airport: return "airplane"
        case .publicTransport: return "tram.fill"
        case .gasStation, .evCharger: return "fuelpump.fill"
        case .parking: return "parkingsign"
        case .fitnessCenter: return "dumbbell.fill"
        case .school, .university, .library: return "book.fill"
        default: return "mappin.circle.fill"
        }
    }
}

@MainActor
enum RichPlaceLookup {
    static let deadline: TimeInterval = 8
    /// How close Apple Maps' match must be to where Hermes said the place is.
    static let matchRadius: CLLocationDistance = 250
    private static let foundFor: TimeInterval = 60 * 60
    private static let missingFor: TimeInterval = 10 * 60
    private static let maxEntries = 300

    private struct Entry {
        let match: RichPlaceMatch?
        let at: Date
    }

    private static var cache: [String: Entry] = [:]
    private static var running: [String: Task<RichPlaceMatch?, Never>] = [:]

    /// The place as Apple Maps knows it; nil when it can't be found and
    /// Hermes gave no coordinates either.
    static func match(_ place: RichPlace) async -> RichPlaceMatch? {
        let key = place.lookupKey
        if let entry = cache[key],
           Date().timeIntervalSince(entry.at) < (entry.match?.isVerified == true ? foundFor : missingFor) {
            return entry.match
        }
        if let task = running[key] { return await task.value }
        let task = Task { @MainActor in
            await MapsDeadline.run(after: deadline, fallback: unverified(place)) { await find(place) }
        }
        running[key] = task
        let match = await task.value
        running[key] = nil
        if cache.count >= maxEntries, let oldest = cache.min(by: { $0.value.at < $1.value.at })?.key {
            cache[oldest] = nil
        }
        cache[key] = Entry(match: match, at: Date())
        return match
    }

    /// The places of a card, in order; a place that can't be found is nil.
    static func matches(_ places: [RichPlace]) async -> [RichPlaceMatch?] {
        var found: [RichPlaceMatch?] = []
        // One at a time: MapKit allows about 50 lookups a minute.
        for place in places { found.append(await match(place)) }
        return found
    }

    private static func find(_ place: RichPlace) async -> RichPlaceMatch? {
        if let id = place.placeID, #available(iOS 18.0, *), let item = try? await MapsKit.item(placeID: id) {
            return RichPlaceMatch(item: item, fallbackName: place.name, isVerified: true)
        }
        let given = place.givenCoordinate
        let query = [place.name, place.address].compactMap { $0 }.joined(separator: ", ")
        let centre = given ?? CLLocationManager().location?.coordinate
        let items = (try? await MapsKit.search(query, near: centre, span: given == nil ? MapsEngine.resolveSpan : 2_000)) ?? []
        if let given {
            let target = CLLocation(latitude: given.latitude, longitude: given.longitude)
            let nearest = items
                .map { item -> (MKMapItem, CLLocationDistance) in
                    let found = MapDatum.fromMap(item.placemark.coordinate)
                    return (item, CLLocation(latitude: found.latitude, longitude: found.longitude).distance(from: target))
                }
                .filter { $0.1 <= matchRadius }
                .min { $0.1 < $1.1 }?.0
            if let nearest { return RichPlaceMatch(item: nearest, fallbackName: place.name, isVerified: true) }
            return unverified(place)
        }
        guard let first = items.first else { return nil }
        return RichPlaceMatch(item: first, fallbackName: place.name, isVerified: true)
    }

    /// A pin where Hermes said the place is, with no Apple details.
    private static func unverified(_ place: RichPlace) -> RichPlaceMatch? {
        guard let given = place.givenCoordinate, CLLocationCoordinate2DIsValid(given) else { return nil }
        return RichPlaceMatch(item: MapsKit.item(at: MapDatum.toMap(given), name: place.name), fallbackName: place.name, isVerified: false)
    }

    // MARK: Travel

    /// Whether the user's position may be used for travel times and routes
    /// drawn on this phone. Nothing about it leaves the phone.
    static var canUseLocation: Bool {
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return true
        default: return false
        }
    }

    private static var travelTimes: [String: (seconds: TimeInterval, at: Date)] = [:]
    private static let travelTimeFor: TimeInterval = 2 * 60

    /// How long getting to `match` from where the user is takes now.
    static func travelTime(to match: RichPlaceMatch, mode: RichCard.TravelMode) async -> TimeInterval? {
        guard canUseLocation, CLLocationCoordinate2DIsValid(match.coordinate) else { return nil }
        let key = "\(match.coordinate.latitude),\(match.coordinate.longitude),\(mode.rawValue)"
        if let known = travelTimes[key], Date().timeIntervalSince(known.at) < travelTimeFor { return known.seconds }
        let request = MKDirections.Request()
        request.source = .forCurrentLocation()
        request.destination = match.item
        request.transportType = transportType(mode)
        let seconds = await MapsDeadline.run(after: deadline, fallback: nil as TimeInterval?) {
            (try? await MapsKit.eta(request))?.expectedTravelTime
        }
        if let seconds {
            if travelTimes.count >= maxEntries { travelTimes.removeAll() }
            travelTimes[key] = (seconds, Date())
        }
        return seconds
    }

    /// A route between two places, or from the user when `from` is nil.
    static func route(from: RichPlaceMatch?, to: RichPlaceMatch, mode: RichCard.TravelMode) async -> MKRoute? {
        guard from != nil || canUseLocation else { return nil }
        let request = MKDirections.Request()
        request.source = from?.item ?? .forCurrentLocation()
        request.destination = to.item
        request.transportType = transportType(mode)
        request.requestsAlternateRoutes = false
        return await MapsDeadline.run(after: deadline, fallback: nil as MKRoute?) {
            (try? await MapsKit.routes(request))?.first
        }
    }

    static func transportType(_ mode: RichCard.TravelMode) -> MKDirectionsTransportType {
        switch mode {
        case .driving: return .automobile
        case .walking: return .walking
        case .transit: return .transit
        // No route where Maps has no bike directions: never walking's time
        // and line under the bicycle.
        case .cycling: return .cycling
        }
    }

    static func directionsMode(_ mode: RichCard.TravelMode) -> String {
        switch mode {
        case .driving: return MKLaunchOptionsDirectionsModeDriving
        case .walking: return MKLaunchOptionsDirectionsModeWalking
        case .transit: return MKLaunchOptionsDirectionsModeTransit
        case .cycling: return MKLaunchOptionsDirectionsModeCycling
        }
    }

    /// Opens Apple Maps with directions there; the user tapped, so Conduit
    /// is in front.
    static func openDirections(to match: RichPlaceMatch, mode: RichCard.TravelMode) {
        match.item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: directionsMode(mode)])
    }

    static func openInMaps(_ match: RichPlaceMatch) {
        match.item.openInMaps(launchOptions: nil)
    }
}

// MARK: - Map pictures

/// A still map of a card's places (and route) for chat rows: a picture
/// scrolls for free where a live map wouldn't. Tapping opens the live map.
@MainActor
enum RichMapSnapshot {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 40
        return cache
    }()

    /// Tells routes apart for the cache: their points and the area they cover.
    static func routeKey(_ route: MKPolyline?) -> String {
        guard let route else { return "-" }
        let rect = route.boundingMapRect
        return "\(route.pointCount)@\(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.size.width)),\(Int(rect.size.height))"
    }

    static func image(coordinates: [CLLocationCoordinate2D], route: MKPolyline?, size: CGSize,
                      dark: Bool, accent: UIColor) async -> UIImage? {
        guard !coordinates.isEmpty, size.width > 1, size.height > 1 else { return nil }
        let points = coordinates.map { "\($0.latitude),\($0.longitude)" }.joined(separator: ";")
        let key = "\(points)|\(routeKey(route))|\(Int(size.width))x\(Int(size.height))|\(dark)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let options = MKMapSnapshotter.Options()
        options.region = region(fitting: coordinates, route: route)
        options.size = size
        options.traitCollection = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        options.pointOfInterestFilter = .includingAll
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        let image = draw(snapshot, coordinates: coordinates, route: route, accent: accent)
        cache.setObject(image, forKey: key)
        return image
    }

    static func region(fitting coordinates: [CLLocationCoordinate2D], route: MKPolyline?) -> MKCoordinateRegion {
        var rect = MKMapRect.null
        for coordinate in coordinates {
            let point = MKMapPoint(coordinate)
            rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        if let route { rect = rect.union(route.boundingMapRect) }
        // One place: a street-level view around it.
        let minimum = MKMapPointsPerMeterAtLatitude(coordinates[0].latitude) * 600
        if rect.size.width < minimum, rect.size.height < minimum {
            let centre = MKMapPoint(x: rect.midX, y: rect.midY)
            rect = MKMapRect(x: centre.x - minimum / 2, y: centre.y - minimum / 2, width: minimum, height: minimum)
        }
        var region = MKCoordinateRegion(rect.insetBy(dx: -rect.size.width * 0.25, dy: -rect.size.height * 0.3))
        region.span.latitudeDelta = min(max(region.span.latitudeDelta, 0.002), 170)
        region.span.longitudeDelta = min(max(region.span.longitudeDelta, 0.002), 350)
        return region
    }

    private static func draw(_ snapshot: MKMapSnapshotter.Snapshot, coordinates: [CLLocationCoordinate2D],
                             route: MKPolyline?, accent: UIColor) -> UIImage {
        let base = snapshot.image
        let format = UIGraphicsImageRendererFormat()
        format.scale = base.scale
        return UIGraphicsImageRenderer(size: base.size, format: format).image { context in
            base.draw(at: .zero)
            let cg = context.cgContext
            if let route, route.pointCount > 1 {
                let points = route.points()
                cg.setLineCap(.round)
                cg.setLineJoin(.round)
                cg.beginPath()
                for index in 0..<route.pointCount {
                    let point = snapshot.point(for: points[index].coordinate)
                    if index == 0 { cg.move(to: point) } else { cg.addLine(to: point) }
                }
                cg.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor)
                cg.setLineWidth(7)
                cg.strokePath()
                cg.beginPath()
                for index in 0..<route.pointCount {
                    let point = snapshot.point(for: points[index].coordinate)
                    if index == 0 { cg.move(to: point) } else { cg.addLine(to: point) }
                }
                cg.setStrokeColor(accent.cgColor)
                cg.setLineWidth(4)
                cg.strokePath()
            }
            for (index, coordinate) in coordinates.enumerated() {
                let centre = snapshot.point(for: coordinate)
                let radius: CGFloat = coordinates.count > 1 ? 11 : 9
                let circle = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
                cg.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: UIColor.black.withAlphaComponent(0.3).cgColor)
                cg.setFillColor(UIColor.white.cgColor)
                cg.fillEllipse(in: circle.insetBy(dx: -2, dy: -2))
                cg.setShadow(offset: .zero, blur: 0, color: nil)
                cg.setFillColor(accent.cgColor)
                cg.fillEllipse(in: circle)
                guard coordinates.count > 1 else { continue }
                let label = "\(index + 1)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 12, weight: .bold),
                    .foregroundColor: UIColor.white,
                ]
                let textSize = label.size(withAttributes: attributes)
                label.draw(at: CGPoint(x: centre.x - textSize.width / 2, y: centre.y - textSize.height / 2), withAttributes: attributes)
            }
        }
    }
}
