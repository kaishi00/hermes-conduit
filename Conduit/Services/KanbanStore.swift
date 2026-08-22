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
    /// refreshes from an old server/board context are discarded.
    private var configurationGeneration = 0

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

    var selectedBoardMetadata: KanbanBoardMetadata? {
        let slug = selectedBoardSlug.isEmpty ? currentServerBoardSlug : selectedBoardSlug
        return boards.first(where: { $0.slug == slug })
    }

    /// Board selection is scoped to the dashboard SERVER identity only. The
    /// plugin API serves the backend's own Hermes home (one profile per
    /// process), so the server URL - not the app-level UI profile - is the
    /// real data boundary. Two dashboards never share a selection; switching
    /// Conduit's active profile on one dashboard intentionally does not either.
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
            service = nil
            requesterID = nil
            board = nil
            boards = []
            return
        }

        let normalizedServer = serverIdentity.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let identity = ObjectIdentifier(requester)
        if requesterID == identity && self.serverIdentity == normalizedServer { return }

        // Invalidate any cancelled load or in-flight mutation from the
        // previous bridge/server. Their completions must not repopulate this
        // store after the data source changes.
        configurationGeneration += 1
        loadGeneration += 1
        isLoading = false

        service = makeService(requester)
        requesterID = identity
        self.serverIdentity = normalizedServer
        persistenceKey = Self.scopedBoardKey(serverIdentity: normalizedServer)
        selectedBoardSlug = defaults.string(forKey: persistenceKey!) ?? ""

        // One-time migration for the pre-scoped key.
        if selectedBoardSlug.isEmpty, let legacy = defaults.string(forKey: Self.selectedBoardKey) {
            selectedBoardSlug = legacy
            defaults.set(legacy, forKey: persistenceKey!)
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

    func reload(includeArchived: Bool = false) async {
        guard !isLoading else { return }
        loadGeneration += 1
        let generation = loadGeneration
        guard let service else {
            if board == nil {
                errorMessage = "Connect to a Hermes dashboard to use Kanban."
            }
            return
        }

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

            async let loadedBoard = service.fetchBoard(slug: effectiveBoardSlug, includeArchived: includeArchived)
            async let loadedProfiles = try? service.fetchProfiles()
            async let loadedProjects = try? service.fetchProjects()
            async let loadedOrchestration = try? service.fetchOrchestration()

            let resolvedBoard = try await loadedBoard
            let resolvedProfiles = await loadedProfiles
            let resolvedProjects = await loadedProjects
            let resolvedOrchestration = await loadedOrchestration
            guard generation == loadGeneration else { return }

            board = resolvedBoard
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
        await reload(includeArchived: includeArchived)
    }

    func refresh(includeArchived: Bool = false) async {
        guard !isMutating else { return }
        await reload(includeArchived: includeArchived)
    }

    func fetchTaskDetail(id: String) async throws -> KanbanTaskDetail {
        guard let service else { throw KanbanServiceError.invalidResponse("Kanban is not connected.") }
        return try await service.fetchTask(id: id, board: effectiveBoardSlug)
    }

    func fetchTaskLog(id: String, tailBytes: Int = 16_384) async throws -> KanbanWorkerLog {
        guard let service else { throw KanbanServiceError.invalidResponse("Kanban is not connected.") }
        return try await service.fetchTaskLog(id: id, board: effectiveBoardSlug, tailBytes: tailBytes)
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

    func clearMutationError() {
        mutationErrorMessage = nil
    }

    func showMutationError(_ error: Error) {
        mutationErrorMessage = error.localizedDescription
    }

    // MARK: - Mutation state

    private func makeOperationContext() -> KanbanOperationContext? {
        guard let service else { return nil }
        return KanbanOperationContext(
            service: service,
            boardSlug: effectiveBoardSlug,
            configurationGeneration: configurationGeneration
        )
    }

    private func performMutation<T>(
        context: KanbanOperationContext,
        includeArchived: Bool,
        operation: () async throws -> T
    ) async throws -> T {
        isMutating = true
        mutationErrorMessage = nil
        defer { isMutating = false }
        do {
            let result = try await operation()
            if configurationGeneration == context.configurationGeneration {
                await reload(includeArchived: includeArchived)
            }
            return result
        } catch {
            // Refresh so a partial success (e.g. created-but-not-moved task)
            // becomes visible even though the overall call failed - unless the
            // store was reconfigured mid-flight, in which case the fresh load
            // already reflects the new source.
            if configurationGeneration == context.configurationGeneration {
                await reload(includeArchived: includeArchived)
            }
            mutationErrorMessage = error.localizedDescription
            throw error
        }
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
