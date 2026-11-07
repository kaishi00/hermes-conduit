//
//  RoomSetup.swift
//  Conduit
//
//  Host setup on Settings > People (designs/cross-owner-agents, C2): what
//  this Hermes needs before rooms with other people's agents can reach a
//  profile's agent, and the one switch that does it. The notifier plugin
//  (room_setup.py) turns on Hermes' API server, which rooms reach agents
//  through, saves the tools rooms may use (the profile's room ceiling),
//  keeps approvals on, and restarts the gateway when that starts the API
//  server. The API server's key never leaves the host.
//

import Foundation

struct RoomSetupState: Equatable {
    /// What the plugin can't fix, with what to change: YOLO mode, a
    /// managed install, a profile the host gateway doesn't serve, no free
    /// port.
    struct Blocker: Equatable {
        let code: String
        let message: String
    }

    struct APIServer: Equatable {
        /// The gateway starts it: a usable key, and not turned off.
        let enabled: Bool
        let keySet: Bool
        /// The profile has a key of its own for it (the default profile
        /// uses the API server's).
        let profileKeySet: Bool
        /// Where it runs, or will once set up.
        let address: String
        let running: Bool
        /// Why it isn't running while the gateway is, such as its port
        /// being taken.
        let error: String?
    }

    /// A toolset the room ceiling can name, as Hermes labels it.
    struct Choice: Equatable, Identifiable {
        let id: String
        let label: String
        let description: String
    }

    /// Nothing needs doing and nothing blocks it.
    let ready: Bool
    /// What a setup would do, in its order: `api_server`, `ceiling`,
    /// `plugin_tools`, `approvals`, `restart`.
    let needs: [String]
    /// What it would change: `api_server_key`, `profile_key`,
    /// `api_server_port`, `api_server_enabled`, `ceiling`, `plugin_tools`,
    /// `approvals`.
    let changes: [String]
    let blockers: [Blocker]
    let profile: String
    let apiServer: APIServer
    /// The toolsets rooms may use: the ones the setup saved, else what the
    /// room choices can turn on. Toolsets only: the plugin reports the MCP
    /// servers the saved list names apart, in `mcpServers`, and keeps them
    /// when a setup posts a ceiling without `mcp_servers`.
    let ceiling: [String]
    let choices: [Choice]
    /// The profile's MCP servers the ceiling names (notifier #500, plugin
    /// 0.125+): none unless the owner picks some. Their tools still run only
    /// where a room's Custom choice names them.
    let mcpServers: [String]
    /// The profile's enabled MCP servers the ceiling can name, or nil from a
    /// plugin that can't name any.
    let mcpChoices: [String]?
    /// The profile's approval mode (`manual`, `smart`, `off`).
    let approvals: String?

    /// Each toolset's label, or its id when Hermes gave none.
    func label(of toolset: String) -> String {
        choices.first { $0.id == toolset }?.label ?? toolset
    }

    /// The ceiling a setup posts for the tools picked: the ones the plugin
    /// lists, in its order, or nil to keep this one, which can name a
    /// toolset Hermes no longer has (a POST naming it is refused).
    func ceilingToSave(picking picked: Set<String>) -> [String]? {
        guard picked != Set(ceiling) else { return nil }
        return choices.map(\.id).filter(picked.contains)
    }

    /// Whether setting up with the tools picked changes a ceiling the setup
    /// saved before. Each room pins its members' tools when it starts
    /// (designs/cross-owner-agents, decision 13), so the agent then stops
    /// answering in rooms already started.
    func changesSavedCeiling(picking picked: Set<String>, servers: Set<String>? = nil) -> Bool {
        (picked != Set(ceiling) || changesServers(servers)) && !changes.contains("ceiling")
    }

    /// The MCP servers a setup posts for the ones picked, or nil to keep the
    /// saved ones (and on a plugin that can't name any). A saved one Hermes
    /// turned off has no switch and stays chosen (and off): it goes along.
    func mcpServersToSave(picking servers: Set<String>?) -> [String]? {
        guard let choices = mcpChoices, changesServers(servers), let servers else { return nil }
        return choices.filter(servers.contains) + mcpServersTurnedOff
    }

    /// The saved MCP servers Hermes has turned off since: chosen, but none of
    /// their tools run.
    var mcpServersTurnedOff: [String] {
        guard let choices = mcpChoices else { return [] }
        return mcpServers.filter { !choices.contains($0) }
    }

    private var mcpServersOn: [String] {
        guard let choices = mcpChoices else { return [] }
        return mcpServers.filter(choices.contains)
    }

    private func changesServers(_ servers: Set<String>?) -> Bool {
        guard mcpChoices != nil, let servers else { return false }
        return servers.subtracting(mcpServersTurnedOff) != Set(mcpServersOn)
    }

    /// The chosen MCP servers Hermes has on, which Ready names.
    var mcpServersInUse: [String] { mcpServersOn }
}

struct RoomSetupResult: Equatable {
    /// Hermes' gateway restart after the save: `busy` while chats run on
    /// it, with Hermes' words in `error`.
    struct Restart: Equatable {
        let started: Bool
        let busy: Bool
        let error: String?
    }

    let state: RoomSetupState
    /// What the setup changed, by the same names as `changes`.
    let changed: [String]
    /// Nil when the API server needed no restart.
    let restart: Restart?
}

/// The plugin's `GET`/`POST /rooms/setup`, for one profile.
struct RoomSetupClient {
    static let capability = "room-setup"
    static let path = "/api/plugins/conduit_push/rooms/setup"

    typealias Request = @MainActor (_ path: String, _ method: String, _ body: [String: Any]?) async throws -> [String: Any]

    /// The dashboard the requests go to (nil in tests).
    var dashboardID: UUID?
    /// What names the profile: `profile`, or `conduit_profile` on a plugin
    /// that takes it here (`room-dashboard-profiles`), where a profile the
    /// dashboard didn't start with is set up, gateway restart and all.
    var profileParameter: String
    let request: Request

    init(dashboardID: UUID? = nil, profileParameter: String = "profile", request: @escaping Request) {
        self.dashboardID = dashboardID
        self.profileParameter = profileParameter
        self.request = request
    }

    func state(profile: String) async throws -> RoomSetupState {
        try Self.parseState(try await request(scopedPath(profile), "GET", nil))
    }

    /// Sets the profile up with `ceiling` and `mcpServers`, or the ones it
    /// has when nil; `interrupt` restarts the gateway even while chats run
    /// on it.
    func setUp(profile: String, ceiling: [String]?, mcpServers: [String]? = nil,
               interrupt: Bool = false) async throws -> RoomSetupResult {
        let path = scopedPath(profile)
        var body: [String: Any] = ["interrupt": interrupt]
        if let ceiling { body["ceiling"] = ceiling }
        if let mcpServers { body["mcp_servers"] = mcpServers }
        let response = try await request(path, "POST", body)
        let state = try Self.parseState(response)
        var restart: RoomSetupResult.Restart?
        if let object = response["restart"] as? [String: Any] {
            restart = RoomSetupResult.Restart(
                started: object["started"] as? Bool ?? false,
                busy: object["busy"] as? Bool ?? false,
                error: Self.text(object["error"])
            )
        }
        return RoomSetupResult(state: state, changed: response["changed"] as? [String] ?? [], restart: restart)
    }

    static func parseState(_ response: [String: Any]) throws -> RoomSetupState {
        guard response["ok"] as? Bool == true,
              let ready = response["ready"] as? Bool,
              let needs = response["needs"] as? [String],
              let server = response["api_server"] as? [String: Any],
              let address = server["address"] as? String,
              let ceiling = response["ceiling"] as? [String] else { throw HermesError.invalidResponse }
        let blockers = (response["blockers"] as? [[String: Any]] ?? []).compactMap { object -> RoomSetupState.Blocker? in
            guard let message = object["message"] as? String else { return nil }
            return RoomSetupState.Blocker(code: object["code"] as? String ?? "", message: message)
        }
        let choices = (response["choices"] as? [[String: Any]] ?? []).compactMap { object -> RoomSetupState.Choice? in
            guard let id = object["id"] as? String, !id.isEmpty else { return nil }
            return RoomSetupState.Choice(
                id: id,
                label: object["label"] as? String ?? id,
                description: object["description"] as? String ?? ""
            )
        }
        return RoomSetupState(
            ready: ready,
            needs: needs,
            changes: response["changes"] as? [String] ?? [],
            blockers: blockers,
            profile: response["profile"] as? String ?? "",
            apiServer: RoomSetupState.APIServer(
                enabled: server["enabled"] as? Bool ?? false,
                keySet: server["key_set"] as? Bool ?? false,
                profileKeySet: server["profile_key_set"] as? Bool ?? false,
                address: address,
                running: server["running"] as? Bool ?? false,
                error: text(server["error"])
            ),
            ceiling: ceiling,
            choices: choices,
            mcpServers: (response["mcp_servers"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty },
            mcpChoices: (response["mcp_choices"] as? [Any]).map { rows in
                rows.compactMap { ($0 as? [String: Any])?["id"] as? String }.filter { !$0.isEmpty }
            },
            approvals: response["approvals"] as? String
        )
    }

    private func scopedPath(_ profile: String) -> String {
        DashboardPath.withProfile(Self.path, profile: profile, parameter: profileParameter)
    }

    /// A non-empty string, or nil.
    private static func text(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

extension AppState {
    /// Whether the host's plugin can set this Hermes up for rooms. Not in
    /// `usedCapabilities`, as with Links.
    var canSetUpRooms: Bool {
        notifierPlugin.reports(RoomSetupClient.capability)
    }

    /// Requests stay with the dashboard they were made for.
    var roomSetupClient: RoomSetupClient {
        let dashboard = activeDashboardID
        let parameter = notifierPlugin.roomDashboardProfileParameter
        return RoomSetupClient(dashboardID: dashboard, profileParameter: parameter) { [weak self] path, method, body in
            guard let self, self.activeDashboardID == dashboard,
                  let bridge = self.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
            return try await bridge.requestJSON(path: path, method: method, body: body)
        }
    }
}
