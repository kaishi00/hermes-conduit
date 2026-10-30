//
//  ComposerPasteTextView.swift
//  Conduit
//
//  UIKit supplies the paste override SwiftUI intentionally does not expose on
//  iOS. Text continues through normally, while a pasted bitmap becomes an
//  attachment in the composer instead of an opaque text placeholder.
//

import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PastedImage: Equatable {
    let data: Data
    let typeIdentifier: String
}

/// A pasted image link's download, kept only when it is a picture, under
/// the type it actually is: a link can answer with an error page whatever
/// its extension says. One whose header claims more pixels than a reply's
/// picture may have (`BoundedRemoteImage.maxPixelCount`) is refused too: it
/// would become an attachment that decodes to gigabytes.
enum PastedRemoteImage {
    static func image(from data: Data) -> PastedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0,
              width <= BoundedRemoteImage.maxPixelCount / height else { return nil }
        return PastedImage(data: data, typeIdentifier: type)
    }
}

struct ComposerPasteTextView: UIViewRepresentable {
    /// One line of body text plus the text insets at the current text size,
    /// so a large Text Size doesn't clip the first line.
    static var minimumHeight: CGFloat { minimumHeight(for: .preferredFont(forTextStyle: .body)) }
    /// About four lines at large text sizes, never under the original
    /// 160 pt, and capped so the composer can't cover the chat.
    static var maximumHeight: CGFloat { maximumHeight(for: .preferredFont(forTextStyle: .body)) }

    /// The bounds for the text view's own font (`bodyFont`).
    static func minimumHeight(for font: UIFont) -> CGFloat {
        max(44, ceil(font.lineHeight) + 16)
    }

    static func maximumHeight(for font: UIFont) -> CGFloat {
        min(max(160, ceil(font.lineHeight) * 4 + 16), 280)
    }

    /// Body text at the view's environment size, which a wide window's
    /// chat column steps up (`readableChatColumn`), grown by point size
    /// where the system draws it no larger, as an iPad app on a Mac does
    /// (`UIFont.preferredFont(forTextStyle:in:from:)`).
    static func bodyFont(in sizeCategory: ContentSizeCategory, from column: ColumnText?) -> UIFont {
        UIFont.preferredFont(forTextStyle: .body, in: sizeCategory, from: column)
    }

    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.columnText) private var columnText

    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var measuredHeight: CGFloat
    let enabled: Bool
    let onPastedImage: (PastedImage) -> Void
    let onPastedImageError: (String) -> Void
    let editorIdentity: UUID
    /// Files dropped or pasted on the field that are staged as attachments
    /// (`AttachmentDrop.stagesAsFiles`), on the main thread.
    var onDroppedFiles: (([NSItemProvider]) -> Void)? = nil
    /// A long paste, offered as an attachment (`ReturnKeyTextView`).
    var onLongTextPaste: ((String) -> Bool)? = nil
    /// Generation of INTENTIONAL programmatic composer replacements (draft
    /// restore, prefill, session handoff, slash insertion, clear after send).
    /// ComposerBar advances it only through `replaceComposerText(_:)`.
    /// Ordinary SwiftUI invalidations — streaming, reasoning, busy state,
    /// toolbar state — arrive with an unchanged revision, which is how the
    /// bridge tells them apart from a deliberate replacement and from the
    /// echo of a user edit: they may not rewrite the editor.
    var programmaticRevision: UInt64 = 0
    /// The replacement at `programmaticRevision` puts the cursor after the
    /// text (dictation) instead of keeping its position (#333).
    var programmaticCursorAtEnd = false
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
    /// Invoked synchronously from `textViewDidChange` — the earliest
    /// authoritative point a text mutation is known to be genuine user input
    /// (typing, deletion, paste), after the active/programmatic guards and
    /// before the SwiftUI binding updates. IME composition updates, commits,
    /// discards, and autocorrect substitutions also count: they are all
    /// user-driven mutations, and the extra claims are harmless under
    /// AppState's per-generation latch. Programmatic replacements ride the
    /// revision machinery inside `isApplyingProgrammaticState` and never
    /// reach this callback. ComposerBar forwards this to
    /// `AppState.noteComposerUserEdit()` so an in-flight automatic foreground
    /// return loses session-selection authority the moment the user edits.
    var onUserEdit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ImagePasteTextView {
        let view = ImagePasteTextView()
        view.delegate = context.coordinator
        // Set here and on each text size change below rather than
        // adjusted by UIKit, which would undo the Mac's point-size growth.
        view.font = Self.bodyFont(in: sizeCategory, from: columnText)
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
        view.onDroppedFiles = onDroppedFiles
        view.onLongTextPaste = onLongTextPaste
        view.returnKeySends = returnKeySends
        view.canSubmitFromReturn = canSubmitFromReturn
        view.onSubmitFromReturn = onSubmitFromReturn
        return view
    }

    static func dismantleUIView(_ uiView: ImagePasteTextView, coordinator: Coordinator) {
        coordinator.deactivate(textView: uiView)
    }

    func updateUIView(_ uiView: ImagePasteTextView, context: Context) {
        TranscriptPerf.note(.composerUpdateUIView)
        // Text Size changed while the app was open, or a wide column
        // stepped or scaled it: the font and the height bounds follow.
        // Checked by category and column so the hot update path doesn't
        // look up fonts.
        let category = UIContentSizeCategory(sizeCategory)
        if uiView.boundsContentSizeCategory != category || uiView.boundsColumnText != columnText {
            uiView.boundsContentSizeCategory = category
            uiView.boundsColumnText = columnText
            let font = Self.bodyFont(in: sizeCategory, from: columnText)
            uiView.font = font
            uiView.minimumReportedHeight = Self.minimumHeight(for: font)
            uiView.maximumReportedHeight = Self.maximumHeight(for: font)
            uiView.setNeedsLayout()
        }
        context.coordinator.parent = self
        context.coordinator.isActive = true
        context.coordinator.apply(
            text: text,
            programmaticRevision: programmaticRevision,
            cursorAtEnd: programmaticCursorAtEnd,
            editorIdentity: editorIdentity,
            to: uiView
        )
        // Layout is requested on text change and editability flip only;
        // bounds changes re-layout automatically through layoutSubviews.
        if uiView.isEditable != enabled {
            uiView.isEditable = enabled
            uiView.setNeedsLayout()
        }
        uiView.editorIdentity = editorIdentity
        uiView.onContentHeightChange = { height in
            context.coordinator.updateMeasuredHeight(height)
        }
        uiView.onPastedImage = onPastedImage
        uiView.onPastedImageError = onPastedImageError
        uiView.onDroppedFiles = onDroppedFiles
        uiView.onLongTextPaste = onLongTextPaste
        uiView.returnKeySends = returnKeySends
        uiView.canSubmitFromReturn = canSubmitFromReturn
        uiView.onSubmitFromReturn = onSubmitFromReturn
        if isFocused, !uiView.isFirstResponder { uiView.becomeFirstResponder() }
        if !isFocused, uiView.isFirstResponder { _ = uiView.resignFirstResponder() }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerPasteTextView
        var isApplyingProgrammaticState = false
        var isActive = true
        /// The last text UIKit itself reported through `textViewDidChange`.
        /// A binding value equal to this is the ECHO of a user edit, never a
        /// reason to write into the editor: UIKit's text-input delegate can
        /// deliver the change notification after the storage already moved
        /// on (and after unrelated SwiftUI invalidations), so a binding that
        /// lags the editor is evidence of in-flight user input, not of a
        /// programmatic source.
        private var lastTextReportedByUIKit = ""
        /// The programmatic revision currently reflected in the editor.
        /// Only an ADVANCE may rewrite the editor, and it does so exactly
        /// once; unchanged revisions ride along without touching text.
        private var appliedProgrammaticRevision: UInt64 = 0
        /// An intentional replacement that arrived while IME marked text was
        /// active. Composition is never silently replaced; this lands as
        /// soon as it ends.
        private var pendingProgrammatic: (text: String, revision: UInt64, cursorAtEnd: Bool)?
        private var editorIdentity: UUID?

        init(_ parent: ComposerPasteTextView) {
            self.parent = parent
            super.init()
        }

        func textViewDidChange(_ textView: UITextView) {
            guard isActive, !isApplyingProgrammaticState else { return }
            // Ownership claim first: this delegate callback is the earliest
            // point the mutation is provably user input. Everything below
            // (binding write, flush of a deferred programmatic replacement)
            // happens after the user already owns the conversation.
            parent.onUserEdit?()
            lastTextReportedByUIKit = textView.text
            parent.text = textView.text
            textView.scrollRangeToVisible(textView.selectedRange)
            textView.setNeedsLayout()
            flushPendingProgrammaticIfCompositionEnded(textView)
        }
        func textViewDidBeginEditing(_ textView: UITextView) {
            guard isActive, !isApplyingProgrammaticState else { return }
            parent.isFocused = true
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            guard isActive, !isApplyingProgrammaticState else { return }
            parent.isFocused = false
            flushPendingProgrammaticIfCompositionEnded(textView)
        }

        func updateMeasuredHeight(_ height: CGFloat) {
            guard isActive else { return }
            guard abs(parent.measuredHeight - height) > 0.5 else { return }
            parent.measuredHeight = height
        }

        /// The one gate between SwiftUI and the editor's text state.
        ///
        ///   user typing:            UIKit → binding (textViewDidChange)
        ///   unrelated invalidation: no SwiftUI → UIKit text replacement
        ///   intentional change:     programmaticRevision advance → UIKit
        ///
        /// A binding that merely disagrees with `textView.text` is NOT an
        /// intentional change — it is either the echo of text UIKit already
        /// reported, or user input that outran the delegate notification.
        func apply(
            text: String,
            programmaticRevision: UInt64,
            cursorAtEnd: Bool = false,
            editorIdentity: UUID,
            to textView: UITextView
        ) {
            if self.editorIdentity != editorIdentity {
                // Lifecycle boundary (session handoff / attachment rotate).
                // `.id(editorIdentity)` recreates the editor wholesale, so
                // this branch is defensive: reset bookkeeping to the fresh
                // view's actual state — the previous editor's pending
                // replacement and applied revision died with it.
                self.editorIdentity = editorIdentity
                lastTextReportedByUIKit = textView.text
                pendingProgrammatic = nil
                appliedProgrammaticRevision = 0
                if textView.text != text {
                    // The binding is the fresh editor's ground truth even
                    // when no revision advance accompanies the rotation.
                    // Every production rotation is text-paired through
                    // replaceComposerText; applying here keeps a future
                    // unpaired rotation from silently blanking the editor.
                    performProgrammaticReplacement(
                        text: text,
                        revision: programmaticRevision,
                        cursorAtEnd: cursorAtEnd,
                        into: textView
                    )
                    return
                }
            }
            flushPendingProgrammaticIfCompositionEnded(textView)

            // An unrelated invalidation keeps the revision and can stop here.
            guard programmaticRevision != appliedProgrammaticRevision else { return }

            // Active IME composition is never silently replaced — nor
            // revision-adopted; the deferred replacement lands when the
            // composition ends and stays the newest instruction.
            if textView.markedTextRange != nil {
                TranscriptPerf.note(.composerMarkedTextDeferral)
                pendingProgrammatic = (text, programmaticRevision, cursorAtEnd)
                return
            }

            if text == textView.text {
                // The editor verifiably holds the intended value — checked
                // against the LIVE text, not only the last delegate report,
                // which can lag in-flight user input. Adopt the revision so
                // bookkeeping stays in sync without tearing down live input
                // state with a redundant rewrite.
                appliedProgrammaticRevision = programmaticRevision
                lastTextReportedByUIKit = textView.text
                return
            }

            // A revision advance the editor does not verifiably hold is a
            // genuine intentional replacement: apply it even when the value
            // equals the last reported text — the live editor has moved past
            // that report, and the intentional source stays authoritative.
            performProgrammaticReplacement(
                text: text,
                revision: programmaticRevision,
                cursorAtEnd: cursorAtEnd,
                into: textView
            )
        }

        func deactivate(textView: UITextView) {
            isActive = false
            isApplyingProgrammaticState = false
            pendingProgrammatic = nil
            lastTextReportedByUIKit = ""
            appliedProgrammaticRevision = 0
            editorIdentity = nil
            textView.delegate = nil
            if let textView = textView as? ImagePasteTextView {
                textView.editorIdentity = nil
                textView.onContentHeightChange = nil
                textView.onPastedImage = nil
                textView.onPastedImageError = nil
                textView.onDroppedFiles = nil
                textView.onLongTextPaste = nil
                textView.returnKeySends = false
                textView.canSubmitFromReturn = false
                textView.onSubmitFromReturn = nil
            }
            if textView.isFirstResponder {
                textView.resignFirstResponder()
            }
        }

        /// A deferred intentional replacement lands at the first
        /// composition-free moment: `textViewDidChange` fires for both the
        /// commit and the discard of marked text, and any later
        /// `updateUIView` re-checks here.
        private func flushPendingProgrammaticIfCompositionEnded(_ textView: UITextView) {
            guard textView.markedTextRange == nil,
                  let pending = pendingProgrammatic else { return }
            pendingProgrammatic = nil
            if textView.text == pending.text {
                // Already in place: record the revision without tearing down
                // live input state with a redundant assignment.
                appliedProgrammaticRevision = pending.revision
                lastTextReportedByUIKit = textView.text
                return
            }
            performProgrammaticReplacement(
                text: pending.text,
                revision: pending.revision,
                cursorAtEnd: pending.cursorAtEnd,
                into: textView
            )
        }

        private func performProgrammaticReplacement(
            text: String,
            revision: UInt64,
            cursorAtEnd: Bool,
            into textView: UITextView
        ) {
            let length = (text as NSString).length
            let clampedSelection = cursorAtEnd
                ? NSRange(location: length, length: 0)
                : clampedSelectionRange(textView.selectedRange, maxLength: length)

            TranscriptPerf.note(.composerProgrammaticTextAssignment)
            TranscriptPerf.lastComposerSelectionBeforeAssignment = textView.selectedRange.location
            TranscriptPerf.note(.composerSelectionWrite)
            TranscriptPerf.lastComposerSelectionAfterAssignment = clampedSelection.location

            isApplyingProgrammaticState = true
            defer { isApplyingProgrammaticState = false }

            textView.text = text
            textView.selectedRange = clampedSelection
            textView.setNeedsLayout()
            appliedProgrammaticRevision = revision
            lastTextReportedByUIKit = text
            // In the deferred flow the user's (now replaced) composition may
            // have published a newer binding AFTER the intentional source
            // wrote its value; the intentional replacement stays
            // authoritative, so the binding follows the editor.
            if parent.text != text { parent.text = text }
        }

        private func clampedSelectionRange(_ range: NSRange, maxLength: Int) -> NSRange {
            let location = min(max(range.location, 0), maxLength)
            let remaining = max(0, maxLength - location)
            let length = min(max(range.length, 0), remaining)
            return NSRange(location: location, length: length)
        }
    }
}

final class ImagePasteTextView: ReturnKeyTextView {
    var onPastedImage: ((PastedImage) -> Void)?
    var onPastedImageError: ((String) -> Void)?
    var onDroppedFiles: (([NSItemProvider]) -> Void)?
    var onContentHeightChange: ((CGFloat) -> Void)?
    var editorIdentity: UUID?
    var minimumReportedHeight: CGFloat = 44
    /// The Text Size and column the height bounds were last read at.
    var boundsContentSizeCategory: UIContentSizeCategory?
    var boundsColumnText: ColumnText?
    var maximumReportedHeight: CGFloat = 160
    private var lastReportedHeight: CGFloat = 0

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
        if onDroppedFiles != nil, AttachmentDrop.stagesAsFiles(itemProviders) {
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
        // Dropped files (Finder, Files) attach as picked files do; words
        // and links among them go into the text, and a lone image keeps
        // the image paste below.
        if let onDroppedFiles, AttachmentDrop.stagesAsFiles(itemProviders) {
            let files = AttachmentDrop.files(in: itemProviders)
            DispatchQueue.main.async { onDroppedFiles(files) }
            let words = itemProviders.filter { !AttachmentDrop.takes($0) }
            if !words.isEmpty { super.paste(itemProviders: words) }
            return
        }
        guard let provider = itemProviders.first(where: { canLoadImageProvider($0) }) else {
            // Words dropped or put here by a keyboard action stay words; a
            // long paste is the Paste command's (`paste(_:)`).
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
            self.onPastedImageError?(AppLocalization.string("The image provider returned invalid image data."))
        }
    }

    private func reportPastedImageTooLarge(_ url: URL, megabytes: Int, editorIdentity pasteEditorIdentity: UUID?) {
        let name = url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent
        let message = AttachmentSizeLimit.tooLargeMessage(names: [name], megabytes: megabytes)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.editorIdentity == pasteEditorIdentity else { return }
            self.onPastedImageError?(message)
        }
    }

    private func reportImageLoadFailure(
        _ error: Error?,
        editorIdentity pasteEditorIdentity: UUID? = nil
    ) {
        let pasteEditorIdentity = pasteEditorIdentity ?? editorIdentity
        let message = error.map { UserFacingError.message(for: $0) }
            ?? AppLocalization.string("Conduit couldn't read that image. Try copying it again.")
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
                // Streamed against the attachment limit: an endless or huge
                // answer is abandoned, not buffered whole.
                let megabytes = UserDefaults.standard.integer(forKey: AttachmentSizeLimit.preferenceKey)
                let limit = Int(AttachmentSizeLimit.byteLimit(megabytes: megabytes))
                Task { [weak self] in
                    switch await MediaPreviewPresenter.boundedDownloadResult(url, limit: limit) {
                    case .downloaded(let data, _):
                        guard let pastedImage = PastedRemoteImage.image(from: data) else {
                            self?.reportImageNormalizationFailure(editorIdentity: pasteEditorIdentity)
                            return
                        }
                        self?.deliverImageData(
                            pastedImage.data,
                            typeIdentifier: pastedImage.typeIdentifier,
                            editorIdentity: pasteEditorIdentity
                        )
                    case .tooLarge:
                        self?.reportPastedImageTooLarge(url, megabytes: megabytes, editorIdentity: pasteEditorIdentity)
                    case .failed:
                        self?.reportImageLoadFailure(nil, editorIdentity: pasteEditorIdentity)
                    }
                }
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
