//
//  AppState+KeptAnswers.swift
//  Conduit
//
//  The answers kept so a screen opens on its last read (KeptRoute), and
//  the writes that update them. Moved out of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Answers kept for screens to open on

    /// The reads whose answers the settings pages keep (#1533): dashboard
    /// routes, and gateway calls kept beside them. Usage's periods
    /// (UsageReport.route), Pulse's routes (PulseClient.keptRoute), Voice
    /// settings' (HermesVoiceConfigurationService.KeptRead) and the
    /// Capabilities tabs' (CapabilitiesStore.KeptRoute) are kept under
    /// their own.
    enum KeptRoute {
        static let config = "/api/config"
        static let configSchema = "/api/config/schema"
        static let modelOptions = "/api/model/options?explicit_only=true"
        static let modelInfo = "/api/model/info"
        /// Hermes' auxiliary model slots, for Voice settings' voice reply model.
        static let modelAuxiliary = "/api/model/auxiliary"
        static let pluginsHub = "/api/dashboard/plugins/hub"
        /// Capabilities' installed skills and toolsets.
        static let skills = "/api/skills"
        static let toolsets = "/api/tools/toolsets"
        static let delegationStatus = "rpc:delegation.status"
        /// Settings > Usage's quota: the gateway's `model.options`, whose
        /// models the Voice and Pulse model pickers list too.
        static let providerQuotas = "rpc:model.options"
        /// A live voice mode's status line on Voice settings, by the mode's
        /// name: not a read's answer but what its check said.
        static let liveVoiceStatus = "conduit:live-voice-status/"
        /// The Bots list's bots and Desktop's groups, as Conduit read them
        /// (`KeptBotRoster`): `profiles.list` lists the whole Hermes, so
        /// it's kept once per dashboard.
        static let botRoster = "rpc:profiles.list"
        /// The Bots list's hosted rooms and their pictures
        /// (`KeptGroupRooms`), once per dashboard too.
        static let groupRooms = "rpc:groups.list"
        /// The bot editor's details of a profile (`BotProfileDetails`: its
        /// description, SOUL, model, skills, tools and MCP servers, as
        /// `profiles.describe` gave them), kept in that profile's answers:
        /// Edit Bot's bot, or New Bot's Start From profile.
        static let botDetails = "rpc:profiles.describe"
        /// Edit Bot's MCP catalog and its servers' sign-in states
        /// (`BotMcpSetupSnapshot`, with `mcp.servers.list`), in the bot's.
        static let botMcpSetup = "rpc:mcp.catalog"
        /// The scope of an answer about all of a Hermes' profiles at once
        /// (delegation's pause), kept once per dashboard: no profile is
        /// named with nothing.
        static let everyProfile = ""
    }

    /// A read whose answer is kept for the screen that shows it, so that
    /// screen opens on it next time (#1533): per dashboard, profile and
    /// route, in the saved chats' store, which wipes it with them.
    func readKeepingAnswer(_ route: String, profile: String, owner: DashboardRuntimeOwner) async throws -> [String: Any] {
        try await keepingAnswer(profile: profile, owner: owner, keptAs: { _ in route }) {
            try await owner.bridge.requestJSON(path: dashboardPath(route, profile: profile))
        }
    }

    /// The toolsets, read and kept as `readKeepingAnswer` does unless
    /// Hermes lists none: a Hermes still loading its plugins answers an
    /// empty list, which the chat's tool catalog refuses too
    /// (adoptToolCatalog), and the Tools tab would open on nothing.
    func readKeepingToolsets(profile: String, owner: DashboardRuntimeOwner) async throws -> [String: Any] {
        try await keepingAnswer(
            profile: profile,
            owner: owner,
            keptAs: { ($0["_array"] as? [Any])?.isEmpty == false ? KeptRoute.toolsets : nil }
        ) {
            try await owner.bridge.requestJSON(path: dashboardPath(KeptRoute.toolsets, profile: profile))
        }
    }

    /// Runs `read` and keeps its answer as `readKeepingAnswer` does, under
    /// the route `keptAs` names for it (nil: not kept): for an answer read
    /// another way (a gateway call), or a step that answers with a screen's
    /// state (Pulse's), which is then what the screen opens on next.
    /// `writes` for a step that changes what it answers with (a save, a
    /// forget): it's as new as when it lands, so the answer to a read asked
    /// while it was out never goes back over it, and it's kept for the
    /// dashboard it was made on, another one open by then or not.
    func keepingAnswer(
        profile: String,
        owner: DashboardRuntimeOwner,
        keptAs route: ([String: Any]) -> String?,
        writes: Bool = false,
        turnOnly: () -> Bool = { false },
        _ read: () async throws -> [String: Any]
    ) async throws -> [String: Any] {
        let removals = offlineChatCache.removals
        let asked = nextKeptAnswerTurn()
        let answer = try await read()
        let turn = writes ? nextKeptAnswerTurn() : asked
        if let route = route(answer) {
            keepAnswer(answer, for: route, profile: profile, owner: owner, removals: removals, turn: turn, writes: writes,
                       turnOnly: turnOnly())
        }
        return answer
    }

    /// Runs `read` and keeps what it decoded, as Conduit's own JSON, the
    /// way `keepingAnswer` keeps an answer: for a list Conduit reads through
    /// its decoders (the Bots list's), whose answer can't be kept as Hermes
    /// gave it. Without an owner it only reads.
    func keepingRead<Kept: Encodable>(
        as route: String,
        profile: String,
        owner: DashboardRuntimeOwner?,
        keeps: (Kept) -> Bool = { _ in true },
        unchanged: (Kept) -> Bool = { _ in false },
        _ read: () async throws -> Kept
    ) async throws -> Kept {
        guard let owner else { return try await read() }
        var kept: Kept?
        var same = false
        _ = try await keepingAnswer(profile: profile, owner: owner, keptAs: { $0.isEmpty ? nil : route },
                                    turnOnly: { same }) {
            let value = try await read()
            kept = value
            // A read only partly Hermes' answer (`keeps` says) keeps nothing.
            guard keeps(value) else { return [:] }
            // The same as what's kept: nothing is encoded or written, but
            // its turn still counts, so an older read landing after it
            // can't put an earlier answer back (issue 2152).
            if unchanged(value) {
                same = true
                return ["unchanged": true]
            }
            return Self.keptJSON(value) ?? [:]
        }
        guard let kept else { throw CancellationError() }
        return kept
    }

    /// What `keepingRead` kept for the route on the open dashboard, or nil.
    func keptRead<Kept: Decodable>(_ type: Kept.Type, _ route: String, profile: String) -> Kept? {
        keptAnswer(route, profile: profile).flatMap { Self.decodeKept(type, from: $0) }
    }

    /// Changes what `keepingRead` kept for the route on the owner's
    /// dashboard, the one open or not, as Hermes took a write there, and
    /// keeps it over the answer to any read asked before it (#1533). With
    /// nothing kept to change, the write counts all the same.
    func keepWrittenChange<Kept: Codable>(
        _ type: Kept.Type,
        _ route: String,
        profile: String,
        on owner: DashboardRuntimeOwner?,
        _ change: (inout Kept) -> Void
    ) {
        guard let owner else { return }
        guard var kept = keptAnswer(route, profile: profile, on: owner).flatMap({ Self.decodeKept(type, from: $0) }) else {
            noteKeptAnswerWrite(for: route, profile: profile, owner: owner)
            return
        }
        change(&kept)
        guard let answer = Self.keptJSON(kept) else { return }
        keepWrittenAnswer(answer, for: route, profile: profile, owner: owner, removals: offlineChatCache.removals)
    }

    private static func keptJSON<Kept: Encodable>(_ value: Kept) -> [String: Any]? {
        (try? JSONEncoder().encode(value)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static func decodeKept<Kept: Decodable>(_ type: Kept.Type, from answer: [String: Any]) -> Kept? {
        guard let data = try? JSONSerialization.data(withJSONObject: answer) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// The number the answer kept for the route on the open dashboard
    /// was kept under, so a screen decodes it once per answer.
    func keptAnswerTurn(_ route: String, profile: String) -> Int {
        guard let dashboardID = activeDashboardID else { return 0 }
        return keptAnswerTurnsKept[Self.keptAnswerScope(dashboardID, profile, route)] ?? 0
    }

    /// Keeps what the phone just wrote, over the answer to any read asked
    /// before it, for the dashboard it wrote to.
    func keepWrittenAnswer(
        _ answer: [String: Any],
        for route: String,
        profile: String,
        owner: DashboardRuntimeOwner,
        removals: Int
    ) {
        keepAnswer(answer, for: route, profile: profile, owner: owner, removals: removals, turn: nextKeptAnswerTurn(), writes: true)
    }

    func nextKeptAnswerTurn() -> Int {
        keptAnswerTurns += 1
        return keptAnswerTurns
    }

    /// A write that leaves nothing to keep counts all the same: the answer
    /// to a read asked before it isn't kept after it.
    func noteKeptAnswerWrite(for route: String, profile: String, owner: DashboardRuntimeOwner) {
        guard let dashboardID = owner.dashboardID else { return }
        keptAnswerTurnsKept[Self.keptAnswerScope(dashboardID, profile, route)] = nextKeptAnswerTurn()
    }

    private static func keptAnswerScope(_ dashboardID: UUID, _ profile: String, _ route: String) -> String {
        [dashboardID.uuidString, profile, route].joined(separator: "\u{1F}")
    }

    /// Kept with nothing newer kept since, and nothing wiped since it was
    /// asked (a sign-out, Delete Saved Chats, a deleted bot): a read's
    /// answer only while its dashboard is still the one open, and a
    /// write's for the dashboard it was made on, as that's what its Hermes
    /// holds now. A write counts from when it landed, kept or not.
    func keepAnswer(
        _ answer: [String: Any],
        for route: String,
        profile: String,
        owner: DashboardRuntimeOwner,
        removals: Int,
        turn: Int,
        writes: Bool,
        turnOnly: Bool = false
    ) {
        guard let dashboardID = owner.dashboardID else { return }
        let scope = Self.keptAnswerScope(dashboardID, profile, route)
        guard turn > keptAnswerTurnsKept[scope, default: 0] else { return }
        let keeps = offlineChatCache.removals == removals && (writes || ownsDashboardRuntime(owner))
        guard keeps || writes else { return }
        keptAnswerTurnsKept[scope] = turn
        // The same as what's kept (keepingRead's `unchanged`): the turn alone.
        guard keeps, !turnOnly else { return }
        // A schema's fields are keyed by config path, not by what they hold.
        let names: Set<String> = route == KeptRoute.configSchema ? ["fields"] : []
        let answer = route == KeptRoute.modelAuxiliary ? HelperModelSlot.keptAnswer(answer) : answer
        offlineChatCache.recordAnswer(answer, route: route, dashboardID: dashboardID, profile: profile, namesUnder: names)
    }

    /// The answer the active profile's screen last read for the route (or
    /// the given scope's, as `KeptRoute.everyProfile`), or nil when none is
    /// kept.
    func keptAnswer(_ route: String, profile: String? = nil) -> [String: Any]? {
        guard let dashboardID = activeDashboardID else { return nil }
        return offlineChatCache.keptAnswer(route, dashboardID: dashboardID, profile: profile ?? activeProfile)
    }

    /// The answer kept for the route on the owner's dashboard, the one open
    /// or not: what a write that lands there changes.
    func keptAnswer(_ route: String, profile: String, on owner: DashboardRuntimeOwner) -> [String: Any]? {
        owner.dashboardID.flatMap { offlineChatCache.keptAnswer(route, dashboardID: $0, profile: profile) }
    }

    /// Where Voice settings keep their answers for the profile, beside the
    /// other settings pages': on this dashboard, which they read only while
    /// it's the one open. Nil without a bridge.
    func voiceSettingsAnswers(profile: String) -> KeptAnswers? {
        guard let owner = currentDashboardRuntimeOwner() else { return nil }
        return KeptAnswers(
            kept: { [weak self] route in
                guard let self, self.ownsDashboardRuntime(owner) else { return nil }
                return self.keptAnswer(route, profile: profile)
            },
            keep: { [weak self] route, writes, read in
                guard let self else { return try await read() }
                return try await self.keepingAnswer(profile: profile, owner: owner, keptAs: { _ in route }, writes: writes, read)
            }
        )
    }

    /// Where a screen that reads through its own service (Capabilities'
    /// tabs, the Tasks board) keeps its answers for the profile (or the
    /// dashboard's own, as `KeptRoute.everyProfile`), beside the settings
    /// pages': on the dashboard open when they're asked for, offline too,
    /// whose kept answers a change that lands after a switch still changes.
    /// A read keeps its answer only with a bridge to read through.
    func screenAnswers(profile: String) -> KeptAnswers {
        let dashboardID = activeDashboardID
        let owner = currentDashboardRuntimeOwner()
        return KeptAnswers(
            kept: { [weak self] route in
                guard let self, let dashboardID else { return nil }
                return self.offlineChatCache.keptAnswer(route, dashboardID: dashboardID, profile: profile)
            },
            keep: { [weak self] route, writes, read in
                guard let self, let owner else { return try await read() }
                return try await self.keepingAnswer(profile: profile, owner: owner, keptAs: { _ in route }, writes: writes, read)
            },
            noteWrite: { [weak self] route in
                guard let self, let owner else { return }
                self.noteKeptAnswerWrite(for: route, profile: profile, owner: owner)
            }
        )
    }
}
