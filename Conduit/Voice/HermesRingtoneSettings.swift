//
//  HermesRingtoneSettings.swift
//  Conduit
//
//  The iPhone's side of the ringtone for calls from Hermes (issue 2445,
//  Shared/WatchVoice/HermesRingtones.swift): each tone's name in Settings,
//  and the preview a pick plays.
//

import AVFoundation
import CallKit
import Foundation

extension HermesRingtone {
    var title: String {
        switch self {
        case .system: return AppLocalization.string("iOS default", table: .voice)
        case .chime: return AppLocalization.string("Chime", table: .voice)
        case .lantern: return AppLocalization.string("Lantern", table: .voice)
        case .ripple: return AppLocalization.string("Ripple", table: .voice)
        case .signal: return AppLocalization.string("Signal", table: .voice)
        case .beacon: return AppLocalization.string("Beacon", table: .voice)
        case .orbit: return AppLocalization.string("Orbit", table: .voice)
        }
    }
}

/// Plays a tone once when it's picked in Settings, so the user hears what
/// they chose. Quiet while voice is on or the user is on a phone call of
/// any app's: a call's audio isn't talked over.
/// It takes the audio session as a clip in a chat does, so it plays on the
/// loudspeaker after a call that ended on the earpiece, and gives way to
/// dictation or a voice message taking the microphone.
@MainActor
final class HermesRingtonePreview: NSObject {
    private var player: AVAudioPlayer?
    private var lease: VoiceAudioLease?
    private let coordinator: VoiceAudioSessionCoordinator
    private let center: NotificationCenter
    private let phoneCallInProgress: (() -> Bool)?

    private static let callObserver = CXCallObserver()

    var isPlaying: Bool { player != nil }

    /// The defaults are the app's; tests pass their own.
    init(
        coordinator: VoiceAudioSessionCoordinator? = nil,
        center: NotificationCenter = .default,
        isPhoneCallInProgress: (() -> Bool)? = nil
    ) {
        self.coordinator = coordinator ?? .shared
        self.center = center
        phoneCallInProgress = isPhoneCallInProgress
        super.init()
        // A call or an alarm pauses the player underneath: the preview is
        // over then, and its hold on the audio session with it.
        center.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: .audioSessionInterruption,
            object: nil
        )
    }

    deinit {
        center.removeObserver(self)
    }

    @objc nonisolated private func handleInterruption(_ notification: Notification) {
        guard AudioSessionInterruption(notification) == .began else { return }
        Task { @MainActor [weak self] in self?.stop() }
    }

    /// A call of any app's, a cellular one included: Conduit's own audio
    /// state knows only its own calls.
    private var isPhoneCallInProgress: Bool {
        phoneCallInProgress?() ?? Self.callObserver.calls.contains { !$0.hasEnded }
    }

    func play(_ ringtone: HermesRingtone, voiceInUse: Bool) {
        stop()
        guard !voiceInUse, !isPhoneCallInProgress, let url = ringtone.bundledURL, let player = try? AVAudioPlayer(contentsOf: url) else { return }
        // It still plays if the session can't be claimed, under whatever
        // category is already active.
        lease = try? coordinator.acquire(.standalonePlayback) { [weak self] in
            self?.stop()
        }
        player.delegate = self
        self.player = player
        if !player.play() { stop() }
    }

    func stop() {
        player?.stop()
        player?.delegate = nil
        player = nil
        guard let lease else { return }
        self.lease = nil
        coordinator.release(lease)
    }

    private func finished(_ finishedPlayer: AVAudioPlayer) {
        guard finishedPlayer === player else { return }
        stop()
    }
}

extension HermesRingtonePreview: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.finished(player) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.finished(player) }
    }
}
