import Foundation
import SwiftUI

/// Immutable capture of everything a mutation needs. Captured BEFORE the first
/// suspension point so a concurrent board/server switch can never splice a
/// new board slug (or a different backend) into an in-flight write.
struct KanbanOperationContext {
    let service: KanbanService
    let boardSlug: String?
    let configurationGeneration: Int
}

/// Immutable board/server ownership of the currently loaded snapshot: the
/// loaded board slug plus the configuration generation that produced it.
/// Destructive confirmations staged on one context (e.g. a pending card
/// delete) must match this stamp EXACTLY before executing — a task id alone
/// is never an ownership token, because ids can collide across independent
/// boards/servers.
struct KanbanBoardContextStamp: Equatable {
    let boardSlug: String
    let configurationGeneration: Int
}

@MainActor
final class KanbanStore: ObservableObject {
    static let selectedBoardKey = "conduit.kanbanBoardSlug"

    @Published private(set) var boards: [KanbanBoardMetadata] = []
    @Published private(set) var currentServerBoardSlug = "default"
    @Published private(set) var board: KanbanBoard?
    @Published private(set) var profiles: [KanbanProfile] = []
    @Published private(set) var projects: [KanbanProject] = []
    @Published private(set) var orchestration: KanbanOrchestrationSettings?
    @Published private(set) var selectedBoardSlug = ""
    /// Board identity of the snapshot currently on screen. Set ONLY when a
    /// load completes for the generation that is still current; mutations
    /// always target this value so a displayed card can never be written to a
    /// different board than the one it was read from.
    @Published private(set) var loadedBoardSlug: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isMutating = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var mutationErrorMessage: String?

    private let defaults: UserDefaults
    private let makeService: @MainActor (any DashboardJSONRequester) -> KanbanService
    private var service: KanbanService?
    private var requesterID: ObjectIdentifier?
    private var serverIdentity = ""
    private var persistenceKey: String?
    private var loadGeneration = 0
    /// Bumped on every configure(); captured by mutations so post-mutation
    /// refreshes and UI-state writes from an old server/board context are
    /// discarded.
    private var configurationGeneration = 0
    /// Generation of the mutation that currently owns isMutating/
    /// mutationErrorMessage. Nil when no live operation owns the UI; configure()
    /// clears it immediately so a stale server's completion becomes inert.
    private var activeMutationGeneration: Int?

    /// The current configuration generation, captured BEFORE a suspension so a
    /// completion can prove it still belongs to the current server/board
    /// context (store-level UI-inertness for view-local state writing).
    var currentConfigurationGeneration: Int { configurationGeneration }

    /// True while a captured generation is still the store's current
    /// configuration generation - the ownership check for view-local
    /// completions (sheets/editors) that must stay UI-inert after configure().
    func isCurrentConfiguration(_ generation: Int) -> Bool {
        configurationGeneration == generation
    }

    init(
        defaults: UserDefaults = .standard,
        serviceFactory: ((any DashboardJSONRequester) -> KanbanService)? = nil
    ) {
        self.defaults = defaults
        self.makeService = serviceFactory ?? { KanbanService(requester: $0) }
    }

    var effectiveBoardSlug: String? {
        selectedBoardSlug.isEmpty ? nil : selectedBoardSlug
    }

    /// The board identity the selection currently resolves to ("Server
    /// current" collapses onto the server-reported current board).
    var resolvedSelectedBoardSlug: String {
        selectedBoardSlug.isEmpty ? currentServerBoardSlug : selectedBoardSlug
    }

    /// True when the on-screen snapshot belongs to the currently selected
    /// board. During navigation the stale snapshot stays visible but must be
    /// non-actionable: mutations are rejected in the store and the view
    /// disables creation/moves/deletes until the new board finishes loading.
    var isSelectedSnapshotLoaded: Bool {
        loadedBoardSlug == resolvedSelectedBoardSlug
    }

    /// Stamp of the board/server context that currently owns mutations, or
    /// nil while no snapshot is loaded. Staged destructive confirmations
    /// capture this at STAGE time and must match it again at CONFIRM time;
    /// any board or server switch (different slug, or a configure() that
    /// bumps the generation) invalidates the staged request fail-closed.
    /// Note the generation deliberately does NOT change on reloads, polls,
    /// or board selections — only configure() moves it (and configure()
    /// early-returns for an identical requester+URL, matching the mutation
    /// ownership model; do not "fix" the counter into every reload).
    var loadedContextStamp: KanbanBoardContextStamp? {
        guard let loadedBoardSlug else { return nil }
        return KanbanBoardContextStamp(boardSlug: loadedBoardSlug, configurationGeneration: configurationGeneration)
    }

    var selectedBoardMetadata: KanbanBoardMetadata? {
        let slug = selectedBoardSlug.isEmpty ? currentServerBoardSlug : selectedBoardSlug
        return boards.first(where: { $0.slug == slug })
    }

    /// Board selection is scoped to the dashboard SERVER identity only.
    /// Hermes Kanban is a shared, cross-profile coordination primitive anchored
    /// at the shared Hermes root (kanban_db.py resolves profiles back through
    /// get_default_hermes_root()), so profiles on one dashboard intentionally
    /// see the same boards - there is nothing profile-scoped to persist. Two
    /// different dashboards (roots) never share a selection.
    static func scopedBoardKey(serverIdentity: String) -> String {
        // Normalize exactly like configure() so equivalent URLs share a key.
        let normalized = serverIdentity.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return selectedBoardKey + "." + scopeToken(normalized)
    }

    func configure(requester: (any DashboardJSONRequester)?, serverIdentity: String = "") {
        guard let requester else {
            configurationGeneration += 1
            loadGeneration += 1
            isLoading = false
            endActiveMutationOwnership()
            service = nil
            requesterID = nil
            board = nil
            boards = []
            loadedBoardSlug = nil
            return
        }

        let normalizedServer = serverIdentity.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let identity = ObjectIdentifier(requester)
        if requesterID == identity && self.serverIdentity == normalizedServer { return }

        // Invalidate any cancelled load or in-flight mutation from the
        // previous bridge/server. Their completions must not repopulate this
        // store, touch its UI mutation state, or trigger refreshes after the
        // data source changes.
        configurationGeneration += 1
        loadGeneration += 1
        isLoading = false
        endActiveMutationOwnership()
        loadedBoardSlug = nil

        service = makeService(requester)
        requesterID = identity
        self.serverIdentity = normalizedServer
        let scopedKey = Self.scopedBoardKey(serverIdentity: normalizedServer)
        persistenceKey = scopedKey
        selectedBoardSlug = defaults.string(forKey: scopedKey) ?? ""

        // One-time migration for the pre-scoped key.
        if selectedBoardSlug.isEmpty, let legacy = defaults.string(forKey: Self.selectedBoardKey) {
            selectedBoardSlug = legacy
            defaults.set(legacy, forKey: scopedKey)
            defaults.removeObject(forKey: Self.selectedBoardKey)
        }

        board = nil
        boards = []
        profiles = []
        projects = []
        orchestration = nil
        currentServerBoardSlug = "default"
        errorMessage = nil
        mutationErrorMessage = nil
    }

    /// `superseding: true` lets an explicit user navigation (board selection)
    /// invalidate and outrun an in-flight background poll. The stale load's
    /// completion is discarded by the generation checks below.
    func reload(includeArchived: Bool = false, superseding: Bool = false) async {
        if !superseding && isLoading { return }
        loadGeneration += 1
        let generation = loadGeneration
        guard let service else {
            if board == nil {
                errorMessage = "Connect to a Hermes dashboard to use Kanban."
            }
            return
        }

        // Freeze nothing yet: the concrete slug can only be known after
        // /boards returns and invalid-selection validation runs, so the fetch
        // below always carries an explicit ?board= that matches what we record.
        isLoading = true
        errorMessage = nil
        defer {
            if generation == loadGeneration { isLoading = false }
        }

        do {
            let boardResponse = try await service.fetchBoards()
            guard generation == loadGeneration else { return }

            boards = boardResponse.boards
            currentServerBoardSlug = boardResponse.current

            if !selectedBoardSlug.isEmpty && !boards.contains(where: { $0.slug == selectedBoardSlug }) {
                selectedBoardSlug = ""
                if let persistenceKey { defaults.removeObject(forKey: persistenceKey) }
            }

            // Pin ONE concrete identity for this load. An omitted board=
            // would let the backend resolve "current" independently at GET
            // /board time, so loadedBoardSlug could drift from what was truly
            // fetched if another client moved the pointer in between.
            let resolvedSlug = selectedBoardSlug.isEmpty ? boardResponse.current : selectedBoardSlug

            async let loadedBoard = service.fetchBoard(slug: resolvedSlug, includeArchived: includeArchived)
            async let loadedProfiles = try? service.fetchProfiles()
            async let loadedProjects = try? service.fetchProjects()
            async let loadedOrchestration = try? service.fetchOrchestration()

            let resolvedBoard = try await loadedBoard
            let resolvedProfiles = await loadedProfiles
            let resolvedProjects = await loadedProjects
            let resolvedOrchestration = await loadedOrchestration
            guard generation == loadGeneration else { return }

            board = resolvedBoard
            // Exactly the slug used in GET /board?board=... above.
            loadedBoardSlug = resolvedSlug
            if let resolvedProfiles { profiles = resolvedProfiles }
            if let resolvedProjects { projects = resolvedProjects }
            if let resolvedOrchestration { orchestration = resolvedOrchestration }
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            // Keep the last successful board visible during refresh failures.
            errorMessage = error.localizedDescription
        }
    }

    func poll(includeArchived: Bool = false) async {
        guard !isMutating, !isLoading else { return }
        await reload(includeArchived: includeArchived)
    }

    func selectBoard(slug: String, includeArchived: Bool = false) async {
        selectedBoardSlug = slug
        if slug.isEmpty {
            if let persistenceKey { defaults.removeObject(forKey: persistenceKey) }
        } else if let persistenceKey {
            defaults.set(slug, forKey: persistenceKey)
        }
        // Explicit navigation supersedes any in-flight poll so the displayed
        // snapshot converges on the selection instead of racing it.
        await reload(includeArchived: includeArchived, superseding: true)
    }

    func refresh(includeArchived: Bool = false) async {
        guard !isMutating else { return }
        await reload(includeArchived: includeArchived)
    }

    func fetchTaskDetail(id: String) async throws -> KanbanTaskDetail {
        guard let service else { throw KanbanServiceError.invalidResponse("Kanban is not connected.") }
        return try await service.fetchTask(id: id, board: loadedBoardSlug ?? effectiveBoardSlug)
    }

    func fetchTaskLog(id: String, tailBytes: Int = 16_384) async throws -> KanbanWorkerLog {
        guard let service else { throw KanbanServiceError.invalidResponse("Kanban is not connected.") }
        return try await service.fetchTaskLog(id: id, board: loadedBoardSlug ?? effectiveBoardSlug, tailBytes: tailBytes)
    }

    /// Provider/model roster for the per-task override picker. Read-only
    /// auxiliary data: failures are surfaced to the caller (the picker falls
    /// back to free-text entry) but never touch board state.
    func fetchModelOptions() async throws -> [KanbanModelProviderOption] {
        guard let service else { throw KanbanServiceError.invalidResponse("Kanban is not connected.") }
        return try await service.fetchModelOptions()
    }

    @discardableResult
    func createTask(
        _ request: KanbanCreateTaskRequest,
        initialStatus: String? = nil,
        includeArchived: Bool = false
    ) async throws -> KanbanTask? {
        guard !isMutating else {
            throw recordMutationError(KanbanServiceError.mutationInProgress)
        }
        // Context is frozen before the first suspension point.
        guard let context = makeOperationContext() else {
            throw recordMutationError(KanbanServiceError.invalidResponse("Kanban is not connected."))
        }
        let targetStatus = initialStatus ?? (request.triage ? "triage" : "todo")

        return try await performMutation(context: context, includeArchived: includeArchived) {
            // Upstream only exposes creation targets on unlocked lanes; locked
            // lanes are rejected before any POST so no partial task can exist.
            guard KanbanStatusPresentation.canCreateTask(in: targetStatus) else {
                throw KanbanServiceError.invalidManualStatus(targetStatus)
            }

            var body = request
            if targetStatus == "triage" { body.triage = true }
            let response = try await context.service.createTask(body, board: context.boardSlug)
            var task = response.task

            // Upstream parity: native triage landing, otherwise a guarded
            // follow-up transition when the created status differs from the
            // requested lane (board.tsx submit()).
            let needsMove = targetStatus != "todo" && targetStatus != "triage" && task?.status != targetStatus
            if needsMove {
                guard let taskID = task?.id, !taskID.isEmpty else {
                    context.service.scheduleDispatcherNudge(board: context.boardSlug)
                    throw KanbanServiceError.taskCreatedButMoveFailed(
                        taskID: nil,
                        targetStatus: targetStatus,
                        reason: "Hermes did not return the created task ID."
                    )
                }
                do {
                    task = try await context.service.updateTask(
                        id: taskID,
                        board: context.boardSlug,
                        patch: KanbanTaskPatch(status: targetStatus)
                    ) ?? task
                } catch {
                    context.service.scheduleDispatcherNudge(board: context.boardSlug)
                    throw KanbanServiceError.taskCreatedButMoveFailed(
                        taskID: taskID,
                        targetStatus: targetStatus,
                        reason: error.localizedDescription
                    )
                }
            }

            context.service.scheduleDispatcherNudge(board: context.boardSlug)
            return task
        }
    }

    @discardableResult
    func updateTask(id: String, patch: KanbanTaskPatch, includeArchived: Bool = false) async throws -> KanbanTask? {
        guard !isMutating else {
            throw recordMutationError(KanbanServiceError.mutationInProgress)
        }
        guard let context = makeOperationContext() else {
            throw recordMutationError(KanbanServiceError.invalidResponse("Kanban is not connected."))
        }
        return try await performMutation(context: context, includeArchived: includeArchived) {
            if let status = patch.status, !KanbanStatusPresentation.canSelectManually(status) {
                throw KanbanServiceError.invalidManualStatus(status)
            }
            let task = try await context.service.updateTask(id: id, board: context.boardSlug, patch: patch)
            context.service.scheduleDispatcherNudge(board: context.boardSlug)
            return task
        }
    }

    func deleteTask(id: String, includeArchived: Bool = false) async throws {
        // !isMutating is the fast-path UX rejection only; performMutation
        // additionally enforces the structural activeMutationGeneration and
        // snapshot invariants inside the same actor turn.
        guard !isMutating else {
            throw recordMutationError(KanbanServiceError.mutationInProgress)
        }
        guard let context = makeOperationContext() else {
            throw recordMutationError(KanbanServiceError.invalidResponse("Kanban is not connected."))
        }
        try await performMutation(context: context, includeArchived: includeArchived) {
            try await context.service.deleteTask(id: id, board: context.boardSlug)
            // Deleting can unblock dependants, so it nudges too (upstream).
            context.service.scheduleDispatcherNudge(board: context.boardSlug)
        }
    }

    /// Context-bound permanent deletion for STAGED destructive confirmations
    /// (card Delete…). TOCTOU-closed: the staged ownership stamp is validated
    /// against the currently loaded context AND the mutation operation
    /// context is captured back-to-back — both on the MainActor, before the
    /// first suspension point — so validation and capture are atomic. A
    /// confirmation staged for server/board A can therefore never execute a
    /// DELETE under context B, even when the store reconfigures or switches
    /// boards between the confirmation tap and the spawned Task's execution.
    /// The view-level KanbanCardDeletePolicy check remains only as early UX
    /// rejection; THIS is the hard safety boundary and fails closed.
    func deleteTask(id: String, expectedContext: KanbanBoardContextStamp, includeArchived: Bool = false) async throws {
        guard isSelectedSnapshotLoaded, loadedContextStamp == expectedContext else {
            // Fail closed: the staged confirmation no longer owns the loaded
            // board/server context. Discard it without any destructive
            // request — a colliding task id on the new board is never a match.
            throw recordMutationError(KanbanServiceError.boardNavigationInProgress)
        }
        // !isMutating is the fast-path UX rejection only; performMutation
        // additionally enforces the structural activeMutationGeneration and
        // snapshot invariants inside the same actor turn.
        guard !isMutating else {
            throw recordMutationError(KanbanServiceError.mutationInProgress)
        }
        guard let context = makeOperationContext() else {
            throw recordMutationError(KanbanServiceError.invalidResponse("Kanban is not connected."))
        }
        try await performMutation(context: context, includeArchived: includeArchived) {
            try await context.service.deleteTask(id: id, board: context.boardSlug)
            // Deleting can unblock dependants, so it nudges too (upstream).
            context.service.scheduleDispatcherNudge(board: context.boardSlug)
        }
    }

    func addComment(taskID: String, body: String) async throws {
        guard !isMutating else {
            throw recordMutationError(KanbanServiceError.mutationInProgress)
        }
        guard let context = makeOperationContext() else {
            throw recordMutationError(KanbanServiceError.invalidResponse("Kanban is not connected."))
        }
        try await performMutation(context: context, includeArchived: false) {
            // Comments are not dispatcher-relevant upstream: no nudge.
            try await context.service.addComment(taskID: taskID, board: context.boardSlug, body: body)
        }
    }

    func reassignTask(taskID: String, profile: String?, reclaimFirst: Bool = true) async throws {
        guard !isMutating else {
            throw recordMutationError(KanbanServiceError.mutationInProgress)
        }
        guard let context = makeOperationContext() else {
            throw recordMutationError(KanbanServiceError.invalidResponse("Kanban is not connected."))
        }
        try await performMutation(context: context, includeArchived: false) {
            try await context.service.reassignTask(taskID: taskID, board: context.boardSlug, profile: profile, reclaimFirst: reclaimFirst)
            context.service.scheduleDispatcherNudge(board: context.boardSlug)
        }
    }

    func reclaimTask(taskID: String, reason: String? = nil) async throws {
        guard !isMutating else {
            throw recordMutationError(KanbanServiceError.mutationInProgress)
        }
        guard let context = makeOperationContext() else {
            throw recordMutationError(KanbanServiceError.invalidResponse("Kanban is not connected."))
        }
        try await performMutation(context: context, includeArchived: false) {
            try await context.service.reclaimTask(taskID: taskID, board: context.boardSlug, reason: reason)
            context.service.scheduleDispatcherNudge(board: context.boardSlug)
        }
    }

    // MARK: - V3A: Orchestration settings

    /// PUT /orchestration (server-global, but still server-ownership-safe:
    /// the mutation context pins the loaded board/server generation and the
    /// post-mutation superseding reload refreshes GET /orchestration).
    /// Upstream does NOT nudge the dispatcher for settings saves.
    @discardableResult
    func updateOrchestration(_ patch: KanbanOrchestrationPatch, includeArchived: Bool = false) async throws -> KanbanOrchestrationSettings? {
        guard !isMutating else {
            throw recordMutationError(KanbanServiceError.mutationInProgress)
        }
        guard let context = makeOperationContext() else {
            throw recordMutationError(KanbanServiceError.invalidResponse("Kanban is not connected."))
        }
        return try await performMutation(context: context, includeArchived: includeArchived) {
            let settings = try await context.service.updateOrchestration(patch)
            // Adopt the backend's resolved echo ONLY while this mutation still
            // owns the current generation: after configure() the completion is
            // inert and must not repopulate the newly configured store.
            if configurationGeneration == context.configurationGeneration {
                orchestration = settings
            }
            return settings
        }
    }

    // MARK: - V3A: Profile routing descriptions

    /// PATCH /profiles/{name} {description}. Not dispatcher-relevant upstream
    /// (the desktop saves descriptions without a nudge).
    func updateProfileDescription(profile: String, description: String, includeArchived: Bool = false) async throws {
        guard !isMutating else {
            throw recordMutationError(KanbanServiceError.mutationInProgress)
        }
        guard let context = makeOperationContext() else {
            throw recordMutationError(KanbanServiceError.invalidResponse("Kanban is not connected."))
        }
        try await performMutation(context: context, includeArchived: includeArchived) {
            try await context.service.updateProfileDescription(profile: profile, description: description)
        }
    }

    /// POST /profiles/{name}/describe-auto. The generated text is persisted
    /// immediately server-side; a non-ok outcome is a SEMANTIC refusal the
    /// caller renders inline (never an HTTP error, never a fabricated
    /// failure).
    @discardableResult
    func autoDescribeProfile(profile: String, overwrite: Bool = true, includeArchived: Bool = false) async throws -> KanbanAutoDescribeResponse {
        guard !isMutating else {
            throw recordMutationError(KanbanServiceError.mutationInProgress)
        }
        guard let context = makeOperationContext() else {
            throw recordMutationError(KanbanServiceError.invalidResponse("Kanban is not connected."))
        }
        return try await performMutation(context: context, includeArchived: includeArchived) {
            let outcome = try await context.service.autoDescribeProfile(profile: profile, overwrite: overwrite)
            if outcome.ok, let generated = outcome.description,
               configurationGeneration == context.configurationGeneration {
                // Adopt the authoritative generated text locally (generation-
                // guarded: a stale completion never repopulates the store);
                // reload also refreshes profile descriptions.
                profiles = profiles.map {
                    $0.name == outcome.profile ? KanbanProfile(
                        name: $0.name,
                        isDefault: $0.isDefault,
                        description: generated,
                        descriptionAuto: true,
                        model: $0.model,
                        provider: $0.provider,
                        skillCount: $0.skillCount
                    ) : $0
                }
            }
            return outcome
        }
    }

    // MARK: - V3A: Triage actions

    /// Specify a TRIAGE task: POST /tasks/{id}/specify, then supersede stale
    /// board polling with an authoritative reload. The backend flips the task
    /// triage -> todo (and recompute_ready may promote it to ready). A
    /// semantic {ok:false} refusal throws the backend reason; the task is
    /// left intact and the failure is recorded as the current-generation
    /// mutation error.
    @discardableResult
    func specifyTask(id: String, includeArchived: Bool = false) async throws -> KanbanSpecifyResponse {
        guard !isMutating else {
            throw recordMutationError(KanbanServiceError.mutationInProgress)
        }
        guard let context = makeOperationContext() else {
            throw recordMutationError(KanbanServiceError.invalidResponse("Kanban is not connected."))
        }
        return try await performMutation(context: context, includeArchived: includeArchived) {
            try await context.service.specifyTask(id: id, board: context.boardSlug)
        }
    }

    /// Decompose a TRIAGE task: POST /tasks/{id}/decompose, then reconcile
    /// from authoritative REST state (performMutation's superseding reload).
    /// The response is child ids only — Conduit NEVER synthesizes cards from
    /// it. Semantic refusal throws the backend reason.
    @discardableResult
    func decomposeTask(id: String, includeArchived: Bool = false) async throws -> KanbanDecomposeResponse {
        guard !isMutating else {
            throw recordMutationError(KanbanServiceError.mutationInProgress)
        }
        guard let context = makeOperationContext() else {
            throw recordMutationError(KanbanServiceError.invalidResponse("Kanban is not connected."))
        }
        return try await performMutation(context: context, includeArchived: includeArchived) {
            try await context.service.decomposeTask(id: id, board: context.boardSlug)
        }
    }

    // MARK: - V3A: Manual dispatcher nudge

    /// Explicit board-menu nudge. Ownership-disciplined like every mutation:
    /// the request is issued only while the captured context still owns the
    /// UI, and a completion after configure() is inert. The board reload
    /// after success doubles as the authoritative post-nudge refresh.
    func nudgeDispatcher(includeArchived: Bool = false) async throws {
        guard !isMutating else {
            throw recordMutationError(KanbanServiceError.mutationInProgress)
        }
        guard let context = makeOperationContext() else {
            throw recordMutationError(KanbanServiceError.invalidResponse("Kanban is not connected."))
        }
        try await performMutation(context: context, includeArchived: includeArchived) {
            try await context.service.nudgeDispatcher(board: context.boardSlug)
        }
    }

    func clearMutationError() {
        mutationErrorMessage = nil
    }

    /// Test seam: awaits any in-flight debounced dispatcher nudge owned by the
    /// active service, so tests need no wall-clock sleeps.
    func awaitPendingDispatcherNudgeForTesting() async {
        await service?.awaitPendingDispatcherNudgeForTesting()
    }

    func showMutationError(_ error: Error) {
        mutationErrorMessage = error.localizedDescription
    }

    // MARK: - Mutation state

    private func makeOperationContext() -> KanbanOperationContext? {
        guard let service else { return nil }
        // Bind to the LOADED snapshot identity, never the mutable selection:
        // a card on screen must be written back to the board it was read from,
        // even if the user has already started navigating elsewhere.
        guard let loadedBoardSlug else { return nil }
        return KanbanOperationContext(
            service: service,
            boardSlug: loadedBoardSlug,
            configurationGeneration: configurationGeneration
        )
    }

    private func performMutation<T>(
        context: KanbanOperationContext,
        includeArchived: Bool,
        operation: () async throws -> T
    ) async throws -> T {
        let generation = context.configurationGeneration
        // Only one operation may own the UI mutation state at a time. The
        // owning generation is recorded so configure() can revoke ownership
        // instantly when the data source changes mid-flight.
        guard activeMutationGeneration == nil else {
            let error = KanbanServiceError.mutationInProgress
            mutationErrorMessage = error.localizedDescription
            throw error
        }
        // Navigation invariant: while the selected and loaded board identities
        // differ, the visible snapshot belongs to the OLD board. Refuse to act
        // on it rather than writing old-board data under a new-board UI.
        guard isSelectedSnapshotLoaded else {
            let error = KanbanServiceError.boardNavigationInProgress
            mutationErrorMessage = error.localizedDescription
            throw error
        }
        activeMutationGeneration = generation
        isMutating = true
        mutationErrorMessage = nil
        do {
            let result = try await operation()
            if configurationGeneration == generation {
                // A finished mutation is newer authoritative activity than any
                // passive poll that started before it: supersede so the
                // reconciliation cannot be dropped behind isLoading.
                await reload(includeArchived: includeArchived, superseding: true)
            }
            endMutationOwnership(generation: generation)
            return result
        } catch {
            // Ownership check FIRST: after a reconfigure, this completion must
            // be completely inert - no refresh, no UI error text, no flag flip.
            let stillOwnsUI = configurationGeneration == generation && activeMutationGeneration == generation
            if stillOwnsUI {
                // Refresh (superseding) so a partial success - e.g. a created
                // task whose follow-up move failed - becomes visible even when
                // a passive poll is already in flight.
                await reload(includeArchived: includeArchived, superseding: true)
                mutationErrorMessage = error.localizedDescription
            }
            endMutationOwnership(generation: generation)
            throw error
        }
    }

    /// Revokes this operation's UI ownership if it still holds it.
    private func endMutationOwnership(generation: Int) {
        guard activeMutationGeneration == generation else { return }
        activeMutationGeneration = nil
        if configurationGeneration == generation {
            isMutating = false
        }
    }

    /// Immediately strips any in-flight operation of UI mutation ownership.
    private func endActiveMutationOwnership() {
        activeMutationGeneration = nil
        isMutating = false
    }

    private func recordMutationError(_ error: KanbanServiceError) -> KanbanServiceError {
        mutationErrorMessage = error.localizedDescription
        return error
    }

    private static func scopeToken(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
