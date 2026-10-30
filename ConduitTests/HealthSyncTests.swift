//
//  HealthSyncTests.swift
//  ConduitTests
//
//  Health sharing: the sealing matches the
//  notifier's vector, nights are summarized by the fixed rule, batches keep
//  windows whole, and a pass sets up a key, sends sealed batches and moves
//  its cursors only after the host has taken them. Written as an extension
//  of an existing suite: the CI test planner is at capacity for new
//  XCTestCase classes.
//

import CryptoKit
import XCTest
@testable import Conduit

@MainActor
extension HermesVoiceGatewayTimeoutTests {
    // The notifier's tests/health_vector.json: both sides must agree.
    private static let vectorHostPublic = "j0DFrbaPJWJK5bIU6nZ6bslNgp09e14a0bpvPiE4KF8"
    private static let vectorDevicePrivate = "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8"
    private static let vectorKid = "568703226d4ca837141b5eebba642b64"

    func testSealingMatchesTheNotifierVector() throws {
        let raw = try XCTUnwrap(NotificationE2E.base64URLDecoded(Self.vectorDevicePrivate))
        let device = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        XCTAssertEqual(NotificationE2E.base64URL(device.publicKey.rawRepresentation), "NYBy1jZYgNGu6jKa35EhODhR7SGijjt16WXQ0s0WYlQ")
        let hostPublic = try XCTUnwrap(NotificationE2E.base64URLDecoded(Self.vectorHostPublic))
        XCTAssertEqual(HealthSyncCrypto.keyID(devicePublic: device.publicKey.rawRepresentation, hostPublic: hostPublic), Self.vectorKid)

        let key = try HealthSyncCrypto.agree(devicePrivate: device, deviceID: "device-vector-1",
                                             hostPublicKey: Self.vectorHostPublic, kid: Self.vectorKid)
        XCTAssertEqual(key.key.map { String(format: "%02x", $0) }.joined(),
                       "b5b0006ac3d4b1ff1c5bc4d29245fbe723ea03ffdd9ee3a38b8458bef47c2332")

        let envelope = try HealthSyncCrypto.envelope(
            plaintext: Data(#"{"batch_id":"batch-vector-1"}"#.utf8), key: key,
            deviceID: "device-vector-1", batchID: "batch-vector-1",
            nonce: try ChaChaPoly.Nonce(data: Data(count: 12)))
        XCTAssertEqual(envelope["nonce"] as? String, "AAAAAAAAAAAAAAAA")
        XCTAssertEqual(envelope["ct"] as? String, "TcrUbI4YW2m833vWYhvn-tbMWAmZ4-XCdXzRzWT4wxEnlx8N7Z45UyvsHAt6")
        XCTAssertEqual(envelope["kid"] as? String, Self.vectorKid)

        XCTAssertThrowsError(try HealthSyncCrypto.agree(devicePrivate: device, deviceID: "device-vector-1",
                                                        hostPublicKey: Self.vectorHostPublic, kid: "0000"),
                             "An answer for another key is refused")
    }

    func testNightPicksTheWatchAndNamesTheMorning() throws {
        let calendar = Self.healthCalendar
        let watch = [
            sleepSegment("w1", .core, "2026-10-12T23:00:00Z", "2026-10-13T02:00:00Z", "Apple Watch", watch: true),
            sleepSegment("w2", .awake, "2026-10-13T02:00:00Z", "2026-10-13T02:10:00Z", "Apple Watch", watch: true),
            sleepSegment("w3", .deep, "2026-10-13T02:10:00Z", "2026-10-13T03:10:00Z", "Apple Watch", watch: true),
            sleepSegment("w4", .rem, "2026-10-13T03:10:00Z", "2026-10-13T06:10:00Z", "Apple Watch", watch: true),
        ]
        // More time asleep, but the Watch wins.
        let other = [sleepSegment("o1", .asleep, "2026-10-12T22:00:00Z", "2026-10-13T08:00:00Z", "Sleep App", watch: false)]
        let nights = HealthSleepNights.summaries(other + watch, calendar: calendar)
        let night = try XCTUnwrap(nights.first)
        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(night.date, "2026-10-13")
        XCTAssertEqual(night.source, "Apple Watch")
        XCTAssertEqual(night.data["asleep"], .number(420))
        XCTAssertEqual(night.data["deep"], .number(60))
        XCTAssertEqual(night.data["rem"], .number(180))
        XCTAssertEqual(night.data["core"], .number(180))
        XCTAssertEqual(night.data["awake"], .number(10))
        XCTAssertEqual(night.data["wake_count"], .number(1))
        XCTAssertEqual(night.data["in_bed"], .number(430), "No in-bed samples: first to last")
        XCTAssertEqual(night.data["bedtime"], .text("2026-10-12T23:00:00Z"))
        XCTAssertNil(night.data["unspecified"])

        // Without a Watch, the source with the most sleep.
        let phoneOnly = HealthSleepNights.summaries(
            other + [sleepSegment("p1", .asleep, "2026-10-13T00:00:00Z", "2026-10-13T05:00:00Z", "iPhone", watch: false)],
            calendar: calendar)
        XCTAssertEqual(phoneOnly.first?.source, "Sleep App")
        XCTAssertEqual(phoneOnly.first?.data["unspecified"], .number(600))

        // A nap after noon belongs to the next morning's night.
        XCTAssertEqual(HealthSleepNights.nightEnding(date("2026-10-13T13:00:00Z"), calendar: calendar), date("2026-10-14T00:00:00Z"))
        let window = HealthSleepNights.window(mornings: date("2026-10-10T00:00:00Z"), until: date("2026-10-13T00:00:00Z"), calendar: calendar)
        XCTAssertEqual(window.from, date("2026-10-09T12:00:00Z"))
        XCTAssertEqual(window.to, date("2026-10-12T12:00:00Z"))
    }

    func testBatchSplitKeepsWindowsWhole() {
        var batch = HealthBatch(computedAt: date("2026-10-13T12:00:00Z"), deviceName: "iPhone", timeZone: Self.healthCalendar.timeZone,
                                categories: [.activity], detailed: [])
        let bucket = HealthBucket(start: date("2026-10-13T00:00:00Z"), end: date("2026-10-13T01:00:00Z"), sum: 12)
        batch.windows = (0..<3).map { index in
            HealthWindow(metric: "steps", grain: .hour, unit: "count", from: date("2026-10-13T00:00:00Z"),
                         to: date("2026-10-14T00:00:00Z"), buckets: Array(repeating: bucket, count: 4 + index))
        }
        batch.deleted = ["a", "b"]
        let parts = batch.split(limit: 8)
        XCTAssertEqual(parts.map { $0.windows.map(\.buckets.count) }, [[4], [5], [6]], "Each window whole")
        XCTAssertEqual(parts.flatMap(\.deleted), ["a", "b"])
        XCTAssertTrue(parts.allSatisfy { $0.itemCount <= 8 })

        let json = parts[0].json()
        XCTAssertEqual(json["categories"] as? [String], ["activity"])
        let window = (json["windows"] as? [[String: Any]])?.first
        XCTAssertEqual(window?["from"] as? String, "2026-10-13T00:00:00Z")
        XCTAssertEqual((window?["buckets"] as? [[String: Any]])?.first?["sum"] as? Double, 12)
    }

    func testPassSetsUpAKeySendsSealedBatchesAndMovesItsCursors() async throws {
        let source = FakeHealthSource()
        let host = FakeHealthHost()
        let engine = makeHealthEngine(source: source)
        let preferences = healthPreferences(history: .days30)

        let outcome = await engine.sync(preferences: preferences, deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(outcome, .synced)
        XCTAssertEqual(host.keyRequests, 1)
        XCTAssertFalse(host.batches.isEmpty)
        // Every batch opens with the agreed key, so only the host reads it.
        XCTAssertTrue(host.batches.allSatisfy { ($0["windows"] as? [[String: Any]]) != nil })
        let metrics = Set(host.batches.flatMap { ($0["windows"] as? [[String: Any]] ?? []).compactMap { $0["metric"] as? String } })
        XCTAssertTrue(metrics.contains("steps"))
        XCTAssertTrue(metrics.contains("sleep"))
        XCTAssertFalse(metrics.contains("heart_rate"), "Only the categories turned on")
        XCTAssertEqual(engine.state.backfillCursor, engine.state.historyStart, "All 30 days are in")
        XCTAssertEqual(engine.state.anchors["workouts"], Data("w-anchor".utf8))
        XCTAssertNil(engine.state.anchors["samples.steps"], "No raw readings without detailed readings")
        XCTAssertNotNil(engine.state.lastSync)

        // The next pass reuses the key.
        _ = await engine.sync(preferences: preferences, deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(host.keyRequests, 1)

        // A host that lost the key asks for a new one next time.
        host.forgetKey()
        _ = await engine.sync(preferences: preferences, deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(host.keyRequests, 2)
    }

    func testRecentDaysSendOnlyTheWindowsThatChanged() async throws {
        let source = FakeHealthSource()
        let host = FakeHealthHost()
        var now = Self.healthDate("2026-10-13T12:00:00Z")
        let engine = makeHealthEngine(source: source, now: { now })
        let preferences = healthPreferences(history: .days30)
        func windows(since count: Int) -> [String] {
            host.batches.dropFirst(count).flatMap { ($0["windows"] as? [[String: Any]] ?? []).map {
                "\($0["metric"] as? String ?? "")/\($0["grain"] as? String ?? "")"
            } }
        }

        _ = await engine.sync(preferences: preferences, deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(engine.state.recentWholeAt, now)
        XCTAssertFalse(engine.state.recentWindows?.isEmpty ?? true)

        // Nothing changed in Apple Health: nothing goes.
        var sent = host.batches.count
        now += 60
        _ = await engine.sync(preferences: preferences, deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(host.batches.count, sent)

        // New steps: only the steps windows go again.
        source.sums[.steps] = 250
        now += 60
        _ = await engine.sync(preferences: preferences, deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(windows(since: sent), ["steps/day", "steps/hour"])

        // The host kept a newer computation of some window: those go again.
        source.sums[.steps] = 300
        host.staleWindows = 1
        sent = host.batches.count
        now += 60
        _ = await engine.sync(preferences: preferences, deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(windows(since: sent), ["steps/day", "steps/hour"])
        host.staleWindows = 0
        sent = host.batches.count
        now += 60
        _ = await engine.sync(preferences: preferences, deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(windows(since: sent), ["steps/day", "steps/hour"], "Not taken, so sent again")
        sent = host.batches.count
        now += 60
        _ = await engine.sync(preferences: preferences, deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(host.batches.count, sent)

        // Nothing new for a quarter hour: an empty upload, so the host
        // knows this phone still shares.
        now += ContextUploadPolicy.healthKeepalive
        _ = await engine.sync(preferences: preferences, deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(host.batches.count, sent + 1)
        XCTAssertEqual((host.batches.last?["windows"] as? [Any])?.count, 0)
        XCTAssertEqual(host.batches.last?["categories"] as? [String], ["activity", "sleep", "workouts"])
        sent = host.batches.count

        // Low Data Mode: still only what changed, even past six hours (and
        // the empty upload that says so).
        now += ContextUploadPolicy.healthWholeResend
        _ = await engine.sync(preferences: preferences, deadline: .distantFuture,
                              options: HealthPassOptions(lowData: true), request: host.handle)
        XCTAssertEqual(host.batches.count, sent + 1)
        XCTAssertTrue(windows(since: sent).isEmpty)
        sent = host.batches.count

        // Otherwise every six hours, and on Sync now, everything goes again.
        _ = await engine.sync(preferences: preferences, deadline: .distantFuture, request: host.handle)
        let whole = windows(since: sent)
        XCTAssertTrue(whole.contains("steps/day") && whole.contains("sleep/night") && whole.count > 2, "\(whole)")
        sent = host.batches.count
        now += 60
        _ = await engine.sync(preferences: preferences, deadline: .distantFuture,
                              options: HealthPassOptions(resendRecent: true), request: host.handle)
        XCTAssertEqual(windows(since: sent).count, whole.count)

        // Another choice of what's shared: every window again.
        sent = host.batches.count
        var fewer = preferences
        fewer.categories = [.activity, .workouts]
        now += 60
        _ = await engine.sync(preferences: fewer, deadline: .distantFuture, request: host.handle)
        XCTAssertFalse(windows(since: sent).isEmpty)
        XCTAssertFalse(windows(since: sent).contains("sleep/night"))

        // A host that lost the key starts over: everything goes.
        sent = host.batches.count
        host.forgetKey()
        now += 60
        _ = await engine.sync(preferences: fewer, deadline: .distantFuture, request: host.handle)
        XCTAssertTrue(windows(since: sent).contains("steps/hour"))
    }

    func testACategoryTurnedOnLaterGetsItsHistory() async throws {
        let host = FakeHealthHost()
        let engine = makeHealthEngine(source: FakeHealthSource())
        func windows(since count: Int, _ kind: String) -> Int {
            host.batches.dropFirst(count).flatMap { $0["windows"] as? [[String: Any]] ?? [] }
                .filter { "\($0["metric"] as? String ?? "")/\($0["grain"] as? String ?? "")" == kind }.count
        }
        var preferences = healthPreferences(history: .days30)
        preferences.categories = [.activity, .workouts]
        _ = await engine.sync(preferences: preferences, deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(engine.state.backfillCursor, engine.state.historyStart)
        XCTAssertEqual(windows(since: 0, "sleep/night"), 0)

        // Sleep on: its older nights go too, not just the recent days.
        var sent = host.batches.count
        preferences.categories = [.activity, .sleep, .workouts]
        _ = await engine.sync(preferences: preferences, deadline: .distantFuture, request: host.handle)
        XCTAssertGreaterThan(windows(since: sent, "sleep/night"), 1, "The recent days and the history walked again")
        XCTAssertEqual(engine.state.backfillCursor, engine.state.historyStart, "All 30 days are in again")

        // Sleep off: what stays on already has its history.
        sent = host.batches.count
        preferences.categories = [.activity, .workouts]
        _ = await engine.sync(preferences: preferences, deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(windows(since: sent, "steps/day"), 1, "Only the recent days go again")
        XCTAssertEqual(windows(since: sent, "sleep/night"), 0)
        XCTAssertEqual(engine.state.backfillCursor, engine.state.historyStart)
    }

    func testLowDataModeLeavesOlderHistoryForLater() async throws {
        let host = FakeHealthHost()
        let engine = makeHealthEngine(source: FakeHealthSource())
        let preferences = healthPreferences(history: .days30)
        _ = await engine.sync(preferences: preferences, deadline: .distantFuture,
                              options: HealthPassOptions(lowData: true), request: host.handle)
        let cursor = try XCTUnwrap(engine.state.backfillCursor)
        XCTAssertGreaterThan(cursor, try XCTUnwrap(engine.state.historyStart), "Recent days only")
        _ = await engine.sync(preferences: preferences, deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(engine.state.backfillCursor, engine.state.historyStart, "The rest once off Low Data")
    }

    func testAllHistoryStartsAfterTheHostsFirstDay() async throws {
        // Issue 1537: UTC+8, and Health keeping dates from before 2000.
        var calendar = Self.healthCalendar
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let source = FakeHealthSource()
        source.earliest = date("1999-06-01T00:00:00Z")
        let host = FakeHealthHost()
        let engine = makeHealthEngine(source: source, calendar: calendar, now: { Self.healthDate("2000-03-01T12:00:00Z") })
        let outcome = await engine.sync(preferences: healthPreferences(history: .all), deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(outcome, .synced)
        XCTAssertEqual(engine.state.historyStart, date("2000-01-02T16:00:00Z"), "Its first night's window opens after 2000")
        XCTAssertEqual(engine.state.backfillCursor, engine.state.historyStart, "All of it is in")
        let windows = host.batches.flatMap { $0["windows"] as? [[String: Any]] ?? [] }
        XCTAssertFalse(windows.isEmpty)
        XCTAssertTrue(windows.compactMap { $0["from"] as? String }.allSatisfy { $0 >= "2000-01-01T00:00:00Z" })
    }

    func testASavedStartBeforeTheHostsFirstDayMovesUp() async throws {
        let source = FakeHealthSource()
        source.earliest = date("2010-01-01T00:00:00Z")
        source.oldest = nil
        let host = FakeHealthHost()
        let keys = HealthKeyBox()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("health-sync-\(UUID().uuidString)", isDirectory: true)
        let preferences = healthPreferences(history: .all)
        let first = makeHealthEngine(source: source, keys: keys, folder: folder)
        _ = await first.sync(preferences: preferences, deadline: .distantFuture, request: host.handle)
        // As a build from before the host's limit saved it (issue 1537).
        var saved = first.state
        XCTAssertFalse(saved.anchors.isEmpty)
        saved.historyStart = date("1999-12-31T16:00:00Z")
        XCTAssertTrue(HealthSyncStateStore(url: folder.appendingPathComponent("state.json")).save(saved))

        let second = makeHealthEngine(source: source, keys: keys, folder: folder)
        _ = await second.sync(preferences: preferences, deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(second.state.historyStart, date("2000-01-03T00:00:00Z"))
        XCTAssertEqual(second.state.anchors, saved.anchors, "Anchors kept")
        XCTAssertEqual(host.keyRequests, 1)
    }

    func testHistoryStopsAtTheOldestReading() async throws {
        let source = FakeHealthSource()
        source.earliest = date("2010-01-01T00:00:00Z")
        source.oldest = date("2026-08-20T09:30:00Z")
        let host = FakeHealthHost()
        let engine = makeHealthEngine(source: source)
        let preferences = healthPreferences(history: .all)
        _ = await engine.sync(preferences: preferences, deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(engine.state.backfillCursor, date("2026-08-20T00:00:00Z"), "No empty years walked")
        let froms = host.batches.flatMap { $0["windows"] as? [[String: Any]] ?? [] }
            .filter { $0["metric"] as? String == "steps" && $0["grain"] as? String == "day" }
            .compactMap { $0["from"] as? String }
        XCTAssertEqual(froms.min(), "2026-08-20T00:00:00Z")

        // An import with older readings: the walk goes on from there.
        source.oldest = date("2026-06-01T08:00:00Z")
        _ = await engine.sync(preferences: preferences, deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(engine.state.backfillCursor, date("2026-06-01T00:00:00Z"))
        XCTAssertEqual(engine.state.historyStart, date("2010-01-01T00:00:00Z"), "Events still reach back as far as Health")
    }

    func testUnreadableHealthStateKeepsTheDeviceID() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("health-state-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("state.json")
        try Data(#"{"deviceID":"phone1","anchors":"not a map"}"#.utf8).write(to: url)
        let state = HealthSyncStateStore(url: url).load()
        XCTAssertEqual(state.deviceID, "phone1")
        XCTAssertTrue(state.anchors.isEmpty)
    }

    func testRefusedIngestKeepsTheCursorAndPauses() async {
        let source = FakeHealthSource()
        let host = FakeHealthHost()
        host.ingestError = DashboardTicketBridgeError.http(status: 413, detail: "too_big")
        let engine = makeHealthEngine(source: source)
        let outcome = await engine.sync(preferences: healthPreferences(history: .days30), deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(outcome, .paused(.refused("too_big")))
        XCTAssertNil(engine.state.backfillCursor, "Nothing acknowledged, nothing moves")
        XCTAssertTrue(engine.state.anchors.isEmpty)

        host.ingestError = DashboardTicketBridgeError.http(status: 404, detail: "")
        let missing = await engine.sync(preferences: healthPreferences(history: .days30), deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(missing, .paused(.pluginMissing))

        // A plain failure replaces an old pause, so its error shows.
        host.ingestError = URLError(.timedOut)
        let failed = await engine.sync(preferences: healthPreferences(history: .days30), deadline: .distantFuture, request: host.handle)
        XCTAssertNil(engine.state.pause)
        if case .failed = failed {} else { XCTFail("Expected a failure, got \(failed)") }
        XCTAssertNotNil(engine.lastError)
    }

    /// Only a 409 that says the host lost the key clears it. The notifier's
    /// other 409s (too many devices, a store from a newer plugin) can't be
    /// fixed by a new key: they keep it. A newer plugin's store asks for a
    /// plugin update; the others pause with the host's reason.
    func testOnlyAKeyLoss409ForgetsTheKey() async {
        let host = FakeHealthHost()
        let keys = HealthKeyBox()
        let engine = makeHealthEngine(source: FakeHealthSource(), keys: keys)
        let preferences = healthPreferences(history: .days30)
        // The key is agreed, then the first batch is refused.
        host.ingestError = DashboardTicketBridgeError.http(
            status: 409, detail: "This health store was written by a newer plugin; update the plugin"
        )
        let newer = await engine.sync(preferences: preferences, deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(newer, .paused(.pluginMissing))
        XCTAssertNotNil(keys.key, "A newer store is no reason to give up the key")
        XCTAssertEqual(host.keyRequests, 1)

        // The bare code, should a host send it.
        host.ingestError = DashboardTicketBridgeError.http(status: 409, detail: "schema")
        let code = await engine.sync(preferences: preferences, deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(code, .paused(.pluginMissing))
        XCTAssertNotNil(keys.key)
        XCTAssertEqual(host.keyRequests, 1)

        let full = "This profile already keeps health data from 4 devices; delete one from Conduit first"
        host.ingestError = DashboardTicketBridgeError.http(status: 409, detail: full)
        let refused = await engine.sync(preferences: preferences, deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(refused, .paused(.refused(full)))
        XCTAssertNotNil(keys.key)
        XCTAssertEqual(host.keyRequests, 1)

        host.ingestError = DashboardTicketBridgeError.http(
            status: 409, detail: "This device's health key isn't on this profile; set it up again"
        )
        let lost = await engine.sync(preferences: preferences, deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(lost, .unfinished)
        XCTAssertNil(keys.key, "The host lost the key: the next pass agrees a new one")
    }

    func testTurningOffDeletesFromTheHostAndForgetsTheKey() async {
        let host = FakeHealthHost()
        let keys = HealthKeyBox()
        let engine = makeHealthEngine(source: FakeHealthSource(), keys: keys)
        _ = await engine.sync(preferences: healthPreferences(history: .days30), deadline: .distantFuture, request: host.handle)
        let deviceID = engine.state.deviceID
        let deleted = await engine.turnOff(deleteFromHost: host.handle)
        XCTAssertTrue(deleted)
        XCTAssertEqual(host.wiped, [deviceID])
        XCTAssertNil(engine.state.historyStart)
        XCTAssertTrue(engine.state.anchors.isEmpty)
        XCTAssertNil(keys.key)

        // Deletion asked for but no way to reach the host is not a deletion.
        let offline = makeHealthEngine(source: FakeHealthSource())
        let offlineDeleted = await offline.turnOff(deleteFromHost: nil)
        XCTAssertFalse(offlineDeleted)
    }

    func testHealthSettingsLinkOpensOnlyInsideTheApp() throws {
        let url = try XCTUnwrap(URL(string: "conduit://settings/health"))
        XCTAssertEqual(ConduitAppLink(url: url), .settings(.health))
        XCTAssertNil(ConduitAppLink(externalURL: url))
    }

    // MARK: Helpers

    private static var healthCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private func makeHealthEngine(source: FakeHealthSource, keys box: HealthKeyBox = HealthKeyBox(),
                                  calendar: Calendar? = nil, folder: URL? = nil,
                                  now: @escaping () -> Date = { HermesVoiceGatewayTimeoutTests.healthDate("2026-10-13T12:00:00Z") })
        -> HealthSyncEngine {
        let folder = folder ?? FileManager.default.temporaryDirectory.appendingPathComponent("health-sync-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let keys = HealthSyncKeyStore(load: { box.key }, save: { box.key = $0 }, clear: { box.key = nil })
        return HealthSyncEngine(source: source, store: HealthSyncStateStore(url: folder.appendingPathComponent("state.json")),
                                keys: keys, calendar: calendar ?? Self.healthCalendar, now: now)
    }

    private func healthPreferences(history: HealthHistoryDepth) -> HealthSyncPreferences {
        HealthSyncPreferences(
            destination: HealthSyncDestination(dashboardID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                               profile: "default", host: "hermes.local"),
            categories: [.activity, .sleep, .workouts], detailed: [], history: history)
    }

    private func date(_ text: String) -> Date { Self.healthDate(text) }

    nonisolated fileprivate static func healthDate(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func sleepSegment(_ id: String, _ stage: HealthSleepStage, _ start: String, _ end: String,
                         _ source: String, watch: Bool) -> HealthSleepSegment {
        HealthSleepSegment(id: id, stage: stage, start: date(start), end: date(end), source: source, fromWatch: watch)
    }
}

/// The Keychain's place in tests.
private final class HealthKeyBox {
    var key: HealthSyncCrypto.SessionKey?
}

/// Apple Health stand-in: one bucket per range, one workout, no sleep.
private final class FakeHealthSource: HealthDataSource {
    var isAvailable: Bool { true }
    /// A metric's sum other than 100, as when a reading arrives.
    var sums: [HealthMetric: Double] = [:]
    func requestAuthorization(for categories: Set<HealthCategory>, detailed: Set<HealthCategory>) async throws {}

    func buckets(_ metric: HealthMetric, grain: HealthGrain, from: Date, to: Date, calendar: Calendar) async throws -> [HealthBucket] {
        [HealthBucket(start: from, end: calendar.date(byAdding: grain == .hour ? .hour : .day, value: 1, to: from) ?? to,
                      sum: metric.aggregation == .sum ? (sums[metric] ?? 100) : nil)]
    }

    func sleepSegments(from: Date, to: Date) async throws -> [HealthSleepSegment] { [] }

    func changes(_ stream: HealthEventStream, since: Date, anchor: Data?, limit: Int) async throws -> HealthEventChanges {
        guard stream == .workouts, anchor == nil else { return HealthEventChanges(added: [], deleted: [], anchor: anchor ?? Data("\(stream.key)".utf8), more: false) }
        let workout = HealthEvent(id: "W1", kind: .workout, metric: "workout", start: since, end: since.addingTimeInterval(1800),
                                  data: ["activity": .text("running")])
        return HealthEventChanges(added: [workout], deleted: [], anchor: Data("w-anchor".utf8), more: false)
    }

    var earliest = Date(timeIntervalSince1970: 1_600_000_000)
    func earliestDate() -> Date { earliest }
    /// Readings back to the start of time unless a test says otherwise.
    var oldest: Date? = .distantPast
    func oldestReading(in categories: Set<HealthCategory>) async throws -> Date? { oldest }
    func observe(_ categories: Set<HealthCategory>, onChange: @escaping (_ done: @escaping () -> Void) -> Void) async {}
    func stopObserving() async {}
}

/// The notifier's health routes, enough to agree a key and open batches.
@MainActor
private final class FakeHealthHost {
    private let hostKey = Curve25519.KeyAgreement.PrivateKey()
    private var session: SymmetricKey?
    private var kid: String?
    private(set) var keyRequests = 0
    private(set) var batches: [[String: Any]] = []
    private(set) var wiped: [String] = []
    var ingestError: Error?
    /// health_store's count of windows it kept a newer computation of.
    var staleWindows = 0

    func forgetKey() {
        session = nil
        kid = nil
    }

    func handle(path: String, method: String, body: [String: Any]?) async throws -> [String: Any] {
        let base = HealthSyncEngine.base
        if path.hasPrefix("\(base)/status") {
            var answer: [String: Any] = ["generation": "g1"]
            if let kid { answer["device"] = ["kid": kid] }
            return answer
        }
        if path == "\(base)/key" {
            keyRequests += 1
            let deviceID = try XCTUnwrap(body?["device_id"] as? String)
            let devicePublic = try XCTUnwrap(NotificationE2E.base64URLDecoded(try XCTUnwrap(body?["public_key"] as? String)))
            let hostPublic = hostKey.publicKey.rawRepresentation
            let kid = HealthSyncCrypto.keyID(devicePublic: devicePublic, hostPublic: hostPublic)
            let shared = try hostKey.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: devicePublic))
            let info = HealthSyncCrypto.ingestInfo + Data("\n\(deviceID)\n".utf8) + devicePublic + hostPublic
            session = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: HealthSyncCrypto.salt, sharedInfo: info, outputByteCount: 32)
            self.kid = kid
            return ["host_public_key": NotificationE2E.base64URL(hostPublic), "kid": kid, "generation": "g1"]
        }
        if path == "\(base)/ingest" {
            if let ingestError { throw ingestError }
            let body = try XCTUnwrap(body)
            guard let session, let kid, body["kid"] as? String == kid else {
                throw DashboardTicketBridgeError.http(status: 409, detail: "unknown_key")
            }
            let nonce = try XCTUnwrap(NotificationE2E.base64URLDecoded(try XCTUnwrap(body["nonce"] as? String)))
            let sealed = try XCTUnwrap(NotificationE2E.base64URLDecoded(try XCTUnwrap(body["ct"] as? String)))
            let box = try ChaChaPoly.SealedBox(combined: nonce + sealed)
            let aad = HealthSyncCrypto.aad(kid: kid, deviceID: try XCTUnwrap(body["device_id"] as? String),
                                           batchID: try XCTUnwrap(body["batch_id"] as? String))
            let plaintext = try ChaChaPoly.open(box, using: session, authenticating: aad)
            batches.append(try XCTUnwrap(JSONSerialization.jsonObject(with: plaintext) as? [String: Any]))
            return ["ok": true, "stale_windows": staleWindows]
        }
        if path == "\(base)/wipe" {
            wiped.append(try XCTUnwrap(body?["device_id"] as? String))
            return ["ok": true]
        }
        throw DashboardTicketBridgeError.http(status: 404, detail: path)
    }
}
