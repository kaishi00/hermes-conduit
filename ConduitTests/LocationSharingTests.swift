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

    func testACachedFixAnswersPreciseOnlyWhenCloseToTheAskedAccuracy() {
        XCTAssertEqual(LocationFixProvider.acceptableCachedAccuracy(for: kCLLocationAccuracyNearestTenMeters), 20)
        XCTAssertEqual(LocationFixProvider.acceptableCachedAccuracy(for: kCLLocationAccuracyHundredMeters), 100)
    }

    func testReadsWithTheSameTimeAndActionKeepDistinctIDs() {
        let reads = LocationRead.parse(["reads": [
            ["at": "2026-10-14T09:00:00Z", "action": "now", "platform": "telegram"],
            ["at": "2026-10-14T09:00:00Z", "action": "now", "platform": "telegram"],
        ]])
        XCTAssertEqual(Set(reads.map(\.id)).count, 2)
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
}
