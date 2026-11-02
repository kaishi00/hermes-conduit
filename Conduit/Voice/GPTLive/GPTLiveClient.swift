//
//  GPTLiveClient.swift
//  Conduit
//
//  GPT-Live starts on the Hermes host, never the phone: the conduit_push
//  dashboard plugin holds the host's Codex (ChatGPT) sign-in, exchanges
//  Conduit's WebRTC offer for GPT-Live's answer, and bills the ChatGPT
//  subscription. The OAuth token never reaches Conduit.
//
//  A profile can instead choose GPT-Live on the host's OpenAI API key,
//  billed per minute (`GPTLiveBilling.api`). Conduit names the path in
//  every request, the host answers with the path it used (`auth`), and a
//  call whose answer names any other path is dropped before its audio
//  starts. Neither path ever falls back to the other.
//

import Foundation

extension GPTLiveBilling {
    /// The short label the call screen, the minimised bar and Settings
    /// show, so a call always says which path it's on.
    var badge: String {
        switch self {
        case .subscription: return AppLocalization.string("ChatGPT plan")
        case .api: return AppLocalization.string("API key · billed per minute")
        }
    }
}

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
    /// True when the host made the model speak first: a greeting (#290) or
    /// the opening of a call Hermes placed (`call_opening`, #544). An older
    /// plugin keeps it silent and the opening is asked for after the call
    /// starts.
    var greetingApplied: Bool = false
    /// The path the host confirmed it billed. The call speaks that path's
    /// protocol (the subscription's Codex events or the public API's).
    var billing: GPTLiveBilling = .subscription
    /// Who built the session: "hermes" (Hermes' own GPT-Live code) or
    /// "plugin" (the plugin's). Nil from a host that doesn't say. Read
    /// only for the call trace (#1611).
    var source: String? = nil
}

enum GPTLiveClientError: LocalizedError, Equatable {
    case unavailable(GPTLiveAvailability)
    /// The host refused or failed the exchange. `detail` is its own message
    /// (which always says no API fallback was used), shown as-is.
    case host(String)
    case malformedResponse
    /// The host answered with something other than subscription billing.
    case notSubscription(String?)
    /// Asked for the API key, the host answered with another path (an
    /// older plugin answers every request on the subscription).
    case notAPIKey(String?)

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
        case .notAPIKey:
            return AppLocalization.string("Hermes did not start GPT-Live on the API key, so Conduit did not connect. Update the Hermes notifier plugin.")
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
    /// host adds it to the session's instructions. `greeting` (nil for none,
    /// empty for the model's own words) makes the model greet first.
    /// `callOpening` marks a call Hermes placed: the model speaks first with
    /// the opening the briefing gives (#544). Callers send no greeting with
    /// it; the host lets it win over one.
    func createSession(offer: String, history: [[String: Any]], voice: String?, briefing: String?, greeting: String?, callOpening: Bool) async throws -> GPTLiveSessionAnswer
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
    /// The path the next check and call are billed on, read each time so a
    /// change in Settings applies to the next call.
    private let billing: @MainActor () -> GPTLiveBilling

    init(profile: @escaping @MainActor () -> String = { "default" }, billing: @escaping @MainActor () -> GPTLiveBilling = { .subscription }, request: @escaping Request) {
        self.profile = profile
        self.billing = billing
        self.request = request
    }

    private func scoped(_ path: String) -> String {
        DashboardPath.withProfile(path, profile: profile())
    }

    func availability() async throws -> GPTLiveAvailability {
        try await availability(billing: billing())
    }

    /// The readiness of one path, whatever the profile chose: the Watch's
    /// GPT-Live always runs on the subscription.
    func availability(billing: GPTLiveBilling) async throws -> GPTLiveAvailability {
        let response: [String: Any]
        do {
            response = try await request(scoped(Self.statusPath), "GET", nil, 12_000)
        } catch let error as DashboardTicketBridgeError {
            if GeminiLiveTokenClient.isMissingRoute(error) { return .pluginMissing }
            throw error
        }
        return Self.availability(from: response, billing: billing)
    }

    func createSession(offer: String, history: [[String: Any]], voice: String? = nil, briefing: String? = nil, greeting: String? = nil, callOpening: Bool = false) async throws -> GPTLiveSessionAnswer {
        let billing = self.billing()
        // Always named, the subscription too: the host bills only the path
        // asked for (an older plugin ignores it and uses the subscription).
        var body: [String: Any] = ["sdp": offer, "billing": billing.rawValue]
        if let briefing, !briefing.isEmpty { body["briefing"] = briefing }
        if let greeting { body["greeting"] = greeting }
        // An older plugin ignores it and keeps the model silent; Conduit
        // then sends the opening turn itself (greeting_applied false).
        if callOpening { body["call_opening"] = true }
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
        return try Self.answer(from: response, billing: billing)
    }

    // MARK: Parsing (static for tests)

    static func availability(from response: [String: Any], billing: GPTLiveBilling = .subscription) -> GPTLiveAvailability {
        if billing == .api {
            return apiAvailability(from: response)
        }
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

    /// The API-key path's readiness, which the host reports under `api`; a
    /// plugin without it can't start an API-billed call.
    static func apiAvailability(from response: [String: Any]) -> GPTLiveAvailability {
        guard response["ok"] as? Bool == true else {
            return .unavailable(reason: response["reason"] as? String ?? response["detail"] as? String ?? response["error"] as? String)
        }
        guard let api = response["api"] as? [String: Any] else {
            return .unavailable(reason: AppLocalization.string("GPT-Live on an API key needs the Hermes notifier plugin 0.22 or newer."))
        }
        guard api["available"] as? Bool == true, api["auth"] as? String == GPTLiveBilling.api.rawValue else {
            return .unavailable(reason: api["reason"] as? String)
        }
        let model = (api["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "gpt-live-1"
        let voice = (api["voice"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return .available(model: model, voice: voice)
    }

    static func answer(from response: [String: Any], billing: GPTLiveBilling = .subscription) throws -> GPTLiveSessionAnswer {
        guard response["ok"] as? Bool == true else {
            let detail = response["detail"] as? String ?? response["reason"] as? String ?? response["error"] as? String
            if let detail, !detail.isEmpty { throw GPTLiveClientError.host(detail) }
            throw GPTLiveClientError.malformedResponse
        }
        // The path the host billed must be the one asked for, or nothing
        // connects: the peer is closed before any audio flows.
        guard response["auth"] as? String == billing.rawValue else {
            switch billing {
            case .subscription: throw GPTLiveClientError.notSubscription(response["auth"] as? String)
            case .api: throw GPTLiveClientError.notAPIKey(response["auth"] as? String)
            }
        }
        guard let transport = response["transport"] as? [String: Any],
              transport["type"] as? String == "webrtc",
              let sdp = transport["sdp"] as? String, sdp.hasPrefix("v=0") else {
            throw GPTLiveClientError.malformedResponse
        }
        let sessionID = (response["session"] as? [String: Any])?["id"] as? String
        let voice = (response["voice"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return GPTLiveSessionAnswer(
            sessionID: sessionID,
            sdp: sdp,
            voice: voice,
            briefingApplied: response["briefing_applied"] as? Bool == true,
            greetingApplied: response["greeting_applied"] as? Bool == true,
            billing: billing,
            // Only the two names the plugin sends: nothing else the host
            // says reaches the trace.
            source: (response["source"] as? String).flatMap { ["hermes", "plugin"].contains($0) ? $0 : nil }
        )
    }
}
