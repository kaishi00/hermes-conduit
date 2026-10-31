//
//  ChatRowState.swift
//  Conduit
//
//  What the transcript's rows show from AppState, worked out once per
//  publish. The rows used to observe AppState themselves, so every publish
//  (a title, a list load, a status poll) redrew each row on screen: the
//  open chat's biggest cost per update. They read these from the
//  environment now, which redraws a row only when a value it shows changed.
//

import SwiftUI

struct ChatRowState: Equatable {
    var activeProfile = ""
    /// The open conversation's agent: a Bot Chat's bot, else the profile.
    var agentIdentity = ConversationAgentIdentity.workspace(name: "", photoURL: nil)
    var agentGlowTint: Color?
    var isBusy = false
    var isBranchingChat = false
    var isOffline = false
    var canQuoteIntoComposer = false
    /// Reactions can be sent at all; `canReact(to:)` adds the message's
    /// own part.
    var reactionsAvailable = false
    var latestAssistantMessageID: String?
    /// The newest reply, while it answers the last message sent: /retry
    /// sends that message again, so a reply with a message after it (a
    /// stopped or unanswered turn) offers no Retry.
    var retryableReplyID: String?
    var readAloudUnavailable = false
    var displayPreferences = ProfileDisplayPreferences()
    /// A call card finds its call through AppState; this redraws it when
    /// the links change.
    var voiceCallLinksRevision = 0
    /// Each live card's last row: earlier rows with that live name show
    /// that it was updated below.
    var latestLiveRows: [String: String] = [:]
    /// The open chat's messages that have a Pulse card, by Hermes' message
    /// id (PulseFeed.swift): they show a Pulse mark that opens it.
    var pulseCards: [Int: Int] = [:]
    /// Replies can be pinned here (#918), and the rows that are.
    var canPinReplies = false
    var pinnedMessageIDs: Set<String> = []
    /// Replies to a teammate's delivery, folded under "Replied to <name>".
    var teammateReplies: [String: String] = [:]
    /// The bots' names as the chat shows them: a "Messaged" step reads its
    /// teammate's name from the roster, and this redraws it when that loads.
    var botLabels: [String] = []
    /// Names the steps Conduit has no words of its own for.
    var toolCatalog = ToolCatalog()
    /// Finished runs' summaries, by their first tool call.
    var stepSummaries: [String: String] = [:]
    /// Runs Hermes is looking back on now, by their first tool call.
    var stepSummariesAsked: Set<String> = []
    /// A run's menu can ask Hermes to explain it.
    var canExplainStepRuns = false
    /// Replies Hermes wrote on its own, with why (Predictive follow-ups).
    var followUpReasons: [String: String] = [:]

    init() {}

    /// `facts`: the transcript's own (ChatView's TranscriptModel), worked out
    /// once per change of its rows; else from AppState's rows on screen.
    @MainActor
    init(_ appState: AppState, facts: ChatRowFacts? = nil) {
        let profile = appState.activeProfile
        activeProfile = profile
        agentIdentity = appState.conversationAgentIdentity
        agentGlowTint = appState.profileGlowTint(appState.conversationIdentityProfile)
        isBusy = appState.chatOnScreenIsBusy
        isBranchingChat = appState.isBranchingChat
        isOffline = appState.offlineChatPresentation != nil
        canQuoteIntoComposer = appState.canQuoteIntoComposer()
        reactionsAvailable = appState.reactionsAvailable
        let facts = facts ?? ChatRowFacts(rows: appState.chatRowsOnScreen, isBusy: isBusy)
        latestAssistantMessageID = facts.latestAssistantMessageID
        retryableReplyID = facts.retryableReplyID
        readAloudUnavailable = appState.readAloudUnavailableReason != nil
        displayPreferences = appState.displayPreferences
        voiceCallLinksRevision = appState.voiceCallChatLinksRevision
        latestLiveRows = facts.latestLiveRows
        pulseCards = appState.pulseCards(forChat: appState.activeSessionId)
        canPinReplies = appState.canPinReplies
        pinnedMessageIDs = appState.openChatPinnedMessageIDs
        teammateReplies = facts.teammateReplies
        botLabels = appState.botRoster.map { "\($0.name)=\($0.displayLabel)" }
        toolCatalog = appState.toolCatalog
        let scope = appState.toolCatalogKey
        stepSummaries = appState.stepSummaries[scope] ?? [:]
        stepSummariesAsked = Set(appState.stepSummaryRequested.keys.lazy.filter { $0.scope == scope }.map(\.toolID))
        canExplainStepRuns = appState.client != nil && !(appState.activeSessionId ?? "").isEmpty && !isOffline
        followUpReasons = appState.predictive.followUpReasons
    }

    /// `AppState.canReact(to:)`, from these values alone.
    func canReact(to message: ChatMessage) -> Bool {
        reactionsAvailable
            && message.content.contains(where: { !$0.isWhitespace })
            && AppState.reactionTarget(
                for: message,
                isBusy: isBusy,
                latestAssistantMessageID: latestAssistantMessageID
            ) != nil
    }
}

/// What the rows show that comes from the whole transcript: which reply is
/// the latest, offers Retry or folds under a teammate's delivery, and each
/// live card's last row. Worked out from the rows drawn, the saved copy's
/// while they stand in, so those fold and hide as Hermes' will and nothing
/// moves when Hermes' land.
struct ChatRowFacts: Equatable {
    var latestAssistantMessageID: String?
    var retryableReplyID: String?
    var latestLiveRows: [String: String] = [:]
    var teammateReplies: [String: String] = [:]

    init() {}

    /// `isBusy`: a turn runs in the chat drawn, so its reply still streaming
    /// stays open.
    @MainActor
    init(rows: [ChatMessage], isBusy: Bool) {
        latestAssistantMessageID = rows.last(where: { $0.role == .assistant })?.id
        retryableReplyID = AppState.retryableReplyID(in: rows)
        latestLiveRows = RichCard.latestLiveRows(rows)
        teammateReplies = BotTeammateMessages.teammateReplies(
            in: rows,
            streamingMessageID: isBusy ? BotTeammateMessages.runningReplyID(in: rows) : nil
        )
    }
}

/// The AppState the rows act on (send a reaction, answer a card), held
/// without observing it.
struct ChatRowActions: Equatable {
    let appState: AppState

    nonisolated static func == (lhs: ChatRowActions, rhs: ChatRowActions) -> Bool {
        lhs.appState === rhs.appState
    }
}

private struct ChatRowStateKey: EnvironmentKey {
    /// Outside `chatRows()` a row draws these blanks (actions crash instead).
    static let defaultValue = ChatRowState()
}

private struct ChatRowActionsKey: EnvironmentKey {
    static let defaultValue: ChatRowActions? = nil
}

extension EnvironmentValues {
    var chatRowState: ChatRowState {
        get { self[ChatRowStateKey.self] }
        set { self[ChatRowStateKey.self] = newValue }
    }

    var chatRowActions: ChatRowActions? {
        get { self[ChatRowActionsKey.self] }
        set { self[ChatRowActionsKey.self] = newValue }
    }
}

extension Optional where Wrapped == ChatRowActions {
    /// The rows only draw under `chatRows()`: missing it is a programming
    /// error, like a missing `environmentObject`, which crashes the same way.
    var required: AppState {
        guard let actions = self else { preconditionFailure("Chat rows draw under .chatRows()") }
        return actions.appState
    }
}

extension View {
    /// Hands the transcript's rows their state and actions. On every view
    /// that draws chat rows (the chat, an offline copy, a group room).
    /// `facts`: the transcript's, from the chat's TranscriptModel; nil works
    /// them out from AppState's rows on screen on each publish (a card on
    /// its own, as on the Classic voice screen).
    func chatRows(facts: ChatRowFacts? = nil) -> some View {
        modifier(ChatRowsEnvironment(facts: facts))
    }
}

private struct ChatRowsEnvironment: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @State private var last = LastChatRowState()
    let facts: ChatRowFacts?

    init(facts: ChatRowFacts?) {
        self.facts = facts
    }

    func body(content: Content) -> some View {
        content
            .environment(\.chatRowState, last.keeping(ChatRowState(appState, facts: facts)))
            .environment(\.chatRowActions, ChatRowActions(appState: appState))
    }
}

/// The last state handed down, kept while equal: the same instance, URL
/// and color storage included, compares unchanged however SwiftUI checks.
@MainActor
private final class LastChatRowState {
    private var value: ChatRowState?

    func keeping(_ next: ChatRowState) -> ChatRowState {
        if let value, value == next { return value }
        value = next
        return next
    }
}
