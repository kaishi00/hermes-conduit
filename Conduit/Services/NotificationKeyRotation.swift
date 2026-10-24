import CryptoKit
import Foundation

/// Inline rotation of a pairing's end-to-end key (conduit-e2e/2), the phone's
/// side of hermes-conduit-notifier's `e2e.py` rotation.
///
/// The request, sealed with the current key's answer key, carries a fresh
/// X25519 share and, on iOS 26 and later, an ML-KEM-768 encapsulation key.
/// The host answers with its X25519 share and the ML-KEM ciphertext, sealed
/// with the push key. Both derive the new secret with HKDF-SHA256 from the
/// exchange mixed with the old secret, so it never crosses the dashboard
/// connection: only a pairing's first key depends on that connection, and
/// with ML-KEM even a recording of it can't open later notifications.
/// Below iOS 26 the X25519 suite still gives break-in recovery: a leaked key
/// stops opening anything after the next rotation.
enum NotificationKeyRotation {
    static let suitePQ = "mlkem768+x25519"
    static let suiteClassical = "x25519"
    static let path = "/api/plugins/conduit_push/e2e/rotate"

    private static let salt = Data("conduit-e2e-v2 rotate".utf8)
    private static let aadTag = "conduit-e2e/2"
    static let mlkemEncapsulationKeyBytes = 1184
    static let mlkemCiphertextBytes = 1088

    enum RotationError: Error {
        case malformed
        case unverified
    }

    /// Whether this iPhone can run the quantum-safe suite.
    static var supportsPQ: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// The best suite both sides can run, or nil when the host can't rotate
    /// inline.
    static func suite(hostSuites: [String], supportsPQ: Bool = NotificationKeyRotation.supportsPQ) -> String? {
        if supportsPQ, hostSuites.contains(suitePQ) { return suitePQ }
        return hostSuites.contains(suiteClassical) ? suiteClassical : nil
    }

    static func requestAAD(kid: String, installationID: String, gatewayID: String, suite: String) -> Data {
        Data([aadTag, "rotate-request", "kid=\(kid)", "inst=\(installationID)", "gw=\(gatewayID)", "suite=\(suite)"]
            .joined(separator: "\n").utf8)
    }

    static func replyAAD(kid: String, kidNew: String, installationID: String, gatewayID: String, suite: String) -> Data {
        Data([aadTag, "rotate-reply", "kid=\(kid)", "kid_new=\(kidNew)", "inst=\(installationID)", "gw=\(gatewayID)", "suite=\(suite)"]
            .joined(separator: "\n").utf8)
    }

    /// HKDF info: every value both sides sent.
    static func info(kid: String, kidNew: String, installationID: String, gatewayID: String, suite: String,
                     ek: Data, xpub: Data, hostXpub: Data, ct: Data) -> Data {
        Data([
            "conduit-e2e-v2 rotate", "kid=\(kid)", "kid_new=\(kidNew)", "inst=\(installationID)", "gw=\(gatewayID)",
            "suite=\(suite)", "ek=\(sha256Hex(ek))", "xpub=\(hex(xpub))", "host_xpub=\(hex(hostXpub))", "ct=\(sha256Hex(ct))",
        ].joined(separator: "\n").utf8)
    }

    static func rotatedSecret(ssPQ: Data, ssX: Data, oldSecret: Data, info: Data) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ssPQ + ssX + oldSecret), salt: salt, info: info, outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    /// One rotation in flight: the request to send (again, on a retry) and
    /// the private halves that open the reply.
    struct Pending {
        let current: E2EKeyRecord
        let kidNew: String
        let suite: String
        let request: [String: Any]
        fileprivate let xPrivate: Curve25519.KeyAgreement.PrivateKey
        fileprivate let kem: Any?
        fileprivate let ek: Data
        let createdAt: Date
    }

    static func start(current: E2EKeyRecord, suite: String, now: Date = Date()) throws -> Pending {
        let kidNew = NotificationE2E.newRecord(installationID: "", gatewayID: "", dashboardID: nil, profile: nil).kid
        let xPrivate = Curve25519.KeyAgreement.PrivateKey()
        var inner: [String: String] = [
            "kid_new": kidNew,
            "suite": suite,
            "xpub": NotificationE2E.base64URL(xPrivate.publicKey.rawRepresentation),
        ]
        var kem: Any?
        var ek = Data()
        if suite == suitePQ {
            guard #available(iOS 26.0, *) else { throw RotationError.malformed }
            let privateKey = try MLKEM768.PrivateKey()
            ek = privateKey.publicKey.rawRepresentation
            inner["ek"] = NotificationE2E.base64URL(ek)
            kem = privateKey
        }
        let sealed = try sealJSON(
            inner,
            key: NotificationE2E.keys(secret: current.secret).answer,
            aad: requestAAD(kid: current.kid, installationID: current.installationID, gatewayID: current.gatewayID, suite: suite)
        )
        let request: [String: Any] = [
            "kid": current.kid,
            "suite": suite,
            "installation_id": current.installationID,
            "gateway_id": current.gatewayID,
            "sealed": sealed,
        ]
        return Pending(current: current, kidNew: kidNew, suite: suite, request: request,
                       xPrivate: xPrivate, kem: kem, ek: ek, createdAt: now)
    }

    /// The new key from the host's reply, or a RotationError when the reply
    /// isn't for this request or doesn't verify.
    static func finish(_ pending: Pending, reply: [String: Any], dashboardID: String?, profile: String?, now: Date = Date()) throws -> E2EKeyRecord {
        let current = pending.current
        guard reply["kid"] as? String == current.kid,
              reply["kid_new"] as? String == pending.kidNew,
              reply["suite"] as? String == pending.suite,
              let sealed = reply["sealed"] as? [String: Any] else {
            throw RotationError.malformed
        }
        let content = try openJSON(
            sealed,
            key: NotificationE2E.keys(secret: current.secret).push,
            aad: replyAAD(kid: current.kid, kidNew: pending.kidNew, installationID: current.installationID,
                          gatewayID: current.gatewayID, suite: pending.suite)
        )
        guard content["kid_new"] as? String == pending.kidNew, content["suite"] as? String == pending.suite,
              let hostXpub = (content["host_xpub"] as? String).flatMap(NotificationE2E.base64URLDecoded), hostXpub.count == 32 else {
            throw RotationError.malformed
        }
        let hostKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hostXpub)
        let ssX = try pending.xPrivate.sharedSecretFromKeyAgreement(with: hostKey).withUnsafeBytes { Data($0) }
        var ssPQ = Data()
        var ct = Data()
        if pending.suite == suitePQ {
            guard #available(iOS 26.0, *), let kem = pending.kem as? MLKEM768.PrivateKey,
                  let ciphertext = (content["ct"] as? String).flatMap(NotificationE2E.base64URLDecoded),
                  ciphertext.count == mlkemCiphertextBytes else {
                throw RotationError.malformed
            }
            ct = ciphertext
            ssPQ = try kem.decapsulate(ciphertext).withUnsafeBytes { Data($0) }
        }
        let secret = rotatedSecret(
            ssPQ: ssPQ, ssX: ssX, oldSecret: current.secret,
            info: info(kid: current.kid, kidNew: pending.kidNew, installationID: current.installationID,
                       gatewayID: current.gatewayID, suite: pending.suite, ek: pending.ek,
                       xpub: pending.xPrivate.publicKey.rawRepresentation, hostXpub: hostXpub, ct: ct)
        )
        return E2EKeyRecord(
            kid: pending.kidNew, secret: secret, installationID: current.installationID, gatewayID: current.gatewayID,
            dashboardID: dashboardID ?? current.dashboardID, profile: profile ?? current.profile, createdAt: now,
            suite: pending.suite
        )
    }

    // MARK: Sealing

    private static func sealJSON(_ value: [String: String], key: SymmetricKey, aad: Data) throws -> [String: String] {
        let raw = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let nonce = ChaChaPoly.Nonce()
        let box = try ChaChaPoly.seal(raw, using: key, nonce: nonce, authenticating: aad)
        return [
            "n": NotificationE2E.base64URL(nonce.withUnsafeBytes { Data($0) }),
            "ct": NotificationE2E.base64URL(box.ciphertext + box.tag),
        ]
    }

    private static func openJSON(_ sealed: [String: Any], key: SymmetricKey, aad: Data) throws -> [String: Any] {
        guard let nonceData = (sealed["n"] as? String).flatMap(NotificationE2E.base64URLDecoded), nonceData.count == 12,
              let combined = (sealed["ct"] as? String).flatMap(NotificationE2E.base64URLDecoded), combined.count >= 16 else {
            throw RotationError.malformed
        }
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: nonceData),
                ciphertext: combined.prefix(combined.count - 16),
                tag: combined.suffix(16)
            )
            let plain = try ChaChaPoly.open(box, using: key, authenticating: aad)
            guard let value = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else { throw RotationError.malformed }
            return value
        } catch {
            throw RotationError.unverified
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }
}
