//
//  ProfileAppearanceStore.swift
//  Conduit
//
//  Profile presentation is deliberately device-local. Hermes owns the
//  profile identifiers and configuration; a person's chosen label/photo must
//  travel neither to the gateway nor between accounts.
//
//  It is also scoped to one saved dashboard (#148). Every Hermes server has
//  a profile called "default", so a label or photo keyed by profile name
//  alone showed dashboard A's "default" name and picture on dashboard B.
//  Names live in a per-dashboard map; photos live in a per-dashboard
//  subdirectory whose file names encode the profile.
//

import Foundation
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
        return url
    }

    func removeAvatar(for profile: String, dashboardID: UUID?) {
        guard let directory = avatarsDirectory(dashboardID: dashboardID, create: false) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.fileName(for: profile)))
    }

    /// Remove Dashboard: its label and photos go with it.
    func removeAll(dashboardID: UUID) {
        var names = defaultNames()
        if names.removeValue(forKey: Self.bucket(dashboardID)) != nil {
            defaults.set(names, forKey: Self.defaultNamesKey)
        }
        if let directory = avatarsDirectory(dashboardID: dashboardID, create: false) {
            try? FileManager.default.removeItem(at: directory)
        }
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

enum ProfileAppearanceError: LocalizedError {
    case invalidImage
    var errorDescription: String? { AppLocalization.string("That photo could not be read.") }
}
