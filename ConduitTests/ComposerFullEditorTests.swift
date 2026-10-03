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
}
