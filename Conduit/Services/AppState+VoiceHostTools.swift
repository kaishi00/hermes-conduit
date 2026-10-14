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

import Combine
import Foundation
import OSLog

extension AppState {
    static let voiceToolsCapability = "voice-tools"
    static let voiceToolsPath = "/api/plugins/conduit_push/voice-tools"
    static let voiceToolsLog = Logger(subsystem: "com.milim.relay", category: "voice-tools")

    /// What a call on `mode` may use: the host's tools (health, the
    /// calendar and phone status) each when the user lets `mode` read it and
    /// its dashboard and profile are the ones in use, and the phone's own
    /// calendar tools. Starts a sync of each, so the call reads fresh data.
    /// `host` is nil when the host couldn't be asked (a reconnect then keeps
    /// what it had).
    func voiceHostTools(for mode: LiveVoiceModeName) async -> (host: [VoiceHostTool]?, local: [VoiceHostTool]) {
        let health = healthSyncPreferences
        let healthAllowed = health.letsVoiceRead(mode) && health.destination.map(isActiveDestination) == true
        let phone = phoneSync.preferences
        let phoneAllowed = phone.letsVoiceUse(mode) && phone.destination.map(isActiveDestination) == true
        let local = phoneAllowed
            ? PhoneVoiceTools.tools(for: phone, access: phoneSync.calendarSource.eventAccess,
                                    remindersAuthorized: phoneSync.calendarSource.remindersAuthorized)
            : []
        guard healthAllowed || phoneAllowed else { return ([], local) }
        // The connection or the plugin's report isn't back yet (a gateway
        // restart): can't ask now, which isn't "nothing offered".
        guard notifierPlugin.reports(Self.voiceToolsCapability), let bridge = dashboardTicketBridge else { return (nil, local) }
        // Not waited on: the call starts now and reads what has arrived by
        // the time it asks. A key from before voice reads is replaced here.
        if healthAllowed, !healthSync.isSyncing { Task { await runHealthSync(reason: .voiceCall) } }
        if phoneAllowed, !phoneSync.isSyncing { Task { await runPhoneSync(reason: .voiceCall) } }
        do {
            let response = try await bridge.requestJSON(
                path: DashboardPath.withProfile(Self.voiceToolsPath, profile: activeProfile),
                method: "GET", body: nil, timeoutMilliseconds: 5_000)
            let host = VoiceHostTool.tools(from: response).filter { tool in
                (tool.key == "health" && healthAllowed) || (tool.key == "phone" && phoneAllowed)
            }
            return (host, local)
        } catch {
            Self.voiceToolsLog.info("Voice tools unavailable: \(HealthSyncEngine.describe(error), privacy: .public)")
            return (nil, local)
        }
    }

    private func isActiveDestination(_ destination: HealthSyncDestination) -> Bool {
        activeDashboardID == destination.dashboardID && activeProfile == destination.profile
    }

    /// One call for the running call. What the model hears back.
    func callVoiceHostTool(_ tool: VoiceHostTool, arguments: [String: Any], mode: LiveVoiceModeName?) async -> [String: String] {
        switch tool.key {
        case "health": return await callHealthVoiceTool(tool, arguments: arguments, mode: mode)
        case "phone", PhoneVoiceTools.key: return await callPhoneVoiceTool(tool, arguments: arguments, mode: mode)
        default: return ["error": "That isn't available on this call."]
        }
    }

    private func callPhoneVoiceTool(_ tool: VoiceHostTool, arguments: [String: Any], mode: LiveVoiceModeName?) async -> [String: String] {
        // Checked again at each call: the user may have turned it off mid-call.
        let engine = phoneSync
        guard let mode, engine.preferences.letsVoiceUse(mode),
              let destination = engine.preferences.destination, isActiveDestination(destination) else {
            return ["error": "The user hasn't let this voice call use their calendar, or it isn't reachable now."]
        }
        if tool.key == PhoneVoiceTools.key {
            let result = await PhoneVoiceTools.run(tool, arguments: arguments, engine: engine) { prompt, approve in
                await engine.answer(prompt, approve: approve)
                // Reported in the background: the call hears the outcome now.
                Task { await self.runPhoneSync(reason: .answered) }
            }
            if result["error"] == nil { Self.recordPhoneVoiceUse(tool, arguments: arguments, mode: mode) }
            return result
        }
        guard let bridge = dashboardTicketBridge else {
            return ["error": "The calendar isn't reachable just now."]
        }
        do {
            let result = try await engine.voiceRead(
                tool: tool.name, arguments: arguments, provider: mode.storageID,
                path: DashboardPath.withProfile("\(Self.voiceToolsPath)/call", profile: destination.profile)
            ) { path, method, body in
                try await bridge.requestJSON(path: path, method: method, body: body, timeoutMilliseconds: 12_000)
            }
            let answer = VoiceHostTool.modelResult(result)
            // Logged only when the answer reaches the call.
            if answer["error"] == nil { Self.recordPhoneVoiceUse(tool, arguments: arguments, mode: mode) }
            return answer
        } catch is PhoneSyncEngine.VoiceNotReady {
            return ["error": "The calendar isn't ready for voice yet; it will be after the next sync."]
        } catch {
            Self.voiceToolsLog.info("Voice read failed: \(PhoneSyncEngine.describe(error), privacy: .public)")
            // The detail stays in the log: it can name the host, and the
            // model's company would get it.
            return ["error": "The calendar couldn't be read just now."]
        }
    }

    /// Logs what a call used of the calendar and phone (Settings > Calendar &
    /// phone): the tool's action ("events", "add reminder"), never the data.
    private static func recordPhoneVoiceUse(_ tool: VoiceHostTool, arguments: [String: Any], mode: LiveVoiceModeName) {
        let action: String
        if tool.name == PhoneVoiceTools.addTool {
            action = (arguments["kind"] as? String).map { "add \($0)" } ?? tool.name
        } else if tool.name == PhoneVoiceTools.changesTool {
            action = "changes \(arguments["action"] as? String ?? "")"
        } else {
            action = arguments["action"] as? String ?? tool.name
        }
        HealthVoiceReadLog.record(mode: mode, action: action, key: HealthVoiceReadLog.phoneStorageKey)
    }

    /// One sealed health read for the running call.
    private func callHealthVoiceTool(_ tool: VoiceHostTool, arguments: [String: Any], mode: LiveVoiceModeName?) async -> [String: String] {
        // Checked again at each read: the user may have turned it off mid-call.
        let preferences = healthSyncPreferences
        guard let mode, preferences.letsVoiceRead(mode),
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
            supervisor.hostToolsWatch = nil
        }
        let fetched = await voiceHostTools(for: mode)
        // A cancelled probe (the call isn't starting) publishes nothing.
        guard mine == Self.voiceToolsGeneration, !Task.isCancelled else { return }
        // The host couldn't be asked: the same mode keeps its host tools
        // (each read still checks consent); another mode's were cleared above.
        let host = fetched.host ?? supervisor.hostTools.filter { $0.key != PhoneVoiceTools.key }
        supervisor.hostToolsMode = mode
        supervisor.hostTools = host + fetched.local
        supervisor.runHostTool = { [weak self] tool, arguments in
            await self?.callVoiceHostTool(tool, arguments: arguments, mode: mode)
                ?? ["error": "That isn't available on this call."]
        }
        supervisor.hostToolsWatch = fetched.local.isEmpty ? nil : watchPhoneChanges(for: mode)
    }

    /// Tells the running call about each change Hermes asks for while it
    /// runs, so the user can answer it out loud.
    private func watchPhoneChanges(for mode: LiveVoiceModeName) -> AnyCancellable {
        // What was waiting at the last update: a change Hermes withdraws and
        // asks for again is told again.
        var known = Set(phoneSync.prompts.map(\.id))
        return phoneSync.$prompts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prompts in
                guard let self else { return }
                let supervisor = self.voiceBackgroundJobSupervisor
                let fresh = prompts.filter { !known.contains($0.id) }
                known = Set(prompts.map(\.id))
                guard !fresh.isEmpty, supervisor.hostToolsMode == mode,
                      self.isGeminiLiveActive || self.isGPTLiveActive || self.isGrokLiveActive,
                      self.phoneSync.preferences.letsVoiceUse(mode) else { return }
                for prompt in fresh { supervisor.notePhoneChange(PhoneVoiceTools.note(for: prompt)) }
            }
    }
}
