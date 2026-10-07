//
//  WatchVoiceWireTests.swift
//  Conduit
//
//  Apple Watch proof of concept (designs/apple-watch-voice.md): the link
//  format, audio codec and measurements both devices share. Written as an
//  extension of an existing suite: the CI test planner is at capacity for
//  new XCTestCase classes.
//

import CryptoKit
import XCTest
@testable import Conduit

extension HermesVoiceGatewayTimeoutTests {
    func testWatchVoiceADPCMKeepsSpeechClearAtAQuarterOfTheSize() throws {
        let rate = 24_000.0
        let samples = (0..<Int(rate)).map { index in
            Int16((8_000 * sin(2 * Double.pi * 440 * Double(index) / rate)).rounded())
        }
        var encoder = IMAADPCM.Encoder()
        let encoded = encoder.encode(samples)
        XCTAssertEqual(encoded.count, IMAADPCM.blockHeaderSize + samples.count / 2)

        let decoded = try XCTUnwrap(IMAADPCM.decode(encoded))
        XCTAssertEqual(decoded.count, samples.count)
        var signal = 0.0
        var noise = 0.0
        for (original, restored) in zip(samples, decoded) {
            signal += Double(original) * Double(original)
            noise += Double(Int(original) - Int(restored)) * Double(Int(original) - Int(restored))
        }
        XCTAssertGreaterThan(10 * log10(signal / noise), 25, "Signal to noise in dB")
    }

    func testWatchVoiceADPCMBlocksDecodeOnTheirOwn() throws {
        // The second packet is longer than one block holds, with an odd
        // sample count.
        let samples = (0..<(IMAADPCM.maxSamplesPerBlock + 10_001)).map { index in
            Int16(truncatingIfNeeded: (index * 37) % 12_000 - 6_000)
        }
        var encoder = IMAADPCM.Encoder()
        let first = encoder.encode(Array(samples.prefix(4_801)))
        let second = encoder.encode(Array(samples.dropFirst(4_801)))
        let whole = try XCTUnwrap(IMAADPCM.decode(first + second))
        XCTAssertEqual(whole.count, samples.count)

        // A lost packet costs only its own audio: the next one carries the
        // coder state it starts from.
        let alone = try XCTUnwrap(IMAADPCM.decode(second))
        XCTAssertEqual(alone, Array(whole.dropFirst(4_801)))

        // Cut short or malformed is refused, not misread.
        XCTAssertNil(IMAADPCM.decode(second.dropLast()))
        var badIndex = first
        badIndex[badIndex.startIndex + 2] = 89
        XCTAssertNil(IMAADPCM.decode(badIndex))
        XCTAssertEqual(IMAADPCM.decode(Data()), [])

        encoder.reset()
        XCTAssertEqual(encoder.state, IMAADPCM.State())
    }

    func testWatchVoicePCMRoundTripsLittleEndian() {
        let samples: [Int16] = [0, 1, -1, .max, .min, 1_234]
        let data = WatchVoicePCM.data(samples)
        XCTAssertEqual(Array(data.prefix(4)), [0, 0, 1, 0])
        XCTAssertEqual(WatchVoicePCM.samples(data), samples)
        XCTAssertEqual(WatchVoicePCM.data(samples[2...]), data.dropFirst(4))
    }

    func testWatchVoicePacketHeaderRoundTripsFromASlice() throws {
        let packet = WatchVoicePacket(
            kind: .callAudio,
            flags: .turnStart,
            codec: .imaADPCM,
            callID: 0xDEAD_BEEF,
            seq: 7,
            turn: 3,
            sampleRate: 24_000,
            sentAtMs: 123_456,
            payload: Data([9, 8, 7])
        )
        let encoded = packet.encoded()
        XCTAssertEqual(encoded.count, WatchVoicePacket.headerSize + 3)
        XCTAssertEqual(Array(encoded.prefix(8)), [1, 1, 1, 0, 0xEF, 0xBE, 0xAD, 0xDE])
        XCTAssertEqual(WatchVoicePacket(data: encoded), packet)

        // WatchConnectivity may hand over a slice of a larger buffer.
        let slice = (Data([0xFF, 0xFF]) + encoded).dropFirst(2)
        XCTAssertEqual(WatchVoicePacket(data: slice), packet)

        XCTAssertNil(WatchVoicePacket(data: encoded.prefix(WatchVoicePacket.headerSize - 1)))
        var unknownKind = encoded
        unknownKind[0] = 9
        XCTAssertNil(WatchVoicePacket(data: unknownKind))
    }

    func testWatchVoiceMessagesRoundTripThroughTheMessageDictionary() {
        let messages: [WatchVoiceWire.Message] = [
            .callStart(callID: 1, fullDuplex: false, version: WatchVoiceWire.version),
            .ping(callID: nil),
            .ping(callID: 4),
            .drained(callID: 1, turn: 2, seq: 3),
            .report("{\"event\":\"callSummary\"}"),
            .note("{\"event\":\"pingFailed\"}"),
            .callState(.init(callID: 1, phase: .speaking, detail: nil, caption: "Hello", mode: "geminiLive", jobs: 1, muted: false)),
            .soakResult(.init(
                side: "phone", runID: 2, label: "live", sent: 10, acked: 9, failed: 1, merged: 0,
                rttP50Ms: 40, rttP95Ms: nil, rttP99Ms: nil, rttMaxMs: 90, received: 10, maxGapMs: nil,
                stallsOver1s: 0, reachabilityChanges: 1, suspendedMs: 0, errors: ["timeout"]
            )),
            .pong(phase: nil),
        ]
        for message in messages {
            let dictionary = WatchVoiceWire.encode(message)
            XCTAssertEqual(Array(dictionary.keys), [WatchVoiceWire.messageKey])
            XCTAssertEqual(WatchVoiceWire.decode(dictionary), message)
        }
        XCTAssertNil(WatchVoiceWire.decode([:]))
        XCTAssertNil(WatchVoiceWire.decode([WatchVoiceWire.messageKey: Data("{}".utf8)]))
    }

    func testWatchVoiceStatsPercentilesAndLogLines() {
        let values = (1...100).map(Double.init)
        XCTAssertEqual(WatchVoiceStats.percentile(values, 0.5), 50)
        XCTAssertEqual(WatchVoiceStats.percentile(values, 0.95), 95)
        XCTAssertEqual(WatchVoiceStats.percentile(values, 1), 100)
        XCTAssertNil(WatchVoiceStats.percentile([], 0.5))
        XCTAssertEqual(WatchVoiceStats.milliseconds(0.2504), 250)

        let missing: Int? = nil
        let present: Int? = 42
        let line = WatchVoiceStats.jsonLine(["at": "t", "event": "x", "missing": missing as Any, "rtt": present as Any])
        XCTAssertEqual(line, #"{"at":"t","event":"x","missing":null,"rtt":42}"#)
    }

    func testWatchVoiceActivityFindsTheEndOfSpeech() throws {
        let rate = 16_000.0
        var samples = [Int16](repeating: 0, count: Int(rate))
        // Speech from 0.5 s to 0.8 s of a one-second chunk ending at 10 s.
        for index in Int(rate * 0.5)..<Int(rate * 0.8) {
            samples[index] = Int16((8_000 * sin(2 * Double.pi * 300 * Double(index) / rate)).rounded())
        }
        var activity = WatchVoiceActivity()
        activity.process(samples, sampleRate: rate, endingAt: 10)
        XCTAssertEqual(try XCTUnwrap(activity.lastVoicedAt), 9.8, accuracy: 0.001)
        XCTAssertEqual(activity.level, 0)

        activity.reset()
        XCTAssertNil(activity.lastVoicedAt)
    }

    // MARK: Gemini on the Watch (designs/apple-watch-voice-direct.md)

    func testWatchDirectMessagesRoundTripThroughTheMessageDictionary() {
        let token = WatchVoiceWire.DirectToken(
            token: "auth_tokens/one-use",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            newSessionExpiresAt: nil,
            model: "gemini-3.8-live",
            webSocketURL: "wss://example.test/ws"
        )
        let messages: [WatchVoiceWire.Message] = [
            .directStart(callID: 7, version: WatchVoiceWire.version),
            .directToken(callID: 7),
            .directTool(callID: 7, call: .init(id: "c1", name: "start_job", arguments: ["instructions": "Check the build"])),
            .directToolCancel(callID: 7, ids: ["c1", "c2"]),
            .directPoll(callID: 7),
            .directEnd(callID: 7, transcript: .init(
                callUUID: "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                endedAt: Date(timeIntervalSince1970: 1_700_000_600),
                turns: [.init(role: .user, text: "Hi", at: Date(timeIntervalSince1970: 1_700_000_001))]
            )),
            .directSession(callID: 7, session: .init(token: token, setup: Data([1, 2, 3]), setupBytes: 900, googleSearch: false, voice: "Kore", openingPrompt: nil)),
            .directSession(callID: 7, session: .init(token: token, setup: Data([1, 2, 3]), setupBytes: 900, googleSearch: false, voice: "Kore", openingPrompt: nil, toolGrant: Self.watchToolGrant)),
            .directTokenIssued(callID: 7, token: token),
            .directGrant(callID: 7),
            .directGrantIssued(callID: 7, grant: Self.watchToolGrant),
            .directToolResult(callID: 7, result: .init(outgoing: [
                .toolResponse(id: "c1", name: "start_job", result: ["status": "running"], scheduling: nil, fallback: "Hermes started it."),
                .textWhenIdle("The build passed."),
                .contextWhenIdle("Typed in the chat."),
                .endConversation,
            ], runningJobs: 1)),
        ]
        for message in messages {
            XCTAssertEqual(WatchVoiceWire.decode(WatchVoiceWire.encode(message)), message)
        }
    }

    /// The Watch's session must send Gemini exactly the setup the iPhone's
    /// would: the declarations survive the trip byte for byte.
    @MainActor
    func testWatchDirectSetupGivesTheWatchTheIPhonesSetup() throws {
        let functions = GeminiLiveToolBridge.declarations(webSearch: true, memoryRecall: true, thread: false)
        let instructions = GeminiLiveConversationController.instructions(search: .hermes, answerLength: .detailed)
        let packed = try XCTUnwrap(WatchVoiceWire.DirectSetup(systemInstruction: instructions, functions: functions).compressed())
        XCTAssertLessThan(packed.data.count, packed.bytes)

        let unpacked = try XCTUnwrap(WatchVoiceWire.DirectSetup(compressed: packed.data))
        let declarations = try XCTUnwrap(unpacked.declarations)
        XCTAssertEqual(declarations.map(\.name), functions.map(\.name))
        XCTAssertEqual(declarations.map(\.behavior), functions.map(\.behavior))

        func setup(_ instructions: String, _ functions: [GeminiLiveProtocol.FunctionDeclaration]) throws -> Data {
            let message = GeminiLiveProtocol.setupMessage(systemInstruction: instructions, functions: functions, googleSearch: false, voice: "Kore", resumptionHandle: "h1")
            return try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        }
        XCTAssertEqual(try setup(unpacked.systemInstruction, declarations), try setup(instructions, functions))

        XCTAssertNil(WatchVoiceWire.DirectSetup(compressed: Data("not zlib".utf8)))
        XCTAssertNil(WatchVoiceWire.DirectSetup(systemInstruction: "x", functions: [Data("{}".utf8)]).declarations)
    }

    func testWatchDirectTokenKeepsEveryField() throws {
        let token = GeminiLiveToken(
            token: "auth_tokens/one-use",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            newSessionExpiresAt: Date(timeIntervalSince1970: 1_800_000_060),
            model: "gemini-3.8-live",
            webSocketURL: try XCTUnwrap(URL(string: "wss://example.test/ws?key=value"))
        )
        let wire = WatchVoiceWire.DirectToken(token)
        XCTAssertEqual(wire.geminiToken, token)
        XCTAssertEqual(wire.geminiToken?.connectURL, token.connectURL)
    }

    func testWatchDirectOutgoingBecomesWhatTheIPhonesCallSends() {
        XCTAssertEqual(
            WatchVoiceWire.DirectOutgoing.toolResponse(id: "c1", name: "web_search", result: ["answer": "Sunny"], scheduling: "WHEN_IDLE", fallback: "Sunny.").clientMessage,
            .toolResponse(id: "c1", name: "web_search", result: ["answer": "Sunny"], scheduling: .whenIdle)
        )
        XCTAssertEqual(
            WatchVoiceWire.DirectOutgoing.toolResponse(id: "c2", name: "start_job", result: [:], scheduling: nil, fallback: nil).clientMessage,
            .toolResponse(id: "c2", name: "start_job", result: [:], scheduling: nil)
        )
        XCTAssertEqual(WatchVoiceWire.DirectOutgoing.textWhenIdle("Done.").clientMessage, .textTurn("Done."))
        XCTAssertEqual(WatchVoiceWire.DirectOutgoing.contextWhenIdle("Typed.").clientMessage, .contextNote("Typed."))
        XCTAssertNil(WatchVoiceWire.DirectOutgoing.endConversation.clientMessage)
        XCTAssertTrue(WatchVoiceWire.DirectOutgoing.textWhenIdle("Done.").waitsForQuiet)
        XCTAssertFalse(WatchVoiceWire.DirectOutgoing.endConversation.waitsForQuiet)
    }

    @MainActor
    func testWatchDirectBrokerPassesTheBridgesOutgoingOn() {
        XCTAssertEqual(WatchDirectBroker.wire(.textWhenIdle("News.")), .textWhenIdle("News."))
        XCTAssertEqual(WatchDirectBroker.wire(.endConversation), .endConversation)
        let silent = WatchDirectBroker.wire(.toolResponse(id: "c1", name: "recall_memory", result: ["status": "ok"], scheduling: .silent))
        XCTAssertEqual(silent, .toolResponse(id: "c1", name: "recall_memory", result: ["status": "ok"], scheduling: "SILENT", fallback: nil))
    }

    // MARK: Wrist-down tools through the relay

    static let watchToolGrant = WatchVoiceWire.DirectToolGrant(
        grantID: String(repeating: "G", count: 22),
        relayURL: "https://relay.example.test",
        key: WatchToolSeal.base64URL(Data(0..<32)),
        watchKey: WatchToolSeal.base64URL(Data(repeating: 7, count: 32)),
        expiresAt: Date(timeIntervalSinceNow: 1_800),
        tools: ["web_search", "recall_memory"],
        maxCalls: 60
    )

    private static func hex(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
    }

    /// The vectors conduit_push's tests/test_watch_tools.py checks the
    /// plugin against: the Watch seals what the host opens, and opens
    /// what the host seals.
    func testWatchToolSealMatchesTheHostPluginsVectors() throws {
        let keys = try XCTUnwrap(WatchToolSeal.Keys(root: Data(0..<32)))
        XCTAssertEqual(Self.hex(keys.call), "76bee458fa181a0da7695798b6de8a0be9bf13587ecac450ff389d0094b5bbdf")
        XCTAssertEqual(Self.hex(keys.result), "06499568025534ab010493728680fd7bc9216867d0012198cc6d6a9e450fc703")

        let grantID = String(repeating: "G", count: 22)
        let rid = String(repeating: "R", count: 22)
        let nonce = try ChaChaPoly.Nonce(data: Data(0..<12))
        let call = try WatchToolSeal.json(["tool": "web_search", "args": ["query": "weather in Tokyo"]])
        XCTAssertEqual(String(decoding: call, as: UTF8.self), #"{"args":{"query":"weather in Tokyo"},"tool":"web_search"}"#)
        let sealed = try WatchToolSeal.seal(call, keys: keys, direction: .call, grantID: grantID, rid: rid, nonce: nonce)
        XCTAssertEqual(sealed, .init(
            n: "AAECAwQFBgcICQoL",
            ct: "usQw1Mc1f6DtZfIgf1Dd3VKsJq3JjVCOQUQYKH3nr0mk-Lb0ZEN1IoBA1LY1CEkYy8BAT4aGVN28rrFCyuXKvKmk7un4LOPnaA"
        ))

        let answer = WatchToolSeal.Sealed(
            n: "AAECAwQFBgcICQoL",
            ct: "Mmf4pRBwr3HNiVGcy-x-KIXRml6fz7xmr32vPgunMfFVqBvDAEImsfwkDEGZP28NtM89wF7XhlAhL99eH7KBpO0cVQc4roUey5BFrzA84ybx4K1PD28aY05sabPmNAQBqZoEkZR-bA1IdfVrmkLNhhbS7Qi1TfDsHIIgVOxQ1PVG2ohffj1meUdS-EskwQTMUW_iivE2GQ"
        )
        let opened = try WatchToolSeal.open(answer, keys: keys, direction: .result, grantID: grantID, rid: rid)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: opened) as? [String: Any])
        XCTAssertEqual(WatchToolAnswer.result(name: "web_search", body: body), [
            "results": "1. Tokyo weather: Sunny, 21°C (https://example.com/tokyo)",
            "note": WatchToolAnswer.lookupAnswerNote,
        ])

        // Bound to its direction, grant and call: anything else is refused.
        XCTAssertThrowsError(try WatchToolSeal.open(answer, keys: keys, direction: .call, grantID: grantID, rid: rid)) {
            XCTAssertEqual($0 as? WatchToolSeal.Failure, .didNotVerify)
        }
        XCTAssertThrowsError(try WatchToolSeal.open(answer, keys: keys, direction: .result, grantID: grantID, rid: String(repeating: "S", count: 22)))
        XCTAssertThrowsError(try WatchToolSeal.open(answer, keys: keys, direction: .result, grantID: String(repeating: "H", count: 22), rid: rid))
        var flipped = answer
        flipped.ct = (flipped.ct.first == "A" ? "B" : "A") + flipped.ct.dropFirst()
        XCTAssertThrowsError(try WatchToolSeal.open(flipped, keys: keys, direction: .result, grantID: grantID, rid: rid))
        XCTAssertThrowsError(try WatchToolSeal.open(.init(n: "AAEC", ct: answer.ct), keys: keys, direction: .result, grantID: grantID, rid: rid)) {
            XCTAssertEqual($0 as? WatchToolSeal.Failure, .malformed)
        }
        XCTAssertNil(WatchToolSeal.Keys(root: Data(0..<31)))
    }

    func testWatchToolSealBase64URLRefusesOtherAlphabets() {
        XCTAssertEqual(WatchToolSeal.base64URL(Data([0xfb, 0xff, 0xfe])), "-__-")
        XCTAssertEqual(WatchToolSeal.data(base64URL: "-__-"), Data([0xfb, 0xff, 0xfe]))
        XCTAssertEqual(WatchToolSeal.data(base64URL: "AQ"), Data([1]))
        XCTAssertNil(WatchToolSeal.data(base64URL: "+//+"))
        XCTAssertNil(WatchToolSeal.data(base64URL: "AQ=="))
        XCTAssertNil(WatchToolSeal.data(base64URL: "AQIDB"))
        XCTAssertEqual(WatchToolSeal.newRequestID().count, 22)
        XCTAssertNotEqual(WatchToolSeal.newRequestID(), WatchToolSeal.newRequestID())
    }

    /// A lookup through the relay must reach the model exactly as the same
    /// host response would through the iPhone: the bridge's result, its
    /// scheduling, and the broker's fallback.
    @MainActor
    func testWatchToolAnswersMatchWhatTheIPhoneSendsForTheSameHostResponse() async throws {
        let backend = FakeVoiceJobBackend()
        defer { withExtendedLifetime(backend) {} }
        let supervisor = VoiceBackgroundJobSupervisor(backend: backend.backend, pollInterval: .seconds(3_600))
        let search = FakeGeminiLiveWebSearch()
        let memory = FakeGeminiLiveMemory()
        let bridge = GeminiLiveToolBridge(supervisor: supervisor, webSearch: search, memory: memory, holdsJobCalls: false)

        XCTAssertEqual(WatchToolAnswer.webSearchLimit, GeminiLiveTokenClient.webSearchLimit)
        XCTAssertEqual(WatchToolAnswer.memoryRecallLimit, GeminiLiveTokenClient.memoryRecallLimit)
        XCTAssertEqual(WatchToolAnswer.lookupAnswerNote, GeminiLiveToolBridge.lookupAnswerNote)
        XCTAssertEqual(WatchToolAnswer.tools, [GeminiLiveToolBridge.Tool.webSearch.rawValue, GeminiLiveToolBridge.Tool.recallMemory.rawValue])

        let searchBodies: [[String: Any]] = [
            ["ok": true, "query": "q", "results": [
                ["title": "Tokyo weather", "url": "https://example.com/tokyo", "snippet": "Sunny, 21°C"],
                ["title": "No link", "url": "", "snippet": "Dropped"],
                ["url": "https://example.com/bare"],
            ]],
            ["ok": true, "query": "q", "results": [] as [Any]],
            ["ok": false, "status": 503, "detail": "No web search provider configured."],
            ["ok": false, "status": 500],
        ]
        for (index, body) in searchBodies.enumerated() {
            do {
                search.results = try GeminiLiveTokenClient.webResults(from: body)
                search.error = nil
            } catch {
                search.results = []
                search.error = error
            }
            let id = "s\(index)"
            let phone = await bridge.handle(.init(id: id, name: "web_search", arguments: ["query": "  q "]))
            let watch = WatchToolAnswer.outgoing(id: id, name: "web_search", result: WatchToolAnswer.result(name: "web_search", body: body))
            XCTAssertEqual(phone.map { WatchDirectBroker.wire($0) }, [watch], "web_search body \(index)")
        }

        let recallBodies: [[String: Any]] = [
            ["ok": true, "available": true, "results": "  Eric drinks oolong.  "],
            ["ok": true, "available": true, "results": ""],
            ["ok": true, "available": true, "results": String(repeating: "x", count: 5_000)],
            ["ok": true, "available": false, "reason": "No memory provider is configured."],
            ["ok": false, "status": 504, "detail": "Memory recall timed out"],
        ]
        for (index, body) in recallBodies.enumerated() {
            do {
                memory.results = try GeminiLiveTokenClient.memoryRecall(from: body)
                memory.error = nil
            } catch {
                memory.results = ""
                memory.error = error
            }
            let id = "m\(index)"
            let phone = await bridge.handle(.init(id: id, name: "recall_memory", arguments: ["query": "tea"]))
            let watch = WatchToolAnswer.outgoing(id: id, name: "recall_memory", result: WatchToolAnswer.result(name: "recall_memory", body: body))
            XCTAssertEqual(phone.map { WatchDirectBroker.wire($0) }, [watch], "recall_memory body \(index)")
        }

        for name in ["web_search", "recall_memory"] {
            XCTAssertNil(WatchToolAnswer.query(["query": "  "]))
            let phone = await bridge.handle(.init(id: "e-\(name)", name: name, arguments: [:]))
            let watch = WatchToolAnswer.outgoing(id: "e-\(name)", name: name, result: WatchToolAnswer.missingQuery(name: name))
            XCTAssertEqual(phone.map { WatchDirectBroker.wire($0) }, [watch], name)
        }
        XCTAssertEqual(search.queries.count, searchBodies.count)
        XCTAssertEqual(memory.queries.count, recallBodies.count)
    }

    /// What the host runs for the Watch: the arguments the iPhone's client
    /// sends the same route.
    @MainActor
    func testWatchToolRequestsAskTheHostWhatTheIPhoneWould() throws {
        let search = WatchToolAnswer.request(name: "web_search", query: "weather")
        XCTAssertEqual(search["tool"] as? String, "web_search")
        let searchArgs = try XCTUnwrap(search["args"] as? [String: Any])
        XCTAssertEqual(searchArgs["query"] as? String, "weather")
        XCTAssertEqual(searchArgs["limit"] as? Int, GeminiLiveTokenClient.webSearchLimit)
        let recall = WatchToolAnswer.request(name: "recall_memory", query: "tea")
        XCTAssertEqual(recall["args"] as? [String: String], ["query": "tea"])
        XCTAssertEqual(WatchToolAnswer.query(["query": "  tea "]), "tea")
    }

    @MainActor
    func testWatchToolGrantClientAsksTheProfilesHostAndReadsTheGrant() async throws {
        var asked: [(path: String, method: String, body: [String: Any]?)] = []
        var timeouts: [Int] = []
        let response: [String: Any] = [
            "ok": true,
            "grant_id": Self.watchToolGrant.grantID,
            "relay_url": "https://relay.example.test",
            "key": Self.watchToolGrant.key,
            "watch_key": Self.watchToolGrant.watchKey,
            "expires_at": "2026-10-07T11:00:00Z",
            "tools": ["web_search"],
            "max_calls": 60,
        ]
        let client = WatchToolGrantClient(request: { path, method, body, timeout in
            asked.append((path, method, body))
            timeouts.append(timeout)
            return path.contains("/grant") ? response : ["ok": true, "revoked": true]
        })

        let grant = try await client.grant(tools: ["web_search"], profile: "work")
        XCTAssertEqual(grant.grantID, Self.watchToolGrant.grantID)
        XCTAssertEqual(grant.relayURL, "https://relay.example.test")
        XCTAssertEqual(grant.tools, ["web_search"])
        XCTAssertEqual(grant.maxCalls, 60)
        XCTAssertEqual(grant.expiresAt, Date(timeIntervalSince1970: 1_791_370_800))
        await client.revoke(grantID: grant.grantID, profile: "work")

        XCTAssertEqual(asked.map(\.path), [
            "/api/plugins/conduit_push/watch-tools/grant?profile=work",
            "/api/plugins/conduit_push/watch-tools/revoke?profile=work",
        ])
        XCTAssertEqual(asked.map(\.method), ["POST", "POST"])
        // A hung host holds up the call's setup a few seconds at most.
        XCTAssertEqual(timeouts, [4_000, 4_000])
        XCTAssertEqual(asked.first?.body?["tools"] as? [String], ["web_search"])
        XCTAssertEqual(asked.last?.body?["grant_id"] as? String, grant.grantID)

        var http = response
        http["relay_url"] = "http://relay.example.test"
        XCTAssertNil(WatchToolGrantClient.grant(from: http))
        var keyless = response
        keyless["key"] = nil
        XCTAssertNil(WatchToolGrantClient.grant(from: keyless))
        XCTAssertNil(WatchToolGrantClient.grant(from: ["ok": false, "detail": "not paired"]))
    }

    /// The Watch's side of a relayed lookup, against a stand-in relay that
    /// answers as the host would: sealed both ways, bound to the call.
    @MainActor
    func testWatchToolRelayClientSealsTheCallAndOpensOnlyItsOwnAnswer() async throws {
        let grant = Self.watchToolGrant
        let keys = try XCTUnwrap(WatchToolSeal.Keys(root: Data(0..<32)))
        defer { WatchToolRelayStubProtocol.handler = nil }
        var seen: [URLRequest] = []
        var answerFor: (_ rid: String) throws -> (Int, [String: Any]) = { rid in
            let sealed = try WatchToolSeal.seal(
                WatchToolSeal.json(["ok": true, "query": "weather", "results": [["title": "T", "url": "https://t.example", "snippet": "S"]]]),
                keys: keys, direction: .result, grantID: grant.grantID, rid: rid
            )
            return (200, ["n": sealed.n, "ct": sealed.ct])
        }
        WatchToolRelayStubProtocol.handler = { request, body in
            seen.append(request)
            guard request.httpMethod == "POST" else { return (200, ["ok": true]) }
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            let rid = try XCTUnwrap(envelope["rid"])
            // The host opens it with the call key, bound to this grant and call.
            let opened = try WatchToolSeal.open(.init(n: envelope["n"] ?? "", ct: envelope["ct"] ?? ""), keys: keys, direction: .call, grantID: grant.grantID, rid: rid)
            let call = try XCTUnwrap(JSONSerialization.jsonObject(with: opened) as? [String: Any])
            XCTAssertEqual(call["tool"] as? String, "web_search")
            XCTAssertEqual((call["args"] as? [String: Any])?["query"] as? String, "weather")
            return try answerFor(rid)
        }
        let client = try XCTUnwrap(WatchToolRelayClient(grant, protocolClasses: [WatchToolRelayStubProtocol.self]))
        XCTAssertEqual(client.tools, ["web_search", "recall_memory"])
        XCTAssertFalse(client.canRun("start_job"))

        guard case .answered(let body) = await client.run(name: "web_search", query: "weather") else { return XCTFail("Expected an answer") }
        XCTAssertEqual(WatchToolAnswer.result(name: "web_search", body: body)["results"], "1. T: S (https://t.example)")
        let request = try XCTUnwrap(seen.last)
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example.test/v1/watch-tools/grants/\(grant.grantID)/calls")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(grant.watchKey)")

        // An answer sealed for another call is refused, not read.
        answerFor = { _ in
            let other = try WatchToolSeal.seal(WatchToolSeal.json(["ok": true, "results": [] as [Any]]), keys: keys, direction: .result, grantID: grant.grantID, rid: WatchToolSeal.newRequestID())
            return (200, ["n": other.n, "ct": other.ct])
        }
        guard case .unavailable("unreadableAnswer", false, true) = await client.run(name: "web_search", query: "weather") else { return XCTFail("Expected a refusal") }

        answerFor = { _ in (504, ["error": "host_timeout"]) }
        guard case .timedOut = await client.run(name: "web_search", query: "weather") else { return XCTFail("Expected a timeout") }

        answerFor = { _ in (503, ["error": "host_offline"]) }
        guard case .unavailable(_, false, true) = await client.run(name: "web_search", query: "weather") else { return XCTFail("Expected a fallback") }
        XCTAssertTrue(client.canRun("web_search"))

        // The host's search limit is an answer for the model, not the
        // grant's end.
        answerFor = { rid in
            let sealed = try WatchToolSeal.seal(WatchToolSeal.json(["ok": false, "status": 429, "detail": "Too many web searches; try again shortly"]), keys: keys, direction: .result, grantID: grant.grantID, rid: rid)
            return (200, ["n": sealed.n, "ct": sealed.ct])
        }
        guard case .answered(let limited) = await client.run(name: "web_search", query: "weather") else { return XCTFail("Expected the host's answer") }
        XCTAssertEqual(WatchToolAnswer.result(name: "web_search", body: limited)["error"], "Too many web searches; try again shortly")
        XCTAssertTrue(client.canRun("web_search"))

        // Hermes' own word that the grant is over ends it here too.
        answerFor = { rid in
            let sealed = try WatchToolSeal.seal(WatchToolSeal.json(["ok": false, "status": 410, "detail": "ended"]), keys: keys, direction: .result, grantID: grant.grantID, rid: rid)
            return (200, ["n": sealed.n, "ct": sealed.ct])
        }
        guard case .unavailable(_, true, true) = await client.run(name: "web_search", query: "weather") else { return XCTFail("Expected the grant to end") }
        XCTAssertFalse(client.canRun("web_search"))
        XCTAssertEqual(client.callsSent, 6)
        guard case .unavailable("grantEnded", true, false) = await client.run(name: "web_search", query: "weather") else { return XCTFail("Expected the grant to stay ended") }
        XCTAssertEqual(client.callsSent, 6)

        let closing = expectation(description: "closed on the relay")
        WatchToolRelayStubProtocol.handler = { request, _ in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.absoluteString, "https://relay.example.test/v1/watch-tools/grants/\(grant.grantID)")
            closing.fulfill()
            return (200, ["ok": true])
        }
        client.close()
        client.close()
        await fulfillment(of: [closing], timeout: 5)

        var plain = grant
        plain.relayURL = "http://relay.example.test"
        XCTAssertNil(WatchToolRelayClient(plain))
        // A grant about to expire is skipped, not ended: the iPhone renews it.
        var expiring = grant
        expiring.expiresAt = Date(timeIntervalSinceNow: 10)
        let ending = try XCTUnwrap(WatchToolRelayClient(expiring, protocolClasses: [WatchToolRelayStubProtocol.self]))
        XCTAssertFalse(ending.canRun("web_search"))
        WatchToolRelayStubProtocol.handler = { _, _ in
            XCTFail("An expiring grant sends nothing")
            return (500, [:])
        }
        guard case .unavailable("grantExpiring", false, false) = await ending.run(name: "web_search", query: "weather") else { return XCTFail("Expected it skipped") }
        XCTAssertFalse(ending.isGone)
        XCTAssertEqual(ending.callsSent, 0)
    }
}

/// A stand-in push relay for WatchToolRelayClient: hands each request and
/// its body to `handler`.
private final class WatchToolRelayStubProtocol: URLProtocol {
    static var handler: ((URLRequest, Data) throws -> (Int, [String: Any]))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler, let url = request.url else { throw URLError(.badServerResponse) }
            let (status, body) = try handler(request, Self.body(of: request))
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
                throw URLError(.badURL)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
