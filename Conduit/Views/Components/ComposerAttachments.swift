//
//  ComposerAttachments.swift
//  Conduit
//
//  Naming, typing and size rules for files staged in the composer (#334),
//  plus the thumbnails its attachment strip shows. The policy enums are
//  pure so they stay unit-testable; ComposerBar owns when they run.
//

import AVFoundation
import CoreTransferable
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The largest file Conduit will stage for upload. Device-only preference,
/// like Hermes Desktop's: 16 MB by default, raisable up to what the Hermes
/// host accepts. Every upload is held in memory and base64-encoded before
/// it is sent, so a high limit can make the app freeze or be killed.
enum AttachmentSizeLimit {
    static let preferenceKey = "conduit.attachmentSizeLimitMB"
    static let defaultMegabytes = 16
    /// What the Hermes host accepts per upload.
    static let hostMaximumMegabytes = 256
    static let choices = [8, 16, 32, 64, 128, 256]

    static func clampedMegabytes(_ value: Int) -> Int {
        guard value > 0 else { return defaultMegabytes }
        return min(value, hostMaximumMegabytes)
    }

    static func byteLimit(megabytes: Int) -> Int64 {
        Int64(clampedMegabytes(megabytes)) * 1024 * 1024
    }

    static func allows(byteCount: Int64, megabytes: Int) -> Bool {
        byteCount <= byteLimit(megabytes: megabytes)
    }

    /// Above Desktop's default the settings screen warns about memory.
    static func isRisky(megabytes: Int) -> Bool {
        clampedMegabytes(megabytes) > defaultMegabytes
    }

    static func formattedSize(_ byteCount: Int64) -> String {
        // Binary, like the limit, so a file at exactly 16 MB reads "16 MB".
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .binary)
    }

    static func tooLargeMessage(names: [String], megabytes: Int) -> String {
        let limit = String(clampedMegabytes(megabytes))
        if names.count == 1, let name = names.first {
            return AppLocalization.string("\(name) is larger than the \(limit) MB attachment limit. You can raise the limit in Settings › Chat.")
        }
        let list = names.joined(separator: ", ")
        return AppLocalization.string("These files are larger than the \(limit) MB attachment limit: \(list). You can raise the limit in Settings › Chat.")
    }

    static func fileSize(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize { return Int64(size) }
        return nil
    }
}

/// How a picked or imported file is named, typed and sent.
enum AttachmentTypePolicy {
    /// Image formats every model provider reads. Anything else (HEIC, TIFF,
    /// RAW...) is re-encoded as JPEG before it is staged.
    static let providerImageTypes: [UTType] = [.jpeg, .png, .gif, .webP]

    static func kind(for type: UTType?) -> Attachment.Kind {
        guard let type else { return .document }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .image) { return .image }
        return .document
    }

    static func needsJPEGTranscode(_ type: UTType?) -> Bool {
        guard let type, type.conforms(to: .image) else { return false }
        return !providerImageTypes.contains { type.conforms(to: $0) }
    }

    static func mimeType(for type: UTType?) -> String {
        guard let mime = type?.preferredMIMEType, !mime.contains("/*") else {
            return "application/octet-stream"
        }
        return mime
    }

    /// The real file name when the system gave one, with an extension that
    /// matches the content; otherwise "photo"/"video"/"file" plus one.
    static func filename(suggested: String?, type: UTType?, ordinal: Int = 1) -> String {
        let trimmed = (suggested ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredExtension = type?.preferredFilenameExtension
        if !trimmed.isEmpty {
            let currentExtension = (trimmed as NSString).pathExtension
            guard currentExtension.isEmpty, let preferredExtension else { return trimmed }
            return "\(trimmed).\(preferredExtension)"
        }
        let stem: String
        switch kind(for: type) {
        case .image: stem = "photo"
        case .video: stem = "video"
        case .document: stem = "file"
        }
        let numbered = ordinal > 1 ? "\(stem)-\(ordinal)" : stem
        guard let preferredExtension else { return numbered }
        return "\(numbered).\(preferredExtension)"
    }

    static func jpegFilename(for name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        return "\(stem.isEmpty ? "photo" : stem).jpg"
    }

    /// Short label under the name in the composer strip, e.g. "MP4 · 21 MB".
    static func detailLabel(for attachment: Attachment, byteCount: Int64?) -> String {
        let pathExtension = (attachment.name as NSString).pathExtension.uppercased()
        let typeLabel: String
        if !pathExtension.isEmpty {
            typeLabel = pathExtension
        } else {
            switch attachment.kind {
            case .image: typeLabel = AppLocalization.string("Image")
            case .video: typeLabel = AppLocalization.string("Video")
            case .document: typeLabel = AppLocalization.string("File")
            }
        }
        guard let byteCount else { return typeLabel }
        return "\(typeLabel) · \(AttachmentSizeLimit.formattedSize(byteCount))"
    }

    static func symbolName(for attachment: Attachment) -> String {
        switch attachment.kind {
        case .image: return "photo"
        case .video: return "film"
        case .document:
            return attachment.name.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc"
        }
    }
}

/// The staging folder the composer copies attachments into until they
/// are sent.
enum AttachmentStaging {
    static var directory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Hermes-Conduit-Attachments", isDirectory: true)
    }

    static func destination(for name: String) throws -> URL {
        let folder = directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeName = name.replacingOccurrences(of: "/", with: "_")
        return folder.appendingPathComponent("\(UUID().uuidString)-\(safeName)")
    }

    /// Re-encodes an image file as JPEG through ImageIO, keeping its
    /// metadata (orientation included) without decoding it into a UIImage.
    static func writeJPEG(from source: URL, to destination: URL) -> Bool {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let target = CGImageDestinationCreateWithURL(
                destination as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              ) else { return false }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        CGImageDestinationAddImageFromSource(target, imageSource, 0, options)
        guard CGImageDestinationFinalize(target) else {
            try? FileManager.default.removeItem(at: destination)
            return false
        }
        return true
    }

    /// The image format the file's bytes actually hold, if it is an image.
    static func imageType(at url: URL) -> UTType? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let identifier = CGImageSourceGetType(source) else { return nil }
        return UTType(identifier as String)
    }

    /// Staged files outlive their drafts (the sent bubble previews from
    /// them), so old ones are cleared at launch. Drafts live only in
    /// memory, so nothing from a previous launch still needs them.
    static func sweepStaleFiles(olderThan age: TimeInterval = 3 * 24 * 60 * 60, now: Date = Date()) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > age {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}

/// A photo-library item received as a file, so the original name and type
/// survive and a large video is never loaded into memory just to stage it.
struct PickedMediaFile: Transferable {
    let url: URL
    let originalName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try stage(received.file)
        }
        FileRepresentation(importedContentType: .image) { received in
            try stage(received.file)
        }
    }

    private static func stage(_ file: URL) throws -> PickedMediaFile {
        let name = file.lastPathComponent
        let destination = try AttachmentStaging.destination(for: name)
        try FileManager.default.copyItem(at: file, to: destination)
        return PickedMediaFile(url: destination, originalName: name)
    }
}

/// Small previews for the composer strip: the image itself, or a video's
/// first frame. Cached by file URL so re-renders don't decode again.
enum AttachmentThumbnailLoader {
    private static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 60
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    static func cachedThumbnail(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    static func thumbnail(for attachment: Attachment, maxPixelSize: CGFloat) async -> UIImage? {
        guard attachment.kind != .document,
              let url = URL(string: attachment.uri), url.isFileURL else { return nil }
        if let cached = cachedThumbnail(for: url) { return cached }
        let image: UIImage?
        if attachment.kind == .video {
            image = await videoFrame(at: url, maxPixelSize: maxPixelSize)
        } else {
            image = await Task.detached(priority: .utility) {
                downsampledImage(at: url, maxPixelSize: maxPixelSize)
            }.value
        }
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            cache.setObject(image, forKey: url as NSURL, cost: cost)
        }
        return image
    }

    private static func downsampledImage(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func videoFrame(at url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        // A moment in, so a clip that fades in from black still shows
        // something; the very first frame is the fallback.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let early = CMTime(seconds: 0.1, preferredTimescale: 600)
        if let frame = try? await generator.image(at: early) {
            return UIImage(cgImage: frame.image)
        }
        guard let frame = try? await generator.image(at: .zero) else { return nil }
        return UIImage(cgImage: frame.image)
    }
}

/// One staged attachment in the composer strip: a thumbnail (or type
/// icon), the real file name, and its type and size.
struct ComposerAttachmentChip: View {
    let attachment: Attachment
    let canRemove: Bool
    let onRemove: () -> Void

    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var thumbnail: UIImage?
    @State private var byteCount: Int64?

    private static let thumbnailSide: CGFloat = 40

    var body: some View {
        HStack(spacing: 8) {
            preview
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .truncationMode(.middle)
                Text(AttachmentTypePolicy.detailLabel(for: attachment, byteCount: byteCount))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 220 : 140, alignment: .leading)
            Button {
                Haptics.light()
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    // A full-size tap target without growing the chip.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .padding(.vertical, -10)
                    .padding(.horizontal, -12)
            }
            .buttonStyle(.plain)
            .disabled(!canRemove)
            .accessibilityLabel(AppLocalization.string("Remove \(attachment.name)"))
        }
        .padding(.leading, 5)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        // A plain fill, not glass: glass inside the composer's
        // GlassEffectContainer is drawn by the container and escaped the
        // strip's scroll clipping (#334).
        .background(Color.conduitAccent.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .task(id: attachment.uri) {
            if let url = URL(string: attachment.uri), url.isFileURL {
                byteCount = AttachmentSizeLimit.fileSize(at: url)
            }
            thumbnail = await AttachmentThumbnailLoader.thumbnail(
                for: attachment,
                maxPixelSize: Self.thumbnailSide * displayScale
            )
        }
    }

    private var preview: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.primary.opacity(0.06)
                Image(systemName: AttachmentTypePolicy.symbolName(for: attachment))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if attachment.kind == .video, thumbnail != nil {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
            }
        }
        .frame(width: Self.thumbnailSide, height: Self.thumbnailSide)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityHidden(true)
    }
}
