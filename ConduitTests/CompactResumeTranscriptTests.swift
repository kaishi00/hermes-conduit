import XCTest
@testable import Conduit

/// Regression coverage for issue #106: large sessions resume reliably because
/// the WebSocket transport carries a bounded, explicit `maximumMessageSize`
/// and `session.resume` requests the compact projection (`omit_messages`),
/// hydrating the persisted transcript through the existing dashboard history
/// route. The compatibility fallback (history source unavailable → legacy
/// full-transcript resume) is exercised, and unrelated history failures must
/// surface instead of hiding behind that fallback.
@MainActor
final class CompactResumeTranscriptTests: XCTestCase {

    private enum FixtureError: Error {
        case unusableSuite
    }

    @MainActor
    private final class ResumeCallRecorder {
        private(set) var calls: [(sessionID: String, compact: Bool)] = []
        func record(sessionID: String, compact: Bool) {
            calls.append((sessionID, compact))
        }
    }

    // MARK: - Transcript hydration

    func testCompactResumeHydratesPersistedTranscriptFromHistoryPayload() async throws {
        let recorder = ResumeCallRecorder()
        let active = session("stored-a", alternateIDs: ["runtime-a"])
        let harness = try makeHarness(
            openSession: { _, sessionID, compact in
                recorder.record(sessionID: sessionID, compact: compact)
                return SessionResumeResult(
                    sessionId: "runtime-a",
                    messages: [],  // compact projection: transcript omitted
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _ in
                // Raw history payload exactly as the dashboard messages
                // endpoint returns it; the production normalizer parses it.
                .payload([
                    "session_id": "stored-a",
                    "messages": [
                        [
                            "id": 1,
                            "role": "user",
                            "content": "Find the transcript.",
                            "timestamp": "2026-09-01T10:00:00Z"
                        ],
                        [
                            "id": 2,
                            "role": "assistant",
                            "content": "",
                            "timestamp": "2026-09-01T10:00:04Z",
                            "tool_calls": [[
                                "id": "call_1",
                                "type": "function",
                                "function": [
                                    "name": "read_file",
                                    "arguments": "{\"path\": \"/tmp/transcript.md\"}"
                                ]
                            ]]
                        ],
                        [
                            "id": 3,
                            "role": "tool",
                            "tool_call_id": "call_1",
                            "content": "file body",
                            "timestamp": "2026-09-01T10:00:05Z"
                        ],
                        [
                            "id": 4,
                            "role": "assistant",
                            "content": "Here it is.",
                            "timestamp": "2026-09-01T10:00:06Z"
                        ]
                    ]
                ])
            }
        )
        harness.appState.sessions = [active]

        let opened = await harness.appState.openSession("stored-a")

        XCTAssertTrue(opened)
        XCTAssertEqual(recorder.calls.map { $0.compact }, [true])

        // The visible conversation is the persisted transcript, parsed by the
        // production normalizer: user row, tool card with input and output,
        // and the final reply — not just array counts.
        XCTAssertEqual(harness.appState.messages.map { $0.role }, [.user, .tool, .assistant])
        XCTAssertEqual(harness.appState.messages[0].content, "Find the transcript.")
        XCTAssertEqual(harness.appState.messages[0].timestamp, "2026-09-01T10:00:00Z")
        XCTAssertEqual(harness.appState.messages[1].tool?.name, "read_file")
        XCTAssertEqual(harness.appState.messages[1].tool?.input, "{\"path\": \"/tmp/transcript.md\"}")
        XCTAssertEqual(harness.appState.messages[1].tool?.output, "file body")
        XCTAssertEqual(harness.appState.messages[2].content, "Here it is.")
        XCTAssertEqual(harness.appState.messages[2].timestamp, "2026-09-01T10:00:06Z")
    }

    // MARK: - Hermes display projection on the reload path

    /// Regression for the transcript-leak finding: the REST history route
    /// returns the physical persisted rows plus display-projection metadata,
    /// and several synthetic row families (model switches, auto-continues,
    /// hidden compaction carriers) ride as `role=user`. The compact-resume
    /// hydration must apply Hermes' display contract so none of them become
    /// human-authored user bubbles after a session reload.
    func testCompactResumeAppliesDisplayProjectionToSyntheticRows() async throws {
        let active = session("stored-a", alternateIDs: ["runtime-a"])
        let modelSwitchMarker = "[System: The active model for this chat has changed to GLM-5.3-Flash via provider zai. From this point forward, use this runtime metadata when answering questions about what model/provider is active.]"
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(
                    sessionId: "runtime-a",
                    messages: [],  // compact projection: transcript omitted
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _ in
                // Raw history payload exactly as the dashboard messages
                // endpoint returns it, including a hidden scaffolding row, an
                // auto-continue pivot, and a display_content compaction
                // carrier alongside the genuine conversation.
                .payload([
                    "session_id": "stored-a",
                    "messages": [
                        [
                            "id": 1,
                            "role": "user",
                            "content": "Ship the release.",
                            "timestamp": "2026-09-01T10:00:00Z"
                        ],
                        [
                            "id": 2,
                            "role": "user",
                            "content": "INTERNAL MODEL SCAFFOLD — do not render",
                            "display_kind": "hidden",
                            "timestamp": "2026-09-01T10:00:01Z"
                        ],
                        [
                            "id": 3,
                            "role": "user",
                            "content": "[System note: Your previous turn was interrupted mid-run. Continuing from the checkpoint.]",
                            "display_kind": "auto_continue",
                            "timestamp": "2026-09-01T10:00:02Z"
                        ],
                        [
                            "id": 4,
                            "role": "user",
                            "content": "Pull the logs before triage.\n\n"
                                + "[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]\n\n"
                                + "[CONTEXT COMPACTION 12:04]\nCompacted prior turns.",
                            "display_content": "Pull the logs before triage.",
                            "timestamp": "2026-09-01T10:00:03Z"
                        ],
                        [
                            "id": 5,
                            "role": "user",
                            "content": modelSwitchMarker,
                            "display_kind": "model_switch",
                            "timestamp": "2026-09-01T10:00:04Z"
                        ],
                        [
                            "id": 6,
                            "role": "assistant",
                            "content": "Shipping it now.",
                            "timestamp": "2026-09-01T10:00:05Z"
                        ]
                    ]
                ])
            }
        )
        harness.appState.sessions = [active]

        let opened = await harness.appState.openSession("stored-a")

        XCTAssertTrue(opened)

        // The genuine conversation survives, the hidden row disappears, the
        // auto-continue and model-switch pivots become timeline events, and
        // the display_content carrier shows its projected ask instead of the
        // physical compaction payload.
        XCTAssertEqual(
            harness.appState.messages.map { $0.role },
            [.user, .system, .user, .system, .assistant]
        )
        XCTAssertEqual(
            harness.appState.messages.map { $0.content },
            [
                "Ship the release.",
                "Resumed interrupted turn",
                "Pull the logs before triage.",
                "[Model has been changed to zai/GLM-5.3-Flash]",
                "Shipping it now."
            ]
        )
        // No synthetic row may end up authored as the human user.
        XCTAssertEqual(
            harness.appState.messages.filter { $0.role == .user }.map { $0.content },
            ["Ship the release.", "Pull the logs before triage."]
        )
        XCTAssertFalse(
            harness.appState.messages.contains { $0.content.contains("INTERNAL MODEL SCAFFOLD") }
                || harness.appState.messages.contains { $0.content.contains("COMPACTION") }
                || harness.appState.messages.contains { $0.content.contains("System note") },
            "No model-facing scaffold text may reach the visible transcript"
        )
        // The model-switch row keeps the card presentation ChatView derives
        // from rawContent.
        XCTAssertNotNil(
            MessageNormalizer.modelChangeActivity(
                fromText: harness.appState.messages[3].rawContent ?? harness.appState.messages[3].content
            )
        )
    }

    // MARK: - Live projection preservation

    func testCompactResumeKeepsRunningInflightProjectionOnPersistedBase() async throws {
        let active = session("stored-a", alternateIDs: ["runtime-a"])
        let persistedPrefix = "Streaming the report now."
        let inflightText = persistedPrefix + " The numbers section is next."
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(
                    sessionId: "runtime-a",
                    messages: [],  // compact projection: transcript omitted
                    snapshot: SessionRuntimeSnapshot(
                        object: ["running": .bool(true)],
                        inflight: .object(["assistant": .string(inflightText)])
                    )
                )
            },
            persistedTranscript: { _, _ in
                .payload([
                    "session_id": "stored-a",
                    "messages": [
                        [
                            "id": 1,
                            "role": "user",
                            "content": "Write the report.",
                            "timestamp": "2026-09-01T10:00:00Z"
                        ],
                        [
                            "id": 2,
                            "role": "assistant",
                            "content": persistedPrefix,
                            "timestamp": "2026-09-01T10:00:10Z"
                        ]
                    ]
                ])
            }
        )
        harness.appState.sessions = [active]

        let opened = await harness.appState.openSession("stored-a")

        XCTAssertTrue(opened)
        // The persisted conversation stays visible while the turn is live,
        // and the in-flight projection rides the live bubble as exactly the
        // unpersisted continuation — no duplicated prefix row.
        XCTAssertEqual(harness.appState.messages.map { $0.role }, [.user, .assistant])
        XCTAssertEqual(harness.appState.messages[1].content, persistedPrefix)
        XCTAssertEqual(harness.appState.messages[1].timestamp, "2026-09-01T10:00:10Z")
        // Publish the authoritative streaming buffer into the test projection.
        harness.appState.showSidebar = true
        harness.appState.showSidebar = false
        XCTAssertEqual(harness.appState.streamingText, "The numbers section is next.")
        XCTAssertFalse(
            harness.appState.messages.contains { $0.content.contains("The numbers section is next.") },
            "The inflight continuation must ride the live bubble, not duplicate into rows"
        )
    }

    // MARK: - Large-session regression

    func testLargeSessionResumeShipsNoTranscriptOverWebSocket() async throws {
        // A transcript whose ordinary (non-compact) resume payload exceeds the
        // old 1 MiB URLSessionWebSocketTask default. The invariant under test:
        // such a session resumes deterministically without that giant payload
        // ever needing to traverse the WebSocket — no live multi-megabyte
        // transfer is involved.
        let filler = String(repeating: "x", count: 3_000)
        var rows: [[String: Any]] = []
        for index in 0..<200 {
            let minute = String(format: "%02d", index % 60)
            rows.append([
                "id": index * 2,
                "role": "user",
                "content": "Prompt \(index) \(filler)",
                "timestamp": "2026-09-01T10:\(minute):00Z"
            ])
            rows.append([
                "id": index * 2 + 1,
                "role": "assistant",
                "content": "Reply \(index) \(filler)",
                "timestamp": "2026-09-01T10:\(minute):05Z"
            ])
        }
        let payloadBytes = try JSONSerialization
            .data(withJSONObject: ["session_id": "stored-a", "messages": rows])
            .count
        XCTAssertGreaterThan(
            payloadBytes,
            1_048_576,
            "The fixture must represent a session whose legacy resume frame would exceed the old default limit"
        )

        let recorder = ResumeCallRecorder()
        let active = session("stored-a", alternateIDs: ["runtime-a"])
        let harness = try makeHarness(
            openSession: { _, sessionID, compact in
                recorder.record(sessionID: sessionID, compact: compact)
                return SessionResumeResult(
                    sessionId: "runtime-a",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _ in .payload(["session_id": "stored-a", "messages": rows]) }
        )
        harness.appState.sessions = [active]

        let opened = await harness.appState.openSession("stored-a")

        XCTAssertTrue(opened)
        XCTAssertEqual(
            recorder.calls.map { $0.compact },
            [true],
            "The large session must resume compactly with the transcript hydrated from history"
        )
        XCTAssertEqual(harness.appState.messages.count, 400)
        XCTAssertEqual(harness.appState.messages.first?.content, "Prompt 0 \(filler)")
        XCTAssertEqual(harness.appState.messages.first?.timestamp, "2026-09-01T10:00:00Z")
        XCTAssertEqual(harness.appState.messages.last?.content, "Reply 199 \(filler)")
        XCTAssertEqual(harness.appState.messages.last?.timestamp, "2026-09-01T10:19:05Z")
    }

    // MARK: - Compatibility fallback

    func testUnavailableHistorySourceFallsBackToLegacyResume() async throws {
        let recorder = ResumeCallRecorder()
        let legacyMessages = [
            ChatMessage(
                id: "legacy-1",
                role: .user,
                content: "Legacy persisted prompt",
                timestamp: "2026-09-01T09:00:00Z"
            ),
            ChatMessage(
                id: "legacy-2",
                role: .assistant,
                content: "Legacy persisted reply",
                timestamp: "2026-09-01T09:00:05Z"
            )
        ]
        let active = session("stored-gateway-old")
        let harness = try makeHarness(
            openSession: { _, sessionID, compact in
                recorder.record(sessionID: sessionID, compact: compact)
                if compact {
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                }
                return SessionResumeResult(
                    sessionId: sessionID,
                    messages: legacyMessages,
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _ in
                // The gateway predates the session-messages endpoint.
                .unavailable
            }
        )
        harness.appState.sessions = [active]

        let opened = await harness.appState.openSession("stored-gateway-old")

        XCTAssertTrue(opened)
        XCTAssertEqual(
            recorder.calls.map { $0.compact },
            [true, false],
            "The unsupported history source must trigger exactly one legacy re-resume"
        )
        XCTAssertEqual(
            harness.appState.messages.map { $0.content },
            ["Legacy persisted prompt", "Legacy persisted reply"]
        )
    }

    /// Drives one reconciliation against a history source that fails with
    /// `failure` and asserts the transient-failure contract: the session
    /// still opens via exactly one legacy resume, and the fallback can never
    /// cascade (the legacy call itself never triggers a second one).
    private func assertTransientHistoryFailureFallsBackExactlyOnce(
        _ failure: Error,
        expectedLegacyContent: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let recorder = ResumeCallRecorder()
        let active = session("stored-transient")
        let harness = try makeHarness(
            openSession: { _, sessionID, compact in
                recorder.record(sessionID: sessionID, compact: compact)
                if compact {
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                }
                return SessionResumeResult(
                    sessionId: sessionID,
                    messages: [
                        ChatMessage(
                            id: "legacy-1",
                            role: .assistant,
                            content: expectedLegacyContent,
                            timestamp: "2026-09-01T08:00:00Z"
                        )
                    ],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _ in .failed(failure) }
        )
        harness.appState.sessions = [active]

        let opened = await harness.appState.openSession("stored-transient")

        XCTAssertTrue(opened, "\(failure) must fall back instead of failing the resume", file: file, line: line)
        XCTAssertEqual(
            recorder.calls.map { $0.compact },
            [true, false],
            "\(failure) must trigger exactly one legacy resume",
            file: file,
            line: line
        )
        XCTAssertEqual(
            harness.appState.messages.map { $0.content },
            [expectedLegacyContent],
            file: file,
            line: line
        )
    }

    func testTransientHistoryFailuresFallBackExactlyOnce() async throws {
        // 429 / 5xx / status-0 WebKit failures / bridge readiness-timeout are
        // temporary availability problems: preserve session access through
        // exactly one legacy resume instead of failing the restore.
        let transientFailures: [Error] = [
            DashboardTicketBridgeError.http(status: 429, detail: "Too Many Requests"),
            DashboardTicketBridgeError.http(status: 500, detail: "Internal error"),
            DashboardTicketBridgeError.http(status: 503, detail: "Service Unavailable"),
            DashboardTicketBridgeError.http(status: 0, detail: "Failed to fetch"),
            DashboardTicketBridgeError.notReady,
        ]
        for failure in transientFailures {
            try await assertTransientHistoryFailureFallsBackExactlyOnce(
                failure,
                expectedLegacyContent: "Legacy transcript"
            )
        }
    }

    func testStructuralHistoryEndpointGapsFallBackExactlyOnce() async throws {
        // Gateways predating the history endpoint fall back cleanly as well.
        for status in [404, 410, 501] {
            try await assertTransientHistoryFailureFallsBackExactlyOnce(
                DashboardTicketBridgeError.http(status: status, detail: "missing endpoint"),
                expectedLegacyContent: "Legacy transcript"
            )
        }
    }

    func testDelayedHistoryHydrationAvoidsLegacyResume() async throws {
        // A history source that is not usable at the instant reconciliation
        // starts but becomes usable inside the bounded readiness window
        // hydrates normally — the legacy resume must not fire.
        let recorder = ResumeCallRecorder()
        let active = session("stored-a", alternateIDs: ["runtime-a"])
        let harness = try makeHarness(
            openSession: { _, sessionID, compact in
                recorder.record(sessionID: sessionID, compact: compact)
                return SessionResumeResult(
                    sessionId: "runtime-a",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _ in
                try? await Task.sleep(for: .milliseconds(150))
                return .payload([
                    "session_id": "stored-a",
                    "messages": [[
                        "id": 1,
                        "role": "user",
                        "content": "Late hydration",
                        "timestamp": "2026-09-01T10:00:00Z"
                    ]]
                ])
            }
        )
        harness.appState.sessions = [active]

        let opened = await harness.appState.openSession("stored-a")

        XCTAssertTrue(opened)
        XCTAssertEqual(
            recorder.calls.map { $0.compact },
            [true],
            "Hydration that succeeds inside the bounded window must not trigger the legacy resume"
        )
        XCTAssertEqual(harness.appState.messages.first?.content, "Late hydration")
    }

    func testColdDashboardBridgeStillBeginsWithCompactResume() async throws {
        // Regression for the cold-launch hole: a dashboard bridge that exists
        // but is not ready yet must NOT push the resume onto the legacy
        // full-transcript path immediately. The resume begins compact, the
        // transcript fetch waits inside requestJSON's bounded readiness poll,
        // and a bridge that never becomes usable degrades to exactly one
        // legacy resume. A modern gateway therefore never receives a legacy
        // full-transcript request just because the bridge was cold.
        let recorder = ResumeCallRecorder()
        let active = session("stored-cold")
        let harness = try makeHarness(
            openSession: { _, sessionID, compact in
                recorder.record(sessionID: sessionID, compact: compact)
                return SessionResumeResult(
                    sessionId: sessionID,
                    messages: [
                        ChatMessage(
                            id: "restored",
                            role: .assistant,
                            content: "Restored",
                            timestamp: "1"
                        )
                    ],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            additionalOperations: { ops in
                ops.connectClient = { _ in }
                ops.loadCatalog = { _, _ in [active] }
                ops.loadProfiles = {}
                ops.loadBusyInputMode = { _ in }
                ops.loadProfileDisplayPreferences = {}
                ops.loadSlashCommands = {}
            }
        )
        harness.coordinator.rememberSessionID(active.id, for: "default")
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id

        await harness.appState.connect(
            with: HermesConnection(baseUrl: "https://one.example", ticket: "cold-ticket")
        )

        XCTAssertTrue(harness.appState.isConnected)
        XCTAssertEqual(
            recorder.calls.map { $0.compact },
            [true, false],
            "A cold bridge must begin compact and fall back to at most one legacy resume"
        )
        XCTAssertEqual(harness.appState.messages.map { $0.content }, ["Restored"])
    }

    func testLegacyFallbackMergeHandlesLargeTranscriptAtAppStateLevel() async throws {
        // AppState-merge-level scope ONLY: this injects a large transcript
        // through the lifecycle seam, bypassing HermesClient, JSON-RPC
        // serialization, and URLSessionWebSocketTask entirely. It proves the
        // reconciliation and merge layers handle a big transcript without
        // duplication — it makes NO claim about transport size.
        //
        // Transport bound: a legacy resume response larger than the 4 MiB
        // `URLSessionWebSocketTask.maximumMessageSize` cannot traverse the
        // socket at all (verified by
        // HermesClientTests/testProductionTransportRaisesWebSocketMessageLimit).
        // The supported path for transcripts of that scale is the compact
        // resume + REST hydration
        // (testLargeSessionResumeShipsNoTranscriptOverWebSocket).
        let filler = String(repeating: "x", count: 10_000)
        let recorder = ResumeCallRecorder()
        let count = 450
        let legacyMessages: [ChatMessage] = (0..<count).map { index in
            ChatMessage(
                id: "big-\(index)",
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "Row \(index) \(filler)",
                timestamp: "2026-09-01T10:\(String(format: "%02d", index % 60)):00Z"
            )
        }
        // The fixture is deliberately large so any row loss or duplication in
        // the merge path is observable at scale.
        let payloadBytes = legacyMessages
            .reduce(0) { $0 + $1.content.utf8.count }
        XCTAssertGreaterThan(payloadBytes, 4 * 1024 * 1024)

        let active = session("stored-gateway-old")
        let harness = try makeHarness(
            openSession: { _, sessionID, compact in
                recorder.record(sessionID: sessionID, compact: compact)
                if compact {
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                }
                return SessionResumeResult(
                    sessionId: sessionID,
                    messages: legacyMessages,
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _ in .unavailable }
        )
        harness.appState.sessions = [active]

        let opened = await harness.appState.openSession("stored-gateway-old")

        XCTAssertTrue(opened)
        XCTAssertEqual(recorder.calls.map { $0.compact }, [true, false])
        XCTAssertEqual(harness.appState.messages.count, count)
        XCTAssertEqual(harness.appState.messages.first?.content, "Row 0 \(filler)")
        XCTAssertEqual(harness.appState.messages.last?.content, "Row \(count - 1) \(filler)")
        XCTAssertNil(
            harness.appState.persistedTranscriptWindow,
            "A legacy full-transcript resume leaves no window: there is no older page to fetch"
        )
    }

    func testHistoryFailureSurfacesWithoutLegacyFallback() async throws {
        let recorder = ResumeCallRecorder()
        let active = session("stored-a")
        let harness = try makeHarness(
            openSession: { _, sessionID, compact in
                recorder.record(sessionID: sessionID, compact: compact)
                return SessionResumeResult(
                    sessionId: sessionID,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _ in
                // An unrelated authentication failure on the history source.
                .failed(DashboardTicketBridgeError.signInRequired)
            }
        )
        harness.appState.sessions = [active]

        let opened = await harness.appState.openSession("stored-a")

        XCTAssertFalse(opened, "A history authentication failure must surface, not hide behind a legacy resume")
        XCTAssertEqual(
            recorder.calls.map { $0.compact },
            [true],
            "No silent legacy fallback may run for unrelated history failures"
        )
        XCTAssertTrue(
            harness.appState.errorMessage?.contains("Dashboard sign-in has expired.") == true,
            "The surfaced error should name the actual history failure, got: \(harness.appState.errorMessage ?? "nil")"
        )
    }

    func testMalformedHistoryPayloadSurfacesWithoutLegacyFallback() async throws {
        let recorder = ResumeCallRecorder()
        let active = session("stored-a")
        let harness = try makeHarness(
            openSession: { _, sessionID, compact in
                recorder.record(sessionID: sessionID, compact: compact)
                return SessionResumeResult(
                    sessionId: sessionID,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _ in
                // A 200 response without the expected messages array.
                .payload(["session_id": "stored-a"])
            }
        )
        harness.appState.sessions = [active]

        let opened = await harness.appState.openSession("stored-a")

        XCTAssertFalse(opened, "A malformed history payload must surface, not hide behind a legacy resume")
        XCTAssertEqual(recorder.calls.map { $0.compact }, [true])
        XCTAssertFalse(
            harness.appState.errorMessage?.isEmpty ?? true,
            "The parse failure should be visible to the user"
        )
    }

    // MARK: - Unavailable-source classification

    func testHistorySourceUnavailableClassification() {
        // Structural endpoint gaps fall back to the legacy resume…
        for status in [404, 410, 501] {
            XCTAssertTrue(
                AppState.historySourceIsUnavailable(
                    DashboardTicketBridgeError.http(status: status, detail: "missing")
                ),
                "status \(status) must be classified as unavailable"
            )
        }
        // …as do transient availability problems: rate limiting, any 5xx,
        // status-0 WebKit/network failures, and a bridge (or request) that
        // outlived its bounded readiness strategy.
        XCTAssertTrue(AppState.historySourceIsUnavailable(
            DashboardTicketBridgeError.http(status: 429, detail: "Too Many Requests")
        ))
        for status in [500, 502, 503, 504] {
            XCTAssertTrue(
                AppState.historySourceIsUnavailable(
                    DashboardTicketBridgeError.http(status: status, detail: "server error")
                ),
                "status \(status) must be classified as unavailable"
            )
        }
        XCTAssertTrue(AppState.historySourceIsUnavailable(
            DashboardTicketBridgeError.http(status: 0, detail: "Failed to fetch")
        ))
        XCTAssertTrue(AppState.historySourceIsUnavailable(DashboardTicketBridgeError.notReady))
        // A known-oversized one-shot history response is a typed condition,
        // not transport trouble: it must surface its controlled compatibility
        // error instead of retrying the giant transcript over the WebSocket.
        XCTAssertFalse(AppState.historySourceIsUnavailable(
            DashboardTicketBridgeError.oversizedResponse(limit: DataURLLimits.maxJSONResponseBytes)
        ))
        // Authentication and unclassified failures must surface instead.
        XCTAssertFalse(AppState.historySourceIsUnavailable(DashboardTicketBridgeError.signInRequired))
        XCTAssertFalse(AppState.historySourceIsUnavailable(
            DashboardTicketBridgeError.http(status: 400, detail: "Bad Request")
        ))
        XCTAssertFalse(AppState.historySourceIsUnavailable(
            DashboardTicketBridgeError.requestFailed("Could not encode dashboard request.")
        ))
    }

    /// Backfill affordance retirement is structural-only: 404/410/5xx and a
    /// bridge that never became ready retire "Load earlier messages"; every
    /// transient transport trouble (408/429/status-0) and unclassified or
    /// auth failures stay tap-retryable.
    func testBackfillStructuralRetirementClassification() {
        for status in [404, 410, 500, 502, 503] {
            XCTAssertTrue(
                AppState.historySourceIsStructurallyGone(
                    DashboardTicketBridgeError.http(status: status, detail: "gone")
                ),
                "status \(status) must retire the affordance"
            )
        }
        XCTAssertTrue(AppState.historySourceIsStructurallyGone(DashboardTicketBridgeError.notReady))
        for status in [0, 408, 429] {
            XCTAssertFalse(
                AppState.historySourceIsStructurallyGone(
                    DashboardTicketBridgeError.http(status: status, detail: "transient")
                ),
                "status \(status) must stay tap-retryable"
            )
        }
        XCTAssertFalse(AppState.historySourceIsStructurallyGone(DashboardTicketBridgeError.signInRequired))
        XCTAssertFalse(AppState.historySourceIsStructurallyGone(
            DashboardTicketBridgeError.oversizedResponse(limit: DataURLLimits.maxJSONResponseBytes)
        ))
        XCTAssertFalse(AppState.historySourceIsStructurallyGone(
            DashboardTicketBridgeError.requestFailed("Could not encode dashboard request.")
        ))
    }

    // MARK: - Bounded persisted-history pagination

    /// Large-session invariant: a session with thousands of persisted rows
    /// opens by transferring and normalizing exactly one bounded page, and
    /// the pagination echo reports older history behind it.
    func testPaginatedHistoryHydratesOnlyNewestPage() async throws {
        let recorder = ResumeCallRecorder()
        let active = session("stored-a", alternateIDs: ["runtime-a"])
        let harness = try makeHarness(
            openSession: { _, sessionID, compact in
                recorder.record(sessionID: sessionID, compact: compact)
                return SessionResumeResult(
                    sessionId: "runtime-a",
                    messages: [],  // compact projection: transcript omitted
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _ in
                // The session holds 2,000 persisted rows; the paginated
                // endpoint answers with only the newest 120 plus its
                // pagination echo.
                self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1880..<2000), offset: 0)
            }
        )
        harness.appState.sessions = [active]

        let opened = await harness.appState.openSession("stored-a")

        XCTAssertTrue(opened)
        XCTAssertEqual(
            recorder.calls.map { $0.compact },
            [true],
            "A paginated-history session must resume compactly — no full transcript over the WebSocket"
        )
        XCTAssertEqual(harness.appState.messages.count, 120, "Only the requested page may be normalized and published")
        XCTAssertEqual(harness.appState.messages.first?.content, "Row 1880")
        XCTAssertEqual(harness.appState.messages.last?.content, "Row 1999")
        let window = harness.appState.persistedTranscriptWindow
        XCTAssertEqual(window?.requestedSessionID, "stored-a")
        XCTAssertEqual(window?.profile, "default")
        XCTAssertEqual(window?.resolvedSessionID, "stored-a")
        XCTAssertEqual(window?.nextOffset, 120)
        XCTAssertEqual(window?.canLoadEarlier, true, "A full page means older history may still exist")
        XCTAssertEqual(window?.isLoadingEarlier, false)
    }

    /// Backfill: "Load earlier messages" fetches the next older page under
    /// the same tail-anchored contract and prepends it. Rows persisted while
    /// the conversation was open shift the offset origin, so the page
    /// overlaps rows already held — the prepend must deduplicate them without
    /// disturbing the loaded tail.
    func testLoadEarlierPrependsOlderPageWithOverlapDeduplicated() async throws {
        let backfillCalls = Counter()
        let active = session("stored-a", alternateIDs: ["runtime-a"])
        let harness = try makeHarness(
            openSession: { _, _, compact in
                XCTAssertTrue(compact)
                return SessionResumeResult(
                    sessionId: "runtime-a",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _ in
                self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1880..<2000), offset: 0)
            },
            loadEarlierTranscriptPage: { sessionId, profile, offset in
                backfillCalls.value += 1
                XCTAssertEqual(sessionId, "stored-a", "The backfill must stay scoped to the requested session")
                XCTAssertEqual(profile, "default", "The backfill must stay scoped to the requesting profile")
                XCTAssertEqual(offset, 120)
                // Ten rows persisted since the tail hydration shifted the
                // offset origin: the page overlaps 110 already-held rows and
                // adds ten genuinely older ones.
                return self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1870..<1990), offset: offset)
            }
        )
        harness.appState.sessions = [active]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.count, 120)

        await harness.appState.loadEarlierMessages()

        XCTAssertEqual(backfillCalls.value, 1)
        let messages = harness.appState.messages
        XCTAssertEqual(messages.count, 120 + 120 - 110, "The overlapping prefix must be deduplicated, the loaded tail kept")
        XCTAssertEqual(messages.first?.content, "Row 1870")
        XCTAssertEqual(messages.last?.content, "Row 1999")
        let ids = messages.map { $0.id }
        XCTAssertEqual(Set(ids).count, ids.count, "No duplicate user messages, tool cards, or timeline events may result")
        let numericIDs = ids.compactMap { Double($0) }
        XCTAssertEqual(numericIDs, numericIDs.sorted(), "Prepended pages must keep the transcript chronological")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.nextOffset, 240)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.canLoadEarlier, true)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.isLoadingEarlier, false)
    }

    /// A short page means the beginning of the persisted transcript has been
    /// reached: the affordance retires and repeated taps issue no further
    /// requests.
    func testShortBackfillPageMarksTranscriptFullyBackfilled() async throws {
        let backfillCalls = Counter()
        let active = session("stored-a", alternateIDs: ["runtime-a"])
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(
                    sessionId: "runtime-a",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _ in
                self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1880..<2000), offset: 0)
            },
            loadEarlierTranscriptPage: { _, _, offset in
                backfillCalls.value += 1
                XCTAssertEqual(offset, 120)
                return self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1843..<1880), offset: offset)
            }
        )
        harness.appState.sessions = [active]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)

        await harness.appState.loadEarlierMessages()
        XCTAssertEqual(harness.appState.messages.count, 157)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.canLoadEarlier, false, "A short page proves the beginning was reached")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.nextOffset, 157)

        // Repeated taps after the terminal page must not issue more requests.
        await harness.appState.loadEarlierMessages()
        await harness.appState.loadEarlierMessages()
        XCTAssertEqual(backfillCalls.value, 1)
    }

    /// A backfill resolving after a session switch belongs to a conversation
    /// nobody is viewing: it must be discarded whole, leaving the newly
    /// active session untouched.
    func testStaleBackfillDiscardedAfterSessionSwitch() async throws {
        let backfillStarted = Flag()
        let activeA = session("stored-a", alternateIDs: ["runtime-a"])
        let activeB = session("stored-b", alternateIDs: ["runtime-b"])
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(
                    sessionId: "runtime-a",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { sessionId, _ in
                if sessionId == "stored-a" {
                    return self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1880..<2000), offset: 0)
                }
                return self.tailPagePayload(
                    sessionId: "stored-b",
                    rows: self.syntheticRows(0..<2),
                    offset: 0
                )
            },
            loadEarlierTranscriptPage: { sessionId, _, offset in
                backfillStarted.isOn = true
                XCTAssertEqual(sessionId, "stored-a")
                try? await Task.sleep(for: .milliseconds(250))
                return self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1760..<1880), offset: offset)
            }
        )
        harness.appState.sessions = [activeA, activeB]
        let openedA = await harness.appState.openSession("stored-a")
        XCTAssertTrue(openedA)

        let backfill = Task { await harness.appState.loadEarlierMessages() }
        for _ in 0..<1_000 where !backfillStarted.isOn {
            await Task.yield()
        }
        XCTAssertTrue(backfillStarted.isOn, "The backfill fetch must have started")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.isLoadingEarlier, true)

        let openedB = await harness.appState.openSession("stored-b")
        XCTAssertTrue(openedB)
        await backfill

        XCTAssertEqual(harness.appState.messages.count, 2, "Session B must be completely unchanged by the stale page")
        XCTAssertEqual(harness.appState.messages.first?.content, "Row 0")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.requestedSessionID, "stored-b")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.isLoadingEarlier, false)
        XCTAssertFalse(
            harness.appState.messages.contains { $0.id == "1760" },
            "No row from the stale session-A page may leak into session B"
        )
    }

    /// Backfilled pages carry the same display-contract rows as the initial
    /// hydration (hidden compaction carriers, display_content asks,
    /// model-switch and auto-continue pivots); the projection must stay
    /// correct after a prepend.
    func testCompactedDisplayRowsProjectCorrectlyInBackfilledPage() async throws {
        let modelSwitchMarker = "[System: The active model for this chat has changed to GLM-5.3-Flash via provider zai. From this point forward, use this runtime metadata when answering questions about what model/provider is active.]"
        let active = session("stored-a", alternateIDs: ["runtime-a"])
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(
                    sessionId: "runtime-a",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _ in
                self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1880..<2000), offset: 0)
            },
            loadEarlierTranscriptPage: { _, _, offset in
                var hiddenRow = self.transcriptRow(900, role: "user", content: "INTERNAL MODEL SCAFFOLD — do not render")
                hiddenRow["display_kind"] = "hidden"
                var autoContinueRow = self.transcriptRow(901, role: "user", content: "[System note: Your previous turn was interrupted mid-run. Continuing from the checkpoint.]")
                autoContinueRow["display_kind"] = "auto_continue"
                var displayCarrierRow = self.transcriptRow(902, role: "user", content: "Older ask.\n\n[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]")
                displayCarrierRow["display_content"] = "Older ask."
                var modelSwitchRow = self.transcriptRow(903, role: "user", content: modelSwitchMarker)
                modelSwitchRow["display_kind"] = "model_switch"
                return .payload([
                    "session_id": "stored-a",
                    "messages": [
                        hiddenRow,
                        autoContinueRow,
                        displayCarrierRow,
                        modelSwitchRow,
                        self.transcriptRow(904, role: "user", content: "Older human turn"),
                        self.transcriptRow(905, role: "assistant", content: "Older assistant turn"),
                    ],
                    "pagination": ["limit": 120, "offset": offset, "order": "latest", "returned": 6]
                ])
            }
        )
        harness.appState.sessions = [active]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)

        await harness.appState.loadEarlierMessages()

        let messages = harness.appState.messages
        XCTAssertEqual(messages.count, 120 + 6 - 1, "The hidden carrier row disappears; every visible projection stays")
        XCTAssertEqual(
            messages.prefix(5).map { $0.role },
            [.system, .user, .system, .user, .assistant]
        )
        XCTAssertEqual(
            messages.prefix(5).map { $0.content },
            [
                "Resumed interrupted turn",
                "Older ask.",
                "[Model has been changed to zai/GLM-5.3-Flash]",
                "Older human turn",
                "Older assistant turn"
            ]
        )
        XCTAssertFalse(
            messages.contains { $0.content.contains("SCAFFOLD") || $0.content.contains("COMPACTION SUMMARY") },
            "No model-facing scaffold text may surface through a backfilled page"
        )
        XCTAssertEqual(messages.last?.content, "Row 1999", "The loaded tail must remain intact after the prepend")
    }

    /// Legacy one-shot backend: no pagination metadata means the complete
    /// transcript — accepted as the compatibility path, with no window and
    /// therefore no load-earlier affordance. (The large-session legacy merge
    /// is additionally covered by
    /// testLargeSessionResumeShipsNoTranscriptOverWebSocket.)
    func testLegacyOneShotResponseHydratesFullyWithoutWindow() async throws {
        let active = session("stored-a", alternateIDs: ["runtime-a"])
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(
                    sessionId: "runtime-a",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _ in
                .payload([
                    "session_id": "stored-a",
                    "messages": self.syntheticRows(0..<300)
                ])
            }
        )
        harness.appState.sessions = [active]

        let opened = await harness.appState.openSession("stored-a")

        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.count, 300)
        XCTAssertNil(
            harness.appState.persistedTranscriptWindow,
            "A one-shot transcript leaves no window: there is no older page to fetch"
        )
    }

    /// A pagination echo WITHOUT the `order=latest` tail contract describes a
    /// backend whose offsets page from the oldest end. Honoring those offsets
    /// would walk forward from row zero and never reach the newest rows, so
    /// the transcript is re-read one-shot — the exact request pre-pagination
    /// Conduit made — and treated as the legacy contract.
    func testPaginationEchoWithoutLatestOrderFallsBackToOneShot() async throws {
        let fetchCalls = Counter()
        let active = session("stored-a", alternateIDs: ["runtime-a"])
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(
                    sessionId: "runtime-a",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _ in
                fetchCalls.value += 1
                if fetchCalls.value == 1 {
                    // Oldest-anchored build: bounded request, no order echo.
                    return self.tailPagePayload(
                        sessionId: "stored-a",
                        rows: self.syntheticRows(0..<3),
                        offset: 0,
                        limit: 120,
                        order: nil
                    )
                }
                // The unbounded re-read returns the complete transcript.
                return .payload([
                    "session_id": "stored-a",
                    "messages": self.syntheticRows(0..<6)
                ])
            }
        )
        harness.appState.sessions = [active]

        let opened = await harness.appState.openSession("stored-a")

        XCTAssertTrue(opened)
        XCTAssertEqual(fetchCalls.value, 2, "Exactly one bounded read and one one-shot re-read")
        XCTAssertEqual(harness.appState.messages.count, 6)
        XCTAssertEqual(harness.appState.messages.first?.content, "Row 0")
        XCTAssertEqual(harness.appState.messages.last?.content, "Row 5")
        XCTAssertNil(harness.appState.persistedTranscriptWindow)
    }

    /// An old backend answering a one-shot history that exceeds the client's
    /// safe response bound must surface the controlled compatibility error —
    /// never a retry of the same giant transcript over the bounded
    /// WebSocket.
    func testOversizedLegacyHistorySurfacesWithoutWebSocketRetry() async throws {
        let recorder = ResumeCallRecorder()
        let active = session("stored-a")
        let harness = try makeHarness(
            openSession: { _, sessionID, compact in
                recorder.record(sessionID: sessionID, compact: compact)
                return SessionResumeResult(
                    sessionId: sessionID,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _ in
                .failed(DashboardTicketBridgeError.oversizedResponse(
                    limit: DataURLLimits.maxJSONResponseBytes
                ))
            }
        )
        harness.appState.sessions = [active]

        let opened = await harness.appState.openSession("stored-a")

        XCTAssertFalse(opened, "The oversized-history compatibility error must surface")
        XCTAssertEqual(
            recorder.calls.map { $0.compact },
            [true],
            "No legacy full-transcript WebSocket retry may follow an oversized history response"
        )
        XCTAssertTrue(
            harness.appState.errorMessage?.contains("too large to load safely") == true,
            "The surfaced error should be the controlled compatibility copy, got: \(harness.appState.errorMessage ?? "nil")"
        )
    }

    /// Live resume over a paginated tail: the persisted newest page stays the
    /// durable base and the inflight assistant continuation still rides the
    /// streaming bubble as exactly the unpersisted suffix.
    func testLiveResumeWithPaginatedTailKeepsInflightProjection() async throws {
        let persistedPrefix = "Streaming the report now."
        let inflightText = persistedPrefix + " The numbers section is next."
        let active = session("stored-a", alternateIDs: ["runtime-a"])
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(
                    sessionId: "runtime-a",
                    messages: [],  // compact projection: transcript omitted
                    snapshot: SessionRuntimeSnapshot(
                        object: ["running": .bool(true)],
                        inflight: .object(["assistant": .string(inflightText)])
                    )
                )
            },
            persistedTranscript: { _, _ in
                .payload([
                    "session_id": "stored-a",
                    "messages": [
                        self.transcriptRow(1, role: "user", content: "Write the report."),
                        self.transcriptRow(2, role: "assistant", content: persistedPrefix)
                    ],
                    "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                ])
            }
        )
        harness.appState.sessions = [active]

        let opened = await harness.appState.openSession("stored-a")

        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map { $0.role }, [.user, .assistant])
        XCTAssertEqual(harness.appState.messages[1].content, persistedPrefix)
        XCTAssertEqual(
            harness.appState.persistedTranscriptWindow?.nextOffset, 2,
            "A short page under the paginated contract means the whole persisted history is loaded"
        )
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.canLoadEarlier, false)
        harness.appState.showSidebar = true
        harness.appState.showSidebar = false
        XCTAssertEqual(harness.appState.streamingText, "The numbers section is next.")
        XCTAssertFalse(
            harness.appState.messages.contains { $0.content.contains("The numbers section is next.") },
            "The inflight continuation must ride the live bubble, not duplicate into rows"
        )
    }

    /// A re-reconciliation re-reads only the newest page; the pages already
    /// loaded through "Load earlier messages" must survive it via the tail
    /// graft instead of being truncated away.
    func testReconcileRefreshGraftsBackfilledPrefix() async throws {
        let holdsRefreshedTail = Flag()
        let active = session("stored-a", alternateIDs: ["runtime-a"])
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(
                    sessionId: "runtime-a",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _ in
                if holdsRefreshedTail.isOn {
                    // Twenty new rows persisted since the backfill: the
                    // refreshed tail covers the newest 120 rows.
                    return self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1900..<2020), offset: 0)
                }
                return self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1880..<2000), offset: 0)
            },
            loadEarlierTranscriptPage: { _, _, offset in
                self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1760..<1880), offset: offset)
            },
            additionalOperations: { ops in
                ops.connectClient = { _ in }
                ops.loadCatalog = { _, _ in [active] }
                ops.loadProfiles = {}
                ops.loadBusyInputMode = { _ in }
                ops.loadProfileDisplayPreferences = {}
                ops.loadSlashCommands = {}
            }
        )
        harness.appState.sessions = [active]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)

        await harness.appState.loadEarlierMessages()
        XCTAssertEqual(harness.appState.messages.count, 240)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.nextOffset, 240)

        // A reconnect re-reconciles the same session without clearing the
        // transcript; the refreshed tail grafts onto the backfilled prefix.
        holdsRefreshedTail.isOn = true
        harness.coordinator.rememberSessionID("stored-a", for: "default")
        await harness.appState.connect(
            with: HermesConnection(baseUrl: "https://one.example", ticket: "graft-ticket")
        )

        XCTAssertEqual(harness.appState.messages.count, 140 + 120, "Older prefix (rows 1760–1899) plus the refreshed tail (rows 1900–2019)")
        XCTAssertEqual(harness.appState.messages.first?.content, "Row 1760")
        XCTAssertEqual(harness.appState.messages[139].content, "Row 1899")
        XCTAssertEqual(harness.appState.messages[140].content, "Row 1900")
        XCTAssertEqual(harness.appState.messages.last?.content, "Row 2019")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.nextOffset, 120)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.canLoadEarlier, true)
    }

    /// Pins the request contract: the production history request is an
    /// explicit tail-anchored bounded page — never the implicit default and
    /// never an unbounded one-shot — and older pages continue the same
    /// contract at the next offset.
    func testPersistedHistoryRequestContractIsBoundedTailPaging() {
        XCTAssertEqual(PersistedTranscriptPagination.pageSize, 120)
        XCTAssertEqual(
            PersistedTranscriptPagination.tailQuery(offset: 0),
            "?limit=120&offset=0&order=latest&include_compacted=true"
        )
        XCTAssertEqual(
            PersistedTranscriptPagination.tailQuery(offset: 240),
            "?limit=120&offset=240&order=latest&include_compacted=true"
        )
        XCTAssertEqual(PersistedTranscriptPagination.legacyQuery, "")
        XCTAssertEqual(
            AppState.sessionMessagesPath(
                sessionId: "stored a",
                profile: "default",
                query: PersistedTranscriptPagination.tailQuery(offset: 0)
            ),
            "/api/sessions/stored%20a/messages?limit=120&offset=0&order=latest&include_compacted=true"
        )
        XCTAssertEqual(
            AppState.sessionMessagesPath(
                sessionId: "stored-a",
                profile: "work",
                query: PersistedTranscriptPagination.tailQuery(offset: 120)
            ),
            "/api/sessions/stored-a/messages?limit=120&offset=120&order=latest&include_compacted=true&profile=work"
        )
    }

    /// A transient backfill failure (429, status-0, 408) stays retryable:
    /// the affordance remains and a later tap succeeds. Only a structurally
    /// gone history source (404/410/5xx, dead bridge) retires it — pinned by
    /// testHistorySourceUnavailableClassification's structural counterpart.
    func testTransientBackfillFailureStaysRetryable() async throws {
        let backfillCalls = Counter()
        let shouldFail = Flag()
        let active = session("stored-a", alternateIDs: ["runtime-a"])
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(
                    sessionId: "runtime-a",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _ in
                self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1880..<2000), offset: 0)
            },
            loadEarlierTranscriptPage: { _, _, offset in
                backfillCalls.value += 1
                if shouldFail.isOn {
                    return .failed(DashboardTicketBridgeError.http(status: 429, detail: "Too Many Requests"))
                }
                return self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1760..<1880), offset: offset)
            }
        )
        harness.appState.sessions = [active]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)

        shouldFail.isOn = true
        let didPrependFailure = await harness.appState.loadEarlierMessages()
        XCTAssertFalse(didPrependFailure)
        XCTAssertEqual(backfillCalls.value, 1)
        XCTAssertEqual(
            harness.appState.persistedTranscriptWindow?.canLoadEarlier,
            true,
            "A transient failure must keep the affordance retryable"
        )
        XCTAssertEqual(harness.appState.messages.count, 120, "A failed backfill must not touch the transcript")

        shouldFail.isOn = false
        let didPrependRetry = await harness.appState.loadEarlierMessages()
        XCTAssertTrue(didPrependRetry)
        XCTAssertEqual(backfillCalls.value, 2)
        XCTAssertEqual(harness.appState.messages.count, 240)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.canLoadEarlier, true)
    }

    /// A full page that dedupes to nothing (heavy offset drift) publishes no
    /// transcript replacement but still advances coverage so the next tap
    /// fetches genuinely older rows — and reports that nothing landed so the
    /// viewport anchor is discharged rather than re-pinning later.
    func testDuplicateOnlyPageAdvancesCoverageWithoutPrepending() async throws {
        let active = session("stored-a", alternateIDs: ["runtime-a"])
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(
                    sessionId: "runtime-a",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _ in
                self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1880..<2000), offset: 0)
            },
            loadEarlierTranscriptPage: { _, _, offset in
                self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1880..<2000), offset: offset)
            }
        )
        harness.appState.sessions = [active]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)

        let didPrepend = await harness.appState.loadEarlierMessages()

        XCTAssertFalse(didPrepend, "An all-duplicate page must not report a prepend")
        XCTAssertEqual(harness.appState.messages.count, 120)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.nextOffset, 240, "Coverage still advances past the held rows")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.canLoadEarlier, true)
    }

    /// A malformed backfill payload retires the affordance without touching
    /// the already-hydrated transcript.
    func testMalformedBackfillPayloadRetiresAffordanceWithoutTouchingTranscript() async throws {
        let active = session("stored-a", alternateIDs: ["runtime-a"])
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(
                    sessionId: "runtime-a",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _ in
                self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1880..<2000), offset: 0)
            },
            loadEarlierTranscriptPage: { _, _, _ in
                .payload(["session_id": "stored-a"])
            }
        )
        harness.appState.sessions = [active]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)

        let didPrepend = await harness.appState.loadEarlierMessages()

        XCTAssertFalse(didPrepend)
        XCTAssertEqual(harness.appState.messages.count, 120, "The transcript stays untouched")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.canLoadEarlier, false, "A malformed page is a backfill dead end")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.isLoadingEarlier, false)
    }

    /// The graft gate is alias-aware: a window opened under a runtime ID
    /// survives a reconnect that reconciles under the catalog's stored ID.
    func testGraftSurvivesRuntimeAliasReconcile() async throws {
        let holdsRefreshedTail = Flag()
        let active = session("stored-a", alternateIDs: ["runtime-a"])
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(
                    sessionId: "runtime-a",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _ in
                if holdsRefreshedTail.isOn {
                    return self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1900..<2020), offset: 0)
                }
                return self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1880..<2000), offset: 0)
            },
            loadEarlierTranscriptPage: { _, _, offset in
                self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1760..<1880), offset: offset)
            },
            additionalOperations: { ops in
                ops.connectClient = { _ in }
                ops.loadCatalog = { _, _ in [active] }
                ops.loadProfiles = {}
                ops.loadBusyInputMode = { _ in }
                ops.loadProfileDisplayPreferences = {}
                ops.loadSlashCommands = {}
            }
        )
        harness.appState.sessions = [active]
        // Open under the runtime alias; the window is owned by "runtime-a".
        let opened = await harness.appState.openSession("runtime-a")
        XCTAssertTrue(opened)

        await harness.appState.loadEarlierMessages()
        XCTAssertEqual(harness.appState.messages.count, 240)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.requestedSessionID, "runtime-a")

        // The automatic reconnect reconciles under the catalog's stored ID;
        // the alias-aware graft gate must still recognize the window.
        holdsRefreshedTail.isOn = true
        harness.coordinator.rememberSessionID("stored-a", for: "default")
        await harness.appState.connect(
            with: HermesConnection(baseUrl: "https://one.example", ticket: "alias-graft-ticket")
        )

        XCTAssertEqual(harness.appState.messages.count, 140 + 120, "Backfilled pages survive the alias reconcile")
        XCTAssertEqual(harness.appState.messages.first?.content, "Row 1760")
        XCTAssertEqual(harness.appState.messages.last?.content, "Row 2019")
    }

    // MARK: - Harness

    private func makeHarness(
        openSession: @escaping @MainActor (HermesClient, String, Bool) async throws -> SessionResumeResult,
        persistedTranscript: (@MainActor (String, String) async -> PersistedTranscriptFetchOutcome)? = nil,
        loadEarlierTranscriptPage: (@MainActor (String, String, Int) async -> PersistedTranscriptFetchOutcome)? = nil,
        additionalOperations: (inout ChatResumeLifecycleOperations) -> Void = { _ in }
    ) throws -> (appState: AppState, coordinator: ChatResumeCoordinator, defaults: UserDefaults) {
        let suite = "CompactResumeTranscriptTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw FixtureError.unusableSuite
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let cacheSuite = suite + ".cache"
        guard let cacheDefaults = UserDefaults(suiteName: cacheSuite) else {
            throw FixtureError.unusableSuite
        }
        addTeardownBlock { cacheDefaults.removePersistentDomain(forName: cacheSuite) }

        var operations = ChatResumeLifecycleOperations(
            openSession: openSession,
            persistedTranscript: persistedTranscript,
            loadEarlierTranscriptPage: loadEarlierTranscriptPage
        )
        additionalOperations(&operations)
        let coordinator = ChatResumeCoordinator(store: ChatResumeStore(defaults: defaults))
        let appState = AppState(
            defaults: defaults,
            chatResumeCoordinator: coordinator,
            recoverySequence: ChatResumeRecoverySequence(),
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: operations,
            sessionPresentationCache: SessionPresentationCache(defaults: cacheDefaults)
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        return (appState, coordinator, defaults)
    }

    private func session(
        _ id: String,
        alternateIDs: [String] = []
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: alternateIDs,
            title: id,
            model: "Hermes",
            updatedLabel: "now",
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
    }

    // MARK: - Pagination fixtures

    private final class Counter {
        var value = 0
    }

    private final class Flag {
        var isOn = false
    }

    /// One persisted transcript row exactly as the messages endpoint returns
    /// it (numeric row id, chronological insertion order).
    private func transcriptRow(
        _ id: Int,
        role: String,
        content: String
    ) -> [String: Any] {
        [
            "id": id,
            "role": role,
            "content": content,
            "timestamp": String(format: "2026-09-01T%02d:%02d:00Z", 10 + (id / 60) % 10, id % 60)
        ]
    }

    private func syntheticRows(_ range: Range<Int>) -> [[String: Any]] {
        range.map { index in
            transcriptRow(
                index,
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "Row \(index)"
            )
        }
    }

    private func tailPagePayload(
        sessionId: String,
        rows: [[String: Any]],
        offset: Int,
        limit: Int? = 120,
        order: String? = "latest"
    ) -> PersistedTranscriptFetchOutcome {
        var pagination: [String: Any] = ["offset": offset, "returned": rows.count]
        if let limit {
            pagination["limit"] = limit
        }
        if let order {
            pagination["order"] = order
        }
        return .payload([
            "session_id": sessionId,
            "messages": rows,
            "pagination": pagination
        ])
    }
}
