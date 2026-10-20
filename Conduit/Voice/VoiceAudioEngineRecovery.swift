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
//  Some Bluetooth headset microphones (hearing aids over HFP, #177) still
//  fail that way on a fresh engine. Capture then records from the iPhone's
//  own microphone for the rest of its lease, which is what turning the
//  headset's streaming off did by hand.
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
    /// the converter. An unpopulated (zero-rate) node output keeps the
    /// nil-format tap, exactly as before this guard existed.
    static func tapFormat(nodeOutput: AVAudioFormat, hardware: AVAudioFormat) -> AVAudioFormat? {
        guard nodeOutput.sampleRate > 0,
              abs(nodeOutput.sampleRate - hardware.sampleRate) >= 0.5 else { return nil }
        // Logged here, for every mic-start path that asks: the field
        // breadcrumb that this route-dependent guard engaged.
        engineRecoveryLogger.notice(
            "Input node output rate \(nodeOutput.sampleRate, privacy: .public) disagrees with hardware rate \(hardware.sampleRate, privacy: .public); tapping at the hardware format"
        )
        return hardware
    }

    /// Starts one rendering lifetime on a freshly rebuilt engine. On a
    /// recoverable failure the session policy is re-applied, the engine is
    /// rebuilt again, and the start is retried exactly once; any other
    /// failure, or a second failure, is rethrown to the caller.
    ///
    /// `switchMicrophone`, for capture, is asked after the retry fails too:
    /// when it moved the input to another microphone (true), the start is
    /// tried once more, on that one.
    @MainActor
    static func startFresh(
        rebuild: () -> Void,
        reassert: () throws -> Void,
        start: () throws -> Void,
        switchMicrophone: (() throws -> Bool)? = nil
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
            do {
                try start()
            } catch where isRecoverable(error) {
                guard let switchMicrophone else { throw error }
                // A microphone that can't be switched to reports the graph
                // failure that asked for it, not its own.
                let switched: Bool
                do {
                    switched = try switchMicrophone()
                } catch let switchError {
                    engineRecoveryLogger.error("Could not prefer the built-in microphone: \(LogRedaction.message(switchError), privacy: .public)")
                    throw error
                }
                guard switched else { throw error }
                engineRecoveryLogger.notice("Audio engine still failed on the headset microphone; starting on the built-in microphone")
                rebuild()
                try start()
            }
        }
    }
}

/// Records from the iPhone's own microphone when a Bluetooth headset's
/// (HFP, hearing aids) won't start (#177). Playback stays where the route
/// puts it. Held until `clear()`, which capture calls as it gives the
/// session back.
@MainActor
final class VoiceBuiltInMicrophoneFallback {
    private(set) var isEngaged = false
    private let routeRecordsFromBluetooth: @MainActor () -> Bool
    private let preferBuiltInMicrophone: @MainActor () throws -> Bool
    private let clearPreferredInput: @MainActor () throws -> Void

    /// The closures are seams for tests; nil uses the shared session.
    init(
        routeRecordsFromBluetooth: (@MainActor () -> Bool)? = nil,
        preferBuiltInMicrophone: (@MainActor () throws -> Bool)? = nil,
        clearPreferredInput: (@MainActor () throws -> Void)? = nil
    ) {
        self.routeRecordsFromBluetooth = routeRecordsFromBluetooth ?? {
            AVAudioSession.sharedInstance().currentRoute.inputs.contains { VoiceBuiltInMicrophoneFallback.bluetoothInputs.contains($0.portType) }
        }
        self.preferBuiltInMicrophone = preferBuiltInMicrophone ?? {
            let session = AVAudioSession.sharedInstance()
            guard let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else { return false }
            try session.setPreferredInput(builtIn)
            return true
        }
        self.clearPreferredInput = clearPreferredInput ?? {
            try AVAudioSession.sharedInstance().setPreferredInput(nil)
        }
    }

    static let bluetoothInputs: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothLE]

    /// Moves capture to the built-in microphone when it records from a
    /// Bluetooth headset. Whether it moved.
    func engage() throws -> Bool {
        guard !isEngaged, routeRecordsFromBluetooth() else { return false }
        guard try preferBuiltInMicrophone() else { return false }
        isEngaged = true
        return true
    }

    /// The headset's microphone again, for the next capture.
    func clear() {
        guard isEngaged else { return }
        isEngaged = false
        do {
            try clearPreferredInput()
        } catch {
            engineRecoveryLogger.error("Could not clear the built-in microphone preference: \(LogRedaction.message(error), privacy: .public)")
        }
    }
}
