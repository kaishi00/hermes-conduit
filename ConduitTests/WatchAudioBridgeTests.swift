//
//  WatchAudioBridgeTests.swift
//  Conduit
//
//  GPT-Live on the Watch through the Hermes host's audio bridge
//  (designs/apple-watch-gpt-live.md): the sealing both ends share, the
//  control messages, the iPhone's hand-off, the delegation requests and
//  the call ledger's audio grant.
//  Written as an extension of an existing suite: the CI test planner is at
//  capacity for new XCTestCase classes.
//

import CryptoKit
import XCTest
@testable import Conduit

extension HermesVoiceGatewayTimeoutTests {
    private static let bridgeGrantID = String(repeating: "G", count: 22)
    private static let bridgeRoot = Data(0..<32)
    private static let bridgeStreamID = Data(100..<116)

    private static func bridgeHex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// The vectors conduit_push's tests/test_watch_audio.py checks the
    /// plugin against.
    func testWatchAudioBridgeSealMatchesTheHostPluginsVectors() throws {
        let keys = try XCTUnwrap(WatchAudioBridgeWire.Keys(root: Self.bridgeRoot, streamID: Self.bridgeStreamID))
        XCTAssertEqual(Self.bridgeHex(keys.watchToHost.withUnsafeBytes { Data($0) }), "a970c88b4c9fad954c1c7c46e50ba2a6cbb65e7cc660cb9c9903aaba94ec21d5")
        XCTAssertEqual(Self.bridgeHex(keys.hostToWatch.withUnsafeBytes { Data($0) }), "bfba0a519d8cc7330fb2c5eaafbada1094ba8906e9c613cdae24ec67a7f5791a")
        XCTAssertEqual(
            String(decoding: WatchAudioBridgeWire.associatedData(.watchToHost, grantID: Self.bridgeGrantID, streamID: Self.bridgeStreamID, kind: .control), as: UTF8.self),
            "conduit-watch-audio/1\nwatch-to-host\ngrant=GGGGGGGGGGGGGGGGGGGGGG\nsid=ZGVmZ2hpamtsbW5vcHFycw\ntype=3"
        )

        // The Watch's first sealed message on a stream: counter 0.
        var stream = try XCTUnwrap(WatchAudioBridgeStream(grantID: Self.bridgeGrantID, root: Self.bridgeRoot, streamID: Self.bridgeStreamID))
        let start = try stream.seal(Data(#"{"type":"start","engine":"gpt_live"}"#.utf8), kind: .control)
        XCTAssertEqual(Self.bridgeHex(start), "03000000000000000065911b5180de3d861bf69d75d796d56ed8363e51361e991a4f351df10440d35e3239930328e694505b7254359bab106607b55cf2")
        XCTAssertEqual(stream.sent, 1)

        // The host's audio, counter 1: PCM16LE samples 1 and 2.
        let audio = try XCTUnwrap(Data(hexString: "01000000000000000163f89b82063f879f7eccbfb0b3f896f105565f24"))
        let opened = try stream.open(audio)
        XCTAssertEqual(opened.kind, .audio)
        XCTAssertEqual(WatchAudioBridgeWire.samples(opened.plain), [1, 2])

        // Once only, and only as the host sealed it.
        XCTAssertThrowsError(try stream.open(audio)) {
            XCTAssertEqual($0 as? WatchAudioBridgeWire.Failure, .replayed)
        }
        var fresh = try XCTUnwrap(WatchAudioBridgeStream(grantID: Self.bridgeGrantID, root: Self.bridgeRoot, streamID: Self.bridgeStreamID))
        var flipped = audio
        flipped[flipped.count - 1] ^= 1
        XCTAssertThrowsError(try fresh.open(flipped)) {
            XCTAssertEqual($0 as? WatchAudioBridgeWire.Failure, .didNotVerify)
        }
        var retyped = audio
        retyped[0] = WatchAudioBridgeWire.Kind.control.rawValue
        XCTAssertThrowsError(try fresh.open(retyped))
        // The Watch's own message doesn't open as the host's.
        XCTAssertThrowsError(try fresh.open(start))
        var otherStream = try XCTUnwrap(WatchAudioBridgeStream(grantID: Self.bridgeGrantID, root: Self.bridgeRoot, streamID: Data(repeating: 0, count: 16)))
        XCTAssertThrowsError(try otherStream.open(audio))
        XCTAssertThrowsError(try fresh.open(audio.prefix(20))) {
            XCTAssertEqual($0 as? WatchAudioBridgeWire.Failure, .malformed)
        }
        XCTAssertEqual(try fresh.open(audio).kind, .audio)

        XCTAssertNil(WatchAudioBridgeWire.Keys(root: Data(0..<31), streamID: Self.bridgeStreamID))
        XCTAssertNil(WatchAudioBridgeWire.Keys(root: Self.bridgeRoot, streamID: Data(0..<15)))
        XCTAssertThrowsError(try stream.seal(Data(count: WatchAudioBridgeWire.maxPlainBytes + 1), kind: .audio)) {
            XCTAssertEqual($0 as? WatchAudioBridgeWire.Failure, .tooLarge)
        }
    }

    func testWatchAudioBridgeFramesAndControlMessages() throws {
        XCTAssertEqual(WatchAudioBridgeWire.hello(streamID: Self.bridgeStreamID), Data([4]) + Self.bridgeStreamID + Data([1]))
        XCTAssertEqual(WatchAudioBridgeWire.notice(Data([0, 1])), .watchConnected)
        XCTAssertEqual(WatchAudioBridgeWire.notice(Data([0, 2])), .watchGone)
        XCTAssertNil(WatchAudioBridgeWire.notice(Data([0, 9])))
        XCTAssertNil(WatchAudioBridgeWire.notice(Data([1, 1])))
        XCTAssertEqual(WatchAudioBridgeWire.newStreamID().count, 16)
        XCTAssertNotEqual(WatchAudioBridgeWire.newStreamID(), WatchAudioBridgeWire.newStreamID())

        let samples: [Int16] = [0, 1, -1, .max, .min]
        XCTAssertEqual(WatchAudioBridgeWire.pcm(samples), Data([0, 0, 1, 0, 0xff, 0xff, 0xff, 0x7f, 0, 0x80]))
        XCTAssertEqual(WatchAudioBridgeWire.samples(WatchAudioBridgeWire.pcm(samples)), samples)

        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: WatchAudioBridgeWire.start(
            engine: "gpt_live", voice: "cove", briefing: "Be brief.", greeting: "Say hi.", history: []
        )) as? [String: Any])
        XCTAssertEqual(first["type"] as? String, "start")
        XCTAssertEqual(first["engine"] as? String, "gpt_live")
        XCTAssertEqual(first["voice"] as? String, "cove")
        XCTAssertEqual(first["briefing"] as? String, "Be brief.")
        XCTAssertEqual(first["greeting"] as? String, "Say hi.")
        XCTAssertNil(first["history"])
        // A rejoin: the conversation so far, no second greeting.
        let rejoin = try XCTUnwrap(JSONSerialization.jsonObject(with: WatchAudioBridgeWire.start(
            engine: "gpt_live", voice: nil, briefing: nil, greeting: nil,
            history: [GPTLiveProtocol.historyItem(role: "user", text: "What's the capital of France?")]
        )) as? [String: Any])
        XCTAssertEqual(Set(rejoin.keys), ["type", "engine", "history"])
        XCTAssertEqual((rejoin["history"] as? [[String: Any]])?.first?["role"] as? String, "user")
        XCTAssertEqual(WatchAudioBridgeWire.end, Data(#"{"type":"end"}"#.utf8))

        XCTAssertEqual(
            WatchAudioBridgeWire.control(Data(#"{"type":"started","engine":"gpt_live","voice":"cove","input_rate":16000,"output_rate":24000,"briefing_applied":true,"greeting_applied":false}"#.utf8)),
            .started(.init(engine: "gpt_live", voice: "cove", inputRate: 16_000, outputRate: 24_000, briefingApplied: true, greetingApplied: false))
        )
        XCTAssertEqual(WatchAudioBridgeWire.control(Data(#"{"type":"ended","reason":"ended"}"#.utf8)), .ended(reason: "ended"))
        XCTAssertEqual(WatchAudioBridgeWire.control(Data(#"{"type":"ended"}"#.utf8)), .ended(reason: nil))
        XCTAssertEqual(
            WatchAudioBridgeWire.control(Data(#"{"type":"error","code":"busy","message":"Another Watch call is running."}"#.utf8)),
            .error(code: "busy", message: "Another Watch call is running.")
        )
        XCTAssertNil(WatchAudioBridgeWire.control(Data(#"{"type":"later"}"#.utf8)))
        XCTAssertNil(WatchAudioBridgeWire.control(Data("not json".utf8)))
    }

    /// What the iPhone hands the Watch: the grant with its audio bridge
    /// and the briefing, through the message dictionary.
    @MainActor
    func testWatchBridgeSessionCarriesTheGrantsBridgeAndTheBriefing() throws {
        let response: [String: Any] = [
            "ok": true,
            "grant_id": Self.bridgeGrantID,
            "relay_url": "https://relay.example.test",
            "key": WatchToolSeal.base64URL(Self.bridgeRoot),
            "watch_key": WatchToolSeal.base64URL(Data(repeating: 7, count: 32)),
            "expires_at": "2026-10-07T11:00:00Z",
            "tools": ["web_search", "start_job", "job_news", "answer_approval"],
            "max_calls": 60,
            "max_jobs": 3,
            "audio": ["url": "wss://relay.example.test/v1/watch-audio/\(Self.bridgeGrantID)/watch", "version": 1, "engines": ["gpt_live"]] as [String: Any],
        ]
        let grant = try XCTUnwrap(WatchToolGrantClient.grant(from: response))
        XCTAssertEqual(grant.audio, WatchVoiceWire.AudioBridge(url: "wss://relay.example.test/v1/watch-audio/\(Self.bridgeGrantID)/watch", version: 1, engines: ["gpt_live"]))
        var plain = response
        plain["audio"] = ["url": "ws://relay.example.test/v1/watch-audio/x/watch", "version": 1] as [String: Any]
        XCTAssertNil(try XCTUnwrap(WatchToolGrantClient.grant(from: plain)).audio)
        plain["audio"] = nil
        XCTAssertNil(try XCTUnwrap(WatchToolGrantClient.grant(from: plain)).audio)

        XCTAssertEqual(WatchToolGrantClient.audioRuntime(from: ["engines": ["gpt_live": ["runtime": "ready"]]]), .init(runtime: "ready", reason: nil))
        XCTAssertEqual(
            WatchToolGrantClient.audioRuntime(from: ["engines": ["gpt_live": ["runtime": "failed", "reason": "No compiler."]]]),
            .init(runtime: "failed", reason: "No compiler.")
        )
        XCTAssertEqual(WatchToolGrantClient.audioRuntime(from: [:]).runtime, "missing")

        let briefing = String(repeating: "Speak plainly and keep it short. ", count: 200)
        let packed = try XCTUnwrap(WatchVoiceWire.BridgeSession.pack(briefing))
        XCTAssertEqual(packed.bytes, briefing.utf8.count)
        XCTAssertLessThan(packed.data.count, packed.bytes)
        let session = WatchVoiceWire.BridgeSession(engine: "gpt_live", grant: grant, briefing: packed.data, briefingBytes: packed.bytes, greeting: "Say hi.", voice: "cove")
        XCTAssertEqual(session.briefingText, briefing)

        let messages: [WatchVoiceWire.Message] = [
            .bridgeStart(callID: 9, version: WatchVoiceWire.version, engine: "gpt_live"),
            .bridgeSession(callID: 9, session: session),
            .directEnd(callID: 9, transcript: .init(
                callUUID: "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                endedAt: Date(timeIntervalSince1970: 1_700_000_600),
                turns: [.init(role: .user, text: "Hi", at: Date(timeIntervalSince1970: 1_700_000_001))],
                engine: "gpt_live"
            )),
        ]
        for message in messages {
            XCTAssertEqual(WatchVoiceWire.decode(WatchVoiceWire.encode(message)), message)
        }

        // A transcript from a Watch app before the bridge is a Gemini call.
        let older = Data(#"{"callUUID":"A","startedAt":0,"endedAt":1,"turns":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(WatchVoiceWire.DirectTranscript.self, from: older).engine)
        XCTAssertEqual(VoiceCallEngine.watchBridge("gpt_live"), .gptLive)
        XCTAssertEqual(VoiceCallEngine.watchBridge("grok"), .grokLive)
        XCTAssertNil(VoiceCallEngine.watchBridge("gemini"))
    }

    /// The Watch asks Hermes for a delegation's work as the phone does.
    @MainActor
    func testWatchBridgeDelegationAsksForTheWorkAsThePhoneDoes() {
        XCTAssertEqual(WatchBridgeDelegation.contextMarker, GPTLiveConversationController.delegationContextMarker)

        let lines: [WatchBridgeDelegation.Line] = [
            .init(role: .user, text: "Find a ramen place.", handled: true),
            .init(role: .assistant, text: "I've asked Hermes.", handled: true),
            .init(role: .user, text: "And check the weather in Tokyo.", handled: false),
        ]
        XCTAssertEqual(
            WatchBridgeDelegation.request(itemText: "", lines: lines),
            "And check the weather in Tokyo."
                + WatchBridgeDelegation.contextMarker
                + "User (handled separately): Find a ramen place.\nAssistant: I've asked Hermes.\nUser: And check the weather in Tokyo.\n"
        )
        // Its own text wins over the user's words.
        XCTAssertTrue(WatchBridgeDelegation.request(itemText: "  Tokyo weather today ", lines: lines).hasPrefix("Tokyo weather today" + WatchBridgeDelegation.contextMarker))
        // Nothing new: no request, so Hermes doesn't redo the last one.
        XCTAssertEqual(WatchBridgeDelegation.request(itemText: "", lines: Array(lines.prefix(2))), "")
        XCTAssertEqual(WatchBridgeDelegation.request(itemText: "Weather", lines: []), "Weather")

        // Within the host's bound, context dropped first.
        let long = String(repeating: "é", count: 2_000)
        let request = WatchBridgeDelegation.request(itemText: long, lines: lines)
        XCTAssertLessThanOrEqual(request.utf8.count, WatchBridgeDelegation.maxRequestBytes)
        XCTAssertEqual(request, String(repeating: "é", count: WatchBridgeDelegation.maxRequestBytes / 2))
        XCTAssertEqual(WatchBridgeDelegation.clipped("aé", bytes: 2), "a")

        XCTAssertEqual(WatchBridgeDelegation.relay("The job finished."), WatchJobAnswer.updatePrompt("The job finished."))
        XCTAssertTrue(WatchBridgeDelegation.working(title: "Tokyo weather").contains("\"Tokyo weather\""))
    }

    /// A bridge call adopted after a restart still asks for the audio
    /// bridge; calls stored before it read as no audio.
    @MainActor
    func testWatchBridgeCallLedgerKeepsTheAudioGrantAcrossARestart() throws {
        let suite = "WatchDirectCallLedger.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var ledger = WatchDirectCallLedger(defaults: defaults)
        ledger.begin(7, connection: WatchDirectConnection(profile: "default", dashboard: "A"), saveCalls: true)
        let scope = WatchDirectCallLedger.GrantScope(
            tools: ["web_search"],
            jobTools: [],
            liveToken: false,
            maxJobs: 0,
            jobOptions: [:],
            voiceApprovals: false,
            grantIDs: ["grant-1"],
            audio: true
        )
        ledger.setGrant(scope, for: 7)
        XCTAssertEqual(WatchDirectCallLedger(defaults: defaults).call(7)?.grant?.audio, true)

        let stored = Data(#"{"tools":[],"jobTools":[],"liveToken":false,"maxJobs":0,"jobOptions":{},"voiceApprovals":false,"grantIDs":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(WatchDirectCallLedger.GrantScope.self, from: stored).audio)
    }

    /// Corrections on a Watch call (#455): the marker, the words and what
    /// the model hears match the phone's, for GPT-Live and Gemini/Grok.
    @MainActor
    func testWatchJobFollowUpsMirrorThePhone() {
        for text in ["Job 2: make it Alex", "job #3, hold that", "JOB 12 - never mind", "Jobs: list them",
                     "Job 2 make it Alex", "Job 2:30 appointment reminder", "job 2.5 things to check"] {
            let watch = WatchBridgeDelegation.jobMarker(in: text)
            let phone = GPTLiveDelegationBridge.jobMarker(in: text)
            XCTAssertEqual(watch?.number, phone?.number, text)
            XCTAssertEqual(watch?.rest, phone?.rest, text)
        }
        XCTAssertEqual(WatchBridgeDelegation.followUpWords(userWords: " make it Alex ", delegated: "Alex"), "make it Alex")
        XCTAssertEqual(WatchBridgeDelegation.followUpWords(userWords: "", delegated: " hold that "), "hold that")
        XCTAssertEqual(WatchBridgeDelegation.followUpWords(userWords: "", delegated: "hold that" + WatchBridgeDelegation.contextMarker + "User: hi\n"), "hold that")

        let pairs: [(WatchJobAnswer.FollowUp, VoiceFollowUpOutcome)] = [
            (.interrupted(title: "Tokyo weather"), .interrupted(title: "Tokyo weather")),
            (.queued(title: "Tokyo weather"), .queued(title: "Tokyo weather")),
            (.finished(title: ""), .finished(title: "")),
            (.failed("session not found"), .failed("session not found")),
        ]
        for (watch, phone) in pairs {
            XCTAssertEqual(WatchJobAnswer.followUpResult(watch), GeminiLiveToolBridge.followUpResult(phone))
            let reply = WatchBridgeDelegation.followUpReply(watch)
            XCTAssertEqual(
                GPTLiveDelegationBridge.followUpReply(delegationID: "d1", phone),
                .delegationReply(delegationID: "d1", text: reply.text, channel: reply.speakable ? .speakable : .commentary)
            )
        }

        XCTAssertEqual(WatchJobAnswer.FollowUp(body: ["ok": true, "outcome": "interrupted", "title": "T"]), .interrupted(title: "T"))
        XCTAssertEqual(WatchJobAnswer.FollowUp(body: ["ok": true, "outcome": "unknown_job"]), .unknownJob)
        XCTAssertEqual(WatchJobAnswer.FollowUp(body: ["ok": true, "outcome": "failed", "error": "busy"]), .failed("busy"))
        XCTAssertEqual(WatchJobAnswer.FollowUp(body: ["ok": false, "detail": "message is required"]), .failed("message is required"))

        XCTAssertEqual(WatchJobAnswer.arguments(name: WatchJobAnswer.interruptJob, ["job_id": " watch-2 ", "message": " make it Alex "]) as? [String: String],
                       ["job_id": "watch-2", "message": "make it Alex"])
        XCTAssertNil(WatchJobAnswer.arguments(name: WatchJobAnswer.interruptJob, ["job_id": "watch-2"]))
        XCTAssertEqual(WatchJobAnswer.missingArguments(name: WatchJobAnswer.interruptJob, ["job_id": "watch-2"]), ["error": "message is required"])
        XCTAssertEqual(WatchJobAnswer.missingArguments(name: WatchJobAnswer.interruptJob, [:])["error"], "Unknown job_id. Call list_jobs for the jobs' ids.")
        XCTAssertEqual(WatchJobAnswer.scheduling(name: WatchJobAnswer.interruptJob, result: [:]), GeminiLiveProtocol.Scheduling.whenIdle.rawValue)

        // Numbered when the host takes corrections, as the phone's note.
        XCTAssertTrue(WatchBridgeDelegation.working(title: "Tokyo weather", number: 2).contains("starting with \"Job 2:\""))
        XCTAssertFalse(WatchBridgeDelegation.working(title: "Tokyo weather").contains("Job "))
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
