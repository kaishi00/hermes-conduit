//
//  PulseSpotWatcher.swift
//  Conduit
//
//  Walking past (LocationSpots): the shops Pulse asked this iPhone to watch.
//  For each watch it searches Apple Maps around where the phone is, keeps
//  the nearest few, and watches them with a second CLMonitor, sized for how
//  the phone moves now (a watch has a walking and a driving circle). Saved
//  places come first in iOS's twenty conditions: shops get what's left, at
//  most ten. The first state of a shop is where the phone already is, not
//  an entry. Shops' coordinates stay on this phone (spots.json, excluded
//  from backups); the host hears only a name when the phone comes near one.
//

import CoreLocation
import Foundation
import MapKit

@MainActor
final class PulseSpotWatcher {
    /// Letters and digits only: CoreLocation aborts the app on any other
    /// character ("Monitor name is not valid").
    nonisolated static let monitorName = "conduitPulseSpots"
    /// iOS watches at most this many conditions for an app, all monitors.
    static let conditionLimit = 20
    static let maxSpots = 10
    static let perWatch = 3
    /// Searched again after moving this far from the last search, at most
    /// this often (or at once when the phone starts or stops driving).
    static let searchAgainDistance: CLLocationDistance = 1_000
    static let searchAgainInterval: TimeInterval = 30 * 60
    /// A change between walking and driving searches again, but not more
    /// often than this.
    static let modeChangeInterval: TimeInterval = 5 * 60
    /// Faster than this is driving: the wider circles.
    static let drivingSpeed: CLLocationSpeed = 5
    /// A search spans at least this, and twice the circle it's for.
    static let minimumSpan: CLLocationDistance = 2_000

    private(set) var state: PulseSpotState
    /// How many shops it can watch now (0 while it may not watch any).
    private(set) var room = 0
    /// The phone came near a shop: the controller takes a fix and sends it.
    var entered: ((PulseSpotState.Spot, Date) -> Void)?
    /// Private saved places: no shop inside one is watched.
    var privatePlaces: () -> [LocationSavedPlace] = { [] }
    var now: () -> Date = Date.init
    /// Asks iOS for time to finish a search in the background; returns
    /// what ends it.
    var keepRunning: () -> () -> Void = { {} }
    var search: (String, CLLocationCoordinate2D, CLLocationDistance) async throws -> [MKMapItem] = { query, centre, span in
        try await MapsKit.search(query, near: centre, span: span)
    }

    /// Whether a monitor was left with shops in it, so turning off empties
    /// it even before it's opened this launch.
    var hasMonitor: () -> Bool = { UserDefaults.standard.bool(forKey: PulseSpotWatcher.monitoredKey) }

    private let save: (PulseSpotState) -> Void
    private var monitor: CLMonitor?
    private var eventsTask: Task<Void, Never>?
    private var work: Task<Void, Never>?

    init(state: PulseSpotState = LocationSharedStore.readSpots(),
         save: @escaping (PulseSpotState) -> Void = { LocationSharedStore.saveSpots($0) }) {
        self.state = state
        self.save = save
    }

    var watching: Bool { room > 0 }

    /// Whether shops may be watched (background sharing at Precise, Always
    /// and precise location, not paused) and how many saved places iOS
    /// watches already. Off, everything is forgotten.
    func configure(enabled: Bool, savedPlaces: Int) {
        room = enabled ? max(0, min(Self.maxSpots, Self.conditionLimit - min(savedPlaces, Self.conditionLimit))) : 0
        guard watching else {
            if state != PulseSpotState() || monitor != nil || hasMonitor() {
                state = PulseSpotState()
                save(state)
                queue { await $0.syncMonitor() }
            }
            return
        }
        if state.spots.count > room {
            state.spots = Array(state.spots.prefix(room))
            state.inside = state.inside.filter { id, _ in state.spots.contains { $0.id == id } }
            save(state)
        }
        queue { await $0.syncMonitor() }
    }

    /// The host's list, from the reply to a batch: what's no longer listed
    /// stops being watched, and new watches are searched near `location`.
    func replied(_ watches: [LocationSpotWatch], near location: CLLocation?) {
        guard watching else { return }
        let live = watches.filter { $0.until > now() }
        guard live != state.watches else {
            // The same list: searched again only when the last search found nothing and is old enough.
            if !live.isEmpty, state.spots.isEmpty, searchDue {
                let centre = location ?? state.searchCentre
                queue { await $0.searchAgain(near: centre) }
            }
            return
        }
        let added = Set(live.map(\.id)).subtracting(state.watches.map(\.id))
        // The same watch with other words: its shops are searched again.
        let requeried = live.contains { watch in state.watches.contains { $0.id == watch.id && $0.query != watch.query } }
        state.watches = live
        dropSpotsWithoutWatches()
        save(state)
        if !added.isEmpty || requeried || resized {
            let centre = location ?? state.searchCentre
            queue { await $0.searchAgain(near: centre) }
        } else {
            queue { await $0.syncMonitor() }
        }
    }

    private var searchDue: Bool {
        state.searchedAt.map { now().timeIntervalSince($0) >= Self.searchAgainInterval } ?? true
    }

    /// Whether a watch's circle changed since its shops were searched.
    private var resized: Bool {
        state.spots.contains { spot in
            state.watches.first { $0.id == spot.watchID }.map { $0.radius(driving: state.driving) != spot.radius } ?? false
        }
    }

    /// A fix from a visit, a significant move or a send: searched again when
    /// the phone moved far enough since the last search, or started or
    /// stopped driving.
    func moved(_ location: CLLocation) {
        guard watching, !state.watches.isEmpty else { return }
        // A fix with no speed (a visit, most significant moves) keeps the mode it had.
        let driving = location.speed >= 0 ? location.speed >= Self.drivingSpeed : state.driving
        let far = state.searchCentre.map { $0.distance(from: location) > Self.searchAgainDistance } ?? true
        let recent = state.searchedAt.map { now().timeIntervalSince($0) < Self.modeChangeInterval } ?? false
        if (driving != state.driving && !recent) || (far && searchDue) {
            state.driving = driving
            queue { await $0.searchAgain(near: location) }
        }
    }

    // MARK: Searching

    private func searchAgain(near location: CLLocation?) async {
        let done = keepRunning()
        defer { done() }
        expire()
        guard watching, let location else {
            await syncMonitor()
            return
        }
        let privates = privatePlaces()
        var nearest: [[PulseSpotState.Spot]] = []
        for watch in state.watches {
            let radius = watch.radius(driving: state.driving)
            let span = max(Self.minimumSpan, radius * 2)
            let items: [MKMapItem]
            do {
                items = try await search(watch.query, location.coordinate, span)
            } catch {
                LocationSyncEngine.log.info("Pulse spot search failed: \(LogRedaction.message(error), privacy: .public)")
                items = []
            }
            let found = items.compactMap { item -> PulseSpotState.Spot? in
                let coordinate = MapDatum.fromMap(item.placemark.coordinate)
                let shop = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                guard shop.distance(from: location) <= span / 2,
                      !privates.contains(where: { $0.distance(to: shop) <= $0.radius + radius }) else { return nil }
                return PulseSpotState.Spot(
                    id: "s" + LocationIDs.hex(bytes: 8), watchID: watch.id,
                    name: item.name ?? watch.query, latitude: coordinate.latitude, longitude: coordinate.longitude,
                    radius: radius)
            }
            nearest.append(Array(found.sorted { $0.location.distance(from: location) < $1.location.distance(from: location) }
                .prefix(Self.perWatch)))
        }
        // A watch dropped while Maps answered (Walking past turned off, or
        // a reply listing fewer) keeps none of its shops.
        guard watching else {
            await syncMonitor()
            return
        }
        let current = Set(state.watches.map(\.id))
        nearest = nearest.map { $0.filter { current.contains($0.watchID) } }
        // Round robin: each watch's nearest first, so one watch can't take the room.
        var spots: [PulseSpotState.Spot] = []
        for rank in 0..<Self.perWatch {
            for found in nearest where rank < found.count && spots.count < room {
                spots.append(found[rank])
            }
        }
        // A shop already watched keeps its id and what the phone knew of it,
        // each old one claimed once (Maps can list one shop twice).
        var unclaimed = state.spots
        state.spots = spots.map { spot in
            guard let index = unclaimed.firstIndex(where: {
                $0.watchID == spot.watchID && $0.name == spot.name && $0.radius == spot.radius
                    && $0.location.distance(from: spot.location) < 50
            }) else { return spot }
            return unclaimed.remove(at: index)
        }
        state.searchLatitude = location.coordinate.latitude
        state.searchLongitude = location.coordinate.longitude
        state.searchedAt = now()
        state.inside = state.inside.filter { id, _ in state.spots.contains { $0.id == id } }
        save(state)
        await syncMonitor()
    }

    private func expire() {
        let live = state.watches.filter { $0.until > now() }
        guard live != state.watches else { return }
        state.watches = live
        dropSpotsWithoutWatches()
        save(state)
    }

    private func dropSpotsWithoutWatches() {
        let ids = Set(state.watches.map(\.id))
        state.spots.removeAll { !ids.contains($0.watchID) }
        state.inside = state.inside.filter { id, _ in state.spots.contains { $0.id == id } }
    }

    // MARK: Monitor

    nonisolated static let monitoredKey = "conduit.location.pulseSpotsMonitored.v1"

    private func syncMonitor() async {
        expire()
        if state.spots.isEmpty, monitor == nil, !hasMonitor() { return }
        let monitor = await spotsMonitor()
        let wanted = Dictionary(state.spots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let current = await monitor.identifiers
        for identifier in current where wanted[identifier] == nil {
            await monitor.remove(identifier)
        }
        for spot in wanted.values where !current.contains(spot.id) {
            let condition = CLMonitor.CircularGeographicCondition(
                center: CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude), radius: spot.radius)
            await monitor.add(condition, identifier: spot.id)
        }
        UserDefaults.standard.set(!state.spots.isEmpty, forKey: Self.monitoredKey)
        // An empty monitor stays open, like the saved places' one: opening a
        // second CLMonitor by the same name while the first lives aborts.
    }

    /// The one monitor, opened by name so a background relaunch gets the
    /// events that woke it.
    private func spotsMonitor() async -> CLMonitor {
        if let monitor { return monitor }
        let created = await CLMonitor(Self.monitorName)
        monitor = created
        eventsTask = Task { @MainActor [weak self] in
            do {
                for try await event in await created.events {
                    self?.handle(identifier: event.identifier, state: event.state, at: event.date)
                }
            } catch {
                LocationSyncEngine.log.info("Pulse spot monitor stopped: \(LogRedaction.message(error), privacy: .public)")
            }
            // Its events ended: the next sync opens it again by name (this one
            // is released with this task) and adds the shops back.
            guard let self, self.monitor === created else { return }
            self.monitor = nil
            self.eventsTask = nil
        }
        return created
    }

    func handle(identifier: String, state condition: CLMonitor.Event.State, at date: Date) {
        let inside: Bool
        switch condition {
        case .satisfied: inside = true
        case .unsatisfied: inside = false
        default: return
        }
        guard let spot = state.spots.first(where: { $0.id == identifier }) else { return }
        let before = state.inside[identifier]
        guard before != inside else { return }
        state.inside[identifier] = inside
        save(state)
        guard before == false, inside, state.watches.contains(where: { $0.id == spot.watchID && $0.until > now() }) else { return }
        entered?(spot, date)
    }

    /// One change at a time, in order.
    private func queue(_ step: @escaping @MainActor (PulseSpotWatcher) async -> Void) {
        let previous = work
        work = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await step(self)
        }
    }
}
