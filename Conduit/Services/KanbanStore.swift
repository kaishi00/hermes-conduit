import Foundation
import SwiftUI

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
    private var service: KanbanService?
    private var requesterID: ObjectIdentifier?
    private var profile = "default"
    private var serverIdentity = ""
    private var persistenceKey: String?
    private var loadGeneration = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var effectiveBoardSlug: String? {
        selectedBoardSlug.isEmpty ? nil : selectedBoardSlug
    }

    var selectedBoardMetadata: KanbanBoardMetadata? {
        let slug = selectedBoardSlug.isEmpty ? currentServerBoardSlug : selectedBoardSlug
        return boards.first(where: { $0.slug == slug })
    }

    static func scopedBoardKey(serverIdentity: String, profile: String) -> String {
        "\(selectedBoardKey).\(scopeToken(serverIdentity)).\(scopeToken(profile))"
    }

    func configure(
        requester: (any DashboardJSONRequester)?,
        profile: String = "default",
        serverIdentity: String = ""
    ) {
        guard let requester else {
            service = nil
            requesterID = nil
            board = nil
            boards = []
            return
        }

        let normalizedProfile = profile.isEmpty ? "default" : profile
        let normalizedServer = serverIdentity.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let identity = ObjectIdentifier(requester)
        let nextPersistenceKey = Self.scopedBoardKey(serverIdentity: normalizedServer, profile: normalizedProfile)
        guard requesterID != identity || self.profile != normalizedProfile || self.serverIdentity != normalizedServer else {
            return
        }

        self.service = KanbanService(requester: requester, profile: normalizedProfile)
        requesterID = identity
        self.profile = normalizedProfile
        self.serverIdentity = normalizedServer
        persistenceKey = nextPersistenceKey
        selectedBoardSlug = defaults.string(forKey: nextPersistenceKey) ?? ""

        // One-time migration for the pre-profile-scoped key. Once migrated,
        // every subsequent profile gets an independent board selection.
        if selectedBoardSlug.isEmpty, let legacy = defaults.string(forKey: Self.selectedBoardKey) {
            selectedBoardSlug = legacy
            defaults.set(legacy, forKey: nextPersistenceKey)
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
        loadGeneration &+= 1
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
        guard let service else {
            let error = KanbanServiceError.invalidResponse("Kanban is not connected.")
            mutationErrorMessage = error.localizedDescription
            throw error
        }
        let targetStatus = initialStatus ?? (request.triage ? "triage" : "todo")

        return try await performMutation(includeArchived: includeArchived) {
            guard KanbanStatusPresentation.canCreateTask(in: targetStatus) else {
                throw KanbanServiceError.invalidManualStatus(targetStatus)
            }

            var body = request
            if targetStatus == "triage" { body.triage = true }
            let response = try await service.createTask(body, board: self.effectiveBoardSlug)
            var task = response.task

            // The backend owns native triage/default creation. Other supported
            // manual lanes use one guarded follow-up transition.
            let needsMove = targetStatus != "todo" && targetStatus != "triage" && task?.status != targetStatus
            if needsMove {
                guard let taskID = task?.id, !taskID.isEmpty else {
                    await service.nudgeDispatcher(board: self.effectiveBoardSlug)
                    throw KanbanServiceError.taskCreatedButMoveFailed(
                        taskID: nil,
                        targetStatus: targetStatus,
                        reason: "Hermes did not return the created task ID."
                    )
                }
                do {
                    task = try await service.updateTask(
                        id: taskID,
                        board: self.effectiveBoardSlug,
                        patch: KanbanTaskPatch(status: targetStatus)
                    ) ?? task
                } catch {
                    await service.nudgeDispatcher(board: self.effectiveBoardSlug)
                    throw KanbanServiceError.taskCreatedButMoveFailed(
                        taskID: taskID,
                        targetStatus: targetStatus,
                        reason: error.localizedDescription
                    )
                }
            }

            await service.nudgeDispatcher(board: self.effectiveBoardSlug)
            return task
        }
    }

    @discardableResult
    func updateTask(id: String, patch: KanbanTaskPatch, includeArchived: Bool = false) async throws -> KanbanTask? {
        guard let service else {
            let error = KanbanServiceError.invalidResponse("Kanban is not connected.")
            mutationErrorMessage = error.localizedDescription
            throw error
        }
        return try await performMutation(includeArchived: includeArchived) {
            if let status = patch.status, !KanbanStatusPresentation.canSelectManually(status) {
                throw KanbanServiceError.invalidManualStatus(status)
            }
            let task = try await service.updateTask(id: id, board: self.effectiveBoardSlug, patch: patch)
            await service.nudgeDispatcher(board: self.effectiveBoardSlug)
            return task
        }
    }

    func deleteTask(id: String, includeArchived: Bool = false) async throws {
        guard let service else {
            let error = KanbanServiceError.invalidResponse("Kanban is not connected.")
            mutationErrorMessage = error.localizedDescription
            throw error
        }
        try await performMutation(includeArchived: includeArchived) {
            try await service.deleteTask(id: id, board: self.effectiveBoardSlug)
            await service.nudgeDispatcher(board: self.effectiveBoardSlug)
        }
    }

    func addComment(taskID: String, body: String) async throws {
        guard let service else {
            let error = KanbanServiceError.invalidResponse("Kanban is not connected.")
            mutationErrorMessage = error.localizedDescription
            throw error
        }
        try await performMutation(includeArchived: false) {
            try await service.addComment(taskID: taskID, board: self.effectiveBoardSlug, body: body)
        }
    }

    func reassignTask(taskID: String, profile: String?, reclaimFirst: Bool = true) async throws {
        guard let service else {
            let error = KanbanServiceError.invalidResponse("Kanban is not connected.")
            mutationErrorMessage = error.localizedDescription
            throw error
        }
        try await performMutation(includeArchived: false) {
            try await service.reassignTask(taskID: taskID, board: self.effectiveBoardSlug, profile: profile, reclaimFirst: reclaimFirst)
            await service.nudgeDispatcher(board: self.effectiveBoardSlug)
        }
    }

    func reclaimTask(taskID: String, reason: String? = nil) async throws {
        guard let service else {
            let error = KanbanServiceError.invalidResponse("Kanban is not connected.")
            mutationErrorMessage = error.localizedDescription
            throw error
        }
        try await performMutation(includeArchived: false) {
            try await service.reclaimTask(taskID: taskID, board: self.effectiveBoardSlug, reason: reason)
            await service.nudgeDispatcher(board: self.effectiveBoardSlug)
        }
    }

    func clearMutationError() {
        mutationErrorMessage = nil
    }

    func showMutationError(_ error: Error) {
        mutationErrorMessage = error.localizedDescription
    }

    // MARK: - Mutation state

    private func performMutation<T>(includeArchived: Bool, operation: () async throws -> T) async throws -> T {
        guard !isMutating else {
            let error = KanbanServiceError.mutationInProgress
            mutationErrorMessage = error.localizedDescription
            throw error
        }
        isMutating = true
        mutationErrorMessage = nil
        do {
            let result = try await operation()
            isMutating = false
            await reload(includeArchived: includeArchived)
            return result
        } catch {
            isMutating = false
            await reload(includeArchived: includeArchived)
            mutationErrorMessage = error.localizedDescription
            throw error
        }
    }


    private static func scopeToken(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
