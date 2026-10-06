import CryptoKit
import Foundation
import Security

/// End-to-end encrypted notification content (#431), shared by Conduit and
/// its Notification Service Extension.
///
/// Each relay pairing gets a 32-byte root secret created on this iPhone and
/// handed to the Hermes notifier plugin over the dashboard connection, so it
/// never passes through the push relay or APNs. Both sides derive separate
/// keys from it with HKDF-SHA256 (gateway → device content, device → gateway
/// clarify answers) and seal with ChaCha20-Poly1305. The associated data binds
/// every envelope to its pairing and to the fields the relay can see.
///
/// Wire format and derivation mirror hermes-conduit-notifier's `e2e.py`;
/// NotificationE2ETests checks both against vectors produced by it.
enum NotificationE2E {
    static let appGroup = "group.com.milim.relay.notifications"
    static let userInfoKey = "conduit_e2e"
    static let answerPrefix = "e2e1."
    static let maxAge: TimeInterval = 24 * 60 * 60
    static let maxClockSkew: TimeInterval = 60 * 60

    private static let salt = Data("conduit-e2e-v1".utf8)
    private static let pushInfo = Data("conduit-e2e-v1 push gateway-to-device".utf8)
    private static let answerInfo = Data("conduit-e2e-v1 answer device-to-gateway".utf8)
    private static let aadTag = "conduit-e2e/1"

    struct Keys {
        let push: SymmetricKey
        let answer: SymmetricKey
    }

    static func keys(secret: Data) -> Keys {
        let root = SymmetricKey(data: secret)
        func derive(_ info: Data) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: root, salt: salt, info: info, outputByteCount: 32)
        }
        return Keys(push: derive(pushInfo), answer: derive(answerInfo))
    }

    /// A new pairing key: a random secret and an unrelated random key id.
    static func newRecord(installationID: String, gatewayID: String, dashboardID: String?, profile: String?, now: Date = Date()) -> E2EKeyRecord {
        E2EKeyRecord(
            kid: randomBytes(16).map { String(format: "%02x", $0) }.joined(),
            secret: randomBytes(32),
            installationID: installationID,
            gatewayID: gatewayID,
            dashboardID: dashboardID,
            profile: profile,
            createdAt: now
        )
    }

    private static func randomBytes(_ count: Int) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }

    // MARK: Envelope

    /// The `conduit_e2e` object exactly as the relay forwarded it.
    struct Envelope: Equatable {
        let kid: String
        let msg: String
        let iat: Int
        let tok: String
        let z: Int
        let req: String
        let nonce: Data
        let ciphertext: Data

        /// Identifies one sealed message across deliveries (replay checks).
        var replayKey: String { "\(kid):\(msg)" }

        init?(_ value: Any?) {
            guard let object = value as? [String: Any],
                  (object["v"] as? NSNumber)?.intValue == 1,
                  let kid = object["kid"] as? String, kid.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil,
                  let msg = object["msg"] as? String, !msg.isEmpty,
                  let iat = (object["iat"] as? NSNumber)?.intValue, iat > 0,
                  let tok = object["tok"] as? String, tok.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil,
                  let z = (object["z"] as? NSNumber)?.intValue, z == 0 || z == 1,
                  let req = object["req"] as? String,
                  let nonce = (object["n"] as? String).flatMap(NotificationE2E.base64URLDecoded), nonce.count == 12,
                  let ciphertext = (object["ct"] as? String).flatMap(NotificationE2E.base64URLDecoded), ciphertext.count >= 16
            else { return nil }
            self.kid = kid
            self.msg = msg
            self.iat = iat
            self.tok = tok
            self.z = z
            self.req = req
            self.nonce = nonce
            self.ciphertext = ciphertext
        }
    }

    static func pushAAD(kid: String, installationID: String, gatewayID: String, msg: String, type: String, iat: Int, tok: String, z: Int, requestID: String) -> Data {
        Data([
            aadTag, "push", "kid=\(kid)", "inst=\(installationID)", "gw=\(gatewayID)",
            "msg=\(msg)", "type=\(type)", "iat=\(iat)", "tok=\(tok)", "z=\(z)", "req=\(requestID)",
        ].joined(separator: "\n").utf8)
    }

    static func answerAAD(kid: String, installationID: String, gatewayID: String, requestID: String, questionID: String) -> Data {
        Data([
            aadTag, "answer", "kid=\(kid)", "inst=\(installationID)", "gw=\(gatewayID)",
            "req=\(requestID)", "qid=\(questionID)",
        ].joined(separator: "\n").utf8)
    }

    // MARK: Trust

    /// How a delivered notification may be used.
    enum Evaluation {
        /// No envelope, from a pairing that never set up encryption: today's
        /// plaintext behavior.
        case legacy
        /// Unauthenticated: an envelope that doesn't verify, is stale or
        /// unknown, or plaintext for a pairing that has a key. Shows only
        /// generic text and drives no routing or decision card.
        case untrusted(type: String?)
        case verified(Verified)
    }

    struct Verified {
        let record: E2EKeyRecord
        let envelope: Envelope
        let type: String
        /// The decrypted content: title, body, session_id, profile,
        /// stored_session_id, decision.
        let content: [String: Any]

        /// The routing payload Conduit's push parser reads, built only from
        /// authenticated data: the decrypted content, the type bound in the
        /// associated data, and the gateway and dashboard this key was
        /// provisioned for (never the relay's routing stub).
        var routingPayload: [String: Any] {
            var payload = content
            payload.removeValue(forKey: "title")
            payload.removeValue(forKey: "body")
            payload["type"] = type
            payload["gateway_id"] = record.gatewayID
            if let dashboardID = record.dashboardID { payload["dashboard_id"] = dashboardID }
            return payload
        }
    }

    /// The relay's routing stub (top-level `conduit`, else `body.conduit`).
    static func routingStub(_ userInfo: [AnyHashable: Any]) -> [String: Any]? {
        (userInfo["conduit"] as? [String: Any]) ?? ((userInfo["body"] as? [String: Any])?["conduit"] as? [String: Any])
    }

    /// `knownGatewayIDs` are the keyless relay pairings this iPhone may still
    /// trust plaintext from (see `knownGatewayIDs(listed:previous:holdsKeys:)`),
    /// shared through the App Group so the extension applies the same rule.
    /// `keysProvisioned` is the App Group marker that this iPhone has stored a
    /// key: with it set, an empty `records` means the Keychain couldn't be
    /// read (before first unlock, say), not that there are no keys.
    static func evaluate(
        _ userInfo: [AnyHashable: Any],
        records: [E2EKeyRecord],
        knownGatewayIDs: Set<String>,
        keysProvisioned: Bool,
        now: Date = Date()
    ) -> Evaluation {
        let stub = routingStub(userInfo)
        let type = (stub?["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard userInfo[userInfoKey] != nil else {
            // Plaintext. With no key at all, today's behavior. Once this
            // iPhone holds any key, plaintext is trusted only from a keyless
            // pairing it already knew about when it stored its first key:
            // naming a keyed pairing, no pairing, or any pairing listed
            // since is a downgrade, so a relay can't invent one later.
            if records.isEmpty {
                // Keys were stored but none could be read: every pairing
                // may be an encrypted one, so no plaintext is trusted.
                return keysProvisioned ? .untrusted(type: type) : .legacy
            }
            let gatewayID = (stub?["gateway_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !gatewayID.isEmpty,
                  knownGatewayIDs.contains(gatewayID),
                  !records.contains(where: { $0.gatewayID == gatewayID }) else {
                return .untrusted(type: type)
            }
            return .legacy
        }
        guard let envelope = Envelope(userInfo[userInfoKey]),
              let type, !type.isEmpty,
              let record = records.first(where: { $0.kid == envelope.kid }) else {
            return .untrusted(type: type)
        }
        let issuedAt = Date(timeIntervalSince1970: TimeInterval(envelope.iat))
        guard issuedAt >= now.addingTimeInterval(-maxAge), issuedAt <= now.addingTimeInterval(maxClockSkew) else {
            return .untrusted(type: type)
        }
        let aad = pushAAD(
            kid: record.kid, installationID: record.installationID, gatewayID: record.gatewayID,
            msg: envelope.msg, type: type, iat: envelope.iat, tok: envelope.tok, z: envelope.z, requestID: envelope.req
        )
        guard let box = try? ChaChaPoly.SealedBox(combined: envelope.nonce + envelope.ciphertext),
              let opened = try? ChaChaPoly.open(box, using: keys(secret: record.secret).push, authenticating: aad),
              let content = inflate(opened, compressed: envelope.z == 1) else {
            return .untrusted(type: type)
        }
        // A decision answers to the request the ciphertext is bound to.
        if let decision = content["decision"] as? [String: Any],
           let requestID = decision["request_id"] as? String,
           requestID != envelope.req {
            return .untrusted(type: type)
        }
        return .verified(Verified(record: record, envelope: envelope, type: type, content: content))
    }

    /// The keyless pairings plaintext may still come from, after the relay
    /// lists `listed`. Before this iPhone holds a key, that's whatever the
    /// relay lists. After, the set only shrinks: a pairing first listed
    /// once encryption is on (or one a hostile relay makes up) never joins.
    /// A host paired later with an old notifier therefore shows only generic
    /// text until it updates and gets its own key.
    static func knownGatewayIDs(listed: Set<String>, previous: Set<String>, holdsKeys: Bool) -> Set<String> {
        holdsKeys ? previous.intersection(listed) : listed
    }

    private static func inflate(_ data: Data, compressed: Bool) -> [String: Any]? {
        var raw = data
        if compressed {
            // Raw DEFLATE, which the Compression framework calls zlib.
            guard let inflated = try? (data as NSData).decompressed(using: .zlib) as Data else { return nil }
            raw = inflated
        }
        return (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
    }

    /// A clarify answer sealed for the gateway that asked, bound to its
    /// request and question.
    static func sealAnswer(_ answer: String, record: E2EKeyRecord, requestID: String, questionID: String?) throws -> String {
        let nonce = ChaChaPoly.Nonce()
        let aad = answerAAD(
            kid: record.kid, installationID: record.installationID, gatewayID: record.gatewayID,
            requestID: requestID, questionID: questionID ?? ""
        )
        let box = try ChaChaPoly.seal(Data(answer.utf8), using: keys(secret: record.secret).answer, nonce: nonce, authenticating: aad)
        let nonceData = nonce.withUnsafeBytes { Data($0) }
        return "\(answerPrefix)\(record.kid).\(base64URL(nonceData)).\(base64URL(box.ciphertext + box.tag))"
    }

    // MARK: Generic copy

    /// The private fallback for a notification Conduit can't verify. Kept
    /// word for word with the relay's generic copy (English, like every
    /// relay-written alert), so a push reads the same whether the relay or
    /// the extension wrote it.
    static func genericCopy(for type: String?) -> (title: String, body: String) {
        switch type {
        case "approval.needed": return ("Approval needed", "Hermes is waiting for your approval.")
        case "input.needed": return ("Input needed", "Hermes needs your response before it can continue.")
        case "turn.failed": return ("Turn failed", "A Hermes turn could not be completed.")
        case "background_task.finished": return ("Background task finished", "A delegated task has finished.")
        default: return ("Response ready", "Hermes has finished responding.")
        }
    }

    // MARK: Base64url

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecoded(_ value: String) -> Data? {
        guard value.range(of: "^[A-Za-z0-9_-]*$", options: .regularExpression) != nil, value.count % 4 != 1 else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

/// One pairing's key as this iPhone stores it. `installationID` and
/// `gatewayID` are the relay pairing the plugin accepted it for;
/// `dashboardID` and `profile` are where its notifications belong.
struct E2EKeyRecord: Codable, Equatable {
    let kid: String
    let secret: Data
    let installationID: String
    let gatewayID: String
    let dashboardID: String?
    let profile: String?
    let createdAt: Date
}

protocol E2EKeyStoring {
    func records() -> [E2EKeyRecord]
    /// The stored keys, or nil when the store can't be read right now (as
    /// opposed to holding none).
    func readRecords() -> [E2EKeyRecord]?
    @discardableResult func save(_ record: E2EKeyRecord) -> Bool
    func remove(kid: String)
}

/// Pairing keys in the Keychain, shared with the Notification Service
/// Extension through the App Group (an App Group is also a keychain access
/// group). Readable after first unlock so the extension can decrypt while the
/// iPhone is locked, and never synced or restored to another device.
struct KeychainE2EKeyStore: E2EKeyStoring {
    static let service = "com.milim.relay.e2e"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccessGroup as String: NotificationE2E.appGroup,
        ]
    }

    func records() -> [E2EKeyRecord] {
        readRecords() ?? []
    }

    func readRecords() -> [E2EKeyRecord]? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let values = items as? [Data] else { return nil }
        let decoder = JSONDecoder()
        return values.compactMap { try? decoder.decode(E2EKeyRecord.self, from: $0) }
    }

    @discardableResult
    func save(_ record: E2EKeyRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        remove(kid: record.kid)
        var query = baseQuery
        query[kSecAttrAccount as String] = record.kid
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    func remove(kid: String) {
        var query = baseQuery
        query[kSecAttrAccount as String] = kid
        SecItemDelete(query as CFDictionary)
    }
}

/// Sealed messages already seen, kept in the App Group container so the
/// extension and the app share it. Two uses: the extension records each
/// delivery (a second delivery of the same message is a replay and shows
/// only generic text), and the app records each message it routes from a tap
/// (a replay can't route again after the original was opened). Entries older
/// than the freshness window are pruned: the envelope check already rejects
/// anything that old.
final class E2ESeenStore {
    static let retention: TimeInterval = 2 * NotificationE2E.maxAge
    static let maxEntries = 4096

    private let url: URL?
    private var memory: [String: Double] = [:]

    init(url: URL?) {
        self.url = url
    }

    static var shared: E2ESeenStore {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: NotificationE2E.appGroup)
        return E2ESeenStore(url: container?.appendingPathComponent("e2e-seen.json"))
    }

    /// Records `key` in `namespace`; false if it was already there. The app
    /// and the extension are separate processes, so the read-modify-write
    /// runs under a file lock beside the store.
    func insert(_ key: String, namespace: String, now: Date = Date()) -> Bool {
        withFileLock { insertLocked(key, namespace: namespace, now: now) }
    }

    /// Waits up to about a second for the lock: a process suspended while
    /// holding it must not stall the extension past its time budget. If it
    /// can't be had, the insert runs unlocked (best effort, as before).
    private func withFileLock<T>(_ body: () -> T) -> T {
        guard let url else { return body() }
        let descriptor = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return body() }
        defer { close(descriptor) }
        var locked = false
        for _ in 0..<20 {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                locked = true
                break
            }
            usleep(50_000)
        }
        defer { if locked { flock(descriptor, LOCK_UN) } }
        return body()
    }

    private func insertLocked(_ key: String, namespace: String, now: Date) -> Bool {
        let entry = "\(namespace):\(key)"
        var entries = load()
        let cutoff = now.timeIntervalSince1970 - Self.retention
        entries = entries.filter { $0.value >= cutoff }
        if entries[entry] != nil {
            store(entries)
            return false
        }
        entries[entry] = now.timeIntervalSince1970
        if entries.count > Self.maxEntries {
            for (oldKey, _) in entries.sorted(by: { $0.value < $1.value }).prefix(entries.count - Self.maxEntries) {
                entries.removeValue(forKey: oldKey)
            }
        }
        store(entries)
        return true
    }

    private func load() -> [String: Double] {
        guard let url else { return memory }
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return entries
    }

    private func store(_ entries: [String: Double]) {
        guard let url else {
            memory = entries
            return
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        // Readable after first unlock: the extension runs on a locked iPhone.
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Settings the extension needs from the app, mirrored into the App Group.
enum NotificationSharedSettings {
    private static let showPreviewsKey = "conduit.notifications.showPreviews"

    static var defaults: UserDefaults? { UserDefaults(suiteName: NotificationE2E.appGroup) }

    static var showPreviews: Bool {
        get { defaults?.bool(forKey: showPreviewsKey) ?? false }
        set { defaults?.set(newValue, forKey: showPreviewsKey) }
    }

    private static let knownGatewayIDsKey = "conduit.notifications.knownGatewayIDs"
    private static let keysProvisionedMarker = "e2e-keys-provisioned"

    /// Whether this iPhone has stored an encryption key: a file in the App
    /// Group container with no data protection, so the extension can usually
    /// check it while the Keychain and these defaults can't be read.
    static var keysProvisioned: Bool {
        guard let url = markerURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Writes the marker; false when it couldn't be written, and then no key
    /// may be stored.
    @discardableResult
    static func markKeysProvisioned() -> Bool {
        guard let url = markerURL else { return false }
        if keysProvisioned { return true }
        do {
            // No secret in it, and it must be readable while locked.
            try Data().write(to: url, options: [.noFileProtection])
            return true
        } catch {
            return false
        }
    }

    static func clearKeysProvisioned() {
        guard let url = markerURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static var markerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: NotificationE2E.appGroup)?
            .appendingPathComponent(keysProvisionedMarker)
    }

    /// The relay pairings last listed for this iPhone (see
    /// NotificationE2E.evaluate).
    static var knownGatewayIDs: Set<String> {
        get { Set(defaults?.stringArray(forKey: knownGatewayIDsKey) ?? []) }
        set { defaults?.set(newValue.sorted(), forKey: knownGatewayIDsKey) }
    }
}
