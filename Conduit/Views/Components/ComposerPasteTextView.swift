//
//  ComposerPasteTextView.swift
//  Conduit
//
//  UIKit supplies the paste override SwiftUI intentionally does not expose on
//  iOS. Text continues through normally, while a pasted bitmap becomes an
//  attachment in the composer instead of an opaque text placeholder.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PastedImage: Equatable {
    let data: Data
    let typeIdentifier: String
}

struct ComposerPasteTextView: UIViewRepresentable {
    static let minimumHeight: CGFloat = 44
    static let maximumHeight: CGFloat = 160

    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var measuredHeight: CGFloat
    let enabled: Bool
    let onPastedImage: (PastedImage) -> Void
    let onPastedImageError: (String) -> Void
    let editorIdentity: UUID
    /// Hardware-keyboard Return behavior. When true, a plain Return press
    /// submits through the composer action path; Shift-Return and every
    /// non-submittable state keep the default newline insertion.
    var returnKeySends: Bool = false
    /// Live composer verdict on whether the Return shortcut may currently
    /// fire. ComposerBar computes this from the existing action state; the
    /// text view never approximates it.
    var canSubmitFromReturn: Bool = false
    /// Invoked on the main thread when a Return press classifies as submit.
    /// Returns whether the composer actually acted: only then is the Return
    /// press consumed; a declined action keeps the default text behavior.
    /// ComposerBar stays the owner of the actual send/steer/interrupt action.
    var onSubmitFromReturn: (() -> Bool)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ImagePasteTextView {
        let view = ImagePasteTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.backgroundColor = .clear
        view.textColor = .label
        view.tintColor = .systemOrange
        view.textContainerInset = UIEdgeInsets(top: 8, left: 9, bottom: 8, right: 9)
        view.textContainer.lineFragmentPadding = 0
        // Keep long pasted prompts usable without letting the composer cover its
        // own action controls. Short messages retain the same compact height.
        view.isScrollEnabled = true
        view.alwaysBounceVertical = false
        view.showsVerticalScrollIndicator = true
        view.keyboardDismissMode = .interactive
        view.minimumReportedHeight = Self.minimumHeight
        view.maximumReportedHeight = Self.maximumHeight
        view.editorIdentity = editorIdentity
        view.onContentHeightChange = { height in
            context.coordinator.updateMeasuredHeight(height)
        }
        view.onPastedImage = onPastedImage
        view.onPastedImageError = onPastedImageError
        view.returnKeySends = returnKeySends
        view.canSubmitFromReturn = canSubmitFromReturn
        view.onSubmitFromReturn = onSubmitFromReturn
        return view
    }

    static func dismantleUIView(_ uiView: ImagePasteTextView, coordinator: Coordinator) {
        coordinator.deactivate(textView: uiView)
    }

    func updateUIView(_ uiView: ImagePasteTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.isActive = true
        context.coordinator.apply(text: text, editorIdentity: editorIdentity, to: uiView)
        uiView.isEditable = enabled
        uiView.editorIdentity = editorIdentity
        uiView.onContentHeightChange = { height in
            context.coordinator.updateMeasuredHeight(height)
        }
        uiView.onPastedImage = onPastedImage
        uiView.onPastedImageError = onPastedImageError
        uiView.returnKeySends = returnKeySends
        uiView.canSubmitFromReturn = canSubmitFromReturn
        uiView.onSubmitFromReturn = onSubmitFromReturn
        uiView.setNeedsLayout()
        if isFocused, !uiView.isFirstResponder { uiView.becomeFirstResponder() }
        if !isFocused, uiView.isFirstResponder { uiView.resignFirstResponder() }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerPasteTextView
        var isApplyingProgrammaticState = false
        var isActive = true
        private var editorIdentity: UUID?

        init(_ parent: ComposerPasteTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            guard isActive, !isApplyingProgrammaticState else { return }
            parent.text = textView.text
            textView.scrollRangeToVisible(textView.selectedRange)
            textView.setNeedsLayout()
        }
        func textViewDidBeginEditing(_ textView: UITextView) {
            guard isActive, !isApplyingProgrammaticState else { return }
            parent.isFocused = true
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            guard isActive, !isApplyingProgrammaticState else { return }
            parent.isFocused = false
        }

        func updateMeasuredHeight(_ height: CGFloat) {
            guard isActive else { return }
            guard abs(parent.measuredHeight - height) > 0.5 else { return }
            parent.measuredHeight = height
        }

        func apply(text: String, editorIdentity: UUID, to textView: UITextView) {
            let needsTextUpdate = textView.text != text
            let needsIdentityUpdate = self.editorIdentity != editorIdentity
            guard needsTextUpdate || needsIdentityUpdate else { return }

            let clampedSelection = clampedSelectionRange(
                textView.selectedRange,
                maxLength: (text as NSString).length
            )

            isApplyingProgrammaticState = true
            defer {
                isApplyingProgrammaticState = false
                self.editorIdentity = editorIdentity
            }

            textView.text = text
            textView.selectedRange = clampedSelection
            textView.setNeedsLayout()
        }

        func deactivate(textView: UITextView) {
            isActive = false
            isApplyingProgrammaticState = false
            editorIdentity = nil
            textView.delegate = nil
            if let textView = textView as? ImagePasteTextView {
                textView.editorIdentity = nil
                textView.onContentHeightChange = nil
                textView.onPastedImage = nil
                textView.onPastedImageError = nil
                textView.returnKeySends = false
                textView.canSubmitFromReturn = false
                textView.onSubmitFromReturn = nil
            }
            if textView.isFirstResponder {
                textView.resignFirstResponder()
            }
        }

        private func clampedSelectionRange(_ range: NSRange, maxLength: Int) -> NSRange {
            let location = min(max(range.location, 0), maxLength)
            let remaining = max(0, maxLength - location)
            let length = min(max(range.length, 0), remaining)
            return NSRange(location: location, length: length)
        }
    }
}

final class ImagePasteTextView: UITextView {
    var onPastedImage: ((PastedImage) -> Void)?
    var onPastedImageError: ((String) -> Void)?
    var onContentHeightChange: ((CGFloat) -> Void)?
    var editorIdentity: UUID?
    var minimumReportedHeight: CGFloat = 44
    var maximumReportedHeight: CGFloat = 160
    private var lastReportedHeight: CGFloat = 0

    // Hardware-keyboard Return shortcut. pressesBegan only classifies the
    // keystroke; the send-vs-newline policy lives in ComposerReturnKey and
    // the actual composer action stays in ComposerBar. The software
    // keyboard's Return key does not produce UIPress events, so it keeps its
    // existing newline behavior untouched.
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

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        foldHardwareShift(presses, pressed: true)
        var forwarding = presses
        if let returnPress = presses.first(where: { Self.isReturnKeyPress($0) }) {
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
        if !forwarding.isEmpty {
            super.pressesBegan(forwarding, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        foldHardwareShift(presses, pressed: false)
        // Forward the original set: UIKit tracks press lifecycle across the
        // whole sequence, not just the keys this shortcut cares about.
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // A cancelled sequence (e.g. the system ends chord tracking) must
        // release tracked Shift state exactly like a normal key-up, or the
        // shortcut would keep believing Shift is held.
        foldHardwareShift(presses, pressed: false)
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

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configurePasteSupport()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configurePasteSupport()
    }

    private func configurePasteSupport() {
        pasteConfiguration = UIPasteConfiguration(
            acceptableTypeIdentifiers: [
                UTType.text.identifier,
                UTType.image.identifier,
                UTType.item.identifier
            ]
        )
    }

    private func imageTypeIdentifier(for provider: NSItemProvider) -> String? {
        if let registeredImageType = provider.registeredTypeIdentifiers.first(where: { identifier in
            UTType(identifier)?.conforms(to: .image) == true
        }) {
            return registeredImageType
        }

        // Some system providers expose an image representation through their
        // conformance query without listing a concrete image UTI that we can
        // resolve locally. Ask the provider for the abstract image type so
        // loadDataRepresentation can perform the necessary coercion.
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return UTType.image.identifier
        }

        return nil
    }

    private func canLoadImageProvider(_ provider: NSItemProvider) -> Bool {
        imageTypeIdentifier(for: provider) != nil
            || provider.canLoadObject(ofClass: UIImage.self)
    }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        if itemProviders.contains(where: { canLoadImageProvider($0) }) {
            return true
        }
        return super.canPaste(itemProviders)
    }

    /// Surfaces the standard "Paste" edit-menu item when an image is on the
    /// pasteboard. UITextView drops "Paste" for image-only content (it cannot
    /// paste an image as text), leaving system items such as "Autofill" as the
    /// only options. `canPaste`/`paste(itemProviders:)` route external paste
    /// triggers but never gate the long-press menu, so without this override
    /// the image paste code is unreachable from the edit menu.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), shouldOfferImagePaste() {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Whether the edit menu should offer "Paste" for an image. Extracted as a
    /// pure function over `isEditable` and `pasteboardContainsImage()` so the
    /// gate is unit-testable in isolation, without depending on `super` or the
    /// view's first-responder/window state.
    func shouldOfferImagePaste() -> Bool {
        isEditable && pasteboardContainsImage()
    }

    /// Reports whether the general pasteboard advertises image content using
    /// only banner-safe metadata access: `hasImages` (Apple's conformance-aware
    /// detector) plus a conformance scan over `pasteboard.types` as a
    /// belt-and-suspenders fallback. Both read type metadata rather than
    /// contents, so they do NOT raise the iOS "Paste from Other App" prompt —
    /// important because `canPerformAction` runs before the user consents to a
    /// paste and is called repeatedly while the edit menu is displayed. This
    /// deliberately avoids `pb.image`/`pb.data(...)`, `pb.url`, and
    /// materializing `pb.itemProviders`, all of which can trigger the banner.
    /// Note: an image *URL* without image data (e.g. copied from Safari) is not
    /// detected here, so "Paste" is not offered for that case; the legacy
    /// `pb.url` path in `paste(_:)` stays reachable only via external triggers.
    func pasteboardContainsImage() -> Bool {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasImages { return true }
        return pasteboard.types.contains { UTType($0)?.conforms(to: .image) ?? false }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let contentHeight = bounds.width > 0 && contentSize.height.isFinite
            ? contentSize.height
            : minimumReportedHeight
        let height = min(max(contentHeight, minimumReportedHeight), maximumReportedHeight)
        guard abs(lastReportedHeight - height) > 0.5 else { return }
        lastReportedHeight = height
        DispatchQueue.main.async { [weak self] in
            self?.onContentHeightChange?(height)
        }
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first(where: { canLoadImageProvider($0) }) else {
            super.paste(itemProviders: itemProviders)
            return
        }

        let pasteEditorIdentity = editorIdentity
        if let imageType = imageTypeIdentifier(for: provider) {
            provider.loadDataRepresentation(forTypeIdentifier: imageType) { [weak self] data, error in
                guard let data, !data.isEmpty else {
                    if provider.canLoadObject(ofClass: UIImage.self) {
                        self?.loadImageObject(
                            from: provider,
                            fallbackError: error,
                            editorIdentity: pasteEditorIdentity
                        )
                    } else {
                        self?.reportImageLoadFailure(error, editorIdentity: pasteEditorIdentity)
                    }
                    return
                }
                self?.deliverImageData(
                    data,
                    typeIdentifier: imageType,
                    editorIdentity: pasteEditorIdentity
                )
            }
            return
        }

        loadImageObject(from: provider, editorIdentity: pasteEditorIdentity)
    }

    private func loadImageObject(
        from provider: NSItemProvider,
        fallbackError: Error? = nil,
        editorIdentity pasteEditorIdentity: UUID? = nil
    ) {
        let pasteEditorIdentity = pasteEditorIdentity ?? editorIdentity
        // Spell out the protocol existential so Swift selects the
        // NSItemProviderReading overload. The inferred generic overload on
        // newer SDKs expects UIImage to be _ObjectiveCBridgeable and fails
        // during compilation even though UIImage supports this API.
        provider.loadObject(ofClass: UIImage.self) { [weak self] (object: NSItemProviderReading?, error: Error?) in
            guard let image = object as? UIImage,
                  let data = image.pngData(),
                  !data.isEmpty else {
                self?.reportImageLoadFailure(
                    error ?? fallbackError,
                    editorIdentity: pasteEditorIdentity
                )
                return
            }
            self?.deliverImageData(
                data,
                typeIdentifier: UTType.png.identifier,
                editorIdentity: pasteEditorIdentity
            )
        }
    }

    private func deliverImageData(
        _ data: Data,
        typeIdentifier: String,
        editorIdentity pasteEditorIdentity: UUID? = nil
    ) {
        let pasteEditorIdentity = pasteEditorIdentity ?? editorIdentity
        let pastedImage: PastedImage
        if typeIdentifier == UTType.image.identifier {
            guard let image = UIImage(data: data),
                  let normalizedData = image.pngData(),
                  !normalizedData.isEmpty else {
                reportImageNormalizationFailure(editorIdentity: pasteEditorIdentity)
                return
            }
            pastedImage = PastedImage(
                data: normalizedData,
                typeIdentifier: UTType.png.identifier
            )
        } else {
            pastedImage = PastedImage(data: data, typeIdentifier: typeIdentifier)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.editorIdentity == pasteEditorIdentity else { return }
            self.onPastedImage?(pastedImage)
        }
    }

    private func reportImageNormalizationFailure(editorIdentity pasteEditorIdentity: UUID? = nil) {
        let pasteEditorIdentity = pasteEditorIdentity ?? editorIdentity
        DispatchQueue.main.async { [weak self] in
            guard let self, self.editorIdentity == pasteEditorIdentity else { return }
            self.onPastedImageError?("The image provider returned invalid image data.")
        }
    }

    private func reportImageLoadFailure(
        _ error: Error?,
        editorIdentity pasteEditorIdentity: UUID? = nil
    ) {
        let pasteEditorIdentity = pasteEditorIdentity ?? editorIdentity
        let message = error?.localizedDescription ?? "The image provider returned no data."
        DispatchQueue.main.async { [weak self] in
            guard let self, self.editorIdentity == pasteEditorIdentity else { return }
            self.onPastedImageError?(message)
        }
    }

    /// When the pasteboard holds an image it is delivered as an attachment via
    /// `onPastedImage`; any accompanying text is not inserted, since this
    /// attachment composer treats the image as the payload. Non-image
    /// pasteboards fall through to the standard text behavior.
    override func paste(_ sender: Any?) {
        let pb = UIPasteboard.general
        let pasteEditorIdentity = editorIdentity

        // Direct image in pasteboard
        if let image = pb.image, let data = image.pngData() {
            deliverImageData(
                data,
                typeIdentifier: UTType.png.identifier,
                editorIdentity: pasteEditorIdentity
            )
            return
        }

        // Image URL in pasteboard (common from Safari/Photos copy)
        if let url = pb.url, url.scheme?.hasPrefix("http") == true {
            let ext = url.pathExtension.lowercased()
            let imageExts = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "tiff"]
            if imageExts.contains(ext) || pb.types.contains("public.image") {
                URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                    guard let data = data else { return }
                    let typeIdentifier = UTType(filenameExtension: ext)?.identifier ?? UTType.image.identifier
                    self?.deliverImageData(
                        data,
                        typeIdentifier: typeIdentifier,
                        editorIdentity: pasteEditorIdentity
                    )
                }.resume()
                return
            }
        }

        // Raw image data without .image property
        if let data = pb.data(forPasteboardType: "public.image"), !data.isEmpty {
            deliverImageData(
                data,
                typeIdentifier: UTType.image.identifier,
                editorIdentity: pasteEditorIdentity
            )
            return
        }

        // Some system paste actions expose the image only through an item
        // provider, even though they still invoke the legacy paste selector.
        if let provider = pb.itemProviders.first(where: { canLoadImageProvider($0) }) {
            paste(itemProviders: [provider])
            return
        }

        super.paste(sender)
    }
}
