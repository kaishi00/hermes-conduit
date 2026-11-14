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
}
