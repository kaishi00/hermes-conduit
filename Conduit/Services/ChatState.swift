import Foundation
import Combine

/// One chat's own state: its transcript, and the reply streaming into it.
///
/// Stage 1 of the all-live rework moves AppState's chat state here a slice at
/// a time, with no change anyone sees (the plan: "Combining Hermes instances
/// in Conduit", stage 1; the property cut list sorts what moves). There is
/// still one, `AppState.shownChat`, for the chat on screen, and it is never
/// replaced: opening another chat refills it as AppState's own properties
/// were refilled. Stage 2 keeps one per open or running chat, so a chat left
/// mid-reply keeps its stream.
///
/// Views and tests still read the chat on screen through AppState
/// (`messages`, `offlineChatPresentation`, `persistedTranscriptWindow`,
/// `liveTurn` and the rest forward here), and AppState publishes this
/// object's changes as its own, so every view that observes AppState redraws
/// as before. What reacts to a change outside the chat (the chat on screen
/// claim, a message waiting to send, the viewport) stays in AppState's
/// forwarding setters. `liveTurn` publishes on its own object, as before.
@MainActor
final class ChatState: ObservableObject {

    // MARK: Transcript

    @Published var messages: [ChatMessage] = [] {
        didSet {
            transcriptRevision &+= 1
            let pendingClarify = ChatResumeCoordinator.pendingClarifyMessageID(in: messages)
            if pendingClarifyMessageID != pendingClarify {
                pendingClarifyMessageID = pendingClarify
            }
            let kind = pendingClarify.flatMap { id in messages.last { $0.id == id } }
                .map(PendingDecisionKind.init(message:)) ?? .question
            if pendingDecisionKind != kind {
                pendingDecisionKind = kind
            }
        }
    }
    /// Bumped on every write to `messages`.
    @Published private(set) var transcriptRevision: UInt64 = 0
    /// Cached once per transcript mutation so view updates do not rescan the full history.
    @Published private(set) var pendingClarifyMessageID: String?
    /// What that card is, for the jump button's words.
    @Published private(set) var pendingDecisionKind = PendingDecisionKind.question
    /// Read-only copy of a recently opened conversation, shown while the
    /// server has not answered yet (#99): the chat view draws its rows as
    /// the chat's, provisionally. It never feeds `messages`, `sessions`, or
    /// any resume/selection/routing decision, and while it's up nothing
    /// that needs Hermes' word acts on its rows (approvals, Load earlier,
    /// Retry, Edit, reactions, pins). Written through AppState's
    /// `offlineChatPresentation`, which also follows it with the chat on
    /// screen claim and a message waiting to send.
    @Published var offlineChatPresentation: OfflineChatPresentation?
    /// Persisted-history pagination window of the chat.
    /// Drives the "Load earlier messages" affordance; nil means the current
    /// transcript is either a legacy one-shot hydration or not persisted-
    /// history-backed at all, and no older pages exist to fetch.
    @Published var persistedTranscriptWindow: PersistedTranscriptWindowState?
    /// Row ids POSITIVELY known to originate from validated persisted-
    /// transcript hydration (raw rows carrying a durable `id`/`message_id`)
    /// for the chat, adopted from the latest accepted hydration and cleared
    /// whenever a reconcile begins or fails to adopt a transcript. Consumed
    /// only by the ambiguous-delivery verifier as ordering anchors — never
    /// populated from visible id shape, so local optimistic / streaming /
    /// positional ids can never masquerade as persisted anchors.
    var durablePersistedRowIDs: Set<String> = []

    // MARK: Stream

    /// The running turn's live reply text and thinking card. They publish on
    /// their own object, never on AppState: while a turn streams they change
    /// 20 to 30 times a second, and an AppState publish re-renders every view
    /// that observes it, so any open sheet re-rendered at that rate and lagged.
    let liveTurn = LiveTurnProjection()
    var activeAssistantMessageId: String?
    var activeReasoningMessageId: String?
    var receivedReasoningForCurrentTurn = false
    /// Authoritative merged reasoning for the live thinking card. Raw deltas
    /// merge into this buffer immediately; the published transcript is only
    /// republished at a coalesced cadence so an expanded ThinkingCard cannot
    /// monopolize main-actor layout work during a live reasoning stream.
    var reasoningBuffer = ""
    var reasoningPublishTask: Task<Void, Never>?
    var hasScheduledReasoningPublish = false
    var streamingBuffer = ""
    /// The last row a `message.interim` sealed in the running turn.
    var interimRowID: String?
    /// Every row `message.interim` sealed while the current turn runs: its
    /// progress notes, which a call's chat seed leaves out (#1991). A
    /// finished reply can keep an interim row's id, so the id alone doesn't
    /// tell.
    var runningTurnNoteIDs: Set<String> = []
    /// Gateway deltas can arrive much faster than SwiftUI can lay out a chat
    /// transcript. Keep the authoritative buffer intact, but publish at a
    /// display-friendly cadence so an active response cannot monopolize the
    /// main actor (and make sheets or session rows feel untappable).
    var streamingPublishTask: Task<Void, Never>?
    /// A fast gateway can emit its final delta and completion inside one
    /// publish interval. Keep that final projection alive briefly so the UI's
    /// character reveal can drain instead of jumping straight to the result.
    var streamingCompletionTask: Task<Void, Never>?
    var pendingStreamingCompletion: AppState.PendingStreamingCompletion?
    var hasScheduledStreamingPublish = false
    var lastStreamingPublishBurst = 0
    var lastStreamingPublishDate: Date?

    // MARK: Turn and reconcile

    /// Written through AppState's `turnState`, which also follows a change
    /// with the message waiting to send, the backdrop and the chat on screen
    /// claim.
    @Published var turnState: TurnState = .idle
    /// Whether `turnState` may have missed server-side turn edges. Set at
    /// lifecycle boundaries where the socket can die or the gateway can change
    /// state unobserved (scene dips, reconnects, ambiguous submissions);
    /// cleared only when an authoritative source (the `session.active_list`
    /// probe, a resume snapshot, or a typed prompt outcome) re-confirms the
    /// state. A stale idle state must not route the next input as a new-turn
    /// `prompt.submit` — Hermes would apply its busy policy to it and the
    /// message would silently join a turn the user never saw start.
    /// Publishes its flips: the chat list's Working marker reads it.
    var turnStateIsStale = false {
        willSet { if newValue != turnStateIsStale { objectWillChange.send() } }
    }
    var turnLifecycleEvidence = AppState.TurnLifecycleEvidence(revision: 0, running: false)
    /// Whether the visible persisted transcript may be MISSING rows —
    /// conceptually disjoint from `turnStateIsStale`, which answers "do I
    /// know whether Hermes is currently busy?". Set when a bounded
    /// foreground freshness read failed transiently on a real background
    /// return, and when a resume Hermes refused as too long for the whole
    /// transcript kept the rows on screen while its history read failed for
    /// now (issue 2025); a liveness answer (the registry probe) can never
    /// clear it.
    /// Cleared only when an authoritative transcript source proves
    /// convergence: an unchanged bounded verdict, an advancement merge, or a
    /// resume/reconcile hydration (`applyChatResume`).
    var transcriptFreshnessIsStale = false
    var pendingLocalOrderingDebt: AppState.PendingLocalOrderingDebt?
    var locallyOwnedInFlightTurn: AppState.LocallyOwnedInFlightTurn?
    var persistedOrderingFrontier = AppState.PersistedOrderingFrontier()
    var reconciliationToken = UUID()
    /// Set by the resume admission gate when it rejects a contradictory or
    /// foreign-owned identity. Automatic-return recovery treats ordinary
    /// resume failures as retryable; a rejected identity is deterministic,
    /// so reconnect scheduling skips it instead of looping on the same
    /// contradiction. Main-actor state, valid for the current reconcile only.
    var reconciliationWasIdentityRejected = false
    /// Set only when the currently owned resume RPC definitively reports
    /// that its requested session no longer exists. Callers use this to
    /// retire a saved automatic-return target instead of retrying it forever.
    var reconciliationSessionWasNotFound = false
    /// Set when the resume RPC refused a Kanban worker's transcript (4132).
    /// Hermes never reopens one as a chat, so it also counts as not found:
    /// a saved automatic-return target is retired and a notification isn't
    /// retried. This flag keeps its own message from being reworded.
    var reconciliationWasKanbanWorker = false
    var reconciliation: AppState.Reconciliation?
    /// Side-agent answers that came in while a reconciliation was open.
    /// Hermes keeps no copy of them, so unlike the buffered stream they
    /// can't come back with a later transcript: they show once the boundary
    /// closes, whether its reconcile committed or was dropped.
    var heldSideAgentCompletions: [StreamEvent] = []

    // MARK: Composer and sending

    @Published var composerPrefillText = ""
    @Published var composerPrefillToken = UUID()
    /// The draft the prefill is for, until ComposerBar puts it in. A new
    /// chat's draft load can land in the same update as the prefill, so
    /// the composer waits until this draft is the one loaded. Set only by
    /// `prefillComposer`, with the text and then the token.
    var composerPrefillDraftKey: ComposerDraftKey?
    /// A quote waiting for the composer (#385). ComposerBar, which owns the
    /// draft, applies it and then consumes it.
    @Published var composerQuoteRequest: ComposerQuoteRequest?
    /// A "Replying to" card's tap (issue 1420): the chat or room on screen
    /// scrolls to the reply it quoted, then clears it.
    @Published var pendingQuotedReplyJump: QuotedReplyJump?
    /// Files dropped on the open chat (#1408), waiting for its composer to
    /// stage them, and the same for the open room's composer.
    @Published var composerDropRequest: AttachmentDropRequest?
    /// Asks the composer to take focus (a screenshot chat opened with the
    /// keyboard). ComposerBar focuses and then consumes it.
    @Published var composerFocusRequest: ComposerFocusRequest?
    /// Asks the open chat's composer to start dictating (its big button
    /// set to Dictation, or Dictate in the button's menu). ComposerBar
    /// starts and then consumes it.
    @Published var composerDictationRequest: ComposerDictationRequest?
    /// Words the composer puts back: a waiting message taken back to edit,
    /// or one its chat never took. ComposerBar applies each, then consumes it.
    @Published var composerRestoreRequests: [ComposerRestoreRequest] = []
    /// A composer send still checking Hermes before its message shows: the
    /// composer says it's sending meanwhile (#1401).
    @Published var composerSendChecks: [ComposerSendCheck] = []
    /// Sends whose chat was left while their reply was lost: Hermes may
    /// have them, so their words come back without an "unsent" notice.
    var composerSubmissionsOfUnknownDelivery: [ComposerSubmissionContext] = []
    /// Why a waiting message went back to a draft, until it's dismissed or
    /// the composer is used.
    @Published var composerNotice: String? {
        didSet {
            // Each notice says what it is; a new one starts as a waiting
            // message's until its writer says otherwise.
            if composerNotice != oldValue { composerNoticeSystemImage = AppState.composerReturnNoticeSystemImage }
        }
    }
    /// The symbol beside the notice: a message that came back, or a draft
    /// shared from another app (AppState+ShareDraft.swift).
    @Published var composerNoticeSystemImage = AppState.composerReturnNoticeSystemImage
    /// A reasoning write is in flight, from the composer chip or the Model
    /// sheet; both wait for it so picks land in order.
    @Published var isWritingReasoningEffort = false
    /// The failed send's error under the composer, which leaving its chat
    /// clears: the composer shows `errorMessage` unlocked too.
    var sendFailureShown: String?
    /// Counts the failed sends shown, so a send that went through clears
    /// only the line it set out under, never a newer one in the same words
    /// (issue 2115).
    var sendFailureGeneration: UInt64 = 0
    /// Latch for `noteComposerUserEdit()`: set once an edit has invalidated
    /// the current generation's automatic-return intent, cleared when the
    /// next generation begins. Every automatic generation mints its token
    /// here (a cancelled token is stale, so a new one is always minted), so
    /// clearing at entry re-arms the composer for each new window.
    var composerEditClaimedAutomaticWork = false
}
