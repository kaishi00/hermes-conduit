//
//  LocationFixProvider.swift
//  Conduit
//
//  One position when sharing needs one: a recent enough fix iOS already
//  has, else a single `requestLocation()`, never continuous updates. Also
//  asks for permission (When In Use for "while I'm talking to Hermes",
//  Always for "in the background") and turns a position into an area name
//  with Apple's geocoder, on the phone, so the host never calls one.
//

import CoreLocation
import Foundation
import UIKit

@MainActor
final class LocationFixProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: [UUID: CheckedContinuation<CLLocation?, Never>] = [:]
    /// What each waiting request asked for: the manager is set to the
    /// finest of them, so a coarse request can't weaken a precise one.
    private var wanted: [UUID: CLLocationAccuracy] = [:]
    private var requestInFlight = false
    private var cachedArea: (location: CLLocation, area: LocationArea)?

    /// Called when the user changes what Conduit may do.
    var authorizationChanged: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }
    var isApproximate: Bool { manager.accuracyAuthorization == .reducedAccuracy }
    var canLocate: Bool {
        manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
    }

    // MARK: Fixes

    /// A position at about `accuracy`, no older than `maxAge`, or nil when
    /// none comes within `timeout`.
    func currentFix(accuracy: CLLocationAccuracy, maxAge: TimeInterval = 60, timeout: Duration = .seconds(10)) async -> CLLocation? {
        guard canLocate else { return nil }
        if let known = manager.location, -known.timestamp.timeIntervalSinceNow <= maxAge,
           known.horizontalAccuracy >= 0, known.horizontalAccuracy <= Self.acceptableCachedAccuracy(for: accuracy) {
            return known
        }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiting[id] = continuation
            wanted[id] = accuracy
            applyFinestWanted()
            if !requestInFlight {
                requestInFlight = true
                manager.requestLocation()
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resume(id, with: nil)
            }
        }
    }

    /// How rough a fix iOS already has may be and still answer a request
    /// for `accuracy`: twice that for Precise (10 m asks get 20 m), and the
    /// usual Wi-Fi 65 m otherwise.
    nonisolated static func acceptableCachedAccuracy(for accuracy: CLLocationAccuracy) -> CLLocationAccuracy {
        min(max(accuracy, 65), 2 * accuracy)
    }

    private func applyFinestWanted() {
        guard let finest = wanted.values.min(), finest != manager.desiredAccuracy else { return }
        manager.desiredAccuracy = finest
    }

    static func desiredAccuracy(for precision: LocationPrecision) -> CLLocationAccuracy {
        switch precision {
        case .precise: return kCLLocationAccuracyNearestTenMeters
        // Places need to tell neighbouring places apart.
        case .places: return kCLLocationAccuracyHundredMeters
        case .area: return kCLLocationAccuracyHundredMeters
        }
    }

    /// One request gave up (its timeout). The rest keep the finest accuracy
    /// they need; with none left, the next request starts a new one.
    private func resume(_ id: UUID, with location: CLLocation?) {
        wanted.removeValue(forKey: id)
        waiting.removeValue(forKey: id)?.resume(returning: location)
        if waiting.isEmpty { requestInFlight = false }
        applyFinestWanted()
    }

    private func deliver(_ location: CLLocation?) {
        requestInFlight = false
        let all = waiting
        waiting = [:]
        wanted = [:]
        for continuation in all.values { continuation.resume(returning: location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in self.deliver(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.deliver(nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.authorizationChanged?() }
    }

    // MARK: Permission

    /// Asks for When In Use if iOS hasn't asked yet; the status after.
    func requestWhenInUse() async -> CLAuthorizationStatus {
        guard manager.authorizationStatus == .notDetermined else { return manager.authorizationStatus }
        manager.requestWhenInUseAuthorization()
        // Not asked yet, so iOS shows its prompt: wait for the answer.
        return await waitForAnswer(from: .notDetermined, promptCertain: true)
    }

    /// Asks for Always (after When In Use). iOS shows its prompt only once;
    /// after that the user changes it in the Settings app.
    func requestAlways() async -> CLAuthorizationStatus {
        let first = await requestWhenInUse()
        guard first == .authorizedWhenInUse else { return first }
        manager.requestAlwaysAuthorization()
        return await waitForAnswer(from: .authorizedWhenInUse)
    }

    /// Waits for the user's answer. If no prompt shows (iOS asked for
    /// Always before), Conduit stays active and the status doesn't change:
    /// give up soon, unless a prompt is certain.
    private func waitForAnswer(from initial: CLAuthorizationStatus, promptCertain: Bool = false) async -> CLAuthorizationStatus {
        let started = Date()
        while Date().timeIntervalSince(started) < 120 {
            try? await Task.sleep(for: .milliseconds(250))
            if manager.authorizationStatus != initial { return manager.authorizationStatus }
            if !promptCertain, Date().timeIntervalSince(started) > 1.5, UIApplication.shared.applicationState == .active {
                return manager.authorizationStatus
            }
        }
        return manager.authorizationStatus
    }

    // MARK: Area

    /// Neighbourhood, city, region and country, from Apple's geocoder; nil
    /// when it doesn't answer in time. Reused while the phone stays close.
    func area(for location: CLLocation, timeout: Duration = .milliseconds(1_500)) async -> LocationArea? {
        if let cachedArea, cachedArea.location.distance(from: location) < 300,
           abs(cachedArea.location.timestamp.timeIntervalSince(location.timestamp)) < 1_800 {
            return cachedArea.area
        }
        let geocoder = CLGeocoder()
        let found: LocationArea? = await withCheckedContinuation { continuation in
            let once = LocationOnce()
            geocoder.reverseGeocodeLocation(location) { placemarks, _ in
                let area = placemarks?.first.map(Self.area(from:))
                Task { @MainActor in once.run { continuation.resume(returning: area) } }
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                once.run {
                    geocoder.cancelGeocode()
                    continuation.resume(returning: nil)
                }
            }
        }
        if let found, !found.isEmpty { cachedArea = (location, found) }
        return found
    }

    nonisolated static func area(from placemark: CLPlacemark) -> LocationArea {
        LocationArea(
            name: placemark.subLocality ?? placemark.locality,
            locality: placemark.locality,
            region: placemark.administrativeArea,
            country: placemark.country,
            countryCode: placemark.isoCountryCode
        )
    }
}

/// Runs its body once: whichever of a result and a timeout comes first.
@MainActor
final class LocationOnce {
    private var done = false

    func run(_ body: () -> Void) {
        guard !done else { return }
        done = true
        body()
    }
}
