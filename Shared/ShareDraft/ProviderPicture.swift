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
import ImageIO
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

    /// The largest bitmap a redraw may allocate, as for a remote picture
    /// (BoundedRemoteImage): a huge image is refused, not drawn, so the
    /// share extension isn't ended for its memory.
    static let maximumRedrawPixels: CGFloat = 64_000_000

    /// The image as PNG. One with no bitmap of its own (drawn from a
    /// `CIImage`, say) has no `pngData()`, so it is drawn once and that is
    /// encoded.
    static func pngData(_ image: UIImage) -> Data? {
        if let data = image.pngData(), !data.isEmpty { return data }
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        guard pixels.isFinite, pixels <= maximumRedrawPixels else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        let data = UIGraphicsImageRenderer(size: image.size, format: format).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return data.isEmpty ? nil : data
    }

    /// Whether bytes handed over as a picture decode as one. The pixel
    /// count is read from the header first, as for a remote picture
    /// (BoundedRemoteImage): one over `maximumRedrawPixels` is refused
    /// unread, and the first frame is proved with a small thumbnail, so a
    /// small file claiming a huge picture never decodes at full size.
    static func decodes(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0, width * height <= Double(maximumRedrawPixels) else { return false }
        // A source and a frame count can still hold a frame that won't
        // decode (a corrupt HEIC); only a first image proves it.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
    }
}
