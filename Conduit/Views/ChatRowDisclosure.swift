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
/// And it tells the scroller first, so the row the reader tapped stays
/// where it is (TranscriptScroller.userWillToggleRow).
///
/// Not observable: a row reads it when it is built and writes it when
/// tapped, so a toggle re-renders only that row. One instance per chat view,
/// so the environment value never changes identity. Choices last for one
/// conversation: message ids are not unique across them (rows resumed
/// without an id are numbered from 0, "0-reasoning" and so on), so another
/// conversation starts from the defaults. Another spelling of the same
/// conversation (a new chat getting its id) keeps them. Rows without a
/// message id ("Show all" in a long reply, the review summary) only tell
/// the scroller and keep their own state as before.
@MainActor
final class ChatRowDisclosure {
    weak var scroller: TranscriptScroller?
    /// The conversation on screen; ChatView reads it from AppState.
    var currentConversation: @MainActor () -> ChatScrollSessionIdentity = { .none }
    private var conversation = ChatScrollSessionIdentity.none
    private var states: [String: Bool] = [:]
    /// What Show thinking changed, per run, so Hide thinking puts it back.
    private var beforeThinking: [String: [String: Bool?]] = [:]

    func isExpanded(_ id: String, default defaultValue: Bool) -> Bool {
        followConversation()
        return states[id] ?? defaultValue
    }

    /// Call before changing the row's height, inside the same tap.
    func willToggle(_ id: String?, to expanded: Bool) {
        scroller?.userWillToggleRow(id)
        guard let id else { return }
        followConversation()
        states[id] = expanded
    }

    /// A turn's run of steps, or a run of reviews, opens and closes as one
    /// card, drawn by all of its rows, so this one tells them:
    /// `groupToggles` publishes. Keyed by the run's first row.
    let groupToggles = ChatStepGroupToggles()

    func isGroupExpanded(_ id: String, default defaultValue: Bool) -> Bool {
        followConversation()
        return states[Self.groupKey(id)] ?? defaultValue
    }

    func willToggleGroup(_ id: String, to expanded: Bool) {
        scroller?.userWillToggleRow(id)
        followConversation()
        states[Self.groupKey(id)] = expanded
        groupToggles.revision &+= 1
    }

    /// Thinking the reader asked to see in one run while Settings > Chat's
    /// Thinking is On request (ChatThinkingReveal).
    func showsThinking(in groupID: String) -> Bool {
        followConversation()
        return states[Self.thinkingKey(groupID)] ?? false
    }

    /// Showing it opens the run and its thoughts too, so what appears is
    /// the thinking itself, not one more folded line; hiding it puts them
    /// back as they were.
    func willShowThinking(in group: ChatStepGroup, _ shown: Bool) {
        scroller?.userWillToggleRow(group.id)
        followConversation()
        let flag = Self.thinkingKey(group.id)
        if shown {
            if states[flag] != true {
                let opened = [Self.groupKey(group.id)] + group.members.filter(\.isThinking).map(\.messageID)
                beforeThinking[group.id] = Dictionary(opened.map { ($0, states[$0]) }, uniquingKeysWith: { first, _ in first })
                for key in opened { states[key] = true }
            }
            states[flag] = true
        } else {
            for (key, value) in beforeThinking.removeValue(forKey: group.id) ?? [:] {
                states[key] = value
            }
            states[flag] = false
        }
        groupToggles.revision &+= 1
    }

    private static func groupKey(_ id: String) -> String { "steps:" + id }
    private static func thinkingKey(_ id: String) -> String { "thinking:" + id }

    private func followConversation() {
        let current = currentConversation()
        let switched = current.profile != conversation.profile
            || (!conversation.equivalentSessionIDs.isEmpty
                && conversation.equivalentSessionIDs.isDisjoint(with: current.equivalentSessionIDs))
        if switched {
            states.removeAll()
            beforeThinking.removeAll()
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
