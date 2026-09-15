import XCTest
@testable import Conduit

/// Regression coverage for the dedicated `/compress` path: `session.compress`
/// with its LLM-scale timeout, upstream response semantics (pending /
/// lock-held / aborted / transcript adoption), the legacy `slash.exec`
/// fallback for gateways missing the method, and the stale-completion guards.
@MainActor
final class AppStateSessionCompressTests: XCTestCase {

    // MARK: - Routing

    func testCompressRoutesToDedicatedRPCAndAdoptsTranscript() async throws {
        let recorder = SlashCallRecorder()
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            executeSlash: { _, _, _ in
                recorder.recordSlashExec()
                return .object(["type": .string("exec"), "output": .string("should not run")])
            },
            compressSession: { _, sessionID, focusTopic in
                recorder.recordCompress(sessionID: sessionID, focusTopic: focusTopic)
                return Self.compressedResult()
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        let submitted = await harness.appState.submitComposer(text: "/compress")
        XCTAssertTrue(submitted)
        XCTAssertEqual(recorder.compressCalls.count, 1, "/compress must use the dedicated session.compress RPC")
        XCTAssertEqual(recorder.compressCalls.first?.sessionID, "composer-origin")
        XCTAssertNil(recorder.compressCalls.first?.focusTopic)
        XCTAssertEqual(recorder.slashExecCount, 0, "A supported compression must not ride slash.exec")
        XCTAssertEqual(recorder.dispatchCount, 0)

        // The post-compress transcript replaces the local rows immediately,
        // followed by the summary record.
        let roles = harness.appState.messages.map { $0.role }
        XCTAssertEqual(roles.first, .user)
        XCTAssertEqual(harness.appState.messages.first?.content, "Summary carrier")
        XCTAssertEqual(harness.appState.messages.dropFirst().first?.content, "Tail answer")
        XCTAssertEqual(roles.last, .system, "The compression summary lands as the slash-output record")
        XCTAssertEqual(harness.appState.messages.last?.content, "Compressed 13 → 4 messages")
        XCTAssertTrue(harness.appState.compressingSessionIDs.isEmpty)
    }

    func testCompactAliasRoutesIdentically() async throws {
        let recorder = SlashCallRecorder()
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            executeSlash: { _, _, _ in
                recorder.recordSlashExec()
                return .object(["type": .string("exec"), "output": .string("should not run")])
            },
            compressSession: { _, sessionID, focusTopic in
                recorder.recordCompress(sessionID: sessionID, focusTopic: focusTopic)
                return SessionCompressResult(from: .object(["status": .string("compressed"), "removed": .number(2)]))
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        let submitted = await harness.appState.submitComposer(text: "/compact")
        XCTAssertTrue(submitted)
        XCTAssertEqual(recorder.compressCalls.count, 1)
        XCTAssertEqual(recorder.slashExecCount, 0)
        // No transcript payload: the count-based confirmation renders instead.
        XCTAssertEqual(harness.appState.messages.last?.content, "Compressed 2 messages.")
    }

    func testCompressPassesArgumentAsFocusTopic() async throws {
        let recorder = SlashCallRecorder()
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            compressSession: { _, sessionID, focusTopic in
                recorder.recordCompress(sessionID: sessionID, focusTopic: focusTopic)
                return SessionCompressResult(from: .object(["status": .string("compressed")]))
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        _ = await harness.appState.submitComposer(text: "/compress auth refactor")
        XCTAssertEqual(recorder.compressCalls.first?.focusTopic, "auth refactor")
    }

    // MARK: - Older-gateway fallback

    func testMissingMethodFallsBackToLegacySlashPath() async throws {
        let recorder = SlashCallRecorder()
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            executeSlash: { _, _, command in
                recorder.recordSlashExec(command: command)
                return .object(["type": .string("exec"), "output": .string("legacy output")])
            },
            compressSession: { _, _, _ in
                recorder.recordCompress(sessionID: "composer-origin", focusTopic: nil)
                throw RpcError(code: -32601, message: "unknown method: session.compress")
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        let submitted = await harness.appState.submitComposer(text: "/compress")
        XCTAssertTrue(submitted)
        XCTAssertEqual(recorder.compressCalls.count, 1, "The dedicated RPC is tried first")
        XCTAssertEqual(recorder.slashExecCount, 1, "A missing-method failure must fall back to the legacy slash path")
        XCTAssertEqual(recorder.slashExecCommands.first, "compress")
        XCTAssertEqual(harness.appState.messages.last?.content, "legacy output")
    }

    func testTimeoutDoesNotTriggerLegacyFallback() async throws {
        let recorder = SlashCallRecorder()
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            executeSlash: { _, _, _ in
                recorder.recordSlashExec()
                return .object(["type": .string("exec"), "output": .string("must not run")])
            },
            dispatchCommand: { _, _, _, _ in
                recorder.recordDispatch()
                return .object(["type": .string("exec"), "output": .string("must not run")])
            },
            compressSession: { _, _, _ in
                recorder.recordCompress(sessionID: "composer-origin", focusTopic: nil)
                throw HermesError.timeout("session.compress")
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        _ = await harness.appState.submitComposer(text: "/compress")
        // A timeout means the gateway IS compressing; re-running /compress
        // through the legacy route would start a second server-side
        // compression.
        XCTAssertEqual(recorder.slashExecCount, 0)
        XCTAssertEqual(recorder.dispatchCount, 0)
        let lastRow = try XCTUnwrap(harness.appState.messages.last)
        XCTAssertEqual(lastRow.role, .system)
        XCTAssertTrue(
            lastRow.content.hasPrefix("⚠️ Compression failed:"),
            "Expected a visible compression failure row, got: \(lastRow.content)"
        )
    }

    func testSessionBusyRejectionIsNotTreatedAsMissingMethod() async throws {
        let recorder = SlashCallRecorder()
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            executeSlash: { _, _, _ in
                recorder.recordSlashExec()
                return .object(["type": .string("exec"), "output": .string("must not run")])
            },
            compressSession: { _, _, _ in
                recorder.recordCompress(sessionID: "composer-origin", focusTopic: nil)
                throw RpcError(code: 4009, message: "session busy — /interrupt the current turn before /compress")
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        _ = await harness.appState.submitComposer(text: "/compress")
        XCTAssertEqual(recorder.slashExecCount, 0, "A busy rejection must not be retried through the legacy path")
        XCTAssertEqual(recorder.dispatchCount, 0)
        XCTAssertTrue(harness.appState.messages.last?.content.hasPrefix("⚠️ Compression failed:") == true)
    }

    // MARK: - Response semantics

    func testPendingResultIsInformationalAndKeepsTranscript() async throws {
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            compressSession: { _, _, _ in
                SessionCompressResult(from: .object([
                    "status": .string("pending"),
                    "message": .string("compression still running in the background")
                ]))
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id
        harness.appState.messages = [ChatMessage(id: "m1", role: .assistant, content: "Existing", timestamp: "1")]

        let submitted = await harness.appState.submitComposer(text: "/compress")
        XCTAssertTrue(submitted)
        XCTAssertEqual(harness.appState.messages.first?.content, "Existing", "A pending response must not touch the transcript")
        XCTAssertEqual(harness.appState.messages.count, 2)
        XCTAssertEqual(harness.appState.messages.last?.content, "compression still running in the background")
        XCTAssertEqual(harness.appState.messages.last?.role, .system)
        XCTAssertTrue(harness.appState.compressingSessionIDs.isEmpty)
    }

    func testLockHeldResultIsInformational() async throws {
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            compressSession: { _, _, _ in
                SessionCompressResult(from: .object([
                    "compressed": .bool(false),
                    "lock_held": .bool(true),
                    "message": .string("compression already running")
                ]))
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        let submitted = await harness.appState.submitComposer(text: "/compress")
        XCTAssertTrue(submitted)
        XCTAssertEqual(harness.appState.messages.count, 1)
        XCTAssertEqual(harness.appState.messages.last?.content, "compression already running")
        XCTAssertNotEqual(
            harness.appState.messages.last?.content.hasPrefix("⚠️"),
            true,
            "A held compression lock is not an error"
        )
    }

    func testAbortedCompressionAdoptsAuthoritativeHistoryAndWarns() async throws {
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            compressSession: { _, _, _ in
                SessionCompressResult(from: .object([
                    "status": .string("aborted"),
                    "summary": .object(["headline": .string("compression aborted: provider error")]),
                    "messages": .array([
                        .object([
                            "role": .string("assistant"),
                            "content": .string("Gateway authoritative tail"),
                            "timestamp": .string("2026-09-13T08:00:00Z")
                        ])
                    ])
                ]))
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id
        harness.appState.messages = [
            ChatMessage(id: "m1", role: .user, content: "Stale local row", timestamp: "1")
        ]

        _ = await harness.appState.submitComposer(text: "/compress")
        // Upstream Desktop parity: the transcript adopts the gateway's
        // authoritative (unchanged) history whenever `messages` is present;
        // the abort only turns the chat record into a warning.
        XCTAssertEqual(harness.appState.messages.first?.content, "Gateway authoritative tail")
        let lastRow = try XCTUnwrap(harness.appState.messages.last)
        XCTAssertEqual(lastRow.role, .system)
        XCTAssertTrue(lastRow.content.hasPrefix("⚠️"), "Expected the abort to surface, got: \(lastRow.content)")
    }

    func testSummaryAbortedFlagWithMessagesAdoptsAndWarns() async throws {
        // Compute-host results can carry `summary.aborted` while `status`
        // still reads "compressed"; abort detection must catch it.
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            compressSession: { _, _, _ in
                SessionCompressResult(from: .object([
                    "status": .string("compressed"),
                    "summary": .object(["aborted": .bool(true), "note": .string("no usable summary")]),
                    "messages": .array([
                        .object([
                            "role": .string("user"),
                            "content": .string("Carrier"),
                            "timestamp": .string("2026-09-13T08:00:00Z")
                        ])
                    ])
                ]))
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        _ = await harness.appState.submitComposer(text: "/compress")
        XCTAssertEqual(harness.appState.messages.first?.content, "Carrier")
        XCTAssertTrue(harness.appState.messages.last?.content.hasPrefix("⚠️") == true)
    }

    func testEmptyMessagesPayloadAdoptsEmptyTranscript() async throws {
        // The gateway transcript is authoritative even when the compressed
        // history is empty; this pins the deliberate parity-with-Desktop
        // behavior for a present-but-empty `messages` payload.
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            compressSession: { _, _, _ in
                SessionCompressResult(from: .object([
                    "status": .string("compressed"),
                    "messages": .array([])
                ]))
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id
        harness.appState.messages = [ChatMessage(id: "m1", role: .user, content: "Old", timestamp: "1")]

        _ = await harness.appState.submitComposer(text: "/compress")
        XCTAssertEqual(harness.appState.messages.count, 1, "The empty transcript is adopted; only the record row remains")
        XCTAssertEqual(harness.appState.messages.last?.content, "Nothing to compress.")
    }

    func testHostAckOutputRendersWhenNoSummaryPresent() async throws {
        // Compute-host results without summary lines fall back to the host's
        // own feedback before the removed-count text (upstream Desktop order).
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            compressSession: { _, _, _ in
                SessionCompressResult(from: .object([
                    "status": .string("compressed"),
                    "removed": .number(4),
                    "host_ack": .object(["output": .string("  host feedback  ")]),
                    "messages": .array([
                        .object([
                            "role": .string("user"),
                            "content": .string("Carrier"),
                            "timestamp": .string("2026-09-13T08:00:00Z")
                        ])
                    ])
                ]))
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        _ = await harness.appState.submitComposer(text: "/compress")
        XCTAssertEqual(harness.appState.messages.first?.content, "Carrier", "The transcript still adopts")
        XCTAssertEqual(harness.appState.messages.last?.content, "host feedback", "Host output renders trimmed when no summary exists")
    }

    func testSummaryLinesTakePrecedenceOverHostAckOutput() async throws {
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            compressSession: { _, _, _ in
                SessionCompressResult(from: .object([
                    "status": .string("compressed"),
                    "summary": .object(["headline": .string("the summary")]),
                    "host_ack": .object(["output": .string("host feedback")]),
                    "messages": .array([])
                ]))
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        _ = await harness.appState.submitComposer(text: "/compress")
        XCTAssertEqual(harness.appState.messages.last?.content, "the summary")
    }

    func testRunningTurnDefersTranscriptAdoption() async throws {
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            compressSession: { _, _, _ in
                Self.compressedResult()
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id
        harness.appState.messages = [
            ChatMessage(id: "m1", role: .user, content: "Fresh local row", timestamp: "1")
        ]
        // A turn started while the compression RPC was in flight (the gateway
        // allows it on compute-host sessions): the live turn owns the
        // transcript now.
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: origin.id, busy: true))
        XCTAssertEqual(harness.appState.turnState, .running)

        _ = await harness.appState.submitComposer(text: "/compress")
        // The in-flight turn's rows survive; the next authoritative sync
        // converges on the compressed history.
        XCTAssertEqual(harness.appState.messages.first?.content, "Fresh local row")
        XCTAssertEqual(harness.appState.messages.count, 2)
        XCTAssertTrue(harness.appState.transcriptFreshnessIsStale)
        XCTAssertEqual(harness.appState.messages.last?.content, "Compressed 13 → 4 messages")
    }

    // MARK: - Concurrency + staleness

    func testDuplicateCompressWhilePendingDoesNotLaunchSecondOperation() async throws {
        let recorder = SlashCallRecorder()
        let gate = ControlledSuspension()
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            compressSession: { _, sessionID, focusTopic in
                recorder.recordCompress(sessionID: sessionID, focusTopic: focusTopic)
                await gate.suspend()
                return Self.compressedResult()
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        let first = Task { await harness.appState.submitComposer(text: "/compress") }
        await gate.waitUntilSuspended()
        XCTAssertEqual(harness.appState.compressingSessionIDs, ["composer-origin"])
        XCTAssertTrue(harness.appState.isCompressingActiveSession)

        let second = Task { await harness.appState.submitComposer(text: "/compress") }
        let secondSubmitted = await second.value
        XCTAssertTrue(secondSubmitted)
        gate.resume()
        _ = await first.value

        XCTAssertEqual(recorder.compressCalls.count, 1, "A second /compress while one is pending must not launch another compression")
        XCTAssertNotNil(harness.appState.errorMessage)
        XCTAssertTrue(harness.appState.compressingSessionIDs.isEmpty)
    }

    func testCompressingDifferentSessionRunsConcurrently() async throws {
        let recorder = SlashCallRecorder()
        let originGate = ControlledSuspension()
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            compressSession: { _, sessionID, focusTopic in
                recorder.recordCompress(sessionID: sessionID, focusTopic: focusTopic)
                if sessionID == "composer-origin" {
                    await originGate.suspend()
                }
                return Self.compressedResult()
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        let destination = session("composer-destination")
        harness.appState.sessions = [origin, destination]
        harness.appState.activeSessionId = origin.id

        let first = Task { await harness.appState.submitComposer(text: "/compress") }
        await originGate.waitUntilSuspended()

        // The user moves to another conversation while origin compresses.
        harness.appState.activeSessionId = destination.id
        XCTAssertFalse(harness.appState.isCompressingActiveSession, "The in-flight notice must not show in another conversation")

        // Compressing the new conversation is allowed (per-session, like
        // upstream Desktop) and completes without touching origin's RPC.
        let second = Task { await harness.appState.submitComposer(text: "/compress") }
        let secondSubmitted = await second.value
        XCTAssertTrue(secondSubmitted)
        XCTAssertEqual(recorder.compressCalls.count, 2)
        XCTAssertEqual(recorder.compressCalls.last?.sessionID, "composer-destination")
        XCTAssertEqual(harness.appState.messages.first?.content, "Summary carrier")

        // Origin's late result must not leak into the destination transcript.
        originGate.resume()
        _ = await first.value
        XCTAssertEqual(recorder.compressCalls.count, 2)
        XCTAssertEqual(harness.appState.messages.compactMap { $0.role == .user ? $0.content : nil }, ["Summary carrier"])
    }

    func testStaleCompletionDoesNotMutateAfterSwitchingSessions() async throws {
        let gate = ControlledSuspension()
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            compressSession: { _, _, _ in
                await gate.suspend()
                return Self.compressedResult()
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        let destination = session("composer-destination")
        harness.appState.sessions = [origin, destination]
        harness.appState.activeSessionId = origin.id
        harness.appState.messages = [
            ChatMessage(id: "m1", role: .user, content: "Origin question", timestamp: "1")
        ]
        let originContext = harness.appState.composerSubmissionContext()

        let submission = Task { await harness.appState.submitComposer(text: "/compress", context: originContext) }
        await gate.waitUntilSuspended()

        harness.appState.activeSessionId = destination.id
        gate.resume()
        let submitted = await submission.value
        XCTAssertTrue(submitted)

        XCTAssertEqual(harness.appState.messages.first?.content, "Origin question", "The destination transcript must stay untouched")
        XCTAssertFalse(
            harness.appState.messages.contains { $0.content == "Summary carrier" },
            "A late compression result must not adopt the compressed transcript into another conversation"
        )
        XCTAssertFalse(
            harness.appState.messages.contains { $0.content == "Compressed 13 → 4 messages" }
        )
    }

    // MARK: - Persisted-history rehydration

    func testCompressionRehydratesWindowFromFreshOffsetZeroResponse() async throws {
        // Compression rewrites the persisted history server-side: the
        // window's nextOffset describes offsets into the OLD row universe.
        // After each adoption the invariants must come from the FRESH
        // offset=0 hydration response — a pre-compression nextOffset must
        // never survive.
        var page = Self.persistedPagePayload(rowIDs: ["row-1", "row-2", "row-3"], limit: 3)
        var rehydrationQueries: [String] = []
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            persistedTranscript: { _, _, query in
                rehydrationQueries.append(query)
                return .payload(page)
            },
            compressSession: { _, _, _ in
                Self.compressedResult()
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        let firstSubmitted = await harness.appState.submitComposer(text: "/compress")
        XCTAssertTrue(firstSubmitted)
        var window = try XCTUnwrap(harness.appState.persistedTranscriptWindow)
        XCTAssertEqual(window.nextOffset, 3)
        XCTAssertEqual(window.canLoadEarlier, true)
        XCTAssertTrue(harness.appState.canLoadEarlierMessagesForActiveConversation)

        // Compress again: the gateway's persisted history changed, and the
        // hydration now answers with a different (shorter) page. The stale
        // nextOffset 3 must be gone.
        page = Self.persistedPagePayload(rowIDs: ["row-4"], limit: 3)
        let secondSubmitted = await harness.appState.submitComposer(text: "/compress")
        XCTAssertTrue(secondSubmitted)
        window = try XCTUnwrap(harness.appState.persistedTranscriptWindow)
        XCTAssertEqual(
            window.nextOffset, 1,
            "The pre-compression nextOffset (3) must not survive compression; coverage is rebuilt from the fresh hydration"
        )
        XCTAssertEqual(window.canLoadEarlier, false, "A short page retires the backfill affordance")
        XCTAssertFalse(harness.appState.canLoadEarlierMessagesForActiveConversation)
        // Both rehydrations must have requested the validated latest tail at
        // offset 0 — never any pre-compression offset. The first entry is
        // hardcoded so a regression in the query builder itself cannot pass
        // tautologically.
        XCTAssertEqual(
            rehydrationQueries,
            [
                "?limit=120&offset=0&order=latest&include_compacted=true",
                PersistedTranscriptPagination.tailQuery(offset: 0)
            ],
            "Rehydration must request order=latest offset=0 after every adoption"
        )
    }

    func testDeferredCompressionInvalidatesBackfillWindow() async throws {
        // A deferred adoption (a live turn owns the transcript) still rewrites
        // persisted history server-side: the pre-compression Load Earlier
        // window must not remain usable, and no rehydration may run while the
        // turn owns the transcript — the authoritative reconciliation
        // re-establishes pagination and provenance later.
        var page = Self.persistedPagePayload(rowIDs: ["row-1", "row-2", "row-3"], limit: 3)
        var hydrationCalls = 0
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            persistedTranscript: { _, _, _ in
                hydrationCalls += 1
                return .payload(page)
            },
            compressSession: { _, _, _ in
                Self.compressedResult()
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        let firstSubmitted = await harness.appState.submitComposer(text: "/compress")
        XCTAssertTrue(firstSubmitted)
        XCTAssertNotNil(harness.appState.persistedTranscriptWindow)
        XCTAssertTrue(harness.appState.canLoadEarlierMessagesForActiveConversation)
        XCTAssertEqual(hydrationCalls, 1)

        // A turn starts; the next compression's adoption defers to it.
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: origin.id, busy: true))
        XCTAssertEqual(harness.appState.turnState, .running)
        harness.appState.messages = [
            ChatMessage(id: "m1", role: .user, content: "Fresh local row", timestamp: "1")
        ]

        let secondSubmitted = await harness.appState.submitComposer(text: "/compress")
        XCTAssertTrue(secondSubmitted)
        // The pre-compression Load Earlier window cannot remain usable.
        XCTAssertNil(harness.appState.persistedTranscriptWindow)
        XCTAssertFalse(harness.appState.canLoadEarlierMessagesForActiveConversation)
        XCTAssertTrue(harness.appState.transcriptFreshnessIsStale)
        // The live turn's rows survive, and the deferred branch must NOT
        // rehydrate: the authoritative reconciliation does that later.
        XCTAssertEqual(harness.appState.messages.first?.content, "Fresh local row")
        XCTAssertEqual(hydrationCalls, 1)
    }

    func testFailedRehydrationLeavesBackfillDisabled() async throws {
        var hydrationCalls = 0
        let goodPage = Self.persistedPagePayload(rowIDs: ["row-1", "row-2", "row-3"], limit: 3)
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            persistedTranscript: { _, _, _ in
                hydrationCalls += 1
                if hydrationCalls == 1 {
                    return .payload(goodPage)
                }
                return .failed(URLError(.networkConnectionLost))
            },
            compressSession: { _, _, _ in
                Self.compressedResult()
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        let firstSubmitted = await harness.appState.submitComposer(text: "/compress")
        XCTAssertTrue(firstSubmitted)
        let window = try XCTUnwrap(harness.appState.persistedTranscriptWindow)
        XCTAssertEqual(window.nextOffset, 3)
        XCTAssertTrue(harness.appState.canLoadEarlierMessagesForActiveConversation)

        // The rehydration fails after this adoption: the invalidated window
        // must NOT be resurrected from the stale pre-compression state, and
        // backfill stays disabled until the next authoritative sync.
        let secondSubmitted = await harness.appState.submitComposer(text: "/compress")
        XCTAssertTrue(secondSubmitted)
        XCTAssertNil(
            harness.appState.persistedTranscriptWindow,
            "A failed rehydration must leave the window invalidated, not fall back to the stale one"
        )
        XCTAssertFalse(harness.appState.canLoadEarlierMessagesForActiveConversation)
    }

    // MARK: - Stale runtime recovery

    func testSessionNotFoundRecoversStoredRuntimeAndRetriesOnce() async throws {
        let recorder = SlashCallRecorder()
        let page = Self.persistedPagePayload(
            rowIDs: ["row-1", "row-2", "row-3"],
            limit: 3,
            sessionEcho: "runtime-new"
        )
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSession: { _, sessionID, compact in
                recorder.recordResume(sessionID: sessionID, compact: compact)
                return SessionResumeResult(
                    sessionId: "runtime-new",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            persistedTranscript: { _, _, _ in
                recorder.recordHydration()
                return .payload(page)
            },
            compressSession: { _, sessionID, _ in
                recorder.recordCompress(sessionID: sessionID, focusTopic: nil)
                if recorder.compressCalls.count == 1 {
                    throw RpcError(code: 4001, message: "session not found")
                }
                return Self.compressedResult()
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        let submitted = await harness.appState.submitComposer(text: "/compress")
        XCTAssertTrue(submitted)
        // Exactly one bounded recovery: resume the stored session, then retry
        // once against the fresh runtime.
        XCTAssertEqual(recorder.compressCalls.map { $0.sessionID }, ["composer-origin", "runtime-new"])
        XCTAssertEqual(recorder.resumeCalls.count, 1)
        XCTAssertEqual(recorder.resumeCalls.first?.sessionID, "composer-origin")
        XCTAssertEqual(recorder.resumeCalls.first?.compact, true)
        // The recovered runtime is adopted as the active binding.
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-new")
        // The retry result applies, and the rehydration re-establishes the
        // persisted-history window for the recovered runtime.
        XCTAssertEqual(harness.appState.messages.first?.content, "Summary carrier")
        let window = try XCTUnwrap(harness.appState.persistedTranscriptWindow)
        XCTAssertEqual(window.nextOffset, 3)
        XCTAssertEqual(window.requestedSessionID, "runtime-new")
    }

    func testSessionNotFoundResumeDriftPreventsRetry() async throws {
        let recorder = SlashCallRecorder()
        let resumeGate = ControlledSuspension()
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSession: { _, sessionID, _ in
                await resumeGate.suspend()
                recorder.recordResume(sessionID: sessionID, compact: true)
                return SessionResumeResult(
                    sessionId: "runtime-new",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            compressSession: { _, sessionID, _ in
                recorder.recordCompress(sessionID: sessionID, focusTopic: nil)
                throw RpcError(code: 4001, message: "session not found")
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        let destination = session("composer-destination")
        harness.appState.sessions = [origin, destination]
        harness.appState.activeSessionId = origin.id

        let submission = Task { await harness.appState.submitComposer(text: "/compress") }
        await resumeGate.waitUntilSuspended()
        // The user navigates away while the recovery resume is in flight.
        harness.appState.activeSessionId = destination.id
        resumeGate.resume()
        _ = await submission.value

        XCTAssertEqual(recorder.compressCalls.map { $0.sessionID }, ["composer-origin"], "Identity drift must prevent the recovery retry")
        XCTAssertEqual(recorder.resumeCalls.count, 1)
        XCTAssertEqual(harness.appState.activeSessionId, "composer-destination", "A drifted recovery must not rebind the active runtime")
        XCTAssertNil(harness.appState.persistedTranscriptWindow)
    }

    func testSessionNotFoundResumeFailureSurfacesOriginalError() async throws {
        let recorder = SlashCallRecorder()
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSession: { _, sessionID, _ in
                recorder.recordResume(sessionID: sessionID, compact: true)
                throw URLError(.networkConnectionLost)
            },
            compressSession: { _, sessionID, _ in
                recorder.recordCompress(sessionID: sessionID, focusTopic: nil)
                throw RpcError(code: 4001, message: "session not found")
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        _ = await harness.appState.submitComposer(text: "/compress")
        XCTAssertEqual(recorder.compressCalls.count, 1, "No retry after a failed recovery resume")
        XCTAssertEqual(recorder.resumeCalls.count, 1)
        // The ORIGINAL compression error is the meaningful one to surface.
        let lastRow = try XCTUnwrap(harness.appState.messages.last)
        XCTAssertTrue(lastRow.content.contains("session not found"), "Expected the original error, got: \(lastRow.content)")
    }

    func testTimeoutNeverTriggersSessionRecovery() async throws {
        let recorder = SlashCallRecorder()
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSession: { _, sessionID, _ in
                recorder.recordResume(sessionID: sessionID, compact: true)
                return SessionResumeResult(
                    sessionId: "runtime-recovered",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            compressSession: { _, sessionID, _ in
                recorder.recordCompress(sessionID: sessionID, focusTopic: nil)
                throw HermesError.timeout("session.compress")
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        _ = await harness.appState.submitComposer(text: "/compress")
        // A timeout means the gateway IS compressing — never a stale-runtime
        // signal, and never retried.
        XCTAssertTrue(recorder.resumeCalls.isEmpty)
        XCTAssertEqual(recorder.compressCalls.count, 1)
        XCTAssertTrue(harness.appState.messages.last?.content.contains("Request timed out") == true)
    }

    // MARK: - Compaction lifecycle (`status.update`)

    func testPendingCompressionStaysCompactingUntilCompactedEdge() async throws {
        let page = Self.persistedPagePayload(rowIDs: ["row-1", "row-2", "row-3"], limit: 3)
        var secondCompressionIsPending = false
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            persistedTranscript: { _, _, _ in
                .payload(page)
            },
            compressSession: { _, _, _ in
                if secondCompressionIsPending {
                    return SessionCompressResult(from: .object([
                        "status": .string("pending"),
                        "message": .string("compression still running in the background")
                    ]))
                }
                return Self.compressedResult()
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        // First compression adopts and re-establishes a backfill window.
        _ = await harness.appState.submitComposer(text: "/compress")
        XCTAssertNotNil(harness.appState.persistedTranscriptWindow)
        XCTAssertFalse(harness.appState.isCompressingActiveSession)

        // Second compression answers `pending`: the RPC ended but the host is
        // still compressing, so the server-side state keeps the spinner
        // truthful.
        secondCompressionIsPending = true
        _ = await harness.appState.submitComposer(text: "/compress")
        XCTAssertEqual(harness.appState.serverCompactingSessionIDs, ["composer-origin"])
        XCTAssertTrue(harness.appState.isCompressingActiveSession, "A pending result must keep the compression affordance visible")

        // The `compacted` edge is terminal: server state clears, and the
        // pre-compaction persisted-history provenance is invalidated.
        harness.appState.handleStreamEvent(.statusUpdate(sessionId: origin.id, kind: .compacted, text: nil))
        XCTAssertTrue(harness.appState.serverCompactingSessionIDs.isEmpty)
        XCTAssertNil(harness.appState.persistedTranscriptWindow)
        XCTAssertFalse(harness.appState.isCompressingActiveSession)
    }

    func testCompactedDuringLiveTurnDefersReplacementAndInvalidates() async throws {
        let page = Self.persistedPagePayload(rowIDs: ["row-1", "row-2", "row-3"], limit: 3)
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            persistedTranscript: { _, _, _ in
                .payload(page)
            },
            compressSession: { _, _, _ in
                Self.compressedResult()
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        // Compression #1 adopts and rebuilds the backfill window.
        _ = await harness.appState.submitComposer(text: "/compress")
        XCTAssertNotNil(harness.appState.persistedTranscriptWindow)

        // A live turn starts, then the gateway reports `compacted`.
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: origin.id, busy: true))
        harness.appState.messages = [
            ChatMessage(id: "m1", role: .user, content: "Live turn row", timestamp: "1")
        ]
        harness.appState.handleStreamEvent(.statusUpdate(sessionId: origin.id, kind: .compacted, text: nil))

        // The live turn's transcript is never replaced underneath it; the
        // obsolete provenance dies and freshness defers to the post-turn
        // authoritative path.
        XCTAssertEqual(harness.appState.messages.first?.content, "Live turn row")
        XCTAssertNil(harness.appState.persistedTranscriptWindow)
        XCTAssertTrue(harness.appState.transcriptFreshnessIsStale)
        XCTAssertTrue(harness.appState.serverCompactingSessionIDs.isEmpty)
    }

    func testInactiveSessionCompactedClearsOnlySessionState() async throws {
        let page = Self.persistedPagePayload(
            rowIDs: ["row-1", "row-2", "row-3"],
            limit: 3,
            sessionEcho: "composer-destination"
        )
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            persistedTranscript: { _, _, _ in
                .payload(page)
            },
            compressSession: { _, _, _ in
                Self.compressedResult()
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        let destination = session("composer-destination")
        harness.appState.sessions = [origin, destination]
        harness.appState.activeSessionId = destination.id

        // The active (destination) conversation compressed and has a window.
        _ = await harness.appState.submitComposer(text: "/compress")
        let windowBefore = harness.appState.persistedTranscriptWindow
        XCTAssertNotNil(windowBefore)
        let messagesBefore = harness.appState.messages

        // A BACKGROUND conversation (origin) reports compaction activity.
        harness.appState.handleStreamEvent(.statusUpdate(sessionId: origin.id, kind: .compacting, text: nil))
        XCTAssertEqual(harness.appState.serverCompactingSessionIDs, ["composer-origin"])
        harness.appState.handleStreamEvent(.statusUpdate(sessionId: origin.id, kind: .compacted, text: nil))

        // Only origin's session-scoped state clears; the ACTIVE
        // conversation's transcript and window are untouched.
        XCTAssertTrue(harness.appState.serverCompactingSessionIDs.isEmpty)
        XCTAssertEqual(harness.appState.persistedTranscriptWindow, windowBefore)
        XCTAssertEqual(harness.appState.messages, messagesBefore)
    }

    // MARK: - Compression identity

    func testSpinnerSurvivesRuntimeAliasRebind() async throws {
        let gate = ControlledSuspension()
        let recorder = SlashCallRecorder()
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            compressSession: { _, sessionID, _ in
                recorder.recordCompress(sessionID: sessionID, focusTopic: nil)
                await gate.suspend()
                return Self.compressedResult()
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        let first = Task { await harness.appState.submitComposer(text: "/compress") }
        await gate.waitUntilSuspended()

        // The gateway re-homes the runtime mid-compression: same durable
        // conversation, new runtime string.
        let rebound = SessionSummary(
            id: origin.id,
            storedSessionId: origin.storedSessionId,
            alternateIds: ["runtime-new"],
            title: origin.title,
            model: origin.model,
            updatedLabel: origin.updatedLabel,
            profile: origin.profile,
            source: origin.source,
            isActive: origin.isActive,
            isArchived: origin.isArchived,
            lineageRootId: origin.lineageRootId
        )
        harness.appState.sessions = [rebound]
        harness.appState.activeSessionId = "runtime-new"

        XCTAssertTrue(
            harness.appState.isCompressingActiveSession,
            "The Compressing affordance must survive a runtime alias rebind of the same conversation"
        )
        gate.resume()
        _ = await first.value
    }

    func testDuplicateCompressionCoalescedAcrossEquivalentRuntimeIDs() async throws {
        let recorder = SlashCallRecorder()
        let gate = ControlledSuspension()
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            compressSession: { _, sessionID, _ in
                recorder.recordCompress(sessionID: sessionID, focusTopic: nil)
                await gate.suspend()
                return Self.compressedResult()
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        let first = Task { await harness.appState.submitComposer(text: "/compress") }
        await gate.waitUntilSuspended()

        // Re-home the runtime, then try again under the new runtime string:
        // duplicate detection is equivalence-based, so this must coalesce —
        // never launch a second server-side compression.
        let rebound = SessionSummary(
            id: origin.id,
            storedSessionId: origin.storedSessionId,
            alternateIds: ["runtime-new"],
            title: origin.title,
            model: origin.model,
            updatedLabel: origin.updatedLabel,
            profile: origin.profile,
            source: origin.source,
            isActive: origin.isActive,
            isArchived: origin.isArchived,
            lineageRootId: origin.lineageRootId
        )
        harness.appState.sessions = [rebound]
        harness.appState.activeSessionId = "runtime-new"

        let second = Task { await harness.appState.submitComposer(text: "/compress") }
        _ = await second.value
        gate.resume()
        _ = await first.value

        XCTAssertEqual(recorder.compressCalls.count, 1, "Equivalent runtime ids must coalesce into one compression")
        XCTAssertNotNil(harness.appState.errorMessage)
    }

    func testDoubleSessionNotFoundResumesOnlyOnce() async throws {
        let recorder = SlashCallRecorder()
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSession: { _, sessionID, _ in
                recorder.recordResume(sessionID: sessionID, compact: true)
                return SessionResumeResult(
                    sessionId: "runtime-new",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            compressSession: { _, sessionID, _ in
                recorder.recordCompress(sessionID: sessionID, focusTopic: nil)
                // Even the recovered runtime answers session-not-found: the
                // recovery is bounded to ONE resume + ONE retry.
                throw RpcError(code: 4001, message: "session not found")
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        _ = await harness.appState.submitComposer(text: "/compress")
        XCTAssertEqual(recorder.compressCalls.count, 2, "Initial attempt plus exactly one recovered retry")
        XCTAssertEqual(recorder.resumeCalls.count, 1, "A second 4001 is a real error, never a second resume")
        XCTAssertTrue(harness.appState.messages.last?.content.hasPrefix("⚠️ Compression failed:") == true)
    }

    func testRetryFailureAfterRebindSurfacesAgainstRecoveredRuntime() async throws {
        let recorder = SlashCallRecorder()
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSession: { _, _, _ in
                recorder.recordResume(sessionID: "composer-origin", compact: true)
                return SessionResumeResult(
                    sessionId: "runtime-new",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            compressSession: { _, sessionID, _ in
                recorder.recordCompress(sessionID: sessionID, focusTopic: nil)
                if recorder.compressCalls.count == 1 {
                    throw RpcError(code: 4001, message: "session not found")
                }
                // The retry lands on the recovered runtime but then times out:
                // a real failure against the RECOVERED identity.
                throw HermesError.timeout("session.compress")
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        _ = await harness.appState.submitComposer(text: "/compress")
        XCTAssertEqual(recorder.compressCalls.map { $0.sessionID }, ["composer-origin", "runtime-new"])
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-new", "The rebind survives a failed retry")
        let lastRow = try XCTUnwrap(harness.appState.messages.last)
        XCTAssertTrue(
            lastRow.content.contains("Request timed out"),
            "The retry's own failure is the meaningful one to surface, got: \(lastRow.content)"
        )
    }

    func testAliasedCompactedEdgeClearsPendingServerState() async throws {
        // `pending` inserted the claim under the origin runtime; the terminal
        // `compacted` edge arrives addressed to an equivalent ALIAS runtime.
        // Equivalence-aware removal must clear it anyway.
        let origin = session("composer-origin", alternateIDs: ["runtime-new"])
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            compressSession: { _, _, _ in
                SessionCompressResult(from: .object([
                    "status": .string("pending"),
                    "message": .string("compression still running in the background")
                ]))
            }
        ))
        installComposerClient(in: harness)
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        _ = await harness.appState.submitComposer(text: "/compress")
        XCTAssertEqual(harness.appState.serverCompactingSessionIDs, ["composer-origin"])

        harness.appState.handleStreamEvent(.statusUpdate(sessionId: "runtime-new", kind: .compacted, text: nil))
        XCTAssertTrue(
            harness.appState.serverCompactingSessionIDs.isEmpty,
            "A compacted edge addressed to an alias runtime must clear the claim"
        )
        XCTAssertFalse(harness.appState.isCompressingActiveSession)
    }

    // MARK: - Server-claim lifecycle (generation-fenced, bounded)

    func testTerminalCompressionResultClearsPendingServerClaim() async throws {
        var pending = true
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            compressSession: { _, _, _ in
                if pending {
                    return SessionCompressResult(from: .object([
                        "status": .string("pending"),
                        "message": .string("compression still running in the background")
                    ]))
                }
                return Self.compressedResult()
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        _ = await harness.appState.submitComposer(text: "/compress")
        XCTAssertEqual(harness.appState.serverCompactingSessionIDs, ["composer-origin"])
        XCTAssertTrue(harness.appState.isCompressingActiveSession)

        // An authoritative terminal result ends the server-side claim.
        pending = false
        _ = await harness.appState.submitComposer(text: "/compress")
        XCTAssertTrue(harness.appState.serverCompactingSessionIDs.isEmpty)
        XCTAssertFalse(harness.appState.isCompressingActiveSession)
    }

    func testCompactedEdgeBeforePendingContinuationPreventsResurrection() async throws {
        let gate = ControlledSuspension()
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            compressSession: { _, _, _ in
                await gate.suspend()
                return SessionCompressResult(from: .object([
                    "status": .string("pending"),
                    "message": .string("compression still running in the background")
                ]))
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        let submission = Task { await harness.appState.submitComposer(text: "/compress") }
        await gate.waitUntilSuspended()

        // The gateway's terminal `compacted` edge lands while the RPC await
        // is still pending (the compute host finished ahead of the response).
        harness.appState.handleStreamEvent(.statusUpdate(sessionId: origin.id, kind: .compacted, text: nil))

        gate.resume()
        _ = await submission.value

        // The stale pending continuation must NOT resurrect the claim.
        XCTAssertTrue(
            harness.appState.serverCompactingSessionIDs.isEmpty,
            "A pending continuation that lost the race to a terminal edge must not establish server-side state"
        )
        XCTAssertFalse(harness.appState.isCompressingActiveSession)
    }

    func testLostCompactedEdgeExpiresClaimWithoutTouchingOtherConversations() async throws {
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            compressSession: { _, _, _ in
                SessionCompressResult(from: .object([
                    "status": .string("pending"),
                    "message": .string("compression still running in the background")
                ]))
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        let destination = session("composer-destination")
        harness.appState.sessions = [origin, destination]
        harness.appState.activeSessionId = origin.id

        // Both conversations carry a pending server-side claim; origin's uses
        // a short bounded lifetime, destination's the production budget.
        harness.appState.establishServerCompactionClaim(sessionId: origin.id, generation: 0, lifetime: 0.3)
        harness.appState.establishServerCompactionClaim(sessionId: destination.id, generation: 0)
        XCTAssertTrue(harness.appState.isCompressingActiveSession)

        // Past origin's bound: its lost-edge claim expires, destination's is
        // untouched.
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(
            harness.appState.serverCompactingSessionIDs.contains(origin.id),
            "A claim whose bounded lifetime elapsed must expire"
        )
        XCTAssertTrue(
            harness.appState.serverCompactingSessionIDs.contains(destination.id),
            "An unrelated conversation's claim is never touched by origin's expiry"
        )
    }

    // MARK: - Identity admission for stale-runtime recovery

    func testSessionNotFoundResumeEmptyRuntimeIDPreventsRecovery() async throws {
        let recorder = SlashCallRecorder()
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSession: { _, _, _ in
                recorder.recordResume(sessionID: "composer-origin", compact: true)
                return SessionResumeResult(
                    sessionId: "",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            compressSession: { _, sessionID, _ in
                recorder.recordCompress(sessionID: sessionID, focusTopic: nil)
                throw RpcError(code: 4001, message: "session not found")
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        _ = await harness.appState.submitComposer(text: "/compress")
        // A blank runtime id cannot be rebound or retried.
        XCTAssertEqual(recorder.compressCalls.count, 1)
        XCTAssertEqual(recorder.resumeCalls.count, 1)
        XCTAssertEqual(harness.appState.activeSessionId, "composer-origin", "No rebind from a blank runtime id")
        XCTAssertTrue(harness.appState.messages.last?.content.contains("session not found") == true)
    }

    func testSessionNotFoundForeignIdentityPreventsRecovery() async throws {
        let recorder = SlashCallRecorder()
        let harness = makeHarness(lifecycleOperations: ChatResumeLifecycleOperations(
            openSession: { _, _, _ in
                recorder.recordResume(sessionID: "composer-origin", compact: true)
                // The resume answered with a runtime of a DIFFERENT durable
                // conversation: contradictory identity, admission rejects.
                return SessionResumeResult(
                    sessionId: "runtime-foreign",
                    storedSessionId: "stored-foreign",
                    messages: [],
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            compressSession: { _, sessionID, _ in
                recorder.recordCompress(sessionID: sessionID, focusTopic: nil)
                throw RpcError(code: 4001, message: "session not found")
            }
        ))
        installComposerClient(in: harness)
        let origin = session("composer-origin")
        let foreign = session("foreign-id", storedID: "stored-foreign")
        harness.appState.sessions = [origin, foreign]
        harness.appState.activeSessionId = origin.id

        _ = await harness.appState.submitComposer(text: "/compress")
        // Admission rejected the contradictory claim: no rebind, no retry.
        XCTAssertEqual(recorder.compressCalls.count, 1)
        XCTAssertEqual(recorder.resumeCalls.count, 1)
        XCTAssertEqual(harness.appState.activeSessionId, "composer-origin", "A rejected admission must not rebind the active runtime")
        XCTAssertTrue(harness.appState.messages.last?.content.contains("session not found") == true)
    }

    func testValidRecoveryRecordsAuthoritativeRuntimeMapping() async throws {
        let identityIndex = ConversationIdentityIndex()
        let recorder = SlashCallRecorder()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, _, _ in
                    recorder.recordResume(sessionID: "stored-origin", compact: true)
                    return SessionResumeResult(
                        sessionId: "runtime-new",
                        storedSessionId: "stored-origin",
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                compressSession: { _, _, _ in
                    recorder.recordCompress(sessionID: "composer-origin", focusTopic: nil)
                    if recorder.compressCalls.count == 1 {
                        throw RpcError(code: 4001, message: "session not found")
                    }
                    return Self.compressedResult()
                }
            ),
            conversationIdentityIndex: identityIndex
        )
        installComposerClient(in: harness)
        let origin = session("composer-origin", storedID: "stored-origin")
        harness.appState.sessions = [origin]
        harness.appState.activeSessionId = origin.id

        _ = await harness.appState.submitComposer(text: "/compress")
        // The recovery resumed the STORED conversation and rebound to its
        // fresh runtime.
        XCTAssertEqual(recorder.resumeCalls.count, 1)
        XCTAssertEqual(recorder.resumeCalls.first?.sessionID, "stored-origin")
        XCTAssertEqual(harness.appState.activeSessionId, "runtime-new")
        // The authoritative runtime → durable mapping was recorded from the
        // admitted recovery.
        XCTAssertEqual(
            identityIndex.durableID(forRuntime: "runtime-new", profile: "default"),
            "stored-origin"
        )
        // The retry applied the compressed transcript.
        XCTAssertEqual(harness.appState.messages.first?.content, "Summary carrier")
    }

    // MARK: - Fixtures

    /// A validated `order=latest` persisted-history page the `persistedTranscript`
    /// seam serves for the origin conversation: durable row ids, session echo,
    /// and a pagination echo honoring the tail contract.
    private static func persistedPagePayload(
        rowIDs: [String],
        limit: Int,
        sessionEcho: String = "composer-origin"
    ) -> [String: Any] {
        [
            "session_id": sessionEcho,
            "messages": rowIDs.map { id in
                [
                    "id": id,
                    "role": "user",
                    "content": "Persisted \(id)",
                    "timestamp": "2026-09-13T09:00:00Z"
                ] as [String: Any]
            },
            "pagination": [
                "order": "latest",
                "limit": limit,
                "offset": 0,
                "returned": rowIDs.count
            ] as [String: Any]
        ]
    }

    private static func compressedResult() -> SessionCompressResult {
        SessionCompressResult(from: .object([
            "status": .string("compressed"),
            "removed": .number(9),
            "summary": .object(["headline": .string("Compressed 13 → 4 messages")]),
            "messages": .array([
                .object([
                    "role": .string("user"),
                    "content": .string("Summary carrier"),
                    "timestamp": .string("2026-09-13T08:00:00Z")
                ]),
                .object([
                    "role": .string("assistant"),
                    "content": .string("Tail answer"),
                    "timestamp": .string("2026-09-13T08:00:05Z")
                ])
            ])
        ]))
    }

    private func makeHarness(
        lifecycleOperations: ChatResumeLifecycleOperations = .live,
        conversationIdentityIndex: ConversationIdentityIndex? = nil
    ) -> (
        appState: AppState,
        defaults: UserDefaults,
        suite: String
    ) {
        let suite = "AppStateSessionCompressTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        let store = ChatResumeStore(defaults: defaults)
        let coordinator = ChatResumeCoordinator(store: store)
        let appState = AppState(
            defaults: defaults,
            chatResumeCoordinator: coordinator,
            recoverySequence: ChatResumeRecoverySequence(),
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: lifecycleOperations,
            sessionPresentationCache: SessionPresentationCache(defaults: defaults),
            conversationIdentityIndex: conversationIdentityIndex
        )
        return (appState, defaults, suite)
    }

    private func installComposerClient(
        in harness: (
            appState: AppState,
            defaults: UserDefaults,
            suite: String
        )
    ) {
        let connection = HermesConnection(
            baseUrl: "https://one.example",
            ticket: "ticket"
        )
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")
    }

    private func session(
        _ id: String,
        storedID: String? = nil,
        alternateIDs: [String] = [],
        profile: String = "default"
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            storedSessionId: storedID,
            alternateIds: alternateIDs,
            title: id,
            model: "Hermes",
            updatedLabel: "now",
            profile: profile,
            source: .chat,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
    }
}

/// Call recorder for the compression lifecycle seams. Everything runs on the
/// MainActor (the seams and the test body), so plain stored properties are
/// confinement-correct.
@MainActor
private final class SlashCallRecorder {
    struct CompressCall {
        let sessionID: String
        let focusTopic: String?
    }

    struct ResumeCall {
        let sessionID: String
        let compact: Bool
    }

    private(set) var compressCalls: [CompressCall] = []
    private(set) var resumeCalls: [ResumeCall] = []
    private(set) var slashExecCount = 0
    private(set) var slashExecCommands: [String] = []
    private(set) var dispatchCount = 0
    private(set) var hydrationCount = 0

    func recordCompress(sessionID: String, focusTopic: String?) {
        compressCalls.append(CompressCall(sessionID: sessionID, focusTopic: focusTopic))
    }

    func recordResume(sessionID: String, compact: Bool) {
        resumeCalls.append(ResumeCall(sessionID: sessionID, compact: compact))
    }

    func recordHydration() {
        hydrationCount += 1
    }

    func recordSlashExec(command: String = "") {
        slashExecCount += 1
        slashExecCommands.append(command)
    }

    func recordDispatch() {
        dispatchCount += 1
    }
}

@MainActor
private final class ControlledSuspension {
    private var suspension: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation in
            suspension = continuation
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilSuspended() async {
        guard suspension == nil else { return }
        await withCheckedContinuation { continuation in
            observer = continuation
        }
    }

    func resume() {
        suspension?.resume()
        suspension = nil
    }
}
