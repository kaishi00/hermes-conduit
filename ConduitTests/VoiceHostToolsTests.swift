//
//  VoiceHostToolsTests.swift
//  ConduitTests
//
//  Live voice calls read the user's shared health data from the host: the
//  voice sealing matches the notifier's vector, the host's tool schema is
//  passed as strings and turned back into JSON types, and Gemini, Grok and
//  GPT-Live calls reach the tool. Written as an extension of an existing
//  suite: the CI test planner is at capacity for new XCTestCase classes.
//

import CryptoKit
import XCTest
@testable import Conduit

@MainActor
extension HermesVoiceGatewayTimeoutTests {
    // The notifier's tests/health_vector.json ("voice"): both sides must agree.
    private static let voiceVectorRequest = #"{"call_id":"call-vector-1","args":{"action":"overview"},"provider":"gemini-live"}"#
    private static let voiceVectorRequestCT = "HOx6f_7ddA8a8iswArmIJZGmkwuvcfCORA-xeOn3bOc75bgMukljmfXlpEnHSm6mVtLV5db9Zkvc8apgFzDIx1szPaRCtamr7X5X1aCMzb-sR0i0EiJzzRGo1xAVs4Ccbw"
    private static let voiceVectorAnswerCT = "iSaeOMxHomD21JmxF3ktQ1HratzeT8PVbQjVxW7Bu_koLR0XzCHdqVA1wCEaVyNh27JAYKvhPykSSTwho94EXA"

    func testVoiceSealingMatchesTheNotifierVector() throws {
        let raw = try XCTUnwrap(NotificationE2E.base64URLDecoded("ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8"))
        let device = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        let key = try HealthSyncCrypto.agree(devicePrivate: device, deviceID: "device-vector-1",
                                             hostPublicKey: "j0DFrbaPJWJK5bIU6nZ6bslNgp09e14a0bpvPiE4KF8",
                                             kid: "568703226d4ca837141b5eebba642b64")
        XCTAssertTrue(key.readsByVoice)
        XCTAssertEqual(key.voiceRequestKey?.map { String(format: "%02x", $0) }.joined(),
                       "def30ad88be29ac33ba6c2ea3542a08f73abdd92fbf7272210f6b2d95a9a4205")
        XCTAssertEqual(key.voiceAnswerKey?.map { String(format: "%02x", $0) }.joined(),
                       "d2f6d5eea2cf4f97734bce7b880abe9dfad9c405de1897a9c6a13aec40fcd8ab")

        let envelope = try HealthSyncCrypto.voiceRequest(
            tool: "conduit_health", plaintext: Data(Self.voiceVectorRequest.utf8), key: key,
            deviceID: "device-vector-1", callID: "call-vector-1", nonce: try ChaChaPoly.Nonce(data: Data(count: 12)))
        XCTAssertEqual(envelope["ct"] as? String, Self.voiceVectorRequestCT)
        XCTAssertEqual(envelope["call_id"] as? String, "call-vector-1")
        XCTAssertEqual(envelope["tool"] as? String, "conduit_health")

        let answer = ["nonce": "AAAAAAAAAAAAAAAA", "ct": Self.voiceVectorAnswerCT]
        let result = try HealthSyncCrypto.openVoiceAnswer(answer, key: key, deviceID: "device-vector-1", callID: "call-vector-1")
        XCTAssertEqual((result as? [String: Any])?["ok"] as? Bool, true)
        XCTAssertThrowsError(try HealthSyncCrypto.openVoiceAnswer(answer, key: key, deviceID: "device-vector-1", callID: "call-other"),
                             "An answer is bound to its call")

        // A key saved before voice reads decodes, and reads nothing.
        let old = try JSONDecoder().decode(HealthSyncCrypto.SessionKey.self, from: Data(#"{"kid":"k","key":"AAAA"}"#.utf8))
        XCTAssertFalse(old.readsByVoice)
    }

    func testHostToolSchemaIsPassedAsStringsAndReadBack() throws {
        let tool = try XCTUnwrap(VoiceHostTool.tools(from: Self.healthToolList).first)
        XCTAssertEqual(tool.name, "conduit_health")
        XCTAssertEqual(tool.marker, "Health")

        let declaration = tool.declaration
        XCTAssertEqual(declaration.behavior, .nonBlocking)
        let properties = try XCTUnwrap(declaration.parameters["properties"] as? [String: [String: Any]])
        XCTAssertEqual(properties["action"]?["type"] as? String, "STRING")
        XCTAssertEqual(properties["action"]?["enum"] as? [String], ["overview", "daily", "sleep"])
        XCTAssertEqual(properties["metrics"]?["type"] as? String, "STRING", "A list is passed as words")
        XCTAssertTrue((properties["metrics"]?["description"] as? String ?? "").contains("steps, heart_rate"))
        XCTAssertEqual(declaration.parameters["required"] as? [String], ["action"])

        let arguments = tool.arguments(from: ["action": "daily", "metrics": "steps, heart_rate", "days": "7", "secret": "x"])
        XCTAssertEqual(arguments["action"] as? String, "daily")
        XCTAssertEqual(arguments["metrics"] as? [String], ["steps", "heart_rate"])
        XCTAssertEqual(arguments["days"] as? Int, 7)
        XCTAssertNil(arguments["secret"], "Only the schema's own arguments go to the host")
        XCTAssertEqual(tool.arguments(from: ["days": "7.0"])["days"] as? Int, 7)
        XCTAssertNil(tool.arguments(from: ["days": "7.5"])["days"], "Not a whole number: not sent as a guess")
        XCTAssertEqual(VoiceHostTool.convert("no", to: ["type": "boolean"]) as? Bool, false)
        XCTAssertNil(VoiceHostTool.convert("banana", to: ["type": "boolean"]))

        // An answer too long for a call asks for less rather than cutting the JSON.
        let long = VoiceHostTool.modelResult(["text": String(repeating: "x", count: VoiceHostTool.maximumResultCharacters)])
        XCTAssertNil(long["result"])
        XCTAssertNotNil(long["error"])

        // GPT-Live delegates "Health: {json}" with real JSON types.
        let marked = try XCTUnwrap(VoiceHostTool.marked(in: #"health: {"action": "daily", "metrics": ["steps"]} please"#, tools: [tool]))
        let delegated = marked.tool.arguments(from: marked.arguments)
        XCTAssertEqual(delegated["action"] as? String, "daily")
        XCTAssertEqual(delegated["metrics"] as? [String], ["steps"])
        XCTAssertNil(VoiceHostTool.marked(in: "check my health please", tools: [tool]))
        XCTAssertTrue(VoiceHostTool.gptLiveRules([tool]).contains("Health:"))
    }

    func testLiveCallsReachTheHostToolOnlyWhenOffered() async {
        let supervisor = VoiceBackgroundJobSupervisor(backend: FakeVoiceJobBackend().backend, pollInterval: .seconds(3_600))
        var calls: [(String, [String: Any])] = []
        supervisor.runHostTool = { tool, arguments in
            calls.append((tool.name, arguments))
            return VoiceHostTool.modelResult(["ok": true, "nights": [["asleep": 431]]])
        }
        let gemini = GeminiLiveToolBridge(supervisor: supervisor)
        let call = GeminiLiveProtocol.FunctionCall(id: "c1", name: "conduit_health", arguments: ["action": "sleep"])

        // Not offered on this call (the user didn't allow it): not a tool at all.
        _ = await gemini.handle(call)
        XCTAssertTrue(calls.isEmpty)

        supervisor.hostTools = VoiceHostTool.tools(from: Self.healthToolList)
        let answered = await gemini.handle(call)
        guard case .toolResponse(let id, let name, let result, let scheduling)? = answered.first else {
            return XCTFail("\(answered)")
        }
        XCTAssertEqual(id, "c1")
        XCTAssertEqual(name, "conduit_health")
        XCTAssertEqual(scheduling, .whenIdle)
        XCTAssertTrue(result["result"]?.contains("431") == true)
        XCTAssertEqual(calls.first?.1["action"] as? String, "sleep")

        let gpt = GPTLiveDelegationBridge(supervisor: supervisor)
        let reply = await gpt.handleDelegation(id: "d1", request: #"Health: {"action": "overview"}"#)
        guard case .delegationReply(let delegation, let text, let channel)? = reply.first else {
            return XCTFail("\(reply)")
        }
        XCTAssertEqual(delegation, "d1")
        XCTAssertEqual(channel, .commentary)
        XCTAssertTrue(text.contains("431"))
        XCTAssertEqual(calls.last?.1["action"] as? String, "overview")
        XCTAssertEqual(calls.count, 2, "Read by Conduit, not started as a Hermes job")
    }

    func testVoiceReadConsentIsPerModeAndOnlyWhileSharing() {
        var preferences = HealthSyncPreferences()
        preferences.setVoiceRead(.geminiLive, allowed: true)
        XCTAssertFalse(preferences.letsVoiceRead(.geminiLive), "Nothing reads while sharing is off")
        preferences.destination = HealthSyncDestination(dashboardID: UUID(), profile: "default", host: "hermes.local")
        preferences.categories = [.sleep]
        XCTAssertTrue(preferences.letsVoiceRead(.geminiLive))
        XCTAssertFalse(preferences.letsVoiceRead(.gptLive), "Each company is its own yes")
        preferences.setVoiceRead(.geminiLive, allowed: false)
        XCTAssertNil(preferences.voiceReaders)

        // Preferences saved before voice reads still decode.
        let old = #"{"categories":["sleep"],"detailed":[],"history":"days30"}"#
        XCTAssertNotNil(try? JSONDecoder().decode(HealthSyncPreferences.self, from: Data(old.utf8)))
    }

    private static let healthToolList: [String: Any] = [
        "ok": true,
        "tools": [[
            "name": "conduit_health",
            "key": "health",
            "description": "Read the user's Apple Health data.",
            "parameters": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["overview", "daily", "sleep"]],
                    "metrics": ["type": "array", "items": ["type": "string", "enum": ["steps", "heart_rate"]]],
                    "days": ["type": "integer"],
                ],
                "required": ["action"],
            ],
        ]],
    ]
}
