//
//  TranscriptImageCache.swift
//  Conduit
//
//  Chat pictures kept on the phone after their first load (#652), so
//  reopening a chat or scrolling back to a picture does not download it
//  again. It lives in Caches, where iOS may clear it, keeps itself under a
//  size budget, and is wiped with the offline chat copy on sign-out.
//

import CryptoKit
import Foundation

enum TranscriptImageCache {
    /// Past this size the oldest pictures go until the cache is back
    /// under `trimTargetBytes`.
    static let budgetBytes = 200 * 1024 * 1024
    static let trimTargetBytes = 150 * 1024 * 1024

    /// Moves on with every `purge`: a load that started before one keeps
    /// nothing, so a signed-out dashboard's pictures don't come back.
    static var generation: Int { lock.withLock { current } }
    private nonisolated(unsafe) static var current = 0
    /// Keeps a write and a purge from interleaving.
    private static let lock = NSLock()

    /// Quick Look and the share sheet read the type from the extension.
    private static let fileExtensions = ["jpg", "png", "gif", "webp", "heic", "img"]

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("TranscriptImages", isDirectory: true)
    }

    /// A picture by the server file it came from.
    static func key(dashboard: String, profile: String, path: String) -> String {
        "path|\(dashboard)|\(profile)|\(path)"
    }

    /// A picture by its place inside a persisted message.
    static func key(dashboard: String, inlineImage ref: InlineImageRef) -> String {
        "row|\(dashboard)|\(ref.profile)|\(ref.sessionId)|\(ref.rowId)|\(ref.index)"
    }

    /// The kept file for `key`, if there is one. `touch` marks it as just
    /// used, so `trim` drops the pictures nobody has looked at in longest.
    static func cachedFile(for key: String, in directory: URL = defaultDirectory, touch: Bool = false) -> URL? {
        let stem = fileStem(for: key)
        let file = fileExtensions
            .lazy
            .map { directory.appendingPathComponent("\(stem).\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        if touch, let file {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        }
        return file
    }

    /// Keeps the picture in `dataURL` under `key` and returns its file, or
    /// nil when the data URL holds no picture, the write failed, or the
    /// cache was purged since `generation` (read when the load started).
    @discardableResult
    static func store(dataURL: String, for key: String, in directory: URL = defaultDirectory,
                      generation: Int = TranscriptImageCache.generation) -> URL? {
        guard let data = DataURLLimits.decodeBase64DataURL(dataURL, prefix: "data:image/") else { return nil }
        let stem = fileStem(for: key)
        let type = fileExtension(forDataURL: dataURL)
        let file = directory.appendingPathComponent("\(stem).\(type)")
        let kept = lock.withLock { () -> Bool in
            guard current == generation else { return false }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var directoryURL = directory
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? directoryURL.setResourceValues(values)
                try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                return false
            }
            // The same picture kept earlier under another type would shadow
            // this one in `cachedFile`.
            for other in fileExtensions where other != type {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(stem).\(other)"))
            }
            return true
        }
        guard kept else { return nil }
        trim(directory)
        return file
    }

    /// Drops every kept picture. Loads already under way keep nothing; the
    /// files go off the caller's thread.
    @discardableResult
    static func purge(in directory: URL = defaultDirectory) -> Task<Void, Never> {
        lock.withLock { current += 1 }
        return Task.detached(priority: .utility) { removeAll(in: directory) }
    }

    static func removeAll(in directory: URL = defaultDirectory) {
        lock.withLock { _ = try? FileManager.default.removeItem(at: directory) }
    }

    /// Drops the least recently used pictures once the cache outgrows
    /// `budget`. Unserialized on purpose: a picture removed between a
    /// lookup and its read is fetched again, nothing worse.
    static func trim(_ directory: URL, budget: Int = budgetBytes, target: Int = trimTargetBytes) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
        ) else { return }
        var entries = files.compactMap { file -> (url: URL, size: Int, date: Date)? in
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > budget else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > target {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private static func fileStem(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func fileExtension(forDataURL dataURL: String) -> String {
        let header = dataURL.prefix { $0 != "," && $0 != ";" }.lowercased()
        switch header {
        case "data:image/jpeg", "data:image/jpg": return "jpg"
        case "data:image/png": return "png"
        case "data:image/gif": return "gif"
        case "data:image/webp": return "webp"
        case "data:image/heic", "data:image/heif": return "heic"
        default: return "img"
        }
    }
}
