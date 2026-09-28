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
    /// The app's instance writes to disk off the main thread: every caller
    /// is AppState (main actor), and a full-store encode plus UserDefaults
    /// write used to run there on each streaming flush and turn completion,
    /// a cost that grew with the length of the chat.
    static let shared = SessionPresentationCache(writesAsynchronously: true)
    static let maxUnconfirmedPendingDecisionAge: TimeInterval = 24 * 60 * 60

    /// Returns whether a clarification presentation still needs a user
    /// decision. Keep this rule shared by resume pruning and cache saves. A
    /// retryable `.error` question is still unanswered — it must survive as
    /// an unresolved decision, never be pruned as completed.
    static func isPendingDecision(_ status: ClarifyActivity.Status) -> Bool {
        status == .pending || status == .submitting || status == .error
    }

    static func isPendingDecision(_ status: ApprovalActivity.Status) -> Bool {
        // An errored approval is still retryable (the card re-arms its
        // controls), so it remains an unresolved decision for pruning.
        status == .pending || status == .submitting || status == .error
    }

    /// Stable identity for a decision card, regardless of whether it is still
    /// pending. This lets resume reconciliation recognize a resolved gateway
    /// row and suppress a matching locally cached card.
    static func decisionKey(for message: ChatMessage) -> String? {
        if let clarify = message.clarify {
            return "clarify:\(clarify.requestId)"
        }
        if let approval = message.approval {
            return approval.requestId.map { "approval-request:\($0)" }
                ?? "approval:\(approval.sessionId)"
        }
        return nil
    }

    static func pendingDecisionKey(for message: ChatMessage) -> String? {
        if let clarify = message.clarify, isPendingDecision(clarify.status) {
            return "clarify:\(clarify.requestId)"
        }
        if let approval = message.approval, isPendingDecision(approval.status) {
            return approval.requestId.map { "approval-request:\($0)" }
                ?? "approval:\(approval.sessionId)"
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
               keys.contains(approval.requestId.map { "approval-request:\($0)" }
                    ?? "approval:\(approval.sessionId)") {
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
        var toolDisplayName: String?
        var toolID: String?
        var toolInputSignature: String?
        var toolOutputSignature: String?
        var toolPreview: String?
        var toolStatus: ToolActivity.Status?
        var attachments: [Attachment]?
        var clarify: ClarifyActivity?
        var approval: ApprovalActivity?

        init(_ message: ChatMessage) {
            let tool = message.tool
            let preview = tool.flatMap { tool -> String? in
                let value = tool.input?.isEmpty == false ? tool.input! : (tool.output ?? "")
                let oneLine = SessionPresentationCache.collapsingWhitespace(value)
                return oneLine.isEmpty ? nil : String(oneLine.prefix(600))
            }

            id = message.id
            role = message.role
            signature = SessionPresentationCache.fingerprint(message.content)
            timestamp = message.timestamp
            toolName = tool.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            toolDisplayName = tool?.name
            toolID = tool?.id
            toolInputSignature = tool?.input.map(SessionPresentationCache.fingerprint)
            toolOutputSignature = tool?.output.map(SessionPresentationCache.fingerprint)
            toolPreview = preview
            toolStatus = tool?.status
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
    private let pendingToolsStorageKey = "conduit.sessionPresentation.pendingTools.v1"
    private let tombstonesStorageKey = "conduit.sessionPresentation.tombstones.v1"
    private let maxSessions = 32
    private let maxMessagesPerSession = 320

    /// Decoded copies of the two stores. Every public operation used to
    /// decode the whole JSON blob from UserDefaults (often two or three
    /// times per save); the decoded value is now kept and reused.
    private var memoryStore: [String: CachedSession]?
    private var memoryPendingTools: [String: [CachedMessage]]?
    /// Bytes each memory copy was decoded from or encoded to. In synchronous
    /// mode the copy is reused only while UserDefaults still holds exactly
    /// these bytes, so a write made behind this instance's back (another
    /// instance on the same defaults, a test fixture) is still picked up.
    private var memoryStoreData: Data?
    private var memoryPendingToolsData: Data?
    /// Guards the memory copies above. Today every caller is on the main
    /// actor, but the type itself doesn't enforce that.
    private let memoryLock = NSLock()
    /// Removals the stores on disk may not reflect yet (asynchronous mode),
    /// each with the write ticket both stores must reach before it can be
    /// dropped; see `removingDurably`. Guarded by `memoryLock`; nil until
    /// read from disk.
    private var tombstones: [(tombstone: Tombstone, tickets: [StoreKind: Int])]?
    /// Ticket of the newest write that reached disk for each store.
    /// Guarded by `memoryLock`.
    private var landedWriteTicket: [StoreKind: Int] = [:]
    /// Ticket of the newest write scheduled for each store, guarded by
    /// `memoryLock`. A queued write whose ticket is no longer the newest
    /// skips itself: a later write is queued behind it and will store the
    /// newer memory copy, so an older snapshot never lands after a newer one.
    private var writeTicket = 0
    private var newestWriteTicket: [StoreKind: Int] = [:]
    /// When set, encoding and UserDefaults writes run on `writeQueue` and the
    /// memory copies are authoritative (defaults may briefly lag behind).
    /// Each queued write stores the memory copy as it is when the write
    /// runs, not as it was when it was queued. The app keeps itself alive
    /// through suspension until the queue drains (see AppState's background
    /// handling); nothing on the main thread may block on this queue.
    private let writeQueue: DispatchQueue?

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date() },
        writesAsynchronously: Bool = false
    ) {
        self.defaults = defaults
        self.now = now
        self.writeQueue = writesAsynchronously
            ? DispatchQueue(label: "conduit.sessionPresentationCache.write", qos: .utility)
            : nil
    }

    /// Blocks until every queued disk write has landed. No-op in
    /// synchronous mode. Test-only: never call this on the main thread in
    /// the app. A UserDefaults write posts its change notification on the
    /// writing thread, SwiftUI's observer takes SwiftUI's lock there, and a
    /// main thread holding that lock (any view update) while waiting here
    /// deadlocks until the watchdog kills the app.
    #if DEBUG
    func waitForPendingWrites() {
        writeQueue?.sync {}
    }
    #endif

    /// Calls `completion` on the main queue once every disk write queued so
    /// far has landed, without blocking the caller. In synchronous mode the
    /// writes are already on disk, so it only hops to the main queue.
    func notifyWhenPendingWritesLand(_ completion: @escaping @MainActor () -> Void) {
        guard let writeQueue else {
            DispatchQueue.main.async { completion() }
            return
        }
        writeQueue.async {
            DispatchQueue.main.async { completion() }
        }
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
        includePendingApprovals: Bool = false,
        includePendingTools: Bool = false
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
        var cached = resolutionOrder.compactMap { snapshotByID[$0] }
            .flatMap { session -> [CachedMessage] in
                let unconfirmedExpired = isUnconfirmedPendingDecisionExpired(
                    since: session.unconfirmedPendingDecisionAt
                )
                return unconfirmedExpired
                    ? removingPendingDecisionPresentation(from: session.messages)
                    : session.messages
            }
        var cachedIDs = Set(cached.map(\.id))
        cached.append(contentsOf: pendingToolRecords(profile: profile, sessionIDs: sessionIDs)
            .filter { cachedIDs.insert($0.id).inserted })
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

        if includePendingTools {
            var eligibleIDLessRunningByName: [String: Set<String>] = [:]
            for index in remaining {
                let presentation = cached[index]
                guard presentation.role == .tool,
                      presentation.toolStatus == .running,
                      stableToolID(presentation.toolID) == nil,
                      let name = normalizedToolName(name: presentation.toolName, displayName: presentation.toolDisplayName) else {
                    continue
                }
                eligibleIDLessRunningByName[name, default: []].insert(presentation.id)
            }
            let uniqueIDLessRunningNames = Set(
                eligibleIDLessRunningByName.compactMap { name, ids in
                    ids.count == 1 ? name : nil
                }
            )

            for index in remaining.sorted() {
                let presentation = cached[index]
                guard presentation.role == .tool,
                      presentation.toolStatus == .running,
                      !containsResolvedTool(
                          for: presentation,
                          gatewayMessages: messages,
                          uniqueIDLessRunningNames: uniqueIDLessRunningNames
                      ) else {
                    continue
                }
                merged.append(ChatMessage(
                    id: presentation.id,
                    role: .tool,
                    content: "",
                    timestamp: presentation.timestamp,
                    tool: ToolActivity(
                        id: presentation.toolID,
                        name: presentation.toolDisplayName ?? presentation.toolName ?? "Tool",
                        input: presentation.toolPreview,
                        output: nil,
                        status: .running
                    )
                ))
            }
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
                        content: clarify.displayQuestion,
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
            // Hermes approvals are a single gate per conversation. When the
            // gateway transcript already announces a pending approval under
            // ANY identity of this conversation (the supplied lookup set),
            // a promoted push card for the same gate — keyed by the durable
            // id after routing rewrite — would render as a duplicate.
            let suppliedIDs = Set(sessionIDs.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            })
            let gatewayAnnouncesPendingGate = merged.contains { message in
                guard let approval = message.approval else { return false }
                return Self.isPendingDecision(approval.status)
                    && suppliedIDs.contains(
                        approval.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
            }
            for approval in pendingApprovals {
                let alreadyPresent = merged.contains { message in
                    guard let existing = message.approval else { return false }
                    if let requestId = approval.requestId {
                        return existing.requestId == requestId
                    }
                    return existing.requestId == nil
                        && existing.sessionId == approval.sessionId
                }
                if alreadyPresent || (approval.requestId == nil && gatewayAnnouncesPendingGate) {
                    continue
                }
                let cachedMessage = cached.last {
                    $0.approval?.requestId == approval.requestId
                        && $0.approval?.sessionId == approval.sessionId
                }
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

    private func containsResolvedTool(
        for cached: CachedMessage,
        gatewayMessages: [ChatMessage],
        uniqueIDLessRunningNames: Set<String> = []
    ) -> Bool {
        let cachedToolID = stableToolID(cached.toolID)
        let cachedNormalizedName = normalizedToolName(name: cached.toolName, displayName: cached.toolDisplayName)
        return gatewayMessages.contains { message in
            guard message.role == .tool,
                  let tool = message.tool else {
                return false
            }
            if message.id == cached.id { return true }
            let gatewayToolID = stableToolID(tool.id)
            if let cachedToolID, let gatewayToolID {
                return cachedToolID == gatewayToolID
            }
            if cachedToolID == nil,
               gatewayToolID != nil,
               tool.status == .complete,
               let cachedNormalizedName,
               uniqueIDLessRunningNames.contains(cachedNormalizedName),
               normalizedToolName(name: tool.name, displayName: nil) == cachedNormalizedName {
                return true
            }
            return false
        }
    }

    private func normalizedToolName(name: String?, displayName: String?) -> String? {
        if let name {
            let trimmed = normalized(name)
            if !trimmed.isEmpty { return trimmed }
        }
        if let displayName {
            let trimmed = normalized(displayName)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private func stableToolID(_ id: String?) -> String? {
        guard let id else { return nil }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Records the crash-recovery marker synchronously, without decoding and
    /// rewriting the much larger presentation store. The next ordinary,
    /// debounced `save` folds this bounded side record into the full snapshot.
    func recordPendingToolStart(
        _ message: ChatMessage,
        profile: String,
        sessionIDs: [String]
    ) {
        guard message.role == .tool, message.tool?.status == .running else { return }
        let ids = Set(sessionIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !ids.isEmpty else { return }
        let record = CachedMessage(message)
        var pendingStore = loadPendingTools()
        for id in ids {
            let cacheKey = key(profile: profile, sessionID: id)
            var records = pendingStore[cacheKey] ?? []
            if let toolID = stableToolID(record.toolID) {
                records.removeAll { stableToolID($0.toolID) == toolID }
            }
            records.append(record)
            pendingStore[cacheKey] = Array(records.suffix(maxMessagesPerSession))
        }
        persistPendingTools(pendingStore)
    }

    /// A completion event makes the local running projection obsolete. An
    /// exact message id or stable tool id resolves only its exact record.
    /// Legacy id-less events are inherently ambiguous when same-name calls
    /// overlap; resolving is only performed when exactly one unambiguous
    /// running candidate exists, avoiding destructive mis-matches when multiple
    /// calls are in flight.
    func resolvePendingTool(
        named name: String,
        toolID: String? = nil,
        messageID: String? = nil,
        profile: String,
        sessionIDs: [String]
    ) {
        let ids = Set(sessionIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !ids.isEmpty else { return }
        let normalizedName = normalized(name)
        let trimmedToolID = toolID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stableToolID = trimmedToolID.isEmpty ? nil : trimmedToolID
        let trimmedMessageID = messageID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stableMessageID = trimmedMessageID.isEmpty ? nil : trimmedMessageID

        // Exact-identity paths (messageID or stableToolID) are deterministic
        // and handle each store independently — the first match wins.
        // The ID-less fallback must inspect BOTH stores before mutating
        // either, deduplicating by message ID, and only resolve when the
        // combined logical candidate count is exactly one.

        let hasExactIdentity = stableMessageID != nil || stableToolID != nil

        var pendingStore = loadPendingTools()
        var pendingChanged = false
        var matchedPendingKeys = Set<String>()

        if hasExactIdentity {
            // --- Exact-identity resolution (unchanged) ---
            for id in ids {
                let cacheKey = key(profile: profile, sessionID: id)
                guard var records = pendingStore[cacheKey] else { continue }
                let index: Int?
                if let stableMessageID {
                    index = records.lastIndex(where: {
                        $0.id == stableMessageID && $0.toolStatus == .running
                    })
                } else {
                    index = records.lastIndex(where: {
                        $0.toolStatus == .running && self.stableToolID($0.toolID) == stableToolID
                    })
                }
                guard let resolvedIndex = index else { continue }
                records.remove(at: resolvedIndex)
                pendingStore[cacheKey] = records.isEmpty ? nil : records
                pendingChanged = true
                matchedPendingKeys.insert(cacheKey)
            }
            if pendingChanged { persistPendingTools(pendingStore) }

            let unresolvedIDs = ids.filter { !matchedPendingKeys.contains(key(profile: profile, sessionID: $0)) }
            guard !unresolvedIDs.isEmpty else { return }

            var store = load()
            var changed = false
            for id in unresolvedIDs {
                let cacheKey = key(profile: profile, sessionID: id)
                guard var session = store[cacheKey] else { continue }
                let index: Int?
                if let stableMessageID {
                    index = session.messages.lastIndex(where: {
                        $0.role == .tool
                            && $0.toolStatus == .running
                            && $0.id == stableMessageID
                    })
                } else {
                    index = session.messages.lastIndex(where: {
                        $0.role == .tool
                            && $0.toolStatus == .running
                            && self.stableToolID($0.toolID) == stableToolID
                    })
                }
                guard let resolvedIndex = index else { continue }
                session.messages.remove(at: resolvedIndex)
                session.updatedAt = now()
                store[cacheKey] = session
                changed = true
            }
            if changed { persist(store) }
        } else {
            // --- ID-less fallback: cross-store deduplication ---
            // Gather ALL running same-name candidates from both stores across
            // all session aliases, deduplicate by message ID, and only mutate
            // when the combined logical candidate count is exactly one.

            struct CandidateLocation {
                enum Store { case pending, full }
                let store: Store
                let cacheKey: String
                let index: Int
                let messageID: String
            }

            var allCandidates: [CandidateLocation] = []
            let store = load()

            for id in ids {
                let cacheKey = key(profile: profile, sessionID: id)

                if let records = pendingStore[cacheKey] {
                    for idx in records.indices {
                        let msg = records[idx]
                        guard msg.toolStatus == .running,
                              msg.toolName == normalizedName else { continue }
                        allCandidates.append(CandidateLocation(
                            store: .pending, cacheKey: cacheKey, index: idx, messageID: msg.id
                        ))
                    }
                }

                if let session = store[cacheKey] {
                    for idx in session.messages.indices {
                        let msg = session.messages[idx]
                        guard msg.role == .tool,
                              msg.toolStatus == .running,
                              msg.toolName == normalizedName else { continue }
                        allCandidates.append(CandidateLocation(
                            store: .full, cacheKey: cacheKey, index: idx, messageID: msg.id
                        ))
                    }
                }
            }

            // Deduplicate by message ID — the same logical record exists under
            // every session alias and may be mirrored between pending and full.
            var seenMessageIDs = Set<String>()
            let uniqueCandidates = allCandidates.filter { seenMessageIDs.insert($0.messageID).inserted }

            guard uniqueCandidates.count == 1, let winner = uniqueCandidates.first else { return }

            // Remove the unique winner from every alias across BOTH stores
            // (a single logical candidate may be mirrored between pending and full).
            for id in ids {
                let cacheKey = key(profile: profile, sessionID: id)
                guard var records = pendingStore[cacheKey] else { continue }
                if let idx = records.lastIndex(where: { $0.id == winner.messageID && $0.toolStatus == .running }) {
                    records.remove(at: idx)
                    pendingStore[cacheKey] = records.isEmpty ? nil : records
                    pendingChanged = true
                }
            }
            if pendingChanged { persistPendingTools(pendingStore) }

            var mutableStore = store
            var changed = false
            for id in ids {
                let cacheKey = key(profile: profile, sessionID: id)
                guard var session = mutableStore[cacheKey] else { continue }
                if let idx = session.messages.lastIndex(where: {
                    $0.role == .tool && $0.toolStatus == .running && $0.id == winner.messageID
                }) {
                    session.messages.remove(at: idx)
                    session.updatedAt = now()
                    mutableStore[cacheKey] = session
                    changed = true
                }
            }
            if changed { persist(mutableStore) }
        }
    }

    /// An explicitly idle resume is authoritative: any local tool-start
    /// projection that has not been committed is stale and must not become a
    /// permanently-running card on later launches.
    func removePendingTools(profile: String, sessionIDs: [String]) {
        let ids = Set(sessionIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !ids.isEmpty else { return }
        var pendingStore = loadPendingTools()
        var pendingChanged = false
        for id in ids {
            let cacheKey = key(profile: profile, sessionID: id)
            if pendingStore.removeValue(forKey: cacheKey) != nil {
                pendingChanged = true
            }
        }
        if pendingChanged { persistPendingTools(pendingStore) }
        var store = load()
        guard !store.isEmpty else { return }
        var changed = false
        for id in ids {
            let cacheKey = key(profile: profile, sessionID: id)
            guard var session = store[cacheKey] else { continue }
            let originalCount = session.messages.count
            session.messages.removeAll { $0.role == .tool && $0.toolStatus == .running }
            guard session.messages.count != originalCount else { continue }
            session.updatedAt = now()
            store[cacheKey] = session
            changed = true
        }
        if changed { persist(store) }
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
        let pendingRecords = pendingToolRecords(profile: profile, sessionIDs: Array(ids)).filter { pending in
            guard let pendingID = stableToolID(pending.toolID) else { return true }
            return !freshRecords.contains { fresh in
                stableToolID(fresh.toolID) == pendingID && fresh.toolStatus != .running
            }
        }
        let recordIDs = Set(records.map(\.id))
        records.append(contentsOf: pendingRecords.filter { !recordIDs.contains($0.id) })
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
        removePendingToolSideRecords(profile: profile, sessionIDs: Array(ids))
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
               !keys.contains(approval.requestId.map { "approval-request:\($0)" }
                    ?? "approval:\(approval.sessionId)") {
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
            return approval.requestId.map { "approval-request:\($0)" }
                ?? "approval:\(approval.sessionId)"
        }
        return nil
    }

    private func pendingDecisionKey(for message: CachedMessage) -> String? {
        if let clarify = message.clarify, Self.isPendingDecision(clarify.status) {
            return "clarify:\(clarify.requestId)"
        }
        if let approval = message.approval, Self.isPendingDecision(approval.status) {
            return approval.requestId.map { "approval-request:\($0)" }
                ?? "approval:\(approval.sessionId)"
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
        let prefix = profile.map { normalized($0) + "|" } ?? ""
        removingDurably([Tombstone(prefix: prefix, exact: false)]) { clearNow(profile: profile) }
    }

    private func clearNow(profile: String?) {
        guard let profile else {
            memoryLock.withLock {
                memoryStore = [:]
                memoryPendingTools = [:]
                memoryStoreData = nil
                memoryPendingToolsData = nil
            }
            // In asynchronous mode `removingDurably` queues the writes.
            if writeQueue == nil {
                defaults.removeObject(forKey: storageKey)
                defaults.removeObject(forKey: pendingToolsStorageKey)
            }
            return
        }

        let prefix = normalized(profile) + "|"
        var store = load()
        store.keys.filter { $0.hasPrefix(prefix) }.forEach { store.removeValue(forKey: $0) }
        persist(store)
        var pendingStore = loadPendingTools()
        pendingStore.keys.filter { $0.hasPrefix(prefix) }.forEach { pendingStore.removeValue(forKey: $0) }
        persistPendingTools(pendingStore)
    }

    /// Removes the cached records for the given sessions inside `profile`,
    /// for exactly the keys passed (callers must pass every alias — see
    /// `revokeDeletedConversationIdentity`). The delete path calls this so a
    /// deleted conversation cannot resurrect its presentation (including any
    /// pending decision cards) from a stale alias.
    func removeSessions(profile: String, sessionIDs: [String]) {
        let removed = Set(sessionIDs.compactMap { sessionID -> String? in
            let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : key(profile: profile, sessionID: trimmed)
        })
        removingDurably(removed.sorted().map { Tombstone(prefix: $0, exact: true) }) {
            removeSessionsNow(profile: profile, sessionIDs: sessionIDs)
        }
    }

    private func removeSessionsNow(profile: String, sessionIDs: [String]) {
        let prefix = normalized(profile) + "|"
        let ids = Set(sessionIDs.compactMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        })
        guard !ids.isEmpty else { return }
        var store = load()
        var changed = false
        for sessionID in ids {
            let cacheKey = prefix + sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
            if store.removeValue(forKey: cacheKey) != nil {
                changed = true
            }
        }
        if changed { persist(store) }
        removePendingToolSideRecords(profile: profile, sessionIDs: Array(ids))
    }

    /// Durable-owned persistence: once this conversation's durable identity
    /// is positively established, the durable key is its ONLY persistent
    /// presentation key. Moves the conversation's cached presentation from
    /// its runtime-alias keys into the durable key, then REMOVES every alias
    /// key. Retiring the mutable runtime keys is the point: a runtime id the
    /// gateway later re-attributes to a different conversation must not
    /// carry this conversation's timestamps, attachments, tool metadata, or
    /// pending decision cards with it.
    ///
    /// Merge semantics when the durable record already exists: the durable
    /// record stays AUTHORITATIVE for transcript presentation — an alias
    /// snapshot never overwrites its timestamps, tool metadata, or rows.
    /// Only NEW pending decision content (approval/clarify/batch by stable
    /// decision key, deduped) is promoted from alias records — the fresh
    /// notification-delivered card must survive, the stale alias transcript
    /// must not leak. On establishment (no durable record yet) the FRESHEST
    /// alias record migrates whole so runtime-only history is not lost.
    ///
    /// Approval cards whose embedded `sessionId` names a retired runtime
    /// alias are rewritten to the durable id, so answering a restored card
    /// dispatches to the durable session even after later rotations.
    /// Clarify request ids are relay-minted (`conduit-push-…`), not session
    /// ids, and are never rewritten.
    func consolidateUnderDurableKey(
        profile: String,
        durableSessionID: String,
        runtimeAliases: [String]
    ) {
        let durableKey = key(profile: profile, sessionID: durableSessionID)
        let aliasKeys = Set(
            runtimeAliases.map { key(profile: profile, sessionID: $0) }
        ).subtracting([durableKey])
        guard !aliasKeys.isEmpty else { return }
        var pendingStore = loadPendingTools()
        var durablePending = pendingStore[durableKey] ?? []
        var pendingIDs = Set(durablePending.map(\.id))
        for aliasKey in aliasKeys {
            for record in pendingStore.removeValue(forKey: aliasKey) ?? []
                where pendingIDs.insert(record.id).inserted {
                durablePending.append(record)
            }
        }
        if !durablePending.isEmpty {
            pendingStore[durableKey] = Array(durablePending.suffix(maxMessagesPerSession))
        }
        persistPendingTools(pendingStore)
        var store = load()
        if store[durableKey] == nil {
            let freshest = aliasKeys
                .compactMap { store[$0] }
                .max { lhs, rhs in
                    lhs.updatedAt == rhs.updatedAt
                        ? lhs.messages.count < rhs.messages.count
                        : lhs.updatedAt < rhs.updatedAt
                }
            if var freshest {
                rewriteRoutingIdentities(in: &freshest, durableSessionID: durableSessionID, runtimeAliases: runtimeAliases)
                store[durableKey] = freshest
            }
        } else {
            promotePendingDecisionsFromAliases(
                into: &store,
                durableKey: durableKey,
                aliasKeys: aliasKeys,
                durableSessionID: durableSessionID,
                runtimeAliases: runtimeAliases
            )
        }
        var changed = store[durableKey] != nil
        for aliasKey in aliasKeys where store.removeValue(forKey: aliasKey) != nil {
            changed = true
        }
        guard changed else { return }
        if var durableSession = store[durableKey] {
            rewriteRoutingIdentities(
                in: &durableSession,
                durableSessionID: durableSessionID,
                runtimeAliases: runtimeAliases
            )
            store[durableKey] = durableSession
        }
        persist(store)
    }

    /// Promotes NEW pending decision presentation from alias records into an
    /// existing durable record. The durable transcript rows, timestamps, and
    /// tool metadata are never touched: only pending decisions the durable
    /// record does not already hold (deduped by stable decision key, after
    /// routing-identity rewrite) are appended, and the bounded
    /// unconfirmed-expiry marker is adopted when the durable record has none.
    private func promotePendingDecisionsFromAliases(
        into store: inout [String: CachedSession],
        durableKey: String,
        aliasKeys: Set<String>,
        durableSessionID: String,
        runtimeAliases: [String]
    ) {
        guard var durableSession = store[durableKey] else { return }
        let aliases = Set(runtimeAliases.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })
        var knownKeys = Set(durableSession.messages.compactMap(decisionKey(for:)))
        var promoted = false
        // The freshest unconfirmed marker among aliases that actually
        // contributed a card. Markers from cardless aliases are ignored:
        // adopting one could expire the just-promoted card immediately.
        var freshestContributedMarker: Date?
        for aliasKey in aliasKeys {
            guard let aliasEntry = store[aliasKey] else { continue }
            var aliasContributed = false
            for message in aliasEntry.messages {
                guard pendingDecisionKey(for: message) != nil else { continue }
                var candidate = message
                // Rewrite BEFORE dedup so a runtime-keyed card cannot
                // duplicate a decision the durable record already holds
                // under the durable id.
                if let approval = candidate.approval,
                   aliases.contains(approval.sessionId) {
                    candidate.approval?.sessionId = durableSessionID
                }
                let key = decisionKey(for: candidate)
                guard let key else { continue }
                if let existingIndex = durableSession.messages.firstIndex(where: {
                    decisionKey(for: $0) == key
                }) {
                    // Same decision already persisted. The durable row stays
                    // authoritative unless its unconfirmed marker has
                    // expired — a dead durable card is replaced by the fresh
                    // alias copy rather than duplicated or silently dropped.
                    if isUnconfirmedPendingDecisionExpired(
                        since: durableSession.unconfirmedPendingDecisionAt
                    ) {
                        durableSession.messages[existingIndex] = candidate
                        aliasContributed = true
                    }
                    continue
                }
                durableSession.messages.append(candidate)
                knownKeys.insert(key)
                promoted = true
                aliasContributed = true
            }
            // Replacement (the duplicate branch above) counts as promotion:
            // without it a fresh alias copy of an expired durable card would
            // be discarded and the marker refresh skipped.
            if aliasContributed { promoted = true }
            guard aliasContributed,
                  let aliasMarker = aliasEntry.unconfirmedPendingDecisionAt else { continue }
            if freshestContributedMarker == nil || aliasMarker > freshestContributedMarker! {
                freshestContributedMarker = aliasMarker
            }
        }
        guard promoted else { return }
        // Expiry semantics: only touch the marker when cards were promoted.
        // Adopt the freshest contributing marker when the durable record has
        // none, and REFRESH an expired durable marker — a stale marker would
        // make merge strip the freshly promoted card on the next read,
        // silently losing it after successful promotion. A live durable
        // marker is left alone: legitimately-expired durable cards without
        // fresh arrivals stay expired.
        if let freshestContributedMarker,
           durableSession.unconfirmedPendingDecisionAt == nil
            || isUnconfirmedPendingDecisionExpired(since: durableSession.unconfirmedPendingDecisionAt) {
            durableSession.unconfirmedPendingDecisionAt = freshestContributedMarker
        }
        durableSession.updatedAt = now()
        store[durableKey] = durableSession
    }

    /// Points migrated approval cards at the durable session id when they
    /// were keyed by one of the retired runtime aliases. Clarify request ids
    /// live in a different namespace and are intentionally untouched.
    private func rewriteRoutingIdentities(
        in session: inout CachedSession,
        durableSessionID: String,
        runtimeAliases: [String]
    ) {
        let aliases = Set(runtimeAliases.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })
        var mutated = false
        for index in session.messages.indices {
            var message = session.messages[index]
            if let approval = message.approval,
               aliases.contains(approval.sessionId) {
                message.approval?.sessionId = durableSessionID
                session.messages[index] = message
                mutated = true
            }
        }
        if mutated {
            session.updatedAt = now()
        }
    }

    private func load() -> [String: CachedSession] {
        memoryLock.lock()
        defer { memoryLock.unlock() }
        if writeQueue != nil, let memoryStore { return memoryStore }
        let data = defaults.data(forKey: storageKey)
        if let memoryStore, data == memoryStoreData { return memoryStore }
        let decoded = withoutTombstonedKeys(
            data.flatMap { try? JSONDecoder().decode([String: CachedSession].self, from: $0) } ?? [:]
        )
        memoryStore = decoded
        memoryStoreData = data
        return decoded
    }

    private func persist(_ store: [String: CachedSession]) {
        guard writeQueue == nil else {
            memoryLock.withLock { memoryStore = store }
            scheduleWrite(.sessions)
            return
        }
        memoryLock.lock()
        defer { memoryLock.unlock() }
        memoryStore = store
        guard let data = try? JSONEncoder().encode(store) else {
            memoryStore = nil
            return
        }
        defaults.set(data, forKey: storageKey)
        memoryStoreData = data
    }

    private func loadPendingTools() -> [String: [CachedMessage]] {
        memoryLock.lock()
        defer { memoryLock.unlock() }
        if writeQueue != nil, let memoryPendingTools { return memoryPendingTools }
        let data = defaults.data(forKey: pendingToolsStorageKey)
        if let memoryPendingTools, data == memoryPendingToolsData { return memoryPendingTools }
        let decoded = withoutTombstonedKeys(
            data.flatMap { try? JSONDecoder().decode([String: [CachedMessage]].self, from: $0) } ?? [:]
        )
        memoryPendingTools = decoded
        memoryPendingToolsData = data
        return decoded
    }

    private func persistPendingTools(_ store: [String: [CachedMessage]]) {
        guard writeQueue == nil else {
            memoryLock.withLock { memoryPendingTools = store }
            scheduleWrite(.pendingTools)
            return
        }
        memoryLock.lock()
        defer { memoryLock.unlock() }
        memoryPendingTools = store
        let key = pendingToolsStorageKey
        guard !store.isEmpty else {
            defaults.removeObject(forKey: key)
            memoryPendingToolsData = nil
            return
        }
        guard let data = try? JSONEncoder().encode(store) else {
            memoryPendingTools = nil
            return
        }
        defaults.set(data, forKey: key)
        memoryPendingToolsData = data
    }

    private enum StoreKind {
        case sessions, pendingTools
    }

    /// Cache keys a clear or delete removed: one exact key, or every key
    /// with the prefix (a profile's, or "" for all).
    private struct Tombstone: Codable, Equatable {
        var prefix: String
        var exact: Bool

        func covers(_ key: String) -> Bool {
            exact ? key == prefix : key.hasPrefix(prefix)
        }
    }

    /// Queues a write of `kind`'s current memory copy (asynchronous mode
    /// only) and returns its ticket.
    @discardableResult
    private func scheduleWrite(_ kind: StoreKind) -> Int {
        guard let writeQueue else { return 0 }
        let ticket = memoryLock.withLock { () -> Int in
            writeTicket += 1
            newestWriteTicket[kind] = writeTicket
            return writeTicket
        }
        writeQueue.async { self.writeLatest(kind, ticket: ticket) }
        return ticket
    }

    /// Encodes and stores `kind`'s memory copy as it is now, unless a newer
    /// write was scheduled since `ticket` (that one will store newer
    /// state). A store that was never loaded is left alone: nil means "not
    /// read yet", not "empty". The copy is taken under `memoryLock`;
    /// encoding and the UserDefaults write happen outside it, so a UserDefaults change
    /// notification can never re-enter the lock.
    private func writeLatest(_ kind: StoreKind, ticket: Int) {
        func isNewest() -> Bool { newestWriteTicket[kind] == ticket }
        guard memoryLock.withLock({ isNewest() }) else { return }
        let key: String
        // Outer nil: never loaded, nothing to write. Inner nil: empty store.
        let encoded: Data??
        switch kind {
        case .sessions:
            key = storageKey
            let snapshot: [String: CachedSession]? = memoryLock.withLock { memoryStore }
            encoded = snapshot.map { $0.isEmpty ? nil : (try? JSONEncoder().encode($0)) }
            if let snapshot, !snapshot.isEmpty, encoded == .some(nil) { return }
        case .pendingTools:
            key = pendingToolsStorageKey
            let snapshot: [String: [CachedMessage]]? = memoryLock.withLock { memoryPendingTools }
            encoded = snapshot.map { $0.isEmpty ? nil : (try? JSONEncoder().encode($0)) }
            if let snapshot, !snapshot.isEmpty, encoded == .some(nil) { return }
        }
        guard let encoded, memoryLock.withLock({ isNewest() }) else { return }
        if let data = encoded {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        let canRetireTombstones = memoryLock.withLock { () -> Bool in
            landedWriteTicket[kind] = max(landedWriteTicket[kind] ?? 0, ticket)
            guard let tombstones else { return false }
            return tombstones.contains { hasLandedLocked($0.tickets) }
        }
        if canRetireTombstones {
            DispatchQueue.main.async { self.retireLandedTombstones() }
        }
    }

    /// Runs a clear or delete so it holds across a kill, without waiting on
    /// the write queue. In asynchronous mode the stores on disk can lag
    /// memory, and a save queued before the removal can still land after
    /// it, so the removed keys are recorded under their own UserDefaults key
    /// before this returns and filtered out whenever a store is read from
    /// disk. That key is only ever written on the main thread (here and in
    /// `retireLandedTombstones`), so no queued write can overwrite it. Once
    /// a write of each store queued after the removal has landed, disk
    /// matches and the tombstones are dropped. Main thread only.
    private func removingDurably(_ removed: [Tombstone], _ body: () -> Void) {
        body()
        guard writeQueue != nil, !removed.isEmpty else { return }
        let tickets: [StoreKind: Int] = [
            .sessions: scheduleWrite(.sessions),
            .pendingTools: scheduleWrite(.pendingTools)
        ]
        let stored = memoryLock.withLock { () -> [Tombstone] in
            var current = loadedTombstonesLocked().filter { !removed.contains($0.tombstone) }
            current += removed.map { (tombstone: $0, tickets: tickets) }
            tombstones = current
            return current.map(\.tombstone)
        }
        storeTombstones(stored)
        // The removal's writes may already have landed before the
        // tombstones were recorded, in which case no write will retire them.
        retireLandedTombstones()
    }

    /// Drops tombstones whose removal both stores on disk now reflect.
    /// Main thread only (see `removingDurably`).
    private func retireLandedTombstones() {
        let remaining = memoryLock.withLock { () -> [Tombstone]? in
            guard let current = tombstones else { return nil }
            let kept = current.filter { !hasLandedLocked($0.tickets) }
            guard kept.count != current.count else { return nil }
            tombstones = kept
            return kept.map(\.tombstone)
        }
        if let remaining { storeTombstones(remaining) }
    }

    private func storeTombstones(_ stored: [Tombstone]) {
        if stored.isEmpty {
            defaults.removeObject(forKey: tombstonesStorageKey)
        } else if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: tombstonesStorageKey)
        }
    }

    /// Whether each store has landed a write at least as new as its ticket
    /// in `tickets`. Caller holds `memoryLock`.
    private func hasLandedLocked(_ tickets: [StoreKind: Int]) -> Bool {
        tickets.allSatisfy { (landedWriteTicket[$0.key] ?? -1) >= $0.value }
    }

    /// Tombstones in effect, read from disk on first use. Ones left by an
    /// earlier launch carry ticket 0 for both stores, so the first landed
    /// write of each store retires them. Synchronous instances re-read on every call
    /// (another instance may have written them). Caller holds `memoryLock`.
    private func loadedTombstonesLocked() -> [(tombstone: Tombstone, tickets: [StoreKind: Int])] {
        if writeQueue != nil, let tombstones { return tombstones }
        let stored = defaults.data(forKey: tombstonesStorageKey)
            .flatMap { try? JSONDecoder().decode([Tombstone].self, from: $0) } ?? []
        let loaded = stored.map { (tombstone: $0, tickets: [StoreKind.sessions: 0, .pendingTools: 0]) }
        if writeQueue != nil { tombstones = loaded }
        return loaded
    }

    /// `store` minus every key a clear or delete removed but disk may still
    /// hold. Caller holds `memoryLock`.
    private func withoutTombstonedKeys<Value>(_ store: [String: Value]) -> [String: Value] {
        let active = loadedTombstonesLocked()
        guard !active.isEmpty else { return store }
        return store.filter { key, _ in !active.contains { $0.tombstone.covers(key) } }
    }

    private func pendingToolRecords(profile: String, sessionIDs: [String]) -> [CachedMessage] {
        let store = loadPendingTools()
        var seen = Set<String>()
        return sessionIDs.flatMap { store[key(profile: profile, sessionID: $0)] ?? [] }
            .filter { seen.insert($0.id).inserted }
    }

    private func removePendingToolSideRecords(profile: String, sessionIDs: [String]) {
        var store = loadPendingTools()
        var changed = false
        for sessionID in sessionIDs {
            changed = store.removeValue(forKey: key(profile: profile, sessionID: sessionID)) != nil || changed
        }
        if changed { persistPendingTools(store) }
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
        //
        // The message's own fingerprints are computed once here, not
        // once per candidate: this runs for every transcript row against
        // every cached row on each resume, so recomputing them per candidate
        // made a resume cost grow with the square of the chat's length.
        let contentSignature = message.tool == nil ? Self.fingerprint(message.content) : nil
        let toolInputSignature = message.tool?.input.map(Self.fingerprint)
        let toolOutputSignature = message.tool?.output.map(Self.fingerprint)
        let toolName = message.tool.map { normalized($0.name) }
        let gatewayToolID = stableToolID(message.tool?.id)
        for index in cached.indices where remaining.contains(index) {
            let candidate = cached[index]
            guard candidate.role == message.role else { continue }
            var score = Int.min

            if candidate.id == message.id {
                // Absolute maximum; no later candidate can outrank it.
                return index
            } else if message.tool != nil {
                let cachedToolID = stableToolID(candidate.toolID)
                let hasStableMatch: Bool
                if let cachedToolID, let gatewayToolID {
                    guard cachedToolID == gatewayToolID else { continue }
                    hasStableMatch = true
                } else if cachedToolID != nil || gatewayToolID != nil {
                    // ID-bearing tools must not fall back to name matching.
                    continue
                } else {
                    guard candidate.toolName == toolName else { continue }
                    // A locally recorded start belongs after the cached history.
                    // Do not let any generic same-name gateway row consume it:
                    // without a shared row or tool id, it can be a distinct
                    // invocation that happens to have the same input.
                    if candidate.toolStatus == .running {
                        continue
                    }
                    hasStableMatch = false
                }
                score = hasStableMatch ? 80 : 50
                if candidate.toolName == toolName { score += 10 }
                if let toolInputSignature, candidate.toolInputSignature == toolInputSignature { score += 30 }
                if let toolOutputSignature, candidate.toolOutputSignature == toolOutputSignature { score += 30 }
                if (message.tool?.input ?? "").isEmpty, candidate.toolPreview?.isEmpty == false { score += 5 }
            } else if candidate.signature == contentSignature {
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
        let normalized = collapsingWhitespace(value)
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    /// Collapses every run of whitespace to one space and drops leading and
    /// trailing whitespace: the same result as replacing the regex `\s+`
    /// with " " and trimming `.whitespacesAndNewlines`, which this replaces.
    /// That regex ran over the full text of every cached row (tool output
    /// included) on each save, on the main thread; a single scalar pass is
    /// many times cheaper. ICU's `\s` is the Unicode White_Space property,
    /// and every trimmed character is White_Space, so outputs match exactly
    /// and stored signatures stay valid.
    static func collapsingWhitespace(_ value: String) -> String {
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in value.unicodeScalars {
            let isWhitespace = scalar.isASCII
                ? scalar == " " || (scalar.value >= 0x09 && scalar.value <= 0x0D)
                : scalar.properties.isWhitespace
            if isWhitespace {
                pendingSpace = true
                continue
            }
            if pendingSpace, !result.isEmpty {
                result.append(" ")
            }
            pendingSpace = false
            result.append(scalar)
        }
        return String(result)
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
