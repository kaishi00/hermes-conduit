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
import UniformTypeIdentifiers

class ReturnKeyTextView: UITextView {
    /// The text size and column `font` was last set for
    /// (ReturnKeyTextEditor).
    var fontSizeCategory: ContentSizeCategory?
    var fontColumnText: ColumnText?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        inlinePredictionType = Self.inlinePredictionType(onMac: ProcessInfo.processInfo.isiOSAppOnMac)
        installFieldDrop()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        inlinePredictionType = Self.inlinePredictionType(onMac: ProcessInfo.processInfo.isiOSAppOnMac)
        installFieldDrop()
    }

    // MARK: Drops on the field

    // UITextView's own text drop took a file dropped on the field (a
    // picture from Finder) and never finished it: nothing attached, the
    // chat's "Drop to attach" outline stayed up and the drag hung on
    // (issue 1689). So the field has one drop interaction, this one: it
    // takes words and links into the draft, files only where the field
    // stages them itself (the chat composer), and turns other files down
    // so the chat, the room or the full editor around it attaches them.

    /// What a drop on the field does with what is dragged over it.
    enum FieldDrop: Equatable {
        /// The field stages the files (and puts any words in the draft).
        case files
        /// The words or links go into the draft.
        case words
        /// The field turns it down; a drop target around it may take it.
        case declined
    }

    static func fieldDrop(
        registeredTypeIdentifiers: [[String]],
        suggestedNames: [String?],
        isEditable: Bool,
        takesFiles: Bool
    ) -> FieldDrop {
        let items = zip(registeredTypeIdentifiers, suggestedNames)
        if items.contains(where: { AttachmentDrop.takes(registeredTypeIdentifiers: $0, suggestedName: $1) }) {
            // A locked field takes no files, as its Attach menu is off.
            return takesFiles && isEditable ? .files : .declined
        }
        let hasWords = registeredTypeIdentifiers.contains { identifiers in
            identifiers.contains { identifier in
                guard let type = UTType(identifier) else { return false }
                return type.conforms(to: .text) || type.conforms(to: .url)
            }
        }
        return isEditable && hasWords ? .words : .declined
    }

    func fieldDrop(for providers: [NSItemProvider]) -> FieldDrop {
        Self.fieldDrop(
            registeredTypeIdentifiers: providers.map(\.registeredTypeIdentifiers),
            suggestedNames: providers.map(\.suggestedName),
            isEditable: isEditable,
            takesFiles: takesDroppedFiles
        )
    }

    /// Whether the field stages dropped files itself. A field that doesn't
    /// leaves them to the drop target around it.
    var takesDroppedFiles: Bool { false }

    /// Stages the files among `providers` (words and links among them go
    /// into the draft separately). Only called when `takesDroppedFiles`.
    func takeDroppedFiles(_ providers: [NSItemProvider]) {}

    private let fieldDropHandler = FieldDropHandler()

    private func installFieldDrop() {
        fieldDropHandler.field = self
        textDropDelegate = nil
        textDragDelegate = fieldDropHandler
        for case let drop as UIDropInteraction in interactions where drop.delegate !== fieldDropHandler {
            removeInteraction(drop)
        }
        if !interactions.contains(where: { ($0 as? UIDropInteraction)?.delegate === fieldDropHandler }) {
            super.addInteraction(UIDropInteraction(delegate: fieldDropHandler))
        }
    }

    override func addInteraction(_ interaction: UIInteraction) {
        // UIKit's own text drop (or one a paste configuration brings) is
        // kept off the field: the field's drop is `fieldDropHandler`'s.
        if let drop = interaction as? UIDropInteraction, drop.delegate !== fieldDropHandler { return }
        super.addInteraction(interaction)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        installFieldDrop()
        if window != nil { scheduleFocusIntent() }
    }

    // MARK: Focus

    /// The composer wants the field focused: taken once it's in a window.
    private(set) var focusesInWindow = false
    private var focusChangeScheduled = false

    /// Takes or gives up focus as the composer asks, just after the
    /// SwiftUI update that asked, never inside it. Inside it, resigning
    /// asks the hosting view whether it can take focus, which re-enters
    /// the view graph mid-update: on iOS 27 the whole app froze there
    /// while typing (issue 1781). Several asks before it runs come to the
    /// last one; a change UIKit refuses is asked again on the next update,
    /// since the binding still says so. Out of a window, the wish waits
    /// for `didMoveToWindow`.
    func setFocusIntent(_ wantsFocus: Bool) {
        focusesInWindow = wantsFocus
        scheduleFocusIntent()
    }

    private var focusMatchesIntent: Bool {
        focusesInWindow ? (isFirstResponder || window == nil) : !isFirstResponder
    }

    private func scheduleFocusIntent() {
        guard !focusMatchesIntent, !focusChangeScheduled else { return }
        focusChangeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusChangeScheduled = false
            self.applyFocusIntent()
        }
    }

    private func applyFocusIntent() {
        if focusesInWindow, !isFirstResponder, window != nil { _ = becomeFirstResponder() }
        if !focusesInWindow, isFirstResponder { _ = resignFirstResponder() }
    }

    /// Takes a drop the field accepted: files to the composer, words and
    /// links into the draft where they were dropped.
    func takeDrop(_ providers: [NSItemProvider], at point: CGPoint) {
        let decision = fieldDrop(for: providers)
        guard decision != .declined else { return }
        if decision == .files { takeDroppedFiles(providers) }
        let words = providers.filter { !AttachmentDrop.takes($0) }
        guard isEditable, !words.isEmpty else { return }
        if !isFirstResponder { _ = becomeFirstResponder() }
        let target = closestPosition(to: point).flatMap { textRange(from: $0, to: $0) }
        if let target { selectedTextRange = target }
        Task { @MainActor [weak self] in
            var pieces: [String] = []
            for provider in words {
                if let piece = await Self.droppedWords(from: provider) { pieces.append(piece) }
            }
            let text = pieces.joined(separator: " ")
            // A field the composer replaced meanwhile (a send, another
            // chat) is out of its window; the words aren't put there.
            guard let self, self.isEditable, self.window != nil, !text.isEmpty else { return }
            // At the drop point, even if the caret moved while they loaded.
            if let target { self.selectedTextRange = target }
            self.insertText(text)
        }
    }

    /// Words dragged within the field move there, as UIKit's own text drop
    /// moved them: the dragged range leaves and goes in at the drop point.
    /// A drop inside the dragged range leaves the text as it was.
    func moveDraggedWords(from source: NSRange, to point: CGPoint) {
        guard isEditable,
              let position = closestPosition(to: point),
              let move = Self.wordsMove(
                source: source,
                dropOffset: offset(from: beginningOfDocument, to: position),
                length: (text as NSString).length
              ) else { return }
        let moved = (text as NSString).substring(with: source)
        if !isFirstResponder { _ = becomeFirstResponder() }
        // Through the text system, so the composer hears both edits.
        selectedRange = source
        deleteBackward()
        selectedRange = NSRange(location: move.insertOffset, length: 0)
        insertText(moved)
    }

    /// Where words dragged from `source` go in once they've left, or nil
    /// when the drop is inside them (or the range no longer fits).
    static func wordsMove(source: NSRange, dropOffset: Int, length: Int) -> (deleteRange: NSRange, insertOffset: Int)? {
        guard source.length > 0, source.location >= 0, NSMaxRange(source) <= length,
              dropOffset >= 0, dropOffset <= length else { return nil }
        if dropOffset >= source.location && dropOffset <= NSMaxRange(source) { return nil }
        let insertOffset = dropOffset > NSMaxRange(source) ? dropOffset - source.length : dropOffset
        return (source, insertOffset)
    }

    /// The words a dragged item carries, or its link written out.
    static func droppedWords(from provider: NSItemProvider) async -> String? {
        if provider.canLoadObject(ofClass: String.self) {
            let text: String? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    continuation.resume(returning: text)
                }
            }
            if let text { return text }
        }
        if provider.canLoadObject(ofClass: URL.self) {
            return await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url?.absoluteString)
                }
            }
        }
        return nil
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
        guard let onLongTextPaste,
              let pasted = Self.longPastedText(
                isEditable: isEditable,
                hasStrings: pasteboard.hasStrings,
                hasImages: pasteboard.hasImages,
                read: { pasteboard.string }
              ),
              onLongTextPaste(pasted) else { return false }
        // A paste replaces what was selected, wherever the words went.
        if selectedRange.length > 0 { deleteBackward() }
        return true
    }

    /// The paste to offer as an attachment, if any: words only (a picture
    /// keeps its own paste), past the threshold, into an editable field.
    /// The clipboard's text is read only once the rest allows it.
    static func longPastedText(isEditable: Bool, hasStrings: Bool, hasImages: Bool, read: () -> String?) -> String? {
        guard isEditable, hasStrings, !hasImages,
              let pasted = read(), PastedText.becomesAttachment(pasted) else { return nil }
        return pasted
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
        // Applied after this update, the latest ask winning (issue 1781).
        uiView.setFocusIntent(isFocused)
    }

    static func dismantleUIView(_ uiView: ReturnKeyTextView, coordinator: Coordinator) {
        uiView.setFocusIntent(false)
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

/// The field's only drop interaction (`ReturnKeyTextView.installFieldDrop`).
/// A drop it turns down goes to the drop target around the field. As the
/// field's text drag delegate it also keeps the range a drag from the
/// field took, so a drop back in the field moves those words.
final class FieldDropHandler: NSObject, UIDropInteractionDelegate, UITextDragDelegate {
    weak var field: ReturnKeyTextView?
    /// The drag session a drag of the field's own words started, and the
    /// range it took. Kept as an object so tests can stand in for it.
    private weak var draggedSession: AnyObject?
    private var draggedRange: NSRange?

    func textDraggableView(_ textDraggableView: UIView & UITextDraggable, itemsForDrag dragRequest: UITextDragRequest) -> [UIDragItem] {
        if let field {
            let start = field.offset(from: field.beginningOfDocument, to: dragRequest.dragRange.start)
            let end = field.offset(from: field.beginningOfDocument, to: dragRequest.dragRange.end)
            noteDrag(dragRequest.dragSession, range: NSRange(location: start, length: max(0, end - start)))
        }
        return dragRequest.suggestedItems
    }

    func textDraggableView(_ textDraggableView: UIView & UITextDraggable, dragSessionDidEnd session: UIDragSession, with operation: UIDropOperation) {
        if session === draggedSession {
            draggedSession = nil
            draggedRange = nil
        }
    }

    func noteDrag(_ session: AnyObject, range: NSRange) {
        draggedSession = session
        draggedRange = range
    }

    /// The range of the field's own words a drop carries, if it does.
    func ownWords(local: AnyObject?) -> NSRange? {
        guard let local, local === draggedSession else { return nil }
        return draggedRange
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        guard let field else { return false }
        return field.fieldDrop(for: session.items.map(\.itemProvider)) != .declined
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        // A copy even for the field's own words: the field moves them
        // itself (`perform`), so the drag's source never removes them too.
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard let field else { return }
        perform(session.items.map(\.itemProvider), local: session.localDragSession, at: session.location(in: field))
    }

    /// Called for every drag that reached the field, however it ended.
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
        dragEnded()
    }

    /// A drag that reached the field ended, here or anywhere else. The
    /// chat's or room's drop target outlined it on the way in and isn't
    /// told it ended, so it hears it from here (issue 1689).
    func dragEnded() {
        NotificationCenter.default.post(name: .attachmentDragEnded, object: nil)
    }

    /// A drop of the field's own words moves them; anything else is the
    /// field's `takeDrop`.
    func perform(_ providers: [NSItemProvider], local: AnyObject?, at point: CGPoint) {
        guard let field else { return }
        if let source = ownWords(local: local) {
            draggedSession = nil
            draggedRange = nil
            field.moveDraggedWords(from: source, to: point)
            return
        }
        field.takeDrop(providers, at: point)
    }
}
