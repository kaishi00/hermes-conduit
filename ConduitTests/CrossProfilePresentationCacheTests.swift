import XCTest
@testable import Conduit

/// Regression coverage for the cross-profile presentation-cache corruption:
/// a coalesced stream flush scheduled under profile A was able to wake after
/// `switchProfile(to:)` changed the active profile and write profile A's
/// captured session ID through profile B's cache namespace. The debounce is
/// exercised through an injected suspension instead of wall-clock sleeps so
/// every interleaving below is deterministic.
@MainActor
final class CrossProfilePresentationCacheTests: XCTestCase {

    // MARK: - Fixtures

    private let outgoingTranscript = [
        ChatMessage(id: "a1", role: .assistant, content: "Outgoing answer", timestamp: "ts-a1")
    ]

    private func session(_ id: String, profile: String = "default") -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: [],
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

    /// One-shot cancellation-aware suspension used as the injected debounce
    /// sleep. `onCancel` releases the parked task so the coalesced operation
    /// observes cancellation exactly like `Task.sleep` would. Test-only
    /// type, never shared across production concurrency domains;
    /// `@unchecked Sendable` is sound because every field is guarded by
    /// `lock`.
    private final class FlushDebounceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiter: CheckedContinuation<Void, Never>?
        private var engagement: CheckedContinuation<Void, Never>?
        private var isReleased = false

        func suspend() async {
            await withCheckedContinuation { continuation in
                self.lock.lock()
                if self.isReleased {
                    self.lock.unlock()
                    continuation.resume()
                    return
                }
                self.waiter = continuation
                let pendingEngagement = self.engagement
                self.engagement = nil
                self.lock.unlock()
                pendingEngagement?.resume()
            }
        }

        func waitUntilEngaged() async {
            await withCheckedContinuation { continuation in
                self.lock.lock()
                if self.waiter != nil || self.isReleased {
                    self.lock.unlock()
                    continuation.resume()
                    return
                }
                self.engagement = continuation
                self.lock.unlock()
            }
        }

        func release() {
            lock.lock()
            isReleased = true
            let pendingWaiter = waiter
            waiter = nil
            let pendingEngagement = engagement
            engagement = nil
            lock.unlock()
            pendingWaiter?.resume()
            pendingEngagement?.resume()
        }
    }

    private func makeGatePark() -> (gate: FlushDebounceGate, park: @Sendable (Duration) async throws -> Void) {
        let gate = FlushDebounceGate()
        let park: @Sendable (Duration) async throws -> Void = { _ in
            try await withTaskCancellationHandler {
                await gate.suspend()
            } onCancel: {
                gate.release()
            }
        }
        return (gate, park)
    }

    private func makeHarness(
        lifecycleOperations: ChatResumeLifecycleOperations,
        park: @escaping @Sendable (Duration) async throws -> Void
    ) -> (
        appState: AppState,
        coordinator: ChatResumeCoordinator,
        cache: SessionPresentationCache,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suiteName = "CrossProfilePresentationCacheTests." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = ChatResumeStore(defaults: defaults)
        store.setBehavior(.continueWhereLeftOff)
        let coordinator = ChatResumeCoordinator(store: store)
        let cache = SessionPresentationCache(defaults: defaults)
        let appState = AppState(
            defaults: defaults,
            chatResumeCoordinator: coordinator,
            recoverySequence: ChatResumeRecoverySequence(),
            loadSavedConnection: false,
            clearSessionPresentationCache: {},
            chatResumeLifecycleOperations: lifecycleOperations,
            sessionPresentationCache: cache,
            presentationCacheDebounceSuspension: park
        )
        return (appState, coordinator, cache, defaults, suiteName)
    }

    private func workSessionFixtures() -> (session: SessionSummary, messages: [ChatMessage]) {
        (
            session("work-session", profile: "work"),
            [ChatMessage(id: "work-message", role: .assistant, content: "Work", timestamp: "ts-w1")]
        )
    }

    private func switchLifecycleOperations(
        workCatalog: [SessionSummary],
        openMessages: @MainActor @escaping (HermesClient) -> [ChatMessage]
    ) -> ChatResumeLifecycleOperations {
        ChatResumeLifecycleOperations(
            connectClient: { _ in },
            loadCatalog: { client, _ in
                (client.profile ?? "default") == "work" ? workCatalog : []
            },
            mintTicket: { _ in "profile-ticket" },
            openSession: { client, sessionID, _ in
                SessionResumeResult(
                    sessionId: sessionID,
                    messages: openMessages(client),
                    snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
                )
            },
            refreshContext: { _, _ in },
            loadProfiles: {},
            loadBusyInputMode: { _ in },
            loadProfileDisplayPreferences: {},
            loadSlashCommands: {}
        )
    }

    private func seedOutgoingTranscript(
        in appState: AppState,
        connection: HermesConnection,
        sessionID: String
    ) {
        appState.connection = connection
        appState.client = HermesClient(connection: connection, profile: "default")
        appState.isConnected = true
        appState.showLogin = false
        appState.sessions = [session(sessionID)]
        appState.activeSessionId = sessionID
        appState.messages = outgoingTranscript
    }

    /// Timestamp restored by the cache for a matching probe row. Empty string
    /// means "no cached entry supplied metadata" (nothing persisted); a
    /// non-empty value proves a cache entry exists carrying that timestamp.
    private func cachedTimestamp(
        of cache: SessionPresentationCache,
        profile: String,
        sessionID: String
    ) -> String {
        let probe = [
            ChatMessage(id: "a1", role: .assistant, content: "Outgoing answer", timestamp: "")
        ]
        return cache.merge(probe, profile: profile, sessionIDs: [sessionID]).first?.timestamp ?? ""
    }

    /// Persisted namespace contents as [cache-key -> message IDs] for exact
    /// namespace-level assertions. The production record shape is
    /// intentionally private; the storage version key pins this decoding.
    private func persistedCache(from defaults: UserDefaults) -> [String: [String]] {
        struct Entry: Decodable {
            struct Row: Decodable { let id: String }
            let messages: [Row]
        }
        guard let data = defaults.data(forKey: "conduit.sessionPresentation.v1"),
              let map = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return [:]
        }
        return map.mapValues { $0.messages.map(\.id) }
    }

    // MARK: - Tests

    /// The reported bug: a stream event parks a presentation-cache flush under
    /// profile A/session A, the app switches to profile B before it fires, and
    /// when the parked operation finally runs it must neither populate
    /// profile B's namespace nor lose profile A's outgoing transcript.
    func testStreamFlushAcrossProfileSwitchCannotContaminateTargetProfile() async {
        let (gate, park) = makeGatePark()
        let defaultSession = session("session-a")
        let fixtures = workSessionFixtures()
        let harness = makeHarness(
            lifecycleOperations: switchLifecycleOperations(
                workCatalog: [fixtures.session]
            ) { client in
                (client.profile ?? "default") == "work" ? fixtures.messages : []
            },
            park: park
        )
        let connection = HermesConnection(baseUrl: "https://127.0.0.1:1", ticket: "saved-ticket")
        harness.coordinator.rememberSession(.dashboard(profile: "default", sessionID: defaultSession.id), for: "default")
        harness.coordinator.rememberSession(.dashboard(profile: "work", sessionID: fixtures.session.id), for: "work")
        seedOutgoingTranscript(in: harness.appState, connection: connection, sessionID: defaultSession.id)
        harness.appState.installChatViewportSnapshotProvider(id: UUID()) {
            ChatRenderedViewportSnapshot(
                sessionKey: ChatScrollSessionKey(profile: "default", sessionID: "session-a"),
                snapshot: ChatScrollSnapshot(anchorMessageID: "default-anchor", followsLatest: true)
            )
        }

        // Step 3: a stream event belonging to session A schedules the deferred
        // presentation-cache flush; the injected scheduler parks it mid-debounce
        // before anything is persisted.
        harness.appState.handleStreamEvent(.cwdUpdate(sessionId: defaultSession.id, cwd: "/tmp/a"))
        let parkedOperation = harness.appState.presentationCacheFlushOperationForTesting
        XCTAssertNotNil(parkedOperation, "The stream event must schedule the coalesced flush")
        await gate.waitUntilEngaged()
        XCTAssertEqual(
            cachedTimestamp(of: harness.cache, profile: "default", sessionID: defaultSession.id),
            "",
            "Nothing may be persisted while the debounced flush is still parked"
        )

        // Step 4: switch to profile B before the deferred flush fires.
        await harness.appState.switchProfile(to: "work")

        XCTAssertEqual(harness.appState.activeProfile, "work")
        XCTAssertEqual(harness.appState.messages, fixtures.messages)

        // Step 5: run the old flush now that profile B is active. The parked
        // operation had cancellation delivered synchronously during the
        // switch's pre-change flush; awaiting it deterministically settles
        // whichever defensive layer applies first (cancel or profile fence).
        gate.release()
        await parkedOperation?.value

        // Step 6: profile B's cache must not hold anything keyed to A's
        // session identity. Profile B's own session row may legitimately
        // exist (its resume flushes under its own namespace), but it may
        // only contain profile B's own transcript.
        XCTAssertEqual(
            cachedTimestamp(of: harness.cache, profile: "work", sessionID: defaultSession.id),
            "",
            "A stale flush must never write profile A's transcript into profile B's namespace"
        )

        // Step 7: profile A's latest transcript survived the switch because the
        // pre-change boundary flushed synchronously while A was active.
        XCTAssertEqual(
            cachedTimestamp(of: harness.cache, profile: "default", sessionID: defaultSession.id),
            "ts-a1",
            "The outgoing profile's transcript metadata must be preserved across the switch"
        )
        // Schema-proof persistence assertions: the parked flush's captured
        // identity may never appear under work, work's own row (written by
        // its post-switch resume) holds only its own transcript, and the
        // final store contains exactly these two namespaced entries.
        let store = persistedCache(from: harness.defaults)
        XCTAssertNil(store["work|session-a"])
        for (key, ids) in store where key.hasPrefix("work|") {
            XCTAssertEqual(
                Set(ids),
                Set(["work-message"]),
                "\(key) may only hold profile B's own transcript rows, got \(ids)"
            )
        }
        XCTAssertEqual(
            Set(store.keys),
            Set(["default|session-a", "work|" + fixtures.session.id.lowercased()]),
            "Unexpected cache namespaces after the switch: \(store.keys)"
        )
    }

    /// Guard against overcorrecting: when the profile does not change, the
    /// fenced deferred flush must still land normally (stream coalescing is
    /// preserved, just identity-checked).
    func testDeferredFlushStillLandsWhenProfileUnchanged() async {
        let (gate, park) = makeGatePark()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(),
            park: park
        )
        let connection = HermesConnection(baseUrl: "https://127.0.0.1:1", ticket: "saved-ticket")
        seedOutgoingTranscript(in: harness.appState, connection: connection, sessionID: "session-a")

        harness.appState.handleStreamEvent(.cwdUpdate(sessionId: "session-a", cwd: "/tmp/a"))
        let parkedOperation = harness.appState.presentationCacheFlushOperationForTesting
        XCTAssertNotNil(parkedOperation)
        await gate.waitUntilEngaged()
        XCTAssertEqual(cachedTimestamp(of: harness.cache, profile: "default", sessionID: "session-a"), "")

        gate.release()
        await parkedOperation?.value

        XCTAssertEqual(
            cachedTimestamp(of: harness.cache, profile: "default", sessionID: "session-a"),
            "ts-a1",
            "Same-profile deferred flushes must land unchanged once the debounce elapses"
        )
    }

    /// connect(with:profile:) is a legitimate profile-switch entry point
    /// that upholds the same hard boundary as switchProfile: its forward
    /// transition flushes the outgoing transcript synchronously (cancelling
    /// the parked flush), fences anything scheduled under the old identity,
    /// and nothing from session A ever reaches work's namespace.
    func testConnectProfileChangePreservesOutgoingAndFencesStaleFlush() async {
        let (gate, park) = makeGatePark()
        let fixtures = workSessionFixtures()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                connectClient: { _ in },
                loadCatalog: { _, _ in [self.session(fixtures.session.id, profile: "work")] },
                mintTicket: { _ in "connect-ticket" },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: fixtures.messages,
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in }
            ),
            park: park
        )
        let connection = HermesConnection(baseUrl: "https://127.0.0.1:1", ticket: "saved-ticket")
        harness.coordinator.rememberSession(.dashboard(profile: "work", sessionID: fixtures.session.id), for: "work")
        seedOutgoingTranscript(in: harness.appState, connection: connection, sessionID: "session-a")

        harness.appState.handleStreamEvent(.cwdUpdate(sessionId: "session-a", cwd: "/tmp/a"))
        let parkedOperation = harness.appState.presentationCacheFlushOperationForTesting
        XCTAssertNotNil(parkedOperation)
        await gate.waitUntilEngaged()

        // Profile changes through connect; the boundary lives inside
        // setActiveProfile(_:), which no identity mutation can bypass.
        await harness.appState.connect(with: connection, profile: "work")
        XCTAssertEqual(harness.appState.activeProfile, "work")

        gate.release()
        await parkedOperation?.value

        let store = persistedCache(from: harness.defaults)
        XCTAssertNil(
            store["work|session-a"],
            "The stale task must not deposit session-A presentation data into the work namespace"
        )
        // The connect boundary must also preserve the outgoing transcript
        // synchronously while default was still active.
        XCTAssertEqual(store["default|session-a"], ["a1"])
        XCTAssertEqual(
            cachedTimestamp(of: harness.cache, profile: "default", sessionID: "session-a"),
            "ts-a1",
            "The outgoing profile's transcript metadata must survive a connect-driven switch"
        )
    }

    /// While the profile switched to connects, the outgoing profile's
    /// transcript is gone: it used to show under the new chat's title for the
    /// whole switch (#1442). The new chat's own transcript replaces it.
    func testTheOutgoingTranscriptLeavesWhenTheProfileChangesOver() async {
        let fixtures = workSessionFixtures()
        final class Observed {
            weak var appState: AppState?
            var whileConnecting: (profile: String, messages: [ChatMessage])?
        }
        let observed = Observed()
        var operations = switchLifecycleOperations(workCatalog: [fixtures.session]) { client in
            (client.profile ?? "default") == "work" ? fixtures.messages : []
        }
        operations.connectClient = { _ in
            guard let appState = observed.appState else { return }
            observed.whileConnecting = (appState.activeProfile, appState.messages)
        }
        let harness = makeHarness(lifecycleOperations: operations) { _ in }
        observed.appState = harness.appState
        let connection = HermesConnection(baseUrl: "https://127.0.0.1:1", ticket: "saved-ticket")
        harness.coordinator.rememberSession(.dashboard(profile: "default", sessionID: "session-a"), for: "default")
        harness.coordinator.rememberSession(.dashboard(profile: "work", sessionID: fixtures.session.id), for: "work")
        seedOutgoingTranscript(in: harness.appState, connection: connection, sessionID: "session-a")

        await harness.appState.switchProfile(to: "work")

        XCTAssertEqual(observed.whileConnecting?.profile, "work")
        XCTAssertEqual(observed.whileConnecting?.messages, [])
        XCTAssertEqual(harness.appState.messages, fixtures.messages)
    }

    /// The open socket isn't tied to a profile: a switch hands it to the new
    /// profile's client instead of minting a ticket and opening another,
    /// about two seconds on a slow path (#1442).
    func testAProfileSwitchKeepsTheOpenSocket() async throws {
        let fixtures = workSessionFixtures()
        final class Counts { var mints = 0; var sockets = 0 }
        let counts = Counts()
        var operations = switchLifecycleOperations(workCatalog: [fixtures.session]) { client in
            (client.profile ?? "default") == "work" ? fixtures.messages : []
        }
        operations.connectClient = nil
        operations.mintTicket = { _ in
            counts.mints += 1
            return "profile-ticket"
        }
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        transport.nextSocket = {
            counts.sockets += 1
            return socket
        }
        let harness = makeHarness(lifecycleOperations: operations) { _ in }
        let connection = HermesConnection(baseUrl: "https://127.0.0.1:1", ticket: "saved-ticket")
        harness.coordinator.rememberSession(.dashboard(profile: "default", sessionID: "session-a"), for: "default")
        harness.coordinator.rememberSession(.dashboard(profile: "work", sessionID: fixtures.session.id), for: "work")
        seedOutgoingTranscript(in: harness.appState, connection: connection, sessionID: "session-a")
        let outgoing = HermesClient(connection: connection, profile: "default", transportFactory: { transport })
        transport.open(socket)
        try await outgoing.connect()
        harness.appState.client = outgoing
        addTeardownBlock { harness.appState.client?.disconnect() }

        await harness.appState.switchProfile(to: "work")

        XCTAssertEqual(harness.appState.activeProfile, "work")
        let incoming = try XCTUnwrap(harness.appState.client)
        XCTAssertFalse(incoming === outgoing)
        XCTAssertEqual(incoming.profile, "work")
        XCTAssertTrue(incoming.isConnected)
        XCTAssertFalse(outgoing.isConnected)
        XCTAssertEqual(socket.closeCode, .invalid, "The socket stays open for the new profile")
        XCTAssertEqual(counts.sockets, 1, "No second socket is opened")
        XCTAssertEqual(counts.mints, 0, "No ticket is minted")
        XCTAssertEqual(harness.appState.messages, fixtures.messages)
    }

    /// A failed switch that already flipped the identity must fence anything
    /// scheduled mid-attempt, and rollback flushes the RESTORED previous
    /// profile's transcript under its own namespace only — never leaving
    /// partially-loaded target rows behind.
    func testFailedSwitchRollbackLeavesOnlyRestoredProfileNamespace() async {
        let (gate, park) = makeGatePark()
        let fixtures = workSessionFixtures()
        struct ForcedSwitchFailure: Error {}
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                // Fail AFTER the identity has already flipped so the
                // rollback path exercises the mid-attempt fence + restore.
                connectClient: { _ in throw ForcedSwitchFailure() },
                loadCatalog: { _, _ in [self.session(fixtures.session.id, profile: "work")] },
                mintTicket: { _ in "profile-ticket" },
                openSession: { _, sessionID, _ in
                    SessionResumeResult(
                        sessionId: sessionID,
                        messages: fixtures.messages,
                        snapshot: SessionRuntimeSnapshot(object: [:])
                    )
                },
                refreshContext: { _, _ in },
                loadBusyInputMode: { _ in }
            ),
            park: park
        )
        let connection = HermesConnection(baseUrl: "https://127.0.0.1:1", ticket: "saved-ticket")
        harness.coordinator.rememberSession(.dashboard(profile: "default", sessionID: "session-a"), for: "default")
        harness.coordinator.rememberSession(.dashboard(profile: "work", sessionID: fixtures.session.id), for: "work")
        seedOutgoingTranscript(in: harness.appState, connection: connection, sessionID: "session-a")
        harness.appState.installChatViewportSnapshotProvider(id: UUID()) {
            ChatRenderedViewportSnapshot(
                sessionKey: ChatScrollSessionKey(profile: "default", sessionID: "session-a"),
                snapshot: ChatScrollSnapshot(anchorMessageID: "default-anchor", followsLatest: true)
            )
        }

        // Parked flush under default/session-a before attempting the switch.
        harness.appState.handleStreamEvent(.cwdUpdate(sessionId: "session-a", cwd: "/tmp/a"))
        await gate.waitUntilEngaged()

        await harness.appState.switchProfile(to: "work")

        XCTAssertEqual(harness.appState.activeProfile, "default")
        XCTAssertEqual(harness.appState.messages, self.outgoingTranscript)

        gate.release()
        await Task.yield()

        // With no rollback flush and openSession never reached, nothing may
        // be persisted during or after the aborted attempt beyond the
        // pre-flip boundary write: exactly the restored profile's own
        // namespace survives.
        let store = persistedCache(from: harness.defaults)
        XCTAssertEqual(
            Set(store.keys),
            Set(["default|session-a"]),
            "A failed switch must leave only the restored profile's namespace, got \(store.keys)"
        )
        XCTAssertEqual(store["default|session-a"], ["a1"])
        for (key, ids) in store where key.hasPrefix("work|") {
            XCTAssertEqual(
                Set(ids),
                Set(["work-message"]),
                "\(key) may only hold work's own transcript rows, got \(ids)"
            )
        }
    }

    /// The epoch fence's distinguishing case: default → work → back to
    /// default while the original flush is still parked. The profile-string
    /// guard alone would green-light the write after the round trip; only
    /// the epoch check drops it. The two forward boundary flushes along the
    /// way must have landed exactly each profile's own transcript.
    func testStaleFlushIsFencedAcrossRoundTripBackToOriginProfile() async {
        let (gate, park) = makeGatePark()
        let defaultSession = session("session-a")
        let fixtures = workSessionFixtures()
        let harness = makeHarness(
            lifecycleOperations: switchLifecycleOperations(
                workCatalog: [fixtures.session]
            ) { client in
                (client.profile ?? "default") == "work" ? fixtures.messages : []
            },
            park: park
        )
        let connection = HermesConnection(baseUrl: "https://127.0.0.1:1", ticket: "saved-ticket")
        harness.coordinator.rememberSession(.dashboard(profile: "default", sessionID: defaultSession.id), for: "default")
        harness.coordinator.rememberSession(.dashboard(profile: "work", sessionID: fixtures.session.id), for: "work")
        seedOutgoingTranscript(in: harness.appState, connection: connection, sessionID: defaultSession.id)
        harness.appState.installChatViewportSnapshotProvider(id: UUID()) {
            ChatRenderedViewportSnapshot(
                sessionKey: ChatScrollSessionKey(profile: "default", sessionID: "session-a"),
                snapshot: ChatScrollSnapshot(anchorMessageID: "default-anchor", followsLatest: true)
            )
        }

        harness.appState.handleStreamEvent(.cwdUpdate(sessionId: defaultSession.id, cwd: "/tmp/a"))
        let parkedOperation = harness.appState.presentationCacheFlushOperationForTesting
        XCTAssertNotNil(parkedOperation)
        await gate.waitUntilEngaged()

        // Round trip inside the parked flush's lifetime.
        await harness.appState.switchProfile(to: "work")
        XCTAssertEqual(harness.appState.activeProfile, "work")
        await harness.appState.switchProfile(to: "default")
        XCTAssertEqual(harness.appState.activeProfile, "default")

        gate.release()
        await parkedOperation?.value

        XCTAssertNil(
            persistedCache(from: harness.defaults)["work|session-a"],
            "The round-tripped flush must stay fenced despite the matching profile string"
        )
        XCTAssertEqual(
            cachedTimestamp(of: harness.cache, profile: "default", sessionID: defaultSession.id),
            "ts-a1",
            "The original profile's transcript must survive the round trip"
        )
        let store = persistedCache(from: harness.defaults)
        for (key, ids) in store where key.hasPrefix("work|") {
            XCTAssertEqual(
                Set(ids),
                Set(["work-message"]),
                "\(key) may only hold work's own transcript rows, got \(ids)"
            )
        }
    }
}

// MARK: - Combined dashboards (multi-instance stage 3)

extension CrossProfilePresentationCacheTests {
    /// Two combined dashboards with the first one connected, over a socket
    /// that stays open until the test closes it.
    private func combinedDashboards(
        operations: ChatResumeLifecycleOperations
    ) async throws -> (appState: AppState, mac: SavedDashboard, vps: SavedDashboard, outgoing: HermesClient, socket: ClarifyFakeSocket) {
        KeychainHelper.useBackendForTesting(InMemoryKeychainBackend())
        addTeardownBlock { KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend()) }
        let harness = makeHarness(lifecycleOperations: operations) { _ in }
        let appState = harness.appState
        let mac = SavedDashboard(id: UUID(), label: "Mac", normalizedURL: "https://127.0.0.1:1", combined: true)
        let vps = SavedDashboard(id: UUID(), label: "VPS", normalizedURL: "https://127.0.0.2:1", combined: true)
        appState.savedDashboardRegistry = SavedDashboardRegistry(activeDashboardID: mac.id, dashboards: [mac, vps])
        let connection = HermesConnection(baseUrl: mac.normalizedURL, ticket: "saved-ticket")
        seedOutgoingTranscript(in: appState, connection: connection, sessionID: "session-a")
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        // The steps after a take up get an answer at once, rather than
        // waiting out their timeouts on a socket that never answers.
        socket.refusesEveryRequest = true
        transport.nextSocket = { socket }
        let outgoing = HermesClient(connection: connection, profile: "default", transportFactory: { transport })
        transport.open(socket)
        try await outgoing.connect()
        appState.client = outgoing
        appState.installDashboardTicketBridgeForTesting(DashboardTicketBridge(baseURL: mac.normalizedURL, dashboardID: mac.id))
        addTeardownBlock { @MainActor in
            appState.dropAllKeptDashboardRuntimes()
            appState.client?.disconnect()
        }
        return (appState, mac, vps, outgoing, socket)
    }

    /// A registry saved before Combine Dashboards loads with nothing
    /// combined, and one dashboard switched on alone is no group.
    func testCombinedDashboardsNeedTwoAndTodaysRegistryHasNone() throws {
        let id = UUID()
        let saved = #"{"schemaVersion":1,"activeDashboardID":"\#(id.uuidString)","dashboards":[{"id":"\#(id.uuidString)","label":"Mac","normalizedURL":"https://mac.example"}]}"#
        let registry = try JSONDecoder().decode(SavedDashboardRegistry.self, from: Data(saved.utf8))
        XCTAssertFalse(try XCTUnwrap(registry.dashboards.first).isCombined)
        XCTAssertTrue(registry.combinedGroupIDs.isEmpty)

        var two = registry
        two.dashboards.append(SavedDashboard(id: UUID(), label: "VPS", normalizedURL: "https://vps.example"))
        two.dashboards[0].combined = true
        XCTAssertTrue(two.combinedGroupIDs.isEmpty, "one alone is no group")
        two.dashboards[1].combined = true
        XCTAssertEqual(two.combinedGroupIDs, Set(two.dashboards.map(\.id)))
    }

    /// Leaving a combined dashboard keeps its socket open, and coming back
    /// takes it up again: no ticket minted, no socket opened.
    func testACombinedDashboardStaysConnectedWhileAnotherIsUsed() async throws {
        final class Counts { var connects = 0; var mints = 0 }
        let counts = Counts()
        var operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        operations.connectClient = { _ in counts.connects += 1 }
        operations.mintTicket = { _ in
            counts.mints += 1
            return "fresh-ticket"
        }
        let (appState, mac, vps, outgoing, socket) = try await combinedDashboards(operations: operations)

        await appState.switchDashboard(to: vps.id)

        XCTAssertEqual(appState.activeDashboardID, vps.id)
        XCTAssertNil(appState.client)
        XCTAssertTrue(appState.keptDashboardRuntimes[mac.id]?.client === outgoing)
        XCTAssertTrue(outgoing.isConnected)
        XCTAssertEqual(socket.closeCode, .invalid, "the kept socket stays open")

        await appState.switchDashboard(to: mac.id)

        XCTAssertEqual(appState.activeDashboardID, mac.id)
        XCTAssertTrue(appState.client === outgoing, "the kept client is taken up again")
        XCTAssertTrue(appState.isConnected)
        XCTAssertTrue(appState.keptDashboardRuntimes.isEmpty)
        XCTAssertEqual(counts.connects, 0, "no socket is opened")
        XCTAssertEqual(counts.mints, 0, "no ticket is minted")
    }

    /// A kept socket that dropped is let go, and the switch back signs in
    /// as before. Leaving the group lets a kept one go too.
    func testAKeptDashboardThatDroppedOrLeftTheGroupIsLetGo() async throws {
        let operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        let (appState, mac, vps, outgoing, _) = try await combinedDashboards(operations: operations)

        await appState.switchDashboard(to: vps.id)
        outgoing.disconnect()
        await appState.switchDashboard(to: mac.id)

        XCTAssertNil(appState.client, "nothing saved to sign in with, so no connection")
        XCTAssertTrue(appState.showLogin)
        XCTAssertTrue(appState.keptDashboardRuntimes.isEmpty)

        // Kept again from a fresh connection, then the group falls to one.
        let socket = ClarifyFakeSocket()
        let transport = ClarifyFakeTransport()
        transport.nextSocket = { socket }
        let again = HermesClient(connection: HermesConnection(baseUrl: mac.normalizedURL, ticket: "t"), profile: "default", transportFactory: { transport })
        transport.open(socket)
        try await again.connect()
        appState.client = again
        appState.connection = again.connection
        appState.installDashboardTicketBridgeForTesting(DashboardTicketBridge(baseURL: mac.normalizedURL, dashboardID: mac.id))
        let chat = session("mac-chat", profile: "atlas")
        // A list read on an earlier visit gives way to the one on screen.
        appState.combinedDashboardChats[mac.id] = CombinedDashboardChats(
            bridge: ObjectIdentifier(again), profiles: ["old"], sessions: [session("old-chat", profile: "old")], at: Date()
        )
        // So does its bots' work seeded before the visit, with none read on
        // it: no pill from before the visit stands (a wait answered on it).
        let earlier = try XCTUnwrap(BotWorkSnapshot(response: [
            "ok": true, "policy": "strict", "bot": "Atlas", "bot_chat": "botchat",
            "counts": ["working": 0, "needs_you": 1, "ready": 0, "waiting": 1], "work": [[String: Any]](),
        ], profile: "atlas"))
        appState.combinedDashboardBotWork[mac.id] = ["atlas": earlier]
        appState.keepOutgoingDashboardRuntimeIfCombined(
            mac.id, switchingTo: vps.id, roster: [], profiles: ["default", "atlas"], chats: [chat]
        )
        XCTAssertNotNil(appState.keptDashboardRuntimes[mac.id])
        // Its profiles stay on Chats' strip and its chats in All from the
        // switch on, read anew on the next pass (Eric, 2026-11-16).
        XCTAssertEqual(appState.otherCombinedDashboardProfiles(mac.id), ["default", "atlas"])
        XCTAssertEqual(appState.combinedDashboardChats[mac.id]?.sessions.map(\.id), ["mac-chat"])
        XCTAssertEqual(appState.combinedDashboardChats[mac.id]?.sessions.first?.combinedDashboardID, mac.id)
        XCTAssertEqual(appState.combinedDashboardChats[mac.id]?.at, Date.distantPast)
        XCTAssertNotNil(appState.combinedDashboardChats[mac.id]?.seededAt, "a read started before it can't overwrite it")
        XCTAssertEqual(appState.keptDashboardProfiles[mac.id]?.at, Date.distantPast, "its profiles are read anew on the next pass")
        XCTAssertNil(appState.combinedDashboardBotWork[mac.id], "work from before the visit goes")
        // Its socket dropping keeps the strip's profiles with its list.
        appState.dropKeptDashboardRuntime(mac.id, keepingLists: true)
        XCTAssertEqual(appState.otherCombinedDashboardProfiles(mac.id), ["default", "atlas"])

        appState.setDashboardCombined(vps.id, false)

        XCTAssertTrue(appState.keptDashboardRuntimes.isEmpty)
        XCTAssertFalse(again.isConnected)
        XCTAssertFalse(appState.savedDashboardRegistry.dashboard(with: vps.id)?.isCombined ?? true)
    }

    /// A client connected over a socket that stays open.
    private func openClient(_ baseURL: String) async throws -> HermesClient {
        let transport = ClarifyFakeTransport()
        let socket = ClarifyFakeSocket()
        transport.nextSocket = { socket }
        let client = HermesClient(connection: HermesConnection(baseUrl: baseURL, ticket: "t"), profile: "default", transportFactory: { transport })
        transport.open(socket)
        try await client.connect()
        // Also once it has left the kept set (a take-up hands it back).
        addTeardownBlock { @MainActor in client.disconnect() }
        return client
    }

    /// A dashboard whose edited address isn't taken up yet keeps no
    /// connection (it is to the old address), and removing a member that
    /// leaves the group at one lets the other's kept connection go.
    func testAnEditedAddressKeepsNothingAndARemovalThatEndsTheGroupLetsGo() async throws {
        let operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        let (appState, mac, vps, outgoing, _) = try await combinedDashboards(operations: operations)
        appState.connection = outgoing.connection
        var registry = appState.savedDashboardRegistry
        registry.dashboards[0].pendingURL = "https://127.0.0.9:1"
        appState.savedDashboardRegistry = registry

        appState.keepOutgoingDashboardRuntimeIfCombined(mac.id, switchingTo: vps.id, roster: [])
        XCTAssertNil(appState.keptDashboardRuntimes[mac.id], "the old address's connection isn't kept")

        registry.dashboards[0].pendingURL = nil
        appState.savedDashboardRegistry = registry
        appState.keepOutgoingDashboardRuntimeIfCombined(mac.id, switchingTo: vps.id, roster: [])
        XCTAssertNotNil(appState.keptDashboardRuntimes[mac.id])

        // Kept, then the address moves on: the switch back lets it go.
        registry.dashboards[0].normalizedURL = "https://127.0.0.9:1"
        appState.savedDashboardRegistry = registry
        XCTAssertNil(appState.takeKeptDashboardRuntime(mac.id, profile: "default"))
        XCTAssertFalse(outgoing.isConnected)

        let again = try await openClient("https://127.0.0.9:1")
        appState.client = again
        appState.connection = again.connection
        appState.installDashboardTicketBridgeForTesting(DashboardTicketBridge(baseURL: "https://127.0.0.9:1", dashboardID: mac.id))
        appState.keepOutgoingDashboardRuntimeIfCombined(mac.id, switchingTo: vps.id, roster: [])
        XCTAssertNotNil(appState.keptDashboardRuntimes[mac.id])

        appState.removeDashboard(vps.id)

        XCTAssertTrue(appState.keptDashboardRuntimes.isEmpty, "a group of one keeps nothing")
        XCTAssertFalse(again.isConnected)
    }

    /// Four combined dashboards all stay live: a switch back to the one
    /// kept longest takes it up rather than letting it go to make room.
    /// Signing out of a kept one lets it go.
    func testAtTheCapTheSwitchTargetIsTakenUpAndSignOutLetsGo() async throws {
        KeychainHelper.useBackendForTesting(InMemoryKeychainBackend())
        addTeardownBlock { KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend()) }
        let operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        let appState = makeHarness(lifecycleOperations: operations) { _ in }.appState
        let dashboards = (1...4).map {
            SavedDashboard(id: UUID(), label: "D\($0)", normalizedURL: "https://127.0.0.\($0):1", combined: true)
        }
        appState.savedDashboardRegistry = SavedDashboardRegistry(activeDashboardID: dashboards[3].id, dashboards: dashboards)
        addTeardownBlock { @MainActor in appState.dropAllKeptDashboardRuntimes() }
        var kept: [HermesClient] = []
        for (index, dashboard) in dashboards.prefix(3).enumerated() {
            let client = try await openClient(dashboard.normalizedURL)
            kept.append(client)
            appState.keep(KeptDashboardRuntime(
                client: client,
                bridge: DashboardTicketBridge(baseURL: dashboard.normalizedURL, dashboardID: dashboard.id),
                connection: client.connection,
                keptAt: Date(timeIntervalSince1970: TimeInterval(index))
            ), for: dashboard.id)
        }
        let onScreen = try await openClient(dashboards[3].normalizedURL)
        appState.client = onScreen
        appState.connection = onScreen.connection
        appState.installDashboardTicketBridgeForTesting(DashboardTicketBridge(baseURL: dashboards[3].normalizedURL, dashboardID: dashboards[3].id))

        appState.keepOutgoingDashboardRuntimeIfCombined(dashboards[3].id, switchingTo: dashboards[0].id, roster: [])

        XCTAssertEqual(appState.keptDashboardRuntimes.count, 4)
        XCTAssertTrue(appState.takeKeptDashboardRuntime(dashboards[0].id, profile: "default")?.client === kept[0], "the oldest kept is the target, and is taken up")

        appState.signOutDashboard(dashboards[1].id)

        XCTAssertNil(appState.keptDashboardRuntimes[dashboards[1].id])
        XCTAssertFalse(kept[1].isConnected)
    }
}

// MARK: - A kept socket that drops

extension CrossProfilePresentationCacheTests {
    /// Polls `condition` on the main actor, five seconds at most.
    func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A kept dashboard whose socket drops on its own (the server went
    /// away, not a release of ours) is let go at once, with no switch; its
    /// chats, bots and Pulse chip stay listed until it's back (#2634).
    func testAKeptSocketThatDropsOnItsOwnIsLetGoAtOnce() async throws {
        let operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        let (appState, mac, vps, outgoing, socket) = try await combinedDashboards(operations: operations)
        appState.connection = outgoing.connection
        appState.keepOutgoingDashboardRuntimeIfCombined(mac.id, switchingTo: vps.id, roster: [])
        let kept = try XCTUnwrap(appState.keptDashboardRuntimes[mac.id])
        let id = ObjectIdentifier(outgoing)
        appState.combinedDashboardChats[mac.id] = CombinedDashboardChats(bridge: id, profiles: ["default"], sessions: [], at: Date())
        appState.combinedDashboardBots[mac.id] = CombinedDashboardBots(client: id, bots: [], avatars: [:], at: Date())
        appState.combinedDashboardPulse[mac.id] = CombinedDashboardPulse(bridge: id, unseen: 2, at: Date())

        await waitUntil { socket.hasWaitingReceive }
        socket.cancel(with: .abnormalClosure, reason: nil)
        await waitUntil { appState.keptDashboardRuntimes[mac.id] == nil }

        XCTAssertNil(appState.keptDashboardRuntimes[mac.id], "a dead kept connection doesn't hold its place")
        XCTAssertFalse(kept.client.isConnected)
        XCTAssertNotNil(appState.combinedDashboardChats[mac.id], "its chats stay listed")
        XCTAssertNotNil(appState.combinedDashboardBots[mac.id], "its bots stay listed")
        XCTAssertEqual(appState.combinedDashboardPulse[mac.id]?.unseen, 2, "its chip stays")
    }

    /// A read sent on an earlier visit to a combined dashboard isn't this
    /// visit's, though the kept bridge is the same one.
    func testAnAnswerToAnEarlierVisitIsNotThisVisits() async throws {
        let operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        let (appState, mac, vps, _, _) = try await combinedDashboards(operations: operations)
        let earlier = try XCTUnwrap(appState.currentDashboardRuntimeOwner())
        XCTAssertTrue(appState.ownsDashboardRuntime(earlier))

        await appState.switchDashboard(to: vps.id)
        await appState.switchDashboard(to: mac.id)

        let now = try XCTUnwrap(appState.currentDashboardRuntimeOwner())
        XCTAssertTrue(now.bridge === earlier.bridge, "the kept bridge came back")
        XCTAssertFalse(appState.ownsDashboardRuntime(earlier), "but the earlier visit's reads don't land")
        XCTAssertTrue(appState.ownsDashboardRuntime(now))
    }
}

// MARK: - Every combined dashboard live (multi-instance stage 3b)

extension CrossProfilePresentationCacheTests {
    /// Waits, five seconds at most, for a quiet sign-in: its ticket
    /// bridge reads cookies off the main actor, so turns alone aren't enough.
    private func waitForKept(_ id: UUID, in appState: AppState) async {
        await waitUntil { appState.keptDashboardRuntimes[id] != nil && appState.combinedSignInsUnderWay.isEmpty }
    }

    /// Once the dashboard on screen is connected, another combined one with
    /// a saved session signs in beside it, on its own ticket and socket and
    /// on its own last profile; a switch to it then takes that up.
    func testTheOtherCombinedDashboardsConnectOnceTheOneOnScreenHas() async throws {
        final class Counts { var mints: [String] = [] }
        let counts = Counts()
        let socket = ClarifyFakeSocket()
        // Every request answered at once (refused), so the switch's reads
        // don't wait out their timeouts on a socket that never answers, nor
        // its keepalive close the kept socket meanwhile.
        socket.refusesEveryRequest = true
        let transport = ClarifyFakeTransport()
        transport.nextSocket = { socket }
        var operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        operations.mintTicket = { baseURL in
            counts.mints.append(baseURL)
            return "vps-ticket"
        }
        operations.makeTransport = { transport }
        let (appState, mac, vps, outgoing, _) = try await combinedDashboards(operations: operations)
        appState.isConnected = true
        KeychainHelper.saveConnection(HermesConnection(baseUrl: vps.normalizedURL, ticket: "spent"), dashboardID: vps.id)
        appState.rememberActiveProfile("coder", for: vps.id)
        transport.open(socket)

        appState.connectOtherCombinedDashboards()
        await waitForKept(vps.id, in: appState)

        let kept = try XCTUnwrap(appState.keptDashboardRuntimes[vps.id])
        XCTAssertEqual(counts.mints, [vps.normalizedURL], "a fresh ticket for that dashboard alone")
        XCTAssertEqual(kept.connection.ticket, "vps-ticket")
        XCTAssertEqual(kept.client.profile, "coder")
        XCTAssertTrue(kept.client.isConnected)
        XCTAssertTrue(appState.client === outgoing, "nothing on screen changes")
        XCTAssertEqual(appState.activeDashboardID, mac.id)

        appState.connectOtherCombinedDashboards()
        XCTAssertTrue(appState.combinedSignInsUnderWay.isEmpty, "one already kept doesn't sign in again")

        await appState.switchDashboard(to: vps.id)

        XCTAssertTrue(appState.client === kept.client, "the switch takes the background connection up")
        XCTAssertEqual(counts.mints.count, 1, "no second ticket")

        // A pick of another of its profiles from Mac's strip lands on that
        // profile at once, its socket handed to a client on it, never first
        // on the one it last used (Eric, 2026-11-16).
        await appState.switchDashboard(to: mac.id)
        let keptAgain = try XCTUnwrap(appState.keptDashboardRuntimes[vps.id])
        XCTAssertEqual(keptAgain.client.profile, "coder")
        let picked = await appState.switchForCombinedProfile(in: vps.id, profile: "default")
        XCTAssertTrue(picked)
        XCTAssertEqual(appState.activeProfile, "default")
        XCTAssertEqual(appState.client?.profile, "default")
        XCTAssertFalse(appState.client === keptAgain.client, "a client on the picked profile")
        XCTAssertTrue(appState.client?.isConnected ?? false, "on the kept socket")
        XCTAssertEqual(counts.mints.count, 1, "no new ticket")
    }

    /// Turning combine on signs the other dashboard in at once, not first
    /// on the next connect or a switch to it (Eric, 2026-11-16).
    func testTurningCombineOnSignsTheOtherDashboardInAtOnce() async throws {
        let socket = ClarifyFakeSocket()
        let transport = ClarifyFakeTransport()
        transport.nextSocket = { socket }
        var operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        operations.mintTicket = { _ in "vps-ticket" }
        operations.makeTransport = { transport }
        let (appState, _, vps, _, _) = try await combinedDashboards(operations: operations)
        appState.isConnected = true
        KeychainHelper.saveConnection(HermesConnection(baseUrl: vps.normalizedURL, ticket: "spent"), dashboardID: vps.id)
        transport.open(socket)
        appState.setDashboardCombined(vps.id, false)
        XCTAssertTrue(appState.keptDashboardRuntimes.isEmpty)

        appState.setDashboardCombined(vps.id, true)
        await waitForKept(vps.id, in: appState)
        XCTAssertNotNil(appState.keptDashboardRuntimes[vps.id], "signed in beside the one on screen")
    }

    /// A dashboard that needs typing, or Face ID this launch hasn't had,
    /// is left for a tap; and a sign-in that finishes after Conduit left
    /// the screen keeps nothing.
    func testACombinedDashboardThatNeedsSomeoneOrFinishesOffScreenIsNotKept() async throws {
        let socket = ClarifyFakeSocket()
        let transport = ClarifyFakeTransport()
        transport.nextSocket = { socket }
        var operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        operations.makeTransport = { transport }
        final class Box { weak var appState: AppState? }
        let box = Box()
        operations.mintTicket = { _ in
            // Conduit leaves the screen while the ticket is out.
            box.appState?.isSceneActive = false
            box.appState?.dropKeptDashboardRuntimesAfterGrace()
            return "late-ticket"
        }
        let (appState, _, vps, _, _) = try await combinedDashboards(operations: operations)
        box.appState = appState
        appState.isConnected = true

        XCTAssertFalse(appState.combinedDashboardSignsInQuietly(vps.id), "nothing saved: a tap signs in")
        KeychainHelper.saveCredentials(
            DashboardCredentials(baseURL: vps.normalizedURL, username: "eric", password: "pw", requiresFaceID: true),
            dashboardID: vps.id
        )
        appState.faceIDUnlockedThisLaunch = false
        XCTAssertFalse(appState.combinedDashboardSignsInQuietly(vps.id), "behind a Face ID unlock this launch hasn't had")
        appState.connectOtherCombinedDashboards()
        XCTAssertTrue(appState.combinedSignInsUnderWay.isEmpty)

        KeychainHelper.clearCredentials(dashboardID: vps.id)
        KeychainHelper.saveConnection(HermesConnection(baseUrl: vps.normalizedURL, ticket: "spent"), dashboardID: vps.id)
        transport.open(socket)
        appState.connectOtherCombinedDashboards()
        XCTAssertEqual(appState.combinedSignInsUnderWay, [vps.id])
        await waitUntil { appState.combinedSignInsUnderWay.isEmpty }

        XCTAssertTrue(appState.combinedSignInsUnderWay.isEmpty)
        XCTAssertNil(appState.keptDashboardRuntimes[vps.id], "finished after Conduit left the screen: let go")
    }

    /// The group connects beside a dashboard left out of it too; one with
    /// an edited address waits for its switch; and one signed out of while
    /// its ticket was out keeps and saves nothing.
    func testTheGroupConnectsBesideALeftOutDashboardButNotOneSignedOutOrMoving() async throws {
        let sockets = [ClarifyFakeSocket(), ClarifyFakeSocket()]
        final class HandedOut { var count = 0 }
        let handedOut = HandedOut()
        let transport = ClarifyFakeTransport()
        transport.nextSocket = {
            defer { handedOut.count += 1 }
            return sockets[min(handedOut.count, sockets.count - 1)]
        }
        var operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        operations.makeTransport = { transport }
        final class Box { weak var appState: AppState?; var signOut: UUID? }
        let box = Box()
        operations.mintTicket = { baseURL in
            if let id = box.signOut, let appState = box.appState,
               appState.savedDashboardRegistry.dashboard(with: id)?.normalizedURL == baseURL {
                appState.signOutDashboard(id)
            }
            return "ticket"
        }
        let (appState, mac, vps, _, _) = try await combinedDashboards(operations: operations)
        box.appState = appState
        appState.isConnected = true
        // The one on screen leaves the group; VPS and Pi make it up.
        let pi = SavedDashboard(id: UUID(), label: "Pi", normalizedURL: "https://127.0.0.3:1", combined: true)
        appState.savedDashboardRegistry.dashboards[0].combined = false
        appState.savedDashboardRegistry.dashboards.append(pi)
        XCTAssertFalse(appState.isInCombinedGroup(mac.id))
        for id in [vps.id, pi.id] {
            KeychainHelper.saveConnection(HermesConnection(baseUrl: "https://127.0.0.9:1", ticket: "spent"), dashboardID: id)
        }

        // Pi's address is being edited: it waits. VPS signs in beside Mac.
        appState.savedDashboardRegistry.dashboards[2].pendingURL = "https://127.0.0.4:1"
        sockets.forEach { transport.open($0) }
        appState.connectOtherCombinedDashboards()
        XCTAssertEqual(appState.combinedSignInsUnderWay, [vps.id], "beside a dashboard left out of the group")
        await waitForKept(vps.id, in: appState)
        XCTAssertNotNil(appState.keptDashboardRuntimes[vps.id])
        XCTAssertNil(appState.keptDashboardRuntimes[pi.id])

        // Pi's move is done; it's signed out of while its ticket is out.
        appState.savedDashboardRegistry.dashboards[2].pendingURL = nil
        box.signOut = pi.id
        appState.connectOtherCombinedDashboards()
        XCTAssertEqual(appState.combinedSignInsUnderWay, [pi.id])
        await waitUntil { appState.combinedSignInsUnderWay.isEmpty }

        XCTAssertNil(appState.keptDashboardRuntimes[pi.id], "signed out meanwhile: nothing kept")
        XCTAssertNil(KeychainHelper.loadConnection(dashboardID: pi.id), "nor saved again")

        // The call-off drops it whatever it signs in with: the re-saved
        // session stands for one present again by the time it finishes.
        box.signOut = nil
        KeychainHelper.saveConnection(HermesConnection(baseUrl: "https://127.0.0.9:1", ticket: "spent"), dashboardID: pi.id)
        appState.connectOtherCombinedDashboards()
        XCTAssertEqual(appState.combinedSignInsUnderWay, [pi.id])
        XCTAssertTrue(appState.combinedSignInsCalledOff.isEmpty)
        appState.letGoCombinedDashboard(pi.id)
        XCTAssertEqual(appState.combinedSignInsCalledOff, [pi.id])
        KeychainHelper.saveConnection(HermesConnection(baseUrl: "https://127.0.0.9:1", ticket: "spent"), dashboardID: pi.id)
        await waitUntil { appState.combinedSignInsUnderWay.isEmpty }
        XCTAssertNil(appState.keptDashboardRuntimes[pi.id], "called off: nothing kept")
        XCTAssertTrue(appState.combinedSignInsCalledOff.isEmpty)
        XCTAssertTrue(appState.combinedSignInBridges.isEmpty, "no sign-in's bridge outlives it")

        // A browser sign-in's grant goes with Sign Out too, so no later
        // pass signs it in again.
        KeychainHelper.saveNativeOAuthTokens(
            NativeOAuthTokenSet(accessToken: "access", refreshToken: "refresh", expiresAt: 4_000_000_000, provider: "self-hosted", userID: "user"),
            dashboardID: pi.id
        )
        XCTAssertTrue(appState.combinedDashboardSignsInQuietly(pi.id))
        appState.signOutDashboard(pi.id)
        XCTAssertFalse(appState.combinedDashboardSignsInQuietly(pi.id), "nothing left to sign in with")
        appState.connectOtherCombinedDashboards()
        XCTAssertTrue(appState.combinedSignInsUnderWay.isEmpty)
    }

    // MARK: Status, retries and pushes (stage 3c)

    /// The row and the menu say why a combined dashboard beside the one on
    /// screen isn't connected: one with nothing to sign in with waits for a
    /// tap; one whose server didn't answer is down and tried again until
    /// it connects; a kept one whose socket drops is down again.
    func testACombinedDashboardSaysWhyItIsntConnectedAndOneDownIsTriedAgain() async throws {
        final class Mints { var failures = 1; var count = 0; var status = 503 }
        let mints = Mints()
        let socket = ClarifyFakeSocket()
        let transport = ClarifyFakeTransport()
        transport.nextSocket = { socket }
        var operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        operations.mintTicket = { _ in
            mints.count += 1
            if mints.failures > 0 {
                mints.failures -= 1
                throw DashboardTicketBridgeError.http(status: mints.status, detail: "")
            }
            return "vps-ticket"
        }
        operations.makeTransport = { transport }
        let (appState, mac, vps, _, _) = try await combinedDashboards(operations: operations)
        appState.isConnected = true
        appState.combinedDashboardRetryBaseDelay = 0.05
        XCTAssertNil(appState.combinedDashboardStatus(mac.id), "the one on screen says nothing here")

        appState.connectOtherCombinedDashboards()
        XCTAssertEqual(appState.combinedDashboardStatus(vps.id), .signInNeeded, "nothing to sign in with")
        XCTAssertTrue(appState.combinedSignInsUnderWay.isEmpty)
        XCTAssertNil(appState.combinedDashboardRetries[vps.id], "a tap, not a retry")

        KeychainHelper.saveConnection(HermesConnection(baseUrl: vps.normalizedURL, ticket: "spent"), dashboardID: vps.id)
        transport.open(socket)
        appState.connectOtherCombinedDashboards()
        XCTAssertEqual(appState.combinedDashboardStatus(vps.id), .connecting)
        await waitForKept(vps.id, in: appState)
        XCTAssertEqual(mints.count, 2, "down once, then the retry signed it in")
        XCTAssertEqual(appState.combinedDashboardStatus(vps.id), .live)
        XCTAssertNil(appState.combinedDashboardTrouble[vps.id])
        XCTAssertNil(appState.combinedDashboardRetries[vps.id])

        appState.combinedDashboardRetryBaseDelay = 60
        await waitUntil { socket.hasWaitingReceive }
        socket.cancel(with: .abnormalClosure, reason: nil)
        await waitUntil { appState.combinedDashboardStatus(vps.id) == .down }
        XCTAssertEqual(appState.combinedDashboardStatus(vps.id), .down)
        XCTAssertEqual(appState.combinedDashboardRetries[vps.id]?.attempt, 1, "counted from one again")
        XCTAssertNotNil(appState.combinedDashboardRetries[vps.id]?.task)

        // Down past the cap: it says nothing until its turn, and its
        // backoff stands for then.
        let others: Set<UUID> = [UUID(), UUID(), UUID()]
        appState.dropKeptDashboardRuntime(vps.id)
        appState.combinedDashboardTrouble[vps.id] = .down
        appState.combinedSignInsUnderWay.formUnion(others)
        appState.connectOtherCombinedDashboards()
        XCTAssertNil(appState.combinedDashboardTrouble[vps.id], "no \"trying again\" with no retry waiting")
        XCTAssertNil(appState.combinedDashboardRetries[vps.id]?.task)
        XCTAssertEqual(appState.combinedDashboardRetries[vps.id]?.attempt, 1, "its backoff stands")
        appState.combinedSignInsUnderWay.subtract(others)

        // Its retry wakes when no pass can try it (the one on screen not
        // connected): it stops saying "trying again" with nothing waiting,
        // and its backoff stands (issue 2615).
        appState.combinedDashboardRetryBaseDelay = 0.05
        appState.isConnected = false
        appState.noteCombinedDashboardFailed(vps.id, .down)
        XCTAssertEqual(appState.combinedDashboardStatus(vps.id), .down)
        await waitUntil { appState.combinedDashboardTrouble[vps.id] == nil }
        XCTAssertNil(appState.combinedDashboardTrouble[vps.id], "no \"trying again\" with no retry waiting")
        XCTAssertNil(appState.combinedDashboardRetries[vps.id]?.task)
        XCTAssertEqual(appState.combinedDashboardRetries[vps.id]?.attempt, 2, "its backoff stands")
        appState.isConnected = true
        appState.combinedDashboardRetryBaseDelay = 60

        // A refused sign-in waits for a tap: no pass, retry or return asks again.
        mints.failures = 1
        mints.status = 401
        let before = mints.count
        appState.connectOtherCombinedDashboards(only: vps.id)
        await waitUntil { appState.combinedSignInsRefused.contains(vps.id) }
        XCTAssertEqual(appState.combinedDashboardStatus(vps.id), .signInNeeded)
        XCTAssertTrue(appState.combinedSignInsUnderWay.isEmpty)
        appState.connectOtherCombinedDashboards()
        appState.connectOtherCombinedDashboards(only: vps.id)
        XCTAssertTrue(appState.combinedSignInsUnderWay.isEmpty, "refused: not asked again")
        XCTAssertEqual(mints.count, before + 1, "asked once")
        // Opening it is the tap it waited for: the refusal goes at once.
        // The open runs to its end on a socket of its own, before the
        // assertions after it.
        let opened = ClarifyFakeSocket()
        opened.refusesEveryRequest = true
        transport.nextSocket = { opened }
        transport.open(opened)
        let open = Task { @MainActor in await appState.switchDashboard(to: vps.id) }
        await waitUntil { !appState.combinedSignInsRefused.contains(vps.id) }
        XCTAssertFalse(appState.combinedSignInsRefused.contains(vps.id), "opening lifts the refusal")
        await open.value

        appState.setDashboardCombined(vps.id, false)
        XCTAssertNil(appState.combinedDashboardStatus(vps.id))
        XCTAssertTrue(appState.combinedSignInsRefused.isEmpty, "out of the group: forgotten")
        XCTAssertNil(appState.combinedDashboardTrouble[vps.id])
        XCTAssertNil(appState.combinedDashboardRetries[vps.id], "out of the group: no retry")

        XCTAssertEqual(AppState.troubleAfterCombinedSignIn(DashboardTicketBridgeError.signInRequired), .signInNeeded)
        XCTAssertEqual(AppState.troubleAfterCombinedSignIn(AuthClientError.loginFailed(status: 401, detail: "")), .signInNeeded)
        XCTAssertEqual(AppState.troubleAfterCombinedSignIn(AuthClientError.loginFailed(status: 502, detail: "")), .down)
        XCTAssertEqual([1, 2, 3, 4, 5, 9].map { AppState.combinedDashboardRetryDelay(attempt: $0, base: 30) },
                       [30, 60, 120, 240, 300, 300], "30 s, doubling, 5 min at most")
        XCTAssertEqual(AppState.troubleAfterCombinedSignIn(DashboardTicketBridgeError.http(status: 403, detail: "")), .signInNeeded)
        XCTAssertEqual(AppState.troubleAfterCombinedSignIn(DashboardTicketBridgeError.http(status: 503, detail: "")), .down)
        XCTAssertEqual(AppState.troubleAfterCombinedSignIn(URLError(.timedOut)), .down)
    }

    /// Needs you lists the other combined dashboards' waits, read through
    /// their kept connections for every profile there, badged; a row opens
    /// by switching through the kept connection (all-live stage 4a).
    func testNeedsYouListsAKeptDashboardsWaitsAndOpensThroughIt() async throws {
        final class Counts { var connects = 0; var mints = 0; var reads: [String] = [] }
        let counts = Counts()
        var operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        operations.connectClient = { _ in counts.connects += 1 }
        operations.mintTicket = { _ in
            counts.mints += 1
            return "fresh-ticket"
        }
        let (appState, mac, vps, outgoing, _) = try await combinedDashboards(operations: operations)
        await appState.switchDashboard(to: vps.id)
        let kept = try XCTUnwrap(appState.keptDashboardRuntimes[mac.id])
        XCTAssertTrue(kept.client === outgoing)
        appState.keptDashboardJSONReader = { bridge, path in
            XCTAssertTrue(bridge === kept.bridge, "read through the kept connection")
            counts.reads.append(path)
            if path == "/api/profiles" { return ["profiles": [["name": "default"], ["name": "atlas"]]] }
            guard path.contains("profile=atlas") else { return ["waiting": []] }
            return ["waiting": [[
                "id": "w1", "kind": "approval", "session_ids": ["session-a"],
                "title": "Release prep", "summary": "rm -rf build", "at": 1_000,
            ]]]
        }

        await appState.readOtherCombinedDashboardsNeedsYou()
        let item = try XCTUnwrap(appState.needsYou.otherDashboards[mac.id]?.first)
        XCTAssertEqual(item.dashboardID, mac.id)
        XCTAssertEqual(item.profile, "atlas")
        // Its bot's pill on Bots Home's mixed grid says so, and opens it
        // (Eric, 2026-11-16: the far bots showed no status).
        func bot(_ name: String) -> BotProfile {
            BotProfile(name: name, botTitle: nil, displayName: name.capitalized, profileDescription: "", model: nil,
                       provider: nil, hasAvatar: false, isPinned: false, isHiddenByMeta: false,
                       appearanceColor: nil, canonicalSession: nil, lastActive: nil, lastPreview: nil)
        }
        XCTAssertEqual(appState.combinedBotStatus(bot("atlas"), in: mac.id), .needsYou(1))
        XCTAssertEqual(appState.combinedBotChatWaits(bot("atlas"), in: mac.id).map(\.id), [item.id])
        XCTAssertEqual(appState.combinedBotChatWaitThePillOpens(bot("atlas"), in: mac.id)?.id, item.id, "no workstream waits, so the pill opens the chat")
        XCTAssertEqual(appState.combinedBotStatus(bot("default"), in: mac.id), .idle)
        // Its work, read through the kept connection: a workstream waiting
        // adds to the pill, and the pill then opens the overview, not the
        // chat (as this dashboard's portraits).
        let needsYouReader = try XCTUnwrap(appState.keptDashboardJSONReader)
        appState.keptDashboardJSONReader = { bridge, path in
            XCTAssertTrue(bridge === kept.bridge, "read through the kept connection")
            if path == NotifierPluginStatus.path { return ["ok": true, "capabilities": [BotWorkstreamsClient.capability]] }
            return ["ok": true, "policy": "strict", "bot": "Atlas", "bot_chat": "botchat",
                    "counts": ["working": 0, "needs_you": 1, "ready": 0, "waiting": 1],
                    "workstream_sessions": ["ws-1"], "work": [[String: Any]]()]
        }
        await appState.refreshCombinedDashboardBotWork(mac.id, profile: "atlas")
        XCTAssertEqual(appState.combinedDashboardBotWork[mac.id]?["atlas"]?.needsYouCount, 1)
        XCTAssertEqual(appState.combinedBotStatus(bot("atlas"), in: mac.id), .needsYou(2), "its work's wait and its chat's")
        XCTAssertNil(appState.combinedBotChatWaitThePillOpens(bot("atlas"), in: mac.id), "a workstream waits: the overview")
        appState.combinedDashboardBotWork[mac.id] = nil
        appState.keptDashboardJSONReader = needsYouReader
        XCTAssertEqual(appState.needsYou.everyItem.map(\.id), [item.id], "the list shows it")
        XCTAssertTrue(appState.needsYou.items.isEmpty, "this dashboard's profile chips don't count it")
        XCTAssertNil(appState.needsYou.banner, "a first read shows no banner")
        XCTAssertTrue(appState.offersNeedsYouList)
        XCTAssertEqual(appState.combinedDashboardBadge(mac.id)?.letter, "M")
        XCTAssertEqual(appState.combinedDashboardBadge(mac.id)?.colorIndex, 0)
        XCTAssertEqual(appState.combinedDashboardBadge(vps.id)?.colorIndex, 1, "no two share a color")
        XCTAssertEqual(NeedsYouRow.whose(item, appState), "Mac · atlas")

        // The profiles are read once per kept connection.
        await appState.readOtherCombinedDashboardsNeedsYou()
        XCTAssertEqual(counts.reads.filter { $0 == "/api/profiles" }.count, 1)
        // Every few minutes they're read again: a profile deleted there
        // takes its rows with it.
        let read = try XCTUnwrap(appState.keptDashboardProfiles[mac.id])
        appState.keptDashboardProfiles[mac.id] = (read.bridge, read.profiles, .distantPast)
        let reader = try XCTUnwrap(appState.keptDashboardJSONReader)
        appState.keptDashboardJSONReader = { bridge, path in
            if path == "/api/profiles" { return ["profiles": ["default"]] }
            return try await reader(bridge, path)
        }
        await appState.readOtherCombinedDashboardsNeedsYou()
        XCTAssertNil(appState.needsYou.otherDashboards[mac.id], "atlas is gone there, and its wait with it")
        XCTAssertEqual(appState.keptDashboardProfiles[mac.id]?.profiles, ["default"])
        // A read again that fails keeps the last list, and its rows.
        appState.keptDashboardJSONReader = { bridge, path in
            if path == "/api/profiles" { throw URLError(.timedOut) }
            return try await reader(bridge, path)
        }
        appState.keptDashboardProfiles[mac.id] = (read.bridge, ["default"], .distantPast)
        await appState.readOtherCombinedDashboardsNeedsYou()
        XCTAssertEqual(appState.keptDashboardProfiles[mac.id]?.profiles, ["default"], "a failed read again keeps the last list")
        appState.keptDashboardJSONReader = reader
        appState.keptDashboardProfiles[mac.id] = (read.bridge, read.profiles, Date())
        await appState.readOtherCombinedDashboardsNeedsYou()
        XCTAssertEqual(appState.needsYou.otherDashboards[mac.id]?.first?.id, item.id)
        // A read again that fails while atlas still has its wait: atlas is
        // read on the last list, and its row stays.
        appState.keptDashboardProfiles[mac.id] = (read.bridge, read.profiles, .distantPast)
        appState.keptDashboardJSONReader = { bridge, path in
            if path == "/api/profiles" { throw URLError(.timedOut) }
            return try await reader(bridge, path)
        }
        let readsBefore = counts.reads.count
        await appState.readOtherCombinedDashboardsNeedsYou()
        XCTAssertTrue(counts.reads[readsBefore...].contains { $0.contains("profile=atlas") }, "atlas read on the last list")
        XCTAssertEqual(appState.needsYou.otherDashboards[mac.id]?.first?.id, item.id, "its row stays")
        appState.keptDashboardJSONReader = reader

        appState.openNeedsYou(item)
        await waitUntil { appState.activeDashboardID == mac.id && appState.client === outgoing }
        XCTAssertEqual(appState.activeDashboardID, mac.id)
        XCTAssertTrue(appState.client === outgoing, "opened through the kept connection")
        XCTAssertEqual(counts.mints, 0, "no sign-in")
        XCTAssertNil(appState.needsYou.otherDashboards[mac.id], "on screen, its waits are read as this dashboard's")
    }

    /// The Chats list shows a kept combined dashboard's newest chats, read
    /// through its kept connection, badged, with no actions of their own;
    /// a tap opens through that dashboard (all-live stage 4b).
    /// A combined dashboard just switched to: its bots keep the color they
    /// wore on the grid as another dashboard's until this one's profiles
    /// and pictures give it again, never the name's stand-in for a moment
    /// (Eric, 2026-11-16). A seed keeps a color it gave before and can't
    /// give yet.
    func testABotKeepsItsColorThroughASwitch() async throws {
        let operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        let (appState, mac, _, outgoing, _) = try await combinedDashboards(operations: operations)
        let raiden = BotProfile(name: "raiden", botTitle: nil, displayName: "Raiden", profileDescription: "", model: nil,
                                provider: nil, hasAvatar: false, isPinned: false, isHiddenByMeta: false,
                                appearanceColor: nil, canonicalSession: nil, lastActive: nil, lastPreview: nil)
        let violet = ProfileGlowRGB(red: 0.5, green: 0.2, blue: 0.9)
        let standIn = AppState.botColor(raiden, glow: nil)
        XCTAssertNil(appState.profileGlowColors()["raiden"], "this dashboard's pictures aren't in yet")
        XCTAssertEqual(appState.botColor(raiden), standIn)
        appState.combinedDashboardBots[mac.id] = CombinedDashboardBots(
            client: ObjectIdentifier(outgoing), bots: [raiden], avatars: [:], at: Date(), glows: ["raiden": violet]
        )
        XCTAssertEqual(appState.botColor(raiden), violet.color, "the color it wore as another dashboard's")
        // Once this dashboard's profiles are in, its own colors stand.
        appState.profiles = ["default", "raiden"]
        XCTAssertEqual(appState.botColor(raiden), AppState.botColor(raiden, glow: appState.profileGlowColors()["raiden"]))

        appState.seedCombinedDashboardBots(mac.id, from: [raiden], client: outgoing, glows: [:])
        XCTAssertEqual(appState.combinedDashboardBots[mac.id]?.glows["raiden"], violet, "kept, not the stand-in")
    }

    /// A bot's work shown from the phone's copy while Hermes is asked
    /// again is marked so (its counts may be old): Bots Home's finish
    /// ripple doesn't play for the read that follows (Eric, 2026-11-16: a
    /// far bot's open flashed another bot's ring). A read's own isn't.
    func testABotsWorkShownFromThePhonesCopyIsMarkedKept() async throws {
        let operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        let (appState, _, _, _, _) = try await combinedDashboards(operations: operations)
        appState.notifierPlugin = NotifierPluginStatus(state: .reported(
            version: NotifierPluginStatus.recommendedVersion, capabilities: [BotWorkstreamsClient.capability]))
        let answer: [String: Any] = [
            "ok": true, "policy": "strict", "bot": "Atlas", "bot_chat": "botchat",
            "counts": ["working": 0, "needs_you": 0, "ready": 2, "waiting": 0], "work": [[String: Any]](),
        ]
        let read = try XCTUnwrap(BotWorkSnapshot(response: answer, profile: "atlas"))
        XCTAssertFalse(read.isKept)
        _ = try await appState.screenAnswers(profile: "atlas").keep(BotWorkstreamsClient.keptRoute, false) { answer }

        // Hermes can't be asked here: the strip keeps the phone's copy.
        await appState.refreshBotWork(profile: "atlas")
        let shown = try XCTUnwrap(appState.botWork.snapshot("atlas"))
        XCTAssertEqual(shown.readyCount, 2)
        XCTAssertTrue(shown.isKept, "from the phone's copy")
    }

    /// Artifacts lists every combined dashboard's, All on or off (Eric,
    /// 2026-11-16): each profile of a kept dashboard, read through its kept
    /// connection, its rows named by that dashboard and apart from this
    /// one's of the same path, its files read there too.
    func testArtifactsListAKeptDashboardsArtifactsThroughIt() async throws {
        let operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        let (appState, mac, vps, _, _) = try await combinedDashboards(operations: operations)
        await appState.switchDashboard(to: vps.id)
        let kept = try XCTUnwrap(appState.keptDashboardRuntimes[mac.id])
        appState.combinedDashboardChats[mac.id] = CombinedDashboardChats(
            bridge: ObjectIdentifier(kept.bridge), profiles: ["default", "atlas"], sessions: [], at: Date()
        )
        // All off, the other dashboard is listed all the same.
        XCTAssertFalse(appState.isAllProfilesChatsOn)
        let far = appState.artifactSources(for: .profile).filter { $0.dashboardID == mac.id }
        XCTAssertEqual(far.map(\.profile), ["default", "atlas"])
        XCTAssertEqual(far.map(\.label), ["Mac", "Mac · atlas"])
        // New Bot on that dashboard checks the name against its profiles.
        XCTAssertTrue(appState.newBotSlug(for: "Atlas", on: mac.id).isTaken)
        XCTAssertFalse(appState.newBotSlug(for: "Zephyr", on: mac.id).isTaken)

        final class Paths { var read: [String] = [] }
        let paths = Paths()
        appState.keptDashboardJSONReader = { bridge, path in
            XCTAssertTrue(bridge === kept.bridge, "read through the kept connection")
            paths.read.append(path)
            return ["ok": true, "items": [[
                "kind": "image", "source": "written", "name": "chart.png", "path": "/tmp/chart.png",
                "session_id": "atlas-1", "message_id": 4, "timestamp": 1_000,
            ]]]
        }
        let source = try XCTUnwrap(far.last)
        let page = try await appState.artifactsClient(for: source).page(source)
        XCTAssertTrue(paths.read.first?.contains("profile=atlas") == true)
        let row = try XCTUnwrap(ArtifactFeed(sources: [source], pages: [page]).items.first)
        XCTAssertEqual(row.dashboardID, mac.id)
        XCTAssertEqual(row.otherProfile, "atlas")
        XCTAssertEqual(row.otherProfileLabel, "Mac · atlas")
        XCTAssertNotEqual(row.id, "/tmp/chart.png", "apart from this dashboard's file of the same path")
        // Its files are read through the kept connection, as that profile.
        let resolver = appState.keptGatewayMediaResolver(dashboardID: mac.id, profile: "atlas")
        XCTAssertTrue(resolver.connectedDashboardBridge === kept.bridge)
        XCTAssertEqual(resolver.profile, "atlas")

        // Let go, it lists and reads nothing more.
        appState.dropKeptDashboardRuntime(mac.id)
        XCTAssertTrue(appState.artifactSources(for: .profile).allSatisfy { $0.dashboardID == nil })
        XCTAssertNil(resolver.connectedDashboardBridge)
        do {
            _ = try await appState.artifactsClient(for: source).page(source)
            XCTFail("no kept connection to read through")
        } catch {}
    }

    func testTheChatsListShowsAKeptDashboardsChatsAndOpensThroughIt() async throws {
        final class Counts { var connects = 0; var mints = 0; var reads: [String] = [] }
        let counts = Counts()
        var operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        operations.connectClient = { _ in counts.connects += 1 }
        operations.mintTicket = { _ in
            counts.mints += 1
            return "fresh-ticket"
        }
        let (appState, mac, vps, outgoing, _) = try await combinedDashboards(operations: operations)
        await appState.switchDashboard(to: vps.id)
        let kept = try XCTUnwrap(appState.keptDashboardRuntimes[mac.id])
        XCTAssertEqual(appState.rememberedActiveProfile(for: mac.id) ?? "default", "default")
        appState.keptDashboardJSONReader = { bridge, path in
            XCTAssertTrue(bridge === kept.bridge, "read through the kept connection")
            if path == "/api/profiles" { return ["profiles": ["default", "atlas"]] }
            guard path.contains("/api/profiles/sessions") else { return [:] }
            counts.reads.append(path)
            if path.contains("profile=atlas") {
                return ["sessions": [
                    ["id": "atlas-1", "title": "Garden", "message_count": 3, "profile": "atlas", "last_active": 1_500],
                ]]
            }
            return ["sessions": [
                ["id": "mac-1", "title": "Release prep", "message_count": 4, "profile": "default", "last_active": 2_000],
                ["id": "mac-2", "title": "Old", "message_count": 2, "profile": "default", "last_active": 1_000],
                ["id": "mac-3", "title": "Empty", "message_count": 0, "profile": "default", "last_active": 3_000],
            ]]
        }

        // Every one of its profiles, not only the one it last used (Eric,
        // 2026-11-16: All combines all of it).
        await appState.readOtherCombinedDashboardsChats()
        XCTAssertEqual(counts.reads.count, 2)
        XCTAssertTrue(counts.reads[0].contains("profile=default"), counts.reads[0])
        XCTAssertTrue(counts.reads[1].contains("profile=atlas"), counts.reads[1])
        XCTAssertEqual(appState.combinedDashboardChats[mac.id]?.profiles, ["default", "atlas"])
        XCTAssertEqual(appState.otherCombinedDashboardsChats(excluding: ["mac-2"]).map(\.id), ["mac-1", "atlas-1"],
                       "newest first across its profiles")
        XCTAssertEqual(appState.combinedChatTarget(
            try XCTUnwrap(appState.otherCombinedDashboardsChats(excluding: []).first { $0.id == "atlas-1" }), in: mac.id
        ).profile, "atlas", "a row opens in its own profile")
        // Chats' strip: every dashboard's profiles in one row, each
        // dashboard's in Saved Dashboards order until arranged on Bots
        // Home, then in that order.
        appState.combinedBotsHomeOrder = []
        let strip = appState.combinedProfileStrip(own: ["default"])
        XCTAssertEqual(strip.map(\.id), [
            CombinedBotsHomeOrder.key(mac.id, "default"), CombinedBotsHomeOrder.key(mac.id, "atlas"),
            CombinedBotsHomeOrder.key(vps.id, "default"),
        ])
        XCTAssertEqual(strip.map(\.isOther), [true, true, false])
        appState.combinedBotsHomeOrder = [CombinedBotsHomeOrder.key(vps.id, "default"), CombinedBotsHomeOrder.key(mac.id, "atlas")]
        XCTAssertEqual(appState.combinedProfileStrip(own: ["default"]).map(\.profile), ["default", "atlas", "default"])
        XCTAssertEqual(appState.combinedProfileStrip(own: ["default"]).map(\.isOther), [false, true, true])
        // One Hermes saved twice (a bot of each has the same Bot Chat): its
        // profile shows once, as this dashboard's, at the place its copy
        // was saved at, with no Bots Home drawn (issue 2640).
        func chatBot(_ name: String, _ chat: String) -> BotProfile {
            BotProfile(name: name, botTitle: nil, displayName: name.capitalized, profileDescription: "", model: nil,
                       provider: nil, hasAvatar: false, isPinned: false, isHiddenByMeta: false, appearanceColor: nil,
                       canonicalSession: BotCanonicalSession(id: chat, resolvedID: nil, lastActive: nil, preview: nil),
                       lastActive: nil, lastPreview: nil)
        }
        let roster = appState.botRoster
        appState.botRoster = [chatBot("default", "c1")]
        appState.combinedDashboardBots[mac.id] = CombinedDashboardBots(
            client: ObjectIdentifier(outgoing), bots: [chatBot("default", "c1"), chatBot("atlas", "c2")], avatars: [:], at: Date()
        )
        appState.combinedBotsHomeOrder = [CombinedBotsHomeOrder.key(mac.id, "atlas"), CombinedBotsHomeOrder.key(mac.id, "default")]
        XCTAssertEqual(appState.combinedProfileStrip(own: ["default"]).map(\.id),
                       [CombinedBotsHomeOrder.key(mac.id, "atlas"), CombinedBotsHomeOrder.key(vps.id, "default")])
        appState.combinedDashboardBots[mac.id] = nil
        appState.botRoster = roster
        appState.combinedBotsHomeOrder = []
        let rows = appState.otherCombinedDashboardsChats(excluding: ["mac-2", "atlas-1"])
        XCTAssertEqual(rows.map(\.id), ["mac-1"], "an empty chat and one this list holds stay out")
        // The Chats list shows them only in All: one profile's list is that
        // profile's own (Eric, 2026-11-16).
        XCTAssertTrue(appState.chatListCombinedChats(excluding: []).isEmpty, "not in one profile's list")
        let profiles = appState.profiles
        appState.profiles = ["default", "work"]
        appState.allProfilesChatsSettings[dashboard: vps.id].isOn = true
        XCTAssertEqual(appState.chatListCombinedChats(excluding: ["mac-2"]).map(\.id), ["mac-1", "atlas-1"], "in All")
        // A dashboard with one profile still offers All in a group, whose
        // other dashboards' profiles it lists (#2637 review).
        appState.profiles = ["default"]
        XCTAssertTrue(appState.allProfilesChatsAvailable)
        XCTAssertEqual(appState.chatListCombinedChats(excluding: ["mac-2"]).map(\.id), ["mac-1", "atlas-1"], "in All with one profile")
        appState.allProfilesChatsSettings[dashboard: vps.id] = AllProfilesChatsSettings.Dashboard()
        appState.profiles = profiles
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(appState.combinedChatDashboard(row), mac.id)
        XCTAssertEqual(appState.combinedChatBadge(row), V2DashboardBadge(letter: "M", colorIndex: 0, name: "Mac"))
        XCTAssertEqual(appState.rowProfile(row), appState.activeProfile, "not one of this dashboard's profiles")
        XCTAssertFalse(appState.isSessionPinned(row))
        XCTAssertFalse(appState.isSavedChatRow(row))
        XCTAssertFalse(appState.isOpenChatRow(row))
        var own = row
        own.combinedDashboardID = nil
        XCTAssertNil(appState.combinedChatDashboard(own), "this dashboard's own rows carry none")

        // Read again only past a minute, or on a pull.
        await appState.readOtherCombinedDashboardsChats()
        XCTAssertEqual(counts.reads.count, 2)
        await appState.readOtherCombinedDashboardsChats(force: true)
        XCTAssertEqual(counts.reads.count, 4)
        // A failed read keeps what the list showed.
        let reader = try XCTUnwrap(appState.keptDashboardJSONReader)
        appState.keptDashboardJSONReader = { _, _ in throw URLError(.timedOut) }
        await appState.readOtherCombinedDashboardsChats(force: true)
        XCTAssertEqual(appState.otherCombinedDashboardsChats(excluding: []).map(\.id), ["mac-1", "atlas-1", "mac-2"])
        // One profile failing keeps that profile's rows, the other's fresh.
        appState.keptDashboardJSONReader = { bridge, path in
            if path.contains("profile=atlas") { throw URLError(.timedOut) }
            return try await reader(bridge, path)
        }
        await appState.readOtherCombinedDashboardsChats(force: true)
        XCTAssertEqual(appState.otherCombinedDashboardsChats(excluding: []).map(\.id), ["mac-1", "atlas-1", "mac-2"])
        appState.keptDashboardJSONReader = reader
        // A switch's seed stands against a read started before it (#2644
        // review), and gives way to one started after.
        let listed = try XCTUnwrap(appState.combinedDashboardChats[mac.id])
        appState.combinedDashboardChats[mac.id] = CombinedDashboardChats(
            bridge: listed.bridge, profiles: listed.profiles, sessions: [], at: .distantPast, seededAt: Date()
        )
        await appState.readOtherCombinedDashboardsChats(force: true, now: Date(timeIntervalSinceNow: -5))
        XCTAssertEqual(appState.combinedDashboardChats[mac.id]?.sessions.isEmpty, true, "the older read is stale")
        await appState.readOtherCombinedDashboardsChats()
        XCTAssertEqual(appState.otherCombinedDashboardsChats(excluding: []).map(\.id), ["mac-1", "atlas-1", "mac-2"])

        let target = appState.combinedChatTarget(row, in: mac.id)
        XCTAssertEqual(target.dashboardID, mac.id)
        XCTAssertEqual(target.profile, "default")
        XCTAssertEqual(target.sessionId, "mac-1")
        let open = Task { @MainActor in await appState.openNotificationTarget(target) }
        await waitUntil { appState.activeDashboardID == mac.id && appState.client === outgoing }
        open.cancel()
        XCTAssertTrue(appState.client === outgoing, "opened through the kept connection")
        XCTAssertEqual(counts.mints, 0, "no sign-in")
        XCTAssertTrue(appState.otherCombinedDashboardsChats(excluding: []).isEmpty, "on screen, its chats are this list's own")

        // A kept VPS (the fixture's VPS never signed in, so it's kept by
        // hand) lists its chats here; let go, they go.
        let vpsClient = try await openClient(vps.normalizedURL)
        appState.keep(KeptDashboardRuntime(
            client: vpsClient,
            bridge: DashboardTicketBridge(baseURL: vps.normalizedURL, dashboardID: vps.id),
            connection: vpsClient.connection,
            keptAt: Date()
        ), for: vps.id)
        appState.keptDashboardJSONReader = { _, _ in
            ["sessions": [["id": "vps-1", "title": "Deploy", "message_count": 3, "profile": "default", "last_active": 500]]]
        }
        await appState.readOtherCombinedDashboardsChats()
        XCTAssertEqual(appState.otherCombinedDashboardsChats(excluding: []).map(\.combinedDashboardID), [vps.id])
        // Its Pulse chat, as its feed names it, stays behind its Pulse.
        appState.combinedDashboardPulse[vps.id] = CombinedDashboardPulse(
            bridge: ObjectIdentifier(vpsClient), unseen: 0, homeChatID: "vps-1", profile: "default", at: Date()
        )
        XCTAssertTrue(appState.otherCombinedDashboardsChats(excluding: []).isEmpty)
        appState.combinedDashboardPulse[vps.id] = nil
        // Else as it last named it here.
        appState.pulseRememberedHomes[vps.id.uuidString] = "vps-1"
        XCTAssertTrue(appState.otherCombinedDashboardsChats(excluding: []).isEmpty, "the remembered home stays out too")
        appState.pulseRememberedHomes[vps.id.uuidString] = nil
        // One Hermes saved twice gives an id once: the first in Saved
        // Dashboards order keeps its row.
        let lab = SavedDashboard(id: UUID(), label: "Lab", normalizedURL: "https://127.0.0.3:1", combined: true)
        appState.savedDashboardRegistry.dashboards.append(lab)
        var twin = try XCTUnwrap(appState.combinedDashboardChats[vps.id]?.sessions.first)
        twin.combinedDashboardID = lab.id
        appState.combinedDashboardChats[lab.id] = CombinedDashboardChats(
            bridge: ObjectIdentifier(vpsClient), profiles: ["default"], sessions: [twin], at: Date()
        )
        XCTAssertEqual(appState.otherCombinedDashboardsChats(excluding: []).map(\.combinedDashboardID), [vps.id])
        appState.combinedDashboardChats[lab.id] = nil
        appState.letGoCombinedDashboard(vps.id)
        XCTAssertNil(appState.combinedDashboardChats[vps.id])
        XCTAssertTrue(appState.otherCombinedDashboardsChats(excluding: []).isEmpty)
    }

    /// Bots Home shows a kept combined dashboard's bots, read through its
    /// kept client, in the same grid as Bots Home's own, mixed in the
    /// group's order; a tap opens through that dashboard (all-live stage 4c).
    func testBotsHomeShowsAKeptDashboardsBotsAndOpensThroughThem() async throws {
        final class Counts { var mints = 0; var reads = 0 }
        let counts = Counts()
        var operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        operations.mintTicket = { _ in
            counts.mints += 1
            return "fresh-ticket"
        }
        let (appState, mac, vps, outgoing, _) = try await combinedDashboards(operations: operations)
        await appState.switchDashboard(to: vps.id)
        func bot(_ name: String, hidden: Bool = false) -> BotProfile {
            BotProfile(name: name, botTitle: nil, displayName: name.capitalized, profileDescription: "", model: nil,
                       provider: nil, hasAvatar: false, isPinned: false, isHiddenByMeta: hidden,
                       appearanceColor: nil, canonicalSession: nil, lastActive: nil, lastPreview: nil)
        }
        appState.keptDashboardBotRosterReader = { client in
            XCTAssertTrue(client === outgoing, "read through the kept client")
            counts.reads += 1
            return BotRosterSnapshot(bots: [bot("raiden"), bot("nahida", hidden: true)], supportsBotProtocol: true)
        }

        await appState.readOtherCombinedDashboardsBots()
        let section = try XCTUnwrap(appState.otherCombinedDashboardsBots.first)
        XCTAssertEqual(appState.otherCombinedDashboardsBots.count, 1, "only the other dashboard")
        XCTAssertEqual(section.dashboardID, mac.id)
        XCTAssertEqual(section.badge, V2DashboardBadge(letter: "M", colorIndex: 0, name: "Mac"))
        XCTAssertEqual(section.bots.map(\.name), ["raiden"], "a hidden bot stays hidden")
        // Read again only past a few minutes; a failed read keeps it.
        await appState.readOtherCombinedDashboardsBots()
        XCTAssertEqual(counts.reads, 1)
        appState.keptDashboardBotRosterReader = { _ in throw URLError(.timedOut) }
        await appState.readOtherCombinedDashboardsBots(force: true)
        XCTAssertEqual(appState.otherCombinedDashboardsBots.first?.bots.map(\.name), ["raiden"])
        // Its connection gone for a moment (it dropped by itself): its bots
        // stay listed until it's back, not coming and going (Eric,
        // 2026-11-16).
        let keptMac = try XCTUnwrap(appState.keptDashboardRuntimes.removeValue(forKey: mac.id))
        await appState.readOtherCombinedDashboardsBots(force: true)
        XCTAssertEqual(appState.otherCombinedDashboardsBots.first?.bots.map(\.name), ["raiden"], "kept through a drop")
        appState.keptDashboardRuntimes[mac.id] = keptMac

        // One grid for the group: until arranged, each dashboard's bots in
        // Saved Dashboards order; arranged, the group's order holds, mixed.
        appState.botRoster = [bot("furina")]
        appState.combinedBotsHomeOrder = []
        let own = appState.shownBotRoster
        XCTAssertEqual(appState.combinedBotsHomeItems(own: own).map(\.bot.name), ["raiden", "furina"])
        XCTAssertTrue(appState.combinedBotsHomeRostersIn, "every other dashboard's bots are in")
        appState.combinedBotsHomeOrder = [CombinedBotsHomeOrder.key(vps.id, "Furina")]
        XCTAssertEqual(appState.combinedBotsHomeItems(own: own).map(\.id),
                       ["\(vps.id.uuidString)|furina", "\(mac.id.uuidString)|raiden"])
        // A dashboard out of the group leaves the order; the others keep
        // their places.
        let gone = CombinedBotsHomeOrder.key(UUID(), "yelan")
        appState.combinedBotsHomeOrder = [CombinedBotsHomeOrder.key(vps.id, "Furina"), gone, CombinedBotsHomeOrder.key(mac.id, "raiden")]
        appState.settleCombinedBotsHomeOrder(appState.combinedBotsHomeItems(own: own).map(\.id))
        XCTAssertEqual(appState.combinedBotsHomeOrder,
                       ["\(vps.id.uuidString)|furina", "\(mac.id.uuidString)|raiden"])
        // So it does while another dashboard's roster isn't in, and when
        // the group changes, with no grid drawn at all.
        let macBots = appState.combinedDashboardBots.removeValue(forKey: mac.id)
        XCTAssertFalse(appState.combinedBotsHomeRostersIn)
        appState.combinedBotsHomeOrder = [gone, CombinedBotsHomeOrder.key(mac.id, "raiden")]
        appState.settleCombinedBotsHomeOrder([])
        XCTAssertEqual(appState.combinedBotsHomeOrder, ["\(mac.id.uuidString)|raiden"], "pruned, nothing settled in")
        appState.combinedDashboardBots[mac.id] = macBots
        appState.combinedBotsHomeOrder = [gone, "-|furina", CombinedBotsHomeOrder.key(vps.id, "furina")]
        appState.letGoKeptRuntimesOutsideTheGroup()
        XCTAssertEqual(appState.combinedBotsHomeOrder, ["-|furina", "\(vps.id.uuidString)|furina"])
        appState.combinedBotsHomeOrder = []
        // One Hermes saved at two addresses (a bot of each has the same Bot
        // Chat): its bots show once, as this dashboard's; a namesake on
        // another Hermes still shows (issue 2640).
        func chatBot(_ name: String, _ chat: String) -> BotProfile {
            BotProfile(name: name, botTitle: nil, displayName: name.capitalized, profileDescription: "", model: nil,
                       provider: nil, hasAvatar: false, isPinned: false, isHiddenByMeta: false, appearanceColor: nil,
                       canonicalSession: BotCanonicalSession(id: chat, resolvedID: nil, lastActive: nil, preview: nil),
                       lastActive: nil, lastPreview: nil)
        }
        let macRoster = appState.combinedDashboardBots[mac.id]
        appState.botRoster = [chatBot("furina", "c1"), bot("neuvillette")]
        appState.combinedDashboardBots[mac.id] = CombinedDashboardBots(
            client: ObjectIdentifier(outgoing), bots: [chatBot("Furina", "c1"), bot("neuvillette"), bot("raiden")],
            avatars: [:], at: Date()
        )
        XCTAssertEqual(appState.combinedBotsHomeItems(own: appState.shownBotRoster).map(\.id),
                       ["\(mac.id.uuidString)|raiden", "\(vps.id.uuidString)|furina", "\(vps.id.uuidString)|neuvillette"])
        appState.combinedDashboardBots[mac.id] = CombinedDashboardBots(
            client: ObjectIdentifier(outgoing), bots: [chatBot("furina", "c9"), bot("neuvillette")], avatars: [:], at: Date()
        )
        XCTAssertEqual(appState.combinedBotsHomeItems(own: appState.shownBotRoster).count, 4, "two Hermes, two of each")
        // Rosters cached at different times overlap only through a third
        // dashboard: still one Hermes, its bot shown once.
        let (a, b, c) = (UUID(), UUID(), UUID())
        func homeItem(_ dashboard: UUID, _ profile: BotProfile) -> CombinedBotsHomeItem { CombinedBotsHomeItem(dashboardID: dashboard, kind: .own(profile)) }
        let spread = AppState.oneCopyPerHermes([
            homeItem(c, bot("n")), homeItem(c, chatBot("q", "y")),
            homeItem(b, bot("n")), homeItem(b, chatBot("p", "x")), homeItem(b, chatBot("q", "y")),
            homeItem(a, bot("n")), homeItem(a, chatBot("p", "x")),
        ])
        XCTAssertEqual(spread.kept.map(\.id), [CombinedBotsHomeOrder.key(c, "n"), CombinedBotsHomeOrder.key(c, "q"), CombinedBotsHomeOrder.key(b, "p")])
        XCTAssertEqual(Set(spread.twins[CombinedBotsHomeOrder.key(c, "n")] ?? []), [CombinedBotsHomeOrder.key(b, "n"), CombinedBotsHomeOrder.key(a, "n")])
        appState.combinedDashboardBots[mac.id] = macRoster
        appState.botRoster = [bot("furina")]
        // A dashboard left while kept leaves its bots on the grid at once.
        appState.seedCombinedDashboardBots(vps.id, from: [bot("furina"), bot("nahida", hidden: true)], client: outgoing)
        XCTAssertEqual(appState.combinedDashboardBots[vps.id]?.bots.map(\.name), ["furina"])
        appState.combinedDashboardBots[vps.id] = nil

        appState.openCombinedBot(section.bots[0], in: mac.id)
        XCTAssertEqual(appState.botZoom.tapped, "raiden", "the chat grows out of the portrait")
        await waitUntil { appState.activeDashboardID == mac.id && appState.client === outgoing }
        XCTAssertTrue(appState.client === outgoing, "opened through the kept connection")
        XCTAssertEqual(counts.mints, 0, "no sign-in")
        XCTAssertTrue(appState.otherCombinedDashboardsBots.allSatisfy { $0.dashboardID != mac.id }, "on screen, its bots are Bots Home's own")
        // Signed out of, its bots go, even with no connection kept.
        appState.combinedDashboardBots[vps.id] = CombinedDashboardBots(
            client: ObjectIdentifier(outgoing), bots: [bot("yelan")], avatars: [:], at: Date()
        )
        appState.letGoCombinedDashboard(vps.id)
        XCTAssertNil(appState.combinedDashboardBots[vps.id])
    }

    /// Bots Home's mixed order across a combined group: the saved keys
    /// first, new ones after as shown, and a drop takes the target's place
    /// as on the Home Screen.
    func testCombinedBotsHomeOrderMixesAndMovesLikeTheHomeScreen() {
        let mac = UUID(), vps = UUID()
        XCTAssertEqual(CombinedBotsHomeOrder.key(mac, "Raiden"), "\(mac.uuidString)|raiden")
        XCTAssertEqual(CombinedBotsHomeOrder.key(dragged: "Furina", onScreen: vps), "\(vps.uuidString)|furina",
                       "this dashboard's portrait carries its bot's name")
        let other = CombinedBotsHomeOrder.key(mac, "raiden")
        XCTAssertEqual(CombinedBotsHomeOrder.key(dragged: other, onScreen: vps), other,
                       "another dashboard's carries its key")
        XCTAssertEqual(CombinedBotsHomeOrder.key(dragged: "data|core", onScreen: vps), "\(vps.uuidString)|data|core",
                       "a bot's name may hold a bar")
        XCTAssertFalse(CombinedBotsHomeOrder.isKey("data|core"))

        XCTAssertEqual(CombinedBotsHomeOrder.ordered(["a", "b", "c", "d"], saved: ["c", "a"]) { $0 }, ["c", "a", "b", "d"])
        XCTAssertEqual(CombinedBotsHomeOrder.settled(["c", "a"], shown: ["a", "b", "c", "d"]), ["c", "a", "b", "d"])

        let order = ["a", "b", "c", "d"]
        XCTAssertEqual(CombinedBotsHomeOrder.moving(order, "a", onto: "c"), ["b", "c", "a", "d"], "carried on: after")
        XCTAssertEqual(CombinedBotsHomeOrder.moving(order, "d", onto: "b"), ["a", "d", "b", "c"], "carried back: before")
        XCTAssertEqual(CombinedBotsHomeOrder.moving(order, "b", onto: nil), ["a", "c", "d", "b"], "at the end")
        XCTAssertEqual(CombinedBotsHomeOrder.moving(order, "b", onto: "b"), order, "on itself")

        // One Hermes saved twice: its bot shown as the other dashboard's
        // copy takes the place the first copy had (issue 2640).
        let twin = UUID()
        let saved = [CombinedBotsHomeOrder.key(mac, "n"), CombinedBotsHomeOrder.key(vps, "m")]
        XCTAssertEqual(CombinedBotsHomeOrder.handingOn(saved, twins: [CombinedBotsHomeOrder.key(twin, "n"): [CombinedBotsHomeOrder.key(mac, "n")]]),
                       [CombinedBotsHomeOrder.key(twin, "n"), CombinedBotsHomeOrder.key(vps, "m")])
        XCTAssertEqual(CombinedBotsHomeOrder.handingOn(saved, twins: [:]), saved, "a namesake on another Hermes takes no place")
        // An order holding both copies keeps one, at the earlier place, so
        // a drag moves the place the grid reads.
        XCTAssertEqual(CombinedBotsHomeOrder.handingOn(saved + [CombinedBotsHomeOrder.key(twin, "n")],
                                                       twins: [CombinedBotsHomeOrder.key(twin, "n"): [CombinedBotsHomeOrder.key(mac, "n")]]),
                       [CombinedBotsHomeOrder.key(twin, "n"), CombinedBotsHomeOrder.key(vps, "m")])
    }

    /// Pulse has a chip per combined dashboard whose Pulse answers, the
    /// other's saying how many of its cards are new; its tap shows that
    /// dashboard's Pulse, switching through the kept connection (all-live
    /// stage 4d).
    func testPulseHasAChipPerCombinedDashboardAndOneSwitchesThroughIt() async throws {
        final class Counts { var mints = 0; var reads: [String] = [] }
        let counts = Counts()
        var operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        operations.mintTicket = { _ in
            counts.mints += 1
            return "fresh-ticket"
        }
        let (appState, mac, vps, outgoing, _) = try await combinedDashboards(operations: operations)
        await appState.switchDashboard(to: vps.id)
        let kept = try XCTUnwrap(appState.keptDashboardRuntimes[mac.id])
        XCTAssertTrue(appState.pulseDashboardChips.isEmpty, "no chips until another dashboard's Pulse answers")
        appState.keptDashboardJSONReader = { bridge, path in
            XCTAssertTrue(bridge === kept.bridge, "read through the kept connection")
            counts.reads.append(path)
            return ["cards": [], "unseen": 3]
        }

        await appState.readOtherCombinedDashboardsPulse()
        XCTAssertEqual(counts.reads, ["\(PulseClient.path)/feed?proposals=1"], "suggestions counted, as the page does")
        appState.pulseUnseen = 1
        let chips = appState.pulseDashboardChips
        XCTAssertEqual(chips.map(\.dashboardID), [mac.id, vps.id], "Saved Dashboards order")
        XCTAssertEqual(chips.map(\.unseen), [3, 1])
        XCTAssertEqual(chips.map(\.isOnScreen), [false, true])
        XCTAssertEqual(chips.first?.badge.letter, "M")
        // Read again only past its age; a failed read keeps the count.
        await appState.readOtherCombinedDashboardsPulse()
        XCTAssertEqual(counts.reads.count, 1)
        appState.keptDashboardJSONReader = { _, _ in throw URLError(.timedOut) }
        await appState.readOtherCombinedDashboardsPulse(force: true)
        XCTAssertEqual(appState.pulseDashboardChips.first?.unseen, 3)

        // During a call the switch is refused, and nothing opens.
        appState.isNativeHermesCallActive = true
        appState.openCombinedPulse(mac.id)
        XCTAssertEqual(appState.activeDashboardID, vps.id, "a call keeps the dashboard")
        XCTAssertNil(appState.pulseOpenRequest)
        appState.isNativeHermesCallActive = false

        appState.openCombinedPulse(mac.id)
        await waitUntil { appState.activeDashboardID == mac.id && appState.client === outgoing }
        XCTAssertTrue(appState.client === outgoing, "switched through the kept connection")
        XCTAssertEqual(counts.mints, 0, "no sign-in")
        await waitUntil { appState.pulseOpenRequest != nil }
        XCTAssertNotNil(appState.pulseOpenRequest, "its Pulse page shows")
        XCTAssertTrue(appState.pulseDashboardChips.allSatisfy { $0.dashboardID != mac.id || $0.isOnScreen },
                      "on screen, its chip is the page's own")
    }

    /// A notification from a combined dashboard kept beside the one on
    /// screen opens through its kept connection: no ticket, no new socket.
    func testANotificationFromAKeptDashboardOpensThroughItsKeptConnection() async throws {
        final class Counts { var connects = 0; var mints = 0 }
        let counts = Counts()
        var operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        operations.connectClient = { _ in counts.connects += 1 }
        operations.mintTicket = { _ in
            counts.mints += 1
            return "fresh-ticket"
        }
        let (appState, mac, vps, outgoing, _) = try await combinedDashboards(operations: operations)
        await appState.switchDashboard(to: vps.id)
        XCTAssertTrue(appState.keptDashboardRuntimes[mac.id]?.client === outgoing)

        let open = Task { @MainActor in
            await appState.openNotificationTarget(ConduitNotificationTarget(
                profile: "default", sessionId: "session-a", dashboardID: mac.id, type: nil, isChatLink: true
            ))
        }
        await waitUntil { appState.activeDashboardID == mac.id && appState.client === outgoing }
        // What the open does after the switch isn't this test's.
        open.cancel()

        XCTAssertEqual(appState.activeDashboardID, mac.id)
        XCTAssertTrue(appState.client === outgoing, "the kept client is taken up")
        XCTAssertEqual(counts.connects, 0, "no socket is opened")
        XCTAssertEqual(counts.mints, 0, "no ticket is minted")
    }
}
