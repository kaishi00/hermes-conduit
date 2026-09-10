//
//  PendingVoiceIntentStore.swift
//  Conduit
//

import Foundation
import Combine

@MainActor
final class PendingVoiceIntentStore: ObservableObject {
    static let shared = PendingVoiceIntentStore()

    @Published private(set) var revision: UInt64 = 0
    private var pending: PendingVoiceIntent?

    /// True while an enqueued intent has not been routed. The store owns this
    /// fact; presentation decisions (e.g. the preferred return surface) read
    /// it rather than duplicating routing logic.
    var hasPendingIntent: Bool { pending != nil }

    /// Absolute deadline of the pending external launch, if any.
    var pendingExternalLaunchDeadline: Date? { pending?.externalLaunchDeadline }

    var pendingSource: PendingVoiceIntent.Source? { pending?.source }

    /// Test seam: the profile of the still-pending request, if any.
    var pendingProfile: String? { pending?.profile }

    func enqueue(_ intent: PendingVoiceIntent) {
        // One voice sheet can only honor one launch request. The newest source
        // is intentional: it reflects the user's latest explicit action.
        pending = intent
        revision &+= 1
    }

    /// Puts a temporarily-unroutable request back without treating it as a
    /// new launch. A newer explicit enqueue (revision already advanced) wins;
    /// this never resurrects an older request over a newer one. Skipping the
    /// revision bump keeps the scene's revision-keyed task from hot-looping
    /// while Hermes is still connecting.
    func requeueAsDeferred(_ intent: PendingVoiceIntent) {
        guard pending == nil else { return }
        pending = intent
    }

    func take() -> PendingVoiceIntent? {
        let value = pending
        pending = nil
        return value
    }

    func clear() {
        pending = nil
        revision &+= 1
    }
}

/// Result of one routing attempt. Terminal outcomes consume the request;
/// only `.deferred` retains it for a later lifecycle pass.
enum PendingVoiceIntentRouteOutcome: Equatable {
    case idle
    case routed
    case deferred
    case failed(message: String)
}

@MainActor
final class PendingVoiceIntentRouter {
    typealias Handler = (PendingVoiceIntent) async -> Bool

    private let store: PendingVoiceIntentStore

    init(store: PendingVoiceIntentStore = .shared) { self.store = store }

    /// Resolves the pending request against the current connection lifecycle.
    ///
    /// - Expired external (Siri) requests are consumed and reported failed —
    ///   they never wait for a later reconnect.
    /// - Connected requests are consumed exactly once via `handler`.
    /// - Stable connection/auth failures (positive evidence, not connecting)
    ///   terminal-fail Siri launches immediately — the deadline is only a
    ///   backstop for inconclusive states.
    /// - A false handler result requeues only in-app launches; Siri launches
    ///   fail terminally so Voice cannot open minutes later.
    /// - Connecting / inconclusive requests are retained without calling the
    ///   handler.
    func routePending(
        connection: VoiceLaunchConnectionSnapshot,
        now: Date = Date(),
        using handler: Handler
    ) async -> PendingVoiceIntentRouteOutcome {
        guard let intent = store.take() else { return .idle }

        switch PendingVoiceLaunchPolicy.readiness(
            for: intent,
            connection: connection,
            now: now
        ) {
        case .failed(let message):
            return .failed(message: message)
        case .waiting:
            store.requeueAsDeferred(intent)
            return .deferred
        case .ready:
            break
        }

        if await handler(intent) {
            return .routed
        }

        switch PendingVoiceLaunchPolicy.handlerFailureOutcome(for: intent) {
        case .failed(let message):
            return .failed(message: message)
        case .ready, .waiting:
            store.requeueAsDeferred(intent)
            return .deferred
        }
    }
}
