//
//  AppState+YoloAndReasoning.swift
//  Conduit
//
//  A session's YOLO mode and reasoning effort, written to Hermes. Moved
//  out of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - YOLO mode and reasoning effort

    func toggleYolo(context: ComposerSubmissionContext? = nil) async {
        let submissionContext = context ?? composerSubmissionContext()
        _ = await setYoloMode(!runtime.yolo, context: submissionContext)
    }

    @discardableResult
    func setYoloMode(
        _ enabled: Bool,
        context: ComposerSubmissionContext? = nil
    ) async -> Bool {
        let failure = await setYoloModeReportingFailure(enabled, context: context)
        if let message = failure?.message {
            errorMessage = message
        }
        return failure == nil
    }

    enum ReasoningWriteResult: Equatable {
        case applied
        /// The chat changed while the write was in flight; the current
        /// chat's level is untouched.
        case abandoned
        case failed(String)
    }

    /// Sets the live agent's reasoning effort ("none" turns it off). Hermes
    /// applies it at once, so the composer chip and the Model sheet send it
    /// on tap.
    func setReasoningEffort(_ effort: String) async -> ReasoningWriteResult {
        guard !isWritingReasoningEffort else { return .abandoned }
        guard let client, let sessionId = activeSessionId else {
            return .failed(AppLocalization.string("Not connected to a conversation."))
        }
        isWritingReasoningEffort = true
        defer { isWritingReasoningEffort = false }
        do {
            try await client.setReasoning(sessionId, effort: effort)
        } catch {
            return .failed(UserFacingError.message(for: error))
        }
        // Another chat's chip must not take this one's level.
        guard activeSessionId == sessionId else { return .abandoned }
        runtime.reasoningEffort = effort == "none" ? "" : effort
        return .applied
    }

    /// Why a session YOLO write did not apply. `message` is nil when the
    /// write was abandoned (stale submission, no session) rather than refused.
    struct YoloWriteFailure: Equatable {
        let message: String?
    }

    /// `setYoloMode` without the composer banner: the caller decides where
    /// the failure is shown (the Model sheet covers the banner).
    func setYoloModeReportingFailure(
        _ enabled: Bool,
        context: ComposerSubmissionContext? = nil
    ) async -> YoloWriteFailure? {
        let submissionContext = context ?? composerSubmissionContext()
        guard isCurrentComposerSubmission(submissionContext) else { return YoloWriteFailure(message: nil) }
        guard runtime.approvalsMode?.lowercased() != "off" else {
            // Hermes auto-approves globally under approvals.mode == "off"; the
            // per-session write is a server-side no-op, and persisting an
            // override here would silently resurface when the profile mode
            // changes back. Send nothing and keep the effective floor state.
            runtime.yolo = true
            return nil
        }
        guard let client, let sessionId = activeSessionId else { return YoloWriteFailure(message: nil) }
        let persistedSessionID = canonicalSessionID(for: sessionId) ?? sessionId
        // Ownership is captured ONCE, before the await, from the originating
        // submission profile. begin and the deferred cleanup therefore touch
        // the exact same keys even if the active profile/session changes
        // while the RPC is suspended (profile-switch bookkeeping leak).
        let writeKeys = sessionYoloKeys(
            profile: submissionContext.profile,
            sessionIDs: [sessionId, persistedSessionID]
        )
        beginSessionYoloWrite(keys: writeKeys)
        defer { endSessionYoloWrite(keys: writeKeys) }
        do {
            if let setSessionYolo = chatResumeLifecycleOperations.setSessionYolo {
                try await setSessionYolo(client, sessionId, enabled)
            } else {
                try await client.setSessionYolo(sessionId, enabled: enabled)
            }
            // Hermes accepted the setting. Avoid publishing it into a new
            // session if the composer origin was handed off while awaiting.
            guard isCurrentComposerSubmission(submissionContext) else { return nil }
            sessionYoloStore.setOverride(
                enabled,
                for: activeProfile,
                sessionID: persistedSessionID
            )
            recordSessionYoloWrite(for: [sessionId, persistedSessionID])
            lastReportedSessionYolo = enabled
            runtime.yolo = enabled
            return nil
        } catch {
            guard isCurrentComposerSubmission(submissionContext) else { return YoloWriteFailure(message: nil) }
            return YoloWriteFailure(
                message: AppLocalization.string("Unable to change YOLO mode: \(UserFacingError.message(for: error))")
            )
        }
    }

    /// Re-assert a persisted per-session YOLO override after a resume.
    ///
    /// The Hermes gateway keeps the per-session YOLO flag in memory only and
    /// never persists it (unlike the CLI), so a gateway restart or rebuilt
    /// agent forgets the flag and reverts to the profile default. Re-sending
    /// `config.set` restores the user's explicit choice so the server keeps
    /// honoring it. No-op when the profile approval mode is already "off" (the
    /// flag is then moot), when there is no stored override, when the snapshot
    /// does not report a session-level yolo (unknown is not a disagreement),
    /// or when the server's reported value already matches the override.
    /// Failure is non-fatal: the local override still governs the indicator
    /// and the next resume retries.
    func reassertSessionYolo(
        for sessionId: String,
        snapshot: SessionRuntimeSnapshot,
        using client: HermesClient
    ) async {
        // Use the same resolved floor source applyRuntime just updated (the
        // snapshot's value when present, else the last-known mode) so the
        // floor decision and the re-assert decision can never diverge when a
        // snapshot omits approvals_mode.
        guard runtime.approvalsMode?.lowercased() != "off" else { return }
        let persistedSessionID = canonicalSessionID(for: sessionId) ?? sessionId
        // A user write awaiting its RPC has not reached the store yet;
        // re-asserting now could read the pre-toggle override and land after
        // the user's write, leaving the server on the stale value. Skip — the
        // user's write settles the server and the next resume reconciles.
        guard !hasInFlightSessionYoloWrite(sessionIDs: [persistedSessionID, sessionId]) else { return }
        guard let override = sessionYoloStore.storedOverride(
            for: activeProfile,
            sessionIDs: [persistedSessionID, sessionId]
        ) else { return }
        // A snapshot that omits the session-level yolo is unknown, not a
        // disagreement; re-asserting on every resume for gateways that omit the
        // field would be pure churn. The gateway's session.info projection
        // reports yolo as a boolean, so a real conflict is always visible.
        guard let reportedYolo = snapshot.yolo, reportedYolo != override else { return }
        do {
            if let setSessionYolo = chatResumeLifecycleOperations.setSessionYolo {
                try await setSessionYolo(client, sessionId, override)
            } else {
                try await client.setSessionYolo(sessionId, enabled: override)
            }
            recordSessionYoloWrite(for: [sessionId, persistedSessionID])
        } catch {
            sessionYoloLog.error(
                "Failed to re-assert session YOLO override \(override, privacy: .public) for \(sessionId, privacy: .private(mask: .hash)): \(LogRedaction.message(error), privacy: .public)"
            )
        }
    }
}
