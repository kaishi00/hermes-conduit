//
//  GeminiLiveToken.swift
//  Conduit and the Conduit Watch app
//
//  Gemini Live's single-use tokens and the host's availability, moved out
//  of GeminiLiveTokenClient.swift unchanged so the Watch can run
//  GeminiLiveSession too (designs/apple-watch-voice-direct.md). Fetching
//  them stays on the iPhone: only it can reach the Hermes host.
//

import Foundation

enum GeminiLiveAvailability: Equatable {
    case available(model: String)
    /// Reachable, but the host cannot serve Gemini Live (no key, plugin
    /// disabled…). `reason` is the host's own explanation when it gave one.
    case unavailable(reason: String?)
    /// The conduit_push plugin (or its Gemini Live routes) is not installed.
    case pluginMissing

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// What Voice settings and the Voice sheet show. Never a silent
    /// fallback: when Gemini Live cannot run, the user is told why.
    var userFacingReason: String? {
        switch self {
        case .available:
            return nil
        case .unavailable(let reason):
            if let reason, !reason.isEmpty {
                if reason == "no_api_key" {
                    return AppLocalization.string("Add a Gemini API key on your Hermes server.")
                }
                return AppLocalization.string("Gemini Live is not available on this Hermes server: \(reason)")
            }
            return AppLocalization.string("Gemini Live is not available on this Hermes server.")
        case .pluginMissing:
            return AppLocalization.string("Install or update the Hermes notifier plugin on your Hermes server.")
        }
    }
}

struct GeminiLiveToken: Equatable {
    let token: String
    let expiresAt: Date?
    let newSessionExpiresAt: Date?
    let model: String
    let webSocketURL: URL

    /// The URL to open: the plugin's WebSocket URL with the single-use token
    /// as `access_token` (kept if the plugin already appended it).
    var connectURL: URL {
        guard var components = URLComponents(url: webSocketURL, resolvingAgainstBaseURL: false) else {
            return webSocketURL
        }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == "access_token" }) {
            items.append(URLQueryItem(name: "access_token", value: token))
        }
        components.queryItems = items
        return components.url ?? webSocketURL
    }
}

enum GeminiLiveTokenError: LocalizedError, Equatable {
    case unavailable(GeminiLiveAvailability)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .unavailable(let availability):
            return availability.userFacingReason
        case .malformedResponse:
            return AppLocalization.string("Hermes returned an invalid Gemini Live token.")
        }
    }
}

@MainActor
protocol GeminiLiveTokenProviding: AnyObject {
    func availability() async throws -> GeminiLiveAvailability
    /// A fresh single-use token. Call once per WebSocket connection,
    /// including resumptions: tokens are never reused.
    func freshToken() async throws -> GeminiLiveToken
}
