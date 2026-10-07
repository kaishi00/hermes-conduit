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
    static let version = 2
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

    /// A single-use Gemini Live token the iPhone got from the Hermes host
    /// (designs/apple-watch-voice-direct.md). With the call's tool grant,
    /// the only credential the Watch ever holds: it works for one session
    /// and expires within the half hour.
    struct DirectToken: Codable, Equatable {
        var token: String
        var expiresAt: Date?
        var newSessionExpiresAt: Date?
        var model: String
        var webSocketURL: String
    }

    /// Everything a Watch call needs to run Gemini Live the way a call on
    /// the iPhone does, built there: the same instructions, functions and
    /// voice, and a token for the first connection.
    struct DirectSession: Codable, Equatable {
        var token: DirectToken
        /// `DirectSetup` as zlib-compressed JSON: the instructions carry
        /// the persona and memory, which can be long.
        var setup: Data
        /// The setup's uncompressed size, for the log.
        var setupBytes: Int
        var googleSearch: Bool
        var voice: String?
        /// The call's greeting turn, when the user asked for one.
        var openingPrompt: String?
        /// Lets the call's lookups reach Hermes through the push relay
        /// while the iPhone can't be reached. Nil when the host can't
        /// grant one: lookups then go through the iPhone only.
        var toolGrant: DirectToolGrant?
    }

    /// One call's grant to run web_search and recall_memory, and with the
    /// user's job setting Hermes jobs, through the push relay, without the
    /// iPhone (designs/apple-watch-voice-direct.md, "Wrist-down tools
    /// through the relay"). It works for this call's Hermes profile, those
    /// tools, half an hour and a call budget. The
    /// key seals what the Watch asks and what Hermes answers; the relay
    /// never gets it, and keeps only a hash of `watchKey`.
    struct DirectToolGrant: Codable, Equatable {
        var grantID: String
        /// The relay's https base URL.
        var relayURL: String
        /// The 32-byte root of the grant's two sealing keys, base64url.
        var key: String
        /// The Watch's key to the grant on the relay, base64url.
        var watchKey: String
        var expiresAt: Date?
        var tools: [String]
        var maxCalls: Int
        /// The jobs one call may start through the relay, when the grant
        /// carries jobs ("Wrist-down jobs through the relay").
        var maxJobs: Int?
        /// The user lets the model answer job approvals by voice; set by
        /// the iPhone from its setting, not by the host.
        var voiceApprovals: Bool?
    }

    /// The setup's long part. Function declarations travel as their JSON:
    /// their parameter schemas aren't Codable.
    struct DirectSetup: Codable, Equatable {
        var systemInstruction: String
        var functions: [Data]
    }

    /// A function call from Gemini, for the iPhone's tool bridge to run.
    struct DirectToolCall: Codable, Equatable {
        var id: String
        var name: String
        var arguments: [String: String]
    }

    /// What the tool bridge asks the call to send Gemini, as on the iPhone.
    enum DirectOutgoing: Codable, Equatable {
        /// `fallback` is said instead, as a text turn, when the call can't
        /// be answered any more (a new connection took over meanwhile), as
        /// the iPhone's call does.
        case toolResponse(id: String, name: String, result: [String: String], scheduling: String?, fallback: String?)
        /// Sent as a text turn once nobody is speaking.
        case textWhenIdle(String)
        /// Kept by the model without a reply, sent once nobody is speaking.
        case contextWhenIdle(String)
        /// The model said goodbye: end once it has played.
        case endConversation
    }

    /// The iPhone's answer to a tool call or a job poll.
    struct DirectToolResult: Codable, Equatable {
        var outgoing: [DirectOutgoing]
        /// Voice jobs still running on Hermes (the phone's count, so jobs
        /// started elsewhere count too): the Watch asks again while there
        /// are any.
        var runningJobs: Int
    }

    /// One settled line of a Watch call's transcript.
    struct DirectTurn: Codable, Equatable {
        enum Role: String, Codable {
            case user
            case assistant
        }
        var role: Role
        var text: String
        var at: Date
    }

    /// A finished Watch call, queued to the iPhone to save in voice
    /// history whenever Conduit next runs there.
    struct DirectTranscript: Codable, Equatable {
        /// Names the saved call, so a transcript delivered twice is saved once.
        var callUUID: String
        var startedAt: Date
        var endedAt: Date
        var turns: [DirectTurn]
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
        /// Any other Watch event, as one JSON line for the iPhone's log.
        case note(String)
        /// A Watch call to Gemini Live wants its session.
        case directStart(callID: UInt32, version: Int)
        /// A new single-use token for the call's next connection.
        case directToken(callID: UInt32)
        case directTool(callID: UInt32, call: DirectToolCall)
        /// Gemini withdrew these calls (the user interrupted).
        case directToolCancel(callID: UInt32, ids: [String])
        /// While the call's jobs run: anything to tell the user?
        case directPoll(callID: UInt32)
        /// The call ended; queued, so it arrives even if the iPhone is
        /// asleep right now.
        case directEnd(callID: UInt32, transcript: DirectTranscript)
        /// A new tool grant, before the call's runs out.
        case directGrant(callID: UInt32)
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
        /// The answer to `directStart`; a refusal comes as `callRefused`.
        case directSession(callID: UInt32, session: DirectSession)
        /// The answer to `directToken`; a refusal comes as `callRefused`.
        case directTokenIssued(callID: UInt32, token: DirectToken)
        /// The answer to `directTool` and `directPoll`.
        case directToolResult(callID: UInt32, result: DirectToolResult)
        /// The answer to `directGrant`; a refusal comes as `callRefused`.
        case directGrantIssued(callID: UInt32, grant: DirectToolGrant)
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

    /// A timer on the main run loop's common modes. A scheduled timer
    /// fires in the default mode only, so it stops while the user
    /// scrolls, and the pause would read as a link stall or a suspension.
    static func timer(every interval: TimeInterval, repeats: Bool, _ block: @escaping @Sendable (Timer) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
