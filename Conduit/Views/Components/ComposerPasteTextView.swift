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

struct ComposerPasteTextView: UIViewRepresentable {
    static let minimumHeight: CGFloat = 44
    static let maximumHeight: CGFloat = 160

    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var measuredHeight: CGFloat
    let enabled: Bool
    let onPastedImage: (Data) -> Void
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
    var onPastedImage: ((Data) -> Void)?
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
            acceptableTypeIdentifiers: [UTType.text.identifier, UTType.image.identifier]
        )
    }

    private func imageTypeIdentifier(for provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { identifier in
            UTType(identifier)?.conforms(to: .image) == true
        }
    }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        if itemProviders.contains(where: { imageTypeIdentifier(for: $0) != nil }) {
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
        guard let provider = itemProviders.first(where: { imageTypeIdentifier(for: $0) != nil }),
              let imageType = imageTypeIdentifier(for: provider) else {
            super.paste(itemProviders: itemProviders)
            return
        }

        provider.loadDataRepresentation(forTypeIdentifier: imageType) { [weak self] data, error in
            guard let data, !data.isEmpty else {
                let message = error?.localizedDescription ?? "The image provider returned no data."
                DispatchQueue.main.async {
                    self?.onPastedImageError?(message)
                }
                return
            }
            DispatchQueue.main.async {
                self?.onPastedImage?(data)
            }
        }
    }

    override func paste(_ sender: Any?) {
        let pb = UIPasteboard.general

        // Direct image in pasteboard
        if let image = pb.image, let data = image.pngData() {
            onPastedImage?(data)
            return
        }

        // Image URL in pasteboard (common from Safari/Photos copy)
        if let url = pb.url, url.scheme?.hasPrefix("http") == true {
            let ext = url.pathExtension.lowercased()
            let imageExts = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "tiff"]
            if imageExts.contains(ext) || pb.types.contains("public.image") {
                URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                    guard let data = data else { return }
                    DispatchQueue.main.async { self?.onPastedImage?(data) }
                }.resume()
                return
            }
        }

        // Raw image data without .image property
        if let data = pb.data(forPasteboardType: "public.image"), !data.isEmpty {
            onPastedImage?(data)
            return
        }

        super.paste(sender)
    }
}
