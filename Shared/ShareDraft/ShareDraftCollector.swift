//
//  ShareDraftCollector.swift
//  Conduit
//
//  Reads what another app shared (#812) through the documented
//  NSExtensionItem / NSItemProvider path: text, links, pictures, videos and
//  files. Files are copied straight into the draft's staging folder (never
//  read into memory whole), checked against the share's caps, and named by
//  the collector; the sending app's file name is only a label.
//

import Foundation
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
    /// Something the sending app offered but couldn't hand over.
    case unreadable(name: String)
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
                guard let url = await Self.loadURL(provider) else { continue }
                // A file handed over as a link is a file like any other.
                guard url.isFileURL else {
                    links.append(url.absoluteString)
                    continue
                }
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
            case .failed(let name):
                problems.append(.unreadable(name: name))
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
        if types.contains(where: { $0.conforms(to: .url) }) { return .link }
        if types.contains(where: { $0.conforms(to: .text) }) { return .text }
        return .unsupported
    }

    /// The type a provider's file is read as: a picture, video, audio,
    /// PDF or other document, or plain text that comes with a file name.
    static func fileType(of provider: NSItemProvider) -> UTType? {
        let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        let media: [UTType] = [.image, .movie, .audio, .pdf]
        if let type = types.first(where: { type in media.contains { type.conforms(to: $0) } }) { return type }
        let hasName = !((provider.suggestedName ?? "") as NSString).pathExtension.isEmpty
        if let type = types.first(where: { $0.conforms(to: .data) && !$0.conforms(to: .url) && !$0.conforms(to: .text) }) {
            return type
        }
        if hasName, let type = types.first(where: { $0.conforms(to: .text) && !$0.conforms(to: .url) }) { return type }
        return nil
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
        case failed(String)
    }

    /// Copies one provider's file into the staging folder, size checked
    /// before and after the copy. A picture only offered as an image
    /// object (a screenshot's markup) is written as PNG.
    func stageFile(_ provider: NSItemProvider, ordinal: Int) async -> StagedFile {
        let type = Self.fileType(of: provider) ?? Self.fileURLType(of: provider)
        let displayName = Self.displayName(suggested: provider.suggestedName, type: type, ordinal: ordinal)
        if let type, provider.hasItemConformingToTypeIdentifier(type.identifier) {
            let copied: StagedFile? = await withCheckedContinuation { continuation in
                _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                    // The file is only there until this handler returns.
                    continuation.resume(returning: url.map {
                        copy($0, type: UTType(filenameExtension: $0.pathExtension) ?? type, displayName: displayName, ordinal: ordinal)
                    })
                }
            }
            if let copied { return copied }
        }
        // A file offered as a file URL, or an image offered as an object.
        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { continuation in
            // The type itself when the provider has it, else the file URL it
            // offers (a file shared by name only).
            let registered = provider.registeredTypeIdentifiers
            let fileURL = registered.first { UTType($0)?.conforms(to: .fileURL) == true }
            let identifier = type.flatMap { type in registered.contains(type.identifier) ? type.identifier : nil }
                ?? fileURL ?? registered.first ?? UTType.data.identifier
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                switch item {
                case let url as URL where url.isFileURL:
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    let name = Self.displayName(suggested: suggestedName ?? url.lastPathComponent, type: type, ordinal: ordinal)
                    continuation.resume(returning: copy(url, type: UTType(filenameExtension: url.pathExtension) ?? type, displayName: name, ordinal: ordinal))
                case let image as UIImage:
                    let name = Self.displayName(suggested: suggestedName, type: .png, ordinal: ordinal)
                    continuation.resume(returning: write(image.pngData(), type: .png, displayName: name, ordinal: ordinal))
                case let data as Data:
                    continuation.resume(returning: write(data, type: type, displayName: displayName, ordinal: ordinal))
                default:
                    continuation.resume(returning: .failed(displayName))
                }
            }
        }
    }

    private static func fileURLType(of provider: NSItemProvider) -> UTType? {
        provider.registeredTypeIdentifiers.compactMap(UTType.init).first { $0.conforms(to: .fileURL) }
            .flatMap { _ in provider.suggestedName.flatMap { UTType(filenameExtension: ($0 as NSString).pathExtension) } }
    }

    private func copy(_ source: URL, type: UTType?, displayName: String, ordinal: Int) -> StagedFile {
        guard let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) else {
            return .failed(displayName)
        }
        guard size <= fileByteLimit else { return .tooLarge(displayName) }
        guard size > 0 else { return .failed(displayName) }
        let storedName = ShareDraftNames.storedName(ordinal: ordinal, pathExtension: Self.pathExtension(displayName: displayName, type: type))
        guard let destination = ShareDraftInbox.file(named: storedName, in: staging.url) else { return .failed(displayName) }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            return .failed(displayName)
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
        guard let data, !data.isEmpty else { return .failed(displayName) }
        guard Int64(data.count) <= fileByteLimit else { return .tooLarge(displayName) }
        let storedName = ShareDraftNames.storedName(ordinal: ordinal, pathExtension: Self.pathExtension(displayName: displayName, type: type))
        guard let destination = ShareDraftInbox.file(named: storedName, in: staging.url),
              (try? data.write(to: destination, options: .atomic)) != nil else { return .failed(displayName) }
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
