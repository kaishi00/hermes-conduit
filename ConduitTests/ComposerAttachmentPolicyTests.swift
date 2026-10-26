//
//  ComposerAttachmentPolicyTests.swift
//  ConduitTests
//
//  Naming, typing and size rules for composer attachments (#334): picked
//  videos keep their real type instead of becoming "photo.jpg", images
//  providers can't read are re-encoded as JPEG, and the device-only size
//  limit defaults to Hermes Desktop's 16 MB.
//

import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Conduit

final class ComposerAttachmentPolicyTests: XCTestCase {
    // MARK: - Types

    func testVideosAreVideosNotPhotos() {
        XCTAssertEqual(AttachmentTypePolicy.kind(for: .mpeg4Movie), .video)
        XCTAssertEqual(AttachmentTypePolicy.kind(for: .quickTimeMovie), .video)
        XCTAssertEqual(AttachmentTypePolicy.mimeType(for: .mpeg4Movie), "video/mp4")
        XCTAssertEqual(AttachmentTypePolicy.mimeType(for: .quickTimeMovie), "video/quicktime")
    }

    func testImagesAndDocumentsKeepTheirKinds() {
        XCTAssertEqual(AttachmentTypePolicy.kind(for: .png), .image)
        XCTAssertEqual(AttachmentTypePolicy.kind(for: .heic), .image)
        XCTAssertEqual(AttachmentTypePolicy.kind(for: .pdf), .document)
        XCTAssertEqual(AttachmentTypePolicy.kind(for: nil), .document)
        XCTAssertEqual(AttachmentTypePolicy.mimeType(for: nil), "application/octet-stream")
    }

    func testOnlyImagesProvidersCantReadAreTranscoded() {
        XCTAssertTrue(AttachmentTypePolicy.needsJPEGTranscode(.heic))
        XCTAssertTrue(AttachmentTypePolicy.needsJPEGTranscode(.tiff))
        XCTAssertFalse(AttachmentTypePolicy.needsJPEGTranscode(.jpeg))
        XCTAssertFalse(AttachmentTypePolicy.needsJPEGTranscode(.png))
        XCTAssertFalse(AttachmentTypePolicy.needsJPEGTranscode(.gif))
        XCTAssertFalse(AttachmentTypePolicy.needsJPEGTranscode(.webP))
        XCTAssertFalse(AttachmentTypePolicy.needsJPEGTranscode(.mpeg4Movie))
        XCTAssertFalse(AttachmentTypePolicy.needsJPEGTranscode(nil))
        XCTAssertEqual(AttachmentTypePolicy.jpegFilename(for: "IMG_0001.HEIC"), "IMG_0001.jpg")
    }

    // MARK: - Names

    func testRealFileNameIsKept() {
        XCTAssertEqual(
            AttachmentTypePolicy.filename(suggested: "ScreenRecording_10-03.MP4", type: .mpeg4Movie),
            "ScreenRecording_10-03.MP4"
        )
    }

    func testNameWithoutExtensionGetsOneFromItsType() {
        XCTAssertEqual(AttachmentTypePolicy.filename(suggested: "clip", type: .quickTimeMovie), "clip.mov")
    }

    func testMissingNameFallsBackByKindAndOrder() {
        XCTAssertEqual(AttachmentTypePolicy.filename(suggested: nil, type: .png), "photo.png")
        XCTAssertEqual(AttachmentTypePolicy.filename(suggested: "  ", type: .mpeg4Movie, ordinal: 3), "video-3.mp4")
        XCTAssertEqual(AttachmentTypePolicy.filename(suggested: nil, type: nil, ordinal: 2), "file-2")
    }

    func testDetailLabelShowsTypeAndSize() {
        let video = Attachment(id: "a", name: "clip.mp4", uri: "file:///tmp/clip.mp4", mimeType: "video/mp4", kind: .video)
        let label = AttachmentTypePolicy.detailLabel(for: video, byteCount: 21 * 1024 * 1024)
        XCTAssertTrue(label.hasPrefix("MP4 · "), label)
        XCTAssertTrue(label.contains("21"), label)
        XCTAssertEqual(AttachmentTypePolicy.symbolName(for: video), "film")
    }

    // MARK: - Size limit

    func testDefaultLimitMatchesHermesDesktop() {
        XCTAssertEqual(AttachmentSizeLimit.defaultMegabytes, 16)
        XCTAssertEqual(AttachmentSizeLimit.byteLimit(megabytes: 16), 16 * 1024 * 1024)
        XCTAssertTrue(AttachmentSizeLimit.choices.contains(AttachmentSizeLimit.defaultMegabytes))
        XCTAssertFalse(AttachmentSizeLimit.isRisky(megabytes: 16))
        XCTAssertTrue(AttachmentSizeLimit.isRisky(megabytes: 64))
    }

    func testLimitIsClampedToWhatTheHostAccepts() {
        XCTAssertEqual(AttachmentSizeLimit.clampedMegabytes(1024), AttachmentSizeLimit.hostMaximumMegabytes)
        XCTAssertEqual(AttachmentSizeLimit.clampedMegabytes(0), AttachmentSizeLimit.defaultMegabytes)
        XCTAssertEqual(AttachmentSizeLimit.choices.max(), AttachmentSizeLimit.hostMaximumMegabytes)
    }

    func testSizeCheckIsInclusiveOfTheLimit() {
        let limit = AttachmentSizeLimit.byteLimit(megabytes: 16)
        XCTAssertTrue(AttachmentSizeLimit.allows(byteCount: limit, megabytes: 16))
        XCTAssertFalse(AttachmentSizeLimit.allows(byteCount: limit + 1, megabytes: 16))
        // The reporter's ~21 MB screen recording is over the default.
        XCTAssertFalse(AttachmentSizeLimit.allows(byteCount: 21 * 1024 * 1024, megabytes: 16))
        XCTAssertTrue(AttachmentSizeLimit.allows(byteCount: 21 * 1024 * 1024, megabytes: 32))
    }

    func testTooLargeMessageNamesTheFilesAndTheLimit() {
        let one = AttachmentSizeLimit.tooLargeMessage(names: ["clip.mp4"], megabytes: 16)
        XCTAssertTrue(one.contains("clip.mp4"), one)
        XCTAssertTrue(one.contains("16"), one)
        let many = AttachmentSizeLimit.tooLargeMessage(names: ["a.mov", "b.mov"], megabytes: 16)
        XCTAssertTrue(many.contains("a.mov") && many.contains("b.mov"), many)
    }

    func testVideoKindRoundTripsThroughDrafts() throws {
        let video = Attachment(id: "v", name: "clip.mov", uri: "file:///tmp/clip.mov", mimeType: "video/quicktime", kind: .video)
        let decoded = try JSONDecoder().decode(Attachment.self, from: JSONEncoder().encode(video))
        XCTAssertEqual(decoded, video)
    }

    // MARK: - Pictures sent to Hermes (#1265)

    private func pngData(width: Int, height: Int, alpha: Bool = false, opaque: Bool = false) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
        ))
        // Noise, so the PNG is large like a photo's.
        let pixels = try XCTUnwrap(context.data).bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        var seed: UInt32 = 7
        for i in 0..<(context.bytesPerRow * height) {
            seed = seed &* 1_103_515_245 &+ 12_345
            pixels[i] = UInt8(truncatingIfNeeded: seed >> 16)
            // Premultiplied, a full alpha takes any color.
            if alpha, opaque, i % 4 == 3 { pixels[i] = 255 }
        }
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    func testALargePictureGoesToHermesResizedAsAJPEG() throws {
        let data = try pngData(width: 2600, height: 1950)
        let prepared = try XCTUnwrap(PictureUpload.resized(data, filename: "IMG_0001.png"))
        XCTAssertEqual(prepared.filename, "IMG_0001.jpg")
        XCTAssertEqual(prepared.mimeType, "image/jpeg")
        XCTAssertLessThan(prepared.data.count, data.count)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(prepared.data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 2048)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 1536, "2600 x 1950 keeps its shape")
    }

    func testALargeTransparentPictureStaysAPNG() throws {
        let data = try pngData(width: 2600, height: 1950, alpha: true)
        let prepared = try XCTUnwrap(PictureUpload.resized(data, filename: "sticker.png"))
        XCTAssertEqual(prepared.filename, "sticker.png", "A JPEG would fill in the transparency")
        XCTAssertEqual(prepared.mimeType, "image/png")
    }

    func testAnOpaquePictureWithAnAlphaChannelStillGoesAsAJPEG() throws {
        let data = try pngData(width: 2600, height: 1950, alpha: true, opaque: true)
        let prepared = try XCTUnwrap(PictureUpload.resized(data, filename: "screenshot.png"))
        XCTAssertEqual(prepared.mimeType, "image/jpeg", "Only real transparency keeps it a PNG")
    }

    func testAPictureAModelTakesGoesUnchanged() throws {
        XCTAssertNil(PictureUpload.resized(try pngData(width: 2048, height: 1024), filename: "small.png"))
        XCTAssertNil(PictureUpload.resized(Data("not a picture".utf8), filename: "broken.jpg"))
    }
}
