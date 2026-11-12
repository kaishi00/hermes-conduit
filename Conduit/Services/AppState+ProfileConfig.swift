//
//  AppState+ProfileConfig.swift
//  Conduit
//
//  A profile's settings and config: the startup reads, display
//  preferences, the main and fallback models, config writes, and the busy
//  input mode. Moved out of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - A profile's settings, config and display preferences

    func sendStartupReads(profile: String, includingProfiles: Bool = true) {
        guard let bridge = dashboardTicketBridge,
              bridge.readsWithoutThePageFirst || bridge.usesNativeOAuth else { return }
        let chatList = profileSessionsPath(profile)
        startupReads.send(
            (includingProfiles ? ["/api/profiles"] : []) + [chatList, dashboardPath("/api/config", profile: profile)],
            through: bridge,
            fence: { path in self.startupReadFence(for: bridge, chatList: path == chatList) }
        )
    }

    /// What an early read must still match to be used: no write through the
    /// dashboard, chat list change or display save since it was sent.
    /// The chat list's own read also needs no listing committed since: one
    /// another load committed meanwhile is newer than the early answer.
    func startupReadFence(for bridge: DashboardTicketBridge, chatList: Bool = false) -> StartupReads.Fence {
        StartupReads.Fence(
            writes: bridge.writesSent,
            catalog: sessionCatalogCache.mutationGeneration,
            display: displayPreferencesWriteRevision,
            listings: chatList ? sessionCatalogCache.commits : 0,
            writesOut: bridge.writesOut
        )
    }

    func loadProfileDisplayPreferences() async {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { return }
        let dashboardTicketBridge = owner.bridge
        let revision = displayPreferencesWriteRevision
        let zoneRevision = timeZoneWriteRevision
        displayPreferencesReadsSent &+= 1
        let read = displayPreferencesReadsSent
        do {
            let config = try await startupReads.read(
                dashboardPath("/api/config", profile: profile),
                through: dashboardTicketBridge,
                fence: startupReadFence(for: dashboardTicketBridge)
            )
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return }
            // A read sent after this one that already landed is newer.
            guard read > displayPreferencesReadCommitted else { return }
            displayPreferencesReadCommitted = read
            let display = config["display"] as? [String: Any] ?? [:]
            // A time-zone or display save that landed while this read was
            // out is newer, each for its own setting.
            if zoneRevision == timeZoneWriteRevision {
                profileTimeZoneSetting = (profile, config[ProfileTimeZone.configKey] as? String ?? "")
            }
            guard revision == displayPreferencesWriteRevision else { return }
            let reasoning = ReasoningDisplayMode(display: display)
            displayPreferences = ProfileDisplayPreferences(
                showReasoning: reasoning == .show,
                thinkingOnRequest: reasoning != .off,
                showToolProgress: display["tool_progress"] as? String != "off",
                expandToolsByDefault: display["expand_tools"] as? Bool ?? false,
                showReviews: ProfileDisplayPreferences.showsReviews(display["memory_notifications"])
            )
        } catch {
            // A read cut off by a dashboard switch fails here; it must not
            // reset the next dashboard's preferences for a profile of the
            // same name.
            guard ownsDashboardRuntime(owner), profile == activeProfile,
                  read > displayPreferencesReadCommitted else { return }
            // Unread (offline, say): what this profile last said, not
            // Hermes' defaults, so thinking set to Off stays off.
            displayPreferences = storedDisplayPreferences(dashboardID: activeDashboardID, profile: profile)
                ?? ProfileDisplayPreferences()
            // A zone saved while the read was out is still the one on screen.
            if zoneRevision == timeZoneWriteRevision { profileTimeZoneSetting = nil }
        }
    }

    /// The active profile's `timezone` value, when Conduit has read it.
    var activeProfileTimeZoneSetting: String? {
        guard let setting = profileTimeZoneSetting, profilesMatch(setting.profile, activeProfile) else { return nil }
        return setting.value
    }

    func loadProfileSettings(keys: [String]) async -> [String: ProfileSettingValue] {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else {
            return keptProfileSettings(keys: keys) ?? keptDisplaySettings(keys: keys)
        }
        do {
            let config = try await readKeepingAnswer(KeptRoute.config, profile: profile, owner: owner)
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return [:] }
            return profileSettings(in: config, keys: keys)
        } catch {
            // A read that fails after a dashboard or profile switch belongs to
            // the settings page that was left; the one on screen has no error.
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return [:] }
            errorMessage = AppLocalization.string("Could not load profile settings: \(UserFacingError.message(for: error))")
            return keptProfileSettings(keys: keys) ?? keptDisplaySettings(keys: keys)
        }
    }

    /// The settings as Hermes answers now, or nil when it didn't: for a
    /// control that waits for Hermes rather than show a kept value as its
    /// answer (a provider's key order).
    func readProfileSettings(keys: [String]) async -> [String: ProfileSettingValue]? {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner(),
              let config = try? await readKeepingAnswer(KeptRoute.config, profile: profile, owner: owner),
              ownsDashboardRuntime(owner), profile == activeProfile else { return nil }
        return profileSettings(in: config, keys: keys)
    }

    /// What the settings pages open on before Hermes answers, and keep when
    /// it can't: the config last read, kept on the phone, with the display
    /// settings the chats follow meanwhile over it. Nil when no config is
    /// kept, so a page waits rather than show Hermes' defaults as its own.
    func keptProfileSettings(keys: [String]) -> [String: ProfileSettingValue]? {
        guard let config = keptAnswer(KeptRoute.config) else { return nil }
        return profileSettings(in: config, keys: keys)
            .merging(keptDisplaySettings(keys: keys)) { _, display in display }
    }

    private func profileSettings(in config: [String: Any], keys: [String]) -> [String: ProfileSettingValue] {
        Dictionary(uniqueKeysWithValues: keys.compactMap { key -> (String, ProfileSettingValue)? in
            if key == ReasoningDisplayMode.settingKey {
                // Worked out from two config values (ReasoningDisplayMode).
                let display = config["display"] as? [String: Any] ?? [:]
                return (key, .text(ReasoningDisplayMode(display: display).rawValue))
            }
            return profileSettingValue(in: config, key: key).map { (key, $0) }
        })
    }

    /// Unread, the display rows show what the chats follow meanwhile: the
    /// settings last read, kept on the phone. Self-improvement updates
    /// keeps only whether they show, so it reads Never show or Hermes'
    /// default.
    private func keptDisplaySettings(keys: [String]) -> [String: ProfileSettingValue] {
        let kept = displayPreferences
        var values: [String: ProfileSettingValue] = [
            ReasoningDisplayMode.settingKey: .text(kept.reasoningMode.rawValue),
            "display.tool_progress": .text(kept.showToolProgress ? "all" : "off"),
            "display.expand_tools": .bool(kept.expandToolsByDefault),
        ]
        if !kept.showReviews { values["display.memory_notifications"] = .text("off") }
        return values.filter { keys.contains($0.key) }
    }

    func loadProfileConfigOptions() async -> ProfileConfigOptions {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { return keptProfileConfigOptions() ?? ProfileConfigOptions() }
        do {
            async let configRequest = readKeepingAnswer(KeptRoute.config, profile: profile, owner: owner)
            async let pluginsRequest = readKeepingAnswer(KeptRoute.pluginsHub, profile: profile, owner: owner)
            let (config, plugins) = try await (configRequest, pluginsRequest)
            guard profile == activeProfile else { return ProfileConfigOptions() }
            return Self.profileConfigOptions(config: config, plugins: plugins)
        } catch {
            // Options are supplementary; retain safe built-ins when an older
            // dashboard does not expose its plugin hub.
            return keptProfileConfigOptions() ?? ProfileConfigOptions()
        }
    }

    /// The choices last read, from the answers kept on the phone, or nil
    /// when they aren't kept.
    func keptProfileConfigOptions() -> ProfileConfigOptions? {
        guard let config = keptAnswer(KeptRoute.config), let plugins = keptAnswer(KeptRoute.pluginsHub) else { return nil }
        return Self.profileConfigOptions(config: config, plugins: plugins)
    }

    static func profileConfigOptions(config: [String: Any], plugins: [String: Any]) -> ProfileConfigOptions {
        var result = ProfileConfigOptions()
        if let personalities = ((config["agent"] as? [String: Any])?["personalities"] as? [String: Any])?.keys {
            result.personalities = personalities.sorted()
        }
        let providers = plugins["providers"] as? [String: Any] ?? [:]
        let memoryOptions = providers["memory_options"] as? [[String: Any]] ?? []
        result.memoryProviders = memoryOptions.compactMap { option in
            option["status"] as? String == "ready" ? option["name"] as? String : nil
        }.sorted()
        let contextOptions = providers["context_options"] as? [[String: Any]] ?? []
        result.contextEngines = Array(Set(result.contextEngines + contextOptions.compactMap { $0["name"] as? String })).sorted()
        return result
    }

    func loadProfileModelDefaults() async -> ProfileModelDefaults? {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { return nil }
        do {
            async let optionsRequest = readKeepingAnswer(KeptRoute.modelOptions, profile: profile, owner: owner)
            async let infoRequest = readKeepingAnswer(KeptRoute.modelInfo, profile: profile, owner: owner)
            async let configRequest = readKeepingAnswer(KeptRoute.config, profile: profile, owner: owner)
            let (options, info, config) = try await (optionsRequest, infoRequest, configRequest)
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return nil }
            return Self.profileModelDefaults(options: options, info: info, config: config)
        } catch {
            // Same fence as the success path: a failure from the dashboard or
            // profile switched away from is not the on-screen page's error.
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return nil }
            errorMessage = AppLocalization.string("Could not load model defaults: \(UserFacingError.message(for: error))")
            return nil
        }
    }

    /// The Model page's catalog and defaults as last read, from the answers
    /// kept on the phone, or nil when they aren't all kept.
    func keptProfileModelDefaults() -> ProfileModelDefaults? {
        guard let options = keptAnswer(KeptRoute.modelOptions),
              let info = keptAnswer(KeptRoute.modelInfo),
              let config = keptAnswer(KeptRoute.config) else { return nil }
        return Self.profileModelDefaults(options: options, info: info, config: config)
    }

    static func profileModelDefaults(
        options: [String: Any],
        info: [String: Any],
        config: [String: Any]
    ) -> ProfileModelDefaults {
        let optionsObject = AnyCodable.from(options).objectValue ?? [:]
        let providers = modelProviders(in: options)
        // Profile config is the persisted default. Hermes stores it under
        // `model.default` and `model.provider`, but `/api/config` flattens
        // `model` to the bare model string and drops the provider, so the
        // provider comes from `/api/model/info` (read from the same config)
        // or the options payload's current selection.
        let modelConfig = config["model"] as? [String: Any] ?? [:]
        let model = [modelConfig["default"] as? String, config["model"] as? String, info["model"] as? String, optionsObject["model"]?.stringValue]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first(where: { !$0.isEmpty }) ?? ""
        let provider = [modelConfig["provider"] as? String, info["provider"] as? String, optionsObject["provider"]?.stringValue]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first(where: { !$0.isEmpty }) ?? ""
        let reasoning = profileReasoningEffort(in: config)
        return ProfileModelDefaults(providers: providers, model: model, provider: provider, reasoning: reasoning)
    }

    func setProfileMainModel(provider: String, model: String, reasoning: String) async -> Bool {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { return false }
        let dashboardTicketBridge = owner.bridge
        do {
            // Hermes writes the profile config for it: in turn with every
            // other config save.
            let result = try await ProfileConfigWriteQueue.runThrowing { [self] in
                try await dashboardTicketBridge.requestJSON(
                    path: dashboardPath("/api/model/set", profile: profile),
                    method: "POST",
                    body: ["model": model, "provider": provider, "scope": "main", "profile": profile]
                )
            }
            // Another dashboard took over: stop. A profile switch on this
            // dashboard doesn't stop the save: the model change already
            // reached Hermes, and the captured profile's config must follow
            // it; only what's shown on screen depends on the profile.
            guard ownsDashboardRuntime(owner) else { return false }
            if result["confirm_required"] as? Bool == true {
                if profile == activeProfile {
                    errorMessage = result["confirm_message"] as? String ?? AppLocalization.string("Hermes requires confirmation before using this model.")
                }
                return false
            }
            try await updateProfileConfig(profile: profile) { config in
                var modelConfig = config["model"] as? [String: Any] ?? [:]
                modelConfig["default"] = model
                modelConfig["provider"] = provider
                config["model"] = modelConfig
                // Hermes reads the profile default from `agent.reasoning_effort`
                // (Desktop writes it there too). The PUT deep-merges, so an old
                // top-level `reasoning` stays on disk; loading reads the agent
                // key first, so it no longer wins.
                var agentConfig = config["agent"] as? [String: Any] ?? [:]
                agentConfig["reasoning_effort"] = reasoning
                config["agent"] = agentConfig
                config["reasoning"] = nil
            }
            // The kept config has the new model now; the catalog, which
            // marks the provider in use (a delegate inherits its models),
            // and the model's info follow it, so the Model page opens on
            // the save next time (#1533).
            Task { [weak self] in
                _ = try? await self?.readKeepingAnswer(KeptRoute.modelOptions, profile: profile, owner: owner)
                _ = try? await self?.readKeepingAnswer(KeptRoute.modelInfo, profile: profile, owner: owner)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return false }
            errorMessage = AppLocalization.string("Could not save model defaults: \(UserFacingError.message(for: error))")
            return false
        }
    }

    /// One GET, change and PUT of the whole profile config, run after any
    /// earlier one finishes (ProfileConfigWriteQueue, shared with the
    /// voice settings' own service). Settings pages save independently
    /// (the Model page has three savers), and two overlapping round trips
    /// would let the later PUT put back what the earlier one changed.
    private func updateProfileConfig(
        profile: String,
        _ change: @escaping @MainActor (inout [String: Any]) -> Void
    ) async throws {
        // Sent only to the dashboard it was made on: one queued behind a
        // write that outlives a switch must not reach the next dashboard's
        // profile of the same name.
        let owner = currentDashboardRuntimeOwner()
        try await ProfileConfigWriteQueue.runThrowing { @MainActor [weak self] in
            guard let self, let owner, self.ownsDashboardRuntime(owner) else { throw CancellationError() }
            let bridge = owner.bridge
            let removals = self.offlineChatCache.removals
            var config = try await bridge.requestJSON(path: self.dashboardPath(KeptRoute.config, profile: profile))
            guard self.ownsDashboardRuntime(owner) else { throw CancellationError() }
            change(&config)
            _ = try await bridge.requestJSON(
                path: self.dashboardPath(KeptRoute.config, profile: profile),
                method: "PUT",
                body: ["config": config, "profile": profile]
            )
            // What the settings pages open on next is what was just saved.
            self.keepWrittenAnswer(config, for: KeptRoute.config, profile: profile, owner: owner, removals: removals)
        }
    }

    /// The profile's default reasoning effort. Hermes keeps it at
    /// `agent.reasoning_effort`; Conduit used to save a top-level
    /// `reasoning`, which is read only when the real key is unset. A
    /// hand-written `false`/`off` means no reasoning, as on Desktop.
    nonisolated static func profileReasoningEffort(in config: [String: Any]) -> String {
        let agentValue = (config["agent"] as? [String: Any])?["reasoning_effort"]
        for value in [agentValue, config["reasoning"], config["reasoning_effort"]] {
            if let flag = value as? NSNumber, AnyCodable.isBoolean(flag), !flag.boolValue { return "none" }
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty else { continue }
            return text == "false" || text == "off" || text == "disabled" ? "none" : text
        }
        return "medium"
    }

    /// `GET /api/config/schema` for the active profile. Empty when the
    /// dashboard can't serve it, which settings pages read as "show every
    /// setting".
    func loadProfileConfigSchema() async -> ProfileConfigSchema {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { return keptProfileConfigSchema() ?? ProfileConfigSchema() }
        do {
            let json = try await readKeepingAnswer(KeptRoute.configSchema, profile: profile, owner: owner)
            guard profile == activeProfile else { return ProfileConfigSchema() }
            return ProfileConfigSchema(json: json)
        } catch {
            return keptProfileConfigSchema() ?? ProfileConfigSchema()
        }
    }

    /// The schema last read, kept on the phone, or nil when none is.
    func keptProfileConfigSchema() -> ProfileConfigSchema? {
        keptAnswer(KeptRoute.configSchema).map(ProfileConfigSchema.init(json:))
    }

    /// The profile's `fallback_providers`, or nil when the config couldn't load.
    func loadProfileFallbackModels() async -> [ProfileFallbackModel]? {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { return nil }
        do {
            let config = try await readKeepingAnswer(KeptRoute.config, profile: profile, owner: owner)
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return nil }
            return ProfileFallbackModel.list(from: config["fallback_providers"])
        } catch {
            // A failure from the dashboard or profile switched away from is
            // not the on-screen page's error.
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return nil }
            errorMessage = AppLocalization.string("Could not load profile settings: \(UserFacingError.message(for: error))")
            return nil
        }
    }

    /// The fallbacks last read, from the config kept on the phone, or nil
    /// when none is kept.
    func keptProfileFallbackModels() -> [ProfileFallbackModel]? {
        keptAnswer(KeptRoute.config).map { ProfileFallbackModel.list(from: $0["fallback_providers"]) }
    }

    /// Saves the complete entries in order. `PUT /api/config` deep-merges
    /// objects but replaces lists, so the whole list goes up each time.
    func setProfileFallbackModels(_ entries: [ProfileFallbackModel]) async -> Bool {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { return false }
        let list = entries.filter(\.isComplete).map(\.jsonObject)
        do {
            try await updateProfileConfig(profile: profile) { config in
                config["fallback_providers"] = list
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            // As for the sibling savers: a save that fails after a dashboard
            // or profile switch has nothing to report to the page on screen.
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return false }
            errorMessage = AppLocalization.string("Could not save fallback models: \(UserFacingError.message(for: error))")
            return false
        }
    }

    /// The subagents' own fallbacks (`delegation.fallback_providers`), or
    /// nil when the config couldn't load. Unset (null) means a subagent on
    /// the chat's model takes the chat's fallbacks.
    func loadDelegateFallbackModels() async -> ProfileFallbackChain? {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { return nil }
        do {
            let config = try await readKeepingAnswer(KeptRoute.config, profile: profile, owner: owner)
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return nil }
            return ProfileFallbackChain(delegationIn: config)
        } catch {
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return nil }
            errorMessage = AppLocalization.string("Could not load profile settings: \(UserFacingError.message(for: error))")
            return nil
        }
    }

    func keptDelegateFallbackModels() -> ProfileFallbackChain? {
        keptAnswer(KeptRoute.config).map(ProfileFallbackChain.init(delegationIn:))
    }

    /// Saves the subagents' fallbacks: null for the chat's, else the
    /// complete entries in order (none listed turns fallback off).
    func setDelegateFallbackModels(_ chain: ProfileFallbackChain) async -> Bool {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { return false }
        let value: Any = chain.inherits ? NSNull() : chain.entries.filter(\.isComplete).map(\.jsonObject)
        do {
            try await updateProfileConfig(profile: profile) { config in
                var delegation = config["delegation"] as? [String: Any] ?? [:]
                delegation["fallback_providers"] = value
                config["delegation"] = delegation
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return false }
            errorMessage = AppLocalization.string("Could not save fallback models: \(UserFacingError.message(for: error))")
            return false
        }
    }

    func setProfileSetting(_ key: String, value: ProfileSettingValue) async -> Bool {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { return false }
        let dashboardTicketBridge = owner.bridge
        do {
            if profile == "default" && (key == "context.engine" || key == "memory.provider") {
                let raw = value.textValue ?? ""
                let body = key == "context.engine" ? ["context_engine": raw] : ["memory_provider": raw]
                let removals = offlineChatCache.removals
                // Hermes writes the profile config for it: in turn with
                // every other config save.
                try await ProfileConfigWriteQueue.runThrowing {
                    _ = try await dashboardTicketBridge.requestJSON(path: "/api/dashboard/plugin-providers", method: "PUT", body: body)
                }
                // The page opens on it next time, as on a config it saved,
                // a switch to another profile or dashboard meanwhile included.
                if var config = keptAnswer(KeptRoute.config, profile: profile, on: owner) {
                    setProfileSettingValue(value, in: &config, key: key)
                    keepWrittenAnswer(config, for: KeptRoute.config, profile: profile, owner: owner, removals: removals)
                } else {
                    noteKeptAnswerWrite(for: KeptRoute.config, profile: profile, owner: owner)
                }
                return ownsDashboardRuntime(owner) && profile == activeProfile
            }
            let reasoning = key == ReasoningDisplayMode.settingKey ? value.textValue.flatMap(ReasoningDisplayMode.init(rawValue:)) : nil
            if key == ReasoningDisplayMode.settingKey, reasoning == nil { return false }
            try await updateProfileConfig(profile: profile) { [weak self] config in
                if let reasoning {
                    var display = config["display"] as? [String: Any] ?? [:]
                    reasoning.write(into: &display)
                    config["display"] = display
                } else {
                    self?.setProfileSettingValue(value, in: &config, key: key)
                }
            }
            if reasoning != nil || key.hasPrefix("display.") { displayPreferencesWriteRevision &+= 1 }
            // The write landed on its own profile; what's mirrored on screen
            // must still be that dashboard's and profile's.
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return true }
            // Only the zone on screen voids a settings read's zone: one saved
            // for a profile switched away from leaves the new one's read alone.
            if key == ProfileTimeZone.configKey { timeZoneWriteRevision &+= 1 }
            if key == ProfileTimeZone.configKey, let zone = value.textValue {
                profileTimeZoneSetting = (profile, zone)
            }
            if let reasoning {
                // Thinking in the chat on screen follows at once.
                displayPreferences.showReasoning = reasoning == .show
                displayPreferences.thinkingOnRequest = reasoning != .off
            }
            if key == "display.memory_notifications" {
                // Rows already in the chat hide or come back with it.
                displayPreferences.showReviews = ProfileDisplayPreferences.showsReviews(value.textValue)
            }
            if key == "display.tool_progress" {
                // The kept choice follows the save, so the offline copy does too.
                displayPreferences.showToolProgress = value.textValue != "off"
            }
            if key == "display.expand_tools", let expand = value.boolValue {
                displayPreferences.expandToolsByDefault = expand
            }
            if key == "approvals.mode", let mode = value.textValue?.lowercased() {
                // Mirror the saved profile mode immediately and re-resolve the
                // effective indicator state through the same precedence
                // applyRuntime uses, so the floor and the picker lock take
                // effect without waiting for the next session snapshot. The
                // last server-reported session value carries through when
                // known (runtime.yolo may be the floor-forced value, not the
                // session flag); only the floor/override precedence re-runs.
                runtime.approvalsMode = mode
                let requestedSessionID = activeSessionId
                let resolvedCanonicalSessionID = canonicalSessionID(for: requestedSessionID)
                applyEffectiveYolo(
                    sessionIDsForOverride: [resolvedCanonicalSessionID, requestedSessionID]
                        .compactMap { $0 },
                    snapshotYolo: lastReportedSessionYolo ?? runtime.yolo,
                    snapshotReportedApprovalsMode: nil
                )
            }
            return true
        } catch is CancellationError {
            // A save queued on a dashboard since switched away from: nothing
            // was sent, and the dashboard on screen has nothing to report.
            return false
        } catch {
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return false }
            errorMessage = AppLocalization.string("Could not save \(key): \(UserFacingError.message(for: error))")
            return false
        }
    }

    func profileSettingValue(in config: [String: Any], key: String) -> ProfileSettingValue? {
        let components = key.split(separator: ".").map(String.init)
        var current: Any = config
        for component in components {
            guard let object = current as? [String: Any], let next = object[component] else { return nil }
            current = next
        }
        // JSON numbers and booleans are both NSNumber, and `as? Bool` also
        // accepts a plain 0 or 1, so a count of 1 would read as a switch.
        if let value = current as? NSNumber {
            return AnyCodable.isBoolean(value) ? .bool(value.boolValue) : .number(value.doubleValue)
        }
        if let value = current as? String { return .text(value) }
        // A stray number in a list is shown as text, so saving the list
        // doesn't drop it.
        if let value = current as? [Any] { return .list(value.map { $0 as? String ?? "\($0)" }) }
        return nil
    }

    private func setProfileSettingValue(_ value: ProfileSettingValue, in config: inout [String: Any], key: String) {
        let components = key.split(separator: ".").map(String.init)
        guard let leaf = components.last else { return }
        let rawValue: Any
        switch value {
        case .bool(let value): rawValue = value
        case .text(let value): rawValue = value
        case .number(let value): rawValue = value
        case .list(let value): rawValue = value
        }
        setNestedValue(rawValue, in: &config, path: Array(components.dropLast()), leaf: leaf)
    }

    private func setNestedValue(_ value: Any, in object: inout [String: Any], path: [String], leaf: String) {
        guard let next = path.first else {
            object[leaf] = value
            return
        }
        var child = object[next] as? [String: Any] ?? [:]
        setNestedValue(value, in: &child, path: Array(path.dropFirst()), leaf: leaf)
        object[next] = child
    }

    func setDisplayPreference(_ key: DisplayPreferenceKey, enabled: Bool) async -> Bool {
        let profile = activeProfile
        let previous = displayPreferences
        applyDisplayPreference(key, enabled: enabled)
        guard let owner = currentDashboardRuntimeOwner() else {
            displayPreferences = previous
            return false
        }
        // A read still out (a switch's, in the background) predates this.
        displayPreferencesWriteRevision &+= 1

        do {
            try await updateProfileConfig(profile: profile) { config in
                var display = config["display"] as? [String: Any] ?? [:]
                switch key {
                case .toolProgress: display["tool_progress"] = enabled ? "on" : "off"
                case .expandTools: display["expand_tools"] = enabled
                }
                config["display"] = display
            }
            displayPreferencesWriteRevision &+= 1
            return true
        } catch {
            // After a dashboard switch the preferences on screen are the next
            // dashboard's (even for a profile of the same name): nothing to
            // restore over them and nothing to report.
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return false }
            displayPreferences = previous
            errorMessage = AppLocalization.string("Could not save display preference: \(UserFacingError.message(for: error))")
            return false
        }
    }

    private func applyDisplayPreference(_ key: DisplayPreferenceKey, enabled: Bool) {
        switch key {
        case .toolProgress: displayPreferences.showToolProgress = enabled
        case .expandTools: displayPreferences.expandToolsByDefault = enabled
        }
    }

    func dashboardPath(_ path: String, profile: String) -> String {
        DashboardPath.withProfile(path, profile: profile)
    }

    /// Hermes' value wins and is kept on the phone; a read that fails keeps
    /// the last value this profile had, else Hermes' own default
    /// (interrupt), so Settings never shows a mode Hermes doesn't use.
    func loadBusyInputMode(using client: HermesClient) async {
        let key = busyInputModeCacheKey
        // Shown while Hermes answers, and kept if it can't.
        restoreBusyInputMode()
        let revision = busyInputModeWriteRevision
        do {
            let mode = try await client.busyInputMode()
            // A switch away while this was out reads its own, and a mode
            // picked meanwhile is newer.
            guard self.client === client, revision == busyInputModeWriteRevision else { return }
            busyInputMode = mode
            defaults.set(mode.rawValue, forKey: key)
        } catch {}
    }

    /// Another profile: the busy mode it last had here, until Hermes
    /// answers for it.
    func restoreBusyInputMode() {
        busyInputMode = defaults.string(forKey: busyInputModeCacheKey).flatMap(BusyInputMode.init(rawValue:)) ?? .interrupt
    }

    /// The busy mode last read from or saved to Hermes, per server and profile.
    private var busyInputModeCacheKey: String {
        let server = defaults.string(forKey: Self.chatResumeServerIdentityKey) ?? ""
        return "\(Self.busyInputModeCachePrefix)\(server)|\(activeProfile)"
    }

    static let busyInputModeCachePrefix = "conduit.busyInputMode.v1."

    func setBusyInputMode(_ mode: BusyInputMode) async -> Bool {
        guard let client else { return false }
        let previous = busyInputMode
        // The profile that takes the write, captured before it.
        let key = busyInputModeCacheKey
        busyInputMode = mode
        busyInputModeWriteRevision &+= 1
        do {
            if let setBusyInputMode = chatResumeLifecycleOperations.setBusyInputMode {
                try await setBusyInputMode(client, mode)
            } else {
                try await client.setBusyInputMode(mode)
            }
            defaults.set(mode.rawValue, forKey: key)
            return true
        } catch {
            busyInputMode = previous
            errorMessage = AppLocalization.string("Could not save message behavior: \(UserFacingError.message(for: error))")
            return false
        }
    }
}
