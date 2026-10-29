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

    /// #1309: from the tap that starts it until its last words are in, a
    /// dictation keeps Send's slot.
    func testADictationHoldsSendsSlotFromStartUntilItsWordsAreIn() {
        XCTAssertTrue(ComposerDictation.holdsSendSlot(isDictating: false, isStarting: true), "coming up")
        XCTAssertTrue(ComposerDictation.holdsSendSlot(isDictating: true, isStarting: false), "listening or settling")
        XCTAssertFalse(ComposerDictation.holdsSendSlot(isDictating: false, isStarting: false), "over: Send is back")
    }

    func testTheStopInSendsSlotStopsCancelsFinishesOrWaits() {
        func face(capturing: Bool = false, starting: Bool = false, transcribing: Bool = false, canEnd: Bool = false) -> ComposerDictation.SlotFace {
            ComposerDictation.slotFace(isCapturing: capturing, isStarting: starting, isTranscribing: transcribing, settleCanEnd: canEnd)
        }
        XCTAssertEqual(face(capturing: true), .stop)
        XCTAssertEqual(face(starting: true), .cancelStart)
        XCTAssertEqual(face(), .transcribing, "within the usual settle: its last words are still coming")
        XCTAssertEqual(face(canEnd: true), .finishing, "past the usual settle with words in the draft: Done ends it there")
        XCTAssertEqual(face(transcribing: true, canEnd: true), .transcribing, "none of its words are in yet: nothing to tap")
    }

    /// The Stop's tap policy: stop, call off, or wait; never a new
    /// dictation and never a send. Return and the big voice button call the
    /// same `tapSlot()`.
    func testTheStopsTapStopsCallsOffOrWaits() {
        XCTAssertEqual(ComposerDictation.slotTap(.stop), .stop)
        XCTAssertEqual(ComposerDictation.slotTap(.cancelStart), .cancelStart)
        XCTAssertEqual(ComposerDictation.slotTap(.finishing), .cancelStart, "a slow settle ends at once, keeping the draft's words")
        XCTAssertEqual(ComposerDictation.slotTap(.transcribing), .nothing)
    }

    /// Both Apple engines' settles (Speech 1.5 s, SpeechAnalyzer 3 s) end
    /// on their own before Done could cut them short; only a slower one
    /// (Hermes) offers Done.
    func testSettleGraceOutlastsTheAppleSettles() {
        XCTAssertGreaterThan(ComposerDictationService.settleGrace, .seconds(3))
    }
}
