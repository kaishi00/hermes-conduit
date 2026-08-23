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
    case invalidManualStatus(String)
    case taskCreatedButMoveFailed(taskID: String?, targetStatus: String, reason: String)
    case mutationInProgress
    case boardNavigationInProgress
    case invalidQueryParameter(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let message): return message
        case .emptyTaskID: return "Hermes returned a Kanban task without an ID."
        case .invalidManualStatus(let status):
            if status == "running" {
                return "Hermes controls Running; use the dispatcher/claim path instead of setting it manually."
            }
            return "Hermes does not allow " + status + " as a manual Kanban destination."
        case .taskCreatedButMoveFailed(let taskID, let targetStatus, let reason):
            let identifier = taskID.map { " (task " + $0 + ")" } ?? ""
            return "The task was created" + identifier + ", but Hermes could not move it to " + targetStatus + ". It was not duplicated; close this form and refresh the board. " + reason
        case .mutationInProgress:
            return "Another Kanban change is still being saved."
        case .boardNavigationInProgress:
            return "Still switching boards. Try again once the new board finishes loading."
        case .invalidQueryParameter(let name):
            // Fail closed: a dropped board/id parameter would silently
            // retarget the request at the backend's current board.
            return "Could not build a safe Hermes Kanban request (invalid " + name + "). The operation was cancelled before any data changed."
        }
    }
}

/// Typed client for the authenticated Hermes dashboard Kanban plugin.
///
/// This depends on the existing dashboard request bridge rather than
/// HermesClient. Board selection is always sent as a local board query and
/// never changes the server-wide current-board pointer.
///
/// Profiles: Hermes Kanban is intentionally a SHARED, cross-profile board.
/// hermes_cli/kanban_db.py anchors boards at the shared Hermes root - when
/// HERMES_HOME is <root>/profiles/<name>, paths resolve back through
/// get_default_hermes_root() so every profile joins the same dispatch bus by
/// design. There is therefore nothing profile-scoped to request: this service
/// deliberately sends no profile query parameter, and switching Conduit's UI
/// profile must not reload or re-scope Kanban.
@MainActor
final class KanbanService {
    private let requester: any DashboardJSONRequester
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private static let namespace = "/api/plugins/kanban"
    /// Mirrors upstream's 400 ms dispatcher-nudge debounce (api.ts autoNudge).
    static let dispatcherNudgeDebounceNanoseconds: UInt64 = 400_000_000
    private let nudgeDebounceIntervalNanoseconds: UInt64
    private var pendingDispatcherNudge: Task<Void, Never>?

    init(
        requester: any DashboardJSONRequester,
        nudgeDebounceNanoseconds: UInt64 = KanbanService.dispatcherNudgeDebounceNanoseconds
    ) {
        self.requester = requester
        self.nudgeDebounceIntervalNanoseconds = max(1, nudgeDebounceNanoseconds)
        decoder = JSONDecoder()
        encoder = JSONEncoder()
    }

    func fetchBoards() async throws -> KanbanBoardsResponse {
        try await decode(KanbanBoardsResponse.self, path: scoped(Self.namespace + "/boards"))
    }

    func fetchBoard(slug: String?, includeArchived: Bool) async throws -> KanbanBoard {
        var params: [String: String] = [:]
        if includeArchived { params["include_archived"] = "true" }
        return try await decode(
            KanbanBoard.self,
            path: try withBoard(Self.namespace + "/board", slug: slug, params: params)
        )
    }

    func fetchTask(id: String, board: String?) async throws -> KanbanTaskDetail {
        guard !id.isEmpty else { throw KanbanServiceError.emptyTaskID }
        return try await decode(
            KanbanTaskDetail.self,
            path: try withBoard(Self.namespace + "/tasks/" + (try pathComponent(id)), slug: board)
        )
    }

    func fetchTaskLog(id: String, board: String?, tailBytes: Int = 16_384) async throws -> KanbanWorkerLog {
        guard !id.isEmpty else { throw KanbanServiceError.emptyTaskID }
        return try await decode(
            KanbanWorkerLog.self,
            path: try withBoard(Self.namespace + "/tasks/" + (try pathComponent(id)) + "/log", slug: board, params: ["tail": String(max(1, tailBytes))])
        )
    }

    func fetchProfiles() async throws -> [KanbanProfile] {
        let response = try await decode(KanbanProfilesResponse.self, path: scoped(Self.namespace + "/profiles"))
        return response.profiles
    }

    func fetchProjects() async throws -> [KanbanProject] {
        let response = try await decode(KanbanProjectsResponse.self, path: scoped(Self.namespace + "/projects"))
        return response.projects
    }

    func fetchOrchestration() async throws -> KanbanOrchestrationSettings {
        try await decode(KanbanOrchestrationSettings.self, path: scoped(Self.namespace + "/orchestration"))
    }

    /// Backend-curated provider/model roster for per-task overrides
    /// (`GET /model-options`). Board-independent, so no board query is sent.
    /// Unusable rows (empty slug or no models — e.g. a degraded inventory
    /// payload) are dropped here so every caller sees an offerable catalog.
    func fetchModelOptions() async throws -> [KanbanModelProviderOption] {
        let response = try await decode(KanbanModelOptionsResponse.self, path: scoped(Self.namespace + "/model-options"))
        return response.providers.filter { !$0.slug.isEmpty && !$0.models.isEmpty }
    }

    func createTask(_ requestBody: KanbanCreateTaskRequest, board: String?) async throws -> KanbanCreateTaskResponse {
        let response = try await request(
            path: try withBoard(Self.namespace + "/tasks", slug: board),
            method: "POST",
            body: try encodedDictionary(requestBody)
        )
        return try decodeResponse(KanbanCreateTaskResponse.self, from: response)
    }

    @discardableResult
    func updateTask(id: String, board: String?, patch: KanbanTaskPatch) async throws -> KanbanTask? {
        guard !id.isEmpty else { throw KanbanServiceError.emptyTaskID }
        let response = try await request(
            path: try withBoard(Self.namespace + "/tasks/" + (try pathComponent(id)), slug: board),
            method: "PATCH",
            body: try encodedDictionary(patch)
        )
        return try decodeResponse(TaskEnvelope.self, from: response).task
    }

    func deleteTask(id: String, board: String?) async throws {
        guard !id.isEmpty else { throw KanbanServiceError.emptyTaskID }
        _ = try await request(
            path: try withBoard(Self.namespace + "/tasks/" + (try pathComponent(id)), slug: board),
            method: "DELETE",
            body: nil
        )
    }

    func addComment(taskID: String, board: String?, body: String, author: String = "conduit") async throws {
        guard !taskID.isEmpty else { throw KanbanServiceError.emptyTaskID }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try await request(
            path: try withBoard(Self.namespace + "/tasks/" + (try pathComponent(taskID)) + "/comments", slug: board),
            method: "POST",
            body: try encodedDictionary(KanbanCommentRequest(author: author, body: trimmed))
        )
    }

    func reassignTask(taskID: String, board: String?, profile: String?, reclaimFirst: Bool = true, reason: String? = nil) async throws {
        guard !taskID.isEmpty else { throw KanbanServiceError.emptyTaskID }
        _ = try await request(
            path: try withBoard(Self.namespace + "/tasks/" + (try pathComponent(taskID)) + "/reassign", slug: board),
            method: "POST",
            body: try encodedDictionary(KanbanReassignRequest(profile: profile, reclaimFirst: reclaimFirst, reason: reason))
        )
    }

    func reclaimTask(taskID: String, board: String?, reason: String? = nil) async throws {
        guard !taskID.isEmpty else { throw KanbanServiceError.emptyTaskID }
        _ = try await request(
            path: try withBoard(Self.namespace + "/tasks/" + (try pathComponent(taskID)) + "/reclaim", slug: board),
            method: "POST",
            body: try encodedDictionary(KanbanReclaimRequest(reason: reason))
        )
    }

    // MARK: - Dispatcher nudge

    /// Schedule the upstream-equivalent acceleration hint for the backend
    /// dispatcher. True fire-and-forget: returns immediately (it never blocks
    /// or outlives a mutation's success), coalesces rapid writes onto one
    /// debounced timer, and swallows its own failures - the periodic backend
    /// tick remains the fallback. The board scope is captured now so a later
    /// board switch cannot retarget an already-scheduled nudge.
    func scheduleDispatcherNudge(board: String?) {
        pendingDispatcherNudge?.cancel()
        let capturedBoard = board
        let debounce = nudgeDebounceIntervalNanoseconds
        pendingDispatcherNudge = Task { [weak self] in
            do {
                try? await Task.sleep(nanoseconds: debounce)
                if Task.isCancelled { return }
                guard let self else { return }
                _ = try? await self.request(
                    path: try self.withBoard(Self.namespace + "/dispatch", slug: capturedBoard),
                    method: "POST",
                    body: [:]
                )
            } catch {
                // Dispatch is an acceleration hint, never a mutation dependency.
            }
        }
    }

    /// Test seam: awaits (without cancelling) any in-flight debounced nudge.
    func awaitPendingDispatcherNudgeForTesting() async {
        await pendingDispatcherNudge?.value
        pendingDispatcherNudge = nil
    }

    func createBoard(slug: String, name: String, projectID: String? = nil) async throws -> KanbanBoardMetadata {
        struct Body: Encodable {
            let slug: String
            let name: String
            let projectID: String?
            enum CodingKeys: String, CodingKey { case slug, name; case projectID = "project_id" }
        }
        let response = try await request(
            path: scoped(Self.namespace + "/boards"),
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
            path: scoped(Self.namespace + "/boards/" + (try pathComponent(slug))),
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
            throw KanbanServiceError.invalidResponse("Hermes returned an unexpected Kanban response: " + error.localizedDescription)
        }
    }

    private func encodedDictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try encoder.encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KanbanServiceError.invalidResponse("Could not encode the Kanban request.")
        }
        return object
    }

    private func scoped(_ path: String) -> String {
        // Reserved seam for future request-scoped parameters. Today the plugin
        // API takes no profile/scope query and must stay that way.
        path
    }

    /// Throwing query builder: board scope is data-integrity critical, so an
    /// unencodable parameter fails the request instead of silently vanishing
    /// (which would retarget the call at the backend's current board).
    private func withBoard(_ path: String, slug: String?, params: [String: String] = [:]) throws -> String {
        var values = params
        if let slug, !slug.isEmpty { values["board"] = slug }
        guard !values.isEmpty else { return path }
        let query = try values.keys.sorted().map { key -> String in
            guard let encodedKey = DashboardPath.encodedQueryComponent(key),
                  let encodedValue = DashboardPath.encodedQueryComponent(values[key] ?? "") else {
                throw KanbanServiceError.invalidQueryParameter(key)
            }
            return encodedKey + "=" + encodedValue
        }.joined(separator: "&")
        return query.isEmpty ? path : path + "?" + query
    }

    private func pathComponent(_ value: String) throws -> String {
        // Exact dot segments navigate URL directories: "tasks/.." would
        // normalize onto a parent route while keeping the PATCH/DELETE method.
        guard value != ".", value != ".." else {
            throw KanbanServiceError.invalidQueryParameter(value)
        }
        guard let encoded = DashboardPath.encodedQueryComponent(value), !encoded.isEmpty else {
            throw KanbanServiceError.invalidQueryParameter("id")
        }
        return encoded
    }

    private struct TaskEnvelope: Decodable { let task: KanbanTask? }
    private struct BoardEnvelope: Decodable { let board: KanbanBoardMetadata }
}
