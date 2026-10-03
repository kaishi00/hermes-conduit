//
//  HeadsetMicrophoneMute.swift
//  Conduit
//
//  The system's microphone mute during a live voice call (#331): pressing
//  the AirPods stem (or a Bluetooth headset's mute control) toggles the
//  call's mute, the same as the on-screen Mute button, and the on-screen
//  button keeps the system's mute state in step so the next press does the
//  expected thing.
//
//  On iOS the system mutes the app's input itself (`AVAudioApplication`
//  zeroes every input while muted) and posts
//  `inputMuteStateChangeNotification`; the closure-based
//  `setInputMuteStateChangeHandler` is macOS only. So the system state and
//  the call's own mute must never disagree: a call that stayed system-muted
//  after the user unmuted on screen would send silence.
//

import AVFAudio
import Foundation
import OSLog

private let headsetMuteLogger = Logger(subsystem: "com.milim.relay", category: "VoiceAudio")

/// Seam over `AVAudioApplication.shared`'s input mute so the ownership
/// policy can be asserted in unit tests without touching system audio.
@MainActor
protocol SystemInputMuteControlling: AnyObject {
    /// Starts (or, with nil, stops) observing the system input mute. The
    /// handler gets the system's mute state as it is when delivered.
    func observeInputMute(_ handler: (@MainActor (Bool) -> Void)?)
    func setInputMuted(_ muted: Bool) throws
}

@MainActor
final class SystemInputMute: SystemInputMuteControlling {
    private var observer: NSObjectProtocol?

    func observeInputMute(_ handler: (@MainActor (Bool) -> Void)?) {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        guard let handler else { return }
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioApplication.inputMuteStateChangeNotification,
            object: AVAudioApplication.shared,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // The current state, not the notification's: delivery is
                // queued, so a notification for an earlier change (one
                // Conduit made itself, say) can arrive after a later one.
                handler(AVAudioApplication.shared.isInputMuted)
            }
        }
    }

    func setInputMuted(_ muted: Bool) throws {
        try AVAudioApplication.shared.setInputMuted(muted)
    }
}

/// One live call at a time owns the system mute. The live voice
/// controllers are app-lifetime objects, so ownership is keyed by
/// controller: a controller that goes idle after another has started its
/// call can't stop the newer call's observer.
@MainActor
final class HeadsetMicrophoneMute {
    static let shared = HeadsetMicrophoneMute(system: SystemInputMute())

    private let system: SystemInputMuteControlling
    private var owner: ObjectIdentifier?
    /// The owning controller itself, held weakly: a controller freed without
    /// releasing counts as released, so a new object at the same address
    /// can't inherit its (dead) claim.
    private weak var ownerObject: AnyObject?
    private var onChange: (@MainActor (Bool) -> Void)?
    /// The system mute state as Conduit last set or saw it, so repeated
    /// syncs don't call into AVFAudio again and echoes are ignored.
    private var reflectedMuted: Bool?

    init(system: SystemInputMuteControlling) {
        self.system = system
    }

    /// Makes `owner` the call the headset gesture mutes, and mirrors its
    /// current mute to the system. Idempotent: calling again while already
    /// the owner only updates the mirrored state.
    func claim(by owner: AnyObject, muted: Bool, onChange: @escaping @MainActor (Bool) -> Void) {
        let id = ObjectIdentifier(owner)
        if self.owner != id || ownerObject == nil {
            self.owner = id
            ownerObject = owner
            self.onChange = onChange
            reflectedMuted = nil
            system.observeInputMute { [weak self] muted in
                self?.systemMuteChanged(muted, for: id)
            }
        }
        reflect(muted)
    }

    /// Hands the system mute back when `owner`'s call ends. The system is
    /// left unmuted: a mute belongs to the call it was set in.
    func release(by owner: AnyObject) {
        guard self.owner == ObjectIdentifier(owner) else { return }
        reflect(false)
        system.observeInputMute(nil)
        self.owner = nil
        ownerObject = nil
        onChange = nil
        reflectedMuted = nil
    }

    private func reflect(_ muted: Bool) {
        guard reflectedMuted != muted else { return }
        do {
            try system.setInputMuted(muted)
            reflectedMuted = muted
        } catch {
            // Unknown now: the next sync or gesture is applied, not skipped.
            reflectedMuted = nil
            headsetMuteLogger.error("Setting the system input mute failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func systemMuteChanged(_ muted: Bool, for id: ObjectIdentifier) {
        // A gesture queued for a call that has since ended goes nowhere, and
        // the echo of Conduit's own change is already reflected.
        guard owner == id, ownerObject != nil, muted != reflectedMuted else { return }
        reflectedMuted = muted
        onChange?(muted)
    }
}
