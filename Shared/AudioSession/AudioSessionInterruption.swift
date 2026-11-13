//
//  AudioSessionInterruption.swift
//  Conduit, Conduit Watch
//
//  One reading of audio session interruptions for every observer (issue
//  826). iOS and watchOS 27 report them with didBecomeInactiveNotification
//  and resumptionRecommendationNotification; earlier systems with
//  interruptionNotification. The forwarder reads whichever the running
//  system posts and reposts it as `.audioSessionInterruption`, so each
//  observer handles one shape, and tests post that shape on any system.
//

import AVFAudio
import Foundation

/// An interruption of Conduit's audio session.
enum AudioSessionInterruption: Equatable, Sendable {
    /// Another session (a call, Siri, an alarm) or the system took the
    /// audio away.
    case began
    /// The interruption is over; `shouldResume` is the system's advice
    /// on whether to carry on.
    case ended(shouldResume: Bool)

    static let userInfoKey = "AudioSessionInterruption"

    /// Reads a `.audioSessionInterruption` notification.
    init?(_ notification: Notification) {
        guard let interruption = notification.userInfo?[Self.userInfoKey] as? AudioSessionInterruption else {
            return nil
        }
        self = interruption
    }

    /// Posts this interruption as `.audioSessionInterruption`.
    func post(on center: NotificationCenter = .default) {
        center.post(name: .audioSessionInterruption, object: nil, userInfo: [Self.userInfoKey: self])
    }

    /// Reads `interruptionNotification`, which systems before 27 post.
    static func legacy(_ notification: Notification) -> AudioSessionInterruption? {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return nil }
        switch type {
        case .began:
            return .began
        case .ended:
            let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            return .ended(shouldResume: options.contains(.shouldResume))
        @unknown default:
            return nil
        }
    }
}

extension Notification.Name {
    /// Conduit's audio session was interrupted or got its audio back; the
    /// `AudioSessionInterruption` is in the user info. Reading this name
    /// starts the forwarder, so observing it is enough.
    static let audioSessionInterruption: Notification.Name = {
        AudioSessionInterruptionForwarder.start()
        return Notification.Name("ConduitAudioSessionInterruption")
    }()
}

/// Turns the system's interruption notifications into
/// `.audioSessionInterruption` on the default center. Its observers stay
/// for the app's lifetime (the center keeps them), and the system posts
/// these on the main thread.
private enum AudioSessionInterruptionForwarder {
    static func start() {
        let center = NotificationCenter.default
        if #available(iOS 27, watchOS 27, *) {
            _ = center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: nil) { note in
                // The app's own deactivation also makes the session
                // inactive; only the system taking it is an interruption.
                guard let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext,
                      context.source == .system || context.interruptionContext != nil else { return }
                AudioSessionInterruption.began.post()
            }
            _ = center.addObserver(forName: AVAudioSession.resumptionRecommendationNotification, object: nil, queue: nil) { note in
                let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
                AudioSessionInterruption.ended(shouldResume: context?.recommendation == .shouldResume).post()
            }
        } else {
            _ = center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
                AudioSessionInterruption.legacy(note)?.post()
            }
        }
    }
}
