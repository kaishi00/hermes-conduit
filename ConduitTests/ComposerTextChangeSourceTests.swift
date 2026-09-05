import XCTest
@testable import Conduit

/// The composer's session-ownership classification. A genuine user edit
/// cancels automatic foreground-return restoration (via
/// `AppState.noteComposerUserEdit()`), so the classification must fire for
/// real typing only: draft restores, prefills, slash insertions, post-send
/// collapses, and failed-submit restores are programmatic replacements, and
/// ordinary SwiftUI re-renders never produce a text change at all.
final class ComposerTextChangeSourceTests: XCTestCase {
    func testBindingChangeWithoutPendingMarkClassifiesAsUserEdit() {
        // The UIKit editor moved the binding (textViewDidChange); the
        // programmatic revision is unchanged.
        XCTAssertEqual(
            ComposerTextChangeSource.classify(hasPendingProgrammaticReplacement: false),
            .userEdit
        )
    }

    func testMarkedReplacementClassifiesAsProgrammatic() {
        // Draft restore, prefill, slash insertion, clear after send, and
        // failed-submit restore all route through replaceComposerText with a
        // changed value, which sets the pending mark.
        XCTAssertEqual(
            ComposerTextChangeSource.classify(hasPendingProgrammaticReplacement: true),
            .programmaticReplacement
        )
    }

    func testOnlyChangedTextMarksPendingReplacement() {
        // A no-op programmatic write must not mark: its text-change observer
        // never fires, and a leaked mark would swallow the next genuine
        // keystroke's ownership signal.
        XCTAssertFalse(
            ComposerTextChangeSource.marksPendingReplacement(from: "abc", to: "abc")
        )
        XCTAssertFalse(ComposerTextChangeSource.marksPendingReplacement(from: "", to: ""))
        XCTAssertTrue(
            ComposerTextChangeSource.marksPendingReplacement(from: "", to: "/deploy ")
        )
        XCTAssertTrue(
            ComposerTextChangeSource.marksPendingReplacement(from: "draft", to: "")
        )
    }

    func testSourcesAreDistinct() {
        XCTAssertNotEqual(
            ComposerTextChangeSource.userEdit,
            ComposerTextChangeSource.programmaticReplacement
        )
    }
}
