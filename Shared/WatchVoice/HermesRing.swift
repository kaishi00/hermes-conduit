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

/// Who a call from Hermes says is calling, the only text CallKit shows on
/// the iPhone and the Watch alike: the calling profile by the name Conduit
/// gives it, with the job's title when the call carries one. The main
/// ("default") profile goes by the name the user gave it in Conduit, never
/// Hermes' own "Default", else by its bot's name; "Hermes" when nothing
/// names the caller. Another bot goes by its name in Hermes, else its
/// capitalized profile id.
enum HermesCallerName {
    static let fallback = "Hermes"
    /// The address a call from a profile rings from, on the iPhone and the
    /// Watch: `hermes+<profile>@hermesconduit.app`, one per bot. A Focus
    /// lets a call through only from a caller it matches to a contact in
    /// its allowed people, so a user who saves a bot's contact (Settings >
    /// Calls from Hermes) can let that bot ring through one Focus and not
    /// others, and the call screen shows the contact's name, which is the
    /// bot's. A call that names no profile (a sealed push on the Watch)
    /// rings from `hermes@hermesconduit.app`, which no contact holds.
    /// Nothing is ever sent to these addresses (#1606).
    static func contactAddress(profile: String?) -> String {
        let id = (profile ?? "").lowercased().unicodeScalars.filter { allowedAddressCharacters.contains($0) }
        guard !id.isEmpty else { return "hermes@\(addressDomain)" }
        return "hermes+\(String(id).prefix(64))@\(addressDomain)"
    }

    private static let addressDomain = "hermesconduit.app"
    private static let allowedAddressCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
    static let maximumNameCharacters = 40

    /// `mainName`: the name the user gave the main profile on the call's
    /// dashboard, nil when there is none. `profileName`: the bot's name in
    /// Hermes as the Bots list shows it (the push's `profile_name`), nil
    /// when Hermes gave it none or the push doesn't say.
    static func name(profile: String?, mainName: String?, profileName: String? = nil) -> String {
        let id = oneLine(profile)
        guard !id.isEmpty else { return fallback }
        // A name that is only the profile id says nothing more than the id.
        let given = oneLine(profileName)
        let named = given.lowercased() == id.lowercased() ? "" : given
        guard id.lowercased() != "default" else {
            // The name set in Conduit wins; one never set reads "Hermes"
            // (as does one set to "Hermes"), where the bot's own name says more.
            let main = oneLine(mainName)
            let shown = main.isEmpty || main == fallback ? (named.isEmpty ? fallback : named) : main
            return String(shown.prefix(maximumNameCharacters))
        }
        // The bot's name, else the profile as Conduit shows one with no
        // name (AppState.profileDisplayName), on one line: CallKit shows a
        // caller name on one.
        let shown = named.isEmpty ? String(id.prefix(1)).uppercased() + String(id.dropFirst()) : named
        return String(shown.prefix(maximumNameCharacters))
    }

    /// "Name · Title", or the name alone.
    static func line(name: String, title: String?) -> String {
        guard let title, !title.isEmpty else { return name }
        return name + " · " + title
    }

    /// The main profile's name per dashboard (UUID string), as the iPhone
    /// last shared them with the Watch; `activeDashboardID` stands in for a
    /// push that names no dashboard.
    static func mainName(dashboardID: UUID?, in names: [String: String]?, activeDashboardID: String? = nil) -> String? {
        guard let key = dashboardID?.uuidString ?? activeDashboardID.flatMap(UUID.init(uuidString:))?.uuidString else { return nil }
        return names?[key]
    }

    private static func oneLine(_ text: String?) -> String {
        (text ?? "").split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
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

    /// The calling Hermes profile and its dashboard, when the push carries
    /// them in the clear; nil from a sealed push.
    static func caller(_ userInfo: [AnyHashable: Any]) -> (profile: String?, dashboardID: UUID?) {
        let conduit = (userInfo["body"] as? [String: Any])?["conduit"] as? [String: Any]
        let dashboard = (conduit?["dashboard_id"] as? String).flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return (conduit?["profile"] as? String, dashboard)
    }

    /// The calling bot's name (`profile_name`), when the push carries it in
    /// the clear; nil from a sealed push.
    static func profileName(_ userInfo: [AnyHashable: Any]) -> String? {
        ((userInfo["body"] as? [String: Any])?["conduit"] as? [String: Any])?["profile_name"] as? String
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
    /// Sent, but no answer came back (it timed out, or the connection
    /// dropped): the relay may have settled it, and forwarded the Watch's
    /// start.
    case unconfirmed

    /// Whether the relay may hold a handoff for the Watch's start: settled
    /// here, or maybe. The Watch's fetch races its link to the iPhone, so
    /// one that finds nothing costs only the wait.
    var mayFetchHandoff: Bool { self == .settled || self == .unconfirmed }
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
            return result(for: error)
        }
    }

    /// A settle that got no answer: failed when it never reached the relay
    /// (no network, no connection, TLS refused), otherwise unconfirmed.
    static func result(for error: Error) -> HermesRingSettleResult {
        guard let code = (error as? URLError)?.code else { return .failed }
        return neverSent.contains(code) ? .failed : .unconfirmed
    }

    private static let neverSent: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .badURL, .unsupportedURL, .cancelled, .appTransportSecurityRequiresSecureConnection,
        .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
        .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
        .clientCertificateRequired, .internationalRoamingOff, .dataNotAllowed, .callIsActive,
    ]
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
        case .directStart(_, _, let ring, _) where ring == ringID: return message
        case .grokStart(_, _, let ring) where ring == ringID: return message
        case .bridgeStart(_, _, _, let ring) where ring == ringID: return message
        case .localLiveStart(_, _, let ring) where ring == ringID: return message
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

extension WatchVoiceWire.Message {
    /// The call id a Watch call's start names; nil for any other message.
    var watchCallID: UInt32? {
        switch self {
        case .directStart(let id, _, _, _), .grokStart(let id, _, _), .localLiveStart(let id, _, _): return id
        case .bridgeStart(let id, _, _, _): return id
        default: return nil
        }
    }

    /// The call from Hermes a Watch call's start answers.
    var watchCallRing: String? {
        switch self {
        case .directStart(_, _, let ring, _), .grokStart(_, _, let ring), .localLiveStart(_, _, let ring): return ring
        case .bridgeStart(_, _, _, let ring): return ring
        default: return nil
        }
    }
}

/// A call from Hermes answered on the Watch while the iPhone has a headset
/// on (AirPods, #1204): the iPhone answers its own ring, so the voice plays
/// on the headset as a phone call's would, and the Watch's call screen keeps
/// Mute and End. The iPhone's call keeps their link down, so the two share
/// them through the relay (0.17+, `ring-controls`): each posts its change to
/// the ring's control and long-polls it for the other's. Only the two flags
/// go through; the ring's token guards them. A relay restart drops the
/// ring: every write may adopt it back (`adopt`), and a device whose read
/// finds it gone writes its state again and reads on.
enum HermesRingControl {
    struct State: Equatable {
        /// The relay's count of changes, which a read waits past.
        let seq: Int
        let muted: Bool
        let ended: Bool
    }

    enum Read: Equatable {
        case state(State)
        /// Nothing new within the wait: ask again.
        case notYet
        /// No such ring, or no control route (a relay older than 0.17):
        /// asking again won't help.
        case gone
        /// Busy, or failing for now.
        case retry
    }

    /// The longest one read waits at the relay, in seconds.
    static let readWait = 20

    /// Beside the ring's settle URL.
    static func url(_ ring: HermesRing) -> URL {
        ring.url.deletingLastPathComponent().appendingPathComponent("control")
    }

    /// `muted` nil leaves the mute as it is; an end is only ever set.
    static func setRequest(_ ring: HermesRing, by device: HermesRingDevice, muted: Bool? = nil, ended: Bool = false) -> URLRequest {
        var request = URLRequest(url: url(ring), timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["token": ring.token, "by": device.rawValue, "adopt": true]
        if let muted { body["muted"] = muted }
        if ended { body["ended"] = true }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func readRequest(_ ring: HermesRing, after seq: Int, wait: Int = readWait) -> URLRequest {
        let wait = max(0, min(wait, readWait))
        var components = URLComponents(url: url(ring), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "after", value: String(seq)), URLQueryItem(name: "wait", value: String(wait))]
        var request = URLRequest(url: components?.url ?? url(ring), timeoutInterval: TimeInterval(wait + 10))
        request.setValue("Bearer \(ring.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func state(_ data: Data) -> State? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let seq = body["seq"] as? Int, let muted = body["muted"] as? Bool, let ended = body["ended"] as? Bool else { return nil }
        return State(seq: seq, muted: muted, ended: ended)
    }

    static func readResult(status: Int, data: Data) -> Read {
        switch status {
        // One it can't read is asked again, never taken for a lost ring.
        case 200: return state(data).map(Read.state) ?? .retry
        case 204: return .notYet
        case 400, 401, 404, 405, 409: return .gone
        default: return .retry
        }
    }

    /// Posts a change: the control after it, nil when the relay refused it
    /// or couldn't be reached in `attempts` tries (2 s apart: a restarting
    /// relay is back within seconds).
    static func set(
        _ ring: HermesRing,
        by device: HermesRingDevice,
        muted: Bool? = nil,
        ended: Bool = false,
        attempts: Int = 1,
        retryDelay: UInt64 = 2_000_000_000,
        send: (URLRequest) async throws -> (Data, Int) = HermesRingHandoff.send
    ) async -> State? {
        for attempt in 1...max(1, attempts) {
            let answer = try? await send(setRequest(ring, by: device, muted: muted, ended: ended))
            // A 200 it can't read is tried again like a lost one.
            if let answer, answer.1 == 200, let state = state(answer.0) { return state }
            // Refused: trying again won't help.
            if let status = answer?.1, (400..<500).contains(status), status != 429 { return nil }
            guard attempt < attempts, !Task.isCancelled else { break }
            try? await Task.sleep(nanoseconds: retryDelay)
        }
        return nil
    }

    /// The control as it stands, without waiting: `.state` (seq 0 and
    /// unmuted when no one has written it yet), `.gone` when the relay has
    /// no such ring or no control route, `.retry` when it couldn't be read
    /// in `attempts` tries.
    static func current(
        _ ring: HermesRing,
        attempts: Int = 3,
        retryDelay: UInt64 = 1_000_000_000,
        send: (URLRequest) async throws -> (Data, Int) = HermesRingHandoff.send
    ) async -> Read {
        for attempt in 1...max(1, attempts) {
            let answer = try? await send(readRequest(ring, after: 0, wait: 0))
            switch answer.map({ readResult(status: $0.1, data: $0.0) }) ?? .retry {
            case .state(let state): return .state(state)
            case .notYet: return .state(State(seq: 0, muted: false, ended: false))
            case .gone: return .gone
            case .retry:
                guard attempt < attempts, !Task.isCancelled else { return .retry }
                try? await Task.sleep(nanoseconds: retryDelay)
            }
        }
        return .retry
    }

    /// Reads the control past `seq` until it ends, the ring goes, or the
    /// task is cancelled, handing each change to `changed`. A ring the relay
    /// lost (a restart) is written again with `rewrite`, this device's state,
    /// and read from its start: once each time it's lost, and the reads
    /// stop when it can't be written.
    static func follow(
        _ ring: HermesRing,
        after seq: Int,
        retryDelay: UInt64 = 2_000_000_000,
        send: (URLRequest) async throws -> (Data, Int) = HermesRingHandoff.send,
        rewrite: @MainActor () async -> Bool,
        changed: @MainActor (State) async -> Void
    ) async {
        var seen = seq
        var rewritten = false
        let clock = ContinuousClock()
        while !Task.isCancelled {
            let read: Read
            let asked = clock.now
            do {
                let (data, status) = try await send(readRequest(ring, after: seen))
                read = readResult(status: status, data: data)
            } catch {
                read = .retry
            }
            // Nothing new, at once: something on the way doesn't wait, so
            // reads pause rather than spin.
            let early = clock.now - asked < .seconds(1)
            switch read {
            case .state(let state):
                rewritten = false
                guard state.seq > seen else {
                    if early { try? await Task.sleep(nanoseconds: retryDelay) }
                    continue
                }
                seen = state.seq
                await changed(state)
                if state.ended { return }
            case .notYet:
                if early { try? await Task.sleep(nanoseconds: retryDelay) }
            case .gone:
                guard !rewritten, await rewrite() else { return }
                rewritten = true
                seen = 0
            case .retry:
                try? await Task.sleep(nanoseconds: retryDelay)
            }
        }
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

#if canImport(CallKit)
import CallKit

extension HermesCallerName {
    /// Who a call from this profile rings from in CallKit, on the iPhone
    /// and the Watch: the address its bot's contact holds (#1606).
    static func callHandle(profile: String?) -> CXHandle {
        CXHandle(type: .emailAddress, value: contactAddress(profile: profile))
    }

    /// The handle types both CallKit providers take.
    static let handleTypes: Set<CXHandle.HandleType> = [.emailAddress]
}
#endif
