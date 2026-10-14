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
import XCTest
@testable import Conduit

@MainActor
extension HermesVoiceGatewayTimeoutTests {
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

        // Nothing changed: no events section, and the key is reused.
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        XCTAssertEqual(host.keyRequests, 1)
        XCTAssertNil(host.batches.last?["events"])

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

    func testPhoneChangeNeedsWhatItActsOn() {
        XCTAssertNil(PhoneChange(json: ["id": "ch_1", "kind": "delete_event", "fields": [String: Any]()]), "A deletion names its event")
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
        let tools = PhoneVoiceTools.tools(for: eventsOnly)
        XCTAssertEqual(tools.map(\.name), [PhoneVoiceTools.changesTool, PhoneVoiceTools.addTool])
        let addTool = try XCTUnwrap(tools.last)
        XCTAssertEqual(((addTool.parameters["properties"] as? [String: Any])?["kind"] as? [String: Any])?["enum"] as? [String], ["event"])
        XCTAssertTrue(PhoneVoiceTools.tools(for: PhoneSyncPreferences()).isEmpty)

        // A change Hermes asks for is answered out loud.
        host.changes = [["id": "ch_voice", "kind": "add_reminder", "auto": false, "reason": "You asked",
                         "fields": ["title": "Call the plumber"]]]
        _ = await engine.sync(deadline: .distantFuture, request: host.handle)
        let changesTool = try XCTUnwrap(PhoneVoiceTools.tools(for: phonePreferences()).first)
        let answer: (PhoneChangePrompt, Bool) async -> Void = { prompt, approve in await engine.answer(prompt, approve: approve) }
        let listed = await PhoneVoiceTools.run(changesTool, arguments: ["action": "list"], engine: engine, answer: answer)
        XCTAssertTrue(listed["result"]?.contains("Call the plumber") == true)
        XCTAssertTrue(PhoneVoiceTools.note(for: try XCTUnwrap(engine.prompts.first)).contains("ch_voice"))
        let approved = await PhoneVoiceTools.run(changesTool, arguments: ["action": "approve", "id": "ch_voice"],
                                                 engine: engine, answer: answer)
        XCTAssertNotNil(approved["result"])
        XCTAssertEqual(source.applied, ["ch_voice"])
        let missing = await PhoneVoiceTools.run(changesTool, arguments: ["action": "approve", "id": "ch_voice"],
                                                engine: engine, answer: answer)
        XCTAssertNotNil(missing["error"], "Answered already: not applied twice")

        // An event the user asks for goes in at once and counts as sent.
        let added = await PhoneVoiceTools.run(addTool, arguments: ["kind": "event", "title": "Dentist", "start": "2026-10-16T15:00",
                                                                   "calendar": "personal"],
                                              engine: engine, answer: answer)
        XCTAssertNotNil(added["result"], added["error"] ?? "")
        let voiceID = try XCTUnwrap(source.applied.last)
        XCTAssertTrue(voiceID.hasPrefix("voice_"))
        XCTAssertEqual(engine.state.eventHashes["item_\(voiceID)"], "")
        let unknown = await PhoneVoiceTools.run(addTool, arguments: ["kind": "event", "title": "Gym", "start": "2026-10-16T07:00",
                                                                     "calendar": "Work"],
                                                engine: engine, answer: answer)
        XCTAssertNotNil(unknown["error"], "No calendar called Work")
        XCTAssertNotNil(PhoneVoiceTools.localTime("2026-10-16T15:00"))
        XCTAssertEqual(PhoneVoiceTools.localTime("2026-10-16")?.isDate, true)
        XCTAssertNil(PhoneVoiceTools.localTime("Thursday"))
    }

    // MARK: Helpers

    private func makePhoneEngine(source: FakePhoneCalendarSource) -> PhoneSyncEngine {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("phone-sync-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let defaults = UserDefaults(suiteName: "phone-sync-\(UUID().uuidString)")!
        PhoneFocusSnapshot(active: true, label: "Work", holdCalls: true, at: Date(timeIntervalSince1970: 1_760_000_000))
            .save(to: defaults)
        let box = PhoneKeyBox()
        let keys = PhoneSyncKeyStore(load: { box.key }, save: { box.key = $0 }, clear: { box.key = nil })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return PhoneSyncEngine(calendarSource: source, statusSource: FakePhoneStatusSource(),
                               store: PhoneSyncStateStore(url: folder.appendingPathComponent("state.json")),
                               keys: keys, defaults: defaults, calendar: calendar,
                               now: { Date(timeIntervalSince1970: 1_760_400_000) })
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

private final class PhoneKeyBox {
    var key: PhoneSyncCrypto.SessionKey?
}

private final class FakePhoneCalendarSource: PhoneCalendarSource {
    var events: [[String: Any]] = []
    var reminderItems: [[String: Any]] = []
    private(set) var applied: [String] = []

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
        return "item_\(change.id)"
    }
    func removeAdded(itemID: String, isEvent: Bool, window: (from: Date, to: Date)) async throws {}
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
    private(set) var batches: [[String: Any]] = []
    private(set) var reported: [[String: Any]] = []
    var changes: [[String: Any]] = []
    var ignoreResults = false

    func forgetKey() {
        keys = nil
    }

    func handle(path: String, method: String, body: [String: Any]?) async throws -> [String: Any] {
        let base = PhoneSyncEngine.base
        if path.hasPrefix("\(base)/status") {
            var answer: [String: Any] = ["generation": "g1"]
            if let keys { answer["device"] = ["kid": keys.kid] }
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
            let aad = PhoneSyncCrypto.ingestAAD(kid: keys.kid, deviceID: deviceID, batchID: try XCTUnwrap(body["batch_id"] as? String))
            let plaintext = try ChaChaPoly.open(box, using: SymmetricKey(data: keys.ingest), authenticating: aad)
            batches.append(try XCTUnwrap(JSONSerialization.jsonObject(with: plaintext) as? [String: Any]))
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
