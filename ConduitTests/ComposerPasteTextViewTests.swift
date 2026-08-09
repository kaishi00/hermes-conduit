import Foundation
import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import Conduit

final class ComposerPasteTextViewTests: XCTestCase {
    func testPasteItemProvidersDeliversImageData() {
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

        wait(for: [callback], timeout: 1.0)
    }
}
