//
//  BoundedRemoteImage.swift
//  Conduit
//
//  Web pictures shown in place — a reply's Markdown images, a web image's
//  Artifacts tile — load within bounds. The body streams against the same
//  ceiling as gateway media (`MediaPreviewPresenter.boundedDownload`), and
//  decoding downsamples to the size shown, refusing a picture whose header
//  alone claims more pixels than memory can hold: a few hundred KB of PNG
//  can claim 30,000 × 30,000, which decodes to gigabytes.
//

import ImageIO
import UIKit

enum BoundedRemoteImage {
    enum Outcome {
        case image(UIImage)
        /// Over the byte or pixel ceiling: offered as a link, never handed
        /// to the web view fallback, which would load it whole.
        case tooLarge
        /// The fetch failed or isn't a picture ImageIO reads: the web view
        /// fallback may still show it.
        case unavailable
    }

    /// Above a 48 MP camera photo, far below a decompression bomb.
    static let maxPixelCount = 64_000_000

    static func load(
        _ url: URL,
        maxPixelSize: CGFloat,
        download: (URL) async -> BoundedDownloadResult = { await MediaPreviewPresenter.boundedDownloadResult($0) }
    ) async -> Outcome {
        if let image = cachedImage(url, maxPixelSize: maxPixelSize) { return .image(image) }
        switch await download(url) {
        case .downloaded(let data, _):
            let outcome = decode(data, maxPixelSize: maxPixelSize)
            if case .image(let image) = outcome {
                let cost = Int(image.size.width * image.scale * image.size.height * image.scale) * 4
                cache.setObject(image, forKey: cacheKey(url, maxPixelSize), cost: cost)
            }
            return outcome
        case .tooLarge: return .tooLarge
        case .failed: return .unavailable
        }
    }

    /// A picture already loaded at this size: a row scrolled back into view
    /// shows it at once instead of downloading it again.
    static func cachedImage(_ url: URL, maxPixelSize: CGFloat) -> UIImage? {
        cache.object(forKey: cacheKey(url, maxPixelSize))
    }

    /// Downsampled pictures only, bounded by their decoded size.
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    private static func cacheKey(_ url: URL, _ maxPixelSize: CGFloat) -> NSString {
        NSString(string: "\(Int(maxPixelSize))\u{0}\(url.absoluteString)")
    }

    /// The picture downsampled to `maxPixelSize` on its longer side. The
    /// pixel count is read from the header before anything is decoded.
    static func decode(_ data: Data, maxPixelSize: CGFloat, maxPixelCount: Int = maxPixelCount) -> Outcome {
        // Nothing decoded is cached on the source: only the thumbnail is
        // kept (a flat PNG within the pixel ceiling still decodes to 256 MB).
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return .unavailable }
        guard width.multipliedReportingOverflow(by: height).partialValue <= maxPixelCount,
              width <= maxPixelCount / height else { return .tooLarge }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return .unavailable
        }
        return .image(UIImage(cgImage: thumbnail))
    }
}
