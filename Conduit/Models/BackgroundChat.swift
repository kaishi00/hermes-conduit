import Foundation

/// A chat left while its reply was still coming (all-live stage 2). Hermes
/// keeps streaming that reply on the same socket after another chat opens,
/// and Conduit used to drop it. Now the left chat's rows and the reply's
/// text so far stay here and grow as the reply streams, so going back to
/// the chat shows the reply as far as it got, at once, while Hermes sends
/// the transcript. Hermes' own rows still replace these as the chat opens:
/// this copy is shown the way a saved copy is, and nothing acts on it.
///
/// Only the reply's words are followed. Tool steps, reasoning and decision
/// cards that come while the chat is away show when Hermes' rows land.
struct BackgroundChat: Equatable {
    /// Every id the chat answers to.
    let sessionIDs: Set<String>
    /// The id its saved copy is kept under, when its row is listed.
    let durableSessionID: String?
    let title: String
    let dashboardID: UUID
    let profile: String
    /// Kept in memory only, as a Bot Chat's copy is: never saved as a file.
    let isBotChat: Bool
    private(set) var rows: [ChatMessage]
    /// The reply streaming now, and its row while it has one.
    private(set) var replyText = ""
    private(set) var replyRowID: String?
    private(set) var isRunning = true
    /// When the chat was left. The list keeps the newest first by when each
    /// joined it.
    private(set) var leftAt: Date

    /// How many left chats are followed at once. A fifth pushes out the
    /// oldest whose reply has finished, or else the oldest.
    static let limit = 4

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
        self.sessionIDs = sessionIDs
        self.durableSessionID = durableSessionID
        self.title = title
        self.dashboardID = dashboardID
        self.profile = profile
        self.isBotChat = isBotChat
        // Partials are the streamed text a tool step cut off: they read as
        // the reply's own words in a saved copy.
        self.rows = rows.map { row in
            guard row.role == .partial else { return row }
            var copy = ChatMessage(id: row.id, role: .assistant, content: row.content, timestamp: row.timestamp, author: row.author)
            copy.reasoning = row.reasoning
            return copy
        }
        self.leftAt = leftAt
        let text = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            replyText = streamingText
            appendReplyRow()
        }
    }

    func answers(to sessionID: String) -> Bool {
        !sessionID.isEmpty && sessionIDs.contains(sessionID)
    }

    /// What applying an event did, so the app knows whether to save it.
    enum Outcome: Equatable {
        /// Not a reply event this copy follows.
        case ignored
        case updated
        /// The reply finished, failed or was stopped.
        case ended
    }

    mutating func apply(_ event: StreamEvent) -> Outcome {
        switch event {
        case .messageStart:
            closeReply()
            isRunning = true
            return .updated
        case .messageDelta(_, let text):
            guard !text.isEmpty else { return .ignored }
            isRunning = true
            replyText += text
            if let replyRowID, let index = rows.lastIndex(where: { $0.id == replyRowID }) {
                rows[index].content = replyText
            } else {
                appendReplyRow()
            }
            return .updated
        case .messageInterim(_, let text, let alreadyStreamed):
            let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if alreadyStreamed, let replyRowID, let index = rows.lastIndex(where: { $0.id == replyRowID }) {
                if !content.isEmpty { rows[index].content = content }
            } else if !content.isEmpty {
                rows.append(Self.row(id: "background-interim-\(UUID().uuidString)", content: content, author: profile))
            }
            closeReply()
            return .updated
        case .messageComplete(_, let messageId, let content, _, _):
            let final = (content ?? replyText).trimmingCharacters(in: .whitespacesAndNewlines)
            if let replyRowID, let index = rows.lastIndex(where: { $0.id == replyRowID }) {
                if !final.isEmpty { rows[index].content = final }
            } else if !final.isEmpty, rows.last?.content != final {
                let id = messageId.flatMap { $0.isEmpty ? nil : $0 } ?? "background-reply-\(UUID().uuidString)"
                rows.append(Self.row(id: id, content: final, author: profile))
            }
            closeReply()
            isRunning = false
            return .ended
        case .messageError, .messageInterrupted:
            closeReply()
            isRunning = false
            return .ended
        case .sessionBusy(_, let busy):
            guard !busy else { return .ignored }
            guard isRunning else { return .ignored }
            closeReply()
            isRunning = false
            return .ended
        default:
            return .ignored
        }
    }

    private mutating func appendReplyRow() {
        let id = "background-reply-\(UUID().uuidString)"
        rows.append(Self.row(id: id, content: replyText, author: profile))
        replyRowID = id
    }

    private mutating func closeReply() {
        replyText = ""
        replyRowID = nil
    }

    private static let rowTimestampFormatter = ISO8601DateFormatter()

    private static func row(id: String, content: String, author: String) -> ChatMessage {
        ChatMessage(
            id: id,
            role: .assistant,
            content: content,
            timestamp: rowTimestampFormatter.string(from: Date()),
            author: author
        )
    }

    /// The list after `chat` joins it: one entry per chat, newest first,
    /// at most `limit`, letting go of finished replies before running ones.
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
