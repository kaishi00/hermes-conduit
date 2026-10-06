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
        guard case .verified(let verified) = NotificationE2E.evaluate(delivered(), records: [record], knownGatewayIDs: [], now: now) else {
            return XCTFail("the plugin's envelope should verify")
        }
        XCTAssertEqual(verified.content["title"] as? String, "Hermes")
        XCTAssertEqual(verified.content["body"] as? String, "Deploy to prod?")

        let target = try XCTUnwrap(PushNotificationService.parseNotificationTarget(from: delivered(), records: [record], knownGatewayIDs: [], now: now))
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
        XCTAssertUntrusted(NotificationE2E.evaluate(retyped, records: [record], knownGatewayIDs: [], now: now))

        var rethreaded = Self.envelope
        rethreaded["tok"] = "0000000000000000"
        XCTAssertUntrusted(NotificationE2E.evaluate(delivered(envelope: rethreaded), records: [record], knownGatewayIDs: [], now: now))

        var moved = Self.envelope
        moved["req"] = "conduit-push-000000000000"
        XCTAssertUntrusted(NotificationE2E.evaluate(delivered(envelope: moved), records: [record], knownGatewayIDs: [], now: now))

        let stale = Date(timeIntervalSince1970: Self.issuedAt + NotificationE2E.maxAge + 1)
        XCTAssertUntrusted(NotificationE2E.evaluate(delivered(), records: [record], knownGatewayIDs: [], now: stale))
        let early = Date(timeIntervalSince1970: Self.issuedAt - NotificationE2E.maxClockSkew - 1)
        XCTAssertUntrusted(NotificationE2E.evaluate(delivered(), records: [record], knownGatewayIDs: [], now: early))

        // Another pairing's key, or none at all.
        let other = E2EKeyRecord(kid: Self.kid, secret: Data(repeating: 1, count: 32), installationID: Self.installationID, gatewayID: Self.gatewayID, dashboardID: nil, profile: nil, createdAt: now)
        XCTAssertUntrusted(NotificationE2E.evaluate(delivered(), records: [other], knownGatewayIDs: [], now: now))
        XCTAssertUntrusted(NotificationE2E.evaluate(delivered(), records: [], knownGatewayIDs: [], now: now))

        retyped["conduit_e2e"] = "garbage"
        XCTAssertUntrusted(NotificationE2E.evaluate(retyped, records: [record], knownGatewayIDs: [], now: now))
        XCTAssertNil(PushNotificationService.parseNotificationTarget(from: delivered(type: "approval.needed"), records: [record], knownGatewayIDs: [], now: now))
    }

    func testPlaintextIsADowngradeOnlyForPairingsWithAKey() {
        let plaintext: [AnyHashable: Any] = ["conduit": ["type": "response.ready", "session_id": "sess-1", "gateway_id": Self.gatewayID]]
        XCTAssertUntrusted(NotificationE2E.evaluate(plaintext, records: [record], knownGatewayIDs: [], now: now))
        XCTAssertNil(PushNotificationService.parseNotificationTarget(from: plaintext, records: [record], knownGatewayIDs: [], now: now))

        // A known pairing that never provisioned a key keeps today's behavior.
        let legacy: [AnyHashable: Any] = ["conduit": ["type": "response.ready", "session_id": "sess-2", "gateway_id": "another-gateway"]]
        let known: Set<String> = [Self.gatewayID, "another-gateway"]
        XCTAssertEqual(PushNotificationService.parseNotificationTarget(from: legacy, records: [record], knownGatewayIDs: known, now: now)?.sessionId, "sess-2")
        // Even listed, a keyed pairing's plaintext stays a downgrade.
        XCTAssertNil(PushNotificationService.parseNotificationTarget(from: plaintext, records: [record], knownGatewayIDs: known, now: now))
        // A pairing this iPhone has never seen can't vouch for plaintext.
        let invented: [AnyHashable: Any] = ["conduit": ["type": "response.ready", "session_id": "sess-4", "gateway_id": "made-up-gateway"]]
        XCTAssertUntrusted(NotificationE2E.evaluate(invented, records: [record], knownGatewayIDs: known, now: now))
        XCTAssertNil(PushNotificationService.parseNotificationTarget(from: invented, records: [record], knownGatewayIDs: known, now: now))
        // With no key at all, every plaintext push behaves as before.
        XCTAssertEqual(PushNotificationService.parseNotificationTarget(from: invented, records: [], knownGatewayIDs: [], now: now)?.sessionId, "sess-4")

        // No gateway named: unattributable once this iPhone holds any key.
        let unscoped: [AnyHashable: Any] = ["conduit": ["type": "response.ready", "session_id": "sess-3"]]
        XCTAssertNil(PushNotificationService.parseNotificationTarget(from: unscoped, records: [record], knownGatewayIDs: [], now: now))
        XCTAssertEqual(PushNotificationService.parseNotificationTarget(from: unscoped, records: [], knownGatewayIDs: [], now: now)?.sessionId, "sess-3")
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
