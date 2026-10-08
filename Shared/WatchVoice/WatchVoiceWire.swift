//
//  WatchVoiceWire.swift
//  Conduit and the Conduit Watch app
//
//  What the Apple Watch and the iPhone send each other over
//  WatchConnectivity for a Watch voice call
//  (designs/apple-watch-voice-direct.md, apple-watch-gpt-live.md): small
//  Codable values in a message dictionary.
//

import Foundation

enum WatchVoiceWire {
    /// Bumped when either side changes what a message means; a mismatch
    /// refuses the call instead of misreading it.
    static let version = 2
    /// The message dictionary's only key.
    static let messageKey = "wv"

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
        /// The profile's spoken end phrases: the user saying one ends the
        /// call, as on the iPhone. Nil from an older iPhone.
        var endPhrases: [String]? = nil
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
        /// A renewal: the previous grant whose jobs Hermes moved to this
        /// one, so the Watch follows them here.
        var jobsCarriedFrom: String?
        /// The call's audio bridge for GPT-Live (and Grok) through the
        /// Hermes host, when asked for (designs/apple-watch-gpt-live.md).
        var audio: AudioBridge?
        /// The names a job may give the user's profiles ("for Fam, …"),
        /// where the host runs jobs on the others (plugin 0.11). Nil: a
        /// job for another profile goes through the iPhone.
        var jobProfiles: [JobProfileName]? = nil
    }

    /// One of the user's profiles as a job may name it: the profile
    /// (nil: the call's own) and every name it goes by, a bot's included.
    struct JobProfileName: Codable, Equatable {
        var profile: String?
        var names: [String]
    }

    /// Where the Watch dials the host's audio bridge: the relay's
    /// wss://…/v1/watch-audio/{grant}/watch, with the grant's relay key.
    /// `engines` are those the host can run now: GPT-Live only once its
    /// WebRTC runtime is made.
    struct AudioBridge: Codable, Equatable {
        var url: String
        var version: Int
        var engines: [String]
    }

    /// Everything a Watch call to GPT-Live through the host's audio bridge
    /// needs, built on the iPhone: the grant (audio, and jobs for the
    /// delegations as the user allows), and what the phone's GPT-Live call
    /// would start with.
    struct BridgeSession: Codable, Equatable {
        var engine: String
        var grant: DirectToolGrant
        /// Conduit's rules, persona and memory for the call as
        /// zlib-compressed UTF-8: they can be long.
        var briefing: Data
        /// The briefing's size before compression, for the log.
        var briefingBytes: Int
        var greeting: String?
        var voice: String?
        /// The profile's spoken end phrases: the user saying one ends the
        /// call, as on the iPhone. Nil from an older iPhone.
        var endPhrases: [String]? = nil
    }

    /// Everything a Watch call to Grok needs, built on the iPhone. The
    /// Watch runs the conversation as it runs Gemini's (the same setup,
    /// functions and tools), but xAI's session is held by the Hermes host,
    /// on its xAI sign-in, and reached through the grant's audio bridge.
    struct GrokSession: Codable, Equatable {
        /// `DirectSetup` as zlib-compressed JSON.
        var setup: Data
        var setupBytes: Int
        var voice: String?
        var openingPrompt: String?
        /// Opens the audio bridge, and carries the call's lookups and jobs.
        var grant: DirectToolGrant
        /// The profile's spoken end phrases: the user saying one ends the
        /// call, as on the iPhone. Nil from an older iPhone.
        var endPhrases: [String]? = nil
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

    /// A job a Watch call started through the push relay.
    struct DirectJob: Codable, Equatable {
        var jobID: String
        var title: String
        /// The job's Hermes chat, once the host named it.
        var sessionID: String?
        var startedAt: Date
    }

    /// The jobs a Watch call started through the relay, in order, from the
    /// start answers and the job news.
    struct DirectJobLog: Equatable {
        private(set) var jobs: [DirectJob] = []

        mutating func started(jobID: String, title: String, at: Date = Date()) {
            guard !jobID.isEmpty, !jobs.contains(where: { $0.jobID == jobID }) else { return }
            jobs.append(.init(jobID: jobID, title: title.isEmpty ? "Hermes job" : title, sessionID: nil, startedAt: at))
        }

        /// News names the job's chat; a job first heard of here (its start
        /// answer was lost) is kept from now.
        mutating func heard(jobID: String, title: String, sessionID: String?, at: Date = Date()) {
            started(jobID: jobID, title: title, at: at)
            guard let index = jobs.firstIndex(where: { $0.jobID == jobID }) else { return }
            if let sessionID, !sessionID.isEmpty { jobs[index].sessionID = sessionID }
            if !title.isEmpty, jobs[index].title == "Hermes job" { jobs[index].title = title }
        }

        mutating func reset() { jobs = [] }
    }

    /// A finished Watch call, queued to the iPhone to save in voice
    /// history whenever Conduit next runs there.
    struct DirectTranscript: Codable, Equatable {
        /// Names the saved call, so a transcript delivered twice is saved once.
        var callUUID: String
        var startedAt: Date
        var endedAt: Date
        var turns: [DirectTurn]
        /// The engine the call ran on; nil for Gemini.
        var engine: String? = nil
        /// The jobs the call started through the push relay, for the saved
        /// call's "Started a background job" lines. Nil from an older Watch.
        var jobs: [DirectJob]? = nil

        /// The newest turns whose text fits `bytes` of UTF-8: a queued
        /// transfer is meant for small payloads (Japanese or Chinese text
        /// takes three bytes a character), and a long call keeps its end.
        static let maxTextBytes = 40_000

        static func capped(_ turns: [DirectTurn], bytes: Int = maxTextBytes) -> [DirectTurn] {
            var kept: [DirectTurn] = []
            var total = 0
            for turn in turns.reversed() {
                total += turn.text.utf8.count
                if total > bytes {
                    // A newest turn too long on its own keeps its opening,
                    // so a call is never saved empty.
                    if kept.isEmpty {
                        var clipped = turn
                        clipped.text = clippedPrefix(turn.text, bytes: bytes)
                        if !clipped.text.isEmpty { kept.append(clipped) }
                    }
                    break
                }
                kept.append(turn)
            }
            return kept.reversed()
        }

        /// The longest whole-character opening of `text` within `bytes` of UTF-8.
        static func clippedPrefix(_ text: String, bytes: Int) -> String {
            var used = 0
            var end = text.startIndex
            for index in text.indices {
                let size = text[index].utf8.count
                if used + size > bytes { break }
                used += size
                end = text.index(after: index)
            }
            return String(text[..<end])
        }
    }

    /// Control messages, both directions.
    enum Message: Codable, Equatable {
        // Watch → iPhone
        /// A finished call's summary, as one JSON line for the iPhone's log.
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
        /// A new tool grant, before the call's runs out; Hermes moves the
        /// jobs of `carryJobsFrom` (the call's grant with jobs) to it.
        case directGrant(callID: UInt32, carryJobsFrom: String? = nil)
        /// A Watch call through the host's audio bridge (GPT-Live) wants
        /// its grant and briefing.
        case bridgeStart(callID: UInt32, version: Int, engine: String)
        /// A Watch call to Grok wants its setup and the grant that opens
        /// the host's audio bridge.
        case grokStart(callID: UInt32, version: Int)
        // iPhone → Watch
        /// Why the iPhone can't serve the call, as the Watch shows it.
        case callRefused(callID: UInt32, reason: String)
        /// The answer to `directStart`; a refusal comes as `callRefused`.
        case directSession(callID: UInt32, session: DirectSession)
        /// The answer to `directToken`; a refusal comes as `callRefused`.
        case directTokenIssued(callID: UInt32, token: DirectToken)
        /// The answer to `directTool` and `directPoll`.
        case directToolResult(callID: UInt32, result: DirectToolResult)
        /// The answer to `directGrant`; a refusal comes as `callRefused`.
        case directGrantIssued(callID: UInt32, grant: DirectToolGrant)
        /// The answer to `bridgeStart`; a refusal comes as `callRefused`.
        case bridgeSession(callID: UInt32, session: BridgeSession)
        /// The answer to `grokStart`; a refusal comes as `callRefused`.
        case grokSession(callID: UInt32, session: GrokSession)
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

enum WatchVoiceMain {
    /// Runs `work` on the main queue, in the order calls were made: a
    /// message must not overtake the one sent before it, and
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
