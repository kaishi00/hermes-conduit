import ImageIO
import UIKit
import XCTest
@testable import Conduit

/// Moving bot and profile pictures (AnimatedAvatar). An extension rather
/// than its own class: the hosted CI planner balances shards per class.
extension BotModeTests {
    private func solidFrame(_ color: UIColor, width: Int = 320, height: Int = 240) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.cgImage!
    }

    private func frames(_ count: Int, delay: Double = 0.1) -> [AnimatedAvatar.Frame] {
        let colors: [UIColor] = [.red, .green, .blue, .orange]
        return (0..<count).map { AnimatedAvatar.Frame(image: solidFrame(colors[$0 % colors.count]), delay: delay) }
    }

    func testAnimatedAvatarEncodesALoopingSquareAPNGUnderTheCap() throws {
        let data = try AnimatedAvatar.encode(frames(6)).get()
        XCTAssertLessThanOrEqual(data.count, AnimatedAvatar.maxBytes)
        // PNG bytes, which Hermes' asset store sniffs and keeps as avatar.png.
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertTrue(AnimatedAvatar.isAnimated(data))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 6)
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(first.width, 256)
        XCTAssertEqual(first.height, 256)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 1, nil) as? [CFString: Any] ?? [:]
        XCTAssertEqual(AnimatedAvatar.frameDelay(properties), 0.1, accuracy: 0.01)
        // The still every list draws is its first frame.
        XCTAssertNotNil(UIImage(data: data))
    }

    func testAnimatedAvatarReadsBackItsOwnFrames() throws {
        let data = try AnimatedAvatar.encode(frames(4, delay: 0.25)).get()
        let read = try XCTUnwrap(AnimatedAvatar.frames(from: data))
        XCTAssertEqual(read.count, 4)
        XCTAssertEqual(read.reduce(0) { $0 + $1.delay }, 1.0, accuracy: 0.05)
    }

    func testAnimatedAvatarStopsReadingAfterTheLongestLoop() throws {
        // 8 s of frames: only the first maxDuration seconds are kept.
        let data = try XCTUnwrap(AnimatedAvatar.apng(frames(16, delay: 0.5), edge: 64))
        let read = try XCTUnwrap(AnimatedAvatar.frames(from: data))
        XCTAssertEqual(read.count, Int(AnimatedAvatar.maxDuration / 0.5))
    }

    func testAnimatedAvatarThinningKeepsTheLoopLength() {
        let thinned = AnimatedAvatar.thinned(frames(10), to: 4)
        XCTAssertLessThanOrEqual(thinned.count, 4)
        XCTAssertEqual(thinned.reduce(0) { $0 + $1.delay }, 1.0, accuracy: 0.0001)
        XCTAssertEqual(AnimatedAvatar.thinned(frames(3), to: 4).count, 3)
    }

    func testAnimatedAvatarTreatsTinyDelaysAsTenFramesASecond() {
        let gif: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: 0.0]]
        XCTAssertEqual(AnimatedAvatar.frameDelay(gif), AnimatedAvatar.defaultDelay)
        let png: [CFString: Any] = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.04]]
        XCTAssertEqual(AnimatedAvatar.frameDelay(png), 0.04, accuracy: 0.0001)
        XCTAssertEqual(AnimatedAvatar.frameDelay([:]), AnimatedAvatar.defaultDelay)
    }

    func testAStillIsNotAnimated() throws {
        let still = try XCTUnwrap(UIImage(cgImage: solidFrame(.red)).pngData())
        XCTAssertFalse(AnimatedAvatar.isAnimated(still))
        XCTAssertNil(AnimatedAvatar.frames(from: still))
    }

    func testOnDevicePhotoKeepsAMovingPictureAsItIs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "animated-avatar-\(UUID().uuidString)"))
        let store = ProfileAppearanceStore(defaults: defaults, avatarsRoot: root, legacyAvatarDirectories: [])
        let apng = try AnimatedAvatar.encode(frames(3)).get()
        let url = try store.saveAvatar(apng, for: "ada", dashboardID: nil)
        XCTAssertEqual(try Data(contentsOf: url), apng)
        XCTAssertTrue(ProfileAvatarImageCache.isAnimated(at: url))
        let revision = ProfileAvatarImageCache.revision(of: url)

        // A still replaces it: the cache forgets it moved, and a face
        // playing the file restarts on the new revision.
        let still = try XCTUnwrap(UIImage(cgImage: solidFrame(.blue)).pngData())
        _ = try store.saveAvatar(still, for: "ada", dashboardID: nil)
        XCTAssertFalse(ProfileAvatarImageCache.isAnimated(at: url))
        XCTAssertNotEqual(ProfileAvatarImageCache.revision(of: url), revision)
    }
}
