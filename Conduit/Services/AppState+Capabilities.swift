//
//  AppState+Capabilities.swift
//  Conduit
//
//  A profile's skills and toolsets (loading and toggling them) and the
//  tools catalog step rows read. Moved out of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Capabilities

    /// Request-scoped result for a capability load. The caller must be able to
    /// know how THIS request ended without consulting global error/skill
    /// state, which can be stale or mutated by unrelated flows.
    enum CapabilityLoadOutcome {
        case success(profile: String)
        case failed(profile: String, message: String)
        case unavailable(profile: String)
        /// The active dashboard or profile changed mid-request; the result
        /// belongs to an abandoned one and callers should discard it.
        case superseded(requested: CapabilitySnapshotOwner, active: CapabilitySnapshotOwner)

        var isSuperseded: Bool {
            if case .superseded = self { return true }
            return false
        }
    }

    @discardableResult
    func loadCapabilities() async -> CapabilityLoadOutcome {
        capabilityLoadGeneration &+= 1
        let generation = capabilityLoadGeneration
        let profile = activeProfile
        let owner = currentCapabilitiesOwner
        guard let runtime = currentDashboardRuntimeOwner() else { return .unavailable(profile: profile) }
        // Kept for Capabilities to open on next time (#1533).
        async let skillsResult = readKeepingAnswer(KeptRoute.skills, profile: profile, owner: runtime)
        async let toolsetsResult = readKeepingToolsets(profile: profile, owner: runtime)
        // Commit gate: this exact request must still be the newest one AND
        // target the still-active dashboard and profile (A -> B -> A stale
        // commits rejected).
        func ownsRequest() -> Bool {
            CapabilityLoadPolicy.canCommit(
                generation: generation,
                latestGeneration: capabilityLoadGeneration,
                requested: owner,
                active: currentCapabilitiesOwner
            )
        }
        do {
            let (skillsResponse, toolsetsResponse) = try await (skillsResult, toolsetsResult)
            guard ownsRequest() else { return .superseded(requested: owner, active: currentCapabilitiesOwner) }
            self.skills = capabilitySkills(from: skillsResponse)
            self.toolsets = capabilityToolsets(from: toolsetsResponse)
            adoptToolCatalog(ToolCatalog(toolsets: self.toolsets), key: toolCatalogKey)
            capabilitiesOwner = owner
            capabilitiesAreKept = false
            return .success(profile: profile)
        } catch {
            guard ownsRequest() else { return .superseded(requested: owner, active: currentCapabilitiesOwner) }
            errorMessage = AppLocalization.string("Could not load capabilities: \(UserFacingError.message(for: error))")
            return .failed(profile: profile, message: AppLocalization.string("Could not load capabilities: \(UserFacingError.message(for: error))"))
        }
    }

    /// Draws the installed skills and toolsets Hermes gave last time on
    /// this dashboard and profile, kept on the phone (#1533), unless this
    /// profile's are already showing; only once both lists are kept.
    func showKeptCapabilities() {
        guard !capabilitiesAreCurrent,
              let skillsAnswer = keptAnswer(KeptRoute.skills),
              let toolsetsAnswer = keptAnswer(KeptRoute.toolsets) else { return }
        skills = capabilitySkills(from: skillsAnswer)
        toolsets = capabilityToolsets(from: toolsetsAnswer)
        capabilitiesOwner = currentCapabilitiesOwner
        capabilitiesAreKept = true
    }

    func capabilitySkills(from answer: [String: Any]) -> [CapabilitySkill] {
        (answer["_array"] as? [Any] ?? []).compactMap(decodeCapabilitySkill)
            .sorted { lhs, rhs in
                let lhsCat = lhs.category ?? ""
                let rhsCat = rhs.category ?? ""
                if lhsCat != rhsCat { return lhsCat < rhsCat }
                return lhs.name < rhs.name
            }
    }

    private func capabilityToolsets(from answer: [String: Any]) -> [CapabilityToolset] {
        (answer["_array"] as? [Any] ?? []).compactMap(decodeCapabilityToolset)
            .sorted { ($0.label ?? $0.name) < ($1.label ?? $1.name) }
    }

    /// Keeps a switch Hermes took in the list it's kept in, so Capabilities
    /// opens on it next time, the dashboard switched away from included.
    /// A flip drops the read on its way (it was asked before it): rows
    /// still kept ask again, as they'd otherwise stay up.
    private func keepFlip(_ route: String, name: String, enabled: Bool, profile: String, owner: DashboardRuntimeOwner, removals: Int) async {
        if let kept = keptAnswer(route, profile: profile, on: owner), let rows = kept["_array"] as? [Any] {
            let flipped = rows.map { row -> Any in
                guard var row = row as? [String: Any], row["name"] as? String == name else { return row }
                row["enabled"] = enabled
                return row
            }
            keepWrittenAnswer(["_array": flipped], for: route, profile: profile, owner: owner, removals: removals)
        } else {
            noteKeptAnswerWrite(for: route, profile: profile, owner: owner)
        }
        guard capabilitiesAreKept, ownsDashboardRuntime(owner), profile == activeProfile else { return }
        await loadCapabilities()
    }

    /// `rows` is the snapshot the switch was flipped in (a bulk change's
    /// first one); nothing is sent once it is no longer the one showing.
    func toggleSkill(name: String, enabled: Bool, rows: CapabilitySnapshotOwner? = nil) async {
        let profile = activeProfile
        guard capabilityRowsAreCurrent(rows), let owner = currentDashboardRuntimeOwner() else { return }
        let dashboardTicketBridge = owner.bridge
        let removals = offlineChatCache.removals
        let current = skills.first(where: { $0.name == name })?.enabled ?? !enabled
        // Optimistic update. A list read still on its way was read before
        // this flip: it no longer commits (as CapabilitiesStore, #867).
        capabilityLoadGeneration &+= 1
        if let index = skills.firstIndex(where: { $0.name == name }) {
            skills[index].enabled = enabled
        }
        // After every switch flipped before it; a failure puts back what
        // Hermes last confirmed, unless a newer flip is on its way.
        let outcome = await capabilityToggleWrites.send("\(ObjectIdentifier(owner.bridge))|\(profile)|skill|\(name)", enabled: enabled, current: current) {
            // Hermes rewrites the profile config for it: in turn with
            // every other config save.
            try await ProfileConfigWriteQueue.runThrowing {
                _ = try await dashboardTicketBridge.requestJSON(
                    path: "/api/skills/toggle",
                    method: "PUT",
                    body: ["name": name, "enabled": enabled, "profile": profile]
                )
            }
        }
        // Kept only once Hermes took it: a refused flip a newer one
        // replaced says nothing failed, but was never saved.
        if outcome.taken {
            await keepFlip(KeptRoute.skills, name: name, enabled: enabled, profile: profile, owner: owner, removals: removals)
        }
        guard ownsDashboardRuntime(owner), let error = outcome.error, profile == activeProfile else { return }
        if let restore = outcome.restore, let index = skills.firstIndex(where: { $0.name == name }) {
            skills[index].enabled = restore
        }
        errorMessage = AppLocalization.string("Could not update skill: \(UserFacingError.message(for: error))")
        // The flip dropped the read on its way: a list still kept asks again.
        if capabilitiesAreKept { await loadCapabilities() }
    }

    /// `rows` is the snapshot the switch was flipped in (a bulk change's
    /// first one); nothing is sent once it is no longer the one showing.
    func toggleToolset(name: String, enabled: Bool, rows: CapabilitySnapshotOwner? = nil) async {
        let profile = activeProfile
        guard capabilityRowsAreCurrent(rows), let owner = currentDashboardRuntimeOwner() else { return }
        let dashboardTicketBridge = owner.bridge
        let removals = offlineChatCache.removals
        let current = toolsets.first(where: { $0.name == name })?.enabled ?? !enabled
        // Optimistic update. A list read still on its way was read before
        // this flip: it no longer commits (as CapabilitiesStore, #867).
        capabilityLoadGeneration &+= 1
        if let index = toolsets.firstIndex(where: { $0.name == name }) {
            toolsets[index].enabled = enabled
        }
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        // In the same order as skill switches: Hermes rewrites one config.
        let outcome = await capabilityToggleWrites.send("\(ObjectIdentifier(owner.bridge))|\(profile)|toolset|\(name)", enabled: enabled, current: current) {
            // Hermes rewrites the profile config for it: in turn with
            // every other config save.
            try await ProfileConfigWriteQueue.runThrowing {
                _ = try await dashboardTicketBridge.requestJSON(
                    path: "/api/tools/toolsets/\(encodedName)",
                    method: "PUT",
                    body: ["enabled": enabled, "profile": profile]
                )
            }
        }
        // Kept only once Hermes took it: a refused flip a newer one
        // replaced says nothing failed, but was never saved.
        if outcome.taken {
            await keepFlip(KeptRoute.toolsets, name: name, enabled: enabled, profile: profile, owner: owner, removals: removals)
        }
        guard ownsDashboardRuntime(owner), let error = outcome.error, profile == activeProfile else { return }
        if let restore = outcome.restore, let index = toolsets.firstIndex(where: { $0.name == name }) {
            toolsets[index].enabled = restore
        }
        errorMessage = AppLocalization.string("Could not update toolset: \(UserFacingError.message(for: error))")
        // The flip dropped the read on its way: a list still kept asks again.
        if capabilitiesAreKept { await loadCapabilities() }
    }

    /// The dashboard, bridge and profile a capability read made now would
    /// belong to.
    var currentCapabilitiesOwner: CapabilitySnapshotOwner {
        CapabilitySnapshotOwner(
            dashboardID: activeDashboardID,
            bridge: dashboardTicketBridge.map { ObjectIdentifier($0) },
            profile: activeProfile
        )
    }

    /// Whether the installed skills and toolsets are the current dashboard's
    /// and profile's: anything that shows them checks this first.
    var capabilitiesAreCurrent: Bool {
        CapabilityLoadPolicy.shouldPresentRows(snapshot: capabilitiesOwner, active: currentCapabilitiesOwner)
    }

    /// Whether a switch flipped in `rows` (nil: the rows showing) may still
    /// act: they are the rows showing, and those are the current
    /// dashboard's and profile's.
    private func capabilityRowsAreCurrent(_ rows: CapabilitySnapshotOwner?) -> Bool {
        guard let rows = rows ?? capabilitiesOwner else { return false }
        return rows == capabilitiesOwner && rows == currentCapabilitiesOwner
    }

    /// The installed skills and toolsets belong to the dashboard switched
    /// away from: a read still on its way commits nothing, and its rows
    /// never show (or act) under the next one.
    func retireCapabilitySnapshot() {
        capabilityLoadGeneration &+= 1
        capabilitiesOwner = nil
        capabilitiesAreKept = false
        skills = []
        toolsets = []
    }

    private func decodeCapabilitySkill(_ value: Any) -> CapabilitySkill? {
        guard let dict = value as? [String: Any], let name = dict["name"] as? String else { return nil }
        return CapabilitySkill(
            name: name,
            description: dict["description"] as? String,
            category: dict["category"] as? String,
            enabled: dict["enabled"] as? Bool ?? false,
            provenance: dict["provenance"] as? String,
            usage: dict["usage"] as? Int
        )
    }

    // MARK: - Tools catalog for step rows

    /// The active dashboard and profile, for what is kept per profile on
    /// this device (the tools catalog, step summaries).
    var toolCatalogKey: String {
        "\(Self.dashboardPreferenceBucket(activeDashboardID)).\(activeProfile)"
    }

    /// Shows the profile's saved catalog at once, then asks Hermes for the
    /// current one, once per profile while Conduit runs (Capabilities
    /// refreshes it too). A failed read is tried again on the next chat.
    func loadToolCatalogIfNeeded() async {
        let key = toolCatalogKey
        if toolCatalogOwner != key {
            toolCatalogOwner = key
            toolCatalog = ToolCatalog.saved(key: key, defaults: defaults)
        }
        guard !toolCatalogFetched.contains(key), !toolCatalogLoading.contains(key),
              let owner = currentDashboardRuntimeOwner() else { return }
        // Two chats opened in a row ask once.
        toolCatalogLoading.insert(key)
        defer { toolCatalogLoading.remove(key) }
        // The answer Capabilities' Tools tab opens on, kept for it too.
        guard let response = try? await readKeepingToolsets(profile: activeProfile, owner: owner) else { return }
        let toolsets = (response["_array"] as? [Any] ?? []).compactMap(decodeCapabilityToolset)
        adoptToolCatalog(ToolCatalog(toolsets: toolsets), key: key)
    }

    /// An empty catalog (a Hermes still loading its plugins, or one that
    /// answered nothing) neither replaces the saved one nor ends the
    /// retries: the next chat asks again.
    private func adoptToolCatalog(_ catalog: ToolCatalog, key: String) {
        guard !catalog.isEmpty else { return }
        toolCatalogFetched.insert(key)
        if catalog != ToolCatalog.saved(key: key, defaults: defaults) {
            catalog.save(key: key, defaults: defaults)
        }
        guard key == toolCatalogKey else { return }
        toolCatalogOwner = key
        if toolCatalog != catalog { toolCatalog = catalog }
    }

    private func decodeCapabilityToolset(_ value: Any) -> CapabilityToolset? {
        guard let dict = value as? [String: Any], let name = dict["name"] as? String else { return nil }
        let tools = dict["tools"] as? [Any]
        return CapabilityToolset(
            name: name,
            description: dict["description"] as? String,
            enabled: dict["enabled"] as? Bool ?? false,
            configured: dict["configured"] as? Bool,
            label: dict["label"] as? String,
            tools: tools as? [String]
        )
    }
}
