//
//  VoiceAudioEngineRecovery.swift
//  Conduit
//
//  An AVAudioEngine snapshots the hardware formats of its I/O nodes when
//  they are first touched. Voice reconfigures the shared session between
//  turns (capture pause for speaker-safe playback, standalone Read Aloud,
//  Bluetooth HFP route changes, sample-rate changes when the voice-chat
//  mode engages), so an engine kept alive across those changes can start
//  against formats the hardware no longer offers. Core Audio then fails
//  `start()` with kAudioUnitErr_FormatNotSupported (-10868), or — worse —
//  `installTap` raises an uncatchable format-mismatch exception.
//
//  Audio services therefore start every rendering lifetime on a freshly
//  built engine, and retry once after re-applying the session policy when
//  the start still fails with a graph/format error.
//

import AVFAudio
import Foundation
import OSLog

private let engineRecoveryLogger = Logger(subsystem: "com.milim.relay", category: "VoiceAudio")

/// The capture input node reported a tap (output) format that disagrees
/// with the live hardware format. Installing a tap in that state raises an
/// Objective-C exception, so it is surfaced as a recoverable error instead.
struct VoiceAudioInputFormatMismatch: LocalizedError, Equatable {
    let hardwareSampleRate: Double
    let tapSampleRate: Double

    var errorDescription: String? {
        AppLocalization.string("The selected microphone is unavailable.")
    }
}

enum VoiceAudioEngineRecovery {
    /// kAudioUnitErr_FormatNotSupported.
    static let formatNotSupported = -10868
    /// kAudioUnitErr_FailedInitialization.
    static let failedInitialization = -10875
    /// kAudioUnitErr_CannotDoInCurrentContext.
    static let cannotDoInCurrentContext = -10863

    /// Domains Core Audio graph failures arrive in. Codes are namespaced, so
    /// a matching number in any other domain is not a graph failure.
    private static let coreAudioDomains: Set<String> = [
        "com.apple.coreaudio.avfaudio",
        NSOSStatusErrorDomain,
    ]

    private static let recoverableCodes: Set<Int> = [
        formatNotSupported,
        failedInitialization,
        cannotDoInCurrentContext,
    ]

    /// Whether a start failure is the stale-graph family a fresh engine on a
    /// re-applied session can recover from. Permission, missing-microphone,
    /// and app-level errors are not retried.
    static func isRecoverable(_ error: Error) -> Bool {
        if error is VoiceAudioInputFormatMismatch { return true }
        if error is VoiceAudioError { return false }
        let nsError = error as NSError
        return coreAudioDomains.contains(nsError.domain) && recoverableCodes.contains(nsError.code)
    }

    /// Whether a tap installed with the node's own output format would match
    /// the live hardware input. Sample rate is the condition AVAudioEngine
    /// asserts on when installing an input tap; channel layout is left to the
    /// converter. A zero-rate hardware format is not a match (no microphone).
    static func tapFormat(_ tap: AVAudioFormat, matchesHardware hardware: AVAudioFormat) -> Bool {
        hardware.sampleRate > 0 && abs(tap.sampleRate - hardware.sampleRate) < 0.5
    }

    /// Starts one rendering lifetime on a freshly rebuilt engine. On a
    /// recoverable failure the session policy is re-applied, the engine is
    /// rebuilt again, and the start is retried exactly once; any other
    /// failure, or a second failure, is rethrown to the caller.
    @MainActor
    static func startFresh(
        rebuild: () -> Void,
        reassert: () throws -> Void,
        start: () throws -> Void
    ) throws {
        rebuild()
        do {
            try start()
        } catch where isRecoverable(error) {
            let nsError = error as NSError
            engineRecoveryLogger.notice(
                "Audio engine start failed with a recoverable graph error domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public); rebuilding once"
            )
            try reassert()
            rebuild()
            try start()
        }
    }
}
