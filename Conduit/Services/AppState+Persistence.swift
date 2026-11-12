//
//  AppState+Persistence.swift
//  Conduit
//
//  Moved out of AppState.swift (issue 828): Persistence; Offline chat cache
//  (#99).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Persistence

    /// This AppState's defaults, for its extensions in other files.
    var appDefaults: UserDefaults { defaults }

    /// Who keeps a sharing destination's plugin up to date: the active
    /// dashboard's answer, or what another saved dashboard last reported.
    func pluginManagedBy(forDashboard id: UUID?) -> String? {
        guard let id, id != activeDashboardID else { return PluginUpdateAsk.managedBy }
        return NotifierPluginStatus.Remembered.managedBy(for: id, in: defaults)
    }

    /// Kept outside ChatResumeStore on purpose: the return surface is a
    /// presentation preference, not part of the resume schema.
    static let chatReturnSurfaceKey = "conduit.chatReturnSurface.v1"

    /// Shared with the saved-dashboard migration (which relabels a legacy
    /// URL identity to the dashboard UUID), so it is a static.
    static let chatResumeServerIdentityKey = "conduit.chatResumeServerIdentity.v1"

    static let maximumRememberedVoiceJobSessions = 200

    /// The id a review summary is saved under: the open chat's durable id
    /// when Hermes confirmed one, else its row's stored id, else the open id.
    /// The event's runtime id is replaced on the next resume, and the scroll
    /// identity's canonical id can still be the chat open before a new one.
    /// Never a row found through its alternate ids, which another row can
    /// share: a runtime key Hermes confirms later still matches.
    func reviewRecordSessionID(eventSessionId: String) -> String {
        guard let active = activeSessionId, !active.isEmpty else { return eventSessionId }
        if let durable = confirmedDurableSessionID(forRuntime: active) { return durable }
        // Only a row that alone names the chat, in this profile: two rows
        // claiming it are not settled by list order.
        if let key = ChatScrollIdentityNormalization.sessionID(active) {
            let rows = (activeProfileSessions + activeProfileCronSessions).filter { row in
                [row.id, row.storedSessionId].contains { ChatScrollIdentityNormalization.sessionID($0) == key }
            }
            if rows.count == 1, let row = rows.first,
               let id = ChatScrollIdentityNormalization.sessionID(row.storedSessionId)
                ?? ChatScrollIdentityNormalization.sessionID(row.id) {
                return id
            }
        }
        if let stored = ChatScrollIdentityNormalization.sessionID(voiceSessionAliases.storedID(forRuntime: active)) {
            return stored
        }
        return ChatScrollIdentityNormalization.sessionID(active) ?? active
    }

    /// The durable id Hermes confirmed for a chat's runtime id: a Bot Chat's
    /// mapping is under the bot's profile, and the dashboard's is tried too.
    /// The durable id Hermes confirmed for a runtime id in `profile`.
    func confirmedDurableSessionID(forRuntime sessionId: String, profile: String) -> String? {
        conversationIdentityIndex.durableID(forRuntime: sessionId, profile: profile)
    }

    func confirmedDurableSessionID(forRuntime sessionId: String) -> String? {
        botConversationProfile(for: sessionId)
            .flatMap { conversationIdentityIndex.durableID(forRuntime: sessionId, profile: $0) }
            ?? conversationIdentityIndex.durableID(forRuntime: sessionId, profile: activeProfile)
    }

    /// Whether a saved review belongs to the open chat: its key is one of the
    /// chat's own ids, or a runtime id Hermes confirmed as one of them. Never
    /// the scroll identity's aliases or a reconciliation's ids, which keep the
    /// previous chat's ids after a new chat and pinned its reviews there.
    private func reviewRecordBelongs(_ record: ReviewSummaryRecord, toOwnIDs ownIDs: Set<String>) -> Bool {
        if let key = ChatScrollIdentityNormalization.sessionID(record.sessionId), ownIDs.contains(key) {
            return true
        }
        guard let durable = ChatScrollIdentityNormalization.sessionID(
            confirmedDurableSessionID(forRuntime: record.sessionId)
        ) else { return false }
        return ownIDs.contains(durable)
    }

    func mergeCachedReviews(into history: [ChatMessage], sessionId: String) -> [ChatMessage] {
        let ownIDs = chatOwnSessionIDs(for: sessionId)
        let records = cachedReviews().filter {
            $0.profile == activeProfile && reviewRecordBelongs($0, toOwnIDs: ownIDs)
        }
        guard !records.isEmpty else { return history }
        var reviews: [ChatMessage] = []
        // Dedup by record id, not by activity: with Hermes' default
        // `display.memory_notifications: on` every review reads the same
        // generic "Memory updated", and each one is its own event. A review
        // the TRANSCRIPT already carries (older gateways persisted the
        // "💾 Self-improvement review:" line) is the same event, so a cached
        // record repeating one of those is skipped, one cached record per
        // transcript row so identically worded reviews are not collapsed.
        var transcriptReviews = history.compactMap { message in
            message.id.hasPrefix("review-summary-") ? nil : message.review
        }
        for record in records where !history.contains(where: { $0.id == record.id }) {
            if let match = transcriptReviews.firstIndex(of: record.activity) {
                transcriptReviews.remove(at: match)
                continue
            }
            reviews.append(ChatMessage(
                id: record.id,
                role: .system,
                content: record.activity.summary,
                timestamp: record.timestamp,
                review: record.activity
            ))
        }
        return Self.placingReviews(reviews, into: history)
    }

    /// Saved review rows put among Hermes' rows by time, leaving Hermes'
    /// order as it is: each review goes before the first row timed after it.
    /// Hermes times its rows in epoch seconds and Conduit its reviews as ISO
    /// dates, so both are read the way the chat reads a row's time. Sorting
    /// the whole transcript by an ISO-only read used to put every saved
    /// review after the newest message (issue #1549). A row with no time it
    /// can read never decides a review's place. A review's time is the
    /// phone's clock and a row's the host's, so a host clock that is off
    /// moves a review by as much (an open gap in the feature map: Hermes'
    /// review event carries no time of its own).
    static func placingReviews(_ reviews: [ChatMessage], into history: [ChatMessage]) -> [ChatMessage] {
        guard !reviews.isEmpty else { return history }
        // Parse each timestamp once: a long chat resumes with every row.
        let historyDates = history.map { MessageTimestampFormatter.date(from: $0.timestamp) }
        // Reviews saved in the same second keep the order they were saved in.
        let placed = reviews.enumerated()
            .map { (message: $1, date: MessageTimestampFormatter.date(from: $1.timestamp) ?? .distantFuture, order: $0) }
            .sorted { ($0.date, $0.order) < ($1.date, $1.order) }
        var merged: [ChatMessage] = []
        merged.reserveCapacity(history.count + reviews.count)
        var next = 0
        for (index, message) in history.enumerated() {
            if let date = historyDates[index] {
                while next < placed.count, placed[next].date < date {
                    merged.append(placed[next].message)
                    next += 1
                }
            }
            merged.append(message)
        }
        merged.append(contentsOf: placed[next...].map(\.message))
        return merged
    }

    /// The chat with its saved review rows placed again, after Load earlier
    /// put older rows above a review that sat at the start of the newest
    /// page. Nil when no review moves.
    static func replacingSavedReviews(in messages: [ChatMessage]) -> [ChatMessage]? {
        let isSaved = { (message: ChatMessage) in message.id.hasPrefix("review-summary-") }
        let reviews = messages.filter(isSaved)
        guard !reviews.isEmpty else { return nil }
        let placed = placingReviews(reviews, into: messages.filter { !isSaved($0) })
        return placed.map(\.id) == messages.map(\.id) ? nil : placed
    }

    /// The chat's "Voice call" markers for calls started from it.
    func mergeVoiceCallMarkers(into history: [ChatMessage], sessionId: String) -> [ChatMessage] {
        let ownIDs = chatOwnSessionIDs(for: sessionId)
        var openIDs = ownIDs
        if let call = voiceCallSessionID(ownIDs: ownIDs) { openIDs.insert(call) }
        return voiceCallChatLinks.merge(
            into: history,
            chatIDs: ownIDs,
            openIDs: openIDs,
            profile: activeProfile
        )
    }

    /// The open chat's own ids, for its call cards and Resume Call: the id,
    /// the durable id Hermes confirmed for it, and its row's id and stored
    /// id. Never the scroll identity's aliases or a reconciliation's ids:
    /// a new chat, or one opened from another, keeps the previous chat's
    /// ids there, and that chat's calls would show in this one.
    func chatOwnSessionIDs(for sessionId: String) -> Set<String> {
        // An opened saved chat resumes under a new runtime id the list may
        // not show yet; the resume (or the create) recorded its durable id.
        let durable = confirmedDurableSessionID(forRuntime: sessionId)
        let seeds = [sessionId, durable, voiceSessionAliases.storedID(forRuntime: sessionId)].compactMap { $0 }
        // The chat's header, composer and call cards ask several times per
        // publish; the answer only changes with the seeds or the catalog.
        let key = ChatOwnSessionIDsKey(
            seeds: seeds,
            sessionsRevision: sessionsRevision,
            cronSessionsRevision: cronSessionsRevision
        )
        // A few entries: the header asks by the open id and by its row's.
        if let cached = chatOwnSessionIDsCache[key] { return cached }
        let ids = Self.ownSessionIDs(for: seeds, in: [sessions, cronSessions].joined())
        if chatOwnSessionIDsCache.count >= 8 { chatOwnSessionIDsCache.removeAll() }
        chatOwnSessionIDsCache[key] = ids
        return ids
    }

    struct ChatOwnSessionIDsKey: Hashable {
        let seeds: [String]
        let sessionsRevision: Int
        let cronSessionsRevision: Int
    }

    /// The open chat's row in the session list, for the chat title's
    /// touch-and-hold menu. A cron run is found among the Cron rows and gets
    /// the same menu its row has there (#512; no Move to Project). Nil for a
    /// room, an offline copy, a Bot Chat or a workstream's chat (no row of its own), or a new chat
    /// Hermes hasn't listed yet. A reopened chat runs under a
    /// runtime id its row may not name yet, so the row is found through the
    /// chat's own ids and handed back carrying the open id too: rename,
    /// archive and delete then reach the open chat as well.
    var activeChatSessionSummary: SessionSummary? {
        // While an offline copy is on screen the title is that copy's, which
        // can be another chat than the active id.
        guard activeRoomSurface == nil, offlineChatPresentation == nil, !showsPendingNewChat,
              let sessionId = activeSessionId, !sessionId.isEmpty,
              botConversationProfile(for: sessionId) == nil else { return nil }
        let ownIDs = chatOwnSessionIDs(for: sessionId)
        let durable = conversationIdentityIndex.durableID(forRuntime: sessionId, profile: activeProfile)
        // The chat's header reads this several times per publish, and the
        // match walks every row of the profile, its cron runs included.
        let key = ActiveChatSessionSummaryKey(
            rows: ActiveProfileSessionsKey(
                sessionsRevision: sessionsRevision,
                profile: activeProfile,
                botOwnershipGeneration: botOwnershipGeneration,
                workstreamsGeneration: botWork.workstreamsGeneration
            ),
            cronSessionsRevision: cronSessionsRevision,
            sessionId: sessionId,
            ownIDs: ownIDs,
            durable: durable
        )
        if let cached = activeChatSessionSummaryCache, cached.key == key { return cached.row }
        let row = activeChatSessionSummary(sessionId: sessionId, ownIDs: ownIDs, durable: durable)
        activeChatSessionSummaryCache = (key, row)
        return row
    }

    struct ActiveChatSessionSummaryKey: Equatable {
        let rows: ActiveProfileSessionsKey
        let cronSessionsRevision: Int
        let sessionId: String
        let ownIDs: Set<String>
        let durable: String?
    }

    func activeChatSessionSummary(sessionId: String, ownIDs: Set<String>, durable: String?) -> SessionSummary? {
        let rows = [activeProfileSessions, activeProfileCronSessions].joined()
        // This row drives rename, archive and delete, so it is never picked
        // by list order: two rows matching the chat's own ids are settled
        // by the stored id its resume recorded, else neither is used. An
        // alternate id, which rows can share, only counts when exactly one
        // row lists it.
        let ownMatches = rows.filter { candidate in
            !ownIDs.isDisjoint(with: [candidate.id, candidate.storedSessionId].compactMap {
                ChatScrollIdentityNormalization.sessionID($0)
            })
        }
        let alternateMatches = rows.filter { $0.alternateIds.contains(sessionId) }
        let match: SessionSummary?
        if ownMatches.count == 1 {
            match = ownMatches.first
        } else if ownMatches.count > 1 {
            if let durable {
                let durableMatches = ownMatches.filter { $0.id == durable || $0.storedSessionId == durable }
                match = durableMatches.count == 1 ? durableMatches.first : nil
            } else {
                match = nil
            }
        } else {
            match = alternateMatches.count == 1 ? alternateMatches.first : nil
        }
        guard var row = match else { return nil }
        if row.id != sessionId, !row.alternateIds.contains(sessionId) {
            row.alternateIds.append(sessionId)
        }
        return row
    }

    /// The ids a pending screenshot's chat is known by: its own ids, so it
    /// is still found when the chat is reopened under a new runtime id.
    func screenshotChatIDs(for sessionId: String) -> Set<String> {
        chatOwnSessionIDs(for: sessionId)
    }

    /// The ids a call from Hermes' chat is known by (#449), so its spoken
    /// answers reach cards in that chat only.
    func hermesCallChatIDs(for sessionId: String) -> Set<String> {
        chatOwnSessionIDs(for: sessionId)
    }

    static func ownSessionIDs(for sessionId: String, in rows: [SessionSummary]) -> Set<String> {
        ownSessionIDs(for: [sessionId], in: rows)
    }

    /// The ids plus the id and stored id of each row they name, never a
    /// row's alternate ids, which another row can share.
    static func ownSessionIDs(for seeds: [String], in rows: some Sequence<SessionSummary>) -> Set<String> {
        var ids = Set(seeds)
        for row in rows where seeds.contains(row.id) || row.storedSessionId.map(seeds.contains) == true {
            ids.insert(row.id)
            if let stored = row.storedSessionId { ids.insert(stored) }
        }
        return Set(ids.compactMap { ChatScrollIdentityNormalization.sessionID($0) })
    }

    /// The call a chat's "Voice call" marker opens.
    func voiceCallLink(markerID: String) -> VoiceCallChatLink? {
        voiceCallChatLinks.link(markerID: markerID)
    }

    /// Whether a listed chat has a call kept with it or started from it,
    /// for the Voice filter: one look at the links per filter pass.
    func voiceCallChatFilter() -> (SessionSummary) -> Bool {
        let ids = voiceCallChatLinks.chatIDs(profile: activeProfile)
        guard !ids.isEmpty else { return { _ in false } }
        return { session in session.nestingIDs.contains { ids.contains($0) } }
    }

    /// The calls the host keeps with this profile's chats, from every
    /// device: their chats get the call cards and are listed under Voice
    /// here too (a call's link used to live only on the device that made it).
    func adoptHostChatCalls(_ calls: [VoiceHostChatCall], profile: String) {
        let listed = profile == activeProfile ? sessions : []
        let adopted = voiceCallChatLinks.adopt(calls, profile: profile) { chatID in
            listed.first { $0.nestingIDs.contains(chatID) }?.title
        }
        guard adopted else { return }
        voiceCallChatLinks.store(in: defaults)
        voiceCallChatLinksRevision &+= 1
        showVoiceCallMarkersInOpenChat(profile: profile)
    }

    /// The open chat's history with any call cards it lacks, at once.
    private func showVoiceCallMarkersInOpenChat(profile: String) {
        guard profile == activeProfile, let sessionID = activeSessionId else { return }
        let merged = mergeVoiceCallMarkers(into: messages, sessionId: sessionID)
        guard merged.count != messages.count else { return }
        messages = merged
        cacheMessagePresentation()
    }

    /// A call attached to a chat was saved: the chat gets its marker, at
    /// once when it's on screen.
    /// `callSessionID` is empty for a call kept with its chat, `chatID`
    /// the chat it was kept with.
    func linkVoiceCall(_ attachment: VoiceCallAttachment, callSessionID: String, chatID: String? = nil, profile: String) {
        let runtimeID = attachment.thread.runtimeSessionID
        let storedID = chatID ?? storedChatID(for: attachment.thread, profile: profile)
        learnVoiceSessionAlias(runtimeID: runtimeID, storedID: storedID)
        let link = VoiceCallChatLink(
            callID: attachment.callID,
            callSessionID: callSessionID,
            chatRuntimeSessionID: runtimeID,
            chatStoredSessionID: storedID,
            chatTitle: attachment.thread.title,
            profile: profile,
            startedAt: attachment.startedAt,
            endedAt: attachment.endedAt ?? Date(),
            resumed: attachment.resumed,
            chatProfile: attachment.thread.profile
        )
        voiceCallChatLinks.add(link)
        voiceCallChatLinks.store(in: defaults)
        voiceCallChatLinksRevision &+= 1
        showVoiceCallMarkersInOpenChat(profile: profile)
    }

    /// An unattached call took its first job's chat as its own (#1250): the
    /// call is kept with that chat, as one started there is, so the chat
    /// gets its call marker and Resume Call goes back to it. The chat is the
    /// call's now, not one of its jobs. Called again once the chat's stored
    /// id turns up.
    func keepVoiceCallWithAdoptedChat(_ thread: VoiceThreadTarget) {
        let ids = [thread.runtimeSessionID, thread.storedSessionID].compactMap { $0 }.filter { !$0.isEmpty }
        if var remembered = voiceJobSessionIDsByProfile[activeProfile], remembered.contains(where: { ids.contains($0) }) {
            remembered.removeAll { ids.contains($0) }
            voiceJobSessionIDsByProfile[activeProfile] = remembered
            persistVoiceJobSessions()
        }
        guard let recorder = voiceCallRecorder else { return }
        captureVoiceCall()
        // Its line in the saved call says where the request went now.
        if let job = voiceBackgroundJobSupervisor.jobs.first(where: { $0.id == voiceBackgroundJobSupervisor.callChatJobID }) {
            let line = Self.voiceThreadTurnNote(job, thread: thread)
            for sessionID in [job.storedSessionID, job.runtimeSessionID, nil] {
                recorder.replaceNote(Self.voiceJobStartedNote(title: job.title, sessionID: sessionID), with: line)
            }
            // Once the chat's stored id is learned, the line links to it.
            var earlier = thread
            earlier.storedSessionID = nil
            let runtimeLine = Self.voiceThreadTurnNote(job, thread: earlier)
            if runtimeLine != line { recorder.replaceNote(runtimeLine, with: line) }
        }
        recorder.jobSessionIDs.removeAll { ids.contains($0) }
        let key = voiceHistoryKey(profile: recorder.profile)
        for id in ids { voiceSessionTagsByKey[key]?[id] = nil }
        if voiceCallAttachment?.callID == recorder.callID {
            voiceCallAttachment?.thread = thread
        } else {
            voiceCallAttachment = VoiceCallAttachment(
                thread: thread, callID: recorder.callID,
                startedAt: voiceBackgroundJobSupervisor.liveCallStartedAt ?? Date(),
                resumed: recorder.sessionID != nil
            )
        }
        checkpointVoiceCall(recorder)
    }

    /// The chat's durable id: a chat new at the call's start may only have
    /// its stored id later.
    private func storedChatID(for thread: VoiceThreadTarget, profile: String) -> String? {
        let runtimeID = thread.runtimeSessionID
        // The catalog lists the active profile's chats: a Bot Chat isn't one.
        let listed = (thread.profile ?? profile) == activeProfile
        return thread.storedSessionID.flatMap { $0.isEmpty ? nil : $0 }
            ?? (listed ? sessions.first(where: { $0.id == runtimeID || $0.alternateIds.contains(runtimeID) })?.storedSessionId.flatMap { $0.isEmpty ? nil : $0 } : nil)
            ?? conversationIdentityIndex.durableID(forRuntime: runtimeID, profile: thread.profile ?? profile)
    }

    /// The chat a call on `profile` is kept with (#556): its stored id. A
    /// Bot Chat's is in the bot's profile, where its calls are kept too
    /// (`voiceCallChatProfile`).
    func voiceCallChatID(for thread: VoiceThreadTarget, profile: String) -> String? {
        storedChatID(for: thread, profile: thread.profile ?? profile)
    }

    /// The profile a call on `profile` kept with `thread` is saved to, when
    /// it isn't `profile`: a Bot Chat's bot.
    static func voiceCallChatProfile(for thread: VoiceThreadTarget, profile: String) -> String? {
        guard let bot = thread.profile, !bot.isEmpty, bot != profile else { return nil }
        return bot
    }

    /// Whether a call starting now goes on as the last call kept with a
    /// chat: same chat and profile, started again within the reconnect
    /// window.
    static func continuesChatCall(lastChatID: String, lastProfile: String, endedAt: Date, chatID: String?, profile: String, now: Date) -> Bool {
        guard let chatID, chatID == lastChatID, profile == lastProfile else { return false }
        let gap = now.timeIntervalSince(endedAt)
        return gap >= 0 && gap <= chatCallReconnectWindow
    }

    func persistReview(_ record: ReviewSummaryRecord) {
        // Append-only by design: every review is its own row (the default
        // mode repeats "Memory updated"), and the merge dedupes by record id.
        var records = cachedReviews()
        records.append(record)
        // Keep this small, device-local resilience cache. Hermes remains the
        // source of truth for normal messages; this only preserves summaries
        // that are emitted exclusively as stream events.
        records = Array(records.suffix(200))
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: reviewSummaryCacheKey)
        }
    }

    private func cachedReviews() -> [ReviewSummaryRecord] {
        guard let data = defaults.data(forKey: reviewSummaryCacheKey) else { return [] }
        return (try? JSONDecoder().decode([ReviewSummaryRecord].self, from: data)) ?? []
    }

    func deviceConditionsChanged(_ conditions: DeviceConditions) {
        let wasUsable = networkPathUsable
        if networkPathUsable != conditions.pathSatisfied { networkPathUsable = conditions.pathSatisfied }
        guard conditions.pathGeneration != lastPathGeneration else { return }
        lastPathGeneration = conditions.pathGeneration
        networkPathChanged(satisfied: conditions.pathSatisfied, cameBack: !wasUsable)
    }

    /// Path reports on a churny network (handovers, a VPN reasserting) come
    /// often; only one every this long restarts the backoff.
    static let pathReconnectInterval: TimeInterval = 30

    /// The network path changed. A usable one checks the open socket at
    /// once. A reconnect waiting out its backoff (or the network) runs now,
    /// from the first step, when the network came back or the last such
    /// restart is 30 s old: the drop was most likely the old path.
    func networkPathChanged(satisfied: Bool, cameBack: Bool = false, now: Date = Date()) {
        guard satisfied else { return }
        client?.networkPathChanged()
        guard connection != nil, !isConnected, !isConnecting, reconnectTask != nil,
              canRunTransportRecovery else { return }
        if !cameBack, let lastPathReconnectAt,
           now.timeIntervalSince(lastPathReconnectAt) < Self.pathReconnectInterval { return }
        lastPathReconnectAt = now
        let purpose = recoverySequence.takeQueuedReconnectPurpose() ?? .preserveCurrent
        reconnectTask?()
        reconnectTask = nil
        reconnectAttempts = 0
        noteConnectionStep("Network changed")
        // Immediate: the delay doesn't depend on the path state read below.
        scheduleReconnect(immediately: true, purpose: purpose)
    }

    func restoreActiveSessionState(for profile: String) {
        clearPendingDecisionRestorationGuard()
        // A switch to Pulse's profile doesn't open Pulse's hidden chat either.
        if let home = pulseHomeChat, showsPulseScreen {
            forgetResumedPulseChat(home, profile: profile, among: sessions)
        }
        // The stored reference's KIND decides how its conversation restores.
        // Positive bot evidence reclassifies a legacy id-only reference (every
        // install upgrading from a build that could not record the kind), so a
        // Bot Chat written there before this build is not adopted as an
        // ordinary conversation of the workspace; with no evidence the
        // reference keeps its recorded kind and restores exactly as before.
        let reference = chatResumeCoordinator.lastSession(for: profile).map { stored in
            chatResumeCoordinator.reclassifySession(
                stored,
                for: profile,
                ownership: botOwnership
            )
        }
        adoptSessionReference(reference, for: profile)
    }

    // MARK: - Offline chat cache (#99)

    #if DEBUG
    private static let testOfflineChatCacheRoot: URL? = {
        guard NSClassFromString("XCTestCase") != nil else { return nil }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineChatCache-tests", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        return root
    }()
    #endif

    static func makeDefaultOfflineChatCache() -> OfflineChatCacheStore {
        #if DEBUG
        // Unit tests construct many AppStates in one process without
        // injecting a store: each gets its own subdirectory (so no test can
        // read another's copy) under ONE per-process root, which is wiped the
        // first time it is used — nothing accumulates across runs.
        if let testRoot = testOfflineChatCacheRoot {
            return OfflineChatCacheStore(
                directory: testRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            )
        }
        #endif
        // Leaving a chat, a reply settling or the list changing saves on the
        // store's own queue, never on the tap.
        return OfflineChatCacheStore(directory: OfflineChatCacheStore.defaultDirectory(), writesAsynchronously: true)
    }

    /// Saves the newest page of the conversation on screen. Only
    /// authoritative, connected state is recorded — never the offline copy
    /// itself, and never a transcript mid-reconciliation.
    func recordOfflineChatCopy() {
        guard isConnected,
              offlineChatPresentation == nil,
              turnState != .synchronizing,
              !messages.isEmpty,
              let dashboardID = activeDashboardID,
              let identities = offlineChatIdentities(),
              // A Bot Chat keeps no copy on the phone, even when a stray row
              // of it is in the workspace's list (`keepBotChatCopy` keeps it).
              botStoreProfile(forSessionIDs: Array(identities)) == nil else { return }
        offlineChatCache.record(
            dashboardID: dashboardID,
            profile: activeProfile,
            sessionID: offlineChatDurableSessionID(identities: identities),
            identities: identities,
            title: activeSessionTitle,
            messages: messages,
            sessions: sessions
        )
    }

    /// The key a saved transcript is stored under: the durable id of the
    /// catalog row this conversation matches (by runtime id, stored id, or
    /// alias) — the same `storedSessionId ?? id` that keys the saved session
    /// list — so a server that reports distinct runtime and stored ids still
    /// lines the transcript up with its sidebar row.
    /// Nil when the live catalog has no row for this conversation: the store
    /// then resolves the key from its saved session list, or skips the write.
    private func offlineChatDurableSessionID(identities: Set<String>) -> String? {
        let row = sessions.first { session in
            identities.contains(session.id)
                || session.storedSessionId.map(identities.contains) == true
                || !identities.isDisjoint(with: session.alternateIds)
        }
        return row.map { $0.storedSessionId ?? $0.id }
    }

    /// Every identity the on-screen conversation is known under.
    func offlineChatIdentities() -> Set<String>? {
        guard let active = ChatScrollIdentityNormalization.sessionID(
            activeChatScrollSessionIdentity.canonicalSessionID ?? activeSessionId
        ) else { return nil }
        var identities = acceptedIdentitySessionIDs(forRequested: active)
        identities.formUnion(activeChatScrollSessionIdentity.equivalentSessionIDs)
        return identities
    }

    /// Cold launch: present the saved copy for the active dashboard until the
    /// server answers, and the Chats list as it was last shown until the
    /// live one lands. A no-op once any real transcript is on screen.
    func presentOfflineChatIfAvailable(dashboardID: UUID) {
        presentSavedChatListIfAvailable(dashboardID: dashboardID)
        // A message an earlier run, or an earlier visit here, left waiting
        // comes back as a draft, once the chat it goes to shows.
        defer { restorePendingSendsLeftBehind(dashboardID: dashboardID) }
        guard offlineChatPresentation == nil,
              messages.isEmpty,
              let snapshot = offlineChatCache.load(dashboardID: dashboardID, profile: activeProfile),
              !snapshot.transcripts.isEmpty || !snapshot.sessions.isEmpty else { return }
        let displayed = snapshot.lastSessionID.flatMap { snapshot.transcript(for: $0) != nil ? $0 : nil }
            ?? snapshot.transcripts.first?.sessionID
        offlineChatPresentation = OfflineChatPresentation(
            dashboardID: dashboardID,
            profile: activeProfile,
            snapshot: snapshot,
            displayedTranscript: displayed.flatMap {
                offlineChatCache.loadTranscript($0, dashboardID: dashboardID, profile: activeProfile)
            }
        )
    }

    /// Header title: the saved conversation's title while the offline copy
    /// is on screen (a picked chat's row title), otherwise the live
    /// conversation's.
    var displayedChatTitle: String {
        if showsPendingNewChat { return AppLocalization.string("New conversation") }
        let title = offlineChatPresentation?.picked?.title
            ?? offlineChatPresentation?.displayedTranscript?.title
            ?? activeSessionTitle
        // A workstream's chat isn't in the list here (Hermes hides an open
        // one, and this app leaves a resolved one out), so it has no title
        // here: it takes its task's.
        if title == AppLocalization.string("New conversation"), let workstream = activeWorkstream {
            return workstream.item.shownTitle
        }
        return title
    }

    func dismissOfflineChatPresentation() {
        guard offlineChatPresentation != nil else { return }
        offlineChatPresentation = nil
    }
}
