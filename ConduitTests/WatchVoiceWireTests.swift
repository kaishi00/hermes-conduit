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
}
