//
//  ComposerFullEditorTests.swift
//  ConduitTests
//
//  When the composer offers its full-screen editor (#335).
//

import XCTest
@testable import Conduit

final class ComposerFullEditorTests: XCTestCase {
    /// #695: a running turn or notice expands the composer, but only typing
    /// hides the minimised call bar, so a call minimised in a chat can come back.
    func testOnlyTypingHidesTheMinimisedCallBar() {
        XCTAssertTrue(ComposerBar.hidesMinimisedCallBar(restsWhenIdle: true, isFocused: true))
        XCTAssertFalse(ComposerBar.hidesMinimisedCallBar(restsWhenIdle: true, isFocused: false), "a busy, unfocused composer keeps the bar")
        XCTAssertFalse(ComposerBar.hidesMinimisedCallBar(restsWhenIdle: false, isFocused: true), "the classic layout always shows it")
    }

    /// #762: V2 keeps Stop in the resting bar, so the big voice button
    /// beside it stays; steering still needs the controls row.
    func testStopAloneKeepsTheV2ComposerResting() {
        XCTAssertFalse(ComposerBar.turnControlExpandsComposer(action: .stop, restsWhenIdle: true))
        XCTAssertTrue(ComposerBar.turnControlExpandsComposer(action: .stop, restsWhenIdle: false), "the classic layout keeps Stop in its row")
        XCTAssertTrue(ComposerBar.turnControlExpandsComposer(action: .steer, restsWhenIdle: true))
        XCTAssertTrue(ComposerBar.turnControlExpandsComposer(action: .interrupt, restsWhenIdle: true))
        XCTAssertTrue(ComposerBar.turnControlExpandsComposer(action: .queue, restsWhenIdle: true))
        XCTAssertFalse(ComposerBar.turnControlExpandsComposer(action: .unavailable, restsWhenIdle: true))
        XCTAssertEqual(ComposerBar.trailingControl(action: .stop, showsVoiceButton: true), .action, "the resting bar's slot holds Stop, not voice")
    }

    /// #762: a live call can start while Hermes replies; classic voice waits.
    func testOnlyClassicVoiceWaitsForARunningReply() {
        XCTAssertFalse(AppState.voiceWaitsForRunningTurn(isBusy: true, liveEngine: .geminiLive))
        XCTAssertFalse(AppState.voiceWaitsForRunningTurn(isBusy: true, liveEngine: .localLive))
        XCTAssertTrue(AppState.voiceWaitsForRunningTurn(isBusy: true, liveEngine: nil))
        XCTAssertFalse(AppState.voiceWaitsForRunningTurn(isBusy: false, liveEngine: nil))
    }

    func testShortDraftsHaveNoExpandButton() {
        XCTAssertFalse(ComposerBar.showsFullEditorButton(measuredHeight: ComposerPasteTextView.minimumHeight))
        XCTAssertFalse(ComposerBar.showsFullEditorButton(measuredHeight: 60), "two lines read fine in place")
    }

    func testLongDraftsOfferTheFullEditor() {
        XCTAssertTrue(ComposerBar.showsFullEditorButton(measuredHeight: ComposerBar.fullEditorThreshold))
        XCTAssertTrue(ComposerBar.showsFullEditorButton(measuredHeight: ComposerPasteTextView.maximumHeight))
        // A wide Mac column grows the text: a single line there waits too.
        let grown = ComposerPasteTextView.minimumHeight(for: ComposerPasteTextView.bodyFont(in: .large, from: ColumnText(base: .large, scale: 2.2)))
        XCTAssertFalse(ComposerBar.showsFullEditorButton(measuredHeight: grown, restingHeight: grown))
        XCTAssertTrue(ComposerBar.showsFullEditorButton(measuredHeight: grown + 20, restingHeight: grown))
    }

    func testTheFullEditorTellsDictationFromTyping() {
        let dictated = ComposerDictation.draft(before: "Note:", dictated: "buy milk")
        XCTAssertFalse(ComposerDictation.isTyping(dictated, dictationWrote: dictated), "dictation's own write keeps it going")
        XCTAssertTrue(ComposerDictation.isTyping(dictated + "s", dictationWrote: dictated), "a keystroke after it is typing")
        XCTAssertTrue(ComposerDictation.isTyping("Note:", dictationWrote: nil), "no dictation write to match: every change is typing")
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
