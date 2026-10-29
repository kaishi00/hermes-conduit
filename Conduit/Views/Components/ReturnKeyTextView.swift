//
//  ReturnKeyTextView.swift
//  Conduit
//
//  The hardware-keyboard Return shortcut (Settings > Chat > Keyboard >
//  Return key sends) for every composer: the chat composer's
//  ImagePasteTextView, a group room's field and the full editor. The text
//  view only classifies the keystroke; ComposerReturnKey owns the
//  send-vs-newline decision and the composer owns the action.
//

import SwiftUI
import UIKit

class ReturnKeyTextView: UITextView {
    /// The text size and column `font` was last set for
    /// (ReturnKeyTextEditor).
    var fontSizeCategory: ContentSizeCategory?
    var fontColumnText: ColumnText?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        inlinePredictionType = Self.inlinePredictionType(onMac: ProcessInfo.processInfo.isiOSAppOnMac)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        inlinePredictionType = Self.inlinePredictionType(onMac: ProcessInfo.processInfo.isiOSAppOnMac)
    }

    /// On a Mac, macOS shows an inline prediction in a correction panel that
    /// runs its own nested event loop, and the text checker can open another
    /// panel inside it. Both Mac freezes captured on 2.2.1 (237) ran SwiftUI's
    /// update from three and four such nested panels, where the transcript's
    /// LazyVStack re-laid out forever and the chat stopped updating. The
    /// fields keep autocorrect and spelling; only the inline prediction is
    /// off on a Mac. iPhone and iPad keep theirs.
    static func inlinePredictionType(onMac: Bool) -> UITextInlinePredictionType {
        onMac ? .no : .default
    }

    // Two routes reach the shortcut. A Return key command that takes
    // priority over the text system: on a Mac (the iPad app on macOS) the
    // text view's own Return handling runs before pressesBegan would see
    // the press, so the command is the route there. pressesBegan stays for
    // what the command doesn't cover (keypad Enter, Shift read from the
    // press). The software keyboard's Return key produces neither, so it
    // keeps its newline.
    var returnKeySends = false
    var canSubmitFromReturn = false
    var onSubmitFromReturn: (() -> Bool)?
    /// Ground-truth Shift state folded from the keyboard's own Shift press
    /// events. Some Bluetooth keyboards report chord modifiers with a lag on
    /// the event/key modifier surfaces, so the physical Shift press itself is
    /// tracked as well. Left and right Shift are tracked independently so a
    /// released key cannot clear a still-held second Shift.
    private var heldShiftKeys: Set<UIKeyboardHIDUsage> = []
    private var hardwareShiftHeld: Bool { !heldShiftKeys.isEmpty }
    /// Set while the Return key command has just acted, so the same
    /// keystroke reaching pressesBegan too isn't handled twice.
    private var returnTakenByKeyCommand = false

    private static let returnKeyCommand: UIKeyCommand = {
        // Plain Return only: Shift-Return doesn't match it and keeps the
        // text system's newline.
        let command = UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(returnKeyCommandPressed))
        command.wantsPriorityOverSystemBehavior = true
        return command
    }()

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + [Self.returnKeyCommand]
    }

    /// A paste too long for the field (`PastedText.becomesAttachment`),
    /// offered to the composer to attach instead. True when it took the
    /// paste; otherwise the words go into the field as usual. Nil keeps
    /// every paste in the field.
    var onLongTextPaste: ((String) -> Bool)?

    override func paste(_ sender: Any?) {
        if takesLongTextPaste() { return }
        super.paste(sender)
    }

    override func pasteAndMatchStyle(_ sender: Any?) {
        if takesLongTextPaste() { return }
        super.pasteAndMatchStyle(sender)
    }

    /// Read only once the user has asked to paste, so it never raises the
    /// "Paste from Other App" prompt by itself.
    private func takesLongTextPaste() -> Bool {
        let pasteboard = UIPasteboard.general
        guard let onLongTextPaste, isEditable, pasteboard.hasStrings, !pasteboard.hasImages,
              let pasted = pasteboard.string, PastedText.becomesAttachment(pasted),
              onLongTextPaste(pasted) else { return false }
        // A paste replaces what was selected, wherever the words went.
        if selectedRange.length > 0 { deleteBackward() }
        return true
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(returnKeyCommandPressed) {
            // Declining hands Return back to the text system: a newline,
            // or the IME confirming its candidate. A Shift the key command
            // carries counts even when no Shift press reached this view.
            if (sender as? UIKeyCommand)?.modifierFlags.contains(.shift) == true { return false }
            return returnKeyCommandApplies
        }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Whether the Return key command takes this press. Internal so tests
    /// can check the gate without a key event.
    var returnKeyCommandApplies: Bool {
        returnKeyCommandApplies(hasMarkedText: markedTextRange != nil)
    }

    func returnKeyCommandApplies(hasMarkedText: Bool) -> Bool {
        // Only the first responder's commands are asked, so the field
        // being typed in is the one that sends.
        onSubmitFromReturn != nil
            && ComposerReturnKey.decision(
                returnKeySends: returnKeySends,
                shiftPressed: hardwareShiftHeld,
                hasMarkedText: hasMarkedText,
                canSubmit: canSubmitFromReturn
            ) == .submit
    }

    @objc func returnKeyCommandPressed() {
        returnTakenByKeyCommand = true
        DispatchQueue.main.async { [weak self] in self?.returnTakenByKeyCommand = false }
        // The composer turned it down after all: the press is still a
        // newline, as it would have been without the shortcut.
        if !(onSubmitFromReturn?() ?? false) {
            insertText("\n")
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        foldHardwareShift(presses, pressed: true)
        var forwarding = presses
        if let returnPress = presses.first(where: { Self.isReturnKeyPress($0) }) {
            if returnTakenByKeyCommand {
                forwarding.remove(returnPress)
            } else {
                let shiftPressed = hardwareShiftHeld
                    || Self.shiftIsPressed(event: event, key: returnPress.key)
                    || Self.shiftIsHeld(in: event?.allPresses ?? [])
                // Consume only the Return press, and only when the composer
                // actually acted. Every other case (setting off, Shift-Return,
                // marked text / IME composition, non-submittable composer,
                // declined callback) is forwarded with the remaining presses so
                // UIKit's normal text-input behavior is preserved.
                if handleReturnKeyPress(shiftPressed: shiftPressed) {
                    forwarding.remove(returnPress)
                }
            }
        }
        if !forwarding.isEmpty {
            super.pressesBegan(forwarding, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        foldHardwareShift(presses, pressed: false)
        if presses.contains(where: { Self.isReturnKeyPress($0) }) { returnTakenByKeyCommand = false }
        // Forward the original set: UIKit tracks press lifecycle across the
        // whole sequence, not just the keys this shortcut cares about.
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // A cancelled sequence (e.g. the system ends chord tracking) must
        // release tracked Shift state exactly like a normal key-up, or the
        // shortcut would keep believing Shift is held.
        foldHardwareShift(presses, pressed: false)
        if presses.contains(where: { Self.isReturnKeyPress($0) }) { returnTakenByKeyCommand = false }
        // Forward the original set: UIKit tracks press lifecycle across the
        // whole sequence, not just the keys this shortcut cares about.
        super.pressesCancelled(presses, with: event)
    }

    /// Whether any currently-down Shift press exists anywhere in the press
    /// event. Covers keyboards that deliver the Shift key-down in a separate,
    /// later event than Return, where the per-press modifiers and the local
    /// fold would not yet show the chord.
    static func shiftIsHeld(in presses: Set<UIPress>) -> Bool {
        presses.contains { press in
            press.key?.keyCode == .keyboardLeftShift || press.key?.keyCode == .keyboardRightShift
        }
    }

    override func resignFirstResponder() -> Bool {
        // A focus change mid-chord means the key-up will go to a different
        // responder; drop the tracked Shift so the next plain Return is not
        // misread as Shift-Return.
        heldShiftKeys.removeAll()
        return super.resignFirstResponder()
    }

    /// Folds physical Shift presses into the tracked chord state. Cancellations
    /// are treated like key-ups: the press is no longer held either way.
    private func foldHardwareShift(_ presses: Set<UIPress>, pressed: Bool) {
        heldShiftKeys = Self.updatedShiftState(
            heldShiftKeys,
            keyCodes: Set(presses.compactMap { $0.key?.keyCode }),
            isPressed: pressed
        )
    }

    /// Pure Shift-chord state transition over key codes, extracted so the
    /// begin/end/cancel bookkeeping is unit-testable without synthesizing
    /// UIPress events. Unknown key codes are ignored; cancellations and
    /// key-ups both release their keys.
    static func updatedShiftState(
        _ held: Set<UIKeyboardHIDUsage>,
        keyCodes: Set<UIKeyboardHIDUsage>,
        isPressed: Bool
    ) -> Set<UIKeyboardHIDUsage> {
        let shiftCodes: Set<UIKeyboardHIDUsage> = [.keyboardLeftShift, .keyboardRightShift]
        let touched = keyCodes.intersection(shiftCodes)
        return isPressed ? held.union(touched) : held.subtracting(touched)
    }

    /// Applies the Return shortcut policy for one Return key press and
    /// reports whether the press was consumed as a submit. While the text
    /// view holds IME marked text, Return belongs to the composition and the
    /// shortcut always declines. Consumption additionally requires the
    /// composer's callback to report that it acted; anything else returns
    /// false so the caller forwards the press. Internal so tests can drive
    /// the exact pressesBegan branch without synthesizing UIPress or UIKey
    /// events (neither exposes an initializer).
    @discardableResult
    func handleReturnKeyPress(shiftPressed: Bool) -> Bool {
        handleReturnKeyPress(shiftPressed: shiftPressed, hasMarkedText: markedTextRange != nil)
    }

    /// Test seam for the same decision path with the marked-text state passed
    /// explicitly, since a live IME composition cannot be synthesized in unit
    /// tests.
    func handleReturnKeyPress(shiftPressed: Bool, hasMarkedText: Bool) -> Bool {
        let decision = ComposerReturnKey.decision(
            returnKeySends: returnKeySends,
            shiftPressed: shiftPressed,
            hasMarkedText: hasMarkedText,
            canSubmit: canSubmitFromReturn
        )
        guard decision == .submit, let onSubmit = onSubmitFromReturn else { return false }
        return onSubmit()
    }

    /// Pure keystroke classification for hardware Return presses. Covers the
    /// main Return key plus the keypad/alternate Enter keys on extended
    /// keyboards, so every physical Enter variant behaves consistently.
    static func isReturnKeyPress(_ press: UIPress) -> Bool {
        guard let keyCode = press.key?.keyCode else { return false }
        return keyCode == .keyboardReturnOrEnter
            || keyCode == .keyboardReturn
            || keyCode == .keypadEnter
    }

    /// Shift detection for a Return press. UIPressesEvent and UIKey can
    /// report modifiers independently, so both sources are consulted; either
    /// reporting Shift means the user wants a newline.
    static func shiftIsPressed(event: UIPressesEvent?, key: UIKey?) -> Bool {
        (event?.modifierFlags.contains(.shift) ?? false)
            || (key?.modifierFlags.contains(.shift) ?? false)
    }
}

/// A plain multi-line field with the Return shortcut, for the composers
/// that had SwiftUI's TextField or TextEditor, which give no way to tell a
/// hardware Return from the on-screen one: a group room's field and the
/// full editor. With `maxLines`, it grows with its text up to that many
/// lines and then scrolls; without, it fills the space it's given.
struct ReturnKeyTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var enabled = true
    var accessibilityLabel: String
    var accessibilityIdentifier: String?
    var textInsets: UIEdgeInsets = .zero
    var maxLines: Int?
    @AppStorage(ComposerReturnKey.preferenceKey) private var returnKeySends = ComposerReturnKey.sendsByDefault
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.columnText) private var columnText
    /// Whether the composer's Send (or dictation's Stop in its place) can
    /// act now; Return falls back to a newline when it can't.
    var canSubmitFromReturn: Bool
    /// Sends, and reports whether anything was done.
    var onSubmitFromReturn: () -> Bool
    /// A long paste, offered as an attachment (`ReturnKeyTextView`).
    var onLongTextPaste: ((String) -> Bool)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ReturnKeyTextView {
        let view = ReturnKeyTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textColor = .label
        view.tintColor = .systemOrange
        view.textContainer.lineFragmentPadding = 0
        view.textContainerInset = textInsets
        view.keyboardDismissMode = .interactive
        view.text = text
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(view, context: context)
        return view
    }

    func updateUIView(_ uiView: ReturnKeyTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(text: text, to: uiView, hasMarkedText: uiView.markedTextRange != nil)
        configure(uiView, context: context)
        if isFocused, !uiView.isFirstResponder, uiView.window != nil {
            DispatchQueue.main.async { uiView.becomeFirstResponder() }
        }
        if !isFocused, uiView.isFirstResponder {
            DispatchQueue.main.async { _ = uiView.resignFirstResponder() }
        }
    }

    static func dismantleUIView(_ uiView: ReturnKeyTextView, coordinator: Coordinator) {
        uiView.delegate = nil
        uiView.onSubmitFromReturn = nil
        uiView.canSubmitFromReturn = false
        uiView.onLongTextPaste = nil
    }

    private func configure(_ view: ReturnKeyTextView, context: Context) {
        // Body text at the environment's size, which a wide window's chat
        // column steps up (`readableChatColumn`), set on each change rather
        // than adjusted by UIKit, which would undo a Mac's point-size growth
        // (`UIFont.preferredFont(forTextStyle:in:)`).
        if view.fontSizeCategory != sizeCategory || view.fontColumnText != columnText {
            view.fontSizeCategory = sizeCategory
            view.fontColumnText = columnText
            view.font = .preferredFont(forTextStyle: .body, in: sizeCategory, from: columnText)
        }
        if view.isEditable != enabled { view.isEditable = enabled }
        view.accessibilityLabel = accessibilityLabel
        view.accessibilityIdentifier = accessibilityIdentifier
        view.returnKeySends = returnKeySends
        view.canSubmitFromReturn = canSubmitFromReturn
        view.onSubmitFromReturn = onSubmitFromReturn
        view.onLongTextPaste = onLongTextPaste
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ReturnKeyTextView, context: Context) -> CGSize? {
        guard let maxLines else { return nil }
        guard let font = uiView.font else { return nil }
        let width = proposal.width ?? uiView.bounds.width
        let insets = uiView.textContainerInset.top + uiView.textContainerInset.bottom
        // Not laid out yet: one line.
        guard width > 0 else { return CGSize(width: width, height: ceil(font.lineHeight + insets)) }
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let cap = ceil(font.lineHeight * CGFloat(maxLines) + insets)
        let scrolls = fitting > cap
        if uiView.isScrollEnabled != scrolls {
            DispatchQueue.main.async { uiView.isScrollEnabled = scrolls }
        }
        return CGSize(width: width, height: min(ceil(fitting), cap))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ReturnKeyTextEditor

        /// A change made elsewhere while the IME was composing. It lands
        /// once the composition ends, never replacing it mid-way.
        private(set) var pendingText: String?
        /// The text the field last reported. A binding equal to it is that
        /// report's echo, possibly behind typing still in flight, never a
        /// change made elsewhere (#333).
        private var lastReportedText: String?

        init(_ parent: ReturnKeyTextEditor) {
            self.parent = parent
        }

        /// A change made elsewhere (dictation, a quote, a mention, a send
        /// clearing the field) goes into the field, the cursor after it.
        /// Internal, with the IME state passed in, for tests.
        func apply(text: String, to textView: UITextView, hasMarkedText: Bool) {
            guard textView.text != text, text != lastReportedText else { return }
            if hasMarkedText {
                // The binding also echoes the composition itself; only a
                // text that isn't the field's is a change made elsewhere.
                pendingText = text
                return
            }
            pendingText = nil
            lastReportedText = text
            textView.text = text
            textView.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidChange(_ textView: UITextView) {
            textDidChange(in: textView, hasMarkedText: textView.markedTextRange != nil)
        }

        func textDidChange(in textView: UITextView, hasMarkedText: Bool) {
            if !hasMarkedText, let pending = pendingText {
                // The composition ended: the change made meanwhile wins.
                // Spent first, so one already in place can't linger.
                pendingText = nil
                apply(text: pending, to: textView, hasMarkedText: false)
                parent.text = pending
                return
            }
            if !hasMarkedText { pendingText = nil }
            lastReportedText = textView.text
            parent.text = textView.text
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }
    }
}
