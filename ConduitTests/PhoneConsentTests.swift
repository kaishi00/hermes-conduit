import CryptoKit
import XCTest

@testable import Conduit

// Source tests only until run on the required macOS/Xcode validation lane.
extension BotModeTests {
    private func phoneConsentVector() throws -> [String: String] {
        let url = try XCTUnwrap(Bundle(for: BotModeTests.self).url(forResource: "phone-consent-v1", withExtension: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String])
    }

    func testPhoneConsentWireVector() throws {
        let vector = try phoneConsentVector()
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: XCTUnwrap(Data(base64Encoded: vector["seed"]!)))
        let message = Data(vector["message"]!.utf8)
        XCTAssertEqual(key.publicKey.rawRepresentation.base64EncodedString(), vector["public_key"])
        XCTAssertEqual(try key.signature(for: message).base64EncodedString(), vector["signature"])
        XCTAssertTrue(key.publicKey.isValidSignature(try XCTUnwrap(Data(base64Encoded: vector["signature"]!)), for: message))
        XCTAssertFalse(key.publicKey.isValidSignature(try XCTUnwrap(Data(base64Encoded: vector["signature"]!)), for: message + Data([0])))
        let signed = try PhoneConsentClient.sign(["challenge": String(repeating: "0", count: 32), "message": vector["message"]!], key: key,
            expected: ["action": "grant_approve", "digest": vector["digest"]!, "device": String(repeating: "d", count: 32)],
            now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(signed["signature"] as? String, NotificationE2E.base64URL(try XCTUnwrap(Data(base64Encoded: vector["signature"]!))))
        let card = try PhoneScopedGrant(row: ["id": "G" + String(repeating: "1", count: 32), "digest": vector["digest"]!,
                                              "status": "pending", "snapshot_text": vector["snapshot_text"]!])
        XCTAssertEqual(card.snapshot.task, "Read release notes: café 😀.")
        XCTAssertEqual(card.snapshot.provenance.turn_id, "turn-1")
        XCTAssertEqual(card.snapshot.origin?.session, "origin-session")
    }

    @MainActor
    func testPhoneConsentReconnectReadsFreshAndNeverReplays() async throws {
        let vector = try phoneConsentVector()
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: XCTUnwrap(Data(base64Encoded: vector["seed"]!)))
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(vector["message"]!.utf8)) as? [String: Any])
        let response: [String: Any] = ["protocol": PhoneConsentClient.wireProtocol, "owner": "test-owner", "profile_id": "test-profile",
            "installation": "test-installation", "pairing": context["pairing"]!, "device": String(repeating: "d", count: 32),
            "public_key": NotificationE2E.base64URL(key.publicKey.rawRepresentation),
            "grants": [["id": "G" + String(repeating: "1", count: 32), "digest": vector["digest"]!,
                        "status": "pending", "snapshot_text": vector["snapshot_text"]!]]]
        let model = PhoneConsentModel()
        var methods: [String] = []
        let client = PhoneConsentClient(profile: "default", parameter: "conduit_profile") { _, method, _ in
            methods.append(method)
            return response
        }
        await model.refresh(client: client, allowed: true, key: key)
        XCTAssertTrue(model.canAct)
        model.invalidate()  // disconnect/background/profile or chat switch
        XCTAssertFalse(model.canAct)
        XCTAssertNil(model.preview)
        await model.refresh(client: client, allowed: false, key: key)
        XCTAssertEqual(methods, ["GET"])
        await model.refresh(client: client, allowed: true, key: key)
        XCTAssertEqual(methods, ["GET", "GET"])
        XCTAssertTrue(model.canAct)
        await model.refresh(client: client, allowed: true, key: Curve25519.Signing.PrivateKey())
        XCTAssertFalse(model.canAct, "a different phone cannot use a displayed enrollment")
    }

    func testPhoneConsentKeyIsDeviceLocalProfileScopedAndUnavailableWhileLocked() throws {
        let oldBackend = KeychainHelper.backend
        let backend = InMemoryKeychainBackend()
        KeychainHelper.useBackendForTesting(backend)
        defer { KeychainHelper.useBackendForTesting(oldBackend) }
        let dashboard = UUID()
        let key = Curve25519.Signing.PrivateKey()
        XCTAssertTrue(KeychainHelper.savePhoneConsentKey(key, dashboardID: dashboard, profile: "default"))
        XCTAssertEqual(KeychainHelper.phoneConsentKey(dashboardID: dashboard, profile: "default")?.rawRepresentation, key.rawRepresentation)
        XCTAssertNil(KeychainHelper.phoneConsentKey(dashboardID: UUID(), profile: "default"))
        XCTAssertNil(KeychainHelper.phoneConsentKey(dashboardID: dashboard, profile: "other"))
        backend.phoneLocked = true
        XCTAssertNil(KeychainHelper.phoneConsentKey(dashboardID: dashboard, profile: "default"))
        XCTAssertFalse(KeychainHelper.savePhoneConsentKey(key, dashboardID: dashboard, profile: "default"))
    }

    func testPhoneConsentSnapshotFailsClosedRatherThanDroppingMalformedCards() throws {
        XCTAssertThrowsError(try PhoneConsentPreview(response: ["protocol": "unknown"]))
        XCTAssertThrowsError(try PhoneConsentPreview(response: ["protocol": PhoneConsentClient.wireProtocol, "grants": [[:]]]))
        let text = "{\"task\":\"different\"}"
        XCTAssertThrowsError(try PhoneScopedGrant(row: ["id": "G1", "digest": String(repeating: "0", count: 64),
                                                        "status": "pending", "snapshot_text": text]))
    }

    @MainActor
    func testPhoneConsentOfflineAndUnknownCapabilityNeverReadOrApprove() async {
        let model = PhoneConsentModel()
        var calls = 0
        let client = PhoneConsentClient(profile: "default", parameter: "conduit_profile") { _, _, _ in
            calls += 1
            return [:]
        }
        await model.refresh(client: client, allowed: false, key: nil)
        XCTAssertNil(model.preview)
        XCTAssertFalse(model.canAct)
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testPhoneConsentLostReadClearsPreviouslyDisplayedAuthority() async {
        let model = PhoneConsentModel()
        let client = PhoneConsentClient(profile: "default", parameter: "conduit_profile") { _, _, _ in
            throw URLError(.notConnectedToInternet)
        }
        await model.refresh(client: client, allowed: true, key: nil)
        XCTAssertNil(model.preview)
        XCTAssertFalse(model.canAct)
        model.invalidate()
        XCTAssertNil(model.preview)
    }

    func testPhoneConsentChallengeRejectsUnexpectedActionAndSnapshot() throws {
        let key = Curve25519.Signing.PrivateKey()
        let body: [String: Any] = ["challenge": "nonce", "message": "{}"]
        XCTAssertThrowsError(try PhoneConsentClient.sign(body, key: key, expected: ["action": "grant_approve"], now: Date()))
    }

    @MainActor
    func testPhoneConsentNeverRetriesAnUncertainReceipt() async throws {
        let key = Curve25519.Signing.PrivateKey()
        var requests: [String] = []
        let client = PhoneConsentClient(profile: "test", parameter: "conduit_profile") { path, _, body in
            requests.append(path)
            if path.contains("/challenge") {
                let message: [String: Any] = ["protocol": PhoneConsentClient.wireProtocol, "challenge": "nonce",
                    "expires": Int(Date().timeIntervalSince1970) + 30,
                    "public_key": NotificationE2E.base64URL(key.publicKey.rawRepresentation), "action": "enroll",
                    "installation_id": "ignored"]
                return ["challenge": "nonce", "message": String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)]
            }
            throw URLError(.timedOut)
        }
        do {
            _ = try await client.perform(body: ["action": "enroll"], expected: ["action": "enroll"], key: key, stillCurrent: { true })
            XCTFail("must surface an uncertain write")
        } catch {}
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.contains("conduit_profile=test") })
    }

    @MainActor
    func testPhoneConsentSwitchWhileChallengeIsInFlightNeverSigns() async throws {
        let key = Curve25519.Signing.PrivateKey()
        var current = true
        var requests = 0
        let client = PhoneConsentClient(profile: "test", parameter: "conduit_profile") { _, _, _ in
            requests += 1
            current = false
            return [:]
        }
        do {
            _ = try await client.perform(body: ["action": "enroll"], expected: [:], key: key, stillCurrent: { current })
            XCTFail("must fence switch")
        } catch {}
        XCTAssertEqual(requests, 1)
    }
}
