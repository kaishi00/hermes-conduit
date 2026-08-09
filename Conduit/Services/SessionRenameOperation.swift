import Foundation

@MainActor
enum SessionRenameOperation {
    struct Operations {
        var renameRuntime: ((String, String) async throws -> Void)?
        var renameStored: (String, String) async throws -> Void
    }

    struct ContextChanged: Error {}

    struct Result: Equatable {
        let title: String
        let sessionIDs: [String]

        func matches(_ session: SessionSummary) -> Bool {
            let knownIDs = Set(sessionIDs)
            let candidateIDs = Set([session.id] + session.alternateIds)
            return !knownIDs.isDisjoint(with: candidateIDs)
        }

        func matches(sessionID: String?) -> Bool {
            guard let sessionID else { return false }
            return sessionIDs.contains(sessionID)
        }

        func updating(_ session: SessionSummary) -> SessionSummary {
            guard matches(session) else { return session }
            var updated = session
            updated.title = title
            return updated
        }
    }

    static func normalizedTitle(_ title: String, currentTitle: String) -> String? {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != currentTitle else { return nil }
        return normalized
    }
    static func failureMessage(_ error: Error) -> String {
        "Could not rename this conversation: \(error.localizedDescription)"
    }

    static func perform(
        session: SessionSummary,
        activeSessionID: String?,
        title: String,
        operations: Operations
    ) async throws -> Result? {
        guard let normalized = normalizedTitle(title, currentTitle: session.title) else { return nil }
        let sessionIDs = [session.id] + session.alternateIds
        let runtimeID = activeSessionID.flatMap { sessionIDs.contains($0) ? $0 : nil }

        if let runtimeID, let renameRuntime = operations.renameRuntime {
            do {
                try await renameRuntime(runtimeID, normalized)
                return Result(title: normalized, sessionIDs: sessionIDs)
            } catch {
                // A stored-session PATCH is the supported fallback when the
                // active runtime no longer accepts the title RPC.
            }
        }

        try await operations.renameStored(session.id, normalized)
        return Result(title: normalized, sessionIDs: sessionIDs)
    }
}

@MainActor
final class SessionTitleRecoveryTracker {
    private var tasks: [String: Task<Void, Never>] = [:]
    private var tokens: [String: UUID] = [:]
    private var suppressedKeys = Set<String>()

    func isSuppressed(_ key: String) -> Bool {
        suppressedKeys.contains(key)
    }

    func hasTask(for key: String) -> Bool {
        tasks[key] != nil
    }

    func suppress(_ keys: Set<String>) {
        suppressedKeys.formUnion(keys)
    }

    func unsuppress(_ keys: Set<String>) {
        suppressedKeys.subtract(keys)
    }

    func register(_ task: Task<Void, Never>, token: UUID, for key: String) {
        tokens[key] = token
        tasks[key] = task
    }

    func isCurrent(_ token: UUID, for key: String) -> Bool {
        tokens[key] == token
    }

    func finish(_ token: UUID, for key: String) {
        guard tokens[key] == token else { return }
        tasks.removeValue(forKey: key)
        tokens.removeValue(forKey: key)
    }

    func cancel(_ key: String) {
        tokens.removeValue(forKey: key)
        tasks.removeValue(forKey: key)?.cancel()
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        tokens.removeAll()
    }

    func cancel(_ keys: Set<String>) async {
        let pending = keys.compactMap { key -> Task<Void, Never>? in
            tokens.removeValue(forKey: key)
            return tasks.removeValue(forKey: key)
        }
        pending.forEach { $0.cancel() }
        for task in pending { await task.value }
    }
}
