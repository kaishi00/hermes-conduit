//
//  MediaPreviewPresenter.swift
//  Conduit
//
//  Full-screen preview for chat media (#195): agent `MEDIA:` images, video,
//  audio and documents, web images, and the user's own attachments.
//
//  Presentation goes through Quick Look rather than a hand-rolled viewer:
//  QLPreviewController already gives pinch-to-zoom for images, playback for
//  video and audio, paged documents, a Done button, and the system share
//  sheet (Save Image / Save Video / Save to Files / Copy). It is presented
//  from UIKit by this singleton so transcript rows — which are Equatable-
//  gated and often inside lazy stacks — don't need presentation state of
//  their own; a row only has to hand over a local file or bytes.
//
//  Previewed bytes are written under a per-preview temporary directory that
//  keeps the original filename (the share sheet uses it as the saved name)
//  and is removed when the preview is dismissed. Files the user already had
//  on disk (local attachments) are previewed in place and never deleted.
//

import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What an inline `MEDIA:` path points at, decided from its extension.
enum GatewayMediaKind: Equatable {
    case image
    case video
    case audio
    case document

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv", "avi"]
    static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "ogg", "oga", "opus", "flac", "caf", "aiff"]
    static let documentExtensions: Set<String> = [
        "pdf", "txt", "md", "csv", "json", "rtf",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers"
    ]

    /// Classifies a gateway path (optionally carrying a `?query`), or nil
    /// when the extension is not one Conduit renders as chat media.
    init?(path: String) {
        let withoutQuery = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        let ext = (withoutQuery as NSString).pathExtension.lowercased()
        if Self.imageExtensions.contains(ext) { self = .image }
        else if Self.videoExtensions.contains(ext) { self = .video }
        else if Self.audioExtensions.contains(ext) { self = .audio }
        else if Self.documentExtensions.contains(ext) { self = .document }
        else { return nil }
    }

    var systemImage: String {
        switch self {
        case .image: return "photo"
        case .video: return "play.rectangle.fill"
        case .audio: return "waveform"
        case .document: return "doc.fill"
        }
    }

    var label: String {
        switch self {
        case .image: return AppLocalization.string("Image")
        case .video: return AppLocalization.string("Video")
        case .audio: return AppLocalization.string("Audio")
        case .document: return AppLocalization.string("File")
        }
    }
}

@MainActor
final class MediaPreviewPresenter {
    /// First use sweeps staging folders left by a previous run (a preview
    /// open when the app was killed never reaches its dismiss cleanup).
    static let shared: MediaPreviewPresenter = {
        MediaPreviewPresenter.removeDirectory(MediaPreviewPresenter.stagingRoot)
        return MediaPreviewPresenter()
    }()

    /// One open preview. Each controller gets its own session (Quick Look
    /// holds its data source weakly, so `sessions` keeps it alive), which
    /// removes only its own staged directory when that controller closes.
    private final class Session: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let url: URL
        let title: String
        /// Temporary directory created for this preview, removed on dismiss.
        let ownedDirectory: URL?
        var onFinish: (@MainActor () -> Void)?
        var didPresent = false

        init(url: URL, title: String, ownedDirectory: URL?) {
            self.url = url
            self.title = title
            self.ownedDirectory = ownedDirectory
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            PreviewItem(url: url, title: title)
        }

        func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode {
            .disabled
        }

        func previewControllerDidDismiss(_ controller: QLPreviewController) {
            MediaPreviewPresenter.removeDirectory(ownedDirectory)
            // Quick Look calls its delegate on the main thread.
            MainActor.assumeIsolated {
                onFinish?()
                onFinish = nil
            }
        }
    }

    private var sessions: [ObjectIdentifier: Session] = [:]

    /// Previews a file already on disk (a local attachment). The file is
    /// left in place afterwards.
    @discardableResult
    func present(fileURL: URL, title: String? = nil) -> Bool {
        guard Self.isPreviewable(filename: fileURL.lastPathComponent, mimeType: nil),
              FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        return show(Session(url: fileURL, title: title ?? fileURL.lastPathComponent, ownedDirectory: nil))
    }

    /// Previews in-memory bytes (a download) under `filename`, so Save/Share
    /// keep the original name and type. Active web content (HTML, SVG, XML)
    /// is refused rather than handed to Quick Look's web renderer. The disk
    /// write runs off the main actor; a cancelled caller presents nothing.
    @discardableResult
    func present(data: Data, filename: String, mimeType: String? = nil) async -> Bool {
        guard Self.isPreviewable(filename: filename, mimeType: mimeType) else { return false }
        let staged = await Task.detached(priority: .userInitiated) {
            Self.stage(data: data, filename: filename)
        }.value
        return presentStaged(staged)
    }

    /// Previews a gateway `data:` URL, refusing active web content by its
    /// declared MIME type as well as by `filename`. Up to 16 MB of base64 is
    /// decoded and written off the main actor so a large file can't hitch
    /// the transcript on tap.
    @discardableResult
    func present(dataURL: String, filename: String) async -> Bool {
        guard Self.isPreviewable(filename: filename, mimeType: Self.mimeType(ofDataURL: dataURL)) else { return false }
        let staged = await Task.detached(priority: .userInitiated) { () -> (directory: URL, file: URL)? in
            guard let data = DataURLLimits.decodeBase64DataURL(dataURL) else { return nil }
            return Self.stage(data: data, filename: filename)
        }.value
        return presentStaged(staged)
    }

    private func presentStaged(_ staged: (directory: URL, file: URL)?) -> Bool {
        guard let staged else { return false }
        guard !Task.isCancelled else {
            Self.removeDirectory(staged.directory)
            return false
        }
        return show(Session(url: staged.file, title: staged.file.lastPathComponent, ownedDirectory: staged.directory))
    }

    /// Downloads a web image and previews it. The body is streamed against
    /// the same 16 MB ceiling as gateway media, so an oversized or endless
    /// response is abandoned instead of being buffered whole.
    func presentRemote(url: URL, fallbackName: String) async -> Bool {
        guard let (data, response) = await Self.boundedDownload(url),
              !Task.isCancelled else { return false }
        let name = Self.filename(for: url, response: response, fallback: fallbackName)
        return await present(data: data, filename: name, mimeType: response.mimeType)
    }

    // MARK: - Presentation

    @discardableResult
    private func show(_ session: Session) -> Bool {
        guard let presenter = Self.topViewController() else {
            Self.removeDirectory(session.ownedDirectory)
            return false
        }
        let controller = QLPreviewController()
        let key = ObjectIdentifier(controller)
        session.onFinish = { [weak self] in self?.sessions[key] = nil }
        sessions[key] = session
        controller.dataSource = session
        controller.delegate = session
        controller.modalPresentationStyle = .fullScreen
        presenter.present(controller, animated: true) {
            session.didPresent = true
        }
        // UIKit refuses (and only logs) a presentation while another is in
        // flight, and then never calls the completion or the dismiss
        // delegate. Reclaim such a session once the transition has had
        // ample time to finish.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !session.didPresent, controller.presentingViewController == nil else { return }
            self?.sessions[key] = nil
            Self.removeDirectory(session.ownedDirectory)
        }
        return true
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    // MARK: - Content policy

    nonisolated static let blockedExtensions: Set<String> = [
        "html", "htm", "xhtml", "xht", "svg", "svgz", "xml", "webarchive", "mht", "mhtml"
    ]
    nonisolated static let blockedMIMETypes: Set<String> = [
        "text/html", "application/xhtml+xml", "image/svg+xml", "text/xml",
        "application/xml", "application/x-webarchive", "multipart/related"
    ]

    /// False for content Quick Look would render as a web page.
    nonisolated static func isPreviewable(filename: String, mimeType: String?) -> Bool {
        let ext = (sanitizedFilename(filename) as NSString).pathExtension.lowercased()
        if blockedExtensions.contains(ext) { return false }
        if let mimeType {
            let base = mimeType.split(separator: ";", maxSplits: 1).first.map(String.init) ?? mimeType
            if blockedMIMETypes.contains(base.trimmingCharacters(in: .whitespaces).lowercased()) { return false }
        }
        return true
    }

    /// The MIME type in a `data:<type>;base64,` header, lowercased.
    nonisolated static func mimeType(ofDataURL value: String) -> String? {
        guard value.lowercased().hasPrefix("data:") else { return nil }
        let header = value.dropFirst(5).prefix { $0 != ";" && $0 != "," }
        let type = header.trimmingCharacters(in: .whitespaces).lowercased()
        return type.isEmpty ? nil : type
    }

    // MARK: - Download

    nonisolated static func boundedDownload(_ url: URL, limit: Int = DataURLLimits.maxDecodedBytes) async -> (Data, URLResponse)? {
        do {
            let (bytes, response) = try await URLSession.shared.bytes(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            if response.expectedContentLength > Int64(limit) { return nil }
            var data = Data()
            if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
            // Gather into a fixed chunk and append in bulk: appending each
            // byte to `Data` costs millions of calls for a large image.
            let chunkSize = 64 * 1024
            var chunk = [UInt8]()
            chunk.reserveCapacity(chunkSize)
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count == chunkSize {
                    data.append(contentsOf: chunk)
                    chunk.removeAll(keepingCapacity: true)
                    if data.count > limit { return nil }
                }
            }
            data.append(contentsOf: chunk)
            guard data.count <= limit else { return nil }
            return data.isEmpty ? nil : (data, response)
        } catch {
            return nil
        }
    }

    // MARK: - Staging

    nonisolated static let stagingRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("Conduit-Media-Preview", isDirectory: true)

    /// Writes `data` to `<tmp>/Conduit-Media-Preview/<uuid>/<filename>`.
    nonisolated static func stage(data: Data, filename: String) -> (directory: URL, file: URL)? {
        let directory = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent(sanitizedFilename(filename))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return (directory, file)
        } catch {
            removeDirectory(directory)
            return nil
        }
    }

    /// Keeps the last path component of a gateway path or URL, stripped of
    /// separators and a query, so it is always a single safe file name.
    nonisolated static func sanitizedFilename(_ raw: String) -> String {
        let withoutQuery = raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        let last = withoutQuery.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let cleaned = last
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return "media" }
        return truncatedFilename(cleaned)
    }

    /// File systems cap a name at 255 bytes; keep the extension and trim the
    /// stem so an over-long gateway name still stages.
    nonisolated static func truncatedFilename(_ name: String, maxBytes: Int = 200) -> String {
        guard name.utf8.count > maxBytes else { return name }
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty || ext.utf8.count > 16 ? "" : ".\(ext)"
        var stem = suffix.isEmpty ? name : String(name.dropLast(suffix.count))
        while stem.utf8.count + suffix.utf8.count > maxBytes, !stem.isEmpty {
            stem.removeLast()
        }
        return stem.isEmpty ? "media\(suffix)" : stem + suffix
    }

    nonisolated static func filename(for url: URL, response: URLResponse?, fallback: String) -> String {
        let candidate = response?.suggestedFilename ?? url.lastPathComponent
        var name = sanitizedFilename(candidate.isEmpty ? fallback : candidate)
        if (name as NSString).pathExtension.isEmpty,
           let mime = response?.mimeType,
           let ext = UTType(mimeType: mime)?.preferredFilenameExtension {
            name += ".\(ext)"
        }
        return name
    }

    nonisolated static func removeDirectory(_ directory: URL?) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class PreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL?, title: String?) {
        previewItemURL = url
        previewItemTitle = title
    }
}

/// Makes an inline media view open the full-screen preview on tap, and
/// tells VoiceOver it is a button that does so.
struct MediaPreviewTapModifier: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text("Opens full screen with save and share"))
    }
}

extension View {
    func opensMediaPreview(_ action: @escaping () -> Void) -> some View {
        modifier(MediaPreviewTapModifier(action: action))
    }
}
