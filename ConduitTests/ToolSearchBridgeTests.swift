import Foundation
import XCTest
@testable import Conduit

/// A tool deferred behind Hermes' Tool Search is saved as a `tool_call`
/// wrapper call whose result names the real tool (#1090). Kept in an
/// extension so the test planner gets no new class.
extension MessageNormalizerTests {
    private static let mapAnswer = #"{"ok": true, "cards": [{"type": "map", "places": [{"name": "Kin Khao", "lat": 37.78, "lon": -122.4}]}]}"#

    private func wrapperCall(id: String, arguments: String) -> AnyCodable {
        .object([
            "id": .number(1), "role": .string("assistant"), "content": .string(""),
            "tool_calls": .array([.object([
                "id": .string(id),
                "function": .object(["name": .string("tool_call"), "arguments": .string(arguments)])
            ])])
        ])
    }

    private func result(callID: String, toolName: String, content: String) -> AnyCodable {
        .object([
            "id": .number(2), "role": .string("tool"),
            "tool_call_id": .string(callID), "tool_name": .string(toolName),
            "content": .string(content)
        ])
    }

    func testDeferredShowCallShowsTheToolItRanAndItsCards() {
        let envelope = #"{"calls":[{"name":"conduit_show","arguments":{"title":"Dinner"}}]}"#
        let rows = [
            wrapperCall(id: "call-show", arguments: envelope),
            result(callID: "call-show", toolName: "conduit_show", content: Self.mapAnswer)
        ]
        let tools = MessageNormalizer.normalizeMessages(rows).compactMap(\.tool)

        XCTAssertEqual(tools.count, 1)
        guard let tool = tools.first else { return }
        XCTAssertEqual(tool.name, "conduit_show")
        XCTAssertEqual(tool.input, #"{"title":"Dinner"}"#, "the tool's own arguments, as live events show them")
        XCTAssertEqual(tool.output, Self.mapAnswer)
        XCTAssertEqual(RichCard.cards(for: tool).map(\.kind), [.map])
        // Only the display changes: the saved call keeps the wrapper.
        XCTAssertEqual(rows[0].objectValue?["tool_calls"]?.arrayValue?.first?
            .objectValue?["function"]?.objectValue?["name"]?.stringValue, "tool_call")
    }

    func testDeferredShowCardsFallBackToTheToolsOwnArguments() {
        let envelope = #"{"calls":[{"name":"conduit_show","arguments":"{\"cards\":[{\"type\":\"place\",\"places\":[{\"name\":\"Tartine\"}]}]}"}]}"#
        let tools = MessageNormalizer.normalizeMessages([
            wrapperCall(id: "call-show", arguments: envelope),
            result(callID: "call-show", toolName: "conduit_show", content: #"{"ok": true, "id": "c1"}"#)
        ]).compactMap(\.tool)

        XCTAssertEqual(tools.first.map { RichCard.cards(for: $0).flatMap(\.places).map(\.name) }, ["Tartine"])
    }

    func testWrapperTakesItsResultsNameWhenTheEnvelopeDoesNotSay() {
        let tools = MessageNormalizer.normalizeMessages([
            wrapperCall(id: "call-show", arguments: "{}"),
            result(callID: "call-show", toolName: "conduit_show", content: Self.mapAnswer)
        ]).compactMap(\.tool)

        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?.name, "conduit_show")
        XCTAssertEqual(tools.first?.input, "{}")
        XCTAssertEqual(tools.first.map { RichCard.cards(for: $0).map(\.kind) }, [.map])
    }

    func testWrapperOnlyTakesTheNameOfAResultWithItsOwnCallID() {
        let tools = MessageNormalizer.normalizeMessages([
            wrapperCall(id: "call-show", arguments: "{}"),
            result(callID: "call-other", toolName: "conduit_show", content: Self.mapAnswer)
        ]).compactMap(\.tool)

        XCTAssertEqual(tools.map(\.name), ["tool_call", "conduit_show"])
        XCTAssertNil(tools.first?.output)
        XCTAssertTrue(tools.first.map { RichCard.cards(for: $0).isEmpty } ?? false)
    }

    func testWrapperKeepsItsNameForABridgeNamedResult() {
        // A connector batch, or a call Hermes refused, keeps the wrapper.
        let envelope = #"{"calls":[{"name":"connectors__mail__send","arguments":{}},{"name":"connectors__mail__list","arguments":{}}]}"#
        let tools = MessageNormalizer.normalizeMessages([
            wrapperCall(id: "call-batch", arguments: envelope),
            result(callID: "call-batch", toolName: "tool_call", content: #"{"results": []}"#)
        ]).compactMap(\.tool)

        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?.name, "tool_call")
        XCTAssertEqual(tools.first?.input, envelope)
    }

    func testDirectToolIsNotRenamedByItsResult() {
        let tools = MessageNormalizer.normalizeMessages([
            .object([
                "id": .number(1), "role": .string("assistant"), "content": .string(""),
                "tool_calls": .array([.object([
                    "id": .string("call-1"),
                    "function": .object(["name": .string("web_search"), "arguments": .string(#"{"query":"x"}"#)])
                ])])
            ]),
            result(callID: "call-1", toolName: "conduit_show", content: Self.mapAnswer)
        ]).compactMap(\.tool)

        XCTAssertEqual(tools.map(\.name), ["web_search"])
    }

    func testCompactResumeRowShowsTheDeferredTool() {
        let messages = MessageNormalizer.normalizeMessages([
            .object([
                "role": .string("tool"),
                "name": .string("tool_call"),
                "tool_call_id": .string("call-show"),
                "context": .string("conduit_show"),
                "args": .object(["calls": .array([.object([
                    "name": .string("conduit_show"),
                    "arguments": .object(["title": .string("Dinner")])
                ])])])
            ])
        ])

        XCTAssertEqual(messages.first?.tool?.name, "conduit_show")
        XCTAssertEqual(messages.first?.tool?.input, "conduit_show")
    }

    func testToolSearchBridgeResolvesOnlyASingleConcreteTool() {
        XCTAssertEqual(ToolSearchBridge.underlyingCall(#"{"name":"conduit_maps","arguments":{"q":"cafe"}}"#),
                       ToolSearchBridge.Call(name: "conduit_maps", arguments: #"{"q":"cafe"}"#), "the legacy single shape")
        XCTAssertEqual(ToolSearchBridge.underlyingCall(#"{"calls":"[{\"name\":\"conduit_health\"}]"}"#),
                       ToolSearchBridge.Call(name: "conduit_health", arguments: nil), "calls sent as a JSON string")
        XCTAssertNil(ToolSearchBridge.underlyingCall(#"{"calls":[{"name":"a"},{"name":"b"}]}"#), "a batch")
        XCTAssertNil(ToolSearchBridge.underlyingCall(#"{"calls":[{"name":"tool_search"}]}"#), "a bridge tool")
        XCTAssertNil(ToolSearchBridge.underlyingCall(#"{"calls":[{"name":"connectors__mail__send"}]}"#))
        XCTAssertNil(ToolSearchBridge.underlyingCall(#"{"calls":[]}"#))
        XCTAssertNil(ToolSearchBridge.underlyingCall("not json"))
        XCTAssertNil(ToolSearchBridge.underlyingCall(#"{"calls":[{"name":"conduit_show","arguments":"not json"}]}"#),
                     "arguments Hermes refuses keep the wrapper")
        XCTAssertNil(ToolSearchBridge.underlyingCall(#"{"calls":[{"name":"conduit_show","arguments":[1]}]}"#))
        XCTAssertTrue(ToolSearchBridge.isWrapper(" Tool_Call "))
        XCTAssertFalse(ToolSearchBridge.isConcrete("tool_describe"))
        XCTAssertFalse(ToolSearchBridge.isConcrete("  "))
        XCTAssertFalse(ToolSearchBridge.isConcrete("Connectors__mail__send"), "a connector runs in a batch")
    }

    func testLiveToolEventNamesTheDeferredTool() {
        let envelope: [String: Any] = ["calls": [["name": "conduit_show", "arguments": ["title": "Dinner"]]]]
        let start = StreamEventParser.parse(params: AnyCodable.from([
            "type": "tool.start", "session_id": "s1",
            "payload": ["name": "tool_call", "tool_id": "call-show", "args": envelope] as [String: Any]
        ]))
        guard case .toolStart(_, let started, _, _) = start else { return XCTFail("Expected toolStart") }
        XCTAssertEqual(started, "conduit_show")

        let complete = StreamEventParser.parse(params: AnyCodable.from([
            "type": "tool.complete", "session_id": "s1",
            "payload": ["name": "web_search", "tool_id": "call-1", "args": envelope] as [String: Any]
        ]))
        guard case .toolComplete(_, let completed, _, _) = complete else { return XCTFail("Expected toolComplete") }
        XCTAssertEqual(completed, "web_search", "only the wrapper is resolved")
    }
}
