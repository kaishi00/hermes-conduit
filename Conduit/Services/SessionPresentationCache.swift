//
//  SessionPresentationCache.swift
//  Conduit
//
//  Hermes session history is intentionally compact and can omit UI-only
//  fields such as per-message timestamps and a tool's original input. Keep a
//  bounded local presentation cache so reopening a session does not make
//  those fields disappear. The gateway remains the source of truth for the
//  transcript itself.
//

import Foundation

final class SessionPresentationCache {
    static let shared = SessionPresentationCache()

    private struct CachedMessage: Codable {
        var id: String
        var role: MessageRole
        var signature: String
        var timestamp: String
        var toolName: String?
        var toolInputSignature: String?
        var toolOutputSignature: String?
        var toolPreview: String?
        var attachments: [Attachment]?
        var clarify: ClarifyActivity?
        var approval: ApprovalActivity?

        init(_ message: ChatMessage) {
            let tool = message.tool
            let preview = tool.flatMap { tool -> String? in
                let value = tool.input?.isEmpty == false ? tool.input! : (tool.output ?? "")
                let oneLine = value
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return oneLine.isEmpty ? nil : String(oneLine.prefix(600))
            }

            id = message.id
            role = message.role
            signature = SessionPresentationCache.fingerprint(message.content)
            timestamp = message.timestamp
            toolName = tool.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            toolInputSignature = tool?.input.map(SessionPresentationCache.fingerprint)
            toolOutputSignature = tool?.output.map(SessionPresentationCache.fingerprint)
            toolPreview = preview
            attachments = message.attachments
            clarify = message.clarify
            approval = message.approval
        }
    }

    private struct CachedSession: Codable {
        var updatedAt: Date
        var messages: [CachedMessage]
    }

    private let defaults = UserDefaults.standard
    private let storageKey = "conduit.sessionPresentation.v1"
    private let maxSessions = 32
    private let maxMessagesPerSession = 320

    private init() {}

    /// Restores only fields Hermes did not send in its persisted history.
    /// The transcript, message ordering, and any nonempty server value always
    /// remain authoritative.
    func merge(
        _ messages: [ChatMessage],
        profile: String,
        sessionIDs: [String],
        includePendingClarifications: Bool = false,
        includePendingApprovals: Bool = false
    ) -> [ChatMessage] {
        let cached = sessionIDs
            .compactMap { load()[key(profile: profile, sessionID: $0)]?.messages }
            .flatMap { $0 }
        guard !cached.isEmpty else { return messages }

        var remaining = Set(cached.indices)
        var merged = messages.enumerated().map { position, original in
            var message = original
            guard let index = bestMatch(
                for: message,
                in: cached,
                remaining: remaining,
                preferredPosition: position
            ) else {
                return message
            }

            let presentation = cached[index]
            remaining.remove(index)

            if message.timestamp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                message.timestamp = presentation.timestamp
            }

            if var tool = message.tool {
                if (tool.input ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let preview = presentation.toolPreview,
                   !preview.isEmpty {
                    tool.input = preview
                }
                message.tool = tool
            }

            // Image uploads are represented locally by temporary file URLs;
            // Hermes' compact history may only retain an attachment marker.
            // Restore the local reference when available so the outgoing
            // bubble can keep showing the image after reopening this session.
            if message.attachments?.isEmpty != false,
               let cachedAttachments = presentation.attachments,
               !cachedAttachments.isEmpty {
                message.attachments = cachedAttachments
            }

            if message.clarify == nil, let cachedClarify = presentation.clarify {
                message.clarify = cachedClarify
            }

            if message.approval == nil, let cachedApproval = presentation.approval {
                message.approval = cachedApproval
            }

            return message
        }

        if includePendingClarifications {
            let pendingClarifications = cached.compactMap(\.clarify).filter {
                $0.status == .pending || $0.status == .submitting
            }

            // A gateway resume can retain the running clarify tool call but omit
            // the one-shot clarify.request event. Restore the locally observed
            // card only while the session is still running, and hide that duplicate
            // generic tool row behind the answerable clarification UI.
            if !pendingClarifications.isEmpty {
                merged.removeAll { message in
                    message.role == .tool && message.tool?.name.lowercased() == "clarify"
                }
                for clarify in pendingClarifications where !merged.contains(where: {
                    $0.clarify?.requestId == clarify.requestId
                }) {
                    let cachedMessage = cached.first { $0.clarify?.requestId == clarify.requestId }
                    merged.append(ChatMessage(
                        id: cachedMessage?.id ?? "clarify-\(clarify.requestId)",
                        role: .clarify,
                        content: clarify.question,
                        timestamp: cachedMessage?.timestamp ?? "",
                        clarify: clarify
                    ))
                }
            }
        }

        if includePendingApprovals {
            let pendingApprovals = cached.compactMap(\.approval).filter {
                $0.status == .pending || $0.status == .submitting
            }
            for approval in pendingApprovals where !merged.contains(where: {
                $0.approval?.sessionId == approval.sessionId
                    && ($0.approval?.status == .pending || $0.approval?.status == .submitting)
            }) {
                let cachedMessage = cached.last { $0.approval?.sessionId == approval.sessionId }
                merged.append(ChatMessage(
                    id: cachedMessage?.id ?? "approval-\(approval.sessionId)",
                    role: .approval,
                    content: approval.description,
                    timestamp: cachedMessage?.timestamp ?? "",
                    approval: approval
                ))
            }
        }
        return merged
    }

    func save(_ messages: [ChatMessage], profile: String, sessionIDs: [String]) {
        let ids = Set(sessionIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !ids.isEmpty else { return }

        var store = load()
        let freshRecords = messages.suffix(maxMessagesPerSession).map { CachedMessage($0) }
        guard !freshRecords.isEmpty else { return }
        let existingRecords = ids.lazy
            .compactMap { store[self.key(profile: profile, sessionID: $0)]?.messages }
            .first ?? []
        let records = preservingPresentation(in: freshRecords, from: existingRecords)
        let session = CachedSession(updatedAt: Date(), messages: records)
        for id in ids {
            store[key(profile: profile, sessionID: id)] = session
        }
        trim(&store)
        persist(store)
    }

    func clear(profile: String? = nil) {
        guard let profile else {
            defaults.removeObject(forKey: storageKey)
            return
        }

        let prefix = normalized(profile) + "|"
        var store = load()
        store.keys.filter { $0.hasPrefix(prefix) }.forEach { store.removeValue(forKey: $0) }
        persist(store)
    }

    private func load() -> [String: CachedSession] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: CachedSession].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func persist(_ store: [String: CachedSession]) {
        guard let data = try? JSONEncoder().encode(store) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func trim(_ store: inout [String: CachedSession]) {
        guard store.count > maxSessions else { return }
        let keysToRemove = store.sorted { $0.value.updatedAt > $1.value.updatedAt }
            .dropFirst(maxSessions)
            .map(\.key)
        keysToRemove.forEach { store.removeValue(forKey: $0) }
    }

    private func key(profile: String, sessionID: String) -> String {
        normalized(profile) + "|" + sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func bestMatch(
        for message: ChatMessage,
        in cached: [CachedMessage],
        remaining: Set<Int>,
        preferredPosition: Int
    ) -> Int? {
        let ranked = remaining.compactMap { index -> (index: Int, score: Int)? in
            let candidate = cached[index]
            guard candidate.role == message.role else { return nil }

            if candidate.id == message.id { return (index, 1_000) }

            if let tool = message.tool {
                guard candidate.toolName == normalized(tool.name) else { return nil }
                var score = 50
                if let input = tool.input, candidate.toolInputSignature == Self.fingerprint(input) { score += 30 }
                if let output = tool.output, candidate.toolOutputSignature == Self.fingerprint(output) { score += 30 }
                if (tool.input ?? "").isEmpty, candidate.toolPreview?.isEmpty == false { score += 5 }
                return (index, score)
            }

            if candidate.signature == Self.fingerprint(message.content) { return (index, 100) }

            // Hermes can re-render a completed response before placing it in
            // history. The text may therefore differ even though it is the
            // same chronological row. This is only a fallback for missing
            // presentation metadata within the same bounded session cache.
            let distance = abs(index - preferredPosition)
            guard distance <= 3,
                  !candidate.timestamp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return (index, 20 - distance)
        }

        return ranked.max { $0.score < $1.score }?.index
    }

    /// Never replace a cached timestamp/preview with a newer history record
    /// that simply omits it. Exact content wins; matching row position is only
    /// used when Hermes has re-rendered the response text.
    private func preservingPresentation(
        in fresh: [CachedMessage],
        from existing: [CachedMessage]
    ) -> [CachedMessage] {
        fresh.enumerated().map { position, record in
            var merged = record
            let exact = existing.first {
                $0.id == record.id || ($0.role == record.role && $0.signature == record.signature)
            }
            let positional: CachedMessage? = existing.indices.contains(position) && existing[position].role == record.role
                ? existing[position]
                : nil
            guard let prior = exact ?? positional else { return merged }

            if merged.timestamp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                merged.timestamp = prior.timestamp
            }
            if merged.toolPreview?.isEmpty != false {
                merged.toolPreview = prior.toolPreview
            }
            if merged.toolInputSignature == nil {
                merged.toolInputSignature = prior.toolInputSignature
            }
            if merged.toolOutputSignature == nil {
                merged.toolOutputSignature = prior.toolOutputSignature
            }
            if merged.attachments?.isEmpty != false {
                merged.attachments = prior.attachments
            }
            if merged.clarify == nil {
                merged.clarify = prior.clarify
            }
            if merged.approval == nil {
                merged.approval = prior.approval
            }
            return merged
        }
    }

    private static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let normalized = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
