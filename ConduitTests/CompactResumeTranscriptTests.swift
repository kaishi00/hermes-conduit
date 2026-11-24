import XCTest
import SwiftUI
import UIKit
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
            persistedTranscript: { _, _, _ in
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
            persistedTranscript: { _, _, _ in
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
            persistedTranscript: { _, _, _ in
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

    func testCompactResumeOfATurnSeveralStepsInKeepsOnlyTheStepBeingWritten() async throws {
        let active = session("stored-a", alternateIDs: ["runtime-a"])
        let firstStep = "Reading the logs first."
        let secondStep = "The logs are clean. Now the config."
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(
                    sessionId: "runtime-a",
                    messages: [],  // compact projection: transcript omitted
                    snapshot: SessionRuntimeSnapshot(
                        object: ["running": .bool(true)],
                        // Every delta of the turn, steps run together.
                        inflight: .object(["assistant": .string(firstStep + secondStep + "The config sets")])
                    )
                )
            },
            persistedTranscript: { _, _, _ in
                .payload([
                    "session_id": "stored-a",
                    "messages": [
                        [
                            "id": 1,
                            "role": "user",
                            "content": "Check the logs and the config.",
                            "timestamp": "2026-09-01T10:00:00Z"
                        ],
                        [
                            "id": 2,
                            "role": "assistant",
                            "content": firstStep,
                            "timestamp": "2026-09-01T10:00:04Z",
                            "tool_calls": [[
                                "id": "call_1",
                                "type": "function",
                                "function": ["name": "read_file", "arguments": "{\"path\": \"/var/log/app.log\"}"]
                            ]]
                        ],
                        [
                            "id": 3,
                            "role": "tool",
                            "tool_call_id": "call_1",
                            "content": "no errors",
                            "timestamp": "2026-09-01T10:00:05Z"
                        ],
                        [
                            "id": 4,
                            "role": "assistant",
                            "content": secondStep,
                            "timestamp": "2026-09-01T10:00:08Z",
                            "tool_calls": [[
                                "id": "call_2",
                                "type": "function",
                                "function": ["name": "read_file", "arguments": "{\"path\": \"/etc/app.conf\"}"]
                            ]]
                        ],
                        [
                            "id": 5,
                            "role": "tool",
                            "tool_call_id": "call_2",
                            "content": "mode = fast",
                            "timestamp": "2026-09-01T10:00:09Z"
                        ]
                    ]
                ])
            }
        )
        harness.appState.sessions = [active]

        let opened = await harness.appState.openSession("stored-a")

        XCTAssertTrue(opened)
        // The finished steps stay with their tool cards; the live bubble
        // holds only the step still being written.
        XCTAssertEqual(harness.appState.messages.filter { $0.role == .tool }.count, 2)
        XCTAssertTrue(harness.appState.messages.contains { $0.content == secondStep })
        harness.appState.showSidebar = true
        harness.appState.showSidebar = false
        XCTAssertEqual(harness.appState.streamingText, "The config sets")
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
            persistedTranscript: { _, _, _ in .payload(["session_id": "stored-a", "messages": rows]) }
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
            persistedTranscript: { _, _, _ in
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

    // MARK: - Hermes' resume size limit (issue 2025)

    private static let resumeTooLong = RpcError(
        code: 4130,
        message: "This session is too long to reload safely (20001 messages; limit 20000)."
    )

    /// Past `sessions.max_resume_messages` Hermes refuses the resume that
    /// carries the whole transcript but still resumes compact: the chat
    /// opens on that, with the history source's rows once it answers.
    func testAResumeTooLongForTheWholeTranscriptOpensCompact() async throws {
        let recorder = ResumeCallRecorder()
        var historyReads = 0
        let harness = try makeHarness(
            openSession: { _, sessionID, compact in
                recorder.record(sessionID: sessionID, compact: compact)
                if !compact { throw Self.resumeTooLong }
                return SessionResumeResult(
                    sessionId: sessionID,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _, _ in
                historyReads += 1
                // The history source wasn't ready for the first read.
                if historyReads == 1 { return .unavailable }
                return .payload([
                    "session_id": "stored-long",
                    "messages": [
                        ["id": 1, "role": "user", "content": "Still here?", "timestamp": "2026-11-08T10:00:00Z"],
                        ["id": 2, "role": "assistant", "content": "Yes.", "timestamp": "2026-11-08T10:00:02Z"]
                    ]
                ])
            }
        )
        harness.appState.sessions = [session("stored-long")]

        let opened = await harness.appState.openSession("stored-long")

        XCTAssertTrue(opened)
        XCTAssertEqual(recorder.calls.map { $0.compact }, [true, false, true])
        XCTAssertEqual(harness.appState.messages.map { $0.content }, ["Still here?", "Yes."])
        XCTAssertNil(harness.appState.errorMessage)
    }

    /// The chat on screen keeps its rows when Hermes refuses the whole
    /// transcript and no history source answers; the next read brings them
    /// up to date. With nothing to keep, the refusal shows, and a later
    /// resume of the chat that works takes it down again.
    func testAResumeTooLongKeepsTheRowsOnScreenAndItsErrorClearsOnceTheChatComesBack() async throws {
        var refusesWholeTranscript = false
        var historyAnswers = false
        let shown = [
            ChatMessage(id: "1", role: .user, content: "Long chat", timestamp: "2026-11-08T10:00:00Z"),
            ChatMessage(id: "2", role: .assistant, content: "Kept", timestamp: "2026-11-08T10:00:02Z")
        ]
        let harness = try makeHarness(
            openSession: { _, sessionID, compact in
                if !compact, refusesWholeTranscript { throw Self.resumeTooLong }
                return SessionResumeResult(
                    sessionId: sessionID,
                    messages: compact ? [] : shown,
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _, _ in
                historyAnswers
                    ? .payload([
                        "session_id": "stored-long",
                        "messages": [
                            ["id": 1, "role": "user", "content": "Long chat", "timestamp": "2026-11-08T10:00:00Z"],
                            ["id": 2, "role": "assistant", "content": "Kept", "timestamp": "2026-11-08T10:00:02Z"]
                        ]
                    ])
                    : .unavailable
            },
            additionalOperations: { ops in
                ops.connectClient = { _ in }
                ops.loadCatalog = { _, _ in [self.session("stored-long")] }
                ops.refreshContext = { _, _ in }
            }
        )
        harness.appState.sessions = [session("stored-long")]

        // Nothing on screen to keep: the refusal says why.
        refusesWholeTranscript = true
        let failedOpen = await harness.appState.openSession("stored-long")
        XCTAssertFalse(failedOpen)
        XCTAssertTrue(harness.appState.errorMessage?.contains("too long to reload safely") == true)

        // The chat comes back on the next resume: its error goes.
        historyAnswers = true
        await harness.appState.syncSession(purpose: .preserveCurrent, using: nil, automaticWorkToken: nil)
        XCTAssertEqual(harness.appState.messages.map { $0.content }, ["Long chat", "Kept"])
        XCTAssertNil(harness.appState.errorMessage)

        // Refused again with no history source: the rows on screen stay.
        // A source that isn't there can't be read before a send either, so
        // sends aren't held for it; the next return reads it.
        historyAnswers = false
        await harness.appState.syncSession(purpose: .preserveCurrent, using: nil, automaticWorkToken: nil)
        XCTAssertEqual(harness.appState.messages.map { $0.content }, ["Long chat", "Kept"])
        XCTAssertNil(harness.appState.errorMessage)
        XCTAssertFalse(harness.appState.transcriptFreshnessIsStale)
    }

    /// A history read that failed for now, after Hermes refused the whole
    /// transcript, keeps the rows on screen but unresolved, so the next send
    /// reads again.
    func testAResumeTooLongWithAFailedHistoryReadKeepsTheRowsUnresolved() async throws {
        var refusesWholeTranscript = false
        var historyReads = 0
        let shown = [
            ChatMessage(id: "1", role: .user, content: "Long chat", timestamp: "2026-11-08T10:00:00Z"),
            ChatMessage(id: "2", role: .assistant, content: "Kept", timestamp: "2026-11-08T10:00:02Z")
        ]
        let harness = try makeHarness(
            openSession: { _, sessionID, compact in
                if !compact, refusesWholeTranscript { throw Self.resumeTooLong }
                return SessionResumeResult(
                    sessionId: sessionID,
                    messages: compact ? [] : shown,
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _, _ in
                historyReads += 1
                // The open reads no source and takes the legacy rows. After
                // the refusal, the compact path's read finds no source either
                // and the retry's read fails for now.
                guard refusesWholeTranscript, historyReads > 1 else { return .unavailable }
                return .failed(DashboardTicketBridgeError.http(status: 503, detail: "Service Unavailable"))
            },
            additionalOperations: { ops in
                ops.connectClient = { _ in }
                ops.loadCatalog = { _, _ in [self.session("stored-long")] }
                ops.refreshContext = { _, _ in }
            }
        )
        harness.appState.sessions = [session("stored-long")]
        let opened = await harness.appState.openSession("stored-long")
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map { $0.content }, ["Long chat", "Kept"])

        refusesWholeTranscript = true
        historyReads = 0
        await harness.appState.syncSession(purpose: .preserveCurrent, using: nil, automaticWorkToken: nil)
        XCTAssertEqual(harness.appState.messages.map { $0.content }, ["Long chat", "Kept"])
        XCTAssertNil(harness.appState.errorMessage)
        XCTAssertTrue(harness.appState.transcriptFreshnessIsStale)
    }

    /// Kept rows keep their paging window, so what Load earlier brought in
    /// survives; a page naming another chat leaves them unresolved.
    func testAResumeTooLongKeepsThePagingWindowAndAForeignPageLeavesTheRowsUnresolved() async throws {
        enum History { case page, none, foreign }
        var refusesWholeTranscript = false
        var history = History.page
        let rows: [[String: Any]] = [
            ["id": 1, "role": "user", "content": "Long chat", "timestamp": "2026-11-08T10:00:00Z"],
            ["id": 2, "role": "assistant", "content": "Kept", "timestamp": "2026-11-08T10:00:02Z"]
        ]
        let harness = try makeHarness(
            openSession: { _, sessionID, compact in
                if !compact, refusesWholeTranscript { throw Self.resumeTooLong }
                return SessionResumeResult(
                    sessionId: sessionID,
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _, _ in
                switch history {
                case .page: return self.tailPagePayload(sessionId: "stored-long", rows: rows, offset: 0, limit: 2)
                case .none: return .unavailable
                case .foreign: return self.tailPagePayload(sessionId: "another-chat", rows: rows, offset: 0, limit: 2)
                }
            },
            additionalOperations: { ops in
                ops.connectClient = { _ in }
                ops.loadCatalog = { _, _ in [self.session("stored-long")] }
                ops.refreshContext = { _, _ in }
            }
        )
        harness.appState.sessions = [session("stored-long")]
        let opened = await harness.appState.openSession("stored-long")
        XCTAssertTrue(opened)
        let window = harness.appState.persistedTranscriptWindow
        XCTAssertEqual(window?.nextOffset, 2)
        XCTAssertEqual(window?.canLoadEarlier, true)

        refusesWholeTranscript = true
        history = .none
        await harness.appState.syncSession(purpose: .preserveCurrent, using: nil, automaticWorkToken: nil)
        XCTAssertEqual(harness.appState.messages.map { $0.content }, ["Long chat", "Kept"])
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.nextOffset, 2)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.canLoadEarlier, true)
        XCTAssertFalse(harness.appState.transcriptFreshnessIsStale)

        history = .foreign
        await harness.appState.syncSession(purpose: .preserveCurrent, using: nil, automaticWorkToken: nil)
        XCTAssertEqual(harness.appState.messages.map { $0.content }, ["Long chat", "Kept"])
        XCTAssertNil(harness.appState.errorMessage)
        XCTAssertTrue(harness.appState.transcriptFreshnessIsStale)
    }

    /// A chat open by its runtime id that a resume addresses by its stored
    /// id (an automatic return to a Bot Chat) still keeps its rows.
    func testAResumeTooLongKeepsTheRowsOfAChatOpenByAnotherOfItsIDs() async throws {
        var refusesWholeTranscript = false
        let shown = [
            ChatMessage(id: "1", role: .user, content: "Long chat", timestamp: "2026-11-08T10:00:00Z"),
            ChatMessage(id: "2", role: .assistant, content: "Kept", timestamp: "2026-11-08T10:00:02Z")
        ]
        let row = session("stored-long", alternateIDs: ["runtime-long"])
        let harness = try makeHarness(
            openSession: { _, _, compact in
                if !compact, refusesWholeTranscript { throw Self.resumeTooLong }
                return SessionResumeResult(
                    sessionId: "runtime-long",
                    storedSessionId: "stored-long",
                    messages: compact ? [] : shown,
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _, _ in .unavailable },
            additionalOperations: { ops in
                ops.connectClient = { _ in }
                ops.loadCatalog = { _, _ in [row] }
                ops.refreshContext = { _, _ in }
            }
        )
        harness.appState.sessions = [row]
        let opened = await harness.appState.openSession("stored-long")
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map { $0.content }, ["Long chat", "Kept"])
        XCTAssertTrue(harness.appState.chatOwnSessionIDsForTesting("runtime-long").contains("stored-long"))

        refusesWholeTranscript = true
        await harness.appState.syncSession(purpose: .preserveCurrent, using: nil, automaticWorkToken: nil)
        XCTAssertEqual(harness.appState.messages.map { $0.content }, ["Long chat", "Kept"])
        XCTAssertNil(harness.appState.errorMessage)
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
            persistedTranscript: { _, _, _ in .failed(failure) }
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
                persistedTranscript: { _, _, _ in
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
            persistedTranscript: { _, _, _ in
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
        harness.coordinator.rememberSession(.dashboard(profile: "default", sessionID: active.id), for: "default")
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
            persistedTranscript: { _, _, _ in .unavailable }
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
            persistedTranscript: { _, _, _ in
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
            persistedTranscript: { _, _, _ in
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
            persistedTranscript: { _, _, _ in
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
    func testLoadEarlierReanchorsVoiceCallMarkersAcrossPages() async throws {
        let base = Date(timeIntervalSince1970: 1_788_256_800)
        func rows(_ range: Range<Int>) -> [[String: Any]] {
            let iso = ISO8601DateFormatter()
            return range.map { index in
                ["id": String(index + 1), "role": "user", "content": "Synthetic row \(index)",
                 "timestamp": iso.string(from: base.addingTimeInterval(Double(index) * 60))]
            }
        }
        let backfillCalls = Counter()
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(sessionId: "runtime-a", messages: [],
                                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            persistedTranscript: { _, _, _ in
                self.tailPagePayload(sessionId: "stored-a", rows: rows(120..<240), offset: 0)
            },
            loadEarlierTranscriptPage: { sessionID, profile, offset in
                XCTAssertEqual(sessionID, "stored-a")
                XCTAssertEqual(profile, "default")
                backfillCalls.value += 1
                XCTAssertEqual(offset, backfillCalls.value * 120)
                return self.tailPagePayload(sessionId: "stored-a", rows: rows(offset == 120 ? 60..<180 : 0..<60), offset: offset)
            },
            additionalOperations: { ops in
                ops.connectClient = { _ in }
                ops.loadCatalog = { _, _ in [self.session("stored-a", alternateIDs: ["runtime-a"])] }
                ops.loadProfiles = {}
                ops.loadBusyInputMode = { _ in }
                ops.loadProfileDisplayPreferences = {}
                ops.loadSlashCommands = {}
            }
        )
        harness.appState.sessions = [session("stored-a", alternateIDs: ["runtime-a"])]
        harness.appState.voiceCallChatLinks.add(VoiceCallChatLink(
            callID: "synthetic-backfill", callSessionID: "", chatRuntimeSessionID: "runtime-a",
            chatStoredSessionID: "stored-a", chatTitle: "Synthetic chat", profile: "default",
            startedAt: base.addingTimeInterval(30.5 * 60), endedAt: base.addingTimeInterval(31 * 60), resumed: false
        ))
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)
        XCTAssertFalse(harness.appState.messages.contains { $0.id == "voice-call-synthetic-backfill" }, "INITIAL_WINDOW: the call predates the loaded partial tail")
        XCTAssertEqual(backfillCalls.value, 0)

        let firstPrepend = await harness.appState.loadEarlierMessages()
        XCTAssertTrue(firstPrepend)
        XCTAssertFalse(harness.appState.messages.contains { $0.id == "voice-call-synthetic-backfill" }, "The call still predates this partial older page")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.nextOffset, 240)
        let secondPrepend = await harness.appState.loadEarlierMessages()
        XCTAssertTrue(secondPrepend)
        let expected = (1..<32).map(String.init) + ["voice-call-synthetic-backfill"] + (32..<241).map(String.init)
        XCTAssertEqual(harness.appState.messages.map(\.id), expected)
        XCTAssertEqual(Set(harness.appState.messages.map(\.id)).count, 241)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.nextOffset, 300)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.canLoadEarlier, false)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.hasBackfilledPrefix, true)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.loadedPageStarts.map(\.firstRowID), ["121", "61", "1"], "Page starts name persisted rows, not a movable call marker")
        let refreshed = harness.appState.mergeVoiceCallMarkers(into: harness.appState.messages, sessionId: "stored-a")
        XCTAssertEqual(refreshed.map(\.id), expected, "A repeated refresh preserves placement and identity")
        let terminalPrepend = await harness.appState.loadEarlierMessages()
        XCTAssertFalse(terminalPrepend)
        XCTAssertEqual(backfillCalls.value, 2)
        for _ in 0..<2 {
            harness.coordinator.rememberSession(.dashboard(profile: "default", sessionID: "stored-a"), for: "default")
            await harness.appState.connect(with: HermesConnection(baseUrl: "https://one.example", ticket: "synthetic-reconnect-ticket"))
            XCTAssertEqual(harness.appState.messages.map(\.id), expected, "Repeated reconnect grafts preserve the backfilled call placement")
            XCTAssertEqual(harness.appState.persistedTranscriptWindow?.hasBackfilledPrefix, true)
        }
    }

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
            persistedTranscript: { _, _, _ in
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
            persistedTranscript: { _, _, _ in
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
            openSession: { _, requestedID, _ in
                // Each row resumes to its own runtime alias; a shared echo
                // would now be (correctly) rejected as a foreign runtime id.
                SessionResumeResult(
                    sessionId: requestedID == "stored-b" ? "runtime-b" : "runtime-a",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { sessionId, _, _ in
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
            persistedTranscript: { _, _, _ in
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
            persistedTranscript: { _, _, _ in
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
            persistedTranscript: { _, _, _ in
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
            persistedTranscript: { _, _, _ in
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
            persistedTranscript: { _, _, _ in
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
            persistedTranscript: { _, _, _ in
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
            persistedTranscript: { _, _, _ in
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
        harness.coordinator.rememberSession(.dashboard(profile: "default", sessionID: "stored-a"), for: "default")
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

    /// A chat left after Load earlier and opened again keeps the older rows
    /// it had (issue 1825): Hermes' newest page grafts onto them, as a
    /// reconnect's does, instead of the chat starting again from one page.
    func testAChatOpenedAgainKeepsTheRowsLoadEarlierBroughtIn() async throws {
        let first = session("stored-a", alternateIDs: ["runtime-a"])
        let other = session("stored-b", alternateIDs: ["runtime-b"])
        let harness = try makeHarness(
            openSession: { _, sessionId, _ in
                SessionResumeResult(
                    sessionId: sessionId.hasSuffix("b") ? "runtime-b" : "runtime-a",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { sessionId, _, _ in
                if sessionId.hasSuffix("b") {
                    return self.tailPagePayload(sessionId: "stored-b", rows: self.syntheticRows(5000..<5010), offset: 0)
                }
                return self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1880..<2000), offset: 0)
            },
            loadEarlierTranscriptPage: { _, _, offset in
                self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1760..<1880), offset: offset)
            }
        )
        harness.appState.sessions = [first, other]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)
        await harness.appState.loadEarlierMessages()
        XCTAssertEqual(harness.appState.messages.count, 240)

        let openedOther = await harness.appState.openSession("stored-b")
        XCTAssertTrue(openedOther)
        XCTAssertEqual(harness.appState.messages.first?.content, "Row 5000")

        let openedAgain = await harness.appState.openSession("stored-a")
        XCTAssertTrue(openedAgain)
        XCTAssertEqual(harness.appState.messages.count, 240, "The rows Load earlier brought in came back with the chat")
        XCTAssertEqual(harness.appState.messages.first?.content, "Row 1760")
        XCTAssertEqual(harness.appState.messages.last?.content, "Row 1999")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.hasBackfilledPrefix, true)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.canLoadEarlier, true)

        // Another chat never takes them, and a chat whose rows are one page
        // keeps nothing beyond its saved copy.
        let openedOtherAgain = await harness.appState.openSession("stored-b")
        XCTAssertTrue(openedOtherAgain)
        XCTAssertEqual(harness.appState.messages.map(\.content), (5000..<5010).map { "Row \($0)" })
    }

    /// A chat that comes back mid-turn takes its rows from the resume and
    /// leaves the kept Load earlier rows for the next open (#1836 review).
    func testAChatBackMidTurnLeavesItsKeptRowsForTheNextOpen() async throws {
        let first = session("stored-a", alternateIDs: ["runtime-a"])
        let other = session("stored-b", alternateIDs: ["runtime-b"])
        let liveA = Flag()
        let harness = try makeHarness(
            openSession: { _, sessionId, _ in
                if sessionId.hasSuffix("b") {
                    return SessionResumeResult(
                        sessionId: "runtime-b",
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                }
                guard liveA.isOn else {
                    return SessionResumeResult(
                        sessionId: "runtime-a",
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                }
                return SessionResumeResult(
                    sessionId: "runtime-a",
                    messages: [ChatMessage(id: "0", role: .user, content: "Row 1998", timestamp: "2026-09-13T08:00:00Z")],
                    snapshot: SessionRuntimeSnapshot(object: [:], inflight: .bool(true))
                )
            },
            persistedTranscript: { sessionId, _, _ in
                if sessionId.hasSuffix("b") {
                    return self.tailPagePayload(sessionId: "stored-b", rows: self.syntheticRows(5000..<5010), offset: 0)
                }
                return self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1880..<2000), offset: 0)
            },
            loadEarlierTranscriptPage: { _, _, offset in
                self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1760..<1880), offset: offset)
            }
        )
        harness.appState.sessions = [first, other]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)
        await harness.appState.loadEarlierMessages()
        XCTAssertEqual(harness.appState.messages.count, 240)
        let openedOther = await harness.appState.openSession("stored-b")
        XCTAssertTrue(openedOther)

        liveA.isOn = true
        let openedLive = await harness.appState.openSession("stored-a")
        XCTAssertTrue(openedLive)
        XCTAssertNotEqual(harness.appState.messages.first?.content, "Row 1760", "A live turn's rows come from the resume")

        liveA.isOn = false
        let openedOtherAgain = await harness.appState.openSession("stored-b")
        XCTAssertTrue(openedOtherAgain)
        let openedSettled = await harness.appState.openSession("stored-a")
        XCTAssertTrue(openedSettled)
        XCTAssertEqual(harness.appState.messages.count, 240, "The kept rows waited for the next open")
        XCTAssertEqual(harness.appState.messages.first?.content, "Row 1760")
    }

    /// A chat past 1,000 rows lets go of its oldest loaded pages once the
    /// reader is back at the newest row, or as it's left, and Load earlier
    /// reads on from the page it went back to (issue 1828).
    func testALongChatLetsGoOfItsOldestPagesAndLoadEarlierBringsThemBack() async throws {
        let first = session("stored-a", alternateIDs: ["runtime-a"])
        let other = session("stored-b", alternateIDs: ["runtime-b"])
        let offsets = Counter()
        let harness = try makeHarness(
            openSession: { _, sessionId, _ in
                SessionResumeResult(
                    sessionId: sessionId.hasSuffix("b") ? "runtime-b" : "runtime-a",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { sessionId, _, _ in
                if sessionId.hasSuffix("b") {
                    return self.tailPagePayload(sessionId: "stored-b", rows: self.syntheticRows(5000..<5010), offset: 0)
                }
                return self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1880..<2000), offset: 0)
            },
            loadEarlierTranscriptPage: { _, _, offset in
                offsets.value = offset
                return self.tailPagePayload(
                    sessionId: "stored-a",
                    rows: self.syntheticRows((1880 - offset)..<(2000 - offset)),
                    offset: offset
                )
            }
        )
        harness.appState.sessions = [first, other]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)
        for _ in 0..<9 { await harness.appState.loadEarlierMessages() }
        XCTAssertEqual(harness.appState.messages.count, 1_200)

        harness.appState.trimLoadedHistoryIfLong()
        XCTAssertEqual(harness.appState.messages.count, 1_080, "Back to the newest page start that keeps 1,000 rows")
        XCTAssertEqual(harness.appState.messages.first?.content, "Row 920")
        XCTAssertEqual(harness.appState.messages.last?.content, "Row 1999")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.nextOffset, 1_080)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.canLoadEarlier, true)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.hasBackfilledPrefix, true)

        harness.appState.trimLoadedHistoryIfLong()
        XCTAssertEqual(harness.appState.messages.count, 1_080, "Within reach of the limit, nothing more goes")

        await harness.appState.loadEarlierMessages()
        XCTAssertEqual(offsets.value, 1_080, "Load earlier reads on from the page it went back to")
        XCTAssertEqual(harness.appState.messages.count, 1_200)
        XCTAssertEqual(harness.appState.messages.first?.content, "Row 800")
        let ids = harness.appState.messages.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)

        // Left past the limit, it's kept cut back too.
        let openedOther = await harness.appState.openSession("stored-b")
        XCTAssertTrue(openedOther)
        let openedAgain = await harness.appState.openSession("stored-a")
        XCTAssertTrue(openedAgain)
        XCTAssertEqual(harness.appState.messages.count, 1_080)
        XCTAssertEqual(harness.appState.messages.first?.content, "Row 920")
        XCTAssertEqual(harness.appState.messages.last?.content, "Row 1999")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.canLoadEarlier, true)
    }

    /// A reader up in the older rows keeps them as the chat is left, so
    /// their place comes back with it; the reopened chat still lets go of
    /// them once the reader is back at the newest row, from the page starts
    /// the graft carried over (issue 1828, #1839 review).
    func testALongChatLeftWhileReadingOlderRowsKeepsThemUntilBackAtTheNewestRow() async throws {
        let first = session("stored-a", alternateIDs: ["runtime-a"])
        let other = session("stored-b", alternateIDs: ["runtime-b"])
        let harness = try makeHarness(
            openSession: { _, sessionId, _ in
                SessionResumeResult(
                    sessionId: sessionId.hasSuffix("b") ? "runtime-b" : "runtime-a",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { sessionId, _, _ in
                if sessionId.hasSuffix("b") {
                    return self.tailPagePayload(sessionId: "stored-b", rows: self.syntheticRows(5000..<5010), offset: 0)
                }
                return self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1880..<2000), offset: 0)
            },
            loadEarlierTranscriptPage: { _, _, offset in
                self.tailPagePayload(
                    sessionId: "stored-a",
                    rows: self.syntheticRows((1880 - offset)..<(2000 - offset)),
                    offset: offset
                )
            }
        )
        harness.appState.sessions = [first, other]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)
        for _ in 0..<9 { await harness.appState.loadEarlierMessages() }
        XCTAssertEqual(harness.appState.messages.count, 1_200)

        harness.appState.chatReaderIsUpInOlderRows = true
        harness.appState.trimLoadedHistoryIfLong()
        XCTAssertEqual(harness.appState.messages.count, 1_200, "Nothing goes while the reader is up in them")
        let openedOther = await harness.appState.openSession("stored-b")
        XCTAssertTrue(openedOther)
        let openedAgain = await harness.appState.openSession("stored-a")
        XCTAssertTrue(openedAgain)
        XCTAssertEqual(harness.appState.messages.count, 1_200, "Left while reading them, they came back whole")
        XCTAssertEqual(harness.appState.messages.first?.content, "Row 800")

        harness.appState.chatReaderIsUpInOlderRows = false
        harness.appState.trimLoadedHistoryIfLong()
        XCTAssertEqual(harness.appState.messages.count, 1_080, "The graft kept the page starts to cut back to")
        XCTAssertEqual(harness.appState.messages.first?.content, "Row 920")
        XCTAssertEqual(
            harness.appState.persistedTranscriptWindow?.nextOffset, 120,
            "A carried start claims no more coverage than the refreshed page: Hermes' newer side may have shrunk"
        )
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.canLoadEarlier, true)

        // Load earlier reads back over held rows, which dedup drops, and
        // reaches the dropped pages without a gap.
        for _ in 0..<9 { await harness.appState.loadEarlierMessages() }
        XCTAssertEqual(harness.appState.messages.first?.content, "Row 800")
        let ids = harness.appState.messages.map(\.id)
        XCTAssertEqual(ids.count, 1_200)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    /// Tapping the chat already open, settled and connected, reads it and
    /// nothing else: no second resume or page read (issue 1825).
    func testTappingTheOpenChatAgainDoesNotOpenItAgain() async throws {
        let resumes = Counter()
        let first = session("stored-a", alternateIDs: ["runtime-a"])
        let harness = try makeHarness(
            openSession: { _, _, _ in
                resumes.value += 1
                return SessionResumeResult(
                    sessionId: "runtime-a",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _, _ in
                self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1880..<2000), offset: 0)
            },
            loadEarlierTranscriptPage: { _, _, offset in
                self.tailPagePayload(sessionId: "stored-a", rows: self.syntheticRows(1760..<1880), offset: offset)
            }
        )
        harness.appState.sessions = [first]
        harness.appState.isConnected = true
        let opened = await harness.appState.requestOpenSession("stored-a").value
        XCTAssertTrue(opened)
        XCTAssertEqual(resumes.value, 1)
        await harness.appState.loadEarlierMessages()
        XCTAssertEqual(harness.appState.messages.count, 240)

        // By the row's id, or by the runtime id the chat is open as.
        for id in ["stored-a", "runtime-a"] {
            XCTAssertTrue(harness.appState.openChatIsSettled(as: id))
            let openedAgain = await harness.appState.requestOpenSession(id).value
            XCTAssertTrue(openedAgain)
        }
        XCTAssertEqual(resumes.value, 1, "The open chat wasn't resumed again")
        XCTAssertEqual(harness.appState.messages.count, 240, "Nothing Load earlier brought in was dropped")
        XCTAssertFalse(harness.appState.openChatIsSettled(as: "stored-b"), "Another chat still opens")

        // Not connected, a tap opens it as before.
        harness.appState.isConnected = false
        XCTAssertFalse(harness.appState.openChatIsSettled(as: "stored-a"), "Not while the dashboard isn't connected")
    }

    /// Pins the request contract: the production history request is an
    /// explicit tail-anchored bounded page — never the implicit default and
    /// never an unbounded one-shot — and older pages continue the same
    /// contract at the next offset.
    /// A JSON boolean in the pagination echo is not a count (as
    /// `AppState.integerValue` reads one): `returned: true` falls back to
    /// the rows fetched, not 1.
    func testPaginationEchoReadsJSONBooleansAsNoCount() throws {
        let data = Data(#"{"pagination": {"limit": true, "offset": false, "returned": true, "order": "latest"}}"#.utf8)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let page = try XCTUnwrap(PersistedTranscriptPagination.parse(payload, rawRowCount: 7))
        XCTAssertNil(page.limit)
        XCTAssertNil(page.offset)
        XCTAssertEqual(page.returned, 7)
    }

    func testPersistedHistoryRequestContractIsBoundedTailPaging() {
        XCTAssertEqual(PersistedTranscriptPagination.pageSize, 120)
        XCTAssertEqual(
            PersistedTranscriptPagination.tailQuery(offset: 0),
            "?limit=120&offset=0&order=latest&include_compacted=true&inline_images=false"
        )
        XCTAssertEqual(
            PersistedTranscriptPagination.tailQuery(offset: 240),
            "?limit=120&offset=240&order=latest&include_compacted=true&inline_images=false"
        )
        XCTAssertEqual(PersistedTranscriptPagination.legacyQuery, "")
        XCTAssertEqual(
            AppState.sessionMessagesPath(
                sessionId: "stored a",
                profile: "default",
                query: PersistedTranscriptPagination.tailQuery(offset: 0)
            ),
            "/api/sessions/stored%20a/messages?limit=120&offset=0&order=latest&include_compacted=true&inline_images=false"
        )
        XCTAssertEqual(
            AppState.sessionMessagesPath(
                sessionId: "stored-a",
                profile: "work",
                query: PersistedTranscriptPagination.tailQuery(offset: 120)
            ),
            "/api/sessions/stored-a/messages?limit=120&offset=120&order=latest&include_compacted=true&inline_images=false&profile=work"
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
            persistedTranscript: { _, _, _ in
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
        let failure = await harness.appState.loadEarlierPage()
        XCTAssertEqual(failure, .failed, "ChatView's own reads don't read again on a failure (issue 2967)")
        XCTAssertEqual(backfillCalls.value, 1)
        XCTAssertEqual(
            harness.appState.persistedTranscriptWindow?.canLoadEarlier,
            true,
            "A transient failure must keep the affordance retryable"
        )
        XCTAssertEqual(harness.appState.messages.count, 120, "A failed backfill must not touch the transcript")

        shouldFail.isOn = false
        let retry = await harness.appState.loadEarlierPage()
        XCTAssertEqual(retry, .landed)
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
            persistedTranscript: { _, _, _ in
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
        // Told apart from a failure, so ChatView reads the page after it (issue 2967).
        let held = await harness.appState.loadEarlierPage()
        XCTAssertEqual(held, .dedupedToNothing)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.nextOffset, 360)
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
            persistedTranscript: { _, _, _ in
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
            persistedTranscript: { _, _, _ in
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
        harness.coordinator.rememberSession(.dashboard(profile: "default", sessionID: "stored-a"), for: "default")
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
            persistedTranscript: { _, _, _ in
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
            persistedTranscript: { _, _, _ in
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
            persistedTranscript: { _, _, _ in
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
        // The page start on the folded result moved to its call card, so a
        // long chat's cut can still go back to it, keeping the run whole.
        let starts = harness.appState.persistedTranscriptWindow?.loadedPageStarts ?? []
        XCTAssertEqual(starts.map(\.firstRowID), ["1879.0-tool-0", "1760.0"])
        XCTAssertTrue(starts.allSatisfy { start in messages.contains { $0.id == start.firstRowID } })
        XCTAssertEqual(starts.first?.nextOffset, 120)
        XCTAssertEqual(starts.first?.hasBackfilledPrefix, true)
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
            persistedTranscript: { _, _, _ in
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
            persistedTranscript: { _, _, _ in
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
            persistedTranscript: { _, _, _ in
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
            persistedTranscript: { sessionId, _, _ in
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
            persistedTranscript: { _, _, _ in
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
            persistedTranscript: { _, _, _ in
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
            persistedTranscript: { _, _, _ in
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
        harness.coordinator.rememberSession(.dashboard(profile: "default", sessionID: "stored-a"), for: "default")
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
            persistedTranscript: { _, _, _ in
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
            persistedTranscript: { _, _, _ in
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
            persistedTranscript: { _, _, _ in
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
    // Window admission is exercised by the extensions below.

    private func makeHarness(
        openSession: @escaping @MainActor (HermesClient, String, Bool) async throws -> SessionResumeResult,
        persistedTranscript: (@MainActor (String, String, String) async -> PersistedTranscriptFetchOutcome)? = nil,
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

@MainActor
extension CompactResumeTranscriptTests {
    func testInitialOpenPartialWindowRejectsOutOfWindowCalls() async throws {
        try await initialOpenFixture()
    }

    private func initialOpenFixture() async throws {
        let suite = "InitialOpenWindow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dashboardID = UUID()
        let registry = SavedDashboardRegistry(activeDashboardID: dashboardID, dashboards: [
            SavedDashboard(id: dashboardID, label: "Synthetic chronology", normalizedURL: "https://chronology.invalid")
        ])
        var tailReads = 0
        var earlierReads = 0
        func row(_ id: Int, _ role: String, _ content: String, _ time: String, hidden: Bool = false) -> [String: Any] {
            var result: [String: Any] = ["id": id, "role": role, "content": content, "timestamp": time]
            if hidden { result["display_kind"] = "hidden" }
            return result
        }
        let leadingRows = (0..<118).map { index in
            row(1000 + index, index.isMultiple(of: 2) ? "user" : "assistant",
                "Synthetic latest-window row \(index)",
                "2026-11-20T10:00:00Z")
        }
        let tailRows = leadingRows + [
            row(1118, "user", "Nov 20: latest checkpoint", "2026-11-20T10:01:00Z"),
            row(1119, "assistant", "Latest checkpoint saved.", "2026-11-20T10:02:00Z")
        ]
        let operations = ChatResumeLifecycleOperations(
            openSession: { _, _, compact in
                XCTAssertTrue(compact)
                return SessionResumeResult(sessionId: "chronology-runtime", messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            persistedTranscript: { _, _, _ in
                tailReads += 1
                return self.tailPagePayload(sessionId: "chronology-stored", rows: tailRows, offset: 0)
            },
            loadEarlierTranscriptPage: { sessionID, profile, offset in
                earlierReads += 1
                XCTFail("INITIAL_OPEN: earlier-page read forbidden in this fixture")
                return self.tailPagePayload(sessionId: "chronology-stored", rows: [], offset: offset)
            }
        )
        let coordinator = ChatResumeCoordinator(store: ChatResumeStore(defaults: defaults))
        let state = AppState(defaults: defaults, chatResumeCoordinator: coordinator,
                             loadSavedConnection: false, dashboardRegistry: registry,
                             clearSessionPresentationCache: {}, chatResumeLifecycleOperations: operations,
                             sessionPresentationCache: SessionPresentationCache(defaults: defaults))
        // A fresh registry plus disabled saved connection means no bridge exists
        // through initialization. A client is constructed but never connected;
        // lifecycle operations above are the only transport for this test.
        XCTAssertNil(state.dashboardTicketBridge, "No WebKit navigation may exist at construction")
        let connection = HermesConnection(baseUrl: "https://chronology.invalid", ticket: "synthetic-only")
        state.connection = connection
        state.client = HermesClient(connection: connection, profile: "default")
        state.sessions = [session("chronology-stored", alternateIDs: ["chronology-runtime"])]
        let opened = await state.openSession("chronology-stored")
        XCTAssertTrue(opened)
        XCTAssertEqual(tailReads, 1)
        XCTAssertEqual(earlierReads, 0, "Visible tail must not auto-backfill")
        XCTAssertEqual(state.messages.count, 120)
        XCTAssertTrue(state.canLoadEarlierMessagesForActiveConversation)
        XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, 120)
        XCTAssertEqual(state.persistedTranscriptWindow?.canLoadEarlier, true)
        let iso = ISO8601DateFormatter()
        let calls = try [12, 13].map { day -> VoiceHostChatCall in
            let start = try XCTUnwrap(iso.date(from: "2026-11-\(day)T12:00:00Z"))
            return VoiceHostChatCall(callID: "synthetic-nov\(day)", chatID: "chronology-stored", startedAt: start, endedAt: start.addingTimeInterval(60))
        }
        state.adoptHostChatCalls(calls, profile: "default")
        XCTAssertEqual(earlierReads, 0, "INITIAL_OPEN: never request an earlier page")
        XCTAssertTrue(state.canLoadEarlierMessagesForActiveConversation)
        XCTAssertEqual(state.persistedTranscriptWindow?.canLoadEarlier, true)
        let oldIDs = Set(calls.map { "voice-call-\($0.callID)" })
        XCTAssertTrue(oldIDs.isDisjoint(with: state.messages.map(\.id)),
            "INITIAL_OPEN_WINDOW_ACCEPTANCE: older call markers must not be injected before a partial latest window, prior to any earlier-page load")
        let visible = try ["in-window", "new"].enumerated().map { index, id in
            let start = try XCTUnwrap(iso.date(from: index == 0 ? "2026-11-20T10:01:30Z" : "2026-11-21T12:00:00Z"))
            return VoiceHostChatCall(callID: id, chatID: "chronology-stored", startedAt: start, endedAt: start)
        }
        state.adoptHostChatCalls(visible, profile: "default")
        for call in visible { XCTAssertEqual(state.messages.filter { $0.id == "voice-call-\(call.callID)" }.count, 1) }
        XCTAssertEqual(state.messages.filter { $0.displayKind != VoiceCallChatLink.displayKind }.count, 120)
        XCTAssertEqual(state.voiceCallChatLinks.links.count, 4, "Deferred links are not deleted")
        XCTAssertEqual(earlierReads, 0)

    }
}


@MainActor
extension CompactResumeTranscriptTests {
    func testInitialOpenPartialWindowWithPreexistingLinksExcludesOldCalls() async throws {
        try await initialOpenControl(partial: true, empty: false)
    }

    func testInitialOpenCompleteHistoryKeepsCallsBeforeFirstTypedRow() async throws {
        try await initialOpenControl(partial: false, empty: false)
    }

    func testInitialOpenCompleteEmptyHistoryKeepsCalls() async throws {
        try await initialOpenControl(partial: false, empty: true)
    }

    private func initialOpenControl(partial: Bool, empty: Bool) async throws {
        let suite = "InitialOpenWindow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dashboardID = UUID()
        let registry = SavedDashboardRegistry(activeDashboardID: dashboardID, dashboards: [
            SavedDashboard(id: dashboardID, label: "Synthetic chronology", normalizedURL: "https://chronology.invalid")
        ])
        var tailReads = 0
        var earlierReads = 0
        func row(_ id: Int, _ role: String, _ content: String, _ time: String, hidden: Bool = false) -> [String: Any] {
            var result: [String: Any] = ["id": id, "role": role, "content": content, "timestamp": time]
            if hidden { result["display_kind"] = "hidden" }
            return result
        }
        let leadingRows = partial ? (0..<118).map { index in
            row(1000 + index, index.isMultiple(of: 2) ? "user" : "assistant", "Synthetic latest-window row \(index)", "2026-11-20T10:00:00Z")
        } : []
        let tailRows = empty ? [] : leadingRows + [
            row(1118, "user", "Nov 20: latest checkpoint", "2026-11-20T10:01:00Z"),
            row(1119, "assistant", "Latest checkpoint saved.", "2026-11-20T10:02:00Z")
        ]
        let operations = ChatResumeLifecycleOperations(
            openSession: { _, _, compact in
                XCTAssertTrue(compact)
                return SessionResumeResult(sessionId: "chronology-runtime", messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            persistedTranscript: { _, _, _ in
                tailReads += 1
                return self.tailPagePayload(sessionId: "chronology-stored", rows: tailRows, offset: 0)
            },
            loadEarlierTranscriptPage: { sessionID, profile, offset in
                earlierReads += 1
                XCTFail("INITIAL_OPEN: earlier-page read forbidden in this fixture")
                return self.tailPagePayload(sessionId: "chronology-stored", rows: [], offset: offset)
            }
        )
        let coordinator = ChatResumeCoordinator(store: ChatResumeStore(defaults: defaults))
        let state = AppState(defaults: defaults, chatResumeCoordinator: coordinator,
                             loadSavedConnection: false, dashboardRegistry: registry,
                             clearSessionPresentationCache: {}, chatResumeLifecycleOperations: operations,
                             sessionPresentationCache: SessionPresentationCache(defaults: defaults))
        // A fresh registry plus disabled saved connection means no bridge exists
        // through initialization. A client is constructed but never connected;
        // lifecycle operations above are the only transport for this test.
        XCTAssertNil(state.dashboardTicketBridge, "No WebKit navigation may exist at construction")
        let connection = HermesConnection(baseUrl: "https://chronology.invalid", ticket: "synthetic-only")
        state.connection = connection
        state.client = HermesClient(connection: connection, profile: "default")
        state.sessions = [session("chronology-stored", alternateIDs: ["chronology-runtime"])]
        let iso = ISO8601DateFormatter()
        let calls = try [12, 13].map { day -> VoiceHostChatCall in
            let start = try XCTUnwrap(iso.date(from: "2026-11-\(day)T12:00:00Z"))
            return VoiceHostChatCall(callID: "synthetic-nov\(day)", chatID: "chronology-stored", startedAt: start, endedAt: start.addingTimeInterval(60))
        }
        state.adoptHostChatCalls(calls, profile: "default")
        let opened = await state.openSession("chronology-stored")
        XCTAssertTrue(opened)
        XCTAssertEqual(tailReads, 1)
        XCTAssertEqual(earlierReads, 0, "Visible tail must not auto-backfill")
        XCTAssertEqual(state.messages.filter { $0.displayKind != VoiceCallChatLink.displayKind && $0.displayKind != VoiceCallChatLink.originDisplayKind }.count, empty ? 0 : (partial ? 120 : 2))
        XCTAssertEqual(state.canLoadEarlierMessagesForActiveConversation, partial)
        XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, empty ? 0 : (partial ? 120 : 2))
        XCTAssertEqual(state.persistedTranscriptWindow?.canLoadEarlier, partial)
        XCTAssertEqual(earlierReads, 0, "INITIAL_OPEN: never request an earlier page")
        XCTAssertEqual(state.canLoadEarlierMessagesForActiveConversation, partial)
        XCTAssertEqual(state.persistedTranscriptWindow?.canLoadEarlier, partial)
        let oldIDs = Set(calls.map { "voice-call-\($0.callID)" })
        if partial {
            XCTAssertTrue(oldIDs.isDisjoint(with: state.messages.map(\.id)),
                "INITIAL_OPEN_CACHED_LINKS_ACCEPTANCE: preexisting older calls must not enter a partial latest window")
        } else {
            XCTAssertTrue(oldIDs.isSubset(of: Set(state.messages.map(\.id))),
                "COMPLETE_HISTORY_ACCEPTANCE: a call before the earliest typed row must not be lost")
            XCTAssertEqual(Array(state.messages.prefix(2)).map(\.id), calls.map { "voice-call-\($0.callID)" })
            XCTAssertEqual(state.messages.count, empty ? 2 : 4)
        }
    }
}

@MainActor
extension CompactResumeTranscriptTests {
    func testEmptyTerminalPageRevealsCallBeforeFirstTypedRow() async throws {
        try await assertVoiceWindowTerminal(.empty)
    }

    func testDuplicateOnlyTerminalPageRevealsCallBeforeFirstTypedRow() async throws {
        try await assertVoiceWindowTerminal(.duplicate)
    }

    func testShortTerminalPageRevealsCallBeforeFirstTypedRow() async throws {
        try await assertVoiceWindowTerminal(.short)
    }

    func testFailedBackfillDoesNotClaimCompleteVoiceWindow() async throws {
        for kind in [VoiceWindowPage.unavailable, .malformed, .foreign, .idless, .lostContract] {
            try await assertVoiceWindowTerminal(kind)
        }
    }

    private enum VoiceWindowPage { case empty, duplicate, short, unavailable, malformed, foreign, idless, lostContract }

    private func assertVoiceWindowTerminal(_ kind: VoiceWindowPage) async throws {
        var reads = 0
        let rows = voiceWindowRows(120..<240)
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(sessionId: "runtime-a", messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            persistedTranscript: { _, _, _ in self.tailPagePayload(sessionId: "stored-a", rows: rows, offset: 0) },
            loadEarlierTranscriptPage: { _, _, offset in
                reads += 1
                switch kind {
                case .empty: return self.tailPagePayload(sessionId: "stored-a", rows: [], offset: offset)
                case .duplicate: return self.tailPagePayload(sessionId: "stored-a", rows: Array(rows.prefix(1)), offset: offset)
                case .short: return self.tailPagePayload(sessionId: "stored-a", rows: self.voiceWindowRows(110..<120), offset: offset)
                case .unavailable: return .unavailable
                case .malformed: return .payload(["session_id": "stored-a"])
                case .foreign: return self.tailPagePayload(sessionId: "foreign", rows: [], offset: offset)
                case .idless: return self.tailPagePayload(sessionId: "stored-a", rows: [["role": "user", "content": "bad"]], offset: offset)
                case .lostContract: return self.tailPagePayload(sessionId: "stored-a", rows: [], offset: offset, order: nil)
                }
            }
        )
        harness.appState.sessions = [session("stored-a", alternateIDs: ["runtime-a"])]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)
        let start = Date(timeIntervalSince1970: 1_788_256_800)
        harness.appState.adoptHostChatCalls([VoiceHostChatCall(callID: "before-first", chatID: "stored-a", startedAt: start, endedAt: start)], profile: "default")
        XCTAssertEqual(reads, 0)
        XCTAssertFalse(harness.appState.messages.contains { $0.id == "voice-call-before-first" }, "PARTIAL_WINDOW: pre-first call is deferred")
        // Isolate terminal admission even on the pre-fix implementation,
        // whose initial merge already leaked this marker.
        harness.appState.messages.removeAll { $0.id == "voice-call-before-first" }
        let prepended = await harness.appState.loadEarlierMessages()
        XCTAssertEqual(reads, 1)
        XCTAssertFalse(harness.appState.canLoadEarlierMessagesForActiveConversation)
        let complete = kind == .empty || kind == .duplicate || kind == .short
        XCTAssertEqual(harness.appState.messages.contains { $0.id == "voice-call-before-first" }, complete, "TERMINAL_ADMISSION: only a validated terminal page proves complete")
        XCTAssertEqual(prepended, kind == .short, "A marker-only change is not a persisted-row prepend")
        let refreshed = harness.appState.mergeVoiceCallMarkers(into: harness.appState.messages, sessionId: "stored-a")
        XCTAssertEqual(refreshed.contains { $0.id == "voice-call-before-first" }, complete, "Retired paging is not proof of complete history")
        XCTAssertEqual(harness.appState.voiceCallChatLinks.links.count, 1)
        XCTAssertEqual(refreshed.filter { $0.displayKind != VoiceCallChatLink.displayKind }.count, kind == .short ? 130 : 120)
    }

    func testInitialLegacyFullHistoryRetainsCallBeforeFirstTypedRow() async throws {
        var earlierReads = 0
        let harness = try makeHarness(
            openSession: { _, _, _ in SessionResumeResult(sessionId: "runtime-a", messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])) },
            persistedTranscript: { _, _, _ in .payload(["session_id": "stored-a", "messages": self.voiceWindowRows(120..<240)]) },
            loadEarlierTranscriptPage: { _, _, _ in earlierReads += 1; return .unavailable }
        )
        harness.appState.sessions = [session("stored-a", alternateIDs: ["runtime-a"])]
        let start = Date(timeIntervalSince1970: 1_788_256_800)
        harness.appState.adoptHostChatCalls([VoiceHostChatCall(callID: "legacy-first", chatID: "stored-a", startedAt: start, endedAt: start)], profile: "default")
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.first?.id, "voice-call-legacy-first")
        XCTAssertNil(harness.appState.persistedTranscriptWindow)
        XCTAssertEqual(earlierReads, 0)
    }

    private func voiceWindowRows(_ range: Range<Int>) -> [[String: Any]] {
        let iso = ISO8601DateFormatter()
        let start = Date(timeIntervalSince1970: 1_788_256_800)
        return range.map { index in
            ["id": String(index + 1), "role": "user", "content": "Window row \(index)", "timestamp": iso.string(from: start.addingTimeInterval(Double(index) * 60))]
        }
    }
}

@MainActor
extension CompactResumeTranscriptTests {
    func testCompleteVoicePrefixSurvivesReconnectTrimAndReload() async throws {
        var pages = 0
        let harness = try makeHarness(
            openSession: { _, _, _ in SessionResumeResult(sessionId: "runtime-a", messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])) },
            persistedTranscript: { _, _, _ in self.tailPagePayload(sessionId: "stored-a", rows: self.voiceWindowRows(1200..<1320), offset: 0) },
            loadEarlierTranscriptPage: { _, _, offset in
                pages += 1
                let end = max(0, 1320 - offset)
                return self.tailPagePayload(sessionId: "stored-a", rows: self.voiceWindowRows(max(0, end - 120)..<end), offset: offset)
            },
            additionalOperations: { ops in
                ops.connectClient = { _ in }
                ops.loadCatalog = { _, _ in [self.session("stored-a", alternateIDs: ["runtime-a"])] }
                ops.loadProfiles = {}; ops.loadBusyInputMode = { _ in }
                ops.loadProfileDisplayPreferences = {}; ops.loadSlashCommands = {}
            }
        )
        harness.appState.sessions = [session("stored-a", alternateIDs: ["runtime-a"])]
        let start = Date(timeIntervalSince1970: 1_788_256_740)
        let call = VoiceHostChatCall(callID: "first-ever", chatID: "stored-a", startedAt: start, endedAt: start)
        harness.appState.adoptHostChatCalls([call], profile: "default")
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)
        XCTAssertEqual(pages, 0)
        XCTAssertFalse(harness.appState.messages.contains { $0.id == "voice-call-first-ever" })
        for _ in 0..<11 { _ = await harness.appState.loadEarlierMessages() }
        XCTAssertEqual(harness.appState.messages.first?.id, "voice-call-first-ever")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.reachedBeginning, true)
        harness.appState.chatReaderIsUpInOlderRows = true
        for _ in 0..<2 {
            harness.coordinator.rememberSession(.dashboard(profile: "default", sessionID: "stored-a"), for: "default")
            await harness.appState.connect(with: HermesConnection(baseUrl: "https://one.example", ticket: "synthetic-reconnect"))
            XCTAssertEqual(harness.appState.messages.first?.id, "voice-call-first-ever", "A retained whole prefix stays complete even when latest coverage resets")
            XCTAssertEqual(harness.appState.persistedTranscriptWindow?.reachedBeginning, true)
        }
        harness.appState.chatReaderIsUpInOlderRows = false
        harness.appState.trimLoadedHistoryIfLong()
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.reachedBeginning, false)
        XCTAssertFalse(harness.appState.messages.contains { $0.id == "voice-call-first-ever" })
        let placed = harness.appState.mergeVoiceCallMarkers(into: harness.appState.messages, sessionId: "stored-a")
        XCTAssertFalse(placed.contains { $0.id == "voice-call-first-ever" }, "Trimmed calls must not resurrect before their persisted region returns")
        for _ in 0..<11 { _ = await harness.appState.loadEarlierMessages() }
        XCTAssertEqual(harness.appState.messages.first?.id, "voice-call-first-ever")
        XCTAssertEqual(harness.appState.messages.filter { $0.id == "voice-call-first-ever" }.count, 1)
        XCTAssertEqual(harness.appState.messages.filter { $0.displayKind != VoiceCallChatLink.displayKind }.map(\.id), (1...1320).map(String.init))
    }

    func testCompleteTailRefreshDropsOmittedOlderRows() async throws {
        try await assertCompleteRefreshAuthority(legacy: false, partial: false)
    }

    func testLegacyFullRefreshDropsOmittedOlderRows() async throws {
        try await assertCompleteRefreshAuthority(legacy: true, partial: false)
    }

    func testCompletePrefixSurvivesGenuinelyPartialRefresh() async throws {
        try await assertCompleteRefreshAuthority(legacy: false, partial: true)
    }

    private func assertCompleteRefreshAuthority(legacy: Bool, partial: Bool) async throws {
        var refreshed = false
        var reads = 0
        let active = session("stored-a", alternateIDs: ["runtime-a"])
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(sessionId: "runtime-a", messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            persistedTranscript: { _, _, _ in
                reads += 1
                let rows = (refreshed ? (partial ? 2..<122 : 2..<4) : 1..<4).map { index -> [String: Any] in
                    ["id": String(index), "role": index.isMultiple(of: 2) ? "user" : "assistant",
                     "content": "Row \(index)",
                     "timestamp": String(format: "2026-09-01T%02d:%02d:00Z", 10 + (index / 60) % 10, index % 60)]
                }
                if refreshed && legacy {
                    return .payload(["session_id": "stored-a", "messages": rows])
                }
                return self.tailPagePayload(sessionId: "stored-a", rows: rows, offset: 0)
            },
            loadEarlierTranscriptPage: { _, _, _ in
                XCTFail("Refresh must not request earlier pages")
                return .unavailable
            },
            additionalOperations: { ops in
                ops.connectClient = { _ in }
                ops.loadCatalog = { _, _ in [active] }
                ops.loadProfiles = {}; ops.loadBusyInputMode = { _ in }
                ops.loadProfileDisplayPreferences = {}; ops.loadSlashCommands = {}
            }
        )
        harness.appState.sessions = [active]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.reachedBeginning, true)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.hasBackfilledPrefix, false)
        refreshed = true
        harness.coordinator.rememberSession(.dashboard(profile: "default", sessionID: "stored-a"), for: "default")
        await harness.appState.connect(with: HermesConnection(baseUrl: "https://one.example", ticket: "authority-refresh"))
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(harness.appState.messages.map(\.id), partial ? (1..<122).map(String.init) : ["2", "3"],
            "COMPLETE_REFRESH_AUTHORITY: only a genuinely partial tail may preserve an omitted older prefix")
        if legacy {
            XCTAssertNil(harness.appState.persistedTranscriptWindow)
        } else {
            XCTAssertEqual(harness.appState.persistedTranscriptWindow?.reachedBeginning, true)
            XCTAssertEqual(harness.appState.persistedTranscriptWindow?.hasBackfilledPrefix, partial)
        }
    }

    func testPartialRefreshDiscardsSkewedSuffixCoverageAndDefersOldCall() async throws {
        var refreshed = false
        var earlierReads = 0
        let active = session("stored-a", alternateIDs: ["runtime-a"])
        let epoch = Date(timeIntervalSince1970: 1_788_256_800)
        let iso = ISO8601DateFormatter()
        func row(_ id: Int, _ seconds: Int) -> [String: Any] {
            ["id": String(id), "role": "user", "content": "Skew fixture row \(id)",
             "timestamp": iso.string(from: epoch.addingTimeInterval(Double(seconds)))]
        }
        let prefix = [row(1, 800), row(2, 801)]
        let normalTail = (0..<119).map { row(100 + $0, 1000 + $0) }
        let oldTail = normalTail + [row(219, 100)]
        let freshTail = normalTail + [row(220, 1119)]
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(sessionId: "runtime-a", messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            persistedTranscript: { _, _, _ in
                self.tailPagePayload(sessionId: "stored-a", rows: refreshed ? freshTail : oldTail, offset: 0)
            },
            loadEarlierTranscriptPage: { _, _, offset in
                earlierReads += 1
                // A full overlapping page adds two prefix rows without proving completeness.
                return self.tailPagePayload(sessionId: "stored-a", rows: prefix + Array(normalTail.prefix(118)), offset: offset)
            },
            additionalOperations: { ops in
                ops.connectClient = { _ in }
                ops.loadCatalog = { _, _ in [active] }
                ops.loadProfiles = {}; ops.loadBusyInputMode = { _ in }
                ops.loadProfileDisplayPreferences = {}; ops.loadSlashCommands = {}
            }
        )
        harness.appState.sessions = [active]
        let opened = await harness.appState.openSession("stored-a")
        XCTAssertTrue(opened)
        let prepended = await harness.appState.loadEarlierMessages()
        XCTAssertTrue(prepended)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["1", "2"] + (100..<220).map(String.init))
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.reachedBeginning, false)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.oldestLoadedTimestamp, epoch.addingTimeInterval(100))
        let start = epoch.addingTimeInterval(200)
        harness.appState.adoptHostChatCalls([VoiceHostChatCall(callID: "removed-skew-bound", chatID: "stored-a", startedAt: start, endedAt: start)], profile: "default")
        XCTAssertTrue(harness.appState.messages.contains { $0.id == "voice-call-removed-skew-bound" })
        refreshed = true
        harness.coordinator.rememberSession(.dashboard(profile: "default", sessionID: "stored-a"), for: "default")
        await harness.appState.connect(with: HermesConnection(baseUrl: "https://one.example", ticket: "skew-refresh"))
        XCTAssertEqual(earlierReads, 1)
        XCTAssertEqual(harness.appState.messages.filter { $0.displayKind != VoiceCallChatLink.displayKind }.map(\.id),
            ["1", "2"] + (100..<219).map(String.init) + ["220"], "Ordinary row order stays unchanged; the removed suffix must not survive")
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.hasBackfilledPrefix, true)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.reachedBeginning, false)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow?.oldestLoadedTimestamp, epoch.addingTimeInterval(800),
            "RETAINED_COVERAGE: a discarded skewed suffix cannot supply the current lower bound")
        XCTAssertFalse(harness.appState.messages.contains { $0.id == "voice-call-removed-skew-bound" },
            "RETAINED_COVERAGE_ADMISSION: calls older than all retained persisted rows must be deferred")
        XCTAssertEqual(harness.appState.voiceCallChatLinks.links.count, 1, "Deferral must not delete the durable link")
    }
}

@MainActor
extension CompactResumeTranscriptTests {
    func testInitialHiddenPartialPageDefersCallsUntilVisibleBackfill() async throws {
        try await hiddenPartialVoiceFixture(terminal: false)
    }

    func testInitialHiddenPartialPageDefersCallsUntilTerminalBackfill() async throws {
        try await hiddenPartialVoiceFixture(terminal: true)
    }

    func testHiddenPartialBackfillDoesNotSeedTranscriptChangedDuringRead() async throws {
        try await hiddenPartialVoiceFixture(terminal: false, clearDuringRead: true)
    }

    private func hiddenPartialVoiceFixture(terminal: Bool, clearDuringRead: Bool = false) async throws {
        var tailReads = 0
        var offsets: [Int] = []
        var clearTranscript: (() -> Void)?
        let hidden = voiceWindowRows(120..<240).map { row -> [String: Any] in
            var row = row
            row["display_kind"] = "hidden"
            return row
        }
        XCTAssertTrue(MessageNormalizer.normalizeMessages(hidden.map(AnyCodable.from)).isEmpty,
            "HIDDEN_NORMALIZATION: valid raw rows establish no displayed timestamp coverage")
        let visible = voiceWindowRows(0..<120)
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(sessionId: "runtime-a", messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            persistedTranscript: { _, _, _ in
                tailReads += 1
                return self.tailPagePayload(sessionId: "stored-a", rows: hidden, offset: 0)
            },
            loadEarlierTranscriptPage: { id, profile, offset in
                XCTAssertEqual(id, "stored-a")
                XCTAssertEqual(profile, "default")
                offsets.append(offset)
                if clearDuringRead { clearTranscript?() }
                return self.tailPagePayload(sessionId: "stored-a", rows: terminal ? [] : visible, offset: offset)
            }
        )
        let state = harness.appState
        clearTranscript = { [weak state] in state?.messages = [] }
        defer { clearTranscript = nil }
        state.sessions = [session("stored-a", alternateIDs: ["runtime-a"])]
        let epoch = Date(timeIntervalSince1970: 1_788_256_800)
        let saved = VoiceHostChatCall(callID: "hidden-saved", chatID: "stored-a",
            startedAt: epoch.addingTimeInterval(30), endedAt: epoch.addingTimeInterval(30))
        state.adoptHostChatCalls([saved], profile: "default")
        let opened = await state.openSession("stored-a")
        XCTAssertTrue(opened)
        XCTAssertEqual(tailReads, 1)
        XCTAssertTrue(offsets.isEmpty, "INITIAL_HIDDEN_OPEN: zero earlier-page requests")
        XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, 120)
        XCTAssertEqual(state.persistedTranscriptWindow?.reachedBeginning, false)
        XCTAssertNil(state.persistedTranscriptWindow?.oldestLoadedTimestamp)
        XCTAssertTrue(state.messages.isEmpty,
            "HIDDEN_INITIAL_ADMISSION: unknown partial coverage must not admit preexisting chat calls")
        let newCall = VoiceHostChatCall(callID: "hidden-new", chatID: "stored-a",
            startedAt: epoch.addingTimeInterval(90), endedAt: epoch.addingTimeInterval(90))
        state.adoptHostChatCalls([saved, newCall], profile: "default")
        XCTAssertTrue(state.messages.isEmpty,
            "HIDDEN_LATER_ADOPTION: no timestamp coverage must also defer newly discovered calls")
        let links = state.voiceCallChatLinks
        XCTAssertEqual(links.links.count, 2)
        XCTAssertEqual(VoiceCallChatLinks.load(from: harness.defaults), links)

        let prepended = await state.loadEarlierMessages()
        XCTAssertEqual(prepended, !terminal && !clearDuringRead)
        XCTAssertEqual(offsets, [120], "Raw hidden rows, not normalized count, control paging")
        XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, terminal || clearDuringRead ? 120 : 240)
        XCTAssertEqual(state.persistedTranscriptWindow?.reachedBeginning, terminal)
        if clearDuringRead {
            XCTAssertTrue(state.messages.isEmpty,
                "An otherwise owned hidden-only window cannot seed a transcript written during the fetch")
            XCTAssertNil(state.persistedTranscriptWindow?.oldestLoadedTimestamp)
            XCTAssertEqual(state.voiceCallChatLinks, links)
            return
        }
        for call in [saved, newCall] {
            XCTAssertEqual(state.messages.filter { $0.id == "voice-call-\(call.callID)" }.count, 1,
                "HIDDEN_BACKFILL_ADMISSION: accepted visible coverage or terminal history reveals deferred calls")
        }
        XCTAssertEqual(state.messages.filter { $0.displayKind != VoiceCallChatLink.displayKind }.map(\.id),
            terminal ? [] : (1...120).map(String.init))
        if !terminal {
            XCTAssertEqual(Array(state.messages.prefix(3)).map(\.id), ["1", "voice-call-hidden-saved", "2"])
        }
        XCTAssertEqual(state.voiceCallChatLinks, links, "Deferral must preserve stored links")
    }
}

@MainActor
extension CompactResumeTranscriptTests {
    func testInitialHiddenPartialStandaloneCallKeepsOriginCard() async throws {
        let hidden = voiceWindowRows(120..<240).map { row -> [String: Any] in
            var row = row
            row["display_kind"] = "hidden"
            return row
        }
        let harness = try makeHarness(
            openSession: { _, _, _ in SessionResumeResult(sessionId: "runtime-call", messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])) },
            persistedTranscript: { _, _, _ in self.tailPagePayload(sessionId: "stored-call", rows: hidden, offset: 0) }
        )
        let state = harness.appState
        state.sessions = [session("stored-call", alternateIDs: ["runtime-call"])]
        let start = Date(timeIntervalSince1970: 1_000)
        let link = VoiceCallChatLink(callID: "hidden-standalone", callSessionID: "stored-call",
            chatRuntimeSessionID: "source-chat", chatStoredSessionID: "source-stored",
            chatTitle: "Synthetic origin", profile: "default", startedAt: start, endedAt: start, resumed: false)
        state.voiceCallChatLinks.add(link)
        let opened = await state.openSession("stored-call")
        XCTAssertTrue(opened)
        XCTAssertEqual(state.persistedTranscriptWindow?.reachedBeginning, false)
        XCTAssertNil(state.persistedTranscriptWindow?.oldestLoadedTimestamp)
        XCTAssertEqual(state.messages.map(\.id), [link.originMarkerID],
            "HIDDEN_STANDALONE_ORIGIN: lack of chat coverage must not hide the call's way back")
        XCTAssertEqual(state.voiceCallChatLinks.links, [link])
    }
}

@MainActor
extension CompactResumeTranscriptTests {
    func testHiddenPartialWindowOffersAndLoadsEarlierVisibleHistory() async throws {
        let hidden = voiceWindowRows(120..<240).map { row -> [String: Any] in
            var row = row
            row["display_kind"] = "hidden"
            return row
        }
        var offsets: [Int] = []
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(sessionId: "runtime-a", messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            persistedTranscript: { _, _, _ in self.tailPagePayload(sessionId: "stored-a", rows: hidden, offset: 0) },
            loadEarlierTranscriptPage: { id, profile, offset in
                XCTAssertEqual(id, "stored-a")
                XCTAssertEqual(profile, "default")
                offsets.append(offset)
                return self.tailPagePayload(sessionId: "stored-a", rows: self.voiceWindowRows(0..<120), offset: offset)
            }
        )
        let state = harness.appState
        state.sessions = [session("stored-a", alternateIDs: ["runtime-a"])]
        let epoch = Date(timeIntervalSince1970: 1_788_256_800)
        state.adoptHostChatCalls([VoiceHostChatCall(callID: "ui-hidden-saved", chatID: "stored-a",
            startedAt: epoch.addingTimeInterval(30), endedAt: epoch.addingTimeInterval(30))], profile: "default")
        let opened = await state.openSession("stored-a")
        XCTAssertTrue(opened)
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, 120)
        let links = state.voiceCallChatLinks
        let provenance = state.shownChat.durablePersistedRowIDs
        XCTAssertEqual(provenance, Set((121...240).map(String.init)))
        XCTAssertEqual(state.persistedTranscriptWindow?.reachedBeginning, false)
        XCTAssertEqual(state.persistedTranscriptWindow?.hasBackfilledPrefix, false)
        XCTAssertTrue(try XCTUnwrap(state.persistedTranscriptWindow).loadedPageStarts.isEmpty)
        XCTAssertNil(state.persistedTranscriptWindow?.oldestLoadedTimestamp)
        var withoutProvenance = try XCTUnwrap(state.persistedTranscriptWindow)
        XCTAssertTrue(withoutProvenance.hasAcceptedHiddenOnlyPage)
        withoutProvenance.hasAcceptedHiddenOnlyPage = false
        state.persistedTranscriptWindow = withoutProvenance
        XCTAssertFalse(state.canLoadEarlierMessagesForActiveConversation, "An arbitrary empty transcript has no seed provenance")
        withoutProvenance.hasAcceptedHiddenOnlyPage = true
        state.persistedTranscriptWindow = withoutProvenance
        let eligibleWindow = try XCTUnwrap(state.persistedTranscriptWindow)
        var disallowed = eligibleWindow
        disallowed.hasBackfilledPrefix = true
        state.persistedTranscriptWindow = disallowed
        XCTAssertFalse(state.canLoadEarlierMessagesForActiveConversation, "A wiped loaded prefix must not become seedable")
        disallowed = eligibleWindow
        disallowed.reachedBeginning = true
        state.persistedTranscriptWindow = disallowed
        XCTAssertFalse(state.canLoadEarlierMessagesForActiveConversation)
        disallowed = eligibleWindow
        disallowed.canLoadEarlier = false
        state.persistedTranscriptWindow = disallowed
        XCTAssertFalse(state.canLoadEarlierMessagesForActiveConversation)
        state.persistedTranscriptWindow = eligibleWindow
        let offered = state.canLoadEarlierMessagesForActiveConversation
        XCTAssertTrue(offered, "HIDDEN_UI_AFFORDANCE: ChatView must offer its real backfill path for validated hidden-only coverage")
        guard offered else { return }
        var model = TranscriptModel()
        let disclosure = ChatRowDisclosure()
        var input = TranscriptModel.Input()
        input.loadsEarlier = offered
        input.hasSavedCopy = state.offlineChatPresentation != nil
        input.chatIsOpening = state.liveChatIsOnItsWay
        _ = model.update(input, targets: [], disclosure: disclosure)
        XCTAssertTrue(model.rows.contains { if case .loadEarlier(isLoading: false) = $0.kind { return true }; return false },
            "HIDDEN_UI_MODEL: the production selector must create the load-earlier control")
        // A truly empty transcript also draws its empty/opening line. Do not
        // fabricate targets or saved-copy state to force the auto-load oracle.
        XCTAssertFalse(model.drawsOnlyLoadEarlier)
        try await captureHiddenHistory(state, label: "hidden-only")
        XCTAssertTrue(offsets.isEmpty, "Capture precedes the explicit earlier-page read")
        let outcome = await state.loadEarlierPage()
        XCTAssertEqual(outcome, .landed)
        XCTAssertEqual(offsets, [120])
        XCTAssertEqual(state.messages.filter { $0.displayKind != VoiceCallChatLink.displayKind }.map(\.id), (1...120).map(String.init))
        XCTAssertEqual(Array(state.messages.prefix(3)).map(\.id), ["1", "voice-call-ui-hidden-saved", "2"])
        XCTAssertEqual(state.voiceCallChatLinks, links)
        XCTAssertEqual(VoiceCallChatLinks.load(from: harness.defaults), links)
        XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, 240)
        XCTAssertEqual(state.persistedTranscriptWindow?.reachedBeginning, false)
        XCTAssertEqual(state.persistedTranscriptWindow?.hasBackfilledPrefix, true)
        XCTAssertEqual(state.persistedTranscriptWindow?.loadedPageStarts.map(\.firstRowID), ["1"])
        XCTAssertEqual(state.activeSessionId, "runtime-a")
        XCTAssertEqual(state.activeProfile, "default")
        input.targetsRevision += 1
        input.loadsEarlier = state.canLoadEarlierMessagesForActiveConversation
        var targets = ChatMessageScrollTargetCache()
        targets.update(for: state.messages)
        _ = model.update(input, targets: targets.targets, disclosure: disclosure)
        XCTAssertFalse(model.drawsOnlyLoadEarlier)
        try await captureHiddenHistory(state, label: "visible-backfilled")
    }

    func testHiddenPartialRejectedSeedRetriesSameRawPage() async throws {
        let hidden = voiceWindowRows(120..<240).map { row -> [String: Any] in
            var row = row
            row["display_kind"] = "hidden"
            return row
        }
        var offsets: [Int] = []
        var interrupt: (() -> Void)?
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(sessionId: "runtime-a", messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            persistedTranscript: { _, _, _ in self.tailPagePayload(sessionId: "stored-a", rows: hidden, offset: 0) },
            loadEarlierTranscriptPage: { id, profile, offset in
                XCTAssertEqual(id, "stored-a")
                XCTAssertEqual(profile, "default")
                offsets.append(offset)
                if offsets.count == 1 { interrupt?() }
                return self.tailPagePayload(sessionId: "stored-a", rows: offset == 120 ? self.voiceWindowRows(0..<120) : [], offset: offset)
            }
        )
        let state = harness.appState
        state.sessions = [session("stored-a", alternateIDs: ["runtime-a"])]
        interrupt = { [weak state] in state?.messages = [] }
        defer { interrupt = nil }
        let opened = await state.openSession("stored-a")
        XCTAssertTrue(opened)
        XCTAssertTrue(state.messages.isEmpty)
        let rejected = await state.loadEarlierPage()
        XCTAssertEqual(rejected, .failed, "HIDDEN_REJECTED_SEED_OUTCOME: an unadopted, unheld page is not a duplicate-only page")
        XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, 120,
            "HIDDEN_REJECTED_SEED_OFFSET: rejecting a changed transcript must not skip its never-adopted page")
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertEqual(state.persistedTranscriptWindow?.reachedBeginning, false)
        XCTAssertEqual(state.persistedTranscriptWindow?.canLoadEarlier, true)
        XCTAssertEqual(state.persistedTranscriptWindow?.isLoadingEarlier, false)
        XCTAssertEqual(state.persistedTranscriptWindow?.hasBackfilledPrefix, false)
        XCTAssertTrue(try XCTUnwrap(state.persistedTranscriptWindow).loadedPageStarts.isEmpty)
        XCTAssertNil(state.persistedTranscriptWindow?.oldestLoadedTimestamp)
        XCTAssertTrue(state.canLoadEarlierMessagesForActiveConversation)
        let retry = await state.loadEarlierPage()
        XCTAssertEqual(retry, .landed)
        XCTAssertEqual(offsets, [120, 120], "HIDDEN_REJECTED_SEED_RETRY: retry the same raw page before advancing")
        XCTAssertEqual(state.messages.map(\.id), (1...120).map(String.init))
        XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, 240)
    }
}

@MainActor
extension CompactResumeTranscriptTests {
    /// Native scene-attached production ChatView, never a web reconstruction.
    /// All state and voice links come from the regression's real open/backfill.
    private func captureHiddenHistory(_ state: AppState, label: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let host = UIHostingController(rootView: DormancyHarnessEnvironment.applying(
            ChatView(chatTextSizeOverride: DormancyHarnessEnvironment.pinnedChatTextSize).environmentObject(state)
        ))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<35 {
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        var didDraw = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            didDraw = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(didDraw, "HIDDEN_NATIVE_RENDER: scene-attached production ChatView must draw")
        let name = "hidden-history-\(label)-native-ChatView"
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        try XCTUnwrap(image.pngData()).write(to: documents.appendingPathComponent(name + ".png"), options: .atomic)
        let links = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state.voiceCallChatLinks))
        let receipt: [String: Any] = [
            "label": label,
            "sceneAttachedProductionChatView": true,
            "canLoadEarlier": state.canLoadEarlierMessagesForActiveConversation,
            "rawNextOffset": try XCTUnwrap(state.persistedTranscriptWindow).nextOffset,
            "reachedBeginning": try XCTUnwrap(state.persistedTranscriptWindow).reachedBeginning,
            "activeSessionID": state.activeSessionId ?? "",
            "profile": state.activeProfile,
            "links": links,
            "rows": state.messages.map { message in
                ["id": message.id, "content": message.content, "timestamp": message.timestamp,
                 "role": message.role.rawValue, "displayKind": message.displayKind ?? "ordinary"]
            }
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: documents.appendingPathComponent("hidden-history-\(label)-rows.json"), options: .atomic)
        let rows = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        rows.name = "hidden-history-\(label)-rows"
        rows.lifetime = .keepAlways
        add(rows)
    }
}

@MainActor
extension CompactResumeTranscriptTests {
    func testHiddenSeedEvidenceRetiresWhenVisibleTranscriptIsWiped() async throws {
        let hidden = voiceWindowRows(120..<240).map { row -> [String: Any] in
            var row = row
            row["display_kind"] = "hidden"
            return row
        }
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(sessionId: "runtime-a", messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            persistedTranscript: { _, _, _ in self.tailPagePayload(sessionId: "stored-a", rows: hidden, offset: 0) }
        )
        let state = harness.appState
        state.sessions = [session("stored-a", alternateIDs: ["runtime-a"])]
        let opened = await state.openSession("stored-a")
        XCTAssertTrue(opened)
        let accepted = try XCTUnwrap(state.persistedTranscriptWindow)
        XCTAssertTrue(accepted.hasAcceptedHiddenOnlyPage)
        // Matching identity/offset and verifier IDs alone cannot invent the
        // accepted-window evidence; a newly made arbitrary empty window refuses.
        state.persistedTranscriptWindow = PersistedTranscriptWindowState(
            requestedSessionID: "stored-a", profile: "default", pageSize: 120,
            resolvedSessionID: "stored-a", runtimeSessionID: "runtime-a",
            nextOffset: 120, canLoadEarlier: true)
        XCTAssertFalse(state.canLoadEarlierMessagesForActiveConversation)
        XCTAssertFalse(try XCTUnwrap(state.persistedTranscriptWindow).hasAcceptedHiddenOnlyPage)
        XCTAssertFalse(state.shownChat.durablePersistedRowIDs.isEmpty)
        state.persistedTranscriptWindow = accepted
        XCTAssertTrue(state.canLoadEarlierMessagesForActiveConversation)
        state.messages = [ChatMessage(id: "local-visible", role: .user, content: "Local row", timestamp: "2026-09-01T10:00:00Z")]
        XCTAssertFalse(try XCTUnwrap(state.persistedTranscriptWindow).hasAcceptedHiddenOnlyPage)
        state.messages = []
        XCTAssertFalse(state.canLoadEarlierMessagesForActiveConversation,
            "Wiping visible history must not revive an obsolete hidden-only seed")
        XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, 120)
        XCTAssertEqual(state.persistedTranscriptWindow?.hasBackfilledPrefix, false)
        XCTAssertNil(state.persistedTranscriptWindow?.oldestLoadedTimestamp)
        state.persistedTranscriptWindow = nil
        XCTAssertFalse(state.canLoadEarlierMessagesForActiveConversation)
    }

    func testHiddenSeedEvidenceDoesNotSurviveAcceptedReplacement() async throws {
        for replacement in ["visible-partial", "complete-empty", "legacy-empty"] {
            let hidden = voiceWindowRows(120..<240).map { row -> [String: Any] in
                var row = row
                row["display_kind"] = "hidden"
                return row
            }
            var reads = 0
            let harness = try makeHarness(
                openSession: { _, _, _ in
                    SessionResumeResult(sessionId: "runtime-a", messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
                },
                persistedTranscript: { _, _, _ in
                    reads += 1
                    if reads == 1 { return self.tailPagePayload(sessionId: "stored-a", rows: hidden, offset: 0) }
                    if replacement == "legacy-empty" { return .payload(["session_id": "stored-a", "messages": []]) }
                    return self.tailPagePayload(sessionId: "stored-a",
                        rows: replacement == "visible-partial" ? self.voiceWindowRows(0..<120) : [], offset: 0)
                }
            )
            let state = harness.appState
            state.sessions = [session("stored-a", alternateIDs: ["runtime-a"])]
            let opened = await state.openSession("stored-a")
            XCTAssertTrue(opened)
            XCTAssertTrue(try XCTUnwrap(state.persistedTranscriptWindow).hasAcceptedHiddenOnlyPage)
            let client = try XCTUnwrap(state.client)
            let reconciled = await state.reconcile(sessionId: "stored-a", using: client, token: state.beginReconciliation())
            XCTAssertTrue(reconciled, replacement)
            XCTAssertEqual(reads, 2)
            if replacement == "legacy-empty" {
                XCTAssertNil(state.persistedTranscriptWindow)
            } else {
                XCTAssertFalse(try XCTUnwrap(state.persistedTranscriptWindow).hasAcceptedHiddenOnlyPage, replacement)
                XCTAssertEqual(state.persistedTranscriptWindow?.reachedBeginning, replacement == "complete-empty")
            }
            state.messages = []
            XCTAssertFalse(state.canLoadEarlierMessagesForActiveConversation, replacement)
        }
    }

    func testHiddenPartialFailedReconcileRejectsStaleOwnershipAndRetriesRevision() async throws {
        let hidden = voiceWindowRows(120..<240).map { row -> [String: Any] in
            var row = row
            row["display_kind"] = "hidden"
            return row
        }
        var reads = 0
        var offsets: [Int] = []
        var interrupt: (() -> Void)?
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(sessionId: "runtime-a", messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            persistedTranscript: { _, _, _ in
                reads += 1
                if reads > 1 { return .failed(DashboardTicketBridgeError.http(status: 503, detail: "Synthetic transient history failure")) }
                return self.tailPagePayload(sessionId: "stored-a", rows: hidden, offset: 0)
            },
            loadEarlierTranscriptPage: { id, profile, offset in
                XCTAssertEqual(id, "stored-a")
                XCTAssertEqual(profile, "default")
                offsets.append(offset)
                interrupt?()
                return self.tailPagePayload(sessionId: "stored-a", rows: self.voiceWindowRows(0..<120), offset: offset)
            }
        )
        let state = harness.appState
        state.sessions = [session("stored-a", alternateIDs: ["runtime-a"])]
        let opened = await state.openSession("stored-a")
        XCTAssertTrue(opened)
        let client = try XCTUnwrap(state.client)
        let reconciled = await state.reconcile(sessionId: "stored-a", using: client, token: state.beginReconciliation())
        XCTAssertFalse(reconciled)
        XCTAssertTrue(state.shownChat.durablePersistedRowIDs.isEmpty)
        let retained = try XCTUnwrap(state.persistedTranscriptWindow)
        XCTAssertTrue(retained.hasAcceptedHiddenOnlyPage)
        for staleID in [nil, "runtime-foreign"] as [String?] {
            state.activeSessionId = staleID
            XCTAssertFalse(state.canLoadEarlierMessagesForActiveConversation)
            let refused = await state.loadEarlierPage()
            XCTAssertEqual(refused, .failed)
            XCTAssertEqual(state.persistedTranscriptWindow, retained)
        }
        state.activeSessionId = "runtime-a"
        state.activeProfile = "work"
        XCTAssertFalse(state.canLoadEarlierMessagesForActiveConversation)
        let foreignProfile = await state.loadEarlierPage()
        XCTAssertEqual(foreignProfile, .failed)
        XCTAssertTrue(offsets.isEmpty)
        state.activeProfile = "default"
        XCTAssertTrue(state.canLoadEarlierMessagesForActiveConversation)
        // Ownership lost after the read starts must release single flight
        // without adopting the page, its raw offset or completeness.
        interrupt = { [weak state] in state?.activeSessionId = nil }
        let stale = await state.loadEarlierPage()
        XCTAssertEqual(stale, .failed)
        XCTAssertEqual(state.persistedTranscriptWindow, retained)
        state.activeSessionId = "runtime-a"
        // A write during a legitimate empty seed refuses only this response;
        // accepted window evidence and raw120 stay available for the retry.
        interrupt = { [weak state] in state?.messages = [] }
        let changed = await state.loadEarlierPage()
        XCTAssertEqual(changed, .failed)
        XCTAssertEqual(state.persistedTranscriptWindow, retained)
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertTrue(state.canLoadEarlierMessagesForActiveConversation)
        interrupt = nil
        let retry = await state.loadEarlierPage()
        XCTAssertEqual(retry, .landed)
        XCTAssertEqual(offsets, [120, 120, 120])
        XCTAssertEqual(state.messages.map(\.id), (1...120).map(String.init))
        XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, 240)
        XCTAssertFalse(try XCTUnwrap(state.persistedTranscriptWindow).hasAcceptedHiddenOnlyPage)
        XCTAssertTrue(state.shownChat.durablePersistedRowIDs.isEmpty)
    }

    func testHiddenPartialWindowSurvivesSameChatFailedReconcile() async throws {
        let hidden = voiceWindowRows(120..<240).map { row -> [String: Any] in
            var row = row
            row["display_kind"] = "hidden"
            return row
        }
        var reads = 0
        var resumeCount = 0
        var offsets: [Int] = []
        let harness = try makeHarness(
            openSession: { _, id, compact in
                XCTAssertEqual(id, "stored-a")
                XCTAssertTrue(compact, "A transient history error must not trigger a legacy resume")
                resumeCount += 1
                return SessionResumeResult(sessionId: "runtime-a", messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            persistedTranscript: { id, profile, _ in
                XCTAssertEqual(id, "stored-a")
                XCTAssertEqual(profile, "default")
                reads += 1
                if reads > 1 {
                    return .failed(DashboardTicketBridgeError.http(status: 503, detail: "Synthetic transient history failure"))
                }
                return self.tailPagePayload(sessionId: "stored-a", rows: hidden, offset: 0)
            },
            loadEarlierTranscriptPage: { id, profile, offset in
                XCTAssertEqual(id, "stored-a")
                XCTAssertEqual(profile, "default")
                offsets.append(offset)
                return self.tailPagePayload(sessionId: "stored-a", rows: self.voiceWindowRows(0..<120), offset: offset)
            }
        )
        let state = harness.appState
        state.sessions = [session("stored-a", alternateIDs: ["runtime-a"])]
        let epoch = Date(timeIntervalSince1970: 1_788_256_800)
        state.adoptHostChatCalls([VoiceHostChatCall(callID: "reconcile-hidden-saved", chatID: "stored-a",
            startedAt: epoch.addingTimeInterval(30), endedAt: epoch.addingTimeInterval(30))], profile: "default")
        let opened = await state.openSession("stored-a")
        XCTAssertTrue(opened)
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertEqual(state.shownChat.durablePersistedRowIDs, Set((121...240).map(String.init)))
        XCTAssertTrue(state.canLoadEarlierMessagesForActiveConversation)
        let priorWindow = try XCTUnwrap(state.persistedTranscriptWindow)
        let links = state.voiceCallChatLinks
        let client = try XCTUnwrap(state.client)
        let reconciled = await state.reconcile(sessionId: "stored-a", using: client, token: state.beginReconciliation())
        XCTAssertFalse(reconciled)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(resumeCount, 2)
        XCTAssertNotNil(state.chatSyncErrorMessage)
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertEqual(state.persistedTranscriptWindow, priorWindow, "The failed reconcile retains its accepted owned hidden-only window")
        XCTAssertTrue(state.shownChat.durablePersistedRowIDs.isEmpty, "Verifier evidence must stay transaction-local; do not restore it as a repair")
        XCTAssertEqual(state.activeSessionId, "runtime-a")
        XCTAssertEqual(state.activeProfile, "default")
        let offered = state.canLoadEarlierMessagesForActiveConversation
        XCTAssertTrue(offered, "FAILED_RECONCILE_UI: retained accepted hidden-only history must keep Load earlier")
        var model = TranscriptModel()
        var input = TranscriptModel.Input()
        input.loadsEarlier = offered
        input.hasSavedCopy = state.offlineChatPresentation != nil
        input.chatIsOpening = state.liveChatIsOnItsWay
        _ = model.update(input, targets: [], disclosure: ChatRowDisclosure())
        XCTAssertTrue(model.rows.contains { if case .loadEarlier(isLoading: false) = $0.kind { return true }; return false },
            "FAILED_RECONCILE_MODEL: use the actual selector, not fabricated load eligibility")
        XCTAssertFalse(model.drawsOnlyLoadEarlier)
        try await captureHiddenHistory(state, label: "failed-reconcile")
        XCTAssertTrue(offsets.isEmpty)
        let outcome = await state.loadEarlierPage()
        XCTAssertEqual(outcome, .landed, "FAILED_RECONCILE_ACTION: visible older rows must seed the unchanged owned empty transcript")
        XCTAssertEqual(offsets, [120])
        XCTAssertEqual(state.messages.filter { $0.displayKind != VoiceCallChatLink.displayKind }.map(\.id), (1...120).map(String.init),
            "FAILED_RECONCILE_VISIBLE: preserve every ordinary row in exact order")
        XCTAssertEqual(Array(state.messages.prefix(3)).map(\.id), ["1", "voice-call-reconcile-hidden-saved", "2"])
        XCTAssertEqual(state.messages.filter { $0.id == "voice-call-reconcile-hidden-saved" }.count, 1)
        XCTAssertEqual(state.voiceCallChatLinks, links)
        XCTAssertEqual(VoiceCallChatLinks.load(from: harness.defaults), links)
        XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, 240)
        XCTAssertEqual(state.persistedTranscriptWindow?.reachedBeginning, false)
        XCTAssertEqual(state.persistedTranscriptWindow?.hasBackfilledPrefix, true)
        XCTAssertEqual(state.persistedTranscriptWindow?.loadedPageStarts.map(\.firstRowID), ["1"])
        XCTAssertEqual(state.persistedTranscriptWindow?.oldestLoadedTimestamp, epoch)
        XCTAssertTrue(state.shownChat.durablePersistedRowIDs.isEmpty)
        try await captureHiddenHistory(state, label: "failed-reconcile-backfilled")
    }
}

// A captured stale action must refuse the same emptied transcript as the UI selector.
@MainActor
extension CompactResumeTranscriptTests {
    func testReview6035656478IneligibleEmptyEarlierActionDoesNotConsumePage() async throws {
        var reads = 0
        var offsets: [Int] = []
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(sessionId: "runtime-a", messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            persistedTranscript: { _, _, _ in
                reads += 1
                return self.tailPagePayload(sessionId: "stored-a", rows: self.voiceWindowRows(120..<240), offset: 0)
            },
            loadEarlierTranscriptPage: { id, profile, offset in
                XCTAssertEqual(id, "stored-a")
                XCTAssertEqual(profile, "default")
                offsets.append(offset)
                return self.tailPagePayload(sessionId: "stored-a", rows: self.voiceWindowRows(0..<2), offset: offset)
            }
        )
        let state = harness.appState
        state.sessions = [session("stored-a", alternateIDs: ["runtime-a"])]
        let epoch = Date(timeIntervalSince1970: 1_788_256_800)
        state.adoptHostChatCalls([VoiceHostChatCall(callID: "review-b-saved", chatID: "stored-a",
            startedAt: epoch.addingTimeInterval(30), endedAt: epoch.addingTimeInterval(30))], profile: "default")
        let opened = await state.openSession("stored-a")
        XCTAssertTrue(opened)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(state.messages.map(\.id), (121...240).map(String.init))
        XCTAssertTrue(state.canLoadEarlierMessagesForActiveConversation)
        XCTAssertFalse(try XCTUnwrap(state.persistedTranscriptWindow).hasAcceptedHiddenOnlyPage)
        XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, 120)
        XCTAssertEqual(state.persistedTranscriptWindow?.reachedBeginning, false)
        let links = state.voiceCallChatLinks
        XCTAssertEqual(links.links.count, 1)
        let staleAction = { await state.loadEarlierPage() }
        state.messages = []
        XCTAssertFalse(state.canLoadEarlierMessagesForActiveConversation, "B_PRECONDITION_SELECTOR_FALSE_BEFORE_ACTION")
        XCTAssertFalse(try XCTUnwrap(state.persistedTranscriptWindow).hasAcceptedHiddenOnlyPage)
        let before = try XCTUnwrap(state.persistedTranscriptWindow)
        let outcome = await staleAction()
        XCTAssertEqual(outcome, .failed, "B_INELIGIBLE_ACTION_MUST_REFUSE")
        XCTAssertEqual(offsets, [], "B_INELIGIBLE_ACTION_ZERO_FETCHES")
        XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, before.nextOffset, "B_INELIGIBLE_ACTION_NO_RAW_OFFSET_MUTATION")
        XCTAssertEqual(state.persistedTranscriptWindow?.reachedBeginning, before.reachedBeginning, "B_INELIGIBLE_ACTION_NO_COMPLETENESS_MUTATION")
        XCTAssertEqual(state.persistedTranscriptWindow, before, "B_INELIGIBLE_ACTION_WINDOW_UNCHANGED")
        XCTAssertTrue(state.messages.isEmpty, "Rejected action must not admit ordinary rows or deferred call markers")
        XCTAssertEqual(state.voiceCallChatLinks, links)
        XCTAssertEqual(VoiceCallChatLinks.load(from: harness.defaults), links)
        let receipt: [String: Any] = ["selectorBeforeAction": false, "offsets": offsets,
            "beforeOffset": before.nextOffset, "afterOffset": state.persistedTranscriptWindow?.nextOffset ?? -1,
            "beforeReachedBeginning": before.reachedBeginning,
            "afterReachedBeginning": state.persistedTranscriptWindow?.reachedBeginning ?? false,
            "outcome": String(describing: outcome), "rowIDs": state.messages.map(\.id),
            "linksUnchanged": state.voiceCallChatLinks == links]
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
            .write(to: documents.appendingPathComponent("review6035656478-b.json"), options: .atomic)
    }
}

// Captured from the real isolated model-switch writer and DISPLAY /messages route.
// Raw response bytes are bound in backend-model-switch-01/VERDICT.json; no guessed compression payload.
@MainActor
extension CompactResumeTranscriptTests {
    func testReview6035656478RemoteModelSwitchDoesNotResurrectRemovedPrefix() async throws {
        func payload(_ json: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }
        let before = try payload(#"""
{"pagination":{"limit":120,"offset":0,"order":"latest","returned":3},"profile":"default","session_id":"20261124_160454_d1612f","messages":[
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Kept older row X","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":1,"message_uid":"eddb75f0f16b40bba612939f67bfbe7f","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.3644767,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"[System: The active model for this chat has changed to fixture-model-before via provider fixture-provider. From this point forward, use this runtime metadata when answering questions about what model/provider is active.]","display_kind":"model_switch","display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":2,"message_uid":"a4ed9014aa214426bbe43c49efd23914","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.370923,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Kept anchor B","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":3,"message_uid":"8393e2f9918c4389a52b898a80a3b1d7","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.3754544,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null}
]}
"""#)
        let refreshed = try payload(#"""
{"pagination":{"limit":120,"offset":0,"order":"latest","returned":120},"profile":"default","session_id":"20261124_160454_d1612f","messages":[
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Kept anchor B","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":3,"message_uid":"8393e2f9918c4389a52b898a80a3b1d7","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.3754544,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 0","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":4,"message_uid":"7cbf0ca1c27640afa14d5e25fcdffaeb","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.389395,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 1","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":5,"message_uid":"2e11cf6c0c9a4bce8c108fef37c8c74f","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.3946598,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 2","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":6,"message_uid":"321fd1fd7c1c4eb9be62721b115525ac","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.3993979,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 3","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":7,"message_uid":"2bac54cea11448abb6b560b21fd3c1cc","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.4042659,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 4","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":8,"message_uid":"e4d39514b8bf4b31b33a36f1f82ad998","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.4092014,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 5","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":9,"message_uid":"3ece6275478a4a16b1086738625639a3","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.4140465,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 6","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":10,"message_uid":"0c2aa3fb45ce405a982ca9843f830083","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.4186313,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 7","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":11,"message_uid":"4e49c3d414c74020999f5987fb6781da","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.4235575,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 8","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":12,"message_uid":"02d7766e195544818f1831ed92de6e5d","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.4292452,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 9","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":13,"message_uid":"9b81adf212684b09971306e65fdbbf49","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.4342523,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 10","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":14,"message_uid":"0edbbb53645c48a4aa75aa5c492aa496","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.4387698,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 11","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":15,"message_uid":"7f796721de23425ebbb38003f745a72d","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.4434094,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 12","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":16,"message_uid":"849b367cc77b46efb52d86b686487a87","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.4481313,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 13","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":17,"message_uid":"b5dc28bb44fe43f199ae24e0a29d3905","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.4532688,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 14","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":18,"message_uid":"469af9362e2b40a4a69d897f36ef12bb","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.4582617,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 15","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":19,"message_uid":"dbdf132f33834021a58c738cc0d3fb92","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.4632044,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 16","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":20,"message_uid":"a4094f6cf72a49ee8ae12d8c264f4215","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.468264,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 17","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":21,"message_uid":"5d491bbbe41a4c63aee0a4efcce4cb2d","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.4728267,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 18","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":22,"message_uid":"d50a380521094ac290fb3b0241e0bc1e","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.4776788,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 19","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":23,"message_uid":"dea5662f815849d68fc89982b1990c03","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.4829907,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 20","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":24,"message_uid":"55b5fbc3ae014772aa0c2d41881e6a42","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.488534,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 21","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":25,"message_uid":"6231d35a142540269c51cebd754a9b26","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.4936821,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 22","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":26,"message_uid":"14b7a7c0f5dc44ba82db1e460b8ecadc","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.4987886,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 23","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":27,"message_uid":"9e7510e7ef2d4657946c298d033922e6","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.503766,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 24","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":28,"message_uid":"1f3d103544f74178921f760ac2ebe2ab","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.5088573,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 25","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":29,"message_uid":"acdf9fe6a2294cbb92b28d387225db0f","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.5136847,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 26","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":30,"message_uid":"659d6bb24d40492a8dcc7c26518192f0","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.5183203,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 27","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":31,"message_uid":"e2ccfc3024af4c4c94cca8be3a918e1b","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.5228987,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 28","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":32,"message_uid":"b1293f12fa3a4511899c1878b89649e3","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.5276902,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 29","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":33,"message_uid":"fcfb925a26b7440aa434588e18b5e4aa","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.5330377,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 30","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":34,"message_uid":"0d31ad9dd1df45f0b2b009d149f7c383","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.5375495,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 31","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":35,"message_uid":"8e2599445cbd4de7bf86b460f8eba8c4","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.5423346,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 32","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":36,"message_uid":"ee24cdaa9d3a4795bf2a79f875583277","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.547805,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 33","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":37,"message_uid":"836ba9b90716466ca8ff0931b459ec02","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.5546653,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 34","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":38,"message_uid":"71590ae41eca4c3f82277333ffbf02fc","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.5610118,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 35","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":39,"message_uid":"6879315ce05c4dd69c0ffd2f9d7b49a6","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.5666487,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 36","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":40,"message_uid":"3b732ee5aa4f4ebaa9fc0714574e0c89","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.571568,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 37","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":41,"message_uid":"5ee50619641a474fad58be68df986f77","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.5771942,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 38","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":42,"message_uid":"682683e9b5eb4bd78e01fab25d69ce5d","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.5824256,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 39","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":43,"message_uid":"6b334b28199e41a0b5ffd6d1f967fe67","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.587891,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 40","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":44,"message_uid":"5d427ab5402c4b1983ed37eed3a7d267","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.5926945,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 41","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":45,"message_uid":"7ae8f427b07942858c4443fb6e379587","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.5978725,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 42","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":46,"message_uid":"a01b133738054600af1add81c0eada58","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.603003,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 43","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":47,"message_uid":"6d9d7ad1b2f346d992331386d3c56f82","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.6081958,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 44","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":48,"message_uid":"88aaaeb4e27b4678aecd7064c05a95ec","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.6162002,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 45","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":49,"message_uid":"66dcbf121626460d800f5cd269518162","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.6249554,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 46","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":50,"message_uid":"325ee4a4f80b46b49ecb9de6e5e38567","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.63145,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 47","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":51,"message_uid":"ada369f3949e4365b4a4a0fa39f8e52c","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.6359718,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 48","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":52,"message_uid":"ce8539907a624af89faf6ba68dbbba23","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.641093,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 49","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":53,"message_uid":"0be6ef88ac664b2c8fe3d3c84f6e874e","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.645745,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 50","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":54,"message_uid":"52bb35171bce4c339f0c8c0d4fd483ec","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.6501138,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 51","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":55,"message_uid":"6b73ffeeb1284c3cb33493348b69ef43","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.6548843,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 52","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":56,"message_uid":"0ddb04f5fe8b493ca899ae7e194e82f8","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.6594527,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 53","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":57,"message_uid":"2569d648b1024c7ea8e8c7bdd73acdc5","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.6643925,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 54","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":58,"message_uid":"1d656d64a5614a089ebfc8ae9513f08c","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.6692057,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 55","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":59,"message_uid":"c465b9c70a454f2e98bf7d28499a8c64","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.6741116,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 56","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":60,"message_uid":"7765110ce71c4ee3905f89c8e826ad61","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.67878,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 57","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":61,"message_uid":"cd667e0088064407a6942f5784ad23cc","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.6844132,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 58","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":62,"message_uid":"e5b88de4dd214bdcb6acb7dcbc39e382","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.6896343,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 59","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":63,"message_uid":"54025449274641d6a9e3a1d5712a3bba","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.6945107,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 60","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":64,"message_uid":"15747e1276814372aadd875851753344","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.699017,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 61","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":65,"message_uid":"a1f122172c77446db53cf8bf0b4480c0","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.7038884,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 62","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":66,"message_uid":"979ab821befc4948841543ac73cb5f3c","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.7090228,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 63","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":67,"message_uid":"04b19e29f719490fa10f1c2dfa2890d4","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.7145617,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 64","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":68,"message_uid":"7edca7c6bfe54b2aa94f562a7dc95fcb","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.719436,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 65","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":69,"message_uid":"7e09573164504d2b85f999ff689041a7","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.7243106,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 66","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":70,"message_uid":"c18aa67d32a84b84887ff5b5b64e99eb","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.729184,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 67","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":71,"message_uid":"1a94d91d11a34dddb9bdeba0de2871e9","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.7341862,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 68","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":72,"message_uid":"881699c131f14288bc973456496316ef","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.7387624,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 69","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":73,"message_uid":"c4d588ba948f46469dd8c64f9724aac2","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.7437942,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 70","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":74,"message_uid":"17f1d8ac479449e990e62afe4f7da418","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.7488315,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 71","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":75,"message_uid":"a1065eee498d40f08965fb38e43ee9eb","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.7539809,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 72","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":76,"message_uid":"06cdb2dfbee24666a69bc4c6a45527bb","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.7591343,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 73","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":77,"message_uid":"491945d1a04a4c4c877de4d2f86c99bc","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.7637794,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 74","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":78,"message_uid":"f22afbefd4b7420c8862b705a7024e0b","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.7689397,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 75","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":79,"message_uid":"56bcecbad2e2468a877515ad36a80cca","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.773911,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 76","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":80,"message_uid":"65f9dea9f1fd435fb154169fcb8a095a","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.7789576,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 77","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":81,"message_uid":"73b28fb5d5d34849a1081f71cc35fc8f","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.7838955,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 78","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":82,"message_uid":"3177eeddb67d4bc593b32db65b3ea353","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.7886453,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 79","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":83,"message_uid":"78bd804a3806461c8ce7f71fd9649d23","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.7934017,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 80","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":84,"message_uid":"1a6fcf44b22747669c0b26e7aa18d9bf","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.797215,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 81","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":85,"message_uid":"fe440a664cc245de9a415681d8609197","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.8017492,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 82","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":86,"message_uid":"04b9355ce8874294a758494cdc3d5a1f","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.8069208,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 83","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":87,"message_uid":"a73535db13774f1da3b992986e12f51a","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.8114414,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 84","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":88,"message_uid":"5a44c7d9cd00401595297b9b0e90172a","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.816228,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 85","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":89,"message_uid":"a59cf4c3baa24e64916c798453684c6e","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.820692,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 86","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":90,"message_uid":"1ca7b433fa014a9c851c945bf4a48e92","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.825615,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 87","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":91,"message_uid":"c3204576297741e3aa38e62d02e4a3d4","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.8302658,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 88","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":92,"message_uid":"1cf6b030da4b4c9ab7b793f064b37463","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.8352056,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 89","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":93,"message_uid":"02edd5508734415d823bf11caea04b62","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.8403912,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 90","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":94,"message_uid":"4e4e00982c244d6b84e77311c242f0da","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.8455868,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 91","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":95,"message_uid":"2bb5e428f2bf44a29f470ee2c395f75f","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.8506372,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 92","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":96,"message_uid":"4bfbc205e3b74df19a61cfdeb31f02cc","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.857302,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 93","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":97,"message_uid":"ce0c1c7b00754cc4a5ffc9a0b80907fe","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.8641963,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 94","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":98,"message_uid":"ded053b845444694a99327660b7039fe","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.8694215,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 95","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":99,"message_uid":"c39d2a50eb014230b90617228c7d94df","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.8783526,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 96","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":100,"message_uid":"4dc2f340c5eb459f99f677f4800eb6fc","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.8853126,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 97","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":101,"message_uid":"de942e2427944992bfffd5d7ae5e27a6","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.8900836,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 98","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":102,"message_uid":"6ded230fc4c043a3b99c9a228ee5ce29","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.8953807,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 99","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":103,"message_uid":"34afe803ec8d4219ac29d8461624eaad","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.9003665,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 100","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":104,"message_uid":"d568026a188c4114903d0e3352799851","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.905119,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 101","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":105,"message_uid":"226dff410cf54feea47a44c90953085f","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.9100332,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 102","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":106,"message_uid":"ac7b38a2e1b84c389b61bc4fa9eae492","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.9163015,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 103","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":107,"message_uid":"1111294229924eaaad501319626f810d","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.9213681,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 104","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":108,"message_uid":"d35378f10c8d4ce2b174802cb2855fa4","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.9260263,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 105","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":109,"message_uid":"db11b2cb10f74986ac07d4b5956afbc6","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.9311886,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 106","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":110,"message_uid":"d2a8307d3bb84b0e95723f4202487622","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.9369447,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 107","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":111,"message_uid":"7304be8fb365464ba365046d293177db","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.9420018,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 108","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":112,"message_uid":"1ca35d6d4e9249f3aa29aa058c89be30","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.9468267,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 109","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":113,"message_uid":"c8b5cbb2d7b94bde9380e7f6b177b57a","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.951779,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 110","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":114,"message_uid":"32019f2d708c4808b74439d159f1f2da","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.9563284,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 111","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":115,"message_uid":"7b57d5fdb9e9473181528240559e9dd0","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.9609833,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 112","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":116,"message_uid":"578cde59679942aa9a9c471f15c60182","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.9657187,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 113","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":117,"message_uid":"19f498d548ad42f88330f9a173afba75","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.9704676,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 114","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":118,"message_uid":"940fb72e0957444f9347c408c3fd3780","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.9752998,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 115","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":119,"message_uid":"6a2df364875e4fe3b23dcb8b23dc82b6","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.980527,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 116","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":120,"message_uid":"c7f3e3d902e349dfb60bf5393c3b44c4","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.9847736,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Remote growth 117","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":121,"message_uid":"a89213cc6f7648848e247ac385d1f305","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"assistant","session_id":"20261124_160454_d1612f","timestamp":1795536295.9894543,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null},
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"[System: The active model for this chat has changed to fixture-model-after via provider fixture-provider. From this point forward, use this runtime metadata when answering questions about what model/provider is active.]","display_kind":"model_switch","display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":122,"message_uid":"c44b35ca200546d8a37f26e83dba00c6","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.9988883,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null}
]}
"""#)
        let earlier = try payload(#"""
{"pagination":{"limit":120,"offset":120,"order":"latest","returned":1},"profile":"default","session_id":"20261124_160454_d1612f","messages":[
{"absorbed_message_uids":null,"active":1,"api_content":null,"codex_message_items":null,"codex_reasoning_items":null,"compacted":0,"content":"Kept older row X","display_kind":null,"display_metadata":null,"effect_disposition":null,"finish_reason":null,"id":1,"message_uid":"eddb75f0f16b40bba612939f67bfbe7f","observed":0,"platform_message_id":null,"reasoning":null,"reasoning_content":null,"reasoning_details":null,"role":"user","session_id":"20261124_160454_d1612f","timestamp":1795536295.3644767,"token_count":null,"tool_call_id":null,"tool_call_uid":null,"tool_call_uids":null,"tool_calls":null,"tool_name":null}
]}
"""#)
        let stored = try XCTUnwrap(before["session_id"] as? String)
        let active = session(stored)
        let initialRows = MessageNormalizer.normalizeMessages(try XCTUnwrap(before["messages"] as? [Any]).map(AnyCodable.from))
        let tailRows = MessageNormalizer.normalizeMessages(try XCTUnwrap(refreshed["messages"] as? [Any]).map(AnyCodable.from))
        let earlierRows = MessageNormalizer.normalizeMessages(try XCTUnwrap(earlier["messages"] as? [Any]).map(AnyCodable.from))
        XCTAssertEqual(initialRows.map(\.id), ["1.0", "2.0", "3.0"])
        XCTAssertEqual(tailRows.count, 120)
        XCTAssertEqual(tailRows.first?.id, "3.0")
        XCTAssertEqual(earlierRows.map(\.id), ["1.0"])
        var reads = 0
        var offsets: [Int] = []
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(sessionId: stored, messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            persistedTranscript: { _, _, query in
                XCTAssertEqual(query, PersistedTranscriptPagination.tailQuery(offset: 0))
                reads += 1
                return .payload(reads == 1 ? before : refreshed)
            },
            loadEarlierTranscriptPage: { id, profile, offset in
                XCTAssertEqual(id, stored); XCTAssertEqual(profile, "default")
                offsets.append(offset)
                return .payload(earlier)
            },
            additionalOperations: { ops in
                ops.connectClient = { _ in }; ops.loadCatalog = { _, _ in [active] }
                ops.loadProfiles = {}; ops.loadBusyInputMode = { _ in }
                ops.loadProfileDisplayPreferences = {}; ops.loadSlashCommands = {}
            }
        )
        let state = harness.appState
        state.sessions = [active]
        let opened = await state.openSession(stored)
        XCTAssertTrue(opened)
        XCTAssertEqual(state.messages, initialRows)
        XCTAssertEqual(state.persistedTranscriptWindow?.reachedBeginning, true)
        XCTAssertEqual(state.persistedTranscriptWindow?.hasBackfilledPrefix, false)
        let links = state.voiceCallChatLinks
        try await captureHiddenHistory(state, label: "review-a-before")
        harness.coordinator.rememberSession(.dashboard(profile: "default", sessionID: stored), for: "default")
        await state.connect(with: HermesConnection(baseUrl: "https://one.example", ticket: "captured-model-switch-refresh"))
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(offsets.isEmpty, "No speculative prefix read; old rows remain explicitly loadable")
        XCTAssertFalse(state.messages.contains { $0.id == "2.0" }, "A_REMOVED_PREFIX_NOTICE_MUST_NOT_RESURRECT")
        XCTAssertEqual(state.messages, tailRows, "A_REPLACEMENT_SIGNAL_INVALIDATES_POTENTIALLY_STALE_PREFIX")
        XCTAssertEqual(state.persistedTranscriptWindow?.reachedBeginning, false)
        XCTAssertEqual(state.persistedTranscriptWindow?.hasBackfilledPrefix, false)
        XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, 120)
        XCTAssertTrue(state.canLoadEarlierMessagesForActiveConversation)
        try await captureHiddenHistory(state, label: "review-a-refreshed")
        let outcome = await state.loadEarlierPage()
        XCTAssertEqual(outcome, .landed)
        XCTAssertEqual(offsets, [120])
        XCTAssertEqual(state.messages, earlierRows + tailRows, "Retained ordinary X returns from actual authoritative backfill, never stale marker A")
        XCTAssertFalse(state.messages.contains { $0.id == "2.0" })
        XCTAssertEqual(state.persistedTranscriptWindow?.reachedBeginning, true)
        XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, 121)
        XCTAssertEqual(state.voiceCallChatLinks, links)
        try await captureHiddenHistory(state, label: "review-a-backfilled")
        await state.connect(with: HermesConnection(baseUrl: "https://one.example", ticket: "captured-model-switch-second-refresh"))
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(state.messages, earlierRows + tailRows)
        XCTAssertEqual(offsets, [120])
    }
}

@MainActor
extension CompactResumeTranscriptTests {
    func testReview6043623895ReconnectKeepsPrefixWhenTailNoticeIsAlreadyHeld() async throws {
        let active = session("stored-a", alternateIDs: ["runtime-a"])
        func rows(_ range: Range<Int>, notice: Int) -> [[String: Any]] {
            self.syntheticRows(range).map { row in
                var row = row
                if row["id"] as? Int == notice {
                    row["display_kind"] = "model_switch"
                }
                return row
            }
        }
        let tail = rows(1880..<2000, notice: 1950)
        let older = rows(1760..<1880, notice: 1800)
        var reads = 0
        var offsets: [Int] = []
        let harness = try makeHarness(
            openSession: { _, _, _ in
                SessionResumeResult(sessionId: "runtime-a", messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)]))
            },
            persistedTranscript: { _, _, query in
                XCTAssertEqual(query, PersistedTranscriptPagination.tailQuery(offset: 0))
                reads += 1
                return self.tailPagePayload(sessionId: "stored-a", rows: tail, offset: 0)
            },
            loadEarlierTranscriptPage: { _, _, offset in
                offsets.append(offset)
                return self.tailPagePayload(sessionId: "stored-a", rows: older, offset: offset)
            },
            additionalOperations: { ops in
                ops.connectClient = { _ in }; ops.loadCatalog = { _, _ in [active] }
                ops.loadProfiles = {}; ops.loadBusyInputMode = { _ in }
                ops.loadProfileDisplayPreferences = {}; ops.loadSlashCommands = {}
            }
        )
        let state = harness.appState
        state.sessions = [active]
        let opened = await state.openSession("stored-a")
        XCTAssertTrue(opened)
        let landed = await state.loadEarlierMessages()
        XCTAssertTrue(landed)
        let held = state.messages
        XCTAssertEqual(held.count, 240)
        XCTAssertEqual(held.filter { $0.displayKind == "model_switch" }.count, 2)
        let links = state.voiceCallChatLinks
        harness.coordinator.rememberSession(.dashboard(profile: "default", sessionID: "stored-a"), for: "default")
        for _ in 0..<2 {
            await state.connect(with: HermesConnection(baseUrl: "https://one.example", ticket: "known-notice-control"))
            XCTAssertEqual(state.messages, held, "KNOWN_NOTICE_RECONNECT_MUST_RETAIN_EXACT_PREFIX")
            XCTAssertEqual(state.persistedTranscriptWindow?.hasBackfilledPrefix, true)
            XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, 120)
            XCTAssertEqual(state.voiceCallChatLinks, links)
        }
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(offsets, [120], "No speculative earlier fetch during either reconnect")
    }
}

@MainActor
extension CompactResumeTranscriptTests {
    func testReview6043623895MismatchedEarlierOffsetKeepsHeldPageRetryable() async throws {
        try await assertReview604EarlierOffsetMismatch(hiddenSeed: false)
    }

    func testReview6043623895MismatchedEarlierOffsetKeepsHiddenSeedRetryable() async throws {
        try await assertReview604EarlierOffsetMismatch(hiddenSeed: true)
    }

    private func assertReview604EarlierOffsetMismatch(hiddenSeed: Bool) async throws {
        let initial = voiceWindowRows(120..<240).map { raw -> [String: Any] in
            var row = raw
            if hiddenSeed { row["display_kind"] = "hidden" }
            return row
        }
        var offsets: [Int] = []
        let harness = try makeHarness(
            openSession: { _, _, _ in SessionResumeResult(sessionId: "runtime-a", messages: [], snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])) },
            persistedTranscript: { _, _, _ in self.tailPagePayload(sessionId: "stored-a", rows: initial, offset: 0) },
            loadEarlierTranscriptPage: { _, _, offset in
                offsets.append(offset)
                return self.tailPagePayload(sessionId: "stored-a", rows: self.voiceWindowRows(offsets.count == 1 ? 0..<2 : 0..<120),
                    offset: offsets.count == 1 ? offset + 120 : offset)
            }
        )
        let state = harness.appState
        state.sessions = [session("stored-a", alternateIDs: ["runtime-a"])]
        let epoch = Date(timeIntervalSince1970: 1_788_256_800)
        state.adoptHostChatCalls([VoiceHostChatCall(callID: "offset-saved", chatID: "stored-a",
            startedAt: epoch.addingTimeInterval(30), endedAt: epoch.addingTimeInterval(30))], profile: "default")
        let opened = await state.openSession("stored-a")
        XCTAssertTrue(opened)
        XCTAssertTrue(state.canLoadEarlierMessagesForActiveConversation)
        let held = state.messages
        let window = try XCTUnwrap(state.persistedTranscriptWindow)
        let provenance = state.shownChat.durablePersistedRowIDs
        let links = state.voiceCallChatLinks
        let rejected = await state.loadEarlierPage()
        XCTAssertEqual(rejected, .failed, "WRONG_OFFSET_MUST_NOT_PUBLISH_OR_CONSUME_COVERAGE")
        XCTAssertEqual(state.messages, held)
        XCTAssertEqual(state.persistedTranscriptWindow, window, "Rejected page must not alter completeness, cutoff, starts or hidden seed evidence")
        XCTAssertEqual(state.shownChat.durablePersistedRowIDs, provenance)
        XCTAssertEqual(state.voiceCallChatLinks, links)
        XCTAssertTrue(state.canLoadEarlierMessagesForActiveConversation)
        let retry = await state.loadEarlierPage()
        XCTAssertEqual(retry, .landed)
        XCTAssertEqual(offsets, [120, 120], "Explicit retry re-reads the same raw page; never silently skips the mismatch")
        XCTAssertEqual(state.persistedTranscriptWindow?.nextOffset, 240)
        XCTAssertEqual(state.persistedTranscriptWindow?.reachedBeginning, false)
        XCTAssertEqual(state.messages.filter { $0.displayKind != VoiceCallChatLink.displayKind }.map(\.id),
            (hiddenSeed ? Array(1...120) : Array(1...240)).map(String.init))
        XCTAssertEqual(state.voiceCallChatLinks, links)
        XCTAssertEqual(VoiceCallChatLinks.load(from: harness.defaults), links)
    }
}
