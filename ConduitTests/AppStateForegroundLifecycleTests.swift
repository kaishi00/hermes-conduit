import XCTest
@testable import Conduit

/// Regression coverage for the foreground lifecycle contract: a healthy
/// foreground transition is observational (never a `session.resume` session
/// replacement), an ambiguous `prompt.submit` acknowledgement is recovered
/// through the authoritative runtime registry instead of a blind retry, and a
/// stale local idle state is corrected before the next submission is routed.
@MainActor
final class AppStateForegroundLifecycleTests: XCTestCase {

    // MARK: - A. Healthy socket + active turn

    func testForegroundWithHealthySocketAndActiveTurnDoesNotResume() async {
        let active = session("stored-a")
        var healthChecks = 0
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var catalogCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [active]
                },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    // The bounded tail always matches what the device last
                    // hydrated: same-turn continuity, provably unchanged.
                    return .payload([
                        "messages": [
                            ["id": "user", "role": "user", "content": "Question", "timestamp": "1"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in healthChecks += 1 },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        // Seed through the real hydration path so the durable frontier covers
        // the turn Conduit is about to own.
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        let seedMessages = [
            ChatMessage(id: "user", role: .user, content: "Question", timestamp: "1")
        ]
        XCTAssertEqual(harness.appState.messages, seedMessages)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(healthChecks, 1, "The foreground must verify the transport health once")
        XCTAssertEqual(probeCount, 1, "The foreground must query the authoritative runtime registry")
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground,
            "A healthy foreground must never issue session.resume"
        )
        XCTAssertEqual(catalogCount, 0, "A healthy foreground must not reload the session catalog")
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertEqual(harness.appState.activeSessionId, active.id)
        XCTAssertEqual(harness.appState.messages, seedMessages, "Foregrounding must not replace the transcript")
        XCTAssertFalse(harness.appState.turnStateIsStale)

        // The stream gate is open again after the observational settle: later
        // turn events land without a transcript replacement. The streaming
        // projection publishes on a short coalescing cadence, so poll briefly.
        harness.appState.handleStreamEvent(.messageDelta(sessionId: active.id, text: " more"))
        let published = await waitForStreamingText(" more", in: harness.appState)
        XCTAssertTrue(published, "The post-foreground delta must land in the streaming projection")
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(
            harness.appState.activeChatScrollSessionIdentity.isReconciling
        )
        box.client.disconnect()
    }

    /// Bounded wait for the coalesced streaming publish (33 ms cadence).
    private func waitForStreamingText(
        _ expected: String,
        in appState: AppState,
        timeout: TimeInterval = 3
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if appState.streamingText == expected { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return appState.streamingText == expected
    }

    // MARK: - B. Healthy socket + PR #121 live reasoning

    func testForegroundPreservesLiveReasoningSegmentOnHealthySocket() async {
        let active = session("stored-a")
        var resumeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    .payload([
                        "messages": [
                            ["id": "user", "role": "user", "content": "Question", "timestamp": "1"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "Step one."))
        let segmentBefore = harness.appState.liveReasoningSegment
        XCTAssertNotNil(segmentBefore)
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(
            harness.appState.liveReasoningSegment, segmentBefore,
            "A harmless foreground cycle must not settle or reset the live reasoning segment"
        )
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground,
            "Proven same-turn continuity must not resume"
        )

        // Later reasoning deltas extend the SAME segment (a reset would nil
        // the projection or mint a new segment id on the next delta).
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: " Step two."))
        await flushMainActor()
        XCTAssertEqual(harness.appState.liveReasoningSegment?.id, segmentBefore?.id)
        XCTAssertNotNil(harness.appState.liveReasoningSegment)
        // No duplicate settled thinking row may appear in the transcript.
        XCTAssertEqual(harness.appState.messages.map(\.id), ["user"])
        box.client.disconnect()
    }

    // MARK: - C. Healthy idle session

    func testForegroundWithHealthyIdleSessionIsObservationalNoOp() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let seedPayload: [String: Any] = [
            "messages": [
                ["id": "100", "role": "user", "content": "Earlier", "timestamp": "1"]
            ],
            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    return .payload(seedPayload)
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        // Seed through the real hydration path so the freshness comparison
        // has a durable frontier to anchor against.
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100"])
        let messagesBefore = harness.appState.messages
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2, "One bounded freshness read proves currency")
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground,
            "An idle healthy session must not be resumed"
        )
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertEqual(harness.appState.messages, messagesBefore, "The transcript must remain stable")
        XCTAssertFalse(
            harness.appState.activeChatScrollSessionIdentity.isReconciling,
            "No reconciliation may remain open after the observational refresh"
        )
        XCTAssertFalse(harness.appState.turnStateIsStale)
        box.client.disconnect()
    }

    // MARK: - C2. Stale transitional state under an authoritative idle probe

    /// A recovery attempt parked mid-reconcile leaves the transitional
    /// `.synchronizing` state behind even though the socket is healthy. The
    /// next foreground cycle's authoritative idle observation must adopt
    /// idle — composer usable, no resume, transcript untouched — instead of
    /// settling the boundary around the stale state.
    func testForegroundWithStaleSynchronizingAndAuthoritativeIdleAdoptsIdle() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let parkedBranch = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                    ])
                },
                branchSession: { _, _, _, _, _ in
                    // The branch parks mid-flight AFTER flipping the turn
                    // state to .synchronizing — the transitional state the
                    // foreground must normalize, without the frontier-wiping
                    // reconcile a parked resume would run.
                    await parkedBranch.suspend()
                    throw HermesError.notConnected
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        // Seed through the real hydration path: durable frontier covers the
        // transcript the freshness check will compare against.
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        let seedMessages = [
            ChatMessage(id: "100", role: .user, content: "Earlier question", timestamp: "1"),
            ChatMessage(id: "101", role: .assistant, content: "Earlier answer", timestamp: "2")
        ]
        XCTAssertEqual(harness.appState.messages, seedMessages)

        // A previous recovery attempt (a conversation branch) parks mid-flight
        // with the transitional state showing. The task is deliberately not
        // awaited: its unwinding is covered by the rotated-token guards.
        Task { @MainActor in
            await harness.appState.branchFromAssistantMessage("101")
        }
        await parkedBranch.waitUntilSuspended()
        XCTAssertEqual(harness.appState.turnState, .synchronizing)
        let resumeCountBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2, "One bounded freshness read proves currency")
        XCTAssertEqual(
            resumeCount, resumeCountBeforeForeground,
            "The foreground refresh must not issue any resume of its own"
        )
        XCTAssertEqual(
            harness.appState.turnState, .idle,
            "An authoritative idle observation must clear the stale transitional state"
        )
        XCTAssertTrue(
            harness.appState.composerIsEnabled,
            "The composer must be usable once the registry says idle"
        )
        XCTAssertFalse(harness.appState.turnStateIsStale)
        XCTAssertEqual(harness.appState.messages, seedMessages, "The transcript must remain stable")
        XCTAssertFalse(
            harness.appState.activeChatScrollSessionIdentity.isReconciling,
            "No reconciliation may remain open after the observational refresh"
        )

        // The abandoned branch unwinds through its rotated-token guards; it
        // must not undo the adopted idle state or the transcript.
        parkedBranch.resume()
        await flushMainActor()
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertEqual(
            harness.appState.messages, seedMessages,
            "The abandoned branch must not replace the transcript"
        )
        XCTAssertFalse(
            harness.appState.activeChatScrollSessionIdentity.isReconciling
        )
        box.client.disconnect()
    }

    /// A recovery attempt parked while reconnecting (the ticket mint stands
    /// in for a slow dashboard handoff) leaves `.reconnecting` behind even
    /// though the socket is healthy. The next foreground cycle's
    /// authoritative idle observation must adopt idle with the same
    /// observational guarantees.
    func testForegroundWithStaleReconnectingAndAuthoritativeIdleAdoptsIdle() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let parkedReconnect = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                mintTicket: { _ in
                    await parkedReconnect.suspend()
                    return "ticket"
                },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier", "timestamp": "1"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        // Seed through the real hydration path so the freshness comparison has
        // a durable frontier to anchor against.
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        let messagesBefore = harness.appState.messages

        // A previous connection/recovery attempt parks mid-reconnect, leaving
        // the transitional state showing. The gate is never released: the
        // foreground adoption must not depend on how the abandoned attempt
        // resolves.
        Task { @MainActor in
            await harness.appState.reconnectForRetry(purpose: .automaticReturn)
        }
        await parkedReconnect.waitUntilSuspended()
        XCTAssertEqual(harness.appState.turnState, .reconnecting)
        let resumeCountBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2, "One bounded freshness read proves currency")
        XCTAssertEqual(
            resumeCount, resumeCountBeforeForeground,
            "An idle healthy session must not be resumed"
        )
        XCTAssertEqual(
            harness.appState.turnState, .idle,
            "An authoritative idle observation must clear the stale transitional state"
        )
        XCTAssertTrue(
            harness.appState.composerIsEnabled,
            "The composer must be usable once the registry says idle"
        )
        XCTAssertFalse(harness.appState.turnStateIsStale)
        XCTAssertEqual(harness.appState.messages, messagesBefore, "The transcript must remain stable")
        XCTAssertFalse(
            harness.appState.activeChatScrollSessionIdentity.isReconciling,
            "No reconciliation may remain open after the observational refresh"
        )
        box.client.disconnect()
    }

    /// The adopted idle baseline is the OLDER observation: a busy edge that
    /// races the probe and lands in the boundary buffer must win when the
    /// buffer is replayed, instead of being discarded by the idle adoption.
    func testForegroundAdoptedIdleYieldsToNewerBufferedBusyEdge() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        let parkedProbe = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    .payload([
                        "messages": [
                            ["id": "user", "role": "user", "content": "Earlier", "timestamp": "1"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    await parkedProbe.suspend()
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        // Seed through the real hydration path so the freshness comparison has
        // a durable frontier to anchor against.
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        let activation = Task { @MainActor in
            await runSceneActivation(harness)
        }
        // Hold the foreground activation at the probe, then deliver a newer
        // busy edge while the reconciliation boundary is open.
        await parkedProbe.waitUntilSuspended()
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        parkedProbe.resume()
        await activation.value
        await flushMainActor()

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground,
            "An idle healthy session must not be resumed"
        )
        XCTAssertEqual(
            harness.appState.turnState, .running,
            "The newer buffered busy edge must win over the adopted idle baseline"
        )
        XCTAssertTrue(
            harness.appState.composerIsEnabled,
            "A running turn keeps composer actions (stop/steer) available"
        )
        XCTAssertFalse(harness.appState.turnStateIsStale)
        box.client.disconnect()
    }

    // MARK: - Round 6: cross-surface transcript freshness

    /// A turn another surface completed while Conduit was backgrounded is
    /// invisible to the liveness probe (the runtime is idle). One bounded
    /// persisted-tail read must merge the missed rows into the local
    /// transcript on foreground — without a session.resume.
    func testForegroundMergesRemoteCompletedTurnAfterBackground() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        // The seeding hydration: two durable rows held.
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // A remote surface completed a turn while Conduit was
                    // suspended: rows beyond the local durable frontier.
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Remote question", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Remote answer", "timestamp": "4"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2, "One bounded freshness read decides the foreground")
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground,
            "Completed remote history must merge without a session.resume"
        )
        XCTAssertEqual(
            harness.appState.messages.map(\.id), ["100", "101", "102", "103"],
            "The remotely completed turn becomes visible immediately"
        )
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertTrue(harness.appState.composerIsEnabled)
        XCTAssertFalse(harness.appState.turnStateIsStale)
        XCTAssertFalse(harness.appState.activeChatScrollSessionIdentity.isReconciling)
        XCTAssertEqual(
            harness.appState.persistedTranscriptWindow?.nextOffset, 4,
            "The persisted window must re-anchor to the fetched page"
        )

        // A live completion over a merged row finalizes it IN PLACE (same
        // gateway id) instead of appending a duplicate twin.
        harness.appState.handleStreamEvent(.messageComplete(
            sessionId: active.id,
            messageId: "103",
            content: "Remote full answer",
            reasoning: nil
        ))
        harness.appState.handleStreamEvent(.messageStart(sessionId: active.id))
        XCTAssertEqual(
            harness.appState.messages.filter { $0.id == "103" }.count, 1,
            "The live completion must not duplicate the merged persisted row"
        )
        XCTAssertEqual(
            harness.appState.messages.first(where: { $0.id == "103" })?.content,
            "Remote full answer"
        )
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101", "102", "103"])
        box.client.disconnect()
    }

    /// A turn another surface STARTED while Conduit was idle-and-backgrounded
    /// is still running on foreground. Persisted history alone cannot supply
    /// the in-flight projection, so the authoritative attach runs: the compact
    /// resume returns the live runtime state and the reconcile merges the
    /// persisted prefix — exactly one session.resume.
    func testForegroundAttachesRemoteRunningTurnAuthoritatively() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        // The attach resume returns the live runtime: the
                        // remote turn is running.
                        snapshot: SessionRuntimeSnapshot(
                            object: ["running": .bool(resumeCount > 1)]
                        )
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Remote question", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Remote partial", "timestamp": "4"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2, "The attach reconcile performs its own bounded read")
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground + 1,
            "A turn this device never owned attaches through the compact resume"
        )
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101", "102", "103"])
        XCTAssertEqual(
            harness.appState.turnState, .running,
            "The authoritative snapshot proves the remote turn is running"
        )
        XCTAssertTrue(harness.appState.composerIsEnabled)
        XCTAssertFalse(harness.appState.turnStateIsStale)

        // Future stream events extend the attached turn.
        harness.appState.handleStreamEvent(.messageDelta(
            sessionId: active.id,
            text: " and more"
        ))
        let published = await waitForStreamingText(" and more", in: harness.appState)
        XCTAssertTrue(published, "Deltas must land on the attached live turn")
        box.client.disconnect()
    }

    /// The headline PR #122 behavior must not degrade: a Conduit-owned turn
    /// that was running before the background transition continues on the
    /// same runtime — fast observational path, zero freshness reads, zero
    /// resumes, reasoning and transcript untouched.
    func testForegroundOwnedTurnContinuityStaysFastPathObservational() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "Thinking."))
        let segmentBefore = harness.appState.liveReasoningSegment
        let messagesBefore = harness.appState.messages
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(
            transcriptReads, 2,
            "One bounded freshness read proves same-turn continuity"
        )
        XCTAssertEqual(resumeCount, resumesBeforeForeground, "Zero session.resume")
        XCTAssertEqual(harness.appState.messages, messagesBefore, "No transcript replacement")
        XCTAssertEqual(harness.appState.liveReasoningSegment, segmentBefore)
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(harness.appState.turnStateIsStale)
        box.client.disconnect()
    }

    /// A backgrounded idle conversation whose persisted tail did not advance:
    /// the freshness read returns unchanged and the foreground stays a pure
    /// observational no-op.
    func testForegroundIdleBackgroundReturnWithNoRemoteActivityStaysObservational() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let seedPayload: [String: Any] = [
            "messages": [
                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
            ],
            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    return .payload(seedPayload)
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        let messagesBefore = harness.appState.messages
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2)
        XCTAssertEqual(resumeCount, resumesBeforeForeground, "Zero session.resume")
        XCTAssertEqual(
            harness.appState.messages, messagesBefore,
            "An unchanged tail must not replace the transcript"
        )
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertTrue(harness.appState.composerIsEnabled)
        XCTAssertFalse(harness.appState.turnStateIsStale)
        XCTAssertFalse(harness.appState.activeChatScrollSessionIdentity.isReconciling)
        box.client.disconnect()
    }

    /// When the local durable frontier has rotated out of the newest bounded
    /// page, freshness cannot be proven — the bounded resume refresh (the
    /// existing reconcile, which re-anchors the whole conversation) must take
    /// over instead of a false no-op.
    func testForegroundFreshnessWithRotatedAnchorTakesBoundedRecovery() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // Remote activity pushed the local frontier (rows 100/101)
                    // out of the newest page entirely: no overlap anchor.
                    let rotatedRows: [[String: Any]] = (200..<320).map { id in
                        [
                            "id": "\(id)",
                            "role": "assistant",
                            "content": "Remote row \(id)",
                            "timestamp": "\(id)"
                        ]
                    }
                    return .payload([
                        "messages": rotatedRows,
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 120]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 3, "Freshness read + the recovery reconcile's bounded read")
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground + 1,
            "Anchor-less freshness must take the bounded resume recovery exactly once"
        )
        XCTAssertEqual(harness.appState.messages.count, 120, "No remote rows may be lost")
        XCTAssertEqual(harness.appState.messages.first?.id, "200")
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertTrue(harness.appState.composerIsEnabled)
        XCTAssertFalse(harness.appState.activeChatScrollSessionIdentity.isReconciling)
        box.client.disconnect()
    }

    /// Ordering invariant: the persisted tail is the OLDER observation. A
    /// stream event that arrives while the freshness read is in flight is
    /// buffered and replayed after the merge, so the final state reflects
    /// snapshot first, newer live edge second.
    func testForegroundFreshnessMergeYieldsToNewerBufferedBusyEdge() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let parkedRead = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // Hold the foreground freshness read open while a newer
                    // live edge arrives.
                    await parkedRead.suspend()
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Remote question", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Remote answer", "timestamp": "4"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])

        harness.appState.handleScenePhase(.background)
        let activation = Task { @MainActor in
            await runSceneActivation(harness)
        }
        await parkedRead.waitUntilSuspended()
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        parkedRead.resume()
        await activation.value
        await flushMainActor()

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2)
        XCTAssertEqual(resumeCount, 1, "The seeding reconcile owns the only resume")
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101", "102", "103"])
        XCTAssertEqual(
            harness.appState.turnState, .running,
            "The newer buffered busy edge must win over the merged persisted snapshot"
        )
        XCTAssertTrue(harness.appState.composerIsEnabled)
        XCTAssertFalse(harness.appState.turnStateIsStale)
        box.client.disconnect()
    }

    /// The freshness arming is consumed by one foreground return: an overlay
    /// dip after a completed background return must stay fully observational
    /// (the socket survived the dip, live events kept flowing), with zero
    /// freshness reads and zero resumes.
    func testForegroundFreshnessRunsOncePerBackgroundNotOnOverlayDips() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Remote question", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Remote answer", "timestamp": "4"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        let resumesBefore = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(transcriptReads, 2, "The armed background return runs the freshness check once")
        XCTAssertFalse(harness.appState.foregroundFreshnessCheckArmed)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101", "102", "103"])
        let resumesAfterBackgroundReturn = resumeCount

        // Overlay dip: observational only — no third read, no resume.
        harness.appState.handleScenePhase(.inactive)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 2)
        XCTAssertEqual(
            transcriptReads, 2,
            "An overlay dip must not run the freshness check"
        )
        XCTAssertEqual(resumeCount, resumesAfterBackgroundReturn)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101", "102", "103"])
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertFalse(harness.appState.turnStateIsStale)
        box.client.disconnect()
    }

    /// A composer submit landing during the bounded freshness read supersedes
    /// the foreground refresh: `sendMessage`'s recovery-intent cancellation
    /// advances the automatic-work epoch, so the freshness continuation's
    /// ownership guard fails and it stands down WITHOUT merging. Persisted
    /// rows can therefore never be appended after the newer optimistic row;
    /// convergence belongs to the submission's own outcome and the next
    /// bounded refresh.
    func testForegroundFreshnessStandsDownWhenSubmissionOwnsTheTranscript() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let parkedRead = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    if transcriptReads == 2 {
                        // Hold only the freshness read; the recovery
                        // reconcile's own read must flow freely.
                        await parkedRead.suspend()
                    }
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Remote question", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Remote answer", "timestamp": "4"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])
        let resumesBefore = resumeCount

        harness.appState.handleScenePhase(.background)
        let activation = Task { @MainActor in
            await runSceneActivation(harness)
        }
        await parkedRead.waitUntilSuspended()
        let submitted = await harness.appState.submitComposer(text: "Mid-read send")
        XCTAssertTrue(submitted)
        parkedRead.resume()
        await activation.value
        await flushMainActor()

        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(
            resumeCount, resumesBefore,
            "The freshness continuation is token-dead: it must not resume"
        )
        XCTAssertEqual(
            harness.appState.messages.map(\.id).first, "100",
            "The seeded prefix stands"
        )
        XCTAssertEqual(
            harness.appState.messages.last?.content, "Mid-read send",
            "The optimistic local row stays the newest row — no inverted persisted append"
        )
        XCTAssertFalse(
            harness.appState.messages.contains { $0.id == "102" || $0.id == "103" },
            "The freshness merge must not append behind the newer local row"
        )
        XCTAssertEqual(
            harness.appState.turnState, .running,
            "The accepted submission owns the turn state"
        )
        XCTAssertFalse(harness.appState.activeChatScrollSessionIdentity.isReconciling)
        box.client.disconnect()
    }

    /// A positively empty persisted page behind an idle runtime proves the
    /// conversation has no rows at all: freshness is provably unchanged and
    /// an empty local transcript stays a pure observational no-op.
    func testForegroundArmedIdleWithPositivelyEmptyConversationStaysObservational() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    return .payload([
                        "messages": [],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 0]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 1)
        XCTAssertEqual(resumeCount, 0, "A provably empty conversation must not resume")
        XCTAssertTrue(harness.appState.messages.isEmpty)
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertTrue(harness.appState.composerIsEnabled)
        XCTAssertFalse(harness.appState.turnStateIsStale)
        box.client.disconnect()
    }

    /// Local chat activity since the last hydration leaves the transcript
    /// tail optimistically identified (the frontier cannot vouch for it), so
    /// the append-only merge stands down: one bounded resume refresh per
    /// background return converges the conversation. This pins the deliberate
    /// cost of the conservative route on the most common sequence.
    func testForegroundAfterLocalChatSinceHydrationTakesBoundedRecovery() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Remote question", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Remote answer", "timestamp": "4"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)

        // A locally streamed turn completes after the hydration: its row is
        // optimistically identified, so the durable frontier cannot vouch
        // for the transcript tail.
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.messageComplete(
            sessionId: active.id,
            messageId: nil,
            content: "Locally streamed answer",
            reasoning: nil
        ))
        harness.appState.handleStreamEvent(.messageStart(sessionId: active.id))
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: false))
        XCTAssertEqual(harness.appState.messages.last?.role, .assistant)
        XCTAssertNotEqual(
            harness.appState.messages.last?.id, "102",
            "The local completion row must be optimistically identified"
        )
        XCTAssertEqual(
            harness.appState.turnState, .idle,
            "The locally completed turn must settle before the background transition"
        )
        let resumesBefore = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 3, "Freshness read + the recovery reconcile's bounded read")
        XCTAssertEqual(
            resumeCount, resumesBefore + 1,
            "An unanchored tail takes the bounded resume recovery exactly once"
        )
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101", "102", "103"])
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertTrue(harness.appState.composerIsEnabled)
        XCTAssertFalse(harness.appState.activeChatScrollSessionIdentity.isReconciling)
        box.client.disconnect()
    }

    // MARK: - Round 7: tail-only freshness, source classification, authoritative attach

    private let legacyShapedRows: [[String: Any]] = [
        ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
        ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
        ["id": "102", "role": "user", "content": "Remote question", "timestamp": "3"],
        ["id": "103", "role": "assistant", "content": "Remote answer", "timestamp": "4"]
    ]

    /// A backend that pages from the oldest end (a pagination echo WITHOUT
    /// the `order=latest` contract) yields NO bounded freshness evidence, and
    /// the freshness check must NOT escalate into the legacy whole-transcript
    /// read. Arithmetic: seed(1) + freshness(2) + the recovery reconcile's
    /// own bounded read(3) + its designed legacy one-shot re-read(4) = 4
    /// calls. Had the FRESHNESS path performed a legacy fallback too, the
    /// total would be 5.
    func testForegroundFreshnessTailReadNeverFallsBackToLegacyHistory() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // Oldest-anchored pagination echo: a pagination object
                    // WITHOUT the `order=latest` contract.
                    return .payload([
                        "messages": self.legacyShapedRows,
                        "pagination": ["limit": 120, "offset": 0, "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(
            transcriptReads, 4,
            "Exactly one freshness call (no legacy fallback) + the recovery reconcile's bounded read and its designed legacy re-read"
        )
        XCTAssertEqual(resumeCount, resumesBeforeForeground + 1)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101", "102", "103"])
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertTrue(harness.appState.composerIsEnabled)
        box.client.disconnect()
    }

    /// A structurally absent messages endpoint (404-class) means there is no
    /// bounded capability to compare with: the authoritative resume/reconcile
    /// fallback runs exactly once instead of silently adopting a possibly
    /// stale transcript as current.
    func testForegroundFreshnessStructuralSourceAbsenceTakesAuthoritativeFallback() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, compact in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        // A legacy (non-compact) resume carries the transcript
                        // itself — exactly what the structural fallback uses.
                        messages: compact ? [] : [
                            ChatMessage(id: "100", role: .user, content: "Earlier question", timestamp: "1"),
                            ChatMessage(id: "101", role: .assistant, content: "Earlier answer", timestamp: "2"),
                            ChatMessage(id: "102", role: .user, content: "Remote question", timestamp: "3"),
                            ChatMessage(id: "103", role: .assistant, content: "Remote answer", timestamp: "4")
                        ],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    return .failed(DashboardTicketBridgeError.http(
                        status: 404,
                        detail: "no session-messages endpoint"
                    ))
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(
            transcriptReads, 2,
            "Seed hydration + the foreground freshness read only — the hinted reconcile skips the history request"
        )
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground + 1,
            "Exactly one authoritative noncompact resume — no compact attempt, no second resume"
        )
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101", "102", "103"])
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertTrue(harness.appState.composerIsEnabled)
        XCTAssertFalse(harness.appState.activeChatScrollSessionIdentity.isReconciling)
        box.client.disconnect()
    }

    /// A transiently failed bounded tail read must not claim currency, must
    /// not escalate to a full-transcript read, and must not loop: the
    /// authoritative liveness adopts while the stale marker is RETAINED so
    /// the next authoritative source re-confirms.
    func testForegroundFreshnessTransientFailureKeepsStaleMarker() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let seedPayload: [String: Any] = [
            "messages": [
                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
            ],
            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload(seedPayload)
                    }
                    return .failed(DashboardTicketBridgeError.http(
                        status: 503,
                        detail: "temporarily unavailable"
                    ))
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        let messagesBefore = harness.appState.messages
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(
            transcriptReads, 2,
            "The failed bounded read must not be retried or escalated to a full read"
        )
        XCTAssertEqual(resumeCount, resumesBeforeForeground, "No resume cascade")
        XCTAssertEqual(harness.appState.messages, messagesBefore)
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertTrue(harness.appState.composerIsEnabled)
        XCTAssertFalse(
            harness.appState.turnStateIsStale,
            "Turn-state staleness is resolved: the registry's idle answer was adopted"
        )
        XCTAssertTrue(
            harness.appState.transcriptFreshnessIsStale,
            "Transcript freshness is unresolved: the freshness marker must be retained"
        )
        box.client.disconnect()
    }

    /// The transient-failure contract on the RUNNING liveness path: the
    /// observational adopt clears the stale marker and the reconcile must
    /// re-set it afterwards — a reorder would silently drop freshness
    /// resolution exactly where the in-flight projection makes it most
    /// valuable.
    func testForegroundFreshnessTransientFailureOnRunningTurnKeepsStaleMarker() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let midTurnPayload: [String: Any] = [
            "messages": [
                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                ["id": "102", "role": "user", "content": "Turn A question", "timestamp": "3"]
            ],
            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 3]
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(true)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload(midTurnPayload)
                    }
                    return .failed(DashboardTicketBridgeError.http(
                        status: 503,
                        detail: "temporarily unavailable"
                    ))
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.turnState, .running)
        let messagesBefore = harness.appState.messages
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2, "No retry, no escalation")
        XCTAssertEqual(resumeCount, resumesBeforeForeground, "No resume cascade")
        XCTAssertEqual(harness.appState.messages, messagesBefore)
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(
            harness.appState.turnStateIsStale,
            "Turn-state staleness is resolved: the registry's working answer was adopted"
        )
        XCTAssertTrue(
            harness.appState.transcriptFreshnessIsStale,
            "Transcript freshness is unresolved on the running path too: the freshness marker must be retained"
        )
        box.client.disconnect()
    }

    /// A remotely started RUNNING turn has an in-flight assistant/reasoning
    /// prefix persisted history cannot supply. The authoritative attach (the
    /// compact resume fast-path) returns that live projection on top of the
    /// merged persisted prefix, and future deltas extend it.
    func testForegroundRemoteRunningTurnAttachesUnpersistedLiveProjection() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        // The seeding resume finds the session idle; the
                        // authoritative attach returns the live runtime with
                        // the unpersisted in-flight projection.
                        snapshot: SessionRuntimeSnapshot(
                            object: ["running": .bool(resumeCount > 1)],
                            inflight: resumeCount > 1
                                ? .object(["text": .string("Remote partial answer")])
                                : nil
                        )
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Remote question", "timestamp": "3"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 3]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2)
        XCTAssertEqual(resumeCount, resumesBeforeForeground + 1, "Exactly one authoritative attach resume")
        XCTAssertEqual(
            harness.appState.messages.map(\.id), ["100", "101", "102"],
            "The remote persisted prefix is visible"
        )
        XCTAssertEqual(
            harness.appState.streamingText, "Remote partial answer",
            "The unpersisted in-flight prefix attaches through the resume"
        )
        XCTAssertEqual(harness.appState.turnState, .running)

        // Future deltas extend the attached projection.
        harness.appState.handleStreamEvent(.messageDelta(
            sessionId: active.id,
            text: " continued"
        ))
        let published = await waitForStreamingText(
            "Remote partial answer continued", in: harness.appState
        )
        XCTAssertTrue(published, "Future stream events continue the attached turn")
        box.client.disconnect()
    }

    /// Turn A running before background, A completing and Turn B starting in
    /// the SAME session while suspended: same-session identity is not
    /// same-turn proof. The persisted tail advancement forces the
    /// authoritative attach — B becomes authoritative with no stale Turn A
    /// reasoning segment and no missing prefix.
    func testForegroundTurnBInSameSessionIsNotContinuationOfTurnA() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        // The seeding hydration happens MID-TURN-A: the
                        // runtime was already working.
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(true)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                                ["id": "102", "role": "user", "content": "Turn A question", "timestamp": "3"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 3]
                        ])
                    }
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Turn A question", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Turn A answer", "timestamp": "4"],
                            ["id": "104", "role": "user", "content": "Turn B question", "timestamp": "5"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 5]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.turnState, .running, "Turn A is Conduit-owned")
        harness.appState.handleStreamEvent(.reasoningDelta(
            sessionId: active.id,
            text: "Turn A stale thinking"
        ))
        let staleSegment = harness.appState.liveReasoningSegment
        XCTAssertNotNil(staleSegment)
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 3, "Freshness read + the attach reconcile's bounded read")
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground + 1,
            "Unprovable same-turn continuity takes the authoritative attach exactly once"
        )
        XCTAssertEqual(
            harness.appState.messages.map(\.id),
            ["100", "101", "102", "103", "104"],
            "Turn A's completion and Turn B's prefix are both present"
        )
        XCTAssertNil(
            harness.appState.liveReasoningSegment,
            "Turn A's stale reasoning segment must not survive the authoritative attach"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertTrue(harness.appState.composerIsEnabled)
        box.client.disconnect()
    }

    /// Genuine Conduit-owned continuation after a mid-turn rehydration: the
    /// bounded freshness read proves same-turn continuity (unchanged tail),
    /// so the fast observational path keeps zero resumes, zero transcript
    /// replacement, and the identical live reasoning segment.
    func testForegroundGenuineContinuationAfterMidTurnRehydrationStaysZeroResume() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let midTurnPayload: [String: Any] = [
            "messages": [
                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                ["id": "102", "role": "user", "content": "Turn A question", "timestamp": "3"]
            ],
            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 3]
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(true)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    return .payload(midTurnPayload)
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101", "102"])
        harness.appState.handleStreamEvent(.reasoningDelta(
            sessionId: active.id,
            text: "Continuing Turn A"
        ))
        let segmentBefore = harness.appState.liveReasoningSegment
        XCTAssertNotNil(segmentBefore)
        let messagesBefore = harness.appState.messages
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2, "One bounded read proves same-turn continuity")
        XCTAssertEqual(resumeCount, resumesBeforeForeground, "Zero session.resume")
        XCTAssertEqual(harness.appState.messages, messagesBefore, "Zero transcript replacement")
        XCTAssertEqual(
            harness.appState.liveReasoningSegment?.id, segmentBefore?.id,
            "The live reasoning projection is untouched"
        )
        XCTAssertEqual(harness.appState.turnState, .running)

        // Future deltas continue the SAME segment.
        harness.appState.handleStreamEvent(.reasoningDelta(
            sessionId: active.id,
            text: " and more"
        ))
        await flushMainActor()
        XCTAssertEqual(harness.appState.liveReasoningSegment?.id, segmentBefore?.id)
        box.client.disconnect()
    }

    /// `starting` is liveness-inconclusive — but a stale `.synchronizing`
    /// left by an aborted recovery is not stream-owned state either. The
    /// foreground normalizes it to a usable neutral baseline: composer
    /// usable, starting never classified as running, zero reads.
    func testForegroundStartingNormalizesStaleSynchronizingState() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        let parkedRefresh = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    if resumeCount > 1 {
                        await parkedRefresh.suspend()
                    }
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier", "timestamp": "1"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "starting"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)

        Task { @MainActor in
            await harness.appState.refreshActiveSession()
        }
        await parkedRefresh.waitUntilSuspended()
        XCTAssertEqual(harness.appState.turnState, .synchronizing)

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(
            harness.appState.turnState, .idle,
            "A stale transitional state must normalize under a starting runtime"
        )
        XCTAssertTrue(
            harness.appState.composerIsEnabled,
            "The composer must not stay disabled on a starting runtime"
        )
        box.client.disconnect()
    }

    /// Same normalization for `.reconnecting`, and the ordering invariant: a
    /// newer buffered busy edge still wins over the normalized baseline.
    func testForegroundStartingNormalizesStaleReconnectingAndBusyEdgeWins() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        let parkedReconnect = LifecycleSuspension()
        let probeGate = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                mintTicket: { _ in
                    await parkedReconnect.suspend()
                    return "ticket"
                },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier", "timestamp": "1"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    await probeGate.suspend()
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "starting"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100"])

        Task { @MainActor in
            await harness.appState.reconnectForRetry(purpose: .automaticReturn)
        }
        await parkedReconnect.waitUntilSuspended()
        XCTAssertEqual(harness.appState.turnState, .reconnecting)

        harness.appState.handleScenePhase(.background)
        let activation = Task { @MainActor in
            await runSceneActivation(harness)
        }
        await probeGate.waitUntilSuspended()
        // A turn starts remotely while the probe is in flight: the newer
        // live edge must win over the normalized baseline.
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        probeGate.resume()
        await activation.value
        await flushMainActor()

        XCTAssertEqual(
            harness.appState.turnState, .running,
            "The newer buffered busy edge wins over the normalized baseline"
        )
        XCTAssertTrue(harness.appState.composerIsEnabled)
        XCTAssertEqual(resumeCount, 1, "The seeding reconcile owns the only resume")
        XCTAssertEqual(transcriptReads, 1, "A starting runtime performs no freshness read")
        box.client.disconnect()
    }

    // MARK: - D. inactive → active only

    func testInactiveToActiveCycleDoesNotResumeOrResetReasoning() async {
        let active = session("stored-a")
        var resumeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        harness.appState.messages = [
            ChatMessage(id: "user", role: .user, content: "Question", timestamp: "1")
        ]
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "Thinking."))
        let segmentBefore = harness.appState.liveReasoningSegment
        let returnSurfaceBefore = harness.appState.preferredReturnSurfaceRequest

        harness.appState.handleScenePhase(.inactive)
        await runSceneActivation(harness)

        XCTAssertEqual(resumeCount, 0, "An overlay dip must not resume the session")
        XCTAssertEqual(harness.appState.messages.map(\.id), ["user"])
        XCTAssertEqual(harness.appState.liveReasoningSegment, segmentBefore)
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertEqual(
            harness.appState.preferredReturnSurfaceRequest, returnSurfaceBefore,
            "An inactive → active cycle is not a background return"
        )
        XCTAssertFalse(harness.appState.turnStateIsStale)
        box.client.disconnect()
    }

    // MARK: - E. Dead socket

    func testForegroundWithDeadTransportReconnectsAndResumesOnce() async {
        let active = session("stored-a")
        var connects = 0
        var resumeCount = 0
        var catalogCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                connectClient: { _ in connects += 1 },
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [active]
                },
                mintTicket: { _ in "fresh-ticket" },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: "runtime-e",
                        messages: [
                            ChatMessage(
                                id: "assistant-e",
                                role: .assistant,
                                content: "Recovered",
                                timestamp: "2"
                            )
                        ],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                setBusyInputMode: { _, _ in },
                loadProfiles: {},
                loadBusyInputMode: { _ in },
                loadProfileDisplayPreferences: {},
                loadSlashCommands: {}
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(connects, 1, "The dead transport must be reconnected exactly once")
        XCTAssertEqual(resumeCount, 1, "Recovery must fall back to exactly one stored-session resume")
        XCTAssertEqual(catalogCount, 1)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["assistant-e"])
        XCTAssertEqual(harness.appState.turnState, .idle)
    }

    // MARK: - F. Gateway restart (runtime gone, stored session remains)

    func testForegroundAfterGatewayRestartResumesStoredSessionOnce() async {
        let active = session("stored-a", alternateIDs: ["runtime-old"])
        var probeCount = 0
        var resumeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    XCTAssertEqual(sessionID, "stored-a")
                    return SessionResumeResult(
                        sessionId: "runtime-new",
                        messages: [
                            ChatMessage(
                                id: "restored",
                                role: .assistant,
                                content: "After restart",
                                timestamp: "3"
                            )
                        ],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    // The gateway restarted: no live runtime exists for this
                    // session anymore.
                    return []
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = "runtime-old"
        harness.appState.messages = [
            ChatMessage(id: "stale", role: .user, content: "Before restart", timestamp: "1")
        ]

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(resumeCount, 1, "Exactly one stored-session resume must run")
        XCTAssertEqual(
            harness.appState.activeSessionId, "runtime-new",
            "The resumed runtime id must become authoritative"
        )
        XCTAssertEqual(harness.appState.messages.map(\.id), ["restored"])
        XCTAssertEqual(harness.appState.turnState, .idle)
        box.client.disconnect()
    }

    // MARK: - G. Ordinary successful prompt

    func testOrdinaryIdleSubmitStartsExactlyOneTurn() async {
        var submitCount = 0
        var probeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return []
                }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a")]
        harness.appState.activeSessionId = "stored-a"

        let submitted = await harness.appState.submitComposer(text: "Hello")

        XCTAssertTrue(submitted)
        XCTAssertEqual(submitCount, 1, "An ordinary submit must issue exactly one prompt.submit")
        XCTAssertEqual(probeCount, 0, "Trusted state must not pay for an authoritative probe")
        XCTAssertEqual(
            harness.appState.messages.last?.content, "Hello",
            "Exactly one optimistic user row is kept"
        )
        XCTAssertEqual(harness.appState.messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(harness.appState.turnState, .running)
    }

    // MARK: - H. Ambiguous acknowledgement, server proves the turn is running

    func testAmbiguousPromptSubmissionWithRunningServerTurnIsAcceptedOnce() async {
        let active = session("stored-a")
        var submitCount = 0
        var probeCount = 0
        var resumeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    // The RPC reached Hermes, but the acknowledgement was lost.
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        harness.appState.messages = [
            ChatMessage(id: "earlier", role: .assistant, content: "Earlier", timestamp: "0")
        ]

        let submitted = await harness.appState.submitComposer(text: "Ambiguous send")

        XCTAssertTrue(submitted, "The accepted turn must not surface as a failed send")
        XCTAssertEqual(submitCount, 1, "An accepted prompt must never be re-submitted")
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(resumeCount, 0, "The healthy transport must not be replaced")
        XCTAssertEqual(
            harness.appState.messages.last?.content, "Ambiguous send",
            "The optimistic user row must remain"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        box.client.disconnect()
    }

    // MARK: - I. Ambiguous submit, server proves the prompt was not accepted

    func testAmbiguousPromptSubmissionWithIdleServerRunsFailedSendRestorationOnce() async {
        let active = session("stored-a")
        var submitCount = 0
        var probeCount = 0
        var catalogCount = 0
        var resumeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [active]
                },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [
                            ChatMessage(
                                id: "persisted",
                                role: .assistant,
                                content: "Persisted history",
                                timestamp: "1"
                            )
                        ],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id

        let submitted = await harness.appState.submitComposer(text: "Never delivered")

        XCTAssertFalse(submitted, "A provably undelivered prompt is a failed send")
        XCTAssertEqual(submitCount, 1, "No blind retry may follow the ambiguous failure")
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(catalogCount, 1, "The failed-send restoration must run exactly once")
        XCTAssertEqual(resumeCount, 1)
        XCTAssertEqual(
            harness.appState.messages.map(\.id), ["persisted"],
            "The optimistic row is restored away exactly once by the authoritative transcript"
        )
        XCTAssertTrue(
            harness.appState.errorMessage?.contains("Failed to send") == true
        )
        XCTAssertEqual(harness.appState.turnState, .idle)
        box.client.disconnect()
    }

    // MARK: - J. Local idle / server running mismatch

    func testStaleIdleSubmissionRoutesThroughConfiguredBusyAction() async {
        let active = session("stored-a")
        var submitCount = 0
        var steerCount = 0
        var probeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    // The suspected production divergence: Hermes still runs
                    // the session while Conduit believes it is idle.
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                },
                steer: { _, _, _ in steerCount += 1 }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        // The lifecycle boundary marks the local turn state stale.
        harness.appState.handleScenePhase(.background)

        let submitted = await harness.appState.submitComposer(text: "Follow-up")

        XCTAssertTrue(submitted)
        XCTAssertEqual(probeCount, 1, "A stale idle state must be corrected before routing")
        XCTAssertEqual(
            submitCount, 0,
            "The message must NOT be sent as an ordinary new-turn prompt.submit"
        )
        XCTAssertEqual(
            steerCount, 1,
            "The corrected busy session must route the message through the configured busy action"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(harness.appState.turnStateIsStale)
    }

    // MARK: - K. Two genuinely idle turns stay independent

    func testSequentialIdleTurnsSubmitIndependently() async {
        var submitTexts: [String] = []
        var probeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, text in
                    submitTexts.append(text)
                    return .accepted
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return []
                }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a")]
        harness.appState.activeSessionId = "stored-a"

        let first = await harness.appState.submitComposer(text: "Message A")
        // Turn A completes authoritatively (server-driven busy=false edge).
        harness.appState.handleStreamEvent(
            .sessionBusy(sessionId: "stored-a", busy: false)
        )
        let second = await harness.appState.submitComposer(text: "Message B")

        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(
            submitTexts, ["Message A", "Message B"],
            "Two idle turns must be two independent prompt submissions"
        )
        XCTAssertEqual(probeCount, 0, "No stale-state probe may run for trusted idle state")
        XCTAssertEqual(
            harness.appState.messages.filter { $0.role == .user }.map(\.content),
            ["Message A", "Message B"],
            "No client-side concatenation of the two submissions"
        )
    }

    // MARK: - Prompt outcome typing (HermesClient seam-level)

    func testPromptSubmissionOutcomeClassification() {
        XCTAssertEqual(PromptSubmissionOutcome(gatewayStatus: "streaming"), .accepted)
        XCTAssertEqual(PromptSubmissionOutcome(gatewayStatus: "steered"), .steered)
        XCTAssertEqual(PromptSubmissionOutcome(gatewayStatus: "redirected"), .redirected)
        XCTAssertEqual(PromptSubmissionOutcome(gatewayStatus: "queued"), .queued)
        XCTAssertEqual(PromptSubmissionOutcome(gatewayStatus: "STREAMING"), .accepted)
        XCTAssertEqual(PromptSubmissionOutcome(gatewayStatus: nil), .accepted)
        XCTAssertFalse(PromptSubmissionOutcome.accepted.isBusySubmission)
        XCTAssertTrue(PromptSubmissionOutcome.queued.isBusySubmission)
        XCTAssertTrue(PromptSubmissionOutcome.steered.isBusySubmission)
        XCTAssertTrue(PromptSubmissionOutcome.redirected.isBusySubmission)
    }

    func testLiveSessionStatusRowParsing() throws {
        let row = try XCTUnwrap(LiveSessionStatus(from: [
            "id": .string("runtime-1"),
            "session_key": .string("stored-1"),
            "status": .string("working"),
            "last_active": .number(1234.5)
        ]))
        XCTAssertEqual(
            row,
            LiveSessionStatus(
                runtimeSessionId: "runtime-1",
                storedSessionId: "stored-1",
                status: "working",
                lastActive: 1234.5
            )
        )
        XCTAssertTrue(row.isRunning)
        XCTAssertTrue(
            LiveSessionStatus(
                runtimeSessionId: "r", storedSessionId: "s", status: "waiting"
            ).isRunning,
            "A pending decision keeps the turn live"
        )
        XCTAssertFalse(
            LiveSessionStatus(
                runtimeSessionId: "r", storedSessionId: "s", status: "starting"
            ).isRunning,
            "Starting also covers promptless agent pre-warm — not committed busy"
        )
        XCTAssertFalse(
            LiveSessionStatus(
                runtimeSessionId: "r", storedSessionId: "s", status: "idle"
            ).isRunning
        )
        XCTAssertNil(
            LiveSessionStatus(from: ["session_key": .string("missing-runtime-id")]),
            "A row without a runtime id cannot be matched"
        )
    }

    // MARK: - Reviewer-hardening coverage

    func testForegroundWithStartingRuntimeLeavesStateStreamOwned() async {
        let active = session("stored-a")
        var resumeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "starting"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        harness.appState.messages = [
            ChatMessage(id: "user", role: .user, content: "Question", timestamp: "1")
        ]
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(
            resumeCount, 0,
            "A starting runtime must never manufacture a resume refresh"
        )
        XCTAssertEqual(
            harness.appState.turnState, .running,
            "A starting row is liveness-inconclusive: local state stays stream-owned"
        )
        XCTAssertTrue(
            harness.appState.turnStateIsStale,
            "An inconclusive probe must not mark the state trusted"
        )
        box.client.disconnect()
    }

    func testForegroundWithUnavailableProbeFallsBackToResumeRefresh() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [
                            ChatMessage(
                                id: "restored",
                                role: .assistant,
                                content: "From legacy refresh",
                                timestamp: "2"
                            )
                        ],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    // An older gateway without session.active_list.
                    throw HermesError.invalidResponse
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(resumeCount, 1, "An unreadable registry must fall back to the resume refresh")
        XCTAssertEqual(harness.appState.messages.map(\.id), ["restored"])
        box.client.disconnect()
    }

    func testForegroundWithIdleProbeAndLocalRunningRecoversCompletedTurn() async {
        let active = session("stored-a")
        var resumeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [
                            ChatMessage(
                                id: "completed",
                                role: .assistant,
                                content: "Finished while away",
                                timestamp: "2"
                            )
                        ],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        harness.appState.messages = [
            ChatMessage(id: "user", role: .user, content: "Question", timestamp: "1")
        ]
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(
            resumeCount, 1,
            "A missed turn-end edge must recover through the authoritative transcript refresh"
        )
        XCTAssertEqual(harness.appState.messages.map(\.id), ["completed"])
        XCTAssertEqual(harness.appState.turnState, .idle)
        box.client.disconnect()
    }

    func testDefinitiveNotConnectedFailureSkipsAuthoritativeProbe() async {
        var submitCount = 0
        var probeCount = 0
        var catalogCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [self.session("stored-a")]
                },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    // rpc() throws notConnected before any bytes are written,
                    // so the outcome is definitive, not ambiguous.
                    throw HermesError.notConnected
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return []
                }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a")]
        harness.appState.activeSessionId = "stored-a"

        let submitted = await harness.appState.submitComposer(text: "Unsent")

        XCTAssertFalse(submitted)
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(
            probeCount, 0,
            "A provably undelivered prompt must not pay for an authoritative probe"
        )
        XCTAssertEqual(catalogCount, 1, "The ordinary failed-send restoration runs exactly once")
        XCTAssertTrue(harness.appState.errorMessage?.contains("Failed to send") == true)
    }

    func testStaleIdleWithUnavailableProbeFallsThroughToOrdinarySend() async {
        var submitCount = 0
        var steerCount = 0
        var probeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    throw HermesError.invalidResponse
                },
                steer: { _, _, _ in steerCount += 1 }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a")]
        harness.appState.activeSessionId = "stored-a"
        harness.appState.handleScenePhase(.background)

        let submitted = await harness.appState.submitComposer(text: "Direct send")

        XCTAssertTrue(submitted, "An unreadable probe must not block the user")
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(
            submitCount, 1,
            "The submission falls through to the ordinary new-turn send"
        )
        XCTAssertEqual(steerCount, 0)
        XCTAssertEqual(harness.appState.turnState, .running)
    }

    func testQueuedPromptOutcomeAdoptsAuthoritativeRunningState() async {
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    // Hermes was busy: the prompt joined the busy policy.
                    return .queued
                },
                probeActiveSessions: { _ in [] }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a")]
        harness.appState.activeSessionId = "stored-a"

        let submitted = await harness.appState.submitComposer(text: "Queued send")

        XCTAssertTrue(submitted)
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(
            harness.appState.turnState, .running,
            "A busy-policy outcome proves the session was running server-side"
        )
        XCTAssertFalse(harness.appState.turnStateIsStale)
    }

    // MARK: - Round 2: ambiguous acceptance proven by the durable transcript

    /// The headline fast-settle regression: the prompt was ACCEPTED, the turn
    /// completed, and by the time recovery probed, the registry had already
    /// gone absent. The durable transcript must prove acceptance instead of
    /// the submission being restored as unsent.
    func testAmbiguousAcceptedTurnCompletedBeforeProbeIsProvenByTranscript() async {
        let active = session("stored-a")
        var submitCount = 0
        var probeCount = 0
        var transcriptReads = 0
        var resumeCount = 0
        var catalogCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [active]
                },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        // The pre-submit hydration: two durable rows held.
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // Recovery: the accepted turn landed and settled.
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Ambiguous send", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Completed result", "timestamp": "4"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    // The turn completed and the runtime was reaped before
                    // recovery looked: current liveness is absent.
                    return []
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        // Establish durable provenance through the real hydration path.
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])
        let resumesBeforeSubmit = resumeCount

        let submitted = await harness.appState.submitComposer(text: "Ambiguous send")

        XCTAssertTrue(submitted, "Transcript-proven acceptance must not surface as a failed send")
        XCTAssertEqual(submitCount, 1, "An accepted prompt must never be re-submitted")
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2, "One bounded tail read decides the outcome")
        XCTAssertEqual(
            catalogCount, 0,
            "No failed-send restoration may run for a transcript-proven acceptance"
        )
        XCTAssertEqual(resumeCount, resumesBeforeSubmit)
        XCTAssertEqual(
            harness.appState.messages.last?.content, "Ambiguous send",
            "The submitted turn stays; the transcript converges on the next bounded refresh"
        )
        XCTAssertEqual(harness.appState.turnState, .idle, "The turn settled before recovery looked")
        XCTAssertFalse(harness.appState.turnStateIsStale)
        box.client.disconnect()
    }

    /// The genuine not-accepted case keeps its coverage: registry idle AND
    /// the durable transcript holds nothing beyond the submit-time baseline.
    func testAmbiguousPromptAbsentFromDurableTranscriptRestoresOnce() async {
        let active = session("stored-a")
        var submitCount = 0
        var transcriptReads = 0
        var catalogCount = 0
        var resumeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [active]
                },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [
                            ChatMessage(id: "100", role: .user, content: "Earlier question", timestamp: "1"),
                            ChatMessage(id: "101", role: .assistant, content: "Earlier answer", timestamp: "2")
                        ],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        // Establish durable provenance through the real hydration path: the
        // pre-submit conversation durably holds rows 100 and 101.
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])
        let resumesBeforeSubmit = resumeCount

        let submitted = await harness.appState.submitComposer(text: "Never delivered")

        XCTAssertFalse(submitted)
        XCTAssertEqual(submitCount, 1, "No blind retry may follow the ambiguous failure")
        XCTAssertEqual(
            transcriptReads, 3,
            "Hydration, ambiguous verification, and the restore's compact resume each read once"
        )
        XCTAssertEqual(catalogCount, 1, "The unsent restoration runs exactly once")
        XCTAssertEqual(resumeCount, resumesBeforeSubmit + 1)
        XCTAssertEqual(
            harness.appState.messages.map(\.id), ["100", "101"],
            "The optimistic row is restored away exactly once by the authoritative transcript"
        )
        XCTAssertTrue(harness.appState.errorMessage?.contains("Failed to send") == true)
        box.client.disconnect()
    }

    /// A duplicate-text trap: the transcript advanced with rows that do not
    /// carry the submitted text, while an OLDER identical user row exists.
    /// Ordering (baseline ids) must decide, not content matching.
    func testAmbiguousPromptWithDuplicateOlderTextIsProvenAbsentByOrdering() async {
        let active = session("stored-a")
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        // Pre-submit hydration: the older identical "go on".
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "go on", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier reply", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // Recovery: the tail advanced with a DIFFERENT newer ask.
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "go on", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier reply", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Different newer ask", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Newer reply", "timestamp": "4"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in throw HermesError.timeout("prompt.submit") },
                probeActiveSessions: { _ in
                    [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        // Establish durable provenance for the older identical "go on" row.
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])

        let submitted = await harness.appState.submitComposer(text: "go on")

        XCTAssertFalse(submitted, "The transcript advanced without this prompt: it was not accepted")
        XCTAssertEqual(transcriptReads, 3)
        XCTAssertEqual(
            harness.appState.messages.map(\.id), ["100", "101", "102", "103"],
            "Restoration converges on the authoritative tail even though only its older rows " +
            "predate the submission — the newer rows prove this prompt never landed"
        )
        box.client.disconnect()
    }

    /// No usable durable source (bridge unavailable): acceptance can be
    /// neither proven nor disproven — conservative restore, never a resend.
    func testAmbiguousPromptWithUnreadableTranscriptRestoresConservatively() async {
        var submitCount = 0
        var probeCount = 0
        var catalogCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [self.session("stored-a")]
                },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in .unavailable },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a")]
        harness.appState.activeSessionId = "stored-a"

        let submitted = await harness.appState.submitComposer(text: "Unverifiable send")

        XCTAssertFalse(submitted)
        XCTAssertEqual(submitCount, 1, "Unresolved acceptance must never become an automatic resend")
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(catalogCount, 1, "Exactly one conservative restoration")
    }

    // MARK: - Round 2: submission-owned stale-state correction

    /// A probe started for session A must not mutate anything after the user
    /// switched to session B: B's stale marker survives and B runs its own
    /// authoritative correction before its send.
    func testStaleIdleProbeSupersededBySessionHandoffDoesNotMutateNewSession() async {
        let sessionA = session("stored-a")
        let sessionB = session("stored-b")
        var probeCalls = 0
        var submitCount = 0
        var steerTargets: [String] = []
        let probeGate = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                probeActiveSessions: { _ in
                    probeCalls += 1
                    if probeCalls == 1 {
                        await probeGate.suspend()
                        return [LiveSessionStatus(
                            runtimeSessionId: "runtime-a",
                            storedSessionId: "stored-a",
                            status: "working"
                        )]
                    }
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-b",
                        storedSessionId: "stored-b",
                        status: "working"
                    )]
                },
                steer: { _, sessionID, _ in steerTargets.append(sessionID) }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [sessionA, sessionB]
        harness.appState.activeSessionId = sessionA.id
        harness.appState.handleScenePhase(.background)

        let submissionA = Task { @MainActor in
            await harness.appState.submitComposer(text: "A follow-up")
        }
        await probeGate.waitUntilSuspended()

        // The user switches to session B while A's probe is suspended.
        harness.appState.activeSessionId = sessionB.id
        probeGate.resume()
        let submittedA = await submissionA.value

        XCTAssertFalse(submittedA, "A superseded submission must abort, not fall through")
        XCTAssertEqual(submitCount, 0, "A's aborted submission must not send")
        XCTAssertEqual(steerTargets, [], "A's result must not steer")
        XCTAssertEqual(
            harness.appState.turnState, .idle,
            "A's running result must not be attributed to B"
        )
        XCTAssertTrue(
            harness.appState.turnStateIsStale,
            "B's stale marker must survive A's completed probe"
        )

        // B still performs its own authoritative probe before routing.
        let submittedB = await harness.appState.submitComposer(text: "B follow-up")
        XCTAssertTrue(submittedB)
        XCTAssertEqual(probeCalls, 2)
        XCTAssertEqual(steerTargets, ["stored-b"], "B routes through the configured busy action")
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(harness.appState.turnStateIsStale)
    }

    /// A prompt outcome returned after the user switched sessions must not
    /// adopt running state or clear staleness for the new session.
    func testPromptOutcomeHandoffDoesNotMutateNewSessionState() async {
        let sessionA = session("stored-a")
        let sessionB = session("stored-b")
        var submitCount = 0
        let sendGate = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    if submitCount == 1 {
                        await sendGate.suspend()
                    }
                    // Hermes was busy: a typed busy outcome for session A.
                    return .queued
                },
                probeActiveSessions: { _ in [] }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [sessionA, sessionB]
        harness.appState.activeSessionId = sessionA.id

        let submissionA = Task { @MainActor in
            await harness.appState.submitComposer(text: "A message")
        }
        await sendGate.waitUntilSuspended()

        // Switch to B, let B go stale, and establish B's authoritative idle
        // edge while A's RPC is still suspended.
        harness.appState.activeSessionId = sessionB.id
        harness.appState.handleScenePhase(.inactive)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: sessionB.id, busy: false))

        sendGate.resume()
        let submittedA = await submissionA.value

        XCTAssertTrue(submittedA, "A's remotely accepted send stays a success")
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(
            harness.appState.turnState, .idle,
            "A's busy outcome must not be misattributed to session B"
        )
        XCTAssertTrue(
            harness.appState.turnStateIsStale,
            "B's stale marker must not be cleared by A's outcome"
        )
    }

    /// A starting runtime is not committed busy: the stale-idle correction
    /// falls through to the ordinary send, whose typed outcome reconciles any
    /// genuine busy race.
    func testStaleIdleWithStartingRuntimeSendsOrdinaryTurn() async {
        var submitCount = 0
        var steerCount = 0
        var probeCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "starting"
                    )]
                },
                steer: { _, _, _ in steerCount += 1 }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a")]
        harness.appState.activeSessionId = "stored-a"
        harness.appState.handleScenePhase(.background)

        let submitted = await harness.appState.submitComposer(text: "Go")

        XCTAssertTrue(submitted)
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(steerCount, 0, "Starting alone must not route through busy steer")
        XCTAssertEqual(submitCount, 1, "The submission falls through to the ordinary new-turn send")
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(harness.appState.turnStateIsStale)
    }

    // MARK: - Round 2: foreground probe/event ordering

    /// A turn-ending event that arrives while the foreground probe is in
    /// flight is NEWER than the registry snapshot and must win: the settled
    /// state is idle, not a falsely-resurrected running turn.
    func testForegroundBufferedTurnEndWinsOverStaleRunningSnapshot() async {
        let active = session("stored-a")
        var resumeCount = 0
        let probeGate = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    .payload([
                        "messages": [
                            ["id": "user", "role": "user", "content": "Question", "timestamp": "1"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                    ])
                },
                refreshContext: { _, _ in },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    await probeGate.suspend()
                    // The snapshot was taken before the turn ended.
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        let sceneTask = harness.appState.handleScenePhase(.active)
        await probeGate.waitUntilSuspended()

        // The turn ENDS while the probe is still in flight: the newest edge.
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: false))
        probeGate.resume()
        await sceneTask?.value

        XCTAssertEqual(
            harness.appState.turnState, .idle,
            "The newest authoritative event must win over the older registry snapshot"
        )
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground,
            "The race must not manufacture a resume"
        )
        XCTAssertFalse(
            harness.appState.activeChatScrollSessionIdentity.isReconciling
        )
        box.client.disconnect()
    }

    // MARK: - Round 3: durable-anchor evidence model

    /// Case A: the pre-submit conversation holds an optimistic local row
    /// ("continue"), and the persisted tail contains an identical user row
    /// (501) that may be that SAME send re-homed under a database id. The
    /// verifier must not prove acceptance merely because "501" is not
    /// "local-123": with a durable anchor present but local-only rows
    /// outstanding, the outcome is indeterminate → conservative restore.
    func testAmbiguousMatchingRowAfterAnchorWithLocalPredecessorIsIndeterminate() async {
        let active = session("stored-a")
        var submitCount = 0
        var transcriptReads = 0
        var catalogCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [active]
                },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        // Pre-submit hydration: two durable rows held.
                        return .payload([
                            "messages": [
                                ["id": "98", "role": "user", "content": "prior", "timestamp": "0"],
                                ["id": "99", "role": "assistant", "content": "ack", "timestamp": "1"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // Recovery: an identical user row exists after the anchor,
                    // but the conversation also held an optimistic local row.
                    return .payload([
                        "messages": [
                            ["id": "98", "role": "user", "content": "prior", "timestamp": "0"],
                            ["id": "99", "role": "assistant", "content": "ack", "timestamp": "1"],
                            ["id": "501", "role": "user", "content": "continue", "timestamp": "5"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 3]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        // Establish durable provenance for rows 98/99 through real hydration.
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        // Turn 1 was sent optimistically and never re-hydrated: its persisted
        // twin's id is unknown to this conversation.
        harness.appState.messages.append(
            ChatMessage(id: "local-123", role: .user, content: "continue", timestamp: "2")
        )

        let submitted = await harness.appState.submitComposer(text: "continue")

        XCTAssertFalse(
            submitted,
            "An identical persisted row after the anchor cannot be attributed to this submission"
        )
        XCTAssertEqual(submitCount, 1, "No automatic resend")
        XCTAssertEqual(transcriptReads, 3)
        XCTAssertEqual(catalogCount, 1, "The conservative restoration runs exactly once")
        XCTAssertEqual(
            harness.appState.messages.filter { $0.role == .user && $0.content == "continue" }.count,
            1,
            "The optimistic duplicate is restored away; exactly one user row remains"
        )
        box.client.disconnect()
    }

    /// Case B: the first identical turn is durably anchored (hydrated rows
    /// 501/502) and the tail advances past that anchor with a NEW identical
    /// user row (503) plus its response — acceptance is provable.
    func testAmbiguousNewIdenticalRowBeyondDurableAnchorIsAcceptedSettled() async {
        let active = session("stored-a")
        var submitCount = 0
        var probeCount = 0
        var catalogCount = 0
        var transcriptReads = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [active]
                },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        // Pre-submit hydration: the first identical turn is
                        // durably anchored (rows 501/502).
                        return .payload([
                            "messages": [
                                ["id": "501", "role": "user", "content": "continue", "timestamp": "1"],
                                ["id": "502", "role": "assistant", "content": "done", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // Recovery: the tail advanced past the anchor with a NEW
                    // identical user row (503) plus its response.
                    return .payload([
                        "messages": [
                            ["id": "501", "role": "user", "content": "continue", "timestamp": "1"],
                            ["id": "502", "role": "assistant", "content": "done", "timestamp": "2"],
                            ["id": "503", "role": "user", "content": "continue", "timestamp": "3"],
                            ["id": "504", "role": "assistant", "content": "done again", "timestamp": "4"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    // The turn already completed and the runtime was reaped.
                    return []
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        // Durably anchor the FIRST identical turn (rows 501/502) via real
        // hydration; the verifier may then treat 503 as new.
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["501", "502"])

        let submitted = await harness.appState.submitComposer(text: "continue")

        XCTAssertTrue(submitted, "Durable ordering proves the second identical turn landed")
        XCTAssertEqual(submitCount, 1, "No second prompt.submit")
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(catalogCount, 0, "No composer restoration for a proven acceptance")
        XCTAssertEqual(
            harness.appState.messages.last?.content, "continue",
            "The optimistic row converges with the persisted transcript"
        )
        XCTAssertEqual(harness.appState.turnState, .idle, "The turn settled before recovery looked")
        XCTAssertFalse(harness.appState.turnStateIsStale)
        box.client.disconnect()
    }

    /// Case C: with NO durable pre-submit anchor at all, a matching persisted
    /// row cannot be dated — indeterminate, never present.
    func testAmbiguousMatchingRowWithoutDurableAnchorIsIndeterminate() async {
        var submitCount = 0
        var catalogCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [self.session("stored-a")]
                },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    .payload([
                        "messages": [
                            ["id": "501", "role": "user", "content": "continue", "timestamp": "5"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [session("stored-a")]
        harness.appState.activeSessionId = "stored-a"
        harness.appState.messages = [
            ChatMessage(id: "local-123", role: .user, content: "continue", timestamp: "2")
        ]

        let submitted = await harness.appState.submitComposer(text: "continue")

        XCTAssertFalse(submitted, "Without a durable anchor the outcome must not claim acceptance")
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(catalogCount, 1, "Conservative restoration exactly once")
    }

    // MARK: - Round 3: post-recovery presentation ownership

    /// A failed-send error produced by session A's ambiguous recovery must
    /// not paint the error (or any turn state) onto session B after the user
    /// switched mid-recovery.
    func testAmbiguousRecoveryErrorDoesNotLeakIntoHandedOffSession() async {
        let sessionA = session("stored-a")
        let sessionB = session("stored-b")
        var submitCount = 0
        var probeCount = 0
        var catalogCount = 0
        let probeGate = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [sessionA]
                },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    await probeGate.suspend()
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [sessionA, sessionB]
        harness.appState.activeSessionId = sessionA.id
        // Establish durable provenance through the real hydration path.
        let opened = await harness.appState.openSession(sessionA.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])

        let submissionA = Task { @MainActor in
            await harness.appState.submitComposer(text: "A doomed send")
        }
        await probeGate.waitUntilSuspended()

        // The user switches to session B while A's recovery is suspended.
        harness.appState.activeSessionId = sessionB.id
        harness.appState.handleScenePhase(.inactive)
        harness.appState.errorMessage = "B-sentinel"

        probeGate.resume()
        let submittedA = await submissionA.value

        XCTAssertFalse(submittedA)
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(
            harness.appState.errorMessage, "B-sentinel",
            "A's stale send failure must not overwrite B's error surface"
        )
        XCTAssertTrue(
            harness.appState.turnStateIsStale,
            "B's stale marker must survive A's recovery"
        )
        XCTAssertEqual(catalogCount, 0, "A's restoration is skipped under lost ownership")
        box.client.disconnect()
    }

    /// Round 4: the accepted turn generated so much activity that BOTH the
    /// pre-submit durable anchor and the submitted row fell out of the newest
    /// bounded page. Ordering evidence is gone — content absence from a
    /// window cannot prove non-acceptance, so the outcome is indeterminate
    /// (conservative restore, no resend, no false rejection claim).
    func testAmbiguousPromptBeyondBoundedTailIsIndeterminate() async {
        let active = session("stored-a")
        var submitCount = 0
        var transcriptReads = 0
        var catalogCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in
                    catalogCount += 1
                    return [active]
                },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        // Pre-submit hydration: one durable anchor row held.
                        return .payload([
                            "messages": [
                                ["id": "500", "role": "assistant", "content": "anchor row", "timestamp": "1"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                        ])
                    }
                    // Recovery: the newest page holds neither the anchor nor
                    // the submitted user row — the accepted turn's activity
                    // pushed both out of the window.
                    return .payload([
                        "messages": [
                            ["id": "601", "role": "assistant", "content": "much later output", "timestamp": "9"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    throw HermesError.timeout("prompt.submit")
                },
                probeActiveSessions: { _ in
                    [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["500"])

        let submitted = await harness.appState.submitComposer(text: "continue")

        XCTAssertFalse(
            submitted,
            "Without ordering evidence the submission must be treated as unresolved"
        )
        XCTAssertEqual(submitCount, 1, "No automatic resend of the ambiguous prompt")
        XCTAssertEqual(transcriptReads, 3)
        XCTAssertEqual(catalogCount, 1, "Exactly one conservative restoration")
        XCTAssertFalse(
            harness.appState.messages.contains { $0.role == .user && $0.content == "continue" },
            "The unresolved submission is restored rather than kept as sent"
        )
        box.client.disconnect()
    }

    /// Synthetic visible ids (optimistic sends, live streaming completions,
    /// positional fallbacks, reasoning/tool projections) carry no persisted
    /// provenance and must never become overlap anchors — even when the tail
    /// contains a matching user row that could be the older logical twin.
    func testSyntheticVisibleIDsNeverBecomeDurableAnchors() async {
        for syntheticID in [
            "local-123",
            "assistant-1700000000",
            "3",
            "reasoning-1700000001",
            "tool-start-1700000002"
        ] {
            let harness = makeHarness(
                lifecycleOperations: ChatResumeLifecycleOperations(
                    loadCatalog: { _, _ in [self.session("stored-a")] },
                    openSession: { _, sessionID, _ in
                        SessionResumeResult(
                            sessionId: sessionID,
                            messages: [],
                            snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                        )
                    },
                    persistedTranscript: { _, _ in
                        .payload([
                            "messages": [
                                ["id": "501", "role": "user", "content": "continue", "timestamp": "5"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                        ])
                    },
                    refreshContext: { _, _ in },
                    sendPrompt: { _, _, _ in throw HermesError.timeout("prompt.submit") },
                    probeActiveSessions: { _ in
                        [LiveSessionStatus(
                            runtimeSessionId: "runtime-a",
                            storedSessionId: "stored-a",
                            status: "idle"
                        )]
                    }
                )
            )
            installDisconnectedClient(into: harness)
            harness.appState.sessions = [session("stored-a")]
            harness.appState.activeSessionId = "stored-a"
            // The visible conversation holds ONLY a synthetic id: no positive
            // persisted provenance exists.
            harness.appState.messages = [
                ChatMessage(id: syntheticID, role: .user, content: "continue", timestamp: "1")
            ]

            let submitted = await harness.appState.submitComposer(text: "continue")

            XCTAssertFalse(
                submitted,
                "Synthetic id \(syntheticID) must not prove acceptance"
            )
            XCTAssertEqual(
                harness.appState.turnState, .idle,
                "Synthetic id \(syntheticID) must not adopt a running state"
            )
            XCTAssertEqual(
                harness.appState.messages.last?.id, "501",
                "Synthetic id \(syntheticID): the durable tail restored exactly once"
            )
        }
    }

    // MARK: - Round 8: locally-owned optimistic tails, freshness split, single structural resume

    /// The NORMAL workflow: a real `submitComposer` turn starts with an
    /// optimistic `local-*` user row that has NO durable id. Background +
    /// foreground with the runtime still working on that same locally
    /// submitted turn must stay observational — zero `session.resume`, zero
    /// transcript replacement, the optimistic row and the live reasoning
    /// segment survive, and later deltas extend the same turn.
    func testForegroundNormalLocallySubmittedRunningTurnStaysObservational() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let seedPayload: [String: Any] = [
            "messages": [
                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
            ],
            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    // Every read returns only the durable pre-turn history:
                    // the in-flight turn has persisted nothing.
                    return .payload(seedPayload)
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])

        // The real submit path: optimistic user row, accepted prompt, live
        // reasoning projection.
        let submitted = await harness.appState.submitComposer(text: "Follow-up question")
        XCTAssertTrue(submitted)
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(harness.appState.messages.count, 3)
        XCTAssertEqual(harness.appState.messages.last?.role, .user)
        XCTAssertTrue(
            harness.appState.messages.last?.id.hasPrefix("local-") == true,
            "The visible user row must be the optimistic local row"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "Thinking."))
        let segmentBefore = harness.appState.liveReasoningSegment
        XCTAssertNotNil(segmentBefore)
        let messagesBefore = harness.appState.messages
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(
            transcriptReads, 2,
            "One bounded freshness read; the durable frontier is unchanged"
        )
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground,
            "The normal locally-submitted running turn must NOT pay a session.resume"
        )
        XCTAssertEqual(harness.appState.messages, messagesBefore, "No transcript replacement")
        XCTAssertEqual(
            harness.appState.liveReasoningSegment, segmentBefore,
            "The live reasoning projection survives the foreground cycle"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(harness.appState.turnStateIsStale)
        XCTAssertFalse(harness.appState.transcriptFreshnessIsStale)

        // Future deltas extend the SAME turn — no reset, no replacement.
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: " More."))
        XCTAssertEqual(
            harness.appState.liveReasoningSegment?.id, segmentBefore?.id,
            "Later deltas must extend the same live reasoning segment"
        )
        // The sidebar toggle synchronously flushes the coalesced live
        // projection publish (the established deterministic-test pattern).
        harness.appState.showSidebar = true
        harness.appState.showSidebar = false
        XCTAssertEqual(
            harness.appState.liveReasoningSegment?.content, "Thinking. More.",
            "The delta merged into the SAME segment's buffer"
        )
        box.client.disconnect()
    }

    /// A locally-submitted Turn A whose persisted evidence advanced past the
    /// pre-turn frontier while suspended (A completed, another surface
    /// started Turn B) must NOT keep the optimistic tail as same-turn
    /// continuation. The tail shows TWO new canonical user-turn boundaries
    /// after the pre-submit anchor (Turn A's twin and Turn B's prompt): the
    /// second boundary proves a later turn exists and forces the
    /// authoritative attach, resetting Turn A's live projection in favor of
    /// Turn B's.
    func testForegroundLocallyOwnedOptimisticTailYieldsToPersistedTurnB() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(
                            object: ["running": .bool(resumeCount > 1)],
                            inflight: resumeCount > 1
                                ? .object(["text": .string("Turn B partial answer")])
                                : nil
                        )
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // Turn A's rows AND Turn B's first row are persisted:
                    // advancement beyond the locally-owned pre-turn frontier.
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Turn A question", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Turn A answer", "timestamp": "4"],
                            ["id": "104", "role": "user", "content": "Turn B question", "timestamp": "5"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 5]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)

        let submitted = await harness.appState.submitComposer(text: "Turn A question")
        XCTAssertTrue(submitted)
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(harness.appState.turnState, .running)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "Turn A thinking."))
        XCTAssertNotNil(harness.appState.liveReasoningSegment)
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 3, "Freshness read + the attach reconcile's bounded read")
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground + 1,
            "Persisted advancement behind an optimistic tail forces the authoritative attach"
        )
        XCTAssertEqual(
            harness.appState.messages.map(\.id), ["100", "101", "102", "103", "104"],
            "Turn A completion and Turn B prefix are visible after the attach"
        )
        XCTAssertNil(
            harness.appState.liveReasoningSegment,
            "The stale Turn A reasoning segment must not survive the attach"
        )
        XCTAssertEqual(
            harness.appState.streamingText, "Turn B partial answer",
            "Turn B's live projection is authoritative"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        box.client.disconnect()
    }

    /// A transient foreground freshness failure leaves
    /// `transcriptFreshnessIsStale` set. The next NEW-TURN submit runs
    /// exactly one bounded tail-only retry; when it proves advancement, the
    /// missing rows merge BEFORE the optimistic user row appends, and the
    /// send proceeds with zero resume.
    func testPreSendFreshnessRetryMergesMissingRowsBeforeNewPrompt() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    if transcriptReads == 2 {
                        // The foreground freshness read fails transiently.
                        return .failed(DashboardTicketBridgeError.http(
                            status: 503,
                            detail: "temporarily unavailable"
                        ))
                    }
                    // The pre-send retry proves the remote completed turn.
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Remote question", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Remote answer", "timestamp": "4"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        let resumesBefore = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2, "No foreground retry, no legacy fallback")
        XCTAssertEqual(resumeCount, resumesBefore, "No resume on the transient path")
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertFalse(harness.appState.turnStateIsStale)
        XCTAssertTrue(harness.appState.transcriptFreshnessIsStale)

        let submitted = await harness.appState.submitComposer(text: "Follow-up")
        XCTAssertTrue(submitted)

        XCTAssertEqual(submitCount, 1, "prompt.submit called exactly once")
        XCTAssertEqual(transcriptReads, 3, "Exactly one bounded pre-send retry")
        XCTAssertEqual(
            resumeCount, resumesBefore,
            "The merge needs no resume — the persisted source supplied the rows"
        )
        XCTAssertEqual(
            harness.appState.messages.count, 5,
            "Missing remote rows reconcile, then the optimistic user appends"
        )
        XCTAssertEqual(
            Array(harness.appState.messages.map(\.id).prefix(4)), ["100", "101", "102", "103"],
            "The remote rows land before the new prompt"
        )
        XCTAssertEqual(harness.appState.messages.last?.role, .user)
        XCTAssertTrue(
            harness.appState.messages.last?.id.hasPrefix("local-") == true,
            "The new prompt appends last, after the reconciled rows"
        )
        XCTAssertFalse(
            harness.appState.transcriptFreshnessIsStale,
            "A proven advancement merge clears transcript freshness"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        box.client.disconnect()
    }

    /// A SECOND transient freshness failure at the pre-send gate must not
    /// loop, must not fall back to full history, and must not silently
    /// append a new-turn prompt into an unresolved ordering: the send is
    /// blocked with a lightweight retryable message.
    func testPreSendFreshnessRetryTransientFailureBlocksNewTurn() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    return .failed(DashboardTicketBridgeError.http(
                        status: 503,
                        detail: "temporarily unavailable"
                    ))
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        let resumesBefore = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)
        XCTAssertTrue(harness.appState.transcriptFreshnessIsStale)

        let submitted = await harness.appState.submitComposer(text: "Follow-up")
        XCTAssertFalse(submitted, "The blocked send must not report success")

        XCTAssertEqual(submitCount, 0, "No prompt.submit into an unresolved ordering")
        XCTAssertEqual(transcriptReads, 3, "Foreground read + one retry; no loop, no legacy fallback")
        XCTAssertEqual(resumeCount, resumesBefore, "A transient failure never escalates to a resume")
        XCTAssertEqual(
            harness.appState.messages.map(\.id), ["100", "101"],
            "The new-turn prompt must not append out of order"
        )
        XCTAssertTrue(
            harness.appState.transcriptFreshnessIsStale,
            "Freshness stays unresolved after the second transient failure"
        )
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertTrue(harness.appState.composerIsEnabled)
        XCTAssertFalse(harness.appState.activeChatScrollSessionIdentity.isReconciling)
        box.client.disconnect()
    }

    // MARK: - Round 9: realistic persisted shape, busy-edge race

    /// The REALISTIC locally-submitted turn: Hermes persists the user row at
    /// turn start, so the foreground bounded tail already contains the
    /// durable twin (102) of Conduit's optimistic local row. Exactly ONE new
    /// canonical user-turn boundary after the pre-submit anchor is the
    /// expected Turn A twin — it must NOT force a resume: zero
    /// `session.resume`, transcript untouched (the twin is never merged
    /// behind the optimistic bubble), live reasoning projection intact.
    func testForegroundLocalTurnAWithPersistedUserTwinStaysObservational() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let seedPayload: [String: Any] = [
            "messages": [
                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
            ],
            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload(seedPayload)
                    }
                    // The freshness read: Hermes' crash-resilience path has
                    // already persisted the durable twin of our optimistic
                    // user row.
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Follow-up question", "timestamp": "3"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 3]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])

        let submitted = await harness.appState.submitComposer(text: "Follow-up question")
        XCTAssertTrue(submitted)
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(harness.appState.messages.count, 3)
        XCTAssertTrue(
            harness.appState.messages.last?.id.hasPrefix("local-") == true,
            "The visible user row must still be the optimistic local row"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "Thinking."))
        let segmentBefore = harness.appState.liveReasoningSegment
        XCTAssertNotNil(segmentBefore)
        let messagesBefore = harness.appState.messages
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2, "One bounded freshness read")
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground,
            "The durable user twin of our own turn must NOT force a session.resume"
        )
        XCTAssertEqual(
            harness.appState.messages, messagesBefore,
            "The persisted twin is never merged behind the optimistic row"
        )
        XCTAssertEqual(harness.appState.liveReasoningSegment, segmentBefore)
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(harness.appState.transcriptFreshnessIsStale)

        // Future deltas extend the SAME turn.
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: " More."))
        XCTAssertEqual(harness.appState.liveReasoningSegment?.id, segmentBefore?.id)
        harness.appState.showSidebar = true
        harness.appState.showSidebar = false
        XCTAssertEqual(harness.appState.liveReasoningSegment?.content, "Thinking. More.")
        box.client.disconnect()
    }

    /// Turn A's crash-resilience persistence can outrun the live stream:
    /// besides the durable user twin, assistant and tool rows of the SAME
    /// turn may already be persisted while the runtime is still working.
    /// Non-user rows do not prove another turn: exactly one new canonical
    /// user boundary stays same-turn continuation — zero resume, same live
    /// projection, same optimistic local row.
    func testForegroundLocalTurnAWithPersistedTurnARowsStaysObservational() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // Turn A's user twin PLUS two Turn A rows (assistant
                    // output and a tool row): still only ONE new user-turn
                    // boundary after the pre-submit anchor.
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "Follow-up question", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Working answer", "timestamp": "4"],
                            ["id": "104", "role": "tool", "content": "tool output", "timestamp": "5"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 5]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)

        let submitted = await harness.appState.submitComposer(text: "Follow-up question")
        XCTAssertTrue(submitted)
        XCTAssertEqual(submitCount, 1)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "Thinking."))
        let segmentBefore = harness.appState.liveReasoningSegment
        let messagesBefore = harness.appState.messages
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2)
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground,
            "Turn A's own persisted output/tool rows must NOT force a session.resume"
        )
        XCTAssertEqual(harness.appState.messages, messagesBefore)
        XCTAssertEqual(harness.appState.liveReasoningSegment, segmentBefore)
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(harness.appState.transcriptFreshnessIsStale)
        box.client.disconnect()
    }

    /// A busy edge that races the pre-send freshness read must win: when the
    /// gate's bounded read returns and the SAME conversation has turned
    /// running, the text routes through the configured busy submission —
    /// never an ordinary new-turn `prompt.submit`, and no optimistic
    /// new-turn row is appended into the running turn.
    func testPreSendFreshnessRetryYieldsToBusyEdge() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        var steerCount = 0
        let parkedRead = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    if transcriptReads == 2 {
                        // The foreground freshness read fails transiently,
                        // arming the pre-send gate.
                        return .failed(DashboardTicketBridgeError.http(
                            status: 503,
                            detail: "temporarily unavailable"
                        ))
                    }
                    // Hold ONLY the pre-send retry; the busy edge lands
                    // while it is suspended.
                    if transcriptReads == 3 {
                        await parkedRead.suspend()
                    }
                    return .failed(DashboardTicketBridgeError.http(
                        status: 503,
                        detail: "temporarily unavailable"
                    ))
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                },
                steer: { _, _, _ in
                    steerCount += 1
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)
        XCTAssertTrue(harness.appState.transcriptFreshnessIsStale)
        XCTAssertEqual(harness.appState.turnState, .idle)

        let submission = Task { @MainActor in
            await harness.appState.submitComposer(text: "Follow-up")
        }
        await parkedRead.waitUntilSuspended()
        // The race: a live busy edge arrives while the pre-send freshness
        // read is suspended.
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        XCTAssertEqual(harness.appState.turnState, .running)
        parkedRead.resume()

        let submitted = await submission.value
        XCTAssertTrue(submitted, "The steered busy submission reports success")

        XCTAssertEqual(submitCount, 0, "No ordinary prompt.submit into a running turn")
        XCTAssertEqual(steerCount, 1, "The text routed through the configured busy action")
        XCTAssertEqual(transcriptReads, 3, "No retry loop behind the routed submission")
        XCTAssertEqual(
            harness.appState.messages.map(\.id), ["100", "101"],
            "No optimistic new-turn row is appended into the running turn"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertTrue(
            harness.appState.transcriptFreshnessIsStale,
            "The busy path does not claim transcript freshness it never checked"
        )
        box.client.disconnect()
    }

    // MARK: - Round 9 review hardening

    /// The twin is what makes the one-boundary shape provable. When the
    /// first persisted row after the pre-submit anchor is NOT a user prompt
    /// (the twin is missing while Turn A output rows persisted), the page
    /// cannot prove same-turn continuity — the classifier must take the
    /// authoritative attach, not observational adoption.
    func testForegroundLocalTurnAWithMissingUserTwinTakesAttach() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(
                            object: ["running": .bool(resumeCount > 1)],
                            inflight: resumeCount > 1
                                ? .object(["text": .string("Recovered partial answer")])
                                : nil
                        )
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // Turn A output rows persisted WITHOUT the user twin:
                    // the first row after the anchor is not a user prompt.
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "103", "role": "assistant", "content": "Orphaned output", "timestamp": "3"],
                            ["id": "104", "role": "assistant", "content": "More orphaned output", "timestamp": "4"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)

        let submitted = await harness.appState.submitComposer(text: "Follow-up question")
        XCTAssertTrue(submitted)
        XCTAssertEqual(submitCount, 1)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "Turn A thinking."))
        XCTAssertNotNil(harness.appState.liveReasoningSegment)
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 3, "Freshness read + the attach reconcile's bounded read")
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground + 1,
            "A non-user first row after the anchor cannot prove same-turn continuity"
        )
        XCTAssertEqual(
            harness.appState.messages.map(\.id), ["100", "101", "103", "104"],
            "The authoritative attach owns the unprovable tail"
        )
        XCTAssertNil(
            harness.appState.liveReasoningSegment,
            "The optimistic live projection must not survive the attach"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        box.client.disconnect()
    }

    /// A brand-new conversation's first locally-submitted turn: the initial
    /// hydration POSITIVELY proved the persisted transcript empty, which is
    /// valid ordering evidence (distinct from unknown). The persisted twin
    /// of the optimistic first-turn row — exactly ONE new canonical
    /// user-turn boundary after a positively-empty baseline, with the
    /// runtime still working — stays same-turn observational: zero
    /// `session.resume`, zero transcript replacement, optimistic row and
    /// live reasoning projection intact.
    func testForegroundFirstTurnFromPositivelyEmptyBaselineStaysObservational() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        // A positively empty conversation: no durable rows.
                        return .payload([
                            "messages": [],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 0]
                        ])
                    }
                    // The twin of our optimistic first-turn user row.
                    return .payload([
                        "messages": [
                            ["id": "102", "role": "user", "content": "First question", "timestamp": "1"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 1]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertTrue(harness.appState.messages.isEmpty)

        let submitted = await harness.appState.submitComposer(text: "First question")
        XCTAssertTrue(submitted)
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(harness.appState.messages.count, 1)
        XCTAssertTrue(
            harness.appState.messages.last?.id.hasPrefix("local-") == true,
            "The visible user row is the optimistic local row"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "Thinking."))
        let segmentBefore = harness.appState.liveReasoningSegment
        XCTAssertNotNil(segmentBefore)
        let messagesBefore = harness.appState.messages
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2, "One bounded freshness read")
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground,
            "A positively-empty baseline makes the first turn's twin provable — zero session.resume"
        )
        XCTAssertEqual(
            harness.appState.messages, messagesBefore,
            "The persisted twin is never merged behind the optimistic row"
        )
        XCTAssertEqual(harness.appState.liveReasoningSegment, segmentBefore)
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(harness.appState.transcriptFreshnessIsStale)

        // Future deltas extend the SAME turn.
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: " More."))
        XCTAssertEqual(harness.appState.liveReasoningSegment?.id, segmentBefore?.id)
        harness.appState.showSidebar = true
        harness.appState.showSidebar = false
        XCTAssertEqual(harness.appState.liveReasoningSegment?.content, "Thinking. More.")
        box.client.disconnect()
    }

    /// Consecutive locally-owned turns: the Turn A foreground's unchanged
    /// verdict advances the persisted ordering frontier through Turn A's
    /// persisted rows WITHOUT touching the visible transcript, so Turn B's
    /// marker anchors past them — Turn B's foreground must not miscount
    /// Turn A's rows as foreign user-turn boundaries. Both foregrounds stay
    /// observational: zero `session.resume`.
    func testConsecutiveLocallyOwnedTurnsAdvancePersistedOrderingFrontier() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    if transcriptReads == 2 {
                        // Turn A's durable twin + output while A runs.
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                                ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                                ["id": "103", "role": "assistant", "content": "Answer A", "timestamp": "4"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                        ])
                    }
                    // Turn B's twin: only ONE new user boundary after the
                    // advanced ordering frontier (103).
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Answer A", "timestamp": "4"],
                            ["id": "104", "role": "user", "content": "B", "timestamp": "5"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 5]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])

        // --- Turn A ---
        let submittedA = await harness.appState.submitComposer(text: "A")
        XCTAssertTrue(submittedA)
        XCTAssertEqual(submitCount, 1)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "A thinking."))
        let segmentA = harness.appState.liveReasoningSegment
        XCTAssertNotNil(segmentA)
        let messagesAfterA = harness.appState.messages

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2)
        XCTAssertEqual(
            resumeCount, 1,
            "Turn A's foreground with its durable twin stays observational"
        )
        XCTAssertEqual(harness.appState.messages, messagesAfterA)
        XCTAssertEqual(harness.appState.liveReasoningSegment, segmentA)
        XCTAssertEqual(harness.appState.turnState, .running)

        // Settle Turn A locally through the normal stream completion path.
        harness.appState.handleStreamEvent(.messageComplete(
            sessionId: active.id,
            messageId: nil,
            content: "Answer A",
            reasoning: nil
        ))
        harness.appState.handleStreamEvent(.messageStart(sessionId: active.id))
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: false))
        XCTAssertEqual(harness.appState.turnState, .idle)

        // --- Turn B ---
        let submittedB = await harness.appState.submitComposer(text: "B")
        XCTAssertTrue(submittedB)
        XCTAssertEqual(submitCount, 2)
        XCTAssertEqual(harness.appState.turnState, .running)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "B thinking."))
        let segmentB = harness.appState.liveReasoningSegment
        XCTAssertNotNil(segmentB)
        let messagesAfterB = harness.appState.messages

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 2)
        XCTAssertEqual(transcriptReads, 3, "One bounded freshness read per background return")
        XCTAssertEqual(
            resumeCount, 1,
            "Turn A's persisted rows must not be miscounted as foreign boundaries — Turn B stays observational"
        )
        XCTAssertEqual(harness.appState.messages, messagesAfterB, "No transcript replacement")
        XCTAssertEqual(harness.appState.liveReasoningSegment, segmentB)
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(harness.appState.transcriptFreshnessIsStale)

        // Future Turn B deltas extend the SAME segment.
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: " More."))
        XCTAssertEqual(harness.appState.liveReasoningSegment?.id, segmentB?.id)
        box.client.disconnect()
    }

    /// Frontier advancement never weakens cross-surface protection: the
    /// locally-owned marker's baseline is FROZEN at submit time, so after
    /// Turn A's foreground advances the frontier through 103, a SECOND
    /// background return where A completed and a remote Turn B started
    /// still sees TWO boundaries against the frozen baseline and takes the
    /// authoritative attach.
    func testForegroundRemoteTurnBAfterFrontierAdvanceStillAttaches() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(
                            object: ["running": .bool(resumeCount > 1)],
                            inflight: resumeCount > 1
                                ? .object(["text": .string("Turn B partial answer")])
                                : nil
                        )
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    if transcriptReads == 2 {
                        // Turn A's twin + output while A runs.
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                                ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                                ["id": "103", "role": "assistant", "content": "Answer A", "timestamp": "4"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                        ])
                    }
                    // A completed while away; a remote Turn B started: TWO
                    // boundaries after the frozen baseline (101).
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Answer A", "timestamp": "4"],
                            ["id": "104", "role": "user", "content": "Turn B question", "timestamp": "5"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 5]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)

        // Turn A: foreground advances the ordering frontier through 103.
        let submitted = await harness.appState.submitComposer(text: "A")
        XCTAssertTrue(submitted)
        XCTAssertEqual(submitCount, 1)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "Turn A thinking."))
        XCTAssertNotNil(harness.appState.liveReasoningSegment)

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)
        XCTAssertEqual(resumeCount, 1, "Turn A's own foreground stays observational")
        XCTAssertEqual(transcriptReads, 2)

        // Second background: A completes unobserved, remote Turn B starts.
        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 2)
        XCTAssertEqual(transcriptReads, 4, "Freshness read + the attach reconcile's bounded read")
        XCTAssertEqual(
            resumeCount, 2,
            "A second user boundary after the FROZEN baseline forces the authoritative attach"
        )
        XCTAssertEqual(
            harness.appState.messages.map(\.id), ["100", "101", "102", "103", "104"],
            "Turn A completion and the remote Turn B prefix are visible"
        )
        XCTAssertNil(
            harness.appState.liveReasoningSegment,
            "The stale Turn A projection must not survive the attach"
        )
        XCTAssertEqual(
            harness.appState.streamingText, "Turn B partial answer",
            "The remote Turn B projection is authoritative"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        box.client.disconnect()
    }

    /// Local Turn A observed (frontier advanced), local Turn B submitted,
    /// then B completes while backgrounded and a remote Turn C starts: TWO
    /// boundaries after B's frozen baseline force the attach — advancing the
    /// ordering frontier does not erase the second-boundary protection.
    func testForegroundRemoteTurnCAfterLocalTurnBStillAttaches() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(
                            object: ["running": .bool(resumeCount > 1)],
                            inflight: resumeCount > 1
                                ? .object(["text": .string("Turn C partial answer")])
                                : nil
                        )
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    if transcriptReads == 2 {
                        // Turn A's twin + output while A runs.
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                                ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                                ["id": "103", "role": "assistant", "content": "Answer A", "timestamp": "4"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                        ])
                    }
                    // B completed while away; remote Turn C started: TWO
                    // boundaries after B's frozen baseline (103).
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Answer A", "timestamp": "4"],
                            ["id": "104", "role": "user", "content": "B", "timestamp": "5"],
                            ["id": "105", "role": "assistant", "content": "Answer B", "timestamp": "6"],
                            ["id": "106", "role": "user", "content": "Turn C question", "timestamp": "7"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 7]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)

        // Turn A: foreground advances the ordering frontier through 103.
        let submittedA = await harness.appState.submitComposer(text: "A")
        XCTAssertTrue(submittedA)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "A thinking."))
        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)
        XCTAssertEqual(resumeCount, 1)

        // Settle A locally, then submit Turn B.
        harness.appState.handleStreamEvent(.messageComplete(
            sessionId: active.id,
            messageId: nil,
            content: "Answer A",
            reasoning: nil
        ))
        harness.appState.handleStreamEvent(.messageStart(sessionId: active.id))
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: false))
        XCTAssertEqual(harness.appState.turnState, .idle)

        let submittedB = await harness.appState.submitComposer(text: "B")
        XCTAssertTrue(submittedB)
        XCTAssertEqual(submitCount, 2)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "B thinking."))
        XCTAssertNotNil(harness.appState.liveReasoningSegment)

        // B completes while backgrounded; a remote Turn C starts.
        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 2)
        XCTAssertEqual(transcriptReads, 4, "Freshness read + the attach reconcile's bounded read")
        XCTAssertEqual(
            resumeCount, 2,
            "Two boundaries after B's frozen baseline force the authoritative attach"
        )
        XCTAssertEqual(
            harness.appState.messages.map(\.id), ["100", "101", "102", "103", "104", "105", "106"],
            "Turn B completion and the remote Turn C prefix are visible"
        )
        XCTAssertNil(
            harness.appState.liveReasoningSegment,
            "The stale Turn B projection must not survive the attach"
        )
        XCTAssertEqual(
            harness.appState.streamingText, "Turn C partial answer",
            "The remote Turn C projection is authoritative"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        box.client.disconnect()
    }

    /// The twin can lag the read: a locally-owned first turn whose user row
    /// has NOT persisted yet (the page is still positively empty) with the
    /// runtime working stays observational — nothing new is persisted, so
    /// there is nothing to attach to.
    func testForegroundLocallyOwnedTurnTwinNotYetPersistedStaysObservational() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let emptyPage: [String: Any] = [
            "messages": [],
            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 0]
        ]
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    return .payload(emptyPage)
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertTrue(harness.appState.messages.isEmpty)

        let submitted = await harness.appState.submitComposer(text: "First question")
        XCTAssertTrue(submitted)
        XCTAssertEqual(submitCount, 1)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "Thinking."))
        let segmentBefore = harness.appState.liveReasoningSegment
        XCTAssertNotNil(segmentBefore)
        let messagesBefore = harness.appState.messages
        let resumesBeforeForeground = resumeCount

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 2)
        XCTAssertEqual(
            resumeCount, resumesBeforeForeground,
            "An empty persisted tail behind a running locally-owned turn is not evidence of anything foreign"
        )
        XCTAssertEqual(harness.appState.messages, messagesBefore)
        XCTAssertEqual(harness.appState.liveReasoningSegment, segmentBefore)
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(harness.appState.transcriptFreshnessIsStale)
        box.client.disconnect()
    }

    /// THE foreground-only lifecycle: Turn A is submitted, runs, and
    /// settles entirely while Conduit stays foregrounded — no bounded
    /// history read ever observes its durable rows. The settle records one
    /// unit of local ordering debt, and Turn B's submit reconciles it with
    /// exactly one bounded tail read BEFORE freezing B's ordering baseline.
    /// B's foreground then sees only B's own boundary and stays
    /// observational.
    func testConsecutiveLocallyOwnedTurnsWithoutIntermediateFreshnessReadStayObservational() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    if transcriptReads == 2 {
                        // The pre-send debt catch-up: Turn A's durable rows.
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                                ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                                ["id": "103", "role": "assistant", "content": "Answer A", "timestamp": "4"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                        ])
                    }
                    // Turn B's twin: exactly ONE boundary after 103.
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Answer A", "timestamp": "4"],
                            ["id": "104", "role": "user", "content": "B", "timestamp": "5"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 5]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(harness.appState.messages.map(\.id), ["100", "101"])

        // --- Turn A: runs and settles entirely in the foreground ---
        let submittedA = await harness.appState.submitComposer(text: "A")
        XCTAssertTrue(submittedA)
        XCTAssertEqual(submitCount, 1)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "A thinking."))
        harness.appState.handleStreamEvent(.messageComplete(
            sessionId: active.id,
            messageId: nil,
            content: "Answer A",
            reasoning: nil
        ))
        harness.appState.handleStreamEvent(.messageStart(sessionId: active.id))
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: false))
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertEqual(transcriptReads, 1, "No history read observed Turn A")

        // --- Turn B: the debt catch-up read fires before B freezes its
        // baseline, then B submits normally ---
        let submittedB = await harness.appState.submitComposer(text: "B")
        XCTAssertTrue(submittedB)
        XCTAssertEqual(submitCount, 2, "prompt.submit exactly once for Turn B")
        XCTAssertEqual(
            transcriptReads, 2,
            "Exactly one bounded debt catch-up read before Turn B"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "B thinking."))
        let segmentB = harness.appState.liveReasoningSegment
        XCTAssertNotNil(segmentB)
        let messagesAfterB = harness.appState.messages

        // --- Foreground during Turn B ---
        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(transcriptReads, 3)
        XCTAssertEqual(
            resumeCount, 1,
            "Turn A's persisted rows were anchored by the debt read — Turn B stays observational"
        )
        XCTAssertEqual(harness.appState.messages, messagesAfterB, "No transcript replacement")
        XCTAssertEqual(harness.appState.liveReasoningSegment, segmentB)
        XCTAssertEqual(harness.appState.turnState, .running)
        XCTAssertFalse(harness.appState.transcriptFreshnessIsStale)

        // Future Turn B deltas extend the SAME segment.
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: " More."))
        XCTAssertEqual(harness.appState.liveReasoningSegment?.id, segmentB?.id)
        box.client.disconnect()
    }

    /// Local ordering debt that is EXCEEDED by persisted history proves
    /// foreign activity: the authoritative reconcile runs before the local
    /// send, the remote turn becomes visible, and only then does the new
    /// local prompt append after it.
    func testLocalOrderingDebtExceededByRemoteTurnForcesReconcile() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                loadCatalog: { _, _ in [active] },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    // The debt read (and the recovery reconcile's own read)
                    // see MORE boundaries than the one outstanding
                    // locally-owned settled turn: remote B.
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Answer A", "timestamp": "4"],
                            ["id": "104", "role": "user", "content": "Remote B", "timestamp": "5"],
                            ["id": "105", "role": "assistant", "content": "Remote B answer", "timestamp": "6"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 6]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)

        // Turn A: foreground-only lifecycle, settles, leaves debt = 1.
        let submittedA = await harness.appState.submitComposer(text: "A")
        XCTAssertTrue(submittedA)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.messageComplete(
            sessionId: active.id,
            messageId: nil,
            content: "Answer A",
            reasoning: nil
        ))
        harness.appState.handleStreamEvent(.messageStart(sessionId: active.id))
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: false))
        XCTAssertEqual(harness.appState.turnState, .idle)

        // The next local submit: the debt read proves foreign activity.
        let submittedC = await harness.appState.submitComposer(text: "Local C")
        XCTAssertTrue(submittedC)

        XCTAssertEqual(submitCount, 2, "Turn A + one reconciled local send — no duplicates")
        XCTAssertEqual(transcriptReads, 3, "Debt read + the recovery reconcile's bounded read")
        XCTAssertEqual(
            resumeCount, 2,
            "Seed hydration + the authoritative recovery resume"
        )
        XCTAssertEqual(
            harness.appState.messages.count, 7,
            "The remote turn is visible and the local prompt appends after it"
        )
        XCTAssertEqual(harness.appState.messages.last?.role, .user)
        XCTAssertTrue(
            harness.appState.messages.last?.id.hasPrefix("local-") == true,
            "The reconciled local prompt appends last"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        box.client.disconnect()
    }

    /// An already-observed locally-owned turn (its foreground freshness read
    /// advanced the frontier through its rows) creates NO ordering debt: the
    /// next local submit performs no extra pre-send read.
    func testAlreadyObservedLocalTurnCreatesNoExtraPreSendRead() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    if transcriptReads == 2 {
                        // Turn A's foreground freshness read: twin + output.
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                                ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                                ["id": "103", "role": "assistant", "content": "Answer A", "timestamp": "4"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 4]
                        ])
                    }
                    // Turn B's twin (used only if B is backgrounded).
                    return .payload([
                        "messages": [
                            ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                            ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"],
                            ["id": "102", "role": "user", "content": "A", "timestamp": "3"],
                            ["id": "103", "role": "assistant", "content": "Answer A", "timestamp": "4"],
                            ["id": "104", "role": "user", "content": "B", "timestamp": "5"]
                        ],
                        "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 5]
                    ])
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "working"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)

        // Turn A: background + foreground observes its rows (frontier 103).
        let submittedA = await harness.appState.submitComposer(text: "A")
        XCTAssertTrue(submittedA)
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "A thinking."))
        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)
        XCTAssertEqual(resumeCount, 1)
        XCTAssertEqual(transcriptReads, 2)

        // Settle A locally; the frontier already covered its boundary.
        harness.appState.handleStreamEvent(.messageComplete(
            sessionId: active.id,
            messageId: nil,
            content: "Answer A",
            reasoning: nil
        ))
        harness.appState.handleStreamEvent(.messageStart(sessionId: active.id))
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: false))
        XCTAssertEqual(harness.appState.turnState, .idle)

        // Turn B submits with NO extra pre-send read.
        let submittedB = await harness.appState.submitComposer(text: "B")
        XCTAssertTrue(submittedB)
        XCTAssertEqual(submitCount, 2)
        XCTAssertEqual(
            transcriptReads, 2,
            "An already-observed turn must not trigger a debt catch-up read"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
        box.client.disconnect()
    }

    /// The gate's second non-proceed arm: a recovery boundary
    /// (.reconnecting here) racing the pre-send freshness read proves
    /// neither liveness nor ordering — the send is blocked, not blind-sent
    /// and not routed as a busy action.
    func testPreSendFreshnessRetryBlockedByRecoveryBoundary() async {
        let active = session("stored-a")
        var probeCount = 0
        var resumeCount = 0
        var transcriptReads = 0
        var submitCount = 0
        let parkedRead = LifecycleSuspension()
        let parkedMint = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                mintTicket: { _ in
                    await parkedMint.suspend()
                    return "ticket"
                },
                openSession: { _, sessionID, _ in
                    resumeCount += 1
                    return SessionResumeResult(
                        sessionId: sessionID,
                        messages: [],
                        snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                    )
                },
                persistedTranscript: { _, _ in
                    transcriptReads += 1
                    if transcriptReads == 1 {
                        return .payload([
                            "messages": [
                                ["id": "100", "role": "user", "content": "Earlier question", "timestamp": "1"],
                                ["id": "101", "role": "assistant", "content": "Earlier answer", "timestamp": "2"]
                            ],
                            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 2]
                        ])
                    }
                    if transcriptReads == 2 {
                        return .failed(DashboardTicketBridgeError.http(
                            status: 503,
                            detail: "temporarily unavailable"
                        ))
                    }
                    if transcriptReads == 3 {
                        await parkedRead.suspend()
                    }
                    return .failed(DashboardTicketBridgeError.http(
                        status: 503,
                        detail: "temporarily unavailable"
                    ))
                },
                refreshContext: { _, _ in },
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                verifyTransportHealth: { _ in },
                probeActiveSessions: { _ in
                    probeCount += 1
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                }
            )
        )
        let box = await installConnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        let opened = await harness.appState.openSession(active.id)
        XCTAssertTrue(opened)

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)
        XCTAssertTrue(harness.appState.transcriptFreshnessIsStale)

        let submission = Task { @MainActor in
            await harness.appState.submitComposer(text: "Follow-up")
        }
        await parkedRead.waitUntilSuspended()
        // The race: a reconnect boundary starts while the pre-send freshness
        // read is suspended and parks mid-mint in .reconnecting.
        let reconnect = Task { @MainActor in
            await harness.appState.reconnectForRetry(purpose: .automaticReturn)
        }
        await parkedMint.waitUntilSuspended()
        XCTAssertEqual(harness.appState.turnState, .reconnecting)
        parkedRead.resume()

        let submitted = await submission.value
        XCTAssertFalse(submitted, "The blocked send must not report success")

        XCTAssertEqual(submitCount, 0, "No ordinary prompt.submit past a recovery boundary")
        XCTAssertEqual(transcriptReads, 3, "No retry loop behind the blocked send")
        XCTAssertEqual(
            harness.appState.messages.map(\.id), ["100", "101"],
            "No optimistic new-turn row is appended past a recovery boundary"
        )
        XCTAssertEqual(
            harness.appState.errorMessage, "Unable to refresh this conversation. Try again."
        )
        XCTAssertEqual(harness.appState.turnState, .reconnecting)
        box.client.disconnect()
    }

    /// The busy-edge rule also covers the sibling stale-idle probe: a busy
    /// edge landing while THAT probe is suspended must route through the
    /// configured busy action instead of falling through to an ordinary
    /// new-turn prompt.submit into the now-running turn.
    func testStaleIdleProbeBusyEdgeRaceRoutesThroughBusyAction() async {
        let active = session("stored-a")
        var submitCount = 0
        var steerCount = 0
        var probeCount = 0
        let parkedProbe = LifecycleSuspension()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                sendPrompt: { _, _, _ in
                    submitCount += 1
                    return .accepted
                },
                probeActiveSessions: { _ in
                    probeCount += 1
                    await parkedProbe.suspend()
                    return [LiveSessionStatus(
                        runtimeSessionId: "runtime-a",
                        storedSessionId: "stored-a",
                        status: "idle"
                    )]
                },
                steer: { _, _, _ in
                    steerCount += 1
                }
            )
        )
        installDisconnectedClient(into: harness)
        harness.appState.sessions = [active]
        harness.appState.activeSessionId = active.id
        // The lifecycle boundary marks the local idle state stale.
        harness.appState.handleScenePhase(.background)

        let submission = Task { @MainActor in
            await harness.appState.submitComposer(text: "Follow-up")
        }
        await parkedProbe.waitUntilSuspended()
        // The race: the live busy edge lands while the stale-idle probe is
        // suspended.
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))
        XCTAssertEqual(harness.appState.turnState, .running)
        parkedProbe.resume()

        let submitted = await submission.value
        XCTAssertTrue(submitted)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(submitCount, 0, "No ordinary prompt.submit into the running turn")
        XCTAssertEqual(steerCount, 1, "The text routed through the configured busy action")
        XCTAssertTrue(
            harness.appState.messages.isEmpty,
            "No optimistic new-turn row is appended into the running turn"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
    }

    // MARK: - Harness

    private func makeHarness(
        lifecycleOperations: ChatResumeLifecycleOperations = .live
    ) -> (
        appState: AppState,
        coordinator: ChatResumeCoordinator,
        store: ChatResumeStore,
        recoverySequence: ChatResumeRecoverySequence
    ) {
        let suite = "AppStateForegroundLifecycleTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        let store = ChatResumeStore(defaults: defaults)
        let coordinator = ChatResumeCoordinator(store: store)
        let recoverySequence = ChatResumeRecoverySequence()
        // A fresh presentation cache per test: the shared singleton would let
        // one test's optimistic rows leak into another test's resume merge.
        let presentationCache = SessionPresentationCache(defaults: defaults)
        let appState = AppState(
            defaults: defaults,
            chatResumeCoordinator: coordinator,
            recoverySequence: recoverySequence,
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: lifecycleOperations,
            sessionPresentationCache: presentationCache
        )
        return (appState, coordinator, store, recoverySequence)
    }

    /// A real HermesClient whose handshake completed over a fake transport, so
    /// `isConnected` is true without any network traffic. All RPCs in these
    /// tests ride the lifecycle-operation seams.
    @discardableResult
    private func installConnectedClient(
        into harness: (
            appState: AppState,
            coordinator: ChatResumeCoordinator,
            store: ChatResumeStore,
            recoverySequence: ChatResumeRecoverySequence
        )
    ) async -> ConnectedClientBox {
        let transport = LifecycleFakeTransport()
        let socket = LifecycleFakeSocket()
        transport.nextSocket = { socket }
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        let client = HermesClient(
            connection: connection,
            profile: "default",
            transportFactory: { transport }
        )
        harness.appState.connection = connection
        harness.appState.client = client
        let connectTask = Task { try await client.connect() }
        transport.open(socket)
        addTeardownBlock { client.disconnect() }
        let box = ConnectedClientBox(
            client: client,
            socket: socket,
            transport: transport,
            connectTask: connectTask
        )
        connectedClientBox = box
        // Deterministic handshake: the caller must observe `isConnected` as
        // soon as this returns, or the ambiguous-submission path would treat
        // the transport as dead and take the reconnect route.
        try? await awaitCompletion(of: connectTask, "the fake handshake")
        return box
    }

    private func installDisconnectedClient(
        into harness: (
            appState: AppState,
            coordinator: ChatResumeCoordinator,
            store: ChatResumeStore,
            recoverySequence: ChatResumeRecoverySequence
        )
    ) {
        let connection = HermesConnection(baseUrl: "https://one.example", ticket: "ticket")
        harness.appState.connection = connection
        harness.appState.client = HermesClient(connection: connection, profile: "default")
    }

    /// Awaits the scene-activation task (the handshake already settled in
    /// `installConnectedClient`).
    private func runSceneActivation(
        _ harness: (
            appState: AppState,
            coordinator: ChatResumeCoordinator,
            store: ChatResumeStore,
            recoverySequence: ChatResumeRecoverySequence
        )
    ) async {
        if let task = harness.appState.handleScenePhase(.active) {
            await task.value
        }
    }

    private var connectedClientBox: ConnectedClientBox?

    private func flushMainActor() async {
        for _ in 0..<10 { await Task.yield() }
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

/// Holds the fake-transport client for a test so the handshake can be awaited
/// and the socket disconnected at teardown.
@MainActor
private final class ConnectedClientBox {
    let client: HermesClient
    let socket: LifecycleFakeSocket
    let transport: LifecycleFakeTransport
    let connectTask: Task<Void, Error>

    init(
        client: HermesClient,
        socket: LifecycleFakeSocket,
        transport: LifecycleFakeTransport,
        connectTask: Task<Void, Error>
    ) {
        self.client = client
        self.socket = socket
        self.transport = transport
        self.connectTask = connectTask
    }
}

private struct LifecycleSyncTimedOut: Error {
    let phase: String
}

/// Suspend/resume gate for driving an in-flight RPC to a chosen point and
/// releasing it after the test has raced a handoff against it.
@MainActor
private final class LifecycleSuspension {
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

/// Bounded wait for a spawned task to finish: a wedged phase fails the test
/// naming it instead of suspending forever.
@MainActor
private func awaitCompletion(
    of task: Task<Void, Error>,
    _ phase: String,
    timeout: TimeInterval = 10
) async throws {
    let finished = LifecycleGate()
    let watcher = Task<Void, Never>.detached(priority: .userInitiated) {
        _ = try? await task.value
        finished.signal()
    }
    defer { watcher.cancel() }
    try await finished.wait(phase, timeout: timeout)
}

/// Single-use bounded gate (mirrors the HermesClientTests helper).
private final class LifecycleGate: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var continuation: CheckedContinuation<Bool, Never>?

    func signal() {
        lock.lock()
        signalled = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: false)
    }

    func wait(
        _ phase: String,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let timedOut = await withCheckedContinuation { continuation in
            lock.lock()
            if signalled {
                lock.unlock()
                continuation.resume(returning: false)
                return
            }
            self.continuation = continuation
            lock.unlock()
            Task<Void, Never>.detached(priority: .userInitiated) { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.fireDeadline()
            }
        }
        if timedOut {
            XCTFail("Timed out after \(timeout)s waiting for \(phase)", file: file, line: line)
            throw LifecycleSyncTimedOut(phase: phase)
        }
    }

    private func fireDeadline() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let signalled = self.signalled
        lock.unlock()
        if !signalled {
            continuation?.resume(returning: true)
        }
    }
}

private final class LifecycleFakeSocket: HermesWebSocket {
    var closeCode: URLSessionWebSocketTask.CloseCode = .invalid
    private(set) var cancelled = false
    var cancelErrorsReceive = true
    private var receiveContinuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?

    func resume() {}

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        self.closeCode = closeCode
        cancelled = true
        if cancelErrorsReceive {
            receiveContinuation?.resume(throwing: URLError(.networkConnectionLost))
            receiveContinuation = nil
        }
    }

    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        completionHandler(nil)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            receiveContinuation = continuation
        }
    }
}

private final class LifecycleFakeTransport: HermesWebSocketTransport {
    var nextSocket: (() -> LifecycleFakeSocket)?
    private var openCallbacks: [ObjectIdentifier: () -> Void] = [:]
    private var earlyOpenRequests = Set<ObjectIdentifier>()

    func makeSocket(
        request: URLRequest,
        onOpen: @escaping (any HermesWebSocket) -> Void,
        onCloseBeforeOpen: @escaping (any HermesWebSocket) -> Void
    ) -> any HermesWebSocket {
        let socket = nextSocket?() ?? LifecycleFakeSocket()
        openCallbacks[ObjectIdentifier(socket)] = { onOpen(socket) }
        if earlyOpenRequests.remove(ObjectIdentifier(socket)) != nil,
           let callback = openCallbacks.removeValue(forKey: ObjectIdentifier(socket)) {
            callback()
        }
        return socket
    }

    func invalidate() {}

    /// Fire the handshake-open callback; buffered so it works whether the
    /// socket has been made yet or not.
    func open(_ socket: LifecycleFakeSocket) {
        let key = ObjectIdentifier(socket)
        if let callback = openCallbacks.removeValue(forKey: key) {
            callback()
        } else {
            earlyOpenRequests.insert(key)
        }
    }
}
