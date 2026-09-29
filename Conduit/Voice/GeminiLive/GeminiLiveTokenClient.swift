//
//  GeminiLiveTokenClient.swift
//  Conduit
//
//  Gemini Live credentials come from the Hermes host, never the phone: the
//  conduit_push dashboard plugin keeps GEMINI_API_KEY and mints a
//  single-use Google ephemeral token per WebSocket connection. Conduit
//  calls it through the same authenticated dashboard bridge it uses for
//  /api/audio/*.
//

import Foundation
import OSLog

private let geminiLiveMemoryLogger = Logger(subsystem: "com.milim.relay", category: "GeminiLiveMemory")

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

/// A quick lookup the host couldn't answer. Its text goes to the model,
/// not the screen.
struct GeminiLiveWebSearchError: LocalizedError, Equatable {
    let reason: String
    var errorDescription: String? { reason }
}

/// A memory recall the host couldn't answer. Its text goes to the model,
/// not the screen.
struct GeminiLiveMemoryError: LocalizedError, Equatable {
    let reason: String
    var errorDescription: String? { reason }
}

/// What the Hermes host remembers, for a Gemini Live conversation: the
/// memory it gives its own agent, and whether its memory provider can be
/// searched for more.
struct GeminiLiveMemoryContext: Equatable {
    let text: String
    let canRecall: Bool
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

/// One web result for a quick lookup.
struct GeminiLiveWebResult: Equatable {
    let title: String
    let url: String
    let snippet: String
}

/// Quick lookups on the Hermes host's own web search backend.
@MainActor
protocol GeminiLiveWebSearching: AnyObject {
    func webSearch(query: String) async throws -> [GeminiLiveWebResult]
}

/// Searches the Hermes host's memory provider, whichever one it runs.
@MainActor
protocol GeminiLiveMemoryRecalling: AnyObject {
    func recallMemory(query: String) async throws -> String
}

@MainActor
final class GeminiLiveTokenClient: GeminiLiveTokenProviding, GeminiLiveWebSearching, GeminiLiveMemoryRecalling {
    static let statusPath = "/api/plugins/conduit_push/gemini-live/status"
    static let tokenPath = "/api/plugins/conduit_push/gemini-live/token"
    static let webSearchStatusPath = "/api/plugins/conduit_push/web-search/status"
    static let webSearchPath = "/api/plugins/conduit_push/web-search"
    static let memoryContextPath = "/api/plugins/conduit_push/memory/context"
    static let memoryRecallPath = "/api/plugins/conduit_push/memory/recall"
    static let personalityPath = "/api/plugins/conduit_push/personality"
    /// Results a lookup asks for: enough to answer, short enough to read.
    static let webSearchLimit = 3

    /// The authenticated dashboard request, injected so tests can script
    /// responses. Production binds it to `DashboardTicketBridge.requestJSON`.
    typealias Request = @MainActor (_ path: String, _ method: String, _ body: [String: Any]?) async throws -> [String: Any]

    private let request: Request
    /// The Hermes profile whose key the host should use, read at call time
    /// (same `?profile=` scoping as /api/audio/*).
    private let profile: @MainActor () -> String

    init(profile: @escaping @MainActor () -> String = { "default" }, request: @escaping Request) {
        self.profile = profile
        self.request = request
    }

    convenience init(bridge: DashboardTicketBridge, profile: @escaping @MainActor () -> String) {
        self.init(profile: profile, request: { [weak bridge] path, method, body in
            guard let bridge else { throw DashboardTicketBridgeError.notReady }
            return try await bridge.requestJSON(path: path, method: method, body: body)
        })
    }

    private func scoped(_ path: String) -> String {
        DashboardPath.withProfile(path, profile: profile())
    }

    func availability() async throws -> GeminiLiveAvailability {
        let response: [String: Any]
        do {
            response = try await request(scoped(Self.statusPath), "GET", nil)
        } catch let error as DashboardTicketBridgeError {
            if Self.isMissingRoute(error) { return .pluginMissing }
            throw error
        }
        return Self.availability(from: response)
    }

    func freshToken() async throws -> GeminiLiveToken {
        let response: [String: Any]
        do {
            response = try await request(scoped(Self.tokenPath), "POST", [:])
        } catch let error as DashboardTicketBridgeError {
            if Self.isMissingRoute(error) { throw GeminiLiveTokenError.unavailable(.pluginMissing) }
            throw error
        }
        return try Self.token(from: response)
    }

    /// Whether the host can answer quick lookups with its own backend. Any
    /// failure (an older plugin without the route, no backend) is false.
    func webSearchAvailable() async -> Bool {
        guard let response = try? await request(scoped(Self.webSearchStatusPath), "GET", nil) else { return false }
        return response["ok"] as? Bool == true && response["available"] as? Bool == true
    }

    func webSearch(query: String) async throws -> [GeminiLiveWebResult] {
        let response = try await request(scoped(Self.webSearchPath), "POST", ["query": query, "limit": Self.webSearchLimit])
        return try Self.webResults(from: response)
    }

    /// The host's memory for a new conversation. Nil when there is none
    /// or the plugin predates the route: the conversation goes on without.
    func memoryContext() async -> GeminiLiveMemoryContext? {
        do {
            let response = try await request(scoped(Self.memoryContextPath), "GET", nil)
            return Self.memoryContext(from: response)
        } catch let error as DashboardTicketBridgeError where Self.isMissingRoute(error) {
            geminiLiveMemoryLogger.notice("Hermes plugin has no memory route; Gemini Live starts without memory")
            return nil
        } catch {
            // Memory is extra context: the conversation still starts, but
            // the failure is logged rather than lost.
            geminiLiveMemoryLogger.error("Hermes memory context failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The profile's SOUL.md persona for a new conversation. Nil when it
    /// has none or the plugin predates the route.
    func personality() async -> String? {
        do {
            let response = try await request(scoped(Self.personalityPath), "GET", nil)
            return Self.personality(from: response)
        } catch let error as DashboardTicketBridgeError where Self.isMissingRoute(error) {
            geminiLiveMemoryLogger.notice("Hermes plugin has no personality route; Gemini Live starts without a persona")
            return nil
        } catch {
            geminiLiveMemoryLogger.error("Hermes personality failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func recallMemory(query: String) async throws -> String {
        let response = try await request(scoped(Self.memoryRecallPath), "POST", ["query": query])
        return try Self.memoryRecall(from: response)
    }

    // MARK: Parsing (static for tests)

    /// The most memory a conversation's instructions carry.
    static let memoryContextLimit = 8000
    /// The most a single recall hands the model.
    static let memoryRecallLimit = 4000

    static func memoryContext(from response: [String: Any]) -> GeminiLiveMemoryContext? {
        guard response["ok"] as? Bool == true, response["available"] as? Bool == true else { return nil }
        let text = String((response["context"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(memoryContextLimit))
        let canRecall = response["recall"] as? Bool == true
        guard !text.isEmpty || canRecall else { return nil }
        return GeminiLiveMemoryContext(text: text, canRecall: canRecall)
    }

    /// The most persona a conversation's instructions carry.
    static let personalityLimit = 8000

    static func personality(from response: [String: Any]) -> String? {
        guard response["ok"] as? Bool == true, response["available"] as? Bool == true else { return nil }
        let text = String((response["text"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(personalityLimit))
        return text.isEmpty ? nil : text
    }

    static func memoryRecall(from response: [String: Any]) throws -> String {
        guard response["ok"] as? Bool == true, response["available"] as? Bool != false,
              let results = response["results"] as? String else {
            let reason = response["detail"] as? String ?? response["error"] as? String ?? response["reason"] as? String
            throw GeminiLiveMemoryError(reason: reason.flatMap { $0.isEmpty ? nil : $0 } ?? "Hermes memory is not available")
        }
        return String(results.trimmingCharacters(in: .whitespacesAndNewlines).prefix(memoryRecallLimit))
    }

    static func webResults(from response: [String: Any]) throws -> [GeminiLiveWebResult] {
        guard response["ok"] as? Bool == true, let items = response["results"] as? [[String: Any]] else {
            let reason = response["detail"] as? String ?? response["error"] as? String ?? response["reason"] as? String
            throw GeminiLiveWebSearchError(reason: reason.flatMap { $0.isEmpty ? nil : $0 } ?? "The Hermes web search returned no results")
        }
        return items.compactMap { item in
            guard let url = item["url"] as? String, !url.isEmpty else { return nil }
            return GeminiLiveWebResult(
                title: item["title"] as? String ?? "",
                url: url,
                snippet: item["snippet"] as? String ?? ""
            )
        }
    }

    static func isMissingRoute(_ error: DashboardTicketBridgeError) -> Bool {
        if case .http(let status, _) = error { return status == 404 || status == 410 }
        return false
    }

    static func availability(from response: [String: Any]) -> GeminiLiveAvailability {
        let reason = response["reason"] as? String ?? response["error"] as? String
        guard response["ok"] as? Bool == true else { return .unavailable(reason: reason) }
        guard response["available"] as? Bool == true else { return .unavailable(reason: reason) }
        let model = (response["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? GeminiLiveProtocol.model
        return .available(model: model)
    }

    static func token(from response: [String: Any]) throws -> GeminiLiveToken {
        guard response["ok"] as? Bool == true else {
            let reason = response["reason"] as? String ?? response["error"] as? String
            throw GeminiLiveTokenError.unavailable(.unavailable(reason: reason))
        }
        guard let token = response["token"] as? String, !token.isEmpty,
              let urlString = response["websocket_url"] as? String,
              let url = URL(string: urlString),
              url.scheme?.lowercased() == "wss" else {
            throw GeminiLiveTokenError.malformedResponse
        }
        let model = (response["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? GeminiLiveProtocol.model
        return GeminiLiveToken(
            token: token,
            expiresAt: date(response["expires_at"]),
            newSessionExpiresAt: date(response["new_session_expires_at"]),
            model: model,
            webSocketURL: url
        )
    }

    /// ISO 8601 (with or without fractional seconds) or epoch seconds.
    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        guard let string = value as? String, !string.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}
