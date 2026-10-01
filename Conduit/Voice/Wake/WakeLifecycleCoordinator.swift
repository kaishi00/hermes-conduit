//
//  WakeLifecycleCoordinator.swift
//  Conduit
//

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

    var canArm: Bool {
        isForegroundActive && isAuthenticated && isGatewayConnected && microphonePermitted && isVoiceIdle && hasWakePhrases
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
