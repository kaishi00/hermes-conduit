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
                .none, .started, .continued, .continued,
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
        XCTAssertEqual(detector.observe(0.026), .none)
        XCTAssertEqual(detector.observe(0.03), .started, "two consecutive quiet-of-legacy samples accept speech")

        // Below the speech-start threshold but above the hysteresis floor:
        // an active utterance keeps going.
        XCTAssertEqual(detector.observe(0.008), .continued)
        XCTAssertEqual(detector.observe(0.002), .none, "true silence does not continue speech")
    }

    func testResetClearsSpeechAndWarmupState() {
        var detector = VoiceSpeechDetector()
        for _ in 0..<6 { _ = detector.observe(0.003) }
        XCTAssertEqual(detector.observe(0.026), .none)
        XCTAssertEqual(detector.observe(0.03), .started)

        // A completed utterance resets everything: warmup re-arms, speech is
        // inactive, and the floor re-learns from the fresh window.
        detector.reset()
        XCTAssertTrue(detector.noiseFloor <= 0.004, "the floor must not carry the previous window's estimate")
        for _ in 0..<4 { _ = detector.observe(0.003) }
        XCTAssertEqual(detector.observe(0.018), .none)
        XCTAssertEqual(detector.observe(0.026), .started, "quiet speech is recognized again in the new window")
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
        XCTAssertEqual(detector.observe(0.026), .started, "the detector still works after non-finite input")
    }

    func testThresholdBoundaries() {
        // Quiet room: the adaptive start threshold sits at its absolute
        // minimum, and the minimum still needs corroboration.
        var quiet = VoiceSpeechDetector()
        for _ in 0..<6 { _ = quiet.observe(0.003) }
        XCTAssertEqual(quiet.observe(0.012), .none, "the minimum start threshold needs a second candidate")
        XCTAssertEqual(quiet.observe(0.012), .started)

        // Louder room: the adapted threshold rises toward its ceiling, and
        // a sample exactly at the conservative ceiling starts immediately.
        var louder = VoiceSpeechDetector()
        for _ in 0..<6 { _ = louder.observe(0.02) }
        XCTAssertEqual(louder.observe(0.075), .started, "the conservative ceiling starts immediately even when adapted higher")
    }

    func testImmediateQuietSpeechDuringWarmupIsNotLearnedAsNoise() {
        var detector = VoiceSpeechDetector()
        // The user starts speaking immediately, inside the warmup window:
        // speech-level samples must not raise the learned floor above the
        // minimum start threshold, or the whole utterance gets swallowed.
        for sample: Float in [0.018, 0.026, 0.034, 0.028] {
            XCTAssertEqual(detector.observe(sample), .none)
        }
        XCTAssertLessThanOrEqual(
            detector.noiseFloor,
            VoiceSpeechDetectorConstants().minimumSpeechStartThreshold,
            "warmup must never learn speech-level input as the noise floor"
        )

        // After a few genuinely quiet samples the floor settles and the
        // same quiet speech is recognized again — it was never permanently
        // learned as noise.
        for _ in 0..<8 { _ = detector.observe(0.004) }
        XCTAssertEqual(detector.observe(0.026), .none, "the first quiet sample is a single candidate")
        XCTAssertEqual(detector.observe(0.026), .started, "quiet speech is recognized again after the floor settles")
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
