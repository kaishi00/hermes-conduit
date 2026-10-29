//
//  ProfileAppearanceStore.swift
//  Conduit
//
//  The profile label is device-local. A profile's photo lives on Hermes,
//  in the profile's asset store (`profiles.get_asset` / `set_asset`, the
//  same picture bots and Hermes Desktop use); this store keeps a mirror of
//  it on disk so avatars draw at launch and offline. Only a gateway without
//  that asset store keeps a photo on the device alone.
//
//  It is also scoped to one saved dashboard (#148). Every Hermes server has
//  a profile called "default", so a label or photo keyed by profile name
//  alone showed dashboard A's "default" name and picture on dashboard B.
//  Names live in a per-dashboard map; photos live in a per-dashboard
//  subdirectory whose file names encode the profile.
//

import Foundation
import ImageIO
import UIKit

/// Main-actor isolated: its read-modify-write of the defaults maps relies
/// on a single caller context (AppState).
@MainActor
final class ProfileAppearanceStore {
    static let defaultName = "Hermes"
    /// Pre-scoping keys. Their values belonged to the only dashboard that
    /// existed then, so they are adopted by the registry's first dashboard.
    static let legacyDefaultNameKey = "conduit.defaultProfileName.v1"
    static let legacyAvatarsKey = "conduit.profileAvatars.v1"
    static let defaultNamesKey = "conduit.defaultProfileNameByDashboard.v1"
    /// Per dashboard, the profiles whose photo file is a copy of the Hermes
    /// asset. A photo NOT listed was picked on this device before photos
    /// moved to Hermes (or on a gateway without the asset store).
    static let mirroredAvatarsKey = "conduit.profileAvatarsMirroredFromHermes.v1"
    /// Per dashboard, the backdrop glow color picked for a profile
    /// (`#rrggbb`). A device-local presentation choice, like the order.
    static let glowColorsKey = "conduit.profileGlowColorByDashboard.v1"
    /// Per dashboard, names given to profiles other than the main one on a
    /// gateway without bot looks, which has nowhere to keep them.
    static let deviceNamesKey = "conduit.profileDeviceNameByDashboard.v1"
    /// Per dashboard, the bot titles and Hermes `display_name`s its
    /// listings last gave, so a profile is named at launch and offline
    /// before they answer. The pre-scoping global names
    /// (`conduit.profileHermesNames.v1`) are left behind: the next listing
    /// gives them again.
    static let botTitlesKey = "conduit.profileBotTitleByDashboard.v1"
    static let hermesNamesKey = "conduit.profileHermesNameByDashboard.v1"
    /// The bucket for writes made while no dashboard is selected.
    private static let unscopedBucket = "unscoped"

    private let defaults: UserDefaults
    private let avatarsRootOverride: URL?
    private let legacyAvatarDirectoriesOverride: [URL]?

    /// `avatarsRoot` and `legacyAvatarDirectories` are test seams; nil uses
    /// Documents/profile-avatars and the pre-scoping locations.
    init(
        defaults: UserDefaults = .standard,
        avatarsRoot: URL? = nil,
        legacyAvatarDirectories: [URL]? = nil
    ) {
        self.defaults = defaults
        self.avatarsRootOverride = avatarsRoot
        self.legacyAvatarDirectoriesOverride = legacyAvatarDirectories
    }

    // MARK: Default profile name

    func loadDefaultName(dashboardID: UUID?) -> String {
        let saved = defaultNames()[Self.bucket(dashboardID)]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? Self.defaultName : saved
    }

    @discardableResult
    func saveDefaultName(_ value: String, dashboardID: UUID?) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = normalized.isEmpty ? Self.defaultName : normalized
        var names = defaultNames()
        names[Self.bucket(dashboardID)] = saved
        defaults.set(names, forKey: Self.defaultNamesKey)
        return saved
    }

    /// Every dashboard's main profile name, by dashboard UUID string: the
    /// Apple Watch names a call with them (HermesCallerName), and the
    /// Notification Service Extension the main bot's pushes
    /// (NotificationSharedSettings.mainProfileNames).
    func defaultNamesByDashboard() -> [String: String] {
        defaultNames().reduce(into: [String: String]()) { result, entry in
            let name = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id = UUID(uuidString: entry.key), !name.isEmpty else { return }
            result[id.uuidString] = name
        }
    }

    private func defaultNames() -> [String: String] {
        defaults.dictionary(forKey: Self.defaultNamesKey) as? [String: String] ?? [:]
    }

    // MARK: Avatars

    /// The dashboard's photos, discovered from its directory. File names
    /// encode the profile, so no path map is kept (absolute container paths
    /// change across app updates anyway).
    func loadAvatarURLs(dashboardID: UUID?) -> [String: URL] {
        guard let directory = avatarsDirectory(dashboardID: dashboardID, create: false) else { return [:] }
        return Self.avatarFiles(in: directory).reduce(into: [String: URL]()) { result, entry in
            result[entry.profile] = entry.url
        }
    }

    func saveAvatar(_ source: Data, for profile: String, dashboardID: UUID?) throws -> URL {
        guard let image = UIImage(data: source), let jpeg = image.jpegData(compressionQuality: 0.88) else {
            throw ProfileAppearanceError.invalidImage
        }
        guard let directory = avatarsDirectory(dashboardID: dashboardID, create: true) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let url = directory.appendingPathComponent(Self.fileName(for: profile), isDirectory: false)
        try jpeg.write(to: url, options: .atomic)
        ProfileAvatarImageCache.forget(url)
        setMirrored(false, profile: profile, dashboardID: dashboardID)
        return url
    }

    /// Stores the Hermes asset's bytes as the profile's photo. The bytes are
    /// kept as they are (PNG, JPEG or WebP; ImageIO reads the content, not
    /// the file extension), so a transparent picture stays transparent.
    /// Unchanged bytes are not rewritten; `changed` says whether they were.
    func saveMirroredAvatar(_ data: Data, for profile: String, dashboardID: UUID?) throws -> (url: URL, changed: Bool) {
        guard UIImage(data: data) != nil else { throw ProfileAppearanceError.invalidImage }
        guard let directory = avatarsDirectory(dashboardID: dashboardID, create: true) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let url = directory.appendingPathComponent(Self.fileName(for: profile), isDirectory: false)
        let changed = (try? Data(contentsOf: url)) != data
        if changed {
            try data.write(to: url, options: .atomic)
            ProfileAvatarImageCache.forget(url)
        }
        setMirrored(true, profile: profile, dashboardID: dashboardID)
        return (url, changed)
    }

    func isMirrored(_ profile: String, dashboardID: UUID?) -> Bool {
        mirroredProfiles()[Self.bucket(dashboardID)]?.contains(profile) == true
    }

    /// The photo file's bytes, for moving a device-only photo to Hermes.
    func avatarData(for profile: String, dashboardID: UUID?) -> Data? {
        guard let directory = avatarsDirectory(dashboardID: dashboardID, create: false) else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(Self.fileName(for: profile)))
    }

    func removeAvatar(for profile: String, dashboardID: UUID?) {
        guard let directory = avatarsDirectory(dashboardID: dashboardID, create: false) else {
            setMirrored(false, profile: profile, dashboardID: dashboardID)
            return
        }
        let url = directory.appendingPathComponent(Self.fileName(for: profile))
        // A copy that could not be deleted keeps its mark, so it is never
        // mistaken for a device photo and uploaded back to Hermes.
        if (try? FileManager.default.removeItem(at: url)) == nil,
           FileManager.default.fileExists(atPath: url.path) { return }
        setMirrored(false, profile: profile, dashboardID: dashboardID)
        ProfileAvatarImageCache.forget(url)
    }

    private func mirroredProfiles() -> [String: [String]] {
        defaults.dictionary(forKey: Self.mirroredAvatarsKey) as? [String: [String]] ?? [:]
    }

    private func setMirrored(_ mirrored: Bool, profile: String, dashboardID: UUID?) {
        var all = mirroredProfiles()
        let bucket = Self.bucket(dashboardID)
        var names = all[bucket] ?? []
        guard names.contains(profile) != mirrored else { return }
        if mirrored {
            names.append(profile)
        } else {
            names.removeAll { $0 == profile }
        }
        all[bucket] = names.isEmpty ? nil : names
        defaults.set(all, forKey: Self.mirroredAvatarsKey)
    }

    // MARK: Glow colors

    func loadGlowColors(dashboardID: UUID?) -> [String: String] {
        glowColors()[Self.bucket(dashboardID)] ?? [:]
    }

    /// Nil goes back to the color drawn from the profile's photo.
    func saveGlowColor(_ hex: String?, for profile: String, dashboardID: UUID?) {
        var all = glowColors()
        let bucket = Self.bucket(dashboardID)
        var colors = all[bucket] ?? [:]
        guard colors[profile] != hex else { return }
        colors[profile] = hex
        all[bucket] = colors.isEmpty ? nil : colors
        defaults.set(all, forKey: Self.glowColorsKey)
    }

    private func glowColors() -> [String: [String: String]] {
        defaults.dictionary(forKey: Self.glowColorsKey) as? [String: [String: String]] ?? [:]
    }

    func loadDeviceNames(dashboardID: UUID?) -> [String: String] {
        deviceNames()[Self.bucket(dashboardID)] ?? [:]
    }

    /// Nil or empty goes back to Hermes' name.
    func saveDeviceName(_ name: String?, for profile: String, dashboardID: UUID?) {
        let normalized = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var all = deviceNames()
        let bucket = Self.bucket(dashboardID)
        var names = all[bucket] ?? [:]
        names[profile] = normalized.isEmpty ? nil : normalized
        all[bucket] = names.isEmpty ? nil : names
        defaults.set(all, forKey: Self.deviceNamesKey)
    }

    private func deviceNames() -> [String: [String: String]] {
        defaults.dictionary(forKey: Self.deviceNamesKey) as? [String: [String: String]] ?? [:]
    }

    func loadBotTitles(dashboardID: UUID?) -> [String: String] {
        scopedNames(Self.botTitlesKey)[Self.bucket(dashboardID)] ?? [:]
    }

    func saveBotTitles(_ titles: [String: String], dashboardID: UUID?) {
        saveScopedNames(titles, key: Self.botTitlesKey, dashboardID: dashboardID)
    }

    func loadHermesNames(dashboardID: UUID?) -> [String: String] {
        scopedNames(Self.hermesNamesKey)[Self.bucket(dashboardID)] ?? [:]
    }

    func saveHermesNames(_ names: [String: String], dashboardID: UUID?) {
        saveScopedNames(names, key: Self.hermesNamesKey, dashboardID: dashboardID)
    }

    private func saveScopedNames(_ names: [String: String], key: String, dashboardID: UUID?) {
        var all = scopedNames(key)
        all[Self.bucket(dashboardID)] = names.isEmpty ? nil : names
        defaults.set(all, forKey: key)
    }

    private func scopedNames(_ key: String) -> [String: [String: String]] {
        defaults.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
    }

    /// Remove Dashboard: its labels, photos and glow colors go with it.
    func removeAll(dashboardID: UUID) {
        var deviceNames = deviceNames()
        if deviceNames.removeValue(forKey: Self.bucket(dashboardID)) != nil {
            defaults.set(deviceNames, forKey: Self.deviceNamesKey)
        }
        for key in [Self.botTitlesKey, Self.hermesNamesKey] {
            var names = scopedNames(key)
            if names.removeValue(forKey: Self.bucket(dashboardID)) != nil {
                defaults.set(names, forKey: key)
            }
        }
        var glows = glowColors()
        if glows.removeValue(forKey: Self.bucket(dashboardID)) != nil {
            defaults.set(glows, forKey: Self.glowColorsKey)
        }
        var names = defaultNames()
        if names.removeValue(forKey: Self.bucket(dashboardID)) != nil {
            defaults.set(names, forKey: Self.defaultNamesKey)
        }
        var mirrored = mirroredProfiles()
        if mirrored.removeValue(forKey: Self.bucket(dashboardID)) != nil {
            defaults.set(mirrored, forKey: Self.mirroredAvatarsKey)
        }
        if let directory = avatarsDirectory(dashboardID: dashboardID, create: false) {
            try? FileManager.default.removeItem(at: directory)
        }
        ProfileAvatarImageCache.forgetAll()
    }

    // MARK: Legacy adoption

    /// One-time move of the pre-scoping name and photos into `dashboardID`
    /// (the registry's first dashboard: the one they were chosen on).
    /// Idempotent: once the legacy key and files are gone this is a no-op,
    /// and it never overwrites a name the dashboard already has. Photos are
    /// moved, not copied; when two copies exist for the same profile, the
    /// most recently written one is kept.
    func adoptLegacyAppearance(into dashboardID: UUID) {
        if let legacyName = defaults.string(forKey: Self.legacyDefaultNameKey) {
            var names = defaultNames()
            let bucket = Self.bucket(dashboardID)
            let trimmed = legacyName.trimmingCharacters(in: .whitespacesAndNewlines)
            if names[bucket] == nil, !trimmed.isEmpty {
                names[bucket] = trimmed
                defaults.set(names, forKey: Self.defaultNamesKey)
            }
            defaults.removeObject(forKey: Self.legacyDefaultNameKey)
        }
        defaults.removeObject(forKey: Self.legacyAvatarsKey)

        let legacyFiles = legacyAvatarDirectories().flatMap(Self.avatarFiles(in:))
        guard !legacyFiles.isEmpty,
              let target = avatarsDirectory(dashboardID: dashboardID, create: true) else { return }
        // A newer legacy photo can replace one already at its destination.
        defer { ProfileAvatarImageCache.forgetAll() }
        let manager = FileManager.default
        for file in legacyFiles {
            let destination = target.appendingPathComponent(file.url.lastPathComponent)
            if manager.fileExists(atPath: destination.path) {
                if Self.modificationDate(file.url) > Self.modificationDate(destination) {
                    do {
                        _ = try manager.replaceItemAt(destination, withItemAt: file.url)
                    } catch {
                        try? manager.removeItem(at: destination)
                        try? manager.moveItem(at: file.url, to: destination)
                    }
                } else {
                    try? manager.removeItem(at: file.url)
                }
            } else {
                try? manager.moveItem(at: file.url, to: destination)
            }
        }
    }

    // MARK: Paths

    private static func bucket(_ dashboardID: UUID?) -> String {
        dashboardID?.uuidString ?? unscopedBucket
    }

    private func avatarsRoot(create: Bool) -> URL? {
        if let avatarsRootOverride {
            if create { try? FileManager.default.createDirectory(at: avatarsRootOverride, withIntermediateDirectories: true) }
            return avatarsRootOverride
        }
        let manager = FileManager.default
        guard let base = try? manager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: create) else { return nil }
        return base.appendingPathComponent("profile-avatars", isDirectory: true)
    }

    private func avatarsDirectory(dashboardID: UUID?, create: Bool) -> URL? {
        guard let root = avatarsRoot(create: create) else { return nil }
        let directory = root.appendingPathComponent(Self.bucket(dashboardID), isDirectory: true)
        if create {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return nil
            }
        }
        return directory
    }

    /// Where photos lived before scoping: loose files directly in the avatars
    /// root, and an older Application Support folder.
    private func legacyAvatarDirectories() -> [URL] {
        if let legacyAvatarDirectoriesOverride { return legacyAvatarDirectoriesOverride }
        var directories: [URL] = []
        if let root = avatarsRoot(create: false) { directories.append(root) }
        if let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            directories.append(base.appendingPathComponent("ProfileAvatars", isDirectory: true))
        }
        return directories
    }

    private static func avatarFiles(in directory: URL) -> [(profile: String, url: URL)] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )) ?? []
        return urls.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let profile = profileName(from: url) else { return nil }
            return (profile, url)
        }
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    static func fileName(for profile: String) -> String {
        let encoded = profile.data(using: .utf8)?.base64EncodedString() ?? "default"
        let safe = encoded.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return "profile-\(safe).jpg"
    }

    private static func profileName(from url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix("profile-") else { return nil }
        var encoded = String(stem.dropFirst("profile-".count))
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "-", with: "+")
        while encoded.count % 4 != 0 { encoded.append("=") }
        guard let data = Data(base64Encoded: encoded), let name = String(data: data, encoding: .utf8), !name.isEmpty else { return nil }
        return name
    }
}

/// What a roster refresh does about one profile's photo.
enum ProfileAvatarSyncAction: Equatable {
    /// Hermes has a picture: fetch it and keep the copy on disk.
    case fetch
    /// The photo on disk was picked on this device before photos moved to
    /// Hermes: upload it, so the picture the person chose carries over.
    case upload
    /// The copy of a Hermes picture that was removed elsewhere: delete it.
    case dropMirror
    case keep

    static func action(hermesHasAvatar: Bool, hasPhotoOnDevice: Bool, photoIsMirror: Bool) -> ProfileAvatarSyncAction {
        if hermesHasAvatar { return .fetch }
        guard hasPhotoOnDevice else { return .keep }
        return photoIsMirror ? .dropMirror : .upload
    }
}

enum ProfileAppearanceError: LocalizedError {
    case invalidImage
    var errorDescription: String? { AppLocalization.string("That photo could not be read.") }
}


/// Profile photos decoded once, at the largest size an avatar shows. An
/// avatar sits in the live reply and thinking rows, whose bodies run at
/// streaming rate; reading and decoding the whole photo there cost a disk
/// read and a full-size image decode per frame. A saved or removed photo
/// keeps its file name, so the store drops the entry when it writes.
@MainActor
enum ProfileAvatarImageCache {
    /// The largest avatar is 48 pt (the profile picker); 192 px covers it
    /// at 3x with room to spare.
    static let maxPixelSize: CGFloat = 192

    /// A 192 px bitmap is ~150 KB, so the count bounds the memory too.
    private static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 32
        return cache
    }()
    /// When each photo last failed to decode, so a missing or damaged file
    /// is retried now and then rather than on every redraw, and a passing
    /// failure (a file not readable yet) doesn't hide the photo for good.
    private static var failedReads: [String: TimeInterval] = [:]
    static let failedReadRetryInterval: TimeInterval = 30

    /// The first show of each photo decodes it here, on the main actor, so
    /// the avatar never flashes its initials. ImageIO reads the file once
    /// and builds the thumbnail without decoding the photo at full size.
    static func image(at url: URL) -> UIImage? {
        let key = url.path as NSString
        if let cached = images.object(forKey: key) { return cached }
        let now = ProcessInfo.processInfo.systemUptime
        if let failedAt = failedReads[url.path], now - failedAt < failedReadRetryInterval { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            failedReads[url.path] = now
            return nil
        }
        let image = UIImage(cgImage: thumbnail)
        failedReads[url.path] = nil
        images.setObject(image, forKey: key)
        return image
    }

    static func forget(_ url: URL) {
        images.removeObject(forKey: url.path as NSString)
        failedReads[url.path] = nil
    }

    static func forgetAll() {
        images.removeAllObjects()
        failedReads.removeAll()
    }
}
