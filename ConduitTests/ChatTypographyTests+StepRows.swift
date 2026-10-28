import XCTest
@testable import Conduit

/// The V2 thinking and tool rows: what a step is called, what it was about,
/// and which tool the working line names.
extension ChatTypographyTests {
    func testStepStylesUseTheLiveActivityCategories() {
        XCTAssertEqual(ChatStepStyle(toolName: "web_search").category, .web)
        XCTAssertEqual(ChatStepStyle(toolName: "terminal").category, .terminal)
        XCTAssertEqual(ChatStepStyle(toolName: "browser_navigate").category, .browser)
        XCTAssertEqual(ChatStepStyle(toolName: "something_new").category, .tool)
    }

    func testPhoneToolsKeepOneCategoryButTheirOwnIcons() {
        let calendar = ChatStepStyle(toolName: "conduit_calendar")
        let health = ChatStepStyle(toolName: "conduit_health")
        XCTAssertEqual(calendar.category, .phone)
        XCTAssertEqual(health.category, .phone)
        XCTAssertEqual(calendar.symbol, "calendar")
        XCTAssertEqual(health.symbol, "heart")
        XCTAssertEqual(ChatStepStyle(toolName: "conduit_notify").symbol, "bell")
        XCTAssertEqual(ChatStepStyle(toolName: "conduit_unknown").symbol, "iphone")
    }

    func testEveryCategoryHasRunningAndDoneWords() {
        for category in HermesToolCategory.allCases {
            XCTAssertFalse(HermesTurnCopy.toolKey(category).isEmpty)
            XCTAssertFalse(AppLocalization.string(ChatStepStyle.doneKey(category), language: .source).isEmpty)
        }
    }

    func testStepSubjectPrefersTheSearchCommandOrPage() {
        XCTAssertEqual(ChatStepSubject.line(from: #"{"max_results": "5", "query": "dinner downtown"}"#), "dinner downtown")
        XCTAssertEqual(ChatStepSubject.line(from: #"{"command": "git status\nls"}"#), "git status ls")
        XCTAssertEqual(ChatStepSubject.line(from: #"{"zeta": "last", "alpha": "first"}"#), "first")
        XCTAssertEqual(ChatStepSubject.line(from: #"{"agent": "atlas", "message": "the brief is in"}"#), "the brief is in")
        XCTAssertEqual(ChatStepSubject.line(from: "plain text\nsecond line"), "plain text second line")
        XCTAssertNil(ChatStepSubject.line(from: "   "))
        XCTAssertNil(ChatStepSubject.line(from: #"{"count": 3}"#))
        XCTAssertNil(ChatStepSubject.line(from: nil))
        // A huge input isn't parsed: its start is shown as one line.
        let huge = #"{"query": "x", "blob": ""# + String(repeating: "a", count: ChatStepSubject.parseLimit) + #""}"#
        XCTAssertEqual(ChatStepSubject.line(from: huge)?.hasPrefix(#"{"query""#), true)
        XCTAssertLessThanOrEqual(ChatStepSubject.line(from: huge)?.count ?? 0, 200)
    }

    @MainActor
    func testWorkingLineNamesOnlyTheTurnsRunningTool() {
        func tool(_ id: String, _ name: String, _ status: ToolActivity.Status) -> ChatMessage {
            ChatMessage(
                id: id, role: .tool, content: "", timestamp: "now",
                tool: ToolActivity(id: id, name: name, input: nil, output: nil, status: status)
            )
        }
        let user = ChatMessage(id: "u", role: .user, content: "Hi", timestamp: "now")
        let earlier = tool("t0", "terminal", .running)

        XCTAssertEqual(
            ChatView.runningToolName(in: [user, tool("t1", "web_search", .complete), tool("t2", "conduit_calendar", .running)]),
            "conduit_calendar"
        )
        XCTAssertNil(ChatView.runningToolName(in: [user, tool("t1", "web_search", .complete)]))
        // A stuck row from an earlier turn isn't this turn's step.
        XCTAssertNil(ChatView.runningToolName(in: [earlier, user]))
    }

    func testStepSubjectFallsBackToOutputWhenInputIsEmpty() {
        let tool = ToolActivity(id: "t", name: "terminal", input: "", output: "done\nmore", status: .complete)
        XCTAssertEqual(
            ChatStepSubject.line(from: tool.input) ?? ChatStepSubject.line(from: tool.output),
            "done more"
        )
    }

    @MainActor
    func testSteerDoesNotStartANewTurn() {
        let user = ChatMessage(id: "u", role: .user, content: "Hi", timestamp: "2026-10-16T09:00:00Z")
        let running = ChatMessage(
            id: "t1", role: .tool, content: "", timestamp: "now",
            tool: ToolActivity(id: "t1", name: "web_search", input: nil, output: nil, status: .running)
        )
        let steer = ChatMessage(
            id: "s", role: .user, content: "Also lunch", timestamp: "2026-10-16T09:00:30Z",
            displayKind: ChatMessage.steerDisplayKind
        )
        XCTAssertEqual(ChatView.runningToolName(in: [user, running, steer]), "web_search")
        XCTAssertEqual(
            ChatView.turnStart(in: [user, running, steer]),
            MessageTimestampFormatter.date(from: "2026-10-16T09:00:00Z")
        )
    }

    func testRunsOfStepsArePlacedTogether() {
        func step(_ id: String, _ status: ToolActivity.Status = .complete) -> ChatMessage {
            ChatMessage(
                id: id, role: .tool, content: "", timestamp: "now",
                tool: ToolActivity(id: id, name: "web_search", input: nil, output: nil, status: status)
            )
        }
        let user = ChatMessage(id: "u", role: .user, content: "Hi", timestamp: "now")
        let thinking = ChatMessage(id: "r", role: .reasoning, content: "Look it up", timestamp: "now")
        let answer = ChatMessage(id: "a", role: .assistant, content: "Done", timestamp: "now")
        let clarify = ChatMessage(
            id: "c", role: .tool, content: "", timestamp: "now",
            tool: ToolActivity(id: "c", name: "clarify", input: nil, output: nil, status: .complete)
        )

        var cache = ChatMessageScrollTargetCache()
        cache.update(for: [user, thinking, step("t1"), clarify, step("t2"), answer])
        let placed = cache.targets.map { $0.step?.index }
        XCTAssertEqual(placed, [nil, 0, 1, nil, 0, nil])
        XCTAssertEqual(cache.targets[1].step?.group.members.map(\.messageID), ["r", "t1"])
        XCTAssertEqual(cache.targets[1].step?.group.isTrailing, false)

        // A live turn: the run is at the end and grows as steps arrive.
        cache.update(for: [user, thinking, step("t1", .running)])
        XCTAssertEqual(cache.targets[1].step?.group.isTrailing, true)
        XCTAssertEqual(cache.targets[2].step?.group.members.last?.running, true)
        cache.update(for: [user, thinking, step("t1"), step("t2", .running)])
        XCTAssertEqual(cache.targets[1].step?.group.members.count, 3)
        XCTAssertEqual(cache.targets[1].step?.group.members[1].running, false)
        cache.update(for: [user, thinking, step("t1"), step("t2"), answer])
        XCTAssertEqual(cache.targets[1].step?.group.isTrailing, false)
        XCTAssertNil(cache.targets[4].step)
    }

    /// A reply knows the run right above it when that run has thinking,
    /// so its ⋯ can offer Show thinking while Settings hides it.
    func testAReplyKnowsTheThinkingAboveIt() {
        let user = ChatMessage(id: "u", role: .user, content: "Hi", timestamp: "now")
        let thinking = ChatMessage(id: "r", role: .reasoning, content: "Look it up", timestamp: "now")
        let search = ChatMessage(
            id: "t", role: .tool, content: "", timestamp: "now",
            tool: ToolActivity(id: "t", name: "web_search", input: nil, output: nil, status: .complete)
        )
        let answer = ChatMessage(id: "a", role: .assistant, content: "Done", timestamp: "now")
        let later = ChatMessage(id: "u2", role: .user, content: "Thanks", timestamp: "now")

        var cache = ChatMessageScrollTargetCache()
        cache.update(for: [user, thinking, search, answer, later])
        XCTAssertEqual(cache.targets[3].stepsAbove?.members.map(\.messageID), ["r", "t"])
        XCTAssertEqual(cache.targets.map { $0.stepsAbove != nil }, [false, false, false, true, false])

        // Tools alone: nothing to show.
        cache.update(for: [user, search, answer])
        XCTAssertNil(cache.targets[2].stepsAbove)

        // A live turn's reply landing after its run picks the run up.
        cache.update(for: [user, thinking])
        cache.update(for: [user, thinking, answer])
        XCTAssertEqual(cache.targets[2].stepsAbove?.id, "r")
    }

    func testStepTimesReadAsShortDurations() {
        XCTAssertNil(ChatStepTiming.text(nil))
        XCTAssertNil(ChatStepTiming.text(0.4))
        XCTAssertEqual(ChatStepTiming.text(12.2)?.contains("12"), true)
        XCTAssertNil(ChatStepTiming.spokenText(0.4))
        XCTAssertNotEqual(ChatStepTiming.spokenText(12), ChatStepTiming.text(12))
        XCTAssertEqual(
            ChatStepTiming.elapsed(from: "2026-10-16T09:00:00Z", to: "2026-10-16T09:00:05Z"),
            5
        )
        XCTAssertNil(ChatStepTiming.elapsed(from: "2026-10-16T09:00:05Z", to: "2026-10-16T09:00:00Z"))
        XCTAssertNil(ChatStepTiming.elapsed(from: "now", to: Date()))

        func member(_ id: String, _ timestamp: String, _ duration: TimeInterval?) -> ChatStepGroupMember {
            var message = ChatMessage(
                id: id, role: .tool, content: "", timestamp: timestamp,
                tool: ToolActivity(id: id, name: "terminal", input: nil, output: nil, status: .complete)
            )
            message.tool?.duration = duration
            return ChatStepGroupMember(message)
        }
        // From the first start to the last end.
        XCTAssertEqual(
            ChatStepTiming.span(of: [
                member("a", "2026-10-16T09:00:00Z", 2),
                member("b", "2026-10-16T09:00:03Z", 9),
            ]),
            12
        )
        XCTAssertNil(ChatStepTiming.span(of: [member("a", "now", 2)]))
    }

    func testHistoryTimesAToolCallFromItsRows() {
        func call(_ id: Double, _ callID: String, at timestamp: Double) -> AnyCodable {
            .object([
                "id": .number(id),
                "role": .string("assistant"),
                "content": .string(""),
                "timestamp": .number(timestamp),
                "tool_calls": .array([
                    .object([
                        "id": .string(callID),
                        "function": .object([
                            "name": .string("terminal"),
                            "arguments": .string("{\"command\":\"ls\"}"),
                        ]),
                    ]),
                ]),
            ])
        }
        func result(_ id: Double, _ callID: String, at timestamp: Double, extra: [String: AnyCodable] = [:]) -> AnyCodable {
            var row: [String: AnyCodable] = [
                "id": .number(id),
                "role": .string("tool"),
                "tool_call_id": .string(callID),
                "tool_name": .string("terminal"),
                "content": .string("ok"),
                "timestamp": .number(timestamp),
            ]
            row.merge(extra) { _, new in new }
            return .object(row)
        }
        let messages = MessageNormalizer.normalizeMessages([
            call(1, "call-1", at: 1_760_000_000),
            result(2, "call-1", at: 1_760_000_007),
            call(3, "call-2", at: 1_760_000_010),
            // Hermes' own timing wins over the row times.
            result(4, "call-2", at: 1_760_000_010, extra: ["duration_ms": .number(2_500)]),
        ])
        let tools = messages.compactMap(\.tool)
        XCTAssertEqual(tools.map(\.duration), [7, 2.5])
    }

    // MARK: - Names from Hermes' tools catalog

    private var stepCatalog: ToolCatalog {
        ToolCatalog(toolsets: [
            CapabilityToolset(name: "web", description: "web_search, web_extract", enabled: true, label: "Web Search & Scraping", tools: ["web_search", "web_extract"]),
            CapabilityToolset(name: "spotify", description: "playback, search", enabled: true, label: "Spotify", tools: ["spotify_play", "spotify_search"]),
            CapabilityToolset(name: "searxng", description: "SearXNG metasearch", enabled: true, label: "🔌 Searxng", tools: ["searxng_search"]),
            // A composite that also lists it: the smaller toolset names it.
            CapabilityToolset(name: "everything", description: nil, enabled: true, label: "Everything", tools: ["searxng_search", "spotify_play", "terminal"]),
        ])
    }

    func testKnownKindsKeepConduitsOwnWords() {
        XCTAssertEqual(ChatStepLabel(toolName: "web_search", catalog: stepCatalog).kind, .category(.web))
        XCTAssertEqual(ChatStepLabel(toolName: "conduit_calendar", catalog: stepCatalog).kind, .category(.phone))
    }

    func testOtherToolsAreNamedByTheirToolset() {
        let spotify = ChatStepLabel(toolName: "spotify_play", catalog: stepCatalog)
        XCTAssertEqual(spotify.kind, .named("Spotify"))
        XCTAssertEqual(spotify.detail, "playback, search")
        let searxng = ChatStepLabel(toolName: "searxng_search", catalog: stepCatalog)
        XCTAssertEqual(searxng.kind, .named("Searxng"))
        XCTAssertEqual(searxng.detail, "SearXNG metasearch")
    }

    func testToolsMissingFromTheCatalogShowTheirOwnNameReadably() {
        XCTAssertEqual(ChatStepLabel(toolName: "crawl4ai_md").kind, .named("Crawl4ai md"))
        XCTAssertEqual(ChatStepLabel(toolName: "  ").kind, .category(.tool))
        XCTAssertEqual(ChatStepLabel(toolName: "").kind, .category(.tool))
    }

    func testMcpAndConnectorToolsNameTheirAppAndAction() {
        let notion = ChatStepLabel(toolName: "mcp__notion__create_page")
        XCTAssertEqual(notion.kind, .named("Notion"))
        XCTAssertEqual(notion.action, "create page")
        let github = ChatStepLabel(toolName: "connectors__github__GITHUB_LIST_ISSUES")
        XCTAssertEqual(github.kind, .named("GitHub"))
        XCTAssertEqual(github.action, "list issues")
        XCTAssertEqual(ChatStepStyle(toolName: "connectors__github__list_issues").symbol, "puzzlepiece.extension")
        // An older single-underscore MCP name keeps the connector words.
        XCTAssertEqual(ChatStepLabel(toolName: "mcp_notion_create_page").kind, .category(.connector))
    }

    func testToolSearchStepsHaveTheirOwnWords() {
        XCTAssertEqual(ChatStepLabel(toolName: "tool_search").kind, .toolSearch)
        XCTAssertEqual(ChatStepLabel(toolName: "tool_describe").kind, .toolDescribe)
        XCTAssertEqual(ChatStepStyle(toolName: "tool_search").symbol, "magnifyingglass")
    }

    func testAWrapperNamesWhatItRan() {
        let one = ChatStepLabel(
            toolName: "tool_call",
            input: #"{"calls": [{"name": "connectors__github__list_issues", "arguments": {}}, {"name": "connectors__github__get_issue"}]}"#
        )
        XCTAssertEqual(one.kind, .named("GitHub"))
        XCTAssertEqual(one.action, "list issues, get issue")
        XCTAssertEqual(ChatStepStyle(toolName: "tool_call").symbol, ChatStepStyle(toolName: "connectors__github__get_issue").symbol)
        let two = ChatStepLabel(
            toolName: "tool_call",
            input: #"{"calls": [{"name": "connectors__github__list_issues"}, {"name": "spotify_play"}]}"#,
            catalog: stepCatalog
        )
        guard case .named(let names) = two.kind else { return XCTFail("\(two.kind)") }
        XCTAssertTrue(names.contains("GitHub") && names.contains("Spotify"), names)
        XCTAssertEqual(two.action, "list issues")
        XCTAssertEqual(ChatStepLabel(toolName: "tool_call", input: "not json").kind, .category(.tool))
    }

    func testTheCatalogDropsAnOlderHermesEmojiAndRoundTrips() throws {
        XCTAssertEqual(CapabilityToolsetOrdering.strippedLabel("🔍 Web Search & Scraping"), "Web Search & Scraping")
        XCTAssertEqual(CapabilityToolsetOrdering.strippedLabel("X (Twitter) Search"), "X (Twitter) Search")
        XCTAssertEqual(CapabilityToolsetOrdering.strippedLabel("元宝 群聊"), "元宝 群聊")
        XCTAssertNil(CapabilityToolsetOrdering.strippedLabel("🔌"))
        XCTAssertNil(CapabilityToolsetOrdering.strippedLabel("  "))

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ToolCatalogTests-\(UUID().uuidString)"))
        stepCatalog.save(key: "d.default", defaults: defaults)
        XCTAssertEqual(ToolCatalog.saved(key: "d.default", defaults: defaults), stepCatalog)
        XCTAssertTrue(ToolCatalog.saved(key: "d.other", defaults: defaults).isEmpty)
    }
}

extension ChatTypographyTests {
    /// Offline from launch the saved chats draw as Settings last said, not
    /// as Hermes' defaults: thinking set to Off stays off.
    @MainActor
    func testTheLastDisplayPreferencesHoldBeforeTheConfigIsRead() throws {
        let defaults = makeScratchDefaults("DisplayPreferencesCacheTests")
        var off = ProfileDisplayPreferences()
        off.showReasoning = false
        off.thinkingOnRequest = false
        off.showToolProgress = false
        defaults.set(["unscoped.default": try JSONEncoder().encode(off)], forKey: "profileDisplayPreferencesByDashboard")
        let state = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        XCTAssertEqual(state.displayPreferences.reasoningMode, .off)
        XCTAssertFalse(state.displayPreferences.showToolProgress)
    }

    /// Unread, Settings > Chat's display rows show the kept settings the
    /// chats follow, not Hermes' defaults.
    @MainActor
    func testChatSettingsShowTheKeptDisplaySettingsUnread() async throws {
        let defaults = makeScratchDefaults("DisplayPreferencesSettingsTests")
        let kept = ProfileDisplayPreferences(
            showReasoning: false, thinkingOnRequest: false, showToolProgress: false,
            expandToolsByDefault: true, showReviews: false
        )
        defaults.set(["unscoped.default": try JSONEncoder().encode(kept)], forKey: "profileDisplayPreferencesByDashboard")
        let state = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults)
        )
        XCTAssertEqual(state.displayPreferences, kept)
        let settings = await state.loadProfileSettings(keys: [
            ReasoningDisplayMode.settingKey, "display.tool_progress", "display.expand_tools",
            "display.memory_notifications", "display.skin",
        ])
        XCTAssertEqual(settings[ReasoningDisplayMode.settingKey], .text("off"))
        XCTAssertEqual(settings["display.tool_progress"], .text("off"))
        XCTAssertEqual(settings["display.expand_tools"], .bool(true))
        XCTAssertEqual(settings["display.memory_notifications"], .text("off"))
        XCTAssertNil(settings["display.skin"])
    }
}
