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
            return AppLocalization.string("\(name) is larger than the \(limit) MB attachment limit. You can raise the limit in Settings › Chat.", table: .chat)
        }
        let list = names.joined(separator: ", ")
        return AppLocalization.string("These files are larger than the \(limit) MB attachment limit: \(list). You can raise the limit in Settings › Chat.", table: .chat)
    }

    /// A recorded voice message over the limit: its size and where to raise it.
    static func voiceTooLargeMessage(megabytes: Int) -> String {
        let limit = String(clampedMegabytes(megabytes))
        return AppLocalization.string("This voice message is larger than the \(limit) MB attachment limit. You can raise the limit in Settings › Chat.", table: .chat)
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

    /// The name a staged file is previewed under when its path doesn't say
    /// its type, since Quick Look picks its renderer by the extension; nil
    /// when the staged copy can be shown in place. A screenshot is staged
    /// without its extension, and a stem ending in a dotted time ("… at
    /// 10.00.37") reads as having one, so the path's extension is checked
    /// against the attachment's type, not against its name (desktop#611).
    static func stagedPreviewName(name: String, fileURL: URL, mimeType: String?) -> String? {
        guard let mimeType, let type = UTType(mimeType: mimeType), type != .data,
              let preferredExtension = type.preferredFilenameExtension else { return nil }
        if UTType(filenameExtension: fileURL.pathExtension)?.conforms(to: type) == true { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = trimmed.isEmpty ? "file" : trimmed
        if UTType(filenameExtension: (stem as NSString).pathExtension)?.conforms(to: type) == true { return stem }
        return "\(stem).\(preferredExtension)"
    }

    /// The real file name when the system gave one, with an extension that
    /// matches the content; otherwise "photo"/"video"/"file" plus one.
    static func filename(suggested: String?, type: UTType?, ordinal: Int = 1) -> String {
        var trimmed = Substring((suggested ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        // "Apple." has no extension, and would become "Apple..png" (#3366).
        while trimmed.last == "." { trimmed.removeLast() }
        let preferredExtension = type?.preferredFilenameExtension
        if !trimmed.isEmpty {
            let trimmed = String(trimmed)
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

    /// A picture's name with an extension that says what its bytes are.
    /// Hermes stages a picture under its name's extension, so a page title
    /// like "Event 8.30", a screenshot's dotted time, or "flyer.jpg" holding
    /// a PNG reached the model as an unknown format and never drew in the
    /// sent message (issue 3331). A wrong picture extension is replaced; any
    /// other ending ("30", "com") stays part of the name, and the type's
    /// extension is added. Only pictures: they are the files Hermes types
    /// by their name.
    static func pictureFilename(_ name: String, type: UTType?) -> String {
        guard let type, type.conforms(to: .image), let preferred = type.preferredFilenameExtension else { return name }
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty, UTType(filenameExtension: ext)?.conforms(to: type) == true { return name }
        return pictureFilename(name, withExtension: preferred)
    }

    /// `name` with the picture extension `ext`: a picture extension it has
    /// is replaced, any other ending ("30", "com") stays part of the name,
    /// and trailing dots go (issue 3331).
    static func pictureFilename(_ name: String, withExtension ext: String) -> String {
        var trimmed = Substring(name)
        while trimmed.last == "." { trimmed.removeLast() }
        let current = (String(trimmed) as NSString).pathExtension.lowercased()
        let isPicture = !current.isEmpty && UTType(filenameExtension: current)?.conforms(to: .image) == true
        let stem = isPicture ? (String(trimmed) as NSString).deletingPathExtension : String(trimmed)
        return "\(stem.isEmpty ? "photo" : stem).\(ext)"
    }

    static func jpegFilename(for name: String) -> String {
        pictureFilename(name, withExtension: "jpg")
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
            case .video: typeLabel = AppLocalization.string("Video", table: .chat)
            case .document: typeLabel = AppLocalization.string("File", table: .chat)
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
            if PastedText.isPastedText(attachment) { return "doc.plaintext" }
            return attachment.name.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc"
        }
    }

    /// What a file is called on screen: a long paste reads "Pasted text",
    /// not its generated file name.
    static func displayName(for attachment: Attachment) -> String {
        PastedText.isPastedText(attachment) ? PastedText.displayName : attachment.name
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

    /// What became of one file the composer tried to stage.
    enum StagedImport {
        case staged(Attachment)
        case tooLarge(String)
        case failed(String)
    }

    /// Copies a file the user picked or dropped into the staging folder,
    /// size checked before anything is copied, then finished like the rest.
    static func stageCopy(of url: URL, name: String, type: UTType?, limitMegabytes: Int) -> StagedImport {
        if let size = AttachmentSizeLimit.fileSize(at: url),
           !AttachmentSizeLimit.allows(byteCount: size, megabytes: limitMegabytes) {
            return .tooLarge(name)
        }
        do {
            let staged = try destination(for: name)
            try FileManager.default.copyItem(at: url, to: staged)
            return finishStaging(fileAt: staged, name: name, type: type, limitMegabytes: limitMegabytes)
        } catch {
            return .failed(name)
        }
    }

    /// The composer's rules for a file already copied into the staging
    /// folder: the size limit, checked before anything is decoded, a JPEG
    /// re-encode for image formats providers can't read, a picture's name
    /// typed by its bytes, and a "picture" nothing can read sent as a file.
    static func finishStaging(fileAt url: URL, name: String, type: UTType?, limitMegabytes: Int) -> StagedImport {
        var url = url
        var name = name
        var type = type
        // Checked on the original first, so an oversized file is never
        // decoded; a re-encoded image is checked again below.
        if let size = AttachmentSizeLimit.fileSize(at: url),
           !AttachmentSizeLimit.allows(byteCount: size, megabytes: limitMegabytes) {
            try? FileManager.default.removeItem(at: url)
            return .tooLarge(name)
        }
        // The bytes decide, not the extension: a HEIC named .png still
        // gets re-encoded. Only formats ImageIO reads are re-encoded; an
        // SVG goes as a file (below).
        var sniffed: UTType?
        if type == nil || type?.conforms(to: .image) == true {
            sniffed = imageType(at: url)
            if let sniffed { type = sniffed }
        }
        if sniffed != nil, AttachmentTypePolicy.needsJPEGTranscode(type) {
            let jpegName = AttachmentTypePolicy.jpegFilename(for: name)
            guard let jpegURL = try? destination(for: jpegName),
                  writeJPEG(from: url, to: jpegURL) else {
                try? FileManager.default.removeItem(at: url)
                return .failed(name)
            }
            try? FileManager.default.removeItem(at: url)
            url = jpegURL
            name = jpegName
            type = .jpeg
        }
        var kind = AttachmentTypePolicy.kind(for: type)
        if kind == .image, sniffed == nil {
            // A picture no format reader takes (an SVG, bytes that aren't a
            // picture at all) goes as a file: sent as an image, a provider
            // refuses the whole message (issue 3331).
            kind = .document
        } else if kind == .image {
            let typedName = AttachmentTypePolicy.pictureFilename(name, type: type)
            if typedName != name {
                name = typedName
                // The staged copy's path says its type too.
                if let renamed = try? destination(for: typedName),
                   (try? FileManager.default.moveItem(at: url, to: renamed)) != nil {
                    url = renamed
                }
            }
        }
        let size = AttachmentSizeLimit.fileSize(at: url)
        if size == 0 {
            try? FileManager.default.removeItem(at: url)
            return .failed(name)
        }
        if let size, !AttachmentSizeLimit.allows(byteCount: size, megabytes: limitMegabytes) {
            try? FileManager.default.removeItem(at: url)
            return .tooLarge(name)
        }
        return .staged(Attachment(
            id: UUID().uuidString,
            name: name,
            uri: url.absoluteString,
            mimeType: AttachmentTypePolicy.mimeType(for: type),
            kind: kind
        ))
    }

    /// An image handed to the Ask Hermes About Screen action, staged like
    /// a picked photo. A screenshot is a PNG, so it goes up as captured and
    /// its text stays sharp; anything that isn't an image is refused.
    static func stageScreenshot(data: Data, filename: String?, limitMegabytes: Int) -> StagedImport {
        let suggested = (filename ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = (suggested as NSString).deletingPathExtension
        let baseName = stem.isEmpty ? "Screenshot" : stem
        guard AttachmentSizeLimit.allows(byteCount: Int64(data.count), megabytes: limitMegabytes) else {
            return .tooLarge(baseName)
        }
        guard !data.isEmpty,
              let url = try? destination(for: baseName),
              (try? data.write(to: url, options: .atomic)) != nil else {
            return .failed(baseName)
        }
        guard let type = imageType(at: url) else {
            try? FileManager.default.removeItem(at: url)
            return .failed(baseName)
        }
        let name = AttachmentTypePolicy.filename(suggested: baseName, type: type)
        return finishStaging(fileAt: url, name: name, type: type, limitMegabytes: limitMegabytes)
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
    /// What a long paste's sheet may do (`PastedTextSheet`). Only a pasted
    /// text's chip opens one; nil shows the paste read-only.
    var pastedText: PastedTextActions? = nil
    let onRemove: () -> Void

    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var thumbnail: UIImage?
    @State private var byteCount: Int64?
    @State private var pastedPreview: String?
    @State private var isShowingPastedText = false
    /// A preview still reading its copy; cancelled when the chip goes, so
    /// a late read never opens Quick Look over another screen.
    @State private var previewTask: Task<Void, Never>?

    private static let thumbnailSide: CGFloat = 40

    private var isPastedText: Bool { PastedText.isPastedText(attachment) }

    /// The staged copy a tap previews; nil when the attachment isn't a file
    /// on this device, or its copy is gone, so the chip isn't tappable.
    private var stagedFileURL: URL? {
        guard let url = URL(string: attachment.uri), url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Opens the staged copy in Quick Look. A copy whose path doesn't say
    /// its type is shown from a copy under a name that does
    /// (`AttachmentTypePolicy.stagedPreviewName`); the presenter removes that
    /// copy when the preview closes.
    private func previewStagedFile(at url: URL) {
        guard let filename = AttachmentTypePolicy.stagedPreviewName(
            name: attachment.name, fileURL: url, mimeType: attachment.mimeType
        ) else {
            if !MediaPreviewPresenter.shared.present(fileURL: url, title: AttachmentTypePolicy.displayName(for: attachment)) {
                Haptics.error()
            }
            return
        }
        previewTask?.cancel()
        previewTask = Task {
            let data = await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: url, options: .mappedIfSafe)
            }.value
            guard let data, !Task.isCancelled,
                  await MediaPreviewPresenter.shared.present(data: data, filename: filename) else {
                if !Task.isCancelled { Haptics.error() }
                return
            }
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if isPastedText {
                Button {
                    Haptics.selection()
                    isShowingPastedText = true
                } label: {
                    summary
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(PastedText.displayName))
                .accessibilityValue(Text(pastedPreview ?? ""))
                .accessibilityHint(Text(AppLocalization.string("Shows the pasted text", table: .chat)))
                .accessibilityIdentifier("composer.pastedText.chip")
            } else if let stagedFileURL {
                // A tap previews the staged file to check it before it's
                // sent, in Quick Look as a sent file opens (desktop#611):
                // pictures, PDFs, audio and video play there. Closing it
                // keeps the attachment; × removes it.
                summary
                    .accessibilityElement(children: .combine)
                    .opensMediaPreview {
                        Haptics.selection()
                        previewStagedFile(at: stagedFileURL)
                    }
                    .accessibilityIdentifier("composer.attachment.preview")
            } else {
                summary
            }
            Button {
                Haptics.light()
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    // A full-size tap target without growing the chip.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .padding(.vertical, -10)
                    .padding(.horizontal, -12)
            }
            .buttonStyle(.plain)
            .disabled(!canRemove)
            .accessibilityLabel(AppLocalization.string("Remove \(AttachmentTypePolicy.displayName(for: attachment))"))
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
        .sheet(isPresented: $isShowingPastedText) {
            PastedTextSheet(attachment: attachment, actions: pastedText)
        }
        .onDisappear { previewTask?.cancel() }
        .task(id: attachment.uri) {
            if let url = URL(string: attachment.uri), url.isFileURL {
                byteCount = AttachmentSizeLimit.fileSize(at: url)
            }
            if isPastedText {
                let attachment = attachment
                pastedPreview = await Task.detached(priority: .utility) {
                    PastedText.chipPreview(of: attachment)
                }.value
                return
            }
            thumbnail = await AttachmentThumbnailLoader.thumbnail(
                for: attachment,
                maxPixelSize: Self.thumbnailSide * displayScale
            )
        }
    }

    /// The preview, the name, and its type and size; a paste shows its
    /// first words in place of a type.
    private var summary: some View {
        HStack(spacing: 8) {
            preview
            VStack(alignment: .leading, spacing: 1) {
                Text(AttachmentTypePolicy.displayName(for: attachment))
                    .scaledFont(.caption.weight(.medium))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .truncationMode(.middle)
                Text(detail)
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 220 : 140, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private var detail: String {
        if isPastedText, let pastedPreview, !pastedPreview.isEmpty {
            return pastedPreview
        }
        return AttachmentTypePolicy.detailLabel(for: attachment, byteCount: byteCount)
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
                    .scaledFont(.callout)
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
