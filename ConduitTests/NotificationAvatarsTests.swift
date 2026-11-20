import ImageIO
import UIKit
import XCTest
@testable import Conduit

/// Bot pictures on notifications (NotificationAvatars): the still copies
/// the app leaves for the Notification Service Extension, and the sender
/// iOS shows. An extension rather than its own class: the hosted CI planner
/// balances shards per class.
extension BotModeTests {
    private func notificationPicture(_ color: UIColor, width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func pixelSize(_ data: Data) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    func testANotificationPictureIsASmallStillCopy() throws {
        let still = try XCTUnwrap(NotificationAvatars.stillPNG(notificationPicture(.red, width: 1200, height: 800)))
        let size = try pixelSize(still)
        XCTAssertEqual(max(size.width, size.height), NotificationAvatars.maxPixels)
        // Never scaled up.
        let small = try XCTUnwrap(NotificationAvatars.stillPNG(notificationPicture(.red, width: 64, height: 64)))
        XCTAssertEqual(try pixelSize(small).width, 64)
        // A moving picture leaves its first frame.
        let frame: (UIColor) throws -> AnimatedAvatar.Frame = { (color: UIColor) in
            let image = try XCTUnwrap(UIImage(data: self.notificationPicture(color, width: 120, height: 120)))
            let cgImage = try XCTUnwrap(image.cgImage)
            return AnimatedAvatar.Frame(image: cgImage, delay: 0.1)
        }
        let apng = try AnimatedAvatar.encode([try frame(.red), try frame(.blue)]).get()
        let first = try XCTUnwrap(NotificationAvatars.stillPNG(apng))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(first as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        XCTAssertNil(NotificationAvatars.stillPNG(Data("not a picture".utf8)))
    }

    func testTheStoreLeavesTheExtensionACopyOfEveryPhotoWrite() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let shared = base.appendingPathComponent("shared")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "notification-avatars-\(UUID().uuidString)"))
        let store = ProfileAppearanceStore(
            defaults: defaults, avatarsRoot: base.appendingPathComponent("photos"),
            legacyAvatarDirectories: [], notificationAvatars: shared
        )
        let dashboard = UUID()
        let picture = notificationPicture(.green, width: 400, height: 400)

        _ = try store.saveMirroredAvatar(picture, for: "Cortana", dashboardID: dashboard)
        // Found the way a push names it: the id in any case, the dashboard
        // id in any case.
        XCTAssertNotNil(NotificationAvatars.picture(profile: " cortana ", dashboardID: dashboard.uuidString.lowercased(), root: shared))
        XCTAssertNil(NotificationAvatars.picture(profile: "cortana", dashboardID: UUID().uuidString, root: shared), "another dashboard's Cortana")

        store.removeAvatar(for: "Cortana", dashboardID: dashboard)
        XCTAssertNil(NotificationAvatars.picture(profile: "cortana", dashboardID: dashboard.uuidString, root: shared))

        _ = try store.saveAvatar(picture, for: "ada", dashboardID: dashboard)
        XCTAssertNotNil(NotificationAvatars.picture(profile: "ada", dashboardID: dashboard.uuidString, root: shared))
        store.removeAll(dashboardID: dashboard)
        XCTAssertNil(NotificationAvatars.picture(profile: "ada", dashboardID: dashboard.uuidString, root: shared))

        // A test store with its own photos folder never writes the app group.
        let isolated = ProfileAppearanceStore(defaults: defaults, avatarsRoot: base.appendingPathComponent("other"), legacyAvatarDirectories: [])
        _ = try isolated.saveAvatar(picture, for: "zed", dashboardID: dashboard)
        XCTAssertNil(NotificationAvatars.picture(profile: "zed", dashboardID: dashboard.uuidString))
    }

    func testTheLaunchPassCopiesPhotosSavedBeforeTheCopiesExisted() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let photos = base.appendingPathComponent("photos")
        let shared = base.appendingPathComponent("shared")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "notification-avatars-\(UUID().uuidString)"))
        let dashboard = UUID()
        // Saved by a build without the copies.
        _ = try ProfileAppearanceStore(defaults: defaults, avatarsRoot: photos, legacyAvatarDirectories: [])
            .saveAvatar(notificationPicture(.orange, width: 300, height: 300), for: "jarvis", dashboardID: dashboard)
        XCTAssertNil(NotificationAvatars.picture(profile: "jarvis", dashboardID: dashboard.uuidString, root: shared))

        ProfileAppearanceStore.shareAvatars(under: photos, with: shared)
        XCTAssertNotNil(NotificationAvatars.picture(profile: "jarvis", dashboardID: dashboard.uuidString, root: shared))
        let copy = try XCTUnwrap(NotificationAvatars.url(profile: "jarvis", dashboardID: dashboard.uuidString, root: shared))
        let source = photos.appendingPathComponent(dashboard.uuidString).appendingPathComponent(ProfileAppearanceStore.fileName(for: "jarvis"))
        XCTAssertFalse(NotificationAvatars.needsCopy(of: source, profile: "jarvis", dashboardID: dashboard.uuidString, root: shared))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
    }

    func testANotificationIsFromItsBotInAConversationPerChat() throws {
        let dashboard = UUID().uuidString
        let sender = try XCTUnwrap(NotificationAvatars.sender(
            profile: "Angelos", dashboardID: dashboard.lowercased(), botName: "Angelos",
            title: "Response ready", conversation: "session-1"
        ))
        XCTAssertEqual(sender.handle, "conduit:\(dashboard.uppercased())/angelos")
        XCTAssertEqual(sender.displayName, "Angelos")
        XCTAssertEqual(sender.conversationID, "conduit:\(dashboard.uppercased())/chat/session-1")
        // The push keeps its own title above the bot's name.
        XCTAssertEqual(sender.groupName, "Response ready")

        // Two bots' pushes for one chat join one conversation.
        let second = try XCTUnwrap(NotificationAvatars.sender(
            profile: "Kaleb", dashboardID: dashboard.lowercased(), botName: "Kaleb",
            title: "Response ready", conversation: "session-1"
        ))
        XCTAssertEqual(second.conversationID, sender.conversationID)
        XCTAssertNotEqual(second.handle, sender.handle)

        let call = try XCTUnwrap(NotificationAvatars.sender(
            profile: "kaleb", dashboardID: nil, botName: "Kaleb", title: "Kaleb", conversation: nil
        ))
        XCTAssertNil(call.groupName, "a title that is only the bot's name")
        XCTAssertEqual(call.conversationID, "conduit:unscoped/kaleb")
        XCTAssertNil(NotificationAvatars.sender(profile: "  ", dashboardID: dashboard, botName: "Hermes", title: "x", conversation: nil))
    }

    func testTheLaunchPassNeverOverwritesAFreshCopyWithStaleBytes() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let photos = base.appendingPathComponent("photos")
        let shared = base.appendingPathComponent("shared")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "notification-avatars-\(UUID().uuidString)"))
        let dashboard = UUID()
        let profile = "jarvis"
        let store = ProfileAppearanceStore(
            defaults: defaults, avatarsRoot: photos, legacyAvatarDirectories: [], notificationAvatars: shared
        )
        _ = try store.saveAvatar(notificationPicture(.orange, width: 300, height: 300), for: profile, dashboardID: dashboard)
        // The pass's premise: a photo with no copy (one deleted, or saved by
        // a build without the copies).
        NotificationAvatars.remove(profile: profile, dashboardID: dashboard.uuidString, root: shared)
        // The pass reads the photo here, and a newer photo (with its own
        // fresh copy) lands before the pass commits.
        let work = ProfileAppearanceStore.copyWork(under: photos, with: shared)
        _ = try store.saveAvatar(notificationPicture(.blue, width: 300, height: 300), for: profile, dashboardID: dashboard)
        // The blue save's own copy, as it must stay: a save's copy is a
        // still of the JPEG the store keeps, so the expectation is the
        // copy itself, not a still of the raw picture.
        let freshCopy = try XCTUnwrap(NotificationAvatars.picture(profile: profile, dashboardID: dashboard.uuidString, root: shared))
        ProfileAppearanceStore.commit(work, with: shared)
        XCTAssertEqual(
            NotificationAvatars.picture(profile: profile, dashboardID: dashboard.uuidString, root: shared),
            freshCopy,
            "the pass's stale read must not overwrite the newer copy"
        )

        // A photo removed while the pass ran gets no copy back.
        NotificationAvatars.remove(profile: profile, dashboardID: dashboard.uuidString, root: shared)
        let stale = ProfileAppearanceStore.copyWork(under: photos, with: shared)
        XCTAssertFalse(stale.isEmpty, "the pass saw the photo before its removal")
        store.removeAvatar(for: profile, dashboardID: dashboard)
        ProfileAppearanceStore.commit(stale, with: shared)
        XCTAssertNil(NotificationAvatars.picture(profile: profile, dashboardID: dashboard.uuidString, root: shared))

        // The whole pass still fills in a copy when nothing changed under it.
        _ = try store.saveAvatar(notificationPicture(.green, width: 300, height: 300), for: profile, dashboardID: dashboard)
        NotificationAvatars.remove(profile: profile, dashboardID: dashboard.uuidString, root: shared)
        ProfileAppearanceStore.shareAvatars(under: photos, with: shared)
        // A copy is a still of the JPEG the store keeps, not of the raw
        // picture, so the expectation comes from the photo's own bytes.
        let photo = try XCTUnwrap(try? Data(contentsOf: XCTUnwrap(store.loadAvatarURLs(dashboardID: dashboard)[profile])))
        XCTAssertEqual(
            NotificationAvatars.picture(profile: profile, dashboardID: dashboard.uuidString, root: shared),
            NotificationAvatars.stillPNG(photo)
        )
    }
}
