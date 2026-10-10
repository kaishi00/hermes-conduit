//
//  HermesRing.swift
//  Conduit and the Conduit Watch app
//
//  A call from Hermes that rings on the iPhone and the Apple Watch alike
//  (relay 0.10+, designs/hermes-calls-watch.md). iOS doesn't pass a calling
//  app's CallKit call to the Watch, so the relay sends the call to both,
//  each push with the same ring. The device that answers or declines
//  settles the ring at the relay, which tells the other to stop ringing:
//  the iPhone's ringing call cuts its link to the Watch, so the two can't
//  tell each other. A call answered on the Watch gets its session from the
//  iPhone through the relay too (HermesRingHandoff).
//

import CryptoKit
import Foundation
import Security

/// The ring a call push carries when the call rings on the Watch too.
struct HermesRing: Equatable {
    let id: String
    /// Settles the ring: only the call's two pushes hold it.
    let token: String
    /// Where to settle it, on the relay that sent the call.
    let url: URL

    /// The ring in a call push, outside any sealed envelope; nil when the
    /// call rings on this device alone.
    static func from(_ userInfo: [AnyHashable: Any]) -> HermesRing? {
        guard let ring = HermesRingPush.ring(in: userInfo),
              let id = ring["id"] as? String, HermesRingPush.isID(id),
              let token = ring["token"] as? String, HermesRingPush.isToken(token),
              let text = ring["url"] as? String, let url = URL(string: text),
              url.scheme == "https", url.path.hasSuffix("/v1/rings/\(id)/settled") else { return nil }
        return HermesRing(id: id, token: token, url: url)
    }
}

/// How a ring was settled.
enum HermesRingOutcome: String, Equatable {
    case answered
    case declined
}

/// The device that settled a ring.
enum HermesRingDevice: String, Equatable {
    case phone
    case watch
}

/// The relay's "stop ringing": the other device answered or declined.
struct HermesRingSettled: Equatable {
    let id: String
    let outcome: HermesRingOutcome
    let by: HermesRingDevice
    /// The Watch's sealed start, when it answered (relay 0.11+): the
    /// iPhone builds the Watch call's session from it (HermesRingHandoff).
    var start: String? = nil

    /// Nil for any other push, a call included.
    static func from(_ userInfo: [AnyHashable: Any]) -> HermesRingSettled? {
        guard let ring = HermesRingPush.ring(in: userInfo),
              let id = ring["id"] as? String, HermesRingPush.isID(id),
              let outcome = (ring["settled"] as? String).flatMap(HermesRingOutcome.init(rawValue:)),
              let by = (ring["by"] as? String).flatMap(HermesRingDevice.init(rawValue:)) else { return nil }
        let start = (ring["start"] as? String).flatMap { HermesRingHandoff.isSealed($0, maxChars: HermesRingHandoff.maxStartChars) ? $0 : nil }
        return HermesRingSettled(id: id, outcome: outcome, by: by, start: by == .watch && outcome == .answered ? start : nil)
    }
}

enum HermesRingPush {
    /// The `ring` beside `sent_at`: in `conduit`, or in `body.conduit`.
    static func ring(in userInfo: [AnyHashable: Any]) -> [String: Any]? {
        let direct = (userInfo["conduit"] as? [String: Any])?["ring"] as? [String: Any]
        let nested = ((userInfo["body"] as? [String: Any])?["conduit"] as? [String: Any])?["ring"] as? [String: Any]
        return direct ?? nested
    }

    /// The relay's `sent_at` (seconds since 1970), outside any sealed
    /// envelope.
    static func sentAt(_ userInfo: [AnyHashable: Any]) -> Date? {
        let direct = userInfo["conduit"] as? [String: Any]
        let nested = (userInfo["body"] as? [String: Any])?["conduit"] as? [String: Any]
        guard let seconds = (direct?["sent_at"] as? NSNumber) ?? (nested?["sent_at"] as? NSNumber) else { return nil }
        return Date(timeIntervalSince1970: seconds.doubleValue)
    }

    /// The call's title when the push carries it in the clear; nil from a
    /// sealed push, which only the iPhone can open.
    static func title(_ userInfo: [AnyHashable: Any]) -> String? {
        let call = ((userInfo["body"] as? [String: Any])?["conduit"] as? [String: Any])?["call"] as? [String: Any]
        let words = (call?["title"] as? String)?
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ") ?? ""
        return words.isEmpty ? nil : String(words.prefix(60))
    }

    static func isID(_ value: String) -> Bool { value.count == 22 && value.allSatisfy(isBase64URL) }
    static func isToken(_ value: String) -> Bool { value.count == 43 && value.allSatisfy(isBase64URL) }

    private static func isBase64URL(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
    }
}

/// What settling a ring came to.
enum HermesRingSettleResult: Equatable {
    /// This device settled it; the other stops ringing.
    case settled
    /// The other device got there first.
    case alreadySettled(HermesRingOutcome, by: HermesRingDevice)
    /// The relay forgot the ring (it expired, or the relay restarted) or
    /// couldn't be reached: the other device rings out.
    case failed
}

enum HermesRingSettler {
    /// `start`: the Watch's sealed start, with its answer (HermesRingHandoff).
    static func request(_ ring: HermesRing, by device: HermesRingDevice, outcome: HermesRingOutcome, start: String? = nil) -> URLRequest {
        var request = URLRequest(url: ring.url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = [
            "token": ring.token,
            "by": device.rawValue,
            "outcome": outcome.rawValue,
        ]
        if let start { body["start"] = start }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func result(status: Int, data: Data) -> HermesRingSettleResult {
        if (200..<300).contains(status) { return .settled }
        guard status == 409,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settled = body["settled"] as? [String: Any],
              let outcome = (settled["outcome"] as? String).flatMap(HermesRingOutcome.init(rawValue:)),
              let by = (settled["by"] as? String).flatMap(HermesRingDevice.init(rawValue:)) else { return .failed }
        return .alreadySettled(outcome, by: by)
    }

    static func settle(_ ring: HermesRing, by device: HermesRingDevice, outcome: HermesRingOutcome, start: String? = nil, session: URLSession = .shared) async -> HermesRingSettleResult {
        do {
            let (data, response) = try await session.data(for: request(ring, by: device, outcome: outcome, start: start))
            return result(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
        } catch {
            return .failed
        }
    }
}

/// A call from Hermes answered on the Watch: what its Watch call needs to
/// fetch its session from the relay (HermesRingHandoff).
struct HermesRingAnswer: Equatable {
    let ring: HermesRing
    /// The Watch call's id, picked as it answered: the start it sealed for
    /// the iPhone carries it.
    let callID: UInt32
    /// The Watch's handoff key (HermesRingHandoffKey).
    let key: Data
}

/// Starting a Watch call that answers a ring, through the relay
/// (designs/hermes-calls-watch.md, "Starting an answered call through the
/// relay"). The Watch app stays in the background under the system call
/// screen, where its WatchConnectivity link to the iPhone is down, so it
/// can't ask Conduit there for the call's session. Instead its settle
/// carries its start message, sealed, which the relay forwards in the
/// iPhone's stop push; the iPhone answers it as if it had come over the
/// link and stores the answer at the relay, sealed, for the Watch to fetch
/// with the ring's token.
///
/// The key is the Watch's: 32 random bytes in its Keychain, sent to the
/// iPhone with its PushKit token over WatchConnectivity, so the relay never
/// has it. HKDF-SHA256 derives one key a direction; each message is
/// ChaCha20-Poly1305 bound to the ring and direction, as nonce, ciphertext
/// and tag in one base64url string.
enum HermesRingHandoff {
    enum Direction: String {
        /// The Watch's start, in its settle.
        case start
        /// The iPhone's answer, stored at the relay.
        case session
    }

    enum Failure: Error, Equatable {
        case malformed
        case didNotVerify
        case tooLarge
    }

    /// What one fetch at the relay came to.
    enum Fetch: Equatable {
        case sealed(String)
        /// Not stored yet: ask again.
        case notYet
        /// The relay has no such ring, or no session route (older than 0.11),
        /// or the ring isn't the Watch's to fetch: asking again won't help.
        case gone
        /// Busy, or failing for now.
        case retry
    }

    /// How fetching the session ended.
    enum Outcome: Equatable {
        case message(WatchVoiceWire.Message)
        /// Why not, for the call log.
        case unavailable(String)
    }

    static let keyBytes = 32
    /// As the relay takes them.
    static let maxStartChars = 1024
    static let maxSessionChars = 96 * 1024
    /// The longest one fetch waits at the relay, in seconds.
    static let fetchWait = 20
    static let salt = "conduit-ring-handoff-v1"

    static func key(root: Data, _ direction: Direction) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: root),
            salt: Data(salt.utf8),
            info: Data("conduit-ring-handoff-v1 \(direction.rawValue)".utf8),
            outputByteCount: 32
        )
    }

    static func associatedData(_ direction: Direction, ringID: String) -> Data {
        Data(["conduit-ring-handoff/1", direction.rawValue, "ring=\(ringID)"].joined(separator: "\n").utf8)
    }

    /// A fixed nonce is for tests only.
    static func seal(_ plaintext: Data, root: Data, direction: Direction, ringID: String, nonce: ChaChaPoly.Nonce = ChaChaPoly.Nonce()) throws -> String {
        guard root.count == keyBytes else { throw Failure.malformed }
        let box = try ChaChaPoly.seal(plaintext, using: key(root: root, direction), nonce: nonce, authenticating: associatedData(direction, ringID: ringID))
        let sealed = WatchToolSeal.base64URL(box.combined)
        guard sealed.count <= (direction == .start ? maxStartChars : maxSessionChars) else { throw Failure.tooLarge }
        return sealed
    }

    static func open(_ sealed: String, root: Data, direction: Direction, ringID: String) throws -> Data {
        guard root.count == keyBytes, let combined = WatchToolSeal.data(base64URL: sealed),
              let box = try? ChaChaPoly.SealedBox(combined: combined) else { throw Failure.malformed }
        do {
            return try ChaChaPoly.open(box, using: key(root: root, direction), authenticating: associatedData(direction, ringID: ringID))
        } catch {
            throw Failure.didNotVerify
        }
    }

    static func isSealed(_ value: String, maxChars: Int) -> Bool {
        !value.isEmpty && value.count <= maxChars && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// The Watch's start message, sealed for the iPhone; nil if it can't be.
    static func sealStart(_ message: WatchVoiceWire.Message, answer: HermesRingAnswer) -> String? {
        guard let data = try? JSONEncoder().encode(message) else { return nil }
        return try? seal(data, root: answer.key, direction: .start, ringID: answer.ring.id)
    }

    /// The Watch's start in a stop push, opened: only a call start that
    /// names this ring. Nil if it doesn't verify.
    static func openStart(_ sealed: String, key: Data, ringID: String) -> WatchVoiceWire.Message? {
        guard let data = try? open(sealed, root: key, direction: .start, ringID: ringID),
              let message = try? JSONDecoder().decode(WatchVoiceWire.Message.self, from: data) else { return nil }
        switch message {
        case .directStart(_, _, let ring) where ring == ringID: return message
        case .grokStart(_, _, let ring) where ring == ringID: return message
        case .bridgeStart(_, _, _, let ring) where ring == ringID: return message
        default: return nil
        }
    }

    /// Where the ring's session is stored and fetched: beside its settle URL.
    static func sessionURL(_ ring: HermesRing) -> URL {
        ring.url.deletingLastPathComponent().appendingPathComponent("session")
    }

    static func storeRequest(_ ring: HermesRing, sealed: String) -> URLRequest {
        var request = URLRequest(url: sessionURL(ring), timeoutInterval: 15)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": ring.token, "sealed": sealed])
        return request
    }

    static func fetchRequest(_ ring: HermesRing, wait: Int) -> URLRequest {
        var components = URLComponents(url: sessionURL(ring), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "wait", value: String(max(0, min(wait, fetchWait))))]
        var request = URLRequest(url: components?.url ?? sessionURL(ring), timeoutInterval: TimeInterval(max(0, min(wait, fetchWait)) + 10))
        request.setValue("Bearer \(ring.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func fetchResult(status: Int, data: Data) -> Fetch {
        switch status {
        case 200:
            guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sealed = body["sealed"] as? String, isSealed(sealed, maxChars: maxSessionChars) else { return .gone }
            return .sealed(sealed)
        case 204: return .notYet
        case 400, 401, 404, 405, 409: return .gone
        default: return .retry
        }
    }

    /// The iPhone stores its answer: the relay's status, 0 when it couldn't
    /// be reached.
    static func store(_ ring: HermesRing, sealed: String, session: URLSession = .shared) async -> Int {
        do {
            let (_, response) = try await session.data(for: storeRequest(ring, sealed: sealed))
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            return 0
        }
    }

    /// The iPhone's answer to the Watch's start, fetched until `deadline`.
    static func fetchSession(
        _ answer: HermesRingAnswer,
        until deadline: Date,
        now: () -> Date = { Date() },
        send: (URLRequest) async throws -> (Data, Int) = HermesRingHandoff.send
    ) async -> Outcome {
        while !Task.isCancelled {
            // Each fetch waits at least a second at the relay.
            let left = deadline.timeIntervalSince(now())
            guard left >= 2 else { return .unavailable("timedOut") }
            let fetched: Fetch
            do {
                let (data, status) = try await send(fetchRequest(answer.ring, wait: Int(left) - 1))
                fetched = fetchResult(status: status, data: data)
            } catch {
                fetched = .retry
            }
            switch fetched {
            case .sealed(let sealed):
                guard let data = try? open(sealed, root: answer.key, direction: .session, ringID: answer.ring.id),
                      let message = try? JSONDecoder().decode(WatchVoiceWire.Message.self, from: data) else { return .unavailable("unreadable") }
                return .message(message)
            case .notYet:
                continue
            case .gone:
                return .unavailable("gone")
            case .retry:
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        return .unavailable("cancelled")
    }

    static func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// The Watch's handoff key, in the Keychain of the device holding it: the
/// Watch's own, or on the iPhone the one the Watch sent.
enum HermesRingHandoffKey {
    private static let service = "com.milim.relay.hermesRingHandoff"
    private static let account = "watch"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func load() -> Data? { read().key }

    /// Keeps `key` in place of any other.
    @discardableResult
    static func save(_ key: Data) -> Bool {
        guard key.count == HermesRingHandoff.keyBytes else { return false }
        let (current, status) = read()
        if current == key { return true }
        return write(key, exists: status == errSecSuccess)
    }

    /// The Watch's own key, made the first time. Nil while the Keychain
    /// can't be read (before the first unlock).
    static func loadOrCreate() -> Data? {
        let (current, status) = read()
        if let current { return current }
        guard status == errSecSuccess || status == errSecItemNotFound else { return nil }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return write(key, exists: status == errSecSuccess) ? key : nil
    }

    /// The stored key, nil when there's none or it isn't one.
    private static func read() -> (key: Data?, status: OSStatus) {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, data.count == HermesRingHandoff.keyBytes else { return (nil, status) }
        return (data, status)
    }

    private static func write(_ key: Data, exists: Bool) -> Bool {
        if exists {
            return SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: key] as CFDictionary) == errSecSuccess
        }
        var query = baseQuery
        query[kSecValueData as String] = key
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
}
