import Foundation

/// A chat left while its reply was still coming (all-live stage 2). Hermes
/// keeps streaming that reply on the same socket after another chat opens,
/// and Conduit used to drop it. Now the left chat keeps its own `ChatState`,
/// seeded from the screen's as it's left, and every event of its turn
/// applies to it through the same stream handling as the chat on screen
/// (`AppState.act(on:)`): the reply's words, its tool steps and its
/// thinking. Going back to the chat shows its rows as far as they got, at
/// once, while Hermes sends the transcript. Hermes' own rows still replace
/// these as the chat opens: this copy is shown the way a saved copy is, and
/// nothing acts on it.
///
/// Decision cards Hermes raises while it's away (a question, an approval)
/// show when Hermes' rows land; the chat's row in Chats says it waits.
struct BackgroundChat: Equatable {
    /// Every id the chat answers to. A runtime id Hermes binds to it while
    /// it's away is looked up in the identity index on each event instead,
    /// since a runtime id can be reassigned to another chat.
    let sessionIDs: Set<String>
    /// The id its saved copy is kept under, when its row is listed.
    let durableSessionID: String?
    let title: String
    let dashboardID: UUID
    let profile: String
    /// Kept in memory only, as a Bot Chat's copy is: never saved as a file.
    let isBotChat: Bool
    /// The chat's own transcript and turn, which its events apply to.
    let state: ChatState
    /// When the chat was left. The list keeps the newest first by when each
    /// joined it.
    let leftAt: Date

    /// How many left chats are followed at once. A fifth pushes out the
    /// oldest whose reply has finished, or else the oldest.
    static let limit = 4

    /// A left chat whose rows and live turn are `state`'s.
    init(
        sessionIDs: Set<String>,
        durableSessionID: String?,
        title: String,
        dashboardID: UUID,
        profile: String,
        isBotChat: Bool,
        state: ChatState,
        leftAt: Date = Date()
    ) {
        self.sessionIDs = sessionIDs
        self.durableSessionID = durableSessionID
        self.title = title
        self.dashboardID = dashboardID
        self.profile = profile
        self.isBotChat = isBotChat
        self.state = state
        self.leftAt = leftAt
    }

    /// A left chat with `rows` and the reply streaming so far, its turn
    /// running.
    @MainActor
    init(
        sessionIDs: Set<String>,
        durableSessionID: String?,
        title: String,
        dashboardID: UUID,
        profile: String,
        isBotChat: Bool,
        rows: [ChatMessage],
        streamingText: String,
        leftAt: Date = Date()
    ) {
        let state = ChatState()
        state.messages = rows
        state.streamingBuffer = streamingText
        state.turnState = .running
        self.init(
            sessionIDs: sessionIDs,
            durableSessionID: durableSessionID,
            title: title,
            dashboardID: dashboardID,
            profile: profile,
            isBotChat: isBotChat,
            state: state,
            leftAt: leftAt
        )
    }

    static func == (lhs: BackgroundChat, rhs: BackgroundChat) -> Bool {
        lhs.state === rhs.state
            && lhs.sessionIDs == rhs.sessionIDs
            && lhs.durableSessionID == rhs.durableSessionID
            && lhs.dashboardID == rhs.dashboardID
            && lhs.profile == rhs.profile
            && lhs.leftAt == rhs.leftAt
    }

    func answers(to sessionID: String) -> Bool {
        !sessionID.isEmpty && sessionIDs.contains(sessionID)
    }

    /// Whether its turn still runs.
    @MainActor
    var isRunning: Bool { state.turnState.isRunning }

    /// Its rows as a saved copy shows them: the words a tool step or an
    /// interim note cut off read as the reply's own until the final row
    /// takes their place (the chat removes them as its reply completes),
    /// and the reply streaming now and the thinking card live now are rows
    /// of their own.
    @MainActor
    var rows: [ChatMessage] {
        var rows = state.messages.map { row -> ChatMessage in
            guard row.role == .partial else { return row }
            var copy = ChatMessage(id: row.id, role: .assistant, content: row.content, timestamp: row.timestamp, author: row.author)
            copy.reasoning = row.reasoning
            return copy
        }
        if let segment = state.liveTurn.reasoningSegment, !state.reasoningBuffer.isEmpty {
            rows.append(ChatMessage(
                id: segment.id,
                role: .reasoning,
                content: state.reasoningBuffer,
                timestamp: segment.timestamp,
                author: profile
            ))
        }
        let reply = state.streamingBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reply.isEmpty {
            rows.append(ChatMessage(
                id: "background-reply",
                role: .assistant,
                content: state.streamingBuffer,
                timestamp: Self.rowTimestampFormatter.string(from: Date()),
                author: profile
            ))
        }
        return rows
    }

    private static let rowTimestampFormatter = ISO8601DateFormatter()

    /// The list after `chat` joins it: one entry per chat, newest first,
    /// at most `limit`, letting go of finished replies before running ones.
    @MainActor
    static func adding(_ chat: BackgroundChat, to list: [BackgroundChat]) -> [BackgroundChat] {
        var kept = list.filter { $0.sessionIDs.isDisjoint(with: chat.sessionIDs) }
        kept.insert(chat, at: 0)
        while kept.count > limit {
            if let finished = kept.lastIndex(where: { !$0.isRunning }) {
                kept.remove(at: finished)
            } else {
                kept.removeLast()
            }
        }
        return kept
    }
}
