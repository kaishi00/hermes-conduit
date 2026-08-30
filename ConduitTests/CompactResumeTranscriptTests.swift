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
        // Authentication and unclassified failures must surface instead.
        XCTAssertFalse(AppState.historySourceIsUnavailable(DashboardTicketBridgeError.signInRequired))
        XCTAssertFalse(AppState.historySourceIsUnavailable(
            DashboardTicketBridgeError.http(status: 400, detail: "Bad Request")
        ))
        XCTAssertFalse(AppState.historySourceIsUnavailable(
            DashboardTicketBridgeError.requestFailed("Could not encode dashboard request.")
        ))
    }

    // MARK: - Harness

    private func makeHarness(
        openSession: @escaping @MainActor (HermesClient, String, Bool) async throws -> SessionResumeResult,
        persistedTranscript: (@MainActor (String, String) async -> PersistedTranscriptFetchOutcome)? = nil,
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
            persistedTranscript: persistedTranscript
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
}
