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

    /// A turn that ended while Conduit was closed (or in a chat not on
    /// screen, with no relay to end it) may be over once the live registry
    /// shows its chat isn't running, but only on its own dashboard and
    /// profile, and not in the first moments of the turn.
    func testLiveTurnEndsWhenTheRegistryNoLongerRunsItsChat() throws {
        let start = now
        let link = try XCTUnwrap(URL(string: "conduit://session/rt?profile=default"))
        let attributes = HermesTurnAttributes(chatTitle: "Chat", startedAt: start, language: "system", link: link, sessionIDs: ["rt", "stored"], dashboardID: "D1")
        let running = HermesTurnAttributes.ContentState(phase: .thinking)
        func verdict(_ live: Set<String>, profile: String = "default", dashboard: String? = "D1", after seconds: TimeInterval = 120, state: HermesTurnAttributes.ContentState? = nil, attributes a: HermesTurnAttributes? = nil) -> LiveTurnProgress.RegistryVerdict {
            LiveTurnProgress.registryVerdict(attributes: a ?? attributes, state: state ?? running, liveSessionIDs: live, profile: profile, dashboardID: dashboard, now: start.addingTimeInterval(seconds), grace: LiveTurnActivities.registryGrace)
        }
        XCTAssertEqual(verdict([]), .absent, "Its chat isn't running any more")
        XCTAssertEqual(verdict(["other"]), .absent)
        XCTAssertEqual(verdict(["stored"]), .running, "Still running under its stored id")
        XCTAssertEqual(verdict(["rt"], after: 10), .running)
        XCTAssertEqual(verdict([], after: 10), .unknown, "A snapshot right after the prompt can predate the turn")
        XCTAssertEqual(verdict([], profile: "work"), .unknown, "Another profile's snapshot says nothing about it")
        XCTAssertEqual(verdict([], dashboard: "D2"), .unknown, "Another dashboard's snapshot says nothing about it")
        XCTAssertEqual(verdict([], state: LiveTurnProgress.finished(running, .done, now: start)), .unknown, "Already ended")

        var older = attributes
        older.dashboardID = nil
        XCTAssertEqual(verdict([], dashboard: "D2", attributes: older), .absent, "An older build's activity goes by its chat ids")

        let rows = [
            LiveSessionStatus(runtimeSessionId: "a", storedSessionId: "a-stored", status: "working"),
            LiveSessionStatus(runtimeSessionId: "b", storedSessionId: "", status: "waiting"),
            LiveSessionStatus(runtimeSessionId: "c", storedSessionId: "c-stored", status: "starting"),
            LiveSessionStatus(runtimeSessionId: "d", storedSessionId: "d-stored", status: "idle"),
        ]
        XCTAssertEqual(AppState.liveTurnSessionIDs(rows), ["a", "a-stored", "b", "c", "c-stored"], "Idle sessions have no turn")

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(attributes)) as? [String: Any])
        object["dashboardID"] = nil
        XCTAssertNil(try JSONDecoder().decode(HermesTurnAttributes.self, from: JSONSerialization.data(withJSONObject: object)).dashboardID, "An older build's activity decodes")
    }

    /// One snapshot without the chat (a gateway restarting can serve an
    /// empty registry) doesn't end the turn: the absence has to last from
    /// one snapshot to another `registryAbsenceSpan` later, with none in
    /// between that runs it.
    func testLiveTurnEndsOnlyWhenItsChatStaysOutOfTheRegistry() {
        let span = LiveTurnActivities.registryAbsenceSpan
        func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

        var absences = LiveTurnProgress.RegistryAbsences()
        XCTAssertEqual(absences.record(.absent, for: "a", at: at(0), span: span), .started, "Absent once: still running, a recheck is due")
        XCTAssertEqual(absences.record(.absent, for: "a", at: at(span), span: span), .over, "Absent twice: over")

        absences = LiveTurnProgress.RegistryAbsences()
        XCTAssertEqual(absences.record(.absent, for: "a", at: at(0), span: span), .started)
        XCTAssertEqual(absences.record(.running, for: "a", at: at(4), span: span), .none)
        XCTAssertEqual(absences.record(.absent, for: "a", at: at(span), span: span), .started, "Absent, running, absent: still running")
        XCTAssertEqual(absences.record(.absent, for: "a", at: at(2 * span), span: span), .over)

        absences = LiveTurnProgress.RegistryAbsences()
        XCTAssertEqual(absences.record(.absent, for: "a", at: at(0), span: span), .started)
        XCTAssertEqual(absences.record(.absent, for: "a", at: at(1), span: span), .none, "Reads at the same moment count once")
        XCTAssertEqual(absences.record(.unknown, for: "a", at: at(4), span: span), .none)
        XCTAssertEqual(absences.record(.absent, for: "a", at: at(span), span: span), .over, "Another profile's snapshot in between changes nothing")
        XCTAssertEqual(absences.record(.absent, for: "b", at: at(span), span: span), .started, "Counted per activity")

        absences.forget("b")
        XCTAssertEqual(absences.record(.absent, for: "b", at: at(3 * span), span: span), .started, "An ended activity's absence is gone")

        absences = LiveTurnProgress.RegistryAbsences()
        let long = span * LiveTurnProgress.RegistryAbsences.staleSpans + 1
        XCTAssertEqual(absences.record(.absent, for: "a", at: at(0), span: span), .started)
        XCTAssertEqual(absences.record(.absent, for: "a", at: at(long), span: span), .started, "An absence seen long ago starts over")
        XCTAssertEqual(absences.record(.absent, for: "a", at: at(long + span), span: span), .over)
    }

    /// Which turns ending a dashboard's activities ends: its own and an
    /// older build's, except, when asked, those whose token the relay
    /// installation still in use took.
    func testEndingADashboardsTurnsKeepsOnlyThoseTheRelayCanEnd() {
        func ends(_ own: String?, token: String?, keeping: Bool, current: String? = "I1") -> Bool {
            LiveTurnActivities.endsTurn(activityDashboardID: own, tokenInstallationID: token, ofDashboard: "D1", keepingThoseOnRelay: keeping, currentInstallationID: current)
        }
        XCTAssertTrue(ends("D1", token: nil, keeping: false))
        XCTAssertTrue(ends("D1", token: "I1", keeping: false), "Disconnect and Sign Out end them all")
        XCTAssertFalse(ends("D2", token: nil, keeping: false), "Another dashboard's stay")
        XCTAssertTrue(ends(nil, token: nil, keeping: false), "An older build's activity names no dashboard")
        XCTAssertFalse(ends("D1", token: "I1", keeping: true), "The plugin still ends it by push")
        XCTAssertTrue(ends("D1", token: nil, keeping: true), "The relay never took its token")
        XCTAssertTrue(ends("D1", token: "I1", keeping: true, current: nil), "Notifications turned off: the installation is gone")
        XCTAssertTrue(ends("D1", token: "I1", keeping: true, current: "I2"), "Moved to another relay: its token isn't there")
        XCTAssertFalse(ends("D2", token: nil, keeping: true))
    }

    /// Only a relay that took a Live Activity token counts as a route the
    /// plugin can end activities through; an error or no answer settles
    /// nothing.
    func testLiveActivityRouteIsConfirmedOnlyByASuccessfulRegistration() {
        XCTAssertEqual(PushNotificationService.liveActivityRouteExists(registrationStatus: 200), true)
        XCTAssertEqual(PushNotificationService.liveActivityRouteExists(registrationStatus: 204), true)
        XCTAssertEqual(PushNotificationService.liveActivityRouteExists(registrationStatus: 404), false)
        XCTAssertNil(PushNotificationService.liveActivityRouteExists(registrationStatus: 500))
        XCTAssertNil(PushNotificationService.liveActivityRouteExists(registrationStatus: 401))
    }
}
