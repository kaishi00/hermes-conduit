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
}
