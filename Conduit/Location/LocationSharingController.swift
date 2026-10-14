//
//  LocationSharingController.swift
//  Conduit
//
//  Location sharing as a whole: the user's choices and saved places, when
//  a fix is taken (a message sent, a voice call, a saved place's arrive or
//  leave, a visit, a significant move), the latest unsent fix and events,
//  and sending them to the dashboard and profile sharing is bound to.
//
//  Nothing is taken or sent while a layer is off or sharing is paused.
//  A fix for a message never holds the message up for long: the send
//  waits at most `talkingWait`, and the fix goes on its own after that.
//

import CoreLocation
import Foundation
import OSLog
import UIKit

enum LocationSharingError: LocalizedError {
    case noDashboard
    case permissionDenied
    case unreadable

    var errorDescription: String? {
        switch self {
        case .noDashboard:
            return AppLocalization.string("Connect to your Hermes dashboard first.")
        case .permissionDenied:
            return AppLocalization.string("Conduit doesn't have permission to use your location. Allow it in the Settings app under Privacy & Security > Location Services > Conduit.")
        case .unreadable:
            return AppLocalization.string("Unlock your iPhone and try again.")
        }
    }
}

/// How long sending a message waits for its fix.
enum LocationTiming {
    static let talkingWait: Duration = .milliseconds(2_500)
    /// A Layer 2 fix when Conduit opens, if the last one is older than this.
    static let appFixInterval: TimeInterval = 15 * 60
    /// How often a running voice call is checked for having ended.
    static let callCheckInterval: Duration = .seconds(15)
}

@MainActor
final class LocationSharingController: ObservableObject {
    static let shared = LocationSharingController()
    /// The plugin keeps location (`location-sync`); it can also ask the
    /// phone for a fresh fix (`location-locate`). Never gated on a version.
    static let capability = "location-sync"
    static let locateCapability = "location-locate"
    static let maxPlaces = LocationSavedPlace.maxCount

    @Published private(set) var config: LocationSharedConfig
    /// The config file couldn't be read: before first unlock, or damaged.
    /// Nothing is taken, sent or saved over it until it reads again or the
    /// user starts over in Settings > Location.
    @Published private(set) var configUnreadable = false
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var approximate = false
    @Published private(set) var isSending = false

    let engine: LocationSyncEngine
    private(set) lazy var fixes: LocationFixProvider = {
        let provider = LocationFixProvider()
        provider.authorizationChanged = { [weak self] in self?.authorizationDidChange() }
        return provider
    }()
    private(set) lazy var monitor: LocationBackgroundMonitor = {
        let monitor = LocationBackgroundMonitor()
        monitor.placeStateChanged = { [weak self] id, inside, at in self?.placeStateChanged(id, inside: inside, at: at) }
        monitor.visited = { [weak self] visit in self?.visited(visit) }
        monitor.movedSignificantly = { [weak self] location in self?.movedSignificantly(location) }
        monitor.movedDuringCall = { [weak self] location in self?.movedDuringCall(location) }
        monitor.locationPushToken = { token in PushNotificationService.shared.updateLocationToken(token) }
        return monitor
    }()

    /// The connection to `binding`'s dashboard, or nil when there is none.
    /// AppState+Location supplies it; tests supply their own.
    var requestProvider: ((LocationBinding) async -> LocationSyncEngine.Request?)?
    var now: () -> Date = Date.init

    private var unsent: LocationUnsent
    private var sendChain: Task<Bool, Never>?
    private var callWatch: Task<Void, Never>?
    private var lastCallFix: CLLocation?
    private var activated = false

    init(engine: LocationSyncEngine? = nil, config: LocationSharedConfig? = nil, unsent: LocationUnsent? = nil) {
        self.engine = engine ?? LocationSyncEngine(deviceName: { UIDevice.current.name })
        if let config {
            self.config = config
        } else {
            switch LocationSharedStore.readConfig() {
            case .value(let stored): self.config = stored
            case .missing: self.config = LocationSharedConfig()
            case .unreadable:
                self.config = LocationSharedConfig()
                configUnreadable = true
            }
        }
        self.unsent = unsent ?? LocationSharedStore.readUnsent()
    }

    // MARK: State

    var settings: LocationSharingSettings { config.settings }
    var places: [LocationSavedPlace] { config.places }
    var binding: LocationBinding? { config.binding }

    func isPaused(at date: Date? = nil) -> Bool { settings.isPaused(at: date ?? now()) }

    /// Reads the config file again if it couldn't be read at launch.
    @discardableResult
    func readConfigIfNeeded() -> Bool {
        guard configUnreadable else { return true }
        switch LocationSharedStore.readConfig() {
        case .value(let stored):
            config = stored
            unsent = LocationSharedStore.readUnsent()
            configUnreadable = false
            return true
        case .missing:
            configUnreadable = false
            return true
        case .unreadable:
            return false
        }
    }

    /// Changes and stores the config, never over one that couldn't be
    /// read (that would replace the device id and saved places).
    private func save(_ change: (inout LocationSharedConfig) -> Void) {
        guard readConfigIfNeeded() else {
            LocationSyncEngine.log.error("Location config unreadable; not saving a change over it")
            return
        }
        change(&config)
        if !LocationSharedStore.saveConfig(config) {
            LocationSyncEngine.log.error("Couldn't write the location config")
        }
    }

    /// Settings > Location's way out of a config file that stays unreadable
    /// while the phone is unlocked: a fresh config, keeping the device id if
    /// it can still be found in the file, so the host's copy can be deleted.
    func startOver() {
        let deviceID = LocationSharedStore.salvageDeviceID()
        config = deviceID.map { LocationSharedConfig(deviceID: $0) } ?? LocationSharedConfig()
        configUnreadable = false
        if !LocationSharedStore.saveConfig(config) {
            LocationSyncEngine.log.error("Couldn't write the location config")
        }
        unsent = LocationUnsent()
        saveUnsent()
        voiceCallEnded()
        reconfigureMonitors()
    }

    private func saveUnsent() {
        LocationSharedStore.saveUnsent(unsent)
    }

    // MARK: Launch and foreground

    /// At launch, before any scene: the background signals must be set up
    /// again for the event that relaunched Conduit to arrive.
    func activateAtLaunch() {
        guard !activated else { return }
        activated = true
        guard readConfigIfNeeded(), config.binding != nil, settings.background else { return }
        refreshAuthorization()
        reconfigureMonitors()
    }

    /// Conduit came to the foreground: permissions may have changed in the
    /// Settings app, and anything unsent goes now.
    func appBecameActive() {
        guard readConfigIfNeeded() else { return }
        refreshAuthorization()
        guard config.binding != nil, settings.isOn else { return }
        reconfigureMonitors()
        if settings.shares(.app, at: now()), fixes.authorizationStatus == .authorizedAlways,
           (engine.state.lastFixSent.map { now().timeIntervalSince($0) > LocationTiming.appFixInterval } ?? true) {
            Task { await shareFix(source: .app) }
        } else if !unsent.isEmpty {
            Task { await flush() }
        }
    }

    /// Connected to a dashboard: send what's waiting if it's the bound one.
    func hostConnected() {
        guard readConfigIfNeeded(), config.binding != nil, !unsent.isEmpty else { return }
        Task { await flush() }
    }

    func refreshAuthorization() {
        authorization = fixes.authorizationStatus
        approximate = fixes.isApproximate
        if config.approximateOnly != approximate, config.binding != nil { save { $0.approximateOnly = approximate } }
    }

    private func authorizationDidChange() {
        refreshAuthorization()
        if config.binding != nil, settings.background { reconfigureMonitors() }
    }

    func reconfigureMonitors() {
        monitor.configure(settings: settings, places: places, bound: config.binding != nil && !configUnreadable)
    }

    // MARK: Layer 1: talking to Hermes

    /// Starts a fix before a message goes out and returns what the send
    /// waits for: the upload, or `talkingWait`, whichever is first. Nil
    /// (nothing to wait for) while this layer is off or paused.
    func shareBeforeSending(_ source: LocationFixSource = .message) -> Task<Void, Never>? {
        guard !configUnreadable, config.binding != nil, settings.shares(source, at: now()), fixes.canLocate else { return nil }
        let upload = Task { @MainActor in _ = await self.shareFix(source: source) }
        return Task { @MainActor in await Self.waitAtMost(LocationTiming.talkingWait, for: upload) }
    }

    /// A voice call started (Live Voice, Classic, CarPlay): one fix now,
    /// and another whenever the phone has moved 200 m, until `stillActive`
    /// says the call is over.
    ///
    /// Movement is followed only while Conduit is running (open, or kept
    /// alive by the call's `audio` background mode). Conduit deliberately
    /// doesn't declare the `location` UIBackgroundMode
    /// (designs/location-awareness.md, Layer 1 and the Info.plist notes): it
    /// draws extra App Review scrutiny, isn't needed for visits, regions or
    /// significant change, and Layer 1 is "while I'm talking", not
    /// tracking. Settings says so in its copy.
    func voiceCallStarted(stillActive: @escaping @MainActor () -> Bool) {
        guard callWatch == nil, !configUnreadable, config.binding != nil, settings.shares(.call, at: now()),
              fixes.canLocate else { return }
        lastCallFix = nil
        Task { await shareFix(source: .call) }
        monitor.startCallUpdates()
        callWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: LocationTiming.callCheckInterval)
                guard let self else { return }
                if !stillActive() || !self.settings.shares(.call, at: self.now()) {
                    self.voiceCallEnded()
                    return
                }
            }
        }
    }

    func voiceCallEnded() {
        callWatch?.cancel()
        callWatch = nil
        lastCallFix = nil
        monitor.stopCallUpdates()
    }

    private func movedDuringCall(_ location: CLLocation) {
        guard callWatch != nil, settings.shares(.call, at: now()) else { return }
        if let last = lastCallFix, last.distance(from: location) < LocationBackgroundMonitor.callMoveDistance { return }
        lastCallFix = location
        Task { await share(location, source: .call) }
    }

    // MARK: Layer 2: in the background

    private func placeStateChanged(_ placeID: String, inside: Bool, at date: Date) {
        guard readConfigIfNeeded(), let place = places.first(where: { $0.id == placeID }) else { return }
        let before = unsent.inside[placeID]
        unsent.inside[placeID] = inside
        saveUnsent()
        // The first answer for a place is where the phone is, not a move.
        guard let before, before != inside, settings.shares(.place, at: now()) else { return }
        let event = LocationPlaceEvent(kind: inside ? .arrive : .leave, placeID: place.id, at: date, isPrivate: place.isPrivate)
        Task { await shareFix(source: .place, events: [event]) }
    }

    private func visited(_ visit: CLVisit) {
        guard readConfigIfNeeded(), settings.shares(.visit, at: now()) else { return }
        let at = visit.departureDate == .distantFuture ? visit.arrivalDate : visit.departureDate
        let location = CLLocation(
            coordinate: visit.coordinate, altitude: 0, horizontalAccuracy: visit.horizontalAccuracy,
            verticalAccuracy: -1, timestamp: at == .distantPast ? now() : at
        )
        Task { await share(location, source: .visit) }
    }

    private func movedSignificantly(_ location: CLLocation) {
        guard readConfigIfNeeded(), settings.shares(.significant, at: now()) else { return }
        Task { await share(location, source: .significant) }
    }

    // MARK: Taking and sending

    /// Takes a fix for `source` (with any events) and sends it. True when
    /// the host has it.
    @discardableResult
    func shareFix(source: LocationFixSource, events: [LocationPlaceEvent] = []) async -> Bool {
        guard settings.shares(source, at: now()) else { return false }
        let precision = settings.precision(for: source)
        let location = await fixes.currentFix(
            accuracy: LocationFixProvider.desiredAccuracy(for: precision),
            maxAge: source.isTalking ? 30 : 120,
            timeout: source.isTalking ? .seconds(8) : .seconds(15)
        )
        return await share(location, source: source, events: events)
    }

    @discardableResult
    func share(_ location: CLLocation?, source: LocationFixSource, events: [LocationPlaceEvent] = []) async -> Bool {
        guard readConfigIfNeeded(), config.binding != nil, settings.shares(source, at: now()) else { return false }
        var record: LocationFixRecord?
        if let location {
            let precision = settings.precision(for: source)
            let area = precision == .places ? nil : await fixes.area(for: location)
            record = LocationFixRecord(source: source, raw: LocationRawFix(location), area: area)
        }
        guard record != nil || !events.isEmpty else { return false }
        unsent.keep(fix: record, events: events)
        saveUnsent()
        return await flush()
    }

    /// Sends the unsent fix and events (or just the sharing choices and
    /// places), one batch at a time.
    @discardableResult
    func flush(settingsOnly: Bool = false) async -> Bool {
        let previous = sendChain
        let task = Task { @MainActor [weak self] () -> Bool in
            _ = await previous?.value
            guard let self else { return false }
            return await self.sendNow(settingsOnly: settingsOnly)
        }
        sendChain = task
        let sent = await task.value
        // The last send in the chain lets go of it.
        if sendChain == task { sendChain = nil }
        return sent
    }

    private func sendNow(settingsOnly: Bool) async -> Bool {
        guard readConfigIfNeeded(), let binding = config.binding else { return false }
        let at = now()
        // What a layer turned off or a pause no longer allows stays unsent.
        if let fix = unsent.fix, !settings.shares(fix.source, at: at) { unsent.fix = nil }
        if !settings.shares(.place, at: at) { unsent.events = [] }
        saveUnsent()
        let pending = unsent
        if pending.isEmpty, !settingsOnly { return true }
        guard let request = await requestProvider?(binding) else { return false }
        var batch = LocationBatch(sentAt: at, settings: settings)
        batch.approximateOnly = approximate || config.approximateOnly
        batch.knownPlaces = places
        batch.fix = pending.fix?.record
        batch.events = pending.events
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "conduit.location.send")
        defer { if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier) } }
        isSending = true
        defer { isSending = false }
        let outcome = await engine.send(batch, config: config, request: request)
        guard outcome != .failed else { return false }
        unsent.remove(fixID: pending.fix?.id, eventIDs: Set(pending.events.map(\.id)))
        saveUnsent()
        return outcome == .sent
    }

    static func waitAtMost(_ limit: Duration, for task: Task<Void, Never>) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = LocationOnce()
            Task { @MainActor in
                await task.value
                once.run { continuation.resume() }
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                once.run { continuation.resume() }
            }
        }
    }

    // MARK: Choices

    enum Layer { case talking, background }

    /// Turns a layer on for `destination`: asks iOS for permission (When In
    /// Use, then Always for the background), binds sharing to the dashboard
    /// and profile in use when nothing is on yet, and tells the host.
    func turnOn(_ layer: Layer, destination: LocationBinding) async throws {
        guard readConfigIfNeeded() else { throw LocationSharingError.unreadable }
        let status: CLAuthorizationStatus
        switch layer {
        case .talking: status = await fixes.requestWhenInUse()
        case .background: status = await fixes.requestAlways()
        }
        refreshAuthorization()
        // Background without Always stays on and says it needs Always.
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            throw LocationSharingError.permissionDenied
        }
        if config.binding == nil || (!settings.isOn && config.binding != destination) {
            if config.binding != destination { engine.forgetHost() }
            save { $0.binding = destination }
        }
        save { config in
            switch layer {
            case .talking: config.settings.talking = true
            case .background: config.settings.background = true
            }
        }
        reconfigureMonitors()
        await flush(settingsOnly: true)
    }

    func turnOff(_ layer: Layer) async {
        save { config in
            switch layer {
            case .talking: config.settings.talking = false
            case .background: config.settings.background = false
            }
        }
        if layer == .talking { voiceCallEnded() }
        reconfigureMonitors()
        await flush(settingsOnly: true)
    }

    func setPrecision(_ precision: LocationPrecision, for layer: Layer) async {
        save { config in
            switch layer {
            case .talking: config.settings.talkingPrecision = precision
            case .background: config.settings.backgroundPrecision = precision
            }
        }
        reconfigureMonitors()
        await flush(settingsOnly: true)
    }

    func setRetention(_ days: Int) async {
        guard LocationSharingSettings.retentionChoices.contains(days) else { return }
        save { $0.settings.retentionDays = days }
        await flush(settingsOnly: true)
    }

    /// Pauses until `date` (`.distantFuture`: until turned back on), or
    /// resumes with nil. What wasn't sent before the pause is dropped.
    func pause(until date: Date?) async {
        save { $0.settings.pausedUntil = date }
        if date != nil {
            unsent.fix = nil
            unsent.events = []
            saveUnsent()
            voiceCallEnded()
        }
        await flush(settingsOnly: true)
    }

    /// Resumes a pause whose time has passed, so it doesn't linger.
    func clearExpiredPause() {
        if let until = settings.pausedUntil, until <= now() { save { $0.settings.pausedUntil = nil } }
    }

    // MARK: Saved places

    func savePlace(_ place: LocationSavedPlace) async {
        save { config in
            if let index = config.places.firstIndex(where: { $0.id == place.id }) {
                config.places[index] = place
            } else if config.places.count < Self.maxPlaces {
                config.places.append(place)
            }
        }
        // A moved place starts from where the phone is.
        unsent.inside.removeValue(forKey: place.id)
        saveUnsent()
        reconfigureMonitors()
        await flush(settingsOnly: true)
    }

    func removePlace(_ id: String) async {
        save { $0.places.removeAll { $0.id == id } }
        unsent.inside.removeValue(forKey: id)
        unsent.events.removeAll { $0.placeID == id }
        saveUnsent()
        reconfigureMonitors()
        await flush(settingsOnly: true)
    }

    // MARK: Host

    /// The connection for reading the host's status, read log and rules.
    func hostRequest() async -> LocationSyncEngine.Request? {
        guard let binding = config.binding else { return nil }
        return await requestProvider?(binding)
    }

    /// Deletes what this phone (or, with `everything`, every device and the
    /// place rules) sent to the host. With both layers off, sharing is
    /// unbound too, so it can be turned on for another dashboard.
    func wipe(everything: Bool) async throws {
        guard let request = await hostRequest() else { throw DashboardTicketBridgeError.notReady }
        try await engine.wipe(deviceID: config.deviceID, everything: everything, request: request)
        unsent.fix = nil
        unsent.events = []
        saveUnsent()
        if !settings.isOn {
            save { $0.binding = nil }
            LocationKeychain.clearHostPass()
        }
    }
}
