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
//  A message uses a fix iOS took minutes ago while the phone was still, and
//  sends nothing when the host already has that place from a recent
//  message (ContextUploadPolicy).
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
    /// phone for a fresh fix (`location-locate`), and let the host's other
    /// profiles read it (`location-profiles`). Never gated on a version.
    static let capability = "location-sync"
    static let locateCapability = "location-locate"
    static let profilesCapability = "location-profiles"
    static let maxPlaces = LocationSavedPlace.maxCount

    @Published private(set) var config: LocationSharedConfig
    /// The config file couldn't be read: before first unlock, or damaged.
    /// Nothing is taken, sent or saved over it until it reads again or the
    /// user starts over in Settings > Location.
    @Published private(set) var configUnreadable = false
    /// The last change couldn't be written to config.json. It's in effect
    /// in the app; the extension and the next launch don't see it yet.
    @Published private(set) var configSaveFailed = false
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
    /// Walking past: the shops Pulse asked this iPhone to watch.
    private(set) lazy var spots: PulseSpotWatcher = {
        let spots = PulseSpotWatcher()
        spots.entered = { [weak self] spot, at in self?.spotEntered(spot, at: at) }
        spots.privatePlaces = { [weak self] in self?.places.filter(\.isPrivate) ?? [] }
        spots.keepRunning = { LocationSharingController.beginBackgroundTask("conduit.location.spots") }
        return spots
    }()

    /// The connection to `binding`'s dashboard, or nil when there is none.
    /// AppState+Location supplies it; tests supply their own.
    var requestProvider: ((LocationBinding) async -> LocationSyncEngine.Request?)?
    var now: () -> Date = Date.init
    var deviceConditions: @MainActor () -> DeviceConditions = { DeviceConditionsMonitor.shared.current }

    private var unsent: LocationUnsent
    /// How many times shop watching was forgotten, and that count when the
    /// batch now being sent was built.
    private var spotsForgotten = 0
    private var spotsSentAt = 0
    /// Whether shops could be watched at the last reconfigure (nil before
    /// the first).
    private var spotsAllowedBefore: Bool?
    private var sendChain: Task<Bool, Never>?
    private var callWatch: Task<Void, Never>?
    private var lastCallFix: CLLocation?
    /// The last fix the host took with a message or a call, so the same
    /// place isn't sent again with every message.
    private(set) var lastTalkingUpload: LocationTalkingUpload?
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
        self.engine.spotsReplied = { [weak self] watches in
            // A reply to a batch sent before Walking past went off lists
            // watches the host no longer keeps.
            guard let self, self.spotsSentAt == self.spotsForgotten else { return }
            self.spots.replied(watches, near: self.fixes.lastKnownFix)
        }
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
        // Applied in memory either way: turning sharing off or pausing it
        // takes effect in the app even if the file can't be written now.
        change(&config)
        writeConfig()
    }

    /// Writes the config; on failure Settings > Location says so, and the
    /// next change or coming to the foreground tries again.
    private func writeConfig() {
        if LocationSharedStore.saveConfig(config) {
            configSaveFailed = false
        } else {
            LocationSyncEngine.log.error("Couldn't write the location config")
            configSaveFailed = true
        }
    }

    func retryConfigSave() {
        guard configSaveFailed, !configUnreadable else { return }
        writeConfig()
    }

    /// Settings > Location's way out of a config file that stays unreadable
    /// while the phone is unlocked: a fresh config, keeping the device id if
    /// it can still be found in the file, so the host's copy can be deleted.
    func startOver() {
        let deviceID = LocationSharedStore.salvageDeviceID()
        config = deviceID.map { LocationSharedConfig(deviceID: $0) } ?? LocationSharedConfig()
        configUnreadable = false
        writeConfig()
        unsent = LocationUnsent()
        saveUnsent()
        lastTalkingUpload = nil
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
        retryConfigSave()
        clearExpiredPause(send: false)
        // Not only while sharing is on: a change to off or paused that
        // didn't reach the host is the one that matters most.
        guard config.binding != nil else { return }
        reconfigureMonitors()
        if settings.shares(.app, at: now()), fixes.authorizationStatus == .authorizedAlways,
           (engine.state.lastFixSent.map { now().timeIntervalSince($0) > LocationTiming.appFixInterval } ?? true) {
            // Every batch carries the sharing choices too.
            Task { await shareFix(source: .app) }
        } else {
            sendWaiting()
        }
    }

    /// Connected to a dashboard: send what's waiting if it's the bound one.
    func hostConnected() {
        guard readConfigIfNeeded(), config.binding != nil else { return }
        sendWaiting()
    }

    /// Sends what's unsent and any choices the host hasn't had yet.
    private func sendWaiting() {
        guard !unsent.isEmpty || config.settingsPending else { return }
        let settingsOnly = config.settingsPending
        Task { await flush(settingsOnly: settingsOnly) }
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

    /// Stops watching shops now (Walking past or Where you are turned off
    /// in Settings > Pulse), as a reply listing none would, and drops the
    /// entries waiting to be sent.
    func forgetSpots() {
        spotsForgotten += 1
        spots.replied([], near: nil)
        guard !unsent.spotEntries.isEmpty else { return }
        unsent.spotEntries = []
        saveUnsent()
    }

    /// Shop entries waiting to be sent.
    var unsentSpotEntryCount: Int { unsent.spotEntries.count }

    func reconfigureMonitors() {
        monitor.configure(settings: settings, places: places, bound: config.binding != nil && !configUnreadable)
        let watching = watchesSpots
        spots.configure(enabled: watching, savedPlaces: places.count)
        // Shops may be watched again (Always or Precise allowed in iOS
        // Settings): a send now brings back the host's list.
        if watching, spotsAllowedBefore == false { Task { await flush(settingsOnly: true) } }
        spotsAllowedBefore = watching
    }

    /// Whether this iPhone may watch shops for Pulse: background sharing at
    /// Precise (a shop's name and how far the phone was from it say as much
    /// as a precise fix), with Always and precise location, not paused.
    var watchesSpots: Bool {
        config.binding != nil && !configUnreadable && settings.backgroundPrecision == .precise
            && settings.shares(.place, at: now()) && fixes.authorizationStatus == .authorizedAlways && !fixes.isApproximate
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

    /// The phone came within a watched shop's circle: a fresh fix says how
    /// far from it the phone was then (how late iOS told the app), and the
    /// entry goes now. Nothing inside a private place.
    private func spotEntered(_ spot: PulseSpotState.Spot, at date: Date) {
        guard readConfigIfNeeded(), watchesSpots else { return }
        Task { @MainActor in
            let endBackground = beginBackgroundWork(for: .place)
            defer { endBackground() }
            let location = await fixes.currentFix(accuracy: kCLLocationAccuracyBest, maxAge: 15, timeout: .seconds(15))
            // Nothing from inside a private place: without a fresh fix the last
            // known one decides, and with neither nothing is sent.
            guard let checked = location ?? fixes.lastKnownFix,
                  LocationPrecisionRules.containingPrivatePlace(LocationRawFix(checked), places: places) == nil
            else { return }
            let entry = LocationSpotEntry(
                spotID: spot.watchID, name: spot.name, at: date, fixAt: location?.timestamp,
                distance: location.map { $0.distance(from: spot.location) },
                accuracy: location.map(\.horizontalAccuracy),
                speed: location.flatMap { $0.speed >= 0 ? $0.speed : nil },
                radius: spot.radius)
            // Walking past may have been turned off, or the shop dropped,
            // while the fix came.
            guard watchesSpots, spots.state.watches.contains(where: { $0.id == spot.watchID }),
                  spots.state.spots.contains(where: { $0.id == spot.id }) else { return }
            unsent.keep(spotEntry: entry)
            saveUnsent()
            if let location { spots.moved(location) }
            await flush()
        }
    }

    // MARK: Taking and sending

    /// Takes a fix for `source` (with any events) and sends it. True when
    /// the host has it.
    @discardableResult
    func shareFix(source: LocationFixSource, events: [LocationPlaceEvent] = []) async -> Bool {
        guard settings.shares(source, at: now()) else { return false }
        // A background relaunch gets a few seconds: the fix, place name and
        // send run inside an assertion, and an arrive/leave is kept before
        // the fix so a suspension can't lose it.
        let endBackground = beginBackgroundWork(for: source)
        defer { endBackground() }
        if !events.isEmpty {
            unsent.keep(fix: nil, events: events)
            saveUnsent()
        }
        let precision = settings.precision(for: source)
        let accuracy = LocationFixProvider.desiredAccuracy(for: precision)
        let location: CLLocation?
        if source == .message, let known = recentFixForMessage(accuracy: accuracy) {
            location = known
        } else {
            location = await fixes.currentFix(
                accuracy: accuracy,
                maxAge: source.isTalking ? ContextUploadPolicy.messageFixFreshAge : 120,
                timeout: source.isTalking ? .seconds(8) : .seconds(15)
            )
        }
        // The place the host already has from a message moments ago: the
        // message goes without sending it again (or looking up its area).
        if source == .message, events.isEmpty, unsent.fix == nil, let location,
           !messageFixIsNews(LocationRawFix(location), precision: precision) {
            return true
        }
        return await share(location, source: source, events: events)
    }

    /// A fix iOS took a few minutes ago while the phone was still, instead
    /// of asking Core Location again for every message.
    private func recentFixForMessage(accuracy: CLLocationAccuracy) -> CLLocation? {
        guard let known = fixes.lastKnownFix else { return nil }
        let reusable = ContextUploadPolicy.reusesFix(
            age: now().timeIntervalSince(known.timestamp), accuracy: known.horizontalAccuracy,
            speed: known.speed, wanted: accuracy)
        return reusable ? known : nil
    }

    /// Whether a message's fix says more than the last one the host took.
    func messageFixIsNews(_ fix: LocationRawFix, precision: LocationPrecision) -> Bool {
        ContextUploadPolicy.messageFixIsNews(fix, precision: precision, host: talkingHost, last: lastTalkingUpload,
                                             now: now(), conditions: deviceConditions())
    }

    private var talkingHost: LocationTalkingUpload.Host {
        LocationTalkingUpload.Host(keyAgreements: engine.keyAgreements, generation: engine.state.generation)
    }

    /// The host took `fix`: remembered (in memory) when it came with a
    /// message or a call.
    func noteSent(_ fix: LocationFixRecord?, at date: Date) {
        guard let fix else { return }
        guard fix.source.isTalking else {
            // A newer fix from elsewhere is the host's latest now.
            lastTalkingUpload = nil
            return
        }
        lastTalkingUpload = LocationTalkingUpload(fix: fix.raw, precision: settings.precision(for: fix.source),
                                                  host: talkingHost, sentAt: date)
    }

    @discardableResult
    func share(_ location: CLLocation?, source: LocationFixSource, events: [LocationPlaceEvent] = []) async -> Bool {
        guard readConfigIfNeeded(), config.binding != nil, settings.shares(source, at: now()) else { return false }
        let endBackground = beginBackgroundWork(for: source)
        defer { endBackground() }
        var record: LocationFixRecord?
        if let location {
            // Any fix may move the shops watched along (walking past).
            spots.moved(location)
            let precision = settings.precision(for: source)
            let area = precision == .places ? nil : await fixes.area(for: location)
            record = LocationFixRecord(source: source, raw: LocationRawFix(location), area: area)
        }
        guard record != nil || !events.isEmpty else { return false }
        unsent.keep(fix: record, events: events)
        saveUnsent()
        return await flush()
    }

    private func beginBackgroundWork(for source: LocationFixSource) -> () -> Void {
        source.isTalking ? {} : Self.beginBackgroundTask("conduit.location.fix")
    }

    /// Ends itself when iOS's time runs out, so expiry stops the work
    /// instead of killing the app. Nothing is lost: unsent fixes and events
    /// are only dropped once the host has them.
    private static func beginBackgroundTask(_ name: String) -> () -> Void {
        BackgroundTaskHold.begin(name)
    }

    /// Sends the unsent fix and events (or just the sharing choices and
    /// places), one batch at a time.
    @discardableResult
    func flush(settingsOnly: Bool = false) async -> Bool {
        // Remembered until a batch with these choices reaches the host, so a
        // change made offline goes when the host is next reachable.
        if settingsOnly, config.binding != nil, !config.settingsPending { save { $0.settingsPending = true } }
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
        // What a layer turned off or a pause no longer allows is dropped,
        // not held for later.
        if let fix = unsent.fix, !settings.shares(fix.source, at: at) { unsent.fix = nil }
        if !settings.shares(.place, at: at) { unsent.events = [] }
        var watching = watchesSpots
        if !watching { unsent.spotEntries = [] }
        saveUnsent()
        var pending = unsent
        if pending.isEmpty, !settingsOnly { return true }
        let forgotten = spotsForgotten
        guard let request = await requestProvider?(binding) else { return false }
        // Walking past turned off, a pause, or Location settings changed
        // while the connection came: this batch carries no shops.
        if spotsForgotten != forgotten || !watchesSpots {
            watching = false
            pending.spotEntries = []
        }
        var batch = LocationBatch(sentAt: at, settings: settings)
        batch.approximateOnly = approximate || config.approximateOnly
        batch.knownPlaces = places
        batch.fix = pending.fix?.record
        batch.events = pending.events
        if watching {
            // Even empty: the host's answer then lists what to watch.
            batch.spotEntries = pending.spotEntries
            batch.spotsRoom = spots.room
        }
        let endBackground = Self.beginBackgroundTask("conduit.location.send")
        defer { endBackground() }
        isSending = true
        defer { isSending = false }
        let sentSettings = config.settings
        let sentPlaces = config.places
        spotsSentAt = spotsForgotten
        let outcome = await engine.send(batch, config: config, request: request)
        guard outcome != .failed else { return false }
        if outcome == .sent { noteSent(batch.fix, at: at) }
        // The host has these choices (or won't take them: retrying the same
        // batch wouldn't help). A change made meanwhile stays pending.
        if config.settingsPending, config.settings == sentSettings, config.places == sentPlaces {
            save { $0.settingsPending = false }
        }
        unsent.remove(fixID: pending.fix?.id, eventIDs: Set(pending.events.map(\.id)),
                      spotEntryIDs: Set(pending.spotEntries.map(\.id)))
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
    func turnOn(_ layer: Layer, destination: LocationBinding, otherProfiles: Bool) async throws {
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
        let sharesWithOtherProfiles = Self.otherProfiles(turningOn: settings, bound: config.binding, to: destination,
                                                         offered: otherProfiles)
        if config.binding == nil || (!settings.isOn && config.binding != destination) {
            if config.binding != destination { engine.forgetHost() }
            save {
                // A choice about one host's profiles isn't another's.
                if $0.binding != destination { $0.settings.otherProfilesChosen = false }
                $0.binding = destination
            }
            // Precise Location off is kept only once there's a binding.
            refreshAuthorization()
        }
        save { config in
            switch layer {
            case .talking: config.settings.talking = true
            case .background: config.settings.background = true
            }
            config.settings.otherProfiles = sharesWithOtherProfiles
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
            // Sharing off: turning it on again asks each voice mode again.
            if !config.settings.isOn { config.voiceReaders = nil }
        }
        if layer == .talking {
            voiceCallEnded()
            lastTalkingUpload = nil
        }
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

    /// "Keep maps lookups on this iPhone": the host then never looks up
    /// places or routes itself.
    func setMapsHost(_ allowed: Bool) async {
        guard settings.mapsHost != allowed else { return }
        save { $0.settings.mapsHost = allowed }
        await flush(settingsOnly: true)
    }

    /// Whether the host's other profiles read the location once a layer goes
    /// on: the consent sheet for the first layer said so (`offered`), unless
    /// the user already chose in Settings; a second layer keeps what the
    /// user has. Binding to another host asks afresh.
    static func otherProfiles(turningOn settings: LocationSharingSettings, bound: LocationBinding?,
                              to destination: LocationBinding?, offered: Bool) -> Bool {
        if settings.isOn { return settings.otherProfiles }
        return (settings.otherProfilesChosen && bound == destination) ? settings.otherProfiles : offered
    }

    /// "Share with this host's other profiles".
    func setOtherProfiles(_ allowed: Bool) async {
        guard settings.otherProfiles != allowed else { return }
        save {
            $0.settings.otherProfiles = allowed
            $0.settings.otherProfilesChosen = true
        }
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
            unsent.spotEntries = []
            saveUnsent()
            lastTalkingUpload = nil
            voiceCallEnded()
        }
        // Paused, shops stop being watched (and are forgotten); resumed, they start again.
        reconfigureMonitors()
        await flush(settingsOnly: true)
        // Resumed: a voice mode the user allowed may read again.
        if date == nil { await prepareVoiceReads() }
    }

    /// Resumes a pause whose time has passed, so it doesn't linger, and
    /// tells the host (pending until it's reachable). `send: false` leaves
    /// the sending to the caller.
    func clearExpiredPause(send: Bool = true) {
        guard let until = settings.pausedUntil, until <= now() else { return }
        save { config in
            config.settings.pausedUntil = nil
            if config.binding != nil { config.settingsPending = true }
        }
        reconfigureMonitors()
        if send, config.binding != nil {
            Task {
                await flush(settingsOnly: true)
                await prepareVoiceReads()
            }
        }
    }

    // MARK: Live voice calls

    /// Whether a live call on `mode` may read the shared location
    /// (Settings > Location, off by default: what it reads goes to the
    /// mode's company). Never while sharing is paused.
    func letsVoiceRead(_ mode: LiveVoiceModeName) -> Bool {
        !configUnreadable && config.letsVoiceRead(mode.storageID, at: now())
    }

    /// Whether the switch for `mode` is on (a pause keeps it, but stops reads).
    func allowsVoiceRead(_ mode: LiveVoiceModeName) -> Bool {
        (config.voiceReaders ?? []).contains(mode.storageID)
    }

    /// Lets `mode` read the shared location on a call, or stops it.
    func setVoiceRead(_ mode: LiveVoiceModeName, allowed: Bool) async {
        guard readConfigIfNeeded(), config.binding != nil, settings.isOn || !allowed else { return }
        save { $0.setVoiceRead(mode.storageID, allowed: allowed) }
        if allowed { await prepareVoiceReads() }
    }

    /// This phone's key for a voice read of its own location; nil until a
    /// send has agreed one that reads.
    func voiceReadKey() -> LocationCrypto.SessionKey? {
        guard readConfigIfNeeded(), config.binding != nil else { return nil }
        return engine.voiceReadKey(deviceID: config.deviceID)
    }

    /// A key agreed before voice reads existed is set up again now (a send
    /// does it), with a fresh position when sharing allows one now (the
    /// background layer, or a call already running on the talking layer):
    /// the host drops the one it had with the old key.
    func prepareVoiceReads() async {
        guard voiceReadKey() == nil, config.readsByVoice(at: now()) else { return }
        if fixes.canLocate {
            if await shareFix(source: .app) { return }
            if callWatch != nil, await shareFix(source: .call) { return }
        }
        await flush(settingsOnly: true)
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
        lastTalkingUpload = nil
        unsent.fix = nil
        unsent.events = []
        unsent.spotEntries = []
        saveUnsent()
        if !settings.isOn {
            save { $0.binding = nil }
            LocationKeychain.clearHostPass()
        }
        // Unbound, the shops' monitor is emptied and spots.json forgotten.
        reconfigureMonitors()
    }
}
