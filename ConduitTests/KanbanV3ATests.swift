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

        let requesterB = V3AMockRequester(responsesByPath: routes(boardSlug: "beta"))
        store.configure(requester: requesterB, serverIdentity: "https://b.test")
        requesterA.resumeSuspended()
        _ = await task.value

        XCTAssertNil(store.mutationErrorMessage)
        XCTAssertTrue(store.profiles.isEmpty, "stale profile completion must not repopulate the new context")
        XCTAssertEqual(requesterB.calls.count, 0)
        XCTAssertEqual(
            KanbanProfileDescriptionPolicy.completionIsActive(sessionProfile: "coder", currentProfile: "coder"),
            true
        )
        XCTAssertEqual(
            KanbanProfileDescriptionPolicy.completionIsActive(sessionProfile: "coder", currentProfile: "lancelot"),
            false,
            "a session for A never updates B's editor"
        )
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
        let notice = KanbanTriageActionsPolicy.refreshFailureNotice(
            actionLabel: "Decomposition succeeded",
            detail: "network unreachable"
        )
        XCTAssertTrue(notice.hasPrefix("Decomposition succeeded"))
        XCTAssertTrue(notice.contains("could not be refreshed"))
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

    func waitForSuspension() async {
        if !suspended.isEmpty {
            suspended.removeAll()
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            suspensionWaiters.append(continuation)
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
            suspensionWaiters.forEach { $0.resume() }
            suspensionWaiters.removeAll()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                suspended.append(continuation)
            }
        }

        if let error = errorsByPath[path] ?? errorsByPath[basePath] { throw error }
        if method == "GET", basePath == "/api/plugins/kanban/board" {
            boardFetches += 1
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
