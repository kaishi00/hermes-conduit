//
//  PictureCopy.swift
//  Conduit
//
//  Copy in a chat picture's long-press menu: the picture itself goes on the
//  clipboard, never its address.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

enum PictureClipboard {
    /// The original's types that go on the clipboard as they are; any
    /// other (HEIC, WebP, TIFF) goes as a PNG, which every app pastes.
    static let keptTypes: [UTType] = [.png, .jpeg, .gif]

    /// What goes on the clipboard for a picture's bytes: the bytes under
    /// their own type, read from the bytes themselves (a file's name can be
    /// missing or wrong), when an app pastes that type everywhere, else a
    /// PNG made from them. Nil when the bytes aren't a picture.
    static func pasteboardItem(for data: Data) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        if let identifier = CGImageSourceGetType(source) as String?,
           let type = UTType(identifier),
           let kept = keptTypes.first(where: { type.conforms(to: $0) }) {
            return [kept.identifier: data]
        }
        guard let png = UIImage(data: data)?.pngData() else { return nil }
        return [UTType.png.identifier: png]
    }

    /// Counts copies, so a slow fetch for an earlier one never replaces a
    /// later picture on the clipboard.
    @MainActor private static var latestCopy = 0

    /// Copies a picture's description. A picture copy still fetching then
    /// leaves the clipboard alone, as a later picture copy would.
    @MainActor
    static func copyDescription(_ text: String) {
        latestCopy += 1
        UIPasteboard.general.string = text
    }

    /// Copies the picture `item` fetches, at full size, else `shown` (the
    /// row's own copy) when the original can't be had. Buzzes when neither
    /// can, and tells VoiceOver when it's copied. Returns the copy's work,
    /// which tests wait on.
    @MainActor
    @discardableResult
    static func copy(_ item: ImageGalleryItem?, shown: UIImage?) -> Task<Void, Never> {
        latestCopy += 1
        let copyNumber = latestCopy
        return Task { @MainActor in
            var pasted: [String: Any]?
            if let item, let file = await item.load().file {
                // A later copy took the clipboard meanwhile: nothing to read.
                guard copyNumber == latestCopy else {
                    if let owned = file.ownedDirectory { try? FileManager.default.removeItem(at: owned) }
                    return
                }
                pasted = await Task.detached(priority: .userInitiated) { () -> [String: Any]? in
                    defer {
                        if let owned = file.ownedDirectory { try? FileManager.default.removeItem(at: owned) }
                    }
                    guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe) else { return nil }
                    return PictureClipboard.pasteboardItem(for: data)
                }.value
            }
            // A later copy took the clipboard meanwhile: nothing to encode.
            guard copyNumber == latestCopy else { return }
            if pasted == nil, let png = shown?.pngData() {
                pasted = [UTType.png.identifier: png]
            }
            guard let pasted else {
                Haptics.error()
                return
            }
            UIPasteboard.general.setItems([pasted])
            Haptics.light()
            UIAccessibility.post(notification: .announcement, argument: AppLocalization.string("Copied"))
        }
    }
}

/// A chat picture's long-press menu: Copy once the picture shows, and for a
/// picture from older history what Hermes' vision saw in it (#887), which
/// Hermes used to save in the message itself.
struct PictureMenu: ViewModifier {
    /// Copies the picture; nil while it loads or when it won't.
    var copy: (() -> Void)?
    var description: String? = nil

    func body(content: Content) -> some View {
        if copy != nil || description != nil {
            content
                .contextMenu {
                    if let copy {
                        Button(action: copy) {
                            Label(AppLocalization.string("Copy"), systemImage: "doc.on.doc")
                        }
                    }
                    if let description {
                        Section(AppLocalization.string("Description")) {
                            Text(description)
                        }
                        Button {
                            PictureClipboard.copyDescription(description)
                        } label: {
                            Label(AppLocalization.string("Copy Description"), systemImage: "text.quote")
                        }
                    }
                }
                .modifier(OptionalAccessibilityAction(name: AppLocalization.string("Copy"), action: copy))
        } else {
            content
        }
    }
}

/// VoiceOver's Copy action, where there's one.
private struct OptionalAccessibilityAction: ViewModifier {
    let name: String
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.accessibilityAction(named: Text(verbatim: name), action)
        } else {
            content
        }
    }
}
