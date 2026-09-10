//
//  PendingVoiceLaunchPolicy.swift
//  Conduit
//
//  Deterministic lifecycle for external voice launch requests (Siri).
//  Voice is foreground-first: the App Intent only records a pending request,
//  and the root scene consumes it after Hermes is ready — or fails it so an
//  old Siri launch can never open Voice minutes later.
//

import Foundation

/// Pure decisions for external (Siri) voice launches. Kept free of App
/// Intents and networking so unit tests can cover the policy without
/// mocking the framework or a live socket.
enum PendingVoiceLaunchPolicy {
    /// How long a Siri-triggered launch may wait for Hermes during the
    /// foreground bootstrap before it is treated as unready and failed.
    /// Long enough for saved-credential restore + first connect on a cold
    /// launch; short enough that a later manual reconnect cannot resurrect
    /// the same request.
    static let externalLaunchBudget: TimeInterval = 30

    /// User-visible explanation when an external launch cannot start voice.
    static let disconnectedFailureMessage =
        "Conduit could not connect to Hermes, so voice did not start. Ask again after the connection is restored."

    /// User-visible explanation when a pending Siri request outlived its
    /// launch window (stable failure or reconnect that arrived too late).
    static let expiredFailureMessage =
        "The Siri voice request expired before Hermes was ready. Ask Siri again now that Conduit is open."

    static func normalizedProfile(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Builds the in-memory pending request for one Siri invocation.
    /// The absolute deadline is stamped once at enqueue time so later
    /// re-enqueues (temporary not-ready deferrals) cannot extend the window.
    static func makeSiriPendingIntent(
        profile: String?,
        now: Date = Date(),
        budget: TimeInterval = externalLaunchBudget
    ) -> PendingVoiceIntent {
        PendingVoiceIntent(
            profile: normalizedProfile(profile),
            startsFreshConversation: true,
            source: .siri,
            externalLaunchDeadline: now.addingTimeInterval(budget)
        )
    }

    enum Readiness: Equatable {
        /// Hermes is live — consume the request exactly once.
        case ready
        /// Foreground bootstrap / reconnect may still bring Hermes up.
        case waiting
        /// Terminal for this request: do not retain across later reconnects.
        case failed(message: String)
    }

    /// Lifecycle decision for a pending external launch. Success is
    /// connection-driven; the deadline only ends the wait so a stale Siri
    /// request cannot fire after an unrelated reconnect.
    static func readiness(
        for intent: PendingVoiceIntent,
        isConnected: Bool,
        now: Date
    ) -> Readiness {
        if let deadline = intent.externalLaunchDeadline, now > deadline {
            return .failed(message: expiredFailureMessage)
        }
        if isConnected {
            return .ready
        }
        // In-app launches (composer / wake) have no deadline and keep the
        // original "wait until connected" semantics. Siri requests inside
        // their window also wait for the normal connection attempt.
        return .waiting
    }

    /// Outcome when the launch handler reports it could not open Voice.
    /// Siri launches are terminal: a failed or partial open must not sit
    /// pending and surprise the user on a later reconnect. In-app launches
    /// keep the existing defer-and-retry behavior.
    static func handlerFailureOutcome(
        for intent: PendingVoiceIntent
    ) -> Readiness {
        if intent.source == .siri {
            return .failed(message: disconnectedFailureMessage)
        }
        return .waiting
    }
}

