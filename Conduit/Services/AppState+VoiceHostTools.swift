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

import Combine
import Foundation
import OSLog

extension AppState {
    static let voiceToolsCapability = "voice-tools"
    static let voiceToolsPath = "/api/plugins/conduit_push/voice-tools"
    static let voiceToolsLog = Logger(subsystem: "com.milim.relay", category: "voice-tools")

    /// The kinds of sealed host data (`VoiceHostTool.key`) a call on `mode`
    /// may read now: each one the user lets `mode` read, shared with the
    /// dashboard and profile in use (`profile`: a Watch call's own, #1564;
    /// nil is the active one).
    func voiceReadableKeys(for mode: LiveVoiceModeName, profile: String? = nil) -> Set<String> {
        let profile = profile ?? activeProfile
        var keys: Set<String> = []
        let health = healthSyncPreferences
        if health.letsVoiceRead(mode), health.destination.map({ isCallDestination($0, profile: profile) }) == true {
            keys.insert("health")
        }
        let location = LocationSharingController.shared
        // An older plugin has no location tool: no key is set up for it.
        if notifierPlugin.servesLocationVoice, location.letsVoiceRead(mode), let binding = location.binding,
           activeDashboardID == binding.dashboardID, profile == binding.profile {
            keys.insert("location")
        }
        return keys
    }

    /// What a call on `mode` may use: the host's tools (health, location,
    /// the calendar and phone status) each when the user lets `mode` read it
    /// and its dashboard and profile are the ones in use, and the phone's own
    /// calendar tools. Starts a sync of each, so the call reads fresh data.
    /// `host` is nil when the host couldn't be asked (a reconnect then keeps
    /// what it had).
    func voiceHostTools(for mode: LiveVoiceModeName, profile: String? = nil) async -> (host: [VoiceHostTool]?, local: [VoiceHostTool]) {
        let profile = profile ?? activeProfile
        let keys = voiceReadableKeys(for: mode, profile: profile)
        let phone = phoneSync.preferences
        let phoneAllowed = phone.letsVoiceUse(mode) && phone.destination.map({ isCallDestination($0, profile: profile) }) == true
        let phoneTools = phoneAllowed
            ? PhoneVoiceTools.tools(for: phone, access: phoneSync.calendarSource.eventAccess,
                                    remindersAuthorized: phoneSync.calendarSource.remindersAuthorized,
                                    alarmsAuthorized: phoneSync.alarmSource.authorized)
            : []
        // Maps run on this iPhone's MapKit for every live mode; "me" and
        // saved places check the mode's location consent at each call.
        // Confirmations Hermes put on screen, answered out loud.
        let local = phoneTools + [MapsVoiceTool.tool] + presentVoiceTools
        guard !keys.isEmpty || phoneAllowed else { return ([], local) }
        // The connection or the plugin's report isn't back yet (a gateway
        // restart): can't ask now, which isn't "nothing offered".
        guard notifierPlugin.reports(Self.voiceToolsCapability), let bridge = dashboardTicketBridge else { return (nil, local) }
        // Not waited on: the call starts now and reads what has arrived by
        // the time it asks. A key from before voice reads is replaced here.
        if keys.contains("health"), !healthSync.isSyncing { Task { await runHealthSync(reason: .voiceCall) } }
        if keys.contains("location") { Task { await LocationSharingController.shared.prepareVoiceReads() } }
        if phoneAllowed, !phoneSync.isSyncing { Task { await runPhoneSync(reason: .voiceCall) } }
        // This iPhone's id in each store: a call reads this iPhone alone, so
        // the host offers only what this iPhone shares.
        var devices: [String: String] = [:]
        if keys.contains("health"), healthSync.readStateIfNeeded() { devices["health_device"] = healthSync.state.deviceID }
        if keys.contains("location") { devices["location_device"] = LocationSharingController.shared.config.deviceID }
        if phoneAllowed, phoneSync.readStateIfNeeded() { devices["phone_device"] = phoneSync.state.deviceID }
        do {
            let response = try await bridge.requestJSON(
                path: Self.voiceToolsListPath(profile: profile, devices: devices),
                method: "GET", body: nil, timeoutMilliseconds: 5_000)
            // A store whose id can't be read can't be read by voice either.
            let host = VoiceHostTool.tools(from: response).filter { tool in
                devices["\(tool.key)_device"] != nil && (keys.contains(tool.key) || (tool.key == "phone" && phoneAllowed))
            }
            return (host, local)
        } catch {
            Self.voiceToolsLog.info("Voice tools unavailable: \(LogRedaction.redactingURLs(HealthSyncEngine.describe(error)), privacy: .public)")
            return (nil, local)
        }
    }

    /// GET /voice-tools for `profile`, naming this iPhone's device in each
    /// store it shares from (older plugins ignore the names).
    static func voiceToolsListPath(profile: String, devices: [String: String]) -> String {
        var path = DashboardPath.withProfile(voiceToolsPath, profile: profile)
        for (name, id) in devices.sorted(by: { $0.key < $1.key }) {
            guard !id.isEmpty, let encoded = DashboardPath.encodedQueryComponent(id) else { continue }
            path += "\(path.contains("?") ? "&" : "?")\(name)=\(encoded)"
        }
        return path
    }

    /// The briefing line for a call on `mode` that the user hasn't let use
    /// the calendar and phone they share on this dashboard.
    func phoneVoiceSettingHint(for mode: LiveVoiceModeName, profile: String? = nil) -> String {
        let phone = phoneSync.preferences
        let profile = profile ?? activeProfile
        guard phone.destination.map({ isCallDestination($0, profile: profile) }) == true else { return "" }
        return PhoneVoiceTools.settingHint(for: phone, mode: mode)
    }

    /// Whether data shared to `destination` is a call's on `profile`: the
    /// dashboard in use and that profile.
    private func isCallDestination(_ destination: HealthSyncDestination, profile: String) -> Bool {
        activeDashboardID == destination.dashboardID && profile == destination.profile
    }

    /// One call for the running call. What the model hears back.
    /// `profile`: the call's own (a Watch call's, #1564); nil is the active one.
    func callVoiceHostTool(_ tool: VoiceHostTool, arguments: [String: Any], mode: LiveVoiceModeName?, profile: String? = nil) async -> [String: String] {
        let profile = profile ?? activeProfile
        switch tool.key {
        case "health", "location": return await callSealedReadTool(tool, arguments: arguments, mode: mode, profile: profile)
        case "phone", PhoneVoiceTools.key: return await callPhoneVoiceTool(tool, arguments: arguments, mode: mode, profile: profile)
        case PresentVoiceTool.key:
            guard tool.name == PresentVoiceTool.name else { return ["error": "That isn't available on this call."] }
            return await callPresentVoiceTool(arguments)
        case MapsVoiceTool.key:
            guard let mode, tool.name == MapsVoiceTool.name else { return ["error": "That isn't available on this call."] }
            let location = LocationSharingController.shared
            // Like the sealed location read: "me" and saved places only on a
            // call with the dashboard and profile the location is shared with.
            let sharedHere = location.binding.map { activeDashboardID == $0.dashboardID && profile == $0.profile } ?? false
            return await MapsVoiceTool.run(arguments, mode: mode, controller: location, sharedHere: sharedHere)
        default: return ["error": "That isn't available on this call."]
        }
    }

    private func callPhoneVoiceTool(_ tool: VoiceHostTool, arguments: [String: Any], mode: LiveVoiceModeName?, profile: String) async -> [String: String] {
        // Checked again at each call: the user may have turned it off mid-call.
        let engine = phoneSync
        guard let mode, engine.preferences.letsVoiceUse(mode),
              let destination = engine.preferences.destination, isCallDestination(destination, profile: profile) else {
            return ["error": "The user hasn't let this voice call use their calendar, or it isn't reachable now."]
        }
        if tool.key == PhoneVoiceTools.key {
            let result = await PhoneVoiceTools.run(tool, arguments: arguments, engine: engine, confirmed: { cancelsAlarm, excluding in
                // Their words reach Conduit a moment after the model heard
                // them. Each yes answers one change or deletion.
                let deadline = ContinuousClock.now + .seconds(2)
                // A Watch call's words come with its tool call: read once,
                // so a later turn's yes can't answer this change.
                let onWatch = !(self.isQwenLiveActive || self.isGeminiLiveActive || self.isGrokLiveActive || self.isGPTLiveActive || self.isLocalLiveActive)
                    && self.watchCallUserTurn != nil
                while true {
                    let turn = self.liveCallLastUserTurn()
                    // The turn current when the change arrived answers
                    // something else: wait for a later one.
                    if let id = turn.id, id != excluding, PhoneVoiceTools.usedConfirmation != id,
                       PhoneVoiceTools.confirmsChange(turn.text, cancelsAlarm: cancelsAlarm) {
                        PhoneVoiceTools.usedConfirmation = id
                        return true
                    }
                    guard !onWatch, ContinuousClock.now < deadline else { return false }
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return false }
                }
            }, lastUserTurn: { [weak self] in self?.liveCallLastUserTurn() ?? (nil, "") }) { prompt, approve in
                await engine.answer(prompt, approve: approve)
                // Reported in the background: the call hears the outcome now.
                Task { await self.runPhoneSync(reason: .answered) }
            }
            if result["error"] == nil {
                Self.recordPhoneVoiceUse(tool, arguments: arguments, mode: mode)
                // Hermes' alarm list and calendar catch up with what was
                // just set, added or deleted.
                if [PhoneVoiceTools.alarmTool, PhoneVoiceTools.addTool, PhoneVoiceTools.updateTool,
                    PhoneVoiceTools.removeTool].contains(tool.name) {
                    Task { await self.runPhoneSync(reason: .answered) }
                }
            }
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
            Self.voiceToolsLog.info("Voice read failed: \(LogRedaction.redactingURLs(PhoneSyncEngine.describe(error)), privacy: .public)")
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
        } else if tool.name == PhoneVoiceTools.updateTool {
            action = (arguments["kind"] as? String).map { "change \($0)" } ?? tool.name
        } else if tool.name == PhoneVoiceTools.removeTool {
            action = (arguments["kind"] as? String).map { "delete \($0)" } ?? tool.name
        } else if tool.name == PhoneVoiceTools.alarmTool {
            switch arguments["kind"] as? String {
            case "list": action = "alarms"
            case "cancel": action = "cancel alarm"
            case let kind?: action = "set \(kind)"
            case nil: action = tool.name
            }
        } else if tool.name == PhoneVoiceTools.changesTool {
            action = "changes \(arguments["action"] as? String ?? "")"
        } else {
            action = arguments["action"] as? String ?? tool.name
        }
        HealthVoiceReadLog.record(mode: mode, action: action, key: HealthVoiceReadLog.phoneStorageKey)
    }

    /// One sealed health or location read for the running call.
    private func callSealedReadTool(_ tool: VoiceHostTool, arguments: [String: Any], mode: LiveVoiceModeName?, profile: String) async -> [String: String] {
        // Checked again at each read: the user may have turned it off mid-call.
        guard let mode, voiceReadableKeys(for: mode, profile: profile).contains(tool.key), let bridge = dashboardTicketBridge else {
            return ["error": tool.key == "location"
                ? "The user hasn't let this voice call read their location, or it isn't reachable now."
                : "The user hasn't let this voice call read their health data, or it isn't reachable now."]
        }
        switch tool.key {
        case "health":
            return await callHealthVoiceTool(tool, arguments: arguments, mode: mode, bridge: bridge, profile: profile)
        case "location":
            return await callLocationVoiceTool(tool, arguments: arguments, mode: mode, bridge: bridge, profile: profile)
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

    private func voiceCallPath(profile: String) -> String {
        DashboardPath.withProfile("\(Self.voiceToolsPath)/call", profile: profile)
    }

    private func callHealthVoiceTool(_ tool: VoiceHostTool, arguments: [String: Any], mode: LiveVoiceModeName,
                                     bridge: DashboardTicketBridge, profile: String) async -> [String: String] {
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
            let response = try await bridge.requestJSON(path: voiceCallPath(profile: profile), method: "POST", body: envelope,
                                                        timeoutMilliseconds: 12_000)
            let result = try HealthSyncCrypto.openVoiceAnswer(response, tool: tool.name, key: key,
                                                                deviceID: deviceID, callID: callID)
            HealthVoiceReadLog.record(mode: mode, action: arguments["action"] as? String ?? "")
            return VoiceHostTool.modelResult(result)
        } catch {
            Self.voiceToolsLog.info("Voice read failed: \(LogRedaction.redactingURLs(HealthSyncEngine.describe(error)), privacy: .public)")
            // The detail stays in the log: it can name the host, and the
            // model's company would get it.
            return ["error": "The health data couldn't be read just now."]
        }
    }

    private func callLocationVoiceTool(_ tool: VoiceHostTool, arguments: [String: Any], mode: LiveVoiceModeName,
                                       bridge: DashboardTicketBridge, profile: String) async -> [String: String] {
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
            let response = try await bridge.requestJSON(path: voiceCallPath(profile: profile), method: "POST", body: envelope,
                                                        timeoutMilliseconds: 12_000)
            let result = try LocationCrypto.openVoiceAnswer(response, tool: tool.name, key: key, callID: callID)
            return VoiceHostTool.modelResult(result)
        } catch {
            Self.voiceToolsLog.info("Voice location read failed: \(LogRedaction.redactingURLs(LocationSyncEngine.describe(error)), privacy: .public)")
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
            supervisor.hostToolsWatch = nil
        }
        let fetched = await voiceHostTools(for: mode)
        // A cancelled probe (the call isn't starting) publishes nothing.
        guard mine == Self.voiceToolsGeneration, !Task.isCancelled else { return }
        // The host couldn't be asked: the same mode keeps its host tools
        // (each read still checks consent); another mode's were cleared above.
        let host = fetched.host ?? supervisor.hostTools.filter {
            $0.key != PhoneVoiceTools.key && $0.key != MapsVoiceTool.key && $0.key != PresentVoiceTool.key
        }
        supervisor.hostToolsMode = mode
        supervisor.hostTools = host + fetched.local
        supervisor.runHostTool = { [weak self] tool, arguments in
            await self?.callVoiceHostTool(tool, arguments: arguments, mode: mode)
                ?? ["error": "That isn't available on this call."]
        }
        let phoneWatch = fetched.local.contains { $0.key == PhoneVoiceTools.key } ? watchPhoneChanges(for: mode) : nil
        let presentWatch = fetched.local.contains { $0.key == PresentVoiceTool.key } ? watchPresentedConfirms(for: mode) : nil
        supervisor.hostToolsWatch = phoneWatch == nil && presentWatch == nil ? nil : AnyCancellable {
            phoneWatch?.cancel()
            presentWatch?.cancel()
        }
    }

    /// Tells the running call about each change Hermes asks for while it
    /// runs, so the user can answer it out loud, and notes the turn current
    /// when each was first seen, which approving it has to come after.
    private func watchPhoneChanges(for mode: LiveVoiceModeName) -> AnyCancellable {
        // What was waiting at the last update: a change Hermes withdraws and
        // asks for again is told again.
        var known = Set(phoneSync.prompts.map(\.id))
        PhoneVoiceTools.beginWatch(waiting: known, turn: liveCallLastUserTurn().id)
        return phoneSync.$prompts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prompts in
                guard let self else { return }
                let supervisor = self.voiceBackgroundJobSupervisor
                let fresh = prompts.filter { !known.contains($0.id) }
                known = Set(prompts.map(\.id))
                let turn = self.liveCallLastUserTurn().id
                for prompt in fresh { PhoneVoiceTools.noteArrival(prompt.id, userTurn: turn) }
                guard !fresh.isEmpty, supervisor.hostToolsMode == mode,
                      self.isQwenLiveActive || self.isGeminiLiveActive || self.isGPTLiveActive || self.isGrokLiveActive || self.isLocalLiveActive,
                      self.phoneSync.preferences.letsVoiceUse(mode) else { return }
                for prompt in fresh { supervisor.notePhoneChange(PhoneVoiceTools.note(for: prompt)) }
            }
    }
}
