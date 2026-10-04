import XCTest
import UIKit
@testable import Conduit

/// Quoting chat text into the composer (#385). Extensions of existing
/// classes, so the CI planner's class inventory is unchanged.
private final class QuoteRecorder {
    var quotes: [String] = []

    @MainActor
    func action(available: Bool = true) -> ChatQuoteAction {
        ChatQuoteAction(owner: self, isAvailable: { available }) { [weak self] text in self?.quotes.append(text) }
    }
}

extension ChatTextSelectionTests {
    // MARK: - Quote formatting

    func testBlockquotePrefixesEveryLineAndKeepsBlankLinesInsideTheQuote() {
        XCTAssertEqual(ChatQuote.blockquote("first\n\nsecond\n"), "> first\n>\n> second")
        XCTAssertEqual(ChatQuote.blockquote("\n\n  indented code  \r\nnext"), ">   indented code\n> next")
        XCTAssertEqual(ChatQuote.blockquote(" \n \t\n"), "", "whitespace has nothing to quote")
    }

    func testQuoteGoesBelowTheExistingDraftWithRoomForTheReply() {
        XCTAssertEqual(ChatQuote.inserting("> quoted", into: ""), "> quoted\n\n")
        XCTAssertEqual(ChatQuote.inserting("> quoted", into: "My note  \n"), "My note\n\n> quoted\n\n")
        XCTAssertEqual(ChatQuote.inserting("", into: "unchanged"), "unchanged")
    }

    func testExcerptReadsLikePlainText() {
        let markdown = "## Plan\n\n- **First** step\n```swift\nlet x = 1\n```\n1. Done `now`"
        XCTAssertEqual(ChatQuote.excerpt(of: markdown), "Plan First step let x = 1 Done now")
        XCTAssertEqual(ChatQuote.excerpt(of: String(repeating: "a", count: 30), limit: 10), "aaaaaaaaaa…")
    }

    // MARK: - Whole-reply envelope

    func testReplyEnvelopeRoundTripsTheQuoteAndTheMessage() throws {
        let sent = ReplyQuoteEnvelope.outboundText(quoting: "Line one\n\nLine two", message: "My reply")
        XCTAssertEqual(sent, "[Replying to your earlier message]\n> Line one\n>\n> Line two\n\nMy reply")

        let parsed = try XCTUnwrap(ReplyQuoteEnvelope.parse(sent))
        XCTAssertEqual(parsed.quote, "Line one\n\nLine two")
        XCTAssertEqual(parsed.message, "My reply")
    }

    func testReplyEnvelopeWithoutWordsStillParses() throws {
        // A reply quoted with only an attachment carries no words of its own.
        let parsed = try XCTUnwrap(ReplyQuoteEnvelope.parse(
            ReplyQuoteEnvelope.outboundText(quoting: "Earlier", message: "")
        ))
        XCTAssertEqual(parsed.quote, "Earlier")
        XCTAssertEqual(parsed.message, "")
    }

    func testOrdinaryMessagesAreNotTakenForAReplyEnvelope() {
        XCTAssertNil(ReplyQuoteEnvelope.parse("> a quote typed by hand\n\nreply"))
        XCTAssertNil(ReplyQuoteEnvelope.parse("[Replying to your earlier message]"))
        XCTAssertNil(ReplyQuoteEnvelope.parse("[Replying to your earlier message]\nno quote"))
        XCTAssertNil(ReplyQuoteEnvelope.parse("[Replying to your earlier message]\n> q\nno blank line"))
    }

    func testReplyReferenceRidesWithMessagesButNotSlashCommands() {
        let reference = ComposerReplyReference(authorName: "Hermes", text: "Earlier answer")
        let envelope = "[Replying to your earlier message]\n> Earlier answer\n\n"
        XCTAssertEqual(
            ComposerReplyReference.outboundText("Thanks", hasAttachments: false, replyingTo: reference),
            envelope + "Thanks"
        )
        XCTAssertEqual(
            ComposerReplyReference.outboundText("  /compact", hasAttachments: false, replyingTo: reference),
            "  /compact"
        )
        // What AppState sends as a message rather than a command keeps it.
        XCTAssertEqual(
            ComposerReplyReference.outboundText("/", hasAttachments: false, replyingTo: reference),
            envelope + "/"
        )
        XCTAssertEqual(
            ComposerReplyReference.outboundText("/look", hasAttachments: true, replyingTo: reference),
            envelope + "/look"
        )
        XCTAssertEqual(ComposerReplyReference.outboundText("Thanks", hasAttachments: false, replyingTo: nil), "Thanks")
        XCTAssertEqual(reference.excerpt, "Earlier answer")
    }

    func testRefusedQuotedReplyIsResentOnlyWhileItsChipIsAttached() {
        // After a chat takeover the composer resends its draft only when it
        // rebuilds the refused text, envelope included.
        let reference = ComposerReplyReference(authorName: "Hermes", text: "Earlier answer")
        let refused = ComposerReplyReference.outboundText("Thanks", hasAttachments: false, replyingTo: reference)
        let takeover = ChatTakeoverState(
            sessionID: "s1",
            sessionIDs: ["s1"],
            surface: "desktop",
            refusedText: refused,
            phase: .ready
        )

        XCTAssertTrue(takeover.isRefusedMessage(
            ComposerReplyReference.outboundText("Thanks ", hasAttachments: false, replyingTo: reference)
        ))
        XCTAssertFalse(takeover.isRefusedMessage(
            ComposerReplyReference.outboundText("Thanks", hasAttachments: false, replyingTo: nil)
        ))
    }

    // MARK: - Selection menu and pill

    @MainActor
    func testSelectionMenuOffersQuoteAfterCopyOnlyInsideAChat() throws {
        let bridge = SelectableTextView(text: "Hello quoted world").makeCoordinator()
        let delegate: UITextViewDelegate = bridge
        let textView = SelectableTextView.makeTextView()
        textView.attributedText = NSAttributedString(string: "Hello quoted world")
        let copy = UIAction(title: "Copy") { _ in }
        let lookUp = UIAction(title: "Look Up") { _ in }
        let suggested: [UIMenuElement] = [
            UIMenu(title: "", identifier: .standardEdit, options: .displayInline, children: [copy]),
            lookUp
        ]
        let range = NSRange(location: 6, length: 6)

        // Outside a chat the delegate defers to the system menu.
        XCTAssertNil(delegate.textView?(textView, editMenuForTextIn: range, suggestedActions: suggested) ?? nil)

        // So it does while the composer is locked (saved copy, reconnecting).
        let recorder = QuoteRecorder()
        bridge.quoteAction = recorder.action(available: false)
        XCTAssertNil(delegate.textView?(textView, editMenuForTextIn: range, suggestedActions: suggested) ?? nil)

        bridge.quoteAction = recorder.action()
        let menu = try XCTUnwrap(delegate.textView?(textView, editMenuForTextIn: range, suggestedActions: suggested) ?? nil)
        XCTAssertEqual(menu.children.count, 3)
        XCTAssertEqual((menu.children[0] as? UIMenu)?.identifier, .standardEdit)
        XCTAssertEqual((menu.children[1] as? UIAction)?.title, AppLocalization.string("Quote"))
        XCTAssertTrue(menu.children[2] === lookUp)

        // Without a standard edit group, Quote leads.
        let elements = SelectableTextView.Coordinator.editMenuElements([lookUp], adding: copy)
        XCTAssertTrue(elements.first === copy)
    }

    @MainActor
    func testQuoteHandsTheSelectedTextToTheComposerAndClearsTheSelection() {
        let textView = SelectableTextView.makeTextView()
        textView.attributedText = NSAttributedString(string: "Hello quoted world")
        textView.selectedRange = NSRange(location: 6, length: 6)
        let recorder = QuoteRecorder()

        SelectableTextView.Coordinator.quoteSelection(
            in: textView,
            range: NSRange(location: 6, length: 6),
            with: recorder.action()
        )

        XCTAssertEqual(recorder.quotes, ["quoted"])
        XCTAssertEqual(textView.selectedRange.length, 0)
    }

    @MainActor
    func testQuotingOnlyWhitespaceKeepsTheSelection() {
        let textView = SelectableTextView.makeTextView()
        textView.attributedText = NSAttributedString(string: "Hello   world")
        textView.selectedRange = NSRange(location: 5, length: 3)
        let recorder = QuoteRecorder()

        SelectableTextView.Coordinator.quoteSelection(
            in: textView,
            range: NSRange(location: 5, length: 3),
            with: recorder.action()
        )

        XCTAssertEqual(recorder.quotes, [])
        XCTAssertEqual(textView.selectedRange, NSRange(location: 5, length: 3))
    }

    @MainActor
    func testQuoteFromTheMenuTakesTheWholeCrossBlockSelection() {
        let selectionCoordinator = MarkdownSelectionCoordinator()
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "first", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "second", order: 1, separatorBefore: "\n\n")
        ]
        selectionCoordinator.replaceSegments(descriptors, revision: "quote-bridge-v1")
        let view = SelectableTextView(
            text: "First",
            selectionCoordinator: selectionCoordinator,
            selectionSegment: descriptors[0]
        )
        let bridge = view.makeCoordinator()
        let hostView = view.makeUIViewForTests(coordinator: bridge)
        let secondTextView = SelectableTextView.makeTextView()
        secondTextView.attributedText = NSAttributedString(string: "Second")
        selectionCoordinator.register(descriptor: descriptors[1], textView: secondTextView)
        selectionCoordinator.beginSelection(segmentID: "first", offset: 2, windowPoint: .zero)
        selectionCoordinator.updateSelection(segmentID: "second", offset: 3, windowPoint: CGPoint(x: 0, y: 10))
        let recorder = QuoteRecorder()

        SelectableTextView.Coordinator.quoteSelection(
            in: hostView.mountedTextView,
            range: NSRange(location: 2, length: 3),
            with: recorder.action()
        )

        XCTAssertEqual(recorder.quotes, ["rst\n\nSec"])
        XCTAssertFalse(selectionCoordinator.hasActiveSelection)
    }

    @MainActor
    func testPillQuotesTheCrossBlockSelectionOnlyInsideAChat() throws {
        let coordinator = MarkdownSelectionCoordinator()
        let descriptors = [
            MarkdownSelectionSegmentDescriptor(id: "first", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "second", order: 1, separatorBefore: "\n\n")
        ]
        coordinator.replaceSegments(descriptors, revision: "quote-pill-v1")
        let firstTextView = SelectableTextView.makeTextView()
        firstTextView.attributedText = NSAttributedString(string: "First")
        coordinator.register(descriptor: descriptors[0], textView: firstTextView)
        let secondTextView = SelectableTextView.makeTextView()
        secondTextView.attributedText = NSAttributedString(string: "Second")
        coordinator.register(descriptor: descriptors[1], textView: secondTextView)
        coordinator.beginSelection(segmentID: "first", offset: 2, windowPoint: .zero)
        coordinator.updateSelection(segmentID: "second", offset: 3, windowPoint: CGPoint(x: 0, y: 10))

        let container = MarkdownSelectionHandleContainerView(frame: .zero)
        container.coordinator = coordinator
        XCTAssertEqual(container.quotePill?.accessibilityIdentifier, "selection.quotePill")

        // The selection fixture and other non-chat surfaces have no Quote.
        container.quoteActiveSelection()
        XCTAssertTrue(coordinator.hasActiveSelection)

        // Nor does a chat whose composer is locked.
        let recorder = QuoteRecorder()
        container.quoteAction = recorder.action(available: false)
        container.quoteActiveSelection()
        XCTAssertTrue(coordinator.hasActiveSelection)
        XCTAssertEqual(recorder.quotes, [])

        container.quoteAction = recorder.action()
        container.quoteActiveSelection()

        XCTAssertEqual(recorder.quotes, ["rst\n\nSec"])
        XCTAssertFalse(coordinator.hasActiveSelection)
    }
}

extension ComposerDraftStoreTests {
    func testDraftHoldingOnlyAQuotedReplyIsKept() {
        let store = ComposerDraftStore(capacity: 12)
        let key = ComposerDraftKey(profile: "default", sessionID: "session-a")
        let reference = ComposerReplyReference(authorName: "Hermes", text: "Earlier answer")
        let draft = ComposerDraft(text: "", attachments: [], replyReference: reference)

        XCTAssertFalse(draft.isEmpty)
        store.save(draft, for: key)
        XCTAssertEqual(store.draft(for: key).replyReference, reference)

        store.save(ComposerDraft(text: "", attachments: []), for: key)
        XCTAssertNil(store.draft(for: key).replyReference)
    }
}
