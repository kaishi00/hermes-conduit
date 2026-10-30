//
//  LocationSharingTests.swift
//
//  Location for Hermes (designs/location-v1-contract.md): the sealing
//  against the notifier's shared vector, the precision rules the phone
//  applies before anything is sealed, the batch's shape, pause and layer
//  gating, what's kept unsent, and the on-demand locate's checks.
//
//  An extension of NotificationE2ETests (both are about what Conduit seals
//  for a host) so the CI planner gets no new class to place.
//

import CoreLocation
import CryptoKit
import XCTest
@testable import Conduit

private enum LocationVector {
    // tests/location_vector.json in hermes-conduit-notifier.
    static let hostPublic = "j0DFrbaPJWJK5bIU6nZ6bslNgp09e14a0bpvPiE4KF8"
    static let devicePrivate = "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8"
    static let devicePublic = "NYBy1jZYgNGu6jKa35EhODhR7SGijjt16WXQ0s0WYlQ"
    static let deviceID = "device-vector-1"
    static let batchID = "batch-vector-1"
    static let kid = "4186c0bc93b7b264b5991464ab3e4c1f"
    static let key = "e97fd9902f44b9a9c5ffacd40612f58a471a56b5ab28c6e66f87efc04840fa6e"
    static let aad = "conduit-location/1\ningest\nkid=4186c0bc93b7b264b5991464ab3e4c1f\ndev=device-vector-1\nbatch=batch-vector-1"
    static let plaintext = "{\"batch_id\":\"batch-vector-1\"}"
    static let ct = "upKO2AMUfh95gixFbp-_E9hsTT76TlUyHHlwzdREWwCk0Gf-Nr6Oz98FPEP_"
}

private enum LocationFixtures {
    static let at = Date(timeIntervalSince1970: 1_760_430_000)
    static let home = LocationSavedPlace(id: "p_home", name: "Home", kind: .home, latitude: 51.5321, longitude: -0.0755, radius: 150)
    static let work = LocationSavedPlace(id: "p_work", name: "Work", kind: .work, latitude: 51.5155, longitude: -0.0922, radius: 200)
    static let area = LocationArea(name: "Shoreditch", locality: "London", region: "England", country: "United Kingdom", countryCode: "GB")

    static func fix(latitude: Double, longitude: Double, accuracy: Double = 12, source: LocationFixSource = .message) -> LocationFixRecord {
        LocationFixRecord(
            id: "f_test",
            source: source,
            raw: LocationRawFix(latitude: latitude, longitude: longitude, accuracy: accuracy, timestamp: at, speed: 1.23, course: 87.6),
            area: area
        )
    }

    static func json(_ fix: LocationFixRecord, _ precision: LocationPrecision, places: [LocationSavedPlace] = [home, work],
                     approximate: Bool = false) -> [String: Any] {
        LocationPrecisionRules.json(fix, precision: precision, places: places, approximateOnly: approximate,
                                    formatter: LocationTime.formatter(timeZone: TimeZone(identifier: "Europe/London")!))
    }

    static let dashboardID = UUID(uuidString: "0F5C8A34-1B2D-4E5F-8A9B-0C1D2E3F4A5B")!

    static func config(background: Bool = true, talking: Bool = false, pausedUntil: Date? = nil) -> LocationSharedConfig {
        var config = LocationSharedConfig()
        config.binding = LocationBinding(dashboardID: dashboardID, profile: "coder", host: "hermes.example.com")
        config.settings.background = background
        config.settings.talking = talking
        config.settings.pausedUntil = pausedUntil
        return config
    }
}

extension NotificationE2ETests {
    // MARK: Crypto

    func testLocationKeyAgreementMatchesTheNotifierVector() throws {
        let privateRaw = try XCTUnwrap(NotificationE2E.base64URLDecoded(LocationVector.devicePrivate))
        let devicePrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateRaw)
        XCTAssertEqual(NotificationE2E.base64URL(devicePrivate.publicKey.rawRepresentation), LocationVector.devicePublic)

        let key = try LocationCrypto.agree(
            devicePrivate: devicePrivate, deviceID: LocationVector.deviceID,
            hostPublicKey: LocationVector.hostPublic, kid: LocationVector.kid
        )
        XCTAssertEqual(key.kid, LocationVector.kid)
        XCTAssertEqual(key.deviceID, LocationVector.deviceID)
        XCTAssertEqual(key.key.map { String(format: "%02x", $0) }.joined(), LocationVector.key)
        XCTAssertEqual(
            String(decoding: LocationCrypto.aad(kid: key.kid, deviceID: key.deviceID, batchID: LocationVector.batchID), as: UTF8.self),
            LocationVector.aad
        )

        let envelope = try LocationCrypto.envelope(
            plaintext: Data(LocationVector.plaintext.utf8), key: key, batchID: LocationVector.batchID,
            nonce: ChaChaPoly.Nonce(data: Data(count: 12))
        )
        XCTAssertEqual(envelope["ct"] as? String, LocationVector.ct)
        XCTAssertEqual(envelope["nonce"] as? String, "AAAAAAAAAAAAAAAA")
        XCTAssertEqual(envelope["device_id"] as? String, LocationVector.deviceID)
        XCTAssertEqual(envelope["kid"] as? String, LocationVector.kid)
        XCTAssertEqual(envelope["batch_id"] as? String, LocationVector.batchID)
        XCTAssertEqual(envelope["v"] as? Int, 1)
    }

    func testLocationKeyAgreementRefusesAnAnswerForAnotherKey() throws {
        let devicePrivate = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: XCTUnwrap(NotificationE2E.base64URLDecoded(LocationVector.devicePrivate))
        )
        XCTAssertThrowsError(try LocationCrypto.agree(
            devicePrivate: devicePrivate, deviceID: LocationVector.deviceID,
            hostPublicKey: LocationVector.hostPublic, kid: String(repeating: "0", count: 32)
        )) { error in
            XCTAssertEqual(error as? LocationCrypto.Failure, .keyIDMismatch)
        }
    }

    // MARK: Precision

    func testAreaNamesFitWhatTheHostTakes() {
        // location_store MAX_AREA_CHARS: a longer field refuses the whole batch.
        let long = String(repeating: "Ä", count: 120)
        let area = LocationArea(name: long, locality: "London", region: long + "🇬🇧", country: "United Kingdom", countryCode: "GB")
        let json = area.json
        for key in ["name", "region"] {
            let value = json[key] as? String ?? ""
            XCTAssertEqual(value.unicodeScalars.count, 80, key)
            XCTAssertTrue(long.hasPrefix(value), key)
        }
        XCTAssertEqual(json["locality"] as? String, "London")
        XCTAssertEqual(json["country"] as? String, "United Kingdom")
        XCTAssertEqual(json["country_code"] as? String, "GB")
    }

    func testPlacesPrecisionNamesThePlaceAndNothingElse() {
        let json = LocationFixtures.json(LocationFixtures.fix(latitude: 51.5322, longitude: -0.0754), .places)
        XCTAssertEqual(json["place_id"] as? String, "p_home")
        XCTAssertEqual(json["precision"] as? String, "places")
        XCTAssertEqual(json["source"] as? String, "message")
        for key in ["lat", "lon", "accuracy_m", "area", "distances_m", "speed_mps", "course"] {
            XCTAssertNil(json[key], key)
        }

        let away = LocationFixtures.json(LocationFixtures.fix(latitude: 51.60, longitude: -0.20), .places)
        XCTAssertNil(away["place_id"])
        XCTAssertNil(away["lat"])
    }

    func testAreaPrecisionRoundsToAboutAKilometre() throws {
        let json = LocationFixtures.json(LocationFixtures.fix(latitude: 51.54367, longitude: -0.08123, accuracy: 30), .area)
        XCTAssertEqual(json["lat"] as? Double, 51.54)
        XCTAssertEqual(json["lon"] as? Double, -0.08)
        XCTAssertEqual(json["accuracy_m"] as? Int, 1_000)
        XCTAssertNil(json["speed_mps"])
        XCTAssertNil(json["course"])
        XCTAssertNil(json["place_id"])
        XCTAssertEqual((json["area"] as? [String: Any])?["locality"] as? String, "London")
        XCTAssertEqual((json["area"] as? [String: Any])?["country_code"] as? String, "GB")
        let distances = try XCTUnwrap(json["distances_m"] as? [String: Int])
        XCTAssertEqual(Set(distances.keys), ["p_home", "p_work"])
        for distance in distances.values { XCTAssertEqual(distance % 100, 0) }

        // A poor measurement keeps its own, larger, accuracy.
        let coarse = LocationFixtures.json(LocationFixtures.fix(latitude: 51.54367, longitude: -0.08123, accuracy: 1_800), .area)
        XCTAssertEqual(coarse["accuracy_m"] as? Int, 1_800)
    }

    func testPrecisePrecisionKeepsTheMeasurement() throws {
        let json = LocationFixtures.json(LocationFixtures.fix(latitude: 51.5322, longitude: -0.0754), .precise)
        XCTAssertEqual(json["lat"] as? Double, 51.5322)
        XCTAssertEqual(json["lon"] as? Double, -0.0754)
        XCTAssertEqual(json["accuracy_m"] as? Int, 12)
        XCTAssertEqual(json["place_id"] as? String, "p_home")
        XCTAssertEqual(json["speed_mps"] as? Double, 1.2)
        XCTAssertEqual(json["course"] as? Double, 88)
        let distances = try XCTUnwrap(json["distances_m"] as? [String: Int])
        for distance in distances.values { XCTAssertEqual(distance % 10, 0) }
        XCTAssertLessThan(try XCTUnwrap(distances["p_home"]), 50)
    }

    func testAPrivatePlaceSendsOnlyItsID() {
        var home = LocationFixtures.home
        home.isPrivate = true
        for precision in LocationPrecision.allCases {
            let json = LocationFixtures.json(LocationFixtures.fix(latitude: 51.5322, longitude: -0.0754), precision,
                                             places: [home, LocationFixtures.work])
            XCTAssertEqual(json["place_id"] as? String, "p_home", precision.rawValue)
            XCTAssertEqual(Set(json.keys), ["id", "at", "source", "precision", "place_id"], precision.rawValue)
        }
        // Elsewhere, no distance points at the private place.
        let away = LocationFixtures.json(LocationFixtures.fix(latitude: 51.54, longitude: -0.08), .precise,
                                         places: [home, LocationFixtures.work])
        XCTAssertNil((away["distances_m"] as? [String: Int])?["p_home"])
        XCTAssertNotNil((away["distances_m"] as? [String: Int])?["p_work"])

        let listed = LocationPrecisionRules.placesJSON([home, LocationFixtures.work])
        XCTAssertEqual(listed.first?["name"] as? String, LocationPrecisionRules.privatePlaceName)
        XCTAssertEqual(listed.first?["private"] as? Bool, true)
        XCTAssertEqual(listed.first?["kind"] as? String, "other")
        XCTAssertEqual(listed.last?["kind"] as? String, "work")
        XCTAssertEqual(listed.last?["name"] as? String, "Work")
    }

    func testApproximateOnlyNamesNoPlaceAndIsNeverPrecise() {
        let json = LocationFixtures.json(LocationFixtures.fix(latitude: 51.5322, longitude: -0.0754), .precise, approximate: true)
        XCTAssertEqual(json["precision"] as? String, "area")
        XCTAssertNil(json["place_id"])
        XCTAssertEqual(json["lat"] as? Double, 51.53)

        // Places only stays places only: no position or distances.
        let places = LocationFixtures.json(LocationFixtures.fix(latitude: 51.5322, longitude: -0.0754), .places,
                                           places: [LocationFixtures.work], approximate: true)
        XCTAssertEqual(places["precision"] as? String, "places")
        XCTAssertEqual(Set(places.keys), ["id", "at", "source", "precision"])
    }

    func testAPrivatePlaceIsHiddenEvenInARoughFix() {
        var home = LocationFixtures.home
        home.isPrivate = true
        // An approximate-only fix, and one too rough to name an ordinary place.
        for (accuracy, approximate) in [(12.0, true), (3_000.0, false), (3_000.0, true)] {
            let json = LocationFixtures.json(LocationFixtures.fix(latitude: 51.5322, longitude: -0.0754, accuracy: accuracy), .area,
                                             places: [home, LocationFixtures.work], approximate: approximate)
            XCTAssertEqual(json["place_id"] as? String, "p_home")
            XCTAssertEqual(Set(json.keys), ["id", "at", "source", "precision", "place_id"])
        }
    }

    // MARK: Stored configuration

    func testAStoredConfigurationToleratesMissingKeysAndBadPlaces() throws {
        let json = """
        {"deviceID": "0123456789abcdef0123456789abcdef", "settings": {"talking": true},
         "places": [{"id": "p_home", "latitude": 51.5, "longitude": -0.07}, {"id": "p_broken", "name": "No coordinate"}]}
        """
        let config = try JSONDecoder().decode(LocationSharedConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.deviceID, "0123456789abcdef0123456789abcdef")
        XCTAssertTrue(config.settings.talking)
        XCTAssertEqual(config.settings.backgroundPrecision, .area)
        XCTAssertEqual(config.settings.retentionDays, LocationSharingSettings.defaultRetention)
        XCTAssertEqual(config.places.map(\.id), ["p_home"])
        XCTAssertEqual(config.places.first?.kind, .other)
        XCTAssertEqual(config.places.first?.radius, LocationSavedPlace.defaultRadius)
        XCTAssertNil(config.binding)

        // A binding that can't be read shows sharing off, not on and silent.
        let unbound = try JSONDecoder().decode(LocationSharedConfig.self, from: Data(#"{"binding": {"dashboardID": 7}, "settings": {"talking": true, "background": true}}"#.utf8))
        XCTAssertNil(unbound.binding)
        XCTAssertFalse(unbound.settings.talking || unbound.settings.background)

        // A round trip keeps everything.
        var full = LocationFixtures.config()
        full.places = [LocationFixtures.home]
        XCTAssertEqual(try JSONDecoder().decode(LocationSharedConfig.self, from: JSONEncoder().encode(full)), full)
    }

    func testADamagedConfigurationFileIsUnreadableNotMissing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("location-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("config.json")
        guard case .missing = LocationSharedStore.readConfig(at: url) else { return XCTFail("expected missing") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        guard case .unreadable = LocationSharedStore.readConfig(at: url) else { return XCTFail("expected unreadable") }
        let config = LocationFixtures.config()
        XCTAssertTrue(LocationSharedStore.saveConfig(config, at: url))
        guard case .value(let stored) = LocationSharedStore.readConfig(at: url) else { return XCTFail("expected value") }
        XCTAssertEqual(stored, config)
    }

    // MARK: Batch

    func testLocationBatchShape() throws {
        var settings = LocationSharingSettings()
        settings.talking = true
        settings.background = true
        settings.retentionDays = 30
        var batch = LocationBatch(sentAt: LocationFixtures.at, settings: settings)
        batch.timeZone = TimeZone(identifier: "Europe/London")!
        batch.places = [LocationFixtures.home, LocationFixtures.work]
        batch.knownPlaces = [LocationFixtures.home, LocationFixtures.work]
        batch.fix = LocationFixtures.fix(latitude: 51.5322, longitude: -0.0754, source: .locate)
        batch.events = [LocationPlaceEvent(id: "e_1", kind: .leave, placeID: "p_home", at: LocationFixtures.at, isPrivate: false)]
        batch.locateID = "l_0123456789abcdef"

        let data = try batch.plaintext()
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["batch_id"] as? String, batch.batchID)
        XCTAssertTrue(LocationIDs.isValidWireID(batch.batchID))
        XCTAssertEqual(json["sent_at"] as? String, "2025-10-14T09:20:00+01:00")
        XCTAssertEqual(json["locate_id"] as? String, "l_0123456789abcdef")

        let sharing = try XCTUnwrap(json["sharing"] as? [String: Any])
        XCTAssertEqual(sharing["talking"] as? Bool, true)
        XCTAssertEqual(sharing["talking_precision"] as? String, "precise")
        XCTAssertEqual(sharing["background_precision"] as? String, "area")
        XCTAssertEqual(sharing["retention_days"] as? Int, 30)
        XCTAssertTrue(sharing["paused_until"] is NSNull)
        XCTAssertEqual(sharing["time_zone"] as? String, "Europe/London")

        let places = try XCTUnwrap(json["places"] as? [[String: Any]])
        XCTAssertEqual(places.count, 2)
        for place in places {
            XCTAssertEqual(Set(place.keys), ["id", "name", "kind", "private"])
        }

        // A locate answers at the background precision.
        let fix = try XCTUnwrap(json["fix"] as? [String: Any])
        XCTAssertEqual(fix["source"] as? String, "locate")
        XCTAssertEqual(fix["precision"] as? String, "area")
        XCTAssertEqual(fix["lat"] as? Double, 51.53)

        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.first?["kind"] as? String, "leave")
        XCTAssertEqual(events.first?["place_id"] as? String, "p_home")
        XCTAssertEqual(events.first?["private"] as? Bool, false)
    }

    func testASettingsOnlyBatchCarriesNoLocation() throws {
        let json = LocationBatch(sentAt: LocationFixtures.at, settings: LocationSharingSettings()).json()
        XCTAssertEqual(Set(json.keys), ["batch_id", "sent_at", "sharing"])
    }

    // MARK: Pause, layers and retention

    func testPauseAndLayersDecideWhatIsShared() {
        let now = LocationFixtures.at
        var settings = LocationSharingSettings()
        XCTAssertFalse(settings.shares(.message, at: now))
        XCTAssertFalse(settings.shares(.place, at: now))

        settings.talking = true
        XCTAssertTrue(settings.shares(.message, at: now))
        XCTAssertTrue(settings.shares(.call, at: now))
        XCTAssertFalse(settings.shares(.visit, at: now))
        XCTAssertFalse(settings.shares(.locate, at: now))

        settings.background = true
        XCTAssertTrue(settings.shares(.locate, at: now))
        XCTAssertEqual(settings.precision(for: .message), .precise)
        XCTAssertEqual(settings.precision(for: .significant), .area)

        settings.pausedUntil = now.addingTimeInterval(3_600)
        XCTAssertTrue(settings.isPaused(at: now))
        XCTAssertFalse(settings.shares(.message, at: now))
        XCTAssertFalse(settings.shares(.place, at: now))
        let formatter = LocationTime.formatter(timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(settings.json(at: now, timeZone: .current, formatter: formatter)["paused_until"] as? String,
                       formatter.string(from: now.addingTimeInterval(3_600)))

        // A pause that has run out shares again and says so.
        XCTAssertTrue(settings.shares(.message, at: now.addingTimeInterval(3_601)))
        XCTAssertTrue(settings.json(at: now.addingTimeInterval(3_601), timeZone: .current, formatter: formatter)["paused_until"] is NSNull)

        settings.pausedUntil = .distantFuture
        XCTAssertTrue(settings.isPaused(at: now.addingTimeInterval(10 * 365 * 86_400)))
    }

    func testRetentionIsOneOfTheHostsChoices() {
        let formatter = LocationTime.formatter()
        var settings = LocationSharingSettings()
        XCTAssertEqual(settings.retentionDays, 7)
        for days in LocationSharingSettings.retentionChoices {
            settings.retentionDays = days
            XCTAssertEqual(settings.json(at: Date(), timeZone: .current, formatter: formatter)["retention_days"] as? Int, days)
        }
        settings.retentionDays = 3
        XCTAssertEqual(settings.json(at: Date(), timeZone: .current, formatter: formatter)["retention_days"] as? Int, 7)
    }

    func testUnsentKeepsTheLatestFixAndTheLastFiftyEvents() {
        var unsent = LocationUnsent()
        let newer = LocationFixtures.fix(latitude: 51.5, longitude: -0.1)
        var older = LocationFixtures.fix(latitude: 51.4, longitude: -0.2)
        older.id = "f_older"
        older.raw.timestamp = LocationFixtures.at.addingTimeInterval(-600)
        unsent.keep(fix: newer, events: [])
        unsent.keep(fix: older, events: [])
        XCTAssertEqual(unsent.fix?.id, "f_test")

        let events = (0..<60).map { index in
            LocationPlaceEvent(id: "e_\(index)", kind: .arrive, placeID: "p_home",
                               at: LocationFixtures.at.addingTimeInterval(Double(index)), isPrivate: false)
        }
        unsent.keep(fix: nil, events: events)
        XCTAssertEqual(unsent.events.count, LocationUnsent.maxEvents)
        XCTAssertEqual(unsent.events.first?.id, "e_10")
        XCTAssertEqual(unsent.events.last?.id, "e_59")

        unsent.remove(fixID: "f_test", eventIDs: Set(unsent.events.prefix(10).map(\.id)))
        XCTAssertNil(unsent.fix)
        XCTAssertEqual(unsent.events.count, 40)
    }

    func testTheHostsKeyErrorsAreToldApartFromOtherConflicts() {
        XCTAssertTrue(LocationSyncEngine.needsNewKey("unknown_key"))
        XCTAssertTrue(LocationSyncEngine.needsNewKey("bad_seal"))
        XCTAssertFalse(LocationSyncEngine.needsNewKey("layer_off"))
    }

    /// The notifier sends its message, not its code, as the 409's detail
    /// (`location_store.py`, `health_store.py`): key loss is recognized from
    /// those messages too, and its other 409s are not key loss.
    func testTheNotifiersKeyLossMessagesAreRecognized() {
        for detail in [
            "This device's location key isn't on this profile; set it up again",
            "The body didn't open with this device's key; set up location sharing again",
            "This device's health key isn\u{2019}t on this profile; set it up again",
            "The body didn't open with this device's key; set up health sync again",
        ] {
            XCTAssertTrue(LocationSyncEngine.needsNewKey(detail), detail)
        }
        for detail in [
            "This profile already keeps location from 8 devices; delete one from Conduit first",
            "This location store was written by a newer plugin; update the plugin",
            "This health store was written by a newer plugin; update the plugin",
            "A gps fix needs precise sharing on",
            "That place rule was just deleted",
        ] {
            XCTAssertFalse(LocationSyncEngine.needsNewKey(detail), detail)
        }
        // A store from a newer plugin (`schema`) asks for a plugin update.
        for detail in [
            "This calendar store was written by a newer plugin; update the plugin",
            "This location store was written by a newer plugin; update the plugin",
            "This health store was written by a newer plugin; update the plugin",
            "schema",
        ] {
            XCTAssertTrue(HostKeyConflict.isNewerPluginStore(detail), detail)
            XCTAssertFalse(HostKeyConflict.isKeyLoss(detail), detail)
        }
        for detail in ["unknown_key", "This profile already keeps location from 8 devices; delete one from Conduit first",
                       "The calendar store is being upgraded; try again in a moment"] {
            XCTAssertFalse(HostKeyConflict.isNewerPluginStore(detail), detail)
        }
    }

    /// A store written by a newer plugin (409 `schema`) waits for a plugin
    /// update: the batch stays to send after it, and the key stays.
    func testANewerPluginsStoreKeepsTheBatchAndAsksForAPluginUpdate() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("location-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let hostPrivate = Curve25519.KeyAgreement.PrivateKey()
        var keyRequests = 0
        let newer = "This location store was written by a newer plugin; update the plugin"
        var ingestDetail = newer
        var ingestFailure: Error?
        let request: LocationSyncEngine.Request = { path, _, body in
            if path.hasSuffix("/key") {
                keyRequests += 1
                let devicePublic = try XCTUnwrap((body?["public_key"] as? String).flatMap(NotificationE2E.base64URLDecoded))
                return [
                    "host_public_key": NotificationE2E.base64URL(hostPrivate.publicKey.rawRepresentation),
                    "kid": LocationCrypto.keyID(devicePublic: devicePublic, hostPublic: hostPrivate.publicKey.rawRepresentation),
                ]
            }
            if path.contains("/status") { return ["ok": true] }
            throw ingestFailure ?? DashboardTicketBridgeError.http(status: 409, detail: ingestDetail)
        }
        let keys = LocationKeyStore.memory()
        let engine = LocationSyncEngine(store: LocationSyncStateStore(url: folder.appendingPathComponent("state.json")), keys: keys)
        let config = LocationFixtures.config()
        let batch = LocationBatch(sentAt: LocationFixtures.at, settings: config.settings)

        let outcome = await engine.send(batch, config: config, request: request)
        XCTAssertEqual(outcome, .failed, "Kept to send once the plugin is updated, not dropped as refused")
        XCTAssertEqual(engine.state.pause, .pluginMissing)
        XCTAssertNotNil(keys.load())
        XCTAssertEqual(keyRequests, 1)

        // A later timeout, or a 404 while the plugin's status route answers,
        // replaces the pause so its own error shows.
        ingestFailure = URLError(.timedOut)
        let timedOut = await engine.send(batch, config: config, request: request)
        XCTAssertEqual(timedOut, .failed)
        XCTAssertNil(engine.state.pause)
        XCTAssertNotNil(engine.lastError)
        ingestFailure = nil
        _ = await engine.send(batch, config: config, request: request)
        XCTAssertEqual(engine.state.pause, .pluginMissing)
        ingestFailure = DashboardTicketBridgeError.http(status: 404, detail: "Not found")
        let notFound = await engine.send(batch, config: config, request: request)
        XCTAssertEqual(notFound, .failed)
        XCTAssertNil(engine.state.pause)
        XCTAssertEqual(engine.lastError, "Not found")
        ingestFailure = nil

        // Once the plugin is updated, a different refusal replaces the
        // pause: it no longer asks for an update.
        ingestDetail = "Background location is off on this profile"
        let next = await engine.send(batch, config: config, request: request)
        XCTAssertEqual(next, .refused)
        XCTAssertNil(engine.state.pause)
        XCTAssertEqual(engine.lastError, ingestDetail)
    }

    func testAnIngest404KeepsTheKeyAndIsThePluginMissingOnlyWhenStatusIsGoneToo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("location-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let hostPrivate = Curve25519.KeyAgreement.PrivateKey()
        var statusExists = true
        var calls: [String] = []
        let request: LocationSyncEngine.Request = { path, _, body in
            calls.append(path)
            if path.hasSuffix("/key") {
                let devicePublic = try XCTUnwrap((body?["public_key"] as? String).flatMap(NotificationE2E.base64URLDecoded))
                return [
                    "host_public_key": NotificationE2E.base64URL(hostPrivate.publicKey.rawRepresentation),
                    "kid": LocationCrypto.keyID(devicePublic: devicePublic, hostPublic: hostPrivate.publicKey.rawRepresentation),
                ]
            }
            if path.contains("/status"), statusExists { return ["ok": true] }
            throw DashboardTicketBridgeError.http(status: 404, detail: "Not Found")
        }
        let keys = LocationKeyStore.memory()
        let engine = LocationSyncEngine(store: LocationSyncStateStore(url: folder.appendingPathComponent("state.json")), keys: keys)
        let config = LocationFixtures.config()
        let batch = LocationBatch(sentAt: LocationFixtures.at, settings: config.settings)

        // Ingest 404s but status answers: a passing failure, and the key stays.
        let passing = await engine.send(batch, config: config, request: request)
        XCTAssertEqual(passing, .failed)
        XCTAssertNil(engine.state.pause)
        let key = try XCTUnwrap(keys.load())
        XCTAssertEqual(calls.filter { $0.hasSuffix("/key") }.count, 1)
        XCTAssertEqual(calls.last, "\(LocationHostClient.base)/status?device_id=\(config.deviceID)")

        // Status gone too: the plugin has no location sync. Still no new key.
        statusExists = false
        let missing = await engine.send(batch, config: config, request: request)
        XCTAssertEqual(missing, .failed)
        XCTAssertEqual(engine.state.pause, .pluginMissing)
        XCTAssertEqual(keys.load(), key)
        XCTAssertEqual(calls.filter { $0.hasSuffix("/key") }.count, 1)
    }

    // #973: a send that fails on the network shows plain words on the
    // settings page, never NSURLErrorDomain text.
    func testAFailedSendShowsPlainLanguageOnTheSettingsPage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("location-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var failure: Error = URLError(.notConnectedToInternet)
        let request: LocationSyncEngine.Request = { _, _, _ in throw failure }
        let engine = LocationSyncEngine(store: LocationSyncStateStore(url: folder.appendingPathComponent("state.json")),
                                        keys: LocationKeyStore.memory())
        let config = LocationFixtures.config()
        let batch = LocationBatch(sentAt: LocationFixtures.at, settings: config.settings)

        let offline = await engine.send(batch, config: config, request: request)
        XCTAssertEqual(offline, .failed)
        XCTAssertEqual(engine.lastError, ConnectionFailure.offline.userMessage)

        // Conduit's own errors keep their text.
        failure = DashboardTicketBridgeError.notReady
        _ = await engine.send(batch, config: config, request: request)
        XCTAssertEqual(engine.lastError, DashboardTicketBridgeError.notReady.errorDescription)

        // So does an HTTP status with no special handling: the page shows
        // the bridge's own wording for it, unchanged by the plain-language
        // mapping.
        let unhandled = DashboardTicketBridgeError.http(status: 502, detail: "Bad gateway")
        failure = unhandled
        let unhandledResult = await engine.send(batch, config: config, request: request)
        XCTAssertEqual(unhandledResult, .failed)
        XCTAssertNotNil(unhandled.errorDescription)
        XCTAssertEqual(engine.lastError, unhandled.errorDescription)
    }

    func testAnUnsentSettingsChangeIsRememberedInTheSharedConfig() throws {
        var config = LocationFixtures.config()
        XCTAssertFalse(config.settingsPending)
        config.settingsPending = true
        XCTAssertTrue(try JSONDecoder().decode(LocationSharedConfig.self, from: JSONEncoder().encode(config)).settingsPending)
        // A config written before the flag existed has nothing pending.
        let old = try JSONDecoder().decode(LocationSharedConfig.self, from: Data(#"{"deviceID": "0123456789abcdef"}"#.utf8))
        XCTAssertFalse(old.settingsPending)
        // A binding missing its labels still binds to its dashboard.
        let binding = try JSONDecoder().decode(LocationBinding.self, from: Data(#"{"dashboardID": "0F5C8A34-1B2D-4E5F-8A9B-0C1D2E3F4A5B"}"#.utf8))
        XCTAssertEqual(binding, LocationBinding(dashboardID: LocationFixtures.dashboardID, profile: "default", host: ""))
        XCTAssertFalse(LocationSyncEngine.statusPath(deviceID: "bad id!").contains("device_id"))
    }

    // MARK: Live voice calls

    func testLocationVoiceSealingMatchesTheNotifierVector() throws {
        // tests/location_vector.json "voice" in hermes-conduit-notifier.
        let devicePrivate = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: XCTUnwrap(NotificationE2E.base64URLDecoded(LocationVector.devicePrivate))
        )
        let key = try LocationCrypto.agree(devicePrivate: devicePrivate, deviceID: LocationVector.deviceID,
                                           hostPublicKey: LocationVector.hostPublic, kid: LocationVector.kid)
        XCTAssertTrue(key.readsByVoice)
        XCTAssertEqual(key.voiceRequestKey?.map { String(format: "%02x", $0) }.joined(),
                       "55cf19b6e1118491dc136b9c94af8af83891b19673744e64c44200411ea93424")
        XCTAssertEqual(key.voiceAnswerKey?.map { String(format: "%02x", $0) }.joined(),
                       "d0c6c9aa90c735b1bcf78368794430d41599835b930730a7ad288fc4a010d53d")
        XCTAssertEqual(
            String(decoding: LocationCrypto.voiceAAD(direction: "request", tool: "conduit_location", kid: key.kid,
                                                     deviceID: key.deviceID, callID: "call-vector-1"), as: UTF8.self),
            "conduit-location/1\nvoice-request\ntool=conduit_location\nkid=\(LocationVector.kid)\ndev=device-vector-1\ncall=call-vector-1"
        )

        let request = #"{"call_id":"call-vector-1","args":{"action":"now"},"provider":"gemini-live"}"#
        let envelope = try LocationCrypto.voiceRequest(tool: "conduit_location", plaintext: Data(request.utf8), key: key,
                                                       callID: "call-vector-1", nonce: ChaChaPoly.Nonce(data: Data(count: 12)))
        XCTAssertEqual(envelope["ct"] as? String,
                       "Pz9gGtPpraVru4dOPXv0TcJEUmj6vNdCFECj8qkccvaUZOZDCGdFpfh-OY-1QHSBAVebQ0JZuQjZ0WpA5M5eiv7WJvwXkjdfpT0FJQHgX7j13RSFFKcJR1KMReU")
        XCTAssertEqual(envelope["tool"] as? String, "conduit_location")
        XCTAssertEqual(envelope["device_id"] as? String, LocationVector.deviceID)
        XCTAssertEqual(envelope["kid"] as? String, LocationVector.kid)
        XCTAssertEqual(envelope["call_id"] as? String, "call-vector-1")

        let answer = ["nonce": "AAAAAAAAAAAAAAAA",
                      "ct": "4L3Edq2Pqul5L7IkSFV1mcpEe62ksOCr_58lP-hpj0EifhOgs7WlfcyZHScBjna8zBbtma66vY4xJQ6FNc_YzA"]
        let result = try LocationCrypto.openVoiceAnswer(answer, tool: "conduit_location", key: key, callID: "call-vector-1")
        XCTAssertEqual((result as? [String: Any])?["ok"] as? Bool, true)
        XCTAssertThrowsError(try LocationCrypto.openVoiceAnswer(answer, tool: "conduit_location", key: key, callID: "call-other"),
                             "An answer is bound to its call")
        XCTAssertThrowsError(try LocationCrypto.openVoiceAnswer(answer, tool: "conduit_health", key: key, callID: "call-vector-1"),
                             "and to its tool")

        // A key saved before voice reads decodes, still seals batches, and reads nothing.
        let old = try JSONDecoder().decode(LocationCrypto.SessionKey.self,
                                           from: Data(#"{"kid":"k","key":"AAAA","deviceID":"device-vector-1"}"#.utf8))
        XCTAssertFalse(old.readsByVoice)
        XCTAssertThrowsError(try LocationCrypto.voiceRequest(tool: "conduit_location", plaintext: Data(), key: old, callID: "c")) { error in
            XCTAssertEqual(error as? LocationCrypto.VoiceFailure, .noVoiceKey)
        }
    }

    func testLocationVoiceReadConsentIsPerModeAndOnlyWhileSharing() throws {
        var config = LocationFixtures.config(background: false, talking: false)
        config.setVoiceRead(LiveVoiceModeName.geminiLive.storageID, allowed: true)
        let now = LocationFixtures.at
        XCTAssertFalse(config.letsVoiceRead("gemini-live", at: now), "Nothing reads while sharing is off")
        config.settings.talking = true
        XCTAssertTrue(config.letsVoiceRead("gemini-live", at: now))
        XCTAssertTrue(config.readsByVoice(at: now))
        XCTAssertFalse(config.letsVoiceRead("gpt-live", at: now), "Each company is its own yes")
        config.settings.pausedUntil = now.addingTimeInterval(3_600)
        XCTAssertFalse(config.letsVoiceRead("gemini-live", at: now), "Nor while paused")
        XCTAssertFalse(config.readsByVoice(at: now), "and the key isn't set up again then")
        XCTAssertTrue(config.letsVoiceRead("gemini-live", at: now.addingTimeInterval(7_200)), "The pause's end lets it read again")
        config.settings.pausedUntil = nil
        let reread = try JSONDecoder().decode(LocationSharedConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(reread.voiceReaders, ["gemini-live"])
        config.binding = nil
        XCTAssertFalse(config.letsVoiceRead("gemini-live", at: now), "Nor while unbound")
        config.setVoiceRead("gemini-live", allowed: false)
        XCTAssertNil(config.voiceReaders)

        // A config written before voice reads lets no mode read.
        let old = try JSONDecoder().decode(LocationSharedConfig.self, from: Data(#"{"deviceID": "0123456789abcdef"}"#.utf8))
        XCTAssertNil(old.voiceReaders)
    }

    func testAKeyFromBeforeVoiceReadsIsSetUpAgainOnlyOnceAVoiceModeMayRead() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("location-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let hostPrivate = Curve25519.KeyAgreement.PrivateKey()
        var keyRequests = 0
        let request: LocationSyncEngine.Request = { path, _, body in
            if path.hasSuffix("/key") {
                keyRequests += 1
                let devicePublic = try XCTUnwrap((body?["public_key"] as? String).flatMap(NotificationE2E.base64URLDecoded))
                return [
                    "host_public_key": NotificationE2E.base64URL(hostPrivate.publicKey.rawRepresentation),
                    "kid": LocationCrypto.keyID(devicePublic: devicePublic, hostPublic: hostPrivate.publicKey.rawRepresentation),
                ]
            }
            return ["ok": true]
        }
        var config = LocationFixtures.config()
        let keys = LocationKeyStore.memory()
        // Agreed after maps, before voice reads: only voice needs a new key here.
        let old = LocationCrypto.SessionKey(kid: "old", key: Data(count: 32), deviceID: config.deviceID,
                                            mapsRequestKey: Data(count: 32), mapsAnswerKey: Data(count: 32))
        XCTAssertTrue(keys.save(old))
        let engine = LocationSyncEngine(store: LocationSyncStateStore(url: folder.appendingPathComponent("state.json")), keys: keys)
        let batch = LocationBatch(sentAt: LocationFixtures.at, settings: config.settings)

        // No voice mode may read: the old key keeps sealing batches.
        let plain = await engine.send(batch, config: config, request: request)
        XCTAssertEqual(plain, .sent)
        XCTAssertEqual(keyRequests, 0)
        XCTAssertEqual(keys.load(), old)
        XCTAssertNil(engine.voiceReadKey(deviceID: config.deviceID))

        // One may: the next send agrees a key that reads, once.
        config.setVoiceRead("grok-live", allowed: true)
        let voice = await engine.send(batch, config: config, request: request)
        XCTAssertEqual(voice, .sent)
        XCTAssertEqual(keyRequests, 1)
        let key = try XCTUnwrap(engine.voiceReadKey(deviceID: config.deviceID))
        XCTAssertTrue(key.readsByVoice)
        XCTAssertNil(engine.voiceReadKey(deviceID: "another-device"))
        _ = await engine.send(batch, config: config, request: request)
        XCTAssertEqual(keyRequests, 1)
    }

    @MainActor
    func testForgettingSpotsDropsTheShopEntriesWaitingToBeSent() {
        var unsent = LocationUnsent()
        unsent.keep(spotEntry: LocationSpotEntry(id: "s_1", spotID: "0.c1", name: "Florist",
                                                 at: LocationFixtures.at, radius: 1_000))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("location-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = LocationSyncEngine(store: LocationSyncStateStore(url: folder.appendingPathComponent("state.json")),
                                        keys: LocationKeyStore.memory())
        let controller = LocationSharingController(engine: engine, config: LocationFixtures.config(background: true),
                                                   unsent: unsent)
        XCTAssertEqual(controller.unsentSpotEntryCount, 1)
        controller.forgetSpots()
        XCTAssertEqual(controller.unsentSpotEntryCount, 0)
        controller.forgetSpots()
        XCTAssertEqual(controller.unsentSpotEntryCount, 0, "Nothing left: a second forget changes nothing")
    }

    @MainActor
    func testAMessageAtThePlaceTheHostHasSendsNoFixAgain() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("location-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = LocationSyncEngine(store: LocationSyncStateStore(url: folder.appendingPathComponent("state.json")),
                                        keys: LocationKeyStore.memory())
        let controller = LocationSharingController(engine: engine, config: LocationFixtures.config(background: false, talking: true),
                                                   unsent: LocationUnsent())
        var now = LocationFixtures.at
        var conditions = DeviceConditions()
        controller.now = { now }
        controller.deviceConditions = { conditions }
        let here = LocationRawFix(latitude: 51.5321, longitude: -0.0755, accuracy: 15, timestamp: now)
        let precision = controller.settings.precision(for: .message)

        XCTAssertTrue(controller.messageFixIsNews(here, precision: precision), "Nothing sent yet")
        controller.noteSent(LocationFixRecord(source: .message, raw: here), at: now)
        now += 5 * 60
        XCTAssertFalse(controller.messageFixIsNews(here, precision: precision))
        now += 6 * 60
        XCTAssertTrue(controller.messageFixIsNews(here, precision: precision), "Ten minutes on: sent again")
        conditions.lowPowerMode = true
        XCTAssertFalse(controller.messageFixIsNews(here, precision: precision), "Low Power Mode waits longer")

        // A visit's fix is the host's latest now: the next message's goes.
        controller.noteSent(LocationFixRecord(source: .visit, raw: here), at: now)
        XCTAssertNil(controller.lastTalkingUpload)
        XCTAssertTrue(controller.messageFixIsNews(here, precision: precision))

        // A forgotten key drops the host's fix.
        controller.noteSent(LocationFixRecord(source: .call, raw: here), at: now)
        XCTAssertFalse(controller.messageFixIsNews(here, precision: precision))
        engine.forgetHost()
        XCTAssertTrue(controller.messageFixIsNews(here, precision: precision))
    }

    func testACachedFixAnswersPreciseOnlyWhenCloseToTheAskedAccuracy() {
        XCTAssertEqual(LocationFixProvider.acceptableCachedAccuracy(for: kCLLocationAccuracyNearestTenMeters), 20)
        XCTAssertEqual(LocationFixProvider.acceptableCachedAccuracy(for: kCLLocationAccuracyHundredMeters), 100)
    }

    func testReadsWithTheSameTimeAndActionKeepDistinctIDs() {
        let reads = LocationRead.parse(["reads": [
            ["at": "2026-10-14T09:00:00Z", "action": "now", "platform": "telegram"],
            ["at": "2026-10-14T09:00:00Z", "action": "now", "platform": "telegram"],
            ["at": "2026-10-14T09:00:00Z", "action": "now", "platform": "telegram"],
        ]])
        XCTAssertEqual(Set(reads.map(\.id)).count, 3)
    }

    func testAReadKeepsItsIDWhenANewerReadArrives() {
        let older = ["at": "2026-10-14T09:00:00Z", "action": "now", "platform": "telegram"]
        let before = LocationRead.parse(["reads": [older]])
        let after = LocationRead.parse(["reads": [["at": "2026-10-14T09:05:00Z", "action": "locate"], older]])
        XCTAssertEqual(after.last?.id, before.first?.id)
    }

    // MARK: On-demand locate

    func testALocateClaimAgesOutUnlessAnswered() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("location-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = E2ESeenStore(url: folder.appendingPathComponent("seen.json"))
        let start = LocationFixtures.at
        XCTAssertTrue(store.claim("r1", namespace: "locate", ttl: 120, now: start))
        // Claimed and not answered: held for a while, then free again.
        XCTAssertFalse(store.claim("r1", namespace: "locate", ttl: 120, now: start.addingTimeInterval(60)))
        XCTAssertTrue(store.claim("r1", namespace: "locate", ttl: 120, now: start.addingTimeInterval(121)))
        // Answered: a replay for good.
        store.markAnswered("r1", namespace: "locate", now: start.addingTimeInterval(122))
        XCTAssertFalse(store.claim("r1", namespace: "locate", ttl: 120, now: start.addingTimeInterval(400)))
        // Released after a failed post: free at once.
        XCTAssertTrue(store.claim("r2", namespace: "locate", ttl: 120, now: start))
        store.remove("r2", namespace: "locate")
        XCTAssertTrue(store.claim("r2", namespace: "locate", ttl: 120, now: start.addingTimeInterval(1)))
    }

    func testTheMonitoredPlacesDigestHoldsNoCoordinates() {
        let digest = LocationBackgroundMonitor.monitoredDigest([LocationFixtures.home, LocationFixtures.work])
        XCTAssertEqual(digest.count, 64)
        XCTAssertFalse(digest.contains("51.5"))
        XCTAssertNotEqual(digest, LocationBackgroundMonitor.monitoredDigest([LocationFixtures.home]))
    }

    func testTheSavedPlacesMonitorNameIsLettersAndDigitsOnly() {
        // CLMonitor(_:) raises "Monitor name is not valid" for anything else,
        // which crashed Conduit on saving the first place.
        let name = LocationBackgroundMonitor.monitorName
        XCTAssertFalse(name.isEmpty)
        XCTAssertTrue(name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII }, name)
    }

    func testAPlaintextLocateIsAnsweredOnlyForTheBoundProfileWhileSharing() throws {
        let payload: [AnyHashable: Any] = [
            "aps": [String: Any](),
            "conduit": [
                "type": "location.requested",
                "profile": "coder",
                "gateway_id": "gw-1",
                "dashboard_id": LocationFixtures.dashboardID.uuidString,
                "locate": ["id": "l_0123456789abcdef"],
            ] as [String: Any],
        ]
        let request = try XCTUnwrap(LocationLocateRequest.parse(payload, records: [], knownGatewayIDs: [], keysProvisioned: false))
        XCTAssertEqual(request.id, "l_0123456789abcdef")
        XCTAssertEqual(request.dashboardID, LocationFixtures.dashboardID)

        let now = LocationFixtures.at
        XCTAssertTrue(request.isAnswered(by: LocationFixtures.config(), at: now))
        XCTAssertFalse(request.isAnswered(by: LocationFixtures.config(background: false, talking: true), at: now))
        XCTAssertFalse(request.isAnswered(by: LocationFixtures.config(pausedUntil: now.addingTimeInterval(60)), at: now))

        var otherProfile = LocationFixtures.config()
        otherProfile.binding?.profile = "default"
        XCTAssertFalse(request.isAnswered(by: otherProfile, at: now))
        var unbound = LocationFixtures.config()
        unbound.binding = nil
        XCTAssertFalse(request.isAnswered(by: unbound, at: now))

        // Once this iPhone holds encryption keys, plaintext isn't trusted.
        XCTAssertNil(LocationLocateRequest.parse(payload, records: [], knownGatewayIDs: [], keysProvisioned: true))
        // Another push type is no locate.
        var notification = payload
        notification["conduit"] = ["type": "turn.completed", "locate": ["id": "l_0123456789abcdef"]] as [String: Any]
        XCTAssertNil(LocationLocateRequest.parse(notification, records: [], knownGatewayIDs: [], keysProvisioned: false))
    }

    func testPlaceRulesCarryAnyPlaceEitherEventAndRepeat() {
        let rules = LocationRule.parse(["ok": true, "rules": [
            ["id": "r1", "what": "Remind me to log my workout", "place_id": "*", "place_name": "any saved place",
             "event": "either", "repeat": "every", "call": false],
            ["id": "r2", "task": "Daily brief", "place_id": "p_0123456789ab", "place_name": "Home",
             "event": "leave", "repeat": "daily", "days": ["mon", "tue"], "call": true],
            ["what": "no id"],
        ] as [[String: Any]]])
        XCTAssertEqual(rules.map(\.id), ["r1", "r2"])
        XCTAssertTrue(rules[0].isAnySavedPlace)
        XCTAssertEqual(rules[0].event, "either")
        XCTAssertEqual(rules[0].repeatMode, "every")
        XCTAssertFalse(rules[1].isAnySavedPlace)
        XCTAssertEqual(rules[1].what, "Daily brief")
        XCTAssertEqual(rules[1].repeatMode, "daily")
        XCTAssertEqual(rules[1].days, "mon, tue")
        XCTAssertTrue(rules[1].calls)
    }

    // MARK: Calls from Hermes

    func testCallSettingsCarryPlaceLimitsOnlyWhenTheHostHasThem() throws {
        let base: [String: Any] = ["enabled": true, "when_asked": true, "min_gap_s": 120, "per_hour": 6, "per_day": 20]
        let old = try XCTUnwrap(HermesCallSettings(json: base))
        XCTAssertNil(old.avoidPlaces)
        XCTAssertNil(old.payload["avoid_places"])
        XCTAssertNil(old.payload["avoid_unknown_place"])

        var withPlaces = base
        withPlaces["avoid_places"] = ["p_home"]
        withPlaces["avoid_unknown_place"] = false
        var settings = try XCTUnwrap(HermesCallSettings(json: withPlaces))
        XCTAssertEqual(settings.avoidPlaces, ["p_home"])
        settings.avoidPlaces?.append("p_work")
        settings.avoidUnknownPlace = true
        XCTAssertEqual(settings.payload["avoid_places"] as? [String], ["p_home", "p_work"])
        XCTAssertEqual(settings.payload["avoid_unknown_place"] as? Bool, true)
    }

    // MARK: Maps (designs/maps-v1-contract.md)

    func testLocationMapsSealingMatchesTheVector() throws {
        // The "maps" vector, shared with the notifier's location store.
        let devicePrivate = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: XCTUnwrap(NotificationE2E.base64URLDecoded(LocationVector.devicePrivate))
        )
        let key = try LocationCrypto.agree(devicePrivate: devicePrivate, deviceID: LocationVector.deviceID,
                                           hostPublicKey: LocationVector.hostPublic, kid: LocationVector.kid)
        XCTAssertTrue(key.answersMaps)
        XCTAssertEqual(key.mapsRequestKey?.map { String(format: "%02x", $0) }.joined(),
                       "b56fa57113c019f2b8d9350fb751e9df8202ecc297577700df829f70dcb51c02")
        XCTAssertEqual(key.mapsAnswerKey?.map { String(format: "%02x", $0) }.joined(),
                       "ae7dd388abc512517a706da57dc4908c316adbdcde58e78de7b4447901f7b71c")
        let id = "m_vector0123456789abcd"
        XCTAssertEqual(
            String(decoding: LocationCrypto.mapsAAD(direction: "maps-request", kid: key.kid, deviceID: key.deviceID, id: id), as: UTF8.self),
            "conduit-location/1\nmaps-request\nkid=\(LocationVector.kid)\ndev=device-vector-1\nid=\(id)"
        )

        let sealed: [String: Any] = [
            "ok": true, "v": 1, "nonce": "AAAAAAAAAAAAAAAA",
            "ct": "3KzdgIkgGzXth_u6OLG69KJdOHs-ZpQ1zZiDXxDHK9uZ0AtkxMhgmNkhL41iwDnHpQXzGDbN22lEZecj-9nl0soF3qC-4eEsiWmQZe-P4WbV9--vJ3krWoZX9yXm9RYEbvtTeAwlewwfp9yGDQleQaQJVr149SEGWfbr-P0j7qze",
        ]
        let body = try LocationCrypto.openMapsRequest(sealed, key: key, id: id)
        XCTAssertEqual(body["id"] as? String, id)
        XCTAssertThrowsError(try LocationCrypto.openMapsRequest(sealed, key: key, id: "m_another0123456789abc"),
                             "A request is bound to its id")
        guard case .success(let request) = MapsRequest.parse(body) else { return XCTFail("The vector's request parses") }
        XCTAssertEqual(request.action, .search)
        XCTAssertEqual(request.query, "pharmacy")
        XCTAssertEqual(request.near, .me)
        XCTAssertEqual(request.limit, 3)
        XCTAssertEqual(request.detail, .area)
        XCTAssertTrue(request.usesMe)

        let plaintext = MapsAnswer.failure(MapsFailure(code: "paused", note: "x")).plaintext(id: id)
        XCTAssertEqual(String(decoding: plaintext, as: UTF8.self), #"{"error":"paused","id":"m_vector0123456789abcd","note":"x","ok":false}"#)
        let answer = try LocationCrypto.mapsAnswer(plaintext: plaintext, key: key, id: id, nonce: ChaChaPoly.Nonce(data: Data(count: 12)))
        XCTAssertEqual(answer["ct"] as? String,
                       "yzg2DSNRs2O4KP-JqCiLxMOu8K8CJxxAedJ7XQZOXPKq6QkWnaDPHRwIucRhLCk52UiCzk_wayZV9utToCcaOzy2na1WTgGCDfBCPTvIe-HYvYTYfhY")
        XCTAssertEqual(answer["device_id"] as? String, LocationVector.deviceID)
        XCTAssertEqual(answer["kid"] as? String, LocationVector.kid)
        XCTAssertEqual(answer["v"] as? Int, 1)

        // A key from before maps opens and seals nothing.
        let old = LocationCrypto.SessionKey(kid: "k", key: Data(count: 32), deviceID: LocationVector.deviceID)
        XCTAssertFalse(old.answersMaps)
        XCTAssertThrowsError(try LocationCrypto.openMapsRequest(sealed, key: old, id: id)) { error in
            XCTAssertEqual(error as? LocationCrypto.MapsFailure, .noMapsKey)
        }
    }

    func testAMapsPushIsTakenOnlyWithAValidID() throws {
        XCTAssertTrue(LocationLocateRequest.isMapsID("m_0123456789abcdefgh"))
        XCTAssertFalse(LocationLocateRequest.isMapsID("m_short"))
        XCTAssertFalse(LocationLocateRequest.isMapsID("l_0123456789abcdefgh"))
        XCTAssertFalse(LocationLocateRequest.isMapsID("m_0123456789abcdef/../x"))
        // A pairing without keys sends the id in the plain stub, like a locate.
        let payload: [AnyHashable: Any] = [
            "aps": [String: Any](),
            "conduit": [
                "type": "location.requested", "profile": "coder", "gateway_id": "gw-1",
                "dashboard_id": LocationFixtures.dashboardID.uuidString,
                "maps": ["id": "m_0123456789abcdefgh"],
            ] as [String: Any],
        ]
        let request = try XCTUnwrap(LocationLocateRequest.parse(payload, records: [], knownGatewayIDs: [], keysProvisioned: false))
        XCTAssertEqual(request.kind, .maps)
        XCTAssertEqual(request.id, "m_0123456789abcdefgh")
        XCTAssertEqual(request.profile, "coder")
        // Once this iPhone holds encryption keys, plaintext isn't trusted.
        XCTAssertNil(LocationLocateRequest.parse(payload, records: [], knownGatewayIDs: [], keysProvisioned: true))
        var badID = payload
        badID["conduit"] = ["type": "location.requested", "maps": ["id": "m_short"]] as [String: Any]
        XCTAssertNil(LocationLocateRequest.parse(badID, records: [], knownGatewayIDs: [], keysProvisioned: false))
        let now = LocationFixtures.at
        XCTAssertTrue(request.isForBinding(of: LocationFixtures.config()))
        // Paused or off still reaches the binding check: the host hears "paused".
        XCTAssertTrue(request.isForBinding(of: LocationFixtures.config(background: false, pausedUntil: now.addingTimeInterval(60))))
        var otherProfile = LocationFixtures.config()
        otherProfile.binding?.profile = "default"
        XCTAssertFalse(request.isForBinding(of: otherProfile))
    }

    func testMapsRequestsTakeTheContractDefaultsAndRefuseWhatTheyCantRun() throws {
        func parse(_ json: [String: Any]) -> MapsRequest? {
            if case .success(let request) = MapsRequest.parse(json) { return request }
            return nil
        }
        let directions = try XCTUnwrap(parse(["id": "m_1", "action": "directions", "to": ["text": "Heathrow T5"],
                                              "mode": "transit", "arrive_by": "2026-10-15T07:40:00+01:00", "depart_at": NSNull()]))
        XCTAssertEqual(directions.from, .me, "from defaults to me")
        XCTAssertEqual(directions.to, [.text("Heathrow T5")])
        XCTAssertEqual(directions.mode, .transit)
        XCTAssertEqual(directions.arriveBy, Date(timeIntervalSince1970: 1_792_046_400))
        XCTAssertNil(directions.near)

        let lookup = try XCTUnwrap(parse(["id": "m_2", "action": "lookup", "query": "Boots\u{0007} Oxford St\n"]))
        XCTAssertNil(lookup.near, "a lookup doesn't use me unless asked")
        XCTAssertFalse(lookup.usesMe)
        XCTAssertEqual(lookup.query, "Boots  Oxford St", "control characters are dropped")

        let times = try XCTUnwrap(parse(["id": "m_3", "action": "travel_times", "from": ["saved": "p_home"],
                                         "to": [["lat": 51.5, "lon": -0.12], ["place_id": "I1234"], ["me": true]] as [[String: Any]]]))
        XCTAssertEqual(times.from, .saved("p_home"))
        XCTAssertEqual(times.to, [.coordinate(latitude: 51.5, longitude: -0.12), .placeID("I1234"), .me])
        XCTAssertTrue(times.usesMe)

        let search = try XCTUnwrap(parse(["id": "m_4", "action": "search", "query": "pharmacy", "limit": 99]))
        XCTAssertEqual(search.near, .me)
        XCTAssertEqual(search.limit, 25)

        XCTAssertNil(parse(["id": "m_5", "action": "search"]), "search needs a query")
        XCTAssertNil(parse(["id": "m_6", "action": "directions", "to": [["text": "A"], ["text": "B"]]]), "one destination")
        XCTAssertNil(parse(["id": "m_7", "action": "travel_times", "to": Array(repeating: ["text": "A"], count: 11)]))
        XCTAssertNil(parse(["id": "m_8", "action": "navigate"]))
        XCTAssertNil(parse(["id": "m_9", "action": "directions", "to": ["lat": 91, "lon": 0]]))
        XCTAssertNil(parse(["id": "m_10", "action": "directions", "to": ["text": "A"], "mode": "flying"]))
    }

    func testAMapsAnswerStaysUnderSixtyFourKilobytes() throws {
        let step: [String: Any] = ["text": String(repeating: "Turn left onto High Street ", count: 7), "distance_m": 400]
        let route: [String: Any] = ["name": "A40", "duration_s": 1520, "distance_m": 18400,
                                    "steps": Array(repeating: step, count: 60)]
        let routes = MapsAnswer.result(["routes": Array(repeating: route, count: 10)]).plaintext(id: "m_1")
        XCTAssertLessThanOrEqual(routes.count, MapsAnswer.maximumBytes)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: routes) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true)

        let place: [String: Any] = ["name": String(repeating: "Boots ", count: 20), "address": String(repeating: "x", count: 300)]
        let places = MapsAnswer.result(["places": Array(repeating: place, count: 400)]).plaintext(id: "m_1")
        XCTAssertLessThanOrEqual(places.count, MapsAnswer.maximumBytes)
        let listed = try XCTUnwrap((JSONSerialization.jsonObject(with: places) as? [String: Any])?["result"] as? [String: Any])
        XCTAssertFalse((listed["places"] as? [Any] ?? []).isEmpty)
    }

    func testTheVoiceMapsToolReadsPlacesAsTheModelSaysThem() throws {
        let places = [LocationFixtures.home, LocationFixtures.work]
        XCTAssertEqual(MapsVoiceTool.ref("me", places: places), .me)
        XCTAssertEqual(MapsVoiceTool.ref(" home ", places: places), .saved("p_home"))
        XCTAssertEqual(MapsVoiceTool.ref("51.5, -0.12", places: places), .coordinate(latitude: 51.5, longitude: -0.12))
        XCTAssertEqual(MapsVoiceTool.ref("place_id:I1234", places: places), .placeID("I1234"))
        XCTAssertEqual(MapsVoiceTool.ref("12 High St, London", places: places), .text("12 High St, London"))
        XCTAssertEqual(MapsVoiceTool.destinations(#"["Home", "12 High St, London"]"#), ["Home", "12 High St, London"])
        XCTAssertEqual(MapsVoiceTool.destinations("12 High St, London"), ["12 High St, London"], "an address's commas don't split it")
        XCTAssertEqual(MapsVoiceTool.destinations(["Home", "Work"]), ["Home", "Work"])

        // GPT-Live sends `to` as a real list; Gemini and Grok as text.
        let to = try XCTUnwrap(MapsVoiceTool.tool.arguments(from: ["action": "travel_times", "to": ["Home", "Work"]])["to"] as? [String])
        XCTAssertEqual(to, ["Home", "Work"])
        XCTAssertEqual(MapsVoiceTool.tool.arguments(from: ["to": "Home"])["to"] as? String, "Home")

        // Without location consent nothing defaults to me, and me or a saved place is refused.
        guard case .success(let anywhere) = MapsVoiceTool.makeRequest(
            action: .search, arguments: ["query": "pharmacy"], places: places, meByDefault: false) else { return XCTFail() }
        XCTAssertNil(anywhere.near)
        XCTAssertFalse(MapsVoiceTool.usesLocation(anywhere))
        guard case .success(let home) = MapsVoiceTool.makeRequest(
            action: .directions, arguments: ["from": "Heathrow", "to": "Home"], places: places, meByDefault: false) else { return XCTFail() }
        XCTAssertTrue(MapsVoiceTool.usesLocation(home))
        guard case .success(let between) = MapsVoiceTool.makeRequest(
            action: .directions, arguments: ["from": "Heathrow", "to": "Paddington"], places: places, meByDefault: false) else { return XCTFail() }
        XCTAssertFalse(MapsVoiceTool.usesLocation(between))
        if case .success = MapsVoiceTool.makeRequest(action: .reverseGeocode, arguments: [:], places: places, meByDefault: false) {
            XCTFail("Reverse geocoding needs a place or the user's position")
        }
    }

    func testEveryIngestSaysWhetherTheHostsOtherProfilesMayRead() throws {
        var settings = LocationSharingSettings()
        settings.talking = true
        XCTAssertFalse(settings.otherProfiles, "only the bound profile reads unless the user says so")
        var sharing = try XCTUnwrap(LocationBatch(sentAt: LocationFixtures.at, settings: settings).json()["sharing"] as? [String: Any])
        XCTAssertEqual(sharing["other_profiles"] as? Bool, false)
        settings.otherProfiles = true
        sharing = try XCTUnwrap(LocationBatch(sentAt: LocationFixtures.at, settings: settings).json()["sharing"] as? [String: Any])
        XCTAssertEqual(sharing["other_profiles"] as? Bool, true)
        // Saved before the switch existed: the bound profile alone (notifier #287).
        let old = try JSONDecoder().decode(LocationSharingSettings.self, from: Data(#"{"talking": true}"#.utf8))
        XCTAssertFalse(old.otherProfiles)
        XCTAssertTrue(try JSONDecoder().decode(LocationSharingSettings.self, from: JSONEncoder().encode(settings)).otherProfiles)
    }

    @MainActor
    func testTheFirstLayerOnRecordsWhetherOtherProfilesMayReadAndASecondKeepsIt() {
        let home = LocationBinding(dashboardID: LocationFixtures.dashboardID, profile: "default", host: "hermes.example.com")
        let other = LocationBinding(dashboardID: UUID(), profile: "default", host: "other.example.com")
        func decide(_ settings: LocationSharingSettings, to destination: LocationBinding? = nil, offered: Bool) -> Bool {
            LocationSharingController.otherProfiles(turningOn: settings, bound: home, to: destination ?? home, offered: offered)
        }
        var settings = LocationSharingSettings()
        XCTAssertTrue(decide(settings, offered: true))
        XCTAssertFalse(decide(settings, offered: false))
        settings.talking = true
        settings.otherProfiles = true
        XCTAssertTrue(decide(settings, offered: false), "the background layer keeps what the user agreed to")
        settings.otherProfiles = false
        XCTAssertFalse(decide(settings, offered: true), "turned off in Settings: a second layer doesn't turn it back on")
        // Off in Settings, then sharing off and on again: the choice stands.
        settings.otherProfilesChosen = true
        settings.talking = false
        XCTAssertFalse(decide(settings, offered: true))
        settings.otherProfiles = true
        XCTAssertTrue(decide(settings, offered: false))
        // On for another host: that host's profiles are asked about afresh.
        XCTAssertFalse(decide(settings, to: other, offered: false))
        settings.otherProfiles = false
        XCTAssertTrue(decide(settings, to: other, offered: true))
    }

    func testEveryIngestSaysThePhoneAnswersMapsAndWhetherTheHostMayToo() throws {
        var settings = LocationSharingSettings()
        settings.background = true
        XCTAssertTrue(settings.mapsHost, "the host may look up maps unless the user keeps them on the iPhone")
        let batch = LocationBatch(sentAt: LocationFixtures.at, settings: settings)
        var sharing = try XCTUnwrap(batch.json()["sharing"] as? [String: Any])
        XCTAssertEqual(sharing["features"] as? [String], ["maps"])
        XCTAssertEqual(sharing["maps_host"] as? Bool, true)
        settings.mapsHost = false
        sharing = try XCTUnwrap(LocationBatch(sentAt: LocationFixtures.at, settings: settings).json()["sharing"] as? [String: Any])
        XCTAssertEqual(sharing["maps_host"] as? Bool, false)
        // Saved before the switch existed: the host may.
        let old = try JSONDecoder().decode(LocationSharingSettings.self, from: Data(#"{"talking": true}"#.utf8))
        XCTAssertTrue(old.mapsHost)
        XCTAssertFalse(try JSONDecoder().decode(LocationSharingSettings.self, from: JSONEncoder().encode(settings)).mapsHost)

        // A key from before maps can't open a request: the host isn't told.
        func sealedSharing(_ key: LocationCrypto.SessionKey) throws -> [String: Any] {
            let body = try LocationIngest.body(batch, key: key)
            let nonce = try XCTUnwrap((body["nonce"] as? String).flatMap(NotificationE2E.base64URLDecoded))
            let sealed = try XCTUnwrap((body["ct"] as? String).flatMap(NotificationE2E.base64URLDecoded))
            let plaintext = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: nonce + sealed), using: SymmetricKey(data: key.key),
                                                authenticating: LocationCrypto.aad(kid: key.kid, deviceID: key.deviceID, batchID: batch.batchID))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
            return try XCTUnwrap(json["sharing"] as? [String: Any])
        }
        let old32 = LocationCrypto.SessionKey(kid: "k", key: Data(count: 32), deviceID: "device-vector-1")
        XCTAssertNil(try sealedSharing(old32)["features"])
        var current = old32
        current.mapsRequestKey = Data(count: 32)
        current.mapsAnswerKey = Data(count: 32)
        XCTAssertEqual(try sealedSharing(current)["features"] as? [String], ["maps"])
    }

    func testAKeyFromBeforeMapsIsSetUpAgainOnceWhileSharingInTheBackground() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("location-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let hostPrivate = Curve25519.KeyAgreement.PrivateKey()
        var keyRequests = 0
        let request: LocationSyncEngine.Request = { path, _, body in
            if path.hasSuffix("/key") {
                keyRequests += 1
                let devicePublic = try XCTUnwrap((body?["public_key"] as? String).flatMap(NotificationE2E.base64URLDecoded))
                return [
                    "host_public_key": NotificationE2E.base64URL(hostPrivate.publicKey.rawRepresentation),
                    "kid": LocationCrypto.keyID(devicePublic: devicePublic, hostPublic: hostPrivate.publicKey.rawRepresentation),
                ]
            }
            return ["ok": true]
        }
        let keys = LocationKeyStore.memory()
        let talkingOnly = LocationFixtures.config(background: false, talking: true)
        let old = LocationCrypto.SessionKey(kid: "old", key: Data(count: 32), deviceID: talkingOnly.deviceID)
        XCTAssertTrue(keys.save(old))
        let engine = LocationSyncEngine(store: LocationSyncStateStore(url: folder.appendingPathComponent("state.json")), keys: keys)

        // Only the talking layer: the host never asks this iPhone, the key stays.
        _ = await engine.send(LocationBatch(sentAt: LocationFixtures.at, settings: talkingOnly.settings), config: talkingOnly, request: request)
        XCTAssertEqual(keyRequests, 0)
        XCTAssertEqual(keys.load(), old)

        var background = talkingOnly
        background.settings.background = true
        let batch = LocationBatch(sentAt: LocationFixtures.at, settings: background.settings)
        let sent = await engine.send(batch, config: background, request: request)
        XCTAssertEqual(sent, .sent)
        XCTAssertEqual(keyRequests, 1)
        XCTAssertEqual(keys.load()?.answersMaps, true)
        _ = await engine.send(batch, config: background, request: request)
        XCTAssertEqual(keyRequests, 1)
    }

    // MARK: Apple Maps datum in mainland China (#1122)

    func testMapDatumShiftsMainlandChinaToWhereAppleMapsDrawsIt() {
        let tiananmen = CLLocationCoordinate2D(latitude: 39.9087, longitude: 116.3975)
        let onMap = MapDatum.toMap(tiananmen)
        XCTAssertEqual(onMap.latitude, 39.910103, accuracy: 0.000005)
        XCTAssertEqual(onMap.longitude, 116.403744, accuracy: 0.000005)
        let shift = CLLocation(latitude: tiananmen.latitude, longitude: tiananmen.longitude)
            .distance(from: CLLocation(latitude: onMap.latitude, longitude: onMap.longitude))
        XCTAssertGreaterThan(shift, 300)
    }

    func testMapDatumRegionParsesEveryPoint() {
        let tokens = MapDatumRegion.mainland.split(whereSeparator: \.isWhitespace)
        XCTAssertGreaterThan(tokens.count, 1_000)
        for token in tokens + MapDatumRegion.excluded.flatMap({ $0.split(whereSeparator: \.isWhitespace) }) {
            let parts = token.split(separator: ",")
            XCTAssertEqual(parts.count, 2, String(token))
            XCTAssertNotNil(parts.first.flatMap { Double($0) }, String(token))
            XCTAssertNotNil(parts.last.flatMap { Double($0) }, String(token))
        }
    }

    func testMapDatumReadsAMapPointBackToTheFixDatum() {
        for fix in [CLLocationCoordinate2D(latitude: 39.9087, longitude: 116.3975),
                    CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
                    CLLocationCoordinate2D(latitude: 22.5431, longitude: 114.0579),
                    CLLocationCoordinate2D(latitude: 30.5728, longitude: 104.0668)] {
            let back = MapDatum.fromMap(MapDatum.toMap(fix))
            let error = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
                .distance(from: CLLocation(latitude: back.latitude, longitude: back.longitude))
            XCTAssertLessThan(error, 0.01)
        }
    }

    func testMapDatumLeavesPlacesOutsideMainlandChinaAlone() {
        let outside: [(Double, Double)] = [
            (51.5007, -0.1246),   // London
            (25.0330, 121.5654),  // Taipei
            (23.5700, 119.5800),  // Penghu
            (24.4300, 118.3200),  // Kinmen
            (26.1600, 119.9500),  // Matsu
            (22.2819, 114.1582),  // Hong Kong Central
            (22.4450, 114.0200),  // Yuen Long
            (22.5280, 114.1130),  // Lo Wu
            (22.2930, 114.1700),  // Victoria Harbour
            (22.2400, 114.1500),  // off Aberdeen
            (22.1987, 113.5439),  // Macau
            (22.1900, 113.5600),  // between Macau and Taipa
            (47.9184, 106.9177),  // Ulaanbaatar
            (48.9683, 89.9625),   // Ölgii
            (42.8700, 74.6000),   // Bishkek
            (27.7000, 85.3200),   // Kathmandu
            (27.4700, 89.6400),   // Thimphu
            (21.0300, 105.8500),  // Hanoi
            (40.1000, 124.4000),  // Sinuiju
            (50.2700, 127.5300),  // Blagoveshchensk
            (37.5665, 126.9780),  // Seoul
            (37.9700, 124.6700),  // Baengnyeong
        ]
        for (latitude, longitude) in outside {
            let place = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            XCTAssertFalse(MapDatum.isShifted(place), "\(latitude), \(longitude)")
            for converted in [MapDatum.toMap(place), MapDatum.fromMap(place)] {
                XCTAssertEqual(converted.latitude, place.latitude)
                XCTAssertEqual(converted.longitude, place.longitude)
            }
        }
        let mainland: [(Double, Double)] = [
            (22.5431, 114.0579),  // Shenzhen
            (22.4800, 113.9100),  // Shekou
            (22.2186, 113.5489),  // Gongbei, Zhuhai
            (22.1300, 113.5200),  // Hengqin
            (24.4798, 118.0894),  // Xiamen
            (30.0160, 122.2070),  // Zhoushan
            (18.2528, 109.5119),  // Sanya
            (40.1270, 124.3900),  // Dandong
            (50.2450, 127.4900),  // Heihe
            (43.8256, 87.6168),   // Urumqi
            (39.4700, 75.9900),   // Kashgar
        ]
        for (latitude, longitude) in mainland {
            XCTAssertTrue(MapDatum.isShifted(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)), "\(latitude), \(longitude)")
        }
    }
}
