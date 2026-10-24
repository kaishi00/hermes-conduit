//
//  ShortcutInbox.swift
//  Conduit
//
//  What the "Log to Hermes" Shortcuts action keeps for Hermes. An iOS
//  automation (a notification from an app the user picks, a message, an
//  email, a Wallet payment, an NFC tag, a sound the phone hears) hands its
//  content to the action, and Conduit posts it to the plugin's inbox as one
//  event: no chat turn and no push. Hermes reads it with conduit_inbox.
//
//  Sealed end to end like calendar and health: one X25519 agreement with
//  the profile (POST /inbox/key), HKDF-SHA256 and ChaCha20-Poly1305 with the
//  inbox's own labels. Must match inbox_store.py in hermes-conduit-notifier;
//  both check the vector in its tests/inbox_vector.json.
//
//  An event that looks like a sign-in code never leaves the phone, and one
//  that can't go now waits (at most ShortcutInboxQueue.capacity) for the
//  next run.
//

import CryptoKit
import Foundation

/// One run of an automation, as the inbox stores it.
struct ShortcutEvent: Codable, Equatable {
    /// The kinds inbox_store.py takes.
    enum Kind: String, Codable, CaseIterable {
        case notification, message, email, transaction, nfc, sound, other
    }

    var id: String
    var kind: Kind
    var at: Date
    var source: String?
    var title: String?
    var text: String?
    var amount: String?

    init(id: String = UUID().uuidString, kind: Kind, at: Date, source: String? = nil, title: String? = nil,
         text: String? = nil, amount: String? = nil) {
        self.id = id
        self.kind = kind
        self.at = at
        self.source = Self.cleaned(source)
        self.title = Self.cleaned(title)
        self.text = Self.cleaned(text)
        self.amount = Self.cleaned(amount)
    }

    var carriesSomething: Bool { [source, title, text, amount].contains { $0 != nil } }

    /// The event as the batch sends it: its time with the phone's offset, so
    /// "this morning" means the user's morning.
    func json(timeZone: TimeZone = .current) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        var item: [String: Any] = ["id": id, "kind": kind.rawValue, "at": formatter.string(from: at)]
        if let source { item["source"] = source }
        if let title { item["title"] = title }
        if let text { item["text"] = text }
        if let amount { item["amount"] = amount }
        return item
    }

    private static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Sign-in codes, one-time passwords and sign-in links: never logged. The
/// host checks the same words again (inbox_store.py's looks_like_code);
/// keep both lists in step.
enum ShortcutEventFilter {
    private static let words = try! NSRegularExpression(
        pattern: #"\b(verification|verify|security|login|log-in|sign-in|signin|one[- ]time|two[- ]factor|authentication|auth|confirmation|access)\s+(code|password|pin|link)\b|\b(otp|2fa|passcode)\b|\b(your|the|this|ton|votre)\s+code\b|\bcode\s*(is|:|est)|\bcode de (vérification|sécurité|confirmation)\b|\bmot de passe (à usage unique|temporaire)\b"#,
        options: [.caseInsensitive])
    private static let digits = try! NSRegularExpression(
        pattern: #"(?<![\d.,$€£])\b\d{4,8}\b(?![.,]\d)|\b\d{3}[- ]\d{3}\b|\b[A-Z0-9]{3,4}-[A-Z0-9]{3,4}\b"#)
    private static let link = try! NSRegularExpression(
        pattern: #"\b(sign[- ]?in|log[- ]?in|verification|verify|magic|confirm)\b[^\n]{0,80}https?://"#,
        options: [.caseInsensitive])

    static func looksLikeCode(_ parts: String?...) -> Bool {
        let text = parts.compactMap { $0 }.joined(separator: " ")
        let range = NSRange(text.startIndex..., in: text)
        func found(_ expression: NSRegularExpression) -> Bool { expression.firstMatch(in: text, range: range) != nil }
        return (found(words) && found(digits)) || found(link)
    }

    static func looksLikeCode(_ event: ShortcutEvent) -> Bool {
        looksLikeCode(event.title, event.text)
    }
}

enum ShortcutInboxCrypto {
    static let salt = Data("conduit-inbox-v1".utf8)
    static let ingestInfo = Data("conduit-inbox-v1 ingest device-to-host".utf8)
    /// What the host seals for this phone alone: its own events, read back
    /// on the Settings page.
    static let answerInfo = Data("conduit-inbox-v1 answer host-to-device".utf8)
    static let aadTag = "conduit-inbox/1"

    enum Failure: Error, Equatable {
        case malformedHostKey
        case keyIDMismatch
        case malformedAnswer
    }

    struct SessionKey: Codable, Equatable {
        var kid: String
        var ingest: Data
        var answer: Data
    }

    static func keyID(devicePublic: Data, hostPublic: Data) -> String {
        let digest = SHA256.hash(data: Data("conduit-inbox-kid\n".utf8) + devicePublic + hostPublic)
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    static func agree(
        devicePrivate: Curve25519.KeyAgreement.PrivateKey,
        deviceID: String,
        hostPublicKey: String,
        kid: String
    ) throws -> SessionKey {
        guard let hostPublic = NotificationE2E.base64URLDecoded(hostPublicKey), hostPublic.count == 32,
              let host = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: hostPublic) else {
            throw Failure.malformedHostKey
        }
        let devicePublic = devicePrivate.publicKey.rawRepresentation
        guard keyID(devicePublic: devicePublic, hostPublic: hostPublic) == kid else { throw Failure.keyIDMismatch }
        let shared = try devicePrivate.sharedSecretFromKeyAgreement(with: host)
        func derive(_ purpose: Data) -> Data {
            let info = purpose + Data("\n\(deviceID)\n".utf8) + devicePublic + hostPublic
            let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info, outputByteCount: 32)
            return key.withUnsafeBytes { Data($0) }
        }
        return SessionKey(kid: kid, ingest: derive(ingestInfo), answer: derive(answerInfo))
    }

    static func ingestAAD(kid: String, deviceID: String, batchID: String) -> Data {
        Data([aadTag, "ingest", "kid=\(kid)", "dev=\(deviceID)", "batch=\(batchID)"].joined(separator: "\n").utf8)
    }

    static func listAAD(kid: String, deviceID: String, requestID: String) -> Data {
        Data([aadTag, "list", "kid=\(kid)", "dev=\(deviceID)", "req=\(requestID)"].joined(separator: "\n").utf8)
    }

    /// Opens an `/inbox/list` answer: it opens only for this request.
    static func openAnswer(_ body: [String: Any], key: SessionKey, deviceID: String, requestID: String) throws -> Data {
        guard let nonceText = body["nonce"] as? String, let ctText = body["ct"] as? String,
              let nonceData = NotificationE2E.base64URLDecoded(nonceText),
              let sealed = NotificationE2E.base64URLDecoded(ctText), sealed.count >= 16 else {
            throw Failure.malformedAnswer
        }
        let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonceData), ciphertext: sealed.dropLast(16),
                                           tag: sealed.suffix(16))
        return try ChaChaPoly.open(box, using: SymmetricKey(data: key.answer),
                                   authenticating: listAAD(kid: key.kid, deviceID: deviceID, requestID: requestID))
    }

    /// The `/inbox/ingest` body for a batch's JSON.
    static func envelope(
        plaintext: Data,
        key: SessionKey,
        deviceID: String,
        batchID: String,
        nonce: ChaChaPoly.Nonce = ChaChaPoly.Nonce()
    ) throws -> [String: Any] {
        let aad = ingestAAD(kid: key.kid, deviceID: deviceID, batchID: batchID)
        let box = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: key.ingest), nonce: nonce, authenticating: aad)
        return ["v": 1, "device_id": deviceID, "kid": key.kid, "batch_id": batchID,
                "nonce": NotificationE2E.base64URL(Data(box.nonce)),
                "ct": NotificationE2E.base64URL(box.ciphertext + box.tag)]
    }
}

/// Events that couldn't go yet, oldest first, kept in UserDefaults until the
/// next run sends them. Never more than `capacity`, and never older than
/// the days the host keeps.
struct ShortcutInboxQueue {
    static let capacity = 50
    static let keepDays = 14
    private static let eventsKey = "conduit.shortcutInbox.pending"
    private static let deviceKey = "conduit.shortcutInbox.deviceID"

    let defaults: UserDefaults

    var deviceID: String {
        if let known = defaults.string(forKey: Self.deviceKey) { return known }
        let made = "inbox-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
        defaults.set(made, forKey: Self.deviceKey)
        return made
    }

    func pending(now: Date = Date()) -> [ShortcutEvent] {
        guard let data = defaults.data(forKey: Self.eventsKey),
              let events = try? JSONDecoder().decode([ShortcutEvent].self, from: data) else { return [] }
        let oldest = now.addingTimeInterval(-Double(Self.keepDays) * 86_400)
        return events.filter { $0.at >= oldest }
    }

    func add(_ event: ShortcutEvent, now: Date = Date()) {
        save(Array((pending(now: now) + [event]).suffix(Self.capacity)))
    }

    func remove(_ sent: [ShortcutEvent]) {
        let ids = Set(sent.map(\.id))
        save(pending().filter { !ids.contains($0.id) })
    }

    func clear() {
        defaults.removeObject(forKey: Self.eventsKey)
    }

    private func save(_ events: [ShortcutEvent]) {
        if events.isEmpty {
            defaults.removeObject(forKey: Self.eventsKey)
        } else if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: Self.eventsKey)
        }
    }
}

struct ShortcutInboxKeyStore {
    var load: () -> ShortcutInboxCrypto.SessionKey?
    var save: (ShortcutInboxCrypto.SessionKey) -> Void
    var clear: () -> Void

    static let keychain = ShortcutInboxKeyStore(
        load: {
            KeychainHelper.loadShortcutInboxKey().flatMap { try? JSONDecoder().decode(ShortcutInboxCrypto.SessionKey.self, from: $0) }
        },
        save: { key in
            if let data = try? JSONEncoder().encode(key) { KeychainHelper.saveShortcutInboxKey(data) }
        },
        clear: { KeychainHelper.clearShortcutInboxKey() }
    )
}

/// Sends what's waiting, this run's event last, in one sealed batch.
@MainActor
struct ShortcutInboxSender {
    typealias Request = (_ path: String, _ method: String, _ body: [String: Any]?) async throws -> [String: Any]

    static let base = "/api/plugins/conduit_push/inbox"

    let queue: ShortcutInboxQueue
    let keys: ShortcutInboxKeyStore
    var deviceName: String = "iPhone"
    var timeZone: TimeZone = .current

    /// How many events reached the host.
    func send(request: Request) async throws -> Int {
        let events = queue.pending()
        guard !events.isEmpty else { return 0 }
        let deviceID = queue.deviceID
        let batchID = "batch-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
        let batch: [String: Any] = [
            "batch_id": String(batchID),
            "device": ["name": deviceName, "time_zone": timeZone.identifier],
            "keep_days": ShortcutInboxQueue.keepDays,
            "events": events.map { $0.json(timeZone: timeZone) },
        ]
        let plaintext = try JSONSerialization.data(withJSONObject: batch)
        func post(_ key: ShortcutInboxCrypto.SessionKey) async throws {
            let envelope = try ShortcutInboxCrypto.envelope(plaintext: plaintext, key: key, deviceID: deviceID,
                                                           batchID: String(batchID))
            _ = try await request("\(Self.base)/ingest", "POST", envelope)
        }
        do {
            try await post(try await ensureKey(deviceID: deviceID, request: request))
        } catch DashboardTicketBridgeError.http(let status, let detail) where status == 409 && HostKeyConflict.isKeyLoss(detail) {
            // The host forgot or replaced this phone's key (a wipe, a new
            // store): agree a new one, once.
            keys.clear()
            try await post(try await ensureKey(deviceID: deviceID, request: request))
        }
        queue.remove(events)
        return events.count
    }

    private func ensureKey(deviceID: String, request: Request) async throws -> ShortcutInboxCrypto.SessionKey {
        let status = try await request("\(Self.base)/status?device_id=\(deviceID)", "GET", nil)
        let hostKid = (status["device"] as? [String: Any])?["kid"] as? String
        if let key = keys.load(), key.kid == hostKid { return key }
        let devicePrivate = Curve25519.KeyAgreement.PrivateKey()
        let answer = try await request("\(Self.base)/key", "POST", [
            "device_id": deviceID,
            "device_name": deviceName,
            "public_key": NotificationE2E.base64URL(devicePrivate.publicKey.rawRepresentation),
        ])
        guard let hostPublic = answer["host_public_key"] as? String, let kid = answer["kid"] as? String else {
            throw DashboardTicketBridgeError.requestFailed(AppLocalization.string("The host didn't return a key."))
        }
        let key = try ShortcutInboxCrypto.agree(devicePrivate: devicePrivate, deviceID: deviceID,
                                                hostPublicKey: hostPublic, kid: kid)
        keys.save(key)
        return key
    }
}

/// One logged event as the Settings page shows it.
struct ShortcutInboxEntry: Identifiable, Equatable {
    var id: String
    var kind: ShortcutEvent.Kind
    var at: Date?
    var source: String?
    var title: String?
    var text: String?
    var amount: String?

    init?(_ item: [String: Any]) {
        guard let id = item["id"] as? String else { return nil }
        self.id = id
        kind = (item["kind"] as? String).flatMap(ShortcutEvent.Kind.init(rawValue:)) ?? .other
        at = (item["at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        source = item["source"] as? String
        title = item["title"] as? String
        text = item["text"] as? String
        amount = item["amount"] as? String
    }
}

/// Settings > Shortcuts inbox: reads back what this iPhone logged, sealed
/// for it alone, and deletes what the user picks. Only this iPhone's own
/// events: the key is this phone's, and the host answers for its device id.
@MainActor
struct ShortcutInboxBrowser {
    typealias Request = ShortcutInboxSender.Request

    struct Page: Equatable {
        var entries: [ShortcutInboxEntry]
        /// Where the next page starts (the host's `next`), nil at the end.
        var next: Cursor?
    }

    struct Cursor: Equatable {
        var at: Int
        var id: String
    }

    let queue: ShortcutInboxQueue
    let keys: ShortcutInboxKeyStore
    var pageSize = 50

    /// The page after ``before``, newest first. Empty when this iPhone
    /// never logged anything, or the host no longer has its key (a wipe:
    /// nothing it sent is left there).
    func page(before: Cursor? = nil, request: Request) async throws -> Page {
        guard let key = keys.load() else { return Page(entries: [], next: nil) }
        let deviceID = queue.deviceID
        let requestID = "list-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
        var body: [String: Any] = ["device_id": deviceID, "kid": key.kid, "request_id": String(requestID),
                                   "limit": pageSize]
        if let before { body["before"] = [before.at, before.id] }
        let answer: [String: Any]
        do {
            answer = try await request("\(ShortcutInboxSender.base)/list", "POST", body)
        } catch DashboardTicketBridgeError.http(let status, let detail) where status == 409 && HostKeyConflict.isKeyLoss(detail) {
            keys.clear()  // the next Log to Hermes agrees a new one
            return Page(entries: [], next: nil)
        }
        let opened = try ShortcutInboxCrypto.openAnswer(answer, key: key, deviceID: deviceID, requestID: String(requestID))
        guard let page = try JSONSerialization.jsonObject(with: opened) as? [String: Any],
              page["request_id"] as? String == String(requestID) else {
            throw ShortcutInboxCrypto.Failure.malformedAnswer
        }
        let entries = (page["events"] as? [[String: Any]] ?? []).compactMap(ShortcutInboxEntry.init)
        var next: Cursor?
        if let raw = page["next"] as? [Any], raw.count == 2, let at = raw[0] as? Int, let id = raw[1] as? String {
            next = Cursor(at: at, id: id)
        }
        return Page(entries: entries, next: next)
    }

    /// Deletes these events from the host; how many it deleted.
    func delete(_ ids: [String], request: Request) async throws -> Int {
        guard let key = keys.load(), !ids.isEmpty else { return 0 }
        let answer = try await request("\(ShortcutInboxSender.base)/delete", "POST",
                                       ["device_id": queue.deviceID, "kid": key.kid, "ids": ids])
        return answer["deleted"] as? Int ?? 0
    }

    /// Deletes everything this iPhone logged, on the host and waiting here,
    /// and its key: the next Log to Hermes starts over.
    func deleteAll(request: Request) async throws {
        _ = try await request("\(ShortcutInboxSender.base)/wipe", "POST", ["device_id": queue.deviceID])
        queue.clear()
        keys.clear()
    }
}
