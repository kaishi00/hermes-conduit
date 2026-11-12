//
//  AppState+TranscriptHistory.swift
//  Conduit
//
//  A chat's persisted transcript: its tail on foregrounding, history
//  pages, row ids, and loading earlier messages. Moved out of
//  AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Persisted transcripts and earlier messages

    /// Mirrors Hermes Desktop's `/api/sessions/{id}/messages` prefetch:
    /// fetches the session's persisted transcript through the dashboard
    /// history route (or the test seam standing in for it) and parses it with
    /// the production normalizer path. The typed outcome lets the resume
    /// reconciliation distinguish a missing history source — which triggers
    /// the legacy full-transcript resume — from an unrelated failure, which
    /// must surface instead of silently degrading.
    ///
    /// The request is explicitly bounded (tail-anchored page of
    /// `PersistedTranscriptPagination.pageSize` rows) so the transport and
    /// normalization cost of opening a conversation is bounded no matter how
    /// large the session grew. A response that carries the `order=latest`
    /// pagination echo answers under the paginated tail contract; one
    /// without it is a legacy one-shot full transcript and hydrates as
    /// before.
    /// Result of the foreground freshness tail read. Only the newest bounded
    /// `order=latest` page is ever requested. Unlike `persistedTranscriptOutcome`
    /// this deliberately has NO legacy one-shot fallback: a freshness check
    /// must never escalate into a full-transcript transfer just to prove
    /// currency — a backend that cannot serve the tail contract yields
    /// inconclusive evidence instead, and the authoritative resume/reconcile
    /// path owns any full hydration. (Gateway-only deployments without any
    /// history source therefore re-attach authoritatively on each armed
    /// return — the designed fallback, not a regression to optimize away.)
    enum ForegroundPersistedTailOutcome {
        /// Validated tail page with positively durable row ids.
        case hydrated(PersistedSessionTranscript)
        /// The response did not honor the `order=latest` + durable-identity
        /// contract — including a body with no message-rows array at all,
        /// which the authoritative resume path re-classifies and SURFACES as
        /// `HermesError.invalidResponse` (never silently absorbed here).
        case unsupportedTailContract
        /// The history source is structurally absent (no bridge/endpoint, or
        /// the endpoint answered 404/410/501): no bounded capability exists.
        case unavailable
        /// Transient trouble (timeout, 429/5xx, bridge not ready, network).
        case failed(Error)
    }

    /// Bounded tail-only read for the foreground freshness check: exactly one
    /// `order=latest offset=0` page request, parsed with the shared
    /// extraction/pagination/identity helpers, and stopping deliberately
    /// before `persistedTranscriptOutcome`'s legacy one-shot re-read.
    func foregroundPersistedTailOutcome(
        sessionId: String,
        profile: String,
        using bridge: DashboardTicketBridge?
    ) async -> ForegroundPersistedTailOutcome {
        let fetchOutcome = await fetchPersistedHistoryPayload(
            sessionId: sessionId,
            profile: profile,
            query: PersistedTranscriptPagination.tailQuery(offset: 0),
            using: bridge
        )
        switch fetchOutcome {
        case .unavailable:
            return .unavailable
        case .failed(let error):
            if Self.historySourceIsUnavailable(error) {
                // Structural endpoint absence: no bounded capability exists.
                return .unavailable
            }
            return .failed(error)
        case .payload(let response):
            guard let rawMessages = Self.persistedMessageRows(in: response) else {
                return .unsupportedTailContract
            }
            guard let page = PersistedTranscriptPagination.parse(response, rawRowCount: rawMessages.count),
                  page.honorsTailContract,
                  PersistedTranscriptWindow.rowsHaveDurableIdentity(rawMessages) else {
                return .unsupportedTailContract
            }
            return .hydrated(PersistedSessionTranscript(
                resolvedSessionId: Self.resolvedSessionId(in: response),
                messages: await Self.normalizeTranscriptRows(
                    rawMessages,
                    imageScope: Self.transcriptImageScope(in: response, sessionId: sessionId, profile: profile)
                ),
                page: page,
                durableRowIDs: Set(rawMessages.compactMap(Self.durablePersistedRowID(from:)))
            ))
        }
    }

    func persistedTranscriptOutcome(
        sessionId: String,
        profile: String,
        using bridge: DashboardTicketBridge?
    ) async -> PersistedTranscriptOutcome {
        let fetchStartedAt = Date()
        let fetchOutcome = await fetchPersistedHistoryPayload(
            sessionId: sessionId,
            profile: profile,
            query: PersistedTranscriptPagination.tailQuery(offset: 0),
            using: bridge
        )
        switch fetchOutcome {
        case .payload: noteConnectionStep("Chat history", since: fetchStartedAt)
        case .unavailable: noteConnectionStep("Chat history endpoint unavailable", since: fetchStartedAt)
        case .failed(let error): noteConnectionStep("Chat history", since: fetchStartedAt, error: error)
        }

        switch fetchOutcome {
        case .unavailable:
            return .unavailable
        case .failed(let error):
            // Only STRUCTURAL endpoint absence degrades to the single legacy
            // resume. Transient trouble (429, 5xx, status-0 WebKit/network
            // failures, request timeouts, a bridge that never became ready)
            // surfaces instead: a slow or failing BOUNDED read must never
            // silently become a full-transcript WebSocket transport (the
            // giant-payload path compact resume exists to eliminate).
            if Self.historySourceIsUnavailable(error) {
                sessionCatalogLog.debug("Persisted transcript unavailable for \(sessionId, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
                return .unavailable
            }
            sessionCatalogLog.debug("Persisted transcript failed for \(sessionId, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private)")
            return .failed(error)
        case .payload(let response):
            guard let rawMessages = Self.persistedMessageRows(in: response) else {
                return .failed(HermesError.invalidResponse)
            }
            let page = PersistedTranscriptPagination.parse(response, rawRowCount: rawMessages.count)

            // A pagination echo WITHOUT the `order=latest` tail contract
            // describes a backend that pages from the oldest end: honoring
            // its offsets would walk the transcript forward from row zero
            // and never reach the newest rows. A paginated-contract page
            // whose rows lack durable identity is equally unpageable —
            // overlap dedup and the graft key on the persisted row ID, and
            // id-less rows would normalize to page-local positional IDs.
            // Either way, re-read one-shot — the exact request
            // pre-pagination Conduit made — and treat the response as the
            // legacy full transcript. Shape-detected from the response,
            // never version-sniffed, and performed at most once.
            if let page, !(page.honorsTailContract
                && PersistedTranscriptWindow.rowsHaveDurableIdentity(rawMessages)) {
                let oneShotOutcome = await fetchPersistedHistoryPayload(
                    sessionId: sessionId,
                    profile: profile,
                    query: PersistedTranscriptPagination.legacyQuery,
                    using: bridge
                )
                switch oneShotOutcome {
                case .payload(let fullResponse):
                    guard let fullRows = Self.persistedMessageRows(in: fullResponse) else {
                        return .failed(HermesError.invalidResponse)
                    }
                    return .hydrated(PersistedSessionTranscript(
                        resolvedSessionId: Self.resolvedSessionId(in: fullResponse) ?? Self.resolvedSessionId(in: response),
                        messages: await Self.normalizeTranscriptRows(
                            fullRows,
                            imageScope: Self.transcriptImageScope(in: fullResponse, sessionId: sessionId, profile: profile)
                        ),
                        page: nil
                    ))
                case .unavailable:
                    return .unavailable
                case .failed(let error):
                    if case DashboardTicketBridgeError.oversizedResponse = error {
                        // The legacy one-shot transcript outgrew the safe
                        // bound: an old backend attempted the entire
                        // transcript. Surface the transcript-specific
                        // compatibility copy.
                        return .failed(LegacyTranscriptOversizedError(limit: DataURLLimits.maxJSONResponseBytes))
                    }
                    if Self.historySourceIsUnavailable(error) {
                        return .unavailable
                    }
                    return .failed(error)
                }
            }

            // The dashboard server returns `messages`; the API-server variant
            // returns `data`, so accept both public Hermes response shapes.
            return .hydrated(PersistedSessionTranscript(
                resolvedSessionId: Self.resolvedSessionId(in: response),
                messages: await Self.normalizeTranscriptRows(
                    rawMessages,
                    imageScope: Self.transcriptImageScope(in: response, sessionId: sessionId, profile: profile)
                ),
                page: page,
                durableRowIDs: Set(rawMessages.compactMap(Self.durablePersistedRowID(from:)))
            ))
        }
    }

    private func fetchPersistedHistoryPayload(
        sessionId: String,
        profile: String,
        query: String,
        using bridge: DashboardTicketBridge?
    ) async -> PersistedTranscriptFetchOutcome {
        if let persistedTranscript = chatResumeLifecycleOperations.persistedTranscript {
            return await persistedTranscript(sessionId, profile, query)
        }
        guard let bridge else { return .unavailable }
        if let page = await historyPagePayload(sessionId: sessionId, profile: profile, query: query, using: bridge) {
            return page
        }
        do {
            return .payload(try await bridge.requestJSON(
                path: Self.sessionMessagesPath(sessionId: sessionId, profile: profile, query: query)
            ))
        } catch {
            // requestJSON's readiness poll is the bounded wait for a cold
            // or reloading bridge; whatever it raises is classified with
            // the seam-sourced failures below. Note the bridge caps REST
            // response size (DataURLLimits.maxJSONResponseBytes), so an
            // oversized transcript also lands here rather than silently
            // degrading the resume.
            return .failed(error)
        }
    }

    /// A voice read's page: the newest one through the history page when the
    /// plugin serves it (the rows a chat open kept stand in), any other page
    /// or a refused one through Hermes' route as before.
    func voiceHistoryPage(
        sessionId: String,
        profile: String,
        query: String,
        using bridge: DashboardTicketBridge
    ) async -> [String: Any]? {
        if query == PersistedTranscriptPagination.tailQuery(offset: 0) {
            switch await historyPagePayload(sessionId: sessionId, profile: profile, query: query, using: bridge) {
            case .payload(let page)?: return page
            // The link's own trouble: no second wait on Hermes' route.
            case .failed?: return nil
            case .unavailable?, nil: break
            }
        }
        return try? await bridge.requestJSON(
            path: Self.sessionMessagesPath(sessionId: sessionId, profile: profile, query: query)
        )
    }

    /// The page through the plugin's history page route (#1525), with the
    /// rows this phone kept from the last read of the chat's newest page
    /// sent as their fingerprints; nil when the plugin doesn't serve it or
    /// refused it, and Hermes' own route reads the page instead. A tail page
    /// read through it is kept for the next read.
    private func historyPagePayload(
        sessionId: String,
        profile: String,
        query: String,
        using bridge: DashboardTicketBridge
    ) async -> PersistedTranscriptFetchOutcome? {
        guard case .reported(_, let capabilities) = notifierPlugin.state,
              capabilities.contains(HistoryPage.capability),
              let dashboardID = activeDashboardID,
              !historyPageRefusedScopes.contains(HistoryPage.scopeKey(dashboardID: dashboardID, profile: profile)) else { return nil }
        // Kept under the chat's durable id: a new chat opens by its runtime
        // id, and the same chat by its stored one after a relaunch.
        // A query the route doesn't carry reads no held rows.
        guard HistoryPage.body(sessionId: sessionId, query: query, known: []) != nil else { return nil }
        let heldID = canonicalSessionID(for: sessionId) ?? sessionId
        let heldURL = offlineChatCache.heldRowsFileURL(heldID, dashboardID: dashboardID, profile: profile)
        let removals = offlineChatCache.removals
        let held = await Task.detached(priority: .userInitiated) {
            OfflineChatCacheStore.loadHeldRows(at: heldURL, sessionID: heldID)
        }.value
        guard let body = HistoryPage.body(sessionId: sessionId, query: query, known: held?.digests ?? []) else { return nil }
        let isTail = (body["offset"] as? Int) == 0 && (body["order"] as? String) == "latest"
        let path = DashboardPath.withProfile(HistoryPage.path, profile: profile)
        let startedAt = Date()
        let response: [String: Any]
        do {
            response = try await bridge.requestJSON(path: path, method: "POST", body: body, readsOnly: true)
        } catch {
            // A route this host can't serve for the profile is left for the
            // run, so later opens don't pay its round trip first.
            if HistoryPage.isRefusedForScope(error) {
                historyPageRefusedScopes.insert(HistoryPage.scopeKey(dashboardID: dashboardID, profile: profile))
            }
            return HistoryPage.readsHermesRouteInstead(after: error) ? nil : .failed(error)
        }
        guard let rebuilt = HistoryPage.rebuild(response, held: held?.byDigest ?? [:], sessionID: heldID) else {
            // The answer didn't match the fingerprints sent: Hermes' own
            // route reads the page whole.
            return nil
        }
        let sentRows = (response["messages"] as? [Any])?.filter { ($0 as? [String: Any])?[HistoryPage.knownKey] == nil }.count ?? 0
        noteConnectionStep("History page: \(sentRows) of \(rebuilt.kept.rows.count) rows sent", since: startedAt)
        // Only while nothing was removed from the saved chats during the read
        // (a sign-out, a removed dashboard, Delete saved chats, a deleted
        // chat) and the same sign-in still holds: these rows went too. The
        // store writes them on its queue, and a removal from now on waits
        // for them and takes them as well.
        if isTail, offlineChatCache.removals == removals, dashboardTicketBridge === bridge,
           activeDashboardID == dashboardID {
            offlineChatCache.recordHeldRows(rebuilt.kept, to: heldURL)
        }
        return .payload(rebuilt.page)
    }

    /// Where a page of persisted rows lives, for fetching a picture stored
    /// inside one of them later (#652): the stored session the response
    /// echoed (else the one asked for) in `profile`'s database.
    nonisolated static func transcriptImageScope(
        in response: [String: Any],
        sessionId: String,
        profile: String
    ) -> TranscriptImageScope {
        let echoed = resolvedSessionId(in: response)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptImageScope(
            sessionId: echoed.flatMap { $0.isEmpty ? nil : $0 } ?? sessionId,
            profile: profile
        )
    }

    /// Normalizes a transcript page off the main actor: a long chat's
    /// rows take tens of milliseconds, and the launch sync runs while the
    /// Chats list is drawing its first frames.
    private static func normalizeTranscriptRows(
        _ rows: [Any],
        imageScope: TranscriptImageScope?
    ) async -> [ChatMessage] {
        // Detached, so the hop off the main actor never depends on how a
        // nonisolated async function is scheduled.
        await Task.detached(priority: .userInitiated) {
            MessageNormalizer.normalizeMessages(rows.map(AnyCodable.from), imageScope: imageScope)
        }.value
    }

    /// The dashboard server returns `messages`; the API-server variant
    /// returns `data`, so accept both public Hermes response shapes.
    nonisolated static func persistedMessageRows(in response: [String: Any]) -> [Any]? {
        ["messages", "data", "_array"]
            .compactMap { response[$0] as? [Any] }
            .first
    }

    /// Positively extracts the durable persisted row id from a raw `/messages`
    /// row — the id the row actually persisted under — or nil when the row
    /// carries no durable identity (the normalizer would fall back to a
    /// positional index, which is presentation identity, not provenance).
    ///
    /// Keep the envelope merge and id-key order in sync with
    /// `MessageNormalizer.normalizeMessages`, which consumes the same rows.
    /// A row's `row_id` comes first, as in the normalizer; `/messages` rows
    /// carry `id` itself.
    nonisolated static func durablePersistedRowID(from rawRow: Any) -> String? {
        guard let envelope = rawRow as? [String: Any] else { return nil }
        // Same envelope merge as normalizeMessages: `message` / `payload` /
        // message-shaped `data` override the envelope, nested values win.
        let dataMessage = envelope["data"] as? [String: Any]
        let dataMessageIsCarrier = dataMessage.map { $0["role"] != nil || $0["type"] != nil } ?? false
        let nested = (envelope["message"] as? [String: Any])
            ?? (envelope["payload"] as? [String: Any])
            ?? (dataMessageIsCarrier ? dataMessage : nil)
            ?? [:]
        var obj = envelope
        for (key, value) in nested {
            obj[key] = value
        }
        // A row naming its stored row (`row_id`) has that row's id first,
        // as the normalizer gives it.
        if let rowID = obj["row_id"] as? NSNumber,
           CFGetTypeID(rowID) != CFBooleanGetTypeID(),
           let exactRowID = Int(exactly: rowID.doubleValue), exactRowID > 0 {
            return String(Double(exactRowID))
        }
        for key in ["id", "message_id"] {
            switch obj[key] {
            case let string as String where !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                return string
            case let number as NSNumber where number.doubleValue != 0:
                // Match AnyCodable's number rendering so the extracted id is
                // byte-identical to the normalized ChatMessage.id.
                return String(number.doubleValue)
            default:
                continue
            }
        }
        return nil
    }

    nonisolated static func resolvedSessionId(in response: [String: Any]) -> String? {
        (response["session_id"] as? String) ?? (response["sessionId"] as? String)
    }

    /// Classifies a history-fetch failure as STRUCTURAL ENDPOINT ABSENCE —
    /// the only condition that degrades the initial hydration to the single
    /// legacy full-transcript resume, and the only one that retires the
    /// backfill affordance:
    ///
    ///  - 404/410 — the gateway predates the messages route (or the session
    ///    is gone from it);
    ///  - 501 — the endpoint is explicitly unimplemented.
    ///
    /// Everything else must NOT silently escalate to the unbounded legacy
    /// transport: transient trouble (408/429, any other 5xx, status-0
    /// WebKit/network failures), a bridge that did not become ready or a
    /// request that outlived its deadline (both `.notReady`), an oversized
    /// response, authentication, and every unlisted error surfaces instead.
    /// This is the giant-session safety property: current Hermes can serve
    /// the bounded `include_compacted=true` page slowly for heavily
    /// compacted sessions until upstream bounding lands (#97440), so a slow
    /// bounded read must fail boundedly and retry through reconnect — never
    /// silently become "load the entire transcript over the WebSocket".
    nonisolated static func historySourceIsUnavailable(_ error: Error) -> Bool {
        guard case let DashboardTicketBridgeError.http(status, _) = error else { return false }
        switch status {
        case 404, 410, 501: return true
        default: return false
        }
    }

    nonisolated static func sessionMessagesPath(
        sessionId: String,
        profile: String,
        query: String
    ) -> String {
        let encodedSessionId = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId
        return DashboardPath.withProfile(
            "/api/sessions/\(encodedSessionId)/messages\(query)",
            profile: profile
        )
    }

    /// Whether a persisted-history window from the previous reconciliation
    /// belongs to the conversation this reconcile just accepted. Identity is
    /// compared through the ONE centralized rule with the new transaction's
    /// full identity set (requested, resolved stored, runtime), so a
    /// reconnect keeps the backfilled prefix even when the catalog is
    /// temporarily stale about the stored↔runtime alias.
    func priorWindowOwnsThisConversation(
        _ window: PersistedTranscriptWindowState?,
        requestedSessionId: String,
        resolvedSessionId: String?,
        runtimeSessionId: String?,
        profile: String
    ) -> Bool {
        guard let window else { return false }
        let conversationIds = PersistedTranscriptWindow.normalizingSessionIDs([
            requestedSessionId, resolvedSessionId, runtimeSessionId
        ])
        return PersistedTranscriptWindow.ownershipHolds(
            window: window,
            conversationSessionIds: conversationIds,
            profile: profile,
            windowAliasIds: catalogAliasIDs(for: window.trustedSessionIDs),
            conversationAliasIds: catalogAliasIDs(for: conversationIds)
        )
    }

    /// Fetches the next older persisted-history page for the active
    /// conversation and prepends it, keeping the user's visible position
    /// stable (ChatView anchors the prepend through the viewport controller).
    /// Strictly user-driven and single-flight: one explicit request at a
    /// time, owned by the window identity captured at request time, and a
    /// response from a session/profile that is no longer current is
    /// discarded without touching state.
    ///
    /// Returns whether a prepend actually published — the view discharges
    /// its viewport anchor when nothing landed, so an armed anchor can never
    /// re-pin on some later unrelated transcript change.
    @discardableResult
    func loadEarlierMessages() async -> Bool {
        guard let window = persistedTranscriptWindow,
              window.canLoadEarlier,
              !window.isLoadingEarlier else {
            return false
        }
        guard persistedTranscriptWindowOwnershipIsCurrent(window) else {
            // No user-facing error for an already-departed conversation —
            // and normally unreachable from a tap, because the affordance
            // exposes this exact ownership truth. The debug capture below
            // is purely diagnostic (it also fires on the legitimate
            // render-to-tap race during a session switch).
            sessionCatalogLog.debug("""
                Older-page backfill rejected ownership of an otherwise-actionable window: \
                requested=\(window.requestedSessionID, privacy: .private(mask: .hash)) \
                resolved=\(window.resolvedSessionID ?? "none", privacy: .private(mask: .hash)) \
                runtime=\(window.runtimeSessionID ?? "none", privacy: .private(mask: .hash)) \
                active=\(self.activeSessionId ?? "none", privacy: .private(mask: .hash)) \
                windowProfile=\(window.profile, privacy: .public) \
                activeProfile=\(self.activeProfile, privacy: .public)
                """)
            return false
        }
        // Older pages are persisted transcript history: continue against
        // the durable stored identity the hydration resolved (Desktop's
        // `BackfillRequest.storedSessionId` contract) — never the runtime
        // WebSocket ID, and never re-derived from a later catalog refresh.
        let wireSessionId = window.resolvedSessionID ?? window.requestedSessionID
        let requestedSessionId = window.requestedSessionID
        let profile = window.profile
        let offset = window.nextOffset
        var arming = window
        arming.isLoadingEarlier = true
        persistedTranscriptWindow = arming

        let outcome = await fetchOlderTranscriptPage(
            sessionId: wireSessionId,
            profile: profile,
            offset: offset
        )

        // Stale-response guard: the window must still be this exact
        // request's window (same session, same profile, still loading, and
        // no other fetch advanced it meanwhile). Anything else — session
        // switch, profile switch, disconnect re-home — discards the page.
        // The first four conditions identify THIS armed window; only then
        // may the bookkeeping below touch it.
        guard var current = persistedTranscriptWindow,
              current.requestedSessionID == requestedSessionId,
              current.profile == profile,
              current.nextOffset == offset,
              current.isLoadingEarlier else {
            return false
        }
        guard persistedTranscriptWindowOwnershipIsCurrent(current) else {
            // The armed window survived untouched but the conversation
            // moved on underneath it (e.g. activeSessionId cleared by a
            // disconnect). Discard the response whole AND release the
            // single-flight flag so the affordance can re-arm later — a
            // replaced window never reaches this branch.
            current.isLoadingEarlier = false
            persistedTranscriptWindow = current
            return false
        }
        current.isLoadingEarlier = false
        defer { persistedTranscriptWindow = current }

        switch outcome {
        case .payload(let response):
            guard let rawRows = Self.persistedMessageRows(in: response) else {
                // A malformed page is a backfill dead end, not a chat
                // failure: stop offering older pages rather than erroring
                // the already-hydrated conversation.
                sessionCatalogLog.debug("Older-page backfill for \(wireSessionId, privacy: .private(mask: .hash)) returned a malformed payload; retiring the affordance")
                current.canLoadEarlier = false
                return false
            }
            // Response ownership: the page must still describe THIS
            // conversation. The SAME centralized identity rule decides —
            // the echoed session_id plays the role of the checked
            // conversation — so an echo is accepted exactly when it is a
            // transaction-captured identity of this window or a
            // catalog-proven alias of one. Never a foreign session's rows;
            // a foreign response neither normalizes into the transcript
            // nor advances coverage.
            if let returnedId = Self.resolvedSessionId(in: response),
               !returnedId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !PersistedTranscriptWindow.ownershipHolds(
                 window: current,
                 conversationSessionIds: [returnedId],
                 profile: current.profile,
                 windowAliasIds: catalogAliasIDs(for: current.trustedSessionIDs),
                 conversationAliasIds: knownSessionIDs(for: returnedId)
               ) {
                sessionCatalogLog.debug("Older-page backfill for \(wireSessionId, privacy: .private(mask: .hash)) returned foreign session \(returnedId, privacy: .private(mask: .hash)); discarding and retiring the affordance")
                current.canLoadEarlier = false
                return false
            }
            let fetchedRowCount = rawRows.count
            let page = PersistedTranscriptPagination.parse(response, rawRowCount: fetchedRowCount)
            // Only pages still answering under the tail contract may splice
            // into the transcript: a response whose echo lost `order=latest`
            // carries oldest-anchored rows with unknown window semantics,
            // and prepending them would break chronology. That response
            // retires the affordance instead.
            guard let page, page.honorsTailContract else {
                sessionCatalogLog.debug("Older-page backfill for \(wireSessionId, privacy: .private(mask: .hash)) lost the tail contract; retiring the affordance")
                current.canLoadEarlier = false
                return false
            }
            // Overlap dedup keys on the durable persisted row ID. A page
            // whose rows lack one would normalize to page-local positional
            // IDs that cannot survive across pages — refuse it before it can
            // silently corrupt dedup.
            guard PersistedTranscriptWindow.rowsHaveDurableIdentity(rawRows) else {
                sessionCatalogLog.debug("Older-page backfill for \(wireSessionId, privacy: .private(mask: .hash)) returned rows without durable IDs; retiring the affordance")
                current.canLoadEarlier = false
                return false
            }
            var didPrepend = false
            var foldedPageStart: (heldIDs: Set<String>, callCardID: String)?
            let startBeforePage = messages.first.map {
                PersistedTranscriptWindowState.LoadedPageStart(
                    firstRowID: $0.id,
                    nextOffset: offset,
                    hasBackfilledPrefix: current.hasBackfilledPrefix
                )
            }
            if fetchedRowCount > 0 {
                let normalizedPage = MessageNormalizer.normalizeMessages(
                    rawRows.map(AnyCodable.from),
                    imageScope: Self.transcriptImageScope(in: response, sessionId: wireSessionId, profile: profile)
                )
                // A page boundary can split a tool call from its result row.
                // Fold any trailing call cards back together with the
                // matching held result cards by durable tool-call identity
                // before prepending, so one logical tool run never renders
                // as an orphan call card plus a duplicate standalone result.
                let (olderPage, foldedFromHeld) = PersistedTranscriptWindow.reconcilingToolCallsAcrossBoundary(
                    olderPage: normalizedPage,
                    held: messages
                )
                let merged: [ChatMessage]?
                if foldedFromHeld > 0 {
                    // The folded result rows go; a page start on one moves
                    // to the call card that took it in (issue 1828).
                    foldedPageStart = PersistedTranscriptWindow.foldedPageStart(
                        olderPage: olderPage,
                        foldedHeld: messages.prefix(foldedFromHeld)
                    )
                    let remainingHeld = messages.dropFirst(foldedFromHeld)
                    if remainingHeld.isEmpty {
                        // Every held row folded into the adjusted page (the
                        // stale-response guard already proved this window is
                        // current): the folded page itself is the whole
                        // transcript. Never fall back to the unfolded page
                        // here — that would resurrect the duplicate the fold
                        // just removed.
                        merged = olderPage.isEmpty ? nil : olderPage
                    } else {
                        merged = PersistedTranscriptWindow.prepending(olderPage, onto: Array(remainingHeld))
                    }
                } else {
                    merged = nil
                }
                if let merged {
                    messages = merged
                    didPrepend = true
                } else if let plain = PersistedTranscriptWindow.prepending(normalizedPage, onto: messages) {
                    messages = plain
                    didPrepend = true
                }
            }
            if didPrepend {
                if let replaced = Self.replacingSavedReviews(in: messages) {
                    messages = replaced
                }
                // The visible transcript now starts with backfilled rows.
                // The reconcile graft relies on this explicit fact to keep
                // preserving the prefix across repeated reconciles — the
                // network coverage reset below erases the offset evidence
                // after the first one.
                current.hasBackfilledPrefix = true
            }
            // A full page means older history may still exist; a short or
            // empty page marks the transcript fully backfilled and retires
            // the affordance. The offset advances by the fetched row count
            // either way, which self-corrects drift: a page that deduped to
            // nothing still moves the next request past the already-held
            // rows.
            current.nextOffset = offset + fetchedRowCount
            current.canLoadEarlier = fetchedRowCount > 0
                && page.mayHaveOlderRows(fetchedRowCount: fetchedRowCount)
            if didPrepend, let first = messages.first {
                if current.loadedPageStarts.isEmpty, let startBeforePage {
                    current.loadedPageStarts.append(startBeforePage)
                }
                if let foldedPageStart {
                    current.loadedPageStarts = PersistedTranscriptWindow.movingPageStarts(
                        current.loadedPageStarts,
                        off: foldedPageStart.heldIDs,
                        onto: foldedPageStart.callCardID
                    )
                }
                current.loadedPageStarts.append(.init(
                    firstRowID: first.id,
                    nextOffset: current.nextOffset,
                    hasBackfilledPrefix: true
                ))
            }
            return didPrepend
        case .unavailable:
            // The history source went away mid-conversation; there is no
            // older page to offer.
            current.canLoadEarlier = false
            return false
        case .failed(let error):
            // Only a structurally gone history source retires the
            // affordance; transient trouble — rate limits, slow bounded
            // reads, a temporarily cold bridge — stays retryable through
            // another explicit tap. A failed backfill never loops on its
            // own.
            sessionCatalogLog.debug("Older-page backfill failed for \(wireSessionId, privacy: .private(mask: .hash)): \(LogRedaction.message(error), privacy: .public)")
            current.canLoadEarlier = !Self.historySourceIsUnavailable(error)
            return false
        }
    }

    private func fetchOlderTranscriptPage(
        sessionId: String,
        profile: String,
        offset: Int
    ) async -> PersistedTranscriptFetchOutcome {
        if let loadEarlierTranscriptPage = chatResumeLifecycleOperations.loadEarlierTranscriptPage {
            return await loadEarlierTranscriptPage(sessionId, profile, offset)
        }
        // Backfill never falls through to the initial-hydration seam: that
        // seam cannot carry the offset, and a test wiring mistake would
        // otherwise become a silent always-duplicate affordance.
        guard let bridge = dashboardTicketBridge else { return .unavailable }
        do {
            return .payload(try await bridge.requestJSON(path: Self.sessionMessagesPath(
                sessionId: sessionId,
                profile: profile,
                query: PersistedTranscriptPagination.tailQuery(offset: offset)
            )))
        } catch {
            return .failed(error)
        }
    }

    /// Catalog alias knowledge for a set of session identities: every ID
    /// the live catalog groups with any of them (an unknown ID expands to
    /// just itself).
    private func catalogAliasIDs(for sessionIds: Set<String>) -> Set<String> {
        sessionIds.reduce(into: Set<String>()) { expanded, sessionId in
            expanded.formUnion(knownSessionIDs(for: sessionId))
        }
    }

    /// Ownership gate for the persisted-history window: the window must
    /// belong to the conversation that is actually active. The window's
    /// transaction-captured identities (requested, resolved stored, runtime)
    /// are the primary truth — `applyChatResume` re-homes `activeSessionId`
    /// to the runtime ID long before the catalog learns the alias — while
    /// catalog alias knowledge remains a compatibility source only.
    func persistedTranscriptWindowOwnershipIsCurrent(
        _ window: PersistedTranscriptWindowState
    ) -> Bool {
        guard let activeId = activeSessionId else { return false }
        // The ownership comparison uses the ACTIVE CONVERSATION's profile
        // scope, not the dashboard's: a canonical Bot Chat's window is
        // stamped with the bot profile, and must stay actionable (for
        // "Load earlier messages") while that chat is on screen.
        return PersistedTranscriptWindow.ownershipHolds(
            window: window,
            conversationSessionIds: [activeId],
            profile: persistedTailProfile(for: activeId),
            windowAliasIds: catalogAliasIDs(for: window.trustedSessionIDs),
            conversationAliasIds: knownSessionIDs(for: activeId)
        )
    }

    /// Whether "Load earlier messages" may be offered AND executed right
    /// now: a hydrated, non-empty transcript whose persisted-history window
    /// still has an older page and belongs to the conversation that is
    /// actually active. The single ownership truth for the ChatView
    /// affordance and the `loadEarlierMessages` action, so the control can
    /// never render for a window the action would reject (the production
    /// no-op regression).
    var canLoadEarlierMessagesForActiveConversation: Bool {
        guard let window = persistedTranscriptWindow,
              window.canLoadEarlier,
              !messages.isEmpty,
              persistedTranscriptWindowOwnershipIsCurrent(window) else {
            return false
        }
        return true
    }

    /// The endpoint may resolve a runtime ID to its stored session ID. Accept
    /// any identifier already known for the selected session, just as Desktop
    /// verifies its REST prefetch before using it for a resumed transcript.
    func transcriptMatchesSession(
        _ transcript: PersistedSessionTranscript,
        requestedSessionId: String,
        resumedSessionId: String
    ) -> Bool {
        guard let returnedId = transcript.resolvedSessionId,
              !returnedId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }

        var knownIds = Set([requestedSessionId, resumedSessionId])
        if let session = sessions.first(where: { session in
            let ids = [session.id] + session.alternateIds
            return ids.contains(requestedSessionId) || ids.contains(resumedSessionId)
        }) {
            knownIds.insert(session.id)
            knownIds.formUnion(session.alternateIds)
        }
        return knownIds.contains(returnedId)
    }
}
