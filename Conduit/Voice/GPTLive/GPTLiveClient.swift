//
//  GPTLiveClient.swift
//  Conduit
//
//  GPT-Live starts on the Hermes host, never the phone: the conduit_push
//  dashboard plugin holds the host's Codex (ChatGPT) sign-in, exchanges
//  Conduit's WebRTC offer for GPT-Live's answer, and bills the ChatGPT
//  subscription. The OAuth token never reaches Conduit, and there is no
//  API-key fallback: every failure is reported, never worked around.
//

import Foundation

enum GPTLiveAvailability: Equatable {
    case available(model: String, voice: String?)
    /// Reachable, but the host cannot serve GPT-Live (no Codex sign-in…).
    /// `reason` is the host's own explanation when it gave one.
    case unavailable(reason: String?)
    /// The conduit_push plugin (or its GPT-Live routes) is not installed.
    case pluginMissing

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// What Voice settings and the GPT-Live sheet show.
    var userFacingReason: String? {
        switch self {
        case .available:
            return nil
        case .unavailable(let reason):
            if let reason, !reason.isEmpty {
                return AppLocalization.string("GPT-Live is not available on this Hermes server: \(reason)")
            }
            return AppLocalization.string("GPT-Live is not available on this Hermes server.")
        case .pluginMissing:
            return AppLocalization.string("Install or update the Hermes notifier plugin on your Hermes server.")
        }
    }
}

/// The host's answer to Conduit's offer.
struct GPTLiveSessionAnswer: Equatable {
    let sessionID: String?
    let sdp: String
    /// The voice the host started the call with; nil from a host that
    /// doesn't report it (an older plugin).
    var voice: String? = nil
    /// True when the host put Conduit's briefing into the session's
    /// instructions; an older plugin ignores it and the briefing must be sent
    /// as context after the call starts.
    var briefingApplied: Bool = false
}

enum GPTLiveClientError: LocalizedError, Equatable {
    case unavailable(GPTLiveAvailability)
    /// The host refused or failed the exchange. `detail` is its own message
    /// (which always says no API fallback was used), shown as-is.
    case host(String)
    case malformedResponse
    /// The host answered with something other than subscription billing.
    case notSubscription(String?)

    var errorDescription: String? {
        switch self {
        case .unavailable(let availability):
            return availability.userFacingReason
        case .host(let detail):
            return detail
        case .malformedResponse:
            return AppLocalization.string("Hermes returned an invalid GPT-Live answer.")
        case .notSubscription:
            return AppLocalization.string("Hermes did not start GPT-Live on the ChatGPT subscription, so Conduit did not connect.")
        }
    }
}

@MainActor
protocol GPTLiveSessionProviding: AnyObject {
    func availability() async throws -> GPTLiveAvailability
    /// Exchanges a WebRTC offer for GPT-Live's answer. `history` seeds the
    /// conversation (the host passes it as `initial_items`).
    /// `voice` overrides the host's configured voice for this call.
    /// `briefing` is Conduit's rules, persona and memory for this call: the
    /// host adds it to the session's instructions.
    func createSession(offer: String, history: [[String: Any]], voice: String?, briefing: String?) async throws -> GPTLiveSessionAnswer
}

@MainActor
final class GPTLiveClient: GPTLiveSessionProviding {
    static let statusPath = "/api/plugins/conduit_push/gpt-live/status"
    static let sessionPath = "/api/plugins/conduit_push/gpt-live/session"
    /// The host gives OpenAI 30 s and itself 32 s; wait a little longer so
    /// its own timeout message is the one the user sees.
    static let sessionTimeoutMilliseconds = 40_000

    /// The authenticated dashboard request, injected so tests can script
    /// responses. Production binds it to `DashboardTicketBridge.requestJSON`.
    typealias Request = @MainActor (_ path: String, _ method: String, _ body: [String: Any]?, _ timeoutMilliseconds: Int) async throws -> [String: Any]

    private let request: Request
    /// The Hermes profile whose sign-in and settings the host uses.
    private let profile: @MainActor () -> String

    init(profile: @escaping @MainActor () -> String = { "default" }, request: @escaping Request) {
        self.profile = profile
        self.request = request
    }

    private func scoped(_ path: String) -> String {
        DashboardPath.withProfile(path, profile: profile())
    }

    func availability() async throws -> GPTLiveAvailability {
        let response: [String: Any]
        do {
            response = try await request(scoped(Self.statusPath), "GET", nil, 12_000)
        } catch let error as DashboardTicketBridgeError {
            if GeminiLiveTokenClient.isMissingRoute(error) { return .pluginMissing }
            throw error
        }
        return Self.availability(from: response)
    }

    func createSession(offer: String, history: [[String: Any]], voice: String? = nil, briefing: String? = nil) async throws -> GPTLiveSessionAnswer {
        var body: [String: Any] = ["sdp": offer]
        if let briefing, !briefing.isEmpty { body["briefing"] = briefing }
        if !history.isEmpty { body["history"] = history }
        if let voice, !voice.isEmpty { body["voice"] = voice }
        let response: [String: Any]
        do {
            response = try await request(scoped(Self.sessionPath), "POST", body, Self.sessionTimeoutMilliseconds)
        } catch let error as DashboardTicketBridgeError {
            if GeminiLiveTokenClient.isMissingRoute(error) { throw GPTLiveClientError.unavailable(.pluginMissing) }
            // The host's `detail` already names the problem and says no API
            // fallback was used: shown as it is.
            if case .http(_, let detail) = error, !detail.isEmpty { throw GPTLiveClientError.host(detail) }
            throw error
        }
        return try Self.answer(from: response)
    }

    // MARK: Parsing (static for tests)

    static func availability(from response: [String: Any]) -> GPTLiveAvailability {
        let reason = response["reason"] as? String ?? response["detail"] as? String ?? response["error"] as? String
        guard response["ok"] as? Bool == true, response["available"] as? Bool == true else {
            return .unavailable(reason: reason)
        }
        // Only the subscription route is ever used; anything else (or a host
        // that doesn't say) is not GPT-Live on this plan.
        guard response["auth"] as? String == "subscription" else {
            return .unavailable(reason: reason)
        }
        let model = (response["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "gpt-live"
        let voice = (response["voice"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return .available(model: model, voice: voice)
    }

    static func answer(from response: [String: Any]) throws -> GPTLiveSessionAnswer {
        guard response["ok"] as? Bool == true else {
            let detail = response["detail"] as? String ?? response["reason"] as? String ?? response["error"] as? String
            if let detail, !detail.isEmpty { throw GPTLiveClientError.host(detail) }
            throw GPTLiveClientError.malformedResponse
        }
        guard response["auth"] as? String == "subscription" else {
            throw GPTLiveClientError.notSubscription(response["auth"] as? String)
        }
        guard let transport = response["transport"] as? [String: Any],
              transport["type"] as? String == "webrtc",
              let sdp = transport["sdp"] as? String, sdp.hasPrefix("v=0") else {
            throw GPTLiveClientError.malformedResponse
        }
        let sessionID = (response["session"] as? [String: Any])?["id"] as? String
        let voice = (response["voice"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return GPTLiveSessionAnswer(sessionID: sessionID, sdp: sdp, voice: voice, briefingApplied: response["briefing_applied"] as? Bool == true)
    }
}
