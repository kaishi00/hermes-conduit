//
//  TranscriptPictureMemory.swift
//  Conduit
//
//  What a chat row needs on its first frame when it scrolls back into view
//  (#1238): its picture while it is still in memory, else at least the
//  picture's size, and the height a card drawn in a web page (an HTML
//  preview, a diagram, a formula) measured last time, so the row takes its
//  final height at once. A row that mounted as a "Loading image…" line or a
//  placeholder and grew a few frames later moved everything under it while
//  the user scrolled up through a long chat.
//
//  Sizes and heights are kept on the phone next to the pictures, read once
//  off the main thread, so a body only ever looks one up in memory.
//

import UIKit

@MainActor
enum TranscriptPictureMemory {
    /// Past this many sizes the memo starts again; a size is a few bytes.
    static let sizeLimit = 4000
    /// Past this many card heights, likewise.
    static let heightLimit = 2000

    /// Decoded pictures from Hermes' `MEDIA:` paths, by their
    /// `TranscriptImageCache` key. Bounded by decoded size; NSCache evicts
    /// under memory pressure, and the files on disk stay.
    private static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// Your attachments' previews, by photo path or kept-picture key,
    /// downsampled to the display size so a body at streaming frame rate
    /// never decodes. Here so they go with everything else on a sign-out.
    static let previews: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// Shown sizes by key: a kept picture's cache key, or a photo's path.
    private static var sizes: [String: CGSize] = [:]
    /// Heights of the cards drawn in web pages, by card key ("preview|…"
    /// for an HTML file on the connected Hermes, "markup|…" for a diagram
    /// or formula's source): the room their row takes before the page
    /// reports (ChatCardHeight).
    private static var heights: [String: CGFloat] = [:]
    private static var loadedKeptSizes = false
    /// The read under way, so overlapping callers (a restarted `.task`, a
    /// save) wait for its merge instead of passing it by.
    private static var keptSizesLoad: Task<Void, Never>?
    private static var pendingSave: Task<Void, Never>?
    /// Moves on with every `forgetAll`, so a read or save from before it
    /// brings nothing back.
    private static var generation = 0

    nonisolated static var defaultSizesFile: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("TranscriptImageSizes.plist")
    }

    static func image(for key: String) -> UIImage? {
        images.object(forKey: key as NSString)
    }

    static func remember(_ image: UIImage, for key: String, savingTo file: URL? = defaultSizesFile) {
        images.setObject(image, forKey: key as NSString, cost: bitmapCost(of: image))
        rememberSize(image.size, for: key, savingTo: file)
    }

    static func size(for key: String) -> CGSize? {
        sizes[key]
    }

    static func rememberSize(_ size: CGSize, for key: String, savingTo file: URL? = defaultSizesFile) {
        guard size.width > 0, size.height > 0, sizes[key] != size else { return }
        if sizes.count >= sizeLimit, sizes[key] == nil { sizes.removeAll() }
        sizes[key] = size
        if let file { scheduleSave(to: file) }
    }

    static func height(for key: String) -> CGFloat? {
        heights[key]
    }

    static func rememberHeight(_ height: CGFloat, for key: String, savingTo file: URL? = defaultSizesFile) {
        guard height > 0, heights[key] != height else { return }
        if heights.count >= heightLimit, heights[key] == nil { heights.removeAll() }
        heights[key] = height
        if let file { scheduleSave(to: file) }
    }

    /// Reads the sizes and heights kept from earlier launches, once, off
    /// the main thread. Ones remembered meanwhile win.
    static func loadKeptSizes(from file: URL = defaultSizesFile) async {
        if let keptSizesLoad {
            await keptSizesLoad.value
            return
        }
        guard !loadedKeptSizes else { return }
        loadedKeptSizes = true
        let started = generation
        let load = Task {
            // On `io`, so it runs after any removal `forgetAll` already asked for.
            let kept = await withCheckedContinuation { continuation in
                io.async { continuation.resume(returning: readKept(from: file)) }
            }
            // `forgetAll` moved the generation on, and reset the flag itself.
            guard generation == started else { return }
            // Up to the limits, the ones this launch has first.
            for (key, size) in kept.sizes where sizes[key] == nil {
                guard sizes.count < sizeLimit else { break }
                sizes[key] = size
            }
            for (key, height) in kept.heights where heights[key] == nil {
                guard heights.count < heightLimit else { break }
                heights[key] = height
            }
        }
        keptSizesLoad = load
        await load.value
        // A sign-out meanwhile let the next caller start a read of its own.
        if keptSizesLoad == load { keptSizesLoad = nil }
    }

    /// Everything goes with the kept files (sign-out, Delete Saved Chats).
    static func forgetAll(sizesFile file: URL = defaultSizesFile) {
        generation += 1
        pendingSave?.cancel()
        pendingSave = nil
        images.removeAllObjects()
        previews.removeAllObjects()
        sizes.removeAll()
        heights.removeAll()
        // The next read finds the file gone, so nothing comes back. A read
        // still under way is of the file going, so the next caller starts
        // its own instead of waiting on it.
        loadedKeptSizes = false
        keptSizesLoad = nil
        io.async { try? FileManager.default.removeItem(at: file) }
    }

    /// Writes the sizes and heights a second after the last new one, off
    /// the main thread.
    private static func scheduleSave(to file: URL) {
        pendingSave?.cancel()
        let started = generation
        pendingSave = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, generation == started else { return }
            // The kept sizes first, so the save never writes over them
            // with only this launch's.
            await loadKeptSizes(from: file)
            guard !Task.isCancelled, generation == started else { return }
            let snapshot = TranscriptKeptSizes(sizes: sizes, heights: heights)
            io.async { writeKept(snapshot, to: file) }
        }
    }

    /// Saves and removals of the sizes file, in the order they were asked
    /// for: a save already under way when the sizes are forgotten can't
    /// land after the removal.
    private nonisolated static let io = DispatchQueue(label: "TranscriptPictureMemory.io", qos: .utility)

    /// A size is two numbers, a height one; a build before heights reads
    /// past them.
    nonisolated static func writeKept(_ kept: TranscriptKeptSizes, to file: URL) {
        var plist = kept.sizes.mapValues { [Double($0.width), Double($0.height)] }
        for (key, height) in kept.heights {
            plist[key] = [Double(height)]
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) else { return }
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    nonisolated static func readKept(from file: URL) -> TranscriptKeptSizes {
        guard let data = try? Data(contentsOf: file),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: [Double]]
        else { return TranscriptKeptSizes() }
        var kept = TranscriptKeptSizes()
        for (key, values) in plist {
            switch values.count {
            case 2 where values[0] > 0 && values[1] > 0:
                kept.sizes[key] = CGSize(width: values[0], height: values[1])
            case 1 where values[0] > 0:
                kept.heights[key] = CGFloat(values[0])
            default:
                continue
            }
        }
        return kept
    }

    /// Estimated decoded byte cost for NSCache. `bytesPerRow * height`
    /// accounts for the row-alignment padding that a naive
    /// `width * height * 4` misses.
    static func bitmapCost(of image: UIImage) -> Int {
        if let cg = image.cgImage {
            return cg.bytesPerRow * cg.height
        }
        return Int(image.size.width * image.scale * image.size.height * image.scale) * 4
    }
}

/// What the sizes file holds: picture sizes and card heights, by key.
struct TranscriptKeptSizes: Equatable, Sendable {
    var sizes: [String: CGSize] = [:]
    var heights: [String: CGFloat] = [:]
}
