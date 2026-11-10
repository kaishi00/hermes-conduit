//
//  ShortcutInboxTests.swift
//  ConduitTests
//
//  Log to Hermes: events are sealed the way the notifier opens them, sign-in
//  codes never leave the phone, and events that couldn't go wait on the
//  phone within the same limits the host keeps. Written as an extension of
//  an existing suite: the CI test planner is at capacity for new XCTestCase
//  classes.
//

import CryptoKit
import XCTest
@testable import Conduit

@MainActor
extension HermesVoiceGatewayTimeoutTests {
    // The notifier's tests/inbox_vector.json: both sides must agree.
    func testShortcutInboxSealingMatchesTheNotifierVector() throws {
        let raw = try XCTUnwrap(NotificationE2E.base64URLDecoded("ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8"))
        let device = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        let hostPublicKey = "j0DFrbaPJWJK5bIU6nZ6bslNgp09e14a0bpvPiE4KF8"
        let hostPublic = try XCTUnwrap(NotificationE2E.base64URLDecoded(hostPublicKey))
        let kid = "75c510988e6efbb936358b0888484b4e"
        XCTAssertEqual(ShortcutInboxCrypto.keyID(devicePublic: device.publicKey.rawRepresentation, hostPublic: hostPublic), kid)

        let key = try ShortcutInboxCrypto.agree(devicePrivate: device, deviceID: "device-vector-1",
                                                hostPublicKey: hostPublicKey, kid: kid)
        let hex = key.ingest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "d888cf89cbd1b02260accf0953290c544cfb884a67467208a6748b5d9952f97b")
        XCTAssertEqual(
            String(decoding: ShortcutInboxCrypto.ingestAAD(kid: kid, deviceID: "device-vector-1", batchID: "batch-vector-1"),
                   as: UTF8.self),
            "conduit-inbox/1\ningest\nkid=75c510988e6efbb936358b0888484b4e\ndev=device-vector-1\nbatch=batch-vector-1")

        let envelope = try ShortcutInboxCrypto.envelope(
            plaintext: Data(#"{"batch_id":"batch-vector-1"}"#.utf8), key: key, deviceID: "device-vector-1",
            batchID: "batch-vector-1", nonce: try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 12)))
        XCTAssertEqual(envelope["nonce"] as? String, "AAAAAAAAAAAAAAAA")
        XCTAssertEqual(envelope["ct"] as? String, "WYzqHIN89Jlkn_pcNRgJchZ31aO3JaXbL_e5-an_ib5yvEdsOnUjoPqgYL_7")
        XCTAssertThrowsError(try ShortcutInboxCrypto.agree(devicePrivate: device, deviceID: "device-vector-1",
                                                           hostPublicKey: hostPublicKey, kid: "0" + kid.dropFirst()))

        // The Settings page's read-back, sealed by the host for this phone alone.
        XCTAssertEqual(key.answer.map { String(format: "%02x", $0) }.joined(),
                       "00da256af8fb67ae658b3c495436a9f103a02ca41933f1f305c5de3e5f875257")
        let answer: [String: Any] = [
            "nonce": "AAAAAAAAAAAAAAAA",
            "ct": "d6j8jwhtiMNt38XcZlCYKzaftuH2vl5PDqphYvyfIBQobShtnWSM9CkbN_cPwBloKxK2oUB7zEfb2vrpzd78_NwfX_Pwn7H6invv-8Jk-cbOiAU796IQqwu7eCdqYj36rrvN2aHvEji0MQaaXTbJQDs-hwleqlc3bJuWlxcAi1pwG2mo3a01fwrvb9WMVp_by1h-qKZ4Ydmn5JV_Wk6pptHKZsM",
        ]
        let opened = try ShortcutInboxCrypto.openAnswer(answer, key: key, deviceID: "device-vector-1",
                                                        requestID: "request-vector-1")
        XCTAssertEqual(String(decoding: opened, as: UTF8.self),
                       #"{"request_id":"request-vector-1","events":[{"id":"evt-1","kind":"email","at":"2026-10-14T09:15:00-04:00","title":"Your order shipped"}],"next":null}"#)
        XCTAssertThrowsError(try ShortcutInboxCrypto.openAnswer(answer, key: key, deviceID: "device-vector-1",
                                                                requestID: "request-other"),
                             "An answer opens only for the request it answers")
    }

    private func shortcutInboxTestQueue(
        profile: String = "default",
        dashboardID: UUID = UUID()
    ) -> (ShortcutInboxQueue, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShortcutInboxTests-\(UUID().uuidString)")
        let url = folder.appendingPathComponent("queue.json")
        return (ShortcutInboxQueue(url: url, scope: ShortcutInboxScope(dashboardID: dashboardID, profile: profile)), folder)
    }

    func testShortcutInboxSettingsPageReadsAPageAndForgetsALostKey() async throws {
        let (queue, folder) = shortcutInboxTestQueue()
        defer { try? FileManager.default.removeItem(at: folder) }
        let deviceID = try XCTUnwrap(queue.ensureDeviceID())
        var stored: ShortcutInboxCrypto.SessionKey? = ShortcutInboxCrypto.SessionKey(
            kid: String(repeating: "a", count: 32), ingest: Data(repeating: 1, count: 32), answer: Data(repeating: 2, count: 32))
        let keys = ShortcutInboxKeyStore(load: { stored }, save: { stored = $0 }, clear: { stored = nil })
        let browser = ShortcutInboxBrowser(queue: queue, keys: keys)

        let page = try await browser.page { path, _, body in
            XCTAssertEqual(path, "/api/plugins/conduit_push/inbox/list")
            let requestID = try XCTUnwrap(body?["request_id"] as? String)
            let plain = #"{"request_id":"\#(requestID)","events":[{"id":"e2","kind":"transaction","at":"2026-10-14T09:15:00-04:00","source":"Desjardins","amount":"45,20 $"},{"id":"e1","kind":"bogus"}],"next":[1792000000,"e1"]}"#
            let box = try ChaChaPoly.seal(Data(plain.utf8), using: SymmetricKey(data: Data(repeating: 2, count: 32)),
                                          authenticating: ShortcutInboxCrypto.listAAD(kid: String(repeating: "a", count: 32),
                                                                                       deviceID: deviceID, requestID: requestID))
            return ["nonce": NotificationE2E.base64URL(Data(box.nonce)), "ct": NotificationE2E.base64URL(box.ciphertext + box.tag)]
        }
        XCTAssertEqual(page.entries.map(\.id), ["e2", "e1"])
        XCTAssertEqual(page.entries.first?.kind, .transaction)
        XCTAssertEqual(page.entries.first?.amount, "45,20 $")
        XCTAssertEqual(page.entries.last?.kind, .other, "An unknown kind still shows")
        XCTAssertEqual(page.next, ShortcutInboxBrowser.Cursor(at: 1_792_000_000, id: "e1"))

        let lost = try await browser.page { _, _, _ in
            throw DashboardTicketBridgeError.http(status: 409, detail: "This device's inbox key isn't on this profile; set it up again")
        }
        XCTAssertTrue(lost.entries.isEmpty)
        XCTAssertNil(stored, "A key the host no longer has is forgotten; the next Log to Hermes agrees a new one")
    }

    // inbox_store.py's test_what_counts_as_a_code: keep both lists in step.
    /// The junk filter leaves out only what the model calls junk, for the
    /// kinds it sorts, while it's on, and keeps the event when the model is
    /// slow or can't answer.
    func testShortcutInboxJunkFilterLeavesOutOnlyClearJunk() async {
        let defaults = UserDefaults(suiteName: "junk-\(UUID().uuidString)")!
        let promo = ShortcutEvent(kind: .email, at: Date(), source: "Shop", title: "50% off today", text: "Sale ends soon")
        let asked = PromptBox()
        let junk: @Sendable (String) async -> Bool? = { text in await asked.add(text); return true }
        let left = await ShortcutJunkFilter.shouldLeaveOut(promo, defaults: defaults, classify: junk)
        XCTAssertTrue(left)
        XCTAssertEqual(ShortcutJunkFilter.leftOutCount(in: defaults), 1)
        let prompt = await asked.texts.first ?? ""
        XCTAssertTrue(prompt.contains("From: Shop") && prompt.contains("Title: 50% off today"))
        // A payment, a tag or a sound is never sorted.
        let payment = ShortcutEvent(kind: .transaction, at: Date(), title: "Coffee", amount: "$4")
        let kept = await ShortcutJunkFilter.shouldLeaveOut(payment, defaults: defaults, classify: junk)
        XCTAssertFalse(kept)
        // Unsure or unavailable keeps it.
        let unsure = await ShortcutJunkFilter.shouldLeaveOut(promo, defaults: defaults, classify: { _ in nil })
        XCTAssertFalse(unsure)
        let notJunk = await ShortcutJunkFilter.shouldLeaveOut(promo, defaults: defaults, classify: { _ in false })
        XCTAssertFalse(notJunk)
        // Off: nothing is sorted.
        ShortcutJunkFilter.setOn(false, in: defaults)
        let off = await ShortcutJunkFilter.shouldLeaveOut(promo, defaults: defaults, classify: junk)
        XCTAssertFalse(off)
        XCTAssertEqual(ShortcutJunkFilter.leftOutCount(in: defaults), 1)
    }

    func testShortcutInboxDropsWhatLooksLikeASignInCode() {
        let cases: [(String, Bool)] = [
            ("Your verification code is 482913", true),
            ("Votre code de vérification est 123456", true),
            ("Your Uber code: 4821", true),
            ("Tap to sign in: https://example.com/magic?t=abc", true),
            ("Order 123456 shipped", false),
            ("Can you pick up milk on the way home?", false),
            ("Security alert: a charge of $45.20 on card 4821 looks unusual", false),
        ]
        for (text, code) in cases {
            XCTAssertEqual(ShortcutEventFilter.looksLikeCode(text), code, text)
        }
        let event = ShortcutEvent(kind: .message, at: Date(), source: "Bank", title: "Your code is",
                                  text: "991204")
        XCTAssertTrue(ShortcutEventFilter.looksLikeCode(event), "Title and text are read together")
        XCTAssertTrue(ShortcutEventFilter.looksLikeCode(
            ShortcutEvent(kind: .other, at: Date(), source: "Your verification code is 482913", text: "Hello")),
                      "A code in From stays on the phone")
        XCTAssertTrue(ShortcutEventFilter.looksLikeCode(
            ShortcutEvent(kind: .transaction, at: Date(), title: "Bank", amount: "Tap to sign in: https://example.com/magic?t=abc")),
                      "A sign-in link in Amount stays on the phone")
        XCTAssertFalse(ShortcutEventFilter.looksLikeCode(
            ShortcutEvent(kind: .transaction, at: Date(), source: "Café Olimpico", amount: "4,50 $")))
    }

    func testShortcutEventSendsItsTimeWithThePhonesOffsetAndDropsBlankFields() throws {
        let event = ShortcutEvent(id: "e1", kind: .transaction, at: Date(timeIntervalSince1970: 1_760_400_000),
                                  source: "  Café Olimpico ", title: "   ", text: nil, amount: "4,50 $")
        XCTAssertTrue(event.carriesSomething)
        XCTAssertFalse(ShortcutEvent(kind: .other, at: Date(), text: " \n ").carriesSomething)
        let json = event.json(timeZone: try XCTUnwrap(TimeZone(identifier: "America/Toronto")))
        XCTAssertEqual(json["at"] as? String, "2025-10-13T20:00:00-04:00")
        XCTAssertEqual(json["kind"] as? String, "transaction")
        XCTAssertEqual(json["source"] as? String, "Café Olimpico")
        XCTAssertEqual(json["amount"] as? String, "4,50 $")
        XCTAssertNil(json["title"])
        XCTAssertNil(json["text"])

        // Cut to what the host keeps, in Unicode scalars as Python counts.
        let long = ShortcutEvent(kind: .email, at: Date(), title: String(repeating: "é", count: 300),
                                 text: String(repeating: "👍🏽", count: 3_000))
        XCTAssertEqual(long.title?.unicodeScalars.count, ShortcutEvent.maxTitle)
        XCTAssertEqual(long.text?.unicodeScalars.count, ShortcutEvent.maxText)
    }

    func testShortcutInboxSetsAnUnreadableQueueAside() throws {
        let (queue, folder) = shortcutInboxTestQueue()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: queue.url)
        XCTAssertTrue(queue.pending().isEmpty)
        XCTAssertTrue(queue.add(ShortcutEvent(id: "e1", kind: .other, at: Date(), text: "one")))
        XCTAssertEqual(queue.pending().map(\.id), ["e1"])
        let aside = folder.appendingPathComponent("queue.unreadable.json")
        XCTAssertEqual(try Data(contentsOf: aside), Data("not json".utf8), "Kept for a look, never silently lost")
    }

    func testShortcutInboxQueueKeepsTheNewestWithinTheHostsDays() throws {
        let (queue, folder) = shortcutInboxTestQueue()
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()

        XCTAssertNil(queue.knownDeviceID, "No device id before the first event")
        let deviceID = try XCTUnwrap(queue.ensureDeviceID())
        XCTAssertTrue(deviceID.hasPrefix("inbox-"))
        XCTAssertEqual(queue.ensureDeviceID(), deviceID, "The device id stays the same across runs")

        let stale = ShortcutEvent(id: "stale", kind: .other, at: now.addingTimeInterval(-31 * 86_400), text: "old")
        XCTAssertTrue(queue.add(stale, now: now))
        XCTAssertTrue(queue.pending(now: .distantPast).isEmpty, "Older than the host keeps: never kept")

        for index in 0..<(ShortcutInboxQueue.capacity + 5) {
            queue.add(ShortcutEvent(id: "e\(index)", kind: .other, at: now, text: "\(index)"), now: now)
        }
        let pending = queue.pending(now: now)
        XCTAssertEqual(pending.count, ShortcutInboxQueue.capacity)
        XCTAssertEqual(pending.first?.id, "e5", "The oldest go first when the queue is full")

        queue.remove(Array(pending.prefix(10)))
        XCTAssertEqual(queue.pending(now: now).count, ShortcutInboxQueue.capacity - 10)
        queue.clear()
        XCTAssertTrue(queue.pending(now: now).isEmpty)
        XCTAssertEqual(queue.knownDeviceID, deviceID, "Clearing what waits keeps the device id")
    }

    // Each dashboard and profile has its own waiting events and device id,
    // and they live in a file left out of backups, not in UserDefaults.
    func testShortcutInboxQueueKeepsEachProfileApartOutOfBackups() throws {
        let (home, folder) = shortcutInboxTestQueue(profile: "default")
        defer { try? FileManager.default.removeItem(at: folder) }
        let work = ShortcutInboxQueue(url: home.url, scope: ShortcutInboxScope(dashboardID: home.scope.dashboardID, profile: "work"))
        let otherDashboard = ShortcutInboxQueue(url: home.url, scope: ShortcutInboxScope(dashboardID: UUID(), profile: "default"))
        XCTAssertNotEqual(home.scope.storageID, work.scope.storageID)

        home.add(ShortcutEvent(id: "h1", kind: .message, at: Date(), text: "home"))
        work.add(ShortcutEvent(id: "w1", kind: .email, at: Date(), text: "work"))
        XCTAssertEqual(home.pending().map(\.id), ["h1"])
        XCTAssertEqual(work.pending().map(\.id), ["w1"])
        XCTAssertTrue(otherDashboard.pending().isEmpty)
        XCTAssertNotEqual(home.ensureDeviceID(), work.ensureDeviceID())

        work.clear()
        XCTAssertEqual(home.pending().map(\.id), ["h1"], "Clearing one inbox leaves the others")

        otherDashboard.add(ShortcutEvent(id: "o1", kind: .other, at: Date(), text: "other"))
        var forgotten: [ShortcutInboxScope] = []
        ShortcutInboxQueue.forgetDashboard(home.scope.dashboardID, url: home.url) { forgotten.append($0) }
        XCTAssertTrue(home.pending().isEmpty, "A removed dashboard's waiting events go")
        XCTAssertNil(home.knownDeviceID)
        XCTAssertEqual(Set(forgotten), [home.scope, work.scope], "Its profiles' keys go too")
        XCTAssertEqual(otherDashboard.pending().map(\.id), ["o1"], "Another dashboard's stay")

        let values = try home.url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        XCTAssertNil(UserDefaults.standard.object(forKey: "conduit.shortcutInbox.pending"))
    }

    // Two automation runs at once: the second waits for the first, so each
    // event goes once and only one key is agreed.
    func testShortcutInboxOverlappingRunsSendEachEventOnceWithOneKey() async throws {
        let (queue, folder) = shortcutInboxTestQueue()
        defer { try? FileManager.default.removeItem(at: folder) }
        var stored: ShortcutInboxCrypto.SessionKey?
        let keys = ShortcutInboxKeyStore(load: { stored }, save: { stored = $0 }, clear: { stored = nil })
        let host = Curve25519.KeyAgreement.PrivateKey()
        var hostKid: String?
        var keyPosts = 0
        var ingested: [String] = []

        let request: ShortcutInboxSender.Request = { path, _, body in
            // Every request yields, so unserialized runs would interleave.
            try await Task.sleep(for: .milliseconds(20))
            if path.contains("/status") {
                return ["device": ["kid": hostKid as Any]]
            }
            if path.hasSuffix("/key") {
                keyPosts += 1
                let devicePublic = try XCTUnwrap(NotificationE2E.base64URLDecoded(try XCTUnwrap(body?["public_key"] as? String)))
                let kid = ShortcutInboxCrypto.keyID(devicePublic: devicePublic, hostPublic: host.publicKey.rawRepresentation)
                hostKid = kid
                return ["host_public_key": NotificationE2E.base64URL(host.publicKey.rawRepresentation), "kid": kid]
            }
            let body = try XCTUnwrap(body)
            let key = try XCTUnwrap(stored)
            let sealed = try XCTUnwrap(NotificationE2E.base64URLDecoded(try XCTUnwrap(body["ct"] as? String)))
            let box = try ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: try XCTUnwrap(NotificationE2E.base64URLDecoded(try XCTUnwrap(body["nonce"] as? String)))),
                ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
            let plain = try ChaChaPoly.open(box, using: SymmetricKey(data: key.ingest), authenticating: ShortcutInboxCrypto.ingestAAD(
                kid: key.kid, deviceID: try XCTUnwrap(body["device_id"] as? String), batchID: try XCTUnwrap(body["batch_id"] as? String)))
            let batch = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any])
            ingested += (batch["events"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            return ["ok": true]
        }
        let gate = ShortcutInboxGate()
        let sender = ShortcutInboxSender(queue: queue, keys: keys)
        let runs = ["e1", "e2"].map { id in
            Task { @MainActor in
                queue.add(ShortcutEvent(id: id, kind: .other, at: Date(), text: id))
                return try await gate.run { try await sender.send(request: request) }
            }
        }
        var sent = 0
        for run in runs { sent += try await run.value }
        XCTAssertEqual(sent, 2)
        XCTAssertEqual(ingested.sorted(), ["e1", "e2"], "Each event reaches the host once")
        XCTAssertEqual(keyPosts, 1, "One key agreement, not one per run")
        XCTAssertTrue(queue.pending().isEmpty)
    }

    func testShortcutInboxDeletesClearWaitingCopiesAndReportAMissingHost() async throws {
        let (queue, folder) = shortcutInboxTestQueue()
        defer { try? FileManager.default.removeItem(at: folder) }
        var stored: ShortcutInboxCrypto.SessionKey? = ShortcutInboxCrypto.SessionKey(
            kid: String(repeating: "a", count: 32), ingest: Data(repeating: 1, count: 32), answer: Data(repeating: 2, count: 32))
        let keys = ShortcutInboxKeyStore(load: { stored }, save: { stored = $0 }, clear: { stored = nil })
        let browser = ShortcutInboxBrowser(queue: queue, keys: keys)
        _ = queue.ensureDeviceID()
        queue.add(ShortcutEvent(id: "e1", kind: .other, at: Date(), text: "one"))
        queue.add(ShortcutEvent(id: "e2", kind: .other, at: Date(), text: "two"))

        let deleted = try await browser.delete(["e1"]) { path, _, body in
            XCTAssertEqual(path, "/api/plugins/conduit_push/inbox/delete")
            XCTAssertEqual(body?["ids"] as? [String], ["e1"])
            return ["deleted": 1]
        }
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(queue.pending().map(\.id), ["e2"], "A deleted event's waiting copy never goes later")

        do {
            try await browser.deleteAll(request: nil)
            XCTFail("A delete that can't reach Hermes says so")
        } catch {
            XCTAssertEqual(error as? ShortcutInboxUnavailable, .notConnected)
        }
        XCTAssertTrue(queue.pending().isEmpty, "What waits on the phone goes even offline")
        XCTAssertNotNil(stored, "The key stays until the host's copy is deleted")
    }

    // A drain on connect holds the gate only until its deadline, even when
    // the transport hangs: a Log to Hermes run never waits behind it longer.
    func testShortcutInboxBoundedPassNeverHoldsTheGatePastItsDeadline() async throws {
        let gate = ShortcutInboxGate()
        var entered = false
        let hanging: ShortcutInboxSender.Request = { _, _, _ in
            entered = true
            try await Task.sleep(for: .seconds(30))
            return [:]
        }
        let started = Date()
        let drain = ShortcutInboxDeadline.bounded(hanging, until: started.addingTimeInterval(0.3))
        let draining = Task { @MainActor in try await gate.run { try await drain("/inbox/status", "GET", nil) } }
        while !entered { await Task.yield() }
        let waited = await gate.run { Date().timeIntervalSince(started) }
        XCTAssertGreaterThanOrEqual(waited, 0.25, "The run waited for the drain")
        XCTAssertLessThan(waited, 2, "but only until the drain's deadline")
        do {
            _ = try await draining.value
            XCTFail("A pass past its deadline gives up")
        } catch {
            XCTAssertEqual(error as? ShortcutInboxUnavailable, .outOfTime)
        }
        do {
            _ = try await drain("/inbox/ingest", "POST", nil)
            XCTFail("No request starts after the deadline")
        } catch {
            XCTAssertEqual(error as? ShortcutInboxUnavailable, .outOfTime)
        }
    }

    // Settings decides whether to show the page from memory, never the disk.
    func testShortcutInboxLocalStateAnswersFromMemory() {
        let state = ShortcutInboxLocalState()
        let scope = ShortcutInboxScope(dashboardID: UUID(), profile: "default")
        XCTAssertNil(state.hasLocalData(scope), "Unknown until read once, off the drawing path")
        state.noteKey(false, for: scope.storageID)
        state.noteQueue([:], now: Date())
        XCTAssertNil(state.hasLocalData(scope), "An inbox the file never had is unknown until loaded")
        state.noteQueue([scope.storageID: .init(scope: scope, events: [ShortcutEvent(kind: .other, at: Date(), text: "x")])],
                        now: Date())
        XCTAssertEqual(state.hasLocalData(scope), true)
        state.noteQueue([:], now: Date())
        XCTAssertEqual(state.hasLocalData(scope), false, "A written queue without it: nothing waits")
        state.noteKey(true, for: scope.storageID)
        XCTAssertEqual(state.hasLocalData(scope), true)
    }
}

private actor PromptBox {
    private(set) var texts: [String] = []
    func add(_ text: String) { texts.append(text) }
}
