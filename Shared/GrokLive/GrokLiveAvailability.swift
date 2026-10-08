//
//  GrokLiveAvailability.swift
//  Conduit and the Conduit Watch app
//
//  Whether the Hermes host can serve Grok Live, and the seam a Grok Live
//  session opens its connections through: the phone's dashboard relay
//  (GrokLiveClient), or the Watch's audio bridge through the push relay.
//

import Foundation

enum GrokLiveAvailability: Equatable {
    /// `auth` is "subscription" (SuperGrok) or "api_key".
    case available(model: String, voice: String?, auth: String?)
    /// Reachable, but the host cannot serve Grok Live (no xAI sign-in…).
    /// `reason` is the host's own explanation when it gave one.
    case unavailable(reason: String?)
    /// The conduit_push plugin (or its Grok Live routes) is not installed.
    case pluginMissing

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// What Voice settings and the Grok Live sheet show.
    var userFacingReason: String? {
        switch self {
        case .available:
            return nil
        case .unavailable(let reason):
            if let reason, !reason.isEmpty {
                return AppLocalization.string("Grok Live is not available on this Hermes server: \(reason)")
            }
            return AppLocalization.string("Grok Live is not available on this Hermes server.")
        case .pluginMissing:
            return AppLocalization.string("Install or update the Hermes notifier plugin on your Hermes server.")
        }
    }
}

@MainActor
protocol GrokLiveConnecting: AnyObject {
    func availability() async throws -> GrokLiveAvailability
    /// The upgrade request for one relay connection, with a fresh
    /// single-use ticket: call once per WebSocket.
    func socketRequest() async throws -> URLRequest
}
