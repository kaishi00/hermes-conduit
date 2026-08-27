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
    /// observes cancellation exactly like `Task.sleep` would.
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
            openSession: { client, sessionID in
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
        harness.coordinator.rememberSessionID(defaultSession.id, for: "default")
        harness.coordinator.rememberSessionID(fixtures.session.id, for: "work")
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
        let store = persistedCache(from: harness.defaults)
        XCTAssertFalse(
            store.keys.contains { $0.hasPrefix("work|") && !$0.hasSuffix(fixtures.session.id) },
            "Work-namespace entries are limited to work's own sessions, got \(store.keys)"
        )
        XCTAssertEqual(store["work|session-a"], nil)
        for (key, ids) in store where key.hasPrefix("work|") {
            XCTAssertEqual(
                Set(ids),
                Set(["work-message"]),
                "\(key) may only hold profile B's own transcript rows, got \(ids)"
            )
        }
        XCTAssertTrue(
            Set(store.keys).isSubset(of: ["default|session-a", "default|\(defaultSession.id)".lowercased(), "work|\(fixtures.session.id)".lowercased()]),
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

    /// Requirement-level guarantee: even when NO caller cancels or flushes, an
    /// identity change fences the parked operation on its own. Changing
    /// profiles through connect(with:profile:) never touches
    /// `presentationCacheFlushTask`; only the epoch fence stands between the
    /// stale task and profile B's namespace.
    func testIdentityChangeAloneFencesStaleDeferredFlush() async {
        let (gate, park) = makeGatePark()
        let fixtures = workSessionFixtures()
        let harness = makeHarness(
            lifecycleOperations: ChatResumeLifecycleOperations(
                connectClient: { _ in },
                loadCatalog: { _, _ in [self.session(fixtures.session.id, profile: "work")] },
                mintTicket: { _ in "connect-ticket" },
                openSession: { _, sessionID in
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
        harness.coordinator.rememberSessionID(fixtures.session.id, for: "work")
        seedOutgoingTranscript(in: harness.appState, connection: connection, sessionID: "session-a")

        harness.appState.handleStreamEvent(.cwdUpdate(sessionId: "session-a", cwd: "/tmp/a"))
        let parkedOperation = harness.appState.presentationCacheFlushOperationForTesting
        XCTAssertNotNil(parkedOperation)
        await gate.waitUntilEngaged()

        // Profile changes without any explicit flush/cancel around it.
        await harness.appState.connect(with: connection, profile: "work")
        XCTAssertEqual(harness.appState.activeProfile, "work")

        gate.release()
        await parkedOperation?.value

        XCTAssertEqual(
            cachedTimestamp(of: harness.cache, profile: "work", sessionID: "session-a"),
            "",
            "The fenced task must not deposit session-A presentation data into the work namespace"
        )
        XCTAssertNil(
            persistedCache(from: harness.defaults)["work|session-a"],
            "No work-namespaced entry may ever be created for the captured session"
        )
    }
}
