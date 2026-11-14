//
//  AppState+SendMessage.swift
//  Conduit
//
//  Sending a message: sendMessage, resending in place of a lost empty
//  chat, send failures, and settling a prompt whose delivery is unknown
//  against the transcript. Moved out of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Sending a message

    /// The first message of an empty chat made here was refused because
    /// Hermes no longer has the chat: it goes, as typed, into a fresh chat
    /// opened in its place (replaceLostEmptyNewChat). A second refusal
    /// there is shown as any failed send is.
    private func resendInPlaceOfLostEmptyChat(
        _ text: String,
        attachments: [Attachment],
        context: ComposerSubmissionContext,
        queued: Bool,
        lostSessionIDs: Set<String>,
        using client: HermesClient
    ) async -> Bool {
        // The fresh chat's create clears the transcript, this row with it;
        // a failed create leaves it, as any failed send does.
        let token = beginReconciliation()
        turnState = .synchronizing
        guard await replaceLostEmptyNewChat(
            lostSessionIDs: lostSessionIDs,
            using: client,
            profile: activeProfile,
            token: token
        ) else {
            // The create's own failure is what the composer shows; the
            // words come back as for any failed send.
            if token == shownChat.reconciliationToken, turnState == .synchronizing { turnState = .idle }
            await recoverComposerSubmission(using: context)
            return false
        }
        return await sendMessage(text, attachments: attachments, queued: queued, afterReplacingLostChat: true)
    }

    /// `queued` is Queue (#842): Hermes keeps the message as the next turn
    /// while one runs. That turn's reply goes on streaming meanwhile.
    func sendMessage(
        _ text: String,
        attachments: [Attachment] = [],
        context: ComposerSubmissionContext? = nil,
        queued: Bool = false,
        afterReplacingLostChat: Bool = false
    ) async -> Bool {
        let submissionContext = context ?? composerSubmissionContext()
        guard isCurrentComposerSubmission(submissionContext) else { return false }
        guard let client, let sessionId = activeSessionId else { return false }
        // A rewind counting this chat's turns (rewindLastTurns): a message
        // now would be the turn it takes back.
        guard !isRewindingTurns else { return false }
        // Images staged for a Queue this Hermes refuses would ride on the
        // next turn instead, so they never go up.
        if queued, !attachments.isEmpty, client.refusesQueuedPrompts {
            showSendFailure(HermesClient.QueueUnsupportedError.attachmentsMessage)
            return false
        }
        let joinsRunningTurn = queued && turnState.isRunning
        continueOpenConnections(beforeSendingIn: sessionId)
        cancelChatResumeRestoration()
        if !joinsRunningTurn { resetResponseHapticTurn() }
        // Bot Mode composer middleware (upstream `mention-middleware`):
        // @mention identification. The canonical-forever-chat `/new` guard
        // runs in `executeSlashCommand`, which `submitComposer` reaches
        // first. The OUTBOUND text carries the transformation; the optimistic
        // bubble and the durable gateway row stay identical, so hydration
        // never rewrites what the user already saw.
        let outboundText = mentionAnnotatedOutboundText(text)
        let surface: String? = spokenSubmissionText == text ? Self.spokenPromptSurface : nil
        // Durable before/after identity for ambiguous-delivery recovery:
        // positively-proven persisted row ids (from the latest accepted
        // hydration) plus whether the conversation holds rows whose persisted
        // identity is unproven, so a later bounded tail read can decide
        // whether the submitted turn landed even when the registry has gone
        // idle/absent.
        let submissionBaseline = PromptTranscriptBaseline(
            durableIDs: shownChat.durablePersistedRowIDs,
            holdsUnprovenRows: messages.contains { !shownChat.durablePersistedRowIDs.contains($0.id) }
        )
        // The locally-owned turn marker's ordering baseline, frozen BEFORE
        // the optimistic append changes the transcript below: the persisted
        // ordering FRONTIER, which may already run past the visible durable
        // tail (a prior freshness read can have positively observed the
        // previous turn's durable twins without adopting them visibly).
        let preSubmitOrderingBaseline = shownChat.persistedOrderingFrontier.baseline
        // The identity under probe must be captured BEFORE any await — never
        // re-derived from the mutable active session afterwards.
        let submissionSessionIDs = acceptedIdentitySessionIDs(forRequested: sessionId)
        // A first message into an empty chat made here: if Hermes has lost
        // the chat, it goes into a fresh one instead (once).
        let sendsIntoEmptyNewChat = !afterReplacingLostChat
            && openChatIsEmptyNewChat(submissionSessionIDs)
        // A fix for Hermes, when the user shares location while talking to
        // it: taken alongside the upload and waited for briefly before the
        // prompt goes, never failing or holding up the send.
        let locationShare = LocationSharingController.shared.shareBeforeSending(.message)
        // The calendar and phone status Hermes may read for this message,
        // and any change it asked for since: never holding up the send.
        Task { await runPhoneSync(reason: .messageSent) }

        let userMessage = ChatMessage(
            id: "local-\(Date().timeIntervalSince1970)",
            role: .user,
            content: outboundText,
            rawContent: nil,
            timestamp: Self.localTimestamp(),
            author: nil,
            attachments: attachments.isEmpty ? nil : attachments
        )
        // Mid-turn ordering rule: the outgoing bubble must not land below a
        // still-live reasoning card's eventual commit.
        settleReasoningSegmentIntoTranscript()
        // An earlier send's failure, shown under the composer, is over.
        if errorMessage != nil { errorMessage = nil }
        sendFailureShown = nil
        messages.append(userMessage)
        requestChatScrollToLatest()
        cacheMessagePresentation(for: [sessionId])
        if !joinsRunningTurn { clearStreamingText() }
        turnState = .running

        // Images this send staged, taken back if it fails: left staged, they
        // would ride on the chat's next message (a Queue's, or on the
        // session authority any send's, which names its staged pictures).
        var stagedImagePaths: [String] = []
        // Every file that isn't an image (PDFs included) is staged as a file,
        // like Hermes Desktop does: Hermes' PDF route needs poppler on the
        // host and bounced the send without it. Whether the model can read
        // a file is up to the agent; the send never fails over its type.
        // Returns the staged image's path, when Hermes names it.
        let attachImageBytes = chatResumeLifecycleOperations.attachImageBytes
        let attachImage: @MainActor (HermesClient, String, String, String) async throws -> String? = {
            client, session, base64, filename in
            if let attachImageBytes {
                try await attachImageBytes(client, session, base64, filename)
                return nil
            }
            return try await client.attachImage(session, base64: base64, filename: filename)
        }
        let attachFile: @MainActor (HermesClient, String, String, String) async throws -> String? =
            chatResumeLifecycleOperations.attachFileData ?? { client, session, dataUrl, name in
                try await client.attachFile(session, dataUrl: dataUrl, name: name)
            }
        var fileReferences: [String] = []
        for attachment in attachments {
            do {
                let fileReference: String?
                var stagedAsFile = false
                if let upload = chatResumeLifecycleOperations.uploadAttachment {
                    fileReference = try await upload(client, sessionId, attachment)
                } else if attachment.kind == .image {
                    // A large photo goes resized (#1265).
                    let picture = await AttachmentHelper.pictureForHermes(attachment)
                    let base64 = picture?.base64 ?? ""
                    guard isCurrentComposerSubmission(submissionContext) else { throw CancellationError() }
                    guard let picture, !base64.isEmpty else { throw AttachmentError.unreadableFile(attachment.name) }
                    do {
                        let stagedPath = try await attachImage(client, sessionId, base64, picture.filename)
                        if let stagedPath { stagedImagePaths.append(stagedPath) }
                        fileReference = nil
                    } catch let error as RpcError where Self.isImageAttachRefusal(error) {
                        // Hermes won't take it as an image (a format it
                        // doesn't list, or past its image size cap): it
                        // still goes up, as a file.
                        guard isCurrentComposerSubmission(submissionContext) else { throw CancellationError() }
                        stagedAsFile = true
                        fileReference = try await attachFile(
                            client,
                            sessionId,
                            AttachmentHelper.dataUrl(base64: base64, mimeType: picture.mimeType),
                            picture.filename
                        )
                    }
                } else {
                    let dataUrl = await AttachmentHelper.toDataUrl(attachment)
                    guard isCurrentComposerSubmission(submissionContext) else { throw CancellationError() }
                    guard !dataUrl.isEmpty else { throw AttachmentError.unreadableFile(attachment.name) }
                    stagedAsFile = true
                    fileReference = try await attachFile(client, sessionId, dataUrl, attachment.name)
                }
                guard isCurrentComposerSubmission(submissionContext) else { throw CancellationError() }
                if let fileReference {
                    fileReferences.append(fileReference)
                } else if stagedAsFile {
                    // Staged, but the reply named no path to point the agent
                    // at: the send goes on without telling it.
                    lifecycleLog.notice(
                        "file.attach gave no reference; the prompt can't name the file session=\(sessionId, privacy: .private(mask: .hash))"
                    )
                }
            } catch {
                // Images this send already staged would ride on a later
                // turn; a superseded submission (CancellationError) too.
                for path in stagedImagePaths {
                    try? await client.detachImage(sessionId, path: path)
                }
                guard isCurrentComposerSubmission(submissionContext) else { return false }
                if sendsIntoEmptyNewChat, HermesClient.isSessionNotFoundError(error) {
                    return await resendInPlaceOfLostEmptyChat(
                        text, attachments: attachments, context: submissionContext, queued: queued,
                        lostSessionIDs: submissionSessionIDs, using: client
                    )
                }
                // A file can't wait as text: it comes back, and the
                // reconnect starts now all the same.
                noteDropFoundBySend(error, client: client)
                showSendFailure(AppLocalization.string("Attachment failed: \(UserFacingError.message(for: error))"))
                await recoverComposerSubmission(using: submissionContext)
                return false
            }
        }

        // The bubble keeps the typed text; Hermes gets the files' references
        // ahead of it.
        let promptText = Self.promptText(outboundText, fileReferences: fileReferences)
        // Where in Conduit this was sent from, for its turn's line (#888).
        let surfaceReportedOn = activeDashboardID
        let surfaceReport = reportTurnSurface(
            submissionTurnSurface.flatMap { $0.text == text ? $0.surface : nil }
                ?? messageTurnSurface(spoken: surface == Self.spokenPromptSurface),
            runtimeSessionID: sessionId,
            text: promptText
        )
        await locationShare?.value
        await surfaceReport?.value
        // Events that arrive while prompt.submit is in flight are held for
        // the turn's Live Activity (#605), which starts once it's accepted.
        if !joinsRunningTurn {
            LiveTurnActivities.shared?.turnSubmitting(sessionIDs: submissionSessionIDs)
        }
        // Taken before the send waits: a lifecycle edge that lands while
        // it's in flight is newer than anything the receipt says.
        let preSendRevision = shownChat.turnLifecycleEvidence.revision
        do {
            let outcome: PromptSubmissionOutcome
            if queued, let sendQueuedPrompt = chatResumeLifecycleOperations.sendQueuedPrompt {
                outcome = try await sendQueuedPrompt(client, sessionId, promptText)
            } else if let sendPrompt = chatResumeLifecycleOperations.sendPrompt {
                outcome = try await sendPrompt(client, sessionId, promptText)
            } else {
                outcome = try await client.sendPrompt(
                    sessionId, text: promptText, surface: surface,
                    voiceTurn: surface == Self.spokenPromptSurface,
                    queued: queued,
                    titlePreview: PastedText.titlePreview(in: attachments)
                )
            }
            // The gateway accepted the prompt. A session handoff may have
            // happened while the RPC was suspended, but that does not turn a
            // remotely successful send into a local draft failure. All local
            // state writes below are submission-owned: an operation started
            // for session A must never mutate turn state that now belongs to
            // session B.
            lifecycleLog.notice(
                "prompt.submit outcome=\(Self.promptOutcomeLogValue(outcome), privacy: .public) session=\(sessionId, privacy: .private(mask: .hash))"
            )
            if chatTakeoverMatches(sessionId) {
                dismissChatTakeover()
            }
            if chatTakeoverAutomaticSessionID == chatTakeoverGuardKey(sessionId) {
                chatTakeoverAutomaticSessionID = nil
            }
            if isCurrentComposerSubmission(submissionContext) {
                if outcome.isBusySubmission {
                    // Hermes applied its busy policy, which proves THIS
                    // session was RUNNING when the prompt landed — the local
                    // state was stale. Adopt the authoritative busy state so
                    // the composer keeps offering the configured busy action
                    // and the next submission is routed correctly.
                    shownChat.turnLifecycleEvidence = TurnLifecycleEvidence(
                        revision: shownChat.turnLifecycleEvidence.revision &+ 1,
                        running: true
                    )
                    turnState = .running
                }
                turnStateIsStale = false
                // A send docked behind a turn a restart cut off starts no
                // turn: the chat reads idle, so the next message queues
                // rather than steers. A lifecycle edge since the send
                // went (a turn that started meanwhile) wins.
                func idleIfHeldByLostTurn() {
                    guard client.chatIsHeldByLostTurn(sessionId),
                          shownChat.turnLifecycleEvidence.revision == preSendRevision,
                          isCurrentComposerSubmission(submissionContext) else { return }
                    turnState = .idle
                }
                switch outcome {
                case .accepted:
                    if client.speaksSessionAuthority, let admission = HermesClient.admittedAdmissionID(for: sessionId) {
                        noteOwnSend(admissionID: admission, rowID: userMessage.id)
                        // A queue push that came before this reply already
                        // listed it: read that list again now it's known as ours.
                        if authorityQueue.sessionID.map({ $0 == sessionId || knownSessionIDs(for: sessionId).contains($0) }) == true {
                            adoptOwnQueuedSends(authorityQueue.rows)
                            if messages.contains(where: { $0.id == userMessage.id }) == false {
                                shownChat.locallyOwnedInFlightTurn = nil
                                idleIfHeldByLostTurn()
                                break
                            }
                        }
                        // A turn a restart cut off holds the chat: the send
                        // waits behind it in the dock, and no turn starts.
                        if !authorityQueue.lost.isEmpty, !shownChat.startedAdmissionIDs.contains(admission),
                           let queueChat = authorityQueue.sessionID,
                           queueChat == sessionId || knownSessionIDs(for: sessionId).contains(queueChat) {
                            shownChat.locallyOwnedInFlightTurn = nil
                            moveQueuedSendToDock(rowID: userMessage.id, sessionID: sessionId)
                            idleIfHeldByLostTurn()
                            break
                        }
                    }
                    // The turn in flight is now provably Conduit's own: record
                    // the optimistic user row so a later foreground freshness
                    // check can prove same-turn continuity WITHOUT demanding a
                    // durable id for a row the gateway has not persisted yet.
                    shownChat.locallyOwnedInFlightTurn = LocallyOwnedInFlightTurn(
                        sessionIDs: submissionSessionIDs,
                        optimisticUserRowID: userMessage.id,
                        preSubmitOrderingBaseline: preSubmitOrderingBaseline
                    )
                    // The new turn's progress on the Lock Screen (#605).
                    LiveTurnActivities.shared?.turnStarted(
                        sessionIDs: submissionSessionIDs,
                        primaryID: sessionId,
                        linkID: liveActivityLinkSessionID(for: sessionId),
                        title: activeSessionTitle,
                        profile: activeProfile,
                        // A Bot Chat's card names its bot and wears its color, as the chat does.
                        profileName: conversationAgentIdentity.name,
                        glowHex: profileGlowColors()[conversationIdentityProfile]?.hex
                            ?? profileGlowTint(conversationIdentityProfile).flatMap { ProfileGlowRGB(UIColor($0).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))?.hex },
                        dashboardID: activeDashboardID?.uuidString
                    )
                case .queued:
                    // Hermes normally drains queued input as a later full turn,
                    // but `_enqueue_prompt` may drop an in-flight self-duplicate
                    // or coalesce several text submissions into one envelope.
                    // Therefore the typed outcome proves no exact boundary
                    // count. Require one later bounded observation: no new user
                    // row clears it; any user row is adopted authoritatively.
                    shownChat.locallyOwnedInFlightTurn = nil
                    recordLocalOrderingDebt(
                        sessionIDs: submissionSessionIDs,
                        baseline: preSubmitOrderingBaseline,
                        expectedUserTurnIncrement: 0,
                        allowTrailingRowsWithoutNewUserBoundary: true
                    )
                    // On the session authority it waits in the chat's queue,
                    // where the dock above the composer shows it.
                    if client.speaksSessionAuthority {
                        moveQueuedSendToDock(rowID: userMessage.id, sessionID: sessionId)
                    }
                case .redirected:
                    // Hermes replaces/corrects the current live model request;
                    // it does not create an independent canonical user turn —
                    // so ZERO new user boundaries are expected. But the
                    // mutated turn can keep persisting assistant/tool rows
                    // AFTER the current ordering frontier, so a redirect still
                    // owes one final-tail observation (the settled-tail shape):
                    // the next operation freezing a new-turn baseline performs
                    // one bounded read — a non-user-only suffix advances the
                    // frontier and clears the obligation, while any canonical
                    // user boundary proves a later/new turn exists and forces
                    // an authoritative reconcile before the send.
                    shownChat.locallyOwnedInFlightTurn = nil
                    recordLocalOrderingDebt(
                        sessionIDs: submissionSessionIDs,
                        baseline: preSubmitOrderingBaseline,
                        expectedUserTurnIncrement: 0,
                        allowTrailingRowsWithoutNewUserBoundary: true
                    )
                case .steered:
                    // Hermes normally injects this into the current run without
                    // a canonical user row. A steer arriving after the final
                    // tool batch is returned as `pending_steer`, however, and
                    // requeued as a full next turn. As with `.queued`, the typed
                    // outcome proves no exact boundary count, so observe once
                    // before the next ordinary local turn and reconcile if a
                    // promoted steer produced a user boundary.
                    shownChat.locallyOwnedInFlightTurn = nil
                    markOptimisticRowAsSteer(userMessage.id)
                    recordLocalOrderingDebt(
                        sessionIDs: submissionSessionIDs,
                        baseline: preSubmitOrderingBaseline,
                        expectedUserTurnIncrement: 0,
                        allowTrailingRowsWithoutNewUserBoundary: true
                    )
                }
            }
            return true
        } catch {
            // No turn of it is coming: the same words sent from another
            // client there mustn't take its line.
            if surfaceReport != nil {
                discardTurnSurface(runtimeSessionID: sessionId, text: promptText, after: error, reportedOn: surfaceReportedOn)
            }
            // Images staged for a send that didn't land would ride on a
            // later turn. One Hermes took was already claimed by it, so
            // taking it back then changes nothing.
            for path in stagedImagePaths {
                try? await client.detachImage(sessionId, path: path)
            }
            if error is HermesClient.QueueUnsupportedError, !attachments.isEmpty {
                guard isCurrentComposerSubmission(submissionContext) else { return false }
                showSendFailure(HermesClient.QueueUnsupportedError.attachmentsMessage)
                await recoverComposerSubmission(using: submissionContext)
                return false
            }
            guard isCurrentComposerSubmission(submissionContext) else {
                // Its chat was left; the reply may only have been lost.
                if Self.isAmbiguousPromptDelivery(error) { shownChat.composerSubmissionsOfUnknownDelivery.append(submissionContext) }
                return false
            }
            if sendsIntoEmptyNewChat, HermesClient.isSessionNotFoundError(error) {
                return await resendInPlaceOfLostEmptyChat(
                    text, attachments: attachments, context: submissionContext, queued: queued,
                    lostSessionIDs: submissionSessionIDs, using: client
                )
            }
            if keepComposerSendForReconnect(
                after: error, text: text, attachments: attachments, queued: queued,
                surface: surface, rowID: userMessage.id, client: client
            ) {
                return true
            }
            if Self.isAmbiguousPromptDelivery(error) {
                lifecycleLog.notice(
                    "prompt.submit ambiguous (\(error.localizedDescription, privacy: .private)); querying authoritative state session=\(sessionId, privacy: .private(mask: .hash))"
                )
                let (resolution, reconnected, recoveryEvidence) = await reconcileAmbiguousPromptSubmission(
                    requestedSessionID: sessionId,
                    acceptedSessionIDs: submissionSessionIDs,
                    baseline: submissionBaseline,
                    // Exactly what prompt.submit sent (a mention annotation
                    // changes it, staged files' references lead it); the
                    // check projects it the way
                    // the persisted user row is shown.
                    submittedText: promptText,
                    submissionContext: submissionContext,
                    optimisticRowID: userMessage.id
                )
                // Ordering guard for the recovery STATE stamps: the recovery
                // captured the lifecycle revision at its registry
                // observation. A changed revision proves an authoritative
                // live edge (sessionBusy, settlement, interruption, error,
                // resume snapshot) arrived while the recovery awaited — that
                // evidence is NEWER and owns the UI. Plain turnState equality
                // cannot prove this: sendMessage stamped .running before
                // prompt.submit, so a newer sessionBusy(true) leaves the
                // value equal.
                //
                // Stamp authority and accepted-turn provenance are SEPARATE
                // facts. A changed revision suppresses the lifecycle stamps
                // but does NOT by itself erase this recovery's positive
                // proof that the submitted turn was accepted and is ours:
                // newer busy/running evidence leaves that ownership live,
                // while newer settled/idle evidence ends it (the evidence's
                // running half). Only the lifecycle stamps below are
                // revision-guarded; the acceptance decisions stay
                // authoritative either way.
                let recoveryMayStampLifecycle = shownChat.turnLifecycleEvidence.revision == recoveryEvidence.revision
                // Whether the NEWEST authoritative lifecycle edge still
                // reports the turn as running (a newest-edge bit, not
                // per-turn tracking — see TurnLifecycleEvidence). Only
                // decisive when the revision changed (newer evidence owns
                // the lifecycle state): a newer busy edge keeps the accepted
                // turn's local ownership live, a newer settled edge ends it.
                let newestEdgeReportsRunning = shownChat.turnLifecycleEvidence.running
                // Every write below is submission-owned: the guard is
                // re-checked inside each branch so a handoff during the
                // recovery awaits cannot leak state into the new session.
                switch resolution {
                case .acceptedRunning:
                    // Hermes accepted the submission and the turn is still
                    // live: keep the optimistic user row and the running turn,
                    // and never re-send the prompt.
                    if isCurrentComposerSubmission(submissionContext) {
                        if recoveryMayStampLifecycle {
                            turnState = .running
                            turnStateIsStale = false
                        }
                        // Provenance is independent of stamp authority:
                        // acceptedRunning POSITIVELY proves this submission
                        // was accepted and is the active turn. A newer busy
                        // edge that raced the probe owns the lifecycle state
                        // but does not erase that ownership — the marker must
                        // still be installed so a later foreground can prove
                        // same-turn continuity without a resume. Only newer
                        // settled/idle evidence ends live ownership.
                        if recoveryMayStampLifecycle || newestEdgeReportsRunning {
                            // Same proof as the ordinary success path: the
                            // turn in flight is provably Conduit's own
                            // submission. The anchor is intentionally the
                            // PRE-SEND capture even though ambiguity recovery
                            // may have re-hydrated the transcript in between:
                            // validation at use plus the anchor lookup at use
                            // neutralize any staleness.
                            shownChat.locallyOwnedInFlightTurn = LocallyOwnedInFlightTurn(
                                sessionIDs: submissionSessionIDs,
                                optimisticUserRowID: userMessage.id,
                                preSubmitOrderingBaseline: preSubmitOrderingBaseline
                            )
                        }
                    }
                    return true
                case .acceptedUnsettled:
                    // The durable transcript proves Hermes accepted the
                    // submission, but the registry reported `starting` —
                    // runtime present, liveness inconclusive (the agent build
                    // may still be arming around a committed turn). The
                    // submission stays accepted: never re-send, the optimistic
                    // row remains. But settlement is NOT proven: keep the turn
                    // running-like for composer routing, leave
                    // `turnStateIsStale` exactly as it stands (uncertainty is
                    // not cleared as though settlement were proven), and let
                    // the next authoritative registry/stream edge settle it.
                    lifecycleLog.notice(
                        "prompt.submit accepted (durable transcript); registry starting — liveness unresolved session=\(sessionId, privacy: .private(mask: .hash))"
                    )
                    if isCurrentComposerSubmission(submissionContext) {
                        if recoveryMayStampLifecycle {
                            turnState = .running
                        }
                        // Same provenance split as acceptedRunning: the
                        // durable row proves the submission was accepted. A
                        // newer busy edge keeps that ownership live; a newer
                        // settled edge ends it.
                        if recoveryMayStampLifecycle || newestEdgeReportsRunning {
                            shownChat.locallyOwnedInFlightTurn = LocallyOwnedInFlightTurn(
                                sessionIDs: submissionSessionIDs,
                                optimisticUserRowID: userMessage.id,
                                preSubmitOrderingBaseline: preSubmitOrderingBaseline
                            )
                        }
                    }
                    return true
                case .acceptedHeld:
                    // Taken, and waiting behind a cut-off turn (or cut off
                    // itself): its bubble is in the dock and nothing runs
                    // until the dock's Discard or Resend. The chat reads
                    // idle, so the next message queues rather than steers.
                    lifecycleLog.notice(
                        "prompt.submit accepted (authority queue); held, no turn running session=\(sessionId, privacy: .private(mask: .hash))"
                    )
                    if isCurrentComposerSubmission(submissionContext), recoveryMayStampLifecycle {
                        turnState = .idle
                    }
                    return true
                case .acceptedSettled:
                    // The durable transcript proves the submitted turn landed
                    // and settled (the registry had already gone idle/absent
                    // by the time recovery looked). The submission stays
                    // accepted: the composer remains cleared, nothing is
                    // restored, and the transcript converges on the next
                    // bounded refresh. That verification proved the turn
                    // persisted but did not re-anchor the ordering frontier,
                    // so an unobserved boundary leaves debt.
                    lifecycleLog.notice(
                        "prompt.submit accepted (durable transcript); turn settled session=\(sessionId, privacy: .private(mask: .hash))"
                    )
                    if isCurrentComposerSubmission(submissionContext) {
                        if recoveryMayStampLifecycle {
                            turnState = .idle
                            turnStateIsStale = false
                        }
                        // The marker is nil here (prompt.submit threw), but
                        // the durable transcript PROVED this submission's
                        // turn persisted: record its ordering debt from the
                        // frame-captured baseline so the next local turn
                        // anchors past it. Retained even when a newer edge
                        // owns the lifecycle state — the boundary was never
                        // positively observed, which stays true regardless of
                        // which edge is newest.
                        recordLocalOrderingDebt(
                            sessionIDs: submissionSessionIDs,
                            baseline: preSubmitOrderingBaseline
                        )
                        shownChat.locallyOwnedInFlightTurn = nil
                    }
                    return true
                case .notAccepted:
                    // Authoritative evidence shows Hermes did not accept the
                    // prompt: restore the unsent state exactly once below.
                    lifecycleLog.notice(
                        "prompt.submit not accepted (authoritative); restoring unsent state session=\(sessionId, privacy: .private(mask: .hash))"
                    )
                    if isCurrentComposerSubmission(submissionContext),
                       recoveryMayStampLifecycle {
                        turnStateIsStale = false
                    }
                case .unresolved:
                    // Acceptance could be neither proven nor disproven. Be
                    // conservative about duplicate delivery: restore rather
                    // than re-send blindly.
                    lifecycleLog.notice(
                        "prompt.submit state unresolved; restoring unsent state session=\(sessionId, privacy: .private(mask: .hash))"
                    )
                }
                // Presentation writes below are submission-owned too: A's
                // failed send must not paint an error onto the session the
                // user switched to while recovery was suspended.
                if isCurrentComposerSubmission(submissionContext) {
                    showSendFailure(AppLocalization.string("Failed to send: \(UserFacingError.message(for: error))"))
                }
                if !reconnected, isCurrentComposerSubmission(submissionContext) {
                    await recoverComposerSubmission(using: submissionContext)
                }
                // A reconnect inside the recovery already synced the
                // authoritative transcript, so the restoration happened there.
                return false
            }
            if isCurrentComposerSubmission(submissionContext) {
                // A call's request records the refusal too: the call takes
                // the chat over itself (`submitComposerForCall`), and the
                // composer shows the outcome when it can't.
                if let refusal = error as? RpcError, refusal.isSessionNotOwned {
                    noteChatOwnedElsewhere(
                        refusal, sessionID: sessionId, knownSessionIDs: submissionSessionIDs, refusedText: text
                    )
                } else {
                    showSendFailure(AppLocalization.string("Failed to send: \(UserFacingError.message(for: error))"))
                }
            }
            await recoverComposerSubmission(using: submissionContext)
            // Automatic takeover starts once the chat has synced. The
            // composer's words for this send come back while it runs, and
            // Conduit keeps them and sends them when the chat is its own.
            // A call's request is taken over and sent again by the call.
            if !callSubmissionTexts.contains(text), surface != Self.spokenPromptSurface,
               chatTakeoverMatches(sessionId), activeChatTakeover?.phase == .offered,
               takesOverChatsAutomatically, chatTakeoverAutomaticSessionID != chatTakeoverGuardKey(sessionId) {
                chatTakeoverAutomaticSessionID = chatTakeoverGuardKey(sessionId)
                takeOverChat()
                // The words this send hands back are kept for it, and sent
                // once the chat is Conduit's (issue 2140).
                if chatTakeover?.phase == .waiting { chatTakeoverKeepsRefusedWords = chatTakeover?.sessionID }
            }
            return false
        }
    }

    private static func promptOutcomeLogValue(_ outcome: PromptSubmissionOutcome) -> String {
        switch outcome {
        case .accepted: return "accepted"
        case .steered: return "steered"
        case .redirected: return "redirected"
        case .queued: return "queued"
        }
    }

    /// A typed send `rpc` refused before writing it (`notConnected`): the
    /// socket had closed under it, its close frame in before its receive
    /// failed, so the drop wasn't known yet (issue 2095, a proxy closing
    /// sockets with 1005 and 1013). Nothing left the phone, so rather than
    /// come back to the composer the message waits in its chat as "Sends
    /// when connected", and goes once the reconnect this starts has the
    /// chat back. Text only, and only the composer's own: a call's, a
    /// Shortcut's or a Queue send reports its own outcome. False, with
    /// nothing changed but the drop noted, when it can't wait.
    private func keepComposerSendForReconnect(
        after error: Error,
        text: String,
        attachments: [Attachment],
        queued: Bool,
        surface: String?,
        rowID: String,
        client: HermesClient
    ) -> Bool {
        guard noteDropFoundBySend(error, client: client) else { return false }
        guard attachments.isEmpty, !queued, surface == nil, submissionTurnSurface == nil,
              !callSubmissionTexts.contains(text), composerWaitsForChat,
              sendWhenConnected(text, replyReference: nil) else { return false }
        // The waiting message shows in its place.
        messages.removeAll { $0.id == rowID }
        if let activeSessionId { cacheMessagePresentation(for: [activeSessionId]) }
        lifecycleLog.notice("prompt.submit found no connection; the message waits for the reconnect")
        return true
    }

    /// A send that went through ends the failure line shown when it set
    /// out, and only that line: another error, or a newer send's failure,
    /// stays.
    /// The failed send's line showing now, and which one it is.
    struct SendFailureMark: Equatable {
        let message: String
        let generation: UInt64
    }

    var sendFailureMark: SendFailureMark? {
        sendFailureShown.map { SendFailureMark(message: $0, generation: shownChat.sendFailureGeneration) }
    }

    /// A send that went through clears the failed send's line it set out
    /// under; a newer failure since, in whatever words, stays.
    func clearSendFailureAfterSend(_ failureBefore: SendFailureMark?) {
        guard let failure = failureBefore, sendFailureMark == failure else { return }
        if errorMessage == failure.message { errorMessage = nil }
        sendFailureShown = nil
    }

    func showSendFailure(_ message: String) {
        shownChat.sendFailureGeneration &+= 1
        errorMessage = message
        sendFailureShown = message
    }

    /// A send's request `rpc` refused with `notConnected` on the current
    /// client: the socket closed before its receive failed. The drop its
    /// own close report would bring a moment later is acted on now; that
    /// report, from this client, then finds it done. True when the error
    /// was that refusal.
    @discardableResult
    private func noteDropFoundBySend(_ error: Error, client: HermesClient) -> Bool {
        guard case HermesError.notConnected = error, self.client === client else { return false }
        if isConnected {
            noteConnectionStep("Send found the socket closed")
            handleDisconnect()
        }
        return true
    }

    /// Which failures leave it genuinely unknown whether Hermes received the
    /// prompt. Two classes are DEFINITIVE rejections: a structured `RpcError`
    /// (the gateway answered, so the prompt was not accepted) and
    /// `notConnected` (`rpc` throws before any bytes leave the device). The
    /// remaining transport failures are ambiguous — the bytes may have
    /// reached Hermes and the turn may already be running — so the
    /// authoritative registry probe decides, and unknown future `HermesError`
    /// cases fail toward the probe rather than toward a blind retry.
    static func isAmbiguousPromptDelivery(_ error: Error) -> Bool {
        switch error {
        case HermesError.notConnected:
            return false
        case is RpcError:
            return false
        case is HermesError:
            return true
        case is URLError, is CancellationError:
            return true
        default:
            return false
        }
    }

    /// Recovery for a `prompt.submit` whose acknowledgement was lost. Reconnects
    /// the transport if needed, then consults the authoritative runtime
    /// registry: a live turn for this session means the prompt was accepted and
    /// must never be re-sent; an idle/absent session means it was not.
    /// `reconnected` reports whether a transport recovery (with its own full
    /// transcript sync) ran, so the caller can skip a duplicate restoration.
    /// `lifecycleEvidence` is the `TurnLifecycleEvidence` captured at the
    /// registry observation — the baseline the caller's stamp/provenance
    /// guards compare.
    /// Internal (not private) so the classification contract is directly
    /// testable.
    enum AmbiguousPromptResolution {
        /// Accepted and still running on the current transport.
        case acceptedRunning
        /// Accepted — the durable transcript holds the submitted row — but
        /// the registry reported `starting`: runtime present, liveness
        /// inconclusive. Settlement is UNPROVEN; the next authoritative
        /// registry/stream edge settles the turn.
        case acceptedUnsettled
        /// Accepted and waiting in the chat's queue on the session authority
        /// with no turn running (a turn cut off by a restart holds the
        /// queue): its bubble is in the dock, and nothing runs until the
        /// cut-off turn is discarded.
        case acceptedHeld
        /// Accepted and proven settled by the durable transcript: the turn ran
        /// to completion before recovery looked (the registry had already gone
        /// idle/absent, which alone cannot prove non-acceptance).
        case acceptedSettled
        /// Authoritative evidence (registry idle/absent AND the durable
        /// transcript advanced without the submitted turn) that the prompt was
        /// not accepted.
        case notAccepted
        /// Neither acceptance nor non-acceptance could be established.
        case unresolved
    }

    /// The ambiguous-recovery registry status, split beyond
    /// `LiveSessionStatus.isRunning`. `isRunning` deliberately excludes
    /// `starting` because Hermes arms `starting` for plain session.create /
    /// cold-resume pre-warm with no prompt involved — but in an ambiguous
    /// submission recovery, that same mask can cover a COMMITTED turn during
    /// the submit → agent-ready window. `starting` is therefore its own
    /// classification: runtime present, liveness inconclusive — never settled,
    /// never committed-busy. Internal for the classification-contract tests.
    enum AmbiguousRegistryLiveness {
        /// `working` | `waiting` — authoritative committed-busy state.
        case committedBusy
        /// `starting` — runtime present, liveness inconclusive.
        case starting
        /// An explicit `idle` row (or any unrecognized non-running status).
        case idle
        /// No matching runtime row for the submitted session.
        case absent
    }

    /// The classification contract for an ambiguous submission's
    /// authoritative evidence pair. Pure and total so the status × evidence
    /// matrix is pinned directly by tests:
    ///
    /// - `committedBusy` ALWAYS classifies `.acceptedRunning`, before the
    ///   transcript is consulted and regardless of which client performed the
    ///   probe — a running registry row is never settled (client
    ///   replacement/submission ownership is a separate concern).
    /// - `starting` NEVER classifies `.acceptedSettled`: a `.present` durable
    ///   row proves acceptance, not settlement (`.acceptedUnsettled`), and
    ///   `.absent`/`.indeterminate` prove nothing — the committed turn may not
    ///   have reached the durable verification point yet, so the outcome is
    ///   conservative `.unresolved` (restore; never a blind resend), never
    ///   `.notAccepted` merely because `starting` was present.
    /// - `idle`/`absent` fall through to the durable transcript: present →
    ///   `.acceptedSettled`, absent → `.notAccepted`, indeterminate →
    ///   `.unresolved`.
    static func classifyAmbiguousSubmission(
        registryLiveness: AmbiguousRegistryLiveness,
        transcript: SubmittedTurnEvidence
    ) -> AmbiguousPromptResolution {
        switch registryLiveness {
        case .committedBusy:
            // Ignoring `transcript` here is the contract: a working/waiting
            // row settles the acceptance question on the registry alone.
            return .acceptedRunning
        case .starting:
            switch transcript {
            case .present: return .acceptedUnsettled
            case .absent, .indeterminate: return .unresolved
            }
        case .idle, .absent:
            switch transcript {
            case .present: return .acceptedSettled
            case .absent: return .notAccepted
            case .indeterminate: return .unresolved
            }
        }
    }

    private func reconcileAmbiguousPromptSubmission(
        requestedSessionID: String,
        acceptedSessionIDs: Set<String>,
        baseline: PromptTranscriptBaseline,
        submittedText: String,
        submissionContext: ComposerSubmissionContext,
        optimisticRowID: String? = nil
    ) async -> (resolution: AmbiguousPromptResolution, reconnected: Bool, lifecycleEvidence: TurnLifecycleEvidence) {
        var reconnected = false
        var probeClient = client
        if probeClient?.isConnected != true {
            // The transport died around the submission. A reconnect here is a
            // real recovery, and its sync may already surface the accepted
            // turn's persisted rows.
            await reconnectForRetry(purpose: .preserveCurrent)
            probeClient = self.client
            // Only a SUCCESSFUL reconnect (whose sync already restored the
            // authoritative transcript) may skip the caller's restoration; a
            // failed reconnect must fall back to it.
            reconnected = probeClient?.isConnected == true
        }
        guard isCurrentOrAliasedComposerSubmission(submissionContext),
              let probeClient else {
            return (.unresolved, reconnected, shownChat.turnLifecycleEvidence)
        }
        // The evidence baseline for the caller's guards, captured at the
        // registry observation: the probe result already includes every edge
        // processed up to this point, so any later revision increment is
        // strictly newer evidence. Capturing BEFORE the probe (not after) is
        // deliberate: an edge processed DURING the probe await may postdate
        // the registry snapshot server-side, so it must keep winning.
        let lifecycleEvidence = shownChat.turnLifecycleEvidence
        // The session authority names every message it holds by the id it
        // was sent with: one its queue lists was taken, whatever the
        // registry or the transcript can show yet.
        if let held = await heldInAuthorityQueue(
            requestedSessionID: requestedSessionID,
            // The chat's own profile: a Bot Chat's queue is under its bot's.
            profile: presentationProfile(for: requestedSessionID),
            client: probeClient,
            optimisticRowID: optimisticRowID
        ) {
            return (held, reconnected, lifecycleEvidence)
        }
        // The alias set was captured from the ORIGINAL submission before any
        // await; it is never re-derived from the mutable active session here.
        let evidenceProfile = activeProfile
        let evidenceServerIdentity = defaults.string(forKey: Self.chatResumeServerIdentityKey)
        let rows: [LiveSessionStatus]
        do {
            if let probeActiveSessions = chatResumeLifecycleOperations.probeActiveSessions {
                rows = try await probeActiveSessions(probeClient)
            } else {
                rows = try await probeClient.activeSessions()
            }
            // Currency fence (see probeForegroundRuntime): a server change
            // during the await discards its in-flight rows.
            guard evidenceProfile == activeProfile,
                  defaults.string(forKey: Self.chatResumeServerIdentityKey) == evidenceServerIdentity else {
                return (.unresolved, reconnected, lifecycleEvidence)
            }
            recordActiveListEvidence(rows, profile: evidenceProfile)
        } catch {
            return (.unresolved, reconnected, lifecycleEvidence)
        }
        let matchedRow = rows.first(where: {
            acceptedSessionIDs.contains($0.runtimeSessionId) || acceptedSessionIDs.contains($0.storedSessionId)
        })
        // Registry liveness split: `working`/`waiting` are committed-busy,
        // `starting` is runtime-present but liveness-inconclusive, and only a
        // genuine `idle`/absent runtime lets the durable transcript decide
        // between settled and not-accepted.
        let registryLiveness: AmbiguousRegistryLiveness
        if let matchedRow {
            if matchedRow.isRunning {
                registryLiveness = .committedBusy
            } else if matchedRow.status == "starting" {
                registryLiveness = .starting
            } else {
                registryLiveness = .idle
            }
        } else {
            // No runtime for this conversation anymore: current liveness is
            // gone, but that alone cannot prove non-acceptance — the accepted
            // turn may have completed and been reaped. Verify durably below.
            registryLiveness = .absent
        }
        // A committed-busy row classifies on the registry alone; the bounded
        // durable verifier is only consulted when liveness alone cannot
        // classify.
        let transcript: SubmittedTurnEvidence = registryLiveness == .committedBusy
            ? .indeterminate
            : await verifySubmittedTurnInTranscript(
                requestedSessionID: requestedSessionID,
                profile: submissionContext.profile,
                baseline: baseline,
                submittedText: submittedText
            )
        return (
            Self.classifyAmbiguousSubmission(
                registryLiveness: registryLiveness,
                transcript: transcript
            ),
            reconnected,
            lifecycleEvidence
        )
    }

    /// A send whose reply never came back, looked up in the chat's queue on
    /// the session authority by its submission id (`input_id`): waiting its
    /// turn, its bubble moves to the dock above the composer; running, or
    /// cut off by a restart, it reads as taken. Nil when the queue doesn't
    /// list it (not taken, or already done: the transcript decides) or the
    /// server keeps none.
    private func heldInAuthorityQueue(
        requestedSessionID: String,
        profile: String,
        client: HermesClient,
        optimisticRowID: String?
    ) async -> AmbiguousPromptResolution? {
        guard client.speaksSessionAuthority,
              let submissionID = HermesClient.unansweredSubmissionID(for: requestedSessionID),
              let rows = try? await client.queuedPrompts(requestedSessionID, profile: profile),
              let row = rows.first(where: { $0.inputID == submissionID }) else { return nil }
        switch row.status {
        case .queued, .unknown:
            // Waiting, or cut off: the dock shows it (a cut-off one on its
            // card, whose Resend sends the words again), never the transcript too.
            // Its turn already started (the start came during this read):
            // the bubble stays where it is.
            if !shownChat.startedAdmissionIDs.contains(row.admissionID),
               let optimisticRowID, let index = messages.firstIndex(where: { $0.id == optimisticRowID }) {
                holdQueuedSendRow(messages.remove(at: index), admissionID: row.admissionID)
                cacheMessagePresentation()
            }
            if activeSessionId == requestedSessionID || eventBelongsToActiveSession(requestedSessionID) {
                authorityQueue.apply(rows, for: requestedSessionID)
            }
            // Taken either way; it runs only behind a running turn. Held by
            // a cut-off one, nothing runs: the next snapshot says so.
            return row.status == .queued && rows.contains { $0.status == .started } ? .acceptedRunning : .acceptedHeld
        case .started:
            if activeSessionId == requestedSessionID || eventBelongsToActiveSession(requestedSessionID) {
                authorityQueue.apply(rows, for: requestedSessionID)
            }
            return .acceptedRunning
        case .terminal:
            // Settled: the same words sent again are a new message.
            HermesClient.forgetUnansweredSubmission(submissionID, for: requestedSessionID)
            return nil
        }
    }

    /// Durable before/after identity captured BEFORE the optimistic append.
    ///
    /// Only rows with POSITIVE durable provenance may serve as baseline
    /// evidence: ids adopted from validated persisted-transcript hydration.
    /// Visible `ChatMessage.id` values for optimistic or locally synthesized
    /// rows (`local-…`, live tool/reasoning/review projections, positional
    /// fallbacks, streaming completions) are presentation identities — Hermes
    /// persists those rows under fresh database ids — so id shape can never
    /// establish that a persisted row is new, and no prefix list can be
    /// complete. The baseline therefore consumes only the positively adopted
    /// durable id set and flags whether the conversation holds any visible
    /// row whose persisted identity is unproven.
    struct PromptTranscriptBaseline {
        /// Positively known durable persisted row ids for this conversation,
        /// usable as overlap anchors against a persisted tail.
        let durableIDs: Set<String>
        /// Whether some pre-submit conversation content exists only as a
        /// row without durable provenance (e.g. an earlier optimistic send
        /// that was never re-hydrated). If so, a matching persisted row after
        /// the anchor could belong to THAT content, and acceptance is
        /// unprovable.
        let holdsUnprovenRows: Bool

        init(durableIDs: Set<String>, holdsUnprovenRows: Bool) {
            self.durableIDs = durableIDs
            self.holdsUnprovenRows = holdsUnprovenRows
        }
    }

    /// Internal (not private) so `classifyAmbiguousSubmission`'s contract is
    /// directly testable.
    enum SubmittedTurnEvidence {
        case present
        case absent
        case indeterminate
    }

    /// Bounded tail read (the PR #118 `order=latest` page via the existing
    /// persisted-transcript source) to decide whether an ambiguously
    /// acknowledged prompt actually landed. `profile` comes from the owning
    /// submission context, captured before any await.
    private func verifySubmittedTurnInTranscript(
        requestedSessionID: String,
        profile: String,
        baseline: PromptTranscriptBaseline,
        submittedText: String
    ) async -> SubmittedTurnEvidence {
        let outcome = await persistedTranscriptOutcome(
            sessionId: requestedSessionID,
            profile: profile,
            using: dashboardTicketBridge
        )
        let tail: [ChatMessage]
        let idsAreDurable: Bool
        switch outcome {
        case .hydrated(let persisted):
            tail = persisted.messages
            // A paginated page only comes back when the echo honored the
            // tail contract AND the rows carried durable identity; the
            // legacy one-shot re-read makes no such guarantee.
            idsAreDurable = persisted.page != nil
        case .unavailable, .failed:
            // No usable durable source: acceptance stays unproven.
            return .indeterminate
        }

        // Compared as the persisted row shows it: a prompt typed with a
        // leading `@file:` line or an `@image:` token is projected the same
        // way on both sides.
        let wanted = MessageNormalizer.visibleUserText(submittedText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let contentMatches: (ChatMessage) -> Bool = { message in
            message.role == .user
                && message.content.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
        }

        if idsAreDurable {
            // Overlap anchor: the NEWEST tail row the pre-submit durable
            // evidence already held. Only rows strictly after that anchor are
            // candidates for the submitted turn — a matching row at or before
            // the anchor belongs to an OLDER identical send.
            //
            // A bounded `order=latest` page carries only the newest rows: an
            // accepted turn can persist hundreds of rows after the
            // submission, pushing BOTH the anchor and the submitted row out
            // of this window. Without the anchor in the tail, ordering
            // evidence is unavailable and content absence from the window
            // proves nothing — the outcome is indeterminate, never
            // notAccepted and never acceptedSettled.
            guard let anchorIndex = tail.lastIndex(where: {
                baseline.durableIDs.contains($0.id)
            }) else {
                return .indeterminate
            }
            let candidates = tail[tail.index(after: anchorIndex)...]

            if candidates.contains(where: contentMatches) {
                if baseline.holdsUnprovenRows {
                    // The conversation held visible rows whose persisted
                    // twins are unknown: the matching candidate could be an
                    // older identical send re-homed under a new id.
                    return .indeterminate
                }
                // Every pre-submit row was durably identified, so the anchor
                // proves everything up to it; a matching user row after the
                // anchor can only be the new submission.
                return .present
            }
            // The tail advanced past the durable anchor without any matching
            // user row. The anchor's presence in this window bounds the
            // search: the submitted row, if it had landed, would be newer
            // than the anchor and therefore inside the window too.
            return .absent
        }

        // Positional-id fallback (legacy one-shot transcript): this response
        // IS the entire persisted transcript, so content absence proves
        // non-acceptance — but row identity cannot distinguish new from old
        // rows, so a matching row is never proof of acceptance.
        if tail.contains(where: contentMatches) {
            return .indeterminate
        }
        return .absent
    }
}
