import Foundation
import XCTest
@testable import Conduit

/// Tests SessionPresentationCache.merge — the logic that decides which
/// presentation metadata (timestamps, tool previews, attachments) survives
/// a reconnect or session reopen. Getting this wrong means messages lose
/// their timestamps or tool calls lose their input text.
@MainActor
final class SessionPresentationCacheTests: XCTestCase {

    // MARK: - Merge: timestamp restoration

    func testMergeRestoresMissingTimestamp() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-merge-timestamp-\(UUID().uuidString)"
        let profile = "test"

        // Save messages WITH timestamps
        let savedMessages = [
            ChatMessage(id: "msg-1", role: .assistant, content: "Hello", timestamp: "2024-01-01T10:00:00Z"),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])

        // Gateway sends messages WITHOUT timestamps (compact history)
        let gatewayMessages = [
            ChatMessage(id: "msg-1", role: .assistant, content: "Hello", timestamp: ""),
        ]
        let merged = cache.merge(gatewayMessages, profile: profile, sessionIDs: [sessionId])

        XCTAssertEqual(merged[0].timestamp, "2024-01-01T10:00:00Z")

        cache.clear(profile: profile)
    }

    func testMergeDoesNotOverrideExistingTimestamp() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-merge-no-override-\(UUID().uuidString)"
        let profile = "test"

        let savedMessages = [
            ChatMessage(id: "msg-1", role: .assistant, content: "Hello", timestamp: "2024-01-01T10:00:00Z"),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])

        let gatewayMessages = [
            ChatMessage(id: "msg-1", role: .assistant, content: "Hello", timestamp: "2024-06-01T12:00:00Z"),
        ]
        let merged = cache.merge(gatewayMessages, profile: profile, sessionIDs: [sessionId])

        XCTAssertEqual(merged[0].timestamp, "2024-06-01T12:00:00Z")

        cache.clear(profile: profile)
    }

    // MARK: - Merge: tool input restoration

    func testMergeRestoresToolInputFromPreview() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-merge-tool-\(UUID().uuidString)"
        let profile = "test"

        let savedMessages = [
            ChatMessage(
                id: "msg-tool", role: .tool, content: "",
                timestamp: "2024-01-01",
                tool: ToolActivity(id: nil, name: "terminal", input: "ls -la", output: "output", status: .complete)
            ),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])

        // Gateway sends tool with empty input (compact history)
        let gatewayMessages = [
            ChatMessage(
                id: "msg-tool", role: .tool, content: "",
                timestamp: "",
                tool: ToolActivity(id: nil, name: "terminal", input: nil, output: "output", status: .complete)
            ),
        ]
        let merged = cache.merge(gatewayMessages, profile: profile, sessionIDs: [sessionId])

        XCTAssertNotNil(merged[0].tool?.input)
        XCTAssertFalse(merged[0].tool?.input?.isEmpty ?? true)

        cache.clear(profile: profile)
    }

    // MARK: - Merge: attachment restoration

    func testMergeRestoresAttachments() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-merge-attach-\(UUID().uuidString)"
        let profile = "test"

        let attachment = Attachment(id: "att-1", name: "image.png", uri: "file:///tmp/image.png", mimeType: "image/png", kind: .image)
        let savedMessages = [
            ChatMessage(id: "msg-1", role: .user, content: "Look", timestamp: "2024-01-01", attachments: [attachment]),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])

        let gatewayMessages = [
            ChatMessage(id: "msg-1", role: .user, content: "Look", timestamp: "", attachments: nil),
        ]
        let merged = cache.merge(gatewayMessages, profile: profile, sessionIDs: [sessionId])

        XCTAssertEqual(merged[0].attachments?.count, 1)
        XCTAssertEqual(merged[0].attachments?.first?.id, "att-1")

        cache.clear(profile: profile)
    }

    // MARK: - Merge: no cache available

    func testMergeReturnsOriginalWhenNoCache() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-no-cache-\(UUID().uuidString)"

        let messages = [
            ChatMessage(id: "msg-1", role: .user, content: "Hello", timestamp: "2024-01-01"),
        ]
        let merged = cache.merge(messages, profile: "test", sessionIDs: [sessionId])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].content, "Hello")
    }

    // MARK: - Merge: ID-based matching

    func testMergeMatchesByExactId() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-merge-id-\(UUID().uuidString)"
        let profile = "test"

        let savedMessages = [
            ChatMessage(id: "unique-id-123", role: .assistant, content: "Response", timestamp: "2024-01-01T10:00:00Z"),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])

        let gatewayMessages = [
            ChatMessage(id: "unique-id-123", role: .assistant, content: "Response", timestamp: ""),
        ]
        let merged = cache.merge(gatewayMessages, profile: profile, sessionIDs: [sessionId])

        XCTAssertEqual(merged[0].timestamp, "2024-01-01T10:00:00Z")

        cache.clear(profile: profile)
    }

    // MARK: - Merge: role mismatch prevention

    func testMergeDoesNotMatchAcrossRoles() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-merge-role-\(UUID().uuidString)"
        let profile = "test"

        let savedMessages = [
            ChatMessage(id: "msg-1", role: .assistant, content: "Response", timestamp: "2024-01-01"),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])

        let gatewayMessages = [
            ChatMessage(id: "msg-1", role: .user, content: "Response", timestamp: ""),
        ]
        let merged = cache.merge(gatewayMessages, profile: profile, sessionIDs: [sessionId])

        // Different role = no match = timestamp not restored
        XCTAssertEqual(merged[0].timestamp, "")

        cache.clear(profile: profile)
    }

    // MARK: - Save + clear isolation

    func testClearRemovesSpecificProfile() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-clear-\(UUID().uuidString)"
        let profile = "test-clear-profile"

        let messages = [
            ChatMessage(id: "msg-1", role: .user, content: "data", timestamp: "2024-01-01"),
        ]
        cache.save(messages, profile: profile, sessionIDs: [sessionId])
        cache.clear(profile: profile)

        let merged = cache.merge(messages, profile: profile, sessionIDs: [sessionId])
        // After clear, no cache to restore from, but messages still returned
        XCTAssertEqual(merged.count, 1)
    }

    func testRemoveSessionsDropsEveryAliasRecordButLeavesSiblings() throws {
        let (cache, _, _, _) = try makeIsolatedCache()
        let profile = "remove-test"
        let deletedPrimary = "remove-deleted-primary"
        let deletedAlias = "remove-deleted-alias"
        let sibling = "remove-sibling"

        let messages = [
            ChatMessage(id: "msg-1", role: .user, content: "Remove me", timestamp: "2024-01-01"),
        ]
        cache.save(messages, profile: profile, sessionIDs: [deletedPrimary, deletedAlias])
        cache.save(
            [ChatMessage(id: "msg-2", role: .user, content: "Keep me", timestamp: "2024-01-02")],
            profile: profile,
            sessionIDs: [sibling]
        )

        cache.removeSessions(profile: profile, sessionIDs: [deletedPrimary, deletedAlias])

        let probe = ChatMessage(id: "msg-1", role: .user, content: "Remove me", timestamp: "")
        for alias in [deletedPrimary, deletedAlias] {
            XCTAssertEqual(
                cache.merge([probe], profile: profile, sessionIDs: [alias]).first?.timestamp,
                "",
                "A deleted conversation's cached presentation must not survive under any alias"
            )
        }
        XCTAssertEqual(
            cache.merge(
                [ChatMessage(id: "msg-2", role: .user, content: "Keep me", timestamp: "")],
                profile: profile,
                sessionIDs: [sibling]
            ).first?.timestamp,
            "2024-01-02",
            "Sibling conversations keep their cached presentation"
        )
    }

    // MARK: - Durable-owned persistence (runtime alias retirement)

    func testConsolidationMigratesRuntimeOnlyRecordToDurableKeyWithoutLoss() throws {
        // Runtime-only establishment: presentation cached under runtime-x
        // must MIGRATE to the durable key when stored-A is established —
        // never be lost — and the mutable runtime key must be retired.
        let (cache, _, tickClock, _) = try makeIsolatedCache()
        let profile = "consolidate"
        let messages = [
            ChatMessage(id: "m1", role: .assistant, content: "Answer", timestamp: "ts-1"),
            ChatMessage(
                id: "m2",
                role: .user,
                content: "Question",
                timestamp: "ts-2",
                tool: ToolActivity(id: "t1", name: "shell", input: "", output: "files", status: .complete)
            ),
        ]
        cache.save(messages, profile: profile, sessionIDs: ["runtime-x"])
        tickClock()

        cache.consolidateUnderDurableKey(
            profile: profile,
            durableSessionID: "stored-a",
            runtimeAliases: ["runtime-x"]
        )

        let probe = messages.map { message -> ChatMessage in
            var row = ChatMessage(id: message.id, role: message.role, content: message.content, timestamp: "")
            // The merge only ENRICHES an existing tool row — mirror the
            // gateway's compact shape (tool present, details omitted).
            if let tool = message.tool {
                row.tool = ToolActivity(id: tool.id, name: tool.name, input: "", output: nil, status: tool.status)
            }
            return row
        }
        let merged = cache.merge(probe, profile: profile, sessionIDs: ["stored-a"])
        XCTAssertEqual(merged.map(\.timestamp), ["ts-1", "ts-2"], "Establishment migrates the record")
        XCTAssertEqual(merged[1].tool?.input, "files", "Tool metadata migrates with the record")
        XCTAssertEqual(
            cache.merge(probe, profile: profile, sessionIDs: ["runtime-x"]).map(\.timestamp),
            ["", ""],
            "The runtime-keyed copy is retired"
        )
    }

    func testReattributedRuntimeCannotLeakPresentationIntoAnotherConversation() throws {
        // The reported bleed: A's presentation (pending approval card
        // included) was cached under runtime-x; the gateway later
        // re-attributes runtime-x to stored-B. After consolidation retired
        // the runtime key, restoring B through runtime-x must find NOTHING
        // of A's — while A's own presentation survives under its durable key.
        let (cache, _, tickClock, _) = try makeIsolatedCache()
        let profile = "bleed"
        let approval = ApprovalActivity(
            sessionId: "runtime-x",
            command: "",
            description: "A's pending approval",
            choices: ["once", "deny"],
            allowPermanent: false,
            smartDenied: false,
            status: .pending,
            choice: nil,
            error: nil
        )
        let aMessages = [
            ChatMessage(
                id: "a-approval",
                role: .approval,
                content: "A's pending approval",
                timestamp: "a-ts",
                approval: approval
            ),
        ]
        cache.save(aMessages, profile: profile, sessionIDs: ["stored-a", "runtime-x"])
        tickClock()

        cache.consolidateUnderDurableKey(
            profile: profile,
            durableSessionID: "stored-a",
            runtimeAliases: ["runtime-x"]
        )

        // Restore B using the re-attributed runtime id.
        let bProbe = [
            ChatMessage(id: "b-row", role: .assistant, content: "B's own reply", timestamp: "")
        ]
        let restoredForB = cache.merge(
            bProbe,
            profile: profile,
            sessionIDs: ["runtime-x"],
            includePendingApprovals: true
        )
        XCTAssertNil(restoredForB[0].approval, "A's pending approval must not cross into B")
        XCTAssertEqual(restoredForB[0].timestamp, "", "A's timestamps must not cross into B")
        XCTAssertFalse(restoredForB.contains { $0.role == .approval })

        // Positive control: A still restores through its durable key, and the
        // migrated card now answers against the DURABLE session — after a
        // later rotation of runtime-x, an approve tap can never dispatch to
        // whatever the old runtime id routes to.
        let aProbe = [
            ChatMessage(id: "a-approval", role: .approval, content: "A's pending approval", timestamp: "")
        ]
        let restoredForA = cache.merge(
            aProbe,
            profile: profile,
            sessionIDs: ["stored-a"],
            includePendingApprovals: true
        )
        XCTAssertEqual(restoredForA[0].approval?.description, "A's pending approval")
        XCTAssertEqual(restoredForA[0].timestamp, "a-ts")
        XCTAssertEqual(
            restoredForA[0].approval?.sessionId, "stored-a",
            "Consolidation rewrites the card's routing identity to the durable session"
        )
    }

    func testConsolidationKeepsExistingDurableRecordOverAliasCopy() throws {
        // When the durable key already holds the live write, consolidation
        // must keep it (dropping stale alias copies), not overwrite it with
        // an older alias snapshot.
        let (cache, _, tickClock, _) = try makeIsolatedCache()
        let profile = "keep-live"
        cache.save(
            [ChatMessage(id: "live", role: .assistant, content: "Live durable write", timestamp: "live-ts")],
            profile: profile,
            sessionIDs: ["stored-a"]
        )
        tickClock()
        cache.save(
            [ChatMessage(id: "stale", role: .assistant, content: "Stale alias copy", timestamp: "stale-ts")],
            profile: profile,
            sessionIDs: ["runtime-x"]
        )

        cache.consolidateUnderDurableKey(
            profile: profile,
            durableSessionID: "stored-a",
            runtimeAliases: ["runtime-x"]
        )

        let probe = [ChatMessage(id: "live", role: .assistant, content: "Live durable write", timestamp: "")]
        XCTAssertEqual(
            cache.merge(probe, profile: profile, sessionIDs: ["stored-a"]).first?.timestamp,
            "live-ts",
            "The durable record is the live write and survives"
        )
        XCTAssertEqual(
            cache.merge(
                [ChatMessage(id: "stale", role: .assistant, content: "Stale alias copy", timestamp: "")],
                profile: profile,
                sessionIDs: ["runtime-x"]
            ).map(\.timestamp),
            [""],
            "The alias copy is retired"
        )
    }

    func testConsolidationPromotesNewPendingApprovalIntoExistingDurableRecord() throws {
        // The notification-promotion case: the durable record already holds
        // normal presentation when a fresh pending approval arrives under a
        // runtime alias. Consolidation must promote the CARD (deduped,
        // routing id rewritten to the durable session) while keeping the
        // durable transcript authoritative — and retire the alias key.
        let (cache, _, tickClock, _) = try makeIsolatedCache()
        let profile = "promote"
        cache.save(
            [ChatMessage(id: "d1", role: .assistant, content: "Durable transcript", timestamp: "durable-ts")],
            profile: profile,
            sessionIDs: ["stored-a"]
        )
        tickClock()
        let approval = ApprovalActivity(
            sessionId: "runtime-x",
            command: "",
            description: "Fresh push approval",
            choices: ["once", "deny"],
            allowPermanent: false,
            smartDenied: false,
            status: .pending,
            choice: nil,
            error: nil
        )
        cache.save(
            [
                ChatMessage(
                    id: "approval-runtime-x",
                    role: .approval,
                    content: "Fresh push approval",
                    timestamp: "push-ts",
                    approval: approval
                )
            ],
            profile: profile,
            sessionIDs: ["runtime-old"]
        )

        cache.consolidateUnderDurableKey(
            profile: profile,
            durableSessionID: "stored-a",
            // Production unions every runtime the admitted resume knows: the
            // push-named key (runtime-old) AND the card's own embedded
            // session key (runtime-x) — both are retired by promotion.
            runtimeAliases: ["runtime-old", "runtime-x"]
        )

        let probe = [
            ChatMessage(id: "d1", role: .assistant, content: "Durable transcript", timestamp: ""),
            ChatMessage(id: "approval-runtime-x", role: .approval, content: "Fresh push approval", timestamp: ""),
        ]
        let merged = cache.merge(
            probe,
            profile: profile,
            sessionIDs: ["stored-a"],
            includePendingApprovals: true
        )
        XCTAssertEqual(merged[0].timestamp, "durable-ts", "The durable transcript stays authoritative")
        XCTAssertEqual(
            merged[1].approval?.sessionId, "stored-a",
            "The promoted card answers against the durable session"
        )
        XCTAssertEqual(merged[1].approval?.status, .pending)
        // No duplicates, no runtime key: consolidating again must not add a
        // second card, and the runtime-old copy is gone.
        cache.consolidateUnderDurableKey(
            profile: profile,
            durableSessionID: "stored-a",
            runtimeAliases: ["runtime-old", "runtime-x"]
        )
        let mergedAgain = cache.merge(
            probe,
            profile: profile,
            sessionIDs: ["stored-a"],
            includePendingApprovals: true
        )
        XCTAssertEqual(mergedAgain.filter { $0.role == .approval }.count, 1)
        XCTAssertNil(
            cache.merge([probe[1]], profile: profile, sessionIDs: ["runtime-old"], includePendingApprovals: true)
                .first?.approval,
            "The runtime alias key is retired — no card answers from it"
        )
    }

    func testConsolidationPromotesPendingClarifyIntoExistingDurableRecordWithoutRewritingRequestId() throws {
        // Clarify request ids are request identity (relay-minted), not
        // session routing identity: promotion must preserve them verbatim,
        // dedupe on a second pass, and retire the alias key.
        let (cache, _, tickClock, _) = try makeIsolatedCache()
        let profile = "promote-clarify"
        cache.save(
            [ChatMessage(id: "d1", role: .assistant, content: "Durable transcript", timestamp: "durable-ts")],
            profile: profile,
            sessionIDs: ["stored-a"]
        )
        tickClock()
        cache.save(
            [
                ChatMessage(
                    id: "clarify-conduit-push-q1",
                    role: .clarify,
                    content: "Which env?",
                    timestamp: "push-ts",
                    clarify: ClarifyActivity(
                        requestId: "conduit-push-q1",
                        question: "Which env?",
                        choices: [ClarifyChoice(label: "staging", value: "staging")],
                        status: .pending,
                        answer: nil,
                        error: nil
                    )
                )
            ],
            profile: profile,
            sessionIDs: ["runtime-old"]
        )

        cache.consolidateUnderDurableKey(
            profile: profile,
            durableSessionID: "stored-a",
            runtimeAliases: ["runtime-old"]
        )

        let probe = [ChatMessage(id: "p", role: .assistant, content: "probe", timestamp: "")]
        let merged = cache.merge(probe, profile: profile, sessionIDs: ["stored-a"], includePendingClarifications: true)
        let cards = merged.filter { $0.clarify?.requestId == "conduit-push-q1" }
        XCTAssertEqual(cards.count, 1, "Exactly one promoted clarify card")
        XCTAssertEqual(cards.first?.clarify?.requestId, "conduit-push-q1", "Request ids are never rewritten")
        cache.consolidateUnderDurableKey(
            profile: profile,
            durableSessionID: "stored-a",
            runtimeAliases: ["runtime-old"]
        )
        let mergedAgain = cache.merge(probe, profile: profile, sessionIDs: ["stored-a"], includePendingClarifications: true)
        XCTAssertEqual(
            mergedAgain.filter { $0.clarify?.requestId == "conduit-push-q1" }.count, 1,
            "Promotion dedupes by decision key"
        )
        XCTAssertTrue(
            cache.merge(probe, profile: profile, sessionIDs: ["runtime-old"], includePendingClarifications: true)
                .filter { $0.clarify?.requestId == "conduit-push-q1" }.isEmpty,
            "The runtime alias key is retired"
        )
    }

    func testConsolidationRefreshesExpiredDurableMarkerSoPromotedCardStaysVisible() throws {
        // A durable record whose unconfirmed marker has expired must not
        // kill a freshly promoted card: promotion refreshes the marker from
        // the contributing alias so the card renders after the promotion.
        let (cache, cacheDefaults, tickClock, _) = try makeIsolatedCache()
        let profile = "expired-marker"
        let expiredApproval = ApprovalActivity(
            sessionId: "stored-a",
            command: "",
            description: "Old durable card",
            choices: ["once", "deny"],
            allowPermanent: false,
            smartDenied: false,
            status: .pending,
            choice: nil,
            error: nil
        )
        cache.save(
            [
                ChatMessage(
                    id: "approval-old",
                    role: .approval,
                    content: "Old durable card",
                    timestamp: "old-ts",
                    approval: expiredApproval
                )
            ],
            profile: profile,
            sessionIDs: ["stored-a"],
            unconfirmedPendingDecisionKeys: ["approval:stored-a"]
        )
        // Age the durable record's marker past the 24h unconfirmed window.
        for _ in 0..<8_700 { tickClock() }
        let freshApproval = ApprovalActivity(
            sessionId: "runtime-x",
            command: "",
            description: "Fresh push approval",
            choices: ["once", "deny"],
            allowPermanent: false,
            smartDenied: false,
            status: .pending,
            choice: nil,
            error: nil
        )
        cache.recordPendingDecision(
            ChatMessage(
                id: "approval-fresh",
                role: .approval,
                content: "Fresh push approval",
                timestamp: "fresh-ts",
                approval: freshApproval
            ),
            profile: profile,
            sessionIDs: ["runtime-x"]
        )
        XCTAssertEqual(
            cache.storedPendingDecisionKeys(profile: profile, sessionIDs: ["runtime-x"]),
            ["approval:runtime-x"],
            "Fixture check: the fresh card is staged under the runtime key"
        )
        XCTAssertTrue(
            cache.unconfirmedPendingDecisionDate(profile: profile, sessionIDs: ["stored-a"]).map {
                cache.isUnconfirmedPendingDecisionExpired(since: $0)
            } ?? false,
            "Fixture check: the durable marker is expired at consolidation time"
        )

        cache.consolidateUnderDurableKey(
            profile: profile,
            durableSessionID: "stored-a",
            runtimeAliases: ["runtime-x"]
        )

        XCTAssertEqual(
            cache.storedPendingDecisionKeys(profile: profile, sessionIDs: ["stored-a"]),
            ["approval:stored-a"],
            "Promotion must land the fresh card in the durable record"
        )

        let probe = [
            ChatMessage(id: "approval-fresh", role: .approval, content: "Fresh push approval", timestamp: "")
        ]
        let merged = cache.merge(
            probe,
            profile: profile,
            sessionIDs: ["stored-a"],
            includePendingApprovals: true
        )
        XCTAssertEqual(
            merged.first?.approval?.description, "Fresh push approval",
            "The freshly promoted card must not be killed by the durable record's expired marker"
        )
        XCTAssertEqual(merged.first?.approval?.sessionId, "stored-a")
    }

    func testConsolidationStaleAliasNeverOverwritesDurableTranscript() throws {
        // Inverse protection: a stale alias snapshot with NO new pending
        // decision must not touch the durable transcript presentation at
        // all — the alias key is simply retired.
        let (cache, _, tickClock, _) = try makeIsolatedCache()
        let profile = "stale-alias"
        let durableMessages = [
            ChatMessage(id: "d1", role: .assistant, content: "Fresh row", timestamp: "fresh-ts"),
            ChatMessage(id: "d2", role: .user, content: "Second", timestamp: "fresh-ts-2"),
        ]
        cache.save(durableMessages, profile: profile, sessionIDs: ["stored-a"])
        tickClock()
        let staleMessages = [
            ChatMessage(id: "s1", role: .assistant, content: "Stale row", timestamp: "stale-ts"),
        ]
        cache.save(staleMessages, profile: profile, sessionIDs: ["runtime-x"])

        cache.consolidateUnderDurableKey(
            profile: profile,
            durableSessionID: "stored-a",
            runtimeAliases: ["runtime-x"]
        )

        let probe = durableMessages.map { message in
            ChatMessage(id: message.id, role: message.role, content: message.content, timestamp: "")
        }
        XCTAssertEqual(
            cache.merge(probe, profile: profile, sessionIDs: ["stored-a"]).map(\.timestamp),
            ["fresh-ts", "fresh-ts-2"],
            "The durable transcript presentation is unchanged"
        )
        XCTAssertTrue(
            cache.merge(
                staleMessages.map { message in
                    ChatMessage(id: message.id, role: message.role, content: message.content, timestamp: "")
                },
                profile: profile,
                sessionIDs: ["runtime-x"]
            ).allSatisfy { $0.timestamp.isEmpty },
            "The stale alias key is retired"
        )
    }

    func testConsolidationPreservesPendingClarifyThroughEstablishment() throws {
        // A pending clarify recorded under a runtime-only identity survives
        // the runtime→durable establishment migration.
        let (cache, _, tickClock, _) = try makeIsolatedCache()
        let profile = "clarify-migrate"
        let clarify = ClarifyActivity(
            requestId: "conduit-push-xyz",
            question: "Which env?",
            choices: [ClarifyChoice(label: "staging", value: "staging")],
            status: .pending,
            answer: nil,
            error: nil
        )
        cache.save(
            [
                ChatMessage(
                    id: "clarify-conduit-push-xyz",
                    role: .clarify,
                    content: "Which env?",
                    timestamp: "c-ts",
                    clarify: clarify
                )
            ],
            profile: profile,
            sessionIDs: ["runtime-only"]
        )
        tickClock()

        cache.consolidateUnderDurableKey(
            profile: profile,
            durableSessionID: "stored-a",
            runtimeAliases: ["runtime-only"]
        )

        let probe = [ChatMessage(id: "probe", role: .assistant, content: "p", timestamp: "")]
        let restored = cache.merge(probe, profile: profile, sessionIDs: ["stored-a"], includePendingClarifications: true)
        XCTAssertTrue(
            restored.contains { $0.clarify?.requestId == "conduit-push-xyz" && $0.clarify?.status == .pending },
            "The pending clarify migrates with the record"
        )
    }


    // MARK: - Multiple session IDs

    func testSaveAndMergeAcrossLineageSessionIds() {
        let cache = SessionPresentationCache.shared
        let primaryId = "test-lineage-primary-\(UUID().uuidString)"
        let altId = "test-lineage-alt-\(UUID().uuidString)"
        let profile = "test"

        let messages = [
            ChatMessage(id: "msg-1", role: .user, content: "Hello", timestamp: "2024-01-01"),
        ]
        cache.save(messages, profile: profile, sessionIDs: [primaryId, altId])

        // Merging with altId should still find the cache
        let gatewayMessages = [
            ChatMessage(id: "msg-1", role: .user, content: "Hello", timestamp: ""),
        ]
        let merged = cache.merge(gatewayMessages, profile: profile, sessionIDs: [altId])

        XCTAssertEqual(merged[0].timestamp, "2024-01-01")

        cache.clear(profile: profile)
    }

    // MARK: - Multi-alias merge: logical-snapshot deduplication

    /// Isolated cache with a manually advanced clock so alias-write order
    /// (and therefore CachedSession.updatedAt comparisons) is deterministic.
    private func makeIsolatedCache() throws -> (cache: SessionPresentationCache, defaults: UserDefaults, tickClock: () -> Void, suiteName: String) {
        let suiteName = "SessionPresentationCacheTests.dedup." + UUID().uuidString
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName),
            "Could not create isolated UserDefaults suite"
        )
        let clock = DeterministicClock()
        let cache = SessionPresentationCache(defaults: defaults, now: { clock.currentValue() })
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (cache, defaults, { clock.advance() }, suiteName)
    }

    /// THE reported bug shape: one transcript saved under [primary,
    /// resolved] and later REWRITTEN through only one alias with fresher
    /// presentation metadata (same messages - Hermes re-stamped them).
    /// Merging through both aliases must yield the freshest snapshot's
    /// metadata exactly once per row. The old duplicated-candidate pool
    /// flattened both generations and could attach stale metadata.
    func testDualAliasMergeYieldsFreshestSnapshotOncePerRow() throws {
        let (cache, _, tickClock, _) = try makeIsolatedCache()
        let primaryId = "alias-primary-" + UUID().uuidString
        let resolvedId = "alias-resolved-" + UUID().uuidString
        let profile = "test"

        func generation(prefix: String) -> [ChatMessage] {
            (1...5).map { index in
                ChatMessage(
                    id: "gen-row-" + String(index),
                    role: .assistant,
                    content: "Status digest " + String(index),
                    timestamp: prefix + String(index)
                )
            }
        }

        cache.save(generation(prefix: "stale-"), profile: profile, sessionIDs: [primaryId, resolvedId])
        tickClock()
        cache.save(generation(prefix: "fresh-"), profile: profile, sessionIDs: [resolvedId])

        // Regenerated ids force fingerprint-based matching instead of the
        // exact-id path.
        let gatewayMessages = (1...5).map { index in
            ChatMessage(id: "gw-" + String(index), role: .assistant, content: "Status digest " + String(index), timestamp: "")
        }
        let merged = cache.merge(gatewayMessages, profile: profile, sessionIDs: [primaryId, resolvedId])

        XCTAssertEqual(
            merged.map(\.timestamp),
            ["fresh-1", "fresh-2", "fresh-3", "fresh-4", "fresh-5"]
        )
        cache.clear(profile: profile)
    }

    /// Tool-call flavor of the same drift: same tool name, fresher input
    /// preview. Duplicated candidates must not cross-wire row one's input
    /// with row two's.
    func testRepeatedToolCallsKeepDistinctFreshMetadataAcrossAliases() throws {
        let (cache, _, tickClock, _) = try makeIsolatedCache()
        let primaryId = "tool-primary-" + UUID().uuidString
        let resolvedId = "tool-resolved-" + UUID().uuidString
        let profile = "test"

        func toolGeneration(prefix: String) -> [ChatMessage] {
            (1...2).map { index in
                ChatMessage(
                    id: "tool-row-" + String(index),
                    role: .tool,
                    content: "",
                    timestamp: prefix + "ts-" + String(index),
                    tool: ToolActivity(
                        id: nil,
                        name: "deploy",
                        input: prefix + "input-" + String(index),
                        output: prefix + "output-" + String(index),
                        status: .complete
                    )
                )
            }
        }

        cache.save(toolGeneration(prefix: "stale-"), profile: profile, sessionIDs: [primaryId, resolvedId])
        tickClock()
        cache.save(toolGeneration(prefix: "fresh-"), profile: profile, sessionIDs: [resolvedId])

        let gatewayMessages = (1...2).map { index in
            ChatMessage(
                id: "gw-tool-" + String(index),
                role: .tool,
                content: "",
                timestamp: "",
                tool: ToolActivity(id: nil, name: "deploy", input: nil, output: nil, status: .complete)
            )
        }
        let merged = cache.merge(gatewayMessages, profile: profile, sessionIDs: [primaryId, resolvedId])

        XCTAssertEqual(merged[0].tool?.input, "fresh-input-1")
        XCTAssertEqual(merged[1].tool?.input, "fresh-input-2")
        XCTAssertEqual(merged[0].timestamp, "fresh-ts-1")
        cache.clear(profile: profile)
    }

    // MARK: - Merge: pending tool restoration

    func testMergeRestoresLaterPendingToolAfterHistoricalCompletionWithSameInput() throws {
        let (cache, _, _, _) = try makeIsolatedCache()
        let profile = "pending-tool-same-input"
        let sessionID = "pending-tool-" + UUID().uuidString
        let historical = ChatMessage(
            id: "cached-historical",
            role: .tool,
            content: "",
            timestamp: "older",
            tool: ToolActivity(id: nil, name: "terminal", input: "git status", output: "clean", status: .complete)
        )
        let pending = ChatMessage(
            id: "cached-pending",
            role: .tool,
            content: "",
            timestamp: "newer",
            tool: ToolActivity(id: nil, name: "terminal", input: "git status", output: nil, status: .running)
        )
        cache.save([historical], profile: profile, sessionIDs: [sessionID])
        cache.recordPendingToolStart(pending, profile: profile, sessionIDs: [sessionID])

        let gatewayHistorical = ChatMessage(
            id: "gateway-historical",
            role: .tool,
            content: "",
            timestamp: "",
            tool: ToolActivity(id: nil, name: "terminal", input: "git status", output: "clean", status: .complete)
        )
        let merged = cache.merge(
            [gatewayHistorical],
            profile: profile,
            sessionIDs: [sessionID],
            includePendingTools: true
        )

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.last?.id, pending.id)
        XCTAssertEqual(merged.last?.tool?.status, .running)
    }

    func testMergeKeepsPendingOnlyCacheWhenGatewayHasHistoricalSameNameCompletion() throws {
        let (cache, _, _, _) = try makeIsolatedCache()
        let profile = "pending-tool-only"
        let sessionID = "pending-only-" + UUID().uuidString
        let pending = ChatMessage(
            id: "cached-pending-only",
            role: .tool,
            content: "",
            timestamp: "newer",
            tool: ToolActivity(id: nil, name: "terminal", input: "git status", output: nil, status: .running)
        )
        cache.recordPendingToolStart(pending, profile: profile, sessionIDs: [sessionID])

        let merged = cache.merge(
            [
                ChatMessage(
                    id: "gateway-historical",
                    role: .tool,
                    content: "",
                    timestamp: "",
                    tool: ToolActivity(id: nil, name: "terminal", input: "pwd", output: "/repo", status: .complete)
                ),
            ],
            profile: profile,
            sessionIDs: [sessionID],
            includePendingTools: true
        )

        XCTAssertEqual(merged.map(\.id), ["gateway-historical", pending.id])
        XCTAssertEqual(merged.last?.tool?.status, .running)
    }

    func testMergeDoesNotResurrectPendingToolWhenCompletionSharesMessageIdentity() throws {
        let (cache, _, _, _) = try makeIsolatedCache()
        let profile = "resolved-pending-tool"
        let sessionID = "resolved-pending-" + UUID().uuidString
        let historical = ChatMessage(
            id: "cached-historical",
            role: .tool,
            content: "",
            timestamp: "older",
            tool: ToolActivity(id: nil, name: "terminal", input: "pwd", output: "/repo", status: .complete)
        )
        let pending = ChatMessage(
            id: "cached-pending",
            role: .tool,
            content: "",
            timestamp: "newer",
            tool: ToolActivity(id: nil, name: "terminal", input: "git status", output: nil, status: .running)
        )
        cache.save([historical], profile: profile, sessionIDs: [sessionID])
        cache.recordPendingToolStart(pending, profile: profile, sessionIDs: [sessionID])

        let gatewayMessages = [
            ChatMessage(
                id: "gateway-before-cache-window",
                role: .tool,
                content: "",
                timestamp: "",
                tool: ToolActivity(id: nil, name: "terminal", input: "echo earlier", output: "earlier", status: .complete)
            ),
            ChatMessage(
                id: "gateway-historical",
                role: .tool,
                content: "",
                timestamp: "",
                tool: ToolActivity(id: nil, name: "terminal", input: "pwd", output: "/repo", status: .complete)
            ),
            ChatMessage(
                id: pending.id,
                role: .tool,
                content: "",
                timestamp: "",
                tool: ToolActivity(id: nil, name: "terminal", input: "git status", output: "clean", status: .complete)
            ),
        ]
        let merged = cache.merge(
            gatewayMessages,
            profile: profile,
            sessionIDs: [sessionID],
            includePendingTools: true
        )

        XCTAssertEqual(merged.count, gatewayMessages.count)
        XCTAssertEqual(merged.last?.id, pending.id)
        XCTAssertEqual(merged.last?.tool?.status, .complete)
        XCTAssertFalse(merged.contains { $0.tool?.status == .running })
    }

    func testMergeKeepsPendingToolWhenCompletionHasDifferentKnownIdentity() throws {
        let (cache, _, _, _) = try makeIsolatedCache()
        let profile = "ambiguous-completed-tool"
        let sessionID = "ambiguous-completed-" + UUID().uuidString
        let pending = ChatMessage(
            id: "cached-pending",
            role: .tool,
            content: "",
            timestamp: "newer",
            tool: ToolActivity(id: "cached-tool", name: "terminal", input: "git status", output: nil, status: .running)
        )
        cache.recordPendingToolStart(pending, profile: profile, sessionIDs: [sessionID])

        let gatewayCompletion = ChatMessage(
            id: "gateway-completion",
            role: .tool,
            content: "",
            timestamp: "",
            tool: ToolActivity(id: "gateway-tool", name: "terminal", input: "git status", output: "clean", status: .complete)
        )
        let merged = cache.merge(
            [gatewayCompletion],
            profile: profile,
            sessionIDs: [sessionID],
            includePendingTools: true
        )

        XCTAssertEqual(merged.map(\.id), [gatewayCompletion.id, pending.id])
        XCTAssertEqual(merged.last?.tool?.status, .running)
    }

    func testMergeKeepsDistinctRunningToolWhenKnownToolIDsConflict() throws {
        let (cache, _, _, _) = try makeIsolatedCache()
        let profile = "ambiguous-running-tool"
        let sessionID = "ambiguous-running-" + UUID().uuidString
        let pending = ChatMessage(
            id: "cached-pending",
            role: .tool,
            content: "",
            timestamp: "newer",
            tool: ToolActivity(id: "cached-tool", name: "terminal", input: "git status", output: nil, status: .running)
        )
        cache.recordPendingToolStart(pending, profile: profile, sessionIDs: [sessionID])

        let gatewayRunning = ChatMessage(
            id: "gateway-running",
            role: .tool,
            content: "",
            timestamp: "",
            tool: ToolActivity(id: "gateway-tool", name: "terminal", input: "git status", output: nil, status: .running)
        )
        let merged = cache.merge(
            [gatewayRunning],
            profile: profile,
            sessionIDs: [sessionID],
            includePendingTools: true
        )

        XCTAssertEqual(merged.map(\.id), [gatewayRunning.id, pending.id])
        XCTAssertEqual(merged.filter { $0.tool?.status == .running }.count, 2)
    }

    func testMergeRestoresLaterPendingToolOnceAcrossAliasesAfterDifferentHistoricalInput() throws {
        let (cache, _, _, _) = try makeIsolatedCache()
        let profile = "pending-tool-aliases"
        let requestedID = "pending-tool-requested-" + UUID().uuidString
        let resolvedID = "pending-tool-resolved-" + UUID().uuidString
        let historical = ChatMessage(
            id: "cached-historical",
            role: .tool,
            content: "",
            timestamp: "older",
            tool: ToolActivity(id: nil, name: "terminal", input: "pwd", output: "/repo", status: .complete)
        )
        let pending = ChatMessage(
            id: "cached-pending",
            role: .tool,
            content: "",
            timestamp: "newer",
            tool: ToolActivity(id: nil, name: "terminal", input: "git status", output: nil, status: .running)
        )
        cache.save([historical], profile: profile, sessionIDs: [requestedID, resolvedID])
        cache.recordPendingToolStart(pending, profile: profile, sessionIDs: [requestedID, resolvedID])

        let merged = cache.merge(
            [
                ChatMessage(
                    id: "gateway-historical",
                    role: .tool,
                    content: "",
                    timestamp: "",
                    tool: ToolActivity(id: nil, name: " TERMINAL ", input: "pwd", output: "/repo", status: .complete)
                ),
            ],
            profile: profile,
            sessionIDs: [resolvedID, requestedID],
            includePendingTools: true
        )

        XCTAssertEqual(merged.filter { $0.tool?.status == .running }.map(\.id), [pending.id])
        XCTAssertEqual(merged.count, 2)
    }

    /// Duplicate STRINGS inside sessionIDs behave like any other
    /// multi-alias lookup rather than a doubled pool.
    func testDuplicateStringsInsideSessionIDsDoNotDuplicateCandidates() throws {
        let (cache, _, _, _) = try makeIsolatedCache()
        let sessionId = "dup-string-" + UUID().uuidString
        let profile = "test"

        let savedMessages = [
            ChatMessage(id: "twin-a", role: .assistant, content: "Twin status A", timestamp: "twin-ts-a"),
            ChatMessage(id: "twin-b", role: .assistant, content: "Twin status B", timestamp: "twin-ts-b"),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])

        let gatewayMessages = [
            ChatMessage(id: "gw-twin-a", role: .assistant, content: "Twin status A", timestamp: ""),
            ChatMessage(id: "gw-twin-b", role: .assistant, content: "Twin status B", timestamp: ""),
        ]
        let merged = cache.merge(gatewayMessages, profile: profile, sessionIDs: [sessionId, sessionId])

        XCTAssertEqual(merged[0].timestamp, "twin-ts-a")
        XCTAssertEqual(merged[1].timestamp, "twin-ts-b")
        cache.clear(profile: profile)
    }

    /// Single-alias lookup keeps working exactly as before.
    func testSingleAliasMergeUnchangedByDeduplication() throws {
        let (cache, _, _, _) = try makeIsolatedCache()
        let sessionId = "single-" + UUID().uuidString
        let profile = "test"

        cache.save(
            [ChatMessage(id: "keep-1", role: .assistant, content: "Saved once", timestamp: "kept-ts")],
            profile: profile,
            sessionIDs: [sessionId]
        )
        let merged = cache.merge(
            [ChatMessage(id: "keep-1", role: .assistant, content: "Saved once", timestamp: "")],
            profile: profile,
            sessionIDs: [sessionId]
        )
        XCTAssertEqual(merged[0].timestamp, "kept-ts")
        cache.clear(profile: profile)
    }

    /// Two supplied IDs that hold genuinely DIFFERENT snapshots must both
    /// stay available to the matcher: dedup keys on whole-record logical
    /// identity, never on surface similarity of individual rows.
    func testDifferentSnapshotsRemainAvailableToMatcher() throws {
        let (cache, _, _, _) = try makeIsolatedCache()
        let primaryId = "distinct-primary-" + UUID().uuidString
        let resolvedId = "distinct-resolved-" + UUID().uuidString
        let profile = "test"

        cache.save(
            [ChatMessage(id: "a-row", role: .assistant, content: "snapshot alpha", timestamp: "alpha-ts")],
            profile: profile,
            sessionIDs: [primaryId]
        )
        cache.save(
            [
                ChatMessage(id: "b-row", role: .assistant, content: "snapshot beta", timestamp: "beta-ts"),
                ChatMessage(id: "c-row", role: .user, content: "snapshot gamma", timestamp: "gamma-ts"),
            ],
            profile: profile,
            sessionIDs: [resolvedId]
        )

        let gatewayMessages = [
            ChatMessage(id: "a-row", role: .assistant, content: "snapshot alpha", timestamp: ""),
            ChatMessage(id: "b-row", role: .assistant, content: "snapshot beta", timestamp: ""),
            ChatMessage(id: "c-row", role: .user, content: "snapshot gamma", timestamp: ""),
        ]
        let merged = cache.merge(gatewayMessages, profile: profile, sessionIDs: [primaryId, resolvedId])

        XCTAssertEqual(merged[0].timestamp, "alpha-ts")
        XCTAssertEqual(merged[1].timestamp, "beta-ts")
        XCTAssertEqual(merged[2].timestamp, "gamma-ts")
        cache.clear(profile: profile)
    }

    /// Pins the documented tie contract for DIVERGENT snapshots: equal-
    /// scoring rows resolve to the earliest pool position, which is this
    /// call's argument order (production passes [resolved, requested] so
    /// the live write leads). Here the newer-written alias is listed
    /// second; precedence still follows argument order by design.
    func testDivergentSnapshotTieResolvesByAliasArgumentOrder() throws {
        let (cache, _, tickClock, _) = try makeIsolatedCache()
        let requestedId = "tie-requested-" + UUID().uuidString
        let resolvedId = "tie-resolved-" + UUID().uuidString
        let profile = "test"

        // Older write lands under the SECOND-listed alias...
        cache.save(
            [ChatMessage(id: "", role: .assistant, content: "Drifted row", timestamp: "older-ts")],
            profile: profile,
            sessionIDs: [requestedId]
        )
        tickClock()
        // ...and the newer write under the FIRST-listed alias. Rows share
        // role+signature shape via identical content; identities diverge
        // only through their stamps being absent from the identity key.
        // Different toolName-free assistant rows with the same text and
        // id have the SAME identity, so instead give genuinely different
        // ids: both records stay in the pool and the tie must follow
        // argument order.
        cache.save(
            [ChatMessage(id: "drift-b", role: .assistant, content: "Drifted row", timestamp: "newer-ts")],
            profile: profile,
            sessionIDs: [resolvedId]
        )

        let gatewayMessages = [
            ChatMessage(id: "gw-drift-a", role: .assistant, content: "Drifted row", timestamp: ""),
            ChatMessage(id: "gw-drift-b", role: .assistant, content: "Drifted row", timestamp: ""),
        ]
        let merged = cache.merge(gatewayMessages, profile: profile, sessionIDs: [resolvedId, requestedId])

        XCTAssertEqual(
            Set(merged.compactMap(\.timestamp)),
            Set(["older-ts", "newer-ts"]),
            "both divergent snapshots stay available to the matcher"
        )
        XCTAssertNotEqual(
            merged[0].timestamp, merged[1].timestamp,
            "distinct gateway rows must consume distinct candidates"
        )
        cache.clear(profile: profile)
    }

    // MARK: - Merge: pending clarification restoration

    func testMergeRestoresPendingClarificationWhenRequested() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-merge-clarify-\(UUID().uuidString)"
        let profile = "test"

        let clarify = ClarifyActivity(
            requestId: "req-123",
            question: "Which color?",
            choices: [
                ClarifyChoice(label: "Red", value: "red"),
                ClarifyChoice(label: "Blue", value: "blue"),
            ],
            status: .pending
        )
        let savedMessages = [
            ChatMessage(
                id: "clarify-req-123",
                role: .clarify,
                content: "Which color?",
                timestamp: "2024-01-01T10:00:00Z",
                clarify: clarify
            ),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])
        defer { cache.clear(profile: profile) }

        // Gateway resume omits the clarify card (compact history)
        let gatewayMessages: [ChatMessage] = []
        let merged = cache.merge(
            gatewayMessages,
            profile: profile,
            sessionIDs: [sessionId],
            includePendingClarifications: true
        )

        let restoredClarify = merged.first { $0.role == .clarify }
        XCTAssertNotNil(restoredClarify, "Pending clarification should be restored from cache")
        XCTAssertEqual(restoredClarify?.clarify?.requestId, "req-123")
        XCTAssertEqual(restoredClarify?.clarify?.status, .pending)
        XCTAssertEqual(restoredClarify?.clarify?.questions.first?.choices.count, 2)
    }

    func testMergeDoesNotRestoreClarificationWhenNotRequested() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-merge-clarify-off-\(UUID().uuidString)"
        let profile = "test"

        let clarify = ClarifyActivity(
            requestId: "req-456",
            question: "Pick one",
            choices: [ClarifyChoice(label: "A", value: "a")],
            status: .pending
        )
        let savedMessages = [
            ChatMessage(
                id: "clarify-req-456",
                role: .clarify,
                content: "Pick one",
                timestamp: "2024-01-01",
                clarify: clarify
            ),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])
        defer { cache.clear(profile: profile) }

        let gatewayMessages: [ChatMessage] = []
        let merged = cache.merge(
            gatewayMessages,
            profile: profile,
            sessionIDs: [sessionId],
            includePendingClarifications: false
        )

        XCTAssertFalse(merged.contains { $0.role == .clarify },
                       "Clarification should not be restored when includePendingClarifications is false")
    }

    func testMergeDoesNotRestoreAnsweredClarification() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-merge-clarify-answered-\(UUID().uuidString)"
        let profile = "test"

        let clarify = ClarifyActivity(
            requestId: "req-789",
            question: "Done?",
            choices: [ClarifyChoice(label: "Yes", value: "yes")],
            status: .answered,
            answer: "yes"
        )
        let savedMessages = [
            ChatMessage(
                id: "clarify-req-789",
                role: .clarify,
                content: "Done?",
                timestamp: "2024-01-01",
                clarify: clarify
            ),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])
        defer { cache.clear(profile: profile) }

        let gatewayMessages: [ChatMessage] = []
        let merged = cache.merge(
            gatewayMessages,
            profile: profile,
            sessionIDs: [sessionId],
            includePendingClarifications: true
        )

        XCTAssertFalse(merged.contains { $0.role == .clarify },
                       "Answered clarification should not be restored as pending")
    }

    func testMergeRestoresClarificationWhenRunningIsNil() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-merge-clarify-nil-\(UUID().uuidString)"
        let profile = "test"

        let clarify = ClarifyActivity(
            requestId: "req-nil",
            question: "Pick?",
            choices: [ClarifyChoice(label: "X", value: "x")],
            status: .pending
        )
        let savedMessages = [
            ChatMessage(
                id: "clarify-req-nil",
                role: .clarify,
                content: "Pick?",
                timestamp: "2024-01-01",
                clarify: clarify
            ),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])
        defer { cache.clear(profile: profile) }

        let gatewayMessages: [ChatMessage] = []
        let merged = cache.merge(
            gatewayMessages,
            profile: profile,
            sessionIDs: [sessionId],
            includePendingClarifications: true
        )

        XCTAssertTrue(merged.contains { $0.role == .clarify },
                      "Clarification should be restored when running state is omitted (nil)")
    }

    // MARK: - Merge: pending approval restoration

    func testApplyChatResumeRestoresAuthoritativePendingApprovalWithoutCache() throws {
        let suiteName = "conduit.tests.pending-approval-snapshot-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let cache = SessionPresentationCache(defaults: defaults)
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: { cache.clear() },
            sessionPresentationCache: cache
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(appState.applyChatResume(SessionResumeResult(
            sessionId: "runtime-approval",
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [
                "running": .bool(true),
                "pending_approval": .object([
                    "request_id": .string("approval-42"),
                    "command": .string("deploy"),
                    "description": .string("Deploy now?"),
                    "choices": .array([.string("once"), .string("deny")])
                ])
            ])
        )))

        let card = try XCTUnwrap(appState.messages.first?.approval)
        XCTAssertEqual(card.requestId, "approval-42")
        XCTAssertEqual(card.sessionId, "runtime-approval")
        XCTAssertEqual(card.status, .pending)
    }

    func testAuthoritativeApprovalResetsSameCachedSubmittingRequestAndDropsLegacyAmbiguity() throws {
        let suiteName = "conduit.tests.pending-approval-authority-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let cache = SessionPresentationCache(defaults: defaults)
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: { cache.clear() },
            sessionPresentationCache: cache
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sessionId = "approval-authority"
        let cards = [
            ApprovalActivity(sessionId: sessionId, requestId: "req-current", command: "old", description: "Old text", choices: nil, allowPermanent: false, smartDenied: false, status: .submitting),
            ApprovalActivity(sessionId: sessionId, command: "legacy", description: "Legacy card", choices: nil, allowPermanent: false, smartDenied: false, status: .pending)
        ].enumerated().map { index, approval in
            ChatMessage(id: "approval-\(index)", role: .approval, content: approval.description, timestamp: "1", approval: approval)
        }
        cache.save(cards, profile: appState.activeProfile, sessionIDs: [sessionId])

        XCTAssertTrue(appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [
                "pending_approval": .object([
                    "request_id": .string("req-current"),
                    "command": .string("new"),
                    "description": .string("Current text")
                ])
            ])
        )))

        let approvals = appState.messages.compactMap(\.approval)
        XCTAssertEqual(approvals.count, 1)
        XCTAssertEqual(approvals[0].requestId, "req-current")
        XCTAssertEqual(approvals[0].description, "Current text")
        XCTAssertEqual(approvals[0].status, .pending)
    }

    func testCacheKeepsTwoRequestIdentifiedApprovalsForOneSessionDistinct() throws {
        let suiteName = "conduit.tests.approval-request-identity-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let cache = SessionPresentationCache(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sessionId = "same-session"
        for requestId in ["req-a", "req-b"] {
            let approval = ApprovalActivity(
                sessionId: sessionId,
                requestId: requestId,
                command: requestId,
                description: requestId,
                choices: nil,
                allowPermanent: false,
                smartDenied: false,
                status: .pending
            )
            cache.recordPendingDecision(
                ChatMessage(id: requestId, role: .approval, content: requestId, timestamp: "1", approval: approval),
                profile: "default",
                sessionIDs: [sessionId]
            )
        }

        let restored = cache.merge(
            [], profile: "default", sessionIDs: [sessionId], includePendingApprovals: true
        ).compactMap(\.approval)
        XCTAssertEqual(Set(restored.compactMap(\.requestId)), Set(["req-a", "req-b"]))
    }

    func testMergeRestoresPendingApprovalWhenRequested() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-merge-approval-\(UUID().uuidString)"
        let profile = "test"

        let approval = ApprovalActivity(
            sessionId: sessionId,
            command: "rm -rf /tmp",
            description: "Delete temp files",
            choices: ["once", "session", "always", "deny"],
            allowPermanent: true,
            smartDenied: false,
            status: .pending
        )
        let savedMessages = [
            ChatMessage(
                id: "approval-\(sessionId)",
                role: .approval,
                content: "Delete temp files",
                timestamp: "2024-01-01T10:00:00Z",
                approval: approval
            ),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])
        defer { cache.clear(profile: profile) }

        // Gateway resume omits the approval card
        let gatewayMessages: [ChatMessage] = []
        let merged = cache.merge(
            gatewayMessages,
            profile: profile,
            sessionIDs: [sessionId],
            includePendingApprovals: true
        )

        let restoredApproval = merged.first { $0.role == .approval }
        XCTAssertNotNil(restoredApproval, "Pending approval should be restored from cache")
        XCTAssertEqual(restoredApproval?.approval?.sessionId, sessionId)
        XCTAssertEqual(restoredApproval?.approval?.status, .pending)
    }

    func testRecordPendingDecisionRestoresApprovalWithoutDisturbingTranscript() {
        let suiteName = "conduit.tests.record-decision-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: defaults)
        let sessionId = "test-record-\(UUID().uuidString)"
        let profile = "test"
        defer {
            cache.clear(profile: profile)
            defaults.removePersistentDomain(forName: suiteName)
        }

        // Seed the cached transcript the way a normal save would.
        let transcript = [
            ChatMessage(id: "u1", role: .user, content: "please clean tmp", timestamp: "t1"),
            ChatMessage(id: "a1", role: .assistant, content: "on it", timestamp: "t2"),
        ]
        cache.save(transcript, profile: profile, sessionIDs: [sessionId])

        // A push delivers a pending approval card that arrived while backgrounded.
        let approval = ApprovalActivity(
            sessionId: sessionId,
            command: "",
            description: "Delete temp files",
            choices: ["once", "deny"],
            allowPermanent: false,
            smartDenied: false,
            status: .pending,
            choice: nil,
            error: nil
        )
        let card = ChatMessage(
            id: "approval-\(sessionId)",
            role: .approval,
            content: "Delete temp files",
            timestamp: "t3",
            approval: approval
        )
        cache.recordPendingDecision(card, profile: profile, sessionIDs: [sessionId])

        // Gateway resume replays the transcript but omits the one-shot approval event.
        let merged = cache.merge(
            transcript,
            profile: profile,
            sessionIDs: [sessionId],
            includePendingApprovals: true
        )

        let restored = merged.first { $0.role == .approval }
        XCTAssertEqual(restored?.approval?.sessionId, sessionId)
        XCTAssertEqual(restored?.approval?.status, .pending)
        // The transcript rows survive the upsert (non-destructive).
        XCTAssertTrue(merged.contains { $0.id == "u1" })
        XCTAssertTrue(merged.contains { $0.id == "a1" })
    }

    func testRecordPendingDecisionReplacesExistingCardForSameDecision() {
        let suiteName = "conduit.tests.record-decision-dedupe-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: defaults)
        let sessionId = "test-record-dedupe-\(UUID().uuidString)"
        let profile = "test"
        defer {
            cache.clear(profile: profile)
            defaults.removePersistentDomain(forName: suiteName)
        }

        func card(description: String) -> ChatMessage {
            ChatMessage(
                id: "approval-\(sessionId)",
                role: .approval,
                content: description,
                timestamp: "t",
                approval: ApprovalActivity(
                    sessionId: sessionId,
                    command: "",
                    description: description,
                    choices: ["once", "deny"],
                    allowPermanent: false,
                    smartDenied: false,
                    status: .pending,
                    choice: nil,
                    error: nil
                )
            )
        }
        cache.recordPendingDecision(card(description: "old"), profile: profile, sessionIDs: [sessionId])
        cache.recordPendingDecision(card(description: "new"), profile: profile, sessionIDs: [sessionId])

        let merged = cache.merge([], profile: profile, sessionIDs: [sessionId], includePendingApprovals: true)
        let approvals = merged.filter { $0.role == .approval }
        XCTAssertEqual(approvals.count, 1, "Recording the same decision twice must not duplicate the card")
        XCTAssertEqual(approvals.first?.approval?.description, "new")
    }

    func testRecordPendingDecisionAppliesAcrossRuntimeAndStoredSessionIDs() {
        let suiteName = "conduit.tests.record-decision-ids-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: defaults)
        let profile = "test"
        let runtimeID = "runtime-\(UUID().uuidString)"
        let storedID = "stored-\(UUID().uuidString)"
        defer {
            cache.clear(profile: profile)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let card = ChatMessage(
            id: "approval-\(runtimeID)",
            role: .approval,
            content: "Delete temp files",
            timestamp: "t",
            approval: ApprovalActivity(
                sessionId: runtimeID,
                command: "",
                description: "Delete temp files",
                choices: ["once", "deny"],
                allowPermanent: false,
                smartDenied: false,
                status: .pending,
                choice: nil,
                error: nil
            )
        )
        // Written under both identities, as openNotificationTarget does.
        cache.recordPendingDecision(card, profile: profile, sessionIDs: [storedID, runtimeID])

        XCTAssertTrue(
            cache.merge([], profile: profile, sessionIDs: [storedID], includePendingApprovals: true)
                .contains { $0.role == .approval },
            "Card recorded under the stored id should restore on merge"
        )
        XCTAssertTrue(
            cache.merge([], profile: profile, sessionIDs: [runtimeID], includePendingApprovals: true)
                .contains { $0.role == .approval },
            "Card recorded under the runtime id should restore on merge"
        )
    }

    func testRecordPendingDecisionRestartsExpiryWindowForFreshObservation() {
        let suiteName = "conduit.tests.record-decision-expiry-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let cache = SessionPresentationCache(defaults: defaults, now: { now })
        let sessionId = "test-record-expiry-\(UUID().uuidString)"
        let profile = "test"
        defer {
            cache.clear(profile: profile)
            defaults.removePersistentDomain(forName: suiteName)
        }

        func card(description: String) -> ChatMessage {
            ChatMessage(
                id: "approval-\(sessionId)",
                role: .approval,
                content: description,
                timestamp: "t",
                approval: ApprovalActivity(
                    sessionId: sessionId,
                    command: "",
                    description: description,
                    choices: ["once", "deny"],
                    allowPermanent: false,
                    smartDenied: false,
                    status: .pending,
                    choice: nil,
                    error: nil
                )
            )
        }

        // A card recorded yesterday, beyond the 24h unconfirmed window...
        cache.recordPendingDecision(card(description: "stale"), profile: profile, sessionIDs: [sessionId])
        // ...then a fresh push-delivered observation for the same decision today.
        now = now.addingTimeInterval(25 * 60 * 60)
        cache.recordPendingDecision(card(description: "fresh"), profile: profile, sessionIDs: [sessionId])
        // An hour later the fresh card must still restore: recording it
        // restarted the bounded window instead of inheriting yesterday's stamp.
        now = now.addingTimeInterval(60 * 60)

        let merged = cache.merge([], profile: profile, sessionIDs: [sessionId], includePendingApprovals: true)
        let restored = merged.first { $0.role == .approval }
        XCTAssertEqual(
            restored?.approval?.description,
            "fresh",
            "A freshly recorded decision must not inherit an expired session marker"
        )
    }

    func testMergeDoesNotRestoreApprovalWhenNotRequested() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-merge-approval-off-\(UUID().uuidString)"
        let profile = "test"

        let approval = ApprovalActivity(
            sessionId: sessionId,
            command: "ls",
            description: "List files",
            choices: nil,
            allowPermanent: false,
            smartDenied: false,
            status: .pending
        )
        let savedMessages = [
            ChatMessage(
                id: "approval-\(sessionId)",
                role: .approval,
                content: "List files",
                timestamp: "2024-01-01",
                approval: approval
            ),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])
        defer { cache.clear(profile: profile) }

        let gatewayMessages: [ChatMessage] = []
        let merged = cache.merge(
            gatewayMessages,
            profile: profile,
            sessionIDs: [sessionId],
            includePendingApprovals: false
        )

        XCTAssertFalse(merged.contains { $0.role == .approval },
                       "Approval should not be restored when includePendingApprovals is false")
    }

    // MARK: - Save preserves restored pending cards

    func testSavePreservesRestoredClarificationCard() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-save-clarify-\(UUID().uuidString)"
        let profile = "test"

        let clarify = ClarifyActivity(
            requestId: "req-save",
            question: "Which?",
            choices: [ClarifyChoice(label: "A", value: "a")],
            status: .pending
        )
        let savedMessages = [
            ChatMessage(
                id: "clarify-req-save",
                role: .clarify,
                content: "Which?",
                timestamp: "2024-01-01T10:00:00Z",
                clarify: clarify
            ),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])
        defer { cache.clear(profile: profile) }

        // Merge restores the pending card
        let gatewayMessages: [ChatMessage] = []
        let merged = cache.merge(
            gatewayMessages,
            profile: profile,
            sessionIDs: [sessionId],
            includePendingClarifications: true
        )
        XCTAssertTrue(merged.contains { $0.role == .clarify },
                      "Card should be restored from cache")

        // Save the merged result (as applyResume does when running == true)
        cache.save(merged, profile: profile, sessionIDs: [sessionId])

        // Re-merge: the card should survive because save persisted it
        let remerged = cache.merge(
            gatewayMessages,
            profile: profile,
            sessionIDs: [sessionId],
            includePendingClarifications: true
        )
        XCTAssertTrue(remerged.contains { $0.role == .clarify },
                      "Restored clarification card must survive a save-then-merge cycle")
    }

    func testSavePreservesRestoredApprovalCard() {
        let cache = SessionPresentationCache.shared
        let sessionId = "test-save-approval-\(UUID().uuidString)"
        let profile = "test"

        let approval = ApprovalActivity(
            sessionId: sessionId,
            command: "ls",
            description: "List files",
            choices: ["once", "session", "always", "deny"],
            allowPermanent: true,
            smartDenied: false,
            status: .pending
        )
        let savedMessages = [
            ChatMessage(
                id: "approval-save",
                role: .approval,
                content: "List files",
                timestamp: "2024-01-01T10:00:00Z",
                approval: approval
            ),
        ]
        cache.save(savedMessages, profile: profile, sessionIDs: [sessionId])
        defer { cache.clear(profile: profile) }

        // Merge restores the pending card
        let gatewayMessages: [ChatMessage] = []
        let merged = cache.merge(
            gatewayMessages,
            profile: profile,
            sessionIDs: [sessionId],
            includePendingApprovals: true
        )
        XCTAssertTrue(merged.contains { $0.role == .approval },
                      "Card should be restored from cache")

        // Save the merged result (as applyResume does when running == true)
        cache.save(merged, profile: profile, sessionIDs: [sessionId])

        // Re-merge: the card should survive
        let remerged = cache.merge(
            gatewayMessages,
            profile: profile,
            sessionIDs: [sessionId],
            includePendingApprovals: true
        )
        XCTAssertTrue(remerged.contains { $0.role == .approval },
                      "Restored approval card must survive a save-then-merge cycle")
    }

    // MARK: - AppState resume integration

    func testApplyChatResumeRestoresPendingClarificationWhenRunningIsNil() {
        let suiteName = "conduit.tests.session-presentation-clarify-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: defaults)
        let sessionId = "test-apply-resume-clarify-\(UUID().uuidString)"
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: { cache.clear() },
            sessionPresentationCache: cache
        )
        let profile = appState.activeProfile
        let clarify = ClarifyActivity(
            requestId: "req-apply-resume",
            question: "Which color?",
            choices: [ClarifyChoice(label: "Red", value: "red")],
            status: .pending
        )
        cache.save([
            ChatMessage(
                id: "clarify-req-apply-resume",
                role: .clarify,
                content: clarify.displayQuestion,
                timestamp: "2024-01-01",
                clarify: clarify
            )
        ], profile: profile, sessionIDs: [sessionId])
        defer {
            cache.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [:])
        ))

        XCTAssertEqual(appState.messages.first?.clarify?.requestId, clarify.requestId)
        XCTAssertEqual(appState.messages.first?.clarify?.status, .pending)
        XCTAssertEqual(appState.turnState, TurnState.running,
                       "A restored pending clarification must keep the composer answerable")
        XCTAssertTrue(
            cache.merge(
                [],
                profile: profile,
                sessionIDs: [sessionId],
                includePendingClarifications: true
            ).contains { $0.clarify?.requestId == clarify.requestId },
            "An unconfirmed clarification card should survive a cold launch during its grace period"
        )
        appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [:])
        ))
        XCTAssertEqual(
            appState.messages.first?.clarify?.requestId,
            clarify.requestId,
            "The active AppState should retain the card for a subsequent foreground resume"
        )
    }

    func testApplyChatResumeRestoresPendingApprovalWhenRunningIsNil() {
        let suiteName = "conduit.tests.session-presentation-approval-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: defaults)
        let sessionId = "test-apply-resume-approval-\(UUID().uuidString)"
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: { cache.clear() },
            sessionPresentationCache: cache
        )
        let profile = appState.activeProfile
        let approval = ApprovalActivity(
            sessionId: sessionId,
            command: "ls",
            description: "List files",
            choices: ["once", "deny"],
            allowPermanent: false,
            smartDenied: false,
            status: .pending
        )
        cache.save([
            ChatMessage(
                id: "approval-\(sessionId)",
                role: .approval,
                content: approval.description,
                timestamp: "2024-01-01",
                approval: approval
            )
        ], profile: profile, sessionIDs: [sessionId])
        defer {
            cache.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [:])
        ))

        XCTAssertEqual(appState.messages.first?.approval?.sessionId, sessionId)
        XCTAssertEqual(appState.messages.first?.approval?.status, .pending)
        XCTAssertEqual(appState.turnState, TurnState.running,
                       "A restored pending approval must keep the composer answerable")
        XCTAssertTrue(
            cache.merge(
                [],
                profile: profile,
                sessionIDs: [sessionId],
                includePendingApprovals: true
            ).contains { $0.approval?.sessionId == sessionId },
            "An unconfirmed approval card should survive a cold launch during its grace period"
        )
        appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [:])
        ))
        XCTAssertEqual(
            appState.messages.first?.approval?.sessionId,
            sessionId,
            "The active AppState should retain the card for a subsequent foreground resume"
        )
    }

    func testApplyChatResumePreservesGatewayPendingDecisionWhenRunningIsNil() {
        let suiteName = "conduit.tests.session-presentation-gateway-pending-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: defaults)
        let sessionId = "test-apply-resume-gateway-pending-\(UUID().uuidString)"
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: { cache.clear() },
            sessionPresentationCache: cache
        )
        let profile = appState.activeProfile
        let clarify = ClarifyActivity(
            requestId: "req-gateway-pending",
            question: "Which color?",
            choices: [ClarifyChoice(label: "Red", value: "red")],
            status: .pending
        )
        let gatewayMessage = ChatMessage(
            id: "clarify-gateway-pending",
            role: .clarify,
            content: clarify.displayQuestion,
            timestamp: "2024-01-01",
            clarify: clarify
        )
        defer {
            cache.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [gatewayMessage],
            snapshot: SessionRuntimeSnapshot(object: [:])
        ))

        let persisted = cache.merge(
            [],
            profile: profile,
            sessionIDs: [sessionId],
            includePendingClarifications: true
        )
        XCTAssertTrue(
            persisted.contains { $0.clarify?.requestId == clarify.requestId },
            "A pending decision sent by the gateway is authoritative and must remain cached"
        )
        XCTAssertEqual(appState.turnState, TurnState.running)
    }

    func testApplyChatResumePersistsGatewayMessagesAndRetainsRestoredCardsWhenRunningIsNil() {
        let suiteName = "conduit.tests.session-presentation-cache-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: defaults)
        let sessionId = "test-apply-resume-cache-\(UUID().uuidString)"
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: { cache.clear() },
            sessionPresentationCache: cache
        )
        let profile = appState.activeProfile
        let approval = ApprovalActivity(
            sessionId: sessionId,
            command: "ls",
            description: "List files",
            choices: ["once", "deny"],
            allowPermanent: false,
            smartDenied: false,
            status: .pending
        )
        cache.save([
            ChatMessage(
                id: "approval-\(sessionId)",
                role: .approval,
                content: approval.description,
                timestamp: "2024-01-01",
                approval: approval
            )
        ], profile: profile, sessionIDs: [sessionId])
        defer {
            cache.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        let gatewayMessage = ChatMessage(
            id: "gateway-user",
            role: .user,
            content: "Fresh transcript row",
            timestamp: "2024-02-02"
        )
        appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [gatewayMessage],
            snapshot: SessionRuntimeSnapshot(object: [:])
        ))

        let persisted = cache.merge(
            [],
            profile: profile,
            sessionIDs: [sessionId],
            includePendingClarifications: true,
            includePendingApprovals: true
        )
        XCTAssertTrue(persisted.contains { $0.approval?.sessionId == sessionId },
                      "An unconfirmed restored card should survive a cold launch during its grace period")
        XCTAssertTrue(
            appState.messages.contains { $0.approval?.sessionId == sessionId },
            "The active AppState should retain the restored card while the gateway is inconclusive"
        )
        let compactGatewayMessage = ChatMessage(
            id: gatewayMessage.id,
            role: gatewayMessage.role,
            content: gatewayMessage.content,
            timestamp: ""
        )
        XCTAssertEqual(
            cache.merge(
                [compactGatewayMessage],
                profile: profile,
                sessionIDs: [sessionId]
            ).first?.timestamp,
            gatewayMessage.timestamp,
            "Fresh gateway transcript presentation must be persisted on resume"
        )
    }

    func testUnconfirmedPendingDecisionExpiresFromPresentationCache() {
        let suiteName = "conduit.tests.session-presentation-expiry-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        var currentDate = Date(timeIntervalSince1970: 1_000_000)
        let cache = SessionPresentationCache(defaults: defaults, now: { currentDate })
        let sessionId = "test-presentation-expiry-\(UUID().uuidString)"
        let profile = "default"
        let clarify = ClarifyActivity(
            requestId: "req-expiring",
            question: "Which color?",
            choices: [ClarifyChoice(label: "Red", value: "red")],
            status: .pending
        )
        let message = ChatMessage(
            id: "clarify-expiring",
            role: .clarify,
            content: clarify.displayQuestion,
            timestamp: "2024-01-01",
            clarify: clarify
        )
        defer {
            cache.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        cache.save(
            [message],
            profile: profile,
            sessionIDs: [sessionId],
            preservePendingDecisionCards: true,
            unconfirmedPendingDecisionKeys: ["clarify:\(clarify.requestId)"]
        )
        XCTAssertTrue(
            cache.merge(
                [],
                profile: profile,
                sessionIDs: [sessionId],
                includePendingClarifications: true
            ).contains { $0.clarify?.requestId == clarify.requestId }
        )

        currentDate.addTimeInterval(SessionPresentationCache.maxUnconfirmedPendingDecisionAge + 1)
        XCTAssertFalse(
            cache.merge(
                [],
                profile: profile,
                sessionIDs: [sessionId],
                includePendingClarifications: true
            ).contains { $0.clarify?.requestId == clarify.requestId },
            "An unconfirmed card must not remain answerable forever without gateway confirmation"
        )
    }

    func testApplyChatResumeExpiresWarmRestoredPendingDecision() {
        let suiteName = "conduit.tests.session-presentation-warm-expiry-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        var currentDate = Date(timeIntervalSince1970: 2_000_000)
        let cache = SessionPresentationCache(defaults: defaults, now: { currentDate })
        let sessionId = "test-warm-presentation-expiry-\(UUID().uuidString)"
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: { cache.clear() },
            sessionPresentationCache: cache
        )
        let profile = appState.activeProfile
        let clarify = ClarifyActivity(
            requestId: "req-warm-expiring",
            question: "Which color?",
            choices: [ClarifyChoice(label: "Red", value: "red")],
            status: .pending
        )
        cache.save([
            ChatMessage(
                id: "clarify-warm-expiring",
                role: .clarify,
                content: clarify.displayQuestion,
                timestamp: "2024-01-01",
                clarify: clarify
            )
        ], profile: profile, sessionIDs: [sessionId])
        defer {
            cache.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [:])
        ))
        XCTAssertTrue(appState.messages.contains { $0.clarify?.requestId == clarify.requestId })

        currentDate.addTimeInterval(SessionPresentationCache.maxUnconfirmedPendingDecisionAge + 1)
        appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [:])
        ))

        XCTAssertFalse(
            appState.messages.contains { $0.clarify?.requestId == clarify.requestId },
            "Warm resumes must stop retaining an unconfirmed card after its grace period"
        )
    }

    func testApplyChatResumeRestoresPendingClarificationWhenRunningIsFalse() {
        let suiteName = "conduit.tests.session-presentation-background-clarify-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: defaults)
        let sessionId = "test-apply-resume-background-clarify-\(UUID().uuidString)"
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: { cache.clear() },
            sessionPresentationCache: cache
        )
        let profile = appState.activeProfile
        let clarify = ClarifyActivity(
            requestId: "req-settled",
            question: "Which color?",
            choices: [ClarifyChoice(label: "Red", value: "red")],
            status: .pending
        )
        cache.save([
            ChatMessage(
                id: "clarify-background",
                role: .clarify,
                content: clarify.displayQuestion,
                timestamp: "2024-01-01",
                clarify: clarify
            )
        ], profile: profile, sessionIDs: [sessionId])
        defer {
            cache.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [ChatMessage(
                id: "assistant-before-clarify",
                role: .assistant,
                content: "I need one more detail before I continue.",
                timestamp: "2024-01-02"
            )],
            snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
        ))

        XCTAssertTrue(appState.messages.contains { $0.content == "I need one more detail before I continue." })
        XCTAssertEqual(
            appState.messages.first(where: { $0.clarify?.requestId == clarify.requestId })?.clarify?.status,
            ClarifyActivity.Status.pending
        )
        XCTAssertEqual(appState.turnState, TurnState.idle)
        XCTAssertTrue(appState.composerIsEnabled)
        XCTAssertEqual(
            appState.composerAction(hasText: true, hasAttachments: false),
            ComposerAction.send
        )
        XCTAssertTrue(
            cache.merge(
                [],
                profile: profile,
                sessionIDs: [sessionId],
                includePendingClarifications: true
            ).contains { $0.clarify?.requestId == clarify.requestId },
            "An unresolved clarification must remain cached after a settled-looking background resume"
        )
    }

    func testApplyChatResumeRestoresPendingApprovalWhenRunningIsFalse() {
        let suiteName = "conduit.tests.session-presentation-background-approval-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: defaults)
        let sessionId = "test-apply-resume-background-approval-\(UUID().uuidString)"
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: { cache.clear() },
            sessionPresentationCache: cache
        )
        let profile = appState.activeProfile
        let approval = ApprovalActivity(
            sessionId: sessionId,
            command: "ls",
            description: "List files",
            choices: ["once", "deny"],
            allowPermanent: false,
            smartDenied: false,
            status: .pending
        )
        cache.save([
            ChatMessage(
                id: "approval-background",
                role: .approval,
                content: approval.description,
                timestamp: "2024-01-01",
                approval: approval
            )
        ], profile: profile, sessionIDs: [sessionId])
        defer {
            cache.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [ChatMessage(
                id: "assistant-before-approval",
                role: .assistant,
                content: "I need permission before I continue.",
                timestamp: "2024-01-02"
            )],
            snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
        ))

        XCTAssertTrue(appState.messages.contains { $0.content == "I need permission before I continue." })
        XCTAssertEqual(
            appState.messages.first(where: { $0.approval?.sessionId == sessionId })?.approval?.status,
            ApprovalActivity.Status.pending
        )
        XCTAssertTrue(AppState.hasPendingDecision(in: appState.messages))
        XCTAssertEqual(appState.turnState, TurnState.idle)
        XCTAssertTrue(appState.composerIsEnabled)
        XCTAssertEqual(
            appState.composerAction(hasText: true, hasAttachments: false),
            ComposerAction.send
        )
        XCTAssertTrue(
            cache.merge(
                [],
                profile: profile,
                sessionIDs: [sessionId],
                includePendingApprovals: true
            ).contains { $0.approval?.sessionId == sessionId },
            "An unresolved approval must remain cached after a settled-looking background resume"
        )
    }

    func testApplyChatResumeSuppressesCachedPendingApprovalWhenGatewayResolvedIt() {
        let suiteName = "conduit.tests.session-presentation-resolved-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: defaults)
        let sessionId = "test-apply-resume-resolved-\(UUID().uuidString)"
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: { cache.clear() },
            sessionPresentationCache: cache
        )
        let profile = appState.activeProfile
        let pendingApproval = ApprovalActivity(
            sessionId: sessionId,
            command: "ls",
            description: "List files",
            choices: ["once", "deny"],
            allowPermanent: false,
            smartDenied: false,
            status: .pending
        )
        cache.save([
            ChatMessage(
                id: "approval-\(sessionId)",
                role: .approval,
                content: pendingApproval.description,
                timestamp: "2024-01-01",
                approval: pendingApproval
            )
        ], profile: profile, sessionIDs: [sessionId])
        let resolvedApproval = ApprovalActivity(
            sessionId: sessionId,
            command: pendingApproval.command,
            description: pendingApproval.description,
            choices: pendingApproval.choices,
            allowPermanent: pendingApproval.allowPermanent,
            smartDenied: pendingApproval.smartDenied,
            status: .approved,
            choice: "once"
        )
        let gatewayMessage = ChatMessage(
            id: "approval-\(sessionId)",
            role: .approval,
            content: resolvedApproval.description,
            timestamp: "2024-01-02",
            approval: resolvedApproval
        )
        defer {
            cache.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [gatewayMessage],
            snapshot: SessionRuntimeSnapshot(object: [:])
        ))

        XCTAssertEqual(
            appState.messages.filter { $0.approval?.sessionId == sessionId }.count,
            1,
            "A resolved gateway approval must replace, not coexist with, the cached pending card"
        )
        XCTAssertEqual(
            appState.messages.first?.approval?.status,
            ApprovalActivity.Status.approved
        )
        XCTAssertFalse(AppState.hasPendingDecision(in: appState.messages))
        XCTAssertFalse(
            cache.merge(
                [],
                profile: profile,
                sessionIDs: [sessionId],
                includePendingApprovals: true
            ).contains { $0.approval?.status == .pending }
        )
    }

    func testApplyChatResumeSuppressesCachedPendingClarificationWhenGatewayResolvedIt() {
        let suiteName = "conduit.tests.session-presentation-resolved-clarify-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: defaults)
        let sessionId = "test-apply-resume-resolved-clarify-\(UUID().uuidString)"
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: { cache.clear() },
            sessionPresentationCache: cache
        )
        let profile = appState.activeProfile
        let pendingClarify = ClarifyActivity(
            requestId: "req-resolved-clarify",
            question: "Which color?",
            choices: [ClarifyChoice(label: "Red", value: "red")],
            status: .pending
        )
        cache.save([
            ChatMessage(
                id: "clarify-\(pendingClarify.requestId)",
                role: .clarify,
                content: pendingClarify.displayQuestion,
                timestamp: "2024-01-01",
                clarify: pendingClarify
            )
        ], profile: profile, sessionIDs: [sessionId])
        let resolvedClarify = ClarifyActivity(
            requestId: pendingClarify.requestId,
            question: pendingClarify.questions[0].question,
            choices: pendingClarify.questions[0].choices,
            status: .answered,
            answer: "red"
        )
        let gatewayMessage = ChatMessage(
            id: "clarify-\(pendingClarify.requestId)",
            role: .clarify,
            content: resolvedClarify.displayQuestion,
            timestamp: "2024-01-02",
            clarify: resolvedClarify
        )
        defer {
            cache.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [gatewayMessage],
            snapshot: SessionRuntimeSnapshot(object: [:])
        ))

        XCTAssertEqual(
            appState.messages.filter { $0.clarify?.requestId == pendingClarify.requestId }.count,
            1
        )
        XCTAssertEqual(appState.messages.first?.clarify?.status, ClarifyActivity.Status.answered)
        XCTAssertFalse(AppState.hasPendingDecision(in: appState.messages))
        XCTAssertFalse(
            cache.merge(
                [],
                profile: profile,
                sessionIDs: [sessionId],
                includePendingClarifications: true
            ).contains { $0.clarify?.requestId == pendingClarify.requestId && $0.clarify?.status == .pending },
            "A resolved gateway clarification must suppress the cached pending card"
        )
    }

    func testApplyChatResumeMakesRestoredSubmittingApprovalRetryable() {
        let suiteName = "conduit.tests.session-presentation-submitting-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: defaults)
        let sessionId = "test-apply-resume-submitting-\(UUID().uuidString)"
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: { cache.clear() },
            sessionPresentationCache: cache
        )
        let profile = appState.activeProfile
        let approval = ApprovalActivity(
            sessionId: sessionId,
            command: "ls",
            description: "List files",
            choices: ["once", "deny"],
            allowPermanent: false,
            smartDenied: false,
            status: .submitting,
            choice: "once"
        )
        cache.save([
            ChatMessage(
                id: "approval-\(sessionId)",
                role: .approval,
                content: approval.description,
                timestamp: "2024-01-01",
                approval: approval
            )
        ], profile: profile, sessionIDs: [sessionId])
        defer {
            cache.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: [:])
        ))

        XCTAssertEqual(
            appState.messages.first?.approval?.status,
            ApprovalActivity.Status.pending,
            "A restored in-flight decision must be retryable after the app resumes"
        )
        XCTAssertNil(appState.messages.first?.approval?.choice)
    }

    func testApplyChatResumePersistsRestoredCardWhenRunningIsTrue() {
        let suiteName = "conduit.tests.session-presentation-running-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: defaults)
        let sessionId = "test-apply-resume-running-\(UUID().uuidString)"
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: { cache.clear() },
            sessionPresentationCache: cache
        )
        let profile = appState.activeProfile
        let clarify = ClarifyActivity(
            requestId: "req-running",
            question: "Which color?",
            choices: [ClarifyChoice(label: "Red", value: "red")],
            status: .pending
        )
        cache.save([
            ChatMessage(
                id: "clarify-running",
                role: .clarify,
                content: clarify.displayQuestion,
                timestamp: "2024-01-01",
                clarify: clarify
            )
        ], profile: profile, sessionIDs: [sessionId])
        defer {
            cache.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: ["running": .bool(true)])
        ))

        XCTAssertTrue(
            cache.merge(
                [],
                profile: profile,
                sessionIDs: [sessionId],
                includePendingClarifications: true
            ).contains { $0.clarify?.requestId == clarify.requestId }
        )
    }

    func testApplyChatResumePreservesGatewayPendingClarificationWhenRunningIsFalse() {
        let suiteName = "conduit.tests.session-presentation-gateway-pending-clarify-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: defaults)
        let sessionId = "test-apply-resume-gateway-pending-clarify-\(UUID().uuidString)"
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: { cache.clear() },
            sessionPresentationCache: cache
        )
        let profile = appState.activeProfile
        let clarify = ClarifyActivity(
            requestId: "req-gateway-pending-false",
            question: "Which color?",
            choices: [ClarifyChoice(label: "Red", value: "red")],
            status: .pending
        )
        let gatewayMessage = ChatMessage(
            id: "clarify-gateway-pending-false",
            role: .clarify,
            content: clarify.displayQuestion,
            timestamp: "2024-01-01",
            clarify: clarify
        )
        defer {
            cache.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [gatewayMessage],
            snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
        ))

        XCTAssertEqual(appState.turnState, TurnState.idle)
        XCTAssertTrue(
            AppState.hasPendingDecision(in: appState.messages),
            "A gateway clarification without a resolved record must remain answerable"
        )
        XCTAssertTrue(appState.composerIsEnabled)
        XCTAssertEqual(
            appState.composerAction(hasText: true, hasAttachments: false),
            ComposerAction.send
        )
        XCTAssertTrue(
            cache.merge(
                [],
                profile: profile,
                sessionIDs: [sessionId],
                includePendingClarifications: true
            ).contains { $0.clarify?.requestId == clarify.requestId },
            "An unresolved gateway clarification must remain cached when running is false"
        )
    }

    func testApplyChatResumePreservesGatewayPendingApprovalWhenRunningIsFalse() {
        let suiteName = "conduit.tests.session-presentation-gateway-settled-approval-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        let cache = SessionPresentationCache(defaults: defaults)
        let sessionId = "test-apply-resume-gateway-settled-approval-\(UUID().uuidString)"
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: { cache.clear() },
            sessionPresentationCache: cache
        )
        let profile = appState.activeProfile
        let approval = ApprovalActivity(
            sessionId: sessionId,
            command: "ls",
            description: "List files",
            choices: ["once", "deny"],
            allowPermanent: false,
            smartDenied: false,
            status: .pending
        )
        let gatewayMessage = ChatMessage(
            id: "approval-gateway-settled",
            role: .approval,
            content: approval.description,
            timestamp: "2024-01-01",
            approval: approval
        )
        defer {
            cache.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [gatewayMessage],
            snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
        ))

        XCTAssertEqual(appState.turnState, TurnState.idle)
        XCTAssertTrue(
            AppState.hasPendingDecision(in: appState.messages),
            "A gateway approval without a resolved record must remain answerable"
        )
        XCTAssertEqual(
            appState.messages.first(where: { $0.approval?.sessionId == sessionId })?.approval?.status,
            ApprovalActivity.Status.pending
        )
        XCTAssertTrue(appState.composerIsEnabled)
        XCTAssertEqual(
            appState.composerAction(hasText: true, hasAttachments: false),
            ComposerAction.send
        )
        XCTAssertTrue(
            cache.merge(
                [],
                profile: profile,
                sessionIDs: [sessionId],
                includePendingApprovals: true
            ).contains { $0.approval?.sessionId == sessionId },
            "An unresolved gateway approval must remain cached when running is false"
        )
    }

    func testBackgroundCacheFlushPreservesGatewayPendingDecisionExpiryMarker() {
        let suiteName = "conduit.tests.session-presentation-gateway-flush-marker-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        var currentDate = Date(timeIntervalSince1970: 3_000_000)
        let cache = SessionPresentationCache(defaults: defaults, now: { currentDate })
        let sessionId = "test-apply-resume-gateway-flush-marker-\(UUID().uuidString)"
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: { cache.clear() },
            sessionPresentationCache: cache
        )
        let profile = appState.activeProfile
        let approval = ApprovalActivity(
            sessionId: sessionId,
            command: "ls",
            description: "List files",
            choices: ["once", "deny"],
            allowPermanent: false,
            smartDenied: false,
            status: .pending
        )
        let gatewayMessage = ChatMessage(
            id: "approval-gateway-flush-marker",
            role: .approval,
            content: approval.description,
            timestamp: "2024-01-01",
            approval: approval
        )
        defer {
            cache.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [gatewayMessage],
            snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
        ))
        let initialMarker = cache.unconfirmedPendingDecisionDate(
            profile: profile,
            sessionIDs: [sessionId]
        )
        XCTAssertEqual(initialMarker, currentDate)

        currentDate.addTimeInterval(60)
        appState.handleScenePhase(.background)

        XCTAssertEqual(
            cache.unconfirmedPendingDecisionDate(profile: profile, sessionIDs: [sessionId]),
            initialMarker,
            "A guard-less cache flush must preserve the original pending-decision expiry marker"
        )
    }

    func testApplyChatResumeExpiresGatewayPendingApprovalAfterGracePeriod() {
        let suiteName = "conduit.tests.session-presentation-gateway-approval-expiry-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        var currentDate = Date(timeIntervalSince1970: 3_000_000)
        let cache = SessionPresentationCache(defaults: defaults, now: { currentDate })
        let sessionId = "test-apply-resume-gateway-approval-expiry-\(UUID().uuidString)"
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            clearSessionPresentationCache: { cache.clear() },
            sessionPresentationCache: cache
        )
        let profile = appState.activeProfile
        let approval = ApprovalActivity(
            sessionId: sessionId,
            command: "ls",
            description: "List files",
            choices: ["once", "deny"],
            allowPermanent: false,
            smartDenied: false,
            status: .pending
        )
        let gatewayMessage = ChatMessage(
            id: "approval-gateway-expiring",
            role: .approval,
            content: approval.description,
            timestamp: "2024-01-01",
            approval: approval
        )
        defer {
            cache.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [gatewayMessage],
            snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
        ))
        XCTAssertTrue(
            cache.merge(
                [],
                profile: profile,
                sessionIDs: [sessionId],
                includePendingApprovals: true
            ).contains { $0.approval?.sessionId == sessionId },
            "A gateway-provided pending approval should be cached during its grace period"
        )

        currentDate.addTimeInterval(SessionPresentationCache.maxUnconfirmedPendingDecisionAge + 1)
        appState.applyChatResume(SessionResumeResult(
            sessionId: sessionId,
            messages: [],
            snapshot: SessionRuntimeSnapshot(object: ["running": .bool(false)])
        ))

        XCTAssertFalse(
            appState.messages.contains { $0.approval?.sessionId == sessionId },
            "An unconfirmed gateway approval must not remain answerable forever"
        )
        XCTAssertFalse(
            cache.merge(
                [],
                profile: profile,
                sessionIDs: [sessionId],
                includePendingApprovals: true
            ).contains { $0.approval?.sessionId == sessionId },
            "An expired gateway approval must be removed from the presentation cache"
        )
    }
}

/// Test-scope clock whose value only moves when a test advances it. Gives
/// multi-write alias scenarios strictly increasing, deterministic
/// CachedSession.updatedAt ordering without wall-clock dependence.
final class DeterministicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1_000_000

    func currentValue() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return Date(timeIntervalSince1970: value)
    }

    func advance() {
        lock.lock()
        defer { lock.unlock() }
        value += 10
    }
}
