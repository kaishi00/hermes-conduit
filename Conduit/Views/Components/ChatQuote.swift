import SwiftUI

/// Quoting chat text into the composer (issue #385). Two ways in:
///
/// - Selecting text in the transcript and choosing Quote puts the selection
///   in the draft as a Markdown blockquote, ready for a reply underneath.
/// - The Quote button under a reply attaches the whole reply instead: the
///   composer shows a removable "Replying to…" chip and the reply travels
///   with the next message (see `ReplyQuoteEnvelope`).
enum ChatQuote {
    /// `text` as a Markdown blockquote: every line gets `> `, blank lines a
    /// bare `>` so the quote stays one block. Indentation is kept (code and
    /// nested lists in a quoted reply), trailing spaces and surrounding blank
    /// lines are dropped; text with nothing to quote gives "".
    static func blockquote(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        guard let first = lines.firstIndex(where: { !$0.isEmpty }),
              let last = lines.lastIndex(where: { !$0.isEmpty }) else { return "" }
        return lines[first...last]
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
    }

    /// The draft with `quote` added after whatever is already typed, then an
    /// empty line so the reply starts underneath it.
    static func inserting(_ quote: String, into draft: String) -> String {
        guard !quote.isEmpty else { return draft }
        let kept = draft.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return kept.isEmpty ? "\(quote)\n\n" : "\(kept)\n\n\(quote)\n\n"
    }

    /// A one-line plain-text preview of a Markdown reply for the chips:
    /// code fences, heading and list markers and emphasis are dropped, so
    /// "## Plan" previews as "Plan".
    static func excerpt(of markdown: String, limit: Int = 200) -> String {
        var words: [String] = []
        var length = 0
        for rawLine in markdown.components(separatedBy: .newlines) {
            // Enough for the preview; a long reply's tail is never scanned.
            if length > limit { break }
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { continue }
            line = line.replacingOccurrences(
                of: "^(?:>\\s*)*(?:#{1,6}\\s+|[-*+]\\s+(?:\\[[ xX]\\]\\s+)?|\\d+[.)]\\s+)?",
                with: "",
                options: .regularExpression
            )
            line = line.replacingOccurrences(of: "\\*\\*|__|`", with: "", options: .regularExpression)
            if !line.isEmpty {
                words.append(line)
                length += line.count + 1
            }
        }
        let joined = words.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard joined.count > limit else { return joined }
        return String(joined.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// The whole-reply quote as it travels to Hermes. The reply is sent ahead
/// of the user's words, behind a fixed marker line, as a Markdown quote:
///
///     [Replying to your earlier message]
///     > the earlier reply,
///     > line by line
///
///     the user's message
///
/// Hermes stores the text as sent, so the optimistic bubble and the saved
/// row match, and `parse` turns either back into a compact "Replying to"
/// card instead of repeating the whole reply in the user's bubble. Other
/// clients simply show the quote.
enum ReplyQuoteEnvelope {
    /// Protocol text, deliberately not localized: it is what Hermes and its
    /// model read, and what `parse` recognizes on reload.
    static let marker = "[Replying to your earlier message]"

    static func outboundText(quoting reply: String, message: String) -> String {
        let quote = ChatQuote.blockquote(reply)
        guard !quote.isEmpty else { return message }
        return "\(marker)\n\(quote)\n\n\(message)"
    }

    /// Splits a sent message back into the quoted reply (unquoted) and the
    /// user's own words, or nil when `content` is not an envelope.
    static func parse(_ content: String) -> (quote: String, message: String)? {
        guard content.hasPrefix(marker + "\n") else { return nil }
        var lines = content.dropFirst(marker.count + 1)
            .split(separator: "\n", omittingEmptySubsequences: false)[...]
        var quoted: [Substring] = []
        while let line = lines.first, line.hasPrefix(">") {
            let unquoted = line.dropFirst()
            quoted.append(unquoted.hasPrefix(" ") ? unquoted.dropFirst() : unquoted)
            lines = lines.dropFirst()
        }
        guard !quoted.isEmpty else { return nil }
        if let separator = lines.first {
            guard separator.isEmpty else { return nil }
            lines = lines.dropFirst()
        }
        return (quoted.joined(separator: "\n"), lines.joined(separator: "\n"))
    }
}

/// A whole earlier reply attached to the next message (the composer's
/// "Replying to…" chip).
struct ComposerReplyReference: Equatable {
    let messageID: String
    let authorName: String
    let text: String
    /// Worked out once: the chip re-renders with every composer update.
    let excerpt: String

    init(messageID: String, authorName: String, text: String) {
        self.messageID = messageID
        self.authorName = authorName
        self.text = text
        self.excerpt = ChatQuote.excerpt(of: text)
    }

    /// The text to submit for `draft`. A slash command is left alone: the
    /// reply stays attached for the next message instead.
    static func outboundText(
        _ draft: String,
        hasAttachments: Bool,
        replyingTo reference: ComposerReplyReference?
    ) -> String {
        guard let reference, appliesToDraft(draft, hasAttachments: hasAttachments) else { return draft }
        return ReplyQuoteEnvelope.outboundText(quoting: reference.text, message: draft)
    }

    /// False only for what AppState runs as a slash command: a `/` and a
    /// command name, with no attachments. A bare `/`, or a `/…` sent with an
    /// attachment, goes out as a message and carries the reply.
    static func appliesToDraft(_ draft: String, hasAttachments: Bool) -> Bool {
        guard !hasAttachments else { return true }
        let trimmed = draft.drop(while: { $0.isWhitespace })
        guard trimmed.hasPrefix("/") else { return true }
        return trimmed.drop(while: { $0 == "/" }).allSatisfy { $0.isWhitespace }
    }
}

/// Puts selected chat text into the composer as a quote. Only the chat
/// screen provides one, so text outside a chat (Kanban logs, voice sheets,
/// the selection fixture) shows no Quote action. Equal by owner, so a
/// re-created value does not count as an environment change and re-run
/// every transcript text view's update.
struct ChatQuoteAction: Equatable {
    private let owner: ObjectIdentifier
    private let handler: @MainActor (String) -> Void

    init(owner: AnyObject, handler: @escaping @MainActor (String) -> Void) {
        self.owner = ObjectIdentifier(owner)
        self.handler = handler
    }

    @MainActor
    func callAsFunction(_ text: String) {
        handler(text)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.owner == rhs.owner
    }
}

private struct ChatQuoteActionKey: EnvironmentKey {
    static let defaultValue: ChatQuoteAction? = nil
}

extension EnvironmentValues {
    var chatQuoteAction: ChatQuoteAction? {
        get { self[ChatQuoteActionKey.self] }
        set { self[ChatQuoteActionKey.self] = newValue }
    }
}

/// The compact "Replying to" card at the top of a sent message that quoted
/// a whole reply.
struct ReplyReferenceQuoteCard: View {
    let quote: String
    /// On the accent-colored user bubble the card uses white text.
    var onAccentSurface = true

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(primaryColor.opacity(0.7))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Label(AppLocalization.string("Replying to"), systemImage: "quote.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(primaryColor)
                Text(ChatQuote.excerpt(of: quote))
                    .font(.footnote)
                    .foregroundStyle(primaryColor.opacity(0.82))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(primaryColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var primaryColor: Color {
        onAccentSurface ? .white : .primary
    }
}
