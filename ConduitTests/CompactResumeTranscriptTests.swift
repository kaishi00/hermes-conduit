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
    /// `failure` and asserts the bounded-failure contract: a failing or slow
    /// BOUNDED history request must never escalate into the legacy
    /// full-transcript WebSocket resume. The restore surfaces the error
    /// instead; the compact resume stays the only transport used.
    private func assertTransientHistoryFailureSurfacesWithoutLegacyResume(
        _ failure: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let recorder = ResumeCallRecorder()
        let active = session("stored-transient")
        let harness = try makeHarness(
            openSession: { _, sessionID, compact in
                recorder.record(sessionID: sessionID, compact: compact)
                return SessionResumeResult(
                    sessionId: sessionID,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _ in .failed(failure) }
        )
        harness.appState.sessions = [active]

        let opened = await harness.appState.openSession("stored-transient")

        XCTAssertFalse(opened, "\(failure) must surface instead of silently degrading", file: file, line: line)
        XCTAssertEqual(
            recorder.calls.map { $0.compact },
            [true],
            "\(failure) must not trigger any legacy full-transcript resume",
            file: file,
            line: line
        )
        XCTAssertFalse(
            harness.appState.errorMessage?.isEmpty ?? true,
            "\(failure) must surface a visible restore error",
            file: file,
            line: line
        )
    }

    func testTransientHistoryFailuresSurfaceWithoutLegacyResume() async throws {
        // A slow or failing BOUNDED history request must never become the
        // giant-payload path: timeouts, rate limits, ordinary 5xx, status-0
        // WebKit failures, and a bridge that outlived its readiness window
        // all surface a retryable restore error instead of requesting the
        // entire transcript over the WebSocket. (Current Hermes can serve
        // the include_compacted page slowly for heavily compacted sessions
        // until upstream #97440 bounds that work server-side.)
        let transientFailures: [Error] = [
            DashboardTicketBridgeError.http(status: 408, detail: "Request Timeout"),
            DashboardTicketBridgeError.http(status: 429, detail: "Too Many Requests"),
            DashboardTicketBridgeError.http(status: 500, detail: "Internal error"),
            DashboardTicketBridgeError.http(status: 503, detail: "Service Unavailable"),
            DashboardTicketBridgeError.http(status: 0, detail: "Failed to fetch"),
            DashboardTicketBridgeError.notReady,
        ]
        for failure in transientFailures {
            try await assertTransientHistoryFailureSurfacesWithoutLegacyResume(failure)
        }
    }

    func testStructuralHistoryEndpointGapsFallBackExactlyOnce() async throws {
        // Gateways predating the history endpoint are the one case where the
        // legacy full-transcript resume remains the compatibility path: the
        // endpoint cannot serve ANY page, bounded or not. Exactly one legacy
        // resume, and the fallback never cascades.
        for status in [404, 410, 501] {
            let recorder = ResumeCallRecorder()
            let active = session("stored-structural")
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
                                content: "Legacy transcript",
                                timestamp: "2026-09-01T08:00:00Z"
                            )
                        ],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    .failed(DashboardTicketBridgeError.http(status: status, detail: "missing endpoint"))
                }
            )
            harness.appState.sessions = [active]

            let opened = await harness.appState.openSession("stored-structural")

            XCTAssertTrue(opened, "status \(status) must fall back instead of failing the resume")
            XCTAssertEqual(
                recorder.calls.map { $0.compact },
                [true, false],
                "status \(status) must trigger exactly one legacy resume"
            )
            XCTAssertEqual(harness.appState.messages.map { $0.content }, ["Legacy transcript"])
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

    func testColdDashboardBridgeBeginsCompactAndNeverEscalatesToLegacy() async throws {
        // Regression for the cold-launch hole AND the giant-session safety
        // property: a dashboard bridge that exists but is not ready yet must
        // not push the resume onto the legacy full-transcript path — neither
        // immediately nor after its bounded readiness window expires. The
        // resume begins compact; a bridge that never becomes usable surfaces
        // a retryable restore error instead of requesting the entire
        // transcript over the WebSocket.
        let recorder = ResumeCallRecorder()
        let active = session("stored-cold")
        let harness = try makeHarness(
            openSession: { _, sessionID, compact in
                recorder.record(sessionID: sessionID, compact: compact)
                return SessionResumeResult(
                    sessionId: sessionID,
                    messages: [],
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

        XCTAssertFalse(
            recorder.calls.isEmpty,
            "The resume must have begun on the compact transport"
        )
        XCTAssertTrue(
            recorder.calls.allSatisfy { $0.compact },
            "A cold bridge must never trigger a legacy full-transcript resume, got: \(recorder.calls.map { $0.compact })"
        )
        XCTAssertFalse(
            harness.appState.errorMessage?.isEmpty ?? true,
            "The bounded history failure must surface to the user"
        )
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
        // ONLY structural endpoint absence degrades to the legacy resume /
        // retires the backfill affordance: 404/410 gateways without the
        // messages route, and 501 explicitly-unimplemented.
        for status in [404, 410, 501] {
            XCTAssertTrue(
                AppState.historySourceIsUnavailable(
                    DashboardTicketBridgeError.http(status: status, detail: "missing")
                ),
                "status \(status) must be classified as unavailable"
            )
        }
        // Transient transport trouble must SURFACE (initial hydration) or
        // stay tap-retryable (backfill) instead of silently escalating into
        // the unbounded legacy transcript transport: rate limits, timeouts,
        // ordinary 5xx, status-0 WebKit failures, and a bridge that never
        // became ready or a request that outlived its deadline.
        for status in [0, 408, 429, 500, 502, 503, 504] {
            XCTAssertFalse(
                AppState.historySourceIsUnavailable(
                    DashboardTicketBridgeError.http(status: status, detail: "transient")
                ),
                "status \(status) must not be classified as unavailable"
            )
        }
        XCTAssertFalse(AppState.historySourceIsUnavailable(DashboardTicketBridgeError.notReady))
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

    /// The bridge-level oversized error is generic — it can arise from any
    /// oversized dashboard response (workspace-file reads, catalogs), not
    /// only transcript history — so its copy must be neutral.
    /// Transcript-specific compatibility messaging is mapped in the
    /// transcript layer (see the oversized-history tests below).
    func testGenericOversizedBridgeErrorUsesNeutralCopy() {
        let error = DashboardTicketBridgeError.oversizedResponse(limit: DataURLLimits.maxJSONResponseBytes)
        XCTAssertEqual(error.errorDescription, "This response is too large to load safely.")
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
        XCTAssertTrue(
            harness.appState.persistedTranscriptWindow?.hasBackfilledPrefix ?? false,
            "A published prepend must mark the backfilled prefix"
        )
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
                // Row ids start at 1: SQLite AUTOINCREMENT never produces 0.
                return self.tailPagePayload(
                    sessionId: "stored-b",
                    rows: self.syntheticRows(1..<3),
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
        XCTAssertEqual(harness.appState.messages.first?.content, "Row 1")
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
    /// A bounded current-Hermes page that exceeds the safe response bound
    /// (one enormous physical row) surfaces NEUTRAL copy — the backend does
    /// have pagination, and no giant WebSocket retry may follow.
    func testOversizedBoundedHistorySurfacesNeutralError() async throws {
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

        XCTAssertFalse(opened, "The oversized-response error must surface")
        XCTAssertEqual(
            recorder.calls.map { $0.compact },
            [true],
            "No legacy full-transcript WebSocket retry may follow an oversized history response"
        )
        XCTAssertEqual(
            harness.appState.errorMessage,
            "This response is too large to load safely.",
            "A bounded page oversize must not claim the backend lacks pagination"
        )
    }

    /// A legacy one-shot transcript (an old backend attempting the entire
    /// conversation after the oldest-anchored echo was detected) that
    /// exceeds the safe bound surfaces the transcript-specific
    /// compatibility copy — and never retries over the WebSocket.
    func testOversizedLegacyOneShotSurfacesCompatibilityCopy() async throws {
        let fetchCalls = Counter()
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
                // The one-shot re-read of the full transcript outgrew the
                // safe bound.
                return .failed(DashboardTicketBridgeError.oversizedResponse(
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
            harness.appState.errorMessage?.contains("Update Hermes to enable paginated conversation history") == true,
            "A legacy one-shot oversize should carry the compatibility copy, got: \(harness.appState.errorMessage ?? "nil")"
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

    /// A backfill response whose session_id belongs to another conversation
    /// is rejected whole: no normalization into the transcript, no coverage
    /// advance, affordance retired.
    func testForeignBackfillResponseRejected() async throws {
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
                self.tailPagePayload(sessionId: "stored-b", rows: self.syntheticRows(0..<120), offset: offset)
            }
        )
        harness.appState.sessions = [active]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)

        let didPrepend = await harness.appState.loadEarlierMessages()

        XCTAssertFalse(didPrepend)
        XCTAssertEqual(harness.appState.messages.count, 120, "Foreign rows must never reach the transcript")
        XCTAssertFalse(harness.appState.messages.contains { $0.content == "Row 0" })
        XCTAssertEqual(
            harness.appState.persistedTranscriptWindow?.nextOffset, 120,
            "Foreign responses must not advance pagination coverage"
        )
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.canLoadEarlier, false)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.isLoadingEarlier, false)
    }

    /// A backfill page whose rows lack durable persisted IDs would dedup on
    /// page-local positional identities that cannot survive across pages —
    /// refuse it instead of silently corrupting overlap dedup.
    func testBackfillPageWithoutDurableIdsRetiresAffordance() async throws {
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
                .payload([
                    "session_id": "stored-a",
                    "messages": [
                        // Missing id entirely…
                        ["role": "user", "content": "Id-less row", "timestamp": "2026-09-01T10:00:00Z"],
                        // …and an empty-string id, which would likewise
                        // collapse every such row onto one dedup key.
                        ["id": "", "role": "user", "content": "Empty-id row", "timestamp": "2026-09-01T10:00:01Z"]
                    ],
                    "pagination": ["limit": 120, "offset": offset, "order": "latest", "returned": 2]
                ])
            }
        )
        harness.appState.sessions = [active]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)

        let didPrepend = await harness.appState.loadEarlierMessages()

        XCTAssertFalse(didPrepend)
        XCTAssertEqual(harness.appState.messages.count, 120, "The transcript stays untouched")
        XCTAssertFalse(harness.appState.messages.contains { $0.content == "Id-less row" })
        XCTAssertFalse(harness.appState.messages.contains { $0.content == "Empty-id row" })
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.canLoadEarlier, false)
        XCTAssertEqual(
            harness.appState.persistedTranscriptWindow?.nextOffset, 120,
            "No coverage advance for an unusable page"
        )
    }

    /// A page boundary can split a tool call from its result row: the call
    /// row is the last row of the older page, its result the first row of
    /// the loaded newer page. One logical tool run must reconstruct — never
    /// an orphan call card plus a duplicate standalone result.
    func testToolCallSplitAcrossPageBoundaryReconstructsOneRun() async throws {
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
                var resultRow = self.transcriptRow(1880, role: "tool", content: "file body")
                resultRow["tool_call_id"] = "call_123"
                resultRow["name"] = "read_file"
                let rows = [resultRow] + self.syntheticRows(1881..<2000)
                return self.tailPagePayload(sessionId: "stored-a", rows: rows, offset: 0)
            },
            loadEarlierTranscriptPage: { _, _, offset in
                var callRow = self.transcriptRow(1879, role: "assistant", content: "")
                callRow["tool_calls"] = [[
                    "id": "call_123",
                    "type": "function",
                    "function": [
                        "name": "read_file",
                        "arguments": "{\"path\": \"/tmp/row1879\"}"
                    ]
                ]]
                let rows = self.syntheticRows(1760..<1879) + [callRow]
                return self.tailPagePayload(sessionId: "stored-a", rows: rows, offset: offset)
            }
        )
        harness.appState.sessions = [active]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)
        // The unmatched result hydrates as a standalone card on the newer
        // page (its call row is not in that page).
        XCTAssertEqual(harness.appState.messages.count, 120)
        XCTAssertEqual(harness.appState.messages.first?.role, .tool)
        XCTAssertEqual(harness.appState.messages.first?.tool?.id, "call_123")

        await harness.appState.loadEarlierMessages()

        let messages = harness.appState.messages
        XCTAssertEqual(messages.count, 120 + 120 - 1, "The standalone result card folds away into its call card")
        let callCards = messages.filter { $0.tool?.id == "call_123" }
        XCTAssertEqual(callCards.count, 1, "Exactly one card for the durable tool-call identity")
        XCTAssertEqual(callCards.first?.id, "1879.0-tool-0")
        XCTAssertEqual(callCards.first?.tool?.name, "read_file")
        XCTAssertEqual(callCards.first?.tool?.input, "{\"path\": \"/tmp/row1879\"}")
        XCTAssertEqual(callCards.first?.tool?.output, "file body")
        XCTAssertEqual(callCards.first?.tool?.status, .complete)
        XCTAssertFalse(
            messages.contains { $0.id == "1880.0" },
            "No orphan standalone result may remain"
        )
        XCTAssertEqual(messages.last?.content, "Row 1999", "The loaded tail stays intact")
        XCTAssertTrue(harness.appState.persistedTranscriptWindow?.hasBackfilledPrefix ?? false)
    }

    /// A single assistant turn can carry any number of tool calls. A page
    /// boundary splitting one 12-call run from its 12 result rows must
    /// reconstruct every pair — no pair ceiling, no orphan standalone
    /// results, one completed card per durable tool_call_id.
    func testTwelveToolCallRunSplitAcrossPageBoundaryReconstructsFully() async throws {
        let callCount = 12
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
                // Newer page: 12 unmatched result rows (their call row is on
                // the older page) followed by the untouched loaded tail.
                let resultRows = (1...callCount).map { index -> [String: Any] in
                    var row = self.transcriptRow(1879 + index, role: "tool", content: "body \(index)")
                    row["tool_call_id"] = "call_\(index)"
                    row["name"] = "read_file"
                    return row
                }
                let rows = resultRows + self.syntheticRows((1880 + callCount)..<2000)
                return self.tailPagePayload(sessionId: "stored-a", rows: rows, offset: 0)
            },
            loadEarlierTranscriptPage: { _, _, offset in
                // Older page: 111 conversational rows, then ONE assistant
                // row carrying all 12 tool calls as its final row.
                var callRow = self.transcriptRow(1879, role: "assistant", content: "")
                callRow["tool_calls"] = (1...callCount).map { index in
                    [
                        "id": "call_\(index)",
                        "type": "function",
                        "function": [
                            "name": "read_file",
                            "arguments": "{\"path\": \"/tmp/row\(index)\"}"
                        ]
                    ]
                }
                let rows = self.syntheticRows(1768..<1879) + [callRow]
                return self.tailPagePayload(sessionId: "stored-a", rows: rows, offset: offset)
            }
        )
        harness.appState.sessions = [active]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)
        // Every unmatched result hydrates as a standalone card on the newer
        // page (their call row is not in that page).
        XCTAssertEqual(harness.appState.messages.count, 120)
        XCTAssertEqual(
            harness.appState.messages.prefix(callCount).compactMap { $0.tool?.id },
            (1...callCount).map { "call_\($0)" }
        )

        await harness.appState.loadEarlierMessages()

        let messages = harness.appState.messages
        XCTAssertEqual(
            messages.count,
            (111 + callCount) + (120 - callCount),
            "123 adjusted older-page messages prepended onto the 108 held rows left after the 12 folds"
        )
        let callCards = messages.filter { $0.role == .tool && $0.tool?.id?.hasPrefix("call_") == true }
        XCTAssertEqual(callCards.count, callCount, "Exactly one logical card per durable tool_call_id")
        XCTAssertEqual(
            Set(callCards.compactMap { $0.tool?.id }),
            Set((1...callCount).map { "call_\($0)" }),
            "No duplicate tool-call identities"
        )
        for index in 1...callCount {
            let card = messages.first { $0.tool?.id == "call_\(index)" }
            XCTAssertNotNil(card, "call_\(index) must have its card")
            XCTAssertEqual(card?.id, "1879.0-tool-\(index - 1)")
            XCTAssertEqual(card?.tool?.name, "read_file")
            XCTAssertEqual(card?.tool?.input, "{\"path\": \"/tmp/row\(index)\"}")
            XCTAssertEqual(card?.tool?.output, "body \(index)")
            XCTAssertEqual(card?.tool?.status, .complete)
        }
        // The dropped standalone result cards occupied row ids 1880–1891.
        let orphanIDs = Set((1880...(1879 + callCount)).map { "\($0).0" })
        XCTAssertFalse(
            messages.contains { orphanIDs.contains($0.id) },
            "No orphan standalone result card may remain"
        )
        // Chronology stays intact across the fold, and the loaded newer
        // tail after the tool results is untouched.
        let rowIndexes = messages.compactMap { message -> Int? in
            guard message.content.hasPrefix("Row ") else { return nil }
            return Int(message.content.dropFirst(4))
        }
        XCTAssertEqual(rowIndexes, Array(1768...1878) + Array((1880 + callCount)...1999))
        XCTAssertEqual(messages[110].content, "Row 1878", "Last conversational row before the call block")
        XCTAssertEqual(messages[111 + callCount].content, "Row 1892", "The newer tail resumes immediately after the folded block")
        XCTAssertTrue(harness.appState.persistedTranscriptWindow?.hasBackfilledPrefix ?? false)
    }

    // MARK: - Window conversation-identity ownership

    /// THE production no-op regression: a long stored session opens, the
    /// bounded tail hydrates, and `session.resume` re-homes
    /// `activeSessionId` to a runtime ID the session catalog has NOT
    /// learned as an alias. The window's transaction-captured identity must
    /// keep the backfill owned and actionable — the old catalog-alias gate
    /// silently early-returned before any request, spinner, or error, while
    /// the button stayed visible.
    func testBackfillWorksWithoutCatalogLearningRuntimeAlias() async throws {
        let backfillCalls = BackfillCallRecorder()
        // Catalog contains ONLY stored-a; runtime-a appears nowhere in it.
        let active = session("stored-a")
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
            loadEarlierTranscriptPage: { sessionId, profile, offset in
                backfillCalls.record(sessionId: sessionId, profile: profile, offset: offset)
                return self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1760..<1880), offset: offset)
            }
        )
        harness.appState.sessions = [active]

        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)

        // The resume re-homed the active identity to the runtime ID, and
        // the window captured the whole accepted transaction.
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-a")
        let window = harness.appState.persistedTranscriptWindow
        XCTAssertEqual(window?.requestedSessionID, "stored-a")
        XCTAssertEqual(window?.resolvedSessionID, "stored-a")
        XCTAssertEqual(window?.runtimeSessionID, "runtime-a")
        XCTAssertEqual(window?.canLoadEarlier, true)
        XCTAssertTrue(
            harness.appState.canLoadEarlierMessagesForActiveConversation,
            "The affordance must stay actionable before the catalog learns the runtime↔stored alias"
        )

        let didPrepend = await harness.appState.loadEarlierMessages()

        XCTAssertTrue(didPrepend, "Backfill must run — not silently early-return — without catalog aliases")
        XCTAssertEqual(backfillCalls.calls.count, 1, "The older-page loader must be invoked exactly once")
        XCTAssertEqual(backfillCalls.calls.first?.sessionId, "stored-a", "The persisted-history request must use the stored session ID")
        XCTAssertEqual(backfillCalls.calls.first?.profile, "default")
        XCTAssertEqual(backfillCalls.calls.first?.offset, 120)
        XCTAssertEqual(harness.appState.messages.count, 240)
        XCTAssertEqual(harness.appState.messages.first?.content, "Row 1760")
        XCTAssertEqual(harness.appState.messages.last?.content, "Row 1999")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.nextOffset, 240)
        XCTAssertTrue(harness.appState.persistedTranscriptWindow?.hasBackfilledPrefix ?? false)
    }

    /// A requested runtime alias that resolves to a DIFFERENT stored ID:
    /// backfill continues against the resolved stored ID (Desktop's
    /// `BackfillRequest.storedSessionId` contract) while ownership stays
    /// with the active runtime conversation.
    func testBackfillUsesResolvedStoredIDWhenOpenedViaRuntimeAlias() async throws {
        let backfillCalls = BackfillCallRecorder()
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
            loadEarlierTranscriptPage: { sessionId, profile, offset in
                backfillCalls.record(sessionId: sessionId, profile: profile, offset: offset)
                XCTAssertEqual(
                    sessionId, "stored-a",
                    "Persisted-history reads continue against the stored ID, never the requested runtime alias"
                )
                return self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1760..<1880), offset: offset)
            }
        )
        harness.appState.sessions = [active]

        let opened = await harness.appState.openSession("runtime-a")
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-a")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.requestedSessionID, "runtime-a")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.resolvedSessionID, "stored-a")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.runtimeSessionID, "runtime-a")

        let didPrepend = await harness.appState.loadEarlierMessages()

        XCTAssertTrue(didPrepend)
        XCTAssertEqual(backfillCalls.calls.first?.sessionId, "stored-a")
        XCTAssertEqual(backfillCalls.calls.first?.offset, 120)
        XCTAssertEqual(harness.appState.messages.count, 240)
        XCTAssertTrue(harness.appState.canLoadEarlierMessagesForActiveConversation)
    }

    /// A backfill resolving after a session switch is discarded even with a
    /// catalog that never learned any runtime aliases: session B's
    /// transcript is untouched and session A's coverage is not published
    /// into it.
    func testStaleBackfillDiscardedAfterSwitchWithoutCatalogAliases() async throws {
        let backfillStarted = Flag()
        let sessionA = session("stored-a")
        let sessionB = session("stored-b")
        let harness = try makeHarness(
            openSession: { _, sessionID, _ in
                SessionResumeResult(
                    sessionId: sessionID == "stored-a" ? "runtime-a" : "runtime-b",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { sessionId, _ in
                if sessionId == "stored-a" {
                    return self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1880..<2000), offset: 0)
                }
                return self.tailPagePayload(sessionId: "stored-b", rows: self.syntheticRows(1..<3), offset: 0)
            },
            loadEarlierTranscriptPage: { sessionId, _, offset in
                backfillStarted.isOn = true
                XCTAssertEqual(sessionId, "stored-a")
                try? await Task.sleep(for: .milliseconds(250))
                return self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1760..<1880), offset: offset)
            }
        )
        harness.appState.sessions = [sessionA, sessionB]
        let openedA = await harness.appState.openSession("stored-a")
        XCTAssertTrue(openedA)
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-a")

        let backfill = Task { await harness.appState.loadEarlierMessages() }
        for _ in 0..<1_000 where !backfillStarted.isOn {
            await Task.yield()
        }
        XCTAssertTrue(backfillStarted.isOn, "The backfill fetch must have started")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.isLoadingEarlier, true)

        let openedB = await harness.appState.openSession("stored-b")
        XCTAssertTrue(openedB)
        let didPrependStale = await backfill.value
        XCTAssertFalse(didPrependStale, "The stale session-A page must not publish")

        XCTAssertEqual(harness.appState.messages.count, 2, "Session B must be completely unchanged by the stale page")
        XCTAssertEqual(harness.appState.messages.first?.content, "Row 1")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.requestedSessionID, "stored-b")
        XCTAssertFalse(
            harness.appState.persistedTranscriptWindow?.hasBackfilledPrefix ?? true,
            "Session A's backfill coverage must not be published into session B"
        )
        XCTAssertFalse(harness.appState.messages.contains { $0.id == "1760" }, "No session-A row may leak into session B")
    }

    /// A window from a genuinely different conversation must neither show
    /// an actionable control nor issue a request.
    func testForeignActiveSessionHidesAffordanceAndRejectsBackfill() async throws {
        let backfillCalls = BackfillCallRecorder()
        let active = session("stored-a")
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
            loadEarlierTranscriptPage: { sessionId, profile, offset in
                backfillCalls.record(sessionId: sessionId, profile: profile, offset: offset)
                return self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1760..<1880), offset: offset)
            }
        )
        harness.appState.sessions = [active]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)
        XCTAssertTrue(harness.appState.canLoadEarlierMessagesForActiveConversation)

        // A different conversation becomes active — no alias relationship
        // with the window's stored/runtime identities.
        harness.appState.activeSessionId = "runtime-b"

        XCTAssertFalse(
            harness.appState.canLoadEarlierMessagesForActiveConversation,
            "A foreign active session must not show an actionable control"
        )
        let didPrepend = await harness.appState.loadEarlierMessages()
        XCTAssertFalse(didPrepend)
        XCTAssertEqual(backfillCalls.calls.count, 0, "No network request may be issued for a foreign conversation")
    }

    /// The catalog learning the stored↔runtime alias LATER must not reset
    /// or re-own the history window: the transaction-derived identity stays
    /// sufficient before and after the refresh.
    func testCatalogLearningAliasLaterPreservesWindowAndOwnership() async throws {
        let backfillCalls = BackfillCallRecorder()
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
            loadEarlierTranscriptPage: { sessionId, profile, offset in
                backfillCalls.record(sessionId: sessionId, profile: profile, offset: offset)
                return self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1760..<1880), offset: offset)
            }
        )
        harness.appState.sessions = [session("stored-a")]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)
        let windowBefore = harness.appState.persistedTranscriptWindow
        XCTAssertEqual(windowBefore?.runtimeSessionID, "runtime-a")

        // The catalog later learns the alias.
        harness.appState.sessions = [session("stored-a", alternateIDs: ["runtime-a"])]

        XCTAssertEqual(
            harness.appState.persistedTranscriptWindow, windowBefore,
            "A catalog refresh must not reset or rewrite the history window"
        )
        XCTAssertTrue(harness.appState.canLoadEarlierMessagesForActiveConversation)

        let didPrepend = await harness.appState.loadEarlierMessages()
        XCTAssertTrue(didPrepend)
        XCTAssertEqual(backfillCalls.calls.count, 1)
        XCTAssertEqual(backfillCalls.calls.first?.sessionId, "stored-a")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.nextOffset, 240)
    }

    /// The exact production sequence end to end: backfill under a catalog
    /// that never learned the runtime↔stored alias, then a
    /// reconnect/reconcile — the backfilled prefix survives, ownership
    /// holds, and continued backfilling still routes by the stored ID.
    /// (The harness reuses one runtime ID per stored session; a backend
    /// minting a FRESH runtime ID per resume is still safe because the
    /// reconcile rebuilds the window inside the same accepted transaction
    /// — the graft gate then compares that new transaction's full identity
    /// against the previous window's.)
    func testReconnectGraftSurvivesStaleCatalogAliases() async throws {
        let holdsRefreshedTail = Flag()
        let backfillCalls = BackfillCallRecorder()
        let active = session("stored-a")
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
            loadEarlierTranscriptPage: { sessionId, profile, offset in
                backfillCalls.record(sessionId: sessionId, profile: profile, offset: offset)
                if backfillCalls.calls.count == 1 {
                    return self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1760..<1880), offset: offset)
                }
                return self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1640..<1760), offset: offset)
            },
            additionalOperations: { ops in
                ops.connectClient = { _ in }
                // The refreshed catalog STILL lacks the runtime alias.
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

        let didPrepend = await harness.appState.loadEarlierMessages()
        XCTAssertTrue(didPrepend)
        XCTAssertEqual(harness.appState.messages.count, 240)
        XCTAssertEqual(backfillCalls.calls.first?.sessionId, "stored-a")

        // The reconnect re-reconciles under the stored ID while the catalog
        // is still alias-stale; resume re-homes active to runtime-a again.
        holdsRefreshedTail.isOn = true
        harness.coordinator.rememberSessionID("stored-a", for: "default")
        await harness.appState.connect(
            with: HermesConnection(baseUrl: "https://one.example", ticket: "stale-alias-graft")
        )

        // Backfilled prefix (rows 1760–1899) plus the refreshed tail
        // (rows 1900–2019) — not truncated to the refreshed tail alone.
        XCTAssertEqual(harness.appState.messages.count, 140 + 120)
        XCTAssertEqual(harness.appState.messages.first?.content, "Row 1760")
        XCTAssertEqual(harness.appState.messages[139].content, "Row 1899")
        XCTAssertEqual(harness.appState.messages[140].content, "Row 1900")
        XCTAssertEqual(harness.appState.messages.last?.content, "Row 2019")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.requestedSessionID, "stored-a")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.runtimeSessionID, "runtime-a")
        XCTAssertTrue(harness.appState.persistedTranscriptWindow?.hasBackfilledPrefix ?? false)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.nextOffset, 120)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.canLoadEarlier, true)
        XCTAssertTrue(
            harness.appState.canLoadEarlierMessagesForActiveConversation,
            "Ownership must survive the reconnect without catalog aliases"
        )

        // Continued backfilling after the reconnect still uses the stored ID.
        let didPrependAfter = await harness.appState.loadEarlierMessages()
        XCTAssertTrue(didPrependAfter)
        XCTAssertEqual(backfillCalls.calls.count, 2)
        XCTAssertEqual(backfillCalls.calls.last?.sessionId, "stored-a")
        XCTAssertEqual(backfillCalls.calls.last?.offset, 120)
        XCTAssertEqual(harness.appState.messages.count, 380, "Rows 1640–1759 prepend onto the grafted transcript")
        XCTAssertEqual(harness.appState.messages.first?.content, "Row 1640")
    }

    /// The centralized identity rule behind every window-ownership check:
    /// explicit transaction-captured overlap is primary truth, catalog
    /// aliases only assist, and a profile mismatch always rejects.
    func testWindowOwnershipIdentityRule() {
        func expanded(_ ids: Set<String>, catalog: [String: Set<String>]) -> Set<String> {
            ids.reduce(into: Set<String>()) { out, id in out.formUnion(catalog[id] ?? [id]) }
        }
        let window = PersistedTranscriptWindowState(
            requestedSessionID: "stored-a",
            profile: "default",
            pageSize: 120,
            resolvedSessionID: "stored-a",
            runtimeSessionID: "runtime-a",
            nextOffset: 120,
            canLoadEarlier: true
        )
        func holds(
            active: String,
            profile: String = "default",
            catalog: [String: Set<String>] = [:]
        ) -> Bool {
            let conversationIds = Set([active])
            return PersistedTranscriptWindow.ownershipHolds(
                window: window,
                conversationSessionIds: conversationIds,
                profile: profile,
                windowAliasIds: expanded(window.trustedSessionIDs, catalog: catalog),
                conversationAliasIds: expanded(conversationIds, catalog: catalog)
            )
        }

        // Active runtime conversation, catalog ignorant of the alias:
        // owned through the transaction-captured runtime ID alone.
        XCTAssertTrue(holds(active: "runtime-a"))
        XCTAssertTrue(holds(active: "stored-a"))
        // Catalog alias knowledge still proves equivalence either direction.
        XCTAssertTrue(holds(
            active: "runtime-x",
            catalog: ["runtime-x": ["runtime-x", "stored-a"]]
        ))
        XCTAssertTrue(holds(
            active: "runtime-x",
            catalog: ["stored-a": ["stored-a", "runtime-x"]]
        ))
        // A genuinely foreign conversation with no proven alias rejects.
        XCTAssertFalse(holds(active: "runtime-b"))
        XCTAssertFalse(holds(active: "stored-b", catalog: ["stored-b": ["stored-b", "runtime-b"]]))
        // Profile mismatch rejects even with explicit ID overlap.
        XCTAssertFalse(holds(active: "runtime-a", profile: "work"))
    }

    /// If ownership is lost MID-FLIGHT while the armed window itself
    /// survived (e.g. a disconnect clears `activeSessionId` without a
    /// reconcile replacing the window), the response is discarded whole AND
    /// the single-flight flag is released — the affordance can re-arm later
    /// instead of spinning forever.
    func testOwnershipLossMidFlightReleasesLoadingFlag() async throws {
        let backfillCalls = BackfillCallRecorder()
        let active = session("stored-a")
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
            loadEarlierTranscriptPage: { sessionId, profile, offset in
                backfillCalls.record(sessionId: sessionId, profile: profile, offset: offset)
                try? await Task.sleep(for: .milliseconds(150))
                return self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1760..<1880), offset: offset)
            }
        )
        harness.appState.sessions = [active]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)

        let backfill = Task { await harness.appState.loadEarlierMessages() }
        // Detach the conversation identity WITHOUT replacing the window —
        // the ownership-lost-but-window-survived shape.
        for _ in 0..<1_000 where backfillCalls.calls.isEmpty {
            await Task.yield()
        }
        harness.appState.activeSessionId = "runtime-b"
        let didPrepend = await backfill.value

        XCTAssertFalse(didPrepend, "The response must be discarded once the conversation moved on")
        XCTAssertEqual(harness.appState.messages.count, 120, "The transcript stays untouched")
        XCTAssertFalse(
            harness.appState.persistedTranscriptWindow?.isLoadingEarlier ?? true,
            "The single-flight flag must be released, not stranded"
        )

        // Re-owning the conversation re-arms the affordance and backfill works.
        harness.appState.activeSessionId = "runtime-a"
        XCTAssertTrue(harness.appState.canLoadEarlierMessagesForActiveConversation)
        let didPrependRetry = await harness.appState.loadEarlierMessages()
        XCTAssertTrue(didPrependRetry)
        XCTAssertEqual(backfillCalls.calls.count, 2)
        XCTAssertEqual(harness.appState.messages.count, 240)
    }

    /// A `/messages` response without a `session_id` echo (legacy backend
    /// shape) leaves the window without a resolved stored ID: older-page
    /// requests fall back to the requested session ID.
    func testBackfillFallsBackToRequestedIDWhenHydrationEchoesNoSessionID() async throws {
        let backfillCalls = BackfillCallRecorder()
        let active = session("stored-a")
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(
                    sessionId: "runtime-a",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _ in
                // Tail page under the current contract, but with NO
                // `session_id` echo.
                .payload([
                    "messages": self.syntheticRows(1880..<2000),
                    "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 120]
                ])
            },
            loadEarlierTranscriptPage: { sessionId, profile, offset in
                backfillCalls.record(sessionId: sessionId, profile: profile, offset: offset)
                XCTAssertEqual(sessionId, "stored-a", "No resolved stored ID: fall back to the requested ID")
                return self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1760..<1880), offset: offset)
            }
        )
        harness.appState.sessions = [active]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)
        XCTAssertNil(harness.appState.persistedTranscriptWindow?.resolvedSessionID)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.runtimeSessionID, "runtime-a")

        let didPrepend = await harness.appState.loadEarlierMessages()

        XCTAssertTrue(didPrepend)
        XCTAssertEqual(backfillCalls.calls.first?.sessionId, "stored-a")
        XCTAssertEqual(backfillCalls.calls.first?.offset, 120)
        XCTAssertEqual(harness.appState.messages.count, 240)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.nextOffset, 240)
    }

    /// An older-page response that echoes the TRANSACTION-CAPTURED runtime
    /// ID is still this conversation's rows: the accepted resume proved
    /// that identity, so the page must not be rejected as foreign.
    func testBackfillAcceptsResponseEchoingTransactionRuntimeID() async throws {
        let active = session("stored-a")
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
                self.tailPagePayload(sessionId: "runtime-a", rows: self.syntheticRows(1760..<1880), offset: offset)
            }
        )
        harness.appState.sessions = [active]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)

        let didPrepend = await harness.appState.loadEarlierMessages()

        XCTAssertTrue(didPrepend, "An echo of the window's own resume-proven runtime ID is not foreign")
        XCTAssertEqual(harness.appState.messages.count, 240)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.canLoadEarlier, true, "The affordance must not be retired")
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

    /// Records every older-page backfill request: the wire session ID, the
    /// routing profile, and the offset — the identity contract of "Load
    /// earlier messages".
    private final class BackfillCallRecorder {
        private(set) var calls: [(sessionId: String, profile: String, offset: Int)] = []
        func record(sessionId: String, profile: String, offset: Int) {
            calls.append((sessionId, profile, offset))
        }
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
