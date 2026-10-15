import XCTest
@testable import Conduit

/// Pins shared with Hermes (#555). An extension of an existing class so the
/// CI planner gets no new class to place.
extension ChatReadStateTests {
    private static let pinHost = "https://hermes.example"
    private static let pinT0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func pinRow(_ id: String, pinned: Bool?, lineageRoot: String? = nil) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: [],
            title: id,
            model: "Hermes",
            updatedLabel: "",
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: false,
            isPinned: pinned,
            lineageRootId: lineageRoot
        )
    }

    private func pinSync(adopted: Bool = false) -> SessionPinSync {
        var sync = SessionPinSync(adopted: adopted ? ["\(Self.pinHost)\u{1F}default"] : [])
        sync.setHost(Self.pinHost)
        return sync
    }

    func testPinsHostWithoutTheFlagKeepsPhonePins() {
        var sync = pinSync()
        let outcome = sync.reconcile(pins: ["a"], listed: [pinRow("a", pinned: nil), pinRow("b", pinned: nil)], profile: "default")
        XCTAssertEqual(outcome, SessionPinSync.Reconciliation(pins: ["a"], uploads: []))
        XCTAssertFalse(sync.supportsPins(profile: "default", host: Self.pinHost))
        XCTAssertFalse(sync.isAdopted(profile: "default"))
    }

    func testPinsFirstSyncUploadsPhonePinsAndTakesHostPins() {
        var sync = pinSync()
        let listed = [pinRow("a", pinned: false), pinRow("b", pinned: true), pinRow("c", pinned: false)]
        let outcome = sync.reconcile(pins: ["a", "gone-from-listing"], listed: listed, profile: "default", now: Self.pinT0)
        XCTAssertEqual(outcome.pins, ["a", "gone-from-listing", "b"], "Host pins join after the phone's, in order")
        XCTAssertEqual(outcome.uploads, [
            SessionPinSync.Upload(pinID: "a", hostID: "a"),
            SessionPinSync.Upload(pinID: "gone-from-listing", hostID: "gone-from-listing"),
        ], "Pins on unlisted chats go up too")
        XCTAssertTrue(sync.supportsPins(profile: "default", host: Self.pinHost))
        XCTAssertFalse(sync.isAdopted(profile: "default"), "Not adopted until the uploads land")
    }

    func testPinsAdoptedOnceUploadsLand() {
        var sync = pinSync()
        _ = sync.reconcile(pins: ["a", "old"], listed: [pinRow("a", pinned: false)], profile: "default", now: Self.pinT0)
        sync.recordWrite(pinID: "a", profile: "default", pinned: true, at: Self.pinT0)
        sync.recordWrite(pinID: "old", profile: "default", pinned: true, at: Self.pinT0)
        sync.uploadSucceeded(pinID: "a", profile: "default")
        sync.uploadSucceeded(pinID: "old", profile: "default")

        // A listing fetched before the upload landed still says unpinned.
        let stale = sync.reconcile(pins: ["a", "old"], listed: [pinRow("a", pinned: false)], profile: "default", now: Self.pinT0)
        XCTAssertEqual(stale, SessionPinSync.Reconciliation(pins: ["a", "old"], uploads: []))
        XCTAssertFalse(sync.isAdopted(profile: "default"))

        let later = Self.pinT0.addingTimeInterval(SessionPinSync.pendingWriteLifetime + 1)
        let confirmed = sync.reconcile(pins: ["a", "old"], listed: [pinRow("a", pinned: true)], profile: "default", now: later)
        XCTAssertEqual(confirmed, SessionPinSync.Reconciliation(pins: ["a", "old"], uploads: []))
        XCTAssertTrue(sync.isAdopted(profile: "default"))
    }

    func testPinsUploadTheHostDidntKeepGoesAgain() {
        var sync = pinSync()
        _ = sync.reconcile(pins: ["a"], listed: [pinRow("a", pinned: false)], profile: "default", now: Self.pinT0)
        sync.recordWrite(pinID: "a", profile: "default", pinned: true, at: Self.pinT0)
        sync.uploadSucceeded(pinID: "a", profile: "default")
        let later = Self.pinT0.addingTimeInterval(SessionPinSync.pendingWriteLifetime + 1)
        let outcome = sync.reconcile(pins: ["a"], listed: [pinRow("a", pinned: false)], profile: "default", now: later)
        XCTAssertEqual(outcome.uploads, [SessionPinSync.Upload(pinID: "a", hostID: "a")])
        XCTAssertFalse(sync.isAdopted(profile: "default"), "Never adopted while the host disagrees")
    }

    func testPinsAdoptedHostDecides() {
        var sync = pinSync(adopted: true)
        let outcome = sync.reconcile(
            pins: ["a", "unlisted"],
            listed: [pinRow("a", pinned: false), pinRow("b", pinned: true)],
            profile: "default"
        )
        XCTAssertEqual(outcome.pins, ["unlisted", "b"], "Unpinned on Desktop leaves; an unlisted pin stays")
        XCTAssertEqual(outcome.uploads, [])
    }

    func testPinsOwnWriteOutranksAStaleListing() {
        var sync = pinSync(adopted: true)
        sync.recordWrite(pinID: "a", profile: "default", pinned: true, at: Self.pinT0)
        let stale = sync.reconcile(pins: ["a"], listed: [pinRow("a", pinned: false)], profile: "default", now: Self.pinT0)
        XCTAssertEqual(stale.pins, ["a"])

        let confirmed = sync.reconcile(pins: ["a"], listed: [pinRow("a", pinned: true)], profile: "default", now: Self.pinT0)
        XCTAssertEqual(confirmed.pins, ["a"])
        XCTAssertTrue(sync.pendingWrites.isEmpty, "A listing that shows the write retires it")

        let unpinnedElsewhere = sync.reconcile(pins: ["a"], listed: [pinRow("a", pinned: false)], profile: "default", now: Self.pinT0)
        XCTAssertEqual(unpinnedElsewhere.pins, [])
    }

    func testPinsFailedWriteOnlyDiscardsTheLatest() {
        var sync = pinSync()
        let first = sync.recordWrite(pinID: "a", profile: "default", pinned: true)
        let second = sync.recordWrite(pinID: "a", profile: "default", pinned: false)
        XCTAssertFalse(sync.discardWrite(pinID: "a", profile: "default", generation: first))
        XCTAssertTrue(sync.discardWrite(pinID: "a", profile: "default", generation: second))
        XCTAssertTrue(sync.pendingWrites.isEmpty)
    }

    func testPinsFollowTheLineageRoot() {
        var sync = pinSync(adopted: true)
        let tip = pinRow("tip", pinned: true, lineageRoot: "root")
        let outcome = sync.reconcile(pins: [], listed: [tip], profile: "default")
        XCTAssertEqual(outcome.pins, ["root"])
        let unpinned = sync.reconcile(pins: ["tip"], listed: [pinRow("tip", pinned: false, lineageRoot: "root")], profile: "default")
        XCTAssertEqual(unpinned.pins, [], "A pin stored under the tip's own id clears too")
    }

    func testPinsUploadWritesTheListedRowsOwnID() {
        var sync = pinSync()
        let outcome = sync.reconcile(
            pins: ["root"],
            listed: [pinRow("tip", pinned: false, lineageRoot: "root")],
            profile: "default"
        )
        XCTAssertEqual(outcome.uploads, [SessionPinSync.Upload(pinID: "root", hostID: "tip")])
    }

    func testPinsForgetADeletedProfile() {
        var sync = pinSync(adopted: true)
        _ = sync.reconcile(pins: [], listed: [pinRow("a", pinned: true)], profile: "default")
        sync.recordWrite(pinID: "a", profile: "default", pinned: false)
        sync.forget(profile: "default")
        XCTAssertFalse(sync.isAdopted(profile: "default"))
        XCTAssertFalse(sync.supportsPins(profile: "default", host: Self.pinHost))
        XCTAssertTrue(sync.pendingWrites.isEmpty)
    }

    func testPinsAnotherHostStartsOver() {
        var sync = pinSync(adopted: true)
        _ = sync.reconcile(pins: [], listed: [pinRow("a", pinned: true)], profile: "default")
        sync.recordWrite(pinID: "a", profile: "default", pinned: false)
        sync.setHost("https://other.example")
        XCTAssertFalse(sync.supportsPins(profile: "default", host: "https://other.example"))
        XCTAssertFalse(sync.isAdopted(profile: "default"))
        XCTAssertTrue(sync.pendingWrites.isEmpty)
    }

    func testDashboardRowsCarryHermesPinnedFlag() {
        let rows: [[String: Any]] = [
            ["id": "a", "title": "A", "message_count": 3, "pinned": true, "profile": "default"],
            ["id": "b", "title": "B", "message_count": 3, "pinned": false, "profile": "default"],
            ["id": "c", "title": "C", "message_count": 3, "profile": "default"],
        ]
        let sessions = MessageNormalizer.normalizeSessions(
            AnyCodable.from(["sessions": rows] as [String: Any]),
            profile: nil
        )
        XCTAssertEqual(sessions.first { $0.id == "a" }?.isPinned, true)
        XCTAssertEqual(sessions.first { $0.id == "b" }?.isPinned, false)
        XCTAssertNil(sessions.first { $0.id == "c" }?.isPinned)
    }
}

// MARK: - Session mutation identity

/// Hermes main refuses a session PATCH or DELETE without a request id and
/// the row's revision (409 mutation_identity_required).
extension ChatReadStateTests {
    func testSessionMutationIdentityReadsTheSnapshotRevision() throws {
        let snapshot: [String: Any] = [
            "session_id": "abc", "exists": true,
            "runtime_revision": NSNumber(value: 7), "runtime_generation": NSNumber(value: 2)
        ]
        let fields = try XCTUnwrap(SessionMutationIdentity.fields(snapshot: snapshot, requestID: "req-1"))
        XCTAssertEqual(fields["request_id"] as? String, "req-1")
        XCTAssertEqual(fields["expected_revision"] as? Int, 7)
        XCTAssertEqual(fields["expected_generation"] as? Int, 2)
    }

    func testSessionMutationIdentityKeepsARevisionOfZeroOrOne() throws {
        let zero = try XCTUnwrap(SessionMutationIdentity.fields(snapshot: ["runtime_revision": NSNumber(value: 0), "runtime_generation": NSNull()], requestID: "r"))
        XCTAssertEqual(zero["expected_revision"] as? Int, 0)
        XCTAssertNil(zero["expected_generation"])
        let one = try XCTUnwrap(SessionMutationIdentity.fields(snapshot: ["runtime_revision": NSNumber(value: 1)], requestID: "r"))
        XCTAssertEqual(one["expected_revision"] as? Int, 1)
    }

    func testSessionMutationIdentityIsAbsentForAnOlderHost() {
        XCTAssertNil(SessionMutationIdentity.fields(snapshot: [:]))
        XCTAssertNil(SessionMutationIdentity.fields(snapshot: ["runtime_revision": NSNumber(value: true)]))
    }

    func testSessionMutationIdentityGoesInADeleteQuery() {
        let path = SessionMutationIdentity.path(
            "/api/sessions/abc?profile=work",
            adding: ["request_id": "r-1", "expected_revision": 3]
        )
        XCTAssertEqual(path, "/api/sessions/abc?profile=work&expected_revision=3&request_id=r-1")
        XCTAssertEqual(SessionMutationIdentity.path("/api/sessions/abc", adding: ["expected_revision": 3]), "/api/sessions/abc?expected_revision=3")
    }

    func testSessionMutationRetriesOnlyHermesConflicts() {
        func retries(_ status: Int, _ detail: String) -> Bool {
            SessionMutationIdentity.warrantsRetry(DashboardTicketBridgeError.http(status: status, detail: detail))
        }
        XCTAssertTrue(retries(409, "revision_conflict"))
        XCTAssertTrue(retries(409, #"{"detail":"stale_generation"}"#))
        XCTAssertTrue(retries(409, "mutation_identity_required"))
        XCTAssertFalse(retries(409, "session_busy"))
        XCTAssertFalse(retries(409, "lock held by another gateway"))
        XCTAssertFalse(retries(404, "not_found"))
    }

    func testSessionWriteConflictReadsAsBusy() {
        let busy = AppLocalization.string("Hermes is busy right now. Wait a moment, then try again.")
        XCTAssertEqual(DashboardTicketBridgeError.describe(status: 409, detail: #"{"detail":"mutation_identity_required"}"#), busy)
        XCTAssertEqual(DashboardTicketBridgeError.describe(status: 409, detail: "session_busy"), busy)
    }

    @MainActor
    private func mutationAppState() -> AppState {
        let suite = "SessionMutation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppState(defaults: defaults, loadSavedConnection: false)
    }

    @MainActor
    func testSessionPatchReadsTheSnapshotThenCarriesItsIdentity() async throws {
        let appState = mutationAppState()
        var calls: [(path: String, method: String, body: [String: Any]?)] = []
        _ = try await appState.sendSessionMutation("abc", body: ["pinned": true], profile: "work") { path, method, body in
            calls.append((path, method, body))
            return method == "GET" ? ["runtime_revision": 4, "runtime_generation": 2] : ["ok": true]
        }
        XCTAssertEqual(calls.map(\.method), ["GET", "PATCH"])
        XCTAssertTrue(calls[0].path.hasPrefix("/api/sessions/abc/mutation-snapshot"))
        let body = try XCTUnwrap(calls[1].body)
        XCTAssertEqual(body["pinned"] as? Bool, true)
        XCTAssertEqual(body["profile"] as? String, "work")
        XCTAssertEqual(body["expected_revision"] as? Int, 4)
        XCTAssertEqual(body["expected_generation"] as? Int, 2)
        XCTAssertNotNil(body["request_id"] as? String)
    }

    @MainActor
    func testSessionDeleteCarriesTheIdentityInItsQuery() async throws {
        let appState = mutationAppState()
        var paths: [String] = []
        _ = try await appState.sendSessionMutation("abc", body: nil, profile: "default") { path, method, _ in
            paths.append("\(method) \(path)")
            return method == "GET" ? ["runtime_revision": 7] : [:]
        }
        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths[1].hasPrefix("DELETE /api/sessions/abc?expected_revision=7&request_id="))
    }

    @MainActor
    func testSessionWriteRetriesOnceWithAFreshSnapshot() async throws {
        let appState = mutationAppState()
        var revisions: [Int] = []
        var requestIDs: [String] = []
        var snapshots = 0
        _ = try await appState.sendSessionMutation("abc", body: ["archived": true], profile: "default") { _, method, body in
            if method == "GET" {
                snapshots += 1
                // The first snapshot read fails, so the first write goes bare.
                if snapshots == 1 { throw DashboardTicketBridgeError.http(status: 0, detail: "Load failed") }
                return ["runtime_revision": 9]
            }
            if let id = body?["request_id"] as? String { requestIDs.append(id) }
            guard let revision = body?["expected_revision"] as? Int else {
                throw DashboardTicketBridgeError.http(status: 409, detail: "mutation_identity_required")
            }
            revisions.append(revision)
            return [:]
        }
        XCTAssertEqual(snapshots, 2)
        XCTAssertEqual(revisions, [9])
        XCTAssertEqual(requestIDs.count, 1)
    }

    @MainActor
    func testSessionWriteDoesNotRetryABusySession() async {
        let appState = mutationAppState()
        var writes = 0
        do {
            _ = try await appState.sendSessionMutation("abc", body: ["title": "x"], profile: "default") { _, method, _ in
                if method == "GET" { return ["runtime_revision": 1] }
                writes += 1
                throw DashboardTicketBridgeError.http(status: 409, detail: "session_busy")
            }
            XCTFail("A busy session should fail the write")
        } catch {
            XCTAssertEqual(writes, 1)
        }
    }

    @MainActor
    func testSessionWritesSkipTheSnapshotOnAnOlderHost() async throws {
        let appState = mutationAppState()
        var methods: [String] = []
        let olderHost: (String, String, [String: Any]?) async throws -> [String: Any] = { _, method, _ in
            methods.append(method)
            if method == "GET" { throw DashboardTicketBridgeError.http(status: 404, detail: "Not Found") }
            return [:]
        }
        _ = try await appState.sendSessionMutation("abc", body: ["pinned": true], profile: "default", using: olderHost)
        _ = try await appState.sendSessionMutation("abc", body: ["pinned": false], profile: "default", using: olderHost)
        XCTAssertEqual(methods, ["GET", "PATCH", "PATCH"])
    }

    func testOnlyAFrameworkNotFoundMeansNoSnapshotRoute() {
        XCTAssertTrue(SessionMutationIdentity.isMissingRoute(#"{"detail":"Not Found"}"#))
        XCTAssertFalse(SessionMutationIdentity.isMissingRoute("not_found"))
        XCTAssertFalse(SessionMutationIdentity.isMissingRoute("Session not found"))
    }

    func testPinsHermesRefusedStayOnThePhone() {
        var sync = pinSync(adopted: true)
        let write = sync.recordWrite(pinID: "old", profile: "default", pinned: true, at: Self.pinT0)
        XCTAssertTrue(sync.keepOnPhone(pinID: "old", profile: "default", generation: write))
        XCTAssertTrue(sync.isPhoneOnly(pinID: "old", profile: "default"))
        XCTAssertFalse(sync.isPhoneOnly(pinID: "old", profile: "work"))
        let outcome = sync.reconcile(
            pins: ["old"],
            listed: [pinRow("old", pinned: false), pinRow("b", pinned: true)],
            profile: "default",
            now: Self.pinT0
        )
        XCTAssertEqual(outcome.pins, ["old", "b"], "The host's unpinned flag can't drop a pin it refused")
        XCTAssertEqual(outcome.uploads, [])
    }

    func testPinsHermesRefusedNeverGoUpAndDontHoldOffAdoption() {
        var sync = pinSync()
        let oldDefaultWrite = sync.recordWrite(pinID: "old", profile: "default", pinned: true)
        sync.keepOnPhone(pinID: "old", profile: "default", generation: oldDefaultWrite)
        let unlistedDefaultWrite = sync.recordWrite(pinID: "unlisted", profile: "default", pinned: true)
        sync.keepOnPhone(pinID: "unlisted", profile: "default", generation: unlistedDefaultWrite)
        let outcome = sync.reconcile(
            pins: ["old", "unlisted"],
            listed: [pinRow("old", pinned: false)],
            profile: "default",
            now: Self.pinT0
        )
        XCTAssertEqual(outcome, SessionPinSync.Reconciliation(pins: ["old", "unlisted"], uploads: []))
        XCTAssertTrue(sync.isAdopted(profile: "default"))
    }

    func testPinsHermesRefusedAreKeptPerHostAndProfile() {
        var sync = pinSync()
        let oldDefaultWrite = sync.recordWrite(pinID: "old", profile: "default", pinned: true)
        sync.keepOnPhone(pinID: "old", profile: "default", generation: oldDefaultWrite)
        let oldWorkWrite = sync.recordWrite(pinID: "old", profile: "work", pinned: true)
        sync.keepOnPhone(pinID: "old", profile: "work", generation: oldWorkWrite)
        var restored = SessionPinSync(phoneOnly: sync.phoneOnly)
        restored.setHost(Self.pinHost)
        XCTAssertTrue(restored.isPhoneOnly(pinID: "old", profile: "default"), "Survives a relaunch")
        restored.forget(profile: "default")
        XCTAssertFalse(restored.isPhoneOnly(pinID: "old", profile: "default"))
        XCTAssertTrue(restored.isPhoneOnly(pinID: "old", profile: "work"))
        restored.setHost("https://other.example")
        XCTAssertFalse(restored.isPhoneOnly(pinID: "old", profile: "work"))
        restored.reset()
        XCTAssertTrue(restored.phoneOnly.isEmpty)
    }

    func testHermesRefusalIsNotAnExpiredSignIn() {
        XCTAssertTrue(SessionMutationIdentity.isRefusal(DashboardTicketBridgeError.http(status: 403, detail: "permission_denied")))
        XCTAssertTrue(SessionMutationIdentity.isRefusal(DashboardTicketBridgeError.http(status: 403, detail: " profile_mismatch\n")))
        XCTAssertTrue(SessionMutationIdentity.isRefusal(DashboardTicketBridgeError.http(status: 403, detail: "permission_denied: history claim required")))
        XCTAssertFalse(SessionMutationIdentity.isRefusal(DashboardTicketBridgeError.http(status: 403, detail: "Forbidden")))
        XCTAssertFalse(SessionMutationIdentity.isRefusal(DashboardTicketBridgeError.http(status: 409, detail: "permission_denied")))
        XCTAssertFalse(SessionMutationIdentity.isRefusal(DashboardTicketBridgeError.signInRequired))
        XCTAssertEqual(
            DashboardTicketBridgeError.describe(status: 403, detail: "permission_denied"),
            AppLocalization.string("Hermes only lets the computer it runs on change this older chat. Change it there instead.")
        )
        XCTAssertEqual(
            DashboardTicketBridgeError.describe(status: 403, detail: "profile_mismatch"),
            AppLocalization.string("Hermes says this chat belongs to another profile. Switch to that profile, then try again.")
        )
        XCTAssertEqual(
            DashboardTicketBridgeError.describe(status: 403, detail: "Forbidden"),
            AppLocalization.string("Hermes turned this down because the dashboard sign-in expired or doesn't allow it. Sign in again, then try once more.")
        )
    }

    func testPinsAStaleRefusalLeavesANewerWriteAlone() {
        var sync = pinSync(adopted: true)
        let pin = sync.recordWrite(pinID: "old", profile: "default", pinned: true, at: Self.pinT0)
        sync.recordWrite(pinID: "old", profile: "default", pinned: false, at: Self.pinT0)
        XCTAssertFalse(sync.keepOnPhone(pinID: "old", profile: "default", generation: pin))
        XCTAssertFalse(sync.isPhoneOnly(pinID: "old", profile: "default"))
        XCTAssertEqual(sync.pendingWrites["default\u{1F}old"]?.pinned, false, "The newer write still stands")
    }

    func testPinsClearingThePhoneOnlyMarkLetsListingsFollowHermes() {
        var sync = pinSync(adopted: true)
        let oldDefaultWrite = sync.recordWrite(pinID: "old", profile: "default", pinned: true)
        sync.keepOnPhone(pinID: "old", profile: "default", generation: oldDefaultWrite)
        XCTAssertTrue(sync.clearPhoneOnly(pinID: "old", profile: "default"))
        XCTAssertFalse(sync.isPhoneOnly(pinID: "old", profile: "default"))
        XCTAssertFalse(sync.clearPhoneOnly(pinID: "old", profile: "default"))
        let outcome = sync.reconcile(pins: [], listed: [pinRow("old", pinned: true)], profile: "default", now: Self.pinT0)
        XCTAssertEqual(outcome.pins, ["old"], "Listings follow Hermes for the chat again")
    }

    func testPinsARefusalAfterThePendingWriteLapsedStillMarks() {
        var sync = pinSync(adopted: true)
        let write = sync.recordWrite(pinID: "old", profile: "default", pinned: true, at: Self.pinT0)
        _ = sync.reconcile(
            pins: ["old"],
            listed: [pinRow("b", pinned: false)],
            profile: "default",
            now: Self.pinT0.addingTimeInterval(SessionPinSync.pendingWriteLifetime + 1)
        )
        XCTAssertNil(sync.pendingWrites["default\u{1F}old"], "The pending entry lapsed")
        XCTAssertTrue(sync.keepOnPhone(pinID: "old", profile: "default", generation: write))
        XCTAssertTrue(sync.isPhoneOnly(pinID: "old", profile: "default"))
    }
}
