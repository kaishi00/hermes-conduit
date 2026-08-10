import Foundation
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
        view.onPastedImage = { data in
            XCTAssertEqual(data, expectedData)
            callback.fulfill()
        }

        view.paste(itemProviders: [provider])

        await fulfillment(of: [callback], timeout: 1.0)
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
            [UTType.text.identifier, UTType.image.identifier]
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

        await fulfillment(of: [callback], timeout: 1.0)
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
}
