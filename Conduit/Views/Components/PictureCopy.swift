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

enum PictureClipboard {
    /// The original's types that go on the clipboard as they are; any
    /// other (HEIC, WebP, TIFF) goes as a PNG, which every app pastes.
    static let keptTypes: [UTType] = [.png, .jpeg, .gif]

    /// What goes on the clipboard for a picture's bytes: the bytes under
    /// their own type when an app pastes that type everywhere, else a PNG
    /// made from them. Nil when the bytes aren't a picture.
    static func pasteboardItem(for data: Data, fileExtension: String) -> [String: Any]? {
        if let type = UTType(filenameExtension: fileExtension.lowercased()),
           let kept = keptTypes.first(where: { type.conforms(to: $0) }),
           UIImage(data: data) != nil {
            return [kept.identifier: data]
        }
        guard let png = UIImage(data: data)?.pngData() else { return nil }
        return [UTType.png.identifier: png]
    }

    /// Copies the picture `item` fetches, at full size, else `shown` (the
    /// row's own copy) when the original can't be had. Buzzes when neither
    /// can, and tells VoiceOver when it's copied.
    @MainActor
    static func copy(_ item: ImageGalleryItem?, shown: UIImage?) {
        Task { @MainActor in
            var pasted: [String: Any]?
            if let item, let file = await item.load().file {
                pasted = await Task.detached(priority: .userInitiated) { () -> [String: Any]? in
                    defer {
                        if let owned = file.ownedDirectory { try? FileManager.default.removeItem(at: owned) }
                    }
                    guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe) else { return nil }
                    return pasteboardItem(for: data, fileExtension: file.url.pathExtension)
                }.value
            }
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
                            UIPasteboard.general.string = description
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
