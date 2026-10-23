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

    init() {}

    @MainActor
    init(_ appState: AppState) {
        let profile = appState.activeProfile
        activeProfile = profile
        agentIdentity = appState.conversationAgentIdentity
        agentGlowTint = appState.profileGlowTint(appState.conversationIdentityProfile)
        isBusy = appState.isBusy
        isBranchingChat = appState.isBranchingChat
        isOffline = appState.offlineChatPresentation != nil
        canQuoteIntoComposer = appState.canQuoteIntoComposer()
        reactionsAvailable = appState.reactionsAvailable
        latestAssistantMessageID = appState.messages.last(where: { $0.role == .assistant })?.id
        readAloudUnavailable = appState.readAloudUnavailableReason != nil
        displayPreferences = appState.displayPreferences
        voiceCallLinksRevision = appState.voiceCallChatLinksRevision
        latestLiveRows = RichCard.latestLiveRows(appState.messages)
        pulseCards = appState.pulseCards(forChat: appState.activeSessionId)
        canPinReplies = appState.canPinReplies
        pinnedMessageIDs = appState.openChatPinnedMessageIDs
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
    func chatRows() -> some View {
        modifier(ChatRowsEnvironment())
    }
}

private struct ChatRowsEnvironment: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @State private var last = LastChatRowState()

    func body(content: Content) -> some View {
        content
            .environment(\.chatRowState, last.keeping(ChatRowState(appState)))
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
