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
