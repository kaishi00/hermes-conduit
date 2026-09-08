//
//  VoiceSpeechDetector.swift
//  Conduit
//
//  Adaptive listening-side speech detection for Voice Conversation
// (issue #130). The legacy detector required every sample to exceed one
// fixed global threshold, so quiet-but-valid speech (typical peaks
// 0.02–0.05) was never recognized and the session sat in Listening until
// the idle pause. This detector instead learns the ambient noise floor of
// the current capture window and accepts speech that rises clearly above
// it, while never becoming more sensitive than the conservative threshold
// that acoustic barge-in continues to use.
//

import Foundation

/// Centralized, test-covered constants for the adaptive speech detector.
/// All levels are linear PCM peaks in 0...1.
struct VoiceSpeechDetectorConstants: Equatable {
    /// Speech-start requires a rise above the observed noise floor by this
    /// factor, clamped between the absolute minimum and the conservative
    /// ceiling.
    var noiseFloorSpeechRiseFactor: Float = 3
    /// Absolute lower bound for the speech-start threshold so a near-silent
    /// floor cannot let tiny electrical hum count as speech.
    var minimumSpeechStartThreshold: Float = 0.012
    /// Ceiling for the adaptive speech-start threshold, identical to the
    /// conservative barge-in threshold: adaptive detection can never become
    /// more sensitive than the legacy fixed behavior. Samples at or above
    /// it are unambiguous speech and start an utterance immediately.
    var maximumSpeechStartThreshold: Float = 0.075
    /// While an utterance is active this lower (hysteresis) factor keeps
    /// speech alive through brief level dips.
    var speechContinuationRiseFactor: Float = 1.6
    /// Absolute lower bound for the continuation threshold.
    var minimumSpeechContinuationThreshold: Float = 0.006
    /// Consecutive candidate samples required before a sub-ceiling rise is
    /// accepted as speech: a single isolated noisy buffer never starts a
    /// turn.
    var speechStartDebounceSamples = 2
    /// Bound on speech-plausible warmup samples that arrive before any
    /// genuinely quiet sample: past this many skips the warmup force-arms
    /// (falling back to the conservative ceiling-only behavior), so a
    /// permanently loud room can never stay disarmed forever.
    var maximumWarmupSkips = 12
    /// Fresh capture windows spend this many events establishing the noise
    /// floor (with fast adaptation) before sub-ceiling speech-start is
    /// armed, so a loud room cannot misclassify its own ambience during
    /// cold start.
    var warmupEvents = 4
    /// Noise-floor adaptation speed while warming up a fresh window.
    var warmupAdaptationAlpha: Float = 0.4
    /// Noise-floor adaptation speed toward quieter input.
    var noiseFloorFallAlpha: Float = 0.2
    /// Noise-floor adaptation speed toward louder input while no speech is
    /// active.
    var noiseFloorRiseAlpha: Float = 0.06
    /// Initial and absolute-minimum noise floor estimate.
    var minimumNoiseFloor: Float = 0.003
    /// Sanity ceiling for the noise floor estimate.
    var maximumNoiseFloor: Float = 0.5
}

enum VoiceSpeechDetection: Equatable {
    /// Noise: not speech.
    case none
    /// Speech continues (hysteresis path while an utterance is active).
    case continued
    /// Speech start accepted.
    case started
}

struct VoiceSpeechDetector {
    private(set) var constants: VoiceSpeechDetectorConstants
    /// Asymmetric EMA of observed input while no speech is active.
    private(set) var noiseFloor: Float
    private var warmupRemaining: Int
    private var warmupSkippedSamples = 0
    private var candidateSamples = 0
    private(set) var isSpeechActive = false

    init(constants: VoiceSpeechDetectorConstants = .init()) {
        self.constants = constants
        noiseFloor = constants.minimumNoiseFloor
        warmupRemaining = constants.warmupEvents
    }

    /// Noise-floor-relative level that continues an active utterance
    /// (hysteresis: lower than the speech-start threshold).
    private var speechContinuationThreshold: Float {
        max(
            constants.minimumSpeechContinuationThreshold,
            noiseFloor * constants.speechContinuationRiseFactor
        )
    }

    /// Noise-floor-relative speech-start threshold for the current window,
    /// clamped between the absolute minimum and the conservative ceiling.
    private var speechStartThreshold: Float {
        let floorRise = noiseFloor * constants.noiseFloorSpeechRiseFactor
        return max(
            constants.minimumSpeechStartThreshold,
            min(constants.maximumSpeechStartThreshold, floorRise)
        )
    }

    mutating func observe(_ level: Float) -> VoiceSpeechDetection {
        // Garbage samples (NaN, negative) must not poison the noise floor
        // or wedge threshold comparisons; treat them as silence.
        guard level.isFinite, level >= 0 else {
            candidateSamples = 0
            return .none
        }
        if isSpeechActive {
            // Hysteresis: an active utterance survives level dips via the
            // lower continuation threshold; trailing-silence timing stays
            // with the controller.
            return level >= speechContinuationThreshold ? .continued : .none
        }
        if warmupRemaining > 0 {
            // Fresh window: establish the floor before sub-ceiling
            // speech-start is armed. Genuinely quiet samples teach the floor
            // fast and advance the warmup. Speech-plausible samples at cold
            // start are ambiguous — they must not start speech, and they
            // must not be learned as noise quickly — so they only creep the
            // floor up slowly with a bounded skip count: a permanently loud
            // room still arms (falling back to the conservative ceiling-only
            // behavior) within a fraction of a second, while an immediately
            // speaking user is merely delayed, never swallowed permanently.
            if level < constants.minimumSpeechStartThreshold {
                adaptNoiseFloor(
                    level,
                    alpha: constants.warmupAdaptationAlpha,
                    ceiling: constants.minimumSpeechStartThreshold
                )
                warmupRemaining -= 1
                warmupSkippedSamples = 0
            } else {
                adaptNoiseFloor(
                    level,
                    alpha: constants.noiseFloorRiseAlpha,
                    ceiling: constants.maximumNoiseFloor
                )
                warmupSkippedSamples += 1
                if warmupSkippedSamples >= constants.maximumWarmupSkips {
                    warmupRemaining = 0
                }
            }
            if level >= constants.maximumSpeechStartThreshold {
                // An unambiguous level is speech even before the floor has
                // been established.
                isSpeechActive = true
                return .started
            }
            return .none
        }
        if level >= constants.maximumSpeechStartThreshold {
            // At or above the conservative legacy threshold the sample is
            // unambiguous speech and starts immediately.
            isSpeechActive = true
            candidateSamples = 0
            return .started
        }
        guard level >= speechStartThreshold else {
            // Clearly below the start threshold: ambient input adapts the
            // floor, and any pending candidate was an isolated spike.
            candidateSamples = 0
            adaptNoiseFloor(
                level,
                alpha: level < noiseFloor
                    ? constants.noiseFloorFallAlpha
                    : constants.noiseFloorRiseAlpha,
                ceiling: constants.maximumNoiseFloor
            )
            return .none
        }
        // Suspected speech onset: count it, but never feed it to the floor —
        // raising the threshold mid-onset would swallow real speech.
        candidateSamples += 1
        guard candidateSamples >= constants.speechStartDebounceSamples else { return .none }
        isSpeechActive = true
        candidateSamples = 0
        return .started
    }

    /// Clears speech state and the learned noise floor so nothing from one
    /// capture window shapes the next one.
    mutating func reset() {
        noiseFloor = constants.minimumNoiseFloor
        warmupRemaining = constants.warmupEvents
        warmupSkippedSamples = 0
        candidateSamples = 0
        isSpeechActive = false
    }

    /// Tracks the ambient level with an asymmetric EMA: quiet input pulls
    /// the floor down quickly, louder input raises it slowly, and suspected
    /// speech never feeds it. During warmup the floor is additionally
    /// capped at the minimum speech-start threshold, so speech-level input
    /// arriving at cold start can never raise the threshold above the
    /// point where that same speech stays detectable.
    /// Moves the noise floor toward `level` by `alpha` (EMA), clamped to
    /// `ceiling`. Asymmetry lives at the call sites: quiet input pulls the
    /// floor down fast, louder input raises it slowly, suspected speech
    /// never feeds it, and warmup caps the floor at the minimum start
    /// threshold so speech-level input at cold start is never learned as
    /// noise.
    private mutating func adaptNoiseFloor(_ level: Float, alpha: Float, ceiling: Float) {
        noiseFloor += (level - noiseFloor) * alpha
        noiseFloor = min(ceiling, max(constants.minimumNoiseFloor, noiseFloor))
    }
}
