import Foundation

@MainActor
protocol DashboardJSONRequester: AnyObject {
    func requestJSON(
        path: String,
        method: String,
        body: [String: Any]?,
        timeoutMilliseconds: Int,
        maxResponseBytes: Int
    ) async throws -> [String: Any]
}

extension DashboardTicketBridge: DashboardJSONRequester {}

enum KanbanServiceError: LocalizedError, Equatable {
    case invalidResponse(String)
    case emptyTaskID

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let message): return message
        case .emptyTaskID: return "Hermes returned a Kanban task without an ID."
        }
    }
}

/// Typed client for the authenticated Hermes dashboard Kanban plugin.
/// This depends on the existing dashboard request bridge rather than HermesClient.
/// Board selection is always sent as a local board query and never changes the
/// server-wide current-board pointer.
@MainActor
final class KanbanService {
    private let requester: any DashboardJSONRequester
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private static let namespace = "/api/plugins/kanban"

    init(requester: any DashboardJSONRequester) {
        self.requester = requester
        decoder = JSONDecoder()
        encoder = JSONEncoder()
    }

    func fetchBoards() async throws -> KanbanBoardsResponse {
        try await decode(KanbanBoardsResponse.self, path: Self.namespace + "/boards")
    }

    func fetchBoard(slug: String?, includeArchived: Bool) async throws -> KanbanBoard {
        var params: [String: String] = [:]
        if includeArchived { params["include_archived"] = "true" }
        return try await decode(
            KanbanBoard.self,
            path: withBoard(Self.namespace + "/board", slug: slug, params: params)
        )
    }

    func fetchTask(id: String, board: String?) async throws -> KanbanTaskDetail {
        guard !id.isEmpty else { throw KanbanServiceError.emptyTaskID }
        return try await decode(
            KanbanTaskDetail.self,
            path: withBoard(Self.namespace + "/tasks/\(pathComponent(id))", slug: board)
        )
    }

    func fetchTaskLog(id: String, board: String?, tailBytes: Int = 16_384) async throws -> KanbanWorkerLog {
        guard !id.isEmpty else { throw KanbanServiceError.emptyTaskID }
        return try await decode(
            KanbanWorkerLog.self,
            path: withBoard(Self.namespace + "/tasks/\(pathComponent(id))/log", slug: board, params: ["tail": String(max(1, tailBytes))])
        )
    }

    func fetchProfiles() async throws -> [KanbanProfile] {
        let response = try await decode(KanbanProfilesResponse.self, path: Self.namespace + "/profiles")
        return response.profiles
    }

    func fetchProjects() async throws -> [KanbanProject] {
        let response = try await decode(KanbanProjectsResponse.self, path: Self.namespace + "/projects")
        return response.projects
    }

    func fetchOrchestration() async throws -> KanbanOrchestrationSettings {
        try await decode(KanbanOrchestrationSettings.self, path: Self.namespace + "/orchestration")
    }

    func createTask(_ requestBody: KanbanCreateTaskRequest, board: String?) async throws -> KanbanCreateTaskResponse {
        let response = try await request(
            path: withBoard(Self.namespace + "/tasks", slug: board),
            method: "POST",
            body: try encodedDictionary(requestBody)
        )
        return try decodeResponse(KanbanCreateTaskResponse.self, from: response)
    }

    @discardableResult
    func updateTask(id: String, board: String?, patch: KanbanTaskPatch) async throws -> KanbanTask? {
        guard !id.isEmpty else { throw KanbanServiceError.emptyTaskID }
        let response = try await request(
            path: withBoard(Self.namespace + "/tasks/\(pathComponent(id))", slug: board),
            method: "PATCH",
            body: try encodedDictionary(patch)
        )
        return try decodeResponse(TaskEnvelope.self, from: response).task
    }

    func deleteTask(id: String, board: String?) async throws {
        guard !id.isEmpty else { throw KanbanServiceError.emptyTaskID }
        _ = try await request(
            path: withBoard(Self.namespace + "/tasks/\(pathComponent(id))", slug: board),
            method: "DELETE",
            body: nil
        )
    }

    func addComment(taskID: String, board: String?, body: String, author: String = "conduit") async throws {
        guard !taskID.isEmpty else { throw KanbanServiceError.emptyTaskID }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try await request(
            path: withBoard(Self.namespace + "/tasks/\(pathComponent(taskID))/comments", slug: board),
            method: "POST",
            body: try encodedDictionary(KanbanCommentRequest(author: author, body: trimmed))
        )
    }

    func reassignTask(taskID: String, board: String?, profile: String?, reclaimFirst: Bool = true, reason: String? = nil) async throws {
        guard !taskID.isEmpty else { throw KanbanServiceError.emptyTaskID }
        _ = try await request(
            path: withBoard(Self.namespace + "/tasks/\(pathComponent(taskID))/reassign", slug: board),
            method: "POST",
            body: try encodedDictionary(KanbanReassignRequest(profile: profile, reclaimFirst: reclaimFirst, reason: reason))
        )
    }

    func reclaimTask(taskID: String, board: String?, reason: String? = nil) async throws {
        guard !taskID.isEmpty else { throw KanbanServiceError.emptyTaskID }
        _ = try await request(
            path: withBoard(Self.namespace + "/tasks/\(pathComponent(taskID))/reclaim", slug: board),
            method: "POST",
            body: try encodedDictionary(KanbanReclaimRequest(reason: reason))
        )
    }

    func createBoard(slug: String, name: String, projectID: String? = nil) async throws -> KanbanBoardMetadata {
        struct Body: Encodable {
            let slug: String
            let name: String
            let projectID: String?
            enum CodingKeys: String, CodingKey { case slug, name; case projectID = "project_id" }
        }
        let response = try await request(
            path: Self.namespace + "/boards",
            method: "POST",
            body: try encodedDictionary(Body(slug: slug, name: name, projectID: projectID))
        )
        return try decodeResponse(BoardEnvelope.self, from: response).board
    }

    func updateBoard(slug: String, name: String?, description: String?, defaultWorkdir: String?) async throws -> KanbanBoardMetadata {
        struct Body: Encodable {
            let name: String?
            let description: String?
            let defaultWorkdir: String?
            enum CodingKeys: String, CodingKey {
                case name, description
                case defaultWorkdir = "default_workdir"
            }
        }
        let response = try await request(
            path: Self.namespace + "/boards/\(pathComponent(slug))",
            method: "PATCH",
            body: try encodedDictionary(Body(name: name, description: description, defaultWorkdir: defaultWorkdir))
        )
        return try decodeResponse(BoardEnvelope.self, from: response).board
    }

    // MARK: - Transport helpers

    private func decode<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        let response = try await request(path: path, method: "GET", body: nil)
        return try decodeResponse(type, from: response)
    }

    private func request(path: String, method: String, body: [String: Any]?) async throws -> [String: Any] {
        try await requester.requestJSON(
            path: path,
            method: method,
            body: body,
            timeoutMilliseconds: 20_000,
            maxResponseBytes: DataURLLimits.maxJSONResponseBytes
        )
    }

    private func decodeResponse<T: Decodable>(_ type: T.Type, from response: [String: Any]) throws -> T {
        guard JSONSerialization.isValidJSONObject(response), let data = try? JSONSerialization.data(withJSONObject: response) else {
            throw KanbanServiceError.invalidResponse("Hermes returned an unreadable Kanban response.")
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw KanbanServiceError.invalidResponse("Hermes returned an unexpected Kanban response: \(error.localizedDescription)")
        }
    }

    private func encodedDictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try encoder.encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KanbanServiceError.invalidResponse("Could not encode the Kanban request.")
        }
        return object
    }

    private func withBoard(_ path: String, slug: String?, params: [String: String] = [:]) -> String {
        var values = params
        if let slug, !slug.isEmpty { values["board"] = slug }
        guard !values.isEmpty else { return path }
        let query = values.keys.sorted().compactMap { key -> String? in
            guard let encodedValue = DashboardPath.encodedQueryComponent(values[key] ?? "") else { return nil }
            return "\(key)=\(encodedValue)"
        }.joined(separator: "&")
        return query.isEmpty ? path : "\(path)?\(query)"
    }

    private func pathComponent(_ value: String) -> String {
        DashboardPath.encodedQueryComponent(value) ?? value
    }

    private struct TaskEnvelope: Decodable { let task: KanbanTask? }
    private struct BoardEnvelope: Decodable { let board: KanbanBoardMetadata }
}
