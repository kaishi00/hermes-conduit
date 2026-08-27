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
    static let maxUnconfirmedPendingDecisionAge: TimeInterval = 24 * 60 * 60

    /// Returns whether a clarification or approval presentation still needs a
    /// user decision. Keep this rule shared by resume pruning and cache saves.
    static func isPendingDecision(_ status: ClarifyActivity.Status) -> Bool {
        status == .pending || status == .submitting
    }

    static func isPendingDecision(_ status: ApprovalActivity.Status) -> Bool {
        status == .pending || status == .submitting
    }

    /// Stable identity for a decision card, regardless of whether it is still
    /// pending. This lets resume reconciliation recognize a resolved gateway
    /// row and suppress a matching locally cached card.
    static func decisionKey(for message: ChatMessage) -> String? {
        if let clarify = message.clarify {
            return "clarify:\(clarify.requestId)"
        }
        if let approval = message.approval {
            return "approval:\(approval.sessionId)"
        }
        return nil
    }

    static func pendingDecisionKey(for message: ChatMessage) -> String? {
        if let clarify = message.clarify, isPendingDecision(clarify.status) {
            return "clarify:\(clarify.requestId)"
        }
        if let approval = message.approval, isPendingDecision(approval.status) {
            return "approval:\(approval.sessionId)"
        }
        return nil
    }

    static func pendingDecisionKeys(in messages: [ChatMessage]) -> Set<String> {
        Set(messages.compactMap(pendingDecisionKey(for:)))
    }

    /// Removes only the selected pending decision presentations. Completed
    /// decision metadata and unrelated pending cards remain untouched.
    static func removingPendingDecisionPresentation(
        from messages: [ChatMessage],
        matching keys: Set<String>
    ) -> [ChatMessage] {
        messages.compactMap { original in
            var message = original
            if let clarify = message.clarify,
               isPendingDecision(clarify.status),
               keys.contains("clarify:\(clarify.requestId)") {
                message.clarify = nil
            }
            if let approval = message.approval,
               isPendingDecision(approval.status),
               keys.contains("approval:\(approval.sessionId)") {
                message.approval = nil
            }
            if message.role == .clarify, message.clarify == nil { return nil }
            if message.role == .approval, message.approval == nil { return nil }
            return message
        }
    }

    private struct CachedMessage: Codable, Equatable {
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
        var unconfirmedPendingDecisionAt: Date?
    }

    /// A resume without explicit active-turn confirmation is inherently
    /// ambiguous for pending decisions. Keep an unconfirmed decision across a
    /// cold launch for a bounded grace period, then prefer a stale-card miss
    /// over making an old request answerable forever.
    private let defaults: UserDefaults
    private let now: () -> Date
    private let storageKey = "conduit.sessionPresentation.v1"
    private let maxSessions = 32
    private let maxMessagesPerSession = 320

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
    }

    func unconfirmedPendingDecisionDate(
        profile: String,
        sessionIDs: [String]
    ) -> Date? {
        let stored = load()
        return sessionIDs
            .compactMap { stored[key(profile: profile, sessionID: $0)]?.unconfirmedPendingDecisionAt }
            .min()
    }

    func isUnconfirmedPendingDecisionExpired(since date: Date?) -> Bool {
        guard let date else { return false }
        return now().timeIntervalSince(date) > Self.maxUnconfirmedPendingDecisionAge
    }

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
        let stored = load()
        // Resolve every supplied alias, but let each LOGICAL cached snapshot
        // enter the matching pool exactly once. save(...sessionIDs:) writes
        // equivalent records under every alias, so a requested+resolved
        // lookup used to flatten the same rows twice and the matcher could
        // consume stale duplicates as though they were distinct historical
        // messages (fingerprint and positional scoring especially). Aliases
        // are resolved in supplied order; when several aliases hold the same
        // logical snapshot — including one rewritten later with only fresh
        // presentation stamps — the freshest write wins.
        //
        // Ordering contract (review-gate W1): DIVERGENT snapshots that
        // outscore equally tie-break by earliest pool position, which is
        // this call's argument order. The sole production caller passes
        // [resolvedId, requestedId] so the live write leads; keep callers
        // passing the most-current alias first.
        var resolutionOrder: [String] = []
        var snapshotByID: [String: CachedSession] = [:]
        var seenCacheKeys = Set<String>()
        for rawSessionID in sessionIDs {
            let trimmed = rawSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard seenCacheKeys.insert(trimmed).inserted else { continue }
            guard let session = stored[
                key(profile: profile, sessionID: trimmed)
            ] else { continue }
            let identity = Self.logicalSnapshotIdentity(for: session.messages)
            if let existing = snapshotByID[identity] {
                let isFresher =
                    session.updatedAt == existing.updatedAt
                    ? session.messages.count > existing.messages.count
                    : session.updatedAt > existing.updatedAt
                if isFresher {
                    snapshotByID[identity] = session
                }
            } else {
                resolutionOrder.append(identity)
                snapshotByID[identity] = session
            }
        }
        let cached = resolutionOrder.compactMap { snapshotByID[$0] }
            .flatMap { session -> [CachedMessage] in
                let unconfirmedExpired = isUnconfirmedPendingDecisionExpired(
                    since: session.unconfirmedPendingDecisionAt
                )
                return unconfirmedExpired
                    ? removingPendingDecisionPresentation(from: session.messages)
                    : session.messages
            }
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

            if message.clarify == nil,
               let cachedClarify = presentation.clarify,
               !Self.isPendingDecision(cachedClarify.status) || includePendingClarifications {
                message.clarify = cachedClarify
            }

            if message.approval == nil,
               let cachedApproval = presentation.approval,
               !Self.isPendingDecision(cachedApproval.status) || includePendingApprovals {
                message.approval = cachedApproval
            }

            return message
        }

        if includePendingClarifications {
            let pendingClarifications = cached.compactMap(\.clarify).filter {
                Self.isPendingDecision($0.status)
            }

            // A gateway resume can retain the preceding transcript or generic
            // clarify tool call but omit the one-shot clarify.request event.
            // Restore the locally observed card while it remains unresolved,
            // and hide that duplicate generic tool row behind the answerable
            // clarification UI.
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
                Self.isPendingDecision($0.status)
            }
            for approval in pendingApprovals where !merged.contains(where: {
                $0.approval?.sessionId == approval.sessionId
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

    /// Pending decision keys currently held in the store for the given
    /// sessions, regardless of what the live in-memory transcript contains.
    /// A presentation-cache flush rebuilds its records from the in-memory
    /// transcript, so without this a flush for a session whose store holds a
    /// push-recorded card (`recordPendingDecision`) would silently drop that
    /// card — most notably the open-from-notification path, which records and
    /// then immediately flushes when the notified session is already active.
    func storedPendingDecisionKeys(
        profile: String,
        sessionIDs: [String]
    ) -> Set<String> {
        let stored = load()
        let keys = sessionIDs
            .compactMap { stored[key(profile: profile, sessionID: $0)] }
            .flatMap { session in session.messages.compactMap(pendingDecisionKey(for:)) }
        return Set(keys)
    }

    /// Evicts a still-pending decision record from the cache. Used when a
    /// live event supersedes a push-delivered card: the two carry different
    /// decision keys (gateway vs plugin-minted ids), so the merge can never
    /// dedupe them, and without eviction the superseded card would resurface
    /// as a duplicate answerable card after the next cold-start resume.
    /// Non-pending records and unrelated cards are untouched.
    func removePendingDecision(
        key targetKey: String,
        profile: String,
        sessionIDs: [String]
    ) {
        let ids = Set(sessionIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !ids.isEmpty else { return }
        var store = load()
        var changed = false
        for id in ids {
            let cacheKey = key(profile: profile, sessionID: id)
            guard var session = store[cacheKey] else { continue }
            let before = session.messages
            session.messages.removeAll { existing in
                decisionKey(for: existing) == targetKey && pendingDecisionKey(for: existing) != nil
            }
            guard session.messages != before else { continue }
            session.updatedAt = now()
            store[cacheKey] = session
            changed = true
        }
        guard changed else { return }
        persist(store)
    }

    /// Records a pending decision card observed outside the live stream —
    /// today, from a push notification's structured payload, which is the only
    /// source for a decision raised while the app was backgrounded and missed
    /// the one-shot gateway event. Upserts the single card into whatever is
    /// already cached for each session (the transcript is otherwise the
    /// gateway's source of truth), dedupes by decision key, and stamps the
    /// bounded unconfirmed marker so a stale card expires rather than
    /// lingering. `merge(includePendingApprovals:)` restores it on resume.
    func recordPendingDecision(
        _ message: ChatMessage,
        profile: String,
        sessionIDs: [String]
    ) {
        guard Self.pendingDecisionKey(for: message) != nil,
              let targetKey = Self.decisionKey(for: message) else { return }
        let ids = Set(sessionIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !ids.isEmpty else { return }

        var store = load()
        let record = CachedMessage(message)
        let stampedAt = now()
        var changed = false
        for id in ids {
            let cacheKey = key(profile: profile, sessionID: id)
            var session = store[cacheKey] ?? CachedSession(
                updatedAt: stampedAt,
                messages: [],
                unconfirmedPendingDecisionAt: nil
            )
            // Replace any prior card for this exact decision, then append the
            // fresh one. Other cached rows (the transcript) are untouched.
            session.messages.removeAll { existing in
                decisionKey(for: existing) == targetKey
            }
            session.messages.append(record)
            // Restart the bounded unconfirmed window from this observation.
            // The marker is per session, and expiry strips every pending card
            // in the session at once, so preserving an old marker would let a
            // near-24h stamp immediately expire a decision that just arrived.
            // (The card is also written under each session identity; an
            // answered card can linger under an identity the answer flow did
            // not update, but this same bounded window retires that copy.)
            session.unconfirmedPendingDecisionAt = stampedAt
            session.updatedAt = stampedAt
            store[cacheKey] = session
            changed = true
        }
        guard changed else { return }
        trim(&store)
        persist(store)
    }

    func save(
        _ messages: [ChatMessage],
        profile: String,
        sessionIDs: [String],
        preservePendingDecisionCards: Bool = true,
        unconfirmedPendingDecisionKeys: Set<String> = []
    ) {
        let ids = Set(sessionIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !ids.isEmpty else { return }

        var store = load()
        let freshRecords = messages.suffix(maxMessagesPerSession).map { CachedMessage($0) }
        guard !freshRecords.isEmpty else {
            guard !preservePendingDecisionCards || !unconfirmedPendingDecisionKeys.isEmpty else { return }
            var changed = false
            for id in ids {
                let cacheKey = key(profile: profile, sessionID: id)
                guard var session = store[cacheKey] else { continue }
                let pruned = removingPendingDecisionPresentation(
                    from: session.messages,
                    preserving: unconfirmedPendingDecisionKeys
                )
                let unconfirmedAt = unconfirmedPendingDecisionKeys.isEmpty
                    ? nil
                    : (session.unconfirmedPendingDecisionAt ?? now())
                guard pruned != session.messages || unconfirmedAt != session.unconfirmedPendingDecisionAt else {
                    continue
                }
                session.messages = pruned
                session.unconfirmedPendingDecisionAt = unconfirmedAt
                store[cacheKey] = session
                changed = true
            }
            if changed { persist(store) }
            return
        }
        let existingRecords = ids.lazy
            .compactMap { store[self.key(profile: profile, sessionID: $0)]?.messages }
            .first ?? []
        var records = preservingPresentation(
            in: freshRecords,
            from: existingRecords,
            preservePendingDecisionCards: preservePendingDecisionCards
        )
        appendUnconfirmedPendingDecisionRecords(
            to: &records,
            from: existingRecords,
            matching: unconfirmedPendingDecisionKeys
        )
        if !preservePendingDecisionCards {
            records = removingPendingDecisionPresentation(
                from: records,
                preserving: unconfirmedPendingDecisionKeys
            )
        }
        let existingUnconfirmedAt = ids.lazy
            .compactMap { store[self.key(profile: profile, sessionID: $0)]?.unconfirmedPendingDecisionAt }
            .first
        let unconfirmedAt = unconfirmedPendingDecisionKeys.isEmpty
            ? nil
            : (existingUnconfirmedAt ?? now())
        let session = CachedSession(
            updatedAt: now(),
            messages: records,
            unconfirmedPendingDecisionAt: unconfirmedAt
        )
        for id in ids {
            store[key(profile: profile, sessionID: id)] = session
        }
        trim(&store)
        persist(store)
    }

    /// A resume without an explicit active-turn signal may temporarily show a
    /// locally restored decision card, but that card is not authoritative
    /// enough to keep writing to disk. Strip only pending/submitting decision
    /// presentation while preserving normal transcript metadata.
    private func removingPendingDecisionPresentation(
        from messages: [CachedMessage],
        preserving keys: Set<String> = []
    ) -> [CachedMessage] {
        messages.compactMap { original in
            var message = original
            if let clarify = message.clarify,
               Self.isPendingDecision(clarify.status),
               !keys.contains("clarify:\(clarify.requestId)") {
                message.clarify = nil
            }
            if let approval = message.approval,
               Self.isPendingDecision(approval.status),
               !keys.contains("approval:\(approval.sessionId)") {
                message.approval = nil
            }
            if message.role == .clarify, message.clarify == nil { return nil }
            if message.role == .approval, message.approval == nil { return nil }
            return message
        }
    }

    private func decisionKey(for message: CachedMessage) -> String? {
        if let clarify = message.clarify {
            return "clarify:\(clarify.requestId)"
        }
        if let approval = message.approval {
            return "approval:\(approval.sessionId)"
        }
        return nil
    }

    private func pendingDecisionKey(for message: CachedMessage) -> String? {
        if let clarify = message.clarify, Self.isPendingDecision(clarify.status) {
            return "clarify:\(clarify.requestId)"
        }
        if let approval = message.approval, Self.isPendingDecision(approval.status) {
            return "approval:\(approval.sessionId)"
        }
        return nil
    }

    private func appendUnconfirmedPendingDecisionRecords(
        to records: inout [CachedMessage],
        from existing: [CachedMessage],
        matching keys: Set<String>
    ) {
        guard !keys.isEmpty else { return }
        var existingRecordKeys = Set(records.compactMap(decisionKey(for:)))
        for record in existing {
            guard let pendingKey = pendingDecisionKey(for: record),
                  keys.contains(pendingKey),
                  let recordKey = decisionKey(for: record),
                  !existingRecordKeys.contains(recordKey) else {
                continue
            }
            records.append(record)
            existingRecordKeys.insert(recordKey)
        }
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
        var bestIndex: Int?
        var bestScore = Int.min
        // Scan candidates in ascending pool order and keep the FIRST highest
        // score. Equal-scoring rows (repeated content, repeated tool calls)
        // must resolve deterministically to the earliest row; iterating the
        // `remaining` set unordered made enrichment order arbitrary.
        for index in remaining.sorted() {
            let candidate = cached[index]
            guard candidate.role == message.role else { continue }
            var score = Int.min

            if candidate.id == message.id {
                // Absolute maximum; no later candidate can outrank it.
                return index
            } else if let tool = message.tool {
                guard candidate.toolName == normalized(tool.name) else { continue }
                score = 50
                if let input = tool.input, candidate.toolInputSignature == Self.fingerprint(input) { score += 30 }
                if let output = tool.output, candidate.toolOutputSignature == Self.fingerprint(output) { score += 30 }
                if (tool.input ?? "").isEmpty, candidate.toolPreview?.isEmpty == false { score += 5 }
            } else if candidate.signature == Self.fingerprint(message.content) {
                score = 100
            } else {
                // Hermes can re-render a completed response before placing it in
                // history. The text may therefore differ even though it is the
                // same chronological row. This is only a fallback for missing
                // presentation metadata within the same bounded session cache.
                let distance = abs(index - preferredPosition)
                guard distance <= 3,
                      !candidate.timestamp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                score = 20 - distance
            }

            // Strict > : the first highest-scoring candidate in ascending
            // index order wins the tie, never arbitrary Set iteration order.
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        return bestIndex
    }

    /// Never replace a cached timestamp/preview with a newer history record
    /// that simply omits it. Exact content wins; matching row position is only
    /// used when Hermes has re-rendered the response text.
    private func preservingPresentation(
        in fresh: [CachedMessage],
        from existing: [CachedMessage],
        preservePendingDecisionCards: Bool
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
            if merged.clarify == nil,
               let priorClarify = prior.clarify,
               !Self.isPendingDecision(priorClarify.status) || preservePendingDecisionCards {
                merged.clarify = prior.clarify
            }
            if merged.approval == nil,
               let priorApproval = prior.approval,
               !Self.isPendingDecision(priorApproval.status) || preservePendingDecisionCards {
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

    /// Stable logical identity of one cached snapshot: the (role, id,
    /// content-signature) sequence of its rows. Deliberately EXCLUDES
    /// volatile presentation stamps (timestamps, tool previews) so a
    /// re-stamped rewrite of the same transcript through another alias is
    /// recognized as the same snapshot and deduplicated to its freshest
    /// write — while snapshots whose rows genuinely differ keep separate
    /// identities and all stay available to the matcher. Identity is
    /// value-derived; two records collapse only when their entire row
    /// sequences agree structurally.
    private static func logicalSnapshotIdentity(
        for messages: [CachedMessage]
    ) -> String {
        // Review-gate W2: encode the row matrix as JSON before fingerprinting
        // so no separator/field content can ever alias two structurally
        // different sequences onto one identity.
        let rowIdentity = messages.map { message -> [String] in
            [
                String(describing: message.role),
                message.id,
                message.signature,
                message.toolName ?? ""
            ]
        }
        guard let data = try? JSONEncoder().encode(rowIdentity) else {
            // Encoding cannot fail for [ [String] ]; failing open can only
            // ever ADD a candidate, never silently drop a real one.
            return UUID().uuidString
        }
        return fingerprint(String(decoding: data, as: UTF8.self))
    }
}
