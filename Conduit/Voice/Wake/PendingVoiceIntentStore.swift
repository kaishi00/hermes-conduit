//
//  PendingVoiceIntentStore.swift
//  Conduit
//

import Foundation
import Combine

/// Ownership token for one pending Siri launch. A claim is only valid while
/// `generation` still matches the store: any enqueue/clear invalidates it.
struct PendingVoiceIntentClaim: Equatable {
    let generation: UInt64
    let intent: PendingVoiceIntent
}

/// In-memory mailbox for the single pending external voice launch.
///
/// Production enqueue path is the Siri App Intent. Composer calls
/// `openVoiceConversation` directly and does not use this store.
///
/// Invariant: async work started for claim N may only mutate the store when
/// the claim is still current. Superseded/cleared/expired claims are no-ops.
@MainActor
final class PendingVoiceIntentStore: ObservableObject {
    static let shared = PendingVoiceIntentStore()

    /// SwiftUI routing revision. Bumped only on real launches (enqueue) and
    /// terminal consumption that should re-evaluate the scene (clear / expire).
    /// Deliberately not bumped on deferred requeues — that would hot-loop
    /// `.task(id: revision…)` while Hermes is still connecting.
    @Published private(set) var revision: UInt64 = 0
    /// Monotonic ownership generation. Bumped on every enqueue and clear.
    private(set) var ownershipGeneration: UInt64 = 0
    private var pending: PendingVoiceIntent?

    var hasPendingIntent: Bool { pending != nil }

    var pendingExternalLaunchDeadline: Date? { pending?.externalLaunchDeadline }

    var pendingSource: PendingVoiceIntent.Source? { pending?.source }

    var pendingProfile: String? { pending?.profile }

    /// Claim without consuming — used by the deadline waiter before sleep.
    func peekClaim() -> PendingVoiceIntentClaim? {
        guard let intent = pending else { return nil }
        return PendingVoiceIntentClaim(generation: ownershipGeneration, intent: intent)
    }

    func enqueue(_ intent: PendingVoiceIntent) {
        // Newest explicit launch wins. Bumping ownershipGeneration invalidates
        // any in-flight claim for a previous request.
        pending = intent
        ownershipGeneration &+= 1
        revision &+= 1
    }

    /// Claim the pending request for routing. Clears the slot; the claim's
    /// generation stays valid until enqueue/clear/expiry.
    func takeClaim() -> PendingVoiceIntentClaim? {
        guard let intent = pending else { return nil }
        pending = nil
        return PendingVoiceIntentClaim(generation: ownershipGeneration, intent: intent)
    }

    func isClaimCurrent(_ claim: PendingVoiceIntentClaim) -> Bool {
        claim.generation == ownershipGeneration
    }

    /// Restore a still-current claim without a revision bump (temporary
    /// not-ready). No-op if a newer launch already claimed the slot.
    @discardableResult
    func requeueDeferred(_ claim: PendingVoiceIntentClaim) -> Bool {
        guard isClaimCurrent(claim), pending == nil else { return false }
        pending = claim.intent
        return true
    }

    /// Hard-backstop expiry. Consumes the request only when the claim still
    /// owns the store and the pending intent is still that exact claim.
    /// Never leaves the same external request pending after firing.
    @discardableResult
    func expireClaimIfCurrent(_ claim: PendingVoiceIntentClaim) -> PendingVoiceIntent? {
        guard isClaimCurrent(claim),
              pending != nil,
              pending == claim.intent else {
            return nil
        }
        pending = nil
        ownershipGeneration &+= 1
        revision &+= 1
        return claim.intent
    }

    func clear() {
        pending = nil
        ownershipGeneration &+= 1
        revision &+= 1
    }
}

/// Result of one routing attempt.
enum PendingVoiceIntentRouteOutcome: Equatable {
    case idle
    case routed
    case deferred
    case failed(message: String)
    /// The claim was invalidated (clear / supersede) before completion.
    /// Callers must not publish errors or touch a newer request.
    case superseded
}

/// Terminal outcome when the launch handler could not open Voice.
enum PendingVoiceHandlerFailure: Equatable {
    case terminal(message: String)
    case retryLater
}

@MainActor
final class PendingVoiceIntentRouter {
    typealias Handler = (PendingVoiceIntent) async -> Bool

    private let store: PendingVoiceIntentStore

    init(store: PendingVoiceIntentStore = .shared) { self.store = store }

    /// Resolves the pending request against the current connection lifecycle.
    ///
    /// Ownership: only the claim taken here may requeue or report a terminal
    /// result. After `await`, a stale claim returns `.superseded` and mutates
    /// nothing.
    func routePending(
        connection: VoiceLaunchConnectionSnapshot,
        now: Date = Date(),
        using handler: Handler
    ) async -> PendingVoiceIntentRouteOutcome {
        guard let claim = store.takeClaim() else { return .idle }
        let intent = claim.intent

        switch PendingVoiceLaunchPolicy.readiness(
            for: intent,
            connection: connection,
            now: now
        ) {
        case .failed(let message):
            // Consumed by takeClaim; still current (no suspension yet).
            return .failed(message: message)
        case .waiting:
            store.requeueDeferred(claim)
            return .deferred
        case .ready:
            break
        }

        let didOpen = await handler(intent)

        // Handler may suspend across profile switch / session create. If the
        // store moved on, this completion is stale — no requeue, no error.
        guard store.isClaimCurrent(claim) else {
            return .superseded
        }

        if didOpen {
            return .routed
        }

        switch PendingVoiceLaunchPolicy.handlerFailure(for: intent) {
        case .terminal(let message):
            return .failed(message: message)
        case .retryLater:
            store.requeueDeferred(claim)
            return .deferred
        }
    }
}
