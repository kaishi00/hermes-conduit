//
//  DictationEngineTests.swift
//  ConduitTests
//
//  The dictation engine choice and custom words. An extension of an
//  existing class, so CI plans no new test class.
//

import XCTest
@testable import Conduit

extension ComposerFullEditorTests {
    func testDictationEngineFallsBackToApple() {
        let all: (DictationEngine) -> Bool = { _ in true }
        XCTAssertEqual(DictationEngine.resolved(nil, isSupported: all), .apple)
        XCTAssertEqual(DictationEngine.resolved("whisper", isSupported: all), .apple, "unknown choices read as Apple")
        XCTAssertEqual(DictationEngine.resolved("hermes", isSupported: all), .hermes)
        XCTAssertEqual(
            DictationEngine.resolved("appleSpeechAnalyzer", isSupported: { $0 != .appleSpeechAnalyzer }),
            .apple,
            "the new model on an iPhone without it reads as Apple"
        )
    }

    func testCustomWordsKeepSpellingAndDropRepeats() {
        XCTAssertEqual(
            DictationCustomWords.canonicalized(["  Milim  ", "milim", "", "   ", "Hermes   Conduit", "OpenAI"]),
            ["Milim", "Hermes Conduit", "OpenAI"]
        )
        let many = (0..<150).map { "word\($0)" }
        XCTAssertEqual(DictationCustomWords.canonicalized(many).count, DictationCustomWords.maximumCount)
        XCTAssertEqual(DictationCustomWords.canonicalized(String(repeating: "a", count: 200)).count, DictationCustomWords.maximumLength)
    }

    func testCustomWordsRoundTripThroughDefaults() throws {
        let suite = "DictationWords.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(DictationCustomWords.load(defaults: defaults), [])
        DictationCustomWords.save(["Acme", "acme", "Zyx Corp"], defaults: defaults)
        XCTAssertEqual(DictationCustomWords.load(defaults: defaults), ["Acme", "Zyx Corp"])
        DictationCustomWords.save([], defaults: defaults)
        XCTAssertNil(defaults.object(forKey: DictationCustomWords.preferenceKey))
    }

    func testAnalyzerTranscriptKeepsFinishedTextAndReplacesTheGuess() {
        var transcript = AnalyzerTranscript()
        transcript.receive("Hello", isFinal: false)
        transcript.receive("Hello there", isFinal: false)
        XCTAssertEqual(transcript.text, "Hello there")
        transcript.receive("Hello there.", isFinal: true)
        XCTAssertEqual(transcript.text, "Hello there.")
        transcript.receive("Send it to", isFinal: false)
        XCTAssertEqual(transcript.text, "Hello there. Send it to")
        transcript.receive(" Send it to Milim.", isFinal: true)
        XCTAssertEqual(transcript.text, "Hello there. Send it to Milim.")
    }

    func testATapWhileTranscribingWaitsForTheWords() {
        XCTAssertEqual(
            ComposerDictation.tap(isCapturing: false, isStarting: false, canDictate: true, isTranscribing: true),
            .nothing
        )
        XCTAssertEqual(
            ComposerDictation.tap(isCapturing: false, isStarting: false, canDictate: true, isTranscribing: false),
            .start
        )
    }
}
