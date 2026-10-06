//
//  ComposerFullEditorTests.swift
//  ConduitTests
//
//  When the composer offers its full-screen editor (#335).
//

import XCTest
@testable import Conduit

final class ComposerFullEditorTests: XCTestCase {
    func testShortDraftsHaveNoExpandButton() {
        XCTAssertFalse(ComposerBar.showsFullEditorButton(measuredHeight: ComposerPasteTextView.minimumHeight))
        XCTAssertFalse(ComposerBar.showsFullEditorButton(measuredHeight: 60), "two lines read fine in place")
    }

    func testLongDraftsOfferTheFullEditor() {
        XCTAssertTrue(ComposerBar.showsFullEditorButton(measuredHeight: ComposerBar.fullEditorThreshold))
        XCTAssertTrue(ComposerBar.showsFullEditorButton(measuredHeight: ComposerPasteTextView.maximumHeight))
    }

    func testTheFullEditorTellsDictationFromTyping() {
        let dictated = ComposerDictation.draft(before: "Note:", dictated: "buy milk")
        XCTAssertFalse(ComposerDictation.isTyping(dictated, dictationWrote: dictated), "dictation's own write keeps it going")
        XCTAssertTrue(ComposerDictation.isTyping(dictated + "s", dictationWrote: dictated), "a keystroke after it is typing")
        XCTAssertTrue(ComposerDictation.isTyping("Note:", dictationWrote: nil), "no dictation running: every change is typing")
    }

    func testADictationResultNeverWritesOverTyping() {
        XCTAssertTrue(ComposerDictation.draftIsAsDictationLeftIt("Note:", prefix: "Note:", lastWrite: nil), "before its first words")
        let dictated = ComposerDictation.draft(before: "Note:", dictated: "buy")
        XCTAssertTrue(ComposerDictation.draftIsAsDictationLeftIt(dictated, prefix: "Note:", lastWrite: dictated))
        XCTAssertFalse(
            ComposerDictation.draftIsAsDictationLeftIt(dictated + "x", prefix: "Note:", lastWrite: dictated),
            "a keystroke the sheet hasn't reported yet"
        )
        XCTAssertFalse(ComposerDictation.draftIsAsDictationLeftIt("Note: x", prefix: "Note:", lastWrite: nil), "typed before the first words")
    }
}
