//
//  MapDatum.swift
//  Conduit
//
//  Apple Maps in mainland China works in GCJ-02, the shifted datum Chinese
//  law requires: its tiles, search results and routes sit a few hundred
//  metres from the WGS-84 that Core Location measures (#1122). Conduit
//  keeps saved places and fixes in WGS-84 and converts where MapKit is on
//  the other side: what MapKit hands back is read with `fromMap`, what is
//  drawn or routed in MapKit goes through `toMap`. Outside mainland China
//  (MapDatumRegion) both are the identity.
//
//  Shared with the Location Push extension, which routes saved places.
//

import CoreLocation
import Foundation

enum MapDatum {
    /// A WGS-84 coordinate as Apple Maps places it.
    static func toMap(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard isShifted(coordinate) else { return coordinate }
        let shift = offset(coordinate)
        return CLLocationCoordinate2D(latitude: coordinate.latitude + shift.latitude,
                                      longitude: coordinate.longitude + shift.longitude)
    }

    /// A coordinate read from Apple Maps (a search result, a map item) in WGS-84.
    static func fromMap(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return coordinate }
        // The shift has no closed inverse: step back until the forward shift lands
        // on the map's point. It converges to well under a millimetre in a few steps.
        var wgs = coordinate
        for _ in 0..<10 {
            let shift = offset(wgs)
            let errorLatitude = wgs.latitude + shift.latitude - coordinate.latitude
            let errorLongitude = wgs.longitude + shift.longitude - coordinate.longitude
            wgs = CLLocationCoordinate2D(latitude: wgs.latitude - errorLatitude, longitude: wgs.longitude - errorLongitude)
            if abs(errorLatitude) < 1e-9 && abs(errorLongitude) < 1e-9 { break }
        }
        // Gate on the WGS-84 point, as toMap does, so a point near a border round trips.
        return isShifted(wgs) ? wgs : coordinate
    }

    /// Whether Apple Maps shifts this point: inside mainland China (coast and
    /// islands included), not Hong Kong, Macau, Taiwan, Kinmen or Matsu. The
    /// land border is simplified to about 2 km (MapDatumRegion).
    static func isShifted(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard CLLocationCoordinate2DIsValid(coordinate),
              outline.contains(coordinate) else { return false }
        if islands.contains(where: { $0.contains(coordinate) }) { return false }
        return !excluded.contains { $0.contains(coordinate) }
    }

    private struct Ring {
        let longitudes: [Double]
        let latitudes: [Double]
        let west, east, south, north: Double

        /// "longitude,latitude" pairs separated by white space.
        init(_ pairs: String) {
            let points = pairs.split(whereSeparator: \.isWhitespace).compactMap { pair -> (Double, Double)? in
                let parts = pair.split(separator: ",")
                guard parts.count == 2, let longitude = Double(parts[0]), let latitude = Double(parts[1]) else { return nil }
                return (longitude, latitude)
            }
            self.init(longitudes: points.map(\.0), latitudes: points.map(\.1))
        }

        init(longitudes: [Double], latitudes: [Double]) {
            self.longitudes = longitudes
            self.latitudes = latitudes
            west = longitudes.min() ?? 0
            east = longitudes.max() ?? 0
            south = latitudes.min() ?? 0
            north = latitudes.max() ?? 0
        }

        /// Even-odd ray casting; a box check first keeps most calls cheap.
        func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
            let x = coordinate.longitude, y = coordinate.latitude
            guard x >= west, x <= east, y >= south, y <= north else { return false }
            var inside = false
            var j = longitudes.count - 1
            for i in longitudes.indices {
                let (xi, yi, xj, yj) = (longitudes[i], latitudes[i], longitudes[j], latitudes[j])
                if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi) + xi { inside.toggle() }
                j = i
            }
            return inside
        }
    }

    private static let outline = Ring(MapDatumRegion.mainland)
    private static let excluded = MapDatumRegion.excluded.map(Ring.init)
    /// Taiwan's islands a few km off Xiamen and Fuzhou, inside the sea line.
    private static let islands = [
        Ring(longitudes: [118.22, 118.50, 118.50, 118.22], latitudes: [24.38, 24.38, 24.53, 24.53]), // Kinmen
        Ring(longitudes: [119.85, 120.55, 120.55, 119.85], latitudes: [25.90, 25.90, 26.40, 26.40]), // Matsu
    ]

    private static let semiMajorAxis = 6_378_245.0
    private static let eccentricitySquared = 0.00669342162296594323

    /// The GCJ-02 shift at a WGS-84 point, in degrees.
    private static func offset(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let x = coordinate.longitude - 105
        let y = coordinate.latitude - 35
        let latitude = coordinate.latitude * .pi / 180
        let magic = 1 - eccentricitySquared * sin(latitude) * sin(latitude)
        let rootMagic = magic.squareRoot()
        let shiftLatitude = latitudeShift(x, y) * 180
            / ((semiMajorAxis * (1 - eccentricitySquared)) / (magic * rootMagic) * .pi)
        let shiftLongitude = longitudeShift(x, y) * 180 / (semiMajorAxis / rootMagic * cos(latitude) * .pi)
        return CLLocationCoordinate2D(latitude: shiftLatitude, longitude: shiftLongitude)
    }

    private static func latitudeShift(_ x: Double, _ y: Double) -> Double {
        var shift = -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * abs(x).squareRoot()
        shift += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        shift += (20 * sin(y * .pi) + 40 * sin(y / 3 * .pi)) * 2 / 3
        shift += (160 * sin(y / 12 * .pi) + 320 * sin(y * .pi / 30)) * 2 / 3
        return shift
    }

    private static func longitudeShift(_ x: Double, _ y: Double) -> Double {
        var shift = 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * abs(x).squareRoot()
        shift += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        shift += (20 * sin(x * .pi) + 40 * sin(x / 3 * .pi)) * 2 / 3
        shift += (150 * sin(x / 12 * .pi) + 300 * sin(x / 30 * .pi)) * 2 / 3
        return shift
    }
}
