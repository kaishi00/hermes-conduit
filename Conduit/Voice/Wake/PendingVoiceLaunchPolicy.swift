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

/// Connection facts the pending-voice router needs, derived once from
/// `AppState` so the policy stays free of Combine / live app state.
struct VoiceLaunchConnectionSnapshot: Equatable {
    enum Phase: String, Equatable {
        /// Hermes is live — consume the request exactly once.
        case connected
        /// A connect/reconnect attempt is in flight; keep waiting.
        case connecting
        /// Not connected, not connecting, and AppState recorded a real
        /// login/connection failure (or auth-required presentation).
        case stableFailure
        /// Disconnected with no conclusive evidence yet — short cold-launch
        /// window before async credential restore marks itself connecting.
        case inconclusive
    }

    var isConnected: Bool
    var isConnecting: Bool
    /// Positive lifecycle evidence of a terminal failure for this launch.
    /// Never inferred from `!isConnecting` alone.
    var hasStableFailureEvidence: Bool
    /// Classified failure when available (better user-facing copy).
    var classifiedFailure: ConnectionFailure?

    var phase: Phase {
        if isConnected { return .connected }
        // An in-flight attempt outranks a previous attempt's failure: the
        // classifier often stays set until the next successful connect.
        if isConnecting { return .connecting }
        if hasStableFailureEvidence { return .stableFailure }
        return .inconclusive
    }
}

extension AppState {
    /// Deterministic snapshot for external voice-launch routing. Stable
    /// failure means recorded lifecycle evidence (`lastConnectionFailure` or
    /// a presented login failure) — not merely “not connecting right now.”
    func voiceLaunchConnectionSnapshot() -> VoiceLaunchConnectionSnapshot {
        VoiceLaunchConnectionSnapshot(
            isConnected: isConnected,
            isConnecting: isConnecting,
            hasStableFailureEvidence: lastConnectionFailure != nil
                || pendingLoginFailure != nil,
            classifiedFailure: lastConnectionFailure
        )
    }
}

/// Pure decisions for external (Siri) voice launches. Kept free of App
/// Intents and networking so unit tests can cover the policy without
/// mocking the framework or a live socket.
enum PendingVoiceLaunchPolicy {
    /// Backstop budget for a Siri-triggered launch whose connection stays
    /// inconclusive (never connected, never recorded a stable failure, never
    /// finished the first bootstrap attempt). Not the primary failure
    /// detector: known stable failures fail immediately via the snapshot.
    static let externalLaunchBudget: TimeInterval = 30

    /// User-visible explanation when an external launch cannot start voice
    /// and AppState has no classified failure to show.
    static let disconnectedFailureMessage =
        "Conduit could not connect to Hermes, so voice did not start. Ask again after the connection is restored."

    /// User-visible explanation when a pending Siri request outlived its
    /// launch window without a conclusive ready/failed outcome.
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

    /// User-facing failure copy for a stable connection failure. Prefer the
    /// classified ConnectionFailure copy when AppState recorded one.
    static func stableFailureMessage(
        for connection: VoiceLaunchConnectionSnapshot
    ) -> String {
        if let failure = connection.classifiedFailure {
            return "\(failure.userTitle). \(failure.userMessage) Voice did not start — ask Siri again after reconnecting."
        }
        return disconnectedFailureMessage
    }

    /// Lifecycle decision for a pending external launch.
    ///
    /// - Connected → ready (exactly once).
    /// - Connecting / inconclusive → wait (Siri window still open).
    /// - Stable failure (positive evidence, not connecting) → terminal fail
    ///   for Siri; do not wait out the deadline.
    /// - Deadline expiry → terminal fail even if still inconclusive.
    static func readiness(
        for intent: PendingVoiceIntent,
        connection: VoiceLaunchConnectionSnapshot,
        now: Date
    ) -> Readiness {
        if let deadline = intent.externalLaunchDeadline, now > deadline {
            return .failed(message: expiredFailureMessage)
        }
        switch connection.phase {
        case .connected:
            return .ready
        case .connecting, .inconclusive:
            // In-app launches (composer / wake) have no deadline and keep
            // “wait until connected.” Siri requests inside their window also
            // wait for the normal connection attempt / bootstrap.
            return .waiting
        case .stableFailure:
            if intent.source == .siri {
                return .failed(message: stableFailureMessage(for: connection))
            }
            return .waiting
        }
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
