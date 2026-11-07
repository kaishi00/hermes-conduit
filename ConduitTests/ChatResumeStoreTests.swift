import XCTest
@testable import Conduit

@MainActor
final class ChatResumeStoreTests: XCTestCase {
    private func defaults() throws -> (UserDefaults, String) {
        let suite = "ChatResumeStoreTests.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suite), "Failed to create test UserDefaults suite")
        return (ud, suite)
    }

    func testUnsavedBehaviorDefaultsToContinueWhereLeftOff() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ChatResumeStore(defaults: defaults).behavior, .continueWhereLeftOff)
    }

    func testPreferenceSessionAndAnchorSurviveStoreRecreation() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        let snapshot = ChatScrollSnapshot(
            anchorMessageID: "anchor-12",
            followsLatest: false,
            anchorMetadata: .init(fingerprint: "fingerprint", duplicateCount: 1),
            anchorSourceMessageID: "source-12"
        )
        let store = ChatResumeStore(defaults: defaults)

        store.setBehavior(.latestActivity)
        store.setLastSessionID("stored-a", for: "default")
        store.save(snapshot, for: key, at: Date(timeIntervalSince1970: 100))
        store.flush()

        let restored = ChatResumeStore(defaults: defaults)
        XCTAssertEqual(restored.behavior, .latestActivity)
        XCTAssertEqual(restored.lastSessionID(for: "default"), "stored-a")
        XCTAssertEqual(restored.snapshot(for: key), snapshot)
    }

    func testCorruptPayloadFallsBackWithoutThrowing() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not-json".utf8), forKey: ChatResumeStore.defaultStorageKey)

        let store = ChatResumeStore(defaults: defaults)

        XCTAssertEqual(store.behavior, .continueWhereLeftOff)
        XCTAssertNil(store.lastSessionID(for: "default"))
    }

    func testLegacySessionMapImportsOnlyOnce() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["default": "stored-a"], forKey: "legacy")
        _ = ChatResumeStore(defaults: defaults, legacyActiveSessionsKey: "legacy")
        defaults.set(["default": "stored-b"], forKey: "legacy")

        XCTAssertEqual(
            ChatResumeStore(defaults: defaults, legacyActiveSessionsKey: "legacy").lastSessionID(for: "default"),
            "stored-a"
        )
    }

    func testUnknownVersionResetsToDefault() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 999,
            "behavior": "latestActivity",
            "lastSessionIDsByProfile": ["default": "stored-a"],
            "snapshots": []
        ])
        defaults.set(data, forKey: ChatResumeStore.defaultStorageKey)

        XCTAssertEqual(ChatResumeStore(defaults: defaults).behavior, .continueWhereLeftOff)
    }

    func testPruningKeepsNewestHundredSnapshots() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatResumeStore(defaults: defaults)
        for index in 0...100 {
            store.save(
                .init(anchorMessageID: "anchor-\(index)", followsLatest: false),
                for: .init(profile: "default", sessionID: "session-\(index)"),
                at: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        XCTAssertNil(store.snapshot(for: .init(profile: "default", sessionID: "session-0")))
        XCTAssertNotNil(store.snapshot(for: .init(profile: "default", sessionID: "session-100")))
    }

    func testClearResumeStatePreservesBehavior() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatResumeStore(defaults: defaults)
        store.setBehavior(.latestActivity)
        store.setLastSessionID("stored-a", for: "default")
        store.save(.latest, for: .init(profile: "default", sessionID: "stored-a"), at: Date())
        store.clearResumeState()

        XCTAssertEqual(store.behavior, .latestActivity)
        XCTAssertNil(store.lastSessionID(for: "default"))
        XCTAssertNil(store.snapshot(for: .init(profile: "default", sessionID: "stored-a")))
    }

    /// Every chat open sets the last chat, and any write to the defaults
    /// redraws each `@AppStorage` view: setting the one already saved, or
    /// forgetting one that isn't, writes nothing.
    func testSettingTheSameLastChatWritesNothing() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatResumeStore(defaults: defaults)
        store.setLastSessionID("stored-a", for: "default")
        // Gone from the defaults behind the store's back, so a write shows.
        defaults.removeObject(forKey: ChatResumeStore.defaultStorageKey)

        store.setLastSessionID("stored-a", for: "default")
        store.setLastSession(nil, for: "work")
        XCTAssertNil(defaults.data(forKey: ChatResumeStore.defaultStorageKey), "Nothing changed: nothing written")

        store.setLastSessionID("stored-b", for: "default")
        XCTAssertEqual(ChatResumeStore(defaults: defaults).lastSessionID(for: "default"), "stored-b")
        defaults.removeObject(forKey: ChatResumeStore.defaultStorageKey)
        store.setLastSession(nil, for: "default")
        XCTAssertNotNil(defaults.data(forKey: ChatResumeStore.defaultStorageKey), "Forgetting a saved chat is written")
    }

    func testRemoveSessionsDropsSnapshotsAndLastSelectionWithoutTouchingSiblings() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatResumeStore(defaults: defaults)
        let deletedKey = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        let siblingKey = ChatScrollSessionKey(profile: "default", sessionID: "stored-b")
        let otherProfileKey = ChatScrollSessionKey(profile: "work", sessionID: "stored-a")
        store.save(
            ChatScrollSnapshot(anchorMessageID: "deleted-anchor", followsLatest: false),
            for: deletedKey,
            at: Date()
        )
        store.save(
            ChatScrollSnapshot(anchorMessageID: "sibling-anchor", followsLatest: false),
            for: siblingKey,
            at: Date()
        )
        store.save(
            ChatScrollSnapshot(anchorMessageID: "other-profile-anchor", followsLatest: false),
            for: otherProfileKey,
            at: Date()
        )
        store.setLastSessionID("stored-a", for: "default")

        store.removeSessions(profile: "default", sessionIDs: ["stored-a", "runtime-a"])

        XCTAssertNil(store.snapshot(for: deletedKey))
        XCTAssertNil(store.lastSessionID(for: "default"), "The deleted conversation cannot stay last-selected")
        XCTAssertNotNil(store.snapshot(for: siblingKey))
        XCTAssertNotNil(
            store.snapshot(for: otherProfileKey),
            "Deletion is profile-scoped; another profile's same-named session survives"
        )
    }

    func testSnapshotMigratesFromRuntimeToCanonicalKey() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatResumeStore(defaults: defaults)
        let runtime = ChatScrollSessionKey(profile: "default", sessionID: "runtime-a")
        let canonical = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        let snapshot = ChatScrollSnapshot(
            anchorMessageID: "anchor-12",
            followsLatest: false,
            anchorMetadata: .init(fingerprint: "fingerprint", duplicateCount: 2),
            anchorSourceMessageID: "source-12"
        )
        store.save(snapshot, for: runtime, at: Date())

        store.migrateSnapshot(from: runtime, to: canonical)

        XCTAssertEqual(store.snapshot(for: canonical), snapshot)
    }

    func testMigrationRemovesRuntimeSnapshotAndPreservesNewerCanonicalSnapshot() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatResumeStore(defaults: defaults)
        let runtime = ChatScrollSessionKey(profile: "default", sessionID: "runtime-a")
        let canonical = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        let runtimeSnapshot = ChatScrollSnapshot(anchorMessageID: "runtime-anchor", followsLatest: false)
        let canonicalSnapshot = ChatScrollSnapshot(anchorMessageID: "canonical-anchor", followsLatest: false)
        store.save(runtimeSnapshot, for: runtime, at: Date(timeIntervalSince1970: 100))
        store.save(canonicalSnapshot, for: canonical, at: Date(timeIntervalSince1970: 200))

        store.migrateSnapshot(from: runtime, to: canonical)

        XCTAssertNil(store.snapshot(for: runtime))
        XCTAssertEqual(store.snapshot(for: canonical), canonicalSnapshot)
    }

    func testSessionIdentityMigrationMovesLastSessionAndPreservesNewerCanonicalSnapshot() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatResumeStore(defaults: defaults)
        let runtime = ChatScrollSessionKey(profile: "default", sessionID: "runtime-a")
        let canonical = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        let runtimeSnapshot = ChatScrollSnapshot(anchorMessageID: "runtime-anchor", followsLatest: false)
        let canonicalSnapshot = ChatScrollSnapshot(anchorMessageID: "canonical-anchor", followsLatest: false)
        store.setLastSessionID(runtime.sessionID, for: runtime.profile)
        store.save(runtimeSnapshot, for: runtime, at: Date(timeIntervalSince1970: 100))
        store.save(canonicalSnapshot, for: canonical, at: Date(timeIntervalSince1970: 200))

        store.migrateSessionIdentity(from: runtime, to: canonical)

        let restored = ChatResumeStore(defaults: defaults)
        XCTAssertEqual(restored.lastSessionID(for: canonical.profile), canonical.sessionID)
        XCTAssertNil(restored.snapshot(for: runtime))
        XCTAssertEqual(restored.snapshot(for: canonical), canonicalSnapshot)
    }

    func testEqualTimestampPruningUsesDeterministicKeyOrder() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshots = (0...100).reversed().map { index in
            storedSnapshot(
                sessionID: String(format: "session-%03d", index),
                anchorMessageID: "anchor-\(index)",
                updatedAt: 0
            )
        }
        defaults.set(try payloadData(snapshots: snapshots), forKey: ChatResumeStore.defaultStorageKey)

        let store = ChatResumeStore(defaults: defaults)

        XCTAssertNotNil(store.snapshot(for: .init(profile: "default", sessionID: "session-000")))
        XCTAssertNil(store.snapshot(for: .init(profile: "default", sessionID: "session-100")))
    }

    func testEqualTimestampDuplicateSnapshotsUseDeterministicAnchorOrder() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try payloadData(snapshots: [
            storedSnapshot(sessionID: "session", anchorMessageID: "anchor-z", updatedAt: 0),
            storedSnapshot(sessionID: "session", anchorMessageID: "anchor-a", updatedAt: 0)
        ]), forKey: ChatResumeStore.defaultStorageKey)

        XCTAssertEqual(
            ChatResumeStore(defaults: defaults).snapshot(for: .init(profile: "default", sessionID: "session")),
            ChatScrollSnapshot(anchorMessageID: "anchor-a", followsLatest: false)
        )
    }

    func testNormalizationCollisionUsesLexicographicallyFirstSessionID() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([
            "Default": "stored-z",
            " default ": "stored-y",
            "DEFAULT": "stored-x",
            " default": "stored-a"
        ], forKey: "legacy")

        XCTAssertEqual(
            ChatResumeStore(defaults: defaults, legacyActiveSessionsKey: "legacy").lastSessionID(for: "DEFAULT"),
            "stored-a"
        )
    }

    // MARK: - session kind (v1 → v2)

    func testBotSessionReferenceRoundTripsWithItsKindAndScope() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatResumeStore(defaults: defaults)
        store.setLastSession(
            .bot(botName: "atlas", label: "Scout", sessionID: "stored-bot"),
            for: "default"
        )

        let restored = ChatResumeStore(defaults: defaults)
        XCTAssertEqual(
            restored.lastSession(for: "default"),
            SessionReference(
                kind: .bot,
                scopeProfile: "atlas",
                botName: "atlas",
                botLabel: "Scout",
                sessionID: "stored-bot"
            )
        )
        XCTAssertEqual(
            restored.lastSession(for: "default")?.resumeProfileScope,
            "atlas",
            "a Bot Chat's resume addresses the BOT's profile, not the workspace's"
        )
    }

    func testLegacyPayloadMigratesSessionIDsToDashboardReferences() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        // Exactly what a build before the session-kind change wrote.
        defaults.set(try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "behavior": "latestActivity",
            "lastSessionIDsByProfile": ["default": "stored-a", "work": "stored-b"],
            "snapshots": []
        ]), forKey: ChatResumeStore.defaultStorageKey)

        let store = ChatResumeStore(defaults: defaults)

        XCTAssertEqual(store.behavior, .latestActivity, "the migrated payload keeps the user's preference")
        let migrated = store.lastSession(for: "default")
        XCTAssertEqual(
            migrated,
            .dashboard(profile: "default", sessionID: "stored-a", isUnverified: true),
            "a bare v1 id carries no kind: it migrates as an UNTYPED reference — the kind is unknown until bot evidence says otherwise"
        )
        XCTAssertTrue(
            migrated?.isUnverified ?? false,
            "callers must be able to tell a migrated id from one this build recorded"
        )
        XCTAssertEqual(store.lastSessionID(for: "work"), "stored-b")
        XCTAssertTrue(
            store.lastSession(for: "work")?.isUnverified ?? false,
            "every entry recovered from a v1 payload is untyped, whichever workspace it belongs to"
        )
        // The upgrade is persisted, so the next launch decodes v2 directly.
        let rewritten = try XCTUnwrap(
            defaults.data(forKey: ChatResumeStore.defaultStorageKey)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: rewritten) as? [String: Any]
        )
        XCTAssertEqual(object["version"] as? Int, 2)
        XCTAssertNotNil(object["lastSessionByProfile"])
    }

    // MARK: - session kind durability (review-gate hardening)

    /// A runtime → durable rebind must carry the conversation's KIND: the
    /// reference is re-keyed, not rewritten, so a Bot Chat stays a Bot Chat and
    /// keeps the scope its RPCs ride.
    func testSessionIdentityMigrationPreservesBotKindAndScope() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatResumeStore(defaults: defaults)
        let runtime = ChatScrollSessionKey(profile: "default", sessionID: "runtime-1")
        let durable = ChatScrollSessionKey(profile: "default", sessionID: "stored-1")
        store.setLastSession(
            .bot(botName: "atlas", label: "Scout", sessionID: runtime.sessionID),
            for: "default"
        )

        store.migrateSessionIdentity(from: runtime, to: durable)

        let restored = ChatResumeStore(defaults: defaults).lastSession(for: "default")
        XCTAssertEqual(restored?.sessionID, durable.sessionID)
        XCTAssertEqual(restored?.kind, SessionReference.Kind.bot)
        XCTAssertEqual(restored?.scopeProfile, "atlas")
        XCTAssertEqual(restored?.botLabel, "Scout")
    }

    /// Every comparison in the app normalizes a session id, so the stored value
    /// must be normalized too: an untrimmed id would survive here and then fail
    /// the delete / not-found equality fences, leaving restorable state behind
    /// for a conversation that no longer exists.
    /// Records written by THIS build carry a known kind, so they are never
    /// marked untyped — the flag is what makes the catalog-absent escape hatch
    /// conditional on bot evidence.
    func testNativelyWrittenSelectionIsNotMarkedUntyped() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatResumeStore(defaults: defaults)

        store.setLastSessionID("stored-a", for: "default")
        store.setLastSession(.bot(botName: "Atlas", label: "Scout", sessionID: "stored-b"), for: "work")

        XCTAssertFalse(store.lastSession(for: "default")?.isUnverified ?? true)
        XCTAssertFalse(store.lastSession(for: "work")?.isUnverified ?? true)
    }

    func testStoredSelectionNormalizesItsSessionID() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatResumeStore(defaults: defaults)

        store.setLastSession(.dashboard(profile: "default", sessionID: "  stored-a  "), for: "default")

        XCTAssertEqual(store.lastSession(for: "default")?.sessionID, "stored-a")
        store.removeSessions(profile: "default", sessionIDs: ["stored-a"])
        XCTAssertNil(
            store.lastSession(for: "default"),
            "the deletion fence matches the value the store actually kept"
        )
    }

    /// A `.bot` reference is meaningless without the profile its RPCs ride, so
    /// a reference whose scope does not survive normalization is dropped rather
    /// than stored half-addressed.
    func testBotReferenceWithoutUsableScopeIsDropped() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatResumeStore(defaults: defaults)

        store.setLastSession(
            SessionReference(
                kind: .bot,
                scopeProfile: "   ",
                botName: "  ",
                botLabel: "Scout",
                sessionID: "stored-bot"
            ),
            for: "default"
        )

        XCTAssertNil(store.lastSession(for: "default"))
    }

    /// The bot's label survives the store round-trip (it is what a restored Bot
    /// Chat shows before the roster has loaded).
    func testBotLabelSurvivesStoreRoundTripAndDropsForOrdinaryKinds() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChatResumeStore(defaults: defaults)

        store.setLastSession(
            SessionReference(
                kind: .dashboard,
                scopeProfile: "default",
                botName: "atlas",
                botLabel: "Scout",
                sessionID: "stored-a"
            ),
            for: "default"
        )

        let restored = ChatResumeStore(defaults: defaults).lastSession(for: "default")
        XCTAssertEqual(restored?.kind, SessionReference.Kind.dashboard)
        XCTAssertNil(restored?.botName, "an ordinary reference carries no bot binding")
        XCTAssertNil(restored?.botLabel)
    }

    /// A payload written BEFORE the unverified flag existed must still decode,
    /// as unverified. `Codable` synthesis does not apply a property default when
    /// a key is absent, so without the lenient decoder this payload would fail
    /// to decode and the store would silently discard the user's selection —
    /// data loss, in exchange for no safety gain (the flag's whole point is that
    /// absent evidence reads as unverified).
    func testPayloadWithoutTheUnverifiedFlagDecodesAsUnverified() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacyV2: [String: Any] = [
            "version": 2,
            "behavior": "continueWhereLeftOff",
            "lastSessionByProfile": [
                "default": [
                    "kind": "dashboard",
                    "scopeProfile": "default",
                    "sessionID": "stored-a"
                    // no `isUnverified` key: written before the flag existed
                ],
                "work": [
                    "kind": "bot",
                    "scopeProfile": "Atlas",
                    "botName": "Atlas",
                    "botLabel": "Scout",
                    "sessionID": "stored-b"
                ]
            ],
            "snapshots": []
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: legacyV2),
            forKey: ChatResumeStore.defaultStorageKey
        )

        let store = ChatResumeStore(defaults: defaults)

        XCTAssertEqual(
            store.lastSessionID(for: "default"),
            "stored-a",
            "the selection survives instead of being dropped"
        )
        XCTAssertTrue(
            store.lastSession(for: "default")?.isUnverified ?? false,
            "a flag-less payload means the kind was never verified"
        )
        XCTAssertFalse(
            store.lastSession(for: "work")?.isUnverified ?? true,
            "a .bot reference records its kind outright, so it is verified whatever the flag says"
        )
        XCTAssertEqual(
            store.lastSession(for: "work")?.scopeProfile,
            "Atlas",
            "and the case-preserved scope round-trips"
        )

        // A payload that EXPLICITLY says it was verified stays verified.
        let verifiedV2: [String: Any] = [
            "version": 2,
            "behavior": "continueWhereLeftOff",
            "lastSessionByProfile": [
                "default": [
                    "kind": "dashboard",
                    "scopeProfile": "default",
                    "sessionID": "stored-a",
                    "isUnverified": false
                ]
            ],
            "snapshots": []
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: verifiedV2),
            forKey: ChatResumeStore.defaultStorageKey
        )
        XCTAssertFalse(
            ChatResumeStore(defaults: defaults).lastSession(for: "default")?.isUnverified ?? true
        )
    }


    private func payloadData(snapshots: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "behavior": "continueWhereLeftOff",
            "lastSessionIDsByProfile": [:],
            "snapshots": snapshots
        ])
    }

    private func storedSnapshot(
        sessionID: String,
        anchorMessageID: String,
        updatedAt: TimeInterval
    ) -> [String: Any] {
        [
            "key": ["profile": "default", "sessionID": sessionID],
            "snapshot": [
                "anchorMessageID": anchorMessageID,
                "followsLatest": false,
                "anchorMetadata": NSNull(),
                "anchorSourceMessageID": NSNull()
            ],
            "updatedAt": updatedAt
        ]
    }
}
