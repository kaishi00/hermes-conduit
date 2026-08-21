import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import Conduit

@MainActor
final class ComposerPasteTextViewTests: XCTestCase {
    // Tests that mutate UIPasteboard.general wrap their body in
    // withClearedGeneralPasteboard so they start from a known-empty clipboard
    // and leave nothing behind. A suite-wide setUp()/tearDown()
    // used to round-trip UIPasteboard.general.items around every test —
    // including the purely in-memory NSItemProvider tests below — and the
    // .items getter is the dangerous half: it materializes whatever the
    // simulator clipboard holds (content this app did not write), which can
    // block indefinitely on CI simulators. XCTest logs "Test Case ... started"
    // before setUp() returns, so the stall presents as a stuck first test
    // rather than a hung pasteboard read. Writes and clears are safe, so
    // isolation here uses clears only — never an unsolicited read.

    func testPasteboardContainsImageTrueForImagePasteboard() {
        withClearedGeneralPasteboard {
            let view = ImagePasteTextView()
            UIPasteboard.general.image = Self.fixtureImage()

            XCTAssertTrue(view.pasteboardContainsImage())
        }
    }

    func testPasteboardContainsImageFalseForTextPasteboard() {
        withClearedGeneralPasteboard {
            let view = ImagePasteTextView()
            UIPasteboard.general.string = "just text"

            XCTAssertFalse(view.pasteboardContainsImage())
        }
    }

    func testCanPerformActionOffersPasteForImagePasteboard() {
        withClearedGeneralPasteboard {
            let view = ImagePasteTextView()
            view.isEditable = true
            UIPasteboard.general.image = Self.fixtureImage()

            // Regression: UITextView drops "Paste" for an image-only pasteboard, so
            // the long-press edit menu only offered system items like "Autofill".
            // canPerformAction must surface paste: so the existing paste(_:) path
            // becomes reachable from the menu.
            XCTAssertTrue(view.canPerformAction(#selector(UIResponder.paste(_:)), withSender: nil))
        }
    }

    func testShouldOfferImagePasteTrueForImagePasteboard() {
        withClearedGeneralPasteboard {
            let view = ImagePasteTextView()
            view.isEditable = true
            UIPasteboard.general.image = Self.fixtureImage()

            XCTAssertTrue(view.shouldOfferImagePaste())
        }
    }

    func testShouldOfferImagePasteFalseWhenNotEditable() {
        withClearedGeneralPasteboard {
            let view = ImagePasteTextView()
            view.isEditable = false
            UIPasteboard.general.image = Self.fixtureImage()

            // A disabled composer must not offer image paste even with an image on
            // the pasteboard.
            XCTAssertFalse(view.shouldOfferImagePaste())
        }
    }

    func testShouldOfferImagePasteFalseForTextOnlyPasteboard() {
        withClearedGeneralPasteboard {
            let view = ImagePasteTextView()
            view.isEditable = true
            UIPasteboard.general.string = "just text"

            // Text-only content must not be treated as an image paste.
            XCTAssertFalse(view.shouldOfferImagePaste())
        }
    }

    func testPasteSelectorDeliversImageFromPasteboard() async {
        // End-to-end check of the exact path a menu tap now dispatches: the
        // legacy paste(_:) selector reads UIPasteboard.general and fires
        // onPastedImage. This is independent of the canPerformAction gate.
        await withClearedGeneralPasteboard {
            let view = ImagePasteTextView()
            UIPasteboard.general.image = Self.fixtureImage()

            let callback = expectation(description: "paste(_:) delivered image")
            view.onPastedImage = { pastedImage in
                XCTAssertFalse(pastedImage.data.isEmpty)
                XCTAssertEqual(pastedImage.typeIdentifier, UTType.png.identifier)
                callback.fulfill()
            }
            view.onPastedImageError = { message in
                XCTFail("paste(_:) should deliver the image, got: \(message)")
            }

            view.paste(nil as Any?)

            await fulfillment(of: [callback], timeout: 5.0)
        }
    }

    func testProgrammaticTextApplicationDoesNotPublishAsUserEditing() {
        var value = "old"
        let view = ComposerPasteTextView(
            text: Binding(get: { value }, set: { value = $0 }),
            isFocused: .constant(false),
            measuredHeight: .constant(44),
            enabled: true,
            onPastedImage: { _ in },
            onPastedImageError: { _ in },
            editorIdentity: UUID()
        )
        let coordinator = ComposerPasteTextView.Coordinator(view)
        coordinator.isApplyingProgrammaticState = true

        let textView = ImagePasteTextView()
        textView.text = "restored"

        coordinator.textViewDidChange(textView)

        XCTAssertEqual(value, "old")
    }

    func testInactiveCoordinatorDoesNotPublishFocusOrMeasuredHeightChanges() {
        var isFocused = false
        var measuredHeight: CGFloat = 44
        let view = ComposerPasteTextView(
            text: .constant(""),
            isFocused: Binding(get: { isFocused }, set: { isFocused = $0 }),
            measuredHeight: Binding(get: { measuredHeight }, set: { measuredHeight = $0 }),
            enabled: true,
            onPastedImage: { _ in },
            onPastedImageError: { _ in },
            editorIdentity: UUID()
        )
        let coordinator = ComposerPasteTextView.Coordinator(view)
        coordinator.isActive = false

        let textView = ImagePasteTextView()

        coordinator.textViewDidBeginEditing(textView)
        coordinator.updateMeasuredHeight(88)
        coordinator.textViewDidEndEditing(textView)

        XCTAssertFalse(isFocused)
        XCTAssertEqual(measuredHeight, 44)
    }

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

    /// Clears the general pasteboard, runs `body`, then clears it again.
    /// Scoped to the tests that actually write to UIPasteboard.general so
    /// every other test in this suite stays off the global pasteboard service
    /// entirely. Deliberately performs NO read of `items`: materializing
    /// existing clipboard content is what wedges CI simulators, while clears
    /// and writes stay safe. The trailing clear also keeps image payloads from
    /// leaking into later suites.
    private func withClearedGeneralPasteboard(_ body: () throws -> Void) rethrows {
        let pasteboard = UIPasteboard.general
        pasteboard.items = []
        defer { pasteboard.items = [] }
        try body()
    }

    /// Async counterpart for tests that await while their mutated pasteboard
    /// content is live (e.g. waiting on a paste callback expectation).
    private func withClearedGeneralPasteboard(_ body: () async throws -> Void) async rethrows {
        let pasteboard = UIPasteboard.general
        pasteboard.items = []
        defer { pasteboard.items = [] }
        try await body()
    }

    private static func fixtureImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
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
