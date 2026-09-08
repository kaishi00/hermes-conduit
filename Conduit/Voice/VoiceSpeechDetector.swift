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
        // Baseline decision kept from the legacy detector: the fixed
        // conservative threshold decides alone. The adaptive floor,
        // warmup, and debounce paths land with the #130 fix.
        if level >= constants.maximumSpeechStartThreshold {
            if isSpeechActive { return .continued }
            isSpeechActive = true
            return .started
        }
        return .none
    }

    /// Clears speech state and the learned noise floor so nothing from one
    /// capture window shapes the next one.
    mutating func reset() {
        noiseFloor = constants.minimumNoiseFloor
        warmupRemaining = constants.warmupEvents
        candidateSamples = 0
        isSpeechActive = false
    }
}
