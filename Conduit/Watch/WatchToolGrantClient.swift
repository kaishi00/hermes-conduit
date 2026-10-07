//
//  WatchToolGrantClient.swift
//  Conduit
//
//  Asks the Hermes host's conduit_push plugin for a Watch call's tool grant
//  and ends it again (designs/apple-watch-voice-direct.md, "Wrist-down
//  tools through the relay"). The grant lets the Watch run web_search and
//  recall_memory through the push relay while it can't reach this phone:
//  one call, one profile, those tools, half an hour, a call budget. It
//  goes to the Watch only; nothing here logs or keeps its keys.
//

import Foundation

@MainActor
final class WatchToolGrantClient {
    static let grantPath = "/api/plugins/conduit_push/watch-tools/grant"
    static let revokePath = "/api/plugins/conduit_push/watch-tools/revoke"
    static let timeoutMilliseconds = 10_000

    private let request: GeminiLiveTokenClient.Request

    init(request: @escaping GeminiLiveTokenClient.Request) {
        self.request = request
    }

    /// Throws when the host can't grant one: an older plugin or relay, no
    /// notification pairing, no network. The call's lookups then go
    /// through this phone only, as before.
    func grant(tools: [String], profile: String) async throws -> WatchVoiceWire.DirectToolGrant {
        let response = try await request(
            DashboardPath.withProfile(Self.grantPath, profile: profile),
            "POST",
            ["tools": tools],
            Self.timeoutMilliseconds
        )
        guard let grant = Self.grant(from: response) else { throw WatchDirectPrepareError("The Watch tool grant couldn't be read.") }
        return grant
    }

    /// Best effort: an unrevoked grant ends on its own within the half hour.
    func revoke(grantID: String, profile: String) async {
        _ = try? await request(
            DashboardPath.withProfile(Self.revokePath, profile: profile),
            "POST",
            ["grant_id": grantID],
            Self.timeoutMilliseconds
        )
    }

    static func grant(from response: [String: Any]) -> WatchVoiceWire.DirectToolGrant? {
        guard response["ok"] as? Bool == true,
              let grantID = response["grant_id"] as? String, !grantID.isEmpty,
              let relayURL = response["relay_url"] as? String, relayURL.hasPrefix("https://"),
              let key = response["key"] as? String, !key.isEmpty,
              let watchKey = response["watch_key"] as? String, !watchKey.isEmpty,
              let tools = response["tools"] as? [String], !tools.isEmpty,
              let maxCalls = response["max_calls"] as? Int, maxCalls > 0 else { return nil }
        return WatchVoiceWire.DirectToolGrant(
            grantID: grantID,
            relayURL: relayURL,
            key: key,
            watchKey: watchKey,
            expiresAt: GeminiLiveTokenClient.date(response["expires_at"]),
            tools: tools,
            maxCalls: maxCalls
        )
    }
}
