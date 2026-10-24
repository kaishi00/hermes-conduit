//
//  NotificationE2ETests.swift
//
//  End-to-end encrypted notifications (#431). The vectors below were sealed
//  by hermes-conduit-notifier's e2e.py (fixed nonces), so these tests pin
//  the key derivation, associated data, compression and answer format to
//  what the plugin actually sends and accepts.
//

import CryptoKit
import XCTest
@testable import Conduit

@MainActor
final class NotificationE2ETests: XCTestCase {
    private static let kid = "0123456789abcdef0123456789abcdef"
    private static let secret = Data(0..<32)
    private static let installationID = "11111111-2222-3333-4444-555555555555"
    private static let gatewayID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private static let dashboardID = "0F5C8A34-1B2D-4E5F-8A9B-0C1D2E3F4A5B"
    private static let issuedAt: TimeInterval = 1_760_000_000

    /// e2e.seal_event for an input.needed clarify ("Deploy to prod?",
    /// Yes/No, session sess-1, profile coder) at iat 1760000000.
    private static let envelope: [String: Any] = [
        "v": 1,
        "kid": kid,
        "msg": "input:9ab3405eb5333adb44e353fcd81508e8",
        "iat": 1_760_000_000,
        "tok": "5d671a3554c84fb7",
        "z": 1,
        "req": "conduit-push-abc123def456",
        "n": "BwcHBwcHBwcHBwcH",
        "ct": "YEtXcEZp_hUYxXaIBmF-kC5gT4i7IomTbFRQmwF8LiFNeAzHOrZSd-VdKXI8WBkdjNd9GCKsCqePYurZuUJCINjnT2wiVZAGyBa2rq2UZfKo9399Ql8p-f4Rywl3wgNKh33TNk8pGP0EvdOuI6zi3Haw-c1-bCrheVS1BkufqRdPe2WPDPElQCiw0RU6PRCeEwLbFd7G30C0RKQDmExz-ZyYrQ",
    ]

    /// e2e.seal_answer("Yes", request conduit-push-abc123def456, question q0).
    private static let pythonAnswer = "e2e1.0123456789abcdef0123456789abcdef.CQkJCQkJCQkJCQkJ.ql5wF3j3B9LkSwjxp3TxEr5fYg"

    private var record: E2EKeyRecord {
        E2EKeyRecord(
            kid: Self.kid,
            secret: Self.secret,
            installationID: Self.installationID,
            gatewayID: Self.gatewayID,
            dashboardID: Self.dashboardID,
            profile: "coder",
            createdAt: Date(timeIntervalSince1970: Self.issuedAt)
        )
    }

    private var now: Date { Date(timeIntervalSince1970: Self.issuedAt + 60) }

    /// What the relay delivers: generic alert, routing stub, envelope.
    private func delivered(envelope: [String: Any] = NotificationE2ETests.envelope, type: String = "input.needed", gatewayID: String = "relay-says-anything") -> [AnyHashable: Any] {
        let routing: [String: Any] = ["type": type, "e2e": 1, "gateway_id": gatewayID, "dashboard_id": "99999999-9999-4999-8999-999999999999"]
        return [
            "aps": ["alert": ["title": "Input needed", "body": "Hermes needs your response before it can continue."], "mutable-content": 1],
            "conduit": routing,
            "body": ["conduit": routing],
            "conduit_e2e": envelope,
        ]
    }

    // MARK: Derivation and wire format

    func testKeyDerivationMatchesThePlugin() {
        let keys = NotificationE2E.keys(secret: Self.secret)
        let push = keys.push.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        let answer = keys.answer.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(push, "a5a8884943a780bbf4f846cf294f149d8c668f58312ca26841ec7f78e5a1a099")
        XCTAssertEqual(answer, "08c9b2cf01c5f94ed56658fc2a8b90d25b0361ab943f9efa4a857f3c44409b27")
    }

    func testPluginSealedPushOpensAndRoutesFromVerifiedDataOnly() throws {
        guard case .verified(let verified) = NotificationE2E.evaluate(delivered(), records: [record], knownGatewayIDs: [], keysProvisioned: false, now: now) else {
            return XCTFail("the plugin's envelope should verify")
        }
        XCTAssertEqual(verified.content["title"] as? String, "Hermes")
        XCTAssertEqual(verified.content["body"] as? String, "Deploy to prod?")

        let target = try XCTUnwrap(PushNotificationService.parseNotificationTarget(from: delivered(), records: [record], knownGatewayIDs: [], keysProvisioned: false, now: now))
        XCTAssertEqual(target.sessionId, "sess-1")
        XCTAssertEqual(target.profile, "coder")
        XCTAssertEqual(target.type, "input.needed")
        // The pairing the key belongs to, never the relay's routing stub.
        XCTAssertEqual(target.relayGatewayID, Self.gatewayID)
        XCTAssertEqual(target.dashboardID, UUID(uuidString: Self.dashboardID))
        XCTAssertEqual(target.decision, .clarify(requestId: "conduit-push-abc123def456", question: "Deploy to prod?", choices: ["Yes", "No"]))
    }

    func testPluginSealedAnswerOpensWithTheAppsAnswerKeyAndAAD() throws {
        let parts = Self.pythonAnswer.dropFirst(NotificationE2E.answerPrefix.count).split(separator: ".").map(String.init)
        let nonce = try XCTUnwrap(NotificationE2E.base64URLDecoded(parts[1]))
        let sealed = try XCTUnwrap(NotificationE2E.base64URLDecoded(parts[2]))
        let aad = NotificationE2E.answerAAD(kid: Self.kid, installationID: Self.installationID, gatewayID: Self.gatewayID, requestID: "conduit-push-abc123def456", questionID: "q0")
        let opened = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: nonce + sealed), using: NotificationE2E.keys(secret: Self.secret).answer, authenticating: aad)
        XCTAssertEqual(String(decoding: opened, as: UTF8.self), "Yes")
    }

    func testAppSealedAnswerIsBoundToItsRequestAndQuestion() throws {
        let sealed = try NotificationE2E.sealAnswer("Blue", record: record, requestID: "conduit-push-abc123def456", questionID: "q1")
        let parts = sealed.dropFirst(NotificationE2E.answerPrefix.count).split(separator: ".").map(String.init)
        XCTAssertTrue(sealed.hasPrefix("e2e1.\(Self.kid)."))
        XCTAssertEqual(parts.count, 3)
        let box = try ChaChaPoly.SealedBox(combined: XCTUnwrap(NotificationE2E.base64URLDecoded(parts[1])) + XCTUnwrap(NotificationE2E.base64URLDecoded(parts[2])))
        let keys = NotificationE2E.keys(secret: Self.secret)
        let right = NotificationE2E.answerAAD(kid: Self.kid, installationID: Self.installationID, gatewayID: Self.gatewayID, requestID: "conduit-push-abc123def456", questionID: "q1")
        XCTAssertEqual(String(decoding: try ChaChaPoly.open(box, using: keys.answer, authenticating: right), as: UTF8.self), "Blue")
        let otherQuestion = NotificationE2E.answerAAD(kid: Self.kid, installationID: Self.installationID, gatewayID: Self.gatewayID, requestID: "conduit-push-abc123def456", questionID: "q0")
        XCTAssertThrowsError(try ChaChaPoly.open(box, using: keys.answer, authenticating: otherQuestion))
    }

    // MARK: Trust

    func testTamperedOrStaleOrForeignEnvelopesAreUntrusted() {
        var retyped = delivered(type: "approval.needed")
        XCTAssertUntrusted(NotificationE2E.evaluate(retyped, records: [record], knownGatewayIDs: [], keysProvisioned: false, now: now))

        var rethreaded = Self.envelope
        rethreaded["tok"] = "0000000000000000"
        XCTAssertUntrusted(NotificationE2E.evaluate(delivered(envelope: rethreaded), records: [record], knownGatewayIDs: [], keysProvisioned: false, now: now))

        var moved = Self.envelope
        moved["req"] = "conduit-push-000000000000"
        XCTAssertUntrusted(NotificationE2E.evaluate(delivered(envelope: moved), records: [record], knownGatewayIDs: [], keysProvisioned: false, now: now))

        let stale = Date(timeIntervalSince1970: Self.issuedAt + NotificationE2E.maxAge + 1)
        XCTAssertUntrusted(NotificationE2E.evaluate(delivered(), records: [record], knownGatewayIDs: [], keysProvisioned: false, now: stale))
        let early = Date(timeIntervalSince1970: Self.issuedAt - NotificationE2E.maxClockSkew - 1)
        XCTAssertUntrusted(NotificationE2E.evaluate(delivered(), records: [record], knownGatewayIDs: [], keysProvisioned: false, now: early))

        // Another pairing's key, or none at all.
        let other = E2EKeyRecord(kid: Self.kid, secret: Data(repeating: 1, count: 32), installationID: Self.installationID, gatewayID: Self.gatewayID, dashboardID: nil, profile: nil, createdAt: now)
        XCTAssertUntrusted(NotificationE2E.evaluate(delivered(), records: [other], knownGatewayIDs: [], keysProvisioned: false, now: now))
        XCTAssertUntrusted(NotificationE2E.evaluate(delivered(), records: [], knownGatewayIDs: [], keysProvisioned: false, now: now))

        retyped["conduit_e2e"] = "garbage"
        XCTAssertUntrusted(NotificationE2E.evaluate(retyped, records: [record], knownGatewayIDs: [], keysProvisioned: false, now: now))
        XCTAssertNil(PushNotificationService.parseNotificationTarget(from: delivered(type: "approval.needed"), records: [record], knownGatewayIDs: [], keysProvisioned: false, now: now))
    }

    func testPlaintextIsADowngradeOnlyForPairingsWithAKey() {
        let plaintext: [AnyHashable: Any] = ["conduit": ["type": "response.ready", "session_id": "sess-1", "gateway_id": Self.gatewayID]]
        XCTAssertUntrusted(NotificationE2E.evaluate(plaintext, records: [record], knownGatewayIDs: [], keysProvisioned: false, now: now))
        XCTAssertNil(PushNotificationService.parseNotificationTarget(from: plaintext, records: [record], knownGatewayIDs: [], keysProvisioned: false, now: now))

        // A known pairing that never provisioned a key keeps today's behavior.
        let legacy: [AnyHashable: Any] = ["conduit": ["type": "response.ready", "session_id": "sess-2", "gateway_id": "another-gateway"]]
        let known: Set<String> = [Self.gatewayID, "another-gateway"]
        XCTAssertEqual(PushNotificationService.parseNotificationTarget(from: legacy, records: [record], knownGatewayIDs: known, keysProvisioned: false, now: now)?.sessionId, "sess-2")
        // Even listed, a keyed pairing's plaintext stays a downgrade.
        XCTAssertNil(PushNotificationService.parseNotificationTarget(from: plaintext, records: [record], knownGatewayIDs: known, keysProvisioned: false, now: now))
        // A pairing this iPhone has never seen can't vouch for plaintext.
        let invented: [AnyHashable: Any] = ["conduit": ["type": "response.ready", "session_id": "sess-4", "gateway_id": "made-up-gateway"]]
        XCTAssertUntrusted(NotificationE2E.evaluate(invented, records: [record], knownGatewayIDs: known, keysProvisioned: false, now: now))
        XCTAssertNil(PushNotificationService.parseNotificationTarget(from: invented, records: [record], knownGatewayIDs: known, keysProvisioned: false, now: now))
        // With no key at all, every plaintext push behaves as before.
        XCTAssertEqual(PushNotificationService.parseNotificationTarget(from: invented, records: [], knownGatewayIDs: [], keysProvisioned: false, now: now)?.sessionId, "sess-4")

        // No gateway named: unattributable once this iPhone holds any key.
        let unscoped: [AnyHashable: Any] = ["conduit": ["type": "response.ready", "session_id": "sess-3"]]
        XCTAssertNil(PushNotificationService.parseNotificationTarget(from: unscoped, records: [record], knownGatewayIDs: [], keysProvisioned: false, now: now))
        XCTAssertEqual(PushNotificationService.parseNotificationTarget(from: unscoped, records: [], knownGatewayIDs: [], keysProvisioned: false, now: now)?.sessionId, "sess-3")
    }

    func testAnUnreadableKeychainIsNotTreatedAsNoKeys() {
        let plaintext: [AnyHashable: Any] = ["conduit": ["type": "response.ready", "session_id": "sess-5", "gateway_id": "another-gateway"]]
        // Keys were stored but couldn't be read (say, before first unlock):
        // plaintext is a downgrade, not legacy.
        XCTAssertUntrusted(NotificationE2E.evaluate(plaintext, records: [], knownGatewayIDs: [], keysProvisioned: true, now: now))
        XCTAssertNil(PushNotificationService.parseNotificationTarget(from: plaintext, records: [], knownGatewayIDs: [], keysProvisioned: true, now: now))
        // Even naming a listed pairing (which may be the keyed one).
        let keyed: [AnyHashable: Any] = ["conduit": ["type": "response.ready", "session_id": "sess-6", "gateway_id": Self.gatewayID]]
        let listed: Set<String> = [Self.gatewayID, "another-gateway"]
        XCTAssertUntrusted(NotificationE2E.evaluate(keyed, records: [], knownGatewayIDs: listed, keysProvisioned: true, now: now))
        XCTAssertUntrusted(NotificationE2E.evaluate(plaintext, records: [], knownGatewayIDs: listed, keysProvisioned: true, now: now))
    }

    func testKeylessPairingsListedAfterTheFirstKeyNeverBecomeTrusted() {
        XCTAssertEqual(NotificationE2E.knownGatewayIDs(listed: ["a", "b"], previous: [], holdsKeys: false), ["a", "b"])
        // Once a key is held the set only shrinks: a pairing the relay lists
        // later (real or made up) never joins.
        XCTAssertEqual(NotificationE2E.knownGatewayIDs(listed: ["a", "b", "phantom"], previous: ["a", "b"], holdsKeys: true), ["a", "b"])
        XCTAssertEqual(NotificationE2E.knownGatewayIDs(listed: ["b"], previous: ["a", "b"], holdsKeys: true), ["b"])
    }

    func testSeenStoreRecordsEachMessageOncePerUse() {
        let store = E2ESeenStore(url: nil)
        XCTAssertTrue(store.insert("k:m", namespace: "delivered", now: now))
        XCTAssertFalse(store.insert("k:m", namespace: "delivered", now: now))
        XCTAssertTrue(store.insert("k:m", namespace: "routed", now: now))
        // Pruned once past retention, when the envelope is too old anyway.
        XCTAssertTrue(store.insert("k:m", namespace: "delivered", now: now.addingTimeInterval(E2ESeenStore.retention + 1)))
    }

    func testSeenStoreSharesItsRecordsThroughTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-seen-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        XCTAssertTrue(E2ESeenStore(url: url).insert("k:m", namespace: "delivered", now: now))
        // Another process (a second instance here) sees the first one's record.
        XCTAssertFalse(E2ESeenStore(url: url).insert("k:m", namespace: "delivered", now: now))
    }

    // MARK: Provisioning and answers

    func testOnlyThisIPhonesPairingsWithoutAKnownKeyGetOne() {
        let paired: [String: Any] = ["ok": true, "paired": true, "installation_id": Self.installationID, "gateway_id": Self.gatewayID, "e2e": NSNull(), "crypto": true]
        XCTAssertEqual(PushNotificationService.gatewayNeedingEncryptionKey(status: paired, installationID: Self.installationID, records: []), Self.gatewayID)

        var held = paired
        held["e2e"] = ["kid": Self.kid]
        XCTAssertNil(PushNotificationService.gatewayNeedingEncryptionKey(status: held, installationID: Self.installationID, records: [record]))
        // The plugin holds a key this iPhone lost: replace it.
        XCTAssertEqual(PushNotificationService.gatewayNeedingEncryptionKey(status: held, installationID: Self.installationID, records: []), Self.gatewayID)

        var otherPhone = paired
        otherPhone["installation_id"] = "other"
        XCTAssertNil(PushNotificationService.gatewayNeedingEncryptionKey(status: otherPhone, installationID: Self.installationID, records: []))
        var noCrypto = paired
        noCrypto["crypto"] = false
        XCTAssertNil(PushNotificationService.gatewayNeedingEncryptionKey(status: noCrypto, installationID: Self.installationID, records: []))
        XCTAssertNil(PushNotificationService.gatewayNeedingEncryptionKey(status: ["ok": true, "paired": false], installationID: Self.installationID, records: []))
        var noGateway = paired
        noGateway["gateway_id"] = NSNull()
        XCTAssertNil(PushNotificationService.gatewayNeedingEncryptionKey(status: noGateway, installationID: Self.installationID, records: []))
    }

    func testAnswersAreSealedOnlyForGatewaysWithAKey() throws {
        let body = PushNotificationService.respondBody(requestID: "conduit-push-abc123def456", answer: "Yes", questionID: "q0", relayGatewayID: Self.gatewayID)
        let sealed = try PushNotificationService.sealedRespondBody(body, requestID: "conduit-push-abc123def456", installationID: Self.installationID, records: [record])
        XCTAssertTrue(sealed["answer"]?.hasPrefix("e2e1.") == true)
        XCTAssertEqual(sealed["question_id"], "q0")
        XCTAssertEqual(sealed["gateway_id"], Self.gatewayID)

        let legacy = PushNotificationService.respondBody(requestID: "conduit-push-abc123def456", answer: "Yes", relayGatewayID: "another-gateway")
        XCTAssertEqual(try PushNotificationService.sealedRespondBody(legacy, requestID: "conduit-push-abc123def456", installationID: Self.installationID, records: [record]), legacy)
    }

    func testNewRecordsHaveFreshRandomKeys() {
        let first = NotificationE2E.newRecord(installationID: "i", gatewayID: "g", dashboardID: nil, profile: nil)
        let second = NotificationE2E.newRecord(installationID: "i", gatewayID: "g", dashboardID: nil, profile: nil)
        XCTAssertEqual(first.secret.count, 32)
        XCTAssertNotNil(first.kid.range(of: "^[0-9a-f]{32}$", options: .regularExpression))
        XCTAssertNotEqual(first.kid, second.kid)
        XCTAssertNotEqual(first.secret, second.secret)
    }

    private func XCTAssertUntrusted(_ evaluation: NotificationE2E.Evaluation, file: StaticString = #filePath, line: UInt = #line) {
        guard case .untrusted = evaluation else {
            return XCTFail("expected untrusted, got \(evaluation)", file: file, line: line)
        }
    }
}

// MARK: - Relay errors

extension NotificationE2ETests {
    func testRelayErrorsSayWhatTheRelayRefused() {
        func message(_ json: String) -> String { PushNotificationService.relayErrorMessage(data: Data(json.utf8)) }
        let generic = AppLocalization.string("Push relay request failed.")
        // The relay answers {"error": "<code>"} (relay/src/server.mjs).
        for code in ["unauthorized", "invalid_topic", "production_only", "invalid_device_token", "token_proof_required",
                     "token_proof_invalid", "installation_limit_reached", "gateway_limit_reached", "rate_limited",
                     "answer_too_large"] {
            let text = message(#"{"error":"\#(code)"}"#)
            XCTAssertNotEqual(text, generic, code)
            XCTAssertFalse(text.contains(code), "A known code reads as a sentence: \(code)")
        }
        // An unknown code still says which it was.
        XCTAssertTrue(message(#"{"error":"something_new"}"#).contains("something_new"))
        // A relay that says it in words (none does today) is shown as is.
        XCTAssertEqual(message(#"{"message":"Relay is down for maintenance"}"#), "Relay is down for maintenance")
        XCTAssertEqual(message("not json"), generic)
        XCTAssertEqual(message("{}"), generic)
    }

    func testAClarifyAnswerTooLongForTheRelayIsRefusedWithAReason() {
        // The relay takes plaintext answers of 2,000 UTF-16 units after
        // trimming, and answers 413 answer_too_large beyond (or for a sealed
        // answer over its cap).
        XCTAssertNil(PushNotificationService.decisionAnswerError(String(repeating: "a", count: 2_000)))
        XCTAssertNil(PushNotificationService.decisionAnswerError("  " + String(repeating: "a", count: 2_000) + "\n"))
        let tooLong = PushNotificationService.decisionAnswerError(String(repeating: "😀", count: 1_001))
        XCTAssertNotNil(tooLong, "Counted as the relay counts: 2,002 UTF-16 units")
        let refused = PushNotificationService.decisionError(status: 413, data: Data(#"{"error":"answer_too_large"}"#.utf8))
        XCTAssertEqual(refused.errorDescription, tooLong?.errorDescription)
        XCTAssertNotEqual(refused.errorDescription, PushNotificationService.RelayDecisionError.server(413).errorDescription)
        // Other refusals keep the generic text.
        XCTAssertEqual(PushNotificationService.decisionError(status: 400, data: Data(#"{"error":"invalid_answer"}"#.utf8)).errorDescription,
                       PushNotificationService.RelayDecisionError.server(400).errorDescription)
    }

    // MARK: Key rotation and the padlock

    func testHostKeepsReplacedKeysReadsTheRotateFieldFromJSON() throws {
        func status(_ json: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }
        XCTAssertTrue(PushNotificationService.hostKeepsReplacedKeys(status: try status(#"{"ok":true,"rotate":false}"#)))
        XCTAssertTrue(PushNotificationService.hostKeepsReplacedKeys(status: try status(#"{"ok":true,"rotate":true}"#)))
        // Before notifier 0.71 the field is missing.
        XCTAssertFalse(PushNotificationService.hostKeepsReplacedKeys(status: try status(#"{"ok":true}"#)))
        XCTAssertFalse(PushNotificationService.hostKeepsReplacedKeys(status: try status(#"{"ok":true,"rotate":null}"#)))
    }

    private func rotated(kid: String, createdAt: Date, retiredAt: Date? = nil) -> E2EKeyRecord {
        E2EKeyRecord(
            kid: kid, secret: Data(repeating: 7, count: 32), installationID: Self.installationID, gatewayID: Self.gatewayID,
            dashboardID: Self.dashboardID, profile: "coder", createdAt: createdAt, retiredAt: retiredAt
        )
    }

    func testAnswersAreSealedWithTheNewestKeyNotReplacedByARotation() throws {
        let newer = rotated(kid: String(repeating: "b", count: 32), createdAt: now)
        let pending = rotated(kid: String(repeating: "c", count: 32), createdAt: now.addingTimeInterval(60), retiredAt: now)
        let old = record.retired(at: now)
        XCTAssertEqual(NotificationE2E.currentRecord(gatewayID: Self.gatewayID, installationID: Self.installationID, records: [old, newer, pending]), newer)
        XCTAssertNil(NotificationE2E.currentRecord(gatewayID: Self.gatewayID, installationID: Self.installationID, records: [old]))

        let body = PushNotificationService.respondBody(requestID: "conduit-push-abc123def456", answer: "Yes", relayGatewayID: Self.gatewayID)
        let sealed = try PushNotificationService.sealedRespondBody(body, requestID: "conduit-push-abc123def456", installationID: Self.installationID, records: [old, newer])
        XCTAssertTrue(sealed["answer"]?.hasPrefix("e2e1.\(newer.kid).") == true)
    }

    func testAReplacedKeyStillOpensPushesUntilItExpires() throws {
        let old = record.retired(at: now)
        guard case .verified = NotificationE2E.evaluate(delivered(), records: [old], knownGatewayIDs: [], keysProvisioned: true, now: now) else {
            return XCTFail("A replaced key still opens pushes sealed before the rotation")
        }
        XCTAssertEqual(NotificationE2E.expiredRecords([old], now: now.addingTimeInterval(NotificationE2E.previousKeyGrace - 1)), [])
        XCTAssertEqual(NotificationE2E.expiredRecords([old, rotated(kid: String(repeating: "b", count: 32), createdAt: now)],
                                                     now: now.addingTimeInterval(NotificationE2E.previousKeyGrace)), [old])
    }

    func testAPairingThatNeverRotatesKeepsWorking() throws {
        // An older app or notifier never rotates: its one key keeps opening
        // pushes, sealing answers and closing the padlock, at any age.
        guard case .verified = NotificationE2E.evaluate(delivered(), records: [record], knownGatewayIDs: [], keysProvisioned: true, now: now) else {
            return XCTFail("A key that was never rotated still opens pushes")
        }
        let years = now.addingTimeInterval(3 * 365 * 24 * 3600)
        XCTAssertEqual(NotificationE2E.expiredRecords([record], now: years), [], "Only a replaced key expires")
        XCTAssertEqual(NotificationE2E.currentRecord(gatewayID: Self.gatewayID, installationID: Self.installationID, records: [record]), record)
        let body = PushNotificationService.respondBody(requestID: "conduit-push-abc123def456", answer: "Yes", relayGatewayID: Self.gatewayID)
        let sealed = try PushNotificationService.sealedRespondBody(body, requestID: "conduit-push-abc123def456", installationID: Self.installationID, records: [record])
        XCTAssertTrue(sealed["answer"]?.hasPrefix("e2e1.\(Self.kid).") == true)
        let keeps = PushNotificationService.EncryptionConfirmation(kid: Self.kid, rotates: false)
        XCTAssertEqual(PushNotificationService.encryptionAssurance(gatewayID: Self.gatewayID, installationID: Self.installationID,
                                                                   records: [record], confirmation: keeps, now: years),
                       .ensured(keyCreatedAt: record.createdAt, rotates: false, quantumSafe: false))
    }

    func testRetiredAtIsOptionalInStoredRecords() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any] ?? [:]
        json.removeValue(forKey: "retiredAt")
        let decoded = try JSONDecoder().decode(E2EKeyRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.retiredAt)
        XCTAssertEqual(decoded, record)
    }

    func testTheHostConfirmsOnlyAKeyThisIPhoneHolds() {
        let status: [String: Any] = ["ok": true, "paired": true, "installation_id": Self.installationID, "gateway_id": Self.gatewayID,
                                     "e2e": ["kid": Self.kid, "created_at": "2026-10-24T00:00:00Z"], "crypto": true, "rotate": false]
        XCTAssertEqual(PushNotificationService.confirmedKey(status: status, installationID: Self.installationID, records: [record]), record)
        XCTAssertNil(PushNotificationService.confirmedKey(status: status, installationID: Self.installationID, records: []))
        XCTAssertNil(PushNotificationService.confirmedKey(status: status, installationID: "other", records: [record]))
        var noKey = status
        noKey["e2e"] = NSNull()
        XCTAssertNil(PushNotificationService.confirmedKey(status: noKey, installationID: Self.installationID, records: [record]))
    }

    func testThePadlockClosesOnlyForAKeyTheHostConfirmed() {
        typealias Confirmation = PushNotificationService.EncryptionConfirmation
        func assurance(_ records: [E2EKeyRecord], _ confirmation: Confirmation?, at date: Date? = nil) -> PushNotificationService.EncryptionAssurance {
            PushNotificationService.encryptionAssurance(gatewayID: Self.gatewayID, installationID: Self.installationID,
                                                        records: records, confirmation: confirmation, now: date ?? now)
        }
        let confirmed = Confirmation(kid: Self.kid, rotates: true)
        XCTAssertEqual(assurance([record], confirmed), .ensured(keyCreatedAt: record.createdAt, rotates: true, quantumSafe: false))
        var pq = record
        pq.suite = NotificationKeyRotation.suitePQ
        XCTAssertEqual(assurance([pq], confirmed), .ensured(keyCreatedAt: record.createdAt, rotates: true, quantumSafe: true))
        XCTAssertEqual(assurance([], nil), .notEncrypted)
        XCTAssertEqual(assurance([record], nil), .unconfirmed)
        // The host seals with a key this iPhone lost, or holds for another installation.
        XCTAssertEqual(assurance([], confirmed), .mismatched)
        let otherInstallation = E2EKeyRecord(kid: Self.kid, secret: Self.secret, installationID: "other", gatewayID: Self.gatewayID,
                                             dashboardID: nil, profile: nil, createdAt: record.createdAt)
        XCTAssertEqual(assurance([otherInstallation], confirmed), .mismatched)
        // Rotation kept failing past the grace period.
        let late = now.addingTimeInterval(NotificationE2E.keyMaxAge + NotificationE2E.previousKeyGrace)
        XCTAssertEqual(assurance([record], confirmed, at: late), .overdue(keyCreatedAt: record.createdAt))
        // A host that can't rotate isn't overdue: nothing could be done.
        let keeps = Confirmation(kid: Self.kid, rotates: false)
        XCTAssertEqual(assurance([record], keeps, at: late), .ensured(keyCreatedAt: record.createdAt, rotates: false, quantumSafe: false))
    }

    // MARK: Inline rotation (conduit-e2e/2)

    func testRotationDerivationMatchesThePlugin() {
        // tests/test_e2e.py ROTATION_VECTOR in hermes-conduit-notifier.
        let info = NotificationKeyRotation.info(
            kid: Self.kid, kidNew: "fedcba9876543210fedcba9876543210", installationID: Self.installationID, gatewayID: "gw-1",
            suite: NotificationKeyRotation.suitePQ, ek: Data(0..<16), xpub: Data(count: 32), hostXpub: Data(repeating: 1, count: 32),
            ct: Data(0..<8)
        )
        let secret = NotificationKeyRotation.rotatedSecret(
            ssPQ: Data(repeating: 2, count: 32), ssX: Data(repeating: 3, count: 32), oldSecret: Self.secret, info: info
        )
        XCTAssertEqual(secret.map { String(format: "%02x", $0) }.joined(),
                       "3e1d41576dbc23aae71465d40df6185ddc2dedef720e3f6da49a767b2f89b1fd")
    }

    func testTheBestSuiteBothSidesRunIsChosen() {
        let both = [NotificationKeyRotation.suitePQ, NotificationKeyRotation.suiteClassical]
        XCTAssertEqual(NotificationKeyRotation.suite(hostSuites: both, supportsPQ: true), NotificationKeyRotation.suitePQ)
        XCTAssertEqual(NotificationKeyRotation.suite(hostSuites: both, supportsPQ: false), NotificationKeyRotation.suiteClassical)
        XCTAssertEqual(NotificationKeyRotation.suite(hostSuites: [NotificationKeyRotation.suiteClassical], supportsPQ: true),
                       NotificationKeyRotation.suiteClassical)
        XCTAssertNil(NotificationKeyRotation.suite(hostSuites: [], supportsPQ: true))
    }

    func testHandedOverAndClassicalKeysAreReplacedInline() {
        var key = record
        XCTAssertTrue(PushNotificationService.wantsInlineRotation(held: key, suite: NotificationKeyRotation.suiteClassical, hostAsks: false),
                      "A key handed over through the dashboard is replaced at once")
        key.suite = NotificationKeyRotation.suiteClassical
        XCTAssertFalse(PushNotificationService.wantsInlineRotation(held: key, suite: NotificationKeyRotation.suiteClassical, hostAsks: false))
        XCTAssertTrue(PushNotificationService.wantsInlineRotation(held: key, suite: NotificationKeyRotation.suitePQ, hostAsks: false),
                      "After an update to iOS 26 the next rotation is quantum-safe")
        XCTAssertTrue(PushNotificationService.wantsInlineRotation(held: key, suite: NotificationKeyRotation.suiteClassical, hostAsks: true))
        key.suite = NotificationKeyRotation.suitePQ
        XCTAssertFalse(PushNotificationService.wantsInlineRotation(held: key, suite: NotificationKeyRotation.suitePQ, hostAsks: false))
    }

    /// The host's side, as e2e.answer_rotation does it.
    private func hostAnswer(_ request: [String: Any], current: E2EKeyRecord) throws -> (reply: [String: Any], secret: Data) {
        let suite = try XCTUnwrap(request["suite"] as? String)
        let sealed = try XCTUnwrap(request["sealed"] as? [String: String])
        let combined = try XCTUnwrap(sealed["ct"].flatMap(NotificationE2E.base64URLDecoded))
        let box = try ChaChaPoly.SealedBox(
            nonce: ChaChaPoly.Nonce(data: try XCTUnwrap(sealed["n"].flatMap(NotificationE2E.base64URLDecoded))),
            ciphertext: combined.prefix(combined.count - 16), tag: combined.suffix(16)
        )
        let plain = try ChaChaPoly.open(box, using: NotificationE2E.keys(secret: current.secret).answer, authenticating:
            NotificationKeyRotation.requestAAD(kid: current.kid, installationID: current.installationID, gatewayID: current.gatewayID, suite: suite))
        let inner = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: String])
        let kidNew = try XCTUnwrap(inner["kid_new"])
        let xpub = try XCTUnwrap(inner["xpub"].flatMap(NotificationE2E.base64URLDecoded))
        let host = Curve25519.KeyAgreement.PrivateKey()
        let ssX = try host.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: xpub)).withUnsafeBytes { Data($0) }
        var ek = Data(), ct = Data(), ssPQ = Data()
        var content: [String: String] = ["kid_new": kidNew, "suite": suite, "host_xpub": NotificationE2E.base64URL(host.publicKey.rawRepresentation)]
        if suite == NotificationKeyRotation.suitePQ {
            guard #available(iOS 26.0, *) else { throw XCTSkip("ML-KEM needs iOS 26") }
            ek = try XCTUnwrap(inner["ek"].flatMap(NotificationE2E.base64URLDecoded))
            XCTAssertEqual(ek.count, NotificationKeyRotation.mlkemEncapsulationKeyBytes)
            let result = try MLKEM768.PublicKey(rawRepresentation: ek).encapsulate()
            ct = result.encapsulated
            ssPQ = result.sharedSecret.withUnsafeBytes { Data($0) }
            content["ct"] = NotificationE2E.base64URL(ct)
        }
        let secret = NotificationKeyRotation.rotatedSecret(
            ssPQ: ssPQ, ssX: ssX, oldSecret: current.secret,
            info: NotificationKeyRotation.info(kid: current.kid, kidNew: kidNew, installationID: current.installationID,
                                               gatewayID: current.gatewayID, suite: suite, ek: ek, xpub: xpub,
                                               hostXpub: host.publicKey.rawRepresentation, ct: ct)
        )
        let nonce = ChaChaPoly.Nonce()
        let replyBox = try ChaChaPoly.seal(
            try JSONSerialization.data(withJSONObject: content), using: NotificationE2E.keys(secret: current.secret).push, nonce: nonce,
            authenticating: NotificationKeyRotation.replyAAD(kid: current.kid, kidNew: kidNew, installationID: current.installationID,
                                                             gatewayID: current.gatewayID, suite: suite)
        )
        let reply: [String: Any] = [
            "kid": current.kid, "kid_new": kidNew, "suite": suite,
            "sealed": ["n": NotificationE2E.base64URL(nonce.withUnsafeBytes { Data($0) }),
                       "ct": NotificationE2E.base64URL(replyBox.ciphertext + replyBox.tag)],
        ]
        return (reply, secret)
    }

    func testAClassicalRotationDerivesTheHostsSecret() throws {
        let pending = try NotificationKeyRotation.start(current: record, suite: NotificationKeyRotation.suiteClassical)
        let (reply, secret) = try hostAnswer(pending.request, current: record)
        let rotated = try NotificationKeyRotation.finish(pending, reply: reply, dashboardID: nil, profile: nil)
        XCTAssertEqual(rotated.secret, secret)
        XCTAssertEqual(rotated.suite, NotificationKeyRotation.suiteClassical)
        XCTAssertNotEqual(rotated.kid, record.kid)
        XCTAssertEqual(rotated.gatewayID, record.gatewayID)
    }

    func testAQuantumSafeRotationDerivesTheHostsSecret() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("ML-KEM needs iOS 26") }
        let pending = try NotificationKeyRotation.start(current: record, suite: NotificationKeyRotation.suitePQ)
        let (reply, secret) = try hostAnswer(pending.request, current: record)
        let rotated = try NotificationKeyRotation.finish(pending, reply: reply, dashboardID: nil, profile: nil)
        XCTAssertEqual(rotated.secret, secret)
        XCTAssertEqual(rotated.suite, NotificationKeyRotation.suitePQ)
    }

    func testARotationReplyThatIsTamperedOrForAnotherRequestIsRefused() throws {
        let pending = try NotificationKeyRotation.start(current: record, suite: NotificationKeyRotation.suiteClassical)
        var (reply, _) = try hostAnswer(pending.request, current: record)
        var wrongKid = reply
        wrongKid["kid_new"] = String(repeating: "c", count: 32)
        XCTAssertThrowsError(try NotificationKeyRotation.finish(pending, reply: wrongKid, dashboardID: nil, profile: nil))
        var sealed = try XCTUnwrap(reply["sealed"] as? [String: String])
        let ct = try XCTUnwrap(sealed["ct"])
        sealed["ct"] = String(ct.dropLast(2)) + (ct.hasSuffix("AA") ? "BB" : "AA")
        reply["sealed"] = sealed
        XCTAssertThrowsError(try NotificationKeyRotation.finish(pending, reply: reply, dashboardID: nil, profile: nil))
    }
}

