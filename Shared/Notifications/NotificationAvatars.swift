import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Bot pictures on notifications: each push shows the face of the bot it
/// is from, not Conduit's icon (iOS Communication Notifications).
///
/// The app keeps its profile photos in its own Documents
/// (ProfileAppearanceStore), which the Notification Service Extension
/// can't read. Every write there leaves a small still copy here, in the app
/// group, so the extension finds the bot's face offline, at once, and
/// without Conduit running: a moving picture's first frame, at most
/// `maxPixels` on a side, as PNG. Copies are scoped to the saved dashboard
/// as the photos are (#148: every Hermes has a "default"), and keyed by the
/// profile id trimmed and lowercased, as routing reads it.
enum NotificationAvatars {
    static let directoryName = "notification-avatars"
    /// Notifications draw the face at most about 60 pt; 3x plus headroom.
    static let maxPixels = 256
    private static let unscopedBucket = "unscoped"

    /// The app group folder; nil where the target has no app group (the
    /// Watch, a unit test host without the entitlement).
    static var sharedRoot: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: NotificationE2E.appGroup)?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The profile id as routing reads it, nil when empty.
    static func profileKey(_ profile: String?) -> String? {
        let key = profile?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return key.isEmpty ? nil : key
    }

    /// A dashboard id in any case spelling, as the photos' folder names it.
    static func bucket(_ dashboardID: String?) -> String {
        dashboardID.flatMap(UUID.init(uuidString:))?.uuidString ?? unscopedBucket
    }

    static func fileName(for profileKey: String) -> String {
        let encoded = Data(profileKey.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return "profile-\(encoded).png"
    }

    static func url(profile: String?, dashboardID: String?, root: URL?) -> URL? {
        guard let root, let key = profileKey(profile) else { return nil }
        return root
            .appendingPathComponent(bucket(dashboardID), isDirectory: true)
            .appendingPathComponent(fileName(for: key), isDirectory: false)
    }

    /// The copy's bytes for the extension; nil when the bot has no picture
    /// here yet, which keeps Conduit's icon on that push.
    static func picture(profile: String?, dashboardID: String?, root: URL? = sharedRoot) -> Data? {
        guard let url = url(profile: profile, dashboardID: dashboardID, root: root) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Writes the still copy of `source` (PNG, JPEG, WebP or APNG).
    /// Returns false when the bytes aren't an image or the folder can't be
    /// written; the push then shows Conduit's icon, as before.
    @discardableResult
    static func store(_ source: Data, profile: String?, dashboardID: String?, root: URL? = sharedRoot) -> Bool {
        guard let url = url(profile: profile, dashboardID: dashboardID, root: root),
              let still = stillPNG(source) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if (try? Data(contentsOf: url)) != still { try still.write(to: url, options: .atomic) }
            return true
        } catch {
            return false
        }
    }

    static func remove(profile: String?, dashboardID: String?, root: URL? = sharedRoot) {
        guard let url = url(profile: profile, dashboardID: dashboardID, root: root) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Remove Dashboard: its pictures go with its photos.
    static func removeAll(dashboardID: String?, root: URL? = sharedRoot) {
        guard let root else { return }
        try? FileManager.default.removeItem(
            at: root.appendingPathComponent(bucket(dashboardID), isDirectory: true)
        )
    }

    /// Whether the copy is missing or older than the photo it came from, for
    /// the launch pass that fills in photos saved before this existed.
    static func needsCopy(of source: URL, profile: String?, dashboardID: String?, root: URL? = sharedRoot) -> Bool {
        guard let copy = url(profile: profile, dashboardID: dashboardID, root: root) else { return false }
        func modified(_ url: URL) -> Date? {
            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        guard let copied = modified(copy) else { return true }
        return (modified(source) ?? .distantFuture) > copied
    }

    /// The first frame, scaled down to `maxPixels` on its longer side
    /// (never up), as PNG so a transparent picture stays transparent.
    static func stillPNG(_ data: Data, maxPixels: Int = maxPixels) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: The sender iOS shows

    /// Who a push is from, as iOS's communication notification shows it:
    /// the bot, with its face, in a conversation per chat. `groupName` is
    /// the notification's own title ("Response ready", a chat's title),
    /// so the push keeps the title it had above the bot's name (the
    /// subtitle Conduit already wrote), instead of iOS replacing it with
    /// the sender's name; nil when the title is only the bot's name.
    struct Sender: Equatable {
        let handle: String
        let displayName: String
        let conversationID: String
        let groupName: String?
    }

    /// nil when the push names no profile: it has no bot to show.
    static func sender(
        profile: String?, dashboardID: String?, botName: String, title: String, conversation: String?
    ) -> Sender? {
        guard let key = profileKey(profile) else { return nil }
        let handle = "conduit:\(bucket(dashboardID))/\(key)"
        let chat = conversation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return Sender(
            handle: handle,
            displayName: botName,
            conversationID: chat.isEmpty ? handle : "\(handle)/\(chat)",
            groupName: heading.isEmpty || heading == botName ? nil : heading
        )
    }
}
