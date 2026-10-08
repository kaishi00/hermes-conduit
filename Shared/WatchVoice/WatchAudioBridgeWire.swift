//
//  WatchAudioBridgeWire.swift
//  Conduit and the Conduit Watch app
//
//  A Watch call to GPT-Live through the Hermes host's audio bridge
//  (designs/apple-watch-gpt-live.md). GPT-Live on a ChatGPT subscription
//  speaks WebRTC only, which watchOS doesn't have, so the conduit_push
//  plugin holds the call and the Watch streams to it over one WebSocket
//  through the push relay: /v1/watch-audio/{grant}/watch, with the
//  grant's relay key as the bearer.
//
//  Each connection opens with a hello in clear, [4][stream id 16][version],
//  then everything is sealed: [type][counter 8 BE][ChaCha20-Poly1305 ct],
//  type 1 audio (PCM16LE mono), 2 engine event (the engine's own JSON
//  text), 3 control (JSON). The keys come from the grant's 32-byte root
//  by HKDF-SHA256, one per direction and stream; the nonce is 4 zero
//  bytes and the counter, which starts at 0 and must rise. The relay's
//  own notices are [0, n] in clear.
//
//  The sealing mirrors conduit_push's dashboard/plugin_api.py ("Watch
//  audio"), checked by shared test vectors.
//

import CryptoKit
import Foundation

enum WatchAudioBridgeWire {
    static let version: UInt8 = 1
    static let helloType: UInt8 = 4
    /// The engines the bridge runs. Gemini stays direct.
    static let gptLive = "gpt_live"
    static let grok = "grok"
    /// The relay's bound on one message.
    static let maxMessageBytes = 64 * 1024
    /// What fits in one sealed message: the type, counter and tag go
    /// around it.
    static let maxPlainBytes = maxMessageBytes - 1 - 8 - 16
    static let salt = "conduit-watch-audio-v1"
    static let associatedDataTag = "conduit-watch-audio/1"

    enum Kind: UInt8 {
        case audio = 1
        case event = 2
        case control = 3
    }

    enum Direction: String {
        case watchToHost = "watch-to-host"
        case hostToWatch = "host-to-watch"
    }

    /// What the relay says about the other side, in clear.
    enum Notice: UInt8 {
        /// The Watch's socket came (sent to the host).
        case watchConnected = 1
        /// The Watch's socket went (sent to the host).
        case watchGone = 2
    }

    enum Failure: Error, Equatable {
        case malformed
        case didNotVerify
        case tooLarge
        case replayed
    }

    /// One stream's keys: one per direction, from the grant's root.
    struct Keys {
        let watchToHost: SymmetricKey
        let hostToWatch: SymmetricKey

        /// Nil unless `root` is 32 bytes and `streamID` 16.
        init?(root: Data, streamID: Data) {
            guard root.count == 32, streamID.count == 16 else { return nil }
            let material = SymmetricKey(data: root)
            let stream = WatchToolSeal.base64URL(streamID)
            func derive(_ direction: Direction) -> SymmetricKey {
                HKDF<SHA256>.deriveKey(
                    inputKeyMaterial: material,
                    salt: Data(WatchAudioBridgeWire.salt.utf8),
                    info: Data("conduit-watch-audio-v1 \(direction.rawValue) stream=\(stream)".utf8),
                    outputByteCount: 32
                )
            }
            watchToHost = derive(.watchToHost)
            hostToWatch = derive(.hostToWatch)
        }

        func key(_ direction: Direction) -> SymmetricKey {
            direction == .watchToHost ? watchToHost : hostToWatch
        }
    }

    static func associatedData(_ direction: Direction, grantID: String, streamID: Data, kind: Kind) -> Data {
        Data([
            associatedDataTag,
            direction.rawValue,
            "grant=\(grantID)",
            "sid=\(WatchToolSeal.base64URL(streamID))",
            "type=\(kind.rawValue)",
        ].joined(separator: "\n").utf8)
    }

    static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        // 12 bytes: never throws.
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    static func seal(_ plain: Data, kind: Kind, counter: UInt64, keys: Keys, direction: Direction, grantID: String, streamID: Data) throws -> Data {
        guard plain.count <= maxPlainBytes else { throw Failure.tooLarge }
        let box = try ChaChaPoly.seal(
            plain,
            using: keys.key(direction),
            nonce: nonce(counter),
            authenticating: associatedData(direction, grantID: grantID, streamID: streamID, kind: kind)
        )
        var message = Data([kind.rawValue])
        withUnsafeBytes(of: counter.bigEndian) { message.append(contentsOf: $0) }
        message.append(box.ciphertext)
        message.append(box.tag)
        return message
    }

    static func open(_ message: Data, keys: Keys, direction: Direction, grantID: String, streamID: Data) throws -> (kind: Kind, counter: UInt64, plain: Data) {
        let bytes = [UInt8](message)
        guard bytes.count >= 1 + 8 + 16, bytes.count <= maxMessageBytes, let kind = Kind(rawValue: bytes[0]) else {
            throw Failure.malformed
        }
        let counter = bytes[1..<9].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let body = Data(bytes[9...])
        guard let box = try? ChaChaPoly.SealedBox(nonce: nonce(counter), ciphertext: body.dropLast(16), tag: body.suffix(16)) else {
            throw Failure.malformed
        }
        do {
            let plain = try ChaChaPoly.open(
                box,
                using: keys.key(direction),
                authenticating: associatedData(direction, grantID: grantID, streamID: streamID, kind: kind)
            )
            return (kind, counter, plain)
        } catch {
            throw Failure.didNotVerify
        }
    }

    /// The first message on each connection, in clear.
    static func hello(streamID: Data) -> Data {
        Data([helloType]) + streamID + Data([version])
    }

    /// The relay's notice, if `message` is one.
    static func notice(_ message: Data) -> Notice? {
        guard message.count == 2, message.first == 0 else { return nil }
        return Notice(rawValue: message[message.startIndex + 1])
    }

    /// A new stream id: 16 random bytes. Taken once per grant.
    static func newStreamID() -> Data {
        SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
    }

    // MARK: Control

    /// Starts the engine. `briefing` is Conduit's rules, persona and
    /// memory (GPT-Live puts it in the instructions); `greeting` asks for
    /// a first line; `history` seeds a rejoined call's conversation.
    static func start(engine: String, voice: String?, briefing: String?, greeting: String?, history: [[String: Any]]) -> Data {
        var message: [String: Any] = ["type": "start", "engine": engine]
        if let voice, !voice.isEmpty { message["voice"] = voice }
        if let briefing, !briefing.isEmpty { message["briefing"] = briefing }
        if let greeting { message["greeting"] = greeting }
        if !history.isEmpty { message["history"] = history }
        return (try? WatchToolSeal.json(message)) ?? Data()
    }

    static let end = Data(#"{"type":"end"}"#.utf8)

    struct Started: Equatable {
        var engine: String
        var voice: String?
        var inputRate: Int
        var outputRate: Int
        var briefingApplied: Bool
        var greetingApplied: Bool
    }

    enum Control: Equatable {
        case started(Started)
        /// The engine's session ended: "ended" when asked, "error" after
        /// an error message, otherwise the engine's or the host's reason.
        case ended(reason: String?)
        /// A start the host refused or a session that failed: bad_request,
        /// busy, unavailable, rate_limited, refused, unreachable, failed or
        /// version, with a message for the user.
        case error(code: String?, message: String)
    }

    static func control(_ plain: Data) -> Control? {
        guard let object = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "started":
            return .started(Started(
                engine: object["engine"] as? String ?? "",
                voice: object["voice"] as? String,
                inputRate: object["input_rate"] as? Int ?? 16_000,
                outputRate: object["output_rate"] as? Int ?? 24_000,
                briefingApplied: object["briefing_applied"] as? Bool ?? false,
                greetingApplied: object["greeting_applied"] as? Bool ?? false
            ))
        case "ended":
            return .ended(reason: object["reason"] as? String)
        case "error":
            return .error(code: object["code"] as? String, message: object["message"] as? String ?? "")
        default:
            return nil
        }
    }

    /// PCM16LE mono, as the bridge carries audio.
    static func pcm(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func samples(_ pcm: Data) -> [Int16] {
        let bytes = [UInt8](pcm)
        return stride(from: 0, to: bytes.count - 1, by: 2).map { Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8) }
    }
}

/// One connection's sealing state: its stream id and keys, the counter it
/// sends with and the newest it accepted.
struct WatchAudioBridgeStream {
    let grantID: String
    let streamID: Data
    let keys: WatchAudioBridgeWire.Keys
    private(set) var sent: UInt64 = 0
    private(set) var received: UInt64?

    init?(grantID: String, root: Data, streamID: Data = WatchAudioBridgeWire.newStreamID()) {
        guard let keys = WatchAudioBridgeWire.Keys(root: root, streamID: streamID) else { return nil }
        self.grantID = grantID
        self.streamID = streamID
        self.keys = keys
    }

    mutating func seal(_ plain: Data, kind: WatchAudioBridgeWire.Kind) throws -> Data {
        let message = try WatchAudioBridgeWire.seal(plain, kind: kind, counter: sent, keys: keys, direction: .watchToHost, grantID: grantID, streamID: streamID)
        sent += 1
        return message
    }

    /// Checked once it verifies, so a forged counter can't move the window.
    mutating func open(_ message: Data) throws -> (kind: WatchAudioBridgeWire.Kind, plain: Data) {
        let opened = try WatchAudioBridgeWire.open(message, keys: keys, direction: .hostToWatch, grantID: grantID, streamID: streamID)
        if let received, opened.counter <= received { throw WatchAudioBridgeWire.Failure.replayed }
        received = opened.counter
        return (opened.kind, opened.plain)
    }
}
