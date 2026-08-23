import XCTest
@testable import Conduit

/// Kanban V3B: board administration (create/update/archive), project +
/// default-workdir wire semantics, client-side filters, Show Archived, and
/// Running grouped by profile — with the full async ownership discipline.
///
/// Deterministic: no sleeps; continuation-handshake + provider-keyed mock.
@MainActor
final class KanbanV3BTests: XCTestCase {

    // MARK: - Helpers

    private func makeTask(id: String, status: String = "todo", assignee: String? = nil, tenant: String? = nil, title: String? = nil, body: String? = nil) -> KanbanTask {
        var object: [String: Any] = ["id": id, "title": title ?? "T \(id)", "status": status]
        if let assignee { object["assignee"] = assignee }
        if let tenant { object["tenant"] = tenant }
        if let body { object["body"] = body }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSONDecoder().decode(KanbanTask.self, from: data)
    }

    private func makeStore(requester: V3BMockRequester) -> KanbanStore {
        makeStore(requester: requester, defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private func makeStore(requester: V3BMockRequester, defaults: UserDefaults) -> KanbanStore {
        let store = KanbanStore(defaults: defaults)
        store.configure(requester: requester, serverIdentity: "https://a.test")
        return store
    }

    private func routes(
        boards: [[String: Any]] = V3BMockRequester.baseBoards,
        current: String = "alpha",
        board: [String: Any]? = nil
    ) -> [String: [String: Any]] {
        [
            "/api/plugins/kanban/boards": ["boards": boards, "current": current],
            "/api/plugins/kanban/board": board ?? V3BMockRequester.defaultBoard,
            "/api/plugins/kanban/profiles": ["profiles": []],
            "/api/plugins/kanban/projects": ["projects": V3BMockRequester.defaultProjects],
            "/api/plugins/kanban/orchestration": V3BMockRequester.defaultOrchestration,
            "/api/plugins/kanban/dispatch": [:],
        ]
    }

    private let projectA = ["id": "proj-a", "slug": "project-a", "name": "Project A", "primary_path": "/repos/a", "icon": "", "color": ""]
    private let projectB = ["id": "proj-b", "slug": "project-b", "name": "Project B", "primary_path": "/repos/b", "icon": "", "color": ""]

    // MARK: - 1. Board create: wire + slug

    func testCreateRequestEncodesPayloadExactly() throws {
        let request = KanbanCreateBoardRequest(
            slug: "my-board",
            name: "My Board",
            description: "desc",
            defaultWorkdir: "/repos/x",
            projectID: "proj-a",
            switchRequested: false
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["slug"] as? String, "my-board")
        XCTAssertEqual(object["name"] as? String, "My Board")
        XCTAssertEqual(object["description"] as? String, "desc")
        XCTAssertEqual(object["project_id"] as? String, "proj-a")
        XCTAssertEqual(object["default_workdir"] as? String, "/repos/x")
        XCTAssertEqual(object["switch"] as? Bool, false, "switch is EXPLICITLY false; server pointer never touched")

        let minimal = try JSONEncoder().encode(KanbanCreateBoardRequest(slug: "bare"))
        let minimalObject = try XCTUnwrap(JSONSerialization.jsonObject(with: minimal) as? [String: Any])
        XCTAssertNil(minimalObject["name"])
        XCTAssertNil(minimalObject["project_id"])
        XCTAssertEqual(minimalObject["switch"] as? Bool, false)
    }

    func testSlugDerivationMatchesDesktopAlgorithm() {
        XCTAssertEqual(KanbanBoardSlugPolicy.derivedSlug(from: "iOS Release Work"), "ios-release-work")
        XCTAssertEqual(KanbanBoardSlugPolicy.derivedSlug(from: "  My   Board!!! "), "my-board")
        XCTAssertEqual(KanbanBoardSlugPolicy.derivedSlug(from: "123 ABC"), "123-abc")
        XCTAssertEqual(KanbanBoardSlugPolicy.derivedSlug(from: "a--b"), "a-b")
        XCTAssertEqual(KanbanBoardSlugPolicy.derivedSlug(from: "---leading"), "leading")
        XCTAssertEqual(KanbanBoardSlugPolicy.derivedSlug(from: "日本語"), "", "non-ASCII yields empty (Create disabled)")
        XCTAssertEqual(KanbanBoardSlugPolicy.derivedSlug(from: ""), "")
    }

    func testSlugValidationMatchesBackendRegex() {
        XCTAssertTrue(KanbanBoardSlugPolicy.isValid("abc"))
        XCTAssertTrue(KanbanBoardSlugPolicy.isValid("a1-b_c"))
        XCTAssertFalse(KanbanBoardSlugPolicy.isValid(""))
        XCTAssertFalse(KanbanBoardSlugPolicy.isValid("-abc"))
        XCTAssertFalse(KanbanBoardSlugPolicy.isValid("_abc"))
        XCTAssertFalse(KanbanBoardSlugPolicy.isValid("ABC"))
        XCTAssertFalse(KanbanBoardSlugPolicy.isValid("a b"))
        XCTAssertFalse(KanbanBoardSlugPolicy.isValid("a.b"))
        XCTAssertFalse(KanbanBoardSlugPolicy.isValid(String(repeating: "a", count: 65)))
    }

    func testCustomPathFoldedIntoDraftAtSubmit() {
        // W1 regression: the PICKER row is pathless; the typed path is folded
        // in at submit time, so a selected "Custom Directory…" row must carry
        // the typed path into the create/patch builders.
        var draft = KanbanBoardEditorDraft(name: "X", description: "", projectID: nil, workspace: .custom(""))
        XCTAssertEqual(
            KanbanBoardPatchPolicy.createRequest(
                slug: "x", name: "X", description: "", projectID: nil, workspace: draft.workspace
            ).defaultWorkdir,
            nil,
            "an empty custom path is not a wire value"
        )
        draft.workspace = .custom(" /repos/typed ")
        XCTAssertEqual(
            KanbanBoardPatchPolicy.createRequest(
                slug: "x", name: "X", description: "", projectID: nil, workspace: draft.workspace
            ).defaultWorkdir,
            "/repos/typed",
            "the folded workspace choice carries the typed path"
        )
        let patch = KanbanBoardPatchPolicy.patch(
            baseline: boardMeta(name: "Alpha", workdir: "/repos/old"),
            draft: KanbanBoardEditorDraft(name: "Alpha", description: "", projectID: nil, workspace: .custom(" /repos/typed ")),
            projects: []
        )
        XCTAssertEqual(patch.defaultWorkdir, "/repos/typed")
    }

    func testCreateRequestProjectWorkspaceEncoding() {
        // Project + Project Default: only project_id travels; workdir mirrors
        // server-side.
        let mirrored = KanbanBoardPatchPolicy.createRequest(
            slug: "x", name: "X", description: "", projectID: "proj-a", workspace: .projectDefault
        )
        XCTAssertEqual(mirrored.projectID, "proj-a")
        XCTAssertNil(mirrored.defaultWorkdir)

        // B-1 documented contract: "None/Scratch" while a project is selected
        // is NOT representable upstream (the UI hides the row) - the policy
        // pins what the wire would do anyway: the server mirrors the project.
        let phantom = KanbanBoardPatchPolicy.createRequest(
            slug: "x", name: "X", description: "", projectID: "proj-a", workspace: .none
        )
        XCTAssertEqual(phantom.projectID, "proj-a")
        XCTAssertNil(phantom.defaultWorkdir, "project mirror still applies; documented, unreachable from the UI")

        // Custom directory with a project: explicit path wins.
        let explicit = KanbanBoardPatchPolicy.createRequest(
            slug: "x", name: "X", description: "d", projectID: "proj-a", workspace: .custom(" /repos/custom ")
        )
        XCTAssertEqual(explicit.defaultWorkdir, "/repos/custom")
        XCTAssertEqual(explicit.projectID, "proj-a")

        // No project, None: no workdir field at all.
        let none = KanbanBoardPatchPolicy.createRequest(
            slug: "x", name: "X", description: "", projectID: nil, workspace: .none
        )
        XCTAssertNil(none.defaultWorkdir)
        XCTAssertNil(none.projectID)
        XCTAssertFalse(none.switchRequested)
    }

    func testCreateInvalidSlugRejectedBeforeAnyRequest() async {
        let requester = V3BMockRequester(responsesByPath: routes())
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        do {
            _ = try await store.createBoard(KanbanCreateBoardRequest(slug: "BAD SLUG"), expectedContext: stampA)
            XCTFail("a malformed slug must be refused up front")
        } catch let error as KanbanServiceError {
            XCTAssertEqual(error, .actionDeclined(reason: "Invalid board slug — use 1-64 lowercase letters or numbers with hyphens/underscores."))
        } catch {
            XCTFail("unexpected: \(error)")
        }
        XCTAssertFalse(requester.calls.contains { $0.method == "POST" && $0.path.contains("/boards") }, "zero POST for an invalid slug")
    }

    func testArchiveUnexpectedActionResultFailsClosed() async {
        let requester = V3BMockRequester(responsesByPath: routes())
        requester.deleteBoardResponse = [
            "result": ["slug": "alpha", "action": "deleted", "new_path": ""],
            "current": "alpha",
        ]
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        do {
            _ = try await store.archiveBoard(slug: "alpha", expectedContext: stampA)
            XCTFail("a non-archive action must fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unexpected result"), "action mismatch surfaced: \(error.localizedDescription)")
        }
        XCTAssertNotNil(store.mutationErrorMessage)
        XCTAssertFalse(store.isMutating)
    }

    func testCreateServerChangeFailsClosed() async {
        let requesterA = V3BMockRequester(responsesByPath: routes())
        let store = makeStore(requester: requesterA)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        let requesterB = V3BMockRequester(responsesByPath: routes())
        store.configure(requester: requesterB, serverIdentity: "https://b.test")

        do {
            _ = try await store.createBoard(KanbanCreateBoardRequest(slug: "beta"), expectedContext: stampA)
            XCTFail("a create started for A must never execute on B")
        } catch KanbanServiceError.boardNavigationInProgress {
            // fail-closed
        } catch {
            XCTFail("unexpected: \(error)")
        }
        XCTAssertEqual(requesterB.calls.count, 0)
        XCTAssertFalse(requesterB.calls.contains { $0.method == "POST" && $0.path.contains("/boards") })
    }

    func testCreateSelectsReturnedSlugLocallyAndRefreshes() async throws {
        let requester = V3BMockRequester(responsesByPath: routes())
        requester.boardsProvider = { fetch in
            fetch >= 2
                ? ["boards": V3BMockRequester.baseBoards + [["slug": "beta", "name": "Beta", "archived": false]], "current": "alpha"]
                : ["boards": V3BMockRequester.baseBoards, "current": "alpha"]
        }
        requester.boardForSlug = { slug in
            slug == "beta" ? V3BMockRequester.board(columns: [["name": "todo", "tasks": []]]) : V3BMockRequester.defaultBoard
        }
        requester.postBoardResponse = [
            "board": ["slug": "beta", "name": "Beta", "archived": false],
            "current": "alpha",
        ]
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = makeStore(requester: requester, defaults: defaults)
        await store.reload()
        XCTAssertEqual(store.selectedBoardSlug, "")

        let request = KanbanCreateBoardRequest(slug: "beta", name: "Beta")
        let created = try await store.createBoard(request)

        XCTAssertEqual(created.slug, "beta")
        // Local selection only; the server pointer is never requested.
        XCTAssertEqual(store.selectedBoardSlug, "beta")
        let scopedKey = KanbanStore.scopedBoardKey(serverIdentity: "https://a.test")
        XCTAssertEqual(defaults.string(forKey: scopedKey), "beta", "the per-dashboard selection is persisted locally")
        let posts = requester.calls.filter { $0.method == "POST" && $0.path == "/api/plugins/kanban/boards" }
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.body?["switch"] as? Bool, false)
        XCTAssertNil(requester.calls.first { $0.path.contains("/switch") }, "POST /boards/{slug}/switch is never called")
        // Authoritative reconciliation landed on the created board.
        XCTAssertEqual(store.loadedBoardSlug, "beta")
        XCTAssertTrue(store.boards.contains { $0.slug == "beta" })
    }

    func testCreateOutcomeMessageIsHonestAboutIdempotentCollision() {
        XCTAssertEqual(
            KanbanBoardAdminMessage.createOutcomeMessage(knewSlugBeforeRequest: true, name: "beta"),
            "Board \"beta\" already exists — opened it.",
            "no fabricated created flag; document the idempotent-return behavior"
        )
        XCTAssertEqual(
            KanbanBoardAdminMessage.createOutcomeMessage(knewSlugBeforeRequest: false, name: "beta"),
            "Board \"beta\" created and selected."
        )
    }

    // MARK: - 2. Board PATCH wire semantics

    private func boardMeta(slug: String = "alpha", name: String = "Alpha", projectID: String? = nil, workdir: String? = nil) -> KanbanBoardMetadata {
        KanbanBoardMetadata(
            slug: slug,
            name: name,
            defaultWorkdir: workdir,
            projectID: projectID
        )
    }

    func testNameOnlyPatchOmitsProjectAndWorkdir() {
        // Project-scoped board with its workdir already following the project:
        // a pure name edit must NOT send project/workdir.
        let baseline = boardMeta(name: "Alpha", projectID: "proj-a", workdir: "/repos/a")
        let draft = KanbanBoardEditorDraft(
            name: "Renamed", description: "", projectID: "proj-a", workspace: .projectDefault
        )
        let patch = KanbanBoardPatchPolicy.patch(baseline: baseline, draft: draft, projects: [KanbanProject(id: "proj-a", slug: "project-a", name: "Project A", primaryPath: "/repos/a")])
        XCTAssertEqual(patch.name, "Renamed")
        XCTAssertNil(patch.projectID, "name-only edit never touches project")
        XCTAssertNil(patch.defaultWorkdir, "name-only edit never touches workdir")
    }

    func testPatchProjectSetAndClear() {
        // Set: No Project -> Project A (Project Default).
        let setPatch = KanbanBoardPatchPolicy.patch(
            baseline: boardMeta(),
            draft: KanbanBoardEditorDraft(name: "Alpha", description: "", projectID: "proj-a", workspace: .projectDefault),
            projects: []
        )
        XCTAssertEqual(setPatch.projectID, "proj-a")
        XCTAssertNil(setPatch.defaultWorkdir, "mirror is implied")

        // Clear: Project A -> No Project (with a stale workdir: cleared too).
        let clearPatch = KanbanBoardPatchPolicy.patch(
            baseline: boardMeta(name: "Alpha", projectID: "proj-a", workdir: "/repos/a"),
            draft: KanbanBoardEditorDraft(name: "Alpha", description: "", projectID: nil, workspace: .none),
            projects: []
        )
        XCTAssertEqual(clearPatch.projectID, "", "project clear is an explicit empty string")
        XCTAssertEqual(clearPatch.defaultWorkdir, "", "workdir clear is an explicit empty string")
    }

    func testPatchWorkdirSetAndClear() {
        let setPatch = KanbanBoardPatchPolicy.patch(
            baseline: boardMeta(),
            draft: KanbanBoardEditorDraft(name: "Alpha", description: "", projectID: nil, workspace: .custom(" /repos/new ")),
            projects: []
        )
        XCTAssertEqual(setPatch.defaultWorkdir, "/repos/new", "custom path trimmed and set")
        XCTAssertNil(setPatch.projectID)

        let clearPatch = KanbanBoardPatchPolicy.patch(
            baseline: boardMeta(name: "Alpha", workdir: "/repos/a"),
            draft: KanbanBoardEditorDraft(name: "Alpha", description: "", projectID: nil, workspace: .none),
            projects: []
        )
        XCTAssertEqual(clearPatch.defaultWorkdir, "")
    }

    func testPatchProjectPlusExplicitWorkdirInteraction() {
        // Changing the project WHILE entering a custom directory: both travel;
        // the explicit workdir wins over the server-side mirror.
        let patch = KanbanBoardPatchPolicy.patch(
            baseline: boardMeta(name: "Alpha"),
            draft: KanbanBoardEditorDraft(name: "Alpha", description: "", projectID: "proj-b", workspace: .custom("/repos/custom")),
            projects: [KanbanProject(id: "proj-b", slug: "project-b", name: "Project B", primaryPath: "/repos/b")]
        )
        XCTAssertEqual(patch.projectID, "proj-b")
        XCTAssertEqual(patch.defaultWorkdir, "/repos/custom")
    }

    func testPatchProjectDefaultRemirrorsDriftedWorkdir() {
        // Same project, but the workdir drifted away from the project repo:
        // re-sending the same project_id re-mirrors (default_workdir omitted).
        let patch = KanbanBoardPatchPolicy.patch(
            baseline: boardMeta(name: "Alpha", projectID: "proj-a", workdir: "/repos/stale"),
            draft: KanbanBoardEditorDraft(name: "Alpha", description: "", projectID: "proj-a", workspace: .projectDefault),
            projects: [KanbanProject(id: "proj-a", slug: "project-a", name: "Project A", primaryPath: "/repos/a")]
        )
        XCTAssertEqual(patch.projectID, "proj-a")
        XCTAssertNil(patch.defaultWorkdir)
    }

    func testPatchServerChangeFailsClosed() async {
        let requesterA = V3BMockRequester(responsesByPath: routes())
        let store = makeStore(requester: requesterA)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        let requesterB = V3BMockRequester(responsesByPath: routes())
        store.configure(requester: requesterB, serverIdentity: "https://b.test")

        do {
            _ = try await store.updateBoard(
                slug: "alpha",
                patch: KanbanUpdateBoardPatch(name: "X"),
                expectedContext: stampA
            )
            XCTFail("a stale stamp must fail closed")
        } catch KanbanServiceError.boardNavigationInProgress {
            // expected
        } catch {
            XCTFail("unexpected: \(error)")
        }
        XCTAssertEqual(requesterB.calls.count, 0)
    }

    func testUpdateCapturedSlugCannotRetargetAfterSelectionChange() async {
        let requester = V3BMockRequester(responsesByPath: routes())
        requester.boardsProvider = { _ in
            ["boards": V3BMockRequester.baseBoards, "current": "alpha"]
        }
        requester.boardForSlug = { _ in V3BMockRequester.defaultBoard }
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        // Settings opened while alpha loaded; the user switches to beta before
        // the async body runs. The captured stamp no longer owns the loaded
        // context (board-scope) -> fail closed, zero requests.
        await store.selectBoard(slug: "beta")
        XCTAssertEqual(store.loadedBoardSlug, "beta")

        do {
            _ = try await store.updateBoard(
                slug: "alpha",
                patch: KanbanUpdateBoardPatch(name: "X"),
                expectedContext: stampA
            )
            XCTFail("must fail closed after the selection moved")
        } catch KanbanServiceError.boardNavigationInProgress {
            // expected: the network target is the captured slug, never the
            // current selection - and it must not fire at all now.
        } catch {
            XCTFail("unexpected: \(error)")
        }
        XCTAssertFalse(requester.calls.contains { $0.method == "PATCH" && $0.path.contains("/boards/") })
    }

    // MARK: - 3. Archive

    func testArchiveNeverRequestsHardDelete() async throws {
        let requester = V3BMockRequester(responsesByPath: routes())
        requester.boardsProvider = { _ in
            ["boards": [["slug": "default", "name": "Default", "archived": false]], "current": "default"]
        }
        requester.boardForSlug = { _ in V3BMockRequester.defaultBoard }
        requester.deleteBoardResponse = [
            "result": ["slug": "alpha", "action": "archived", "new_path": "/kanban/boards/_archived/alpha-1"],
            "current": "default",
        ]
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        _ = try await store.archiveBoard(slug: "alpha", expectedContext: stampA)

        let deletes = requester.calls.filter { $0.method == "DELETE" && $0.path.contains("/boards/alpha") }
        XCTAssertEqual(deletes.count, 1)
        XCTAssertFalse(deletes.first?.path.contains("delete") ?? false, "hard-delete query is NEVER sent")
        XCTAssertNil(deletes.first?.body)
    }

    func testArchiveStagedForALeavesBUntouched() async {
        let requesterA = V3BMockRequester(responsesByPath: routes())
        let store = makeStore(requester: requesterA)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }
        let staged = PendingBoardArchive(slug: "alpha", displayName: "Alpha", stamp: stampA)

        // Server/board ownership replaced before the confirmation executes.
        let requesterB = V3BMockRequester(responsesByPath: routes())
        store.configure(requester: requesterB, serverIdentity: "https://b.test")

        do {
            _ = try await store.archiveBoard(slug: staged.slug, expectedContext: staged.stamp)
            XCTFail("a stale staged archive must fail closed")
        } catch KanbanServiceError.boardNavigationInProgress {
            // expected
        } catch {
            XCTFail("unexpected: \(error)")
        }
        XCTAssertEqual(requesterB.calls.count, 0, "a confirmation staged for A never archives on B")
        XCTAssertFalse(requesterA.calls.contains { $0.method == "DELETE" }, "no archive may fire after ownership loss")
    }

    func testArchiveDefaultBoardRefusedUpFront() async {
        let requester = V3BMockRequester(responsesByPath: routes())
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        do {
            _ = try await store.archiveBoard(slug: "default", expectedContext: stampA)
            XCTFail("the default board must be refused before any request")
        } catch let error as KanbanServiceError {
            XCTAssertEqual(error, .actionDeclined(reason: "Hermes does not allow archiving the default board."))
        } catch {
            XCTFail("unexpected: \(error)")
        }
        XCTAssertFalse(requester.calls.contains { $0.method == "DELETE" }, "zero DELETE for the default board")
    }

    func testArchivePartialSuccessMessageSurvivesFailedBoardsRefresh() async throws {
        let requester = V3BMockRequester(responsesByPath: routes())
        requester.boardsProvider = { fetch in
            if fetch >= 3 { throw URLError(.cannotConnectToHost) }
            return ["boards": V3BMockRequester.baseBoards, "current": "alpha"]
        }
        requester.boardForSlug = { _ in V3BMockRequester.defaultBoard }
        requester.deleteBoardResponse = [
            "result": ["slug": "beta", "action": "archived", "new_path": "/x"],
            "current": "alpha",
        ]
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        // DELETE succeeds (archiving a NON-selected board), but the boards
        // refresh afterwards fails: the ARCHIVE is not reported as failed and
        // the crafted partial-success wording survives (no clobbering reload).
        let archived = try await store.archiveBoard(slug: "beta", expectedContext: stampA)
        XCTAssertTrue(archived)
        XCTAssertNil(store.mutationErrorMessage, "the archive itself did not fail")
        XCTAssertTrue(
            store.errorMessage?.hasPrefix("The board was archived, but the board list could not be refreshed.") == true,
            "partial-success wording survives: \(store.errorMessage ?? "nil")"
        )
        XCTAssertFalse(store.isMutating, "ownership released")
    }

    func testUpdateEmptyPatchShortCircuitsWithoutRequest() async throws {
        let requester = V3BMockRequester(responsesByPath: routes())
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        let baseline = store.boards.first { $0.slug == "alpha" }
        let echoed = try await store.updateBoard(
            slug: "alpha",
            patch: KanbanUpdateBoardPatch(),
            expectedContext: stampA
        )
        XCTAssertEqual(echoed.slug, baseline?.slug)
        XCTAssertFalse(requester.calls.contains { $0.method == "PATCH" && $0.path.contains("/boards/") }, "an all-nil patch never reaches the wire")
    }

    func testUpdateSlugMismatchWithStampFailsClosed() async {
        let requester = V3BMockRequester(responsesByPath: routes())
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }
        // A valid stamp paired with the WRONG board slug must never issue.
        let foreignStamp = KanbanBoardContextStamp(boardSlug: "beta", configurationGeneration: stampA.configurationGeneration)

        do {
            _ = try await store.updateBoard(
                slug: "alpha",
                patch: KanbanUpdateBoardPatch(name: "X"),
                expectedContext: foreignStamp
            )
            XCTFail("a wrong-slug stamp must fail closed")
        } catch KanbanServiceError.boardNavigationInProgress {
            // expected
        } catch {
            XCTFail("unexpected: \(error)")
        }
        XCTAssertFalse(requester.calls.contains { $0.method == "PATCH" && $0.path.contains("/boards/") })
    }

    func testArchiveBackendRefusalPreserved() async {
        let requester = V3BMockRequester(responsesByPath: routes())
        requester.errorsByPath["/api/plugins/kanban/boards/beta"] = KanbanAdminTestError.refused("board 'beta' is already archived")
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        do {
            _ = try await store.archiveBoard(slug: "beta", expectedContext: stampA)
            XCTFail("the backend refusal must propagate")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already archived"), "backend reason surfaced verbatim")
            XCTAssertNotNil(store.mutationErrorMessage)
        }
    }

    func testArchiveSelectedBoardReconcilesToValidFallback() async throws {
        let requester = V3BMockRequester(responsesByPath: routes())
        requester.boardsProvider = { fetch in
            fetch >= 2
                ? ["boards": [["slug": "default", "name": "Default", "archived": false]], "current": "default"]
                : ["boards": V3BMockRequester.baseBoards, "current": "default"]
        }
        requester.boardForSlug = { slug in
            slug == "default" ? V3BMockRequester.defaultBoard : V3BMockRequester.board(columns: [["name": "todo", "tasks": []]])
        }
        requester.deleteBoardResponse = [
            "result": ["slug": "alpha", "action": "archived", "new_path": "/x"],
            "current": "default",
        ]
        let store = makeStore(requester: requester)
        // selectBoard performs the authoritative load (boards fetch #1 keeps
        // alpha; fetch #2+ drop it post-archive).
        await store.selectBoard(slug: "alpha")
        XCTAssertEqual(store.loadedBoardSlug, "alpha")
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        _ = try await store.archiveBoard(slug: "alpha", expectedContext: stampA)

        // Selected board disappeared: fallback resolved and authoritative
        // board reloaded; selection no longer points at the archived slug.
        XCTAssertFalse(store.boards.contains { $0.slug == "alpha" })
        XCTAssertEqual(store.selectedBoardSlug, "", "persisted selection cleared for the archived board")
        XCTAssertEqual(store.loadedBoardSlug, "default", "board converges on the valid fallback")
        XCTAssertNil(store.mutationErrorMessage)
    }

    func testArchiveNonSelectedBoardDoesNotDisturbSelection() async throws {
        let requester = V3BMockRequester(responsesByPath: routes())
        requester.boardsProvider = { _ in
            ["boards": V3BMockRequester.baseBoards, "current": "alpha"]
        }
        requester.boardForSlug = { _ in V3BMockRequester.defaultBoard }
        requester.deleteBoardResponse = [
            "result": ["slug": "beta", "action": "archived", "new_path": "/x"],
            "current": "alpha",
        ]
        let store = makeStore(requester: requester)
        await store.reload()
        guard let stampA = store.loadedContextStamp else { return XCTFail("expected context") }

        // Archive a NON-selected board while alpha stays loaded/selected.
        _ = try await store.archiveBoard(slug: "beta", expectedContext: stampA)

        XCTAssertEqual(store.selectedBoardSlug, "", "selection (server current -> alpha) undisturbed")
        XCTAssertEqual(store.loadedBoardSlug, "alpha", "the selected board is still loaded")
        XCTAssertNil(store.mutationErrorMessage)
    }

    // MARK: - 4. Filters

    private func filterFixture() -> KanbanTask {
        makeTask(id: "t1", assignee: "coder", tenant: "project-a", title: "Hello world", body: "details")
    }

    func testAssigneeFilterUsesExactTaskAssignee() {
        let coder = filterFixture()
        let reviewer = makeTask(id: "t2", assignee: "reviewer")
        let unassigned = makeTask(id: "t3", assignee: nil)

        XCTAssertTrue(KanbanBoardFilterPolicy.matchesAssignee(coder, "coder"))
        XCTAssertFalse(KanbanBoardFilterPolicy.matchesAssignee(reviewer, "coder"))
        // A task with NO assignee is never matched by an assignee filter,
        // even though the resolved default assignee may be "coder".
        XCTAssertFalse(KanbanBoardFilterPolicy.matchesAssignee(unassigned, "coder"))
        XCTAssertTrue(KanbanBoardFilterPolicy.matchesAssignee(unassigned, nil))
    }

    func testTenantFilterExactMatch() {
        let task = filterFixture()
        XCTAssertTrue(KanbanBoardFilterPolicy.matchesTenant(task, "project-a"))
        XCTAssertFalse(KanbanBoardFilterPolicy.matchesTenant(task, "project-b"))
        XCTAssertTrue(KanbanBoardFilterPolicy.matchesTenant(task, nil))
    }

    func testSearchCoversTitleBodyIDSummaryAndAssignee() {
        XCTAssertTrue(KanbanBoardFilterPolicy.matchesSearch(makeTask(id: "t-7"), "T-7"), "task id is searchable")
        XCTAssertTrue(KanbanBoardFilterPolicy.matchesSearch(filterFixture(), "hello"))
        XCTAssertTrue(KanbanBoardFilterPolicy.matchesSearch(filterFixture(), "DETAILS"))
        XCTAssertTrue(KanbanBoardFilterPolicy.matchesSearch(KanbanTask(id: "x", latestSummaryText: "summary"), "summary"))
        XCTAssertTrue(KanbanBoardFilterPolicy.matchesSearch(KanbanTask(id: "x", assigneeText: "coder"), "coder"))
        XCTAssertFalse(KanbanBoardFilterPolicy.matchesSearch(filterFixture(), "zzzz"))
        XCTAssertTrue(KanbanBoardFilterPolicy.matchesSearch(filterFixture(), "   "))
    }

    func testCombinedAndPredicate() {
        let task = filterFixture()
        XCTAssertTrue(KanbanBoardFilterPolicy.matches(task: task, search: "hello", assignee: "coder", tenant: "project-a"))
        XCTAssertFalse(KanbanBoardFilterPolicy.matches(task: task, search: "hello", assignee: "reviewer", tenant: "project-a"))
        XCTAssertFalse(KanbanBoardFilterPolicy.matches(task: task, search: "hello", assignee: "coder", tenant: "project-b"))
        XCTAssertFalse(KanbanBoardFilterPolicy.matches(task: task, search: "nope", assignee: nil, tenant: nil))
    }

    func testFiltersNeverMutateAuthoritativeBoard() {
        let board = KanbanBoard(
            columns: [
                KanbanColumn(name: "running", tasks: [makeTask(id: "a", assignee: "coder"), makeTask(id: "b", assignee: "reviewer")]),
            ],
            tenants: ["project-a"],
            assignees: ["coder", "reviewer"]
        )
        let baseColumns = board.columns
        let visible = KanbanBoardFilterPolicy.visibleColumns(board: board, search: "", assignee: "coder", tenant: nil)
        XCTAssertEqual(visible.first?.tasks.map(\.id), ["a"])
        XCTAssertEqual(board.columns, baseColumns, "the authoritative board is never mutated")
        XCTAssertEqual(board.columns.first?.tasks.count, 2)
    }

    func testStaleFilterResetsHarmlesslyWhenRosterChanges() {
        XCTAssertNil(KanbanBoardFilterPolicy.validatedFilter("coder", available: []), "stale profile filter deactivates")
        XCTAssertNil(KanbanBoardFilterPolicy.validatedFilter("coder", available: ["reviewer"]))
        XCTAssertEqual(KanbanBoardFilterPolicy.validatedFilter("coder", available: ["coder", "reviewer"]), "coder")
        XCTAssertNil(KanbanBoardFilterPolicy.validatedFilter("", available: ["coder"]))
        XCTAssertNil(KanbanBoardFilterPolicy.validatedFilter(nil, available: ["coder"]))
    }

    // MARK: - 5. Show Archived

    func testArchivedToggleIsTheServerFetchParameter() async {
        let requester = V3BMockRequester(responsesByPath: routes())
        var withArchivedColumn = false
        requester.boardForSlug = { _ in
            if withArchivedColumn {
                return V3BMockRequester.board(columns: [
                    ["name": "todo", "tasks": []],
                    ["name": "archived", "tasks": []],
                ])
            }
            return V3BMockRequester.board(columns: [["name": "todo", "tasks": []]])
        }
        let store = makeStore(requester: requester)
        await store.reload(includeArchived: false)
        XCTAssertFalse(requester.calls.contains { $0.path.contains("include_archived") }, "default fetch omits the param")
        XCTAssertFalse(store.board?.columns.contains { $0.name == "archived" } ?? true, "no archived column without the toggle")

        withArchivedColumn = true
        await store.reload(includeArchived: true)
        XCTAssertTrue(requester.calls.contains { $0.path.contains("include_archived=true") }, "Show Archived is a server fetch parameter")
        XCTAssertTrue(store.board?.columns.contains { $0.name == "archived" } ?? false, "archived column appears with the toggle")
    }

    func testArchivedLaneFallsBackWhenColumnHidden() {
        let visibleColumns = [KanbanColumn(name: "todo"), KanbanColumn(name: "ready")]
        XCTAssertEqual(
            KanbanLanePolicy.effectiveSelectedLane(selected: "archived", columns: visibleColumns),
            "todo",
            "a selected archived lane falls back to a sensible lane when the column is gone"
        )
        let withArchived = [KanbanColumn(name: "todo"), KanbanColumn(name: "archived")]
        XCTAssertEqual(KanbanLanePolicy.effectiveSelectedLane(selected: "archived", columns: withArchived), "archived")
    }

    // MARK: - 6. Running grouped by profile

    func testGroupingOffYieldsFlatList() {
        XCTAssertFalse(KanbanRunningGroupPolicy.shouldApply(lane: "running", enabled: false))
        XCTAssertFalse(KanbanRunningGroupPolicy.shouldApply(lane: "todo", enabled: true), "grouping ONLY affects Running")
        XCTAssertTrue(KanbanRunningGroupPolicy.shouldApply(lane: "running", enabled: true))
    }

    func testGroupingBucketsRunningByAssigneeWithUnassignedFallback() {
        let tasks = [
            makeTask(id: "a", assignee: "coder"),
            makeTask(id: "b", assignee: "coder"),
            makeTask(id: "c", assignee: nil),
            makeTask(id: "d", assignee: "reviewer"),
        ]
        let groups = KanbanRunningGroupPolicy.group(tasks)
        XCTAssertEqual(groups.map(\.key), ["coder", "reviewer", "unassigned"], "deterministic ordering, unassigned participates")
        XCTAssertEqual(groups[0].tasks.map(\.id), ["a", "b"])
        XCTAssertEqual(groups[2].displayName, "Unassigned")
        XCTAssertEqual(groups[2].tasks.map(\.id), ["c"])
    }

    func testGroupingDeterministicCaseInsensitiveOrderWithTieBreak() {
        let tasks = [
            makeTask(id: "1", assignee: "B"),
            makeTask(id: "2", assignee: "a"),
            makeTask(id: "3", assignee: "A"),
        ]
        let groups = KanbanRunningGroupPolicy.group(tasks)
        XCTAssertEqual(groups.map(\.key), ["A", "a", "B"], "case-insensitive primary, raw tie-break")
    }

    func testGroupingAppliesAfterFiltering() {
        let all = [
            makeTask(id: "keep", assignee: "coder", tenant: "project-a"),
            makeTask(id: "drop", assignee: "coder", tenant: "project-b"),
            makeTask(id: "nil", assignee: nil, tenant: "project-a"),
        ]
        let filtered = all.filter {
            KanbanBoardFilterPolicy.matches(task: $0, search: "", assignee: "coder", tenant: "project-a")
        }
        let groups = KanbanRunningGroupPolicy.group(filtered)
        XCTAssertEqual(groupByID(groups).sorted(), ["keep"], "grouping runs AFTER filtering")
    }

    private func groupByID(_ groups: [KanbanRunningGroupPolicy.Group]) -> [String] {
        groups.flatMap { $0.tasks.map(\.id) }.sorted()
    }
}

// MARK: - Fixtures

extension KanbanTask {
    fileprivate init(id: String, latestSummaryText: String? = nil, assigneeText: String? = nil) {
        var object: [String: Any] = ["id": id, "title": id, "status": "todo"]
        if let latestSummaryText { object["latest_summary"] = latestSummaryText }
        if let assigneeText { object["assignee"] = assigneeText }
        let data = try! JSONSerialization.data(withJSONObject: object)
        self = try! JSONDecoder().decode(KanbanTask.self, from: data)
    }
}

enum KanbanAdminTestError: LocalizedError {
    case refused(String)
    var errorDescription: String? {
        switch self {
        case .refused(let message): return message
        }
    }
}

/// Deterministic DashboardJSONRequester double for V3B: recorded calls,
/// slug-keyed board provider, boards-list provider, error injection, and the
/// continuation-handshake suspension machinery (no sleeps).
@MainActor
private final class V3BMockRequester: DashboardJSONRequester {
    struct Call {
        let path: String
        let method: String
        let body: [String: Any]?
    }

    static let baseBoards: [[String: Any]] = [
        ["slug": "alpha", "name": "Alpha", "archived": false],
        ["slug": "beta", "name": "Beta", "archived": false],
        ["slug": "default", "name": "Default", "archived": false],
    ]

    static let defaultProjects: [[String: Any]] = [
        ["id": "proj-a", "slug": "project-a", "name": "Project A", "primary_path": "/repos/a", "icon": "", "color": ""],
        ["id": "proj-b", "slug": "project-b", "name": "Project B", "primary_path": "/repos/b", "icon": "", "color": ""],
    ]

    static let defaultOrchestration: [String: Any] = [
        "orchestrator_profile": "", "default_assignee": "", "auto_decompose": true,
        "auto_promote_children": true, "resolved_orchestrator_profile": "default",
        "resolved_default_assignee": "coder", "active_profile": "default",
    ]

    static func board(columns: [[String: Any]]) -> [String: Any] {
        ["columns": columns, "tenants": ["project-a", "project-b"], "assignees": ["coder", "reviewer", "default"], "latest_event_id": 1, "now": 2]
    }

    static let defaultBoard: [String: Any] = board(columns: [
        ["name": "triage", "tasks": []],
        ["name": "todo", "tasks": []],
        ["name": "running", "tasks": []],
    ])

    var responsesByPath: [String: [String: Any]]
    var errorsByPath: [String: Error] = [:]
    var boardsProvider: (Int) throws -> [String: Any]
    var boardForSlug: (String) -> [String: Any]
    var deleteBoardResponse: [String: Any] = [:]
    var postBoardResponse: [String: Any] = [:]
    var boardFetches = 0
    var boardsFetches = 0
    var calls: [Call] = []

    private var suspendEntries: [(method: String, basePath: String)] = []
    private var suspended: [CheckedContinuation<Void, Never>] = []
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var parkedCount = 0
    private var parkedWaiters: [CheckedContinuation<Void, Never>] = []

    init(responsesByPath: [String: [String: Any]] = [:]) {
        self.responsesByPath = responsesByPath
        let boards = responsesByPath["/api/plugins/kanban/boards"] ?? ["boards": Self.baseBoards, "current": "alpha"]
        boardsProvider = { _ in boards }
        boardForSlug = { _ in Self.defaultBoard }
    }

    func suspend(method: String, basePath: String) {
        suspendEntries.append((method, basePath))
    }

    func waitForSuspension() async {
        if !suspended.isEmpty { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            suspensionWaiters.append(continuation)
        }
    }

    func waitUntilParked() async {
        if parkedCount > 0 { return }
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
        if method == "GET", basePath == "/api/plugins/kanban/boards" {
            boardsFetches += 1
            return try boardsProvider(boardsFetches)
        }
        if method == "GET", basePath == "/api/plugins/kanban/board" {
            boardFetches += 1
            let slug = queryValue("board", in: path) ?? "default"
            return boardForSlug(slug)
        }
        if method == "POST", basePath == "/api/plugins/kanban/boards" {
            return postBoardResponse
        }
        if method == "DELETE", basePath.hasPrefix("/api/plugins/kanban/boards/") {
            return deleteBoardResponse
        }
        if let response = responsesByPath[path] ?? responsesByPath[basePath] { return response }
        return [:]
    }

    private func queryValue(_ key: String, in path: String) -> String? {
        guard let query = path.components(separatedBy: "?").dropFirst().first else { return nil }
        return query.components(separatedBy: "&")
            .first { $0.hasPrefix(key + "=") }
            .map { String($0.dropFirst(key.count + 1)) }
    }
}
