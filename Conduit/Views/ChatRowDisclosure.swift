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
/// so the environment value never changes identity.
@MainActor
final class ChatRowDisclosure {
    weak var engine: ChatScrollEngine?
    private var states: [String: Bool] = [:]

    func isExpanded(_ id: String, default defaultValue: Bool) -> Bool {
        states[id] ?? defaultValue
    }

    /// Call before changing the row's height, inside the same tap.
    func willToggle(_ id: String?, to expanded: Bool) {
        engine?.userWillToggleRow()
        if let id {
            states[id] = expanded
        }
    }
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
