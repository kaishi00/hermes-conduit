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
        groups: GroupChatLifecycleOperations = .live,
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
            groupChatOperations: groups,
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
        operations: ChatResumeLifecycleOperations,
        groups: GroupChatLifecycleOperations = .live
    ) async throws -> (appState: AppState, mac: SavedDashboard, vps: SavedDashboard, outgoing: HermesClient, socket: ClarifyFakeSocket) {
        KeychainHelper.useBackendForTesting(InMemoryKeychainBackend())
        addTeardownBlock { KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend()) }
        let harness = makeHarness(lifecycleOperations: operations, groups: groups) { _ in }
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

    /// A kept dashboard keeps what it showed, and a switch back shows it
    /// at once (no-switch plan, slice 5): its bots, chats, group rooms and
    /// Pulse badge, before its sync reads them anew. Lists read on another
    /// profile than the one it resumes stay unused.
    func testAKeptDashboardsListsShowAtOnceOnTheSwitchBack() async throws {
        // What the switch back's sync finds on screen when it reads the list.
        final class AtSync { weak var appState: AppState?; var roster: [String]?; var rooms: [String]?; var pulse: Int? }
        let atSync = AtSync()
        var operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        operations.loadCatalog = { _, _ in
            if let appState = atSync.appState, atSync.roster == nil {
                atSync.roster = appState.botRoster.map(\.name)
                atSync.rooms = appState.groupRooms.map(\.roomID)
                atSync.pulse = appState.pulseUnseen
            }
            return []
        }
        let (appState, mac, vps, _, _) = try await combinedDashboards(operations: operations)
        let raiden = BotProfile(name: "raiden", botTitle: nil, displayName: "Raiden", profileDescription: "", model: nil,
                                provider: nil, hasAvatar: false, isPinned: false, isHiddenByMeta: false,
                                appearanceColor: nil, canonicalSession: nil, lastActive: nil, lastPreview: nil)
        let chat = SessionSummary(id: "session-a", alternateIds: [], title: "Plans", model: "Hermes",
                                  updatedLabel: "now", profile: "default", source: .chat, isActive: false,
                                  isArchived: false, lineageRootId: nil)
        appState.botModePhase = .available
        appState.botRoster = [raiden]
        appState.sessions = [chat]
        let trip = GroupRoom(roomID: "trip", name: "Trip", members: [], authorityGatewayID: "gw", authorityEpoch: 1,
                             revision: 1, createdAt: 0, updatedAt: 1, disbandedAt: nil, latestSeq: nil)
        appState.groupChatPhase = .available
        appState.groupRooms = [trip]
        appState.groupRoomsListed = true
        appState.pulseUnseen = 3

        await appState.switchDashboard(to: vps.id)
        let tile = CombinedRoomTile(dashboardID: mac.id, kind: .hosted(trip))
        XCTAssertFalse(appState.listsCombinedRoomTile(tile), "another dashboard's room waits for the switch")

        let kept = try XCTUnwrap(appState.keptDashboardRuntimes[mac.id]?.lists, "what it showed is kept with it")
        XCTAssertEqual(kept.keptListsProfile, "default")
        XCTAssertEqual(kept.botRoster.map(\.name), ["raiden"])
        // It's the dashboard's own runtime while kept, its connection in it.
        let keptConnection = try XCTUnwrap(appState.keptDashboardRuntimes[mac.id])
        XCTAssertTrue(appState.runtime(for: mac.id) === kept)
        XCTAssertTrue(kept.client === keptConnection.client)
        XCTAssertTrue(kept.dashboardTicketBridge === keptConnection.bridge)
        XCTAssertTrue(kept.isConnected)
        XCTAssertTrue(appState.runtime(for: vps.id) === appState.runtimeOnScreen, "the one on screen's own")
        XCTAssertFalse(appState.runtime(for: mac.id) === appState.runtimeOnScreen)
        XCTAssertNil(appState.runtime(for: UUID()), "none for a dashboard not kept")
        XCTAssertNil(appState.runtime(for: nil), "nor for no dashboard")
        // Acting on it reads and writes its own, and leaves the screen's.
        XCTAssertEqual(kept.activeProfile, keptConnection.client.profile ?? "default", "its profile is its kept client's")
        let onWork = KeptDashboardRuntime(
            client: HermesClient(connection: keptConnection.connection, profile: "work"),
            bridge: keptConnection.bridge, connection: keptConnection.connection, keptAt: Date()
        )
        XCTAssertEqual(onWork.runtime.activeProfile, "work", "a kept client on another profile gives its runtime that one")
        XCTAssertNotEqual(appState.activeProfile, "work", "and the screen keeps its own")
        let profileOnScreen = appState.activeProfile
        var syncTask: Task<Int, Never>?
        appState.act(onRuntime: kept) {
            XCTAssertEqual(appState.botRoster.map(\.name), ["raiden"])
            XCTAssertFalse(appState.actingOnRuntimeOnScreen)
            XCTAssertEqual(appState.activeDashboardID, mac.id, "the dashboard in scope")
            XCTAssertEqual(appState.dashboardIDOnScreen, vps.id)
            appState.pulseUnseen = 5
            appState.activeProfile = "kept-profile"
            syncTask = Task { @MainActor in appState.pulseUnseen }
        }
        let fromSyncScope = await syncTask?.value
        XCTAssertEqual(fromSyncScope, 5, "a Task made in a synchronous scope carries it on")
        XCTAssertEqual(kept.activeProfile, "kept-profile", "a profile set in its scope is its own")
        XCTAssertEqual(appState.activeProfile, profileOnScreen, "and the screen's stays")
        kept.activeProfile = keptConnection.client.profile ?? "default"
        XCTAssertEqual(kept.pulseUnseen, 5)
        XCTAssertEqual(appState.pulseUnseen, 0)
        XCTAssertTrue(appState.actingOnRuntimeOnScreen)
        XCTAssertEqual(appState.activeDashboardID, vps.id)
        // Across awaits too: the scope is the task's, so main-actor work in
        // between keeps the screen's, and a Task made inside carries it on.
        final class Seen { var between: Int?; var inner: Int?; var innerDashboard: UUID? }
        let seen = Seen()
        await appState.actAcrossAwaits(onRuntime: kept) {
            let between = Task { @MainActor in seen.between = appState.pulseUnseen }
            await between.value
            XCTAssertEqual(appState.pulseUnseen, 5, "still the kept one's after the await")
            XCTAssertEqual(appState.activeDashboardID, mac.id)
            XCTAssertTrue(appState.runtime(for: vps.id) === appState.runtimeOnScreen)
            await Task { @MainActor in
                seen.inner = appState.pulseUnseen
                seen.innerDashboard = appState.activeDashboardID
            }.value
        }
        XCTAssertEqual(seen.between, 5, "a Task made inside carries the scope")
        XCTAssertEqual(seen.inner, 5)
        XCTAssertEqual(seen.innerDashboard, mac.id)
        let outside = await Task { @MainActor in appState.pulseUnseen }.value
        XCTAssertEqual(outside, 0, "work outside the scope acts on the screen's")
        XCTAssertEqual(appState.activeDashboardID, vps.id)
        // The one on screen's runs unscoped.
        await appState.actAcrossAwaits(onRuntime: appState.runtimeOnScreen) {
            XCTAssertTrue(appState.actingOnRuntimeOnScreen)
            XCTAssertEqual(appState.activeDashboardID, vps.id)
        }
        kept.pulseUnseen = 3
        XCTAssertEqual(appState.pulseUnseen, 0, "the dashboard switched to shows none of it")
        // As the other dashboard's roster would be (a first switch with no
        // stored server identity crosses no boundary, so nothing clears it).
        appState.botRoster = []

        // The switch back takes the connection up and shows them before its
        // sync reads anew; its reads, refused here, leave the roster standing.
        atSync.appState = appState
        await appState.switchDashboard(to: mac.id)
        XCTAssertEqual(atSync.roster, ["raiden"], "shown before the sync reads")
        XCTAssertEqual(atSync.rooms, ["trip"])
        XCTAssertEqual(atSync.pulse, 3)
        XCTAssertEqual(appState.activeDashboardID, mac.id)
        XCTAssertEqual(appState.botRoster.map(\.name), ["raiden"], "shown on the switch back")

        appState.botRoster = []
        appState.sessions = []
        appState.groupChatPhase = .idle
        appState.groupRooms = []
        appState.groupRoomsListed = false
        appState.pulseUnseen = 0
        XCTAssertFalse(appState.listsCombinedRoomTile(tile))
        appState.showKeptLists(of: kept)
        XCTAssertTrue(appState.listsCombinedRoomTile(tile), "its room opens without waiting for the sync")

        XCTAssertEqual(appState.botRoster.map(\.name), ["raiden"])
        XCTAssertEqual(appState.botModePhase, .available)
        XCTAssertEqual(appState.sessions.map(\.id), ["session-a"])
        XCTAssertEqual(appState.groupChatPhase, .available)
        XCTAssertTrue(appState.groupRoomsListed)
        XCTAssertEqual(appState.pulseUnseen, 3)

        appState.botRoster = []
        kept.keptListsProfile = "coder"
        appState.showKeptLists(of: kept)
        XCTAssertTrue(appState.botRoster.isEmpty, "read on another profile: unused")
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
        // The seed holds no rows for default: not read as empty, so a failed
        // read keeps what the widgets stored for it (#3117 review).
        XCTAssertEqual(appState.combinedDashboardChats[mac.id]?.unreadProfiles, ["default"])
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
        // One kept without showing has a runtime of its own, and no lists.
        XCTAssertNil(appState.keptDashboardRuntimes[dashboards[1].id]?.lists)
        XCTAssertTrue(appState.runtime(for: dashboards[1].id)?.client === kept[1])
        XCTAssertTrue(appState.takeKeptDashboardRuntime(dashboards[0].id, profile: "default")?.client === kept[0], "the oldest kept is the target, and is taken up")

        appState.signOutDashboard(dashboards[1].id)

        XCTAssertNil(appState.keptDashboardRuntimes[dashboards[1].id])
        XCTAssertFalse(kept[1].isConnected)
    }

    /// A live call keeps its dashboard (no-switch stage 2): while another
    /// combined dashboard shows, its requests, host routes, chat link and
    /// job ledger are its own dashboard's, a switch inside the group
    /// neither asks nor refuses, its connection is never let go to make
    /// room, and signing out of its dashboard ends it.
    func testALiveCallGoesOnThroughItsDashboardWhileAnotherCombinedOneShows() async throws {
        KeychainHelper.useBackendForTesting(InMemoryKeychainBackend())
        addTeardownBlock { KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend()) }
        let operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        let appState = makeHarness(lifecycleOperations: operations) { _ in }.appState
        let mac = SavedDashboard(id: UUID(), label: "Mac", normalizedURL: "https://127.0.0.1:1", combined: true)
        let vps = SavedDashboard(id: UUID(), label: "VPS", normalizedURL: "https://127.0.0.2:1", combined: true)
        let solo = SavedDashboard(id: UUID(), label: "Solo", normalizedURL: "https://127.0.0.3:1")
        let spare = SavedDashboard(id: UUID(), label: "Spare", normalizedURL: "https://127.0.0.4:1", combined: true)
        let extra = SavedDashboard(id: UUID(), label: "Extra", normalizedURL: "https://127.0.0.5:1", combined: true)
        appState.savedDashboardRegistry = SavedDashboardRegistry(
            activeDashboardID: vps.id, dashboards: [mac, vps, solo, spare, extra]
        )
        addTeardownBlock { @MainActor in appState.dropAllKeptDashboardRuntimes() }
        let callClient = try await openClient(mac.normalizedURL)
        let macBridge = DashboardTicketBridge(baseURL: mac.normalizedURL, dashboardID: mac.id)
        // Kept longest, so the cap would let it go first.
        appState.keep(KeptDashboardRuntime(
            client: callClient, bridge: macBridge, connection: callClient.connection, keptAt: .distantPast
        ), for: mac.id)
        for (index, dashboard) in [spare, extra].enumerated() {
            let client = try await openClient(dashboard.normalizedURL)
            appState.keep(KeptDashboardRuntime(
                client: client,
                bridge: DashboardTicketBridge(baseURL: dashboard.normalizedURL, dashboardID: dashboard.id),
                connection: client.connection,
                keptAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
            ), for: dashboard.id)
        }
        let onScreen = try await openClient(vps.normalizedURL)
        let vpsBridge = DashboardTicketBridge(baseURL: vps.normalizedURL, dashboardID: vps.id)
        appState.client = onScreen
        appState.connection = onScreen.connection
        appState.installDashboardTicketBridgeForTesting(vpsBridge)
        appState.isConnected = true

        // A GPT-Live call started on Mac, minimised, with VPS on screen.
        appState.liveCallProfile = "default"
        appState.liveCallDashboardID = mac.id
        appState.minimisedLiveVoice = .gptLive

        XCTAssertEqual(appState.callDashboardOffScreen, mac.id)
        XCTAssertTrue(appState.callBridge === macBridge, "its host routes go to Mac")
        XCTAssertEqual(appState.callConnection?.baseUrl, mac.normalizedURL)
        let requests = try await appState.clientForVoiceRequest()
        XCTAssertTrue(requests === callClient, "its requests go through Mac's own connection")
        XCTAssertEqual(appState.callProfileOffScreen, "default", "it names its profile: Mac's client may be on another")
        XCTAssertTrue(appState.voiceJobLedgerKey.contains(mac.id.uuidString), "its jobs' ledger is Mac's")
        XCTAssertEqual(
            appState.callChatLink(.session(id: "chat-1")),
            .session(id: "chat-1", profile: "default", dashboard: mac.id.uuidString),
            "its chat's link opens on Mac"
        )
        XCTAssertEqual(appState.liveCallBarSubject(thread: "Trip"), "\(appState.defaultProfileName) · Mac · Trip")
        // The names are Mac's own, not the screen's: its main profile's
        // rename, and a device name while its gateway keeps no bot looks.
        appState.profileAppearanceStore.saveDefaultName("Atlas", dashboardID: mac.id)
        XCTAssertEqual(appState.liveCallBarSubject(thread: "Trip"), "Atlas · Mac · Trip")
        XCTAssertNotEqual(appState.defaultProfileName, "Atlas", "VPS's main profile keeps its own name")
        appState.profileAppearanceStore.saveDeviceName("Scout", for: "work", dashboardID: mac.id)
        appState.liveCallProfile = "work"
        XCTAssertEqual(appState.liveCallBarSubject(thread: "Trip"), "Scout · Mac · Trip")
        appState.liveCallProfile = "default"

        // A switch inside the group goes on; one outside it asks first.
        XCTAssertTrue(appState.callSurvivesDashboardSwitch(to: mac.id))
        XCTAssertTrue(appState.callSurvivesDashboardSwitch(to: spare.id))
        XCTAssertFalse(appState.refusesCombinedSwitchDuringCall(to: spare.id))
        XCTAssertTrue(appState.isCallEndingDashboardSwitch(to: solo.id))
        XCTAssertTrue(appState.callSurvivesProfileSwitch, "a profile switch on VPS touches nothing of Mac's call")
        XCTAssertFalse(appState.isCallEndingProfileSwitch)
        var asked: CallEndingSwitch?
        var switched = false
        appState.switchEndingCall(to: "Mac", dashboard: mac.id, pending: &asked) { switched = true }
        XCTAssertTrue(switched)
        XCTAssertNil(asked)
        appState.switchEndingCall(to: "Solo", dashboard: solo.id, pending: &asked) { XCTFail("Solo isn't combined: the call would end") }
        XCTAssertNotNil(asked)
        // Classic voice can't go on: it covers the screen it talks through.
        appState.showVoiceSheet = true
        XCTAssertTrue(appState.isCallEndingDashboardSwitch(to: mac.id))
        appState.showVoiceSheet = false

        // Past the cap, VPS kept lets the oldest go: Spare, never the
        // call's Mac, kept longer still.
        appState.keepOutgoingDashboardRuntimeIfCombined(vps.id, switchingTo: solo.id, roster: [])
        XCTAssertNotNil(appState.keptDashboardRuntimes[mac.id], "the call's dashboard stays")
        XCTAssertNil(appState.keptDashboardRuntimes[spare.id])
        XCTAssertNotNil(appState.keptDashboardRuntimes[extra.id])
        XCTAssertTrue(callClient.isConnected)

        // The switch's speech boundary keeps a call that goes on across it.
        appState.retireSpeechOperationsForServerReplacement(
            previousIdentity: vps.id.uuidString, identity: solo.id.uuidString, keepingLiveCall: true
        )
        XCTAssertEqual(appState.minimisedLiveVoice, .gptLive)
        XCTAssertEqual(appState.liveCallDashboardID, mac.id)

        // Mac's socket drops: the call goes on, and switching back to Mac
        // still keeps it (the switch signs in again); away from it, nothing
        // would carry it.
        var macPreferences = VoiceProfilePreferences()
        macPreferences.outputMuted = true
        let macRuntime = try XCTUnwrap(appState.runtime(for: mac.id))
        appState.act(onRuntime: macRuntime) { appState.saveVoiceProfilePreferences(macPreferences, profile: "default") }
        appState.notifierPlugin.state = .reported(version: "9.0.0", capabilities: ["voice-tools"])
        appState.dropKeptDashboardRuntime(mac.id, keepingLists: true)
        // Meanwhile it reads Mac's settings by its address, and no plugin
        // report: never VPS's.
        XCTAssertEqual(appState.loadCallVoicePreferences(profile: "default"), macPreferences)
        XCTAssertEqual(appState.onCallRuntime { appState.notifierPlugin.state }, .unknown)
        XCTAssertNil(appState.callBridge)
        XCTAssertTrue(appState.callSurvivesDashboardSwitch(to: mac.id))
        XCTAssertFalse(appState.callSurvivesDashboardSwitch(to: extra.id))

        // Signing out of Mac ends the call: nothing carries it now.
        appState.signOutDashboard(mac.id)
        XCTAssertFalse(appState.isLiveCallUp)
        XCTAssertNil(appState.liveCallDashboardID)
        XCTAssertFalse(callClient.isConnected)
        XCTAssertNil(appState.callDashboardOffScreen)
    }
}

// MARK: - A call started on another combined dashboard

extension CrossProfilePresentationCacheTests {
    /// A call starts on another combined dashboard's bot with no switch:
    /// its start runs on that dashboard's runtime, and the call holds that
    /// dashboard from then on (no-switch stage 2, calls and voice).
    func testACallStartsOnAnotherCombinedDashboardWithoutASwitch() async throws {
        KeychainHelper.useBackendForTesting(InMemoryKeychainBackend())
        addTeardownBlock { KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend()) }
        let operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        let appState = makeHarness(lifecycleOperations: operations) { _ in }.appState
        let mac = SavedDashboard(id: UUID(), label: "Mac", normalizedURL: "https://127.0.0.1:1", combined: true)
        let vps = SavedDashboard(id: UUID(), label: "VPS", normalizedURL: "https://127.0.0.2:1", combined: true)
        let solo = SavedDashboard(id: UUID(), label: "Solo", normalizedURL: "https://127.0.0.3:1")
        appState.savedDashboardRegistry = SavedDashboardRegistry(activeDashboardID: vps.id, dashboards: [mac, vps, solo])
        addTeardownBlock { @MainActor in appState.dropAllKeptDashboardRuntimes() }
        let macClient = try await openClient(mac.normalizedURL)
        let macBridge = DashboardTicketBridge(baseURL: mac.normalizedURL, dashboardID: mac.id)
        appState.keep(KeptDashboardRuntime(
            client: macClient, bridge: macBridge, connection: macClient.connection, keptAt: Date()
        ), for: mac.id)
        let onScreen = try await openClient(vps.normalizedURL)
        appState.client = onScreen
        appState.connection = onScreen.connection
        appState.installDashboardTicketBridgeForTesting(DashboardTicketBridge(baseURL: vps.normalizedURL, dashboardID: vps.id))
        appState.isConnected = true

        // The dashboard on screen starts as usual; one outside the group
        // isn't kept, so its start switches first.
        let onVPS: Bool? = await appState.onFarCallDashboard(vps.id, profile: "default") { true }
        XCTAssertNil(onVPS)
        let onSolo: Bool? = await appState.onFarCallDashboard(solo.id, profile: "default") { true }
        XCTAssertNil(onSolo)
        // Mac's main profile talks in Classic voice there, which needs the
        // chat on screen: the phone's start leaves it to a switch.
        XCTAssertFalse(appState.openLiveCallOnFarDashboard(mac.id, profile: "default"))
        XCTAssertNil(appState.liveCallDashboardID)
        // So does another profile there: the refusal leaves Mac's kept
        // socket on its own profile, its kept chats untouched.
        XCTAssertFalse(appState.openLiveCallOnFarDashboard(mac.id, profile: "work"))
        XCTAssertTrue(appState.keptDashboardRuntimes[mac.id]?.client === macClient, "nothing handed over")

        // A start on Mac reads Mac's settings and begins a call holding Mac.
        var macPreferences = VoiceProfilePreferences()
        macPreferences.outputMuted = true
        let macRuntime = try XCTUnwrap(appState.runtime(for: mac.id))
        appState.act(onRuntime: macRuntime) { appState.saveVoiceProfilePreferences(macPreferences, profile: "default") }
        let started: Bool? = await appState.onFarCallDashboard(mac.id, profile: "default") {
            XCTAssertEqual(appState.activeDashboardID, mac.id)
            XCTAssertEqual(appState.activeProfile, "default")
            XCTAssertEqual(appState.loadVoiceProfilePreferences(profile: "default"), macPreferences)
            appState.beginVoiceCallRecordingForTesting(engine: .gptLive, turns: [])
            return true
        }
        XCTAssertEqual(started, true)
        appState.minimisedLiveVoice = .gptLive
        XCTAssertEqual(appState.dashboardIDOnScreen, vps.id, "nothing switched")
        XCTAssertEqual(appState.liveCallDashboardID, mac.id)
        XCTAssertEqual(appState.liveCallProfile, "default")
        XCTAssertEqual(appState.callDashboardOffScreen, mac.id)
        XCTAssertTrue(appState.callBridge === macBridge, "its host routes go to Mac")
        XCTAssertEqual(appState.loadCallVoicePreferences(profile: "default"), macPreferences)
        XCTAssertTrue(appState.callSurvivesDashboardSwitch(to: mac.id))
        appState.minimisedLiveVoice = nil
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
        final class Mints {
            var failures = 1; var count = 0; var status = 503
            /// The next mint waits for `hold` to be resumed.
            var holds = false
            var hold: CheckedContinuation<Void, Never>?
        }
        let mints = Mints()
        let socket = ClarifyFakeSocket()
        let transport = ClarifyFakeTransport()
        transport.nextSocket = { socket }
        var operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        operations.mintTicket = { _ in
            mints.count += 1
            if mints.holds {
                mints.holds = false
                await withCheckedContinuation { mints.hold = $0 }
            }
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

        // A quiet sign-in dropped while it runs (past the cap meanwhile, or
        // no longer wanted) with no retry waiting stops saying "trying
        // again", its backoff kept (#2641's review, issue 2655).
        mints.holds = true
        appState.connectOtherCombinedDashboards(only: vps.id)
        await waitUntil { mints.hold != nil }
        _ = try XCTUnwrap(mints.hold, "the sign-in reached its mint")
        XCTAssertTrue(appState.combinedSignInsUnderWay.contains(vps.id))
        appState.combinedDashboardTrouble[vps.id] = .down
        // Called off (as Sign Out does), not a new generation: that one
        // passes again once the sign-in ends.
        appState.combinedSignInsCalledOff.insert(vps.id)
        mints.hold?.resume()
        mints.hold = nil
        await waitUntil { appState.combinedSignInsUnderWay.isEmpty }
        XCTAssertNil(appState.combinedDashboardTrouble[vps.id], "no \"trying again\" with no retry waiting")
        XCTAssertNil(appState.combinedDashboardRetries[vps.id]?.task)
        XCTAssertEqual(appState.combinedDashboardRetries[vps.id]?.attempt, 2, "its backoff stands")
        XCTAssertNil(appState.keptDashboardRuntimes[vps.id], "what it finished isn't kept")

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
            if path == NotifierPluginStatus.path {
                return ["ok": true, "capabilities": [BotWorkstreamsClient.capability], "name": "Studio"]
            }
            guard path.contains("profile=atlas") else { return ["waiting": []] }
            return ["waiting": [[
                "id": "w1", "kind": "approval", "session_ids": ["session-a"],
                "title": "Release prep", "summary": "rm -rf build", "at": 1_000,
            ]]]
        }

        // Named by the person, so its plugin's name doesn't relabel it.
        appState.renameDashboard(mac.id, to: "Mac")
        await appState.readOtherCombinedDashboardsNeedsYou()
        let item = try XCTUnwrap(appState.needsYou.otherDashboards[mac.id]?.first)
        // The pass reads its plugin's capabilities, so its Hermes' name lands
        // with no bots shown (Dashboard names).
        XCTAssertEqual(appState.savedDashboardRegistry.dashboard(with: mac.id)?.hermesName, "Studio")
        XCTAssertEqual(appState.savedDashboardRegistry.dashboard(with: mac.id)?.label, "Mac")
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
        XCTAssertEqual(counts.reads.filter { $0 == NotifierPluginStatus.path }.count, 1,
                       "its capabilities are asked once per kept connection")
        // One whose plugin didn't answer is asked again after a while, not
        // only when its kept connection is replaced (issue 2948).
        let named = try XCTUnwrap(appState.keptDashboardJSONReader)
        appState.combinedDashboardNameReads[mac.id] = nil
        appState.combinedDashboardPluginCapabilities[mac.id] = nil
        appState.keptDashboardJSONReader = { bridge, path in
            guard path == NotifierPluginStatus.path else { return try await named(bridge, path) }
            counts.reads.append(path)
            throw URLError(.timedOut)
        }
        func capabilityAsks() -> Int { counts.reads.filter { $0 == NotifierPluginStatus.path }.count }
        let asksBefore = capabilityAsks()
        await appState.readOtherCombinedDashboardsNeedsYou()
        XCTAssertEqual(capabilityAsks(), asksBefore + 1)
        await appState.readOtherCombinedDashboardsNeedsYou()
        XCTAssertEqual(capabilityAsks(), asksBefore + 1, "not asked again on the next poll")
        appState.keptDashboardJSONReader = named
        let retry = AppState.combinedDashboardNameRetryInterval
        await appState.readOtherCombinedDashboardsNeedsYou(now: Date().addingTimeInterval(retry + 1))
        XCTAssertEqual(capabilityAsks(), asksBefore + 2, "asked again once the wait passed")
        XCTAssertNotNil(appState.combinedDashboardNameReads[mac.id])
        XCTAssertNil(appState.combinedDashboardNameReads[mac.id]?.retryAt, "answered: asked no more on this connection")
        await appState.readOtherCombinedDashboardsNeedsYou(now: Date().addingTimeInterval(3 * retry))
        XCTAssertEqual(capabilityAsks(), asksBefore + 2)
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

        // A room wait whose read was out while the two dashboards turned
        // out one Hermes, or two: whether it's the open room's is asked once
        // the read is back (issue 2764, DeepSeek on #2756).
        final class Paused {
            var holds = false
            var waiting: CheckedContinuation<Void, Never>?
            var roomWaits: [[String: Any]] = []
        }
        let paused = Paused()
        appState.keptDashboardJSONReader = { bridge, path in
            guard path.contains(NeedsYouStore.path), path.contains("profile=atlas") else { return try await reader(bridge, path) }
            if paused.holds {
                paused.holds = false
                await withCheckedContinuation { paused.waiting = $0 }
            }
            let listed = try await reader(bridge, path)["waiting"] as? [[String: Any]] ?? []
            return ["waiting": listed + paused.roomWaits]
        }
        let room = GroupRoom(
            roomID: "room-1", name: "Planning", members: [],
            authorityGatewayID: "gw-a", authorityEpoch: 1, revision: 1,
            createdAt: 0, updatedAt: 0, disbandedAt: nil, latestSeq: 0
        )
        appState.setActiveRoomSurfaceForTesting(AppState.GroupRoomSurface(dashboardID: vps.id, room: room))
        let ownSessions = appState.sessions
        let shared = session("shared-1")
        func readPaused(_ waitID: String, meanwhile: @escaping @MainActor () -> Void) async {
            paused.roomWaits = [["id": waitID, "kind": "approval", "session_ids": ["room-s"], "room": "room-1", "at": 2_000]]
            paused.holds = true
            let pass = Task { @MainActor in await appState.readOtherCombinedDashboardsNeedsYou() }
            await waitUntil { paused.waiting != nil }
            guard let waiting = paused.waiting else {
                // Never reached the pause: nothing would resume it.
                paused.holds = false
                XCTFail("atlas's read never reached the pause")
                await pass.value
                return
            }
            meanwhile()
            waiting.resume()
            paused.waiting = nil
            await pass.value
        }
        // One Hermes by the time it's back: the open room's, no banner.
        await readPaused("wr1") {
            appState.sessions = ownSessions + [shared]
            appState.combinedDashboardChats[mac.id] = CombinedDashboardChats(
                bridge: ObjectIdentifier(kept.bridge), profiles: ["default", "atlas"], sessions: [shared], at: Date()
            )
        }
        XCTAssertNotNil(appState.combinedHermesGroups[vps.id])
        XCTAssertEqual(appState.combinedHermesGroups[mac.id], appState.combinedHermesGroups[vps.id])
        XCTAssertTrue(appState.needsYou.otherDashboards[mac.id]?.contains { $0.waitID == "wr1" } == true)
        XCTAssertNil(appState.needsYou.banner, "the same Hermes' room on screen")
        // Two by the time it's back: another Hermes' room with the same id
        // banners.
        await readPaused("wr2") {
            appState.sessions = ownSessions
            appState.combinedDashboardChats[mac.id] = nil
        }
        XCTAssertEqual(appState.needsYou.banner?.waitID, "wr2", "another Hermes' room under the same id")
        if let banner = appState.needsYou.banner { appState.needsYou.dismissBanner(banner) }
        appState.setActiveRoomSurfaceForTesting(nil)
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
        // One Hermes saved twice (a chat both list): the copy keeps only
        // the profile this dashboard doesn't read (#2754 review).
        appState.sessions = [session("shared-1")]
        appState.combinedDashboardChats[mac.id] = CombinedDashboardChats(
            bridge: ObjectIdentifier(kept.bridge), profiles: ["default", "atlas"], sessions: [session("shared-1")], at: Date()
        )
        XCTAssertEqual(appState.artifactSources(for: .profile).filter { $0.dashboardID == mac.id }.map(\.profile), ["atlas"])
        appState.sessions = []
        appState.combinedDashboardChats[mac.id] = CombinedDashboardChats(
            bridge: ObjectIdentifier(kept.bridge), profiles: ["default", "atlas"], sessions: [], at: Date()
        )

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

    func testAKeptDashboardsChatsChangeReadsItsChatsAtOnce() async throws {
        final class Reads { var paths: [String] = [] }
        let reads = Reads()
        let (appState, mac, vps, _, _) = try await combinedDashboards(operations: switchLifecycleOperations(workCatalog: []) { _ in [] })
        await appState.switchDashboard(to: vps.id)
        let kept = try XCTUnwrap(appState.keptDashboardRuntimes[mac.id])
        appState.keptDashboardChatsChangeWait = .zero
        appState.keptDashboardJSONReader = { _, path in
            if path == "/api/profiles" { return ["profiles": ["default"]] }
            guard path.contains("/api/profiles/sessions"), !path.contains("source=cron") else { return ["sessions": []] }
            reads.paths.append(path)
            return ["sessions": [
                ["id": "mac-new", "title": "Made there", "message_count": 1, "profile": "default", "last_active": 2_000],
            ]]
        }
        await appState.readOtherCombinedDashboardsChats()
        XCTAssertEqual(reads.paths.count, 1)

        // A chat made on its Hermes: its own sessions.changed reads its
        // chats now, inside the minute the poll would wait.
        kept.client.onEvent?(.sessionsChanged)
        kept.client.onEvent?(.sessionsChanged)
        let read = try XCTUnwrap(appState.keptDashboardChatsChangeReads[mac.id], "a read on its way")
        await read.value
        XCTAssertEqual(reads.paths.count, 2, "a burst is one read")
        XCTAssertNil(appState.keptDashboardChatsChangeReads[mac.id])
        XCTAssertEqual(appState.otherCombinedDashboardsChats(excluding: []).map(\.id), ["mac-new"])
        // Never the screen's: its list and its catalog stay as they were.
        XCTAssertFalse(appState.sessions.contains { $0.id == "mac-new" })

        // Taken up, the switch back's sync reads it; a change noted before
        // goes with the kept connection.
        appState.keptDashboardChatsChangeWait = .seconds(60)
        kept.client.onEvent?(.sessionsChanged)
        let waiting = try XCTUnwrap(appState.keptDashboardChatsChangeReads[mac.id])
        await appState.switchDashboard(to: mac.id)
        XCTAssertNil(appState.keptDashboardChatsChangeReads[mac.id])
        XCTAssertTrue(waiting.isCancelled)

        // Kept again and let go, nothing waits on it either.
        await appState.switchDashboard(to: vps.id)
        let keptAgain = try XCTUnwrap(appState.keptDashboardRuntimes[mac.id])
        keptAgain.client.onEvent?(.sessionsChanged)
        let dropped = try XCTUnwrap(appState.keptDashboardChatsChangeReads[mac.id])
        appState.dropKeptDashboardRuntime(mac.id, keepingLists: true)
        XCTAssertNil(appState.keptDashboardChatsChangeReads[mac.id])
        XCTAssertTrue(dropped.isCancelled)
    }

    /// The other dashboards' kept chat reads reach the widgets' snapshot
    /// (#3027, issue 3034): a far profile's workspace appears after a read,
    /// leaves once its Hermes no longer lists the profile, and stays while
    /// the profile list can't be read; a profile whose chats couldn't be
    /// read, with none read before, keeps what the widgets stored.
    func testKeptChatReadsPublishAndPruneAFarProfilesWidgetWorkspace() async throws {
        final class Hermes { var profiles: [String]? = ["default", "atlas"]; var atlasFails = false }
        let hermes = Hermes()
        let (appState, mac, vps, _, _) = try await combinedDashboards(operations: switchLifecycleOperations(workCatalog: []) { _ in [] })
        await appState.switchDashboard(to: vps.id)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeptWidgets.\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = WidgetSnapshotStore(directory: root)
        appState.widgetSnapshotStoreOverride = store
        appState.widgetSnapshotReloadOverride = {}
        appState.keptDashboardJSONReader = { _, path in
            if path == "/api/profiles" {
                guard let profiles = hermes.profiles else { throw URLError(.timedOut) }
                return ["profiles": profiles]
            }
            guard path.contains("/api/profiles/sessions"), !path.contains("source=cron") else { return ["sessions": []] }
            let profile = path.contains("profile=atlas") ? "atlas" : "default"
            if profile == "atlas", hermes.atlasFails { throw URLError(.timedOut) }
            return ["sessions": [
                ["id": "\(profile)-1", "title": "Chat", "message_count": 1, "profile": profile, "last_active": 2_000],
            ]]
        }
        func farWorkspaces() -> [String: WidgetWorkspaceSnapshot] {
            Dictionary((store.read()?.workspaces ?? []).filter { $0.id.dashboardID == mac.id }.map { ($0.id.profile, $0) },
                       uniquingKeysWith: { first, _ in first })
        }

        await appState.readOtherCombinedDashboardsChats()
        XCTAssertEqual(Set(farWorkspaces().keys), ["default", "atlas"], "both profiles' chats reach the widgets")
        let atlas = try XCTUnwrap(farWorkspaces()["atlas"])
        XCTAssertEqual(atlas.choices.map(\.reference.sessionID), ["atlas-1"])

        // The profile list can't be read: the last one stands, nothing goes.
        hermes.profiles = nil
        appState.keptDashboardProfiles[mac.id]?.at = .distantPast
        await appState.readOtherCombinedDashboardsChats(force: true)
        XCTAssertEqual(Set(farWorkspaces().keys), ["default", "atlas"], "a failed profile list prunes nothing")

        // Atlas deleted there: its workspace leaves with it.
        hermes.profiles = ["default"]
        appState.keptDashboardProfiles[mac.id]?.at = .distantPast
        await appState.readOtherCombinedDashboardsChats(force: true)
        XCTAssertEqual(Set(farWorkspaces().keys), ["default"], "a profile its Hermes no longer lists leaves")

        // The kept list dropped it too, so a later publish doesn't bring it
        // back (#3117 review).
        XCTAssertEqual(appState.combinedDashboardChats[mac.id]?.profiles, ["default"])
        XCTAssertFalse(appState.combinedDashboardChats[mac.id]?.sessions.contains { $0.profile == "atlas" } ?? true)

        // Back again, but its chats can't be read and none were read since
        // it was listed again: what the widgets stored for it stands.
        let stored = try XCTUnwrap(store.read())
        try WidgetSnapshotPublisher(store: store, reload: {}).publish(others: [atlas], over: stored, language: stored.appLanguage)
        hermes.profiles = ["default", "atlas"]
        hermes.atlasFails = true
        appState.keptDashboardProfiles[mac.id]?.at = .distantPast
        await appState.readOtherCombinedDashboardsChats(force: true)
        XCTAssertEqual(farWorkspaces()["atlas"], atlas, "an unread profile keeps what was stored, not an empty list")
        XCTAssertEqual(appState.combinedDashboardChats[mac.id]?.unreadProfiles, ["atlas"])
    }

    /// A pass whose chat reads all fail still narrows the kept list to the
    /// profiles its Hermes lists now, so a later publish can't bring a
    /// deleted profile back into the widgets, and reads anew (#3117 review).
    func testKeptChatsNarrowToTheListedProfilesWhenNoReadAnswers() {
        let last = CombinedDashboardChats(
            bridge: ObjectIdentifier(NSObject()), profiles: ["default", "atlas"],
            sessions: [session("d-1"), session("a-1", profile: "atlas")], at: Date(),
            unreadProfiles: ["atlas"]
        )
        let kept = AppState.combinedChats(last, keepingProfiles: ["default", "coder"], unread: ["coder"])
        XCTAssertEqual(kept.profiles, ["default", "coder"])
        XCTAssertEqual(kept.sessions.map(\.id), ["d-1"], "the deleted profile's rows go")
        XCTAssertEqual(kept.unreadProfiles, ["coder"], "its unread mark goes, the new one's comes")
        XCTAssertEqual(kept.at, .distantPast, "read anew on the next pass")
        XCTAssertEqual(kept.bridge, last.bridge)
    }

    /// Another combined dashboard's Chats row opens in place (no-switch
    /// stage 2): no switch, the chat read and sent through that dashboard's
    /// kept connection on its own runtime, the dashboard on screen's
    /// events and selection left alone.
    func testAKeptDashboardsChatOpensInPlaceAndSendsThroughIt() async throws {
        final class Seen { var opened: [(ObjectIdentifier, String)] = []; var sent: [(ObjectIdentifier, String, String)] = [] }
        let seen = Seen()
        var operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        operations.openSession = { client, sessionID, _ in
            seen.opened.append((ObjectIdentifier(client), sessionID))
            return SessionResumeResult(
                sessionId: sessionID,
                messages: [ChatMessage(id: "far-1", role: .assistant, content: "From the Mac", timestamp: "ts-f1")],
                snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
            )
        }
        operations.sendPrompt = { client, sessionID, text in
            seen.sent.append((ObjectIdentifier(client), sessionID, text))
            return .accepted
        }
        let (appState, mac, vps, outgoing, socket) = try await combinedDashboards(operations: operations)
        await appState.switchDashboard(to: vps.id)
        let kept = try XCTUnwrap(appState.keptDashboardRuntimes[mac.id])
        XCTAssertTrue(kept.client === outgoing)
        var row = SessionSummary(id: "mac-1", alternateIds: [], title: "Release prep", model: "Hermes", updatedLabel: "now",
                                 profile: "default", source: .chat, isActive: false, isArchived: false, lineageRootId: nil)
        row.combinedDashboardID = mac.id
        appState.combinedDashboardChats[mac.id] = CombinedDashboardChats(
            bridge: ObjectIdentifier(kept.bridge), profiles: ["default"], sessions: [row], at: Date()
        )

        var botChat = row
        botChat.title = BotMode.canonicalChatTitle
        XCTAssertFalse(appState.openFarChatInPlace(botChat, in: mac.id), "a far Bot Chat still opens through a switch")
        XCTAssertNil(appState.farChatDashboardID)
        // Named by that dashboard's bots: by its id, or by the lineage root
        // a compacted Bot Chat keeps.
        let atlas = BotProfile(name: "atlas", botTitle: nil, displayName: "Atlas", profileDescription: "", model: nil,
                               provider: nil, hasAvatar: false, isPinned: false, isHiddenByMeta: false, appearanceColor: nil,
                               canonicalSession: BotCanonicalSession(id: "atlas-chat", resolvedID: nil, lastActive: nil, preview: nil),
                               lastActive: nil, lastPreview: nil)
        appState.combinedDashboardBots[mac.id] = CombinedDashboardBots(
            client: ObjectIdentifier(outgoing), bots: [atlas], avatars: [:], at: Date()
        )
        func farRow(_ id: String, lineageRoot: String?) -> SessionSummary {
            SessionSummary(id: id, alternateIds: [], title: "Atlas notes", model: "Hermes", updatedLabel: "now",
                           profile: "atlas", source: .chat, isActive: false, isArchived: false, lineageRootId: lineageRoot)
        }
        XCTAssertTrue(appState.isFarBotChat(farRow("atlas-chat", lineageRoot: nil), in: mac.id))
        let compacted = farRow("atlas-chat-2", lineageRoot: "atlas-chat")
        XCTAssertTrue(appState.isFarBotChat(compacted, in: mac.id))
        XCTAssertFalse(appState.isFarBotChat(row, in: mac.id), "an ordinary chat opens in place")
        appState.combinedDashboardBots[mac.id] = nil

        appState.openCombinedChat(row, in: mac.id)
        await waitUntil { appState.activeSessionId == "mac-1" && appState.messages.contains { $0.id == "far-1" } }
        XCTAssertEqual(appState.activeDashboardID, vps.id, "no switch")
        XCTAssertEqual(appState.farChatDashboardID, mac.id, "the chat is the Mac's")
        XCTAssertEqual(seen.opened.last?.0, ObjectIdentifier(outgoing), "read through the kept connection")
        XCTAssertEqual(seen.opened.last?.1, "mac-1")
        XCTAssertTrue(appState.runtime(for: mac.id) === kept.runtime)
        XCTAssertTrue(appState.chatIsConnected, "its own connection's")
        XCTAssertEqual(kept.runtime.sessions.first?.id, "mac-1", "its runtime holds its row as the Chats list read it")
        XCTAssertNil(kept.runtime.sessions.first?.combinedDashboardID, "as a row of its own")
        XCTAssertNotEqual(appState.chatResumeLastSessionReference(for: "default")?.sessionID, "mac-1",
                          "not this dashboard's selection")
        // Only its own dashboard's events reach it.
        XCTAssertFalse(appState.eventBelongsToActiveSession("mac-1"), "the dashboard on screen's events don't")
        appState.act(onRuntime: kept.runtime) {
            XCTAssertTrue(appState.eventBelongsToActiveSession("mac-1"), "its own do")
        }
        XCTAssertTrue(appState.keptDashboardFollowsChats(mac.id))
        XCTAssertFalse(appState.keptDashboardFollowsChats(vps.id))

        // A message goes through the kept connection, to the chat.
        _ = await appState.sendMessage("Ship it")
        XCTAssertEqual(seen.sent.last?.0, ObjectIdentifier(outgoing))
        XCTAssertEqual(seen.sent.last?.1, "mac-1")
        XCTAssertEqual(seen.sent.last?.2, "Ship it")
        XCTAssertTrue(appState.messages.contains { $0.role == .user && $0.content == "Ship it" })
        // The composer's context, captured on screen, is the far chat's, so
        // its send is checked there and goes.
        let composerContext = appState.composerSubmissionContext()
        XCTAssertEqual(composerContext.clientIdentity, kept.runtime.client.map(ObjectIdentifier.init))
        XCTAssertTrue(appState.act(onRuntime: kept.runtime) { appState.isCurrentComposerSubmission(composerContext) },
                      "a context captured on screen is the far chat's")

        // The composer shows and writes the far chat's own model, reasoning
        // and YOLO, and keeps its draft under its own dashboard and profile.
        kept.runtime.runtime.model = "mac-model"
        appState.runtimeOnScreen.runtime.model = "vps-model"
        XCTAssertEqual(appState.chatRuntimeState.model, "mac-model", "the far chat's")
        XCTAssertEqual(appState.runtime.model, "vps-model", "the dashboard on screen's stays its own")
        appState.updateChatRuntimeState { $0.provider = "mac-provider" }
        XCTAssertEqual(kept.runtime.runtime.provider, "mac-provider")
        XCTAssertNotEqual(appState.runtimeOnScreen.runtime.provider, "mac-provider")
        XCTAssertTrue(appState.chatClient === outgoing, "its own connection's client")
        XCTAssertEqual(appState.composerDraftKeyOnScreen.dashboard, mac.id, "its draft is the Mac's")
        XCTAssertEqual(appState.composerDraftKeyOnScreen.profile, "default")
        let framesBefore = socket.refusedTexts.count
        _ = await appState.setReasoningEffort("high")
        XCTAssertTrue(socket.refusedTexts.dropFirst(framesBefore).contains { $0.contains("reasoning") && $0.contains("mac-1") },
                      "its reasoning goes through the kept connection, for its chat")
        let yoloFrames = socket.refusedTexts.count
        _ = await appState.setYoloModeReportingFailure(true)
        XCTAssertTrue(socket.refusedTexts.dropFirst(yoloFrames).contains { $0.contains("mac-1") },
                      "its YOLO goes through the kept connection too")
        // The Model sheet's catalog is read through it, and its Edit
        // filters and Quick picks are the Mac's own.
        let catalogFrames = socket.refusedTexts.count
        _ = await appState.loadChatModelProviders(sessionId: "mac-1", refresh: false)
        XCTAssertTrue(socket.refusedTexts.dropFirst(catalogFrames).contains { $0.contains("model.options") },
                      "the catalog is the Mac's, read through its kept connection")
        let screenVisibility = appState.modelVisibility
        let screenPicks = appState.modelQuickPicks
        appState.saveChatModelVisibility(ModelVisibility(hiddenProviders: ["mac-hidden"], hiddenModels: []))
        XCTAssertEqual(appState.chatModelVisibility.hiddenProviders, ["mac-hidden"])
        XCTAssertEqual(appState.modelVisibility, screenVisibility, "the dashboard on screen's filters are untouched")
        appState.updateChatModelQuickPicks { $0.recordSwitch(to: ModelQuickPick(provider: "mac-provider", model: "mac-model"), from: nil) }
        XCTAssertEqual(appState.chatModelQuickPicks.recent.first?.model, "mac-model")
        XCTAssertEqual(appState.modelQuickPicks, screenPicks, "the dashboard on screen's Quick picks are untouched")
        XCTAssertEqual(appState.storedModelQuickPicks()[AppState.dashboardPreferenceBucket(mac.id)]?.recent.first?.model, "mac-model",
                       "kept under the Mac")
        // Its draft's owner comes from the Mac's own list.
        XCTAssertEqual(appState.composerDraftOwner(for: appState.composerDraftKeyOnScreen), "mac-1")
        // And whether its id is another chat's now is read from that list too.
        XCTAssertTrue(appState.composerDraftKey(appState.composerDraftKeyOnScreen, isNotChatOf: "older-chat"),
                      "the Mac's list gives mac-1 to its own row")
        XCTAssertFalse(appState.composerDraftKey(appState.composerDraftKeyOnScreen, isNotChatOf: "mac-1"))
        // Once the chat is left, its stored draft is still told from the
        // Mac's list while the Mac is kept: words that came back after it
        // was left keep their owner and stay its chat's.
        let farKey = appState.composerDraftKeyOnScreen
        let farChatOwner = appState.farChat
        appState.farChat = nil
        XCTAssertEqual(appState.composerDraftOwner(for: farKey), "mac-1", "read from the Mac's list, not the screen's")
        XCTAssertTrue(appState.composerDraftKey(farKey, isNotChatOf: "older-chat"),
                      "and whether its id is another chat's is the Mac's list's call too")
        // Two ids of one Mac row are one chat's, by the Mac's list alone.
        kept.runtime.sessions[0].alternateIds = ["mac-alias"]
        var aliasKey = farKey
        aliasKey.sessionID = "mac-alias"
        var strangerKey = farKey
        strangerKey.sessionID = "nobody"
        XCTAssertTrue(appState.composerDraftKeysAreSameChat(farKey, aliasKey), "its alias is its chat")
        XCTAssertFalse(appState.composerDraftKeysAreSameChat(farKey, strangerKey), "an id the Mac doesn't list isn't")
        kept.runtime.sessions[0].alternateIds = []
        appState.farChat = farChatOwner

        // Its kept connection gone, nothing reaches another dashboard's.
        let sentBefore = seen.sent.count
        appState.dropKeptDashboardRuntime(mac.id, keepingLists: true)
        XCTAssertFalse(appState.chatIsConnected)
        let wentAnyway = await appState.sendMessage("Again")
        XCTAssertFalse(wentAnyway)
        XCTAssertEqual(seen.sent.count, sentBefore, "never sent to the dashboard on screen")
        let unreachableCatalog = await appState.loadChatModelProviders(sessionId: "mac-1", refresh: false)
        XCTAssertNil(unreachableCatalog, "no catalog while its connection is down, never the screen's")
        // Its filters and Quick picks still keep under the Mac, never the screen.
        appState.saveChatModelVisibility(ModelVisibility(hiddenProviders: ["mac-gone"], hiddenModels: []))
        XCTAssertEqual(appState.chatModelVisibility.hiddenProviders, ["mac-gone"])
        XCTAssertEqual(appState.modelVisibility, screenVisibility, "the dashboard on screen's filters are untouched")
        appState.updateChatModelQuickPicks { $0.recordSwitch(to: ModelQuickPick(provider: "mac-provider", model: "mac-later"), from: nil) }
        XCTAssertEqual(appState.storedModelQuickPicks()[AppState.dashboardPreferenceBucket(mac.id)]?.recent.first?.model, "mac-later")
        XCTAssertEqual(appState.modelQuickPicks, screenPicks, "the dashboard on screen's Quick picks are untouched")
        // Unreachable, its rows still save under its own profile.
        appState.farChat = FarChatOwner(dashboardID: mac.id, profile: "work")
        XCTAssertEqual(appState.activeSessionId, "mac-1")
        // Its rows as they stand when the flush runs.
        appState.messages = [ChatMessage(id: "far-1", role: .assistant, content: "From the Mac", timestamp: "ts-f1")]
        guard case .unreachable = appState.chatRuntimeRoute else { return XCTFail("its dashboard is gone") }
        appState.flushPendingPresentationCache()
        appState.sessionPresentationCache.waitForPendingWrites()
        let probe = [ChatMessage(id: "far-1", role: .assistant, content: "From the Mac", timestamp: "")]
        let savedAs = appState.presentationCacheSessionIDs(for: "mac-1")
        XCTAssertEqual(appState.sessionPresentationCache.merge(probe, profile: "work", sessionIDs: savedAs).first?.timestamp, "ts-f1",
                       "saved under the far chat's profile (as \(savedAs))")
        // So do a deferred flush's, its connection having dropped while it
        // was parked.
        appState.messages = [ChatMessage(id: "far-1", role: .assistant, content: "From the Mac", timestamp: "ts-f2")]
        appState.schedulePresentationCacheFlush(for: "mac-1")
        await appState.presentationCacheFlushOperationForTesting?.value
        appState.sessionPresentationCache.waitForPendingWrites()
        XCTAssertEqual(appState.sessionPresentationCache.merge(probe, profile: "work", sessionIDs: savedAs).first?.timestamp, "ts-f2",
                       "a deferred flush saves under the far chat's profile too")
        // A switch makes the chat on screen that dashboard's, as before.
        appState.farChat = FarChatOwner(dashboardID: mac.id, profile: "default")
        var registry = appState.savedDashboardRegistry
        registry.activeDashboardID = mac.id
        appState.savedDashboardRegistry = registry
        XCTAssertNil(appState.farChatDashboardID)
    }

    /// A far chat on another profile takes the kept socket on a client of
    /// its profile, as a profile switch does: its runtime is on that
    /// profile and the screen's isn't touched. Its followed chats settle
    /// when that connection goes, and only theirs.
    func testAKeptDashboardsChatOnAnotherProfileTakesItsSocket() async throws {
        let operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        let (appState, mac, vps, outgoing, socket) = try await combinedDashboards(operations: operations)
        await appState.switchDashboard(to: vps.id)
        let kept = try XCTUnwrap(appState.keptDashboardRuntimes[mac.id])
        XCTAssertTrue(kept.client === outgoing)
        let screenClient = appState.client

        // A chat left mid-reply there on its old profile keeps naming it.
        appState.backgroundChats = [BackgroundChat(
            sessionIDs: ["left-1"], durableSessionID: nil, title: "Left", dashboardID: mac.id,
            profile: "default", isBotChat: false, rows: [], streamingText: "Half"
        )]
        // So does the far chat open there now, as it hands the socket on.
        appState.activeSessionId = "far-open"
        appState.farChat = FarChatOwner(dashboardID: mac.id, profile: "default")
        let runtime = try XCTUnwrap(appState.keptRuntime(mac.id, on: "work"))
        let handed = try XCTUnwrap(appState.keptDashboardRuntimes[mac.id])
        XCTAssertEqual(handed.client.sessionProfile(for: "left-1"), "default", "its chats on the old profile keep it")
        XCTAssertEqual(handed.client.sessionProfile(for: "far-open"), "default", "the far chat on its old profile keeps it")
        appState.farChat = nil
        appState.backgroundChats = []
        XCTAssertTrue(runtime === kept.runtime, "the same runtime")
        XCTAssertFalse(handed.client === outgoing)
        XCTAssertEqual(handed.client.profile, "work")
        XCTAssertTrue(handed.client.isConnected)
        XCTAssertFalse(outgoing.isConnected)
        XCTAssertEqual(socket.closeCode, .invalid, "the socket stays open for the new profile")
        XCTAssertEqual(runtime.activeProfile, "work")
        XCTAssertTrue(runtime.client === handed.client)
        XCTAssertTrue(appState.client === screenClient, "the screen's client isn't touched")
        XCTAssertNotEqual(appState.activeProfile, "work")
        XCTAssertTrue(appState.keptRuntime(mac.id, on: "work") === runtime, "on its profile already, kept as it is")
        XCTAssertTrue(appState.keptDashboardRuntimes[mac.id]?.client === handed.client)

        // A far chat's deferred flush writes under its own profile, and
        // skips once its runtime has moved to another.
        appState.activeSessionId = "far-s"
        appState.messages = outgoingTranscript
        appState.farChat = FarChatOwner(dashboardID: mac.id, profile: "default")
        appState.schedulePresentationCacheFlush(for: "far-s")
        await appState.presentationCacheFlushOperationForTesting?.value
        appState.sessionPresentationCache.waitForPendingWrites()
        let farProbe = [ChatMessage(id: "a1", role: .assistant, content: "Outgoing answer", timestamp: "")]
        let farIDs = appState.presentationCacheSessionIDs(for: "far-s")
        XCTAssertEqual(appState.sessionPresentationCache.merge(farProbe, profile: "work", sessionIDs: farIDs).first?.timestamp, "",
                       "its runtime is on another profile now: nothing saved under it")
        appState.farChat = FarChatOwner(dashboardID: mac.id, profile: "work")
        appState.schedulePresentationCacheFlush(for: "far-s")
        await appState.presentationCacheFlushOperationForTesting?.value
        appState.sessionPresentationCache.waitForPendingWrites()
        XCTAssertEqual(appState.sessionPresentationCache.merge(farProbe, profile: "work", sessionIDs: farIDs).first?.timestamp, "ts-a1",
                       "saved under the far chat's profile, though scheduled on screen")
        // Scheduled for a chat on the runtime's profile, and run once the
        // chat open there is on another: skipped, though the runtime's
        // profile is still the one it was scheduled on.
        appState.activeSessionId = "far-p"
        appState.messages = outgoingTranscript
        appState.farChat = FarChatOwner(dashboardID: mac.id, profile: "work")
        appState.schedulePresentationCacheFlush(for: "far-p")
        appState.farChat = FarChatOwner(dashboardID: mac.id, profile: "default")
        await appState.presentationCacheFlushOperationForTesting?.value
        appState.sessionPresentationCache.waitForPendingWrites()
        let movedIDs = appState.presentationCacheSessionIDs(for: "far-p")
        XCTAssertEqual(appState.sessionPresentationCache.merge(farProbe, profile: "work", sessionIDs: movedIDs).first?.timestamp, "",
                       "the chat open there is on another profile: nothing saved under the runtime's")
        appState.farChat = nil

        // The same ids on two dashboards are two chats, each followed.
        func left(_ dashboardID: UUID) -> BackgroundChat {
            BackgroundChat(sessionIDs: ["shared"], durableSessionID: nil, title: "Shared", dashboardID: dashboardID,
                           profile: appState.activeProfile, isBotChat: false, rows: [], streamingText: "Half a reply")
        }
        let onMac = left(mac.id), onVPS = left(vps.id)
        let both = BackgroundChat.adding(onMac, to: BackgroundChat.adding(onVPS, to: []))
        XCTAssertEqual(both.count, 2)
        XCTAssertEqual(BackgroundChat.adding(left(mac.id), to: both).count, 2, "one copy per chat")
        XCTAssertTrue(onMac.isRunning && onVPS.isRunning)
        appState.backgroundChats = both
        // The pane's chat is this dashboard's, though the Mac's comes first.
        appState.besideChatIDs = ["shared"]
        XCTAssertEqual(appState.keptChat(answering: "shared")?.dashboardID, vps.id)
        appState.besideChatIDs = nil
        // Letting go of an idle chat lets go of this dashboard's only.
        let idleMac = left(mac.id), idleVPS = left(vps.id)
        idleMac.state.turnState = .idle
        idleVPS.state.turnState = .idle
        appState.backgroundChats = [idleMac, idleVPS]
        appState.letGoOfIdleFollowedChat(answering: ["shared"])
        XCTAssertEqual(appState.backgroundChats.map(\.dashboardID), [mac.id], "the Mac's, under the same ids, stays")
        appState.act(onRuntime: kept.runtime) { appState.letGoOfIdleFollowedChat(answering: ["shared"]) }
        XCTAssertTrue(appState.backgroundChats.isEmpty, "let go in its own dashboard's scope")
        appState.backgroundChats = both
        appState.dropKeptDashboardRuntime(mac.id, keepingLists: true)
        XCTAssertFalse(onMac.isRunning, "its connection gone, its reply is followed no more")
        XCTAssertTrue(onVPS.isRunning, "the screen's dashboard's goes on")
        appState.backgroundChats = []
    }

    func testTheChatsListShowsAKeptDashboardsChatsAndOpensThroughIt() async throws {
        final class Counts { var connects = 0; var mints = 0; var reads: [String] = []; var cronReads: [String] = [] }
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
            if path.contains("source=cron") {
                // Its cron runs, read for twin evidence only (issue 2761).
                counts.cronReads.append(path)
                return ["sessions": path.contains("profile=atlas") ? [] : [
                    ["id": "cron-mac-1", "title": "Daily brief", "message_count": 2, "profile": "default", "last_active": 900],
                ]]
            }
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
        // Its cron runs' ids, every profile's few newest, for twin evidence
        // only: never listed (issue 2761).
        XCTAssertEqual(counts.cronReads.count, 2)
        XCTAssertTrue(counts.cronReads.allSatisfy { $0.contains("limit=\(AppState.combinedDashboardCronLimit)") })
        XCTAssertEqual(appState.combinedDashboardChats[mac.id]?.cronIDs, ["cron-mac-1"])
        XCTAssertFalse(appState.otherCombinedDashboardsChats(excluding: []).contains { $0.id == "cron-mac-1" })
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
        // CarPlay's Voice list offers the same agents (no-switch stage 2):
        // another dashboard's carries it, and is named with it.
        let agents = CarPlayVoiceCoordinator.agents(in: appState)
        XCTAssertEqual(agents.map(\.profile), appState.combinedProfileStrip(own: appState.profiles).map(\.profile))
        XCTAssertEqual(agents.filter { $0.dashboardID == mac.id }.map(\.profile), ["atlas", "default"])
        XCTAssertFalse(agents.contains { $0.dashboardID == vps.id }, "the dashboard on screen's carry none")
        XCTAssertTrue(CarPlayVoiceCoordinator.agentTitle(CarPlayAgent(dashboardID: mac.id, profile: "atlas"), in: appState).hasPrefix("atlas"))
        // Its chats in the car are that agent's, from the kept read; with
        // no live mode set there, the car switches rather than calling it
        // in place (Classic voice talks through the chat on screen).
        XCTAssertEqual(CarPlayVoiceCoordinator.farChatList("atlas", in: mac.id, appState: appState).recent.map(\.sessionID), ["atlas-1"])
        XCTAssertFalse(appState.canStartLiveCallOnFarDashboard(mac.id, profile: "atlas"))
        XCTAssertNil(appState.voiceModeOnFarDashboard(mac.id, profile: "atlas"), "no mode to mark where it can't start")
        // Siri's profile phrases and the Shortcuts pickers: the other
        // dashboard's profiles, each id carrying its dashboard, named with
        // it; the one on screen's stay bare (no-switch stage 2).
        appState.persistSiriCombinedProfiles()
        let siri = ConduitProfileEntityQuery.combinedProfiles(appState.defaults)
        XCTAssertEqual(Set(siri.map(\.id)), [
            ConduitProfileEntity.farID(profile: "default", dashboardID: mac.id),
            ConduitProfileEntity.farID(profile: "atlas", dashboardID: mac.id),
        ])
        let atlas = try XCTUnwrap(siri.first { ConduitProfileEntity.parts(of: $0.id).profile == "atlas" })
        XCTAssertEqual(ConduitProfileEntity.parts(of: atlas.id).dashboardID, mac.id)
        XCTAssertTrue(atlas.displayName.hasPrefix("atlas"), atlas.displayName)
        XCTAssertEqual(ConduitProfileEntity.parts(of: "default").profile, "default")
        XCTAssertNil(ConduitProfileEntity.parts(of: "default").dashboardID, "a bare id is the dashboard in use's")
        XCTAssertNil(ConduitProfileEntity.parts(of: "me@example").dashboardID, "an @ not followed by a dashboard id is the name's")
        XCTAssertNil(ConduitProfileEntity.parts(of: "@\(mac.id.uuidString)").dashboardID)
        // A launch naming the dashboard on screen goes on as usual; one
        // naming a dashboard that can't take the call in place (not kept
        // live here) is left to the switch.
        let onScreen = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "default", dashboardID: vps.id)
        let handled = await appState.handledVoiceLaunchOnFarDashboard(onScreen)
        XCTAssertFalse(handled)
        let unnamed = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: "default")
        let handledUnnamed = await appState.handledVoiceLaunchOnFarDashboard(unnamed)
        XCTAssertFalse(handledUnnamed)
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
        // No bots anywhere: a chat both lists give is the same evidence,
        // so the profile still shows once (issue 2741).
        XCTAssertEqual(appState.combinedProfileStrip(own: ["default"]).count, 3, "two Hermes until something says otherwise")
        // A Hermes sharing only cron runs: the kept dashboard's cron ids
        // count as this one's cron rows do, so it's still one Hermes
        // (issue 2761); a cron id only one side lists says nothing.
        let ownCron = appState.cronSessions
        appState.cronSessions = [SessionSummary(id: "cron-run-7f3a", alternateIds: [], title: "Daily brief", model: "Hermes",
                                                updatedLabel: "now", profile: "default", source: .cron, isActive: false,
                                                isArchived: false, lineageRootId: nil)]
        XCTAssertFalse(appState.combinedHermesEvidence[mac.id]?.contains("cron-run-7f3a") ?? false)
        XCTAssertNotEqual(appState.combinedHermesGroups[mac.id], appState.combinedHermesGroups[vps.id])
        appState.combinedDashboardChats[mac.id]?.cronIDs = ["cron-run-7f3a", "42"]
        let evidence = appState.combinedHermesEvidence
        XCTAssertTrue(evidence[mac.id]?.contains("cron-run-7f3a") ?? false, "its cron runs are its evidence")
        XCTAssertTrue(evidence[vps.id]?.contains("cron-run-7f3a") ?? false, "as this one's cron rows are")
        XCTAssertFalse(evidence[mac.id]?.contains("42") ?? true, "never a placeholder number")
        XCTAssertEqual(appState.combinedHermesGroups[mac.id], appState.combinedHermesGroups[vps.id])
        XCTAssertEqual(appState.combinedProfileStrip(own: ["default"]).count, 2, "its profile shows once")
        appState.combinedDashboardChats[mac.id]?.cronIDs = ["42"]
        appState.cronSessions = [SessionSummary(id: "42", alternateIds: [], title: "Daily brief", model: "Hermes",
                                                updatedLabel: "now", profile: "default", source: .cron, isActive: false,
                                                isArchived: false, lineageRootId: nil)]
        XCTAssertFalse(appState.combinedHermesEvidence[mac.id]?.contains("42") ?? false,
                       "a placeholder number any Hermes could give isn't evidence")
        XCTAssertFalse(appState.combinedHermesEvidence[vps.id]?.contains("42") ?? false)
        appState.cronSessions = ownCron
        appState.combinedDashboardChats[mac.id]?.cronIDs = []
        let ownSessions = appState.sessions
        appState.sessions = [SessionSummary(id: "mac-2", alternateIds: [], title: "Old", model: "Hermes", updatedLabel: "now",
                                            profile: "default", source: .chat, isActive: false, isArchived: false, lineageRootId: nil)]
        XCTAssertEqual(appState.combinedProfileStrip(own: ["default"]).map(\.id),
                       [CombinedBotsHomeOrder.key(mac.id, "atlas"), CombinedBotsHomeOrder.key(vps.id, "default")])
        XCTAssertEqual(appState.combinedHermesGroups[mac.id], appState.combinedHermesGroups[vps.id])
        appState.sessions = ownSessions
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
        XCTAssertEqual(counts.cronReads.count, 2, "cron ids stand for half an hour on one connection")
        // With the phone's scene in the background no read runs, except
        // the one CarPlay's list of a far agent's chats asks for while the
        // car's voice screen is up.
        appState.isSceneActive = false
        let readsBefore = counts.reads.count
        await appState.readOtherCombinedDashboardsChats(force: true, only: mac.id)
        XCTAssertEqual(counts.reads.count, readsBefore)
        appState.isCarPlayVoiceSurfaceActive = true
        await appState.readOtherCombinedDashboardsChats(force: true, only: mac.id, forCar: true)
        XCTAssertGreaterThan(counts.reads.count, readsBefore, "the car's read runs")
        appState.isCarPlayVoiceSurfaceActive = false
        appState.isSceneActive = true
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
        // Cron evidence past its half hour: one profile's cron read failing
        // keeps what the last full read gave, to read again next time;
        // every profile answering with none clears it (#2800 review).
        // The evidence comes from a full read that every profile answered
        // (issue 2810), not seeded by hand.
        appState.combinedDashboardChats[mac.id]?.cronIDs = []
        appState.combinedDashboardChats[mac.id]?.cronAt = .distantPast
        await appState.readOtherCombinedDashboardsChats(force: true)
        XCTAssertEqual(appState.combinedDashboardChats[mac.id]?.cronIDs, ["cron-mac-1"], "a full read records it")
        appState.combinedDashboardChats[mac.id]?.cronAt = .distantPast
        appState.keptDashboardJSONReader = { bridge, path in
            if path.contains("source=cron"), path.contains("profile=atlas") { throw URLError(.timedOut) }
            return try await reader(bridge, path)
        }
        await appState.readOtherCombinedDashboardsChats(force: true)
        XCTAssertEqual(appState.combinedDashboardChats[mac.id]?.cronIDs, ["cron-mac-1"])
        XCTAssertEqual(appState.combinedDashboardChats[mac.id]?.cronAt, .distantPast)
        appState.keptDashboardJSONReader = { bridge, path in
            if path.contains("source=cron") { return ["sessions": [Any]()] }
            return try await reader(bridge, path)
        }
        await appState.readOtherCombinedDashboardsChats(force: true)
        XCTAssertEqual(appState.combinedDashboardChats[mac.id]?.cronIDs, [])
        XCTAssertNotEqual(appState.combinedDashboardChats[mac.id]?.cronAt, .distantPast)
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
        // Its push opens in place now (testANotificationFromAKeptDashboardOpensInPlaceThroughItsKeptConnection);
        // a switch there takes up its kept connection.
        await appState.switchDashboard(to: mac.id)
        await waitUntil { appState.activeDashboardID == mac.id && appState.client === outgoing }
        XCTAssertTrue(appState.client === outgoing, "switched to through the kept connection")
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

    /// A strip chip whose profile its Hermes deleted since the last read
    /// switches nothing, leaves the strip and its chats and waits go;
    /// neither dashboard's All changes, and a switch whose own list
    /// doesn't name the profile leaves its All as it was (issue 2646).
    func testAStaleProfileChipOfAKeptDashboardSwitchesNothingAndLeavesTheStrip() async throws {
        final class Lists {
            var profiles: [String] = ["default", "atlas"]
            var fails = false
            var reads = 0
            var duringAtlasWaits: (@MainActor () -> Void)?
        }
        final class Loaded { weak var app: AppState?; var profiles: [String]? }
        let lists = Lists()
        let loaded = Loaded()
        var operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        operations.mintTicket = { _ in "fresh-ticket" }
        // The switch's own profile list, as its Hermes gives it.
        operations.loadProfiles = { if let profiles = loaded.profiles { loaded.app?.profiles = profiles } }
        let (appState, mac, vps, _, _) = try await combinedDashboards(operations: operations)
        loaded.app = appState
        await appState.switchDashboard(to: vps.id)
        let kept = try XCTUnwrap(appState.keptDashboardRuntimes[mac.id])
        appState.keptDashboardJSONReader = { bridge, path in
            XCTAssertTrue(bridge === kept.bridge, "read through the kept connection")
            if path.contains(NeedsYouStore.path) {
                guard path.contains("profile=atlas") else { return ["waiting": []] }
                if let during = lists.duringAtlasWaits { await MainActor.run { during() } }
                return ["waiting": [[
                    "id": "w2", "kind": "approval", "session_ids": ["atlas-1"],
                    "title": "Garden", "summary": "water", "at": 1_000,
                ]]]
            }
            if path == "/api/profiles" {
                lists.reads += 1
                if lists.fails { throw URLError(.timedOut) }
                return ["profiles": lists.profiles]
            }
            guard path.contains("/api/profiles/sessions") else { return [:] }
            let profile = path.contains("profile=atlas") ? "atlas" : "default"
            return ["sessions": [
                ["id": "\(profile)-1", "title": "T", "message_count": 3, "profile": profile, "last_active": 1_500],
            ]]
        }
        await appState.readOtherCombinedDashboardsChats()
        appState.combinedBotsHomeOrder = []
        XCTAssertEqual(appState.combinedProfileStrip(own: ["default"]).map(\.id), [
            CombinedBotsHomeOrder.key(mac.id, "default"), CombinedBotsHomeOrder.key(mac.id, "atlas"),
            CombinedBotsHomeOrder.key(vps.id, "default"),
        ])
        appState.needsYou.applyOther(
            [NeedsYouItem(waitID: "w-atlas", profile: "atlas", kind: .approval, sessionIDs: ["atlas-1"])],
            profile: "atlas", dashboardID: mac.id, isOpenChat: { _ in false }
        )
        XCTAssertEqual(appState.needsYou.otherDashboards[mac.id]?.count, 1)
        appState.allProfilesChatsSettings[dashboard: vps.id].isOn = true
        appState.allProfilesChatsSettings[dashboard: mac.id].isOn = true

        // Still listed, read anew at the tap though the last list is fresh.
        let readsBefore = lists.reads
        let listed = await appState.combinedProfileStillListed("Atlas", in: mac.id)
        XCTAssertTrue(listed)
        XCTAssertEqual(lists.reads, readsBefore + 1, "asked anew at the tap")
        // No list to be had says nothing against the chip.
        lists.fails = true
        let unread = await appState.combinedProfileStillListed("atlas", in: mac.id)
        XCTAssertTrue(unread)
        lists.fails = false

        // Deleted on Mac's Hermes since, after a visit there left it
        // remembered.
        appState.rememberActiveProfile("atlas", for: mac.id)
        lists.profiles = ["default"]
        let switched = await appState.switchForCombinedProfile(in: mac.id, profile: "atlas")
        XCTAssertFalse(switched)
        XCTAssertEqual(appState.activeDashboardID, vps.id, "nothing switches")
        XCTAssertNil(appState.rememberedActiveProfile(for: mac.id), "nor resumes there on it later")
        XCTAssertTrue(appState.allProfilesChatsSettings[dashboard: mac.id].isOn, "its All stays on")
        XCTAssertTrue(appState.allProfilesChatsSettings[dashboard: vps.id].isOn, "this one's too")
        XCTAssertEqual(appState.combinedProfileStrip(own: ["default"]).map(\.id), [
            CombinedBotsHomeOrder.key(mac.id, "default"), CombinedBotsHomeOrder.key(vps.id, "default"),
        ], "the chip leaves the strip")
        XCTAssertEqual(appState.combinedDashboardChats[mac.id]?.sessions.map(\.id), ["default-1"], "its chats leave All")
        XCTAssertNil(appState.needsYou.otherDashboards[mac.id], "its waits leave Needs you")

        // A waits pass that read the old list before the tap brings none
        // of its waits back.
        lists.profiles = ["default", "atlas"]
        appState.keptDashboardProfiles[mac.id]?.at = .distantPast
        lists.duringAtlasWaits = { appState.keptDashboardProfiles[mac.id]?.profiles = ["default"] }
        await appState.readOtherCombinedDashboardsNeedsYou()
        XCTAssertNil(appState.needsYou.otherDashboards[mac.id], "the deleted profile's wait stays out")
        lists.duringAtlasWaits = nil

        // Listed when tapped, but not by the switch's own list: its All
        // stays as it was and nothing is picked.
        loaded.profiles = ["default"]
        let landed = await appState.switchForCombinedProfile(in: mac.id, profile: "atlas")
        XCTAssertFalse(landed)
        XCTAssertEqual(appState.activeDashboardID, mac.id)
        XCTAssertTrue(appState.allProfilesChatsSettings[dashboard: mac.id].isOn, "its All stays on")
        appState.allProfilesChatsSettings[dashboard: vps.id] = AllProfilesChatsSettings.Dashboard()
        appState.allProfilesChatsSettings[dashboard: mac.id] = AllProfilesChatsSettings.Dashboard()
    }

    /// Group Chats in a combined group: another dashboard's rooms, read
    /// through its kept connection, show beside this dashboard's, and a
    /// room shows once, under the dashboard you talk in it from: the one
    /// whose Hermes hosts it, else the first with a copy (Eric, 2026-11-20:
    /// who you were in a room went with the dashboard on screen).
    func testGroupChatsShowEveryCombinedDashboardsRoomsOnceEach() async throws {
        final class Counts { var rooms = 0 }
        let counts = Counts()
        var operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        operations.mintTicket = { _ in "fresh-ticket" }
        let (appState, mac, vps, outgoing, _) = try await combinedDashboards(operations: operations)
        await appState.switchDashboard(to: vps.id)
        func room(_ id: String, _ members: [String], updated: Double = 1) -> GroupRoom {
            GroupRoom(roomID: id, name: id.capitalized,
                      members: members.map { GroupMember(memberID: $0, profile: $0, handle: $0, displayName: nil, target: [:], extra: [:]) },
                      authorityGatewayID: "gw", authorityEpoch: 1, revision: 1, createdAt: 0, updatedAt: updated,
                      disbandedAt: nil, latestSeq: nil)
        }
        func copy(_ id: String, _ members: [String]) -> [String: Any] {
            ["room_id": id, "name": id.capitalized, "link": "lk-\(id)", "from": "Sam", "status": "started",
             "members": members.map { ["member_id": $0, "handle": $0] }, "yours": [[String: Any]](),
             "state": ["working": false] as [String: Any], "last_seq": 1, "updated_at": 1.0]
        }
        // Mac hosts "trip" (its bot and one of VPS' over the own Link) and
        // "plans", and has a copy of Sam's "zoo"; VPS has copies of "trip"
        // and "zoo".
        appState.keptDashboardRoomsReader = { client in
            XCTAssertTrue(client === outgoing, "read through the kept client")
            counts.rooms += 1
            return [room("trip", ["raiden", "furina"], updated: 2), room("plans", ["raiden"], updated: 3)]
        }
        appState.keptDashboardJSONReader = { _, path in
            if path == NotifierPluginStatus.path { return ["ok": true, "capabilities": [RoomCopiesClient.capability]] }
            if path == RoomCopiesClient.path { return ["ok": true, "copies": [copy("zoo", ["sam-bot", "nahida"])]] }
            throw URLError(.badURL)
        }
        await appState.readOtherCombinedDashboardsRooms()
        XCTAssertEqual(counts.rooms, 1)
        XCTAssertEqual(appState.combinedDashboardRooms[mac.id]?.rooms.map(\.roomID), ["trip", "plans"])
        XCTAssertEqual(appState.combinedDashboardRooms[mac.id]?.copies.map(\.roomID), ["zoo"])
        // Read again only past a minute; a failed read keeps what it showed.
        await appState.readOtherCombinedDashboardsRooms()
        XCTAssertEqual(counts.rooms, 1)
        appState.keptDashboardRoomsReader = { _ in throw URLError(.timedOut) }
        await appState.readOtherCombinedDashboardsRooms(force: true)
        XCTAssertEqual(appState.combinedDashboardRooms[mac.id]?.rooms.map(\.roomID), ["trip", "plans"])
        // A read out while Mac is opened and left again (kept anew, on the
        // same client) doesn't replace the lists that visit showed (#3049).
        appState.keptDashboardRoomsReader = { _ in
            if let kept = appState.keptDashboardRuntimes[mac.id] {
                appState.keptDashboardRuntimes[mac.id] = KeptDashboardRuntime(
                    client: kept.client, bridge: kept.bridge, connection: kept.connection,
                    keptAt: kept.keptAt.addingTimeInterval(1), runtime: kept.runtime)
            }
            return [room("stale", ["raiden"])]
        }
        await appState.readOtherCombinedDashboardsRooms(force: true)
        XCTAssertEqual(appState.combinedDashboardRooms[mac.id]?.rooms.map(\.roomID), ["trip", "plans"],
                       "a read started before the dashboard was kept again is dropped")
        XCTAssertTrue(appState.keptDashboardRuntimes[mac.id]?.client === outgoing, "still kept on the same client")
        appState.keptDashboardRoomsReader = { _ in throw URLError(.timedOut) }

        appState.notifierPlugin = NotifierPluginStatus(state: .reported(
            version: NotifierPluginStatus.recommendedVersion, capabilities: [RoomCopiesClient.capability]))
        appState.groupChatPhase = .available
        appState.groupRoomsListed = true
        appState.groupRooms = [room("standup", ["furina"])]
        let vpsCopies = [copy("trip", ["raiden", "furina"]), copy("zoo", ["sam-bot", "nahida"]), copy("solo", ["sam-bot"])]
        appState.linkedRoomCopies = LinkedRoomCopies(dashboardID: vps.id, copies: vpsCopies.compactMap(RoomCopiesClient.copy))
        // The one on screen's rooms are kept as it shows them, so leaving it
        // shows them at once, and stand as unread, so they're read anew there.
        await appState.readOtherCombinedDashboardsRooms()
        XCTAssertEqual(appState.combinedDashboardRooms[vps.id]?.rooms.map(\.roomID), ["standup"])
        XCTAssertEqual(appState.combinedDashboardRooms[vps.id]?.copies.map(\.roomID), ["trip", "zoo", "solo"])
        XCTAssertEqual(appState.combinedDashboardRooms[vps.id]?.at, .distantPast)
        // VPS' copy of Mac's "trip" leaves for Mac's own room, and its copy
        // of Sam's "zoo" for Mac's, which comes first in Saved Dashboards.
        XCTAssertEqual(appState.shownLinkedRoomCopyRows.map(\.roomID), ["solo"])
        let tiles = appState.otherCombinedDashboardsRoomTiles
        XCTAssertEqual(tiles.map(\.roomID), ["trip", "plans", "zoo"], "Mac's as Mac shows them: its rooms, then its copies")
        XCTAssertEqual(Set(tiles.map(\.dashboardID)), [mac.id])
        if case .hosted = tiles[0].kind {} else { XCTFail("Mac's own room opens as Mac's") }
        if case .copy = tiles[2].kind {} else { XCTFail("Sam's room opens from Mac's copy") }
        // Mac comes before VPS in Saved Dashboards, so its group chats show
        // before VPS' own, in Mac's own room order: opening one, in place
        // or through a switch, moves nothing (Eric, 2026-11-21).
        let macOrderKey = BotOrder.roomStorageKey(scope: AppState.dashboardPreferenceBucket(mac.id))
        BotOrder(names: ["plans", "trip"], kind: .rooms).save(to: appState.defaults, key: macOrderKey)
        let around = appState.combinedRoomTilesAroundThisDashboard
        XCTAssertEqual(around.before.map(\.roomID), ["plans", "trip", "zoo"])
        XCTAssertTrue(around.after.isEmpty)
        // Saved after VPS, Mac's go after VPS' own instead; Sam's "zoo"
        // now shows from VPS' copy, VPS being the first with one.
        let savedOrder = appState.savedDashboardRegistry
        appState.savedDashboardRegistry = SavedDashboardRegistry(activeDashboardID: vps.id, dashboards: Array(savedOrder.dashboards.reversed()))
        let aroundAfter = appState.combinedRoomTilesAroundThisDashboard
        XCTAssertTrue(aroundAfter.before.isEmpty)
        XCTAssertEqual(aroundAfter.after.map(\.roomID), ["plans", "trip"])
        XCTAssertEqual(appState.shownLinkedRoomCopyRows.map(\.roomID), ["zoo", "solo"])
        appState.savedDashboardRegistry = savedOrder
        appState.defaults.removeObject(forKey: macOrderKey)
        // A room id another Hermes uses for another room (no member shared)
        // is not the same room.
        appState.linkedRoomCopies = LinkedRoomCopies(dashboardID: vps.id,
                                                     copies: [copy("plans", ["sam-bot"])].compactMap(RoomCopiesClient.copy))
        XCTAssertEqual(appState.shownLinkedRoomCopyRows.map(\.roomID), ["plans"])
        // One Hermes saved at two addresses: a room both list shows once,
        // as this dashboard's.
        appState.groupRooms = [room("plans", ["raiden"])]
        XCTAssertFalse(appState.otherCombinedDashboardsRoomTiles.contains { $0.roomID == "plans" })
        // Out of the group, its rooms go.
        appState.forgetCombinedDashboardLists(mac.id)
        XCTAssertTrue(appState.otherCombinedDashboardsRoomTiles.isEmpty)
        appState.linkedRoomCopies = nil
        appState.groupRooms = []
        appState.groupRoomsListed = false
        appState.groupChatPhase = .idle
    }

    /// Another combined dashboard's group chat opens in place on that
    /// dashboard's own runtime (no-switch stage 2): no switch, its reads and
    /// sends through its kept connection, its lists on its own runtime, a
    /// Needs you wait in it opens it in place too, and it closes when that
    /// connection is let go.
    func testAKeptDashboardsGroupChatOpensInPlaceOnItsRuntime() async throws {
        final class Calls { var clients: [String: [ObjectIdentifier]] = [:]; var sent: [String] = [] }
        let calls = Calls()
        // What Bot Mode's open mark says while the room is read (issue 2995).
        final class Marks { var probe: (() -> Void)?; var seen: [String?] = [] }
        let marks = Marks()
        let trip = GroupRoom(roomID: "trip", name: "Trip", members: [], authorityGatewayID: "gw", authorityEpoch: 1,
                             revision: 1, createdAt: 0, updatedAt: 1, disbandedAt: nil, latestSeq: nil)
        func note(_ name: String, _ client: HermesClient) {
            calls.clients[name, default: []].append(ObjectIdentifier(client))
        }
        let groups = GroupChatLifecycleOperations(
            capabilities: { client in
                note("capabilities", client)
                return GroupCapabilities(protocolVersion: 2, driverReady: true, authorityGatewayID: "gw", features: [],
                                         methods: GroupWire.requiredMethods.union(["groups.attachment.upload"]), maxLogLimit: 500)
            },
            list: { client in
                note("list", client)
                return ([trip], nil)
            },
            state: { client, _ in
                note("state", client)
                marks.probe?()
                return (trip, nil)
            },
            log: { client, _, sinceSeq, _ in
                note("log", client)
                return GroupLogPage(events: [], cursor: sinceSeq, latestSeq: 0, hasMore: false,
                                    authorityGatewayID: "gw", authorityEpoch: 1)
            },
            send: { client, _, _, text, _ in
                note("send", client)
                calls.sent.append(text)
                throw URLError(.timedOut)
            },
            uploadAttachment: { client, _, _, kind, name, mime, _ in
                note("upload", client)
                return GroupRoomAttachment(attachmentID: "att-1", kind: kind, name: name, size: 9, mime: mime)
            }
        )
        var operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        operations.mintTicket = { _ in "fresh-ticket" }
        let (appState, mac, vps, outgoing, _) = try await combinedDashboards(operations: operations, groups: groups)
        await appState.switchDashboard(to: vps.id)
        let kept = try XCTUnwrap(appState.runtime(for: mac.id))
        XCTAssertFalse(kept === appState.runtimeOnScreen)
        marks.probe = { marks.seen.append(appState.botChatOpening) }
        defer { marks.probe = nil }

        await appState.openCombinedRoom(CombinedRoomTile(dashboardID: mac.id, kind: .hosted(trip)))
        XCTAssertFalse(marks.seen.isEmpty, "the room was read")
        XCTAssertTrue(marks.seen.allSatisfy { $0 == nil }, "opened from Chats: no Bots mark")

        XCTAssertEqual(appState.activeDashboardID, vps.id, "no switch")
        XCTAssertEqual(appState.activeRoomSurface?.dashboardID, mac.id)
        XCTAssertEqual(appState.activeRoomSurface?.room.roomID, "trip")
        XCTAssertTrue(appState.farRoomRuntime === kept)
        for name in ["capabilities", "list", "state", "log"] {
            XCTAssertEqual(calls.clients[name]?.isEmpty, false, "\(name) was read")
            XCTAssertEqual(Set(calls.clients[name] ?? []), [ObjectIdentifier(outgoing)], "\(name) through the kept connection")
        }
        XCTAssertEqual(kept.groupRooms.map(\.roomID), ["trip"], "its rooms on its own runtime")
        XCTAssertTrue(appState.groupRooms.isEmpty, "the screen's stay its own")
        XCTAssertTrue(appState.readingRoomRuntime { appState.groupCapabilities?.supports("groups.send") == true })
        XCTAssertNil(appState.groupCapabilities, "the screen's capabilities untouched")

        // A send from the room's screen goes through the room's dashboard.
        await appState.sendGroupRoomMessage("Hello from VPS")
        XCTAssertEqual(calls.sent, ["Hello from VPS"])
        XCTAssertEqual(Set(calls.clients["send"] ?? []), [ObjectIdentifier(outgoing)])
        XCTAssertEqual(appState.activeDashboardID, vps.id)

        // A file staged there goes up to the room's own Hermes too.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-plan.pdf")
        try Data("%PDF-1.7\n".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let pdf = Attachment(id: UUID().uuidString, name: "plan.pdf", uri: url.absoluteString,
                             mimeType: "application/pdf", kind: .document)
        let message = try await appState.roomMessage("", attachments: [pdf])
        XCTAssertEqual(message.attachments.map(\.attachmentID), ["att-1"])
        XCTAssertEqual(Set(calls.clients["upload"] ?? []), [ObjectIdentifier(outgoing)], "uploaded through the kept connection")

        // A wait in that room, from Needs you, opens it in place too.
        appState.closeRoomSurface()
        XCTAssertNil(appState.activeRoomSurface)
        var wait = NeedsYouItem(waitID: "w-trip", profile: "default", kind: .approval, sessionIDs: ["s"], roomID: "trip")
        wait.dashboardID = mac.id
        XCTAssertFalse(appState.isOpenChat(wait))
        appState.openNeedsYou(wait)
        await waitUntil { appState.activeRoomSurface != nil }
        XCTAssertEqual(appState.activeDashboardID, vps.id, "no switch")
        XCTAssertEqual(appState.activeRoomSurface?.dashboardID, mac.id)
        XCTAssertTrue(appState.isOpenChat(wait))
        var own = wait
        own.dashboardID = nil
        // The screen's own room of that id is the one open only when both
        // dashboards are one Hermes saved twice (issue 2631).
        let hermes = appState.combinedHermesGroups
        let oneHermes = hermes[mac.id] != nil && hermes[mac.id] == hermes[vps.id]
        XCTAssertEqual(appState.isOpenChat(own), oneHermes)

        // Its connection let go, the room has nothing to act on and closes.
        appState.dropKeptDashboardRuntime(mac.id)
        XCTAssertNil(appState.activeRoomSurface)
        XCTAssertNil(appState.farRoomRuntime)

        // Not kept connected, it switches there first, and a tap on Bots
        // Home marks the open as Bots' only once the switch has settled,
        // since the switch clears Bot Mode's state (#2993, issue 2995): a
        // mark made before it would be gone. (This harness's switch has no
        // socket to sign in on, so the room itself doesn't open here.)
        marks.probe = nil
        await appState.openCombinedRoom(CombinedRoomTile(dashboardID: mac.id, kind: .hosted(trip)), inBots: true)
        XCTAssertEqual(appState.activeDashboardID, mac.id, "switched there")
        XCTAssertEqual(appState.botChatLatestMark, BotZoomArm.roomKey("trip"), "marked as Bots' after the switch")
        XCTAssertNil(appState.botChatOpening, "cleared once the open ended")
    }

    /// Another combined dashboard's room tiles on Bots Home: which are
    /// talking, read on its own runtime through its kept connection; a drag
    /// moves one among its own dashboard's rooms, and nothing else's.
    func testAKeptDashboardsRoomTilesTalkAndMoveAmongTheirOwn() async throws {
        final class Calls { var states: [String: [ObjectIdentifier]] = [:]; var capabilities: [ObjectIdentifier] = [] }
        let calls = Calls()
        func room(_ id: String) -> GroupRoom {
            GroupRoom(roomID: id, name: id.capitalized, members: [], authorityGatewayID: "gw", authorityEpoch: 1,
                      revision: 1, createdAt: 0, updatedAt: 1, disbandedAt: nil, latestSeq: nil)
        }
        let groups = GroupChatLifecycleOperations(
            capabilities: { client in
                calls.capabilities.append(ObjectIdentifier(client))
                return GroupCapabilities(protocolVersion: 1, driverReady: true, authorityGatewayID: "gw", features: [],
                                         methods: GroupWire.requiredMethods.union(["groups.disband"]), maxLogLimit: 500)
            },
            state: { client, roomID in
                calls.states[roomID, default: []].append(ObjectIdentifier(client))
                let working = roomID == "trip"
                return (room(roomID), GroupDriverStatus(running: working, working: working, blocked: false,
                                                        counts: [:], pendingActions: []))
            }
        )
        var operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        operations.mintTicket = { _ in "fresh-ticket" }
        let (appState, mac, vps, outgoing, _) = try await combinedDashboards(operations: operations, groups: groups)
        await appState.switchDashboard(to: vps.id)
        appState.keptDashboardRoomsReader = { _ in [room("trip"), room("plans")] }
        appState.keptDashboardJSONReader = { _, path in
            if path == NotifierPluginStatus.path { return ["ok": true, "capabilities": [String]()] }
            throw URLError(.badURL)
        }
        await appState.readOtherCombinedDashboardsRooms()
        func hosted() -> [String] { appState.otherCombinedDashboardsRoomTiles.map(\.roomID) }
        XCTAssertEqual(hosted(), ["trip", "plans"])
        let tiles = appState.otherCombinedDashboardsRoomTiles
        XCTAssertFalse(tiles.contains { appState.combinedRoomTalking($0) }, "nothing read yet")
        // Kept quietly, none of its rooms opened: what its groups can do unknown.
        appState.keptDashboardRuntimes[mac.id]?.runtime.groupCapabilities = nil
        XCTAssertFalse(appState.canDisbandCombinedRoom(tiles[0]), "its Hermes hasn't said it can yet")
        let screensReads = calls.capabilities.count

        await appState.refreshCombinedRoomTilesIfDue(every: .seconds(12))
        XCTAssertEqual(Set(calls.states["trip"] ?? []), [ObjectIdentifier(outgoing)], "read through the kept connection")
        XCTAssertEqual(tiles.filter { appState.combinedRoomTalking($0) }.map(\.roomID), ["trip"])
        XCTAssertTrue(appState.talkingRoomIDs.isEmpty, "the screen's rooms are its own")
        XCTAssertNil(appState.combinedRoomPicture(tiles[0]), "no picture kept or served")
        XCTAssertEqual(Array(calls.capabilities.dropFirst(screensReads)), [ObjectIdentifier(outgoing)],
                       "what its groups can do, read through the kept connection")
        XCTAssertTrue(appState.canDisbandCombinedRoom(tiles[0]), "its Hermes said it can")
        XCTAssertFalse(appState.canEditCombinedRoomSettings(tiles[0]), "no groups.context there: no Group Settings")
        // Within the tick, not read again.
        await appState.refreshCombinedRoomTilesIfDue(every: .seconds(12))
        XCTAssertEqual(calls.states["trip"]?.count, 1)

        // A drag takes the place of a room of its own dashboard, kept for it.
        XCTAssertNil(appState.combinedRoomNeighbor(tiles[0], by: -1), "the first: nothing earlier")
        XCTAssertEqual(appState.combinedRoomNeighbor(tiles[0], by: 1)?.id, tiles[1].id, "VoiceOver's Move Later drops on it")
        // The last dropped past the end moves nothing: no haptic, no order saved.
        XCTAssertFalse(appState.dropCombinedRoom(tiles[1].id, onto: nil, dashboardID: mac.id), "nothing moved")
        XCTAssertEqual(hosted(), ["trip", "plans"])
        XCTAssertTrue(appState.dropCombinedRoom(tiles[1].id, onto: tiles[0].id, dashboardID: mac.id))
        XCTAssertEqual(hosted(), ["plans", "trip"])
        // This dashboard's room, or one named for another dashboard, moves nothing.
        XCTAssertFalse(appState.dropCombinedRoom("plans", onto: tiles[1].id, dashboardID: mac.id), "refused: no haptic")
        XCTAssertFalse(appState.dropCombinedRoom(tiles[0].id, onto: tiles[1].id, dashboardID: vps.id))
        XCTAssertEqual(hosted(), ["plans", "trip"])
        XCTAssertTrue(appState.groupRoomOrder.isEmpty, "the screen's order untouched")
        await appState.refreshCombinedRoomTilesIfDue(every: .seconds(1))
        XCTAssertEqual(calls.capabilities.count, screensReads + 1, "known: not read again on a later tick")
        // Its Hermes serves groups.context: Group Settings in its menu.
        appState.keptDashboardRuntimes[mac.id]?.runtime.groupCapabilities = GroupCapabilities(
            protocolVersion: 1, driverReady: true, authorityGatewayID: "gw", features: [],
            methods: GroupWire.requiredMethods.union(["groups.context"]), maxLogLimit: 500)
        XCTAssertTrue(appState.canEditCombinedRoomSettings(tiles[0]))
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
        // The switch kept Mac's chats; this harness's two dashboards share
        // one fake host, so its list would make them one Hermes (issue 2741).
        appState.combinedDashboardChats[mac.id] = nil
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

        let requestsBefore = appState.botChatOpenRequests
        appState.openCombinedBot(section.bots[0], in: mac.id)
        XCTAssertEqual(appState.botZoom.tapped, "raiden", "the chat grows out of the portrait")
        await waitUntil { appState.activeDashboardID == mac.id && appState.client === outgoing }
        XCTAssertTrue(appState.client === outgoing, "opened through the kept connection")
        // The tap's link carries the tap's own request (`counted:`), so the
        // open after the switch counts no second one (issue 2810).
        await waitUntil { appState.activeBotChatProfile == "raiden" || appState.linkedBotChatWaitingRequest != nil }
        XCTAssertEqual(appState.botChatOpenRequests, requestsBefore &+ 1, "one tap, one request")
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
    func testPulseHasAChipPerCombinedDashboardAndOneShowsItsFeedInPlace() async throws {
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
        XCTAssertEqual(chips.map(\.isShown), [false, true])
        XCTAssertEqual(chips.first?.badge.letter, "M")
        // Read again only past its age; a failed read keeps the count.
        await appState.readOtherCombinedDashboardsPulse()
        XCTAssertEqual(counts.reads.count, 1)
        appState.keptDashboardJSONReader = { _, _ in throw URLError(.timedOut) }
        await appState.readOtherCombinedDashboardsPulse(force: true)
        XCTAssertEqual(appState.pulseDashboardChips.first?.unseen, 3)

        // A chip shows its Pulse in place: no switch, so a call goes on.
        appState.isNativeHermesCallActive = true
        // What its plugin serves is read on its own runtime first, signed in
        // quietly beside this one without it.
        XCTAssertEqual(kept.runtime.notifierPlugin.state, .unknown)
        appState.keptDashboardJSONReader = { bridge, path in
            XCTAssertTrue(bridge === kept.bridge, "read through the kept connection")
            counts.reads.append(path)
            if path == NotifierPluginStatus.path { return ["ok": true, "capabilities": [PulseClient.explainsCapability]] }
            return ["cards": [], "unseen": 3]
        }
        appState.openCombinedPulse(mac.id)
        await appState.readyShownPulseRuntime()
        XCTAssertEqual(counts.reads.last, NotifierPluginStatus.path)
        XCTAssertEqual(appState.activeDashboardID, vps.id, "no switch")
        XCTAssertEqual(appState.pulseDashboardID, mac.id)
        XCTAssertTrue(appState.pulseRuntime === kept.runtime)
        XCTAssertEqual(appState.pulseDashboardChips.map(\.isShown), [true, false])
        XCTAssertEqual(appState.pulseDashboardChips.map(\.switches), [false, false], "a kept chip shows in place")
        XCTAssertEqual(appState.shownPulseClient.dashboardID, mac.id, "its requests go to its own dashboard")
        XCTAssertTrue(appState.pulseExplainsLearning, "what its plugin serves")
        appState.readingPulseRuntime { appState.pulseUnseen = 0 }
        XCTAssertEqual(kept.runtime.pulseUnseen, 0)
        XCTAssertEqual(appState.pulseUnseen, 1, "the one on screen's count stays")
        kept.runtime.pulseFeedAppliedAt = (mac.id, Date())
        XCTAssertEqual(appState.pulseDashboardChips.map(\.unseen), [0, 1], "shown, its chip counts its own runtime's")
        XCTAssertEqual(counts.mints, 0, "no sign-in")
        // The one on screen's chip goes back to it.
        appState.openCombinedPulse(vps.id)
        XCTAssertEqual(appState.pulseDashboardID, vps.id)
        XCTAssertEqual(appState.pulseDashboardChips.map(\.unseen), [0, 1], "left, the page's read there is the newer")
        await appState.readOtherCombinedDashboardsPulse(force: true)
        XCTAssertEqual(appState.pulseDashboardChips.map(\.unseen), [3, 1], "then a newer background read's")
        XCTAssertFalse(appState.pulseExplainsLearning, "the one on screen's plugin")
        appState.isNativeHermesCallActive = false

        // A step tapped on Mac's Pulse, after the screen's chip was picked:
        // no switch for a page that left it.
        let leftStep = await appState.switchForFarPulseStep(for: mac.id)
        XCTAssertFalse(leftStep, "the page left Mac's Pulse")
        XCTAssertEqual(appState.activeDashboardID, vps.id, "no switch")

        // A step that opens a chat there switches first, through the kept
        // connection, until far chats open in place.
        appState.openCombinedPulse(mac.id)
        // A step from the one on screen's Pulse doesn't go on another's.
        let screensStep = await appState.switchForFarPulseStep(for: vps.id)
        XCTAssertFalse(screensStep, "the page shows Mac's now")
        XCTAssertEqual(appState.activeDashboardID, vps.id)
        let stepGoes = await appState.switchForFarPulseStep(for: mac.id)
        XCTAssertTrue(stepGoes)
        XCTAssertEqual(appState.activeDashboardID, mac.id)
        XCTAssertTrue(appState.client === outgoing, "switched through the kept connection")
        XCTAssertEqual(counts.mints, 0, "no sign-in")
        XCTAssertNil(appState.pulseShownDashboardID)
        XCTAssertTrue(appState.pulseDashboardChips.allSatisfy { $0.dashboardID != mac.id || $0.isShown },
                      "on screen, its chip is the page's own")
    }

    /// A dashboard let go while its Pulse shows in place: the page goes back
    /// to the one on screen's, so a runtime kept for it anew doesn't take
    /// the page over.
    func testAPulseShownInPlaceGoesBackToTheScreensWhenItsDashboardIsLetGo() async throws {
        let operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        let (appState, mac, vps, _, _) = try await combinedDashboards(operations: operations)
        await appState.switchDashboard(to: vps.id)
        XCTAssertNotNil(appState.keptDashboardRuntimes[mac.id])
        appState.keptDashboardJSONReader = { _, _ in ["cards": [], "unseen": 2] }
        await appState.readOtherCombinedDashboardsPulse()
        appState.openCombinedPulse(mac.id)
        XCTAssertEqual(appState.pulseDashboardID, mac.id)
        appState.dropKeptDashboardRuntime(mac.id, keepingLists: true)
        XCTAssertNil(appState.pulseShownDashboardID)
        XCTAssertEqual(appState.pulseDashboardID, vps.id)
        let dropped = appState.pulseDashboardChips.first { $0.dashboardID == mac.id }
        XCTAssertEqual(dropped?.switches, true, "its chip stays, as its last read, and switches")
        XCTAssertEqual(dropped?.isShown, false)

        appState.isNativeHermesCallActive = true
        appState.openCombinedPulse(mac.id)
        XCTAssertNil(appState.pulseShownDashboardID, "not shown in place: nothing to show it on")
        XCTAssertEqual(appState.activeDashboardID, vps.id, "no switch during a call")
        appState.isNativeHermesCallActive = false
    }

    /// A notification from a combined dashboard kept beside the one on
    /// screen opens its chat in place, on that dashboard's runtime through
    /// its kept connection (no-switch stage 2): no switch, no ticket, no new
    /// socket.
    func testANotificationFromAKeptDashboardOpensInPlaceThroughItsKeptConnection() async throws {
        final class Counts { var connects = 0; var mints = 0; var opened: [(ObjectIdentifier, String)] = [] }
        let counts = Counts()
        var operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        operations.connectClient = { _ in counts.connects += 1 }
        operations.mintTicket = { _ in
            counts.mints += 1
            return "fresh-ticket"
        }
        operations.openSession = { client, sessionID, _ in
            counts.opened.append((ObjectIdentifier(client), sessionID))
            return SessionResumeResult(
                sessionId: sessionID,
                messages: [ChatMessage(id: "far-1", role: .assistant, content: "From the Mac", timestamp: "ts-f1")],
                snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
            )
        }
        let (appState, mac, vps, outgoing, _) = try await combinedDashboards(operations: operations)
        await appState.switchDashboard(to: vps.id)
        let kept = try XCTUnwrap(appState.keptDashboardRuntimes[mac.id])
        XCTAssertTrue(kept.client === outgoing)
        var row = SessionSummary(id: "session-a", alternateIds: [], title: "Release prep", model: "Hermes", updatedLabel: "now",
                                 profile: "default", source: .chat, isActive: false, isArchived: false, lineageRootId: nil)
        row.combinedDashboardID = mac.id
        appState.combinedDashboardChats[mac.id] = CombinedDashboardChats(
            bridge: ObjectIdentifier(kept.bridge), profiles: ["default"], sessions: [row], at: Date()
        )
        // Its bots are read (none), so a Bot Chat's push could be told apart.
        appState.combinedDashboardBots[mac.id] = CombinedDashboardBots(
            client: ObjectIdentifier(kept.client), bots: [], avatars: [:], at: Date()
        )

        let open = Task { @MainActor in
            await appState.openNotificationTargetOutcome(ConduitNotificationTarget(
                profile: "default", sessionId: "session-a", dashboardID: mac.id, type: "response.ready"
            ))
        }
        await waitUntil { appState.activeSessionId == "session-a" && appState.messages.contains { $0.id == "far-1" } }
        let outcome = await open.value
        XCTAssertEqual(outcome, .opened, "the route waits on the far open")

        XCTAssertEqual(appState.activeDashboardID, vps.id, "no switch")
        XCTAssertEqual(appState.farChatDashboardID, mac.id, "the chat is the Mac's")
        XCTAssertEqual(counts.opened.last?.0, ObjectIdentifier(outgoing), "read through the kept connection")
        XCTAssertTrue(appState.keptDashboardRuntimes[mac.id]?.client === outgoing, "still kept")
        XCTAssertEqual(counts.connects, 0, "no socket is opened")
        XCTAssertEqual(counts.mints, 0, "no ticket is minted")
    }

    func testAWidgetOrSiriChatOfAKeptDashboardOpensInPlaceThroughItsKeptConnection() async throws {
        final class Counts { var connects = 0; var opened: [(ObjectIdentifier, String)] = [] }
        let counts = Counts()
        var operations = switchLifecycleOperations(workCatalog: []) { _ in [] }
        operations.connectClient = { _ in counts.connects += 1 }
        operations.openSession = { client, sessionID, _ in
            counts.opened.append((ObjectIdentifier(client), sessionID))
            return SessionResumeResult(
                sessionId: sessionID,
                messages: [ChatMessage(id: "far-w1", role: .assistant, content: "From the Mac", timestamp: "ts-w1")],
                snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
            )
        }
        let (appState, mac, vps, outgoing, _) = try await combinedDashboards(operations: operations)
        await appState.switchDashboard(to: vps.id)
        let kept = try XCTUnwrap(appState.keptDashboardRuntimes[mac.id])
        var row = SessionSummary(id: "session-a", alternateIds: [], title: "Release prep", model: "Hermes", updatedLabel: "now",
                                 profile: "default", source: .chat, isActive: false, isArchived: false, lineageRootId: nil)
        row.combinedDashboardID = mac.id
        appState.combinedDashboardChats[mac.id] = CombinedDashboardChats(
            bridge: ObjectIdentifier(kept.bridge), profiles: ["default"], sessions: [row], at: Date()
        )
        func link(_ sessionID: String) throws -> WidgetLaunchLink {
            try XCTUnwrap(WidgetLaunchLink(
                action: .resume,
                workspace: WidgetWorkspaceID(dashboardID: mac.id, profile: "default"),
                reference: WidgetConversationReference(kind: .dashboard, scopeProfile: "default", botName: nil,
                                                       botLabel: nil, sessionID: sessionID, isUnverified: false)
            ))
        }

        XCTAssertFalse(appState.openWidgetChatInPlace(try link("session-a")), "its bots unread, it switches")
        appState.combinedDashboardBots[mac.id] = CombinedDashboardBots(
            client: ObjectIdentifier(outgoing), bots: [], avatars: [:], at: Date()
        )
        XCTAssertFalse(appState.openWidgetChatInPlace(try link("session-unlisted")), "a chat its list doesn't hold switches")
        appState.pulseRememberedHomes[mac.id.uuidString] = "session-a"
        XCTAssertFalse(appState.openWidgetChatInPlace(try link("session-a")), "its Pulse chat switches")
        appState.pulseRememberedHomes[mac.id.uuidString] = nil
        appState.showVoiceSheet = true
        XCTAssertTrue(appState.isVoiceCallInProgress)
        XCTAssertFalse(appState.openWidgetChatInPlace(try link("session-a")), "during a call it refuses, as the switch's launch does")
        appState.showVoiceSheet = false
        XCTAssertTrue(appState.routeWidgetLaunchURL(try link("session-a").url))
        await waitUntil { appState.activeSessionId == "session-a" && appState.messages.contains { $0.id == "far-w1" } }

        XCTAssertEqual(appState.activeDashboardID, vps.id, "no switch")
        XCTAssertEqual(appState.farChatDashboardID, mac.id, "the chat is the Mac's")
        XCTAssertEqual(counts.opened.last?.0, ObjectIdentifier(outgoing), "read through the kept connection")
        XCTAssertEqual(counts.connects, 0, "no socket is opened")
    }
}
