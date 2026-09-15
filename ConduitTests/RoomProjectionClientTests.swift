//
//  RoomProjectionClientTests.swift
//  Conduit
//
//  Fake-transport contract tests for the ANVIL Room read seam. The fixtures
//  mirror the Hub H1 wire shapes verbatim (feat/room-projection-v1-20260915
//  @ 078ff5a2 — src/public-api/contracts.ts): snake_case Room payloads,
//  camelCase requestId inside the problem document.
//

import Foundation
import XCTest
@testable import Conduit

final class RoomProjectionClientTests: XCTestCase {
    static let roomID = "10000000-0000-4000-8000-0000000000a1"
    static let roomB = "10000000-0000-4000-8000-0000000000b1"
    static let correlation = "10000000-0000-4000-8000-0000000000d1"
    static let participant = "10000000-0000-4000-8000-0000000000e1"
    static let agent = "10000000-0000-4000-8000-0000000000c2"
    static let eventA = "20000000-0000-4000-8000-0000000000a1"
    static let eventB = "20000000-0000-4000-8000-0000000000a2"

    override func setUp() {
        super.setUp()
        RoomAPIStub.reset()
    }

    override func tearDown() {
        RoomAPIStub.reset()
        super.tearDown()
    }

    private func makeClient(
        baseURL: String = "https://hub.test",
        token: String = "hub-api-key"
    ) throws -> RoomProjectionClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoomAPIStub.self]
        return try RoomProjectionClient(
            credential: RoomHubCredential(hubBaseURL: baseURL, token: token),
            transport: .urlSession(URLSession(configuration: configuration))
        )
    }

    // MARK: - Snapshot decode

    func testListRoomsDecodesProjectedRoomsVerbatim() async throws {
        RoomAPIStub.handler = { _ in (200, [:], Self.roomListBody) }
        let list = try await makeClient().listRooms()

        XCTAssertEqual(list.rooms.count, 2)
        let room = list.rooms[0]
        XCTAssertEqual(room.roomID, Self.roomID)
        XCTAssertEqual(room.projectRef, "anvil/core")
        XCTAssertEqual(room.status, .active)
        XCTAssertEqual(room.correlationID, Self.correlation)
        XCTAssertEqual(room.latestSeq, 7)
        XCTAssertEqual(room.createdAt, "2026-09-15T10:00:00.000Z")
        XCTAssertEqual(room.updatedAt, "2026-09-15T12:00:00.000Z")
        XCTAssertNil(list.rooms[1].projectRef)
        XCTAssertEqual(list.rooms[1].status, .archived)
    }

    func testRoomSnapshotDecodesRoomAndActiveParticipants() async throws {
        RoomAPIStub.handler = { _ in (200, [:], Self.snapshotBody) }
        let snapshot = try await makeClient().roomSnapshot(roomID: Self.roomID)

        XCTAssertEqual(snapshot.room.roomID, Self.roomID)
        XCTAssertEqual(snapshot.room.latestSeq, 7)
        XCTAssertEqual(snapshot.participants.count, 1)
        let member = snapshot.participants[0]
        XCTAssertEqual(member.participantID, Self.participant)
        XCTAssertEqual(member.agentID, Self.agent)
        XCTAssertEqual(member.role, "participant")
        XCTAssertEqual(member.joinedSeq, 3)
        XCTAssertEqual(member.ackedSeq, 5)
        XCTAssertEqual(member.joinedAt, "2026-09-15T10:05:00.000Z")
    }

    func testReplayPageDecodesEventsWithServerOwnedFieldsVerbatim() async throws {
        RoomAPIStub.handler = { _ in (200, [:], Self.eventPageBody) }
        let page = try await makeClient().replayEvents(roomID: Self.roomID, after: 3, limit: 2)

        XCTAssertEqual(page.room.roomID, Self.roomID)
        XCTAssertEqual(page.latestSeq, 7)
        XCTAssertEqual(page.nextCursor, 5)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.events.count, 2)

        let first = page.events[0]
        XCTAssertEqual(first.eventID, Self.eventA)
        XCTAssertEqual(first.roomID, Self.roomID)
        XCTAssertEqual(first.roomSeq, 4)
        XCTAssertEqual(first.kind, .message)
        XCTAssertEqual(first.producer, "agent:\(Self.agent)")
        XCTAssertEqual(first.payload["text"]?.stringValue, "first replayed")
        XCTAssertEqual(first.link["hop"]?.intValue, 2)
        XCTAssertEqual(first.correlationID, Self.correlation)
        XCTAssertEqual(first.causationID, "agent:\(Self.agent):9")
        XCTAssertEqual(first.taskRef, "30000000-0000-4000-8000-0000000000f1")
        XCTAssertEqual(first.campaignID, "campaign-77")
        XCTAssertEqual(first.idempotencyKey, "agent:\(Self.agent):41")
        XCTAssertEqual(first.occurredAt, "2026-09-15T11:00:00.000Z")
        XCTAssertEqual(first.createdAt, "2026-09-15T11:00:01.000Z")

        let second = page.events[1]
        XCTAssertEqual(second.kind, .evidenceRef)
        XCTAssertNil(second.causationID)
        XCTAssertNil(second.taskRef)
        XCTAssertNil(second.campaignID)
        XCTAssertNil(second.occurredAt)
        XCTAssertEqual(
            second.payload["evidence"]?.objectValue?["sha256"]?.stringValue,
            "9f2c"
        )
    }

    // MARK: - Request shape

    func testRequestsCarryBearerCredentialAndExactRoutes() async throws {
        var requests: [URLRequest] = []
        RoomAPIStub.handler = { request in
            requests.append(request)
            return (200, [:], Data(#"{"rooms":[]}"#.utf8))
        }
        _ = try await makeClient(token: "secret-room-token").listRooms()

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].url?.path, "/api/v1/rooms")
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "Authorization"),
            "Bearer secret-room-token"
        )
    }

    func testReplayRequestEncodesAfterAndLimitQuery() async throws {
        var captured: URLRequest?
        RoomAPIStub.handler = { request in
            captured = request
            return (200, [:], Self.emptyPageBody)
        }
        _ = try await makeClient().replayEvents(roomID: Self.roomID, after: 42, limit: 7)

        let components = try XCTUnwrap(captured?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        XCTAssertEqual(components.path, "/api/v1/rooms/\(Self.roomID)/events")
        let items = components.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "after" })?.value, "42")
        XCTAssertEqual(items.first(where: { $0.name == "limit" })?.value, "7")
    }

    func testReplayClampsOutOfContractCursorAndLimit() async throws {
        var captured: URLRequest?
        RoomAPIStub.handler = { request in
            captured = request
            return (200, [:], Self.emptyPageBody)
        }
        _ = try await makeClient().replayEvents(roomID: Self.roomID, after: -3, limit: 9999)

        let items = captured?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
        // The client can never emit a query the H1 route schema would 400.
        XCTAssertEqual(items.first(where: { $0.name == "after" })?.value, "0")
        XCTAssertEqual(items.first(where: { $0.name == "limit" })?.value, "500")
    }

    // MARK: - 401/403/404/503 distinction

    func testUnauthorized401MapsDistinctFromForbidden() async throws {
        RoomAPIStub.handler = { _ in
            (401, ["Content-Type": "application/problem+json", "WWW-Authenticate": "Bearer"], Self.problemBody(
                status: 401, code: "unauthorized", title: "Authentication required"
            ))
        }
        do {
            _ = try await makeClient().listRooms()
            XCTFail("Expected unauthorized")
        } catch let error as RoomProjectionError {
            guard case .unauthorized(let problem) = error else {
                return XCTFail("Expected .unauthorized, got \(error)")
            }
            XCTAssertEqual(problem.code, "unauthorized")
            XCTAssertEqual(problem.requestID, "req-401")
        }
    }

    func testForbidden403SplitsScopeFromGrant() async throws {
        for (code, expectScope) in [("insufficient_scope", true), ("capability_denied", false)] {
            RoomAPIStub.handler = { _ in
                (403, ["Content-Type": "application/problem+json"], Self.problemBody(
                    status: 403, code: code, title: "Forbidden"
                ))
            }
            do {
                _ = try await makeClient().roomSnapshot(roomID: Self.roomID)
                XCTFail("Expected forbidden for \(code)")
            } catch let error as RoomProjectionError {
                if expectScope {
                    guard case .insufficientScope(let problem) = error else {
                        return XCTFail("Expected .insufficientScope, got \(error)")
                    }
                    XCTAssertEqual(problem.code, "insufficient_scope")
                } else {
                    guard case .capabilityDenied(let problem) = error else {
                        return XCTFail("Expected .capabilityDenied, got \(error)")
                    }
                    XCTAssertEqual(problem.code, "capability_denied")
                }
            }
        }
    }

    func testRoomNotFound404() async throws {
        RoomAPIStub.handler = { _ in
            (404, ["Content-Type": "application/problem+json"], Self.problemBody(
                status: 404, code: "room_not_found", title: "Room not found"
            ))
        }
        do {
            _ = try await makeClient().replayEvents(roomID: Self.roomID, after: 0)
            XCTFail("Expected room not found")
        } catch let error as RoomProjectionError {
            guard case .roomNotFound(let problem) = error else {
                return XCTFail("Expected .roomNotFound, got \(error)")
            }
            XCTAssertEqual(problem.code, "room_not_found")
        }
    }

    func testProjectionUnavailable503() async throws {
        RoomAPIStub.handler = { _ in
            (503, ["Content-Type": "application/problem+json"], Self.problemBody(
                status: 503, code: "room_projection_unavailable", title: "Room projection unavailable"
            ))
        }
        do {
            _ = try await makeClient().listRooms()
            XCTFail("Expected projection unavailable")
        } catch let error as RoomProjectionError {
            guard case .projectionUnavailable(let problem) = error else {
                return XCTFail("Expected .projectionUnavailable, got \(error)")
            }
            XCTAssertEqual(problem.code, "room_projection_unavailable")
        }
    }

    func testServiceUnavailable503SplitsAuthFromInfrastructure() async throws {
        for code in ["authentication_unavailable", "infrastructure_unavailable"] {
            RoomAPIStub.handler = { _ in
                (503, ["Content-Type": "application/problem+json"], Self.problemBody(
                    status: 503, code: code, title: "Unavailable"
                ))
            }
            do {
                _ = try await makeClient().listRooms()
                XCTFail("Expected unavailable for \(code)")
            } catch let error as RoomProjectionError {
                if code == "authentication_unavailable" {
                    guard case .authenticationUnavailable = error else {
                        return XCTFail("Expected .authenticationUnavailable, got \(error)")
                    }
                } else {
                    guard case .infrastructureUnavailable = error else {
                        return XCTFail("Expected .infrastructureUnavailable, got \(error)")
                    }
                }
            }
        }
    }

    // MARK: - Contract breaches

    func testUndecodableSuccessPayloadIsATypedFailure() async throws {
        RoomAPIStub.handler = { _ in (200, [:], Data("<html>not json</html>".utf8)) }
        do {
            _ = try await makeClient().listRooms()
            XCTFail("Expected undecodable")
        } catch let error as RoomProjectionError {
            guard case .undecodable(let status, _) = error else {
                return XCTFail("Expected .undecodable, got \(error)")
            }
            XCTAssertEqual(status, 200)
        }
    }

    func testUnknownServerFailureKeepsStatusAndProblem() async throws {
        RoomAPIStub.handler = { _ in
            (500, ["Content-Type": "application/problem+json"], Self.problemBody(
                status: 500, code: "internal_error", title: "Internal server error"
            ))
        }
        do {
            _ = try await makeClient().listRooms()
            XCTFail("Expected problem")
        } catch let error as RoomProjectionError {
            guard case .problem(let status, let problem) = error else {
                return XCTFail("Expected .problem, got \(error)")
            }
            XCTAssertEqual(status, 500)
            XCTAssertEqual(problem?.code, "internal_error")
        }
    }

    func testNonLocalCleartextHubURLRejected() {
        XCTAssertThrowsError(
            try makeClient(baseURL: "http://hub.example.com")
        ) { error in
            XCTAssertTrue(
                error is ConnectionURLPolicyError,
                "Remote cleartext hub must be rejected by connection policy, got \(error)"
            )
        }
    }

    // MARK: - Fixtures (H1 wire shapes, verbatim field names)

    private static var roomListBody: Data {
        Data(#"""
        {"rooms":[
          {"room_id":"\#(roomID)","project_ref":"anvil/core","status":"active",
           "correlation_id":"\#(correlation)","latest_seq":7,
           "created_at":"2026-09-15T10:00:00.000Z","updated_at":"2026-09-15T12:00:00.000Z"},
          {"room_id":"\#(roomB)","project_ref":null,"status":"archived",
           "correlation_id":"\#(correlation)","latest_seq":0,
           "created_at":"2026-09-15T09:00:00.000Z","updated_at":"2026-09-15T09:30:00.000Z"}
        ]}
        """#.utf8)
    }

    private static var snapshotBody: Data {
        Data(#"""
        {"room":{"room_id":"\#(roomID)","project_ref":"anvil/core","status":"active",
          "correlation_id":"\#(correlation)","latest_seq":7,
          "created_at":"2026-09-15T10:00:00.000Z","updated_at":"2026-09-15T12:00:00.000Z"},
         "participants":[
          {"participant_id":"\#(participant)","agent_id":"\#(agent)","role":"participant",
           "joined_seq":3,"acked_seq":5,"joined_at":"2026-09-15T10:05:00.000Z"}
         ]}
        """#.utf8)
    }

    private static var eventPageBody: Data {
        Data(#"""
        {"room":{"room_id":"\#(roomID)","project_ref":"anvil/core","status":"active",
          "correlation_id":"\#(correlation)","latest_seq":7,
          "created_at":"2026-09-15T10:00:00.000Z","updated_at":"2026-09-15T12:00:00.000Z"},
         "events":[
          {"event_id":"\#(eventA)","room_id":"\#(roomID)","room_seq":4,"kind":"message",
           "producer":"agent:\#(agent)","payload":{"text":"first replayed"},
           "link":{"hop":2},"correlation_id":"\#(correlation)",
           "causation_id":"agent:\#(agent):9","task_ref":"30000000-0000-4000-8000-0000000000f1",
           "campaign_id":"campaign-77","idempotency_key":"agent:\#(agent):41",
           "occurred_at":"2026-09-15T11:00:00.000Z","created_at":"2026-09-15T11:00:01.000Z"},
          {"event_id":"\#(eventB)","room_id":"\#(roomID)","room_seq":5,"kind":"evidence_ref",
           "producer":"service:receipts","payload":{"evidence":{"sha256":"9f2c"}},
           "link":{},"correlation_id":"\#(correlation)",
           "causation_id":null,"task_ref":null,"campaign_id":null,
           "idempotency_key":"service:receipts:7","occurred_at":null,
           "created_at":"2026-09-15T11:05:00.000Z"}
         ],
         "latest_seq":7,"next_cursor":5,"has_more":true}
        """#.utf8)
    }

    private static var emptyPageBody: Data {
        Data(#"""
        {"room":{"room_id":"\#(roomID)","project_ref":null,"status":"active",
          "correlation_id":"\#(correlation)","latest_seq":7,
          "created_at":"2026-09-15T10:00:00.000Z","updated_at":"2026-09-15T12:00:00.000Z"},
         "events":[],"latest_seq":7,"next_cursor":42,"has_more":false}
        """#.utf8)
    }

    private static func problemBody(status: Int, code: String, title: String) -> Data {
        Data(#"""
        {"type":"https://paseo.sh/problems/\#(code.replacingOccurrences(of: "_", with: "-"))",
         "title":"\#(title)","status":\#(status),"detail":"detail for \#(code)",
         "code":"\#(code)","requestId":"req-\#(status)"}
        """#.utf8)
    }
}

/// URLProtocol stub: one programmable handler for every request, with the
/// request log available for header/query assertions.
private final class RoomAPIStub: URLProtocol {
    static var handler: ((URLRequest) -> (status: Int, headers: [String: String], body: Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "hub.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let fixture = handler(request)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: fixture.status,
            httpVersion: "HTTP/1.1",
            headerFields: fixture.headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        handler = nil
    }
}
