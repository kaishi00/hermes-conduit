//
//  ComputerSignIn.swift
//  Conduit
//
//  Conduit for desktop signing this phone in (docs/FEATURE_MAP.md, Each app
//  points to the other): the way back of Pair a Computer. The computer
//  (Settings › Conduit on iPhone › Sign in your iPhone) shows
//  conduit://signin?v=1&m&i&t&k&e, the same fields as a pairing code. This
//  phone makes an inbox of its own on that mailbox and leaves the computer a
//  request sealed to its key (ComputerPairing.seal):
//    {"v":1,"want":"signins","reply":{"inbox","token","key"}}
//  Both screens show the same four words (ComputerPairing.words). Once the
//  person says they match there, the computer seals its sign-ins to this
//  phone's key with info "conduit-pair-v1 computer-to-phone" (the desktop
//  app's src/main/phoneSignIn.ts and pairCrypto.ts), aad
//  "conduit-pair/1\n" ‖ this phone's inbox, and leaves them in that inbox:
//    {"v":1,"hosts":[{"url","method","username","password","token","name","headers"}]}
//  This phone lists them, and each signs in through the sign-in code sheet,
//  which asks first. The inbox is deleted after.
//
//  The mailbox's owner signature (notifier mailbox/README.md, Protocol v1):
//    Authorization: Mailbox-Ed25519 ts=<s>,nonce=<b64url>,sig=<b64url>
//    over "mailbox-v1\n" METHOD "\n" host "\n" path?query "\n" ts "\n" nonce "\n" b64url(sha256(body))
//

import CryptoKit
import Foundation

enum ComputerSignIn {
    private static let info = Data("conduit-pair-v1 computer-to-phone".utf8)
    private static let sender = "computer"
    private static let pollWait = 25

    /// This phone's one-time inbox for the computer's answer. Its keys never
    /// leave the phone.
    struct Inbox {
        let mailbox: URL
        let signing = Curve25519.Signing.PrivateKey()
        let sealing = Curve25519.KeyAgreement.PrivateKey()
        let token: String

        init(mailbox: URL) {
            self.mailbox = mailbox
            token = ComputerPairing.base64URL(ComputerSignIn.randomBytes(32))
        }

        var id: String { ComputerSignIn.inboxID(signing.publicKey.rawRepresentation) }
    }

    /// One sign-in the computer sent.
    struct Host: Decodable, Identifiable, Equatable {
        let url: String
        let method: String
        var username: String?
        var password: String?
        var token: String?
        var name: String?
        var headers: [String: String]?

        var id: String { url }

        var label: String {
            let given = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return given.isEmpty ? (URL(string: url)?.host ?? url) : given
        }

        /// The sign-in code sheet's link: the address, the password sign-in,
        /// Hermes' session token (filled into its form) and the Cloudflare
        /// Access service token when it has them. Anything else is signed in
        /// on the sign-in step.
        var connectLink: DashboardConnectLink {
            let password = method == "password" ? self.password : nil
            let sessionToken = method == "token" ? token.flatMap { $0.isEmpty ? nil : $0 } : nil
            let lowered = (headers ?? [:]).reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
            var cloudflare: LoginCloudflareState?
            if let id = lowered["cf-access-client-id"], let secret = lowered["cf-access-client-secret"], !id.isEmpty, !secret.isEmpty {
                cloudflare = LoginCloudflareState(isEnabled: true, clientID: id, clientSecret: secret)
            }
            return DashboardConnectLink(address: url, username: password == nil ? nil : username, password: password, cloudflare: cloudflare, sessionToken: sessionToken)
        }
    }

    enum Failure: Error, Equatable {
        case codeGone
        case rateLimited
        case unreachable
        case lost
    }

    // MARK: The protocol

    /// The system generator is a cryptographic one on Apple platforms.
    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    static func inboxID(_ signingPublicKey: Data) -> String {
        ComputerPairing.base64URL(Data(SHA256.hash(data: signingPublicKey)))
    }

    /// What an owner signs.
    static func signedMessage(method: String, host: String, pathAndQuery: String, timestamp: Int, nonce: String, body: Data) -> Data {
        let parts = ["mailbox-v1", method.uppercased(), host, pathAndQuery, String(timestamp), nonce, ComputerPairing.base64URL(Data(SHA256.hash(data: body)))]
        return Data(parts.joined(separator: "\n").utf8)
    }

    static func authorization(_ key: Curve25519.Signing.PrivateKey, method: String, host: String, pathAndQuery: String, body: Data, now: Date = Date()) throws -> String {
        let timestamp = Int(now.timeIntervalSince1970)
        let nonce = ComputerPairing.base64URL(randomBytes(18))
        let signature = try key.signature(for: signedMessage(method: method, host: host, pathAndQuery: pathAndQuery, timestamp: timestamp, nonce: nonce, body: body))
        return "Mailbox-Ed25519 ts=\(timestamp),nonce=\(nonce),sig=\(ComputerPairing.base64URL(signature))"
    }

    /// The request the computer opens: where to answer, and the key to seal to.
    static func request(_ inbox: Inbox) throws -> Data {
        let body: [String: Any] = [
            "v": 1,
            "want": "signins",
            "reply": [
                "inbox": inbox.id,
                "token": inbox.token,
                "key": ComputerPairing.base64URL(inbox.sealing.publicKey.rawRepresentation),
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Opens the computer's envelope, or throws when it isn't for this key and inbox.
    static func open(_ envelope: Data, with key: Curve25519.KeyAgreement.PrivateKey, inbox: String) throws -> Data {
        guard let body = try JSONSerialization.jsonObject(with: envelope) as? [String: Any],
              body["v"] as? Int == 1,
              let epkText = body["epk"] as? String, let epk = ComputerPairing.data(base64URL: epkText), epk.count == 32,
              let nonceText = body["n"] as? String, let nonce = ComputerPairing.data(base64URL: nonceText), nonce.count == 12,
              let boxText = body["c"] as? String, let box = ComputerPairing.data(base64URL: boxText), box.count >= 16 else {
            throw Failure.lost
        }
        let shared = try key.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: epk))
        let recipient = key.publicKey.rawRepresentation
        let symmetric = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ComputerPairing.salt, sharedInfo: info + epk + recipient, outputByteCount: 32)
        let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: box.dropLast(16), tag: box.suffix(16))
        return try AES.GCM.open(sealed, using: symmetric, authenticating: Data((ComputerPairing.aadPrefix + inbox).utf8))
    }

    /// The sign-ins in an opened answer; empty when it isn't one.
    static func hosts(from plaintext: Data) -> [Host] {
        struct Payload: Decodable {
            let v: Int
            let hosts: [Host]
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: plaintext), payload.v == 1 else { return [] }
        return payload.hosts.filter { host in
            guard let scheme = URL(string: host.url)?.scheme?.lowercased() else { return false }
            return scheme == "https" || scheme == "http"
        }
    }

    // MARK: The mailbox

    /// Makes this phone's inbox, leaves the request in the computer's, and
    /// answers the four words both screens show.
    static func begin(_ inbox: Inbox, link: ComputerPairingLink, session: URLSession = .shared) async throws -> [String] {
        let key = ComputerPairing.base64URL(inbox.signing.publicKey.rawRepresentation)
        _ = try await owner("POST", "/v1/inboxes", body: try JSONSerialization.data(withJSONObject: ["key": key]), inbox: inbox, session: session)
        let tokenHash = ComputerPairing.base64URL(Data(SHA256.hash(data: Data(inbox.token.utf8))))
        _ = try await owner("PUT", "/v1/inboxes/\(inbox.id)/senders/\(sender)", body: try JSONSerialization.data(withJSONObject: ["token_sha256": tokenHash]), inbox: inbox, session: session)
        let sealed = try ComputerPairing.seal(request(inbox), to: link.key, inbox: link.inbox)
        do {
            try await ComputerPairing.send(sealed.envelope, link: link, session: session)
        } catch let error as ComputerPairing.SendError {
            switch error {
            case .codeGone: throw Failure.codeGone
            case .rateLimited: throw Failure.rateLimited
            case .unreachable: throw Failure.unreachable
            }
        }
        return ComputerPairing.words(computerKey: link.key, ephemeralPublic: sealed.ephemeralPublic)
    }

    /// Waits for the computer's sign-ins, until the task is cancelled.
    static func waitForHosts(_ inbox: Inbox, session: URLSession = .shared) async throws -> [Host] {
        var after = 0
        var failures = 0
        while !Task.isCancelled {
            do {
                let data = try await owner("GET", "/v1/inboxes/\(inbox.id)/envelopes?after=\(after)&wait=\(pollWait)", body: nil, inbox: inbox, session: session)
                failures = 0
                let page = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                for envelope in page["envelopes"] as? [[String: Any]] ?? [] {
                    if let seq = envelope["seq"] as? Int { after = max(after, seq) }
                    guard let text = envelope["body"] as? String, let body = Data(base64Encoded: text),
                          let plaintext = try? open(body, with: inbox.sealing, inbox: inbox.id) else { continue }
                    let received = hosts(from: plaintext)
                    if !received.isEmpty { return received }
                }
                if let next = page["next"] as? Int { after = max(after, next) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures += 1
                // Five in a row: a mailbox that kept saying "too many" says so.
                if failures >= 5 { throw (error as? Failure) == .rateLimited ? Failure.rateLimited : Failure.lost }
                try await Task.sleep(nanoseconds: UInt64(failures) * 2_000_000_000)
            }
        }
        throw CancellationError()
    }

    /// Deletes the inbox and whatever is left in it.
    static func finish(_ inbox: Inbox, session: URLSession = .shared) async {
        _ = try? await owner("DELETE", "/v1/inboxes/\(inbox.id)", body: nil, inbox: inbox, session: session)
    }

    private static func owner(_ method: String, _ pathAndQuery: String, body: Data?, inbox: Inbox, session: URLSession) async throws -> Data {
        guard let url = URL(string: pathAndQuery, relativeTo: inbox.mailbox)?.absoluteURL,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let name = components.host?.lowercased() else { throw Failure.unreachable }
        // As a URL parser gives the host: a port only when it isn't the scheme's.
        let host = components.port.map { "\(name):\($0)" } ?? name
        let bytes = body ?? Data()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = TimeInterval(pollWait + 10)
        request.setValue(try authorization(inbox.signing, method: method, host: host, pathAndQuery: pathAndQuery, body: bytes), forHTTPHeaderField: "Authorization")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bytes
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw Failure.unreachable
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: return data
        case 429: throw Failure.rateLimited
        default: throw Failure.unreachable
        }
    }
}
