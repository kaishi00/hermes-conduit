//
//  ImageGalleryItems.swift
//  Conduit
//
//  The pictures a chat's viewer pages through, in the order the chat shows
//  them: a message's pictures in its text, then the ones it attaches, and a
//  tool's pictures with its step. Each fetches its original the way its row
//  opened it alone: the photo on this device, the copy kept on the phone,
//  then Hermes.
//

import SwiftUI
import UIKit

extension ImageGalleryItem {
    /// A picture the user attached.
    @MainActor
    static func attachment(_ attachment: Attachment, resolver: GatewayMediaDataURLResolver?) -> ImageGalleryItem? {
        guard attachment.kind == .image else { return nil }
        let filename = AttachmentPreviewFilename.make(name: attachment.name, uri: attachment.uri)
        let keptKey = resolver?.imageCacheKey(for: attachment)
        return ImageGalleryItem(id: attachmentID(attachment), title: attachment.name.isEmpty ? filename : attachment.name) {
            if let local = localFile(attachment.uri) {
                return ImageGalleryFile(url: local, ownedDirectory: nil)
            }
            // The original kept on the phone (#652).
            if let keptKey, let kept = TranscriptImageCache.cachedFile(for: keptKey, touch: true) {
                return ImageGalleryFile(url: kept, ownedDirectory: nil)
            }
            guard let resolver else { return nil }
            var dataURL = attachment.uri.hasPrefix("/") ? await resolver.dataURL(for: attachment.uri) : nil
            if dataURL == nil, let inline = attachment.inlineImage {
                dataURL = await resolver.inlineImageDataURL(inline)
            }
            guard let dataURL else { return nil }
            // A picture known only from its message has no file name to
            // borrow an extension from; the share sheet needs one.
            let named = (filename as NSString).pathExtension.isEmpty
                ? "\(filename).\(TranscriptImageCache.fileExtension(forDataURL: dataURL))"
                : filename
            return await ImageGalleryFile.staged(dataURL: dataURL, filename: named)
        }
    }

    /// A picture in a message's Markdown: a `MEDIA:` image from Hermes, or a
    /// web picture. Nil for a gateway video, audio clip or document, which
    /// open in Quick Look, and for an address no row could load.
    @MainActor
    static func markdownImage(url: String, alt: String, resolver: GatewayMediaDataURLResolver?,
                              dataURL: ((String) async -> String?)? = nil) -> ImageGalleryItem? {
        if url.hasPrefix("MEDIA:") {
            let path = String(url.dropFirst("MEDIA:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, GatewayMediaKind(path: path) == .image else { return nil }
            let fetch = dataURL ?? resolver.map { resolver in { path in await resolver.dataURL(for: path) } }
            return gatewayMedia(path: path, title: alt.isEmpty ? MarkdownParser.mediaName(path) : alt,
                                keptKey: resolver?.imageCacheKey(forMediaPath: path), dataURL: fetch)
        }
        guard let destination = WebFallbackImageDestination.resolve(url) else { return nil }
        let fallback = alt.isEmpty ? "image" : alt
        return ImageGalleryItem(id: webID(url), title: alt.isEmpty ? destination.lastPathComponent : alt) {
            guard let (data, response) = await MediaPreviewPresenter.boundedDownload(destination) else { return nil }
            let name = MediaPreviewPresenter.filename(for: destination, response: response, fallback: fallback)
            return await ImageGalleryFile.staged(data: data, filename: name)
        }
    }

    /// A picture on the Hermes host, kept on the phone under `keptKey`.
    @MainActor
    static func gatewayMedia(path: String, title: String, keptKey: String?,
                             dataURL: ((String) async -> String?)?) -> ImageGalleryItem {
        ImageGalleryItem(id: mediaID(path: path), title: title) {
            if let keptKey, let kept = TranscriptImageCache.cachedFile(for: keptKey, touch: true) {
                return ImageGalleryFile(url: kept, ownedDirectory: nil)
            }
            guard let dataURL, let value = await dataURL(path) else { return nil }
            return await ImageGalleryFile.staged(dataURL: value, filename: path)
        }
    }

    /// A file on the Hermes host fetched as Artifacts and the Folder open
    /// one: downloaded, else as a data URL.
    @MainActor
    static func hostFile(path: String, title: String, resolver: GatewayMediaDataURLResolver) -> ImageGalleryItem {
        ImageGalleryItem(id: mediaID(path: path), title: title) {
            switch await resolver.file(for: path) {
            case .downloaded(let download):
                return ImageGalleryFile(download)
            case .tooLarge:
                return nil
            case .unavailable:
                break
            }
            guard !Task.isCancelled, let dataURL = await resolver.dataURL(for: path) else { return nil }
            return await ImageGalleryFile.staged(dataURL: dataURL, filename: title)
        }
    }

    /// The photo itself while it is still on this device.
    private static func localFile(_ uri: String) -> URL? {
        guard !uri.isEmpty else { return nil }
        if let url = URL(string: uri), url.isFileURL {
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let url = URL(fileURLWithPath: uri)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

enum ChatImageGallery {
    /// Every picture in `messages`, in the order the chat shows them.
    @MainActor
    static func items(in messages: [ChatMessage], resolver: GatewayMediaDataURLResolver?) -> [ImageGalleryItem] {
        var items: [ImageGalleryItem] = []
        for message in messages {
            switch message.role {
            case .user:
                let reply = ReplyQuoteEnvelope.parse(message.content)
                let text = reply?.message ?? message.content
                if VoiceMessage.parse(text) == nil {
                    items += markdownItems(text, resolver: resolver, recognizesGatewayMedia: false)
                }
                items += (message.attachments ?? []).compactMap { ImageGalleryItem.attachment($0, resolver: resolver) }
            case .assistant, .partial:
                items += markdownItems(message.content, resolver: resolver, recognizesGatewayMedia: resolver != nil)
            default:
                if let tool = message.tool,
                   case .media(let paths)? = ToolResultPresentation.cached(toolName: tool.name, output: tool.output)?.body {
                    let source = paths.map(ToolResultPresentation.mediaTag(for:)).joined(separator: "\n\n")
                    items += markdownItems(source, resolver: resolver, recognizesGatewayMedia: resolver != nil)
                }
            }
        }
        return ImageGallery.deduplicated(items)
    }

    /// The pictures in one Markdown text, as MarkdownText draws them.
    @MainActor
    static func markdownItems(_ source: String, resolver: GatewayMediaDataURLResolver?,
                              recognizesGatewayMedia: Bool,
                              dataURL: ((String) async -> String?)? = nil) -> [ImageGalleryItem] {
        guard mayHoldPictures(source) else { return [] }
        return MarkdownParser.parse(source, recognizesGatewayMedia: recognizesGatewayMedia).compactMap { block in
            switch block {
            case .image(let url, let alt):
                return ImageGalleryItem.markdownImage(url: url, alt: alt, resolver: resolver, dataURL: dataURL)
            case .htmlPreview:
                // A page's own pictures stay in the page.
                return nil
            default:
                return nil
            }
        }
    }

    /// Cheap check before parsing a whole message: every picture a block
    /// draws comes from a `MEDIA:` tag, a `![…](…)` image, a preview
    /// directive or a bare web address.
    static func mayHoldPictures(_ source: String) -> Bool {
        source.contains("![") || source.contains("://")
            || source.range(of: "MEDIA:", options: .caseInsensitive) != nil
            || source.contains("::preview")
    }
}
