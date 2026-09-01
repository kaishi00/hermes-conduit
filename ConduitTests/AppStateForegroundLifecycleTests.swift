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
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
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
        let seedMessages = [
            ChatMessage(id: "user", role: .user, content: "Question", timestamp: "1")
        ]
        harness.appState.messages = seedMessages
        harness.appState.handleStreamEvent(.sessionBusy(sessionId: active.id, busy: true))

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(healthChecks, 1, "The foreground must verify the transport health once")
        XCTAssertEqual(probeCount, 1, "The foreground must query the authoritative runtime registry")
        XCTAssertEqual(resumeCount, 0, "A healthy foreground must never issue session.resume")
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
        harness.appState.handleStreamEvent(.reasoningDelta(sessionId: active.id, text: "Step one."))
        let segmentBefore = harness.appState.liveReasoningSegment
        XCTAssertNotNil(segmentBefore)

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(
            harness.appState.liveReasoningSegment, segmentBefore,
            "A harmless foreground cycle must not settle or reset the live reasoning segment"
        )
        XCTAssertEqual(resumeCount, 0)

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
        let seedMessages = [
            ChatMessage(id: "user", role: .user, content: "Earlier", timestamp: "1")
        ]
        harness.appState.messages = seedMessages

        harness.appState.handleScenePhase(.background)
        await runSceneActivation(harness)

        XCTAssertEqual(probeCount, 1)
        XCTAssertEqual(resumeCount, 0, "An idle healthy session must not be resumed")
        XCTAssertEqual(harness.appState.turnState, .idle)
        XCTAssertEqual(harness.appState.messages, seedMessages, "The transcript must remain stable")
        XCTAssertFalse(
            harness.appState.activeChatScrollSessionIdentity.isReconciling,
            "No reconciliation may remain open after the observational refresh"
        )
        XCTAssertFalse(harness.appState.turnStateIsStale)
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
        XCTAssertTrue(
            LiveSessionStatus(
                runtimeSessionId: "r", storedSessionId: "s", status: "starting"
            ).isRunning,
            "A turn accepted during agent build is committed busy"
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

    func testForegroundWithStartingRuntimeAdoptsObservationally() async {
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
            "A starting runtime is committed busy — foreground must not resume"
        )
        XCTAssertEqual(harness.appState.turnState, .running)
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
