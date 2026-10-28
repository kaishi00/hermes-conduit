//
//  PendingComposerSend.swift
//  Conduit
//
//  A message sent while its chat was still on its way: the saved copy at
//  launch, a New Chat Hermes hasn't created yet, or a chat reconnecting
//  (AppState+PendingSend.swift).
//

import Foundation

/// It shows as "Sends when connected" and goes through the normal send once
/// its chat is ready. It is tied to that chat: if another one opens instead,
/// or the app stops first, it goes back into its chat's draft and is never
/// sent on its own.
struct PendingComposerSend: Codable, Equatable, Identifiable {
    let id: UUID
    /// The words as typed: what the bubble shows and what goes back into
    /// the composer if it isn't sent.
    var draftText: String
    /// A whole reply attached with its Quote button (#385), kept as its
    /// parts so it can go back into the composer as the chip.
    var replyAuthor: String?
    var replyText: String?
    let dashboardID: UUID
    let profile: String
    /// Every id its chat is known by. Empty for a New Chat.
    let sessionIDs: Set<String>
    /// The id its chat's draft is kept under.
    let draftSessionID: String
    /// Sent in a New Chat Hermes hadn't created yet.
    let isNewChat: Bool
    /// Its chat's title, for the notice when it isn't sent.
    let title: String
    let queuedAt: Date

    /// Every id its chat answers to, the draft's among them.
    var chatSessionIDs: Set<String> {
        isNewChat ? [] : sessionIDs.union([draftSessionID])
    }

    var draftKey: ComposerDraftKey {
        ComposerDraftKey(profile: profile, sessionID: draftSessionID)
    }

    var replyReference: ComposerReplyReference? {
        guard let replyAuthor, let replyText else { return nil }
        return ComposerReplyReference(authorName: replyAuthor, text: replyText)
    }

    /// What goes to Hermes: the words, with the quoted reply when there is one.
    var outboundText: String {
        ComposerReplyReference.outboundText(draftText, hasAttachments: false, replyingTo: replyReference)
    }

    /// The draft it goes back into the composer as.
    var draft: ComposerDraft {
        ComposerDraft(text: draftText, attachments: [], replyReference: replyReference)
    }

    init(
        id: UUID = UUID(),
        draftText: String,
        replyReference: ComposerReplyReference?,
        dashboardID: UUID,
        profile: String,
        sessionIDs: Set<String>,
        draftSessionID: String,
        isNewChat: Bool,
        title: String,
        queuedAt: Date = Date()
    ) {
        self.id = id
        self.draftText = draftText
        self.replyAuthor = replyReference?.authorName
        self.replyText = replyReference?.text
        self.dashboardID = dashboardID
        self.profile = profile
        self.sessionIDs = sessionIDs
        self.draftSessionID = draftSessionID
        self.isNewChat = isNewChat
        self.title = title
        self.queuedAt = queuedAt
    }

    /// Another send before this one went: one message, in the order typed.
    /// A reply already attached stays the one quoted.
    func appending(_ more: String, replyReference moreReply: ComposerReplyReference?) -> PendingComposerSend {
        var combined = self
        combined.draftText = ComposerDraft.joined(draftText, more)
        if combined.replyReference == nil, let moreReply {
            combined.replyAuthor = moreReply.authorName
            combined.replyText = moreReply.text
        }
        return combined
    }
}

extension ComposerDraft {
    /// Two drafts' words as one, the first above the second.
    static func joined(_ first: String, _ second: String) -> String {
        let top = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let bottom = second.trimmingCharacters(in: .whitespacesAndNewlines)
        if top.isEmpty { return second }
        if bottom.isEmpty { return first }
        return first + "\n\n" + second
    }

    /// `restored` put back over this draft: its words first, then what was
    /// typed since; the reply chip already there stays, and a second chip's
    /// reply comes back as a quote above its words rather than being lost.
    func restoring(_ restored: ComposerDraft) -> ComposerDraft {
        var restoredText = restored.text
        if let kept = replyReference, let other = restored.replyReference, other != kept {
            restoredText = Self.joined(ChatQuote.blockquote(other.text), restoredText)
        }
        return ComposerDraft(
            text: Self.joined(restoredText, text),
            attachments: attachments + restored.attachments,
            replyReference: replyReference ?? restored.replyReference
        )
    }
}
