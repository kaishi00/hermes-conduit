import XCTest

@testable import Conduit

/// Your agents' approvals in rooms other people host (designs/
/// cross-owner-agents, C3d): a turn of one of your agents in a room hosted
/// elsewhere waits on your own Hermes for an approval, which the plugin
/// lists (`room_approvals.py`, notifier 0.97) and answers once or deny.
/// Also a linked member's failed turn in the room screen, and #1387's
/// review notes on the join card. An extension, so no new class to plan.
extension GroupChatModelsTests {
    /// An approval as `GET /rooms/approvals` shows it (room_approvals.Approvals.waiting).
    private func approvalsApproval(
        run: String? = "run_a1",
        request: String? = "req-1",
        room: String? = "Zoo trip",
        from: String? = "Furina",
        agent: [String: Any]? = ["profile": "research", "handle": "research-buddy", "display_name": "Research Buddy"],
        sessionKey: String? = "agent:main:conduit:group:abc",
        choices: [String] = ["once", "deny"]
    ) -> [String: Any] {
        var approval: [String: Any] = [
            "room_id": "conduit-2",
            "link": "lk1a2b3c4d5e6f",
            "description": "Run a shell command",
            "command": "ls ~/trips",
            "choices": choices,
        ]
        if let run { approval["run_id"] = run }
        if let request { approval["request_id"] = request }
        approval["room"] = room ?? NSNull()
        approval["from"] = from ?? NSNull()
        if let agent { approval["agent"] = agent }
        approval["session_key"] = sessionKey ?? NSNull()
        return approval
    }

    func testApprovalsListReadsRoomHostAgentAndChoices() async throws {
        let client = RoomApprovalsClient { path, method, body, timeout in
            XCTAssertEqual(path, "/api/plugins/conduit_push/rooms/approvals", "the list takes no profile")
            XCTAssertEqual(method, "GET")
            XCTAssertNil(body)
            XCTAssertNil(timeout)
            return [
                "ok": true,
                "approvals": [
                    self.approvalsApproval(),
                    // A Link without a name, a room the invite didn't name,
                    // no session the store could tell, and a choice a room
                    // turn can't take.
                    self.approvalsApproval(run: "run_b2", request: "req-2", room: nil, from: nil,
                                           agent: ["profile": "default", "handle": NSNull(), "display_name": NSNull()],
                                           sessionKey: nil, choices: ["once", "session", "deny"]),
                    // One that can't be answered is left out: no run or request.
                    self.approvalsApproval(run: nil),
                    self.approvalsApproval(request: ""),
                ],
            ]
        }
        let approvals = try await client.approvals()
        XCTAssertEqual(approvals.map(\.id), ["run_a1/req-1", "run_b2/req-2"])
        let first = try XCTUnwrap(approvals.first)
        XCTAssertEqual(first.runID, "run_a1")
        XCTAssertEqual(first.requestID, "req-1")
        XCTAssertEqual(first.roomID, "conduit-2")
        XCTAssertEqual(first.room, "Zoo trip")
        XCTAssertEqual(first.from, "Furina")
        XCTAssertEqual(first.agentProfile, "research")
        XCTAssertEqual(first.agentHandle, "research-buddy")
        XCTAssertEqual(first.agentName, "Research Buddy")
        XCTAssertEqual(first.sessionKey, "agent:main:conduit:group:abc")
        XCTAssertEqual(first.description, "Run a shell command")
        XCTAssertEqual(first.command, "ls ~/trips")
        XCTAssertEqual(first.choices, ["once", "deny"])
        let second = approvals[1]
        XCTAssertNil(second.room)
        XCTAssertNil(second.from)
        XCTAssertNil(second.agentHandle)
        XCTAssertNil(second.agentName)
        XCTAssertNil(second.sessionKey)
        XCTAssertEqual(second.choices, ["once", "deny"], "a room turn's approval is once or deny only")

        // The room screen's card shows it: what it asks, and Run and Reject.
        let card = first.card
        XCTAssertEqual(card.requestID, "req-1")
        XCTAssertEqual(card.description, "Run a shell command")
        XCTAssertEqual(card.command, "ls ~/trips")
        XCTAssertTrue(card.allows("once"))
        XCTAssertTrue(card.allows("deny"))

        XCTAssertThrowsError(try RoomApprovalsClient.parseList(["ok": false, "approvals": [[String: Any]]()]))
        XCTAssertThrowsError(try RoomApprovalsClient.parseList(["ok": true]))
    }

    func testAnApprovalsLineNamesAgentRoomAndHost() throws {
        func line(room: String? = "Zoo trip", from: String? = "Furina", agent: [String: Any]? = nil) throws -> String {
            let object = agent.map { approvalsApproval(room: room, from: from, agent: $0) }
                ?? approvalsApproval(room: room, from: from)
            return RoomApprovalText.line(for: try XCTUnwrap(RoomApprovalsClient.approval(object)))
        }
        let agent = "Research Buddy"
        let room = "Zoo trip"
        let host = "Furina"
        XCTAssertEqual(try line(), AppLocalization.string("\(agent) in \(room), hosted by \(host)"))
        XCTAssertEqual(try line(from: nil), AppLocalization.string("\(agent) in \(room)"))
        XCTAssertEqual(try line(from: ""), AppLocalization.string("\(agent) in \(room)"))
        XCTAssertEqual(try line(room: nil), AppLocalization.string("\(agent) in a room hosted by \(host)"))
        XCTAssertEqual(try line(room: nil, from: nil), AppLocalization.string("\(agent) in a room hosted elsewhere"))
        // The agent by its name there, else its handle, else its profile.
        let handle = "research-buddy"
        XCTAssertEqual(try line(agent: ["profile": "research", "handle": handle]),
                       AppLocalization.string("\(handle) in \(room), hosted by \(host)"))
        let profile = "research"
        XCTAssertEqual(try line(agent: ["profile": profile, "display_name": ""]),
                       AppLocalization.string("\(profile) in \(room), hosted by \(host)"))
    }

    @MainActor
    func testAnsweringPostsRunRequestAndChoice() async throws {
        let approval = try XCTUnwrap(RoomApprovalsClient.approval(approvalsApproval()))
        var sent: (path: String, method: String, body: [String: Any]?, timeout: Int?)?
        let client = RoomApprovalsClient { path, method, body, timeout in
            sent = (path, method, body, timeout)
            return ["ok": true, "approval": ["run_id": "run_a1", "request_id": "req-1", "choice": "once"]]
        }
        try await client.answer(approval, choice: "once")
        let request = try XCTUnwrap(sent)
        XCTAssertEqual(request.path, "/api/plugins/conduit_push/rooms/approvals/answer")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.timeout, RoomApprovalsClient.answerTimeoutMilliseconds,
                       "the plugin answers within 30 s")
        XCTAssertGreaterThan(RoomApprovalsClient.answerTimeoutMilliseconds, 30_000)
        let body = try XCTUnwrap(request.body)
        XCTAssertEqual(Set(body.keys), ["run_id", "request_id", "choice"])
        XCTAssertEqual(body["run_id"] as? String, "run_a1")
        XCTAssertEqual(body["request_id"] as? String, "req-1")
        XCTAssertEqual(body["choice"] as? String, "once")

        // An answer the plugin didn't say it took isn't one.
        let vague = RoomApprovalsClient { _, _, _, _ in ["ok": false] }
        do {
            try await vague.answer(approval, choice: "deny")
            XCTFail("An answer that wasn't ok read as taken")
        } catch HermesError.invalidResponse {}
    }

    func testApprovalRefusalsShowThePluginsWords() {
        let answered = "That approval was answered already, or its turn moved on"
        XCTAssertEqual(RoomApprovalsClient.refusal(for: DashboardTicketBridgeError.http(status: 409, detail: answered)),
                       AppLocalization.string("Could not answer: \(answered)"))
        let down = "This Hermes' API server didn't answer; check that its gateway runs"
        XCTAssertEqual(RoomApprovalsClient.refusal(for: DashboardTicketBridgeError.http(status: 503, detail: down)),
                       AppLocalization.string("Could not answer: \(down)"))
    }

    // MARK: - When they're read

    /// An AppState on defaults of its own, connected to a gateway that
    /// hosts Group Chats, whose plugin's rooms routes are `routes`.
    @MainActor
    private func approvalsAppState(_ routes: ApprovalsRoutes) -> AppState {
        let suite = "GroupChatModelsTests.approvals.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let operations = GroupChatLifecycleOperations(
            capabilities: { _ in
                GroupCapabilities(protocolVersion: 2, driverReady: true, authorityGatewayID: "gw-a", features: [],
                                  methods: ["groups.list", "groups.create", "groups.state", "groups.send", "groups.log", "groups.disband"],
                                  maxLogLimit: 500)
            },
            list: { _ in ([], nil) },
            roomRoute: { path, method, body, timeout in try await routes.answer(path, method, body, timeout) }
        )
        return AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: .live,
            groupChatOperations: operations,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
    }

    @MainActor
    private func approvalsConnect(_ appState: AppState, url: String = "https://groups.example") {
        appState.client = HermesClient(
            connection: HermesConnection(baseUrl: url, ticket: "groups-test"),
            profile: "default"
        )
        appState.isConnected = true
        _ = appState.adoptDashboard(forNormalizedURL: url)
    }

    /// The plugin's answer once it keeps invites and lists approvals.
    private var approvalsPluginReport: [String: Any] {
        ["ok": true, "version": "0.105.0", "capabilities": [RoomInvitesClient.capability, RoomApprovalsClient.capability]]
    }

    /// Waits until `condition` holds, failing after a few seconds.
    @MainActor
    private func approvalsWait(
        _ what: String, until condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "timed out: \(what)", file: file, line: line)
    }

    /// Group Chats reads the approvals with the drafts and invites, once
    /// the plugin says it lists them; an answer drops its row; a read from
    /// before a sign-out answers after the sign-in, whose own read failed,
    /// and is dropped.
    @MainActor
    func testApprovalsAreReadWithGroupChatsAndDroppedAfterASignOut() async {
        let backend = InMemoryKeychainBackend()
        KeychainHelper.useBackendForTesting(backend)
        defer { KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend()) }
        let routes = ApprovalsRoutes(approvals: [approvalsApproval(), approvalsApproval(run: "run_b2", request: "req-2")])
        let appState = approvalsAppState(routes)
        approvalsConnect(appState)
        await appState.refreshGroupChatSupport()
        XCTAssertEqual(appState.groupChatPhase, .available)
        XCTAssertEqual(routes.approvalsReads, 0, "not before the plugin says it lists them")

        appState.applyNotifierPluginReport(approvalsPluginReport)
        await approvalsWait("the approvals read", until: { appState.linkedRoomApprovalRows.map(\.id) == ["run_a1/req-1", "run_b2/req-2"] })
        XCTAssertEqual(routes.approvalsReads, 1)
        await appState.refreshGroupChatSupport()
        XCTAssertEqual(routes.approvalsReads, 2, "Group Chats reads them, as it reads the invites")

        // Answered: its row goes, and its card says it isn't waiting.
        let first = appState.linkedRoomApprovalRows[0]
        XCTAssertFalse(appState.linkedRoomApprovalIsGone(first.id))
        let answered = await appState.answerLinkedRoomApproval(first, choice: "once")
        XCTAssertEqual(answered, .sent)
        XCTAssertEqual(routes.answers.map { $0["choice"] as? String }, ["once"])
        XCTAssertEqual(appState.linkedRoomApprovalRows.map(\.id), ["run_b2/req-2"])
        XCTAssertTrue(appState.linkedRoomApprovalIsGone(first.id))
        // Refused: the plugin's words, and the list read again drops one
        // answered elsewhere.
        routes.refusesAnswers = true
        routes.approvals = []
        let refused = await appState.answerLinkedRoomApproval(appState.linkedRoomApprovalRows[0], choice: "deny")
        XCTAssertEqual(refused, .failed(AppLocalization.string("Could not answer: \(ApprovalsRoutes.notPending)")))
        XCTAssertEqual(appState.linkedRoomApprovalRows, [])

        // A new one (the one answered here stays gone).
        routes.approvals = [approvalsApproval(run: "run_c3")]
        await appState.refreshGroupChatSupport()
        XCTAssertEqual(appState.linkedRoomApprovalRows.count, 1)
        routes.holdsNextRead = true
        let before = Task { @MainActor in await appState.refreshGroupChatSupport() }
        await approvalsWait("the held read", until: { routes.holding })
        appState.disconnect()
        XCTAssertEqual(appState.linkedRoomApprovalRows, [], "a sign-out clears them")
        routes.readsFail = true
        approvalsConnect(appState)
        appState.applyNotifierPluginReport(approvalsPluginReport)
        await appState.refreshGroupChatSupport()
        routes.answerHeldRead()
        await before.value
        XCTAssertEqual(appState.groupChatPhase, .available)
        XCTAssertEqual(appState.linkedRoomApprovalRows, [], "the read from before the sign-out is dropped")
    }

    /// An "Approval needed" notification opens a listed approval's card
    /// when its decision's session key or its chat is the approval's
    /// session; anything else opens its chat as before.
    @MainActor
    func testAnApprovalNotificationMatchesByDecisionKeyOrChat() async {
        let routes = ApprovalsRoutes(approvals: [approvalsApproval(), approvalsApproval(run: "run_b2", request: "req-2", sessionKey: nil)])
        let appState = approvalsAppState(routes)
        approvalsConnect(appState)
        let early = await appState.roomApproval(matching: ["agent:main:conduit:group:abc"])
        XCTAssertNil(early, "not before the plugin says it lists them")
        XCTAssertEqual(routes.approvalsReads, 0)

        appState.applyNotifierPluginReport(approvalsPluginReport)
        let byKey = await appState.roomApproval(matching: ["agent:main:conduit:group:abc"])
        XCTAssertEqual(byKey?.id, "run_a1/req-1")
        let byChat = await appState.roomApproval(matching: ["20261027_101500_abc", " agent:main:conduit:group:abc "])
        XCTAssertEqual(byChat?.id, "run_a1/req-1", "any of the push's keys, trimmed")
        let other = await appState.roomApproval(matching: ["20261027_101500_abc"])
        XCTAssertNil(other, "an approval in a chat of your own opens that chat")
        let none = await appState.roomApproval(matching: [])
        XCTAssertNil(none)
        routes.readsFail = true
        let failed = await appState.roomApproval(matching: ["agent:main:conduit:group:abc"])
        XCTAssertNil(failed, "a read that fails opens the chat as before")
    }

    // MARK: - A linked member's failed turn

    func testALinkedMembersFailedTurnShowsItsError() throws {
        func member(_ kind: String) -> GroupMember {
            GroupMember(memberID: "m-laifu", profile: "default", handle: "laifu", displayName: "Laifu",
                        target: ["kind": .string(kind)], extra: [:])
        }
        func event(_ kind: String, _ payload: [String: AnyCodable]) -> GroupEvent {
            GroupEvent(roomID: "conduit-1", seq: 4, eventID: "e4", kind: kind,
                       actor: GroupActor(kind: "gateway", id: "gw-a", profile: nil, displayName: nil, connectionID: nil),
                       authorityEpoch: nil, payload: payload, createdAt: 0)
        }
        func failed(_ error: AnyCodable?) -> GroupEvent {
            var payload: [String: AnyCodable] = ["member_id": .string("m-laifu"), "reason_code": .string("unknown")]
            if let error { payload["error"] = error }
            return event("turn.failed", payload)
        }
        let peer = member("peer")
        XCTAssertEqual(GroupRoomTurns.failureDetail(failed(.string("  Laifu's Hermes didn't answer.\n")), members: [peer]),
                       "Laifu's Hermes didn't answer.")
        XCTAssertEqual(GroupRoomTurns.failureDetail(failed(.string("This turn ran past 12 minutes on Laifu's Hermes.")), members: [peer]),
                       "This turn ran past 12 minutes on Laifu's Hermes.")
        // Cut at 300 characters, on one line.
        let long = String(repeating: "x", count: 400)
        XCTAssertEqual(GroupRoomTurns.failureDetail(failed(.string("line one\n\(long)")), members: [peer])?.count, 300)
        XCTAssertEqual(GroupRoomTurns.failureDetail(failed(.string("line one\n\nline two")), members: [peer]), "line one line two")
        XCTAssertNil(GroupRoomTurns.failureDetail(failed(.string("   ")), members: [peer]))
        XCTAssertNil(GroupRoomTurns.failureDetail(failed(nil), members: [peer]))
        XCTAssertNil(GroupRoomTurns.failureDetail(failed(.number(4)), members: [peer]))
        // Your own agents' failures keep their one line: their error is Hermes' raw one.
        XCTAssertNil(GroupRoomTurns.failureDetail(failed(.string("Traceback (most recent call last)")), members: [member("local")]))
        XCTAssertNil(GroupRoomTurns.failureDetail(failed(.string("Laifu's Hermes didn't answer.")), members: []))
        // Another kind has none, and a deferred turn stays hidden.
        let cancelled = event("turn.cancelled", ["member_id": .string("m-laifu"), "error": .string("x")])
        XCTAssertNil(GroupRoomTurns.failureDetail(cancelled, members: [peer]))
        let deferred = event("turn.deferred", ["member_id": .string("m-laifu"), "reason": .string("member_unavailable")])
        XCTAssertFalse(GroupRoomTurns.isVisible(deferred))
    }

    // MARK: - #1387's review notes

    /// A tapped invite whose dashboard changed while the invites were read
    /// tries again, rather than waiting for a change that already came.
    @MainActor
    func testAnInviteTapRetriesWhenTheDashboardChangedMidRead() async {
        let backend = InMemoryKeychainBackend()
        KeychainHelper.useBackendForTesting(backend)
        defer { KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend()) }
        let routes = ApprovalsRoutes(approvals: [])
        routes.invites = [[
            "room_id": "conduit-1", "link": "lk1a2b3c4d5e6f", "name": "Zoo trip", "status": "waiting", "from": "Furina",
            "slots": 2, "profiles": [[String: Any]](),
        ]]
        let appState = approvalsAppState(routes)
        approvalsConnect(appState)
        appState.applyNotifierPluginReport(approvalsPluginReport)
        let tapped = RoomInviteTarget(link: "lk1a2b3c4d5e6f", roomID: "conduit-1", dashboardID: appState.activeDashboardID)
        routes.holdsNextInvitesRead = true
        let opening = Task { @MainActor in await appState.openRoomInvite(tapped) }
        await approvalsWait("the held read", until: { routes.holding })
        _ = appState.adoptDashboard(forNormalizedURL: "https://other.example")
        routes.answerHeldRead()
        let outcome = await opening.value
        XCTAssertEqual(outcome, .retry)
        XCTAssertNil(appState.presentedRoomInvite)
    }

    func testPickedBotsTheInviteNoLongerListsAreSaid() throws {
        XCTAssertEqual(RoomInviteLimits.unlisted(picked: ["default", "research"], profiles: ["default"]), ["research"])
        XCTAssertEqual(RoomInviteLimits.unlisted(picked: ["default"], profiles: ["default", "research"]), [])
        XCTAssertEqual(RoomInviteLimits.unlisted(picked: [], profiles: []), [])
    }

    /// A card whose invite a read no longer lists says so; one the list
    /// has, or before any read, doesn't.
    @MainActor
    func testACardWhoseInviteLeftTheListSaysSo() async {
        let routes = ApprovalsRoutes(approvals: [])
        routes.invites = [[
            "room_id": "conduit-1", "link": "lk1a2b3c4d5e6f", "name": "Zoo trip", "status": "waiting", "from": "Furina",
            "slots": 2, "profiles": [[String: Any]](),
        ]]
        let appState = approvalsAppState(routes)
        approvalsConnect(appState)
        appState.applyNotifierPluginReport(approvalsPluginReport)
        XCTAssertFalse(appState.linkedRoomInviteIsGone("lk1a2b3c4d5e6f/conduit-1"), "nothing read yet")
        await appState.refreshLinkedRoomInvites()
        XCTAssertFalse(appState.linkedRoomInviteIsGone("lk1a2b3c4d5e6f/conduit-1"))
        routes.invites = []
        await appState.refreshLinkedRoomInvites()
        XCTAssertTrue(appState.linkedRoomInviteIsGone("lk1a2b3c4d5e6f/conduit-1"))
    }
}

/// The plugin's rooms routes behind an AppState for the approvals: reads
/// are counted, answers kept, the next read can wait until the test
/// answers it, and other routes answer empty lists.
@MainActor
private final class ApprovalsRoutes {
    static let notPending = "That approval was answered already, or its turn moved on"

    var approvals: [[String: Any]]
    var invites: [[String: Any]] = []
    /// The next approvals read waits until `answerHeldRead()`.
    var holdsNextRead = false
    /// The next invites read waits until `answerHeldRead()`.
    var holdsNextInvitesRead = false
    /// Approvals reads fail from now on.
    var readsFail = false
    /// Answers are refused as answered already.
    var refusesAnswers = false
    private(set) var approvalsReads = 0
    private(set) var answers: [[String: Any]] = []
    private(set) var holding = false
    private var released = false

    init(approvals: [[String: Any]]) {
        self.approvals = approvals
    }

    func answer(_ path: String, _ method: String, _ body: [String: Any]?, _ timeout: Int?) async throws -> [String: Any] {
        switch (path, method) {
        case (RoomDraftsClient.path, "GET"):
            let starts: [String: Any] = ["available": true, "reason": NSNull()]
            return ["ok": true, "drafts": [[String: Any]](), "starts": starts]
        case (RoomInvitesClient.path, "GET"):
            if holdsNextInvitesRead {
                holdsNextInvitesRead = false
                await hold()
            }
            return ["ok": true, "invites": invites]
        case (RoomApprovalsClient.path, "GET"):
            approvalsReads += 1
            if holdsNextRead {
                holdsNextRead = false
                await hold()
            } else if readsFail {
                throw URLError(.timedOut)
            }
            return ["ok": true, "approvals": approvals]
        case ("\(RoomApprovalsClient.path)/answer", "POST"):
            if refusesAnswers { throw DashboardTicketBridgeError.http(status: 409, detail: Self.notPending) }
            answers.append(body ?? [:])
            let run = body?["run_id"] as? String
            let request = body?["request_id"] as? String
            approvals.removeAll { $0["run_id"] as? String == run && $0["request_id"] as? String == request }
            return ["ok": true, "approval": body ?? [:]]
        default:
            throw URLError(.fileDoesNotExist)
        }
    }

    private func hold() async {
        holding = true
        while !released, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        holding = false
        released = false
    }

    func answerHeldRead() {
        released = true
    }
}
