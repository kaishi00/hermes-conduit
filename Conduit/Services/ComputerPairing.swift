//
//  ComputerPairing.swift
//  Conduit
//
//  Pair a Computer (Settings > Connection): the Conduit desktop app on a
//  Windows PC or Mac shows a QR code, the phone scans it and sends that
//  computer its Hermes sign-ins, sealed to the computer's key, through a
//  one-time inbox on the rooms mailbox. Both screens then show the same four
//  words, and the computer signs in once the person says they match there.
//
//  The QR code: conduit://pair?v=1&m=<mailbox>&i=<inbox>&t=<send token>&k=<X25519 key>&e=<expiry, s>
//  The seal (the desktop app's src/main/pairCrypto.ts opens it; both must agree):
//    shared = X25519(ephemeral private, computer's key)
//    key    = HKDF-SHA256(shared, salt "conduit-pair-v1",
//                         info "conduit-pair-v1 phone-to-computer" ‖ epk ‖ computer's key, 32 bytes)
//    box    = AES-256-GCM(key, random 12-byte nonce, payload, aad "conduit-pair/1\n" ‖ inbox)
//    envelope = {"v":1,"epk":b64url,"n":b64url,"c":b64url(ciphertext ‖ tag)}
//  The words: the first 44 bits of SHA-256("conduit-pair-words-v1\n" ‖ computer's key ‖ epk),
//  11 bits a BIP39 word.
//  The payload: {"v":1,"hosts":[{"url","method":"password"|"token","username","password","token","name"}]}
//

import CryptoKit
import Foundation

/// A computer's pairing code, read from its QR code. The send token is a
/// secret: it never shows in a description or a log.
struct ComputerPairingLink: Identifiable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    @EqualityIgnored var id = UUID()
    let mailbox: URL
    let inbox: String
    let token: String
    /// The computer's X25519 public key, 32 bytes.
    let key: Data
    let expires: Date

    static let host = "pair"
    static let prefix = "conduit://pair?"

    init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 2_048, trimmed.prefix(Self.prefix.count).lowercased() == Self.prefix,
              let components = URLComponents(string: Self.prefix + trimmed.dropFirst(Self.prefix.count)) else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { query[item.name] = value }
        }
        guard query["v"] == "1",
              let mailboxText = query["m"], let mailbox = URL(string: mailboxText),
              let scheme = mailbox.scheme?.lowercased(), scheme == "https" || scheme == "http", mailbox.host != nil,
              let inbox = query["i"], inbox.count == 43, inbox.unicodeScalars.allSatisfy(Self.base64URLScalars.contains),
              let token = query["t"], !token.isEmpty, token.unicodeScalars.allSatisfy(Self.base64URLScalars.contains),
              let keyText = query["k"], let key = Data(base64URL: keyText), key.count == 32,
              let expiresText = query["e"], let seconds = TimeInterval(expiresText) else { return nil }
        self.mailbox = mailbox
        self.inbox = inbox
        self.token = token
        self.key = key
        self.expires = Date(timeIntervalSince1970: seconds)
    }

    init?(url: URL) {
        self.init(url.absoluteString)
    }

    func hasExpired(now: Date = Date()) -> Bool { now >= expires }

    private static let base64URLScalars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    var description: String { "ComputerPairingLink(\(mailbox.host ?? "?"))" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["mailbox": mailbox.host ?? "?"]) }
}

enum ComputerPairing {
    private static let salt = Data("conduit-pair-v1".utf8)
    private static let info = Data("conduit-pair-v1 phone-to-computer".utf8)
    private static let aadPrefix = "conduit-pair/1\n"
    private static let wordsLabel = Data("conduit-pair-words-v1\n".utf8)

    /// One sign-in the computer is sent. Only what the desktop app reads.
    struct Host: Encodable, Equatable {
        enum Method: String, Encodable { case password, token }
        let url: String
        let method: Method
        var username: String?
        var password: String?
        var token: String?
        var name: String?
    }

    private struct Payload: Encodable {
        let v = 1
        let hosts: [Host]
    }

    static func payload(_ hosts: [Host]) throws -> Data {
        try JSONEncoder().encode(Payload(hosts: hosts))
    }

    struct Sealed {
        let envelope: Data
        let ephemeralPublic: Data
    }

    /// Seals `plaintext` to the computer's key for its inbox.
    static func seal(_ plaintext: Data, to computerKey: Data, inbox: String) throws -> Sealed {
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: computerKey)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let epk = ephemeral.publicKey.rawRepresentation
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info + epk + computerKey, outputByteCount: 32)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(), authenticating: Data((aadPrefix + inbox).utf8))
        let body: [String: Any] = [
            "v": 1,
            "epk": epk.base64URLEncoded(),
            "n": Data(box.nonce).base64URLEncoded(),
            "c": (box.ciphertext + box.tag).base64URLEncoded(),
        ]
        let envelope = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return Sealed(envelope: envelope, ephemeralPublic: epk)
    }

    /// The four words both screens show.
    static func words(computerKey: Data, ephemeralPublic: Data) -> [String] {
        let digest = Array(SHA256.hash(data: wordsLabel + computerKey + ephemeralPublic))
        var bits: UInt64 = 0
        for byte in digest.prefix(6) { bits = bits << 8 | UInt64(byte) }
        bits >>= 4 // the first 44 bits
        return [33, 22, 11, 0].map { BIP39Words.english[Int((bits >> UInt64($0)) & 0x7FF)] }
    }

    enum SendError: Error, Equatable {
        /// The code ran out, or the computer made a new one.
        case codeGone
        case rateLimited
        case unreachable
    }

    /// Leaves the sealed envelope in the computer's inbox.
    static func send(_ envelope: Data, link: ComputerPairingLink, session: URLSession = .shared) async throws {
        var request = URLRequest(url: link.mailbox.appendingPathComponent("v1/inboxes/\(link.inbox)/envelopes"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(link.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = envelope
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw SendError.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return
        case 401, 403, 404, 410: throw SendError.codeGone
        case 429: throw SendError.rateLimited
        default: throw SendError.unreachable
        }
    }
}

fileprivate extension Data {
    init?(base64URL text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: base64)
    }

    func base64URLEncoded() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
