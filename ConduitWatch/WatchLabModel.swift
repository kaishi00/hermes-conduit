//
//  WatchLabModel.swift
//  Conduit Watch
//
//  The audio lab (designs/apple-watch-voice.md, P1), on the Watch alone:
//  which compressed encoders watchOS offers, how much of the speaker's
//  sound the microphone picks up with and without voice processing, and
//  what interruptions and wrist moves do to a running microphone.
//

import AVFAudio
import Foundation
import SwiftUI

@MainActor
final class WatchLabModel: ObservableObject {
    struct EchoResult: Equatable {
        let voiceProcessing: Bool
        let noiseDBFS: Double
        let echoDBFS: Double
        var echoOverNoiseDB: Double { echoDBFS - noiseDBFS }
    }

    @Published private(set) var encoders: [String] = []
    @Published private(set) var echoResults: [EchoResult] = []
    @Published private(set) var status = "Ready"
    @Published private(set) var isBusy = false
    @Published private(set) var isWatching = false
    @Published private(set) var hasRecording = false

    private let audio = WatchAudio()
    private var recording: [Int16] = []
    private var recordingTimes: [TimeInterval] = []
    private var scenePhase: ScenePhase = .active

    static let playRate: Double = 24_000

    // MARK: Encoders

    func probeEncoders() {
        guard encoders.isEmpty else { return }
        let pcm = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        // Core Audio's format IDs as four-character codes: the watchOS SDK
        // has no AudioToolbox module to name them.
        let candidates: [(String, String)] = [
            ("AAC-LC", "aac "),
            ("AAC-ELD", "aace"),
            ("Opus", "opus"),
        ]
        var lines: [String] = []
        var fields: [String: Any] = [:]
        for (name, code) in candidates {
            let settings: [String: Any] = [
                AVFormatIDKey: code.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) },
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
            ]
            guard let format = AVAudioFormat(settings: settings),
                  let converter = AVAudioConverter(from: pcm, to: format) else {
                lines.append("\(name): no")
                fields[name] = "unavailable"
                continue
            }
            let rates = (converter.availableEncodeBitRates ?? []).map(\.intValue)
            lines.append("\(name): yes" + (rates.isEmpty ? "" : " (\(rates.prefix(3).map { "\($0 / 1000)k" }.joined(separator: ", "))…)"))
            fields[name] = rates
        }
        encoders = lines
        WatchProbeLog.shared.report("labEncoders", fields)
    }

    // MARK: Echo

    /// Plays a speech-like sound through the speaker and measures what the
    /// microphone hears: first silence (the room), then during playback.
    func runEchoTest(voiceProcessing: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        stopWatching()
        status = voiceProcessing ? "Echo test, voice processing on…" : "Echo test, voice processing off…"
        guard await WatchAudio.requestPermission() else {
            status = WatchAudioError.permissionDenied.localizedDescription
            return
        }
        recording = []
        recordingTimes = []
        audio.onCapture = { [weak self] samples, at in
            self?.recording.append(contentsOf: samples)
            self?.recordingTimes.append(at)
        }
        do {
            try audio.start(options: .init(voiceProcessing: voiceProcessing), playbackRate: Self.playRate)
        } catch {
            audio.onCapture = nil
            status = "Audio didn't start: \(error.localizedDescription)"
            WatchProbeLog.shared.note("labEchoFailed", ["error": error.localizedDescription])
            return
        }
        // Settle, then a second and a half of room noise.
        try? await Task.sleep(for: .milliseconds(500))
        let noiseStart = recording.count
        try? await Task.sleep(for: .milliseconds(1_500))
        let noiseEnd = recording.count
        let signal = Self.speechLikeSignal(duration: 4, sampleRate: Self.playRate)
        audio.enqueue(signal, sampleRate: Self.playRate)
        // Skip the pre-roll and the speaker's start.
        try? await Task.sleep(for: .milliseconds(500))
        let echoStart = recording.count
        try? await Task.sleep(for: .milliseconds(3_300))
        let echoEnd = recording.count
        try? await Task.sleep(for: .milliseconds(700))
        audio.stop()
        audio.onCapture = nil
        guard noiseEnd > noiseStart, echoEnd > echoStart else {
            status = "The microphone sent nothing."
            WatchProbeLog.shared.report("labEcho", ["voiceProcessing": voiceProcessing, "error": "no microphone audio"])
            return
        }
        let result = EchoResult(
            voiceProcessing: voiceProcessing,
            noiseDBFS: Self.dbfs(recording[noiseStart..<noiseEnd]),
            echoDBFS: Self.dbfs(recording[echoStart..<echoEnd])
        )
        echoResults.removeAll { $0.voiceProcessing == voiceProcessing }
        echoResults.append(result)
        hasRecording = true
        status = String(format: "Echo %.0f dB over the room", result.echoOverNoiseDB)
        WatchProbeLog.shared.report("labEcho", [
            "voiceProcessing": voiceProcessing,
            "noiseDBFS": (result.noiseDBFS * 10).rounded() / 10,
            "echoDBFS": (result.echoDBFS * 10).rounded() / 10,
            "echoOverNoiseDB": (result.echoOverNoiseDB * 10).rounded() / 10,
            "outputs": AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue },
        ])
    }

    /// Plays back what the microphone heard in the last echo test.
    func playRecording() async {
        guard !isBusy, hasRecording else { return }
        isBusy = true
        defer { isBusy = false }
        stopWatching()
        do {
            try audio.start(options: .init(), playbackRate: WatchAudio.captureRate)
        } catch {
            status = "Audio didn't start: \(error.localizedDescription)"
            return
        }
        status = "Playing what the microphone heard…"
        audio.enqueue(recording, sampleRate: WatchAudio.captureRate)
        try? await Task.sleep(for: .seconds(Double(recording.count) / WatchAudio.captureRate + 0.5))
        audio.stop()
        status = "Ready"
    }

    // MARK: Interruptions

    /// Keeps the microphone running and logs what happens to it: Siri, an
    /// alarm, a phone call, the wrist going down and up.
    func startWatching() async {
        guard !isWatching, !isBusy else { return }
        guard await WatchAudio.requestPermission() else {
            status = WatchAudioError.permissionDenied.localizedDescription
            return
        }
        var lastLevelLog: TimeInterval = 0
        var activity = WatchVoiceActivity()
        audio.onCapture = { samples, at in
            activity.process(samples, sampleRate: WatchAudio.captureRate, endingAt: at)
            // A level line every ten seconds shows the microphone is alive.
            if at - lastLevelLog >= 10 {
                lastLevelLog = at
                WatchProbeLog.shared.note("labMicAlive", ["level": (activity.level * 1000).rounded() / 1000])
            }
        }
        audio.onInterruption = { [weak self] began in
            guard let self, !began else { return }
            // Try to bring the microphone back, wherever the app is.
            do {
                try self.audio.start(options: .init(), playbackRate: Self.playRate)
                WatchProbeLog.shared.note("labRestart", ["ok": true, "scene": "\(self.scenePhase)"])
            } catch {
                WatchProbeLog.shared.note("labRestart", ["ok": false, "scene": "\(self.scenePhase)", "error": error.localizedDescription])
            }
        }
        do {
            try audio.start(options: .init(), playbackRate: Self.playRate)
            isWatching = true
            status = "Watching the microphone. Try Siri, an alarm, a call, lowering your wrist."
            WatchProbeLog.shared.note("labWatchStart")
        } catch {
            status = "Audio didn't start: \(error.localizedDescription)"
        }
    }

    func stopWatching() {
        guard isWatching else { return }
        isWatching = false
        audio.stop()
        audio.onCapture = nil
        audio.onInterruption = nil
        status = "Ready"
        WatchProbeLog.shared.note("labWatchStop")
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard phase != scenePhase else { return }
        scenePhase = phase
        guard isWatching else { return }
        WatchProbeLog.shared.note("labScenePhase", ["phase": "\(phase)", "audioRunning": audio.isRunning, "reachable": WatchLink.shared.isReachable])
    }

    // MARK: Signal

    /// Voiced syllables: harmonics of a gliding pitch with a few formant
    /// peaks, about four syllables a second, peaking near -7 dBFS like a
    /// spoken reply.
    static func speechLikeSignal(duration: TimeInterval, sampleRate: Double) -> [Int16] {
        let count = Int(duration * sampleRate)
        var samples = [Int16](repeating: 0, count: count)
        let formants: [(Double, Double)] = [(500, 1), (1_500, 0.5), (2_500, 0.25)]
        var phase = 0.0
        for index in 0..<count {
            let time = Double(index) / sampleRate
            let pitch = 140 + 40 * sin(2 * .pi * 0.7 * time)
            phase += 2 * .pi * pitch / sampleRate
            let syllable = max(0, sin(2 * .pi * 4 * time))
            var value = 0.0
            for harmonic in 1...20 {
                let frequency = pitch * Double(harmonic)
                guard frequency < sampleRate / 2 else { break }
                let weight = formants.reduce(0.0) { sum, formant in
                    sum + formant.1 / (1 + pow((frequency - formant.0) / 200, 2))
                }
                value += weight * sin(phase * Double(harmonic))
            }
            samples[index] = Int16(max(-32_767, min(32_767, value * syllable * 2_600)))
        }
        return samples
    }

    static func dbfs(_ samples: ArraySlice<Int16>) -> Double {
        guard !samples.isEmpty else { return -120 }
        var sum = 0.0
        for sample in samples {
            let value = Double(sample) / 32_768
            sum += value * value
        }
        let rms = (sum / Double(samples.count)).squareRoot()
        return 20 * log10(max(rms, 1e-6))
    }
}
