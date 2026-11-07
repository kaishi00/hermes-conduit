//
//  MistralLiveProtocolTests.swift
//  ConduitTests
//
//  The Mistral voice agent's wire format: the events its LiveKit room
//  carries, the function calls it makes over RPC, and the session the
//  Hermes host answers with. Every shape here was checked against
//  mistralai 3.7.0's own models (`client/models/voiceagent*.py`).
//

import XCTest
@testable import Conduit

final class MistralLiveProtocolTests: XCTestCase {

    // MARK: - Events

    func testAFinalTranscriptSegmentCarriesItsRoleAndText() {
        let event = MistralLiveProtocol.decode("""
        {"type":"transcription.segment","id":"seg-1","role":"user","content":"what is on my plate","final":true,"ts":1.5}
        """)
        XCTAssertEqual(event, .transcript(id: "seg-1", role: .user, content: "what is on my plate", final: true))
    }

    func testAPartialSegmentIsMarkedUnfinished() {
        let event = MistralLiveProtocol.decode("""
        {"type":"transcription.segment","id":"seg-2","role":"assistant","content":"Looking","final":false,"ts":2}
        """)
        XCTAssertEqual(event, .transcript(id: "seg-2", role: .assistant, content: "Looking", final: false))
    }

    /// The segment is cumulative: the same id comes again with more text, and
    /// the caller replaces the line rather than appending to it.
    func testASegmentWithTheSameIdReplacesTheLine() {
        let first = MistralLiveProtocol.decode("""
        {"type":"transcription.segment","id":"seg-3","role":"assistant","content":"Look","final":false}
        """)
        let second = MistralLiveProtocol.decode("""
        {"type":"transcription.segment","id":"seg-3","role":"assistant","content":"Looking now.","final":true}
        """)
        guard case .transcript(let firstID, _, _, _) = first,
              case .transcript(let secondID, _, let text, let final) = second else {
            return XCTFail("expected two transcript segments")
        }
        XCTAssertEqual(firstID, secondID)
        XCTAssertEqual(text, "Looking now.")
        XCTAssertTrue(final)
    }

    func testAnUnknownRoleReadsAsTheAssistant() {
        let event = MistralLiveProtocol.decode("""
        {"type":"transcription.segment","id":"seg-4","content":"hello","final":true}
        """)
        XCTAssertEqual(event, .transcript(id: "seg-4", role: .assistant, content: "hello", final: true))
    }

    func testAToolCallStartingNamesTheTool() {
        let event = MistralLiveProtocol.decode("""
        {"type":"tool_call.started","id":"call-1","name":"start_job","phase":"started","ts":3}
        """)
        XCTAssertEqual(event, .toolCallStarted(id: "call-1", name: "start_job"))
    }

    func testAToolCallEndingCarriesArgumentsAndResult() {
        let event = MistralLiveProtocol.decode("""
        {"type":"tool_call.ended","id":"call-1","name":"start_job","status":"done",
         "arguments":{"task":"book a table"},"result":"{\\"ok\\":true}","phase":"ended","ts":3.4}
        """)
        guard case .toolCallEnded(let id, let name, let arguments, let result, let status) = event else {
            return XCTFail("expected a tool call end")
        }
        XCTAssertEqual(id, "call-1")
        XCTAssertEqual(name, "start_job")
        XCTAssertEqual(status, "done")
        XCTAssertEqual(result, "{\"ok\":true}")
        XCTAssertEqual(arguments.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["task"] as? String,
                       "book a table")
    }

    func testAToolCallEndingWithoutResultKeepsItNil() {
        let event = MistralLiveProtocol.decode("""
        {"type":"tool_call.ended","id":"call-2","name":"ask","status":"error","arguments":"{}","result":null}
        """)
        XCTAssertEqual(event, .toolCallEnded(id: "call-2", name: "ask", arguments: "{}", result: nil, status: "error"))
    }

    func testTheAgentStateIsRead() {
        XCTAssertEqual(MistralLiveProtocol.decode("""
        {"type":"agent.state.changed","old_state":"listening","state":"speaking","ts":9}
        """), .agentState("speaking"))
    }

    func testAFatalErrorKeepsItsMessageAndCode() {
        XCTAssertEqual(MistralLiveProtocol.decode("""
        {"type":"error","message":"no session","fatal":true,"code":"session_closed","source":"agent"}
        """), .error(message: "no session", fatal: true, code: "session_closed"))
    }

    func testAnEventThisBuildDoesNotReadIsKeptByType() {
        XCTAssertEqual(MistralLiveProtocol.decode("""
        {"type":"usage.report","tokens":12}
        """), .unknown(type: "usage.report"))
    }

    func testSomethingThatIsNotJSONIsIgnored() {
        XCTAssertNil(MistralLiveProtocol.decode("not json"))
        XCTAssertNil(MistralLiveProtocol.decode(#"{"no":"type"}"#))
    }

    // MARK: - Function calls

    func testAFunctionCallWithObjectArgumentsNormalizesToJSONText() {
        let data = Data("""
        {"name":"start_job","arguments":{"task":"book a table","quiet":true}}
        """.utf8)
        let call = MistralLiveProtocol.functionCall(from: data)
        XCTAssertEqual(call?.name, "start_job")
        let object = call.flatMap { $0.arguments.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(object?["task"] as? String, "book a table")
    }

    func testAFunctionCallWithArgumentsAlreadyEncodedKeepsThem() {
        let data = Data("""
        {"name":"read_back","arguments":"{\\"turn\\":3}"}
        """.utf8)
        XCTAssertEqual(MistralLiveProtocol.functionCall(from: data)?.arguments, "{\"turn\":3}")
    }

    func testAFunctionCallWithNoArgumentsAnswersWithAnEmptyObject() {
        let data = Data(#"{"name":"list_jobs"}"#.utf8)
        XCTAssertEqual(MistralLiveProtocol.functionCall(from: data)?.arguments, "{}")
    }

    func testAFunctionCallWithoutANameIsIgnored() {
        XCTAssertNil(MistralLiveProtocol.functionCall(from: Data(#"{"arguments":{}}"#.utf8)))
        XCTAssertNil(MistralLiveProtocol.functionCall(from: Data("nonsense".utf8)))
    }

    func testAToolResultIsJSONTheAgentCanRead() {
        let text = MistralLiveProtocol.result(["ok": true, "job_id": "j-1"])
        let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        XCTAssertEqual(object?["ok"] as? Bool, true)
        XCTAssertEqual(object?["job_id"] as? String, "j-1")
    }

    func testAFailureNamesWhatWentWrong() {
        let text = MistralLiveProtocol.failure("Hermes is not connected")
        let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        XCTAssertEqual(object?["ok"] as? Bool, false)
        XCTAssertEqual(object?["error"] as? String, "Hermes is not connected")
    }

    // MARK: - Session

    func testTheHostsSessionAnswerNamesTheRoomAndToken() {
        let answer = MistralLiveProtocol.SessionAnswer.parse([
            "session_id": "01a1",
            "server_url": "wss://livekit.mistral.ai",
            "participant_token": "eyJhbG",
            "expires_at": "2026-11-04T20:18:03Z",
            "voice_id": "voice_447",
        ])
        XCTAssertEqual(answer?.sessionID, "01a1")
        XCTAssertEqual(answer?.serverURL, "wss://livekit.mistral.ai")
        XCTAssertEqual(answer?.participantToken, "eyJhbG")
        XCTAssertEqual(answer?.voiceID, "voice_447")
        XCTAssertNotNil(answer?.expiresAt)
    }

    func testAnAnswerMissingTheTokenIsRefused() {
        XCTAssertNil(MistralLiveProtocol.SessionAnswer.parse([
            "session_id": "01a1", "server_url": "wss://livekit.mistral.ai",
        ]))
    }

    func testAnAnswerThatIsNotSecureIsRefused() {
        XCTAssertNil(MistralLiveProtocol.SessionAnswer.parse([
            "session_id": "01a1", "server_url": "ws://livekit.mistral.ai", "participant_token": "t",
        ]))
    }

    func testASavedAgentsRequestCarriesOnlyWhatWasChosen() {
        var request = MistralLiveProtocol.SessionRequest(agentID: "agent-1", agentVersion: 3)
        request.profile = "default"
        XCTAssertEqual(request.payload["agent_id"] as? String, "agent-1")
        XCTAssertEqual(request.payload["agent_version"] as? Int, 3)
        XCTAssertEqual(request.payload["profile"] as? String, "default")
        XCTAssertNil(request.payload["voice_id"])
        XCTAssertNil(request.payload["instructions"])
    }

    func testAnInlineRequestCarriesItsConfiguration() {
        let request = MistralLiveProtocol.SessionRequest(
            instructions: "You are the voice of Hermes.",
            welcomeMessage: "Hi, I'm listening.",
            voiceID: "voice_447",
            llmModel: MistralLiveProtocol.defaultLLMModel
        )
        XCTAssertEqual(request.payload["instructions"] as? String, "You are the voice of Hermes.")
        XCTAssertEqual(request.payload["welcome_message"] as? String, "Hi, I'm listening.")
        XCTAssertEqual(request.payload["llm_model"] as? String, "mistral-small-latest")
        XCTAssertNil(request.payload["agent_id"])
    }
}
