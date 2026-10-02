//
//  CarPlayEarcons.swift
//  Conduit
//
//  Short status sounds for the CarPlay voice screen, as Apple recommends for
//  voice apps in the car: a soft two-note rise when the driver's turn is
//  sent, and a low note when Voice fails. Classic mode only: a live call
//  keeps its microphone open, and a tone would be heard by the model.
//  The tones are synthesized, so the app ships no sound files.
//

import AVFoundation
import Foundation

enum CarPlayEarcon: Equatable {
    /// The driver's turn went to Hermes (Listening → Thinking).
    case sent
    /// Voice failed.
    case failed

    /// The sound for a state change, or nil when the change has none.
    static func forTransition(from old: CarPlayVoiceState?, to new: CarPlayVoiceState) -> CarPlayEarcon? {
        switch (old, new) {
        case (.listening?, .processing): return .sent
        case (let previous, .error) where previous != .error && previous != nil: return .failed
        default: return nil
        }
    }

    /// (frequency in Hz, duration in seconds) per note.
    var notes: [(Double, Double)] {
        switch self {
        case .sent: return [(660, 0.07), (880, 0.09)]
        case .failed: return [(330, 0.16)]
        }
    }
}

@MainActor
final class CarPlayEarconPlayer {
    static let sampleRate = 44_100.0
    private var players: [CarPlayEarcon: AVAudioPlayer] = [:]

    func play(_ earcon: CarPlayEarcon) {
        guard let player = player(for: earcon) else { return }
        player.currentTime = 0
        player.play()
    }

    private func player(for earcon: CarPlayEarcon) -> AVAudioPlayer? {
        if let cached = players[earcon] { return cached }
        guard let player = try? AVAudioPlayer(data: Self.wav(for: earcon)) else { return nil }
        player.volume = 0.35
        player.prepareToPlay()
        players[earcon] = player
        return player
    }

    /// A mono 16-bit PCM WAV of the earcon's notes, each with a short fade
    /// in and out so it never clicks.
    static func wav(for earcon: CarPlayEarcon) -> Data {
        var samples: [Int16] = []
        for (frequency, duration) in earcon.notes {
            let count = Int(sampleRate * duration)
            let fade = max(1, Int(sampleRate * 0.012))
            for index in 0..<count {
                let envelope = min(1, Double(index) / Double(fade), Double(count - index) / Double(fade))
                let value = sin(2 * .pi * frequency * Double(index) / sampleRate) * envelope * 0.6
                samples.append(Int16(value * Double(Int16.max)))
            }
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(byteCount)
        for sample in samples { append(sample) }
        return data
    }
}
