//
//  ComposerReturnKeyTests.swift
//  ConduitTests
//
//  Covers the optional hardware-keyboard Return shortcut in the chat
//  composer: the pure decision policy, the composer-action gate, the
//  UIKit text-view branch that consumes (or forwards) the Return press,
//  and the preference's default (on for a Mac) and persistence. UIPress/UIKey have
//  no public initializers, so the pressesBegan branch is exercised through
//  the extracted handleReturnKeyPress(shiftPressed:) entry point, with the
//  modifier classification pinned directly and consumption additionally
//  gated on the composer's callback reporting that it acted.
//

import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

@MainActor
final class ComposerReturnKeyTests: XCTestCase {

    func testTheComposerFieldsTurnOffInlinePredictionOnlyOnAMac() {
        XCTAssertEqual(ReturnKeyTextView.inlinePredictionType(onMac: true), .no)
        XCTAssertEqual(ReturnKeyTextView.inlinePredictionType(onMac: false), .default)
        let here = ReturnKeyTextView.inlinePredictionType(onMac: ProcessInfo.processInfo.isiOSAppOnMac)
        XCTAssertEqual(ImagePasteTextView(frame: .zero, textContainer: nil).inlinePredictionType, here)
        XCTAssertEqual(ReturnKeyTextView().inlinePredictionType, here)
    }
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
            ComposerReturnKey.decision(returnKeySends: false, shiftPressed: false, hasMarkedText: false, canSubmit: true),
            .insertNewline
        )
    }

    func testSettingOnPlainReturnWithSubmittableComposerSubmits() {
        XCTAssertEqual(
            ComposerReturnKey.decision(returnKeySends: true, shiftPressed: false, hasMarkedText: false, canSubmit: true),
            .submit
        )
    }

    func testSettingOnShiftReturnInsertsNewline() {
        // Shift-Return must never send, even with a submittable composer.
        XCTAssertEqual(
            ComposerReturnKey.decision(returnKeySends: true, shiftPressed: true, hasMarkedText: false, canSubmit: true),
            .insertNewline
        )
    }

    func testSettingOnPlainReturnWithNonSubmittableComposerInsertsNewline() {
        // Synchronizing, disabled, stop-only, or empty states must not get
        // Return swallowed: fall back to the default newline behavior.
        XCTAssertEqual(
            ComposerReturnKey.decision(returnKeySends: true, shiftPressed: false, hasMarkedText: false, canSubmit: false),
            .insertNewline
        )
    }

    func testSettingOnPlainReturnWithMarkedTextInsertsNewline() {
        // IME composition owns Return while marked text is active (Japanese/
        // Chinese candidates confirm on Return). The shortcut must decline
        // even with everything else favorable, leaving the key to UIKit's
        // normal multistage text input.
        XCTAssertEqual(
            ComposerReturnKey.decision(returnKeySends: true, shiftPressed: false, hasMarkedText: true, canSubmit: true),
            .insertNewline
        )
    }

    // MARK: - Composer action gate

    func testReturnCanSubmitOnlyForTypedMessageActions() {
        XCTAssertTrue(ComposerReturnKey.canSubmit(action: .send))
        XCTAssertTrue(ComposerReturnKey.canSubmit(action: .steer))
        XCTAssertTrue(ComposerReturnKey.canSubmit(action: .interrupt))
        XCTAssertTrue(ComposerReturnKey.canSubmit(action: .queue))
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
        view.onSubmitFromReturn = { submitCount += 1; return true }

        XCTAssertTrue(view.handleReturnKeyPress(shiftPressed: false))
        XCTAssertEqual(submitCount, 1)
    }

    func testTextViewShiftReturnNeverSubmits() {
        let view = ImagePasteTextView()
        view.returnKeySends = true
        view.canSubmitFromReturn = true
        var submitCount = 0
        view.onSubmitFromReturn = { submitCount += 1; return true }

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
        view.onSubmitFromReturn = { submitCount += 1; return true }

        XCTAssertFalse(view.handleReturnKeyPress(shiftPressed: false))
        XCTAssertEqual(submitCount, 0)
    }

    func testTextViewReturnKeepsLegacyNewlineBehaviorWhenSettingOff() {
        let view = ImagePasteTextView()
        view.returnKeySends = false
        view.canSubmitFromReturn = true
        var submitCount = 0
        view.onSubmitFromReturn = { submitCount += 1; return true }

        XCTAssertFalse(view.handleReturnKeyPress(shiftPressed: false))
        XCTAssertEqual(submitCount, 0)
    }

    func testDeclinedComposerCallbackForwardsPressInsteadOfConsuming() {
        // Even when the policy classifies submit, a declined composer action
        // must report the press as NOT consumed so pressesBegan forwards it
        // and the default newline insertion still happens.
        let view = ImagePasteTextView()
        view.returnKeySends = true
        view.canSubmitFromReturn = true
        var submitCount = 0
        view.onSubmitFromReturn = { submitCount += 1; return false }

        XCTAssertFalse(view.handleReturnKeyPress(shiftPressed: false))
        XCTAssertEqual(submitCount, 1)
    }

    func testMissingCallbackReportsPressAsNotConsumed() {
        // Defensive: with no callback wired (plain UITextView-style use),
        // a submit classification must not report consumption.
        let view = ImagePasteTextView()
        view.returnKeySends = true
        view.canSubmitFromReturn = true

        XCTAssertFalse(view.handleReturnKeyPress(shiftPressed: false))
    }

    func testShiftClassificationIsFalseWhenNoEventAndNoKey() {
        // Pins the nil-safety of the modifier sources: with neither the
        // presses event nor the key reporting modifiers, Shift is not held.
        XCTAssertFalse(ImagePasteTextView.shiftIsPressed(event: nil, key: nil))
    }

    func testMarkedTextForwardsReturnInsteadOfSubmitting() {
        // IME composition: with marked text active, a plain Return on a
        // submittable composer must NOT submit and must report the press as
        // NOT consumed, so pressesBegan forwards it to UIKit's normal
        // text-input handling (candidate confirmation). A live IME session
        // cannot be synthesized in unit tests, so the marked-text state is
        // passed through the same decision seam pressesBegan uses.
        let view = ImagePasteTextView()
        view.returnKeySends = true
        view.canSubmitFromReturn = true
        var submitCount = 0
        view.onSubmitFromReturn = { submitCount += 1; return true }

        XCTAssertFalse(view.handleReturnKeyPress(shiftPressed: false, hasMarkedText: true))
        XCTAssertEqual(submitCount, 0)
    }

    // MARK: - Return key command (the route on a Mac)

    func testKeyCommandIsPlainReturnWithPriorityOverTheTextSystem() {
        // On a Mac the text view's own Return handling runs before
        // pressesBegan; only a priority key command gets there first.
        let command = ImagePasteTextView().keyCommands?.first { $0.input == "\r" }
        XCTAssertNotNil(command)
        XCTAssertEqual(command?.modifierFlags, [])
        XCTAssertEqual(command?.wantsPriorityOverSystemBehavior, true)
    }

    func testKeyCommandTakesReturnOnlyWhenTheComposerWouldSend() {
        let view = ImagePasteTextView()
        view.onSubmitFromReturn = { true }
        view.canSubmitFromReturn = true

        view.returnKeySends = false
        XCTAssertFalse(view.returnKeyCommandApplies(hasMarkedText: false))

        view.returnKeySends = true
        XCTAssertTrue(view.returnKeyCommandApplies(hasMarkedText: false))
        // The IME's Return confirms its candidate.
        XCTAssertFalse(view.returnKeyCommandApplies(hasMarkedText: true))

        view.canSubmitFromReturn = false
        XCTAssertFalse(view.returnKeyCommandApplies(hasMarkedText: false))

        view.canSubmitFromReturn = true
        view.onSubmitFromReturn = nil
        XCTAssertFalse(view.returnKeyCommandApplies(hasMarkedText: false))
    }

    func testShiftedKeyCommandNeverSends() {
        // On a Mac no Shift press may reach the view; the command's own
        // modifiers keep Shift-Return a newline.
        let view = ImagePasteTextView()
        view.returnKeySends = true
        view.canSubmitFromReturn = true
        view.onSubmitFromReturn = { true }
        let shifted = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(ReturnKeyTextView.returnKeyCommandPressed))

        XCTAssertFalse(view.canPerformAction(#selector(ReturnKeyTextView.returnKeyCommandPressed), withSender: shifted))
    }

    func testKeyCommandSendsThroughTheComposer() {
        let view = ImagePasteTextView()
        view.returnKeySends = true
        view.canSubmitFromReturn = true
        var submitCount = 0
        view.onSubmitFromReturn = { submitCount += 1; return true }

        view.returnKeyCommandPressed()
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(view.text, "")
    }

    // MARK: - ⌘Return and the rest of the shortcuts (issue 2219)

    func testCommandReturnIsAPriorityCommandBesidePlainReturn() {
        let commands = ImagePasteTextView().keyCommands ?? []
        let command = commands.first { $0.input == "\r" && $0.modifierFlags == .command }
        XCTAssertNotNil(command)
        XCTAssertEqual(command?.wantsPriorityOverSystemBehavior, true)
        // The catalog the shortcut list reads names the same keys.
        XCTAssertEqual(ConduitKeyboardShortcut.send.key, .return)
        XCTAssertEqual(ConduitKeyboardShortcut.send.modifiers, .command)
    }

    func testCommandReturnSendsWhateverTheReturnSettingSays() {
        let view = ImagePasteTextView()
        view.onSubmitFromReturn = { true }
        view.canSubmitFromReturn = true

        view.returnKeySends = false
        XCTAssertTrue(view.commandReturnKeyCommandApplies(hasMarkedText: false))
        view.returnKeySends = true
        XCTAssertTrue(view.commandReturnKeyCommandApplies(hasMarkedText: false))
        // The IME's Return is the composition's.
        XCTAssertFalse(view.commandReturnKeyCommandApplies(hasMarkedText: true))

        view.canSubmitFromReturn = false
        XCTAssertFalse(view.commandReturnKeyCommandApplies(hasMarkedText: false))

        view.canSubmitFromReturn = true
        view.onSubmitFromReturn = nil
        XCTAssertFalse(view.commandReturnKeyCommandApplies(hasMarkedText: false))
    }

    func testCommandReturnSendsThroughTheComposerAndNeverTypesANewline() {
        let view = ImagePasteTextView()
        view.returnKeySends = false
        view.canSubmitFromReturn = true
        var submitCount = 0
        view.onSubmitFromReturn = { submitCount += 1; return false }

        view.commandReturnKeyCommandPressed()
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(view.text, "")
    }

    func testShortcutGlyphsAreWrittenInTheMenuBarsOrder() {
        XCTAssertEqual(ConduitKeyboardShortcut.newChat.glyphs, "⌘N")
        XCTAssertEqual(ConduitKeyboardShortcut.send.glyphs, "⌘↩")
        XCTAssertEqual(ConduitKeyboardShortcut.chatList.glyphs, "⌃⌘S")
        XCTAssertEqual(ConduitKeyboardShortcut.artifacts.glyphs, "⌥⌘A")
        XCTAssertEqual(ConduitKeyboardShortcut.smallerText.glyphs, "⌘−")
        let standard = V2TabLayout.standard.shown
        XCTAssertEqual(ConduitKeyboardShortcut.tabGlyphs(.bots, in: standard), "⌘1")
        XCTAssertEqual(ConduitKeyboardShortcut.tabGlyphs(.settings, in: standard), "⌘4")
        // The keys follow the bar's order, and a hidden tab has none
        // (issue 2084).
        let reordered = V2TabLayout(stored: ["chats", "-bots", "settings", "tasks"]).shown
        XCTAssertEqual(ConduitKeyboardShortcut.tabGlyphs(.chats, in: reordered), "⌘1")
        XCTAssertEqual(ConduitKeyboardShortcut.tabGlyphs(.settings, in: reordered), "⌘2")
        XCTAssertEqual(ConduitKeyboardShortcut.tabGlyphs(.tasks, in: reordered), "⌘3")
        XCTAssertNil(ConduitKeyboardShortcut.tabGlyphs(.bots, in: reordered))
    }

    func testNoTwoShortcutsShareAKey() {
        var seen = Set<String>()
        let all = ConduitKeyboardShortcut.allCases.map(\.glyphs)
            + V2TabLayout.standardOrder.compactMap { ConduitKeyboardShortcut.tabGlyphs($0, in: V2TabLayout.standardOrder) }
        for glyphs in all {
            XCTAssertTrue(seen.insert(glyphs).inserted, "\(glyphs) is taken twice")
        }
    }

    func testTextSizeStepsHoldAtTheEndsAndZeroIsTheDefault() {
        XCTAssertEqual(KeyboardCommands.chatTextSize(after: .default, step: 1), .larger)
        XCTAssertEqual(KeyboardCommands.chatTextSize(after: .largest, step: 1), .largest)
        XCTAssertEqual(KeyboardCommands.chatTextSize(after: .smaller, step: -1), .smallest)
        XCTAssertEqual(KeyboardCommands.chatTextSize(after: .smallest, step: -1), .smallest)
        XCTAssertEqual(KeyboardCommands.chatTextSize(after: .largest, step: 0), ChatTypography.defaultSize)
    }

    func testTextSizeShortcutWritesWhereSettingsDoes() throws {
        let suite = "ComposerReturnKeyTests.textSize.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        KeyboardCommands.stepChatTextSize(by: 1, defaults: defaults)
        XCTAssertEqual(ChatTypography.stored(in: defaults), .larger)
        KeyboardCommands.stepChatTextSize(by: -2, defaults: defaults)
        XCTAssertEqual(ChatTypography.stored(in: defaults), .smaller)
        KeyboardCommands.stepChatTextSize(by: 0, defaults: defaults)
        XCTAssertEqual(ChatTypography.stored(in: defaults), .default)
    }

    // MARK: - Suggestion list keys (issue 1576)

    func testArrowsMoveTheHighlightAndWrap() {
        XCTAssertEqual(ComposerSuggestionHighlight.moved(nil, by: .down, count: 3), 0)
        XCTAssertEqual(ComposerSuggestionHighlight.moved(nil, by: .up, count: 3), 2)
        XCTAssertEqual(ComposerSuggestionHighlight.moved(2, by: .down, count: 3), 0)
        XCTAssertEqual(ComposerSuggestionHighlight.moved(0, by: .up, count: 3), 2)
        XCTAssertEqual(ComposerSuggestionHighlight.moved(5, by: .down, count: 3), 0, "A list that shrank starts over")
        XCTAssertNil(ComposerSuggestionHighlight.moved(nil, by: .down, count: 0))
    }

    func testReturnPicksOnlyAHighlightedRowAndTabTheFirst() {
        XCTAssertNil(ComposerSuggestionHighlight.picked(nil, by: .choose, count: 3))
        XCTAssertEqual(ComposerSuggestionHighlight.picked(1, by: .choose, count: 3), 1)
        XCTAssertEqual(ComposerSuggestionHighlight.picked(nil, by: .chooseFirst, count: 3), 0)
        XCTAssertEqual(ComposerSuggestionHighlight.picked(2, by: .chooseFirst, count: 3), 2)
        XCTAssertNil(ComposerSuggestionHighlight.picked(4, by: .choose, count: 3))
    }

    func testSuggestionKeysAreTheListsOnlyWhileOneShows() {
        let view = ImagePasteTextView()
        let up = #selector(ReturnKeyTextView.suggestionUpPressed)
        let commands = view.keyCommands ?? []
        for input in [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, "\t", UIKeyCommand.inputEscape] {
            let command = commands.first { $0.input == input }
            XCTAssertEqual(command?.wantsPriorityOverSystemBehavior, true, "\(input) reaches the list before the text")
        }
        XCTAssertFalse(view.canPerformAction(up, withSender: nil), "No list: the arrow moves the cursor")

        var keys: [ComposerSuggestionKey] = []
        view.suggestionKeys = ComposerSuggestionKeys(hasHighlight: false) { keys.append($0) }
        XCTAssertTrue(view.canPerformAction(up, withSender: nil))
        let shiftedUp = UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: .shift, action: up)
        XCTAssertFalse(view.canPerformAction(up, withSender: shiftedUp), "Shift-Up still selects text")
        view.suggestionUpPressed()
        view.suggestionDownPressed()
        view.suggestionTabPressed()
        view.suggestionEscapePressed()
        XCTAssertEqual(keys, [.up, .down, .chooseFirst, .dismiss])
    }

    func testReturnPicksAHighlightedSuggestionInsteadOfSending() {
        let view = ImagePasteTextView()
        view.returnKeySends = true
        view.canSubmitFromReturn = true
        var submitCount = 0
        view.onSubmitFromReturn = { submitCount += 1; return true }
        var keys: [ComposerSuggestionKey] = []
        let returnAction = #selector(ReturnKeyTextView.returnKeyCommandPressed)

        view.suggestionKeys = ComposerSuggestionKeys(hasHighlight: false) { keys.append($0) }
        view.returnKeyCommandPressed()
        XCTAssertEqual(submitCount, 1, "Nothing highlighted: Return sends, so /status and Return still runs it")

        view.returnKeySends = false
        view.suggestionKeys = ComposerSuggestionKeys(hasHighlight: true) { keys.append($0) }
        XCTAssertTrue(view.canPerformAction(returnAction, withSender: nil), "Even where Return types a newline")
        view.returnKeyCommandPressed()
        XCTAssertEqual(keys, [.choose])
        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(view.text, "")
    }

    func testDeclinedKeyCommandStillInsertsTheNewline() {
        let view = ImagePasteTextView()
        view.returnKeySends = true
        view.canSubmitFromReturn = true
        view.onSubmitFromReturn = { false }

        view.returnKeyCommandPressed()
        XCTAssertEqual(view.text, "\n")
    }

    func testRoomAndFullEditorFieldsTakeTheShortcut() {
        // A group room's field and the full editor use the same text view,
        // so the same Return key command reaches them.
        let command = ReturnKeyTextView().keyCommands?.first { $0.input == "\r" }
        XCTAssertEqual(command?.wantsPriorityOverSystemBehavior, true)
    }

    // MARK: - Room and full editor field: text sync

    private func editorCoordinator(text: Binding<String>) -> ReturnKeyTextEditor.Coordinator {
        ReturnKeyTextEditor(
            text: text,
            isFocused: .constant(true),
            accessibilityLabel: "Message",
            canSubmitFromReturn: false,
            onSubmitFromReturn: { false }
        ).makeCoordinator()
    }

    func testFieldTakesAChangeMadeElsewhereWithTheCursorAfterIt() {
        var stored = ""
        let coordinator = editorCoordinator(text: Binding(get: { stored }, set: { stored = $0 }))
        let field = ReturnKeyTextView()
        field.text = "Hi"

        coordinator.apply(text: "Hi @bot ", to: field, hasMarkedText: false)
        XCTAssertEqual(field.text, "Hi @bot ")
        XCTAssertEqual(field.selectedRange, NSRange(location: 8, length: 0))
    }

    func testTypingReachesTheBinding() {
        var stored = ""
        let coordinator = editorCoordinator(text: Binding(get: { stored }, set: { stored = $0 }))
        let field = ReturnKeyTextView()
        field.text = "typed"

        coordinator.textDidChange(in: field, hasMarkedText: false)
        XCTAssertEqual(stored, "typed")
    }

    func testLaggingBindingNeverRewritesTyping() {
        // The binding still holds the field's last report while a newer
        // keystroke is in flight: that's an echo, not a change to apply.
        var stored = ""
        let coordinator = editorCoordinator(text: Binding(get: { stored }, set: { stored = $0 }))
        let field = ReturnKeyTextView()
        field.text = "Hel"
        coordinator.textDidChange(in: field, hasMarkedText: false)
        field.text = "Hell"

        coordinator.apply(text: "Hel", to: field, hasMarkedText: false)
        XCTAssertEqual(field.text, "Hell")
    }

    func testChangeAlreadyInPlaceWhenCompositionEndsDoesNotLinger() {
        var stored = ""
        let coordinator = editorCoordinator(text: Binding(get: { stored }, set: { stored = $0 }))
        let field = ReturnKeyTextView()
        field.text = "にほ"
        coordinator.apply(text: "日本", to: field, hasMarkedText: true)

        field.text = "日本"
        coordinator.textDidChange(in: field, hasMarkedText: false)
        XCTAssertNil(coordinator.pendingText)

        field.text = "日本語"
        coordinator.textDidChange(in: field, hasMarkedText: false)
        XCTAssertEqual(field.text, "日本語")
        XCTAssertEqual(stored, "日本語")
    }

    func testChangeMadeDuringCompositionLandsWhenItEnds() {
        // A quote or dictation write while the IME composes isn't dropped:
        // it waits, then lands once the composition ends.
        var stored = "にほ"
        let coordinator = editorCoordinator(text: Binding(get: { stored }, set: { stored = $0 }))
        let field = ReturnKeyTextView()
        field.text = "にほ"

        coordinator.apply(text: "> quote\n", to: field, hasMarkedText: true)
        XCTAssertEqual(field.text, "にほ")
        XCTAssertEqual(coordinator.pendingText, "> quote\n")

        field.text = "日本"
        coordinator.textDidChange(in: field, hasMarkedText: false)
        XCTAssertEqual(field.text, "> quote\n")
        XCTAssertEqual(stored, "> quote\n")
        XCTAssertNil(coordinator.pendingText)
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

    // MARK: - Held-Shift chord state (begin / end / cancel)

    func testCancelledShiftPressReleasesTrackedState() {
        // pressesCancelled must clear a held Shift exactly like pressesEnded,
        // or the shortcut would keep believing Shift is held after the system
        // cancels the press sequence.
        var held = ImagePasteTextView.updatedShiftState(
            [],
            keyCodes: [.keyboardLeftShift],
            isPressed: true
        )
        XCTAssertEqual(held, [.keyboardLeftShift])

        held = ImagePasteTextView.updatedShiftState(held, keyCodes: [.keyboardLeftShift], isPressed: false)
        XCTAssertTrue(held.isEmpty)
    }

    func testSecondShiftSurvivesReleasingOneKey() {
        // Left and right Shift are tracked independently: releasing one while
        // the other is still physically held keeps the chord active.
        var held = ImagePasteTextView.updatedShiftState(
            [],
            keyCodes: [.keyboardLeftShift, .keyboardRightShift],
            isPressed: true
        )
        XCTAssertEqual(held, [.keyboardLeftShift, .keyboardRightShift])

        held = ImagePasteTextView.updatedShiftState(held, keyCodes: [.keyboardLeftShift], isPressed: false)
        XCTAssertEqual(held, [.keyboardRightShift])
    }

    func testShiftStateIgnoresNonShiftKeyCodes() {
        var held = ImagePasteTextView.updatedShiftState(
            [],
            keyCodes: [.keyboardA, .keyboardReturnOrEnter],
            isPressed: true
        )
        XCTAssertTrue(held.isEmpty)

        held = ImagePasteTextView.updatedShiftState(held, keyCodes: [.keyboardA], isPressed: false)
        XCTAssertTrue(held.isEmpty)
    }

    // MARK: - Preference default and persistence

    func testPreferenceHasNoStoredValueUntilChosen() {
        UserDefaults.standard.removeObject(forKey: ComposerReturnKey.preferenceKey)

        // @AppStorage in ComposerBar and the Chat settings row falls back to
        // `sendsByDefault` only while nothing is stored, so a choice someone
        // already made is kept on every device.
        XCTAssertNil(UserDefaults.standard.object(forKey: ComposerReturnKey.preferenceKey))
    }

    func testReturnSendsByDefaultOnlyOnAMac() {
        XCTAssertTrue(ComposerReturnKey.sendsByDefault(onMac: true))
        XCTAssertFalse(ComposerReturnKey.sendsByDefault(onMac: false))
        XCTAssertEqual(
            ComposerReturnKey.sendsByDefault,
            ProcessInfo.processInfo.isiOSAppOnMac
        )
    }

    /// Settings says where the preference starts, so a Mac user can tell
    /// why it's already on (#1088).
    func testSettingsSaysTheDefaultForEachDevice() {
        XCTAssertEqual(
            ComposerReturnKey.defaultFootnote(onMac: true),
            AppLocalization.string("On by default on a Mac. Turn it off to make Return insert a new line.", table: .chat)
        )
        XCTAssertEqual(
            ComposerReturnKey.defaultFootnote(onMac: false),
            AppLocalization.string("Off by default on iPhone and iPad.", table: .chat)
        )
    }

    func testPreferenceRestoresStoredValue() {
        UserDefaults.standard.set(true, forKey: ComposerReturnKey.preferenceKey)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: ComposerReturnKey.preferenceKey))

        UserDefaults.standard.set(false, forKey: ComposerReturnKey.preferenceKey)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: ComposerReturnKey.preferenceKey))
    }
}
