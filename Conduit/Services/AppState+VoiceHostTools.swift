//
//  AppState+VoiceHostTools.swift
//  Conduit
//
//  A live voice call reads the user's shared health data and location
//  straight from the Hermes host, when the user lets that voice mode read
//  each one (Settings > Health, Settings > Location; off by default: what
//  it reads goes to the mode's company). Each read is sealed with this
//  iPhone's own key for that data and answered only for this iPhone's data.
//  The phone logs every health read whose answer reached the call; the
//  host's location read log lists location reads as the voice call's.
//  (designs/voice-health-location.md)
//

import Foundation
import OSLog

extension AppState {
    static let voiceToolsCapability = "voice-tools"
    static let voiceToolsPath = "/api/plugins/conduit_push/voice-tools"
    static let voiceToolsLog = Logger(subsystem: "com.milim.relay", category: "voice-tools")

    /// The kinds of data (`VoiceHostTool.key`) a call on `mode` may read
    /// now: each one the user lets `mode` read, shared with the dashboard
    /// and profile in use.
    func voiceReadableKeys(for mode: LiveVoiceModeName) -> Set<String> {
        var keys: Set<String> = []
        let health = healthSyncPreferences
        if health.letsVoiceRead(mode), let destination = health.destination,
           activeDashboardID == destination.dashboardID, activeProfile == destination.profile {
            keys.insert("health")
        }
        let location = LocationSharingController.shared
        if location.letsVoiceRead(mode), let binding = location.binding,
           activeDashboardID == binding.dashboardID, activeProfile == binding.profile {
            keys.insert("location")
        }
        return keys
    }

    /// The host tools a call on `mode` may use: those whose data the user
    /// lets `mode` read. Starts a health sync too, so the call reads fresh
    /// numbers. Nil when the host couldn't be asked (a reconnect then keeps
    /// what it had).
    func voiceHostTools(for mode: LiveVoiceModeName) async -> [VoiceHostTool]? {
        let keys = voiceReadableKeys(for: mode)
        guard !keys.isEmpty else { return [] }
        // The connection or the plugin's report isn't back yet (a gateway
        // restart): can't ask now, which isn't "nothing offered".
        guard notifierPlugin.reports(Self.voiceToolsCapability), let bridge = dashboardTicketBridge else { return nil }
        // Not waited on: the call starts now and reads what has arrived by
        // the time it asks. A key from before voice reads is replaced here.
        if keys.contains("health"), !healthSync.isSyncing { Task { await runHealthSync(reason: .voiceCall) } }
        if keys.contains("location") { Task { await LocationSharingController.shared.prepareVoiceReads() } }
        do {
            let response = try await bridge.requestJSON(
                path: DashboardPath.withProfile(Self.voiceToolsPath, profile: activeProfile),
                method: "GET", body: nil, timeoutMilliseconds: 5_000)
            return VoiceHostTool.tools(from: response).filter { keys.contains($0.key) }
        } catch {
            Self.voiceToolsLog.info("Voice tools unavailable: \(HealthSyncEngine.describe(error), privacy: .public)")
            return nil
        }
    }

    /// One sealed read for the running call. What the model hears back.
    func callVoiceHostTool(_ tool: VoiceHostTool, arguments: [String: Any], mode: LiveVoiceModeName?) async -> [String: String] {
        // Checked again at each read: the user may have turned it off mid-call.
        guard let mode, voiceReadableKeys(for: mode).contains(tool.key), let bridge = dashboardTicketBridge else {
            return ["error": tool.key == "location"
                ? "The user hasn't let this voice call read their location, or it isn't reachable now."
                : "The user hasn't let this voice call read their health data, or it isn't reachable now."]
        }
        switch tool.key {
        case "health":
            return await callHealthVoiceTool(tool, arguments: arguments, mode: mode, bridge: bridge)
        case "location":
            return await callLocationVoiceTool(tool, arguments: arguments, mode: mode, bridge: bridge)
        default:
            return ["error": "That isn't available on this call."]
        }
    }

    /// The request's JSON (`call_id`, `args`, `provider`), or nil when the
    /// arguments aren't JSON.
    private func voiceRequestJSON(callID: String, arguments: [String: Any], mode: LiveVoiceModeName) throws -> Data? {
        let request: [String: Any] = ["call_id": callID, "args": arguments, "provider": mode.storageID]
        // JSONSerialization raises, rather than throws, on anything else.
        guard JSONSerialization.isValidJSONObject(request) else { return nil }
        return try JSONSerialization.data(withJSONObject: request)
    }

    private func voiceCallPath() -> String {
        DashboardPath.withProfile("\(Self.voiceToolsPath)/call", profile: activeProfile)
    }

    private func callHealthVoiceTool(_ tool: VoiceHostTool, arguments: [String: Any], mode: LiveVoiceModeName,
                                     bridge: DashboardTicketBridge) async -> [String: String] {
        guard let readKey = healthSync.voiceReadKey() else {
            return ["error": "Health data isn't ready for voice yet; it will be after the next sync."]
        }
        let deviceID = readKey.deviceID
        let key = readKey.key
        let callID = VoiceReadSeal.newCallID()
        do {
            guard let plaintext = try voiceRequestJSON(callID: callID, arguments: arguments, mode: mode) else {
                return ["error": "Those arguments aren't valid."]
            }
            let envelope = try HealthSyncCrypto.voiceRequest(tool: tool.name, plaintext: plaintext, key: key,
                                                             deviceID: deviceID, callID: callID)
            let response = try await bridge.requestJSON(path: voiceCallPath(), method: "POST", body: envelope,
                                                        timeoutMilliseconds: 12_000)
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

    private func callLocationVoiceTool(_ tool: VoiceHostTool, arguments: [String: Any], mode: LiveVoiceModeName,
                                       bridge: DashboardTicketBridge) async -> [String: String] {
        let controller = LocationSharingController.shared
        guard let key = controller.voiceReadKey() else {
            Task { await controller.prepareVoiceReads() }
            return ["error": "The location isn't ready for voice yet; ask again in a moment."]
        }
        let callID = VoiceReadSeal.newCallID()
        do {
            guard let plaintext = try voiceRequestJSON(callID: callID, arguments: arguments, mode: mode) else {
                return ["error": "Those arguments aren't valid."]
            }
            let envelope = try LocationCrypto.voiceRequest(tool: tool.name, plaintext: plaintext, key: key, callID: callID)
            let response = try await bridge.requestJSON(path: voiceCallPath(), method: "POST", body: envelope,
                                                        timeoutMilliseconds: 12_000)
            let result = try LocationCrypto.openVoiceAnswer(response, tool: tool.name, key: key, callID: callID)
            return VoiceHostTool.modelResult(result)
        } catch {
            Self.voiceToolsLog.info("Voice location read failed: \(LocationSyncEngine.describe(error), privacy: .public)")
            if let bridgeError = error as? DashboardTicketBridgeError, case .http(let status, let detail) = bridgeError,
               status == 409, LocationSyncEngine.needsNewKey(detail) {
                // The host forgot this phone's key (a wipe): the next send
                // agrees a new one.
                Task { await controller.flush(settingsOnly: true) }
            }
            return ["error": "The location couldn't be read just now."]
        }
    }

    /// Bumped by each call's prepare, so an older one still fetching can't
    /// hand its mode's tools (and that mode's consent) to a newer call.
    @MainActor private static var voiceToolsGeneration = 0

    /// Sets the running call's host tools for `mode`.
    func prepareVoiceHostTools(for mode: LiveVoiceModeName) async {
        let supervisor = voiceBackgroundJobSupervisor
        Self.voiceToolsGeneration += 1
        let mine = Self.voiceToolsGeneration
        // A reconnect on the same mode keeps its tools while this fetches
        // (each read still checks consent); another mode's go now.
        if supervisor.hostToolsMode != mode {
            supervisor.hostTools = []
            supervisor.runHostTool = nil
            supervisor.hostToolsMode = nil
        }
        let fetched = await voiceHostTools(for: mode)
        // A cancelled probe (the call isn't starting) publishes nothing.
        guard mine == Self.voiceToolsGeneration, !Task.isCancelled else { return }
        // The host couldn't be asked: the same mode keeps its tools (each
        // read still checks consent); another mode's were cleared above.
        guard let tools = fetched else { return }
        supervisor.hostToolsMode = mode
        supervisor.hostTools = tools
        supervisor.runHostTool = { [weak self] tool, arguments in
            await self?.callVoiceHostTool(tool, arguments: arguments, mode: mode)
                ?? ["error": "That isn't available on this call."]
        }
    }
}
