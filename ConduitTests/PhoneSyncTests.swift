//
//  PhoneSyncTests.swift
//  ConduitTests
//
//  Calendar, reminders, Focus and phone status: a pass sets up a key, sends
//  sealed uploads with only what changed, and trades results for the
//  changes Hermes asked for, applying new items without asking only when
//  the user chose that. Written as an extension of an existing suite: the CI
//  test planner is at capacity for new XCTestCase classes.
//

import CryptoKit
import EventKit
import XCTest
@testable import Conduit

@MainActor
extension HermesVoiceGatewayTimeoutTests {
    func testPhoneItemsLeaveOutALinkTooLongForTheHost() throws {
        // phone_store MAX_URL_CHARS: a longer url refuses the whole upload.
        let store = EKEventStore()
        let long = try XCTUnwrap(URL(string: "https://example.com/r?u=" + String(repeating: "a", count: 1_000)))
        let short = try XCTUnwrap(URL(string: "https://example.com/meet"))
        let event = EKEvent(eventStore: store)
        event.calendar = EKCalendar(for: .event, eventStore: store)
        event.title = "Standup"
        event.startDate = Date(timeIntervalSince1970: 1_760_400_000)
        event.endDate = Date(timeIntervalSince1970: 1_760_401_800)
        event.url = long
        XCTAssertNil(try XCTUnwrap(EventKitPhoneSource.json(event, details: true, emails: false))["url"])
        event.url = short
        XCTAssertEqual(try XCTUnwrap(EventKitPhoneSource.json(event, details: true, emails: false))["url"] as? String, short.absoluteString)

        let reminder = EKReminder(eventStore: store)
        reminder.calendar = EKCalendar(for: .reminder, eventStore: store)
        reminder.title = "Read the doc"
        reminder.url = long
        XCTAssertNil(try XCTUnwrap(EventKitPhoneSource.json(reminder, details: true))["url"])
        reminder.url = short
        XCTAssertEqual(try XCTUnwrap(EventKitPhoneSource.json(reminder, details: true))["url"] as? String, short.absoluteString)
    }

    // The notifier's tests/phone_vector.json: both sides must agree.
    func testPhoneSealingMatchesTheNotifierVector() throws {
        let raw = try XCTUnwrap(NotificationE2E.base64URLDecoded("ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8"))
        let device = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        let hostPublicKey = "j0DFrbaPJWJK5bIU6nZ6bslNgp09e14a0bpvPiE4KF8"
        let hostPublic = try XCTUnwrap(NotificationE2E.base64URLDecoded(hostPublicKey))
        let kid = "623ffc0d912da4f291e9b21f5e9525a4"
        XCTAssertEqual(PhoneSyncCrypto.keyID(devicePublic: device.publicKey.rawRepresentation, hostPublic: hostPublic), kid)

        let key = try PhoneSyncCrypto.agree(devicePrivate: device, deviceID: "device-vector-1",
                                            hostPublicKey: hostPublicKey, kid: kid)
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(key.ingest), "630785d4c722fbb7302ec37755e28687dc6ad95908044f75d23c2a68c5bda771")
        XCTAssertEqual(hex(key.request), "897af24a563a0c8828564d83559f2c47a9f154ddc247ef3dc7517cb00a4d44e2")
        XCTAssertEqual(hex(key.answer), "0e3aa3a1b6e61220b05cf2bc928c09be5b6dc7aee322e9e79b13d6472da199ec")

        let batch = #"{"batch_id":"batch-vector-1","sent_at":"2026-10-14T08:02:11+01:00","sharing":{"calendar":"full","reminders":true}}"#
        let envelope = try PhoneSyncCrypto.envelope(
            plaintext: Data(batch.utf8), key: key, deviceID: "device-vector-1", batchID: "batch-vector-1",
            nonce: try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 12)))
        XCTAssertEqual(envelope["nonce"] as? String, "AAAAAAAAAAAAAAAA")
        XCTAssertEqual(envelope["ct"] as? String,
                       "urNzwshgjVt59WJvei1cvkp4Wc5TcyVM23WAjA5ZYzKt5-yCuj5nf1wcGId5cRo_-gZWSlB6HzCH9-5eRkplX2HfKXWd5MclQSsgzZiR4gfhuMHlK48hL1dZy83OiMzIJ-ooKCr3oyJQ9rEZSdMt5y0D0q468B-Q1dLBKdoYvePegQ")

        let request = #"{"call_id":"call-vector-1","results":[{"id":"ch_vector000001","outcome":"applied","item_id":"e_1"}]}"#
        let exchange = try PhoneSyncCrypto.exchangeEnvelope(
            plaintext: Data(request.utf8), op: "changes", key: key, deviceID: "device-vector-1", callID: "call-vector-1",
            nonce: try ChaChaPoly.Nonce(data: Data(repeating: 1, count: 12)))
        XCTAssertEqual(exchange["ct"] as? String,
                       "gELNGLE22UzmOD9jFhmSx2vvTH46EwCS3bOLvdBDvzUNVtuX4BUIafEHjmztpE2ePKpnfSirlccBF3ofBO7oFtA52hidOys7o54b_F_ExfXTtk3va2EBeRBbjFbj1ozUSOkGbc1cLenEB2JgsArgdPbgyEs")

        let answer: [String: Any] = ["nonce": "AgICAgICAgICAgIC",
                                     "ct": "jzmv7wQbA5r8CkriEVswbKhirSLiYHJJQdLAWdBti6KmGBraXGxE4B3wTTRFUMAGFVB3D6Vcyos"]
        let opened = try PhoneSyncCrypto.openAnswer(answer, op: "changes", key: key, deviceID: "device-vector-1",
                                                    callID: "call-vector-1")
        XCTAssertEqual(String(decoding: opened, as: UTF8.self), #"{"call_id":"call-vector-1","changes":[]}"#)
        XCTAssertThrowsError(try PhoneSyncCrypto.openAnswer(answer, op: "changes", key: key, deviceID: "device-vector-1",
                                                            callID: "call-other"), "An answer to another call is refused")
    }

    func testPhoneSyncSendsOnlyWhatChanged() async throws {
        let source = FakePhoneCalendarSource()
        source.events = [phoneEvent("e_1", "Dentist"), phoneEvent("e_2", "Gym")]
        let host = FakePhoneHost()
        let engine = makePhoneEngine(source: source)
        engine.savePreferences(phonePreferences())

        let first = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(first, .synced)
        XCTAssertEqual(host.keyRequests, 1)
        let full = try XCTUnwrap(host.batches.last?["events"] as? [String: Any])
        XCTAssertEqual(full["full"] as? Bool, true)
        XCTAssertEqual((full["upsert"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((host.batches.last?["sharing"] as? [String: Any])?["calendar"] as? String, "full")
        XCTAssertNotNil(host.batches.last?["focus"], "Focus goes when shared")

        // Nothing changed: nothing goes, and the key is reused.
        let sent = host.batches.count
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(host.keyRequests, 1)
        XCTAssertEqual(host.batches.count, sent)

        // One changed, one gone.
        source.events = [phoneEvent("e_1", "Dentist (moved)")]
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        let diff = try XCTUnwrap(host.batches.last?["events"] as? [String: Any])
        XCTAssertEqual(diff["full"] as? Bool, false)
        XCTAssertEqual((diff["upsert"] as? [[String: Any]])?.map { $0["id"] as? String }, ["e_1"])
        XCTAssertEqual(diff["delete"] as? [String], ["e_2"])

        // A host that lost the key: set it up again and send everything.
        host.forgetKey()
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(host.keyRequests, 2)
        XCTAssertEqual((host.batches.last?["events"] as? [String: Any])?["full"] as? Bool, true)
    }

    /// Only a 409 that says the host lost the key clears it. The notifier's
    /// other 409s (too many devices, a store from a newer plugin) can't be
    /// fixed by a new key: they keep it, and a full host pauses with its
    /// reason.
    func testOnlyAKeyLoss409ForgetsThePhoneKey() async {
        let source = FakePhoneCalendarSource()
        source.events = [phoneEvent("e_1", "Dentist")]
        let host = FakePhoneHost()
        let keys = PhoneKeyBox()
        let engine = makePhoneEngine(source: source, keys: keys)
        engine.savePreferences(phonePreferences())
        // The key is agreed, then the first batch is refused.
        let full = "This profile already keeps calendar data from 4 devices; delete one from Conduit first"
        host.ingestError = DashboardTicketBridgeError.http(status: 409, detail: full)
        let refused = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(refused, .paused(.refused(full)))
        XCTAssertNotNil(keys.key, "A full host is no reason to give up the key")
        XCTAssertEqual(host.keyRequests, 1)

        host.ingestError = DashboardTicketBridgeError.http(
            status: 409, detail: "This device's calendar key isn't on this profile; set it up again"
        )
        let lost = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(lost, .unfinished)
        XCTAssertNil(keys.key, "The host lost the key: the next pass agrees a new one")

        host.ingestError = nil
        let rekeyed = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(rekeyed, .synced)
        XCTAssertEqual(host.keyRequests, 2)
        XCTAssertNotNil(keys.key)
    }

    /// A store written by a newer plugin (`phone_store.py`'s 409 `schema`)
    /// is fixed by updating the plugin, not by a new key: sharing pauses
    /// with the update-the-plugin message and the key stays. A lost key
    /// still sets up again (notifier #342 review).
    func testANewerPluginsStoreAsksForAPluginUpdateAndKeepsTheKey() async {
        let source = FakePhoneCalendarSource()
        source.events = [phoneEvent("e_1", "Dentist")]
        let host = FakePhoneHost()
        let keys = PhoneKeyBox()
        let engine = makePhoneEngine(source: source, keys: keys)
        engine.savePreferences(phonePreferences())
        host.ingestError = DashboardTicketBridgeError.http(
            status: 409, detail: "This calendar store was written by a newer plugin; update the plugin"
        )
        let newer = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(newer, .paused(.pluginMissing))
        XCTAssertEqual(engine.state.pause?.message,
                       AppLocalization.string("Paused: update the Conduit plugin on this host to share your calendar and phone status."))
        XCTAssertNotNil(keys.key, "A newer plugin's store is no reason to give up the key")
        XCTAssertEqual(host.keyRequests, 1)

        // The bare code, should a host send it.
        host.ingestError = DashboardTicketBridgeError.http(status: 409, detail: "schema")
        let code = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(code, .paused(.pluginMissing))
        XCTAssertNotNil(keys.key)
        XCTAssertEqual(host.keyRequests, 1)

        host.ingestError = DashboardTicketBridgeError.http(status: 409, detail: "unknown_key")
        let lost = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(lost, .unfinished)
        XCTAssertNil(keys.key, "The host lost the key: the next pass agrees a new one")

        host.ingestError = nil
        let rekeyed = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(rekeyed, .synced)
        XCTAssertEqual(host.keyRequests, 2)
    }

    func testALargePhoneSnapshotGoesInPartsTheHostTakes() async throws {
        // The fake host refuses what the notifier does: bodies over 4 MiB and
        // batches over 5,000 items.
        let notes = String(repeating: "n", count: 2_000)
        let source = FakePhoneCalendarSource()
        source.events = (0..<4_000).map { index in
            var event = phoneEvent("e_\(index)", "Meeting \(index)")
            if index < 2_000 { event["notes"] = notes }
            return event
        }
        source.reminderItems = (0..<1_000).map { ["id": "r_\($0)", "calendar_id": "c_1", "title": "Task \($0)", "completed": false] }
        let host = FakePhoneHost()
        let engine = makePhoneEngine(source: source)
        engine.savePreferences(phonePreferences())

        let synced = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(synced, .synced)
        let parts = host.batches
        XCTAssertGreaterThan(parts.count, 1)
        for part in parts {
            XCTAssertEqual(part["sent_at"] as? String, parts.first?["sent_at"] as? String, "One pass: the host takes every part")
            XCTAssertNotNil(part["sharing"])
        }
        // Only the first part replaces what the host has; the rest add to it.
        XCTAssertEqual((parts.first?["events"] as? [String: Any])?["full"] as? Bool, true)
        XCTAssertEqual((parts.first?["reminders"] as? [String: Any])?["full"] as? Bool, true)
        XCTAssertNotNil(parts.first?["calendars"])
        XCTAssertNotNil(parts.first?["status"])
        for part in parts.dropFirst() {
            XCTAssertNotEqual((part["events"] as? [String: Any])?["full"] as? Bool, true)
            XCTAssertNotEqual((part["reminders"] as? [String: Any])?["full"] as? Bool, true)
            XCTAssertNil(part["calendars"])
            XCTAssertNil(part["status"])
        }
        func ids(_ section: String) -> [String] {
            parts.flatMap { ($0[section] as? [String: Any])?["upsert"] as? [[String: Any]] ?? [] }.compactMap { $0["id"] as? String }
        }
        XCTAssertEqual(ids("events"), source.events.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids("reminders"), source.reminderItems.compactMap { $0["id"] as? String })

        // A small change still goes as one upload.
        source.events[0]["title"] = "Moved"
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(host.batches.count, parts.count + 1)
        XCTAssertEqual(((host.batches.last?["events"] as? [String: Any])?["upsert"] as? [[String: Any]])?.count, 1)

        // A part the host doesn't take: nothing counts as sent, so the next
        // pass starts over whole.
        let other = makePhoneEngine(source: source)
        other.savePreferences(phonePreferences())
        host.forgetKey()
        host.failIngest = 2
        let failed = await other.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertNotEqual(failed, .synced)
        XCTAssertTrue(other.state.eventHashes.isEmpty, "Nothing is recorded as sent before the last part")
        XCTAssertNil(other.state.lastFullSync)
        host.failIngest = nil
        let retried = host.batches.count
        let again = await other.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(again, .synced)
        XCTAssertEqual((host.batches[retried]["events"] as? [String: Any])?["full"] as? Bool, true)
        XCTAssertEqual(other.state.eventHashes.count, 4_000)
    }

    func testManyDeletionsGoInPartsTheHostTakes() throws {
        // A calendar removed on the phone: thousands of deletions and the new
        // calendar list, more than the host's 5,000 items in one upload.
        let batch: [String: Any] = [
            "sent_at": "2026-10-19T08:00:00Z",
            "sharing": ["calendar": "full"],
            "calendars": [["id": "c_2", "title": "Work", "kind": "event"]],
            "events": ["full": false, "upsert": [[String: Any]](), "delete": (0..<4_000).map { "e_\($0)" }],
            "reminders": ["full": false, "upsert": [["id": "r_new", "title": "Task"]], "delete": (0..<1_500).map { "r_\($0)" }],
        ]
        let parts = PhoneSyncEngine.parts(of: batch, maxItems: 5_000, maxBytes: 3_000_000)
        XCTAssertGreaterThan(parts.count, 1)
        for part in parts {
            XCTAssertLessThanOrEqual(FakePhoneHost.items(in: part), 5_000)
            XCTAssertEqual(part["sent_at"] as? String, "2026-10-19T08:00:00Z")
        }
        XCTAssertNotNil(parts.first?["calendars"])
        XCTAssertNil(parts.last?["calendars"])
        func all(_ section: String, _ list: String) -> [String] {
            parts.flatMap { (($0[section] as? [String: Any])?[list] as? [Any]) ?? [] }
                .compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["id"] as? String) }
        }
        XCTAssertEqual(all("events", "delete"), (0..<4_000).map { "e_\($0)" })
        XCTAssertEqual(all("reminders", "delete"), (0..<1_500).map { "r_\($0)" })
        XCTAssertEqual(all("reminders", "upsert"), ["r_new"])

        // An upload that fits is unchanged, as one part.
        var small = batch
        small["events"] = ["full": false, "upsert": [[String: Any]](), "delete": ["e_1"]]
        small["reminders"] = ["full": false, "upsert": [["id": "r_new", "title": "Task"]], "delete": ["r_1"]]
        let one = PhoneSyncEngine.parts(of: small, maxItems: 5_000, maxBytes: 3_000_000)
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one.first.map { NSDictionary(dictionary: $0) }, NSDictionary(dictionary: small))
    }

    func testPhoneSyncPostsNothingNewOnlyAsAKeepalive() async throws {
        let source = FakePhoneCalendarSource()
        source.events = [phoneEvent("e_1", "Dentist")]
        let host = FakePhoneHost()
        var now = Date(timeIntervalSince1970: 1_760_400_000)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("phone-sync-\(UUID().uuidString)", isDirectory: true)
        let defaults = UserDefaults(suiteName: "phone-sync-\(UUID().uuidString)")!
        let keys = PhoneKeyBox()
        let engine = makePhoneEngine(source: source, folder: folder, defaults: defaults, keys: keys, now: { now })
        // Phone status off: its own 15-minute refresh would post anyway.
        var preferences = phonePreferences()
        preferences.status = false
        engine.savePreferences(preferences)

        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(host.batches.count, 1)

        // Nothing new: only the status read, no upload.
        now += 60
        let quiet = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(quiet, .synced)
        XCTAssertEqual(host.batches.count, 1)
        XCTAssertEqual(host.statusRequests, 2)

        // A change Hermes asked for still arrives: the status says it waits.
        host.changes = [["id": "ch_add", "kind": "add_reminder", "auto": false, "fields": ["title": "Buy milk"]]]
        now += 60
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(host.batches.count, 1)
        XCTAssertEqual(engine.prompts.map(\.id), ["ch_add"])

        // Relaunched on the same state (as its writer leaves it): still
        // nothing to send.
        XCTAssertTrue(PhoneSyncStateStore(url: folder.appendingPathComponent("state.json")).save(engine.state))
        let relaunched = makePhoneEngine(source: source, folder: folder, defaults: defaults, keys: keys, now: { now })
        now += 60
        _ = await relaunched.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(host.batches.count, 1)

        // While the user is there (a message), a quarter hour is enough.
        now += 14 * 60
        _ = await relaunched.sync(deadline: .distantFuture, keepalive: ContextUploadPolicy.phoneKeepalive(for: .messageSent),
                                  request: host.handle)
        XCTAssertEqual(host.batches.count, 2)
        XCTAssertNil(host.batches.last?["events"])
        now += 60
        _ = await relaunched.sync(deadline: .distantFuture, keepalive: ContextUploadPolicy.phoneKeepalive(for: .messageSent),
                                  request: host.handle)
        XCTAssertEqual(host.batches.count, 2)

        // In the background, once the last upload is a few hours old.
        now += ContextUploadPolicy.phoneKeepalive - 120
        _ = await relaunched.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(host.batches.count, 2)
        now += 60
        _ = await relaunched.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(host.batches.count, 3)
        XCTAssertNil(host.batches.last?["events"])
        XCTAssertNotNil(host.batches.last?["sharing"])

        // Sharing narrowed: the host must hear it at once.
        var narrower = relaunched.preferences
        narrower.details = !narrower.details
        relaunched.savePreferences(narrower)
        now += 60
        _ = await relaunched.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(host.batches.count, 4)

        // An older plugin's status doesn't say what's waiting: every pass posts.
        host.reportsPending = false
        now += 60
        _ = await relaunched.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(host.batches.count, 5)
    }

    func testPhoneChangesAskUnlessTheUserChoseAddWithoutAsking() async throws {
        let source = FakePhoneCalendarSource()
        let host = FakePhoneHost()
        host.changes = [
            ["id": "ch_add", "kind": "add_reminder", "auto": true, "fields": ["title": "Buy milk"]],
            ["id": "ch_del", "kind": "delete_event", "auto": false, "target": ["event_id": "e_1"], "fields": [String: Any]()],
        ]
        let engine = makePhoneEngine(source: source)
        engine.savePreferences(phonePreferences())

        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        // "Ask me each time": both wait for the user.
        XCTAssertEqual(engine.prompts.map(\.id), ["ch_add", "ch_del"])
        XCTAssertTrue(source.applied.isEmpty)

        await engine.answer(try XCTUnwrap(engine.prompts.first), approve: true)
        await engine.answer(try XCTUnwrap(engine.prompts.first), approve: false)
        XCTAssertEqual(source.applied, ["ch_add"])
        host.changes = []
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(host.reported.map { $0["id"] as? String }, ["ch_add", "ch_del"])
        XCTAssertEqual(host.reported.map { $0["outcome"] as? String }, ["applied", "dismissed"])
        XCTAssertTrue(engine.state.unreported.isEmpty)

        // "Add without asking": a new item goes straight in, a deletion still asks.
        var preferences = phonePreferences()
        preferences.autoAdd = true
        engine.savePreferences(preferences)
        host.changes = [
            ["id": "ch_add2", "kind": "add_event", "auto": true,
             "fields": ["title": "Lunch", "start": "2026-10-15T12:00:00Z", "end": "2026-10-15T13:00:00Z"]],
            ["id": "ch_del2", "kind": "delete_event", "auto": false, "target": ["event_id": "e_1"], "fields": [String: Any]()],
        ]
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(source.applied, ["ch_add", "ch_add2"])
        XCTAssertEqual(engine.autoAdded?.title, "Lunch")
        XCTAssertEqual(engine.prompts.map(\.id), ["ch_del2"])

        // A report the host lost: the change comes back, and isn't applied twice.
        host.ignoreResults = true
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(source.applied, ["ch_add", "ch_add2"])
        XCTAssertEqual(engine.state.unreported.map(\.id), ["ch_add2"], "Reported again next time")

        // An added item counts as sent, so once it's gone from the phone
        // (Undo, or deleted in Calendar) the next upload deletes it on the host.
        let deletions = host.batches.compactMap { ($0["events"] as? [String: Any])?["delete"] as? [String] }.flatMap { $0 }
        XCTAssertTrue(deletions.contains("item_ch_add2"))
    }

    func testReadOnlyCalendarAndRemindersNeverTakeHermesChanges() async throws {
        let source = FakePhoneCalendarSource()
        source.events = [phoneEvent("e_1", "Team sync")]
        let host = FakePhoneHost()
        host.changes = [
            ["id": "ch_add", "kind": "add_event", "auto": true,
             "fields": ["title": "Lunch", "start": "2026-10-15T12:00:00Z", "end": "2026-10-15T13:00:00Z"]],
            ["id": "ch_del", "kind": "delete_event", "auto": false, "target": ["event_id": "e_1"], "fields": [String: Any]()],
            ["id": "ch_done", "kind": "complete_reminder", "auto": false, "target": ["reminder_id": "r_1"], "fields": [String: Any]()],
        ]
        let engine = makePhoneEngine(source: source)
        var preferences = phonePreferences()
        preferences.calendar = .readOnly
        preferences.remindersReadOnly = true
        preferences.autoAdd = true
        engine.savePreferences(preferences)

        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        // Read: events still go to the host, marked read-only in a way a
        // host from before read-only still takes.
        let sharing = try XCTUnwrap(host.batches.first?["sharing"] as? [String: Any])
        XCTAssertEqual(sharing["calendar"] as? String, "full")
        XCTAssertEqual(sharing["calendar_read_only"] as? Bool, true)
        XCTAssertEqual(sharing["reminders_read_only"] as? Bool, true)
        XCTAssertNotNil(host.batches.first?["events"])
        // Never changed: no card, nothing applied, each refused back to Hermes.
        XCTAssertTrue(engine.prompts.isEmpty)
        XCTAssertTrue(source.applied.isEmpty)
        XCTAssertEqual(engine.state.unreported.map(\.id), ["ch_add", "ch_del", "ch_done"])
        XCTAssertTrue(engine.state.unreported.allSatisfy { $0.outcome == .failed })
        XCTAssertNil(engine.state.answered["ch_add"], "A refusal is the setting now, not the user's answer")
        // Nor in a voice call.
        let voiceAdd = try XCTUnwrap(PhoneChange(json: ["id": "v_1", "kind": "add_reminder", "fields": ["title": "Milk"]]))
        do {
            _ = try await engine.applyFromVoice(voiceAdd)
            XCTFail("A read-only list takes no additions")
        } catch {}
        XCTAssertTrue(source.applied.isEmpty)
        XCTAssertEqual(PhoneVoiceTools.tools(for: preferences, access: .full, remindersAuthorized: true).map(\.name),
                       [PhoneVoiceTools.changesTool])

        // A card shown before the user made the calendar read-only isn't applied after.
        var writable = phonePreferences()
        writable.remindersReadOnly = false
        engine.savePreferences(writable)
        host.changes = [["id": "ch_later", "kind": "delete_event", "auto": false, "target": ["event_id": "e_1"],
                         "fields": [String: Any]()]]
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        let card = try XCTUnwrap(engine.prompts.first)
        engine.savePreferences(preferences)
        await engine.answer(card, approve: true)
        XCTAssertTrue(source.applied.isEmpty)
        XCTAssertEqual(engine.state.answered["ch_later"]?.outcome, .failed)

        // Each level allows only its own changes.
        XCTAssertTrue(PhoneSyncPreferences(calendar: .writeOnly).allows(.addEvent))
        XCTAssertFalse(PhoneSyncPreferences(calendar: .writeOnly).allows(.updateEvent))
        XCTAssertFalse(PhoneSyncPreferences(calendar: .readOnly).allows(.addEvent))
        XCTAssertTrue(PhoneSyncPreferences(calendar: .full, reminders: true).allows(.deleteReminder))
        // Read-only without read access in the Settings app leaves nothing.
        XCTAssertEqual(PhoneSyncEngine.effectiveSharing(preferences, access: .writeOnly, remindersAuthorized: true)["calendar"] as? String, "off")
        // Saved before read-only (no key): still writable.
        let saved = try JSONEncoder().encode(phonePreferences())
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("remindersReadOnly"))
        XCTAssertTrue(try JSONDecoder().decode(PhoneSyncPreferences.self, from: saved).allows(.completeReminder))
    }

    func testPhoneChangeNeedsWhatItActsOn() throws {
        XCTAssertNil(PhoneChange(json: ["id": "ch_1", "kind": "delete_event", "fields": [String: Any]()]), "A deletion names its event")
        XCTAssertNil(PhoneChange(json: ["id": "ch_1r", "kind": "delete_reminder", "fields": [String: Any]()]), "A deletion names its reminder")
        let deletion = try XCTUnwrap(PhoneChange(json: ["id": "ch_1d", "kind": "delete_reminder", "target": ["reminder_id": "r_1"]]))
        XCTAssertEqual(deletion.reminderID, "r_1")
        XCTAssertFalse(deletion.kind.addsWithoutAsking, "Deleting always asks")
        XCTAssertFalse(deletion.kind.isEvent)
        XCTAssertTrue(PhoneChangeWording.isRemoval(deletion.kind))
        XCTAssertEqual(PhoneChangeWording.approveTitle(deletion), "Delete")
        let named = try XCTUnwrap(PhoneChange(json: ["id": "ch_1n", "kind": "delete_reminder", "target": ["reminder_id": "r_1"],
                                                     "fields": ["title": "Buy milk"]]))
        XCTAssertEqual(PhoneChangeWording.detail(named), "Buy milk", "The card names what it deletes")
        XCTAssertNil(PhoneChange(json: ["id": "ch_2", "kind": "add_event", "fields": ["title": "No time"]]))
        XCTAssertNil(PhoneChange(json: ["id": "ch_3", "kind": "format_disk"]))
        let change = PhoneChange(json: ["id": "ch_4", "kind": "add_reminder", "auto": true,
                                        "fields": ["title": "Call mum", "due": "2026-10-16", "url": "javascript:alert(1)"]])
        XCTAssertEqual(change?.fields.title, "Call mum")
        XCTAssertNotNil(change?.fields.due)
        XCTAssertNil(change?.fields.url, "Only web links")
    }

    func testPhoneDiffSendsChangesAndDeletions() {
        let sent = ["a": PhoneSyncEngine.hash(["id": "a", "title": "A"]), "b": "old"]
        let section = PhoneSyncEngine.diff([["id": "a", "title": "A"], ["id": "c", "title": "C"]], against: sent, full: false)
        XCTAssertEqual(section.upsert.map { $0["id"] as? String }, ["c"])
        XCTAssertEqual(section.delete, ["b"])
        XCTAssertEqual(Set(section.hashes.keys), ["a", "c"])
        let whole = PhoneSyncEngine.diff([["id": "a", "title": "A"]], against: sent, full: true)
        XCTAssertEqual(whole.upsert.count, 1)
        XCTAssertTrue(whole.delete.isEmpty, "A full upload replaces; nothing to delete by id")
        let cut = PhoneSyncEngine.diff([["id": "a", "title": "A"]], against: sent, full: false, truncated: true)
        XCTAssertTrue(cut.delete.isEmpty, "An item past the limit isn't reported deleted")

        // Access taken away in the Settings app narrows what the host is told,
        // and access granted never widens what the user chose.
        let chosen = PhoneSyncPreferences(calendar: .full, reminders: true, status: true, focus: true)
        let narrowed = PhoneSyncEngine.effectiveSharing(chosen, access: .writeOnly, remindersAuthorized: false)
        XCTAssertEqual(narrowed["calendar"] as? String, "write_only")
        XCTAssertEqual(narrowed["reminders"] as? Bool, false)
        XCTAssertEqual(PhoneSyncEngine.effectiveSharing(chosen, access: .off, remindersAuthorized: true)["calendar"] as? String, "off")
        let kept = PhoneSyncEngine.effectiveSharing(chosen, access: .full, remindersAuthorized: true)
        XCTAssertEqual(kept["calendar"] as? String, "full")
        XCTAssertEqual(kept["reminders"] as? Bool, true)
        let addOnly = PhoneSyncPreferences(calendar: .writeOnly, reminders: false, status: false, focus: false)
        XCTAssertEqual(PhoneSyncEngine.effectiveSharing(addOnly, access: .full, remindersAuthorized: true)["calendar"] as? String, "write_only")
        XCTAssertEqual(PhoneSyncEngine.effectiveSharing(addOnly, access: .full, remindersAuthorized: true)["reminders"] as? Bool, false)
        var withEmails = chosen
        withEmails.details = true
        withEmails.attendeeEmails = true
        XCTAssertEqual(PhoneSyncEngine.effectiveSharing(withEmails, access: .full, remindersAuthorized: true)["attendee_emails"] as? Bool, true)
        let emailsNarrowed = PhoneSyncEngine.effectiveSharing(withEmails, access: .writeOnly, remindersAuthorized: true)
        XCTAssertEqual(emailsNarrowed["attendee_emails"] as? Bool, false)
        XCTAssertEqual(emailsNarrowed["details"] as? Bool, true, "Details also cover reminder notes")
        XCTAssertEqual(PhoneSyncEngine.effectiveSharing(withEmails, access: .writeOnly, remindersAuthorized: false)["details"] as? Bool,
                       false, "Nothing detailed is sent")
    }

    func testPhoneSettingsLinkOpensOnlyInsideTheApp() throws {
        let url = try XCTUnwrap(URL(string: "conduit://settings/phone"))
        XCTAssertEqual(ConduitAppLink(url: url), .settings(.phone))
        XCTAssertNil(ConduitAppLink(externalURL: url))
    }

    func testPhoneChangesPushIsRecognised() {
        XCTAssertTrue(AppState.isPhoneChangesPush(["conduit": ["type": "phone.changes", "e2e": 1] as [String: Any]]))
        XCTAssertTrue(AppState.isPhoneChangesPush(["body": ["conduit": ["type": "phone.changes"]]]))
        XCTAssertFalse(AppState.isPhoneChangesPush(["conduit": ["type": "response.ready"]]))
    }

    func testPhoneVoiceUsesAreLoggedApart() throws {
        let suite = "PhoneVoiceUses-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        HealthVoiceReadLog.record(mode: .geminiLive, action: "events", key: HealthVoiceReadLog.phoneStorageKey, in: defaults)
        XCTAssertEqual(HealthVoiceReadLog.load(key: HealthVoiceReadLog.phoneStorageKey, from: defaults).entries.map(\.action), ["events"])
        XCTAssertTrue(HealthVoiceReadLog.load(from: defaults).entries.isEmpty, "Health reads keep their own log")
        HealthVoiceReadLog.clear(key: HealthVoiceReadLog.phoneStorageKey, in: defaults)
        XCTAssertTrue(HealthVoiceReadLog.load(key: HealthVoiceReadLog.phoneStorageKey, from: defaults).entries.isEmpty)
    }

    func testPhoneChangeIsNeverAppliedTwice() async throws {
        let source = FakePhoneCalendarSource()
        let host = FakePhoneHost()
        let engine = makePhoneEngine(source: source)
        engine.savePreferences(phonePreferences())
        host.changes = [["id": "ch_once", "kind": "add_reminder", "auto": false, "fields": ["title": "Buy milk"]]]
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        let prompt = try XCTUnwrap(engine.prompts.first)

        // The first approval is still saving when a second one and an
        // exchange land: neither hands the change out again.
        source.holdApply = true
        let first = Task { await engine.answer(prompt, approve: true) }
        for _ in 0..<500 where !source.isHolding { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(source.isHolding)
        await engine.answer(prompt, approve: true)
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertTrue(engine.prompts.isEmpty)
        source.releaseApply()
        await first.value
        XCTAssertEqual(source.applied, ["ch_once"])
    }

    /// Add on a Pulse suggestion, or its Undo (0.98.0): the tap was the
    /// asking, so this phone applies that change without its own card, if
    /// the host hands it out within 15 minutes.
    func testAChangeApprovedOnAPulseCardIsAppliedWithoutItsCard() async throws {
        let source = FakePhoneCalendarSource()
        let host = FakePhoneHost()
        var clock = Date(timeIntervalSince1970: 1_760_400_000)
        let engine = makePhoneEngine(source: source, now: { clock })
        engine.savePreferences(phonePreferences())

        // Approved before the host handed it out: applied when it comes, with
        // no card, and reported on the next exchange. Another change still asks.
        await engine.approveFromCard("ch_pulse")
        host.changes = [
            ["id": "ch_pulse", "kind": "add_event", "auto": false,
             "fields": ["title": "Dinner", "start": "2026-10-25T19:00:00Z", "end": "2026-10-25T21:00:00Z"]],
            ["id": "ch_other", "kind": "add_reminder", "auto": false, "fields": ["title": "Buy milk"]],
        ]
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(source.applied, ["ch_pulse"])
        XCTAssertEqual(engine.prompts.map(\.id), ["ch_other"])
        XCTAssertEqual(engine.state.unreported.map(\.id), ["ch_pulse"])
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(host.reported.map { $0["id"] as? String }, ["ch_pulse"])
        XCTAssertEqual(host.reported.map { $0["outcome"] as? String }, ["applied"])

        // Undo tapped once its delete already waits as a card: applied at once.
        host.changes.append(["id": "ch_undo", "kind": "delete_event", "auto": false,
                             "target": ["event_id": "item_ch_pulse"], "fields": [String: Any]()])
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(engine.prompts.map(\.id), ["ch_other", "ch_undo"])
        await engine.approveFromCard("ch_undo")
        XCTAssertEqual(source.applied, ["ch_pulse", "ch_undo"])
        XCTAssertEqual(engine.prompts.map(\.id), ["ch_other"])

        // One the host doesn't hand out within 15 minutes (another device's,
        // or a relaunch's) gets its card, as any change does.
        await engine.approveFromCard("ch_late")
        clock = clock.addingTimeInterval(PhoneSyncEngine.cardApprovalWindow + 1)
        host.changes.append(["id": "ch_late", "kind": "add_reminder", "auto": false, "fields": ["title": "Late"]])
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(source.applied, ["ch_pulse", "ch_undo"])
        XCTAssertEqual(engine.prompts.map(\.id), ["ch_other", "ch_late"])
    }

    func testPhoneVoiceCallsReadAnswerAndAdd() async throws {
        let source = FakePhoneCalendarSource()
        let host = FakePhoneHost()
        let engine = makePhoneEngine(source: source)
        engine.savePreferences(phonePreferences())
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)

        // A read goes sealed to the host with op voice.
        let read = try await engine.voiceRead(tool: "conduit_calendar", arguments: ["action": "next"], provider: "gemini-live",
                                              path: "/api/plugins/conduit_push/voice-tools/call", request: host.handle)
        XCTAssertEqual((read as? [String: Any])?["tool"] as? String, "conduit_calendar")

        // Only what's shared: no reminders shared, no reminder adds.
        var eventsOnly = phonePreferences()
        eventsOnly.reminders = false
        let tools = PhoneVoiceTools.tools(for: eventsOnly, access: .full, remindersAuthorized: true)
        XCTAssertEqual(tools.map(\.name), [PhoneVoiceTools.changesTool, PhoneVoiceTools.addTool, PhoneVoiceTools.updateTool,
                                           PhoneVoiceTools.removeTool])
        let fullAccessAdd = try XCTUnwrap(tools.first { $0.name == PhoneVoiceTools.addTool })
        XCTAssertEqual(((fullAccessAdd.parameters["properties"] as? [String: Any])?["kind"] as? [String: Any])?["enum"] as? [String], ["event"])
        XCTAssertTrue(PhoneVoiceTools.tools(for: PhoneSyncPreferences(), access: .full, remindersAuthorized: true).isEmpty)
        // Nor what iOS no longer allows.
        let noReminders = PhoneVoiceTools.tools(for: phonePreferences(), access: .full, remindersAuthorized: false)
        XCTAssertEqual(((noReminders.first { $0.name == PhoneVoiceTools.addTool }?.parameters["properties"] as? [String: Any])?["kind"] as? [String: Any])?["enum"] as? [String], ["event"])
        XCTAssertEqual(PhoneVoiceTools.tools(for: eventsOnly, access: .off, remindersAuthorized: true).map(\.name), [PhoneVoiceTools.changesTool])
        // Add-only events are never read, so there's no id to delete by.
        let addOnlyTools = PhoneVoiceTools.tools(for: eventsOnly, access: .writeOnly, remindersAuthorized: true)
        XCTAssertEqual(addOnlyTools.map(\.name), [PhoneVoiceTools.changesTool, PhoneVoiceTools.addTool])
        let addOnly = try XCTUnwrap(addOnlyTools.last)
        XCTAssertTrue(addOnly.description.contains("leave the calendar out"))
        XCTAssertFalse(fullAccessAdd.description.contains("leave the calendar out"))

        // A change Hermes asks for is answered out loud.
        host.changes = [["id": "ch_voice", "kind": "add_reminder", "auto": false, "reason": "You asked",
                         "fields": ["title": "Call the plumber"]]]
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        let changesTool = try XCTUnwrap(PhoneVoiceTools.tools(for: phonePreferences(), access: .full, remindersAuthorized: true).first)
        let answer: (PhoneChangePrompt, Bool) async -> Void = { prompt, approve in await engine.answer(prompt, approve: approve) }
        let listed = await PhoneVoiceTools.run(changesTool, arguments: ["action": "list"], engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertTrue(listed["result"]?.contains("Call the plumber") == true)
        XCTAssertTrue(PhoneVoiceTools.note(for: try XCTUnwrap(engine.prompts.first)).contains("ch_voice"))
        let unconfirmedApproval = await PhoneVoiceTools.run(changesTool, arguments: ["action": "approve", "id": "ch_voice"],
                                                            engine: engine, confirmed: { _, _ in false }, answer: answer)
        XCTAssertNotNil(unconfirmedApproval["error"], "Approving takes the user's own yes")
        XCTAssertTrue(source.applied.isEmpty)
        let approved = await PhoneVoiceTools.run(changesTool, arguments: ["action": "approve", "id": "ch_voice"],
                                                 engine: engine, confirmed: { _, _ in true },
                                                 lastUserTurn: { (UUID(), "yes") }, answer: answer)
        XCTAssertNotNil(approved["result"])
        XCTAssertEqual(source.applied, ["ch_voice"])
        let missing = await PhoneVoiceTools.run(changesTool, arguments: ["action": "approve", "id": "ch_voice"],
                                                engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertNotNil(missing["error"], "Answered already: not applied twice")

        // An event the user asks for goes in at once and counts as sent.
        let added = await PhoneVoiceTools.run(fullAccessAdd, arguments: ["kind": "event", "title": "Dentist", "start": "2026-10-16T15:00",
                                                                   "calendar": "personal"],
                                              engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertNotNil(added["result"], added["error"] ?? "")
        let voiceID = try XCTUnwrap(source.applied.last)
        XCTAssertTrue(voiceID.hasPrefix("voice_"))
        XCTAssertEqual(engine.state.eventHashes["item_\(voiceID)"], "")
        let unknown = await PhoneVoiceTools.run(fullAccessAdd, arguments: ["kind": "event", "title": "Gym", "start": "2026-10-16T07:00",
                                                                     "calendar": "Work"],
                                                engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertNotNil(unknown["error"], "No calendar called Work")
        XCTAssertTrue(added["result"]?.contains("item_\(voiceID)") == true, "The add answers with the new item's id")

        // An event the user asks to delete goes at once, by its id.
        let removeTool = try XCTUnwrap(PhoneVoiceTools.tools(for: phonePreferences(), access: .full, remindersAuthorized: true)
            .first { $0.name == PhoneVoiceTools.removeTool })
        XCTAssertEqual(((removeTool.parameters["properties"] as? [String: Any])?["kind"] as? [String: Any])?["enum"] as? [String],
                       ["event", "reminder"])
        let removed = await PhoneVoiceTools.run(removeTool, arguments: ["kind": "event", "id": "e_dentist", "span": "future"],
                                                engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertNotNil(removed["result"], removed["error"] ?? "")
        let deletion = try XCTUnwrap(source.appliedChanges.last)
        XCTAssertEqual(deletion.kind, .deleteEvent)
        XCTAssertEqual(deletion.eventID, "e_dentist")
        XCTAssertEqual(deletion.span, "future")
        XCTAssertNil(engine.state.eventHashes["item_\(deletion.id)"], "A deletion isn't counted as a new item")
        let reminder = await PhoneVoiceTools.run(removeTool, arguments: ["kind": "reminder", "id": "r_milk"],
                                                 engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertNotNil(reminder["result"], reminder["error"] ?? "")
        XCTAssertEqual(source.appliedChanges.last?.kind, .deleteReminder)
        XCTAssertEqual(source.appliedChanges.last?.reminderID, "r_milk")
        // Not in a calendar the user left out since the id was read.
        source.itemCalendars["e_hidden"] = "ek_work"
        var leftOut = phonePreferences()
        leftOut.hiddenCalendars = ["ek_work"]
        engine.savePreferences(leftOut)
        let hidden = await PhoneVoiceTools.run(removeTool, arguments: ["kind": "event", "id": "e_hidden"], engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertNotNil(hidden["error"])
        XCTAssertNotEqual(source.appliedChanges.last?.eventID, "e_hidden")
        engine.savePreferences(phonePreferences())
        // Only on the user's own yes.
        let unconfirmed = await PhoneVoiceTools.run(removeTool, arguments: ["kind": "event", "id": "e_gym"], engine: engine,
                                                    confirmed: { _, _ in false }, answer: answer)
        XCTAssertNotNil(unconfirmed["error"])
        XCTAssertNotEqual(source.appliedChanges.last?.eventID, "e_gym")
        XCTAssertTrue(PhoneVoiceTools.confirmsChange("Yes, delete it."))
        XCTAssertTrue(PhoneVoiceTools.confirmsChange("remove that one"))
        XCTAssertTrue(PhoneVoiceTools.confirmsChange("Yes, move it."))
        XCTAssertTrue(PhoneVoiceTools.confirmsChange("mark it done"))
        XCTAssertFalse(PhoneVoiceTools.confirmsChange("delete it?"))
        XCTAssertFalse(PhoneVoiceTools.confirmsChange("move it to Friday instead"), "A different change, not a yes")
        XCTAssertFalse(PhoneVoiceTools.confirmsChange("what's on my calendar tomorrow"))
        XCTAssertFalse(PhoneVoiceTools.confirmsChange(""))
        XCTAssertFalse(PhoneVoiceTools.confirmsChange("of the event"), "Agreeing words without a yes or a verb")
        XCTAssertFalse(PhoneVoiceTools.confirmsChange("delete the event"), "The request itself isn't the yes")
        XCTAssertTrue(PhoneVoiceTools.confirmsChange("go ahead and delete that one"))
        XCTAssertFalse(PhoneVoiceTools.confirmsChange("Cancel."), "Cancel is a no to a change or deletion")
        XCTAssertFalse(PhoneVoiceTools.confirmsChange("cancel it"))
        XCTAssertTrue(PhoneVoiceTools.confirmsChange("cancel it", cancelsAlarm: true), "But a yes to cancelling an alarm")
        XCTAssertFalse(PhoneVoiceTools.confirmsChange("No, cancel", cancelsAlarm: true))
        // In each of the app's languages: a yes or a word pointing back,
        // never the request or a no.
        for yes in ["Ja, lösch es.", "Sí, bórralo", "Oui, supprime-le", "Sim, apaga isso", "Да, удали его",
                    "Sì, eliminalo", "Tak, usuń to", "Evet, sil onu", "Ya, hapus itu", "네, 삭제해 주세요", "그거 지워줘",
                    "はい、削除して", "それを消してください", "好的，删掉吧", "把它删了", "好，標記為完成"] {
            XCTAssertTrue(PhoneVoiceTools.confirmsChange(yes), yes)
        }
        for notYes in ["Lösche den Termin", "Nein, lösch es nicht", "Borra la alarma", "No lo borres",
                       "Supprime le rendez-vous", "Ne le supprime pas", "Não apague", "Не удаляй его", "Удали напоминание",
                       "Non cancellarlo", "Nie usuwaj", "Silme", "Jangan hapus itu", "삭제하지 마세요", "削除しないで",
                       "削除してください", "不要删除", "删除这个事件", "好的，取消", "¿Lo borro?"] {
            XCTAssertFalse(PhoneVoiceTools.confirmsChange(notYes), notYes)
        }
        for yes in ["Ja, schalte ihn aus", "Oui, annule-le", "Да, отмени его", "好的，取消"] {
            XCTAssertTrue(PhoneVoiceTools.confirmsChange(yes, cancelsAlarm: true), yes)
        }
        XCTAssertFalse(PhoneVoiceTools.confirmsChange("Отмени", cancelsAlarm: true), "A bare cancel isn't pointed at the alarm")
        let noID = await PhoneVoiceTools.run(removeTool, arguments: ["kind": "event"], engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertNotNil(noID["error"])
        let badSpan = await PhoneVoiceTools.run(removeTool, arguments: ["kind": "event", "id": "e_1", "span": "all"],
                                                engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertNotNil(badSpan["error"])
        var noReminderSharing = phonePreferences()
        noReminderSharing.reminders = false
        engine.savePreferences(noReminderSharing)
        let notShared = await PhoneVoiceTools.run(removeTool, arguments: ["kind": "reminder", "id": "r_milk"],
                                                  engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertNotNil(notShared["error"], "Reminders turned off mid-call: none deleted")
        XCTAssertNotNil(PhoneVoiceTools.localTime("2026-10-16T15:00"))
        XCTAssertEqual(PhoneVoiceTools.localTime("2026-10-16")?.isDate, true)
        XCTAssertNil(PhoneVoiceTools.localTime("Thursday"))
    }

    func testPhoneChangeApproveWaitsForTheUsersOwnYes() async throws {
        PhoneVoiceTools.arrivalTurns = [:]
        let source = FakePhoneCalendarSource()
        let host = FakePhoneHost()
        let engine = makePhoneEngine(source: source)
        engine.savePreferences(phonePreferences())
        host.changes = [["id": "ch_yes", "kind": "add_reminder", "auto": false,
                         "fields": ["title": "Call the plumber"]]]
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        let changesTool = try XCTUnwrap(PhoneVoiceTools.tools(for: phonePreferences(), access: .full,
                                                              remindersAuthorized: true).first)
        let answer: (PhoneChangePrompt, Bool) async -> Void = { prompt, approve in await engine.answer(prompt, approve: approve) }
        // The turn current when the model first heard of it can't approve it.
        let arrival = UUID()
        _ = await PhoneVoiceTools.run(changesTool, arguments: ["action": "list"], engine: engine,
                                      lastUserTurn: { (arrival, "what did Hermes ask for") }, answer: answer)
        let stale = await PhoneVoiceTools.run(changesTool, arguments: ["action": "approve", "id": "ch_yes"],
                                              engine: engine, confirmed: { _, _ in true },
                                              lastUserTurn: { (arrival, "yes") }, answer: answer)
        XCTAssertNotNil(stale["error"], "A yes said before the change was known can't approve it")
        XCTAssertFalse(source.applied.contains("ch_yes"))
        // A yes said after it was known does.
        let approved = await PhoneVoiceTools.run(changesTool, arguments: ["action": "approve", "id": "ch_yes"],
                                                 engine: engine, confirmed: { _, _ in true },
                                                 lastUserTurn: { (UUID(), "yes") }, answer: answer)
        XCTAssertNotNil(approved["result"], approved["error"] ?? "")
        XCTAssertEqual(source.applied, ["ch_yes"])
        // Dismissing needs no yes.
        host.changes = [["id": "ch_dismiss", "kind": "add_reminder", "auto": false,
                         "fields": ["title": "Move the car"]]]
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        let dismissed = await PhoneVoiceTools.run(changesTool, arguments: ["action": "dismiss", "id": "ch_dismiss"],
                                                  engine: engine, answer: answer)
        XCTAssertNotNil(dismissed["result"])
        XCTAssertFalse(source.applied.contains("ch_dismiss"))
    }

    func testPhoneChangeStillWaitingFromAnEarlierCallIsAnchoredToTheNewCall() async throws {
        let source = FakePhoneCalendarSource()
        let host = FakePhoneHost()
        let engine = makePhoneEngine(source: source)
        engine.savePreferences(phonePreferences())
        host.changes = [["id": "ch_yes", "kind": "add_reminder", "auto": false,
                         "fields": ["title": "Call the plumber"]]]
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        let changesTool = try XCTUnwrap(PhoneVoiceTools.tools(for: phonePreferences(), access: .full,
                                                              remindersAuthorized: true).first)
        let answer: (PhoneChangePrompt, Bool) async -> Void = { prompt, approve in await engine.answer(prompt, approve: approve) }
        // Heard of in an earlier call, and still waiting when the next starts.
        PhoneVoiceTools.arrivalTurns = ["ch_yes": UUID()]
        PhoneVoiceTools.beginWatch(waiting: ["ch_yes"], turn: nil)
        // In the new call, a "yes" the model lists it under is the turn it
        // arrived in, so it can't approve it.
        let v = UUID()
        _ = await PhoneVoiceTools.run(changesTool, arguments: ["action": "list"], engine: engine,
                                      lastUserTurn: { (v, "yes") }, answer: answer)
        let stale = await PhoneVoiceTools.run(changesTool, arguments: ["action": "approve", "id": "ch_yes"],
                                              engine: engine, confirmed: { _, _ in true },
                                              lastUserTurn: { (v, "yes") }, answer: answer)
        XCTAssertNotNil(stale["error"], "A yes from before this call heard of the change can't approve it")
        XCTAssertTrue(source.applied.isEmpty)
    }

    func testPhoneChangeApproveExcludesTheArrivalTurnWhileWaitingForAYes() async throws {
        PhoneVoiceTools.arrivalTurns = [:]
        let source = FakePhoneCalendarSource()
        let host = FakePhoneHost()
        let engine = makePhoneEngine(source: source)
        engine.savePreferences(phonePreferences())
        host.changes = [["id": "ch_yes", "kind": "add_reminder", "auto": false,
                         "fields": ["title": "Call the plumber"]]]
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        let changesTool = try XCTUnwrap(PhoneVoiceTools.tools(for: phonePreferences(), access: .full,
                                                              remindersAuthorized: true).first)
        let answer: (PhoneChangePrompt, Bool) async -> Void = { prompt, approve in await engine.answer(prompt, approve: approve) }
        let arrival = UUID()
        _ = await PhoneVoiceTools.run(changesTool, arguments: ["action": "list"], engine: engine,
                                      lastUserTurn: { (arrival, "what did Hermes ask for") }, answer: answer)
        // The poll for the yes is told which turn can't be it.
        var excluded: UUID?
        _ = await PhoneVoiceTools.run(changesTool, arguments: ["action": "approve", "id": "ch_yes"],
                                      engine: engine, confirmed: { _, excluding in excluded = excluding; return false },
                                      lastUserTurn: { (UUID(), "yes") }, answer: answer)
        XCTAssertEqual(excluded, arrival)
        XCTAssertTrue(source.applied.isEmpty)
    }

    // MARK: Voice mode setting hint

    func testVoiceModeNotAllowedIsToldWhereToAllowIt() {
        var preferences = phonePreferences()
        let hint = PhoneVoiceTools.settingHint(for: preferences, mode: .gptLive)
        XCTAssertTrue(hint.contains("GPT-Live"), "Names the mode the user would allow")
        XCTAssertTrue(hint.contains("Calendar & phone"), "Names where it's turned on")
        XCTAssertTrue(hint.contains("shares their calendar and their reminders with Hermes"), hint)
        var alarmsOnly = PhoneSyncPreferences()
        alarmsOnly.alarms = true
        alarmsOnly.destination = preferences.destination
        let alarmsHint = PhoneVoiceTools.settingHint(for: alarmsOnly, mode: .gptLive)
        XCTAssertTrue(alarmsHint.contains("shares their alarms with Hermes, but hasn't let this call use it"), alarmsHint)
        XCTAssertFalse(alarmsHint.contains("calendar"), "Only what's shared is named")
        var peopleOnly = PhoneSyncPreferences()
        peopleOnly.contacts = true
        peopleOnly.destination = preferences.destination
        let peopleHint = PhoneVoiceTools.settingHint(for: peopleOnly, mode: .gptLive)
        XCTAssertTrue(peopleHint.contains("shares the people they picked with Hermes"), peopleHint)
        preferences.setVoiceUse(.gptLive, allowed: true)
        XCTAssertEqual(PhoneVoiceTools.settingHint(for: preferences, mode: .gptLive), "", "An allowed mode has the tools instead")
        XCTAssertFalse(PhoneVoiceTools.settingHint(for: preferences, mode: .geminiLive).isEmpty, "Each mode is its own consent")
        var statusOnly = PhoneSyncPreferences(status: true, focus: true)
        statusOnly.destination = preferences.destination
        XCTAssertEqual(PhoneVoiceTools.settingHint(for: statusOnly, mode: .geminiLive), "", "Only phone status: no calendar to point at")
        preferences.destination = nil
        XCTAssertEqual(PhoneVoiceTools.settingHint(for: preferences, mode: .geminiLive), "", "Nothing shared, nothing to point at")
    }

    // MARK: Alarms, timers and people (plugin 0.30.0)

    func testPhoneAlarmChangesNeedWhatTheyAct() throws {
        let weekly = try XCTUnwrap(PhoneChange(json: ["id": "ch_a", "kind": "set_alarm", "auto": true,
                                                      "fields": ["label": "Wake up", "time": "06:30",
                                                                 "repeats": ["fri", "MON", "tue", "wed", "thu", "sun?"]]]))
        XCTAssertEqual(weekly.fields.time, PhoneClockTime(hour: 6, minute: 30))
        XCTAssertEqual(weekly.fields.repeats, ["mon", "tue", "wed", "thu", "fri"], "Known days, in week order")
        XCTAssertTrue(weekly.kind.addsWithoutAsking)
        XCTAssertNil(PhoneChange(json: ["id": "ch_b", "kind": "set_alarm", "fields": ["time": "6:30"]]), "HH:MM only")
        XCTAssertNil(PhoneChange(json: ["id": "ch_c", "kind": "set_alarm", "fields": ["label": "No time"]]))
        XCTAssertNil(PhoneChange(json: ["id": "ch_d", "kind": "set_timer", "fields": ["seconds": 2]]))
        XCTAssertNotNil(PhoneChange(json: ["id": "ch_e", "kind": "set_timer", "fields": ["seconds": 600]]))
        XCTAssertNil(PhoneChange(json: ["id": "ch_f", "kind": "cancel_alarm", "fields": [String: Any]()]), "A cancellation names its alarm")
        let cancel = try XCTUnwrap(PhoneChange(json: ["id": "ch_g", "kind": "cancel_alarm", "target": ["alarm_id": "a1"]]))
        XCTAssertEqual(cancel.alarmID, "a1")
        XCTAssertFalse(cancel.kind.addsWithoutAsking, "Cancelling always asks")
        XCTAssertTrue(PhoneChangeWording.isRemoval(cancel.kind))

        XCTAssertTrue(PhoneChangeWording.alarmSummary(weekly.fields, kind: .setAlarm).hasPrefix("Wake up · "))
        XCTAssertEqual(PhoneChangeWording.days(["mon", "tue", "wed", "thu", "fri"]), "weekdays")
        XCTAssertEqual(PhoneChangeWording.days(["sat", "sun"]), "weekends")
        XCTAssertNil(PhoneChangeWording.days(nil))
    }

    func testPhoneAlarmNextRingFollowsItsDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        // Wednesday 15 October 2025, 12:00 UTC.
        let now = Date(timeIntervalSince1970: 1_760_529_600)
        let time = PhoneClockTime(hour: 6, minute: 30)
        let once = try XCTUnwrap(PhoneAlarmSources.nextRing(time, repeats: nil, after: now, calendar: calendar))
        XCTAssertEqual(once, Date(timeIntervalSince1970: 1_760_509_800 + 86_400), "Tomorrow, the time having passed today")
        let monday = try XCTUnwrap(PhoneAlarmSources.nextRing(time, repeats: ["mon"], after: now, calendar: calendar))
        XCTAssertEqual(calendar.component(.weekday, from: monday), 2)
        let soonest = try XCTUnwrap(PhoneAlarmSources.nextRing(time, repeats: ["mon", "fri"], after: now, calendar: calendar))
        XCTAssertEqual(calendar.component(.weekday, from: soonest), 6, "Friday comes before Monday")
    }

    func testPhoneAlarmsUnsupportedWithoutAlarmKit() {
        let source = PhoneAlarmSources.system(hasAlarmKit: false)
        XCTAssertFalse(source.isSupported, "A Vision Pro has no AlarmKit; touching it crashed at launch")
        XCTAssertEqual(source.alarms(now: Date(), calendar: .current)?.count, 0)
        // The symbol check finds AlarmKit where it is, or alarms would be
        // off everywhere.
        if #available(iOS 26.0, *) {
            XCTAssertTrue(PhoneAlarmSources.alarmKitLoaded)
            XCTAssertTrue(PhoneAlarmSources.system().isSupported)
        }
    }

    func testPhoneAlarmsAndPeopleSyncAndApply() async throws {
        let source = FakePhoneCalendarSource()
        let alarms = FakePhoneAlarmSource()
        alarms.list = [["id": "a_old", "kind": "alarm", "label": "Gym", "fires_at": "2026-10-15T06:00:00Z"]]
        let host = FakePhoneHost()
        let engine = makePhoneEngine(source: source, alarms: alarms)
        var preferences = phonePreferences()
        preferences.alarms = true
        preferences.contacts = true
        preferences.autoAdd = true
        engine.savePreferences(preferences)
        engine.savePeople([PhonePerson(id: "p_1", name: "Sam Lee", relation: "wife",
                                       phones: [.init(number: "+44 7700 900123", label: "mobile")], birthday: "--04-12")])

        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        let sharing = try XCTUnwrap(host.batches.last?["sharing"] as? [String: Any])
        XCTAssertEqual(sharing["alarms"] as? Bool, true)
        XCTAssertEqual(sharing["contacts"] as? Bool, true)
        XCTAssertEqual((host.batches.last?["alarms"] as? [[String: Any]])?.map { $0["id"] as? String }, ["a_old"])
        let people = try XCTUnwrap(host.batches.last?["contacts"] as? [[String: Any]])
        XCTAssertEqual(people.first?["relation"] as? String, "wife")
        XCTAssertEqual(people.first?["birthday"] as? String, "--04-12")

        // Nothing changed: neither list goes again (nor anything else).
        var sent = host.batches.count
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(host.batches.count, sent)

        // A timer goes straight in with "Add without asking"; a cancellation asks.
        host.changes = [
            ["id": "ch_timer", "kind": "set_timer", "auto": true, "fields": ["label": "Pasta", "seconds": 600]],
            ["id": "ch_cancel", "kind": "cancel_alarm", "auto": false, "target": ["alarm_id": "a_old"]],
        ]
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(alarms.applied.map(\.id), ["ch_timer"])
        XCTAssertTrue(source.applied.isEmpty, "Alarms never reach the calendar")
        XCTAssertEqual(engine.autoAdded?.isAlarm, true)
        let prompt = try XCTUnwrap(engine.prompts.first)
        XCTAssertEqual(prompt.id, "ch_cancel")
        XCTAssertNil(prompt.calendarTitle)
        XCTAssertTrue(prompt.alarmTitle?.hasPrefix("Gym · ") == true)

        await engine.answer(prompt, approve: true)
        XCTAssertEqual(alarms.cancelled, ["a_old"])
        // Undo takes the timer back.
        await engine.undo(try XCTUnwrap(engine.autoAdded))
        XCTAssertEqual(alarms.cancelled, ["a_old", "alarm_1"])
        host.changes = []
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(host.reported.first { $0["id"] as? String == "ch_timer" }?["item_id"] as? String, "alarm_1")
        XCTAssertEqual((host.batches.last?["alarms"] as? [[String: Any]])?.count, 0, "Both gone from the phone")
        // AlarmKit unreadable for a pass: nothing is sent, the host keeps its list.
        alarms.list = [["id": "a_new", "kind": "alarm"]]
        alarms.unreadable = true
        sent = host.batches.count
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertTrue(host.batches.dropFirst(sent).allSatisfy { $0["alarms"] == nil })
        alarms.unreadable = false
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual((host.batches.last?["alarms"] as? [[String: Any]])?.count, 1)

        // Turned off: the host is told, and nothing more goes.
        preferences.alarms = false
        preferences.contacts = false
        engine.savePreferences(preferences)
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        let off = try XCTUnwrap(host.batches.last?["sharing"] as? [String: Any])
        XCTAssertEqual(off["alarms"] as? Bool, false)
        XCTAssertEqual(off["contacts"] as? Bool, false)
        XCTAssertNil(host.batches.last?["contacts"])
    }

    func testPhonePeoplePickedAgainKeepTheirRelation() {
        let picked = [PhonePerson(id: "p_1", name: "Sam Lee (new)"), PhonePerson(id: "p_2", name: "Alex")]
        let people = PhonePeopleStore.merging(picked, into: [PhonePerson(id: "p_1", name: "Sam Lee", relation: "wife")])
        XCTAssertEqual(people.map(\.name), ["Sam Lee (new)", "Alex"])
        XCTAssertEqual(people.first?.relation, "wife")
        let long = PhonePerson(id: "p_3", name: "Kim", relation: String(repeating: "x", count: 60))
        XCTAssertEqual((long.json["relation"] as? String)?.count, PhonePerson.relationLength)
        XCTAssertNil(PhonePerson(id: "p_4", name: "Lee", relation: "  ").json["relation"])
        XCTAssertEqual(PhonePerson.birthday(DateComponents(year: 1990, month: 4, day: 12)), "1990-04-12")
        XCTAssertEqual(PhonePerson.birthday(DateComponents(month: 4, day: 12)), "--04-12")
        XCTAssertEqual(PhonePerson.id(forContact: "ABC"), PhonePerson.id(forContact: "ABC"))
        XCTAssertNotEqual(PhonePerson.id(forContact: "ABC"), PhonePerson.id(forContact: "ABD"))
        XCTAssertEqual(PhonePerson.plainNumber("+44\u{00A0}7700\u{2011}900123 "), "+44 7700-900123")
        XCTAssertTrue(PhonePerson.isDialable("+44 7700-900123"))
        XCTAssertFalse(PhonePerson.isDialable("1-800-FLOWERS"), "The host takes only dialling signs")
        XCTAssertFalse(PhonePerson.isDialable("--- ..."))
    }

    /// An update that names another calendar or list moves the item there,
    /// or fails: one that's gone or can't be changed is never silently
    /// skipped while the rest of the change is applied.
    func testPhoneUpdateMovesOrRefusesItsNamedCalendar() throws {
        let calendars = ["work": true, "shared": false]
        func destination(_ id: String?) throws -> Bool? {
            try EventKitPhoneSource.moveDestination(id, find: { calendars[$0] }, isWritable: { $0 })
        }
        XCTAssertNil(try destination(nil), "No calendar named: it stays where it is")
        XCTAssertEqual(try destination("work"), true)
        // The item is still there: the reason names the missing calendar,
        // not the item (#876).
        XCTAssertThrowsError(try destination("deleted")) { error in
            guard case PhoneCalendarSourceError.noSuchCalendar = error else { return XCTFail("\(error)") }
            XCTAssertNotEqual(error.localizedDescription, PhoneCalendarSourceError.notFound.localizedDescription)
        }
        XCTAssertThrowsError(try destination("shared")) { error in
            guard case PhoneCalendarSourceError.readOnly = error else { return XCTFail("\(error)") }
        }
    }

    /// An all-day event lasts whole calendar days: a day with a clock
    /// change (23 or 25 hours) never stretches it into the next date.
    func testPhoneAllDayEventEndsOnItsOwnDayAcrossAClockChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        func day(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day)))
        }
        // New on the 23-hour day the clocks go forward: ends at the next midnight.
        XCTAssertEqual(EventKitPhoneSource.allDayEnd(start: try day(2026, 3, 29), previousLength: nil, calendar: calendar), try day(2026, 3, 30))
        // A one-day event moved onto it keeps one day.
        XCTAssertEqual(EventKitPhoneSource.allDayEnd(start: try day(2026, 3, 29), previousLength: 86_400, calendar: calendar), try day(2026, 3, 30))
        // One moved off the 25-hour day the clocks go back keeps one day too.
        XCTAssertEqual(EventKitPhoneSource.allDayEnd(start: try day(2026, 11, 2), previousLength: 25 * 3600, calendar: calendar), try day(2026, 11, 3))
        // A week across the change keeps its seven days.
        XCTAssertEqual(EventKitPhoneSource.allDayEnd(start: try day(2026, 3, 26), previousLength: 7 * 86_400, calendar: calendar), try day(2026, 4, 2))
        // A short timed event made all-day: one day.
        XCTAssertEqual(EventKitPhoneSource.allDayEnd(start: try day(2026, 3, 29), previousLength: 3600, calendar: calendar), try day(2026, 3, 30))
    }

    /// A due-date update moves only the due alarm: the user's own alarms
    /// on the reminder (a place, another time, an offset) stay (#1001).
    func testPhoneReminderDueUpdateKeepsTheUsersOwnAlarms() throws {
        let oldDue = Date(timeIntervalSince1970: 1_760_400_000)
        let newDue = oldDue.addingTimeInterval(2 * 3600)
        let dueAlarm = EKAlarm(absoluteDate: oldDue)
        let earlier = EKAlarm(absoluteDate: oldDue.addingTimeInterval(-86_400))
        let offset = EKAlarm(relativeOffset: -900)
        let place = EKAlarm()
        place.structuredLocation = EKStructuredLocation(title: "Home")
        place.proximity = .enter

        let moved = EventKitPhoneSource.dueAlarms([dueAlarm, earlier, offset, place], oldDue: oldDue, newDue: newDue)
        XCTAssertFalse(moved.contains { $0 === dueAlarm })
        XCTAssertTrue(moved.contains { $0 === earlier })
        XCTAssertTrue(moved.contains { $0 === offset })
        XCTAssertTrue(moved.contains { $0 === place })
        XCTAssertEqual(moved.compactMap(\.absoluteDate).filter { $0 == newDue }.count, 1)
        XCTAssertEqual(moved.count, 4)

        // Made date-only: the due alarm goes, nothing else does.
        let dateOnly = EventKitPhoneSource.dueAlarms([dueAlarm, earlier, place], oldDue: oldDue, newDue: nil)
        XCTAssertEqual(dateOnly.count, 2)
        XCTAssertTrue(dateOnly.contains { $0 === earlier } && dateOnly.contains { $0 === place })

        // Sent again unchanged: still one due alarm.
        let resent = EventKitPhoneSource.dueAlarms([dueAlarm, place], oldDue: oldDue, newDue: oldDue)
        XCTAssertEqual(resent.compactMap(\.absoluteDate), [oldDue])
        XCTAssertEqual(resent.count, 2)

        // An offset counts from the start date, which may not be the due
        // date: it stays, and the new due time still gets its alarm.
        let atStart = EKAlarm(relativeOffset: 0)
        let following = EventKitPhoneSource.dueAlarms([atStart], oldDue: oldDue, newDue: newDue)
        XCTAssertEqual(following.count, 2)
        XCTAssertIdentical(following.first, atStart)
        XCTAssertEqual(following.last?.absoluteDate, newDue)

        // Only one alarm is the due alarm: the user's second one half a
        // minute later stays.
        let halfMinute = EKAlarm(absoluteDate: oldDue.addingTimeInterval(30))
        let pair = EventKitPhoneSource.dueAlarms([halfMinute, dueAlarm], oldDue: oldDue, newDue: newDue)
        XCTAssertFalse(pair.contains { $0 === dueAlarm })
        XCTAssertTrue(pair.contains { $0 === halfMinute })
        XCTAssertEqual(pair.count, 2)

        // A reminder with no due time before: the user's alarm at that
        // moment is theirs, and the new due time gets its own alarm.
        let mine = EKAlarm(absoluteDate: oldDue)
        let fresh = EventKitPhoneSource.dueAlarms([mine], oldDue: nil, newDue: newDue)
        XCTAssertTrue(fresh.contains { $0 === mine })
        XCTAssertEqual(fresh.count, 2)
    }

    func testPhoneReminderTimedDueReadsOnlyATime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        XCTAssertNil(EventKitPhoneSource.timedDue(nil, calendar: calendar))
        XCTAssertNil(EventKitPhoneSource.timedDue(DateComponents(year: 2026, month: 10, day: 20), calendar: calendar))
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let parts = DateComponents(timeZone: tokyo, year: 2026, month: 10, day: 20, hour: 9, minute: 30)
        var expected = Calendar(identifier: .gregorian)
        expected.timeZone = tokyo
        XCTAssertEqual(EventKitPhoneSource.timedDue(parts, calendar: calendar), expected.date(from: parts))
    }

    func testPhoneVoiceCallsSetAlarmsAndTimers() async throws {
        let alarms = FakePhoneAlarmSource()
        let engine = makePhoneEngine(source: FakePhoneCalendarSource(), alarms: alarms)
        var preferences = phonePreferences()
        preferences.alarms = true
        engine.savePreferences(preferences)
        XCTAssertFalse(PhoneVoiceTools.tools(for: preferences, access: .full, remindersAuthorized: true).map(\.name)
            .contains(PhoneVoiceTools.alarmTool), "Not without AlarmKit access")
        let tool = try XCTUnwrap(PhoneVoiceTools.tools(for: preferences, access: .full, remindersAuthorized: true,
                                                       alarmsAuthorized: true).last)
        XCTAssertEqual(tool.name, PhoneVoiceTools.alarmTool)
        let answer: (PhoneChangePrompt, Bool) async -> Void = { _, _ in }

        let timer = await PhoneVoiceTools.run(tool, arguments: ["kind": "timer", "minutes": 10, "label": "Pasta"],
                                              engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertNotNil(timer["result"], timer["error"] ?? "")
        XCTAssertEqual(alarms.applied.last?.fields.seconds, 600)
        let alarm = await PhoneVoiceTools.run(tool, arguments: ["kind": "alarm", "time": "6:45", "days": ["sun", " Sat ", "sun"]],
                                              engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertNotNil(alarm["result"], alarm["error"] ?? "")
        XCTAssertEqual(alarms.applied.last?.fields.time, PhoneClockTime(hour: 6, minute: 45))
        XCTAssertEqual(alarms.applied.last?.fields.repeats, ["sat", "sun"])
        let bad = await PhoneVoiceTools.run(tool, arguments: ["kind": "timer", "minutes": 0], engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertNotNil(bad["error"])
        // Past what an Int holds: refused as out of range, not trapped on.
        let short = await PhoneVoiceTools.run(tool, arguments: ["kind": "timer", "minutes": 0.01], engine: engine, confirmed: { _, _ in true }, answer: answer)
        let huge = await PhoneVoiceTools.run(tool, arguments: ["kind": "timer", "minutes": 1e30], engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertNotNil(huge["error"])
        XCTAssertEqual(huge["error"], short["error"], "The same range error as a too-short timer")
        let both = await PhoneVoiceTools.run(tool, arguments: ["kind": "alarm", "time": "07:00", "date": "2030-01-05",
                                                           "days": ["mon"]], engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertNotNil(both["error"], "A date and days together is asked about, not half-dropped")
        let funday = await PhoneVoiceTools.run(tool, arguments: ["kind": "alarm", "time": "07:00", "days": ["funday"]],
                                               engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertNotNil(funday["error"], "Not turned into a one-off")
        let dateTime = await PhoneVoiceTools.run(tool, arguments: ["kind": "alarm", "time": "07:00", "date": "2030-01-05T10:00"],
                                                 engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertNotNil(dateTime["error"], "Not turned into a daily alarm")
        XCTAssertEqual(alarms.applied.count, 2)
    }

    func testPhoneVoiceCallsChangeAndCompleteOnThePhone() async throws {
        let source = FakePhoneCalendarSource()
        let engine = makePhoneEngine(source: source)
        engine.savePreferences(phonePreferences())
        let answer: (PhoneChangePrompt, Bool) async -> Void = { _, _ in }
        let tool = try XCTUnwrap(PhoneVoiceTools.tools(for: phonePreferences(), access: .full, remindersAuthorized: true)
            .first { $0.name == PhoneVoiceTools.updateTool })
        XCTAssertTrue(tool.description.contains("not Hermes"), "A change never goes to Hermes as a job")
        let properties = try XCTUnwrap(tool.parameters["properties"] as? [String: Any])
        XCTAssertNotNil(properties["due"])
        XCTAssertNotNil(properties["completed"])

        // Moving a reminder: an update, by its id.
        let moved = await PhoneVoiceTools.run(tool, arguments: ["kind": "reminder", "id": "r_milk", "due": "2026-10-16T17:00"],
                                              engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertNotNil(moved["result"], moved["error"] ?? "")
        let update = try XCTUnwrap(source.appliedChanges.last)
        XCTAssertEqual(update.kind, .updateReminder)
        XCTAssertEqual(update.reminderID, "r_milk")
        XCTAssertNotNil(update.fields.due)
        XCTAssertEqual(update.fields.dueAllDay, false)

        // Marking it done alone is a completion.
        let done = await PhoneVoiceTools.run(tool, arguments: ["kind": "reminder", "id": "r_milk", "completed": true],
                                             engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertNotNil(done["result"], done["error"] ?? "")
        XCTAssertEqual(source.appliedChanges.last?.kind, .completeReminder)
        XCTAssertEqual(source.appliedChanges.last?.fields.completed, true)

        // An event moved for this one of a series, keeping the rest.
        let event = await PhoneVoiceTools.run(tool, arguments: ["kind": "event", "id": "e_dentist", "start": "2026-10-16T16:00",
                                                                "title": "Dentist (moved)"],
                                              engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertNotNil(event["result"], event["error"] ?? "")
        let eventChange = try XCTUnwrap(source.appliedChanges.last)
        XCTAssertEqual(eventChange.kind, .updateEvent)
        XCTAssertEqual(eventChange.eventID, "e_dentist")
        XCTAssertEqual(eventChange.span, "this")
        XCTAssertEqual(eventChange.fields.title, "Dentist (moved)")
        XCTAssertNil(eventChange.fields.end, "Moving the start keeps its length")

        let count = source.appliedChanges.count
        let nothing = await PhoneVoiceTools.run(tool, arguments: ["kind": "event", "id": "e_dentist"], engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertNotNil(nothing["error"], "Nothing to change")
        let both = await PhoneVoiceTools.run(tool, arguments: ["kind": "reminder", "id": "r_milk", "completed": true, "title": "Oat milk"],
                                             engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertNotNil(both["error"], "Done and renamed at once is asked about")
        let badTime = await PhoneVoiceTools.run(tool, arguments: ["kind": "event", "id": "e_dentist", "start": "Friday"],
                                                engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertNotNil(badTime["error"])
        // Only on the user's own yes.
        let unconfirmed = await PhoneVoiceTools.run(tool, arguments: ["kind": "reminder", "id": "r_milk", "title": "Oat milk"],
                                                    engine: engine, confirmed: { _, _ in false }, answer: answer)
        XCTAssertNotNil(unconfirmed["error"])
        // Not in a calendar the user left out since the id was read.
        source.itemCalendars["e_hidden"] = "ek_work"
        var leftOut = phonePreferences()
        leftOut.hiddenCalendars = ["ek_work"]
        engine.savePreferences(leftOut)
        let hidden = await PhoneVoiceTools.run(tool, arguments: ["kind": "event", "id": "e_hidden", "title": "Moved"],
                                               engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertNotNil(hidden["error"])
        XCTAssertEqual(source.appliedChanges.count, count, "None of those reached the phone's calendar")
        // Add-only events are never read: nothing to change them by.
        var eventsOnly = phonePreferences()
        eventsOnly.reminders = false
        XCTAssertFalse(PhoneVoiceTools.tools(for: eventsOnly, access: .writeOnly, remindersAuthorized: true).map(\.name)
            .contains(PhoneVoiceTools.updateTool))
    }

    func testPhoneVoiceCallsListAndCancelAlarms() async throws {
        let alarms = FakePhoneAlarmSource()
        alarms.list = [["id": "alarm_wake", "kind": "alarm", "label": "Wake up"]]
        let engine = makePhoneEngine(source: FakePhoneCalendarSource(), alarms: alarms)
        var preferences = phonePreferences()
        preferences.alarms = true
        engine.savePreferences(preferences)
        let tool = try XCTUnwrap(PhoneVoiceTools.tools(for: preferences, access: .full, remindersAuthorized: true,
                                                       alarmsAuthorized: true).last)
        XCTAssertTrue(tool.description.contains("not Hermes"))
        let answer: (PhoneChangePrompt, Bool) async -> Void = { _, _ in }

        let listed = await PhoneVoiceTools.run(tool, arguments: ["kind": "list"], engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertTrue(listed["result"]?.contains("alarm_wake") == true, listed["error"] ?? "")
        let unconfirmed = await PhoneVoiceTools.run(tool, arguments: ["kind": "cancel", "id": "alarm_wake"], engine: engine,
                                                    confirmed: { _, _ in false }, answer: answer)
        XCTAssertNotNil(unconfirmed["error"])
        XCTAssertEqual(alarms.cancelled, [], "Not without the user's yes")
        let noID = await PhoneVoiceTools.run(tool, arguments: ["kind": "cancel"], engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertNotNil(noID["error"])
        let cancelled = await PhoneVoiceTools.run(tool, arguments: ["kind": "cancel", "id": "alarm_wake"], engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertNotNil(cancelled["result"], cancelled["error"] ?? "")
        XCTAssertEqual(alarms.cancelled, ["alarm_wake"])
        // A timer set in the call answers with its id, to cancel it by.
        let timer = await PhoneVoiceTools.run(tool, arguments: ["kind": "timer", "minutes": 5], engine: engine, confirmed: { _, _ in true }, answer: answer)
        XCTAssertTrue(timer["result"]?.contains("alarm_1") == true, timer["error"] ?? "")
    }

    func testClassicVoiceAnswersTheOneCardWaiting() throws {
        let words = SpokenApprovals.Waiting(phoneChanges: ["ch_1"])
        XCTAssertEqual(SpokenApprovals.answer("Yes", waiting: words)?.target, .phoneChange(id: "ch_1"))
        XCTAssertEqual(SpokenApprovals.answer("Yes, change it.", waiting: words)?.approve, true)
        XCTAssertEqual(SpokenApprovals.answer("No", waiting: words)?.approve, false)
        XCTAssertEqual(SpokenApprovals.answer("No thanks", waiting: words)?.approve, false)
        XCTAssertNil(SpokenApprovals.answer("No, make it five instead", waiting: words), "A change is Hermes' to make")
        XCTAssertNil(SpokenApprovals.answer("What's on my calendar tomorrow?", waiting: words))
        XCTAssertNil(SpokenApprovals.answer("yes?", waiting: words), "Never a question")
        XCTAssertEqual(SpokenApprovals.answer("Cancel", waiting: words)?.approve, false, "Cancel declines a change")
        XCTAssertEqual(SpokenApprovals.answer("Cancel it", waiting: words)?.approve, false)
        XCTAssertEqual(SpokenApprovals.answer("Never mind", waiting: words)?.approve, false)
        let alarm = SpokenApprovals.Waiting(phoneChanges: ["ch_2"], cancellingAlarms: ["ch_2"])
        XCTAssertEqual(SpokenApprovals.answer("Cancel it", waiting: alarm)?.approve, true, "Cancelling an alarm: cancel it is the yes")

        let approval = SpokenApprovals.Waiting(chatApprovals: ["m_1"])
        XCTAssertEqual(SpokenApprovals.answer("go ahead", waiting: approval)?.target, .chatApproval(messageID: "m_1"))
        XCTAssertEqual(SpokenApprovals.answer("go ahead", waiting: approval)?.approve, true)
        XCTAssertNil(SpokenApprovals.answer("go to the store", waiting: approval))

        let confirm = PresentedConfirm(id: "p_1", title: "Send the email", preview: "Hi Sam", actionLabel: "Send",
                                       spokenYes: ["send it"], sessionID: nil, expiresAt: nil, maps: nil)
        let presented = SpokenApprovals.Waiting(presented: [confirm])
        XCTAssertEqual(SpokenApprovals.answer("send it", waiting: presented)?.target, .presented(id: "p_1"))
        XCTAssertEqual(SpokenApprovals.answer("no", waiting: presented)?.approve, false)
        XCTAssertEqual(SpokenApprovals.answer("don't send it", waiting: presented)?.approve, false, "A no-led phrase never confirms")

        // A change already waiting when the user last spoke or typed wasn't
        // asked for in the reply this yes answers: it answers nothing, so a
        // yes to something else can't delete.
        let stale = SpokenApprovals.Waiting(phoneChanges: ["ch_old"], staleChanges: ["ch_old"])
        XCTAssertNil(SpokenApprovals.answer("Yes", waiting: stale))
        XCTAssertNil(SpokenApprovals.answer("Yes, delete it.", waiting: stale))
        XCTAssertNil(SpokenApprovals.answer("No", waiting: stale))
        // One asked for since still counts: a yes with a stale one waiting
        // too is ambiguous.
        let both = SpokenApprovals.Waiting(phoneChanges: ["ch_new", "ch_old"], staleChanges: ["ch_old"])
        XCTAssertNil(SpokenApprovals.answer("Yes", waiting: both))
        let fresh = SpokenApprovals.Waiting(phoneChanges: ["ch_new"], staleChanges: ["ch_old"])
        XCTAssertEqual(SpokenApprovals.answer("Yes", waiting: fresh)?.target, .phoneChange(id: "ch_new"))

        // Nothing waiting, or more than one: a yes answers nothing.
        XCTAssertNil(SpokenApprovals.answer("Yes", waiting: SpokenApprovals.Waiting()))
        XCTAssertNil(SpokenApprovals.answer("Yes", waiting: SpokenApprovals.Waiting(phoneChanges: ["ch_1"], chatApprovals: ["m_1"])))
        XCTAssertNil(SpokenApprovals.answer("Yes", waiting: SpokenApprovals.Waiting(phoneChanges: ["ch_1", "ch_2"])))
    }

    // MARK: Helpers

    private func makePhoneEngine(source: FakePhoneCalendarSource,
                                 alarms: PhoneAlarmSource = FakePhoneAlarmSource(),
                                 folder given: URL? = nil, defaults givenDefaults: UserDefaults? = nil,
                                 keys box: PhoneKeyBox = PhoneKeyBox(),
                                 now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_760_400_000) }) -> PhoneSyncEngine {
        let folder = given ?? FileManager.default.temporaryDirectory.appendingPathComponent("phone-sync-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let defaults = givenDefaults ?? UserDefaults(suiteName: "phone-sync-\(UUID().uuidString)")!
        PhoneFocusSnapshot(active: true, label: "Work", holdCalls: true, at: Date(timeIntervalSince1970: 1_760_000_000))
            .save(to: defaults)
        let keys = PhoneSyncKeyStore(load: { box.key }, save: { box.key = $0 }, clear: { box.key = nil })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return PhoneSyncEngine(calendarSource: source, statusSource: FakePhoneStatusSource(), alarmSource: alarms,
                               store: PhoneSyncStateStore(url: folder.appendingPathComponent("state.json")),
                               keys: keys, defaults: defaults, calendar: calendar, now: now)
    }

    private func phonePreferences() -> PhoneSyncPreferences {
        var preferences = PhoneSyncPreferences(calendar: .full, reminders: true, status: true, focus: true)
        preferences.destination = PhoneSyncDestination(dashboardID: UUID(), profile: "default", host: "hermes.local")
        return preferences
    }

    private func phoneEvent(_ id: String, _ title: String) -> [String: Any] {
        ["id": id, "calendar_id": "c_1", "title": title, "start": "2026-10-15T09:00:00Z", "end": "2026-10-15T10:00:00Z",
         "all_day": false]
    }
}

private final class FakePhoneAlarmSource: PhoneAlarmSource {
    var isSupported: Bool { true }
    var authorized = true
    var list: [[String: Any]] = []
    var unreadable = false
    private(set) var applied: [PhoneChange] = []
    private(set) var cancelled: [String] = []

    func requestAccess() async throws {}
    func alarms(now: Date, calendar: Calendar) -> [[String: Any]]? { unreadable ? nil : list }
    func apply(_ change: PhoneChange, now: Date) async throws -> String {
        // Like AlarmKitPhoneSource: a cancellation takes the alarm back.
        if change.kind == .cancelAlarm {
            let id = change.alarmID ?? ""
            try cancel(id: id)
            return id
        }
        applied.append(change)
        let id = "alarm_\(applied.count)"
        list.append(["id": id, "kind": change.kind == .setTimer ? "timer" : "alarm"])
        return id
    }
    func cancel(id: String) throws {
        cancelled.append(id)
        list.removeAll { $0["id"] as? String == id }
    }
}

private final class PhoneKeyBox {
    var key: PhoneSyncCrypto.SessionKey?
}

private final class FakePhoneCalendarSource: PhoneCalendarSource {
    var events: [[String: Any]] = []
    var reminderItems: [[String: Any]] = []
    private(set) var applied: [String] = []
    private(set) var appliedChanges: [PhoneChange] = []

    var eventAccess: PhoneCalendarAccess { .full }
    var remindersAuthorized: Bool { true }
    func requestAccess(calendar: PhoneCalendarAccess, reminders: Bool) async throws {}
    func calendars(eventsReadable: Bool, reminders: Bool) -> [[String: Any]] {
        [["id": "c_1", "title": "Personal", "kind": "event", "writable": true, "shared": false, "default": true]]
    }
    func events(from: Date, to: Date, hidden: Set<String>, details: Bool, emails: Bool, limit: Int) -> [[String: Any]] { events }
    func reminders(hidden: Set<String>, details: Bool, completedSince: Date, limit: Int) async -> [[String: Any]] { reminderItems }
    /// Holds each apply until releaseApply, to land something in between.
    var holdApply = false
    private let holdLock = NSLock()
    private var held: CheckedContinuation<Void, Never>?
    var isHolding: Bool { holdLock.withLock { held != nil } }
    func releaseApply() {
        holdApply = false
        holdLock.withLock { held }?.resume()
        holdLock.withLock { held = nil }
    }

    func apply(_ change: PhoneChange, window: (from: Date, to: Date)) async throws -> String? {
        if holdApply {
            await withCheckedContinuation { continuation in holdLock.withLock { held = continuation } }
        }
        applied.append(change.id)
        appliedChanges.append(change)
        return "item_\(change.id)"
    }
    func removeAdded(itemID: String, isEvent: Bool, window: (from: Date, to: Date)) async throws {}
    /// Item id to EventKit calendar id, for left-out calendars.
    var itemCalendars: [String: String] = [:]
    func itemCalendar(itemID: String, isEvent: Bool, window: (from: Date, to: Date)) async -> String? { itemCalendars[itemID] }
    func calendarTitle(id: String?, forEvents: Bool) -> String? { "Personal" }
    func eventKitCalendarID(forShared id: String) -> String? { id }
    func startObservingChanges(_ handler: @escaping @Sendable () -> Void) {}
}

@MainActor
private final class FakePhoneStatusSource: PhoneStatusSource {
    func snapshot() async -> [String: Any] {
        ["at": "2026-10-14T00:00:00Z", "battery": 0.5, "charging": false, "carplay": false, "activity": "stationary"]
    }
    func requestMotionAccess() async {}
}

/// The notifier's phone routes, enough to agree keys, open uploads and
/// answer exchanges.
@MainActor
private final class FakePhoneHost {
    private let hostKey = Curve25519.KeyAgreement.PrivateKey()
    private var keys: PhoneSyncCrypto.SessionKey?
    private(set) var keyRequests = 0
    private(set) var statusRequests = 0
    private(set) var batches: [[String: Any]] = []
    private(set) var reported: [[String: Any]] = []
    var changes: [[String: Any]] = []
    var ignoreResults = false
    var reportsPending = true
    /// The serialized size of each upload's body.
    private(set) var ingestBodyBytes: [Int] = []
    /// Answers this upload (1-based, counted from when it's set) with a 503.
    var failIngest: Int? { didSet { ingestsSinceFail = 0 } }
    private var ingestsSinceFail = 0
    /// Thrown by every upload while set, as the notifier's refusals are.
    var ingestError: Error?

    func forgetKey() {
        keys = nil
    }

    /// What phone_store counts against MAX_ITEMS.
    static func items(in batch: [String: Any]) -> Int {
        let events = batch["events"] as? [String: Any] ?? [:]
        let reminders = batch["reminders"] as? [String: Any] ?? [:]
        return (batch["calendars"] as? [Any] ?? []).count + (events["upsert"] as? [Any] ?? []).count
            + (events["delete"] as? [Any] ?? []).count + (reminders["upsert"] as? [Any] ?? []).count
            + (reminders["delete"] as? [Any] ?? []).count + (batch["alarms"] as? [Any] ?? []).count
            + (batch["contacts"] as? [Any] ?? []).count
    }

    func handle(path: String, method: String, body: [String: Any]?) async throws -> [String: Any] {
        let base = PhoneSyncEngine.base
        if path.hasPrefix("\(base)/status") {
            statusRequests += 1
            var answer: [String: Any] = ["generation": "g1"]
            if let keys {
                // phone_store status: the changes still waiting, unless an
                // older plugin's.
                var device: [String: Any] = ["kid": keys.kid]
                if reportsPending {
                    let answered = Set(reported.compactMap { $0["id"] as? String })
                    device["pending"] = changes.filter { !answered.contains($0["id"] as? String ?? "") }.count
                }
                answer["device"] = device
            }
            return answer
        }
        if path == "\(base)/key" {
            keyRequests += 1
            let deviceID = try XCTUnwrap(body?["device_id"] as? String)
            let devicePublic = try XCTUnwrap(NotificationE2E.base64URLDecoded(try XCTUnwrap(body?["public_key"] as? String)))
            let hostPublic = hostKey.publicKey.rawRepresentation
            let kid = PhoneSyncCrypto.keyID(devicePublic: devicePublic, hostPublic: hostPublic)
            let shared = try hostKey.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: devicePublic))
            func derive(_ purpose: Data) -> Data {
                let info = purpose + Data("\n\(deviceID)\n".utf8) + devicePublic + hostPublic
                return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: PhoneSyncCrypto.salt, sharedInfo: info, outputByteCount: 32)
                    .withUnsafeBytes { Data($0) }
            }
            keys = PhoneSyncCrypto.SessionKey(kid: kid, ingest: derive(PhoneSyncCrypto.ingestInfo),
                                              request: derive(PhoneSyncCrypto.exchangeRequestInfo),
                                              answer: derive(PhoneSyncCrypto.exchangeAnswerInfo))
            return ["host_public_key": NotificationE2E.base64URL(hostPublic), "kid": kid, "generation": "g1"]
        }
        let body = try XCTUnwrap(body)
        guard let keys, body["kid"] as? String == keys.kid else {
            throw DashboardTicketBridgeError.http(status: 409, detail: "unknown_key")
        }
        let deviceID = try XCTUnwrap(body["device_id"] as? String)
        let nonce = try XCTUnwrap(NotificationE2E.base64URLDecoded(try XCTUnwrap(body["nonce"] as? String)))
        let sealed = try XCTUnwrap(NotificationE2E.base64URLDecoded(try XCTUnwrap(body["ct"] as? String)))
        let box = try ChaChaPoly.SealedBox(combined: nonce + sealed)
        if path == "\(base)/ingest" {
            if let ingestError { throw ingestError }
            ingestsSinceFail += 1
            if let failIngest, ingestsSinceFail == failIngest {
                throw DashboardTicketBridgeError.http(status: 503, detail: "busy")
            }
            let size = try JSONSerialization.data(withJSONObject: body).count
            ingestBodyBytes.append(size)
            // dashboard/api/phone_data.py PHONE_MAX_INGEST_BODY_BYTES
            if size > 4 * 1024 * 1024 {
                throw DashboardTicketBridgeError.http(status: 413, detail: "Request body is too large")
            }
            let aad = PhoneSyncCrypto.ingestAAD(kid: keys.kid, deviceID: deviceID, batchID: try XCTUnwrap(body["batch_id"] as? String))
            let plaintext = try ChaChaPoly.open(box, using: SymmetricKey(data: keys.ingest), authenticating: aad)
            let batch = try XCTUnwrap(JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
            // phone_store MAX_ITEMS
            if Self.items(in: batch) > 5_000 {
                throw DashboardTicketBridgeError.http(status: 413, detail: "At most 5000 items per batch")
            }
            batches.append(batch)
            return ["ok": true, "pending": changes.count]
        }
        if path == "\(base)/exchange" {
            let op = try XCTUnwrap(body["op"] as? String)
            let callID = try XCTUnwrap(body["call_id"] as? String)
            let aad = PhoneSyncCrypto.exchangeAAD(direction: "request", op: op, kid: keys.kid, deviceID: deviceID, callID: callID)
            let plaintext = try ChaChaPoly.open(box, using: SymmetricKey(data: keys.request), authenticating: aad)
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
            if !ignoreResults { reported.append(contentsOf: request["results"] as? [[String: Any]] ?? []) }
            let answered = Set(reported.compactMap { $0["id"] as? String })
            let waiting = changes.filter { !answered.contains($0["id"] as? String ?? "") }
            let answerJSON: [String: Any] = ["call_id": callID, "changes": waiting]
            let answer = try JSONSerialization.data(withJSONObject: answerJSON)
            let answerAAD = PhoneSyncCrypto.exchangeAAD(direction: "answer", op: op, kid: keys.kid, deviceID: deviceID, callID: callID)
            let sealedAnswer = try ChaChaPoly.seal(answer, using: SymmetricKey(data: keys.answer), authenticating: answerAAD)
            return ["ok": true, "v": 1, "nonce": NotificationE2E.base64URL(Data(sealedAnswer.nonce)),
                    "ct": NotificationE2E.base64URL(sealedAnswer.ciphertext + sealedAnswer.tag)]
        }
        if path.hasSuffix("/voice-tools/call") {
            let callID = try XCTUnwrap(body["call_id"] as? String)
            XCTAssertEqual(body["op"] as? String, "voice")
            let aad = PhoneSyncCrypto.exchangeAAD(direction: "request", op: "voice", kid: keys.kid, deviceID: deviceID, callID: callID)
            let plaintext = try ChaChaPoly.open(box, using: SymmetricKey(data: keys.request), authenticating: aad)
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
            let result: [String: Any] = ["ok": true, "tool": request["tool"] ?? "", "args": request["args"] ?? [:]]
            let answer = try JSONSerialization.data(withJSONObject: ["call_id": callID, "result": result])
            let answerAAD = PhoneSyncCrypto.exchangeAAD(direction: "answer", op: "voice", kid: keys.kid, deviceID: deviceID, callID: callID)
            let sealedAnswer = try ChaChaPoly.seal(answer, using: SymmetricKey(data: keys.answer), authenticating: answerAAD)
            return ["ok": true, "v": 1, "nonce": NotificationE2E.base64URL(Data(sealedAnswer.nonce)),
                    "ct": NotificationE2E.base64URL(sealedAnswer.ciphertext + sealedAnswer.tag)]
        }
        throw DashboardTicketBridgeError.http(status: 404, detail: path)
    }
}
