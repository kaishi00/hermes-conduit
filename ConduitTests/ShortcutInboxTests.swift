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

    func testShortcutInboxSettingsPageReadsAPageAndForgetsALostKey() async throws {
        let suite = "ShortcutInboxBrowserTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let queue = ShortcutInboxQueue(defaults: defaults)
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
                                                                                       deviceID: queue.deviceID, requestID: requestID))
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
    }

    func testShortcutInboxQueueKeepsTheNewestWithinTheHostsDays() throws {
        let suite = "ShortcutInboxQueueTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let queue = ShortcutInboxQueue(defaults: defaults)
        let now = Date()

        XCTAssertTrue(queue.deviceID.hasPrefix("inbox-"))
        XCTAssertEqual(queue.deviceID, queue.deviceID, "The device id stays the same across runs")

        let stale = ShortcutEvent(id: "stale", kind: .other, at: now.addingTimeInterval(-15 * 86_400), text: "old")
        queue.add(stale, now: now)
        XCTAssertTrue(queue.pending(now: now).isEmpty, "Older than the host keeps: never sent")

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
    }
}
