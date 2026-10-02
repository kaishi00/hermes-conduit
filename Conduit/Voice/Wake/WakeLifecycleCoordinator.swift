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
    /// The audio route tolerates a background recording session. CarPlay
    /// does not: any app recording there switches the car's audio to a
    /// voice stream, and other apps' music plays from one side only.
    var isRouteSuitable: Bool = true

    var canArm: Bool {
        isForegroundActive && isAuthenticated && isGatewayConnected && microphonePermitted && isVoiceIdle
            && hasWakePhrases && isRouteSuitable
    }
}

/// Which audio routes foreground wake listening may record on.
enum WakeRoutePolicy {
    static func allowsWakeListening(outputs: [VoiceAudioRoutePort]) -> Bool {
        !outputs.contains { $0.type == .carAudio }
    }

    @MainActor
    static func current() -> Bool {
        allowsWakeListening(outputs: AVAudioSession.sharedInstance().currentRoute.outputs.map {
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
            lastFailureReason = error.localizedDescription
        }
    }

    /// Call this synchronously when the scene becomes inactive/backgrounded.
    /// It never leaves local microphone capture running outside foreground use.
    func disarmImmediately() {
        service.disarm()
        lastFailureReason = nil
    }
}
