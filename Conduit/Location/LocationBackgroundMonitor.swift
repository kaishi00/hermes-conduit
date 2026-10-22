//
//  LocationBackgroundMonitor.swift
//  Conduit
//
//  The low-power signals behind "in the background" (Always permission):
//  saved places as CLMonitor circular conditions (prompt arrive and leave),
//  visits, and significant moves (only above Places precision). All three
//  relaunch Conduit in the background without the `location` background
//  mode, so they are set up at launch, not in a scene. Also the APNs token
//  for the agent's on-demand locate (the Location Push extension), and the
//  movement check while a voice call runs (When In Use is enough there:
//  the call keeps Conduit running).
//

import CoreLocation
import CryptoKit
import Foundation
import OSLog

@MainActor
final class LocationBackgroundMonitor: NSObject, CLLocationManagerDelegate {
    /// Letters and digits only: CoreLocation aborts the app on any other
    /// character ("Monitor name is not valid").
    nonisolated static let monitorName = "conduitSavedPlaces"
    /// What the monitor was last given, so a launch doesn't re-add all.
    static let monitoredDigestKey = "conduit.location.monitoredPlaces.v1"
    static let callMoveDistance: CLLocationDistance = 200

    private let manager = CLLocationManager()
    private var callManager: CLLocationManager?
    private var monitor: CLMonitor?
    private var eventsTask: Task<Void, Never>?
    private var configuring: Task<Void, Never>?
    private var visitsOn = false
    private var significantOn = false
    private var pushesOn = false
    /// Whether this launch has said if there's a location push token: the
    /// first configure always does, even with pushes off (notifier #287).
    private var pushesReported = false

    /// A saved place's state: inside or not, and when.
    var placeStateChanged: ((_ placeID: String, _ inside: Bool, _ at: Date) -> Void)?
    var visited: ((CLVisit) -> Void)?
    var movedSignificantly: ((CLLocation) -> Void)?
    var movedDuringCall: ((CLLocation) -> Void)?
    var locationPushToken: ((String?) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    /// Starts or stops each signal for what the user chose. Runs at every
    /// launch while background sharing is on.
    func configure(settings: LocationSharingSettings, places: [LocationSavedPlace], bound: Bool) {
        let previous = configuring
        configuring = Task { @MainActor [weak self] in
            await previous?.value
            await self?.apply(settings: settings, places: places, bound: bound)
        }
    }

    private func apply(settings: LocationSharingSettings, places: [LocationSavedPlace], bound: Bool) async {
        let always = manager.authorizationStatus == .authorizedAlways
        let on = bound && settings.background && always
        let approximate = manager.accuracyAuthorization == .reducedAccuracy

        if on, !visitsOn {
            manager.startMonitoringVisits()
            visitsOn = true
        } else if !on, visitsOn {
            manager.stopMonitoringVisits()
            visitsOn = false
        }
        // At Places only, the saved places say all there is to say.
        let wantsSignificant = on && settings.backgroundPrecision != .places
        if wantsSignificant, !significantOn {
            manager.startMonitoringSignificantLocationChanges()
            significantOn = true
        } else if !wantsSignificant, significantOn {
            manager.stopMonitoringSignificantLocationChanges()
            significantOn = false
        }
        // Geofences need precise location.
        await syncPlaces(on && !approximate ? places : [])
        setLocationPushes(on)
    }

    // MARK: Saved places

    private func syncPlaces(_ places: [LocationSavedPlace]) async {
        // Only a hash goes in UserDefaults (which is backed up): the saved
        // places' coordinates stay in the backup-excluded config.json.
        let digest = Self.monitoredDigest(places)
        if places.isEmpty, monitor == nil, UserDefaults.standard.string(forKey: Self.monitoredDigestKey) == nil { return }
        let monitor = await placesMonitor()
        if UserDefaults.standard.string(forKey: Self.monitoredDigestKey) != digest {
            for identifier in await monitor.identifiers {
                await monitor.remove(identifier)
            }
            for place in places.prefix(LocationSavedPlace.maxCount) {
                let condition = CLMonitor.CircularGeographicCondition(center: place.coordinate, radius: place.radius)
                await monitor.add(condition, identifier: place.id)
            }
            if places.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.monitoredDigestKey)
            } else {
                UserDefaults.standard.set(digest, forKey: Self.monitoredDigestKey)
            }
        }
    }

    /// SHA-256 of what the monitor watches, to tell when it changed.
    nonisolated static func monitoredDigest(_ places: [LocationSavedPlace]) -> String {
        let plain = places.prefix(LocationSavedPlace.maxCount)
            .map { "\($0.id)@\($0.latitude),\($0.longitude),\($0.radius)" }
            .joined(separator: ";")
        return SHA256.hash(data: Data(plain.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The one monitor, opened by name so a background relaunch gets the
    /// events that woke it.
    private func placesMonitor() async -> CLMonitor {
        if let monitor { return monitor }
        let created = await CLMonitor(Self.monitorName)
        monitor = created
        eventsTask = Task { @MainActor [weak self] in
            do {
                for try await event in await created.events {
                    self?.handle(event)
                }
            } catch {
                LocationSyncEngine.log.info("Saved-place monitor stopped: \(LogRedaction.message(error), privacy: .public)")
            }
        }
        return created
    }

    private func handle(_ event: CLMonitor.Event) {
        switch event.state {
        case .satisfied: placeStateChanged?(event.identifier, true, event.date)
        case .unsatisfied: placeStateChanged?(event.identifier, false, event.date)
        default: break
        }
    }

    // MARK: On-demand locate

    private func setLocationPushes(_ on: Bool) {
        guard on != pushesOn || !pushesReported else { return }
        pushesReported = true
        pushesOn = on
        if on {
            manager.startMonitoringLocationPushes { [weak self] token, error in
                let hex = token.map { $0.map { String(format: "%02x", $0) }.joined() }
                if let error {
                    LocationSyncEngine.log.info("Location pushes unavailable: \(LogRedaction.message(error), privacy: .public)")
                }
                Task { @MainActor in
                    guard let self, self.pushesOn else { return }
                    self.locationPushToken?(hex)
                }
            }
        } else {
            manager.stopMonitoringLocationPushes()
            locationPushToken?(nil)
        }
    }

    // MARK: Calls

    /// Watches for a move of more than 200 m while a voice call runs.
    func startCallUpdates() {
        guard callManager == nil else { return }
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        let callManager = CLLocationManager()
        callManager.delegate = self
        callManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        callManager.distanceFilter = Self.callMoveDistance
        // A pause wouldn't resume on its own; the call ends the updates.
        callManager.pausesLocationUpdatesAutomatically = false
        callManager.startUpdatingLocation()
        self.callManager = callManager
    }

    func stopCallUpdates() {
        callManager?.stopUpdatingLocation()
        callManager?.delegate = nil
        callManager = nil
    }

    // MARK: Delegate

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        Task { @MainActor in self.visited?(visit) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            if manager === self.callManager {
                self.movedDuringCall?(location)
            } else if manager === self.manager {
                self.movedSignificantly?(location)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
