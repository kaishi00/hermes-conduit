//
//  LocationSpotsTests.swift
//  ConduitTests
//
//  Walking past (LocationSpots, PulseSpotWatcher): the sealed reply against
//  the notifier's shared vector, what goes in a batch, unsent entries, and
//  the watcher's first state and entries.
//

import CoreLocation
import CryptoKit
import XCTest
@testable import Conduit

private enum SpotsVector {
    // tests/location_vector.json "spots" in hermes-conduit-notifier.
    static let kid = "4186c0bc93b7b264b5991464ab3e4c1f"
    static let key = "e97fd9902f44b9a9c5ffacd40612f58a471a56b5ab28c6e66f87efc04840fa6e"
    static let deviceID = "device-vector-1"
    static let batchID = "batch-vector-1"
    static let aad = "conduit-location/1\nspots\nkid=4186c0bc93b7b264b5991464ab3e4c1f\ndev=device-vector-1\nbatch=batch-vector-1"
    static let nonce = "AAAAAAAAAAAAAAAB"
    static let ct = "RSb-7Nwq_9jt-B7HWAv_SPltlJEc6LxRt7X3SZpkRAPmQpIwx2XqSgbozttH4e7PXIBz7--wx6SvijJ4rB52grSIcH1P5lW--qyBlDHqv8LF8X36fLS865DAjZ1lHblttmF43FSZy6jgBAUa4kWH3830Do-kgxQGJqhlLIsAmlKOJZYXJwtuI4MbFThcMw6ZptFoTpazrq8FEoHF_G0"

    static func sessionKey() -> LocationCrypto.SessionKey {
        let bytes = stride(from: 0, to: key.count, by: 2).compactMap { offset -> UInt8? in
            let start = key.index(key.startIndex, offsetBy: offset)
            return UInt8(key[start..<key.index(start, offsetBy: 2)], radix: 16)
        }
        return LocationCrypto.SessionKey(kid: kid, key: Data(bytes), deviceID: deviceID)
    }
}

extension NotificationE2ETests {
    // MARK: The sealed reply

    func testSpotsReplyOpensTheNotifierVector() throws {
        XCTAssertEqual(String(decoding: LocationCrypto.spotsAAD(kid: SpotsVector.kid, deviceID: SpotsVector.deviceID,
                                                                batchID: SpotsVector.batchID), as: UTF8.self),
                       SpotsVector.aad)
        let key = SpotsVector.sessionKey()
        let reply = try XCTUnwrap(LocationCrypto.openSpotsReply(["nonce": SpotsVector.nonce, "ct": SpotsVector.ct],
                                                               key: key, batchID: SpotsVector.batchID))
        let watches = LocationSpotWatch.parse(reply)
        XCTAssertEqual(watches.count, 1)
        XCTAssertEqual(watches.first?.id, "0.c12")
        XCTAssertEqual(watches.first?.query, "florist")
        XCTAssertEqual(watches.first?.intent, "opportunity")
        XCTAssertEqual(watches.first?.walkRadius, 750)
        XCTAssertEqual(watches.first?.driveRadius, 3_000)
        XCTAssertEqual(watches.first?.until, ISO8601DateFormatter().date(from: "2026-10-28T00:00:00Z"))
        // Another batch's reply doesn't open, nor a missing one.
        XCTAssertNil(LocationCrypto.openSpotsReply(["nonce": SpotsVector.nonce, "ct": SpotsVector.ct],
                                                   key: key, batchID: "batch-vector-2"))
        XCTAssertNil(LocationCrypto.openSpotsReply(nil, key: key, batchID: SpotsVector.batchID))
    }

    func testSpotWatchesThatDontParseAreDroppedAndCirclesKeptInRange() {
        let reply: [String: Any] = ["spots": [
            ["id": "0.c1", "query": "pharmacy", "until": "2026-10-28T09:00:00+01:00", "intent": "errand",
             "radius": ["walk": 10, "drive": 90_000]],
            ["id": "nope", "query": "florist", "until": "2026-10-28T00:00:00Z", "radius": ["walk": 750, "drive": 3_000]],
            ["id": "0.i2", "query": "", "until": "2026-10-28T00:00:00Z", "radius": ["walk": 750, "drive": 3_000]],
            ["id": "1.i3", "query": "Costco", "until": "soon", "radius": ["walk": 100, "drive": 100]],
            ["id": "1.i4", "query": "Costco", "until": "2026-10-28T00:00:00Z"],
        ]]
        let watches = LocationSpotWatch.parse(reply)
        XCTAssertEqual(watches.map(\.id), ["0.c1"])
        XCTAssertEqual(watches.first?.walkRadius, 50)
        XCTAssertEqual(watches.first?.driveRadius, 5_000)
        XCTAssertEqual(watches.first?.radius(driving: true), 5_000)
        XCTAssertEqual(watches.first?.intent, "errand")
        // An intent the app doesn't know is an opportunity.
        let unknown: [String: Any] = ["spots": [["id": "0.c1", "query": "florist", "until": "2026-10-28T00:00:00Z",
                                                 "intent": "whenever", "radius": ["walk": 750, "drive": 3_000]]]]
        XCTAssertEqual(LocationSpotWatch.parse(unknown).first?.intent, "opportunity")
        // The app reads the host's dates with fractions too.
        let fraction: [String: Any] = ["spots": [["id": "0.c1", "query": "florist", "until": "2026-10-28T00:00:00.250Z",
                                                  "radius": ["walk": 750, "drive": 3_000]]]]
        XCTAssertEqual(LocationSpotWatch.parse(fraction, date: LocationHostDates.parse).count, 1)
    }

    // MARK: The batch

    func testABatchSaysItWatchesShopsOnlyWhenItDoes() throws {
        var batch = LocationBatch(sentAt: Date(timeIntervalSince1970: 1_760_430_000), settings: LocationSharingSettings())
        XCTAssertNil(batch.json()["spot_entries"])
        batch.spotEntries = []
        batch.spotsRoom = 8
        XCTAssertEqual((batch.json()["spot_entries"] as? [Any])?.count, 0)
        XCTAssertEqual(batch.json()["spots_room"] as? Int, 8)
        batch.spotEntries = [LocationSpotEntry(
            id: "s_test1", spotID: "0.c12", name: "Bloom & Co", at: Date(timeIntervalSince1970: 1_760_430_000),
            fixAt: Date(timeIntervalSince1970: 1_760_430_009), distance: 412.4, accuracy: 8.6, speed: 1.26, radius: 750)]
        let entry = try XCTUnwrap((batch.json()["spot_entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["id"] as? String, "s_test1")
        XCTAssertEqual(entry["spot_id"] as? String, "0.c12")
        XCTAssertEqual(entry["name"] as? String, "Bloom & Co")
        XCTAssertEqual(entry["distance_m"] as? Int, 412)
        XCTAssertEqual(entry["accuracy_m"] as? Int, 9)
        XCTAssertEqual(entry["speed_mps"] as? Double, 1.3)
        XCTAssertEqual(entry["radius_m"] as? Int, 750)
        XCTAssertNotNil(entry["fix_at"])
        // No coordinates, ever.
        XCTAssertNil(entry["lat"])
        XCTAssertNil(entry["lon"])
    }

    func testUnsentFromBeforeSpotEntriesStillOpens() throws {
        let old = Data(#"{"events":[],"inside":{"p_home":true}}"#.utf8)
        let unsent = try JSONDecoder().decode(LocationUnsent.self, from: old)
        XCTAssertEqual(unsent.inside, ["p_home": true])
        XCTAssertTrue(unsent.spotEntries.isEmpty)
        XCTAssertTrue(unsent.isEmpty)
    }

    func testUnsentSpotEntriesAreKeptOnceAndTheNewestFew() {
        var unsent = LocationUnsent()
        let start = Date(timeIntervalSince1970: 1_760_430_000)
        for index in 0..<(LocationSpotEntry.maxUnsent + 3) {
            unsent.keep(spotEntry: LocationSpotEntry(id: "s_\(index)", spotID: "0.c1", name: "Shop",
                                                     at: start.addingTimeInterval(Double(index)), radius: 100))
        }
        unsent.keep(spotEntry: LocationSpotEntry(id: "s_22", spotID: "0.c1", name: "Shop", at: start, radius: 100))
        XCTAssertEqual(unsent.spotEntries.count, LocationSpotEntry.maxUnsent)
        XCTAssertEqual(unsent.spotEntries.first?.id, "s_3")
        XCTAssertFalse(unsent.isEmpty)
        unsent.remove(fixID: nil, eventIDs: [], spotEntryIDs: Set(unsent.spotEntries.map(\.id)))
        XCTAssertTrue(unsent.isEmpty)
    }

    // MARK: The watcher

    @MainActor
    func testTheFirstStateOfAShopIsWhereThePhoneIsNotAnEntry() {
        let now = Date(timeIntervalSince1970: 1_760_430_000)
        var state = PulseSpotState()
        state.watches = [LocationSpotWatch(id: "0.c12", query: "florist", until: now.addingTimeInterval(3_600),
                                           intent: "opportunity", walkRadius: 750, driveRadius: 3_000)]
        state.spots = [PulseSpotState.Spot(id: "s1", watchID: "0.c12", name: "Bloom & Co",
                                           latitude: 51.53, longitude: -0.07, radius: 750)]
        var saved: [PulseSpotState] = []
        let watcher = PulseSpotWatcher(state: state, save: { saved.append($0) })
        watcher.hasMonitor = { false }
        watcher.now = { now }
        var entered: [(String, Date)] = []
        watcher.entered = { spot, at in entered.append((spot.name, at)) }

        watcher.handle(identifier: "s1", state: .satisfied, at: now)
        XCTAssertTrue(entered.isEmpty, "already inside when it started watching")
        watcher.handle(identifier: "s1", state: .unsatisfied, at: now.addingTimeInterval(60))
        watcher.handle(identifier: "s1", state: .satisfied, at: now.addingTimeInterval(120))
        XCTAssertEqual(entered.map(\.0), ["Bloom & Co"])
        XCTAssertEqual(entered.first?.1, now.addingTimeInterval(120))
        XCTAssertEqual(saved.last?.inside, ["s1": true])
        // A shop no longer watched, or one whose watch ran out, is no entry.
        watcher.handle(identifier: "s9", state: .satisfied, at: now)
        watcher.now = { now.addingTimeInterval(7_200) }
        watcher.handle(identifier: "s1", state: .unsatisfied, at: now.addingTimeInterval(7_000))
        watcher.handle(identifier: "s1", state: .satisfied, at: now.addingTimeInterval(7_100))
        XCTAssertEqual(entered.count, 1)
    }

    @MainActor
    func testShopsGetWhatSavedPlacesLeaveOfIOSsTwenty() {
        let watcher = PulseSpotWatcher(state: PulseSpotState(), save: { _ in })
        watcher.hasMonitor = { false }
        watcher.configure(enabled: true, savedPlaces: 3)
        XCTAssertEqual(watcher.room, 10)
        watcher.configure(enabled: true, savedPlaces: 14)
        XCTAssertEqual(watcher.room, 6)
        watcher.configure(enabled: true, savedPlaces: 20)
        XCTAssertEqual(watcher.room, 0)
        watcher.configure(enabled: false, savedPlaces: 0)
        XCTAssertEqual(watcher.room, 0)
        XCTAssertFalse(watcher.watching)
    }
}
