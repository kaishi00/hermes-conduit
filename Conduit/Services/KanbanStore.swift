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
    @Published private(set) var selectedBoardSlug: String
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let defaults: UserDefaults
    private var service: KanbanService?
    private var requesterID: ObjectIdentifier?
    private var loadGeneration = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedBoardSlug = defaults.string(forKey: Self.selectedBoardKey) ?? ""
    }

    var effectiveBoardSlug: String? {
        selectedBoardSlug.isEmpty ? nil : selectedBoardSlug
    }

    var selectedBoardMetadata: KanbanBoardMetadata? {
        let slug = selectedBoardSlug.isEmpty ? currentServerBoardSlug : selectedBoardSlug
        return boards.first(where: { $0.slug == slug })
    }

    func configure(requester: (any DashboardJSONRequester)?) {
        guard let requester else {
            service = nil
            requesterID = nil
            return
        }
        let identity = ObjectIdentifier(requester)
        guard requesterID != identity else { return }
        service = KanbanService(requester: requester)
        requesterID = identity
    }

    func reload(includeArchived: Bool = false) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        guard let service else {
            board = nil
            errorMessage = "Connect to a Hermes dashboard to use Kanban."
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
                defaults.removeObject(forKey: Self.selectedBoardKey)
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
            errorMessage = error.localizedDescription
        }
    }

    func selectBoard(slug: String, includeArchived: Bool = false) async {
        selectedBoardSlug = slug
        if slug.isEmpty {
            defaults.removeObject(forKey: Self.selectedBoardKey)
        } else {
            defaults.set(slug, forKey: Self.selectedBoardKey)
        }
        await reload(includeArchived: includeArchived)
    }

    func refresh(includeArchived: Bool = false) async {
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
    func createTask(_ request: KanbanCreateTaskRequest, includeArchived: Bool = false) async throws -> KanbanTask? {
        guard let service else { throw KanbanServiceError.invalidResponse("Kanban is not connected.") }
        let response = try await service.createTask(request, board: effectiveBoardSlug)
        await reload(includeArchived: includeArchived)
        return response.task
    }

    @discardableResult
    func updateTask(id: String, patch: KanbanTaskPatch, includeArchived: Bool = false) async throws -> KanbanTask? {
        guard let service else { throw KanbanServiceError.invalidResponse("Kanban is not connected.") }
        let task = try await service.updateTask(id: id, board: effectiveBoardSlug, patch: patch)
        await reload(includeArchived: includeArchived)
        return task
    }

    func deleteTask(id: String, includeArchived: Bool = false) async throws {
        guard let service else { throw KanbanServiceError.invalidResponse("Kanban is not connected.") }
        try await service.deleteTask(id: id, board: effectiveBoardSlug)
        await reload(includeArchived: includeArchived)
    }

    func addComment(taskID: String, body: String) async throws {
        guard let service else { throw KanbanServiceError.invalidResponse("Kanban is not connected.") }
        try await service.addComment(taskID: taskID, board: effectiveBoardSlug, body: body)
    }

    func reassignTask(taskID: String, profile: String?, reclaimFirst: Bool = true) async throws {
        guard let service else { throw KanbanServiceError.invalidResponse("Kanban is not connected.") }
        try await service.reassignTask(taskID: taskID, board: effectiveBoardSlug, profile: profile, reclaimFirst: reclaimFirst)
        await reload()
    }

    func reclaimTask(taskID: String, reason: String? = nil) async throws {
        guard let service else { throw KanbanServiceError.invalidResponse("Kanban is not connected.") }
        try await service.reclaimTask(taskID: taskID, board: effectiveBoardSlug, reason: reason)
        await reload()
    }
}
