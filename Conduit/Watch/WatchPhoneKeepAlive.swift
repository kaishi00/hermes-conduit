//
//  WatchPhoneKeepAlive.swift
//  Conduit
//
//  How a Watch call keeps Conduit running on a locked iPhone, for the
//  locked-phone test (designs/apple-watch-voice.md, P3). Picked in Voice
//  settings > Apple Watch test. A device log had the CallKit call break
//  the link: every message from the iPhone to the Watch failed from the
//  moment the call's audio started, in both calls tried. Silent audio is
//  the other way an app with background audio keeps running.
//

import AVFAudio
import Foundation

enum WatchPhoneKeepAlive: String, CaseIterable {
    case off
    case silentAudio
    case call

    /// A new key: the CallKit switch's old one stays behind unread, so
    /// nobody carries it into this build turned on.
    static let key = "watchProbe.phoneKeepAlive"

    static var current: WatchPhoneKeepAlive {
        UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .off
    }

    var title: String {
        switch self {
        case .off: return "Off"
        case .silentAudio: return "Silent audio"
        case .call: return "CallKit call"
        }
    }

    var detail: String {
        switch self {
        case .off:
            return "Nothing keeps Conduit running while the phone is locked."
        case .silentAudio:
            return "Each Watch call plays silence on this iPhone, mixed with anything else playing, so iOS keeps Conduit running while the phone is locked."
        case .call:
            return "Each Watch call also starts a call on this iPhone. In the last test this stopped every message from the iPhone reaching the Watch."
        }
    }
}

/// Silence on a loop for the length of a Watch call: an app with the
/// audio background mode keeps running while it plays.
@MainActor
final class WatchPhoneSilentAudio {
    private let log: WatchProbePhoneLog
    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []
    /// The session's setup before the call, put back after it.
    private var previousSession: (category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions)?

    init(log: WatchProbePhoneLog) {
        self.log = log
    }

    func start() {
        guard player == nil else { return }
        let session = AVAudioSession.sharedInstance()
        if previousSession == nil {
            previousSession = (session.category, session.mode, session.categoryOptions)
        }
        do {
            // Mixable: it never pauses the phone's music, and iOS lets a
            // mixable session start in the background, where a Watch call
            // usually finds Conduit.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.silence)
            player.numberOfLoops = -1
            guard player.play() else { throw WatchPhoneSilentAudioError.didNotPlay }
            self.player = player
            observeInterruptions()
            log.note("phoneSilentAudioStart", ["ok": true, "appState": WatchProbeLiveness.appStateName])
        } catch {
            log.note("phoneSilentAudioStart", ["ok": false, "error": error.localizedDescription, "appState": WatchProbeLiveness.appStateName])
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            restoreSession()
        }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let player else { return }
        player.stop()
        self.player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        restoreSession()
        log.note("phoneSilentAudioStop", ["appState": WatchProbeLiveness.appStateName])
    }

    /// A phone call or an alarm stops the player: start it again after.
    private func observeInterruptions() {
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                switch type {
                case .began?:
                    self.log.note("phoneSilentAudioInterrupted", ["appState": WatchProbeLiveness.appStateName])
                case .ended?:
                    let resumed = (try? AVAudioSession.sharedInstance().setActive(true)) != nil && player.play()
                    self.log.note("phoneSilentAudioResumed", ["ok": resumed, "appState": WatchProbeLiveness.appStateName])
                default:
                    break
                }
            }
        })
    }

    private func restoreSession() {
        guard let previousSession else { return }
        self.previousSession = nil
        do {
            try AVAudioSession.sharedInstance().setCategory(previousSession.category, mode: previousSession.mode, options: previousSession.options)
        } catch {
            log.note("phoneSilentAudioRestoreFailed", ["error": error.localizedDescription])
        }
    }

    /// One second of 8 kHz 16-bit mono silence as a WAV file.
    private static let silence: Data = {
        let sampleRate: UInt32 = 8_000
        let dataBytes = sampleRate * 2
        var data = Data()
        func append<Value: FixedWidthInteger>(_ value: Value) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataBytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1)) // PCM
        append(UInt16(1)) // mono
        append(sampleRate)
        append(sampleRate * 2) // bytes per second
        append(UInt16(2)) // bytes per frame
        append(UInt16(16)) // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(dataBytes)
        data.append(Data(count: Int(dataBytes)))
        return data
    }()
}

enum WatchPhoneSilentAudioError: LocalizedError {
    case didNotPlay

    var errorDescription: String? {
        switch self {
        case .didNotPlay: return "The silent audio didn't start playing."
        }
    }
}
