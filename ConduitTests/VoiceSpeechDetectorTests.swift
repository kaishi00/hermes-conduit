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
