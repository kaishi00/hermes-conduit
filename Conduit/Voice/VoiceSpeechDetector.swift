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
    /// Bounded length of the cold-start calibration phase, in events: once
    /// it expires without speech-like dynamics, the steady signal becomes
    /// the calibrated ambient floor and normal adaptive detection arms.
    var coldStartMaximumEvents = 16
    /// Speech-plausible samples retained for the cold-start dynamics check.
    var coldStartCandidateSamples = 4
    /// Cold-start speech onset requires the candidate window to vary by at
    /// least this much between its quietest and loudest sample: steady input
    /// is ambience, modulated input is speech.
    var coldStartMinimumDynamicRange: Float = 0.012
    /// Noise-floor adaptation speed for genuinely quiet samples during cold
    /// start.
    var coldStartQuietAdaptationAlpha: Float = 0.4
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
    private var coldStartRemaining: Int
    /// Recent speech-plausible samples during cold start, for the dynamics
    /// check that distinguishes speech from steady ambience.
    private var coldStartWindow: [Float] = []
    private var candidateSamples = 0
    private(set) var isSpeechActive = false

    init(constants: VoiceSpeechDetectorConstants = .init()) {
        self.constants = constants
        noiseFloor = constants.minimumNoiseFloor
        coldStartRemaining = constants.coldStartMaximumEvents
    }

    /// Noise-floor-relative level that continues an active utterance
    /// (hysteresis: never stricter than the speech-start threshold). In a
    /// loud room the adaptive start threshold is capped at the conservative
    /// ceiling while the uncapped floor-relative continuation threshold can
    /// exceed it — a level that just started the utterance would then count
    /// as silence and end the turn mid-speech — so the onset threshold caps
    /// continuation too.
    private var speechContinuationThreshold: Float {
        min(
            speechStartThreshold,
            max(
                constants.minimumSpeechContinuationThreshold,
                noiseFloor * constants.speechContinuationRiseFactor
            )
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
        if coldStartRemaining > 0 {
            coldStartRemaining -= 1
            // An unambiguous level is speech even before the floor has been
            // established (a user speaking from the very first frame).
            if level >= constants.maximumSpeechStartThreshold {
                isSpeechActive = true
                return .started
            }
            if level < constants.minimumSpeechStartThreshold {
                // Quiet ambience teaches the floor fast.
                adaptNoiseFloor(
                    level,
                    alpha: constants.coldStartQuietAdaptationAlpha,
                    ceiling: constants.minimumSpeechStartThreshold
                )
                coldStartWindow.removeAll()
                return .none
            }
            // Speech-plausible input at cold start is ambiguous — it must
            // neither start speech against an unlearned floor nor be learned
            // as noise — so it is collected for a dynamics check: real
            // speech varies; steady ambience does not.
            coldStartWindow.append(level)
            if coldStartWindow.count > constants.coldStartCandidateSamples {
                coldStartWindow.removeFirst()
            }
            if coldStartWindow.count == constants.coldStartCandidateSamples,
               let loudest = coldStartWindow.max(), let quietest = coldStartWindow.min(),
               loudest - quietest >= constants.coldStartMinimumDynamicRange {
                isSpeechActive = true
                coldStartWindow.removeAll()
                return .started
            }
            if coldStartRemaining == 0 {
                // The bounded cold start expires on a steady speech-plausible
                // run: adopt its mean as the ambient floor and arm normal
                // adaptive detection against it — no phantom, and a later
                // genuine rise is still recognized.
                noiseFloor = min(
                    constants.maximumNoiseFloor,
                    max(
                        constants.minimumNoiseFloor,
                        coldStartWindow.reduce(0, +) / Float(coldStartWindow.count)
                    )
                )
                coldStartWindow.removeAll()
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
        coldStartRemaining = constants.coldStartMaximumEvents
        coldStartWindow.removeAll()
        candidateSamples = 0
        isSpeechActive = false
    }

    /// Clears speech state like `reset()`, but starts from a floor learned
    /// before the window opened instead of a cold start. A steer window
    /// opens while the user is already speaking: its cold start would hear
    /// only speech, keep the floor at the minimum, and the room's own noise
    /// would then hold the utterance open after the user stopped.
    mutating func reset(learnedNoiseFloor: Float) {
        reset()
        // A garbage floor keeps the plain cold start.
        guard learnedNoiseFloor.isFinite, learnedNoiseFloor >= 0 else { return }
        adaptNoiseFloor(learnedNoiseFloor, alpha: 1, ceiling: constants.maximumNoiseFloor)
        coldStartRemaining = 0
    }

    /// Moves the noise floor toward `level` by `alpha` (EMA), clamped to
    /// `ceiling`. Asymmetry lives at the call sites: quiet input pulls the
    /// floor down fast, louder input raises it slowly, and suspected speech
    /// never feeds it.
    private mutating func adaptNoiseFloor(_ level: Float, alpha: Float, ceiling: Float) {
        noiseFloor += (level - noiseFloor) * alpha
        noiseFloor = min(ceiling, max(constants.minimumNoiseFloor, noiseFloor))
    }
}

/// The room's noise floor, learned from levels heard outside a listening
/// window (while Hermes thinks). A steer window opens while the user is
/// already speaking, so its detector starts from this floor rather than a
/// cold start on the user's voice. Like the detector's own floor, suspected
/// speech never feeds it: quiet speech that never opened a window must not
/// teach the room, or a later steer would read that speech as silence and
/// end mid-sentence.
struct VoiceRoomNoiseFloor {
    /// How long a level has to hold steady before it is learned although
    /// it sits above the floor's ambient ceiling: a room that got
    /// louder (a fan, a TV) holds steady; speech dips between words.
    static let steadyRunDuration: TimeInterval = 1.0
    /// A gap longer than this between samples (the tap delivers one about
    /// every 20 ms) means levels went unheard: a run doesn't span it.
    static let maximumRunGap: TimeInterval = 0.25
    /// How fast a steady run raises an existing floor, per sample: a tenth
    /// of the detector's rise, so a held vowel or a hum barely moves it
    /// while a room that got louder is followed within seconds.
    static let steadyRunRiseScale: Float = 0.1

    private(set) var constants: VoiceSpeechDetectorConstants
    /// Nil until the room has been heard; a steer window then cold-starts
    /// as before.
    private(set) var floor: Float?
    private var runStartedAt: Date?
    private var runLastSampleAt: Date?
    private var runQuietest: Float = 0
    private var runLoudest: Float = 0
    private var runSum: Float = 0
    private var runCount = 0

    init(constants: VoiceSpeechDetectorConstants = .init()) {
        self.constants = constants
    }

    mutating func observe(_ level: Float, at date: Date) {
        // Garbage samples teach nothing, and an unambiguous level is speech
        // that also breaks any steady run.
        guard level.isFinite, level >= 0, level < constants.maximumSpeechStartThreshold else {
            endRun()
            return
        }
        if let floor {
            if level < ambientCeiling(over: floor) {
                // Clearly ambient against the floor: adapt, as the
                // detector does.
                adapt(
                    toward: level,
                    alpha: level < floor ? constants.noiseFloorFallAlpha : constants.noiseFloorRiseAlpha
                )
                endRun()
                return
            }
        } else if level < constants.minimumSpeechStartThreshold {
            // Quiet enough to be no one speaking: the first floor.
            self.floor = clamped(level)
            endRun()
            return
        }
        // Suspected speech: learned only once it has held steady long
        // enough to be the room. The run counts suspected samples only, so
        // ambient dips can't age it.
        extendRun(level, at: date)
        guard let runStartedAt, date.timeIntervalSince(runStartedAt) >= Self.steadyRunDuration else { return }
        if floor == nil {
            floor = clamped(runSum / Float(runCount))
        } else {
            adapt(toward: runSum / Float(runCount), alpha: constants.noiseFloorRiseAlpha * Self.steadyRunRiseScale)
        }
    }

    /// Forgets the room: a new turn or another microphone learns afresh.
    mutating func reset() {
        floor = nil
        endRun()
    }

    /// The loudest level still taken for the room over `floor`. Tighter
    /// than the detector's speech-start threshold: nothing here starts an
    /// utterance, so quiet speech (well under that threshold) would
    /// otherwise teach the floor. Anything under the detector's minimum
    /// start threshold is ambience.
    private func ambientCeiling(over floor: Float) -> Float {
        max(constants.minimumSpeechStartThreshold, floor * constants.speechContinuationRiseFactor)
    }

    /// A run stays steady while its quietest sample is within the
    /// detector's cold-start dynamic range, or half, of its loudest.
    /// A sample that breaks it starts a new run.
    private mutating func extendRun(_ level: Float, at date: Date) {
        if runStartedAt != nil, let last = runLastSampleAt,
           date.timeIntervalSince(last) <= Self.maximumRunGap {
            let quietest = min(runQuietest, level)
            let loudest = max(runLoudest, level)
            if loudest - quietest < max(constants.coldStartMinimumDynamicRange, loudest * 0.5) {
                runQuietest = quietest
                runLoudest = loudest
                runSum += level
                runCount += 1
                runLastSampleAt = date
                return
            }
        }
        runStartedAt = date
        runLastSampleAt = date
        runQuietest = level
        runLoudest = level
        runSum = level
        runCount = 1
    }

    private mutating func endRun() {
        runStartedAt = nil
        runLastSampleAt = nil
        runQuietest = 0
        runLoudest = 0
        runSum = 0
        runCount = 0
    }

    private mutating func adapt(toward level: Float, alpha: Float) {
        guard let floor else { return }
        self.floor = clamped(floor + (level - floor) * alpha)
    }

    private func clamped(_ level: Float) -> Float {
        min(constants.maximumNoiseFloor, max(constants.minimumNoiseFloor, level))
    }
}
