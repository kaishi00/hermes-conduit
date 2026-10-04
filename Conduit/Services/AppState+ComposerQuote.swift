//
//  AppState+ComposerQuote.swift
//  Conduit
//
//  Quoting chat text into the composer (#385). The transcript asks here;
//  ComposerBar, which owns the draft, picks the request up and applies it.
//

import Foundation

/// One quote for the composer. Each request has its own id, so quoting the
/// same text twice still reaches the composer twice.
struct ComposerQuoteRequest: Equatable {
    enum Content: Equatable {
        /// Selected text, already a Markdown blockquote, added to the draft.
        case text(String)
        /// A whole reply, attached to the next message as a chip.
        case reply(ComposerReplyReference)
    }

    let id = UUID()
    let content: Content
}

extension AppState {
    /// Selected transcript text goes into the draft as a `>` quote.
    func quoteIntoComposer(_ selectedText: String) {
        let quote = ChatQuote.blockquote(selectedText)
        guard !quote.isEmpty else { return }
        composerQuoteRequest = ComposerQuoteRequest(content: .text(quote))
    }

    /// A reply's Quote button: the whole reply rides along with the next
    /// message, shown in the composer as a removable "Replying to…" chip.
    func replyInComposer(to message: ChatMessage) {
        guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let reference = ComposerReplyReference(
            messageID: message.id,
            authorName: profileDisplayName(activeProfile),
            text: message.content
        )
        composerQuoteRequest = ComposerQuoteRequest(content: .reply(reference))
    }
}
