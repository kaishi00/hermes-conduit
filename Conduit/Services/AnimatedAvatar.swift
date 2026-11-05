//
//  AnimatedAvatar.swift
//  Conduit
//
//  Moving bot and profile pictures (Eric 2026-11-05). Hermes' asset store
//  takes PNG, JPEG or WebP up to 2 MB and tells them apart by their bytes,
//  so an animated PNG (APNG) is stored and synced like any other picture,
//  and Hermes Desktop's <img> plays it. A GIF, animated picture or short
//  video picked with Choose GIF or Video (the Photos picker, which hands
//  over the original file; Choose Photo's crop flattens a GIF to one frame)
//  becomes a looping square APNG here. Wherever a picture is
//  drawn still, ImageIO hands over its first frame, so nothing else changes.
//

import AVFoundation
import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum AnimatedAvatar {
    /// What a picked animation is read from.
    enum Source: Equatable {
        /// A GIF, APNG, animated WebP or HEIC sequence.
        case image(URL)
        case movie(URL)
    }

    enum Failure: Error, Equatable {
        case unreadable
        /// Even the smallest size is over `maxBytes`.
        case tooLarge
    }

    struct Frame {
        let image: CGImage
        /// Seconds this frame shows.
        let delay: Double
    }

    /// Under Hermes' 2 MB cap, with room for the base64 every fetch sends.
    static let maxBytes = 1_500_000
    /// The first seconds of a longer clip; the picker trims videos to it.
    static let maxDuration: TimeInterval = 3
    static let videoFramesPerSecond: Double = 10
    static let maxFrames = 36
    /// Frames are read no larger than this before they're squared.
    static let readPixelSize: CGFloat = 512
    /// Edge and frame count, tried in order until the picture fits
    /// `maxBytes`: a smaller face before fewer frames, so it stays smooth.
    static let attempts: [(edge: CGFloat, frameLimit: Int)] = [
        (256, maxFrames), (192, maxFrames), (160, maxFrames),
        (192, maxFrames / 2), (160, maxFrames / 2), (128, maxFrames / 2)
    ]
    /// Browsers and ImageIO treat a shorter delay as a broken file and show
    /// it at 10 fps; so does this.
    static let minimumDelay: Double = 0.02
    static let defaultDelay: Double = 0.1

    // MARK: Reading

    static func isAnimated(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    static func isAnimated(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    /// The looping APNG to store for a picked animation.
    static func picture(from source: Source) async -> Result<Data, Failure> {
        let frames: [Frame]?
        switch source {
        case .image(let url): frames = Self.frames(fromImageAt: url)
        case .movie(let url): frames = await Self.frames(fromMovieAt: url)
        }
        guard let frames, frames.count > 1 else { return .failure(.unreadable) }
        return encode(frames)
    }

    /// `picture(from:)` for a picker's copy, which it deletes after. Nil is
    /// a pick the picker couldn't copy.
    static func picture(fromPicked source: Source?) async -> Result<Data, Failure> {
        guard let source else { return .failure(.unreadable) }
        let result = await picture(from: source)
        switch source {
        case .image(let url), .movie(let url): try? FileManager.default.removeItem(at: url)
        }
        return result
    }

    /// What the editor says when a picked animation can't be used.
    static func message(for failure: Failure) -> String {
        switch failure {
        case .unreadable: return AppLocalization.string("That picture could not be used.")
        case .tooLarge: return AppLocalization.string("That animation is too large. Try a shorter or simpler clip.")
        }
    }

    /// An animated picture's frames, up to `maxDuration`. Nil for a still
    /// or an unreadable file.
    static func frames(fromImageAt url: URL) -> [Frame]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return frames(from: source)
    }

    static func frames(from data: Data) -> [Frame]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return frames(from: source)
    }

    private static func frames(from source: CGImageSource) -> [Frame]? {
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: readPixelSize
        ]
        var frames: [Frame] = []
        var elapsed: Double = 0
        for index in 0..<count where elapsed < maxDuration {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { continue }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            let delay = frameDelay(properties)
            frames.append(Frame(image: image, delay: delay))
            elapsed += delay
        }
        return frames.count > 1 ? frames : nil
    }

    /// A frame's delay from whichever format's dictionary it has.
    static func frameDelay(_ properties: [CFString: Any]) -> Double {
        let keys: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime)
        ]
        for (dictionaryKey, unclamped, clamped) in keys {
            guard let dictionary = properties[dictionaryKey] as? [CFString: Any] else { continue }
            let value = (dictionary[unclamped] as? Double) ?? (dictionary[clamped] as? Double)
            guard let value else { continue }
            return value < minimumDelay ? defaultDelay : value
        }
        return defaultDelay
    }

    /// A video's first `maxDuration` seconds at `videoFramesPerSecond`.
    static func frames(fromMovieAt url: URL) async -> [Frame]? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 else { return nil }
        let length = min(duration, maxDuration)
        let count = max(2, Int(length * videoFramesPerSecond))
        let delay = length / Double(count)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: readPixelSize, height: readPixelSize)
        let tolerance = CMTime(seconds: delay / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var frames: [Frame] = []
        for index in 0..<count {
            let time = CMTime(seconds: Double(index) * delay, preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image else { continue }
            frames.append(Frame(image: image, delay: delay))
        }
        return frames.count > 1 ? frames : nil
    }

    // MARK: Writing

    /// The largest attempt that fits `maxBytes`.
    static func encode(_ frames: [Frame]) -> Result<Data, Failure> {
        var encodedAny = false
        for attempt in attempts {
            guard let data = apng(thinned(frames, to: attempt.frameLimit), edge: attempt.edge) else { continue }
            encodedAny = true
            if data.count <= maxBytes { return .success(data) }
        }
        return .failure(encodedAny ? .tooLarge : .unreadable)
    }

    /// At most `limit` frames: each kept frame takes the time of the ones
    /// dropped after it, so the loop keeps its length.
    static func thinned(_ frames: [Frame], to limit: Int) -> [Frame] {
        guard limit > 0, frames.count > limit else { return frames }
        let step = Int((Double(frames.count) / Double(limit)).rounded(.up))
        return stride(from: 0, to: frames.count, by: step).map { start in
            let group = frames[start..<min(start + step, frames.count)]
            return Frame(image: group.first!.image, delay: group.reduce(0) { $0 + $1.delay })
        }
    }

    /// A looping APNG of the frames, each center-cropped to an `edge` square.
    static func apng(_ frames: [Frame], edge: CGFloat) -> Data? {
        let data = NSMutableData()
        guard frames.count > 1,
              let destination = CGImageDestinationCreateWithData(
                data as CFMutableData, UTType.png.identifier as CFString, frames.count, nil
              ) else { return nil }
        let loop: [CFString: Any] = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]]
        CGImageDestinationSetProperties(destination, loop as CFDictionary)
        for frame in frames {
            guard let square = squared(frame.image, edge: Int(edge)) else { return nil }
            let properties: [CFString: Any] = [
                kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: frame.delay]
            ]
            CGImageDestinationAddImage(destination, square, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Center-crops to a square and scales to `edge`, as stills are
    /// (BotAvatarImage.normalizedPNG), keeping transparency.
    static func squared(_ image: CGImage, edge: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard width > 0, height > 0 else { return nil }
        let scale = CGFloat(edge) / min(width, height)
        let size = CGSize(width: width * scale, height: height * scale)
        let origin = CGPoint(x: (CGFloat(edge) - size.width) / 2, y: (CGFloat(edge) - size.height) / 2)
        context.draw(image, in: CGRect(origin: origin, size: size))
        return context.makeImage()
    }

    // MARK: Picking

    /// What Choose GIF or Video handed over.
    enum Pick {
        /// A video or moving picture, as a file `picture(fromPicked:)` deletes.
        case animation(Source)
        /// A still picked there, used as any photo.
        case still(UIImage)
        case unreadable
    }

    /// A Photos pick, read from its original file so a GIF keeps its frames.
    static func pick(from item: PhotosPickerItem) async -> Pick {
        if let file = try? await item.loadTransferable(type: PickedMediaFile.self) {
            return pick(fileAt: file.url)
        }
        // Some pictures only hand over their bytes; a video never takes
        // this path, which would hold all of it in memory.
        guard item.supportedContentTypes.first?.conforms(to: .image) == true,
              let data = try? await item.loadTransferable(type: Data.self) else { return .unreadable }
        return pick(data: data)
    }

    /// A picked file: a video or moving picture is kept for
    /// `picture(fromPicked:)`, a still is read and its file deleted.
    static func pick(fileAt url: URL) -> Pick {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .audiovisualContent) == true {
            return .animation(.movie(url))
        }
        if isAnimated(at: url) { return .animation(.image(url)) }
        // A file whose name doesn't say what it is: one ImageIO can't read
        // as a picture goes to the video reader, never read whole here.
        guard AttachmentStaging.imageType(at: url) != nil else { return .animation(.movie(url)) }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        return pick(data: data)
    }

    /// Picked bytes: a moving picture is written to a file of its own.
    static func pick(data: Data) -> Pick {
        if isAnimated(data) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("avatar-\(UUID().uuidString)", isDirectory: false)
            guard (try? data.write(to: url, options: .atomic)) != nil else { return .unreadable }
            return .animation(.image(url))
        }
        guard let image = UIImage(data: data) else { return .unreadable }
        return .still(image)
    }
}
