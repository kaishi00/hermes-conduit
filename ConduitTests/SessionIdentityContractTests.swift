import XCTest
@testable import Conduit

/// Architectural contract suite for conversation identity: the invariants
/// that must hold ACROSS the shared identity components
/// (`ConversationIdentity`, `ConversationIdentityGate`,
/// `ConversationIdentityIndex`, `NotificationSessionResolver`) and the
/// entry points that consume them.
///
/// Feature-specific behavior keeps its own suites (ChatResumePolicyTests,
/// AppStateForegroundLifecycleTests, CompactResumeTranscriptTests, the
/// AppStateChatResumeTests matrix). This suite pins the identity contract
/// itself:
///
///     There is one consistent definition of conversation identity
///     throughout Conduit.
///
/// - A runtime id is routing state; a durable id is conversation ownership.
/// - Only positive evidence creates or resolves identity mappings.
/// - Explicit navigation may switch; recovery may not.
/// - Old suspended work never gains ownership through the index.
@MainActor
final class SessionIdentityContractTests: XCTestCase {
    private let profile = "default"

    private func makeIndex() -> ConversationIdentityIndex {
        ConversationIdentityIndex()
    }

    private func target(
        runtime: String,
        durable: String? = nil,
        notificationProfile: String? = nil
    ) -> ConduitNotificationTarget {
        ConduitNotificationTarget(
            profile: notificationProfile,
            sessionId: runtime,
            durableSessionID: durable,
            type: nil
        )
    }

    private func summary(
        _ id: String,
        stored: String? = nil,
        alternateIDs: [String] = [],
        profile: String? = "default"
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            storedSessionId: stored,
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

    // MARK: - Notification routing contract

    func testExplicitDualIdentityRoutesDurableWithoutCatalog() {
        let route = NotificationSessionResolver.route(
            target: target(runtime: "runtime-a", durable: "stored-a"),
            catalog: [],
            identityIndex: makeIndex(),
            profile: profile
        )
        XCTAssertEqual(
            route,
            NotificationSessionResolver.Route(
                resumeTargetID: "stored-a",
                durableSessionID: "stored-a",
                basis: .explicitDurable
            )
        )
    }

    func testRuntimeOnlyWithCatalogAliasRoutesToStoredID() {
        let route = NotificationSessionResolver.route(
            target: target(runtime: "runtime-a"),
            catalog: [summary("stored-a", stored: "stored-a", alternateIDs: ["runtime-a"])],
            identityIndex: makeIndex(),
            profile: profile
        )
        XCTAssertEqual(route.basis, .catalogAlias)
        XCTAssertEqual(route.resumeTargetID, "stored-a")
    }

    func testRuntimeOnlyWithConfirmedIndexAliasRoutesWithoutCatalog() {
        let index = makeIndex()
        index.record(
            runtimeID: "runtime-a",
            durableID: "stored-a",
            profile: profile,
            source: .resume
        )
        let route = NotificationSessionResolver.route(
            target: target(runtime: "runtime-a"),
            catalog: [],
            identityIndex: index,
            profile: profile
        )
        XCTAssertEqual(
            route,
            NotificationSessionResolver.Route(
                resumeTargetID: "stored-a",
                durableSessionID: "stored-a",
                basis: .confirmedAlias
            ),
            "A confirmed mapping answers when the catalog temporarily omits the alias"
        )
    }

    func testCatalogAliasOutranksIndexWhenTheyDisagree() {
        // The live registry is fresher: if the catalog now attributes
        // runtime-x to stored-b, routing follows the catalog, not the
        // confirmed history.
        let index = makeIndex()
        index.record(
            runtimeID: "runtime-x",
            durableID: "stored-a",
            profile: profile,
            source: .resume
        )
        let route = NotificationSessionResolver.route(
            target: target(runtime: "runtime-x"),
            catalog: [summary("stored-b", stored: "stored-b", alternateIDs: ["runtime-x"])],
            identityIndex: index,
            profile: profile
        )
        XCTAssertEqual(route.resumeTargetID, "stored-b")
        XCTAssertEqual(route.basis, .catalogAlias)
    }

    func testUnknownRuntimeRoutesToItselfNeverToAnotherConversation() {
        let route = NotificationSessionResolver.route(
            target: target(runtime: "runtime-unknown"),
            catalog: [
                summary("stored-newest", stored: "stored-newest"),
                summary("stored-older", stored: "stored-older")
            ],
            identityIndex: makeIndex(),
            profile: profile
        )
        XCTAssertEqual(
            route,
            NotificationSessionResolver.Route(
                resumeTargetID: "runtime-unknown",
                durableSessionID: nil,
                basis: .legacyRuntime
            ),
            "No fallback may invent a durable conversation for an unknown runtime id"
        )
    }

    func testNotificationRoutingIsProfileScoped() {
        let index = makeIndex()
        index.record(
            runtimeID: "runtime-shared",
            durableID: "stored-in-work",
            profile: "work",
            source: .resume
        )
        // Same profile name, same runtime string, different profile scope:
        // the default-profile lookup must not see work's mapping.
        let defaultRoute = NotificationSessionResolver.route(
            target: target(runtime: "runtime-shared"),
            catalog: [],
            identityIndex: index,
            profile: "default"
        )
        XCTAssertEqual(defaultRoute.basis, .legacyRuntime)
        XCTAssertEqual(defaultRoute.resumeTargetID, "runtime-shared")

        let workRoute = NotificationSessionResolver.route(
            target: target(runtime: "runtime-shared", notificationProfile: "work"),
            catalog: [],
            identityIndex: index,
            profile: "work"
        )
        XCTAssertEqual(workRoute.resumeTargetID, "stored-in-work")
    }

    // MARK: - Payload parsing contract

    func testPayloadWithStoredSessionIDParsesDualIdentity() {
        let service = PushNotificationService.shared
        defer {
            if let pendingTarget = service.pendingTarget {
                service.clearPendingTarget(pendingTarget)
            }
        }
        service.receiveNotificationPayload([
            "body": [
                "conduit": [
                    "session_id": "runtime-a",
                    "stored_session_id": "stored-a",
                    "profile": "default",
                    "type": "response.ready"
                ]
            ]
        ])
        XCTAssertEqual(
            service.pendingTarget,
            ConduitNotificationTarget(
                profile: "default",
                sessionId: "runtime-a",
                durableSessionID: "stored-a",
                type: "response.ready"
            )
        )
    }

    func testPayloadSessionKeySpellingParsesAsDurableIdentity() {
        let service = PushNotificationService.shared
        defer {
            if let pendingTarget = service.pendingTarget {
                service.clearPendingTarget(pendingTarget)
            }
        }
        service.receiveNotificationPayload([
            "conduit": [
                "session_id": "runtime-a",
                "session_key": "stored-a",
                "type": "input.needed"
            ]
        ])
        XCTAssertEqual(service.pendingTarget?.durableSessionID, "stored-a")
    }

    func testLegacyPayloadWithoutDurableFieldParsesRuntimeOnly() {
        let service = PushNotificationService.shared
        defer {
            if let pendingTarget = service.pendingTarget {
                service.clearPendingTarget(pendingTarget)
            }
        }
        service.receiveNotificationPayload([
            "conduit": [
                "session_id": "runtime-a",
                "type": "response.ready"
            ]
        ])
        XCTAssertNil(
            service.pendingTarget?.durableSessionID,
            "Older payloads degrade to alias resolution, never to reinterpreting the runtime id"
        )
    }

    func testApprovalDecisionSessionKeyIsNotPromotedToRoutingIdentity() {
        // decision.session_key answers approval.respond; only a top-level
        // routing field may claim durable routing identity.
        let service = PushNotificationService.shared
        defer {
            if let pendingTarget = service.pendingTarget {
                service.clearPendingTarget(pendingTarget)
            }
        }
        service.receiveNotificationPayload([
            "conduit": [
                "session_id": "runtime-a",
                "type": "approval.needed",
                "decision": [
                    "kind": "approval",
                    "session_key": "approval-answer-key",
                    "description": "Run it?",
                    "choices": ["once", "deny"]
                ]
            ]
        ])
        XCTAssertEqual(service.pendingTarget?.sessionId, "runtime-a")
        XCTAssertNil(service.pendingTarget?.durableSessionID)
        guard case .approval(let sessionKey, _, _) = service.pendingTarget?.decision else {
            return XCTFail("The approval card must still parse")
        }
        XCTAssertEqual(sessionKey, "approval-answer-key")
    }

    func testRoutingStoredSessionIDOutranksSessionKeySpelling() {
        // Both top-level spellings present (a transitional relay): the
        // canonical stored_session_id wins deterministically.
        let service = PushNotificationService.shared
        defer {
            if let pendingTarget = service.pendingTarget {
                service.clearPendingTarget(pendingTarget)
            }
        }
        service.receiveNotificationPayload([
            "conduit": [
                "session_id": "runtime-a",
                "stored_session_id": "stored-canonical",
                "session_key": "stored-legacy",
                "type": "response.ready"
            ]
        ])
        XCTAssertEqual(service.pendingTarget?.durableSessionID, "stored-canonical")
    }

    func testCatalogRowLabeledForAnotherProfileDoesNotRouteThisProfile() {
        let route = NotificationSessionResolver.route(
            target: target(runtime: "runtime-shared"),
            catalog: [
                summary(
                    "stored-foreign",
                    stored: "stored-foreign",
                    alternateIDs: ["runtime-shared"],
                    profile: "work"
                )
            ],
            identityIndex: makeIndex(),
            profile: profile
        )
        XCTAssertEqual(
            route.basis, .legacyRuntime,
            "A foreign-profile catalog row must not route this profile's notification"
        )
        XCTAssertEqual(route.resumeTargetID, "runtime-shared")
    }

    // MARK: - Cross-component agreement

    func testRuntimeRotationRetainsDurableOwnershipAcrossAllComponents() {
        // stored-a, runtime-a → runtime-b (admitted rebind). The gate admits
        // the rotation as a knownAlias/rebind; the index maps BOTH runtimes
        // to stored-a; notification routing for either runtime reaches
        // stored-a.
        let selected = ConversationIdentity(
            profile: profile,
            durableSessionID: "stored-a",
            runtimeSessionID: "runtime-a",
            acceptedSessionIDs: ["stored-a", "runtime-a"]
        )
        let claim = ResumeIdentityClaim(runtimeSessionID: "runtime-b", durableSessionID: nil)
        let catalog = [summary("stored-a", stored: "stored-a", alternateIDs: ["runtime-a"])]

        let admission = ConversationIdentityGate.admit(
            claim: claim,
            selected: selected,
            catalog: catalog
        )
        guard case .success = admission else {
            return XCTFail("A rotation of the selected conversation must be admitted, got \(admission)")
        }

        let index = makeIndex()
        for runtime in ["runtime-a", "runtime-b"] {
            index.record(
                runtimeID: runtime,
                durableID: "stored-a",
                profile: profile,
                source: .resume
            )
        }
        for runtime in ["runtime-a", "runtime-b"] {
            XCTAssertEqual(
                NotificationSessionResolver.route(
                    target: target(runtime: runtime),
                    catalog: [],
                    identityIndex: index,
                    profile: profile
                ).resumeTargetID,
                "stored-a",
                "Runtime rotation must not detach notification routing from the durable conversation"
            )
        }
    }

    func testConflictingReattributionCannotHandOwnershipToSuspendedWork() {
        // runtime-x was confirmed for stored-a; the catalog now says it
        // routes to stored-b. The index moves (authoritative refresh), but a
        // captured ConversationIdentity from the stored-a era is immutable:
        // old suspended work holds its own accepted set and can never adopt
        // stored-b through the index.
        let index = makeIndex()
        index.record(
            runtimeID: "runtime-x",
            durableID: "stored-a",
            profile: profile,
            source: .resume
        )
        let capturedDuringStoredAOwnership = ConversationIdentity(
            profile: profile,
            durableSessionID: "stored-a",
            runtimeSessionID: "runtime-x",
            acceptedSessionIDs: ["stored-a", "runtime-x"]
        )

        index.recordCatalogIdentity(
            [summary("stored-b", stored: "stored-b", alternateIDs: ["runtime-x"])],
            profile: profile
        )

        XCTAssertEqual(
            index.durableID(forRuntime: "runtime-x", profile: profile),
            "stored-b",
            "The live registry decides current routing"
        )
        XCTAssertEqual(
            capturedDuringStoredAOwnership.acceptedSessionIDs,
            ["stored-a", "runtime-x"],
            "The captured identity is capture-time evidence, not live state"
        )
        let staleClaim = ResumeIdentityClaim(runtimeSessionID: "runtime-x", durableSessionID: "stored-b")
        guard case .failure(.durableContradiction) = ConversationIdentityGate.admit(
            claim: staleClaim,
            selected: capturedDuringStoredAOwnership,
            catalog: [summary("stored-b", stored: "stored-b", alternateIDs: ["runtime-x"])]
        ) else {
            return XCTFail("Old stored-a work must not be able to adopt stored-b via the reused runtime")
        }
    }

    func testCatalogOmissionIsNotNegativeIdentityEvidence() {
        let index = makeIndex()
        index.record(
            runtimeID: "runtime-a",
            durableID: "stored-a",
            profile: profile,
            source: .resume
        )
        // A catalog refresh that dropped the conversation entirely, then a
        // labeled row comes back with the same identity: both lookups keep
        // answering.
        index.recordCatalogIdentity([], profile: profile)
        XCTAssertEqual(index.durableID(forRuntime: "runtime-a", profile: profile), "stored-a")
        index.recordCatalogIdentity(
            [summary("stored-a", stored: "stored-a", alternateIDs: ["runtime-a"])],
            profile: profile
        )
        XCTAssertEqual(index.durableID(forRuntime: "runtime-a", profile: profile), "stored-a")
    }

    func testResumeAdmissionAndIndexAgreeOnForeignRuntimeRejection() {
        // runtime-b is positively owned by stored-b's catalog row; the gate
        // rejects it for stored-a's conversation, and — independently — the
        // index never recorded runtime-b→stored-a, so notification routing
        // cannot route runtime-b to stored-a either.
        let selected = ConversationIdentity(
            profile: profile,
            durableSessionID: "stored-a",
            runtimeSessionID: "runtime-a",
            acceptedSessionIDs: ["stored-a", "runtime-a"]
        )
        let catalog = [
            summary("stored-a", stored: "stored-a", alternateIDs: ["runtime-a"]),
            summary("stored-b", stored: "stored-b", alternateIDs: ["runtime-b"])
        ]
        let claim = ResumeIdentityClaim(runtimeSessionID: "runtime-b", durableSessionID: nil)
        guard case .failure(.foreignRuntimeOwnership) = ConversationIdentityGate.admit(
            claim: claim,
            selected: selected,
            catalog: catalog
        ) else {
            return XCTFail("Foreign runtime ownership must be rejected")
        }

        let index = makeIndex()
        index.recordCatalogIdentity(catalog, profile: profile)
        let route = NotificationSessionResolver.route(
            target: target(runtime: "runtime-b"),
            catalog: catalog,
            identityIndex: index,
            profile: profile
        )
        XCTAssertEqual(route.resumeTargetID, "stored-b")
    }

    // MARK: - Composer draft identity contract

    func testComposerDraftEquivalenceSurvivesRotationButNotReattribution() {
        // stored-a with confirmed aliases {stored-a, runtime-old,
        // runtime-new}: the draft follows the conversation through the
        // rotation.
        let rotationIdentity = ChatScrollSessionIdentity(
            profile: profile,
            canonicalSessionID: "stored-a",
            equivalentSessionIDs: ["stored-a", "runtime-old", "runtime-new"],
            isReconciling: false,
            settledRevision: 1
        )
        XCTAssertTrue(ComposerBar.draftKeysAreEquivalent(
            ComposerBar.composerDraftKey(for: "runtime-new", profile: profile, dashboard: nil),
            ComposerBar.composerDraftKey(for: "stored-a", profile: profile, dashboard: nil),
            identity: rotationIdentity
        ))

        // The runtime string is later positively re-attributed to stored-b:
        // the re-attributed identity no longer bridges runtime-x and
        // stored-a, so stored-a's draft must not migrate into stored-b.
        let reattributedIdentity = ChatScrollSessionIdentity(
            profile: profile,
            canonicalSessionID: "stored-b",
            equivalentSessionIDs: ["stored-b", "runtime-x"],
            isReconciling: false,
            settledRevision: 2
        )
        XCTAssertFalse(ComposerBar.draftKeysAreEquivalent(
            ComposerBar.composerDraftKey(for: "runtime-x", profile: profile, dashboard: nil),
            ComposerBar.composerDraftKey(for: "stored-a", profile: profile, dashboard: nil),
            identity: reattributedIdentity
        ))
    }

    func testComposerDraftKeysAreProfileScoped() {
        let identity = ChatScrollSessionIdentity(
            profile: profile,
            canonicalSessionID: "stored-a",
            equivalentSessionIDs: ["stored-a"],
            isReconciling: false,
            settledRevision: 1
        )
        XCTAssertFalse(ComposerBar.draftKeysAreEquivalent(
            ComposerBar.composerDraftKey(for: "stored-a", profile: "default", dashboard: nil),
            ComposerBar.composerDraftKey(for: "stored-a", profile: "work", dashboard: nil),
            identity: identity
        ))
        // And dashboard-scoped: two dashboards share profile names and ids
        // (issue 2702).
        XCTAssertFalse(ComposerBar.draftKeysAreEquivalent(
            ComposerBar.composerDraftKey(for: "stored-a", profile: "default", dashboard: UUID()),
            ComposerBar.composerDraftKey(for: "stored-a", profile: "default", dashboard: UUID()),
            identity: identity
        ))
    }

    // MARK: - Durable-owned presentation writes

    func testPresentationWritesCollapseToDurableKeyOnceEstablished() {
        // With no durable id (runtime-only conversation), the supplied
        // runtime keys pass through: temporary runtime ownership is allowed.
        XCTAssertEqual(
            AppState.durableOwnedPresentationIDs(["runtime-x"], durableSessionID: nil),
            ["runtime-x"]
        )
        // Once the durable id is established, it is the ONLY persisted key —
        // whether or not the alias list already contained it. A write must
        // never recreate a runtime-keyed copy that consolidation retired.
        XCTAssertEqual(
            AppState.durableOwnedPresentationIDs(
                ["runtime-new", "stored-a"],
                durableSessionID: "stored-a"
            ),
            ["stored-a"]
        )
        XCTAssertEqual(
            AppState.durableOwnedPresentationIDs(
                ["runtime-new"],
                durableSessionID: "stored-a"
            ),
            ["stored-a"]
        )
        // Empty/whitespace ids collapse to the durable key alone.
        XCTAssertEqual(
            AppState.durableOwnedPresentationIDs(["", "  "], durableSessionID: "stored-a"),
            ["stored-a"]
        )
    }
}
