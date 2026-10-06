//
//  WatchVoiceWire.swift
//  Conduit and the Conduit Watch app
//
//  What the Apple Watch and the iPhone send each other over
//  WatchConnectivity for a wrist voice call and the link tests
//  (designs/apple-watch-voice.md, proof of concept). Control messages are
//  small Codable values in a message dictionary; audio travels as
//  `sendMessageData` packets with a fixed little-endian header.
//

import Foundation

enum WatchVoiceWire {
    /// Bumped when either side changes what a message means; a mismatch
    /// refuses the call instead of misreading it.
    static let version = 1
    /// The message dictionary's only key.
    static let messageKey = "wv"

    /// A Watch call's state as the iPhone sees it.
    struct CallState: Codable, Equatable {
        enum Phase: String, Codable {
            case connecting, listening, speaking, paused, reconnecting, ending, ended, failed
        }
        var callID: UInt32
        var phase: Phase
        /// The failure, or why the call ended.
        var detail: String?
        /// The newest transcript line, cut short.
        var caption: String?
        var mode: String
        var jobs: Int
        var muted: Bool
    }

    /// One link test: both sides send packets of a fixed size at a fixed
    /// interval and measure what comes back.
    struct SoakPlan: Codable, Equatable {
        var runID: UInt32
        var label: String
        var duration: TimeInterval
        var interval: TimeInterval
        var upBytes: Int
        var downBytes: Int
        var maxInFlight: Int
    }

    /// What one side of a link test measured.
    struct SoakResult: Codable, Equatable {
        var side: String
        var runID: UInt32
        var label: String
        /// Packets this side sent, and how many the other side acknowledged.
        var sent: Int
        var acked: Int
        var failed: Int
        /// Sends folded into a later packet because too many were in flight.
        var merged: Int
        var rttP50Ms: Int?
        var rttP95Ms: Int?
        var rttP99Ms: Int?
        var rttMaxMs: Int?
        /// Packets this side received from the other.
        var received: Int
        /// Longest wait between two received packets, and how many waits
        /// went over a second.
        var maxGapMs: Int?
        var stallsOver1s: Int
        var reachabilityChanges: Int
        /// The iPhone app was not running for this long in total (gaps in
        /// its one-second ticker).
        var suspendedMs: Int
        var errors: [String]
    }

    /// Control messages, both directions.
    enum Message: Codable, Equatable {
        // Watch → iPhone
        case callStart(callID: UInt32, fullDuplex: Bool, version: Int)
        case callEnd(callID: UInt32)
        case interrupt(callID: UInt32)
        case mute(callID: UInt32, muted: Bool)
        /// The Watch stopped its microphone (wrist down, Siri, a phone call).
        case paused(callID: UInt32, reason: String)
        case resumed(callID: UInt32)
        /// Everything up to `seq` of `turn` has played out on the Watch.
        case drained(callID: UInt32, turn: UInt32, seq: UInt32)
        case ping(callID: UInt32?)
        case soakStart(SoakPlan)
        case soakStop(runID: UInt32)
        /// A finished test's result, as one JSON line for the iPhone's log.
        case report(String)
        // iPhone → Watch
        case callAccepted(callID: UInt32, mode: String)
        case callRefused(callID: UInt32, reason: String)
        case callState(CallState)
        /// Drop what's queued for this turn and anything older.
        case stopPlayback(callID: UInt32, turn: UInt32)
        /// How long the model took on the iPhone for this turn, from the
        /// end of the user's speech as it arrived there to the model's
        /// first audio.
        case turnMetrics(callID: UInt32, turn: UInt32, modelLatencyMs: Int)
        case soakResult(SoakResult)
        case pong(phase: String?)
    }

    static func encode(_ message: Message) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(message) else { return [:] }
        return [messageKey: data]
    }

    static func decode(_ dictionary: [String: Any]) -> Message? {
        guard let data = dictionary[messageKey] as? Data else { return nil }
        return try? JSONDecoder().decode(Message.self, from: data)
    }
}

/// An audio or link-test packet: a 24-byte little-endian header, then the
/// payload (IMA ADPCM blocks for call audio, filler for a link test).
struct WatchVoicePacket: Equatable {
    enum Kind: UInt8 {
        case callAudio = 1
        case soak = 2
    }

    enum Codec: UInt8 {
        case pcm16 = 0
        case imaADPCM = 1
        case none = 255
    }

    struct Flags: OptionSet, Equatable {
        let rawValue: UInt8
        /// The first packet of a model turn (downlink).
        static let turnStart = Flags(rawValue: 1)
    }

    static let headerSize = 24

    var kind: Kind
    var flags: Flags = []
    var codec: Codec
    var callID: UInt32
    var seq: UInt32
    var turn: UInt32 = 0
    var sampleRate: UInt32
    /// The sender's clock, in milliseconds since its call or test began.
    var sentAtMs: UInt32
    var payload: Data

    func encoded() -> Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        data.append(kind.rawValue)
        data.append(flags.rawValue)
        data.append(codec.rawValue)
        data.append(0)
        for value in [callID, seq, turn, sampleRate, sentAtMs] {
            Self.appendUInt32(value, to: &data)
        }
        data.append(payload)
        return data
    }

    init(kind: Kind, flags: Flags = [], codec: Codec, callID: UInt32, seq: UInt32, turn: UInt32 = 0, sampleRate: UInt32, sentAtMs: UInt32, payload: Data) {
        self.kind = kind
        self.flags = flags
        self.codec = codec
        self.callID = callID
        self.seq = seq
        self.turn = turn
        self.sampleRate = sampleRate
        self.sentAtMs = sentAtMs
        self.payload = payload
    }

    init?(data: Data) {
        guard data.count >= Self.headerSize else { return nil }
        let start = data.startIndex
        guard let kind = Kind(rawValue: data[start]),
              let codec = Codec(rawValue: data[start + 2]) else { return nil }
        self.kind = kind
        self.flags = Flags(rawValue: data[start + 1])
        self.codec = codec
        callID = Self.readUInt32(data, at: 4)
        seq = Self.readUInt32(data, at: 8)
        turn = Self.readUInt32(data, at: 12)
        sampleRate = Self.readUInt32(data, at: 16)
        sentAtMs = Self.readUInt32(data, at: 20)
        payload = Data(data[(start + Self.headerSize)...])
    }

    static func appendUInt32(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    /// Reads at an offset from the data's own start, so slices work too.
    static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(data[start + index]) << UInt32(8 * index)
        }
        return value
    }
}

enum WatchVoiceMain {
    /// Runs `work` on the main queue, in the order calls were made: a
    /// packet or message must not overtake the one sent before it, and
    /// separate Task hops to the main actor don't promise their order.
    static func async(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }
}
