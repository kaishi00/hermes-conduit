//
//  AppState+VoiceHostTools.swift
//  Conduit
//
//  A live voice call reads the user's shared health data straight from the
//  Hermes host, when the user lets that voice mode read it (Settings >
//  Health, off by default: what it reads goes to the mode's company). Each
//  read is sealed with this iPhone's own health key and answered only for
//  this iPhone's data. The phone logs every read whose answer reached the
//  call (what went to the mode's company), since it makes them all.
//  (designs/voice-health-location.md)
//

import Foundation
import OSLog

extension AppState {
    static let voiceToolsCapability = "voice-tools"
    static let voiceToolsPath = "/api/plugins/conduit_push/voice-tools"
    static let voiceToolsLog = Logger(subsystem: "com.milim.relay", category: "voice-tools")

    /// The host tools a call on `mode` may use: health, when the user lets
    /// `mode` read it and its dashboard and profile are the ones in use.
    /// Starts a health sync too, so the call reads fresh numbers.
    func voiceHostTools(for mode: LiveVoiceModeName) async -> [VoiceHostTool] {
        let preferences = healthSyncPreferences
        guard preferences.letsVoiceRead(mode), let destination = preferences.destination,
              activeDashboardID == destination.dashboardID, activeProfile == destination.profile,
              notifierPlugin.reports(Self.voiceToolsCapability), let bridge = dashboardTicketBridge else { return [] }
        // Not waited on: the call starts now and reads what has arrived by
        // the time it asks. A key from before voice reads is replaced here.
        if !healthSync.isSyncing { Task { await runHealthSync(reason: .voiceCall) } }
        do {
            let response = try await bridge.requestJSON(
                path: DashboardPath.withProfile(Self.voiceToolsPath, profile: destination.profile),
                method: "GET", body: nil, timeoutMilliseconds: 5_000)
            return VoiceHostTool.tools(from: response).filter { $0.key == "health" }
        } catch {
            Self.voiceToolsLog.info("Voice tools unavailable: \(HealthSyncEngine.describe(error), privacy: .public)")
            return []
        }
    }

    /// One sealed read for the running call. What the model hears back.
    func callVoiceHostTool(_ tool: VoiceHostTool, arguments: [String: Any], mode: LiveVoiceModeName?) async -> [String: String] {
        // Checked again at each read: the user may have turned it off mid-call.
        let preferences = healthSyncPreferences
        guard let mode, tool.key == "health", preferences.letsVoiceRead(mode),
              let destination = preferences.destination, activeDashboardID == destination.dashboardID,
              activeProfile == destination.profile, let bridge = dashboardTicketBridge else {
            return ["error": "The user hasn't let this voice call read their health data, or it isn't reachable now."]
        }
        guard let readKey = healthSync.voiceReadKey() else {
            return ["error": "Health data isn't ready for voice yet; it will be after the next sync."]
        }
        let deviceID = readKey.deviceID
        let key = readKey.key
        let callID = HealthSyncCrypto.newCallID()
        do {
            let request: [String: Any] = ["call_id": callID, "args": arguments, "provider": mode.storageID]
            // JSONSerialization raises, rather than throws, on anything else.
            guard JSONSerialization.isValidJSONObject(request) else { return ["error": "Those arguments aren't valid."] }
            let plaintext = try JSONSerialization.data(withJSONObject: request)
            let envelope = try HealthSyncCrypto.voiceRequest(tool: tool.name, plaintext: plaintext, key: key,
                                                             deviceID: deviceID, callID: callID)
            let response = try await bridge.requestJSON(
                path: DashboardPath.withProfile("\(Self.voiceToolsPath)/call", profile: destination.profile),
                method: "POST", body: envelope, timeoutMilliseconds: 12_000)
            let result = try HealthSyncCrypto.openVoiceAnswer(response, tool: tool.name, key: key,
                                                                deviceID: deviceID, callID: callID)
            HealthVoiceReadLog.record(mode: mode, action: arguments["action"] as? String ?? "")
            return VoiceHostTool.modelResult(result)
        } catch {
            Self.voiceToolsLog.info("Voice read failed: \(HealthSyncEngine.describe(error), privacy: .public)")
            // The detail stays in the log: it can name the host, and the
            // model's company would get it.
            return ["error": "The health data couldn't be read just now."]
        }
    }

    /// Bumped by each call's prepare, so an older one still fetching can't
    /// hand its mode's tools (and that mode's consent) to a newer call.
    @MainActor private static var voiceToolsGeneration = 0
    /// The mode the published tools were prepared for.
    @MainActor private static var voiceToolsMode: LiveVoiceModeName?

    /// Sets the running call's host tools for `mode`.
    func prepareVoiceHostTools(for mode: LiveVoiceModeName) async {
        let supervisor = voiceBackgroundJobSupervisor
        Self.voiceToolsGeneration += 1
        let mine = Self.voiceToolsGeneration
        // A reconnect on the same mode keeps its tools while this fetches
        // (each read still checks consent); another mode's go now.
        if Self.voiceToolsMode != mode {
            supervisor.hostTools = []
            supervisor.runHostTool = nil
            Self.voiceToolsMode = nil
        }
        let tools = await voiceHostTools(for: mode)
        guard mine == Self.voiceToolsGeneration else { return }
        Self.voiceToolsMode = mode
        supervisor.hostTools = tools
        supervisor.runHostTool = { [weak self] tool, arguments in
            await self?.callVoiceHostTool(tool, arguments: arguments, mode: mode)
                ?? ["error": "That isn't available on this call."]
        }
    }
}
