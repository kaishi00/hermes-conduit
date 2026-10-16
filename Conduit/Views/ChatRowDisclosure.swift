import SwiftUI

/// What a transcript row uses when the reader opens or closes it (Thinking,
/// a tool card, "Show all").
///
/// It remembers each row's choice by message id. A row's own @State does not
/// survive the row being rebuilt: the live Thinking card becomes a settled
/// row with the same id when the next tool call or the reply arrives, and a
/// lazily laid out row can be rebuilt after scrolling away. Either one used
/// to fold an open card shut under the reader, which moved everything below
/// it.
///
/// And it tells the scroll engine first, so the row the reader tapped stays
/// where it is (ChatScrollEngine.userWillToggleRow).
///
/// Not observable: a row reads it when it is built and writes it when
/// tapped, so a toggle re-renders only that row. One instance per chat view,
/// so the environment value never changes identity. Choices last for one
/// conversation: message ids are not unique across them (rows resumed
/// without an id are numbered from 0, "0-reasoning" and so on), so another
/// conversation starts from the defaults. Another spelling of the same
/// conversation (a new chat getting its id) keeps them. Rows without a
/// message id ("Show all" in a long reply, the review summary) only tell
/// the engine and keep their own state as before.
@MainActor
final class ChatRowDisclosure {
    weak var engine: ChatScrollEngine?
    /// The conversation on screen; ChatView reads it from AppState.
    var currentConversation: @MainActor () -> ChatScrollSessionIdentity = { .none }
    private var conversation = ChatScrollSessionIdentity.none
    private var states: [String: Bool] = [:]

    func isExpanded(_ id: String, default defaultValue: Bool) -> Bool {
        followConversation()
        return states[id] ?? defaultValue
    }

    /// Call before changing the row's height, inside the same tap.
    func willToggle(_ id: String?, to expanded: Bool) {
        engine?.userWillToggleRow()
        guard let id else { return }
        followConversation()
        states[id] = expanded
    }

    /// A turn's run of steps opens and closes as one card, drawn by all of
    /// its rows, so this one tells them: `groupToggles` publishes.
    let groupToggles = ChatStepGroupToggles()

    func isGroupExpanded(_ id: String, default defaultValue: Bool) -> Bool {
        followConversation()
        return states[Self.groupKey(id)] ?? defaultValue
    }

    func willToggleGroup(_ id: String, to expanded: Bool) {
        engine?.userWillToggleRow()
        followConversation()
        states[Self.groupKey(id)] = expanded
        groupToggles.revision &+= 1
    }

    private static func groupKey(_ id: String) -> String { "steps:" + id }

    private func followConversation() {
        let current = currentConversation()
        let switched = current.profile != conversation.profile
            || (!conversation.equivalentSessionIDs.isEmpty
                && conversation.equivalentSessionIDs.isDisjoint(with: current.equivalentSessionIDs))
        if switched {
            states.removeAll()
        }
        conversation = current
    }
}

/// By identity, so ChatView handing down the same instance on every body
/// evaluation never invalidates the rows that read it.
extension ChatRowDisclosure: Equatable {
    nonisolated static func == (lhs: ChatRowDisclosure, rhs: ChatRowDisclosure) -> Bool {
        lhs === rhs
    }
}

/// Observed by the step rows only, so opening or closing a run re-renders
/// them and nothing else in the transcript.
@MainActor
final class ChatStepGroupToggles: ObservableObject {
    @Published var revision: UInt64 = 0
}

private struct ChatRowDisclosureKey: EnvironmentKey {
    static let defaultValue: ChatRowDisclosure? = nil
}

extension EnvironmentValues {
    /// Nil outside the chat transcript; rows then keep their own state.
    var chatRowDisclosure: ChatRowDisclosure? {
        get { self[ChatRowDisclosureKey.self] }
        set { self[ChatRowDisclosureKey.self] = newValue }
    }
}
