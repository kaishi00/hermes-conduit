//
//  LiveVoicePhoto.swift
//  Conduit
//
//  A photo the user takes during a voice conversation (the call screen's
//  Camera). The photo itself waits on the conversation's chat, as Ask
//  Hermes About Screen's screenshot does, so the next request to Hermes
//  carries it. Gemini Live and Qwen Live also take a still picture on
//  their own socket: this makes the small copy they get.
//

import UIKit

enum LiveVoicePhotoFrame {
    /// Qwen refuses an image over 256 KB once Base64-encoded and asks for
    /// 720p, at most 1080p; Gemini takes the same frame. Kept under its
    /// raw-size advice, so one copy suits both.
    /// https://www.alibabacloud.com/help/en/model-studio/client-events
    static let maximumBytes = 190_000
    static let longestSides: [CGFloat] = [1280, 960, 640]
    static let qualities: [CGFloat] = [0.7, 0.5, 0.35]

    /// A JPEG of `image` that fits the providers' limits, or nil when even
    /// the smallest try doesn't.
    static func jpeg(from image: UIImage) -> Data? {
        for side in longestSides {
            guard let scaled = scaled(image, longestSide: side) else { return nil }
            for quality in qualities {
                if let data = scaled.jpegData(compressionQuality: quality), data.count <= maximumBytes {
                    return data
                }
            }
        }
        return nil
    }

    /// Drawn at one point per pixel, upright, no larger than it was.
    static func scaled(_ image: UIImage, longestSide: CGFloat) -> UIImage? {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longest = max(pixels.width, pixels.height)
        guard longest > 0 else { return nil }
        let factor = min(1, longestSide / longest)
        let size = CGSize(width: (pixels.width * factor).rounded(), height: (pixels.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
