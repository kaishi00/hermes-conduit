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

/// The input node reported no usable hardware format. Retried once after the
/// session policy is re-applied; surfaced to the user as an unavailable
/// microphone if it persists.
struct VoiceAudioInputFormatUnavailable: LocalizedError, Equatable {
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
        if error is VoiceAudioInputFormatUnavailable { return true }
        // A wrapping framework error may carry the Core Audio status as its
        // underlying error, so walk the chain (bounded against cycles).
        var current: NSError? = error as NSError
        var depth = 0
        while let nsError = current, depth < 8 {
            if coreAudioDomains.contains(nsError.domain) && recoverableCodes.contains(nsError.code) {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    /// The explicit format to install the capture tap with, or nil to keep
    /// the node's own output format. Sample rate is the condition
    /// AVAudioEngine asserts on when installing an input tap, so a node whose
    /// output rate disagrees with the (already validated) hardware is tapped
    /// at the hardware format instead of raising. Channel layout is left to
    /// the converter.
    static func tapFormat(nodeOutput: AVAudioFormat, hardware: AVAudioFormat) -> AVAudioFormat? {
        abs(nodeOutput.sampleRate - hardware.sampleRate) < 0.5 ? nil : hardware
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
