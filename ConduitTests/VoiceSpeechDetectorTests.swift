import XCTest
@testable import Conduit

/// Deterministic coverage for the adaptive listening-side speech detector
/// (issue #130): quiet-but-valid speech must be accepted, steady ambient
/// noise must never become a turn, and the threshold must adapt to the
/// observed room.
final class VoiceSpeechDetectorTests: XCTestCase {
    func testQuietSpeechRiseAboveNearSilenceFloorIsAccepted() {
        var detector = VoiceSpeechDetector()
        var detections: [VoiceSpeechDetection] = []
        // Ambient floor covers the detector warmup, then quiet speech whose
        // peaks never reach the legacy fixed threshold.
        let samples: [Float] = [
            0.003, 0.004, 0.003, 0.003,
            0.018, 0.026, 0.034, 0.028,
            0.004, 0.003
        ]
        for sample in samples {
            detections.append(detector.observe(sample))
        }

        XCTAssertEqual(
            detections,
            [
                .none, .none, .none, .none,
                .none, .none, .none, .started,
                .none, .none
            ],
            "a clear rise above the observed noise floor must be accepted as speech"
        )
    }

    func testSteadyAmbientNoiseNeverBecomesSpeech() {
        var detector = VoiceSpeechDetector()
        let detections = (0..<120).map { _ in detector.observe(0.015) }

        XCTAssertFalse(detections.contains(.started), "constant room noise must never produce phantom speech")
        XCTAssertTrue(detections.allSatisfy { $0 == .none })
    }

    func testLouderRoomFloorAdaptsAndRelativeSpeechRiseIsAccepted() {
        var detector = VoiceSpeechDetector()
        // Establish a louder noise floor…
        for _ in 0..<40 { _ = detector.observe(0.02) }
        // …then inject speech below the legacy fixed threshold but clearly
        // above the adapted floor (floor ≈ 0.02 → threshold ≈ 0.059).
        var detections: [VoiceSpeechDetection] = []
        for sample: Float in [0.065, 0.07, 0.06] {
            detections.append(detector.observe(sample))
        }

        // Full sequence: the first quiet sample is a single candidate
        // (still .none), then the corroborating samples accept speech.
        XCTAssertEqual(detections, [.none, .started, .continued], "the relative rise must be recognized")
    }

    func testWindowOpenedMidSpeechEndsOverRoomNoiseWithALearnedFloor() {
        // A steer window opens while the user is already speaking: a cold
        // start hears only speech and keeps the minimum floor, so room
        // noise counts as more speech.
        var cold = VoiceSpeechDetector()
        XCTAssertEqual(cold.observe(0.2), .started)
        XCTAssertEqual(cold.observe(0.012), .continued, "room noise holds a cold window's utterance open")

        // Started from the floor learned before the window, the same room
        // noise is silence and the utterance can end.
        var seeded = VoiceSpeechDetector()
        seeded.reset(learnedNoiseFloor: 0.012)
        XCTAssertEqual(seeded.observe(0.2), .started)
        XCTAssertEqual(seeded.observe(0.012), .none)
    }

    func testGarbageLearnedFloorKeepsTheColdStart() {
        var detector = VoiceSpeechDetector()
        detector.reset(learnedNoiseFloor: .nan)
        XCTAssertEqual(detector.noiseFloor, detector.constants.minimumNoiseFloor)
        XCTAssertEqual(detector.observe(0.2), .started)
        XCTAssertEqual(detector.observe(0.012), .continued, "a NaN floor is ignored, not adopted")
    }

    // MARK: Room floor learned while Hermes thinks

    /// Feeds `levels` in order, one every 20 ms (about the tap's rate).
    private func feed(
        _ room: inout VoiceRoomNoiseFloor, _ levels: [Float], from start: Date
    ) -> Date {
        var date = start
        for level in levels {
            room.observe(level, at: date)
            date = date.addingTimeInterval(0.02)
        }
        return date
    }

    func testRoomFloorLearnsSteadyRoomNoise() {
        var room = VoiceRoomNoiseFloor()
        XCTAssertNil(room.floor, "nothing heard yet: a steer cold-starts as before")
        _ = feed(&room, Array(repeating: 0.012, count: 60), from: Date())
        XCTAssertEqual(room.floor ?? 0, 0.012, accuracy: 0.001)
    }

    func testQuietSpeechWhileThinkingDoesNotRaiseTheRoomFloor() {
        var room = VoiceRoomNoiseFloor()
        let end = feed(&room, Array(repeating: 0.012, count: 75), from: Date())
        // Speech too quiet to open a steer window, over three seconds.
        let words: [Float] = [0.03, 0.045, 0.02, 0.05, 0.035, 0.008]
        _ = feed(&room, Array(Array(repeating: words, count: 25).joined()), from: end)

        let floor = room.floor ?? 1
        XCTAssertLessThanOrEqual(floor, 0.0121, "quiet speech must not teach the room")
        // A steer window started from that floor still hears the speech.
        var detector = VoiceSpeechDetector()
        detector.reset(learnedNoiseFloor: floor)
        XCTAssertEqual(detector.observe(0.1), .started)
        XCTAssertEqual(detector.observe(0.03), .continued)
    }

    func testQuietSpeechAfterALongQuietRoomStillHasToHoldSteady() {
        var room = VoiceRoomNoiseFloor()
        let end = feed(&room, Array(repeating: 0.012, count: 100), from: Date())
        // Speech just over the room, with dips back to it: the long quiet
        // run before it must not count as the speech holding steady.
        let words: [Float] = [0.021, 0.023, 0.012, 0.022, 0.02, 0.012]
        _ = feed(&room, Array(Array(repeating: words, count: 25).joined()), from: end)
        XCTAssertLessThanOrEqual(room.floor ?? 1, 0.0121)
    }

    func testARunDoesNotSpanUnheardTime() {
        var room = VoiceRoomNoiseFloor()
        _ = feed(&room, Array(repeating: 0.005, count: 5), from: Date())
        // Suspected speech, then nothing heard for two seconds (a steer
        // window, playback), then the same level once.
        let start = Date().addingTimeInterval(1)
        room.observe(0.03, at: start)
        room.observe(0.03, at: start.addingTimeInterval(2))
        XCTAssertEqual(room.floor ?? 0, 0.005, accuracy: 0.0005)
    }

    func testRoomFloorFollowsARoomThatGetsLouder() {
        var room = VoiceRoomNoiseFloor()
        let end = feed(&room, Array(repeating: 0.012, count: 75), from: Date())
        // A fan comes on: steady, so it becomes the room within seconds.
        _ = feed(&room, Array(repeating: 0.04, count: 300), from: end)
        XCTAssertGreaterThan(room.floor ?? 0, 0.03)
    }

    func testAHeldVowelBarelyMovesTheRoomFloor() {
        var room = VoiceRoomNoiseFloor()
        let end = feed(&room, Array(repeating: 0.012, count: 75), from: Date())
        // Two seconds of a flat "ummm" just too quiet to steer.
        _ = feed(&room, Array(repeating: 0.03, count: 100), from: end)
        let floor = room.floor ?? 1
        XCTAssertLessThan(floor, 0.02)
        var detector = VoiceSpeechDetector()
        detector.reset(learnedNoiseFloor: floor)
        XCTAssertEqual(detector.observe(0.1), .started)
        XCTAssertEqual(detector.observe(0.03), .continued, "the same level still reads as speech in a steer")
    }

    func testRoomFloorIgnoresGarbageAndForgetsOnReset() {
        var room = VoiceRoomNoiseFloor()
        let end = feed(&room, Array(repeating: 0.008, count: 10), from: Date())
        room.observe(.nan, at: end)
        room.observe(-1, at: end)
        XCTAssertEqual(room.floor ?? 0, 0.008, accuracy: 0.0005)
        room.reset()
        XCTAssertNil(room.floor)
    }

    func testSingleIsolatedSpikeDoesNotStartSpeech() {
        var detector = VoiceSpeechDetector()
        for _ in 0..<6 { _ = detector.observe(0.003) }

        XCTAssertEqual(detector.observe(0.03), .none, "one isolated noisy sample must not start a turn")
        XCTAssertEqual(detector.observe(0.003), .none, "the candidate must reset after a quiet sample")
        XCTAssertEqual(detector.observe(0.03), .none, "a new isolated spike starts counting from zero")
    }

    func testSpeechContinuationUsesLowerHysteresisThreshold() {
        var detector = VoiceSpeechDetector()
        for _ in 0..<6 { _ = detector.observe(0.003) }
        // Four speech-plausible samples with natural variation fill the
        // cold-start dynamics window (range 0.014 ≥ 0.012).
        let run: [Float] = [0.026, 0.038, 0.024, 0.032]
        var detections: [VoiceSpeechDetection] = []
        for (index, sample) in run.enumerated() {
            detections.append(detector.observe(sample))
            if index < run.count - 1 {
                // A partial window must not start a turn.
                XCTAssertFalse(detections.last == .started)
            }
        }
        XCTAssertEqual(detections.last, .started, "the varied run is accepted as speech onset")

        // Below the speech-start threshold but above the hysteresis floor:
        // an active utterance keeps going.
        XCTAssertEqual(detector.observe(0.008), .continued)
        XCTAssertEqual(detector.observe(0.002), .none, "true silence does not continue speech")
    }

    func testResetClearsSpeechAndColdStartState() {
        var detector = VoiceSpeechDetector()
        for _ in 0..<6 { _ = detector.observe(0.003) }
        // A varied sub-ceiling run fills the cold-start dynamics window.
        let run: [Float] = [0.02, 0.026, 0.038, 0.03]
        var detections: [VoiceSpeechDetection] = []
        for sample in run {
            detections.append(detector.observe(sample))
        }
        XCTAssertEqual(detections.last, .started, "the varied run is accepted as speech onset")

        // A completed utterance resets everything: cold start re-arms, the
        // floor re-learns from the fresh window, and quiet speech is
        // recognized again.
        detector.reset()
        XCTAssertTrue(detector.noiseFloor <= 0.004, "the floor must not carry the previous window's estimate")
        for _ in 0..<4 { _ = detector.observe(0.003) }
        XCTAssertEqual(detector.observe(0.018), .none)
        XCTAssertEqual(detector.observe(0.026), .none)
        XCTAssertEqual(detector.observe(0.034), .none)
        XCTAssertEqual(detector.observe(0.028), .started, "quiet speech is recognized again in the new window")
    }

    func testClearLoudSampleStartsImmediatelyEvenDuringWarmup() {
        var detector = VoiceSpeechDetector()
        XCTAssertEqual(detector.observe(0.1), .started, "an unambiguous level is speech regardless of warmup")
    }

    func testNonFiniteLevelsAreIgnoredWithoutPoisoningTheFloor() {
        var detector = VoiceSpeechDetector()
        for _ in 0..<6 { _ = detector.observe(0.003) }

        XCTAssertEqual(detector.observe(Float.nan), .none)
        XCTAssertTrue(detector.noiseFloor.isFinite, "non-finite input must not poison the noise floor")
        XCTAssertEqual(detector.observe(0.026), .none, "the garbage sample must not become a candidate")

        // The detector still works after non-finite input: an unambiguous
        // level starts speech, and the floor was never poisoned.
        XCTAssertEqual(detector.observe(0.5), .started)
        XCTAssertTrue(detector.noiseFloor.isFinite)
    }

    func testThresholdBoundaries() {
        // Quiet room, fully calibrated: the adaptive start threshold sits at
        // its absolute minimum, and the minimum still needs corroboration.
        var quiet = VoiceSpeechDetector()
        for _ in 0..<16 { _ = quiet.observe(0.003) }
        XCTAssertEqual(quiet.observe(0.012), .none, "the minimum start threshold needs a second candidate")
        XCTAssertEqual(quiet.observe(0.012), .started)

        // Louder room: the adapted threshold rises toward its ceiling, and
        // a sample exactly at the conservative ceiling starts immediately.
        var louder = VoiceSpeechDetector()
        for _ in 0..<6 { _ = louder.observe(0.02) }
        XCTAssertEqual(louder.observe(0.075), .started, "the conservative ceiling starts immediately even when adapted higher")
    }

    func testSteadyLoudAmbientNoiseFromColdStartNeverBecomesSpeech() {
        var detector = VoiceSpeechDetector()
        // A permanently loud room: steady elevated ambience calibrates the
        // floor (never starts a turn) and ceiling-only detection applies
        // afterward.
        let detections = (0..<40).map { _ in detector.observe(0.05) }
        XCTAssertTrue(detections.allSatisfy { $0 == .none }, "steady loud ambience must never be classified as speech")
        XCTAssertEqual(detector.noiseFloor, 0.05, accuracy: 0.005, "the steady signal becomes the calibrated floor")
    }

    func testCalibratedLoudRoomRecognizesLaterVariableRise() {
        var detector = VoiceSpeechDetector()
        for _ in 0..<40 { _ = detector.observe(0.05) }
        XCTAssertEqual(detector.noiseFloor, 0.05, accuracy: 0.005)

        // A genuine variable rise above the calibrated floor is speech even
        // though the room calibrated loud.
        let samples: [Float] = [0.09, 0.12, 0.08, 0.11]
        let detections = samples.map { detector.observe($0) }
        XCTAssertTrue(detections.contains(.started), "a later real rise must still be recognized in a loud room")
    }

    /// In a room calibrated loud the start threshold is capped at the
    /// ceiling (0.075) while the floor-relative continuation threshold
    /// (floor × 1.6 ≈ 0.08) is not: a level that would have started the
    /// utterance must still continue it, not end the turn mid-speech.
    func testCalibratedLoudRoomContinuesAtLevelsThatCouldStartSpeech() {
        var detector = VoiceSpeechDetector()
        for _ in 0..<40 { _ = detector.observe(0.05) }
        XCTAssertEqual(detector.noiseFloor, 0.05, accuracy: 0.005)
        XCTAssertEqual(detector.observe(0.09), .started)

        XCTAssertEqual(detector.observe(0.078), .continued, "a level above the start ceiling continues speech")
        XCTAssertEqual(detector.observe(0.075), .continued, "the start ceiling itself continues speech")
        // With the band collapsed at the ceiling, a dip below it is silence;
        // trailing-silence timing lives with the controller.
        XCTAssertEqual(detector.observe(0.05), .none, "the calibrated floor still ends speech")
    }

    func testImmediateQuietSpeechWithNaturalDynamicsIsAccepted() {
        var detector = VoiceSpeechDetector()

        // A user who starts talking at capture frame 1, with no initial
        // silence: natural amplitude variation over a sustained run.
        let samples: [Float] = [
            0.018, 0.024, 0.032, 0.027,
            0.035, 0.023, 0.031, 0.026,
            0.034, 0.021
        ]

        let detections = samples.map {
            detector.observe($0)
        }

        XCTAssertTrue(
            detections.contains(.started),
            "quiet speech beginning at capture frame 1 must not require the user to stop and try again"
        )
        // The suspected-speech window must not have been taught into the
        // noise floor: speech-level cold-start input is never learned as
        // ambience.
        XCTAssertLessThanOrEqual(
            detector.noiseFloor,
            VoiceSpeechDetectorConstants().minimumSpeechStartThreshold
        )
    }
}

/// Presentation-only mapping tests, independent of the VAD tests.
final class VoiceLevelMeterMathTests: XCTestCase {
    func testZeroAndNearZeroMapToEmpty() {
        XCTAssertEqual(VoiceLevelMeterMath.displayFraction(forLevel: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(VoiceLevelMeterMath.displayFraction(forLevel: 0.0001), 0, accuracy: 0.0001)
        XCTAssertEqual(VoiceLevelMeterMath.displayFraction(forLevel: -0.5), 0, accuracy: 0.0001)
        XCTAssertEqual(VoiceLevelMeterMath.displayFraction(forLevel: .nan), 0, accuracy: 0.0001)
    }

    func testQuietVoiceMapsToVisibleNonzeroFraction() {
        let quiet = VoiceLevelMeterMath.displayFraction(forLevel: 0.034)
        XCTAssertEqual(quiet, 0.51, accuracy: 0.02, "typical quiet speech sits near the meter midpoint")
        XCTAssertGreaterThan(quiet, 0.2)
    }

    func testMediumInputMapsLargerThanQuiet() {
        let quiet = VoiceLevelMeterMath.displayFraction(forLevel: 0.034)
        let medium = VoiceLevelMeterMath.displayFraction(forLevel: 0.1)
        XCTAssertEqual(medium, 2.0 / 3.0, accuracy: 0.01)
        XCTAssertGreaterThan(medium, quiet)
    }

    func testFullScaleInputClampsToFull() {
        XCTAssertEqual(VoiceLevelMeterMath.displayFraction(forLevel: 1), 1, accuracy: 0.0001)
        XCTAssertEqual(VoiceLevelMeterMath.displayFraction(forLevel: 5), 1, accuracy: 0.0001, "over-range input clamps")
        XCTAssertEqual(VoiceLevelMeterMath.displayFraction(forLevel: .infinity), 1, accuracy: 0.0001, "+Inf is full scale")
    }
}
