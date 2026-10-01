//
//  AppStateMoveSessionTests.swift
//  Conduit
//
//  "Move to Project" re-homes a conversation's workspace through
//  `session.workspace.move`. The gateway looks the row up by its DURABLE
//  stored key, so a live catalog row (runtime `id`, durable
//  `storedSessionId`) must send the stored key. A gateway without the RPC
//  must stop offering the action without losing the project tree.
//
//  These ride on AppStateDecisionFenceTests (same parked fake-socket
//  harness) instead of a new XCTestCase class: the local gate's plan is at
//  its class cap (see scripts/plan-tests.py validate).
//

import XCTest
@testable import Conduit

extension AppStateDecisionFenceTests {

    private func makeMoveAppState() -> AppState {
        let suite = "AppStateMoveSessionTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
    }

    private func installMoveClient(
        _ appState: AppState,
        socket: ClarifyFakeSocket,
        transport: ClarifyFakeTransport
    ) async throws -> HermesClient {
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        let client = HermesClient(
            connection: connection,
            profile: "default",
            transportFactory: { transport }
        )
        transport.nextSocket = { socket }
        appState.connection = connection
        appState.client = client
        let connectTask = Task { try await client.connect() }
        transport.open(socket)
        _ = try await connectTask.value
        appState.isConnected = true
        return client
    }

    private func liveSession() -> SessionSummary {
        SessionSummary(
            id: "runtime-1",
            storedSessionId: "stored-1",
            alternateIds: ["stored-1"],
            title: "Wrong folder",
            model: "Hermes",
            updatedLabel: "now",
            profile: "default",
            source: .chat,
            isActive: true,
            isArchived: false,
            lineageRootId: nil
        )
    }

    private var projectTree: [String: Any] { [
        "projects": [
            ["id": "home", "label": "Home", "is_no_project": true, "session_count": 1],
            ["id": "p1", "label": "Skunkworks", "path": "/work/skunkworks", "session_count": 0]
        ],
        "active_id": NSNull(),
        "scoped_session_ids": []
    ] }

    /// Waits for the next RPC on `socket` and returns its decoded request.
    private func nextRequest(
        on socket: ClarifyFakeSocket,
        _ phase: String,
        during start: () -> Void
    ) async throws -> [String: Any] {
        let sent = ClarifyGate()
        socket.onSend = { sent.signal() }
        start()
        try await sent.wait(phase)
        socket.onSend = nil
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sentTexts.last).utf8)) as? [String: Any]
        )
    }

    private func respond(on socket: ClarifyFakeSocket, to request: [String: Any], with body: [String: Any]) throws {
        var response: [String: Any] = ["jsonrpc": "2.0", "id": try XCTUnwrap(request["id"] as? Int)]
        response.merge(body) { _, new in new }
        socket.deliver(try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: response), encoding: .utf8)))
    }

    private func loadMoveProjects(_ appState: AppState, socket: ClarifyFakeSocket) async throws {
        var refresh: Task<Void, Never>?
        let request = try await nextRequest(on: socket, "the projects.tree request") {
            refresh = Task { await appState.refreshProjects() }
        }
        XCTAssertEqual(request["method"] as? String, "projects.tree")
        try respond(on: socket, to: request, with: ["result": projectTree])
        await refresh?.value
    }

    func testMoveSendsTheDurableStoredKeyAndReloadsProjects() async throws {
        let appState = makeMoveAppState()
        let socket = ClarifyFakeSocket()
        let transport = ClarifyFakeTransport()
        _ = try await installMoveClient(appState, socket: socket, transport: transport)
        try await loadMoveProjects(appState, socket: socket)

        XCTAssertEqual(appState.projectMoveTargets.map(\.id), ["p1"], "Home has no folder to move into")
        let target = try XCTUnwrap(appState.projectMoveTargets.first)

        var move: Task<Bool, Never>?
        let request = try await nextRequest(on: socket, "the workspace move request") {
            move = Task { await appState.moveSession(self.liveSession(), to: target) }
        }
        XCTAssertEqual(request["method"] as? String, "session.workspace.move")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["session_key"] as? String, "stored-1", "the gateway looks rows up by the stored key")
        XCTAssertEqual(params["cwd"] as? String, "/work/skunkworks")

        let reload = try await nextRequest(on: socket, "the project tree reload after the move") {
            try? respond(on: socket, to: request, with: ["result": ["cwd": "/work/skunkworks"]])
        }
        XCTAssertEqual(reload["method"] as? String, "projects.tree")
        try respond(on: socket, to: reload, with: ["result": projectTree])

        let moved = await move?.value
        XCTAssertEqual(moved, true)
        XCTAssertNil(appState.errorMessage)
    }

    func testMissingMoveRPCHidesTheActionButKeepsProjects() async throws {
        let appState = makeMoveAppState()
        let socket = ClarifyFakeSocket()
        let transport = ClarifyFakeTransport()
        _ = try await installMoveClient(appState, socket: socket, transport: transport)
        try await loadMoveProjects(appState, socket: socket)
        let target = try XCTUnwrap(appState.projectMoveTargets.first)

        var move: Task<Bool, Never>?
        let request = try await nextRequest(on: socket, "the workspace move request") {
            move = Task { await appState.moveSession(self.liveSession(), to: target) }
        }
        try respond(on: socket, to: request, with: [
            "error": ["code": -32601, "message": "Method not found: session.workspace.move"]
        ])

        let moved = await move?.value
        XCTAssertEqual(moved, false)
        XCTAssertTrue(appState.supportsProjects, "the project tree still works on this gateway")
        XCTAssertFalse(appState.supportsSessionWorkspaceMove)
        XCTAssertTrue(appState.projectMoveTargets.isEmpty, "the action is no longer offered")
        XCTAssertNotNil(appState.errorMessage)
    }

    func testNewConnectionProbesTheMoveRPCAgain() async throws {
        let appState = makeMoveAppState()
        let socket = ClarifyFakeSocket()
        let transport = ClarifyFakeTransport()
        let first = try await installMoveClient(appState, socket: socket, transport: transport)
        try await loadMoveProjects(appState, socket: socket)
        let target = try XCTUnwrap(appState.projectMoveTargets.first)

        var move: Task<Bool, Never>?
        let request = try await nextRequest(on: socket, "the workspace move request") {
            move = Task { await appState.moveSession(self.liveSession(), to: target) }
        }
        try respond(on: socket, to: request, with: [
            "error": ["code": -32601, "message": "Method not found: session.workspace.move"]
        ])
        _ = await move?.value
        XCTAssertFalse(appState.supportsSessionWorkspaceMove)

        // A reconnect builds a new client; the gateway behind it may have
        // been upgraded in place, so the suppression must not carry over.
        let second = try await installMoveClient(appState, socket: ClarifyFakeSocket(), transport: ClarifyFakeTransport())
        first.disconnect()
        XCTAssertTrue(appState.supportsSessionWorkspaceMove)
        XCTAssertEqual(appState.projectMoveTargets.map(\.id), ["p1"])
        second.disconnect()
    }
}
