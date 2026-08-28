//
//  ComposerReturnKeyTests.swift
//  ConduitTests
//
//  Covers the optional hardware-keyboard Return shortcut in the chat
//  composer: the pure decision policy, the composer-action gate, the
//  UIKit text-view branch that consumes (or forwards) the Return press,
//  and the default-off persistence of the preference. UIPress/UIKey have
//  no public initializers, so the pressesBegan branch is exercised through
//  the extracted handleReturnKeyPress(shiftPressed:) entry point with the
//  key-code/modifier classification pinned separately.
//

import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

@MainActor
final class ComposerReturnKeyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: ComposerReturnKey.preferenceKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: ComposerReturnKey.preferenceKey)
        super.tearDown()
    }

    // MARK: - Decision policy

    func testSettingOffPlainReturnInsertsNewline() {
        // Existing users must keep the default: Return never submits.
        XCTAssertEqual(
            ComposerReturnKey.decision(returnKeySends: false, shiftPressed: false, canSubmit: true),
            .insertNewline
        )
    }

    func testSettingOnPlainReturnWithSubmittableComposerSubmits() {
        XCTAssertEqual(
            ComposerReturnKey.decision(returnKeySends: true, shiftPressed: false, canSubmit: true),
            .submit
        )
    }

    func testSettingOnShiftReturnInsertsNewline() {
        // Shift-Return must never send, even with a submittable composer.
        XCTAssertEqual(
            ComposerReturnKey.decision(returnKeySends: true, shiftPressed: true, canSubmit: true),
            .insertNewline
        )
    }

    func testSettingOnPlainReturnWithNonSubmittableComposerInsertsNewline() {
        // Synchronizing, disabled, stop-only, or empty states must not get
        // Return swallowed: fall back to the default newline behavior.
        XCTAssertEqual(
            ComposerReturnKey.decision(returnKeySends: true, shiftPressed: false, canSubmit: false),
            .insertNewline
        )
    }

    // MARK: - Composer action gate

    func testReturnCanSubmitOnlyForTypedMessageActions() {
        XCTAssertTrue(ComposerReturnKey.canSubmit(action: .send))
        XCTAssertTrue(ComposerReturnKey.canSubmit(action: .steer))
        XCTAssertTrue(ComposerReturnKey.canSubmit(action: .interrupt))
        // A running response with an empty composer is stop-only; Return
        // must never act as the Stop button.
        XCTAssertFalse(ComposerReturnKey.canSubmit(action: .stop))
        // Synchronizing/reconnecting/unsupported gateways are unavailable.
        XCTAssertFalse(ComposerReturnKey.canSubmit(action: .unavailable))
    }

    // MARK: - Text view press branch

    func testTextViewConsumesPlainReturnAsSubmitWhenEnabledAndSubmittable() {
        let view = ImagePasteTextView()
        view.returnKeySends = true
        view.canSubmitFromReturn = true
        var submitCount = 0
        view.onSubmitFromReturn = { submitCount += 1 }

        XCTAssertTrue(view.handleReturnKeyPress(shiftPressed: false))
        XCTAssertEqual(submitCount, 1)
    }

    func testTextViewShiftReturnNeverSubmits() {
        let view = ImagePasteTextView()
        view.returnKeySends = true
        view.canSubmitFromReturn = true
        var submitCount = 0
        view.onSubmitFromReturn = { submitCount += 1 }

        // A false return means the press was not consumed and falls through
        // to the default newline insertion.
        XCTAssertFalse(view.handleReturnKeyPress(shiftPressed: true))
        XCTAssertEqual(submitCount, 0)
    }

    func testTextViewReturnDoesNotSubmitWhenComposerCannotAct() {
        let view = ImagePasteTextView()
        view.returnKeySends = true
        view.canSubmitFromReturn = false
        var submitCount = 0
        view.onSubmitFromReturn = { submitCount += 1 }

        XCTAssertFalse(view.handleReturnKeyPress(shiftPressed: false))
        XCTAssertEqual(submitCount, 0)
    }

    func testTextViewReturnKeepsLegacyNewlineBehaviorWhenSettingOff() {
        let view = ImagePasteTextView()
        view.returnKeySends = false
        view.canSubmitFromReturn = true
        var submitCount = 0
        view.onSubmitFromReturn = { submitCount += 1 }

        XCTAssertFalse(view.handleReturnKeyPress(shiftPressed: false))
        XCTAssertEqual(submitCount, 0)
    }

    func testTextViewDefaultsPreserveLegacyReturnBehavior() {
        // Fresh text views (and every existing construction site that does
        // not know about the shortcut) must behave exactly as before.
        let view = ImagePasteTextView()
        XCTAssertFalse(view.returnKeySends)
        XCTAssertFalse(view.canSubmitFromReturn)
        XCTAssertNil(view.onSubmitFromReturn)
    }

    func testRepresentableDefaultsPreserveLegacyReturnBehavior() {
        var storedText = ""
        let view = ComposerPasteTextView(
            text: Binding(get: { storedText }, set: { storedText = $0 }),
            isFocused: .constant(false),
            measuredHeight: .constant(44),
            enabled: true,
            onPastedImage: { _ in },
            onPastedImageError: { _ in },
            editorIdentity: UUID()
        )
        XCTAssertFalse(view.returnKeySends)
        XCTAssertFalse(view.canSubmitFromReturn)
        XCTAssertNil(view.onSubmitFromReturn)
    }

    // MARK: - Preference default and persistence

    func testPreferenceDefaultsToOffWithNoStoredValue() {
        UserDefaults.standard.removeObject(forKey: ComposerReturnKey.preferenceKey)

        // @AppStorage in ComposerBar and the Chat settings row reads through
        // UserDefaults; a missing key must resolve to the `false` default so
        // existing users never gain send-on-Return after updating.
        XCTAssertNil(UserDefaults.standard.object(forKey: ComposerReturnKey.preferenceKey))
        XCTAssertFalse(UserDefaults.standard.bool(forKey: ComposerReturnKey.preferenceKey))
    }

    func testPreferenceRestoresStoredValue() {
        UserDefaults.standard.set(true, forKey: ComposerReturnKey.preferenceKey)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: ComposerReturnKey.preferenceKey))

        UserDefaults.standard.set(false, forKey: ComposerReturnKey.preferenceKey)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: ComposerReturnKey.preferenceKey))
    }
}
