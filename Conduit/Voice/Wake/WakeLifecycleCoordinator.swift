//
//  WakeLifecycleCoordinator.swift
//  Conduit
//

import AVFAudio
import Foundation

struct WakeLifecycleSnapshot: Equatable {
    var isForegroundActive: Bool
    var isAuthenticated: Bool
    var isGatewayConnected: Bool
    var microphonePermitted: Bool
    /// No voice surface of any engine (classic sheet, Gemini / GPT / Grok
    /// Live, CarPlay), no voice launch in flight, and no other audio owner
    /// (Read Aloud, a provider test). The listener never shares the
    /// microphone with a conversation.
    var isVoiceIdle: Bool
    /// At least one usable wake phrase is bound on the current gateway.
    var hasWakePhrases: Bool
    /// The audio route allows listening. CarPlay does only when the user
    /// keeps wake on there: recording through the car switches its audio to
    /// a voice stream (other apps' music then plays from one side), so on
    /// CarPlay the listener records from the iPhone's own microphone.
    var isRouteSuitable: Bool = true

    var canArm: Bool {
        isForegroundActive && isAuthenticated && isGatewayConnected && microphonePermitted && isVoiceIdle
            && hasWakePhrases && isRouteSuitable
    }
}

/// Which audio routes foreground wake listening may record on.
enum WakeRoutePolicy {
    /// Fails open on an empty route on purpose: with no session active the
    /// route can read empty, and refusing there would keep wake from ever
    /// arming. CarPlay always reports its `.carAudio` output.
    static func isCarPlay(outputs: [VoiceAudioRoutePort]) -> Bool {
        outputs.contains { $0.type == .carAudio }
    }

    @MainActor
    static func currentRouteIsCarPlay() -> Bool {
        isCarPlay(outputs: AVAudioSession.sharedInstance().currentRoute.outputs.map {
            VoiceAudioRoutePort(type: $0.portType, name: $0.portName)
        })
    }
}

@MainActor
final class WakeLifecycleCoordinator {
    private let service: WakeWordService
    private(set) var lastFailureReason: String?

    init(service: WakeWordService) { self.service = service }

    var isArmed: Bool { service.isArmed }

    func update(for snapshot: WakeLifecycleSnapshot) {
        guard snapshot.canArm else {
            service.disarm()
            lastFailureReason = nil
            return
        }
        guard !service.isArmed else { return }
        do {
            try service.arm()
            lastFailureReason = nil
        } catch {
            service.disarm()
            lastFailureReason = UserFacingError.message(for: error)
        }
    }

    /// Call this synchronously when the scene becomes inactive/backgrounded.
    /// It never leaves local microphone capture running outside foreground use.
    func disarmImmediately() {
        service.disarm()
        lastFailureReason = nil
    }
}
