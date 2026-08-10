import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import Conduit

@MainActor
final class ComposerPasteTextViewTests: XCTestCase {
    func testPasteItemProvidersDeliversImageData() async {
        let view = ImagePasteTextView()
        let expectedData = Data([0x89, 0x50, 0x4E, 0x47])
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            visibility: .all
        ) { completion in
            completion(expectedData, nil)
            return nil
        }

        let callback = expectation(description: "pasted image callback")
        view.onPastedImage = { pastedImage in
            XCTAssertEqual(pastedImage.data, expectedData)
            XCTAssertEqual(pastedImage.typeIdentifier, UTType.png.identifier)
            callback.fulfill()
        }

        view.paste(itemProviders: [provider])

        await fulfillment(of: [callback], timeout: 5.0)
    }

    func testCanPasteAcceptsImageItemProvider() {
        let view = ImagePasteTextView()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            visibility: .all
        ) { completion in
            completion(Data([0x89, 0x50, 0x4E, 0x47]), nil)
            return nil
        }

        XCTAssertEqual(
            view.pasteConfiguration?.acceptableTypeIdentifiers,
            [UTType.text.identifier, UTType.image.identifier, UTType.item.identifier]
        )
        XCTAssertTrue(view.canPaste([provider]))
    }

    func testPasteItemProvidersReportsImageLoadFailure() async {
        let view = ImagePasteTextView()
        let expectedError = NSError(
            domain: "ComposerPasteTextViewTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The image provider failed."]
        )
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            visibility: .all
        ) { completion in
            completion(nil, expectedError)
            return nil
        }

        let callback = expectation(description: "pasted image error callback")
        view.onPastedImageError = { message in
            XCTAssertFalse(message.isEmpty)
            callback.fulfill()
        }

        view.paste(itemProviders: [provider])

        await fulfillment(of: [callback], timeout: 5.0)
    }

    func testPasteItemProvidersFallsBackToUIImageWhenImageDataFails() async {
        let view = ImagePasteTextView()
        let expectedImage = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { rendererContext in
            UIColor.systemOrange.setFill()
            rendererContext.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let expectedError = NSError(
            domain: "ComposerPasteTextViewTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "The raw image representation failed."]
        )
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            visibility: .all
        ) { completion in
            completion(nil, expectedError)
            return nil
        }
        provider.registerObject(ofClass: UIImage.self, visibility: .all) { completion in
            completion(expectedImage, nil)
            return nil
        }

        let callback = expectation(description: "fallback image callback")
        view.onPastedImage = { pastedImage in
            XCTAssertFalse(pastedImage.data.isEmpty)
            XCTAssertEqual(pastedImage.typeIdentifier, UTType.png.identifier)
            callback.fulfill()
        }
        view.onPastedImageError = { message in
            XCTFail("Image object fallback should succeed, got: \(message)")
        }

        view.paste(itemProviders: [provider])

        await fulfillment(of: [callback], timeout: 5.0)
    }

    func testPasteItemProvidersFallsBackToTextViewForText() async {
        let view = ImagePasteTextView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
        view.isEditable = true
        view.becomeFirstResponder()

        let provider = NSItemProvider(object: NSString(string: "pasted text"))
        view.paste(itemProviders: [provider])

        let textInserted = expectation(description: "text pasted")
        let deadline = Date().addingTimeInterval(1.0)
        func checkText() {
            if view.text == "pasted text" {
                textInserted.fulfill()
            } else if Date() < deadline {
                DispatchQueue.main.async { checkText() }
            }
        }
        checkText()

        await fulfillment(of: [textInserted], timeout: 1.0)
    }

    func testPasteItemProvidersPreservesJPEGTypeIdentifier() async {
        let view = ImagePasteTextView()
        let expectedData = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.jpeg.identifier,
            visibility: .all
        ) { completion in
            completion(expectedData, nil)
            return nil
        }

        let callback = expectation(description: "pasted JPEG callback")
        view.onPastedImage = { pastedImage in
            XCTAssertEqual(pastedImage.data, expectedData)
            XCTAssertEqual(pastedImage.typeIdentifier, UTType.jpeg.identifier)
            callback.fulfill()
        }

        view.paste(itemProviders: [provider])

        await fulfillment(of: [callback], timeout: 5.0)
    }

    func testPasteItemProvidersNormalizesGenericJPEGToPNG() async {
        let view = ImagePasteTextView()
        let sourceImage = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { rendererContext in
            UIColor.systemOrange.setFill()
            rendererContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        guard let expectedJPEGData = sourceImage.jpegData(compressionQuality: 1) else {
            XCTFail("Could not create JPEG fixture")
            return
        }

        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.image.identifier,
            visibility: .all
        ) { completion in
            completion(expectedJPEGData, nil)
            return nil
        }

        let callback = expectation(description: "normalized generic image callback")
        view.onPastedImage = { pastedImage in
            XCTAssertNotEqual(pastedImage.data, expectedJPEGData)
            XCTAssertEqual(pastedImage.typeIdentifier, UTType.png.identifier)
            XCTAssertTrue(pastedImage.data.starts(with: Data([0x89, 0x50, 0x4E, 0x47])))
            XCTAssertNotNil(UIImage(data: pastedImage.data))

            let metadata = ComposerBar.pastedImageAttachmentMetadata(
                for: pastedImage.typeIdentifier
            )
            XCTAssertEqual(metadata.name, "pasted-image.png")
            XCTAssertEqual(metadata.mimeType, "image/png")
            callback.fulfill()
        }
        view.onPastedImageError = { message in
            XCTFail("Generic JPEG should normalize successfully, got: \(message)")
        }

        view.paste(itemProviders: [provider])

        await fulfillment(of: [callback], timeout: 5.0)
    }

    func testPasteItemProvidersNormalizesGenericHEICToPNG() async throws {
        let sourceImage = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { rendererContext in
            UIColor.systemOrange.setFill()
            rendererContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        guard let expectedHEICData = encodedImageData(sourceImage, type: .heic) else {
            throw XCTSkip("HEIC encoding is unavailable in this test runtime")
        }

        let view = ImagePasteTextView()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.image.identifier,
            visibility: .all
        ) { completion in
            completion(expectedHEICData, nil)
            return nil
        }

        let callback = expectation(description: "normalized generic HEIC callback")
        view.onPastedImage = { pastedImage in
            XCTAssertNotEqual(pastedImage.data, expectedHEICData)
            XCTAssertEqual(pastedImage.typeIdentifier, UTType.png.identifier)
            XCTAssertTrue(pastedImage.data.starts(with: Data([0x89, 0x50, 0x4E, 0x47])))
            XCTAssertNotNil(UIImage(data: pastedImage.data))
            callback.fulfill()
        }
        view.onPastedImageError = { message in
            XCTFail("Generic HEIC should normalize successfully, got: \(message)")
        }

        view.paste(itemProviders: [provider])

        await fulfillment(of: [callback], timeout: 5.0)
    }

    func testPastedImageAttachmentMetadataUsesImageType() {
        let metadata = ComposerBar.pastedImageAttachmentMetadata(for: UTType.jpeg.identifier)

        XCTAssertEqual(metadata.name, "pasted-image.jpeg")
        XCTAssertEqual(metadata.mimeType, "image/jpeg")
    }

    func testPastedImageErrorMessageIsVisibleComposerCopy() {
        XCTAssertEqual(
            ComposerBar.pastedImageErrorMessage("The image provider failed."),
            "Could not paste image: The image provider failed."
        )
    }

    private func encodedImageData(_ image: UIImage, type: UTType) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            type.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
