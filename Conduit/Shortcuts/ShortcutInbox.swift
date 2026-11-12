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
//  next run or the next connect. Each dashboard and profile has its own
//  queue, device id and key (ShortcutInboxScope), and one inbox operation
//  runs at a time (ShortcutInboxGate).
//

import CryptoKit
import Foundation
import OSLog

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

    /// What inbox_store.py keeps of each field (MAX_SOURCE_CHARS and the
    /// rest), counted in Unicode scalars as Python counts characters. Cut
    /// here, so a long email never makes a batch the host's size cap refuses.
    static let maxSource = 120
    static let maxTitle = 200
    static let maxText = 4_000
    static let maxAmount = 40

    init(id: String = UUID().uuidString, kind: Kind, at: Date, source: String? = nil, title: String? = nil,
         text: String? = nil, amount: String? = nil) {
        self.id = id
        self.kind = kind
        self.at = at
        self.source = Self.cleaned(source, limit: Self.maxSource)
        self.title = Self.cleaned(title, limit: Self.maxTitle)
        self.text = Self.cleaned(text, limit: Self.maxText)
        self.amount = Self.cleaned(amount, limit: Self.maxAmount)
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

    private static func cleaned(_ value: String?, limit: Int) -> String? {
        var trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.unicodeScalars.count > limit {
            trimmed = String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(limit)))
        }
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

    /// Every field the action takes: a code or sign-in link in From or
    /// Amount stays on the phone too.
    static func looksLikeCode(_ event: ShortcutEvent) -> Bool {
        looksLikeCode(event.source, event.title, event.text, event.amount)
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
              nonceData.count == 12, let sealed = NotificationE2E.base64URLDecoded(ctText), sealed.count >= 16 else {
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

/// The dashboard and profile an event was logged for. Its queue, device id
/// and key belong to that pair alone, like the other phone data: an event
/// never goes to another profile's inbox, and agreeing a key with one never
/// drops what another holds.
struct ShortcutInboxScope: Codable, Hashable {
    var dashboardID: UUID
    var profile: String

    /// A stable name for the queue file's entry and the keychain account.
    var storageID: String {
        let digest = SHA256.hash(data: Data("\(dashboardID.uuidString.lowercased())\n\(profile)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }
}

/// Events that couldn't go yet, per dashboard and profile, oldest first,
/// until a later run or connect sends them. Never more than `capacity` per
/// inbox, and never older than the days the host keeps.
///
/// Event content stays out of UserDefaults and backups: one file in
/// Application Support, excluded from backup and protected until the phone
/// is first unlocked after a restart. Automations run while the phone is
/// locked, so complete protection would refuse them; the inbox key's
/// keychain item has the same after-first-unlock, this-device-only reach.
@MainActor
struct ShortcutInboxQueue {
    static let capacity = 50
    static let keepDays = 30

    struct Slot: Codable, Equatable {
        /// Whose slot this is, so forgetting a dashboard can find its own.
        var scope: ShortcutInboxScope?
        var deviceID: String?
        var events: [ShortcutEvent] = []
    }

    let url: URL
    let scope: ShortcutInboxScope

    nonisolated static var standardURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ShortcutInbox", isDirectory: true).appendingPathComponent("queue.json")
    }

    static func standard(_ scope: ShortcutInboxScope) -> ShortcutInboxQueue {
        ShortcutInboxQueue(url: standardURL, scope: scope)
    }

    /// The id this inbox's events go under, made on first use; nil when
    /// the file can't be written (not unlocked since restart).
    func ensureDeviceID() -> String? {
        if let known = knownDeviceID { return known }
        guard var all = readAll() else { return nil }
        let made = "inbox-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
        all[scope.storageID, default: Slot(scope: scope)].deviceID = made
        return writeAll(all) ? made : nil
    }

    /// The id this inbox already has; nil before its first event.
    var knownDeviceID: String? { readAll()?[scope.storageID]?.deviceID }

    func pending(now: Date = Date()) -> [ShortcutEvent] {
        let oldest = now.addingTimeInterval(-Double(Self.keepDays) * 86_400)
        return (readAll()?[scope.storageID]?.events ?? []).filter { $0.at >= oldest }
    }

    /// False when the event couldn't be kept.
    @discardableResult
    func add(_ event: ShortcutEvent, now: Date = Date()) -> Bool {
        guard var all = readAll() else { return false }
        // Older than the host keeps: it would never go, so it isn't kept.
        guard event.at >= now.addingTimeInterval(-Double(Self.keepDays) * 86_400) else { return true }
        let kept = Array((pending(now: now) + [event]).suffix(Self.capacity))
        all[scope.storageID, default: Slot(scope: scope)].events = kept
        return writeAll(all)
    }

    func remove(_ sent: [ShortcutEvent]) {
        remove(ids: Set(sent.map(\.id)))
    }

    func remove(ids: Set<String>) {
        guard var all = readAll(), let slot = all[scope.storageID], slot.events.contains(where: { ids.contains($0.id) }) else {
            return
        }
        all[scope.storageID]?.events = pending().filter { !ids.contains($0.id) }
        writeAll(all)
    }

    /// Forgets what waits for this inbox; its device id stays.
    func clear() {
        guard var all = readAll(), all[scope.storageID]?.events.isEmpty == false else { return }
        all[scope.storageID]?.events = []
        writeAll(all)
    }

    /// Forgets every inbox of a dashboard the user removed: what waits for
    /// it could never go anywhere now. Their keys go with them.
    static func forgetDashboard(_ dashboardID: UUID, url: URL = standardURL,
                                clearKey: (ShortcutInboxScope) -> Void = { ShortcutInboxKeyStore.keychain($0).clear() }) {
        let any = ShortcutInboxQueue(url: url, scope: ShortcutInboxScope(dashboardID: dashboardID, profile: ""))
        guard var all = any.readAll() else { return }
        let gone = all.filter { $0.value.scope?.dashboardID == dashboardID }
        guard !gone.isEmpty else { return }
        for (id, slot) in gone {
            all[id] = nil
            if let scope = slot.scope { clearKey(scope) }
        }
        any.writeAll(all)
    }

    /// Every inbox's slot; nil when the file is there but can't be read yet.
    private func readAll() -> [String: Slot]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode([String: Slot].self, from: data)
        } catch {
            // Never silently: the unreadable file is set aside for a look,
            // and the queue starts over.
            Self.log.error("Shortcut inbox queue unreadable, set aside: \(String(describing: error), privacy: .public)")
            let aside = url.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            return [:]
        }
    }

    private static let log = Logger(subsystem: "com.milim.relay", category: "shortcut-inbox")

    @discardableResult
    private func writeAll(_ all: [String: Slot]) -> Bool {
        do {
            var folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
            try JSONEncoder().encode(all).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var file = url
            try? file.setResourceValues(values)
            if url == Self.standardURL { ShortcutInboxLocalState.shared.noteQueue(all, now: Date()) }
            return true
        } catch {
            return false
        }
    }
}

struct ShortcutInboxKeyStore {
    var load: () -> ShortcutInboxCrypto.SessionKey?
    var save: (ShortcutInboxCrypto.SessionKey) -> Void
    var clear: () -> Void

    /// The key this inbox agreed with its profile, one keychain item each.
    static func keychain(_ scope: ShortcutInboxScope) -> ShortcutInboxKeyStore {
        let id = scope.storageID
        return ShortcutInboxKeyStore(
            load: {
                KeychainHelper.loadShortcutInboxKey(scope: id)
                    .flatMap { try? JSONDecoder().decode(ShortcutInboxCrypto.SessionKey.self, from: $0) }
            },
            save: { key in
                if let data = try? JSONEncoder().encode(key) { KeychainHelper.saveShortcutInboxKey(data, scope: id) }
                Task { @MainActor in ShortcutInboxLocalState.shared.noteKey(true, for: id) }
            },
            clear: {
                KeychainHelper.clearShortcutInboxKey(scope: id)
                Task { @MainActor in ShortcutInboxLocalState.shared.noteKey(false, for: id) }
            }
        )
    }
}

/// What the Settings home needs to know about each inbox on this phone (a
/// key, events waiting), kept in memory so drawing Settings never reads the
/// queue file or the keychain. The queue and key store report their writes
/// here; an inbox not seen yet this launch is read once, off the drawing
/// path (``load(_:)``), and the change is published.
@MainActor
final class ShortcutInboxLocalState: ObservableObject {
    static let shared = ShortcutInboxLocalState()

    /// Per ShortcutInboxScope.storageID.
    @Published private(set) var waiting: [String: Int] = [:]
    @Published private(set) var keyed: [String: Bool] = [:]

    /// Whether this inbox has a key or waiting events; nil until it's known.
    func hasLocalData(_ scope: ShortcutInboxScope) -> Bool? {
        let id = scope.storageID
        guard let count = waiting[id], let key = keyed[id] else { return nil }
        return key || count > 0
    }

    /// Reads one inbox's state from disk and the keychain, unless known.
    func load(_ scope: ShortcutInboxScope) {
        let id = scope.storageID
        if waiting[id] == nil { waiting[id] = ShortcutInboxQueue.standard(scope).pending().count }
        if keyed[id] == nil { keyed[id] = ShortcutInboxKeyStore.keychain(scope).load() != nil }
    }

    func noteQueue(_ all: [String: ShortcutInboxQueue.Slot], now: Date) {
        let oldest = now.addingTimeInterval(-Double(ShortcutInboxQueue.keepDays) * 86_400)
        var counts = waiting
        for key in counts.keys where all[key] == nil { counts[key] = 0 }
        for (id, slot) in all { counts[id] = slot.events.filter { $0.at >= oldest }.count }
        if counts != waiting { waiting = counts }
    }

    func noteKey(_ present: Bool, for id: String) {
        if keyed[id] != present { keyed[id] = present }
    }
}

/// Requests that give up at a deadline: each one waits at most until then,
/// whatever the transport does, and none starts after it. A pass that
/// holds the gate (ShortcutInboxGate) with these can't keep a Log to Hermes
/// run waiting longer than its deadline.
enum ShortcutInboxDeadline {
    static func bounded(_ request: @escaping ShortcutInboxSender.Request, until deadline: Date) -> ShortcutInboxSender.Request {
        { path, method, body in
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw ShortcutInboxUnavailable.outOfTime }
            return try await withThrowingTaskGroup(of: [String: Any]?.self) { group in
                group.addTask { try await request(path, method, body) }
                group.addTask {
                    try await Task.sleep(for: .seconds(remaining))
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let answer = first else {
                    throw ShortcutInboxUnavailable.outOfTime
                }
                return answer
            }
        }
    }
}

/// One inbox operation at a time: two automation runs at once would both
/// send what waits, and both agree a first key. A later caller waits for
/// the one in flight, then reads the queue afresh.
@MainActor
final class ShortcutInboxGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ operation: () async throws -> T) async rethrows -> T {
        while busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return try await operation()
    }
}

/// What the phone couldn't do itself.
enum ShortcutInboxUnavailable: Error, Equatable {
    /// The queue file can't be read or written (not unlocked since restart).
    case storage
    /// The run's time is up.
    case outOfTime
    /// Another dashboard is in use now.
    case otherDashboard
    /// Hermes isn't connected.
    case notConnected
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
        guard let deviceID = queue.ensureDeviceID() else { throw ShortcutInboxUnavailable.storage }
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
            throw DashboardTicketBridgeError.requestFailed(AppLocalization.string("The host didn't return a key.", table: .phone))
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

/// Settings > Shortcuts inbox: reads back what this iPhone logged for the
/// dashboard and profile in use, sealed for it alone, and deletes what the
/// user picks. Only this iPhone's own events: the key is this inbox's, and
/// the host answers for its device id.
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
        guard let key = keys.load(), let deviceID = queue.knownDeviceID else { return Page(entries: [], next: nil) }
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

    /// Deletes these events from the host, and any copy still waiting
    /// here (a send whose answer was lost would bring it back); how many
    /// the host deleted.
    func delete(_ ids: [String], request: Request) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        queue.remove(ids: Set(ids))
        guard let key = keys.load(), let deviceID = queue.knownDeviceID else { return 0 }
        let answer = try await request("\(ShortcutInboxSender.base)/delete", "POST",
                                       ["device_id": deviceID, "kid": key.kid, "ids": ids])
        return answer["deleted"] as? Int ?? 0
    }

    /// Deletes everything this iPhone logged for this inbox: what waits
    /// here at once, then what the host keeps and the key, so the next Log
    /// to Hermes starts over. Throws when the host couldn't be reached; the
    /// waiting events are gone either way.
    func deleteAll(request: Request?) async throws {
        queue.clear()
        guard let deviceID = queue.knownDeviceID else {
            keys.clear()
            return
        }
        guard let request else { throw ShortcutInboxUnavailable.notConnected }
        _ = try await request("\(ShortcutInboxSender.base)/wipe", "POST", ["device_id": deviceID])
        keys.clear()
    }
}
