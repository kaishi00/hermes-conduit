//
//  ProviderPicture.swift
//  Conduit
//
//  A picture another app hands over as an image object rather than a file
//  (the screenshot editor's Share, a paste, a drag): read as a UIImage and
//  written as PNG. Shared by the share sheet, the composer's paste and a
//  drop on a chat (issue 1747).
//

import Foundation
import UIKit

enum ProviderPicture {
    /// Reads a provider's picture as a `UIImage`, with the reason when it
    /// can't.
    static func loadImage(_ provider: NSItemProvider) async -> (image: UIImage?, error: Error?) {
        guard provider.canLoadObject(ofClass: UIImage.self) else { return (nil, nil) }
        return await withCheckedContinuation { continuation in
            // The explicit closure type picks the NSItemProviderReading
            // overload (see ComposerPasteTextView's image paste).
            _ = provider.loadObject(ofClass: UIImage.self) { (object: NSItemProviderReading?, error: Error?) in
                continuation.resume(returning: (object as? UIImage, error))
            }
        }
    }

    /// The image as PNG. One with no bitmap of its own (drawn from a
    /// `CIImage`, say) has no `pngData()`, so it is drawn once and that is
    /// encoded.
    static func pngData(_ image: UIImage) -> Data? {
        if let data = image.pngData(), !data.isEmpty { return data }
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        let data = UIGraphicsImageRenderer(size: image.size, format: format).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return data.isEmpty ? nil : data
    }
}
