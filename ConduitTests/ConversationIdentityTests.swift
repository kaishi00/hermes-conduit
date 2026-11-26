import XCTest
@testable import Conduit

/// Pure-model coverage for the conversation identity abstraction: the
/// durable/runtime separation, the resume identity admission gate, and the
/// preserve-current resolver boundary when no current identity exists.
final class ConversationIdentityTests: XCTestCase {
    // MARK: - resumeTargetID

    func testResumeTargetPrefersDurableIdentityOverRuntimeAlias() {
        let identity = ConversationIdentity(
            profile: "default",
            durableSessionID: "stored-a",
            runtimeSessionID: "runtime-a",
            acceptedSessionIDs: ["stored-a", "runtime-a"]
        )
        XCTAssertEqual(identity.resumeTargetID, "stored-a")
        XCTAssertTrue(identity.contains("runtime-a"))
    }

    func testRuntimeOnlyIdentityResumesThroughItsOnlyKnownID() {
        let identity = ConversationIdentity(
            profile: "default",
            durableSessionID: nil,
            runtimeSessionID: "runtime-new",
            acceptedSessionIDs: ["runtime-new"]
        )
        XCTAssertEqual(identity.resumeTargetID, "runtime-new")
    }

    // MARK: - A compressed chat's segments (issue 3276)

    /// The gateway resumes a compressed chat listed under its newest segment
    /// as its owner, a middle segment: the chat's own segments answer for it,
    /// and another chat still doesn't.
    @MainActor
    func testACompressedChatAdmitsItsOwnerSegmentAndStillRefusesAnotherChat() throws {
        let suite = "ConversationIdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.sessions = MessageNormalizer.normalizeSessions(
            .object([
                "sessions": .array([
                    .object([
                        "id": .string("tip"),
                        "_lineage_root_id": .string("root"),
                        "_lineage_ids": .array([.string("root"), .string("owner"), .string("tip")]),
                        "continuation_kind": .string("compression")
                    ]),
                    .object(["id": .string("other")])
                ])
            ]),
            profile: appState.activeProfile
        )

        let selected = try XCTUnwrap(appState.captureConversationIdentity(for: "tip"))
        XCTAssertEqual(selected.durableSessionID, "tip")
        let catalog = appState.sessions
        XCTAssertEqual(
            ConversationIdentityGate.admit(
                claim: ResumeIdentityClaim(runtimeSessionID: "owner", durableSessionID: "owner"),
                selected: selected,
                catalog: catalog
            ),
            .success(.knownAlias)
        )
        XCTAssertEqual(
            ConversationIdentityGate.admit(
                claim: ResumeIdentityClaim(runtimeSessionID: "other", durableSessionID: "other"),
                selected: selected,
                catalog: catalog
            ),
            .failure(.durableContradiction(selected: "tip", returned: "other"))
        )
        XCTAssertEqual(appState.knownSessionIDs(for: "owner"), ["tip", "root", "owner"], "the owner finds its chat's row")
    }

    // MARK: - Admission: durable identity

    func testGateAcceptsWhenReturnedDurableIdentityMatchesSelected() {
        let selected = identity(durable: "stored-a", runtime: "runtime-a")
        let claim = ResumeIdentityClaim(runtimeSessionID: "runtime-new", durableSessionID: "stored-a")

        XCTAssertEqual(
            ConversationIdentityGate.admit(claim: claim, selected: selected, catalog: []),
            .success(.durableIdentityMatch)
        )
    }

    func testGateRejectsExplicitDurableContradiction() {
        let selected = identity(durable: "stored-a", runtime: "runtime-a")
        let claim = ResumeIdentityClaim(runtimeSessionID: "runtime-b", durableSessionID: "stored-b")

        XCTAssertEqual(
            ConversationIdentityGate.admit(claim: claim, selected: selected, catalog: []),
            .failure(.durableContradiction(selected: "stored-a", returned: "stored-b"))
        )
    }

    func testGateAcceptsReturnedDurableIdentityAlreadyConfirmedAsAlias() {
        // Mixed-generation catalogs can label the durable id differently while
        // still meaning the same row; a positively confirmed alias never
        // counts as a contradiction.
        let selected = identity(
            durable: "stored-a",
            runtime: "runtime-a",
            accepted: ["stored-a", "runtime-a", "legacy-stored-key"]
        )
        let claim = ResumeIdentityClaim(runtimeSessionID: "runtime-a", durableSessionID: "legacy-stored-key")

        XCTAssertEqual(
            ConversationIdentityGate.admit(claim: claim, selected: selected, catalog: []),
            .success(.knownAlias)
        )
    }

    func testGateConfirmsRuntimeEchoWhileResponseEstablishesDurableKey() {
        // A brand-new runtime-only conversation has no established durable
        // id. The runtime id is already accepted (it is the conversation's
        // own), so admission is a known-alias confirmation; recording the
        // response's stored key as the newly established durable identity is
        // the caller's job (the same adoption the create path performs).
        let selected = identity(durable: nil, runtime: "runtime-new")
        let claim = ResumeIdentityClaim(runtimeSessionID: "runtime-new", durableSessionID: "stored-from-server")

        XCTAssertEqual(
            ConversationIdentityGate.admit(claim: claim, selected: selected, catalog: []),
            .success(.knownAlias)
        )
    }

    // MARK: - Admission: runtime identity

    func testGateAcceptsReturnedRuntimeIDAlreadyConfirmedAsAlias() {
        let selected = identity(
            durable: "stored-a",
            runtime: "runtime-old",
            accepted: ["stored-a", "runtime-old", "runtime-new"]
        )
        let claim = ResumeIdentityClaim(runtimeSessionID: "runtime-new", durableSessionID: nil)

        XCTAssertEqual(
            ConversationIdentityGate.admit(claim: claim, selected: selected, catalog: []),
            .success(.knownAlias)
        )
    }

    func testGateRejectsRuntimeIDPositivelyOwnedByAnotherCatalogConversation() {
        let selected = identity(durable: "stored-a", runtime: "runtime-a")
        let catalog = [session("stored-b", alternates: ["runtime-b"])]
        let claim = ResumeIdentityClaim(runtimeSessionID: "runtime-b", durableSessionID: nil)

        XCTAssertEqual(
            ConversationIdentityGate.admit(claim: claim, selected: selected, catalog: catalog),
            .failure(.foreignRuntimeOwnership(returned: "runtime-b", ownerSessionID: "stored-b"))
        )
    }

    func testGateRejectsForeignRuntimeWhenBothRowsAreUnlabeled() {
        // Two absent stored labels are "unknown", never "equal": a runtime-only
        // selection must not adopt a runtime id that positively belongs to a
        // different (unlabeled) catalog row.
        let selected = identity(durable: nil, runtime: "runtime-a")
        let catalog = [session("stored-b", alternates: ["runtime-b"])]
        let claim = ResumeIdentityClaim(runtimeSessionID: "runtime-b", durableSessionID: nil)

        XCTAssertEqual(
            ConversationIdentityGate.admit(claim: claim, selected: selected, catalog: catalog),
            .failure(.foreignRuntimeOwnership(returned: "runtime-b", ownerSessionID: "stored-b"))
        )
    }

    func testGateChecksEveryOwnerRowBeforeDecidingForeignOwnership() {
        // Rows can share a runtime id after rotation. The FIRST matching row
        // must not decide: a foreign row ahead of the selected row in the
        // catalog must not reject a legitimate rebind.
        let selected = identity(
            durable: "stored-a",
            runtime: "runtime-old",
            accepted: ["stored-a", "runtime-old"]
        )
        let catalog = [
            session("stored-b", alternates: ["runtime-new"]),
            session("stored-a", alternates: ["runtime-old", "runtime-new"])
        ]
        let claim = ResumeIdentityClaim(runtimeSessionID: "runtime-new", durableSessionID: nil)

        XCTAssertEqual(
            ConversationIdentityGate.admit(claim: claim, selected: selected, catalog: catalog),
            .success(.knownAlias)
        )
    }

    func testGateAcceptsRuntimeIDOwnedByACatalogRowThatIsTheSelectedConversation() {
        // The refreshed catalog still holds the selected conversation but
        // under an id the capture knew only as an alias: that is confirmation,
        // not foreign ownership.
        let selected = identity(
            durable: "stored-a",
            runtime: "runtime-old",
            accepted: ["stored-a", "runtime-old"]
        )
        let catalog = [session("stored-a", alternates: ["runtime-old", "runtime-new"])]
        let claim = ResumeIdentityClaim(runtimeSessionID: "runtime-new", durableSessionID: nil)

        XCTAssertEqual(
            ConversationIdentityGate.admit(claim: claim, selected: selected, catalog: catalog),
            .success(.knownAlias)
        )
    }

    func testGatePermitsLegacyRequestScopedRuntimeRebind() {
        let selected = identity(durable: "stored-a", runtime: "runtime-old")
        let claim = ResumeIdentityClaim(runtimeSessionID: "runtime-unknown", durableSessionID: nil)

        XCTAssertEqual(
            ConversationIdentityGate.admit(claim: claim, selected: selected, catalog: []),
            .success(.legacyRuntimeRebind)
        )
    }

    // MARK: - Resolver: no current identity (review finding 1)

    func testPreserveCurrentWithoutCurrentIdentityKeepsNewestChatSelection() {
        // "Never navigate away from the current conversation" only applies
        // when one exists. With no current identity the historical selection
        // (newest ordinary chat) is preserved — it must not turn into
        // session.create.
        let selected = ChatResumeSessionResolver.target(
            in: [session("stored-newest"), session("stored-older")],
            behavior: .latestActivity,
            purpose: .preserveCurrent,
            savedSessionID: "stored-older",
            currentSessionID: nil
        )
        XCTAssertEqual(selected?.id, "stored-newest")
    }

    func testPreserveCurrentWithEmptyCatalogAndNoCurrentIdentityReturnsNil() {
        // The caller then falls through to session.create — the preexisting
        // pristine-canvas behavior this refactor must not change.
        XCTAssertNil(ChatResumeSessionResolver.target(
            in: [],
            behavior: .latestActivity,
            purpose: .preserveCurrent,
            savedSessionID: nil,
            currentSessionID: nil
        ))
    }

    func testPreserveCurrentWithEstablishedIdentityMissingFromCatalogReturnsNil() {
        // Catalog absence of an established identity is not navigation
        // authority: the caller resumes the captured identity directly.
        XCTAssertNil(ChatResumeSessionResolver.target(
            in: [session("unrelated")],
            behavior: .latestActivity,
            purpose: .preserveCurrent,
            savedSessionID: nil,
            currentSessionID: "runtime-a"
        ))
    }

    // MARK: - Automatic return pins

    func testAutomaticReturnSelectionPoliciesAreUnchanged() {
        let catalog = [session("stored-b"), session("stored-a", alternates: ["runtime-a"])]

        // Continue Where I Left Off still restores the saved conversation,
        // including through a runtime alias.
        XCTAssertEqual(
            ChatResumeSessionResolver.target(
                in: catalog,
                behavior: .continueWhereLeftOff,
                purpose: .automaticReturn,
                savedSessionID: "runtime-a",
                currentSessionID: nil
            )?.id,
            "stored-a"
        )
        // Jump to Latest Activity still ignores the saved conversation.
        XCTAssertEqual(
            ChatResumeSessionResolver.target(
                in: catalog,
                behavior: .latestActivity,
                purpose: .automaticReturn,
                savedSessionID: "stored-a",
                currentSessionID: "stored-a"
            )?.id,
            "stored-b"
        )
    }

    func testGateRejectsEstablishmentClaimingAnotherRowsStoredKey() {
        // A runtime-only selection cannot contradict a durable claim, but a
        // claim that names a key POSITIVELY labeled as another row's stored
        // id is a renaming attempt, not an establishment.
        let selected = identity(durable: nil, runtime: "runtime-solo")
        let catalog = [session("stored-other", storedSessionID: "stored-other-key")]
        let claim = ResumeIdentityClaim(runtimeSessionID: "runtime-solo", durableSessionID: "stored-other-key")

        XCTAssertEqual(
            ConversationIdentityGate.admit(claim: claim, selected: selected, catalog: catalog),
            .failure(.foreignDurableOwnership(returned: "stored-other-key", ownerSessionID: "stored-other"))
        )
    }

    func testGateAcceptsAliasWhenOwnerRowIsLabeledWithSelectedDurable() {
        // The refreshed catalog kept the conversation under a row whose
        // stored label matches the selection's durable id: confirmation, not
        // foreign ownership.
        let selected = identity(durable: "stored-a", runtime: "runtime-old")
        let catalog = [session("runtime-a", alternates: ["runtime-old", "runtime-new"], storedSessionID: "stored-a")]
        let claim = ResumeIdentityClaim(runtimeSessionID: "runtime-new", durableSessionID: nil)

        XCTAssertEqual(
            ConversationIdentityGate.admit(claim: claim, selected: selected, catalog: catalog),
            .success(.knownAlias)
        )
    }

    // MARK: - Fixtures

    private func identity(
        durable: String?,
        runtime: String?,
        accepted: Set<String>? = nil
    ) -> ConversationIdentity {
        var ids = accepted ?? []
        if let durable { ids.insert(durable) }
        if let runtime { ids.insert(runtime) }
        return ConversationIdentity(
            profile: "default",
            durableSessionID: durable,
            runtimeSessionID: runtime,
            acceptedSessionIDs: ids
        )
    }

    private func session(
        _ id: String,
        alternates: [String] = [],
        storedSessionID: String? = nil
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            storedSessionId: storedSessionID,
            alternateIds: alternates,
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
