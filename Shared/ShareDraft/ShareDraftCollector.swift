//
//  ShareDraftCollector.swift
//  Conduit
//
//  Reads what another app shared (#812) through the documented
//  NSExtensionItem / NSItemProvider path: text, links, pictures, videos and
//  files. Files are copied straight into the draft's staging folder (never
//  read into memory whole, except a picture whose file can't be read,
//  which is read as bytes or as an image object and written as PNG), checked against the share's caps, and
//  named by the collector; the sending app's file name is only a label.
//

import Foundation
import os
import UIKit
import UniformTypeIdentifiers

/// Something in a share that was left out, and why. The share sheet shows
/// each one; nothing is dropped silently.
enum ShareDraftProblem: Equatable {
    /// A file over the per-file cap.
    case fileTooLarge(name: String, limitBytes: Int64)
    /// A file that would have taken the share over its total.
    case totalTooLarge(name: String, limitBytes: Int64)
    /// Files past the attachment count.
    case tooManyFiles(dropped: Int, limit: Int)
    /// Text cut at the character cap.
    case textTruncated(limit: Int)
    /// Something the sending app offered but couldn't hand over, with the
    /// system's reason when it gave one.
    case unreadable(name: String, reason: String?)
}

/// What the collector made of a share.
struct ShareDraftCollection: Equatable {
    var text: String
    var attachments: [ShareDraftAttachment]
    var problems: [ShareDraftProblem]

    var isEmpty: Bool { text.isEmpty && attachments.isEmpty }
}

struct ShareDraftCollector {
    let staging: ShareDraftStagingFolder
    let fileByteLimit: Int64
    let totalByteLimit: Int64
    let maximumAttachments: Int
    let maximumTextCharacters: Int

    init(
        staging: ShareDraftStagingFolder,
        fileByteLimit: Int64,
        totalByteLimit: Int64 = ShareDraftLimits.totalBytes,
        maximumAttachments: Int = ShareDraftLimits.maximumAttachments,
        maximumTextCharacters: Int = ShareDraftLimits.maximumTextCharacters
    ) {
        self.staging = staging
        self.fileByteLimit = fileByteLimit
        self.totalByteLimit = totalByteLimit
        self.maximumAttachments = maximumAttachments
        self.maximumTextCharacters = maximumTextCharacters
    }

    /// The share sheet's input: every item's attachments, and the text an
    /// item carries itself (a page title) when no attachment is text.
    func collect(_ items: [NSExtensionItem]) async -> ShareDraftCollection {
        let providers = items.flatMap { $0.attachments ?? [] }
        let itemText = items.compactMap { $0.attributedContentText?.string }
        return await collect(providers: providers, itemText: itemText)
    }

    func collect(providers: [NSItemProvider], itemText: [String] = []) async -> ShareDraftCollection {
        var texts: [String] = []
        var links: [String] = []
        var attachments: [ShareDraftAttachment] = []
        var problems: [ShareDraftProblem] = []
        var totalBytes: Int64 = 0
        var droppedFiles = 0
        var attempts = 0

        for provider in providers {
            switch Self.kind(of: provider) {
            case .unsupported:
                continue
            case .text:
                if let text = await Self.loadText(provider) { texts.append(text) }
                continue
            case .link:
                if let url = await Self.loadURL(provider) {
                    // A file handed over as a link is a file like any other.
                    guard url.isFileURL else {
                        links.append(url.absoluteString)
                        continue
                    }
                } else if !Self.offersFileURL(provider) {
                    continue
                }
                // A file URL that didn't load as a link is read as a file,
                // or named as left out.
            case .file:
                break
            }
            guard attachments.count < maximumAttachments else {
                droppedFiles += 1
                continue
            }
            attempts += 1
            let ordinal = attempts
            switch await stageFile(provider, ordinal: ordinal) {
            case .staged(let attachment):
                if totalBytes + attachment.byteCount > totalByteLimit {
                    try? FileManager.default.removeItem(at: staging.url.appendingPathComponent(attachment.storedName))
                    problems.append(.totalTooLarge(name: attachment.displayName, limitBytes: totalByteLimit))
                } else {
                    totalBytes += attachment.byteCount
                    attachments.append(attachment)
                }
            case .tooLarge(let name):
                problems.append(.fileTooLarge(name: name, limitBytes: fileByteLimit))
            case .failed(let name, let reason):
                problems.append(.unreadable(name: name, reason: reason))
            }
        }
        if droppedFiles > 0 {
            problems.append(.tooManyFiles(dropped: droppedFiles, limit: maximumAttachments))
        }

        // The page's title (Safari) only when nothing else said anything.
        if texts.isEmpty {
            texts = itemText.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        var parts: [String] = []
        for part in texts.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) + links
        where !part.isEmpty && !parts.contains(part) {
            // A link already in the shared text isn't added again.
            if links.contains(part), parts.contains(where: { $0.contains(part) }) { continue }
            parts.append(part)
        }
        var text = parts.joined(separator: "\n\n")
        if text.count > maximumTextCharacters || text.utf8.count > ShareDraftLimits.maximumTextBytes {
            text = ShareDraftLimits.truncated(text, characters: maximumTextCharacters)
            problems.append(.textTruncated(limit: text.count))
        }
        return ShareDraftCollection(text: text, attachments: attachments, problems: problems)
    }

    // MARK: Kinds

    enum Kind: Equatable { case link, file, text, unsupported }

    /// How a provider is read. Files win over text (a shared .txt document
    /// keeps its name); a web link is text in the draft.
    static func kind(of provider: NSItemProvider) -> Kind {
        let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        if types.contains(where: { $0.conforms(to: .fileURL) }) { return .link }
        if fileType(of: provider) != nil { return .file }
        // A picture offered only as an image object (the screenshot
        // editor's Share hands over UIKit's own image type, #1747).
        if offersImageObjectOnly(provider) { return .file }
        if types.contains(where: { $0.conforms(to: .url) }) { return .link }
        if types.contains(where: { $0.conforms(to: .text) }) { return .text }
        return .unsupported
    }

    /// The type a provider's file is read as: a picture, video, audio,
    /// PDF or other document, or plain text that comes with a file name.
    static func fileType(of provider: NSItemProvider) -> UTType? {
        let types = fileTypeCandidates(provider)
        let media: [UTType] = [.image, .movie, .audio, .pdf]
        if let type = types.first(where: { type in media.contains { type.conforms(to: $0) } }) { return type }
        let hasName = !((provider.suggestedName ?? "") as NSString).pathExtension.isEmpty
        if let type = types.first(where: { $0.conforms(to: .data) && !$0.conforms(to: .url) && !$0.conforms(to: .text) }) {
            return type
        }
        if hasName, let type = types.first(where: { $0.conforms(to: .text) && !$0.conforms(to: .url) }) { return type }
        return nil
    }

    /// UIKit's own type for an image object. Its bytes are an archived
    /// `UIImage`, not a picture file, so it is never read as a file type.
    static let imageObjectType = "com.apple.uikit.image"

    private static func fileTypeCandidates(_ provider: NSItemProvider) -> [UTType] {
        provider.registeredTypeIdentifiers.filter { $0 != imageObjectType }.compactMap(UTType.init)
    }

    /// Whether a provider's only picture is an image object: it lists no
    /// file, link or text type but can still be read as a `UIImage`.
    static func offersImageObjectOnly(_ provider: NSItemProvider) -> Bool {
        let types = fileTypeCandidates(provider)
        let readable: [UTType] = [.data, .url, .text]
        guard !types.contains(where: { type in readable.contains { type.conforms(to: $0) } }) else { return false }
        return provider.canLoadObject(ofClass: UIImage.self)
    }

    // MARK: Reading

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        guard provider.canLoadObject(ofClass: URL.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        if provider.canLoadObject(ofClass: String.self) {
            let text: String? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: String.self) { text, _ in continuation.resume(returning: text) }
            }
            if let text { return text }
        }
        // Rich text and the like: read the item and keep its plain text.
        guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .text) == true }) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                switch item {
                case let string as String: continuation.resume(returning: string)
                case let attributed as NSAttributedString: continuation.resume(returning: attributed.string)
                case let data as Data: continuation.resume(returning: text(from: data))
                default: continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Text an item hands over as bytes: UTF-8, or UTF-16 that says so
    /// with its byte order mark (any even run of bytes decodes as UTF-16,
    /// so unmarked bytes are never guessed into it).
    static func text(from data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        guard data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) else { return nil }
        return String(data: data, encoding: .utf16)
    }

    enum StagedFile: Equatable {
        case staged(ShareDraftAttachment)
        case tooLarge(String)
        /// The name, and the system's reason when one was given.
        case failed(String, reason: String?)
    }

    /// Copies one provider's file into the staging folder, size checked
    /// before and after the copy. Each way the provider offers it is tried
    /// in turn (issue 1747): its file, then a picture's bytes, then the
    /// picture as an image object (written as PNG), then whatever item it
    /// hands over. It is left out only when every way failed, with the
    /// first reason the system gave; each failed step is logged.
    func stageFile(_ provider: NSItemProvider, ordinal: Int) async -> StagedFile {
        let type = Self.fileType(of: provider) ?? Self.fileURLType(of: provider)
        let displayName = Self.displayName(suggested: provider.suggestedName, type: type, ordinal: ordinal)
        let suggestedName = provider.suggestedName
        var reasons: [String] = []
        func failed(_ step: String, _ outcome: StagedFile?, error: Error?) {
            var reason = error?.localizedDescription
            if case .failed(_, let own)? = outcome { reason = reason ?? own }
            Self.log.error("Share #\(ordinal, privacy: .public) \(step, privacy: .public) failed: \(reason ?? "no reason given", privacy: .private)")
            if let reason, !reason.isEmpty { reasons.append(reason) }
        }
        Self.log.info("Share #\(ordinal, privacy: .public) types \(provider.registeredTypeIdentifiers.joined(separator: ","), privacy: .public), file type \(type?.identifier ?? "none", privacy: .public), named \(suggestedName != nil, privacy: .public)")

        // 1. Its file.
        if let type, provider.hasItemConformingToTypeIdentifier(type.identifier) {
            let (copied, error): (StagedFile?, Error?) = await withCheckedContinuation { continuation in
                _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                    // The file is only there until this handler returns.
                    continuation.resume(returning: (url.map {
                        copy($0, type: UTType(filenameExtension: $0.pathExtension) ?? type, displayName: displayName, ordinal: ordinal)
                    }, error))
                }
            }
            if let copied, Self.settles(copied) { return copied }
            failed("file", copied, error: error)
        }

        // 2. A picture's bytes. Only a picture: a video or document read
        // into memory whole could take the extension past its memory.
        if let type, type.conforms(to: .image), provider.hasItemConformingToTypeIdentifier(type.identifier) {
            let (data, error): (Data?, Error?) = await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                    continuation.resume(returning: (data, error))
                }
            }
            // Bytes that don't decode as a picture fall through to the
            // image object, which may hold a good one.
            // Size first: a payload over the limit is never decoded.
            let written = data.flatMap { data -> StagedFile? in
                guard Int64(data.count) <= fileByteLimit else { return .tooLarge(displayName) }
                return ProviderPicture.decodes(data) ? write(data, type: type, displayName: displayName, ordinal: ordinal) : nil
            }
            if let written, Self.settles(written) { return written }
            failed("data", written, error: error)
        }

        // 3. The picture as an image object, whatever picture type it
        // lists too: the screenshot editor's Share hands over UIKit's own
        // image. Never for a video or document, whose preview would stand
        // in for the file.
        if type.map({ $0.conforms(to: .image) }) ?? true, provider.canLoadObject(ofClass: UIImage.self) {
            let (image, error) = await ProviderPicture.loadImage(provider)
            let name = Self.pngName(suggested: suggestedName, ordinal: ordinal)
            let written = image.map { write(ProviderPicture.pngData($0), type: .png, displayName: name, ordinal: ordinal) }
            if let written, Self.settles(written) { return written }
            failed("image", written, error: error)
        }

        // 4. Whatever item it hands over under its type, then the file
        // URL it offers (a file shared by name only). UIKit's archived
        // image is never read as a file.
        let registered = provider.registeredTypeIdentifiers.filter { $0 != Self.imageObjectType }
        let fileURL = registered.first { UTType($0)?.conforms(to: .fileURL) == true }
        var identifiers: [String] = []
        for candidate in [type.flatMap { registered.contains($0.identifier) ? $0.identifier : nil }, fileURL] {
            if let candidate, !identifiers.contains(candidate) { identifiers.append(candidate) }
        }
        if identifiers.isEmpty, let first = registered.first { identifiers = [first] }
        for identifier in identifiers {
            let asFileURL = UTType(identifier)?.conforms(to: .fileURL) == true
            let (item, error): (StagedFile?, Error?) = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, error in
                    // A file URL handed over as bytes is the URL, not the file.
                    var loaded: NSSecureCoding? = item
                    if asFileURL, let data = item as? Data {
                        loaded = URL(dataRepresentation: data, relativeTo: nil).map { $0 as NSURL }
                    }
                    switch loaded {
                    case let url as URL where url.isFileURL:
                        let accessing = url.startAccessingSecurityScopedResource()
                        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                        let name = Self.displayName(suggested: suggestedName ?? url.lastPathComponent, type: type, ordinal: ordinal)
                        continuation.resume(returning: (copy(url, type: UTType(filenameExtension: url.pathExtension) ?? type, displayName: name, ordinal: ordinal), error))
                    case let image as UIImage:
                        continuation.resume(returning: (write(ProviderPicture.pngData(image), type: .png, displayName: Self.pngName(suggested: suggestedName, ordinal: ordinal), ordinal: ordinal), error))
                    case let data as Data where !asFileURL:
                        // Picture bytes count only when they decode, as in step 2.
                        let isPicture = type?.conforms(to: .image) == true
                        if Int64(data.count) > fileByteLimit {
                            continuation.resume(returning: (.tooLarge(displayName), error))
                        } else if isPicture, !ProviderPicture.decodes(data) {
                            continuation.resume(returning: (nil, error))
                        } else {
                            continuation.resume(returning: (write(data, type: type, displayName: displayName, ordinal: ordinal), error))
                        }
                    default:
                        continuation.resume(returning: (nil, error))
                    }
                }
            }
            if let item, Self.settles(item) { return item }
            failed("item \(identifier)", item, error: error)
        }
        return .failed(displayName, reason: reasons.first)
    }

    /// A picture written as PNG: the suggested name's stem, its own
    /// extension dropped.
    private static func pngName(suggested: String?, ordinal: Int) -> String {
        let stem = ((suggested ?? "") as NSString).deletingPathExtension
        return displayName(suggested: stem.isEmpty ? nil : "\(stem).png", type: .png, ordinal: ordinal)
    }

    private static let log = Logger(subsystem: "com.milim.relay", category: "ShareDraft")

    /// Whether a step's outcome is the answer: staged, or too large (the
    /// same file is no smaller read another way).
    private static func settles(_ outcome: StagedFile) -> Bool {
        if case .failed = outcome { return false }
        return true
    }

    private static func offersFileURL(_ provider: NSItemProvider) -> Bool {
        provider.registeredTypeIdentifiers.contains { UTType($0)?.conforms(to: .fileURL) == true }
    }

    private static func fileURLType(of provider: NSItemProvider) -> UTType? {
        provider.registeredTypeIdentifiers.compactMap(UTType.init).first { $0.conforms(to: .fileURL) }
            .flatMap { _ in provider.suggestedName.flatMap { UTType(filenameExtension: ($0 as NSString).pathExtension) } }
    }

    private func copy(_ source: URL, type: UTType?, displayName: String, ordinal: Int) -> StagedFile {
        let size: Int64
        do {
            guard let read = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                return .failed(displayName, reason: nil)
            }
            size = Int64(read)
        } catch {
            return .failed(displayName, reason: error.localizedDescription)
        }
        guard size <= fileByteLimit else { return .tooLarge(displayName) }
        guard size > 0 else { return .failed(displayName, reason: nil) }
        let storedName = ShareDraftNames.storedName(ordinal: ordinal, pathExtension: Self.pathExtension(displayName: displayName, type: type))
        guard let destination = ShareDraftInbox.file(named: storedName, in: staging.url) else { return .failed(displayName, reason: nil) }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            // A copy cut short would otherwise ride along in the draft
            // folder beside a later step's file.
            try? FileManager.default.removeItem(at: destination)
            return .failed(displayName, reason: error.localizedDescription)
        }
        // Checked again on the copy: the source could have grown meanwhile.
        guard let copied = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init),
              copied <= fileByteLimit else {
            try? FileManager.default.removeItem(at: destination)
            return .tooLarge(displayName)
        }
        return .staged(ShareDraftAttachment(storedName: storedName, displayName: displayName, typeIdentifier: type?.identifier, byteCount: copied))
    }

    private func write(_ data: Data?, type: UTType?, displayName: String, ordinal: Int) -> StagedFile {
        guard let data, !data.isEmpty else { return .failed(displayName, reason: nil) }
        guard Int64(data.count) <= fileByteLimit else { return .tooLarge(displayName) }
        let storedName = ShareDraftNames.storedName(ordinal: ordinal, pathExtension: Self.pathExtension(displayName: displayName, type: type))
        guard let destination = ShareDraftInbox.file(named: storedName, in: staging.url) else { return .failed(displayName, reason: nil) }
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            return .failed(displayName, reason: error.localizedDescription)
        }
        return .staged(ShareDraftAttachment(storedName: storedName, displayName: displayName, typeIdentifier: type?.identifier, byteCount: Int64(data.count)))
    }

    private static func pathExtension(displayName: String, type: UTType?) -> String? {
        let ext = (displayName as NSString).pathExtension
        return ext.isEmpty ? type?.preferredFilenameExtension : ext
    }

    /// The label a shared file gets: the sending app's name for it, made
    /// safe, with an extension that matches its type; otherwise "photo",
    /// "video" or "file" plus one, numbered past the first.
    static func displayName(suggested: String?, type: UTType?, ordinal: Int) -> String {
        let safe = ShareDraftNames.sanitizedDisplayName(suggested ?? "")
        let preferred = type?.preferredFilenameExtension
        if !safe.isEmpty {
            guard (safe as NSString).pathExtension.isEmpty, let preferred else { return safe }
            return ShareDraftNames.sanitizedDisplayName("\(safe).\(preferred)")
        }
        let stem: String
        if type?.conforms(to: .image) == true {
            stem = "photo"
        } else if type?.conforms(to: .movie) == true {
            stem = "video"
        } else {
            stem = "file"
        }
        let numbered = ordinal > 1 ? "\(stem)-\(ordinal)" : stem
        return preferred.map { "\(numbered).\($0)" } ?? numbered
    }
}
