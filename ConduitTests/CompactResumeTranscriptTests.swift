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

    func testLegacyFallbackHydratesSessionExceedingTransportBound() async throws {
        // The issue-sanctioned legacy fallback (history source unavailable)
        // must deterministically hydrate a transcript far larger than the new
        // 4 MiB socket bound as well: the durable rows arrive through the
        // fallback resume, and the assertion proves the fixture really is
        // bigger than the transport bound without pushing traffic over a
        // live WebSocket.
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
        let payloadBytes = legacyMessages
            .reduce(0) { $0 + $1.content.utf8.count }
        XCTAssertGreaterThan(payloadBytes, 4 * 1024 * 1024, "The fixture must exceed the new transport bound")

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

    func testHistorySourceUnavailableClassificationMatchesOnlyUsableSourceGaps() {
        // Structural endpoint gaps and a not-yet-usable bridge fall back to
        // the legacy resume…
        XCTAssertTrue(AppState.historySourceIsUnavailable(
            DashboardTicketBridgeError.http(status: 404, detail: "Not Found")
        ))
        XCTAssertTrue(AppState.historySourceIsUnavailable(
            DashboardTicketBridgeError.http(status: 410, detail: "Gone")
        ))
        XCTAssertTrue(AppState.historySourceIsUnavailable(
            DashboardTicketBridgeError.http(status: 501, detail: "Not Implemented")
        ))
        XCTAssertTrue(AppState.historySourceIsUnavailable(DashboardTicketBridgeError.notReady))
        // …while transient or environmental failures do not.
        XCTAssertFalse(AppState.historySourceIsUnavailable(
            DashboardTicketBridgeError.http(status: 500, detail: "Internal error")
        ))
        XCTAssertFalse(AppState.historySourceIsUnavailable(
            DashboardTicketBridgeError.http(status: 0, detail: "network failure")
        ))
        XCTAssertFalse(AppState.historySourceIsUnavailable(DashboardTicketBridgeError.signInRequired))
        XCTAssertFalse(AppState.historySourceIsUnavailable(
            DashboardTicketBridgeError.requestFailed("Dashboard request failed (500).")
        ))
    }

    // MARK: - Harness

    private func makeHarness(
        openSession: @escaping @MainActor (HermesClient, String, Bool) async throws -> SessionResumeResult,
        persistedTranscript: (@MainActor (String, String) async -> PersistedTranscriptFetchOutcome)? = nil
    ) throws -> (appState: AppState, defaults: UserDefaults) {
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

        let store = ChatResumeStore(defaults: defaults)
        let appState = AppState(
            defaults: defaults,
            chatResumeCoordinator: ChatResumeCoordinator(store: store),
            recoverySequence: ChatResumeRecoverySequence(),
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: ChatResumeLifecycleOperations(
                openSession: openSession,
                persistedTranscript: persistedTranscript,
                refreshContext: { _, _ in }
            ),
            sessionPresentationCache: SessionPresentationCache(defaults: cacheDefaults)
        )
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        return (appState, defaults)
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
