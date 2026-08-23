import XCTest
@testable import Conduit

/// Kanban V3A semantics: lifecycle audit, orchestration settings (configured
/// vs resolved), profile routing descriptions, manual dispatcher nudge, and
/// the Specify/Decompose triage actions — with semantic-failure
/// (HTTP-200-but-ok:false) handling and full async ownership discipline.
///
/// No test sleeps: suspensions use a continuation handshake in the mock
/// requester (deterministic, like V2's ContextRaceMockRequester idiom).
@MainActor
final class KanbanV3ATests: XCTestCase {

    // MARK: - Helpers

    private func makeTask(id: String, status: String = "triage", extra: [String: Any] = [:]) -> KanbanTask {
        var object: [String: Any] = ["id": id, "title": "T \(id)", "status": status]
        for (key, value) in extra { object[key] = value }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSONDecoder().decode(KanbanTask.self, from: data)
    }

    private func makeStore(requester: V3AMockRequester) -> KanbanStore {
        let store = KanbanStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.configure(requester: requester, serverIdentity: "https://a.test")
        return store
    }

    private func routes(
        boardSlug: String = "alpha",
        task: KanbanTask? = nil,
        profiles: [[String: Any]] = V3AMockRequester.defaultProfiles,
        orchestration: [String: Any] = V3AMockRequester.defaultOrchestration
    ) -> [String: [String: Any]] {
        [
            "/api/plugins/kanban/boards": [
                "boards": [["slug": boardSlug, "name": "Alpha", "is_current": true]],
                "current": boardSlug,
            ],
            "/api/plugins/kanban/board": V3AMockRequester.staticBoard(task: task),
            "/api/plugins/kanban/profiles": ["profiles": profiles],
            "/api/plugins/kanban/projects": ["projects": []],
            "/api/plugins/kanban/orchestration": orchestration,
            "/api/plugins/kanban/dispatch": [:]
        ]
    }

    // MARK: - 1. Lifecycle audit

    func testLockedDestinationsAreExactlyReviewRunningScheduled() {
        XCTAssertEqual(
            KanbanStatusPresentation.lockedDestinations.sorted(),
            ["review", "running", "scheduled"]
        )
        for status in KanbanStatusPresentation.lockedDestinations {
            XCTAssertFalse(KanbanStatusPresentation.forStatus(status).isManuallySelectable)
            XCTAssertFalse(KanbanStatusPresentation.forStatus(status).isTaskCreatable)
            XCTAssertTrue(KanbanStatusPresentation.forStatus(status).isBackendControlled)
        }
    }

    func testEveryUnlockedStatusStaysManuallySelectable() {
        let unlocked = KanbanStatusPresentation.knownStatuses.filter {
            !KanbanStatusPresentation.isLockedDestination($0)
        }
        for status in unlocked {
            XCTAssertTrue(
                KanbanStatusPresentation.forStatus(status).isManuallySelectable,
                "\(status) must remain a manual destination (V2 policy unchanged)"
            )
        }
    }

    func testUnknownStatusesNeverBecomeActionableDestinations() {
        XCTAssertFalse(KanbanStatusPresentation.canSelectManually("warp_drive"))
        XCTAssertFalse(KanbanStatusPresentation.canCreateTask(in: "warp_drive"))
        XCTAssertTrue(KanbanStatusPresentation.forStatus("warp_drive").isBackendControlled)
    }

    func testTriageActionsGateStrictlyOnTriageStatus() {
        for status in ["todo", "scheduled", "ready", "running", "blocked", "review", "done", "archived", "unknown_x"] {
            XCTAssertFalse(KanbanTriagePolicy.isEligible(status: status), "\(status) must never expose Specify/Decompose")
        }
        XCTAssertTrue(KanbanTriagePolicy.isEligible(status: "triage"))
        XCTAssertTrue(KanbanTriagePolicy.isEligible(task: makeTask(id: "t1", status: "triage")))
        XCTAssertFalse(KanbanTriagePolicy.isEligible(task: nil))
    }

    // MARK: - 2. Orchestration: wire semantics + store behavior

    func testOrchestrationResponseDecodesConfiguredAndResolvedSeparately() throws {
        let json = """
        {"orchestrator_profile": "", "default_assignee": "", "auto_decompose": true,
         "auto_promote_children": true, "resolved_orchestrator_profile": "default",
         "resolved_default_assignee": "coder", "active_profile": "default"}
        """
        let settings = try JSONDecoder().decode(KanbanOrchestrationSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.orchestratorProfile, "", "configured value is the raw wire value")
        XCTAssertEqual(settings.defaultAssignee, "")
        XCTAssertEqual(settings.resolvedOrchestratorProfile, "default")
        XCTAssertEqual(settings.resolvedDefaultAssignee, "coder")
        XCTAssertEqual(settings.autoDecompose, true)
        XCTAssertEqual(settings.autoPromoteChildren, true)
    }

    func testOrchestrationPatchEncodesDefaultAsEmptyStringNotSentinel() throws {
        let patch = KanbanOrchestrationPatch(orchestratorProfile: "", autoDecompose: true)
        let data = try JSONEncoder().encode(patch)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["orchestrator_profile"] as? String, "", "Default is the empty string on the wire")
        XCTAssertEqual(object["auto_decompose"] as? Bool, true)
        XCTAssertNil(object["default_assignee"], "untouched fields are omitted entirely")
        XCTAssertNil(object["auto_promote_children"])
    }

    func testOrchestrationPatchPinsExplicitProfilesAndBools() throws {
        let patch = KanbanOrchestrationPatch(orchestratorProfile: "archimedes", defaultAssignee: "lancelot", autoPromoteChildren: false)
        let data = try JSONEncoder().encode(patch)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["orchestrator_profile"] as? String, "archimedes")
        XCTAssertEqual(object["default_assignee"] as? String, "lancelot")
        XCTAssertEqual(object["auto_promote_children"] as? Bool, false)
    }

    func testOrchestrationDisplayDistinguishesConfiguredFromResolved() {
        XCTAssertEqual(KanbanOrchestrationDisplay.defaultOptionLabel(configured: "", resolved: "coder"), "Default (coder)")
        XCTAssertEqual(KanbanOrchestrationDisplay.defaultOptionLabel(configured: "", resolved: "  coder  "), "Default (coder)", "resolved trimmed for display")
        XCTAssertEqual(KanbanOrchestrationDisplay.defaultOptionLabel(configured: "", resolved: ""), "Default")
        XCTAssertEqual(KanbanOrchestrationDisplay.resolveFootnote(configured: "", resolved: "coder"), "Default resolves to coder.")
        XCTAssertEqual(KanbanOrchestrationDisplay.resolveFootnote(configured: "coder", resolved: "coder"), "Pinned to coder.", "explicit pin is labeled as pinned, not defaulted")
    }

    func testUpdateOrchestrationPostsOnlyChangedFieldsAndAdoptsEcho() async throws {
        let requester = V3AMockRequester(responsesByPath: routes())
        let store = makeStore(requester: requester)
        await store.reload()
        XCTAssertEqual(store.orchestration?.defaultAssignee, "")

        let patch = KanbanOrchestrationPatch(defaultAssignee: "coder")
        let updated = try await store.updateOrchestration(patch)

        XCTAssertEqual(updated?.defaultAssignee, "coder", "backend echo adopted")
        // Authoritative refresh after the mutation (superseding reload) sees
        // the updated server state via the merged orchestration mock.
        XCTAssertGreaterThanOrEqual(requester.boardFetches, 2)
        XCTAssertEqual(store.orchestration?.defaultAssignee, "coder")
        XCTAssertNil(store.mutationErrorMessage)

        let putCalls = requester.calls.filter { $0.method == "PUT" && $0.path.hasSuffix("/orchestration") }
        XCTAssertEqual(putCalls.count, 1)
        XCTAssertEqual(putCalls.first?.body?["default_assignee"] as? String, "coder")
        XCTAssertNil(putCalls.first?.body?["orchestrator_profile"], "unchanged field not sent")
    }

    func testUpdateOrchestrationStaleGenerationIsFullyInert() async throws {
        let requesterA = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha"))
        let store = makeStore(requester: requesterA)
        await store.reload()

        // Suspend the PUT inside the mock; the call IS recorded, then the
        // request parks until the test resumes it.
        requesterA.suspend(method: "PUT", basePath: "/api/plugins/kanban/orchestration")
        let task = Task { try? await store.updateOrchestration(KanbanOrchestrationPatch(autoDecompose: false)) }
        await requesterA.waitForSuspension()
        XCTAssertEqual(requesterA.calls.filter { $0.method == "PUT" }.count, 1)
        XCTAssertTrue(store.isMutating)

        // Ownership loss: the server/board context is replaced mid-flight.
        let requesterB = V3AMockRequester(responsesByPath: routes(boardSlug: "beta"))
        store.configure(requester: requesterB, serverIdentity: "https://b.test")
        XCTAssertFalse(store.isMutating, "configure() strips mutation ownership immediately")

        requesterA.resumeSuspended()
        _ = await task.value

        XCTAssertFalse(store.isMutating)
        XCTAssertNil(store.mutationErrorMessage, "stale completion must not surface errors")
        XCTAssertNil(store.orchestration, "stale echo must not repopulate the new server context")
        XCTAssertNil(store.board)
        XCTAssertEqual(requesterB.calls.count, 0, "no request may fire against the new context")
    }

    func testUpdateOrchestrationNetworkFailureSurfacesAndClearsOwnership() async {
        let requester = V3AMockRequester(responsesByPath: routes())
        requester.errorsByPath["/api/plugins/kanban/orchestration"] = URLError(.cannotConnectToHost)
        let store = makeStore(requester: requester)
        await store.reload()

        do {
            _ = try await store.updateOrchestration(KanbanOrchestrationPatch(autoDecompose: false))
            XCTFail("expected a network failure")
        } catch {
            XCTAssertFalse(store.isMutating, "ownership released after failure")
            XCTAssertNotNil(store.mutationErrorMessage)
        }
    }

    // MARK: - 3. Profile routing descriptions

    func testProfileDescriptionManualSaveWireAndNoNudge() async throws {
        let requester = V3AMockRequester(responsesByPath: routes())
        let store = makeStore(requester: requester)
        await store.reload()

        try await store.updateProfileDescription(profile: "coder", description: "Swift/iOS implementation and debugging")

        let patchCalls = requester.calls.filter { $0.method == "PATCH" && $0.path.hasSuffix("/profiles/coder") }
        XCTAssertEqual(patchCalls.count, 1)
        XCTAssertEqual(patchCalls.first?.body?["description"] as? String, "Swift/iOS implementation and debugging")
        XCTAssertFalse(requester.calls.contains { $0.path.contains("/dispatch") }, "upstream saves descriptions without a dispatcher nudge")
    }

    func testAutoDescribePostsOverwriteTrueAndAdoptsGeneratedText() async throws {
        let requester = V3AMockRequester(responsesByPath: routes())
        requester.responsesByPath["/api/plugins/kanban/profiles/coder/describe-auto"] = [
            "ok": true, "profile": "coder", "reason": "", "description": "Swift/iOS implementation and debugging.",
        ]
        // The authoritative profiles refetch after the mutation returns the
        // server-persisted generated text (description_auto=true).
        let generated = [
            "name": "coder", "is_default": false, "model": "", "provider": "",
            "description": "Swift/iOS implementation and debugging.", "description_auto": true, "skill_count": 3,
        ] as [String: Any]
        requester.profilesProvider = { fetch in
            ["profiles": fetch >= 2 ? [generated, V3AMockRequester.defaultProfiles[1]] : V3AMockRequester.defaultProfiles]
        }
        let store = makeStore(requester: requester)
        await store.reload()

        let outcome = try await store.autoDescribeProfile(profile: "coder", overwrite: true)

        XCTAssertTrue(outcome.ok)
        let postCalls = requester.calls.filter { $0.method == "POST" && $0.path.hasSuffix("/profiles/coder/describe-auto") }
        XCTAssertEqual(postCalls.count, 1)
        XCTAssertEqual(postCalls.first?.body?["overwrite"] as? Bool, true)
        let profile = store.profiles.first { $0.name == "coder" }
        XCTAssertEqual(profile?.description, "Swift/iOS implementation and debugging.", "generated text adopted")
        XCTAssertEqual(profile?.descriptionAuto, true)
        XCTAssertFalse(requester.calls.contains { $0.path.contains("/dispatch") })
    }

    func testAutoDescribeSemanticRefusalReturnsReasonWithoutThrowing() async throws {
        let requester = V3AMockRequester(responsesByPath: routes())
        requester.responsesByPath["/api/plugins/kanban/profiles/coder/describe-auto"] = [
            "ok": false, "profile": "coder", "reason": "no auxiliary client configured", "description": nil as Any?,
        ]
        let store = makeStore(requester: requester)
        await store.reload()
        let before = store.profiles.first { $0.name == "coder" }?.description

        let outcome = try await store.autoDescribeProfile(profile: "coder", overwrite: true)

        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.reason, "no auxiliary client configured", "backend reason is the product semantics")
        XCTAssertEqual(store.profiles.first { $0.name == "coder" }?.description, before)
        XCTAssertNil(store.mutationErrorMessage, "semantic refusal is an outcome, not a mutation failure")
    }

    func testGenerateNeverOverwritesDirtyDraftWithoutExplicitDiscard() {
        XCTAssertEqual(
            KanbanProfileDescriptionPolicy.resolveGenerate(draft: "my draft", baseline: "server text"),
            .requiresDiscard
        )
        XCTAssertEqual(
            KanbanProfileDescriptionPolicy.resolveGenerate(draft: "server text", baseline: "server text"),
            .allowed
        )
        XCTAssertEqual(
            KanbanProfileDescriptionPolicy.discard(draft: "my draft", baseline: "server text"),
            "server text",
            "discard drops the draft back to the baseline"
        )
    }

    func testStaleProfileCompletionIsIdentityInert() async throws {
        let requesterA = V3AMockRequester(responsesByPath: routes())
        let store = makeStore(requester: requesterA)
        await store.reload()

        requesterA.suspend(method: "POST", basePath: "/api/plugins/kanban/profiles/coder/describe-auto")
        let task = Task { try? await store.autoDescribeProfile(profile: "coder", overwrite: true) }
        await requesterA.waitForSuspension()

        let generation = store.currentConfigurationGeneration
        let requesterB = V3AMockRequester(responsesByPath: routes(boardSlug: "beta"))
        store.configure(requester: requesterB, serverIdentity: "https://b.test")
        requesterA.resumeSuspended()
        _ = await task.value

        XCTAssertNil(store.mutationErrorMessage)
        XCTAssertTrue(store.profiles.isEmpty, "stale profile completion must not repopulate the new context")
        XCTAssertEqual(requesterB.calls.count, 0)
        XCTAssertFalse(
            store.isCurrentConfiguration(generation),
            "the view-local generation guard sees the ownership loss immediately"
        )
    }

    func testStoreGenerationTokenFlipsOnConfigure() async {
        let requesterA = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha"))
        let store = makeStore(requester: requesterA)
        await store.reload()
        let generationA = store.currentConfigurationGeneration

        XCTAssertTrue(store.isCurrentConfiguration(generationA), "a fresh token stays current")
        XCTAssertEqual(generationA, store.currentConfigurationGeneration, "token stable across loads")

        let requesterB = V3AMockRequester(responsesByPath: routes(boardSlug: "beta"))
        store.configure(requester: requesterB, serverIdentity: "https://b.test")

        XCTAssertFalse(store.isCurrentConfiguration(generationA), "configure() invalidates captured tokens")
        XCTAssertTrue(store.isCurrentConfiguration(store.currentConfigurationGeneration))
    }

    // MARK: - 4. Manual dispatcher nudge

    func testManualNudgePostsToCapturedBoardOnly() async throws {
        let requester = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha"))
        let store = makeStore(requester: requester)
        await store.reload()

        try await store.nudgeDispatcher()

        let dispatchCalls = requester.calls.filter { $0.method == "POST" && $0.path.contains("/dispatch") }
        XCTAssertEqual(dispatchCalls.count, 1)
        XCTAssertTrue(dispatchCalls.first?.path.contains("board=alpha") ?? false, "nudge carries the captured board slug")
        XCTAssertEqual(dispatchCalls.first?.body?.isEmpty ?? false, true, "empty body matches upstream POST /dispatch")
        XCTAssertNil(store.mutationErrorMessage)
        XCTAssertGreaterThanOrEqual(requester.boardFetches, 2, "success reconciles with an authoritative board refresh")
    }

    func testNudgeRefusedWhileSnapshotIsNotActionable() async {
        let requester = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha"))
        // Beta exists on the server; selecting it starts a superseding load
        // whose board fetch FAILS, leaving the stale alpha snapshot visible
        // but non-actionable.
        requester.responsesByPath["/api/plugins/kanban/boards"] = [
            "boards": [
                ["slug": "alpha", "name": "Alpha", "is_current": true],
                ["slug": "beta", "name": "Beta", "is_current": false],
            ],
            "current": "alpha",
        ]
        requester.boardProvider = { fetch in
            if fetch >= 2 { throw URLError(.cannotConnectToHost) }
            return V3AMockRequester.staticBoard(task: nil)
        }
        let store = makeStore(requester: requester)
        await store.reload()
        XCTAssertTrue(store.isSelectedSnapshotLoaded)

        await store.selectBoard(slug: "beta")
        XCTAssertFalse(store.isSelectedSnapshotLoaded)

        do {
            try await store.nudgeDispatcher()
            XCTFail("expected the navigation guard to refuse the nudge")
        } catch KanbanServiceError.boardNavigationInProgress {
            // expected: fail-closed
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(requester.calls.contains { $0.path.contains("/dispatch") }, "no nudge may fire for a stale snapshot")
    }

    func testNudgeAfterOwnershipLossNeverFiresAgainstNewContext() async {
        let requesterA = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha"))
        let store = makeStore(requester: requesterA)
        await store.reload()

        requesterA.suspend(method: "POST", basePath: "/api/plugins/kanban/dispatch")
        let task = Task { try? await store.nudgeDispatcher() }
        await requesterA.waitForSuspension()
        XCTAssertEqual(requesterA.calls.filter { $0.path.contains("/dispatch") }.count, 1)

        let requesterB = V3AMockRequester(responsesByPath: routes(boardSlug: "beta"))
        store.configure(requester: requesterB, serverIdentity: "https://b.test")
        requesterA.resumeSuspended()
        _ = await task.value

        XCTAssertEqual(requesterB.calls.count, 0)
        XCTAssertFalse(store.isMutating)
        XCTAssertNil(store.mutationErrorMessage)
    }

    // MARK: - 5. Specify

    func testSpecifySuccessReloadsAuthoritativeTaskState() async throws {
        let t1 = makeTask(id: "t1", status: "triage")
        let afterSpecify = makeTask(id: "t1", status: "todo")
        let requester = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha", task: t1))
        // After the mutation the authoritative board moves t1 to todo.
        requester.boardProvider = { fetch in
            fetch >= 2 ? V3AMockRequester.staticBoard(task: afterSpecify) : V3AMockRequester.staticBoard(task: t1)
        }
        requester.responsesByPath["/api/plugins/kanban/tasks/t1/specify"] = [
            "ok": true, "task_id": "t1", "reason": "specified", "new_title": "Tightened title",
        ]
        let store = makeStore(requester: requester)
        await store.reload()
        XCTAssertEqual(store.board?.columns.first { $0.name == "triage" }?.tasks.first?.id, "t1")

        let outcome = try await store.specifyTask(id: "t1")

        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(outcome.newTitle, "Tightened title")
        XCTAssertEqual(requester.boardFetches, 2, "post-mutation superseding reload")
        XCTAssertNil(store.board?.columns.first { $0.name == "triage" }?.tasks.first, "t1 left triage")
        XCTAssertEqual(store.board?.columns.first { $0.name == "todo" }?.tasks.first?.id, "t1", "reconciled from authoritative REST state")
        XCTAssertNil(store.mutationErrorMessage)
        XCTAssertTrue(requester.calls.contains {
            $0.method == "POST" && $0.path.contains("/tasks/t1/specify") && $0.path.contains("board=alpha")
        })
    }

    func testSpecifySemanticFailureSurfacesBackendReasonAndLeavesTaskIntact() async {
        let t1 = makeTask(id: "t1", status: "triage")
        let requester = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha", task: t1))
        requester.responsesByPath["/api/plugins/kanban/tasks/t1/specify"] = [
            "ok": false,
            "task_id": "t1",
            "reason": "task is not in triage (status='todo')",
            "new_title": nil as Any?,
        ]
        let store = makeStore(requester: requester)
        await store.reload()

        do {
            _ = try await store.specifyTask(id: "t1")
            XCTFail("semantic failure must throw")
        } catch let error as KanbanServiceError {
            XCTAssertEqual(error, .actionDeclined(reason: "task is not in triage (status='todo')"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(store.mutationErrorMessage?.contains("task is not in triage") == true, "backend reason shown verbatim")
        XCTAssertEqual(store.board?.columns.first { $0.name == "triage" }?.tasks.first?.id, "t1", "task left intact on semantic refusal")
        XCTAssertEqual(store.board?.columns.first { $0.name == "todo" }?.tasks.isEmpty, true)
    }

    func testSpecifyNetworkFailureIsDistinctFromSemanticFailure() async {
        let t1 = makeTask(id: "t1", status: "triage")
        let requester = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha", task: t1))
        requester.errorsByPath["/api/plugins/kanban/tasks/t1/specify"] = URLError(.timedOut)
        let store = makeStore(requester: requester)
        await store.reload()

        do {
            _ = try await store.specifyTask(id: "t1")
            XCTFail("expected failure")
        } catch is KanbanServiceError {
            XCTFail("a network failure is not a semantic actionDeclined")
        } catch {
            XCTAssertFalse(store.isMutating)
            XCTAssertNotNil(store.mutationErrorMessage)
        }
    }

    func testSpecifyStaleCompletionAfterServerSwitchIsInert() async {
        let t1 = makeTask(id: "t1", status: "triage")
        let requesterA = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha", task: t1))
        requesterA.responsesByPath["/api/plugins/kanban/tasks/t1/specify"] = [
            "ok": true, "task_id": "t1", "reason": "specified", "new_title": nil as Any?,
        ]
        let store = makeStore(requester: requesterA)
        await store.reload()

        requesterA.suspend(method: "POST", basePath: "/api/plugins/kanban/tasks/t1/specify")
        let task = Task { try? await store.specifyTask(id: "t1") }
        await requesterA.waitForSuspension()

        let requesterB = V3AMockRequester(responsesByPath: routes(boardSlug: "beta"))
        store.configure(requester: requesterB, serverIdentity: "https://b.test")
        requesterA.resumeSuspended()
        _ = await task.value

        XCTAssertEqual(requesterB.calls.count, 0, "mutation started for A must never touch B")
        XCTAssertNil(store.mutationErrorMessage)
        XCTAssertNil(store.board, "no stale reload may repopulate B's UI")
        XCTAssertFalse(store.isMutating)
    }

    // MARK: - 7. V3A final pass: mutation identity frozen before scheduling

    func testPendingTriageActionCaptureFreezesIdentityAndStamp() {
        let task = makeTask(id: "t1", status: "triage")
        let stamp = KanbanBoardContextStamp(boardSlug: "alpha", configurationGeneration: 3)
        let pending = PendingTriageAction.capture(task: task, isSnapshotActionable: true, stamp: stamp)
        XCTAssertEqual(pending?.taskID, "t1")
        XCTAssertEqual(pending?.context, stamp)
        // A capture is refused entirely when the identity is not owned.
        XCTAssertNil(PendingTriageAction.capture(task: task, isSnapshotActionable: false, stamp: stamp))
        XCTAssertNil(PendingTriageAction.capture(task: task, isSnapshotActionable: true, stamp: nil))
        XCTAssertNil(PendingTriageAction.capture(task: nil, isSnapshotActionable: true, stamp: stamp))
    }

    func testSpecifyStaleCapturedContextFailsClosedWithoutAnyRequest() async {
        let t1 = makeTask(id: "t1", status: "triage")
        let requesterA = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha", task: t1))
        let store = makeStore(requester: requesterA)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected a loaded context") }

        // Server B replaces A between the tap (capture) and Task execution.
        let requesterB = V3AMockRequester(responsesByPath: routes(boardSlug: "beta"))
        store.configure(requester: requesterB, serverIdentity: "https://b.test")

        do {
            _ = try await store.specifyTask(id: "t1", expectedContext: stampA)
            XCTFail("a stale captured stamp must fail closed")
        } catch KanbanServiceError.boardNavigationInProgress {
            // fail-closed, expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(requesterB.calls.count, 0, "zero request may reach server B")
        XCTAssertFalse(requesterA.calls.contains { $0.path.contains("/tasks/t1/specify") }, "no specify may fire after capture invalidation")
    }

    func testDecomposeStagedConfirmationFailsClosedAfterNavigation() async {
        let t1 = makeTask(id: "t1", status: "triage")
        let requester = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha", task: t1))
        requester.responsesByPath["/api/plugins/kanban/boards"] = [
            "boards": [
                ["slug": "alpha", "name": "Alpha", "is_current": true],
                ["slug": "beta", "name": "Beta", "is_current": false],
            ],
            "current": "alpha",
        ]
        // Beta's board fetch fails: the stale alpha snapshot stays visible but
        // non-actionable while beta loads.
        requester.boardProvider = { fetch in
            if fetch >= 2 { throw URLError(.cannotConnectToHost) }
            return V3AMockRequester.staticBoard(task: t1)
        }
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected a loaded context") }

        // Stage for A, then navigate before confirming.
        let staged = PendingTriageAction(taskID: t1.id, context: stampA)
        await store.selectBoard(slug: "beta")
        XCTAssertFalse(store.isSelectedSnapshotLoaded)

        do {
            _ = try await store.decomposeTask(id: staged.taskID, expectedContext: staged.context)
            XCTFail("a stale staged confirmation must fail closed")
        } catch KanbanServiceError.boardNavigationInProgress {
            // fail-closed, expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(requester.calls.contains { $0.path.contains("/decompose") }, "zero decompose may fire for a stale confirmation")
    }

    func testOrchestrationSaveProceedsAfterSameServerBoardSwitch() async throws {
        // F-2: orchestration is server-global on the wire; a board switch on
        // the SAME server (generation unchanged) must not abort a valid
        // settings save - only a server reconfigure invalidates the stamp.
        let requester = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha"))
        requester.responsesByPath["/api/plugins/kanban/boards"] = [
            "boards": [
                ["slug": "alpha", "name": "Alpha", "is_current": true],
                ["slug": "beta", "name": "Beta", "is_current": false],
            ],
            "current": "alpha",
        ]
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected a loaded context") }

        // Same-server navigation completes successfully before the mutation.
        await store.selectBoard(slug: "beta")
        XCTAssertTrue(store.isSelectedSnapshotLoaded)
        XCTAssertEqual(store.loadedBoardSlug, "beta")

        let updated = try await store.updateOrchestration(
            KanbanOrchestrationPatch(autoDecompose: false),
            expectedContext: stampA
        )
        XCTAssertEqual(updated?.autoDecompose, false, "same-server save proceeds")
        XCTAssertNil(store.mutationErrorMessage)
        let putCalls = requester.calls.filter { $0.method == "PUT" && $0.path.hasSuffix("/orchestration") }
        XCTAssertEqual(putCalls.count, 1)
        XCTAssertFalse(putCalls.first?.path.contains("board=") ?? false, "server-global PUT carries no board query")
    }

    func testProfileSaveAndGenerateProceedAfterSameServerBoardSwitch() async throws {
        // G-1 parity: profile endpoints are server-global too - a completed
        // same-server board switch must not abort a valid save or generation.
        let requester = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha"))
        requester.responsesByPath["/api/plugins/kanban/boards"] = [
            "boards": [
                ["slug": "alpha", "name": "Alpha", "is_current": true],
                ["slug": "beta", "name": "Beta", "is_current": false],
            ],
            "current": "alpha",
        ]
        requester.responsesByPath["/api/plugins/kanban/profiles/coder/describe-auto"] = [
            "ok": true, "profile": "coder", "reason": "", "description": "Generated text",
        ]
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected a loaded context") }

        await store.selectBoard(slug: "beta")
        XCTAssertTrue(store.isSelectedSnapshotLoaded)

        try await store.updateProfileDescription(
            profile: "coder",
            description: "New description",
            expectedContext: stampA
        )
        XCTAssertNil(store.mutationErrorMessage)
        XCTAssertTrue(requester.calls.contains { $0.method == "PATCH" && $0.path.contains("/profiles/coder") })

        let outcome = try await store.autoDescribeProfile(profile: "coder", overwrite: true, expectedContext: stampA)
        XCTAssertTrue(outcome.ok)
        XCTAssertFalse(requester.calls.contains { $0.path.contains("board=") && $0.path.contains("profiles") }, "no board query on server-global profile calls")
    }

    func testServerGlobalSaveProceedsDuringInFlightBoardTransition() async throws {
        // Merge pass: a server-global orchestration save must stay valid while
        // a same-server alpha -> beta transition is IN FLIGHT (selected = beta,
        // loaded = alpha, snapshot not actionable).
        let requester = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha"))
        requester.responsesByPath["/api/plugins/kanban/boards"] = [
            "boards": [
                ["slug": "alpha", "name": "Alpha", "is_current": true],
                ["slug": "beta", "name": "Beta", "is_current": false],
            ],
            "current": "alpha",
        ]
        requester.boardProvider = { _ in V3AMockRequester.staticBoard(task: nil) }
        requester.blockedBoardFetches = [2] // hold the beta load mid-flight
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected a loaded context") }

        let navigation = Task { await store.selectBoard(slug: "beta") }
        await requester.waitUntilBoardFetchParked()
        XCTAssertFalse(store.isSelectedSnapshotLoaded, "navigation is genuinely in flight")

        let updated = try await store.updateOrchestration(
            KanbanOrchestrationPatch(autoDecompose: false),
            expectedContext: stampA
        )
        XCTAssertEqual(updated?.autoDecompose, false, "same-server in-flight transition does not reject the save")
        XCTAssertEqual(
            requester.calls.filter { $0.method == "PUT" && $0.path.hasSuffix("/orchestration") }.count,
            1,
            "PUT occurs exactly once"
        )
        XCTAssertNil(store.mutationErrorMessage, "no boardNavigationInProgress")

        requester.releaseBoardFetches()
        await navigation.value
        XCTAssertEqual(store.loadedBoardSlug, "beta", "reconciliation converges onto the currently selected board")
    }

    func testServerGlobalProfileSaveProceedsDuringInFlightBoardTransition() async throws {
        let requester = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha"))
        requester.responsesByPath["/api/plugins/kanban/boards"] = [
            "boards": [
                ["slug": "alpha", "name": "Alpha", "is_current": true],
                ["slug": "beta", "name": "Beta", "is_current": false],
            ],
            "current": "alpha",
        ]
        requester.boardProvider = { _ in V3AMockRequester.staticBoard(task: nil) }
        requester.blockedBoardFetches = [2]
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected a loaded context") }

        let navigation = Task { await store.selectBoard(slug: "beta") }
        await requester.waitUntilBoardFetchParked()

        try await store.updateProfileDescription(profile: "coder", description: "New text", expectedContext: stampA)
        XCTAssertNil(store.mutationErrorMessage)
        XCTAssertEqual(
            requester.calls.filter { $0.method == "PATCH" && $0.path.contains("/profiles/coder") }.count,
            1,
            "PATCH still occurs exactly once"
        )

        requester.releaseBoardFetches()
        await navigation.value
        XCTAssertEqual(store.loadedBoardSlug, "beta")
    }

    func testServerGlobalGenerateProceedsDuringInFlightBoardTransition() async throws {
        let requester = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha"))
        requester.responsesByPath["/api/plugins/kanban/boards"] = [
            "boards": [
                ["slug": "alpha", "name": "Alpha", "is_current": true],
                ["slug": "beta", "name": "Beta", "is_current": false],
            ],
            "current": "alpha",
        ]
        requester.boardProvider = { _ in V3AMockRequester.staticBoard(task: nil) }
        requester.blockedBoardFetches = [2]
        requester.responsesByPath["/api/plugins/kanban/profiles/coder/describe-auto"] = [
            "ok": true, "profile": "coder", "reason": "", "description": "Generated",
        ]
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected a loaded context") }

        let navigation = Task { await store.selectBoard(slug: "beta") }
        await requester.waitUntilBoardFetchParked()

        let outcome = try await store.autoDescribeProfile(profile: "coder", overwrite: true, expectedContext: stampA)
        XCTAssertTrue(outcome.ok)
        XCTAssertNil(store.mutationErrorMessage)
        XCTAssertEqual(
            requester.calls.filter { $0.method == "POST" && $0.path.contains("/profiles/coder/describe-auto") }.count,
            1,
            "describe-auto still occurs exactly once"
        )

        requester.releaseBoardFetches()
        await navigation.value
        XCTAssertEqual(store.loadedBoardSlug, "beta")
    }

    func testBoardScopedSpecifyFailsClosedDuringInFlightBoardTransition() async {
        // S-1 negative branch: BOARD-scoped mutations must keep the
        // fail-closed invariant during a PARKED (not failed) transition -
        // selected beta, loaded alpha, snapshot not actionable.
        let t1 = makeTask(id: "t1", status: "triage")
        let requester = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha", task: t1))
        requester.responsesByPath["/api/plugins/kanban/boards"] = [
            "boards": [
                ["slug": "alpha", "name": "Alpha", "is_current": true],
                ["slug": "beta", "name": "Beta", "is_current": false],
            ],
            "current": "alpha",
        ]
        requester.boardProvider = { fetch in
            V3AMockRequester.staticBoard(task: fetch >= 2 ? nil : t1)
        }
        requester.blockedBoardFetches = [2]
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected a loaded context") }

        let navigation = Task { await store.selectBoard(slug: "beta") }
        await requester.waitUntilBoardFetchParked()
        XCTAssertFalse(store.isSelectedSnapshotLoaded)

        do {
            _ = try await store.specifyTask(id: "t1", expectedContext: stampA)
            XCTFail("a board-scoped mutation must fail closed during the transition")
        } catch KanbanServiceError.boardNavigationInProgress {
            // expected fail-closed
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(requester.calls.contains { $0.path.contains("/tasks/t1/specify") }, "zero specify may fire")

        requester.releaseBoardFetches()
        await navigation.value
        XCTAssertEqual(store.loadedBoardSlug, "beta")
    }

    func testOrchestrationSaveStaleContextCannotReachServerB() async {
        let requesterA = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha"))
        let store = makeStore(requester: requesterA)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected a loaded context") }

        let requesterB = V3AMockRequester(responsesByPath: routes(boardSlug: "beta"))
        store.configure(requester: requesterB, serverIdentity: "https://b.test")

        do {
            _ = try await store.updateOrchestration(
                KanbanOrchestrationPatch(autoDecompose: false),
                expectedContext: stampA
            )
            XCTFail("a stale stamp must fail closed")
        } catch KanbanServiceError.boardNavigationInProgress {
            // fail-closed, expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(requesterB.calls.count, 0, "zero PUT may reach server B")
    }

    func testProfileSaveStaleContextCannotReachServerB() async {
        let requesterA = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha"))
        let store = makeStore(requester: requesterA)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected a loaded context") }

        let requesterB = V3AMockRequester(responsesByPath: routes(boardSlug: "beta"))
        store.configure(requester: requesterB, serverIdentity: "https://b.test")

        do {
            try await store.updateProfileDescription(
                profile: "coder",
                description: "New description",
                expectedContext: stampA
            )
            XCTFail("a stale stamp must fail closed")
        } catch KanbanServiceError.boardNavigationInProgress {
            // fail-closed, expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(requesterB.calls.count, 0, "zero PATCH may reach server B")
    }

    func testProfileGenerateStaleContextCannotReachServerB() async {
        let requesterA = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha"))
        let store = makeStore(requester: requesterA)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected a loaded context") }

        let requesterB = V3AMockRequester(responsesByPath: routes(boardSlug: "beta"))
        store.configure(requester: requesterB, serverIdentity: "https://b.test")

        do {
            _ = try await store.autoDescribeProfile(profile: "coder", overwrite: true, expectedContext: stampA)
            XCTFail("a stale stamp must fail closed")
        } catch KanbanServiceError.boardNavigationInProgress {
            // fail-closed, expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(requesterB.calls.count, 0, "zero describe-auto may reach server B")
    }

    func testNudgeStaleContextCannotReachServerB() async {
        let requesterA = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha"))
        let store = makeStore(requester: requesterA)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected a loaded context") }

        let requesterB = V3AMockRequester(responsesByPath: routes(boardSlug: "beta"))
        store.configure(requester: requesterB, serverIdentity: "https://b.test")

        do {
            try await store.nudgeDispatcher(expectedContext: stampA)
            XCTFail("a stale stamp must fail closed")
        } catch KanbanServiceError.boardNavigationInProgress {
            // fail-closed, expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(requesterB.calls.count, 0, "zero dispatch may reach server B")
    }

    // MARK: - 8. V3A final pass: in-flight editor state

    func testProfileSavePreservesEditsMadeAfterSubmission() {
        // submit "A"; user types "B" while pending; A succeeds
        let outcome = KanbanProfileDescriptionPolicy.saveCompletion(
            submitted: "A",
            currentRawDraft: "B",
            currentTrimmedDraft: "B"
        )
        XCTAssertEqual(outcome.baselineDescription, "A", "server baseline is the SUBMITTED value")
        XCTAssertEqual(outcome.draft, "B", "newer local typing is preserved, never marked saved")
        XCTAssertTrue(outcome.isDirtyAfter, "the newer text was never persisted: editor stays dirty")
        XCTAssertTrue(outcome.notice?.contains("still unsaved") == true)

        // no post-submit edit: normalized clean
        let clean = KanbanProfileDescriptionPolicy.saveCompletion(
            submitted: "A",
            currentRawDraft: "A",
            currentTrimmedDraft: "A"
        )
        XCTAssertEqual(clean.draft, "A")
        XCTAssertFalse(clean.isDirtyAfter)
        XCTAssertEqual(clean.notice, "Description saved.")

        // a trailing-newline-only change is NOT a newer edit (dirty compares
        // the trimmed draft)
        let newline = KanbanProfileDescriptionPolicy.saveCompletion(
            submitted: "A",
            currentRawDraft: "A\n",
            currentTrimmedDraft: "A"
        )
        XCTAssertFalse(newline.isDirtyAfter)
    }

    func testProfileGeneratePreservesEditsTypedWhilePending() {
        // generation starts from "A"; user types "B" while pending; server
        // generates "C"
        let outcome = KanbanProfileDescriptionPolicy.generateCompletion(
            submittedDraft: "A",
            currentRawDraft: "B",
            currentTrimmedDraft: "B",
            generated: "C"
        )
        XCTAssertEqual(outcome.baselineDescription, "C", "server baseline is the generated value")
        XCTAssertEqual(outcome.baselineIsAuto, true)
        XCTAssertEqual(outcome.draft, "B", "newer manual typing is preserved, not overwritten by C")
        XCTAssertTrue(outcome.isDirtyAfter, "remaining dirty against the generated baseline")
        XCTAssertTrue(outcome.notice?.contains("preserved") == true, "non-destructive notice")

        // no typing while pending: generated text is adopted cleanly
        let clean = KanbanProfileDescriptionPolicy.generateCompletion(
            submittedDraft: "A",
            currentRawDraft: "A",
            currentTrimmedDraft: "A",
            generated: "C"
        )
        XCTAssertEqual(clean.draft, "C")
        XCTAssertFalse(clean.isDirtyAfter)

        // F-1: the submission snapshot is TRIMMED (startGenerate freezes the
        // trimmed draft), so a whitespace-ragged editor state is never
        // misclassified as "newer typing": the generated value is adopted.
        let ragged = KanbanProfileDescriptionPolicy.generateCompletion(
            submittedDraft: "A",
            currentRawDraft: "A\n",
            currentTrimmedDraft: "A",
            generated: "C"
        )
        XCTAssertEqual(ragged.draft, "C", "trailing newline is not newer typing")
        XCTAssertFalse(ragged.isDirtyAfter)
        XCTAssertEqual(ragged.notice, "Generated automatically — review recommended.")
    }

    func testEditorLivenessTokenOwnsBusyReleaseIndependentlyOfGeneration() {
        var liveness = KanbanEditorLiveness()
        let op1 = liveness.begin()
        XCTAssertTrue(liveness.owns(op1))
        let op2 = liveness.begin()
        XCTAssertFalse(liveness.owns(op1), "a newer operation owns the busy flag now")
        XCTAssertTrue(liveness.owns(op2))
        XCTAssertEqual(liveness.token, op2, "monotonic token")
    }

    func testStaleCompletionStillOwnsItsLocalBusyTokenAfterReconfigure() async {
        // The editor starts ONE operation and captures its liveness token
        // BEFORE the simulated reconfigure - this is precisely the contract
        // the test asserts (merge pass: the old version fabricated an
        // unrelated fresh token and proved nothing).
        var liveness = KanbanEditorLiveness()
        let operationID = liveness.begin()
        let requesterA = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha"))
        let store = makeStore(requester: requesterA)
        await store.reload()
        let generationA = store.currentConfigurationGeneration

        requesterA.suspend(method: "POST", basePath: "/api/plugins/kanban/profiles/coder/describe-auto")
        let operation = Task { try? await store.autoDescribeProfile(profile: "coder", overwrite: true) }
        await requesterA.waitForSuspension()

        let requesterB = V3AMockRequester(responsesByPath: routes(boardSlug: "beta"))
        store.configure(requester: requesterB, serverIdentity: "https://b.test")
        requesterA.resumeSuspended()
        _ = await operation.value

        // Independent facts the view relies on for busy-release:
        XCTAssertFalse(store.isCurrentConfiguration(generationA), "generation A is stale after the reconfigure")
        XCTAssertTrue(liveness.owns(operationID), "the STALE completion still owns its local busy token, so it can release the flag")
        // Store-level inertness of the stale completion is preserved:
        XCTAssertNil(store.mutationErrorMessage)
        XCTAssertEqual(requesterB.calls.count, 0)
    }

    // MARK: - V3A merge pass: triage completion suppression

    func testTriageCompletionSuppressionSurvivesFailedRefresh() {
        let stamp = KanbanBoardContextStamp(boardSlug: "alpha", configurationGeneration: 4)
        let marker = CompletedTriageMutation(taskID: "t1", context: stamp)
        // Cached detail still reports triage: suppression holds - no second
        // request can be staged for the committed task.
        XCTAssertTrue(KanbanTriageCompletionPolicy.isSuppressed(completed: marker, displayedTaskID: "t1", context: stamp))
        // Task replaced.
        XCTAssertFalse(KanbanTriageCompletionPolicy.isSuppressed(completed: marker, displayedTaskID: "t2", context: stamp))
        // Board/server context replaced.
        XCTAssertFalse(KanbanTriageCompletionPolicy.isSuppressed(
            completed: marker,
            displayedTaskID: "t1",
            context: KanbanBoardContextStamp(boardSlug: "beta", configurationGeneration: 4)
        ))
        // No loaded context / no marker: never suppressed.
        XCTAssertFalse(KanbanTriageCompletionPolicy.isSuppressed(completed: marker, displayedTaskID: "t1", context: nil))
        XCTAssertFalse(KanbanTriageCompletionPolicy.isSuppressed(completed: nil, displayedTaskID: "t1", context: stamp))
    }

    func testTriageCompletionMarkerClearsOnlyAfterAuthoritativeReconciliation() {
        XCTAssertTrue(KanbanTriageCompletionPolicy.shouldClearAfterReconciliation(reconciledStatus: "todo"))
        XCTAssertTrue(KanbanTriageCompletionPolicy.shouldClearAfterReconciliation(reconciledStatus: "ready"))
        XCTAssertTrue(KanbanTriageCompletionPolicy.shouldClearAfterReconciliation(reconciledStatus: "done"))
        // The task still reports triage from an authoritative load: the
        // marker KEEPS the actions suppressed until state proves otherwise.
        XCTAssertFalse(KanbanTriageCompletionPolicy.shouldClearAfterReconciliation(reconciledStatus: "triage"))
    }

    // MARK: - V3A merge pass: nudge notice invalidation

    func testNudgeNoticeClearsOnBoardChangeAndOldTimerIsInert() {
        var state = KanbanNudgeNoticeState()
        let alphaTimer = state.show("Dispatcher nudged")
        XCTAssertEqual(state.notice, "Dispatcher nudged")

        // Board switch alpha -> beta: feedback clears IMMEDIATELY.
        state.invalidateOnContextChange()
        XCTAssertNil(state.notice)
        // The old alpha auto-hide timer firing later changes nothing.
        state.hideIfCurrent(alphaTimer)
        XCTAssertNil(state.notice)

        // A later beta notice cannot be cleared by the old timer...
        let betaTimer = state.show("Dispatcher nudged")
        XCTAssertEqual(state.notice, "Dispatcher nudged")
        state.hideIfCurrent(alphaTimer)
        XCTAssertEqual(state.notice, "Dispatcher nudged", "the stale timer is inert for the newer notice")
        // ...only its own (current) timer clears it.
        state.hideIfCurrent(betaTimer)
        XCTAssertNil(state.notice)
    }

    // MARK: - 9. V3A final pass: continuation-helper + nudge feedback

    func testWaitForSuspensionWhenRequestParksFirstDoesNotDestroyContinuation() async {
        let requester = V3AMockRequester(responsesByPath: routes())
        let store = makeStore(requester: requester)
        await store.reload()

        requester.suspend(method: "PUT", basePath: "/api/plugins/kanban/orchestration")
        let operation = Task { try? await store.updateOrchestration(KanbanOrchestrationPatch(autoDecompose: false)) }

        // Scheduling order: request parks BEFORE waitForSuspension() executes.
        await requester.waitUntilParked()
        await requester.waitForSuspension()
        // The parked continuation must STILL be the one resumeSuspended
        // releases (the old removeAll() destroyed it -> deadlock).
        requester.resumeSuspended()
        _ = await operation.value

        XCTAssertFalse(store.isMutating)
        XCTAssertNil(store.mutationErrorMessage)
        XCTAssertNotNil(store.orchestration, "operation completed and reconciled")
    }

    func testWaitForSuspensionRegistersBeforeParkStillReleases() async {
        let requester = V3AMockRequester(responsesByPath: routes())
        let store = makeStore(requester: requester)
        await store.reload()

        requester.suspend(method: "POST", basePath: "/api/plugins/kanban/dispatch")
        let waiter = Task { await requester.waitForSuspension() }
        let operation = Task { try? await store.nudgeDispatcher() }
        await waiter.value // wakes the moment the request parks
        XCTAssertEqual(requester.calls.filter { $0.path.contains("/dispatch") }.count, 1)

        requester.resumeSuspended()
        _ = await operation.value
        XCTAssertFalse(store.isMutating)
        XCTAssertNil(store.mutationErrorMessage)
    }

    func testStaleNudgeSuccessShowsNoFeedbackOnNewContext() {
        let stampA = KanbanBoardContextStamp(boardSlug: "alpha", configurationGeneration: 7)
        let stampB = KanbanBoardContextStamp(boardSlug: "beta", configurationGeneration: 8)
        XCTAssertFalse(
            KanbanNudgePolicy.shouldShowNotice(capturedStamp: stampA, currentStamp: stampB, isSnapshotActionable: true),
            "a /dispatch that finished on A must not surface as feedback on B"
        )
        XCTAssertFalse(
            KanbanNudgePolicy.shouldShowNotice(capturedStamp: stampA, currentStamp: nil, isSnapshotActionable: true)
        )
        XCTAssertFalse(
            KanbanNudgePolicy.shouldShowNotice(capturedStamp: stampA, currentStamp: stampA, isSnapshotActionable: false),
            "a stale/non-actionable snapshot never shows nudge feedback"
        )
    }

    func testNudgeNoticeStillShownWhenContextUnchanged() {
        let stampA = KanbanBoardContextStamp(boardSlug: "alpha", configurationGeneration: 7)
        XCTAssertTrue(
            KanbanNudgePolicy.shouldShowNotice(capturedStamp: stampA, currentStamp: stampA, isSnapshotActionable: true)
        )
    }

    // MARK: - 6. Decompose

    func testDecomposeTapRequiresExplicitConfirmation() {
        XCTAssertEqual(KanbanTriageActionsPolicy.decomposeTap(), .confirm, "a tap resolves to a confirmation, never the mutation")
        XCTAssertEqual(KanbanTriageActionsPolicy.decomposeConfirmationTitle, "Decompose this task?")
        XCTAssertEqual(
            KanbanTriageActionsPolicy.decomposeConfirmationMessage,
            "Hermes may create and assign multiple dependent tasks."
        )
    }

    func testDecomposeSuccessReconcilesFromAuthoritativeBoardReload() async throws {
        let t1 = makeTask(id: "t1", status: "triage")
        let requester = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha", task: t1))
        requester.responsesByPath["/api/plugins/kanban/tasks/t1/decompose"] = [
            "ok": true,
            "task_id": "t1",
            "reason": "decomposed into 2 children",
            "fanout": true,
            "child_ids": ["c1", "c2"],
            "new_title": nil as Any?,
        ]
        // Authoritative server state after fan-out: root t1 -> todo with two
        // children c1/c2 in todo. Conduit must render THIS, not synthesize
        // cards from the response (the response carries ids only).
        let afterColumns: [[String: Any]] = [
            ["name": "triage", "tasks": []],
            ["name": "todo", "tasks": [
                ["id": "t1", "title": "Root", "status": "todo"],
                ["id": "c1", "title": "Child 1", "status": "todo"],
                ["id": "c2", "title": "Child 2", "status": "todo"],
            ]],
            ["name": "ready", "tasks": []],
        ]
        let requesterBoard = V3AMockRequester.board(columns: afterColumns)
        requester.boardProvider = { fetch in
            fetch >= 2 ? requesterBoard : V3AMockRequester.staticBoard(task: t1)
        }
        let store = makeStore(requester: requester)
        await store.reload()

        let outcome = try await store.decomposeTask(id: "t1")

        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(outcome.childIDs, ["c1", "c2"])
        XCTAssertEqual(
            KanbanTriageActionsPolicy.successNotice(fanout: outcome.fanout, childCount: outcome.childIDs.count),
            "Decomposed into 2 tasks"
        )
        XCTAssertEqual(requester.boardFetches, 2, "authoritative superseding reload after decompose")
        let todoIDs = store.board?.columns.filter { $0.name == "todo" }.flatMap(\.tasks).map(\.id) ?? []
        XCTAssertEqual(todoIDs, ["t1", "c1", "c2"], "board reflects the authoritative fan-out, never synthetic cards")
        XCTAssertNil(store.mutationErrorMessage)
    }

    func testDecomposeSemanticFailurePreservesTaskAndSurfacesReason() async {
        let t1 = makeTask(id: "t1", status: "triage")
        let requester = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha", task: t1))
        requester.responsesByPath["/api/plugins/kanban/tasks/t1/decompose"] = [
            "ok": false, "task_id": "t1", "reason": "task moved out of triage before decomposition",
            "fanout": false, "child_ids": [], "new_title": nil as Any?,
        ]
        let store = makeStore(requester: requester)
        await store.reload()

        do {
            _ = try await store.decomposeTask(id: "t1")
            XCTFail("semantic failure must throw")
        } catch let error as KanbanServiceError {
            XCTAssertEqual(error, .actionDeclined(reason: "task moved out of triage before decomposition"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(store.board?.columns.first { $0.name == "triage" }?.tasks.first?.id, "t1", "task intact")
        XCTAssertEqual(store.mutationErrorMessage, "task moved out of triage before decomposition")
    }

    func testDecomposeSuccessWithFailedRefreshIsPartialSuccessNotFailure() async throws {
        let t1 = makeTask(id: "t1", status: "triage")
        let requester = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha", task: t1))
        requester.responsesByPath["/api/plugins/kanban/tasks/t1/decompose"] = [
            "ok": true, "task_id": "t1", "reason": "decomposed into 1 children",
            "fanout": true, "child_ids": ["c1"], "new_title": nil as Any?,
        ]
        // The decompose SUCCEEDS, but the authoritative refresh afterwards
        // fails — the board must stay cached (never cleared) and the mutation
        // must not be reported as failed.
        requester.boardProvider = { fetch in
            if fetch >= 2 { throw URLError(.cannotConnectToHost) }
            return V3AMockRequester.staticBoard(task: t1)
        }
        let store = makeStore(requester: requester)
        await store.reload()

        let outcome = try await store.decomposeTask(id: "t1")
        XCTAssertTrue(outcome.ok, "the decompose itself succeeded")
        XCTAssertNil(store.mutationErrorMessage, "the mutation must not be presented as failed")
        XCTAssertNotNil(store.board, "cached board content survives a failed refresh")
        XCTAssertNotNil(store.errorMessage, "the REFRESH failure is its own banner channel")
        XCTAssertFalse(store.isMutating)
    }

    func testDecomposeServerNavigationRaceIsInert() async {
        let t1 = makeTask(id: "t1", status: "triage")
        let requesterA = V3AMockRequester(responsesByPath: routes(boardSlug: "alpha", task: t1))
        requesterA.responsesByPath["/api/plugins/kanban/tasks/t1/decompose"] = [
            "ok": true, "task_id": "t1", "reason": "decomposed into 1 children",
            "fanout": true, "child_ids": ["c1"], "new_title": nil as Any?,
        ]
        let store = makeStore(requester: requesterA)
        await store.reload()

        requesterA.suspend(method: "POST", basePath: "/api/plugins/kanban/tasks/t1/decompose")
        let task = Task { try? await store.decomposeTask(id: "t1") }
        await requesterA.waitForSuspension()

        let requesterB = V3AMockRequester(responsesByPath: routes(boardSlug: "beta"))
        store.configure(requester: requesterB, serverIdentity: "https://b.test")
        requesterA.resumeSuspended()
        _ = await task.value

        XCTAssertEqual(requesterB.calls.count, 0, "decompose started for A must never reconcile B")
        XCTAssertNil(store.board)
        XCTAssertNil(store.mutationErrorMessage)
        XCTAssertFalse(store.isMutating)
    }

    func testPartialSuccessRefreshWordingNeverBlamesTheMutation() {
        // Mutation succeeded + refresh failed: the wording blames the refresh.
        let notice = KanbanTriageActionsPolicy.successNoticeWithRefreshFailure(
            base: "Decomposed into 3 tasks",
            storeRefreshError: "network unreachable"
        )
        XCTAssertTrue(notice.hasPrefix("Decomposed into 3 tasks"))
        XCTAssertTrue(notice.contains("could not be refreshed"))
        XCTAssertTrue(notice.hasSuffix("network unreachable"))
        // Refresh fine: exact base passes through untouched.
        XCTAssertEqual(
            KanbanTriageActionsPolicy.successNoticeWithRefreshFailure(base: "Task specified", storeRefreshError: nil),
            "Task specified"
        )
        XCTAssertEqual(
            KanbanTriageActionsPolicy.successNoticeWithRefreshFailure(base: "Task specified", storeRefreshError: "  "),
            "Task specified",
            "blank refresh errors never wrap the base"
        )
        // Decompose fanout=false single-task fallback wording.
        XCTAssertEqual(KanbanTriageActionsPolicy.successNotice(fanout: false, childCount: 0), "Decomposed (single task, no fan-out)")
    }

    func testSpecifyResponseDecodesTolerantly() throws {
        let json = """
        {"ok": true, "task_id": "t7", "reason": "specified", "new_title": "Tightened"}
        """
        let outcome = try JSONDecoder().decode(KanbanSpecifyResponse.self, from: Data(json.utf8))
        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(outcome.taskID, "t7")
        XCTAssertEqual(outcome.newTitle, "Tightened")

        // Tolerant decode mirror of the Decompose case: hostile field types
        // degrade without crashing.
        let malformed = """
        {"ok": "nope", "task_id": 7, "new_title": ["array"]}
        """
        let tolerant = try JSONDecoder().decode(KanbanSpecifyResponse.self, from: Data(malformed.utf8))
        XCTAssertFalse(tolerant.ok)
        XCTAssertEqual(tolerant.taskID, "7")
        XCTAssertNil(tolerant.newTitle, "non-string new_title fails safe to nil")
    }

    func testAutoPromoteChildrenBackendDefaultConstant() {
        XCTAssertTrue(KanbanOrchestrationSettings.defaultAutoPromoteChildren, "upstream config default is true")
    }

    func testDecomposeResponseDecodesTolerantly() throws {
        let json = """
        {"ok": true, "task_id": "t9", "reason": "decomposed into 0 children",
         "fanout": false, "child_ids": [], "new_title": "Tightened"}
        """
        let outcome = try JSONDecoder().decode(KanbanDecomposeResponse.self, from: Data(json.utf8))
        XCTAssertTrue(outcome.ok)
        XCTAssertFalse(outcome.fanout)
        XCTAssertEqual(outcome.childIDs, [])
        XCTAssertEqual(outcome.newTitle, "Tightened")

        let malformed = """
        {"ok": "yes", "task_id": 7, "child_ids": "nope"}
        """
        let tolerant = try JSONDecoder().decode(KanbanDecomposeResponse.self, from: Data(malformed.utf8))
        XCTAssertFalse(tolerant.ok, "non-bool ok fails safely")
        // Lossy string decoding converts a numeric task_id ("7") rather than
        // crashing or dropping the identity; non-array child_ids degrades to [].
        XCTAssertEqual(tolerant.taskID, "7")
        XCTAssertEqual(tolerant.childIDs, [])
    }
}

// MARK: - V3A request double

/// Deterministic DashboardJSONRequester double: static or closure-backed
/// responses, recorded calls, per-request error injection, and a
/// continuation handshake to suspend a request mid-flight (no sleeps).
@MainActor
private final class V3AMockRequester: DashboardJSONRequester {
    struct Call {
        let path: String
        let method: String
        let body: [String: Any]?
    }

    static let defaultProfiles: [[String: Any]] = [
        ["name": "coder", "is_default": false, "model": "", "provider": "",
         "description": "Swift/iOS implementation and debugging", "description_auto": false, "skill_count": 3],
        ["name": "default", "is_default": true, "model": "", "provider": "",
         "description": "General purpose", "description_auto": true, "skill_count": 0],
    ]

    static let defaultOrchestration: [String: Any] = [
        "orchestrator_profile": "",
        "default_assignee": "",
        "auto_decompose": true,
        "auto_promote_children": true,
        "resolved_orchestrator_profile": "default",
        "resolved_default_assignee": "coder",
        "active_profile": "default",
    ]

    static func board(columns: [[String: Any]]) -> [String: Any] {
        ["columns": columns, "tenants": [], "assignees": [], "latest_event_id": 1, "now": 2]
    }

    /// JSON-compatible task row: the transport layer re-serializes mock
    /// responses with JSONSerialization, so structs must not leak in.
    private static func taskJSON(_ task: KanbanTask) -> [String: Any] {
        let data = try! JSONEncoder().encode(task)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    static func staticBoard(task: KanbanTask?) -> [String: Any] {
        let rows: [[String: Any]] = task.map { [taskJSON($0)] } ?? []
        let columns: [[String: Any]] = [
            ["name": "triage", "tasks": task?.status == "triage" ? rows : []],
            ["name": "todo", "tasks": task?.status == "todo" ? rows : []],
            ["name": "ready", "tasks": []],
        ]
        return board(columns: columns)
    }

    var responsesByPath: [String: [String: Any]]
    var errorsByPath: [String: Error] = [:]
    var boardProvider: (Int) throws -> [String: Any]
    var profilesProvider: (Int) -> [String: Any]
    var boardFetches = 0
    var calls: [Call] = []

    /// Live orchestration state: seeded from the initial route map, then
    /// merged by every PUT so the post-mutation GET sees the new value.
    private var orchestrationResponse: [String: Any]

    private var suspendEntries: [(method: String, basePath: String)] = []
    private var suspended: [CheckedContinuation<Void, Never>] = []
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var parkedCount = 0
    private var parkedWaiters: [CheckedContinuation<Void, Never>] = []
    /// Board-fetch gate (merge pass): suspends specific GET /board fetches so
    /// a test can hold a board navigation IN FLIGHT while server-global
    /// mutations run, then release it and observe convergence.
    var blockedBoardFetches: [Int] = []
    private var boardGateContinuations: [CheckedContinuation<Void, Never>] = []
    private var boardGateWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilBoardFetchParked() async {
        if !boardGateContinuations.isEmpty {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            boardGateWaiters.append(continuation)
        }
    }

    func releaseBoardFetches() {
        let pending = boardGateContinuations
        boardGateContinuations.removeAll()
        pending.forEach { $0.resume() }
    }

    init(responsesByPath: [String: [String: Any]] = [:]) {
        self.responsesByPath = responsesByPath
        // Default: serve the route-map board (falling back to an empty board)
        // so tests that never override the provider still load the fixture.
        let staticBoardRow = responsesByPath["/api/plugins/kanban/board"]
        boardProvider = { _ in
            staticBoardRow ?? V3AMockRequester.staticBoard(task: nil)
        }
        profilesProvider = { [responsesByPath] _ in
            responsesByPath["/api/plugins/kanban/profiles"] ?? ["profiles": []]
        }
        orchestrationResponse = responsesByPath["/api/plugins/kanban/orchestration"] ?? V3AMockRequester.defaultOrchestration
    }

    func suspend(method: String, basePath: String) {
        suspendEntries.append((method, basePath))
    }

    /// FIX (V3A final pass, review): never destroys the parked request
    /// continuation. If the request already parked, this returns immediately
    /// and resumeSuspended() alone owns the release; otherwise it registers a
    /// waiter that requestJSON resumes the moment the request parks.
    func waitForSuspension() async {
        if !suspended.isEmpty {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            suspensionWaiters.append(continuation)
        }
    }

    /// Deterministic "the request has parked" signal for the park-before-
    /// waiter scheduling order (no sleeps): returns once the suspended
    /// request is parked and waiting for resumeSuspended.
    func waitUntilParked() async {
        if parkedCount > 0 {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            parkedWaiters.append(continuation)
        }
    }

    func resumeSuspended() {
        let pending = suspended
        suspended.removeAll()
        pending.forEach { $0.resume() }
    }

    func requestJSON(path: String, method: String, body: [String: Any]?, timeoutMilliseconds: Int, maxResponseBytes: Int) async throws -> [String: Any] {
        let call = Call(path: path, method: method, body: body)
        calls.append(call)
        let basePath = path.components(separatedBy: "?").first ?? path

        if suspendEntries.contains(where: { $0.method == method && $0.basePath == basePath }) {
            suspendEntries.removeAll { $0.method == method && $0.basePath == basePath }
            parkedCount += 1
            parkedWaiters.forEach { $0.resume() }
            parkedWaiters.removeAll()
            suspensionWaiters.forEach { $0.resume() }
            suspensionWaiters.removeAll()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                suspended.append(continuation)
            }
        }

        if let error = errorsByPath[path] ?? errorsByPath[basePath] { throw error }
        if method == "GET", basePath == "/api/plugins/kanban/board" {
            boardFetches += 1
            if blockedBoardFetches.contains(boardFetches) {
                boardGateWaiters.forEach { $0.resume() }
                boardGateWaiters.removeAll()
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    boardGateContinuations.append(continuation)
                }
            }
            return try boardProvider(boardFetches)
        }
        if method == "GET", basePath == "/api/plugins/kanban/profiles" {
            return profilesProvider(calls.filter { $0.method == "GET" && $0.path.contains("/profiles") }.count)
        }
        if basePath == "/api/plugins/kanban/orchestration" {
            if method == "PUT", let body {
                for (key, value) in body where !(value is NSNull) {
                    orchestrationResponse[key] = value
                }
            }
            return orchestrationResponse
        }
        if let response = responsesByPath[path] ?? responsesByPath[basePath] { return response }
        return [:]
    }
}
