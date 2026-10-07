//
//  WatchVoiceWireTests.swift
//  Conduit
//
//  Apple Watch proof of concept (designs/apple-watch-voice.md): the link
//  format, audio codec and measurements both devices share. Written as an
//  extension of an existing suite: the CI test planner is at capacity for
//  new XCTestCase classes.
//

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
            .directTokenIssued(callID: 7, token: token),
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
}
