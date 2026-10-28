//
//  RoomApprovals.swift
//  Conduit
//
//  Your agents' approvals in rooms other people host (designs/
//  cross-owner-agents, C3d). An agent of yours in a room hosted elsewhere
//  runs its turns on your Hermes, and a tool call that needs your approval
//  waits there: the host only hears that the turn waits. The notifier
//  plugin lists each one (room_approvals.py) and answers it, once or deny,
//  through your Hermes' own API server, since approval.respond can't reach
//  a room's turn. Group Chats lists them first, and the "Approval needed"
//  notification for one opens its card instead of the hidden chat the turn
//  runs in.
//

import Foundation

/// An approval one of your agents' turns in a room hosted elsewhere waits
/// for, as the plugin shows it.
struct RoomApproval: Identifiable, Equatable {
    /// The turn and the approval, which an answer names.
    var id: String { "\(runID)/\(requestID)" }
    let runID: String
    let requestID: String
    let roomID: String?
    /// The room's name, as the invite named it.
    let room: String?
    let link: String?
    /// Who hosts it, by the name the Link shows them.
    let from: String?
    let agentProfile: String?
    /// The agent's handle in the room.
    let agentHandle: String?
    let agentName: String?
    /// The session its "Approval needed" notification names, which a
    /// tapped notification is matched by.
    let sessionKey: String?
    let description: String
    let command: String
    /// `once` and `deny`: a room turn's approval is for that call only.
    let choices: [String]

    /// The room screen's own approval card shows it.
    var card: GroupPendingApproval {
        GroupPendingApproval(roomApproval: self)
    }
}

/// The approvals as Group Chats last read them, for the dashboard they were
/// read from.
struct LinkedRoomApprovals: Equatable {
    let dashboardID: UUID?
    /// The oldest turn's first.
    var approvals: [RoomApproval]
}

/// What Group Chats and the card say about an approval.
enum RoomApprovalText {
    /// The agent and where it waits: "Kuro in Zoo trip, hosted by Furina".
    static func line(for approval: RoomApproval) -> String {
        let agent = [approval.agentName, approval.agentHandle, approval.agentProfile]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? AppLocalization.string("Your agent")
        let room = approval.room?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host = approval.from?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (room.isEmpty, host.isEmpty) {
        case (false, false):
            return AppLocalization.string("\(agent) in \(room), hosted by \(host)")
        case (false, true):
            return AppLocalization.string("\(agent) in \(room)")
        case (true, false):
            return AppLocalization.string("\(agent) in a room hosted by \(host)")
        case (true, true):
            return AppLocalization.string("\(agent) in a room hosted elsewhere")
        }
    }
}

/// The plugin's approvals routes. Like the invites', they take no profile:
/// the approvals are the installation's.
struct RoomApprovalsClient {
    static let capability = "room-approvals"
    static let path = "/api/plugins/conduit_push/rooms/approvals"
    /// The plugin answers within 30 s, its API server's wait.
    static let answerTimeoutMilliseconds = 35_000
    /// A tapped notification's read: past this, its chat opens as before.
    static let notificationReadTimeoutMilliseconds = 5_000
    /// A notification arriving in front: its banner waits on this read,
    /// so it's kept short; past it, the push stays quiet as before.
    static let presentationReadTimeoutMilliseconds = 2_000

    typealias Request = RoomLinksClient.Request

    /// The dashboard the requests go to (nil in tests).
    var dashboardID: UUID?
    let request: Request

    init(dashboardID: UUID? = nil, request: @escaping Request) {
        self.dashboardID = dashboardID
        self.request = request
    }

    func approvals(timeoutMilliseconds: Int? = nil) async throws -> [RoomApproval] {
        try Self.parseList(try await request(Self.path, "GET", nil, timeoutMilliseconds))
    }

    /// Answers `approval` with `choice`, `once` or `deny`.
    func answer(_ approval: RoomApproval, choice: String) async throws {
        let body: [String: Any] = ["run_id": approval.runID, "request_id": approval.requestID, "choice": choice]
        let response = try await request("\(Self.path)/answer", "POST", body, Self.answerTimeoutMilliseconds)
        guard response["ok"] as? Bool == true else { throw HermesError.invalidResponse }
    }

    /// An approval that can't be answered (no run or request id) is left
    /// out rather than refusing the whole list.
    static func parseList(_ response: [String: Any]) throws -> [RoomApproval] {
        guard response["ok"] as? Bool == true,
              let approvals = response["approvals"] as? [[String: Any]] else { throw HermesError.invalidResponse }
        return approvals.compactMap(approval)
    }

    static func approval(_ object: [String: Any]) -> RoomApproval? {
        guard let runID = text(object["run_id"]), let requestID = text(object["request_id"]) else { return nil }
        let agent = object["agent"] as? [String: Any] ?? [:]
        let offered = (object["choices"] as? [Any] ?? []).compactMap { $0 as? String }.filter { $0 == "once" || $0 == "deny" }
        return RoomApproval(
            runID: runID,
            requestID: requestID,
            roomID: text(object["room_id"]),
            room: text(object["room"]),
            link: text(object["link"]),
            from: text(object["from"]),
            agentProfile: text(agent["profile"]),
            agentHandle: text(agent["handle"]),
            agentName: text(agent["display_name"]),
            sessionKey: text(object["session_key"]),
            description: object["description"] as? String ?? "",
            command: object["command"] as? String ?? "",
            choices: offered.isEmpty ? ["once", "deny"] : offered
        )
    }

    /// A string with something in it, else nil.
    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// Why an answer didn't go: the plugin's own words (answered already,
    /// the turn moved on, the agent's place in the room ended, its API
    /// server down).
    static func refusal(for error: Error) -> String {
        AppLocalization.string("Could not answer: \(RoomLinksClient.message(for: error))")
    }
}

extension GroupPendingApproval {
    /// A room elsewhere's approval, for the room screen's card: no member,
    /// task or generation of a room you host.
    init(roomApproval approval: RoomApproval) {
        memberID = approval.agentProfile ?? ""
        taskID = approval.runID
        executionGeneration = 0
        requestID = approval.requestID
        command = approval.command
        description = approval.description
        choices = approval.choices
    }
}

extension AppState {
    /// Whether the host's plugin lists your agents' approvals in rooms
    /// hosted elsewhere. Not in `usedCapabilities`, as with Links.
    var canAnswerRoomApprovals: Bool {
        notifierPlugin.reports(RoomApprovalsClient.capability)
    }

    /// Requests stay with the dashboard they were made for.
    var roomApprovalsClient: RoomApprovalsClient {
        let dashboard = activeDashboardID
        return RoomApprovalsClient(dashboardID: dashboard) { [weak self] path, method, body, timeout in
            guard let self, self.activeDashboardID == dashboard else { throw DashboardTicketBridgeError.notReady }
            return try await self.roomRouteJSON(path: path, method: method, body: body, timeoutMilliseconds: timeout)
        }
    }

    /// Group Chats' approval rows.
    var linkedRoomApprovalRows: [RoomApproval] {
        guard groupChatPhase == .available, canAnswerRoomApprovals,
              let approvals = linkedRoomApprovals, approvals.dashboardID == activeDashboardID else { return [] }
        return approvals.approvals.filter { !answeredLinkedRoomApprovalIDs.contains($0.id) }
    }

    /// The approvals were read, and that one isn't among them any more: it
    /// was answered, or its turn moved on, so its card can't answer it.
    func linkedRoomApprovalIsGone(_ id: String) -> Bool {
        guard canAnswerRoomApprovals, let approvals = linkedRoomApprovals,
              approvals.dashboardID == activeDashboardID else { return false }
        return !approvals.approvals.contains { $0.id == id }
    }

    /// Reads the approvals. A read that fails keeps what was read last, and
    /// one that a sign-out or another dashboard overtook is dropped, as the
    /// invites' is.
    func refreshLinkedRoomApprovals() async {
        _ = await readLinkedRoomApprovals()
    }

    /// The approvals read now, kept for Group Chats; nil when the read
    /// failed or was overtaken.
    private func readLinkedRoomApprovals(timeoutMilliseconds: Int? = nil) async -> [RoomApproval]? {
        guard canAnswerRoomApprovals, isConnected else { return nil }
        let epoch = groupRoomEpoch
        let client = roomApprovalsClient
        guard let approvals = try? await client.approvals(timeoutMilliseconds: timeoutMilliseconds),
              groupRoomEpoch == epoch, activeDashboardID == client.dashboardID else { return nil }
        // One the plugin no longer lists needn't be remembered as answered.
        let listed = Set(approvals.map(\.id))
        if !answeredLinkedRoomApprovalIDs.isSubset(of: listed) {
            answeredLinkedRoomApprovalIDs.formIntersection(listed)
        }
        let read = LinkedRoomApprovals(dashboardID: client.dashboardID, approvals: approvals)
        // A copy's room screen reads them each tick: unchanged, nothing is published.
        if read != linkedRoomApprovals { linkedRoomApprovals = read }
        return approvals
    }

    /// The card's answer. Taken, its row goes; refused, the plugin's words,
    /// and the approvals are read again, so one answered elsewhere drops
    /// its row.
    func answerLinkedRoomApproval(_ approval: RoomApproval, choice: String) async -> RoomApprovalAnswer {
        let client = roomApprovalsClient
        do {
            try await client.answer(approval, choice: choice)
            answeredLinkedRoomApprovalIDs.insert(approval.id)
            if activeDashboardID == client.dashboardID, var approvals = linkedRoomApprovals,
               approvals.dashboardID == client.dashboardID {
                approvals.approvals.removeAll { $0.id == approval.id }
                linkedRoomApprovals = approvals
            }
            return .sent
        } catch {
            let message = RoomApprovalsClient.refusal(for: error)
            await refreshLinkedRoomApprovals()
            return .failed(message)
        }
    }

    /// The listed approval a tapped or arriving "Approval needed"
    /// notification is about: one whose session is any of `keys` (the
    /// decision's session key, the chat's). Nil when the plugin doesn't
    /// list approvals, none matches, or the read fails, so the chat opens
    /// as before.
    func roomApproval(
        matching keys: [String],
        timeoutMilliseconds: Int = RoomApprovalsClient.notificationReadTimeoutMilliseconds
    ) async -> RoomApproval? {
        let wanted = Set(keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !wanted.isEmpty,
              let approvals = await readLinkedRoomApprovals(
                  timeoutMilliseconds: timeoutMilliseconds) else { return nil }
        return approvals.first { approval in
            !answeredLinkedRoomApprovalIDs.contains(approval.id) &&
            approval.sessionKey.map { wanted.contains($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? false
        }
    }
}
