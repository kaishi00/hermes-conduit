//
//  HermesRingtoneSettings.swift
//  Conduit
//
//  The iPhone's side of the ringtone for calls from Hermes (issue 2445,
//  Shared/WatchVoice/HermesRingtones.swift): each tone's name in Settings,
//  and the preview a pick plays.
//

import AVFoundation
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
/// they chose. Quiet while voice is on: a call's audio isn't talked over.
/// It takes the audio session as a clip in a chat does, so it plays on the
/// loudspeaker after a call that ended on the earpiece, and gives way to
/// dictation or a voice message taking the microphone.
@MainActor
final class HermesRingtonePreview: NSObject {
    private var player: AVAudioPlayer?
    private var lease: VoiceAudioLease?

    override init() {
        super.init()
        // A call or an alarm pauses the player underneath: the preview is
        // over then, and its hold on the audio session with it.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: .audioSessionInterruption,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc nonisolated private func handleInterruption(_ notification: Notification) {
        guard AudioSessionInterruption(notification) == .began else { return }
        Task { @MainActor [weak self] in self?.stop() }
    }

    func play(_ ringtone: HermesRingtone, voiceInUse: Bool) {
        stop()
        guard !voiceInUse, let url = ringtone.bundledURL, let player = try? AVAudioPlayer(contentsOf: url) else { return }
        // It still plays if the session can't be claimed, under whatever
        // category is already active.
        lease = try? VoiceAudioSessionCoordinator.shared.acquire(.standalonePlayback) { [weak self] in
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
        VoiceAudioSessionCoordinator.shared.release(lease)
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
