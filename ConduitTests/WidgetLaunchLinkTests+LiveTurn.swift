import XCTest
@testable import Conduit

private typealias State = HermesTurnAttributes.ContentState
private let now = Date(timeIntervalSince1970: 1_800_000_000)

/// How a chat's stream moves a running turn's Lock Screen state (#605).
/// An extension of an existing class, so the CI planner's lanes stay within
/// their batch budget.
extension WidgetLaunchLinkTests {
    func testLiveTurnToolsCountAndShowOnlyTheirCategory() throws {
        var state = State(phase: .thinking)
        state = try XCTUnwrap(LiveTurnProgress.applying(.toolStart(sessionId: "s", toolName: "terminal", toolInput: "rm -rf build"), to: state))
        XCTAssertEqual(state.turnPhase, .tool)
        XCTAssertEqual(state.toolCategory, .terminal)
        XCTAssertEqual(state.tools, 1)
        state = try XCTUnwrap(LiveTurnProgress.applying(.toolStart(sessionId: "s", toolName: "mcp_github_create_issue", toolInput: nil), to: state))
        XCTAssertEqual(state.toolCategory, .connector)
        XCTAssertEqual(state.tools, 2)
        state = try XCTUnwrap(LiveTurnProgress.applying(.toolComplete(sessionId: "s", toolName: "mcp_github_create_issue", toolOutput: "ok"), to: state))
        XCTAssertEqual(state.turnPhase, .thinking)
        XCTAssertNil(state.tool)
        XCTAssertEqual(state.tools, 2)
    }

    func testLiveTurnClarifyWaitsOnTheUserWithoutCountingATool() throws {
        let state = try XCTUnwrap(LiveTurnProgress.applying(.toolStart(sessionId: "s", toolName: "clarify", toolInput: nil), to: State(phase: .thinking)))
        XCTAssertEqual(state.turnPhase, .input)
        XCTAssertEqual(state.tools, 0)
    }

    func testLiveTurnRepeatedDeltasChangeNothing() throws {
        let writing = try XCTUnwrap(LiveTurnProgress.applying(.messageDelta(sessionId: "s", text: "Hel"), to: State(phase: .thinking)))
        XCTAssertEqual(writing.turnPhase, .writing)
        XCTAssertNil(LiveTurnProgress.applying(.messageDelta(sessionId: "s", text: "lo"), to: writing))
    }

    func testLiveTurnContextIsAWholeBoundedPercent() throws {
        let state = try XCTUnwrap(LiveTurnProgress.applying(.contextUpdate(sessionId: "s", percent: 41.6, used: 41_600, max: 100_000), to: State(phase: .thinking)))
        XCTAssertEqual(state.context, 42)
        let capped = try XCTUnwrap(LiveTurnProgress.applying(.contextUpdate(sessionId: "s", percent: 130, used: 1, max: 1), to: state))
        XCTAssertEqual(capped.context, 100)
        let huge = try XCTUnwrap(LiveTurnProgress.applying(.contextUpdate(sessionId: "s", percent: 1e20, used: 1, max: 1), to: State(phase: .thinking)))
        XCTAssertEqual(huge.context, 100, "a huge value is clamped, never trapped on")
    }

    func testLiveTurnTheTurnEndsWithItsOutcomeAndTime() throws {
        let running = State(phase: .tool, tool: .web, tools: 3, context: 20)
        let done = try XCTUnwrap(LiveTurnProgress.applying(.messageComplete(sessionId: "s", messageId: nil, content: "Hi", reasoning: nil), to: running, now: now))
        XCTAssertEqual(done.turnPhase, .done)
        XCTAssertNil(done.tool)
        XCTAssertEqual(done.tools, 3)
        XCTAssertEqual(done.endDate, now)
        XCTAssertEqual(LiveTurnProgress.applying(.messageError(sessionId: "s", message: "boom"), to: running, now: now)?.turnPhase, .failed)
        XCTAssertEqual(LiveTurnProgress.applying(.messageInterrupted(sessionId: "s"), to: running, now: now)?.turnPhase, .stopped)
        XCTAssertEqual(LiveTurnProgress.applying(.sessionBusy(sessionId: "s", busy: false), to: running, now: now)?.turnPhase, .done)
        XCTAssertNil(LiveTurnProgress.applying(.sessionBusy(sessionId: "s", busy: true), to: running, now: now))
    }

    func testLiveTurnAWithdrawnRequestGoesBackToThinkingOnlyWhileWaiting() throws {
        let waiting = State(phase: .approval)
        let resumed = try XCTUnwrap(LiveTurnProgress.applying(.approvalWithdrawn(sessionId: "s", requestId: "r", reason: "resolved"), to: waiting))
        XCTAssertEqual(resumed.turnPhase, .thinking)
        XCTAssertNil(LiveTurnProgress.applying(.approvalWithdrawn(sessionId: "s", requestId: "r", reason: "resolved"), to: State(phase: .tool, tool: .files)))
        XCTAssertNil(LiveTurnProgress.applying(.sessionBusy(sessionId: "s", busy: false), to: waiting), "a pending approval outlasts an idle report")
    }

    func testLiveTurnHeldEventsSkipThePreviousTurnsEnd() {
        let oldEnd = StreamEvent.messageComplete(sessionId: "s", messageId: nil, content: "Old", reasoning: nil)
        let tool = StreamEvent.toolStart(sessionId: "s", toolName: "terminal", toolInput: nil)
        let held = LiveTurnProgress.newTurnEvents([oldEnd, .messageStart(sessionId: "s"), tool])
        XCTAssertEqual(held.count, 2, "only what follows the new turn's start")
        XCTAssertTrue(LiveTurnProgress.newTurnEvents([tool, oldEnd]).isEmpty, "without a start, it's all the turn before")
    }

    /// The relay's push carries this JSON; ActivityKit decodes it into
    /// `ContentState` (relay `liveActivityPush`).
    func testLiveTurnTheRelayContentStateDecodes() throws {
        let json = #"{"phase":"done","tools":2,"context":31,"endedAt":1800000000}"#
        let state = try JSONDecoder().decode(State.self, from: Data(json.utf8))
        XCTAssertEqual(state.turnPhase, .done)
        XCTAssertEqual(state.tools, 2)
        XCTAssertEqual(state.context, 31)
        XCTAssertEqual(state.endDate, now)
        let unknown = try JSONDecoder().decode(State.self, from: Data(#"{"phase":"pondering","tools":0}"#.utf8))
        XCTAssertEqual(unknown.turnPhase, .thinking)
        XCTAssertNil(unknown.toolCategory)
    }

    func testLiveTurnToolCategoriesMatchThePlugin() {
        XCTAssertEqual(HermesToolCategory(toolName: "browser_click"), .browser)
        XCTAssertEqual(HermesToolCategory(toolName: "web_search"), .web)
        XCTAssertEqual(HermesToolCategory(toolName: "conduit_calendar"), .phone)
        XCTAssertEqual(HermesToolCategory(toolName: "delegate_task"), .agents)
        XCTAssertEqual(HermesToolCategory(toolName: "something_private"), .tool)
        XCTAssertEqual(HermesTurnCopy.statusKey(State(phase: .tool, tool: .web)), "Searching the web")
        XCTAssertEqual(HermesTurnCopy.statusKey(State(phase: .done)), "Finished")
    }

    /// The card's profile glow: `#rrggbb` parses, anything else falls back
    /// to gold, and an activity an older build started (no profile keys)
    /// still decodes.
    func testLiveTurnProfileGlowParsesAndOlderAttributesDecode() throws {
        let link = try XCTUnwrap(URL(string: "conduit://session/s"))
        var attributes = HermesTurnAttributes(chatTitle: "Chat", startedAt: now, language: "system", link: link, sessionIDs: ["s"], profileName: "Hermes", glowHex: "#c83a3a")
        let glow = try XCTUnwrap(attributes.glowColor)
        XCTAssertEqual(glow.red, 200.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(glow.green, 58.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(glow.blue, 58.0 / 255, accuracy: 0.0001)
        attributes.glowHex = "#C83A3A\n"
        XCTAssertEqual(try XCTUnwrap(attributes.glowColor).red, 200.0 / 255, accuracy: 0.0001, "uppercase and a trailing newline parse")
        attributes.glowHex = "nope"
        XCTAssertNil(attributes.glowColor)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(attributes)) as? [String: Any])
        object["profileName"] = nil
        object["glowHex"] = nil
        let older = try JSONDecoder().decode(HermesTurnAttributes.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(older.chatTitle, "Chat")
        XCTAssertNil(older.profileName)
        XCTAssertNil(older.glowColor)
    }
}
