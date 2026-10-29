//
//  LiveTurnTrace.swift
//  Conduit and the Conduit Watch app
//
//  What a Grok Live or Local Live call's trace says about the user's turns
//  (#1418): when the server's turn detector heard speech start and end, and
//  how loud the microphone audio sent to it was in between. A turn that
//  never ends then shows whether the server got no audio, quiet speech, or
//  background noise it kept taking for speech. Levels only, never the audio.
//

import Foundation

struct LiveTurnTrace {
    /// The microphone stream the sessions are given:
    /// `GeminiLiveProtocol.inputSampleRate`, before any upsampling.
    static let sampleRate = 16_000
    /// Levels are measured over 100 ms, so a gap between words isn't the
    /// quietest moment and a click isn't the loudest.
    static let windowSamples = sampleRate / 10
    /// Audio sent with no turn detector event after which the trace says so,
    /// once per stretch.
    static let stretchLimit: TimeInterval = 15
    /// What a window of digital silence reads as.
    static let floorDBFS = -96

    private enum Stretch { case waiting, speaking }

    private var stretch = Stretch.waiting
    private var samples = 0
    private var windowSquares = 0.0
    private var windowCount = 0
    private var loudest: Int?
    private var quietest: Int?
    private var noted = false

    /// A new connection, or the call stopped: nothing heard yet.
    mutating func reset() {
        begin(.waiting)
    }

    /// Counts one chunk of 16 kHz PCM16 sent to the server. Returns a step
    /// for the trace the first time a stretch runs past `stretchLimit`.
    mutating func add(_ pcm16: Data) -> String? {
        let bytes = [UInt8](pcm16)
        for index in stride(from: 0, to: bytes.count - 1, by: 2) {
            let sample = Double(Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8))
            windowSquares += sample * sample
            windowCount += 1
            if windowCount == Self.windowSamples { closeWindow() }
        }
        samples += bytes.count / 2
        guard !noted, seconds >= Self.stretchLimit else { return nil }
        noted = true
        switch stretch {
        case .waiting: return "No speech heard in \(Int(Self.stretchLimit)) s of audio (\(levels))"
        case .speaking: return "No speech end after \(Int(Self.stretchLimit)) s of audio (\(levels))"
        }
    }

    /// The server heard the user start: what came before it is the room.
    mutating func speechStarted() -> String {
        let step = "Speech start heard (before it: \(levels))"
        begin(.speaking)
        return step
    }

    /// The server heard the user stop.
    mutating func speechStopped() -> String {
        let step = stretch == .speaking
            ? "Speech end heard after \(String(format: "%.1f", seconds)) s (\(levels))"
            : "Speech end heard with no start"
        begin(.waiting)
        return step
    }

    private var seconds: TimeInterval { Double(samples) / Double(Self.sampleRate) }

    private var levels: String {
        guard let loudest, let quietest else { return samples > 0 ? "under 100 ms of microphone audio" : "no microphone audio" }
        return "microphone loudest \(loudest) dBFS, quietest \(quietest) dBFS"
    }

    private mutating func begin(_ stretch: Stretch) {
        self.stretch = stretch
        samples = 0
        windowSquares = 0
        windowCount = 0
        loudest = nil
        quietest = nil
        noted = false
    }

    private mutating func closeWindow() {
        let rms = (windowSquares / Double(windowCount)).squareRoot()
        let level = rms > 0 ? max(Self.floorDBFS, Int((20 * log10(rms / 32_768)).rounded())) : Self.floorDBFS
        loudest = max(loudest ?? level, level)
        quietest = min(quietest ?? level, level)
        windowSquares = 0
        windowCount = 0
    }
}
