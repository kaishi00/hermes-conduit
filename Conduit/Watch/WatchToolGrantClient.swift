//
//  WatchToolGrantClient.swift
//  Conduit
//
//  Asks the Hermes host's conduit_push plugin for a Watch call's tool grant
//  and ends it again (designs/apple-watch-voice-direct.md, "Wrist-down
//  tools through the relay"). The grant lets the Watch run web_search and
//  recall_memory through the push relay while it can't reach this phone,
//  and with the user's job setting Hermes jobs: one call, one profile,
//  those tools, half an hour, a call and job budget. It goes to the Watch
//  only; nothing here logs or keeps its keys.
//

import Foundation

@MainActor
final class WatchToolGrantClient {
    static let grantPath = "/api/plugins/conduit_push/watch-tools/grant"
    static let revokePath = "/api/plugins/conduit_push/watch-tools/revoke"
    /// Short: the grant is asked for while the call is set up, and a call
    /// without one still works through this phone.
    static let timeoutMilliseconds = 4_000

    private let request: GeminiLiveTokenClient.Request

    init(request: @escaping GeminiLiveTokenClient.Request) {
        self.request = request
    }

    /// A client for whichever Hermes dashboard is active when it asks.
    static func activeDashboard() -> WatchToolGrantClient {
        WatchToolGrantClient(request: { path, method, body, timeout in
            guard let bridge = AppStateRuntimeRegistry.shared.appState.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
            return try await bridge.requestJSON(path: path, method: method, body: body, timeoutMilliseconds: timeout)
        })
    }

    /// Throws when the host can't grant one: an older plugin or relay, no
    /// notification pairing, no network. The call's lookups then go
    /// through this phone only, as before.
    /// `maxJobs`, `jobOptions` (the voice-job model, provider and
    /// reasoning effort) and `carryJobsFrom` (a renewal's previous grant,
    /// whose jobs move to the new one) and `jobProfiles` (the user's other
    /// profiles a job may run on) go with job tools only. `audio`
    /// adds the call's audio bridge (GPT-Live on the Watch), which starts
    /// on the host with the grant.
    func grant(tools: [String], profile: String, maxJobs: Int? = nil, jobOptions: [String: String] = [:], carryJobsFrom: String? = nil, jobProfiles: [String] = [], audio: Bool = false) async throws -> WatchVoiceWire.DirectToolGrant {
        var body: [String: Any] = ["tools": tools]
        if audio { body["audio"] = true }
        if !WatchJobAnswer.tools.isDisjoint(with: tools) {
            if let maxJobs { body["max_jobs"] = maxJobs }
            if !jobOptions.isEmpty { body["job_options"] = jobOptions }
            if let carryJobsFrom { body["carry_jobs_from"] = carryJobsFrom }
            body["job_profiles"] = jobProfiles
        }
        let response = try await request(
            DashboardPath.withProfile(Self.grantPath, profile: profile),
            "POST",
            body,
            Self.timeoutMilliseconds
        )
        guard let grant = Self.grant(from: response) else { throw WatchDirectPrepareError(AppLocalization.string("The Watch tool grant couldn't be read.")) }
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

    static let audioStatusPath = "/api/plugins/conduit_push/watch-audio/status"
    static let audioPreparePath = "/api/plugins/conduit_push/watch-audio/prepare"

    /// GPT-Live's WebRTC runtime on the host: ready, preparing, failed or
    /// missing, with the host's reason when it isn't ready.
    struct AudioRuntime: Equatable {
        var runtime: String
        var reason: String?
    }

    /// Starts making the runtime unless it's there or on its way. The host
    /// makes it in the background and answers at once.
    func prepareAudio(profile: String) async throws -> AudioRuntime {
        let response = try await request(DashboardPath.withProfile(Self.audioPreparePath, profile: profile), "POST", [:], Self.timeoutMilliseconds)
        return Self.audioRuntime(from: response)
    }

    func audioStatus(profile: String) async throws -> AudioRuntime {
        let response = try await request(DashboardPath.withProfile(Self.audioStatusPath, profile: profile), "GET", nil, Self.timeoutMilliseconds)
        return Self.audioRuntime(from: response)
    }

    static func audioRuntime(from response: [String: Any]) -> AudioRuntime {
        let engines = response["engines"] as? [String: Any]
        let gptLive = engines?[WatchAudioBridgeWire.gptLive] as? [String: Any]
        return AudioRuntime(runtime: gptLive?["runtime"] as? String ?? "missing", reason: gptLive?["reason"] as? String)
    }

    static func grant(from response: [String: Any]) -> WatchVoiceWire.DirectToolGrant? {
        guard response["ok"] as? Bool == true,
              let grantID = response["grant_id"] as? String, !grantID.isEmpty,
              let relayURL = response["relay_url"] as? String, relayURL.hasPrefix("https://"),
              let key = response["key"] as? String, !key.isEmpty,
              let watchKey = response["watch_key"] as? String, !watchKey.isEmpty,
              let tools = response["tools"] as? [String], !tools.isEmpty,
              let maxCalls = response["max_calls"] as? Int, maxCalls > 0 else { return nil }
        var bridge: WatchVoiceWire.AudioBridge?
        if let audio = response["audio"] as? [String: Any],
           let url = audio["url"] as? String, url.hasPrefix("wss://"),
           let version = audio["version"] as? Int {
            bridge = .init(url: url, version: version, engines: audio["engines"] as? [String] ?? [])
        }
        return WatchVoiceWire.DirectToolGrant(
            grantID: grantID,
            relayURL: relayURL,
            key: key,
            watchKey: watchKey,
            expiresAt: GeminiLiveTokenClient.date(response["expires_at"]),
            tools: tools,
            maxCalls: maxCalls,
            maxJobs: response["max_jobs"] as? Int,
            jobsCarriedFrom: response["jobs_carried_from"] as? String,
            audio: bridge,
            // The host's names only; the iPhone fills in what each goes by.
            jobProfiles: (response["job_profiles"] as? [String]).map { $0.map { .init(profile: $0, names: [$0]) } }
        )
    }
}
