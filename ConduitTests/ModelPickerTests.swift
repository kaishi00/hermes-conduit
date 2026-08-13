import XCTest
@testable import Conduit

final class ModelPickerTests: XCTestCase {
    func testUnchangedYoloSelectionDoesNotPersistASessionOverride() {
        XCTAssertFalse(sessionYoloSelectionChanged(from: true, to: true))
    }

    func testChangedYoloSelectionPersistsTheNewSessionOverride() {
        XCTAssertTrue(sessionYoloSelectionChanged(from: false, to: true))
        XCTAssertTrue(sessionYoloSelectionChanged(from: true, to: false))
    }

    func testSelectionBeforeInitialLoadDoesNotPersistAnOverride() {
        XCTAssertFalse(sessionYoloSelectionChanged(from: nil, to: true))
    }
}
