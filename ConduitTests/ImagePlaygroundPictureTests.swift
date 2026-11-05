import UIKit
import XCTest
@testable import Conduit

/// Image Playground as a picture source (ImagePlaygroundPicture). An
/// extension rather than its own class: the hosted CI planner balances
/// shards per class.
extension BotModeTests {
    func testImagePlaygroundAvailabilitySplitsCanTurnOnFromNever() {
        let eight: UInt64 = 7_900_000_000
        let six: UInt64 = 5_900_000_000
        XCTAssertEqual(ImagePlaygroundPicture.availability(supported: true, osSupports: true, physicalMemory: eight), .available)
        // Apple Intelligence off, still setting up, or Siri's language unsupported.
        XCTAssertEqual(ImagePlaygroundPicture.availability(supported: false, osSupports: true, physicalMemory: eight), .canTurnOn)
        // An iPhone 15 or older can never turn it on.
        XCTAssertEqual(ImagePlaygroundPicture.availability(supported: false, osSupports: true, physicalMemory: six), .unavailable)
        // iOS 17 has no Image Playground at all.
        XCTAssertEqual(ImagePlaygroundPicture.availability(supported: false, osSupports: false, physicalMemory: eight), .unavailable)
    }

    func testImagePlaygroundPromptTrimsAndCapsWhatItStartsFrom() {
        let prompt = ImagePlaygroundPicture.Prompt(name: "  Furina \n", details: [" A cheerful archivist ", "", "\n"])
        XCTAssertEqual(prompt.name, "Furina")
        XCTAssertEqual(prompt.details, "A cheerful archivist")

        let soul = String(repeating: "x", count: ImagePlaygroundPicture.maxExtractedLength + 500)
        let long = ImagePlaygroundPicture.Prompt(name: "Yelan", details: ["Spy", soul])
        XCTAssertEqual(long.details.count, ImagePlaygroundPicture.maxExtractedLength)
        XCTAssertTrue(long.details.hasPrefix("Spy\n\n"))

        XCTAssertEqual(ImagePlaygroundPicture.Prompt(name: "").details, "")

        let name = String(repeating: "n", count: ImagePlaygroundPicture.maxNameLength + 40)
        XCTAssertEqual(ImagePlaygroundPicture.Prompt(name: name).name.count, ImagePlaygroundPicture.maxNameLength)
    }

    func testImagePlaygroundResultIsReadThenRemoved() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("playground-\(UUID().uuidString).png")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).pngData { context in
            UIColor.purple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        try png.write(to: url)
        let image = try XCTUnwrap(ImagePlaygroundPicture.image(at: url))
        XCTAssertEqual(image.size.width * image.scale, 64)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(BotAvatarImage.normalizedPNG(from: image))

        XCTAssertNil(ImagePlaygroundPicture.image(at: url))
    }
}
