//
//  ComposerCameraCaptureTests.swift
//  ConduitTests
//
//  The composer's Camera item: a taken photo goes up as a JPEG image and
//  obeys the attachment size limit.
//

import UIKit
import XCTest
@testable import Conduit

extension ComposerAttachmentPolicyTests {
    func testCameraPhotoIsStagedAsJPEGImage() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let outcome = ComposerBar.stageCapturedPhoto(image, limitMegabytes: 16)
        guard case .staged(let attachment) = outcome else {
            return XCTFail("expected a staged photo, got \(outcome)")
        }
        let url = try XCTUnwrap(URL(string: attachment.uri))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.name, "photo.jpg")
        XCTAssertEqual(attachment.mimeType, "image/jpeg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// A call's model gets a small copy of a voice screen's photo: under
    /// Qwen's size limit, no longer than 1280 on its longest side.
    func testALiveCallsCopyOfAPhotoFitsTheProvidersLimits() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4_032, height: 3_024), format: format).image { context in
            for row in 0..<48 {
                for column in 0..<64 {
                    UIColor(hue: CGFloat((row * 64 + column) % 97) / 97, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
                    context.fill(CGRect(x: column * 63, y: row * 63, width: 63, height: 63))
                }
            }
        }
        let jpeg = try XCTUnwrap(LiveVoicePhotoFrame.jpeg(from: image))
        XCTAssertLessThanOrEqual(jpeg.count, LiveVoicePhotoFrame.maximumBytes)
        let decoded = try XCTUnwrap(UIImage(data: jpeg))
        XCTAssertLessThanOrEqual(max(decoded.size.width * decoded.scale, decoded.size.height * decoded.scale), 1_280)
        XCTAssertEqual(decoded.size.width / decoded.size.height, 4 / 3, accuracy: 0.01, "the shape is kept")
    }
}
