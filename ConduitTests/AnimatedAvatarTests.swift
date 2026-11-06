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

    func testBotAvatarDecodesDownsampledNotAtItsOwnSize() async throws {
        // Hermes takes pictures up to 2 MB; one this size decoded whole is
        // 36 MB per bot, for a face drawn at 72 pt at most (#1829).
        let large = try XCTUnwrap(UIImage(cgImage: solidFrame(.red, width: 3000, height: 2000)).pngData())
        let image = await AppState.botAvatarThumbnail(large)
        let pixels = try XCTUnwrap(image?.cgImage)
        XCTAssertEqual(max(pixels.width, pixels.height), Int(AppState.botAvatarMaxPixelSize))
        // 512 × 341: the shape is kept, to the pixel ImageIO rounds.
        XCTAssertEqual(Double(pixels.width) / Double(pixels.height), 1.5, accuracy: 0.01, "The shape is kept")

        let small = try XCTUnwrap(UIImage(cgImage: solidFrame(.blue, width: 64, height: 64)).pngData())
        let kept = await AppState.botAvatarThumbnail(small)
        XCTAssertEqual(kept?.cgImage?.width, 64, "A small picture isn't enlarged")

        let notAPicture = await AppState.botAvatarThumbnail(Data("not a picture".utf8))
        XCTAssertNil(notAPicture)
        let nothing = await AppState.botAvatarThumbnail(nil)
        XCTAssertNil(nothing)
    }

    func testKeptBotChatCopiesDropTheLeastRecentlyKeptPastTheirCount() {
        // Up to 500 rows each, kept for the run: bounded by count (#1831).
        let start = Date(timeIntervalSince1970: 1_000)
        var kept: [String: Date] = [:]
        for index in 0..<AppState.maxKeptBotChatCopies {
            XCTAssertNil(AppState.keptBotChatCopyToDrop(keptAt: kept, adding: "bot\(index)"))
            kept["bot\(index)"] = start.addingTimeInterval(TimeInterval(index))
        }
        kept["bot0"] = start.addingTimeInterval(100)
        XCTAssertEqual(AppState.keptBotChatCopyToDrop(keptAt: kept, adding: "new"), "bot1")
        XCTAssertNil(AppState.keptBotChatCopyToDrop(keptAt: kept, adding: "bot3"), "Kept again in place")
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

    func testAPhoneOnlyMovingPictureGoesToHermesAsItIs() throws {
        let apng = try AnimatedAvatar.encode(frames(3)).get()
        XCTAssertEqual(BotAvatarImage.hermesPicture(fromPhoneCopy: apng), apng)
        // A still is normalized to the stored square, as before.
        let still = try XCTUnwrap(UIImage(cgImage: solidFrame(.red)).pngData())
        let stored = try XCTUnwrap(BotAvatarImage.hermesPicture(fromPhoneCopy: still))
        XCTAssertEqual(UIImage(data: stored)?.size, CGSize(width: BotManagement.avatarEdge, height: BotManagement.avatarEdge))
        XCTAssertNil(BotAvatarImage.hermesPicture(fromPhoneCopy: Data("not a picture".utf8)))
    }

    func testChooseGIFOrVideoKeepsAMovingPicksFileAndReadsAStill() throws {
        // Choose Photo's crop hands over one frame of a GIF (Eric,
        // 2026-11-05), so moving pictures come through the Photos picker's
        // own file: a moving one is kept to be made into an APNG.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let moving = dir.appendingPathComponent("loop.png")
        try AnimatedAvatar.encode(frames(3)).get().write(to: moving)
        guard case .animation(.image(let kept)) = AnimatedAvatar.pick(fileAt: moving) else {
            return XCTFail("A moving picture should be kept as an animation")
        }
        XCTAssertEqual(kept, moving)

        let movie = dir.appendingPathComponent("clip.mov")
        try Data("not read yet".utf8).write(to: movie)
        guard case .animation(.movie(let keptMovie)) = AnimatedAvatar.pick(fileAt: movie) else {
            return XCTFail("A video should be kept as an animation")
        }
        XCTAssertEqual(keptMovie, movie)

        // A still picked there is used as any photo, and its copy deleted.
        let still = dir.appendingPathComponent("still.png")
        try XCTUnwrap(UIImage(cgImage: solidFrame(.red)).pngData()).write(to: still)
        guard case .still = AnimatedAvatar.pick(fileAt: still) else {
            return XCTFail("A still should be read as one")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: still.path))

        // A name that doesn't say: a picture is still read by its bytes,
        // anything else goes to the video reader rather than into memory.
        let unnamedStill = dir.appendingPathComponent("picked")
        try XCTUnwrap(UIImage(cgImage: solidFrame(.blue)).pngData()).write(to: unnamedStill)
        guard case .still = AnimatedAvatar.pick(fileAt: unnamedStill) else {
            return XCTFail("A still without an extension should be read as one")
        }
        let unnamedOther = dir.appendingPathComponent("clip")
        try Data("not a picture".utf8).write(to: unnamedOther)
        guard case .animation(.movie) = AnimatedAvatar.pick(fileAt: unnamedOther) else {
            return XCTFail("A file that isn't a picture should go to the video reader")
        }
    }

    func testChooseGIFOrVideoWritesMovingBytesToAFileOfTheirOwn() throws {
        let apng = try AnimatedAvatar.encode(frames(3)).get()
        guard case .animation(.image(let url)) = AnimatedAvatar.pick(data: apng) else {
            return XCTFail("Moving bytes should become an animation")
        }
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try Data(contentsOf: url), apng)
        guard case .still = AnimatedAvatar.pick(data: try XCTUnwrap(UIImage(cgImage: solidFrame(.red)).pngData())) else {
            return XCTFail("A still's bytes should be read as one")
        }
        guard case .unreadable = AnimatedAvatar.pick(data: Data("not a picture".utf8)) else {
            return XCTFail("Bytes that aren't a picture can't be used")
        }
    }

    func testBringToLifeLoopsWithoutAJump() {
        let start = LivingPortrait.pose(at: 0)
        let end = LivingPortrait.pose(at: LivingPortrait.loopDuration)
        XCTAssertEqual(start.scale, end.scale, accuracy: 1e-9)
        XCTAssertEqual(start.rotation, end.rotation, accuracy: 1e-9)
        XCTAssertEqual(start.dx, end.dx, accuracy: 1e-9)
        XCTAssertEqual(start.dy, end.dy, accuracy: 1e-9)
        // The subject never shrinks past its own place in the background.
        for step in 0..<LivingPortrait.frameCount {
            XCTAssertGreaterThan(LivingPortrait.pose(at: Double(step) * 0.0833).scale, 1)
        }
    }

    func testBringToLifeMakesALoopingPictureUnderTheCap() throws {
        // Vision needs a device, so the subject here is drawn by hand: a
        // disc with the rest transparent, as Vision's cut-out is.
        let side = LivingPortrait.edge
        let background = try XCTUnwrap(LivingPortrait.softened(solidFrame(.blue, width: side, height: side)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let subject = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor.orange.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 64, y: 64, width: 128, height: 128))
        }.cgImage)
        let frames = LivingPortrait.frames(background: background, subject: subject)
        XCTAssertEqual(frames.count, LivingPortrait.frameCount)
        XCTAssertEqual(frames.reduce(0) { $0 + $1.delay }, LivingPortrait.loopDuration, accuracy: 0.001)
        XCTAssertNotEqual(frames[0].image.dataProvider?.data as Data?, frames[9].image.dataProvider?.data as Data?, "The subject moves")
        let data = try AnimatedAvatar.encode(frames).get()
        XCTAssertTrue(AnimatedAvatar.isAnimated(data))
        XCTAssertLessThanOrEqual(data.count, AnimatedAvatar.maxBytes)
    }

    func testBringToLifeSaysWhenThereIsNoSubject() {
        XCTAssertEqual(
            LivingPortrait.message(for: .noSubject),
            AppLocalization.string("No subject was found in that picture to bring to life.")
        )
    }
}
