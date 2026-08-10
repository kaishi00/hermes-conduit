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
        view.onContentHeightChange = { height in
            context.coordinator.updateMeasuredHeight(height)
        }
        view.onPastedImage = onPastedImage
        view.onPastedImageError = onPastedImageError
        return view
    }

    func updateUIView(_ uiView: ImagePasteTextView, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text { uiView.text = text }
        uiView.isEditable = enabled
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

        init(_ parent: ComposerPasteTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            textView.scrollRangeToVisible(textView.selectedRange)
            textView.setNeedsLayout()
        }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.isFocused = true }
        func textViewDidEndEditing(_ textView: UITextView) { parent.isFocused = false }

        func updateMeasuredHeight(_ height: CGFloat) {
            guard abs(parent.measuredHeight - height) > 0.5 else { return }
            parent.measuredHeight = height
        }
    }
}

final class ImagePasteTextView: UITextView {
    var onPastedImage: ((PastedImage) -> Void)?
    var onPastedImageError: ((String) -> Void)?
    var onContentHeightChange: ((CGFloat) -> Void)?
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

        if let imageType = imageTypeIdentifier(for: provider) {
            provider.loadDataRepresentation(forTypeIdentifier: imageType) { [weak self] data, error in
                guard let data, !data.isEmpty else {
                    if provider.canLoadObject(ofClass: UIImage.self) {
                        self?.loadImageObject(from: provider, fallbackError: error)
                    } else {
                        self?.reportImageLoadFailure(error)
                    }
                    return
                }
                self?.deliverImageData(data, typeIdentifier: imageType)
            }
            return
        }

        loadImageObject(from: provider)
    }

    private func loadImageObject(from provider: NSItemProvider, fallbackError: Error? = nil) {
        // Spell out the protocol existential so Swift selects the
        // NSItemProviderReading overload. The inferred generic overload on
        // newer SDKs expects UIImage to be _ObjectiveCBridgeable and fails
        // during compilation even though UIImage supports this API.
        provider.loadObject(ofClass: UIImage.self) { [weak self] (object: NSItemProviderReading?, error: Error?) in
            guard let image = object as? UIImage,
                  let data = image.pngData(),
                  !data.isEmpty else {
                self?.reportImageLoadFailure(error ?? fallbackError)
                return
            }
            self?.deliverImageData(data, typeIdentifier: UTType.png.identifier)
        }
    }

    private func deliverImageData(_ data: Data, typeIdentifier: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onPastedImage?(PastedImage(data: data, typeIdentifier: typeIdentifier))
        }
    }

    private func reportImageLoadFailure(_ error: Error?) {
        let message = error?.localizedDescription ?? "The image provider returned no data."
        DispatchQueue.main.async { [weak self] in
            self?.onPastedImageError?(message)
        }
    }

    override func paste(_ sender: Any?) {
        let pb = UIPasteboard.general

        // Direct image in pasteboard
        if let image = pb.image, let data = image.pngData() {
            onPastedImage?(PastedImage(data: data, typeIdentifier: UTType.png.identifier))
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
                    DispatchQueue.main.async {
                        self?.onPastedImage?(PastedImage(data: data, typeIdentifier: typeIdentifier))
                    }
                }.resume()
                return
            }
        }

        // Raw image data without .image property
        if let data = pb.data(forPasteboardType: "public.image"), !data.isEmpty {
            onPastedImage?(PastedImage(data: data, typeIdentifier: UTType.image.identifier))
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
