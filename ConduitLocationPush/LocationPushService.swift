import CoreLocation
import Foundation

/// Answers the agent's on-demand locate (designs/location-awareness.md
/// section 12, contract section 5) while Conduit may not be running.
///
/// The relay sends a `location` push for a `locate` the agent asked for.
/// This extension checks it the way the Notification Service Extension
/// checks a notification, answers only for the dashboard and profile
/// location sharing is bound to while background sharing is on and not
/// paused, takes one fix at the background precision, seals it with the
/// key the app agreed with the host, and posts it straight to the host with
/// the app's host pass (LocationHostClient). The relay never sees where the
/// phone is. Anything that doesn't check out posts nothing.
///
/// The same push can carry a maps request instead (designs/maps-v1-contract.md):
/// the request is fetched sealed from the host, answered with MapKit on this
/// iPhone (MapsEngine), and the sealed answer posted back.
final class LocationPushService: NSObject, CLLocationPushServiceExtension, CLLocationManagerDelegate {
    // didReceive and serviceExtensionWillTerminate may run on different
    // threads; the lock guards `completion` and `work`, so completion runs
    // exactly once and the task is cancelled whichever comes first.
    private let lock = NSLock()
    private var completion: (() -> Void)?
    private var manager: CLLocationManager?
    private var serviceSession: AnyObject?
    private var fixContinuation: CheckedContinuation<CLLocation?, Never>?
    private var work: Task<Void, Never>?
    /// The locate claimed in the replay store and not answered yet:
    /// released if the extension finishes or is stopped without posting.
    /// If iOS kills the extension outright the claim ages out instead.
    private var pendingReplayKey: String?
    /// The replay namespace of `pendingReplayKey`: "locate" or "maps".
    private var pendingNamespace = "locate"
    private static let claimLifetime: TimeInterval = 30

    // The whole answer has to fit iOS's budget for this extension.
    private static let fixTimeout: TimeInterval = 6
    private static let geocodeTimeout: TimeInterval = 1.5
    private static let postTimeout: TimeInterval = 8
    // A maps request (designs/maps-v1-contract.md): the host waits 20 s
    // in all, so fetch (4), fix (6), lookup (5) and answer (5) fit in it.
    private static let mapsFetchTimeout: TimeInterval = 4
    private static let mapsLookupDeadline: TimeInterval = 5
    private static let mapsPostTimeout: TimeInterval = 5

    func didReceiveLocationPushPayload(_ payload: [String: Any], completion: @escaping () -> Void) {
        lock.withLock { self.completion = completion }
        var userInfo: [AnyHashable: Any] = [:]
        for (key, value) in payload { userInfo[AnyHashable(key)] = value }
        let task = Task { [weak self] in
            await self?.answer(userInfo)
            self?.finish()
        }
        // Installed only while the push is still open: if iOS stopped the
        // extension in between, finish already ran and the task just stops.
        let installed: Bool = lock.withLock {
            guard self.completion != nil else { return false }
            work = task
            return true
        }
        if !installed { task.cancel() }
    }

    func serviceExtensionWillTerminate() {
        let task: Task<Void, Never>? = lock.withLock {
            defer { work = nil }
            return work
        }
        task?.cancel()
        finish()
    }

    /// Ends the push: releases an unanswered replay key, stops a fix still
    /// waiting, and calls the completion once.
    private func finish() {
        let (handler, unanswered, namespace): ((() -> Void)?, String?, String) = lock.withLock {
            defer {
                completion = nil
                work = nil
                pendingReplayKey = nil
            }
            return (completion, pendingReplayKey, pendingNamespace)
        }
        if let unanswered { E2ESeenStore.shared.remove(unanswered, namespace: namespace) }
        DispatchQueue.main.async {
            self.resumeFix(nil)
            self.manager?.delegate = nil
            self.manager = nil
            self.serviceSession = nil
        }
        handler?()
    }

    private func answer(_ payload: [AnyHashable: Any]) async {
        guard let request = LocationLocateRequest.parse(
            payload,
            records: KeychainE2EKeyStore().records(),
            knownGatewayIDs: NotificationSharedSettings.knownGatewayIDs,
            keysProvisioned: NotificationSharedSettings.keysProvisioned
        ) else { return }
        if request.kind == .maps {
            await answerMaps(request)
            return
        }
        guard case .value(let config) = LocationSharedStore.readConfig(),
              request.isAnswered(by: config, at: Date()),
              let binding = config.binding,
              let key = LocationKeychain.loadKey(), key.deviceID == config.deviceID,
              let pass = LocationKeychain.loadHostPass(), pass.dashboardID == binding.dashboardID, pass.isUsable(at: Date())
        else { return }
        // A second delivery of the same request is answered once. The key
        // is claimed now (a concurrent delivery stops here), marked answered
        // after the post, and released if the answer doesn't reach the
        // host; a claim left by a killed extension ages out after
        // `claimLifetime`. Either way a redelivery can try again.
        // Stopped already (iOS's time ran out): leave it to a redelivery.
        guard !Task.isCancelled else { return }
        guard E2ESeenStore.shared.claim(request.replayKey, namespace: "locate", ttl: Self.claimLifetime) else { return }
        lock.withLock {
            pendingReplayKey = request.replayKey
            pendingNamespace = "locate"
        }

        let precision = config.settings.backgroundPrecision
        // Stopped between the claim and here: don't arm location hardware.
        guard !Task.isCancelled else { return }
        let (location, approximate) = await fix(precision: precision)
        guard let location, !Task.isCancelled else { return }
        // The area is a nicety: sent only if the geocoder answers quickly.
        var area: LocationArea?
        if precision != .places, !Task.isCancelled { area = await Self.area(for: location, timeout: Self.geocodeTimeout) }

        var batch = LocationBatch(sentAt: Date(), settings: config.settings)
        batch.approximateOnly = approximate || config.approximateOnly
        batch.knownPlaces = config.places
        // The same place list the app sends, so the host's stays current.
        // (No coordinates: names, kinds and ids only.)
        batch.places = config.places
        batch.fix = LocationFixRecord(source: .locate, raw: LocationRawFix(location), area: area)
        batch.locateID = request.id
        guard let body = try? LocationIngest.body(batch, key: key), !Task.isCancelled else { return }
        do {
            _ = try await LocationHostClient.requestJSON(
                pass: pass,
                path: LocationHostClient.withProfile("\(LocationHostClient.base)/ingest", profile: binding.profile),
                method: "POST",
                body: body,
                timeout: Self.postTimeout
            )
            // Answered: a redelivery of this locate stays a replay.
            lock.withLock { pendingReplayKey = nil }
            E2ESeenStore.shared.markAnswered(request.replayKey, namespace: "locate")
        } catch {
            // The claim is released (finish), so a redelivery can answer;
            // this fix isn't kept, and the app shares its own next time.
        }
    }

    // MARK: Maps

    /// Answers a maps request (designs/maps-v1-contract.md sections 2-4):
    /// fetches it sealed from the host, runs it with MapKit, and posts the
    /// sealed answer. Only for the dashboard and profile sharing is bound
    /// to; while sharing is paused or the background layer is off, the
    /// answer is "paused". A fix is taken only when the request uses "me".
    private func answerMaps(_ request: LocationLocateRequest) async {
        guard case .value(let config) = LocationSharedStore.readConfig(),
              request.isForBinding(of: config),
              let binding = config.binding,
              let key = LocationKeychain.loadKey(), key.deviceID == config.deviceID, key.answersMaps,
              let pass = LocationKeychain.loadHostPass(), pass.dashboardID == binding.dashboardID, pass.isUsable(at: Date()),
              LocationLocateRequest.isMapsID(request.id),
              let deviceQuery = Self.queryValue(key.deviceID), let kidQuery = Self.queryValue(key.kid)
        else { return }
        guard !Task.isCancelled else { return }
        guard E2ESeenStore.shared.claim(request.replayKey, namespace: "maps", ttl: Self.claimLifetime) else { return }
        lock.withLock {
            pendingReplayKey = request.replayKey
            pendingNamespace = "maps"
        }

        let path = "\(LocationHostClient.base)/maps/\(request.id)"
        let sealed: [String: Any]
        do {
            sealed = try await LocationHostClient.requestJSON(
                pass: pass,
                path: LocationHostClient.withProfile("\(path)?device_id=\(deviceQuery)&kid=\(kidQuery)", profile: binding.profile),
                method: "GET",
                body: nil,
                timeout: Self.mapsFetchTimeout
            )
        } catch {
            // Expired, answered, another device's, or the host is away:
            // nothing to answer. The claim is released (finish).
            return
        }
        guard !Task.isCancelled,
              let body = try? LocationCrypto.openMapsRequest(sealed, key: key, id: request.id),
              body["id"] as? String == request.id
        else { return }

        let answer: MapsAnswer
        switch MapsRequest.parse(body) {
        case .failure(let failure):
            answer = .failure(failure)
        case .success(let maps):
            // Too late: the host refuses answers after expires_at, so none is sent.
            if let expiresAt = maps.expiresAt, expiresAt < Date() { return }
            answer = await run(maps, config: config)
        }
        guard !Task.isCancelled,
              let envelope = try? LocationCrypto.mapsAnswer(plaintext: answer.plaintext(id: request.id), key: key, id: request.id)
        else { return }
        do {
            _ = try await LocationHostClient.requestJSON(
                pass: pass,
                path: LocationHostClient.withProfile(path, profile: binding.profile),
                method: "POST",
                body: envelope,
                timeout: Self.mapsPostTimeout
            )
            lock.withLock { pendingReplayKey = nil }
            E2ESeenStore.shared.markAnswered(request.replayKey, namespace: "maps")
        } catch {
            // The claim is released (finish), so a redelivery can answer.
        }
    }

    /// The answer, with "me" at the background precision (and the host's
    /// `detail`, whichever is stricter).
    private func run(_ request: MapsRequest, config: LocationSharedConfig) async -> MapsAnswer {
        let now = Date()
        guard config.settings.shares(.locate, at: now) else { return .failure(.paused) }
        var me: MapsMe?
        if request.usesMe {
            var precision = config.settings.backgroundPrecision
            if config.approximateOnly { precision = precision.capped(at: .area) }
            if precision == .places {
                me = .unavailable(.noLocation("Location detail is Places only, so nothing can be worked out from where the user is."))
            } else {
                guard !Task.isCancelled else { return .failure(.timeout) }
                let (location, approximate) = await fix(precision: precision)
                if let location {
                    me = .at(location, approximate ? precision.capped(at: .area) : precision)
                } else {
                    me = .unavailable(.noLocation())
                }
            }
        }
        guard !Task.isCancelled else { return .failure(.timeout) }
        let context = MapsContext(me: me, places: config.places, now: now)
        return await MapsEngine.answer(request, context: context, deadline: Self.mapsLookupDeadline)
    }

    /// A value for the query string: ids are `[A-Za-z0-9_-]` already.
    private static func queryValue(_ value: String) -> String? {
        value.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil ? value : nil
    }

    // MARK: One fix

    private func fix(precision: LocationPrecision) async -> (CLLocation?, Bool) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(CLLocation?, Bool), Never>) in
            DispatchQueue.main.async {
                let manager = CLLocationManager()
                if #available(iOS 18.0, *) {
                    // iOS 18 lets an extension use location only inside a
                    // session for the authorization the app holds.
                    self.serviceSession = CLServiceSession(authorization: .always)
                }
                manager.delegate = self
                manager.desiredAccuracy = precision == .precise ? kCLLocationAccuracyNearestTenMeters : kCLLocationAccuracyHundredMeters
                self.manager = manager
                let approximate = manager.accuracyAuthorization == .reducedAccuracy
                Task {
                    let location = await withCheckedContinuation { (inner: CheckedContinuation<CLLocation?, Never>) in
                        DispatchQueue.main.async {
                            self.fixContinuation = inner
                            manager.requestLocation()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fixTimeout) { self.resumeFix(nil) }
                    }
                    continuation.resume(returning: (location, approximate))
                }
            }
        }
    }

    /// Main queue only.
    private func resumeFix(_ location: CLLocation?) {
        let continuation = fixContinuation
        fixContinuation = nil
        continuation?.resume(returning: location)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        DispatchQueue.main.async { self.resumeFix(location) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async { self.resumeFix(nil) }
    }

    // MARK: Area

    /// Neighbourhood, city and country from Apple's geocoder, or nil when it
    /// doesn't answer within `timeout`.
    private static func area(for location: CLLocation, timeout: TimeInterval) async -> LocationArea? {
        let geocoder = CLGeocoder()
        let lock = NSLock()
        var done = false
        return await withCheckedContinuation { (continuation: CheckedContinuation<LocationArea?, Never>) in
            func resume(_ area: LocationArea?) {
                let first: Bool = lock.withLock {
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: area) }
            }
            geocoder.reverseGeocodeLocation(location) { placemarks, _ in
                resume(placemarks?.first.map { placemark in
                    LocationArea(
                        name: placemark.subLocality ?? placemark.locality,
                        locality: placemark.locality,
                        region: placemark.administrativeArea,
                        country: placemark.country,
                        countryCode: placemark.isoCountryCode
                    )
                })
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                geocoder.cancelGeocode()
                resume(nil)
            }
        }
    }
}
