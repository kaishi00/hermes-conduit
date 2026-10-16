//
//  MapsNavigator.swift
//  Conduit
//
//  Opens Apple Maps with directions to a place: the live voice modes'
//  `maps` navigate action and Hermes' `conduit_maps` navigate (a Go
//  confirmation, PresentedScreens). On the car screen when CarPlay is
//  connected, on the phone when Conduit is in front, and otherwise behind a
//  notification the user taps: iOS opens another app only from the
//  foreground. Directions start from wherever the user is.
//

import CarPlay
import CoreLocation
import MapKit
import UIKit
import UserNotifications

@MainActor
enum MapsNavigator {
    enum Outcome: Equatable {
        case openedInCar(String)
        case opened(String)
        /// Conduit wasn't in front: a notification opens Maps on a tap.
        case notified(String)
        case failed(MapsFailure)
    }

    static let lookupDeadline: TimeInterval = 7
    nonisolated static let notificationIdentifier = "conduit.maps.navigate"
    nonisolated static let urlKey = "conduit_maps_url"

    /// Resolves `ref` and opens Apple Maps with `mode` directions there.
    static func open(_ ref: MapsPlaceRef, mode: MapsRequest.Mode, places: [LocationSavedPlace],
                     near hint: CLLocationCoordinate2D?) async -> Outcome {
        let item: MKMapItem
        switch await MapsEngine.destination(ref, places: places, near: hint, deadline: lookupDeadline) {
        case .failure(let failure): return .failed(failure)
        case .success(let found): item = found
        }
        let coordinate = item.placemark.coordinate
        let name = MapsText.cleanOrNil(item.name, limit: 120)
            ?? String(format: "%.4f, %.4f", locale: posix, coordinate.latitude, coordinate.longitude)
        guard let url = mapsURL(to: coordinate, mode: mode) else { return .failed(.failed("Apple Maps couldn't be opened.")) }
        if let scene = CarPlayMapsHandoff.scene, await openInCar(url, scene: scene) {
            return .openedInCar(name)
        }
        if UIApplication.shared.applicationState == .active {
            // In front, a notification wouldn't show: Maps opens or it failed.
            let opened = item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: directionsMode(mode)])
            return opened ? .opened(name) : .failed(.failed("Apple Maps couldn't be opened."))
        }
        guard await notify(name: name, url: url) else {
            return .failed(.failed("Conduit isn't in front and can't post notifications, so Maps couldn't be opened."))
        }
        return .notified(name)
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// An Apple Maps directions link. Cycling has no flag: Maps picks.
    static func mapsURL(to coordinate: CLLocationCoordinate2D, mode: MapsRequest.Mode) -> URL? {
        var components = URLComponents()
        components.scheme = "maps"
        components.host = ""
        var items = [URLQueryItem(name: "daddr", value: String(format: "%.6f,%.6f", locale: posix, coordinate.latitude, coordinate.longitude))]
        switch mode {
        case .driving: items.append(URLQueryItem(name: "dirflg", value: "d"))
        case .walking: items.append(URLQueryItem(name: "dirflg", value: "w"))
        case .transit: items.append(URLQueryItem(name: "dirflg", value: "r"))
        case .cycling: break
        }
        components.queryItems = items
        return components.url
    }

    static func directionsMode(_ mode: MapsRequest.Mode) -> String {
        switch mode {
        case .driving: return MKLaunchOptionsDirectionsModeDriving
        case .walking: return MKLaunchOptionsDirectionsModeWalking
        case .transit: return MKLaunchOptionsDirectionsModeTransit
        case .cycling: return MKLaunchOptionsDirectionsModeDefault
        }
    }

    /// The Maps link a tapped navigate notification carries, if it's one.
    nonisolated static func url(fromNotification userInfo: [AnyHashable: Any]) -> URL? {
        guard let text = userInfo[urlKey] as? String, let url = URL(string: text), url.scheme == "maps" else { return nil }
        return url
    }

    /// Whether the car screen opened it; a scene that never answers counts
    /// as no after a few seconds, and the phone is tried next.
    private static func openInCar(_ url: URL, scene: CPTemplateApplicationScene) async -> Bool {
        await MapsDeadline.run(after: 3, fallback: false) {
            await withCheckedContinuation { continuation in
                scene.open(url, options: nil) { opened in continuation.resume(returning: opened) }
            }
        }
    }

    /// Whether the notification was posted (notifications may be off).
    private static func notify(name: String, url: URL) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return false }
        let content = UNMutableNotificationContent()
        content.title = AppLocalization.string("Directions to \(name)")
        content.body = AppLocalization.string("Tap to open Apple Maps.")
        content.sound = .default
        content.userInfo = [urlKey: url.absoluteString]
        // One at a time: a newer destination replaces the last.
        let request = UNNotificationRequest(identifier: notificationIdentifier, content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }
}

/// The connected CarPlay scene, so Maps can open on the car screen.
@MainActor
enum CarPlayMapsHandoff {
    static weak var scene: CPTemplateApplicationScene?
}
