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
@MainActor
final class HermesRingtonePreview {
    private var player: AVAudioPlayer?

    func play(_ ringtone: HermesRingtone, voiceInUse: Bool) {
        stop()
        guard !voiceInUse, let url = ringtone.bundledURL, let player = try? AVAudioPlayer(contentsOf: url) else { return }
        self.player = player
        player.play()
    }

    func stop() {
        player?.stop()
        player = nil
    }
}
